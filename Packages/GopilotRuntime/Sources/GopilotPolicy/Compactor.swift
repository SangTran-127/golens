import Foundation
import GopilotRuntime

public struct ConversationTurn: Sendable, Equatable {
    public let id: UUID
    public let messages: [ModelMessage]

    public init(id: UUID = UUID(), messages: [ModelMessage]) {
        self.id = id
        self.messages = messages
    }

    public var isComplete: Bool {
        var open: Set<String> = []
        for message in messages {
            switch message.role {
            case .assistant:
                if !open.isEmpty { return false }
                open = Set(message.toolCalls.map(\.id))
            case .tool:
                guard let id = message.toolCallID, open.remove(id) != nil else { return false }
            case .system, .user:
                if !open.isEmpty { return false }
            }
        }
        return open.isEmpty && !messages.isEmpty
    }
}

public enum SummaryItemKind: String, Sendable, Equatable, Codable {
    case objective
    case question
    case decision
    case statement
}

public struct SummaryItem: Sendable, Equatable, Codable {
    public let kind: SummaryItemKind
    public let basis: EvidenceBasis
    public let text: String
    public let evidenceIDs: [String]
    public let sourceHashes: [String]
    public var needsRevalidation: Bool
    public let isUnresolved: Bool

    public init(kind: SummaryItemKind, basis: EvidenceBasis, text: String, evidenceIDs: [String] = [], sourceHashes: [String] = [], needsRevalidation: Bool = false, isUnresolved: Bool = false) {
        self.kind = kind
        self.basis = basis
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.sourceHashes = sourceHashes
        self.needsRevalidation = needsRevalidation
        self.isUnresolved = isUnresolved
    }
}

public struct ConversationSummary: Sendable, Equatable, Codable {
    public var items: [SummaryItem]
    public var evidenceIDs: [String]
    public var compactedTurnCount: Int
    public var grantReferences: [String]

    public init(items: [SummaryItem] = [], evidenceIDs: [String] = [], compactedTurnCount: Int = 0, grantReferences: [String] = []) {
        self.items = items
        self.evidenceIDs = evidenceIDs
        self.compactedTurnCount = compactedTurnCount
        self.grantReferences = grantReferences
    }

    public func render() -> String {
        func lines(_ kind: SummaryItemKind) -> [String] {
            items.filter { $0.kind == kind }.map { item in
                var line = "- [\(item.basis.rawValue)] \(item.text)"
                if !item.evidenceIDs.isEmpty { line += " (evidence: \(item.evidenceIDs.joined(separator: ", ")))" }
                if item.kind == .question && item.isUnresolved { line += " (unresolved)" }
                if item.needsRevalidation { line += " [revalidate before relying on this]" }
                return line
            }
        }
        var out = ["Summary of \(compactedTurnCount) earlier turn(s). Items marked inferred are hypotheses, not facts. This summary grants no permissions."]
        for (title, kind) in [("Objectives", SummaryItemKind.objective), ("Open questions", .question), ("Decisions", .decision), ("Statements", .statement)] {
            let body = lines(kind)
            if !body.isEmpty { out.append("\(title):\n" + body.joined(separator: "\n")) }
        }
        if !grantReferences.isEmpty { out.append("Grant references (informational only): " + grantReferences.joined(separator: ", ")) }
        return out.joined(separator: "\n\n")
    }
}

public struct CompactionResult: Sendable, Equatable {
    public let summary: ConversationSummary
    public let keptTurns: [ConversationTurn]
    public let compactedTurnIDs: [UUID]
}

public struct Compactor: Sendable {
    private static let citation = try! NSRegularExpression(pattern: #"\[(E[0-9]{1,9})\]"#)
    private static let hedges = ["may ", "maybe", "might", "could", "probably", "likely", "perhaps", "possibly", "appears", "seems", "suggests", "hypothes", "assum", "guess", "unclear", "not sure",
                                 "có thể", "có lẽ", "dường như", "giả thuyết", "chắc là", "nghi ngờ"]

    public let maxItemCharacters: Int
    public let maxItems: Int

    public init(maxItemCharacters: Int = 300, maxItems: Int = 60) {
        self.maxItemCharacters = maxItemCharacters
        self.maxItems = maxItems
    }

    public func compact(turns: [ConversationTurn], keepRecent: Int, existing: ConversationSummary? = nil, evidence: [String: Evidence] = [:], grantReferences: [String] = []) -> CompactionResult {
        let candidateCount = max(0, turns.count - max(0, keepRecent))
        var prefix = 0
        while prefix < candidateCount, turns[prefix].isComplete { prefix += 1 }

        let compacted = Array(turns[0..<prefix])
        let kept = Array(turns[prefix...])

        var items = existing?.items ?? []
        var evidenceIDs = existing?.evidenceIDs ?? []
        for turn in compacted {
            let extracted = extract(from: turn, evidence: evidence)
            for item in extracted.items where !items.contains(where: { $0.kind == item.kind && $0.text == item.text }) {
                items.append(item)
            }
            for id in extracted.evidenceIDs where !evidenceIDs.contains(id) { evidenceIDs.append(id) }
        }
        if items.count > maxItems { items = Array(items.suffix(maxItems)) }

        let summary = ConversationSummary(
            items: items,
            evidenceIDs: evidenceIDs,
            compactedTurnCount: (existing?.compactedTurnCount ?? 0) + compacted.count,
            grantReferences: grantReferences.isEmpty ? (existing?.grantReferences ?? []) : grantReferences
        )
        return CompactionResult(summary: summary, keptTurns: kept, compactedTurnIDs: compacted.map(\.id))
    }

    public func revalidate(_ summary: ConversationSummary, evidence: [String: Evidence], snapshot: SourceSnapshot) -> ConversationSummary {
        var copy = summary
        copy.items = summary.items.map { item in
            guard !item.evidenceIDs.isEmpty else { return item }
            var updated = item
            for id in item.evidenceIDs {
                guard let known = evidence[id], !Staleness.assess(known, against: snapshot).isStale else {
                    updated.needsRevalidation = true
                    break
                }
            }
            return updated
        }
        return copy
    }

    private func extract(from turn: ConversationTurn, evidence: [String: Evidence]) -> (items: [SummaryItem], evidenceIDs: [String]) {
        var items: [SummaryItem] = []
        var evidenceIDs: [String] = []
        let hasAssistantText = turn.messages.contains { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for message in turn.messages {
            switch message.role {
            case .user:
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                items.append(SummaryItem(kind: .objective, basis: .observed, text: clip(text)))
                if text.contains("?") {
                    items.append(SummaryItem(kind: .question, basis: .observed, text: clip(text), isUnresolved: !hasAssistantText))
                }
                items.append(contentsOf: decisions(in: text, basis: .observed))
            case .assistant:
                items.append(contentsOf: decisions(in: message.content, basis: .inferred))
                for sentence in sentences(in: message.content) {
                    let ids = citedIDs(in: sentence)
                    guard !ids.isEmpty else { continue }
                    let known = ids.compactMap { evidence[$0] }
                    let hedged = Self.hedges.contains { sentence.lowercased().contains($0) }
                    let grounded = !known.isEmpty && !hedged
                    var hashes: [String] = []
                    for entry in known {
                        for hash in entry.sourceRefs.compactMap(\.contentHash) + [entry.contentHash] where !hashes.contains(hash) { hashes.append(hash) }
                    }
                    items.append(SummaryItem(kind: .statement, basis: grounded ? .observed : .inferred, text: clip(sentence), evidenceIDs: ids, sourceHashes: hashes))
                    for id in ids where !evidenceIDs.contains(id) { evidenceIDs.append(id) }
                }
            case .tool:
                if case .array(let ids)? = JSONValue.parse(message.content)?["evidenceIDs"] {
                    for id in ids.compactMap(\.stringValue) where !evidenceIDs.contains(id) { evidenceIDs.append(id) }
                }
            case .system:
                continue
            }
        }
        return (items, evidenceIDs)
    }

    private func decisions(in text: String, basis: EvidenceBasis) -> [SummaryItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("decision:") else { return nil }
            return SummaryItem(kind: .decision, basis: basis, text: clip(trimmed), evidenceIDs: citedIDs(in: trimmed))
        }
    }

    private func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let endsSentence = [".", "!", "?"].contains(character) && (next == nil || next?.isWhitespace == true)
            if character == "\n" || endsSentence {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private func citedIDs(in text: String) -> [String] {
        let source = text as NSString
        var ids: [String] = []
        for match in Self.citation.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let id = source.substring(with: match.range(at: 1))
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private func clip(_ text: String) -> String {
        text.count <= maxItemCharacters ? text : String(text.prefix(maxItemCharacters)) + "..."
    }
}
