import AppKit
import Foundation

struct DockerEngineInfo: Decodable, Equatable {
    var state = "engineDown"
    var cliPath = ""
    var cliVersion = ""
    var composeVersion = ""
    var context = ""
    var endpoint = ""
    var serverVersion = ""
    var provider = ""
    var providerApp = ""
    var error = ""

    enum CodingKeys: String, CodingKey {
        case state, cliPath, cliVersion, composeVersion, context, endpoint, serverVersion, provider, providerApp, error
    }

    init(error: String) {
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        state = string(.state)
        cliPath = string(.cliPath)
        cliVersion = string(.cliVersion)
        composeVersion = string(.composeVersion)
        context = string(.context)
        endpoint = string(.endpoint)
        serverVersion = string(.serverVersion)
        provider = string(.provider)
        providerApp = string(.providerApp)
        error = string(.error)
    }

    var isOK: Bool { state == "ok" }

    func blocks(compose: Bool) -> Bool {
        !isOK && (compose || state != "missingCompose")
    }

    var contextName: String { context.isEmpty ? "default" : context }

    var statusLabel: String {
        state == "missingCLI" ? "Docker: Not Installed" : "Docker: \(contextName)"
    }

    var title: String {
        switch state {
        case "ok": return "Docker Is Ready"
        case "missingCLI": return "Docker Isn’t Installed"
        case "missingCompose": return "Docker Compose Isn’t Available"
        default: return "Docker Engine Isn’t Running"
        }
    }

    var explanation: String {
        switch state {
        case "ok":
            return "Context ‘\(contextName)’ is connected to Docker Engine \(serverVersion)."
        case "missingCLI":
            return "No docker command was found on the PATH. Install OrbStack, Docker Desktop or Colima, then retry."
        case "missingCompose":
            return "The docker compose plugin isn’t installed, so compose files can’t be validated or run. Install the Compose plugin, then retry."
        default:
            if !provider.isEmpty {
                return "Context ‘\(contextName)’ points to \(provider), which isn’t running. Start \(provider), then retry."
            }
            return "Couldn’t reach the Docker engine for context ‘\(contextName)’. Start your Docker engine, then retry."
        }
    }

    var detail: String? {
        guard state == "engineDown", provider.isEmpty else { return nil }
        let parts = [endpoint, error].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }
}

struct DockerfileFix: Decodable {
    struct Edit: Decodable {
        let line: Int
        let col: Int
        let endLine: Int
        let endCol: Int
        let newText: String
    }

    struct NewFile: Decodable {
        let path: String
        let content: String
    }

    let title: String
    let edits: [Edit]?
    let createFile: NewFile?
}

struct DockerfileFinding: Decodable {
    let line: Int
    let col: Int
    let endLine: Int
    let endCol: Int
    let severity: Int
    let code: String?
    let source: String?
    let message: String
    let fixes: [DockerfileFix]?
}

@Observable
final class DockerState {
    static let shared = DockerState()

    var status: DockerEngineInfo?
    var isChecking = false
    @ObservationIgnored var checkedAt = Date.distantPast
    @ObservationIgnored var pendingChecks: [(DockerEngineInfo) -> Void] = []
    @ObservationIgnored var dockerfileFixes: [String: (version: Int, findings: [DockerfileFinding])] = [:]
    var runBlocked = false
    @ObservationIgnored var pendingRuns: [String: DockerRunPlan] = [:]
}

struct DockerRunPlan {
    let dir: String
    let dockerfilePath: String
    let container: String
    let buildArgv: [String]
    let runArgv: [String]

    var buildKey: String { Self.buildKey(dockerfilePath) }
    var runKey: String { Self.runKey(container) }

    static func buildKey(_ dockerfilePath: String) -> String { "docker:build:\(dockerfilePath):|run" }
    static func runKey(_ container: String) -> String { "docker:run:\(container)" }
}

enum DockerCommandLine {
    static func quote(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func line(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    static func split(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
            } else if ch.isWhitespace {
                if inWord { args.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if inWord { args.append(current) }
        return args
    }

    static func containerName(project: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        let name = String(project.lowercased().map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return "golens-" + (name.isEmpty ? "app" : name)
    }

    static func portMappings(_ text: String) -> Result<[String], DockerRunError> {
        let pattern = #"^([0-9.]+:)?[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp|sctp))?$"#
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let entry = String(raw)
            guard entry.range(of: pattern, options: .regularExpression) != nil else {
                return .failure(DockerRunError(message: "Port mapping ‘\(entry)’ isn’t host:container, like 8080:8080."))
            }
            if entry.contains(":") {
                out.append(entry)
            } else {
                let port = entry.split(separator: "/").first.map(String.init) ?? entry
                out.append("\(port):\(entry)")
            }
        }
        return .success(out)
    }

    static func imageTag(folder: String, stage: String?) -> String {
        func sanitize(_ s: String) -> String {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
            let mapped = String(s.lowercased().map { allowed.contains($0) ? $0 : "-" })
                .replacingOccurrences(of: "[._-]{2,}", with: "-", options: .regularExpression)
            return mapped.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        }
        let name = sanitize(folder)
        var tag = "dev"
        if let stage, !stage.isEmpty { tag += "-" + sanitize(stage) }
        return (name.isEmpty ? "app" : name) + ":" + tag
    }

    static func buildFailure(in lines: [String], dockerfileName: String) -> (line: Int?, message: String)? {
        var line: Int?
        var message: String?
        let name = dockerfileName.lowercased()
        for raw in lines {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if let colon = text.lastIndex(of: ":"),
               let n = Int(text[text.index(after: colon)...]), n > 0,
               (String(text[..<colon]) as NSString).lastPathComponent.lowercased() == name {
                line = n - 1
            } else if text.hasPrefix("ERROR:") {
                message = text.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            } else if text.contains("failed to solve:") && message == nil {
                message = text
            }
        }
        guard let message, !message.isEmpty else { return nil }
        return (line, message)
    }
}

extension WorkspaceState {
    var docker: DockerState { DockerState.shared }

    static let dockerBuildSource = "docker build"
    static let composeConfigSource = "docker compose config"
    static let dockerCommandDiagnosticSources: Set<String> = [dockerBuildSource, composeConfigSource]
    private static let dockerStatusCacheSeconds: TimeInterval = 30

    static func isDockerFile(_ path: String) -> Bool {
        EcosystemDocumentTools.isDockerfile(path) || EcosystemDocumentTools.isDockerComposeFile(path)
    }

    var showsDockerStatus: Bool {
        Self.isDockerFile(activeFilePath) || runSessions.contains { $0.key.hasPrefix("docker:") }
    }

    var activeDockerBlocker: DockerEngineInfo? {
        guard let status = docker.status else { return nil }
        if Self.isDockerFile(activeFilePath) {
            return status.blocks(compose: EcosystemDocumentTools.isDockerComposeFile(activeFilePath)) ? status : nil
        }
        guard docker.runBlocked, activeRunConfiguration?.kind == .docker, status.blocks(compose: false) else { return nil }
        return status
    }

    func replaceDiagnostics(at path: String, dropping shouldDrop: (DiagnosticData) -> Bool, with new: [DiagnosticData]) {
        let merged = (diagnostics[path] ?? []).filter { !shouldDrop($0) } + new
        if merged.isEmpty {
            guard diagnostics.removeValue(forKey: path) != nil else { return }
        } else {
            diagnostics[path] = merged
        }
        updateFlatDiagnostics(changedPath: path)
        NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
        (activeTextView as? GoLensTextView)?.needsDisplay = true
    }

    func refreshDockerStatus(force: Bool = false, completion: ((DockerEngineInfo) -> Void)? = nil) {
        if !force, let status = docker.status, Date().timeIntervalSince(docker.checkedAt) < Self.dockerStatusCacheSeconds {
            completion?(status)
            return
        }
        if let completion { docker.pendingChecks.append(completion) }
        guard !docker.isChecking else { return }
        docker.isChecking = true
        let fileDir = Self.isDockerFile(activeFilePath) ? (activeFilePath as NSString).deletingLastPathComponent : ""
        let dir = !fileDir.isEmpty ? fileDir : (activeWorkspacePath.isEmpty ? NSHomeDirectory() : activeWorkspacePath)
        DispatchQueue.global(qos: .userInitiated).async {
            let info = dir.withCString { ptr -> DockerEngineInfo in
                guard let out = DockerEngineStatus(ptr) else { return DockerEngineInfo(error: "Couldn’t read Docker’s status.") }
                defer { FreeGoCString(out) }
                let json = String(cString: out)
                return (try? JSONDecoder().decode(DockerEngineInfo.self, from: Data(json.utf8)))
                    ?? DockerEngineInfo(error: "Couldn’t read Docker’s status: \(json.prefix(200))")
            }
            DispatchQueue.main.async {
                let docker = DockerState.shared
                docker.status = info
                docker.checkedAt = Date()
                docker.isChecking = false
                let waiting = docker.pendingChecks
                docker.pendingChecks.removeAll()
                waiting.forEach { $0(info) }
            }
        }
    }

    func checkDockerEngine() {
        refreshDockerStatus(force: true) { [weak self] info in
            guard let self else { return }
            self.revealConsole()
            if info.isOK {
                self.appendLog("Docker engine is running: context ‘\(info.contextName)’, Docker \(info.serverVersion).")
            } else {
                self.appendLog("\(info.title). \(info.explanation)\(info.detail.map { " \($0)" } ?? "")", isStderr: true)
            }
        }
    }

    func openDockerProvider() {
        guard let status = docker.status, !status.providerApp.isEmpty else { return }
        let url = URL(fileURLWithPath: status.providerApp)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.revealConsole()
                    self.appendLog("Couldn’t open \(status.provider): \(error.localizedDescription)", isStderr: true)
                    return
                }
                for delay in [5.0, 15.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if self.docker.status?.isOK != true { self.refreshDockerStatus(force: true) }
                    }
                }
            }
        }
    }

    func revealConsole() {
        showConsole = true
        selectedConsoleTab = Self.consoleTab
    }

    func runMakeTargetInConsole(makefilePath: String, target: String) {
        let dir = (makefilePath as NSString).deletingLastPathComponent
        let file = (makefilePath as NSString).lastPathComponent
        let argv = file.lowercased() == "makefile" ? ["make", target] : ["make", "-f", file, target]
        runExternalCommand(argv, in: dir, key: "make:\(makefilePath):\(target)")
    }

    func showServicesPanel() {
        if selectedConsoleTab != Self.servicesTab { selectedConsoleTab = Self.servicesTab }
        if !showConsole { showConsole = true }
    }

    var projectComposeFile: String? {
        ServicesStore.shared.composeFile(for: self)
    }

    func confirmComposeDown(composePath: String) {
        let store = ServicesStore.shared
        let folder = ((composePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let fallback = folder.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let project = store.thisProjectName(root: activeWorkspacePath, composeFile: composePath) ?? fallback
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop and Remove the “\(project)” Compose Project?"
        alert.informativeText = "Its containers and networks are removed. Named volumes are kept."
        alert.addButton(withTitle: "Compose Down").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let run = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.runDockerComposeCommand(composePath: composePath, service: nil, action: "down")
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(alert.runModal())
        }
    }

    func runComposeLogs(composePath: String) {
        refreshDockerStatus(force: docker.status?.isOK != true) { [weak self] info in
            guard let self else { return }
            guard !info.blocks(compose: false) else {
                self.revealConsole()
                self.appendLog("Didn’t show the Compose logs: \(info.title). \(info.explanation)", isStderr: true)
                return
            }
            let key = "docker:compose:\(composePath):logs:"
            self.revealConsole()
            self.claimCoreEvents(.output)
            self.agentQueue.async {
                let id = composePath.withCString { p in
                    "Compose Logs".withCString { t in key.withCString { k in DockerComposeLogsRun(p, t, k) } }
                }
                if id == 0 {
                    DispatchQueue.main.async {
                        self.appendLog("Couldn’t follow the logs of \((composePath as NSString).lastPathComponent).", isStderr: true)
                    }
                } else {
                    self.ownTask(id)
                }
            }
        }
    }

    func runDockerComposeCommand(composePath: String, service: String?, action: String) {
        if action == "logs" && (service ?? "").isEmpty {
            runComposeLogs(composePath: composePath)
            return
        }
        let dir = (composePath as NSString).deletingLastPathComponent
        let file = (composePath as NSString).lastPathComponent
        let service = service?.isEmpty == false ? service : nil
        var argv = ["docker", "compose", "-f", file]
        switch action {
        case "up": argv += ["up", "-d"]
        case "rebuild": argv += ["up", "-d", "--build"]
        case "logs": argv += ["logs", "-f", "--tail=200"]
        default: argv.append(action)
        }
        if let service, action != "down" { argv.append(service) }
        runDockerCommand(argv, in: dir, key: "docker:compose:\(composePath):\(action):\(service ?? "")", compose: true)
    }

    func runDockerBuildCommand(dockerfilePath: String, stage: String?) {
        let dir = (dockerfilePath as NSString).deletingLastPathComponent
        let file = (dockerfilePath as NSString).lastPathComponent
        let stage = stage?.isEmpty == false ? stage : nil
        var argv = ["docker", "build", "-f", file]
        if let stage { argv += ["--target", stage] }
        argv += ["-t", DockerCommandLine.imageTag(folder: (dir as NSString).lastPathComponent, stage: stage), "."]
        runDockerCommand(argv, in: dir, key: "docker:build:\(dockerfilePath):\(stage ?? "")", compose: false)
    }

    private func runDockerCommand(_ argv: [String], in dir: String, key: String, compose: Bool) {
        refreshDockerStatus(force: docker.status?.isOK != true) { [weak self] info in
            guard let self else { return }
            guard !info.blocks(compose: compose) else {
                self.revealConsole()
                self.appendLog("Didn’t run \(DockerCommandLine.line(argv)): \(info.title). \(info.explanation)", isStderr: true)
                return
            }
            self.runExternalCommand(argv, in: dir, key: key)
        }
    }

    func runExternalCommand(_ argv: [String], in dir: String, key: String, title: String? = nil, savesEdited: Bool = true, revealsConsole: Bool = true) {
        let title = title ?? DockerCommandLine.line(argv)
        let argvJSON = jsonText(argv)
        if revealsConsole { revealConsole() }
        claimCoreEvents(.output)
        let start = {
            self.agentQueue.async {
                let id = argvJSON.withCString { a in
                    dir.withCString { d in title.withCString { t in key.withCString { k in RunExternalCommand(a, d, t, k) } } }
                }
                if id == 0 {
                    DispatchQueue.main.async {
                        self.appendLog("Couldn’t start \(title) in \((dir as NSString).lastPathComponent).", isStderr: true)
                    }
                } else {
                    self.ownTask(id)
                }
            }
        }
        if savesEdited { saveAllEdited(then: start) } else { start() }
    }

    func copyRunCommand(_ session: RunSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.title, forType: .string)
    }

    func dockerBuildRunExited(key: String, state: String, output: [LogMessage]) {
        if state == "exited", let plan = docker.pendingRuns.removeValue(forKey: key) {
            startDockerRun(plan)
        } else if state == "failed" {
            docker.pendingRuns[key] = nil
        }
        let rest = key.dropFirst("docker:build:".count)
        guard key.hasPrefix("docker:build:"), let colon = rest.lastIndex(of: ":") else { return }
        let path = String(rest[..<colon])
        let isBuildDiag: (DiagnosticData) -> Bool = { $0.source == Self.dockerBuildSource }
        if state == "exited" {
            replaceDiagnostics(at: path, dropping: isBuildDiag, with: [])
            return
        }
        guard state == "failed",
              let failure = DockerCommandLine.buildFailure(in: output.map(\.text), dockerfileName: (path as NSString).lastPathComponent) else { return }
        let line = failure.line ?? 0
        let lineText: String
        if let session = documents[path], let range = session.lineRange(line) {
            lineText = (session.storage.string as NSString).substring(with: range)
        } else {
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            lineText = lines.indices.contains(line) ? lines[line] : ""
        }
        let diag = DiagnosticData(line: line, col: 0, endLine: line, endCol: (lineText as NSString).length,
                                  severity: 1, message: failure.message, source: Self.dockerBuildSource)
        replaceDiagnostics(at: path, dropping: isBuildDiag, with: [diag])
    }

    func validateComposeFile(_ path: String) {
        guard EcosystemDocumentTools.isDockerComposeFile(path) else { return }
        let validate = { [weak self] in
            self?.refreshDockerStatus { info in
                guard let self else { return }
                if info.state == "missingCLI" || info.state == "missingCompose" {
                    self.revealConsole()
                    self.appendLog("Didn’t validate \((path as NSString).lastPathComponent): \(info.title). \(info.explanation)", isStderr: true)
                    return
                }
                self.runComposeValidation(path)
            }
        }
        if let session = documents[path], session.isEdited {
            save(session, reportsFailure: true) { ok in if ok { validate() } }
        } else {
            validate()
        }
    }

    private func runComposeValidation(_ path: String) {
        struct Reply: Decodable {
            let ok: Bool
            let diagnostics: [DiagnosticData]?
            let output: String?
        }
        let name = (path as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = path.withCString { ptr -> Reply? in
                guard let out = ValidateComposeFile(ptr) else { return nil }
                defer { FreeGoCString(out) }
                return try? JSONDecoder().decode(Reply.self, from: Data(String(cString: out).utf8))
            }
            DispatchQueue.main.async {
                self.revealConsole()
                let isOwn: (DiagnosticData) -> Bool = { $0.source == Self.composeConfigSource }
                guard let reply else {
                    self.appendLog("Couldn’t validate \(name): docker compose returned no result.", isStderr: true)
                    return
                }
                if reply.ok {
                    self.replaceDiagnostics(at: path, dropping: isOwn, with: [])
                    self.appendLog("Compose file is valid: \(name)")
                    return
                }
                let output = (reply.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var diags = (reply.diagnostics ?? []).map { d -> DiagnosticData in
                    var d = d
                    d.source = Self.composeConfigSource
                    return d
                }
                if diags.isEmpty {
                    let message = output.components(separatedBy: "\n").first { !$0.isEmpty } ?? "docker compose config failed."
                    diags = [DiagnosticData(line: 0, col: 0, endLine: 0, endCol: 0, severity: 1, message: message, source: Self.composeConfigSource)]
                }
                self.replaceDiagnostics(at: path, dropping: isOwn, with: diags)
                self.appendLog("Compose file has \(diags.count == 1 ? "1 problem" : "\(diags.count) problems"): \(name)", isStderr: true)
                for line in output.components(separatedBy: "\n").prefix(50) where !line.isEmpty {
                    self.appendLog(line, isStderr: true)
                }
                if let first = diags.min(by: { ($0.line, $0.col) < ($1.line, $1.col) }) {
                    self.jumpTo(filePath: path, line: first.line + 1, column: first.col + 1)
                }
            }
        }
    }

    func refreshDockerfileFindings(_ path: String) {
        guard let session = documents[path] else { return }
        let text = session.storage.string
        let version = session.version
        DispatchQueue.global(qos: .utility).async {
            let findings = path.withCString { p in
                text.withCString { c -> [DockerfileFinding]? in
                    guard let out = InspectDockerfile(p, c) else { return nil }
                    defer { FreeGoCString(out) }
                    struct Reply: Decodable { let findings: [DockerfileFinding]? }
                    return (try? JSONDecoder().decode(Reply.self, from: Data(String(cString: out).utf8)))?.findings ?? []
                }
            }
            guard let findings else { return }
            DispatchQueue.main.async {
                guard self.documents[path]?.version == version else { return }
                self.docker.dockerfileFixes[path] = (version, findings)
                let diags = findings.map {
                    DiagnosticData(line: $0.line, col: $0.col, endLine: $0.endLine, endCol: $0.endCol, severity: $0.severity,
                                   message: $0.message, source: $0.source ?? "Dockerfile", code: $0.code)
                }
                self.replaceDiagnostics(at: path, dropping: { !Self.dockerCommandDiagnosticSources.contains($0.source ?? "") }, with: diags)
            }
        }
    }

    func dockerfileFixItems(path: String, lines: Set<Int>) -> [LSPCodeActionItem] {
        guard let entry = docker.dockerfileFixes[path], documents[path]?.version == entry.version else { return [] }
        return entry.findings.filter { lines.contains($0.line) }.flatMap { $0.fixes ?? [] }.compactMap { fix in
            LSPCodeActionItem(["title": fix.title, "kind": "quickfix", "golens": "dockerfileFix",
                               "path": path, "version": entry.version, "dockerfileFix": fix])
        }
    }

    func applyDockerfileFix(_ item: LSPCodeActionItem) {
        guard let fix = item.raw["dockerfileFix"] as? DockerfileFix, let path = item.raw["path"] as? String else { return }
        guard documents[path]?.version == item.raw["version"] as? Int else {
            let message = "The Dockerfile changed after it was checked. Try the fix again in a moment."
            appendLog(message)
            presentCommandFeedback(message, title: "Dockerfile Quick Fix", tone: .warning)
            return
        }
        func uri(_ p: String) -> String { lspURI(forPath: p) }
        func edit(_ line: Int, _ col: Int, _ endLine: Int, _ endCol: Int, _ text: String) -> [String: Any] {
            ["range": ["start": ["line": line, "character": col], "end": ["line": endLine, "character": endCol]], "newText": text]
        }
        var changes: [String: Any] = [:]
        var documentChanges: [[String: Any]] = []
        if let edits = fix.edits, !edits.isEmpty {
            changes[uri(path)] = edits.map { edit($0.line, $0.col, $0.endLine, $0.endCol, $0.newText) }
        }
        if let file = fix.createFile {
            guard file.path.hasPrefix("/") else {
                presentCommandFeedback("The quick fix target path could not be resolved safely.", title: "Dockerfile Quick Fix", tone: .warning)
                return
            }
            if FileManager.default.fileExists(atPath: file.path) {
                changes[uri(file.path)] = [edit(0, 0, Int(Int32.max), 0, file.content)]
            } else {
                documentChanges = [["kind": "create", "uri": uri(file.path)],
                                   ["textDocument": ["uri": uri(file.path)], "edits": [edit(0, 0, 0, 0, file.content)]]]
            }
        }
        var workspaceEdit: [String: Any] = [:]
        if !changes.isEmpty { workspaceEdit["changes"] = changes }
        if !documentChanges.isEmpty { workspaceEdit["documentChanges"] = documentChanges }
        guard !workspaceEdit.isEmpty, applyLSPWorkspaceEdit(workspaceEdit, revealCreated: true) else {
            presentCommandFeedback("Could not apply this Dockerfile quick fix.", title: "Dockerfile Quick Fix", tone: .failure)
            return
        }
        if fix.createFile != nil { refreshDockerfileFindings(path) }
    }
}

struct DockerRunError: Error {
    let message: String
}

struct DockerfileProposal: Decodable, Equatable {
    struct Port: Decodable, Equatable {
        let port: Int
        let package: String
        let file: String
        let line: Int
        let via: String
    }

    var dir = ""
    var dockerfile = ""
    var dockerignore = ""
    var mainPackages: [String] = []
    var goVersion = ""
    var usesCgo = false
    var cgoReason = ""
    var detectedPorts: [Port] = []
    var warnings: [String] = []
    var package = ""
    var base = ""
    var port = 0
    var error: String?

    enum CodingKeys: String, CodingKey {
        case dir, dockerfile, dockerignore, mainPackages, goVersion, usesCgo, cgoReason, detectedPorts, warnings, package, base, port, error
    }

    init(error: String) {
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile) ?? ""
        dockerignore = try c.decodeIfPresent(String.self, forKey: .dockerignore) ?? ""
        mainPackages = try c.decodeIfPresent([String].self, forKey: .mainPackages) ?? []
        goVersion = try c.decodeIfPresent(String.self, forKey: .goVersion) ?? ""
        usesCgo = try c.decodeIfPresent(Bool.self, forKey: .usesCgo) ?? false
        cgoReason = try c.decodeIfPresent(String.self, forKey: .cgoReason) ?? ""
        detectedPorts = try c.decodeIfPresent([Port].self, forKey: .detectedPorts) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        package = try c.decodeIfPresent(String.self, forKey: .package) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

extension WorkspaceState {

    static func proposeDockerfile(contextDir: String, package: String?, base: String?, port: Int?) -> DockerfileProposal {
        var options: [String: Any] = [:]
        if let package { options["package"] = package }
        if let base { options["base"] = base }
        if let port { options["port"] = port }
        let optionsJSON = options.isEmpty ? "" : ((try? JSONSerialization.data(withJSONObject: options)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        return contextDir.withCString { dir in
            optionsJSON.withCString { opts -> DockerfileProposal in
                guard let out = GenerateDockerfile(dir, opts) else { return DockerfileProposal(error: "The Dockerfile generator returned nothing.") }
                defer { FreeGoCString(out) }
                let json = String(cString: out)
                return (try? JSONDecoder().decode(DockerfileProposal.self, from: Data(json.utf8)))
                    ?? DockerfileProposal(error: "Couldn’t read the generated Dockerfile: \(json.prefix(200))")
            }
        }
    }

    func presentGenerateDockerfile() {
        guard !activeWorkspacePath.isEmpty else { return }
        activeDockerfileModel = GenerateDockerfileModel(contextDir: activeWorkspacePath)
        activeDockerfileModel?.workspace = self
    }

    func writeGeneratedDockerfile(_ proposal: DockerfileProposal) -> String? {
        let path = (proposal.dir as NSString).appendingPathComponent("Dockerfile")
        let ignorePath = (proposal.dir as NSString).appendingPathComponent(".dockerignore")
        do {
            try proposal.dockerfile.write(toFile: path, atomically: true, encoding: .utf8)
            if !FileManager.default.fileExists(atPath: ignorePath) {
                try proposal.dockerignore.write(toFile: ignorePath, atomically: true, encoding: .utf8)
            }
        } catch {
            return "Couldn’t write the Dockerfile: \(error.localizedDescription)"
        }
        if documents[path] != nil { revertToDiskVersion(path) }
        openFile(path)
        return nil
    }

    func dockerRunPlan(for config: RunConfiguration) -> Result<DockerRunPlan, DockerRunError> {
        func absolute(_ p: String) -> String {
            p.hasPrefix("/") ? p : (activeWorkspacePath as NSString).appendingPathComponent(p)
        }
        let dockerfilePath = dockerfilePath(for: config)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dockerfilePath, isDirectory: &isDir), !isDir.boolValue else {
            return .failure(DockerRunError(message: "There’s no Dockerfile at \(projectRelativePath(dockerfilePath)). Choose one in Edit Run Configurations, or choose Product ▸ Docker ▸ Generate Dockerfile for Go Project."))
        }
        let ports: [String]
        switch DockerCommandLine.portMappings(config.ports) {
        case .success(let p): ports = p
        case .failure(let e): return .failure(e)
        }
        let dir = (dockerfilePath as NSString).deletingLastPathComponent
        let project = (activeWorkspacePath as NSString).lastPathComponent
        let stage = config.targetStage.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTag = config.imageTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = customTag.isEmpty ? DockerCommandLine.imageTag(folder: project, stage: stage) : customTag
        let container = DockerCommandLine.containerName(project: project)

        var build = ["docker", "build", "-f", (dockerfilePath as NSString).lastPathComponent]
        if !stage.isEmpty { build += ["--target", stage] }
        build += ["-t", tag, "."]

        var run = ["docker", "run", "--rm", "--name", container]
        run += ports.flatMap { ["-p", $0] }
        let envFile = config.envFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !envFile.isEmpty {
            guard FileManager.default.fileExists(atPath: absolute(envFile)) else {
                return .failure(DockerRunError(message: "The env file \(envFile) doesn’t exist."))
            }
            run += ["--env-file", absolute(envFile)]
        }
        run += config.envVars.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
        run += DockerCommandLine.split(config.dockerRunArgs)
        run.append(tag)
        run += DockerCommandLine.split(config.args)
        return .success(DockerRunPlan(dir: dir, dockerfilePath: dockerfilePath, container: container, buildArgv: build, runArgv: run))
    }

    func runDockerConfiguration(_ config: RunConfiguration) {
        guard !activeWorkspacePath.isEmpty else { return }
        let plan: DockerRunPlan
        switch dockerRunPlan(for: config) {
        case .success(let p): plan = p
        case .failure(let e):
            revealConsole()
            appendLog("Didn’t run \(config.name): \(e.message)", isStderr: true)
            return
        }
        refreshDockerStatus(force: docker.status?.isOK != true) { [weak self] info in
            guard let self else { return }
            guard !info.blocks(compose: false) else {
                self.docker.runBlocked = true
                self.revealConsole()
                self.appendLog("Didn’t run \(config.name): \(info.title). \(info.explanation)", isStderr: true)
                return
            }
            self.docker.runBlocked = false
            self.docker.pendingRuns[plan.buildKey] = plan
            self.runExternalCommand(plan.buildArgv, in: plan.dir, key: plan.buildKey)
        }
    }

    private func dockerfilePath(for config: RunConfiguration) -> String {
        let rel = config.dockerfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rel.isEmpty ? "Dockerfile" : rel
        return path.hasPrefix("/") ? path : (activeWorkspacePath as NSString).appendingPathComponent(path)
    }

    func isDockerConfigurationRunning(_ config: RunConfiguration) -> Bool {
        let keys: Set = [DockerRunPlan.buildKey(dockerfilePath(for: config)),
                         DockerRunPlan.runKey(DockerCommandLine.containerName(project: (activeWorkspacePath as NSString).lastPathComponent))]
        return runSessions.contains { $0.isRunning && keys.contains($0.key) }
    }

    private func startDockerRun(_ plan: DockerRunPlan) {
        let cli = docker.status?.cliPath ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            Self.runDockerQuietly(cli: cli, ["rm", "-f", plan.container])
            DispatchQueue.main.async {
                self.runExternalCommand(plan.runArgv, in: plan.dir, key: plan.runKey)
            }
        }
    }

    func stopDockerContainer(runKey: String) {
        guard runKey.hasPrefix("docker:run:") else { return }
        let name = String(runKey.dropFirst("docker:run:".count))
        let cli = docker.status?.cliPath ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            Self.runDockerQuietly(cli: cli, ["stop", "-t", "5", name])
        }
    }

    private static func runDockerQuietly(cli: String, _ args: [String]) {
        guard !cli.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
    }
}
