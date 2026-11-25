import AppKit
import Foundation

struct RemoteIssue: Decodable, Equatable {
    var code: String = ""
    var title: String = ""
    var message: String = ""
    var fix: String = ""
    var fixTitle: String = ""
    var command: String = ""
    var detail: String = ""
    var target: RunTarget = .local

    enum CodingKeys: String, CodingKey {
        case code, title, message, fix, fixTitle, command, detail, target
    }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        code = string(.code)
        title = string(.title)
        message = string(.message)
        fix = string(.fix)
        fixTitle = string(.fixTitle)
        command = string(.command)
        detail = string(.detail)
        target = (try? c.decodeIfPresent(RunTarget.self, forKey: .target)) ?? .local
    }
}

struct RemoteProbe: Decodable, Equatable {
    var machine: String = ""
    var goarch: String = ""
    var go: String = ""
    var goVersion: String = ""
    var dlv: String = ""

    enum CodingKeys: String, CodingKey { case machine, goarch, go, goVersion, dlv }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        machine = string(.machine)
        goarch = string(.goarch)
        go = string(.go)
        goVersion = string(.goVersion)
        dlv = string(.dlv)
    }

    var summary: String {
        var parts = ["linux/\(goarch.isEmpty ? machine : goarch)"]
        parts.append(go.isEmpty ? "no Go" : (goVersion.isEmpty ? "Go" : goVersion.replacingOccurrences(of: "go", with: "Go ")))
        parts.append(dlv.isEmpty ? "no Delve" : "Delve")
        return parts.joined(separator: " · ")
    }
}

struct RemoteCheckResult: Decodable, Equatable {
    var ok = false
    var label = ""
    var probe = RemoteProbe()
    var issue: RemoteIssue?

    enum CodingKeys: String, CodingKey { case ok, label, probe, issue }

    init(issue: RemoteIssue) {
        self.issue = issue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        probe = (try? c.decodeIfPresent(RemoteProbe.self, forKey: .probe)) ?? RemoteProbe()
        issue = try? c.decodeIfPresent(RemoteIssue.self, forKey: .issue)
    }
}

struct ComposeServiceList: Decodable, Equatable {
    var file = ""
    var services: [String] = []
    var error: String?
}

enum RemoteAction {
    case run, test, debug
}

@Observable
final class RunTargetState {
    static let shared = RunTargetState()

    var compose = ComposeServiceList()
    var isLoadingServices = false
    var checking: Set<UUID> = []
    var checkResults: [UUID: RemoteCheckResult] = [:]
    var requestedKind: RunTarget.Kind?
    @ObservationIgnored var lastAction: RemoteAction = .run
    @ObservationIgnored var pendingTerminalInput: [String: String] = [:]
    @ObservationIgnored var loadedRoot = ""
}

extension WorkspaceState {
    var runTargets: RunTargetState { RunTargetState.shared }

    var activeRunTarget: RunTarget {
        activeRunConfiguration?.runTarget ?? .local
    }

    func addRunTarget(to dict: inout [String: Any], action: RemoteAction) {
        if let config = activeRunConfiguration, config.kind == .go, !config.runTarget.isRemote,
           config.architecture == .amd64, action != .debug, SandboxVMManager.activeMode == .linuxVM {
            dict["architecture"] = config.architecture.rawValue
        }
        guard let config = activeRunConfiguration, config.runTarget.isRemote else { return }
        dict["target"] = config.runTarget.jsonObject
        runTargets.lastAction = action
        if action == .test {
            dict["name"] = config.name
            dict["envVars"] = resolvedEnvVars(for: config)
            dict["buildFlags"] = config.buildFlags
        }
    }

    func discoverComposeFiles() -> [String] {
        let names: Set<String> = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        return allWorkspaceRelativeFilePaths()
            .filter { names.contains(($0 as NSString).lastPathComponent) || ($0 as NSString).lastPathComponent.hasPrefix("docker-compose.") && ($0.hasSuffix(".yml") || $0.hasSuffix(".yaml")) }
            .sorted { a, b in
                let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                return da == db ? a < b : da < db
            }
    }

    func loadComposeServices(file: String = "", force: Bool = false) {
        let root = activeWorkspacePath
        guard !root.isEmpty else { return }
        let state = runTargets
        if !force, state.loadedRoot == root, state.compose.file.hasSuffix(file), !state.isLoadingServices, state.compose.error == nil, !state.compose.services.isEmpty { return }
        state.isLoadingServices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list: ComposeServiceList = root.withCString { r in
                file.withCString { f in
                    guard let out = ComposeServices(r, f) else { return ComposeServiceList(error: "No answer from the backend.") }
                    defer { FreeGoCString(out) }
                    return (try? JSONDecoder().decode(ComposeServiceList.self, from: Data(String(cString: out).utf8))) ?? ComposeServiceList(error: "Couldn’t read the compose services.")
                }
            }
            DispatchQueue.main.async {
                state.compose = list
                state.loadedRoot = root
                state.isLoadingServices = false
            }
        }
    }

    func checkRunTarget(_ config: RunConfiguration) {
        let root = activeWorkspacePath
        let json = config.target.jsonString
        let state = runTargets
        state.checking.insert(config.id)
        state.checkResults[config.id] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: RemoteCheckResult = root.withCString { r in
                json.withCString { t in
                    guard let out = RemoteCheckTarget(r, t) else { return RemoteCheckResult(issue: RemoteIssue(title: "Couldn’t Check", message: "No answer from the backend.")) }
                    defer { FreeGoCString(out) }
                    return (try? JSONDecoder().decode(RemoteCheckResult.self, from: Data(String(cString: out).utf8))) ?? RemoteCheckResult(issue: RemoteIssue(title: "Couldn’t Check", message: "The check returned an unreadable answer."))
                }
            }
            DispatchQueue.main.async {
                state.checking.remove(config.id)
                state.checkResults[config.id] = result
            }
        }
    }

    func setActiveRunTarget(_ target: RunTarget) {
        if var config = activeRunConfiguration {
            if config.kind != .go { return }
            config.target = target
            updateRunConfiguration(config)
            activeRunConfigId = config.id
        } else {
            let config = RunConfiguration(name: "Default", envVars: [:], buildFlags: "", args: "", workingDirectory: "", envFilePath: discoverWorkspaceEnvFiles().first ?? "", target: target)
            updateRunConfiguration(config)
            activeRunConfigId = config.id
            saveRunConfigurations()
        }
        runFailure = nil
    }

    var knownSSHTargets: [RunTarget] {
        var seen = Set<String>()
        var out: [RunTarget] = []
        for config in runConfigurations where config.target.kind == .ssh && !config.target.host.isEmpty {
            let key = "\(config.target.host):\(config.target.port)"
            if seen.insert(key).inserted { out.append(config.target) }
        }
        return out
    }

    func handleRemoteIssue(_ payload: String) {
        guard let issue = try? JSONDecoder().decode(RemoteIssue.self, from: Data(payload.utf8)) else { return }
        DispatchQueue.main.async {
            self.isStartingRun = false
            self.pendingRunPrelude.removeAll()
            self.goCommand = nil
            self.revealConsole()
            self.runFailure = RunFailure(kind: .remote(issue), errorCount: 0, firstErrorURL: nil, detail: issue.message)
        }
    }

    func performRemoteFix(_ issue: RemoteIssue) {
        runFailure = nil
        switch issue.fix {
        case "startService", "installDelve":
            let root = activeWorkspacePath
            let json = issue.target.jsonString
            let fix = issue.fix
            revealConsole()
            appendLog(fix == "startService" ? "Starting \(issue.target.service)…" : "Installing Delve on \(issue.target.title)…")
            agentQueue.async {
                _ = root.withCString { r in json.withCString { t in fix.withCString { f in RemoteFix(r, t, f) } } }
            }
        case "openTerminal":
            openTerminal(running: issue.command)
        case "editDestination":
            showRunConfigurations = true
        case "retry":
            switch runTargets.lastAction {
            case .run: runProject()
            case .test: runAllTests()
            case .debug: debugProject()
            }
        default:
            break
        }
    }

    func openTerminal(running command: String) {
        openTerminal(atDirectory: activeWorkspacePath)
        guard let id = selectedTerminalId, !command.isEmpty else { return }
        runTargets.pendingTerminalInput[id] = command + "\n"
    }

    static func takePendingTerminalInput(_ id: String) -> String? {
        RunTargetState.shared.pendingTerminalInput.removeValue(forKey: id)
    }
}
