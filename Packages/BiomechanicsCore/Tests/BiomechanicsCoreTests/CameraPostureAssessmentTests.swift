import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("Webcam-assisted calibration")
struct CameraPostureAssessmentTests {
    let assessment = CameraPostureAssessment()

    let upright = CameraPostureObservation(
        faceDetected: true,
        eyeLineRollDegrees: 1,
        faceYawDegrees: 3,
        faceCenterX: 0.52,
        eyeHeight: 0.6,
        faceWidth: 0.18,
        shoulderTiltDegrees: 1.5,
        shoulderWidth: 0.42
    )

    func cue(_ kind: PostureCueKind, in cues: [PostureCue]) -> PostureCue? {
        cues.first { $0.kind == kind }
    }

    @Test("Upright, centred, level: every cue satisfied, ready to lock")
    func uprightIsReady() {
        let cues = assessment.cues(for: upright)
        #expect(cues.count == 7)
        #expect(cues.allSatisfy { $0.isSatisfied })
        #expect(assessment.isReadyToCalibrate(cues))
    }

    @Test("No face: a single blocking cue")
    func noFace() {
        let cues = assessment.cues(for: CameraPostureObservation(faceDetected: false))
        #expect(cues == [PostureCue(kind: .faceVisible, isSatisfied: false, isBlocking: true)])
        #expect(!assessment.isReadyToCalibrate(cues))
    }

    @Test("A tilted head, a turned face or uneven shoulders block the lock")
    func blockingCues() {
        var tilted = upright
        tilted.eyeLineRollDegrees = -6
        #expect(cue(.headLevel, in: assessment.cues(for: tilted))?.isSatisfied == false)
        #expect(!assessment.isReadyToCalibrate(assessment.cues(for: tilted)))

        var turned = upright
        turned.faceYawDegrees = 18
        #expect(!assessment.isReadyToCalibrate(assessment.cues(for: turned)))

        var offCentre = upright
        offCentre.faceCenterX = 0.8
        #expect(!assessment.isReadyToCalibrate(assessment.cues(for: offCentre)))

        var shoulders = upright
        shoulders.shoulderTiltDegrees = 7
        #expect(!assessment.isReadyToCalibrate(assessment.cues(for: shoulders)))
    }

    @Test("Distance, forward head and screen height are advice, never blocking")
    func advisoryCues() throws {
        var leaning = upright
        leaning.faceWidth = 0.31          // closer than ~40 cm
        leaning.shoulderWidth = 0.5       // face/shoulders = 0.62: head pushed forward
        leaning.eyeHeight = 0.8           // eyes high in frame: screen too low
        let cues = assessment.cues(for: leaning)
        let distance = try #require(cue(.distance, in: cues))
        #expect(!distance.isSatisfied)
        #expect(distance.direction == -1)
        #expect(cue(.chinTuck, in: cues)?.isSatisfied == false)
        #expect(cue(.screenHeight, in: cues)?.isSatisfied == false)
        #expect(assessment.isReadyToCalibrate(cues))

        var far = upright
        far.faceWidth = 0.09
        #expect(cue(.distance, in: assessment.cues(for: far))?.direction == 1)
    }

    @Test("Shoulders out of frame: their cues are simply omitted")
    func missingShoulders() {
        var noShoulders = upright
        noShoulders.shoulderTiltDegrees = nil
        noShoulders.shoulderWidth = nil
        let cues = assessment.cues(for: noShoulders)
        #expect(cue(.shouldersLevel, in: cues) == nil)
        #expect(cue(.chinTuck, in: cues) == nil)
        #expect(assessment.isReadyToCalibrate(cues))
    }

    @Test("A closed gate pauses the hold; opening it resumes from where it was")
    func holdGate() {
        let calibrator = ZeroTouchAutoCalibrator()
        calibrator.beginWearCalibration()
        var time = 0.0
        func hold(seconds: Double) {
            for _ in 0..<Int(seconds * 50) {
                time += 0.02
                calibrator.process(IMUSample(timestamp: time))
            }
        }
        hold(seconds: 1)
        let afterOne = calibrator.wearProgress
        calibrator.isHoldGateOpen = false
        hold(seconds: 5)
        #expect(calibrator.wearProgress == afterOne)
        #expect(calibrator.isAwaitingWearCapture)
        calibrator.isHoldGateOpen = true
        hold(seconds: 2.1)
        #expect(!calibrator.isAwaitingWearCapture)
        #expect(calibrator.isNeutralLockedByUser)
        // The gate resets to open for the next calibration.
        #expect(calibrator.isHoldGateOpen)
    }
}
