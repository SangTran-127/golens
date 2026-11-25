import Foundation
import GopilotRuntime
@testable import GopilotStore

final class Sandbox: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gopilot-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func workspaceRoot(_ id: UUID) -> URL {
        url.appendingPathComponent("workspaces").appendingPathComponent(id.uuidString)
    }

    func allFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.withLock {
            current = current.addingTimeInterval(0.001)
            return current
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var asClosure: @Sendable () -> Date {
        { [self] in now() }
    }
}

final class FaultFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var appendFailure: Error?
    private var atomicFailure: Error?
    private var atomicFailureFilter: String?
    private var partialAppend = false
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func failAppends(with error: Error? = CocoaError(.fileWriteOutOfSpace)) {
        lock.withLock { appendFailure = error }
    }

    func failAtomicWrites(containing filter: String? = nil, with error: Error? = CocoaError(.fileWriteOutOfSpace)) {
        lock.withLock {
            atomicFailure = error
            atomicFailureFilter = filter
        }
    }

    func tearAppends(_ enabled: Bool) {
        lock.withLock { partialAppend = enabled }
    }

    func read(_ url: URL) throws -> Data { try base.read(url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let failure: Error? = lock.withLock {
            if let error = atomicFailure, atomicFailureFilter == nil || url.lastPathComponent.contains(atomicFailureFilter!) { return error }
            writes += 1
            return nil
        }
        if let failure { throw failure }
        try base.writeAtomically(data, to: url)
    }

    func append(_ data: Data, to url: URL) throws {
        let (failure, tear): (Error?, Bool) = lock.withLock {
            if let error = appendFailure { return (error, false) }
            if partialAppend { return (nil, true) }
            writes += 1
            return (nil, false)
        }
        if let failure { throw failure }
        if tear {
            try base.append(data.prefix(data.count / 2), to: url)
            lock.withLock { partialAppend = false }
            throw POSIXError(.EIO)
        }
        try base.append(data, to: url)
    }

    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func remove(_ url: URL) throws {
        lock.withLock { writes += 1 }
        try base.remove(url)
    }
    func copy(from source: URL, to destination: URL) throws {
        lock.withLock { writes += 1 }
        try base.copy(from: source, to: destination)
    }
    func contents(of directory: URL) throws -> [URL] { try base.contents(of: directory) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func size(of url: URL) -> Int? { base.size(of: url) }
}

struct EchoTool: GopilotTool {
    let schema = ToolSchema(name: "echo", description: "Returns text.", parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"additionalProperties":false}"#)

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        ToolResultEnvelope(callID: callID, status: .ok, data: "echoed", evidenceIDs: ["E1"])
    }
}

func makeStore(_ sandbox: Sandbox, workspace: UUID = UUID(), fileSystem: FileSystem = LocalFileSystem(), limits: StoreLimits = StoreLimits(), migrations: [SchemaMigration] = [], clock: TestClock = TestClock()) throws -> WorkspaceStore {
    try WorkspaceStore(baseURL: sandbox.url, workspaceID: workspace, fileSystem: fileSystem, limits: limits, migrations: migrations, now: clock.asClosure)
}

func event(_ turn: UUID, _ sequence: Int, _ kind: AgentEventKind, _ payload: [String: String] = [:], at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AgentEvent {
    AgentEvent(sessionID: UUID(), turnID: turn, sequence: sequence, timestamp: at.addingTimeInterval(Double(sequence)), kind: kind, payload: payload)
}

func stream(_ events: [AgentEvent]) -> AsyncStream<AgentEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
    for event in events { continuation.yield(event) }
    continuation.finish()
    return stream
}

func completedTurnEvents(_ turn: UUID, tool: Bool = false) -> [AgentEvent] {
    var events = [event(turn, 1, .turnStarted), event(turn, 2, .activity, ["label": "Requesting model"])]
    var next = 3
    if tool {
        events.append(event(turn, next, .toolRequested, ["callID": "call_1", "name": "echo"]))
        events.append(event(turn, next + 1, .toolStarted, ["callID": "call_1", "name": "echo"]))
        events.append(event(turn, next + 2, .toolFinished, ["callID": "call_1", "status": "ok", "errorCode": ""]))
        next += 3
    }
    events.append(event(turn, next, .usageUpdated, ["inputTokens": "10", "outputTokens": "4"]))
    events.append(event(turn, next + 1, .turnCompleted))
    return events
}

func journalURL(_ sandbox: Sandbox, workspace: UUID, conversation: UUID) -> URL {
    sandbox.workspaceRoot(workspace).appendingPathComponent("conversations").appendingPathComponent("\(conversation.uuidString).jsonl")
}

func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}
