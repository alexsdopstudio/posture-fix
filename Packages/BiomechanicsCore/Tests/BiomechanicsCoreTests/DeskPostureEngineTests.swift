import Foundation
import Testing
@testable import BiomechanicsCore

@Suite("DeskPostureEngine state machine")
struct DeskPostureEngineTests {
    @Test("neutral → drifting (15 s) → magneticNudge (45 s) → dopamineRecovery (1.5 s in axis) → neutral")
    func fullCycle() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 10)
        #expect(engine.state == .neutral)

        feeder.feed(seconds: 14, pitch: -20)
        #expect(engine.state == .neutral)
        #expect(engine.currentDeviation == .techNeck)

        feeder.feed(seconds: 2, pitch: -20)
        #expect(engine.state == .drifting)

        feeder.feed(seconds: 28, pitch: -20)
        #expect(engine.state == .drifting)
        feeder.feed(seconds: 2, pitch: -20)
        #expect(engine.state == .magneticNudge)
        #expect(engine.nudgeIntensity > 0)

        // 1 s back in axis is not enough (EMA lag + 1.5 s hold).
        feeder.feed(seconds: 1)
        #expect(engine.state == .magneticNudge)
        feeder.feed(seconds: 1.2)
        #expect(engine.state == .dopamineRecovery)
        #expect(engine.metrics.postureRecoveryStreak == 1)
        #expect(feeder.events.contains(.recovered(streak: 1)))

        feeder.feed(seconds: 2.1)
        #expect(engine.state == .neutral)
        #expect(feeder.events.filter { if case .stateChanged = $0 { return true } else { return false } }.count == 4)

        // ~46 s of tech neck out of ~60 s tracked.
        #expect(abs(engine.metrics.techNeckAndTurtleSeconds - 46) < 1)
        #expect(engine.metrics.dailyDeskFlowScore < 30)
    }

    @Test("Drifting resolves straight to neutral without a reward")
    func driftingRecovery() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 5)
        feeder.feed(seconds: 20, pitch: -18)
        #expect(engine.state == .drifting)
        feeder.feed(seconds: 3)
        #expect(engine.state == .neutral)
        #expect(engine.metrics.postureRecoveryStreak == 0)
        #expect(engine.deviationSeconds == 0)
    }

    @Test("Motion gate freezes every timer above 0.08 g")
    func motionGate() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 5)
        feeder.feed(seconds: 30, pitch: -20, extraAccelerationG: 0.1)
        #expect(engine.isMotionGated)
        #expect(engine.state == .neutral)
        #expect(engine.deviationSeconds == 0)
        #expect(engine.metrics.techNeckAndTurtleSeconds == 0)

        // Rotation above 0.5 rad/s also gates.
        let sample = IMUSample(timestamp: feeder.time + 0.02, rotationRate: Vector3(x: 0.6, y: 0, z: 0))
        let pose = HeadPose(relativeAttitude: .zero, isSeated: true, isCalibrated: true, neutralPitchBaseline: 0)
        engine.process(sample, pose: pose)
        #expect(engine.isMotionGated)
    }

    @Test("EMA alpha 0.05 smooths a pitch step")
    func emaSmoothing() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 1, swayAmplitude: 0)
        feeder.feed(seconds: 0.02, pitch: -20, swayAmplitude: 0)
        // One sample after the step: 0 + 0.05 · (-20) = -1.
        #expect(abs(engine.smoothPitch - -1) < 1e-6)
    }

    @Test("Kinematic Turtle Signature: forward glide + C1-C2 micro-extension + 40% less sway")
    func turtleSignature() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        // Relaxed sitting teaches the physiological sway reference.
        feeder.feed(seconds: 30, swayAmplitude: 0.5)
        #expect(engine.referenceSwayVariance != nil)

        // Chin glides forward (anterior acceleration) while gaze stays level.
        feeder.feed(seconds: 1, swayAmplitude: 0.5, forwardAccelerationG: 0.03)
        #expect(engine.isForwardTranslationLatched)

        // Locked, slightly extended head: sway collapses.
        feeder.feed(seconds: 6, pitch: 3, swayAmplitude: 0.1)
        #expect(engine.currentDeviation == .turtle)
        feeder.feed(seconds: 14, pitch: 3, swayAmplitude: 0.1)
        #expect(engine.state == .drifting)
        #expect(engine.metrics.techNeckAndTurtleSeconds > 15)
    }

    @Test("Micro-extension alone without a forward glide is not a turtle")
    func extensionAloneIsNotTurtle() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 30, swayAmplitude: 0.5)
        feeder.feed(seconds: 20, pitch: 3, swayAmplitude: 0.1)
        #expect(engine.currentDeviation == .none)
        #expect(engine.state == .neutral)
    }

    @Test("Lateral lean is tracked per side and steers the nudge")
    func lateralLean() {
        let engine = DeskPostureEngine()
        var feeder = DeskFeeder(engine: engine)
        feeder.feed(seconds: 20, roll: 12)
        #expect(engine.currentDeviation == .rightLean)
        #expect(engine.lateralBias > 0.7)
        #expect(engine.metrics.rightLeanSeconds > 19)
        feeder.feed(seconds: 20, roll: -12)
        #expect(engine.currentDeviation == .leftLean)
        #expect(engine.lateralBias < -0.7)
        #expect(engine.metrics.leftLeanSeconds > 19)
    }

    @Test("Demo fast-forward jumps straight into the nudge")
    func simulatedDeviation() {
        let engine = DeskPostureEngine()
        let events = engine.simulateSustainedDeviation(seconds: 46)
        #expect(engine.state == .magneticNudge)
        #expect(events == [.stateChanged(from: .neutral, to: .magneticNudge)])
    }

    @Test("Daily metrics copy into the persisted summary")
    func summaryApply() {
        var metrics = DeskPostureMetrics()
        metrics.totalTrackedSeconds = 3_600
        metrics.techNeckAndTurtleSeconds = 900
        metrics.leftLeanSeconds = 300
        metrics.postureRecoveryStreak = 4
        metrics.neutralPitchBaseline = 2.5
        let summary = DailyPostureSummary()
        summary.apply(metrics)
        #expect(summary.totalTrackedMinutes == 60)
        #expect(summary.techNeckAndTurtleMinutes == 15)
        #expect(summary.leftLeanMinutes == 5)
        #expect(summary.dailyDeskFlowScore == 67)
        #expect(summary.postureRecoveryStreak == 4)
        #expect(summary.dynamicNeutralPitchBaseline == 2.5)
    }
}

@Suite("Quaternion algebra and Zero-Touch calibration")
struct CalibrationTests {
    @Test("Euler angles round-trip through quaternions")
    func eulerRoundTrip() {
        let angles = Quaternion(pitchDegrees: -25, rollDegrees: 10, yawDegrees: 40).eulerAngles
        #expect(abs(angles.pitchDegrees - -25) < 1e-9)
        #expect(abs(angles.rollDegrees - 10) < 1e-9)
        #expect(abs(angles.yawDegrees - 40) < 1e-9)
    }

    @Test("Relative attitude via multiply(byInverseOf:) removes the reference, even near gimbal lock")
    func relativeAttitude() {
        let reference = Quaternion(pitchDegrees: 0, rollDegrees: 0, yawDegrees: 70)
        let current = reference * Quaternion(pitchDegrees: -15, rollDegrees: 0, yawDegrees: 0)
        let relative = current.multiply(byInverseOf: reference).eulerAngles
        #expect(abs(relative.pitchDegrees - -15) < 1e-9)
        #expect(abs(relative.yawDegrees) < 1e-9)

        let nearLock = Quaternion(pitchDegrees: 0, rollDegrees: 89.9, yawDegrees: 0)
        let tilted = nearLock * Quaternion(pitchDegrees: 5, rollDegrees: 0, yawDegrees: 0)
        let delta = tilted.multiply(byInverseOf: nearLock)
        #expect(abs(delta.eulerAngles.pitchDegrees - 5) < 1e-6)
        #expect(abs(delta.norm - 1) < 1e-12)
    }

    @Test("Seated after 10 s of stillness, then baseline = 85th percentile of pitch")
    func zeroTouchCalibration() {
        let calibrator = ZeroTouchAutoCalibrator()
        var simulator = SeatedHeadSimulator(seed: 1)
        let mounting = Quaternion(pitchDegrees: 12, rollDegrees: -4, yawDegrees: 30)
        var pose: HeadPose?
        for index in 0..<(9 * 50) {
            var sample = simulator.nextSample(at: Double(index) / 50)
            sample.quaternion = mounting * sample.quaternion
            pose = calibrator.process(sample)
        }
        #expect(pose?.isSeated == false)

        for index in (9 * 50)..<(20 * 50) {
            var sample = simulator.nextSample(at: Double(index) / 50)
            sample.quaternion = mounting * sample.quaternion
            pose = calibrator.process(sample)
        }
        #expect(pose?.isSeated == true)
        #expect(pose?.isCalibrated == true)
        // Relative attitude is centred on the sit-down reference, not on the mounting.
        #expect(abs(pose?.relativeAttitude.pitchDegrees ?? 99) < 2)
        let baseline = calibrator.neutralPitchBaseline ?? -99
        #expect(baseline > 0 && baseline < 1)
    }

    @Test("A brief movement keeps the reference; a long absence recaptures it")
    func referenceStability() throws {
        let calibrator = ZeroTouchAutoCalibrator()
        var random = SeededRandom(seed: 4)
        var time = 0.0
        func feed(seconds: Double, attitude: Quaternion, accelerationNoise: Double) {
            for _ in 0..<Int(seconds * 50) {
                time += 0.02
                let noise = Vector3(x: random.nextGaussian() * accelerationNoise,
                                    y: random.nextGaussian() * accelerationNoise,
                                    z: random.nextGaussian() * accelerationNoise)
                calibrator.process(IMUSample(timestamp: time, quaternion: attitude, userAcceleration: noise))
            }
        }
        let upright = Quaternion(pitchDegrees: 0, rollDegrees: 0, yawDegrees: 0)
        let lookingDown = Quaternion(pitchDegrees: -20, rollDegrees: 0, yawDegrees: 0)

        feed(seconds: 12, attitude: upright, accelerationNoise: 0.001)
        let firstReference = try #require(calibrator.referenceAttitude)
        // Reach for the phone, then sit still while looking down.
        feed(seconds: 2, attitude: lookingDown, accelerationNoise: 0.2)
        feed(seconds: 12, attitude: lookingDown, accelerationNoise: 0.001)
        #expect(calibrator.isSeated)
        #expect(calibrator.referenceAttitude == firstReference)

        // Away for more than a minute: the next sit-down is a new reference.
        feed(seconds: 70, attitude: upright, accelerationNoise: 0.2)
        feed(seconds: 12, attitude: lookingDown, accelerationNoise: 0.001)
        #expect(calibrator.referenceAttitude == lookingDown)
    }

    @Test("Guided calibration: a 3 s steady hold locks the neutral; crooked AirPods read as upright")
    func guidedCalibration() throws {
        let calibrator = ZeroTouchAutoCalibrator()
        calibrator.beginWearCalibration()
        // Earbud rotated 15° forward and 10° sideways in the ear.
        let crooked = Quaternion(pitchDegrees: 15, rollDegrees: 10, yawDegrees: 0)
        var time = 0.0
        var captured: HeadPose?
        var progressAtHalf: Double?
        for index in 1...(4 * 50) {
            time = Double(index) * 0.02
            let pose = calibrator.process(IMUSample(timestamp: time, quaternion: crooked))
            if index == 75 { progressAtHalf = pose.calibrationProgress }
            if pose.didCaptureReference {
                captured = pose
                break
            }
        }
        // Progress fills linearly, then locks at ~3 s.
        #expect(abs((progressAtHalf ?? 0) - 0.5) < 0.02)
        let pose = try #require(captured)
        #expect(abs(time - 3.0) < 0.05)
        #expect(pose.isCalibrated)
        #expect(pose.neutralPitchBaseline == 0)
        #expect(calibrator.isNeutralLockedByUser)
        #expect(abs(pose.relativeAttitude.pitchDegrees) < 1e-6)

        // Looking down 20° from there reads as -20° pitch, not mixed into roll.
        let lookingDown = crooked * Quaternion(pitchDegrees: -20, rollDegrees: 0, yawDegrees: 0)
        let relative = calibrator.process(IMUSample(timestamp: time + 0.02, quaternion: lookingDown)).relativeAttitude
        #expect(abs(relative.pitchDegrees - -20) < 1e-6)
        #expect(abs(relative.rollDegrees) < 1e-6)

        // The chosen neutral does not drift with P85 while seated.
        for index in 1...(20 * 50) {
            calibrator.process(IMUSample(timestamp: time + Double(index) * 0.02, quaternion: lookingDown))
        }
        #expect(calibrator.neutralPitchBaseline == 0)
    }

    @Test("Moving the head restarts the hold instead of locking a wrong posture")
    func guidedCalibrationRestarts() {
        let calibrator = ZeroTouchAutoCalibrator()
        calibrator.beginWearCalibration()
        var time = 0.0
        for _ in 0..<100 {
            time += 0.02
            calibrator.process(IMUSample(timestamp: time))
        }
        #expect(abs(calibrator.wearProgress - 2.0 / 3) < 0.02)
        // A glance down: the head rotates beyond the 2° tolerance.
        time += 0.02
        let glance = Quaternion(pitchDegrees: -15, rollDegrees: 0, yawDegrees: 0)
        calibrator.process(IMUSample(timestamp: time, quaternion: glance, rotationRate: Vector3(x: -1, y: 0, z: 0)))
        #expect(calibrator.wearProgress == 0)
        #expect(calibrator.isAwaitingWearCapture)
        #expect(calibrator.referenceAttitude == nil)
    }

    @Test("Without a steady hold the guided calibration times out to automatic")
    func guidedCalibrationTimeout() {
        let calibrator = ZeroTouchAutoCalibrator()
        calibrator.beginWearCalibration()
        for index in 0..<(21 * 50) {
            let angle = Double(index) * 0.5
            let wandering = Quaternion(pitchDegrees: 10 * sin(angle), rollDegrees: 0, yawDegrees: 0)
            calibrator.process(IMUSample(timestamp: Double(index) * 0.02, quaternion: wandering))
        }
        #expect(!calibrator.isAwaitingWearCapture)
        #expect(calibrator.referenceAttitude == nil)
        #expect(!calibrator.isNeutralLockedByUser)
    }

    @Test("Guided-only mode: sitting still never auto-captures, it reopens the guided calibration")
    func guidedOnlyMode() {
        var configuration = ZeroTouchAutoCalibrator.Configuration()
        configuration.allowsAutomaticCapture = false
        let calibrator = ZeroTouchAutoCalibrator(configuration: configuration)
        var random = SeededRandom(seed: 12)
        var time = 0.0
        func feed(seconds: Double, noise: Double, quaternion: Quaternion = .identity) {
            for _ in 0..<Int(seconds * 50) {
                time += 0.02
                let acceleration = Vector3(x: random.nextGaussian() * noise, y: random.nextGaussian() * noise, z: 0)
                calibrator.process(IMUSample(timestamp: time, quaternion: quaternion, userAcceleration: acceleration))
            }
        }
        // Walking for a while: no prompt.
        feed(seconds: 12, noise: 0.2)
        #expect(!calibrator.isAwaitingWearCapture)
        // Sitting still for 10 s: the guided calibration opens instead of capturing silently.
        feed(seconds: 10.1, noise: 0.001)
        #expect(calibrator.isAwaitingWearCapture)
        #expect(calibrator.referenceAttitude == nil)

        // The user ignores it while fidgeting in the chair (rotating the head): it times out...
        for index in 0..<(21 * 50) {
            time += 0.02
            let wandering = Quaternion(pitchDegrees: 10 * sin(Double(index) * 0.5), rollDegrees: 0, yawDegrees: 0)
            calibrator.process(IMUSample(timestamp: time, quaternion: wandering))
        }
        #expect(!calibrator.isAwaitingWearCapture)
        // ...and does not reopen until the next sit-down.
        feed(seconds: 5, noise: 0.001)
        #expect(!calibrator.isAwaitingWearCapture)
        feed(seconds: 3, noise: 0.2)
        feed(seconds: 10.1, noise: 0.001)
        #expect(calibrator.isAwaitingWearCapture)
        #expect(!calibrator.isNeutralLockedByUser)
    }

    @Test("The simulated head adopts its first sample as neutral")
    func adoptForSimulation() {
        let calibrator = ZeroTouchAutoCalibrator()
        calibrator.adoptNextSampleAsNeutral()
        let tilted = Quaternion(pitchDegrees: 7, rollDegrees: 0, yawDegrees: 0)
        let pose = calibrator.process(IMUSample(timestamp: 0, quaternion: tilted))
        #expect(pose.didCaptureReference)
        #expect(pose.isCalibrated)
        #expect(calibrator.referenceAttitude == tilted)
    }

    @Test("Standing up (high acceleration variance) clears the seated flag")
    func standingUp() {
        let calibrator = ZeroTouchAutoCalibrator()
        var random = SeededRandom(seed: 2)
        for index in 0..<(11 * 50) {
            calibrator.process(IMUSample(timestamp: Double(index) / 50))
        }
        #expect(calibrator.isSeated)
        for index in (11 * 50)..<(13 * 50) {
            let walking = Vector3(x: random.nextGaussian() * 0.2, y: random.nextGaussian() * 0.2, z: random.nextGaussian() * 0.2)
            calibrator.process(IMUSample(timestamp: Double(index) / 50, userAcceleration: walking))
        }
        #expect(!calibrator.isSeated)
    }
}
