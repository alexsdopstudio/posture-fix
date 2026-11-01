import BiomechanicsCore
import FlowUI
import Foundation
import Observation

/// iPhone counterpart of the Mac `FlowController`: AirPods posture while using the phone,
/// guided calibration (no webcam), spatial tone + haptic nudges, posture history.
@MainActor
@Observable
final class PhonePostureController {
    /// Guided calibration only, as on the Mac: the neutral is always the posture the user chose.
    let motion: HeadphoneMotionService = {
        var calibration = ZeroTouchAutoCalibrator.Configuration()
        calibration.allowsAutomaticCapture = false
        return HeadphoneMotionService(calibration: calibration)
    }()
    let history = PostureHistoryRecorder()
    @ObservationIgnored let headRing = HeadRingState()

    private(set) var state: DeskPostureState = .neutral
    private(set) var deviation: PostureDeviation = .none
    private(set) var flowScore = 100
    private(set) var streak = 0
    private(set) var isSimulatingTechNeck = false
    private(set) var headPitchDeviation: Double = 0
    private(set) var headRoll: Double = 0
    /// Progress of the guided calibration hold, nil when not calibrating.
    private(set) var calibrationProgress: Double?
    private(set) var isShowingCalibration = false

    @ObservationIgnored private let engine = DeskPostureEngine()
    @ObservationIgnored private let audio = SpatialMagneticAudioEngine()
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var lastReadoutUpdate: TimeInterval = 0
    @ObservationIgnored private var wasCalibrating = false

    var isCalibrated: Bool { motion.latestPose?.isCalibrated == true }
    var nudgeAfterSeconds: Int { Int(engine.configuration.nudgeAfterSeconds) }

    var ringThresholds: RingThresholds {
        let c = engine.configuration
        return RingThresholds(
            techNeck: c.techNeckFlexionDegrees,
            lateral: c.lateralLeanDegrees,
            pitchTolerance: c.inAxisPitchToleranceDegrees,
            rollTolerance: c.inAxisRollToleranceDegrees
        )
    }

    var stateDescription: String {
        guard isCalibrated else { return "Non calibrato" }
        switch state {
        case .neutral: return deviation == .none ? "In asse" : "Neutro · \(label(for: deviation))"
        case .drifting: return "Drifting · \(label(for: deviation))"
        case .magneticNudge: return "Richiamo · \(label(for: deviation))"
        case .dopamineRecovery: return "Recuperato ✨"
        }
    }

    func recalibrate() {
        motion.recalibrate()
        isShowingCalibration = true
    }

    func dismissCalibration() {
        isShowingCalibration = false
    }

    /// Demo: inject a flexed + right-tilted head and fast-forward past the nudge delay.
    func simulateTechNeck() {
        isSimulatingTechNeck = true
        motion.injectedPitchOffsetDegrees = -22
        motion.injectedRollOffsetDegrees = 7
        handle(events: engine.simulateSustainedDeviation(seconds: engine.configuration.nudgeAfterSeconds + 1))
    }

    func straightenUp() {
        isSimulatingTechNeck = false
        motion.injectedPitchOffsetDegrees = 0
        motion.injectedRollOffsetDegrees = 0
    }

    func handle(sample: IMUSample, pose: HeadPose) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != currentDay {
            currentDay = today
            engine.resetDailyMetrics()
        }

        // Without a neutral there is nothing to judge: no nudges, no score, no history.
        let events = pose.isCalibrated ? engine.process(sample, pose: pose) : []
        handle(events: events)
        if motion.isUsingSimulation || !pose.isCalibrated || pose.calibrationProgress != nil {
            history.flush()
        } else {
            history.record(engine, pose: pose, isInAxis: headStatus == .inAxis)
            history.record(events)
        }

        if engine.state == .magneticNudge {
            // The tone stops as soon as the head leaves the deviation.
            if engine.currentDeviation == .none {
                audio.stopMagneticPull()
            } else if audio.isPulling {
                audio.updatePull(roll: engine.smoothRoll)
            } else {
                audio.startMagneticPull(roll: engine.smoothRoll)
            }
        }

        if deviation != engine.currentDeviation { deviation = engine.currentDeviation }
        if flowScore != engine.metrics.dailyDeskFlowScore { flowScore = engine.metrics.dailyDeskFlowScore }
        if streak != engine.metrics.postureRecoveryStreak { streak = engine.metrics.postureRecoveryStreak }

        headRing.pitchDeviation = pose.relativeAttitude.pitchDegrees - pose.neutralPitchBaseline
        headRing.roll = pose.relativeAttitude.rollDegrees
        headRing.status = headStatus
        headRing.calibrationProgress = pose.calibrationProgress
        updateCalibration(pose: pose)

        if sample.timestamp - lastReadoutUpdate >= 1.0 / 15 || sample.timestamp < lastReadoutUpdate {
            lastReadoutUpdate = sample.timestamp
            headPitchDeviation = headRing.pitchDeviation
            headRoll = headRing.roll
            if calibrationProgress != pose.calibrationProgress { calibrationProgress = pose.calibrationProgress }
        }
    }

    private var headStatus: HeadStatus {
        if engine.currentDeviation != .none { return .deviating }
        let c = engine.configuration
        let inAxis = abs(engine.pitchDeviation) < c.inAxisPitchToleranceDegrees && abs(engine.smoothRoll) < c.inAxisRollToleranceDegrees
        return inAxis ? .inAxis : .between
    }

    /// Opens the calibration sheet when a guided calibration starts (AirPods put on, sitting
    /// still without a neutral) and closes it a moment after it locks.
    private func updateCalibration(pose: HeadPose) {
        let calibrating = pose.calibrationProgress != nil
        if calibrating && !wasCalibrating {
            isShowingCalibration = true
        }
        if pose.didCaptureReference && !motion.isUsingSimulation {
            history.recordCalibration(usedCamera: false, unmetCues: [])
        }
        if pose.didCaptureReference && wasCalibrating {
            headRing.calibratedAt = Date()
            calibrationProgress = nil
            audio.playDopamineChime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.calibrationProgress == nil else { return }
                    self.isShowingCalibration = false
                }
            }
        } else if !calibrating && wasCalibrating {
            isShowingCalibration = false
        }
        wasCalibrating = calibrating
    }

    private func handle(events: [DeskPostureEvent]) {
        for event in events {
            switch event {
            case let .stateChanged(_, newState):
                state = newState
                if newState == .magneticNudge {
                    audio.startMagneticPull(roll: engine.smoothRoll)
                } else {
                    audio.stopMagneticPull()
                }
            case .recovered:
                audio.playDopamineChime()
            }
        }
    }

    private func label(for deviation: PostureDeviation) -> String {
        switch deviation {
        case .none: return "in asse"
        case .techNeck: return "tech neck"
        case .turtle: return "collo a tartaruga"
        case .leftLean: return "inclinato a sinistra"
        case .rightLean: return "inclinato a destra"
        }
    }
}
