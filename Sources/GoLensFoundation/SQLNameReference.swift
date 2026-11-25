import Foundation

public struct SQLNameReference: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let name: String
        public let quoted: Bool
        public let range: NSRange

        public init(name: String, quoted: Bool, range: NSRange) {
            self.name = name
            self.quoted = quoted
            self.range = range
        }
    }

    public let parts: [Part]

    public var range: NSRange {
        guard let first = parts.first, let last = parts.last else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
    }

    public static func at(_ index: Int, in text: NSString) -> SQLNameReference? {
        guard index >= 0, index < text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        let tokens = SQLNameScanner.tokens(in: text, range: line)
        guard let hit = tokens.firstIndex(where: { $0.isName && NSLocationInRange(index, $0.range) }) else { return nil }
        var first = hit
        while first >= 2, tokens[first - 1].isDot, tokens[first - 2].isName,
              NSMaxRange(tokens[first - 2].range) == tokens[first - 1].range.location,
              NSMaxRange(tokens[first - 1].range) == tokens[first].range.location {
            first -= 2
        }
        let parts = stride(from: first, through: hit, by: 2).map { i -> Part in
            let token = tokens[i]
            return Part(name: token.name(in: text), quoted: token.kind == .quoted, range: token.range)
        }
        return SQLNameReference(parts: parts)
    }
}

enum SQLNameScanner {
    enum Kind { case word, quoted, dot, other }

    struct Token {
        let kind: Kind
        let range: NSRange

        var isName: Bool { kind == .word || kind == .quoted }
        var isDot: Bool { kind == .dot }

        func name(in text: NSString) -> String {
            guard kind == .quoted, range.length >= 2 else { return text.substring(with: range) }
            let quote = text.substring(with: NSRange(location: range.location, length: 1))
            let inner = text.substring(with: NSRange(location: range.location + 1, length: range.length - 2))
            return inner.replacingOccurrences(of: quote + quote, with: quote)
        }
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        c == 0x5F || c == 0x24 || c >= 0x80 || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    static func tokens(in text: NSString, range: NSRange) -> [Token] {
        var tokens: [Token] = []
        let end = NSMaxRange(range)
        var i = range.location
        func at(_ j: Int) -> unichar { j < end ? text.character(at: j) : 0 }
        while i < end {
            let c = at(i)
            switch c {
            case 0x27:
                i += 1
                while i < end {
                    if at(i) == 0x27 {
                        if at(i + 1) == 0x27 { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
            case 0x2D where at(i + 1) == 0x2D, 0x23:
                return tokens
            case 0x2F where at(i + 1) == 0x2A:
                i += 2
                while i < end, !(at(i) == 0x2A && at(i + 1) == 0x2F) { i += 1 }
                i = min(end, i + 2)
            case 0x22, 0x60:
                let start = i
                i += 1
                var closed = false
                while i < end {
                    if at(i) == c {
                        if at(i + 1) == c { i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                if closed, i - start > 2 { tokens.append(Token(kind: .quoted, range: NSRange(location: start, length: i - start))) }
            case 0x2E:
                tokens.append(Token(kind: .dot, range: NSRange(location: i, length: 1)))
                i += 1
            default:
                guard isWordChar(c) else {
                    i += 1
                    continue
                }
                let start = i
                while i < end, isWordChar(at(i)) { i += 1 }
                let isNumber = (0x30...0x39).contains(text.character(at: start))
                tokens.append(Token(kind: isNumber ? .other : .word, range: NSRange(location: start, length: i - start)))
            }
        }
        return tokens
    }
}
