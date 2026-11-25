import Foundation
import Testing
import GopilotRuntime
@testable import GopilotProvider

private final class CountingStore: CredentialStore, @unchecked Sendable {
    let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private var readCount = 0
    var failWrites = false

    var reads: Int { lock.withLock { readCount } }

    func read(_ reference: CredentialReference) throws -> String {
        lock.withLock { readCount += 1 }
        return try inner.read(reference)
    }

    func write(_ secret: String, for reference: CredentialReference) throws {
        if failWrites { throw CredentialError.denied }
        try inner.write(secret, for: reference)
    }

    func delete(_ reference: CredentialReference) throws {
        try inner.delete(reference)
    }
}

private func temporaryFileStore() throws -> LocalFileCredentialStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gopilot-cred-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return LocalFileCredentialStore(fileURL: directory.appendingPathComponent("gopilot-credentials.json"))
}

@Suite("Credential storage")
struct CredentialMigrationTests {
    let reference = CredentialReference(profileID: "default")

    @Test func fileKeyMovesToTheTargetStoreAndTheFileIsDeleted() throws {
        let legacy = try temporaryFileStore()
        try legacy.write("sk-moved", for: reference)
        let target = CountingStore()
        #expect(CredentialMigration.moveFileCredential(reference, from: legacy, to: target) == .migrated)
        #expect(try target.read(reference) == "sk-moved")
        #expect(FileManager.default.fileExists(atPath: legacy.fileURL.path) == false)
    }

    @Test func fileKeyReplacesAStaleTargetKey() throws {
        let legacy = try temporaryFileStore()
        try legacy.write("sk-current", for: reference)
        let target = InMemoryCredentialStore([reference: "sk-stale"])
        #expect(CredentialMigration.moveFileCredential(reference, from: legacy, to: target) == .migrated)
        #expect(try target.read(reference) == "sk-current")
        #expect(FileManager.default.fileExists(atPath: legacy.fileURL.path) == false)
    }

    @Test func failedMoveKeepsTheFileCopy() throws {
        let legacy = try temporaryFileStore()
        try legacy.write("sk-kept", for: reference)
        let target = CountingStore()
        target.failWrites = true
        guard case .failed = CredentialMigration.moveFileCredential(reference, from: legacy, to: target) else {
            Issue.record("expected a failed migration")
            return
        }
        #expect(try legacy.read(reference) == "sk-kept")
    }

    @Test func noFileMeansNothingToMigrate() {
        let legacy = LocalFileCredentialStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json"))
        #expect(CredentialMigration.moveFileCredential(reference, from: legacy, to: CountingStore()) == .nothingToMigrate)
    }

    @Test func cachingStoreReadsTheBackingStoreOnce() throws {
        let base = CountingStore()
        try base.write("sk-cached", for: reference)
        let cached = CachingCredentialStore(base)
        #expect(try cached.read(reference) == "sk-cached")
        #expect(try cached.read(reference) == "sk-cached")
        #expect(base.reads == 1)
        try cached.delete(reference)
        #expect(throws: CredentialError.notFound) { try cached.read(reference) }
        try cached.write("sk-new", for: reference)
        #expect(try cached.read(reference) == "sk-new")
        #expect(base.reads == 1)
    }
}
