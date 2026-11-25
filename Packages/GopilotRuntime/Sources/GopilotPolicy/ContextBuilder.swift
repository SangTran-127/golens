import Foundation
import GopilotRuntime

public struct ContextBudget: Sendable, Equatable {
    public static let unknownInputTokens = 8_000
    public static let unknownOutputTokens = 2_000
    public static let minimumOutputFraction = 0.2

    public let inputTokens: Int
    public let outputTokens: Int
    public let isDeclared: Bool

    public init(contextWindow: Int?, declaredOutputLimit: Int? = nil) {
        guard let window = contextWindow, window > 0 else {
            inputTokens = Self.unknownInputTokens
            outputTokens = Self.unknownOutputTokens
            isDeclared = false
            return
        }
        let floor = Int((Double(window) * Self.minimumOutputFraction).rounded(.up))
        let declared = min(max(0, declaredOutputLimit ?? 0), window / 2)
        let reserve = max(floor, declared)
        outputTokens = reserve
        inputTokens = window - reserve
        isDeclared = true
    }
}

public struct AttachedSelection: Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct ApprovedNote: Sendable, Equatable {
    public let id: String
    public let text: String
    public let isStale: Bool

    public init(id: String, text: String, isStale: Bool = false) {
        self.id = id
        self.text = text
        self.isStale = isStale
    }
}

public struct ContextInput: Sendable {
    public var systemPrompt: String
    public var userRequest: String
    public var attachedSelection: AttachedSelection?
    public var attachedSources: [AttachedSourceSnapshot]
    public var readScope: TurnReadScope
    public var turnProvenance: [UUID: Set<String>]
    public var snapshotFacts: [String]
    public var freshEvidence: [Evidence]
    public var approvedNotes: [ApprovedNote]
    public var recentTurns: [ConversationTurn]
    public var summary: ConversationSummary?
    public var currentSnapshot: SourceSnapshot?

    public init(
        systemPrompt: String,
        userRequest: String,
        attachedSelection: AttachedSelection? = nil,
        attachedSources: [AttachedSourceSnapshot] = [],
        readScope: TurnReadScope = .unrestricted,
        turnProvenance: [UUID: Set<String>] = [:],
        snapshotFacts: [String] = [],
        freshEvidence: [Evidence] = [],
        approvedNotes: [ApprovedNote] = [],
        recentTurns: [ConversationTurn] = [],
        summary: ConversationSummary? = nil,
        currentSnapshot: SourceSnapshot? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userRequest = userRequest
        self.attachedSelection = attachedSelection
        self.attachedSources = attachedSources
        self.readScope = readScope
        self.turnProvenance = turnProvenance
        self.snapshotFacts = snapshotFacts
        self.freshEvidence = freshEvidence
        self.approvedNotes = approvedNotes
        self.recentTurns = recentTurns
        self.summary = summary
        self.currentSnapshot = currentSnapshot
    }
}

public enum ContextSection: String, Sendable, Equatable {
    case userRequest
    case attachedSelection
    case attachedSources
    case snapshotFacts
    case freshEvidence
    case approvedNotes
    case recentTurns
    case incompleteTurn
    case outOfScopeHistory
    case summary
}

public struct BuiltContext: Sendable, Equatable {
    public let messages: [ModelMessage]
    public let estimatedInputTokens: Int
    public let budget: ContextBudget
    public let omitted: [ContextSection]
    public let redactions: [String: Int]
    public let requestWasTruncated: Bool
}

public struct ContextBuilder: Sendable {
    public static let maxToolResultBytes = 8 * 1024
    public static let maxAttachedSourceBytes = 16 * 1024

    private let filter: SecretFilter
    private let budget: ContextBudget
    public let sessionSalt: String?

    public init(budget: ContextBudget, filter: SecretFilter = SecretFilter(), sessionSalt: String? = nil) {
        self.budget = budget
        self.filter = filter
        self.sessionSalt = sessionSalt
    }

    public func build(_ input: ContextInput) -> BuiltContext {
        var redactions: [String: Int] = [:]
        func clean(_ text: String) -> String {
            let result = filter.redact(text)
            for (name, count) in result.counts { redactions[name, default: 0] += count }
            return result.text
        }

        func cleanMessage(_ message: ModelMessage) -> ModelMessage {
            ModelMessage(
                role: message.role,
                content: clean(message.content),
                toolCalls: message.toolCalls.map { ToolCall(id: $0.id, name: $0.name, argumentsJSON: clean($0.argumentsJSON)) },
                toolCallID: message.toolCallID
            )
        }

        let system = clean(input.systemPrompt) + "\n\n" + UntrustedData.policyNotice
        var request = clean(input.userRequest)
        var used = TokenEstimator.estimate(system).value + TokenEstimator.perMessageOverhead

        var requestTruncated = false
        let truncationMarker = "\n[request truncated to fit the context budget]"
        let requestRoom = max(0, budget.inputTokens - used - 2 * TokenEstimator.perMessageOverhead - TokenEstimator.estimate(truncationMarker).value)
        while TokenEstimator.estimate(request).value > requestRoom, request.count > 1 {
            request = String(request.prefix(max(1, request.count / 2)))
            requestTruncated = true
        }
        if requestTruncated { request += truncationMarker }
        used += TokenEstimator.estimate(request).value + TokenEstimator.perMessageOverhead

        var omitted: [ContextSection] = []
        var blocks: [String] = []

        func tryAdd(_ block: String, section: ContextSection) -> Bool {
            let cost = TokenEstimator.estimate(block).value
            guard used + cost <= budget.inputTokens else {
                if !omitted.contains(section) { omitted.append(section) }
                return false
            }
            used += cost
            blocks.append(block)
            return true
        }

        if let selection = input.attachedSelection {
            _ = tryAdd(UntrustedData.wrap(kind: "attached_selection", source: selection.path, content: clean(selection.text), salt: sessionSalt), section: .attachedSelection)
        }

        for attached in input.attachedSources {
            var cleanedText = clean(attached.text)
            var wasTruncated = attached.wasTruncated
            if cleanedText.utf8.count > Self.maxAttachedSourceBytes {
                let marker = "\n[truncated: attached source capped at \(Self.maxAttachedSourceBytes) bytes]"
                let room = max(0, Self.maxAttachedSourceBytes - marker.utf8.count)
                cleanedText = TextBounds.truncate(cleanedText, maxBytes: room).text + marker
                wasTruncated = true
            }
            var parts: [String] = ["path=\(attached.ref.relativePath)"]
            if let symbol = attached.ref.symbolName, !symbol.isEmpty {
                parts.append("symbol=\(symbol)")
            }
            if let range = attached.ref.range {
                parts.append("lines=\(range.startLine + 1)-\(range.endLine + 1)")
            }
            if let evidenceID = attached.evidenceID, !evidenceID.isEmpty {
                parts.append("evidenceID=\(evidenceID)")
            }
            if attached.ref.isUnsaved {
                parts.append("unsaved=true")
            }
            if wasTruncated {
                parts.append("truncated=true")
            }
            let block = UntrustedData.wrap(kind: "attached_source", source: parts.joined(separator: " "), content: cleanedText, salt: sessionSalt)
            if !tryAdd(block, section: .attachedSources) { break }
        }

        let projectContextEnabled = input.readScope.projectContextEnabled

        if projectContextEnabled, !input.snapshotFacts.isEmpty {
            let body = input.snapshotFacts.map { "- " + clean($0) }.joined(separator: "\n")
            _ = tryAdd("<workspace-facts>\n\(body)\n</workspace-facts>", section: .snapshotFacts)
        }

        let scopedEvidence = input.freshEvidence.filter { evidence in
            guard !projectContextEnabled else { return true }
            guard !evidence.sourceRefs.isEmpty else { return false }
            return evidence.sourceRefs.allSatisfy { ref in
                input.readScope.allowsFile(relativePath: ref.path, dependencyRootID: ref.dependencyRootID)
            }
        }

        for evidence in scopedEvidence {
            var attributes = "id=\"\(evidence.id)\" kind=\"\(evidence.kind.rawValue)\" basis=\"\(evidence.basis.rawValue)\""
            if evidence.isTruncated { attributes += " truncated=\"true\"" }
            if let snapshot = input.currentSnapshot, Staleness.assess(evidence, against: snapshot).isStale {
                attributes += " stale=\"true\""
            }
            let block = UntrustedData.wrap(kind: "evidence", source: attributes, content: clean(evidence.content), salt: sessionSalt)
            if !tryAdd(block, section: .freshEvidence) { break }
        }

        if projectContextEnabled {
            for note in input.approvedNotes {
                let label = note.isStale ? "note \(note.id) (stale, revalidate)" : "note \(note.id)"
                if !tryAdd(UntrustedData.wrap(kind: "approved_note", source: label, content: clean(note.text), salt: sessionSalt), section: .approvedNotes) { break }
            }
        }

        let allowedPaths = Set(input.readScope.allowedSources.map(\.relativePath))
        var turnMessages: [[ModelMessage]] = []
        for turn in input.recentTurns.reversed() {
            guard turn.isComplete else {
                if !omitted.contains(.incompleteTurn) { omitted.append(.incompleteTurn) }
                continue
            }
            if !projectContextEnabled {
                guard let provenance = input.turnProvenance[turn.id],
                      !provenance.isEmpty,
                      provenance.isSubset(of: allowedPaths) else {
                    if !omitted.contains(.outOfScopeHistory) { omitted.append(.outOfScopeHistory) }
                    continue
                }
            }
            let cleaned = turn.messages.map(cleanMessage)
            let cost = TokenEstimator.estimate(cleaned).value
            guard used + cost <= budget.inputTokens else {
                if !omitted.contains(.recentTurns) { omitted.append(.recentTurns) }
                break
            }
            used += cost
            turnMessages.insert(cleaned, at: 0)
        }

        if projectContextEnabled, let summary = input.summary, !summary.items.isEmpty {
            _ = tryAdd(UntrustedData.wrap(kind: "conversation_summary", source: "earlier turns", content: clean(summary.render()), salt: sessionSalt), section: .summary)
        }

        var messages: [ModelMessage] = [ModelMessage(role: .system, content: system)]
        messages.append(contentsOf: turnMessages.flatMap { $0 })
        let userContent = blocks.isEmpty ? request : blocks.joined(separator: "\n\n") + "\n\nUser request:\n" + request
        messages.append(ModelMessage(role: .user, content: userContent))

        return BuiltContext(messages: messages, estimatedInputTokens: used, budget: budget, omitted: omitted, redactions: redactions, requestWasTruncated: requestTruncated)
    }

    public func toolMessage(for envelope: ToolResultEnvelope, toolName: String) -> ModelMessage {
        let overhead = UntrustedData.wrap(kind: "tool_result", source: toolName, content: "", salt: sessionSalt).utf8.count
        var capped = Self.cap(envelope, maxBytes: Self.maxToolResultBytes - overhead - 256)
        let redacted = filter.redact(capped.data).text
        capped = ToolResultEnvelope(
            callID: capped.callID, status: capped.status,
            data: UntrustedData.wrap(kind: "tool_result", source: toolName, content: redacted, salt: sessionSalt),
            evidenceIDs: capped.evidenceIDs, sourceSnapshotID: capped.sourceSnapshotID, truncated: capped.truncated,
            nextCursor: capped.nextCursor, errorCode: capped.errorCode, retryable: capped.retryable
        )
        return ModelMessage(role: .tool, content: capped.modelContent(), toolCallID: envelope.callID)
    }

    public static func cap(_ envelope: ToolResultEnvelope, maxBytes: Int = ContextBuilder.maxToolResultBytes) -> ToolResultEnvelope {
        let total = envelope.data.utf8.count
        guard total > maxBytes else { return envelope }
        let cursorNote = envelope.nextCursor.map { "; nextCursor=\($0)" } ?? ""
        let marker = "\n[truncated: tool result was \(total) bytes and was cut to fit the \(maxBytes) byte limit\(cursorNote)]"
        let room = max(0, maxBytes - marker.utf8.count)
        let cut = TextBounds.truncate(envelope.data, maxBytes: room)
        return ToolResultEnvelope(
            callID: envelope.callID, status: envelope.status, data: cut.text + marker,
            evidenceIDs: envelope.evidenceIDs, sourceSnapshotID: envelope.sourceSnapshotID, truncated: true,
            nextCursor: envelope.nextCursor, errorCode: envelope.errorCode, retryable: envelope.retryable
        )
    }
}
