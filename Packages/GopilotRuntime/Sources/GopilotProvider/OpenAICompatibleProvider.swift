import Foundation
import GopilotRuntime

public struct RetryPolicy: Sendable, Equatable {
    public var maxRetries: Int
    public var baseDelaySeconds: TimeInterval
    public var maxDelaySeconds: TimeInterval
    public var maxReportedRetryAfterSeconds: Int

    public init(
        maxRetries: Int = 2,
        baseDelaySeconds: TimeInterval = 0.5,
        maxDelaySeconds: TimeInterval = 8,
        maxReportedRetryAfterSeconds: Int = 3600
    ) {
        self.maxRetries = maxRetries
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.maxReportedRetryAfterSeconds = maxReportedRetryAfterSeconds
    }
}

private actor ProviderObservations {
    private(set) var unsupported: Set<OptionalRequestField> = []
    private(set) var maxTokensParameter: MaxTokensParameter?
    private(set) var lastRequestID: String?

    func markUnsupported(_ field: OptionalRequestField) {
        unsupported.insert(field)
    }

    func overrideMaxTokensParameter(_ parameter: MaxTokensParameter) {
        maxTokensParameter = parameter
    }

    func record(requestID: String?) {
        if let requestID { lastRequestID = requestID }
    }
}

private struct UnsupportedFieldRejection: Error {
    let field: OptionalRequestField
}

private final class OutputTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var hasOutput: Bool { lock.withLock { value } }
    func markOutput() { lock.withLock { value = true } }
}

private final class ChunkReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<Data, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

public final class OpenAICompatibleProvider: ProviderAdapter, @unchecked Sendable {
    public let configuration: ProviderConfiguration

    private let credentials: CredentialStore
    private let transport: HTTPTransport
    private let profile: CapabilityProfile
    private let streamingOverride: Bool?
    private let retryPolicy: RetryPolicy
    private let clock: ProviderClock
    private let jitter: @Sendable () -> Double
    private let limits: SSELimits
    private let observations = ProviderObservations()
    private static let errorBodyLimit = 32 * 1024

    public init(
        configuration: ProviderConfiguration,
        credentials: CredentialStore,
        transport: HTTPTransport,
        profile: CapabilityProfile = CapabilityProfile(),
        streamingOverride: Bool? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: ProviderClock = SystemProviderClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        limits: SSELimits = SSELimits()
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.profile = profile
        self.streamingOverride = streamingOverride
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.jitter = jitter
        self.limits = limits
    }

    public func lastRequestID() async -> String? {
        await observations.lastRequestID
    }

    public func observedUnsupportedCapabilities() async -> Set<ProviderCapability> {
        var result: Set<ProviderCapability> = []
        for field in await observations.unsupported {
            switch field {
            case .streamOptions: result.insert(.streamUsage)
            case .parallelToolCalls: result.insert(.parallelToolCalls)
            case .strict: result.insert(.strictSchema)
            case .maxTokens: result.insert(.maxTokensParameter)
            case .reasoningEffort: break
            }
        }
        return result
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.execute(request, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func usesStreaming(for request: ProviderRequest) -> Bool {
        if let streamingOverride { return streamingOverride }
        let hash = configuration.capabilityHash(routeOverride: request.routeOverride)
        return configuration.declaredCapabilities.contains(.streaming) && profile.state(of: .streaming, configHash: hash) != .unsupported
    }

    private func verifiedFields(for request: ProviderRequest) -> Set<OptionalRequestField> {
        let hash = configuration.capabilityHash(routeOverride: request.routeOverride)
        var fields: Set<OptionalRequestField> = []
        if profile.isVerified(.streamUsage, configHash: hash) { fields.insert(.streamOptions) }
        if profile.isVerified(.parallelToolCalls, configHash: hash) { fields.insert(.parallelToolCalls) }
        if profile.isVerified(.strictSchema, configHash: hash) { fields.insert(.strict) }
        return fields
    }

    private func sanitized(_ error: Error) -> Error {
        var secrets: [String] = []
        if let reference = configuration.credentialReference, let secret = try? credentials.read(reference) {
            secrets.append(secret)
        }
        let redactor = Redactor(secrets: secrets)
        switch error {
        case ProviderError.malformedResponse(let message):
            return ProviderError.malformedResponse(redactor.redact(message))
        case ProviderError.unsupportedParameter(let field, let message):
            return ProviderError.unsupportedParameter(field: field, message: redactor.redact(message))
        case ProviderError.requestRejected(let status, let reason):
            return ProviderError.requestRejected(status: status, reason: reason.map { redactor.redact($0) })
        default:
            return error
        }
    }

    private func execute(_ request: ProviderRequest, _ continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async {
        let output = OutputTracker()
        let started = clock.now()
        do {
            try await withTimeout(seconds: streamCeilingSeconds) { [self] in
                try await self.attemptLoop(request, started: started, continuation: continuation, output: output)
            }
            continuation.finish()
        } catch is TimeoutExpired {
            continuation.finish(throwing: timeoutError(output: output))
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: sanitized(error))
        }
    }

    private var streamCeilingSeconds: TimeInterval {
        configuration.timeouts.streamCeilingSeconds(maxOutputTokens: configuration.outputTokenLimit)
    }

    private func attemptLoop(
        _ request: ProviderRequest,
        started: Date,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation,
        output: OutputTracker
    ) async throws {
        var retries = 0
        var rejected: Set<OptionalRequestField> = []
        while true {
            do {
                try await performAttempt(request, rejected: rejected, continuation: continuation, output: output)
                return
            } catch let rejection as UnsupportedFieldRejection {
                guard !output.hasOutput, !rejected.contains(rejection.field) else {
                    throw ProviderError.malformedResponse("The provider rejected the request.")
                }
                rejected.insert(rejection.field)
            } catch let error as ProviderError {
                guard !output.hasOutput, retries < retryPolicy.maxRetries, let delay = retryDelay(for: error, retries: retries) else {
                    throw error
                }
                let elapsed = clock.now().timeIntervalSince(started)
                guard delay < streamCeilingSeconds - elapsed else {
                    throw error
                }
                try await clock.sleep(seconds: delay)
                retries += 1
            }
        }
    }

    private func retryDelay(for error: ProviderError, retries: Int) -> TimeInterval? {
        switch error {
        case .rateLimited(let retryAfter):
            if let retryAfter { return TimeInterval(retryAfter) }
            return backoff(retries)
        case .server, .offline:
            return backoff(retries)
        case .unauthorized, .malformedResponse, .unsupportedParameter, .contextLengthExceeded, .requestRejected, .consentRequired:
            return nil
        }
    }

    private func backoff(_ retries: Int) -> TimeInterval {
        let exponential = min(retryPolicy.maxDelaySeconds, retryPolicy.baseDelaySeconds * pow(2, Double(retries)))
        let factor = 0.5 + 0.5 * min(max(jitter(), 0), 1)
        return exponential * factor
    }

    private func timeoutError(output: OutputTracker) -> ProviderError {
        output.hasOutput
            ? .malformedResponse("The provider stopped responding before the answer was complete.")
            : .offline
    }

    private func performAttempt(
        _ request: ProviderRequest,
        rejected: Set<OptionalRequestField>,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation,
        output: OutputTracker
    ) async throws {
        let streaming = usesStreaming(for: request)
        let overrideName = await observations.maxTokensParameter
        let observed = await observations.unsupported
        let allowed = verifiedFields(for: request).subtracting(rejected).subtracting(observed)
        let maxTokensName = overrideName ?? configuration.maxTokensParameter

        let encoded = try ChatCompletionsRequestEncoder.encode(
            configuration: configuration,
            request: request,
            streaming: streaming,
            allowed: allowed,
            maxTokensParameter: maxTokensName
        )
        let httpRequest = try makeHTTPRequest(body: encoded.body, streaming: streaming)
        let response = try await send(httpRequest, output: output)
        await observations.record(requestID: response.head.headers["x-request-id"])

        let status = response.head.status
        switch status {
        case 200..<300:
            try await consumeSuccess(response, streaming: streaming, continuation: continuation, output: output)
        case 401, 403:
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfterSeconds: parseRetryAfter(response.head.headers["retry-after"]))
        case 500...599:
            throw ProviderError.server(status: status)
        case 413:
            throw ProviderError.contextLengthExceeded
        case 400:
            let body = try await collectBody(response.body, limit: Self.errorBodyLimit, output: output)
            if Self.isContextLengthRejection(in: body) {
                throw ProviderError.contextLengthExceeded
            }
            if encoded.sentFields.contains(.reasoningEffort), isReasoningEffortRejection(in: body) {
                throw ProviderError.unsupportedParameter(
                    field: "reasoning_effort",
                    message: "This model route does not accept the requested reasoning effort. Retry with Default."
                )
            }
            if let field = await unsupportedField(in: body, sent: encoded.sentFields, maxTokensName: encoded.maxTokensParameter) {
                if field == .maxTokens {
                    await observations.overrideMaxTokensParameter(encoded.maxTokensParameter.alternate)
                } else {
                    await observations.markUnsupported(field)
                }
                throw UnsupportedFieldRejection(field: field)
            }
            throw rejectedRequestError(status: status, head: response.head, body: body)
        default:
            let body = try? await collectBody(response.body, limit: Self.errorBodyLimit, output: output)
            throw rejectedRequestError(status: status, head: response.head, body: body)
        }
    }

    private func rejectedRequestError(status: Int, head: HTTPResponseHead, body: Data?) -> ProviderError {
        if (head.headers["content-type"] ?? "").lowercased().contains("html") {
            return .malformedResponse("The endpoint returned a web page instead of an API response (status \(status)). Check the base URL.")
        }
        return .requestRejected(status: status, reason: body.flatMap(Self.rejectionReason(in:)))
    }

    static func rejectionReason(in body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = object?["error"]
        let candidates: [Any?] = [
            (error as? [String: Any])?["message"],
            error,
            object?["message"],
            object?["detail"]
        ]
        guard let raw = candidates.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > rejectionReasonLimit ? String(collapsed.prefix(rejectionReasonLimit)) + "…" : collapsed
    }

    static let rejectionReasonLimit = 300

    private func makeHTTPRequest(body: Data, streaming: Bool) throws -> HTTPRequest {
        let url: URL
        do {
            url = try configuration.chatCompletionsURL()
        } catch {
            throw ProviderError.malformedResponse("The provider endpoint is not valid.")
        }
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": streaming ? "text/event-stream" : "application/json",
            "User-Agent": "GoLens-Gopilot"
        ]
        var sensitive: Set<String> = ["authorization"]
        if let reference = configuration.credentialReference {
            let secret: String
            do {
                secret = try credentials.read(reference)
            } catch {
                throw ProviderError.unauthorized
            }
            if let name = configuration.authHeaderName, !name.isEmpty {
                headers[name] = secret
                sensitive.insert(name.lowercased())
            } else {
                headers["Authorization"] = "Bearer \(secret)"
            }
        }
        return HTTPRequest(
            url: url,
            headers: headers,
            body: body,
            sensitiveHeaderNames: sensitive,
            timeout: configuration.timeouts.requestSeconds
        )
    }

    private func send(_ request: HTTPRequest, output: OutputTracker) async throws -> HTTPResponse {
        let transport = self.transport
        do {
            return try await withTimeout(seconds: configuration.timeouts.idleSeconds) {
                try await transport.send(request)
            }
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is TimeoutExpired {
            throw timeoutError(output: output)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.offline
        }
    }

    private func nextChunk(_ reader: ChunkReader, output: OutputTracker) async throws -> Data? {
        do {
            return try await withTimeout(seconds: configuration.timeouts.idleSeconds) {
                try await reader.next()
            }
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is TimeoutExpired {
            throw timeoutError(output: output)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.offline
        }
    }

    private func collectBody(_ stream: AsyncThrowingStream<Data, Error>, limit: Int, output: OutputTracker) async throws -> Data {
        let reader = ChunkReader(stream)
        var body = Data()
        while let chunk = try await nextChunk(reader, output: output) {
            body.append(chunk)
            if body.count > limit {
                throw ProviderError.malformedResponse("The response exceeded the \(limit / 1024) KiB limit.")
            }
        }
        try Task.checkCancellation()
        return body
    }

    private func consumeSuccess(
        _ response: HTTPResponse,
        streaming: Bool,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation,
        output: OutputTracker
    ) async throws {
        let contentType = (response.head.headers["content-type"] ?? "").lowercased()
        if contentType.contains("html") {
            throw ProviderError.malformedResponse("The endpoint returned a web page instead of an API response. Check the base URL.")
        }
        func emit(_ events: [ProviderEvent]) throws {
            for event in events {
                output.markOutput()
                if case .terminated = continuation.yield(event) {
                    throw CancellationError()
                }
            }
        }

        if streaming && !contentType.contains("application/json") {
            var parser = SSEParser(limits: limits)
            var assembler = ChatCompletionsStreamAssembler(limits: limits)
            let reader = ChunkReader(response.body)
            var finished = false
            readLoop: while let chunk = try await nextChunk(reader, output: output) {
                for sseEvent in try parser.feed(chunk) {
                    if sseEvent.isDone {
                        finished = true
                        break readLoop
                    }
                    try emit(try assembler.consume(sseEvent.data))
                }
            }
            if !finished {
                for sseEvent in try parser.finish() where !sseEvent.isDone {
                    try emit(try assembler.consume(sseEvent.data))
                }
            }
            try Task.checkCancellation()
            try emit(assembler.end())
        } else {
            let body = try await collectBody(response.body, limit: limits.responseBytes, output: output)
            try emit(try ChatCompletionsResponseDecoder.decode(body, limits: limits))
        }
    }

    private func parseRetryAfter(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let bound = retryPolicy.maxReportedRetryAfterSeconds
        if let seconds = Int(value) {
            return min(max(seconds, 0), bound)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let delta = Int(date.timeIntervalSince(clock.now()).rounded(.up))
        return min(max(delta, 0), bound)
    }

    static func isContextLengthRejection(in body: Data) -> Bool {
        let raw = String(decoding: body, as: UTF8.self).lowercased()
        let markers = [
            "context_length_exceeded",
            "maximum context length",
            "context length",
            "context window",
            "prompt is too long",
            "input is too long",
            "too many tokens",
            "reduce the length of the messages"
        ]
        return markers.contains { raw.contains($0) }
    }

    private func isReasoningEffortRejection(in body: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                let text = [error["param"], error["message"], error["code"], error["type"]]
                    .compactMap { $0 as? String }
                    .joined(separator: " ")
                    .lowercased()
                if text.contains("reasoning_effort") || text.contains("reasoning") {
                    return true
                }
            } else if let errorString = object["error"] as? String {
                let lower = errorString.lowercased()
                if lower.contains("reasoning_effort") || lower.contains("reasoning") {
                    return true
                }
            }
        }
        let raw = String(decoding: body, as: UTF8.self).lowercased()
        return raw.contains("reasoning_effort") || raw.contains("reasoning")
    }

    private func unsupportedField(
        in body: Data,
        sent: Set<OptionalRequestField>,
        maxTokensName: MaxTokensParameter
    ) async -> OptionalRequestField? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let error = object["error"] as? [String: Any]
        let text = [error?["param"], error?["message"], error?["code"]]
            .compactMap { $0 as? String }
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return nil }
        let candidates: [(OptionalRequestField, String)] = [
            (.streamOptions, "stream_options"),
            (.parallelToolCalls, "parallel_tool_calls"),
            (.strict, "strict"),
            (.maxTokens, maxTokensName.rawValue)
        ]
        return candidates.first { sent.contains($0.0) && text.contains($0.1) }?.0
    }
}
