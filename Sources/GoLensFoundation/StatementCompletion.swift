import Foundation

public struct StatementCompletion: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var caret: Int

    public init(range: NSRange, replacement: String, caret: Int) {
        self.range = range
        self.replacement = replacement
        self.caret = caret
    }

    public static func compute(text: String, caret: Int, indentUnit: String = "\t") -> StatementCompletion? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let scan = scanLine(line)
        let code = String(line.prefix(scan.codeLength))
        let body = trimTrailingSpace(code)
        let trailing = String(line.dropFirst(body.count))
        let trimmed = body.trimmingCharacters(in: .whitespaces)

        var brackets = scan.openBrackets
        let opensBlock = scan.openString == nil && trimmed.hasSuffix("{") && brackets.last == "{"
        if opensBlock { brackets.removeLast() }
        var closers = scan.openString.map(String.init) ?? ""
        closers += brackets.reversed().map { closer(for: $0) }.joined()
        let completed = trimmed + closers
        let codeEnd = lineStart + (body as NSString).length
        let lineRange = NSRange(location: codeEnd, length: contentsEnd - codeEnd)
        guard !trimmed.isEmpty else { return nil }
        let word = firstWord(completed)
        let inner = word == "switch" || word == "select" ? indent : indent + indentUnit
        if isCaseClause(completed) {
            let colon = completed.hasSuffix(":") ? "" : ":"
            let text = closers + colon + trailing + "\n" + inner
            return StatementCompletion(range: lineRange, replacement: text, caret: codeEnd + (text as NSString).length)
        }
        if opensBlock {
            let afterLine = lineEnd
            let closed = blockIsClosed(ns, after: afterLine, indent: indent)
            let head = closers + trailing + "\n" + inner
            let text = head + (closed ? "" : "\n" + indent + "}")
            return StatementCompletion(range: lineRange, replacement: text, caret: codeEnd + (head as NSString).length)
        }
        if isBlockHeader(completed) {
            let suffix = isGoroutineLiteral(completed) ? "}()" : "}"
            let head = closers + " {" + trailing + "\n" + inner
            let text = head + "\n" + indent + suffix
            return StatementCompletion(range: lineRange, replacement: text, caret: codeEnd + (head as NSString).length)
        }
        let continuation = completed.hasSuffix(",") || completed.hasSuffix("(") || completed.hasSuffix("[") ? inner : indent
        let text = closers + trailing + "\n" + continuation
        return StatementCompletion(range: lineRange, replacement: text, caret: codeEnd + (text as NSString).length)
    }

    private struct LineScan {
        var codeLength: Int
        var openBrackets: [Character]
        var openString: Character?
    }

    private static func scanLine(_ line: String) -> LineScan {
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        var count = 0
        var previous: Character?
        for ch in line {
            if let q = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" && q != "`" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
                count += 1
                previous = ch
                continue
            }
            if ch == "/" && previous == "/" {
                return LineScan(codeLength: count - 1, openBrackets: stack, openString: nil)
            }
            switch ch {
            case "\"", "'", "`": quote = ch
            case "(", "[", "{": stack.append(ch)
            case ")", "]", "}":
                if let last = stack.last, closer(for: last) == String(ch) { stack.removeLast() }
            default: break
            }
            count += 1
            previous = ch
        }
        return LineScan(codeLength: count, openBrackets: stack, openString: quote)
    }

    private static func closer(for opener: Character) -> String {
        switch opener {
        case "(": return ")"
        case "[": return "]"
        default: return "}"
        }
    }

    private static func trimTrailingSpace(_ s: String) -> String {
        var result = s
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    private static func firstWord(_ s: String) -> String {
        var rest = Substring(s)
        if rest.hasPrefix("}") { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    private static func isCaseClause(_ s: String) -> Bool {
        let word = firstWord(s)
        return (word == "case" && s.count > 4) || (word == "default" && (s == "default" || s == "default:"))
    }

    private static func isBlockHeader(_ s: String) -> Bool {
        switch firstWord(s) {
        case "if", "for", "switch", "select", "else", "func":
            return true
        case "type":
            return endsWithWord(s, "struct") || endsWithWord(s, "interface")
        case "go", "defer":
            return isGoroutineLiteral(s)
        default:
            return endsWithWord(s, "struct") || endsWithWord(s, "interface") || endsWithFuncLiteral(s)
        }
    }

    private static func isGoroutineLiteral(_ s: String) -> Bool {
        let word = firstWord(s)
        guard word == "go" || word == "defer" else { return false }
        let rest = s.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("func(") || rest.hasPrefix("func (")
    }

    private static func endsWithWord(_ s: String, _ word: String) -> Bool {
        guard s.hasSuffix(word) else { return false }
        let before = s.dropLast(word.count).last
        return before == nil || !(before!.isLetter || before!.isNumber || before! == "_")
    }

    private static func endsWithFuncLiteral(_ s: String) -> Bool {
        guard let range = s.range(of: "func(", options: .backwards) ?? s.range(of: "func (", options: .backwards) else { return false }
        if range.lowerBound > s.startIndex {
            let before = s[s.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber || before == "_" || before == "." { return false }
        }
        var depth = 0
        for ch in s[s.index(before: range.upperBound)...] {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        return depth == 0
    }

    private static func blockIsClosed(_ ns: NSString, after location: Int, indent: String) -> Bool {
        var position = location
        while position < ns.length {
            let range = ns.lineRange(for: NSRange(location: position, length: 0))
            let line = ns.substring(with: range).trimmingCharacters(in: .newlines)
            position = NSMaxRange(range)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let lineIndent = line.prefix { $0 == " " || $0 == "\t" }
            if lineIndent.count > indent.count { return true }
            return line.dropFirst(lineIndent.count).hasPrefix("}")
        }
        return false
    }
}
