import Foundation
import GoLensFoundation
import SwiftUI
import os
import SwiftTerm

extension WorkspaceState {
    func hasMainPackageClause(in text: NSString) -> Bool {
        let limit = min(text.length, 4096)
        var pos = 0
        var inBlockComment = false
        while pos < limit {
            let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            pos = NSMaxRange(lineRange)
            if inBlockComment {
                if let end = line.range(of: "*/") {
                    inBlockComment = false
                    let rest = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("package ") || rest.hasPrefix("package\t") {
                        let pkg = rest.dropFirst("package".count).trimmingCharacters(in: .whitespaces)
                        return pkg == "main" || pkg.hasPrefix("main ") || pkg.hasPrefix("main\t") || pkg.hasPrefix("main;") || pkg.hasPrefix("main/")
                    }
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("/*") {
                if !line.contains("*/") { inBlockComment = true }
                continue
            }
            if line.hasPrefix("package ") || line.hasPrefix("package\t") {
                let pkg = line.dropFirst("package".count).trimmingCharacters(in: .whitespaces)
                return pkg == "main" || pkg.hasPrefix("main ") || pkg.hasPrefix("main\t") || pkg.hasPrefix("main;") || pkg.hasPrefix("main/")
            }
            break
        }
        return false
    }

    func isMainPackageFile(_ path: String) -> Bool {
        guard path.hasSuffix(".go") else { return false }
        if let doc = documents[path] {
            return hasMainPackageClause(in: doc.storage.string as NSString)
        }
        let dir = (path as NSString).deletingLastPathComponent
        for (docPath, doc) in documents where (docPath as NSString).deletingLastPathComponent == dir && docPath.hasSuffix(".go") {
            if hasMainPackageClause(in: doc.storage.string as NSString) {
                return true
            }
        }
        return false
    }

    func resolvedRunTargetDisplayName(forTest test: TestTarget? = nil) -> String {
        if let title = test?.title, !title.isEmpty {
            return title
        }
        if let name = activeRunConfiguration?.name, !name.isEmpty {
            return name
        }
        if let wd = activeRunConfiguration?.workingDirectory, !wd.isEmpty {
            return projectRelativePath(wd)
        }
        if activeFilePath.hasSuffix(".go") {
            let dir = (activeFilePath as NSString).deletingLastPathComponent
            if dir != activeWorkspacePath && dir.hasPrefix(activeWorkspacePath + "/") && isMainPackageFile(activeFilePath) {
                return projectRelativePath(dir)
            }
        }
        return (activeWorkspacePath as NSString).lastPathComponent
    }

    var isCurrentRunTargetRunning: Bool {
        if debug.isDebugMode || isTestRunning || goCommand != nil || isStartingRun {
            return true
        }
        guard isRunning else { return false }
        if let config = activeRunConfiguration, config.kind == .docker {
            return isDockerConfigurationRunning(config)
        }
        if let config = activeRunConfiguration, !config.name.isEmpty {
            return runSessions.contains { $0.isRunning && $0.key == "config:" + config.name }
        }
        if let wd = activeRunConfiguration?.workingDirectory, !wd.isEmpty {
            let dir = wd.hasPrefix("/") ? wd : (activeWorkspacePath as NSString).appendingPathComponent(wd)
            return runSessions.contains { $0.isRunning && ($0.dir == dir || $0.key == dir) }
        }
        if activeFilePath.hasSuffix(".go") && isMainPackageFile(activeFilePath) {
            let dir = (activeFilePath as NSString).deletingLastPathComponent
            return runSessions.contains { $0.isRunning && ($0.dir == dir || $0.key == dir) }
        }
        return runSessions.contains(where: \.isRunning)
    }

    func clearDebugPauseState() {
        debug.isPaused = false
        debug.exceptionMessage = nil
        debug.activeLine = 0
        debug.activePath = nil
        debug.inlinePath = nil
        debug.inlineValues = [:]
        debug.selectedFrameId = nil
        debug.callStack = []
        debug.variables = []
        debug.watchResults = [:]
        activeTextView?.needsDisplay = true
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func debugContinue() {
        let tid = debug.activeThreadId ?? 1
        clearDebugPauseState()
        agentQueue.async { DebugContinue(tid) }
    }

    func debugPause() {
        guard debug.isDebugMode, !debug.isPaused else { return }
        let tid = debug.activeThreadId ?? 1
        agentQueue.async { DebugPause(tid) }
    }

    func debugRunToCursor(line requestedLine: Int? = nil) {
        let title = "Run to Cursor"
        guard debug.isDebugMode else {
            presentCommandFeedback("Start debugging, then pause the program to run to a line.", title: title)
            return
        }
        guard debug.isPaused else {
            presentCommandFeedback("The program is running. Pause it or wait for a breakpoint, then run to the cursor.", title: title)
            return
        }
        guard let textView = activeTextView as? GoLensTextView, textView.filePath.hasSuffix(".go") else {
            presentCommandFeedback("Run to Cursor works in Go files. Open the Go file and place the cursor on the line to stop at.", title: title)
            return
        }
        let path = textView.filePath
        let line = requestedLine ?? textView.lineAndCol(forCharacterIndex: textView.selectedRange().location).line
        let json = debug.breakpointsJSON(for: path)
        let tid = debug.activeThreadId ?? 1
        agentQueue.async { [weak self] in
            let error: String? = path.withCString { p in json.withCString { j in
                guard let c = DebugRunToLine(p, Int32(line), j, tid) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            } }
            guard let error else { return }
            let reason = Self.formatCommandReason(error, fallback: "Couldn’t run to line \(line).")
            let message = error.contains("no code to stop at") ? reason + " Place the cursor on a line with a statement and try again." : reason
            DispatchQueue.main.async {
                self?.presentCommandFeedback(message, title: title, tone: .warning)
            }
        }
    }

    func debugStepOver() {
        let tid = debug.activeThreadId ?? 1
        clearDebugPauseState()
        agentQueue.async { DebugStepOver(tid) }
    }

    func debugStepInto() {
        let tid = debug.activeThreadId ?? 1
        clearDebugPauseState()
        agentQueue.async { DebugStepInto(tid) }
    }

    func debugStepOut() {
        let tid = debug.activeThreadId ?? 1
        clearDebugPauseState()
        agentQueue.async { DebugStepOut(tid) }
    }

    func debugStop() {
        clearDebugPauseState()
        debug.functionBreakpointProblems = [:]
        debug.isDebugMode = false
        debug.activeThreadId = 1
        debug.threads = []
        debug.goroutineGroups = []
        if selectedConsoleTab == Self.debuggerTab { selectedConsoleTab = Self.consoleTab }
        agentQueue.async { DebugStop() }
    }

    func debugProject(test: TestTarget? = nil, patternOverride: String? = nil) {
        guard !activeWorkspacePath.isEmpty, !isRunning else { return }
        if let test {
            lastTestInvocation = .debug(test, patternOverride: patternOverride)
        }
        if let other = otherWindowDebugSession {
            presentCommandFeedback("The window for \((other.activeWorkspacePath as NSString).lastPathComponent) is debugging. GoLens runs one debug session at a time, so stop that session first.", title: "Debug", tone: .warning)
            return
        }
        claimCoreEvents(.debug, .output)
        runFailure = nil
        debug.isDebugMode = true
        debug.isPaused = false
        showConsole = true
        selectedConsoleTab = Self.consoleTab
        debug.revealedOnPause = false
        selectedRunSessionId = nil
        consoleOutput.removeAll()
        consoleOutputBytes = 0
        appendLog("Debugging \(resolvedRunTargetDisplayName(forTest: test))\(activeRunTarget.isRemote ? " on \(activeRunTarget.title)" : "")…")
        var configDict: [String: Any] = [:]
        if let config = activeRunConfiguration {
            configDict["name"] = config.name
            configDict["envVars"] = resolvedEnvVars(for: config)
            configDict["buildFlags"] = config.buildFlags
            configDict["args"] = config.args
            configDict["workingDirectory"] = config.workingDirectory
        }
        configDict["activeFilePath"] = activeFilePath
        addRunTarget(to: &configDict, action: .debug)
        if let test {
            configDict["test"] = test.test
            configDict["testRow"] = test.row ?? ""
            if let patternOverride, !patternOverride.isEmpty {
                configDict["testPattern"] = patternOverride
            }
            configDict["workingDirectory"] = test.dir
            configDict["args"] = ""
        }
        configDict["debugLogging"] = UserDefaults.standard.bool(forKey: Self.diagnosticLogsKey)

        let configJsonStr: String
        if let data = try? JSONSerialization.data(withJSONObject: configDict, options: []), let str = String(data: data, encoding: .utf8) {
            configJsonStr = str
        } else {
            configJsonStr = "{}"
        }
        
        saveAllEdited(then: {
            self.launchDebugSession(configJsonStr)
        }, onFailure: {
            self.debug.isDebugMode = false
        })
    }

    func launchDebugSession(_ configJsonStr: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let errorString: String? = configJsonStr.withCString { cStr in
                if let cError = DebugStart(UnsafeMutablePointer(mutating: cStr)) {
                    defer { FreeGoCString(cError) }
                    return String(cString: cError)
                }
                return nil
            }
            if let errorString = errorString {
                await MainActor.run {
                    self.appendLog("Debug start failed: \(errorString)")
                    self.debug.isDebugMode = false
                    guard self.runFailure == nil else { return }
                    self.runFailure = RunFailure(
                        kind: .remote(RemoteIssue(
                            title: "Couldn’t Start Debugging",
                            message: "\(Self.formatCommandReason(errorString, fallback: "The debugger didn’t start.")) Check the output below, then start debugging again."
                        )),
                        errorCount: 0,
                        firstErrorURL: nil,
                        detail: errorString
                    )
                }
                return
            }
            let payloads = await MainActor.run { self.debug.breakpoints.keys.map { ($0, self.debug.breakpointsJSON(for: $0)) } }
            for (path, json) in payloads {
                path.withCString { p in json.withCString { j in FreeGoCString(DebugSetBreakpoints(p, j)) } }
            }
            let functions = await MainActor.run { (self.debug.functionBreakpointsJSON(), self.debug.functionBreakpoints.filter(\.isEnabled).map(\.name)) }
            if !functions.1.isEmpty {
                let result = Self.sendFunctionBreakpoints(functions.0)
                await MainActor.run { self.applyFunctionBreakpointResult(result, names: functions.1) }
            }
            DebugConfigurationDone()
        }
    }

    func toggleBreakpoint(forLine line: Int, in filePath: String) {
        guard filePath.hasSuffix(".go") else { return }
        if debug.breakpoints[filePath] == nil { debug.breakpoints[filePath] = [] }
        if debug.breakpoints[filePath]!.contains(line) {
            debug.breakpoints[filePath]!.remove(line)
            debug.breakpointSpecs[filePath]?[line] = nil
        } else {
            debug.breakpoints[filePath]!.insert(line)
        }
        if debug.breakpoints[filePath]?.isEmpty == true {
            debug.breakpoints[filePath] = nil
        }
        syncBreakpoints(for: filePath)
        saveBreakpointsForWorkspace()
    }

    func updateBreakpoint(_ spec: BreakpointSpec, line: Int, in filePath: String) {
        debug.breakpoints[filePath, default: []].insert(line)
        debug.breakpointSpecs[filePath, default: [:]][line] = spec.isPlain ? nil : spec
        syncBreakpoints(for: filePath)
        saveBreakpointsForWorkspace()
        activeTextView?.needsDisplay = true
    }

    func syncBreakpoints(for filePath: String) {
        guard debug.isDebugMode else { return }
        let json = debug.breakpointsJSON(for: filePath)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String? = filePath.withCString { p in json.withCString { j in
                guard let c = DebugSetBreakpoints(p, j) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            } }
            guard let result, let data = result.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            for bp in list where bp["verified"] as? Bool == false {
                let line = bp["line"] as? Int ?? 0
                self.appendLog("Breakpoint at \((filePath as NSString).lastPathComponent):\(line) not set: \(bp["message"] as? String ?? "unverified")")
            }
        }
    }

    func setDebugVariable(_ variable: DAPVariable, parentReference: Int, to value: String) {
        let name = variable.name
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String? = name.withCString { n in value.withCString { v in
                guard let c = DebugSetVariable(Int32(parentReference), n, v) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            } }
            DispatchQueue.main.async {
                guard let result, !result.hasPrefix("Error:") else {
                    let detail = result.map { String($0.dropFirst(7)) } ?? "debugger not running"
                    self.appendLog("Could not set \(name): \(detail)")
                    self.presentCommandFeedback(Self.formatCommandReason(detail, fallback: "Could not update variable value."), title: "Couldn’t Set Variable", tone: .failure)
                    return
                }
                if let tid = self.debug.activeThreadId { self.fetchDebugState(for: tid, jump: false) }
            }
        }
    }

    func fetchGoroutineGroups() {
        DispatchQueue.global(qos: .utility).async {
            guard let c = DebugGoroutineGroups() else { return }
            let json = String(cString: c)
            FreeGoCString(c)
            guard let groups = try? JSONDecoder().decode([GoroutineGroup].self, from: Data(json.utf8)) else { return }
            DispatchQueue.main.async { self.debug.goroutineGroups = groups }
        }
    }

    func fetchDebugState(for threadId: Int32, jump: Bool = true) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            if let cThreads = DebugGetThreads() {
                defer { FreeGoCString(cThreads) }
                let threadsJson = String(cString: cThreads)
                if let data = threadsJson.data(using: .utf8),
                   let threads = try? JSONDecoder().decode([DAPThread].self, from: data) {
                    await MainActor.run {
                        self.debug.threads = threads
                    }
                }
            }
            guard let cStack = DebugGetStackTrace(threadId) else { return }
            defer { FreeGoCString(cStack) }
            let stackJson = String(cString: cStack)
            guard let data = stackJson.data(using: .utf8),
                  let frames = try? JSONDecoder().decode([DAPStackFrame].self, from: data) else { return }
            let root = await MainActor.run { URL(fileURLWithPath: self.activeWorkspacePath).resolvingSymlinksInPath().path }
            let topFrame = frames.first {
                guard let p = $0.source?.path, !p.isEmpty else { return false }
                let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
                return resolved.hasPrefix(root + "/")
            } ?? frames.first
            await MainActor.run {
                self.debug.callStack = frames
                if let topFrame {
                    self.selectFrame(topFrame, jump: jump)
                } else {
                    self.debug.selectedFrameId = nil
                    self.debug.activeLine = 0
                }
            }
        }
    }

    func selectFrame(_ frame: DAPStackFrame, jump: Bool = true, focusEditor: Bool = false) {
        let resolvedPath = frame.source?.path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        debug.selectedFrameId = frame.id
        debug.activeLine = frame.line
        debug.activePath = resolvedPath
        if jump, let path = resolvedPath, !path.isEmpty {
            jumpTo(filePath: path, line: frame.line, column: max(1, frame.column))
            if focusEditor {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let tv = self.activeTextView { tv.window?.makeFirstResponder(tv) }
                }
            }
        }
        (activeTextView as? GoLensTextView)?.redrawGutter()
        fetchVariablesForFrame(frameId: Int32(frame.id), path: resolvedPath, line: frame.line)
    }

    static let maxWatches = 50

    func addWatch(_ expression: String) {
        let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { return }
        if !debug.watches.contains(expr) {
            if debug.watches.count >= Self.maxWatches { debug.watches.removeFirst() }
            debug.watches.append(expr)
        }
        if let frameId = debug.selectedFrameId { evaluateWatches(frameId: Int32(frameId), only: [expr]) }
    }

    func removeWatch(_ expression: String) {
        debug.watches.removeAll { $0 == expression }
        debug.watchResults[expression] = nil
    }

    func evaluateWatches(frameId: Int32, only: [String]? = nil) {
        let expressions = only ?? debug.watches
        guard !expressions.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [String: WatchEvaluationResult] = [:]
            for expr in expressions {
                guard let c = DebugEvaluate(expr, frameId) else { continue }
                defer { FreeGoCString(c) }
                let raw = String(cString: c)
                if let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(WatchEvaluationResult.self, from: data) {
                    results[expr] = decoded
                } else if raw.hasPrefix("Error: ") {
                    results[expr] = WatchEvaluationResult(value: "", type: "", variablesReference: 0, error: String(raw.dropFirst(7)))
                } else {
                    results[expr] = WatchEvaluationResult(value: raw, type: "", variablesReference: 0, error: nil)
                }
            }
            DispatchQueue.main.async {
                guard self.debug.selectedFrameId == Int(frameId) else { return }
                self.debug.watchResults.merge(results) { _, new in new }
            }
        }
    }

    static func debugVariables(_ reference: Int) -> [DAPVariable]? {
        guard let c = DebugGetVariables(Int32(reference)) else { return nil }
        defer { FreeGoCString(c) }
        return try? JSONDecoder().decode([DAPVariable].self, from: Data(String(cString: c).utf8))
    }

    func fetchVariablesForFrame(frameId: Int32, path: String?, line: Int) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            guard let cScopes = DebugGetScopes(frameId) else { return }
            defer { FreeGoCString(cScopes) }
            let scopesJson = String(cString: cScopes)
            guard let data = scopesJson.data(using: .utf8),
                  let scopes = try? JSONDecoder().decode([DAPScope].self, from: data),
                  let firstScope = scopes.first else { return }
            await MainActor.run { self.debug.variablesScopeReference = firstScope.variablesReference }
            guard let cVars = DebugGetVariables(Int32(firstScope.variablesReference)) else { return }
            defer { FreeGoCString(cVars) }
            let varsJson = String(cString: cVars)
            guard let vdata = varsJson.data(using: .utf8),
                  let vars = try? JSONDecoder().decode([DAPVariable].self, from: vdata) else { return }
            let inline = path.map { Self.inlineValues(vars, path: $0, line: line) } ?? [:]
            await MainActor.run {
                self.debug.variables = vars
                self.evaluateWatches(frameId: frameId)
                self.debug.inlinePath = path
                self.debug.inlineValues = inline
                (self.activeTextView as? GoLensTextView)?.redrawGutter()
            }
        }
    }

    static let maxInlineValueLength = 60

    static func inlineValues(_ vars: [DAPVariable], path: String, line: Int) -> [Int: String] {
        guard path.hasSuffix(".go"), line > 0, !vars.isEmpty,
              let names = try? JSONSerialization.data(withJSONObject: vars.map(\.name)),
              let namesJSON = String(data: names, encoding: .utf8) else { return [:] }
        let json: String? = path.withCString { p in
            namesJSON.withCString { n in
                guard let c = InlineValueLines(p, Int32(line), n) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
        }
        guard let positions = json.flatMap({ try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }) else { return [:] }
        var byLine: [Int: [String]] = [:]
        for v in vars {
            guard let at = positions[v.name] else { continue }
            let value = v.value.count > maxInlineValueLength ? String(v.value.prefix(maxInlineValueLength)) + "…" : v.value
            byLine[at, default: []].append("\(v.name): \(value)")
        }
        return byLine.mapValues { $0.joined(separator: "  ") }
    }

    func diagnoseRunFailure(exitMessage: String, in messages: [LogMessage]? = nil, oomKilled: Bool = false, memoryMax: UInt64 = 0) -> RunFailure {
        let source = messages ?? consoleOutput
        let errors = source.filter { $0.isStderr && $0.text.range(of: #"\.go:\d+:\d+: "#, options: .regularExpression) != nil }
        let firstURL = errors.first?.linked.flatMap { linked in linked.runs.lazy.compactMap(\.link).first }
        if oomKilled || exitMessage.contains("OOMKilled") {
            let limitStr = MemoryLimit.allCases.first(where: { $0.bytes == memoryMax && memoryMax > 0 })?.title ?? (memoryMax > 0 ? "\(memoryMax / (1024 * 1024)) MB" : "configured limit")
            return RunFailure(
                kind: .oomKilled(memoryLimit: limitStr),
                errorCount: 0,
                firstErrorURL: nil,
                detail: "Process terminated by Linux OOM Killer (cgroups memory limit exceeded)"
            )
        }
        if goToolchainMissing || exitMessage.contains("executable file not found") {
            return RunFailure(kind: .toolchainMissing, errorCount: 0, firstErrorURL: nil, detail: exitMessage)
        }
        let programExit = source.last { $0.isStderr && $0.text.hasPrefix("exit status ") }?.text
        let kind: RunFailure.Kind = goCommand.map { .command($0) } ?? (errors.isEmpty ? .exited : .build)
        return RunFailure(kind: kind, errorCount: errors.count, firstErrorURL: firstURL, detail: programExit ?? exitMessage)
    }

    func runProject() {
        if let config = activeRunConfiguration, config.kind == .docker {
            runDockerConfiguration(config)
            return
        }
        let destination = activeRunTarget.isRemote ? " on \(activeRunTarget.title)" : ""
        beginRun("Running \(resolvedRunTargetDisplayName())\(destination)…", command: nil)
        
        var configDict: [String: Any] = ["activeFilePath": activeFilePath]
        if let config = activeRunConfiguration {
            configDict["name"] = config.name
            configDict["envVars"] = resolvedEnvVars(for: config)
            configDict["buildFlags"] = config.buildFlags
            configDict["args"] = config.args
            configDict["workingDirectory"] = config.workingDirectory
            configDict["memoryLimit"] = config.memoryLimit.rawValue
            configDict["cpuQuota"] = config.cpuQuota.rawValue
        }
        addRunTarget(to: &configDict, action: .run)
        let configJsonStr = (try? JSONSerialization.data(withJSONObject: configDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        claimCoreEvents(.output)
        saveAllEdited(then: {
            self.agentQueue.async {
                configJsonStr.withCString { cStr in
                    ExecuteGoRun(UnsafeMutablePointer(mutating: cStr))
                }
            }
        }, onFailure: {
            self.abortPendingRun()
        })
    }

    func profileProject() {
        beginRun("Profiling \(resolvedRunTargetDisplayName())…", command: nil)

        var configDict: [String: Any] = ["activeFilePath": activeFilePath]
        if let config = activeRunConfiguration {
            configDict["name"] = config.name
            configDict["envVars"] = resolvedEnvVars(for: config)
            configDict["buildFlags"] = config.buildFlags
            configDict["args"] = config.args
            configDict["workingDirectory"] = config.workingDirectory
            configDict["memoryLimit"] = config.memoryLimit.rawValue
            configDict["cpuQuota"] = config.cpuQuota.rawValue
        }
        let configJsonStr = (try? JSONSerialization.data(withJSONObject: configDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        saveAllEdited(then: {
            self.agentQueue.async {
                configJsonStr.withCString { cStr in
                    ExecuteGoProfileApp(UnsafeMutablePointer(mutating: cStr))
                }
            }
        }, onFailure: {
            self.abortPendingRun()
        })
    }

    func buildProject() {
        runGoCommand("build -o /dev/null ./...", named: "Build", log: "Building")
    }

    func tidyModule() {
        runGoCommand("mod tidy", named: "go mod tidy", log: "Running go mod tidy in")
    }

    func downloadModules() {
        runGoCommand("mod download", named: "go mod download", log: "Downloading Go modules in")
    }

    func addGoModule(_ spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isGoGetSpec(trimmed) else {
            appendLog("“\(trimmed)” isn’t a Go module or package path.", isStderr: true)
            return
        }
        pendingTidyAfterGoGet.insert("cmd:go get \(trimmed)")
        runGoCommand("get \(trimmed)", named: "go get \(trimmed)", log: "Adding \(trimmed) to")
    }

    static func isGoGetSpec(_ spec: String) -> Bool {
        spec.range(of: #"^[A-Za-z0-9][A-Za-z0-9._~+-]*(/[A-Za-z0-9._~+-]+)*(@[A-Za-z0-9._~+/-]+)?$"#, options: .regularExpression) != nil
    }

    func upgradeModuleDependency(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runGoCommand("get \(trimmed)", named: "go get \(trimmed)", log: "Upgrading \(trimmed) in")
    }

    func runGoGenerate(forPath path: String? = nil) {
        if let path, !path.isEmpty, path.hasSuffix(".go") {
            let rel = projectRelativePath(path)
            runGoCommand("generate \(rel)", named: "go generate", log: "Running go generate on \((path as NSString).lastPathComponent) in")
        } else {
            runGoCommand("generate ./...", named: "go generate", log: "Running go generate in")
        }
    }

    func runGoCommand(_ args: String, named name: String, log: String) {
        beginRun("\(log) \((activeWorkspacePath as NSString).lastPathComponent)…", command: name)
        claimCoreEvents(.output)
        saveAllEdited(then: {
            self.agentQueue.async {
                args.withCString { RunGoCommand(UnsafeMutablePointer(mutating: $0)) }
            }
        }, onFailure: {
            self.abortPendingRun()
        })
    }

    private func abortPendingRun() {
        goCommand = nil
        isStartingRun = false
        pendingRunPrelude.removeAll()
    }

    private func beginRun(_ message: String, command: String?) {
        var clean = sanitizeTerminalStream(message)
        if clean.utf8.count > Self.maxLogLineBytes {
            clean = String(decoding: clean.utf8.prefix(Self.maxLogLineBytes), as: UTF8.self) + "…"
        }
        let msg = LogMessage(text: clean, linked: ConsoleLinks.attributed(clean), isStderr: false)
        runFailure = nil
        goCommand = command
        isStartingRun = true
        pendingRunPrelude = [msg]
        selectedRunSessionId = nil
        consoleOutput = [msg]
        consoleOutputBytes = clean.utf8.count
        showConsole = true
        selectedConsoleTab = Self.consoleTab
    }

    func selectRunSession(_ id: Int64) {
        guard let session = runSessions.first(where: { $0.id == id }) else { return }
        selectedRunSessionId = id
        consoleOutput = session.output
        consoleOutputBytes = session.outputBytes
        runFailure = session.failure
    }

    func stopRunSession(_ id: Int64) {
        if let idx = runSessions.firstIndex(where: { $0.id == id }) {
            runSessions[idx].isRunning = false
            stopDockerContainer(runKey: runSessions[idx].key)
        }
        SandboxVMManager.shared.stopForwardingAllPorts()
        agentQueue.async {
            StopProgramRun(id)
        }
    }

    func closeRunSession(_ id: Int64) {
        guard let idx = runSessions.firstIndex(where: { $0.id == id }) else { return }
        let wasRunning = runSessions[idx].isRunning
        if wasRunning { stopDockerContainer(runKey: runSessions[idx].key) }
        runSessions.remove(at: idx)
        if wasRunning {
            SandboxVMManager.shared.stopForwardingAllPorts()
            agentQueue.async {
                StopProgramRun(id)
            }
        }
        if selectedRunSessionId == id {
            if let next = runSessions.last(where: \.isRunning) ?? runSessions.last {
                selectRunSession(next.id)
            } else {
                selectedRunSessionId = nil
                consoleOutput.removeAll()
                consoleOutputBytes = 0
                runFailure = nil
            }
        }
    }

    func resetRunSessions() {
        isStartingRun = false
        pendingRunPrelude = []
        let owned = Set(runSessions.map(\.id) + ownedTaskIDs())
        runSessions.removeAll()
        selectedRunSessionId = nil
        agentQueue.async {
            for id in owned where id > 0 {
                StopProgramRun(id)
            }
        }
    }

    func clearConsoleOutput() {
        consoleOutput.removeAll()
        consoleOutputBytes = 0
        runFailure = nil
        if let activeId = selectedRunSessionId, let idx = runSessions.firstIndex(where: { $0.id == activeId }) {
            runSessions[idx].output.removeAll()
            runSessions[idx].outputBytes = 0
            runSessions[idx].failure = nil
        }
    }

    func sendProgramStdin(_ text: String, runId: Int64? = nil) {
        let targetId: Int64
        if let runId {
            targetId = runId
        } else if let selected = selectedRunSessionId,
                  runSessions.contains(where: { $0.id == selected && $0.isRunning }) {
            targetId = selected
        } else {
            targetId = runSessions.last(where: \.isRunning)?.id ?? 0
        }
        agentQueue.async {
            text.withCString { ptr in
                WriteProgramStdin(targetId, ptr, Int32(text.utf8.count))
            }
        }
    }

    func sendProgramEOF(runId: Int64? = nil) {
        let targetId: Int64
        if let runId {
            targetId = runId
        } else if let selected = selectedRunSessionId,
                  runSessions.contains(where: { $0.id == selected && $0.isRunning }) {
            targetId = selected
        } else {
            targetId = runSessions.last(where: \.isRunning)?.id ?? 0
        }
        agentQueue.async {
            CloseProgramStdin(targetId)
        }
    }

    func appendMessage(_ msg: LogMessage, toSessionAt idx: Int) {
        guard runSessions.indices.contains(idx) else { return }
        runSessions[idx].output.append(msg)
        runSessions[idx].outputBytes += msg.text.utf8.count
        var drop = 0
        var dropped = 0
        let out = runSessions[idx].output
        let totalBytes = runSessions[idx].outputBytes
        while out.count - drop > Self.maxLogLines || totalBytes - dropped > Self.maxLogBytes {
            dropped += out[drop].text.utf8.count
            drop += 1
        }
        if drop > 0 {
            runSessions[idx].output.removeFirst(max(drop, out.count / 4))
            runSessions[idx].outputBytes = runSessions[idx].output.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    func appendLog(_ message: String, isStderr: Bool = false) {
        var clean = sanitizeTerminalStream(message)
        if clean.utf8.count > Self.maxLogLineBytes {
            clean = String(decoding: clean.utf8.prefix(Self.maxLogLineBytes), as: UTF8.self) + "…"
        }
        runnerLogLock.lock()
        pendingLogEntries.append((text: clean, isStderr: isStderr), limit: Self.maxLogLines)
        let shouldSchedule = !logDrainScheduled
        if shouldSchedule {
            logDrainScheduled = true
        }
        runnerLogLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runnerLogLock.lock()
                let batch = self.pendingLogEntries.drain()
                self.logDrainScheduled = false
                self.runnerLogLock.unlock()

                for entry in batch {
                    let msg = self.appendConsoleLine(entry.text, isStderr: entry.isStderr)
                    if self.isStartingRun {
                        self.pendingRunPrelude.append(msg)
                    } else if let id = self.selectedRunSessionId,
                              let idx = self.runSessions.firstIndex(where: { $0.id == id }) {
                        self.appendMessage(msg, toSessionAt: idx)
                    }
                    if entry.text == "Process stopped." { self.goCommand = nil }
                    if entry.text.contains("Process exited") && !self.isTestRunning {
                        if entry.text.contains("successfully") {
                            if self.goCommand == "Build" { self.showBuildOverlay(.succeeded) }
                        } else {
                            self.runFailure = self.diagnoseRunFailure(exitMessage: entry.text.replacingOccurrences(of: "Process exited with error: ", with: ""))
                        }
                        self.goCommand = nil
                    }
                }
            }
        }
    }

    static let diagnosticLogsKey = "GoLensDebuggerLogging"
    static let coreLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GoLensApp", category: "core")

    func appendDiagnosticLog(_ message: String) {
        Self.coreLog.info("\(message, privacy: .public)")
        if UserDefaults.standard.bool(forKey: Self.diagnosticLogsKey) {
            appendLog(message)
        }
    }

    static let maxLogLines = 2000
    static let maxLogBytes = 1 << 20
    static let maxLogLineBytes = 4096

    @discardableResult
    static func consoleMessage(_ raw: String, isStderr: Bool) -> LogMessage {
        var clean = sanitizeTerminalStream(raw)
        if clean.utf8.count > maxLogLineBytes {
            clean = String(decoding: clean.utf8.prefix(maxLogLineBytes), as: UTF8.self) + "…"
        }
        return LogMessage(text: clean, linked: ConsoleLinks.attributed(clean), isStderr: isStderr)
    }

    func appendConsoleLine(_ line: String, isStderr: Bool) -> LogMessage {
        let msg = LogMessage(text: line, linked: ConsoleLinks.attributed(line), isStderr: isStderr)
        appendConsoleMessage(msg)
        return msg
    }

    func appendConsoleMessage(_ msg: LogMessage) {
        let line = msg.text
        consoleOutput.append(msg)
        consoleOutputBytes += line.utf8.count
        var drop = 0
        var dropped = 0
        while consoleOutput.count - drop > Self.maxLogLines || consoleOutputBytes - dropped > Self.maxLogBytes {
            dropped += consoleOutput[drop].text.utf8.count
            drop += 1
        }
        if drop > 0 {
            consoleOutput.removeFirst(max(drop, consoleOutput.count / 4))
            consoleOutputBytes = consoleOutput.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    func showBuildOverlay(_ status: BuildStatus) {
        switch status {
        case .succeeded: lastActivity = FinishedActivity(title: "Build Succeeded", failed: false, date: Date())
        case .failed: lastActivity = FinishedActivity(title: "Build Failed", failed: true, date: Date())
        case .testsSucceeded: lastActivity = FinishedActivity(title: "Tests Passed", failed: false, date: Date())
        case .testsFailed: lastActivity = FinishedActivity(title: "Tests Failed", failed: true, date: Date())
        }
    }

    func handleDebugEvent(name eventName: String, jsonStr: String) {
        if eventName == "stopped" {
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? [String: Any],
                  let threadId = body["threadId"] as? Int else { return }
            let tid = Int32(threadId)
            let reason = body["reason"] as? String ?? ""
            DispatchQueue.main.async {
                if reason.contains("breakpoint") { GetStartedProgress.shared.complete(.stopAtBreakpoint) }
                self.debug.isPaused = true
                self.debug.activeThreadId = tid
                self.debug.exceptionMessage = nil
                self.fetchDebugState(for: tid)
                self.fetchGoroutineGroups()
                if !self.debug.revealedOnPause {
                    self.debug.revealedOnPause = true
                    self.showConsole = true
                    self.selectedConsoleTab = Self.debuggerTab
                }
            }
            if reason == "exception" || reason == "panic" {
                DispatchQueue.global(qos: .userInitiated).async {
                    var message = body["description"] as? String ?? "Paused on panic"
                    if let c = DebugExceptionInfo(Int32(threadId)) {
                        let json = String(cString: c)
                        FreeGoCString(c)
                        if let info = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                            message = [info["exceptionId"] as? String, info["description"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                        }
                    }
                    DispatchQueue.main.async {
                        self.debug.exceptionMessage = message
                        self.appendLog(message)
                    }
                }
            }
        } else if eventName == "continued" {
            DispatchQueue.main.async {
                self.clearDebugPauseState()
            }
        } else if eventName == "output" {
            struct OutputEventBody: Codable { let output: String; let category: String? }
            struct OutputEvent: Codable { let body: OutputEventBody? }
            if let data = jsonStr.data(using: .utf8),
               let event = try? JSONDecoder().decode(OutputEvent.self, from: data),
               let body = event.body {
                let text = body.output.trimmingCharacters(in: .newlines)
                if text.contains("Detaching without terminating") {
                    self.appendLog(text)
                } else if body.category == "console" || (body.category == "stdout" && text.hasPrefix("Building ") && !self.debug.revealedOnPause) {
                    self.appendDiagnosticLog(text)
                } else {
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        self.appendLog(String(line), isStderr: body.category == "stderr")
                    }
                }
            }
        } else if eventName == "exited" {
            struct ExitedBody: Codable { let exitCode: Int }
            struct ExitedEvent: Codable { let body: ExitedBody? }
            let code = jsonStr.data(using: .utf8).flatMap { try? JSONDecoder().decode(ExitedEvent.self, from: $0) }?.body?.exitCode
            DispatchQueue.main.async {
                self.clearDebugPauseState()
                if let code {
                    self.appendLog("Debugger finished with the exit code \(code)")
                }
            }
        } else if eventName == "terminated" {
            agentQueue.async { DebugStop() }
            DispatchQueue.main.async {
                self.clearDebugPauseState()
                self.debug.isDebugMode = false
                self.debug.functionBreakpointProblems = [:]
                self.debug.activeThreadId = 1
                self.debug.threads = []
                self.debug.goroutineGroups = []
                if self.selectedConsoleTab == Self.debuggerTab { self.selectedConsoleTab = Self.consoleTab }
            }
        }
    }

}

struct PendingLogQueue {
    private var entries: [(text: String, isStderr: Bool)] = []
    private var dropDebt = 0
    private var droppable = 0

    private static func isDroppable(_ text: String) -> Bool {
        !text.contains("Process exited") && text != "Process stopped."
    }

    mutating func append(_ entry: (text: String, isStderr: Bool), limit: Int) {
        let canDrop = Self.isDroppable(entry.text)
        if canDrop, entries.count - dropDebt >= limit, droppable > 0 {
            dropDebt += 1
            droppable -= 1
        }
        entries.append(entry)
        if canDrop { droppable += 1 }
        if dropDebt >= max(limit, 1) { compact() }
    }

    mutating func drain() -> [(text: String, isStderr: Bool)] {
        compact()
        let batch = entries
        entries.removeAll(keepingCapacity: true)
        droppable = 0
        return batch
    }

    private mutating func compact() {
        guard dropDebt > 0 else { return }
        var remaining = dropDebt
        entries.removeAll { entry in
            guard remaining > 0, Self.isDroppable(entry.text) else { return false }
            remaining -= 1
            return true
        }
        dropDebt = 0
    }
}
