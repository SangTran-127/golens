import Foundation
import GoLensFoundation
import SwiftUI

struct BenchmarkBaselineEntry: Codable, Equatable, Sendable {
    let nsPerOp: Double
    let bytesPerOp: Int64
    let allocsPerOp: Int64

    init(nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64) {
        self.nsPerOp = nsPerOp
        self.bytesPerOp = bytesPerOp
        self.allocsPerOp = allocsPerOp
    }

    init(_ values: BenchmarkMetricValues) {
        self.nsPerOp = values.nsPerOp
        self.bytesPerOp = values.bytesPerOp
        self.allocsPerOp = values.allocsPerOp
    }

    var asMetricValues: BenchmarkMetricValues {
        BenchmarkMetricValues(nsPerOp: nsPerOp, bytesPerOp: bytesPerOp, allocsPerOp: allocsPerOp)
    }
}

struct BenchmarkDiffRow: Identifiable, Codable, Equatable, Sendable {
    var id: String { importPath.isEmpty ? name : "\(importPath)::\(name)" }
    let name: String
    var importPath: String = ""
    let baselineNsPerOp: Double
    let currentNsPerOp: Double
    let nsDeltaPct: Double
    let baselineBytesPerOp: Int64
    let currentBytesPerOp: Int64
    let bytesDeltaPct: Double
    let baselineAllocsPerOp: Int64
    let currentAllocsPerOp: Int64
    let allocsDeltaPct: Double
    let verdict: String
    let inlineBadge: String

    enum CodingKeys: String, CodingKey {
        case name
        case baselineNsPerOp
        case currentNsPerOp
        case nsDeltaPct
        case baselineBytesPerOp
        case currentBytesPerOp
        case bytesDeltaPct
        case baselineAllocsPerOp
        case currentAllocsPerOp
        case allocsDeltaPct
        case verdict
        case inlineBadge
    }

    func matches(importPath targetImportPath: String, name targetName: String) -> Bool {
        asSnapshot.matches(importPath: targetImportPath, name: targetName)
    }

    var asSnapshot: BenchmarkDiffSnapshot {
        BenchmarkDiffSnapshot(
            name: name,
            importPath: importPath,
            baselineNsPerOp: baselineNsPerOp,
            currentNsPerOp: currentNsPerOp,
            nsDeltaPct: nsDeltaPct,
            baselineBytesPerOp: baselineBytesPerOp,
            currentBytesPerOp: currentBytesPerOp,
            bytesDeltaPct: bytesDeltaPct,
            baselineAllocsPerOp: baselineAllocsPerOp,
            currentAllocsPerOp: currentAllocsPerOp,
            allocsDeltaPct: allocsDeltaPct,
            verdict: verdict,
            inlineBadge: inlineBadge
        )
    }
}

struct BenchmarkComparisonReportDTO: Codable, Equatable, Sendable {
    let items: [BenchmarkDiffRow]
    let fasterCount: Int
    let regressedCount: Int
    let unchangedCount: Int
}

extension WorkspaceState {
    private static var legacyBenchmarkBaselines: [String: (nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64)] = [:]

    var isActiveFileScratch: Bool {
        guard !activeFilePath.isEmpty else { return false }
        if activeFilePath.contains("/.golens-scratch/") {
            return true
        }
        let name = (activeFilePath as NSString).lastPathComponent
        return name.hasPrefix("scratch") && activeFilePath.hasSuffix(".go")
    }

    func openOrCreateGoScratchFile() {
        guard !activeWorkspacePath.isEmpty else { return }
        let fm = FileManager.default
        let scratchDir = (activeWorkspacePath as NSString).appendingPathComponent(".golens-scratch")
        let scratchPath = (scratchDir as NSString).appendingPathComponent("scratch.go")
        do {
            if !fm.fileExists(atPath: scratchDir) {
                try fm.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)
            }
        } catch {
            presentScratchFailure(error, path: scratchPath)
            return
        }

        let gitExcludePath = (activeWorkspacePath as NSString).appendingPathComponent(".git/info/exclude")
        if fm.fileExists(atPath: gitExcludePath),
           let existingExclude = try? String(contentsOfFile: gitExcludePath, encoding: .utf8),
           !existingExclude.contains(".golens-scratch/") {
            let updatedExclude = existingExclude.hasSuffix("\n")
                ? existingExclude + ".golens-scratch/\n"
                : existingExclude + "\n.golens-scratch/\n"
            try? updatedExclude.write(toFile: gitExcludePath, atomically: true, encoding: .utf8)
        }

        if !fm.fileExists(atPath: scratchPath) {
            let starter = """
            package main

            import "fmt"

            func main() {
            \tfmt.Println("Hello from GoLens Go Scratchpad!")
            }

            """
            do {
                try starter.write(toFile: scratchPath, atomically: true, encoding: .utf8)
            } catch {
                presentScratchFailure(error, path: scratchPath)
                return
            }
        }

        openFile(scratchPath)
    }

    private func presentScratchFailure(_ error: Error, path: String) {
        presentFailure(
            "Couldn’t Create “scratch.go”",
            "\(Self.failureReason(error)) Check that you can write to the project folder, then try again.",
            recovery: ("Try Again", { [weak self] in self?.openOrCreateGoScratchFile() }),
            revealing: path
        )
    }

    func runGoScratchFile() {
        guard !activeWorkspacePath.isEmpty else {
            presentCommandFeedback("Open a Go project folder first to run a Scratchpad file.", title: "Go Scratchpad")
            return
        }
        if !isActiveFileScratch {
            openOrCreateGoScratchFile()
        }
        let targetPath = isActiveFileScratch
            ? activeFilePath
            : (activeWorkspacePath as NSString).appendingPathComponent(".golens-scratch/scratch.go")
        guard FileManager.default.fileExists(atPath: targetPath) else { return }
        let relPath = projectRelativePath(targetPath)
        let pathToRun = relPath.isEmpty ? targetPath : relPath
        let quotedPath = "'\(pathToRun.replacingOccurrences(of: "'", with: "'\\''"))'"
        runGoCommand("run \(quotedPath)", named: "go run \((pathToRun as NSString).lastPathComponent)", log: "Running Go Scratchpad in")
    }

    var hasBenchmarkBaseline: Bool {
        _ = benchMetrics.count
        return !benchmarkBaselines.isEmpty || !Self.legacyBenchmarkBaselines.isEmpty
    }

    private var benchmarkBaselineDefaultsKey: String {
        let ws = activeWorkspacePath.isEmpty ? "default" : activeWorkspacePath
        return "GoLensBenchmarkBaseline_\(ws)"
    }

    func loadSavedBenchmarkBaseline() {
        let key = benchmarkBaselineDefaultsKey
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: BenchmarkBaselineEntry].self, from: data) {
            benchmarkBaselines = decoded
            var legacy: [String: (nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64)] = [:]
            for (k, v) in decoded {
                legacy[k] = (v.nsPerOp, v.bytesPerOp, v.allocsPerOp)
            }
            Self.legacyBenchmarkBaselines = legacy
        }
        recomputeBenchmarkComparison()
    }

    func benchmarkMetric(_ importPath: String, _ name: String) -> String? {
        if !importPath.isEmpty {
            if let m = benchMetrics[testKey(importPath, name)] {
                return m
            }
            if let m = benchMetrics["\(importPath)::\(name)"] {
                return m
            }
            if !BenchmarkScopeStore.hasScopedEntry(for: name, in: benchMetrics.keys) {
                return benchMetrics[name]
            }
            return nil
        }
        if let m = benchMetrics[name] {
            return m
        }
        var uniqueMatch: (pkg: String, raw: String)?
        for (rawKey, raw) in benchMetrics {
            let (pkg, short) = BenchmarkScopeStore.splitKey(rawKey)
            guard !pkg.isEmpty && short == name else { continue }
            if let existing = uniqueMatch {
                if existing.pkg != pkg { return nil }
            } else {
                uniqueMatch = (pkg, raw)
            }
        }
        return uniqueMatch?.raw
    }

    func lookupBenchmarkBaseline(importPath: String, name: String) -> BenchmarkBaselineEntry? {
        let currentValues = benchmarkBaselines.mapValues(\.asMetricValues)
        let legacyValues = Self.legacyBenchmarkBaselines.mapValues {
            BenchmarkMetricValues(nsPerOp: $0.nsPerOp, bytesPerOp: $0.bytesPerOp, allocsPerOp: $0.allocsPerOp)
        }
        return BenchmarkScopeStore.lookupBaseline(
            importPath: importPath,
            name: name,
            in: currentValues,
            legacy: legacyValues
        ).map(BenchmarkBaselineEntry.init)
    }

    func lookupBenchmarkCurrentEntry(importPath: String, name: String) -> BenchmarkBaselineEntry? {
        let parsedMetrics = parsedBenchmarkMetricsMap()
        if let metric = BenchmarkScopeStore.lookupMetric(importPath: importPath, name: name, in: parsedMetrics) {
            return BenchmarkBaselineEntry(metric)
        }
        if let diff = benchmarkDiffItems.first(where: { $0.matches(importPath: importPath, name: name) }),
           diff.currentNsPerOp > 0 {
            return BenchmarkBaselineEntry(
                nsPerOp: diff.currentNsPerOp,
                bytesPerOp: diff.currentBytesPerOp,
                allocsPerOp: diff.currentAllocsPerOp
            )
        }
        return nil
    }

    func saveBenchmarkBaseline() {
        let existingValues = benchmarkBaselines.mapValues(\.asMetricValues)
        let parsedMetrics = parsedBenchmarkMetricsMap()
        let diffSnapshots = benchmarkDiffItems.map(\.asSnapshot)
        let saved = BenchmarkScopeStore.saveBaselines(
            currentBaselines: existingValues,
            metrics: parsedMetrics,
            diffRows: diffSnapshots
        )

        guard saved.savedCount > 0 else {
            benchmarkBaselineSavedBanner = nil
            return
        }

        let nextBaselines = saved.baselines.mapValues(BenchmarkBaselineEntry.init)
        var nextLegacy: [String: (nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64)] = [:]
        for (k, v) in nextBaselines {
            nextLegacy[k] = (v.nsPerOp, v.bytesPerOp, v.allocsPerOp)
        }

        benchmarkBaselines = nextBaselines
        Self.legacyBenchmarkBaselines = nextLegacy

        if let data = try? JSONEncoder().encode(nextBaselines) {
            UserDefaults.standard.set(data, forKey: benchmarkBaselineDefaultsKey)
        }

        let snapshot = benchMetrics
        benchMetrics = snapshot
        benchmarkBaselineSavedBanner = "Baseline Saved (\(saved.savedCount) benchmark\(saved.savedCount == 1 ? "" : "s"))"
        recomputeBenchmarkComparison()
        refreshBenchmarkCodeLenses()
        appendLog("Saved \(saved.savedCount) benchmark(s) as baseline.")
    }

    func pinCurrentBenchmarksAsBaseline() {
        saveBenchmarkBaseline()
    }

    func clearBenchmarkBaseline() {
        benchmarkBaselines.removeAll()
        Self.legacyBenchmarkBaselines.removeAll()
        benchmarkBaselineSavedBanner = nil
        UserDefaults.standard.removeObject(forKey: benchmarkBaselineDefaultsKey)
        let snapshot = benchMetrics
        benchMetrics = snapshot
        recomputeBenchmarkComparison()
        refreshBenchmarkCodeLenses()
        appendLog("Cleared benchmark baseline.")
    }

    func presentBenchmarkComparisonSheet() {
        if benchmarkBaselines.isEmpty {
            loadSavedBenchmarkBaseline()
        }
        recomputeBenchmarkComparison()
        showBenchmarkComparisonSheet = true
    }

    func runBenchmarks() {
        benchmarkBaselineSavedBanner = nil
        recomputeBenchmarkComparison()
        if !activeWorkspacePath.isEmpty {
            runAllBenchmarks()
        }
    }

    func discoverWorkspaceBenchmarkNames() -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func addName(_ name: String) {
            guard name.hasPrefix("Benchmark"), seen.insert(name).inserted else { return }
            names.append(name)
        }

        if let activeDoc = documents[activeFilePath]?.storage.string {
            for entry in BenchmarkSignatureParser.discoverBenchmarks(in: activeDoc) {
                addName(entry.name)
            }
        }
        for (_, session) in documents {
            for entry in BenchmarkSignatureParser.discoverBenchmarks(in: session.storage.string) {
                addName(entry.name)
            }
        }
        for (_, info) in fileTests {
            for t in info.tests where t.name.hasPrefix("Benchmark") {
                addName(t.name)
            }
        }
        for suite in testSuites {
            for t in suite.tests where t.name.hasPrefix("Benchmark") {
                addName(t.name)
            }
        }
        return names
    }

    func ensureBenchmarkPreviewSeeded(discoveredNames: [String]) {
        _ = discoveredNames
    }

    func recomputeBenchmarkComparison() {
        let partitions = BenchmarkScopeStore.partitionComparisonInputs(
            baselines: benchmarkBaselines.mapValues(\.asMetricValues),
            metrics: parsedBenchmarkMetricsMap(),
            rawOutput: lastBenchmarkOutputRaw
        )

        guard !partitions.isEmpty else {
            benchmarkDiffItems = []
            benchmarkFasterCount = 0
            benchmarkRegressedCount = 0
            benchmarkUnchangedCount = 0
            return
        }

        var combinedItems: [BenchmarkDiffRow] = []
        var fasterTotal = 0
        var regressedTotal = 0
        var unchangedTotal = 0

        for partition in partitions {
            let baselineJSON: String
            if partition.baselines.isEmpty {
                baselineJSON = ""
            } else if let data = try? JSONEncoder().encode(partition.baselines),
                      let str = String(data: data, encoding: .utf8) {
                baselineJSON = str
            } else {
                baselineJSON = ""
            }

            guard !baselineJSON.isEmpty || !partition.currentLines.isEmpty else { continue }

            let replyJSON: String? = baselineJSON.withCString { cBase in
                partition.currentLines.withCString { cCurr in
                    guard let ptr = CompareGoBenchmarks(cBase, cCurr) else { return nil }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }

            guard let replyJSON,
                  let report = try? JSONDecoder().decode(BenchmarkComparisonReportDTO.self, from: Data(replyJSON.utf8)) else {
                continue
            }

            for var item in report.items {
                item.importPath = partition.importPath
                combinedItems.append(item)
            }
            fasterTotal += report.fasterCount
            regressedTotal += report.regressedCount
            unchangedTotal += report.unchangedCount
        }

        benchmarkDiffItems = combinedItems
        benchmarkFasterCount = fasterTotal
        benchmarkRegressedCount = regressedTotal
        benchmarkUnchangedCount = unchangedTotal
    }

    func refreshBenchmarkCodeLenses() {
        for path in visibleDocumentPaths where path.hasSuffix(".go") {
            if let session = documents[path] {
                reloadGoplsCodeLenses(forPath: path, version: session.version)
            }
        }
        activeTextView?.needsDisplay = true
    }

    private func parsedBenchmarkMetricsMap() -> [String: BenchmarkMetricValues] {
        var parsedMap: [String: BenchmarkMetricValues] = [:]
        parsedMap.reserveCapacity(benchMetrics.count)
        for (rawKey, rawMetric) in benchMetrics {
            if let parsed = BenchmarkMetricsFormatter.parseMetricString(rawMetric) {
                parsedMap[rawKey] = parsed
            }
        }
        return parsedMap
    }

    func benchmarkDeltaText(_ importPath: String, _ name: String) -> (text: String, isImproved: Bool, isRegressed: Bool)? {
        benchmarkDeltaText(importPath: importPath, name: name)
    }

    func benchmarkDeltaText(importPath: String, name: String) -> (text: String, isImproved: Bool, isRegressed: Bool)? {
        let diff = benchmarkDiffItems
            .first(where: { $0.matches(importPath: importPath, name: name) })?
            .asSnapshot
        let current = lookupBenchmarkCurrentEntry(importPath: importPath, name: name)?.asMetricValues
        let baseline = lookupBenchmarkBaseline(importPath: importPath, name: name)?.asMetricValues
        return BenchmarkMetricsFormatter.deltaSummary(current: current, baseline: baseline, diff: diff)
    }

    static func parseBenchmarkMetricString(_ raw: String) -> (nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64)? {
        guard let parsed = BenchmarkMetricsFormatter.parseMetricString(raw) else { return nil }
        return (nsPerOp: parsed.nsPerOp, bytesPerOp: parsed.bytesPerOp, allocsPerOp: parsed.allocsPerOp)
    }
}
