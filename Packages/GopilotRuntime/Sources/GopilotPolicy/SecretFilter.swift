import Foundation

public struct RedactionResult: Sendable, Equatable {
    public let text: String
    public let counts: [String: Int]

    public var total: Int { counts.values.reduce(0, +) }
    public var didRedact: Bool { total > 0 }
}

public struct SecretFilter: Sendable {
    private struct Rule: Sendable {
        let name: String
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func rule(_ name: String, _ pattern: String, _ template: String? = nil) -> Rule {
            Rule(name: name, regex: try! NSRegularExpression(pattern: pattern), template: template ?? "[REDACTED:\(name)]")
        }
        return [
            rule("pem", #"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#),
            rule("pem", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*$"#),
            rule("api-key", #"\bsk-[A-Za-z0-9_\-]{16,}"#),
            rule("aws-key-id", #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{16}\b"#),
            rule("github-token", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
            rule("slack-token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
            rule("jwt", #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            rule("bearer", #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{16,}=*"#, "Bearer [REDACTED:bearer]"),
            rule("url-credentials", #"(?<=://)[^/\s:@"']+:[^/\s@"']+(?=@)"#),
            rule(
                "assignment",
                #"(?i)([A-Za-z0-9_.\-]{0,40}(?:password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key)[A-Za-z0-9_.\-]{0,40})(["']?\s*[:=]\s*)(?!["']?\[REDACTED)("[^"\n]{4,}"|'[^'\n]{4,}'|[^\s"',;()]{4,}(?![A-Za-z0-9_.(\[]))"#,
                "$1$2[REDACTED:assignment]"
            )
        ]
    }()

    private let literals: [String]

    public init(literalSecrets: [String] = []) {
        literals = literalSecrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func redact(_ text: String) -> RedactionResult {
        var output = text
        var counts: [String: Int] = [:]

        for literal in literals where output.contains(literal) {
            let occurrences = output.components(separatedBy: literal).count - 1
            output = output.replacingOccurrences(of: literal, with: "[REDACTED:known-secret]")
            counts["known-secret", default: 0] += occurrences
        }

        for rule in Self.rules {
            let range = NSRange(location: 0, length: (output as NSString).length)
            let hits = rule.regex.numberOfMatches(in: output, range: range)
            guard hits > 0 else { continue }
            output = rule.regex.stringByReplacingMatches(in: output, range: range, withTemplate: rule.template)
            counts[rule.name, default: 0] += hits
        }

        let entropyResult = Self.redactHighEntropyTokens(in: output)
        if entropyResult.hits > 0 {
            output = entropyResult.text
            counts["high-entropy", default: 0] += entropyResult.hits
        }

        return RedactionResult(text: output, counts: counts)
    }

    private static let highEntropyCandidateRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9+/_=\-]{32,}\b"#)

    public static func shannonEntropy(_ token: String) -> Double {
        guard !token.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for ch in token { freq[ch, default: 0] += 1 }
        let length = Double(token.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / length
            entropy -= p * log2(p)
        }
        return entropy
    }

    private static func looksLikeHighEntropySecret(_ token: String) -> Bool {
        guard token.count >= 32 else { return false }
        if token.contains("/") || token.hasPrefix("REDACTED") || token.hasPrefix("http") { return false }
        var hasUpper = false
        var hasLower = false
        var hasDigit = false
        for scalar in token.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) { hasUpper = true }
            else if CharacterSet.lowercaseLetters.contains(scalar) { hasLower = true }
            else if CharacterSet.decimalDigits.contains(scalar) { hasDigit = true }
        }
        let isHex = token.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
        let hasMixedClasses = (hasUpper && hasLower && hasDigit) || (isHex && hasDigit && (hasLower || hasUpper))
        guard hasMixedClasses else { return false }
        let threshold = isHex ? 3.5 : (token.count >= 40 ? 5.2 : 5.0)
        return shannonEntropy(token) >= threshold
    }

    private static func redactHighEntropyTokens(in text: String) -> (text: String, hits: Int) {
        let ns = text as NSString
        let matches = highEntropyCandidateRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, 0) }
        var mutated = text
        var hits = 0
        for match in matches.reversed() {
            let candidate = (mutated as NSString).substring(with: match.range)
            guard looksLikeHighEntropySecret(candidate) else { continue }
            if let range = Range(match.range, in: mutated) {
                mutated.replaceSubrange(range, with: "[REDACTED:high-entropy]")
                hits += 1
            }
        }
        return (mutated, hits)
    }

    public func containsSecret(_ text: String) -> Bool {
        redact(text).didRedact
    }
}

public struct EnvironmentBuilder: Sendable {
    public static let defaultAllowedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL",
        "GOPATH", "GOCACHE", "GOMODCACHE", "GOROOT", "GOFLAGS", "GOPROXY", "GOSUMDB", "GOPRIVATE",
        "GOOS", "GOARCH", "GOTOOLCHAIN", "GO111MODULE", "CGO_ENABLED"
    ]

    private static let allowedGoFlags: Set<String> = ["-mod=readonly", "-mod=vendor", "-trimpath", "-buildvcs=false"]
    private static let secretNameFragments = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "SESSION", "COOKIE"]

    private let filter: SecretFilter
    private let allowed: Set<String>

    public init(filter: SecretFilter = SecretFilter(), additionalAllowedNames: Set<String> = []) {
        self.filter = filter
        allowed = Self.defaultAllowedNames.union(additionalAllowedNames)
    }

    public func build(from source: [String: String], grantedNames: Set<String> = []) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in source {
            let permitted = allowed.contains(name) || grantedNames.contains(name)
            guard permitted, !Self.looksSecret(name: name), !filter.containsSecret(value) else { continue }
            result[name] = value
        }
        let flags = (source["GOFLAGS"] ?? "").split(separator: " ").map(String.init).filter { Self.allowedGoFlags.contains($0) }
        let forced = flags.contains("-mod=readonly") || flags.contains("-mod=vendor") ? flags : ["-mod=readonly"] + flags
        result["GOFLAGS"] = forced.joined(separator: " ")
        if !grantedNames.contains("CGO_ENABLED") {
            result["CGO_ENABLED"] = "0"
        } else if result["CGO_ENABLED"] == nil {
            result["CGO_ENABLED"] = "0"
        }
        return result
    }

    static func looksSecret(name: String) -> Bool {
        let upper = name.uppercased()
        return secretNameFragments.contains { upper.contains($0) }
    }
}
