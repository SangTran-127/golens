import Foundation
import Security

public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case notFound
    case locked
    case denied
    case unexpected(status: Int32)

    public var description: String {
        switch self {
        case .notFound: return "No credential is stored for this provider."
        case .locked: return "The keychain is locked."
        case .denied: return "Access to the keychain was denied."
        case .unexpected(let status): return "The keychain returned an unexpected error (\(status))."
        }
    }
}

public protocol CredentialStore: Sendable {
    func read(_ reference: CredentialReference) throws -> String
    func write(_ secret: String, for reference: CredentialReference) throws
    func delete(_ reference: CredentialReference) throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [CredentialReference: String] = [:]

    public init(_ initial: [CredentialReference: String] = [:]) {
        secrets = initial
    }

    public func read(_ reference: CredentialReference) throws -> String {
        guard let secret = lock.withLock({ secrets[reference] }) else {
            throw CredentialError.notFound
        }
        return secret
    }

    public func write(_ secret: String, for reference: CredentialReference) throws {
        lock.withLock { secrets[reference] = secret }
    }

    public func delete(_ reference: CredentialReference) throws {
        lock.withLock { _ = secrets.removeValue(forKey: reference) }
    }
}

public final class LocalFileCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base
                .appendingPathComponent("GoLens", isDirectory: true)
                .appendingPathComponent("gopilot-credentials.json")
        }
    }

    public func read(_ reference: CredentialReference) throws -> String {
        try lock.withLock {
            let map = loadMap()
            guard let secret = map[storageKey(for: reference)], !secret.isEmpty else {
                throw CredentialError.notFound
            }
            return secret
        }
    }

    public func write(_ secret: String, for reference: CredentialReference) throws {
        try lock.withLock {
            var map = loadMap()
            map[storageKey(for: reference)] = secret
            try saveMap(map)
        }
    }

    public func delete(_ reference: CredentialReference) throws {
        try lock.withLock {
            var map = loadMap()
            map.removeValue(forKey: storageKey(for: reference))
            try saveMap(map)
        }
    }

    public func removeFileIfEmpty() {
        lock.withLock {
            guard loadMap().isEmpty else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func storageKey(for reference: CredentialReference) -> String {
        "\(reference.profileID):\(reference.slot)"
    }

    private func loadMap() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMap(_ map: [String: String]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public final class CachingCredentialStore: CredentialStore, @unchecked Sendable {
    private let base: any CredentialStore
    private let lock = NSLock()
    private var cache: [CredentialReference: String] = [:]
    private var known: Set<CredentialReference> = []

    public init(_ base: any CredentialStore) {
        self.base = base
    }

    public func read(_ reference: CredentialReference) throws -> String {
        if let cached = lock.withLock({ known.contains(reference) ? cache[reference] : nil }) {
            return cached
        }
        if lock.withLock({ known.contains(reference) }) {
            throw CredentialError.notFound
        }
        do {
            let secret = try base.read(reference)
            lock.withLock {
                cache[reference] = secret
                known.insert(reference)
            }
            return secret
        } catch CredentialError.notFound {
            lock.withLock {
                cache[reference] = nil
                known.insert(reference)
            }
            throw CredentialError.notFound
        }
    }

    public func write(_ secret: String, for reference: CredentialReference) throws {
        try base.write(secret, for: reference)
        lock.withLock {
            cache[reference] = secret
            known.insert(reference)
        }
    }

    public func delete(_ reference: CredentialReference) throws {
        try base.delete(reference)
        lock.withLock {
            cache[reference] = nil
            known.insert(reference)
        }
    }

    public func invalidate() {
        lock.withLock {
            cache.removeAll()
            known.removeAll()
        }
    }
}

public enum CredentialMigrationOutcome: Sendable, Equatable {
    case nothingToMigrate
    case migrated
    case failed(String)
}

public enum CredentialMigration {
    public static func moveFileCredential(_ reference: CredentialReference, from legacy: LocalFileCredentialStore, to target: any CredentialStore) -> CredentialMigrationOutcome {
        guard FileManager.default.fileExists(atPath: legacy.fileURL.path) else { return .nothingToMigrate }
        guard let secret = try? legacy.read(reference) else {
            legacy.removeFileIfEmpty()
            return .nothingToMigrate
        }
        do {
            try target.write(secret, for: reference)
            guard (try? target.read(reference)) == secret else {
                return .failed("The key could not be read back from the Keychain.")
            }
            try legacy.delete(reference)
            legacy.removeFileIfEmpty()
            return .migrated
        } catch {
            return .failed("\(error)")
        }
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public let servicePrefix: String

    public init(servicePrefix: String = "app.golens.gopilot.provider") {
        self.servicePrefix = servicePrefix
    }

    public func service(for reference: CredentialReference) -> String {
        "\(servicePrefix).\(reference.profileID)"
    }

    public func read(_ reference: CredentialReference) throws -> String {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw Self.mapStatus(status)
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw CredentialError.unexpected(status: errSecDecode)
        }
        return secret
    }

    public func write(_ secret: String, for reference: CredentialReference) throws {
        let data = Data(secret.utf8)
        var addQuery = baseQuery(for: reference)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw Self.mapStatus(addStatus)
        }
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var updateQuery = baseQuery(for: reference)
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        _ = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard retryStatus == errSecSuccess else {
            throw Self.mapStatus(updateStatus)
        }
    }

    public func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status)
        }
    }

    public static func mapStatus(_ status: OSStatus) -> CredentialError {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem, errSecInteractionRequired:
            return .denied
        default:
            return .unexpected(status: status)
        }
    }

    private func baseQuery(for reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: reference),
            kSecAttrAccount as String: reference.slot
        ]
    }
}

public struct Redactor: Sendable {
    public static let placeholder = "[REDACTED]"

    private let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: Self.placeholder)
        }
        for pattern in Self.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: Self.template)
        }
        return result
    }

    private static let template = "$1" + placeholder

    private static let patterns: [NSRegularExpression] = [
        #"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]+"#,
        #"(?i)((?:authorization|x-api-key|api-key|api_key|apikey)["']?\s*[:=]\s*["']?)[^\r\n"',;]+"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}
