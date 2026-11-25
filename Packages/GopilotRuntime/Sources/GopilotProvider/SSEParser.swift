import Foundation
import GopilotRuntime

public struct SSEEvent: Sendable, Equatable {
    public let name: String?
    public let data: String

    public init(name: String?, data: String) {
        self.name = name
        self.data = data
    }

    public var isDone: Bool { data == "[DONE]" }
}

public struct SSELimits: Sendable, Equatable {
    public var eventBytes: Int
    public var responseBytes: Int
    public var toolArgumentBytes: Int

    public init(eventBytes: Int = 1 << 20, responseBytes: Int = 4 << 20, toolArgumentBytes: Int = ToolArgumentLimits.maxPatchArgumentBytes) {
        self.eventBytes = eventBytes
        self.responseBytes = responseBytes
        self.toolArgumentBytes = toolArgumentBytes
    }
}

public struct SSEParser: Sendable {
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private let limits: SSELimits
    private var buffer: [UInt8] = []
    private var dataBytes: [UInt8] = []
    private var hasData = false
    private var eventName: String?
    private var totalBytes = 0
    private var atStreamStart = true

    public init(limits: SSELimits = SSELimits()) {
        self.limits = limits
    }

    public mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        totalBytes += chunk.count
        guard totalBytes <= limits.responseBytes else {
            throw ProviderError.malformedResponse("The response exceeded the \(limits.responseBytes / (1 << 20)) MiB limit.")
        }
        buffer.append(contentsOf: chunk)
        return try drain(final: false)
    }

    public mutating func finish() throws -> [SSEEvent] {
        var events = try drain(final: true)
        buffer.removeAll()
        if let pending = try dispatch() {
            events.append(pending)
        }
        return events
    }

    private mutating func drain(final: Bool) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        var lineStart = 0
        var cursor = 0
        while cursor < buffer.count {
            let byte = buffer[cursor]
            guard byte == Self.lineFeed || byte == Self.carriageReturn else {
                cursor += 1
                continue
            }
            var next = cursor + 1
            if byte == Self.carriageReturn {
                if next >= buffer.count && !final { break }
                if next < buffer.count && buffer[next] == Self.lineFeed { next += 1 }
            }
            if let event = try processLine(buffer[lineStart..<cursor]) {
                events.append(event)
            }
            lineStart = next
            cursor = next
        }
        if lineStart > 0 {
            buffer.removeSubrange(0..<lineStart)
        }
        guard buffer.count <= limits.eventBytes else {
            throw eventTooLarge()
        }
        return events
    }

    private mutating func processLine(_ rawLine: ArraySlice<UInt8>) throws -> SSEEvent? {
        var line = rawLine
        if atStreamStart {
            atStreamStart = false
            if line.starts(with: Self.byteOrderMark) {
                line = line.dropFirst(Self.byteOrderMark.count)
            }
        }
        if line.isEmpty {
            return try dispatch()
        }
        if line.first == Self.colon {
            return nil
        }
        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let separator = line.firstIndex(of: Self.colon) {
            field = line[line.startIndex..<separator]
            value = line[(separator + 1)...]
            if value.first == Self.space {
                value = value.dropFirst()
            }
        } else {
            field = line
            value = []
        }
        switch String(decoding: field, as: UTF8.self) {
        case "data":
            if dataBytes.count + value.count + 1 > limits.eventBytes {
                throw eventTooLarge()
            }
            if hasData {
                dataBytes.append(Self.lineFeed)
            }
            dataBytes.append(contentsOf: value)
            hasData = true
        case "event":
            eventName = String(decoding: value, as: UTF8.self)
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() throws -> SSEEvent? {
        defer {
            dataBytes.removeAll(keepingCapacity: true)
            hasData = false
            eventName = nil
        }
        guard hasData else { return nil }
        guard let text = String(bytes: dataBytes, encoding: .utf8) else {
            throw ProviderError.malformedResponse("The stream contained invalid UTF-8.")
        }
        return SSEEvent(name: eventName, data: text)
    }

    private func eventTooLarge() -> ProviderError {
        ProviderError.malformedResponse("A stream event exceeded the \(limits.eventBytes / (1 << 20)) MiB limit.")
    }
}
