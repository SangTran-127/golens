import AppKit
import Foundation
import GoLensFoundation

struct DBTableName: Hashable, Sendable {
    let dataSourceID: String
    let schema: String
    let table: String
}

extension WorkspaceState {
    func resolveDatabaseTable(inConsole path: String, reference: SQLNameReference, completion: @escaping (DBTableName?) -> Void) {
        let parts = reference.parts.suffix(2)
        guard let name = parts.last, let dataSourceID = databaseDataSourceID(forConsole: path),
              let engine = database.definition(dataSourceID)?.engineKind else { return completion(nil) }
        let qualifier = parts.count == 2 ? parts.first : nil
        let text = "SELECT * FROM " + (qualifier.map { ($0.quoted ? engine.quoteIdentifier($0.name) : $0.name) + "." } ?? "")
        ensureDatabaseConfigured()
        let request = DBCompleteRequest(dataSourceId: dataSourceID, dialect: engine.dialect, text: text, caretByte: text.utf8.count)
        DispatchQueue.global(qos: .userInitiated).async {
            let relations = DatabaseCore.complete(request)?.items.filter { $0.kind == "table" || $0.kind == "view" } ?? []
            let match = relations.first { $0.label == name.name } ?? relations.first { relation in
                guard !name.quoted else { return false }
                return engine == .postgres ? relation.label == name.name.lowercased() : relation.label.caseInsensitiveCompare(name.name) == .orderedSame
            }
            DispatchQueue.main.async {
                completion(match.map { DBTableName(dataSourceID: dataSourceID, schema: $0.detail, table: $0.label) })
            }
        }
    }

    func tableTab(forConsole consoleID: String) -> DBResultTab? {
        database.results.last { $0.consoleID == consoleID && $0.table != nil }
    }

    func openDatabaseTable(dataSourceID: String, schema: String, table: String, filter: String? = nil) {
        let consoleID = Self.browseConsoleID(dataSourceID)
        let current = tableTab(forConsole: consoleID)
        let sameTable = current?.table.map { $0.schema == schema && $0.table == table } == true
        var binding = (sameTable ? current?.table : nil) ?? DBTableBinding(schema: schema, table: table)
        if let filter {
            binding.filter = filter
        }
        confirmDiscardingTableChanges(current, reason: "Opening “\(table)” discards them.") {
            self.loadDatabaseTable(dataSourceID: dataSourceID, binding: binding)
        }
    }

    func showRelatedRows(tabID: String, row: Int, column: Int, direction: DBRelatedDirection, referencing pick: DBReferencingTable? = nil) {
        guard let tab = database.result(tabID), let resultID = tab.resultID else { return }
        let title = direction == .referenced ? "Show Referenced Row" : "Show Referencing Rows"
        let request = DBRelatedRowsRequest(resultId: resultID, row: Int64(row), column: column, direction: direction)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.relatedRows(request)
            DispatchQueue.main.async {
                if let error = result.error {
                    self.presentCommandFeedback(error.message, title: title, tone: .warning)
                    return
                }
                let target = pick.flatMap { p in
                    result.targets.first { $0.schema == p.schema && $0.table == p.table && $0.columns == p.columns }
                } ?? (pick == nil ? result.targets.first : nil)
                guard let target else {
                    self.presentCommandFeedback("The key of this row is NULL, so no rows in “\(pick?.table ?? "the table")” reference it.", title: title, tone: .warning)
                    return
                }
                self.openDatabaseTable(dataSourceID: tab.dataSourceID, schema: target.schema, table: target.table, filter: target.where)
            }
        }
    }

    func reloadDatabaseTable(_ tabID: String, filter: String? = nil, orderBy: String? = nil, sortKeys: [DBSortKey]? = nil, discardingChanges: Bool = false) {
        guard let tab = database.result(tabID), var binding = tab.table else { return }
        if let filter { binding.filter = filter }
        if let orderBy {
            binding.orderBy = orderBy
            if sortKeys == nil { binding.sortKeys = [] }
        }
        if let sortKeys { binding.sortKeys = sortKeys }
        let load = { self.loadDatabaseTable(dataSourceID: tab.dataSourceID, binding: binding) }
        if discardingChanges {
            load()
        } else {
            confirmDiscardingTableChanges(tab, reason: "Reloading “\(binding.table)” discards them.", then: load)
        }
    }

    func confirmDiscardingTableChanges(_ tab: DBResultTab?, reason: String, then proceed: @escaping () -> Void) {
        guard let tab, let session = database.editSessions[tab.id], session.hasChanges else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard Changes to “\(tab.table?.table ?? "the table")”?"
        alert.informativeText = "\(UserMessage.count(session.changeCount, "row has", "rows have")) changes that are not submitted. \(reason)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed()
        }
    }

    private func loadDatabaseTable(dataSourceID: String, binding: DBTableBinding, notice: DBResultNotice? = nil) {
        let consoleID = Self.browseConsoleID(dataSourceID)
        guard database.runningRun(forConsole: consoleID) == nil else {
            presentCommandFeedback("A statement is still running for this data source. Stop it before you open the table again.", title: "Open Table")
            return
        }
        if let issue = ensureDatabaseConfigured().first(where: { $0.id == dataSourceID }) {
            let name = database.definition(dataSourceID)?.name ?? "the data source"
            presentCommandFeedback("\(issue.message) Edit “\(name)” in Tools ▸ Database ▸ Data Sources….", title: "Open Table", tone: .warning)
            return
        }
        let execID = UUID().uuidString
        let request = DBOpenTableRequest(
            execId: execID,
            consoleId: consoleID,
            dataSourceId: dataSourceID,
            workspaceRoot: activeWorkspacePath,
            schema: binding.schema,
            table: binding.table,
            where: binding.filter.trimmingCharacters(in: .whitespacesAndNewlines),
            orderBy: binding.orderBy.trimmingCharacters(in: .whitespacesAndNewlines),
            pageSize: DatabaseState.pageSize
        )
        beginDatabaseRun(execID: execID, consoleID: consoleID, consolePath: "", dataSourceID: dataSourceID, mode: .all)
        runOpenTable(request, binding: binding, notice: notice, secretRetried: false, signpost: DatabaseSignpost.begin())
    }

    private func runOpenTable(_ request: DBOpenTableRequest, binding: DBTableBinding, notice: DBResultNotice?, secretRetried: Bool, signpost: DatabaseSignpost?) {
        database.queue(forConsole: request.consoleId).async {
            let response = DatabaseCore.openTable(request)
            let returnedAt = CFAbsoluteTimeGetCurrent()
            var firstPage: ResultPage?
            if let statement = response.statements.first, statement.hasRows, statement.error == nil {
                firstPage = DatabaseCore.fetchPage(resultID: statement.resultId, firstRow: 0, maxRows: Int32(request.pageSize))
            }
            DispatchQueue.main.async {
                self.handleOpenTable(response, request: request, binding: binding, notice: notice, firstPage: firstPage, returnedAt: returnedAt, secretRetried: secretRetried, signpost: signpost)
            }
        }
    }

    private func handleOpenTable(_ response: DBOpenTableResponse, request: DBOpenTableRequest, binding: DBTableBinding, notice: DBResultNotice?, firstPage: ResultPage?, returnedAt: CFAbsoluteTime, secretRetried: Bool, signpost: DatabaseSignpost?) {
        let dataSourceID = request.dataSourceId
        let consoleID = request.consoleId
        if let session = response.session { applyDatabaseSession(session, consoleID: consoleID, dataSourceID: dataSourceID) }
        if let error = response.error, error.kind == DBError.needsSecret, !secretRetried, let source = database.definition(dataSourceID) {
            resolveDatabaseSecret(source) { secret in
                guard let secret else {
                    self.finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    self.database.connectionStatus[dataSourceID] = .notConnected
                    return
                }
                DatabaseCore.setSecret(dataSourceID: dataSourceID, secret: secret)
                self.runOpenTable(request, binding: binding, notice: notice, secretRetried: true, signpost: signpost)
            }
            return
        }
        if !response.blocked.isEmpty {
            confirmBlockedStatements(response.blocked, dataSourceID: dataSourceID) { confirmed in
                guard confirmed else {
                    self.finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    return
                }
                var next = request
                next.confirmed = response.blocked.map { DBConfirmation(hash: $0.hash, risk: $0.risk) }
                self.runOpenTable(next, binding: binding, notice: notice, secretRetried: secretRetried, signpost: signpost)
            }
            return
        }
        if database.session(forConsole: consoleID)?.isConnected != true, database.status(forDataSource: dataSourceID) == .connecting {
            setDatabaseConnectionStatus(.notConnected, for: dataSourceID)
        }
        if let error = response.error, error.isConnectionFailure || error.kind == DBError.needsSecret {
            database.connectionStatus[dataSourceID] = .failed(error)
        }
        let existing = tableTab(forConsole: consoleID)
        guard let statement = response.statements.first, response.error == nil, statement.error == nil else {
            let failure = response.error ?? response.statements.first?.error
            if let existing, existing.table?.schema == binding.schema, existing.table?.table == binding.table, let failure, !DatabaseErrorPresentation.isConnection(failure) {
                database.updateResult(existing.id) { tab in
                    tab.notice = DBResultNotice(kind: .warning, title: "Couldn’t Apply the Filter", message: [failure.message, failure.detail].compactMap { $0 }.joined(separator: " "))
                }
                finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: false)
            } else {
                finishDatabaseRun(request.execId, statements: response.statements, error: failure, canceledBeforeRunning: false)
            }
            return
        }
        upsertDatabaseResult(statement, execID: request.execId, consoleID: consoleID, dataSourceID: dataSourceID)
        let id = Self.databaseResultID(statement, execID: request.execId)
        var bound = binding
        bound.sql = response.sql
        bound.editable = response.editable
        bound.keyColumns = response.keyColumns
        bound.reason = response.reason
        bound.readOnlyColumns = response.readOnlyColumns
        bound.foreignKeyColumns = response.foreignKeyColumns
        bound.referencingTables = response.referencingTables
        bound.rowCount = .unknown
        database.updateResult(id) { tab in
            tab.table = bound
            tab.notice = notice
        }
        if let tab = database.result(id), let page = firstPage {
            seedDatabasePageCache(for: tab, firstPage: page) { [encoded = statement.pageEncodedMs] in
                let swiftMs = (CFAbsoluteTimeGetCurrent() - returnedAt) * 1000
                signpost?.end()
                measureLog(String(format: "database table rows shown: GoLens overhead %.1f ms (core page encode %.1f ms + Swift %.1f ms)", encoded + swiftMs, encoded, swiftMs))
            }
        }
        finishDatabaseRun(request.execId, statements: response.statements, error: nil, canceledBeforeRunning: false)
        if database.selectedResultID != id { database.selectedResultID = id }
    }

    func databaseGridSource(for tab: DBResultTab) -> (any DataGridSource)? {
        guard let cache = databasePageCache(for: tab) else { return nil }
        guard let table = tab.table else { return cache }
        if let source = database.tableSources[tab.id], source.cache === cache { return source }
        let session = database.editSessions[tab.id] ?? DatabaseEditSession()
        database.editSessions[tab.id] = session
        let source = DatabaseTableGridSource(cache: cache, session: session, table: table, dataSourceReadOnlyReason: dataSourceReadOnlyReason(tab.dataSourceID))
        let id = tab.id
        source.onSort = { [weak self] keys in
            self?.sortDatabaseTable(id, keys: keys)
        }
        source.onRefused = { [weak self] reason in
            self?.presentCommandFeedback(reason, title: "Can’t Edit This Cell", tone: .warning)
        }
        database.tableSources[tab.id] = source
        return source
    }

    private func dataSourceReadOnlyReason(_ dataSourceID: String) -> String? {
        guard let source = database.definition(dataSourceID), source.readOnly else { return nil }
        return "“\(source.name)” is read-only. Turn off Read-only in Edit Data Source to change rows."
    }

    private func sortDatabaseTable(_ tabID: String, keys: [DataGridSortKey]) {
        guard let tab = database.result(tabID), let engine = database.definition(tab.dataSourceID)?.engineKind else { return }
        let columns = tab.statement.columns
        let orderBy = keys.compactMap { key -> String? in
            guard columns.indices.contains(key.column) else { return nil }
            return engine.quoteIdentifier(columns[key.column].name) + (key.descending ? " DESC" : " ASC")
        }.joined(separator: ", ")
        reloadDatabaseTable(tabID, orderBy: orderBy, sortKeys: keys.map { DBSortKey(column: $0.column, descending: $0.descending) })
    }

    func countDatabaseTableRows(_ tabID: String) {
        guard let tab = database.result(tabID), let binding = tab.table else { return }
        if case .counting(let execID) = binding.rowCount {
            DispatchQueue.global(qos: .userInitiated).async { DatabaseCore.cancel(execID) }
            return
        }
        let execID = UUID().uuidString
        database.updateResult(tabID) { $0.table?.rowCount = .counting(execID) }
        let request = DBCountRowsRequest(execId: execID, dataSourceId: tab.dataSourceID, schema: binding.schema, table: binding.table, where: binding.filter.trimmingCharacters(in: .whitespacesAndNewlines))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.countRows(request)
            DispatchQueue.main.async {
                self.database.updateResult(tabID) { tab in
                    guard case .counting(let current) = tab.table?.rowCount, current == execID else { return }
                    if let count = result.count {
                        tab.table?.rowCount = .counted(count)
                    } else if let error = result.error, error.kind != DBError.cancelled {
                        tab.table?.rowCount = .failed(error)
                    } else {
                        tab.table?.rowCount = .unknown
                    }
                }
            }
        }
    }

    var selectedTableTabWithChanges: DBResultTab? {
        guard let tab = database.selectedResult, tab.table != nil, database.editSessions[tab.id]?.hasChanges == true else { return nil }
        return tab
    }

    var canSubmitDatabaseChanges: Bool { selectedTableTabWithChanges != nil }

    func submitDatabaseChanges() {
        guard let tab = selectedTableTabWithChanges, let resultID = tab.resultID, let session = database.editSessions[tab.id] else {
            presentCommandFeedback("Edit cells, add rows or delete rows in a table first. Open a table from the schema in the Database panel.", title: "Submit Changes")
            return
        }
        let request = session.request(resultID: resultID)
        let tableName = tab.table?.table ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = DatabaseCore.planEdits(request)
            DispatchQueue.main.async {
                if let error = plan.error {
                    self.presentCommandFeedback(error.message, title: "Couldn’t Prepare the Changes", tone: .failure)
                    return
                }
                session.issues = plan.issues
                self.router.activeSheet = .submitChanges(DBSubmitPreview(tabID: tab.id, dataSourceID: tab.dataSourceID, table: tableName, plan: plan, request: request))
            }
        }
    }

    enum DatabaseApplyOutcome {
        case applied
        case failed(DBError, failedStatement: Int?)
    }

    @discardableResult
    func applyDatabaseChanges(_ preview: DBSubmitPreview, completion: @escaping (DatabaseApplyOutcome) -> Void) -> String? {
        guard let tab = database.result(preview.tabID) else {
            completion(.failed(DBError.internalFailure("The table was closed, so GoLens couldn’t submit the changes."), failedStatement: nil))
            return nil
        }
        var request = preview.request
        let execID = UUID().uuidString
        request.execId = execID
        request.confirmed = preview.plan.blocked.map { DBConfirmation(hash: $0.hash, risk: $0.risk) }
        let consoleID = tab.consoleID
        database.queue(forConsole: consoleID).async {
            let result = DatabaseCore.applyEdits(request)
            DispatchQueue.main.async {
                if let session = result.session { self.applyDatabaseSession(session, consoleID: consoleID, dataSourceID: tab.dataSourceID) }
                if let error = result.error {
                    completion(.failed(error, failedStatement: result.failedStatement))
                    return
                }
                guard result.applied else {
                    completion(.failed(DBError(kind: DBError.internalError, message: "The changes changed after the preview, so GoLens didn’t submit them. Submit them again."), failedStatement: nil))
                    return
                }
                let rows = UserMessage.quantity(Int(result.rowsAffected), "row", "rows")
                let notice = result.committed
                    ? DBResultNotice(kind: .success, title: "Changes Submitted", message: "\(rows) changed and committed.")
                    : DBResultNotice(kind: .warning, title: "Changes Not Committed Yet", message: "\(rows) changed inside the open transaction. Commit to keep the changes or Roll Back to undo them.")
                self.database.editSessions[tab.id]?.revertAll()
                if var binding = tab.table {
                    binding.rowCount = .unknown
                    self.loadDatabaseTable(dataSourceID: tab.dataSourceID, binding: binding, notice: notice)
                }
                completion(.applied)
            }
        }
        return execID
    }

    func cancelDatabaseApply(_ execID: String) {
        DispatchQueue.global(qos: .userInitiated).async { DatabaseCore.cancel(execID) }
    }

    func addDatabaseRowFromToolbar(_ tabID: String) {
        database.tableSources[tabID]?.gridAddRow()
    }

    func revertAllDatabaseChanges(_ tabID: String) {
        database.tableSources[tabID]?.gridRevertAll()
    }
}
