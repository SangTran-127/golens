import Foundation
import GopilotRuntime

public struct StoreLimits: Sendable, Equatable {
    public var maxConversations: Int
    public var maxTranscriptBytes: Int
    public var maxEvidenceBytes: Int
    public var maxArtifactBytes: Int
    public var trashUndoWindow: TimeInterval
    public var flushRecordThreshold: Int
    public var flushInterval: TimeInterval

    public init(maxConversations: Int = 100, maxTranscriptBytes: Int = 50 * 1024 * 1024, maxEvidenceBytes: Int = 200 * 1024 * 1024, maxArtifactBytes: Int = 32 * 1024 * 1024, trashUndoWindow: TimeInterval = 7 * 24 * 3600, flushRecordThreshold: Int = 8, flushInterval: TimeInterval = 2) {
        self.maxConversations = maxConversations
        self.maxTranscriptBytes = maxTranscriptBytes
        self.maxEvidenceBytes = maxEvidenceBytes
        self.maxArtifactBytes = maxArtifactBytes
        self.trashUndoWindow = trashUndoWindow
        self.flushRecordThreshold = flushRecordThreshold
        self.flushInterval = flushInterval
    }
}

public enum StoreMode: Sendable, Equatable {
    case readWrite
    case readOnly(recovery: String)
}

public struct StoreUsage: Sendable, Equatable {
    public let conversationCount: Int
    public let trashedCount: Int
    public let conversationLimit: Int
    public let transcriptBytes: Int
    public let transcriptLimitBytes: Int
    public let evidenceBytes: Int
    public let evidenceLimitBytes: Int
}

public struct EvictionToken: Sendable, Equatable {
    public let rawValue: String
}

public struct EvictionPreview: Sendable, Equatable {
    public let candidates: [ConversationSummary]
    public let reclaimedBytes: Int
    public let token: EvictionToken
}

public struct TrashReceipt: Sendable, Equatable {
    public let conversationID: UUID
    public let trashedAt: Date
    public let undoDeadline: Date
}

public struct PermanentDeleteReport: Sendable, Equatable {
    public let conversationID: UUID
    public let derivedNotes: [MemoryNote]
}

public struct RecoveryReport: Sendable, Equatable {
    public let skippedJournalLines: Int
    public let interruptedTurnIDs: [UUID]
    public let unknownToolCallIDs: [String]
    public let repairedToolCallIDs: [String]
}

public struct OpenedConversation: Sendable, Equatable {
    public let conversation: Conversation
    public let recovery: RecoveryReport
    public let isReadOnly: Bool
}

public enum EvidenceFreshness: Sendable, Equatable {
    case current
    case needsRefresh
}

public struct ResumeResult: Sendable, Equatable {
    public let conversationID: UUID
    public let evidenceIDsNeedingRefresh: [String]
    public let interruptedTurnIDs: [UUID]
    public let unknownToolCallIDs: [String]
}

struct WorkspaceIndex: Sendable, Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var workspaceID: UUID
    var entries: [ConversationSummary]
}

public actor WorkspaceStore {
    public nonisolated let workspaceID: UUID
    public nonisolated let rootURL: URL
    public nonisolated let limits: StoreLimits
    public nonisolated let artifacts: ArtifactStore
    public nonisolated let memory: MemoryStore
    nonisolated let fileSystem: FileSystem
    nonisolated let now: @Sendable () -> Date

    public private(set) var mode: StoreMode = .readWrite
    private var entries: [UUID: ConversationSummary] = [:]
    private var indexDirty = false
    private var writableIDs = Set<UUID>()
    private var recorders: [UUID: SessionRecorder] = [:]

    public init(baseURL: URL, workspaceID: UUID, fileSystem: FileSystem = LocalFileSystem(), limits: StoreLimits = StoreLimits(), migrations: [SchemaMigration] = [], now: @escaping @Sendable () -> Date = { Date() }) throws {
        let root = baseURL.appendingPathComponent("workspaces", isDirectory: true).appendingPathComponent(workspaceID.uuidString, isDirectory: true)
        self.workspaceID = workspaceID
        self.rootURL = root
        self.limits = limits
        self.fileSystem = fileSystem
        self.now = now
        self.artifacts = ArtifactStore(directory: root.appendingPathComponent("artifacts", isDirectory: true), maxTotalBytes: limits.maxEvidenceBytes, maxArtifactBytes: limits.maxArtifactBytes, fileSystem: fileSystem, migrations: migrations, now: now)
        self.memory = MemoryStore(fileURL: root.appendingPathComponent("memory.json"), workspaceID: workspaceID, fileSystem: fileSystem, migrations: migrations, now: now)
        do {
            try fileSystem.createDirectory(root)
        } catch {
            throw StoreError.mapping(error)
        }
        let loaded = Self.loadIndex(root: root, fileSystem: fileSystem, migrations: migrations)
        self.entries = loaded.entries
        self.indexDirty = loaded.dirty
        if let recovery = loaded.recovery { self.mode = .readOnly(recovery: recovery) }
    }

    public func listConversations(includeTrashed: Bool = false) -> [ConversationSummary] {
        entries.values
            .filter { includeTrashed || $0.trashedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func trashedConversations() -> [ConversationSummary] {
        entries.values.filter { $0.trashedAt != nil }.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    public func expiredTrash() -> [ConversationSummary] {
        let reference = now()
        return trashedConversations().filter { reference.timeIntervalSince($0.trashedAt ?? reference) > limits.trashUndoWindow }
    }

    public func usage() async -> StoreUsage {
        StoreUsage(
            conversationCount: entries.values.filter { $0.trashedAt == nil }.count,
            trashedCount: entries.values.filter { $0.trashedAt != nil }.count,
            conversationLimit: limits.maxConversations,
            transcriptBytes: totalTranscriptBytes,
            transcriptLimitBytes: limits.maxTranscriptBytes,
            evidenceBytes: await artifacts.totalBytes,
            evidenceLimitBytes: limits.maxEvidenceBytes
        )
    }

    public func createConversation(providerID: String, modelID: String, title: String) throws -> Conversation {
        try requireWritable()
        guard entries.values.filter({ $0.trashedAt == nil }).count < limits.maxConversations else { throw StoreError.conversationLimitReached }
        let id = UUID()
        let created = now()
        let header = ConversationHeader(workspaceID: workspaceID, providerID: providerID, modelID: modelID, title: title, createdAt: created)
        var record = JournalRecord(seq: 1, at: created, kind: .conversationCreated)
        record.header = header
        let line: Data
        do { line = try record.encodedLine() } catch { throw StoreError.mapping(error) }
        guard totalTranscriptBytes + line.count <= limits.maxTranscriptBytes else { throw StoreError.transcriptLimitReached }
        do {
            try fileSystem.append(line, to: journalURL(id))
        } catch {
            try? fileSystem.remove(journalURL(id))
            throw StoreError.mapping(error)
        }
        entries[id] = ConversationSummary(id: id, workspaceID: workspaceID, providerID: providerID, modelID: modelID, title: title, createdAt: created, updatedAt: created, transcriptBytes: line.count)
        indexDirty = true
        writableIDs.insert(id)
        try persistIndex()
        return Conversation(id: id, workspaceID: workspaceID, providerID: providerID, modelID: modelID, title: title, createdAt: created, updatedAt: created)
    }

    public func openConversation(id: UUID) throws -> OpenedConversation {
        guard let entry = entries[id] else { throw StoreError.notFound }
        let loaded = try loadJournal(id: id, summary: entry)
        guard let conversation = loaded.builder.build(finalize: true) else { throw StoreError.corruptMetadata("Conversation header is missing.") }
        let interrupted = conversation.turns.filter { $0.terminal == .interrupted }.map(\.id)
        let unknown = conversation.turns.flatMap { $0.toolLifecycles.filter { $0.state == .unknown }.map(\.callID) }
        let repaired = conversation.turns.flatMap(\.repairedCallIDs)
        return OpenedConversation(
            conversation: conversation,
            recovery: RecoveryReport(skippedJournalLines: loaded.skippedLines, interruptedTurnIDs: interrupted, unknownToolCallIDs: unknown, repairedToolCallIDs: repaired),
            isReadOnly: !writableIDs.contains(id)
        )
    }

    public func resume(id: UUID, revalidate: @Sendable (String) async -> EvidenceFreshness) async throws -> ResumeResult {
        try requireWritable()
        let opened = try openConversation(id: id)
        var needing: [String] = []
        var seen = Set<String>()
        for turn in opened.conversation.turns {
            for evidenceID in turn.evidenceIDs where seen.insert(evidenceID).inserted {
                if await revalidate(evidenceID) == .needsRefresh { needing.append(evidenceID) }
            }
        }
        writableIDs.insert(id)
        return ResumeResult(conversationID: id, evidenceIDsNeedingRefresh: needing, interruptedTurnIDs: opened.recovery.interruptedTurnIDs, unknownToolCallIDs: opened.recovery.unknownToolCallIDs)
    }

    public func artifactFreshness(_ evidenceID: String) async -> EvidenceFreshness {
        await artifacts.status(id: evidenceID) == .available ? .current : .needsRefresh
    }

    public func recorder(for id: UUID) throws -> SessionRecorder {
        try requireWritable()
        guard let entry = entries[id] else { throw StoreError.notFound }
        guard writableIDs.contains(id) else { throw StoreError.conversationReadOnly }
        if let existing = recorders[id] { return existing }
        let loaded = try loadJournal(id: id, summary: entry)
        let created = SessionRecorder(store: self, conversationID: id, builder: loaded.builder)
        recorders[id] = created
        return created
    }

    public func trash(id: UUID) throws -> TrashReceipt {
        try requireWritable()
        guard entries[id] != nil else { throw StoreError.notFound }
        let moment = now()
        entries[id]?.trashedAt = moment
        indexDirty = true
        do { try persistIndex() } catch {
            entries[id]?.trashedAt = nil
            throw error
        }
        return TrashReceipt(conversationID: id, trashedAt: moment, undoDeadline: moment.addingTimeInterval(limits.trashUndoWindow))
    }

    public func undoTrash(id: UUID) throws {
        try requireWritable()
        guard let entry = entries[id], let trashedAt = entry.trashedAt else { throw StoreError.notInTrash }
        guard now().timeIntervalSince(trashedAt) <= limits.trashUndoWindow else { throw StoreError.undoWindowExpired }
        guard entries.values.filter({ $0.trashedAt == nil }).count < limits.maxConversations else { throw StoreError.conversationLimitReached }
        entries[id]?.trashedAt = nil
        indexDirty = true
        do { try persistIndex() } catch {
            entries[id]?.trashedAt = trashedAt
            throw error
        }
    }

    public func permanentlyDelete(id: UUID) async throws -> PermanentDeleteReport {
        try requireWritable()
        guard entries[id] != nil else { throw StoreError.notFound }
        let derived = await memory.notes(derivedFrom: id)
        do { try fileSystem.remove(journalURL(id)) } catch { throw StoreError.mapping(error) }
        entries[id] = nil
        writableIDs.remove(id)
        recorders[id] = nil
        indexDirty = true
        try persistIndex()
        return PermanentDeleteReport(conversationID: id, derivedNotes: derived)
    }

    public func previewEviction() -> EvictionPreview {
        let candidates = evictionCandidates()
        return EvictionPreview(candidates: candidates, reclaimedBytes: candidates.reduce(0) { $0 + $1.transcriptBytes }, token: Self.token(for: candidates))
    }

    public func evict(confirming preview: EvictionPreview) throws -> [UUID] {
        try requireWritable()
        let current = evictionCandidates()
        guard preview.token == Self.token(for: current), preview.candidates == current else { throw StoreError.invalidConfirmation }
        var removed: [UUID] = []
        for candidate in current {
            do { try fileSystem.remove(journalURL(candidate.id)) } catch {
                if !removed.isEmpty { indexDirty = true; try? persistIndex() }
                throw StoreError.mapping(error)
            }
            entries[candidate.id] = nil
            writableIDs.remove(candidate.id)
            recorders[candidate.id] = nil
            removed.append(candidate.id)
        }
        if !removed.isEmpty {
            indexDirty = true
            try persistIndex()
        }
        return removed
    }

    public func previewExport(conversationIDs: [UUID]? = nil, includeMemory: Bool = false, redactor: @escaping @Sendable (String) -> String) async throws -> ExportPreview {
        let ids = conversationIDs ?? listConversations().map(\.id)
        var files: [ExportFile] = []
        let redact = Redaction(redactor)
        for id in ids {
            let opened = try openConversation(id: id)
            let redacted = redact.conversation(opened.conversation)
            files.append(ExportFile(name: "conversation-\(id.uuidString).json", data: try Self.exportEncoder().encode(redacted), conversationID: id))
        }
        if includeMemory {
            let notes = await memory.notes().map { redact.note($0) }
            files.append(ExportFile(name: "memory-notes.json", data: try Self.exportEncoder().encode(notes), conversationID: nil))
        }
        return ExportPreview(files: files, redactedStringCount: redact.changedCount)
    }

    public func export(_ preview: ExportPreview, to directory: URL) throws {
        for file in preview.files {
            do { try fileSystem.writeAtomically(file.data, to: directory.appendingPathComponent(file.name)) } catch {
                throw StoreError.mapping(error)
            }
        }
    }

    public func flush() async throws {
        if indexDirty, case .readWrite = mode { try persistIndex() }
        try await artifacts.flush()
        try await memory.flush()
    }

    func appendJournal(id: UUID, data: Data, updatedAt: Date, turnCount: Int, title: String?) throws {
        try requireWritable()
        guard entries[id] != nil else { throw StoreError.notFound }
        guard totalTranscriptBytes + data.count <= limits.maxTranscriptBytes else { throw StoreError.transcriptLimitReached }
        do { try fileSystem.append(data, to: journalURL(id)) } catch { throw StoreError.mapping(error) }
        if var entry = entries[id] {
            entry.transcriptBytes += data.count
            entry.updatedAt = max(entry.updatedAt, updatedAt)
            entry.turnCount = turnCount
            if let title { entry.title = title }
            entries[id] = entry
        }
        indexDirty = true
    }

    func persistIndexIfDirty() throws {
        if indexDirty { try persistIndex() }
    }

    private var totalTranscriptBytes: Int {
        entries.values.reduce(0) { $0 + $1.transcriptBytes }
    }

    private func requireWritable() throws {
        if case .readOnly(let recovery) = mode { throw StoreError.readOnly(recovery) }
    }

    private func journalURL(_ id: UUID) -> URL {
        Self.journalURL(root: rootURL, id)
    }

    private var indexURL: URL { rootURL.appendingPathComponent("index.json") }

    private func loadJournal(id: UUID, summary: ConversationSummary?) throws -> (builder: ConversationBuilder, skippedLines: Int) {
        let data: Data
        do { data = try fileSystem.read(journalURL(id)) } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
        let result = JournalReader.read(data)
        let fallback = summary.map { ConversationHeader(workspaceID: $0.workspaceID, providerID: $0.providerID, modelID: $0.modelID, title: $0.title, createdAt: $0.createdAt) }
        var builder = ConversationBuilder(id: id, fallback: fallback, updatedAt: summary?.createdAt ?? .distantPast)
        for record in result.records { builder.apply(record) }
        return (builder, result.skippedLines)
    }

    private func persistIndex() throws {
        let index = WorkspaceIndex(schemaVersion: WorkspaceIndex.currentSchemaVersion, workspaceID: workspaceID, entries: entries.values.sorted { $0.createdAt < $1.createdAt })
        do {
            try fileSystem.writeAtomically(try Coding.encoder().encode(index), to: indexURL)
            indexDirty = false
        } catch {
            throw StoreError.mapping(error)
        }
    }

    private static func journalURL(root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("conversations", isDirectory: true).appendingPathComponent("\(id.uuidString).jsonl")
    }

    private static func loadIndex(root: URL, fileSystem: FileSystem, migrations: [SchemaMigration]) -> (entries: [UUID: ConversationSummary], dirty: Bool, recovery: String?) {
        var entries: [UUID: ConversationSummary] = [:]
        var dirty = false
        var recovery: String?
        var loaded: [ConversationSummary] = []
        do {
            if let data = try Migrator.load(url: root.appendingPathComponent("index.json"), file: .index, currentVersion: WorkspaceIndex.currentSchemaVersion, migrations: migrations, fileSystem: fileSystem) {
                loaded = try Coding.decoder().decode(WorkspaceIndex.self, from: data).entries
            }
        } catch let error as StoreError {
            recovery = Migrator.recoveryDescription(for: error, file: "the conversation index")
        } catch {
            recovery = Migrator.recoveryDescription(for: .corruptMetadata("The conversation index is unreadable."), file: "the conversation index")
        }
        for entry in loaded {
            entries[entry.id] = entry
            if let size = fileSystem.size(of: journalURL(root: root, entry.id)) { entries[entry.id]?.transcriptBytes = size }
        }
        let journals = ((try? fileSystem.contents(of: root.appendingPathComponent("conversations", isDirectory: true))) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        for url in journals {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), entries[id] == nil else { continue }
            guard let data = try? fileSystem.read(url) else { continue }
            var builder = ConversationBuilder(id: id, fallback: nil, updatedAt: .distantPast)
            for record in JournalReader.read(data).records { builder.apply(record) }
            guard let conversation = builder.build(finalize: true) else { continue }
            entries[id] = ConversationSummary(id: id, workspaceID: conversation.workspaceID, providerID: conversation.providerID, modelID: conversation.modelID, title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, turnCount: conversation.turns.count, transcriptBytes: data.count)
            dirty = true
        }
        return (entries, recovery == nil && dirty, recovery)
    }

    private func evictionCandidates() -> [ConversationSummary] {
        let ordered = entries.values.sorted { lhs, rhs in
            if (lhs.trashedAt != nil) != (rhs.trashedAt != nil) { return lhs.trashedAt != nil }
            return lhs.updatedAt < rhs.updatedAt
        }
        var liveCount = entries.values.filter { $0.trashedAt == nil }.count
        var bytes = totalTranscriptBytes
        let byteTarget = Int(Double(limits.maxTranscriptBytes) * 0.8)
        var chosen: [ConversationSummary] = []
        for entry in ordered {
            let needsCount = liveCount > limits.maxConversations - 1
            let needsBytes = bytes > byteTarget
            if !needsCount && !needsBytes { break }
            guard needsBytes || entry.trashedAt == nil else { continue }
            chosen.append(entry)
            bytes -= entry.transcriptBytes
            if entry.trashedAt == nil { liveCount -= 1 }
        }
        return chosen
    }

    private static func token(for candidates: [ConversationSummary]) -> EvictionToken {
        let material = candidates.map { "\($0.id.uuidString):\($0.transcriptBytes):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
        return EvictionToken(rawValue: ContentHash.sha256Hex("evict|" + material))
    }

    private static func exportEncoder() -> JSONEncoder {
        let encoder = Coding.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
