import AppKit
import Foundation
import Security
import SwiftUI

enum GitAccountProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case githubCloud
    case githubEnterprise
    case gitlabCloud
    case gitlabSelfHosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .githubCloud: "GitHub.com"
        case .githubEnterprise: "GitHub Enterprise"
        case .gitlabCloud: "GitLab.com"
        case .gitlabSelfHosted: "GitLab Self-Hosted"
        }
    }

    var shortServiceName: String {
        switch self {
        case .githubCloud, .githubEnterprise: "GitHub"
        case .gitlabCloud, .gitlabSelfHosted: "GitLab"
        }
    }

    var providerFamily: String {
        switch self {
        case .githubCloud, .githubEnterprise: "github"
        case .gitlabCloud, .gitlabSelfHosted: "gitlab"
        }
    }

    var iconResourceName: String {
        switch self {
        case .githubCloud, .githubEnterprise: "provider-github"
        case .gitlabCloud, .gitlabSelfHosted: "provider-gitlab"
        }
    }

    var usesCustomServerURL: Bool {
        switch self {
        case .githubCloud, .gitlabCloud: false
        case .githubEnterprise, .gitlabSelfHosted: true
        }
    }

    var defaultHost: String {
        switch self {
        case .githubCloud: "github.com"
        case .gitlabCloud: "gitlab.com"
        case .githubEnterprise, .gitlabSelfHosted: ""
        }
    }

    var defaultServerURL: String {
        switch self {
        case .githubCloud: "https://github.com"
        case .gitlabCloud: "https://gitlab.com"
        case .githubEnterprise, .gitlabSelfHosted: ""
        }
    }

    var serverURLPlaceholder: String {
        switch self {
        case .githubCloud: "https://github.com"
        case .githubEnterprise: "https://github.example.com"
        case .gitlabCloud: "https://gitlab.com"
        case .gitlabSelfHosted: "https://gitlab.example.com"
        }
    }

    var serverPlaceholder: String { serverURLPlaceholder }

    var tokenPlaceholder: String {
        switch self {
        case .githubCloud, .githubEnterprise: "ghp_…"
        case .gitlabCloud, .gitlabSelfHosted: "glpat-…"
        }
    }

    var scopesHelpText: String {
        switch self {
        case .githubCloud, .githubEnterprise:
            "Requires repo and read:org scopes."
        case .gitlabCloud, .gitlabSelfHosted:
            "Requires api, read_user, and write_repository scopes."
        }
    }

    var requiredScopesSummary: String { scopesHelpText }

    var createTokenButtonTitle: String {
        switch self {
        case .githubCloud, .githubEnterprise:
            "Create a Token on GitHub…"
        case .gitlabCloud, .gitlabSelfHosted:
            "Create a Token on GitLab…"
        }
    }

    static func infer(fromHost rawHost: String) -> GitAccountProviderKind {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "github.com" || host.isEmpty { return .githubCloud }
        if host == "gitlab.com" { return .gitlabCloud }
        if host.contains("gitlab") { return .gitlabSelfHosted }
        return .githubEnterprise
    }
}

struct GitAccount: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var providerKind: GitAccountProviderKind
    var scheme: String
    var host: String
    var username: String
    var displayName: String
    var email: String?
    var needsTokenUpdate: Bool = false

    var formattedIdentity: String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.caseInsensitiveCompare(username) == .orderedSame {
            return "@\(username)"
        }
        return "\(trimmedName) (@\(username))"
    }

    var webProfileURL: URL? {
        URL(string: "\(scheme)://\(host)/\(username)")
    }

    var serverURL: String {
        "\(scheme)://\(host)"
    }

    var statusSummary: String {
        needsTokenUpdate ? "Token expired or revoked" : "Connected"
    }
}

struct GitRemoteRepository: Identifiable, Equatable, Sendable {
    let id: String
    let accountID: UUID
    let providerKind: GitAccountProviderKind
    let host: String
    let fullName: String
    let description: String
    let cloneURL: String
    let sshURL: String
    let isPrivate: Bool
}

struct GitAuthRecoveryContext: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let existingAccount: GitAccount?

    var alertTitle: String {
        if let existingAccount {
            return "Authentication Failed for @\(existingAccount.username) on \(host)"
        }
        return "Authentication Required for \(host)"
    }

    var alertMessage: String {
        if let existingAccount {
            return "The Personal Access Token for @\(existingAccount.username) on \(host) was rejected or has expired. Update the token to continue."
        }
        return "Sign in with a Personal Access Token for \(host) to access this repository."
    }

    var primaryActionTitle: String {
        existingAccount != nil ? "Update Token…" : "Add Account…"
    }

    static func == (lhs: GitAuthRecoveryContext, rhs: GitAuthRecoveryContext) -> Bool {
        lhs.id == rhs.id
    }
}

struct GitAccountServiceIconView: View {
    let providerKind: GitAccountProviderKind
    var size: CGFloat = 18

    var body: some View {
        if let image = Self.loadBundledPDF(named: providerKind.iconResourceName) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "network")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private static func loadBundledPDF(named name: String) -> NSImage? {
        let url = AppResourceBundle.url(forResource: name, withExtension: "pdf")
            ?? AppResourceBundle.bundle.url(forResource: name, withExtension: "pdf", subdirectory: "ProviderIcons")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }
}

@Observable
@MainActor
final class GitAccountStore {
    static let shared = GitAccountStore()

    private static let accountsDefaultsKey = "GoLensGitAccounts"
    private static let keychainService = "app.golens.git.account"

    var accounts: [GitAccount] = []
    var isVerifying = false
    var verifyingAccountIDs: Set<UUID> = []
    var repositoriesByAccount: [UUID: [GitRemoteRepository]] = [:]
    var isLoadingRepositories = false

    private let usesFileCredentialStore: Bool = {
        ProcessInfo.processInfo.environment["GOPILOT_CREDENTIAL_STORE"] == "file"
    }()

    var usesKeychainStore: Bool {
        !usesFileCredentialStore
    }

    private init() {
        loadAccounts()
        migrateFileTokensToKeychain()
        syncCredentialsToCore()
    }

    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsDefaultsKey),
           let decoded = try? JSONDecoder().decode([GitAccount].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsDefaultsKey)
        }
        syncCredentialsToCore()
    }

    func account(forHost rawHost: String) -> GitAccount? {
        let normalized = Self.normalizeHost(rawHost).host
        guard !normalized.isEmpty else { return nil }
        return accounts.first { $0.host.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    func hasStoredToken(for accountID: UUID) -> Bool {
        guard let token = readToken(for: accountID) else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func tokenCreationURL(for kind: GitAccountProviderKind, serverURL: String) -> URL? {
        tokenCreationURL(for: kind, customServerURL: serverURL)
    }

    func tokenCreationURL(for kind: GitAccountProviderKind, customServerURL: String) -> URL? {
        let parsed = Self.resolveEndpoint(kind: kind, customServerURL: customServerURL)
        guard !parsed.host.isEmpty else { return nil }
        let base = "\(parsed.scheme)://\(parsed.host)"
        switch kind {
        case .githubCloud, .githubEnterprise:
            return URL(string: "\(base)/settings/tokens/new?description=GoLens&scopes=repo,read:org,write:public_key,write:ssh_signing_key,write:gpg_key")
        case .gitlabCloud, .gitlabSelfHosted:
            return URL(string: "\(base)/-/user_settings/personal_access_tokens?name=GoLens&scopes=api,read_user,write_repository")
        }
    }

    static func normalizeHost(_ rawInput: String) -> (scheme: String, host: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("https", "") }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            let scheme = (url.scheme?.lowercased() == "http") ? "http" : "https"
            if let port = url.port {
                return (scheme, "\(host.lowercased()):\(port)")
            }
            return (scheme, host.lowercased())
        }
        var cleaned = trimmed.lowercased()
        var scheme = "https"
        if cleaned.hasPrefix("http://") {
            scheme = "http"
            cleaned.removeFirst("http://".count)
        } else if cleaned.hasPrefix("https://") {
            cleaned.removeFirst("https://".count)
        }
        if let slashIdx = cleaned.firstIndex(of: "/") {
            cleaned = String(cleaned[..<slashIdx])
        }
        return (scheme, cleaned)
    }

    static func resolveEndpoint(kind: GitAccountProviderKind, customServerURL: String) -> (scheme: String, host: String) {
        if kind.usesCustomServerURL {
            return normalizeHost(customServerURL)
        }
        return ("https", kind.defaultHost)
    }

    static func validateServerURL(_ rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a server URL (for example, https://gitlab.example.com)."
        }
        guard trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("http://") else {
            return "Start the server URL with https:// (for example, https://gitlab.example.com)."
        }
        let parsed = normalizeHost(trimmed)
        if parsed.host.isEmpty || !parsed.host.contains(".") && !parsed.host.hasPrefix("localhost") && !parsed.host.hasPrefix("127.0.0.1") {
            return "Enter a valid server hostname (for example, https://gitlab.example.com)."
        }
        return nil
    }

    func signInWithToken(
        providerKind: GitAccountProviderKind,
        serverURL: String,
        token: String,
        updatingAccountID: UUID? = nil
    ) async throws -> GitAccount {
        isVerifying = true
        defer { isVerifying = false }
        return try await signIn(
            providerKind: providerKind,
            customServerURL: serverURL,
            token: token,
            updatingAccountID: updatingAccountID
        )
    }

    func verifyExistingAccount(id: UUID) async {
        await verifyAccount(id)
    }

    func removeAccount(id: UUID) throws {
        try removeAccount(id)
    }

    func signIn(
        providerKind: GitAccountProviderKind,
        customServerURL: String,
        token: String,
        updatingAccountID: UUID? = nil
    ) async throws -> GitAccount {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw NSError(domain: "GitAccountStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a personal access token to sign in."
            ])
        }

        if providerKind.usesCustomServerURL, let problem = Self.validateServerURL(customServerURL) {
            throw NSError(domain: "GitAccountStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: problem
            ])
        }

        let endpoint = Self.resolveEndpoint(kind: providerKind, customServerURL: customServerURL)
        guard !endpoint.host.isEmpty else {
            throw NSError(domain: "GitAccountStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Enter a valid server URL."
            ])
        }

        let profile = try await Self.fetchUserProfile(
            providerKind: providerKind,
            scheme: endpoint.scheme,
            host: endpoint.host,
            token: trimmedToken
        )

        let existingIndex = accounts.firstIndex { acc in
            if let updatingAccountID, acc.id == updatingAccountID { return true }
            return acc.host.caseInsensitiveCompare(endpoint.host) == .orderedSame
        }

        let accountID = existingIndex.map { accounts[$0].id } ?? updatingAccountID ?? UUID()
        let account = GitAccount(
            id: accountID,
            providerKind: providerKind,
            scheme: endpoint.scheme,
            host: endpoint.host,
            username: profile.username,
            displayName: profile.displayName,
            email: profile.email,
            needsTokenUpdate: false
        )

        guard try saveToken(trimmedToken, for: accountID) else {
            throw NSError(domain: "GitAccountStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "GoLens couldn’t save the token in the Keychain. Unlock your login keychain, allow GoLens to use it, and try again."
            ])
        }
        if let existingIndex {
            accounts[existingIndex] = account
        } else {
            accounts.append(account)
        }
        persistAccounts()
        return account
    }

    func verifyAccount(_ accountID: UUID) async {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let account = accounts[index]
        guard let token = readToken(for: accountID), !token.isEmpty else {
            accounts[index].needsTokenUpdate = true
            persistAccounts()
            return
        }
        verifyingAccountIDs.insert(accountID)
        defer { verifyingAccountIDs.remove(accountID) }

        do {
            let profile = try await Self.fetchUserProfile(
                providerKind: account.providerKind,
                scheme: account.scheme,
                host: account.host,
                token: token
            )
            if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[idx].username = profile.username
                accounts[idx].displayName = profile.displayName
                accounts[idx].email = profile.email
                accounts[idx].needsTokenUpdate = false
                persistAccounts()
            }
        } catch {
            if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[idx].needsTokenUpdate = true
                persistAccounts()
            }
        }
    }

    func removeAccount(_ accountID: UUID) throws {
        try deleteToken(for: accountID)
        accounts.removeAll { $0.id == accountID }
        repositoriesByAccount.removeValue(forKey: accountID)
        persistAccounts()
    }

    func markTokenRejected(forHost rawHost: String) {
        let host = Self.normalizeHost(rawHost).host
        guard let idx = accounts.firstIndex(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) else { return }
        if !accounts[idx].needsTokenUpdate {
            accounts[idx].needsTokenUpdate = true
            persistAccounts()
        }
    }

    @discardableResult
    func fetchRepositories(for account: GitAccount) async -> [GitRemoteRepository] {
        guard let token = readToken(for: account.id), !token.isEmpty else { return [] }
        isLoadingRepositories = true
        defer { isLoadingRepositories = false }
        let repos = (try? await Self.loadRemoteRepositories(account: account, token: token)) ?? []
        repositoriesByAccount[account.id] = repos
        return repos
    }

    func syncCredentialsToCore() {
        struct CoreGitCredential: Encodable {
            let provider: String
            let scheme: String
            let host: String
            let username: String
            let token: String
        }
        var payload: [CoreGitCredential] = []
        for account in accounts {
            guard let token = readToken(for: account.id), !token.isEmpty else { continue }
            payload.append(CoreGitCredential(
                provider: account.providerKind.providerFamily,
                scheme: account.scheme,
                host: account.host,
                username: account.username,
                token: token
            ))
        }
        let jsonString = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        jsonString.withCString { cStr in
            SetGitCredentialsJSON(cStr)
        }
    }

    func detectAuthenticationFailure(errorText: String, remoteURLs: [String]) -> GitAuthRecoveryContext? {
        let lower = errorText.lowercased()
        let isAuthError = lower.contains("authentication failed")
            || lower.contains("could not read username")
            || lower.contains("could not read password")
            || lower.contains("terminal prompts disabled")
            || lower.contains("http basic: access denied")
            || lower.contains("returned error: 401")
            || lower.contains("returned error: 403")
            || lower.contains("permission denied (publickey)")
            || lower.contains("authentication required")
        guard isAuthError else { return nil }

        for candidate in [errorText] + remoteURLs {
            if let extracted = Self.extractHost(fromGitRemoteOrError: candidate) {
                let existing = account(forHost: extracted)
                if existing != nil {
                    markTokenRejected(forHost: extracted)
                }
                return GitAuthRecoveryContext(host: extracted, existingAccount: account(forHost: extracted))
            }
        }
        return nil
    }

    static func extractHost(fromGitRemoteOrError text: String) -> String? {
        let patternHTTPS = #"https?://([^/\s'":]+(?::\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: patternHTTPS, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            var host = String(text[range]).lowercased()
            if let atIndex = host.lastIndex(of: "@") {
                host = String(host[host.index(after: atIndex)...])
            }
            if !host.isEmpty { return host }
        }
        let patternSSH = #"git@([^:\s/'"]+):"#
        if let regex = try? NSRegularExpression(pattern: patternSSH, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let host = String(text[range]).lowercased()
            if !host.isEmpty { return host }
        }
        return nil
    }

    private struct UserProfile {
        let username: String
        let displayName: String
        let email: String?
    }

    private static func fetchUserProfile(
        providerKind: GitAccountProviderKind,
        scheme: String,
        host: String,
        token: String
    ) async throws -> UserProfile {
        let apiURL: URL?
        switch providerKind {
        case .githubCloud:
            apiURL = URL(string: "https://api.github.com/user")
        case .githubEnterprise:
            apiURL = URL(string: "\(scheme)://\(host)/api/v3/user")
        case .gitlabCloud, .gitlabSelfHosted:
            apiURL = URL(string: "\(scheme)://\(host)/api/v4/user")
        }
        guard let url = apiURL else {
            throw NSError(domain: "GitAccountStore", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Invalid API URL for \(host)."
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("GoLens/1.0", forHTTPHeaderField: "User-Agent")

        switch providerKind {
        case .githubCloud, .githubEnterprise:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .gitlabCloud, .gitlabSelfHosted:
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            throw NSError(domain: "GitAccountStore", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t connect to \(host). Check the server URL and your network connection."
            ])
        }

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GitAccountStore", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Received an invalid response from \(host)."
            ])
        }

        if http.statusCode == 401 {
            throw NSError(domain: "GitAccountStore", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "The personal access token was rejected by \(host). Check that the token hasn’t expired and try again."
            ])
        }
        if http.statusCode == 403 {
            throw NSError(domain: "GitAccountStore", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "This token doesn’t have permission to access \(host). Create a token with the required repository scopes."
            ])
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw NSError(domain: "GitAccountStore", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(host) returned HTTP \(http.statusCode). Verify the server URL and token."
            ])
        }

        if providerKind == .githubCloud || providerKind == .githubEnterprise,
           let scopesHeader = http.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            let scopes = Set(scopesHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            if !scopes.isEmpty && !scopes.contains("repo") && !scopes.contains("public_repo") {
                throw NSError(domain: "GitAccountStore", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "This token is missing the “repo” scope needed to clone, pull, and push repositories."
                ])
            }
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GitAccountStore", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t read the account profile returned by \(host)."
            ])
        }

        let username = (obj["login"] as? String) ?? (obj["username"] as? String) ?? ""
        guard !username.isEmpty else {
            throw NSError(domain: "GitAccountStore", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "\(host) did not return a valid username for this token."
            ])
        }
        let displayName = (obj["name"] as? String) ?? username
        let email = obj["email"] as? String
        return UserProfile(username: username, displayName: displayName, email: email)
    }

    private static func loadRemoteRepositories(account: GitAccount, token: String) async throws -> [GitRemoteRepository] {
        let url: URL?
        switch account.providerKind {
        case .githubCloud:
            url = URL(string: "https://api.github.com/user/repos?sort=updated&per_page=50&affiliation=owner,collaborator,organization_member")
        case .githubEnterprise:
            url = URL(string: "\(account.scheme)://\(account.host)/api/v3/user/repos?sort=updated&per_page=50&affiliation=owner,collaborator,organization_member")
        case .gitlabCloud, .gitlabSelfHosted:
            url = URL(string: "\(account.scheme)://\(account.host)/api/v4/projects?membership=true&order_by=last_activity_at&per_page=50")
        }
        guard let url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("GoLens/1.0", forHTTPHeaderField: "User-Agent")
        switch account.providerKind {
        case .githubCloud, .githubEnterprise:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .gitlabCloud, .gitlabSelfHosted:
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> GitRemoteRepository? in
            switch account.providerKind {
            case .githubCloud, .githubEnterprise:
                guard let fullName = item["full_name"] as? String,
                      let cloneURL = item["clone_url"] as? String else { return nil }
                let desc = (item["description"] as? String) ?? ""
                let sshURL = (item["ssh_url"] as? String) ?? ""
                let isPrivate = (item["private"] as? Bool) ?? false
                return GitRemoteRepository(
                    id: "\(account.id.uuidString):\(fullName)",
                    accountID: account.id,
                    providerKind: account.providerKind,
                    host: account.host,
                    fullName: fullName,
                    description: desc,
                    cloneURL: cloneURL,
                    sshURL: sshURL,
                    isPrivate: isPrivate
                )
            case .gitlabCloud, .gitlabSelfHosted:
                guard let fullName = item["path_with_namespace"] as? String,
                      let cloneURL = item["http_url_to_repo"] as? String else { return nil }
                let desc = (item["description"] as? String) ?? ""
                let sshURL = (item["ssh_url_to_repo"] as? String) ?? ""
                let visibility = (item["visibility"] as? String) ?? "private"
                return GitRemoteRepository(
                    id: "\(account.id.uuidString):\(fullName)",
                    accountID: account.id,
                    providerKind: account.providerKind,
                    host: account.host,
                    fullName: fullName,
                    description: desc,
                    cloneURL: cloneURL,
                    sshURL: sshURL,
                    isPrivate: visibility != "public"
                )
            }
        }
    }

    private var fileStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("GoLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("git-account-tokens.json")
    }

    private func readFileTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: fileStoreURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeFileTokens(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fileStoreURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileStoreURL.path)
    }

    @discardableResult
    func saveToken(_ token: String, for accountID: UUID) throws -> Bool {
        if usesFileCredentialStore {
            var dict = readFileTokens()
            dict[accountID.uuidString] = token
            do {
                try writeFileTokens(dict)
            } catch {
                throw NSError(domain: "GitAccountStore", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "GoLens couldn’t save the token to \(fileStoreURL.path). Check that you can write to this folder, then try again.",
                    NSUnderlyingErrorKey: error
                ])
            }
            return true
        }
        let encoded = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func migrateFileTokensToKeychain() {
        guard !usesFileCredentialStore, FileManager.default.fileExists(atPath: fileStoreURL.path) else { return }
        var remaining = readFileTokens()
        for (key, token) in remaining {
            guard let id = UUID(uuidString: key) else {
                remaining.removeValue(forKey: key)
                continue
            }
            if readToken(for: id) != nil || (try? saveToken(token, for: id)) == true {
                remaining.removeValue(forKey: key)
            }
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: fileStoreURL)
        } else {
            try? writeFileTokens(remaining)
        }
    }

    func readToken(for accountID: UUID) -> String? {
        if usesFileCredentialStore {
            return readFileTokens()[accountID.uuidString]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }

    func deleteToken(for accountID: UUID) throws {
        if usesFileCredentialStore {
            var dict = readFileTokens()
            guard dict.removeValue(forKey: accountID.uuidString) != nil else { return }
            do {
                try writeFileTokens(dict)
            } catch {
                throw NSError(domain: "GitAccountStore", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "GoLens couldn’t remove the token from \(fileStoreURL.path). Check that you can write to this folder, then try again.",
                    NSUnderlyingErrorKey: error
                ])
            }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "GitAccountStore", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "GoLens couldn’t remove the token from the Keychain. Unlock your login keychain, allow GoLens to use it, and try again."
            ])
        }
    }
}
