import AppKit
import Foundation
import GoLensFoundation
import Observation
import SwiftUI

enum UnifiedDiagnosticSource: String, CaseIterable, Hashable, Sendable {
    case compilerOrLSP
    case linter
    case database
    case safety
    case complexity
    case dependencyCycle
    case todo
    case bookmark
    case breakpoint

    var badgeLabel: String {
        switch self {
        case .compilerOrLSP: "Go / LSP"
        case .linter: "Lint"
        case .database: "SQL"
        case .safety: "Safety"
        case .complexity: "Complexity"
        case .dependencyCycle: "Cycle"
        case .todo: "TODO"
        case .bookmark: "Bookmark"
        case .breakpoint: "Breakpoint"
        }
    }
}

enum DiagnosticsNavigatorScope: String, CaseIterable, Identifiable {
    case all = "All"
    case errors = "Errors"
    case warnings = "Warnings"
    case safety = "Safety"
    case todos = "TODOs"
    case bookmarks = "Bookmarks"
    case breakpoints = "Breakpoints"

    var id: String { rawValue }

    var itemNoun: String {
        switch self {
        case .all: "Issues"
        case .errors: "Errors"
        case .warnings: "Warnings"
        case .safety: "Safety Findings"
        case .todos: "TODOs"
        case .bookmarks: "Bookmarks"
        case .breakpoints: "Breakpoints"
        }
    }
}

enum UnifiedDiagnosticQuickFix: Equatable {
    case codeActions(path: String, line: Int, column: Int)
    case inspectComplexity(path: String, line: Int)
    case openPackageGraph
    case removeBookmark(item: BookmarkItem)
    case deleteBreakpoint(BreakpointRef)

    var buttonTitle: String {
        switch self {
        case .codeActions: "Quick Fix"
        case .inspectComplexity: "Inspect"
        case .openPackageGraph: "Graph"
        case .removeBookmark: "Remove"
        case .deleteBreakpoint: "Delete"
        }
    }

    var helpText: String {
        switch self {
        case .codeActions: "Show Quick Fixes & Code Actions"
        case .inspectComplexity: "Open Function Complexity Inspector"
        case .openPackageGraph: "Open Package Dependency Graph"
        case .removeBookmark: "Remove Bookmark"
        case .deleteBreakpoint: "Delete Breakpoint"
        }
    }

    var symbolName: String {
        switch self {
        case .codeActions: "wand.and.stars"
        case .inspectComplexity: "gauge.with.dots.needle.67percent"
        case .openPackageGraph: "point.3.connected.trianglepath.dotted"
        case .removeBookmark: "bookmark.slash"
        case .deleteBreakpoint: "trash"
        }
    }
}

struct UnifiedDiagnosticItem: Identifiable, Equatable {
    let id: String
    let source: UnifiedDiagnosticSource
    let severity: Int
    let title: String
    let detail: String?
    let path: String
    let relativePath: String
    let line: Int
    let column: Int
    let badgeLabel: String?
    let quickFix: UnifiedDiagnosticQuickFix?
    var breakpoint: BreakpointRef? = nil
    var isEnabled = true
    var hasProblem = false

    var isRemovable: Bool {
        switch quickFix {
        case .removeBookmark, .deleteBreakpoint: true
        default: false
        }
    }

    var tint: Color {
        source == .breakpoint && isEnabled && !hasProblem ? ThemeColor.accent : tone.tint
    }

    var tone: StatusTone {
        switch source {
        case .breakpoint:
            if hasProblem { return .warning }
            return isEnabled ? .info : .inactive
        case .bookmark:
            return .info
        case .todo:
            return severity <= 2 ? .warning : .info
        default:
            if severity == 1 { return .failure }
            if severity == 2 { return .warning }
            return .info
        }
    }

    var symbolName: String {
        switch source {
        case .breakpoint:
            if hasProblem { return StatusTone.warning.symbol }
            return isEnabled ? "arrowshape.right.fill" : "arrowshape.right"
        case .bookmark:
            return "bookmark.fill"
        case .todo:
            return severity <= 2 ? StatusTone.warning.symbol : "checklist"
        case .safety:
            return severity == 1 ? StatusTone.failure.symbol : "shield.lefthalf.filled"
        case .complexity:
            return "gauge.with.dots.needle.67percent"
        case .dependencyCycle:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .compilerOrLSP, .linter, .database:
            if severity == 1 { return StatusTone.failure.symbol }
            if severity == 2 { return StatusTone.warning.symbol }
            return StatusTone.info.symbol
        }
    }
}

@Observable
final class DiagnosticsCenter {
    var scope: DiagnosticsNavigatorScope = .all
    var filterQuery: String = ""
    private(set) var complexityItems: [FunctionComplexityItem] = []
    private(set) var dependencyCycles: [ImportCycleDTO] = []
    private(set) var isRefreshingStaticChecks: Bool = false

    @ObservationIgnored private var lastRefreshedWorkspace: String = ""
    @ObservationIgnored private var lastRefreshTimestamp: TimeInterval = 0
    @ObservationIgnored private var lastDependencyRefreshWorkspace: String = ""
    @ObservationIgnored private var lastDependencyRefreshTimestamp: TimeInterval = 0
    @ObservationIgnored private var refreshGeneration: Int = 0
    @ObservationIgnored private var saveRefreshGeneration: Int = 0
    @ObservationIgnored private var saveChecksWorkItem: DispatchWorkItem?
    @ObservationIgnored private var pendingSavedPaths: Set<String> = []
    @ObservationIgnored private let checksQueue = DispatchQueue(label: "dev.golens.diagnostics-checks", qos: .utility)

    func syncWithLegacySubtab(_ subtab: IssuesNavigatorSubtab) {
        switch subtab {
        case .issues:
            if scope == .todos || scope == .bookmarks || scope == .breakpoints {
                scope = .all
            }
        case .todos:
            if scope != .todos {
                scope = .todos
            }
        case .bookmarks:
            if scope != .bookmarks {
                scope = .bookmarks
            }
        case .breakpoints:
            if scope != .breakpoints {
                scope = .breakpoints
            }
        }
    }

    func selectScope(_ nextScope: DiagnosticsNavigatorScope, in workspace: WorkspaceState) {
        scope = nextScope
        switch nextScope {
        case .todos:
            if workspace.selectedIssuesNavigatorSubtab != .todos {
                workspace.selectedIssuesNavigatorSubtab = .todos
            }
        case .bookmarks:
            if workspace.selectedIssuesNavigatorSubtab != .bookmarks {
                workspace.selectedIssuesNavigatorSubtab = .bookmarks
            }
        case .breakpoints:
            if workspace.selectedIssuesNavigatorSubtab != .breakpoints {
                workspace.selectedIssuesNavigatorSubtab = .breakpoints
            }
        case .all, .errors, .warnings, .safety:
            if workspace.selectedIssuesNavigatorSubtab != .issues {
                workspace.selectedIssuesNavigatorSubtab = .issues
            }
        }
    }

    func resetFilters(in workspace: WorkspaceState) {
        filterQuery = ""
        selectScope(.all, in: workspace)
    }

    func refreshWorkspaceChecksIfNeeded(for workspace: WorkspaceState, force: Bool = false) {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else {
            saveChecksWorkItem?.cancel()
            saveChecksWorkItem = nil
            pendingSavedPaths.removeAll()
            complexityItems = []
            dependencyCycles = []
            lastRefreshedWorkspace = ""
            lastDependencyRefreshWorkspace = ""
            isRefreshingStaticChecks = false
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if !force && DiagnosticsCenterRules.shouldThrottleWorkspaceRefresh(
            activeWorkspace: root,
            lastWorkspace: lastRefreshedWorkspace,
            now: now,
            lastTimestamp: lastRefreshTimestamp,
            cooldown: DiagnosticsCenterRules.onAppearWorkspaceCooldown
        ) {
            return
        }
        if lastRefreshedWorkspace != root {
            saveChecksWorkItem?.cancel()
            saveChecksWorkItem = nil
            pendingSavedPaths.removeAll()
        }
        lastRefreshedWorkspace = root
        lastRefreshTimestamp = now
        lastDependencyRefreshWorkspace = root
        lastDependencyRefreshTimestamp = now
        refreshGeneration &+= 1
        let gen = refreshGeneration
        isRefreshingStaticChecks = true

        let group = DispatchGroup()
        var nextComplexity: [FunctionComplexityItem] = []
        var nextCycles: [ImportCycleDTO] = []

        group.enter()
        workspace.inspectFunctionComplexity(includeWorkspace: true) { report in
            nextComplexity = report.functions.filter {
                DiagnosticsCenterRules.shouldIncludeComplexityInIssues(rating: $0.rating)
            }
            group.leave()
        }

        group.enter()
        workspace.inspectWorkspacePackageDependencies { report in
            nextCycles = report.cycles
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.refreshGeneration == gen, workspace.activeWorkspacePath == root else { return }
            self.complexityItems = nextComplexity
            self.dependencyCycles = nextCycles
            self.isRefreshingStaticChecks = false
        }
    }

    func scheduleChecksAfterSave(for workspace: WorkspaceState, savedFilePath: String) {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty, savedFilePath.hasSuffix(".go") else { return }
        if lastRefreshedWorkspace != root && !lastRefreshedWorkspace.isEmpty {
            pendingSavedPaths.removeAll()
        }
        pendingSavedPaths.insert(savedFilePath)
        saveChecksWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak workspace] in
            guard let self, let workspace, workspace.activeWorkspacePath == root else { return }
            self.saveChecksWorkItem = nil
            let paths = Array(self.pendingSavedPaths)
            self.pendingSavedPaths.removeAll()
            guard !paths.isEmpty else { return }

            let inputs: [(canonicalPath: String, input: WorkspaceState.ActiveInspectionInput)] = paths.map { path in
                let source: String
                if let tv = workspace.activeTextView as? GoLensTextView, tv.filePath == path {
                    source = tv.string
                } else if let session = workspace.documents[path] {
                    source = session.storage.string
                } else if let disk = try? String(contentsOfFile: path, encoding: .utf8) {
                    source = disk
                } else {
                    source = ""
                }
                return (
                    WorkspaceState.canonicalPath(path),
                    WorkspaceState.ActiveInspectionInput(workspacePath: root, filePath: path, source: source)
                )
            }

            let now = Date().timeIntervalSinceReferenceDate
            let shouldRefreshDeps = !DiagnosticsCenterRules.shouldThrottleWorkspaceRefresh(
                activeWorkspace: root,
                lastWorkspace: self.lastDependencyRefreshWorkspace,
                now: now,
                lastTimestamp: self.lastDependencyRefreshTimestamp,
                cooldown: DiagnosticsCenterRules.saveWorkspaceCooldown
            )
            if shouldRefreshDeps {
                self.lastDependencyRefreshWorkspace = root
                self.lastDependencyRefreshTimestamp = now
            }

            self.saveRefreshGeneration &+= 1
            let gen = self.saveRefreshGeneration
            self.checksQueue.async { [weak self, weak workspace] in
                var updatedByFile: [String: [FunctionComplexityItem]] = [:]
                for entry in inputs {
                    let report = WorkspaceState.computeFunctionComplexity(entry.input, includeWorkspace: false)
                    updatedByFile[entry.canonicalPath] = report.functions.filter {
                        DiagnosticsCenterRules.shouldIncludeComplexityInIssues(rating: $0.rating)
                    }
                }
                let updatedDeps = shouldRefreshDeps ? WorkspaceState.computePackageDependencies(dirPath: root) : nil

                DispatchQueue.main.async {
                    guard let self,
                          let workspace,
                          self.saveRefreshGeneration == gen,
                          workspace.activeWorkspacePath == root else { return }
                    let replacedPaths = Set(updatedByFile.keys)
                    var merged = self.complexityItems.filter {
                        !replacedPaths.contains(WorkspaceState.canonicalPath($0.file))
                    }
                    for items in updatedByFile.values {
                        merged.append(contentsOf: items)
                    }
                    merged.sort {
                        if $0.cognitive != $1.cognitive { return $0.cognitive > $1.cognitive }
                        if $0.cyclomatic != $1.cyclomatic { return $0.cyclomatic > $1.cyclomatic }
                        return $0.line < $1.line
                    }
                    self.complexityItems = merged
                    if let updatedDeps {
                        self.dependencyCycles = updatedDeps.cycles
                    }
                }
            }
        }
        saveChecksWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    func allItems(in workspace: WorkspaceState) -> [UnifiedDiagnosticItem] {
        var result: [UnifiedDiagnosticItem] = []
        let root = workspace.activeWorkspacePath

        func makeRelative(_ fullPath: String) -> String {
            guard !fullPath.isEmpty else { return "Workspace" }
            let rel = workspace.projectRelativePath(fullPath)
            return rel.isEmpty ? (fullPath as NSString).lastPathComponent : rel
        }

        var seenSafetyKeys = Set<String>()

        for flat in workspace.flatDiagnostics {
            let path = flat.path
            let diag = flat.diag
            let source: UnifiedDiagnosticSource = {
                if let safetyList = workspace.safetyDiagnostics[path], safetyList.contains(diag) {
                    return .safety
                }
                if let src = diag.source?.lowercased(), src.contains("safety") || src == "govulncheck" || src == "deadcode" {
                    return .safety
                }
                if let lintList = workspace.lintDiagnostics[path], lintList.contains(diag) {
                    return .linter
                }
                if let src = diag.source?.lowercased(), src.contains("golangci") || src.contains("lint") {
                    return .linter
                }
                if diag.source == WorkspaceState.sqlDiagnosticSource {
                    return .database
                }
                return .compilerOrLSP
            }()

            let line1 = max(1, diag.line + 1)
            let col1 = max(1, diag.col + 1)
            if source == .safety {
                seenSafetyKeys.insert("\(WorkspaceState.canonicalPath(path)):\(line1):\(diag.message)")
            }
            let canQuickFix = path.hasSuffix(".go") || (path as NSString).lastPathComponent.hasPrefix("Dockerfile")
            result.append(UnifiedDiagnosticItem(
                id: "diag:\(path):\(line1):\(col1):\(diag.severity):\(diag.source ?? ""):\(diag.code ?? ""):\(diag.message)",
                source: source,
                severity: diag.severity,
                title: diag.message,
                detail: nil,
                path: path,
                relativePath: makeRelative(path),
                line: line1,
                column: col1,
                badgeLabel: diag.sourceLabel ?? source.badgeLabel,
                quickFix: canQuickFix ? .codeActions(path: path, line: line1, column: col1) : nil
            ))
        }

        for finding in workspace.safetyFindings {
            let resolvedPath: String = {
                if !finding.file.isEmpty {
                    if finding.file.hasPrefix("/") {
                        return finding.file
                    }
                    if !root.isEmpty {
                        return (root as NSString).appendingPathComponent(finding.file)
                    }
                    return finding.file
                }
                if !root.isEmpty {
                    let gomod = (root as NSString).appendingPathComponent("go.mod")
                    if FileManager.default.fileExists(atPath: gomod) {
                        return gomod
                    }
                    return root
                }
                return ""
            }()
            let line1 = max(1, finding.line)
            let dedupKey = "\(WorkspaceState.canonicalPath(resolvedPath)):\(line1):\(finding.title)"
            if seenSafetyKeys.contains(dedupKey) {
                continue
            }
            let canQuickFix = resolvedPath.hasSuffix(".go") && finding.line > 0
            let rel = finding.relFile.isEmpty ? (finding.file.isEmpty ? "go.mod" : makeRelative(resolvedPath)) : finding.relFile
            result.append(UnifiedDiagnosticItem(
                id: "safety:\(finding.id):\(resolvedPath):\(line1)",
                source: .safety,
                severity: max(1, min(3, finding.severity)),
                title: finding.title,
                detail: finding.detail.isEmpty ? nil : finding.detail,
                path: resolvedPath,
                relativePath: rel,
                line: line1,
                column: max(1, finding.col),
                badgeLabel: finding.kind.isEmpty ? "Safety" : finding.kind.uppercased(),
                quickFix: canQuickFix ? .codeActions(path: resolvedPath, line: line1, column: max(1, finding.col)) : nil
            ))
        }

        for cycle in dependencyCycles {
            let firstEdge = cycle.edges.first
            let path = firstEdge?.filePath ?? (root.isEmpty ? "" : (root as NSString).appendingPathComponent("go.mod"))
            let line1 = max(1, firstEdge?.line ?? 1)
            let chainText = cycle.chain.joined(separator: " -> ")
            result.append(UnifiedDiagnosticItem(
                id: "cycle:\(cycle.id)",
                source: .dependencyCycle,
                severity: 1,
                title: "Import cycle: \(chainText)",
                detail: firstEdge.map { "\($0.fromPkg) imports \($0.toPkg)" },
                path: path,
                relativePath: path.isEmpty ? "Workspace" : makeRelative(path),
                line: line1,
                column: 1,
                badgeLabel: "Cycle",
                quickFix: .openPackageGraph
            ))
        }

        for item in complexityItems {
            let isHigh = item.rating == "high"
            let sev = isHigh ? 2 : 3
            result.append(UnifiedDiagnosticItem(
                id: "complexity:\(item.id)",
                source: .complexity,
                severity: sev,
                title: "\(item.name) — cognitive complexity \(item.cognitive) (cyclomatic \(item.cyclomatic))",
                detail: item.suggestion.isEmpty ? nil : item.suggestion,
                path: item.file,
                relativePath: item.relFile.isEmpty ? makeRelative(item.file) : item.relFile,
                line: max(1, item.line),
                column: 1,
                badgeLabel: isHigh ? "High Complexity" : "Complexity",
                quickFix: .inspectComplexity(path: item.file, line: max(1, item.line))
            ))
        }

        for todo in workspace.workspaceTodos {
            let sev = (todo.tag == .fixme || todo.tag == .hack) ? 2 : 3
            let title = todo.text.isEmpty ? todo.tag.rawValue : todo.text
            result.append(UnifiedDiagnosticItem(
                id: "todo:\(todo.id)",
                source: .todo,
                severity: sev,
                title: title,
                detail: nil,
                path: todo.path,
                relativePath: makeRelative(todo.path),
                line: max(1, todo.line),
                column: max(1, todo.column),
                badgeLabel: todo.tag.rawValue,
                quickFix: nil
            ))
        }

        for bm in workspace.bookmarks {
            let title = bm.preview.isEmpty ? "Line \(bm.line)" : bm.preview
            result.append(UnifiedDiagnosticItem(
                id: "bookmark:\(bm.id)",
                source: .bookmark,
                severity: 4,
                title: title,
                detail: nil,
                path: bm.path,
                relativePath: makeRelative(bm.path),
                line: max(1, bm.line),
                column: 1,
                badgeLabel: "Bookmark",
                quickFix: .removeBookmark(item: bm)
            ))
        }

        let debug = workspace.debug
        for path in debug.breakpoints.keys.sorted() {
            for line in (debug.breakpoints[path] ?? []).sorted() {
                let spec = debug.spec(path, line)
                let ref = BreakpointRef.line(path: path, line: line)
                let details = [
                    spec.condition.isEmpty ? nil : "Condition: \(spec.condition)",
                    spec.hitCondition.isEmpty ? nil : "Hit count: \(spec.hitCondition)",
                    spec.logMessage.isEmpty ? nil : "Log message: \(spec.logMessage)",
                ].compactMap { $0 }
                result.append(UnifiedDiagnosticItem(
                    id: "breakpoint:\(path):\(line)",
                    source: .breakpoint,
                    severity: 4,
                    title: workspace.extractLinePreview(forPath: path, line: line),
                    detail: details.isEmpty ? nil : details.joined(separator: " · "),
                    path: path,
                    relativePath: makeRelative(path),
                    line: line,
                    column: 1,
                    badgeLabel: spec.isEnabled ? (spec.isLogpoint ? "Logpoint" : "Breakpoint") : "Disabled",
                    quickFix: .deleteBreakpoint(ref),
                    breakpoint: ref,
                    isEnabled: spec.isEnabled
                ))
            }
        }
        for function in debug.functionBreakpoints {
            let ref = BreakpointRef.function(name: function.name)
            let problem = function.isEnabled ? debug.functionBreakpointProblems[function.name] : nil
            result.append(UnifiedDiagnosticItem(
                id: "breakpoint:function:\(function.name)",
                source: .breakpoint,
                severity: 4,
                title: function.name,
                detail: problem,
                path: "",
                relativePath: "Function Breakpoints",
                line: 0,
                column: 0,
                badgeLabel: function.isEnabled ? (problem == nil ? "Function" : "Not Set") : "Disabled",
                quickFix: .deleteBreakpoint(ref),
                breakpoint: ref,
                isEnabled: function.isEnabled,
                hasProblem: problem != nil
            ))
        }

        return result
    }

    func matchesScope(_ item: UnifiedDiagnosticItem, scope: DiagnosticsNavigatorScope) -> Bool {
        let category: DiagnosticsIssueCategory = switch item.source {
        case .compilerOrLSP, .linter, .database, .dependencyCycle:
            .issue
        case .safety:
            .safety
        case .complexity:
            .complexity(rating: "high")
        case .todo:
            .todo
        case .bookmark:
            .bookmark
        case .breakpoint:
            .breakpoint
        }
        let scopeKind: DiagnosticsScopeFilterKind = switch scope {
        case .all: .all
        case .errors: .errors
        case .warnings: .warnings
        case .safety: .safety
        case .todos: .todos
        case .bookmarks: .bookmarks
        case .breakpoints: .breakpoints
        }
        return DiagnosticsCenterRules.matchesScope(
            category: category,
            severity: item.severity,
            scope: scopeKind
        )
    }

    func count(for targetScope: DiagnosticsNavigatorScope, in all: [UnifiedDiagnosticItem]) -> Int {
        all.reduce(0) { partial, item in
            partial + (matchesScope(item, scope: targetScope) ? 1 : 0)
        }
    }

    func filteredItems(from all: [UnifiedDiagnosticItem]) -> [UnifiedDiagnosticItem] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { item in
            guard matchesScope(item, scope: scope) else { return false }
            guard !trimmed.isEmpty else { return true }
            if item.title.lowercased().contains(trimmed) { return true }
            if item.relativePath.lowercased().contains(trimmed) { return true }
            if let badge = item.badgeLabel?.lowercased(), badge.contains(trimmed) { return true }
            if let detail = item.detail?.lowercased(), detail.contains(trimmed) { return true }
            return false
        }
    }

    func performQuickFix(_ quickFix: UnifiedDiagnosticQuickFix, in workspace: WorkspaceState) {
        switch quickFix {
        case let .codeActions(path, line, column):
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            workspace.jumpTo(filePath: path, line: line, column: column)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard let tv = workspace.activeTextView as? GoLensTextView else { return }
                workspace.showCodeActionsMenu(for: tv, at: tv.selectedRange().location)
            }
        case let .inspectComplexity(path, line):
            if !path.isEmpty {
                workspace.jumpTo(filePath: path, line: line, column: 1)
            }
            workspace.openFunctionComplexityInspector()
        case .openPackageGraph:
            workspace.presentPackageDependenciesSheet()
        case let .removeBookmark(item):
            workspace.removeBookmark(item)
        case let .deleteBreakpoint(ref):
            workspace.deleteBreakpoint(ref)
        }
    }
}
