import Foundation

public struct EvidenceSummary: Sendable, Equatable {
    public let profileID: String
    public let observations: [String]
    public let inferences: [String]
    public let limitations: [String]

    public var text: String {
        var lines = observations
        lines += inferences
        lines += limitations.map { "Limitation: \($0)" }
        return lines.joined(separator: "\n")
    }
}

public enum SpeedupClaim: Sendable, Equatable {
    case refused(reason: String)
    case supported(statement: String)
}

public enum ProfileEvidenceBuilder {
    public static let observationLabel = "Profile Observation:"
    public static let inferenceLabel = "Inference:"

    public static func summarize(view: HotspotView, record: ProfileRecord, topCount: Int = 5) -> EvidenceSummary {
        var observations: [String] = []
        var inferences: [String] = []
        var limitations: [String] = []

        var header = "\(observationLabel) profile \(record.id) is a \(record.kind.rawValue) profile with sample type \(record.sampleType) in \(record.unit); total \(format(record.totalValue, unit: record.unit)) over \(record.sampleCount) samples"
        if let duration = record.durationNanos { header += ", collected over \(format(duration, unit: "nanoseconds"))" }
        observations.append(header + ".")

        let top = view.rows.prefix(max(1, topCount))
        for row in top {
            let location = row.file.isEmpty ? "unknown file" : "\(sanitize(row.file)):\(row.line)"
            var line = "\(observationLabel) \(sanitize(row.function)) (\(location)) has flat \(percent(row.flatShare)) (\(format(row.flat, unit: record.unit)) of \(format(view.denominator, unit: record.unit))) and cumulative \(percent(row.cumShare)) (\(format(row.cum, unit: record.unit)))"
            if row.isRecursive { line += "; part of a call cycle" }
            observations.append(line + ".")
        }
        observations.append("\(observationLabel) cumulative values include callees and overlap between callers and callees; they do not add up to a total.")

        for reason in view.incompleteReasons { limitations.append("incomplete data: \(reason.description)") }
        if record.sampleCount <= 1 { limitations.append("the profile holds a single sample, so no ranking is reliable") }
        if record.metadata.isFullyKnown == false {
            limitations.append("workload, config, source and build metadata not all known (\(record.metadata.unknownFieldNames.joined(separator: ", "))); only observations inside this artifact are stated")
        }
        if record.mapping != .verified {
            limitations.append("source mapping is \(record.mapping.rawValue); current file lines may not be the code that ran")
        }
        switch record.kind {
        case .cpu: limitations.append("CPU samples are on-CPU time, not wall-clock time or end-to-end latency")
        case .heapAlloc: limitations.append("allocation values count everything allocated since start, not live memory")
        case .heapInuse: limitations.append("in-use values describe live memory at the last collection, not allocation rate")
        case .block: limitations.append("block values are time spent waiting on synchronization, not CPU cost")
        case .mutex: limitations.append("mutex values are contention delay, not CPU cost")
        }

        let canInfer = record.metadata.isFullyKnown && record.mapping == .verified && record.sampleCount > 1 && !view.incomplete && !view.rows.isEmpty
        if canInfer, let leader = view.rows.first {
            inferences.append("\(inferenceLabel) \(sanitize(leader.function)) is the largest contributor by \(view.ordering.rawValue) \(record.sampleType) in this artifact and is a candidate to investigate; confirm with a timed benchmark before claiming any improvement.")
        } else {
            inferences.append("\(inferenceLabel) withheld: the evidence is not complete or verified enough to go beyond the observations above.")
        }

        return EvidenceSummary(profileID: record.id, observations: observations, inferences: inferences, limitations: limitations)
    }

    public static func speedupClaim(fromProfile view: HotspotView, frameID: String) -> SpeedupClaim {
        guard let row = view.rows.first(where: { $0.frameID == frameID }) else {
            return .refused(reason: "frame is not part of this profile view")
        }
        return .refused(reason: "\(sanitize(row.function)) accounts for \(percent(row.flatShare)) of \(view.sampleType) samples; a profile share is not a measured speedup, and \(view.totalSampleCount) samples cannot establish the effect of changing it. Run a timed benchmark comparison.")
    }

    public static func speedupClaim(fromBenchmark comparison: BenchmarkComparison, benchmark: String) -> SpeedupClaim {
        guard case .comparable = comparison.comparability else {
            return .refused(reason: "baseline and candidate runs are not comparable")
        }
        guard let result = comparison.result(for: benchmark), let time = result.metric(BenchmarkComparator.timeMetric) else {
            return .refused(reason: "benchmark \(sanitize(benchmark)) was not measured on both sides")
        }
        guard result.verdict == .faster, let baseline = time.baseline, let candidate = time.candidate else {
            return .refused(reason: "benchmark \(sanitize(benchmark)) is \(result.verdict.rawValue): \(time.reasons.joined(separator: "; "))")
        }
        let delta = time.deltaPercent.map { String(format: "%.1f%%", abs($0)) } ?? "N/A"
        let p = time.pValue.map { String(format: "%.4f", $0) } ?? "n/a"
        return .supported(statement: "Benchmark \(sanitize(benchmark)) median ns/op went from \(format(baseline.median)) to \(format(candidate.median)) (\(delta) lower, Mann-Whitney p=\(p), \(baseline.count) and \(candidate.count) samples). This is a microbenchmark result, not an end-to-end latency claim.")
    }

    public static func sanitize(_ text: String, limit: Int = 200) -> String {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) || scalar == "`" {
                cleaned.unicodeScalars.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "..."
    }

    static func percent(_ share: Double?) -> String {
        guard let share else { return "N/A" }
        return String(format: "%.1f%%", share * 100)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func format(_ value: Int64, unit: String) -> String {
        switch unit {
        case "nanoseconds":
            let v = Double(value)
            if v < 1_000 { return "\(value)ns" }
            if v < 1_000_000 { return String(format: "%.1fus", v / 1e3) }
            if v < 1_000_000_000 { return String(format: "%.2fms", v / 1e6) }
            return String(format: "%.2fs", v / 1e9)
        case "bytes":
            let v = Double(value)
            if v < 1024 { return "\(value) B" }
            if v < 1024 * 1024 { return String(format: "%.1f KiB", v / 1024) }
            return String(format: "%.2f MiB", v / (1024 * 1024))
        default:
            return "\(value) \(unit)"
        }
    }
}
