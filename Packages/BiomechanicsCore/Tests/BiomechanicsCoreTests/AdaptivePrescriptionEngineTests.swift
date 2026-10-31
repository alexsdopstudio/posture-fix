import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("AdaptivePrescriptionEngine")
struct AdaptivePrescriptionEngineTests {
    let engine = AdaptivePrescriptionEngine()
    let plan = [
        PlannedExercise(name: "Back Squat", sets: 4),
        PlannedExercise(name: "Bulgarian Split Squat", sets: 3, isUnilateral: true),
        PlannedExercise(name: "One-Arm Row", sets: 3, isUnilateral: true),
    ]

    @Test("Clean desk day changes nothing")
    func noDebt() {
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(techNeckAndTurtleMinutes: 30, leftLeanMinutes: 20), plan: plan)
        #expect(prescription.preActivation.isEmpty)
        #expect(prescription.restInserts.isEmpty)
        #expect(prescription.adaptations.isEmpty)
        #expect(prescription.plan == plan)
    }

    @Test("Tech neck > 90 min injects 2 sets of Face Pulls / Band Pull-Aparts with a 2 s hold")
    func techNeck() throws {
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(techNeckAndTurtleMinutes: 95), plan: plan)
        let drill = try #require(prescription.preActivation.first)
        #expect(drill.name == "Face Pulls / Band Pull-Aparts")
        #expect(drill.sets == 2)
        #expect(drill.holdSeconds == 2)
        #expect(prescription.adaptationTags == ["techNeckPullAparts"])
    }

    @Test("Left lean > 60 min loads the right side and sets Weak-Side First + Pace Matching")
    func leftLean() throws {
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(leftLeanMinutes: 75), plan: plan)
        let carry = try #require(prescription.preActivation.first)
        #expect(carry.name == "Suitcase Carry / Side Plank")
        #expect(carry.side == .right)
        #expect(prescription.weakSide == .right)
        let unilateral = prescription.plan.filter(\.isUnilateral)
        #expect(unilateral.allSatisfy { $0.startingSide == .right && $0.paceMatching })
        #expect(prescription.plan.first?.startingSide == nil)
        #expect(prescription.adaptationTags == ["lateralLeanCarry.right", "weakSideFirstPaceMatching.right"])
    }

    @Test("Right lean > 60 min loads the left side; the dominant lean wins")
    func rightLeanDominates() {
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(leftLeanMinutes: 65, rightLeanMinutes: 120), plan: plan)
        #expect(prescription.weakSide == .left)
        #expect(prescription.preActivation.first?.side == .left)
    }

    @Test("Static rigidity > 3 h inserts 40 s Couch Stretch in the first rests")
    func staticRigidity() {
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(staticRigidityMinutes: 200), plan: plan)
        #expect(prescription.restInserts.count == 2)
        #expect(prescription.restInserts.map(\.restIndex) == [0, 1])
        #expect(prescription.restInserts.allSatisfy { $0.name == "Couch Stretch" && $0.durationSeconds == 40 })
        #expect(prescription.adaptations == [.staticRigidityCouchStretch])
    }

    @Test("All rules combine and tag the session")
    func combined() {
        let summary = DailyPostureSummary(
            techNeckAndTurtleMinutes: 120,
            leftLeanMinutes: 10,
            rightLeanMinutes: 70,
            longestStaticStretchMinutes: 190
        )
        let prescription = engine.prescribe(desk: DeskLoadSnapshot(summary: summary), plan: plan)
        #expect(prescription.preActivation.count == 2)
        #expect(prescription.adaptations == [.techNeckPullAparts, .lateralLeanCarry, .weakSideFirstPaceMatching, .staticRigidityCouchStretch])
        let session = engine.makeSession(for: prescription)
        #expect(session.appliedDeskAdaptations == [
            "techNeckPullAparts", "lateralLeanCarry.left", "weakSideFirstPaceMatching.left", "staticRigidityCouchStretch",
        ])
    }

    @Test("Session Flow Score is the mean of its sets")
    func sessionScore() {
        let session = WorkoutSession(sets: [
            ExerciseSet(exerciseName: "Squat", autoDetectedPipeline: .kinematicZUPT, flowScore: 90),
            ExerciseSet(exerciseName: "Curl", autoDetectedPipeline: .cranialCrossCoupling, side: .left, flowScore: 71),
        ])
        session.recomputeSessionFlowScore()
        #expect(session.sessionFlowScore == 81)
        #expect(session.sets?.last?.side == .left)
    }
}
