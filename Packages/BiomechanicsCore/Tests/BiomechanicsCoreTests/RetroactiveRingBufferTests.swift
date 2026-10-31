import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("RetroactiveRingBuffer")
struct RetroactiveRingBufferTests {
    @Test("Default buffer holds exactly 5 s at 50 Hz")
    func defaultCapacity() {
        let buffer = RetroactiveRingBuffer()
        #expect(buffer.capacity == 250)
        #expect(buffer.duration == 5.0)
    }

    @Test("Overflow keeps only the most recent 250 samples, oldest first")
    func overflowKeepsNewest() {
        let buffer = RetroactiveRingBuffer()
        for index in 0..<400 {
            buffer.append(IMUSample(timestamp: Double(index) / 50))
        }
        let snapshot = buffer.snapshot()
        #expect(snapshot.count == 250)
        #expect(snapshot.first?.timestamp == 150.0 / 50)
        #expect(snapshot.last?.timestamp == 399.0 / 50)
        #expect(zip(snapshot, snapshot.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        #expect(buffer.latest?.timestamp == 399.0 / 50)
    }

    @Test("Concurrent writers never corrupt the buffer")
    func threadSafety() {
        let buffer = RetroactiveRingBuffer()
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            buffer.append(IMUSample(timestamp: Double(index)))
            _ = buffer.snapshot()
        }
        #expect(buffer.count == 250)
        #expect(buffer.snapshot().count == 250)
    }

    @Test("Auto-Start on rep 2 recovers rep 1 retroactively")
    func recoversFirstRepetition() throws {
        // Squats in a gym: the user is resting, then starts the set. Each rep lasts 2.8 s,
        // longer than the trigger latency, so rep 1 is only available retroactively.
        let samples = SyntheticSignals.squatSet(reps: 3, restBefore: 1.5, seed: 11)
        let buffer = RetroactiveRingBuffer()
        var detector = RepAutoStartDetector()
        var trigger: AutoStartTrigger?
        for sample in samples {
            buffer.append(sample)
            if let fired = detector.process(sample) {
                trigger = fired
                break
            }
        }
        let fired = try #require(trigger)
        // Rep 1 starts at t = 1.5 s; rep 2's descent starts at 1.5 + 2.8 = 4.3 s.
        #expect(abs(fired.firstRepTimestamp - 1.5) < 0.05)
        #expect(abs(fired.secondRepTimestamp - 4.3) < 0.05)

        let captured = buffer.samples(from: fired.captureStart, through: fired.secondRepTimestamp)
        let firstCaptured = try #require(captured.first)
        // The capture reaches back before rep 1's onset, i.e. the quiet pre-roll is there.
        #expect(firstCaptured.timestamp <= 1.5)
        // Rep 1's full descent (1.5 ... 2.7 s, peak deceleration near 2.7 s) is in RAM.
        let rep1 = captured.filter { $0.timestamp >= 1.5 && $0.timestamp <= 2.7 }
        #expect(rep1.count >= 59)
        let lowestThighPitch = captured.compactMap(\.pocketThighPitch).max() ?? 0
        #expect(lowestThighPitch > 95)

        // `retroactiveCapture` returns the same window when asked for the trigger's lookback.
        let lookback = fired.secondRepTimestamp - fired.captureStart
        let viaHelper = buffer.retroactiveCapture(triggeredAt: fired.secondRepTimestamp, lookback: lookback)
        #expect(viaHelper.count == captured.count)
    }

    @Test("A single isolated movement does not start a set")
    func singleImpulseDoesNotTrigger() {
        let samples = SyntheticSignals.squatSet(reps: 1, restBefore: 1.0, restAfter: 5.0, seed: 3)
        var detector = RepAutoStartDetector()
        let fired = samples.compactMap { detector.process($0) }
        #expect(fired.isEmpty)
    }
}
