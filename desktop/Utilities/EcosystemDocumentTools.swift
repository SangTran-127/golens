import Foundation
import AppKit

typealias LSPDiagnostic = DiagnosticData
typealias EnvEntryInfo = EcosystemDocumentTools.EnvEntryInfo

extension DiagnosticData {
    var range: LSPRange {
        LSPRange(
            start: LSPPosition(line: line, character: col),
            end: LSPPosition(line: endLine, character: endCol)
        )
    }

    init(range: LSPRange, severity: Int, message: String) {
        self.init(
            line: range.start.line,
            col: range.start.character,
            endLine: range.end.line,
            endCol: range.end.character,
            severity: severity,
            message: message
        )
    }
}

enum EcosystemDocumentTools {
    static let maxDocumentBytes = 2_000_000
    static let maxDiagnosticLines = 10_000

    static func isJSONFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "json" || ext == "jsonc"
    }

    static func isYAMLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    static func isEnvFile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if filename == ".env" || filename.hasPrefix(".env.") {
            return true
        }
        return ["env", "local", "beta", "properties"].contains(ext)
    }

    static func isMakefile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        return filename == "makefile" || filename == "gnumakefile" || filename.hasPrefix("makefile.") || ext == "mk"
    }

    static func isDockerfile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        return filename == "dockerfile" || filename.hasPrefix("dockerfile.") || ext == "dockerfile"
    }

    static func isDockerComposeFile(_ path: String) -> Bool {
        guard isYAMLFile(path) else { return false }
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename.contains("docker-compose") || filename.contains("compose")
    }

    static func isTOMLFile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "toml" || filename == "cargo.lock"
    }

    static func isSQLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "sql" || ext == "cql"
    }

    static func isProtoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "proto"
    }

    static func isMarkdownFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    static func isHTTPFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "http" || ext == "rest"
    }

    static func isHTTPEnvironmentFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "http-client.env.json" || name == "http-client.private.env.json"
    }

    static func isBrunoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "bru"
    }

    static func isNonGoEcosystemFile(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "go" { return false }
        if isJSONFile(path) || isYAMLFile(path) || isEnvFile(path) || isMakefile(path) || isDockerfile(path) {
            return true
        }
        return ["toml", "sql", "cql", "proto", "md", "markdown", "bru", "sh", "bash", "zsh"].contains(ext)
    }

    static func yamlLeadingIndent(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " {
                count += 1
            } else if ch == "\t" {
                count += 2
            } else {
                break
            }
        }
        return count
    }

    static func splitYAMLKeyValue(_ line: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(line)

        for i in 0..<chars.count {
            let c = chars[i]
            if inDouble {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else {
                if c == "\"" {
                    inDouble = true
                } else if c == "'" {
                    inSingle = true
                } else if c == ":" {
                    if i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" {
                        let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                        let val = i + 1 < chars.count ? String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces) : ""
                        return key.isEmpty ? nil : (key, val)
                    }
                }
            }
        }
        return nil
    }

    static func stripInlineYAMLComment(_ text: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(text)

        for i in 0..<chars.count {
            let c = chars[i]
            if inDouble {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else {
                if c == "\"" {
                    inDouble = true
                } else if c == "'" {
                    inSingle = true
                } else if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
                    return String(chars[0..<i])
                }
            }
        }
        return text
    }

    static func unquoteYAMLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
