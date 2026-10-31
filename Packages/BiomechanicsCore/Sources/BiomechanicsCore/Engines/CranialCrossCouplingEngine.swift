import Foundation

public struct CranialRep: Equatable, Sendable {
    public var kinematics: RepKinematics
    public var peakTime: TimeInterval
    /// Band-passed thoraco-cranial tension amplitude at the peak, in g.
    public var amplitudeG: Double
}

public struct CranialCrossCouplingResult: Sendable {
    public var timestamps: [TimeInterval]
    /// Band-passed (0.35-2.2 Hz) vertical head acceleration, in g.
    public var filteredG: [Double]
    /// Energy envelope (√2 · moving RMS over 1 s), in g.
    public var envelopeG: [Double]
    public var reps: [CranialRep]
    /// Peaks above the tension band: whole-body movement, not a head-still lift.
    public var rejectedPeakCount: Int

    /// Fraction of `range` whose envelope lies inside the active tension band.
    public func activeFraction(in range: Range<Int>, band: ClosedRange<Double>) -> Double {
        let clamped = range.clamped(to: 0..<envelopeG.count)
        guard !clamped.isEmpty else { return 0 }
        let active = envelopeG[clamped].filter { band.contains($0) }.count
        return Double(active) / Double(clamped.count)
    }
}

/// Pipeline B: counts reps of head-still lifts (curls, lateral raises, bench) from the
/// thoraco-cranial tension that every rep couples into the head.
///
/// The vertical head acceleration is band-passed (0.35-2.2 Hz, zero phase); each positive
/// lobe whose peak sits inside the 0.015-0.06 g tension envelope is one repetition.
public struct CranialCrossCouplingEngine: Sendable {
    public struct Configuration: Sendable {
        public var lowCutHz: Double = 0.35
        public var highCutHz: Double = 2.2
        public var tensionBandG: ClosedRange<Double> = 0.015...0.06
        public var envelopeWindowSeconds: Double = 1.0

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func analyze(_ samples: [IMUSample]) -> CranialCrossCouplingResult {
        let timestamps = samples.map(\.timestamp)
        let n = samples.count
        guard n > 3, let first = timestamps.first, let last = timestamps.last, last > first else {
            return CranialCrossCouplingResult(timestamps: timestamps, filteredG: Array(repeating: 0, count: n),
                                              envelopeG: Array(repeating: 0, count: n), reps: [], rejectedPeakCount: 0)
        }
        let sampleRate = Double(n - 1) / (last - first)
        let signal = samples.map { $0.verticalAcceleration / RetroactiveRingBuffer.standardGravity }
        let mean = Statistics.mean(signal)
        let filtered = ZeroPhaseFilter.bandPass(
            signal.map { $0 - mean },
            low: configuration.lowCutHz,
            high: configuration.highCutHz,
            sampleRate: sampleRate
        )
        let envelope = Self.envelope(filtered, windowSamples: max(1, Int(configuration.envelopeWindowSeconds * sampleRate)))

        // Each positive lobe (between two zero crossings) whose peak clears the tension
        // floor is a candidate rep; peaks above the band are whole-body movement.
        var lobes: [(start: Int, end: Int, peakIndex: Int, peak: Double)] = []
        var lobeStart: Int?
        for i in 0...n {
            let positive = i < n && filtered[i] > 0
            if positive, lobeStart == nil {
                lobeStart = i
            } else if !positive, let start = lobeStart {
                lobeStart = nil
                let end = i - 1
                if let peakIndex = (start...end).max(by: { filtered[$0] < filtered[$1] }),
                   filtered[peakIndex] >= configuration.tensionBandG.lowerBound {
                    lobes.append((start, end, peakIndex, filtered[peakIndex]))
                }
            }
        }

        let ceiling = configuration.tensionBandG.upperBound
        let reference = samples[0].quaternion
        var reps: [CranialRep] = []
        var rejected = 0
        for (index, lobe) in lobes.enumerated() {
            guard lobe.peak <= ceiling else {
                rejected += 1
                continue
            }
            // The zero-phase filter rings next to a large movement; such side lobes are
            // artefacts of the rejected movement, not reps of their own.
            let previousRejected = index > 0 && lobes[index - 1].peak > ceiling
            let nextRejected = index + 1 < lobes.count && lobes[index + 1].peak > ceiling
            guard !previousRejected, !nextRejected else { continue }
            let deviation = KinematicZUPTEngine.headDeviation(samples, from: lobe.start, to: lobe.end, reference: reference)
            reps.append(CranialRep(
                kinematics: RepKinematics(
                    startTime: timestamps[lobe.start],
                    endTime: timestamps[lobe.end],
                    maxPitchDeviation: deviation.pitch,
                    maxRollDeviation: deviation.roll
                ),
                peakTime: timestamps[lobe.peakIndex],
                amplitudeG: lobe.peak
            ))
        }

        // A rep's duration is the peak-to-peak period; the last rep reuses the median period.
        if reps.count > 1 {
            let periods = zip(reps, reps.dropFirst()).map { $1.peakTime - $0.peakTime }
            let median = periods.sorted()[periods.count / 2]
            for index in reps.indices {
                let period = index < periods.count ? periods[index] : median
                reps[index].kinematics.startTime = reps[index].peakTime - period / 2
                reps[index].kinematics.endTime = reps[index].peakTime + period / 2
            }
        }

        return CranialCrossCouplingResult(
            timestamps: timestamps,
            filteredG: filtered,
            envelopeG: envelope,
            reps: reps,
            rejectedPeakCount: rejected
        )
    }

    static func envelope(_ signal: [Double], windowSamples: Int) -> [Double] {
        let n = signal.count
        guard n > 0 else { return [] }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + signal[i] * signal[i] }
        let half = windowSamples / 2
        return (0..<n).map { i in
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let meanSquare = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            return (2 * meanSquare).squareRoot()
        }
    }
}
