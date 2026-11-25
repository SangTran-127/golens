import Foundation

public enum EvidenceLookup: Sendable, Equatable {
    case found(Evidence)
    case expired(String)
    case unknown
}

public actor EvidenceStore {
    public static let defaultMaxContentBytes = 64 * 1024
    public static let defaultMaxEntriesPerWorkspace = 1000

    private let maxContentBytes: Int
    private let maxEntries: Int
    private let now: @Sendable () -> Date
    private var counter = 0
    private var entries: [UUID: [String: Evidence]] = [:]
    private var order: [UUID: [String]] = [:]
    private var dedupe: [String: String] = [:]
    private var expired: [UUID: Set<String>] = [:]

    public init(maxContentBytes: Int = EvidenceStore.defaultMaxContentBytes, maxEntriesPerWorkspace: Int = EvidenceStore.defaultMaxEntriesPerWorkspace, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxContentBytes = maxContentBytes
        self.maxEntries = maxEntriesPerWorkspace
        self.now = now
    }

    @discardableResult
    public func add(_ draft: EvidenceDraft) -> Evidence {
        let bounded = TextBounds.truncate(draft.content, maxBytes: maxContentBytes)
        let truncated = draft.isTruncated || bounded.truncated
        let hash = Hashing.sha256Hex(bounded.text)
        let key = Self.dedupeKey(draft, contentHash: hash, truncated: truncated)

        if let existingID = dedupe[key], let existing = entries[draft.workspaceID]?[existingID], !isExpired(existing) {
            return existing
        }

        counter += 1
        let evidence = Evidence(
            id: "E\(counter)",
            workspaceID: draft.workspaceID,
            producerID: draft.producerID,
            kind: draft.kind,
            sourceRefs: draft.sourceRefs,
            capturedAt: now(),
            snapshotID: draft.snapshotID,
            content: bounded.text,
            contentHash: hash,
            isTruncated: truncated,
            basis: draft.basis,
            expiresAt: draft.expiresAt
        )
        entries[draft.workspaceID, default: [:]][evidence.id] = evidence
        order[draft.workspaceID, default: []].append(evidence.id)
        dedupe[key] = evidence.id
        evictIfNeeded(workspaceID: draft.workspaceID)
        return evidence
    }

    public func restore(_ evidence: Evidence) {
        guard evidence.id.hasPrefix("E"), let number = Int(evidence.id.dropFirst()), number > 0 else { return }
        counter = max(counter, number)
        if entries[evidence.workspaceID]?[evidence.id] == nil {
            order[evidence.workspaceID, default: []].append(evidence.id)
        }
        entries[evidence.workspaceID, default: [:]][evidence.id] = evidence
        expired[evidence.workspaceID]?.remove(evidence.id)
        evictIfNeeded(workspaceID: evidence.workspaceID)
    }

    public func all(workspaceID: UUID) -> [Evidence] {
        (order[workspaceID] ?? []).compactMap { entries[workspaceID]?[$0] }
    }

    public func lookup(id: String, workspaceID: UUID) -> EvidenceLookup {
        if let evidence = entries[workspaceID]?[id] {
            return isExpired(evidence) ? .expired(id) : .found(evidence)
        }
        if expired[workspaceID]?.contains(id) == true { return .expired(id) }
        return .unknown
    }

    public func resolve(id: String, workspaceID: UUID) -> Evidence? {
        if case .found(let evidence) = lookup(id: id, workspaceID: workspaceID) { return evidence }
        return nil
    }

    public func expire(id: String, workspaceID: UUID) {
        guard entries[workspaceID]?[id] != nil else { return }
        entries[workspaceID]?[id] = nil
        order[workspaceID]?.removeAll { $0 == id }
        expired[workspaceID, default: []].insert(id)
    }

    public func expireAll(workspaceID: UUID) {
        for id in order[workspaceID] ?? [] { expired[workspaceID, default: []].insert(id) }
        entries[workspaceID] = nil
        order[workspaceID] = nil
    }

    public func count(workspaceID: UUID) -> Int {
        entries[workspaceID]?.count ?? 0
    }

    public func isStale(_ evidence: Evidence, against snapshot: SourceSnapshot) -> Staleness {
        Staleness.assess(evidence, against: snapshot)
    }

    private func isExpired(_ evidence: Evidence) -> Bool {
        guard let deadline = evidence.expiresAt else { return false }
        return now() >= deadline
    }

    private func evictIfNeeded(workspaceID: UUID) {
        while (order[workspaceID]?.count ?? 0) > maxEntries, let oldest = order[workspaceID]?.first {
            order[workspaceID]?.removeFirst()
            entries[workspaceID]?[oldest] = nil
            expired[workspaceID, default: []].insert(oldest)
        }
    }

    private static func dedupeKey(_ draft: EvidenceDraft, contentHash: String, truncated: Bool) -> String {
        let refs = draft.sourceRefs.map { ref in
            [ref.dependencyRootID ?? "", ref.path, ref.contentHash ?? "", ref.documentVersion.map(String.init) ?? "",
             ref.symbolID ?? "", ref.range.map { "\($0.startLine):\($0.startCharacter)-\($0.endLine):\($0.endCharacter)" } ?? ""].joined(separator: "|")
        }.joined(separator: ";")
        return [draft.workspaceID.uuidString, draft.snapshotID, draft.kind.rawValue, draft.basis.rawValue, refs, contentHash, truncated ? "t" : "c"].joined(separator: "#")
    }
}
