import AppKit
import BiomechanicsCore
import FlowUI
import Foundation
import Observation

/// Glue between the head-motion stream, the desk engine and the two nudge channels.
@MainActor
@Observable
final class FlowController {
    /// Guided calibration only: the neutral is always the posture the user chose.
    let motion: HeadphoneMotionService = {
        var calibration = ZeroTouchAutoCalibrator.Configuration()
        calibration.allowsAutomaticCapture = false
        return HeadphoneMotionService(calibration: calibration)
    }()

    private(set) var state: DeskPostureState = .neutral
    private(set) var deviation: PostureDeviation = .none
    private(set) var flowScore = 100
    private(set) var streak = 0
    private(set) var isSimulatingTechNeck = false

    /// Live head readout (raw, unsmoothed): pitch relative to the neutral, roll, yaw.
    private(set) var headPitchDeviation: Double = 0
    private(set) var headRoll: Double = 0
    private(set) var headYaw: Double = 0
    private(set) var isMotionGated = false

    /// Latest head reading for the Face ID-style ring, written at the sample rate outside SwiftUI.
    @ObservationIgnored let headRing = HeadRingState()
    @ObservationIgnored let cameraModel = CameraCalibrationModel()
    /// Posture history (real AirPods data only).
    @ObservationIgnored let history = PostureHistoryRecorder()
    @ObservationIgnored private lazy var calibrationHUD = CalibrationHUDController(
        ringState: headRing,
        thresholds: ringThresholds,
        camera: cameraModel
    )
    @ObservationIgnored private var wasCalibrating = false

    /// Use the webcam during the guided calibration (on by default, remembered).
    var usesCameraForCalibration: Bool {
        didSet { UserDefaults.standard.set(usesCameraForCalibration, forKey: Self.cameraPreferenceKey) }
    }
    private static let cameraPreferenceKey = "usesCameraForCalibration"
    /// After this long the webcam stops holding the calibration (advice stays visible).
    private static let cameraHoldLimit: TimeInterval = 10
    /// No analysed frame within this time: carry on without the webcam.
    private static let cameraFirstFrameLimit: TimeInterval = 4
    @ObservationIgnored private let camera = CameraPostureCapture()
    @ObservationIgnored private let cameraAssessment = CameraPostureAssessment()
    @ObservationIgnored private var calibrationStartedAt: Date?
    @ObservationIgnored private var lastCameraObservationAt: Date?
    @ObservationIgnored private var cameraHoldReleased = false

    /// The peripheral vignette is switched off for now; the spatial tone is the only nudge.
    let showsPeripheralOverlay = false

    @ObservationIgnored private let engine = DeskPostureEngine()
    @ObservationIgnored private let overlay = PeripheralOverlayWindowController()
    @ObservationIgnored private let audio = SpatialMagneticAudioEngine()
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var lastTelemetryUpdate: TimeInterval = 0

    init() {
        usesCameraForCalibration = UserDefaults.standard.object(forKey: Self.cameraPreferenceKey) as? Bool ?? true
        observeMacEventsForHistory()
        motion.onSample = { [weak self] sample, pose in
            self?.handle(sample: sample, pose: pose)
        }
        motion.start()
    }

    var nudgeAfterSeconds: Int { Int(engine.configuration.nudgeAfterSeconds) }
    var techNeckThreshold: Double { engine.configuration.techNeckFlexionDegrees }
    var lateralLeanThreshold: Double { engine.configuration.lateralLeanDegrees }
    var inAxisPitchTolerance: Double { engine.configuration.inAxisPitchToleranceDegrees }
    var inAxisRollTolerance: Double { engine.configuration.inAxisRollToleranceDegrees }
    var ringThresholds: RingThresholds {
        RingThresholds(
            techNeck: techNeckThreshold,
            lateral: lateralLeanThreshold,
            pitchTolerance: inAxisPitchTolerance,
            rollTolerance: inAxisRollTolerance
        )
    }

    var airPodsStatus: String {
        switch (motion.sourceState, motion.isUsingSimulation) {
        case (.airPodsStreaming, false): return "AirPods: head tracking live"
        case (.airPodsNotWorn, _), (.airPodsStreaming, true): return "AirPods non indossate · simulazione attiva"
        case (.unavailable, _): return "Motion cuffie non disponibile · simulazione attiva"
        }
    }

    var calibrationStatus: String {
        if motion.isAwaitingWearCalibration {
            return "Calibrazione: guarda il cerchio sullo schermo, testa ferma 3 s"
        }
        guard isCalibrated else {
            return "Non calibrato: premi Calibra per iniziare"
        }
        return "Calibrato su come indossi gli AirPods"
    }

    var isCalibrated: Bool { motion.latestPose?.isCalibrated == true }

    var stateDescription: String {
        switch state {
        case .neutral: return deviation == .none ? "In asse" : "Neutro · \(label(for: deviation))"
        case .drifting: return "Drifting · \(label(for: deviation))"
        case .magneticNudge: return "Magnetic Nudge · \(label(for: deviation))"
        case .dopamineRecovery: return "Recuperato ✨"
        }
    }

    /// Demo: inject a flexed + right-tilted head and fast-forward past 45 s.
    func simulateTechNeck() {
        isSimulatingTechNeck = true
        motion.injectedPitchOffsetDegrees = -22
        motion.injectedRollOffsetDegrees = 7
        handle(events: engine.simulateSustainedDeviation(seconds: engine.configuration.nudgeAfterSeconds + 1))
    }

    /// Demo: remove the injected deviation; the engine recovers on its own after 1.5 s in axis.
    func straightenUp() {
        isSimulatingTechNeck = false
        motion.injectedPitchOffsetDegrees = 0
        motion.injectedRollOffsetDegrees = 0
    }

    func recalibrate() {
        motion.recalibrate()
    }

    private func handle(sample: IMUSample, pose: HeadPose) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != currentDay {
            currentDay = today
            engine.resetDailyMetrics()
        }

        // Without a neutral there is nothing to judge: no nudges, no score, no history.
        let events = pose.isCalibrated ? engine.process(sample, pose: pose) : []
        handle(events: events)
        if motion.isUsingSimulation || !pose.isCalibrated || pose.calibrationProgress != nil {
            // Simulated or uncalibrated data never reaches the history; close the minute in progress.
            history.flush()
        } else {
            history.record(engine, pose: pose, isInAxis: headStatus == .inAxis)
            history.record(events)
        }

        if engine.state == .magneticNudge {
            // Immediate feedback: the pull fades the moment the head leaves the deviation,
            // while the engine still waits 1.5 s in axis before counting the recovery.
            if engine.currentDeviation == .none {
                updateOverlay(intensity: 0)
                audio.stopMagneticPull()
            } else {
                updateOverlay(intensity: engine.nudgeIntensity)
                if audio.isPulling {
                    audio.updatePull(roll: engine.smoothRoll)
                } else {
                    audio.startMagneticPull(roll: engine.smoothRoll)
                }
            }
        }
        // Only assign when changed, so SwiftUI does not redraw at 50 Hz.
        if deviation != engine.currentDeviation { deviation = engine.currentDeviation }
        if flowScore != engine.metrics.dailyDeskFlowScore { flowScore = engine.metrics.dailyDeskFlowScore }
        if streak != engine.metrics.postureRecoveryStreak { streak = engine.metrics.postureRecoveryStreak }
        headRing.pitchDeviation = pose.relativeAttitude.pitchDegrees - pose.neutralPitchBaseline
        headRing.roll = pose.relativeAttitude.rollDegrees
        headRing.status = headStatus
        headRing.calibrationProgress = pose.calibrationProgress
        updateCalibrationHUD(pose: pose)
        publishReadout(pose: pose, at: sample.timestamp)
    }

    /// Shows the guided-calibration HUD while it runs; confirms and fades out when it locks.
    private func updateCalibrationHUD(pose: HeadPose) {
        let calibrating = pose.calibrationProgress != nil
        if calibrating && !wasCalibrating {
            calibrationStartedAt = Date()
            if usesCameraForCalibration { startCamera() }
            calibrationHUD.show()
        }
        if calibrating {
            releaseCameraHoldIfNeeded()
        }
        if pose.didCaptureReference && !motion.isUsingSimulation {
            history.recordCalibration(usedCamera: cameraModel.isActive, unmetCues: cameraModel.cues)
        }
        if pose.didCaptureReference && wasCalibrating {
            headRing.calibratedAt = Date()
            NSSound(named: NSSound.Name("Tink"))?.play()
            stopCamera()
            calibrationHUD.hide(after: 1.6)
        } else if !calibrating && wasCalibrating {
            // Timed out: automatic calibration takes over silently.
            stopCamera()
            calibrationHUD.hide()
        }
        wasCalibrating = calibrating
    }

    // MARK: - History hooks

    /// The shared recorder is platform-free: feed it the frontmost app and flush on quit.
    private func observeMacEventsForHistory() {
        history.frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.history.frontmostApp = app?.bundleIdentifier }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.flush() }
        }
    }

    // MARK: - Webcam-assisted calibration

    private func startCamera() {
        cameraHoldReleased = false
        lastCameraObservationAt = nil
        cameraModel.isHoldingForPosture = true
        motion.setCalibrationHoldGate(false)
        camera.start(onObservation: { [weak self] observation in
            self?.handleCamera(observation)
        }, completion: { [weak self] running in
            guard let self else { return }
            if running {
                cameraModel.isActive = true
                cameraModel.previewLayer = camera.previewLayer
            } else {
                // No camera or permission denied: AirPods-only calibration.
                releaseCameraHold()
                cameraModel.reset()
            }
        })
    }

    private func handleCamera(_ observation: CameraPostureObservation) {
        guard camera.isRunning else { return }
        lastCameraObservationAt = Date()
        let cues = cameraAssessment.cues(for: observation)
        if cues != cameraModel.cues { cameraModel.cues = cues }
        guard !cameraHoldReleased else { return }
        let ready = cameraAssessment.isReadyToCalibrate(cues)
        if cameraModel.isHoldingForPosture == ready {
            cameraModel.isHoldingForPosture = !ready
            motion.setCalibrationHoldGate(ready)
        }
    }

    /// The webcam may hold the calibration, but never forever.
    private func releaseCameraHoldIfNeeded() {
        guard camera.isRunning, !cameraHoldReleased, let started = calibrationStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > Self.cameraHoldLimit || (lastCameraObservationAt == nil && elapsed > Self.cameraFirstFrameLimit) {
            releaseCameraHold()
        }
    }

    private func releaseCameraHold() {
        cameraHoldReleased = true
        cameraModel.isHoldingForPosture = false
        motion.setCalibrationHoldGate(true)
    }

    private func stopCamera() {
        camera.stop()
        cameraModel.reset()
        motion.setCalibrationHoldGate(true)
    }

    /// Ring colour: the engine's judgement (which uses the smoothed angles).
    private var headStatus: HeadStatus {
        if engine.currentDeviation != .none { return .deviating }
        let inAxis = abs(engine.pitchDeviation) < engine.configuration.inAxisPitchToleranceDegrees
            && abs(engine.smoothRoll) < engine.configuration.inAxisRollToleranceDegrees
        return inAxis ? .inAxis : .between
    }

    /// The numbers only need ~15 Hz; the ring itself redraws at display rate.
    private func publishReadout(pose: HeadPose, at time: TimeInterval) {
        guard time - lastTelemetryUpdate >= 1.0 / 15 || time < lastTelemetryUpdate else { return }
        lastTelemetryUpdate = time
        headPitchDeviation = pose.relativeAttitude.pitchDegrees - pose.neutralPitchBaseline
        headRoll = pose.relativeAttitude.rollDegrees
        headYaw = pose.relativeAttitude.yawDegrees
        isMotionGated = engine.isMotionGated
    }

    private func updateOverlay(intensity: Double) {
        guard showsPeripheralOverlay else { return }
        overlay.update(intensity: intensity, lateralBias: engine.lateralBias)
    }

    private func handle(events: [DeskPostureEvent]) {
        for event in events {
            switch event {
            case let .stateChanged(_, newState):
                state = newState
                if newState == .magneticNudge {
                    if showsPeripheralOverlay {
                        overlay.update(intensity: engine.nudgeIntensity, lateralBias: engine.lateralBias)
                        overlay.show()
                    }
                    audio.startMagneticPull(roll: engine.smoothRoll)
                } else {
                    overlay.hide()
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
