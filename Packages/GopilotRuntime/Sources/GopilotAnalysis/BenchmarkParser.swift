import Foundation

public struct BenchSample: Sendable, Equatable, Codable {
    public let name: String
    public let procs: Int?
    public let iterations: Int
    public let metrics: [String: Double]

    public init(name: String, procs: Int?, iterations: Int, metrics: [String: Double]) {
        self.name = name
        self.procs = procs
        self.iterations = iterations
        self.metrics = metrics
    }

    public var nsPerOp: Double? { metrics["ns/op"] }
    public var bytesPerOp: Double? { metrics["B/op"] }
    public var allocsPerOp: Double? { metrics["allocs/op"] }
}

public struct BenchmarkParseResult: Sendable, Equatable {
    public let samples: [BenchSample]
    public let environment: [String: String]
    public let ignoredLineCount: Int
}

public enum BenchmarkParser {
    private static let environmentKeys: Set<String> = ["goos", "goarch", "pkg", "cpu"]

    public static func parse(_ output: String) -> BenchmarkParseResult {
        var samples: [BenchSample] = []
        var environment: [String: String] = [:]
        var ignored = 0
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon])
                if environmentKeys.contains(key) {
                    environment[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            if let sample = parseResultLine(line) {
                samples.append(sample)
            } else {
                ignored += 1
            }
        }
        return BenchmarkParseResult(samples: samples, environment: environment, ignoredLineCount: ignored)
    }

    static func parseResultLine(_ line: String) -> BenchSample? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 4, fields[0].hasPrefix("Benchmark"), let iterations = Int(fields[1]), iterations > 0 else { return nil }
        guard (fields.count - 2) % 2 == 0 else { return nil }
        var metrics: [String: Double] = [:]
        var index = 2
        while index + 1 < fields.count {
            guard let value = Double(fields[index]), value.isFinite else { return nil }
            let unit = fields[index + 1]
            guard !unit.isEmpty, metrics[unit] == nil else { return nil }
            metrics[unit] = value
            index += 2
        }
        guard !metrics.isEmpty else { return nil }
        let (name, procs) = splitProcs(fields[0])
        return BenchSample(name: name, procs: procs, iterations: iterations, metrics: metrics)
    }

    private static func splitProcs(_ full: String) -> (String, Int?) {
        guard let dash = full.lastIndex(of: "-") else { return (full, nil) }
        let suffix = full[full.index(after: dash)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let procs = Int(suffix) else { return (full, nil) }
        return (String(full[full.startIndex..<dash]), procs)
    }
}
