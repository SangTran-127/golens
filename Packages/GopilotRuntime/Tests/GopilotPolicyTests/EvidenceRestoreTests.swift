import Foundation
import Testing
@testable import GopilotPolicy

@Suite("Evidence restore")
struct EvidenceRestoreTests {
    private func draft(_ workspace: UUID, _ text: String) -> EvidenceDraft {
        EvidenceDraft(workspaceID: workspace, producerID: "t", kind: .source, sourceRefs: [], snapshotID: "S", content: text)
    }

    @Test func restoredEvidenceKeepsItsIdentifierAndNewEvidenceContinuesAfterIt() async {
        let workspace = UUID()
        let original = EvidenceStore()
        let first = await original.add(draft(workspace, "alpha"))
        let second = await original.add(draft(workspace, "beta"))
        #expect([first.id, second.id] == ["E1", "E2"])

        let resumed = EvidenceStore()
        for item in await original.all(workspaceID: workspace) { await resumed.restore(item) }
        #expect(await resumed.resolve(id: "E2", workspaceID: workspace)?.content == "beta")
        let next = await resumed.add(draft(workspace, "gamma"))
        #expect(next.id == "E3")
    }

    @Test func restoredEvidenceStaysScopedToItsWorkspace() async {
        let workspace = UUID()
        let other = UUID()
        let store = EvidenceStore()
        let item = await store.add(draft(workspace, "alpha"))
        let resumed = EvidenceStore()
        await resumed.restore(item)
        #expect(await resumed.resolve(id: item.id, workspaceID: other) == nil)
    }

    @Test func restoreIsIdempotent() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let item = await store.add(draft(workspace, "alpha"))
        let resumed = EvidenceStore()
        await resumed.restore(item)
        await resumed.restore(item)
        #expect(await resumed.count(workspaceID: workspace) == 1)
    }
}
