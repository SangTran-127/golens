import Foundation
import GopilotProvider
import GopilotRuntime

@Observable
final class AIProviderConsent: @unchecked Sendable {
    static let shared = AIProviderConsent()

    private static let hostsKey = "GoLensAIProviderConsentHosts"

    @ObservationIgnored private let lock = NSLock()
    private(set) var allowedHosts: Set<String>

    private init() {
        allowedHosts = Set(UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? [])
    }

    static func host(forBaseURL baseURL: String) -> String? {
        OutboundHostConsent.normalizedHost(forBaseURL: baseURL)
    }

    static func isLoopback(_ host: String) -> Bool {
        OutboundHostConsent.isLoopback(host: host)
    }

    static func makeTransport(configuration: URLSessionConfiguration? = nil) -> URLSessionTransport {
        URLSessionTransport(configuration: configuration) { url in
            AIProviderConsent.shared.isAllowed(url: url)
        }
    }

    func isAllowed(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if Self.isLoopback(host) { return true }
        return lock.withLock { allowedHosts.contains(host) }
    }

    func isAllowed(url: URL) -> Bool {
        if OutboundHostConsent.isLoopback(url) { return true }
        guard let host = OutboundHostConsent.normalizedHost(for: url) else { return false }
        return lock.withLock { allowedHosts.contains(host) }
    }

    func isAllowed(baseURL: String) -> Bool {
        isAllowed(Self.host(forBaseURL: baseURL))
    }

    func allow(_ host: String) {
        let inserted = lock.withLock { allowedHosts.insert(host).inserted }
        guard inserted else { return }
        persist()
    }

    func revoke(_ host: String) {
        let removed = lock.withLock { allowedHosts.remove(host) != nil }
        guard removed else { return }
        persist()
    }

    private func persist() {
        let sorted = lock.withLock { allowedHosts.sorted() }
        UserDefaults.standard.set(sorted, forKey: Self.hostsKey)
    }

    static func disclosure(host: String) -> String {
        "Gopilot sends your message, the files and symbols you attach, and the project code it reads during the turn to \(host). When AI Suggestions are on, the code around the cursor is sent to the same provider as you type. Environment files, SSH keys and private certificates are blocked, and recognized credentials are removed first. The provider’s terms decide whether it keeps this data. Conversations stay on this Mac. GoLens asks again if you change the provider."
    }
}
