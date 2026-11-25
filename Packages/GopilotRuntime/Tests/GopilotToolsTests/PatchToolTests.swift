import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private let mainText = "package main\n\nfunc main() {}\n"
private let utilText = "package pkg\n"
private let emojiText = "package main\n// \u{1F600} note\nfunc a() {}\n"

private struct TreeEntry: Equatable {
    let data: Data
    let modified: Date
}

private func snapshotTree(_ root: URL) -> [String: TreeEntry] {
    var out: [String: TreeEntry] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return out }
    let prefix = root.resolvingSymlinksInPath().path + "/"
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
        out[url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")] = TreeEntry(data: data, modified: values?.contentModificationDate ?? .distantPast)
    }
    return out
}

private func hash(_ text: String) -> String {
    ContentHash.sha256Hex(text)
}

private func editObject(path: String = "main.go", text: String = mainText, replacements: [[String: String]]) -> [String: Any] {
    ["path": path, "baseHash": hash(text), "replacements": replacements]
}

private func args(snapshot: String = "S1", rationale: String = "Call run from main so the program does something.", edits: [[String: Any]] = [], creates: [[String: Any]] = [], plan: [String] = ["go test ./..."]) -> String {
    var object: [String: Any] = ["baseSnapshotID": snapshot, "rationale": rationale]
    if !edits.isEmpty { object["edits"] = edits }
    if !creates.isEmpty { object["creates"] = creates }
    if !plan.isEmpty { object["verificationPlan"] = plan }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private let mainReplacement: [[String: String]] = [["oldText": "func main() {}", "newText": "func main() { run() }"]]

private func proposalID(_ envelope: ToolResultEnvelope) -> UUID? {
    UUID(uuidString: decode(envelope)["proposalID"] as? String ?? "")
}

private func disk(_ h: Harness) -> CurrentFileProvider {
    let root = h.root
    return { path in
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return .missing }
        return CurrentFileState(exists: true, text: text, documentVersion: 1)
    }
}

@Suite("Patch proposals")
struct PatchToolTests {
    @Test func proposalIsStoredForReviewAndTheProjectIsNotTouched() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText, "pkg/util.go": utilText])
            let before = snapshotTree(h.root)
            let result = try await h.call("propose_patch", args(
                edits: [editObject(replacements: mainReplacement)],
                creates: [["path": "pkg/new.go", "content": "package pkg\n\nvar New = 1\n"]]
            ))
            #expect(result.status == .ok, "\(result.data)")
            let data = decode(result)
            #expect(data["outcome"] as? String == "found")
            #expect(data["proposalStatus"] as? String == "proposed")
            #expect(data["projectChanged"] as? Bool == false)
            let id = try #require(proposalID(result))
            #expect((data["next"] as? String)?.contains("Nothing was applied") == true)
            let files = nestedList(data, "files")
            #expect(files.count == 2)
            #expect(files.first { $0["path"] as? String == "main.go" }?["operation"] as? String == "edit")
            #expect(files.first { $0["path"] as? String == "pkg/new.go" }?["operation"] as? String == "create")
            #expect((data["validation"] as? [String: Any])?["passed"] as? Bool == true)

            #expect(snapshotTree(h.root) == before)
            #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent("pkg/new.go").path))

            let proposal = try #require(await store.proposal(id: id))
            #expect(proposal.status == .proposed)
            #expect(proposal.verificationPlan == ["go test ./..."])
            #expect(proposal.operations.count == 2)
            let edit = try #require(proposal.operations.first { $0.kind == .edit })
            let range = (mainText as NSString).range(of: "func main() {}")
            #expect(edit.edits == [TextEdit(startUTF16: range.location, endUTF16: range.location + range.length, replacement: "func main() { run() }")])
            #expect(edit.baseHash == hash(mainText))
            #expect(edit.documentVersion == 1)
            let expectedAfter = mainText.replacingOccurrences(of: "func main() {}", with: "func main() { run() }")
            #expect(proposal.expectedAfterHashes["main.go"] == hash(expectedAfter))
            #expect(proposal.expectedAfterHashes["pkg/new.go"] == hash("package pkg\n\nvar New = 1\n"))
            #expect(await store.list().map(\.id) == [id])

            let evidence = try #require(await h.evidence.resolve(id: result.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidence.kind == .patch)
            #expect(evidence.basis == .inferred)
            #expect(evidence.sourceRefs.map(\.path) == ["main.go"])
            #expect(evidence.sourceRefs.first?.contentHash == hash(mainText))
        }
    }

    @Test func utf16OffsetsAccountForSurrogatePairs() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": emojiText])
            let result = try await h.call("propose_patch", args(edits: [editObject(text: emojiText, replacements: [["oldText": "func a() {}", "newText": "func a() { b() }"]])]))
            let id = try #require(proposalID(result))
            let proposal = try #require(await store.proposal(id: id))
            let edit = try #require(proposal.operations.first)
            let expectedStart = (emojiText as NSString).range(of: "func a() {}").location
            #expect(edit.edits.first?.startUTF16 == expectedStart)
            #expect(expectedStart == emojiText.utf16.count - "func a() {}\n".utf16.count)
            let after = emojiText.replacingOccurrences(of: "func a() {}", with: "func a() { b() }")
            #expect(proposal.expectedAfterHashes["main.go"] == hash(after))
        }
    }

    @Test func invalidOrStaleProposalsAreRefusedAndNeverStored() async throws {
        try await withHarness { h in
            _ = try h.attachPatch(files: ["main.go": mainText, "pkg/util.go": utilText])
            let before = snapshotTree(h.root)
            func code(_ json: String, id: String = "c") async throws -> ToolErrorCode? {
                try await h.call("propose_patch", json, id: id).errorCode
            }

            #expect(try await code(args(snapshot: "S-old", edits: [editObject(replacements: mainReplacement)])) == .staleContext)
            h.setSnapshot(id: "S2")
            #expect(try await code(args(snapshot: "S1", edits: [editObject(replacements: mainReplacement)])) == .staleContext)
            h.setSnapshot(id: "S1")

            let wrongHash: [String: Any] = ["path": "main.go", "baseHash": "deadbeef", "replacements": mainReplacement]
            #expect(try await code(args(edits: [wrongHash])) == .staleContext)
            #expect(try await code(args(edits: [editObject(replacements: [["oldText": "not in the file", "newText": "x"]])])) == .invalidArguments)
            #expect(try await code(args(edits: [editObject(text: utilText + utilText, replacements: [["oldText": "x", "newText": "y"]])])) == .staleContext)
            #expect(try await code(args(edits: [editObject(path: "missing.go", replacements: mainReplacement)])) == .notFound)
            #expect(try await code(args()) == .invalidArguments)

            let duplicated = "package pkg\nvar a = 1\nvar a = 1\n"
            _ = try h.attachPatch(files: ["dup.go": duplicated])
            #expect(try await code(args(edits: [editObject(path: "dup.go", text: duplicated, replacements: [["oldText": "var a = 1", "newText": "var b = 2"]])])) == .invalidArguments)

            #expect(try await code(args(edits: [editObject(replacements: [["oldText": "func main", "newText": "func start"], ["oldText": "main() {}", "newText": "start() {}"]])])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "pkg/util.go", "content": "package pkg\n"]])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "../escape.go", "content": "package x\n"]])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "/abs/escape.go", "content": "package x\n"]])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "pkg/secret.go", "content": "package pkg\nvar password = \"hunter2hunter2\"\n"]])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "pkg/bin.go", "content": "package pkg\u{0}\n"]])) == .invalidArguments)
            #expect(try await code(args(creates: [["path": "pkg/a.go", "content": "package pkg\n"], ["path": "pkg/a.go", "content": "package pkg\n"]])) == .invalidArguments)
            let big = String(repeating: "x", count: 150_000)
            #expect(try await code(args(creates: [["path": "pkg/big1.go", "content": big], ["path": "pkg/big2.go", "content": big]])) == .invalidArguments)
            let eleven = (0..<11).map { ["path": "pkg/f\($0).go", "content": "package pkg\n"] }
            #expect(try await code(args(creates: eleven)) == .invalidArguments)
            let ten = (0..<10).map { ["path": "pkg/f\($0).go", "content": "package pkg\n"] }
            #expect(try await code(args(creates: ten)) == nil)

            #expect(snapshotTree(h.root).filter { $0.key.hasPrefix("pkg/f") }.isEmpty)
            let after = snapshotTree(h.root)
            #expect(after["main.go"] == before["main.go"])
            #expect(after["pkg/util.go"] == before["pkg/util.go"])
        }
    }

    @Test func refusedProposalsLeaveTheStoreEmpty() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText])
            _ = try await h.call("propose_patch", args(snapshot: "S-old", edits: [editObject(replacements: mainReplacement)]))
            _ = try await h.call("propose_patch", args(creates: [["path": "../x.go", "content": "package x\n"]]), id: "c2")
            _ = try await h.call("propose_patch", args(edits: [editObject(replacements: [["oldText": "missing", "newText": "x"]])]), id: "c3")
            #expect(await store.list().isEmpty)
        }
    }

    @Test func rejectedProposalCannotBePlannedOrRejectedAgain() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText])
            let result = try await h.call("propose_patch", args(edits: [editObject(replacements: mainReplacement)]))
            let id = try #require(proposalID(result))
            let proposal = try #require(await store.proposal(id: id))

            #expect(await store.reject(id: id))
            #expect(await store.proposal(id: id)?.status == .rejected)
            let token = UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash)
            let planned = try #require(await store.plan(id: id, token: token, currentText: disk(h)))
            #expect(planned.outcome == .notAuthorized(.proposalNotApplicable(.rejected)))
            #expect(await store.reject(id: id) == false)
            #expect(await store.markStale(id: id, reason: "late") == false)
            #expect(await store.recordApplied(id: id, afterVersions: [:]) == false)
            #expect(try String(contentsOf: h.root.appendingPathComponent("main.go"), encoding: .utf8) == mainText)
        }
    }

    @Test func staleProposalIsDetectedAtPlanTimeAndTheUsersEditSurvives() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText])
            let result = try await h.call("propose_patch", args(edits: [editObject(replacements: mainReplacement)]))
            let id = try #require(proposalID(result))
            let proposal = try #require(await store.proposal(id: id))

            let userEdit = mainText + "// the user kept typing\n"
            try userEdit.write(to: h.root.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)

            let token = UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash)
            let planned = try #require(await store.plan(id: id, token: token, currentText: disk(h)))
            guard case .stale(let files) = planned.outcome else {
                Issue.record("expected stale, got \(planned.outcome)")
                return
            }
            #expect(files.map(\.path) == ["main.go"])
            if case .hashMismatch(let expected, let actual) = files[0].reason {
                #expect(expected == hash(mainText))
                #expect(actual == hash(userEdit))
            } else {
                Issue.record("expected a hash mismatch")
            }
            guard case .stale(let reason)? = await store.proposal(id: id)?.status else {
                Issue.record("status should be stale")
                return
            }
            #expect(reason.contains("main.go"))
            let again = try #require(await store.plan(id: id, token: token, currentText: disk(h)))
            if case .notAuthorized(.proposalNotApplicable(.stale)) = again.outcome {} else { Issue.record("a stale proposal must not plan again: \(again.outcome)") }
            #expect(try String(contentsOf: h.root.appendingPathComponent("main.go"), encoding: .utf8) == userEdit)
        }
    }

    @Test func planDelegatesToThePlannerWithoutWritingAnything() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText])
            let result = try await h.call("propose_patch", args(
                edits: [editObject(replacements: mainReplacement)],
                creates: [["path": "extra.go", "content": "package main\n"]]
            ))
            let id = try #require(proposalID(result))
            let proposal = try #require(await store.proposal(id: id))
            let before = snapshotTree(h.root)

            let ready = try #require(await store.plan(id: id, token: UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash), currentText: disk(h)))
            guard case .ready(let plan) = ready.outcome else {
                Issue.record("expected ready, got \(ready.outcome)")
                return
            }
            #expect(plan.fileEdits.count == 1)
            #expect(plan.fileEdits[0].afterText == mainText.replacingOccurrences(of: "func main() {}", with: "func main() { run() }"))
            #expect(plan.creations.map(\.path) == ["extra.go"])
            #expect(plan.afterHashes == proposal.expectedAfterHashes)
            #expect(snapshotTree(h.root) == before)
            #expect(await store.proposal(id: id)?.status == .proposed)

            let wrongToken = UserActionToken.makeFromUserAction(approvingProposalHash: "another-hash")
            let mismatch = try #require(await store.plan(id: id, token: wrongToken, currentText: disk(h)))
            #expect(mismatch.outcome == .notAuthorized(.proposalHashMismatch))
            let late = UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash, at: Date().addingTimeInterval(-600))
            let expired = try #require(await store.plan(id: id, token: late, currentText: disk(h)))
            #expect(expired.outcome == .notAuthorized(.tokenExpired))
            #expect(await store.proposal(id: id)?.status == .proposed)
        }
    }

    @Test func statusTransitionsFollowTheReviewLifecycle() async throws {
        try await withHarness { h in
            let store = try h.attachPatch(files: ["main.go": mainText])
            let first = try #require(proposalID(try await h.call("propose_patch", args(edits: [editObject(replacements: mainReplacement)]))))
            let second = try #require(proposalID(try await h.call("propose_patch", args(edits: [editObject(replacements: mainReplacement)], plan: ["different plan"]), id: "c2")))
            #expect(first != second)
            #expect(await store.list().map(\.id) == [first, second])

            #expect(await store.recordRolledBack(id: first) == false)
            #expect(await store.recordApplied(id: first, afterVersions: ["main.go": 4]))
            #expect(await store.proposal(id: first)?.status == .applied)
            #expect(await store.appliedVersions(id: first) == ["main.go": 4])
            #expect(await store.recordApplied(id: first, afterVersions: [:]) == false)
            #expect(await store.reject(id: first) == false)
            #expect(await store.markStale(id: first, reason: "x") == false)
            #expect(await store.recordRolledBack(id: first))
            #expect(await store.proposal(id: first)?.status == .rolledBack)
            #expect(await store.recordRolledBack(id: first) == false)

            #expect(await store.markStale(id: second, reason: "buffer changed"))
            #expect(await store.proposal(id: second)?.status == .stale(reason: "buffer changed"))
            #expect(await store.recordApplied(id: second, afterVersions: [:]) == false)
            #expect(await store.reject(id: second))

            let unknown = UUID()
            #expect(await store.proposal(id: unknown) == nil)
            #expect(await store.reject(id: unknown) == false)
            #expect(await store.markStale(id: unknown, reason: "x") == false)
            #expect(await store.recordApplied(id: unknown, afterVersions: [:]) == false)
            let token = UserActionToken.makeFromUserAction(approvingProposalHash: "x")
            #expect(await store.plan(id: unknown, token: token, currentText: disk(h)) == nil)
        }
    }

    @Test func applyIsNotAModelTool() async throws {
        try await withHarness { h in
            _ = try h.attachMemory()
            _ = try h.attachPatch()
            let names = try h.registry().schemas.map(\.name)
            #expect(names.contains("propose_patch"))
            #expect(!names.contains { $0.contains("apply") || $0.contains("write") || $0.contains("exec") || $0.contains("shell") })
            #expect(!ExecutionToolSet.catalog.contains { $0.name.contains("apply") })
        }
    }
}
