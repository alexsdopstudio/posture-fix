import BiomechanicsCore
import CoreMotion
import Foundation
import Observation
import SwiftData

/// Gym Pocket Mode: AirPods on the head, iPhone in the trouser pocket. The retroactive
/// buffer always keeps the last 5 s; the second rep fires Auto-Start and rep 1 is pulled
/// back from the buffer. The set ends after 3 s of stillness and is analysed by the
/// parallel pipeline router (ZUPT kinematics vs cranial cross-coupling).
@MainActor
@Observable
final class GymController {
    enum Phase: Equatable {
        case idle
        case listening
        case recording
        case analyzing
    }

    enum DemoSet {
        case squat
        case curl
    }

    static let exercises = ["Auto", "Squat", "Stacco", "Affondi", "Panca", "Curl", "Alzate laterali", "Rematore"]
    /// |a_vert - rest level| (m/s²) below which the body counts as still.
    static let stillnessThreshold = 0.25
    /// Stillness that ends a set.
    static let setEndStillSeconds: TimeInterval = 3
    static let maximumSetSeconds: TimeInterval = 120

    private(set) var phase: Phase = .idle
    private(set) var isSessionActive = false
    private(set) var prescription: WorkoutPrescription?
    private(set) var currentSession: WorkoutSession?
    private(set) var lastSet: ExerciseSet?
    private(set) var message: String?
    private(set) var hasPocketPhone = false

    var exerciseName = "Auto"
    var side: LimbSide = .bilateral
    var loadKg: Double = 20

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private let buffer = RetroactiveRingBuffer()
    @ObservationIgnored private var detector = RepAutoStartDetector()
    @ObservationIgnored private var recording: [IMUSample] = []
    @ObservationIgnored private var restLevel: Double?
    @ObservationIgnored private var stillSince: TimeInterval?
    @ObservationIgnored private let router = ParallelPipelineRouter()
    @ObservationIgnored private let pocket = PocketMotion()
    /// Last mean rep duration and MCV per exercise and side, for Pace Matching symmetry.
    @ObservationIgnored private var sideMemory: [String: (repSeconds: Double?, velocity: Double?)] = [:]

    // MARK: - Session

    func startSession(deskLoad: DeskLoadSnapshot, context: ModelContext) {
        let engine = AdaptivePrescriptionEngine()
        let plan = [PlannedExercise(name: "Esercizi unilaterali", sets: 3, isUnilateral: true)]
        let prescription = engine.prescribe(desk: deskLoad, plan: plan)
        let session = engine.makeSession(for: prescription)
        context.insert(session)
        try? context.save()

        self.context = context
        self.prescription = prescription
        currentSession = session
        lastSet = nil
        message = nil
        sideMemory = [:]
        isSessionActive = true
        pocket.start()
        hasPocketPhone = pocket.isAvailable
        listen()
    }

    func endSession() {
        currentSession?.recomputeSessionFlowScore()
        try? context?.save()
        isSessionActive = false
        phase = .idle
        recording = []
        pocket.stop()
        currentSession = nil
        prescription = nil
    }

    // MARK: - Live stream

    func ingest(_ sample: IMUSample, isSimulated: Bool) {
        guard isSessionActive, phase == .listening || phase == .recording else { return }
        var sample = sample
        sample.pocketThighPitch = pocket.thighPitch
        buffer.append(sample)

        switch phase {
        case .listening:
            if let trigger = detector.process(sample) {
                // Rep 2 just started: rep 1 is still in the 5 s buffer.
                recording = buffer.samples(from: trigger.captureStart, through: sample.timestamp)
                beginRecording()
            }
        case .recording:
            recording.append(sample)
            checkForSetEnd(sample)
        case .idle, .analyzing:
            break
        }
    }

    /// For lifts Auto-Start cannot see (very slow or continuous ones).
    func startSetManually() {
        guard phase == .listening else { return }
        recording = Array(buffer.snapshot().suffix(50))
        beginRecording()
    }

    func stopSetManually() {
        guard phase == .recording else { return }
        finishSet()
    }

    /// Simulator demo: runs a synthetic set through the same analysis.
    func simulateSet(_ kind: DemoSet) {
        guard isSessionActive, phase == .listening else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let samples: [IMUSample]
        switch kind {
        case .squat: samples = SyntheticWorkout.squatSet(reps: 5, seed: UInt64(start * 1000) % 10_000, startTime: start)
        case .curl: samples = SyntheticWorkout.curlSet(reps: 10, seed: UInt64(start * 1000) % 10_000, startTime: start)
        }
        analyze(samples)
    }

    // MARK: - Private

    private func listen() {
        phase = .listening
        detector.reset()
        buffer.removeAll()
        recording = []
    }

    private func beginRecording() {
        phase = .recording
        message = nil
        stillSince = nil
        let lead = recording.prefix(25).map(\.verticalAcceleration)
        restLevel = lead.isEmpty ? nil : Statistics.mean(lead)
    }

    private func checkForSetEnd(_ sample: IMUSample) {
        let level = restLevel ?? 0
        if abs(sample.verticalAcceleration - level) < Self.stillnessThreshold {
            let since = stillSince ?? sample.timestamp
            stillSince = since
            if sample.timestamp - since >= Self.setEndStillSeconds {
                finishSet()
                return
            }
        } else {
            stillSince = nil
        }
        if let first = recording.first, sample.timestamp - first.timestamp > Self.maximumSetSeconds {
            finishSet()
        }
    }

    private func finishSet() {
        let samples = recording
        recording = []
        analyze(samples)
    }

    private func analyze(_ samples: [IMUSample]) {
        phase = .analyzing
        let name = exerciseName
        let side = side
        let other = sideMemory[memoryKey(name, side.opposite)]
        let context = SetContext(
            exerciseName: name,
            side: side,
            loadKg: loadKg,
            contralateralMeanRepSeconds: side == .bilateral ? nil : other?.repSeconds,
            contralateralMeanConcentricVelocity: side == .bilateral ? nil : other?.velocity
        )
        let router = router
        Task {
            let analysis = await router.analyze(samples, context: context)
            self.store(analysis)
        }
    }

    private func store(_ analysis: SetAnalysis) {
        defer { listen() }
        guard analysis.totalReps > 0, let session = currentSession else {
            message = "Nessuna ripetizione riconosciuta in questa serie."
            return
        }
        let set = analysis.makeExerciseSet()
        if set.exerciseName == "Auto" {
            set.exerciseName = analysis.selectedPipeline == .kinematicZUPT ? "Multiarticolare" : "Isolamento (testa ferma)"
        }
        sideMemory[memoryKey(analysis.context.exerciseName, analysis.context.side)] = (
            analysis.meanRepSeconds,
            analysis.selectedPipeline == .kinematicZUPT ? analysis.kinematic.meanConcentricVelocity : nil
        )
        set.session = session
        session.sets = (session.sets ?? []) + [set]
        session.recomputeSessionFlowScore()
        try? self.context?.save()
        lastSet = set
        message = nil
    }

    private func memoryKey(_ name: String, _ side: LimbSide) -> String { "\(name)|\(side.rawValue)" }
}

/// The iPhone in the trouser pocket: its pitch is the femur angle.
@MainActor
final class PocketMotion {
    private let manager = CMMotionManager()
    private(set) var thighPitch: Double?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            MainActor.assumeIsolated {
                guard let motion else { return }
                self?.thighPitch = motion.attitude.pitch * 180 / .pi
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        thighPitch = nil
    }
}
