import SwiftUI

struct TestSidebarView: View {
    @Bindable var workspace: WorkspaceState
    @State private var selection: String? = nil

    init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    private var totalFailedCount: Int {
        workspace.testSuites.reduce(0) { $0 + workspace.suiteAggregateStatus(for: $1).failedCount }
    }

    var body: some View {
        let displayed = filteredSuites
        VStack(spacing: 0) {
            TestNavigatorBar(workspace: workspace)
            Divider()
            if !workspace.testsDiscovered {
                UnifiedEmptyState.loading(message: "Discovering Go tests…")
            } else if workspace.testSuites.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "checkmark.diamond",
                    badge: "tests",
                    title: "No Tests",
                    message: "Functions named TestXxx, BenchmarkXxx, or FuzzXxx in _test.go files appear here.",
                    actionTitle: "Refresh",
                    action: { workspace.loadWorkspaceTests() }
                )
            } else {
                filterBar(displayed: displayed)
                Divider()
                if displayed.isEmpty {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Tests") {
                        workspace.showFailedTestsOnly = false
                        workspace.testFilterQuery = ""
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(displayed, id: \.suite.id) { item in
                            TestSuiteNode(
                                workspace: workspace,
                                suite: item.suite,
                                filteredTests: item.tests,
                                selectedNodeID: selection,
                                onActivateNode: selectAndActivateNode
                            )
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.automatic)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let first = ids.first {
                            if let failure = failureForNode(first) {
                                Button("Jump to Failure", systemImage: StatusTone.failure.symbol) {
                                    workspace.jumpToTestFailureAndPresentPopup(
                                        filePath: failure.file,
                                        line: failure.line,
                                        testFailure: failure
                                    )
                                }
                            }
                            if let loc = location(for: first) {
                                Button("Jump to Declaration", systemImage: "text.cursor") {
                                    workspace.jumpTo(filePath: loc.file, line: loc.line, column: 1)
                                }
                            }
                        }
                    } primaryAction: { ids in
                        if let first = ids.first {
                            jumpToTestNode(first, openPopupIfFailed: true)
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        guard let newValue else { return }
                        if isNodeFailed(newValue) || failureForNode(newValue) != nil {
                            jumpToTestNode(newValue, openPopupIfFailed: true)
                        }
                    }
                    .onKeyPress(.return) {
                        if let selection {
                            jumpToTestNode(selection, openPopupIfFailed: true)
                            return .handled
                        }
                        return .ignored
                    }
                }
            }
            if let summary = workspace.testSummary {
                Divider()
                TestSummaryBar(workspace: workspace, summary: summary)
            }
        }
        .onAppear {
            if !workspace.testsDiscovered {
                workspace.loadWorkspaceTests()
            }
        }
    }

    @ViewBuilder
    private func filterBar(displayed: [(suite: GoTestSuite, tests: [GoTestFunc])]) -> some View {
        let failedCount = totalFailedCount
        HStack(spacing: Spacing.row) {
            PanelFilterBar(
                placeholder: "Filter tests…",
                text: $workspace.testFilterQuery,
                accessibilityTitle: "Filter Tests",
                onSubmit: {
                    if let selection {
                        jumpToTestNode(selection, openPopupIfFailed: true)
                    } else if let firstID = flattenSelectableNodeIDs(in: displayed).first {
                        selection = firstID
                        jumpToTestNode(firstID, openPopupIfFailed: true)
                    }
                },
                onMoveSelection: { delta in
                    moveSelection(by: delta, in: displayed)
                }
            )

            Button {
                workspace.showFailedTestsOnly.toggle()
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: StatusTone.failure.symbol)
                        .font(.caption)
                        .foregroundStyle(workspace.showFailedTestsOnly || failedCount > 0 ? StatusTone.failure.tint : ChromeColor.textSecondary)
                    Text(failedCount > 0 ? "Failed (\(failedCount))" : "Failed")
                        .font(.caption.weight(workspace.showFailedTestsOnly ? .semibold : .medium))
                }
                .padding(.horizontal, Spacing.standard)
                .frame(height: 26)
                .background(workspace.showFailedTestsOnly ? StatusTone.failure.fill : ThemeColor.wellFill)
                .foregroundStyle(workspace.showFailedTestsOnly ? StatusTone.failure.tint : ChromeColor.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(workspace.showFailedTestsOnly ? "Show all tests" : "Filter tree to show only failed packages and tests")
            .accessibilityLabel("Show Failed Tests Only")
            .accessibilityAddTraits(workspace.showFailedTestsOnly ? .isSelected : [])
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private func flattenSelectableNodeIDs(in displayed: [(suite: GoTestSuite, tests: [GoTestFunc])]) -> [String] {
        var ids: [String] = []
        let forceExpandSuites = workspace.showFailedTestsOnly || !workspace.testFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for entry in displayed {
            let suiteExpanded = forceExpandSuites || !workspace.collapsedTestSuiteIDs.contains(entry.suite.id)
            guard suiteExpanded else { continue }
            for test in entry.tests {
                let testID = TestNodeID.test(entry.suite, test)
                ids.append(testID)
                let funcExpanded = (workspace.showFailedTestsOnly && workspace.effectiveTestStatus(entry.suite.importPath, test) == .failed)
                    || workspace.expandedTestFuncIDs.contains(testID)
                if funcExpanded {
                    for row in test.rows {
                        ids.append(TestNodeID.row(entry.suite, test, row.id))
                    }
                    for sub in workspace.subtestIDs(entry.suite.importPath, test) {
                        ids.append(TestNodeID.row(entry.suite, test, sub))
                    }
                }
            }
        }
        return ids
    }

    private func moveSelection(by delta: Int, in displayed: [(suite: GoTestSuite, tests: [GoTestFunc])]) {
        let ids = flattenSelectableNodeIDs(in: displayed)
        guard !ids.isEmpty else { return }
        if let current = selection, let idx = ids.firstIndex(of: current) {
            let next = min(max(0, idx + delta), ids.count - 1)
            selection = ids[next]
        } else {
            selection = delta >= 0 ? ids.first : ids.last
        }
    }

    private func selectAndActivateNode(_ id: String) {
        if selection == id {
            jumpToTestNode(id, openPopupIfFailed: true)
        } else {
            selection = id
            if !isNodeFailed(id) && failureForNode(id) == nil {
                jumpToTestNode(id, openPopupIfFailed: false)
            }
        }
    }

    private func jumpToTestNode(_ id: String, openPopupIfFailed: Bool = true) {
        if let failure = failureForNode(id), failure.line >= 1 {
            workspace.jumpToTestFailureAndPresentPopup(
                filePath: failure.file,
                line: failure.line,
                testFailure: failure
            )
            return
        }
        guard let loc = location(for: id) else { return }
        if openPopupIfFailed && isNodeFailed(id) {
            workspace.jumpToTestFailureAndPresentPopup(filePath: loc.file, line: loc.line, testFailure: nil)
        } else {
            workspace.jumpTo(filePath: loc.file, line: loc.line, column: 1)
        }
    }

    private func resolvedNodeInfo(for id: String) -> (suite: GoTestSuite, test: GoTestFunc, subID: String?, file: String, line: Int)? {
        for suite in workspace.testSuites {
            for test in suite.tests {
                if TestNodeID.test(suite, test) == id {
                    return (suite, test, nil, test.file, test.line)
                }
                if let row = test.rows.first(where: { TestNodeID.row(suite, test, $0.id) == id }) {
                    let rowFile = (row.file?.isEmpty == false) ? row.file! : test.file
                    return (suite, test, row.id, rowFile, row.line)
                }
                if let sub = workspace.subtestIDs(suite.importPath, test).first(where: { TestNodeID.row(suite, test, $0) == id }) {
                    return (suite, test, sub, test.file, test.line)
                }
            }
        }
        return nil
    }

    private func isNodeFailed(_ id: String) -> Bool {
        guard let info = resolvedNodeInfo(for: id) else { return false }
        if let subID = info.subID {
            let fullName = info.test.name + "/" + subID
            return workspace.testStatus(info.suite.importPath, fullName) == .failed
        }
        return workspace.effectiveTestStatus(info.suite.importPath, info.test) == .failed
    }

    private func failureForNode(_ id: String) -> TestFailureAnnotation? {
        guard let info = resolvedNodeInfo(for: id) else { return nil }
        let fullName = info.subID.map { "\(info.test.name)/\($0)" } ?? info.test.name
        return workspace.failureAnnotation(
            forTestName: fullName,
            preferredFile: info.file,
            preferredDir: workspace.packageDir(info.suite)
        )
    }

    private var filteredSuites: [(suite: GoTestSuite, tests: [GoTestFunc])] {
        let query = workspace.testFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let failedOnly = workspace.showFailedTestsOnly
        if !failedOnly && query.isEmpty {
            return workspace.testSuites.map { ($0, $0.tests) }
        }
        var result: [(suite: GoTestSuite, tests: [GoTestFunc])] = []
        for suite in workspace.testSuites {
            let suiteMatchesQuery = !query.isEmpty && (
                suite.dir.localizedCaseInsensitiveContains(query) ||
                suite.package.localizedCaseInsensitiveContains(query)
            )
            let matchingTests = suite.tests.filter { test in
                if failedOnly && workspace.effectiveTestStatus(suite.importPath, test) != .failed {
                    return false
                }
                if query.isEmpty || suiteMatchesQuery {
                    return true
                }
                if test.name.localizedCaseInsensitiveContains(query) {
                    return true
                }
                if test.rows.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) {
                    return true
                }
                if workspace.subtestIDs(suite.importPath, test).contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                    return true
                }
                return false
            }
            if !matchingTests.isEmpty {
                result.append((suite: suite, tests: matchingTests))
            }
        }
        return result
    }

    private func location(for id: String) -> (file: String, line: Int)? {
        for suite in workspace.testSuites {
            for test in suite.tests {
                if TestNodeID.test(suite, test) == id { return (test.file, test.line) }
                if let row = test.rows.first(where: { TestNodeID.row(suite, test, $0.id) == id }) {
                    let rowFile = (row.file?.isEmpty == false) ? row.file! : test.file
                    return (rowFile, row.line)
                }
                if workspace.subtestIDs(suite.importPath, test).contains(where: { TestNodeID.row(suite, test, $0) == id }) { return (test.file, test.line) }
            }
        }
        return nil
    }
}

enum TestNodeID {
    static func test(_ suite: GoTestSuite, _ test: GoTestFunc) -> String { "t:\(suite.dir)/\(test.file)/\(test.name)" }
    static func row(_ suite: GoTestSuite, _ test: GoTestFunc, _ row: String) -> String { "r:\(suite.dir)/\(test.file)/\(test.name)/\(row)" }
}

private struct TestNavigatorBar: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        HStack(spacing: Spacing.comfortable) {
            Button { workspace.runAllTests() } label: {
                Label("Run All Tests", systemImage: "play.fill")
            }
            .disabled(workspace.isRunning || workspace.testSuites.isEmpty)
            .help(KeymapStore.shared.labeled("Run All Tests", "product.test"))
            .accessibilityLabel("Run All Tests")

            Button { workspace.rerunFailedTests() } label: {
                Label("Rerun Failed Tests", systemImage: "arrow.clockwise")
            }
            .disabled(workspace.isRunning || !workspace.hasFailedTests)
            .help(KeymapStore.shared.labeled("Rerun Failed Tests", "product.rerunFailed"))
            .accessibilityLabel("Rerun Failed Tests")

            Button { workspace.runTestsWithCoverage() } label: {
                Label("Run Tests with Coverage", systemImage: "checkmark.shield")
            }
            .foregroundStyle(workspace.hasCoverageData ? ThemeColor.accent : ChromeColor.textSecondary)
            .disabled(workspace.isRunning || workspace.testSuites.isEmpty)
            .help(KeymapStore.shared.labeled("Run All Tests with Coverage", "product.coverage"))
            .accessibilityLabel("Run Tests with Coverage")

            if workspace.isTestRunning {
                Button { workspace.stopTests() } label: {
                    Label("Stop Testing", systemImage: "stop.fill")
                }
                .foregroundStyle(StatusTone.failure.tint)
                .help(KeymapStore.shared.labeled("Stop Testing", "product.stop"))
                .accessibilityLabel("Stop Testing")
            }

            Spacer()

            Menu {
                Button {
                    workspace.profileAllTests()
                } label: {
                    Label("Profile Tests", systemImage: "gauge.with.dots.needle.67percent")
                }
                .disabled(workspace.isRunning || workspace.testSuites.isEmpty)

                if workspace.hasProfileData {
                    Button {
                        workspace.clearProfile()
                    } label: {
                        Label("Clear Profile", systemImage: "trash")
                    }
                }

                if workspace.hasCoverageData {
                    Button {
                        workspace.clearCoverage()
                    } label: {
                        Label("Clear Coverage", systemImage: "xmark.shield")
                    }
                }

                Divider()

                Button {
                    workspace.presentBenchmarkComparisonSheet()
                } label: {
                    Label("Compare Benchmarks with Baseline…", systemImage: "chart.bar.xaxis")
                }

                if !workspace.benchMetrics.isEmpty {
                    Button {
                        workspace.pinCurrentBenchmarksAsBaseline()
                    } label: {
                        Label("Pin Benchmark Baseline", systemImage: workspace.hasBenchmarkBaseline ? "pin.fill" : "pin")
                    }
                }

                if workspace.hasBenchmarkBaseline {
                    Button {
                        workspace.clearBenchmarkBaseline()
                    } label: {
                        Label("Clear Benchmark Baseline", systemImage: "pin.slash")
                    }
                }

                Divider()

                Button {
                    workspace.expandAllTestSuites()
                } label: {
                    Label("Expand All Packages", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(workspace.testSuites.isEmpty || workspace.collapsedTestSuiteIDs.isEmpty)

                Button {
                    workspace.collapseAllTestSuites()
                } label: {
                    Label("Collapse All Packages", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(workspace.testSuites.isEmpty)

                Divider()

                Button {
                    workspace.loadWorkspaceTests()
                } label: {
                    Label("Refresh Tests", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
                    .foregroundStyle(ChromeColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Test Actions")
            .accessibilityLabel("More Test Actions")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }
}

private struct TestSummaryBar: View {
    @Bindable var workspace: WorkspaceState
    let summary: TestSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.comfortable) {
                Label {
                    Text("\(summary.passed) passed")
                } icon: {
                    Image(systemName: StatusTone.success.symbol).foregroundStyle(summary.passed > 0 ? StatusTone.success.tint : ChromeColor.textSecondary)
                }
                if summary.failed > 0 || workspace.showFailedTestsOnly {
                    Button {
                        workspace.showFailedTestsOnly.toggle()
                        if workspace.showFailedTestsOnly {
                            for suite in workspace.testSuites where workspace.suiteAggregateStatus(for: suite).failedCount > 0 {
                                workspace.collapsedTestSuiteIDs.remove(suite.id)
                            }
                        }
                    } label: {
                        Label {
                            Text("\(summary.failed) failed")
                                .underline(workspace.showFailedTestsOnly)
                        } icon: {
                            Image(systemName: StatusTone.failure.symbol).foregroundStyle(summary.failed > 0 ? StatusTone.failure.tint : ChromeColor.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(workspace.showFailedTestsOnly ? "Showing failed tests only — click to show all" : "Click to filter tree to failed tests only")
                    .accessibilityLabel("Filter to \(summary.failed) Failed Tests")
                } else {
                    Label {
                        Text("\(summary.failed) failed")
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(ChromeColor.textSecondary)
                    }
                }
                if summary.skipped > 0 {
                    Label("\(summary.skipped) skipped", systemImage: "minus.circle")
                        .foregroundStyle(ChromeColor.textSecondary)
                }
                Spacer()
            }
            .lineLimit(1)
            if summary.failed > 0 {
                HStack(spacing: Spacing.standard) {
                    Text("Select a failed test to jump to its assertion.")
                        .foregroundStyle(ChromeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Rerun Failed") { workspace.rerunFailedTests() }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(workspace.isRunning)
                        .help("Run only the tests that failed")
                }
            }
        }
        .font(.subheadline)
        .labelStyle(TestSummaryLabelStyle())
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
        .accessibilityElement(children: .contain)
    }
}

private struct TestSummaryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.compact) {
            configuration.icon
            configuration.title.foregroundStyle(ChromeColor.textSecondary)
        }
    }
}

private struct TestSuiteNode: View {
    @Bindable var workspace: WorkspaceState
    let suite: GoTestSuite
    var filteredTests: [GoTestFunc]? = nil
    var selectedNodeID: String? = nil
    var onActivateNode: ((String) -> Void)? = nil

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                if workspace.showFailedTestsOnly || !workspace.testFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return !workspace.collapsedTestSuiteIDs.contains(suite.id)
            },
            set: { newValue in
                if newValue {
                    workspace.collapsedTestSuiteIDs.remove(suite.id)
                } else {
                    workspace.collapsedTestSuiteIDs.insert(suite.id)
                    let suitePrefix = "t:\(suite.dir)/"
                    workspace.expandedTestFuncIDs = workspace.expandedTestFuncIDs.filter { !$0.hasPrefix(suitePrefix) }
                }
            }
        )
    }

    private var suiteDuration: Double? {
        guard !workspace.testDurations.isEmpty else { return nil }
        var sum = 0.0
        var any = false
        for test in suite.tests {
            let key = workspace.testKey(suite.importPath, test.name)
            if let elapsed = workspace.testDurations[key] {
                sum += elapsed
                any = true
            }
        }
        return any ? sum : nil
    }

    var body: some View {
        let agg = workspace.suiteAggregateStatus(for: suite)
        let testsToShow = filteredTests ?? suite.tests
        DisclosureGroup(isExpanded: isExpandedBinding) {
            ForEach(testsToShow) { test in
                TestFunctionNode(
                    workspace: workspace,
                    suite: suite,
                    test: test,
                    selectedNodeID: selectedNodeID,
                    onActivateNode: onActivateNode
                )
            }
        } label: {
            TestRowLabel(
                title: suite.dir == "." ? suite.package : suite.dir,
                systemImage: "shippingbox",
                status: agg.status == .none ? nil : agg.status,
                failedCount: agg.failedCount,
                coverage: workspace.packageCoverage[suite.importPath],
                durationSeconds: suiteDuration,
                isRowSelected: false,
                runTitle: "Run Tests in \(suite.package)",
                run: {
                    workspace.runTests(suite: suite)
                },
                runWithCoverage: {
                    workspace.runTests(suite: suite, cover: true)
                },
                runBenchmarks: {
                    workspace.runBenchmarks(suite: suite)
                },
                profile: {
                    workspace.runTests(suite: suite, profile: true)
                },
                profileTitle: "Profile Tests",
                debug: nil,
                expandAll: {
                    workspace.expandAllTestSuites()
                },
                collapseAll: {
                    workspace.collapseAllTestSuites()
                }
            )
        }
    }
}

private struct TestFunctionNode: View {
    @Bindable var workspace: WorkspaceState
    let suite: GoTestSuite
    let test: GoTestFunc
    var selectedNodeID: String? = nil
    var onActivateNode: ((String) -> Void)? = nil

    private var nodeID: String {
        TestNodeID.test(suite, test)
    }

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                if workspace.showFailedTestsOnly && workspace.effectiveTestStatus(suite.importPath, test) == .failed {
                    return true
                }
                return workspace.expandedTestFuncIDs.contains(nodeID)
            },
            set: { newValue in
                if newValue {
                    workspace.expandedTestFuncIDs.insert(nodeID)
                } else {
                    workspace.expandedTestFuncIDs.remove(nodeID)
                }
            }
        )
    }

    var body: some View {
        let subtests = workspace.subtestIDs(suite.importPath, test)
        if test.rows.isEmpty && subtests.isEmpty {
            label.tag(nodeID)
        } else {
            DisclosureGroup(isExpanded: isExpandedBinding) {
                ForEach(test.rows) { row in
                    rowLabel(row.name, id: row.id)
                }
                ForEach(subtests, id: \.self) { sub in
                    rowLabel(sub, id: sub)
                }
            } label: {
                label
            }
            .tag(nodeID)
        }
    }

    private var label: some View {
        let target = workspace.testTarget(suite, test)
        let key = workspace.testKey(suite.importPath, test.name)
        let benchMetric = workspace.benchMetrics.isEmpty ? nil : workspace.benchMetrics[key]
        let benchDelta = (benchMetric != nil && !workspace.benchmarkDiffItems.isEmpty)
            ? workspace.benchmarkDeltaText(importPath: suite.importPath, name: test.name)
            : nil
        let durationSeconds = workspace.testDurations[key]
        let fuzzAction: (() -> Void)? = test.name.hasPrefix("Fuzz") ? {
            workspace.runTests(target, fuzz: true)
        } : nil
        let failure = workspace.failureAnnotation(
            forTestName: test.name,
            preferredFile: test.file,
            preferredDir: workspace.packageDir(suite)
        )
        return TestRowLabel(
            title: test.name,
            systemImage: nil,
            status: workspace.effectiveTestStatus(suite.importPath, test),
            benchMetric: benchMetric,
            benchDelta: benchDelta,
            durationSeconds: durationSeconds,
            isRowSelected: selectedNodeID == nodeID,
            runTitle: "Run \(test.name)",
            run: {
                workspace.runTests(target)
            },
            onPrimaryClick: onActivateNode.map { act in { act(nodeID) } },
            jumpToFailure: failure.map { ann in
                {
                    workspace.jumpToTestFailureAndPresentPopup(
                        filePath: ann.file,
                        line: ann.line,
                        testFailure: ann
                    )
                }
            },
            jumpToSource: {
                workspace.jumpTo(filePath: test.file, line: test.line, column: 1)
            },
            fuzz: fuzzAction,
            profile: {
                workspace.runTests(target, profile: true)
            },
            profileTitle: test.name.hasPrefix("Benchmark") ? "Profile Benchmark" : "Profile Test",
            debug: {
                workspace.debugProject(test: target)
            }
        )
    }

    private func rowLabel(_ title: String, id: String) -> some View {
        let target = workspace.testTarget(suite, test, row: id)
        let fullName = test.name + "/" + id
        let rowKey = workspace.testKey(suite.importPath, fullName)
        let benchMetric = workspace.benchMetrics.isEmpty ? nil : workspace.benchMetrics[rowKey]
        let benchDelta = (benchMetric != nil && !workspace.benchmarkDiffItems.isEmpty)
            ? workspace.benchmarkDeltaText(importPath: suite.importPath, name: fullName)
            : nil
        let durationSeconds = workspace.testDurations[rowKey]
        let rowNodeID = TestNodeID.row(suite, test, id)
        let rowLocation: (file: String, line: Int) = {
            if let row = test.rows.first(where: { $0.id == id }) {
                let f = (row.file?.isEmpty == false) ? row.file! : test.file
                return (f, row.line)
            }
            return (test.file, test.line)
        }()
        let failure = workspace.failureAnnotation(
            forTestName: fullName,
            preferredFile: rowLocation.file,
            preferredDir: workspace.packageDir(suite)
        )
        return TestRowLabel(
            title: title,
            systemImage: nil,
            status: workspace.testResults.isEmpty ? TestStatus.none : workspace.testStatus(suite.importPath, fullName),
            benchMetric: benchMetric,
            benchDelta: benchDelta,
            durationSeconds: durationSeconds,
            isRowSelected: selectedNodeID == rowNodeID,
            runTitle: "Run \(title)",
            run: {
                workspace.runTests(target)
            },
            onPrimaryClick: onActivateNode.map { act in { act(rowNodeID) } },
            jumpToFailure: failure.map { ann in
                {
                    workspace.jumpToTestFailureAndPresentPopup(
                        filePath: ann.file,
                        line: ann.line,
                        testFailure: ann
                    )
                }
            },
            jumpToSource: {
                workspace.jumpTo(filePath: rowLocation.file, line: rowLocation.line, column: 1)
            },
            profile: {
                workspace.runTests(target, profile: true)
            },
            profileTitle: test.name.hasPrefix("Benchmark") ? "Profile Benchmark" : "Profile Test",
            debug: {
                workspace.debugProject(test: target)
            }
        )
        .tag(rowNodeID)
    }
}

private struct TestRowLabel: View {
    @Environment(\.windowWorkspace) private var workspace
    let title: String
    let systemImage: String?
    let status: TestStatus?
    var failedCount: Int = 0
    var coverage: Double? = nil
    var benchMetric: String? = nil
    var benchDelta: (text: String, isImproved: Bool, isRegressed: Bool)? = nil
    var durationSeconds: Double? = nil
    var isRowSelected: Bool = false
    let runTitle: String
    let run: () -> Void
    var onPrimaryClick: (() -> Void)? = nil
    var jumpToFailure: (() -> Void)? = nil
    var jumpToSource: (() -> Void)? = nil
    var runWithCoverage: (() -> Void)? = nil
    var runBenchmarks: (() -> Void)? = nil
    var fuzz: (() -> Void)? = nil
    var profile: (() -> Void)? = nil
    var profileTitle: String = "Profile Test"
    let debug: (() -> Void)?
    var expandAll: (() -> Void)? = nil
    var collapseAll: (() -> Void)? = nil
    @State private var hovered = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    private var isActiveRow: Bool {
        isRowSelected || prominence == .increased || hovered
    }

    var body: some View {
        let isRunning = workspace.isRunning
        HStack(spacing: Spacing.row) {
            if let onPrimaryClick {
                Button(action: onPrimaryClick) {
                    HStack(spacing: Spacing.row) {
                        if let systemImage {
                            Image(systemName: systemImage).foregroundStyle(ChromeColor.textSecondary)
                        }
                        if let status {
                            TestStatusIcon(status: status)
                        }
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(nameStyle)
                        Spacer(minLength: Spacing.compact)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(status.map(TestStatusIcon.label) ?? "")
                .accessibilityAction(named: runTitle, run)
            } else {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(ChromeColor.textSecondary)
                }
                if let status {
                    TestStatusIcon(status: status)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameStyle)
                Spacer(minLength: Spacing.compact)
            }
            if failedCount > 0 {
                Text("\(failedCount) failed")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(StatusTone.failure.tint)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(StatusTone.failure.fill)
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .help("\(failedCount) failed test\(failedCount == 1 ? "" : "s") in \(title)")
            }
            if let metric = benchMetric {
                let primaryMetric = metric.components(separatedBy: " · ").first ?? metric
                Text(primaryMetric)
                    .font(.caption.monospaced())
                    .foregroundStyle(ChromeColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(metric)
                if let delta = benchDelta {
                    Text(delta.text)
                        .font(.caption.weight(.medium).monospaced())
                        .foregroundStyle(delta.isImproved ? StatusTone.success.tint : (delta.isRegressed ? StatusTone.failure.tint : ChromeColor.textSecondary))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if let coverage {
                Text(String(format: "%.0f%%", coverage))
                    .font(TechnicalTypography.metricMono)
                    .foregroundStyle(ChromeColor.textSecondary)
            }
            if let durationSeconds, benchMetric == nil {
                Text(UserMessage.duration(durationSeconds))
                    .font(TechnicalTypography.metricMono)
                    .foregroundStyle(prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : ChromeColor.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !isRunning {
                Button(action: run) {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(
                            prominence == .increased
                                ? Color(nsColor: .alternateSelectedControlTextColor)
                                : (isActiveRow ? ThemeColor.accent : ChromeColor.textTertiary)
                        )
                }
                .buttonStyle(.borderless)
                .help(runTitle)
                .accessibilityLabel(runTitle)

                if isActiveRow, let debugAction = debug {
                    Button(action: debugAction) {
                        Image(systemName: "ladybug.fill")
                            .font(.caption2)
                            .foregroundStyle(
                                prominence == .increased
                                    ? Color(nsColor: .alternateSelectedControlTextColor)
                                    : ChromeColor.textSecondary
                            )
                    }
                    .buttonStyle(.borderless)
                    .help("Debug \(title)")
                    .accessibilityLabel("Debug \(title)")
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            if let jumpToFailure {
                Button("Jump to Failure", systemImage: StatusTone.failure.symbol, action: jumpToFailure)
            }
            if let jumpToSource {
                Button("Jump to Declaration", systemImage: "text.cursor", action: jumpToSource)
            }
            if jumpToFailure != nil || jumpToSource != nil {
                Divider()
            }
            Button(runTitle, systemImage: "play.fill", action: run).disabled(isRunning)
            if let runWithCoverage {
                Button("Run Tests with Coverage", systemImage: "checkmark.shield", action: runWithCoverage).disabled(isRunning)
            }
            if let runBenchmarks {
                Button("Run Benchmarks", systemImage: "stopwatch") { runBenchmarks() }.disabled(isRunning)
            }
            if let fuzz {
                Button("Fuzz Test (5s)", systemImage: "sparkles", action: fuzz).disabled(isRunning)
            }
            if let profile {
                Button(profileTitle, systemImage: "gauge.with.dots.needle.67percent", action: profile).disabled(isRunning)
            }
            if let debugAction = debug {
                Button("Debug \(title)", systemImage: "ladybug.fill", action: debugAction).disabled(isRunning)
            }
            if expandAll != nil || collapseAll != nil {
                Divider()
                if let expandAll {
                    Button("Expand All Packages", systemImage: "arrow.up.left.and.arrow.down.right", action: expandAll)
                }
                if let collapseAll {
                    Button("Collapse All Packages", systemImage: "arrow.down.right.and.arrow.up.left", action: collapseAll)
                }
            }
        }
        .accessibilityElement(children: onPrimaryClick == nil ? .combine : .contain)
        .accessibilityValue(onPrimaryClick == nil ? (status.map(TestStatusIcon.label) ?? "") : "")
        .accessibilityAction(named: runTitle, run)
    }

    private var nameStyle: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) }
        return AnyShapeStyle(ThemeColor.textPrimary)
    }
}

struct TestStatusIcon: View {
    let status: TestStatus

    static func label(_ status: TestStatus) -> String {
        switch status {
        case .none: return "Not run"
        case .running: return "Running"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }

    var body: some View {
        Group {
            switch status {
            case .none:
                Image(systemName: "circle").foregroundStyle(ChromeColor.textSecondary)
            case .running:
                ProgressView().controlSize(.mini)
            case .passed:
                Image(systemName: StatusTone.success.symbol).rowTint(StatusTone.success.tint)
            case .failed:
                Image(systemName: StatusTone.failure.symbol).rowTint(StatusTone.failure.tint)
            case .skipped:
                Image(systemName: StatusTone.inactive.symbol).foregroundStyle(ChromeColor.textSecondary)
            }
        }
        .frame(width: 14, height: 14)
        .help(Self.label(status))
    }
}
