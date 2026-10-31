import CoreMotion
import Foundation
import Observation

/// Streams AirPods head motion (`CMHeadphoneMotionManager`) and falls back to a
/// deterministic simulated seated head whenever headphones are not worn, are not
/// authorised, or the platform has no headphone motion at all.
@MainActor
@Observable
public final class HeadphoneMotionService {
    public enum SourceState: String, Sendable {
        /// Live samples are arriving from worn AirPods.
        case airPodsStreaming
        /// Headphone motion is available but no AirPods are worn right now.
        case airPodsNotWorn
        /// Motion access was denied or the hardware cannot provide headphone motion.
        case unavailable
    }

    public private(set) var sourceState: SourceState = .unavailable
    public private(set) var isUsingSimulation = true
    public private(set) var latestPose: HeadPose?
    public private(set) var latestSample: IMUSample?

    /// Extra offsets added to the calibrated attitude (used by the demo controls).
    public var injectedPitchOffsetDegrees: Double = 0
    public var injectedRollOffsetDegrees: Double = 0

    /// Called on the main actor for every sample, real or simulated.
    @ObservationIgnored public var onSample: ((IMUSample, HeadPose) -> Void)?

    public let sampleRate: Double = 50
    /// A real sample older than this lets the simulation take over.
    public let realSampleTimeout: TimeInterval = 1.0

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private let connectionObserver = HeadphoneConnectionObserver()
    @ObservationIgnored private let calibrator = ZeroTouchAutoCalibrator()
    @ObservationIgnored private var simulator = SeatedHeadSimulator()
    @ObservationIgnored private var simulationTimer: Timer?
    @ObservationIgnored private var lastRealSampleUptime: TimeInterval = -.infinity
    @ObservationIgnored private var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        connectionObserver.onChange = { [weak self] connected in
            MainActor.assumeIsolated {
                self?.sourceState = connected ? .airPodsStreaming : .airPodsNotWorn
            }
        }
        manager.delegate = connectionObserver

        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if manager.isDeviceMotionAvailable && authorization != .denied && authorization != .restricted {
            sourceState = .airPodsNotWorn
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let motion {
                        self.handleRealMotion(motion)
                    } else if error != nil {
                        self.sourceState = .unavailable
                    }
                }
            }
        } else {
            sourceState = .unavailable
        }

        let timer = Timer(timeInterval: 1.0 / sampleRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.simulationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        simulationTimer = timer
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    /// Re-run Zero-Touch calibration from scratch.
    public func recalibrate() {
        calibrator.reset()
    }

    // MARK: - Sample pipeline

    private func handleRealMotion(_ motion: CMDeviceMotion) {
        lastRealSampleUptime = ProcessInfo.processInfo.systemUptime
        isUsingSimulation = false
        sourceState = .airPodsStreaming
        let q = motion.attitude.quaternion
        let sample = IMUSample(
            timestamp: motion.timestamp,
            quaternion: Quaternion(w: q.w, x: q.x, y: q.y, z: q.z),
            userAcceleration: Vector3(x: motion.userAcceleration.x, y: motion.userAcceleration.y, z: motion.userAcceleration.z),
            gravity: Vector3(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z),
            rotationRate: Vector3(x: motion.rotationRate.x, y: motion.rotationRate.y, z: motion.rotationRate.z)
        )
        emit(sample)
    }

    private func simulationTick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRealSampleUptime > realSampleTimeout else { return }
        if !isUsingSimulation {
            // Headphones went quiet: restart calibration on the simulated head.
            calibrator.reset()
        }
        isUsingSimulation = true
        if sourceState == .airPodsStreaming {
            sourceState = .airPodsNotWorn
        }
        emit(simulator.nextSample(at: now))
    }

    private func emit(_ sample: IMUSample) {
        var pose = calibrator.process(sample)
        pose.relativeAttitude.pitchDegrees += injectedPitchOffsetDegrees
        pose.relativeAttitude.rollDegrees += injectedRollOffsetDegrees
        latestSample = sample
        latestPose = pose
        onSample?(sample, pose)
    }
}

/// Bridges the Objective-C delegate to a closure.
private final class HeadphoneConnectionObserver: NSObject, CMHeadphoneMotionManagerDelegate {
    var onChange: ((Bool) -> Void)?

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        onChange?(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        onChange?(false)
    }
}

/// Deterministic seated head: physiological postural sway (0.25 Hz + 0.9 Hz) and
/// low-level sensor noise from a seeded generator, so the calibrator and the desk
/// engine see realistic, repeatable input without AirPods.
public struct SeatedHeadSimulator: Sendable {
    public var swayAmplitudeDegrees: Double = 0.4
    public var accelerationNoiseG: Double = 0.003
    private var random: SeededRandom

    public init(seed: UInt64 = 0x5EA7_ED00) {
        random = SeededRandom(seed: seed)
    }

    public mutating func nextSample(at time: TimeInterval) -> IMUSample {
        let sway = swayAmplitudeDegrees * (sin(2 * .pi * 0.25 * time) + 0.35 * sin(2 * .pi * 0.9 * time))
        let rollSway = 0.5 * swayAmplitudeDegrees * sin(2 * .pi * 0.18 * time + 1.1)
        return IMUSample(
            timestamp: time,
            quaternion: Quaternion(pitchDegrees: sway, rollDegrees: rollSway, yawDegrees: 0),
            userAcceleration: Vector3(
                x: random.nextGaussian() * accelerationNoiseG,
                y: random.nextGaussian() * accelerationNoiseG,
                z: random.nextGaussian() * accelerationNoiseG
            ),
            gravity: Vector3(x: 0, y: 0, z: -1),
            rotationRate: Vector3(
                x: random.nextGaussian() * 0.01,
                y: random.nextGaussian() * 0.01,
                z: random.nextGaussian() * 0.01
            )
        )
    }
}

/// SplitMix64 generator with a Box-Muller Gaussian, for reproducible synthetic data.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Standard normal sample.
    public mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), .leastNonzeroMagnitude)
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
