import Foundation

public enum AgentEventKind: String, Sendable, Codable {
    case turnStarted
    case textDelta
    case activity
    case toolRequested
    case toolStarted
    case toolFinished
    case usageUpdated
    case turnCompleted
    case turnCancelled
    case turnFailed
    case turnBudgetExceeded

    public var isTerminal: Bool {
        switch self {
        case .turnCompleted, .turnCancelled, .turnFailed, .turnBudgetExceeded: return true
        default: return false
        }
    }
}

public struct AgentEvent: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let turnID: UUID
    public let sequence: Int
    public let timestamp: Date
    public let kind: AgentEventKind
    public let payload: [String: String]

    public init(sessionID: UUID, turnID: UUID, sequence: Int, timestamp: Date = Date(), kind: AgentEventKind, payload: [String: String] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.payload = payload
    }
}
