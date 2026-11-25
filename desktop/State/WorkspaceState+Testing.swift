import AppKit
import Foundation
import GoLensFoundation
import SwiftUI

private struct ImportedProfilePayload: Decodable {
    let mode: String
    let entries: [ProfileEntry]
    let error: String?
}

struct TestSummary: Equatable {
    var passed = 0
    var failed = 0
    var skipped = 0
}

extension WorkspaceState {
    static let maxTestResults = 20_000
    static let maxDynamicSubtests = 500

    static func testKey(importPath: String, test: String) -> String {
        importPath + "\u{0}" + test
    }

    func testKey(_ importPath: String, _ name: String) -> String {
        Self.testKey(importPath: importPath, test: name)
    }

    func testStatus(_ importPath: String, _ name: String) -> TestStatus {
        testResults[testKey(importPath, name)] ?? .none
    }

    func subtestIDs(_ importPath: String, _ test: GoTestFunc) -> [String] {
        guard !dynamicSubtests.isEmpty,
              let list = dynamicSubtests[testKey(importPath, test.name)],
              !list.isEmpty else { return [] }
        let known = Set(test.rows.map(\.id))
        return list.filter { !known.contains($0) }
    }

    var hasFailedTests: Bool {
        !testResults.isEmpty && testResults.values.contains(.failed)
    }

    func effectiveTestStatus(_ importPath: String, _ test: GoTestFunc) -> TestStatus {
        guard !testResults.isEmpty else { return .none }
        let direct = testStatus(importPath, test.name)
        if direct == .running || direct == .failed {
            return direct
        }
        var anyRunning = false
        var anyFailed = false
        var anyPassed = false
        for row in test.rows {
            let st = testStatus(importPath, "\(test.name)/\(row.id)")
            switch st {
            case .running: anyRunning = true
            case .failed: anyFailed = true
            case .passed: anyPassed = true
            default: break
            }
        }
        if !dynamicSubtests.isEmpty {
            for subID in subtestIDs(importPath, test) {
                let st = testStatus(importPath, "\(test.name)/\(subID)")
                switch st {
                case .running: anyRunning = true
                case .failed: anyFailed = true
                case .passed: anyPassed = true
                default: break
                }
            }
        }
        if anyRunning { return .running }
        if anyFailed { return .failed }
        if direct != .none { return direct }
        if anyPassed { return .passed }
        return .none
    }

    func suiteAggregateStatus(for suite: GoTestSuite) -> (status: TestStatus, failedCount: Int, passedCount: Int) {
        guard !testResults.isEmpty else { return (status: .none, failedCount: 0, passedCount: 0) }
        var runningCount = 0
        var failedCount = 0
        var passedCount = 0
        for test in suite.tests {
            let st = effectiveTestStatus(suite.importPath, test)
            switch st {
            case .running:
                runningCount += 1
            case .failed:
                failedCount += 1
            case .passed:
                passedCount += 1
            default:
                break
            }
        }
        let status: TestStatus
        if runningCount > 0 {
            status = .running
        } else if failedCount > 0 {
            status = .failed
        } else if passedCount > 0 {
            status = .passed
        } else {
            status = .none
        }
        return (status: status, failedCount: failedCount, passedCount: passedCount)
    }

    func collapseAllTestSuites() {
        collapsedTestSuiteIDs = Set(testSuites.map(\.id))
        expandedTestFuncIDs.removeAll()
    }

    func expandAllTestSuites() {
        collapsedTestSuiteIDs.removeAll()
    }

    func resetTestState() {
        if isTestRunning {
            stopTests()
            isTestRunning = false
        }
        testSuites = []
        collapsedTestSuiteIDs = []
        expandedTestFuncIDs = []
        testFilterQuery = ""
        showFailedTestsOnly = false
        testsDiscovered = false
        testResults = [:]
        testDurations = [:]
        dynamicSubtests = [:]
        testSummary = nil
        currentTestRun = 0
        pendingTestEvents.removeAll()
        fileCoverage.removeAll()
        packageCoverage.removeAll()
        hasCoverageData = false
        cpuProfileEntries = []
        memProfileEntries = []
        hasProfileData = false
        benchMetrics = [:]
        lastBenchmarkOutputRaw = ""
        benchmarkDiffItems = []
        benchmarkFasterCount = 0
        benchmarkRegressedCount = 0
        benchmarkUnchangedCount = 0
        benchmarkBaselineSavedBanner = nil
        lastTestInvocation = nil
    }

    func clearCoverage() {
        fileCoverage.removeAll()
        packageCoverage.removeAll()
        hasCoverageData = false
        activeTextView?.needsDisplay = true
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func clearProfile() {
        cpuProfileEntries = []
        memProfileEntries = []
        blockProfileEntries = []
        mutexProfileEntries = []
        hasProfileData = false
        activeTextView?.needsDisplay = true
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func promptAndImportPprofFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Go Profile (.pprof)"
        panel.message = "Select a CPU, Memory, Block, or Mutex .pprof profile file to inspect."
        if panel.runModal() == .OK, let url = panel.url {
            importPprofFile(at: url.path)
        }
    }

    func importPprofFile(at path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let json: String? = path.withCString { cPath in
                guard let ptr = ParseGoProfileFile(cPath) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
            guard let raw = json,
                  let payload = try? JSONDecoder().decode(ImportedProfilePayload.self, from: Data(raw.utf8)) else {
                DispatchQueue.main.async {
                    self?.appendLog("Failed to parse profile file: \(path)")
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let err = payload.error, !err.isEmpty {
                    self.appendLog("Failed to load profile: \(err)")
                    return
                }
                let capped = Array(payload.entries.prefix(Self.maxProfileEntries))
                if payload.mode == "memory" {
                    self.memProfileEntries = capped
                    self.cpuProfileEntries = []
                    self.blockProfileEntries = []
                    self.mutexProfileEntries = []
                    self.selectedProfileMode = "Memory"
                } else if payload.mode == "block" {
                    self.blockProfileEntries = capped
                    self.cpuProfileEntries = []
                    self.memProfileEntries = []
                    self.mutexProfileEntries = []
                    self.selectedProfileMode = "Block"
                } else if payload.mode == "mutex" {
                    self.mutexProfileEntries = capped
                    self.cpuProfileEntries = []
                    self.memProfileEntries = []
                    self.blockProfileEntries = []
                    self.selectedProfileMode = "Mutex"
                } else {
                    self.cpuProfileEntries = capped
                    self.memProfileEntries = []
                    self.blockProfileEntries = []
                    self.mutexProfileEntries = []
                    self.selectedProfileMode = "CPU"
                }
                self.hasProfileData = !self.cpuProfileEntries.isEmpty || !self.memProfileEntries.isEmpty || !self.blockProfileEntries.isEmpty || !self.mutexProfileEntries.isEmpty
                self.showConsole = true
                self.selectedConsoleTab = Self.profilerTab
                self.activeTextView?.needsDisplay = true
                (self.activeTextView as? GoLensTextView)?.redrawGutter()
                self.gopilot.noteProfile(path: path)
                self.appendLog("Imported \(payload.mode.uppercased()) profile from \((path as NSString).lastPathComponent) (\(capped.count) functions).")
            }
        }
    }

    func profileHeatRatio(forFile path: String, line: Int) -> Double? {
        guard line > 0 else { return nil }
        return profileHeatLines(forFile: path)?[line]
    }

    func profileHeatLines(forFile path: String) -> [Int: Double]? {
        guard hasProfileData, !path.isEmpty, EditorDisplaySettings.showProfileLineHeat else { return nil }
        let entries: [ProfileEntry]
        switch selectedProfileMode {
        case "Block": entries = blockProfileEntries
        case "Mutex": entries = mutexProfileEntries
        case "Memory": entries = memProfileEntries
        default:
            entries = !cpuProfileEntries.isEmpty ? cpuProfileEntries :
                      (!memProfileEntries.isEmpty ? memProfileEntries :
                      (!blockProfileEntries.isEmpty ? blockProfileEntries : mutexProfileEntries))
        }
        if entries.isEmpty { return nil }
        if let cache = profileHeatCache, cache.mode == selectedProfileMode, cache.entries.hasSameStorage(as: entries) {
            return cache.byPath[path]
        }
        var byPath: [String: [Int: Double]] = [:]
        for entry in entries where entry.line > 0 && byPath[entry.file]?[entry.line] == nil {
            byPath[entry.file, default: [:]][entry.line] = min(max(entry.flatPercent / 100.0, 0.05), 1.0)
        }
        profileHeatCache = ProfileHeatCache(mode: selectedProfileMode, entries: entries, byPath: byPath)
        return byPath[path]
    }

    func jumpToLocation(path: String, line: Int, column: Int = 1) {
        jumpTo(filePath: path, line: line, column: column)
    }

    func loadWorkspaceTests() {
        guard !activeWorkspacePath.isEmpty else { return }
        let root = activeWorkspacePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let json: String? = root.withCString { cDir in
                guard let c = DiscoverGoTests(cDir) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            let suites = json.flatMap { try? JSONDecoder().decode([GoTestSuite].self, from: Data($0.utf8)) }
            DispatchQueue.main.async {
                guard let self, self.activeWorkspacePath == root else { return }
                if let suites {
                    let isFirstDiscovery = !self.testsDiscovered
                    if isFirstDiscovery && self.collapsedTestSuiteIDs.isEmpty {
                        let totalTests = suites.reduce(0) { $0 + $1.tests.count }
                        if totalTests > 60 {
                            self.collapsedTestSuiteIDs = Set(suites.map(\.id))
                        }
                    }
                    self.testSuites = suites
                    self.testsDiscovered = true
                } else {
                    self.appendLog("Test discovery failed.")
                }
            }
        }
    }

    func refreshFileTests(_ path: String) {
        guard path.hasSuffix("_test.go") else { return }
        fileTestsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let json: String? = path.withCString { p in
                guard let c = FileTests(p) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            guard let info = json.flatMap({ try? JSONDecoder().decode(FileTestsInfo.self, from: Data($0.utf8)) }) else { return }
            DispatchQueue.main.async {
                guard let self, self.documents[path] != nil else { return }
                self.fileTests[path] = info
                self.fileTestLines[path] = Self.testLines(info, path: path)
                if let session = self.documents[path],
                   info.tests.contains(where: { $0.name.hasPrefix("Benchmark") }) {
                    if var existing = self.goplsLenses[path] {
                        for (lineNum, lineItems) in existing {
                            let pruned = lineItems.filter {
                                let vc = ($0.command["golensCommand"] as? String) ?? ""
                                return vc != "runBenchmark" && vc != "profileBenchmark" && vc != "compareBenchmarkBaseline"
                            }
                            if pruned.isEmpty {
                                existing.removeValue(forKey: lineNum)
                            } else {
                                existing[lineNum] = pruned
                            }
                        }
                        self.goplsLenses[path] = existing
                    }
                    let updatedLenses = CodeLensProvider.benchmarkLenses(in: session.storage.string, path: path, workspace: self)
                    self.mergeGeneratedCodeLenses(updatedLenses, path: path)
                }
                (self.activeTextView as? GoLensTextView)?.redrawGutter()
            }
        }
        fileTestsWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    static func testLines(_ info: FileTestsInfo, path: String) -> [Int: TestTarget] {
        let dir = (path as NSString).deletingLastPathComponent
        let canonical = canonicalPath(path)
        var lines: [Int: TestTarget] = [:]
        for test in info.tests {
            if test.line > 0 {
                lines[test.line] = TestTarget(dir: dir, importPath: info.importPath, test: test.name, row: nil)
            }
            for row in test.rows where row.line > 0 && (row.file == nil || canonicalPath(row.file!) == canonical) && lines[row.line] == nil {
                lines[row.line] = TestTarget(dir: dir, importPath: info.importPath, test: test.name, row: row.id)
            }
        }
        return lines
    }

    func testTarget(_ suite: GoTestSuite, _ test: GoTestFunc, row: String? = nil) -> TestTarget {
        TestTarget(dir: packageDir(suite), importPath: suite.importPath, test: test.name, row: row)
    }

    func packageDir(_ suite: GoTestSuite) -> String {
        if (suite.dir as NSString).isAbsolutePath { return suite.dir }
        return suite.dir == "." ? activeWorkspacePath : (activeWorkspacePath as NSString).appendingPathComponent(suite.dir)
    }

    private struct CaretTestTargetDTO: Decodable {
        let found: Bool
        let test: String?
        let subtests: [String]?
        let subtestPath: String?
        let pattern: String?
    }

    func resolveCaretTestTarget(in path: String, line: Int) -> ResolvedCaretTest? {
        guard !path.isEmpty, path.hasSuffix("_test.go"), line > 0 else { return nil }
        let json: String? = path.withCString { cPath in
            guard let ptr = ResolveCaretTestTarget(cPath, Int32(line)) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let data = json?.data(using: .utf8),
              let dto = try? JSONDecoder().decode(CaretTestTargetDTO.self, from: data),
              dto.found,
              let testName = dto.test,
              !testName.isEmpty else {
            return nil
        }
        let dir = (path as NSString).deletingLastPathComponent
        let canonicalDir = Self.canonicalPath(dir)
        let importPath = fileTests[path]?.importPath
            ?? testSuites.first { Self.canonicalPath(packageDir($0)) == canonicalDir }?.importPath
            ?? ""
        let row = (dto.subtestPath?.isEmpty == false) ? dto.subtestPath : nil
        let pattern = (dto.pattern?.isEmpty == false) ? dto.pattern : nil
        let target = TestTarget(dir: dir, importPath: importPath, test: testName, row: row)
        return ResolvedCaretTest(target: target, patternOverride: pattern)
    }

    func activeCaretLine(for path: String) -> Int {
        if let tv = activeTextView as? GoLensTextView, tv.filePath == path {
            return max(1, tv.lineAndCol(forCharacterIndex: tv.selectedRange().location).line)
        }
        return max(1, cursorLine)
    }

    func runTestAtCursor() {
        guard !activeWorkspacePath.isEmpty, !isRunning else { return }
        guard activeFilePath.hasSuffix("_test.go") else {
            presentCommandFeedback("Open a *_test.go file and place the cursor inside a test function or subtest.", title: "Run Test at Cursor")
            return
        }
        let line = activeCaretLine(for: activeFilePath)
        guard let resolved = resolveCaretTestTarget(in: activeFilePath, line: line) else {
            presentCommandFeedback("Place the cursor inside a Test, Benchmark, Fuzz, or suite test method.", title: "Run Test at Cursor")
            return
        }
        runTests(resolved.target, patternOverride: resolved.patternOverride)
    }

    func debugTestAtCursor() {
        guard !activeWorkspacePath.isEmpty, !isRunning else { return }
        guard activeFilePath.hasSuffix("_test.go") else {
            presentCommandFeedback("Open a *_test.go file and place the cursor inside a test function or subtest.", title: "Debug Test at Cursor")
            return
        }
        let line = activeCaretLine(for: activeFilePath)
        guard let resolved = resolveCaretTestTarget(in: activeFilePath, line: line) else {
            presentCommandFeedback("Place the cursor inside a Test, Benchmark, Fuzz, or suite test method.", title: "Debug Test at Cursor")
            return
        }
        debugProject(test: resolved.target, patternOverride: resolved.patternOverride)
    }

    func repeatLastTest() {
        guard !activeWorkspacePath.isEmpty, !isRunning else { return }
        guard let last = lastTestInvocation else {
            presentCommandFeedback("Run or debug a test first before repeating it.", title: "Repeat Last Test")
            return
        }
        switch last {
        case let .target(target, cover, profile, fuzz, patternOverride):
            runTests(target, cover: cover, profile: profile, fuzz: fuzz, patternOverride: patternOverride)
        case let .suite(dir, title, cover, profile):
            lastTestInvocation = .suite(dir: dir, title: title, cover: cover, profile: profile)
            startTestRun(["dir": dir, "packages": ["."], "cover": cover, "profile": profile], title: title)
        case let .all(cover, profile):
            runAllTests(cover: cover, profile: profile)
        case let .debug(target, patternOverride):
            debugProject(test: target, patternOverride: patternOverride)
        }
    }

    func runTests(_ target: TestTarget, cover: Bool = false, profile: Bool = false, fuzz: Bool = false, patternOverride: String? = nil) {
        lastTestInvocation = .target(target, cover: cover, profile: profile, fuzz: fuzz, patternOverride: patternOverride)
        var request: [String: Any] = ["dir": target.dir, "packages": ["."], "test": target.test, "cover": cover, "profile": profile]
        if target.test.hasPrefix("Benchmark") { request["bench"] = true }
        if fuzz {
            request["fuzz"] = true
            request["fuzzTime"] = "5s"
        }
        if let row = target.row { request["row"] = row }
        if let patternOverride, !patternOverride.isEmpty { request["pattern"] = patternOverride }
        if fuzz {
            startTestRun(request, logLine: "Fuzzing \(target.title) (5s)…")
        } else {
            startTestRun(request, title: target.title)
        }
    }

    func runTests(suite: GoTestSuite, cover: Bool = false, profile: Bool = false) {
        let dir = packageDir(suite)
        lastTestInvocation = .suite(dir: dir, title: suite.package, cover: cover, profile: profile)
        startTestRun(["dir": dir, "packages": ["."], "cover": cover, "profile": profile], title: suite.package)
    }

    func runAllTests(cover: Bool = false, profile: Bool = false) {
        guard !activeWorkspacePath.isEmpty else { return }
        lastTestInvocation = .all(cover: cover, profile: profile)
        startTestRun(["dir": activeWorkspacePath, "packages": ["./..."], "cover": cover, "profile": profile], title: "all tests")
    }

    func runAllBenchmarks() {
        guard !activeWorkspacePath.isEmpty else { return }
        startTestRun([
            "dir": activeWorkspacePath,
            "packages": ["./..."],
            "bench": true
        ], logLine: "Running benchmarks…")
    }

    func runBenchmarks(suite: GoTestSuite) {
        startTestRun([
            "dir": packageDir(suite),
            "packages": ["."],
            "bench": true
        ], logLine: "Running benchmarks in \(suite.package)…")
    }

    func runTestsWithCoverage() {
        runAllTests(cover: true)
    }

    func profileBenchmark(path: String, name: String) {
        let dir = (path as NSString).deletingLastPathComponent
        let importPath = fileTests[path]?.importPath ?? "."
        runTests(TestTarget(dir: dir, importPath: importPath, test: name, row: nil), profile: true)
    }

    func profileAllTests() {
        runAllTests(profile: true)
    }

    func rerunFailedTests() {
        var failedByPkg: [String: [String]] = [:]
        for (key, status) in testResults where status == .failed {
            let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let testPath = String(parts[1])
            guard !testPath.isEmpty else { continue }
            failedByPkg[String(parts[0]), default: []].append(testPath)
        }
        guard !failedByPkg.isEmpty else {
            presentCommandFeedback("Run your tests first — there are no failed tests to rerun.", title: "Rerun Failed Tests")
            return
        }
        var failed: [String: [String]] = [:]
        for (pkg, rawNames) in failedByPkg {
            let pruned = FailedSubtestSelection.pruneAncestors(rawNames)
            if !pruned.isEmpty {
                failed[pkg] = pruned
            }
        }
        guard !failed.isEmpty else {
            presentCommandFeedback("Run your tests first — there are no failed tests to rerun.", title: "Rerun Failed Tests")
            return
        }
        let dirs = Dictionary(testSuites.map { ($0.importPath, packageDir($0)) }, uniquingKeysWith: { a, _ in a })
            .merging(fileTests.map { ($0.value.importPath, ($0.key as NSString).deletingLastPathComponent) }, uniquingKeysWith: { a, _ in a })
        var packages = failed.keys.compactMap { dirs[$0] }
        if packages.isEmpty && !activeWorkspacePath.isEmpty {
            packages = [activeWorkspacePath]
        }
        guard !packages.isEmpty else {
            presentCommandFeedback("Couldn’t locate the package directory for the failed tests.", title: "Rerun Failed Tests", tone: .warning)
            return
        }
        let names = failed.values.flatMap { $0 }.sorted()
        if packages.count == 1 {
            startTestRun(["dir": packages[0], "packages": ["."], "failed": names], title: "failed tests")
        } else {
            let root = activeWorkspacePath
            let rel = packages.map { $0 == root ? "." : "./" + String($0.dropFirst(root.count + 1)) }
            startTestRun(["dir": root, "packages": rel, "failed": names], title: "failed tests")
        }
    }

    private func startTestRun(_ request: [String: Any], title: String) {
        startTestRun(request, logLine: "Testing \(title)…")
    }

    private func startTestRun(_ request: [String: Any], logLine: String) {
        var request = request
        addRunTarget(to: &request, action: .test)
        let logLine = activeRunTarget.isRemote ? logLine.replacingOccurrences(of: "…", with: " on \(activeRunTarget.title)…") : logLine
        guard !debug.isDebugMode, let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return }
        runFailure = nil
        clearTestFailures()
        isTestRunning = true
        testSummary = nil
        selectedRunSessionId = nil
        if request["profile"] as? Bool == true {
            cpuProfileEntries = []
            memProfileEntries = []
            blockProfileEntries = []
            mutexProfileEntries = []
            hasProfileData = false
        }
        consoleOutput.removeAll()
        consoleOutputBytes = 0
        showConsole = true
        selectedConsoleTab = Self.consoleTab
        appendLog(logLine)
        currentTestRun = -1
        testing.stopTestRunWhenStarted = false
        saveAllEdited(then: {
            self.launchTestRun(json)
        }, onFailure: {
            self.currentTestRun = 0
            self.pendingTestEvents.removeAll()
            self.isTestRunning = false
        })
    }

    private func launchTestRun(_ json: String) {
        claimCoreEvents(.tests, .output)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let run = json.withCString { RunTests($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if run == 0 {
                    self.currentTestRun = 0
                    self.pendingTestEvents.removeAll()
                    self.isTestRunning = false
                } else {
                    self.ownTask(run)
                    self.currentTestRun = run
                    self.stopTestRunIfRequested(run)
                    self.flushTestEvents()
                }
            }
        }
    }

    func stopTests() {
        let run = currentTestRun
        guard run > 0 else {
            if run < 0 { testing.stopTestRunWhenStarted = true }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { StopTestRun(run) }
    }

    func stopTestRunIfRequested(_ run: Int64) {
        guard testing.stopTestRunWhenStarted else { return }
        testing.stopTestRunWhenStarted = false
        DispatchQueue.global(qos: .userInitiated).async { StopTestRun(run) }
    }

    func stopActiveRun() {
        if debug.isDebugMode {
            debugStop()
        } else if isTestRunning {
            stopTests()
        } else if isRunning {
            if let id = selectedRunSessionId, runSessions.contains(where: { $0.id == id && $0.isRunning }) {
                stopRunSession(id)
            } else if let running = runSessions.last(where: \.isRunning) {
                stopRunSession(running.id)
            } else {
                isStartingRun = false
                let owned = ownedTaskIDs()
                agentQueue.async {
                    for id in owned where id > 0 {
                        StopProgramRun(id)
                    }
                }
            }
        }
    }

    func receiveTestEvent(_ json: String) {
        let data = Data(json.utf8)
        guard let event = try? JSONDecoder().decode(TestResultEvent.self, from: data) else { return }
        DispatchQueue.main.async {
            self.pendingTestEvents.append(event)
            guard !self.testFlushScheduled else { return }
            self.testFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.flushTestEvents() }
        }
    }

    private func applyCoveragePayload(_ event: TestResultEvent) {
        if let files = event.filesCoverage {
            for item in files {
                if fileCoverage[item.file] == nil && fileCoverage.count >= Self.maxCoverageFiles {
                    continue
                }
                var lineMap: [Int: Bool] = [:]
                lineMap.reserveCapacity(item.coveredLines.count + item.uncoveredLines.count)
                for line in item.uncoveredLines {
                    lineMap[line] = false
                }
                for line in item.coveredLines {
                    lineMap[line] = true
                }
                fileCoverage[item.file] = lineMap
                let resolved = URL(fileURLWithPath: item.file).resolvingSymlinksInPath().path
                if resolved != item.file && (fileCoverage[resolved] != nil || fileCoverage.count < Self.maxCoverageFiles) {
                    fileCoverage[resolved] = lineMap
                }
            }
        }
        if let pkgs = event.packageCoverage {
            for (pkg, pct) in pkgs {
                packageCoverage[pkg] = pct
            }
        }
        hasCoverageData = !fileCoverage.isEmpty || !packageCoverage.isEmpty
        activeTextView?.needsDisplay = true
    }

    func flushTestEvents() {
        testFlushScheduled = false
        guard currentTestRun > 0 else { return }
        let events = pendingTestEvents
        pendingTestEvents.removeAll(keepingCapacity: true)
        var results = testResults
        var durations = testDurations
        var subtests = dynamicSubtests
        var finished: TestResultEvent?
        var benchUpdated = false
        for event in events where event.run == currentTestRun {
            if event.kind == "coverage" || event.status == "coverage" {
                applyCoveragePayload(event)
                continue
            }
            if event.kind == "profile" || event.status == "profile" {
                cpuProfileEntries = Array((event.cpuProfile ?? []).prefix(Self.maxProfileEntries))
                memProfileEntries = Array((event.memProfile ?? []).prefix(Self.maxProfileEntries))
                blockProfileEntries = Array((event.blockProfile ?? []).prefix(Self.maxProfileEntries))
                mutexProfileEntries = Array((event.mutexProfile ?? []).prefix(Self.maxProfileEntries))
                hasProfileData = !cpuProfileEntries.isEmpty || !memProfileEntries.isEmpty || !blockProfileEntries.isEmpty || !mutexProfileEntries.isEmpty
                for paths in (event.profileFiles ?? [:]).values {
                    for path in paths { MainActor.assumeIsolated { gopilot.noteProfile(path: path) } }
                }
                if hasProfileData {
                    showConsole = true
                    selectedConsoleTab = Self.profilerTab
                    activeTextView?.needsDisplay = true
                    (activeTextView as? GoLensTextView)?.redrawGutter()
                }
                continue
            }
            if event.kind == "done" {
                finished = event
                continue
            }
            guard let pkg = event.package, let name = event.test, let raw = event.status else { continue }
            let status: TestStatus
            switch raw {
            case "running": status = .running
            case "pass": status = .passed
            case "fail": status = .failed
            case "skip": status = .skipped
            default: continue
            }
            let key = Self.testKey(importPath: pkg, test: name)
            if let metric = event.benchMetric, !metric.isEmpty {
                if benchMetrics.count >= Self.maxBenchMetrics {
                    benchMetrics.removeAll(keepingCapacity: true)
                }
                benchMetrics[key] = metric
                if pkg.isEmpty {
                    benchMetrics[name] = metric
                }
                if let parsed = Self.parseBenchmarkMetricString(metric) {
                    let rawLine = String(
                        format: "%@-8\t1000000\t%.2f ns/op\t%lld B/op\t%lld allocs/op",
                        name,
                        parsed.nsPerOp,
                        parsed.bytesPerOp,
                        parsed.allocsPerOp
                    )
                    if lastBenchmarkOutputRaw.isEmpty {
                        lastBenchmarkOutputRaw = rawLine
                    } else {
                        if lastBenchmarkOutputRaw.utf8.count > 65_536 {
                            lastBenchmarkOutputRaw = String(lastBenchmarkOutputRaw.suffix(32_768))
                        }
                        lastBenchmarkOutputRaw += "\n" + rawLine
                    }
                }
                benchUpdated = true
            }
            if status == .failed, let failures = event.failures, !failures.isEmpty {
                for f in failures {
                    let totalCount = testFailureAnnotations.values.reduce(0) { $0 + $1.count }
                    if totalCount < Self.maxTestFailures {
                        let path = f.file
                        var list = testFailureAnnotations[path] ?? []
                        if !list.contains(where: { $0.line == f.line && $0.testName == f.testName }) {
                            list.append(f)
                            testFailureAnnotations[path] = list
                            testFailureAnnotationsGeneration &+= 1
                        }
                    }
                }
                activeTextView?.needsDisplay = true
            }
            if results[key] == nil && results.count >= Self.maxTestResults { continue }
            results[key] = status
            if status == .running {
                durations.removeValue(forKey: key)
            } else if let elapsed = event.elapsed, elapsed >= 0 {
                durations[key] = elapsed
            }
            if let slash = name.firstIndex(of: "/") {
                let parent = testKey(pkg, String(name[..<slash]))
                let sub = String(name[name.index(after: slash)...])
                var list = subtests[parent] ?? []
                if !list.contains(sub) && list.count < Self.maxDynamicSubtests {
                    list.append(sub)
                    subtests[parent] = list
                }
            }
        }
        if benchUpdated {
            recomputeBenchmarkComparison()
            refreshBenchmarkCodeLenses()
        }
        if let done = finished {
            for (key, status) in results where status == .running {
                results[key] = TestStatus.none
            }
            let summary = TestSummary(passed: done.passed ?? 0, failed: done.failed ?? 0, skipped: done.skipped ?? 0)
            testSummary = summary
            isTestRunning = false
            currentTestRun = 0
            switch done.status {
            case "pass":
                appendLog("Tests passed: \(summary.passed) passed, \(summary.skipped) skipped.")
                showBuildOverlay(.testsSucceeded)
            case "cancelled":
                appendLog("Testing stopped.")
            default:
                let reason = summary.failed > 0 ? "\(summary.failed) failed" : "Build failed"
                appendLog("Tests failed: \(summary.passed) passed, \(summary.failed) failed, \(summary.skipped) skipped.")
                showBuildOverlay(.testsFailed(reason))
            }
        }
        if results != testResults { testResults = results }
        if durations != testDurations { testDurations = durations }
        if subtests != dynamicSubtests { dynamicSubtests = subtests }
        if finished != nil {
            for suite in testSuites where suiteAggregateStatus(for: suite).failedCount > 0 {
                collapsedTestSuiteIDs.remove(suite.id)
                for test in suite.tests where effectiveTestStatus(suite.importPath, test) == .failed {
                    if !test.rows.isEmpty || !subtestIDs(suite.importPath, test).isEmpty {
                        expandedTestFuncIDs.insert(TestNodeID.test(suite, test))
                    }
                }
            }
        }
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func testFailureAnnotationsForPath(_ path: String) -> [TestFailureAnnotation] {
        if testFailureAnnotations.isEmpty { return [] }
        if let list = testFailureAnnotations[path] { return list }
        if testFailureLookupCache.generation != testFailureAnnotationsGeneration {
            testFailureLookupCache = (testFailureAnnotationsGeneration, [:])
        }
        if let key = testFailureLookupCache.keys[path] {
            return key.flatMap { testFailureAnnotations[$0] } ?? []
        }
        var match: String?
        let resolved = Self.canonicalPath(path)
        if testFailureAnnotations[resolved] != nil {
            match = resolved
        } else if let canonicalHit = testFailureAnnotations.keys.first(where: { Self.canonicalPath($0) == resolved }) {
            match = canonicalHit
        } else {
            let base = (path as NSString).lastPathComponent
            match = testFailureAnnotations.keys.first { ($0 as NSString).lastPathComponent == base }
        }
        testFailureLookupCache.keys[path] = .some(match)
        return match.flatMap { testFailureAnnotations[$0] } ?? []
    }

    func failureAnnotation(
        forTestName fullName: String,
        preferredFile: String? = nil,
        preferredDir: String? = nil
    ) -> TestFailureAnnotation? {
        guard !testFailureAnnotations.isEmpty, !fullName.isEmpty else { return nil }
        let all = testFailureAnnotations.values.flatMap { $0 }
        let prefFileCanonical = preferredFile.map(Self.canonicalPath)
        let prefDirCanonical = preferredDir.map(Self.canonicalPath)

        func rank(_ ann: TestFailureAnnotation) -> Int {
            let annFile = Self.canonicalPath(ann.file)
            if let prefFileCanonical, annFile == prefFileCanonical { return 0 }
            if let prefDirCanonical, annFile.hasPrefix(prefDirCanonical + "/") || (annFile as NSString).deletingLastPathComponent == prefDirCanonical {
                return 1
            }
            return 2
        }

        let exact = all.filter { $0.testName == fullName }.sorted { rank($0) < rank($1) }
        if let first = exact.first {
            return first
        }
        let prefix = fullName + "/"
        let descendants = all.filter { $0.testName.hasPrefix(prefix) }.sorted { rank($0) < rank($1) }
        return descendants.first
    }

    func jumpToTestFailureAndPresentPopup(filePath: String, line: Int, testFailure: TestFailureAnnotation?) {
        let clampedLine = max(1, line)
        testing.pendingFailurePopupToken &+= 1
        let token = testing.pendingFailurePopupToken
        let canonicalTarget = Self.canonicalPath(filePath)
        issuePopup = nil
        jumpTo(filePath: filePath, line: clampedLine, column: 1)
        scheduleFailurePopupAfterJumpSettles(
            targetPath: canonicalTarget,
            line: clampedLine,
            testFailure: testFailure,
            token: token,
            attempt: 0
        )
    }

    private func scheduleFailurePopupAfterJumpSettles(
        targetPath: String,
        line: Int,
        testFailure: TestFailureAnnotation?,
        token: Int,
        attempt: Int
    ) {
        let delay: TimeInterval = attempt == 0 ? 0.06 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.testing.pendingFailurePopupToken == token else { return }
            let activeCanonical = self.activeFilePath.isEmpty ? "" : Self.canonicalPath(self.activeFilePath)
            let pane = self.paneState(for: self.effectiveFocusedPaneID)
            let ready = activeCanonical == targetPath
                && self.documents[self.activeFilePath] != nil
                && pane.pendingJumpToLine == nil
            guard ready else {
                if attempt < 30 {
                    self.scheduleFailurePopupAfterJumpSettles(
                        targetPath: targetPath,
                        line: line,
                        testFailure: testFailure,
                        token: token,
                        attempt: attempt + 1
                    )
                }
                return
            }
            guard let textView = self.editorTextView(for: self.effectiveFocusedPaneID) ?? (self.activeTextView as? GoLensTextView),
                  let session = textView.document else { return }
            guard let offset = session.lines.start(ofLine: max(0, line - 1)) ?? session.offset(line: max(0, line - 1), utf16Column: 0) else { return }
            let caret = NSRange(location: offset, length: 0)
            if textView.selectedRange().location != offset {
                textView.setSelectedRange(caret)
            }
            textView.scrollRangeToVisible(caret)
            textView.setNeedsDisplay(textView.visibleRect)

            let byLine = textView.issuesByLine()
            let diags = byLine[line] ?? []
            let resolvedFailure = testFailure ?? self.testFailureAnnotationsForPath(textView.filePath).first { $0.line == line }
            guard resolvedFailure != nil || !diags.isEmpty else { return }

            let anchor: NSRect
            if let hit = textView.issueHitRects[line] {
                anchor = hit.0
            } else if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                let charRange = NSRange(location: offset, length: offset < session.length ? 1 : 0)
                layoutManager.ensureLayout(forCharacterRange: charRange)
                let glyphs = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += textView.textContainerOrigin.x
                rect.origin.y += textView.textContainerOrigin.y
                anchor = rect
            } else {
                return
            }
            self.presentIssuePopup(
                in: textView,
                line: line,
                diags: diags,
                below: anchor,
                preferredTestFailure: resolvedFailure
            )
        }
    }

    func clearTestFailures() {
        if !testFailureAnnotations.isEmpty {
            testFailureAnnotations.removeAll()
            testFailureAnnotationsGeneration &+= 1
            activeTextView?.needsDisplay = true
        }
    }

    func rerunTestFailure(_ failure: TestFailureAnnotation) {
        let fileDir = (failure.file as NSString).deletingLastPathComponent
        let fileCanonical = Self.canonicalPath(failure.file)
        let matchedSuiteDir = testSuites.first { suite in
            let sDir = Self.canonicalPath(packageDir(suite))
            return fileCanonical.hasPrefix(sDir + "/") || Self.canonicalPath(fileDir) == sDir
        }.map { packageDir($0) }
        let dir = matchedSuiteDir ?? fileDir
        let parts = failure.testName.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let topTest = parts.first.map(String.init) ?? failure.testName
        let subRow = parts.count > 1 ? String(parts[1]) : nil
        runTests(TestTarget(dir: dir, importPath: "", test: topTest, row: subRow))
    }
}
