import Foundation

public struct FlowScoreBreakdown: Equatable, Sendable {
    /// 0-100, weight 50%.
    public var purity: Double
    /// 0-100, weight 30%.
    public var symmetry: Double
    /// 0-100, weight 20%.
    public var tempoRhythm: Double
    public var cleanReps: Int
    /// The single number shown to the user.
    public var flowScore: Int
}

/// Condenses technique into one 0-100 integer:
/// Purity 50% (sagittal cheat Δθ > 12°, lateral compensation |Δϕ| > 8°),
/// Symmetry L/R 30%, Tempo Rhythm 20% (rep-duration consistency).
public struct FlowScoreEngine: Sendable {
    public struct Configuration: Sendable {
        public var sagittalCheatDegrees: Double = 12
        public var lateralCompensationDegrees: Double = 8
        /// Purity points lost per degree beyond each threshold.
        public var sagittalPenaltyPerDegree: Double = 4
        public var lateralPenaltyPerDegree: Double = 5
        /// Rep-duration coefficient of variation at which Tempo Rhythm reaches 0.
        public var tempoCoefficientOfVariationLimit: Double = 0.3
        public var purityWeight: Double = 0.5
        public var symmetryWeight: Double = 0.3
        public var tempoWeight: Double = 0.2

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// - Parameter symmetryRatio: min/max ratio of the two sides (1 = perfect); nil for bilateral work.
    public func score(reps: [RepKinematics], symmetryRatio: Double?) -> FlowScoreBreakdown {
        guard !reps.isEmpty else {
            return FlowScoreBreakdown(purity: 0, symmetry: 0, tempoRhythm: 0, cleanReps: 0, flowScore: 0)
        }
        let c = configuration
        var cleanReps = 0
        let repPurity = reps.map { rep -> Double in
            let sagittalExcess = max(0, rep.maxPitchDeviation - c.sagittalCheatDegrees)
            let lateralExcess = max(0, abs(rep.maxRollDeviation) - c.lateralCompensationDegrees)
            if sagittalExcess == 0 && lateralExcess == 0 { cleanReps += 1 }
            let penalty = sagittalExcess * c.sagittalPenaltyPerDegree + lateralExcess * c.lateralPenaltyPerDegree
            return max(0, 100 - penalty)
        }
        let purity = Statistics.mean(repPurity)
        let symmetry = 100 * max(0, min(1, symmetryRatio ?? 1))
        let durations = reps.map(\.duration)
        let cv = durations.count > 1 ? Statistics.coefficientOfVariation(durations) : 0
        let tempo = 100 * max(0, 1 - cv / c.tempoCoefficientOfVariationLimit)
        let total = purity * c.purityWeight + symmetry * c.symmetryWeight + tempo * c.tempoWeight
        return FlowScoreBreakdown(
            purity: purity,
            symmetry: symmetry,
            tempoRhythm: tempo,
            cleanReps: cleanReps,
            flowScore: Int(max(0, min(100, total)).rounded())
        )
    }
}
