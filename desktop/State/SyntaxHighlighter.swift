import Foundation
import AppKit
import SwiftTreeSitter
import TreeSitterGo

final class SyntaxHighlighter {
    static let goModuleVersionPattern = "\\bv\\d+\\.\\d+\\.\\d+[0-9A-Za-z.+-]*|\\b(?:go)?\\d+\\.\\d+(?:\\.\\d+)?(?:(?:rc|beta)\\d+)?\\b"
    static let goBuiltins: Set<String> = ["append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make", "max", "min", "new", "panic", "print", "println", "real", "recover"]
    static let dockerKeywords: Set<String> = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"]
    private static let nonTimeFormatReceivers: Set<String> = ["fmt", "log", "strings", "errors"]
    private static let regexpFunctions: Set<String> = ["Compile", "MustCompile", "CompilePOSIX", "MustCompilePOSIX", "MatchString", "Match", "MatchReader"]
    private static let timeZoneTokens: [[unichar]] = [
        Array("Z07:00:00".utf16), Array("-07:00:00".utf16),
        Array("Z070000".utf16), Array("-070000".utf16),
        Array("Z07:00".utf16), Array("-07:00".utf16),
        Array("Z0700".utf16), Array("-0700".utf16),
        Array("Z07".utf16), Array("-07".utf16),
    ]
    private static let timeWordTokens: [[unichar]] = [
        Array("January".utf16), Array("Monday".utf16),
        Array("Jan".utf16), Array("Mon".utf16),
        Array("MST".utf16), Array("PM".utf16), Array("pm".utf16),
    ]
    private static let timeNumberTokens: [[unichar]] = [
        Array(".000000000".utf16), Array(".999999999".utf16),
        Array(",000000000".utf16), Array(",999999999".utf16),
        Array(".000000".utf16), Array(".999999".utf16),
        Array(",000000".utf16), Array(",999999".utf16),
        Array(".000".utf16), Array(".999".utf16),
        Array(",000".utf16), Array(",999".utf16),
        Array("2006".utf16), Array("002".utf16), Array("__2".utf16),
        Array("_2".utf16), Array("01".utf16), Array("02".utf16),
        Array("03".utf16), Array("04".utf16), Array("05".utf16),
        Array("06".utf16), Array("15".utf16),
    ]
    private static let readChunk = 16384
    static let sqlKeywordPattern = "(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|INDEX|VIEW|TRIGGER|FUNCTION|PROCEDURE|ALTER|DROP|TRUNCATE|JOIN|INNER|LEFT|RIGHT|FULL|OUTER|CROSS|ON|AS|AND|OR|NOT|IN|EXISTS|BETWEEN|LIKE|ILIKE|IS|NULL|TRUE|FALSE|PRIMARY|FOREIGN|KEY|REFERENCES|UNIQUE|CHECK|DEFAULT|AUTO_INCREMENT|SERIAL|BIGSERIAL|GROUP|BY|ORDER|ASC|DESC|HAVING|LIMIT|OFFSET|FETCH|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END|CAST|COALESCE|NULLIF|WITH|RECURSIVE|RETURNING|CONFLICT|DO|NOTHING|BEGIN|COMMIT|ROLLBACK|TRANSACTION|GRANT|REVOKE|EXPLAIN|ANALYZE|KEYSPACE|MATERIALIZED)\\b"
    static let sqlTypePattern = "(?i)\\b(INT|INTEGER|BIGINT|SMALLINT|TINYINT|DECIMAL|NUMERIC|REAL|FLOAT|DOUBLE|BOOLEAN|BOOL|CHAR|VARCHAR|TEXT|UUID|JSON|JSONB|BYTEA|BLOB|DATE|TIME|TIMESTAMP|TIMESTAMPTZ|INTERVAL|INET|CIDR)\\b"
    private static let injectedSQLRules: [(NSRegularExpression, Category)] = [
        (sqlKeywordPattern, .keyword), (sqlTypePattern, .type), ("\\b\\d+(?:\\.\\d+)?\\b", .number), ("'(?:''|[^'])*'", .string), ("--[^\\n]*", .comment),
    ].compactMap { pattern, category in (try? NSRegularExpression(pattern: pattern)).map { ($0, category) } }

    private let parser = Parser()
    private var tree: MutableTree?
    private var needsParse = true
    private let lastPath: String
    private let isGo: Bool
    private var text: NSString = ""
    private(set) var injectedSQL: [[NSRange]] = []

    init(path: String) {
        lastPath = path
        isGo = (path as NSString).pathExtension.lowercased() == "go"
        if isGo, let lang = tree_sitter_go() {
            try? parser.setLanguage(Language(language: lang))
        }
    }

    func noteEdit(_ edit: InputEdit) {
        tree?.edit(edit)
        needsParse = true
        if !injectedSQL.isEmpty {
            shiftInjectedSQL(start: Int(edit.startByte) / 2, oldEnd: Int(edit.oldEndByte) / 2, newEnd: Int(edit.newEndByte) / 2)
        }
    }

    func setInjectedSQL(_ sites: [[NSRange]]) {
        injectedSQL = sites
    }

    func injectedSQLPart(at location: Int) -> (site: Int, part: Int)? {
        for (s, parts) in injectedSQL.enumerated() {
            for (p, r) in parts.enumerated() where location >= r.location && location <= NSMaxRange(r) {
                return (s, p)
            }
        }
        return nil
    }

    private func shiftInjectedSQL(start: Int, oldEnd: Int, newEnd: Int) {
        let delta = newEnd - oldEnd
        injectedSQL = injectedSQL.map { parts in
            parts.map { r in
                let lo = r.location, hi = NSMaxRange(r)
                let newLo = max(0, lo <= start ? lo : lo + delta)
                let newHi = max(newLo, hi < start ? hi : hi + delta)
                return NSRange(location: newLo, length: newHi - newLo)
            }
        }
    }

    func injectedSQLAttributes(in ns: NSString, theme: Theme, isDark: Bool, target: NSRange) -> [(NSRange, NSColor)] {
        guard !injectedSQL.isEmpty else { return [] }
        var out: [(NSRange, NSColor)] = []
        for parts in injectedSQL {
            for r in parts where NSMaxRange(r) <= ns.length && NSIntersectionRange(r, target).length > 0 {
                let piece = ns.substring(with: r)
                let whole = NSRange(location: 0, length: (piece as NSString).length)
                out.append((r, theme.textColor(isDark: isDark)))
                for (regex, category) in Self.injectedSQLRules {
                    let color: NSColor
                    switch category {
                    case .keyword: color = theme.keywordColor(isDark: isDark)
                    case .type: color = theme.typeColor(isDark: isDark)
                    case .number: color = theme.numberColor(isDark: isDark)
                    case .string: color = theme.stringColor(isDark: isDark)
                    default: color = theme.commentColor(isDark: isDark)
                    }
                    for match in regex.matches(in: piece, range: whole) {
                        out.append((NSRange(location: r.location + match.range.location, length: match.range.length), color))
                    }
                }
            }
        }
        return out
    }

    private func reparse(_ ns: NSString) {
        let length = ns.length
        var buffer = [unichar](repeating: 0, count: Self.readChunk)
        tree = parser.parse(tree: tree) { byteIndex, _ in
            let unit = byteIndex / 2
            guard unit < length else { return nil }
            let n = min(Self.readChunk, length - unit)
            return buffer.withUnsafeMutableBufferPointer { buf in
                ns.getCharacters(buf.baseAddress!, range: NSRange(location: unit, length: n))
                return Data(bytes: buf.baseAddress!, count: n * 2)
            }
        }
        needsParse = false
    }

    func inCommentOrString(at location: Int, in ns: NSString) -> Bool? {
        guard isGo else { return nil }
        if needsParse || tree == nil { reparse(ns) }
        guard let root = tree?.rootNode else { return nil }
        var probe = min(location, ns.length)
        while probe > 0, ns.character(at: probe - 1) == 0x20 || ns.character(at: probe - 1) == 0x09 { probe -= 1 }
        let b = UInt32(probe * 2)
        var node = root.descendant(in: b..<b)
        while let n = node {
            let r = n.byteRange
            switch n.nodeType {
            case "ERROR":
                return nil
            case "comment":
                let start = Int(r.lowerBound) / 2
                let isLine = start + 1 < ns.length && ns.character(at: start + 1) == 0x2F
                return b > r.lowerBound && (isLine ? b <= r.upperBound : b < r.upperBound)
            case "interpreted_string_literal", "raw_string_literal", "rune_literal":
                if b > r.lowerBound && b < r.upperBound { return true }
            default:
                break
            }
            node = n.parent
        }
        return false
    }

    func attributes(for storage: NSTextStorage, isDark: Bool, theme: Theme, in targetRange: NSRange) -> [(NSRange, NSColor)] {
        let text: NSString = storage.mutableString
        self.text = text
        defer { self.text = "" }
        if isGo && (needsParse || tree == nil) {
            reparse(text)
        }
        let targetByteRange = UInt32(targetRange.location * 2)..<UInt32(NSMaxRange(targetRange) * 2)

        guard let tree = self.tree, let rootNode = tree.rootNode else {
            var fallbackAttributes: [(NSRange, NSColor)] = []
            var covered = IndexSet()
            let source = text as String
            func claim(_ range: NSRange, _ color: NSColor) {
                fallbackAttributes.append((range, color))
                if range.location != NSNotFound, range.length > 0 {
                    covered.insert(integersIn: range.location..<NSMaxRange(range))
                }
            }
            let ext = (self.lastPath as NSString).pathExtension.lowercased()
            let filename = (self.lastPath as NSString).lastPathComponent.lowercased()

            func addUnclaimedMatches(
                _ pattern: String,
                options: NSRegularExpression.Options = [],
                group: Int = 0,
                color: NSColor
            ) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                for match in regex.matches(in: source, range: targetRange) {
                    guard group < match.numberOfRanges else { continue }
                    let matchRange = match.range(at: group)
                    guard matchRange.location != NSNotFound, matchRange.length > 0 else { continue }
                    if !covered.intersects(integersIn: matchRange.location..<NSMaxRange(matchRange)) {
                        claim(matchRange, color)
                    }
                }
            }

            let isMarkdown = (ext == "md" || ext == "markdown")
            let isHTMLOrXML = ["html", "tmpl", "gotmpl", "xml", "svg"].contains(ext)
            let isSQL = (ext == "sql" || ext == "cql")
            let isShell = ["sh", "bash", "zsh"].contains(ext)
            let isEnvOrConfig = ["env", "local", "beta", "properties", "toml", "ini"].contains(ext) || filename.hasPrefix(".env")
            let isGoModuleFile = ["go.mod", "go.work", "go.sum", "go.work.sum"].contains(filename)

            if isMarkdown {
                addUnclaimedMatches("<!--[\\s\\S]*?-->", color: theme.commentColor(isDark: isDark))
                addUnclaimedMatches("^#{1,6}\\s+.*$", options: .anchorsMatchLines, color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("`[^`\\n]+`|\\[[^\\]]+\\]\\([^)]+\\)", color: theme.typeColor(isDark: isDark))
                return fallbackAttributes
            }

            if ext == "http" || ext == "rest" {
                addUnclaimedMatches("^###.*$", options: .anchorsMatchLines, color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("^[ \\t]*(?:#|//).*$", options: .anchorsMatchLines, color: theme.commentColor(isDark: isDark))
                addUnclaimedMatches("\\{\\{[^{}\\n]*\\}\\}", color: theme.builtinColor(isDark: isDark))
                addUnclaimedMatches(
                    "^[ \\t]*(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|TRACE|CONNECT|GRPC)(?=[ \\t])",
                    options: .anchorsMatchLines,
                    group: 1,
                    color: theme.keywordColor(isDark: isDark)
                )
                addUnclaimedMatches("\\bHTTP/[0-9.]+\\b", color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("^[ \\t]*(@[A-Za-z_][A-Za-z0-9_.-]*)[ \\t]*=", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
                addUnclaimedMatches("^([A-Za-z0-9!#$%&'*+.^_`|~-]+):(?=[ \\t])", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
                addUnclaimedMatches("^[ \\t]*(?:>[ \\t]*\\{%|%\\}|<@|<(?=[ \\t])|>>!?|>(?=[ \\t]))", options: .anchorsMatchLines, color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'", color: theme.stringColor(isDark: isDark))
                addUnclaimedMatches("\\b-?\\d+(?:\\.\\d+)?\\b", color: theme.numberColor(isDark: isDark))
                addUnclaimedMatches("\\b(true|false|null|function|var|let|const|return|if|else)\\b", color: theme.keywordColor(isDark: isDark))
                return fallbackAttributes
            }

            if isHTMLOrXML {
                addUnclaimedMatches("<!--[\\s\\S]*?-->|\\{\\{/\\*[\\s\\S]*?\\*/\\}\\}", color: theme.commentColor(isDark: isDark))
                addUnclaimedMatches("\"(?:\\\\.|[^\"])*\"|'(?:\\\\.|[^'])*'", color: theme.stringColor(isDark: isDark))
                addUnclaimedMatches("\\{\\{-?|-?\\}\\}|\\b(define|template|block|range|with|end|if|else)\\b", color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("</?[A-Za-z][A-Za-z0-9:-]*|/?>", color: theme.typeColor(isDark: isDark))
                return fallbackAttributes
            }

            if let regex = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"])*\"|'(?:\\\\.|[^'])*'|`(?:[^`])*`", options: []) {
                for match in regex.matches(in: source, range: targetRange) {
                    claim(match.range, theme.stringColor(isDark: isDark))
                }
            }

            let commentPattern: String
            if isSQL {
                commentPattern = "--.*|/\\*[\\s\\S]*?\\*/|#.*"
            } else {
                commentPattern = "//.*|/\\*[\\s\\S]*?\\*/|#.*"
            }
            if let regex = try? NSRegularExpression(pattern: commentPattern, options: []) {
                for match in regex.matches(in: source, range: targetRange) {
                    claim(match.range, theme.commentColor(isDark: isDark))
                }
            }

            let numPattern = isGoModuleFile ? SyntaxHighlighter.goModuleVersionPattern : "\\b\\d+(?:\\.\\d+)?\\b"
            addUnclaimedMatches(numPattern, color: theme.numberColor(isDark: isDark))

            var keywordsPattern = ""
            if isGoModuleFile {
                keywordsPattern = "(?m)^(module|go|toolchain|godebug|require|replace|exclude|retract|use)(?=[ \\t(]|$)"
            } else if ext == "go" {
                keywordsPattern = "\\b(break|default|func|interface|select|case|defer|go|map|struct|chan|else|goto|package|switch|const|fallthrough|if|range|type|continue|for|import|return|var)\\b"
            } else if filename == "dockerfile" || ext == "dockerfile" || filename.hasPrefix("dockerfile.") {
                keywordsPattern = "\\b(FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\\b"
            } else if ext == "json" || ext == "jsonc" || ext == "yml" || ext == "yaml" {
                keywordsPattern = "\\b(true|false|null)\\b"
                addUnclaimedMatches("^\\s*(?:-\\s+)?[\"']?([\\w.-]+)[\"']?\\s*:", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
            } else if filename == "makefile" || filename == "gnumakefile" || ext == "mk" {
                addUnclaimedMatches("^([^:\\s]+):", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
            } else if isSQL {
                keywordsPattern = Self.sqlKeywordPattern
                addUnclaimedMatches(Self.sqlTypePattern, color: theme.typeColor(isDark: isDark))
            } else if isShell {
                keywordsPattern = "\\b(if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|exit|local|export|readonly|declare|typeset|set|unset|shift|source|trap|wait|break|continue)\\b"
                addUnclaimedMatches(
                    "\\b(echo|printf|read|cd|pwd|test|eval|exec|ulimit|umask|kill|sleep)\\b",
                    color: theme.builtinColor(isDark: isDark)
                )
                addUnclaimedMatches(
                    "\\$(?:\\{[^}]+\\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@#?$!*_-])",
                    color: theme.typeColor(isDark: isDark)
                )
            } else if isEnvOrConfig {
                addUnclaimedMatches("^\\s*\\[[^\\]]+\\]", options: .anchorsMatchLines, color: theme.keywordColor(isDark: isDark))
                addUnclaimedMatches("^\\s*(?:export\\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\\s*=", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
                keywordsPattern = "\\b(true|false|yes|no|on|off)\\b"
            } else if ext == "proto" {
                keywordsPattern = "\\b(syntax|package|import|public|weak|option|message|enum|service|rpc|returns|stream|oneof|repeated|optional|required|map|reserved|extensions|extend|to|max)\\b"
                addUnclaimedMatches(
                    "\\b(double|float|int32|int64|uint32|uint64|sint32|sint64|fixed32|fixed64|sfixed32|sfixed64|bool|string|bytes)\\b",
                    color: theme.typeColor(isDark: isDark)
                )
            } else if ext == "bru" {
                addUnclaimedMatches(
                    "^(meta|get|post|put|delete|patch|options|head|headers|body|body:[a-z-]+|auth|auth:[a-z-]+|vars|vars:[a-z-]+|assert|script:[a-z-]+|tests|docs)\\b",
                    options: .anchorsMatchLines,
                    color: theme.keywordColor(isDark: isDark)
                )
                addUnclaimedMatches("^\\s*([A-Za-z_][A-Za-z0-9_.-]*)\\s*:", options: .anchorsMatchLines, group: 1, color: theme.typeColor(isDark: isDark))
            }

            if !keywordsPattern.isEmpty {
                addUnclaimedMatches(keywordsPattern, color: theme.keywordColor(isDark: isDark))
            }

            return fallbackAttributes
        }

        var colors: [Category: NSColor] = [
            .keyword: theme.keywordColor(isDark: isDark),
            .string: theme.stringColor(isDark: isDark),
            .comment: theme.commentColor(isDark: isDark),
            .number: theme.numberColor(isDark: isDark),
            .type: theme.typeColor(isDark: isDark),
        ]
        let builtinColor = theme.builtinColor(isDark: isDark)
        var attributes: [(NSRange, NSColor)] = []
        let cursor = rootNode.treeCursor
        let lower = targetByteRange.lowerBound
        let upper = targetByteRange.upperBound

        func visit() {
            repeat {
                guard let node = cursor.currentNode else { return }
                let r = node.byteRange
                if r.lowerBound >= upper { return }
                guard r.upperBound > lower else { continue }
                let category = self.category(of: node)
                var color = colors[category]
                if category == .identifier, r.upperBound - r.lowerBound <= 14, Self.goBuiltins.contains(textSubstring(for: node)) {
                    color = builtinColor
                }
                if let color {
                    attributes.append((NSRange(location: Int(r.lowerBound) / 2, length: Int(r.upperBound - r.lowerBound) / 2), color))
                }
                if category != .comment && category != .string && cursor.goToFirstChild(for: lower) {
                    visit()
                    _ = cursor.gotoParent()
                }
                if category == .call {
                    highlightCallStringLiterals(
                        of: node,
                        lower: lower,
                        upper: upper,
                        keywordColor: colors[.keyword]!,
                        numberColor: colors[.number]!,
                        typeColor: colors[.type]!,
                        builtinColor: builtinColor,
                        into: &attributes
                    )
                }
            } while cursor.gotoNextSibling()
        }
        if cursor.goToFirstChild(for: lower) {
            visit()
        }
        colors.removeAll()
        return attributes
    }

    enum Category {
        case none, keyword, string, comment, number, type, identifier, call
    }

    private enum StringTokenKind {
        case timeLayout
        case regex
    }

    private var categories: [Int: Category] = [:]

    private func category(of node: Node) -> Category {
        let symbol = node.symbol
        if let cached = categories[symbol] { return cached }
        let category: Category
        switch node.nodeType ?? "" {
        case "comment": category = .comment
        case "interpreted_string_literal", "raw_string_literal", "rune_literal": category = .string
        case "int_literal", "float_literal", "imaginary_literal": category = .number
        case "type_identifier": category = .type
        case "identifier": category = .identifier
        case "call_expression": category = .call
        case "true", "false", "nil", "iota": category = .keyword
        default:
            let t = node.nodeType ?? ""
            category = !node.isNamed && t.first.map({ $0.isLetter }) == true ? .keyword : .none
        }
        categories[symbol] = category
        return category
    }

    private func highlightCallStringLiterals(
        of callNode: Node,
        lower: UInt32,
        upper: UInt32,
        keywordColor: NSColor,
        numberColor: NSColor,
        typeColor: NSColor,
        builtinColor: NSColor,
        into attributes: inout [(NSRange, NSColor)]
    ) {
        guard let fnNode = callNode.child(byFieldName: "function") ?? callNode.namedChild(at: 0),
              fnNode.nodeType == "selector_expression",
              let argsNode = callNode.child(byFieldName: "arguments") ?? callNode.namedChild(at: 1),
              argsNode.nodeType == "argument_list",
              let operandNode = fnNode.child(byFieldName: "operand") ?? fnNode.namedChild(at: 0),
              let fieldNode = fnNode.child(byFieldName: "field") ?? fnNode.namedChild(at: 1)
        else { return }

        let fieldName = textSubstring(for: fieldNode)
        guard !fieldName.isEmpty else { return }

        var argNodes: [Node] = []
        let childCount = argsNode.namedChildCount
        for idx in 0..<childCount {
            if let child = argsNode.namedChild(at: idx), child.nodeType != "comment" {
                argNodes.append(child)
            }
        }
        guard !argNodes.isEmpty else { return }

        let kind: StringTokenKind
        let argIndex: Int
        if fieldName == "Parse" || fieldName == "ParseInLocation" {
            guard textSubstring(for: operandNode) == "time" else { return }
            kind = .timeLayout
            argIndex = 0
        } else if fieldName == "Format" {
            let recv = textSubstring(for: operandNode)
            guard !Self.nonTimeFormatReceivers.contains(recv) else { return }
            if argNodes.count == 1 {
                kind = .timeLayout
                argIndex = 0
            } else if argNodes.count == 2 && recv == "time.Time" {
                kind = .timeLayout
                argIndex = 1
            } else {
                return
            }
        } else if fieldName == "AppendFormat" {
            let recv = textSubstring(for: operandNode)
            guard !Self.nonTimeFormatReceivers.contains(recv), argNodes.count == 2 else { return }
            kind = .timeLayout
            argIndex = 1
        } else if Self.regexpFunctions.contains(fieldName) {
            guard textSubstring(for: operandNode) == "regexp" else { return }
            kind = .regex
            argIndex = 0
        } else {
            return
        }

        guard argIndex < argNodes.count else { return }
        var targetArg = argNodes[argIndex]
        while targetArg.nodeType == "parenthesized_expression", let inner = targetArg.namedChild(at: 0) {
            targetArg = inner
        }
        let argType = targetArg.nodeType ?? ""
        guard argType == "interpreted_string_literal" || argType == "raw_string_literal" else { return }
        let r = targetArg.byteRange
        guard r.lowerBound < upper && r.upperBound > lower else { return }

        let start = Int(r.lowerBound) / 2
        let end = Int(r.upperBound) / 2
        let length = end - start
        guard length >= 2, length <= 2048, end <= text.length else { return }

        let isRaw = argType == "raw_string_literal"
        let quoteChar = text.character(at: start)
        let innerStart = start + 1
        let innerEnd = (end > innerStart && text.character(at: end - 1) == quoteChar) ? (end - 1) : end
        let innerLen = innerEnd - innerStart
        guard innerLen > 0 else { return }

        let chars = [unichar](unsafeUninitializedCapacity: innerLen) { buf, initializedCount in
            text.getCharacters(buf.baseAddress!, range: NSRange(location: innerStart, length: innerLen))
            initializedCount = innerLen
        }

        switch kind {
        case .timeLayout:
            scanTimeLayoutTokens(
                chars,
                baseOffset: innerStart,
                isRaw: isRaw,
                keywordColor: keywordColor,
                numberColor: numberColor,
                builtinColor: builtinColor,
                into: &attributes
            )
        case .regex:
            scanRegexTokens(
                chars,
                baseOffset: innerStart,
                isRaw: isRaw,
                keywordColor: keywordColor,
                numberColor: numberColor,
                typeColor: typeColor,
                builtinColor: builtinColor,
                into: &attributes
            )
        }
    }

    private func scanTimeLayoutTokens(
        _ chars: [unichar],
        baseOffset: Int,
        isRaw: Bool,
        keywordColor: NSColor,
        numberColor: NSColor,
        builtinColor: NSColor,
        into attributes: inout [(NSRange, NSColor)]
    ) {
        let n = chars.count
        var i = 0
        while i < n {
            if !isRaw && chars[i] == 0x5C {
                let escLen = min(2, n - i)
                attributes.append((NSRange(location: baseOffset + i, length: escLen), keywordColor))
                i += escLen
                continue
            }

            if let len = Self.matchPrefix(in: chars, at: i, candidates: Self.timeZoneTokens) {
                attributes.append((NSRange(location: baseOffset + i, length: len), builtinColor))
                i += len
                continue
            }

            let prevIsLetter = i > 0 && Self.isASCIILetter(chars[i - 1])
            if !prevIsLetter, let len = Self.matchPrefix(in: chars, at: i, candidates: Self.timeWordTokens) {
                let nextIdx = i + len
                if nextIdx >= n || !Self.isASCIILetter(chars[nextIdx]) {
                    attributes.append((NSRange(location: baseOffset + i, length: len), keywordColor))
                    i = nextIdx
                    continue
                }
            }

            if let len = Self.matchPrefix(in: chars, at: i, candidates: Self.timeNumberTokens) {
                attributes.append((NSRange(location: baseOffset + i, length: len), numberColor))
                i += len
                continue
            }

            let c = chars[i]
            if c >= 0x31 && c <= 0x35 {
                let prevIsDigit = i > 0 && Self.isASCIIDigit(chars[i - 1])
                let nextIsDigit = (i + 1) < n && Self.isASCIIDigit(chars[i + 1])
                if !prevIsDigit && !nextIsDigit {
                    attributes.append((NSRange(location: baseOffset + i, length: 1), numberColor))
                    i += 1
                    continue
                }
            }

            i += 1
        }
    }

    private func scanRegexTokens(
        _ chars: [unichar],
        baseOffset: Int,
        isRaw: Bool,
        keywordColor: NSColor,
        numberColor: NSColor,
        typeColor: NSColor,
        builtinColor: NSColor,
        into attributes: inout [(NSRange, NSColor)]
    ) {
        let n = chars.count
        var i = 0
        var inCharClass = false
        var charClassContentStart = 0

        while i < n {
            let c = chars[i]

            if c == 0x5C {
                if !isRaw, i + 1 < n, chars[i + 1] == 0x5C {
                    if i + 2 < n {
                        let c2 = chars[i + 2]
                        if (c2 == 0x70 || c2 == 0x50), i + 3 < n, chars[i + 3] == 0x7B,
                           let closeIdx = Self.findClosingBrace(in: chars, from: i + 4) {
                            attributes.append((NSRange(location: baseOffset + i, length: closeIdx - i + 1), builtinColor))
                            i = closeIdx + 1
                            continue
                        }
                        if Self.isRegexEscapeChar(c2) {
                            attributes.append((NSRange(location: baseOffset + i, length: 3), builtinColor))
                            i += 3
                            continue
                        }
                    }
                    attributes.append((NSRange(location: baseOffset + i, length: 2), builtinColor))
                    i += 2
                    continue
                }

                if i + 1 < n {
                    let c1 = chars[i + 1]
                    if (c1 == 0x70 || c1 == 0x50), i + 2 < n, chars[i + 2] == 0x7B,
                       let closeIdx = Self.findClosingBrace(in: chars, from: i + 3) {
                        attributes.append((NSRange(location: baseOffset + i, length: closeIdx - i + 1), builtinColor))
                        i = closeIdx + 1
                        continue
                    }
                    attributes.append((NSRange(location: baseOffset + i, length: 2), builtinColor))
                    i += 2
                    continue
                }

                i += 1
                continue
            }

            if inCharClass {
                if c == 0x5E && i == charClassContentStart {
                    attributes.append((NSRange(location: baseOffset + i, length: 1), typeColor))
                    charClassContentStart += 1
                    i += 1
                    continue
                }
                if c == 0x5D {
                    attributes.append((NSRange(location: baseOffset + i, length: 1), typeColor))
                    if i > charClassContentStart {
                        inCharClass = false
                    }
                    i += 1
                    continue
                }
                if c == 0x2D && i > charClassContentStart && (i + 1) < n && chars[i + 1] != 0x5D {
                    attributes.append((NSRange(location: baseOffset + i, length: 1), typeColor))
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if c == 0x5B {
                attributes.append((NSRange(location: baseOffset + i, length: 1), typeColor))
                inCharClass = true
                charClassContentStart = i + 1
                i += 1
                continue
            }

            if c == 0x28 {
                if i + 3 < n, chars[i + 1] == 0x3F, chars[i + 2] == 0x50, chars[i + 3] == 0x3C {
                    var j = i + 4
                    while j < n && chars[j] != 0x3E && chars[j] != 0x29 {
                        j += 1
                    }
                    if j < n && chars[j] == 0x3E && j > i + 4 {
                        attributes.append((NSRange(location: baseOffset + i, length: j - i + 1), keywordColor))
                        i = j + 1
                        continue
                    }
                }
                if i + 1 < n, chars[i + 1] == 0x3F {
                    var j = i + 2
                    while j < n && Self.isRegexFlagChar(chars[j]) {
                        j += 1
                    }
                    if j < n && (chars[j] == 0x3A || (chars[j] == 0x29 && j > i + 2)) {
                        attributes.append((NSRange(location: baseOffset + i, length: j - i + 1), keywordColor))
                        i = j + 1
                        continue
                    }
                }
                attributes.append((NSRange(location: baseOffset + i, length: 1), keywordColor))
                i += 1
                continue
            }

            if c == 0x29 || c == 0x7C || c == 0x5E || c == 0x24 {
                attributes.append((NSRange(location: baseOffset + i, length: 1), keywordColor))
                i += 1
                continue
            }

            if c == 0x2B || c == 0x2A || c == 0x3F {
                attributes.append((NSRange(location: baseOffset + i, length: 1), numberColor))
                i += 1
                continue
            }

            if c == 0x7B {
                var j = i + 1
                while j < n && Self.isASCIIDigit(chars[j]) {
                    j += 1
                }
                if j > i + 1 && j < n {
                    if chars[j] == 0x2C {
                        j += 1
                        while j < n && Self.isASCIIDigit(chars[j]) {
                            j += 1
                        }
                    }
                    if j < n && chars[j] == 0x7D {
                        attributes.append((NSRange(location: baseOffset + i, length: j - i + 1), numberColor))
                        i = j + 1
                        continue
                    }
                }
            }

            i += 1
        }
    }

    private static func matchPrefix(in chars: [unichar], at index: Int, candidates: [[unichar]]) -> Int? {
        let remaining = chars.count - index
        for token in candidates {
            let count = token.count
            guard count <= remaining else { continue }
            var matched = true
            for k in 0..<count {
                if chars[index + k] != token[k] {
                    matched = false
                    break
                }
            }
            if matched {
                return count
            }
        }
        return nil
    }

    private static func findClosingBrace(in chars: [unichar], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == 0x7D {
                return j > start ? j : nil
            }
            if chars[j] == 0x7B || chars[j] == 0x5C {
                return nil
            }
            j += 1
        }
        return nil
    }

    private static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isASCIIDigit(_ c: unichar) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private static func isRegexFlagChar(_ c: unichar) -> Bool {
        c == 0x69 || c == 0x6D || c == 0x73 || c == 0x55 || c == 0x2D
    }

    private static func isRegexEscapeChar(_ c: unichar) -> Bool {
        switch c {
        case 0x64, 0x44, 0x77, 0x57, 0x73, 0x53, 0x62, 0x42, 0x41, 0x7A, 0x70, 0x50,
             0x2E, 0x5C, 0x2B, 0x2A, 0x3F, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x5E,
             0x24, 0x7C, 0x6E, 0x74, 0x72, 0x66, 0x76, 0x61, 0x78:
            return true
        default:
            return c >= 0x30 && c <= 0x37
        }
    }

    private func textSubstring(for node: Node) -> String {
        let start = Int(node.byteRange.lowerBound) / 2
        let length = Int(node.byteRange.upperBound - node.byteRange.lowerBound) / 2
        guard length > 0, length <= 64, start + length <= text.length else { return "" }
        return text.substring(with: NSRange(location: start, length: length))
    }
}
