import Foundation

/// Small numeric helpers shared by the engines.
public enum Statistics {
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Population variance.
    public static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        return values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        variance(values).squareRoot()
    }

    /// Linear-interpolated percentile, `p` in 0...100.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(1, p / 100)) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Coefficient of variation (σ / μ); 0 when the mean is 0.
    public static func coefficientOfVariation(_ values: [Double]) -> Double {
        let m = mean(values)
        guard m != 0 else { return 0 }
        return standardDeviation(values) / abs(m)
    }
}
