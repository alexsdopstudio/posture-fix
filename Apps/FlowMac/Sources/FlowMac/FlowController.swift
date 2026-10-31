import BiomechanicsCore
import Foundation
import Observation

/// Glue between the head-motion stream, the desk engine and the two nudge channels.
@MainActor
@Observable
final class FlowController {
    let motion = HeadphoneMotionService()

    private(set) var state: DeskPostureState = .neutral
    private(set) var deviation: PostureDeviation = .none
    private(set) var flowScore = 100
    private(set) var streak = 0
    private(set) var isSimulatingTechNeck = false

    @ObservationIgnored private let engine = DeskPostureEngine()
    @ObservationIgnored private let overlay = PeripheralOverlayWindowController()
    @ObservationIgnored private let audio = SpatialMagneticAudioEngine()
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())

    init() {
        motion.onSample = { [weak self] sample, pose in
            self?.handle(sample: sample, pose: pose)
        }
        motion.start()
    }

    var airPodsStatus: String {
        switch (motion.sourceState, motion.isUsingSimulation) {
        case (.airPodsStreaming, false): return "AirPods: head tracking live"
        case (.airPodsNotWorn, _), (.airPodsStreaming, true): return "AirPods non indossate · simulazione attiva"
        case (.unavailable, _): return "Motion cuffie non disponibile · simulazione attiva"
        }
    }

    var calibrationStatus: String {
        guard let pose = motion.latestPose, pose.isCalibrated else {
            return "Calibrazione: resta seduto 10 s"
        }
        return String(format: "Neutro dinamico (P85): %.1f°", pose.neutralPitchBaseline)
    }

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

        handle(events: engine.process(sample, pose: pose))

        if engine.state == .magneticNudge {
            overlay.update(intensity: engine.nudgeIntensity, lateralBias: engine.lateralBias)
            audio.updatePull(roll: engine.smoothRoll)
        }
        // Only assign when changed, so SwiftUI does not redraw at 50 Hz.
        if deviation != engine.currentDeviation { deviation = engine.currentDeviation }
        if flowScore != engine.metrics.dailyDeskFlowScore { flowScore = engine.metrics.dailyDeskFlowScore }
        if streak != engine.metrics.postureRecoveryStreak { streak = engine.metrics.postureRecoveryStreak }
    }

    private func handle(events: [DeskPostureEvent]) {
        for event in events {
            switch event {
            case let .stateChanged(_, newState):
                state = newState
                if newState == .magneticNudge {
                    overlay.update(intensity: engine.nudgeIntensity, lateralBias: engine.lateralBias)
                    overlay.show()
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
