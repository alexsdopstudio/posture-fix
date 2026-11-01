import Foundation

/// Seconds spent in each posture category.
public struct PostureCategorySeconds: Codable, Equatable, Sendable {
    public var inAxis: Double = 0
    /// No deviation, but outside the in-axis tolerance.
    public var between: Double = 0
    public var techNeck: Double = 0
    public var turtle: Double = 0
    public var leftLean: Double = 0
    public var rightLean: Double = 0

    public init() {}

    public var deviated: Double { techNeck + turtle + leftLean + rightLean }
    public var total: Double { inAxis + between + deviated }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var sum = PostureCategorySeconds()
        sum.inAxis = lhs.inAxis + rhs.inAxis
        sum.between = lhs.between + rhs.between
        sum.techNeck = lhs.techNeck + rhs.techNeck
        sum.turtle = lhs.turtle + rhs.turtle
        sum.leftLean = lhs.leftLean + rhs.leftLean
        sum.rightLean = lhs.rightLean + rhs.rightLean
        return sum
    }
}

/// Seconds spent in each state of the desk nudge machine.
public struct PostureStateSeconds: Codable, Equatable, Sendable {
    public var neutral: Double = 0
    public var drifting: Double = 0
    public var magneticNudge: Double = 0
    public var dopamineRecovery: Double = 0

    public init() {}
}

/// One wall-clock minute of real (never simulated) AirPods data.
public struct PostureMinuteRecord: Codable, Equatable, Sendable {
    public var minuteStart: Date
    public var trackedSeconds: Double
    /// Motion-gated seconds: voluntary movement, excluded from the posture judgement.
    public var movingSeconds: Double
    /// Smoothed pitch relative to the neutral over judged samples, degrees (negative = looking down).
    public var pitchMean: Double
    public var pitchMedian: Double
    public var pitchP10: Double
    public var pitchP90: Double
    /// Mean smoothed roll, degrees (positive = leaning right).
    public var rollMean: Double
    public var categories: PostureCategorySeconds
    public var states: PostureStateSeconds
    /// Length of the sitting session at the end of this minute.
    public var sittingSessionSeconds: Double
    public var calibrationID: UUID?
    /// Bundle identifier of the dominant frontmost app (only when the user opted in).
    public var frontmostApp: String?

    /// Seconds actually judged (not moving).
    public var judgedSeconds: Double { categories.total }
}

public struct PostureEventRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nudgeStarted
        case recovered
        /// Drifting again after a recovery.
        case relapsed
        case calibrated
    }

    public var date: Date
    public var kind: Kind
    /// `recovered`: seconds from the nudge start to the recovery.
    public var recoveryLatencySeconds: Double?
    /// `relapsed`: seconds the recovery lasted.
    public var secondsSinceRecovery: Double?
    /// `calibrated`: whether the webcam took part.
    public var usedCamera: Bool?
    /// `calibrated`: webcam cues still unmet when the calibration locked.
    public var unmetCues: [String]?
    public var calibrationID: UUID?

    public init(
        date: Date,
        kind: Kind,
        recoveryLatencySeconds: Double? = nil,
        secondsSinceRecovery: Double? = nil,
        usedCamera: Bool? = nil,
        unmetCues: [String]? = nil,
        calibrationID: UUID? = nil
    ) {
        self.date = date
        self.kind = kind
        self.recoveryLatencySeconds = recoveryLatencySeconds
        self.secondsSinceRecovery = secondsSinceRecovery
        self.usedCamera = usedCamera
        self.unmetCues = unmetCues
        self.calibrationID = calibrationID
    }
}

/// What remains of a day after the per-minute retention window.
public struct PostureDaySummary: Codable, Equatable, Sendable {
    public var day: Date
    public var trackedMinutes: Double
    public var judgedMinutes: Double
    /// Median of the per-minute pitch medians, degrees.
    public var pitchMedian: Double
    public var rollMean: Double
    public var categories: PostureCategorySeconds
    public var nudges: Int
    public var recoveries: Int
    public var meanRecoveryLatencySeconds: Double?
    /// Share of judged time without a deviation, 0-100.
    public var deskFlowScore: Int

    public static func make(day: Date, minutes: [PostureMinuteRecord], events: [PostureEventRecord]) -> PostureDaySummary {
        let categories = minutes.reduce(PostureCategorySeconds()) { $0 + $1.categories }
        let judged = categories.total
        let latencies = events.compactMap(\.recoveryLatencySeconds)
        let score = judged > 0 ? Int((100 * (1 - categories.deviated / judged)).rounded()) : 100
        return PostureDaySummary(
            day: day,
            trackedMinutes: minutes.reduce(0) { $0 + $1.trackedSeconds } / 60,
            judgedMinutes: judged / 60,
            pitchMedian: Statistics.percentile(minutes.map(\.pitchMedian), 50) ?? 0,
            rollMean: Statistics.mean(minutes.map(\.rollMean)),
            categories: categories,
            nudges: events.filter { $0.kind == .nudgeStarted }.count,
            recoveries: events.filter { $0.kind == .recovered }.count,
            meanRecoveryLatencySeconds: latencies.isEmpty ? nil : Statistics.mean(latencies),
            deskFlowScore: score
        )
    }
}
