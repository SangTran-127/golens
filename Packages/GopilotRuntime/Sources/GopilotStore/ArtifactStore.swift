import Foundation

public enum ArtifactLookup: Sendable, Equatable {
    case found(Data, contentHash: String)
    case expired(contentHash: String)
    case missing
}

struct ArtifactEntry: Sendable, Equatable, Codable {
    var id: String
    var contentHash: String
    var size: Int
    var lastAccessed: Date
    var tick: Int
    var expired: Bool
}

struct ArtifactIndex: Sendable, Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var entries: [ArtifactEntry]
}

public actor ArtifactStore {
    private let directory: URL
    private let fileSystem: FileSystem
    private let maxTotalBytes: Int
    private let maxArtifactBytes: Int
    private let now: @Sendable () -> Date
    private var entries: [String: ArtifactEntry] = [:]
    private var nextTick = 0
    private var dirty = false
    private var readOnlyReason: String?

    public init(directory: URL, maxTotalBytes: Int, maxArtifactBytes: Int, fileSystem: FileSystem, migrations: [SchemaMigration] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.maxTotalBytes = maxTotalBytes
        self.maxArtifactBytes = maxArtifactBytes
        self.now = now
        let indexURL = directory.appendingPathComponent("index.json")
        do {
            if let data = try Migrator.load(url: indexURL, file: .artifactIndex, currentVersion: ArtifactIndex.currentSchemaVersion, migrations: migrations, fileSystem: fileSystem) {
                let index = try Coding.decoder().decode(ArtifactIndex.self, from: data)
                for entry in index.entries { entries[entry.id] = entry }
                nextTick = (index.entries.map(\.tick).max() ?? 0) + 1
            }
        } catch let error as StoreError {
            readOnlyReason = Migrator.recoveryDescription(for: error, file: "the evidence cache index")
        } catch {
            readOnlyReason = Migrator.recoveryDescription(for: .corruptMetadata("The evidence cache index is unreadable."), file: "the evidence cache index")
        }
    }

    public var totalBytes: Int {
        entries.values.filter { !$0.expired }.reduce(0) { $0 + $1.size }
    }

    public var recoveryDescription: String? { readOnlyReason }

    public func put(id: String, bytes: Data, contentHash: String) throws {
        if let readOnlyReason { throw StoreError.readOnly(readOnlyReason) }
        guard bytes.count <= maxArtifactBytes, bytes.count <= maxTotalBytes else { throw StoreError.artifactTooLarge }
        guard ContentHash.sha256Hex(bytes) == contentHash else { throw StoreError.hashMismatch }
        if let existing = entries[id], existing.contentHash != contentHash { throw StoreError.hashConflict }

        do {
            try fileSystem.writeAtomically(bytes, to: fileURL(for: id))
        } catch {
            throw StoreError.mapping(error)
        }
        var updated = entries
        updated[id] = ArtifactEntry(id: id, contentHash: contentHash, size: bytes.count, lastAccessed: now(), tick: takeTick(), expired: false)
        var evicted: [ArtifactEntry] = []
        var total = updated.values.filter { !$0.expired }.reduce(0) { $0 + $1.size }
        let candidates = updated.values.filter { !$0.expired && $0.id != id }.sorted { $0.tick < $1.tick }
        for candidate in candidates where total > maxTotalBytes {
            total -= candidate.size
            updated[candidate.id]?.expired = true
            evicted.append(candidate)
        }
        entries = updated
        for entry in evicted { try? fileSystem.remove(fileURL(for: entry.id)) }
        dirty = true
        try persist()
    }

    public func get(id: String) -> ArtifactLookup {
        guard var entry = entries[id] else { return .missing }
        if entry.expired { return .expired(contentHash: entry.contentHash) }
        guard let data = try? fileSystem.read(fileURL(for: id)), ContentHash.sha256Hex(data) == entry.contentHash else {
            entry.expired = true
            entries[id] = entry
            dirty = true
            return .expired(contentHash: entry.contentHash)
        }
        entry.lastAccessed = now()
        entry.tick = takeTick()
        entries[id] = entry
        dirty = true
        return .found(data, contentHash: entry.contentHash)
    }

    public func status(id: String) -> ArtifactStatus {
        guard let entry = entries[id] else { return .missing }
        return entry.expired ? .expired : .available
    }

    public func flush() throws {
        guard dirty, readOnlyReason == nil else { return }
        try persist()
    }

    private func persist() throws {
        let index = ArtifactIndex(schemaVersion: ArtifactIndex.currentSchemaVersion, entries: entries.values.sorted { $0.tick < $1.tick })
        do {
            try fileSystem.writeAtomically(try Coding.encoder().encode(index), to: directory.appendingPathComponent("index.json"))
            dirty = false
        } catch {
            throw StoreError.mapping(error)
        }
    }

    private func takeTick() -> Int {
        defer { nextTick += 1 }
        return nextTick
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(String(ContentHash.sha256Hex(id).prefix(40)) + ".bin")
    }
}

public enum ArtifactStatus: Sendable, Equatable {
    case available
    case expired
    case missing
}
