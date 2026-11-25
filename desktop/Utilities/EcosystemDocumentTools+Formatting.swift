import Foundation
import AppKit

extension EcosystemDocumentTools {
    static func formatDocument(forPath path: String, text: String) -> String? {
        formatDocument(path: path, text: text)
    }

    static func formatDocument(path: String, text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= maxDocumentBytes else { return nil }

        if isJSONFile(path) {
            return formatJSON(text)
        } else if isYAMLFile(path) {
            return formatYAML(text)
        } else if isMakefile(path) {
            return formatMakefile(text)
        } else if isEnvFile(path) {
            return formatEnvFile(text)
        }
        return nil
    }

    static func formatJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return prettyPrintJSONTokens(trimmed, indentStep: "  ") + "\n"
    }

    private static func prettyPrintJSONTokens(_ json: String, indentStep: String) -> String {
        var out = ""
        out.reserveCapacity(json.count + json.count / 4)
        var indentLevel = 0
        var inString = false
        var escaped = false
        let chars = Array(json)
        var i = 0

        func appendIndent(_ level: Int) {
            for _ in 0..<max(0, level) {
                out.append(indentStep)
            }
        }

        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if c.isWhitespace {
                i += 1
                continue
            }

            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                let closeChar: Character = c == "{" ? "}" : "]"
                var look = i + 1
                while look < chars.count && chars[look].isWhitespace {
                    look += 1
                }
                if look < chars.count && chars[look] == closeChar {
                    out.append(c)
                    out.append(closeChar)
                    i = look + 1
                    continue
                }
                out.append(c)
                out.append("\n")
                indentLevel += 1
                appendIndent(indentLevel)
            case "}", "]":
                out.append("\n")
                indentLevel = max(0, indentLevel - 1)
                appendIndent(indentLevel)
                out.append(c)
            case ",":
                out.append(",\n")
                appendIndent(indentLevel)
            case ":":
                out.append(": ")
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }

    private static func formatYAML(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var formattedLines: [String] = []
        formattedLines.reserveCapacity(lines.count)

        for line in lines {
            var leadingSpaces = ""
            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == "\t" {
                    leadingSpaces.append("  ")
                } else if ch == " " {
                    leadingSpaces.append(" ")
                } else {
                    break
                }
                idx = line.index(after: idx)
            }
            let rest = String(line[idx...]).replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            if rest.isEmpty {
                formattedLines.append("")
            } else {
                formattedLines.append(leadingSpaces + rest)
            }
        }

        while formattedLines.last?.isEmpty == true {
            formattedLines.removeLast()
        }
        return formattedLines.joined(separator: "\n") + "\n"
    }

    private static func formatMakefile(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var formattedLines: [String] = []
        formattedLines.reserveCapacity(lines.count)

        var inTargetBlock = false
        var previousLineContinued = false
        var inDefineBlock = false
        let conditionalDirectives: Set<String> = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "define", "endef", "include", "-include", "sinclude", "export", "unexport", "override"]

        for line in lines {
            let trimmedRight = line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            let trimmed = trimmedRight.trimmingCharacters(in: .whitespaces)

            if previousLineContinued {
                previousLineContinued = trimmed.hasSuffix("\\")
                formattedLines.append(trimmedRight)
                continue
            }
            previousLineContinued = trimmed.hasSuffix("\\")

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                formattedLines.append(trimmedRight)
                continue
            }

            let firstWord = String(trimmed.split(whereSeparator: { $0.isWhitespace }).first ?? "")
            if firstWord == "define" {
                inDefineBlock = true
                formattedLines.append(trimmedRight)
                continue
            } else if firstWord == "endef" {
                inDefineBlock = false
                formattedLines.append(trimmedRight)
                continue
            }
            if inDefineBlock {
                formattedLines.append(trimmedRight)
                continue
            }

            if trimmedRight.hasPrefix("\t") {
                formattedLines.append(trimmedRight)
                continue
            }

            if trimmedRight.hasPrefix(" ") {
                if inTargetBlock && !conditionalDirectives.contains(firstWord) {
                    formattedLines.append("\t" + trimmed)
                } else {
                    formattedLines.append(trimmedRight)
                }
                continue
            }

            if conditionalDirectives.contains(firstWord) {
                formattedLines.append(trimmedRight)
                continue
            }

            if trimmedRight.range(of: #"^[A-Za-z0-9_.-]+\s*(?::=|\?=|\+=|=)"#, options: .regularExpression) != nil {
                inTargetBlock = false
                formattedLines.append(trimmedRight)
                continue
            }

            if let colonIdx = trimmedRight.firstIndex(of: ":") {
                let afterColon = trimmedRight[trimmedRight.index(after: colonIdx)...]
                if afterColon.first != "=" {
                    let targetName = String(trimmedRight[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    inTargetBlock = !targetName.isEmpty && targetName != ".PHONY"
                } else {
                    inTargetBlock = false
                }
            } else {
                inTargetBlock = false
            }

            formattedLines.append(trimmedRight)
        }

        while formattedLines.last?.isEmpty == true {
            formattedLines.removeLast()
        }
        return formattedLines.joined(separator: "\n") + "\n"
    }

    private static func formatEnvFile(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var formattedLines: [String] = []
        formattedLines.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("[") {
                formattedLines.append(trimmed)
                continue
            }

            var hasExport = false
            var working = trimmed
            if working.hasPrefix("export ") {
                hasExport = true
                working = String(working.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }

            if let eqIdx = working.firstIndex(of: "=") {
                let key = String(working[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(working[working.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                let prefix = hasExport ? "export " : ""
                formattedLines.append("\(prefix)\(key)=\(val)")
            } else {
                formattedLines.append(trimmed)
            }
        }

        while formattedLines.last?.isEmpty == true {
            formattedLines.removeLast()
        }
        return formattedLines.joined(separator: "\n") + "\n"
    }
}
