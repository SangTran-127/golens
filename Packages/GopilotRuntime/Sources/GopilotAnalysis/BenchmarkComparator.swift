import Foundation

public struct BenchmarkFingerprint: Sendable, Equatable, Codable {
    public var cpu: String?
    public var goVersion: String?
    public var os: String?
    public var arch: String?
    public var gomaxprocs: Int?
    public var tags: [String]?
    public var buildFlags: [String]?
    public var package: String?
    public var benchmarkSelector: String?
    public var datasetID: String?
    public var environment: [String: String]?
    public var benchtime: String?
    public var count: Int?
    public var instrumentation: [String]?
    public var sourceHash: String?

    public init(cpu: String? = nil, goVersion: String? = nil, os: String? = nil, arch: String? = nil, gomaxprocs: Int? = nil, tags: [String]? = nil, buildFlags: [String]? = nil, package: String? = nil, benchmarkSelector: String? = nil, datasetID: String? = nil, environment: [String: String]? = nil, benchtime: String? = nil, count: Int? = nil, instrumentation: [String]? = nil, sourceHash: String? = nil) {
        self.cpu = cpu
        self.goVersion = goVersion
        self.os = os
        self.arch = arch
        self.gomaxprocs = gomaxprocs
        self.tags = tags
        self.buildFlags = buildFlags
        self.package = package
        self.benchmarkSelector = benchmarkSelector
        self.datasetID = datasetID
        self.environment = environment
        self.benchtime = benchtime
        self.count = count
        self.instrumentation = instrumentation
        self.sourceHash = sourceHash
    }

    public func filling(from parsed: [String: String]) -> BenchmarkFingerprint {
        var copy = self
        if copy.cpu == nil { copy.cpu = parsed["cpu"] }
        if copy.os == nil { copy.os = parsed["goos"] }
        if copy.arch == nil { copy.arch = parsed["goarch"] }
        if copy.package == nil { copy.package = parsed["pkg"] }
        return copy
    }

    var nonSourceFields: [(name: String, value: String?)] {
        [
            ("cpu", cpu),
            ("goVersion", goVersion),
            ("os", os),
            ("arch", arch),
            ("gomaxprocs", gomaxprocs.map(String.init)),
            ("tags", tags.map { $0.sorted().joined(separator: ",") }),
            ("buildFlags", buildFlags.map { $0.sorted().joined(separator: " ") }),
            ("package", package),
            ("benchmarkSelector", benchmarkSelector),
            ("datasetID", datasetID),
            ("environment", environment.map { ContentHash.combined($0) }),
            ("benchtime", benchtime),
            ("count", count.map(String.init)),
            ("instrumentation", instrumentation.map { $0.sorted().joined(separator: ",") })
        ]
    }
}

public struct BenchmarkRun: Sendable, Equatable {
    public let fingerprint: BenchmarkFingerprint
    public let samples: [BenchSample]

    public init(fingerprint: BenchmarkFingerprint, samples: [BenchSample]) {
        self.fingerprint = fingerprint
        self.samples = samples
    }
}

public enum Comparability: Sendable, Equatable {
    case comparable(limitations: [String])
    case incomparable(differingFields: [String])
}

public enum BenchmarkVerdict: String, Sendable, Equatable, Codable {
    case faster
    case slower
    case inconclusive
    case incomparable
}

public enum ChangeDirection: String, Sendable, Equatable, Codable {
    case lower
    case higher
    case inconclusive
}

public struct MetricComparison: Sendable, Equatable {
    public let metric: String
    public let baseline: SampleSummary?
    public let candidate: SampleSummary?
    public let deltaAbsolute: Double?
    public let deltaPercent: Double?
    public let pValue: Double?
    public let change: ChangeDirection
    public let reasons: [String]
    public let missingFrom: [String]

    public var percentIsNotApplicable: Bool { deltaAbsolute != nil && deltaPercent == nil }
}

public struct BenchmarkResult: Sendable, Equatable {
    public let name: String
    public let verdict: BenchmarkVerdict
    public let metrics: [MetricComparison]
    public let notes: [String]

    public func metric(_ name: String) -> MetricComparison? { metrics.first { $0.metric == name } }
}

public struct BenchmarkComparison: Sendable, Equatable {
    public let comparability: Comparability
    public let results: [BenchmarkResult]
    public let limitations: [String]
    public let method = BenchmarkStatistics.methodDescription

    public func result(for name: String) -> BenchmarkResult? { results.first { $0.name == name } }
}

public enum BenchmarkComparator {
    public static let minimumSamplesPerSide = 10
    public static let significanceLevel = 0.05
    public static let timeMetric = "ns/op"

    public static func compare(baseline: BenchmarkRun, candidate: BenchmarkRun) -> BenchmarkComparison {
        let names = orderedNames(baseline.samples + candidate.samples)
        var differing: [String] = []
        var limitations: [String] = []
        let candidateFields = candidate.fingerprint.nonSourceFields
        for (index, field) in baseline.fingerprint.nonSourceFields.enumerated() {
            let other = candidateFields[index].value
            switch (field.value, other) {
            case (.some(let a), .some(let b)):
                if a != b { differing.append(field.name) }
            case (nil, nil):
                limitations.append("\(field.name) is unknown on both sides")
            default:
                limitations.append("\(field.name) is unknown on the \(field.value == nil ? "baseline" : "candidate") side")
            }
        }
        let baselineProcs = Set(baseline.samples.compactMap(\.procs))
        let candidateProcs = Set(candidate.samples.compactMap(\.procs))
        if !baselineProcs.isEmpty, !candidateProcs.isEmpty, baselineProcs != candidateProcs, !differing.contains("gomaxprocs") {
            differing.append("gomaxprocs")
        }

        switch (baseline.fingerprint.sourceHash, candidate.fingerprint.sourceHash) {
        case (.some(let a), .some(let b)) where a == b:
            limitations.append("source hashes are identical: this compares unchanged code and measures noise only")
        case (nil, _), (_, nil):
            limitations.append("source hash is unknown on at least one side")
        default:
            break
        }

        if !differing.isEmpty {
            let results = names.map { BenchmarkResult(name: $0, verdict: .incomparable, metrics: [], notes: ["fingerprint differs in: \(differing.joined(separator: ", "))"]) }
            return BenchmarkComparison(comparability: .incomparable(differingFields: differing), results: results, limitations: limitations)
        }

        let results = names.map { compareBenchmark(name: $0, baseline: baseline.samples, candidate: candidate.samples) }
        return BenchmarkComparison(comparability: .comparable(limitations: limitations), results: results, limitations: limitations)
    }

    private static func orderedNames(_ samples: [BenchSample]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for sample in samples where seen.insert(sample.name).inserted { out.append(sample.name) }
        return out
    }

    private static func compareBenchmark(name: String, baseline: [BenchSample], candidate: [BenchSample]) -> BenchmarkResult {
        let base = baseline.filter { $0.name == name }
        let cand = candidate.filter { $0.name == name }
        var notes: [String] = []
        if base.isEmpty { notes.append("benchmark is absent from the baseline run") }
        if cand.isEmpty { notes.append("benchmark is absent from the candidate run") }

        var metricNames = Set<String>()
        for sample in base + cand { metricNames.formUnion(sample.metrics.keys) }
        metricNames.insert(timeMetric)
        let ordered = metricNames.sorted { lhs, rhs in
            if lhs == timeMetric { return true }
            if rhs == timeMetric { return false }
            return lhs < rhs
        }
        let metrics = ordered.map { compareMetric($0, baseline: base, candidate: cand) }
        for metric in metrics where !metric.missingFrom.isEmpty && metric.metric != timeMetric {
            notes.append("\(metric.metric) is missing from: \(metric.missingFrom.joined(separator: ", "))")
        }
        let verdict: BenchmarkVerdict
        switch metrics.first(where: { $0.metric == timeMetric })?.change {
        case .lower: verdict = .faster
        case .higher: verdict = .slower
        default: verdict = .inconclusive
        }
        return BenchmarkResult(name: name, verdict: verdict, metrics: metrics, notes: notes)
    }

    private static func compareMetric(_ metric: String, baseline: [BenchSample], candidate: [BenchSample]) -> MetricComparison {
        let a = baseline.compactMap { $0.metrics[metric] }
        let b = candidate.compactMap { $0.metrics[metric] }
        var missing: [String] = []
        if a.isEmpty { missing.append("baseline") }
        if b.isEmpty { missing.append("candidate") }
        guard missing.isEmpty, let summaryA = BenchmarkStatistics.summarize(a), let summaryB = BenchmarkStatistics.summarize(b) else {
            return MetricComparison(metric: metric, baseline: BenchmarkStatistics.summarize(a), candidate: BenchmarkStatistics.summarize(b), deltaAbsolute: nil, deltaPercent: nil, pValue: nil, change: .inconclusive, reasons: ["metric missing from \(missing.joined(separator: " and "))"], missingFrom: missing)
        }

        let deltaAbsolute = summaryB.median - summaryA.median
        let deltaPercent: Double? = summaryA.median == 0 ? nil : deltaAbsolute / summaryA.median * 100
        let p = BenchmarkStatistics.mannWhitneyTwoSidedP(a, b)
        var reasons: [String] = []
        if summaryA.count < minimumSamplesPerSide || summaryB.count < minimumSamplesPerSide {
            reasons.append("fewer than \(minimumSamplesPerSide) samples on a side (baseline \(summaryA.count), candidate \(summaryB.count))")
        }
        if let p, p >= significanceLevel {
            reasons.append("difference is not significant (Mann-Whitney p=\(String(format: "%.4f", p)))")
        }
        if summaryA.q1 <= summaryB.q3 && summaryB.q1 <= summaryA.q3 {
            reasons.append("interquartile ranges overlap, so run-to-run noise covers the difference")
        }
        if deltaAbsolute == 0 {
            reasons.append("medians are equal")
        }
        let change: ChangeDirection
        if reasons.isEmpty {
            change = deltaAbsolute < 0 ? .lower : .higher
        } else {
            change = .inconclusive
        }
        return MetricComparison(metric: metric, baseline: summaryA, candidate: summaryB, deltaAbsolute: deltaAbsolute, deltaPercent: deltaPercent, pValue: p, change: change, reasons: reasons, missingFrom: [])
    }
}
