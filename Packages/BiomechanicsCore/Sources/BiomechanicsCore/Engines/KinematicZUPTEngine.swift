import Foundation

/// Zero-velocity window: the bar/body is momentarily still at the top or the bottom.
public struct ZUPTWindow: Equatable, Sendable {
    public var startIndex: Int
    public var endIndex: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public var duration: TimeInterval { endTime - startTime }
}

/// Head attitude excursion and timing of a single repetition, shared by both pipelines.
public struct RepKinematics: Equatable, Sendable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var maxPitchDeviation: Double
    public var maxRollDeviation: Double

    public var duration: TimeInterval { endTime - startTime }

    public init(startTime: TimeInterval, endTime: TimeInterval, maxPitchDeviation: Double, maxRollDeviation: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.maxPitchDeviation = maxPitchDeviation
        self.maxRollDeviation = maxRollDeviation
    }
}

public struct KinematicRep: Equatable, Sendable {
    public var kinematics: RepKinematics
    public var eccentricSeconds: Double?
    public var concentricSeconds: Double
    /// Mean concentric velocity, m/s.
    public var meanConcentricVelocity: Double
    /// Concentric vertical excursion, m.
    public var verticalExcursion: Double
}

public struct KinematicZUPTResult: Sendable {
    public var timestamps: [TimeInterval]
    public var verticalAcceleration: [Double]
    /// Naive integration of `a_vert` without any correction (shows the drift).
    public var rawVelocity: [Double]
    /// Velocity after ZUPT clamping and linear retroactive dedrifting.
    public var correctedVelocity: [Double]
    public var zuptWindows: [ZUPTWindow]
    public var reps: [KinematicRep]
    public var thighRomDegrees: Double?

    public var meanConcentricVelocity: Double? {
        reps.isEmpty ? nil : Statistics.mean(reps.map(\.meanConcentricVelocity))
    }

    public var averageEccentricSeconds: Double? {
        let values = reps.compactMap(\.eccentricSeconds)
        return values.isEmpty ? nil : Statistics.mean(values)
    }

    public var maxVerticalExcursion: Double { reps.map(\.verticalExcursion).max() ?? 0 }
}

/// Pipeline A: vertical kinematics for lifts with large vertical travel.
///
/// 1. Earth-frame vertical acceleration `a_vert(t) = -(ax·gx + ay·gy + az·gz) · 9.81`.
/// 2. ZUPT windows: runs of at least 150 ms where `a_vert` is flat (minimum variance)
///    and close to zero, i.e. the lockout at the top or the pause in the hole.
///    Velocity is forced to 0 there.
/// 3. Between two ZUPT anchors the integrated velocity is dedrifted linearly:
///    `v_corrected(t) = v_raw(t) - (v_raw(T_end) / (T_end - T_start)) · (t - T_start)`,
///    which removes any constant accelerometer bias exactly.
/// 4. Each anchored segment is split into eccentric (down) and concentric (up) phases.
public struct KinematicZUPTEngine: Sendable {
    public struct Configuration: Sendable {
        /// Minimum ZUPT window length (150 ms); nominal windows last 150-300 ms and longer
        /// pauses are treated as a chain of consecutive windows.
        public var minimumWindowSeconds: Double = 0.15
        /// Peak-to-peak `a_vert` (m/s²) inside the sliding window that still counts as still.
        public var stillnessRange: Double = 0.3
        /// Minimum phase excursion (m) to count as a repetition phase.
        public var minimumPhaseExcursion: Double = 0.05
        /// Maximum |a_vert| (m/s²) in a ZUPT window: flat *and* near zero, which rejects
        /// the flat plateau at peak acceleration mid-phase. Covers realistic sensor bias.
        public var stillnessMagnitude: Double = 0.5

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func analyze(_ samples: [IMUSample]) -> KinematicZUPTResult {
        let timestamps = samples.map(\.timestamp)
        let acceleration = samples.map(\.verticalAcceleration)
        let n = samples.count
        guard n > 2 else {
            return KinematicZUPTResult(
                timestamps: timestamps, verticalAcceleration: acceleration,
                rawVelocity: Array(repeating: 0, count: n), correctedVelocity: Array(repeating: 0, count: n),
                zuptWindows: [], reps: [], thighRomDegrees: Self.thighRom(samples)
            )
        }

        let rawVelocity = Self.integrate(acceleration, timestamps: timestamps, from: 0, to: n - 1)
        let windows = detectZUPTWindows(acceleration: acceleration, timestamps: timestamps)
        var corrected = [Double](repeating: 0, count: n)
        var phases: [Phase] = []

        for (current, next) in zip(windows, windows.dropFirst()) {
            let start = current.endIndex
            let end = next.startIndex
            guard end - start >= 2 else { continue }
            let segmentRaw = Self.integrate(acceleration, timestamps: timestamps, from: start, to: end)
            let tStart = timestamps[start]
            let tEnd = timestamps[end]
            let drift = segmentRaw[segmentRaw.count - 1] / (tEnd - tStart)
            for offset in 0..<segmentRaw.count {
                let i = start + offset
                corrected[i] = segmentRaw[offset] - drift * (timestamps[i] - tStart)
            }
            phases.append(contentsOf: splitIntoPhases(velocity: corrected, timestamps: timestamps, from: start, to: end))
        }

        let reference = samples[0].quaternion
        var reps: [KinematicRep] = []
        for (index, phase) in phases.enumerated() where phase.isConcentric {
            var eccentric: Phase?
            if index > 0, !phases[index - 1].isConcentric {
                eccentric = phases[index - 1]
            } else if index + 1 < phases.count, !phases[index + 1].isConcentric {
                eccentric = phases[index + 1]
            }
            let startIndex = min(phase.startIndex, eccentric?.startIndex ?? phase.startIndex)
            let endIndex = max(phase.endIndex, eccentric?.endIndex ?? phase.endIndex)
            let deviation = Self.headDeviation(samples, from: startIndex, to: endIndex, reference: reference)
            reps.append(KinematicRep(
                kinematics: RepKinematics(
                    startTime: timestamps[startIndex],
                    endTime: timestamps[endIndex],
                    maxPitchDeviation: deviation.pitch,
                    maxRollDeviation: deviation.roll
                ),
                eccentricSeconds: eccentric.map { timestamps[$0.endIndex] - timestamps[$0.startIndex] },
                concentricSeconds: timestamps[phase.endIndex] - timestamps[phase.startIndex],
                meanConcentricVelocity: phase.excursion / (timestamps[phase.endIndex] - timestamps[phase.startIndex]),
                verticalExcursion: phase.excursion
            ))
        }

        return KinematicZUPTResult(
            timestamps: timestamps,
            verticalAcceleration: acceleration,
            rawVelocity: rawVelocity,
            correctedVelocity: corrected,
            zuptWindows: windows,
            reps: reps,
            thighRomDegrees: Self.thighRom(samples)
        )
    }

    public func detectZUPTWindows(acceleration: [Double], timestamps: [TimeInterval]) -> [ZUPTWindow] {
        let n = acceleration.count
        guard n > 1, let first = timestamps.first, let last = timestamps.last, last > first else { return [] }
        let sampleRate = Double(n - 1) / (last - first)
        let width = max(3, Int((configuration.minimumWindowSeconds * sampleRate).rounded()))
        let half = width / 2

        var still = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var minimum = Double.infinity
            var maximum = -Double.infinity
            for j in lo...hi {
                minimum = min(minimum, acceleration[j])
                maximum = max(maximum, acceleration[j])
            }
            still[i] = maximum - minimum < configuration.stillnessRange
                && max(abs(minimum), abs(maximum)) < configuration.stillnessMagnitude
        }

        // A sample is flagged still only when its whole centred window is flat, so every
        // run is half a window shorter than the real pause at both ends: dilate it back.
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?
        for i in 0...n {
            let isStill = i < n && still[i]
            if isStill, runStart == nil {
                runStart = i
            } else if !isStill, let start = runStart {
                runs.append((max(0, start - half), min(n - 1, i - 1 + half)))
                runStart = nil
            }
        }

        var windows: [ZUPTWindow] = []
        for run in runs {
            if let last = windows.last, run.start <= last.endIndex + 1 {
                windows[windows.count - 1].endIndex = max(last.endIndex, run.end)
                windows[windows.count - 1].endTime = timestamps[windows[windows.count - 1].endIndex]
            } else {
                windows.append(ZUPTWindow(startIndex: run.start, endIndex: run.end, startTime: timestamps[run.start], endTime: timestamps[run.end]))
            }
        }
        return windows.filter { $0.duration >= configuration.minimumWindowSeconds - 0.5 / sampleRate }
    }

    // MARK: - Helpers

    private struct Phase {
        var startIndex: Int
        var endIndex: Int
        var excursion: Double
        var isConcentric: Bool
    }

    /// Splits one anchored segment into up/down phases using the integrated position.
    private func splitIntoPhases(velocity: [Double], timestamps: [TimeInterval], from start: Int, to end: Int) -> [Phase] {
        var position = [Double](repeating: 0, count: end - start + 1)
        for i in (start + 1)...end {
            let dt = timestamps[i] - timestamps[i - 1]
            position[i - start] = position[i - start - 1] + 0.5 * (velocity[i] + velocity[i - 1]) * dt
        }
        let net = position[position.count - 1]
        let minimum = position.min() ?? 0
        let maximum = position.max() ?? 0
        let threshold = configuration.minimumPhaseExcursion

        let phases: [Phase]
        if net >= threshold {
            phases = [Phase(startIndex: start, endIndex: end, excursion: net, isConcentric: true)]
        } else if net <= -threshold {
            phases = [Phase(startIndex: start, endIndex: end, excursion: -net, isConcentric: false)]
        } else if maximum - minimum < threshold {
            phases = []
        } else if -minimum >= maximum, let turn = position.firstIndex(of: minimum) {
            // Touch-and-go rep with no pause at the turning point: split at the extremum.
            phases = [
                Phase(startIndex: start, endIndex: start + turn, excursion: -minimum, isConcentric: false),
                Phase(startIndex: start + turn, endIndex: end, excursion: net - minimum, isConcentric: true),
            ]
        } else if let turn = position.firstIndex(of: maximum) {
            phases = [
                Phase(startIndex: start, endIndex: start + turn, excursion: maximum, isConcentric: true),
                Phase(startIndex: start + turn, endIndex: end, excursion: maximum - net, isConcentric: false),
            ]
        } else {
            phases = []
        }
        return phases
    }

    /// Trapezoidal integration of `values` over `[from, to]`, starting at 0.
    static func integrate(_ values: [Double], timestamps: [TimeInterval], from start: Int, to end: Int) -> [Double] {
        guard end > start else { return [0] }
        var result = [Double](repeating: 0, count: end - start + 1)
        for i in (start + 1)...end {
            let dt = timestamps[i] - timestamps[i - 1]
            result[i - start] = result[i - start - 1] + 0.5 * (values[i] + values[i - 1]) * dt
        }
        return result
    }

    static func headDeviation(_ samples: [IMUSample], from start: Int, to end: Int, reference: Quaternion) -> (pitch: Double, roll: Double) {
        guard start <= end, end < samples.count else { return (0, 0) }
        var pitch = 0.0
        var roll = 0.0
        for sample in samples[start...end] {
            let angles = sample.quaternion.multiply(byInverseOf: reference).eulerAngles
            pitch = max(pitch, abs(angles.pitchDegrees))
            roll = max(roll, abs(angles.rollDegrees))
        }
        return (pitch, roll)
    }

    static func thighRom(_ samples: [IMUSample]) -> Double? {
        let pitches = samples.compactMap(\.pocketThighPitch)
        guard let low = pitches.min(), let high = pitches.max() else { return nil }
        return high - low
    }
}
