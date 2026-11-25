import Foundation
import Testing
import GopilotRuntime
@testable import GopilotProvider

private let canaryCall = ToolCall(id: "call_1", name: ConnectionTester.canaryToolName, argumentsJSON: #"{"name":"alpha"}"#)

private func fastTester() -> ConnectionTester {
    ConnectionTester(stepTimeoutSeconds: 5, cancellationTimeoutSeconds: 1)
}

private let cancellationScript: [ScriptStep] = [.event(.textDelta("1 2 3")), .hang]

private func healthyScript() -> [[ScriptStep]] {
    [
        [.event(.textDelta("ok")), .event(.usage(TokenUsage(inputTokens: 9, outputTokens: 1))), .event(.finish(.stop))],
        [.event(.toolCall(canaryCall)), .event(.finish(.toolCalls))],
        [.event(.textDelta("The value is \(ConnectionTester.canaryValue)")), .event(.finish(.stop))],
        cancellationScript
    ]
}

@Suite("Connection tester")
struct ConnectionTesterTests {
    @Test func healthyScriptedProviderPassesEveryDefaultCheckAndEnablesAgentMode() async throws {
        let provider = ScriptedProvider(responses: healthyScript())
        let now = Date(timeIntervalSince1970: 9_000)
        let report = await fastTester().run(streaming: provider, configHash: "hash-1", now: now)

        for id in [CheckID.text, .streaming, .tools, .jsonArguments, .toolRoundTrip, .cancellation, .usage, .streamUsage] {
            #expect(report.outcome(id) == .pass, "\(id): \(report.check(id).detail)")
        }
        #expect(report.outcome(.nonStreaming) == .notTested)
        #expect(report.outcome(.parallelToolCalls) == .notTested)
        #expect(report.outcome(.strictSchema) == .notTested)
        #expect(report.outcome(.maxTokensParameter) == .notTested)
        #expect(report.agentMode == .agent)
        #expect(report.checks.count == CheckID.allCases.count)
        #expect(report.checks.allSatisfy { !$0.detail.isEmpty })

        let profile = report.updatedProfile()
        #expect(profile.isVerified(.text, configHash: "hash-1"))
        #expect(profile.isVerified(.tools, configHash: "hash-1"))
        #expect(profile.isVerified(.streaming, configHash: "hash-1"))
        #expect(profile.state(of: .strictSchema, configHash: "hash-1") == .unknown)
        #expect(profile.state(of: .tools, configHash: "other") == .unknown)
        #expect(profile.agentMode(configHash: "hash-1") == .agent)
        #expect(profile.record(for: .text, configHash: "hash-1")?.checkedAt == now)

        let requests = await provider.recordedRequests()
        #expect(requests.count == 4)
        #expect(requests[1].tools.map(\.name) == [ConnectionTester.canaryToolName])
        let followUp = requests[2].messages
        #expect(followUp.map(\.role) == [.user, .assistant, .tool])
        #expect(followUp[1].toolCalls == [canaryCall])
        #expect(followUp[2].toolCallID == "call_1")
    }

    @Test func textWorksButToolsFailMakesChatOnly() async {
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("ok")), .event(.finish(.stop))],
            [.event(.textDelta("alpha is probably 42")), .event(.finish(.stop))],
            cancellationScript
        ])
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.outcome(.text) == .pass)
        #expect(report.outcome(.tools) == .unsupported)
        #expect(report.outcome(.jsonArguments) == .notTested)
        #expect(report.outcome(.toolRoundTrip) == .notTested)
        #expect(report.agentMode == .chatOnly)
        let profile = report.updatedProfile()
        #expect(profile.state(of: .tools, configHash: "h") == .unsupported)
        #expect(profile.agentMode(configHash: "h") == .chatOnly)
        #expect(profile.state(of: .usage, configHash: "h") == .unsupported)
    }

    @Test func invalidToolArgumentsKeepAgentModeOff() async {
        let badCall = ToolCall(id: "call_1", name: ConnectionTester.canaryToolName, argumentsJSON: "{}")
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("ok")), .event(.finish(.stop))],
            [.event(.toolCall(badCall)), .event(.finish(.toolCalls))],
            cancellationScript
        ])
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.outcome(.tools) == .pass)
        #expect(report.outcome(.jsonArguments) == .unsupported)
        #expect(report.outcome(.toolRoundTrip) == .notTested)
        #expect(report.agentMode == .chatOnly)
        #expect(report.updatedProfile().state(of: .tools, configHash: "h") == .unsupported)
    }

    @Test func toolRoundTripFailureKeepsAgentModeOff() async {
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("ok")), .event(.finish(.stop))],
            [.event(.toolCall(canaryCall)), .event(.finish(.toolCalls))],
            [.fail(.malformedResponse("tool role rejected"))],
            cancellationScript
        ])
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.outcome(.toolRoundTrip) == .unsupported)
        #expect(report.check(.toolRoundTrip).detail.contains("tool role rejected"))
        #expect(report.agentMode == .chatOnly)
    }

    @Test func streamWithoutFinishReasonIsNotUsableText() async {
        let provider = ScriptedProvider(responses: [[.event(.textDelta("ok"))]])
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.outcome(.text) == .unsupported)
        #expect(report.outcome(.streaming) == .unsupported)
        #expect(report.check(.streaming).detail.contains("finish"))
        #expect(report.outcome(.tools) == .notTested)
        #expect(report.agentMode == .unavailable)
    }

    @Test func environmentFailuresLeaveEverythingNotTested() async {
        let cases: [(ProviderError, String)] = [
            (.unauthorized, "Authentication"),
            (.rateLimited(retryAfterSeconds: 3), "rate limited"),
            (.server(status: 503), "503"),
            (.offline, "reached")
        ]
        for (error, fragment) in cases {
            let provider = ScriptedProvider(responses: [[.fail(error)]])
            let report = await fastTester().run(streaming: provider, configHash: "h")
            #expect(report.checks.allSatisfy { $0.outcome == .notTested }, "\(error)")
            #expect(report.check(.text).detail.localizedCaseInsensitiveContains(fragment), "\(error)")
            #expect(report.agentMode == .unavailable)
            #expect(report.updatedProfile().records.isEmpty)
            let requests = await provider.recordedRequests()
            #expect(requests.count == 1)
        }
    }

    @Test func streamThatFinishesBeforeCancellationIsNotTested() async {
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("ok")), .event(.finish(.stop))],
            [.event(.textDelta("no")), .event(.finish(.stop))],
            [.event(.textDelta("1 2 3")), .event(.finish(.stop))]
        ])
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.outcome(.cancellation) == .notTested)
        #expect(report.outcome(.tools) == .unsupported)
    }

    @Test func requestsContainOnlySyntheticData() async {
        let provider = ScriptedProvider(responses: healthyScript())
        _ = await fastTester().run(streaming: provider, configHash: "h")
        let allowedPrefixes = [
            "You are a connection test",
            "Reply with the single word",
            "Call the read_canary tool",
            "{\"value\":\"CANARY-7391\"}",
            "Count from 1 to 300",
            ""
        ]
        for request in await provider.recordedRequests() {
            for message in request.messages {
                #expect(allowedPrefixes.contains { message.content.hasPrefix($0) }, "\(message.content)")
            }
            #expect(request.tools.allSatisfy { $0.name == ConnectionTester.canaryToolName })
        }
    }

    @Test func openAICompatibleProviderWithoutToolSupportYieldsChatOnly() async throws {
        let streamTransport = MockTransport([
            .sse(textChunk("ok") + finishChunk("stop") + sseChunk(#"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#) + "data: [DONE]\n\n"),
            .json(#"{"error":{"message":"This model does not support tools","type":"invalid_request_error"}}"#, status: 400),
            .sse(textChunk("1 2 3"), then: [.hang])
        ])
        let plainBody = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#
        let plainTransport = MockTransport([.json(plainBody)])
        let configuration = makeConfiguration()
        let streaming = makeProvider(transport: streamTransport, configuration: configuration, streaming: true)
        let plain = makeProvider(transport: plainTransport, configuration: configuration, streaming: false)

        let report = await fastTester().run(streaming: streaming, nonStreaming: plain, configHash: configuration.capabilityHash)

        #expect(report.outcome(.text) == .pass)
        #expect(report.outcome(.streaming) == .pass)
        #expect(report.outcome(.nonStreaming) == .pass)
        #expect(report.outcome(.usage) == .pass)
        #expect(report.outcome(.streamUsage) == .pass)
        #expect(report.outcome(.tools) == .unsupported)
        #expect(report.outcome(.cancellation) == .pass, "\(report.check(.cancellation).detail)")
        #expect(report.agentMode == .chatOnly)
        #expect(configuration.agentMode(using: report.updatedProfile()) == .chatOnly)

        let bodies = (streamTransport.requests + plainTransport.requests).compactMap(\.body).map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.count == 4)
        #expect(bodies.allSatisfy { !$0.contains(canaryKey) })
        let toolRequest = try #require(streamTransport.requests.dropFirst().first)
        let toolData = try #require(toolRequest.body)
        let toolBody = try #require(JSONSerialization.jsonObject(with: toolData) as? [String: Any])
        #expect((toolBody["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test func openAICompatibleProviderWithFullToolSupportYieldsAgentMode() async {
        let callChunk = sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"read_canary","arguments":"{\"name\":\"alpha\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let transport = MockTransport([
            .sse(textChunk("ok") + finishChunk("stop")),
            .sse(callChunk),
            .sse(textChunk("CANARY-7391") + finishChunk("stop")),
            .sse(textChunk("1 2 3"), then: [.hang])
        ])
        let configuration = makeConfiguration()
        let provider = makeProvider(transport: transport, configuration: configuration)
        let report = await fastTester().run(streaming: provider, configHash: configuration.capabilityHash)
        #expect(report.agentMode == .agent, "\(report.checks)")
        #expect(report.outcome(.usage) == .unsupported)
    }

    @Test func unauthorizedProviderIsReportedWithoutLeakingTheKey() async {
        let transport = MockTransport([.json(#"{"error":"\#(canaryKey)"}"#, status: 401)])
        let provider = makeProvider(transport: transport)
        let report = await fastTester().run(streaming: provider, configHash: "h")
        #expect(report.checks.allSatisfy { $0.outcome == .notTested })
        #expect(report.agentMode == .unavailable)
        #expect(!"\(report)".contains(canaryKey))
        #expect(transport.requestCount == 1)
    }
}

@Suite("Usage tracking")
struct UsageTrackerTests {
    private let pricing = ProviderPricing(
        modelID: "test-model",
        inputPerMillionTokens: 2,
        outputPerMillionTokens: 6,
        currency: "USD",
        capturedAt: Date(timeIntervalSince1970: 100)
    )

    @Test func missingProviderUsageIsUnknownNeverZero() {
        let usage = TurnUsage(provider: nil)
        #expect(usage.inputTokens == .unknown)
        #expect(usage.outputTokens == .unknown)
        #expect(usage.totalTokens == .unknown)
        #expect(usage.totalTokens.tokens == nil)
        #expect(usage.inputTokens.displayText == "Unknown")
        #expect(TurnUsage.from(events: [.textDelta("a"), .finish(.stop)]) == .unknown)
        let partial = TurnUsage(provider: TokenUsage(inputTokens: 10, outputTokens: nil))
        #expect(partial.inputTokens == .reported(10))
        #expect(partial.outputTokens == .unknown)
        #expect(partial.totalTokens == .unknown)
    }

    @Test func estimatesAreMarkedAndProviderValuesWin() {
        let estimated = TurnUsage(provider: nil, estimatedInput: 1200, estimatedOutput: 300)
        #expect(estimated.inputTokens == .estimated(1200))
        #expect(estimated.inputTokens.displayText.hasPrefix("~"))
        #expect(estimated.totalTokens == .estimated(1500))
        let reported = TurnUsage(provider: TokenUsage(inputTokens: 1000, outputTokens: 200), estimatedInput: 1200, estimatedOutput: 300)
        #expect(reported.inputTokens == .reported(1000))
        #expect(reported.totalTokens == .reported(1200))
        let mixed = TurnUsage(provider: TokenUsage(inputTokens: 1000, outputTokens: nil), estimatedInput: nil, estimatedOutput: 300)
        #expect(mixed.totalTokens == .estimated(1300))
    }

    @Test func latestUsageEventInTurnIsUsed() {
        let events: [ProviderEvent] = [
            .usage(TokenUsage(inputTokens: 1, outputTokens: 1)),
            .textDelta("x"),
            .usage(TokenUsage(inputTokens: 40, outputTokens: 12)),
            .finish(.stop)
        ]
        #expect(TurnUsage.from(events: events) == TurnUsage(inputTokens: .reported(40), outputTokens: .reported(12)))
    }

    @Test func costOnlyWithPricingThatMatchesTheModel() {
        let usage = TurnUsage(provider: TokenUsage(inputTokens: 1000, outputTokens: 500))
        #expect(usage.cost(pricing: nil, modelID: "test-model") == .unknown(.noPricing))
        #expect(usage.cost(pricing: pricing, modelID: "another-model") == .unknown(.modelMismatch))
        #expect(TurnUsage.unknown.cost(pricing: pricing, modelID: "test-model") == .unknown(.usageUnknown))
        let cost = usage.cost(pricing: pricing, modelID: "test-model")
        #expect(cost == .estimated(amount: Decimal(string: "0.005")!, currency: "USD", pricedAt: pricing.capturedAt))
    }

    @Test func trackerTotalsAndNeverHidesUnknownTurns() {
        var tracker = UsageTracker()
        #expect(tracker.total == nil)
        #expect(tracker.totalCost(pricing: pricing, modelID: "test-model") == nil)
        tracker.record(TurnUsage(provider: TokenUsage(inputTokens: 1000, outputTokens: 500)))
        tracker.record(TurnUsage(provider: TokenUsage(inputTokens: 2000, outputTokens: 1000)))
        #expect(tracker.total == TurnUsage(inputTokens: .reported(3000), outputTokens: .reported(1500)))
        #expect(tracker.totalCost(pricing: pricing, modelID: "test-model") == .estimated(amount: Decimal(string: "0.015")!, currency: "USD", pricedAt: pricing.capturedAt))
        tracker.record(.unknown)
        #expect(tracker.total?.totalTokens == .unknown)
        #expect(tracker.totalCost(pricing: pricing, modelID: "test-model") == .unknown(.usageUnknown))
        #expect(tracker.turns.count == 3)
    }
}
