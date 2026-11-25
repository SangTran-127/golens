import Foundation
import XCTest
import GopilotProvider
@testable import GopilotCompletion

final class CompletionClientTests: XCTestCase {
    private let base = URL(string: "https://gateway.example.com/v1/chat/completions")!
    private let key = "sk-test-secret-value-123456"

    private func endpoint(_ dialect: CompletionDialect, stream: Bool = true) -> CompletionEndpoint {
        CompletionEndpoint(chatCompletionsURL: base, apiKey: key, options: CompletionRequestOptions(model: "codestral-latest", dialect: dialect, stream: stream))
    }

    private let single = CompletionContext(relativePath: "math.go", prefix: "func add(a, b int) int {\n\t", suffix: "\n}\n", multiline: false)
    private let multi = CompletionContext(relativePath: "store.go", prefix: "func (s *Store) Get(k string) string {\n\t", suffix: "\n}\n", multiline: true)

    private static func chatSSE(_ pieces: [String], done: Bool = true) -> String {
        var text = ""
        for piece in pieces {
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": piece]]]])
            text += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        if done { text += "data: [DONE]\n\n" }
        return text
    }

    private static func fimSSE(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "text": piece]]])
            text += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        return text + "data: [DONE]\n\n"
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    func testChatStreamingRequestAndHeaders() async throws {
        let transport = MockTransport([.sse(Self.chatSSE(["return ", "a + b"]), splitting: 7)])
        let client = CompletionClient(transport: transport, userAgent: "GoLens/1.0")
        let response = try await client.complete(context: single, endpoint: endpoint(.chatHoleFill))
        XCTAssertEqual(response.rawText, "return a + b")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://gateway.example.com/v1/chat/completions")
        XCTAssertEqual(request.headerValue("User-Agent"), "GoLens/1.0")
        XCTAssertEqual(request.headerValue("Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.headerValue("Accept"), "text/event-stream")
        let json = try body(request)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNotNil(json["messages"])
        XCTAssertNil(json["suffix"])
        XCTAssertFalse(request.description.contains(key))
    }

    func testFIMStreamingSendsSuffixToCompletionsEndpoint() async throws {
        let transport = MockTransport([.sse(Self.fimSSE(["return", " a + b"]))])
        let client = CompletionClient(transport: transport, userAgent: "GoLens/1.0")
        let response = try await client.complete(context: single, endpoint: endpoint(.fillInTheMiddle))
        XCTAssertEqual(response.rawText, "return a + b")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://gateway.example.com/v1/completions")
        let json = try body(request)
        XCTAssertEqual(json["prompt"] as? String, single.prefix)
        XCTAssertEqual(json["suffix"] as? String, "\n}\n")
        XCTAssertEqual(json["stop"] as? [String], ["\n"])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["messages"])
    }

    func testNonStreamingJSONForBothStyles() async throws {
        let chat = MockTransport([.json(#"{"choices":[{"message":{"role":"assistant","content":"return a + b"}}],"usage":{"prompt_tokens":40,"completion_tokens":5}}"#)])
        let chatResponse = try await CompletionClient(transport: chat, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.chatHoleFill, stream: false))
        XCTAssertEqual(chatResponse.rawText, "return a + b")
        XCTAssertEqual(chatResponse.promptTokens, 40)
        XCTAssertEqual(try body(XCTUnwrap(chat.requests.first))["stream"] as? Bool, false)

        let fim = MockTransport([.json(#"{"choices":[{"text":"return a + b","index":0}],"usage":{"prompt_tokens":31}}"#)])
        let fimResponse = try await CompletionClient(transport: fim, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.fillInTheMiddle, stream: false))
        XCTAssertEqual(fimResponse.rawText, "return a + b")
        XCTAssertEqual(fimResponse.promptTokens, 31)
    }

    func testNonStreamingBodyThatIsActuallySSE() async throws {
        let transport = MockTransport([.json(Self.chatSSE(["return a", " + b"], done: false))])
        let response = try await CompletionClient(transport: transport, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.chatHoleFill, stream: false))
        XCTAssertEqual(response.rawText, "return a + b")
    }

    func testStreamStopsEarlyAtEndOfBlockAndCancelsBody() async throws {
        let pieces = ["s.mu.RLock()\n", "\tdefer s.mu.RUnlock()\n", "\treturn s.data[k]\n", "}\n", "\nfunc other() {\n"]
        let transport = MockTransport([.sse(Self.chatSSE(pieces, done: false), then: [.hang])])
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0", timeoutSeconds: 2))
        let started = Date()
        let outcome = await service.suggest(context: multi, endpoint: endpoint(.chatHoleFill))
        XCTAssertEqual(outcome, .suggestion("s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\treturn s.data[k]", cached: false, latencySeconds: { if case .suggestion(_, _, let l) = outcome { return l }; return 0 }()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.cancellationCount, 1)
    }

    func testSingleLineFIMStopsAtNewline() async throws {
        let transport = MockTransport([.sse(Self.fimSSE(["return a + b", "\n}\n", "garbage"]))])
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0"))
        guard case .suggestion(let text, false, _) = await service.suggest(context: single, endpoint: endpoint(.fillInTheMiddle)) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertEqual(text, "return a + b")
    }

    func testCancellationStopsRequest() async throws {
        let transport = MockTransport([.sse("", then: [.hang])])
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0", timeoutSeconds: 10))
        let task = Task { await service.suggest(context: single, endpoint: endpoint(.chatHoleFill)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.cancellationCount, 1)
    }

    func testHardTimeout() async throws {
        let transport = MockTransport([MockResponse(headBehavior: .hang)])
        let client = CompletionClient(transport: transport, userAgent: "GoLens/1.0", timeoutSeconds: 0.2)
        let started = Date()
        do {
            _ = try await client.complete(context: single, endpoint: endpoint(.chatHoleFill))
            XCTFail("expected timeout")
        } catch let failure as CompletionFailure {
            XCTAssertEqual(failure, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testStatusMappingAndNoRetries() async throws {
        let cases: [(MockResponse, CompletionFailure)] = [
            (.json(#"{"error":{"message":"bad key"}}"#, status: 401), .unauthorized(status: 401)),
            (.json("error code: 1010", status: 403), .unauthorized(status: 403)),
            (.json(#"{"error":"not found"}"#, status: 404), .endpointNotFound),
            (.json("{}", status: 429, headers: ["Retry-After": "7"]), .rateLimited(retryAfterSeconds: 7)),
            (.json("{}", status: 503), .server(status: 503)),
            (.connectionFailure(), .offline)
        ]
        for (response, expected) in cases {
            let transport = MockTransport([response, .json(#"{"choices":[{"text":"x"}]}"#)])
            let client = CompletionClient(transport: transport, userAgent: "GoLens/1.0")
            do {
                _ = try await client.complete(context: single, endpoint: endpoint(.fillInTheMiddle))
                XCTFail("expected \(expected)")
            } catch let failure as CompletionFailure {
                XCTAssertEqual(failure, expected)
            }
            XCTAssertEqual(transport.requestCount, 1)
        }
    }

    func testStreamErrorEventIsReportedWithoutKey() async throws {
        let transport = MockTransport([.sse("data: {\"error\":{\"message\":\"upstream failed\"}}\n\n")])
        do {
            _ = try await CompletionClient(transport: transport, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.chatHoleFill))
            XCTFail("expected failure")
        } catch let failure as CompletionFailure {
            XCTAssertEqual(failure, .invalidResponse("upstream failed"))
        }
    }

    func testServiceCachesAndServesTypingThrough() async throws {
        let transport = MockTransport([.sse(Self.chatSSE(["return a + b"]))])
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0"))
        let first = await service.suggest(context: single, endpoint: endpoint(.chatHoleFill))
        guard case .suggestion("return a + b", false, _) = first else { return XCTFail("\(first)") }
        let again = await service.suggest(context: single, endpoint: endpoint(.chatHoleFill))
        XCTAssertEqual(again, .suggestion("return a + b", cached: true, latencySeconds: 0))
        var typed = single
        typed.prefix += "ret"
        typed.linePrefix += "ret"
        let through = await service.suggest(context: typed, endpoint: endpoint(.chatHoleFill))
        XCTAssertEqual(through, .suggestion("urn a + b", cached: true, latencySeconds: 0))
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testCustomAuthHeader() throws {
        let client = CompletionClient(transport: MockTransport([]), userAgent: "GoLens/1.0")
        var ep = endpoint(.chatHoleFill)
        ep.authHeaderName = "x-api-key"
        let request = try client.makeRequest(context: single, endpoint: ep)
        XCTAssertEqual(request.headerValue("x-api-key"), key)
        XCTAssertNil(request.headerValue("Authorization"))
        XCTAssertTrue(request.sensitiveHeaderNames.contains("x-api-key"))
    }

    func testEndpointFromProviderConfiguration() throws {
        let config = ProviderConfiguration(id: "g:m", displayName: "M", baseURL: "http://127.0.0.1:9999/v1", modelID: "text-completion-codestral/codestral-latest", maxTokensParameter: .maxCompletionTokens, localEndpoint: true)
        let ep = try CompletionEndpoint(configuration: config, apiKey: "k", dialect: .fillInTheMiddle)
        XCTAssertEqual(ep.url.absoluteString, "http://127.0.0.1:9999/v1/completions")
        XCTAssertEqual(ep.options.model, "text-completion-codestral/codestral-latest")
        XCTAssertEqual(ep.options.maxTokensParameter, .maxCompletionTokens)
        let bad = ProviderConfiguration(id: "g:m", displayName: "M", baseURL: "http://example.com/v1", modelID: "m")
        XCTAssertThrowsError(try CompletionEndpoint(configuration: bad, apiKey: nil, dialect: .chatHoleFill))
    }
}

final class CompletionProbeTests: XCTestCase {
    private let base = URL(string: "https://gateway.example.com/v1/chat/completions")!

    private func endpoint(_ dialect: CompletionDialect) -> CompletionEndpoint {
        CompletionEndpoint(chatCompletionsURL: base, apiKey: "k", options: CompletionRequestOptions(model: "m", dialect: dialect))
    }

    func testFIMHonoredWhenSuffixCountsTowardPromptTokens() async throws {
        let transport = MockTransport([
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":72}}"#),
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":18}}"#)
        ])
        let result = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.fillInTheMiddle)).result
        XCTAssertEqual(result, .fimHonored(latencySeconds: { if case .fimHonored(let l, _, _) = result { return l }; return -1 }(), promptTokensWithSuffix: 72, promptTokensWithoutSuffix: 18))
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(first["stream"] as? Bool, false)
        XCTAssertEqual(first["suffix"] as? String, CompletionProbe.suffix)
        XCTAssertEqual(transport.requests.first?.url.lastPathComponent, "completions")
    }

    func testFIMIgnoredWhenPromptTokensMatch() async {
        let transport = MockTransport([
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":18}}"#),
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":18}}"#)
        ])
        guard case .fimSuffixIgnored = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.fillInTheMiddle)).result else {
            return XCTFail("expected suffix ignored")
        }
    }

    func testFIMIgnoredWhenOutputRepeatsSuffix() async {
        let transport = MockTransport([.json(#"{"choices":[{"text":"a + b\n}\n\nfunc multiplyAllTheThings(values []int) int {"}]}"#)])
        guard case .fimSuffixIgnored = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.fillInTheMiddle)).result else {
            return XCTFail("expected suffix ignored")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testFIMNotSupportedOn404() async {
        let transport = MockTransport([.json(#"{"detail":"Not Found"}"#, status: 404)])
        let result = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.fillInTheMiddle)).result
        XCTAssertEqual(result, .fimNotSupported)
    }

    func testFIMUnconfirmedWithoutUsage() async {
        let transport = MockTransport([.json(#"{"choices":[{"text":"a + b"}]}"#)])
        guard case .fimUnconfirmed = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.fillInTheMiddle)).result else {
            return XCTFail("expected unconfirmed")
        }
    }

    func testChatProbe() async {
        let ok = MockTransport([.json(#"{"choices":[{"message":{"content":"a + b"}}]}"#)])
        guard case .chatWorks = await CompletionProbe(transport: ok, userAgent: "GoLens/1.0").run(endpoint: endpoint(.chatHoleFill)).result else {
            return XCTFail("expected chat works")
        }
        let failing = MockTransport([.json("{}", status: 401)])
        let failed = await CompletionProbe(transport: failing, userAgent: "GoLens/1.0").run(endpoint: endpoint(.chatHoleFill)).result
        XCTAssertEqual(failed, .failed(.unauthorized(status: 401)))
    }

    func testSuggestedDialect() {
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "text-completion-codestral/codestral-latest"), .fillInTheMiddle)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "codestral-2508"), .fillInTheMiddle)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "qwen2.5-coder:7b-base"), .fillInTheMiddle)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "deepseek-coder-6.7b-base"), .fillInTheMiddle)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "mercury-edit-fim"), .fillInTheMiddle)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "mistralai/codestral-2508"), .chatHoleFill)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "mistral/deepseek-v4-1-flash-1017"), .chatHoleFill)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "gpt-5-mini"), .chatHoleFill)
    }
}

final class FIMTemplateTests: XCTestCase {
    private let base = URL(string: "https://gateway.example.com/v1/chat/completions")!
    private let single = CompletionContext(relativePath: "math.go", prefix: "func mul(x, y int) int {\n\treturn ", suffix: "\n}\n", multiline: false)

    private func endpoint(_ template: FIMTemplate, stream: Bool = true) -> CompletionEndpoint {
        CompletionEndpoint(chatCompletionsURL: base, apiKey: "k", options: CompletionRequestOptions(model: "fim-coder", dialect: .fillInTheMiddle, stream: stream, fimTemplate: template))
    }

    func testQwenRawTemplateBodyGolden() throws {
        let data = try CompletionEncoder.encode(single, options: endpoint(.qwen).options)
        let expected = #"{"max_tokens":64,"model":"fim-coder","prompt":"<|fim_prefix|>func mul(x, y int) int {\n\treturn <|fim_suffix|>\n}\n<|fim_middle|>","stop":["\n","<|endoftext|>","<|fim_pad|>","<|file_sep|>","<|fim_prefix|>"],"stream":true,"temperature":0}"#
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    func testOtherTemplatesPlaceSuffixAndPrefix() {
        XCTAssertEqual(FIMTemplate.codestral.prompt(prefix: "P", suffix: "S"), "[SUFFIX]S[PREFIX]P")
        XCTAssertEqual(FIMTemplate.deepSeekCoder.prompt(prefix: "P", suffix: "S"), "<｜fim▁begin｜>P<｜fim▁hole｜>S<｜fim▁end｜>")
        XCTAssertEqual(FIMTemplate.starCoder.prompt(prefix: "P", suffix: "S"), "<fim_prefix>P<fim_suffix>S<fim_middle>")
        XCTAssertEqual(FIMTemplate.suffixParameter.prompt(prefix: "P", suffix: "S"), "P")
    }

    func testRawTemplateKeepsContextSmallAtLineBoundaries() throws {
        let prefix = String(repeating: "\tx := 1\n", count: 400) + "\treturn "
        let suffix = "\n" + String(repeating: "\ty := 2\n", count: 200)
        let context = CompletionContext(relativePath: "a.go", prefix: prefix, suffix: suffix, multiline: false)
        let body = CompletionEncoder.body(context, options: endpoint(.qwen).options)
        let prompt = try XCTUnwrap(body["prompt"] as? String)
        let inner = prompt.replacingOccurrences(of: "<|fim_prefix|>", with: "")
        let parts = inner.components(separatedBy: "<|fim_suffix|>")
        XCTAssertLessThanOrEqual(parts[0].count, 1_500)
        XCTAssertTrue(parts[0].hasPrefix("\tx := 1\n"))
        XCTAssertTrue(parts[0].hasSuffix("\treturn "))
        XCTAssertLessThanOrEqual(parts[1].replacingOccurrences(of: "<|fim_middle|>", with: "").count, 500)
        XCTAssertNil(body["suffix"])
        let shifted = CompletionContext(relativePath: "a.go", prefix: prefix + "a", suffix: suffix, multiline: false)
        let next = try XCTUnwrap(CompletionEncoder.body(shifted, options: endpoint(.qwen).options)["prompt"] as? String)
        XCTAssertTrue(next.hasPrefix(String(prompt.prefix(200))))
    }

    func testControlTokensAreCutFromOutput() {
        XCTAssertEqual(CompletionPostProcessor.process("x * y<|endoftext|>garbage", context: single), "x * y")
        XCTAssertEqual(CompletionPostProcessor.process("x * y<|fim_middle|>", context: single), "x * y")
    }

    func testSuggestedTemplates() {
        XCTAssertEqual(FIMTemplate.suggested(forModelID: "openai/qwen2.5-coder-0.5b-base"), .qwen)
        XCTAssertEqual(FIMTemplate.suggested(forModelID: "deepseek-coder-6.7b-base"), .deepSeekCoder)
        XCTAssertEqual(FIMTemplate.suggested(forModelID: "bigcode/starcoder2-15b"), .starCoder)
        XCTAssertEqual(FIMTemplate.suggested(forModelID: "text-completion-codestral/codestral-latest"), .suffixParameter)
        XCTAssertEqual(FIMTemplate.suggested(forModelID: "fim-coder"), .suffixParameter)
        XCTAssertEqual(CompletionDialect.suggested(forModelID: "fim-coder"), .fillInTheMiddle)
    }

    func testNativeLlamaCppContentFallbackNonStreaming() async throws {
        let body = #"{"choices":[{"text":null,"index":0}],"content":"x * y","tokens_predicted":4,"stopped_eos":true,"timings":{"predicted_ms":70}}"#
        let transport = MockTransport([.json(body)])
        let response = try await CompletionClient(transport: transport, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.qwen, stream: false))
        XCTAssertEqual(response.rawText, "x * y")
        XCTAssertTrue(response.usedNativeContent)
        let plain = MockTransport([.json(#"{"choices":[{"text":"x * y"}]}"#)])
        let plainResponse = try await CompletionClient(transport: plain, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.qwen, stream: false))
        XCTAssertFalse(plainResponse.usedNativeContent)
    }

    func testNativeContentInStreamEvents() async throws {
        let transport = MockTransport([.sse("data: {\"content\":\"x * \",\"stop\":false}\n\ndata: {\"content\":\"y\",\"stop\":true}\n\n")])
        let response = try await CompletionClient(transport: transport, userAgent: "GoLens/1.0").complete(context: single, endpoint: endpoint(.qwen))
        XCTAssertEqual(response.rawText, "x * y")
        XCTAssertTrue(response.usedNativeContent)
    }

    func testStreaming5xxFallsBackToSingleResponseAndIsRemembered() async throws {
        let transport = MockTransport([
            .json(#"{"error":{"message":"object of type 'NoneType' has no len()"}}"#, status: 500),
            .json(#"{"choices":[{"text":null}],"content":"x * y"}"#),
            .json(#"{"choices":[{"text":null}],"content":"x * y"}"#)
        ])
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0"))
        let first = await service.suggest(context: single, endpoint: endpoint(.qwen), useCache: false)
        guard case .suggestion("x * y", false, _) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(service.streamingUnsupported(for: endpoint(.qwen)))
        let streamFlags = try transport.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.body)) as? [String: Any])["stream"] as? Bool }
        XCTAssertEqual(streamFlags, [true, false])
        _ = await service.suggest(context: single, endpoint: endpoint(.qwen), useCache: false)
        let third = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.last?.body)) as? [String: Any])
        XCTAssertEqual(third["stream"] as? Bool, false)
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testProbeRawTemplateWorksAndFlagsNativeContentAndStreaming() async {
        let transport = MockTransport([
            .json(#"{"choices":[{"text":null}],"content":"a + b"}"#),
            .json("{}", status: 500)
        ])
        let report = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.qwen))
        guard case .fimTemplateWorks = report.result else { return XCTFail("\(report)") }
        XCTAssertTrue(report.usedNativeContent)
        XCTAssertTrue(report.streamingFailed)
    }

    func testProbeSuffixParameterIgnoredOnLlamaCppRoute() async {
        let transport = MockTransport([
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":14}}"#),
            .json(#"{"choices":[{"text":"a + b"}],"usage":{"prompt_tokens":14}}"#)
        ])
        let report = await CompletionProbe(transport: transport, userAgent: "GoLens/1.0").run(endpoint: endpoint(.suffixParameter))
        guard case .fimSuffixIgnored = report.result else { return XCTFail("\(report)") }
    }

    func testConsentRequiredErrorMapsToCompletionFailureConsentRequired() async {
        let ep = endpoint(.suffixParameter)
        let blockingTransport = URLSessionTransport(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = []
            return cfg
        }(), authorizeHost: { _ in false })
        let client = CompletionClient(transport: blockingTransport, userAgent: "GoLens/1.0", timeoutSeconds: 2)
        do {
            _ = try await client.complete(context: single, endpoint: ep)
            XCTFail("Expected consentRequired failure")
        } catch let failure as CompletionFailure {
            XCTAssertEqual(failure, .consentRequired(host: "gateway.example.com"))
            XCTAssertTrue(failure.requiresSettingsChange)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class BlockOverrunTests: XCTestCase {
    private let getPrefix = "package store\n\nfunc (s *Store) Get(key string) (string, error) {\n\t"
    private let getSuffix = "\n}\n\nfunc (s *Store) Delete(key string) {\n\ts.mu.Lock()\n\tdelete(s.data, key)\n\ts.mu.Unlock()\n}\n"
    private let overrun = "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\tvalue, ok := s.data[key]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\treturn value, nil\n}\n\nfunc (s *Store) Set(key, value string) {\n\ts.mu.Lock()\n\tdefer s.mu.Unlock()\n\ts.data[key] = value\n}\n"
    private let expected = "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\tvalue, ok := s.data[key]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\treturn value, nil"

    func testStoreGetBodyStopsAtEndOfBlock() {
        let context = CompletionContext(relativePath: "store.go", prefix: getPrefix, suffix: getSuffix, multiline: true)
        XCTAssertEqual(CompletionPostProcessor.process(overrun, context: context), expected)
    }

    func testBlockOpenedOnCaretLineStopsAtItsClosingBrace() {
        let context = CompletionContext(relativePath: "store.go", prefix: "func (s *Store) Get(key string) (string, error) {", suffix: "\n", multiline: true)
        let raw = "\n\ts.mu.RLock()\n\treturn s.data[key], nil\n}\nfunc (s *Store) Set(key, value string) {\n"
        XCTAssertEqual(CompletionPostProcessor.process(raw, context: context), "\n\ts.mu.RLock()\n\treturn s.data[key], nil")
    }

    func testBracesInStringsAndCommentsDoNotCount() {
        let context = CompletionContext(relativePath: "a.go", prefix: "func f() string {\n\t", suffix: "\n}\n", multiline: true)
        let raw = "// close } here\n\tx := \"}\"\n\treturn x\n}\nfunc g() {}"
        XCTAssertEqual(CompletionPostProcessor.process(raw, context: context), "// close } here\n\tx := \"}\"\n\treturn x")
    }

    func testStopsWhenRepeatingTheFollowingLine() {
        let context = CompletionContext(relativePath: "a.go", prefix: "func f() error {\n\t", suffix: "\n\treturn helper()\n}\n", multiline: true)
        let raw = "if err := check(); err != nil {\n\t\treturn err\n\t}\n\treturn helper()\n\tmore()"
        XCTAssertEqual(CompletionPostProcessor.process(raw, context: context), "if err := check(); err != nil {\n\t\treturn err\n\t}")
    }

    func testStreamIsCancelledWhenTheBlockCloses() async throws {
        var sse = ""
        for piece in [overrun.prefix(60), overrun.dropFirst(60).prefix(70), overrun.dropFirst(130)] {
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "text": String(piece)]]])
            sse += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        let transport = MockTransport([.sse(sse, then: [.hang])])
        let endpoint = CompletionEndpoint(chatCompletionsURL: URL(string: "https://gw.example.com/v1/chat/completions")!, apiKey: "k",
                                          options: CompletionRequestOptions(model: "fim-coder", dialect: .fillInTheMiddle, fimTemplate: .qwen))
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/1.0", timeoutSeconds: 2))
        let context = CompletionContext(relativePath: "store.go", prefix: getPrefix, suffix: getSuffix, multiline: true)
        let started = Date()
        let outcome = await service.suggest(context: context, endpoint: endpoint)
        guard case .suggestion(let text, false, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(text, expected)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.cancellationCount, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(body["stop"] as? [String], ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|fim_prefix|>"])
        XCTAssertTrue((body["prompt"] as? String)?.hasPrefix("<|fim_prefix|>package store") == true)
    }
}
