import Foundation
import GopilotRuntime

public enum ArgumentNormalizer {
    public static func normalized(_ argumentsJSON: String) -> String {
        JSONValue.parse(argumentsJSON)?.canonicalString ?? "raw:" + argumentsJSON
    }

    public static func hash(_ argumentsJSON: String) -> String {
        Hashing.sha256Hex(normalized(argumentsJSON))
    }
}

public enum LedgerState: String, Sendable, Equatable, Codable {
    case pending
    case started
    case completed
    case unknown
}

public enum LedgerBegin: Sendable, Equatable {
    case execute
    case reuse(ToolResultEnvelope)
    case inFlight
    case interrupted
    case protocolError(String)
}

public actor ToolCallLedger {
    private struct Entry {
        let toolName: String
        let argsHash: String
        var state: LedgerState
        var result: ToolResultEnvelope?
    }

    private struct Key: Hashable {
        let turnID: UUID
        let callID: String
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    public func begin(turnID: UUID, call: ToolCall) -> LedgerBegin {
        let key = Key(turnID: turnID, callID: call.id)
        let hash = ArgumentNormalizer.hash(call.argumentsJSON)
        guard let entry = entries[key] else {
            entries[key] = Entry(toolName: call.name, argsHash: hash, state: .pending, result: nil)
            return .execute
        }
        guard entry.argsHash == hash, entry.toolName == call.name else {
            return .protocolError("Tool call id \(call.id) was reused with different arguments.")
        }
        switch entry.state {
        case .completed:
            if let result = entry.result { return .reuse(result) }
            return .interrupted
        case .pending, .started:
            return .inFlight
        case .unknown:
            return .interrupted
        }
    }

    public func markStarted(turnID: UUID, callID: String) {
        let key = Key(turnID: turnID, callID: callID)
        guard var entry = entries[key], entry.state == .pending else { return }
        entry.state = .started
        entries[key] = entry
    }

    public func complete(turnID: UUID, callID: String, result: ToolResultEnvelope) {
        let key = Key(turnID: turnID, callID: callID)
        guard var entry = entries[key], entry.state != .completed else { return }
        entry.state = .completed
        entry.result = result
        entries[key] = entry
    }

    public func state(turnID: UUID, callID: String) -> LedgerState? {
        entries[Key(turnID: turnID, callID: callID)]?.state
    }

    @discardableResult
    public func recoverInterrupted() -> Int {
        var changed = 0
        for (key, entry) in entries where entry.state == .started || entry.state == .pending {
            var updated = entry
            updated.state = .unknown
            entries[key] = updated
            changed += 1
        }
        return changed
    }
}

public enum LoopVerdict: Sendable, Equatable {
    case proceed
    case stop(explanation: String)
}

public struct LoopDetector: Sendable {
    public let threshold: Int
    private var counts: [String: Int] = [:]
    private var seenEvidence: Set<String> = []

    public init(threshold: Int = 3) {
        self.threshold = threshold
    }

    public mutating func record(toolName: String, argumentsJSON: String, snapshotID: String?, evidenceIDs: [String]) -> LoopVerdict {
        let key = [toolName, ArgumentNormalizer.hash(argumentsJSON), snapshotID ?? "-"].joined(separator: "|")
        let fresh = evidenceIDs.filter { !seenEvidence.contains($0) }
        seenEvidence.formUnion(evidenceIDs)

        if counts[key] == nil {
            counts[key] = 1
            return .proceed
        }
        if !fresh.isEmpty {
            counts[key] = 1
            return .proceed
        }
        let next = (counts[key] ?? 1) + 1
        counts[key] = next
        if next >= threshold {
            return .stop(explanation: "The \(toolName) tool was called \(next) times with the same arguments on the same source snapshot and produced no new evidence. Stopping instead of repeating it; report what is known and what is still unknown.")
        }
        return .proceed
    }
}
