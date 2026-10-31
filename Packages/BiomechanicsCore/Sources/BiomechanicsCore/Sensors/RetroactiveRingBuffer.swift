import Foundation

/// One fused motion sample. Accelerations are in g, rotation rate in rad/s.
public struct IMUSample: Equatable, Sendable, Codable {
    public var timestamp: TimeInterval
    public var quaternion: Quaternion
    public var userAcceleration: Vector3
    public var gravity: Vector3
    public var rotationRate: Vector3
    /// Femur pitch in degrees from an iPhone in the trouser pocket, when available.
    public var pocketThighPitch: Double?

    public init(
        timestamp: TimeInterval,
        quaternion: Quaternion = .identity,
        userAcceleration: Vector3 = .zero,
        gravity: Vector3 = Vector3(x: 0, y: 0, z: -1),
        rotationRate: Vector3 = .zero,
        pocketThighPitch: Double? = nil
    ) {
        self.timestamp = timestamp
        self.quaternion = quaternion
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.pocketThighPitch = pocketThighPitch
    }

    /// Vertical (earth frame) acceleration in m/s², positive upward:
    /// `a_vert = -(a · g) * 9.81`.
    public var verticalAcceleration: Double {
        -userAcceleration.dot(gravity) * RetroactiveRingBuffer.standardGravity
    }
}

/// Fixed-capacity, thread-safe circular buffer that always holds the most recent
/// window of motion (5 s at 50 Hz by default). When the second repetition fires
/// the gym Auto-Start, the first repetition is still in RAM and can be pulled out
/// retroactively instead of being lost.
public final class RetroactiveRingBuffer: @unchecked Sendable {
    public static let standardGravity = 9.81

    public let capacity: Int
    public let sampleRate: Double

    private var storage: [IMUSample?]
    private var head = 0
    private var storedCount = 0
    private let lock = NSLock()

    /// - Parameters:
    ///   - duration: seconds kept in memory.
    ///   - sampleRate: expected sample rate in Hz.
    public init(duration: TimeInterval = 5.0, sampleRate: Double = 50) {
        self.sampleRate = sampleRate
        self.capacity = max(1, Int((duration * sampleRate).rounded()))
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var duration: TimeInterval { Double(capacity) / sampleRate }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    public var isFull: Bool { count == capacity }

    public func append(_ sample: IMUSample) {
        lock.lock()
        defer { lock.unlock() }
        storage[head] = sample
        head = (head + 1) % capacity
        storedCount = min(storedCount + 1, capacity)
    }

    public func append(contentsOf samples: [IMUSample]) {
        for sample in samples { append(sample) }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        head = 0
        storedCount = 0
    }

    /// All buffered samples, oldest first.
    public func snapshot() -> [IMUSample] {
        lock.lock()
        defer { lock.unlock() }
        return orderedUnlocked()
    }

    public var latest: IMUSample? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCount > 0 else { return nil }
        return storage[(head - 1 + capacity) % capacity]
    }

    /// Samples with `start <= timestamp <= end`, oldest first.
    public func samples(from start: TimeInterval, through end: TimeInterval) -> [IMUSample] {
        snapshot().filter { $0.timestamp >= start && $0.timestamp <= end }
    }

    /// Retroactive capture used by gym Auto-Start: returns everything recorded in
    /// the `lookback` seconds before (and including) `triggerTimestamp`, so the
    /// repetition that preceded the trigger is analysed together with the rest of the set.
    public func retroactiveCapture(triggeredAt triggerTimestamp: TimeInterval, lookback: TimeInterval? = nil) -> [IMUSample] {
        let window = min(lookback ?? duration, duration)
        return samples(from: triggerTimestamp - window, through: triggerTimestamp)
    }

    private func orderedUnlocked() -> [IMUSample] {
        guard storedCount > 0 else { return [] }
        let start = (head - storedCount + capacity) % capacity
        var result: [IMUSample] = []
        result.reserveCapacity(storedCount)
        for offset in 0..<storedCount {
            if let sample = storage[(start + offset) % capacity] {
                result.append(sample)
            }
        }
        return result
    }
}

/// Fired when the second repetition confirms that a set has started.
public struct AutoStartTrigger: Equatable, Sendable {
    public var firstRepTimestamp: TimeInterval
    public var secondRepTimestamp: TimeInterval
    /// Where the retroactive capture should begin (first rep minus the pre-roll).
    public var captureStart: TimeInterval
}

/// Gym Auto-Start: one isolated movement could be anything (re-racking, walking),
/// two movement onsets in the same direction within `maximumInterRepGap` are a set
/// (squat: descent, pause, ascent, lockout, descent → fires on rep 2's descent).
/// The trigger arrives during rep 2, so rep 1 must be recovered from the
/// `RetroactiveRingBuffer`.
public struct RepAutoStartDetector: Sendable {
    /// |a_vert - baseline| (m/s²) that marks a movement onset.
    public var impulseThreshold: Double = 0.2
    /// Stillness required before a new onset can be detected.
    public var quietSeconds: Double = 0.25
    public var maximumInterRepGap: Double = 4.0
    /// How much quiet time before rep 1 to include in the capture.
    public var preRollSeconds: Double = 1.0

    private var baseline: Double?
    private var quietSince: TimeInterval?
    private var isMoving = false
    private var firstOnset: (time: TimeInterval, upward: Bool)?
    private var hasFired = false

    public init() {}

    public mutating func reset() {
        baseline = nil
        quietSince = nil
        isMoving = false
        firstOnset = nil
        hasFired = false
    }

    public mutating func process(_ sample: IMUSample) -> AutoStartTrigger? {
        let acceleration = sample.verticalAcceleration
        guard let currentBaseline = baseline else {
            baseline = acceleration
            quietSince = sample.timestamp
            return nil
        }
        let deviation = acceleration - currentBaseline
        guard abs(deviation) > impulseThreshold else {
            // Track slow sensor bias only while quiet.
            baseline = currentBaseline + 0.02 * deviation
            if quietSince == nil { quietSince = sample.timestamp }
            if let since = quietSince, sample.timestamp - since >= quietSeconds { isMoving = false }
            return nil
        }
        quietSince = nil
        guard !isMoving else { return nil }
        isMoving = true
        guard !hasFired else { return nil }

        let onset = (time: sample.timestamp, upward: deviation > 0)
        if let first = firstOnset, onset.time - first.time > maximumInterRepGap {
            firstOnset = onset
            return nil
        }
        guard let first = firstOnset else {
            firstOnset = onset
            return nil
        }
        // Opposite direction is the second half of the same rep.
        guard first.upward == onset.upward else { return nil }
        hasFired = true
        return AutoStartTrigger(
            firstRepTimestamp: first.time,
            secondRepTimestamp: onset.time,
            captureStart: first.time - preRollSeconds
        )
    }
}
