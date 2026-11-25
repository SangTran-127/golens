import Foundation
import GopilotRuntime
@testable import GopilotPolicy

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class CountingReader: FileReading, @unchecked Sendable {
    let counter = CallCounter()
    private let inner = LocalFileReader()

    func readData(at url: URL, maxBytes: Int) throws -> Data {
        counter.increment()
        return try inner.readData(at: url, maxBytes: maxBytes)
    }

    var reads: Int { counter.count }
}

struct TempTree {
    let base: URL
    let workspace: URL
    let outside: URL
    let dependency: URL

    static func make() throws -> TempTree {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gopilot-\(UUID().uuidString)")
        let tree = TempTree(base: base, workspace: base.appendingPathComponent("ws"), outside: base.appendingPathComponent("outside"), dependency: base.appendingPathComponent("modcache"))
        for dir in ["ws/pkg", "ws/.git", "ws/node_modules", "outside", "modcache/example.com/x@v1"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try write("package main\nfunc main() {}\n", to: "ws/main.go", in: base)
        try write("package pkg\n", to: "ws/pkg/a.go", in: base)
        try write("API_TOKEN=abc123abc123\n", to: "ws/.env", in: base)
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n", to: "ws/id_rsa", in: base)
        try write("[core]\n", to: "ws/.git/config", in: base)
        try write("module.exports = 1\n", to: "ws/node_modules/x.js", in: base)
        try write("private notes\n", to: "ws/notes.private", in: base)
        try write("png", to: "ws/logo.png", in: base)
        try Data([0x41, 0x00, 0x42, 0x00]).write(to: base.appendingPathComponent("ws/data.txt"))
        try write("outside secret\n", to: "outside/secret.txt", in: base)
        try write("package x\n", to: "modcache/example.com/x@v1/x.go", in: base)
        try fm.createSymbolicLink(at: base.appendingPathComponent("ws/link-out"), withDestinationURL: base.appendingPathComponent("outside"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("ws/link-file"), withDestinationURL: base.appendingPathComponent("outside/secret.txt"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("ws/link-in"), withDestinationURL: base.appendingPathComponent("ws/pkg"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("ws/env-link"), withDestinationURL: base.appendingPathComponent("ws/.env"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("modcache/example.com/escape"), withDestinationURL: base.appendingPathComponent("ws"))
        return tree
    }

    private static func write(_ text: String, to path: String, in base: URL) throws {
        try text.write(to: base.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func policy(patterns: [String] = ["*.private"], approvedDependencies: [DependencyRoot] = []) -> PathPolicy {
        PathPolicy(workspaceRoots: [workspace], approvedDependencyRoots: approvedDependencies, userExcludePatterns: patterns)
    }
}

actor SnapshotBox {
    private var snapshot: SourceSnapshot

    init(_ snapshot: SourceSnapshot) {
        self.snapshot = snapshot
    }

    func get() -> SourceSnapshot { snapshot }
    func set(_ next: SourceSnapshot) { snapshot = next }
}

struct StubSource: SourceProviding {
    let outcome: BackendOutcome<SourceDocument>
    let counter: CallCounter
    var onCall: (@Sendable () async -> Void)?

    init(_ outcome: BackendOutcome<SourceDocument>, counter: CallCounter = CallCounter(), onCall: (@Sendable () async -> Void)? = nil) {
        self.outcome = outcome
        self.counter = counter
        self.onCall = onCall
    }

    func source(for path: ResolvedPath) async -> BackendOutcome<SourceDocument> {
        counter.increment()
        await onCall?()
        return outcome
    }
}

struct StubSearch: CodeSearchBackend {
    let outcome: BackendOutcome<BackendPage<SearchHit>>

    func search(query: String, scope: SearchScope, regex: Bool, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SearchHit>> {
        outcome
    }
}

struct StubListing: FileListingBackend {
    let outcome: BackendOutcome<BackendPage<String>>

    func listFiles(directory: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<String>> {
        outcome
    }
}

struct StubProject: ProjectInfoBackend {
    let outcome: BackendOutcome<ProjectSummaryInfo>

    func projectSummary(includeReadme: Bool) async -> BackendOutcome<ProjectSummaryInfo> {
        outcome
    }
}

struct StubSymbols: SymbolBackend {
    var documentSymbolsOutcome: BackendOutcome<BackendPage<SymbolInfo>> = .empty
    var findSymbolsOutcome: BackendOutcome<BackendPage<SymbolInfo>> = .empty
    var resolveOutcome: BackendOutcome<ResolvedLocations> = .empty
    var referencesOutcome: BackendOutcome<BackendPage<CodeLocation>> = .empty
    var callsOutcome: BackendOutcome<BackendPage<CallEdge>> = .empty

    func documentSymbols(in path: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>> { documentSymbolsOutcome }
    func findSymbols(query: String, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>> { findSymbolsOutcome }
    func resolveSymbol(at position: SymbolPosition, relation: SymbolRelation) async -> BackendOutcome<ResolvedLocations> { resolveOutcome }
    func findReferences(at position: SymbolPosition, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<CodeLocation>> { referencesOutcome }
    func callHierarchy(at position: SymbolPosition, direction: CallDirection, limit: Int) async -> BackendOutcome<BackendPage<CallEdge>> { callsOutcome }
}

struct StubDocumentation: DocumentationBackend {
    let outcome: BackendOutcome<DocumentationInfo>

    func documentation(for query: DocumentationQuery) async -> BackendOutcome<DocumentationInfo> { outcome }
}

struct StubDiagnostics: DiagnosticsBackend {
    let outcome: BackendOutcome<BackendPage<DiagnosticInfo>>

    func diagnostics(in path: ResolvedPath?, limit: Int) async -> BackendOutcome<BackendPage<DiagnosticInfo>> { outcome }
}

func makeSnapshot(_ id: String = "S1", workspace: UUID, versions: [String: Int] = [:], hashes: [String: String] = [:]) -> SourceSnapshot {
    SourceSnapshot(id: id, workspaceID: workspace, gitHead: "abc123", dirtyFileHashes: hashes, documentVersions: versions, buildTarget: "linux/amd64", goVersion: "1.27.1")
}

func decodeData(_ envelope: ToolResultEnvelope) -> [String: Any] {
    guard let data = envelope.data.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

func hasIntactToolPairs(_ messages: [ModelMessage]) -> Bool {
    var pending: Set<String> = []
    var seen: Set<String> = []
    for message in messages {
        switch message.role {
        case .assistant:
            if !pending.isEmpty { return false }
            pending = Set(message.toolCalls.map(\.id))
            seen.formUnion(pending)
        case .tool:
            guard let id = message.toolCallID, pending.remove(id) != nil else { return false }
        default:
            if !pending.isEmpty { return false }
        }
    }
    return pending.isEmpty
}
