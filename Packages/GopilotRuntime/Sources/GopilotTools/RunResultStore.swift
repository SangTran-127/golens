import Foundation
import GopilotAnalysis

public struct StoredRun: Sendable, Equatable {
    public let record: RunRecord
    public let kind: GoCommand.Kind
    public let packageSelector: String
    public let output: String
    public let benchmark: BenchmarkRun?
    public let ignoredBenchmarkLines: Int
    public let runsSavedVersion: Bool
    public let unsavedPaths: [String]
    public let sourceFileCount: Int
}

public actor RunResultStore {
    private var runs: [UUID: StoredRun] = [:]
    private var order: [UUID] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    public func store(_ run: StoredRun) {
        if runs[run.record.runID] == nil { order.append(run.record.runID) }
        runs[run.record.runID] = run
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            runs[oldest] = nil
        }
    }

    public func run(_ id: UUID) -> StoredRun? {
        runs[id]
    }

    public func runIDs() -> [UUID] {
        order
    }

    @discardableResult
    public func attach(runID: UUID, from arbiter: RunArbiter, redactor: @Sendable (String) -> String = { $0 }) async -> Bool {
        guard let record = await arbiter.record(for: runID) else { return false }
        let output = redactor(await arbiter.output(for: runID) ?? "")
        let isBenchmark = record.argv.contains { $0 == "-bench" }
        var benchmark: BenchmarkRun?
        var ignored = 0
        if isBenchmark {
            let parsed = BenchmarkParser.parse(output)
            ignored = parsed.ignoredLineCount
            benchmark = BenchmarkRun(fingerprint: BenchmarkFingerprint(sourceHash: record.sourceHash).filling(from: parsed.environment), samples: parsed.samples)
        }
        store(StoredRun(
            record: record,
            kind: isBenchmark ? .benchmark : .test,
            packageSelector: record.argv.last ?? "",
            output: output,
            benchmark: benchmark,
            ignoredBenchmarkLines: ignored,
            runsSavedVersion: false,
            unsavedPaths: [],
            sourceFileCount: 0
        ))
        return true
    }
}
