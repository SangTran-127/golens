import Foundation
import GoLensFoundation
import Observation
import os

final class DatabaseSignpost: @unchecked Sendable {
    private static let signposter = OSSignposter(subsystem: "app.golens", category: "Database")
    private let state: OSSignpostIntervalState
    private var ended = false

    private init(state: OSSignpostIntervalState) {
        self.state = state
    }

    static func begin() -> DatabaseSignpost {
        DatabaseSignpost(state: signposter.beginInterval("Run to First Rows", id: signposter.makeSignpostID()))
    }

    func end() {
        guard !ended else { return }
        ended = true
        Self.signposter.endInterval("Run to First Rows", state)
    }
}

enum DBConnectionStatus: Equatable, Sendable {
    case notConnected
    case connecting
    case connected
    case failed(DBError)

    var title: String {
        switch self {
        case .notConnected: "Not Connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }
}

struct DBSourceLocation: Equatable, Sendable {
    let path: String
    let line: Int

    var title: String { "\((path as NSString).lastPathComponent):\(line)" }
}

struct DBRun: Identifiable, Equatable, Sendable {
    let id: String
    let consoleID: String
    let consolePath: String
    let dataSourceID: String
    let mode: DBRunMode
    let startedAt: Date
    var sourceLocation: DBSourceLocation? = nil
    var finishedAt: Date?
    var isRunning: Bool
    var currentStatementIndex: Int?
    var statements: [DBStatementResult] = []
    var error: DBError?
    var wasCanceledBeforeRunning = false

    var execID: String { id }
}

struct DBResultTab: Identifiable, Equatable, Sendable {
    let id: String
    let execID: String
    let consoleID: String
    let consolePath: String
    let dataSourceID: String
    var sourceLocation: DBSourceLocation? = nil
    var statement: DBStatementResult
    var rowsFetched: Int64
    var complete: Bool
    var isFetchingAll = false
    var fetchAllError: DBError?
    var sortKeys: [DBSortKey] = []
    var resultVersion: UInt32 = 0
    var isSorting = false
    var sortError: DBError?

    var table: DBTableBinding?
    var explain: DBExplainOutcome?
    var export: DBExportProgress?
    var cursorClosed = false
    var notice: DBResultNotice?

    var resultID: String? { statement.resultId.isEmpty ? nil : statement.resultId }
    var hasRows: Bool { resultID != nil }
    var isSortedLoadedRowsOnly: Bool { !sortKeys.isEmpty && !complete }
    var canFetchMore: Bool { !complete && !statement.truncated && !cursorClosed }
}

enum DBRowCount: Equatable, Sendable {
    case unknown
    case counting(String)
    case counted(Int64)
    case failed(DBError)
}

struct DBTableBinding: Equatable, Sendable {
    let schema: String
    let table: String
    var filter: String = ""
    var orderBy: String = ""
    var sql: String = ""
    var editable = false
    var keyColumns: [String] = []
    var reason: String = ""
    var readOnlyColumns: [DBReadOnlyColumn] = []
    var foreignKeyColumns: [Int] = []
    var referencingTables: [DBReferencingTable] = []
    var sortKeys: [DBSortKey] = []
    var rowCount: DBRowCount = .unknown
}

struct DBExplainOutcome: Equatable, Sendable {
    let analyze: Bool
    let result: DBExplainResult
}

struct DBExportProgress: Equatable, Sendable {
    let execID: String
    let format: DBExportFormat
    let path: String
}

struct DBResultNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case warning
        case info
    }

    let kind: Kind
    let title: String
    let message: String
    var revealPath: String? = nil
}

struct DBParameterPrompt: Identifiable, Equatable {
    let id = UUID()
    let consoleID: String
    let dataSourceID: String
    let statementText: String
    let dialect: String
    let parameters: [DBParameter]
    let remembered: [String: DBParamValue]
    let actionTitle: String
}

struct DBSubmitPreview: Identifiable, Equatable {
    let id = UUID()
    let tabID: String
    let dataSourceID: String
    let table: String
    var plan: DBPlanEditsResult
    var request: DBEditRequest
}

struct DBExportSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let tabID: String
}

struct DBDetectSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let candidates: [DBDetectCandidate]
}

enum DBSchemaLoad: Equatable, Sendable {
    case idle
    case loading
    case loaded(DBIntrospectResult)
    case failed(DBError)
}

struct DBTransactionNotice: Equatable, Sendable {
    let consoleID: String
    let dataSourceID: String
    let minutes: Int
}

@Observable
final class DatabaseState: @unchecked Sendable {
    static let attachmentsDefaultsKey = "GoLensDatabaseConsoleAttachments"
    static let defaultDataSourcesDefaultsKey = "GoLensDatabaseDefaultDataSources"
    static let pageSize = 500
    static let commandRefreshDelay: TimeInterval = 0.15

    var file = DBDataSourcesFile()
    var hasDefinitionsFile = false
    var loadError: String?
    var configureIssues: [DBIssue] = []
    var attachments: [String: String] = (UserDefaults.standard.dictionary(forKey: DatabaseState.attachmentsDefaultsKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(attachments, forKey: Self.attachmentsDefaultsKey) }
    }
    var defaultDataSourceIDs: [String: String] = (UserDefaults.standard.dictionary(forKey: DatabaseState.defaultDataSourcesDefaultsKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(defaultDataSourceIDs, forKey: Self.defaultDataSourcesDefaultsKey) }
    }
    var consoleIDs: [String: String] = [:]
    var sessions: [String: DBSessionState] = [:]
    var connectionStatus: [String: DBConnectionStatus] = [:]
    var runs: [DBRun] = []
    var results: [DBResultTab] = []
    var selectedResultID: String?
    var schemas: [String: DBSchemaLoad] = [:]
    var transactionNotices: [String: DBTransactionNotice] = [:]
    var consoleDataSources: [String: String] = [:]
    var editSessions: [String: DatabaseEditSession] = [:]
    var isolationLevels: [String: [String]] = [:]
    var transactionErrors: [String: DBError] = [:]
    var historyDataSourceID: String?

    @ObservationIgnored var tableSources: [String: DatabaseTableGridSource] = [:]
    @ObservationIgnored var parameterValues: [String: [String: DBParamValue]] = [:]
    @ObservationIgnored var parameterCompletions: [UUID: ([DBParamValue]?) -> Void] = [:]
    @ObservationIgnored var sqlErrorPaths: Set<String> = []
    @ObservationIgnored var sqlErrorObservers: [String: NSObjectProtocol] = [:]
    @ObservationIgnored var loadedRoot: String?
    @ObservationIgnored var sqlcPaths: [String: Bool] = [:]
    @ObservationIgnored let goSQLSites = TextKeyedCache<[DBGoSQLSite]>(capacity: 64)
    @ObservationIgnored var configuredRoot: String?
    @ObservationIgnored var configuredFile: DBDataSourcesFile?
    @ObservationIgnored var pageCaches: [String: ResultPageCache] = [:]
    @ObservationIgnored var commandRefreshScheduled = false
    @ObservationIgnored private var consoleQueues: [String: DispatchQueue] = [:]
    @ObservationIgnored private let queueLock = NSLock()

    var definitions: [DBDataSourceDefinition] { file.dataSources }
    var hasDataSources: Bool { !file.dataSources.isEmpty }

    func definition(_ id: String) -> DBDataSourceDefinition? {
        file.dataSources.first { $0.id == id }
    }

    func consoleID(forPath path: String) -> String {
        if let id = consoleIDs[path] { return id }
        let id = UUID().uuidString
        consoleIDs[path] = id
        return id
    }

    func consolePath(forID id: String) -> String? {
        consoleIDs.first { $0.value == id }?.key
    }

    func queue(forConsole id: String) -> DispatchQueue {
        queueLock.lock()
        defer { queueLock.unlock() }
        if let q = consoleQueues[id] { return q }
        let q = DispatchQueue(label: "golens.database.console", qos: .userInitiated)
        consoleQueues[id] = q
        return q
    }

    func runningRun(forConsole id: String) -> DBRun? {
        runs.first { $0.consoleID == id && $0.isRunning }
    }

    func latestRun(forConsole id: String) -> DBRun? {
        runs.last { $0.consoleID == id }
    }

    var isAnyStatementRunning: Bool { runs.contains { $0.isRunning } }

    func results(forConsole id: String) -> [DBResultTab] {
        results.filter { $0.consoleID == id }
    }

    var selectedResult: DBResultTab? {
        guard let selectedResultID else { return results.last }
        return results.first { $0.id == selectedResultID } ?? results.last
    }

    func result(_ id: String) -> DBResultTab? {
        results.first { $0.id == id }
    }

    func updateResult(_ id: String, _ change: (inout DBResultTab) -> Void) {
        guard let idx = results.firstIndex(where: { $0.id == id }) else { return }
        var tab = results[idx]
        let before = (tab.rowsFetched, tab.resultVersion, tab.complete)
        change(&tab)
        results[idx] = tab
        if before != (tab.rowsFetched, tab.resultVersion, tab.complete) {
            pageCaches[id]?.resultChanged(tab)
        }
    }

    func removeResults(where shouldRemove: (DBResultTab) -> Bool) -> [DBResultTab] {
        let removed = results.filter(shouldRemove)
        guard !removed.isEmpty else { return [] }
        results.removeAll(where: shouldRemove)
        for tab in removed {
            pageCaches.removeValue(forKey: tab.id)?.close()
            tableSources[tab.id] = nil
            editSessions[tab.id] = nil
        }
        return removed
    }

    func updateRun(_ id: String, _ change: (inout DBRun) -> Void) {
        guard let idx = runs.firstIndex(where: { $0.id == id }) else { return }
        var run = runs[idx]
        change(&run)
        runs[idx] = run
    }

    func status(forDataSource id: String) -> DBConnectionStatus {
        connectionStatus[id] ?? .notConnected
    }

    func session(forConsole id: String) -> DBSessionState? {
        sessions[id]
    }

    func reset() {
        file = DBDataSourcesFile()
        hasDefinitionsFile = false
        loadError = nil
        configureIssues = []
        consoleIDs = [:]
        sessions = [:]
        connectionStatus = [:]
        runs = []
        for cache in pageCaches.values { cache.close() }
        pageCaches = [:]
        tableSources = [:]
        editSessions = [:]
        isolationLevels = [:]
        transactionErrors = [:]
        historyDataSourceID = nil
        parameterValues = [:]
        parameterCompletions = [:]
        results = []
        selectedResultID = nil
        schemas = [:]
        transactionNotices = [:]
        consoleDataSources = [:]
        sqlcPaths = [:]
        goSQLSites.removeAll()
        configuredRoot = nil
        configuredFile = nil
        queueLock.lock()
        consoleQueues = [:]
        queueLock.unlock()
    }
}

enum DatabaseCore {
    static let cellValueMaxBytes: Int32 = 1 << 20

    private static func call<T: Decodable>(_ type: T.Type, _ body: () -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let ptr = body() else { return nil }
        defer { FreeGoCString(ptr) }
        return try? JSONDecoder().decode(T.self, from: Data(String(cString: ptr).utf8))
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "{}"
    }

    static func configure(root: String, file: DBDataSourcesFile) -> DBConfigureResult? {
        let text = json(file)
        return call(DBConfigureResult.self) { root.withCString { r in text.withCString { DBConfigure(r, $0) } } }
    }

    @discardableResult
    static func setSecret(dataSourceID: String, secret: String) -> Bool {
        call(DBOKResult.self) { dataSourceID.withCString { id in secret.withCString { DBSetSecret(id, $0) } } }?.ok ?? false
    }

    static func shutdown(root: String) {
        root.withCString { DBShutdownWorkspace($0) }
    }

    static func stats() -> DBStatsResponse? {
        call(DBStatsResponse.self) { DBStats() }
    }

    static func testConnection(_ request: DBTestConnectionRequest) -> DBTestConnectionResult {
        let text = json(request)
        return call(DBTestConnectionResult.self) { text.withCString { DBTestConnection($0) } }
            ?? DBTestConnectionResult(ok: false, serverVersion: "", latencyMs: 0, error: .internalFailure())
    }

    static func disconnect(dataSourceID: String) -> DBDisconnectResult? {
        call(DBDisconnectResult.self) { dataSourceID.withCString { DBDisconnect($0) } }
    }

    static func closeConsole(_ consoleID: String, force: Bool) -> DBDisconnectResult? {
        call(DBDisconnectResult.self) { consoleID.withCString { DBCloseConsole($0, force ? 1 : 0) } }
    }

    static func statements(text: String, dialect: String) -> [DBStatementInfo] {
        call([DBStatementInfo].self) { text.withCString { t in dialect.withCString { DBStatements(t, $0) } } } ?? []
    }

    static func execute(_ request: DBExecuteRequest) -> DBExecuteResponse {
        let text = json(request)
        return call(DBExecuteResponse.self) { text.withCString { DBExecute($0) } }
            ?? DBExecuteResponse(execId: request.execId, blocked: [], statements: [], session: nil, error: .internalFailure())
    }

    @discardableResult
    static func cancel(_ id: String) -> Bool {
        id.withCString { DBCancel($0) } == 1
    }

    static func fetchPage(resultID: String, firstRow: Int64, maxRows: Int32) -> ResultPage? {
        var length: Int64 = 0
        let buffer = resultID.withCString { DBFetchPage($0, firstRow, maxRows, &length) }
        guard let buffer else { return nil }
        guard length > 0 else {
            FreeGoBuffer(buffer)
            return nil
        }
        return try? ResultPage.adopt(UnsafeRawPointer(buffer), count: Int(length)) { FreeGoBuffer(buffer) }
    }

    static func fetchAll(resultID: String) -> DBFetchAllResult {
        call(DBFetchAllResult.self) { resultID.withCString { DBFetchAll($0) } }
            ?? DBFetchAllResult(rowsFetched: 0, complete: false, spoolDiskBytes: 0, error: .internalFailure())
    }

    static func sort(resultID: String, keys: [DBSortKey]) -> DBSortResponse {
        let text = json(keys)
        return call(DBSortResponse.self) { resultID.withCString { r in text.withCString { DBSortResult(r, $0) } } }
            ?? DBSortResponse(version: 0, sortedRows: 0, complete: false, error: .internalFailure())
    }

    static func cellValue(resultID: String, row: Int64, column: Int32, maxBytes: Int32 = cellValueMaxBytes) -> DBCellValueResponse? {
        call(DBCellValueResponse.self) { resultID.withCString { DBCellValue($0, row, column, maxBytes) } }
    }

    static func closeResult(_ resultID: String) {
        resultID.withCString { DBCloseResult($0) }
    }

    static func introspect(_ request: DBIntrospectRequest) -> DBIntrospectResult {
        let text = json(request)
        return call(DBIntrospectResult.self) { text.withCString { DBIntrospect($0) } }
            ?? DBIntrospectResult(schemas: [], defaultSchema: "", error: .internalFailure())
    }

    static func schemaChildren(_ request: DBSchemaChildrenRequest) -> DBSchemaChildrenResult {
        let text = json(request)
        return call(DBSchemaChildrenResult.self) { text.withCString { DBSchemaChildren($0) } }
            ?? DBSchemaChildrenResult(nodes: [], error: .internalFailure())
    }

    static func complete(_ request: DBCompleteRequest) -> DBCompleteResult? {
        let text = json(request)
        return call(DBCompleteResult.self) { text.withCString { DBComplete($0) } }
    }

    static func openTable(_ request: DBOpenTableRequest) -> DBOpenTableResponse {
        let text = json(request)
        return call(DBOpenTableResponse.self) { text.withCString { DBOpenTable($0) } }
            ?? DBOpenTableResponse(execId: request.execId, session: nil, error: .internalFailure())
    }

    static func countRows(_ request: DBCountRowsRequest) -> DBCountRowsResult {
        let text = json(request)
        return call(DBCountRowsResult.self) { text.withCString { DBCountRows($0) } }
            ?? DBCountRowsResult(count: nil, error: .internalFailure())
    }

    static func planEdits(_ request: DBEditRequest) -> DBPlanEditsResult {
        let text = json(request)
        return call(DBPlanEditsResult.self) { text.withCString { DBPlanEdits($0) } }
            ?? DBPlanEditsResult(error: .internalFailure())
    }

    static func applyEdits(_ request: DBEditRequest) -> DBApplyEditsResult {
        let text = json(request)
        return call(DBApplyEditsResult.self) { text.withCString { DBApplyEdits($0) } }
            ?? DBApplyEditsResult(applied: false, committed: false, rowsAffected: 0, failedStatement: nil, error: .internalFailure(), session: nil)
    }

    static func transaction(_ request: DBTransactionRequest) -> DBTransactionResult {
        let text = json(request)
        return call(DBTransactionResult.self) { text.withCString { DBTransaction($0) } }
            ?? DBTransactionResult(session: nil, error: .internalFailure())
    }

    static func explain(_ request: DBExplainRequest) -> DBExplainResult {
        let text = json(request)
        return call(DBExplainResult.self) { text.withCString { DBExplain($0) } }
            ?? DBExplainResult(plan: nil, analyzed: request.analyze, rolledBack: false, session: nil, error: .internalFailure())
    }

    static func export(_ request: DBExportRequest) -> DBExportResult {
        let text = json(request)
        return call(DBExportResult.self) { text.withCString { DBExport($0) } }
            ?? DBExportResult(rowsWritten: 0, bytes: 0, error: .internalFailure())
    }

    static func detectDataSources(root: String) -> DBDetectResult {
        call(DBDetectResult.self) { root.withCString { DBDetectDataSources($0) } } ?? DBDetectResult()
    }

    static func parameters(text: String, dialect: String, startByte: Int, endByte: Int) -> [DBParameter] {
        call(DBParametersResult.self) {
            text.withCString { t in dialect.withCString { DBParameters(t, $0, Int64(startByte), Int64(endByte)) } }
        }?.parameters ?? []
    }

    static func history(_ request: DBHistoryRequest) -> DBHistoryResult {
        let text = json(request)
        return call(DBHistoryResult.self) { text.withCString { DBHistory($0) } }
            ?? DBHistoryResult(error: .internalFailure())
    }

    static func goSQLSites(path: String, content: String, root: String) -> DBGoSQLSitesResult {
        call(DBGoSQLSitesResult.self) {
            path.withCString { p in content.withCString { c in root.withCString { DBGoSQLSites(p, c, $0) } } }
        } ?? DBGoSQLSitesResult()
    }

    static func sqlcQuery(path: String, content: String, line: Int) -> DBSqlcQueryResult {
        call(DBSqlcQueryResult.self) {
            path.withCString { p in content.withCString { DBSqlcQuery(p, $0, Int32(line)) } }
        } ?? DBSqlcQueryResult(error: .internalFailure())
    }

    static func relatedRows(_ request: DBRelatedRowsRequest) -> DBRelatedRowsResult {
        let text = json(request)
        return call(DBRelatedRowsResult.self) { text.withCString { DBRelatedRows($0) } }
            ?? DBRelatedRowsResult(error: .internalFailure())
    }

    @discardableResult
    static func setHistoryDirectory(_ path: String) -> Bool {
        call(DBOKResult.self) { path.withCString { DBSetHistoryDirectory($0) } }?.ok ?? false
    }
}
