import Foundation

/// Persistence for the posture history. Swappable: JSON Lines files today,
/// SwiftData + CloudKit once the project builds with Xcode.
public protocol PostureHistoryStore: AnyObject {
    func append(_ minutes: [PostureMinuteRecord]) throws
    func append(_ events: [PostureEventRecord]) throws
    func minutes(from start: Date, to end: Date) throws -> [PostureMinuteRecord]
    func events(from start: Date, to end: Date) throws -> [PostureEventRecord]
    func daySummaries() throws -> [PostureDaySummary]
    /// Compacts per-minute data older than the retention window into daily summaries.
    func applyRetention(now: Date) throws
}

/// `<directory>/YYYY-MM-DD/minutes.jsonl`, `<directory>/YYYY-MM-DD/events.jsonl`
/// and `<directory>/summaries.jsonl`. Append-only; a torn last line is skipped on read.
public final class FilePostureHistoryStore: PostureHistoryStore {
    public let directory: URL
    public let minuteRetentionDays: Int
    private let calendar: Calendar
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dayFormatter: DateFormatter

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Flow/History", isDirectory: true)
    }

    public init(directory: URL = FilePostureHistoryStore.defaultDirectory, calendar: Calendar = .current, minuteRetentionDays: Int = 90) {
        self.directory = directory
        self.calendar = calendar
        self.minuteRetentionDays = minuteRetentionDays
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    public func append(_ minutes: [PostureMinuteRecord]) throws {
        for (day, records) in Dictionary(grouping: minutes, by: { dayKey($0.minuteStart) }) {
            try appendLines(records, to: dayDirectory(day).appendingPathComponent("minutes.jsonl"))
        }
    }

    public func append(_ events: [PostureEventRecord]) throws {
        for (day, records) in Dictionary(grouping: events, by: { dayKey($0.date) }) {
            try appendLines(records, to: dayDirectory(day).appendingPathComponent("events.jsonl"))
        }
    }

    public func minutes(from start: Date, to end: Date) throws -> [PostureMinuteRecord] {
        try days(from: start, to: end)
            .flatMap { readLines(PostureMinuteRecord.self, from: dayDirectory($0).appendingPathComponent("minutes.jsonl")) }
            .filter { $0.minuteStart >= start && $0.minuteStart < end }
            .sorted { $0.minuteStart < $1.minuteStart }
    }

    public func events(from start: Date, to end: Date) throws -> [PostureEventRecord] {
        try days(from: start, to: end)
            .flatMap { readLines(PostureEventRecord.self, from: dayDirectory($0).appendingPathComponent("events.jsonl")) }
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date < $1.date }
    }

    public func daySummaries() throws -> [PostureDaySummary] {
        readLines(PostureDaySummary.self, from: directory.appendingPathComponent("summaries.jsonl"))
            .sorted { $0.day < $1.day }
    }

    public func applyRetention(now: Date) throws {
        guard let cutoff = calendar.date(byAdding: .day, value: -minuteRetentionDays, to: calendar.startOfDay(for: now)) else { return }
        let alreadySummarised = Set(try daySummaries().map { dayKey($0.day) })
        for key in try storedDayKeys() {
            guard let day = dayFormatter.date(from: key), day < cutoff else { continue }
            let folder = dayDirectory(key)
            if !alreadySummarised.contains(key) {
                let minutes = readLines(PostureMinuteRecord.self, from: folder.appendingPathComponent("minutes.jsonl"))
                let events = readLines(PostureEventRecord.self, from: folder.appendingPathComponent("events.jsonl"))
                let summary = PostureDaySummary.make(day: day, minutes: minutes, events: events)
                try appendLines([summary], to: directory.appendingPathComponent("summaries.jsonl"))
            }
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Files

    private func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    private func dayDirectory(_ key: String) -> URL { directory.appendingPathComponent(key, isDirectory: true) }

    private func days(from start: Date, to end: Date) throws -> [String] {
        let startKey = dayKey(start)
        let endKey = dayKey(end)
        // Keys sort chronologically, so a string range check is enough.
        return try storedDayKeys().filter { $0 >= startKey && $0 <= endKey }
    }

    private func storedDayKeys() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { dayFormatter.date(from: $0) != nil }
            .sorted()
    }

    private func appendLines<T: Encodable>(_ records: [T], to file: URL) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: file, options: .atomic)
        }
    }

    private func readLines<T: Decodable>(_ type: T.Type, from file: URL) -> [T] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}
