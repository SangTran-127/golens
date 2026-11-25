import Foundation
import Testing
import GopilotRuntime
@testable import GopilotPolicy

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private func draft(_ workspace: UUID, content: String = "body", snapshot: String = "S1", refs: [SourceRef] = [], kind: EvidenceKind = .source, expiresAt: Date? = nil) -> EvidenceDraft {
    EvidenceDraft(workspaceID: workspace, producerID: "read_source:c1", kind: kind, sourceRefs: refs, snapshotID: snapshot, content: content, expiresAt: expiresAt)
}

@Suite("Evidence store")
struct EvidenceStoreTests {
    @Test func addAssignsSequentialIDsAndResolves() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let first = await store.add(draft(workspace, content: "one"))
        let second = await store.add(draft(workspace, content: "two"))
        #expect(first.id == "E1")
        #expect(second.id == "E2")
        #expect(await store.resolve(id: "E1", workspaceID: workspace) == first)
    }

    @Test func contentIsBoundedAndTruncationFlagKept() async {
        let workspace = UUID()
        let store = EvidenceStore(maxContentBytes: 10)
        let evidence = await store.add(draft(workspace, content: "ab\u{1EC7}\u{1EC7}\u{1EC7}\u{1EC7}\u{1EC7}"))
        #expect(evidence.isTruncated)
        #expect(evidence.isComplete == false)
        #expect(evidence.content.utf8.count <= 10)
        #expect(String(data: Data(evidence.content.utf8), encoding: .utf8) == evidence.content)
        let small = await store.add(draft(workspace, content: "short"))
        #expect(small.isTruncated == false)
    }

    @Test func callerSuppliedTruncationIsPreserved() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let evidence = await store.add(EvidenceDraft(workspaceID: workspace, producerID: "p", kind: .search, snapshotID: "S1", content: "x", isTruncated: true))
        #expect(evidence.isTruncated)
    }

    @Test func identicalObservationsShareOneEvidenceID() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let a = await store.add(draft(workspace))
        let b = await store.add(draft(workspace))
        let other = await store.add(draft(workspace, snapshot: "S2"))
        #expect(a.id == b.id)
        #expect(other.id != a.id)
    }

    @Test func crossWorkspaceLookupFails() async {
        let a = UUID()
        let b = UUID()
        let store = EvidenceStore()
        let evidence = await store.add(draft(a))
        #expect(await store.resolve(id: evidence.id, workspaceID: b) == nil)
        #expect(await store.lookup(id: evidence.id, workspaceID: b) == .unknown)
        #expect(await store.resolve(id: evidence.id, workspaceID: a) != nil)
    }

    @Test func expiryByDeadlineManualAndEviction() async {
        let workspace = UUID()
        let clock = Clock()
        let store = EvidenceStore(maxEntriesPerWorkspace: 2, now: { clock.now })
        let timed = await store.add(draft(workspace, content: "t", expiresAt: clock.now.addingTimeInterval(60)))
        #expect(await store.resolve(id: timed.id, workspaceID: workspace) != nil)
        clock.advance(61)
        #expect(await store.lookup(id: timed.id, workspaceID: workspace) == .expired(timed.id))
        #expect(await store.resolve(id: timed.id, workspaceID: workspace) == nil)

        let manual = await store.add(draft(workspace, content: "m"))
        await store.expire(id: manual.id, workspaceID: workspace)
        #expect(await store.lookup(id: manual.id, workspaceID: workspace) == .expired(manual.id))

        let x = await store.add(draft(workspace, content: "x"))
        let y = await store.add(draft(workspace, content: "y"))
        let z = await store.add(draft(workspace, content: "z"))
        #expect(await store.lookup(id: x.id, workspaceID: workspace) == .expired(x.id))
        #expect(await store.resolve(id: y.id, workspaceID: workspace) != nil)
        #expect(await store.resolve(id: z.id, workspaceID: workspace) != nil)
    }

    @Test func expireAllMarksWholeWorkspaceExpired() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let evidence = await store.add(draft(workspace))
        await store.expireAll(workspaceID: workspace)
        #expect(await store.lookup(id: evidence.id, workspaceID: workspace) == .expired(evidence.id))
        #expect(await store.count(workspaceID: workspace) == 0)
    }
}

@Suite("Snapshot staleness")
struct StalenessTests {
    private func evidence(workspace: UUID, snapshot: String, refs: [SourceRef]) async -> Evidence {
        await EvidenceStore().add(draft(workspace, snapshot: snapshot, refs: refs))
    }

    @Test func sameSnapshotIsFresh() async {
        let workspace = UUID()
        let item = await evidence(workspace: workspace, snapshot: "S1", refs: [])
        let store = EvidenceStore()
        #expect(await store.isStale(item, against: makeSnapshot("S1", workspace: workspace)).isStale == false)
    }

    @Test func changedSnapshotMarksStale() async {
        let workspace = UUID()
        let item = await evidence(workspace: workspace, snapshot: "S1", refs: [])
        let result = Staleness.assess(item, against: makeSnapshot("S2", workspace: workspace))
        #expect(result.isStale)
        #expect(result.reasons == [.snapshotChanged])
    }

    @Test func documentVersionAndHashChangesAreNamed() async {
        let workspace = UUID()
        let ref = SourceRef(workspaceID: workspace, path: "a.go", contentHash: "h1", documentVersion: 3)
        let item = await evidence(workspace: workspace, snapshot: "S1", refs: [ref])
        let next = makeSnapshot("S2", workspace: workspace, versions: ["a.go": 4], hashes: ["a.go": "h2"])
        let result = Staleness.assess(item, against: next)
        #expect(result.reasons.contains(.documentVersionChanged))
        #expect(result.reasons.contains(.contentHashChanged))
    }

    @Test func otherWorkspaceSnapshotIsAlwaysStale() async {
        let item = await evidence(workspace: UUID(), snapshot: "S1", refs: [])
        let result = Staleness.assess(item, against: makeSnapshot("S1", workspace: UUID()))
        #expect(result.reasons == [.workspaceMismatch])
    }
}

@Suite("Citation resolver")
struct CitationResolverTests {
    @Test func knownTokensResolveAndTextIsPreserved() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let evidence = await store.add(draft(workspace, refs: [SourceRef(workspaceID: workspace, path: "a.go")]))
        let segments = await CitationResolver().resolve("Create saves the order [\(evidence.id)]. Done.", workspaceID: workspace, store: store)
        #expect(segments == [.text("Create saves the order "), .citation(evidence), .text(". Done.")])
    }

    @Test func forgedUnknownAndOtherWorkspaceTokensAreUnverified() async {
        let a = UUID()
        let b = UUID()
        let store = EvidenceStore()
        let foreign = await store.add(draft(b, content: "foreign"))
        let text = "see [E999] and [\(foreign.id)] and [E0]"
        let segments = await CitationResolver().resolve(text, workspaceID: a, store: store)
        let unverified = segments.compactMap { segment -> String? in
            if case .unverifiedCitation(let token, _) = segment { return token }
            return nil
        }
        #expect(unverified == ["[E999]", "[\(foreign.id)]", "[E0]"])
        #expect(segments.contains { if case .citation = $0 { return true } else { return false } } == false)
    }

    @Test func expiredEvidenceIsReportedAsExpiredNotResolved() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let evidence = await store.add(draft(workspace))
        await store.expire(id: evidence.id, workspaceID: workspace)
        let segments = await CitationResolver().resolve("[\(evidence.id)]", workspaceID: workspace, store: store)
        #expect(segments == [.unverifiedCitation(token: "[\(evidence.id)]", reason: .expired)])
    }

    @Test func pathsAndLinksInModelTextNeverBecomeCitations() async {
        let workspace = UUID()
        let store = EvidenceStore()
        let text = "open [/etc/passwd:1] or [file](file:///Users/me/.ssh/id_rsa) or [E1](../../secret) or [e1] or [E1x] or [E 1]"
        let segments = await CitationResolver().resolve(text, workspaceID: workspace, store: store)
        for segment in segments {
            if case .citation = segment { Issue.record("a citation resolved without evidence") }
        }
        let joined = segments.map { segment -> String in
            switch segment {
            case .text(let value): return value
            case .unverifiedCitation(let token, _): return token
            case .citation: return ""
            }
        }.joined()
        #expect(joined == text)
        #expect(segments.contains(.unverifiedCitation(token: "[E1]", reason: .unknown)))
    }

    @Test func resolvedEvidenceAlwaysBelongsToTheRequestedWorkspace() async {
        let a = UUID()
        let b = UUID()
        let store = EvidenceStore()
        let mine = await store.add(draft(a, content: "mine"))
        let theirs = await store.add(draft(b, content: "theirs"))
        let segments = await CitationResolver().resolve("[\(mine.id)] [\(theirs.id)]", workspaceID: a, store: store)
        let resolved = segments.compactMap { segment -> Evidence? in
            if case .citation(let evidence) = segment { return evidence }
            return nil
        }
        #expect(resolved == [mine])
    }
}

@Suite("Range conversion")
struct RangeConverterTests {
    private let vietnamese = "Vi\u{1EC7}t Nam \u{1F600} x"

    @Test func utf8AndUTF16OffsetsAroundVietnameseAndEmoji() {
        let converter = RangeConverter(vietnamese)
        #expect(converter.utf16Length == 13)
        #expect(converter.utf8Length == 17)
        #expect(converter.utf8Offset(utf16Offset: 3) == 5)
        #expect(converter.utf16Offset(utf8Offset: 5) == 3)
        #expect(converter.utf8Offset(utf16Offset: 9) == 11)
        #expect(converter.utf8Offset(utf16Offset: 11) == 15)
        #expect(converter.utf16Offset(utf8Offset: 15) == 11)
    }

    @Test func offsetsInsideAScalarAreRejected() {
        let converter = RangeConverter(vietnamese)
        #expect(converter.utf16Offset(utf8Offset: 3) == nil)
        #expect(converter.utf16Offset(utf8Offset: 4) == nil)
        #expect(converter.utf16Offset(utf8Offset: 12) == nil)
        #expect(converter.utf8Offset(utf16Offset: 10) == nil)
        #expect(converter.utf8Offset(utf16Offset: 99) == nil)
        #expect(converter.utf8Offset(utf16Offset: -1) == nil)
    }

    @Test func combiningMarksAreCountedPerScalar() {
        let converter = RangeConverter("e\u{0323}\u{0302}x")
        #expect(converter.utf16Length == 4)
        #expect(converter.utf8Length == 6)
        #expect(converter.utf8Offset(utf16Offset: 3) == 5)
    }

    @Test func lineAndColumnAreOneBasedUTF16WithEmojiAndCRLF() {
        let converter = RangeConverter("ab\n\u{1F600}c\r\nd")
        #expect(converter.lineCount == 3)
        #expect(converter.lspPosition(utf16Offset: 5) == LSPPosition(line: 1, character: 2))
        #expect(converter.lineColumn(utf16Offset: 5) == LineColumn(line: 2, column: 3))
        #expect(converter.utf16Offset(lineColumn: LineColumn(line: 2, column: 3)) == 5)
        #expect(converter.lineColumn(utf16Offset: 8) == LineColumn(line: 3, column: 1))
        #expect(converter.utf8Offset(lineColumn: LineColumn(line: 2, column: 3)) == 7)
        #expect(converter.lineColumn(utf8Offset: 7) == LineColumn(line: 2, column: 3))
    }

    @Test func positionsInsideSurrogatePairsOrPastLineEndAreRejected() {
        let converter = RangeConverter("ab\n\u{1F600}c\r\nd")
        #expect(converter.utf16Offset(position: LSPPosition(line: 1, character: 1)) == nil)
        #expect(converter.utf16Offset(position: LSPPosition(line: 1, character: 4)) == nil)
        #expect(converter.utf16Offset(position: LSPPosition(line: 5, character: 0)) == nil)
        #expect(converter.utf16Offset(position: LSPPosition(line: 1, character: 3)) == 6)
    }

    @Test func roundTripsEveryScalarBoundary() {
        let text = "Ti\u{1EBF}ng Vi\u{1EC7}t \u{1F600}\u{1F4A1}\nd\u{00F2}ng hai\nx"
        let converter = RangeConverter(text)
        var utf16 = 0
        var utf8 = 0
        for scalar in text.unicodeScalars {
            #expect(converter.utf8Offset(utf16Offset: utf16) == utf8)
            #expect(converter.utf16Offset(utf8Offset: utf8) == utf16)
            let position = converter.lspPosition(utf16Offset: utf16)
            #expect(position.flatMap { converter.utf16Offset(position: $0) } == utf16)
            utf16 += scalar.value > 0xFFFF ? 2 : 1
            utf8 += String(scalar).utf8.count
        }
        #expect(converter.utf16Length == utf16)
        #expect(converter.utf8Length == utf8)
    }
}
