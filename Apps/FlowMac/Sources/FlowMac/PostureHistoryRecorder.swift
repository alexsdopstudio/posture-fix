import AppKit
import BiomechanicsCore
import Foundation
import Observation

/// Records the posture history (phase 1 of docs/posture-history-design.md): one aggregate
/// per minute of real AirPods data plus nudge, recovery, relapse and calibration events.
/// Everything stays in ~/Library/Application Support/Flow/History.
@MainActor
@Observable
final class PostureHistoryRecorder {
    /// Real AirPods time recorded today, seconds.
    private(set) var todayRecordedSeconds: Double = 0
    /// Plain-language insights from today and the previous 7 days, refreshed every minute.
    private(set) var insights = PostureInsights.empty

    /// Opt-in: also store the bundle id of the app in the foreground. Off by default.
    var recordsFrontmostApp: Bool {
        didSet { UserDefaults.standard.set(recordsFrontmostApp, forKey: Self.frontmostPreferenceKey) }
    }

    var historyDirectory: URL { store.directory }

    private static let frontmostPreferenceKey = "recordsFrontmostApp"

    @ObservationIgnored private let store = FilePostureHistoryStore()
    @ObservationIgnored private let aggregator = PostureMinuteAggregator()
    @ObservationIgnored private let tracker = PostureEventTracker()
    @ObservationIgnored private let insightsEngine = PostureInsightsEngine()
    @ObservationIgnored private var todayMinutes: [PostureMinuteRecord] = []
    @ObservationIgnored private var todayEvents: [PostureEventRecord] = []
    @ObservationIgnored private var previousDays: [PostureMinuteRecord] = []
    @ObservationIgnored private var calibrationID: UUID?
    @ObservationIgnored private var frontmostApp: String?
    @ObservationIgnored private var currentDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        recordsFrontmostApp = UserDefaults.standard.bool(forKey: Self.frontmostPreferenceKey)
        frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostApp = app?.bundleIdentifier }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        perform("retention") { try store.applyRetention(now: Date()) }
        loadToday()
    }

    /// One judged sample of real AirPods data.
    func record(_ engine: DeskPostureEngine, pose: HeadPose, isInAxis: Bool) {
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

    func record(_ events: [DeskPostureEvent]) {
        guard !events.isEmpty else { return }
        let records = tracker.handle(events, at: Date(), calibrationID: calibrationID)
        guard !records.isEmpty else { return }
        perform("events") { try store.append(records) }
        todayEvents += records
        refreshInsights()
    }

    /// A new reference attitude: later minutes belong to this calibration.
    func recordCalibration(usedCamera: Bool, unmetCues: [PostureCue]) {
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
    func flush() {
        if let minute = aggregator.flush() {
            save(minute)
        }
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
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
            NSLog("FlowMac: posture history (\(what)) failed: \(error.localizedDescription)")
        }
    }
}
