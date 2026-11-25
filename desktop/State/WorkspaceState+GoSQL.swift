import AppKit
import Foundation
import GoLensFoundation

struct GoSQLCompletionContext {
    let request: DBCompleteRequest
    let anchor: (Int) -> Int
}

extension WorkspaceState {
    static let runGoSQLCommand = "dbRunGoSQL"
    static let runSqlcQueryCommand = "dbRunSqlcQuery"

    var defaultDataSource: DBDataSourceDefinition? {
        if let id = database.defaultDataSourceIDs[activeWorkspacePath], let source = database.definition(id) {
            return source
        }
        return database.definitions.first
    }

    func setDefaultDataSource(_ id: String) {
        guard !activeWorkspacePath.isEmpty, database.definition(id) != nil else { return }
        database.defaultDataSourceIDs[activeWorkspacePath] = id
    }

    static func goConsoleID(_ dataSourceID: String) -> String {
        "go-" + dataSourceID
    }

    func goSQLLenses(path: String, text: String, session: DocumentSession, version: Int) -> [CodeLensItem] {
        guard path.hasSuffix(".go"), database.hasDataSources, !session.isEffectiveLargeFileMode else {
            applyGoSQLSites([], session: session)
            return []
        }
        if let sites = database.goSQLSites.cached(path: path, text: text) {
            applyGoSQLSites(sites, session: session)
            return Self.goSQLLenses(sites, path: path)
        }
        let root = activeWorkspacePath
        BackgroundFFI.shared.run("goSQLSites:" + path, debounce: 0.5, work: {
            DatabaseCore.goSQLSites(path: path, content: text, root: root).sites
        }, deliver: { [weak self] sites in
            guard let self else { return }
            self.database.goSQLSites.store(sites, path: path, text: text)
            guard self.documents[path] === session, session.version == version else { return }
            self.applyGoSQLSites(sites, session: session)
            self.mergeGeneratedCodeLenses(Self.goSQLLenses(sites, path: path), path: path)
        })
        return []
    }

    private static func goSQLLenses(_ sites: [DBGoSQLSite], path: String) -> [CodeLensItem] {
        var seen = Set<Int>()
        return sites.compactMap { site in
            guard seen.insert(site.line).inserted else { return nil }
            return CodeLensItem(line: site.line, title: "Run SQL", command: ["golensCommand": runGoSQLCommand, "path": path, "line": site.line])
        }
    }

    private func applyGoSQLSites(_ sites: [DBGoSQLSite], session: DocumentSession) {
        let ranges = sites.map { site in
            site.parts.map { part -> NSRange in
                let start = session.utf8.utf16Offset(byte: part.startByte)
                return NSRange(location: start, length: max(0, session.utf8.utf16Offset(byte: part.endByte) - start))
            }
        }
        guard ranges != session.highlighter.injectedSQL else { return }
        measureLog("go sql strings \(ranges.count) in \((session.path as NSString).lastPathComponent)")
        session.highlighter.setInjectedSQL(ranges)
        NotificationCenter.default.post(name: .golensInjectedSQLChanged, object: session.path)
    }

    func goSQLCompletionContext(doc: DocumentSession, caret: Int) -> GoSQLCompletionContext? {
        guard doc.path.hasSuffix(".go"), let hit = doc.highlighter.injectedSQLPart(at: caret),
              let source = defaultDataSource, let engine = source.engineKind else { return nil }
        let ns = doc.storage.mutableString
        let parts = doc.highlighter.injectedSQL[hit.site]
        guard parts.allSatisfy({ NSMaxRange($0) <= ns.length }) else { return nil }
        let texts = parts.map { ns.substring(with: $0) }
        let partStart = texts.prefix(hit.part).reduce(0) { $0 + $1.utf8.count }
        let part = parts[hit.part]
        let caretByte = partStart + ns.substring(with: NSRange(location: part.location, length: caret - part.location)).utf8.count
        let partBytes = Array(texts[hit.part].utf8)
        ensureDatabaseConfigured()
        let request = DBCompleteRequest(dataSourceId: source.id, dialect: engine.dialect, text: texts.joined(), caretByte: caretByte)
        return GoSQLCompletionContext(request: request) { sqlByte in
            let offset = min(max(0, sqlByte - partStart), partBytes.count)
            return part.location + String(decoding: partBytes.prefix(offset), as: UTF8.self).utf16.count
        }
    }

    private func caretByte(in path: String) -> Int? {
        guard let session = documents[path], let tv = databaseTextView(for: path) else { return nil }
        return session.utf8.byteOffset(min(tv.selectedRange().location, session.length))
    }

    func runGoSQL(path: String, line: Int? = nil) {
        let title = "Run SQL"
        guard database.hasDataSources else {
            presentCommandFeedback("Add a data source in Tools ▸ Database ▸ Data Sources… to run SQL.", title: title)
            return
        }
        guard path.hasSuffix(".go"), let session = documents[path] else {
            presentCommandFeedback("Open a Go file and place the caret in a SQL string to run it.", title: title)
            return
        }
        let text = session.storage.string
        let caret = line == nil ? caretByte(in: path) : nil
        let root = activeWorkspacePath
        DispatchQueue.global(qos: .userInitiated).async {
            let sites = DatabaseCore.goSQLSites(path: path, content: text, root: root).sites
            DispatchQueue.main.async {
                self.database.goSQLSites.store(sites, path: path, text: text)
                let site = caret.flatMap { byte in sites.first { $0.startByte <= byte && byte <= $0.endByte } }
                    ?? line.flatMap { target in sites.first { $0.line == target } }
                guard let site else {
                    self.presentCommandFeedback("Place the caret in a SQL string passed to database/sql, pgx or sqlx, or in a string marked // language=SQL.", title: title)
                    return
                }
                self.runGoSQLSite(site, path: path)
            }
        }
    }

    private func runGoSQLSite(_ site: DBGoSQLSite, path: String) {
        guard let source = defaultDataSource else { return }
        guard !site.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentCommandFeedback("This string is empty, so there is no SQL to run.", title: "Run SQL")
            return
        }
        startDatabaseRun(
            consolePath: "",
            consoleID: Self.goConsoleID(source.id),
            dataSourceID: source.id,
            text: site.sql,
            mode: .all,
            caretByte: 0,
            selection: DBByteRange(),
            sourceLocation: DBSourceLocation(path: path, line: site.line)
        )
    }

    func sqlcDataSource(engine: String) -> DBDataSourceDefinition? {
        guard !engine.isEmpty else { return defaultDataSource }
        if let source = defaultDataSource, source.engine == engine { return source }
        return database.definitions.first { $0.engine == engine } ?? defaultDataSource
    }

    func runSqlcQuery(path: String, line: Int? = nil) {
        let title = "Run Query"
        guard database.hasDataSources else {
            presentCommandFeedback("Add a data source in Tools ▸ Database ▸ Data Sources… to run sqlc queries.", title: title)
            return
        }
        guard EcosystemDocumentTools.isSQLFile(path), let session = documents[path] else {
            presentCommandFeedback("Open a sqlc query file and place the caret in a query to run it.", title: title)
            return
        }
        let text = session.storage.string
        let caretLocation = databaseTextView(for: path)?.selectedRange().location
        let target = line ?? caretLocation.map { session.lines.line(at: min($0, session.length)) + 1 } ?? 1
        DispatchQueue.global(qos: .userInitiated).async {
            let query = DatabaseCore.sqlcQuery(path: path, content: text, line: target)
            DispatchQueue.main.async {
                guard query.error == nil else {
                    self.presentCommandFeedback("Place the caret in a query that starts with a “-- name:” comment.", title: title)
                    return
                }
                guard !query.sql.isEmpty else {
                    self.presentCommandFeedback("“\(query.name)” has no SQL to run.", title: title)
                    return
                }
                guard let source = self.sqlcDataSource(engine: query.engine) else { return }
                self.startDatabaseRun(
                    consolePath: path,
                    consoleID: self.database.consoleID(forPath: path),
                    dataSourceID: source.id,
                    text: text,
                    mode: .selection,
                    caretByte: query.startByte,
                    selection: DBByteRange(startByte: query.startByte, endByte: query.endByte)
                )
            }
        }
    }

    func runDatabaseLensCommand(_ name: String, _ command: [String: Any]) {
        guard let path = command["path"] as? String else { return }
        if name == Self.runGoSQLCommand {
            runGoSQL(path: path, line: command["line"] as? Int)
        } else {
            runSqlcQuery(path: path, line: command["line"] as? Int)
        }
    }

    func runGoSQLAtCaret() {
        runGoSQL(path: activeFilePath)
    }

    func runSqlcQueryAtCaret() {
        runSqlcQuery(path: activeFilePath)
    }
}
