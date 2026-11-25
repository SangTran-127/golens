import AppKit
import Foundation
import GoLensFoundation

extension WorkspaceState {
    var isActiveFileSQL: Bool { ActiveCommandCapabilities.isSQLFile(activeFilePath) }

    var activeDatabaseConsoleDataSourceID: String? {
        databaseDataSourceID(forConsole: activeFilePath)
    }

    func databaseDataSourceID(forConsole path: String) -> String? {
        guard !path.isEmpty, ActiveCommandCapabilities.isSQLFile(path), database.hasDataSources else { return nil }
        if let id = database.attachments[path] {
            return database.definition(id) != nil ? id : nil
        }
        guard database.definitions.count == 1, !isInSQLCProject(path) else { return nil }
        return database.definitions.first?.id
    }

    private func isInSQLCProject(_ path: String) -> Bool {
        if let known = database.sqlcPaths[path] { return known }
        let root = activeWorkspacePath
        var dir = (path as NSString).deletingLastPathComponent
        var found = false
        while !dir.isEmpty, dir.hasPrefix(root) {
            if ["sqlc.yaml", "sqlc.yml", "sqlc.json"].contains(where: { FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }) {
                found = true
                break
            }
            if dir == root || dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        database.sqlcPaths[path] = found
        return found
    }

    static let sqlDiagnosticSource = "SQL"

    private static let historyDirectoryConfigured: Void = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let folder = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "GoLens", isDirectory: true)
            .appendingPathComponent("QueryHistory", isDirectory: true)
        DatabaseCore.setHistoryDirectory(folder.path)
    }()

    static func configureDatabaseHistoryDirectory() {
        _ = historyDirectoryConfigured
    }

    func loadDataSources() {
        let root = activeWorkspacePath
        guard database.loadedRoot != root else { return }
        database.reset()
        database.loadedRoot = root
        guard !root.isEmpty else {
            refreshCommandCapabilities()
            return
        }
        do {
            if let file = try DataSourceStore.shared.load(root: root) {
                database.file = file
                database.hasDefinitionsFile = true
            }
        } catch {
            database.hasDefinitionsFile = true
            database.loadError = "\(Self.failureReason(error)) GoLens keeps the file as it is until you save data sources again."
            appendLog("Could not read \(DataSourceStore.relativePath): \(error.localizedDescription)")
        }
        refreshCommandCapabilities()
    }

    func releaseAllDatabaseConsoles() {
        let consoleIDs = Set(database.consoleIDs.values)
            .union(database.sessions.keys)
            .union(database.results.map(\.consoleID))
        let allResults = database.removeResults { _ in true }
        database.selectedResultID = nil
        database.sessions.removeAll()
        database.transactionNotices.removeAll()
        database.transactionErrors.removeAll()
        database.runs.removeAll()
        releaseDatabaseResults(allResults)
        for consoleID in consoleIDs {
            database.queue(forConsole: consoleID).async {
                _ = DatabaseCore.closeConsole(consoleID, force: false)
            }
        }
    }

    func shutdownDatabase(root: String) {
        if !root.isEmpty {
            releaseAllDatabaseConsoles()
        }
        guard !root.isEmpty, database.configuredRoot == root else { return }
        database.configuredRoot = nil
        database.configuredFile = nil
        let stillOpen = Self.allRegisteredWorkspaces().contains { $0 !== self && $0.activeWorkspacePath == root }
        guard !stillOpen else { return }
        DispatchQueue.global(qos: .utility).async {
            DatabaseCore.shutdown(root: root)
        }
    }

    @discardableResult
    func ensureDatabaseConfigured() -> [DBIssue] {
        let root = activeWorkspacePath
        guard !root.isEmpty else { return [] }
        if database.configuredRoot == root, database.configuredFile == database.file {
            return database.configureIssues
        }
        guard database.hasDataSources || database.configuredRoot == root else { return [] }
        Self.configureDatabaseHistoryDirectory()
        let issues = DatabaseCore.configure(root: root, file: database.file)?.issues ?? []
        database.configuredRoot = root
        database.configuredFile = database.file
        database.configureIssues = issues
        return issues
    }

    func saveDataSources(_ file: DBDataSourcesFile, secrets: [String: String]) throws -> [DBIssue] {
        let root = activeWorkspacePath
        guard !root.isEmpty else { return [] }
        if database.loadError != nil {
            let path = DataSourceStore.filePath(root: root)
            let kept = path + ".unreadable"
            try? FileManager.default.removeItem(atPath: kept)
            try? FileManager.default.moveItem(atPath: path, toPath: kept)
        }
        var file = file
        file.dataSources = file.dataSources.map { $0.normalizedForEngine() }
        try DataSourceStore.shared.save(file, root: root)
        let previous = database.file
        let removed = previous.dataSources.filter { old in !file.dataSources.contains { $0.id == old.id } }
        for source in removed {
            DataSourceStore.shared.deleteSecret(dataSourceID: source.id)
            database.connectionStatus[source.id] = nil
            database.schemas[source.id] = nil
        }
        for source in file.dataSources where source.passwordMode != .keychain {
            DataSourceStore.shared.deleteSecret(dataSourceID: source.id)
        }
        var secretErrors: [String] = []
        for (id, secret) in secrets {
            guard let source = file.dataSources.first(where: { $0.id == id }), source.passwordMode == .keychain else { continue }
            do {
                try DataSourceStore.shared.writeSecret(secret, dataSourceID: id)
            } catch {
                secretErrors.append(source.name)
            }
        }
        for source in file.dataSources {
            if let old = previous.dataSources.first(where: { $0.id == source.id }), old != source {
                database.connectionStatus[source.id] = .notConnected
            }
        }
        database.file = file
        database.hasDefinitionsFile = true
        database.loadError = nil
        var issues: [DBIssue] = []
        if file.dataSources.isEmpty {
            if database.configuredRoot == root {
                _ = DatabaseCore.configure(root: root, file: file)
            }
            database.configuredRoot = nil
            database.configuredFile = nil
            database.configureIssues = []
        } else {
            issues = ensureDatabaseConfigured()
            for (id, secret) in secrets where file.dataSources.contains(where: { $0.id == id }) {
                DatabaseCore.setSecret(dataSourceID: id, secret: secret)
            }
        }
        refreshCommandCapabilities()
        if let session = documents[activeFilePath] {
            reloadGoplsCodeLenses(forPath: activeFilePath, version: session.version)
        }
        if !secretErrors.isEmpty {
            presentFailure(
                "Couldn’t Save the Password",
                "GoLens could not write the password for \(secretErrors.map { "“\($0)”" }.joined(separator: ", ")) to the Keychain. GoLens asks for it when it connects."
            )
        }
        return issues
    }

    func presentDataSources(selecting dataSourceID: String? = nil) {
        guard !activeWorkspacePath.isEmpty else {
            presentCommandFeedback("Open a project folder first to add data sources.", title: "Data Sources")
            return
        }
        router.activeSheet = .dataSources(DataSourcesSheetRequest(selectedDataSourceID: dataSourceID))
    }

    func testDataSourceConnection(_ definition: DBDataSourceDefinition, typedSecret: String, completion: @escaping (DBTestConnectionResult) -> Void) {
        let root = activeWorkspacePath
        let usesStoredSecret = definition.passwordMode == .keychain && typedSecret.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            var secret = definition.usesPassword ? typedSecret : ""
            if usesStoredSecret {
                secret = (try? DataSourceStore.shared.readSecret(dataSourceID: definition.id)) ?? nil ?? ""
            }
            let result = DatabaseCore.testConnection(DBTestConnectionRequest(definition: definition, secret: secret, workspaceRoot: root))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func showDatabasePanel() {
        if selectedConsoleTab != Self.databaseTab { selectedConsoleTab = Self.databaseTab }
        if !showConsole { showConsole = true }
    }

    func scheduleDatabaseCommandRefresh() {
        guard !database.commandRefreshScheduled else { return }
        database.commandRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + DatabaseState.commandRefreshDelay) { [weak self] in
            guard let self else { return }
            self.database.commandRefreshScheduled = false
            self.refreshCommandCapabilities()
        }
    }

    func setDatabaseConnectionStatus(_ status: DBConnectionStatus, for dataSourceID: String) {
        if database.connectionStatus[dataSourceID] != status {
            database.connectionStatus[dataSourceID] = status
        }
    }

    func attachDatabaseConsole(_ path: String, to dataSourceID: String?) {
        database.attachments[path] = dataSourceID ?? ""
        refreshCommandCapabilities()
    }

    func newQueryConsole(for dataSourceID: String? = nil) {
        guard !activeWorkspacePath.isEmpty else {
            presentCommandFeedback("Open a project folder first to create a query console.", title: "New Query Console")
            return
        }
        guard let source = dataSourceID.flatMap(database.definition) ?? activeDatabaseConsoleDataSourceID.flatMap(database.definition) ?? database.definitions.first else {
            presentDataSources()
            return
        }
        do {
            let path = try DataSourceStore.shared.createConsoleFile(root: activeWorkspacePath, dataSourceName: source.name)
            database.attachments[path] = source.id
            loadFiles(from: activeWorkspacePath)
            openFile(path)
            refreshCommandCapabilities()
        } catch {
            appendLog("Could not create a query console: \(error.localizedDescription)")
            presentCommandFeedback("Couldn’t create the query console. \(Self.failureReason(error))", title: "New Query Console", tone: .failure)
        }
    }

    func runDatabaseStatement() {
        guard let tv = activeTextView, tv.selectedRange().length > 0 else {
            runDatabase(mode: .caret, path: activeFilePath)
            return
        }
        runDatabase(mode: .selection, path: activeFilePath)
    }

    func runAllDatabaseStatements() {
        runDatabase(mode: .all, path: activeFilePath)
    }

    func databaseTextView(for path: String) -> NSTextView? {
        [activeTextView, primaryTextView, secondaryTextView]
            .compactMap { $0 as? GoLensTextView }
            .first { $0.document?.path == path }
    }

    struct DatabaseConsoleTarget {
        let path: String
        let consoleID: String
        let dataSourceID: String
        let text: String
        let caretByte: Int
        let selection: DBByteRange
        let caretLine: Int
    }

    func databaseConsoleTarget(mode: DBRunMode, path: String, title: String) -> DatabaseConsoleTarget? {
        guard ActiveCommandCapabilities.isSQLFile(path), let session = documents[path] else {
            presentCommandFeedback("Open a .sql file to run statements.", title: title)
            return nil
        }
        guard database.hasDataSources else {
            presentCommandFeedback("Add a data source in Tools ▸ Database ▸ Data Sources… to run SQL.", title: title)
            return nil
        }
        guard let dataSourceID = databaseDataSourceID(forConsole: path) else {
            presentCommandFeedback("Attach “\((path as NSString).lastPathComponent)” to a data source in Tools ▸ Database ▸ Attach Console To.", title: title)
            return nil
        }
        let range = databaseTextView(for: path)?.selectedRange() ?? NSRange(location: 0, length: 0)
        let location = min(range.location, session.length)
        let caretByte = session.utf8.byteOffset(location)
        let selection = mode == .selection
            ? DBByteRange(startByte: caretByte, endByte: session.utf8.byteOffset(min(range.location + range.length, session.length)))
            : DBByteRange()
        let text = session.storage.string
        let prefix = (text as NSString).substring(to: location)
        let caretLine = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return DatabaseConsoleTarget(
            path: path,
            consoleID: database.consoleID(forPath: path),
            dataSourceID: dataSourceID,
            text: text,
            caretByte: caretByte,
            selection: selection,
            caretLine: caretLine
        )
    }

    func runDatabase(mode: DBRunMode, path: String) {
        let title = mode == .all ? "Run All Statements in File" : "Run Statement"
        guard let target = databaseConsoleTarget(mode: mode, path: path, title: title) else { return }
        startDatabaseRun(
            consolePath: path,
            consoleID: target.consoleID,
            dataSourceID: target.dataSourceID,
            text: target.text,
            mode: mode,
            caretByte: target.caretByte,
            selection: target.selection
        )
    }

    static func browseConsoleID(_ dataSourceID: String) -> String {
        "browse-" + dataSourceID
    }

    func startDatabaseRun(consolePath: String, consoleID: String, dataSourceID: String, text: String, mode: DBRunMode, caretByte: Int, selection: DBByteRange, sourceLocation: DBSourceLocation? = nil) {
        let title = mode == .all ? "Run All Statements in File" : "Run Statement"
        guard database.runningRun(forConsole: consoleID) == nil else {
            presentCommandFeedback("A statement is still running in this console. Stop it before you run another one.", title: title)
            return
        }
        let issues = ensureDatabaseConfigured().filter { $0.id == dataSourceID }
        if let issue = issues.first {
            let name = database.definition(dataSourceID)?.name ?? "the data source"
            presentCommandFeedback("\(issue.message) Edit “\(name)” in Tools ▸ Database ▸ Data Sources….", title: title, tone: .warning)
            return
        }
        let execID = UUID().uuidString
        let request = DBExecuteRequest(
            execId: execID,
            consoleId: consoleID,
            dataSourceId: dataSourceID,
            workspaceRoot: activeWorkspacePath,
            text: text,
            mode: mode.rawValue,
            caretByte: caretByte,
            selection: selection,
            confirmed: [],
            pageSize: DatabaseState.pageSize
        )
        beginDatabaseRun(execID: execID, consoleID: consoleID, consolePath: consolePath, dataSourceID: dataSourceID, mode: mode, sourceLocation: sourceLocation)
        executeDatabaseRequest(request, secretRetried: false, signpost: DatabaseSignpost.begin())
    }

    func beginDatabaseRun(execID: String, consoleID: String, consolePath: String, dataSourceID: String, mode: DBRunMode, sourceLocation: DBSourceLocation? = nil) {
        database.runs.removeAll { $0.consoleID == consoleID && !$0.isRunning }
        database.runs.append(DBRun(id: execID, consoleID: consoleID, consolePath: consolePath, dataSourceID: dataSourceID, mode: mode, startedAt: Date(), sourceLocation: sourceLocation, isRunning: true))
        if database.consoleDataSources[consoleID] != dataSourceID {
            database.consoleDataSources[consoleID] = dataSourceID
        }
        Self.registerDatabaseConsole(consoleID, owner: self)
        if database.session(forConsole: consoleID)?.isConnected != true {
            setDatabaseConnectionStatus(.connecting, for: dataSourceID)
        }
        if !consolePath.isEmpty { clearSQLErrorDiagnostics(path: consolePath) }
        showDatabasePanel()
        scheduleDatabaseCommandRefresh()
    }

    func executeDatabaseRequest(_ request: DBExecuteRequest, secretRetried: Bool, signpost: DatabaseSignpost? = nil) {
        database.queue(forConsole: request.consoleId).async {
            let response = DatabaseCore.execute(request)
            let returnedAt = CFAbsoluteTimeGetCurrent()
            var firstPages: [String: ResultPage] = [:]
            for statement in response.statements where statement.hasRows && statement.error == nil {
                firstPages[statement.resultId] = DatabaseCore.fetchPage(resultID: statement.resultId, firstRow: 0, maxRows: Int32(request.pageSize))
            }
            DispatchQueue.main.async {
                self.handleDatabaseResponse(response, request: request, secretRetried: secretRetried, firstPages: firstPages, returnedAt: returnedAt, signpost: signpost)
            }
        }
    }

    private func handleDatabaseResponse(_ response: DBExecuteResponse, request: DBExecuteRequest, secretRetried: Bool, firstPages: [String: ResultPage], returnedAt: CFAbsoluteTime, signpost: DatabaseSignpost?) {
        measureLog(String(format: "database response on main %.1f ms after the core returned", (CFAbsoluteTimeGetCurrent() - returnedAt) * 1000))
        let dataSourceID = request.dataSourceId
        if let error = response.error, error.kind == DBError.needsSecret, !secretRetried, let source = database.definition(dataSourceID) {
            resolveDatabaseSecret(source) { secret in
                guard let secret else {
                    self.finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    self.database.connectionStatus[dataSourceID] = .notConnected
                    return
                }
                DatabaseCore.setSecret(dataSourceID: dataSourceID, secret: secret)
                self.executeDatabaseRequest(request, secretRetried: true, signpost: signpost)
            }
            return
        }
        if let error = response.error, error.kind == DBError.needsParameters, request.parameters == nil {
            if let session = response.session { applyDatabaseSession(session, consoleID: request.consoleId, dataSourceID: dataSourceID) }
            promptForDatabaseParameters(request, actionTitle: "Run") { values in
                guard let values else {
                    self.finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    return
                }
                var next = request
                next.parameters = values
                self.executeDatabaseRequest(next, secretRetried: secretRetried, signpost: signpost)
            }
            return
        }
        if !response.blocked.isEmpty {
            if let session = response.session { applyDatabaseSession(session, consoleID: request.consoleId, dataSourceID: dataSourceID) }
            confirmBlockedStatements(response.blocked, dataSourceID: dataSourceID) { confirmed in
                guard confirmed else {
                    self.finishDatabaseRun(request.execId, statements: [], error: nil, canceledBeforeRunning: true)
                    if self.database.session(forConsole: request.consoleId)?.isConnected != true {
                        self.database.connectionStatus[dataSourceID] = .notConnected
                    }
                    return
                }
                var next = request
                next.confirmed = response.blocked.map { DBConfirmation(hash: $0.hash, risk: $0.risk) }
                self.executeDatabaseRequest(next, secretRetried: secretRetried, signpost: signpost)
            }
            return
        }
        if let session = response.session {
            applyDatabaseSession(session, consoleID: request.consoleId, dataSourceID: dataSourceID)
        }
        if database.session(forConsole: request.consoleId)?.isConnected != true, database.status(forDataSource: dataSourceID) == .connecting {
            setDatabaseConnectionStatus(.notConnected, for: dataSourceID)
        }
        if let error = response.error ?? response.statements.last?.error, error.isConnectionFailure || error.kind == DBError.needsSecret {
            database.connectionStatus[dataSourceID] = .failed(error)
        }
        for statement in response.statements {
            upsertDatabaseResult(statement, execID: request.execId, consoleID: request.consoleId, dataSourceID: dataSourceID)
            if let page = firstPages[statement.resultId], let tab = database.result(Self.databaseResultID(statement, execID: request.execId)) {
                seedDatabasePageCache(for: tab, firstPage: page) { [encoded = statement.pageEncodedMs] in
                    let swiftMs = (CFAbsoluteTimeGetCurrent() - returnedAt) * 1000
                    signpost?.end()
                    measureLog(String(format: "database first rows shown: GoLens overhead %.1f ms (core page encode %.1f ms + Swift %.1f ms)", encoded + swiftMs, encoded, swiftMs))
                }
            }
        }
        finishDatabaseRun(request.execId, statements: response.statements, error: response.error, canceledBeforeRunning: false)
        if let path = database.runs.first(where: { $0.id == request.execId })?.consolePath, !path.isEmpty {
            publishSQLErrorDiagnostics(path: path, errors: ([response.error] + response.statements.map(\.error)).compactMap { $0 })
        }
        if let shown = response.statements.last(where: { !$0.resultId.isEmpty }) ?? response.statements.last {
            let id = Self.databaseResultID(shown, execID: request.execId)
            if database.selectedResultID != id { database.selectedResultID = id }
        }
        if response.statements.contains(where: { $0.kind == "ddl" && $0.error == nil }), case .loaded = database.schemas[dataSourceID] {
            refreshDatabaseSchema(dataSourceID, refresh: true)
        }
        measureLog(String(format: "database response applied %.1f ms after the core returned", (CFAbsoluteTimeGetCurrent() - returnedAt) * 1000))
    }

    func finishDatabaseRun(_ execID: String, statements: [DBStatementResult], error: DBError?, canceledBeforeRunning: Bool) {
        database.updateRun(execID) { run in
            run.isRunning = false
            run.finishedAt = Date()
            run.currentStatementIndex = nil
            if !statements.isEmpty { run.statements = statements }
            run.error = error
            run.wasCanceledBeforeRunning = canceledBeforeRunning
        }
        scheduleDatabaseCommandRefresh()
    }

    static func databaseResultID(_ statement: DBStatementResult, execID: String) -> String {
        statement.resultId.isEmpty ? "\(execID)#\(statement.index)" : statement.resultId
    }

    func upsertDatabaseResult(_ statement: DBStatementResult, execID: String, consoleID: String, dataSourceID: String) {
        let id = Self.databaseResultID(statement, execID: execID)
        if database.result(id) != nil {
            database.updateResult(id) { tab in
                tab.statement = statement
                tab.rowsFetched = max(tab.rowsFetched, statement.rowsFetched)
                tab.complete = tab.complete || statement.complete
            }
            return
        }
        guard let run = database.runs.first(where: { $0.id == execID }) else { return }
        let replaced = database.removeResults { $0.consoleID == consoleID && $0.execID != execID }
        if let selected = database.selectedResultID, replaced.contains(where: { $0.id == selected }) {
            database.selectedResultID = id
        }
        releaseDatabaseResults(replaced)
        database.results.append(DBResultTab(
            id: id,
            execID: execID,
            consoleID: consoleID,
            consolePath: database.consolePath(forID: consoleID) ?? "",
            dataSourceID: dataSourceID,
            sourceLocation: run.sourceLocation,
            statement: statement,
            rowsFetched: statement.rowsFetched,
            complete: statement.complete
        ))
    }

    func applyDatabaseSession(_ session: DBSessionState, consoleID: String, dataSourceID: String) {
        if database.sessions[consoleID] != session { database.sessions[consoleID] = session }
        if database.consoleDataSources[consoleID] != dataSourceID { database.consoleDataSources[consoleID] = dataSourceID }
        switch session.state {
        case DBSessionState.connected:
            setDatabaseConnectionStatus(.connected, for: dataSourceID)
            if database.schemas[dataSourceID] == nil {
                refreshDatabaseSchema(dataSourceID, refresh: false)
            }
        case DBSessionState.connecting:
            setDatabaseConnectionStatus(.connecting, for: dataSourceID)
        case DBSessionState.notConnected:
            if case .connected = database.status(forDataSource: dataSourceID),
               !database.sessions.contains(where: { database.consoleDataSources[$0.key] == dataSourceID && $0.value.isConnected }) {
                setDatabaseConnectionStatus(.notConnected, for: dataSourceID)
            }
        default:
            break
        }
        if !session.hasOpenTransaction, database.transactionNotices[consoleID] != nil {
            database.transactionNotices[consoleID] = nil
        }
        scheduleDatabaseCommandRefresh()
    }

    func handleDatabaseEvent(_ payload: String) {
        guard let event = try? JSONDecoder().decode(DBEvent.self, from: Data(payload.utf8)) else { return }
        DispatchQueue.main.async {
            self.applyDatabaseEvent(event)
        }
    }

    private func applyDatabaseEvent(_ event: DBEvent) {
        switch event.event {
        case DBEvent.statementStarted:
            guard let execID = event.execId, let statement = event.statement else { return }
            database.updateRun(execID) { $0.currentStatementIndex = statement.index }
        case DBEvent.statementFinished:
            guard let execID = event.execId, let statement = event.statement,
                  let run = database.runs.first(where: { $0.id == execID }) else { return }
            upsertDatabaseResult(statement, execID: execID, consoleID: run.consoleID, dataSourceID: run.dataSourceID)
        case DBEvent.fetchProgress:
            guard let resultID = event.resultId, let rows = event.rowsFetched else { return }
            database.updateResult(resultID) { tab in
                if tab.sortKeys.isEmpty { tab.rowsFetched = max(tab.rowsFetched, rows) }
            }
        case DBEvent.sessionState:
            guard let consoleID = event.consoleId, let session = event.session else { return }
            let dataSourceID = event.dataSourceId ?? database.consoleDataSources[consoleID] ?? ""
            applyDatabaseSession(session, consoleID: consoleID, dataSourceID: dataSourceID)
            if let minutes = event.transactionOpenMinutes, minutes > 0, session.hasOpenTransaction {
                database.transactionNotices[consoleID] = DBTransactionNotice(consoleID: consoleID, dataSourceID: dataSourceID, minutes: minutes)
            }
        default:
            break
        }
    }

    func stopDatabaseStatement(consoleID: String? = nil) {
        let targets = consoleID.map { id in database.runs.filter { $0.consoleID == id && $0.isRunning } }
            ?? database.runs.filter(\.isRunning)
        let fetching = database.results.filter { $0.isFetchingAll && (consoleID == nil || $0.consoleID == consoleID) }.compactMap(\.resultID)
        let ids = targets.map(\.execID) + fetching
        guard !ids.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for id in ids { DatabaseCore.cancel(id) }
        }
    }

    var canStopDatabaseStatement: Bool {
        database.isAnyStatementRunning || database.results.contains(where: \.isFetchingAll)
    }

    func fetchAllDatabaseResult(_ id: String) {
        guard let tab = database.result(id), let resultID = tab.resultID, !tab.complete, !tab.isFetchingAll else { return }
        database.updateResult(id) {
            $0.isFetchingAll = true
            $0.fetchAllError = nil
        }
        scheduleDatabaseCommandRefresh()
        database.queue(forConsole: tab.consoleID).async {
            let outcome = DatabaseCore.fetchAll(resultID: resultID)
            DispatchQueue.main.async {
                var resort: [DBSortKey] = []
                self.database.updateResult(id) { tab in
                    tab.isFetchingAll = false
                    tab.complete = outcome.complete
                    tab.fetchAllError = outcome.error?.kind == DBError.cancelled ? nil : outcome.error
                    if tab.sortKeys.isEmpty {
                        tab.rowsFetched = max(tab.rowsFetched, outcome.rowsFetched)
                    } else if outcome.complete {
                        resort = tab.sortKeys
                    }
                }
                self.scheduleDatabaseCommandRefresh()
                if !resort.isEmpty {
                    self.sortDatabaseResult(id, by: resort)
                }
            }
        }
    }

    func sortDatabaseResult(_ id: String, by keys: [DBSortKey], prefetchFrom firstRow: Int64 = 0) {
        guard let tab = database.result(id), let resultID = tab.resultID else { return }
        database.updateResult(id) {
            $0.isSorting = true
            $0.sortError = nil
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DatabaseCore.sort(resultID: resultID, keys: keys)
            let page = outcome.error == nil ? DatabaseCore.fetchPage(resultID: resultID, firstRow: firstRow, maxRows: Int32(DatabaseState.pageSize)) : nil
            DispatchQueue.main.async {
                if let page, page.resultVersion == outcome.version {
                    self.database.pageCaches[id]?.seed(page)
                }
                self.database.updateResult(id) { tab in
                    tab.isSorting = false
                    if let error = outcome.error {
                        tab.sortError = error
                        return
                    }
                    tab.sortKeys = keys
                    tab.resultVersion = outcome.version
                    tab.rowsFetched = max(tab.rowsFetched, outcome.sortedRows)
                    tab.complete = outcome.complete
                }
            }
        }
    }

    func closeDatabaseResult(_ id: String) {
        let closing = database.removeResults { $0.id == id }
        guard !closing.isEmpty else { return }
        if database.selectedResultID == id {
            database.selectedResultID = database.results.last?.id
        }
        releaseDatabaseResults(closing)
    }

    private func closeDatabaseResults(forConsole consoleID: String) {
        let closing = database.removeResults { $0.consoleID == consoleID }
        guard !closing.isEmpty else { return }
        if let selected = database.selectedResultID, closing.contains(where: { $0.id == selected }) {
            database.selectedResultID = database.results.last?.id
        }
        let fetching = closing.filter(\.isFetchingAll).compactMap(\.resultID)
        let ids = closing.compactMap(\.resultID)
        guard !ids.isEmpty else { return }
        database.queue(forConsole: consoleID).async {
            for id in fetching { DatabaseCore.cancel(id) }
            for id in ids { DatabaseCore.closeResult(id) }
        }
    }

    func releaseDatabaseResults(_ tabs: [DBResultTab]) {
        let fetching = tabs.filter(\.isFetchingAll).compactMap(\.resultID)
        let ids = tabs.compactMap(\.resultID)
        guard !ids.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for id in fetching { DatabaseCore.cancel(id) }
            for id in ids { DatabaseCore.closeResult(id) }
        }
    }

    func databasePageCache(for tab: DBResultTab) -> ResultPageCache? {
        guard tab.hasRows else { return nil }
        if let cache = database.pageCaches[tab.id] { return cache }
        return makeDatabasePageCache(for: tab, firstPage: nil)
    }

    func seedDatabasePageCache(for tab: DBResultTab, firstPage: ResultPage, onFirstRowsShown: @escaping () -> Void) {
        if let cache = database.pageCaches[tab.id] {
            cache.onFirstRowsShown = onFirstRowsShown
            cache.seedFirstPage(firstPage)
            return
        }
        makeDatabasePageCache(for: tab, firstPage: firstPage).onFirstRowsShown = onFirstRowsShown
    }

    @discardableResult
    func makeDatabasePageCache(for tab: DBResultTab, firstPage: ResultPage?) -> ResultPageCache {
        database.pageCaches.removeValue(forKey: tab.id)?.close()
        let cache = ResultPageCache(tab: tab, state: database, firstPage: firstPage)
        let id = tab.id
        cache.onRowsLoaded = { [weak self] end, reachedEnd in
            self?.database.updateResult(id) { tab in
                tab.rowsFetched = max(tab.rowsFetched, Int64(end))
                if reachedEnd { tab.complete = true }
            }
        }
        cache.onSort = { [weak self] keys, firstRow in
            self?.sortDatabaseResult(id, by: keys.map { DBSortKey(column: $0.column, descending: $0.descending) }, prefetchFrom: firstRow)
        }
        cache.onMenu = { [weak self] menu, rows, column in
            self?.addDatabaseResultMenuItems(to: menu, tabID: id, rows: rows, column: column)
        }
        database.pageCaches[id] = cache
        return cache
    }

    func refreshDatabaseSchema(_ dataSourceID: String, refresh: Bool, secretRetried: Bool = false, completion: ((DBError?) -> Void)? = nil) {
        guard database.definition(dataSourceID) != nil else {
            completion?(.internalFailure("GoLens does not know this data source. Open Data Sources and save it again."))
            return
        }
        if let issue = ensureDatabaseConfigured().first(where: { $0.id == dataSourceID }) {
            completion?(DBError(kind: DBError.connect, message: issue.message))
            return
        }
        database.schemas[dataSourceID] = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.introspect(DBIntrospectRequest(dataSourceId: dataSourceID, refresh: refresh))
            DispatchQueue.main.async {
                if let error = result.error {
                    if error.kind == DBError.needsSecret, !secretRetried, let source = self.database.definition(dataSourceID) {
                        self.resolveDatabaseSecret(source) { secret in
                            guard let secret else {
                                self.database.schemas[dataSourceID] = .failed(error)
                                completion?(error)
                                return
                            }
                            DatabaseCore.setSecret(dataSourceID: dataSourceID, secret: secret)
                            self.refreshDatabaseSchema(dataSourceID, refresh: refresh, secretRetried: true, completion: completion)
                        }
                        return
                    }
                    self.database.schemas[dataSourceID] = .failed(error)
                    if error.isConnectionFailure { self.database.connectionStatus[dataSourceID] = .failed(error) }
                    completion?(error)
                    return
                }
                self.database.schemas[dataSourceID] = .loaded(result)
                completion?(nil)
            }
        }
    }

    func loadDatabaseSchemaChildren(_ dataSourceID: String, path: [String], completion: @escaping (DBSchemaChildrenResult) -> Void) {
        ensureDatabaseConfigured()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DatabaseCore.schemaChildren(DBSchemaChildrenRequest(dataSourceId: dataSourceID, path: path))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func databaseCompletionRequest(path: String, text: String, caretByte: Int) -> DBCompleteRequest? {
        guard let id = databaseDataSourceID(forConsole: path), let engine = database.definition(id)?.engineKind else { return nil }
        ensureDatabaseConfigured()
        return DBCompleteRequest(dataSourceId: id, dialect: engine.dialect, text: text, caretByte: caretByte)
    }

    func disconnectDataSource(_ dataSourceID: String) {
        guard let source = database.definition(dataSourceID) else { return }
        let openConsoles = database.sessions.filter { database.consoleDataSources[$0.key] == dataSourceID && $0.value.hasOpenTransaction }
        let perform = {
            self.database.connectionStatus[dataSourceID] = .notConnected
            DispatchQueue.global(qos: .userInitiated).async {
                _ = DatabaseCore.disconnect(dataSourceID: dataSourceID)
                DispatchQueue.main.async {
                    for (consoleID, _) in self.database.consoleDataSources where self.database.consoleDataSources[consoleID] == dataSourceID {
                        self.database.sessions[consoleID] = nil
                        self.database.transactionNotices[consoleID] = nil
                    }
                    self.database.connectionStatus[dataSourceID] = .notConnected
                    self.scheduleDatabaseCommandRefresh()
                }
            }
        }
        guard !openConsoles.isEmpty else {
            perform()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Disconnect “\(source.name)” With an Open Transaction?"
        alert.informativeText = "Disconnecting rolls back the changes that are not committed yet."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disconnect").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            perform()
        }
    }

    func isDataSourceConnected(_ dataSourceID: String) -> Bool {
        database.status(forDataSource: dataSourceID) == .connected
    }

    func databaseConsoleNeedsCloseConfirmation(_ path: String) -> Bool {
        guard databaseConsoleHasOpenTransaction(path) else { return false }
        confirmDatabaseConsoleClose(path) { proceed in
            if proceed { self.closeTab(path) }
        }
        return true
    }

    func databaseConsoleHasOpenTransaction(_ path: String) -> Bool {
        guard let consoleID = database.consoleIDs[path] else { return false }
        return database.session(forConsole: consoleID)?.hasOpenTransaction == true
    }

    func confirmDatabaseConsolesClose(_ paths: [String], completion: @escaping (Bool) -> Void) {
        guard let first = paths.first(where: databaseConsoleHasOpenTransaction) else {
            completion(true)
            return
        }
        let rest = Array(paths.drop { $0 != first }.dropFirst())
        confirmDatabaseConsoleClose(first) { proceed in
            guard proceed else {
                completion(false)
                return
            }
            self.confirmDatabaseConsolesClose(rest, completion: completion)
        }
    }

    func confirmDatabaseConsoleClose(_ path: String, completion: @escaping (Bool) -> Void) {
        guard let consoleID = database.consoleIDs[path] else {
            completion(true)
            return
        }
        if openFiles.contains(path) { activeFilePath = path }
        let source = database.consoleDataSources[consoleID].flatMap(database.definition)
        let alert = NSAlert()
        alert.messageText = "Close Console With an Open Transaction?"
        alert.informativeText = "“\((path as NSString).lastPathComponent)” has changes on “\(source?.name ?? "the data source")” that are not committed yet. Commit them or roll them back before the console closes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Roll Back").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn:
                self.endDatabaseTransaction(consoleID: consoleID, commit: true, completion: completion)
            case .alertSecondButtonReturn:
                self.endDatabaseTransaction(consoleID: consoleID, commit: false, completion: completion)
            default:
                completion(false)
            }
        }
    }

    func endDatabaseTransaction(consoleID: String, commit: Bool, completion: @escaping (Bool) -> Void) {
        guard let dataSourceID = database.consoleDataSources[consoleID] else {
            completion(true)
            return
        }
        let request = DBTransactionRequest(consoleId: consoleID, dataSourceId: dataSourceID, action: commit ? DBTransactionAction.commit.rawValue : DBTransactionAction.rollback.rawValue)
        database.queue(forConsole: consoleID).async {
            let response = DatabaseCore.transaction(request)
            let failure = response.error
            if failure == nil {
                _ = DatabaseCore.closeConsole(consoleID, force: true)
            }
            DispatchQueue.main.async {
                if let failure {
                    self.presentFailure(
                        commit ? "Couldn’t Commit the Transaction" : "Couldn’t Roll Back the Transaction",
                        "\(failure.message) The console stays open so you can try again."
                    )
                    completion(false)
                    return
                }
                self.database.sessions[consoleID] = nil
                self.database.transactionNotices[consoleID] = nil
                completion(true)
            }
        }
    }

    func releaseDatabaseConsole(_ path: String) {
        guard let consoleID = database.consoleIDs[path] else { return }
        closeDatabaseResults(forConsole: consoleID)
        database.sessions[consoleID] = nil
        database.transactionNotices[consoleID] = nil
        database.transactionErrors[consoleID] = nil
        database.runs.removeAll { $0.consoleID == consoleID }
        clearSQLErrorDiagnostics(path: path)
        database.queue(forConsole: consoleID).async {
            _ = DatabaseCore.closeConsole(consoleID, force: false)
        }
    }

    func resolveDatabaseSecret(_ source: DBDataSourceDefinition, completion: @escaping (String?) -> Void) {
        switch source.passwordMode {
        case .none:
            completion("")
        case .ask:
            promptForDatabaseSecret(source, offerSave: false, completion: completion)
        case .keychain:
            DispatchQueue.global(qos: .userInitiated).async {
                let stored = (try? DataSourceStore.shared.readSecret(dataSourceID: source.id)) ?? nil
                DispatchQueue.main.async {
                    if let stored {
                        completion(stored)
                    } else {
                        self.promptForDatabaseSecret(source, offerSave: true, completion: completion)
                    }
                }
            }
        }
    }

    private func promptForDatabaseSecret(_ source: DBDataSourceDefinition, offerSave: Bool, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Enter the Password for “\(source.name)”"
        let user = source.user.isEmpty ? "" : " as \(source.user)"
        alert.informativeText = "GoLens connects to \(source.summary)\(user)."
        alert.alertStyle = .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Password"
        field.setAccessibilityLabel("Password")
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if offerSave {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Save in Keychain"
            alert.suppressionButton?.state = .on
        }
        alert.window.initialFirstResponder = field
        present(alert) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let secret = field.stringValue
            if offerSave, alert.suppressionButton?.state == .on {
                DispatchQueue.global(qos: .userInitiated).async {
                    try? DataSourceStore.shared.writeSecret(secret, dataSourceID: source.id)
                }
            }
            completion(secret)
        }
    }

    func confirmBlockedStatements(_ blocked: [DBBlocked], dataSourceID: String, completion: @escaping (Bool) -> Void) {
        let source = database.definition(dataSourceID)
        let sourceName = source?.name ?? "this data source"
        let alert = NSAlert()
        if blocked.count == 1, let item = blocked.first {
            alert.messageText = "Run Statement on “\(sourceName)”?"
            alert.informativeText = "“\(Self.blockedPreview(item))”\n\n" + Self.riskConsequence(item, sourceName: sourceName)
            alert.addButton(withTitle: "Run Statement").hasDestructiveAction = true
        } else {
            alert.messageText = "Run \(UserMessage.count(blocked.count, "Risky Statement", "Risky Statements")) on “\(sourceName)”?"
            let lines = blocked.map { "Line \($0.line): \(Self.blockedPreview($0)). \(Self.riskConsequence($0, sourceName: sourceName))" }
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.addButton(withTitle: "Run Statements").hasDestructiveAction = true
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    private static func blockedPreview(_ item: DBBlocked) -> String {
        let preview = item.preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return preview.count > 80 ? String(preview.prefix(79)) + "…" : preview
    }

    static func riskConsequence(_ item: DBBlocked, sourceName: String) -> String {
        let target = item.table.isEmpty ? "the table" : "“\(item.table)”"
        switch item.risk {
        case DBRisk.deleteWithoutWhere:
            return "The statement has no WHERE clause, so it deletes every row in \(target). This can’t be undone."
        case DBRisk.updateWithoutWhere:
            return "The statement has no WHERE clause, so it changes every row in \(target)."
        case DBRisk.truncate:
            return "This removes every row in \(target). This can’t be undone."
        case DBRisk.dropTable:
            return "This deletes \(target) and all of its rows. This can’t be undone."
        case DBRisk.dropSchema:
            return "This deletes the schema \(item.table.isEmpty ? "" : "“\(item.table)” ")and everything in it. This can’t be undone."
        case DBRisk.dropDatabase:
            return "This deletes the database \(item.table.isEmpty ? "" : "“\(item.table)” ")and everything in it. This can’t be undone."
        case DBRisk.productionWrite:
            return "“\(sourceName)” is marked as production, and this statement changes data."
        default:
            return "This statement can change or remove data."
        }
    }
}
