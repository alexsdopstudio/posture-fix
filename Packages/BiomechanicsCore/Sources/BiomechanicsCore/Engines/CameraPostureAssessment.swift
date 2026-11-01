import Foundation

/// What the webcam sees during calibration, already reduced to geometry by the app
/// (Vision runs on-device; no image ever reaches this type). Image coordinates are
/// normalised 0...1 with the origin at the bottom left.
public struct CameraPostureObservation: Equatable, Sendable {
    public var faceDetected: Bool
    /// Tilt of the line through the pupils, degrees (sign not used: only the magnitude).
    public var eyeLineRollDegrees: Double?
    /// Face yaw reported by Vision, degrees.
    public var faceYawDegrees: Double?
    /// Horizontal centre of the face, fraction of the image width.
    public var faceCenterX: Double?
    /// Height of the eyes in the frame, 0 = bottom, 1 = top.
    public var eyeHeight: Double?
    /// Face bounding-box width, fraction of the image width (a proxy for distance).
    public var faceWidth: Double?
    /// Tilt of the line through the shoulders, degrees (magnitude only).
    public var shoulderTiltDegrees: Double?
    /// Shoulder span, fraction of the image width.
    public var shoulderWidth: Double?

    public init(
        faceDetected: Bool,
        eyeLineRollDegrees: Double? = nil,
        faceYawDegrees: Double? = nil,
        faceCenterX: Double? = nil,
        eyeHeight: Double? = nil,
        faceWidth: Double? = nil,
        shoulderTiltDegrees: Double? = nil,
        shoulderWidth: Double? = nil
    ) {
        self.faceDetected = faceDetected
        self.eyeLineRollDegrees = eyeLineRollDegrees
        self.faceYawDegrees = faceYawDegrees
        self.faceCenterX = faceCenterX
        self.eyeHeight = eyeHeight
        self.faceWidth = faceWidth
        self.shoulderTiltDegrees = shoulderTiltDegrees
        self.shoulderWidth = shoulderWidth
    }
}

public enum PostureCueKind: String, CaseIterable, Sendable {
    case faceVisible
    case headLevel
    case facingScreen
    case centered
    case shouldersLevel
    case distance
    case chinTuck
    case screenHeight
}

/// One posture suggestion. Blocking cues must be satisfied before the calibration can
/// lock; advisory cues are shown but never block (the frontal camera can only estimate them).
public struct PostureCue: Equatable, Sendable {
    public var kind: PostureCueKind
    public var isSatisfied: Bool
    public var isBlocking: Bool
    /// The measured value behind the cue (degrees or ratio), when there is one.
    public var measured: Double?
    /// For `distance`: -1 too close, +1 too far, 0 fine.
    public var direction: Int

    public init(kind: PostureCueKind, isSatisfied: Bool, isBlocking: Bool, measured: Double? = nil, direction: Int = 0) {
        self.kind = kind
        self.isSatisfied = isSatisfied
        self.isBlocking = isBlocking
        self.measured = measured
        self.direction = direction
    }
}

/// Turns one webcam observation into posture cues for the guided calibration.
///
/// The frontal camera measures what the AirPods cannot: whether the head is truly level
/// and facing the screen, and whether the shoulders are even. The calibration locks only
/// when those blocking cues hold, so the AirPods reference is captured on a head that is
/// actually upright, however the earbuds sit in the ears. Forward head posture and screen
/// height are only estimated from the front, so they are advisory.
public struct CameraPostureAssessment: Sendable {
    public struct Configuration: Sendable {
        public var maxHeadRollDegrees: Double = 3
        public var maxFaceYawDegrees: Double = 10
        /// Allowed horizontal offset of the face from the image centre.
        public var maxCenterOffset: Double = 0.2
        public var maxShoulderTiltDegrees: Double = 4
        /// Face width as a fraction of the frame: ~40 cm (0.27) to ~85 cm (0.12) on a laptop camera.
        public var faceWidthRange: ClosedRange<Double> = 0.12...0.27
        /// Face/shoulder width above this suggests the head is pushed forward (face ~0.42 of shoulders when upright).
        public var maxFaceToShoulderRatio: Double = 0.55
        /// Eyes above this height in the frame suggest the screen sits too low.
        public var maxEyeHeight: Double = 0.72

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func cues(for observation: CameraPostureObservation) -> [PostureCue] {
        let c = configuration
        guard observation.faceDetected else {
            return [PostureCue(kind: .faceVisible, isSatisfied: false, isBlocking: true)]
        }
        var cues: [PostureCue] = []

        if let roll = observation.eyeLineRollDegrees {
            cues.append(PostureCue(kind: .headLevel, isSatisfied: abs(roll) <= c.maxHeadRollDegrees,
                                   isBlocking: true, measured: abs(roll)))
        }
        if let yaw = observation.faceYawDegrees {
            cues.append(PostureCue(kind: .facingScreen, isSatisfied: abs(yaw) <= c.maxFaceYawDegrees,
                                   isBlocking: true, measured: abs(yaw)))
        }
        if let centerX = observation.faceCenterX {
            cues.append(PostureCue(kind: .centered, isSatisfied: abs(centerX - 0.5) <= c.maxCenterOffset,
                                   isBlocking: true, measured: centerX))
        }
        if let tilt = observation.shoulderTiltDegrees {
            cues.append(PostureCue(kind: .shouldersLevel, isSatisfied: abs(tilt) <= c.maxShoulderTiltDegrees,
                                   isBlocking: true, measured: abs(tilt)))
        }
        if let width = observation.faceWidth {
            let direction = width > c.faceWidthRange.upperBound ? -1 : (width < c.faceWidthRange.lowerBound ? 1 : 0)
            cues.append(PostureCue(kind: .distance, isSatisfied: direction == 0, isBlocking: false,
                                   measured: width, direction: direction))
        }
        if let face = observation.faceWidth, let shoulders = observation.shoulderWidth, shoulders > 0 {
            let ratio = face / shoulders
            cues.append(PostureCue(kind: .chinTuck, isSatisfied: ratio <= c.maxFaceToShoulderRatio,
                                   isBlocking: false, measured: ratio))
        }
        if let eyes = observation.eyeHeight {
            cues.append(PostureCue(kind: .screenHeight, isSatisfied: eyes <= c.maxEyeHeight,
                                   isBlocking: false, measured: eyes))
        }
        return cues
    }

    /// True when every blocking cue holds.
    public func isReadyToCalibrate(_ cues: [PostureCue]) -> Bool {
        cues.filter(\.isBlocking).allSatisfy(\.isSatisfied)
    }
}
