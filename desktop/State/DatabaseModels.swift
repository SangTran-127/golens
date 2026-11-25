import Foundation

enum DBJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DBJSONValue])
    case object([String: DBJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([DBJSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: DBJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

struct DBAnyKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func dbUnknownFields(_ decoder: Decoder, known: Set<String>) throws -> [String: DBJSONValue] {
    let c = try decoder.container(keyedBy: DBAnyKey.self)
    var extra: [String: DBJSONValue] = [:]
    for key in c.allKeys where !known.contains(key.stringValue) {
        extra[key.stringValue] = try c.decode(DBJSONValue.self, forKey: key)
    }
    return extra
}

private func dbEncodeUnknownFields(_ extra: [String: DBJSONValue], to encoder: Encoder) throws {
    guard !extra.isEmpty else { return }
    var c = encoder.container(keyedBy: DBAnyKey.self)
    for (key, value) in extra {
        try c.encode(value, forKey: DBAnyKey(key))
    }
}

@propertyWrapper
struct DBList<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element] = []) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? [] : try c.decode([Element].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: DBList<T>.Type, forKey key: Key) throws -> DBList<T> {
        try decodeIfPresent(type, forKey: key) ?? DBList(wrappedValue: [])
    }
}

enum DBEngine: String, CaseIterable, Identifiable, Sendable {
    case postgres
    case mysql
    case sqlite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        }
    }

    var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        }
    }

    var defaultSchema: String {
        switch self {
        case .postgres: "public"
        case .mysql: ""
        case .sqlite: "main"
        }
    }

    var dialect: String { rawValue }

    func quoteIdentifier(_ name: String) -> String {
        switch self {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }
}

enum DBPasswordMode: String, CaseIterable, Identifiable, Sendable {
    case keychain
    case ask
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keychain: "Save in Keychain"
        case .ask: "Ask Every Time"
        case .none: "No Password"
        }
    }
}

enum DBSSLMode: String, CaseIterable, Identifiable, Sendable {
    case disable
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disable: "Disable"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify Full"
        }
    }
}

struct DBSSLOptions: Codable, Hashable, Sendable {
    var mode: String = DBSSLMode.prefer.rawValue
    var rootCert: String = ""
    var cert: String = ""
    var key: String = ""
    var extra: [String: DBJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode, rootCert, cert, key
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        rootCert = try c.decodeIfPresent(String.self, forKey: .rootCert) ?? ""
        cert = try c.decodeIfPresent(String.self, forKey: .cert) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        extra = try dbUnknownFields(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        try dbEncodeUnknownFields(extra, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(rootCert, forKey: .rootCert)
        try c.encode(cert, forKey: .cert)
        try c.encode(key, forKey: .key)
    }
}

struct DBSSHOptions: Codable, Hashable, Sendable {
    var destination: String = ""
    var port: Int = 0

    var isEnabled: Bool { !destination.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct DBDataSourceDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var engine: String
    var host: String = ""
    var port: Int = 0
    var database: String = ""
    var user: String = ""
    var password: String = DBPasswordMode.none.rawValue
    var ssl = DBSSLOptions()
    var sqlitePath: String = ""
    var sqliteCreate: Bool = false
    var defaultSchema: String = ""
    var readOnly: Bool = false
    var production: Bool = false
    var transactionMode: String = ""
    var ssh = DBSSHOptions()
    var extra: [String: DBJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, engine, host, port, database, user, password, ssl, sqlitePath, sqliteCreate, defaultSchema, readOnly, production, transactionMode, ssh
    }

    init(id: String = UUID().uuidString, name: String, engine: DBEngine) {
        self.id = id
        self.name = name
        self.engine = engine.rawValue
        self.port = engine.defaultPort
        self.defaultSchema = engine.defaultSchema
        if engine == .sqlite {
            ssl.mode = DBSSLMode.disable.rawValue
        } else {
            host = "localhost"
            password = DBPasswordMode.keychain.rawValue
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? DBPasswordMode.none.rawValue
        ssl = try c.decodeIfPresent(DBSSLOptions.self, forKey: .ssl) ?? DBSSLOptions()
        sqlitePath = try c.decodeIfPresent(String.self, forKey: .sqlitePath) ?? ""
        sqliteCreate = try c.decodeIfPresent(Bool.self, forKey: .sqliteCreate) ?? false
        defaultSchema = try c.decodeIfPresent(String.self, forKey: .defaultSchema) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        production = try c.decodeIfPresent(Bool.self, forKey: .production) ?? false
        transactionMode = try c.decodeIfPresent(String.self, forKey: .transactionMode) ?? ""
        ssh = try c.decodeIfPresent(DBSSHOptions.self, forKey: .ssh) ?? DBSSHOptions()
        extra = try dbUnknownFields(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        try dbEncodeUnknownFields(extra, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(engine, forKey: .engine)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(database, forKey: .database)
        try c.encode(user, forKey: .user)
        try c.encode(password, forKey: .password)
        try c.encode(ssl, forKey: .ssl)
        try c.encode(sqlitePath, forKey: .sqlitePath)
        try c.encode(sqliteCreate, forKey: .sqliteCreate)
        try c.encode(defaultSchema, forKey: .defaultSchema)
        try c.encode(readOnly, forKey: .readOnly)
        try c.encode(production, forKey: .production)
        if !transactionMode.isEmpty {
            try c.encode(transactionMode, forKey: .transactionMode)
        }
        if ssh.isEnabled || ssh.port != 0 {
            try c.encode(ssh, forKey: .ssh)
        }
    }

    var effectiveTransactionMode: DBTransactionMode {
        DBTransactionMode(rawValue: transactionMode) ?? (production ? .manual : .auto)
    }

    var engineKind: DBEngine? { DBEngine(rawValue: engine) }

    func normalizedForEngine() -> DBDataSourceDefinition {
        var source = self
        switch engineKind {
        case .sqlite:
            source.host = ""
            source.port = 0
            source.database = ""
            source.user = ""
            source.password = DBPasswordMode.none.rawValue
            source.ssl.mode = DBSSLMode.disable.rawValue
            source.ssl.rootCert = ""
            source.ssl.cert = ""
            source.ssl.key = ""
            if source.defaultSchema.isEmpty || source.defaultSchema == DBEngine.postgres.defaultSchema { source.defaultSchema = DBEngine.sqlite.defaultSchema }
            source.ssh = DBSSHOptions()
        case .postgres, .mysql:
            source.sqlitePath = ""
            source.sqliteCreate = false
            source.ssh.destination = source.ssh.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.ssh.isEnabled { source.ssh.port = 0 }
        case nil:
            break
        }
        return source
    }
    var passwordMode: DBPasswordMode { DBPasswordMode(rawValue: password) ?? .none }
    var usesPassword: Bool { engineKind != .sqlite && passwordMode != .none }

    var summary: String {
        guard let kind = engineKind else { return engine }
        switch kind {
        case .sqlite:
            return sqlitePath.isEmpty ? kind.title : (sqlitePath as NSString).lastPathComponent
        case .postgres, .mysql:
            let address = host.isEmpty ? kind.title : (port > 0 ? "\(host):\(port)" : host)
            let target = database.isEmpty ? address : "\(address)/\(database)"
            return ssh.isEnabled ? "\(target) through \(ssh.destination)" : target
        }
    }
}

struct DBDataSourcesFile: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int = DBDataSourcesFile.currentVersion
    var dataSources: [DBDataSourceDefinition] = []
    var extra: [String: DBJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, dataSources
    }

    init(dataSources: [DBDataSourceDefinition] = []) {
        self.dataSources = dataSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        dataSources = try c.decodeIfPresent([DBDataSourceDefinition].self, forKey: .dataSources) ?? []
        extra = try dbUnknownFields(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        try dbEncodeUnknownFields(extra, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(dataSources, forKey: .dataSources)
    }
}

struct DBPosition: Codable, Hashable, Sendable {
    let byte: Int
    let line: Int
    let col: Int
}

struct DBError: Codable, Hashable, Sendable, Error {
    static let needsSecret = "needsSecret"
    static let connect = "connect"
    static let auth = "auth"
    static let tls = "tls"
    static let timeout = "timeout"
    static let syntax = "syntax"
    static let permission = "permission"
    static let constraint = "constraint"
    static let readOnly = "readOnly"
    static let cancelled = "cancelled"
    static let connectionLost = "connectionLost"
    static let server = "server"
    static let internalError = "internal"
    static let needsParameters = "needsParameters"
    static let transactionOpen = "transactionOpen"
    static let unsupported = "unsupported"
    static let tooLarge = "tooLarge"
    static let conflict = "conflict"

    let kind: String
    let message: String
    var detail: String? = nil
    var code: String? = nil
    var position: DBPosition? = nil

    var isConnectionFailure: Bool {
        [Self.connect, Self.auth, Self.tls, Self.timeout, Self.connectionLost].contains(kind)
    }

    static func internalFailure(_ message: String = "GoLens could not complete the request because of an internal error.") -> DBError {
        DBError(kind: internalError, message: message)
    }
}

struct DBIssue: Codable, Hashable, Sendable {
    let id: String
    let field: String
    let message: String
}

struct DBConfigureResult: Codable, Hashable, Sendable {
    @DBList var issues: [DBIssue] = []
}

struct DBOKResult: Codable, Hashable, Sendable {
    let ok: Bool
}

struct DBStatsResponse: Codable, Hashable, Sendable {
    let sessions: Int
    let pools: Int
    let openResults: Int
    let spoolMemBytes: Int64
    let spoolDiskBytes: Int64
    let goroutines: Int
    var tunnels: [DBTunnelInfo]? = nil
}

struct DBTunnelInfo: Codable, Hashable, Sendable {
    let dataSourceId: String
    let pid: Int
    let localPort: Int
    let destination: String
}

struct DBTestConnectionRequest: Codable, Hashable, Sendable {
    let definition: DBDataSourceDefinition
    let secret: String
    let workspaceRoot: String
}

struct DBTestConnectionResult: Codable, Hashable, Sendable {
    let ok: Bool
    let serverVersion: String
    let latencyMs: Int64
    let error: DBError?
}

struct DBDisconnectResult: Codable, Hashable, Sendable {
    let ok: Bool
    let hadOpenTransaction: Bool
}

struct DBStatementInfo: Codable, Hashable, Sendable {
    let index: Int
    let startByte: Int
    let endByte: Int
    let line: Int
    let kind: String
    let writes: Bool
    @DBList var risks: [String] = []
}

struct DBStatementsRequest: Codable, Hashable, Sendable {
    let dialect: String
    let text: String
}

struct DBByteRange: Codable, Hashable, Sendable {
    var startByte: Int = 0
    var endByte: Int = 0
}

struct DBConfirmation: Codable, Hashable, Sendable {
    let hash: String
    let risk: String
}

enum DBRunMode: String, Codable, Sendable {
    case caret
    case selection
    case all
}

struct DBExecuteRequest: Codable, Hashable, Sendable {
    let execId: String
    let consoleId: String
    let dataSourceId: String
    let workspaceRoot: String
    let text: String
    let mode: String
    let caretByte: Int
    let selection: DBByteRange
    var confirmed: [DBConfirmation]
    let pageSize: Int
    var parameters: [DBParamValue]? = nil
    var source: String? = nil
}

enum DBRisk {
    static let deleteWithoutWhere = "deleteWithoutWhere"
    static let updateWithoutWhere = "updateWithoutWhere"
    static let truncate = "truncate"
    static let dropTable = "dropTable"
    static let dropSchema = "dropSchema"
    static let dropDatabase = "dropDatabase"
    static let productionWrite = "productionWrite"
}

struct DBBlocked: Codable, Hashable, Sendable {
    let index: Int
    let hash: String
    let risk: String
    let table: String
    let line: Int
    let preview: String
}

struct DBOrigin: Codable, Hashable, Sendable {
    let schema: String
    let table: String
    let column: String
}

struct DBColumn: Codable, Hashable, Sendable {
    let name: String
    let dbType: String
    let kind: String
    let nullable: Bool?
    let origin: DBOrigin?
}

struct DBStatementResult: Codable, Hashable, Sendable {
    let index: Int
    let line: Int
    let startByte: Int
    let endByte: Int
    let kind: String
    let resultId: String
    @DBList var columns: [DBColumn] = []
    let rowsFetched: Int64
    let complete: Bool
    let truncated: Bool
    let rowsAffected: Int64?
    let durationMs: Double
    let firstRowMs: Double
    let pageEncodedMs: Double
    @DBList var notices: [String] = []
    let error: DBError?

    var hasRows: Bool { !resultId.isEmpty }
}

struct DBSessionState: Codable, Hashable, Sendable {
    static let notConnected = "notConnected"
    static let connecting = "connecting"
    static let connected = "connected"
    static let failed = "failed"

    let state: String
    let transaction: String
    let schema: String
    var mode: String = DBTransactionMode.auto.rawValue
    var isolation: String = ""

    private enum CodingKeys: String, CodingKey {
        case state, transaction, schema, mode, isolation
    }

    init(state: String, transaction: String, schema: String, mode: String = DBTransactionMode.auto.rawValue, isolation: String = "") {
        self.state = state
        self.transaction = transaction
        self.schema = schema
        self.mode = mode
        self.isolation = isolation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        transaction = try c.decode(String.self, forKey: .transaction)
        schema = try c.decode(String.self, forKey: .schema)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? DBTransactionMode.auto.rawValue
        isolation = try c.decodeIfPresent(String.self, forKey: .isolation) ?? ""
    }

    var isConnected: Bool { state == Self.connected }
    var hasOpenTransaction: Bool { transaction == "active" || transaction == "failed" }
    var transactionMode: DBTransactionMode { DBTransactionMode(rawValue: mode) ?? .auto }
}

enum DBTransactionMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto-Commit"
        case .manual: "Manual"
        }
    }
}

struct DBExecuteResponse: Codable, Hashable, Sendable {
    let execId: String
    @DBList var blocked: [DBBlocked] = []
    @DBList var statements: [DBStatementResult] = []
    let session: DBSessionState?
    let error: DBError?
}

struct DBEvent: Codable, Hashable, Sendable {
    static let statementStarted = "statementStarted"
    static let statementFinished = "statementFinished"
    static let fetchProgress = "fetchProgress"
    static let sessionState = "sessionState"

    let event: String
    let execId: String?
    let consoleId: String?
    let dataSourceId: String?
    let statement: DBStatementResult?
    let resultId: String?
    let rowsFetched: Int64?
    let session: DBSessionState?
    let transactionOpenMinutes: Int?
}

struct DBFetchAllResult: Codable, Hashable, Sendable {
    let rowsFetched: Int64
    let complete: Bool
    let spoolDiskBytes: Int64
    let error: DBError?
}

struct DBSortKey: Codable, Hashable, Sendable {
    let column: Int
    let descending: Bool
}

struct DBSortResponse: Codable, Hashable, Sendable {
    let version: UInt32
    let sortedRows: Int64
    let complete: Bool
    let error: DBError?
}

struct DBCellValueResponse: Codable, Hashable, Sendable {
    let isNull: Bool
    let kind: String
    let text: String
    let encoding: String
    let byteCount: Int64
    let truncated: Bool
    let error: DBError?

    var isHex: Bool { encoding == "hex" }
}

struct DBIntrospectRequest: Codable, Hashable, Sendable {
    let dataSourceId: String
    let refresh: Bool
}

struct DBSchemaSummary: Codable, Hashable, Sendable {
    let name: String
    let tables: Int
    let views: Int
    let introspectedAt: String
}

struct DBIntrospectResult: Codable, Hashable, Sendable {
    @DBList var schemas: [DBSchemaSummary] = []
    let defaultSchema: String
    let error: DBError?
}

struct DBSchemaChildrenRequest: Codable, Hashable, Sendable {
    let dataSourceId: String
    let path: [String]
}

struct DBNode: Codable, Hashable, Sendable {
    let kind: String
    let name: String
    let detail: String
    let hasChildren: Bool
}

struct DBSchemaChildrenResult: Codable, Hashable, Sendable {
    @DBList var nodes: [DBNode] = []
    let error: DBError?
}

struct DBCompleteRequest: Codable, Hashable, Sendable {
    let dataSourceId: String
    let dialect: String
    let text: String
    let caretByte: Int
}

struct DBCompletionItem: Codable, Hashable, Sendable {
    let label: String
    let kind: String
    let detail: String
    let insert: String
}

struct DBCompleteResult: Codable, Hashable, Sendable {
    let replaceStartByte: Int
    @DBList var items: [DBCompletionItem] = []
    let hint: String
}

struct DBParamValue: Codable, Hashable, Sendable {
    let name: String
    let value: String
    let isNull: Bool
    var secret: Bool? = nil

    var isSecret: Bool { secret == true }
}

struct DBParameter: Codable, Hashable, Sendable {
    let name: String
    @DBList var positions: [DBByteRange] = []
    let typeHint: String
    var nullable: Bool? = nil
}

struct DBParametersRequest: Codable, Hashable, Sendable {
    let dialect: String
    let endByte: Int
    let startByte: Int
    let text: String
}

struct DBParametersResult: Codable, Hashable, Sendable {
    @DBList var parameters: [DBParameter] = []
}

struct DBReadOnlyColumn: Codable, Hashable, Sendable {
    let column: Int
    let reason: String
}

struct DBOpenTableRequest: Codable, Hashable, Sendable {
    let execId: String
    let consoleId: String
    let dataSourceId: String
    var workspaceRoot: String? = nil
    let schema: String
    let table: String
    let `where`: String
    let orderBy: String
    let pageSize: Int
    var confirmed: [DBConfirmation]? = nil
}

struct DBOpenTableResponse: Codable, Hashable, Sendable {
    let execId: String
    @DBList var blocked: [DBBlocked] = []
    @DBList var statements: [DBStatementResult] = []
    let session: DBSessionState?
    let error: DBError?
    var sql: String = ""
    var editable: Bool = false
    @DBList var keyColumns: [String] = []
    var reason: String = ""
    @DBList var readOnlyColumns: [DBReadOnlyColumn] = []
    var foreignKeyColumns: [Int] = []
    var referencingTables: [DBReferencingTable] = []

    private enum CodingKeys: String, CodingKey {
        case execId, blocked, statements, session, error, sql, editable, keyColumns, reason, readOnlyColumns, foreignKeyColumns, referencingTables
    }

    init(execId: String, session: DBSessionState?, error: DBError?) {
        self.execId = execId
        self.session = session
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        execId = try c.decodeIfPresent(String.self, forKey: .execId) ?? ""
        _blocked = try c.decode(DBList<DBBlocked>.self, forKey: .blocked)
        _statements = try c.decode(DBList<DBStatementResult>.self, forKey: .statements)
        session = try c.decodeIfPresent(DBSessionState.self, forKey: .session)
        error = try c.decodeIfPresent(DBError.self, forKey: .error)
        sql = try c.decodeIfPresent(String.self, forKey: .sql) ?? ""
        editable = try c.decodeIfPresent(Bool.self, forKey: .editable) ?? false
        _keyColumns = try c.decode(DBList<String>.self, forKey: .keyColumns)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        _readOnlyColumns = try c.decode(DBList<DBReadOnlyColumn>.self, forKey: .readOnlyColumns)
        foreignKeyColumns = try c.decodeIfPresent([Int].self, forKey: .foreignKeyColumns) ?? []
        referencingTables = try c.decodeIfPresent([DBReferencingTable].self, forKey: .referencingTables) ?? []
    }

    var executeResponse: DBExecuteResponse {
        DBExecuteResponse(execId: execId, blocked: blocked, statements: statements, session: session, error: error)
    }
}

struct DBCountRowsRequest: Codable, Hashable, Sendable {
    let execId: String
    let dataSourceId: String
    let schema: String
    let table: String
    let `where`: String
}

struct DBCountRowsResult: Codable, Hashable, Sendable {
    let count: Int64?
    let error: DBError?
}

struct DBCellEdit: Codable, Hashable, Sendable {
    let row: Int64
    let column: Int
    let value: String
    let isNull: Bool
}

struct DBInsertCell: Codable, Hashable, Sendable {
    let column: Int
    let value: String
    let isNull: Bool
}

struct DBRowInsert: Codable, Hashable, Sendable {
    @DBList var cells: [DBInsertCell] = []
}

struct DBEditRequest: Codable, Hashable, Sendable {
    var execId: String? = nil
    let resultId: String
    @DBList var edits: [DBCellEdit] = []
    @DBList var inserts: [DBRowInsert] = []
    @DBList var deletes: [Int64] = []
    var confirmed: [DBConfirmation]? = nil
}

struct DBPlannedStatement: Codable, Hashable, Sendable {
    let kind: String
    var row: Int64? = nil
    var insert: Int? = nil
    let sql: String
    @DBList var params: [String?] = []
}

struct DBEditIssue: Codable, Hashable, Sendable {
    var row: Int64? = nil
    var insert: Int? = nil
    var column: Int? = nil
    let message: String
}

struct DBPlanEditsResult: Codable, Hashable, Sendable {
    @DBList var statements: [DBPlannedStatement] = []
    @DBList var issues: [DBEditIssue] = []
    @DBList var blocked: [DBBlocked] = []
    let error: DBError?
}

struct DBApplyEditsResult: Codable, Hashable, Sendable {
    let applied: Bool
    let committed: Bool
    let rowsAffected: Int64
    let failedStatement: Int?
    @DBList var blocked: [DBBlocked] = []
    let error: DBError?
    let session: DBSessionState?
}

enum DBTransactionAction: String, Sendable {
    case status
    case commit
    case rollback
    case setMode
    case setIsolation
}

struct DBTransactionRequest: Codable, Hashable, Sendable {
    let consoleId: String
    var dataSourceId: String? = nil
    let action: String
    var mode: String? = nil
    var isolation: String? = nil
}

struct DBTransactionResult: Codable, Hashable, Sendable {
    let session: DBSessionState?
    @DBList var isolationLevels: [String] = []
    let error: DBError?
}

struct DBExplainRequest: Codable, Hashable, Sendable {
    var request: DBExecuteRequest
    let analyze: Bool

    private enum CodingKeys: String, CodingKey {
        case analyze
    }

    init(request: DBExecuteRequest, analyze: Bool) {
        self.request = request
        self.analyze = analyze
    }

    init(from decoder: Decoder) throws {
        request = try DBExecuteRequest(from: decoder)
        analyze = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .analyze) ?? false
    }

    func encode(to encoder: Encoder) throws {
        try request.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(analyze, forKey: .analyze)
    }
}

struct DBPlanNode: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let parent: Int?
    let label: String
    let relation: String
    let estRows: Double?
    let actRows: Double?
    let loops: Double?
    let cost: Double?
    let timeMs: Double?
    let detail: String
}

struct DBPlan: Codable, Hashable, Sendable {
    let format: String
    @DBList var nodes: [DBPlanNode] = []
    let mostExpensive: Int?
    let planningMs: Double?
    let executionMs: Double?
    let actualRows: Int64?
    let raw: String
}

struct DBExplainResult: Codable, Hashable, Sendable {
    let plan: DBPlan?
    let analyzed: Bool
    let rolledBack: Bool
    @DBList var blocked: [DBBlocked] = []
    let session: DBSessionState?
    let error: DBError?
}

enum DBExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case json
    case sql
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .sql: "SQL INSERT"
        case .markdown: "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .json: "json"
        case .sql: "sql"
        case .markdown: "md"
        }
    }

    var hasHeaderOption: Bool { self == .csv || self == .tsv }
}

enum DBExportScope: String, CaseIterable, Identifiable, Sendable {
    case selection
    case loaded
    case all

    var id: String { rawValue }
}

struct DBExportOptions: Codable, Hashable, Sendable {
    var includeHeader: Bool? = nil
    var tableName: String? = nil
    var nullText: String? = nil
    var columns: [Int]? = nil
}

struct DBExportRequest: Codable, Hashable, Sendable {
    let execId: String
    let resultId: String
    let format: String
    let scope: String
    var rows: [Int64]? = nil
    var path: String? = nil
    var clipboard: Bool? = nil
    var options = DBExportOptions()
}

struct DBExportResult: Codable, Hashable, Sendable {
    let rowsWritten: Int64
    let bytes: Int64
    var text: String? = nil
    var cursorClosed: Bool? = nil
    let error: DBError?
}

struct DBHistoryRequest: Codable, Hashable, Sendable {
    let dataSourceId: String
    var query: String = ""
    var limit: Int = 0
    var delete: String? = nil
    var clear: Bool? = nil
}

struct DBHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let text: String
    let time: String
    let durationMs: Double
    let rowCount: Int64?
    var error: String? = nil
    let source: String
    var textTruncated: Bool? = nil
    var parameters: [DBParamValue]? = nil
}

struct DBHistoryResult: Codable, Hashable, Sendable {
    @DBList var entries: [DBHistoryEntry] = []
    let error: DBError?
}

struct DBDetectSource: Codable, Hashable, Sendable {
    let file: String
    let line: Int
    let key: String
}

struct DBDetectCandidate: Codable, Hashable, Sendable {
    var definition: DBDataSourceDefinition
    let source: DBDetectSource
    let kind: String
    let hasSecret: Bool
    var secret: String? = nil
    var note: String? = nil
}

struct DBDetectResult: Codable, Hashable, Sendable {
    @DBList var candidates: [DBDetectCandidate] = []
}

struct DBReferencingTable: Codable, Hashable, Sendable {
    let schema: String
    let table: String
    @DBList var columns: [String] = []
    let constraint: String
}

enum DBRelatedDirection: String, Codable, Sendable {
    case referenced
    case referencing
}

struct DBRelatedRowsRequest: Codable, Hashable, Sendable {
    let resultId: String
    let row: Int64
    let column: Int
    let direction: DBRelatedDirection
}

struct DBRelatedTarget: Codable, Hashable, Sendable {
    let schema: String
    let table: String
    let `where`: String
    @DBList var columns: [String] = []
    let constraint: String
}

struct DBRelatedRowsResult: Codable, Hashable, Sendable {
    @DBList var targets: [DBRelatedTarget] = []
    var error: DBError? = nil
}

struct DBGoSQLPart: Codable, Hashable, Sendable {
    let startByte: Int
    let endByte: Int
}

struct DBGoSQLSite: Codable, Hashable, Sendable {
    let line: Int
    let startByte: Int
    let endByte: Int
    let sql: String
    let dialectHint: String
    let api: String
    @DBList var parts: [DBGoSQLPart] = []
    @DBList var params: [String] = []
}

struct DBGoSQLSitesResult: Codable, Hashable, Sendable {
    @DBList var sites: [DBGoSQLSite] = []
}

struct DBSqlcQueryResult: Codable, Hashable, Sendable {
    var name: String = ""
    var cmd: String = ""
    var line: Int = 0
    var sql: String = ""
    var startByte: Int = 0
    var endByte: Int = 0
    @DBList var parameters: [DBParameter] = []
    var engine: String = ""
    var configDir: String = ""
    var error: DBError? = nil
}

enum DBFixtureCatalog {
    static let decoders: [String: (Data) throws -> Any] = [
        "cell-value-response": { try JSONDecoder().decode(DBCellValueResponse.self, from: $0) },
        "close-console-response": { try JSONDecoder().decode(DBDisconnectResult.self, from: $0) },
        "complete-request": { try JSONDecoder().decode(DBCompleteRequest.self, from: $0) },
        "complete-response": { try JSONDecoder().decode(DBCompleteResult.self, from: $0) },
        "configure-request": { try JSONDecoder().decode(DBDataSourcesFile.self, from: $0) },
        "configure-response": { try JSONDecoder().decode(DBConfigureResult.self, from: $0) },
        "disconnect-response": { try JSONDecoder().decode(DBDisconnectResult.self, from: $0) },
        "errors": { try JSONDecoder().decode([DBError].self, from: $0) },
        "event": { try JSONDecoder().decode(DBEvent.self, from: $0) },
        "execute-request": { try JSONDecoder().decode(DBExecuteRequest.self, from: $0) },
        "execute-response": { try JSONDecoder().decode(DBExecuteResponse.self, from: $0) },
        "fetch-all-response": { try JSONDecoder().decode(DBFetchAllResult.self, from: $0) },
        "introspect-request": { try JSONDecoder().decode(DBIntrospectRequest.self, from: $0) },
        "introspect-response": { try JSONDecoder().decode(DBIntrospectResult.self, from: $0) },
        "schema-children-request": { try JSONDecoder().decode(DBSchemaChildrenRequest.self, from: $0) },
        "schema-children-response": { try JSONDecoder().decode(DBSchemaChildrenResult.self, from: $0) },
        "set-secret-response": { try JSONDecoder().decode(DBOKResult.self, from: $0) },
        "sort-request": { try JSONDecoder().decode([DBSortKey].self, from: $0) },
        "sort-response": { try JSONDecoder().decode(DBSortResponse.self, from: $0) },
        "statements-request": { try JSONDecoder().decode(DBStatementsRequest.self, from: $0) },
        "statements-response": { try JSONDecoder().decode([DBStatementInfo].self, from: $0) },
        "stats-response": { try JSONDecoder().decode(DBStatsResponse.self, from: $0) },
        "test-connection-request": { try JSONDecoder().decode(DBTestConnectionRequest.self, from: $0) },
        "test-connection-response": { try JSONDecoder().decode(DBTestConnectionResult.self, from: $0) },
        "apply-edits-request": { try JSONDecoder().decode(DBEditRequest.self, from: $0) },
        "apply-edits-response": { try JSONDecoder().decode(DBApplyEditsResult.self, from: $0) },
        "plan-edits-request": { try JSONDecoder().decode(DBEditRequest.self, from: $0) },
        "plan-edits-response": { try JSONDecoder().decode(DBPlanEditsResult.self, from: $0) },
        "count-rows-request": { try JSONDecoder().decode(DBCountRowsRequest.self, from: $0) },
        "count-rows-response": { try JSONDecoder().decode(DBCountRowsResult.self, from: $0) },
        "detect-response": { try JSONDecoder().decode(DBDetectResult.self, from: $0) },
        "explain-request": { try JSONDecoder().decode(DBExplainRequest.self, from: $0) },
        "explain-response": { try JSONDecoder().decode(DBExplainResult.self, from: $0) },
        "export-request": { try JSONDecoder().decode(DBExportRequest.self, from: $0) },
        "export-response": { try JSONDecoder().decode(DBExportResult.self, from: $0) },
        "history-request": { try JSONDecoder().decode(DBHistoryRequest.self, from: $0) },
        "history-response": { try JSONDecoder().decode(DBHistoryResult.self, from: $0) },
        "open-table-request": { try JSONDecoder().decode(DBOpenTableRequest.self, from: $0) },
        "open-table-response": { try JSONDecoder().decode(DBOpenTableResponse.self, from: $0) },
        "parameters-request": { try JSONDecoder().decode(DBParametersRequest.self, from: $0) },
        "parameters-response": { try JSONDecoder().decode(DBParametersResult.self, from: $0) },
        "transaction-request": { try JSONDecoder().decode(DBTransactionRequest.self, from: $0) },
        "transaction-response": { try JSONDecoder().decode(DBTransactionResult.self, from: $0) },
        "go-sql-sites-response": { try JSONDecoder().decode(DBGoSQLSitesResult.self, from: $0) },
        "sqlc-query-response": { try JSONDecoder().decode(DBSqlcQueryResult.self, from: $0) },
        "related-rows-request": { try JSONDecoder().decode(DBRelatedRowsRequest.self, from: $0) },
        "related-rows-response": { try JSONDecoder().decode(DBRelatedRowsResult.self, from: $0) }
    ]

    static func decoder(forFixture name: String) -> ((Data) throws -> Any)? {
        let base = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        let match = decoders.keys
            .filter { base == $0 || base.hasPrefix($0 + "-") }
            .max { $0.count < $1.count }
        return match.flatMap { decoders[$0] }
    }
}
