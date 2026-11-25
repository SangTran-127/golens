import Foundation
import GopilotRuntime

public struct ExportFile: Sendable, Equatable {
    public let name: String
    public let data: Data
    public let conversationID: UUID?
}

public struct ExportPreview: Sendable, Equatable {
    public let files: [ExportFile]
    public let redactedStringCount: Int

    public var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
}

final class Redaction {
    private let redactor: @Sendable (String) -> String
    private(set) var changedCount = 0

    init(_ redactor: @escaping @Sendable (String) -> String) {
        self.redactor = redactor
    }

    func string(_ value: String) -> String {
        let result = redactor(value)
        if result != value { changedCount += 1 }
        return result
    }

    func conversation(_ source: Conversation) -> Conversation {
        var copy = source
        copy.title = string(source.title)
        copy.turns = source.turns.map(turn)
        return copy
    }

    func note(_ source: MemoryNote) -> MemoryNote {
        var copy = source
        copy.content = string(source.content)
        return copy
    }

    private func turn(_ source: Turn) -> Turn {
        var copy = source
        copy.userPrompt = string(source.userPrompt)
        copy.messages = source.messages.map { message in
            ModelMessage(
                role: message.role,
                content: string(message.content),
                toolCalls: message.toolCalls.map { ToolCall(id: $0.id, name: $0.name, argumentsJSON: string($0.argumentsJSON)) },
                toolCallID: message.toolCallID
            )
        }
        return copy
    }
}
