import Foundation

public enum ToolErrorCode: String, Sendable, Codable {
    case invalidArguments
    case denied
    case staleContext
    case workspaceClosed
    case unavailable
    case busy
    case timeout
    case cancelled
    case tooLarge
    case notFound
    case incompatibleArtifact
}

public struct ToolResultEnvelope: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case ok
        case error
    }

    public let callID: String
    public let status: Status
    public let data: String
    public let evidenceIDs: [String]
    public let sourceSnapshotID: String?
    public let truncated: Bool
    public let nextCursor: String?
    public let errorCode: ToolErrorCode?
    public let retryable: Bool

    public init(callID: String, status: Status, data: String, evidenceIDs: [String] = [], sourceSnapshotID: String? = nil, truncated: Bool = false, nextCursor: String? = nil, errorCode: ToolErrorCode? = nil, retryable: Bool = false) {
        self.callID = callID
        self.status = status
        self.data = data
        self.evidenceIDs = evidenceIDs
        self.sourceSnapshotID = sourceSnapshotID
        self.truncated = truncated
        self.nextCursor = nextCursor
        self.errorCode = errorCode
        self.retryable = retryable
    }

    public static func failure(callID: String, code: ToolErrorCode, message: String, retryable: Bool = false) -> ToolResultEnvelope {
        ToolResultEnvelope(callID: callID, status: .error, data: message, errorCode: code, retryable: retryable)
    }

    public func modelContent() -> String {
        let object: [String: Any] = [
            "callID": callID,
            "status": status.rawValue,
            "data": data,
            "evidenceIDs": evidenceIDs,
            "truncated": truncated,
            "errorCode": errorCode?.rawValue ?? NSNull(),
            "retryable": retryable,
            "sourceSnapshotID": sourceSnapshotID ?? NSNull(),
            "nextCursor": nextCursor ?? NSNull()
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return data }
        return text
    }
}

public protocol GopilotTool: Sendable {
    var schema: ToolSchema { get }
    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope
}

public struct ToolRegistry: Sendable {
    private let tools: [String: GopilotTool]
    private let order: [String]

    public init(_ list: [GopilotTool] = []) {
        var map: [String: GopilotTool] = [:]
        var names: [String] = []
        for tool in list where map[tool.schema.name] == nil {
            map[tool.schema.name] = tool
            names.append(tool.schema.name)
        }
        tools = map
        order = names
    }

    public var schemas: [ToolSchema] { order.compactMap { tools[$0]?.schema } }

    public func dispatch(_ call: ToolCall) async -> ToolResultEnvelope {
        guard let tool = tools[call.name] else {
            return .failure(callID: call.id, code: .notFound, message: "Unknown tool: \(call.name)")
        }
        guard Self.isJSONObject(call.argumentsJSON) else {
            return .failure(callID: call.id, code: .invalidArguments, message: "Arguments must be a JSON object.")
        }
        do {
            return try await tool.execute(callID: call.id, argumentsJSON: call.argumentsJSON)
        } catch is CancellationError {
            return .failure(callID: call.id, code: .cancelled, message: "Cancelled.")
        } catch {
            return .failure(callID: call.id, code: .unavailable, message: "Tool failed: \(error.localizedDescription)", retryable: true)
        }
    }

    static func isJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        return value is [String: Any]
    }
}
