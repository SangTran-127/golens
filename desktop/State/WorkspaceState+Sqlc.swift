import AppKit

struct SqlcLocation: Decodable {
    let path: String
    let line: Int
    let col: Int

    var lspLocation: LSPLocation {
        let pos = LSPPosition(line: line - 1, character: col - 1)
        return LSPLocation(uri: lspURI(forPath: path), range: LSPRange(start: pos, end: pos))
    }
}

struct SqlcQuery: Decodable {
    let name: String
    let cmd: String
    let line: Int
    let nameCol: Int
    let endLine: Int
    let go: SqlcLocation?
}

struct SqlcFileInfo: Decodable {
    let configDir: String
    let generatedFiles: [String]
    let queries: [SqlcQuery]
}

private struct SqlcGoInfo: Decodable {
    let name: String
    let locations: [SqlcLocation]
}

extension WorkspaceState {
    private static func decodeFFI<T: Decodable>(_ type: T.Type, _ out: UnsafeMutablePointer<CChar>?) -> T? {
        guard let out else { return nil }
        defer { FreeGoCString(out) }
        return try? JSONDecoder().decode(T.self, from: Data(String(cString: out).utf8))
    }

    func sqlcOverlaysJSON() -> String {
        var map: [String: String] = [:]
        for (path, session) in documents where session.isEdited && (path.hasSuffix(".go") || EcosystemDocumentTools.isSQLFile(path)) {
            map[path] = session.storage.string
        }
        guard let data = try? JSONSerialization.data(withJSONObject: map) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func sqlcQueriesInFile(path: String, text: String, root: String, overlays: String) -> SqlcFileInfo? {
        let out = path.withCString { p in
            text.withCString { t in root.withCString { r in overlays.withCString { o in SqlcQueriesInFile(p, t, r, o) } } }
        }
        return decodeFFI(SqlcFileInfo.self, out)
    }

    @MainActor
    func sqlcQueryLocations(forDefinition target: LSPLocation) async -> [SqlcLocation] {
        let root = activeWorkspacePath
        guard !root.isEmpty, target.path.hasSuffix(".go") else { return [] }
        let overlays = sqlcOverlaysJSON()
        let path = target.path
        let line = Int32(target.range.start.line + 1)
        return await Task.detached(priority: .userInitiated) {
            let out = path.withCString { p in root.withCString { r in overlays.withCString { o in SqlcQueryForGo(p, line, r, o) } } }
            return Self.decodeFFI(SqlcGoInfo.self, out)?.locations ?? []
        }.value
    }

    @MainActor
    func sqlcQuery(inFile path: String, text: String, line: Int) async -> (SqlcQuery, SqlcFileInfo)? {
        let root = activeWorkspacePath
        guard !root.isEmpty else { return nil }
        let overlays = sqlcOverlaysJSON()
        let info = await Task.detached(priority: .userInitiated) {
            Self.sqlcQueriesInFile(path: path, text: text, root: root, overlays: overlays)
        }.value
        guard let info, let query = info.queries.last(where: { $0.line <= line && line <= $0.endLine }) else { return nil }
        return (query, info)
    }

    func reloadSqlcLenses(forPath path: String, version: Int) {
        guard let session = documents[path], !activeWorkspacePath.isEmpty else { return }
        let text = session.storage.string
        let root = activeWorkspacePath
        let overlays = sqlcOverlaysJSON()
        BackgroundFFI.shared.run("sqlcLenses:" + path, debounce: 0.3, work: {
            Self.sqlcQueriesInFile(path: path, text: text, root: root, overlays: overlays)
        }, deliver: { [weak self] info in
            guard let self, let info, self.documents[path]?.version == version else { return }
            self.goplsLenses[path] = Dictionary(grouping: Self.sqlcLenses(info, path: path, canRun: self.database.hasDataSources), by: \.line)
            self.activeTextView?.needsDisplay = true
        })
    }

    private static func sqlcLenses(_ info: SqlcFileInfo, path: String, canRun: Bool) -> [CodeLensItem] {
        guard !info.configDir.isEmpty || info.queries.contains(where: { $0.go != nil }) else { return [] }
        return info.queries.flatMap { q -> [CodeLensItem] in
            let run = canRun ? [CodeLensItem(line: q.line, title: "Run Query", command: ["golensCommand": runSqlcQueryCommand, "path": path, "line": q.line])] : []
            guard q.go != nil else {
                return [CodeLensItem(line: q.line, title: "Not Generated — Run sqlc generate", command: [
                    "golensCommand": "sqlcGenerate", "configDir": info.configDir, "name": q.name
                ])] + run
            }
            return [
                CodeLensItem(line: q.line, title: "Go Method", command: ["golensCommand": "sqlcGoMethod", "path": path, "line": q.line]),
                CodeLensItem(line: q.line, title: "Usages", command: ["golensCommand": "sqlcUsages", "path": path, "line": q.line])
            ] + run
        }
    }

    func runSqlcLensCommand(_ name: String, _ command: [String: Any]) {
        switch name {
        case "sqlcGoMethod", "sqlcUsages":
            guard let path = command["path"] as? String, let line = command["line"] as? Int,
                  let session = documents[path] else { return }
            let text = session.storage.string
            let version = session.version
            Task { @MainActor in
                guard let (query, info) = await sqlcQuery(inFile: path, text: text, line: line) else { return }
                guard let go = query.go else {
                    let message = "\(query.name) has no generated Go method yet. Run sqlc generate."
                    appendLog(message)
                    presentCommandFeedback(message, title: "sqlc Query")
                    reloadSqlcLenses(forPath: path, version: version)
                    return
                }
                if name == "sqlcGoMethod" {
                    jumpToLocation(path: go.path, line: go.line, column: go.col)
                } else {
                    showSqlcUsages(of: query.name, goPath: go.path, line: go.line, col: go.col, generatedFiles: info.generatedFiles)
                }
            }
        case "sqlcGenerate":
            runSqlcGenerate(configDir: command["configDir"] as? String ?? "", query: command["name"] as? String ?? "")
        default:
            break
        }
    }

    private func showSqlcUsages(of query: String, goPath: String, line: Int, col: Int, generatedFiles: [String]) {
        let generated = Set(generatedFiles.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        runNavigationRequest(kind: "Usages", symbol: query) { [weak self] _ in
            await LSPClient.shared.referencesResult(atLine: line, col: col, inPath: goPath).map { refs -> NavigationOutcome in
                let calls = refs.filter { !generated.contains(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path) }
                if calls.count == 1, let only = calls.first {
                    return .perform { self?.jumpToLocation(path: only.path, line: only.range.start.line + 1, column: only.range.start.character + 1) }
                }
                if calls.isEmpty {
                    return .perform {
                        let message = "No calls to \(query) outside sqlc-generated code."
                        self?.appendLog(message)
                        self?.presentCommandFeedback(message, title: "sqlc Usages")
                    }
                }
                return .list(calls, kind: "Usages")
            }
        }
    }

    private func runSqlcGenerate(configDir: String, query: String) {
        guard !configDir.isEmpty else {
            appendLog("\(query) has no generated Go method, and there is no sqlc.yaml, sqlc.yml or sqlc.json above this file to run sqlc generate from.")
            presentCommandFeedback("No sqlc.yaml, sqlc.yml, or sqlc.json was found above this file to run sqlc generate.", title: "sqlc Generate", tone: .warning)
            return
        }
        guard Self.findTool("sqlc") != nil else {
            appendLog("sqlc is not installed. Install it with: brew install sqlc", isStderr: true)
            showConsole = true
            selectedConsoleTab = Self.consoleTab
            return
        }
        runExternalCommand(["sqlc", "generate"], in: configDir, key: "sqlc:" + configDir)
    }

    func sqlcGenerateExited(state: String) {
        guard state == "exited" else { return }
        if !activeWorkspacePath.isEmpty {
            loadFiles(from: activeWorkspacePath)
        }
        for (path, session) in documents where EcosystemDocumentTools.isSQLFile(path) {
            reloadSqlcLenses(forPath: path, version: session.version)
        }
    }
}
