import Foundation

public typealias HostAuthorizationCheck = @Sendable (URL) -> Bool

public enum OutboundHostConsent {
    public static func normalizedHost(for url: URL) -> String? {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return nil }
        let stripped = stripBracketsAndTrailingDot(rawHost)
        guard !stripped.isEmpty else { return nil }
        if let port = url.port {
            return stripped.contains(":") ? "[\(stripped)]:\(port)" : "\(stripped):\(port)"
        }
        return stripped.contains(":") ? "[\(stripped)]" : stripped
    }

    public static func normalizedHost(forBaseURL baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return normalizedHost(for: url)
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        return isLoopback(host: rawHost)
    }

    public static func isLoopback(host: String) -> Bool {
        let bare = extractBareHostname(from: host)
        return bare == "localhost"
            || bare == "::1"
            || bare.hasPrefix("127.")
            || bare == "::ffff:127.0.0.1"
    }

    private static func stripBracketsAndTrailingDot(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("["), s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        while s.hasSuffix(".") {
            s.removeLast()
        }
        return s
    }

    private static func extractBareHostname(from hostOrHostPort: String) -> String {
        var working = hostOrHostPort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if working.hasPrefix("[") {
            if let closeIdx = working.firstIndex(of: "]") {
                working = String(working[working.index(after: working.startIndex)..<closeIdx])
            } else {
                working = String(working.dropFirst())
            }
        } else if let colonIdx = working.lastIndex(of: ":") {
            let beforeColon = String(working[..<colonIdx])
            let afterColon = String(working[working.index(after: colonIdx)...])
            if !beforeColon.contains(":"), Int(afterColon) != nil {
                working = beforeColon
            }
        }
        while working.hasSuffix(".") {
            working.removeLast()
        }
        return working
    }
}
