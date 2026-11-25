import Foundation
import GopilotRuntime

public enum ToolLifecycleState: String, Sendable, Codable {
    case pending
    case started
    case completed
    case unknown
}

public enum OutcomeKnowledge: String, Sendable, Codable {
    case known
    case unknown
}

public enum TurnTerminalState: String, Sendable, Codable {
    case completed
    case cancelled
    case failed
    case budgetExceeded
    case interrupted
}

public struct ToolLifecycle: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let callID: String
    public var name: String
    public var normalizedArgsHash: String?
    public var state: ToolLifecycleState
    public var outcome: OutcomeKnowledge
    public var status: String?
    public var errorCode: String?

    public init(callID: String, name: String, normalizedArgsHash: String? = nil, state: ToolLifecycleState = .pending, outcome: OutcomeKnowledge = .unknown, status: String? = nil, errorCode: String? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.callID = callID
        self.name = name
        self.normalizedArgsHash = normalizedArgsHash
        self.state = state
        self.outcome = outcome
        self.status = status
        self.errorCode = errorCode
    }
}

public struct TurnUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var modelRequests: Int
    public var requestsWithUsage: Int

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil, modelRequests: Int = 0, requestsWithUsage: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.modelRequests = modelRequests
        self.requestsWithUsage = requestsWithUsage
    }
}

public struct DisplayMessage: Sendable, Equatable {
    public let message: ModelMessage
    public let isSynthetic: Bool
    public let outcome: OutcomeKnowledge
}

public struct Turn: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let unknownOutcomeText = "Outcome unknown. The app stopped before this tool call finished, and it was not run again."

    public var schemaVersion: Int
    public let id: UUID
    public var userPrompt: String
    public var displayLabel: String?
    public var routeSelection: TurnRouteSelection?
    public var projectContextEnabled: Bool?
    public var attachedPaths: [String]?
    public var accessedPaths: [String]?
    public var messages: [ModelMessage]
    public var toolLifecycles: [ToolLifecycle]
    public var usage: TurnUsage
    public var terminal: TurnTerminalState?
    public var failureCode: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID,
        userPrompt: String,
        displayLabel: String? = nil,
        routeSelection: TurnRouteSelection? = nil,
        projectContextEnabled: Bool? = nil,
        attachedPaths: [String]? = nil,
        accessedPaths: [String]? = nil,
        startedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.userPrompt = userPrompt
        self.displayLabel = displayLabel
        self.routeSelection = routeSelection
        self.projectContextEnabled = projectContextEnabled
        self.attachedPaths = attachedPaths
        self.accessedPaths = accessedPaths
        self.messages = []
        self.toolLifecycles = []
        self.usage = TurnUsage()
        self.terminal = nil
        self.failureCode = nil
        self.startedAt = startedAt
        self.endedAt = nil
    }

    public var durationSeconds: Double? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var displayMessages: [DisplayMessage] {
        var firstResults: [String: ModelMessage] = [:]
        var requestedIDs = Set<String>()
        for message in messages {
            if message.role == .assistant { requestedIDs.formUnion(message.toolCalls.map(\.id)) }
            if message.role == .tool, let callID = message.toolCallID, firstResults[callID] == nil {
                firstResults[callID] = message
            }
        }
        var output: [DisplayMessage] = []
        for message in messages {
            switch message.role {
            case .tool:
                if let callID = message.toolCallID, requestedIDs.contains(callID) { continue }
                output.append(DisplayMessage(message: message, isSynthetic: false, outcome: .known))
            case .assistant where !message.toolCalls.isEmpty:
                output.append(DisplayMessage(message: message, isSynthetic: false, outcome: .known))
                for call in message.toolCalls {
                    if let result = firstResults[call.id] {
                        output.append(DisplayMessage(message: result, isSynthetic: false, outcome: .known))
                    } else {
                        let synthetic = ModelMessage(role: .tool, content: Self.unknownOutcomeText, toolCallID: call.id)
                        output.append(DisplayMessage(message: synthetic, isSynthetic: true, outcome: .unknown))
                    }
                }
            default:
                output.append(DisplayMessage(message: message, isSynthetic: false, outcome: .known))
            }
        }
        return output
    }

    public var repairedCallIDs: [String] {
        displayMessages.filter(\.isSynthetic).compactMap(\.message.toolCallID)
    }

    public var evidenceIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for message in messages where message.role == .tool {
            guard let data = message.content.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = object["evidenceIDs"] as? [String] else { continue }
            for id in ids where seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }
}

public struct Conversation: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let id: UUID
    public let workspaceID: UUID
    public var providerID: String
    public var modelID: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var turns: [Turn]

    public init(id: UUID, workspaceID: UUID, providerID: String, modelID: String, title: String, createdAt: Date, updatedAt: Date, turns: [Turn] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.modelID = modelID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
    }

    public var displayMessages: [DisplayMessage] {
        turns.flatMap(\.displayMessages)
    }
}

public struct ConversationSummary: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let id: UUID
    public var workspaceID: UUID
    public var providerID: String
    public var modelID: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var turnCount: Int
    public var transcriptBytes: Int
    public var trashedAt: Date?

    public init(id: UUID, workspaceID: UUID, providerID: String, modelID: String, title: String, createdAt: Date, updatedAt: Date, turnCount: Int = 0, transcriptBytes: Int = 0, trashedAt: Date? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.modelID = modelID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.transcriptBytes = transcriptBytes
        self.trashedAt = trashedAt
    }
}
