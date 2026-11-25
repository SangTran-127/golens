import Foundation
import GopilotRuntime

public enum CheckID: String, CaseIterable, Sendable, Codable {
    case text
    case streaming
    case nonStreaming
    case tools
    case jsonArguments
    case toolRoundTrip
    case cancellation
    case usage
    case streamUsage
    case parallelToolCalls
    case strictSchema
    case maxTokensParameter
}

public enum CheckOutcome: String, Sendable, Codable, Equatable {
    case pass
    case unsupported
    case notTested
}

public struct CompatibilityCheck: Sendable, Equatable, Codable {
    public let id: CheckID
    public let outcome: CheckOutcome
    public let detail: String

    public init(id: CheckID, outcome: CheckOutcome, detail: String) {
        self.id = id
        self.outcome = outcome
        self.detail = detail
    }
}

public struct CompatibilityReport: Sendable, Equatable, Codable {
    public let checks: [CompatibilityCheck]
    public let configHash: String
    public let testedAt: Date

    public init(checks: [CompatibilityCheck], configHash: String, testedAt: Date) {
        self.checks = checks
        self.configHash = configHash
        self.testedAt = testedAt
    }

    public func check(_ id: CheckID) -> CompatibilityCheck {
        checks.first { $0.id == id } ?? CompatibilityCheck(id: id, outcome: .notTested, detail: "Not part of this run.")
    }

    public func outcome(_ id: CheckID) -> CheckOutcome {
        check(id).outcome
    }

    public var agentMode: AgentMode {
        guard outcome(.text) == .pass else { return .unavailable }
        let toolChecks: [CheckID] = [.tools, .jsonArguments, .toolRoundTrip]
        return toolChecks.allSatisfy { outcome($0) == .pass } ? .agent : .chatOnly
    }

    public func updatedProfile(_ base: CapabilityProfile = CapabilityProfile()) -> CapabilityProfile {
        var profile = base.invalidated(for: configHash)
        func apply(_ capability: ProviderCapability, _ outcome: CheckOutcome, _ detail: String) {
            switch outcome {
            case .pass:
                profile.set(capability, .verified, configHash: configHash, at: testedAt, detail: detail)
            case .unsupported:
                profile.set(capability, .unsupported, configHash: configHash, at: testedAt, detail: detail)
            case .notTested:
                break
            }
        }
        for capability in ProviderCapability.allCases {
            switch capability {
            case .tools:
                let toolChecks: [CheckID] = [.tools, .jsonArguments, .toolRoundTrip]
                let outcomes = toolChecks.map { outcome($0) }
                if outcomes.allSatisfy({ $0 == .pass }) {
                    apply(.tools, .pass, check(.tools).detail)
                } else if let failing = toolChecks.first(where: { outcome($0) == .unsupported }) {
                    apply(.tools, .unsupported, check(failing).detail)
                }
            default:
                let id = CheckID(rawValue: capability.rawValue) ?? .text
                apply(capability, outcome(id), check(id).detail)
            }
        }
        return profile
    }
}

public struct ConnectionTester: Sendable {
    public static let canaryToolName = "read_canary"
    public static let canaryValue = "CANARY-7391"

    public let stepTimeoutSeconds: TimeInterval
    public let cancellationTimeoutSeconds: TimeInterval

    public init(stepTimeoutSeconds: TimeInterval = 120, cancellationTimeoutSeconds: TimeInterval = 2) {
        self.stepTimeoutSeconds = stepTimeoutSeconds
        self.cancellationTimeoutSeconds = cancellationTimeoutSeconds
    }

    public static let canaryTool = ToolSchema(
        name: canaryToolName,
        description: "Returns a synthetic test value for the given name. Read only.",
        parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
    )

    private struct Run: Sendable {
        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage: TokenUsage?
        var finish: FinishReason?
        var failure: Failure?

        var isCleanText: Bool {
            failure == nil && finish == .stop && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        var hasUsage: Bool {
            usage?.inputTokens != nil || usage?.outputTokens != nil
        }
    }

    private enum Failure: Sendable {
        case environment(String)
        case unusable(String)
    }

    public func run(
        streaming: ProviderAdapter,
        nonStreaming: ProviderAdapter? = nil,
        configHash: String,
        now: Date = Date()
    ) async -> CompatibilityReport {
        var checks: [CheckID: CompatibilityCheck] = [:]
        func record(_ id: CheckID, _ outcome: CheckOutcome, _ detail: String) {
            checks[id] = CompatibilityCheck(id: id, outcome: outcome, detail: detail)
        }
        func report() -> CompatibilityReport {
            let ordered = CheckID.allCases.map {
                checks[$0] ?? CompatibilityCheck(id: $0, outcome: .notTested, detail: "Not part of the default canary.")
            }
            return CompatibilityReport(checks: ordered, configHash: configHash, testedAt: now)
        }
        func abort(_ reason: String) -> CompatibilityReport {
            for id in CheckID.allCases where checks[id] == nil {
                record(id, .notTested, reason)
            }
            return report()
        }

        let textRequest = Self.textRequest
        let streamRun = await perform(streaming, textRequest)
        if case .environment(let reason) = streamRun.failure {
            return abort(reason)
        }
        var nonStreamRun: Run?
        if let nonStreaming {
            let run = await perform(nonStreaming, textRequest)
            if case .environment(let reason) = run.failure {
                return abort(reason)
            }
            nonStreamRun = run
        }

        evaluateStreaming(streamRun, record)
        if let nonStreamRun {
            evaluateNonStreaming(nonStreamRun, record)
        } else {
            record(.nonStreaming, .notTested, "No non-stream adapter was supplied.")
        }
        let textPass = streamRun.isCleanText || (nonStreamRun?.isCleanText ?? false)
        if textPass {
            record(.text, .pass, "The model returned plain text and a stop reason.")
        } else {
            record(.text, .unsupported, describe(nonStreamRun?.failure ?? streamRun.failure, fallback: "The model did not return usable text."))
        }

        let usageSource = nonStreamRun ?? streamRun
        if usageSource.hasUsage {
            record(.usage, .pass, "The provider reported token usage.")
        } else {
            record(.usage, .unsupported, "The provider did not report token usage.")
        }
        if streamRun.hasUsage {
            record(.streamUsage, .pass, "The provider reported token usage while streaming.")
        } else {
            record(.streamUsage, .notTested, "Streaming usage needs the stream options probe, which is not part of the default canary.")
        }

        guard textPass else {
            return abort("Skipped because text generation did not work.")
        }

        let toolAdapter: ProviderAdapter = streamRun.isCleanText ? streaming : (nonStreaming ?? streaming)
        await evaluateTools(toolAdapter, record)
        await evaluateCancellation(streaming, record)
        return report()
    }

    private static let textRequest = ProviderRequest(
        messages: [
            ModelMessage(role: .system, content: "You are a connection test. Reply briefly."),
            ModelMessage(role: .user, content: "Reply with the single word: ok")
        ],
        tools: []
    )

    private func evaluateStreaming(_ run: Run, _ record: (CheckID, CheckOutcome, String) -> Void) {
        if run.isCleanText {
            record(.streaming, .pass, "The stream delivered text and ended with a finish reason.")
        } else {
            record(.streaming, .unsupported, describe(run.failure, fallback: "The stream did not end with text and a finish reason."))
        }
    }

    private func evaluateNonStreaming(_ run: Run, _ record: (CheckID, CheckOutcome, String) -> Void) {
        if run.isCleanText {
            record(.nonStreaming, .pass, "The full response body decoded to text and a finish reason.")
        } else {
            record(.nonStreaming, .unsupported, describe(run.failure, fallback: "The full response did not contain text and a finish reason."))
        }
    }

    private func evaluateTools(_ adapter: ProviderAdapter, _ record: (CheckID, CheckOutcome, String) -> Void) async {
        let userMessage = ModelMessage(
            role: .user,
            content: "Call the \(Self.canaryToolName) tool with name \"alpha\", then answer with the value it returns."
        )
        let first = await perform(adapter, ProviderRequest(messages: [userMessage], tools: [Self.canaryTool]))
        if case .environment(let reason) = first.failure {
            for id in [CheckID.tools, .jsonArguments, .toolRoundTrip] { record(id, .notTested, reason) }
            return
        }
        if case .unusable(let reason) = first.failure {
            record(.tools, .unsupported, reason)
            record(.jsonArguments, .notTested, "No tool call was received.")
            record(.toolRoundTrip, .notTested, "No tool call was received.")
            return
        }
        guard let call = first.toolCalls.first, call.name == Self.canaryToolName, first.finish == .toolCalls else {
            record(.tools, .unsupported, "The model answered in text instead of calling the tool.")
            record(.jsonArguments, .notTested, "No tool call was received.")
            record(.toolRoundTrip, .notTested, "No tool call was received.")
            return
        }
        record(.tools, .pass, "The model requested the tool and finished with a tool call reason.")

        let object = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]
        guard let arguments = object, arguments["name"] is String else {
            record(.jsonArguments, .unsupported, "The tool arguments were not a JSON object with the requested field.")
            record(.toolRoundTrip, .notTested, "Skipped because the arguments were invalid.")
            return
        }
        record(.jsonArguments, .pass, "The tool arguments were a complete JSON object.")

        var continuations: [Int: ProviderContinuation] = [:]
        if !first.reasoning.isEmpty {
            continuations[1] = ProviderContinuation(routeID: "default", reasoningContent: first.reasoning)
        }
        let followUp = ProviderRequest(
            messages: [
                userMessage,
                ModelMessage(role: .assistant, content: first.text, toolCalls: [call]),
                ModelMessage(role: .tool, content: "{\"value\":\"\(Self.canaryValue)\"}", toolCallID: call.id)
            ],
            tools: [Self.canaryTool],
            assistantContinuations: continuations
        )
        let second = await perform(adapter, followUp)
        switch second.failure {
        case .environment(let reason):
            record(.toolRoundTrip, .notTested, reason)
        case .unusable(let reason):
            record(.toolRoundTrip, .unsupported, reason)
        case nil:
            if second.isCleanText {
                let echoed = second.text.contains(Self.canaryValue)
                record(.toolRoundTrip, .pass, echoed ? "The model used the tool result in its final answer." : "The model returned a final answer after the tool result.")
            } else {
                record(.toolRoundTrip, .unsupported, "The model did not return a final answer after the tool result.")
            }
        }
    }

    private func evaluateCancellation(_ adapter: ProviderAdapter, _ record: (CheckID, CheckOutcome, String) -> Void) async {
        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: "Count from 1 to 300, separated by spaces.")],
            tools: []
        )
        let probe = ConsumerProbe()
        let consumer = Task {
            do {
                for try await _ in adapter.stream(request) {
                    probe.markEvent()
                }
            } catch {
            }
            probe.markFinished(cancelled: Task.isCancelled)
        }
        guard await probe.waitForEvent(timeout: stepTimeoutSeconds) else {
            consumer.cancel()
            record(.cancellation, .notTested, "The stream produced no events to cancel.")
            return
        }
        consumer.cancel()
        guard await probe.waitForFinish(timeout: cancellationTimeoutSeconds) else {
            record(.cancellation, .unsupported, "The stream kept running after cancellation.")
            return
        }
        if probe.finishedByCancellation {
            record(.cancellation, .pass, "Cancelling the consumer stopped the stream promptly.")
        } else {
            record(.cancellation, .notTested, "The stream finished before cancellation could be tested.")
        }
    }

    private func perform(_ adapter: ProviderAdapter, _ request: ProviderRequest) async -> Run {
        do {
            var run = try await withTimeout(seconds: stepTimeoutSeconds) { () -> Run in
                var collected = Run()
                do {
                    for try await event in adapter.stream(request) {
                        switch event {
                        case .textDelta(let text): collected.text += text
                        case .reasoningDelta(let text): collected.reasoning += text
                        case .toolCall(let call): collected.toolCalls.append(call)
                        case .usage(let usage): collected.usage = usage
                        case .toolCallTruncated: break
                        case .finish(let reason): collected.finish = reason
                        }
                    }
                } catch let error as ProviderError {
                    collected.failure = Self.classify(error)
                }
                return collected
            }
            if run.failure == nil, run.finish == nil {
                run.failure = .unusable("The stream ended without a finish reason.")
            }
            return run
        } catch is TimeoutExpired {
            var run = Run()
            run.failure = .unusable("The provider did not finish within \(Int(stepTimeoutSeconds)) seconds.")
            return run
        } catch {
            var run = Run()
            run.failure = .unusable("The provider failed unexpectedly.")
            return run
        }
    }

    private static func classify(_ error: ProviderError) -> Failure {
        switch error {
        case .unauthorized: return .environment("Authentication was rejected, so nothing else could be tested.")
        case .rateLimited: return .environment("The provider rate limited the test. Try again later.")
        case .server(let status): return .environment("The provider returned server error \(status).")
        case .offline: return .environment("The provider could not be reached.")
        case .malformedResponse(let detail): return .unusable("The response was not usable: \(detail)")
        case .unsupportedParameter(_, let message): return .unusable("The provider rejected a parameter: \(message)")
        case .contextLengthExceeded: return .unusable("The provider said the test request was longer than the model's context window.")
        case .requestRejected(let status, let reason): return .unusable(reason.map { "The provider rejected the request: \($0)" } ?? "The provider rejected the request (status \(status)).")
        case .consentRequired(let host): return .environment("Permission is required before sending code to \(host).")
        }
    }

    private func describe(_ failure: Failure?, fallback: String) -> String {
        switch failure {
        case .environment(let text), .unusable(let text): return text
        case nil: return fallback
        }
    }
}

private final class ConsumerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sawEvent = false
    private var finished = false
    private var cancelled = false

    func markEvent() {
        lock.withLock { sawEvent = true }
    }

    func markFinished(cancelled: Bool) {
        lock.withLock {
            finished = true
            self.cancelled = cancelled
        }
    }

    var finishedByCancellation: Bool {
        lock.withLock { cancelled }
    }

    func waitForEvent(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { sawEvent || finished }
    }

    func waitForFinish(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { finished }
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if lock.withLock(condition) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
