import Foundation
import GopilotRuntime

struct ConversationHeader: Sendable, Equatable, Codable {
    var workspaceID: UUID
    var providerID: String
    var modelID: String
    var title: String
    var createdAt: Date
}

struct JournalRecord: Sendable, Equatable, Codable {
    static let currentSchemaVersion = 1

    enum Kind: String, Sendable, Codable {
        case conversationCreated
        case titleChanged
        case turnStarted
        case modelRequested
        case toolRequested
        case toolStarted
        case toolFinished
        case usage
        case messages
        case turnTerminal
    }

    var schemaVersion: Int
    var seq: Int
    var at: Date
    var kind: Kind
    var turnID: UUID?
    var text: String?
    var callID: String?
    var name: String?
    var argsHash: String?
    var status: String?
    var errorCode: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var displayLabel: String?
    var routeSelection: TurnRouteSelection?
    var projectContextEnabled: Bool?
    var attachedPaths: [String]?
    var accessedPaths: [String]?
    var messages: [ModelMessage]?
    var terminal: TurnTerminalState?
    var header: ConversationHeader?

    init(seq: Int, at: Date, kind: Kind, turnID: UUID? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.seq = seq
        self.at = at
        self.kind = kind
        self.turnID = turnID
    }

    func encodedLine() throws -> Data {
        var data = try Coding.encoder().encode(self)
        data.append(0x0A)
        return data
    }
}

struct JournalReadResult {
    var records: [JournalRecord]
    var skippedLines: Int
}

enum JournalReader {
    static func read(_ data: Data) -> JournalReadResult {
        var records: [JournalRecord] = []
        var skipped = 0
        var lastSeq = 0
        let decoder = Coding.decoder()
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(slice)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            guard let record = try? decoder.decode(JournalRecord.self, from: line),
                  record.schemaVersion <= JournalRecord.currentSchemaVersion else {
                skipped += 1
                continue
            }
            if record.seq <= lastSeq { continue }
            lastSeq = record.seq
            records.append(record)
        }
        return JournalReadResult(records: records, skippedLines: skipped)
    }
}

struct ConversationBuilder {
    let id: UUID
    private(set) var header: ConversationHeader?
    private(set) var turns: [Turn] = []
    private(set) var updatedAt: Date
    private(set) var lastSeq = 0

    init(id: UUID, fallback: ConversationHeader?, updatedAt: Date) {
        self.id = id
        self.header = fallback
        self.updatedAt = updatedAt
    }

    mutating func apply(_ record: JournalRecord) {
        lastSeq = max(lastSeq, record.seq)
        updatedAt = max(updatedAt, record.at)
        switch record.kind {
        case .conversationCreated:
            if let header = record.header { self.header = header }
        case .titleChanged:
            if let title = record.text { header?.title = title }
        case .turnStarted:
            guard let turnID = record.turnID, !turns.contains(where: { $0.id == turnID }) else { return }
            turns.append(
                Turn(
                    id: turnID,
                    userPrompt: record.text ?? "",
                    displayLabel: record.displayLabel,
                    routeSelection: record.routeSelection,
                    projectContextEnabled: record.projectContextEnabled,
                    attachedPaths: record.attachedPaths,
                    accessedPaths: record.accessedPaths,
                    startedAt: record.at
                )
            )
        default:
            guard let turnID = record.turnID, let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
            applyTurnRecord(record, at: index)
        }
    }

    private mutating func applyTurnRecord(_ record: JournalRecord, at index: Int) {
        switch record.kind {
        case .modelRequested:
            turns[index].usage.modelRequests += 1
        case .toolRequested:
            guard let callID = record.callID, !turns[index].toolLifecycles.contains(where: { $0.callID == callID }) else { return }
            turns[index].toolLifecycles.append(ToolLifecycle(callID: callID, name: record.name ?? "", normalizedArgsHash: record.argsHash))
        case .toolStarted:
            guard let callID = record.callID else { return }
            let position = lifecycleIndex(callID, name: record.name, turn: index)
            turns[index].toolLifecycles[position].state = .started
        case .toolFinished:
            guard let callID = record.callID else { return }
            let position = lifecycleIndex(callID, name: record.name, turn: index)
            turns[index].toolLifecycles[position].state = .completed
            turns[index].toolLifecycles[position].outcome = .known
            turns[index].toolLifecycles[position].status = record.status
            turns[index].toolLifecycles[position].errorCode = record.errorCode
        case .usage:
            turns[index].usage.requestsWithUsage += 1
            if let input = record.inputTokens { turns[index].usage.inputTokens = (turns[index].usage.inputTokens ?? 0) + input }
            if let output = record.outputTokens { turns[index].usage.outputTokens = (turns[index].usage.outputTokens ?? 0) + output }
            if let reasoning = record.reasoningTokens { turns[index].usage.reasoningTokens = (turns[index].usage.reasoningTokens ?? 0) + reasoning }
        case .messages:
            turns[index].messages.append(contentsOf: record.messages ?? [])
            if let accessed = record.accessedPaths {
                turns[index].accessedPaths = accessed
            }
            fillArgumentHashes(turn: index)
        case .turnTerminal:
            turns[index].terminal = record.terminal
            turns[index].endedAt = record.at
            turns[index].failureCode = record.text
        default:
            break
        }
    }

    private mutating func lifecycleIndex(_ callID: String, name: String?, turn index: Int) -> Int {
        if let position = turns[index].toolLifecycles.firstIndex(where: { $0.callID == callID }) { return position }
        turns[index].toolLifecycles.append(ToolLifecycle(callID: callID, name: name ?? ""))
        return turns[index].toolLifecycles.count - 1
    }

    private mutating func fillArgumentHashes(turn index: Int) {
        var hashes: [String: String] = [:]
        for message in turns[index].messages where message.role == .assistant {
            for call in message.toolCalls { hashes[call.id] = ContentHash.normalizedArgumentsHash(call.argumentsJSON) }
        }
        for position in turns[index].toolLifecycles.indices where turns[index].toolLifecycles[position].normalizedArgsHash == nil {
            turns[index].toolLifecycles[position].normalizedArgsHash = hashes[turns[index].toolLifecycles[position].callID]
        }
    }

    func build(finalize: Bool) -> Conversation? {
        guard let header else { return nil }
        var resolved = turns
        if finalize {
            for index in resolved.indices {
                if resolved[index].terminal == nil { resolved[index].terminal = .interrupted }
                for position in resolved[index].toolLifecycles.indices {
                    switch resolved[index].toolLifecycles[position].state {
                    case .pending, .started:
                        resolved[index].toolLifecycles[position].state = .unknown
                        resolved[index].toolLifecycles[position].outcome = .unknown
                    default:
                        break
                    }
                }
            }
        }
        return Conversation(id: id, workspaceID: header.workspaceID, providerID: header.providerID, modelID: header.modelID, title: header.title, createdAt: header.createdAt, updatedAt: updatedAt, turns: resolved)
    }
}
