import AppKit
import Foundation
import GoLensFoundation

struct DatabaseConsoleRef: Equatable {
    let consoleID: String
    let dataSourceID: String
    let path: String
}

extension WorkspaceState {
    var activeDatabaseConsole: DatabaseConsoleRef? {
        if let dataSourceID = activeDatabaseConsoleDataSourceID {
            return DatabaseConsoleRef(consoleID: database.consoleID(forPath: activeFilePath), dataSourceID: dataSourceID, path: activeFilePath)
        }
        if let tab = database.selectedResult {
            return DatabaseConsoleRef(consoleID: tab.consoleID, dataSourceID: tab.dataSourceID, path: tab.consolePath)
        }
        return nil
    }

    var activeDatabaseHasOpenTransaction: Bool {
        transactionConsole != nil
    }

    private var transactionConsole: DatabaseConsoleRef? {
        var candidates: [DatabaseConsoleRef] = []
        if let dataSourceID = activeDatabaseConsoleDataSourceID, let consoleID = database.consoleIDs[activeFilePath] {
            candidates.append(DatabaseConsoleRef(consoleID: consoleID, dataSourceID: dataSourceID, path: activeFilePath))
        }
        if let tab = database.selectedResult {
            candidates.append(DatabaseConsoleRef(consoleID: tab.consoleID, dataSourceID: tab.dataSourceID, path: tab.consolePath))
        }
        return candidates.first { database.session(forConsole: $0.consoleID)?.hasOpenTransaction == true }
    }

    func transactionMode(for console: DatabaseConsoleRef) -> DBTransactionMode {
        database.session(forConsole: console.consoleID)?.transactionMode
            ?? database.definition(console.dataSourceID)?.effectiveTransactionMode
            ?? .auto
    }

    func commitActiveDatabaseTransaction() {
        endActiveDatabaseTransaction(commit: true)
    }

    func rollBackActiveDatabaseTransaction() {
        endActiveDatabaseTransaction(commit: false)
    }

    private func endActiveDatabaseTransaction(commit: Bool) {
        guard let console = transactionConsole else {
            presentCommandFeedback("There is no open transaction in this console. Run a statement in Manual mode, or BEGIN, to start one.", title: commit ? "Commit" : "Roll Back")
            return
        }
        endDatabaseTransaction(console, commit: commit)
    }

    func endDatabaseTransaction(_ console: DatabaseConsoleRef, commit: Bool) {
        let action = commit ? DBTransactionAction.commit : DBTransactionAction.rollback
        runDatabaseTransaction(
            console,
            DBTransactionRequest(consoleId: console.consoleID, dataSourceId: console.dataSourceID, action: action.rawValue),
            failureTitle: commit ? "Couldn’t Commit the Transaction" : "Couldn’t Roll Back the Transaction"
        )
    }

    func setActiveDatabaseTransactionMode(_ mode: DBTransactionMode) {
        guard let console = activeDatabaseConsole else {
            presentCommandFeedback("Open a .sql file attached to a data source, or a table, to choose how its statements are committed.", title: mode.title)
            return
        }
        setDatabaseTransactionMode(mode, console: console)
    }

    func setDatabaseTransactionMode(_ mode: DBTransactionMode, console: DatabaseConsoleRef) {
        guard transactionMode(for: console) != mode || database.session(forConsole: console.consoleID) == nil else { return }
        runDatabaseTransaction(console, DBTransactionRequest(consoleId: console.consoleID, dataSourceId: console.dataSourceID, action: DBTransactionAction.setMode.rawValue, mode: mode.rawValue), failureTitle: "Couldn’t Switch to \(mode.title)")
    }

    func setDatabaseIsolation(_ level: String, console: DatabaseConsoleRef) {
        runDatabaseTransaction(console, DBTransactionRequest(consoleId: console.consoleID, dataSourceId: console.dataSourceID, action: DBTransactionAction.setIsolation.rawValue, isolation: level), failureTitle: "Couldn’t Change the Isolation Level")
    }

    func loadDatabaseTransactionStatus(_ console: DatabaseConsoleRef) {
        guard database.isolationLevels[console.dataSourceID] == nil else { return }
        ensureDatabaseConfigured()
        database.isolationLevels[console.dataSourceID] = []
        runDatabaseTransaction(console, DBTransactionRequest(consoleId: console.consoleID, dataSourceId: console.dataSourceID, action: DBTransactionAction.status.rawValue), failureTitle: nil)
    }

    private func runDatabaseTransaction(_ console: DatabaseConsoleRef, _ request: DBTransactionRequest, failureTitle: String?) {
        ensureDatabaseConfigured()
        if database.consoleDataSources[console.consoleID] != console.dataSourceID {
            database.consoleDataSources[console.consoleID] = console.dataSourceID
        }
        Self.registerDatabaseConsole(console.consoleID, owner: self)
        database.queue(forConsole: console.consoleID).async {
            let result = DatabaseCore.transaction(request)
            DispatchQueue.main.async {
                if !result.isolationLevels.isEmpty, self.database.isolationLevels[console.dataSourceID] != result.isolationLevels {
                    self.database.isolationLevels[console.dataSourceID] = result.isolationLevels
                }
                if let session = result.session, request.action != DBTransactionAction.status.rawValue || self.database.sessions[console.consoleID] == nil {
                    self.applyDatabaseSession(session, consoleID: console.consoleID, dataSourceID: console.dataSourceID)
                }
                if let error = result.error, let failureTitle {
                    self.presentCommandFeedback(error.message, title: failureTitle, tone: error.kind == DBError.transactionOpen ? .warning : .failure)
                } else if request.action == DBTransactionAction.rollback.rawValue || request.action == DBTransactionAction.commit.rawValue {
                    self.reloadTablesAfterTransaction(consoleID: console.consoleID)
                }
                self.scheduleDatabaseCommandRefresh()
            }
        }
    }

    private func reloadTablesAfterTransaction(consoleID: String) {
        guard let tab = tableTab(forConsole: consoleID) else { return }
        database.updateResult(tab.id) { $0.notice = nil }
        reloadDatabaseTable(tab.id)
    }

    func confirmDatabaseTransactionsBeforeClosing(completion: @escaping (Bool) -> Void) {
        let open = database.sessions.filter { $0.value.hasOpenTransaction }.map(\.key).sorted()
        confirmNextDatabaseTransaction(open, completion: completion)
    }

    private func confirmNextDatabaseTransaction(_ consoleIDs: [String], completion: @escaping (Bool) -> Void) {
        guard let consoleID = consoleIDs.first else {
            completion(true)
            return
        }
        let rest = Array(consoleIDs.dropFirst())
        if let path = database.consolePath(forID: consoleID) {
            confirmDatabaseConsoleClose(path) { proceed in
                proceed ? self.confirmNextDatabaseTransaction(rest, completion: completion) : completion(false)
            }
            return
        }
        let source = database.consoleDataSources[consoleID].flatMap(database.definition)
        let alert = NSAlert()
        alert.messageText = "Close With an Open Transaction on “\(source?.name ?? "the data source")”?"
        alert.informativeText = "Changes made in the table editor are not committed yet. Commit them or roll them back before the window closes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Roll Back").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            let next: (Bool) -> Void = { proceed in
                proceed ? self.confirmNextDatabaseTransaction(rest, completion: completion) : completion(false)
            }
            switch response {
            case .alertFirstButtonReturn: self.endDatabaseTransaction(consoleID: consoleID, commit: true, completion: next)
            case .alertSecondButtonReturn: self.endDatabaseTransaction(consoleID: consoleID, commit: false, completion: next)
            default: completion(false)
            }
        }
    }

    func promptForDatabaseParameters(_ request: DBExecuteRequest, actionTitle: String, completion: @escaping ([DBParamValue]?) -> Void) {
        guard let engine = database.definition(request.dataSourceId)?.engineKind else {
            completion(nil)
            return
        }
        let dialect = engine.dialect
        let consoleID = request.consoleId
        let remembered = database.parameterValues[consoleID] ?? [:]
        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = Array(request.text.utf8)
            var range = (start: 0, end: bytes.count)
            switch DBRunMode(rawValue: request.mode) {
            case .selection:
                range = (request.selection.startByte, request.selection.endByte)
            case .caret:
                let statements = DatabaseCore.statements(text: request.text, dialect: dialect)
                if let hit = statements.first(where: { $0.startByte <= request.caretByte && request.caretByte <= $0.endByte })
                    ?? statements.last(where: { $0.endByte <= request.caretByte })
                    ?? statements.first {
                    range = (hit.startByte, hit.endByte)
                }
            default:
                break
            }
            let parameters = DatabaseCore.parameters(text: request.text, dialect: dialect, startByte: range.start, endByte: range.end)
            let lower = max(0, min(range.start, bytes.count))
            let upper = max(lower, min(range.end, bytes.count))
            let statement = String(decoding: bytes[lower..<upper], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard !parameters.isEmpty else {
                    self.presentCommandFeedback("The database asked for parameter values, but GoLens found no parameters in the statement. Check the statement, then run it again.", title: "Parameters Needed", tone: .warning)
                    completion(nil)
                    return
                }
                let prompt = DBParameterPrompt(
                    consoleID: consoleID,
                    dataSourceID: request.dataSourceId,
                    statementText: statement,
                    dialect: dialect,
                    parameters: parameters,
                    remembered: remembered,
                    actionTitle: actionTitle
                )
                self.database.parameterCompletions[prompt.id] = completion
                self.router.activeSheet = .queryParameters(prompt)
            }
        }
    }

    func finishDatabaseParameterPrompt(_ prompt: DBParameterPrompt, values: [DBParamValue]?) {
        guard let completion = database.parameterCompletions.removeValue(forKey: prompt.id) else { return }
        if let values {
            var remembered = database.parameterValues[prompt.consoleID] ?? [:]
            for value in values {
                remembered[value.name] = value.isSecret ? DBParamValue(name: value.name, value: "", isNull: false, secret: true) : value
            }
            database.parameterValues[prompt.consoleID] = remembered
        }
        if case .queryParameters(let shown) = router.activeSheet, shown.id == prompt.id {
            router.activeSheet = nil
        }
        completion(values)
    }

    var queryHistoryTargetDataSourceID: String? {
        activeDatabaseConsole?.dataSourceID ?? (database.definitions.count == 1 ? database.definitions.first?.id : nil)
    }

    func showQueryHistory() {
        guard let dataSourceID = queryHistoryTargetDataSourceID else {
            presentCommandFeedback(
                database.hasDataSources
                    ? "Open a .sql file attached to a data source to see the statements run on it."
                    : "Add a data source in Tools ▸ Database ▸ Data Sources… to keep a query history.",
                title: "Query History"
            )
            return
        }
        Self.configureDatabaseHistoryDirectory()
        database.historyDataSourceID = dataSourceID
        activePopup = .queryHistory
    }

    func loadQueryHistory(dataSourceID: String, query: String, deliver: @escaping (DBHistoryResult) -> Void) {
        BackgroundFFI.shared.run("database.history", debounce: query.isEmpty ? 0 : 0.08, work: {
            DatabaseCore.history(DBHistoryRequest(dataSourceId: dataSourceID, query: query, limit: 200))
        }, deliver: deliver)
    }

    func deleteQueryHistoryEntry(_ id: String, dataSourceID: String, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DatabaseCore.history(DBHistoryRequest(dataSourceId: dataSourceID, delete: id))
            DispatchQueue.main.async(execute: completion)
        }
    }

    func clearQueryHistory(dataSourceID: String, completion: @escaping () -> Void) {
        let name = database.definition(dataSourceID)?.name ?? "this data source"
        let alert = NSAlert()
        alert.messageText = "Clear the Query History of “\(name)”?"
        alert.informativeText = "Every statement GoLens recorded for “\(name)” on this Mac is removed. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = DatabaseCore.history(DBHistoryRequest(dataSourceId: dataSourceID, clear: true))
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func insertHistoryStatement(_ text: String, dataSourceID: String) {
        activePopup = nil
        let statement = text.hasSuffix(";") || text.hasSuffix("\n") ? text : text + ";"
        if ActiveCommandCapabilities.isSQLFile(activeFilePath), let tv = databaseTextView(for: activeFilePath) {
            let range = tv.selectedRange()
            let string = tv.string as NSString
            let lineStart = string.lineRange(for: NSRange(location: min(range.location, string.length), length: 0)).location
            let atLineStart = range.location == lineStart
            let insertion = (atLineStart ? "" : "\n") + statement
            tv.window?.makeFirstResponder(tv)
            tv.insertText(insertion, replacementRange: range)
            return
        }
        let root = activeWorkspacePath
        guard !root.isEmpty, let source = database.definition(dataSourceID) else { return }
        do {
            let path = try DataSourceStore.shared.createConsoleFile(root: root, dataSourceName: source.name)
            try (statement + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            database.attachments[path] = source.id
            loadFiles(from: root)
            openFile(path)
            refreshCommandCapabilities()
        } catch {
            presentCommandFeedback("Couldn’t create a query console for the statement. \(Self.failureReason(error))", title: "Query History", tone: .failure)
        }
    }

    func explainDatabaseStatement(analyze: Bool) {
        let title = analyze ? "Explain Analyze" : "Explain Plan"
        let path = activeFilePath
        let selected = databaseTextView(for: path)?.selectedRange().length ?? 0
        let mode: DBRunMode = selected > 0 ? .selection : .caret
        guard let target = databaseConsoleTarget(mode: mode, path: path, title: title) else { return }
        guard database.runningRun(forConsole: target.consoleID) == nil else {
            presentCommandFeedback("A statement is still running in this console. Stop it before you explain another one.", title: title)
            return
        }
        if let issue = ensureDatabaseConfigured().first(where: { $0.id == target.dataSourceID }) {
            presentCommandFeedback(issue.message, title: title, tone: .warning)
            return
        }
        let execID = UUID().uuidString
        let request = DBExecuteRequest(
            execId: execID,
            consoleId: target.consoleID,
            dataSourceId: target.dataSourceID,
            workspaceRoot: activeWorkspacePath,
            text: target.text,
            mode: mode.rawValue,
            caretByte: target.caretByte,
            selection: target.selection,
            confirmed: [],
            pageSize: DatabaseState.pageSize
        )
        beginDatabaseRun(execID: execID, consoleID: target.consoleID, consolePath: path, dataSourceID: target.dataSourceID, mode: mode)
        runExplain(DBExplainRequest(request: request, analyze: analyze), line: target.caretLine, secretRetried: false)
    }

    private func runExplain(_ request: DBExplainRequest, line: Int, secretRetried: Bool) {
        let inner = request.request
        database.queue(forConsole: inner.consoleId).async {
            let result = DatabaseCore.explain(request)
            DispatchQueue.main.async {
                self.handleExplain(result, request: request, line: line, secretRetried: secretRetried)
            }
        }
    }

    private func handleExplain(_ result: DBExplainResult, request: DBExplainRequest, line: Int, secretRetried: Bool) {
        let inner = request.request
        let dataSourceID = inner.dataSourceId
        if let session = result.session { applyDatabaseSession(session, consoleID: inner.consoleId, dataSourceID: dataSourceID) }
        if let error = result.error, error.kind == DBError.needsSecret, !secretRetried, let source = database.definition(dataSourceID) {
            resolveDatabaseSecret(source) { secret in
                guard let secret else {
                    self.finishDatabaseRun(inner.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    self.database.connectionStatus[dataSourceID] = .notConnected
                    return
                }
                DatabaseCore.setSecret(dataSourceID: dataSourceID, secret: secret)
                self.runExplain(request, line: line, secretRetried: true)
            }
            return
        }
        if let error = result.error, error.kind == DBError.needsParameters, inner.parameters == nil {
            promptForDatabaseParameters(inner, actionTitle: request.analyze ? "Explain Analyze" : "Explain Plan") { values in
                guard let values else {
                    self.finishDatabaseRun(inner.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    return
                }
                var next = request
                next.request.parameters = values
                self.runExplain(next, line: line, secretRetried: secretRetried)
            }
            return
        }
        if !result.blocked.isEmpty {
            confirmBlockedStatements(result.blocked, dataSourceID: dataSourceID) { confirmed in
                guard confirmed else {
                    self.finishDatabaseRun(inner.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    return
                }
                var next = request
                next.request.confirmed = result.blocked.map { DBConfirmation(hash: $0.hash, risk: $0.risk) }
                self.runExplain(next, line: line, secretRetried: secretRetried)
            }
            return
        }
        if database.session(forConsole: inner.consoleId)?.isConnected != true, database.status(forDataSource: dataSourceID) == .connecting {
            setDatabaseConnectionStatus(.notConnected, for: dataSourceID)
        }
        if let error = result.error, error.isConnectionFailure {
            database.connectionStatus[dataSourceID] = .failed(error)
            finishDatabaseRun(inner.execId, statements: [], error: error, canceledBeforeRunning: false)
            return
        }
        let statement = DBStatementResult(
            index: 0,
            line: line,
            startByte: inner.caretByte,
            endByte: inner.caretByte,
            kind: "explain",
            resultId: "",
            rowsFetched: 0,
            complete: true,
            truncated: false,
            rowsAffected: nil,
            durationMs: (result.plan?.planningMs ?? 0) + (result.plan?.executionMs ?? 0),
            firstRowMs: 0,
            pageEncodedMs: 0,
            error: result.error
        )
        upsertDatabaseResult(statement, execID: inner.execId, consoleID: inner.consoleId, dataSourceID: dataSourceID)
        let id = Self.databaseResultID(statement, execID: inner.execId)
        database.updateResult(id) { $0.explain = DBExplainOutcome(analyze: request.analyze, result: result) }
        finishDatabaseRun(inner.execId, statements: [statement], error: nil, canceledBeforeRunning: false)
        if let path = database.runs.first(where: { $0.id == inner.execId })?.consolePath, !path.isEmpty, let error = result.error {
            publishSQLErrorDiagnostics(path: path, errors: [error])
        }
        if database.selectedResultID != id { database.selectedResultID = id }
    }

    var exportableDatabaseResult: DBResultTab? {
        guard let tab = database.selectedResult, tab.hasRows, tab.explain == nil else { return nil }
        return tab
    }

    func presentExportResult(_ tabID: String? = nil) {
        guard let tab = tabID.flatMap(database.result) ?? exportableDatabaseResult, tab.hasRows else {
            presentCommandFeedback("Run a statement that returns rows, then export its result.", title: "Export Result")
            return
        }
        guard tab.export == nil else {
            presentCommandFeedback("This result is already being exported. Wait for it to finish or stop it.", title: "Export Result")
            return
        }
        router.activeSheet = .exportResult(DBExportSheetRequest(tabID: tab.id))
    }

    func selectedDatabaseRows(_ tabID: String) -> IndexSet {
        database.pageCaches[tabID]?.selectedRows ?? []
    }

    func databaseExportPreview(tabID: String, format: DBExportFormat, options: DBExportOptions, deliver: @escaping (String) -> Void) {
        guard let tab = database.result(tabID), let resultID = tab.resultID else { return deliver("") }
        let rows = (0..<Int64(min(5, tab.rowsFetched))).map { $0 }
        BackgroundFFI.shared.run("database.export.preview", debounce: 0.1, work: {
            DatabaseCore.export(DBExportRequest(execId: UUID().uuidString, resultId: resultID, format: format.rawValue, scope: DBExportScope.selection.rawValue, rows: rows, clipboard: true, options: options))
        }, deliver: { result in
            deliver(result.text ?? "")
        })
    }

    func startDatabaseExport(tabID: String, format: DBExportFormat, scope: DBExportScope, options: DBExportOptions, path: String) {
        guard let tab = database.result(tabID), let resultID = tab.resultID else { return }
        let execID = UUID().uuidString
        let rows = scope == .selection ? selectedDatabaseRows(tabID).map { Int64($0) } : nil
        let request = DBExportRequest(execId: execID, resultId: resultID, format: format.rawValue, scope: scope.rawValue, rows: rows, path: path, options: options)
        database.updateResult(tabID) { tab in
            tab.export = DBExportProgress(execID: execID, format: format, path: path)
            tab.notice = nil
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.export(request)
            DispatchQueue.main.async {
                let file = (path as NSString).lastPathComponent
                self.database.updateResult(tabID) { tab in
                    tab.export = nil
                    if result.cursorClosed == true {
                        tab.cursorClosed = true
                    }
                    if let error = result.error {
                        tab.notice = error.kind == DBError.cancelled
                            ? DBResultNotice(kind: .info, title: "Export Stopped", message: "GoLens wrote \(UserMessage.quantity(Int(result.rowsWritten), "row")) to “\(file)” before you stopped it.")
                            : DBResultNotice(kind: .warning, title: "Couldn’t Export the Result", message: error.message)
                        return
                    }
                    var message = "Saved \(UserMessage.quantity(Int(result.rowsWritten), "row")) to “\(file)” (\(UserMessage.byteCount(result.bytes)))."
                    if result.cursorClosed == true {
                        message += " GoLens read the rest of the result from the database for the file, so the grid keeps only the \(UserMessage.quantity(Int(tab.rowsFetched), "row")) already loaded."
                    }
                    tab.notice = DBResultNotice(kind: .success, title: "Result Exported", message: message, revealPath: path)
                }
                self.scheduleDatabaseCommandRefresh()
            }
        }
    }

    func stopDatabaseExport(_ tabID: String) {
        guard let execID = database.result(tabID)?.export?.execID else { return }
        DispatchQueue.global(qos: .userInitiated).async { DatabaseCore.cancel(execID) }
    }

    func copyDatabaseRows(tabID: String, rows: IndexSet, format: DBExportFormat) {
        guard let tab = database.result(tabID), let resultID = tab.resultID, !rows.isEmpty else { return }
        var options = DBExportOptions()
        if format == .sql, let table = tab.table { options.tableName = table.schema.isEmpty ? table.table : "\(table.schema).\(table.table)" }
        let request = DBExportRequest(execId: UUID().uuidString, resultId: resultID, format: format.rawValue, scope: DBExportScope.selection.rawValue, rows: rows.map { Int64($0) }, clipboard: true, options: options)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.export(request)
            DispatchQueue.main.async {
                if let error = result.error {
                    self.presentCommandFeedback(error.message, title: "Couldn’t Copy as \(format.title)", tone: error.kind == DBError.tooLarge ? .warning : .failure)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text ?? "", forType: .string)
            }
        }
    }

    func addDatabaseResultMenuItems(to menu: NSMenu, tabID: String, rows: IndexSet, column: Int) {
        let copyAs = NSMenu(title: "Copy As")
        for format in DBExportFormat.allCases {
            copyAs.addGridItem(format.title, enabled: !rows.isEmpty) { [weak self] in
                self?.copyDatabaseRows(tabID: tabID, rows: rows, format: format)
            }
        }
        let item = menu.addItem(withTitle: "Copy As", action: nil, keyEquivalent: "")
        item.submenu = copyAs
        menu.addGridItem("Export Result…", symbol: "square.and.arrow.up") { [weak self] in
            self?.presentExportResult(tabID)
        }
        addRelatedRowsMenuItems(to: menu, tabID: tabID, rows: rows, column: column)
    }

    private func addRelatedRowsMenuItems(to menu: NSMenu, tabID: String, rows: IndexSet, column: Int) {
        guard let table = database.result(tabID)?.table,
              !table.foreignKeyColumns.isEmpty || !table.referencingTables.isEmpty else { return }
        let row = rows.count == 1 ? rows.first : nil
        menu.addItem(.separator())
        if !table.foreignKeyColumns.isEmpty {
            menu.addGridItem("Show Referenced Row", symbol: DatabaseSymbol.referencedRow, enabled: row != nil && table.foreignKeyColumns.contains(column)) { [weak self] in
                guard let row else { return }
                self?.showRelatedRows(tabID: tabID, row: row, column: column, direction: .referenced)
            }
        }
        guard !table.referencingTables.isEmpty else { return }
        let submenu = NSMenu(title: "Show Referencing Rows")
        for target in table.referencingTables {
            let label = target.schema == table.schema || target.schema.isEmpty ? target.table : "\(target.schema).\(target.table)"
            submenu.addGridItem("\(label) (\(target.columns.joined(separator: ", ")))", enabled: row != nil) { [weak self] in
                guard let row else { return }
                self?.showRelatedRows(tabID: tabID, row: row, column: column, direction: .referencing, referencing: target)
            }
        }
        let item = menu.addItem(withTitle: "Show Referencing Rows", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: DatabaseSymbol.referencingRows, accessibilityDescription: nil)
        item.submenu = submenu
        item.isEnabled = row != nil
    }

    func detectDataSourcesInProject() {
        let root = activeWorkspacePath
        guard !root.isEmpty else {
            presentCommandFeedback("Open a project folder first to detect its data sources.", title: "Detect Data Sources")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.detectDataSources(root: root)
            DispatchQueue.main.async {
                guard self.activeWorkspacePath == root else { return }
                self.router.activeSheet = .detectDataSources(DBDetectSheetRequest(candidates: result.candidates))
            }
        }
    }

    func isAlreadyAdded(_ candidate: DBDataSourceDefinition) -> Bool {
        database.definitions.contains { existing in
            guard existing.engine == candidate.engine else { return false }
            if candidate.engineKind == .sqlite { return existing.sqlitePath == candidate.sqlitePath }
            return existing.host == candidate.host && existing.port == candidate.port && existing.database == candidate.database && existing.user == candidate.user
        }
    }

    func addDetectedDataSources(_ sources: [DBDataSourceDefinition], secrets: [String: String]) throws -> [DBIssue] {
        var file = database.file
        file.dataSources.append(contentsOf: sources)
        return try saveDataSources(file, secrets: secrets)
    }

    func publishSQLErrorDiagnostics(path: String, errors: [DBError]) {
        guard let session = documents[path] else { return }
        let text = session.storage.string as NSString
        var diagnostics: [DiagnosticData] = []
        let located = [DBError.syntax, DBError.server, DBError.constraint, DBError.permission]
        for error in errors where located.contains(error.kind) {
            guard let position = error.position, position.byte >= 0 else { continue }
            let start = min(session.utf8.utf16Offset(byte: position.byte), text.length)
            var end = start
            while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                end += 1
            }
            if end == start, start < text.length, text.character(at: start) != 10 { end = start + 1 }
            let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
            let line = text.substring(to: lineRange.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let detail = error.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            diagnostics.append(DiagnosticData(
                line: line,
                col: start - lineRange.location,
                endLine: line,
                endCol: max(start, end) - lineRange.location,
                severity: 1,
                message: detail.isEmpty ? error.message : detail,
                source: Self.sqlDiagnosticSource,
                code: error.code
            ))
        }
        let had = database.sqlErrorPaths.contains(path)
        guard had || !diagnostics.isEmpty else { return }
        replaceDiagnostics(at: path, dropping: { $0.source == Self.sqlDiagnosticSource }, with: diagnostics)
        if diagnostics.isEmpty {
            database.sqlErrorPaths.remove(path)
            removeSQLErrorObserver(path)
            return
        }
        database.sqlErrorPaths.insert(path)
        guard database.sqlErrorObservers[path] == nil else { return }
        database.sqlErrorObservers[path] = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? GoLensTextView)?.document?.path == path else { return }
            self.clearSQLErrorDiagnostics(path: path)
        }
    }

    func clearSQLErrorDiagnostics(path: String) {
        guard database.sqlErrorPaths.contains(path) else { return }
        publishSQLErrorDiagnostics(path: path, errors: [])
    }

    private func removeSQLErrorObserver(_ path: String) {
        if let observer = database.sqlErrorObservers.removeValue(forKey: path) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
