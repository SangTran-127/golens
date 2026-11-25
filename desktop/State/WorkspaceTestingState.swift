import Foundation
import Observation

struct ResolvedCaretTest {
    let target: TestTarget
    let patternOverride: String?
}

enum LastTestInvocation {
    case target(TestTarget, cover: Bool, profile: Bool, fuzz: Bool, patternOverride: String?)
    case suite(dir: String, title: String, cover: Bool, profile: Bool)
    case all(cover: Bool, profile: Bool)
    case debug(TestTarget, patternOverride: String?)
}

@Observable
final class WorkspaceTestingState: @unchecked Sendable {
    var testSuites: [GoTestSuite] = []
    var collapsedTestSuiteIDs: Set<String> = []
    var expandedTestFuncIDs: Set<String> = []
    var testFilterQuery: String = ""
    var showFailedTestsOnly: Bool = false
    var testsDiscovered: Bool = false
    var testResults: [String: TestStatus] = [:]
    var testDurations: [String: Double] = [:]
    var dynamicSubtests: [String: [String]] = [:]
    var testFailureAnnotations: [String: [TestFailureAnnotation]] = [:]
    @ObservationIgnored var testFailureAnnotationsGeneration: Int = 0
    @ObservationIgnored var testFailureLookupCache: (generation: Int, keys: [String: String?]) = (0, [:])
    @ObservationIgnored var profileHeatCache: ProfileHeatCache?
    var isTestRunning: Bool = false
    var testSummary: TestSummary? = nil
    var fileTests: [String: FileTestsInfo] = [:]
    @ObservationIgnored var fileTestLines: [String: [Int: TestTarget]] = [:]
    @ObservationIgnored var fileCoverage: [String: [Int: Bool]] = [:]
    var packageCoverage: [String: Double] = [:]
    var hasCoverageData: Bool = false
    var cpuProfileEntries: [ProfileEntry] = []
    var memProfileEntries: [ProfileEntry] = []
    var blockProfileEntries: [ProfileEntry] = []
    var mutexProfileEntries: [ProfileEntry] = []
    var selectedProfileMode: String = "CPU"
    var hasProfileData: Bool = false
    var benchMetrics: [String: String] = [:]
    var benchmarkBaselines: [String: BenchmarkBaselineEntry] = [:]
    var lastBenchmarkOutputRaw: String = ""
    var benchmarkDiffItems: [BenchmarkDiffRow] = []
    var benchmarkFasterCount: Int = 0
    var benchmarkRegressedCount: Int = 0
    var benchmarkUnchangedCount: Int = 0
    var benchmarkBaselineSavedBanner: String? = nil
    var safetyFindings: [SafetyFinding] = []
    var safetySummary: String = ""
    var isSafetyAuditRunning: Bool = false
    var hasSafetyData: Bool = false
    var lastTestInvocation: LastTestInvocation? = nil
    @ObservationIgnored var currentTestRun: Int64 = 0
    @ObservationIgnored var stopTestRunWhenStarted = false
    @ObservationIgnored var pendingTestEvents: [TestResultEvent] = []
    @ObservationIgnored var testFlushScheduled: Bool = false
    @ObservationIgnored var fileTestsWork: DispatchWorkItem?
    @ObservationIgnored var autoTestDebounceWorkItem: DispatchWorkItem?
    @ObservationIgnored var lastAutoTestTime: CFAbsoluteTime = 0
    @ObservationIgnored var pendingFailurePopupToken: Int = 0
}

extension WorkspaceState {
    static let maxTestFailures = 100
    static let maxCoverageFiles = 500
    static let maxProfileEntries = 500
    static let maxBenchMetrics = 5000

    var testSuites: [GoTestSuite] {
        get { testing.testSuites }
        set { testing.testSuites = newValue }
    }

    var collapsedTestSuiteIDs: Set<String> {
        get { testing.collapsedTestSuiteIDs }
        set { testing.collapsedTestSuiteIDs = newValue }
    }

    var expandedTestFuncIDs: Set<String> {
        get { testing.expandedTestFuncIDs }
        set { testing.expandedTestFuncIDs = newValue }
    }

    var testFilterQuery: String {
        get { testing.testFilterQuery }
        set { testing.testFilterQuery = newValue }
    }

    var showFailedTestsOnly: Bool {
        get { testing.showFailedTestsOnly }
        set { testing.showFailedTestsOnly = newValue }
    }

    var testsDiscovered: Bool {
        get { testing.testsDiscovered }
        set { testing.testsDiscovered = newValue }
    }

    var testResults: [String: TestStatus] {
        get { testing.testResults }
        set { testing.testResults = newValue }
    }

    var testDurations: [String: Double] {
        get { testing.testDurations }
        set { testing.testDurations = newValue }
    }

    var dynamicSubtests: [String: [String]] {
        get { testing.dynamicSubtests }
        set { testing.dynamicSubtests = newValue }
    }

    var testFailureAnnotations: [String: [TestFailureAnnotation]] {
        get { testing.testFailureAnnotations }
        set { testing.testFailureAnnotations = newValue }
    }

    var testFailureAnnotationsGeneration: Int {
        get { testing.testFailureAnnotationsGeneration }
        set { testing.testFailureAnnotationsGeneration = newValue }
    }

    var testFailureLookupCache: (generation: Int, keys: [String: String?]) {
        get { testing.testFailureLookupCache }
        set { testing.testFailureLookupCache = newValue }
    }

    var profileHeatCache: ProfileHeatCache? {
        get { testing.profileHeatCache }
        set { testing.profileHeatCache = newValue }
    }

    var isTestRunning: Bool {
        get { testing.isTestRunning }
        set { testing.isTestRunning = newValue }
    }

    var testSummary: TestSummary? {
        get { testing.testSummary }
        set { testing.testSummary = newValue }
    }

    var fileTests: [String: FileTestsInfo] {
        get { testing.fileTests }
        set { testing.fileTests = newValue }
    }

    var fileTestLines: [String: [Int: TestTarget]] {
        get { testing.fileTestLines }
        set { testing.fileTestLines = newValue }
    }

    var fileCoverage: [String: [Int: Bool]] {
        get { testing.fileCoverage }
        set { testing.fileCoverage = newValue }
    }

    var packageCoverage: [String: Double] {
        get { testing.packageCoverage }
        set { testing.packageCoverage = newValue }
    }

    var hasCoverageData: Bool {
        get { testing.hasCoverageData }
        set { testing.hasCoverageData = newValue }
    }

    var cpuProfileEntries: [ProfileEntry] {
        get { testing.cpuProfileEntries }
        set { testing.cpuProfileEntries = newValue }
    }

    var memProfileEntries: [ProfileEntry] {
        get { testing.memProfileEntries }
        set { testing.memProfileEntries = newValue }
    }

    var blockProfileEntries: [ProfileEntry] {
        get { testing.blockProfileEntries }
        set { testing.blockProfileEntries = newValue }
    }

    var mutexProfileEntries: [ProfileEntry] {
        get { testing.mutexProfileEntries }
        set { testing.mutexProfileEntries = newValue }
    }

    var selectedProfileMode: String {
        get { testing.selectedProfileMode }
        set { testing.selectedProfileMode = newValue }
    }

    var hasProfileData: Bool {
        get { testing.hasProfileData }
        set { testing.hasProfileData = newValue }
    }

    var benchMetrics: [String: String] {
        get { testing.benchMetrics }
        set { testing.benchMetrics = newValue }
    }

    var benchmarkBaselines: [String: BenchmarkBaselineEntry] {
        get { testing.benchmarkBaselines }
        set { testing.benchmarkBaselines = newValue }
    }

    var lastBenchmarkOutputRaw: String {
        get { testing.lastBenchmarkOutputRaw }
        set { testing.lastBenchmarkOutputRaw = newValue }
    }

    var benchmarkDiffItems: [BenchmarkDiffRow] {
        get { testing.benchmarkDiffItems }
        set { testing.benchmarkDiffItems = newValue }
    }

    var benchmarkFasterCount: Int {
        get { testing.benchmarkFasterCount }
        set { testing.benchmarkFasterCount = newValue }
    }

    var benchmarkRegressedCount: Int {
        get { testing.benchmarkRegressedCount }
        set { testing.benchmarkRegressedCount = newValue }
    }

    var benchmarkUnchangedCount: Int {
        get { testing.benchmarkUnchangedCount }
        set { testing.benchmarkUnchangedCount = newValue }
    }

    var benchmarkBaselineSavedBanner: String? {
        get { testing.benchmarkBaselineSavedBanner }
        set { testing.benchmarkBaselineSavedBanner = newValue }
    }

    var safetyFindings: [SafetyFinding] {
        get { testing.safetyFindings }
        set { testing.safetyFindings = newValue }
    }

    var safetySummary: String {
        get { testing.safetySummary }
        set { testing.safetySummary = newValue }
    }

    var isSafetyAuditRunning: Bool {
        get { testing.isSafetyAuditRunning }
        set { testing.isSafetyAuditRunning = newValue }
    }

    var hasSafetyData: Bool {
        get { testing.hasSafetyData }
        set { testing.hasSafetyData = newValue }
    }

    var lastTestInvocation: LastTestInvocation? {
        get { testing.lastTestInvocation }
        set { testing.lastTestInvocation = newValue }
    }

    var hasLastTestInvocation: Bool {
        testing.lastTestInvocation != nil
    }

    var currentTestRun: Int64 {
        get { testing.currentTestRun }
        set { testing.currentTestRun = newValue }
    }

    var pendingTestEvents: [TestResultEvent] {
        get { testing.pendingTestEvents }
        set { testing.pendingTestEvents = newValue }
    }

    var testFlushScheduled: Bool {
        get { testing.testFlushScheduled }
        set { testing.testFlushScheduled = newValue }
    }

    var fileTestsWork: DispatchWorkItem? {
        get { testing.fileTestsWork }
        set { testing.fileTestsWork = newValue }
    }

    var isAutoTestOnSaveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "GoLensAutoTestOnSave") }
        set { UserDefaults.standard.set(newValue, forKey: "GoLensAutoTestOnSave") }
    }

    func triggerDebouncedAutoTest(forFilePath path: String) {
        guard isAutoTestOnSaveEnabled, path.hasSuffix(".go"),
              !isRunning, !isTestRunning, !debug.isDebugMode else { return }

        testing.autoTestDebounceWorkItem?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let waitWindow: Double = 1.5
        let elapsed = now - testing.lastAutoTestTime

        if elapsed >= waitWindow {
            testing.lastAutoTestTime = now
            executeQuietAutoTest(forFilePath: path)
        } else {
            let remaining = waitWindow - elapsed
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.testing.lastAutoTestTime = CFAbsoluteTimeGetCurrent()
                self.executeQuietAutoTest(forFilePath: path)
            }
            testing.autoTestDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }

    func executeQuietAutoTest(forFilePath path: String) {
        guard !isRunning, !isTestRunning, !debug.isDebugMode else { return }
        let dir = (path as NSString).deletingLastPathComponent
        let req: [String: Any] = [
            "dir": dir,
            "packages": ["."],
            "short": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let json = String(data: data, encoding: .utf8) else { return }

        isTestRunning = true
        currentTestRun = -1
        testing.stopTestRunWhenStarted = false
        claimCoreEvents(.tests, .output)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let run = json.withCString { RunTests($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if run == 0 {
                    self.currentTestRun = 0
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
}
