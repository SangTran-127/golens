import Foundation
import Testing
@testable import GopilotRuntime

@Suite("Tool result model content")
struct ModelContentTests {
    @Test func snapshotAndCursorAreVisibleToTheModel() throws {
        let envelope = ToolResultEnvelope(callID: "c1", status: .ok, data: "x", evidenceIDs: ["E4"], sourceSnapshotID: "S-abc", truncated: true, nextCursor: "100")
        let object = try #require(JSONSerialization.jsonObject(with: Data(envelope.modelContent().utf8)) as? [String: Any])
        #expect(object["sourceSnapshotID"] as? String == "S-abc")
        #expect(object["nextCursor"] as? String == "100")
        #expect(object["evidenceIDs"] as? [String] == ["E4"])
    }

    @Test func absentSnapshotAndCursorAreNull() throws {
        let envelope = ToolResultEnvelope.failure(callID: "c2", code: .notFound, message: "none")
        let object = try #require(JSONSerialization.jsonObject(with: Data(envelope.modelContent().utf8)) as? [String: Any])
        #expect(object["sourceSnapshotID"] is NSNull)
        #expect(object["nextCursor"] is NSNull)
    }
}
