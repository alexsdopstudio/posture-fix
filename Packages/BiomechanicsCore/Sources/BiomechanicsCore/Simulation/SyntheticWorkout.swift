import Foundation

/// Deterministic synthetic IMU generators: analytic motion profiles plus seeded noise and drift.
/// Used by the tests and by the apps' gym demo on devices without motion sensors (the simulator).
public enum SyntheticWorkout {
    public static let sampleRate = 50.0
    public static let gravity = Vector3(x: 0, y: 0, z: -1)

    /// Builds a sample whose `verticalAcceleration` equals `verticalMS2` exactly
    /// (gravity points along -Z, so a_vert = userAcceleration.z · 9.81).
    public static func sample(
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
    public static func squatSet(
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
        seed: UInt64 = 42,
        startTime: TimeInterval = 0
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
                time: startTime + t,
                verticalMS2: acceleration + biasMS2 + random.nextGaussian() * noiseMS2,
                pitch: headPitchNod * depthFraction,
                thighPitch: 100 * depthFraction
            )
        }
    }

    /// Travel `distance` in `duration` with v = (D/T)(1 − cos 2πt/T).
    public static func smoothPhase(_ t: Double, duration: Double, distance: Double) -> (acceleration: Double, fraction: Double) {
        let w = 2 * Double.pi / duration
        let acceleration = distance / duration * w * sin(w * t)
        let fraction = (t - sin(w * t) / w) / duration
        return (acceleration, fraction)
    }

    /// Head-still lift (curl): the head bobs `amplitude` metres per rep through
    /// thoraco-cranial coupling, x(t) = A·(cos ωt − 1), so a(t) = −A·ω²·cos ωt.
    public static func curlSet(
        reps: Int = 10,
        frequencyHz: Double = 0.5,
        amplitude: Double = 0.03,
        restBefore: Double = 1.0,
        restAfter: Double = 1.0,
        biasMS2: Double = 0.02,
        noiseMS2: Double = 0.03,
        lateralRoll: Double = 0,
        seed: UInt64 = 7,
        startTime: TimeInterval = 0
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
                time: startTime + t,
                verticalMS2: acceleration + biasMS2 + random.nextGaussian() * noiseMS2,
                roll: roll
            )
        }
    }
}
