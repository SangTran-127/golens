import Foundation
import AppKit

extension EcosystemDocumentTools {

    static func documentSymbols(path: String, text: String) -> [DocumentSymbol] {
        documentSymbols(forPath: path, text: text)
    }

    static func documentSymbols(forPath path: String, text: String) -> [DocumentSymbol] {
        guard !text.isEmpty, text.utf8.count <= maxDocumentBytes else { return [] }

        if isJSONFile(path) {
            return parseJSONSymbols(text)
        } else if isYAMLFile(path) {
            return parseYAMLSymbols(text)
        } else if isMakefile(path) {
            return parseMakefileSymbols(text)
        } else if isDockerfile(path) {
            return parseDockerfileSymbols(text)
        } else if isEnvFile(path) || isTOMLFile(path) {
            return parseEnvOrTOMLSymbols(text)
        } else if isSQLFile(path) {
            return parseSQLSymbols(text)
        } else if isProtoFile(path) {
            return parseProtoSymbols(text)
        } else if isMarkdownFile(path) {
            return parseMarkdownSymbols(text)
        } else if isBrunoFile(path) {
            return parseBrunoSymbols(text)
        }
        return []
    }

    static func breadcrumbSteps(path: String, text: String, cursorLine: Int) -> [(name: String, line: Int, col: Int)] {
        breadcrumbSteps(forPath: path, text: text, cursorLine: cursorLine)
    }

    static func breadcrumbSteps(forPath path: String, text: String, cursorLine: Int) -> [(name: String, line: Int, col: Int)] {
        guard !text.isEmpty, text.utf8.count <= maxDocumentBytes else { return [] }
        let targetLine0 = max(0, cursorLine - 1)
        let symbols = documentSymbols(forPath: path, text: text)
        guard !symbols.isEmpty else { return [] }

        var trail: [(name: String, line: Int, col: Int)] = []
        collectActiveSymbolTrail(in: symbols, targetLine0: targetLine0, into: &trail)
        return trail
    }

    private static func collectActiveSymbolTrail(
        in symbols: [DocumentSymbol],
        targetLine0: Int,
        into trail: inout [(name: String, line: Int, col: Int)]
    ) {
        if let containing = symbols.last(where: { $0.range.start.line <= targetLine0 && targetLine0 <= $0.range.end.line }) {
            trail.append((
                name: containing.name,
                line: containing.selectionRange.start.line + 1,
                col: containing.selectionRange.start.character + 1
            ))
            if let children = containing.children, !children.isEmpty {
                collectActiveSymbolTrail(in: children, targetLine0: targetLine0, into: &trail)
            }
            return
        }
        if trail.isEmpty, let preceding = symbols.last(where: { $0.range.start.line <= targetLine0 }) {
            trail.append((
                name: preceding.name,
                line: preceding.selectionRange.start.line + 1,
                col: preceding.selectionRange.start.character + 1
            ))
        }
    }

    private final class MutableSymbolNode {
        var name: String
        var detail: String?
        var kind: Int
        var startLine: Int
        var startCol: Int
        var selEndLine: Int
        var selEndCol: Int
        var endLine: Int
        var endCol: Int
        var indent: Int
        var isArrayContainer: Bool
        var nextArrayIndex: Int = 0
        var children: [MutableSymbolNode] = []

        init(
            name: String,
            detail: String? = nil,
            kind: Int,
            startLine: Int,
            startCol: Int,
            selEndLine: Int,
            selEndCol: Int,
            endLine: Int,
            endCol: Int,
            indent: Int = 0,
            isArrayContainer: Bool = false
        ) {
            self.name = name
            self.detail = detail
            self.kind = kind
            self.startLine = startLine
            self.startCol = startCol
            self.selEndLine = selEndLine
            self.selEndCol = selEndCol
            self.endLine = endLine
            self.endCol = endCol
            self.indent = indent
            self.isArrayContainer = isArrayContainer
        }

        func toDocumentSymbol() -> DocumentSymbol {
            let startPos = LSPPosition(line: startLine, character: startCol)
            let endPos = LSPPosition(line: max(startLine, endLine), character: max(endLine > startLine ? 0 : startCol, endCol))
            let selEndPos = LSPPosition(line: max(startLine, selEndLine), character: max(startCol, selEndCol))
            let childSymbols = children.map { $0.toDocumentSymbol() }
            return DocumentSymbol(
                name: name,
                detail: detail,
                kind: kind,
                range: LSPRange(start: startPos, end: endPos),
                selectionRange: LSPRange(start: startPos, end: selEndPos),
                children: childSymbols.isEmpty ? nil : childSymbols
            )
        }
    }

    private static func parseJSONSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var stack: [MutableSymbolNode] = []

        struct PendingKey {
            let name: String
            let line: Int
            let startCol: Int
            let endCol: Int
        }

        var pendingKey: PendingKey?
        var inBlockComment = false

        for (lineIdx, rawLine) in lines.enumerated() {
            let chars = Array(rawLine.utf16)
            let len = chars.count
            var i = 0

            while i < len {
                let c = chars[i]

                if inBlockComment {
                    if c == 0x2A && i + 1 < len && chars[i + 1] == 0x2F {
                        inBlockComment = false
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }

                if c == 0x20 || c == 0x09 || c == 0x0D {
                    i += 1
                    continue
                }

                if c == 0x2F && i + 1 < len {
                    if chars[i + 1] == 0x2F {
                        break
                    } else if chars[i + 1] == 0x2A {
                        inBlockComment = true
                        i += 2
                        continue
                    }
                }

                if c == 0x22 {
                    let strStart = i
                    i += 1
                    var escaped = false
                    while i < len {
                        let sc = chars[i]
                        if escaped {
                            escaped = false
                        } else if sc == 0x5C {
                            escaped = true
                        } else if sc == 0x22 {
                            break
                        }
                        i += 1
                    }
                    let strEnd = min(i, len)
                    if i < len { i += 1 }

                    var look = i
                    while look < len && (chars[look] == 0x20 || chars[look] == 0x09) {
                        look += 1
                    }
                    if look < len && chars[look] == 0x3A {
                        let keySlice = rawLine.utf16.dropFirst(strStart + 1).prefix(max(0, strEnd - strStart - 1))
                        let keyName = String(decoding: keySlice, as: UTF16.self)
                        if !keyName.isEmpty {
                            pendingKey = PendingKey(name: keyName, line: lineIdx, startCol: strStart, endCol: strEnd)
                        }
                        i = look + 1
                        continue
                    } else if let pk = pendingKey {
                        let node = MutableSymbolNode(
                            name: pk.name,
                            kind: 15,
                            startLine: pk.line,
                            startCol: pk.startCol,
                            selEndLine: pk.line,
                            selEndCol: pk.endCol,
                            endLine: lineIdx,
                            endCol: i
                        )
                        appendJSONNode(node, stack: &stack, roots: &roots)
                        pendingKey = nil
                    }
                    continue
                }

                if c == 0x7B {
                    if let pk = pendingKey {
                        let node = MutableSymbolNode(
                            name: pk.name,
                            kind: 19,
                            startLine: pk.line,
                            startCol: pk.startCol,
                            selEndLine: pk.line,
                            selEndCol: pk.endCol,
                            endLine: lineIdx,
                            endCol: i + 1
                        )
                        stack.append(node)
                        pendingKey = nil
                    } else if let parent = stack.last, parent.isArrayContainer {
                        let idx = parent.nextArrayIndex
                        parent.nextArrayIndex += 1
                        let node = MutableSymbolNode(
                            name: "[\(idx)]",
                            kind: 19,
                            startLine: lineIdx,
                            startCol: i,
                            selEndLine: lineIdx,
                            selEndCol: i + 1,
                            endLine: lineIdx,
                            endCol: i + 1
                        )
                        stack.append(node)
                    } else {
                        let rootObj = MutableSymbolNode(
                            name: "{root}",
                            kind: 19,
                            startLine: lineIdx,
                            startCol: i,
                            selEndLine: lineIdx,
                            selEndCol: i + 1,
                            endLine: lineIdx,
                            endCol: i + 1
                        )
                        stack.append(rootObj)
                    }
                    i += 1
                    continue
                }

                if c == 0x5B {
                    if let pk = pendingKey {
                        let node = MutableSymbolNode(
                            name: pk.name,
                            kind: 18,
                            startLine: pk.line,
                            startCol: pk.startCol,
                            selEndLine: pk.line,
                            selEndCol: pk.endCol,
                            endLine: lineIdx,
                            endCol: i + 1,
                            isArrayContainer: true
                        )
                        stack.append(node)
                        pendingKey = nil
                    } else {
                        let rootArr = MutableSymbolNode(
                            name: "[root]",
                            kind: 18,
                            startLine: lineIdx,
                            startCol: i,
                            selEndLine: lineIdx,
                            selEndCol: i + 1,
                            endLine: lineIdx,
                            endCol: i + 1,
                            isArrayContainer: true
                        )
                        stack.append(rootArr)
                    }
                    i += 1
                    continue
                }

                if c == 0x7D || c == 0x5D {
                    pendingKey = nil
                    if let finished = stack.popLast() {
                        finished.endLine = lineIdx
                        finished.endCol = i + 1
                        if finished.name == "{root}" || finished.name == "[root]" {
                            if stack.isEmpty {
                                roots.append(contentsOf: finished.children)
                            } else {
                                stack[stack.count - 1].children.append(contentsOf: finished.children)
                            }
                        } else {
                            appendJSONNode(finished, stack: &stack, roots: &roots)
                        }
                    }
                    i += 1
                    continue
                }

                if c == 0x2C {
                    pendingKey = nil
                    i += 1
                    continue
                }

                let tokStart = i
                while i < len {
                    let tc = chars[i]
                    if tc == 0x2C || tc == 0x7D || tc == 0x5D || tc == 0x20 || tc == 0x09 || tc == 0x0D || tc == 0x2F {
                        break
                    }
                    i += 1
                }
                if let pk = pendingKey, i > tokStart {
                    let first = chars[tokStart]
                    let kind: Int
                    if (first >= 0x30 && first <= 0x39) || first == 0x2D {
                        kind = 16
                    } else if first == 0x74 || first == 0x66 {
                        kind = 17
                    } else {
                        kind = 7
                    }
                    let node = MutableSymbolNode(
                        name: pk.name,
                        kind: kind,
                        startLine: pk.line,
                        startCol: pk.startCol,
                        selEndLine: pk.line,
                        selEndCol: pk.endCol,
                        endLine: lineIdx,
                        endCol: i
                    )
                    appendJSONNode(node, stack: &stack, roots: &roots)
                    pendingKey = nil
                }
                if i == tokStart {
                    i += 1
                }
            }
        }

        let lastLine = max(0, lines.count - 1)
        while let remaining = stack.popLast() {
            remaining.endLine = lastLine
            remaining.endCol = lines[lastLine].utf16.count
            if remaining.name == "{root}" || remaining.name == "[root]" {
                if stack.isEmpty {
                    roots.append(contentsOf: remaining.children)
                } else {
                    stack[stack.count - 1].children.append(contentsOf: remaining.children)
                }
            } else {
                appendJSONNode(remaining, stack: &stack, roots: &roots)
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func appendJSONNode(
        _ node: MutableSymbolNode,
        stack: inout [MutableSymbolNode],
        roots: inout [MutableSymbolNode]
    ) {
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            roots.append(node)
        }
    }

    private static func parseYAMLSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var stack: [MutableSymbolNode] = []
        var blockScalarIndent: Int?
        var lastNonEmptyLine = 0

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" || trimmed == "..." {
                continue
            }

            let indent = yamlLeadingIndent(of: line)
            if let bsIndent = blockScalarIndent {
                if indent > bsIndent {
                    lastNonEmptyLine = lineIdx
                    continue
                } else {
                    blockScalarIndent = nil
                }
            }

            var content = trimmed
            var keyColOffset = indent
            var isListItem = false
            if content.hasPrefix("- ") {
                isListItem = true
                content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                keyColOffset += 2
            }

            guard let (rawKey, rawValue) = splitYAMLKeyValue(content) else {
                lastNonEmptyLine = lineIdx
                continue
            }

            let cleanKey = unquoteYAMLString(rawKey)
            guard !cleanKey.isEmpty else {
                lastNonEmptyLine = lineIdx
                continue
            }

            let valWithoutComment = stripInlineYAMLComment(rawValue).trimmingCharacters(in: .whitespaces)
            if valWithoutComment == "|" || valWithoutComment == "|-" || valWithoutComment == "|+" ||
               valWithoutComment == ">" || valWithoutComment == ">-" || valWithoutComment == ">+" {
                blockScalarIndent = indent
            }

            while let top = stack.last, top.indent >= indent {
                let finished = stack.removeLast()
                finished.endLine = max(finished.startLine, lastNonEmptyLine)
                finished.endCol = lines[finished.endLine].utf16.count
                if let parent = stack.last {
                    parent.children.append(finished)
                } else {
                    roots.append(finished)
                }
            }

            let displayName: String
            let detail: String?
            if isListItem && (cleanKey == "name" || cleanKey == "id" || cleanKey == "service" || cleanKey == "container_name"), !valWithoutComment.isEmpty {
                displayName = unquoteYAMLString(valWithoutComment)
                detail = cleanKey
            } else {
                displayName = cleanKey
                detail = valWithoutComment.isEmpty ? nil : valWithoutComment
            }

            let kind: Int
            if valWithoutComment.isEmpty {
                kind = 19
            } else if valWithoutComment.hasPrefix("[") {
                kind = 18
            } else if ["true", "false", "yes", "no"].contains(valWithoutComment.lowercased()) {
                kind = 17
            } else if Double(valWithoutComment) != nil {
                kind = 16
            } else {
                kind = 7
            }

            let node = MutableSymbolNode(
                name: displayName,
                detail: detail,
                kind: kind,
                startLine: lineIdx,
                startCol: keyColOffset,
                selEndLine: lineIdx,
                selEndCol: keyColOffset + rawKey.utf16.count,
                endLine: lineIdx,
                endCol: line.utf16.count,
                indent: indent
            )
            stack.append(node)
            lastNonEmptyLine = lineIdx
        }

        while let finished = stack.popLast() {
            finished.endLine = max(finished.startLine, lastNonEmptyLine)
            finished.endCol = lines[finished.endLine].utf16.count
            if let parent = stack.last {
                parent.children.append(finished)
            } else {
                roots.append(finished)
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func parseMakefileSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var nodes: [MutableSymbolNode] = []
        var activeTarget: MutableSymbolNode?

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if line.hasPrefix("\t") || line.hasPrefix("  ") {
                if let target = activeTarget {
                    target.endLine = lineIdx
                    target.endCol = line.utf16.count
                }
                continue
            }

            activeTarget = nil

            if let eqRange = line.range(of: #"^([A-Za-z_][A-Za-z0-9_.-]*)\s*(?::=|\?=|\+=|=)"#, options: .regularExpression) {
                let prefix = String(line[eqRange])
                let varName = prefix
                    .replacingOccurrences(of: ":=", with: "")
                    .replacingOccurrences(of: "?=", with: "")
                    .replacingOccurrences(of: "+=", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !varName.isEmpty {
                    let node = MutableSymbolNode(
                        name: varName,
                        detail: "variable",
                        kind: 13,
                        startLine: lineIdx,
                        startCol: 0,
                        selEndLine: lineIdx,
                        selEndCol: varName.utf16.count,
                        endLine: lineIdx,
                        endCol: line.utf16.count
                    )
                    nodes.append(node)
                }
                continue
            }

            if let colonIdx = line.firstIndex(of: ":") {
                let afterColon = line[line.index(after: colonIdx)...]
                if afterColon.first == "=" { continue }
                let targetPart = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                if targetPart.isEmpty || targetPart.contains(" ") || targetPart.contains("$") {
                    continue
                }
                let ignoredPseudoTargets: Set<String> = [".PHONY", ".SUFFIXES", ".DEFAULT", ".PRECIOUS", ".INTERMEDIATE", ".SECONDARY", ".SECONDEXPANSION", ".DELETE_ON_ERROR", ".IGNORE", ".LOW_RESOLUTION_TIME", ".SILENT", ".EXPORT_ALL_VARIABLES", ".NOTPARALLEL", ".ONESHELL", ".POSIX"]
                if ignoredPseudoTargets.contains(targetPart) {
                    continue
                }
                let deps = afterColon.trimmingCharacters(in: .whitespaces)
                let node = MutableSymbolNode(
                    name: targetPart,
                    detail: deps.isEmpty ? "target" : deps,
                    kind: 12,
                    startLine: lineIdx,
                    startCol: 0,
                    selEndLine: lineIdx,
                    selEndCol: targetPart.utf16.count,
                    endLine: lineIdx,
                    endCol: line.utf16.count
                )
                nodes.append(node)
                activeTarget = node
            }
        }

        return nodes.map { $0.toDocumentSymbol() }
    }

    private static func parseDockerfileSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var currentStage: MutableSymbolNode?
        let majorInstructions: Set<String> = ["FROM", "WORKDIR", "ARG", "ENV", "EXPOSE", "COPY", "ADD", "RUN", "ENTRYPOINT", "CMD", "USER", "VOLUME", "HEALTHCHECK", "LABEL"]

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let firstWord = parts.first else { continue }
            let instruction = firstWord.uppercased()
            guard majorInstructions.contains(instruction) else {
                if let stage = currentStage {
                    stage.endLine = lineIdx
                    stage.endCol = line.utf16.count
                }
                continue
            }

            let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

            if instruction == "FROM" {
                var stageName = "FROM \(rest)"
                if let asRange = rest.range(of: #"\s+[Aa][Ss]\s+([A-Za-z0-9_.-]+)"#, options: .regularExpression) {
                    let asClause = String(rest[asRange]).trimmingCharacters(in: .whitespaces)
                    let tokens = asClause.split(whereSeparator: { $0.isWhitespace })
                    if let alias = tokens.last {
                        let baseImage = String(rest[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        stageName = "\(alias) (\(baseImage))"
                    }
                }
                let stageNode = MutableSymbolNode(
                    name: stageName,
                    detail: "stage",
                    kind: 23,
                    startLine: lineIdx,
                    startCol: 0,
                    selEndLine: lineIdx,
                    selEndCol: line.utf16.count,
                    endLine: lineIdx,
                    endCol: line.utf16.count
                )
                roots.append(stageNode)
                currentStage = stageNode
            } else {
                let kind: Int
                switch instruction {
                case "ENV", "ARG": kind = 13
                case "EXPOSE": kind = 16
                case "ENTRYPOINT", "CMD", "RUN": kind = 12
                default: kind = 7
                }
                let summary = rest.count > 48 ? String(rest.prefix(48)) + "…" : rest
                let child = MutableSymbolNode(
                    name: summary.isEmpty ? instruction : "\(instruction) \(summary)",
                    detail: instruction,
                    kind: kind,
                    startLine: lineIdx,
                    startCol: 0,
                    selEndLine: lineIdx,
                    selEndCol: instruction.utf16.count,
                    endLine: lineIdx,
                    endCol: line.utf16.count
                )
                if let stage = currentStage {
                    stage.children.append(child)
                    stage.endLine = lineIdx
                    stage.endCol = line.utf16.count
                } else {
                    roots.append(child)
                }
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func parseEnvOrTOMLSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var currentSection: MutableSymbolNode?

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let sectionName = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                if !sectionName.isEmpty {
                    let section = MutableSymbolNode(
                        name: sectionName,
                        detail: "section",
                        kind: 19,
                        startLine: lineIdx,
                        startCol: 0,
                        selEndLine: lineIdx,
                        selEndCol: line.utf16.count,
                        endLine: lineIdx,
                        endCol: line.utf16.count
                    )
                    roots.append(section)
                    currentSection = section
                }
                continue
            }

            var working = trimmed
            if working.hasPrefix("export ") {
                working = String(working.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }

            let sepIdx = working.firstIndex(of: "=") ?? working.firstIndex(of: ":")
            guard let idx = sepIdx else { continue }
            let key = String(working[..<idx]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }

            let node = MutableSymbolNode(
                name: key,
                kind: 7,
                startLine: lineIdx,
                startCol: 0,
                selEndLine: lineIdx,
                selEndCol: key.utf16.count,
                endLine: lineIdx,
                endCol: line.utf16.count
            )
            if let section = currentSection {
                section.children.append(node)
                section.endLine = lineIdx
                section.endCol = line.utf16.count
            } else {
                roots.append(node)
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func parseSQLSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var nodes: [MutableSymbolNode] = []
        var activeNode: MutableSymbolNode?

        let pattern = #"^(?i)(CREATE\s+(?:OR\s+REPLACE\s+)?(?:TEMP(?:ORARY)?\s+)?(?:UNIQUE\s+)?(?:MATERIALIZED\s+)?(TABLE|INDEX|VIEW|FUNCTION|PROCEDURE|TRIGGER|TYPE|SCHEMA|DATABASE|KEYSPACE)|ALTER\s+(TABLE|VIEW|TYPE|SCHEMA))\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?([A-Za-z0-9_."`\[\]-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }

            let nsLine = trimmed as NSString
            if let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsLine.length)) {
                let kindWordRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                let kindWord = kindWordRange.location != NSNotFound ? nsLine.substring(with: kindWordRange).uppercased() : "TABLE"
                let isAlter = nsLine.substring(with: match.range(at: 1)).uppercased().hasPrefix("ALTER")
                let rawName = nsLine.substring(with: match.range(at: 4))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))

                let lspKind: Int
                switch kindWord {
                case "FUNCTION", "PROCEDURE", "TRIGGER": lspKind = 12
                case "INDEX": lspKind = 7
                default: lspKind = 23
                }

                let displayName = isAlter ? "ALTER \(kindWord) \(rawName)" : "\(rawName) (\(kindWord))"
                let node = MutableSymbolNode(
                    name: displayName,
                    detail: isAlter ? "ALTER \(kindWord)" : "CREATE \(kindWord)",
                    kind: lspKind,
                    startLine: lineIdx,
                    startCol: 0,
                    selEndLine: lineIdx,
                    selEndCol: line.utf16.count,
                    endLine: lineIdx,
                    endCol: line.utf16.count
                )
                nodes.append(node)
                activeNode = node
            } else if let active = activeNode {
                active.endLine = lineIdx
                active.endCol = line.utf16.count
                if trimmed.hasSuffix(";") {
                    activeNode = nil
                }
            }
        }

        return nodes.map { $0.toDocumentSymbol() }
    }

    private static func parseProtoSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var stack: [(depth: Int, node: MutableSymbolNode)] = []
        var braceDepth = 0

        let declPattern = #"^(service|message|enum|rpc)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try? NSRegularExpression(pattern: declPattern)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }

            let codePart = trimmed.components(separatedBy: "//").first ?? trimmed
            let nsCode = codePart as NSString

            if let regex, let match = regex.firstMatch(in: codePart, range: NSRange(location: 0, length: nsCode.length)) {
                let keyword = nsCode.substring(with: match.range(at: 1))
                let name = nsCode.substring(with: match.range(at: 2))
                let kind: Int
                switch keyword {
                case "service": kind = 11
                case "rpc": kind = 6
                case "enum": kind = 10
                default: kind = 23
                }

                let node = MutableSymbolNode(
                    name: name,
                    detail: keyword,
                    kind: kind,
                    startLine: lineIdx,
                    startCol: 0,
                    selEndLine: lineIdx,
                    selEndCol: line.utf16.count,
                    endLine: lineIdx,
                    endCol: line.utf16.count
                )

                if keyword == "rpc" || !codePart.contains("{") || codePart.contains("}") {
                    if let parent = stack.last?.node {
                        parent.children.append(node)
                    } else {
                        roots.append(node)
                    }
                } else {
                    stack.append((depth: braceDepth + 1, node: node))
                }
            }

            for ch in codePart {
                if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    if let top = stack.last, top.depth == braceDepth {
                        let finished = stack.removeLast().node
                        finished.endLine = lineIdx
                        finished.endCol = line.utf16.count
                        if let parent = stack.last?.node {
                            parent.children.append(finished)
                        } else {
                            roots.append(finished)
                        }
                    }
                    braceDepth = max(0, braceDepth - 1)
                }
            }
        }

        let lastLine = max(0, lines.count - 1)
        while let remaining = stack.popLast() {
            remaining.node.endLine = lastLine
            remaining.node.endCol = lines[lastLine].utf16.count
            if let parent = stack.last?.node {
                parent.children.append(remaining.node)
            } else {
                roots.append(remaining.node)
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func parseMarkdownSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var stack: [(level: Int, node: MutableSymbolNode)] = []
        var inFence = false

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || !trimmed.hasPrefix("#") { continue }

            var level = 0
            for ch in trimmed {
                if ch == "#" { level += 1 } else { break }
            }
            guard (1...4).contains(level) else { continue }
            let afterHashes = trimmed.dropFirst(level)
            guard afterHashes.first == " " || afterHashes.first == "\t" else { continue }
            let title = afterHashes.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            while let top = stack.last, top.level >= level {
                let finished = stack.removeLast().node
                finished.endLine = max(finished.startLine, lineIdx - 1)
                finished.endCol = lines[finished.endLine].utf16.count
                if let parent = stack.last?.node {
                    parent.children.append(finished)
                } else {
                    roots.append(finished)
                }
            }

            let node = MutableSymbolNode(
                name: title,
                detail: String(repeating: "#", count: level),
                kind: 15,
                startLine: lineIdx,
                startCol: 0,
                selEndLine: lineIdx,
                selEndCol: line.utf16.count,
                endLine: lineIdx,
                endCol: line.utf16.count
            )
            stack.append((level: level, node: node))
        }

        let lastLine = max(0, lines.count - 1)
        while let remaining = stack.popLast() {
            remaining.node.endLine = max(remaining.node.startLine, lastLine)
            remaining.node.endCol = lines[remaining.node.endLine].utf16.count
            if let parent = stack.last?.node {
                parent.children.append(remaining.node)
            } else {
                roots.append(remaining.node)
            }
        }

        return roots.map { $0.toDocumentSymbol() }
    }

    private static func parseBrunoSymbols(_ text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: .newlines)
        var roots: [MutableSymbolNode] = []
        var activeBlock: MutableSymbolNode?
        var braceDepth = 0

        let brunoBlocks: Set<String> = [
            "meta", "get", "post", "put", "delete", "patch", "options", "head",
            "query", "params:query", "params:path", "headers", "auth", "auth:bearer",
            "auth:basic", "body", "body:json", "body:text", "body:xml",
            "body:form-urlencoded", "body:multipart-form", "vars", "vars:pre-request",
            "vars:post-response", "assert", "script:pre-request", "script:post-response",
            "tests", "docs"
        ]

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if braceDepth == 0, trimmed.hasSuffix("{") {
                let blockName = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                let lower = blockName.lowercased()
                if brunoBlocks.contains(lower) || lower.hasPrefix("body:") || lower.hasPrefix("auth:") || lower.hasPrefix("params:") || lower.hasPrefix("vars:") || lower.hasPrefix("script:") {
                    let kind: Int
                    if ["get", "post", "put", "delete", "patch", "options", "head"].contains(lower) {
                        kind = 12
                    } else if lower == "tests" || lower == "assert" {
                        kind = 6
                    } else {
                        kind = 19
                    }
                    let node = MutableSymbolNode(
                        name: blockName,
                        kind: kind,
                        startLine: lineIdx,
                        startCol: 0,
                        selEndLine: lineIdx,
                        selEndCol: blockName.utf16.count,
                        endLine: lineIdx,
                        endCol: line.utf16.count
                    )
                    activeBlock = node
                    braceDepth = 1
                    continue
                }
            }

            if braceDepth > 0 {
                for ch in trimmed {
                    if ch == "{" { braceDepth += 1 }
                    else if ch == "}" { braceDepth -= 1 }
                }
                if let block = activeBlock {
                    block.endLine = lineIdx
                    block.endCol = line.utf16.count
                    if braceDepth <= 0 {
                        roots.append(block)
                        activeBlock = nil
                        braceDepth = 0
                    } else if braceDepth == 1, let colonIdx = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("//") {
                        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        if !key.isEmpty && !key.contains(" ") {
                            let child = MutableSymbolNode(
                                name: key,
                                detail: val,
                                kind: 7,
                                startLine: lineIdx,
                                startCol: 2,
                                selEndLine: lineIdx,
                                selEndCol: 2 + key.utf16.count,
                                endLine: lineIdx,
                                endCol: line.utf16.count
                            )
                            block.children.append(child)
                        }
                    }
                }
            }
        }

        if let remaining = activeBlock {
            roots.append(remaining)
        }

        return roots.map { $0.toDocumentSymbol() }
    }
}
