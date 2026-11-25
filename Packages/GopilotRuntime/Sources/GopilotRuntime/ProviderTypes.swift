import Foundation

public struct ToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ModelMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public let role: Role
    public let content: String
    public let toolCalls: [ToolCall]
    public let toolCallID: String?

    public init(role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public enum ReasoningEffort: String, CaseIterable, Sendable, Equatable, Codable {
    case `default` = "default"
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var displayTitle: String {
        switch self {
        case .default: return "Default"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct TurnRouteSelection: Sendable, Equatable, Codable {
    public let gatewayID: String
    public let routeID: String
    public let displayName: String
    public let dialect: String
    public let effort: ReasoningEffort

    public init(
        gatewayID: String = "default",
        routeID: String,
        displayName: String? = nil,
        dialect: String = "chat_completions",
        effort: ReasoningEffort = .default
    ) {
        self.gatewayID = gatewayID
        self.routeID = routeID
        self.displayName = displayName ?? routeID
        self.dialect = dialect
        self.effort = effort
    }
}

public struct ProviderContinuation: Sendable, Equatable {
    public let routeID: String
    public let reasoningContent: String?

    public init(routeID: String, reasoningContent: String?) {
        self.routeID = routeID
        self.reasoningContent = reasoningContent
    }
}

public struct ProviderRequest: Sendable, Equatable {
    public let messages: [ModelMessage]
    public let tools: [ToolSchema]
    public let routeOverride: String?
    public let reasoningEffort: ReasoningEffort
    public let assistantContinuations: [Int: ProviderContinuation]

    public init(
        messages: [ModelMessage],
        tools: [ToolSchema],
        routeOverride: String? = nil,
        reasoningEffort: ReasoningEffort = .default,
        assistantContinuations: [Int: ProviderContinuation] = [:]
    ) {
        self.messages = messages
        self.tools = tools
        self.routeOverride = routeOverride
        self.reasoningEffort = reasoningEffort
        self.assistantContinuations = assistantContinuations
    }
}

public enum FinishReason: String, Sendable, Equatable, Codable {
    case stop
    case toolCalls
    case length
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let responseModelID: String?

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        reasoningTokens: Int? = nil,
        responseModelID: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.responseModelID = responseModelID
    }
}

public enum ProviderEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
    case toolCallTruncated(name: String)
    case finish(FinishReason)
}

public protocol ProviderAdapter: Sendable {
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

public enum ProviderError: Error, Sendable, Equatable {
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case server(status: Int)
    case offline
    case malformedResponse(String)
    case unsupportedParameter(field: String, message: String)
    case contextLengthExceeded
    case requestRejected(status: Int, reason: String?)
    case consentRequired(host: String)
}
