import Foundation

public enum BackendOutcome<Value: Sendable>: Sendable {
    case found(Value)
    case empty
    case unavailable(String)
    case timeout
}

extension BackendOutcome: Equatable where Value: Equatable {}

public struct BackendPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public let isTruncated: Bool

    public init(items: [Item], nextCursor: String? = nil, isTruncated: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.isTruncated = isTruncated
    }
}

extension BackendPage: Equatable where Item: Equatable {}

public struct EntryCandidate: Sendable, Equatable {
    public let path: String
    public let kind: String
    public let note: String

    public init(path: String, kind: String, note: String = "") {
        self.path = path
        self.kind = kind
        self.note = note
    }
}

public struct ProjectSummaryInfo: Sendable, Equatable {
    public let moduleName: String?
    public let goVersion: String?
    public let buildTarget: String?
    public let entries: [EntryCandidate]
    public let readmeExcerpt: String?

    public init(moduleName: String? = nil, goVersion: String? = nil, buildTarget: String? = nil, entries: [EntryCandidate] = [], readmeExcerpt: String? = nil) {
        self.moduleName = moduleName
        self.goVersion = goVersion
        self.buildTarget = buildTarget
        self.entries = entries
        self.readmeExcerpt = readmeExcerpt
    }
}

public enum SearchScope: String, Sendable, Equatable {
    case workspace
    case goFiles = "go_files"
    case testFiles = "test_files"
}

public struct SearchHit: Sendable, Equatable {
    public let path: String
    public let dependencyRootID: String?
    public let line: Int
    public let text: String

    public init(path: String, dependencyRootID: String? = nil, line: Int, text: String) {
        self.path = path
        self.dependencyRootID = dependencyRootID
        self.line = line
        self.text = text
    }
}

public struct SourceDocument: Sendable, Equatable {
    public let text: String
    public let documentVersion: Int?
    public let fromBuffer: Bool

    public init(text: String, documentVersion: Int? = nil, fromBuffer: Bool = false) {
        self.text = text
        self.documentVersion = documentVersion
        self.fromBuffer = fromBuffer
    }
}

public struct SymbolPosition: Sendable, Equatable {
    public let path: ResolvedPath
    public let line: Int
    public let character: Int

    public init(path: ResolvedPath, line: Int, character: Int) {
        self.path = path
        self.line = line
        self.character = character
    }
}

public struct CodeLocation: Sendable, Equatable {
    public let path: String
    public let dependencyRootID: String?
    public let range: SourceRange
    public let documentVersion: Int?
    public let preview: String?
    public let isDynamic: Bool

    public init(path: String, dependencyRootID: String? = nil, range: SourceRange, documentVersion: Int? = nil, preview: String? = nil, isDynamic: Bool = false) {
        self.path = path
        self.dependencyRootID = dependencyRootID
        self.range = range
        self.documentVersion = documentVersion
        self.preview = preview
        self.isDynamic = isDynamic
    }
}

public struct SymbolInfo: Sendable, Equatable {
    public let name: String
    public let kind: String
    public let container: String?
    public let location: CodeLocation

    public init(name: String, kind: String, container: String? = nil, location: CodeLocation) {
        self.name = name
        self.kind = kind
        self.container = container
        self.location = location
    }
}

public enum SymbolRelation: String, Sendable, Equatable {
    case definition
    case type
    case implementation
}

public struct ResolvedLocations: Sendable, Equatable {
    public let locations: [CodeLocation]
    public let isComplete: Bool

    public init(locations: [CodeLocation], isComplete: Bool = true) {
        self.locations = locations
        self.isComplete = isComplete
    }
}

public enum CallDirection: String, Sendable, Equatable {
    case incoming
    case outgoing
}

public struct CallEdge: Sendable, Equatable {
    public let symbol: SymbolInfo
    public let callSites: [CodeLocation]
    public let isDynamic: Bool

    public init(symbol: SymbolInfo, callSites: [CodeLocation] = [], isDynamic: Bool = false) {
        self.symbol = symbol
        self.callSites = callSites
        self.isDynamic = isDynamic
    }
}

public enum DocumentationQuery: Sendable, Equatable {
    case position(SymbolPosition)
    case packageSymbol(package: String, symbol: String?)
}

public struct DocumentationInfo: Sendable, Equatable {
    public let signature: String
    public let documentation: String
    public let moduleVersion: String?
    public let provenance: String
    public let location: CodeLocation?

    public init(signature: String, documentation: String, moduleVersion: String? = nil, provenance: String, location: CodeLocation? = nil) {
        self.signature = signature
        self.documentation = documentation
        self.moduleVersion = moduleVersion
        self.provenance = provenance
        self.location = location
    }
}

public struct DiagnosticInfo: Sendable, Equatable {
    public let path: String
    public let dependencyRootID: String?
    public let line: Int
    public let column: Int
    public let severity: String
    public let message: String
    public let source: String?
    public let documentVersion: Int?

    public init(path: String, dependencyRootID: String? = nil, line: Int, column: Int, severity: String, message: String, source: String? = nil, documentVersion: Int? = nil) {
        self.path = path
        self.dependencyRootID = dependencyRootID
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.source = source
        self.documentVersion = documentVersion
    }
}

public protocol ProjectInfoBackend: Sendable {
    func projectSummary(includeReadme: Bool) async -> BackendOutcome<ProjectSummaryInfo>
}

public protocol FileListingBackend: Sendable {
    func listFiles(directory: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<String>>
}

public protocol CodeSearchBackend: Sendable {
    func search(query: String, scope: SearchScope, regex: Bool, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SearchHit>>
}

public protocol SourceProviding: Sendable {
    func source(for path: ResolvedPath) async -> BackendOutcome<SourceDocument>
}

public protocol SymbolBackend: Sendable {
    func documentSymbols(in path: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>>
    func findSymbols(query: String, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>>
    func resolveSymbol(at position: SymbolPosition, relation: SymbolRelation) async -> BackendOutcome<ResolvedLocations>
    func findReferences(at position: SymbolPosition, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<CodeLocation>>
    func callHierarchy(at position: SymbolPosition, direction: CallDirection, limit: Int) async -> BackendOutcome<BackendPage<CallEdge>>
}

public protocol DocumentationBackend: Sendable {
    func documentation(for query: DocumentationQuery) async -> BackendOutcome<DocumentationInfo>
}

public protocol DiagnosticsBackend: Sendable {
    func diagnostics(in path: ResolvedPath?, limit: Int) async -> BackendOutcome<BackendPage<DiagnosticInfo>>
}

public struct ReadBackends: Sendable {
    public var project: ProjectInfoBackend?
    public var listing: FileListingBackend?
    public var search: CodeSearchBackend?
    public var source: SourceProviding?
    public var symbols: SymbolBackend?
    public var documentation: DocumentationBackend?
    public var diagnostics: DiagnosticsBackend?

    public init(project: ProjectInfoBackend? = nil, listing: FileListingBackend? = nil, search: CodeSearchBackend? = nil, source: SourceProviding? = nil, symbols: SymbolBackend? = nil, documentation: DocumentationBackend? = nil, diagnostics: DiagnosticsBackend? = nil) {
        self.project = project
        self.listing = listing
        self.search = search
        self.source = source
        self.symbols = symbols
        self.documentation = documentation
        self.diagnostics = diagnostics
    }
}

public protocol FileReading: Sendable {
    func readData(at url: URL, maxBytes: Int) throws -> Data
}

public struct LocalFileReader: FileReading {
    public init() {}

    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}

public struct DiskSourceProvider: SourceProviding {
    public static let defaultMaxBytes = 4 * 1024 * 1024

    private let reader: FileReading
    private let maxBytes: Int

    public init(reader: FileReading = LocalFileReader(), maxBytes: Int = DiskSourceProvider.defaultMaxBytes) {
        self.reader = reader
        self.maxBytes = maxBytes
    }

    public func source(for path: ResolvedPath) async -> BackendOutcome<SourceDocument> {
        let data: Data
        do {
            data = try reader.readData(at: path.url, maxBytes: maxBytes + 1)
        } catch {
            return .unavailable("The file could not be read.")
        }
        if data.count > maxBytes { return .unavailable("The file is larger than \(maxBytes) bytes.") }
        if PathPolicy.looksBinary(data) { return .unavailable("The file looks binary.") }
        guard let text = String(data: data, encoding: .utf8) else { return .unavailable("The file is not valid UTF-8.") }
        return .found(SourceDocument(text: text, documentVersion: nil, fromBuffer: false))
    }
}
