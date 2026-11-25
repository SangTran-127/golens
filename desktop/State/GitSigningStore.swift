import AppKit
import Darwin
import Foundation
import SwiftUI

struct SSHSigningKey: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let publicKeyPath: String
    let keyType: String
    let fingerprint: String
    let comment: String
    let publicKey: String
    let isSecurityKey: Bool
    let hasPassphrase: Bool
    let verifyRequired: Bool

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var shortKeyKindLabel: String {
        switch keyType {
        case "sk-ssh-ed25519@openssh.com":
            return "Security Key · Ed25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com":
            return "Security Key · ECDSA-SK"
        case "ssh-ed25519":
            return "SSH · Ed25519"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return "SSH · ECDSA"
        case "ssh-rsa":
            return "SSH · RSA"
        default:
            return isSecurityKey ? "Security Key" : "SSH Key"
        }
    }

    var displayTitle: String {
        if !comment.isEmpty {
            return "\(fileName) (\(shortKeyKindLabel) — \(comment))"
        }
        return "\(fileName) (\(shortKeyKindLabel))"
    }

    var fingerprintSubtitle: String {
        if hasPassphrase {
            return "\(fingerprint) · Protected by passphrase (choose an unencrypted or -sk key)"
        }
        if isSecurityKey {
            return "\(fingerprint) · Hardware Security Key (touch required on commit)"
        }
        return fingerprint
    }
}

private struct SSHSigningDiscoveryPayload: Decodable {
    let keys: [SSHSigningKey]
    let hasHomebrewOpenSSH: Bool
}

struct CommitSignatureInfo: Codable, Equatable, Sendable {
    let status: String
    let fingerprint: String?
    let signerEmail: String?

    var isVerified: Bool { status == "G" }
    var isSignedOtherKey: Bool { status == "U" }
    var isInvalid: Bool { status == "B" }
}

@Observable
@MainActor
final class GitSigningStore {
    static let shared = GitSigningStore()

    struct TokenPermissionIssue: Equatable {
        let accountID: UUID
        let host: String
        let message: String
        let tokenCreationURL: URL?
    }

    private static let enabledKey = "GoLensGitCommitSigningEnabled"
    private static let selectedKeyPathKey = "GoLensGitSigningKeyPath"
    private static let customKeyPathsKey = "GoLensGitSigningCustomKeyPaths"
    private static let keyBookmarksKey = "GoLensGitSigningKeyBookmarks"
    private static let uploadedFingerprintsKey = "GoLensGitUploadedSigningKeyFingerprints"

    var isSigningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSigningEnabled, forKey: Self.enabledKey)
            if isSigningEnabled {
                refreshAvailableKeys()
            } else {
                signingFailureMessage = nil
                isWaitingForSecurityKeyTouch = false
            }
        }
    }

    var selectedKeyPath: String {
        didSet {
            UserDefaults.standard.set(selectedKeyPath, forKey: Self.selectedKeyPathKey)
            tokenPermissionIssue = nil
            uploadStatusMessage = nil
            syncAllowedSignersWithCurrentAuthor()
        }
    }

    var availableKeys: [SSHSigningKey] = []
    var hasHomebrewOpenSSH: Bool = true
    var isWaitingForSecurityKeyTouch: Bool = false
    var remoteTouchHost: String? = nil
    var signingFailureMessage: String? = nil

    var uploadingAccountID: UUID? = nil
    var uploadStatusMessage: String? = nil
    var uploadErrorMessage: String? = nil
    var tokenPermissionIssue: TokenPermissionIssue? = nil
    private var uploadedFingerprintsByAccount: [String: [String]] = [:]
    private var activeSecurityScopedURLs: [String: URL] = [:]

    var selectedKey: SSHSigningKey? {
        availableKeys.first(where: { $0.path == selectedKeyPath }) ?? availableKeys.first
    }

    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        let home = NSHomeDirectory()
        if let range = home.range(of: "/Library/Containers/") {
            return String(home[..<range.lowerBound])
        }
        return home
    }

    var allowedSignersPath: String {
        let base = URL(fileURLWithPath: Self.realHomeDirectory)
            .appendingPathComponent("Library/Application Support/GoLens/git", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("allowed_signers").path
    }

    private init() {
        self.isSigningEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.selectedKeyPath = UserDefaults.standard.string(forKey: Self.selectedKeyPathKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.uploadedFingerprintsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.uploadedFingerprintsByAccount = decoded
        }
        restoreSecurityScopedBookmarks()
        refreshAvailableKeys()
    }

    func refreshAvailableKeys() {
        let customPaths = UserDefaults.standard.stringArray(forKey: Self.customKeyPathsKey) ?? []
        let extraJSON = (try? JSONEncoder().encode(customPaths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let rawJSON: String = extraJSON.withCString { cExtra in
            guard let ptr = DiscoverSSHSigningKeysJSON(cExtra) else { return "" }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        if let data = rawJSON.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SSHSigningDiscoveryPayload.self, from: data) {
            self.availableKeys = payload.keys
            self.hasHomebrewOpenSSH = payload.hasHomebrewOpenSSH
        }
        if selectedKeyPath.isEmpty || !availableKeys.contains(where: { $0.path == selectedKeyPath }) {
            if let preferred = availableKeys.first(where: { !$0.hasPassphrase }) ?? availableKeys.first {
                selectedKeyPath = preferred.path
            }
        }
        syncAllowedSignersWithCurrentAuthor()
    }

    func syncAllowedSigners(email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pubKey = selectedKey?.publicKey ?? ""
        let path = allowedSignersPath
        path.withCString { cPath in
            trimmedEmail.withCString { cEmail in
                pubKey.withCString { cPub in
                    if let ptr = WriteGitAllowedSigners(cPath, cEmail, cPub) {
                        FreeGoCString(ptr)
                    }
                }
            }
        }
    }

    func syncAllowedSignersWithCurrentAuthor() {
        Task { @MainActor in
            let identity = await WorkspaceState.shared.gitAuthorIdentity()
            if !identity.email.isEmpty {
                syncAllowedSigners(email: identity.email)
            }
        }
    }

    func verifyCommitSignature(rawCommit: Data) -> CommitSignatureInfo {
        guard !rawCommit.isEmpty else {
            return CommitSignatureInfo(status: "N", fingerprint: nil, signerEmail: nil)
        }
        let path = allowedSignersPath
        let jsonStr: String = rawCommit.withUnsafeBytes { buf in
            guard let base = buf.bindMemory(to: CChar.self).baseAddress else { return "" }
            return path.withCString { cPath in
                guard let ptr = VerifyGitCommitSignatureJSON(base, Int32(rawCommit.count), cPath) else { return "" }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
        }
        guard let data = jsonStr.data(using: .utf8),
              let info = try? JSONDecoder().decode(CommitSignatureInfo.self, from: data) else {
            return CommitSignatureInfo(status: "N", fingerprint: nil, signerEmail: nil)
        }
        return info
    }

    func chooseKeyFileWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Signing Key"
        panel.message = "Select your SSH private key handle (for example, id_ed25519_sk) or its .pub file."
        panel.prompt = "Choose Key"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        let sshDir = URL(fileURLWithPath: Self.realHomeDirectory).appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDir.path) {
            panel.directoryURL = sshDir
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosenPath = url.path
        let privPath = chosenPath.hasSuffix(".pub") ? String(chosenPath.dropLast(4)) : chosenPath
        let pubPath = privPath + ".pub"

        saveSecurityScopedBookmark(for: url)
        let privURL = URL(fileURLWithPath: privPath)
        let pubURL = URL(fileURLWithPath: pubPath)
        saveSecurityScopedBookmark(for: privURL)
        saveSecurityScopedBookmark(for: pubURL)

        var custom = UserDefaults.standard.stringArray(forKey: Self.customKeyPathsKey) ?? []
        if !custom.contains(privPath) {
            custom.append(privPath)
            UserDefaults.standard.set(custom, forKey: Self.customKeyPathsKey)
        }
        refreshAvailableKeys()
        if availableKeys.contains(where: { $0.path == privPath }) {
            selectedKeyPath = privPath
        }
    }

    private func saveSecurityScopedBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var bookmarks = (UserDefaults.standard.dictionary(forKey: Self.keyBookmarksKey) as? [String: Data]) ?? [:]
        bookmarks[url.path] = data
        UserDefaults.standard.set(bookmarks, forKey: Self.keyBookmarksKey)
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs[url.path] = url
        }
    }

    private func restoreSecurityScopedBookmarks() {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: Self.keyBookmarksKey) as? [String: Data] else {
            return
        }
        for (path, data) in bookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs[path] = url
            }
        }
    }

    func isKeyUploaded(for account: GitAccount) -> Bool {
        guard let key = selectedKey else { return false }
        let list = uploadedFingerprintsByAccount[account.id.uuidString] ?? []
        return list.contains(key.fingerprint)
    }

    private func markKeyUploaded(_ fingerprint: String, for account: GitAccount) {
        var list = uploadedFingerprintsByAccount[account.id.uuidString] ?? []
        if !list.contains(fingerprint) {
            list.append(fingerprint)
            uploadedFingerprintsByAccount[account.id.uuidString] = list
            if let data = try? JSONEncoder().encode(uploadedFingerprintsByAccount) {
                UserDefaults.standard.set(data, forKey: Self.uploadedFingerprintsKey)
            }
        }
    }

    func uploadSigningKey(to account: GitAccount) async {
        guard let key = selectedKey else { return }
        guard let token = GitAccountStore.shared.readToken(for: account.id), !token.isEmpty else {
            tokenPermissionIssue = TokenPermissionIssue(
                accountID: account.id,
                host: account.host,
                message: "No Personal Access Token found for @\(account.username) on \(account.host).",
                tokenCreationURL: GitAccountStore.shared.tokenCreationURL(for: account.providerKind, serverURL: account.serverURL)
            )
            return
        }

        uploadingAccountID = account.id
        tokenPermissionIssue = nil
        uploadErrorMessage = nil
        uploadStatusMessage = nil
        defer {
            if uploadingAccountID == account.id {
                uploadingAccountID = nil
            }
        }

        let hostName = Host.current().localizedName ?? "Mac"
        let keyTitle = "GoLens (\(hostName) — \(key.fileName))"

        switch account.providerKind {
        case .githubCloud, .githubEnterprise:
            await uploadToGitHub(account: account, token: token, key: key, title: keyTitle)
        case .gitlabCloud, .gitlabSelfHosted:
            await uploadToGitLab(account: account, token: token, key: key, title: keyTitle)
        }
    }

    private func uploadToGitHub(account: GitAccount, token: String, key: SSHSigningKey, title: String) async {
        let urlString: String
        switch account.providerKind {
        case .githubCloud:
            urlString = "https://api.github.com/user/ssh_signing_keys"
        default:
            urlString = "\(account.scheme)://\(account.host)/api/v3/user/ssh_signing_keys"
        }
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("GoLens/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "title": title,
            "key": key.publicKey
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let bodyObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let apiMessage = (bodyObj["message"] as? String) ?? ""

            if http.statusCode == 201 {
                markKeyUploaded(key.fingerprint, for: account)
                uploadStatusMessage = "Added signing key to @\(account.username) on \(account.host)."
                return
            }

            if http.statusCode == 422 {
                let rawBody = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                if rawBody.contains("already in use") {
                    markKeyUploaded(key.fingerprint, for: account)
                    uploadStatusMessage = "This signing key is already registered on @\(account.username)."
                    return
                }
            }

            if http.statusCode == 403 || http.statusCode == 404 {
                let createURL = GitAccountStore.shared.tokenCreationURL(for: account.providerKind, serverURL: account.serverURL)
                if apiMessage.localizedCaseInsensitiveContains("Resource not accessible by personal access token") {
                    tokenPermissionIssue = TokenPermissionIssue(
                        accountID: account.id,
                        host: account.host,
                        message: "Your Fine-Grained Token for @\(account.username) needs Account permissions ▸ SSH signing keys: Read and write, or create a Classic token with write:ssh_signing_key.",
                        tokenCreationURL: createURL
                    )
                } else {
                    tokenPermissionIssue = TokenPermissionIssue(
                        accountID: account.id,
                        host: account.host,
                        message: "The token for @\(account.username) on \(account.host) is missing the write:ssh_signing_key scope needed to register SSH signing keys.",
                        tokenCreationURL: createURL
                    )
                }
                return
            }

            uploadErrorMessage = apiMessage.isEmpty
                ? "\(account.host) returned HTTP \(http.statusCode) when uploading the signing key."
                : apiMessage
        } catch {
            uploadErrorMessage = error.localizedDescription
        }
    }

    private func uploadToGitLab(account: GitAccount, token: String, key: SSHSigningKey, title: String) async {
        guard let url = URL(string: "\(account.scheme)://\(account.host)/api/v4/user/keys") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("GoLens/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: String] = [
            "title": title,
            "key": key.publicKey,
            "usage_type": "signing"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let rawBody = String(data: data, encoding: .utf8) ?? ""

            if http.statusCode == 201 {
                markKeyUploaded(key.fingerprint, for: account)
                uploadStatusMessage = "Added signing key to @\(account.username) on \(account.host)."
                return
            }

            if http.statusCode == 400 && rawBody.localizedCaseInsensitiveContains("has already been taken") {
                markKeyUploaded(key.fingerprint, for: account)
                uploadStatusMessage = "This signing key is already registered on @\(account.username)."
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                tokenPermissionIssue = TokenPermissionIssue(
                    accountID: account.id,
                    host: account.host,
                    message: "The token for @\(account.username) on \(account.host) needs the api scope to register SSH signing keys.",
                    tokenCreationURL: GitAccountStore.shared.tokenCreationURL(for: account.providerKind, serverURL: account.serverURL)
                )
                return
            }

            uploadErrorMessage = "\(account.host) returned HTTP \(http.statusCode) when uploading the signing key."
        } catch {
            uploadErrorMessage = error.localizedDescription
        }
    }
}
