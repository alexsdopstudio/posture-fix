import Foundation

/// One judged instant, as the app sees it after the desk engine has processed a sample.
public struct PostureSampleSnapshot: Sendable {
    public var date: Date
    /// Smoothed pitch relative to the neutral, degrees.
    public var pitchDeviation: Double
    /// Smoothed roll, degrees.
    public var roll: Double
    public var deviation: PostureDeviation
    public var isInAxis: Bool
    public var state: DeskPostureState
    public var isMotionGated: Bool
    public var isSeated: Bool
    public var calibrationID: UUID?
    public var frontmostApp: String?

    public init(
        date: Date,
        pitchDeviation: Double,
        roll: Double,
        deviation: PostureDeviation,
        isInAxis: Bool,
        state: DeskPostureState,
        isMotionGated: Bool,
        isSeated: Bool,
        calibrationID: UUID?,
        frontmostApp: String? = nil
    ) {
        self.date = date
        self.pitchDeviation = pitchDeviation
        self.roll = roll
        self.deviation = deviation
        self.isInAxis = isInAxis
        self.state = state
        self.isMotionGated = isMotionGated
        self.isSeated = isSeated
        self.calibrationID = calibrationID
        self.frontmostApp = frontmostApp
    }
}

/// Folds the 50 Hz stream into one `PostureMinuteRecord` per wall-clock minute.
/// Only feed it real AirPods samples: simulated data must never reach the history.
public final class PostureMinuteAggregator {
    public struct Configuration: Sendable {
        /// Minutes with less real data than this are dropped.
        public var minimumTrackedSeconds: Double = 5
        /// Larger gaps between samples are clamped (sleep, AirPods removed).
        public var maximumSampleGap: Double = 0.5
        /// Not seated (or no data) for this long ends the sitting session.
        public var sessionBreakSeconds: Double = 120

        public init() {}
    }

    public let configuration: Configuration

    private struct Accumulator {
        var minuteStart: Date
        var tracked: Double = 0
        var moving: Double = 0
        var pitches: [Double] = []
        var rollSum: Double = 0
        var rollWeight: Double = 0
        var categories = PostureCategorySeconds()
        var states = PostureStateSeconds()
        var calibrationSeconds: [UUID: Double] = [:]
        var appSeconds: [String: Double] = [:]
    }

    private var current: Accumulator?
    private var lastDate: Date?
    private var sessionStart: Date?
    private var unseatedSince: Date?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Adds one sample; returns the previous minute when this sample starts a new one.
    public func add(_ sample: PostureSampleSnapshot) -> PostureMinuteRecord? {
        let minuteStart = Self.minuteStart(of: sample.date)
        var finished: PostureMinuteRecord?
        if let accumulator = current, accumulator.minuteStart != minuteStart {
            finished = makeRecord(accumulator)
            current = nil
        }
        if current == nil {
            current = Accumulator(minuteStart: minuteStart)
        }

        let rawGap = lastDate.map { sample.date.timeIntervalSince($0) } ?? 0
        let dt = max(0, min(configuration.maximumSampleGap, rawGap))
        lastDate = sample.date
        updateSession(sample, gap: rawGap)

        guard var accumulator = current else { return finished }
        accumulator.tracked += dt
        switch sample.state {
        case .neutral: accumulator.states.neutral += dt
        case .drifting: accumulator.states.drifting += dt
        case .magneticNudge: accumulator.states.magneticNudge += dt
        case .dopamineRecovery: accumulator.states.dopamineRecovery += dt
        }
        if let id = sample.calibrationID { accumulator.calibrationSeconds[id, default: 0] += dt }
        if let app = sample.frontmostApp { accumulator.appSeconds[app, default: 0] += dt }

        if sample.isMotionGated {
            accumulator.moving += dt
        } else {
            accumulator.pitches.append(sample.pitchDeviation)
            accumulator.rollSum += sample.roll * dt
            accumulator.rollWeight += dt
            switch sample.deviation {
            case .techNeck: accumulator.categories.techNeck += dt
            case .turtle: accumulator.categories.turtle += dt
            case .leftLean: accumulator.categories.leftLean += dt
            case .rightLean: accumulator.categories.rightLean += dt
            case .none:
                if sample.isInAxis {
                    accumulator.categories.inAxis += dt
                } else {
                    accumulator.categories.between += dt
                }
            }
        }
        current = accumulator
        return finished
    }

    /// Closes the minute in progress (app quitting, AirPods removed).
    public func flush() -> PostureMinuteRecord? {
        defer { current = nil }
        return current.flatMap(makeRecord)
    }

    public static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func updateSession(_ sample: PostureSampleSnapshot, gap: TimeInterval) {
        if gap > configuration.sessionBreakSeconds {
            sessionStart = nil
        }
        if sample.isSeated {
            unseatedSince = nil
            if sessionStart == nil { sessionStart = sample.date }
        } else {
            let since = unseatedSince ?? sample.date
            unseatedSince = since
            if sample.date.timeIntervalSince(since) >= configuration.sessionBreakSeconds {
                sessionStart = nil
            }
        }
    }

    private func makeRecord(_ accumulator: Accumulator) -> PostureMinuteRecord? {
        guard accumulator.tracked >= configuration.minimumTrackedSeconds else { return nil }
        let sessionEnd = lastDate ?? accumulator.minuteStart
        return PostureMinuteRecord(
            minuteStart: accumulator.minuteStart,
            trackedSeconds: accumulator.tracked,
            movingSeconds: accumulator.moving,
            pitchMean: Statistics.mean(accumulator.pitches),
            pitchMedian: Statistics.percentile(accumulator.pitches, 50) ?? 0,
            pitchP10: Statistics.percentile(accumulator.pitches, 10) ?? 0,
            pitchP90: Statistics.percentile(accumulator.pitches, 90) ?? 0,
            rollMean: accumulator.rollWeight > 0 ? accumulator.rollSum / accumulator.rollWeight : 0,
            categories: accumulator.categories,
            states: accumulator.states,
            sittingSessionSeconds: sessionStart.map { max(0, sessionEnd.timeIntervalSince($0)) } ?? 0,
            calibrationID: accumulator.calibrationSeconds.max { $0.value < $1.value }?.key,
            frontmostApp: accumulator.appSeconds.max { $0.value < $1.value }?.key
        )
    }
}

/// Turns desk-engine events into history events: nudges, recoveries with their latency,
/// and relapses with how long the recovery lasted.
public final class PostureEventTracker {
    private var nudgeStartedAt: Date?
    private var lastRecoveryAt: Date?

    public init() {}

    public func handle(_ events: [DeskPostureEvent], at date: Date, calibrationID: UUID?) -> [PostureEventRecord] {
        var records: [PostureEventRecord] = []
        for event in events {
            switch event {
            case let .stateChanged(_, newState) where newState == .magneticNudge:
                nudgeStartedAt = date
                records.append(PostureEventRecord(date: date, kind: .nudgeStarted, calibrationID: calibrationID))
            case let .stateChanged(_, newState) where newState == .drifting:
                if let recovery = lastRecoveryAt {
                    records.append(PostureEventRecord(
                        date: date,
                        kind: .relapsed,
                        secondsSinceRecovery: date.timeIntervalSince(recovery),
                        calibrationID: calibrationID
                    ))
                    lastRecoveryAt = nil
                }
            case .stateChanged:
                break
            case .recovered:
                records.append(PostureEventRecord(
                    date: date,
                    kind: .recovered,
                    recoveryLatencySeconds: nudgeStartedAt.map { date.timeIntervalSince($0) },
                    calibrationID: calibrationID
                ))
                nudgeStartedAt = nil
                lastRecoveryAt = date
            }
        }
        return records
    }
}
