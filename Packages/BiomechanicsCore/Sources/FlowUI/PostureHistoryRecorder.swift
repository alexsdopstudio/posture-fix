import BiomechanicsCore
import Foundation
import Observation

/// Records the posture history (phase 1 of docs/posture-history-design.md): one aggregate
/// per minute of real AirPods data plus nudge, recovery, relapse and calibration events.
/// Everything stays in the app's Application Support/Flow/History, on this device only.
/// Shared by the Mac and iPhone apps; the host forwards platform events (frontmost app,
/// termination) to it.
@MainActor
@Observable
public final class PostureHistoryRecorder {
    /// Real AirPods time recorded today, seconds.
    public private(set) var todayRecordedSeconds: Double = 0
    /// Plain-language insights from today and the previous 7 days, refreshed every minute.
    public private(set) var insights = PostureInsights.empty

    /// Opt-in: also store the bundle id of the app in the foreground. Off by default.
    public var recordsFrontmostApp: Bool {
        didSet { UserDefaults.standard.set(recordsFrontmostApp, forKey: Self.frontmostPreferenceKey) }
    }

    /// Set by the host app (macOS only) when the foreground app changes.
    @ObservationIgnored public var frontmostApp: String?

    public var historyDirectory: URL { store.directory }

    /// Today's desk load, the input of the gym prescription.
    public var todayDeskLoad: DeskLoadSnapshot {
        let categories = todayMinutes.reduce(PostureCategorySeconds()) { $0 + $1.categories }
        return DeskLoadSnapshot(
            techNeckAndTurtleMinutes: (categories.techNeck + categories.turtle) / 60,
            leftLeanMinutes: categories.leftLean / 60,
            rightLeanMinutes: categories.rightLean / 60,
            staticRigidityMinutes: (todayMinutes.map(\.sittingSessionSeconds).max() ?? 0) / 60
        )
    }

    private static let frontmostPreferenceKey = "recordsFrontmostApp"

    @ObservationIgnored private let store = FilePostureHistoryStore()
    @ObservationIgnored private let aggregator = PostureMinuteAggregator()
    @ObservationIgnored private let tracker = PostureEventTracker()
    @ObservationIgnored private let insightsEngine = PostureInsightsEngine()
    @ObservationIgnored private var todayMinutes: [PostureMinuteRecord] = []
    @ObservationIgnored private var todayEvents: [PostureEventRecord] = []
    @ObservationIgnored private var previousDays: [PostureMinuteRecord] = []
    @ObservationIgnored private var calibrationID: UUID?
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())

    public init() {
        recordsFrontmostApp = UserDefaults.standard.bool(forKey: Self.frontmostPreferenceKey)
        perform("retention") { try store.applyRetention(now: Date()) }
        loadToday()
    }

    /// One judged sample of real AirPods data.
    public func record(_ engine: DeskPostureEngine, pose: HeadPose, isInAxis: Bool) {
        rollOverDayIfNeeded()
        let snapshot = PostureSampleSnapshot(
            date: Date(),
            pitchDeviation: engine.pitchDeviation,
            roll: engine.smoothRoll,
            deviation: engine.currentDeviation,
            isInAxis: isInAxis,
            state: engine.state,
            isMotionGated: engine.isMotionGated,
            isSeated: pose.isSeated,
            calibrationID: calibrationID,
            frontmostApp: recordsFrontmostApp ? frontmostApp : nil
        )
        if let minute = aggregator.add(snapshot) {
            save(minute)
        }
    }

    public func record(_ events: [DeskPostureEvent]) {
        guard !events.isEmpty else { return }
        let records = tracker.handle(events, at: Date(), calibrationID: calibrationID)
        guard !records.isEmpty else { return }
        perform("events") { try store.append(records) }
        todayEvents += records
        refreshInsights()
    }

    /// A new reference attitude: later minutes belong to this calibration.
    public func recordCalibration(usedCamera: Bool, unmetCues: [PostureCue]) {
        let id = UUID()
        calibrationID = id
        let event = PostureEventRecord(
            date: Date(),
            kind: .calibrated,
            usedCamera: usedCamera,
            unmetCues: unmetCues.filter { !$0.isSatisfied }.map(\.kind.rawValue),
            calibrationID: id
        )
        perform("calibration") { try store.append([event]) }
    }

    /// Closes the minute in progress (AirPods removed, app quitting).
    public func flush() {
        if let minute = aggregator.flush() {
            save(minute)
        }
    }

    private func save(_ minute: PostureMinuteRecord) {
        perform("minutes") { try store.append([minute]) }
        if Calendar.current.isDate(minute.minuteStart, inSameDayAs: Date()) {
            todayMinutes.append(minute)
            todayRecordedSeconds += minute.trackedSeconds
            refreshInsights()
        }
    }

    private func rollOverDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != currentDay else { return }
        currentDay = today
        perform("retention") { try store.applyRetention(now: Date()) }
        loadToday()
    }

    private func loadToday() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date().addingTimeInterval(60)
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: start) ?? start
        todayMinutes = (try? store.minutes(from: start, to: end)) ?? []
        todayEvents = (try? store.events(from: start, to: end)) ?? []
        previousDays = (try? store.minutes(from: weekAgo, to: start)) ?? []
        todayRecordedSeconds = todayMinutes.reduce(0) { $0 + $1.trackedSeconds }
        refreshInsights()
    }

    private func refreshInsights() {
        insights = insightsEngine.insights(today: todayMinutes, todayEvents: todayEvents, previousDays: previousDays)
    }

    /// History must never break posture tracking: failures are logged, not thrown.
    private func perform(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            NSLog("Flow: posture history (\(what)) failed: \(error.localizedDescription)")
        }
    }
}
