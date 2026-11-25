import Foundation
import Testing
import GopilotRuntime
@testable import GopilotStore

private struct MigrationBoom: Error {}

private func downgradeIndexToV0(at url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 0
    var entries = try #require(object["entries"] as? [[String: Any]])
    for index in entries.indices {
        entries[index]["name"] = entries[index].removeValue(forKey: "title")
    }
    object["entries"] = entries
    let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try old.write(to: url)
    return old
}

private let renameNameToTitle = SchemaMigration(file: .index, from: 0, to: 1) { object in
    var entries = (object["entries"] as? [[String: Any]]) ?? []
    for index in entries.indices {
        entries[index]["title"] = entries[index].removeValue(forKey: "name")
    }
    object["entries"] = entries
}

@Suite("Schema migration")
struct MigrationTests {
    private func seed(_ sandbox: Sandbox, workspace: UUID) async throws -> (conversation: Conversation, indexURL: URL) {
        let store = try makeStore(sandbox, workspace: workspace)
        let conversation = try await store.createConversation(providerID: "local", modelID: "m1", title: "Kept title")
        let recorder = try await store.recorder(for: conversation.id)
        try await recorder.consume(stream(completedTurnEvents(UUID())), prompt: "history", finalMessages: { [ModelMessage(role: .user, content: "history"), ModelMessage(role: .assistant, content: "reply")] })
        return (conversation, sandbox.workspaceRoot(workspace).appendingPathComponent("index.json"))
    }

    @Test func successfulMigrationKeepsABackupAndKeepsHistory() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let seeded = try await seed(sandbox, workspace: workspace)
        let original = try downgradeIndexToV0(at: seeded.indexURL)

        let store = try makeStore(sandbox, workspace: workspace, migrations: [renameNameToTitle])
        #expect(await store.mode == .readWrite)
        let summaries = await store.listConversations()
        #expect(summaries.map(\.title) == ["Kept title"])
        let backup = seeded.indexURL.deletingLastPathComponent().appendingPathComponent("index.json.v0.bak")
        #expect(try Data(contentsOf: backup) == original)
        let migrated = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: seeded.indexURL)) as? [String: Any])
        #expect(migrated["schemaVersion"] as? Int == 1)
        let opened = try await store.openConversation(id: seeded.conversation.id)
        #expect(opened.conversation.turns.count == 1)
        _ = try await store.createConversation(providerID: "local", modelID: "m1", title: "New")
    }

    @Test func failedMigrationKeepsBackupOpensReadOnlyAndNeverLosesHistory() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let seeded = try await seed(sandbox, workspace: workspace)
        let original = try downgradeIndexToV0(at: seeded.indexURL)
        let failing = SchemaMigration(file: .index, from: 0, to: 1) { _ in throw MigrationBoom() }

        let store = try makeStore(sandbox, workspace: workspace, migrations: [failing])
        guard case .readOnly(let recovery) = await store.mode else {
            Issue.record("Expected read-only mode")
            return
        }
        #expect(recovery.contains("index.json.v0.bak"))
        let backup = seeded.indexURL.deletingLastPathComponent().appendingPathComponent("index.json.v0.bak")
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: seeded.indexURL) == original)

        #expect(await store.listConversations().map(\.id) == [seeded.conversation.id])
        let opened = try await store.openConversation(id: seeded.conversation.id)
        #expect(opened.conversation.turns.first?.messages.last?.content == "reply")
        await #expect(throws: StoreError.self) { _ = try await store.createConversation(providerID: "local", modelID: "m1", title: "Blocked") }
        await #expect(throws: StoreError.self) { _ = try await store.recorder(for: seeded.conversation.id) }
        try await store.flush()
        #expect(try Data(contentsOf: seeded.indexURL) == original)
    }

    @Test func missingMigrationStepFailsSafely() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let seeded = try await seed(sandbox, workspace: workspace)
        let original = try downgradeIndexToV0(at: seeded.indexURL)
        let store = try makeStore(sandbox, workspace: workspace)
        guard case .readOnly = await store.mode else {
            Issue.record("Expected read-only mode")
            return
        }
        #expect(try Data(contentsOf: seeded.indexURL) == original)
        #expect(await store.listConversations().count == 1)
    }

    @Test func newerSchemaOpensReadOnlyWithoutTouchingTheFile() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let seeded = try await seed(sandbox, workspace: workspace)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: seeded.indexURL)) as? [String: Any])
        object["schemaVersion"] = 7
        let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try future.write(to: seeded.indexURL)

        let store = try makeStore(sandbox, workspace: workspace)
        guard case .readOnly(let recovery) = await store.mode else {
            Issue.record("Expected read-only mode")
            return
        }
        #expect(recovery.contains("newer"))
        #expect(try Data(contentsOf: seeded.indexURL) == future)
        #expect(!FileManager.default.fileExists(atPath: seeded.indexURL.path + ".v7.bak"))
        #expect(await store.listConversations().count == 1)
    }

    @Test func corruptIndexRebuildsFromJournalsReadOnly() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let seeded = try await seed(sandbox, workspace: workspace)
        try Data("{ not json".utf8).write(to: seeded.indexURL)
        let store = try makeStore(sandbox, workspace: workspace)
        guard case .readOnly = await store.mode else {
            Issue.record("Expected read-only mode")
            return
        }
        let summaries = await store.listConversations()
        #expect(summaries.map(\.title) == ["Kept title"])
        #expect(summaries.first?.turnCount == 1)
    }

    @Test func memoryMigrationFailureKeepsNotesOnDiskAndBlocksWrites() async throws {
        let sandbox = Sandbox()
        let workspace = UUID()
        let store = try makeStore(sandbox, workspace: workspace)
        _ = try await store.memory.pin(content: "prefer table tests", provenance: MemoryProvenance(sourceConversationID: nil))
        let memoryURL = sandbox.workspaceRoot(workspace).appendingPathComponent("memory.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: memoryURL)) as? [String: Any])
        object["schemaVersion"] = 0
        let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try old.write(to: memoryURL)

        let failing = SchemaMigration(file: .memory, from: 0, to: 1) { _ in throw MigrationBoom() }
        let reopened = try makeStore(sandbox, workspace: workspace, migrations: [failing])
        #expect(await reopened.memory.recoveryDescription != nil)
        await #expect(throws: StoreError.self) { _ = try await reopened.memory.pin(content: "another", provenance: MemoryProvenance(sourceConversationID: nil)) }
        #expect(try Data(contentsOf: memoryURL) == old)
        #expect(try Data(contentsOf: memoryURL.deletingLastPathComponent().appendingPathComponent("memory.json.v0.bak")) == old)
    }
}
