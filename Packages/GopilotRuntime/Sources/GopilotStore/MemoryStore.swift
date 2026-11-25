import Foundation

public struct MemorySourceRef: Sendable, Equatable, Codable {
    public let path: String
    public let contentHash: String

    public init(path: String, contentHash: String) {
        self.path = path
        self.contentHash = contentHash
    }
}

public struct MemoryContextFacts: Sendable, Equatable, Codable {
    public var branch: String?
    public var buildTarget: String?
    public var moduleVersions: [String: String]

    public init(branch: String? = nil, buildTarget: String? = nil, moduleVersions: [String: String] = [:]) {
        self.branch = branch
        self.buildTarget = buildTarget
        self.moduleVersions = moduleVersions
    }
}

public struct MemoryProvenance: Sendable, Equatable, Codable {
    public var origin: String
    public var sourceConversationID: UUID?
    public var sourceTurnID: UUID?
    public var pinnedContext: MemoryContextFacts

    public init(origin: String = "user-pinned", sourceConversationID: UUID?, sourceTurnID: UUID? = nil, pinnedContext: MemoryContextFacts = MemoryContextFacts()) {
        self.origin = origin
        self.sourceConversationID = sourceConversationID
        self.sourceTurnID = sourceTurnID
        self.pinnedContext = pinnedContext
    }
}

public struct MemoryNote: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let id: UUID
    public let workspaceID: UUID
    public var content: String
    public var provenance: MemoryProvenance
    public var userApprovedAt: Date?
    public var sourceRefs: [MemorySourceRef]
    public var isStale: Bool
    public var staleReasons: [String]
    public var deletedAt: Date?

    public init(id: UUID, workspaceID: UUID, content: String, provenance: MemoryProvenance, userApprovedAt: Date?, sourceRefs: [MemorySourceRef]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.workspaceID = workspaceID
        self.content = content
        self.provenance = provenance
        self.userApprovedAt = userApprovedAt
        self.sourceRefs = sourceRefs
        self.isStale = false
        self.staleReasons = []
        self.deletedAt = nil
    }
}

public struct SnapshotFacts: Sendable, Equatable {
    public var branch: String?
    public var buildTarget: String?
    public var moduleVersions: [String: String]
    public var fileHashes: [String: String]

    public init(branch: String? = nil, buildTarget: String? = nil, moduleVersions: [String: String] = [:], fileHashes: [String: String] = [:]) {
        self.branch = branch
        self.buildTarget = buildTarget
        self.moduleVersions = moduleVersions
        self.fileHashes = fileHashes
    }
}

public struct RecalledNote: Sendable, Equatable {
    public let note: MemoryNote
    public let score: Double
    public let ageSeconds: TimeInterval
    public var isStale: Bool { note.isStale }
    public var staleReasons: [String] { note.staleReasons }
}

struct MemoryFile: Sendable, Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var workspaceID: UUID
    var recallEnabled: Bool
    var notes: [MemoryNote]
}

public actor MemoryStore {
    public static let maxRecallLimit = 10
    public static let maxNoteCharacters = 4000

    public nonisolated let workspaceID: UUID
    private let fileURL: URL
    private let fileSystem: FileSystem
    private let now: @Sendable () -> Date
    private var notesByID: [UUID: MemoryNote] = [:]
    private var tokenIndex: [String: Set<UUID>] = [:]
    private var recallCache: [String: [(id: UUID, score: Double)]] = [:]
    private var recallEnabled = true
    private var dirty = false
    private var readOnlyReason: String?
    public private(set) var cacheHitCount = 0

    public init(fileURL: URL, workspaceID: UUID, fileSystem: FileSystem, migrations: [SchemaMigration] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.workspaceID = workspaceID
        self.fileSystem = fileSystem
        self.now = now
        do {
            if let data = try Migrator.load(url: fileURL, file: .memory, currentVersion: MemoryFile.currentSchemaVersion, migrations: migrations, fileSystem: fileSystem) {
                let file = try Coding.decoder().decode(MemoryFile.self, from: data)
                recallEnabled = file.recallEnabled
                for note in file.notes { notesByID[note.id] = note }
            }
        } catch let error as StoreError {
            readOnlyReason = Migrator.recoveryDescription(for: error, file: "memory notes")
        } catch {
            readOnlyReason = Migrator.recoveryDescription(for: .corruptMetadata("Memory notes are unreadable."), file: "memory notes")
        }
        tokenIndex = Self.buildIndex(notesByID.values.filter { Self.isLive($0, workspaceID: workspaceID) })
    }

    public var recoveryDescription: String? { readOnlyReason }
    public var isRecallEnabled: Bool { recallEnabled }
    public var cachedQueryCount: Int { recallCache.count }

    public func pin(content: String, provenance: MemoryProvenance, sourceRefs: [MemorySourceRef] = []) throws -> MemoryNote {
        try requireWritable()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyNote }
        guard trimmed.count <= Self.maxNoteCharacters else { throw StoreError.noteTooLarge }
        let note = MemoryNote(id: UUID(), workspaceID: workspaceID, content: trimmed, provenance: provenance, userApprovedAt: now(), sourceRefs: sourceRefs)
        notesByID[note.id] = note
        invalidate()
        do {
            try persist()
        } catch {
            notesByID[note.id] = nil
            invalidate()
            throw error
        }
        return note
    }

    public func saveOrConsolidate(
        content: String,
        category: String? = nil,
        provenance: MemoryProvenance,
        sourceRefs: [MemorySourceRef] = []
    ) throws -> (note: MemoryNote, consolidated: Bool) {
        try requireWritable()
        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw StoreError.emptyNote }
        let formatted: String
        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty, !raw.lowercased().hasPrefix("[\(cat.lowercased())]") {
            formatted = "[\(cat)] \(raw)"
        } else {
            formatted = raw
        }
        guard formatted.count <= Self.maxNoteCharacters else { throw StoreError.noteTooLarge }

        let incomingTokens = Set(Self.tokens(in: raw))
        if !incomingTokens.isEmpty {
            for existing in notesByID.values where isLive(existing) {
                let existingTokens = Set(Self.tokens(in: existing.content))
                guard !existingTokens.isEmpty else { continue }
                let intersection = incomingTokens.intersection(existingTokens).count
                let minCount = min(incomingTokens.count, existingTokens.count)
                let unionCount = incomingTokens.union(existingTokens).count
                let overlapRatio = minCount > 0 ? Double(intersection) / Double(minCount) : 0
                let jaccard = unionCount > 0 ? Double(intersection) / Double(unionCount) : 0
                if existing.content.caseInsensitiveCompare(formatted) == .orderedSame
                    || existing.content.caseInsensitiveCompare(raw) == .orderedSame
                    || (minCount >= 3 && (overlapRatio >= 0.85 || jaccard >= 0.72)) {
                    var updated = existing
                    updated.content = formatted
                    updated.provenance = provenance
                    updated.userApprovedAt = now()
                    if !sourceRefs.isEmpty {
                        updated.sourceRefs = sourceRefs
                    }
                    updated.isStale = false
                    updated.staleReasons = []
                    notesByID[updated.id] = updated
                    invalidate()
                    try persist()
                    return (updated, true)
                }
            }
        }
        let created = try pin(content: formatted, provenance: provenance, sourceRefs: sourceRefs)
        return (created, false)
    }

    public func recentRecalled(limit: Int = MemoryStore.maxRecallLimit) -> [RecalledNote] {
        guard recallEnabled else { return [] }
        let bounded = min(max(limit, 1), Self.maxRecallLimit)
        let reference = now()
        return notes().prefix(bounded).map { note in
            RecalledNote(
                note: note,
                score: note.isStale ? 0.5 : 1.0,
                ageSeconds: reference.timeIntervalSince(note.userApprovedAt ?? reference)
            )
        }
    }

    public func delete(id: UUID) throws {
        try requireWritable()
        guard var note = notesByID[id], note.deletedAt == nil else { throw StoreError.notFound }
        note.deletedAt = now()
        note.content = ""
        note.sourceRefs = []
        note.isStale = false
        note.staleReasons = []
        notesByID[id] = note
        invalidate()
        try persist()
    }

    public func setRecallEnabled(_ enabled: Bool) throws {
        try requireWritable()
        guard enabled != recallEnabled else { return }
        recallEnabled = enabled
        invalidate()
        try persist()
    }

    @discardableResult
    public func markStale(against facts: SnapshotFacts) throws -> [UUID] {
        try requireWritable()
        var changed: [UUID] = []
        for note in notesByID.values where isLive(note) {
            let reasons = Self.staleReasons(for: note, facts: facts)
            if reasons != note.staleReasons {
                notesByID[note.id]?.staleReasons = reasons
                notesByID[note.id]?.isStale = !reasons.isEmpty
                changed.append(note.id)
            }
        }
        guard !changed.isEmpty else { return [] }
        invalidate()
        try persist()
        return changed
    }

    public func recall(query: String, limit: Int = MemoryStore.maxRecallLimit) -> [RecalledNote] {
        guard recallEnabled else { return [] }
        let bounded = min(max(limit, 1), Self.maxRecallLimit)
        let queryTokens = Self.tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        let key = queryTokens.sorted().joined(separator: " ") + "|\(bounded)"
        let ranked: [(id: UUID, score: Double)]
        if let cached = recallCache[key] {
            cacheHitCount += 1
            ranked = cached
        } else {
            ranked = rank(queryTokens: Set(queryTokens), limit: bounded)
            recallCache[key] = ranked
        }
        let reference = now()
        return ranked.compactMap { entry in
            guard let note = notesByID[entry.id], isLive(note) else { return nil }
            return RecalledNote(note: note, score: entry.score, ageSeconds: reference.timeIntervalSince(note.userApprovedAt ?? reference))
        }
    }

    public func notes() -> [MemoryNote] {
        notesByID.values.filter(isLive).sorted { ($0.userApprovedAt ?? .distantPast) > ($1.userApprovedAt ?? .distantPast) }
    }

    public func notes(derivedFrom conversationID: UUID) -> [MemoryNote] {
        notes().filter { $0.provenance.sourceConversationID == conversationID }
    }

    public func flush() throws {
        guard dirty, readOnlyReason == nil else { return }
        try persist()
    }

    private func isLive(_ note: MemoryNote) -> Bool {
        Self.isLive(note, workspaceID: workspaceID)
    }

    private static func isLive(_ note: MemoryNote, workspaceID: UUID) -> Bool {
        note.deletedAt == nil && note.userApprovedAt != nil && note.workspaceID == workspaceID
    }

    private func rank(queryTokens: Set<String>, limit: Int) -> [(id: UUID, score: Double)] {
        var candidateIDs = Set<UUID>()
        for token in queryTokens { candidateIDs.formUnion(tokenIndex[token] ?? []) }
        var scored: [(note: MemoryNote, score: Double)] = []
        for id in candidateIDs {
            guard let note = notesByID[id], isLive(note) else { continue }
            let counts = Self.tokenCounts(in: note.content)
            var score = 0.0
            for token in queryTokens {
                if let count = counts[token] { score += 1.0 + 0.1 * Double(min(count, 5)) }
            }
            if score > 0 { scored.append((note, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.note.isStale != rhs.note.isStale { return !lhs.note.isStale }
            let left = lhs.note.userApprovedAt ?? .distantPast
            let right = rhs.note.userApprovedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.note.id.uuidString < rhs.note.id.uuidString
        }
        return scored.prefix(limit).map { ($0.note.id, $0.score) }
    }

    private func invalidate() {
        recallCache.removeAll()
        rebuildIndex()
        dirty = true
    }

    private func rebuildIndex() {
        tokenIndex = Self.buildIndex(notesByID.values.filter(isLive))
    }

    private static func buildIndex(_ notes: [MemoryNote]) -> [String: Set<UUID>] {
        var index: [String: Set<UUID>] = [:]
        for note in notes {
            for token in Set(tokens(in: note.content)) { index[token, default: []].insert(note.id) }
        }
        return index
    }

    private func requireWritable() throws {
        if let readOnlyReason { throw StoreError.readOnly(readOnlyReason) }
    }

    private func persist() throws {
        let file = MemoryFile(schemaVersion: MemoryFile.currentSchemaVersion, workspaceID: workspaceID, recallEnabled: recallEnabled, notes: notesByID.values.sorted { $0.id.uuidString < $1.id.uuidString })
        do {
            try fileSystem.writeAtomically(try Coding.encoder().encode(file), to: fileURL)
            dirty = false
        } catch {
            throw StoreError.mapping(error)
        }
    }

    private static func staleReasons(for note: MemoryNote, facts: SnapshotFacts) -> [String] {
        var reasons: [String] = []
        let pinned = note.provenance.pinnedContext
        if let before = pinned.branch, let now = facts.branch, before != now {
            reasons.append("Branch changed from \(before) to \(now).")
        }
        if let before = pinned.buildTarget, let now = facts.buildTarget, before != now {
            reasons.append("Build target changed from \(before) to \(now).")
        }
        for (module, version) in pinned.moduleVersions.sorted(by: { $0.key < $1.key }) {
            if let now = facts.moduleVersions[module], now != version {
                reasons.append("Module \(module) changed from \(version) to \(now).")
            }
        }
        for ref in note.sourceRefs {
            if let now = facts.fileHashes[ref.path], now != ref.contentHash {
                reasons.append("\(ref.path) changed since this note was pinned.")
            }
        }
        return reasons
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func tokenCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens(in: text) { counts[token, default: 0] += 1 }
        return counts
    }
}
