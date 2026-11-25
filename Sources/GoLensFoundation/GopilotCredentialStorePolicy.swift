import Foundation

public enum GopilotCredentialStoreMode: Equatable, Sendable {
    case memory
    case localFile
    case keychain
}

public enum GopilotLegacyMigrationOutcome: Equatable, Sendable {
    case nothingToMigrate
    case migrated
    case failed(reason: String, copiedToTarget: Bool, hadSecret: Bool)
}

public enum GopilotCredentialStorePolicy {
    public static let defaultLegacyFileName = "gopilot-credentials.json"

    public static func resolveMode(environment: [String: String]) -> GopilotCredentialStoreMode {
        if environment["GOPILOT_DEV_SEED_CONNECTED"] == "1" {
            return .memory
        }
        if environment["GOPILOT_CREDENTIAL_STORE"] == "file" {
            return .localFile
        }
        return .keychain
    }

    public static func storageKey(profileID: String, slot: String = "api-key") -> String {
        "\(profileID):\(slot)"
    }

    public static func migrateLegacyFileIfPresent(
        fileURL: URL,
        storageKey: String,
        writeToTarget: (String) throws -> Void,
        readBackFromTarget: () throws -> String
    ) -> GopilotLegacyMigrationOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .nothingToMigrate
        }
        let map: [String: String]
        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                try removeLegacyFile(at: fileURL)
                return .nothingToMigrate
            }
            map = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            do {
                try removeLegacyFile(at: fileURL)
                return .nothingToMigrate
            } catch let removeError {
                return .failed(reason: removeError.localizedDescription, copiedToTarget: false, hadSecret: false)
            }
        }
        guard let secret = map[storageKey], !secret.isEmpty else {
            if map.values.allSatisfy(\.isEmpty) {
                do {
                    try removeLegacyFile(at: fileURL)
                } catch {
                    return .failed(reason: error.localizedDescription, copiedToTarget: false, hadSecret: false)
                }
            }
            return .nothingToMigrate
        }
        do {
            try writeToTarget(secret)
            let readBack = try readBackFromTarget()
            guard readBack == secret else {
                return .failed(
                    reason: "The key couldn’t be verified in the Keychain.",
                    copiedToTarget: false,
                    hadSecret: true
                )
            }
        } catch {
            return .failed(reason: "\(error)", copiedToTarget: false, hadSecret: true)
        }
        do {
            try removeStorageKeyAndEmptyFile(at: fileURL, storageKey: storageKey, existingMap: map)
            return .migrated
        } catch {
            return .failed(reason: error.localizedDescription, copiedToTarget: true, hadSecret: true)
        }
    }

    public static func cleanupLegacyCredentialFile(
        fileURL: URL,
        storageKey: String
    ) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                try removeLegacyFile(at: fileURL)
                return nil
            }
            if let map = try? JSONDecoder().decode([String: String].self, from: data) {
                try removeStorageKeyAndEmptyFile(at: fileURL, storageKey: storageKey, existingMap: map)
                return nil
            }
            try removeLegacyFile(at: fileURL)
            return nil
        } catch {
            return "Your API key was updated in the Keychain, but the legacy file “\(fileURL.lastPathComponent)” couldn’t be deleted (\(error.localizedDescription))."
        }
    }

    public static func migrationFailureMessage(
        for outcome: GopilotLegacyMigrationOutcome,
        fileName: String = defaultLegacyFileName
    ) -> String? {
        switch outcome {
        case .nothingToMigrate, .migrated:
            return nil
        case let .failed(reason, copiedToTarget, hadSecret):
            if copiedToTarget {
                return "Your API key was saved in the Keychain, but the legacy file “\(fileName)” couldn’t be deleted (\(reason))."
            }
            if hadSecret {
                return "Your API key couldn’t be moved to the Keychain (\(reason)). Enter the key again to save it in the Keychain."
            }
            return "The legacy credential file “\(fileName)” couldn’t be deleted (\(reason))."
        }
    }

    private static func removeStorageKeyAndEmptyFile(
        at fileURL: URL,
        storageKey: String,
        existingMap: [String: String]
    ) throws {
        var remaining = existingMap
        remaining.removeValue(forKey: storageKey)
        if remaining.values.allSatisfy(\.isEmpty) {
            try removeLegacyFile(at: fileURL)
            return
        }
        let encoded = try JSONEncoder().encode(remaining)
        try encoded.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func removeLegacyFile(at fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
