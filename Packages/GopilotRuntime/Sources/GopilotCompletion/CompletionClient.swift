import Foundation
import GopilotProvider
import GopilotRuntime

public struct CompletionEndpoint: Sendable, Equatable {
    public var chatCompletionsURL: URL
    public var apiKey: String?
    public var authHeaderName: String?
    public var options: CompletionRequestOptions

    public init(chatCompletionsURL: URL, apiKey: String?, authHeaderName: String? = nil, options: CompletionRequestOptions) {
        self.chatCompletionsURL = chatCompletionsURL
        self.apiKey = apiKey
        self.authHeaderName = authHeaderName
        self.options = options
    }

    public init(configuration: ProviderConfiguration, apiKey: String?, dialect: CompletionDialect, fimTemplate: FIMTemplate = .suffixParameter, stream: Bool = true) throws {
        let url: URL
        do {
            url = try configuration.chatCompletionsURL()
        } catch {
            throw CompletionFailure.invalidConfiguration
        }
        self.init(
            chatCompletionsURL: url,
            apiKey: apiKey,
            authHeaderName: configuration.authHeaderName,
            options: CompletionRequestOptions(
                model: configuration.modelID,
                dialect: dialect,
                maxTokensParameter: configuration.maxTokensParameter,
                stream: stream,
                fimTemplate: fimTemplate
            )
        )
    }

    public var url: URL {
        CompletionEncoder.endpointURL(chatCompletionsURL: chatCompletionsURL, dialect: options.dialect)
    }

    public var cacheScope: String {
        "\(url.absoluteString)|\(options.model)|\(options.dialect.rawValue)|\(options.fimTemplate.rawValue)"
    }
}

public struct CompletionResponse: Sendable, Equatable {
    public var rawText: String
    public var stoppedEarly: Bool
    public var firstChunkSeconds: TimeInterval?
    public var totalSeconds: TimeInterval
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var usedNativeContent = false
}

public final class CompletionClient: @unchecked Sendable {
    public static let defaultTimeoutSeconds: TimeInterval = 3
    static let errorBodyLimit = 4_096

    private let transport: HTTPTransport
    private let userAgent: String
    private let timeoutSeconds: TimeInterval

    public init(transport: HTTPTransport, userAgent: String, timeoutSeconds: TimeInterval = CompletionClient.defaultTimeoutSeconds) {
        self.transport = transport
        self.userAgent = userAgent
        self.timeoutSeconds = timeoutSeconds
    }

    public func makeRequest(context: CompletionContext, endpoint: CompletionEndpoint) throws -> HTTPRequest {
        let body: Data
        do {
            body = try CompletionEncoder.encode(context, options: endpoint.options)
        } catch {
            throw CompletionFailure.invalidConfiguration
        }
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": endpoint.options.stream ? "text/event-stream" : "application/json",
            "User-Agent": userAgent
        ]
        var sensitive: Set<String> = ["authorization"]
        if let key = endpoint.apiKey, !key.isEmpty {
            if let name = endpoint.authHeaderName, !name.isEmpty {
                headers[name] = key
                sensitive.insert(name.lowercased())
            } else {
                headers["Authorization"] = "Bearer \(key)"
            }
        }
        return HTTPRequest(url: endpoint.url, headers: headers, body: body, sensitiveHeaderNames: sensitive, timeout: timeoutSeconds)
    }

    public func complete(
        context: CompletionContext,
        endpoint: CompletionEndpoint,
        shouldStop: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async throws -> CompletionResponse {
        let request = try makeRequest(context: context, endpoint: endpoint)
        let transport = self.transport
        let timeout = timeoutSeconds
        let started = Date()
        let secret = endpoint.apiKey
        let dialect = endpoint.options.dialect
        let streaming = endpoint.options.stream
        do {
            return try await withThrowingTaskGroup(of: CompletionResponse?.self) { group in
                group.addTask {
                    try await Self.perform(request, transport: transport, dialect: dialect, streaming: streaming, secret: secret, started: started, shouldStop: shouldStop)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let response = first else {
                    throw CompletionFailure.timeout
                }
                return response
            }
        } catch let failure as CompletionFailure {
            throw failure
        } catch ProviderError.consentRequired(let host) {
            throw CompletionFailure.consentRequired(host: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            if error.code == .timedOut { throw CompletionFailure.timeout }
            throw CompletionFailure.offline
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CompletionFailure.invalidResponse(Self.redact(String(describing: error), secret: secret))
        }
    }

    private static func perform(
        _ request: HTTPRequest,
        transport: HTTPTransport,
        dialect: CompletionDialect,
        streaming: Bool,
        secret: String?,
        started: Date,
        shouldStop: @escaping @Sendable (String) -> Bool
    ) async throws -> CompletionResponse {
        let response = try await transport.send(request)
        let status = response.head.status
        guard (200..<300).contains(status) else {
            var body = Data()
            for try await chunk in response.body {
                body.append(chunk)
                if body.count > errorBodyLimit { break }
            }
            throw failure(status: status, headers: response.head.headers)
        }
        var decoder = CompletionStreamDecoder(dialect: dialect)
        var text = ""
        var firstChunk: TimeInterval?
        var stoppedEarly = false
        var raw = Data()
        let contentType = response.head.headers["content-type"]?.lowercased() ?? ""
        let treatAsStream = streaming || contentType.contains("text/event-stream")
        for try await chunk in response.body {
            try Task.checkCancellation()
            if treatAsStream {
                let deltas = try decoder.feed(chunk)
                if !deltas.isEmpty, firstChunk == nil {
                    firstChunk = Date().timeIntervalSince(started)
                }
                text += deltas.joined()
                if decoder.isDone { break }
                if shouldStop(text) {
                    stoppedEarly = true
                    break
                }
            } else {
                raw.append(chunk)
                if raw.count > 1 << 20 { throw CompletionFailure.invalidResponse("The response was too large.") }
            }
        }
        if treatAsStream {
            if !stoppedEarly && !decoder.isDone {
                text += try decoder.finish().joined()
            }
        } else {
            firstChunk = Date().timeIntervalSince(started)
            let decoded = try CompletionStreamDecoder.decodeDetailed(raw, dialect: dialect)
            text = decoded.text
            decoder.usage = decoded.usage
            decoder.usedNativeContent = decoded.usedNativeContent
        }
        return CompletionResponse(
            rawText: text,
            stoppedEarly: stoppedEarly,
            firstChunkSeconds: firstChunk,
            totalSeconds: Date().timeIntervalSince(started),
            promptTokens: decoder.usage?.promptTokens,
            completionTokens: decoder.usage?.completionTokens,
            usedNativeContent: decoder.usedNativeContent
        )
    }

    static func failure(status: Int, headers: [String: String]) -> CompletionFailure {
        switch status {
        case 401, 403: return .unauthorized(status: status)
        case 404: return .endpointNotFound
        case 429:
            let retry = headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfterSeconds: retry)
        default: return .server(status: status)
        }
    }

    static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }
}

public struct CompletionStreamDecoder: Sendable {
    public let dialect: CompletionDialect
    private var parser = SSEParser()
    public private(set) var isDone = false
    public var usage: CompletionUsage?
    public var usedNativeContent = false

    public init(dialect: CompletionDialect) {
        self.dialect = dialect
    }

    public mutating func feed(_ chunk: Data) throws -> [String] {
        try parser.feed(chunk).compactMap { try handle($0) }
    }

    public mutating func finish() throws -> [String] {
        try parser.finish().compactMap { try handle($0) }
    }

    private mutating func handle(_ event: SSEEvent) throws -> String? {
        if event.isDone {
            isDone = true
            return nil
        }
        guard let data = event.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] {
            throw CompletionFailure.invalidResponse(Self.errorMessage(error))
        }
        if let parsed = CompletionUsage(object["usage"]) { usage = parsed }
        let extracted = Self.extract(object)
        if extracted.native { usedNativeContent = true }
        return extracted.text
    }

    public static func decodeBody(_ data: Data, dialect: CompletionDialect) throws -> String {
        try decodeDetailed(data, dialect: dialect).text
    }

    public static func decodeDetailed(_ data: Data, dialect: CompletionDialect) throws -> (text: String, usage: CompletionUsage?, usedNativeContent: Bool) {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            var decoder = CompletionStreamDecoder(dialect: dialect)
            var text = try decoder.feed(Data((trimmed + "\n\n").utf8)).joined()
            if !decoder.isDone { text += try decoder.finish().joined() }
            return (text, decoder.usage, decoder.usedNativeContent)
        }
        var parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        if parsed == nil, let firstLine = trimmed.split(separator: "\n").first {
            parsed = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        }
        guard let object = parsed else {
            throw CompletionFailure.invalidResponse("The provider did not return JSON.")
        }
        if let error = object["error"] {
            throw CompletionFailure.invalidResponse(errorMessage(error))
        }
        let extracted = extract(object)
        return (extracted.text ?? "", CompletionUsage(object["usage"]), extracted.native)
    }

    static func extract(_ object: [String: Any]) -> (text: String?, native: Bool) {
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                return (content, false)
            }
            if let message = choice["message"] as? [String: Any], let content = message["content"] as? String {
                return (content, false)
            }
            if let text = choice["text"] as? String {
                return (text, false)
            }
        }
        if let content = object["content"] as? String {
            return (content, true)
        }
        return (nil, false)
    }

    static func errorMessage(_ value: Any) -> String {
        if let dictionary = value as? [String: Any], let message = dictionary["message"] as? String {
            return String(message.prefix(200))
        }
        if let message = value as? String { return String(message.prefix(200)) }
        return "The provider returned an error."
    }
}

public struct CompletionUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(promptTokens: Int?, completionTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    init?(_ value: Any?) {
        guard let dictionary = value as? [String: Any] else { return nil }
        let prompt = (dictionary["prompt_tokens"] as? NSNumber)?.intValue
        let completion = (dictionary["completion_tokens"] as? NSNumber)?.intValue
        guard prompt != nil || completion != nil else { return nil }
        self.init(promptTokens: prompt, completionTokens: completion)
    }
}
