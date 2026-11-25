import Foundation

enum DiagnosticsRedactor {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func make(_ pattern: String, _ template: String) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
        }
        return [
            make(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            make(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*$"#, "[REDACTED_PRIVATE_KEY]"),
            make(#"(?i)\bBearer\s+(?!\[REDACTED\b)[A-Za-z0-9._~+/=\-]{6,}"#, "Bearer [REDACTED]"),
            make(#"(?i)\bBasic\s+(?!\[REDACTED\b)[A-Za-z0-9+/=]{6,}"#, "Basic [REDACTED]"),
            make(#"\bsk-ant-[A-Za-z0-9_\-]{8,}"#, "[REDACTED_API_KEY]"),
            make(#"\bsk-(?:proj-|svcacct-|live-|test-)?[A-Za-z0-9_\-]{12,}"#, "[REDACTED_API_KEY]"),
            make(#"\bAIza[0-9A-Za-z_\-]{20,}"#, "[REDACTED_API_KEY]"),
            make(#"\b[rs]k_(?:live|test)_[A-Za-z0-9]{10,}"#, "[REDACTED_API_KEY]"),
            make(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "[REDACTED_TOKEN]"),
            make(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "[REDACTED_TOKEN]"),
            make(#"\bxox[baprs]-[0-9A-Za-z\-]{10,}"#, "[REDACTED_TOKEN]"),
            make(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#, "[REDACTED_ACCESS_KEY]"),
            make(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "[REDACTED_TOKEN]"),
            make(#"([a-zA-Z][a-zA-Z0-9+.-]*://)(?!\[REDACTED\]@)([^/\s:@]+(?::[^/\s@]*)?)@"#, "$1[REDACTED]@"),
            make(
                #"(?i)\b([A-Za-z0-9_\-]{0,40}(?:key|secret|token|password|passwd|pass|pwd|credentials?|auth))(["']?\s*[:=]\s*)(?!["']?(?:\[REDACTED|Bearer\s|Basic\s))("[^"\n]{3,}"|'[^'\n]{3,}'|[^\s"',;)}\]]{3,})"#,
                "$1$2[REDACTED]"
            ),
            make(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, "[REDACTED_EMAIL]"),
            make(#"/Users/[A-Za-z0-9._\-]+"#, "~")
        ]
    }()

    static func redact(_ input: String, extraSecrets: [String] = [], projectPaths: [String] = []) -> String {
        guard !input.isEmpty else { return input }
        var output = input

        let sortedSecrets = extraSecrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for secret in sortedSecrets where output.contains(secret) {
            output = output.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        for path in projectPaths.filter({ $0.count > 1 }).sorted(by: { $0.count > $1.count }) where output.contains(path) {
            output = output.replacingOccurrences(of: path, with: "[Project]")
        }

        let home = NSHomeDirectory()
        if home.count > 1, output.contains(home) {
            output = output.replacingOccurrences(of: home, with: "~")
        }

        for rule in rules {
            let ns = output as NSString
            let range = NSRange(location: 0, length: ns.length)
            output = rule.regex.stringByReplacingMatches(in: output, range: range, withTemplate: rule.template)
        }

        return output
    }
}
