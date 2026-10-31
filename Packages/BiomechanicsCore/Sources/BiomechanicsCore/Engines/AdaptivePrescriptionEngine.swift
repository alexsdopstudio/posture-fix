import Foundation

/// Yesterday's (or today's) desk load, the input of the Desk -> Gym bridge.
public struct DeskLoadSnapshot: Equatable, Sendable {
    public var techNeckAndTurtleMinutes: Double
    public var leftLeanMinutes: Double
    public var rightLeanMinutes: Double
    /// Longest continuous stretch without voluntary movement.
    public var staticRigidityMinutes: Double

    public init(techNeckAndTurtleMinutes: Double = 0, leftLeanMinutes: Double = 0, rightLeanMinutes: Double = 0, staticRigidityMinutes: Double = 0) {
        self.techNeckAndTurtleMinutes = techNeckAndTurtleMinutes
        self.leftLeanMinutes = leftLeanMinutes
        self.rightLeanMinutes = rightLeanMinutes
        self.staticRigidityMinutes = staticRigidityMinutes
    }

    public init(summary: DailyPostureSummary) {
        self.init(
            techNeckAndTurtleMinutes: summary.techNeckAndTurtleMinutes,
            leftLeanMinutes: summary.leftLeanMinutes,
            rightLeanMinutes: summary.rightLeanMinutes,
            staticRigidityMinutes: summary.longestStaticStretchMinutes
        )
    }
}

public struct PlannedExercise: Equatable, Sendable {
    public var name: String
    public var sets: Int
    public var isUnilateral: Bool
    /// Side to train first on unilateral work; nil means the lifter chooses.
    public var startingSide: LimbSide?
    /// The second side must match the first side's rep tempo.
    public var paceMatching: Bool

    public init(name: String, sets: Int, isUnilateral: Bool = false, startingSide: LimbSide? = nil, paceMatching: Bool = false) {
        self.name = name
        self.sets = sets
        self.isUnilateral = isUnilateral
        self.startingSide = startingSide
        self.paceMatching = paceMatching
    }
}

public struct CorrectiveExercise: Equatable, Sendable {
    public var name: String
    public var sets: Int
    public var side: LimbSide
    /// Isometric hold at end range per rep, seconds.
    public var holdSeconds: Double?
    public var reason: String
}

/// Mobility work slotted into a rest interval of the main workout.
public struct RestIntervalInsert: Equatable, Sendable {
    /// 0-based index of the rest interval (0 = after the first working set).
    public var restIndex: Int
    public var name: String
    public var durationSeconds: Double
}

public enum DeskAdaptation: String, CaseIterable, Sendable {
    case techNeckPullAparts
    case lateralLeanCarry
    case weakSideFirstPaceMatching
    case staticRigidityCouchStretch
}

public struct WorkoutPrescription: Equatable, Sendable {
    public var preActivation: [CorrectiveExercise]
    public var plan: [PlannedExercise]
    public var restInserts: [RestIntervalInsert]
    public var adaptations: [DeskAdaptation]
    /// Weak side identified from desk lean (the side opposite the lean).
    public var weakSide: LimbSide?

    /// Tags stored on `WorkoutSession.appliedDeskAdaptations`.
    public var adaptationTags: [String] {
        adaptations.map { adaptation in
            switch adaptation {
            case .lateralLeanCarry, .weakSideFirstPaceMatching:
                return "\(adaptation.rawValue).\(weakSide?.rawValue ?? LimbSide.bilateral.rawValue)"
            default:
                return adaptation.rawValue
            }
        }
    }
}

/// Desk <-> Gym bridge: turns the day's posture debt into pre-workout corrective work.
public struct AdaptivePrescriptionEngine: Sendable {
    public struct Configuration: Sendable {
        public var techNeckMinutesThreshold: Double = 90
        public var lateralLeanMinutesThreshold: Double = 60
        public var staticRigidityMinutesThreshold: Double = 180
        public var couchStretchSeconds: Double = 40
        /// How many of the first rest intervals receive the couch stretch.
        public var couchStretchRestCount: Int = 2

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func prescribe(desk: DeskLoadSnapshot, plan: [PlannedExercise]) -> WorkoutPrescription {
        let c = configuration
        var preActivation: [CorrectiveExercise] = []
        var adaptations: [DeskAdaptation] = []
        var adaptedPlan = plan
        var restInserts: [RestIntervalInsert] = []
        var weakSide: LimbSide?

        if desk.techNeckAndTurtleMinutes > c.techNeckMinutesThreshold {
            preActivation.append(CorrectiveExercise(
                name: "Face Pulls / Band Pull-Aparts",
                sets: 2,
                side: .bilateral,
                holdSeconds: 2,
                reason: "Tech neck + turtle \(Int(desk.techNeckAndTurtleMinutes)) min: retract scapulae, re-extend the thoracic spine"
            ))
            adaptations.append(.techNeckPullAparts)
        }

        let leftExceeded = desk.leftLeanMinutes > c.lateralLeanMinutesThreshold
        let rightExceeded = desk.rightLeanMinutes > c.lateralLeanMinutesThreshold
        if leftExceeded || rightExceeded {
            // The dominant lean decides; the opposite side is the one to load.
            let lean: LimbSide = desk.leftLeanMinutes >= desk.rightLeanMinutes ? .left : .right
            let side = lean.opposite
            weakSide = side
            let leanMinutes = Int(max(desk.leftLeanMinutes, desk.rightLeanMinutes))
            preActivation.append(CorrectiveExercise(
                name: "Suitcase Carry / Side Plank",
                sets: 2,
                side: side,
                holdSeconds: nil,
                reason: "\(lean.rawValue.capitalized) lean \(leanMinutes) min: load the \(side.rawValue) lateral chain"
            ))
            adaptations.append(.lateralLeanCarry)

            var touchedUnilateral = false
            for index in adaptedPlan.indices where adaptedPlan[index].isUnilateral {
                adaptedPlan[index].startingSide = side
                adaptedPlan[index].paceMatching = true
                touchedUnilateral = true
            }
            if touchedUnilateral {
                adaptations.append(.weakSideFirstPaceMatching)
            }
        }

        if desk.staticRigidityMinutes > c.staticRigidityMinutesThreshold {
            let totalSets = adaptedPlan.reduce(0) { $0 + $1.sets }
            let restCount = min(c.couchStretchRestCount, max(0, totalSets - 1))
            restInserts = (0..<restCount).map {
                RestIntervalInsert(restIndex: $0, name: "Couch Stretch", durationSeconds: c.couchStretchSeconds)
            }
            if !restInserts.isEmpty {
                adaptations.append(.staticRigidityCouchStretch)
            }
        }

        return WorkoutPrescription(
            preActivation: preActivation,
            plan: adaptedPlan,
            restInserts: restInserts,
            adaptations: adaptations,
            weakSide: weakSide
        )
    }

    /// Creates the session record with the applied adaptations already tagged.
    public func makeSession(for prescription: WorkoutPrescription, date: Date = Date()) -> WorkoutSession {
        WorkoutSession(date: date, appliedDeskAdaptations: prescription.adaptationTags)
    }
}
