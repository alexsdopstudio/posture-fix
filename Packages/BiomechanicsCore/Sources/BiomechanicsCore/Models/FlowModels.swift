import Foundation
import SwiftData

/// Which analysis pipeline produced a set's metrics.
public enum PipelineCategory: String, Codable, CaseIterable, Sendable {
    /// Large vertical excursion lifts (squat, deadlift, lunge): ZUPT velocity integration.
    case kinematicZUPT
    /// Head-still lifts (curl, lateral raise, bench): cranial cross-coupling rep counting.
    case cranialCrossCoupling
}

public enum LimbSide: String, Codable, CaseIterable, Sendable {
    case bilateral
    case left
    case right

    public var opposite: LimbSide {
        switch self {
        case .bilateral: return .bilateral
        case .left: return .right
        case .right: return .left
        }
    }
}

// CloudKit compatibility rules applied to every model below:
// every stored property has a default value, relationships are optional,
// no `@Attribute(.unique)` constraints, enums are persisted as raw strings.

#if FLOW_SWIFTDATA_MACROS_UNAVAILABLE

// Command Line Tools toolchains do not ship the SwiftData macro plugin.
// These plain classes keep the exact same API so the engines and tests build;
// any Xcode toolchain compiles the `@Model` variants below instead.

public final class DailyPostureSummary {
    public var date: Date = Date()
    public var totalTrackedMinutes: Double = 0
    public var techNeckAndTurtleMinutes: Double = 0
    public var leftLeanMinutes: Double = 0
    public var rightLeanMinutes: Double = 0
    public var longestStaticStretchMinutes: Double = 0
    /// 85th percentile of seated pitch (degrees), the dynamic neutral reference.
    public var dynamicNeutralPitchBaseline: Double = 0
    /// 0-100.
    public var dailyDeskFlowScore: Int = 100
    public var postureRecoveryStreak: Int = 0

    public init(
        date: Date = Date(),
        totalTrackedMinutes: Double = 0,
        techNeckAndTurtleMinutes: Double = 0,
        leftLeanMinutes: Double = 0,
        rightLeanMinutes: Double = 0,
        longestStaticStretchMinutes: Double = 0,
        dynamicNeutralPitchBaseline: Double = 0,
        dailyDeskFlowScore: Int = 100,
        postureRecoveryStreak: Int = 0
    ) {
        self.date = date
        self.totalTrackedMinutes = totalTrackedMinutes
        self.techNeckAndTurtleMinutes = techNeckAndTurtleMinutes
        self.leftLeanMinutes = leftLeanMinutes
        self.rightLeanMinutes = rightLeanMinutes
        self.longestStaticStretchMinutes = longestStaticStretchMinutes
        self.dynamicNeutralPitchBaseline = dynamicNeutralPitchBaseline
        self.dailyDeskFlowScore = dailyDeskFlowScore
        self.postureRecoveryStreak = postureRecoveryStreak
    }
}

public final class WorkoutSession {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var appliedDeskAdaptations: [String] = []
    public var sessionFlowScore: Int = 0
    public var sets: [ExerciseSet]? = []

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appliedDeskAdaptations: [String] = [],
        sessionFlowScore: Int = 0,
        sets: [ExerciseSet] = []
    ) {
        self.id = id
        self.date = date
        self.appliedDeskAdaptations = appliedDeskAdaptations
        self.sessionFlowScore = sessionFlowScore
        self.sets = sets
    }
}

public final class ExerciseSet {
    public var id: UUID = UUID()
    public var exerciseName: String = ""
    public var autoDetectedPipelineRaw: String = PipelineCategory.kinematicZUPT.rawValue
    public var sideRaw: String = LimbSide.bilateral.rawValue
    public var loadKg: Double = 0
    public var totalReps: Int = 0
    public var cleanReps: Int = 0
    /// 0-100, the primary metric surfaced in the UI.
    public var flowScore: Int = 0
    public var meanConcentricVelocity: Double?
    public var averageEccentricSeconds: Double?
    public var thighRomDegrees: Double?
    public var bilateralSymmetryRatio: Double?
    public var maxPitchDeviation: Double?
    public var maxRollDeviation: Double?
    public var session: WorkoutSession?

    public init(
        id: UUID = UUID(),
        exerciseName: String,
        autoDetectedPipeline: PipelineCategory,
        side: LimbSide = .bilateral,
        loadKg: Double = 0,
        totalReps: Int = 0,
        cleanReps: Int = 0,
        flowScore: Int = 0,
        meanConcentricVelocity: Double? = nil,
        averageEccentricSeconds: Double? = nil,
        thighRomDegrees: Double? = nil,
        bilateralSymmetryRatio: Double? = nil,
        maxPitchDeviation: Double? = nil,
        maxRollDeviation: Double? = nil
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.autoDetectedPipelineRaw = autoDetectedPipeline.rawValue
        self.sideRaw = side.rawValue
        self.loadKg = loadKg
        self.totalReps = totalReps
        self.cleanReps = cleanReps
        self.flowScore = flowScore
        self.meanConcentricVelocity = meanConcentricVelocity
        self.averageEccentricSeconds = averageEccentricSeconds
        self.thighRomDegrees = thighRomDegrees
        self.bilateralSymmetryRatio = bilateralSymmetryRatio
        self.maxPitchDeviation = maxPitchDeviation
        self.maxRollDeviation = maxRollDeviation
    }
}

#else

@Model
public final class DailyPostureSummary {
    public var date: Date = Date()
    public var totalTrackedMinutes: Double = 0
    public var techNeckAndTurtleMinutes: Double = 0
    public var leftLeanMinutes: Double = 0
    public var rightLeanMinutes: Double = 0
    public var longestStaticStretchMinutes: Double = 0
    /// 85th percentile of seated pitch (degrees), the dynamic neutral reference.
    public var dynamicNeutralPitchBaseline: Double = 0
    /// 0-100.
    public var dailyDeskFlowScore: Int = 100
    public var postureRecoveryStreak: Int = 0

    public init(
        date: Date = Date(),
        totalTrackedMinutes: Double = 0,
        techNeckAndTurtleMinutes: Double = 0,
        leftLeanMinutes: Double = 0,
        rightLeanMinutes: Double = 0,
        longestStaticStretchMinutes: Double = 0,
        dynamicNeutralPitchBaseline: Double = 0,
        dailyDeskFlowScore: Int = 100,
        postureRecoveryStreak: Int = 0
    ) {
        self.date = date
        self.totalTrackedMinutes = totalTrackedMinutes
        self.techNeckAndTurtleMinutes = techNeckAndTurtleMinutes
        self.leftLeanMinutes = leftLeanMinutes
        self.rightLeanMinutes = rightLeanMinutes
        self.longestStaticStretchMinutes = longestStaticStretchMinutes
        self.dynamicNeutralPitchBaseline = dynamicNeutralPitchBaseline
        self.dailyDeskFlowScore = dailyDeskFlowScore
        self.postureRecoveryStreak = postureRecoveryStreak
    }
}

@Model
public final class WorkoutSession {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var appliedDeskAdaptations: [String] = []
    public var sessionFlowScore: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.session)
    public var sets: [ExerciseSet]? = []

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appliedDeskAdaptations: [String] = [],
        sessionFlowScore: Int = 0,
        sets: [ExerciseSet] = []
    ) {
        self.id = id
        self.date = date
        self.appliedDeskAdaptations = appliedDeskAdaptations
        self.sessionFlowScore = sessionFlowScore
        self.sets = sets
    }
}

@Model
public final class ExerciseSet {
    public var id: UUID = UUID()
    public var exerciseName: String = ""
    public var autoDetectedPipelineRaw: String = PipelineCategory.kinematicZUPT.rawValue
    public var sideRaw: String = LimbSide.bilateral.rawValue
    public var loadKg: Double = 0
    public var totalReps: Int = 0
    public var cleanReps: Int = 0
    /// 0-100, the primary metric surfaced in the UI.
    public var flowScore: Int = 0
    public var meanConcentricVelocity: Double?
    public var averageEccentricSeconds: Double?
    public var thighRomDegrees: Double?
    public var bilateralSymmetryRatio: Double?
    public var maxPitchDeviation: Double?
    public var maxRollDeviation: Double?
    public var session: WorkoutSession?

    public init(
        id: UUID = UUID(),
        exerciseName: String,
        autoDetectedPipeline: PipelineCategory,
        side: LimbSide = .bilateral,
        loadKg: Double = 0,
        totalReps: Int = 0,
        cleanReps: Int = 0,
        flowScore: Int = 0,
        meanConcentricVelocity: Double? = nil,
        averageEccentricSeconds: Double? = nil,
        thighRomDegrees: Double? = nil,
        bilateralSymmetryRatio: Double? = nil,
        maxPitchDeviation: Double? = nil,
        maxRollDeviation: Double? = nil
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.autoDetectedPipelineRaw = autoDetectedPipeline.rawValue
        self.sideRaw = side.rawValue
        self.loadKg = loadKg
        self.totalReps = totalReps
        self.cleanReps = cleanReps
        self.flowScore = flowScore
        self.meanConcentricVelocity = meanConcentricVelocity
        self.averageEccentricSeconds = averageEccentricSeconds
        self.thighRomDegrees = thighRomDegrees
        self.bilateralSymmetryRatio = bilateralSymmetryRatio
        self.maxPitchDeviation = maxPitchDeviation
        self.maxRollDeviation = maxRollDeviation
    }
}

#endif

// MARK: - Typed accessors shared by both variants

extension ExerciseSet {
    public var autoDetectedPipeline: PipelineCategory {
        get { PipelineCategory(rawValue: autoDetectedPipelineRaw) ?? .kinematicZUPT }
        set { autoDetectedPipelineRaw = newValue.rawValue }
    }

    public var side: LimbSide {
        get { LimbSide(rawValue: sideRaw) ?? .bilateral }
        set { sideRaw = newValue.rawValue }
    }
}

extension WorkoutSession {
    /// Mean of the sets' Flow Scores, rounded; 0 for an empty session.
    public func recomputeSessionFlowScore() {
        let scores = (sets ?? []).map(\.flowScore)
        guard !scores.isEmpty else {
            sessionFlowScore = 0
            return
        }
        sessionFlowScore = Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
    }
}

extension DailyPostureSummary {
    /// Copies the live desk metrics into this persisted daily row.
    public func apply(_ metrics: DeskPostureMetrics) {
        totalTrackedMinutes = metrics.totalTrackedSeconds / 60
        techNeckAndTurtleMinutes = metrics.techNeckAndTurtleSeconds / 60
        leftLeanMinutes = metrics.leftLeanSeconds / 60
        rightLeanMinutes = metrics.rightLeanSeconds / 60
        longestStaticStretchMinutes = metrics.longestStaticStretchSeconds / 60
        dynamicNeutralPitchBaseline = metrics.neutralPitchBaseline
        dailyDeskFlowScore = metrics.dailyDeskFlowScore
        postureRecoveryStreak = metrics.postureRecoveryStreak
    }
}
