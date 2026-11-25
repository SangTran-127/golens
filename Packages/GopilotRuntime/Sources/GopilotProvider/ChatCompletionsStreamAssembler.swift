import Foundation
import GopilotRuntime

private struct WireFunction: Decodable {
    let name: String?
    let arguments: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        arguments = try? container.decodeIfPresent(String.self, forKey: .arguments)
    }

    private enum Keys: String, CodingKey {
        case name, arguments
    }
}

private struct WireToolCall: Decodable {
    let index: Int?
    let id: String?
    let function: WireFunction?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        index = try? container.decodeIfPresent(Int.self, forKey: .index)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        function = try? container.decodeIfPresent(WireFunction.self, forKey: .function)
    }

    private enum Keys: String, CodingKey {
        case index, id, function
    }
}

private struct WireDelta: Decodable {
    let content: String?
    let reasoningContent: String?
    let toolCalls: [WireToolCall]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        reasoningContent = try? container.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCalls = try? container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
    }

    private enum Keys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

private struct WireChoice: Decodable {
    let index: Int?
    let delta: WireDelta?
    let message: WireDelta?
    let finishReason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        index = try? container.decodeIfPresent(Int.self, forKey: .index)
        delta = try? container.decodeIfPresent(WireDelta.self, forKey: .delta)
        message = try? container.decodeIfPresent(WireDelta.self, forKey: .message)
        finishReason = try? container.decodeIfPresent(String.self, forKey: .finishReason)
    }

    private enum Keys: String, CodingKey {
        case index, delta, message
        case finishReason = "finish_reason"
    }
}

private struct WireTokenDetails: Decodable {
    let reasoningTokens: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        reasoningTokens = try? container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
    }

    private enum Keys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
    }
}

private struct WireUsage: Decodable {
    let input: Int?
    let output: Int?
    let reasoning: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let prompt = try? container.decodeIfPresent(Int.self, forKey: .promptTokens)
        let completion = try? container.decodeIfPresent(Int.self, forKey: .completionTokens)
        let inputAlias = try? container.decodeIfPresent(Int.self, forKey: .inputTokens)
        let outputAlias = try? container.decodeIfPresent(Int.self, forKey: .outputTokens)
        let completionDetails = try? container.decodeIfPresent(WireTokenDetails.self, forKey: .completionTokensDetails)
        let outputDetails = try? container.decodeIfPresent(WireTokenDetails.self, forKey: .outputTokensDetails)
        let directReasoning = try? container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        input = prompt ?? inputAlias
        output = completion ?? outputAlias
        reasoning = completionDetails?.reasoningTokens ?? outputDetails?.reasoningTokens ?? directReasoning
    }

    private enum Keys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case completionTokensDetails = "completion_tokens_details"
        case outputTokensDetails = "output_tokens_details"
        case reasoningTokens = "reasoning_tokens"
    }
}

private struct WireChunk: Decodable {
    let model: String?
    let choices: [WireChoice]?
    let usage: WireUsage?
    let hasError: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        choices = try? container.decodeIfPresent([WireChoice].self, forKey: .choices)
        usage = try? container.decodeIfPresent(WireUsage.self, forKey: .usage)
        hasError = container.contains(.error) && ((try? container.decodeNil(forKey: .error)) == false)
    }

    private enum Keys: String, CodingKey {
        case model, choices, usage, error
    }
}

public struct ChatCompletionsStreamAssembler: Sendable {
    private struct PendingToolCall {
        var id: String?
        var name = ""
        var arguments = ""
        var argumentBytes = 0
    }

    private let limits: SSELimits
    private var pending: [PendingToolCall] = []
    private var indexSlots: [Int: Int] = [:]
    private var finishReason: FinishReason?
    private var finishEmitted = false
    private var toolCallsResolved = false
    private var lastUsage: TokenUsage?
    private var latestModel: String?

    public init(limits: SSELimits = SSELimits()) {
        self.limits = limits
    }

    public var hasFinishReason: Bool { finishReason != nil }

    public mutating func consume(_ json: String) throws -> [ProviderEvent] {
        try consume(Data(json.utf8), positionalToolCalls: false)
    }

    mutating func consume(_ data: Data, positionalToolCalls: Bool) throws -> [ProviderEvent] {
        let chunk: WireChunk
        do {
            chunk = try JSONDecoder().decode(WireChunk.self, from: data)
        } catch {
            throw ProviderError.malformedResponse("The provider sent a response that is not valid JSON.")
        }
        if chunk.hasError {
            throw ProviderError.malformedResponse("The provider reported an error in the response.")
        }
        if let model = chunk.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            latestModel = model
        }

        var events: [ProviderEvent] = []
        if let choice = chunk.choices?.first(where: { ($0.index ?? 0) == 0 }) {
            let payload = choice.delta ?? choice.message
            if let reasoning = payload?.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = payload?.content, !content.isEmpty {
                events.append(.textDelta(content))
            }
            if let calls = payload?.toolCalls, !toolCallsResolved {
                for (position, call) in calls.enumerated() {
                    try accumulate(call, position: positionalToolCalls ? position : nil)
                }
            }
            if let raw = choice.finishReason, let reason = try mapFinishReason(raw) {
                events.append(contentsOf: try resolveToolCalls(for: reason))
                finishReason = reason
            }
        }
        if let usage = chunk.usage, usage.input != nil || usage.output != nil || usage.reasoning != nil {
            let mapped = TokenUsage(
                inputTokens: usage.input,
                outputTokens: usage.output,
                reasoningTokens: usage.reasoning,
                responseModelID: latestModel
            )
            if mapped != lastUsage {
                lastUsage = mapped
                events.append(.usage(mapped))
            }
        }
        return events
    }

    public mutating func end() -> [ProviderEvent] {
        guard let reason = finishReason, !finishEmitted else { return [] }
        finishEmitted = true
        return [.finish(reason)]
    }

    private func mapFinishReason(_ raw: String) throws -> FinishReason? {
        switch raw {
        case "stop": return .stop
        case "tool_calls": return .toolCalls
        case "length": return .length
        case "function_call", "null", "": return nil
        default:
            throw ProviderError.malformedResponse("The response ended with an unsupported finish reason.")
        }
    }

    private mutating func accumulate(_ call: WireToolCall, position: Int?) throws {
        let slot = slotIndex(for: call, position: position)
        if let id = call.id, !id.isEmpty, pending[slot].id == nil {
            pending[slot].id = id
        }
        if let name = call.function?.name, !name.isEmpty, pending[slot].name.isEmpty {
            pending[slot].name = name
        }
        if let fragment = call.function?.arguments, !fragment.isEmpty {
            pending[slot].argumentBytes += fragment.utf8.count
            guard pending[slot].argumentBytes <= limits.toolArgumentBytes else {
                throw ProviderError.malformedResponse("Tool call arguments exceeded the \(limits.toolArgumentBytes / 1024) KiB limit.")
            }
            pending[slot].arguments += fragment
        }
    }

    private mutating func slotIndex(for call: WireToolCall, position: Int?) -> Int {
        let index = call.index ?? position
        if let id = call.id, !id.isEmpty {
            if let existing = pending.firstIndex(where: { $0.id == id }) {
                if let index { indexSlots[index] = existing }
                return existing
            }
            if let index, let mapped = indexSlots[index], pending[mapped].id == nil {
                return mapped
            }
            return appendSlot(index: index)
        }
        if let index {
            if let mapped = indexSlots[index] { return mapped }
            return appendSlot(index: index)
        }
        if let last = pending.indices.last { return last }
        return appendSlot(index: nil)
    }

    private mutating func appendSlot(index: Int?) -> Int {
        pending.append(PendingToolCall())
        let slot = pending.count - 1
        if let index { indexSlots[index] = slot }
        return slot
    }

    private mutating func resolveToolCalls(for reason: FinishReason) throws -> [ProviderEvent] {
        guard !toolCallsResolved else { return [] }
        toolCallsResolved = true
        guard reason != .length else {
            let truncated = pending.map { ProviderEvent.toolCallTruncated(name: $0.name) }
            pending.removeAll()
            return truncated
        }
        var events: [ProviderEvent] = []
        for (ordinal, call) in pending.enumerated() {
            guard !call.name.isEmpty else {
                throw ProviderError.malformedResponse("A tool call arrived without a function name.")
            }
            let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = trimmed.isEmpty ? "{}" : call.arguments
            guard Self.isJSONObject(arguments) else {
                throw ProviderError.malformedResponse("Tool call arguments for \(call.name) were not a complete JSON object.")
            }
            let id = call.id ?? "call_\(ordinal)"
            events.append(.toolCall(ToolCall(id: id, name: call.name, argumentsJSON: arguments)))
        }
        pending.removeAll()
        return events
    }

    private static func isJSONObject(_ text: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return false }
        return object is [String: Any]
    }
}

public enum ChatCompletionsResponseDecoder {
    public static func decode(_ body: Data, limits: SSELimits = SSELimits()) throws -> [ProviderEvent] {
        var assembler = ChatCompletionsStreamAssembler(limits: limits)
        var events = try assembler.consume(body, positionalToolCalls: true)
        events.append(contentsOf: assembler.end())
        return events
    }
}
