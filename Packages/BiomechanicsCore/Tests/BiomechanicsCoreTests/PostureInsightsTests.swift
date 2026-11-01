import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("Posture insights")
struct PostureInsightsTests {
    let engine = PostureInsightsEngine()
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-11-02 09:00 UTC.
    let morning = Date(timeIntervalSince1970: 1_793_610_000)

    /// A fully judged minute: `deviated` seconds of the given kind, the rest in axis.
    func minute(
        at offsetMinutes: Int,
        pitch: Double = -2,
        deviated: Double = 0,
        kind: PostureDeviation = .techNeck,
        sitting: Double? = nil
    ) -> PostureMinuteRecord {
        var categories = PostureCategorySeconds()
        categories.inAxis = 60 - deviated
        switch kind {
        case .techNeck: categories.techNeck = deviated
        case .turtle: categories.turtle = deviated
        case .leftLean: categories.leftLean = deviated
        case .rightLean: categories.rightLean = deviated
        case .none: categories.between = deviated
        }
        return PostureMinuteRecord(
            minuteStart: morning.addingTimeInterval(Double(offsetMinutes) * 60),
            trackedSeconds: 60, movingSeconds: 0,
            pitchMean: pitch, pitchMedian: pitch, pitchP10: pitch - 3, pitchP90: pitch + 3,
            rollMean: 0, categories: categories, states: PostureStateSeconds(),
            sittingSessionSeconds: sitting ?? Double(offsetMinutes) * 60,
            calibrationID: nil, frontmostApp: nil
        )
    }

    @Test("Too little data: no conclusions, no tip")
    func notEnoughData() {
        let insights = engine.insights(today: (0..<5).map { minute(at: $0) }, todayEvents: [], previousDays: [], calendar: calendar)
        #expect(insights.trackedMinutes == 5)
        #expect(insights.habitualPitch == nil)
        #expect(insights.worstHour == nil)
        #expect(insights.fatigue == nil)
        #expect(insights.tip == nil)
    }

    @Test("Good day: habitual pitch, hourly timeline, keep going")
    func goodDay() throws {
        let insights = engine.insights(today: (0..<30).map { minute(at: $0, pitch: -1) }, todayEvents: [], previousDays: [], calendar: calendar)
        #expect(insights.habitualPitch == -1)
        #expect(insights.goodShare == 1)
        let hour = try #require(insights.hourly.first)
        #expect(insights.hourly.count == 1)
        #expect(hour.hour == 9)
        #expect(hour.judgedMinutes == 30)
        #expect(insights.tip == .keepGoing)
    }

    @Test("Posture drops after 45 min seated: break every 40 min")
    func fatigue() throws {
        // 45 good minutes, then 30 minutes with 30 s of tech neck each.
        let today = (0..<45).map { minute(at: $0) } + (45..<75).map { minute(at: $0, deviated: 30) }
        let insights = engine.insights(today: today, todayEvents: [], previousDays: [], calendar: calendar)
        let fatigue = try #require(insights.fatigue)
        #expect(fatigue.thresholdMinutes == 45)
        #expect(fatigue.deviatedShareBefore == 0)
        #expect(fatigue.deviatedShareAfter == 0.5)
        #expect(insights.tip == .takeBreaks(everyMinutes: 40))
    }

    @Test("Lateral habit needs a clear majority on one side")
    func lateralHabit() throws {
        let left = (0..<12).map { minute(at: $0, deviated: 20, kind: .leftLean, sitting: 0) }
        let right = (12..<14).map { minute(at: $0, deviated: 20, kind: .rightLean, sitting: 0) }
        let habit = try #require(engine.insights(today: left + right, todayEvents: [], previousDays: [], calendar: calendar).lateralHabit)
        #expect(habit.side == .left)
        #expect(abs(habit.share - 12.0 / 14) < 1e-9)

        let balanced = (0..<10).map { minute(at: $0, deviated: 20, kind: .leftLean, sitting: 0) }
            + (10..<20).map { minute(at: $0, deviated: 20, kind: .rightLean, sitting: 0) }
        #expect(engine.insights(today: balanced, todayEvents: [], previousDays: [], calendar: calendar).lateralHabit == nil)
    }

    @Test("Low habitual head suggests raising the screen; worst hour stands out")
    func lowHeadAndWorstHour() throws {
        let nine = (0..<20).map { minute(at: $0, pitch: -8, sitting: 0) }
        let ten = (60..<80).map { minute(at: $0, pitch: -8, deviated: 24, sitting: 0) }
        let insights = engine.insights(today: nine + ten, todayEvents: [], previousDays: [], calendar: calendar)
        #expect(insights.habitualPitch == -8)
        #expect(insights.worstHour?.hour == 10)
        #expect(insights.tip == .raiseScreen(habitualPitch: -8))
    }

    @Test("Comparison with previous days and nudge response")
    func comparisonAndNudges() {
        let previous = (0..<40).map { minute(at: $0 - 1_440, pitch: -7) }
        let events = [
            PostureEventRecord(date: morning, kind: .nudgeStarted),
            PostureEventRecord(date: morning.addingTimeInterval(9), kind: .recovered, recoveryLatencySeconds: 9),
            PostureEventRecord(date: morning.addingTimeInterval(600), kind: .nudgeStarted),
            PostureEventRecord(date: morning.addingTimeInterval(605), kind: .recovered, recoveryLatencySeconds: 5),
        ]
        let insights = engine.insights(today: (0..<20).map { minute(at: $0, pitch: -3) }, todayEvents: events,
                                       previousDays: previous, calendar: calendar)
        #expect(insights.previousHabitualPitch == -7)
        #expect(insights.habitualPitch == -3)
        #expect(insights.nudges == 2)
        #expect(insights.recoveries == 2)
        #expect(insights.meanRecoveryLatencySeconds == 7)
    }
}
