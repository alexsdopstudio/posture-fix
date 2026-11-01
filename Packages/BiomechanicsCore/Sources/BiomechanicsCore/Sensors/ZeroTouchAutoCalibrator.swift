import Foundation

/// Calibrated head pose for one sample.
public struct HeadPose: Equatable, Sendable {
    /// Attitude relative to the dynamic reference captured when the user sat down.
    public var relativeAttitude: EulerAngles
    public var isSeated: Bool
    /// True once a reference attitude and a pitch baseline exist.
    public var isCalibrated: Bool
    /// Upper 85th percentile of seated pitch (degrees): the dynamic neutral.
    public var neutralPitchBaseline: Double
    /// True on the one sample where a new reference attitude was captured.
    public var didCaptureReference: Bool
    /// Guided calibration hold progress 0...1, nil when no guided calibration is running.
    public var calibrationProgress: Double?

    public init(
        relativeAttitude: EulerAngles,
        isSeated: Bool,
        isCalibrated: Bool,
        neutralPitchBaseline: Double,
        didCaptureReference: Bool = false,
        calibrationProgress: Double? = nil
    ) {
        self.relativeAttitude = relativeAttitude
        self.isSeated = isSeated
        self.isCalibrated = isCalibrated
        self.neutralPitchBaseline = neutralPitchBaseline
        self.didCaptureReference = didCaptureReference
        self.calibrationProgress = calibrationProgress
    }
}

/// Zero-Touch Auto-Calibration.
///
/// 1. Seated detection: the standard deviation of `|userAcceleration|` stays below
///    0.02 g for 10 consecutive seconds.
/// 2. On the first sit-down (and after being away for `recaptureAfterAbsenceSeconds`) the
///    current attitude becomes the dynamic reference, and every later attitude is expressed
///    as `current.multiply(byInverseOf: reference)`. Brief movements that interrupt the
///    seated state keep the reference, so the frame does not jump around.
/// Guided wear calibration: right after the AirPods are put on (or on demand) the user
/// sits upright and holds the head steady for `wearHoldSeconds`. Progress fills while the
/// head stays within `wearMaxDriftDegrees` of where the hold started and restarts from
/// zero when it moves, so a glance or an adjustment never locks a wrong posture. The held attitude
/// becomes both the reference and the neutral, and stays the neutral (no P85 drift):
/// it is the posture the user chose. Everything is measured relative to it, so AirPods
/// worn slightly rotated in the ear no longer make the head look crooked. If nobody holds
/// still within `wearTimeoutSeconds` the automatic seated calibration takes over.
///
/// 3. While seated, relative pitch is sampled into a rolling window and its upper
///    85th percentile becomes the neutral baseline. Slouching drags pitch down, so the
///    upper percentile tracks the user's own upright posture without any button.
public final class ZeroTouchAutoCalibrator {
    public struct Configuration: Sendable {
        public var seatedWindowSeconds: TimeInterval = 10
        public var stillnessThresholdG: Double = 0.02
        public var baselinePercentile: Double = 85
        public var baselineWindowSeconds: TimeInterval = 300
        public var baselineSampleInterval: TimeInterval = 0.2
        /// Minimum pitch history before the baseline is trusted.
        public var minimumBaselineSeconds: TimeInterval = 5
        /// Not seated for longer than this (stood up, walked away) recaptures the reference.
        public var recaptureAfterAbsenceSeconds: TimeInterval = 60
        /// Steady hold needed to lock the guided calibration.
        public var wearHoldSeconds: TimeInterval = 3.0
        /// Head rotation from the start of the hold that still counts as steady.
        public var wearMaxDriftDegrees: Double = 2.0
        /// Rotation rate (rad/s) above which the hold is considered broken.
        public var wearMaxRotationRate: Double = 0.2
        /// Give up the guided calibration (fall back to automatic) after this long.
        public var wearTimeoutSeconds: TimeInterval = 20
        /// Zero-Touch: capture the reference automatically on sit-down (spec behaviour).
        /// When false only the guided calibration sets the neutral, and sitting still
        /// without a reference reopens the guided calibration instead.
        public var allowsAutomaticCapture: Bool = true

        public init() {}
    }

    public let configuration: Configuration
    public private(set) var isSeated = false
    public private(set) var referenceAttitude: Quaternion?
    public private(set) var neutralPitchBaseline: Double?

    private var accelerationWindow: [(time: TimeInterval, magnitude: Double)] = []
    private var pitchWindow: [(time: TimeInterval, pitch: Double)] = []
    private var lastPitchSampleTime: TimeInterval = -.infinity
    private var lastSeatedTime: TimeInterval = -.infinity
    private var wearCapturePending = false
    private var adoptNextSample = false
    private var wearStartTime: TimeInterval?
    private var wearAnchor: Quaternion?
    private var wearHeld: TimeInterval = 0
    private var wearLastTime: TimeInterval?
    /// True when the neutral was chosen by the user (guided calibration): no P85 drift.
    public private(set) var isNeutralLockedByUser = false
    /// External condition for the hold to fill (e.g. the webcam confirms an upright head).
    /// While closed, a steady head pauses the progress instead of advancing it.
    public var isHoldGateOpen = true

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func reset() {
        isSeated = false
        referenceAttitude = nil
        neutralPitchBaseline = nil
        accelerationWindow.removeAll()
        pitchWindow.removeAll()
        lastPitchSampleTime = -.infinity
        lastSeatedTime = -.infinity
        isNeutralLockedByUser = false
        adoptNextSample = false
        endWearCalibration()
    }

    /// Takes the next sample as the neutral without any guided hold.
    /// Meant for the simulated head (demo without AirPods), never for real data.
    public func adoptNextSampleAsNeutral() {
        reset()
        adoptNextSample = true
    }

    /// Call when the AirPods are put on (or to recalibrate): the user holds an upright,
    /// steady head for `wearHoldSeconds` and that posture becomes the neutral.
    public func beginWearCalibration() {
        reset()
        wearCapturePending = true
    }

    /// True while the guided calibration is waiting for the steady hold.
    public var isAwaitingWearCapture: Bool { wearCapturePending }

    /// Hold progress 0...1 of the running guided calibration.
    public var wearProgress: Double { min(1, wearHeld / configuration.wearHoldSeconds) }

    private func endWearCalibration() {
        wearCapturePending = false
        wearStartTime = nil
        wearAnchor = nil
        wearHeld = 0
        wearLastTime = nil
        isHoldGateOpen = true
    }

    /// Advances the steady-hold timer; returns true when the hold is complete.
    private func advanceWearHold(_ sample: IMUSample) -> Bool {
        let now = sample.timestamp
        let dt = wearLastTime.map { max(0, min(0.2, now - $0)) } ?? 0
        wearLastTime = now
        if wearStartTime == nil { wearStartTime = now }

        let anchor = wearAnchor ?? sample.quaternion
        let drift = Self.angleDegrees(between: anchor, and: sample.quaternion)
        let steady = drift <= configuration.wearMaxDriftDegrees
            && sample.rotationRate.magnitude <= configuration.wearMaxRotationRate
        if steady {
            wearAnchor = anchor
            if isHoldGateOpen { wearHeld += dt }
        } else {
            // Moved: the new pose needs a full hold of its own.
            wearAnchor = sample.quaternion
            wearHeld = 0
        }
        return wearHeld >= configuration.wearHoldSeconds
    }

    /// Rotation angle between two attitudes, degrees.
    static func angleDegrees(between a: Quaternion, and b: Quaternion) -> Double {
        let qa = a.normalized
        let qb = b.normalized
        let dot = abs(qa.w * qb.w + qa.x * qb.x + qa.y * qb.y + qa.z * qb.z)
        return 2 * acos(min(1, dot)) * 180 / .pi
    }

    @discardableResult
    public func process(_ sample: IMUSample) -> HeadPose {
        let now = sample.timestamp
        accelerationWindow.append((now, sample.userAcceleration.magnitude))
        accelerationWindow.removeAll { $0.time < now - configuration.seatedWindowSeconds }

        let span = now - (accelerationWindow.first?.time ?? now)
        // Allow one sample period of slack so a 10 s window at 50 Hz qualifies.
        let windowComplete = span >= configuration.seatedWindowSeconds - 0.05
        let still = Statistics.standardDeviation(accelerationWindow.map(\.magnitude)) < configuration.stillnessThresholdG
        let seatedNow = windowComplete && still
        var didCapture = false

        if adoptNextSample {
            adoptNextSample = false
            referenceAttitude = sample.quaternion
            neutralPitchBaseline = 0
            isNeutralLockedByUser = true
            lastSeatedTime = now
            didCapture = true
        } else if wearCapturePending {
            if advanceWearHold(sample) {
                // The posture the user held is the neutral, by their choice.
                referenceAttitude = sample.quaternion
                neutralPitchBaseline = 0
                isNeutralLockedByUser = true
                pitchWindow.removeAll()
                lastPitchSampleTime = -.infinity
                lastSeatedTime = now
                endWearCalibration()
                didCapture = true
            } else if let start = wearStartTime, now - start > configuration.wearTimeoutSeconds {
                // Nobody calibrated (e.g. walking around): automatic calibration takes over.
                endWearCalibration()
            }
        } else if seatedNow && !isSeated {
            if !configuration.allowsAutomaticCapture {
                // Guided-only mode: sitting down still without a neutral reopens the guided calibration.
                if referenceAttitude == nil { wearCapturePending = true }
            } else if referenceAttitude == nil || now - lastSeatedTime > configuration.recaptureAfterAbsenceSeconds {
                // New sit-down: capture a fresh dynamic reference and restart the baseline.
                referenceAttitude = sample.quaternion
                pitchWindow.removeAll()
                neutralPitchBaseline = nil
                lastPitchSampleTime = -.infinity
                didCapture = true
            }
        }
        isSeated = seatedNow
        if isSeated { lastSeatedTime = now }

        let relative = sample.quaternion.multiply(byInverseOf: referenceAttitude ?? sample.quaternion).eulerAngles

        if isSeated, !isNeutralLockedByUser, now - lastPitchSampleTime >= configuration.baselineSampleInterval {
            lastPitchSampleTime = now
            pitchWindow.append((now, relative.pitchDegrees))
            pitchWindow.removeAll { $0.time < now - configuration.baselineWindowSeconds }
            let history = now - (pitchWindow.first?.time ?? now)
            if history >= configuration.minimumBaselineSeconds {
                neutralPitchBaseline = Statistics.percentile(pitchWindow.map(\.pitch), configuration.baselinePercentile)
            }
        }

        return HeadPose(
            relativeAttitude: relative,
            isSeated: isSeated,
            isCalibrated: referenceAttitude != nil && neutralPitchBaseline != nil,
            neutralPitchBaseline: neutralPitchBaseline ?? 0,
            didCaptureReference: didCapture,
            calibrationProgress: wearCapturePending ? wearProgress : nil
        )
    }
}
