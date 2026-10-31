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

    public init(relativeAttitude: EulerAngles, isSeated: Bool, isCalibrated: Bool, neutralPitchBaseline: Double) {
        self.relativeAttitude = relativeAttitude
        self.isSeated = isSeated
        self.isCalibrated = isCalibrated
        self.neutralPitchBaseline = neutralPitchBaseline
    }
}

/// Zero-Touch Auto-Calibration.
///
/// 1. Seated detection: the standard deviation of `|userAcceleration|` stays below
///    0.02 g for 10 consecutive seconds.
/// 2. On every sit-down the current attitude becomes the dynamic reference, and every
///    later attitude is expressed as `current.multiply(byInverseOf: reference)`.
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

        public init() {}
    }

    public let configuration: Configuration
    public private(set) var isSeated = false
    public private(set) var referenceAttitude: Quaternion?
    public private(set) var neutralPitchBaseline: Double?

    private var accelerationWindow: [(time: TimeInterval, magnitude: Double)] = []
    private var pitchWindow: [(time: TimeInterval, pitch: Double)] = []
    private var lastPitchSampleTime: TimeInterval = -.infinity

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

        if seatedNow && !isSeated {
            // New sit-down: capture a fresh dynamic reference and restart the baseline.
            referenceAttitude = sample.quaternion
            pitchWindow.removeAll()
            neutralPitchBaseline = nil
            lastPitchSampleTime = -.infinity
        }
        isSeated = seatedNow

        let relative = sample.quaternion.multiply(byInverseOf: referenceAttitude ?? sample.quaternion).eulerAngles

        if isSeated, now - lastPitchSampleTime >= configuration.baselineSampleInterval {
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
            neutralPitchBaseline: neutralPitchBaseline ?? 0
        )
    }
}
