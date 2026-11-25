import Foundation
import AppKit

extension EcosystemDocumentTools {

    static func validate(forPath path: String, text: String) -> [LSPDiagnostic] {
        validate(path: path, text: text)
    }

    static func validate(path: String, text: String) -> [LSPDiagnostic] {
        guard !text.isEmpty, text.utf8.count <= maxDocumentBytes else { return [] }

        if isJSONFile(path) {
            return validateJSON(text, allowComments: path.lowercased().hasSuffix(".jsonc"))
        } else if isYAMLFile(path) {
            return validateYAML(text)
        } else if isMakefile(path) {
            return validateMakefile(text)
        }
        return []
    }

    private static func validateJSON(_ text: String, allowComments: Bool) -> [LSPDiagnostic] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sanitizedText = allowComments ? stripJSONCommentsPreservingLayout(text) : text
        if let specific = scanSpecificJSONSyntaxError(sanitizedText) {
            return [specific]
        }

        guard let data = sanitizedText.data(using: .utf8) else { return [] }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return []
        } catch let error as NSError {
            let debugDesc = (error.userInfo["NSDebugDescription"] as? String) ?? error.localizedDescription
            let (line0, col0) = extractJSONErrorLocation(from: debugDesc, in: sanitizedText)
            let cleanedMsg = cleanJSONErrorMessage(debugDesc)
            return [
                LSPDiagnostic(
                    line: line0,
                    col: col0,
                    endLine: line0,
                    endCol: col0 + 1,
                    severity: 1,
                    message: cleanedMsg
                )
            ]
        }
    }

    private static func stripJSONCommentsPreservingLayout(_ text: String) -> String {
        var out: [UInt16] = []
        let chars = Array(text.utf16)
        out.reserveCapacity(chars.count)
        var i = 0
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        while i < chars.count {
            let c = chars[i]
            if inLineComment {
                if c == 0x0A || c == 0x0D {
                    inLineComment = false
                    out.append(c)
                } else {
                    out.append(0x20)
                }
                i += 1
                continue
            }
            if inBlockComment {
                if c == 0x2A && i + 1 < chars.count && chars[i + 1] == 0x2F {
                    inBlockComment = false
                    out.append(0x20)
                    out.append(0x20)
                    i += 2
                } else if c == 0x0A || c == 0x0D {
                    out.append(c)
                    i += 1
                } else {
                    out.append(0x20)
                    i += 1
                }
                continue
            }
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == 0x5C {
                    escaped = true
                } else if c == 0x22 {
                    inString = false
                }
                i += 1
                continue
            }
            if c == 0x22 {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == 0x2F && i + 1 < chars.count {
                if chars[i + 1] == 0x2F {
                    inLineComment = true
                    out.append(0x20)
                    out.append(0x20)
                    i += 2
                    continue
                } else if chars[i + 1] == 0x2A {
                    inBlockComment = true
                    out.append(0x20)
                    out.append(0x20)
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func scanSpecificJSONSyntaxError(_ text: String) -> LSPDiagnostic? {
        let lines = text.components(separatedBy: .newlines)
        var openBrackets: [(char: Character, line: Int, col: Int)] = []
        var lastSignificantToken: (char: Character, line: Int, col: Int)?

        for (lineIdx, line) in lines.enumerated() {
            var inString = false
            var escaped = false
            var stringStartCol = 0

            for (colIdx, ch) in line.enumerated() {
                if inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        inString = false
                        lastSignificantToken = ("\"", lineIdx, colIdx)
                    }
                    continue
                }

                if ch == " " || ch == "\t" || ch == "\r" {
                    continue
                }

                if ch == "\"" {
                    inString = true
                    stringStartCol = colIdx
                    continue
                }

                if ch == "{" || ch == "[" {
                    openBrackets.append((ch, lineIdx, colIdx))
                    lastSignificantToken = (ch, lineIdx, colIdx)
                } else if ch == "}" || ch == "]" {
                    if let prev = lastSignificantToken, prev.char == "," {
                        return LSPDiagnostic(
                            line: prev.line,
                            col: prev.col,
                            endLine: prev.line,
                            endCol: prev.col + 1,
                            severity: 1,
                            message: "Trailing comma before '\(ch)' is not permitted in JSON"
                        )
                    }
                    let expectedOpen: Character = ch == "}" ? "{" : "["
                    if let lastOpen = openBrackets.popLast() {
                        if lastOpen.char != expectedOpen {
                            return LSPDiagnostic(
                                line: lineIdx,
                                col: colIdx,
                                endLine: lineIdx,
                                endCol: colIdx + 1,
                                severity: 1,
                                message: "Mismatched closing '\(ch)'; expected closing for '\(lastOpen.char)' from line \(lastOpen.line + 1)"
                            )
                        }
                    } else {
                        return LSPDiagnostic(
                            line: lineIdx,
                            col: colIdx,
                            endLine: lineIdx,
                            endCol: colIdx + 1,
                            severity: 1,
                            message: "Unexpected closing '\(ch)' without matching '\(expectedOpen)'"
                        )
                    }
                    lastSignificantToken = (ch, lineIdx, colIdx)
                } else {
                    lastSignificantToken = (ch, lineIdx, colIdx)
                }
            }

            if inString {
                return LSPDiagnostic(
                    line: lineIdx,
                    col: stringStartCol,
                    endLine: lineIdx,
                    endCol: max(stringStartCol + 1, line.count),
                    severity: 1,
                    message: "Unclosed string literal on line \(lineIdx + 1)"
                )
            }
        }

        if let unclosed = openBrackets.last {
            return LSPDiagnostic(
                line: unclosed.line,
                col: unclosed.col,
                endLine: unclosed.line,
                endCol: unclosed.col + 1,
                severity: 1,
                message: "Unclosed '\(unclosed.char)' (missing matching '\(unclosed.char == "{" ? "}" : "]")')"
            )
        }

        return nil
    }

    private static func extractJSONErrorLocation(from debugDesc: String, in text: String) -> (Int, Int) {
        if let regex = try? NSRegularExpression(pattern: #"line\s+(\d+),\s*column\s+(\d+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: debugDesc, range: NSRange(debugDesc.startIndex..., in: debugDesc)),
           let lineRange = Range(match.range(at: 1), in: debugDesc),
           let colRange = Range(match.range(at: 2), in: debugDesc),
           let line1 = Int(debugDesc[lineRange]),
           let col1 = Int(debugDesc[colRange]) {
            return (max(0, line1 - 1), max(0, col1 - 1))
        }

        if let regex = try? NSRegularExpression(pattern: #"character\s+(\d+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: debugDesc, range: NSRange(debugDesc.startIndex..., in: debugDesc)),
           let offsetRange = Range(match.range(at: 1), in: debugDesc),
           let targetOffset = Int(debugDesc[offsetRange]) {
            var currentOffset = 0
            let lines = text.components(separatedBy: "\n")
            for (lineIdx, line) in lines.enumerated() {
                let lineLen = line.utf8.count + 1
                if currentOffset + lineLen > targetOffset {
                    let col = max(0, targetOffset - currentOffset)
                    return (lineIdx, col)
                }
                currentOffset += lineLen
            }
            return (max(0, lines.count - 1), 0)
        }

        return (0, 0)
    }

    private static func cleanJSONErrorMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Invalid JSON syntax"
        }
        return trimmed.hasPrefix("JSON") ? trimmed : "JSON syntax error: \(trimmed)"
    }

    private static func validateYAML(_ text: String) -> [LSPDiagnostic] {
        let lines = text.components(separatedBy: .newlines)
        let limit = min(lines.count, maxDiagnosticLines)
        var diagnostics: [LSPDiagnostic] = []
        var blockScalarIndent: Int?
        var flowDepth = 0
        var prevWasScalarValueLine = false
        var prevIndent = 0

        for lineIdx in 0..<limit {
            let line = lines[lineIdx]

            var firstNonWSCol = 0
            var tabCol: Int?
            for (colIdx, ch) in line.enumerated() {
                if ch == "\t" {
                    if tabCol == nil { tabCol = colIdx }
                    firstNonWSCol = colIdx + 1
                } else if ch == " " {
                    firstNonWSCol = colIdx + 1
                } else {
                    break
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if let tCol = tabCol {
                diagnostics.append(
                    LSPDiagnostic(
                        line: lineIdx,
                        col: tCol,
                        endLine: lineIdx,
                        endCol: max(tCol + 1, firstNonWSCol),
                        severity: 1,
                        message: "YAML forbids tabs for indentation; use spaces (Format Document to fix)"
                    )
                )
            }

            let indent = yamlLeadingIndent(of: line)
            if let bsIndent = blockScalarIndent {
                if indent > bsIndent {
                    continue
                } else {
                    blockScalarIndent = nil
                }
            }

            if trimmed == "---" || trimmed == "..." {
                flowDepth = 0
                prevWasScalarValueLine = false
                prevIndent = 0
                continue
            }

            if let quoteDiag = checkYAMLUnclosedQuote(in: line, lineIdx: lineIdx, firstNonWSCol: firstNonWSCol) {
                diagnostics.append(quoteDiag)
                continue
            }

            let codeWithoutComment = stripInlineYAMLComment(trimmed)
            let prevFlowDepth = flowDepth
            flowDepth = max(0, flowDepth + netFlowBracketDelta(in: codeWithoutComment))

            if prevFlowDepth > 0 || flowDepth > 0 {
                prevWasScalarValueLine = false
                prevIndent = indent
                continue
            }

            let trimmedCode = codeWithoutComment.trimmingCharacters(in: .whitespaces)
            if trimmedCode.hasSuffix("|") || trimmedCode.hasSuffix("|-") || trimmedCode.hasSuffix("|+") ||
               trimmedCode.hasSuffix(">") || trimmedCode.hasSuffix(">-") || trimmedCode.hasSuffix(">+") {
                blockScalarIndent = indent
                prevWasScalarValueLine = false
                prevIndent = indent
                continue
            }

            if trimmedCode.hasPrefix("-") || trimmedCode.hasPrefix("?") || trimmedCode.hasPrefix("&") || trimmedCode.hasPrefix("*") {
                prevWasScalarValueLine = false
                prevIndent = indent
                continue
            }

            if !containsYAMLMappingColon(in: trimmedCode) {
                diagnostics.append(
                    LSPDiagnostic(
                        line: lineIdx,
                        col: firstNonWSCol,
                        endLine: lineIdx,
                        endCol: line.utf16.count,
                        severity: 1,
                        message: "YAML mapping entry is missing ':' after key"
                    )
                )
                prevWasScalarValueLine = false
                prevIndent = indent
                continue
            }

            if prevWasScalarValueLine && indent > prevIndent {
                diagnostics.append(
                    LSPDiagnostic(
                        line: lineIdx,
                        col: firstNonWSCol,
                        endLine: lineIdx,
                        endCol: line.utf16.count,
                        severity: 1,
                        message: "Unexpected indentation under a scalar value (parent key already has an inline value)"
                    )
                )
            }

            if let (_, rawVal) = splitYAMLKeyValue(trimmedCode) {
                let cleanVal = rawVal.trimmingCharacters(in: .whitespaces)
                prevWasScalarValueLine = !cleanVal.isEmpty && !cleanVal.hasPrefix("&") && !cleanVal.hasPrefix("*")
            } else {
                prevWasScalarValueLine = false
            }
            prevIndent = indent
        }

        return diagnostics
    }

    private static func checkYAMLUnclosedQuote(in line: String, lineIdx: Int, firstNonWSCol: Int) -> LSPDiagnostic? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var quoteStartCol = firstNonWSCol
        let chars = Array(line)

        for i in 0..<chars.count {
            let c = chars[i]
            if inDouble {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inDouble = false
                }
            } else if inSingle {
                if c == "'" {
                    inSingle = false
                }
            } else {
                if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
                    break
                } else if c == "\"" {
                    inDouble = true
                    quoteStartCol = i
                } else if c == "'" {
                    inSingle = true
                    quoteStartCol = i
                }
            }
        }

        if inDouble || inSingle {
            let qChar = inDouble ? "\"" : "'"
            return LSPDiagnostic(
                line: lineIdx,
                col: quoteStartCol,
                endLine: lineIdx,
                endCol: max(quoteStartCol + 1, line.utf16.count),
                severity: 1,
                message: "Unclosed \(qChar) quote in YAML value"
            )
        }
        return nil
    }

    private static func netFlowBracketDelta(in line: String) -> Int {
        var delta = 0
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in line {
            if inDouble {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" { inSingle = false }
            } else {
                switch ch {
                case "\"": inDouble = true
                case "'": inSingle = true
                case "{", "[": delta += 1
                case "}", "]": delta -= 1
                default: break
                }
            }
        }
        return delta
    }

    static func containsYAMLMappingColon(in code: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(code)

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
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func validateMakefile(_ text: String) -> [LSPDiagnostic] {
        if text.contains(".RECIPEPREFIX") {
            return []
        }

        let lines = text.components(separatedBy: .newlines)
        let limit = min(lines.count, maxDiagnosticLines)
        var diagnostics: [LSPDiagnostic] = []
        var inTargetBlock = false
        var previousLineContinued = false
        var inDefineBlock = false

        let conditionalDirectives: Set<String> = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "define", "endef", "include", "-include", "sinclude", "export", "unexport", "override"]

        for lineIdx in 0..<limit {
            let line = lines[lineIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if previousLineContinued {
                previousLineContinued = trimmed.hasSuffix("\\")
                continue
            }
            previousLineContinued = trimmed.hasSuffix("\\")

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let firstWord = String(trimmed.split(whereSeparator: { $0.isWhitespace }).first ?? "")
            if firstWord == "define" {
                inDefineBlock = true
                continue
            } else if firstWord == "endef" {
                inDefineBlock = false
                continue
            }
            if inDefineBlock {
                continue
            }

            if line.hasPrefix("\t") {
                continue
            }

            if line.hasPrefix(" ") {
                if inTargetBlock && !conditionalDirectives.contains(firstWord) {
                    var spaceCount = 0
                    for ch in line {
                        if ch == " " { spaceCount += 1 } else { break }
                    }
                    diagnostics.append(
                        LSPDiagnostic(
                            line: lineIdx,
                            col: 0,
                            endLine: lineIdx,
                            endCol: max(1, spaceCount),
                            severity: 1,
                            message: "Makefile recipe line uses spaces instead of a hard Tab (press ⌃⌘I to fix)"
                        )
                    )
                }
                continue
            }

            if conditionalDirectives.contains(firstWord) {
                continue
            }

            if line.range(of: #"^[A-Za-z0-9_.-]+\s*(?::=|\?=|\+=|=)"#, options: .regularExpression) != nil {
                inTargetBlock = false
                continue
            }

            if let colonIdx = line.firstIndex(of: ":") {
                let afterColon = line[line.index(after: colonIdx)...]
                if afterColon.first != "=" {
                    let targetName = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    inTargetBlock = !targetName.isEmpty && targetName != ".PHONY"
                } else {
                    inTargetBlock = false
                }
            } else {
                inTargetBlock = false
            }
        }

        return diagnostics
    }
}
