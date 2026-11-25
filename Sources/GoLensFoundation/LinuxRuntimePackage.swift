import CryptoKit
import Foundation

public struct LinuxRuntimeManifest: Codable, Equatable, Sendable {
    public let version: String
    public let arch: String
    public let archive: String
    public let archiveSize: Int64
    public let installedSize: Int64
    public let sha256: String
    public let minimumAppVersion: String
    public let agentProtocol: Int
    public let components: [String: String]

    public init(version: String, arch: String, archive: String, archiveSize: Int64, installedSize: Int64, sha256: String, minimumAppVersion: String, agentProtocol: Int, components: [String: String]) {
        self.version = version
        self.arch = arch
        self.archive = archive
        self.archiveSize = archiveSize
        self.installedSize = installedSize
        self.sha256 = sha256
        self.minimumAppVersion = minimumAppVersion
        self.agentProtocol = agentProtocol
        self.components = components
    }

    public static func decode(_ data: Data) -> LinuxRuntimeManifest? {
        try? JSONDecoder().decode(LinuxRuntimeManifest.self, from: data)
    }
}

public enum LinuxRuntimeVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = numbers(lhs), b = numbers(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}

public enum LinuxRuntimeVerification {
    public static func isSignatureValid(manifest: Data, signatureBase64: String, publicKeysBase64: [String]) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return publicKeysBase64.contains { encoded in
            guard let raw = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(signature, for: manifest)
        }
    }

    public static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum LinuxRuntimeAvailability: Equatable, Sendable {
    case notInstalled(LinuxRuntimeManifest)
    case upToDate
    case updateAvailable(LinuxRuntimeManifest)
    case requiresNewerApp(LinuxRuntimeManifest)
    case installedNeedsUpdate

    public static func resolve(installed: LinuxRuntimeManifest?, available: LinuxRuntimeManifest, appVersion: String, agentProtocol: Int) -> LinuxRuntimeAvailability {
        let installedWorks = installed.map { $0.agentProtocol == agentProtocol } ?? false
        let availableWorks = available.agentProtocol == agentProtocol
            && LinuxRuntimeVersion.compare(appVersion, available.minimumAppVersion) != .orderedAscending
        guard let installed else {
            return availableWorks ? .notInstalled(available) : .requiresNewerApp(available)
        }
        if LinuxRuntimeVersion.compare(available.version, installed.version) == .orderedDescending {
            if availableWorks { return .updateAvailable(available) }
            return installedWorks ? .upToDate : .requiresNewerApp(available)
        }
        return installedWorks ? .upToDate : .installedNeedsUpdate
    }
}
