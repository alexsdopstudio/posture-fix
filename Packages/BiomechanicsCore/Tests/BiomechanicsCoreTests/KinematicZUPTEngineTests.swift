import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("Pipeline A: ZUPT + Linear Retroactive Dedrifting")
struct KinematicZUPTEngineTests {
    let samples = SyntheticSignals.squatSet(reps: 3, biasMS2: 0.05, noiseMS2: 0.03)
    let result: KinematicZUPTResult

    init() {
        result = KinematicZUPTEngine().analyze(samples)
    }

    @Test("Vertical projection a_vert = -(a·g)·9.81")
    func verticalProjection() {
        let sample = IMUSample(
            timestamp: 0,
            userAcceleration: Vector3(x: 0.1, y: 0.2, z: 0.3),
            gravity: Vector3(x: 0.0, y: -0.6, z: -0.8)
        )
        // a·g = 0 - 0.12 - 0.24 = -0.36 → a_vert = 0.36 · 9.81
        #expect(abs(sample.verticalAcceleration - 0.36 * 9.81) < 1e-9)
    }

    @Test("Naive integration drifts, ZUPT + dedrifting returns to zero")
    func driftIsRemoved() throws {
        // 0.05 m/s² bias over 9.6 s is ~0.48 m/s of phantom velocity.
        let rawEnd = try #require(result.rawVelocity.last)
        #expect(rawEnd > 0.35)

        let correctedEnd = try #require(result.correctedVelocity.last)
        #expect(abs(correctedEnd) < 1e-9)
        // Inside every ZUPT window velocity is clamped to exactly 0.
        for window in result.zuptWindows {
            for index in (window.startIndex + 1)..<window.endIndex {
                #expect(result.correctedVelocity[index] == 0)
            }
        }
    }

    @Test("ZUPT windows found at lockout and in the hole, all at least 150 ms")
    func zuptWindows() {
        // rest + (hole, lockout) × 3 reps, the last lockout merging with the final rest.
        #expect(result.zuptWindows.count == 7)
        #expect(result.zuptWindows.allSatisfy { $0.duration >= 0.15 - 1e-9 })
    }

    @Test("Three reps with MCV, eccentric time and femur ROM recovered")
    func repMetrics() throws {
        #expect(result.reps.count == 3)
        let truthMCV = 0.5 / 0.8
        let mcv = try #require(result.meanConcentricVelocity)
        #expect(abs(mcv - truthMCV) / truthMCV < 0.05)
        let eccentric = try #require(result.averageEccentricSeconds)
        #expect(abs(eccentric - 1.2) < 0.1)
        for rep in result.reps {
            #expect(abs(rep.verticalExcursion - 0.5) < 0.03)
        }
        let rom = try #require(result.thighRomDegrees)
        #expect(abs(rom - 100) < 1)
    }

    @Test("Touch-and-go reps without a pause in the hole are split at the turning point")
    func touchAndGo() {
        let bounce = SyntheticSignals.squatSet(reps: 2, bottomHoldSeconds: 0, restBefore: 1.0, restAfter: 1.0, seed: 5)
        let analysis = KinematicZUPTEngine().analyze(bounce)
        // The last rep's ascent is followed by the final rest; every rep has a concentric phase.
        #expect(analysis.reps.count == 2)
        #expect(analysis.reps.allSatisfy { abs($0.verticalExcursion - 0.5) < 0.05 })
    }
}
