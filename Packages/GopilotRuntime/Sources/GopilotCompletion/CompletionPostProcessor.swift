import Foundation

public enum CompletionPostProcessor {
    public static let maxLines = 12
    public static let maxCharacters = 2_000

    public static func process(_ raw: String, context: CompletionContext) -> String? {
        let cleaned = clean(raw, context: context)
        let truncated = truncate(cleaned, context: context).text
        let trimmed = trimTrailingWhitespace(removeSuffixOverlap(truncated, context: context))
        guard !CompletionText.trimmed(trimmed).isEmpty else { return nil }
        if duplicatesSurroundingCode(trimmed, context: context) { return nil }
        return trimmed
    }

    public static func isComplete(_ partial: String, context: CompletionContext) -> Bool {
        if partial.count > maxCharacters { return true }
        return truncate(clean(partial, context: context), context: context).stopped
    }

    static func clean(_ raw: String, context: CompletionContext) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for tag in ["<COMPLETION>", "</COMPLETION>", CompletionEncoder.cursorMarker] {
            text = text.replacingOccurrences(of: tag, with: "")
        }
        text = stripFences(text)
        text = cutAtControlTokens(text)

        let lineHead = String(context.linePrefix.drop { $0 == " " || $0 == "\t" })
        if !lineHead.isEmpty {
            let candidate = String(text.drop { $0 == " " || $0 == "\t" })
            if candidate.hasPrefix(lineHead), candidate.count > lineHead.count {
                text = String(candidate.dropFirst(lineHead.count))
            }
        }

        let lineIsIndentOnly = !context.linePrefix.isEmpty && CompletionText.isBlank(context.linePrefix)
        if lineIsIndentOnly {
            text = String(text.drop { $0 == "\n" })
        }
        if lineIsIndentOnly || context.linePrefix.last == " " || context.linePrefix.last == "\t" {
            text = String(text.drop { $0 == " " || $0 == "\t" })
        }
        return normalizeIndentation(text, includeFirstLine: context.linePrefix.isEmpty)
    }

    static func cutAtControlTokens(_ text: String) -> String {
        var end = text.endIndex
        for token in FIMTemplate.allControlTokens {
            if let range = text.range(of: token), range.lowerBound < end {
                end = range.lowerBound
            }
        }
        return String(text[..<end])
    }

    static func stripFences(_ text: String) -> String {
        guard let open = text.range(of: "```") else { return text }
        var body = text[open.upperBound...]
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[..<newline]
            if tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }) {
                body = body[body.index(after: newline)...]
            }
        } else if body.allSatisfy({ $0.isLetter }) {
            return ""
        }
        if let close = body.range(of: "```") {
            body = body[..<close.lowerBound]
        }
        var result = String(body)
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    static func normalizeIndentation(_ text: String, includeFirstLine: Bool) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices where index > 0 || includeFirstLine {
            let line = lines[index]
            let spaces = line.prefix { $0 == " " }.count
            guard spaces > 0 else { continue }
            let rest = line.dropFirst(spaces)
            if spaces % 4 == 0 {
                lines[index] = String(repeating: "\t", count: spaces / 4) + rest
            } else if spaces % 2 == 0 {
                lines[index] = String(repeating: "\t", count: spaces / 2) + rest
            }
        }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ text: String, context: CompletionContext) -> (text: String, stopped: Bool) {
        var working = text
        var braceStopped = false
        if let cut = enclosingBlockEnd(in: text, context: context) {
            working = String(text[..<cut])
            braceStopped = true
        }
        if !context.multiline {
            guard let newline = working.firstIndex(of: "\n") else { return (working, braceStopped) }
            let first = working[..<newline]
            return (CompletionText.isBlank(first) ? "" : String(first), true)
        }
        let lines = working.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (working, braceStopped) }
        var kept: [Substring] = [first]
        var sawContent = !CompletionText.isBlank(first)
        let anchorWidth = CompletionText.indentWidth(context.anchorIndent)
        let repeatedLine = firstFollowingCodeLine(context)
        var stopped = braceStopped
        let blockBounded = braceStopped || CompletionEncoder.closesEnclosingBlockNext(context)
        for (offset, line) in lines.dropFirst().enumerated() {
            let isUnterminated = offset == lines.count - 2
            if CompletionText.isBlank(line) {
                if isUnterminated { kept.append(line); break }
                if sawContent && !blockBounded { stopped = true; break }
                kept.append(line)
                continue
            }
            if CompletionText.indentWidth(CompletionText.leadingWhitespace(of: String(line))) < anchorWidth {
                stopped = true
                break
            }
            if let repeatedLine, CompletionText.trimmed(line) == repeatedLine, !isUnterminated || braceStopped {
                stopped = true
                break
            }
            if kept.count >= maxLines {
                stopped = true
                break
            }
            kept.append(line)
            sawContent = true
        }
        if blockBounded {
            while kept.count > 1, let last = kept.last, CompletionText.isBlank(last) {
                kept.removeLast()
            }
        }
        return (kept.joined(separator: "\n"), stopped)
    }

    static func firstFollowingCodeLine(_ context: CompletionContext) -> String? {
        let closers: Set<Character> = [")", "]", "}", ",", ";"]
        for line in context.suffix.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = CompletionText.trimmed(line)
            if trimmed.isEmpty { continue }
            return trimmed.allSatisfy({ closers.contains($0) }) ? nil : trimmed
        }
        return nil
    }

    static func enclosingBlockEnd(in text: String, context: CompletionContext) -> String.Index? {
        var depth = 0
        var quote = scan(context.linePrefix, startingIn: nil).openQuote
        var escaped = false
        var previous: Character?
        var inLineComment = false
        var inBlockComment = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            defer { previous = ch; index = text.index(after: index) }
            if inLineComment {
                if ch == "\n" { inLineComment = false }
                continue
            }
            if inBlockComment {
                if ch == "/" && previous == "*" { inBlockComment = false }
                continue
            }
            if let q = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" && q != "`" {
                    escaped = true
                } else if ch == q || (ch == "\n" && q != "`") {
                    quote = nil
                }
                continue
            }
            switch ch {
            case "\"", "`", "'":
                quote = ch
            case "/" where previous == "/":
                inLineComment = true
            case "*" where previous == "/":
                inBlockComment = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return index }
            default:
                break
            }
        }
        return nil
    }

    static func removeSuffixOverlap(_ text: String, context: CompletionContext) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let following = context.suffix.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(5).map(String.init)
        let before = abs(netDepth(text))
        var k = min(lines.count - 1, following.count, 5)
        while k >= 1 {
            let tail = lines.suffix(k).map(CompletionText.trimmed)
            let head = following.prefix(k).map(CompletionText.trimmed)
            if tail == head, tail.contains(where: { !$0.isEmpty }) {
                let candidate = lines.dropLast(k).joined(separator: "\n")
                if abs(netDepth(candidate)) <= before {
                    lines.removeLast(k)
                }
                break
            }
            k -= 1
        }
        var result = trimTrailingWhitespace(lines.joined(separator: "\n"))
        result = removeClosingOverlap(result, context: context)
        return result
    }

    static func removeClosingOverlap(_ text: String, context: CompletionContext) -> String {
        let tokens: Set<Character> = [")", "]", "}", "\"", "`", "'"]
        let openQuote = scan(context.linePrefix, startingIn: nil).openQuote
        let scanned = scan(text, startingIn: openQuote)
        let wanted = max(0, -scanned.depth) + (scanned.closedInitialQuote ? 1 : 0)
        guard wanted > 0 else { return text }
        var tail: [Character] = []
        var index = text.endIndex
        while index > text.startIndex, tail.count < wanted {
            let previous = text.index(before: index)
            let ch = text[previous]
            if tokens.contains(ch) {
                tail.insert(ch, at: 0)
            } else if ch != " " && ch != "\t" && ch != "\n" {
                break
            }
            index = previous
        }
        var head: [Character] = []
        for ch in context.suffix {
            if tokens.contains(ch) { head.append(ch) } else if ch == " " || ch == "\t" || ch == "\n" { continue } else { break }
            if head.count >= tail.count { break }
        }
        var k = min(tail.count, head.count)
        while k > 0, Array(tail.suffix(k)) != Array(head.prefix(k)) { k -= 1 }
        guard k > 0 else { return text }
        var removed = 0
        var position = text.endIndex
        while position > text.startIndex, removed < k {
            let previous = text.index(before: position)
            if tokens.contains(text[previous]) { removed += 1 }
            position = previous
        }
        return trimTrailingWhitespace(String(text[..<position]))
    }

    static func netDepth(_ text: String) -> Int {
        scan(text, startingIn: nil).depth
    }

    static func scan(_ text: String, startingIn initialQuote: Character?) -> (depth: Int, openQuote: Character?, closedInitialQuote: Bool) {
        var depth = 0
        var quote = initialQuote
        var closedInitial = false
        var escaped = false
        var previous: Character?
        var inLineComment = false
        for ch in text {
            if inLineComment {
                if ch == "\n" { inLineComment = false }
                previous = ch
                continue
            }
            if let q = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" && q != "`" {
                    escaped = true
                } else if ch == q || (ch == "\n" && q != "`") {
                    if initialQuote != nil && !closedInitial && ch == q { closedInitial = true }
                    quote = nil
                }
                previous = ch
                continue
            }
            switch ch {
            case "\"", "`", "'": quote = ch
            case "/" where previous == "/": inLineComment = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
            previous = ch
        }
        return (depth, quote, closedInitial)
    }

    static func trimTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last == " " || last == "\t" || last == "\n" {
            result.removeLast()
        }
        return result
    }

    static func duplicatesSurroundingCode(_ text: String, context: CompletionContext) -> Bool {
        let candidate = CompletionText.trimmed(text)
        let following = context.suffix.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        if let next = following.first(where: { !CompletionText.trimmed($0).isEmpty }), CompletionText.trimmed(next) == candidate {
            return true
        }
        return false
    }
}
