import Foundation

final class GolangciLintRunner {
    private struct ModuleQueue {
        var pending: [String] = []
        var running = false
        var debounce: DispatchWorkItem?
        var lastError: String?
    }

    struct Outcome: Decodable {
        let status: String
        let error: String?
        let files: [String: [DiagnosticData]]?
    }

    private let queue = DispatchQueue(label: "dev.golens.golangci-lint", qos: .utility, attributes: .concurrent)
    private var modules: [String: ModuleQueue] = [:]
    private var moduleRoots: [String: String] = [:]
    private var generation = 0

    func enqueue(workspace: String, packageDir: String, debounce: TimeInterval = 1,
                 deliver: @escaping (_ packageDir: String, _ outcome: Outcome, _ repeatedError: Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let module = moduleRoot(for: packageDir)
        var state = modules[module] ?? ModuleQueue()
        if !state.pending.contains(packageDir) { state.pending.append(packageDir) }
        state.debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.modules[module]?.debounce = nil
            self.startNext(module: module, workspace: workspace, deliver: deliver)
        }
        state.debounce = work
        modules[module] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1
        for state in modules.values { state.debounce?.cancel() }
        modules.removeAll()
        moduleRoots.removeAll()
    }

    private func startNext(module: String, workspace: String,
                           deliver: @escaping (String, Outcome, Bool) -> Void) {
        guard var state = modules[module], !state.running, state.debounce == nil, !state.pending.isEmpty else { return }
        let packageDir = state.pending.removeFirst()
        state.running = true
        modules[module] = state
        let started = generation
        queue.async { [weak self] in
            let json: String? = workspace.withCString { cRoot in
                packageDir.withCString { cDir in
                    guard let c = RunGolangCILintPackage(cRoot, cDir) else { return nil }
                    defer { FreeGoCString(c) }
                    return String(cString: c)
                }
            }
            let outcome = json.flatMap { try? JSONDecoder().decode(Outcome.self, from: Data($0.utf8)) }
                ?? Outcome(status: "error", error: "could not read golangci-lint results", files: nil)
            DispatchQueue.main.async {
                guard let self, self.generation == started, var state = self.modules[module] else { return }
                state.running = false
                var repeated = false
                if outcome.status == "error" {
                    repeated = state.lastError == outcome.error
                    state.lastError = outcome.error
                } else {
                    state.lastError = nil
                }
                self.modules[module] = state
                deliver(packageDir, outcome, repeated)
                self.startNext(module: module, workspace: workspace, deliver: deliver)
            }
        }
    }

    private func moduleRoot(for packageDir: String) -> String {
        if let cached = moduleRoots[packageDir] { return cached }
        var dir = packageDir
        var root = packageDir
        while !dir.isEmpty, dir != "/" {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod")) {
                root = dir
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        moduleRoots[packageDir] = root
        return root
    }
}

final class SafetyAnalyzerRunner {
    private struct ModuleQueue {
        var pending: [String] = []
        var running = false
        var debounce: DispatchWorkItem?
        var lastError: String?
    }

    private let queue = DispatchQueue(label: "dev.golens.safety-analyzers", qos: .utility, attributes: .concurrent)
    private var modules: [String: ModuleQueue] = [:]
    private var moduleRoots: [String: String] = [:]
    private var generation = 0

    func enqueue(
        workspace: String,
        packageDir: String,
        disabledCategories: String,
        debounce: TimeInterval = 0.35,
        deliver: @escaping (_ packageDir: String, _ outcome: GolangciLintRunner.Outcome, _ repeatedError: Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let module = moduleRoot(for: packageDir)
        var state = modules[module] ?? ModuleQueue()
        if !state.pending.contains(packageDir) { state.pending.append(packageDir) }
        state.debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.modules[module]?.debounce = nil
            self.startNext(module: module, workspace: workspace, disabledCategories: disabledCategories, deliver: deliver)
        }
        state.debounce = work
        modules[module] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1
        for state in modules.values { state.debounce?.cancel() }
        modules.removeAll()
        moduleRoots.removeAll()
    }

    private func startNext(
        module: String,
        workspace: String,
        disabledCategories: String,
        deliver: @escaping (String, GolangciLintRunner.Outcome, Bool) -> Void
    ) {
        guard var state = modules[module], !state.running, state.debounce == nil, !state.pending.isEmpty else { return }
        let packageDir = state.pending.removeFirst()
        state.running = true
        modules[module] = state
        let started = generation
        queue.async { [weak self] in
            let json: String? = workspace.withCString { cRoot in
                packageDir.withCString { cDir in
                    disabledCategories.withCString { cDisabled in
                        guard let c = RunGoSafetyAnalyzers(cRoot, cDir, cDisabled) else { return nil }
                        defer { FreeGoCString(c) }
                        return String(cString: c)
                    }
                }
            }
            let outcome = json.flatMap { try? JSONDecoder().decode(GolangciLintRunner.Outcome.self, from: Data($0.utf8)) }
                ?? GolangciLintRunner.Outcome(status: "error", error: "could not read safety analyzer results", files: nil)
            DispatchQueue.main.async {
                guard let self, self.generation == started, var state = self.modules[module] else { return }
                state.running = false
                var repeated = false
                if outcome.status == "error" {
                    repeated = state.lastError == outcome.error
                    state.lastError = outcome.error
                } else {
                    state.lastError = nil
                }
                self.modules[module] = state
                deliver(packageDir, outcome, repeated)
                self.startNext(module: module, workspace: workspace, disabledCategories: disabledCategories, deliver: deliver)
            }
        }
    }

    private func moduleRoot(for packageDir: String) -> String {
        if let cached = moduleRoots[packageDir] { return cached }
        var dir = packageDir
        var root = packageDir
        while !dir.isEmpty, dir != "/" {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod")) {
                root = dir
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        moduleRoots[packageDir] = root
        return root
    }
}

extension WorkspaceState {
    static let golangciLintOnSaveKey = "GoLensGolangciLintOnSave"
    static let safetyAnalyzersEnabledKey = "GoLensSafetyAnalyzersOnSave"
    static let safetyAnalyzerCategoriesKey = "GoLensSafetyAnalyzerCategories"
    static let allSafetyCategoryIDs = [
        "concurrency",
        "resourceSafety",
        "errorHandling",
        "security",
        "modernization",
    ]

    var golangciLintOnSave: Bool {
        UserDefaults.standard.object(forKey: Self.golangciLintOnSaveKey) as? Bool ?? true
    }

    var safetyAnalyzersOnSave: Bool {
        UserDefaults.standard.object(forKey: Self.safetyAnalyzersEnabledKey) as? Bool ?? true
    }

    static func isSafetyCategoryEnabled(_ id: String) -> Bool {
        let dict = UserDefaults.standard.dictionary(forKey: safetyAnalyzerCategoriesKey) as? [String: Bool] ?? [:]
        return dict[id] ?? true
    }

    static func setSafetyCategoryEnabled(_ id: String, _ enabled: Bool) {
        var dict = UserDefaults.standard.dictionary(forKey: safetyAnalyzerCategoriesKey) as? [String: Bool] ?? [:]
        dict[id] = enabled
        UserDefaults.standard.set(dict, forKey: safetyAnalyzerCategoriesKey)
    }

    static func disabledSafetyCategoriesCSV() -> String {
        allSafetyCategoryIDs.filter { !isSafetyCategoryEnabled($0) }.joined(separator: ",")
    }

    func scheduleLintOnOpen(_ path: String) {
        guard path.hasSuffix(".go") else { return }
        let packageDir = (path as NSString).deletingLastPathComponent
        if golangciLintOnSave, !activeWorkspacePath.isEmpty, !lintRequestedPackages.contains(packageDir) {
            enqueueGolangciLint(for: path)
        }
        if safetyAnalyzersOnSave, !safetyRequestedPackages.contains(packageDir) {
            scheduleSafetyAnalysis(for: path)
        }
    }

    func scheduleLintAfterSave(_ path: String) {
        guard path.hasSuffix(".go") else { return }
        if golangciLintOnSave, !activeWorkspacePath.isEmpty {
            enqueueGolangciLint(for: path)
        }
        if safetyAnalyzersOnSave {
            scheduleSafetyAnalysis(for: path)
        }
        diagnosticsCenter.scheduleChecksAfterSave(for: self, savedFilePath: path)
    }

    private func enqueueGolangciLint(for path: String) {
        let workspace = activeWorkspacePath
        let packageDir = (path as NSString).deletingLastPathComponent
        guard !workspace.isEmpty, !packageDir.isEmpty else { return }
        lintRequestedPackages.insert(packageDir)
        lintRunner.enqueue(workspace: workspace, packageDir: packageDir) { [weak self] packageDir, outcome, repeated in
            guard let self, self.activeWorkspacePath == workspace else { return }
            self.applyLintOutcome(outcome, packageDir: packageDir, repeatedError: repeated)
        }
    }

    func scheduleSafetyAnalysis(for path: String, debounce: TimeInterval = 0.35) {
        guard path.hasSuffix(".go"), safetyAnalyzersOnSave else { return }
        let packageDir = (path as NSString).deletingLastPathComponent
        guard !packageDir.isEmpty else { return }
        let workspace = activeWorkspacePath.isEmpty ? packageDir : activeWorkspacePath
        let expectedWorkspace = activeWorkspacePath
        let disabled = Self.disabledSafetyCategoriesCSV()
        if Self.allSafetyCategoryIDs.allSatisfy({ !Self.isSafetyCategoryEnabled($0) }) {
            clearSafetyDiagnostics()
            return
        }
        safetyRequestedPackages.insert(packageDir)
        safetyRunner.enqueue(
            workspace: workspace,
            packageDir: packageDir,
            disabledCategories: disabled,
            debounce: debounce
        ) { [weak self] packageDir, outcome, repeated in
            guard let self, self.activeWorkspacePath == expectedWorkspace else { return }
            self.applySafetyOutcome(outcome, packageDir: packageDir, repeatedError: repeated)
        }
    }

    func applySafetyOutcome(_ outcome: GolangciLintRunner.Outcome, packageDir: String, repeatedError: Bool) {
        switch outcome.status {
        case "ok":
            resetDiagnosticStoresIfStale()
            var fresh: [String: [DiagnosticData]] = [:]
            for (rawPath, diags) in outcome.files ?? [:] {
                fresh[Self.canonicalPath(rawPath)] = diags
            }
            let affected = (safetyPackageFiles[packageDir] ?? []).union(fresh.keys)
            for path in affected {
                let diags = fresh[path] ?? []
                if diags.isEmpty {
                    safetyDiagnostics.removeValue(forKey: path)
                } else {
                    safetyDiagnostics[path] = diags
                }
                if publishMergedDiagnostics(for: path) {
                    NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
                }
            }
            let withIssues = Set(fresh.filter { !$0.value.isEmpty }.keys)
            if withIssues.isEmpty {
                safetyPackageFiles.removeValue(forKey: packageDir)
            } else {
                safetyPackageFiles[packageDir] = withIssues
            }
        case "error":
            if !repeatedError {
                let detail = outcome.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                appendLog("safety analyzers: \(detail.isEmpty ? "the run failed" : detail)", isStderr: true)
            }
        default:
            break
        }
    }

    func clearSafetyDiagnostics() {
        safetyRunner.cancelAll()
        let paths = Array(safetyDiagnostics.keys)
        safetyDiagnostics.removeAll()
        safetyPackageFiles.removeAll()
        safetyRequestedPackages.removeAll()
        for path in paths where publishMergedDiagnostics(for: path) {
            NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
        }
    }

    func rerunSafetyAnalyzersForOpenFiles() {
        guard safetyAnalyzersOnSave else {
            clearSafetyDiagnostics()
            return
        }
        if Self.allSafetyCategoryIDs.allSatisfy({ !Self.isSafetyCategoryEnabled($0) }) {
            clearSafetyDiagnostics()
            return
        }
        safetyRunner.cancelAll()
        safetyRequestedPackages.removeAll()
        var seenDirs = Set<String>()
        let candidatePaths = openFiles + (activeFilePath.isEmpty ? [] : [activeFilePath])
        for path in candidatePaths where path.hasSuffix(".go") {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty && seenDirs.insert(dir).inserted {
                scheduleSafetyAnalysis(for: path, debounce: 0.05)
            }
        }
    }

    func applyLintOutcome(_ outcome: GolangciLintRunner.Outcome, packageDir: String, repeatedError: Bool) {
        switch outcome.status {
        case "ok":
            resetDiagnosticStoresIfStale()
            var fresh: [String: [DiagnosticData]] = [:]
            for (rawPath, diags) in outcome.files ?? [:] {
                fresh[Self.canonicalPath(rawPath)] = diags
            }
            let affected = (lintPackageFiles[packageDir] ?? []).union(fresh.keys)
            for path in affected {
                let diags = fresh[path] ?? []
                if diags.isEmpty {
                    lintDiagnostics.removeValue(forKey: path)
                } else {
                    lintDiagnostics[path] = diags
                }
                if publishMergedDiagnostics(for: path) {
                    NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
                }
            }
            let withIssues = Set(fresh.filter { !$0.value.isEmpty }.keys)
            if withIssues.isEmpty {
                lintPackageFiles.removeValue(forKey: packageDir)
            } else {
                lintPackageFiles[packageDir] = withIssues
            }
        case "error":
            if !repeatedError {
                let detail = outcome.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                appendLog("golangci-lint: \(detail.isEmpty ? "the run failed" : detail)", isStderr: true)
            }
        default:
            break
        }
    }

    func clearLintDiagnostics() {
        lintRunner.cancelAll()
        let paths = Array(lintDiagnostics.keys)
        lintDiagnostics.removeAll()
        lintPackageFiles.removeAll()
        lintRequestedPackages.removeAll()
        for path in paths where publishMergedDiagnostics(for: path) {
            NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
        }
    }

    @discardableResult
    func publishGoplsDiagnostics(_ diags: [DiagnosticData], for path: String) -> Bool {
        resetDiagnosticStoresIfStale()
        if diags.isEmpty {
            goplsDiagnostics.removeValue(forKey: path)
        } else {
            goplsDiagnostics[path] = diags
        }
        let changed = publishMergedDiagnostics(for: path)
        NotificationCenter.default.post(name: .golensGoplsDiagnosticsPublished, object: path)
        return changed
    }

    @discardableResult
    func publishMergedDiagnostics(for path: String) -> Bool {
        let merged = Self.mergeDiagnostics(
            goplsDiagnostics[path] ?? [],
            lintDiagnostics[path] ?? [],
            safetyDiagnostics[path] ?? [],
            moduleDoctorBucket.entriesByPath[path] ?? []
        )
        guard merged != (diagnostics[path] ?? []) else { return false }
        if merged.isEmpty {
            diagnostics.removeValue(forKey: path)
        } else {
            diagnostics[path] = merged
        }
        updateFlatDiagnostics(changedPath: path)
        return true
    }

    static func mergeDiagnostics(
        _ gopls: [DiagnosticData],
        _ lint: [DiagnosticData],
        _ safety: [DiagnosticData] = [],
        _ moduleDoctor: [DiagnosticData] = []
    ) -> [DiagnosticData] {
        guard !lint.isEmpty || !safety.isEmpty || !moduleDoctor.isEmpty else { return gopls }
        struct Key: Hashable { let line, col, endLine, endCol: Int; let message: String }
        var seen = Set(gopls.map { Key(line: $0.line, col: $0.col, endLine: $0.endLine, endCol: $0.endCol, message: $0.message) })
        var merged = gopls
        for d in lint where seen.insert(Key(line: d.line, col: d.col, endLine: d.endLine, endCol: d.endCol, message: d.message)).inserted {
            merged.append(d)
        }
        for d in safety where seen.insert(Key(line: d.line, col: d.col, endLine: d.endLine, endCol: d.endCol, message: d.message)).inserted {
            merged.append(d)
        }
        for d in moduleDoctor where seen.insert(Key(line: d.line, col: d.col, endLine: d.endLine, endCol: d.endCol, message: d.message)).inserted {
            merged.append(d)
        }
        return merged
    }

    private func resetDiagnosticStoresIfStale() {
        guard diagnosticStoresWorkspace != activeWorkspacePath || diagnostics.isEmpty else { return }
        if diagnosticStoresWorkspace != activeWorkspacePath {
            lintRequestedPackages.removeAll()
            safetyRequestedPackages.removeAll()
        }
        diagnosticStoresWorkspace = activeWorkspacePath
        goplsDiagnostics.removeAll()
        lintDiagnostics.removeAll()
        lintPackageFiles.removeAll()
        safetyDiagnostics.removeAll()
        safetyPackageFiles.removeAll()
        moduleDoctorBucket.syncWorkspaceOnNonDoctorReset(activeWorkspace: activeWorkspacePath)
    }
}
