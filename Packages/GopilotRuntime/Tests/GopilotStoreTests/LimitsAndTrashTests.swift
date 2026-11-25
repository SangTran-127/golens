import Foundation
import Testing
import GopilotRuntime
@testable import GopilotStore

@Suite("Limits, trash, eviction and export")
struct LimitsAndTrashTests {
    private func addTurn(_ store: WorkspaceStore, _ id: UUID, prompt: String = "p", reply: String = "r") async throws {
        let recorder = try await store.recorder(for: id)
        try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: prompt, finalMessages: { [ModelMessage(role: .user, content: prompt), ModelMessage(role: .assistant, content: reply)] })
    }

    @Test func trashHidesConversationAndUndoRestoresWithinWindow() async throws {
        let sandbox = Sandbox()
        let clock = TestClock()
        let store = try makeStore(sandbox, clock: clock)
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "T")
        try await addTurn(store, conversation.id)

        let receipt = try await store.trash(id: conversation.id)
        #expect(receipt.undoDeadline > receipt.trashedAt)
        #expect(await store.listConversations().isEmpty)
        #expect(await store.trashedConversations().map(\.id) == [conversation.id])
        #expect(try await store.openConversation(id: conversation.id).conversation.turns.count == 1)

        clock.advance(3600)
        try await store.undoTrash(id: conversation.id)
        #expect(await store.listConversations().map(\.id) == [conversation.id])
        await #expect(throws: StoreError.notInTrash) { try await store.undoTrash(id: conversation.id) }
    }

    @Test func undoFailsAfterTheWindowAndExpiredTrashIsListedForExplicitDeletion() async throws {
        let sandbox = Sandbox()
        let clock = TestClock()
        let limits = StoreLimits(trashUndoWindow: 100)
        let store = try makeStore(sandbox, limits: limits, clock: clock)
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "T")
        _ = try await store.trash(id: conversation.id)
        clock.advance(101)
        await #expect(throws: StoreError.undoWindowExpired) { try await store.undoTrash(id: conversation.id) }
        #expect(await store.expiredTrash().map(\.id) == [conversation.id])
        #expect(try await store.openConversation(id: conversation.id).conversation.title == "T")
    }

    @Test func trashSurvivesRestart() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "T")
        _ = try await store.trash(id: conversation.id)
        let reopened = try makeStore(sandbox, workspace: workspace)
        #expect(await reopened.listConversations().isEmpty)
        #expect(await reopened.trashedConversations().count == 1)
    }

    @Test func permanentDeleteReportsDerivedNotesAndNeverDeletesThemSilently() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "T")
        let other = try await store.createConversation(providerID: "p", modelID: "m", title: "Other")
        let derived = try await store.memory.pin(content: "derived from first chat", provenance: MemoryProvenance(sourceConversationID: conversation.id))
        _ = try await store.memory.pin(content: "derived from other chat", provenance: MemoryProvenance(sourceConversationID: other.id))
        _ = try await store.trash(id: conversation.id)

        let report = try await store.permanentlyDelete(id: conversation.id)
        #expect(report.derivedNotes.map(\.id) == [derived.id])
        #expect(!FileManager.default.fileExists(atPath: journalURL(sandbox, workspace: workspace, conversation: conversation.id).path))
        await #expect(throws: StoreError.notFound) { _ = try await store.openConversation(id: conversation.id) }
        #expect(await store.memory.notes().count == 2)
        #expect(await store.trashedConversations().isEmpty)

        try await store.memory.delete(id: derived.id)
        #expect(await store.memory.notes().count == 1)
        let reopened = try makeStore(sandbox, workspace: workspace)
        #expect(await reopened.listConversations(includeTrashed: true).map(\.id) == [other.id])
    }

    @Test func evictionOfOldConversationsNeedsAnExplicitConfirmationFromAPreview() async throws {
        let sandbox = Sandbox()
        let clock = TestClock()
        let store = try makeStore(sandbox, limits: StoreLimits(maxConversations: 3), clock: clock)
        var ids: [UUID] = []
        for index in 0..<3 {
            let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "C\(index)")
            ids.append(conversation.id)
            clock.advance(10)
        }
        await #expect(throws: StoreError.conversationLimitReached) { _ = try await store.createConversation(providerID: "p", modelID: "m", title: "C3") }
        #expect(await store.listConversations().count == 3)

        let preview = await store.previewEviction()
        #expect(preview.candidates.map(\.id) == [ids[0]])
        #expect(await store.listConversations().count == 3)

        await #expect(throws: StoreError.invalidConfirmation) {
            _ = try await store.evict(confirming: EvictionPreview(candidates: preview.candidates, reclaimedBytes: preview.reclaimedBytes, token: EvictionToken(rawValue: "forged")))
        }
        #expect(await store.listConversations().count == 3)

        let removed = try await store.evict(confirming: preview)
        #expect(removed == [ids[0]])
        #expect(Set(await store.listConversations().map(\.id)) == Set(ids.dropFirst()))
        _ = try await store.createConversation(providerID: "p", modelID: "m", title: "C3")
    }

    @Test func stalePreviewIsRejectedAfterTheStoreChanged() async throws {
        let sandbox = Sandbox()
        let clock = TestClock()
        let store = try makeStore(sandbox, limits: StoreLimits(maxConversations: 2), clock: clock)
        let first = try await store.createConversation(providerID: "p", modelID: "m", title: "A")
        clock.advance(5)
        let second = try await store.createConversation(providerID: "p", modelID: "m", title: "B")
        let preview = await store.previewEviction()
        #expect(preview.candidates.map(\.id) == [first.id])
        _ = try await store.trash(id: first.id)
        await #expect(throws: StoreError.invalidConfirmation) { _ = try await store.evict(confirming: preview) }
        #expect(Set(await store.listConversations(includeTrashed: true).map(\.id)) == [first.id, second.id])
    }

    @Test func transcriptByteLimitSurfacesTypedErrorAndKeepsPendingRecords() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace, limits: StoreLimits(maxTranscriptBytes: 1500))
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "T")
        let recorder = try await store.recorder(for: conversation.id)
        let big = String(repeating: "z", count: 4000)
        await #expect(throws: StoreError.transcriptLimitReached) {
            try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "p", finalMessages: { [ModelMessage(role: .user, content: "p"), ModelMessage(role: .assistant, content: big)] })
        }
        #expect(await recorder.pendingRecordCount > 0)
        let usage = await store.usage()
        #expect(usage.transcriptBytes <= 1500)
        let opened = try await makeStore(sandbox, workspace: workspace).openConversation(id: conversation.id)
        #expect(opened.conversation.turns.isEmpty)
    }

    @Test func usageReportsCountsAndBytes() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox, limits: StoreLimits(maxConversations: 5, maxTranscriptBytes: 1_000_000, maxEvidenceBytes: 500))
        let first = try await store.createConversation(providerID: "p", modelID: "m", title: "A")
        _ = try await store.createConversation(providerID: "p", modelID: "m", title: "B")
        try await addTurn(store, first.id)
        _ = try await store.trash(id: first.id)
        let bytes = Data(repeating: 1, count: 120)
        try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: ContentHash.sha256Hex(bytes))

        let usage = await store.usage()
        #expect(usage.conversationCount == 1)
        #expect(usage.trashedCount == 1)
        #expect(usage.conversationLimit == 5)
        #expect(usage.transcriptBytes > 0)
        #expect(usage.transcriptLimitBytes == 1_000_000)
        #expect(usage.evidenceBytes == 120)
        #expect(usage.evidenceLimitBytes == 500)
    }

    @Test func evidenceEvictsLeastRecentlyUsedAndCitationsReportExpiredNeverRegenerated() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace, limits: StoreLimits(maxEvidenceBytes: 100))
        func put(_ id: String, _ byte: UInt8) async throws -> String {
            let bytes = Data(repeating: byte, count: 40)
            let hash = ContentHash.sha256Hex(bytes)
            try await store.artifacts.put(id: id, bytes: bytes, contentHash: hash)
            return hash
        }
        let hashA = try await put("A", 1)
        let hashB = try await put("B", 2)
        guard case .found(let dataA, let foundHash) = await store.artifacts.get(id: "A") else {
            Issue.record("A should be found")
            return
        }
        #expect(dataA.count == 40)
        #expect(foundHash == hashA)
        _ = try await put("C", 3)

        #expect(await store.artifacts.get(id: "B") == .expired(contentHash: hashB))
        if case .found = await store.artifacts.get(id: "A") {} else { Issue.record("A should survive as most recently used") }
        if case .found = await store.artifacts.get(id: "C") {} else { Issue.record("C should be present") }
        #expect(await store.artifacts.get(id: "never-stored") == .missing)
        #expect(await store.artifacts.totalBytes <= 100)
        #expect(await store.artifactFreshness("B") == .needsRefresh)
        #expect(await store.artifactFreshness("A") == .current)

        try await store.flush()
        let reopened = try makeStore(sandbox, workspace: workspace, limits: StoreLimits(maxEvidenceBytes: 100))
        #expect(await reopened.artifacts.get(id: "B") == .expired(contentHash: hashB))
        if case .found = await reopened.artifacts.get(id: "A") {} else { Issue.record("A should persist") }
    }

    @Test func artifactPutValidatesHashSizeAndImmutability() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox, limits: StoreLimits(maxEvidenceBytes: 1000, maxArtifactBytes: 50))
        let bytes = Data("payload".utf8)
        let hash = ContentHash.sha256Hex(bytes)
        await #expect(throws: StoreError.hashMismatch) { try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: "deadbeef") }
        await #expect(throws: StoreError.artifactTooLarge) { try await store.artifacts.put(id: "E2", bytes: Data(repeating: 0, count: 51), contentHash: ContentHash.sha256Hex(Data(repeating: 0, count: 51))) }
        try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: hash)
        try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: hash)
        let other = Data("different".utf8)
        await #expect(throws: StoreError.hashConflict) { try await store.artifacts.put(id: "E1", bytes: other, contentHash: ContentHash.sha256Hex(other)) }
    }

    @Test func tamperedArtifactFileIsReportedExpiredNotServed() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let bytes = Data("original".utf8)
        let hash = ContentHash.sha256Hex(bytes)
        try await store.artifacts.put(id: "E1", bytes: bytes, contentHash: hash)
        let artifactDir = sandbox.workspaceRoot(workspace).appendingPathComponent("artifacts")
        let file = try #require(try FileManager.default.contentsOfDirectory(at: artifactDir, includingPropertiesForKeys: nil).first { $0.pathExtension == "bin" })
        try Data("tampered".utf8).write(to: file)
        #expect(await store.artifacts.get(id: "E1") == .expired(contentHash: hash))
    }

    @Test func exportPreviewRedactsSecretsAndNeverWritesUntilExplicitlyExported() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "p", modelID: "m", title: "Chat with sk-LEAK-1")
        let recorder = try await store.recorder(for: conversation.id)
        let turn = UUID()
        try await recorder.ingest(event(turn, 1, .turnStarted), prompt: "my key is sk-LEAK-1")
        try await recorder.recordMessages(turnID: turn, messages: [
            ModelMessage(role: .user, content: "my key is sk-LEAK-1"),
            ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "echo", argumentsJSON: #"{"token":"sk-LEAK-1"}"#)]),
            ModelMessage(role: .tool, content: "ok", toolCallID: "c1"),
            ModelMessage(role: .assistant, content: "done")
        ])
        try await recorder.ingest(event(turn, 2, .turnCompleted))
        _ = try await store.memory.pin(content: "never share sk-LEAK-1", provenance: MemoryProvenance(sourceConversationID: conversation.id))

        let redactor: @Sendable (String) -> String = { $0.replacingOccurrences(of: "sk-LEAK-1", with: "[REDACTED]") }
        let filesBefore = sandbox.allFiles().count
        let preview = try await store.previewExport(includeMemory: true, redactor: redactor)
        #expect(sandbox.allFiles().count == filesBefore)
        #expect(preview.files.count == 2)
        #expect(preview.redactedStringCount >= 4)
        #expect(preview.totalBytes > 0)
        for file in preview.files {
            let text = try #require(String(data: file.data, encoding: .utf8))
            #expect(!text.contains("sk-LEAK-1"))
            #expect(text.contains("[REDACTED]"))
        }

        let target = sandbox.url.appendingPathComponent("exported")
        try await store.export(preview, to: target)
        let written = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(Set(written) == Set(preview.files.map(\.name)))
    }
}
