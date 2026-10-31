import Foundation
@testable import BiomechanicsCore

/// Deterministic synthetic IMU generators: analytic motion profiles plus seeded noise and drift.
enum SyntheticSignals {
    static let sampleRate = 50.0
    static let gravity = Vector3(x: 0, y: 0, z: -1)

    /// Builds a sample whose `verticalAcceleration` equals `verticalMS2` exactly
    /// (gravity points along -Z, so a_vert = userAcceleration.z · 9.81).
    static func sample(
        time: TimeInterval,
        verticalMS2: Double,
        pitch: Double = 0,
        roll: Double = 0,
        thighPitch: Double? = nil
    ) -> IMUSample {
        IMUSample(
            timestamp: time,
            quaternion: Quaternion(pitchDegrees: pitch, rollDegrees: roll, yawDegrees: 0),
            userAcceleration: Vector3(x: 0, y: 0, z: verticalMS2 / RetroactiveRingBuffer.standardGravity),
            gravity: gravity,
            rotationRate: .zero,
            pocketThighPitch: thighPitch
        )
    }

    /// Squat set. Each rep: descent of `depth` over `descentSeconds`, pause in the hole,
    /// ascent over `ascentSeconds`, lockout hold. Phases use a smooth (1 − cos) velocity
    /// profile, v = (D/T)(1 − cos 2πt/T), so acceleration starts and ends at zero like a
    /// real lift. A constant accelerometer bias plus Gaussian noise is added on top.
    static func squatSet(
        reps: Int = 3,
        depth: Double = 0.5,
        descentSeconds: Double = 1.2,
        ascentSeconds: Double = 0.8,
        holdSeconds: Double = 0.4,
        bottomHoldSeconds: Double? = nil,
        restBefore: Double = 1.0,
        restAfter: Double = 0.6,
        biasMS2: Double = 0.05,
        noiseMS2: Double = 0.03,
        headPitchNod: Double = 3,
        seed: UInt64 = 42
    ) -> [IMUSample] {
        var random = SeededRandom(seed: seed)
        let bottomHold = bottomHoldSeconds ?? holdSeconds
        let repSeconds = descentSeconds + bottomHold + ascentSeconds + holdSeconds
        let total = restBefore + Double(reps) * repSeconds - holdSeconds + restAfter
        let count = Int(total * sampleRate)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            var acceleration = 0.0
            var depthFraction = 0.0
            let local = t - restBefore
            if local >= 0, local < Double(reps) * repSeconds {
                let phase = local.truncatingRemainder(dividingBy: repSeconds)
                if phase < descentSeconds {
                    let profile = smoothPhase(phase, duration: descentSeconds, distance: depth)
                    acceleration = -profile.acceleration
                    depthFraction = profile.fraction
                } else if phase < descentSeconds + bottomHold {
                    depthFraction = 1
                } else if phase < descentSeconds + bottomHold + ascentSeconds {
                    let profile = smoothPhase(phase - descentSeconds - bottomHold, duration: ascentSeconds, distance: depth)
                    acceleration = profile.acceleration
                    depthFraction = 1 - profile.fraction
                }
            }
            return sample(
                time: t,
                verticalMS2: acceleration + biasMS2 + random.nextGaussian() * noiseMS2,
                pitch: headPitchNod * depthFraction,
                thighPitch: 100 * depthFraction
            )
        }
    }

    /// Travel `distance` in `duration` with v = (D/T)(1 − cos 2πt/T).
    static func smoothPhase(_ t: Double, duration: Double, distance: Double) -> (acceleration: Double, fraction: Double) {
        let w = 2 * Double.pi / duration
        let acceleration = distance / duration * w * sin(w * t)
        let fraction = (t - sin(w * t) / w) / duration
        return (acceleration, fraction)
    }

    /// Head-still lift (curl): the head bobs `amplitude` metres per rep through
    /// thoraco-cranial coupling, x(t) = A·(cos ωt − 1), so a(t) = −A·ω²·cos ωt.
    static func curlSet(
        reps: Int = 10,
        frequencyHz: Double = 0.5,
        amplitude: Double = 0.03,
        restBefore: Double = 1.0,
        restAfter: Double = 1.0,
        biasMS2: Double = 0.02,
        noiseMS2: Double = 0.03,
        lateralRoll: Double = 0,
        seed: UInt64 = 7
    ) -> [IMUSample] {
        var random = SeededRandom(seed: seed)
        let active = Double(reps) / frequencyHz
        let count = Int((restBefore + active + restAfter) * sampleRate)
        let w = 2 * Double.pi * frequencyHz
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            let local = t - restBefore
            var acceleration = 0.0
            var roll = 0.0
            if local >= 0, local < active {
                acceleration = -amplitude * w * w * cos(w * local)
                roll = lateralRoll * (1 - cos(w * local)) / 2
            }
            return sample(
                time: t,
                verticalMS2: acceleration + biasMS2 + random.nextGaussian() * noiseMS2,
                roll: roll
            )
        }
    }
}

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
