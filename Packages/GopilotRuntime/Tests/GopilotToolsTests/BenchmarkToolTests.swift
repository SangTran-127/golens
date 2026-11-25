import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private let benchArgs = #"{"benchmarkIDs":["./pkg#BenchmarkEncode"]}"#
private let baselineSamples: [Double] = (0..<10).map { 100 + Double($0) }
private let fasterSamples: [Double] = (0..<10).map { 50 + Double($0) }

private struct BenchRun {
    let runID: String
    let envelope: ToolResultEnvelope
    var data: [String: Any] { decode(envelope) }
}

private func runBench(_ h: Harness, output: String, args: String = benchArgs, id: String) async throws -> BenchRun {
    h.fakeGo.setBehavior("bench")
    h.fakeGo.setBenchOutput(output)
    let envelope = try await h.call("run_benchmark", args, id: id)
    return BenchRun(runID: decode(envelope)["runID"] as? String ?? "", envelope: envelope)
}

private func compare(_ h: Harness, _ baseline: BenchRun, _ candidate: BenchRun) async throws -> ToolResultEnvelope {
    try await h.call("compare_benchmarks", "{\"baselineRunID\":\"\(baseline.runID)\",\"candidateRunID\":\"\(candidate.runID)\"}", id: "compare")
}

private func firstResult(_ envelope: ToolResultEnvelope) -> [String: Any] {
    nestedList(decode(envelope), "results").first ?? [:]
}

private func nsMetric(_ result: [String: Any]) -> [String: Any] {
    (result["metrics"] as? [[String: Any]] ?? []).first { $0["metric"] as? String == "ns/op" } ?? [:]
}

@Suite("Benchmark tools", .serialized)
struct BenchmarkToolTests {
    @Test func benchmarkRunKeepsRawSamplesAndReturnsAFingerprint() async throws {
        try await withHarness { h in
            let run = try await runBench(h, output: benchOutput(nsPerOp: baselineSamples), id: "bench-1")
            let data = run.data
            #expect(run.envelope.status == .ok)
            #expect(data["outcome"] as? String == "passed")
            let argv = try #require(data["argv"] as? [String])
            #expect(argv.contains("-bench"))
            #expect(argv.contains("^(BenchmarkEncode)$"))
            #expect(argv.contains("-benchmem"))
            #expect(argv.contains("-count=10"))
            #expect(argv.contains("^$"))
            #expect(!argv.contains { $0.hasPrefix("-race") || $0.contains("profile") })

            let fingerprint = try #require(data["fingerprint"] as? [String: Any])
            #expect(fingerprint["goVersion"] as? String == "go1.22")
            #expect(fingerprint["count"] as? Int == 10)
            #expect(fingerprint["cpu"] as? String == "Test CPU")
            #expect(fingerprint["os"] as? String == "darwin")
            #expect(fingerprint["arch"] as? String == "arm64")
            #expect(fingerprint["package"] as? String == "example.test/pkg")
            #expect(fingerprint["benchmarkSelector"] as? String == "./pkg#BenchmarkEncode")
            #expect(fingerprint["instrumentation"] as? [String] == [])
            #expect(fingerprint["sourceHash"] as? String == data["sourceHash"] as? String)

            let benchmarks = nestedList(data, "benchmarks")
            #expect(benchmarks.count == 1)
            #expect(benchmarks[0]["name"] as? String == "BenchmarkEncode")
            #expect(benchmarks[0]["sampleCount"] as? Int == 10)
            #expect((benchmarks[0]["nsPerOpSamples"] as? [Double]) == baselineSamples)
            #expect(data["parsedSampleCount"] as? Int == 10)

            let card = try #require(h.approvals.cards.snapshot.first)
            #expect(card.operation == .runBenchmark)
            #expect(card.benchmarkNames == ["BenchmarkEncode"])
            #expect(card.testNames.isEmpty)
            #expect(card.goCount == 10)
            #expect(card.benchtime == nil)
            #expect(card.timeoutSeconds == 300)

            let evidence = try #require(await h.evidence.resolve(id: run.envelope.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidence.kind == .benchmark)

            let runID = try #require(UUID(uuidString: run.runID))
            let stored = try #require(await h.runs.run(runID))
            #expect(stored.benchmark?.samples.count == 10)
            #expect(stored.benchmark?.fingerprint.count == 10)
            #expect(stored.output.contains("BenchmarkEncode-8"))
        }
    }

    @Test func countAndBenchtimeFlowIntoArgvCardAndFingerprint() async throws {
        try await withHarness { h in
            let run = try await runBench(h, output: benchOutput(nsPerOp: [1, 2, 3]), args: #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":3,"benchtime":"1x","timeoutSeconds":60}"#, id: "bench-1")
            let argv = try #require(run.data["argv"] as? [String])
            #expect(argv.contains("-count=3"))
            #expect(argv.contains("-benchtime=1x"))
            #expect(argv.contains("-timeout=\(60 + ExecutionKit.toolchainTimeoutMargin)s"))
            let fingerprint = try #require(run.data["fingerprint"] as? [String: Any])
            #expect(fingerprint["count"] as? Int == 3)
            #expect(fingerprint["benchtime"] as? String == "1x")
            let card = try #require(h.approvals.cards.snapshot.first)
            #expect(card.goCount == 3)
            #expect(card.benchtime == "1x")
        }
    }

    @Test func aGrantCoversOnlyTheBenchmarkCountItWasApprovedFor() async throws {
        try await withHarness { h in
            let covered = h.targetHash(extra: ["count": "10", "benchtime": ""])
            try await h.grant(selector: "./pkg#BenchmarkEncode", operation: .runBenchmark, targetHash: covered)
            h.fakeGo.setBehavior("bench")
            h.fakeGo.setBenchOutput(benchOutput(nsPerOp: baselineSamples))
            let allowed = try await h.call("run_benchmark", benchArgs)
            #expect(allowed.status == .ok)
            #expect(h.approvals.requestCount == 0)

            h.approvals.fallback.with { $0 = .decline }
            let heavier = try await h.call("run_benchmark", #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":50}"#, id: "call-2")
            #expect(heavier.errorCode == .denied)
            #expect(h.approvals.requestCount == 1)
            #expect(h.approvals.cards.snapshot[0].mismatches.contains(.targetConfig))
            #expect(h.fakeGo.calls == 1)
        }
    }

    @Test func timedRunsRefuseInstrumentationBeforeAnyApprovalOrProcess() async throws {
        try await withHarness { h in
            for benchtime in ["-race", "1s -race", "-cpuprofile"] {
                let result = try await h.call("run_benchmark", "{\"benchmarkIDs\":[\"./pkg#BenchmarkEncode\"],\"benchtime\":\"\(benchtime)\"}")
                #expect(result.errorCode == .invalidArguments, "benchtime \(benchtime)")
            }
            #expect(h.approvals.requestCount == 0)
            #expect(h.fakeGo.calls == 0)
        }
        for flags in ["-race", "-cpuprofile=cpu.out", "-mod=readonly -race"] {
            try await withHarness(extraEnvironment: ["GOFLAGS": flags]) { h in
                let result = try await h.call("run_benchmark", benchArgs)
                #expect(result.errorCode == .invalidArguments, "GOFLAGS \(flags)")
                #expect((decode(result)["message"] as? String)?.contains("timed") == true)
                #expect(h.approvals.requestCount == 0)
                #expect(h.fakeGo.calls == 0)
                let untimed = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestAlpha"]}"#, id: "call-2")
                #expect(decode(untimed)["outcome"] as? String == "passed")
            }
        }
    }

    @Test func benchmarkWithoutParsableSamplesSaysSo() async throws {
        try await withHarness { h in
            let run = try await runBench(h, output: "nothing useful here\n", id: "bench-1")
            #expect(run.data["outcome"] as? String == "passed")
            #expect(run.data["parsedSampleCount"] as? Int == 0)
            #expect((run.data["warning"] as? String)?.contains("No benchmark samples") == true)
            #expect(nestedList(run.data, "benchmarks").isEmpty)
        }
    }

    @Test func clearlyFasterCandidateIsReportedFasterWithAScopedClaim() async throws {
        try await withHarness { h in
            let baseline = try await runBench(h, output: benchOutput(nsPerOp: baselineSamples), id: "bench-base")
            try "package pkg\n\nvar Faster = 1\n".write(to: h.root.appendingPathComponent("a.go"), atomically: true, encoding: .utf8)
            let candidate = try await runBench(h, output: benchOutput(nsPerOp: fasterSamples), id: "bench-cand")
            #expect(baseline.data["sourceHash"] as? String != candidate.data["sourceHash"] as? String)

            let result = try await compare(h, baseline, candidate)
            #expect(result.status == .ok)
            let data = decode(result)
            #expect(data["comparability"] as? String == "comparable")
            #expect((data["method"] as? String)?.contains("Mann-Whitney") == true)
            #expect((data["claimScope"] as? String)?.contains("not an end-to-end") == true)
            let entry = firstResult(result)
            #expect(entry["verdict"] as? String == "faster")
            let ns = nsMetric(entry)
            #expect(ns["change"] as? String == "lower")
            #expect(ns["deltaAbsolute"] as? Double == -50)
            #expect(ns["percentNotApplicable"] as? Bool == false)
            let claim = try #require(entry["speedupClaim"] as? [String: Any])
            #expect(claim["supported"] as? Bool == true)
            #expect((claim["statement"] as? String)?.contains("microbenchmark") == true)
            #expect((data["verdictCounts"] as? [String: Int]) == ["faster": 1])
            #expect(result.evidenceIDs.count == 1)
            let evidence = try #require(await h.evidence.resolve(id: result.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidence.kind == .benchmark)
        }
    }

    @Test func overlappingNoisyRunsAreInconclusiveNotFaster() async throws {
        try await withHarness { h in
            let a: [Double] = [100, 120, 90, 130, 95, 125, 105, 115, 98, 122]
            let b: [Double] = [101, 119, 92, 128, 97, 124, 106, 113, 99, 121]
            let baseline = try await runBench(h, output: benchOutput(nsPerOp: a), id: "bench-base")
            let candidate = try await runBench(h, output: benchOutput(nsPerOp: b), id: "bench-cand")
            let result = try await compare(h, baseline, candidate)
            let entry = firstResult(result)
            #expect(entry["verdict"] as? String == "inconclusive")
            let claim = try #require(entry["speedupClaim"] as? [String: Any])
            #expect(claim["supported"] as? Bool == false)
            #expect(!result.data.contains("\"verdict\":\"faster\""))
        }
    }

    @Test func tooFewSamplesAreInconclusiveWithAReason() async throws {
        try await withHarness { h in
            let args = #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":3}"#
            let baseline = try await runBench(h, output: benchOutput(nsPerOp: [100, 101, 102]), args: args, id: "bench-base")
            let candidate = try await runBench(h, output: benchOutput(nsPerOp: [10, 11, 12]), args: args, id: "bench-cand")
            let entry = firstResult(try await compare(h, baseline, candidate))
            #expect(entry["verdict"] as? String == "inconclusive")
            let reasons = (nsMetric(entry)["reasons"] as? [String]) ?? []
            #expect(reasons.contains { $0.contains("fewer than 10 samples") })
        }
    }

    @Test func zeroBaselineGivesNotApplicablePercentAndAbsoluteDelta() async throws {
        try await withHarness { h in
            let baseline = try await runBench(h, output: benchOutput(nsPerOp: Array(repeating: 0, count: 10)), id: "bench-base")
            let candidate = try await runBench(h, output: benchOutput(nsPerOp: Array(repeating: 5, count: 10)), id: "bench-cand")
            let result = try await compare(h, baseline, candidate)
            let entry = firstResult(result)
            let ns = nsMetric(entry)
            #expect(ns["deltaPercent"] is NSNull)
            #expect(ns["percentNotApplicable"] as? Bool == true)
            #expect(ns["deltaAbsolute"] as? Double == 5)
            #expect((ns["deltaPercentNote"] as? String)?.contains("N/A") == true)
            #expect(entry["verdict"] as? String != "faster")
            #expect(!result.data.contains("Infinity") && !result.data.contains("NaN"))
        }
    }

    @Test func incompatibleFingerprintsAreIncomparableThroughTheTool() async throws {
        try await withHarness { h in
            let baseline = try await runBench(h, output: benchOutput(nsPerOp: baselineSamples), id: "bench-base")
            let otherCount = try await runBench(h, output: benchOutput(nsPerOp: fasterSamples + [50, 51]), args: #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":12}"#, id: "bench-count")
            let byCount = try await compare(h, baseline, otherCount)
            let countData = decode(byCount)
            #expect(countData["comparability"] as? String == "incomparable")
            #expect((countData["differingFields"] as? [String])?.contains("count") == true)
            let countEntry = firstResult(byCount)
            #expect(countEntry["verdict"] as? String == "incomparable")
            #expect((countEntry["speedupClaim"] as? [String: Any])?["supported"] as? Bool == false)
            #expect(nestedList(countEntry, "metrics").isEmpty)

            let otherCPU = try await runBench(h, output: benchOutput(nsPerOp: fasterSamples, cpu: "Different CPU"), id: "bench-cpu")
            let byCPU = try await compare(h, baseline, otherCPU)
            #expect((decode(byCPU)["differingFields"] as? [String])?.contains("cpu") == true)
            #expect(firstResult(byCPU)["verdict"] as? String == "incomparable")
        }
    }

    @Test func compareRefusesFailedTestAndUnknownRunsAndSelfComparison() async throws {
        try await withHarness { h in
            let good = try await runBench(h, output: benchOutput(nsPerOp: baselineSamples), id: "bench-good")
            h.fakeGo.setBehavior("benchfail")
            let failedEnvelope = try await h.call("run_benchmark", benchArgs, id: "bench-bad")
            #expect(decode(failedEnvelope)["outcome"] as? String == "failed")
            let failed = BenchRun(runID: decode(failedEnvelope)["runID"] as? String ?? "", envelope: failedEnvelope)
            let withFailed = try await compare(h, good, failed)
            #expect(withFailed.errorCode == .incompatibleArtifact)

            h.fakeGo.setBehavior("pass")
            let testEnvelope = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestAlpha"]}"#, id: "test-run")
            let testRun = BenchRun(runID: decode(testEnvelope)["runID"] as? String ?? "", envelope: testEnvelope)
            #expect(try await compare(h, good, testRun).errorCode == .incompatibleArtifact)

            let unknown = BenchRun(runID: UUID().uuidString, envelope: good.envelope)
            #expect(try await compare(h, good, unknown).errorCode == .notFound)
            #expect(try await compare(h, good, good).errorCode == .invalidArguments)
            let malformed = try await h.call("compare_benchmarks", #"{"baselineRunID":"nope","candidateRunID":"nope"}"#)
            #expect(malformed.errorCode == .invalidArguments)
        }
    }
}
