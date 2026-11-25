import Foundation

public struct GoModLensDTO: Decodable, Equatable, Sendable {
    public let line: Int
    public let title: String
    public let compactTitle: String?
    public let command: String
    public let arg: String?

    public init(line: Int, title: String, compactTitle: String? = nil, command: String, arg: String? = nil) {
        self.line = line
        self.title = title
        self.compactTitle = compactTitle
        self.command = command
        self.arg = arg
    }
}

public struct GoModDiagnosticDTO: Decodable, Equatable, Sendable {
    public let line: Int
    public let severity: Int
    public let code: String
    public let message: String

    public init(line: Int, severity: Int, code: String, message: String) {
        self.line = line
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct GoModReplaceDTO: Decodable, Equatable, Sendable {
    public let line: Int
    public let oldModule: String
    public let oldVersion: String?
    public let target: String
    public let targetVersion: String?
    public let isLocal: Bool
    public let resolvedTarget: String?
    public let targetExists: Bool?
    public let targetHasGoMod: Bool?
}

public struct GoWorkModuleRefDTO: Decodable, Equatable, Sendable {
    public let line: Int
    public let raw: String?
    public let relPath: String
    public let dir: String
    public let modulePath: String?
    public let goVersion: String?
    public let exists: Bool
    public let hasGoMod: Bool
}

public struct GoWorkReportDTO: Decodable, Equatable, Sendable {
    public let goVersion: String?
    public let goLine: Int?
    public let useLine: Int?
    public let needsSync: Bool
    public let syncReason: String?
    public let highestChildGoVersion: String?
    public let highestChildModule: String?
    public let useModules: [GoWorkModuleRefDTO]
    public let unlistedModules: [GoWorkModuleRefDTO]?
}

public struct GoModRequireDTO: Decodable, Equatable, Sendable {
    public let line: Int
    public let module: String
    public let version: String
    public let indirect: Bool
    public let latest: String?
}

public struct GoModInspectDTO: Decodable, Equatable, Sendable {
    public let modulePath: String?
    public let moduleLine: Int?
    public let goVersion: String?
    public let requires: [GoModRequireDTO]?
    public let replaces: [GoModReplaceDTO]?
    public let diagnostics: [GoModDiagnosticDTO]?
    public let goWork: GoWorkReportDTO?
    public let lenses: [GoModLensDTO]?
    public let updateError: String?
}

public struct ModuleDoctorDiagnosticBucket<Entry: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var workspace: String = ""
    public private(set) var entriesByPath: [String: [Entry]] = [:]

    public init() {}

    public mutating func set(_ entries: [Entry], forPath canonPath: String, activeWorkspace: String) {
        if workspace != activeWorkspace {
            entriesByPath.removeAll()
            workspace = activeWorkspace
        }
        if entries.isEmpty {
            entriesByPath.removeValue(forKey: canonPath)
        } else {
            entriesByPath[canonPath] = entries
        }
    }

    public mutating func syncWorkspaceOnNonDoctorReset(activeWorkspace: String) {
        if workspace != activeWorkspace {
            entriesByPath.removeAll()
            workspace = activeWorkspace
        }
    }

    @discardableResult
    public mutating func release(path: String, canonicalPath: String) -> Bool {
        let removedRaw = entriesByPath.removeValue(forKey: path) != nil
        let removedCanon = canonicalPath != path && entriesByPath.removeValue(forKey: canonicalPath) != nil
        return removedRaw || removedCanon
    }

    public mutating func removeAll() {
        entriesByPath.removeAll()
        workspace = ""
    }
}

public struct GoModWhyStanzaDTO: Decodable, Equatable, Sendable {
    public let header: String
    public let chain: [String]?
    public let note: String?

    public init(header: String, chain: [String]? = nil, note: String? = nil) {
        self.header = header
        self.chain = chain
        self.note = note
    }
}

public struct GoModWhyReplyDTO: Decodable, Equatable, Sendable {
    public let module: String
    public let needed: Bool
    public let summary: String
    public let stanzas: [GoModWhyStanzaDTO]?
    public let raw: String?
    public let error: String?

    public init(module: String, needed: Bool, summary: String, stanzas: [GoModWhyStanzaDTO]? = nil, raw: String? = nil, error: String? = nil) {
        self.module = module
        self.needed = needed
        self.summary = summary
        self.stanzas = stanzas
        self.raw = raw
        self.error = error
    }
}

public struct GoWorkSyncResultDTO: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let output: String?
    public let error: String?
}

public struct GoModReplaceDirective: Equatable, Hashable, Sendable {
    public let line: Int
    public let oldModule: String
    public let oldVersion: String?
    public let target: String
    public let targetVersion: String?
    public let isLocal: Bool

    public init(line: Int, oldModule: String, oldVersion: String?, target: String, targetVersion: String?, isLocal: Bool) {
        self.line = line
        self.oldModule = oldModule
        self.oldVersion = oldVersion
        self.target = target
        self.targetVersion = targetVersion
        self.isLocal = isLocal
    }
}

public struct GoModCommitReplaceSummary: Equatable, Sendable {
    public let path: String
    public let relativePath: String
    public let directives: [GoModReplaceDirective]

    public init(path: String, relativePath: String, directives: [GoModReplaceDirective]) {
        self.path = path
        self.relativePath = relativePath
        self.directives = directives
    }
}

public enum GoModDoctorHelpers {
    public static func localReplaces(in content: String) -> [GoModReplaceDirective] {
        parseAllReplaces(in: content).filter(\.isLocal)
    }

    public static func allReplaces(in content: String) -> [GoModReplaceDirective] {
        parseAllReplaces(in: content)
    }

    public static func removingLocalReplaces(in content: String, matchingLines linesToDrop: Set<Int>? = nil) -> String {
        let usesCRLF = content.contains("\r\n")
        let lineSep = usesCRLF ? "\r\n" : "\n"
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline, rawLines.last == "" {
            rawLines.removeLast()
        }

        let all = parseAllReplaces(in: normalized)
        let targetLines: Set<Int>
        if let linesToDrop {
            targetLines = linesToDrop
        } else {
            targetLines = Set(all.filter(\.isLocal).map(\.line))
        }
        guard !targetLines.isEmpty else { return content }

        var dropIndices = Set<Int>()
        var blockHeader: Int?
        var blockDirectives: [Int] = []
        var blockAllBodyIndices: [Int] = []

        for idx in rawLines.indices {
            let lineNum = idx + 1
            let fields = tokenizeModFields(stripModLineComment(rawLines[idx]))
            if let headerIdx = blockHeader {
                blockAllBodyIndices.append(idx)
                if fields.first == ")" || (fields.first?.hasPrefix(")") ?? false) {
                    let remainingCount = blockDirectives.filter { !targetLines.contains($0 + 1) }.count
                    if remainingCount == 0 && !blockDirectives.isEmpty {
                        dropIndices.insert(headerIdx)
                        for b in blockAllBodyIndices {
                            dropIndices.insert(b)
                        }
                    }
                    blockHeader = nil
                    blockDirectives = []
                    blockAllBodyIndices = []
                    continue
                }
                if !fields.isEmpty {
                    blockDirectives.append(idx)
                    if targetLines.contains(lineNum) {
                        dropIndices.insert(idx)
                    }
                }
                continue
            }

            if fields.count >= 2 && fields[0] == "replace" && fields[1] == "(" {
                blockHeader = idx
                blockDirectives = []
                blockAllBodyIndices = []
                continue
            }
            if fields.first == "replace(" {
                blockHeader = idx
                blockDirectives = []
                blockAllBodyIndices = []
                continue
            }
            if fields.first == "replace" && targetLines.contains(lineNum) {
                dropIndices.insert(idx)
            }
        }

        guard !dropIndices.isEmpty else { return content }

        var kept: [String] = []
        for idx in rawLines.indices {
            if dropIndices.contains(idx) {
                continue
            }
            let line = rawLines[idx]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if kept.isEmpty {
                    continue
                }
                if kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    continue
                }
            }
            kept.append(line)
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            kept.removeLast()
        }
        if kept.isEmpty {
            return ""
        }
        var result = kept.joined(separator: lineSep)
        if hadTrailingNewline {
            result += lineSep
        }
        return result
    }

    public static func updatingGoWorkVersion(in content: String, to rawVersion: String) -> String {
        let cleanVer = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^go", with: "", options: .regularExpression)
        guard !cleanVer.isEmpty else { return content }

        let usesCRLF = content.contains("\r\n")
        let lineSep = usesCRLF ? "\r\n" : "\n"
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var inBlock = false
        for idx in lines.indices {
            let (code, comment) = splitModLineCommentPreserving(lines[idx])
            let fields = tokenizeModFields(code)
            if inBlock {
                if fields.first == ")" || (fields.first?.hasPrefix(")") ?? false) {
                    inBlock = false
                }
                continue
            }
            if (fields.count >= 2 && fields[1] == "(") || (fields.first?.hasSuffix("(") == true) {
                inBlock = true
                continue
            }
            if fields.first == "go" && fields.count >= 2 {
                let updated = "go \(cleanVer)" + (comment.map { " //\($0)" } ?? "")
                lines[idx] = updated
                return formatLines(lines, separator: lineSep, trailingNewline: hadTrailingNewline)
            }
        }

        let insertLine = "go \(cleanVer)"
        if lines.isEmpty {
            return insertLine + lineSep
        }
        var insertAt = 0
        while insertAt < lines.count && lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            insertAt += 1
        }
        lines.insert(insertLine, at: insertAt)
        if insertAt + 1 < lines.count && !lines[insertAt + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: insertAt + 1)
        }
        return formatLines(lines, separator: lineSep, trailingNewline: hadTrailingNewline)
    }

    public static func addingUseModule(in content: String, relPath rawRel: String) -> String {
        let relPath = normalizeUseEntry(rawRel)
        guard !relPath.isEmpty else { return content }

        let usesCRLF = content.contains("\r\n")
        let lineSep = usesCRLF ? "\r\n" : "\n"
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var firstUseBlockClose: Int?
        var firstSingleUseIdx: Int?
        var firstSingleUseEntry: String?
        var inUseBlock = false
        var existingEntries = Set<String>()

        for idx in lines.indices {
            let fields = tokenizeModFields(stripModLineComment(lines[idx]))
            if fields.isEmpty { continue }
            if inUseBlock {
                if fields[0] == ")" || fields[0].hasPrefix(")") {
                    if firstUseBlockClose == nil {
                        firstUseBlockClose = idx
                    }
                    inUseBlock = false
                    continue
                }
                existingEntries.insert(normalizeUseEntry(unquoteToken(fields[0])))
                continue
            }
            if (fields.count >= 2 && fields[0] == "use" && fields[1] == "(") || fields.first == "use(" {
                inUseBlock = true
                continue
            }
            if fields[0] == "use" && fields.count >= 2 {
                let entry = normalizeUseEntry(unquoteToken(fields[1]))
                existingEntries.insert(entry)
                if firstSingleUseIdx == nil {
                    firstSingleUseIdx = idx
                    firstSingleUseEntry = formatUseToken(unquoteToken(fields[1]))
                }
            }
        }

        if existingEntries.contains(relPath) {
            return content
        }

        let formattedToken = formatUseToken(relPath)
        if let closeIdx = firstUseBlockClose {
            lines.insert("\t\(formattedToken)", at: closeIdx)
        } else if let singleIdx = firstSingleUseIdx, let existingTok = firstSingleUseEntry {
            lines[singleIdx] = "use (\(lineSep)\t\(existingTok)\(lineSep)\t\(formattedToken)\(lineSep))"
        } else {
            if !lines.isEmpty && !lines[lines.count - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("use \(formattedToken)")
        }

        return formatLines(lines, separator: lineSep, trailingNewline: true)
    }

    public static func removingUseModule(in content: String, rawEntry: String) -> String {
        let target = normalizeUseEntry(rawEntry)
        guard !target.isEmpty else { return content }

        let usesCRLF = content.contains("\r\n")
        let lineSep = usesCRLF ? "\r\n" : "\n"
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        let rawLines = normalized.components(separatedBy: "\n")
        var lines = rawLines
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var dropIndices = Set<Int>()
        var blockHeader: Int?
        var blockEntries: [Int] = []
        var blockBody: [Int] = []

        for idx in lines.indices {
            let fields = tokenizeModFields(stripModLineComment(lines[idx]))
            if let headerIdx = blockHeader {
                blockBody.append(idx)
                if fields.first == ")" || (fields.first?.hasPrefix(")") ?? false) {
                    let remaining = blockEntries.filter { !dropIndices.contains($0) }
                    if remaining.isEmpty && !blockEntries.isEmpty {
                        dropIndices.insert(headerIdx)
                        for b in blockBody { dropIndices.insert(b) }
                    }
                    blockHeader = nil
                    blockEntries = []
                    blockBody = []
                    continue
                }
                if !fields.isEmpty {
                    blockEntries.append(idx)
                    let val = unquoteToken(fields[0])
                    if val == rawEntry || normalizeUseEntry(val) == target {
                        dropIndices.insert(idx)
                    }
                }
                continue
            }
            if (fields.count >= 2 && fields[0] == "use" && fields[1] == "(") || fields.first == "use(" {
                blockHeader = idx
                blockEntries = []
                blockBody = []
                continue
            }
            if fields.first == "use" && fields.count >= 2 {
                let val = unquoteToken(fields[1])
                if val == rawEntry || normalizeUseEntry(val) == target {
                    dropIndices.insert(idx)
                }
            }
        }

        guard !dropIndices.isEmpty else { return content }
        var kept: [String] = []
        for idx in lines.indices where !dropIndices.contains(idx) {
            if lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                if kept.isEmpty || kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    continue
                }
            }
            kept.append(lines[idx])
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            kept.removeLast()
        }
        if kept.isEmpty { return "" }
        return formatLines(kept, separator: lineSep, trailingNewline: hadTrailingNewline)
    }

    public static func formatGoModWhyMarkdown(module: String, reply: GoModWhyReplyDTO) -> String {
        let sig = "```go\nmodule \(module)\n```"
        if let err = reply.error, !err.isEmpty {
            return "\(sig)\n\n### Unable to Trace Dependency\n\n\(err)"
        }
        if !reply.needed {
            let reason = reply.summary.isEmpty
                ? "The main module does not import any package from \(module)."
                : reply.summary
            return "\(sig)\n\n### Not Used in Build Graph\n\n\(reason)\n\nConsider running **Run go mod tidy** if this dependency is unused."
        }
        var sections: [String] = [sig, "### Dependency Chain"]
        let stanzas = reply.stanzas ?? []
        for stanza in stanzas {
            let chain = stanza.chain ?? []
            if !chain.isEmpty {
                if stanzas.count > 1 && !stanza.header.isEmpty {
                    sections.append("**\(stanza.header)**")
                }
                sections.append("- " + chain.map { "`\($0)`" }.joined(separator: " -> "))
            } else if let note = stanza.note, !note.isEmpty {
                sections.append("- \(note)")
            }
        }
        if sections.count == 2 && !reply.summary.isEmpty {
            sections.append("- \(reply.summary)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func parseAllReplaces(in content: String) -> [GoModReplaceDirective] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [GoModReplaceDirective] = []
        var inReplaceBlock = false

        for (idx, rawLine) in lines.enumerated() {
            let lineNum = idx + 1
            let fields = tokenizeModFields(stripModLineComment(rawLine))
            if fields.isEmpty { continue }

            if inReplaceBlock {
                if fields[0] == ")" || fields[0].hasPrefix(")") {
                    inReplaceBlock = false
                    continue
                }
                if let rep = parseReplaceTokens(fields, lineNum: lineNum) {
                    result.append(rep)
                }
                continue
            }

            if (fields.count >= 2 && fields[0] == "replace" && fields[1] == "(") || fields[0] == "replace(" {
                inReplaceBlock = true
                continue
            }
            if fields[0] == "replace" && fields.count >= 4 {
                if let rep = parseReplaceTokens(Array(fields.dropFirst()), lineNum: lineNum) {
                    result.append(rep)
                }
            }
        }
        return result
    }

    private static func parseReplaceTokens(_ tokens: [String], lineNum: Int) -> GoModReplaceDirective? {
        guard let arrowIdx = tokens.firstIndex(of: "=>"), arrowIdx > 0, arrowIdx + 1 < tokens.count else {
            return nil
        }
        let oldMod = unquoteToken(tokens[0])
        let oldVer: String? = arrowIdx >= 2 ? tokens[1] : nil
        let right = Array(tokens[(arrowIdx + 1)...])
        let target = unquoteToken(right[0])
        let targetVer: String? = right.count >= 2 ? right[1] : nil
        let isLocal = right.count == 1
            || target.hasPrefix("./")
            || target.hasPrefix("../")
            || target.hasPrefix("/")
            || target == "."
            || target == ".."
            || !target.contains(".")

        return GoModReplaceDirective(
            line: lineNum,
            oldModule: oldMod,
            oldVersion: oldVer,
            target: target,
            targetVersion: targetVer,
            isLocal: isLocal
        )
    }

    private static func formatLines(_ lines: [String], separator: String, trailingNewline: Bool) -> String {
        var joined = lines.joined(separator: separator)
        if trailingNewline && !joined.hasSuffix(separator) {
            joined += separator
        }
        return joined
    }

    private static func normalizeUseEntry(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "." { return "." }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return trimmed
        }
        return "./" + trimmed
    }

    private static func formatUseToken(_ raw: String) -> String {
        if raw.contains(" ") || raw.contains("\t") {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return raw
    }

    private static func stripModLineComment(_ line: String) -> String {
        splitModLineCommentPreserving(line).code
    }

    private static func splitModLineCommentPreserving(_ line: String) -> (code: String, comment: String?) {
        let chars = Array(line)
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\" && q == "\"" && i + 1 < chars.count {
                    i += 2
                    continue
                }
                if c == q {
                    quote = nil
                }
                i += 1
                continue
            }
            if c == "\"" || c == "`" {
                quote = c
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                let code = String(chars[..<i])
                let comment = String(chars[(i + 2)...])
                return (code, comment)
            }
            i += 1
        }
        return (line, nil)
    }

    private static func tokenizeModFields(_ text: String) -> [String] {
        let chars = Array(text)
        var fields: [String] = []
        var i = 0
        let n = chars.count
        while i < n {
            while i < n && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\r") {
                i += 1
            }
            if i >= n { break }
            if chars[i] == "\"" || chars[i] == "`" {
                let q = chars[i]
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" && q == "\"" && i + 1 < n {
                        i += 2
                        continue
                    }
                    if chars[i] == q {
                        i += 1
                        break
                    }
                    i += 1
                }
                fields.append(String(chars[start..<i]))
                continue
            }
            let start = i
            while i < n && chars[i] != " " && chars[i] != "\t" && chars[i] != "\r" {
                i += 1
            }
            fields.append(String(chars[start..<i]))
        }
        return fields
    }

    private static func unquoteToken(_ tok: String) -> String {
        guard tok.count >= 2 else { return tok }
        if tok.hasPrefix("\"") && tok.hasSuffix("\"") {
            return String(tok.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        if tok.hasPrefix("`") && tok.hasSuffix("`") {
            return String(tok.dropFirst().dropLast())
        }
        return tok
    }
}
