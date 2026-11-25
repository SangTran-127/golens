import XCTest
@testable import GoLensFoundation

final class BenchmarkWorkflowTests: XCTestCase {
    func testSourceLineScannerHandlesLFCRLFEmptyAndEarlyStop() {
        let sample = "line1\nline2\r\n\nline4"
        var collected: [(Int, String)] = []
        SourceLineScanner.enumerateLines(in: sample) { lineNum, sub, _ in
            collected.append((lineNum, String(sub)))
        }
        XCTAssertEqual(collected.map(\.0), [1, 2, 3, 4])
        XCTAssertEqual(collected[0].1, "line1")
        XCTAssertEqual(collected[1].1, "line2\r")
        XCTAssertEqual(collected[2].1, "")
        XCTAssertEqual(collected[3].1, "line4")

        var stoppedLines: [Int] = []
        SourceLineScanner.enumerateLines(in: sample) { lineNum, _, stop in
            stoppedLines.append(lineNum)
            if lineNum == 2 {
                stop = true
            }
        }
        XCTAssertEqual(stoppedLines, [1, 2])
    }

    func testBenchmarkSignatureParserHandlesAliasesGuardsAndOversizedLines() {
        let source = """
        package bench

        import (
            benchpkg "testing"
        )

        func BenchmarkEncode(b *testing.B) {
        }
        func\t  BenchmarkAliased( b *benchpkg.B ) { b.Run("sub", func(b *testing.B) {}) }
        func BenchmarkUnnamed(*testing.B) {}
        func Benchmark(b *testing.B) {}
        func Benchmarklower(b *testing.B) {}
        func TestNotABenchmark(t *testing.T) {}
        func BenchmarkWrongParamType(t *testing.T) {}
        func BenchmarkMultiParam(x int, b *testing.B) {}
        func BenchmarkGeneric[T any](b *testing.B) {}
        """

        let oversizedUnclosed = "func BenchmarkTooLong(" + String(repeating: "a", count: 400) + " *testing.B) {}"
        let discovered = BenchmarkSignatureParser.discoverBenchmarks(in: source + "\n" + oversizedUnclosed)
        XCTAssertEqual(
            discovered,
            [
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 7, name: "BenchmarkEncode"),
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 9, name: "BenchmarkAliased"),
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 10, name: "BenchmarkUnnamed"),
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 11, name: "Benchmark")
            ]
        )

        let multiLineText = "package bench\n\nfunc BenchmarkMultiLine(\n\tb *testing.B,\n) {}\nfunc BenchmarkAddedLive(b *testing.B) {}\n"
        let astEntries = [BenchmarkSignatureParser.DiscoveredBenchmark(line: 3, name: "BenchmarkMultiLine")]
        XCTAssertEqual(
            BenchmarkSignatureParser.resolve(astBenchmarks: astEntries, text: multiLineText, isEdited: false),
            astEntries
        )
        XCTAssertEqual(
            BenchmarkSignatureParser.resolve(astBenchmarks: astEntries, text: multiLineText, isEdited: true),
            [
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 3, name: "BenchmarkMultiLine"),
                BenchmarkSignatureParser.DiscoveredBenchmark(line: 6, name: "BenchmarkAddedLive")
            ]
        )
    }

    func testBenchmarkInlineSummaryFormattingWithAndWithoutAllocations() {
        let diffWithAllocs = BenchmarkDiffSnapshot(
            name: "BenchmarkEncode",
            importPath: "example.com/codec",
            baselineNsPerOp: 141.4,
            currentNsPerOp: 124.0,
            nsDeltaPct: -12.3,
            baselineBytesPerOp: 64,
            currentBytesPerOp: 48,
            bytesDeltaPct: -25.0,
            baselineAllocsPerOp: 3,
            currentAllocsPerOp: 2,
            allocsDeltaPct: -33.3,
            verdict: "faster",
            inlineBadge: "-12.3% faster"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: nil, baseline: nil, diff: diffWithAllocs),
            "Compare Baseline (124 ns/op · 48 B/op · 2 allocs/op · -12.3% faster)"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compactCompareLensTitle(current: nil, baseline: nil, diff: diffWithAllocs),
            "124 ns/op · -12.3% faster"
        )

        let zeroAllocsNoBaselineAllocs = BenchmarkDiffSnapshot(
            name: "BenchmarkPureMath",
            importPath: "example.com/math",
            baselineNsPerOp: 9.0,
            currentNsPerOp: 8.5,
            nsDeltaPct: -5.6,
            baselineBytesPerOp: 0,
            currentBytesPerOp: 0,
            bytesDeltaPct: 0,
            baselineAllocsPerOp: 0,
            currentAllocsPerOp: 0,
            allocsDeltaPct: 0,
            verdict: "faster",
            inlineBadge: "-5.6% faster"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: nil, baseline: nil, diff: zeroAllocsNoBaselineAllocs),
            "Compare Baseline (8.50 ns/op · -5.6% faster)"
        )

        let eliminatedAllocsDiff = BenchmarkDiffSnapshot(
            name: "BenchmarkZeroAllocNow",
            importPath: "example.com/codec",
            baselineNsPerOp: 200.0,
            currentNsPerOp: 42.5,
            nsDeltaPct: -78.8,
            baselineBytesPerOp: 64,
            currentBytesPerOp: 0,
            bytesDeltaPct: -100.0,
            baselineAllocsPerOp: 2,
            currentAllocsPerOp: 0,
            allocsDeltaPct: -100.0,
            verdict: "faster",
            inlineBadge: "-78.8% faster"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: nil, baseline: nil, diff: eliminatedAllocsDiff),
            "Compare Baseline (42.5 ns/op · 0 B/op · 0 allocs/op · -78.8% faster)"
        )

        let parsed = BenchmarkMetricsFormatter.parseMetricString("124.0 ns/op · 48 B/op · 2 allocs/op")
        XCTAssertEqual(parsed, BenchmarkMetricValues(nsPerOp: 124.0, bytesPerOp: 48, allocsPerOp: 2))

        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: parsed, baseline: nil, diff: nil),
            "Compare Baseline (124 ns/op · 48 B/op · 2 allocs/op · new)"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: nil, baseline: parsed, diff: nil),
            "Compare Baseline (124 ns/op · 48 B/op · 2 allocs/op · baseline saved)"
        )
        XCTAssertEqual(
            BenchmarkMetricsFormatter.compareLensTitle(current: nil, baseline: nil, diff: nil),
            "Compare Baseline"
        )
    }

    func testPackageScopedBaselinesAndMetricsNeverCollideAcrossPackages() {
        let alphaMetric = BenchmarkMetricValues(nsPerOp: 110, bytesPerOp: 32, allocsPerOp: 1)
        let betaMetric = BenchmarkMetricValues(nsPerOp: 480, bytesPerOp: 256, allocsPerOp: 6)

        let metrics: [String: BenchmarkMetricValues] = [
            BenchmarkScopeStore.testKey(importPath: "example.com/alpha", name: "BenchmarkEncode"): alphaMetric,
            BenchmarkScopeStore.testKey(importPath: "example.com/beta", name: "BenchmarkEncode"): betaMetric
        ]

        let saved = BenchmarkScopeStore.saveBaselines(currentBaselines: [:], metrics: metrics)
        XCTAssertEqual(saved.savedCount, 2)
        XCTAssertEqual(saved.baselines["example.com/alpha::BenchmarkEncode"], alphaMetric)
        XCTAssertEqual(saved.baselines["example.com/beta::BenchmarkEncode"], betaMetric)
        XCTAssertNil(saved.baselines["BenchmarkEncode"])

        XCTAssertEqual(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/alpha", name: "BenchmarkEncode", in: saved.baselines),
            alphaMetric
        )
        XCTAssertEqual(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/beta", name: "BenchmarkEncode", in: saved.baselines),
            betaMetric
        )
        XCTAssertNil(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/gamma", name: "BenchmarkEncode", in: saved.baselines)
        )
        XCTAssertEqual(
            BenchmarkScopeStore.lookupMetric(importPath: "example.com/alpha", name: "BenchmarkEncode", in: metrics),
            alphaMetric
        )
        XCTAssertEqual(
            BenchmarkScopeStore.lookupMetric(importPath: "example.com/beta", name: "BenchmarkEncode", in: metrics),
            betaMetric
        )
        XCTAssertNil(
            BenchmarkScopeStore.lookupMetric(importPath: "example.com/gamma", name: "BenchmarkEncode", in: metrics)
        )

        let legacyOnly: [String: BenchmarkMetricValues] = [
            "BenchmarkLegacy": BenchmarkMetricValues(nsPerOp: 95, bytesPerOp: 16, allocsPerOp: 1)
        ]
        XCTAssertEqual(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/alpha", name: "BenchmarkLegacy", in: legacyOnly),
            legacyOnly["BenchmarkLegacy"]
        )
        XCTAssertEqual(
            BenchmarkScopeStore.lookupBaseline(importPath: "", name: "BenchmarkLegacy", in: legacyOnly),
            legacyOnly["BenchmarkLegacy"]
        )

        let mixedBaselines: [String: BenchmarkMetricValues] = [
            "BenchmarkEncode": BenchmarkMetricValues(nsPerOp: 999, bytesPerOp: 512, allocsPerOp: 9),
            "example.com/alpha::BenchmarkEncode": alphaMetric
        ]
        XCTAssertEqual(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/alpha", name: "BenchmarkEncode", in: mixedBaselines),
            alphaMetric
        )
        XCTAssertNil(
            BenchmarkScopeStore.lookupBaseline(importPath: "example.com/beta", name: "BenchmarkEncode", in: mixedBaselines)
        )

        let partitions = BenchmarkScopeStore.partitionComparisonInputs(
            baselines: saved.baselines,
            metrics: metrics,
            rawOutput: ""
        )
        XCTAssertEqual(partitions.map(\.importPath), ["example.com/alpha", "example.com/beta"])
        XCTAssertEqual(partitions[0].baselines["BenchmarkEncode"], alphaMetric)
        XCTAssertEqual(partitions[1].baselines["BenchmarkEncode"], betaMetric)
    }

    func testMultiPackagePromotesUnmigratedLegacyBaselineWithoutDuplicatingUnscopedPartition() {
        let alphaBaseline = BenchmarkMetricValues(nsPerOp: 110, bytesPerOp: 64, allocsPerOp: 2)
        let betaBaseline = BenchmarkMetricValues(nsPerOp: 220, bytesPerOp: 128, allocsPerOp: 4)
        let promotedLegacy = BenchmarkMetricValues(nsPerOp: 330, bytesPerOp: 256, allocsPerOp: 6)
        let leftoverLegacy = BenchmarkMetricValues(nsPerOp: 440, bytesPerOp: 512, allocsPerOp: 8)

        let baselines: [String: BenchmarkMetricValues] = [
            "example.com/alpha::BenchmarkEncode": alphaBaseline,
            "example.com/beta::BenchmarkDecode": betaBaseline,
            "BenchmarkPromoted": promotedLegacy,
            "BenchmarkLeftover": leftoverLegacy
        ]
        let metricsOnlyPromoted: [String: BenchmarkMetricValues] = [
            "example.com/alpha::BenchmarkEncode": BenchmarkMetricValues(nsPerOp: 100, bytesPerOp: 64, allocsPerOp: 2),
            "example.com/alpha::BenchmarkPromoted": BenchmarkMetricValues(nsPerOp: 310, bytesPerOp: 256, allocsPerOp: 6),
            "example.com/beta::BenchmarkDecode": BenchmarkMetricValues(nsPerOp: 210, bytesPerOp: 128, allocsPerOp: 4)
        ]

        let withLeftover = BenchmarkScopeStore.partitionComparisonInputs(
            baselines: baselines,
            metrics: metricsOnlyPromoted,
            rawOutput: ""
        )
        XCTAssertEqual(withLeftover.map(\.importPath), ["example.com/alpha", "example.com/beta", ""])
        XCTAssertEqual(withLeftover[0].baselines["BenchmarkEncode"], alphaBaseline)
        XCTAssertEqual(withLeftover[0].baselines["BenchmarkPromoted"], promotedLegacy)
        XCTAssertEqual(withLeftover[1].baselines["BenchmarkDecode"], betaBaseline)
        XCTAssertNil(withLeftover[1].baselines["BenchmarkPromoted"])
        XCTAssertEqual(withLeftover[2].baselines, ["BenchmarkLeftover": leftoverLegacy])
        XCTAssertNil(withLeftover[2].baselines["BenchmarkPromoted"])

        let baselinesWithoutLeftover: [String: BenchmarkMetricValues] = [
            "example.com/alpha::BenchmarkEncode": alphaBaseline,
            "example.com/beta::BenchmarkDecode": betaBaseline,
            "BenchmarkPromoted": promotedLegacy
        ]
        let withoutLeftover = BenchmarkScopeStore.partitionComparisonInputs(
            baselines: baselinesWithoutLeftover,
            metrics: metricsOnlyPromoted,
            rawOutput: ""
        )
        XCTAssertEqual(withoutLeftover.map(\.importPath), ["example.com/alpha", "example.com/beta"])
        XCTAssertEqual(withoutLeftover[0].baselines["BenchmarkPromoted"], promotedLegacy)
    }

    func testSourceLineScannerIndentAndOutdentMatchSplitSemantics() {
        XCTAssertEqual(SourceLineScanner.indentLines(in: "", indent: "\t").text, "")
        XCTAssertEqual(SourceLineScanner.indentLines(in: "", indent: "\t").utf16Delta, 0)

        let trailingNewline = SourceLineScanner.indentLines(in: "alpha\n\nbeta\n", indent: "    ")
        XCTAssertEqual(trailingNewline.text, "    alpha\n    \n    beta\n")
        XCTAssertEqual(trailingNewline.utf16Delta, 12)

        let noTrailingNewline = SourceLineScanner.indentLines(in: "alpha\nbeta", indent: "\t")
        XCTAssertEqual(noTrailingNewline.text, "\talpha\n\tbeta")
        XCTAssertEqual(noTrailingNewline.utf16Delta, 2)

        let justNewline = SourceLineScanner.indentLines(in: "\n", indent: "  ")
        XCTAssertEqual(justNewline.text, "  \n")
        XCTAssertEqual(justNewline.utf16Delta, 2)

        XCTAssertEqual(SourceLineScanner.outdentLines(in: "", tabSize: 4).text, "")
        XCTAssertEqual(SourceLineScanner.outdentLines(in: "", tabSize: 4).utf16Delta, 0)

        let outdented = SourceLineScanner.outdentLines(in: "\talpha\n  beta\n      gamma\n\n", tabSize: 4)
        XCTAssertEqual(outdented.text, "alpha\nbeta\n  gamma\n\n")
        XCTAssertEqual(outdented.utf16Delta, 7)

        let outdentedEOF = SourceLineScanner.outdentLines(in: "    one\n  two", tabSize: 4)
        XCTAssertEqual(outdentedEOF.text, "one\ntwo")
        XCTAssertEqual(outdentedEOF.utf16Delta, 6)
    }

    func testParseGitBlameAuthorsSkipsUncommittedAndParsesPorcelain() {
        let porcelain = [
            "0123456789abcdef0123456789abcdef01234567 1 1 2",
            "author Alice",
            "author-mail <alice@example.com>",
            "\tpackage main",
            "0123456789abcdef0123456789abcdef01234567 2 2",
            "author Alice",
            "\t",
            "0000000000000000000000000000000000000000 3 3 1",
            "author Not Committed Yet",
            "\tfunc main() {}",
            "fedcba9876543210fedcba9876543210fedcba98 4 4 1",
            "author Bob Builder",
            "\tprintln(1)"
        ].joined(separator: "\r\n")
        let authors = SourceLineScanner.parseGitBlameAuthors(in: porcelain)
        XCTAssertEqual(authors, [1: "Alice", 2: "Alice", 4: "Bob Builder"])
    }
}
