import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("Pipeline B and auto-routing")
struct ParallelPipelineRouterTests {
    @Test("Cranial cross-coupling counts head-still curl reps")
    func cranialCountsReps() {
        let result = CranialCrossCouplingEngine().analyze(SyntheticSignals.curlSet(reps: 10))
        #expect(result.reps.count == 10)
        #expect(result.rejectedPeakCount == 0)
        #expect(result.reps.allSatisfy { (0.015...0.06).contains($0.amplitudeG) })
    }

    @Test("Whole-body squats exceed the tension band and are rejected by Pipeline B")
    func cranialRejectsSquats() {
        let result = CranialCrossCouplingEngine().analyze(SyntheticSignals.squatSet(reps: 3))
        #expect(result.reps.isEmpty)
        #expect(result.rejectedPeakCount >= 3)
    }

    @Test("Squats route to Pipeline A within 1.5 s")
    func squatsRouteToKinematic() async {
        let analysis = await ParallelPipelineRouter().analyze(
            SyntheticSignals.squatSet(reps: 3),
            context: SetContext(exerciseName: "Back Squat", loadKg: 100)
        )
        #expect(analysis.selectedPipeline == .kinematicZUPT)
        #expect(analysis.classification.verticalExcursionMeters > 0.12)
        #expect(analysis.classification.confidence == 1)
        #expect(analysis.totalReps == 3)

        let set = analysis.makeExerciseSet()
        #expect(set.autoDetectedPipeline == .kinematicZUPT)
        #expect(set.totalReps == 3)
        #expect(set.cleanReps == 3)
        #expect(set.meanConcentricVelocity != nil)
        #expect(set.thighRomDegrees != nil)
        #expect((0...100).contains(set.flowScore))
    }

    @Test("Curls route to Pipeline B within 1.5 s")
    func curlsRouteToCranial() async {
        let analysis = await ParallelPipelineRouter().analyze(
            SyntheticSignals.curlSet(reps: 10),
            context: SetContext(exerciseName: "Dumbbell Curl", side: .left, loadKg: 14)
        )
        #expect(analysis.selectedPipeline == .cranialCrossCoupling)
        #expect(analysis.classification.verticalExcursionMeters < 0.08)
        #expect(analysis.classification.isPeriodicActive)
        #expect(analysis.totalReps == 10)
        #expect(analysis.makeExerciseSet().meanConcentricVelocity == nil)
    }

    @Test("Femur rotation > 25° forces Pipeline A even with little vertical travel")
    func thighRotationForcesKinematic() {
        let router = ParallelPipelineRouter()
        let shallow = SyntheticSignals.squatSet(reps: 2, depth: 0.06)
        let samples = shallow.map { sample -> IMUSample in
            var copy = sample
            copy.pocketThighPitch = (sample.pocketThighPitch ?? 0) * 0.5
            return copy
        }
        let analysis = router.analyzeSynchronously(samples, context: SetContext(exerciseName: "Leg Extension"))
        #expect(analysis.classification.verticalExcursionMeters < 0.12)
        #expect((analysis.classification.thighRotationDegrees ?? 0) > 25)
        #expect(analysis.selectedPipeline == .kinematicZUPT)
    }

    @Test("Ring buffer snapshot feeds the router directly")
    func routerReadsBuffer() async {
        let buffer = RetroactiveRingBuffer(duration: 30)
        buffer.append(contentsOf: SyntheticSignals.curlSet(reps: 6))
        let analysis = await ParallelPipelineRouter().analyze(buffer, context: SetContext(exerciseName: "Lateral Raise"))
        #expect(analysis.selectedPipeline == .cranialCrossCoupling)
        #expect(analysis.totalReps == 6)
    }

    @Test("Async and synchronous analysis agree")
    func asyncMatchesSync() async {
        let samples = SyntheticSignals.squatSet(reps: 2)
        let router = ParallelPipelineRouter()
        let context = SetContext(exerciseName: "Squat")
        let concurrent = await router.analyze(samples, context: context)
        let sequential = router.analyzeSynchronously(samples, context: context)
        #expect(concurrent.flow == sequential.flow)
        #expect(concurrent.classification == sequential.classification)
    }
}

@Suite("Flow Score")
struct FlowScoreEngineTests {
    let engine = FlowScoreEngine()

    func rep(duration: Double, pitch: Double = 2, roll: Double = 1) -> RepKinematics {
        RepKinematics(startTime: 0, endTime: duration, maxPitchDeviation: pitch, maxRollDeviation: roll)
    }

    @Test("Clean, symmetric, rhythmic set scores 100")
    func perfectSet() {
        let score = engine.score(reps: Array(repeating: rep(duration: 2), count: 8), symmetryRatio: 1)
        #expect(score.flowScore == 100)
        #expect(score.cleanReps == 8)
    }

    @Test("Sagittal cheating and lateral compensation reduce Purity")
    func cheatingPenalised() {
        let reps = [rep(duration: 2), rep(duration: 2, pitch: 17), rep(duration: 2, roll: 10)]
        let score = engine.score(reps: reps, symmetryRatio: nil)
        // Rep purities: 100, 100 - 5·4 = 80, 100 - 2·5 = 90 → 90.
        #expect(abs(score.purity - 90) < 1e-9)
        #expect(score.cleanReps == 1)
        #expect(score.flowScore == 95)
    }

    @Test("Symmetry (30%) and Tempo Rhythm (20%) weights")
    func weights() {
        let steady = engine.score(reps: Array(repeating: rep(duration: 2), count: 4), symmetryRatio: 0.5)
        #expect(steady.flowScore == 85)
        let erratic = engine.score(reps: [rep(duration: 1), rep(duration: 3)], symmetryRatio: 1)
        // CV = 0.5 ≥ 0.3 → tempo 0 → 50 + 30.
        #expect(erratic.flowScore == 80)
    }

    @Test("Empty set scores 0")
    func emptySet() {
        #expect(engine.score(reps: [], symmetryRatio: 1).flowScore == 0)
    }
}
