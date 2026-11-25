import AppKit
import SwiftUI

struct CodeLensItem {
    let line: Int
    let title: String
    let command: [String: Any]
}

extension WorkspaceState {
    struct GoGenerateDirectiveDTO: Decodable {
        let file: String?
        let line: Int
        let command: String
        let runArg: String
        let label: String
    }

    static func goGenerateLenses(in text: String, path: String) -> [CodeLensItem] {
        guard text.contains("//go:generate") else { return [] }
        let jsonStr: String? = path.withCString { cPath in
            text.withCString { cSrc in
                guard let ptr = ScanGoGenerateFile(cPath, cSrc) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
        }
        if let jsonStr,
           let directives = try? JSONDecoder().decode([GoGenerateDirectiveDTO].self, from: Data(jsonStr.utf8)),
           !directives.isEmpty {
            return directives.map { dir in
                CodeLensItem(
                    line: max(1, dir.line),
                    title: dir.label,
                    command: [
                        "golensCommand": "goGenerate",
                        "path": path,
                        "line": dir.line,
                        "runArg": dir.runArg,
                        "commandText": dir.command
                    ]
                )
            }
        }
        return []
    }

    func reloadGoplsCodeLenses(forPath path: String, version: Int) {
        guard let session = documents[path], session.syncsToCore else { return }
        let isGoMod = (path as NSString).lastPathComponent == "go.mod"
        let isGo = path.hasSuffix(".go")
        let genLenses: [CodeLensItem]
        if isGo {
            let text = session.storage.string
            let benchmarks = CodeLensProvider.benchmarkLenses(in: text, path: path, workspace: self) + goSQLLenses(path: path, text: text, session: session, version: version)
            if let scan = GoSourceLensScanCache.shared.cached(path: path, text: text) {
                genLenses = scan.generate + benchmarks + scan.routes
            } else {
                genLenses = benchmarks
                BackgroundFFI.shared.run("codeLensScan:" + path, work: {
                    GoSourceLensScanCache.scan(text: text, path: path)
                }, deliver: { [weak self] scan in
                    guard let self else { return }
                    GoSourceLensScanCache.shared.store(scan, path: path, text: text)
                    guard self.documents[path] === session, session.version == version else { return }
                    self.mergeGeneratedCodeLenses(scan.generate + benchmarks + scan.routes, path: path)
                })
            }
        } else if isGoMod {
            genLenses = Self.inspectGoModLenses(forPath: path, content: session.storage.string, checkUpdates: false)
        } else if EcosystemDocumentTools.isSQLFile(path) {
            reloadSqlcLenses(forPath: path, version: version)
            return
        } else if EcosystemDocumentTools.isHTTPFile(path) {
            refreshHTTPLenses(path)
            return
        } else {
            genLenses = CodeLensProvider.ecosystemLenses(in: session.storage.string, path: path, secretsMasked: envSecretsMasked)
            goplsLenses[path] = Dictionary(grouping: genLenses, by: \.line)
            activeTextView?.needsDisplay = true
            return
        }
        mergeGeneratedCodeLenses(genLenses, path: path)
        lspRequestQueue.async {
            let reply = path.withCString { CoreReply(CodeLenses($0)) }
            let lenses: [CodeLensItem] = (reply.result as? [[String: Any]] ?? []).compactMap { l in
                guard let line = l["line"] as? Int, let title = l["title"] as? String, !title.isEmpty else { return nil }
                return CodeLensItem(line: line + 1, title: title, command: l)
            }
            DispatchQueue.main.async {
                guard self.documents[path] != nil, session.version == version else { return }
                let refreshedGen: [CodeLensItem]
                if path.hasSuffix(".go"), let latestSession = self.documents[path] {
                    let latestText = latestSession.storage.string
                    let benchmarks = CodeLensProvider.benchmarkLenses(in: latestText, path: path, workspace: self)
                        + self.goSQLLenses(path: path, text: latestText, session: latestSession, version: latestSession.version)
                    if let scan = GoSourceLensScanCache.shared.cached(path: path, text: latestText) {
                        refreshedGen = scan.generate + benchmarks + scan.routes
                    } else {
                        refreshedGen = benchmarks
                    }
                } else {
                    refreshedGen = genLenses
                }
                let genLines = Set(refreshedGen.map(\.line))
                let filtered = lenses.filter { lens in
                    !(genLines.contains(lens.line) && (lens.title.localizedCaseInsensitiveContains("generate") || lens.title.localizedCaseInsensitiveContains("tidy")))
                }
                self.goplsLenses[path] = Dictionary(grouping: refreshedGen + filtered, by: \.line)
                self.activeTextView?.needsDisplay = true
            }
        }
    }

    func mergeGeneratedCodeLenses(_ genLenses: [CodeLensItem], path: String) {
        guard !genLenses.isEmpty else { return }
        var current = goplsLenses[path] ?? [:]
        let grouped = Dictionary(grouping: genLenses, by: \.line)
        for (lineNum, lineItems) in grouped {
            var items = (current[lineNum] ?? []).filter {
                let vc = ($0.command["golensCommand"] as? String) ?? ""
                return vc != "goGenerate" && !vc.hasPrefix("goMod") &&
                    vc != "runBenchmark" && vc != "profileBenchmark" && vc != "compareBenchmarkBaseline" &&
                    vc != "testHTTPRoute" && vc != Self.runGoSQLCommand &&
                    !$0.title.localizedCaseInsensitiveContains("generate") &&
                    !$0.title.localizedCaseInsensitiveContains("tidy")
            }
            items.append(contentsOf: lineItems)
            current[lineNum] = items
        }
        goplsLenses[path] = current
        activeTextView?.needsDisplay = true
    }

    func runLSPCommand(_ command: [String: Any], title: String? = nil) {
        if handleHTTPLensCommand(command) { return }
        if let golensCmd = command["golensCommand"] as? String {
            switch golensCmd {
            case "sqlcGoMethod", "sqlcUsages", "sqlcGenerate":
                runSqlcLensCommand(golensCmd, command)
            case Self.runGoSQLCommand, Self.runSqlcQueryCommand:
                runDatabaseLensCommand(golensCmd, command)
            case "goGenerate":
                runGoGenerate(forPath: command["path"] as? String)
            case "goModTidy":
                tidyModule()
            case "goModCheckUpdates":
                checkGoModUpdates(forPath: command["path"] as? String)
            case "goModDownload":
                downloadModules()
            case "goModGet":
                if let arg = command["arg"] as? String {
                    upgradeModuleDependency(arg)
                }
            case "goModAdd":
                presentAddGoModuleSheet()
            case "runBenchmark":
                if let path = command["path"] as? String,
                   let name = command["name"] as? String {
                    let dir = (path as NSString).deletingLastPathComponent
                    let importPath = fileTests[path]?.importPath ?? "."
                    runTests(TestTarget(dir: dir, importPath: importPath, test: name, row: nil))
                } else {
                    runBenchmarks()
                }
            case "profileBenchmark":
                if let path = command["path"] as? String,
                   let name = command["name"] as? String {
                    profileBenchmark(path: path, name: name)
                } else {
                    runAllTests(profile: true)
                }
            case "compareBenchmarkBaseline":
                presentBenchmarkComparisonSheet()
            case "testHTTPRoute":
                presentHTTPRouteExerciser(command: command)
            case "runMakeTarget":
                if let path = command["path"] as? String, let target = command["target"] as? String {
                    runMakeTargetInConsole(makefilePath: path, target: target)
                }
            case "dockerComposeService":
                if let path = command["path"] as? String,
                   let service = command["service"] as? String,
                   let action = command["action"] as? String {
                    runDockerComposeCommand(composePath: path, service: service, action: action)
                }
            case "dockerComposeAll":
                if let path = command["path"] as? String,
                   let action = command["action"] as? String {
                    if action == "down" {
                        confirmComposeDown(composePath: path)
                    } else {
                        runDockerComposeCommand(composePath: path, service: nil, action: action)
                    }
                }
            case "dockerValidateCompose":
                if let path = command["path"] as? String {
                    validateComposeFile(path)
                }
            case "dockerBuildImage":
                if let path = command["path"] as? String {
                    let stage = command["stage"] as? String
                    runDockerBuildCommand(dockerfilePath: path, stage: stage)
                }
            case "applyEnvFileToRunConfig":
                if let path = command["path"] as? String {
                    applyEnvFileToActiveRunConfig(envPath: path)
                }
            case "toggleEnvSecretMask":
                envSecretsMasked.toggle()
                if let path = command["path"] as? String, let session = documents[path] {
                    reloadGoplsCodeLenses(forPath: path, version: session.version)
                }
                activeTextView?.needsDisplay = true
            default:
                break
            }
            return
        }
        guard let name = command["command"] as? String else { return }
        if name == "gopls.go_get_package",
           let pkg = (command["arguments"] as? [[String: Any]])?.first?["Pkg"] as? String {
            addGoModule(pkg)
            return
        }
        var params: [String: Any] = ["command": name]
        if let args = command["arguments"] { params["arguments"] = args }
        let label = title ?? (command["title"] as? String) ?? name
        resolveAndExecute(params, title: label)
    }

    func presentHTTPRouteExerciser(command: [String: Any]) {
        let method = (command["method"] as? String) ?? "GET"
        let routePath = (command["routePath"] as? String) ?? "/"
        let sampleBody = (command["sampleBody"] as? String) ?? ""
        let pathParams = (command["pathParams"] as? [String]) ?? []
        let line = (command["line"] as? Int) ?? 1

        activeEditorPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        activeEditorPopover = popover

        let view = HTTPRouteExerciserPopoverView(
            method: method,
            routePath: routePath,
            pathParams: pathParams,
            initialBody: sampleBody,
            onClose: { [weak popover] in
                popover?.performClose(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: view)

        if let tv = activeTextView as? GoLensTextView {
            let anchorRect = tv.lensRect(forLine: line, golensCommand: "testHTTPRoute") ?? NSRect(x: tv.gutterWidth + 10, y: tv.visibleRect.midY, width: 100, height: 20)
            popover.show(relativeTo: anchorRect, of: tv, preferredEdge: .maxY)
        } else if let window = NSApp.keyWindow ?? NSApp.windows.first, let contentView = window.contentView {
            popover.show(relativeTo: NSRect(x: contentView.bounds.midX - 50, y: contentView.bounds.midY, width: 100, height: 20), of: contentView, preferredEdge: .maxY)
        }
    }

    func resolveAndExecute(_ params: [String: Any], title: String) {
        let text = jsonText(params)
        lspRequestQueue.async {
            let reply = text.withCString { CoreReply(ResolveCommand($0)) }
            measureLog("command/resolve \(title): error=\(reply.error ?? "-") fields=\(((reply.result as? [String: Any])?["formFields"] as? [Any])?.count ?? 0)")
            DispatchQueue.main.async {
                guard let resolved = reply.result as? [String: Any] else {
                    self.reportCommandFailure(title, reply.error)
                    return
                }
                if let fields = resolved["formFields"] as? [[String: Any]], !fields.isEmpty {
                    var next = params
                    if let answers = resolved["formAnswers"] { next["formAnswers"] = answers }
                    self.lsp.pendingForm = InteractiveForm(title: title, params: next, fields: fields)
                    return
                }
                var final = params
                if let answers = resolved["formAnswers"] { final["formAnswers"] = answers }
                self.executeLSPCommand(final, title: title)
            }
        }
    }

    func submitInteractiveForm(_ form: InteractiveForm, answers: [[String: Any]]) {
        var params = form.params
        params["formAnswers"] = answers
        lsp.pendingForm = nil
        resolveAndExecute(params, title: form.title)
    }

    func executeLSPCommand(_ params: [String: Any], title: String) {
        let text = jsonText(params)
        lsp.runningCommand = title
        lspCommandQueue.async {
            let reply = text.withCString { CoreReply(ExecuteCommand($0)) }
            DispatchQueue.main.async {
                if self.lsp.runningCommand == title { self.lsp.runningCommand = nil }
                if let error = reply.error {
                    self.reportCommandFailure(title, error)
                } else if let result = reply.result {
                    let rawJSON = jsonText(result)
                    self.appendLog("\(title): \(rawJSON)")
                    self.ingestGovulncheckResult(result, rawText: rawJSON, title: title)
                }
            }
        }
    }

    func openGovulncheckMessageInSafetyPanel(_ rawMessageText: String) {
        if let openBrace = rawMessageText.firstIndex(of: "{"),
           let closeBrace = rawMessageText.lastIndex(of: "}"),
           openBrace < closeBrace {
            let slice = String(rawMessageText[openBrace...closeBrace])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                ingestGovulncheckResult(obj, rawText: slice, title: "Run govulncheck")
                return
            }
            ingestGovulncheckResult([:], rawText: slice, title: "Run govulncheck")
            return
        }
        hasSafetyData = true
        showConsole = true
        selectedConsoleTab = Self.safetyTab
    }

    func ingestGovulncheckResult(_ result: Any, rawText: String, title: String) {
        var entriesByID: [String: [String: Any]] = [:]
        var isGovuln = title.localizedCaseInsensitiveContains("govulncheck") || title.localizedCaseInsensitiveContains("vulncheck")

        if let dict = result as? [String: Any] {
            let innerResult = (dict["Result"] as? [String: Any]) ?? (dict["Entries"] != nil ? dict : nil)
            if let entries = innerResult?["Entries"] as? [String: Any] {
                isGovuln = true
                for (key, value) in entries {
                    if let entryDict = value as? [String: Any] {
                        entriesByID[key] = entryDict
                    }
                }
            } else if let osv = dict["osv"] as? [String: Any], let id = osv["id"] as? String {
                isGovuln = true
                entriesByID[id] = osv
            }
        }

        if entriesByID.isEmpty && (isGovuln || rawText.contains("\"osv\"") || rawText.contains("\"Entries\"")) {
            let lines = rawText.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let osv = obj["osv"] as? [String: Any], let id = osv["id"] as? String {
                    isGovuln = true
                    entriesByID[id] = osv
                } else if let inner = (obj["Result"] as? [String: Any]) ?? (obj["Entries"] != nil ? obj : nil),
                          let entries = inner["Entries"] as? [String: Any] {
                    isGovuln = true
                    for (key, value) in entries {
                        if let entryDict = value as? [String: Any] {
                            entriesByID[key] = entryDict
                        }
                    }
                }
            }
        }

        guard isGovuln else { return }

        let goModPath = activeWorkspacePath.isEmpty ? "go.mod" : (activeWorkspacePath as NSString).appendingPathComponent("go.mod")
        let goModLines: [String] = (try? String(contentsOfFile: goModPath, encoding: .utf8))?.components(separatedBy: .newlines) ?? []

        var vulnFindings: [SafetyFinding] = []
        for osvID in entriesByID.keys.sorted() {
            guard let entry = entriesByID[osvID] else { continue }
            let summary = (entry["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Vulnerability reported"
            let details = (entry["details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? summary
            let aliases = (entry["aliases"] as? [String]) ?? []
            let aliasTag = aliases.first.map { " (\($0))" } ?? ""
            let affected = (entry["affected"] as? [[String: Any]]) ?? []
            let pkgName = (affected.first?["package"] as? [String: Any])?["name"] as? String

            var fixedVersions: [String] = []
            for aff in affected {
                guard let ranges = aff["ranges"] as? [[String: Any]] else { continue }
                for r in ranges {
                    guard let events = r["events"] as? [[String: Any]] else { continue }
                    for ev in events {
                        if let fixed = ev["fixed"] as? String, !fixed.isEmpty, !fixedVersions.contains(fixed) {
                            fixedVersions.append(fixed)
                        }
                    }
                }
            }

            var matchedLine = 1
            if let pkg = pkgName, !goModLines.isEmpty {
                let parts = pkg.split(separator: "/")
                let modPrefix = parts.count >= 3 ? parts.prefix(3).joined(separator: "/") : pkg
                if let idx = goModLines.firstIndex(where: { $0.contains(pkg) || $0.contains(modPrefix) }) {
                    matchedLine = idx + 1
                }
            }

            let fixSuffix = fixedVersions.isEmpty ? "" : " — Fixed in v\(fixedVersions.joined(separator: ", v"))"
            let detailText = "\(details)\(fixSuffix)"

            vulnFindings.append(
                SafetyFinding(
                    id: "DEP_VULN_\(osvID)",
                    kind: "vuln",
                    severity: 2,
                    title: "\(osvID)\(aliasTag): \(summary)",
                    detail: detailText,
                    file: goModPath,
                    relFile: "go.mod",
                    line: matchedLine,
                    col: 1,
                    symbol: pkgName,
                    callChain: nil
                )
            )
        }

        let preserved = safetyFindings.filter { !$0.id.hasPrefix("DEP_VULN_") }
        safetyFindings = preserved + vulnFindings
        if vulnFindings.isEmpty {
            safetySummary = "govulncheck: 0 vulnerabilities found"
        } else {
            safetySummary = "govulncheck: \(vulnFindings.count) vulnerability advisor\(vulnFindings.count == 1 ? "y" : "ies") in go.mod"
        }
        hasSafetyData = true
        showConsole = true
        selectedConsoleTab = Self.safetyTab
    }

    private func reportCommandFailure(_ title: String, _ error: String?) {
        let message = error ?? "The language server returned no result."
        appendLog("\(title) failed: \(message)")
        let alert = NSAlert()
        alert.messageText = "\(title) Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
