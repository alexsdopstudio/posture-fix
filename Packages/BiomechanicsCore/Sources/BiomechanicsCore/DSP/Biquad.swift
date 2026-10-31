import Foundation

/// Second-order IIR section (RBJ audio-EQ cookbook), direct form I.
public struct Biquad: Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public static func lowPass(cutoff: Double, sampleRate: Double, q: Double = 1 / 2.0.squareRoot()) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cosW0) / 2 / a0,
            b1: (1 - cosW0) / a0,
            b2: (1 - cosW0) / 2 / a0,
            a1: -2 * cosW0 / a0,
            a2: (1 - alpha) / a0
        )
    }

    public static func highPass(cutoff: Double, sampleRate: Double, q: Double = 1 / 2.0.squareRoot()) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosW0) / 2 / a0,
            b1: -(1 + cosW0) / a0,
            b2: (1 + cosW0) / 2 / a0,
            a1: -2 * cosW0 / a0,
            a2: (1 - alpha) / a0
        )
    }

    public func apply(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for (i, x0) in input.enumerated() {
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = y0
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }
        return output
    }
}

public enum ZeroPhaseFilter {
    /// Forward-backward band-pass (high-pass then low-pass, both run twice), with odd
    /// reflection padding to tame edge transients. Zero phase, so rep peaks stay in place.
    public static func bandPass(_ signal: [Double], low: Double, high: Double, sampleRate: Double) -> [Double] {
        guard signal.count > 3 else { return signal.map { _ in 0 } }
        let highPass = Biquad.highPass(cutoff: low, sampleRate: sampleRate)
        let lowPass = Biquad.lowPass(cutoff: high, sampleRate: sampleRate)
        let pad = min(signal.count - 1, Int(3 * sampleRate / low))
        let first = signal[0]
        let last = signal[signal.count - 1]
        let head = (1...pad).reversed().map { 2 * first - signal[$0] }
        let tail = (1...pad).map { 2 * last - signal[signal.count - 1 - $0] }
        let padded = head + signal + tail

        func pass(_ x: [Double]) -> [Double] { lowPass.apply(highPass.apply(x)) }
        let forward = pass(padded)
        let backward = Array(pass(Array(forward.reversed())).reversed())
        return Array(backward[pad..<(pad + signal.count)])
    }
}
