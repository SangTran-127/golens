import Foundation
import CryptoKit

public struct TurnCompactionResult: Sendable, Equatable {
    public let messages: [ModelMessage]
    public let compactedToolResults: Int
    public let compactedWritePayloads: Int
    public let estimatedTokens: Int

    public var didCompact: Bool { compactedToolResults > 0 || compactedWritePayloads > 0 }
}

public enum TurnContextCompactor {
    public static let perMessageOverhead = 4
    static let largeArgumentKeys: Set<String> = ["content", "newText", "oldText"]
    static let writeToolNames: Set<String> = ["write_file", "edit_file", "propose_patch"]
    static let compactedMarker = "\"compacted\":true"

    public static func estimateTokens(_ text: String) -> Int {
        var total = 0.0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: total += 0.34
                case 0x09, 0x0A, 0x0D, 0x20: total += 0.2
                default: total += 0.7
                }
            } else if scalar.value > 0xFFFF {
                total += 3.0
            } else {
                total += 1.3
            }
        }
        return Int(total.rounded(.up))
    }

    public static func estimateTokens(_ message: ModelMessage) -> Int {
        var total = perMessageOverhead + estimateTokens(message.content)
        for call in message.toolCalls {
            total += perMessageOverhead + estimateTokens(call.name) + estimateTokens(call.argumentsJSON)
        }
        return total
    }

    public static func estimateTokens(_ messages: [ModelMessage], tools: [ToolSchema] = []) -> Int {
        let messageTokens = messages.reduce(0) { $0 + estimateTokens($1) }
        let toolTokens = tools.reduce(0) { $0 + perMessageOverhead + estimateTokens($1.name) + estimateTokens($1.description) + estimateTokens($1.parametersJSON) }
        return messageTokens + toolTokens
    }

    public static func compact(
        _ messages: [ModelMessage],
        tools: [ToolSchema] = [],
        budget: Int,
        protectedPrefixCount: Int,
        keepRecentToolResults: Int = 4
    ) -> TurnCompactionResult {
        var working = messages
        var toolResults = 0
        var writePayloads = 0
        var estimate = estimateTokens(working, tools: tools)
        guard estimate > budget else {
            return TurnCompactionResult(messages: working, compactedToolResults: 0, compactedWritePayloads: 0, estimatedTokens: estimate)
        }

        let lastAssistantWithCalls = working.lastIndex { $0.role == .assistant && !$0.toolCalls.isEmpty }
        let start = min(max(0, protectedPrefixCount), working.count)
        for index in start..<working.count where estimate > budget {
            let message = working[index]
            guard message.role == .assistant, !message.toolCalls.isEmpty, index != lastAssistantWithCalls else { continue }
            var changed = false
            let calls = message.toolCalls.map { call -> ToolCall in
                guard writeToolNames.contains(call.name), let compacted = compactArguments(call.argumentsJSON) else { return call }
                changed = true
                return ToolCall(id: call.id, name: call.name, argumentsJSON: compacted)
            }
            guard changed else { continue }
            let before = estimateTokens(message)
            let replacement = ModelMessage(role: .assistant, content: message.content, toolCalls: calls, toolCallID: message.toolCallID)
            working[index] = replacement
            estimate += estimateTokens(replacement) - before
            writePayloads += 1
        }

        let toolIndices = working.indices.filter { $0 >= start && working[$0].role == .tool }
        let keep = Set(toolIndices.suffix(max(0, keepRecentToolResults)))
        for index in toolIndices where estimate > budget && !keep.contains(index) {
            let message = working[index]
            guard !message.content.contains(compactedMarker) else { continue }
            let before = estimateTokens(message)
            let replacement = ModelMessage(role: .tool, content: compactedToolContent(message.content), toolCalls: [], toolCallID: message.toolCallID)
            guard estimateTokens(replacement) < before else { continue }
            working[index] = replacement
            estimate += estimateTokens(replacement) - before
            toolResults += 1
        }

        return TurnCompactionResult(messages: working, compactedToolResults: toolResults, compactedWritePayloads: writePayloads, estimatedTokens: estimate)
    }

    static func compactArguments(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var changed = false
        for key in largeArgumentKeys {
            guard let text = object[key] as? String, text.utf8.count > 256 else { continue }
            object[key] = "[omitted from context: \(text.utf8.count) bytes, sha256 \(sha256Prefix(text))]"
            changed = true
        }
        if var creates = object["creates"] as? [[String: Any]] {
            for index in creates.indices {
                if let text = creates[index]["content"] as? String, text.utf8.count > 256 {
                    creates[index]["content"] = "[omitted from context: \(text.utf8.count) bytes, sha256 \(sha256Prefix(text))]"
                    changed = true
                }
            }
            object["creates"] = creates
        }
        guard changed,
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: encoded, encoding: .utf8) else { return nil }
        return text
    }

    static func compactedToolContent(_ content: String) -> String {
        var status = "ok"
        var callID = ""
        var evidenceIDs: [String] = []
        if let data = content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            status = object["status"] as? String ?? status
            callID = object["callID"] as? String ?? ""
            evidenceIDs = object["evidenceIDs"] as? [String] ?? []
        }
        let object: [String: Any] = [
            "callID": callID,
            "status": status,
            "compacted": true,
            "evidenceIDs": evidenceIDs,
            "data": "This earlier tool result was removed to keep the conversation within the model's context window. Call the tool again if you still need its content."
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return content }
        return text
    }

    static func sha256Prefix(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
