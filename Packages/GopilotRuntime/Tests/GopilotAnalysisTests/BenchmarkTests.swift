import Foundation
import Testing
@testable import GopilotAnalysis

private func sample(_ name: String = "BenchmarkMake", ns: Double?, bytes: Double? = nil, allocs: Double? = nil, procs: Int? = 8, extra: [String: Double] = [:]) -> BenchSample {
    var metrics = extra
    if let ns { metrics["ns/op"] = ns }
    if let bytes { metrics["B/op"] = bytes }
    if let allocs { metrics["allocs/op"] = allocs }
    return BenchSample(name: name, procs: procs, iterations: 1000, metrics: metrics)
}

private func baseFingerprint(sourceHash: String = "hash-a") -> BenchmarkFingerprint {
    BenchmarkFingerprint(
        cpu: "Apple M3", goVersion: "go1.27.1", os: "darwin", arch: "arm64", gomaxprocs: 8, tags: [], buildFlags: ["-mod=readonly"],
        package: "example.test/slug", benchmarkSelector: "^(BenchmarkMake)$", datasetID: "small", environment: ["GOFLAGS": "-mod=readonly"],
        benchtime: "1s", count: 12, instrumentation: [], sourceHash: sourceHash
    )
}

private func run(_ values: [Double], fingerprint: BenchmarkFingerprint = baseFingerprint(), name: String = "BenchmarkMake") -> BenchmarkRun {
    BenchmarkRun(fingerprint: fingerprint, samples: values.map { sample(name, ns: $0) })
}

@Suite("Benchmark parser")
struct BenchmarkParserTests {
    let output = """
    goos: darwin
    goarch: arm64
    pkg: example.test/slug
    cpu: Apple M3 Pro
    BenchmarkMake-8   	  500000	      2345.5 ns/op	     512 B/op	       4 allocs/op
    BenchmarkMake-8   	  500000	      2345.5 ns/op	     512 B/op	       4 allocs/op
    BenchmarkMake-8   	  480000	      2401.0 ns/op	     512 B/op	       4 allocs/op
    some log line from the code under test
    BenchmarkSub/size=10-8   	 1000000	       100 ns/op	  25.5 MB/s	      1.5 widgets/op
    BenchmarkBroken-8 notanumber 12 ns/op
    BenchmarkNoResult
    --- FAIL: BenchmarkOther-8
    PASS
    ok  	example.test/slug	4.2s
    """

    @Test func keepsDuplicatesAndStripsProcsSuffix() {
        let result = BenchmarkParser.parse(output)
        let make = result.samples.filter { $0.name == "BenchmarkMake" }
        #expect(make.count == 3)
        #expect(make.map(\.nsPerOp) == [2345.5, 2345.5, 2401.0])
        #expect(make.allSatisfy { $0.procs == 8 })
        #expect(make[0].bytesPerOp == 512)
        #expect(make[0].allocsPerOp == 4)
        #expect(make[2].iterations == 480000)
    }

    @Test func parsesCustomMetricsAndSubBenchmarkNames() throws {
        let result = BenchmarkParser.parse(output)
        let sub = try #require(result.samples.first { $0.name == "BenchmarkSub/size=10" })
        #expect(sub.metrics["MB/s"] == 25.5)
        #expect(sub.metrics["widgets/op"] == 1.5)
        #expect(sub.bytesPerOp == nil)
    }

    @Test func toleratesNoiseAndReportsEnvironment() {
        let result = BenchmarkParser.parse(output)
        #expect(result.samples.count == 4)
        #expect(result.environment == ["goos": "darwin", "goarch": "arm64", "pkg": "example.test/slug", "cpu": "Apple M3 Pro"])
        #expect(result.ignoredLineCount >= 5)
    }

    @Test func benchmemAbsenceLeavesMetricsNil() throws {
        let result = BenchmarkParser.parse("BenchmarkX-4   100   55.5 ns/op\n")
        let only = try #require(result.samples.first)
        #expect(only.nsPerOp == 55.5)
        #expect(only.bytesPerOp == nil)
        #expect(only.allocsPerOp == nil)
    }

    @Test func nameWithoutProcsSuffixIsKept() throws {
        let only = try #require(BenchmarkParser.parse("BenchmarkPlain   10   5 ns/op\n").samples.first)
        #expect(only.name == "BenchmarkPlain")
        #expect(only.procs == nil)
    }

    @Test func rejectsRepeatedUnitsAndNonFiniteValues() {
        #expect(BenchmarkParser.parse("BenchmarkX-4 10 5 ns/op 6 ns/op\n").samples.isEmpty)
        #expect(BenchmarkParser.parse("BenchmarkX-4 10 NaN ns/op\n").samples.isEmpty)
        #expect(BenchmarkParser.parse("BenchmarkX-4 0 5 ns/op\n").samples.isEmpty)
    }

    @Test func parsesRealGoBenchmarkOutput() async throws {
        try #require(TestSupport.goAvailable)
        let root = try TestSupport.writeModule(name: "bench", files: [
            "bench_test.go": "package bench\n\nimport \"testing\"\n\nvar sink int\n\nfunc BenchmarkSum(b *testing.B) {\n\tb.ReportAllocs()\n\tfor i := 0; i < b.N; i++ {\n\t\ts := make([]int, 16)\n\t\tsink += len(s)\n\t}\n}\n"
        ])
        let command = try GoCommandBuilder.benchmark(packages: ["."], benchmarks: ["BenchmarkSum"], count: 3, benchtime: "2000x", timeoutSeconds: 120)
        try GoCommandBuilder.audit(argv: command.argv, timedComparison: true)
        let result = try await ProcessRunExecutor().run(ProcessRunRequest(argv: command.argv, workspaceRoot: root, environment: TestSupport.goEnvironment, deadline: 240))
        #expect(result.exitCode == 0)
        let parsed = BenchmarkParser.parse(result.output)
        let sums = parsed.samples.filter { $0.name == "BenchmarkSum" }
        #expect(sums.count == 3)
        #expect(sums.allSatisfy { ($0.nsPerOp ?? 0) > 0 && $0.iterations == 2000 && $0.bytesPerOp != nil && $0.allocsPerOp != nil })
        #expect(parsed.environment["goos"] == "darwin")
        #expect(parsed.environment["pkg"] == "example.test/bench")
    }
}

@Suite("Benchmark statistics")
struct BenchmarkStatisticsTests {
    @Test func quartilesAndOutliersAreReportedNotDropped() throws {
        let values = [10.0, 11, 12, 13, 14, 15, 16, 17, 18, 19, 500]
        let summary = try #require(BenchmarkStatistics.summarize(values))
        #expect(summary.count == 11)
        #expect(summary.median == 15)
        #expect(summary.q1 == 12.5)
        #expect(summary.q3 == 17.5)
        #expect(summary.iqr == 5)
        #expect(summary.outliers == [500])
        #expect(summary.max == 500)
    }

    @Test func emptyInputHasNoSummary() {
        #expect(BenchmarkStatistics.summarize([]) == nil)
        #expect(BenchmarkStatistics.mannWhitneyTwoSidedP([], [1]) == nil)
    }

    @Test func mannWhitneyMatchesHandComputedNormalApproximation() throws {
        let a = (1...10).map(Double.init)
        let b = (11...20).map(Double.init)
        let p = try #require(BenchmarkStatistics.mannWhitneyTwoSidedP(a, b))
        #expect(abs(p - 0.000183) < 0.00002)
        let reversed = try #require(BenchmarkStatistics.mannWhitneyTwoSidedP(b, a))
        #expect(abs(p - reversed) < 1e-12)
    }

    @Test func identicalAndFullyTiedSamplesGivePOfOne() throws {
        #expect(try #require(BenchmarkStatistics.mannWhitneyTwoSidedP([5, 5, 5, 5], [5, 5, 5, 5])) == 1)
        let interleaved = try #require(BenchmarkStatistics.mannWhitneyTwoSidedP([1, 3, 5, 7, 9, 11], [2, 4, 6, 8, 10, 12]))
        #expect(interleaved > 0.5)
    }

    @Test func tieHandlingUsesAverageRanksAndCorrectedVariance() throws {
        let a = [1.0, 1, 1, 1, 2, 2, 2, 2, 3, 3]
        let b = [3.0, 3, 3, 3, 4, 4, 4, 4, 4, 4]
        let p = try #require(BenchmarkStatistics.mannWhitneyTwoSidedP(a, b))
        #expect(p > 0 && p < 0.01)
        let noTieEquivalent = try #require(BenchmarkStatistics.mannWhitneyTwoSidedP((1...10).map(Double.init), (11...20).map(Double.init)))
        #expect(p > noTieEquivalent)
    }
}

@Suite("Benchmark comparison")
struct BenchmarkComparatorTests {
    @Test func clearSpeedupIsFaster() throws {
        var rng = SeededRandom(seed: 1)
        let baseline = run(rng.values(center: 1000, spread: 15, count: 12))
        let candidate = run(rng.values(center: 800, spread: 15, count: 12), fingerprint: baseFingerprint(sourceHash: "hash-b"))
        let comparison = BenchmarkComparator.compare(baseline: baseline, candidate: candidate)
        guard case .comparable = comparison.comparability else {
            Issue.record("expected comparable")
            return
        }
        let result = try #require(comparison.result(for: "BenchmarkMake"))
        #expect(result.verdict == .faster)
        let time = try #require(result.metric("ns/op"))
        #expect(time.change == .lower)
        let percent = try #require(time.deltaPercent)
        #expect(percent < -15 && percent > -25)
        #expect(try #require(time.pValue) < 0.001)
        #expect(time.reasons.isEmpty)
        #expect(time.baseline?.count == 12)
    }

    @Test func clearRegressionIsSlower() throws {
        var rng = SeededRandom(seed: 2)
        let comparison = BenchmarkComparator.compare(
            baseline: run(rng.values(center: 500, spread: 5, count: 15)),
            candidate: run(rng.values(center: 650, spread: 5, count: 15), fingerprint: baseFingerprint(sourceHash: "hash-b"))
        )
        #expect(try #require(comparison.result(for: "BenchmarkMake")).verdict == .slower)
    }

    @Test func noisyOverlappingSamplesAreInconclusiveNotAFalseSpeedup() throws {
        var rng = SeededRandom(seed: 3)
        let baseline = run(rng.values(center: 1000, spread: 150, count: 12))
        let candidate = run(rng.values(center: 960, spread: 150, count: 12), fingerprint: baseFingerprint(sourceHash: "hash-b"))
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .inconclusive)
        let time = try #require(result.metric("ns/op"))
        #expect(!time.reasons.isEmpty)
        #expect(time.deltaAbsolute != nil)
    }

    @Test func perfectlySeparatedButTooFewSamplesIsInconclusive() throws {
        let baseline = run([1000, 1001, 1002, 1003, 1004])
        let candidate = run([100, 101, 102, 103, 104], fingerprint: baseFingerprint(sourceHash: "hash-b"))
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .inconclusive)
        #expect(try #require(result.metric("ns/op")).reasons.contains { $0.contains("fewer than 10 samples") })
    }

    @Test func nineSamplesOnOneSideStillInconclusive() throws {
        let baseline = run((0..<12).map { 1000 + Double($0) })
        let candidate = run((0..<9).map { 100 + Double($0) }, fingerprint: baseFingerprint(sourceHash: "hash-b"))
        #expect(try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake")).verdict == .inconclusive)
    }

    @Test func zeroBaselineReportsAbsoluteDeltaAndNotApplicablePercent() throws {
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: (0..<12).map { _ in sample(ns: 0, bytes: 0, allocs: 0) })
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: (0..<12).map { _ in sample(ns: 5, bytes: 64, allocs: 2) })
        let comparison = BenchmarkComparator.compare(baseline: baseline, candidate: candidate)
        let result = try #require(comparison.result(for: "BenchmarkMake"))
        let time = try #require(result.metric("ns/op"))
        #expect(time.baseline?.median == 0)
        #expect(time.deltaAbsolute == 5)
        #expect(time.deltaPercent == nil)
        #expect(time.percentIsNotApplicable)
        let bytes = try #require(result.metric("B/op"))
        #expect(bytes.deltaAbsolute == 64)
        #expect(bytes.deltaPercent == nil)
    }

    @Test func zeroBaselineWithIdenticalZeroCandidateIsNotASpeedup() throws {
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: (0..<12).map { _ in sample(ns: 0, bytes: 0) })
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: (0..<12).map { _ in sample(ns: 0, bytes: 0) })
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .inconclusive)
        #expect(result.metric("B/op")?.change == .inconclusive)
    }

    @Test func incompatibleFingerprintFieldsAreListedAndNoVerdictIsGiven() throws {
        var other = baseFingerprint(sourceHash: "hash-b")
        other.goVersion = "go1.26.0"
        other.gomaxprocs = 4
        other.datasetID = "large"
        other.benchtime = "5s"
        other.count = 10
        other.cpu = "Intel Xeon"
        other.tags = ["integration"]
        other.instrumentation = ["race"]
        other.environment = ["GOFLAGS": "-mod=mod"]
        let comparison = BenchmarkComparator.compare(baseline: run((0..<12).map { 1000 + Double($0) }), candidate: run((0..<12).map { 500 + Double($0) }, fingerprint: other))
        guard case .incomparable(let fields) = comparison.comparability else {
            Issue.record("expected incomparable")
            return
        }
        #expect(Set(fields) == ["goVersion", "gomaxprocs", "datasetID", "benchtime", "count", "cpu", "tags", "instrumentation", "environment"])
        let result = try #require(comparison.result(for: "BenchmarkMake"))
        #expect(result.verdict == .incomparable)
        #expect(result.metrics.isEmpty)
    }

    @Test func sourceHashDifferenceIsTheVariableUnderTestNotAnIncompatibility() {
        let comparison = BenchmarkComparator.compare(baseline: run((0..<12).map { 1000 + Double($0) }), candidate: run((0..<12).map { 900 + Double($0) }, fingerprint: baseFingerprint(sourceHash: "hash-b")))
        guard case .comparable = comparison.comparability else {
            Issue.record("source hash must not make runs incomparable")
            return
        }
    }

    @Test func identicalSourceHashIsFlaggedAsNoiseOnly() {
        let comparison = BenchmarkComparator.compare(baseline: run((0..<12).map { 1000 + Double($0) }), candidate: run((0..<12).map { 1000 + Double($0) }))
        #expect(comparison.limitations.contains { $0.contains("source hashes are identical") })
    }

    @Test func differingObservedProcsMakeRunsIncomparableEvenWithoutDeclaredFingerprint() {
        var fingerprint = baseFingerprint()
        fingerprint.gomaxprocs = nil
        let baseline = BenchmarkRun(fingerprint: fingerprint, samples: (0..<12).map { sample(ns: 1000 + Double($0), procs: 8) })
        let candidate = BenchmarkRun(fingerprint: fingerprint, samples: (0..<12).map { sample(ns: 500 + Double($0), procs: 2) })
        guard case .incomparable(let fields) = BenchmarkComparator.compare(baseline: baseline, candidate: candidate).comparability else {
            Issue.record("expected incomparable")
            return
        }
        #expect(fields.contains("gomaxprocs"))
    }

    @Test func unknownFingerprintFieldsBecomeLimitationsNotSilentComparability() {
        let bare = BenchmarkFingerprint(sourceHash: "a")
        let bareOther = BenchmarkFingerprint(sourceHash: "b")
        let comparison = BenchmarkComparator.compare(baseline: run((0..<12).map { 1000 + Double($0) }, fingerprint: bare), candidate: run((0..<12).map { 900 + Double($0) }, fingerprint: bareOther))
        guard case .comparable(let limitations) = comparison.comparability else {
            Issue.record("expected comparable with limitations")
            return
        }
        #expect(limitations.contains("cpu is unknown on both sides"))
        #expect(limitations.contains("goVersion is unknown on both sides"))
        var oneSided = baseFingerprint(sourceHash: "b")
        oneSided.cpu = nil
        let mixed = BenchmarkComparator.compare(baseline: run((0..<12).map { 1000 + Double($0) }), candidate: run((0..<12).map { 900 + Double($0) }, fingerprint: oneSided))
        #expect(mixed.limitations.contains("cpu is unknown on the candidate side"))
    }

    @Test func rawDuplicatesAreAllUsedAsSamples() throws {
        let samples = (0..<10).map { _ in sample(ns: 100) } + (0..<10).map { _ in sample(ns: 200) }
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: samples)
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: samples)
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        let time = try #require(result.metric("ns/op"))
        #expect(time.baseline?.count == 20)
        #expect(time.candidate?.count == 20)
        #expect(time.deltaAbsolute == 0)
        #expect(result.verdict == .inconclusive)
    }

    @Test func missingMetricIsReportedAndNeverInvented() throws {
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: (0..<12).map { sample(ns: 1000 + Double($0)) })
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: (0..<12).map { sample(ns: 700 + Double($0), bytes: 128, allocs: 2) })
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .faster)
        let bytes = try #require(result.metric("B/op"))
        #expect(bytes.missingFrom == ["baseline"])
        #expect(bytes.deltaAbsolute == nil)
        #expect(bytes.deltaPercent == nil)
        #expect(bytes.change == .inconclusive)
        #expect(result.notes.contains { $0.contains("B/op is missing from: baseline") })
    }

    @Test func missingTimeMetricMakesTheVerdictInconclusive() throws {
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: (0..<12).map { _ in sample(ns: nil, bytes: 10) })
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: (0..<12).map { sample(ns: 5 + Double($0), bytes: 10) })
        #expect(try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake")).verdict == .inconclusive)
    }

    @Test func benchmarkPresentOnOnlyOneSideIsNotCompared() throws {
        let baseline = run((0..<12).map { 1000 + Double($0) }, name: "BenchmarkOld")
        let candidate = run((0..<12).map { 500 + Double($0) }, fingerprint: baseFingerprint(sourceHash: "hash-b"), name: "BenchmarkNew")
        let comparison = BenchmarkComparator.compare(baseline: baseline, candidate: candidate)
        let old = try #require(comparison.result(for: "BenchmarkOld"))
        let new = try #require(comparison.result(for: "BenchmarkNew"))
        #expect(old.verdict == .inconclusive)
        #expect(new.verdict == .inconclusive)
        #expect(old.notes.contains { $0.contains("absent from the candidate") })
        #expect(new.notes.contains { $0.contains("absent from the baseline") })
    }

    @Test func outliersStayInTheDataAndAreReported() throws {
        var baselineValues = (0..<11).map { 1000 + Double($0) }
        baselineValues.append(9000)
        let baseline = run(baselineValues)
        let candidate = run((0..<12).map { 800 + Double($0) }, fingerprint: baseFingerprint(sourceHash: "hash-b"))
        let time = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake")?.metric("ns/op"))
        #expect(time.baseline?.count == 12)
        #expect(time.baseline?.outliers == [9000])
        #expect(time.baseline?.max == 9000)
    }

    @Test func noFixedThresholdSmallConsistentShiftIsStillMeasured() throws {
        let baseline = run((0..<12).map { 1000 + Double($0) * 0.01 })
        let candidate = run((0..<12).map { 999 + Double($0) * 0.01 }, fingerprint: baseFingerprint(sourceHash: "hash-b"))
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .faster)
        #expect(abs(try #require(result.metric("ns/op")?.deltaPercent)) < 0.2)
    }

    @Test func comparisonDocumentsItsMethod() {
        let comparison = BenchmarkComparator.compare(baseline: run([1]), candidate: run([2]))
        #expect(comparison.method.contains("Mann-Whitney"))
        #expect(comparison.method.contains("tie"))
    }

    @Test func customMetricsAreComparedWithoutImplyingDirection() throws {
        let baseline = BenchmarkRun(fingerprint: baseFingerprint(), samples: (0..<12).map { sample(ns: 1000 + Double($0), extra: ["MB/s": 100 + Double($0)]) })
        let candidate = BenchmarkRun(fingerprint: baseFingerprint(sourceHash: "hash-b"), samples: (0..<12).map { sample(ns: 1000 + Double($0), extra: ["MB/s": 200 + Double($0)]) })
        let result = try #require(BenchmarkComparator.compare(baseline: baseline, candidate: candidate).result(for: "BenchmarkMake"))
        #expect(result.verdict == .inconclusive)
        #expect(result.metric("MB/s")?.change == .higher)
    }
}
