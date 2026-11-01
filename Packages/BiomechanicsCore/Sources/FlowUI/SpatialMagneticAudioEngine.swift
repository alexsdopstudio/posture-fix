import AVFoundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Render-thread state of the 432 Hz generator. Plain Double stores are atomic on
/// Apple silicon and Intel; the main thread only writes the targets.
private final class ToneState: @unchecked Sendable {
    let frequency: Double = 432
    var phase: Double = 0
    var amplitude: Double = 0
    var targetAmplitude: Double = 0
}

/// "Magnetic" pull: a pure 432 Hz sine synthesised in real time (no audio files),
/// spatialised with HRTF 1.5 m behind the head and shifted on X opposite to the
/// head's roll, so the sound draws the head back into axis.
@MainActor
public final class SpatialMagneticAudioEngine {
    static let distanceBehindHead: Float = 1.5
    static let pullAmplitude = 0.18

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let tone = ToneState()
    private var source: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?
    private var stopWorkItem: DispatchWorkItem?

    public private(set) var isPulling = false

    public init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Output device changed (e.g. AirPods connected): restart if we were playing.
            MainActor.assumeIsolated {
                guard let self, self.isPulling else { return }
                try? self.engine.start()
            }
        }
    }

    public func startMagneticPull(roll: Double) {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        do {
            #if os(iOS)
            // Play over whatever else is playing, through the AirPods.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try configureIfNeeded()
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            NSLog("Flow: spatial audio unavailable: \(error.localizedDescription)")
            return
        }
        isPulling = true
        tone.targetAmplitude = Self.pullAmplitude
        updatePull(roll: roll)
    }

    /// Head rolls right (positive) → the source moves left, and vice versa.
    public func updatePull(roll: Double) {
        guard let source else { return }
        let x = Float(max(-1.5, min(1.5, -roll / 10)))
        source.position = AVAudio3DPoint(x: x, y: 0, z: Self.distanceBehindHead)
    }

    public func stopMagneticPull() {
        guard isPulling else { return }
        isPulling = false
        tone.targetAmplitude = 0
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isPulling else { return }
                self.engine.pause()
            }
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Reward on the return to a neutral posture.
    public func playDopamineChime() {
        #if canImport(AppKit)
        NSSound(named: NSSound.Name("Glass"))?.play()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func configureIfNeeded() throws {
        guard source == nil else { return }
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48_000
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "FlowMac.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create mono format"])
        }
        let node = Self.makeSineSource(format: mono, state: tone)
        engine.attach(node)
        engine.attach(environment)
        // HRTF spatialisation requires a mono input into the environment node.
        engine.connect(node, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        node.renderingAlgorithm = .HRTFHQ
        node.position = AVAudio3DPoint(x: 0, y: 0, z: Self.distanceBehindHead)
        // The listener sits at the origin facing -Z, so +Z is behind the nape.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.reverbParameters.enable = false
        environment.outputVolume = 1

        source = node
        engine.prepare()
    }

    /// Built outside the main actor: the render block runs on the real-time audio thread.
    private nonisolated static func makeSineSource(format: AVAudioFormat, state: ToneState) -> AVAudioSourceNode {
        let sampleRate = format.sampleRate
        let increment = 2 * Double.pi * state.frequency / sampleRate
        // ~20 ms amplitude glide: no clicks when the pull starts or stops.
        let glide = 1 - exp(-1 / (0.02 * sampleRate))
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                state.amplitude += (state.targetAmplitude - state.amplitude) * glide
                let value = Float(sin(state.phase) * state.amplitude)
                state.phase += increment
                if state.phase >= 2 * Double.pi { state.phase -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
    }
}
