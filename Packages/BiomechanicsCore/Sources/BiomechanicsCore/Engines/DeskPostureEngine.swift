import Foundation

public enum DeskPostureState: String, Sendable, CaseIterable {
    /// Head in axis, or deviating for less than 15 s.
    case neutral
    /// Deviating for 15-45 s: silent, nothing is shown yet.
    case drifting
    /// Deviating for more than 45 s: peripheral vignette and spatial audio pull.
    case magneticNudge
    /// Back in axis for 1.5 s after a nudge: reward chime, streak +1.
    case dopamineRecovery
}

public enum PostureDeviation: String, Sendable {
    case none
    /// Cervical flexion below the dynamic neutral (looking down at the screen).
    case techNeck
    /// Forward head translation with level gaze (chin poked forward).
    case turtle
    case leftLean
    case rightLean

    var isSagittal: Bool { self == .techNeck || self == .turtle }
}

public enum DeskPostureEvent: Equatable, Sendable {
    case stateChanged(from: DeskPostureState, to: DeskPostureState)
    case recovered(streak: Int)
}

/// Accumulated desk metrics for the current day.
public struct DeskPostureMetrics: Equatable, Sendable {
    public var totalTrackedSeconds: Double = 0
    public var techNeckAndTurtleSeconds: Double = 0
    public var leftLeanSeconds: Double = 0
    public var rightLeanSeconds: Double = 0
    public var longestStaticStretchSeconds: Double = 0
    public var neutralPitchBaseline: Double = 0
    public var postureRecoveryStreak: Int = 0

    public init() {}

    /// Share of tracked time spent without a sagittal or lateral deviation, 0-100.
    public var dailyDeskFlowScore: Int {
        guard totalTrackedSeconds > 0 else { return 100 }
        let deviated = techNeckAndTurtleSeconds + leftLeanSeconds + rightLeanSeconds
        let ratio = 1 - min(1, deviated / totalTrackedSeconds)
        return Int((ratio * 100).rounded())
    }
}

/// Privacy-first desk posture engine: head kinematics only, no camera.
///
/// Per sample it smooths pitch/roll with an EMA, gates out voluntary movement,
/// classifies the deviation (tech neck, turtle signature, lateral lean) and drives
/// the four-state nudge machine. All timers advance on sample time, so the engine
/// is fully deterministic under test.
public final class DeskPostureEngine {
    public struct Configuration: Sendable {
        public var emaAlpha: Double = 0.05
        public var motionGateAccelerationG: Double = 0.08
        public var motionGateRotationRate: Double = 0.5
        public var driftingAfterSeconds: Double = 15
        public var nudgeAfterSeconds: Double = 45
        public var recoveryHoldSeconds: Double = 1.5
        public var celebrationSeconds: Double = 2.0
        /// Flexion below the neutral baseline that counts as tech neck.
        public var techNeckFlexionDegrees: Double = 10
        public var lateralLeanDegrees: Double = 8
        public var inAxisPitchToleranceDegrees: Double = 5
        public var inAxisRollToleranceDegrees: Double = 4
        /// Mean anterior acceleration (g) over `translationWindowSeconds` that marks a forward head glide.
        public var turtleForwardAccelerationG: Double = 0.015
        public var translationWindowSeconds: Double = 1.0
        /// Sub-occipital (C1-C2) micro-extension above the baseline, degrees.
        public var turtleExtensionRange: ClosedRange<Double> = 1...8
        public var swayWindowSeconds: Double = 4
        /// Sway variance must fall below this fraction of the reference (40% reduction).
        public var swayReductionRatio: Double = 0.6
        /// Larger gaps between samples are clamped so a sleep/wake does not count as posture time.
        public var maximumSampleGap: Double = 0.5

        public init() {}
    }

    public let configuration: Configuration

    public private(set) var state: DeskPostureState = .neutral
    public private(set) var currentDeviation: PostureDeviation = .none
    public private(set) var smoothPitch: Double = 0
    public private(set) var smoothRoll: Double = 0
    public private(set) var pitchDeviation: Double = 0
    public private(set) var isMotionGated = false
    public private(set) var isForwardTranslationLatched = false
    public private(set) var swayVariance: Double = 0
    public private(set) var referenceSwayVariance: Double?
    public private(set) var deviationSeconds: Double = 0
    public private(set) var inAxisSeconds: Double = 0
    public private(set) var secondsInNudge: Double = 0
    public private(set) var metrics = DeskPostureMetrics()

    private var lastTimestamp: TimeInterval?
    private var celebrationElapsed: Double = 0
    private var currentStaticStretch: Double = 0
    private var swayWindow: [(time: TimeInterval, pitch: Double)] = []
    private var translationWindow: [(time: TimeInterval, forward: Double)] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Lateral pull direction for the nudge, -1 (head leaning left) ... +1 (leaning right).
    public var lateralBias: Double { max(-1, min(1, smoothRoll / 15)) }

    /// Progressive nudge intensity 0-1 that ramps over 10 s of nudge.
    public var nudgeIntensity: Double {
        state == .magneticNudge ? min(1, 0.25 + secondsInNudge / 10) : 0
    }

    /// Starts a new day: clears metrics but keeps the streak running.
    public func resetDailyMetrics() {
        let streak = metrics.postureRecoveryStreak
        metrics = DeskPostureMetrics()
        metrics.postureRecoveryStreak = streak
        currentStaticStretch = 0
    }

    /// Demo control: pretend the current deviation has already lasted `seconds`.
    @discardableResult
    public func simulateSustainedDeviation(seconds: Double) -> [DeskPostureEvent] {
        deviationSeconds = seconds
        inAxisSeconds = 0
        var events: [DeskPostureEvent] = []
        if seconds >= configuration.nudgeAfterSeconds {
            transition(to: .magneticNudge, events: &events)
        } else if seconds >= configuration.driftingAfterSeconds {
            transition(to: .drifting, events: &events)
        }
        return events
    }

    @discardableResult
    public func process(_ sample: IMUSample, pose: HeadPose) -> [DeskPostureEvent] {
        let config = configuration
        let dt: Double
        if let lastTimestamp {
            dt = max(0, min(config.maximumSampleGap, sample.timestamp - lastTimestamp))
        } else {
            dt = 0
            smoothPitch = pose.relativeAttitude.pitchDegrees
            smoothRoll = pose.relativeAttitude.rollDegrees
        }
        lastTimestamp = sample.timestamp

        // 1. EMA smoothing.
        smoothPitch += config.emaAlpha * (pose.relativeAttitude.pitchDegrees - smoothPitch)
        smoothRoll += config.emaAlpha * (pose.relativeAttitude.rollDegrees - smoothRoll)
        let baseline = pose.neutralPitchBaseline
        metrics.neutralPitchBaseline = baseline
        pitchDeviation = smoothPitch - baseline

        // 2. Dynamic motion gate.
        isMotionGated = sample.userAcceleration.magnitude > config.motionGateAccelerationG
            || sample.rotationRate.magnitude > config.motionGateRotationRate

        metrics.totalTrackedSeconds += dt
        if isMotionGated {
            currentStaticStretch = 0
        } else {
            currentStaticStretch += dt
            metrics.longestStaticStretchSeconds = max(metrics.longestStaticStretchSeconds, currentStaticStretch)
        }

        // 3. Kinematic turtle signature inputs.
        updateSway(time: sample.timestamp, pitch: pose.relativeAttitude.pitchDegrees)
        updateTranslation(time: sample.timestamp, forwardG: sample.userAcceleration.y)
        let extension_ = pitchDeviation
        let swayReduced = referenceSwayVariance.map { swayVariance < config.swayReductionRatio * $0 } ?? false
        let isTurtle = isForwardTranslationLatched
            && config.turtleExtensionRange.contains(extension_)
            && swayReduced

        // 4. Deviation classification.
        let deviation: PostureDeviation
        if pitchDeviation < -config.techNeckFlexionDegrees {
            deviation = .techNeck
        } else if isTurtle {
            deviation = .turtle
        } else if smoothRoll > config.lateralLeanDegrees {
            deviation = .rightLean
        } else if smoothRoll < -config.lateralLeanDegrees {
            deviation = .leftLean
        } else {
            deviation = .none
        }
        currentDeviation = deviation
        let inAxis = deviation == .none
            && abs(pitchDeviation) < config.inAxisPitchToleranceDegrees
            && abs(smoothRoll) < config.inAxisRollToleranceDegrees

        if inAxis && !isMotionGated && swayWindowIsFull {
            // Learn the physiological sway reference only from relaxed, in-axis sitting.
            if let reference = referenceSwayVariance {
                referenceSwayVariance = reference + 0.001 * (swayVariance - reference)
            } else {
                referenceSwayVariance = swayVariance
            }
        }

        var events: [DeskPostureEvent] = []
        guard !isMotionGated else {
            // Voluntary movement: every posture timer is frozen.
            return events
        }

        switch deviation {
        case .techNeck, .turtle: metrics.techNeckAndTurtleSeconds += dt
        case .leftLean: metrics.leftLeanSeconds += dt
        case .rightLean: metrics.rightLeanSeconds += dt
        case .none: break
        }

        if deviation != .none {
            deviationSeconds += dt
            inAxisSeconds = 0
        } else if inAxis {
            inAxisSeconds += dt
        }

        // 5. State machine.
        switch state {
        case .neutral:
            if deviationSeconds >= config.driftingAfterSeconds {
                transition(to: .drifting, events: &events)
            } else if inAxisSeconds >= config.recoveryHoldSeconds {
                deviationSeconds = 0
            }
        case .drifting:
            if deviationSeconds >= config.nudgeAfterSeconds {
                transition(to: .magneticNudge, events: &events)
            } else if inAxisSeconds >= config.recoveryHoldSeconds {
                deviationSeconds = 0
                transition(to: .neutral, events: &events)
            }
        case .magneticNudge:
            secondsInNudge += dt
            if inAxisSeconds >= config.recoveryHoldSeconds {
                deviationSeconds = 0
                isForwardTranslationLatched = false
                metrics.postureRecoveryStreak += 1
                transition(to: .dopamineRecovery, events: &events)
                events.append(.recovered(streak: metrics.postureRecoveryStreak))
            }
        case .dopamineRecovery:
            celebrationElapsed += dt
            if celebrationElapsed >= config.celebrationSeconds {
                transition(to: .neutral, events: &events)
            }
        }
        return events
    }

    private var swayWindowIsFull: Bool {
        guard let first = swayWindow.first, let last = swayWindow.last else { return false }
        return last.time - first.time >= configuration.swayWindowSeconds - 0.05
    }

    private func updateSway(time: TimeInterval, pitch: Double) {
        swayWindow.append((time, pitch))
        swayWindow.removeAll { $0.time < time - configuration.swayWindowSeconds }
        swayVariance = Statistics.variance(swayWindow.map(\.pitch))
    }

    private func updateTranslation(time: TimeInterval, forwardG: Double) {
        translationWindow.append((time, forwardG))
        translationWindow.removeAll { $0.time < time - configuration.translationWindowSeconds }
        let meanForward = Statistics.mean(translationWindow.map(\.forward))
        if meanForward > configuration.turtleForwardAccelerationG {
            isForwardTranslationLatched = true
        } else if meanForward < -configuration.turtleForwardAccelerationG {
            isForwardTranslationLatched = false
        }
    }

    private func transition(to newState: DeskPostureState, events: inout [DeskPostureEvent]) {
        guard newState != state else { return }
        events.append(.stateChanged(from: state, to: newState))
        state = newState
        if newState == .magneticNudge { secondsInNudge = 0 }
        if newState == .dopamineRecovery { celebrationElapsed = 0 }
    }
}
