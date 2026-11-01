#if !FLOW_SWIFTDATA_MACROS_UNAVAILABLE
import Foundation
import SwiftData
import Testing
@testable import BiomechanicsCore

/// Runs only with a toolchain that ships the SwiftData macros (Xcode).
@Suite("SwiftData models")
@MainActor
struct SwiftDataModelTests {
    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: DailyPostureSummary.self, WorkoutSession.self, ExerciseSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("A session with its sets round-trips, and deleting it cascades to the sets")
    func sessionRoundTripAndCascade() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let session = WorkoutSession(appliedDeskAdaptations: ["techNeckPullAparts"])
        context.insert(session)
        session.sets = [
            ExerciseSet(exerciseName: "Back Squat", autoDetectedPipeline: .kinematicZUPT, loadKg: 100, totalReps: 5, flowScore: 90, meanConcentricVelocity: 0.62),
            ExerciseSet(exerciseName: "Curl", autoDetectedPipeline: .cranialCrossCoupling, side: .left, totalReps: 10, flowScore: 72),
        ]
        session.recomputeSessionFlowScore()
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let stored = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(stored.sessionFlowScore == 81)
        #expect(stored.appliedDeskAdaptations == ["techNeckPullAparts"])
        let sets = try context.fetch(FetchDescriptor<ExerciseSet>(sortBy: [SortDescriptor(\.exerciseName)]))
        #expect(sets.map(\.exerciseName) == ["Back Squat", "Curl"])
        #expect(sets.last?.side == .left)
        #expect(sets.last?.autoDetectedPipeline == .cranialCrossCoupling)
        #expect(sets.first?.session?.id == stored.id)

        context.delete(stored)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ExerciseSet>()).isEmpty)
    }

    @Test("Daily summary persists the desk metrics")
    func dailySummary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var metrics = DeskPostureMetrics()
        metrics.totalTrackedSeconds = 7_200
        metrics.techNeckAndTurtleSeconds = 1_800
        metrics.postureRecoveryStreak = 3
        let summary = DailyPostureSummary()
        summary.apply(metrics)
        context.insert(summary)
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<DailyPostureSummary>()).first)
        #expect(stored.totalTrackedMinutes == 120)
        #expect(stored.techNeckAndTurtleMinutes == 30)
        #expect(stored.dailyDeskFlowScore == 75)
        #expect(stored.postureRecoveryStreak == 3)
    }
}
#endif
