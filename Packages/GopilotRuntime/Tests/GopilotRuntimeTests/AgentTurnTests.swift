import Foundation
import Testing
@testable import GopilotRuntime

private struct FileWriteTool: GopilotTool {
    let schema = ToolSchema(
        name: "write_file",
        description: "Writes a file.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
    )

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        ToolResultEnvelope(
            callID: callID,
            status: .ok,
            data: #"{"outcome":"found","proposalID":"P1","proposalStatus":"applied","projectChanged":true,"files":[{"path":"pkg/a.go","operation":"create"}],"next":"Applied with key sk-live-secret-123"}"#,
            evidenceIDs: ["E1"]
        )
    }
}

private struct TodoTool: GopilotTool {
    let schema = ToolSchema(name: "todo_write", description: "Plan.", parametersJSON: #"{"type":"object","additionalProperties":true}"#)

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        ToolResultEnvelope(callID: callID, status: .ok, data: #"{"outcome":"updated","todos":[{"id":"1","content":"Edit handler","status":"in_progress"}],"totalCount":1,"completedCount":0}"#)
    }
}

private struct BigResultTool: GopilotTool {
    let schema = ToolSchema(name: "read_big", description: "Reads a lot.", parametersJSON: #"{"type":"object","additionalProperties":true}"#)

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        ToolResultEnvelope(callID: callID, status: .ok, data: String(repeating: "lorem ipsum dolor sit amet ", count: 400))
    }
}

private struct WaitingTool: GopilotTool {
    let schema = ToolSchema(name: "wait", description: "Waits.", parametersJSON: #"{"type":"object","additionalProperties":true}"#)

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        try await Task.sleep(for: .seconds(60))
        return ToolResultEnvelope(callID: callID, status: .ok, data: "done")
    }
}

private func run(_ runtime: GopilotRuntime, _ prompt: String = "go", options: TurnExecutionOptions = TurnExecutionOptions()) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in try await runtime.startTurn(prompt: prompt, options: options) { events.append(event) }
    return events
}

private func call(_ id: String, _ name: String, _ args: String = "{}") -> ProviderEvent {
    .toolCall(ToolCall(id: id, name: name, argumentsJSON: args))
}

private func object(_ text: String?) -> [String: Any] {
    guard let text, let data = text.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return value
}

private let redactSecret: @Sendable (String) -> String = { $0.replacingOccurrences(of: "sk-live-secret-123", with: "[REDACTED]") }

@Suite("Tool event payloads")
struct ToolEventPayloadTests {
    @Test func toolEventsCarryRedactedArgumentsSummaryAndExcerptInEveryBuildConfiguration() async throws {
        let content = String(repeating: "x", count: 600) + " sk-live-secret-123"
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "pkg/a.go", "content": content]), as: UTF8.self)
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "write_file", args)), .event(.finish(.toolCalls))],
            [.event(.textDelta("Done.")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]), redactor: redactSecret)
        let events = try await run(runtime)

        let started = try #require(events.first { $0.kind == .toolStarted })
        let arguments = object(started.payload["arguments"])
        #expect(arguments["path"] as? String == "pkg/a.go")
        #expect((arguments["content"] as? String)?.hasPrefix("[") == true)
        #expect(started.payload["arguments"]?.contains("sk-live-secret-123") == false)
        #expect((started.payload["arguments"]?.utf8.count ?? 0) <= ToolEventSummary.argumentsLimit)

        let finished = try #require(events.first { $0.kind == .toolFinished })
        let summary = object(finished.payload["summary"])
        #expect(summary["tool"] as? String == "write_file")
        #expect(summary["proposalStatus"] as? String == "applied")
        #expect((summary["files"] as? [[String: Any]])?.first?["path"] as? String == "pkg/a.go")
        #expect(finished.payload["summary"]?.contains("sk-live-secret-123") == false)
        #expect(finished.payload["result"]?.contains("[REDACTED]") == true)
        #expect(finished.payload["result"]?.contains("sk-live-secret-123") == false)
    }

    @Test func todoChecklistTravelsInTheFinishedSummary() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "todo_write", #"{"todos":[{"id":"1","content":"Edit handler","status":"in_progress"}]}"#)), .event(.finish(.toolCalls))],
            [.event(.textDelta("ok")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([TodoTool()]))
        let events = try await run(runtime)
        let finished = try #require(events.first { $0.kind == .toolFinished })
        let todos = object(finished.payload["summary"])["todos"] as? [[String: Any]]
        #expect(todos?.first?["content"] as? String == "Edit handler")
        #expect(todos?.first?["status"] as? String == "in_progress")
    }

    @Test func oversizedArgumentsKeepKeyFieldsAsValidJSON() {
        var raw: [String: Any] = ["path": "internal/api/handler.go"]
        for index in 0..<40 { raw["field\(index)"] = "value \(index) with some text" }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        let compact = ToolEventSummary.arguments(text, redact: { $0 })
        #expect(compact.utf8.count <= ToolEventSummary.argumentsLimit)
        #expect(object(compact)["path"] as? String == "internal/api/handler.go")
    }
}

@Suite("Agent turn resilience")
struct AgentTurnTests {
    @Test func stopAfterACompletedToolKeepsHistoryAndANote() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "write_file", #"{"path":"a.go","content":"package a"}"#)), .event(.finish(.toolCalls))],
            [.event(.textDelta("thinking")), .hang]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]))
        let stream = try await runtime.startTurn(prompt: "go")
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
            if event.kind == .textDelta { await runtime.stop() }
        }
        let terminal = try #require(events.last)
        #expect(terminal.kind == .turnCancelled)
        #expect(terminal.payload["historyKept"] == "true")
        #expect(terminal.payload["toolCallsCompleted"] == "1")
        let transcript = await runtime.transcript()
        #expect(transcript.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(transcript.last?.content.contains("stopped by the user") == true)
        #expect(await runtime.turnMessages(terminal.turnID) == transcript)
    }

    @Test func failureAfterAToolKeepsHistory() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "write_file", #"{"path":"a.go","content":"package a"}"#)), .event(.finish(.toolCalls))],
            [.fail(.server(status: 502))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]))
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnFailed)
        #expect(events.last?.payload["historyKept"] == "true")
        let transcript = await runtime.transcript()
        #expect(transcript.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(transcript.last?.content.contains("failed before it finished") == true)
    }

    @Test func stopDuringAToolClosesTheOpenCallWithACancelledResult() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "wait")), .event(call("c2", "wait")), .event(.finish(.toolCalls))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([WaitingTool()]))
        let stream = try await runtime.startTurn(prompt: "go")
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
            if event.kind == .toolStarted { await runtime.stop() }
        }
        #expect(events.last?.kind == .turnCancelled)
        let transcript = await runtime.transcript()
        let toolIDs = transcript.filter { $0.role == .tool }.compactMap(\.toolCallID)
        #expect(Set(toolIDs) == ["c1", "c2"])
        #expect(transcript.last?.role == .assistant)
    }

    @Test func failureBeforeAnyToolDoesNotTouchHistoryOrRecordATurn() async throws {
        let provider = ScriptedProvider(responses: [[.fail(.offline)]])
        let runtime = GopilotRuntime(provider: provider)
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnFailed)
        #expect(events.last?.payload["historyKept"] == "false")
        #expect(await runtime.transcript().isEmpty)
        #expect(await runtime.turnMessages(events.last!.turnID) == nil)
    }

    @Test func turnMessagesBelongToTheirOwnTurn() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("first")), .event(.finish(.stop))],
            [.fail(.offline)]
        ])
        let runtime = GopilotRuntime(provider: provider)
        let first = try await run(runtime, "one")
        let second = try await run(runtime, "two")
        let firstMessages = await runtime.turnMessages(first.last!.turnID)
        #expect(firstMessages?.map(\.content) == ["one", "first"])
        #expect(await runtime.turnMessages(second.last!.turnID) == nil)
    }

    @Test func cutToolCallContinuesOnceWithAVisibleWarning() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(.textDelta("Creating the file.")), .event(.toolCallTruncated(name: "write_file")), .event(.finish(.length))],
            [.event(.textDelta("Done in smaller steps.")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]))
        let events = try await run(runtime)
        #expect(events.contains { $0.kind == .activity && $0.payload["warning"] == "outputTruncated" && $0.payload["tools"] == "write_file" })
        #expect(events.last?.kind == .turnCompleted)
        #expect(events.last?.payload["warnings"]?.contains("outputTruncated") == true)
        let requests = await provider.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].messages.last?.content.contains("cut off by the output token limit") == true)
    }

    @Test func cutToolCallTwiceFailsWithAnOutputTruncatedCode() async throws {
        let cut: [ScriptStep] = [.event(.toolCallTruncated(name: "write_file")), .event(.finish(.length))]
        let provider = ScriptedProvider(responses: [cut, cut])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]))
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnFailed)
        #expect(events.last?.payload["code"] == "outputTruncated")
        #expect(events.contains { $0.kind == .turnCompleted } == false)
    }

    @Test func cutTextAnswerCompletesWithAWarning() async throws {
        let provider = ScriptedProvider(responses: [[.event(.textDelta("Partial answer")), .event(.finish(.length))]])
        let runtime = GopilotRuntime(provider: provider)
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnCompleted)
        #expect(events.last?.payload["warnings"] == "outputTruncated")
    }

    @Test func contextLengthErrorCompactsOlderResultsAndRetriesOnce() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "read_big")), .event(call("c2", "read_big")), .event(.finish(.toolCalls))],
            [.fail(.contextLengthExceeded)],
            [.event(.textDelta("Answer.")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([BigResultTool()]), limits: RuntimeLimits(maxModelRequests: 3))
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnCompleted, "\(events.last?.payload ?? [:])")
        #expect(events.contains { $0.kind == .activity && $0.payload["warning"] == "contextLengthExceeded" })
        let requests = await provider.recordedRequests()
        #expect(requests.count == 3)
        let retried = requests[2].messages.filter { $0.role == .tool }
        #expect(retried.first?.content.contains("\"compacted\":true") == true)
        #expect(retried.last?.content.contains("\"compacted\":true") == false)
    }

    @Test func contextLengthErrorWithNothingToCompactFailsClearly() async throws {
        let provider = ScriptedProvider(responses: [[.fail(.contextLengthExceeded)]])
        let runtime = GopilotRuntime(provider: provider)
        let events = try await run(runtime)
        #expect(events.last?.kind == .turnFailed)
        #expect(events.last?.payload["code"] == "contextLengthExceeded")
    }

    @Test func inputBudgetCompactsBeforeTheRequestIsSent() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("c1", "read_big")), .event(call("c2", "read_big")), .event(call("c3", "read_big")), .event(call("c4", "read_big")), .event(call("c5", "read_big")), .event(call("c6", "read_big")), .event(.finish(.toolCalls))],
            [.event(.textDelta("ok")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([BigResultTool()]))
        let events = try await run(runtime, options: TurnExecutionOptions(inputTokenBudget: 3_000))
        #expect(events.last?.kind == .turnCompleted)
        #expect(events.last?.payload["warnings"]?.contains("contextCompacted") == true)
        let requests = await provider.recordedRequests()
        let second = requests[1].messages.filter { $0.role == .tool }
        #expect(second.filter { $0.content.contains("\"compacted\":true") }.count == 2)
        #expect(second.suffix(4).allSatisfy { !$0.content.contains("\"compacted\":true") })
        let transcript = await runtime.transcript()
        #expect(transcript.filter { $0.role == .tool }.allSatisfy { !$0.content.contains("\"compacted\":true") })
    }

    @Test func compactorReplacesOldWritePayloadsWithAHashReference() {
        let content = String(repeating: "func f() {}\n", count: 200)
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["path": "a.go", "content": content]), as: UTF8.self)
        let messages: [ModelMessage] = [
            ModelMessage(role: .user, content: "go"),
            ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "w1", name: "write_file", argumentsJSON: args)]),
            ModelMessage(role: .tool, content: #"{"status":"ok","callID":"w1","data":"ok"}"#, toolCallID: "w1"),
            ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "w2", name: "write_file", argumentsJSON: args)]),
            ModelMessage(role: .tool, content: #"{"status":"ok","callID":"w2","data":"ok"}"#, toolCallID: "w2")
        ]
        let result = TurnContextCompactor.compact(messages, budget: 10, protectedPrefixCount: 1)
        #expect(result.compactedWritePayloads == 1)
        let first = result.messages[1].toolCalls[0].argumentsJSON
        #expect(first.contains("omitted from context"))
        #expect(first.contains("sha256"))
        #expect(object(first)["path"] as? String == "a.go")
        #expect(result.messages[3].toolCalls[0].argumentsJSON == args)
        #expect(result.messages.map(\.role) == messages.map(\.role))
    }

    @Test func uncountedToolsDoNotUseTheToolBudget() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("t1", "todo_write")), .event(.finish(.toolCalls))],
            [.event(call("t2", "todo_write")), .event(.finish(.toolCalls))],
            [.event(call("w1", "write_file", #"{"path":"a.go","content":"x"}"#)), .event(.finish(.toolCalls))],
            [.event(.textDelta("done")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([TodoTool(), FileWriteTool()]))
        let options = TurnExecutionOptions(limits: RuntimeLimits(maxModelRequests: 6, maxToolCalls: 1))
        let events = try await run(runtime, options: options)
        #expect(events.last?.kind == .turnCompleted)
    }

    @Test func perTurnLimitsAndFinalNoteOverrideTheDefaults() async throws {
        let provider = ScriptedProvider(responses: [
            [.event(call("w1", "write_file", #"{"path":"a.go","content":"x"}"#)), .event(.finish(.toolCalls))],
            [.event(.textDelta("Changed a.go.")), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([FileWriteTool()]), limits: RuntimeLimits(maxModelRequests: 12))
        let note = "[IDE notice] Agent budget note."
        let events = try await run(runtime, options: TurnExecutionOptions(limits: RuntimeLimits(maxModelRequests: 2, maxToolCalls: 5), budgetNote: note))
        #expect(events.last?.kind == .turnCompleted)
        let requests = await provider.recordedRequests()
        #expect(requests[1].tools.isEmpty)
        #expect(requests[1].messages.last?.content == note)
    }
}
