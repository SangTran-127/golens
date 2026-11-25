import Foundation

public struct SampleSummary: Sendable, Equatable, Codable {
    public let count: Int
    public let median: Double
    public let q1: Double
    public let q3: Double
    public let min: Double
    public let max: Double
    public let outliers: [Double]

    public var iqr: Double { q3 - q1 }
}

public enum BenchmarkStatistics {
    public static let methodDescription = "Per-benchmark median with interquartile range (linear-interpolated quartiles, outliers beyond 1.5 IQR are reported and kept). Significance is a two-sided Mann-Whitney U test using the normal approximation with average ranks for ties, tie-corrected variance and a 0.5 continuity correction; the approximation is rough below about 10 samples per side, so smaller samples are always inconclusive. A change is reported only when p < 0.05 and the baseline and candidate interquartile ranges do not overlap."

    public static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        if sorted.count == 1 { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    public static func summarize(_ values: [Double]) -> SampleSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let q1 = quantile(sorted, 0.25)
        let q3 = quantile(sorted, 0.75)
        let fence = 1.5 * (q3 - q1)
        let outliers = sorted.filter { $0 < q1 - fence || $0 > q3 + fence }
        return SampleSummary(count: sorted.count, median: quantile(sorted, 0.5), q1: q1, q3: q3, min: sorted[0], max: sorted[sorted.count - 1], outliers: outliers)
    }

    public static func mannWhitneyTwoSidedP(_ a: [Double], _ b: [Double]) -> Double? {
        let n1 = Double(a.count)
        let n2 = Double(b.count)
        guard n1 > 0, n2 > 0 else { return nil }
        let combined = (a.map { ($0, 0) } + b.map { ($0, 1) }).sorted { $0.0 < $1.0 }
        let total = Double(combined.count)
        var rankSumA = 0.0
        var tieTerm = 0.0
        var index = 0
        while index < combined.count {
            var end = index
            while end + 1 < combined.count, combined[end + 1].0 == combined[index].0 { end += 1 }
            let groupSize = Double(end - index + 1)
            let averageRank = (Double(index + 1) + Double(end + 1)) / 2
            for member in index...end where combined[member].1 == 0 { rankSumA += averageRank }
            tieTerm += groupSize * groupSize * groupSize - groupSize
            index = end + 1
        }
        let u1 = rankSumA - n1 * (n1 + 1) / 2
        let mean = n1 * n2 / 2
        let variance = n1 * n2 / 12 * ((total + 1) - tieTerm / (total * (total - 1)))
        guard variance > 0 else { return 1 }
        let deviation = u1 - mean
        let corrected = deviation == 0 ? 0 : deviation - 0.5 * (deviation > 0 ? 1 : -1)
        let z = corrected / variance.squareRoot()
        return Swift.min(1, erfc(abs(z) / 2.0.squareRoot()))
    }
}
