import Foundation
import AppKit

extension WorkspaceState {
    static let requestsTab = 5

    var isActiveFileHTTP: Bool { EcosystemDocumentTools.isHTTPFile(activeFilePath) }

    func httpDocumentText(_ path: String) -> String {
        documents[path]?.storage.string ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    @discardableResult
    func refreshHTTPOutline(_ path: String) -> HTTPFileOutlineDTO {
        let text = httpDocumentText(path)
        let root = activeWorkspacePath
        let outline: HTTPFileOutlineDTO = path.withCString { p in
            text.withCString { t in
                root.withCString { r in
                    guard let ptr = HTTPFileOutline(p, t, r) else { return .empty }
                    defer { FreeGoCString(ptr) }
                    return (try? JSONDecoder().decode(HTTPFileOutlineDTO.self, from: Data(String(cString: ptr).utf8))) ?? .empty
                }
            }
        }
        if http.outlines[path] != outline {
            http.outlines[path] = outline
        }
        return outline
    }

    func refreshAllHTTPOutlines() {
        for path in documents.keys where EcosystemDocumentTools.isHTTPFile(path) {
            refreshHTTPOutline(path)
            refreshHTTPLenses(path)
        }
    }

    func httpFileLenses(path: String) -> [CodeLensItem] {
        let outline = refreshHTTPOutline(path)
        var items: [CodeLensItem] = []
        for request in outline.requests.prefix(CodeLensProvider.maxCodeLensPerFile) {
            let key = HTTPClientState.requestKey(path: path, request: request)
            let base: [String: Any] = ["path": path, "index": request.index, "line": request.line, "requestKey": key]
            if let runID = http.runningRunIDs[key] {
                var stop = base
                stop["golensCommand"] = "httpStopRequest"
                stop["runId"] = runID
                items.append(CodeLensItem(line: request.line, title: "Stop Request", command: stop))
            } else {
                var run = base
                run["golensCommand"] = "httpRunRequest"
                items.append(CodeLensItem(line: request.line, title: "Run Request", command: run))
            }
            if let latest = http.latestEntry(forKey: key), !latest.isRunning {
                var show = base
                show["golensCommand"] = "httpShowResponse"
                show["entryId"] = latest.id.uuidString
                show["outcome"] = latest.isSuccess ? "success" : (latest.isFailure ? "failure" : "neutral")
                items.append(CodeLensItem(line: request.line, title: latest.summary, command: show))
            }
        }
        return items
    }

    func refreshHTTPLenses(_ path: String) {
        guard documents[path] != nil else { return }
        goplsLenses[path] = Dictionary(grouping: httpFileLenses(path: path), by: \.line)
        activeTextView?.needsDisplay = true
    }

    func handleHTTPLensCommand(_ command: [String: Any]) -> Bool {
        guard let name = command["golensCommand"] as? String, name.hasPrefix("http") else { return false }
        let path = command["path"] as? String ?? activeFilePath
        switch name {
        case "httpRunRequest":
            if let index = command["index"] as? Int { runHTTPRequest(path: path, index: index) }
        case "httpStopRequest":
            if let runID = command["runId"] as? String { stopHTTPRequest(runID: runID) }
        case "httpShowResponse":
            if let raw = command["entryId"] as? String, let id = UUID(uuidString: raw) {
                showHTTPResponse(id)
            }
        default:
            return false
        }
        return true
    }

    func showRequestsPanel() {
        selectedConsoleTab = Self.requestsTab
        if !showConsole { showConsole = true }
    }

    func showHTTPResponse(_ id: UUID) {
        http.selectedEntryID = id
        showRequestsPanel()
    }

    func httpRequest(atLine line: Int, in path: String) -> HTTPFileRequestDTO? {
        let outline = refreshHTTPOutline(path)
        return outline.requests.first { line >= $0.startLine && line <= $0.endLine }
    }

    var canRunHTTPRequestAtCaret: Bool {
        isActiveFileHTTP && httpRequest(atLine: cursorLine, in: activeFilePath) != nil
    }

    func runHTTPRequestAtCaret() {
        guard isActiveFileHTTP else {
            presentCommandFeedback("Open a .http or .rest file to run HTTP requests.", title: "Run HTTP Request")
            return
        }
        guard let request = httpRequest(atLine: cursorLine, in: activeFilePath) else {
            presentCommandFeedback("Place the cursor inside an HTTP request block (for example, GET https://example.com).", title: "Run HTTP Request")
            return
        }
        runHTTPRequest(path: activeFilePath, index: request.index)
    }

    func runAllHTTPRequestsInActiveFile() {
        guard isActiveFileHTTP else {
            presentCommandFeedback("Open a .http or .rest file to run all HTTP requests.", title: "Run All HTTP Requests")
            return
        }
        runAllHTTPRequests(path: activeFilePath)
    }

    func runAllHTTPRequests(path: String) {
        guard !http.runAllPaths.contains(path) else { return }
        let outline = refreshHTTPOutline(path)
        guard !outline.requests.isEmpty else {
            presentCommandFeedback("No HTTP requests were found in \((path as NSString).lastPathComponent).", title: "Run All HTTP Requests")
            return
        }
        http.runAllPaths.insert(path)
        let indices = outline.requests.map(\.index)
        var firstFailure: UUID?
        func step(_ remaining: ArraySlice<Int>) {
            guard let index = remaining.first, http.runAllPaths.contains(path) else {
                http.runAllPaths.remove(path)
                if let firstFailure { http.selectedEntryID = firstFailure }
                return
            }
            runHTTPRequest(path: path, index: index) { entry in
                if firstFailure == nil, entry.isFailure { firstFailure = entry.id }
                if entry.error?.kind == "cancelled" {
                    self.http.runAllPaths.remove(path)
                    return
                }
                step(remaining.dropFirst())
            }
        }
        step(indices[...])
    }

    func stopHTTPRequest(runID: String) {
        runID.withCString { _ = HTTPFileCancel($0) }
    }

    func stopAllHTTPRequests() {
        http.runAllPaths.removeAll()
        for runID in http.runningRunIDs.values { stopHTTPRequest(runID: runID) }
    }

    var isAnyHTTPRequestRunning: Bool { !http.runningRunIDs.isEmpty }

    func selectHTTPEnvironment(_ name: String?, for path: String) {
        if let name, !name.isEmpty {
            http.selectedEnvironments[path] = name
        } else {
            http.selectedEnvironments[path] = nil
        }
    }

    func environmentFileTarget(for path: String) -> String {
        if let existing = http.outlines[path]?.environments.publicFile, !existing.isEmpty { return existing }
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("http-client.env.json")
    }

    func openOrCreateHTTPEnvironmentFile(for path: String) {
        let target = environmentFileTarget(for: path)
        if !FileManager.default.fileExists(atPath: target) {
            let template = """
            {
              "dev": {
                "host": "http://localhost:8080"
              }
            }

            """
            do {
                try template.write(toFile: target, atomically: true, encoding: .utf8)
            } catch {
                appendLog("Could not create \(target): \(error.localizedDescription)")
                presentCommandFeedback("Could not create \((target as NSString).lastPathComponent): \(error.localizedDescription)", title: "HTTP Environment", tone: .failure)
                return
            }
            loadFiles(from: activeWorkspacePath)
            refreshHTTPOutline(path)
            if http.environment(for: path) == nil, http.outlines[path]?.environments.names.contains("dev") == true {
                selectHTTPEnvironment("dev", for: path)
            }
        }
        openFile(target)
    }

    func newHTTPRequestFile() {
        guard !activeWorkspacePath.isEmpty else {
            presentCommandFeedback("Open a project folder first to create an HTTP request file.", title: "New HTTP Request File")
            return
        }
        let fm = FileManager.default
        let baseDir: String = {
            if !activeFilePath.isEmpty, activeFilePath.hasPrefix(activeWorkspacePath + "/") {
                return (activeFilePath as NSString).deletingLastPathComponent
            }
            return activeWorkspacePath
        }()
        var target = (baseDir as NSString).appendingPathComponent("requests.http")
        var n = 2
        while fm.fileExists(atPath: target) {
            target = (baseDir as NSString).appendingPathComponent("requests-\(n).http")
            n += 1
        }
        let starter = """
        ### Health check
        GET {{host}}/healthz
        Accept: application/json

        > {%
          client.test("Server is healthy", function () {
            client.assert(response.status === 200, "Expected status 200");
          });
        %}

        """
        do {
            try starter.write(toFile: target, atomically: true, encoding: .utf8)
        } catch {
            appendLog("Could not create \(target): \(error.localizedDescription)")
            presentCommandFeedback("Could not create \((target as NSString).lastPathComponent): \(error.localizedDescription)", title: "New HTTP Request File", tone: .failure)
            return
        }
        loadFiles(from: activeWorkspacePath)
        openFile(target)
    }

    func runHTTPRequest(path: String, index: Int, completion: ((HTTPRunEntry) -> Void)? = nil) {
        let outline = refreshHTTPOutline(path)
        guard let request = outline.requests.first(where: { $0.index == index }) else {
            presentCommandFeedback("Could not find HTTP request #\(index + 1) in \((path as NSString).lastPathComponent).", title: "Run HTTP Request")
            return
        }
        let key = HTTPClientState.requestKey(path: path, request: request)
        guard http.runningRunIDs[key] == nil else { return }

        let runID = UUID().uuidString
        let environment = http.environment(for: path)
        let entry = HTTPRunEntry(
            id: UUID(),
            runID: runID,
            path: path,
            requestKey: key,
            requestIndex: index,
            title: request.title,
            method: request.method,
            rawURL: request.url,
            environment: environment,
            startedAt: Date(),
            finishedAt: nil,
            isRunning: true,
            handlerLine: request.handlerLine
        )
        http.insert(entry)
        http.runningRunIDs[key] = runID
        showRequestsPanel()
        refreshHTTPLenses(path)

        let input: [String: Any] = [
            "path": path,
            "content": httpDocumentText(path),
            "workspaceRoot": activeWorkspacePath,
            "environment": environment ?? "",
            "index": index,
            "globals": http.globals,
            "runId": runID
        ]
        let inputJSON = jsonText(input)
        let globalsSnapshot = http.globals
        DispatchQueue.global(qos: .userInitiated).async {
            let result: HTTPRunResultDTO? = inputJSON.withCString { c in
                guard let ptr = HTTPFileRun(c) else { return nil }
                defer { FreeGoCString(ptr) }
                return try? JSONDecoder().decode(HTTPRunResultDTO.self, from: Data(String(cString: ptr).utf8))
            }
            var outcome: HTTPScriptOutcome?
            if let result, result.error == nil, let response = result.response,
               let script = result.request?.handler, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outcome = HTTPScriptRunner.run(script: script, response: response, globals: globalsSnapshot)
            }
            DispatchQueue.main.async {
                self.finishHTTPRun(entryID: entry.id, key: key, path: path, result: result, outcome: outcome, completion: completion)
            }
        }
    }

    private func finishHTTPRun(entryID: UUID, key: String, path: String, result: HTTPRunResultDTO?, outcome: HTTPScriptOutcome?, completion: ((HTTPRunEntry) -> Void)?) {
        http.runningRunIDs[key] = nil
        if let outcome {
            http.globals = outcome.globals
        }
        http.update(entryID) { entry in
            entry.isRunning = false
            entry.finishedAt = Date()
            if let result {
                entry.request = result.request
                entry.response = result.response
                entry.error = result.error
                if let handlerLine = result.request?.handlerLine, result.request?.handlerName == nil {
                    entry.handlerLine = handlerLine
                }
            } else {
                entry.error = HTTPRunErrorDTO(kind: "parse", message: "GoLens could not run this request.", detail: "The request runner returned no result. Run it again; if it keeps failing, check the Console for details.", variables: nil, file: nil)
            }
            if let outcome {
                entry.tests = outcome.tests
                entry.logs = outcome.logs
                entry.scriptError = outcome.error
                entry.scriptErrorLine = outcome.errorLine
            }
        }
        refreshHTTPLenses(path)
        if let finished = http.entries.first(where: { $0.id == entryID }) {
            completion?(finished)
        }
    }
}
