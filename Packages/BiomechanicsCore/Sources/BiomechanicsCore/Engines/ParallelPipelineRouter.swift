import Foundation

public struct PipelineClassification: Equatable, Sendable {
    public var category: PipelineCategory
    /// Peak-to-peak vertical travel (m) in the first 1.5 s after motion onset.
    public var verticalExcursionMeters: Double
    /// Femur rotation (degrees) in the same window, when a pocket phone is present.
    public var thighRotationDegrees: Double?
    public var isPeriodicActive: Bool
    /// 1 when a decision threshold was clearly crossed, 0.5 in the 8-12 cm grey zone.
    public var confidence: Double
}

/// What the lifter declared (or the watch inferred) about the set.
public struct SetContext: Sendable {
    public var exerciseName: String
    public var side: LimbSide
    public var loadKg: Double
    /// Mean rep duration of the opposite side, used for Pace Matching symmetry.
    public var contralateralMeanRepSeconds: Double?
    /// Mean concentric velocity of the opposite side, m/s.
    public var contralateralMeanConcentricVelocity: Double?

    public init(
        exerciseName: String,
        side: LimbSide = .bilateral,
        loadKg: Double = 0,
        contralateralMeanRepSeconds: Double? = nil,
        contralateralMeanConcentricVelocity: Double? = nil
    ) {
        self.exerciseName = exerciseName
        self.side = side
        self.loadKg = loadKg
        self.contralateralMeanRepSeconds = contralateralMeanRepSeconds
        self.contralateralMeanConcentricVelocity = contralateralMeanConcentricVelocity
    }
}

public struct SetAnalysis: Sendable {
    public var context: SetContext
    public var classification: PipelineClassification
    public var kinematic: KinematicZUPTResult
    public var cranial: CranialCrossCouplingResult
    public var reps: [RepKinematics]
    public var flow: FlowScoreBreakdown
    public var bilateralSymmetryRatio: Double?

    public var selectedPipeline: PipelineCategory { classification.category }
    public var totalReps: Int { reps.count }
    public var meanRepSeconds: Double? { reps.isEmpty ? nil : Statistics.mean(reps.map(\.duration)) }
    public var maxPitchDeviation: Double? { reps.map(\.maxPitchDeviation).max() }
    public var maxRollDeviation: Double? { reps.map(\.maxRollDeviation).max() }

    /// Persistable record for SwiftData / CloudKit.
    public func makeExerciseSet() -> ExerciseSet {
        let isKinematic = selectedPipeline == .kinematicZUPT
        return ExerciseSet(
            exerciseName: context.exerciseName,
            autoDetectedPipeline: selectedPipeline,
            side: context.side,
            loadKg: context.loadKg,
            totalReps: totalReps,
            cleanReps: flow.cleanReps,
            flowScore: flow.flowScore,
            meanConcentricVelocity: isKinematic ? kinematic.meanConcentricVelocity : nil,
            averageEccentricSeconds: isKinematic ? kinematic.averageEccentricSeconds : nil,
            thighRomDegrees: kinematic.thighRomDegrees,
            bilateralSymmetryRatio: bilateralSymmetryRatio,
            maxPitchDeviation: maxPitchDeviation,
            maxRollDeviation: maxRollDeviation
        )
    }
}

/// Gym Pocket Mode: runs Pipeline A (ZUPT kinematics) and Pipeline B (cranial
/// cross-coupling) in parallel over the retroactive buffer, picks the right one from
/// the first 1.5 s of motion, and scores the set.
public struct ParallelPipelineRouter: Sendable {
    public struct Configuration: Sendable {
        public var classificationWindowSeconds: Double = 1.5
        public var kinematicExcursionMeters: Double = 0.12
        public var cranialExcursionMeters: Double = 0.08
        public var kinematicThighRotationDegrees: Double = 25
        /// Mean |a_vert - bias| (m/s²) over ~150 ms that marks motion onset.
        public var onsetAccelerationThreshold: Double = 0.1
        /// Share of the classification window that must sit in the tension band.
        public var periodicActiveFraction: Double = 0.5

        public init() {}
    }

    public var configuration: Configuration
    public var kinematicEngine: KinematicZUPTEngine
    public var cranialEngine: CranialCrossCouplingEngine
    public var flowScoreEngine: FlowScoreEngine

    public init(
        configuration: Configuration = Configuration(),
        kinematicEngine: KinematicZUPTEngine = KinematicZUPTEngine(),
        cranialEngine: CranialCrossCouplingEngine = CranialCrossCouplingEngine(),
        flowScoreEngine: FlowScoreEngine = FlowScoreEngine()
    ) {
        self.configuration = configuration
        self.kinematicEngine = kinematicEngine
        self.cranialEngine = cranialEngine
        self.flowScoreEngine = flowScoreEngine
    }

    /// Both pipelines run concurrently; the classification then selects one.
    public func analyze(_ samples: [IMUSample], context: SetContext) async -> SetAnalysis {
        let kinematicEngine = self.kinematicEngine
        let cranialEngine = self.cranialEngine
        async let kinematic = kinematicEngine.analyze(samples)
        async let cranial = cranialEngine.analyze(samples)
        return assemble(samples: samples, context: context, kinematic: await kinematic, cranial: await cranial)
    }

    /// Same result as `analyze(_:context:)` without structured concurrency.
    public func analyzeSynchronously(_ samples: [IMUSample], context: SetContext) -> SetAnalysis {
        assemble(
            samples: samples,
            context: context,
            kinematic: kinematicEngine.analyze(samples),
            cranial: cranialEngine.analyze(samples)
        )
    }

    public func analyze(_ buffer: RetroactiveRingBuffer, context: SetContext) async -> SetAnalysis {
        await analyze(buffer.snapshot(), context: context)
    }

    public func classify(
        _ samples: [IMUSample],
        kinematic: KinematicZUPTResult,
        cranial: CranialCrossCouplingResult
    ) -> PipelineClassification {
        let c = configuration
        let acceleration = kinematic.verticalAcceleration
        let timestamps = kinematic.timestamps

        // Accelerometer bias from the first stillness window (the rest before the set).
        var bias = 0.0
        if let firstWindow = kinematic.zuptWindows.first {
            let end = min(firstWindow.endIndex, firstWindow.startIndex + 24)
            bias = Statistics.mean(Array(acceleration[firstWindow.startIndex...end]))
        }

        guard let onset = motionOnset(acceleration: acceleration, timestamps: timestamps, bias: bias) else {
            return PipelineClassification(category: .cranialCrossCoupling, verticalExcursionMeters: 0,
                                          thighRotationDegrees: nil, isPeriodicActive: false, confidence: 0)
        }
        let windowEnd = timestamps.lastIndex { $0 <= timestamps[onset] + c.classificationWindowSeconds } ?? onset

        var velocity = 0.0
        var position = 0.0
        var lowest = 0.0
        var highest = 0.0
        if windowEnd > onset {
            for i in (onset + 1)...windowEnd {
                let dt = timestamps[i] - timestamps[i - 1]
                let previousVelocity = velocity
                velocity += 0.5 * ((acceleration[i] - bias) + (acceleration[i - 1] - bias)) * dt
                position += 0.5 * (velocity + previousVelocity) * dt
                lowest = min(lowest, position)
                highest = max(highest, position)
            }
        }
        let excursion = highest - lowest

        let thighPitches = samples[onset...windowEnd].compactMap(\.pocketThighPitch)
        let thighRotation = thighPitches.isEmpty ? nil : (thighPitches.max()! - thighPitches.min()!)
        let periodic = cranial.activeFraction(
            in: onset..<(windowEnd + 1),
            band: cranialEngine.configuration.tensionBandG
        ) >= c.periodicActiveFraction

        let category: PipelineCategory
        let confidence: Double
        if excursion > c.kinematicExcursionMeters || (thighRotation ?? 0) > c.kinematicThighRotationDegrees {
            category = .kinematicZUPT
            confidence = 1
        } else if excursion < c.cranialExcursionMeters && periodic {
            category = .cranialCrossCoupling
            confidence = 1
        } else {
            category = periodic ? .cranialCrossCoupling : .kinematicZUPT
            confidence = 0.5
        }
        return PipelineClassification(
            category: category,
            verticalExcursionMeters: excursion,
            thighRotationDegrees: thighRotation,
            isPeriodicActive: periodic,
            confidence: confidence
        )
    }

    // MARK: - Private

    private func assemble(
        samples: [IMUSample],
        context: SetContext,
        kinematic: KinematicZUPTResult,
        cranial: CranialCrossCouplingResult
    ) -> SetAnalysis {
        let classification = classify(samples, kinematic: kinematic, cranial: cranial)
        let reps: [RepKinematics]
        let ownVelocity: Double?
        switch classification.category {
        case .kinematicZUPT:
            reps = kinematic.reps.map(\.kinematics)
            ownVelocity = kinematic.meanConcentricVelocity
        case .cranialCrossCoupling:
            reps = cranial.reps.map(\.kinematics)
            ownVelocity = nil
        }
        let ownRepSeconds = reps.isEmpty ? nil : Statistics.mean(reps.map(\.duration))
        let symmetry = symmetryRatio(
            context: context,
            ownRepSeconds: ownRepSeconds,
            ownVelocity: ownVelocity
        )
        return SetAnalysis(
            context: context,
            classification: classification,
            kinematic: kinematic,
            cranial: cranial,
            reps: reps,
            flow: flowScoreEngine.score(reps: reps, symmetryRatio: symmetry),
            bilateralSymmetryRatio: symmetry
        )
    }

    /// Pace Matching: min/max of each side's mean rep duration (and MCV when both are known).
    private func symmetryRatio(context: SetContext, ownRepSeconds: Double?, ownVelocity: Double?) -> Double? {
        guard context.side != .bilateral else { return nil }
        var ratios: [Double] = []
        if let own = ownRepSeconds, let other = context.contralateralMeanRepSeconds, own > 0, other > 0 {
            ratios.append(min(own, other) / max(own, other))
        }
        if let own = ownVelocity, let other = context.contralateralMeanConcentricVelocity, own > 0, other > 0 {
            ratios.append(min(own, other) / max(own, other))
        }
        return ratios.isEmpty ? nil : Statistics.mean(ratios)
    }

    private func motionOnset(acceleration: [Double], timestamps: [TimeInterval], bias: Double) -> Int? {
        let n = acceleration.count
        guard n > 1, let first = timestamps.first, let last = timestamps.last, last > first else { return nil }
        let sampleRate = Double(n - 1) / (last - first)
        let width = max(3, Int((0.15 * sampleRate).rounded()))
        guard n >= width else { return nil }
        var sum = acceleration[0..<width].reduce(0) { $0 + abs($1 - bias) }
        if sum / Double(width) > configuration.onsetAccelerationThreshold { return 0 }
        for i in width..<n {
            sum += abs(acceleration[i] - bias) - abs(acceleration[i - width] - bias)
            if sum / Double(width) > configuration.onsetAccelerationThreshold {
                return i - width + 1
            }
        }
        return nil
    }
}
