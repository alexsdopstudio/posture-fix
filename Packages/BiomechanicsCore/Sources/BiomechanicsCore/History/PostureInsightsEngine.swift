import Foundation

/// One hour of today's posture, for the timeline.
public struct HourlyPosture: Equatable, Sendable {
    public var hour: Int
    public var judgedMinutes: Double
    /// In axis or in the tolerated zone in between.
    public var goodShare: Double
    public var deviatedShare: Double

    public init(hour: Int, judgedMinutes: Double, goodShare: Double, deviatedShare: Double) {
        self.hour = hour
        self.judgedMinutes = judgedMinutes
        self.goodShare = goodShare
        self.deviatedShare = deviatedShare
    }
}

/// The side the head habitually leans to.
public struct LateralHabit: Equatable, Sendable {
    public var side: LimbSide
    /// Share of all lateral-lean time spent on `side`.
    public var share: Double
    public var leanMinutes: Double

    public init(side: LimbSide, share: Double, leanMinutes: Double) {
        self.side = side
        self.share = share
        self.leanMinutes = leanMinutes
    }
}

/// Posture gets worse after sitting for `thresholdMinutes` without a break.
public struct FatigueInsight: Equatable, Sendable {
    public var thresholdMinutes: Int
    public var deviatedShareBefore: Double
    public var deviatedShareAfter: Double

    public init(thresholdMinutes: Int, deviatedShareBefore: Double, deviatedShareAfter: Double) {
        self.thresholdMinutes = thresholdMinutes
        self.deviatedShareBefore = deviatedShareBefore
        self.deviatedShareAfter = deviatedShareAfter
    }
}

/// The single most actionable suggestion for today.
public enum PostureTip: Equatable, Sendable {
    /// Posture drops after this long seated: break a few minutes earlier.
    case takeBreaks(everyMinutes: Int)
    /// Habitual lean to one side: usually a monitor or mouse off-centre.
    case centerWorkspace(leaningTo: LimbSide)
    /// Head habitually below the neutral: raise the screen / bring the chin back.
    case raiseScreen(habitualPitch: Double)
    /// One hour stands out: plan a micro-break there.
    case microBreak(atHour: Int)
    case keepGoing
}

public struct PostureInsights: Equatable, Sendable {
    public var trackedMinutes: Double
    public var judgedMinutes: Double
    /// Share of judged time in axis or in between (no deviation).
    public var goodShare: Double?
    public var hourly: [HourlyPosture]
    /// Typical pitch vs the neutral today, degrees (negative = head lower).
    public var habitualPitch: Double?
    /// Typical pitch over the previous 7 days, for comparison.
    public var previousHabitualPitch: Double?
    public var lateralHabit: LateralHabit?
    public var worstHour: HourlyPosture?
    public var fatigue: FatigueInsight?
    public var nudges: Int
    public var recoveries: Int
    public var meanRecoveryLatencySeconds: Double?
    public var tip: PostureTip?

    public static let empty = PostureInsights(
        trackedMinutes: 0, judgedMinutes: 0, goodShare: nil, hourly: [], habitualPitch: nil,
        previousHabitualPitch: nil, lateralHabit: nil, worstHour: nil, fatigue: nil,
        nudges: 0, recoveries: 0, meanRecoveryLatencySeconds: nil, tip: nil
    )
}

/// Turns the recorded history into a few plain insights. Every insight has a minimum
/// amount of data behind it and is omitted otherwise: no conclusions from two minutes.
public struct PostureInsightsEngine: Sendable {
    public struct Configuration: Sendable {
        /// Judged minutes needed before habitual posture is reported.
        public var minimumMinutesForHabit: Double = 10
        /// Judged minutes needed in the previous days for the comparison.
        public var minimumMinutesForComparison: Double = 30
        /// Minutes count toward medians only with at least this much judged time.
        public var minimumJudgedSecondsPerMinute: Double = 20
        public var minimumLeanMinutes: Double = 3
        /// A side must hold this share of lean time to be called a habit.
        public var lateralHabitShare: Double = 0.7
        public var minimumMinutesPerHour: Double = 5
        public var worstHourMinimumShare: Double = 0.15
        public var meaningfulDifference: Double = 0.1
        public var fatigueThresholds: [Int] = [20, 30, 45, 60]
        public var minimumMinutesPerFatigueSide: Double = 10
        /// Habitual pitch below this suggests raising the screen.
        public var lowHeadDegrees: Double = -6
        public var keepGoingShare: Double = 0.85

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func insights(
        today: [PostureMinuteRecord],
        todayEvents: [PostureEventRecord],
        previousDays: [PostureMinuteRecord],
        calendar: Calendar = .current
    ) -> PostureInsights {
        let c = configuration
        let categories = today.reduce(PostureCategorySeconds()) { $0 + $1.categories }
        let judged = categories.total
        let hourly = hourlyPosture(today, calendar: calendar)
        let latencies = todayEvents.compactMap(\.recoveryLatencySeconds)

        var insights = PostureInsights(
            trackedMinutes: today.reduce(0) { $0 + $1.trackedSeconds } / 60,
            judgedMinutes: judged / 60,
            goodShare: judged > 0 ? (categories.inAxis + categories.between) / judged : nil,
            hourly: hourly,
            habitualPitch: habitualPitch(today, minimumMinutes: c.minimumMinutesForHabit),
            previousHabitualPitch: habitualPitch(previousDays, minimumMinutes: c.minimumMinutesForComparison),
            lateralHabit: lateralHabit(categories),
            worstHour: worstHour(hourly),
            fatigue: fatigue(today),
            nudges: todayEvents.filter { $0.kind == .nudgeStarted }.count,
            recoveries: todayEvents.filter { $0.kind == .recovered }.count,
            meanRecoveryLatencySeconds: latencies.isEmpty ? nil : Statistics.mean(latencies),
            tip: nil
        )
        insights.tip = tip(for: insights)
        return insights
    }

    // MARK: - Individual insights

    private func habitualPitch(_ minutes: [PostureMinuteRecord], minimumMinutes: Double) -> Double? {
        let usable = minutes.filter { $0.judgedSeconds >= configuration.minimumJudgedSecondsPerMinute }
        let judgedMinutes = usable.reduce(0) { $0 + $1.judgedSeconds } / 60
        guard judgedMinutes >= minimumMinutes else { return nil }
        return Statistics.percentile(usable.map(\.pitchMedian), 50)
    }

    private func lateralHabit(_ categories: PostureCategorySeconds) -> LateralHabit? {
        let lean = categories.leftLean + categories.rightLean
        guard lean / 60 >= configuration.minimumLeanMinutes else { return nil }
        let side: LimbSide = categories.leftLean >= categories.rightLean ? .left : .right
        let share = max(categories.leftLean, categories.rightLean) / lean
        guard share >= configuration.lateralHabitShare else { return nil }
        return LateralHabit(side: side, share: share, leanMinutes: lean / 60)
    }

    private func hourlyPosture(_ minutes: [PostureMinuteRecord], calendar: Calendar) -> [HourlyPosture] {
        let grouped = Dictionary(grouping: minutes) { calendar.component(.hour, from: $0.minuteStart) }
        return grouped.keys.sorted().compactMap { hour in
            let categories = grouped[hour, default: []].reduce(PostureCategorySeconds()) { $0 + $1.categories }
            let judged = categories.total
            guard judged > 0 else { return nil }
            return HourlyPosture(
                hour: hour,
                judgedMinutes: judged / 60,
                goodShare: (categories.inAxis + categories.between) / judged,
                deviatedShare: categories.deviated / judged
            )
        }
    }

    private func worstHour(_ hourly: [HourlyPosture]) -> HourlyPosture? {
        let eligible = hourly.filter { $0.judgedMinutes >= configuration.minimumMinutesPerHour }
        guard eligible.count >= 2,
              let worst = eligible.max(by: { $0.deviatedShare < $1.deviatedShare }),
              let best = eligible.min(by: { $0.deviatedShare < $1.deviatedShare }),
              worst.deviatedShare >= configuration.worstHourMinimumShare,
              worst.deviatedShare - best.deviatedShare >= configuration.meaningfulDifference
        else { return nil }
        return worst
    }

    /// Picks the sitting-time threshold with the largest worsening, if any is meaningful.
    private func fatigue(_ minutes: [PostureMinuteRecord]) -> FatigueInsight? {
        var best: FatigueInsight?
        for threshold in configuration.fatigueThresholds {
            let limit = Double(threshold) * 60
            let before = minutes.filter { $0.sittingSessionSeconds < limit }.reduce(PostureCategorySeconds()) { $0 + $1.categories }
            let after = minutes.filter { $0.sittingSessionSeconds >= limit }.reduce(PostureCategorySeconds()) { $0 + $1.categories }
            guard before.total / 60 >= configuration.minimumMinutesPerFatigueSide,
                  after.total / 60 >= configuration.minimumMinutesPerFatigueSide
            else { continue }
            let candidate = FatigueInsight(
                thresholdMinutes: threshold,
                deviatedShareBefore: before.deviated / before.total,
                deviatedShareAfter: after.deviated / after.total
            )
            let gain = candidate.deviatedShareAfter - candidate.deviatedShareBefore
            guard gain >= configuration.meaningfulDifference else { continue }
            if best.map({ gain > $0.deviatedShareAfter - $0.deviatedShareBefore }) ?? true {
                best = candidate
            }
        }
        return best
    }

    /// One suggestion, most actionable first.
    private func tip(for insights: PostureInsights) -> PostureTip? {
        if let fatigue = insights.fatigue {
            return .takeBreaks(everyMinutes: max(10, fatigue.thresholdMinutes - 5))
        }
        if let lateral = insights.lateralHabit {
            return .centerWorkspace(leaningTo: lateral.side)
        }
        if let pitch = insights.habitualPitch, pitch <= configuration.lowHeadDegrees {
            return .raiseScreen(habitualPitch: pitch)
        }
        if let worst = insights.worstHour {
            return .microBreak(atHour: worst.hour)
        }
        if insights.judgedMinutes >= configuration.minimumMinutesForHabit,
           let good = insights.goodShare, good >= configuration.keepGoingShare {
            return .keepGoing
        }
        return nil
    }
}
