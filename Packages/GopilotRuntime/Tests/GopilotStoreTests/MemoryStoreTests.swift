import Foundation
import Testing
import GopilotRuntime
@testable import GopilotStore

@Suite("Memory notes")
struct MemoryStoreTests {
    private func provenance(_ conversation: UUID? = nil, branch: String? = nil, target: String? = nil, modules: [String: String] = [:]) -> MemoryProvenance {
        MemoryProvenance(sourceConversationID: conversation, pinnedContext: MemoryContextFacts(branch: branch, buildTarget: target, moduleVersions: modules))
    }

    @Test func pinnedNoteIsRecalledWithProvenanceAndApproval() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox)
        let conversation = UUID()
        let note = try await store.memory.pin(content: "Orders use sqlc generated queries", provenance: provenance(conversation, branch: "main"), sourceRefs: [MemorySourceRef(path: "db/query.sql", contentHash: "h1")])
        #expect(note.userApprovedAt != nil)
        #expect(note.provenance.sourceConversationID == conversation)
        let recalled = await store.memory.recall(query: "sqlc queries")
        #expect(recalled.map(\.note.id) == [note.id])
        #expect(recalled[0].isStale == false)
        #expect(recalled[0].ageSeconds >= 0)
        #expect(await store.memory.recall(query: "kubernetes").isEmpty)
        #expect(await store.memory.recall(query: "   ").isEmpty)
    }

    @Test func deleteRemovesNoteFromIndexesAndCacheSoNextRecallCannotReturnIt() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        let kept = try await store.memory.pin(content: "Use table driven tests", provenance: provenance())
        let doomed = try await store.memory.pin(content: "Use table driven tests for parsers with secret-token-42", provenance: provenance())
        let first = await store.memory.recall(query: "table driven tests")
        #expect(Set(first.map(\.note.id)) == [kept.id, doomed.id])
        _ = await store.memory.recall(query: "table driven tests")
        #expect(await store.memory.cacheHitCount == 1)
        #expect(await store.memory.cachedQueryCount == 1)

        try await store.memory.delete(id: doomed.id)
        #expect(await store.memory.cachedQueryCount == 0)
        let after = await store.memory.recall(query: "table driven tests")
        #expect(after.map(\.note.id) == [kept.id])
        #expect(await store.memory.recall(query: "secret-token-42").isEmpty)
        #expect(await store.memory.notes().map(\.id) == [kept.id])

        let file = try String(contentsOf: sandbox.workspaceRoot(workspace).appendingPathComponent("memory.json"), encoding: .utf8)
        #expect(!file.contains("secret-token-42"))
        let reopened = try makeStore(sandbox, workspace: workspace)
        #expect(await reopened.memory.recall(query: "secret-token-42").isEmpty)
        #expect(await reopened.memory.recall(query: "table driven tests").map(\.note.id) == [kept.id])
        await #expect(throws: StoreError.notFound) { try await reopened.memory.delete(id: doomed.id) }
    }

    @Test func deleteStaysEffectiveInMemoryEvenWhenPersistingFails() async throws {
        let sandbox = Sandbox()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, fileSystem: fileSystem)
        let note = try await store.memory.pin(content: "remember the dispatcher", provenance: provenance())
        _ = await store.memory.recall(query: "dispatcher")
        fileSystem.failAtomicWrites()
        await #expect(throws: StoreError.diskFull) { try await store.memory.delete(id: note.id) }
        #expect(await store.memory.recall(query: "dispatcher").isEmpty)
        fileSystem.failAtomicWrites(with: nil)
        try await store.memory.flush()
    }

    @Test func failedPinRollsBackSoTheUiNeverShowsAnUnsavedNote() async throws {
        let sandbox = Sandbox()
        let fileSystem = FaultFileSystem()
        let store = try makeStore(sandbox, fileSystem: fileSystem)
        fileSystem.failAtomicWrites()
        await #expect(throws: StoreError.diskFull) { _ = try await store.memory.pin(content: "never saved", provenance: provenance()) }
        #expect(await store.memory.notes().isEmpty)
        #expect(await store.memory.recall(query: "never saved").isEmpty)
    }

    @Test func branchTargetModuleAndFileChangesMarkRelevantNotesStaleAndRecoveryClearsIt() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox)
        let note = try await store.memory.pin(
            content: "Checkout flow lives in cart package",
            provenance: provenance(nil, branch: "main", target: "app", modules: ["example.com/cart": "v1.0.0"]),
            sourceRefs: [MemorySourceRef(path: "cart/cart.go", contentHash: "aaa")]
        )
        let unrelated = try await store.memory.pin(content: "Checkout also uses a feature flag", provenance: provenance())

        let unchanged = try await store.memory.markStale(against: SnapshotFacts(branch: "main", buildTarget: "app", moduleVersions: ["example.com/cart": "v1.0.0"], fileHashes: ["cart/cart.go": "aaa"]))
        #expect(unchanged.isEmpty)

        let changed = try await store.memory.markStale(against: SnapshotFacts(branch: "feature/x", buildTarget: "app", moduleVersions: ["example.com/cart": "v1.1.0"], fileHashes: ["cart/cart.go": "bbb"]))
        #expect(changed == [note.id])
        let recalled = await store.memory.recall(query: "checkout flow")
        let stale = try #require(recalled.first { $0.note.id == note.id })
        #expect(stale.isStale)
        #expect(stale.staleReasons.count == 3)
        #expect(stale.staleReasons.contains { $0.contains("feature/x") })
        let fresh = try #require(recalled.first { $0.note.id == unrelated.id })
        #expect(fresh.isStale == false)

        _ = try await store.memory.markStale(against: SnapshotFacts(branch: "main", buildTarget: "app", moduleVersions: ["example.com/cart": "v1.0.0"], fileHashes: ["cart/cart.go": "aaa"]))
        #expect(await store.memory.recall(query: "checkout flow").allSatisfy { !$0.isStale })
    }

    @Test func staleStateSurvivesRestart() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        _ = try await store.memory.pin(content: "Deploy uses the release branch", provenance: provenance(nil, branch: "release"))
        _ = try await store.memory.markStale(against: SnapshotFacts(branch: "main"))
        let reopened = try makeStore(sandbox, workspace: workspace)
        let recalled = await reopened.memory.recall(query: "deploy release")
        #expect(recalled.first?.isStale == true)
    }

    @Test func recallSwitchOffReturnsNothingEvenWithWarmCacheAndPersists() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        _ = try await store.memory.pin(content: "Profile with pprof first", provenance: provenance())
        #expect(await store.memory.recall(query: "pprof").count == 1)
        try await store.memory.setRecallEnabled(false)
        #expect(await store.memory.recall(query: "pprof").isEmpty)
        #expect(await store.memory.notes().count == 1)

        let reopened = try makeStore(sandbox, workspace: workspace)
        #expect(await reopened.memory.isRecallEnabled == false)
        #expect(await reopened.memory.recall(query: "pprof").isEmpty)
        try await reopened.memory.setRecallEnabled(true)
        #expect(await reopened.memory.recall(query: "pprof").count == 1)
    }

    @Test func notesFromAnotherWorkspaceAreNeverRecalled() async throws {
        let sandbox = Sandbox()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let storeA = try makeStore(sandbox, workspace: workspaceA)
        _ = try await storeA.memory.pin(content: "Billing service owns invoices", provenance: provenance())
        let bRoot = sandbox.workspaceRoot(workspaceB)
        try FileManager.default.createDirectory(at: bRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.workspaceRoot(workspaceA).appendingPathComponent("memory.json"), to: bRoot.appendingPathComponent("memory.json"))

        let storeB = try makeStore(sandbox, workspace: workspaceB)
        #expect(await storeB.memory.recall(query: "billing invoices").isEmpty)
        #expect(await storeB.memory.notes().isEmpty)
        #expect(await storeA.memory.recall(query: "billing invoices").count == 1)
    }

    @Test func recallIsCappedAtTenRanksByKeywordMatchAndRejectsBadPins() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox)
        for index in 0..<12 { _ = try await store.memory.pin(content: "handler note \(index)", provenance: provenance()) }
        let strong = try await store.memory.pin(content: "handler handler routing middleware", provenance: provenance())
        #expect(await store.memory.recall(query: "handler", limit: 50).count == 10)
        #expect(await store.memory.recall(query: "handler", limit: 0).count == 1)
        #expect(await store.memory.recall(query: "handler routing middleware", limit: 3).first?.note.id == strong.id)
        await #expect(throws: StoreError.emptyNote) { _ = try await store.memory.pin(content: "  \n ", provenance: provenance()) }
        await #expect(throws: StoreError.noteTooLarge) { _ = try await store.memory.pin(content: String(repeating: "x", count: MemoryStore.maxNoteCharacters + 1), provenance: provenance()) }
    }

    @Test func notesDerivedFromAConversationAreListed() async throws {
        let sandbox = Sandbox()
        let store = try makeStore(sandbox)
        let conversation = UUID()
        let derived = try await store.memory.pin(content: "from this chat", provenance: provenance(conversation))
        _ = try await store.memory.pin(content: "from another chat", provenance: provenance(UUID()))
        #expect(await store.memory.notes(derivedFrom: conversation).map(\.id) == [derived.id])
    }
}
