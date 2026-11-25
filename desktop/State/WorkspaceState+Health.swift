import Foundation
import AppKit
import GoLensFoundation
import os
import SwiftUI

enum LanguageServerState: Equatable {
    case idle
    case starting
    case indexing(String)
    case ready
    case crashed(String, retryIn: Int)
    case restarting
    case missing
}

struct ToolchainHealthInfo: Decodable, Equatable {
    let goVersion: String
    let toolchain: String
    let toolchainSource: String
    let effective: String
    let required: String
    let directive: String
    let requiredBy: String
    let goplsPath: String
    let goplsGo: String
    let goTooOld: Bool
    let goplsOutdated: Bool
    let buildWith: String

    static func display(_ version: String) -> String {
        var v = version.hasPrefix("go") ? String(version.dropFirst(2)) : version
        if v.hasSuffix(".0"), v.split(separator: ".").count == 3 {
            v.removeLast(2)
        }
        return v
    }
}

enum WorkspaceIssue: Equatable {
    case goMissing
    case goTooOld(ToolchainHealthInfo)
    case goplsMissing
    case goplsOutdated(ToolchainHealthInfo)
    case goplsCrashed(String, retryIn: Int)
    case goplsRestarting
    case modulesOffline(String)
    case noModule
    case starting
    case indexing(String)

    var isInProgress: Bool {
        switch self {
        case .starting, .indexing, .goplsRestarting: return true
        default: return false
        }
    }
}

struct RunFailure: Equatable {
    enum Kind: Equatable {
        case build
        case exited
        case toolchainMissing
        case command(String)
        case remote(RemoteIssue)
        case oomKilled(memoryLimit: String)
    }
    let kind: Kind
    let errorCount: Int
    let firstErrorURL: URL?
    let detail: String
}

extension WorkspaceState {
    static let goplsInstallCommand = "go install golang.org/x/tools/gopls@latest"

    var workspaceIssue: WorkspaceIssue? {
        guard !activeWorkspacePath.isEmpty else { return nil }
        if goToolchainMissing { return .goMissing }
        if let health = toolchainHealth, health.goTooOld { return .goTooOld(health) }
        switch languageServerState {
        case .missing: return .goplsMissing
        case .crashed(let reason, let retryIn): return .goplsCrashed(reason, retryIn: retryIn)
        case .restarting: return .goplsRestarting
        default: break
        }
        if let health = toolchainHealth, health.goplsOutdated { return .goplsOutdated(health) }
        if let error = moduleDownloadError { return .modulesOffline(error) }
        switch languageServerState {
        case .starting: return .starting
        case .indexing(let title): return .indexing(title)
        default: break
        }
        if !hasGoModule { return .noModule }
        return nil
    }

    func refreshWorkspaceHealth(then completion: (() -> Void)? = nil) {
        let root = activeWorkspacePath
        guard !root.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let goPath = Self.findTool("go")
            var dir = root
            var hasModule = false
            while !dir.isEmpty {
                if ["go.mod", "go.work"].contains(where: { FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }) {
                    hasModule = true
                    break
                }
                if dir == "/" { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            if !hasModule, let children = try? FileManager.default.contentsOfDirectory(atPath: root) {
                let excluded: Set<String> = ["node_modules", "vendor", "venv", "__pycache__", "testdata", "DerivedData"]
                for child in children where !child.hasPrefix(".") && !excluded.contains(child) {
                    let sub = (root as NSString).appendingPathComponent(child)
                    if ["go.mod", "go.work"].contains(where: { FileManager.default.fileExists(atPath: (sub as NSString).appendingPathComponent($0)) }) {
                        hasModule = true
                        break
                    }
                }
            }
            let health: ToolchainHealthInfo? = root.withCString { r in
                guard let out = ToolchainHealth(r) else { return nil }
                defer { FreeGoCString(out) }
                return try? JSONDecoder().decode(ToolchainHealthInfo.self, from: Data(String(cString: out).utf8))
            }
            DispatchQueue.main.async {
                guard let self, self.activeWorkspacePath == root else { return }
                self.goToolchainMissing = goPath == nil
                self.hasGoModule = hasModule
                self.toolchainHealth = health
                completion?()
            }
        }
    }

    static func goplsUpdateArguments(buildWith: String) -> [String] {
        ["GOTOOLCHAIN=\(buildWith.isEmpty ? "auto" : buildWith + "+auto")", "go", "install", "golang.org/x/tools/gopls@latest"]
    }

    func updateGopls(buildWith: String) {
        runExternalCommand(["env"] + Self.goplsUpdateArguments(buildWith: buildWith), in: NSHomeDirectory(), key: "gopls:update")
    }

    func goplsUpdateExited(state: String) {
        guard state == "exited" else { return }
        restartLanguageServer()
        refreshWorkspaceHealth { [weak self] in
            guard let self, let health = self.toolchainHealth, health.goplsOutdated else { return }
            self.appendLog("gopls at \(health.goplsPath) is still built with Go \(ToolchainHealthInfo.display(health.goplsGo)). go install put the new gopls in the folder `go env GOBIN` names (or GOPATH/bin, usually ~/go/bin); move that folder ahead of \((health.goplsPath as NSString).deletingLastPathComponent) on PATH, or remove the old gopls, then restart GoLens.", isStderr: true)
        }
    }

    @MainActor
    func allowAutomaticToolchain() async -> String? {
        let message = await Task.detached(priority: .userInitiated) { () -> String in
            guard let out = AllowAutomaticToolchain() else { return "" }
            defer { FreeGoCString(out) }
            return String(cString: out)
        }.value
        refreshWorkspaceHealth()
        return message.isEmpty ? nil : message
    }

    func suppressRunnerLog(_ text: String, isStderr: Bool) {
        runnerLogLock.lock()
        defer { runnerLogLock.unlock() }
        if suppressedRunnerLogs.count >= 256 {
            suppressedRunnerLogs.removeFirst(suppressedRunnerLogs.count - 255)
        }
        suppressedRunnerLogs.append((text, isStderr))
    }

    func consumeSuppressedRunnerLog(_ text: String, isStderr: Bool) -> Bool {
        runnerLogLock.lock()
        defer { runnerLogLock.unlock() }
        guard let idx = suppressedRunnerLogs.firstIndex(where: { $0.text == text && $0.isStderr == isStderr }) else {
            return false
        }
        suppressedRunnerLogs.remove(at: idx)
        return true
    }

    func handleStatusEvent(topic: String, payload: String) {
        if topic == "gitTouchSecurityKey" {
            let waiting = payload.trimmingCharacters(in: .whitespacesAndNewlines) == "waiting"
            DispatchQueue.main.async {
                GitSigningStore.shared.isWaitingForSecurityKeyTouch = waiting
            }
            return
        }
        if topic == "remoteTouchSecurityKey" {
            let host = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                GitSigningStore.shared.remoteTouchHost = (host.isEmpty || host == "done") ? nil : host
            }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
        switch topic {
        case "languageServer":
            let detail = object["detail"] as? String ?? ""
            let state: LanguageServerState
            switch object["state"] as? String {
            case "starting": state = .starting
            case "indexing": state = .indexing(detail)
            case "ready": state = .ready
            case "restarting": state = .restarting
            case "missing": state = .missing
            case "crashed":
                let parts = detail.split(separator: "|", maxSplits: 1).map(String.init)
                state = .crashed(parts.first ?? "", retryIn: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
            default: state = .idle
            }
            let reportedRemote = object["remote"] as? Bool
            DispatchQueue.main.async {
                let wasReady = self.languageServerState == .ready
                self.languageServerState = state
                self.updateLanguageServerConditions(reportedRemote: reportedRemote)
                if state == .ready {
                    NotificationCenter.default.post(name: .golensLanguageServerReady, object: nil)
                    if !wasReady { self.languageServerDidBecomeReady() }
                }
            }
        case "terminalExit":
            guard let id = object["id"] as? String else { return }
            let code = (object["code"] as? NSNumber)?.int32Value ?? -1
            DispatchQueue.main.async {
                if let index = self.terminalSessions.firstIndex(where: { $0.id == id }) {
                    self.terminalSessions[index].exitCode = code
                }
            }
        case "remoteIssue":
            handleRemoteIssue(payload)
        case "database":
            handleDatabaseEvent(payload)
        case "taskLog":
            guard let lines = object["lines"] as? [[String: Any]] else { return }
            for line in lines {
                guard let text = line["text"] as? String else { continue }
                let isStderr = line["stderr"] as? Bool ?? false
                if consumeSuppressedRunnerLog(text, isStderr: isStderr) { continue }
                appendLog(text, isStderr: isStderr)
            }
        case "runEvent":
            let state = object["state"] as? String
            if state == nil, let lines = object["lines"] as? [[String: Any]] {
                let id = object["id"] ?? NSNumber(value: 0)
                enqueueRunEvents(lines.map { line in
                    ["id": id, "text": line["text"] as? String ?? "", "stderr": line["stderr"] as? Bool ?? false]
                })
                return
            }
            if state == nil, let text = object["text"] as? String {
                let isStderr = object["stderr"] as? Bool ?? false
                suppressRunnerLog(text, isStderr: isStderr)
            } else if let state, state != "started" {
                let errStr = object["error"] as? String ?? ""
                let exitLine: String
                switch state {
                case "stopped": exitLine = "Process stopped."
                case "failed": exitLine = "Process exited with error: \(errStr)"
                default: exitLine = "Process exited successfully."
                }
                suppressRunnerLog(exitLine, isStderr: false)
            }
            enqueueRunEvent(object)
        case "testProfile":
            struct AppProfileReply: Decodable {
                let cpu: [ProfileEntry]?
                let mem: [ProfileEntry]?
                let cpuProfile: [ProfileEntry]?
                let memProfile: [ProfileEntry]?
                let block: [ProfileEntry]?
                let mutex: [ProfileEntry]?
                let blockProfile: [ProfileEntry]?
                let mutexProfile: [ProfileEntry]?
            }
            if let reply = try? JSONDecoder().decode(AppProfileReply.self, from: Data(payload.utf8)) {
                let cpu = reply.cpu ?? reply.cpuProfile ?? []
                let mem = reply.mem ?? reply.memProfile ?? []
                let block = reply.block ?? reply.blockProfile ?? []
                let mutex = reply.mutex ?? reply.mutexProfile ?? []
                DispatchQueue.main.async {
                    self.cpuProfileEntries = Array(cpu.prefix(Self.maxProfileEntries))
                    self.memProfileEntries = Array(mem.prefix(Self.maxProfileEntries))
                    self.blockProfileEntries = Array(block.prefix(Self.maxProfileEntries))
                    self.mutexProfileEntries = Array(mutex.prefix(Self.maxProfileEntries))
                    self.hasProfileData = !self.cpuProfileEntries.isEmpty || !self.memProfileEntries.isEmpty || !self.blockProfileEntries.isEmpty || !self.mutexProfileEntries.isEmpty
                    self.showConsole = true
                    self.selectedConsoleTab = Self.profilerTab
                    self.activeTextView?.needsDisplay = true
                    (self.activeTextView as? GoLensTextView)?.redrawGutter()
                }
            }
        case "kernelTelemetry":
            do {
                let telemetry = try KernelTelemetry.decode(Data(payload.utf8))
                DispatchQueue.main.async {
                    self.kernelTelemetry = telemetry
                }
            } catch {
                Self.coreLog.error("kernel telemetry decode failed: \(String(describing: error), privacy: .public)")
            }
        default:
            break
        }
    }

    func enqueueRunEvent(_ object: [String: Any]) {
        enqueueRunEvents([object])
    }

    func enqueueRunEvents(_ events: [[String: Any]]) {
        guard !events.isEmpty else { return }
        let objects = events.map { event -> [String: Any] in
            guard event["state"] == nil, let text = event["text"] as? String else { return event }
            var prepared = event
            prepared["message"] = Self.consoleMessage(text, isStderr: event["stderr"] as? Bool ?? false)
            return prepared
        }
        runnerLogLock.lock()
        var count = pendingRunEvents.count
        var outputs = pendingRunEvents.reduce(0) { $0 + ($1["state"] == nil ? 1 : 0) }
        var drops = 0
        for object in objects {
            let isOutput = object["state"] == nil
            if isOutput, count >= Self.maxLogLines, outputs > 0 {
                drops += 1
                outputs -= 1
                count -= 1
            }
            count += 1
            if isOutput { outputs += 1 }
        }
        pendingRunEvents.append(contentsOf: objects)
        if drops > 0 {
            var remaining = drops
            pendingRunEvents.removeAll { event in
                guard remaining > 0, event["state"] == nil else { return false }
                remaining -= 1
                return true
            }
        }
        let shouldSchedule = !runEventDrainScheduled
        if shouldSchedule {
            runEventDrainScheduled = true
        }
        runnerLogLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.runnerLogLock.lock()
                let batch = self.pendingRunEvents
                self.pendingRunEvents.removeAll(keepingCapacity: true)
                self.runEventDrainScheduled = false
                self.runnerLogLock.unlock()

                for ev in batch {
                    self.handleRunEvent(ev)
                }
            }
        }
    }

    func handleRunEvent(_ object: [String: Any]) {
        guard let id = (object["id"] as? NSNumber)?.int64Value else { return }
        let state = object["state"] as? String

        if state == "started" {
            let key = object["key"] as? String ?? ""
            let title = object["title"] as? String ?? "program"
            let dir = object["dir"] as? String ?? activeWorkspacePath
            let prelude = isStartingRun ? pendingRunPrelude : []
            let preludeBytes = prelude.reduce(0) { $0 + $1.text.utf8.count }
            isStartingRun = false
            pendingRunPrelude = []

            runSessions.removeAll { $0.id == id || $0.key == key || (!$0.isRunning && $0.key.hasPrefix("cmd:")) }
            while runSessions.count >= Self.maxRunSessions {
                if let stoppedIdx = runSessions.firstIndex(where: { !$0.isRunning }) {
                    runSessions.remove(at: stoppedIdx)
                } else {
                    runSessions.removeFirst()
                }
            }

            let session = RunSession(
                id: id,
                key: key,
                title: title,
                dir: dir,
                isRunning: true,
                output: prelude,
                outputBytes: preludeBytes,
                failure: nil
            )
            runSessions.append(session)
            selectedRunSessionId = id
            consoleOutput = session.output
            consoleOutputBytes = session.outputBytes
            runFailure = nil
            return
        }

        if state == nil, let msg = object["message"] as? LogMessage ?? (object["text"] as? String).map({ Self.consoleMessage($0, isStderr: object["stderr"] as? Bool ?? false) }) {
            if let idx = runSessions.firstIndex(where: { $0.id == id }) {
                appendMessage(msg, toSessionAt: idx)
                if selectedRunSessionId == id {
                    appendConsoleMessage(msg)
                }
            } else if selectedRunSessionId == nil {
                appendConsoleMessage(msg)
            }
            return
        }

        if let state {
            let key = object["key"] as? String ?? ""
            let title = object["title"] as? String ?? "program"
            let errStr = object["error"] as? String ?? ""
            let exitLine: String
            switch state {
            case "stopped": exitLine = "Process stopped."
            case "failed": exitLine = "Process exited with error: \(errStr)"
            default: exitLine = "Process exited successfully."
            }
            let exitMsg = LogMessage(text: exitLine, linked: ConsoleLinks.attributed(exitLine), isStderr: false)

            if !runSessions.contains(where: { $0.id == id }) && isStartingRun {
                let prelude = pendingRunPrelude
                let preludeBytes = prelude.reduce(0) { $0 + $1.text.utf8.count }
                isStartingRun = false
                pendingRunPrelude = []
                let session = RunSession(
                    id: id,
                    key: key,
                    title: title,
                    dir: activeWorkspacePath,
                    isRunning: false,
                    output: prelude,
                    outputBytes: preludeBytes,
                    failure: nil
                )
                runSessions.append(session)
                selectedRunSessionId = id
            }

            if let idx = runSessions.firstIndex(where: { $0.id == id }) {
                appendMessage(exitMsg, toSessionAt: idx)
                runSessions[idx].isRunning = false
                if !key.hasPrefix("cmd:") && state != "failed" {
                    let sessionTitle = runSessions[idx].title
                    let projectName = (activeWorkspacePath as NSString).lastPathComponent
                    let isDefaultTarget = sessionTitle.isEmpty || sessionTitle == projectName || sessionTitle == "Default"
                    let suffix = isDefaultTarget ? "" : " \(sessionTitle)"
                    lastActivity = FinishedActivity(
                        title: state == "stopped" ? "Stopped\(suffix)" : "Finished Running\(suffix)",
                        failed: false,
                        date: Date()
                    )
                }
                if state == "failed" {
                    let oomKilled = (object["oomKilled"] as? Bool) ?? (object["oomKilled"] as? NSNumber)?.boolValue ?? false
                    let memoryMax = (object["memoryMax"] as? NSNumber)?.uint64Value ?? 0
                    let failure = diagnoseRunFailure(exitMessage: errStr, in: runSessions[idx].output, oomKilled: oomKilled, memoryMax: memoryMax)
                    runSessions[idx].failure = failure
                    if selectedRunSessionId == id {
                        runFailure = failure
                        if case .oomKilled(let limit) = failure.kind {
                            activeOOMFailure = OOMFailureInfo(
                                sessionID: id,
                                targetName: runSessions[idx].title,
                                memoryLimit: limit,
                                detail: failure.detail
                            )
                        }
                    }
                } else {
                    runSessions[idx].failure = nil
                    if selectedRunSessionId == id {
                        activeOOMFailure = nil
                    }
                    if state == "exited" && goCommand == "Build" {
                        showBuildOverlay(.succeeded)
                    }
                    if pendingTidyAfterGoGet.remove(key) != nil, state == "exited" {
                        tidyModule()
                    }
                }
                if selectedRunSessionId == id {
                    _ = appendConsoleLine(exitLine, isStderr: false)
                }
                if key.hasPrefix("cmd:") {
                    goCommand = nil
                    if runSessions.count > 1 {
                        runSessions.remove(at: idx)
                    }
                }
            } else if !isStartingRun {
                _ = appendConsoleLine(exitLine, isStderr: false)
                if state == "failed" {
                    let oomKilled = (object["oomKilled"] as? Bool) ?? (object["oomKilled"] as? NSNumber)?.boolValue ?? false
                    let memoryMax = (object["memoryMax"] as? NSNumber)?.uint64Value ?? 0
                    let failure = diagnoseRunFailure(exitMessage: errStr, oomKilled: oomKilled, memoryMax: memoryMax)
                    runFailure = failure
                    if case .oomKilled(let limit) = failure.kind {
                        activeOOMFailure = OOMFailureInfo(
                            sessionID: 0,
                            targetName: "Target",
                            memoryLimit: limit,
                            detail: failure.detail
                        )
                    }
                } else if state == "exited" && goCommand == "Build" {
                    showBuildOverlay(.succeeded)
                }
                if key.hasPrefix("cmd:") {
                    goCommand = nil
                }
            }

            if key.hasPrefix("docker:build:") {
                dockerBuildRunExited(key: key, state: state, output: runSessions.first { $0.id == id }?.output ?? [])
            }
            if key.hasPrefix("sqlc:") {
                sqlcGenerateExited(state: state)
            }
            if key == "gopls:update" {
                goplsUpdateExited(state: state)
            }
            let stillRunning = isStartingRun || isTestRunning || debug.isDebugMode || runSessions.contains(where: \.isRunning)
            if stillRunning == false && state == "exited" && key.hasPrefix("cmd:go generate") && !activeWorkspacePath.isEmpty {
                loadFiles(from: activeWorkspacePath)
            }
        }
    }

    func restartLanguageServer() {
        languageServerState = .restarting
        DispatchQueue.global(qos: .userInitiated).async { RestartLanguageServer() }
    }

    func restartTerminalSession(_ id: String) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == id }) else { return }
        let title = terminalSessions[index].title
        if let engine = terminalEngines.removeValue(forKey: id) {
            engine.terminalDelegate = nil
            engine.removeFromSuperview()
        }
        DispatchQueue.global(qos: .utility).async { id.withCString { CloseTerminal($0) } }
        let session = TerminalSession(id: UUID().uuidString, title: title)
        terminalSessions[index] = session
        selectedTerminalId = session.id
    }

    @MainActor
    func createGoModule(named module: String) async -> String? {
        let root = activeWorkspacePath
        let output = await runGoCommand(["mod", "init", module], in: root)
        refreshWorkspaceHealth()
        loadFiles(from: root)
        return output.status == 0 ? nil : output.text
    }

    func retryModuleDownload() async -> String? {
        let output = await runGoCommand(["mod", "download"], in: activeWorkspacePath)
        if output.status == 0 {
            moduleDownloadError = nil
            return nil
        }
        if !Self.isNetworkFailure(output.text) { moduleDownloadError = nil }
        return output.text
    }

    func noteModuleError(_ message: String) {
        if Self.isNetworkFailure(message) {
            moduleDownloadError = message
        }
    }

    static func findTool(_ name: String) -> String? {
        let path: String = name.withCString { n in
            guard let c = FindTool(n) else { return "" }
            defer { FreeGoCString(c) }
            return String(cString: c)
        }
        return path.isEmpty ? nil : path
    }

    static func isNetworkFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["dial tcp", "no such host", "network is unreachable", "i/o timeout", "tls handshake timeout", "connection refused"].contains { lower.contains($0) }
    }

    private func runGoCommand(_ args: [String], in dir: String) async -> (status: Int32, text: String) {
        if args.count >= 3 && args[0] == "mod" && args[1] == "init" {
            let module = args[2]
            let goModURL = URL(fileURLWithPath: dir).appendingPathComponent("go.mod")
            let content = "module \(module)\n\ngo 1.22\n"
            do {
                try content.write(to: goModURL, atomically: true, encoding: .utf8)
                return (0, "")
            } catch {
                return (-1, error.localizedDescription)
            }
        }
        return (0, "")
    }
}

func goStatusEventCallback(topic: UnsafePointer<CChar>?, payload: UnsafePointer<CChar>?) {
    guard let topic, let payload else { return }
    let topicText = String(cString: topic)
    let payloadText = String(cString: payload)
    measureLog("status \(topicText) \(payloadText)")
    for target in WorkspaceState.statusEventTargets(topic: topicText, payload: payloadText) {
        target.handleStatusEvent(topic: topicText, payload: payloadText)
    }
}
