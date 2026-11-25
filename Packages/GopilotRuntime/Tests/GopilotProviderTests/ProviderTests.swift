import Foundation
import Testing
import GopilotRuntime
@testable import GopilotProvider

private func bodyObject(_ request: HTTPRequest) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func assertNoKey(_ error: Error?, _ comment: Comment? = nil) {
    guard let error else { return }
    for text in ["\(error)", String(reflecting: error), error.localizedDescription] {
        #expect(!text.contains(canaryKey), comment)
    }
}

private func assertNoKey(_ events: [ProviderEvent]) {
    for event in events {
        #expect(!"\(event)".contains(canaryKey))
    }
}

private func fullStream(_ fixture: String = simpleTextStream) -> MockResponse {
    .sse(fixture)
}

@Suite("OpenAI-compatible provider")
struct ProviderTests {
    @Test func streamsTextAndSendsExpectedRequest() async throws {
        let transport = MockTransport([fullStream()])
        let provider = makeProvider(transport: transport)
        let result = await collect(provider.stream(userRequest))

        #expect(result.error == nil)
        #expect(result.events == [.textDelta("Hi"), .textDelta(" there"), .finish(.stop)])

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.headerValue("Authorization") == "Bearer \(canaryKey)")
        #expect(request.headerValue("Accept") == "text/event-stream")
        let body = try bodyObject(request)
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["stream_options"] == nil)
        #expect(body["parallel_tool_calls"] == nil)
        #expect(body["tools"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hello")
    }

    @Test func requestDescriptionNeverContainsTheKey() async throws {
        let transport = MockTransport([fullStream()])
        let provider = makeProvider(transport: transport)
        _ = await collect(provider.stream(userRequest))
        let request = try #require(transport.requests.first)
        #expect(!request.description.contains(canaryKey))
        #expect(!request.debugDescription.contains(canaryKey))
        #expect(!"\(provider.configuration)".contains(canaryKey))
    }

    @Test func toolsAndConversationAreEncodedAndOptionalFieldsOnlyWhenVerified() async throws {
        let configuration = makeConfiguration()
        let hash = configuration.capabilityHash
        let request = ProviderRequest(
            messages: [
                ModelMessage(role: .system, content: "sys"),
                ModelMessage(role: .user, content: "go"),
                ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "call_1", name: "read_canary", argumentsJSON: #"{"name":"alpha"}"#)]),
                ModelMessage(role: .tool, content: #"{"value":"v"}"#, toolCallID: "call_1")
            ],
            tools: [readCanaryTool]
        )

        let plain = MockTransport([fullStream()])
        _ = await collect(makeProvider(transport: plain).stream(request))
        let plainBody = try bodyObject(try #require(plain.requests.first))
        let plainTools = try #require(plainBody["tools"] as? [[String: Any]])
        let plainFunction = try #require(plainTools.first?["function"] as? [String: Any])
        #expect(plainTools.first?["type"] as? String == "function")
        #expect(plainFunction["name"] as? String == "read_canary")
        #expect((plainFunction["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(plainFunction["strict"] == nil)
        #expect(plainBody["parallel_tool_calls"] == nil)
        #expect(plainBody["stream_options"] == nil)

        let messages = try #require(plainBody["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[2]["content"] is NSNull)
        let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call_1")
        #expect((calls.first?["function"] as? [String: Any])?["arguments"] as? String == #"{"name":"alpha"}"#)
        #expect(messages[3]["tool_call_id"] as? String == "call_1")

        var profile = CapabilityProfile()
        let now = Date()
        for capability in [ProviderCapability.streamUsage, .parallelToolCalls, .strictSchema] {
            profile.set(capability, .verified, configHash: hash, at: now)
        }
        let verified = MockTransport([fullStream()])
        _ = await collect(makeProvider(transport: verified, profile: profile).stream(request))
        let verifiedBody = try bodyObject(try #require(verified.requests.first))
        #expect((verifiedBody["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(verifiedBody["parallel_tool_calls"] as? Bool == true)
        let verifiedTools = try #require(verifiedBody["tools"] as? [[String: Any]])
        #expect((verifiedTools.first?["function"] as? [String: Any])?["strict"] as? Bool == true)

        var stale = CapabilityProfile()
        stale.set(.streamUsage, .verified, configHash: "other-host-hash", at: now)
        let staleTransport = MockTransport([fullStream()])
        _ = await collect(makeProvider(transport: staleTransport, profile: stale).stream(request))
        let staleBody = try bodyObject(try #require(staleTransport.requests.first))
        #expect(staleBody["stream_options"] == nil)
    }

    @Test func invalidToolSchemaIsReportedWithoutSendingAnything() async {
        let transport = MockTransport([fullStream()])
        let bad = ProviderRequest(messages: userRequest.messages, tools: [ToolSchema(name: "t", description: "d", parametersJSON: "{nope")])
        let result = await collect(makeProvider(transport: transport).stream(bad))
        #expect(result.error as? ProviderError != nil)
        #expect(transport.requestCount == 0)
    }

    @Test func customSecretHeaderIsUsedInsteadOfBearer() async throws {
        var configuration = makeConfiguration()
        configuration.authHeaderName = "X-Api-Key"
        let transport = MockTransport([fullStream()])
        _ = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        let request = try #require(transport.requests.first)
        #expect(request.headerValue("X-Api-Key") == canaryKey)
        #expect(request.headerValue("Authorization") == nil)
        #expect(request.sensitiveHeaderNames.contains("x-api-key"))
    }

    @Test func missingCredentialIsUnauthorizedWithoutNetworkCall() async {
        let transport = MockTransport([fullStream()])
        let provider = OpenAICompatibleProvider(
            configuration: makeConfiguration(),
            credentials: InMemoryCredentialStore(),
            transport: transport
        )
        let result = await collect(provider.stream(userRequest))
        #expect(result.error as? ProviderError == .unauthorized)
        #expect(transport.requestCount == 0)
    }

    @Test func localEndpointWithoutCredentialSendsNoAuthorization() async throws {
        let configuration = makeConfiguration(baseURL: "http://localhost:1234/v1", reference: nil, local: true)
        let transport = MockTransport([fullStream()])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.error == nil)
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(request.headerValue("Authorization") == nil)
    }

    @Test func insecureEndpointIsRefusedBeforeAnyRequest() async {
        let configuration = makeConfiguration(baseURL: "http://api.example.test/v1")
        let transport = MockTransport([fullStream()])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.error as? ProviderError != nil)
        #expect(transport.requestCount == 0)
    }

    @Test func doneStopsReadingAndReleasesTheConnection() async {
        let transport = MockTransport([.sse(simpleTextStream + textChunk("ignored after done"), then: [.hang])])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.events == [.textDelta("Hi"), .textDelta(" there"), .finish(.stop)])
    }

    @Test func streamWithoutFinishReasonEndsWithoutFinishEvent() async {
        let transport = MockTransport([.sse(textChunk("cut off"))])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error == nil)
        #expect(result.events == [.textDelta("cut off")])
    }

    @Test func invalidToolArgumentsSurfaceAsRecoverableErrorWithoutToolCall() async {
        let broken = sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{\"a\":"}}]},"finish_reason":"tool_calls"}]}"#)
        let transport = MockTransport([.sse(broken)])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        guard case .malformedResponse = result.error as? ProviderError else {
            Issue.record("expected malformedResponse, got \(String(describing: result.error))")
            return
        }
        #expect(result.events.isEmpty)
    }

    @Test func everyByteSplitThroughTheFullProviderPipeline() async throws {
        let fixture = textChunk("Xin chào đường 𠮷")
            + sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_canary","arguments":"{\"name\":\"Việt"}}]}}]}"#)
            + sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" Nam\"}"}}]},"finish_reason":"tool_calls"}]}"#)
            + sseChunk(#"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#)
            + "data: [DONE]\n\n"
        let expected: [ProviderEvent] = [
            .textDelta("Xin chào đường 𠮷"),
            .toolCall(ToolCall(id: "call_1", name: "read_canary", argumentsJSON: #"{"name":"Việt Nam"}"#)),
            .usage(TokenUsage(inputTokens: 1, outputTokens: 2)),
            .finish(.toolCalls)
        ]
        let bytes = Array(fixture.utf8)
        for split in stride(from: 0, through: bytes.count, by: 1) {
            let chunks = [Data(bytes[0..<split]), Data(bytes[split...])]
            let transport = MockTransport([.sse(chunks: chunks)])
            let result = await collect(makeProvider(transport: transport).stream(userRequest))
            #expect(result.error == nil, "split \(split)")
            #expect(result.events == expected, "split \(split)")
        }
    }

    @Test func nonStreamingRequestDecodesFullBody() async throws {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"full"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#
        let transport = MockTransport([.json(body)])
        let result = await collect(makeProvider(transport: transport, streaming: false).stream(userRequest))
        #expect(result.events == [.textDelta("full"), .usage(TokenUsage(inputTokens: 2, outputTokens: 1)), .finish(.stop)])
        let request = try #require(transport.requests.first)
        #expect(try bodyObject(request)["stream"] as? Bool == false)
        #expect(try bodyObject(request)["stream_options"] == nil)
        #expect(request.headerValue("Accept") == "application/json")
    }

    @Test func jsonBodyReturnedForStreamingRequestIsStillDecoded() async {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"plain"},"finish_reason":"stop"}]}"#
        let transport = MockTransport([.json(body)])
        let result = await collect(makeProvider(transport: transport, streaming: true).stream(userRequest))
        #expect(result.events == [.textDelta("plain"), .finish(.stop)])
    }

    @Test func streamingDisabledWhenProfileSaysUnsupported() async throws {
        let configuration = makeConfiguration()
        var profile = CapabilityProfile()
        profile.set(.streaming, .unsupported, configHash: configuration.capabilityHash, at: Date())
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"x"},"finish_reason":"stop"}]}"#
        let transport = MockTransport([.json(body)])
        _ = await collect(makeProvider(transport: transport, configuration: configuration, profile: profile).stream(userRequest))
        let sentBody = try bodyObject(try #require(transport.requests.first))
        #expect(sentBody["stream"] as? Bool == false)
    }

    @Test func requestIDIsRecorded() async {
        var response = fullStream()
        response.headers["X-Request-Id"] = "req_123"
        let provider = makeProvider(transport: MockTransport([response]))
        _ = await collect(provider.stream(userRequest))
        #expect(await provider.lastRequestID() == "req_123")
    }

    @Test(arguments: [401, 403])
    func authFailuresAreNeverRetriedAndNeverLeakTheKeyOrBody(status: Int) async {
        let transport = MockTransport([.json(#"{"error":{"message":"bad key \#(canaryKey)"}}"#, status: status), fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error as? ProviderError == .unauthorized)
        #expect(transport.requestCount == 1)
        assertNoKey(result.error)
        assertNoKey(result.events)
    }

    @Test func rateLimitIsRetriedTwiceHonouringRetryAfter() async {
        let limited = MockResponse.json("{}", status: 429, headers: ["Retry-After": "2"])
        let transport = MockTransport([limited, limited, limited, fullStream()])
        let clock = ManualClock()
        let result = await collect(makeProvider(transport: transport, clock: clock).stream(userRequest))
        #expect(result.error as? ProviderError == .rateLimited(retryAfterSeconds: 2))
        #expect(transport.requestCount == 3)
        #expect(clock.sleeps == [2, 2])
        assertNoKey(result.error)
    }

    @Test func rateLimitThenSuccessRecovers() async {
        let transport = MockTransport([.json("{}", status: 429, headers: ["Retry-After": "1"]), fullStream()])
        let clock = ManualClock()
        let result = await collect(makeProvider(transport: transport, clock: clock).stream(userRequest))
        #expect(result.error == nil)
        #expect(result.events.last == .finish(.stop))
        #expect(transport.requestCount == 2)
        #expect(clock.sleeps == [1])
    }

    @Test func retryAfterIsBoundedAndCappedByTheRequestDeadline() async {
        let huge = MockResponse.json("{}", status: 429, headers: ["Retry-After": "999999"])
        let transport = MockTransport([huge, fullStream()])
        let clock = ManualClock()
        let result = await collect(makeProvider(transport: transport, clock: clock).stream(userRequest))
        #expect(result.error as? ProviderError == .rateLimited(retryAfterSeconds: 3600))
        #expect(transport.requestCount == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func retryAfterAsHTTPDateIsParsed() async {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 784_111_777 - 10))
        let limited = MockResponse.json("{}", status: 429, headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"])
        let transport = MockTransport([limited])
        let provider = makeProvider(transport: transport, clock: clock, retry: RetryPolicy(maxRetries: 0))
        let result = await collect(provider.stream(userRequest))
        #expect(result.error as? ProviderError == .rateLimited(retryAfterSeconds: 10))
    }

    @Test func serverErrorsRetryWithExponentialBackoffAndJitter() async {
        let transport = MockTransport([.json("{}", status: 500), .json("{}", status: 502), .json("{}", status: 503), fullStream()])
        let clock = ManualClock()
        let result = await collect(makeProvider(transport: transport, clock: clock).stream(userRequest))
        #expect(result.error as? ProviderError == .server(status: 503))
        #expect(transport.requestCount == 3)
        #expect(clock.sleeps == [0.25, 0.5])
    }

    @Test func serverErrorThenSuccessRecovers() async {
        let transport = MockTransport([.json("{}", status: 503), fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error == nil)
        #expect(result.events.last == .finish(.stop))
    }

    @Test func connectionFailureMapsToOfflineAfterBoundedRetries() async {
        let transport = MockTransport([.connectionFailure(), .connectionFailure(.cannotFindHost), .connectionFailure(.timedOut), fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error as? ProviderError == .offline)
        #expect(transport.requestCount == 3)
    }

    @Test func disconnectBeforeAnyOutputIsRetried() async {
        let transport = MockTransport([MockResponse(headers: ["Content-Type": "text/event-stream"], steps: [.disconnect]), fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error == nil)
        #expect(transport.requestCount == 2)
        #expect(result.events.last == .finish(.stop))
    }

    @Test func noRetryAfterPartialOutput() async {
        let partial = MockResponse.sse(textChunk("partial"), then: [.disconnect])
        let transport = MockTransport([partial, fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.events == [.textDelta("partial")])
        #expect(result.error as? ProviderError == .offline)
        #expect(transport.requestCount == 1)
    }

    @Test func htmlBodiesAreMalformedAndNotRetried() async {
        let page = "<html>login \(canaryKey)</html>"
        for response in [MockResponse.html(page, status: 200), MockResponse.html(page, status: 404), MockResponse.json(page, status: 200)] {
            let transport = MockTransport([response, fullStream()])
            let result = await collect(makeProvider(transport: transport).stream(userRequest))
            guard case .malformedResponse = result.error as? ProviderError else {
                Issue.record("expected malformedResponse, got \(String(describing: result.error))")
                continue
            }
            #expect(transport.requestCount == 1)
            assertNoKey(result.error)
        }
    }

    @Test func unsupportedOptionalFieldFallsBackOnceKeepingTools() async throws {
        let configuration = makeConfiguration()
        var profile = CapabilityProfile()
        profile.set(.streamUsage, .verified, configHash: configuration.capabilityHash, at: Date())
        let rejection = MockResponse.json(#"{"error":{"message":"Unrecognized request argument supplied: stream_options","type":"invalid_request_error"}}"#, status: 400)
        let transport = MockTransport([rejection, fullStream()])
        let provider = makeProvider(transport: transport, configuration: configuration, profile: profile)
        let request = ProviderRequest(messages: userRequest.messages, tools: [readCanaryTool])
        let result = await collect(provider.stream(request))

        #expect(result.error == nil)
        #expect(transport.requestCount == 2)
        let first = try bodyObject(transport.requests[0])
        let second = try bodyObject(transport.requests[1])
        #expect(first["stream_options"] != nil)
        #expect(second["stream_options"] == nil)
        #expect(second["tools"] != nil)
        #expect(await provider.observedUnsupportedCapabilities() == [.streamUsage])
    }

    @Test func fieldRejectedByEarlierRequestIsNotSentAgain() async throws {
        let configuration = makeConfiguration()
        var profile = CapabilityProfile()
        profile.set(.parallelToolCalls, .verified, configHash: configuration.capabilityHash, at: Date())
        let rejection = MockResponse.json(#"{"error":{"param":"parallel_tool_calls","message":"not allowed"}}"#, status: 400)
        let transport = MockTransport([rejection, fullStream(), fullStream()])
        let provider = makeProvider(transport: transport, configuration: configuration, profile: profile)
        let request = ProviderRequest(messages: userRequest.messages, tools: [readCanaryTool])
        _ = await collect(provider.stream(request))
        _ = await collect(provider.stream(request))
        #expect(transport.requestCount == 3)
        #expect(try bodyObject(transport.requests[2])["parallel_tool_calls"] == nil)
        #expect(try bodyObject(transport.requests[2])["tools"] != nil)
    }

    @Test func maxTokensParameterNameFlipsWhenRejected() async throws {
        let rejection = MockResponse.json(#"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#, status: 400)
        let transport = MockTransport([rejection, fullStream()])
        let provider = makeProvider(transport: transport)
        let result = await collect(provider.stream(userRequest))
        #expect(result.error == nil)
        #expect(try bodyObject(transport.requests[0])["max_tokens"] != nil)
        let second = try bodyObject(transport.requests[1])
        #expect(second["max_tokens"] == nil)
        #expect(second["max_completion_tokens"] as? Int == 512)
        #expect(await provider.observedUnsupportedCapabilities() == [])
    }

    @Test func unidentifiedBadRequestNeverDropsToolsSilently() async {
        let rejection = MockResponse.json(#"{"error":{"message":"this model does not support tools"}}"#, status: 400)
        let transport = MockTransport([rejection, fullStream()])
        let request = ProviderRequest(messages: userRequest.messages, tools: [readCanaryTool])
        let result = await collect(makeProvider(transport: transport).stream(request))
        #expect(result.error as? ProviderError == .requestRejected(status: 400, reason: "this model does not support tools"))
        #expect(transport.requestCount == 1)
    }

    @Test func contentPolicyRejectionCarriesTheProviderReasonWithoutRetrying() async {
        let body = #"{"error":{"message":"Enterprise DLP Guardrail Violation: Prompt rejected.\n  Sensitive information detected (Type: ENV_SECRET_ASSIGNMENT).","type":"invalid_request_error","code":"400"}}"#
        let transport = MockTransport([.json(body, status: 400), fullStream()])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error as? ProviderError == .requestRejected(status: 400, reason: "Enterprise DLP Guardrail Violation: Prompt rejected. Sensitive information detected (Type: ENV_SECRET_ASSIGNMENT)."))
        #expect(transport.requestCount == 1)
    }

    @Test func rejectionReasonFallsBackToPlainErrorStringsAndIsCapped() {
        #expect(OpenAICompatibleProvider.rejectionReason(in: Data(#"{"error":"model not found"}"#.utf8)) == "model not found")
        #expect(OpenAICompatibleProvider.rejectionReason(in: Data(#"{"detail":"bad request"}"#.utf8)) == "bad request")
        #expect(OpenAICompatibleProvider.rejectionReason(in: Data("not json".utf8)) == nil)
        let long = String(repeating: "a", count: 400)
        let capped = OpenAICompatibleProvider.rejectionReason(in: Data(#"{"error":{"message":"\#(long)"}}"#.utf8))
        #expect(capped?.count == OpenAICompatibleProvider.rejectionReasonLimit + 1)
    }

    @Test func consumerCancellationCancelsTheHTTPRequestPromptly() async throws {
        let transport = MockTransport([.sse(textChunk("first"), then: [.hang])])
        let provider = makeProvider(transport: transport)
        let started = Task<Void, Never> {
            var stream = provider.stream(userRequest).makeAsyncIterator()
            _ = try? await stream.next()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        started.cancel()
        let deadline = Date().addingTimeInterval(3)
        while transport.cancellationCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(transport.cancellationCount >= 1)
    }

    @Test func cancellingWhileWaitingForHeadersCancelsTheRequest() async throws {
        let transport = MockTransport([MockResponse(headBehavior: .hang)])
        let provider = makeProvider(transport: transport)
        let consumer = Task { await collect(provider.stream(userRequest)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        let result = await consumer.value
        #expect(result.events.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while transport.cancellationCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(transport.cancellationCount >= 1)
    }

    @Test func idleTimeoutAfterOutputIsReportedWithoutRetry() async {
        let configuration = makeConfiguration(timeouts: ProviderTimeouts(idleSeconds: 0.2, requestSeconds: 30))
        let transport = MockTransport([.sse(textChunk("started"), then: [.hang]), fullStream()])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.events == [.textDelta("started")])
        guard case .malformedResponse = result.error as? ProviderError else {
            Issue.record("expected malformedResponse, got \(String(describing: result.error))")
            return
        }
        #expect(transport.requestCount == 1)
    }

    @Test func idleTimeoutBeforeAnyOutputIsRetriedThenOffline() async {
        let configuration = makeConfiguration(timeouts: ProviderTimeouts(idleSeconds: 0.15, requestSeconds: 30))
        let hang = MockResponse(headBehavior: .hang)
        let transport = MockTransport([hang, hang, hang, fullStream()])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.error as? ProviderError == .offline)
        #expect(transport.requestCount == 3)
    }

    @Test func steadyStreamOutlivesRequestSecondsBecauseTheCeilingScalesWithOutput() async {
        let configuration = makeConfiguration(timeouts: ProviderTimeouts(idleSeconds: 5, requestSeconds: 0.3))
        var steps: [MockBodyStep] = []
        for _ in 0..<12 {
            steps.append(.chunk(Data(textChunk("tick").utf8)))
            steps.append(.delay(0.05))
        }
        steps.append(.chunk(Data(finishChunk("stop").utf8)))
        steps.append(.chunk(Data("data: [DONE]\n\n".utf8)))
        let transport = MockTransport([MockResponse(headers: ["Content-Type": "text/event-stream"], steps: steps)])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.error == nil)
        #expect(result.events.filter { if case .textDelta = $0 { true } else { false } }.count == 12)
        #expect(result.events.last == .finish(.stop))
    }

    @Test func idleTimeoutStopsAStalledStreamAfterOutput() async {
        let configuration = makeConfiguration(timeouts: ProviderTimeouts(idleSeconds: 0.2, requestSeconds: 30))
        let steps: [MockBodyStep] = [.chunk(Data(textChunk("partial").utf8)), .hang]
        let transport = MockTransport([MockResponse(headers: ["Content-Type": "text/event-stream"], steps: steps)])
        let result = await collect(makeProvider(transport: transport, configuration: configuration).stream(userRequest))
        #expect(result.events == [.textDelta("partial")])
        #expect(result.error as? ProviderError == .malformedResponse("The provider stopped responding before the answer was complete."))
        #expect(transport.requestCount == 1)
    }

    @Test func streamCeilingScalesWithOutputTokensWithinBounds() {
        let timeouts = ProviderTimeouts(idleSeconds: 30, requestSeconds: 90)
        #expect(timeouts.streamCeilingSeconds(maxOutputTokens: 0) == 90)
        #expect(timeouts.streamCeilingSeconds(maxOutputTokens: 16_384) > 1000)
        #expect(timeouts.streamCeilingSeconds(maxOutputTokens: 16_384) > timeouts.streamCeilingSeconds(maxOutputTokens: 8_192))
        #expect(timeouts.streamCeilingSeconds(maxOutputTokens: 1_000_000) == ProviderTimeouts.maximumStreamCeilingSeconds)
        #expect(ProviderTimeouts(idleSeconds: 30, requestSeconds: 2000).streamCeilingSeconds(maxOutputTokens: 100) == 2000)
    }

    @Test func contextLengthRejectionMapsToItsOwnError() async {
        let body = #"{"error":{"message":"This model's maximum context length is 128000 tokens. However, your messages resulted in 140000 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#
        let transport = MockTransport([.json(body, status: 400)])
        let result = await collect(makeProvider(transport: transport).stream(userRequest))
        #expect(result.error as? ProviderError == .contextLengthExceeded)
        #expect(transport.requestCount == 1)
    }

    @Test func canaryKeyNeverAppearsInAnyFailureOutput() async {
        let responses: [MockResponse] = [
            .json(#"{"error":"\#(canaryKey)"}"#, status: 401),
            .json(#"{"error":"\#(canaryKey)"}"#, status: 403),
            .json("{}", status: 429, headers: ["Retry-After": "1", "X-Echo": canaryKey]),
            .json(#"{"error":"\#(canaryKey)"}"#, status: 500),
            .html("<html>\(canaryKey)</html>"),
            .json(#"{"error":{"message":"\#(canaryKey)"}}"#, status: 400),
            .sse(sseChunk(#"{"error":{"message":"\#(canaryKey)"}}"#)),
            .connectionFailure(),
            .sse(sseChunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","function":{"name":"t","arguments":"\#(canaryKey)"}}]},"finish_reason":"tool_calls"}]}"#))
        ]
        for response in responses {
            let transport = MockTransport([response, response, response])
            let result = await collect(makeProvider(transport: transport).stream(userRequest))
            assertNoKey(result.error)
            assertNoKey(result.events)
        }
    }

    @Test func redactorScrubsSecretsAndAuthorizationValues() {
        let redactor = Redactor(secrets: [canaryKey])
        let text = "failed with \(canaryKey) and Authorization: Bearer abc.def-123 plus x-api-key=zzz999 and Bearer tokentoken"
        let cleaned = redactor.redact(text)
        #expect(!cleaned.contains(canaryKey))
        #expect(!cleaned.contains("abc.def-123"))
        #expect(!cleaned.contains("zzz999"))
        #expect(!cleaned.contains("tokentoken"))
        #expect(cleaned.contains(Redactor.placeholder))
        #expect(Redactor().redact("nothing secret here") == "nothing secret here")
    }

    @Test func routeOverrideSendsExactModelPerTurnAcrossSameGatewayAndKey() async throws {
        let fastSSE = sseChunk(#"{"model":"deepseek-chat","choices":[{"index":0,"delta":{"content":"fast answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#) + "data: [DONE]\n\n"
        let deepSSE = sseChunk(#"{"model":"deepseek-reasoner","choices":[{"index":0,"delta":{"content":"deep answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":15,"completion_tokens_details":{"reasoning_tokens":9}}}"#) + "data: [DONE]\n\n"
        let transport = MockTransport([.sse(fastSSE), .sse(deepSSE)])
        let provider = makeProvider(transport: transport)

        let turn1 = await collect(provider.stream(ProviderRequest(
            messages: [ModelMessage(role: .user, content: "quick check")],
            tools: [],
            routeOverride: "go-fast"
        )))
        let turn2 = await collect(provider.stream(ProviderRequest(
            messages: [ModelMessage(role: .user, content: "deep analysis")],
            tools: [],
            routeOverride: "go-deep"
        )))

        #expect(turn1.error == nil)
        #expect(turn2.error == nil)
        #expect(turn1.events == [
            .textDelta("fast answer"),
            .usage(TokenUsage(inputTokens: 10, outputTokens: 4, reasoningTokens: nil, responseModelID: "deepseek-chat")),
            .finish(.stop)
        ])
        #expect(turn2.events == [
            .textDelta("deep answer"),
            .usage(TokenUsage(inputTokens: 20, outputTokens: 15, reasoningTokens: 9, responseModelID: "deepseek-reasoner")),
            .finish(.stop)
        ])

        #expect(transport.requestCount == 2)
        let firstBody = try bodyObject(transport.requests[0])
        let secondBody = try bodyObject(transport.requests[1])
        #expect(firstBody["model"] as? String == "go-fast")
        #expect(secondBody["model"] as? String == "go-deep")
        #expect(transport.requests[0].url == transport.requests[1].url)
        #expect(transport.requests[0].headerValue("Authorization") == "Bearer \(canaryKey)")
        #expect(transport.requests[1].headerValue("Authorization") == "Bearer \(canaryKey)")
    }

    @Test func reasoningEffortEncodingFollowsRouteCapabilityProfileAndRejectsOn400WithoutRetry() async throws {
        var defaultOnlyConfig = makeConfiguration(modelID: "go-fast")
        defaultOnlyConfig.reasoningMode = .defaultOnly
        let defaultOnlyTransport = MockTransport([fullStream()])
        let defaultOnlyProvider = makeProvider(transport: defaultOnlyTransport, configuration: defaultOnlyConfig)
        _ = await collect(defaultOnlyProvider.stream(ProviderRequest(
            messages: userRequest.messages,
            tools: [],
            reasoningEffort: .high
        )))
        let defaultOnlyBody = try bodyObject(try #require(defaultOnlyTransport.requests.first))
        #expect(defaultOnlyBody["reasoning_effort"] == nil)

        var effortConfig = makeConfiguration(modelID: "o3-mini")
        effortConfig.reasoningMode = .openAIChatEffort(supported: [.low, .medium, .high])
        let effortTransport = MockTransport([fullStream(), fullStream()])
        let effortProvider = makeProvider(transport: effortTransport, configuration: effortConfig)

        _ = await collect(effortProvider.stream(ProviderRequest(
            messages: userRequest.messages,
            tools: [],
            reasoningEffort: .default
        )))
        _ = await collect(effortProvider.stream(ProviderRequest(
            messages: userRequest.messages,
            tools: [],
            reasoningEffort: .high
        )))
        let defaultBody = try bodyObject(effortTransport.requests[0])
        let highBody = try bodyObject(effortTransport.requests[1])
        #expect(defaultBody["reasoning_effort"] == nil)
        #expect(highBody["reasoning_effort"] as? String == "high")

        let rejection = MockResponse.json(
            #"{"error":{"param":"reasoning_effort","message":"Unrecognized request argument supplied: reasoning_effort \#(canaryKey)","type":"invalid_request_error"}}"#,
            status: 400
        )
        let rejectTransport = MockTransport([rejection, fullStream()])
        let rejectProvider = makeProvider(transport: rejectTransport, configuration: effortConfig)
        let rejected = await collect(rejectProvider.stream(ProviderRequest(
            messages: userRequest.messages,
            tools: [],
            reasoningEffort: .high
        )))
        #expect(rejectTransport.requestCount == 1)
        #expect(rejected.error as? ProviderError == .unsupportedParameter(
            field: "reasoning_effort",
            message: "This model route does not accept the requested reasoning effort. Retry with Default."
        ))
        assertNoKey(rejected.error)
    }

    @Test func deepSeekThinkingContinuationIsEncodedOnlyOnMatchingRouteAssistantToolCall() async throws {
        var deepSeekConfig = makeConfiguration(modelID: "deepseek-reasoner")
        deepSeekConfig.reasoningMode = .deepSeekThinking(preserveReasoningContentInToolLoop: true)

        let toolCall = ToolCall(id: "call_1", name: "read_canary", argumentsJSON: #"{"name":"alpha"}"#)
        let messages: [ModelMessage] = [
            ModelMessage(role: .user, content: "Inspect alpha"),
            ModelMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            ModelMessage(role: .tool, content: #"{"value":"CANARY"}"#, toolCallID: "call_1")
        ]

        let transport = MockTransport([fullStream(), fullStream(), fullStream()])
        let provider = makeProvider(transport: transport, configuration: deepSeekConfig)

        _ = await collect(provider.stream(ProviderRequest(
            messages: messages,
            tools: [readCanaryTool],
            routeOverride: "deepseek-reasoner",
            assistantContinuations: [1: ProviderContinuation(routeID: "deepseek-reasoner", reasoningContent: "step-by-step analysis")]
        )))

        _ = await collect(provider.stream(ProviderRequest(
            messages: messages,
            tools: [readCanaryTool],
            routeOverride: "go-fast",
            assistantContinuations: [1: ProviderContinuation(routeID: "deepseek-reasoner", reasoningContent: "step-by-step analysis")]
        )))

        var nonThinkingConfig = deepSeekConfig
        nonThinkingConfig.reasoningMode = .defaultOnly
        let nonThinkingProvider = makeProvider(transport: transport, configuration: nonThinkingConfig)
        _ = await collect(nonThinkingProvider.stream(ProviderRequest(
            messages: messages,
            tools: [readCanaryTool],
            routeOverride: "deepseek-reasoner",
            assistantContinuations: [1: ProviderContinuation(routeID: "deepseek-reasoner", reasoningContent: "step-by-step analysis")]
        )))

        let matchingMsgs = try #require(try bodyObject(transport.requests[0])["messages"] as? [[String: Any]])
        #expect(matchingMsgs[1]["reasoning_content"] as? String == "step-by-step analysis")
        #expect(matchingMsgs[0]["reasoning_content"] == nil)
        #expect(matchingMsgs[2]["reasoning_content"] == nil)

        let switchedRouteMsgs = try #require(try bodyObject(transport.requests[1])["messages"] as? [[String: Any]])
        #expect(switchedRouteMsgs[1]["reasoning_content"] == nil)

        let nonThinkingMsgs = try #require(try bodyObject(transport.requests[2])["messages"] as? [[String: Any]])
        #expect(nonThinkingMsgs[1]["reasoning_content"] == nil)
    }
}
