import Foundation
import GopilotRuntime

enum OptionalRequestField: String, CaseIterable, Sendable {
    case streamOptions
    case parallelToolCalls
    case strict
    case maxTokens
    case reasoningEffort
}

struct EncodedRequest {
    let body: Data
    let sentFields: Set<OptionalRequestField>
    let maxTokensParameter: MaxTokensParameter
}

enum ChatCompletionsRequestEncoder {
    static func encode(
        configuration: ProviderConfiguration,
        request: ProviderRequest,
        streaming: Bool,
        allowed: Set<OptionalRequestField>,
        maxTokensParameter: MaxTokensParameter
    ) throws -> EncodedRequest {
        var sent: Set<OptionalRequestField> = []
        let effectiveModelID: String
        if let override = request.routeOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            effectiveModelID = override
        } else {
            effectiveModelID = configuration.modelID
        }
        let encodedMessages = request.messages.enumerated().map { idx, message in
            encodeMessage(
                message,
                index: idx,
                effectiveModelID: effectiveModelID,
                routeOverride: request.routeOverride,
                preservesReasoningContinuation: configuration.reasoningMode.preservesReasoningContinuation,
                continuations: request.assistantContinuations
            )
        }
        var root: [String: Any] = [
            "model": effectiveModelID,
            "messages": encodedMessages,
            "stream": streaming
        ]
        if streaming, allowed.contains(.streamOptions) {
            root["stream_options"] = ["include_usage": true]
            sent.insert(.streamOptions)
        }
        if !request.tools.isEmpty {
            let useStrict = allowed.contains(.strict)
            root["tools"] = try request.tools.map { try encodeTool($0, strict: useStrict) }
            if useStrict { sent.insert(.strict) }
            if allowed.contains(.parallelToolCalls) {
                root["parallel_tool_calls"] = true
                sent.insert(.parallelToolCalls)
            }
        }
        if configuration.outputTokenLimit > 0 {
            root[maxTokensParameter.rawValue] = configuration.outputTokenLimit
            sent.insert(.maxTokens)
        }
        if request.reasoningEffort != .default,
           case .openAIChatEffort(let supported) = configuration.reasoningMode,
           supported.contains(request.reasoningEffort) {
            root["reasoning_effort"] = request.reasoningEffort.rawValue
            sent.insert(.reasoningEffort)
        }
        let body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return EncodedRequest(body: body, sentFields: sent, maxTokensParameter: maxTokensParameter)
    }

    private static func encodeMessage(
        _ message: ModelMessage,
        index: Int,
        effectiveModelID: String,
        routeOverride: String?,
        preservesReasoningContinuation: Bool,
        continuations: [Int: ProviderContinuation]
    ) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue]
        switch message.role {
        case .assistant:
            if message.toolCalls.isEmpty {
                object["content"] = message.content
            } else {
                if message.content.isEmpty {
                    object["content"] = NSNull()
                } else {
                    object["content"] = message.content
                }
                object["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.argumentsJSON]
                    ]
                }
                if preservesReasoningContinuation,
                   let continuation = continuations[index],
                   (continuation.routeID == effectiveModelID || (routeOverride == nil && continuation.routeID == "default")),
                   let reasoning = continuation.reasoningContent,
                   !reasoning.isEmpty {
                    object["reasoning_content"] = reasoning
                }
            }
        case .tool:
            object["content"] = message.content
            object["tool_call_id"] = message.toolCallID ?? ""
        case .system, .user:
            object["content"] = message.content
        }
        return object
    }

    private static func encodeTool(_ tool: ToolSchema, strict: Bool) throws -> [String: Any] {
        guard let parameters = try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)) as? [String: Any] else {
            throw ProviderError.malformedResponse("The schema for tool \(tool.name) is not a valid JSON object.")
        }
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "parameters": parameters
        ]
        if strict { function["strict"] = true }
        return ["type": "function", "function": function]
    }
}
