import AppKit
import Foundation

enum DatabaseCommandID {
    static let runStatement = "database.runStatement"
    static let runAllStatements = "database.runAll"
    static let stopStatement = "database.stop"
    static let submitChanges = "database.submitChanges"
    static let commit = "database.commit"
    static let rollBack = "database.rollBack"
    static let queryHistory = "database.queryHistory"
    static let explainPlan = "database.explainPlan"
    static let explainAnalyze = "database.explainAnalyze"
    static let exportResult = "database.exportResult"
    static let detectDataSources = "database.detectDataSources"
}

enum DatabaseUIConnection: Equatable {
    case notConnected
    case connecting
    case connected(transaction: String)
    case failed(DBError?)

    init(status: DBConnectionStatus, session: DBSessionState?, isRunning: Bool) {
        if let session, session.isConnected {
            self = .connected(transaction: session.transaction)
            return
        }
        switch status {
        case .connecting: self = .connecting
        case .failed(let error): self = .failed(error)
        case .connected: self = isRunning ? .connecting : .connected(transaction: "idle")
        case .notConnected: self = isRunning ? .connecting : .notConnected
        }
    }

    var title: String {
        switch self {
        case .notConnected: "Not Connected"
        case .connecting: "Connecting…"
        case .connected(let transaction): transaction == "active" ? "Transaction Active" : transaction == "failed" ? "Transaction Failed" : "Connected"
        case .failed: "Connection Failed"
        }
    }
}

extension DBDataSourceDefinition {
    var engineTitle: String { engineKind?.title ?? engine }
}

extension DBResultTab {
    var title: String {
        if let explain { return explain.analyze ? "Explain Analyze" : "Explain Plan" }
        if let table { return table.table }
        if let sourceLocation { return sourceLocation.title }
        return consolePath.isEmpty ? "Table" : "Line \(statement.line)"
    }
    var isFromConsole: Bool { !consolePath.isEmpty }
    var hasSource: Bool { isFromConsole || sourceLocation != nil }
    var sourcePath: String { sourceLocation?.path ?? consolePath }
    var sourceLine: Int { sourceLocation?.line ?? max(1, statement.line) }
}

protocol DatabaseUIModel: AnyObject {
    var uiDataSources: [DBDataSourceDefinition] { get }
    func uiAttachedDataSource(path: String) -> DBDataSourceDefinition?
    func uiAttach(path: String, dataSourceID: String?)
    func uiConnection(path: String) -> DatabaseUIConnection
    func uiIsRunning(path: String) -> Bool
    func uiCanRun(path: String) -> Bool
    func uiRunStatement(path: String)
    func uiRunAll(path: String)
    func uiStop(path: String)
    func uiDisconnect(dataSourceID: String)
    func uiIsConnected(dataSourceID: String) -> Bool
    func uiShowDataSources()
    func uiEditDataSource(id: String)

    var uiResults: [DBResultTab] { get }
    var uiSelectedResultID: String? { get set }
    var uiIsRunningAny: Bool { get }
    var uiRunError: DBError? { get }
    var uiRunDataSourceID: String? { get }
    func uiStopRunning()
    func uiCloseResult(id: String)
    func uiDismissRunError()
    func uiFetchAll(id: String)
    func uiStopFetchAll(id: String)
    func uiPageCache(for tab: DBResultTab) -> ResultPageCache?

    func uiSchemaChildren(dataSourceID: String, path: [String], refresh: Bool, completion: @escaping (Result<[DBNode], DBError>) -> Void)
    func uiOpenTable(dataSourceID: String, schema: String, table: String)

    func uiCompletionContext(path: String, text: String, caretByte: Int) -> DBCompleteRequest?
}

extension DatabaseUIModel {
    var uiSelectedResult: DBResultTab? {
        guard let id = uiSelectedResultID else { return uiResults.last }
        return uiResults.first { $0.id == id } ?? uiResults.last
    }
}

extension WorkspaceState: DatabaseUIModel {
    var databaseUI: any DatabaseUIModel { self }

    var uiDataSources: [DBDataSourceDefinition] { database.definitions }

    func uiAttachedDataSource(path: String) -> DBDataSourceDefinition? {
        databaseDataSourceID(forConsole: path).flatMap(database.definition)
    }

    func uiAttach(path: String, dataSourceID: String?) {
        attachDatabaseConsole(path, to: dataSourceID)
    }

    func uiConnection(path: String) -> DatabaseUIConnection {
        guard let id = databaseDataSourceID(forConsole: path) else { return .notConnected }
        let consoleID = database.consoleIDs[path]
        return DatabaseUIConnection(
            status: database.status(forDataSource: id),
            session: consoleID.flatMap(database.session(forConsole:)),
            isRunning: uiIsRunning(path: path)
        )
    }

    func uiIsRunning(path: String) -> Bool {
        guard let consoleID = database.consoleIDs[path] else { return false }
        return database.runningRun(forConsole: consoleID) != nil
    }

    func uiCanRun(path: String) -> Bool {
        databaseDataSourceID(forConsole: path) != nil && !uiIsRunning(path: path)
    }

    func uiRunStatement(path: String) {
        let selected = databaseTextView(for: path)?.selectedRange().length ?? 0
        runDatabase(mode: selected > 0 ? .selection : .caret, path: path)
    }

    func uiRunAll(path: String) {
        runDatabase(mode: .all, path: path)
    }

    func uiStop(path: String) {
        guard let consoleID = database.consoleIDs[path] else { return }
        stopDatabaseStatement(consoleID: consoleID)
    }

    func uiDisconnect(dataSourceID: String) {
        disconnectDataSource(dataSourceID)
    }

    func uiIsConnected(dataSourceID: String) -> Bool {
        isDataSourceConnected(dataSourceID)
    }

    func uiShowDataSources() {
        presentDataSources()
    }

    func uiEditDataSource(id: String) {
        presentDataSources(selecting: id)
    }

    var uiResults: [DBResultTab] { database.results }

    var uiSelectedResultID: String? {
        get { database.selectedResultID }
        set { database.selectedResultID = newValue }
    }

    var uiIsRunningAny: Bool { database.isAnyStatementRunning }

    var uiRunError: DBError? { database.runs.last?.error }

    var uiRunDataSourceID: String? { database.runs.last?.dataSourceID }

    func uiStopRunning() {
        stopDatabaseStatement()
    }

    func uiCloseResult(id: String) {
        closeDatabaseResult(id)
    }

    func uiDismissRunError() {
        guard let run = database.runs.last else { return }
        database.updateRun(run.id) { $0.error = nil }
    }

    func uiFetchAll(id: String) {
        fetchAllDatabaseResult(id)
    }

    func uiStopFetchAll(id: String) {
        guard let resultID = database.result(id)?.resultID else { return }
        DispatchQueue.global(qos: .userInitiated).async { DatabaseCore.cancel(resultID) }
    }

    func uiPageCache(for tab: DBResultTab) -> ResultPageCache? {
        databasePageCache(for: tab)
    }

    func uiSchemaChildren(dataSourceID: String, path: [String], refresh: Bool, completion: @escaping (Result<[DBNode], DBError>) -> Void) {
        let load = {
            self.loadDatabaseSchemaChildren(dataSourceID, path: path) { result in
                if let error = result.error {
                    completion(.failure(error))
                } else {
                    completion(.success(result.nodes))
                }
            }
        }
        guard path.isEmpty else {
            load()
            return
        }
        refreshDatabaseSchema(dataSourceID, refresh: refresh) { error in
            if let error {
                completion(.failure(error))
            } else {
                load()
            }
        }
    }

    func uiOpenTable(dataSourceID: String, schema: String, table: String) {
        openDatabaseTable(dataSourceID: dataSourceID, schema: schema, table: table)
    }

    func uiCompletionContext(path: String, text: String, caretByte: Int) -> DBCompleteRequest? {
        databaseCompletionRequest(path: path, text: text, caretByte: caretByte)
    }
}
