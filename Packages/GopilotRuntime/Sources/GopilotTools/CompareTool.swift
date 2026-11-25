import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis

extension ExecutionKit {
    func compareBenchmarks() -> ExecTool {
        makeTool(
            name: "compare_benchmarks",
            description: "Compare two finished benchmark runs (baseline and candidate) from run_benchmark. The verdict is exactly the statistical comparator's: incomparable, inconclusive, faster or slower, with limitations and the method used. A microbenchmark result is never an end-to-end speedup.",
            parameters: ToolSchemas.object(properties: [
                #""baselineRunID":{"type":"string","minLength":1,"maxLength":64}"#,
                #""candidateRunID":{"type":"string","minLength":1,"maxLength":64}"#
            ], required: ["baselineRunID", "candidateRunID"])
        ) { callID, args in
            guard let baselineID = UUID(uuidString: args["baselineRunID"]?.stringValue ?? ""),
                  let candidateID = UUID(uuidString: args["candidateRunID"]?.stringValue ?? "") else {
                return failure(callID: callID, code: .invalidArguments, message: "baselineRunID and candidateRunID must be run IDs returned by run_benchmark.")
            }
            guard baselineID != candidateID else {
                return failure(callID: callID, code: .invalidArguments, message: "Baseline and candidate must be two different runs.")
            }
            let baseline: StoredRun
            let candidate: StoredRun
            switch await loadBenchmarkRun(baselineID, callID: callID, role: "baseline") {
            case .reply(let reply): return reply
            case .value(let run): baseline = run
            }
            switch await loadBenchmarkRun(candidateID, callID: callID, role: "candidate") {
            case .reply(let reply): return reply
            case .value(let run): candidate = run
            }
            guard let baselineRun = baseline.benchmark, let candidateRun = candidate.benchmark else {
                return failure(callID: callID, code: .incompatibleArtifact, message: "Both runs must be benchmark runs.")
            }

            let snapshot = await context.snapshot()
            let comparison = BenchmarkComparator.compare(baseline: baselineRun, candidate: candidateRun)
            var fields: [String: Any] = [
                "baselineRunID": baselineID.uuidString,
                "candidateRunID": candidateID.uuidString,
                "limitations": comparison.limitations.map { JSONText.clip(redact($0), 300) },
                "method": comparison.method,
                "claimScope": "Microbenchmark medians only; this is not an end-to-end latency or throughput claim."
            ]
            switch comparison.comparability {
            case .comparable:
                fields["comparability"] = "comparable"
            case .incomparable(let fieldsDiffering):
                fields["comparability"] = "incomparable"
                fields["differingFields"] = fieldsDiffering
            }
            var counts: [String: Int] = [:]
            for result in comparison.results { counts[result.verdict.rawValue, default: 0] += 1 }
            fields["verdictCounts"] = counts

            let items = comparison.results.map { renderResult($0, comparison: comparison) }
            let shown = ItemFit.shownCount(base: fields, key: "results", items: items)
            fields["results"] = Array(items.prefix(shown))
            let truncated = shown < items.count
            if truncated { fields["omittedResults"] = items.count - shown }
            return await self.found(callID: callID, toolName: "compare_benchmarks", kind: .benchmark, snapshotID: snapshot.id, fields: fields, truncated: truncated)
        }
    }

    func loadBenchmarkRun(_ id: UUID, callID: String, role: String) async -> Step<StoredRun> {
        guard let stored = await context.runs.run(id) else {
            return .reply(failure(callID: callID, code: .notFound, message: "The \(role) run is not known in this session."))
        }
        guard stored.kind == .benchmark else {
            return .reply(failure(callID: callID, code: .incompatibleArtifact, message: "The \(role) run is a test run, not a benchmark run."))
        }
        guard runStatusLabel(stored.record) == "passed" else {
            return .reply(failure(callID: callID, code: .incompatibleArtifact, message: "The \(role) run did not pass (status \(runStatusLabel(stored.record))), so its samples cannot be compared."))
        }
        return .value(stored)
    }

    func renderResult(_ result: BenchmarkResult, comparison: BenchmarkComparison) -> [String: Any] {
        var object: [String: Any] = [
            "name": redact(result.name),
            "verdict": result.verdict.rawValue,
            "notes": result.notes.map { JSONText.clip(redact($0), 300) },
            "metrics": result.metrics.map(renderMetric)
        ]
        switch ProfileEvidenceBuilder.speedupClaim(fromBenchmark: comparison, benchmark: result.name) {
        case .supported(let statement): object["speedupClaim"] = ["supported": true, "statement": JSONText.clip(redact(statement), 500)]
        case .refused(let reason): object["speedupClaim"] = ["supported": false, "reason": JSONText.clip(redact(reason), 500)]
        }
        return object
    }

    func renderMetric(_ metric: MetricComparison) -> [String: Any] {
        var object: [String: Any] = [
            "metric": metric.metric,
            "change": metric.change.rawValue,
            "reasons": metric.reasons.map { JSONText.clip($0, 240) },
            "deltaAbsolute": JSONText.finite(metric.deltaAbsolute),
            "deltaPercent": JSONText.finite(metric.deltaPercent),
            "percentNotApplicable": metric.percentIsNotApplicable,
            "pValue": JSONText.finite(metric.pValue)
        ]
        if metric.percentIsNotApplicable { object["deltaPercentNote"] = "N/A: the baseline median is zero; use deltaAbsolute." }
        if !metric.missingFrom.isEmpty { object["missingFrom"] = metric.missingFrom }
        if let baseline = metric.baseline { object["baseline"] = summary(baseline) }
        if let candidate = metric.candidate { object["candidate"] = summary(candidate) }
        return object
    }

    func summary(_ value: SampleSummary) -> [String: Any] {
        [
            "count": value.count,
            "median": JSONText.finite(value.median),
            "q1": JSONText.finite(value.q1),
            "q3": JSONText.finite(value.q3),
            "min": JSONText.finite(value.min),
            "max": JSONText.finite(value.max),
            "outlierCount": value.outliers.count,
            "outliers": value.outliers.prefix(10).map { JSONText.finite($0) }
        ]
    }
}
