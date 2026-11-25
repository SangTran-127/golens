import Foundation

public enum StoreFile: String, Sendable, Codable {
    case index
    case memory
    case artifactIndex
}

public struct SchemaMigration: Sendable {
    public let file: StoreFile
    public let from: Int
    public let to: Int
    public let transform: @Sendable (inout [String: Any]) throws -> Void

    public init(file: StoreFile, from: Int, to: Int, transform: @escaping @Sendable (inout [String: Any]) throws -> Void) {
        self.file = file
        self.from = from
        self.to = to
        self.transform = transform
    }
}

enum Migrator {
    static let schemaVersionKey = "schemaVersion"

    static func load(url: URL, file: StoreFile, currentVersion: Int, migrations: [SchemaMigration], fileSystem: FileSystem) throws -> Data? {
        guard fileSystem.exists(url) else { return nil }
        let data: Data
        do { data = try fileSystem.read(url) } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StoreError.corruptMetadata("\(url.lastPathComponent) is not a valid JSON object.")
        }
        let version = (object[schemaVersionKey] as? Int) ?? 0
        if version == currentVersion { return data }
        if version > currentVersion { throw StoreError.unsupportedFutureVersion(version) }

        let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).v\(version).bak")
        do {
            if !fileSystem.exists(backup) { try fileSystem.copy(from: url, to: backup) }
        } catch {
            throw StoreError.migrationFailed(backupPath: nil, reason: "Could not create a backup: \(error.localizedDescription)")
        }

        var step = version
        let chain = migrations.filter { $0.file == file }
        do {
            while step < currentVersion {
                guard let migration = chain.first(where: { $0.from == step }) else {
                    throw StoreError.migrationFailed(backupPath: backup.path, reason: "No migration from schema version \(step).")
                }
                try migration.transform(&object)
                object[schemaVersionKey] = migration.to
                step = migration.to
            }
            let migrated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try fileSystem.writeAtomically(migrated, to: url)
            return migrated
        } catch let error as StoreError {
            if case .migrationFailed = error { throw error }
            throw StoreError.migrationFailed(backupPath: backup.path, reason: String(describing: error))
        } catch {
            throw StoreError.migrationFailed(backupPath: backup.path, reason: error.localizedDescription)
        }
    }

    static func recoveryDescription(for error: StoreError, file: String) -> String {
        switch error {
        case .migrationFailed(let backup, let reason):
            let location = backup.map { " A backup of the original is at \($0)." } ?? ""
            return "Gopilot could not upgrade \(file): \(reason)\(location) History opens read-only so nothing is lost."
        case .unsupportedFutureVersion(let version):
            return "\(file) was written by a newer version of Gopilot (schema \(version)). It opens read-only so nothing is overwritten."
        case .corruptMetadata(let reason):
            return "\(reason) History is rebuilt from the journals and opens read-only."
        default:
            return "Gopilot could not read \(file). It opens read-only so nothing is overwritten."
        }
    }
}
