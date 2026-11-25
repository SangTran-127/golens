import Foundation

public struct RuntimeLimits: Sendable, Equatable {
    public var maxModelRequests: Int
    public var maxToolCalls: Int
    public var uncountedToolNames: Set<String>

    public init(maxModelRequests: Int = 12, maxToolCalls: Int = 24, uncountedToolNames: Set<String> = ["todo_write"]) {
        self.maxModelRequests = maxModelRequests
        self.maxToolCalls = maxToolCalls
        self.uncountedToolNames = uncountedToolNames
    }
}

public enum RuntimeError: Error, Sendable, Equatable {
    case busy
}

public struct TurnExecutionOptions: Sendable {
    public var preparedMessages: [ModelMessage]?
    public var routeSelection: TurnRouteSelection?
    public var providerOverride: ProviderAdapter?
    public var limits: RuntimeLimits?
    public var inputTokenBudget: Int?
    public var budgetNote: String?

    public init(
        preparedMessages: [ModelMessage]? = nil,
        routeSelection: TurnRouteSelection? = nil,
        providerOverride: ProviderAdapter? = nil,
        limits: RuntimeLimits? = nil,
        inputTokenBudget: Int? = nil,
        budgetNote: String? = nil
    ) {
        self.preparedMessages = preparedMessages
        self.routeSelection = routeSelection
        self.providerOverride = providerOverride
        self.limits = limits
        self.inputTokenBudget = inputTokenBudget
        self.budgetNote = budgetNote
    }
}

public actor GopilotRuntime {
    public nonisolated let sessionID: UUID

    private var provider: ProviderAdapter
    private var tools: ToolRegistry
    private let limits: RuntimeLimits
    private let redactor: @Sendable (String) -> String
    private var history: [ModelMessage]
    private var active: ActiveTurn?
    private var turnRecords: [UUID: [ModelMessage]] = [:]
    private var turnRecordOrder: [UUID] = []
    private static let maxTurnRecords = 64

    private struct ActiveTurn {
        let id: UUID
        let task: Task<Void, Never>
    }

    public init(
        provider: ProviderAdapter,
        tools: ToolRegistry = ToolRegistry(),
        limits: RuntimeLimits = RuntimeLimits(),
        sessionID: UUID = UUID(),
        systemPrompt: String? = nil,
        history: [ModelMessage] = [],
        redactor: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.provider = provider
        self.tools = tools
        self.limits = limits
        self.sessionID = sessionID
        self.redactor = redactor
        self.history = (systemPrompt.map { [ModelMessage(role: .system, content: $0)] } ?? []) + history
    }

    public var isBusy: Bool { active != nil }

    public func transcript() -> [ModelMessage] { history }

    public func turnMessages(_ turnID: UUID) -> [ModelMessage]? { turnRecords[turnID] }

    public func configure(provider: ProviderAdapter? = nil, tools: ToolRegistry, systemPrompt: String?) {
        if let provider { self.provider = provider }
        self.tools = tools
        if let systemPrompt {
            if let first = history.first, first.role == .system {
                history[0] = ModelMessage(role: .system, content: systemPrompt)
            } else {
                history.insert(ModelMessage(role: .system, content: systemPrompt), at: 0)
            }
        }
    }

    public func startTurn(prompt: String, options: TurnExecutionOptions = TurnExecutionOptions()) throws -> AsyncStream<AgentEvent> {
        guard active == nil else { throw RuntimeError.busy }
        let turnID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.run(turnID: turnID, prompt: prompt, options: options, continuation: continuation)
        }
        active = ActiveTurn(id: turnID, task: task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() async {
        guard let turn = active else { return }
        turn.task.cancel()
        await turn.task.value
    }

    private func record(turnID: UUID, messages: [ModelMessage]) {
        if turnRecords[turnID] == nil { turnRecordOrder.append(turnID) }
        turnRecords[turnID] = messages
        while turnRecordOrder.count > Self.maxTurnRecords {
            let dropped = turnRecordOrder.removeFirst()
            turnRecords[dropped] = nil
        }
    }

    private func run(turnID: UUID, prompt: String, options: TurnExecutionOptions, continuation: AsyncStream<AgentEvent>.Continuation) async {
        var sequence = 0
        func emit(_ kind: AgentEventKind, _ payload: [String: String] = [:]) {
            sequence += 1
            continuation.yield(AgentEvent(sessionID: sessionID, turnID: turnID, sequence: sequence, kind: kind, payload: payload))
        }
        func finish(_ kind: AgentEventKind, _ payload: [String: String] = [:]) async {
            emit(kind, payload)
            clearActive(turnID)
            continuation.finish()
        }

        let turnLimits = options.limits ?? limits
        let finalNote = options.budgetNote ?? Self.budgetNote
        let turnProvider = options.providerOverride ?? provider
        let routeID = options.routeSelection?.routeID
        let effort = options.routeSelection?.effort ?? .default
        let startingHistory = history
        let userMessage = ModelMessage(role: .user, content: prompt)
        var messages = options.preparedMessages ?? (history + [userMessage])
        let protectedPrefix = messages.count
        var rawHistoryAppend: [ModelMessage] = [userMessage]
        var turnContinuations: [Int: ProviderContinuation] = [:]
        var modelRequests = 0
        var toolCallsUsed = 0
        var toolCallsCompleted = 0
        var toolCallsStarted = 0
        var lengthRecoveries = 0
        var contextRetries = 0
        var warnings: [String] = []
        var startedPayload: [String: String] = [:]
        if let selection = options.routeSelection {
            startedPayload["gatewayID"] = selection.gatewayID
            startedPayload["routeID"] = selection.routeID
            startedPayload["effort"] = selection.effort.rawValue
        }
        emit(.turnStarted, startedPayload)

        func appendCompleted(_ message: ModelMessage) {
            messages.append(message)
            rawHistoryAppend.append(message)
        }

        func closedAppend(note: String?) -> [ModelMessage] {
            var append = rawHistoryAppend
            if let lastCallIndex = append.lastIndex(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }) {
                let answered = Set(append[(lastCallIndex + 1)...].compactMap { $0.role == .tool ? $0.toolCallID : nil })
                for call in append[lastCallIndex].toolCalls where !answered.contains(call.id) {
                    let missing = ToolResultEnvelope.failure(callID: call.id, code: .cancelled, message: "Not run: the turn stopped before this call ran.")
                    append.append(ModelMessage(role: .tool, content: missing.modelContent(), toolCallID: call.id))
                }
            }
            if let note { append.append(ModelMessage(role: .assistant, content: note)) }
            return append
        }

        func commitHistory(note: String? = nil) {
            let append = closedAppend(note: note)
            if options.preparedMessages != nil {
                history.append(contentsOf: append)
            } else {
                history = startingHistory + append
            }
            record(turnID: turnID, messages: append)
        }

        func warningPayload(_ base: [String: String]) -> [String: String] {
            var payload = base
            if !warnings.isEmpty { payload["warnings"] = warnings.joined(separator: ",") }
            return payload
        }

        func finishInterrupted(_ kind: AgentEventKind, _ payload: [String: String]) async {
            var final = payload
            final["toolCallsStarted"] = String(toolCallsStarted)
            final["toolCallsCompleted"] = String(toolCallsCompleted)
            if toolCallsStarted > 0 {
                let reason = kind == .turnCancelled ? "was stopped by the user" : "failed"
                commitHistory(note: "[Gopilot note: this turn \(reason) before it finished. The tool calls above already ran and their effects remain. Do not repeat edits that already succeeded; re-read files before changing them again.]")
                final["historyKept"] = "true"
            } else {
                final["historyKept"] = "false"
            }
            await finish(kind, warningPayload(final))
        }

        func finishBudgetExceeded(limit: String, partialText: String = "") async {
            if !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendCompleted(ModelMessage(role: .assistant, content: partialText))
            }
            if toolCallsCompleted > 0 || !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitHistory()
            }
            await finish(.turnBudgetExceeded, warningPayload([
                "limit": limit,
                "toolCallsUsed": String(toolCallsUsed),
                "toolCallsCompleted": String(toolCallsCompleted)
            ]))
        }

        while true {
            if Task.isCancelled {
                await finishInterrupted(.turnCancelled, [:])
                return
            }
            guard modelRequests < turnLimits.maxModelRequests else {
                await finishBudgetExceeded(limit: "modelRequests")
                return
            }
            let finalRequest = turnLimits.maxModelRequests > 1 && modelRequests == turnLimits.maxModelRequests - 1
            modelRequests += 1
            emit(.activity, ["label": finalRequest ? "Summarizing findings" : "Requesting model"])
            var requestTools = tools.schemas
            if finalRequest { requestTools = [] }
            if let budget = options.inputTokenBudget, budget > 0 {
                let compaction = TurnContextCompactor.compact(messages, tools: requestTools, budget: budget, protectedPrefixCount: protectedPrefix)
                if compaction.didCompact {
                    messages = compaction.messages
                    if !warnings.contains("contextCompacted") { warnings.append("contextCompacted") }
                    emit(.activity, [
                        "label": "Compacting earlier steps to fit the context window",
                        "compactedToolResults": String(compaction.compactedToolResults),
                        "compactedWritePayloads": String(compaction.compactedWritePayloads)
                    ])
                }
            }
            var requestMessages = messages
            if finalRequest {
                requestMessages.append(ModelMessage(role: .user, content: finalNote))
            }

            var text = ""
            var reasoningText = ""
            var lastReasoningEmitCount = 0
            var lastEmittedReasoningPreview = ""
            var calls: [ToolCall] = []
            var truncatedCalls: [String] = []
            var finishReason: FinishReason?
            let request = ProviderRequest(
                messages: requestMessages,
                tools: requestTools,
                routeOverride: routeID,
                reasoningEffort: effort,
                assistantContinuations: turnContinuations
            )
            do {
                for try await event in turnProvider.stream(request) {
                    if Task.isCancelled { throw CancellationError() }
                    switch event {
                    case .textDelta(let delta):
                        text += delta
                        emit(.textDelta, ["text": delta])
                    case .reasoningDelta(let delta):
                        reasoningText += delta
                        if text.isEmpty,
                           (delta.contains("\n") || delta.contains(". ") || reasoningText.count - lastReasoningEmitCount >= 60) {
                            lastReasoningEmitCount = reasoningText.count
                            let preview = Self.latestReasoningLine(from: reasoningText)
                            if !preview.isEmpty, preview != lastEmittedReasoningPreview {
                                lastEmittedReasoningPreview = preview
                                emit(.activity, ["label": "Thinking", "reasoningPreview": preview])
                            }
                        }
                    case .toolCall(let call):
                        calls.append(call)
                        emit(.toolRequested, ["callID": call.id, "name": call.name])
                    case .toolCallTruncated(let name):
                        truncatedCalls.append(name.isEmpty ? "a tool" : name)
                    case .usage(let usage):
                        var usagePayload: [String: String] = [
                            "inputTokens": usage.inputTokens.map(String.init) ?? "unknown",
                            "outputTokens": usage.outputTokens.map(String.init) ?? "unknown"
                        ]
                        if let reasoning = usage.reasoningTokens {
                            usagePayload["reasoningTokens"] = String(reasoning)
                        }
                        if let model = usage.responseModelID, !model.isEmpty {
                            usagePayload["responseModelID"] = model
                        }
                        emit(.usageUpdated, usagePayload)
                    case .finish(let reason):
                        finishReason = reason
                    }
                }
            } catch is CancellationError {
                await finishInterrupted(.turnCancelled, [:])
                return
            } catch ProviderError.contextLengthExceeded {
                if contextRetries == 0 {
                    contextRetries += 1
                    let current = TurnContextCompactor.estimateTokens(messages, tools: requestTools)
                    let compaction = TurnContextCompactor.compact(
                        messages,
                        tools: requestTools,
                        budget: max(1, Int(Double(current) * 0.6)),
                        protectedPrefixCount: protectedPrefix,
                        keepRecentToolResults: 1
                    )
                    if compaction.didCompact {
                        messages = compaction.messages
                        modelRequests -= 1
                        if !warnings.contains("contextCompacted") { warnings.append("contextCompacted") }
                        emit(.activity, [
                            "label": "Compacting earlier steps to fit the context window",
                            "compactedToolResults": String(compaction.compactedToolResults),
                            "compactedWritePayloads": String(compaction.compactedWritePayloads),
                            "warning": "contextLengthExceeded"
                        ])
                        continue
                    }
                }
                await finishInterrupted(.turnFailed, Self.failurePayload(ProviderError.contextLengthExceeded))
                return
            } catch {
                await finishInterrupted(.turnFailed, Self.failurePayload(error))
                return
            }
            if Task.isCancelled {
                await finishInterrupted(.turnCancelled, [:])
                return
            }

            guard let reason = finishReason else {
                await finishInterrupted(.turnFailed, ["code": "truncated", "message": "Response ended before completion."])
                return
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason == .length || !truncatedCalls.isEmpty {
                let cutCalls = truncatedCalls + (reason == .length ? calls.map(\.name) : [])
                let toolWasCut = !cutCalls.isEmpty || trimmedText.isEmpty
                if !toolWasCut {
                    appendCompleted(ModelMessage(role: .assistant, content: text))
                    if !warnings.contains("outputTruncated") { warnings.append("outputTruncated") }
                    commitHistory()
                    await finish(.turnCompleted, warningPayload([:]))
                    return
                }
                let names = cutCalls.isEmpty ? "a response" : Array(Set(cutCalls)).sorted().joined(separator: ", ")
                if !warnings.contains("outputTruncated") { warnings.append("outputTruncated") }
                if lengthRecoveries == 0 && !finalRequest {
                    lengthRecoveries += 1
                    if !trimmedText.isEmpty {
                        appendCompleted(ModelMessage(role: .assistant, content: text))
                    }
                    messages.append(ModelMessage(
                        role: .user,
                        content: "[IDE notice] Your previous response was cut off by the output token limit while writing \(names), so it was not run. Keep reasoning brief. If you were writing a large file, create it with a shorter write_file call and then add the rest with edit_file in several smaller steps."
                    ))
                    emit(.activity, ["label": "Response was cut off; continuing", "warning": "outputTruncated", "tools": names])
                    continue
                }
                await finishInterrupted(.turnFailed, [
                    "code": "outputTruncated",
                    "message": "The model's response was cut off by its output limit while writing \(names), so it was not run.",
                    "tools": names
                ])
                return
            }
            if calls.isEmpty {
                appendCompleted(ModelMessage(role: .assistant, content: text))
                commitHistory()
                await finish(.turnCompleted, warningPayload([:]))
                return
            }
            if finalRequest {
                await finishBudgetExceeded(limit: "modelRequests", partialText: text)
                return
            }
            if Set(calls.map(\.id)).count != calls.count {
                await finishInterrupted(.turnFailed, ["code": "protocolError", "message": "Duplicate tool call id in one response."])
                return
            }
            let countedCalls = calls.filter { !turnLimits.uncountedToolNames.contains($0.name) }.count
            guard toolCallsUsed + countedCalls <= turnLimits.maxToolCalls else {
                await finishBudgetExceeded(limit: "toolCalls", partialText: text)
                return
            }

            let assistantIndex = messages.count
            appendCompleted(ModelMessage(role: .assistant, content: text, toolCalls: calls))
            if !reasoningText.isEmpty {
                turnContinuations[assistantIndex] = ProviderContinuation(
                    routeID: routeID ?? "default",
                    reasoningContent: reasoningText
                )
            }
            for call in calls {
                emit(.toolStarted, [
                    "callID": call.id,
                    "name": call.name,
                    "arguments": ToolEventSummary.arguments(call.argumentsJSON, redact: redactor)
                ])
                toolCallsStarted += 1
                let result = await tools.dispatch(call)
                let safeData = UntrustedData.wrap(kind: "tool_result", source: call.name, content: result.data, salt: sessionID.uuidString)
                let spotlighted = ToolResultEnvelope(
                    callID: result.callID,
                    status: result.status,
                    data: safeData,
                    evidenceIDs: result.evidenceIDs,
                    sourceSnapshotID: result.sourceSnapshotID,
                    truncated: result.truncated,
                    nextCursor: result.nextCursor,
                    errorCode: result.errorCode,
                    retryable: result.retryable
                )
                appendCompleted(ModelMessage(role: .tool, content: spotlighted.modelContent(), toolCallID: call.id))
                toolCallsCompleted += 1
                if Task.isCancelled {
                    await finishInterrupted(.turnCancelled, [:])
                    return
                }
                if !turnLimits.uncountedToolNames.contains(call.name) {
                    toolCallsUsed += 1
                }
                var finishedPayload = [
                    "callID": call.id,
                    "name": call.name,
                    "status": result.status.rawValue,
                    "errorCode": result.errorCode?.rawValue ?? "",
                    "summary": ToolEventSummary.summary(toolName: call.name, resultData: result.data, redact: redactor),
                    "result": ToolEventSummary.excerpt(result.data, redact: redactor)
                ]
                if result.status == .error {
                    finishedPayload["detail"] = String(redactor(result.data).prefix(300))
                    finishedPayload["retryable"] = result.retryable ? "true" : "false"
                }
                emit(.toolFinished, finishedPayload)
            }
        }
    }

    static let budgetNote = "[IDE notice] The tool budget for this request is used up, so no more tools are available. Answer now using only the evidence you already gathered. State clearly which parts you could not verify or read, and what the developer could check next."

    private static func latestReasoningLine(from raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "" }
        return String(last.prefix(220))
    }

    private func clearActive(_ turnID: UUID) {
        if active?.id == turnID { active = nil }
    }

    private static func failurePayload(_ error: Error) -> [String: String] {
        guard let providerError = error as? ProviderError else {
            return ["code": "unknown", "message": error.localizedDescription]
        }
        switch providerError {
        case .unauthorized:
            return ["code": "unauthorized", "message": "The provider rejected authentication."]
        case .rateLimited(let retryAfter):
            return ["code": "rateLimited", "message": "Rate limited.", "retryAfterSeconds": retryAfter.map(String.init) ?? ""]
        case .server(let status):
            return ["code": "server", "message": "Provider error \(status).", "status": String(status)]
        case .offline:
            return ["code": "offline", "message": "Could not reach the provider."]
        case .malformedResponse(let detail):
            return ["code": "malformedResponse", "message": detail]
        case .unsupportedParameter(let field, let message):
            return ["code": "unsupportedParameter", "field": field, "message": message]
        case .contextLengthExceeded:
            return ["code": "contextLengthExceeded", "message": "The conversation no longer fits in this model's context window."]
        case .requestRejected(let status, let reason):
            return ["code": "requestRejected", "status": String(status), "message": reason ?? ""]
        case .consentRequired(let host):
            return ["code": "consentRequired", "message": "Permission is required before sending code to \(host)."]
        }
    }
}
