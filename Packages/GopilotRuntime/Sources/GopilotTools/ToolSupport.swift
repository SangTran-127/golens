import Foundation
import GopilotRuntime
import GopilotPolicy

enum ToolLimits {
    static let resultBytes = 8 * 1024
    static let envelopeReserve = 384
    static let fieldClip = 400
}

enum ToolSchemas {
    static let cursor = #""cursor":{"type":"string","minLength":1,"maxLength":512}"#

    static func limit(_ max: Int) -> String {
        #""limit":{"type":"integer","minimum":1,"maximum":\#(max)}"#
    }

    static func object(properties: [String], required: [String] = []) -> String {
        let req = required.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"# + properties.joined(separator: ",") + #"},"required":["# + req + #"],"additionalProperties":false}"#
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringArray: [String]? {
        guard let items = arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }
}

enum JSONText {
    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func size(_ object: [String: Any]) -> Int {
        encode(object).utf8.count
    }

    static func object<Value: Encodable>(from value: Value) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return raw
    }

    static func finite(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }

    static func clip(_ text: String, _ limit: Int = ToolLimits.fieldClip) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    static func tail(_ text: String, maxBytes: Int) -> (text: String, omittedBytes: Int) {
        let total = text.utf8.count
        guard total > maxBytes else { return (text, 0) }
        var used = 0
        var kept: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let width = String(scalar).utf8.count
            if used + width > maxBytes { break }
            used += width
            kept.append(scalar)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: kept.reversed())
        return (String(view), total - used)
    }

    static func page(_ text: String, startScalar: Int, maxBytes: Int) -> (text: String, endScalar: Int, totalScalars: Int) {
        let scalars = Array(text.unicodeScalars)
        let total = scalars.count
        let start = min(max(0, startScalar), total)
        var used = 0
        var out = String.UnicodeScalarView()
        var index = start
        while index < total {
            let width = String(scalars[index]).utf8.count
            if used + width > maxBytes { break }
            used += width
            out.append(scalars[index])
            index += 1
        }
        return (String(out), index, total)
    }
}

enum ItemFit {
    static func shownCount(base: [String: Any], key: String, items: [[String: Any]], budget: Int = ToolLimits.resultBytes - ToolLimits.envelopeReserve) -> Int {
        var withEmpty = base
        withEmpty[key] = [[String: Any]]()
        var used = JSONText.size(withEmpty)
        var count = 0
        for item in items {
            let width = JSONText.size(item) + 1
            if used + width > budget { break }
            used += width
            count += 1
        }
        return count
    }
}

enum Step<Value> {
    case value(Value)
    case reply(ToolResultEnvelope)
}

struct ExecTool: GopilotTool {
    let schema: ToolSchema
    let handler: @Sendable (String, [String: JSONValue]) async -> ToolResultEnvelope

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        let args = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        return await handler(callID, args)
    }
}

struct ExecutionKit: Sendable {
    let context: ExecutionToolContext

    func makeTool(name: String, description: String, parameters: String, handler: @escaping @Sendable (String, [String: JSONValue]) async -> ToolResultEnvelope) -> ExecTool {
        ExecTool(schema: ToolSchema(name: name, description: description, parametersJSON: parameters), handler: handler)
    }

    func redact(_ text: String) -> String {
        context.redactor(text)
    }

    func envelope(callID: String, outcome: String, code: ToolErrorCode?, retryable: Bool, snapshotID: String?, fields: [String: Any] = [:], evidenceIDs: [String] = [], truncated: Bool = false, nextCursor: String? = nil) -> ToolResultEnvelope {
        var object = fields
        object["outcome"] = outcome
        object["truncated"] = truncated
        var text = JSONText.encode(object)
        var isTruncated = truncated
        if text.utf8.count > ToolLimits.resultBytes {
            isTruncated = true
            text = JSONText.encode([
                "outcome": outcome,
                "truncated": true,
                "message": "The result exceeded \(ToolLimits.resultBytes) bytes and was replaced by this marker. Narrow the request or page with a cursor."
            ])
        }
        return ToolResultEnvelope(
            callID: callID,
            status: code == nil ? .ok : .error,
            data: text,
            evidenceIDs: evidenceIDs,
            sourceSnapshotID: snapshotID,
            truncated: isTruncated,
            nextCursor: nextCursor,
            errorCode: code,
            retryable: retryable
        )
    }

    func failure(callID: String, code: ToolErrorCode, message: String, retryable: Bool = false, fields: [String: Any] = [:]) -> ToolResultEnvelope {
        var object = fields
        object["message"] = JSONText.clip(message, 600)
        return envelope(callID: callID, outcome: "error", code: code, retryable: retryable, snapshotID: nil, fields: object)
    }

    func storeEvidence(toolName: String, callID: String, kind: EvidenceKind, refs: [SourceRef] = [], snapshotID: String, fields: [String: Any], truncated: Bool = false, basis: EvidenceBasis = .observed) async -> String {
        var object = fields
        object["truncated"] = truncated
        let stored = await context.evidence.add(EvidenceDraft(
            workspaceID: context.workspaceID,
            producerID: "\(toolName):\(callID)",
            kind: kind,
            sourceRefs: refs,
            snapshotID: snapshotID,
            content: JSONText.encode(object),
            isTruncated: truncated,
            basis: basis
        ))
        return stored.id
    }

    func found(callID: String, toolName: String, kind: EvidenceKind, refs: [SourceRef] = [], snapshotID: String, fields: [String: Any], truncated: Bool = false, nextCursor: String? = nil, basis: EvidenceBasis = .observed, code: ToolErrorCode? = nil, retryable: Bool = false, outcome: String = "found") async -> ToolResultEnvelope {
        let evidenceID = await storeEvidence(toolName: toolName, callID: callID, kind: kind, refs: refs, snapshotID: snapshotID, fields: fields, truncated: truncated, basis: basis)
        var object = fields
        object["evidenceID"] = evidenceID
        return envelope(callID: callID, outcome: outcome, code: code, retryable: retryable, snapshotID: snapshotID, fields: object, evidenceIDs: [evidenceID], truncated: truncated, nextCursor: nextCursor)
    }

    func cursorOffset(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value >= 0 else { return nil }
        return value
    }
}
