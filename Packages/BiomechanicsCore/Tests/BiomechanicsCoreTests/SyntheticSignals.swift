import Foundation
@testable import BiomechanicsCore

/// The generators live in the core (`SyntheticWorkout`) so the apps can run gym demos.
typealias SyntheticSignals = SyntheticWorkout

/// Feeds a desk engine with a seated head at 50 Hz.
struct DeskFeeder {
    let engine: DeskPostureEngine
    var time: TimeInterval = 0
    var baseline: Double = 0
    var random = SeededRandom(seed: 99)
    var events: [DeskPostureEvent] = []

    init(engine: DeskPostureEngine) {
        self.engine = engine
    }

    mutating func feed(
        seconds: Double,
        pitch: Double = 0,
        roll: Double = 0,
        swayAmplitude: Double = 0.5,
        forwardAccelerationG: Double = 0,
        extraAccelerationG: Double = 0
    ) {
        let count = Int((seconds * SyntheticSignals.sampleRate).rounded())
        for _ in 0..<count {
            time += 1 / SyntheticSignals.sampleRate
            let sway = swayAmplitude * sin(2 * .pi * 0.3 * time)
            let sample = IMUSample(
                timestamp: time,
                quaternion: Quaternion(pitchDegrees: pitch + sway, rollDegrees: roll, yawDegrees: 0),
                userAcceleration: Vector3(
                    x: extraAccelerationG + random.nextGaussian() * 0.002,
                    y: forwardAccelerationG + random.nextGaussian() * 0.002,
                    z: random.nextGaussian() * 0.002
                ),
                gravity: SyntheticSignals.gravity,
                rotationRate: .zero
            )
            let pose = HeadPose(
                relativeAttitude: EulerAngles(pitchDegrees: pitch + sway, rollDegrees: roll, yawDegrees: 0),
                isSeated: true,
                isCalibrated: true,
                neutralPitchBaseline: baseline
            )
            events += engine.process(sample, pose: pose)
        }
    }
}
