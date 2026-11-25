import Foundation
import Testing
@testable import GopilotAnalysis

private final class FileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (text: String, version: Int)]
    private(set) var reads = 0

    init(_ files: [String: String]) {
        self.files = files.mapValues { ($0, 1) }
    }

    func provider() -> CurrentFileProvider {
        { [self] path in
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            guard let entry = files[path] else { return .missing }
            return CurrentFileState(exists: true, text: entry.text, documentVersion: entry.version)
        }
    }

    func set(_ path: String, _ text: String, version: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        files[path] = (text, version ?? ((files[path]?.version ?? 0) + 1))
    }

    func remove(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        files[path] = nil
    }

    func text(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return files[path]?.text
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return files.mapValues(\.text)
    }

    func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[path] != nil
    }
}

private func context(store: FileStore? = nil, limits: PatchLimits = PatchLimits()) -> PatchValidationContext {
    PatchValidationContext(
        limits: limits,
        pathCheck: { path in path.hasPrefix("link/") ? .symlinkEscape : .ok },
        secretCheck: { $0.contains("AKIA") || $0.contains("sk-live-") || $0.contains("BEGIN PRIVATE KEY") },
        pathExists: { path in store?.exists(path) ?? false }
    )
}

private func hash(_ text: String) -> String { ContentHash.sha256Hex(text) }

private func applyEdits(_ edits: [TextEdit], to text: String) -> String {
    var units = Array(text.utf16)
    for edit in edits.sorted(by: { $0.startUTF16 > $1.startUTF16 }) {
        units.replaceSubrange(edit.startUTF16..<edit.endUTF16, with: Array(edit.replacement.utf16))
    }
    return String(decoding: units, as: UTF16.self)
}

private func proposal(_ operations: [PatchFileOperation], turn: UUID = UUID()) -> PatchProposal {
    PatchProposal(turnID: turn, rationale: "reduce allocations", operations: operations, verificationPlan: ["go test ./..."])
}

private func approve(_ proposal: PatchProposal, at date: Date = Date()) -> UserActionToken {
    UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash, at: date)
}

private func ready(_ result: PlanResult) throws -> ApplyPlan {
    guard case .ready(let plan) = result.outcome else {
        Issue.record("expected a ready plan, got \(result.outcome)")
        throw CancellationError()
    }
    return plan
}

@Suite("Patch validation")
struct PatchValidatorTests {
    private func issues(_ operations: [PatchFileOperation], store: FileStore? = nil, limits: PatchLimits = PatchLimits()) -> [PatchIssue] {
        PatchValidator.validate(proposal(operations), context: context(store: store, limits: limits))
    }

    private func edit(_ edits: [TextEdit], path: String = "a.go") -> PatchFileOperation {
        .edit(path: path, baseHash: "h", documentVersion: 1, edits: edits)
    }

    @Test func wellFormedProposalHasNoIssues() {
        let store = FileStore([:])
        let result = issues([edit([TextEdit(startUTF16: 0, endUTF16: 3, replacement: "x")]), .create(path: "new/b.go", content: "package b\n")], store: store)
        #expect(result.isEmpty)
    }

    @Test func emptyProposalIsRejected() {
        #expect(issues([]).map(\.code) == [.emptyProposal])
    }

    @Test func moreThanTenFilesIsRejected() {
        let operations = (0..<11).map { PatchFileOperation.create(path: "f\($0).go", content: "package f") }
        #expect(issues(operations).contains { $0.code == .tooManyFiles })
        #expect(!issues(Array(operations.prefix(10))).contains { $0.code == .tooManyFiles })
    }

    @Test func proposalOverTwoHundredKiBIsRejected() {
        let big = String(repeating: "x", count: 200 * 1024 + 1)
        #expect(issues([.create(path: "big.go", content: big)]).contains { $0.code == .tooLarge })
        let exact = String(repeating: "x", count: 200 * 1024)
        #expect(!issues([.create(path: "ok.go", content: exact)]).contains { $0.code == .tooLarge })
        let split = [PatchFileOperation.create(path: "a.go", content: String(repeating: "x", count: 150 * 1024)), .create(path: "b.go", content: String(repeating: "y", count: 60 * 1024))]
        #expect(issues(split).contains { $0.code == .tooLarge })
    }

    @Test func overlappingAndAmbiguousRangesAreRejected() {
        #expect(issues([edit([TextEdit(startUTF16: 0, endUTF16: 5, replacement: "a"), TextEdit(startUTF16: 4, endUTF16: 8, replacement: "b")])]).contains { $0.code == .overlappingRanges })
        #expect(issues([edit([TextEdit(startUTF16: 0, endUTF16: 10, replacement: "a"), TextEdit(startUTF16: 2, endUTF16: 3, replacement: "b")])]).contains { $0.code == .overlappingRanges })
        #expect(issues([edit([TextEdit(startUTF16: 3, endUTF16: 3, replacement: "a"), TextEdit(startUTF16: 3, endUTF16: 3, replacement: "b")])]).contains { $0.code == .overlappingRanges })
        #expect(issues([edit([TextEdit(startUTF16: 0, endUTF16: 5, replacement: "a"), TextEdit(startUTF16: 5, endUTF16: 8, replacement: "b")])]).isEmpty)
        #expect(issues([edit([TextEdit(startUTF16: 5, endUTF16: 8, replacement: "b"), TextEdit(startUTF16: 0, endUTF16: 5, replacement: "a")])]).isEmpty)
    }

    @Test func invalidRangesAreRejected() {
        #expect(issues([edit([TextEdit(startUTF16: -1, endUTF16: 2, replacement: "a")])]).contains { $0.code == .invalidRange })
        #expect(issues([edit([TextEdit(startUTF16: 5, endUTF16: 2, replacement: "a")])]).contains { $0.code == .invalidRange })
    }

    @Test(arguments: [PatchOperationKind.rename, .delete, .binary, .dependencyInstall])
    func unsupportedOperationsAreRejected(_ kind: PatchOperationKind) {
        let operation = PatchFileOperation(kind: kind, path: "a.go")
        #expect(issues([operation]).contains { $0.code == .unsupportedOperation })
    }

    @Test func unsupportedKindsDecodeFromModelJSONAndThenFailValidation() throws {
        let json = #"{"kind":"rename","path":"a.go","edits":[]}"#
        let operation = try JSONDecoder().decode(PatchFileOperation.self, from: Data(json.utf8))
        #expect(operation.kind == .rename)
        #expect(issues([operation]).contains { $0.code == .unsupportedOperation })
    }

    @Test func pathEscapesAndSymlinksAreRejected() {
        for path in ["../etc/passwd", "a/../../b.go", "/abs/path.go", "~/x.go", "a\\b.go", "", "a//b.go", "./a.go", "a/./b.go"] {
            #expect(issues([.create(path: path, content: "x")]).contains { $0.code == .invalidPath }, "\(path)")
        }
        #expect(issues([.create(path: "link/evil.go", content: "x")]).contains { $0.code == .symlinkEscape })
    }

    @Test func secretsAndBinaryContentAreRejected() {
        #expect(issues([.create(path: "a.go", content: "const key = \"AKIA1234567890\"")]).contains { $0.code == .secretDetected })
        #expect(issues([edit([TextEdit(startUTF16: 0, endUTF16: 0, replacement: "sk-live-abc")])]).contains { $0.code == .secretDetected })
        #expect(issues([.create(path: "a.bin", content: "abc\u{0}def")]).contains { $0.code == .binaryContent })
        #expect(issues([edit([TextEdit(startUTF16: 0, endUTF16: 0, replacement: "a\u{0}")])]).contains { $0.code == .binaryContent })
    }

    @Test func createNeverOverwritesAnExistingPath() {
        let store = FileStore(["exists.go": "package a"])
        #expect(issues([.create(path: "exists.go", content: "package b")], store: store).contains { $0.code == .createWouldOverwrite })
    }

    @Test func duplicatePathsAndMissingFieldsAreRejected() {
        #expect(issues([.create(path: "a.go", content: "x"), .create(path: "a.go", content: "y")]).contains { $0.code == .duplicatePath })
        #expect(issues([PatchFileOperation(kind: .edit, path: "a.go", baseHash: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 0, replacement: "x")])]).contains { $0.code == .missingBaseHash })
        #expect(issues([PatchFileOperation(kind: .edit, path: "a.go", baseHash: "h", edits: [])]).contains { $0.code == .missingEdits })
        #expect(issues([PatchFileOperation(kind: .create, path: "a.go")]).contains { $0.code == .missingContent })
        #expect(issues([PatchFileOperation(kind: .edit, path: "a.go", baseHash: "h", edits: [TextEdit(startUTF16: 0, endUTF16: 0, replacement: "x")], content: "full")]).contains { $0.code == .unsupportedOperation })
    }

    @Test func warnsWhenPatchAddsSensitiveImportsOrDirectives() {
        let p = proposal([
            .create(
                path: "runner.go",
                content: """
                package main
                // #cgo LDFLAGS: -lm
                import (
                    "os/exec"
                    "syscall"
                    "unsafe"
                    "net/http"
                )
                """
            )
        ])
        let warnings = PatchValidator.securityWarnings(for: p)
        let tokens = Set(warnings.map(\.token))
        #expect(tokens.contains("os/exec"))
        #expect(tokens.contains("syscall"))
        #expect(tokens.contains("unsafe"))
        #expect(tokens.contains("net"))
        #expect(tokens.contains("// #cgo"))
    }

    @Test func securityWarningsDiffAgainstBaseTextEliminatesFalsePositives() {
        let baseContent = """
        package main
        import (
            "net/http"
        )
        // reference to "unsafe" in a comment should not be flagged
        const msg = "import \\"syscall\\""
        """
        let newContent = """
        package main
        import (
            "net/http"
            "os/exec"
        )
        // reference to "unsafe" in a comment should not be flagged
        const msg = "import \\"syscall\\""
        """
        let p = proposal([
            .create(path: "main.go", content: newContent)
        ])
        let warningsWithDiff = PatchValidator.securityWarnings(for: p, baseTexts: ["main.go": baseContent])
        let tokensWithDiff = Set(warningsWithDiff.map(\.token))
        #expect(tokensWithDiff.contains("os/exec"))
        #expect(!tokensWithDiff.contains("net"))
        #expect(!tokensWithDiff.contains("unsafe"))
        #expect(!tokensWithDiff.contains("syscall"))
    }
}

@Suite("Patch apply planning")
struct PatchApplyPlannerTests {
    @Test func planComputesAfterHashesDescendingEditsAndInverse() throws {
        let original = "package a\n\nfunc A() int { return 1 }\nfunc B() int { return 2 }\n"
        let store = FileStore(["a.go": original])
        let first = (original as NSString).range(of: "return 1")
        let second = (original as NSString).range(of: "return 2")
        let edits = [
            TextEdit(startUTF16: second.location, endUTF16: second.location + second.length, replacement: "return 20"),
            TextEdit(startUTF16: first.location, endUTF16: first.location + first.length, replacement: "return 10 + 0")
        ]
        let p = proposal([.edit(path: "a.go", baseHash: hash(original), documentVersion: 1, edits: edits), .create(path: "b.go", content: "package a\n")])
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider())
        let plan = try ready(result)

        let planned = try #require(plan.fileEdits.first)
        let expectedAfter = "package a\n\nfunc A() int { return 10 + 0 }\nfunc B() int { return 20 }\n"
        #expect(planned.afterText == expectedAfter)
        #expect(planned.afterHash == hash(expectedAfter))
        #expect(planned.beforeHash == hash(original))
        #expect(planned.edits.map(\.startUTF16) == planned.edits.map(\.startUTF16).sorted(by: >))
        #expect(applyEdits(planned.edits, to: original) == expectedAfter)
        #expect(applyEdits(planned.inverseEdits, to: expectedAfter) == original)
        #expect(plan.creations.map(\.path) == ["b.go"])
        #expect(plan.afterHashes["b.go"] == hash("package a\n"))
        #expect(plan.afterHashes["a.go"] == hash(expectedAfter))
        #expect(result.proposal.status == .proposed)
        #expect(store.snapshot() == ["a.go": original])
    }

    @Test func expectedAfterHashesCanBePrecomputedForTheProposal() throws {
        let original = "hello world"
        let store = FileStore(["a.go": original])
        let p = proposal([.edit(path: "a.go", baseHash: hash(original), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 5, replacement: "howdy")]), .create(path: "n.go", content: "x")])
        let hashes = try #require(PatchApplyPlanner.expectedAfterHashes(for: p, current: store.provider()))
        #expect(hashes == ["a.go": hash("howdy world"), "n.go": hash("x")])
        let stale = FileStore(["a.go": "changed"])
        #expect(PatchApplyPlanner.expectedAfterHashes(for: p, current: stale.provider()) == nil)
    }

    @Test func utf16RangesHandleEmojiAndRefuseToSplitSurrogatePairs() throws {
        let original = "let s = \"x\u{1F600}y\"\n"
        let store = FileStore(["a.go": original])
        let afterEmoji = (original as NSString).range(of: "y").location
        let p = proposal([.edit(path: "a.go", baseHash: hash(original), documentVersion: nil, edits: [TextEdit(startUTF16: afterEmoji, endUTF16: afterEmoji + 1, replacement: "Z")])])
        let plan = try ready(PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider()))
        #expect(try #require(plan.fileEdits.first).afterText == "let s = \"x\u{1F600}Z\"\n")

        let emojiStart = (original as NSString).range(of: "\u{1F600}").location
        let split = proposal([.edit(path: "a.go", baseHash: hash(original), documentVersion: nil, edits: [TextEdit(startUTF16: emojiStart + 1, endUTF16: emojiStart + 2, replacement: "?")])])
        let result = PatchApplyPlanner.plan(proposal: split, token: approve(split), context: context(store: store), current: store.provider())
        guard case .stale(let stale) = result.outcome else {
            Issue.record("expected stale")
            return
        }
        #expect(stale.first?.reason == .rangeSplitsCharacter(offset: emojiStart + 1))
    }

    @Test func outOfBoundsRangeIsStale() {
        let store = FileStore(["a.go": "short"])
        let p = proposal([.edit(path: "a.go", baseHash: hash("short"), documentVersion: nil, edits: [TextEdit(startUTF16: 2, endUTF16: 99, replacement: "x")])])
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider())
        guard case .stale(let stale) = result.outcome else {
            Issue.record("expected stale")
            return
        }
        #expect(stale.first?.reason == .rangeOutOfBounds(start: 2, end: 99, length: 5))
    }

    @Test func staleFileMeansNothingAppliesAndStatusBecomesStale() throws {
        let a = "package a\n"
        let b = "package b\n"
        let c = "package c\n"
        let store = FileStore(["a.go": a, "b.go": b, "c.go": c])
        let p = proposal([
            .edit(path: "a.go", baseHash: hash(a), documentVersion: 1, edits: [TextEdit(startUTF16: 0, endUTF16: 7, replacement: "module")]),
            .edit(path: "b.go", baseHash: hash(b), documentVersion: 1, edits: [TextEdit(startUTF16: 0, endUTF16: 7, replacement: "module")]),
            .edit(path: "c.go", baseHash: hash(c), documentVersion: 1, edits: [TextEdit(startUTF16: 0, endUTF16: 7, replacement: "module")]),
            .create(path: "d.go", content: "package d\n")
        ])
        store.set("b.go", "package b // user edit\n")
        store.remove("c.go")
        let before = store.snapshot()
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider())
        guard case .stale(let stale) = result.outcome else {
            Issue.record("expected stale")
            return
        }
        #expect(Set(stale.map(\.path)) == ["b.go", "c.go"])
        #expect(stale.first { $0.path == "c.go" }?.reason == .missingFile)
        if case .hashMismatch = stale.first(where: { $0.path == "b.go" })?.reason {} else { Issue.record("expected hash mismatch") }
        guard case .stale(let reason) = result.proposal.status else {
            Issue.record("expected stale status")
            return
        }
        #expect(reason.contains("regenerate"))
        #expect(store.snapshot() == before)
        #expect(!store.exists("d.go"))
    }

    @Test func documentVersionMismatchIsStaleEvenWhenTextMatches() {
        let text = "package a\n"
        let store = FileStore(["a.go": text])
        store.set("a.go", text, version: 7)
        let p = proposal([.edit(path: "a.go", baseHash: hash(text), documentVersion: 3, edits: [TextEdit(startUTF16: 0, endUTF16: 1, replacement: "P")])])
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider())
        guard case .stale(let stale) = result.outcome else {
            Issue.record("expected stale")
            return
        }
        #expect(stale.first?.reason == .versionMismatch(expected: 3, actual: 7))
    }

    @Test func createTargetThatAppearedAfterProposalIsNeverOverwritten() {
        let store = FileStore([:])
        let p = proposal([.create(path: "new.go", content: "package n\n")])
        store.set("new.go", "package someone-else\n")
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: nil), current: store.provider())
        guard case .stale(let stale) = result.outcome else {
            Issue.record("expected stale")
            return
        }
        #expect(stale.first?.reason == .createTargetExists)
        #expect(store.text("new.go") == "package someone-else\n")
    }

    @Test func invalidProposalProducesNoPlanAndMarksRegenerate() {
        let store = FileStore(["a.go": "abc"])
        let p = proposal([.edit(path: "a.go", baseHash: hash("abc"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 2, replacement: "x"), TextEdit(startUTF16: 1, endUTF16: 3, replacement: "y")])])
        let result = PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider())
        guard case .invalid(let issues) = result.outcome else {
            Issue.record("expected invalid")
            return
        }
        #expect(issues.contains { $0.code == .overlappingRanges })
        if case .stale = result.proposal.status {} else { Issue.record("expected stale status") }
    }

    @Test func applyNeedsATokenBoundToTheExactProposalHash() throws {
        let store = FileStore(["a.go": "abc"])
        let p = proposal([.edit(path: "a.go", baseHash: hash("abc"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 1, replacement: "X")])])
        let tampered = proposal([.edit(path: "a.go", baseHash: hash("abc"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 1, replacement: "EVIL")])], turn: p.turnID)
        let token = approve(p)
        let wrong = PatchApplyPlanner.plan(proposal: tampered, token: token, context: context(store: store), current: store.provider())
        #expect(wrong.outcome == .notAuthorized(.proposalHashMismatch))

        let sameContentNewID = PatchProposal(turnID: p.turnID, rationale: p.rationale, operations: p.operations, verificationPlan: p.verificationPlan)
        #expect(PatchApplyPlanner.plan(proposal: sameContentNewID, token: token, context: context(store: store), current: store.provider()).outcome == .notAuthorized(.proposalHashMismatch))

        let expired = PatchApplyPlanner.plan(proposal: p, token: token, context: context(store: store), current: store.provider(), now: Date().addingTimeInterval(UserActionToken.lifetime + 5))
        #expect(expired.outcome == .notAuthorized(.tokenExpired))
        let future = UserActionToken.makeFromUserAction(approvingProposalHash: p.contentHash, at: Date().addingTimeInterval(3600))
        #expect(PatchApplyPlanner.plan(proposal: p, token: future, context: context(store: store), current: store.provider()).outcome == .notAuthorized(.tokenExpired))

        _ = try ready(PatchApplyPlanner.plan(proposal: p, token: token, context: context(store: store), current: store.provider()))
        #expect(store.reads == 1)
    }

    @Test func statusAndRationaleChangesKeepTheHashButContentChangesDoNot() {
        let p = proposal([.create(path: "a.go", content: "x")])
        #expect(p.withStatus(.rejected).contentHash == p.contentHash)
        let other = PatchProposal(id: p.id, turnID: p.turnID, rationale: "different", operations: p.operations, verificationPlan: p.verificationPlan)
        #expect(other.contentHash != p.contentHash)
        let moreAfter = p.withExpectedAfterHashes(["a.go": "h"])
        #expect(moreAfter.contentHash != p.contentHash)
    }

    @Test func rejectedOrAlreadyAppliedProposalsCannotBePlanned() {
        let store = FileStore([:])
        let p = proposal([.create(path: "a.go", content: "x")])
        for status in [PatchStatus.rejected, .applied, .rolledBack, .stale(reason: "old")] {
            let done = p.withStatus(status)
            let result = PatchApplyPlanner.plan(proposal: done, token: approve(done), context: context(store: store), current: store.provider())
            #expect(result.outcome == .notAuthorized(.proposalNotApplicable(status)))
        }
    }

    @Test func rejectPerformsNoChangeAndNoReads() {
        let store = FileStore(["a.go": "abc"])
        let p = proposal([.edit(path: "a.go", baseHash: hash("abc"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 1, replacement: "X")])])
        let readsBefore = store.reads
        let rejected = p.rejected()
        #expect(rejected.status == .rejected)
        #expect(rejected.operations == p.operations)
        #expect(rejected.id == p.id)
        #expect(store.snapshot() == ["a.go": "abc"])
        #expect(store.reads == readsBefore)
    }

    @Test func proposalRoundTripsThroughJSON() throws {
        let p = proposal([.edit(path: "a.go", baseHash: "h", documentVersion: 4, edits: [TextEdit(startUTF16: 1, endUTF16: 2, replacement: "\u{1F600}")]), .create(path: "b.go", content: "x")]).withStatus(.stale(reason: "why"))
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(PatchProposal.self, from: data) == p)
    }
}

@Suite("Apply journal and undo")
struct ApplyJournalTests {
    private struct Applied {
        let store: FileStore
        let journal: ApplyJournal
        let entry: ApplyJournalEntry
        let plan: ApplyPlan
        let original: String
    }

    private func appliedScenario(afterVersions: [String: Int] = [:]) throws -> Applied {
        let original = "package a\n\nvar x = 1\nvar y = 2\n"
        let store = FileStore(["a.go": original])
        let range = (original as NSString).range(of: "var x = 1")
        let p = proposal([
            .edit(path: "a.go", baseHash: hash(original), documentVersion: 1, edits: [TextEdit(startUTF16: range.location, endUTF16: range.location + range.length, replacement: "var x = 100")]),
            .create(path: "new.go", content: "package a\n")
        ])
        let plan = try ready(PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider()))
        var journal = ApplyJournal()
        _ = try journal.prepare(plan: plan)
        try journal.markApplying(plan.proposalID)
        let edit = try #require(plan.fileEdits.first)
        store.set("a.go", edit.afterText, version: afterVersions["a.go"])
        store.set("new.go", try #require(plan.creations.first).content, version: afterVersions["new.go"])
        try journal.markApplied(plan.proposalID, afterVersions: afterVersions)
        return Applied(store: store, journal: journal, entry: try #require(journal.entry(for: plan.proposalID)), plan: plan, original: original)
    }

    @Test func journalFollowsTheTransactionStates() throws {
        let applied = try appliedScenario()
        #expect(applied.entry.state == .applied)
        #expect(applied.entry.files.count == 2)
        #expect(applied.entry.files.first { $0.path == "new.go" }?.kind == .create)
        var journal = applied.journal
        #expect(throws: ApplyJournalError.invalidTransition(from: .applied, to: .applying)) { try journal.markApplying(applied.plan.proposalID) }
        #expect(throws: ApplyJournalError.duplicateProposal(applied.plan.proposalID)) { _ = try journal.prepare(plan: applied.plan) }
        #expect(throws: ApplyJournalError.unknownProposal(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try journal.markApplied(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        }
        try journal.markRolledBack(applied.plan.proposalID)
        #expect(journal.entry(for: applied.plan.proposalID)?.state == .rolledBack)
        #expect(throws: ApplyJournalError.invalidTransition(from: .rolledBack, to: .applied)) { try journal.markApplied(applied.plan.proposalID) }
    }

    @Test func journalSurvivesEncodeDecode() throws {
        let applied = try appliedScenario(afterVersions: ["a.go": 5])
        let data = try applied.journal.encoded()
        let decoded = try ApplyJournal.decode(data)
        #expect(decoded == applied.journal)
        #expect(decoded.entry(for: applied.plan.proposalID)?.files.first { $0.path == "a.go" }?.afterVersion == 5)
        #expect(try ApplyJournal.decode(data).encoded() == data)
    }

    @Test func recoveryClassifiesCrashStatesAndNeverMutatesOrReapplies() throws {
        let original = "AAA"
        let store = FileStore(["a.go": original, "b.go": "BBB"])
        let p = proposal([
            .edit(path: "a.go", baseHash: hash("AAA"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 3, replacement: "aaa")]),
            .edit(path: "b.go", baseHash: hash("BBB"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 3, replacement: "bbb")]),
            .create(path: "c.go", content: "ccc")
        ])
        let plan = try ready(PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider()))
        var journal = ApplyJournal()
        _ = try journal.prepare(plan: plan)
        let snapshotBefore = journal

        func observe(_ path: String) -> FileObservationInput {
            guard let text = store.text(path) else { return FileObservationInput(exists: false, contentHash: nil) }
            return FileObservationInput(exists: true, contentHash: hash(text))
        }

        var reports = journal.recover(observe: observe)
        #expect(reports.count == 1)
        #expect(reports[0].classification == .notApplied)
        #expect(reports[0].recommended == .discardPrepared)

        try journal.markApplying(plan.proposalID)
        store.set("a.go", "aaa")
        reports = journal.recover(observe: observe)
        #expect(reports[0].classification == .partiallyApplied)
        #expect(reports[0].recommended == .reviewRecoveryDiff)
        #expect(reports[0].perFile["a.go"] == .matchesAfter)
        #expect(reports[0].perFile["b.go"] == .matchesBefore)
        #expect(reports[0].perFile["c.go"] == .matchesBefore)

        store.set("b.go", "bbb")
        store.set("c.go", "ccc")
        reports = journal.recover(observe: observe)
        #expect(reports[0].classification == .fullyApplied)
        #expect(reports[0].recommended == .confirmApplied)

        store.set("b.go", "user typed something else")
        reports = journal.recover(observe: observe)
        #expect(reports[0].classification == .diverged)
        #expect(reports[0].recommended == .reviewRecoveryDiff)

        let afterRecovery = journal.entry(for: plan.proposalID)
        #expect(afterRecovery?.state == .applying)
        #expect(store.text("a.go") == "aaa")
        #expect(store.text("c.go") == "ccc")
        #expect(snapshotBefore.entries.first?.state == .prepared)
        var appliedJournal = journal
        try appliedJournal.markApplied(plan.proposalID)
        #expect(appliedJournal.recover(observe: observe).isEmpty)
    }

    @Test func recoveryTreatsAMissingEditedFileAsDiverged() throws {
        let store = FileStore(["a.go": "AAA"])
        let p = proposal([.edit(path: "a.go", baseHash: hash("AAA"), documentVersion: nil, edits: [TextEdit(startUTF16: 0, endUTF16: 3, replacement: "aaa")])])
        let plan = try ready(PatchApplyPlanner.plan(proposal: p, token: approve(p), context: context(store: store), current: store.provider()))
        var journal = ApplyJournal()
        _ = try journal.prepare(plan: plan)
        try journal.markApplying(plan.proposalID)
        let reports = journal.recover { _ in FileObservationInput(exists: false, contentHash: nil) }
        #expect(reports[0].classification == .diverged)
    }

    @Test func undoRevertsExactlyWhenAfterHashAndVersionMatch() throws {
        let applied = try appliedScenario(afterVersions: ["a.go": 4, "new.go": 1])
        let outcome = UndoPlanner.plan(entry: applied.entry, current: applied.store.provider())
        guard case .revert(let plan) = outcome else {
            Issue.record("expected revert, got \(outcome)")
            return
        }
        #expect(plan.undoGroupID == applied.plan.undoGroupID)
        let edit = try #require(plan.actions.first { $0.path == "a.go" })
        guard case .revertEdits(let inverse, let resultingHash) = edit.kind else {
            Issue.record("expected edit revert")
            return
        }
        let current = try #require(applied.store.text("a.go"))
        #expect(applyEdits(inverse, to: current) == applied.original)
        #expect(resultingHash == hash(applied.original))
        #expect(plan.actions.first { $0.path == "new.go" }?.kind == .removeCreatedFile)
    }

    @Test func userEditAfterApplyProducesRecoveryDiffAndRevertsNothing() throws {
        let applied = try appliedScenario()
        let afterApply = try #require(applied.store.text("a.go"))
        let userEdited = afterApply + "var userAdded = 3\n"
        applied.store.set("a.go", userEdited)
        let snapshot = applied.store.snapshot()
        let outcome = UndoPlanner.plan(entry: applied.entry, current: applied.store.provider())
        guard case .collision(let diffs) = outcome else {
            Issue.record("expected collision, got \(outcome)")
            return
        }
        #expect(diffs.count == 1)
        let diff = try #require(diffs.first)
        #expect(diff.path == "a.go")
        #expect(diff.reason == .contentChanged)
        #expect(diff.currentText == userEdited)
        #expect(diff.currentHash == hash(userEdited))
        #expect(diff.expectedAfterHash == hash(afterApply))
        #expect(diff.originalText == applied.original)
        #expect(diff.patchedText == afterApply)
        #expect(diff.currentToOriginal.contains { $0.kind == .removed && $0.text == "var userAdded = 3" })
        #expect(diff.currentToOriginal.contains { $0.kind == .removed && $0.text == "var x = 100" })
        #expect(diff.currentToOriginal.contains { $0.kind == .added && $0.text == "var x = 1" })
        #expect(!diff.diffTruncated)
        #expect(applied.store.snapshot() == snapshot)
        #expect(applied.store.text("new.go") == "package a\n")
    }

    @Test func versionChangeOrMissingFileAlsoCollides() throws {
        let versioned = try appliedScenario(afterVersions: ["a.go": 4])
        versioned.store.set("a.go", try #require(versioned.store.text("a.go")), version: 9)
        guard case .collision(let versionDiffs) = UndoPlanner.plan(entry: versioned.entry, current: versioned.store.provider()) else {
            Issue.record("expected collision")
            return
        }
        #expect(versionDiffs.first?.reason == .versionChanged)

        let missing = try appliedScenario()
        missing.store.remove("new.go")
        guard case .collision(let missingDiffs) = UndoPlanner.plan(entry: missing.entry, current: missing.store.provider()) else {
            Issue.record("expected collision")
            return
        }
        #expect(missingDiffs.first?.reason == .fileMissing)
        #expect(missingDiffs.first?.path == "new.go")
    }

    @Test func userModifiedCreatedFileIsNotRemoved() throws {
        let applied = try appliedScenario()
        applied.store.set("new.go", "package a\n\nfunc UserWrote() {}\n")
        guard case .collision(let diffs) = UndoPlanner.plan(entry: applied.entry, current: applied.store.provider()) else {
            Issue.record("expected collision")
            return
        }
        #expect(diffs.map(\.path) == ["new.go"])
        #expect(applied.store.text("new.go") == "package a\n\nfunc UserWrote() {}\n")
    }

    @Test func undoIsOnlyAvailableForAppliedEntries() throws {
        let applied = try appliedScenario()
        var journal = applied.journal
        try journal.markRolledBack(applied.plan.proposalID)
        let rolledBack = try #require(journal.entry(for: applied.plan.proposalID))
        #expect(UndoPlanner.plan(entry: rolledBack, current: applied.store.provider()) == .notApplicable(.rolledBack))
    }
}

@Suite("Line diff")
struct LineDiffTests {
    @Test func producesAddedRemovedAndSameLines() {
        let result = LineDiff.diff(from: "a\nb\nc\nd", to: "a\nB\nc\nd\ne")
        #expect(result.truncated == false)
        #expect(result.lines.map(\.kind) == [.same, .removed, .added, .same, .same, .added])
        #expect(result.lines.map(\.text) == ["a", "b", "B", "c", "d", "e"])
    }

    @Test func identicalTextIsAllSame() {
        let result = LineDiff.diff(from: "x\ny", to: "x\ny")
        #expect(result.lines.allSatisfy { $0.kind == .same })
    }

    @Test func hugeDifferingRegionsAreMarkedTruncatedInsteadOfAllocating() {
        let a = (0..<2000).map { "a\($0)" }.joined(separator: "\n")
        let b = (0..<2000).map { "b\($0)" }.joined(separator: "\n")
        let result = LineDiff.diff(from: a, to: b)
        #expect(result.truncated)
        #expect(result.lines.isEmpty)
    }
}
