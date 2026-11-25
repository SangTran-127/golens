import Foundation
import GopilotProvider

enum DataSourceStoreError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): reason
        }
    }
}

final class DataSourceStore: @unchecked Sendable {
    static let shared = DataSourceStore()

    static let keychainServicePrefix = "app.golens.database"
    static let secretSlot = "password"
    static let relativePath = ".golens/data-sources.json"
    static let consolesFolder = ".golens/consoles"

    let usesKeychain: Bool
    private let secrets: any CredentialStore

    private init() {
        if ProcessInfo.processInfo.environment["GOPILOT_CREDENTIAL_STORE"] == "file" {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let url = base.appendingPathComponent("GoLens", isDirectory: true).appendingPathComponent("database-credentials.json")
            secrets = LocalFileCredentialStore(fileURL: url)
            usesKeychain = false
        } else {
            secrets = KeychainCredentialStore(servicePrefix: Self.keychainServicePrefix)
            usesKeychain = true
        }
    }

    static func filePath(root: String) -> String {
        (root as NSString).appendingPathComponent(relativePath)
    }

    func load(root: String) throws -> DBDataSourcesFile? {
        let path = Self.filePath(root: root)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            return try JSONDecoder().decode(DBDataSourcesFile.self, from: data)
        } catch {
            throw DataSourceStoreError.unreadable("The data source file is not valid JSON.")
        }
    }

    func save(_ file: DBDataSourcesFile, root: String) throws {
        let path = Self.filePath(root: root)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func readSecret(dataSourceID: String) throws -> String? {
        do {
            return try secrets.read(reference(dataSourceID))
        } catch CredentialError.notFound {
            return nil
        }
    }

    func writeSecret(_ secret: String, dataSourceID: String) throws {
        try secrets.write(secret, for: reference(dataSourceID))
    }

    func deleteSecret(dataSourceID: String) {
        try? secrets.delete(reference(dataSourceID))
    }

    private func reference(_ dataSourceID: String) -> CredentialReference {
        CredentialReference(profileID: dataSourceID, slot: Self.secretSlot)
    }

    func createConsoleFile(root: String, dataSourceName: String) throws -> String {
        let folder = (root as NSString).appendingPathComponent(Self.consolesFolder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        excludeConsolesFromGit(root: root)
        let base = Self.consoleFileBase(dataSourceName)
        var path = (folder as NSString).appendingPathComponent(base + ".sql")
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = (folder as NSString).appendingPathComponent("\(base)-\(n).sql")
            n += 1
        }
        try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        return path
    }

    static func consoleFileBase(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "console" : trimmed
    }

    private func excludeConsolesFromGit(root: String) {
        let gitDir = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir, isDirectory: &isDir), isDir.boolValue else { return }
        let info = (gitDir as NSString).appendingPathComponent("info")
        let exclude = (info as NSString).appendingPathComponent("exclude")
        let entry = Self.consolesFolder + "/"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        let lines = current.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(entry), !lines.contains("/" + entry) else { return }
        try? FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? (current + separator + entry + "\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }
}
