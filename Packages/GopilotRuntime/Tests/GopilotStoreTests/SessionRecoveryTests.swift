import Foundation
import Testing
import GopilotRuntime
@testable import GopilotStore

@Suite("Session journal and recovery")
struct SessionRecoveryTests {
    @Test func persistsCompletedMessagesAndToolLifecycleFromRealRuntime() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "First chat")
        let recorder = try await store.recorder(for: conversation.id)

        let provider = ScriptedProvider(responses: [
            [.event(.toolCall(ToolCall(id: "call_1", name: "echo", argumentsJSON: #"{"b":2,"a":1}"#))), .event(.usage(TokenUsage(inputTokens: 10, outputTokens: 3))), .event(.finish(.toolCalls))],
            [.event(.textDelta("Hello ")), .event(.textDelta("world")), .event(.usage(TokenUsage(inputTokens: 20, outputTokens: 5))), .event(.finish(.stop))]
        ])
        let runtime = GopilotRuntime(provider: provider, tools: ToolRegistry([EchoTool()]))
        let events = try await runtime.startTurn(prompt: "What is up?")
        let terminal = try await recorder.consume(events, prompt: "What is up?", finalMessages: { await runtime.transcript() })
        #expect(terminal == .completed)

        let reopened = try makeStore(sandbox, workspace: workspace)
        let opened = try await reopened.openConversation(id: conversation.id)
        let turn = try #require(opened.conversation.turns.first)
        #expect(opened.isReadOnly)
        #expect(turn.userPrompt == "What is up?")
        #expect(turn.terminal == .completed)
        #expect(turn.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(turn.messages.last?.content == "Hello world")
        let lifecycle = try #require(turn.toolLifecycles.first)
        #expect(lifecycle.state == .completed)
        #expect(lifecycle.outcome == .known)
        #expect(lifecycle.status == "ok")
        #expect(lifecycle.normalizedArgsHash == ContentHash.normalizedArgumentsHash(#"{"a":1,"b":2}"#))
        #expect(turn.usage.inputTokens == 30)
        #expect(turn.usage.outputTokens == 8)
        #expect(turn.usage.modelRequests == 2)
        #expect(turn.evidenceIDs == ["E1"])

        let journal = try String(contentsOf: journalURL(sandbox, workspace: workspace, conversation: conversation.id), encoding: .utf8)
        #expect(!journal.contains("\"Hello \""))
        #expect(!journal.contains("textDelta"))
    }

    @Test func truncatedLastJournalLineIsSkippedAndTheRestLoads() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        for prompt in ["one", "two"] {
            let turn = UUID()
            try await recorder.consume(stream(completedTurnEvents(turn)), prompt: prompt, finalMessages: { [ModelMessage(role: .user, content: prompt), ModelMessage(role: .assistant, content: "answer \(prompt)")] })
        }
        let url = journalURL(sandbox, workspace: workspace, conversation: conversation.id)
        try appendRaw("{\"schemaVersion\":1,\"seq\":99,\"at\":1.0,\"kind\":\"turnSta", to: url)

        let reopened = try makeStore(sandbox, workspace: workspace)
        let opened = try await reopened.openConversation(id: conversation.id)
        #expect(opened.recovery.skippedJournalLines == 1)
        #expect(opened.conversation.turns.map(\.userPrompt) == ["one", "two"])
        #expect(opened.conversation.turns.allSatisfy { $0.terminal == .completed })
        #expect(opened.conversation.turns[1].messages.last?.content == "answer two")
    }

    @Test func garbageLineInTheMiddleDoesNotLoseLaterRecords() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let url = journalURL(sandbox, workspace: workspace, conversation: conversation.id)
        try appendRaw("not json at all\n[1,2,3]\n", to: url)
        let recorder = try await store.recorder(for: conversation.id)
        try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "later", finalMessages: { [ModelMessage(role: .user, content: "later")] })

        let opened = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        #expect(opened.recovery.skippedJournalLines == 2)
        #expect(opened.conversation.turns.map(\.userPrompt) == ["later"])
    }

    @Test func turnWithoutTerminalEventBecomesInterruptedWithUnknownToolOutcomes() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let clock = TestClock()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, workspace: workspace, fileSystem: fileSystem, clock: clock)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        let turn = UUID()
        let events = [
            event(turn, 1, .turnStarted),
            event(turn, 2, .toolRequested, ["callID": "done", "name": "echo"]),
            event(turn, 3, .toolStarted, ["callID": "done", "name": "echo"]),
            event(turn, 4, .toolFinished, ["callID": "done", "status": "ok", "errorCode": ""]),
            event(turn, 5, .toolRequested, ["callID": "mid", "name": "run_tests"]),
            event(turn, 6, .toolStarted, ["callID": "mid", "name": "run_tests"]),
            event(turn, 7, .toolRequested, ["callID": "queued", "name": "read_file"])
        ]
        try await recorder.consume(stream(events), prompt: "run it", finalMessages: { [] })

        let writesBefore = fileSystem.writeCount
        let reopened = try makeStore(sandbox, workspace: workspace, fileSystem: fileSystem, clock: clock)
        let opened = try await reopened.openConversation(id: conversation.id)
        let reopenedTurn = try #require(opened.conversation.turns.first)
        #expect(reopenedTurn.terminal == .interrupted)
        #expect(opened.recovery.interruptedTurnIDs == [turn])
        let byID = Dictionary(uniqueKeysWithValues: reopenedTurn.toolLifecycles.map { ($0.callID, $0) })
        #expect(byID["done"]?.state == .completed)
        #expect(byID["done"]?.outcome == .known)
        #expect(byID["mid"]?.state == .unknown)
        #expect(byID["mid"]?.outcome == .unknown)
        #expect(byID["queued"]?.state == .unknown)
        #expect(Set(opened.recovery.unknownToolCallIDs) == ["mid", "queued"])

        #expect(opened.isReadOnly)
        await #expect(throws: StoreError.conversationReadOnly) { _ = try await reopened.recorder(for: conversation.id) }
        #expect(fileSystem.writeCount == writesBefore)
    }

    @Test func newTurnAfterUnterminatedTurnKeepsTheOldOneInterrupted() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        let first = UUID()
        try await recorder.consume(stream([event(first, 1, .turnStarted), event(first, 2, .toolStarted, ["callID": "x", "name": "run_tests"])]), prompt: "a", finalMessages: { [] })
        let second = UUID()
        try await recorder.consume(stream(completedTurnEvents(second)), prompt: "b", finalMessages: { [ModelMessage(role: .user, content: "b"), ModelMessage(role: .assistant, content: "ok")] })

        let opened = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        #expect(opened.conversation.turns.map(\.terminal) == [.interrupted, .completed])
        #expect(opened.conversation.turns[0].toolLifecycles.first?.outcome == .unknown)
    }

    @Test func assistantToolCallsWithoutResultsAreRepairedForDisplayWithoutFabricatingResults() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        let turn = UUID()
        let calls = [ToolCall(id: "c1", name: "echo", argumentsJSON: "{}"), ToolCall(id: "c2", name: "run_tests", argumentsJSON: "{}")]
        try await recorder.ingest(event(turn, 1, .turnStarted), prompt: "go")
        try await recorder.recordMessages(turnID: turn, messages: [
            ModelMessage(role: .user, content: "go"),
            ModelMessage(role: .assistant, content: "", toolCalls: calls),
            ModelMessage(role: .tool, content: "real result", toolCallID: "c1"),
            ModelMessage(role: .tool, content: "duplicate result", toolCallID: "c1")
        ])
        try await recorder.flush()

        let opened = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        let loaded = try #require(opened.conversation.turns.first)
        #expect(loaded.messages.count == 4)
        let display = loaded.displayMessages
        #expect(display.map(\.message.role) == [.user, .assistant, .tool, .tool])
        #expect(display[2].message.content == "real result")
        #expect(display[2].isSynthetic == false)
        #expect(display[3].message.toolCallID == "c2")
        #expect(display[3].isSynthetic)
        #expect(display[3].outcome == .unknown)
        #expect(display[3].message.content == Turn.unknownOutcomeText)
        #expect(!display[3].message.content.lowercased().contains("retry"))
        #expect(opened.recovery.repairedToolCallIDs == ["c2"])
    }

    @Test func resumeReportsEvidenceNeedingRefreshAndUnlocksWriting() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        let turn = UUID()
        let result = ToolResultEnvelope(callID: "c1", status: .ok, data: "x", evidenceIDs: ["E1", "E2"]).modelContent()
        try await recorder.ingest(event(turn, 1, .turnStarted), prompt: "go")
        try await recorder.recordMessages(turnID: turn, messages: [
            ModelMessage(role: .user, content: "go"),
            ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "echo", argumentsJSON: "{}")]),
            ModelMessage(role: .tool, content: result, toolCallID: "c1")
        ])
        try await recorder.ingest(event(turn, 2, .turnCompleted))

        let reopened = try makeStore(sandbox, workspace: workspace)
        let bytes = Data("evidence".utf8)
        try await reopened.artifacts.put(id: "E1", bytes: bytes, contentHash: ContentHash.sha256Hex(bytes))

        await #expect(throws: StoreError.conversationReadOnly) { _ = try await reopened.recorder(for: conversation.id) }
        let resumed = try await reopened.resume(id: conversation.id, revalidate: { id in await reopened.artifactFreshness(id) })
        #expect(resumed.evidenceIDsNeedingRefresh == ["E2"])
        #expect(resumed.interruptedTurnIDs.isEmpty)
        _ = try await reopened.recorder(for: conversation.id)
        #expect(try await reopened.openConversation(id: conversation.id).isReadOnly == false)
    }

    @Test func diskFullSurfacesTypedErrorKeepsMemoryAndLeavesOldDataReadable() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, workspace: workspace, fileSystem: fileSystem)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "first", finalMessages: { [ModelMessage(role: .user, content: "first"), ModelMessage(role: .assistant, content: "ok")] })
        let url = journalURL(sandbox, workspace: workspace, conversation: conversation.id)
        let before = try Data(contentsOf: url)

        fileSystem.failAppends()
        await #expect(throws: StoreError.diskFull) {
            try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "second", finalMessages: { [ModelMessage(role: .user, content: "second"), ModelMessage(role: .assistant, content: "later")] })
        }
        let snapshot = try #require(await recorder.snapshot())
        #expect(snapshot.turns.map(\.userPrompt) == ["first", "second"])
        #expect(await recorder.pendingRecordCount > 0)
        #expect(await recorder.lastWriteError == .diskFull)
        #expect(try Data(contentsOf: url) == before)

        let reader = try makeStore(sandbox, workspace: workspace)
        let opened = try await reader.openConversation(id: conversation.id)
        #expect(opened.conversation.turns.map(\.userPrompt) == ["first"])
        #expect(opened.recovery.skippedJournalLines == 0)

        fileSystem.failAppends(with: nil)
        try await recorder.flush()
        let recovered = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        #expect(recovered.conversation.turns.map(\.userPrompt) == ["first", "second"])
        #expect(recovered.conversation.turns[1].terminal == .completed)
    }

    @Test func tornAppendFollowedByRetryDoesNotCorruptOrDuplicateRecords() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, workspace: workspace, fileSystem: fileSystem)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        let turn = UUID()
        fileSystem.tearAppends(true)
        let terminal = try await recorder.consume(stream(completedTurnEvents(turn, tool: true)), prompt: "torn", finalMessages: { [ModelMessage(role: .user, content: "torn"), ModelMessage(role: .assistant, content: "fine")] })
        #expect(terminal == .completed)
        #expect(await recorder.pendingRecordCount == 0)

        let opened = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        #expect(opened.recovery.skippedJournalLines == 1)
        #expect(opened.conversation.turns.count == 1)
        let loaded = try #require(opened.conversation.turns.first)
        #expect(loaded.terminal == .completed)
        #expect(loaded.messages.count == 2)
        #expect(loaded.toolLifecycles.count == 1)
        #expect(loaded.usage.modelRequests == 1)
        #expect(loaded.usage.inputTokens == 10)
    }

    @Test func idleStoreOperationsPerformNoWrites() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, workspace: workspace, fileSystem: fileSystem)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        let recorder = try await store.recorder(for: conversation.id)
        try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "p", finalMessages: { [ModelMessage(role: .user, content: "p")] })
        _ = try await store.memory.pin(content: "uses sqlc for queries", provenance: MemoryProvenance(sourceConversationID: conversation.id), sourceRefs: [MemorySourceRef(path: "a.go", contentHash: "h")])
        try await store.flush()

        let baseline = fileSystem.writeCount
        try await store.flush()
        try await recorder.flush()
        try await store.memory.flush()
        try await store.artifacts.flush()
        _ = await store.listConversations()
        _ = try await store.openConversation(id: conversation.id)
        _ = await store.usage()
        _ = await store.memory.recall(query: "sqlc")
        _ = try await store.memory.markStale(against: SnapshotFacts(fileHashes: ["a.go": "h"]))
        _ = try await store.memory.markStale(against: SnapshotFacts(fileHashes: ["a.go": "h"]))
        #expect(fileSystem.writeCount == baseline)
    }

    @Test func nothingIsCreatedOutsideTheWorkspaceDirectory() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Chat")
        _ = try await store.recorder(for: conversation.id)
        let bytes = Data("x".utf8)
        try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: ContentHash.sha256Hex(bytes))
        _ = try await store.memory.pin(content: "note", provenance: MemoryProvenance(sourceConversationID: nil))
        try await store.flush()
        let prefix = sandbox.workspaceRoot(workspace).standardizedFileURL.path
        let files = sandbox.allFiles()
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.standardizedFileURL.path.hasPrefix(prefix) })
    }
}
