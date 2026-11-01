import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("Posture history")
struct PostureHistoryTests {
    /// 2026-11-02 09:00:00 UTC, a minute boundary.
    let origin = Date(timeIntervalSince1970: 1_793_610_000)
    let calibration = UUID()

    func snapshot(
        at seconds: Double,
        pitch: Double = 0,
        roll: Double = 0,
        deviation: PostureDeviation = .none,
        inAxis: Bool = true,
        state: DeskPostureState = .neutral,
        gated: Bool = false,
        seated: Bool = true,
        app: String? = nil
    ) -> PostureSampleSnapshot {
        PostureSampleSnapshot(
            date: origin.addingTimeInterval(seconds),
            pitchDeviation: pitch,
            roll: roll,
            deviation: deviation,
            isInAxis: inAxis,
            state: state,
            isMotionGated: gated,
            isSeated: seated,
            calibrationID: calibration,
            frontmostApp: app
        )
    }

    /// Feeds `seconds` of 50 Hz samples starting at `start`, returning finished minutes.
    func feed(_ aggregator: PostureMinuteAggregator, from start: Double, seconds: Double,
              _ make: (Double) -> PostureSampleSnapshot) -> [PostureMinuteRecord] {
        (0..<Int(seconds * 50)).compactMap { aggregator.add(make(start + Double($0) * 0.02)) }
    }

    @Test("One record per wall-clock minute with categories, states and pitch percentiles")
    func minuteAggregation() throws {
        let aggregator = PostureMinuteAggregator()
        // 09:00: 30 s in axis, 20 s tech neck (-15°), 10 s moving.
        var finished = feed(aggregator, from: 0, seconds: 30) { snapshot(at: $0, pitch: -1) }
        finished += feed(aggregator, from: 30, seconds: 20) {
            snapshot(at: $0, pitch: -15, deviation: .techNeck, inAxis: false, state: .drifting)
        }
        finished += feed(aggregator, from: 50, seconds: 10) { snapshot(at: $0, pitch: -40, gated: true) }
        #expect(finished.isEmpty)
        // The first sample of 09:01 closes 09:00.
        finished += feed(aggregator, from: 60, seconds: 1) { snapshot(at: $0) }

        let minute = try #require(finished.first)
        #expect(finished.count == 1)
        #expect(minute.minuteStart == origin)
        #expect(abs(minute.trackedSeconds - 60) < 0.05)
        #expect(abs(minute.movingSeconds - 10) < 0.05)
        #expect(abs(minute.categories.inAxis - 30) < 0.05)
        #expect(abs(minute.categories.techNeck - 20) < 0.05)
        #expect(abs(minute.judgedSeconds - 50) < 0.05)
        #expect(abs(minute.states.drifting - 20) < 0.05)
        // Moving samples never enter the pitch statistics.
        #expect(minute.pitchMedian == -1)
        #expect(minute.pitchP10 == -15)
        #expect(minute.calibrationID == calibration)
        #expect(minute.frontmostApp == nil)
    }

    @Test("Short minutes are dropped; flush closes the minute in progress")
    func flushAndMinimum() {
        let aggregator = PostureMinuteAggregator()
        _ = feed(aggregator, from: 0, seconds: 3) { snapshot(at: $0) }
        #expect(aggregator.flush() == nil)
        _ = feed(aggregator, from: 60, seconds: 10) { snapshot(at: $0) }
        #expect(aggregator.flush()?.minuteStart == origin.addingTimeInterval(60))
    }

    @Test("Dominant frontmost app and mean roll")
    func dominantApp() throws {
        let aggregator = PostureMinuteAggregator()
        _ = feed(aggregator, from: 0, seconds: 40) { snapshot(at: $0, roll: -4, app: "com.tinyspeck.slackmacgap") }
        _ = feed(aggregator, from: 40, seconds: 20) { snapshot(at: $0, roll: 2, app: "com.apple.dt.Xcode") }
        let minute = try #require(aggregator.flush())
        #expect(minute.frontmostApp == "com.tinyspeck.slackmacgap")
        #expect(abs(minute.rollMean - -2) < 0.05)
    }

    @Test("Sitting session survives short breaks and resets after 2 minutes away")
    func sittingSession() throws {
        let aggregator = PostureMinuteAggregator()
        _ = feed(aggregator, from: 0, seconds: 300) { snapshot(at: $0) }
        // 30 s unseated is not a break.
        _ = feed(aggregator, from: 300, seconds: 30) { snapshot(at: $0, seated: false) }
        _ = feed(aggregator, from: 330, seconds: 29) { snapshot(at: $0) }
        let before = try #require(aggregator.flush())
        #expect(abs(before.sittingSessionSeconds - 359) < 0.1)

        // AirPods off for 10 minutes: a new session starts.
        _ = feed(aggregator, from: 960, seconds: 30) { snapshot(at: $0) }
        let after = try #require(aggregator.flush())
        #expect(abs(after.sittingSessionSeconds - 30) < 0.1)
    }

    @Test("Events: nudge, recovery latency, relapse duration")
    func eventTracker() {
        let tracker = PostureEventTracker()
        let t0 = origin
        var records = tracker.handle([.stateChanged(from: .drifting, to: .magneticNudge)], at: t0, calibrationID: calibration)
        records += tracker.handle([.stateChanged(from: .magneticNudge, to: .dopamineRecovery), .recovered(streak: 1)],
                                  at: t0.addingTimeInterval(8), calibrationID: calibration)
        records += tracker.handle([.stateChanged(from: .dopamineRecovery, to: .neutral)], at: t0.addingTimeInterval(10), calibrationID: calibration)
        records += tracker.handle([.stateChanged(from: .neutral, to: .drifting)], at: t0.addingTimeInterval(128), calibrationID: calibration)
        #expect(records.map(\.kind) == [.nudgeStarted, .recovered, .relapsed])
        #expect(records[1].recoveryLatencySeconds == 8)
        #expect(records[2].secondsSinceRecovery == 120)
    }

    @Test("File store round-trips minutes and events per day")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = FilePostureHistoryStore(directory: directory, calendar: calendar)

        let aggregator = PostureMinuteAggregator()
        var minutes = feed(aggregator, from: 0, seconds: 180) { snapshot(at: $0, pitch: -3) }
        minutes += [aggregator.flush()].compactMap { $0 }
        #expect(minutes.count == 3)
        try store.append(Array(minutes.prefix(2)))
        try store.append(Array(minutes.suffix(1)))
        try store.append([PostureEventRecord(date: origin.addingTimeInterval(30), kind: .nudgeStarted)])

        let loaded = try store.minutes(from: origin, to: origin.addingTimeInterval(3_600))
        #expect(loaded == minutes)
        #expect(try store.events(from: origin, to: origin.addingTimeInterval(60)).count == 1)
        #expect(try store.minutes(from: origin.addingTimeInterval(60), to: origin.addingTimeInterval(120)).count == 1)

        // A torn last line (crash mid-write) is skipped, not fatal.
        let file = directory.appendingPathComponent("2026-11-02/minutes.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"minuteStart\":".utf8))
        try handle.close()
        #expect(try store.minutes(from: origin, to: origin.addingTimeInterval(3_600)).count == 3)
    }

    @Test("Retention compacts days older than 90 days into one summary each")
    func retention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = FilePostureHistoryStore(directory: directory, calendar: calendar)

        let aggregator = PostureMinuteAggregator()
        var minutes = feed(aggregator, from: 0, seconds: 120) {
            snapshot(at: $0, pitch: -12, deviation: .techNeck, inAxis: false)
        }
        minutes += [aggregator.flush()].compactMap { $0 }
        try store.append(minutes)
        try store.append([
            PostureEventRecord(date: origin, kind: .nudgeStarted),
            PostureEventRecord(date: origin.addingTimeInterval(6), kind: .recovered, recoveryLatencySeconds: 6),
        ])

        // 89 days later the minutes are still kept.
        try store.applyRetention(now: origin.addingTimeInterval(89 * 86_400))
        #expect(try store.minutes(from: origin, to: origin.addingTimeInterval(86_400)).count == 2)
        #expect(try store.daySummaries().isEmpty)

        // 91 days later they become one daily summary; running again does not duplicate it.
        try store.applyRetention(now: origin.addingTimeInterval(91 * 86_400))
        try store.applyRetention(now: origin.addingTimeInterval(92 * 86_400))
        #expect(try store.minutes(from: origin, to: origin.addingTimeInterval(86_400)).isEmpty)
        let summaries = try store.daySummaries()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(abs(summary.trackedMinutes - 2) < 0.01)
        #expect(summary.pitchMedian == -12)
        #expect(summary.nudges == 1)
        #expect(summary.recoveries == 1)
        #expect(summary.meanRecoveryLatencySeconds == 6)
        #expect(summary.deskFlowScore == 0)
    }
}
