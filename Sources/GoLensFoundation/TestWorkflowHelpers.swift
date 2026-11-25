import Foundation

public struct GoTestDeclMatch: Equatable, Sendable {
    public let prefix: String
    public let anchorUTF16Offset: Int
    public let hasParameterParenAfterCaret: Bool

    public init(prefix: String, anchorUTF16Offset: Int, hasParameterParenAfterCaret: Bool) {
        self.prefix = prefix
        self.anchorUTF16Offset = anchorUTF16Offset
        self.hasParameterParenAfterCaret = hasParameterParenAfterCaret
    }
}

public enum GoTestCompletionContext {
    public static func topLevelTestDeclPrefix(
        in text: String,
        caretUTF16: Int,
        allowEmptyAfterFunc: Bool = false
    ) -> GoTestDeclMatch? {
        let ns = text as NSString
        guard caretUTF16 >= 0, caretUTF16 <= ns.length else { return nil }
        guard isAtTopLevelCode(in: ns, upTo: caretUTF16) else { return nil }

        let lineRange = ns.lineRange(for: NSRange(location: caretUTF16, length: 0))
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location, length: caretUTF16 - lineRange.location))
        let trimmedLeading = dropLeadingHorizontalSpace(beforeCaret)
        guard trimmedLeading.hasPrefix("func") else { return nil }

        let afterFuncKeyword = trimmedLeading.dropFirst(4)
        guard let firstAfterFunc = afterFuncKeyword.first, firstAfterFunc == " " || firstAfterFunc == "\t" else {
            return nil
        }

        let identSlice = dropLeadingHorizontalSpace(String(afterFuncKeyword))
        guard identSlice.unicodeScalars.allSatisfy(isGoIdentScalar) else {
            return nil
        }

        if identSlice.isEmpty {
            guard allowEmptyAfterFunc else { return nil }
        } else if !("Test".hasPrefix(identSlice) || identSlice.hasPrefix("Test")) {
            return nil
        }

        let lineEnd = NSMaxRange(lineRange)
        var scan = caretUTF16
        while scan < lineEnd, isGoIdentUTF16(ns.character(at: scan)) {
            scan += 1
        }
        while scan < lineEnd {
            let ch = ns.character(at: scan)
            if ch == 0x20 || ch == 0x09 {
                scan += 1
            } else {
                break
            }
        }
        let hasParen = scan < lineEnd && ns.character(at: scan) == 0x28
        let anchor = caretUTF16 - (identSlice as NSString).length
        return GoTestDeclMatch(
            prefix: identSlice,
            anchorUTF16Offset: anchor,
            hasParameterParenAfterCaret: hasParen
        )
    }

    public static func existingTopLevelTestNames(in text: String) -> Set<String> {
        let pattern = #"(?m)^\s*func\s+(?:\([^)]*\)\s+)?(Test[A-Za-z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var names = Set<String>()
        for match in matches where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                names.insert(ns.substring(with: range))
            }
        }
        return names
    }

    private static func isAtTopLevelCode(in ns: NSString, upTo limit: Int) -> Bool {
        var depth = 0
        var inLineComment = false
        var inBlockComment = false
        var quote: unichar = 0
        var escaped = false
        var prev: unichar = 0
        var i = 0
        while i < limit {
            let c = ns.character(at: i)
            if c == 0x0A {
                inLineComment = false
                if quote != 0x60 {
                    quote = 0
                }
                escaped = false
                prev = c
                i += 1
                continue
            }
            if inLineComment {
                prev = c
                i += 1
                continue
            }
            if inBlockComment {
                if prev == 0x2A && c == 0x2F {
                    inBlockComment = false
                    prev = 0
                } else {
                    prev = c
                }
                i += 1
                continue
            }
            if quote != 0 {
                if escaped {
                    escaped = false
                } else if c == 0x5C && quote != 0x60 {
                    escaped = true
                } else if c == quote {
                    quote = 0
                }
                prev = c
                i += 1
                continue
            }
            if prev == 0x2F && c == 0x2F {
                inLineComment = true
                prev = c
                i += 1
                continue
            }
            if prev == 0x2F && c == 0x2A {
                inBlockComment = true
                prev = 0
                i += 1
                continue
            }
            switch c {
            case 0x22, 0x27, 0x60:
                quote = c
            case 0x7B:
                depth += 1
            case 0x7D:
                depth = max(0, depth - 1)
            default:
                break
            }
            prev = c
            i += 1
        }
        return depth == 0 && !inLineComment && !inBlockComment && quote == 0
    }

    private static func dropLeadingHorizontalSpace(_ s: String) -> String {
        var idx = s.startIndex
        while idx < s.endIndex && (s[idx] == " " || s[idx] == "\t") {
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    private static func isGoIdentScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x5F
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || scalar.value >= 0x80
    }

    private static func isGoIdentUTF16(_ u: unichar) -> Bool {
        u == 0x5F || (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u >= 0x80
    }
}

public enum FailedSubtestSelection {
    public static func pruneAncestors(_ failedNames: [String]) -> [String] {
        let unique = Array(Set(failedNames.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [] }
        let pruned = unique.filter { candidate in
            let prefix = candidate + "/"
            return !unique.contains { other in
                other != candidate && other.hasPrefix(prefix)
            }
        }
        return (pruned.isEmpty ? unique : pruned).sorted()
    }
}

public struct TestDiffLineItem: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let type: String
    public let text: String
    public let lineNum: Int

    public init(id: String, type: String, text: String, lineNum: Int) {
        self.id = id
        self.type = type
        self.text = text
        self.lineNum = lineNum
    }
}

public struct TestDiffSideBySideRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public let want: TestDiffLineItem?
    public let got: TestDiffLineItem?

    public init(id: Int, want: TestDiffLineItem?, got: TestDiffLineItem?) {
        self.id = id
        self.want = want
        self.got = got
    }
}

public enum TestFailureDiffAlignment {
    public static func alignSideBySide(_ lines: [TestDiffLineItem]) -> [TestDiffSideBySideRow] {
        var rows: [TestDiffSideBySideRow] = []
        var pendingWant: [TestDiffLineItem] = []
        var pendingGot: [TestDiffLineItem] = []

        func flushPending() {
            let count = max(pendingWant.count, pendingGot.count)
            guard count > 0 else { return }
            for i in 0..<count {
                let w = i < pendingWant.count ? pendingWant[i] : nil
                let g = i < pendingGot.count ? pendingGot[i] : nil
                rows.append(TestDiffSideBySideRow(id: rows.count, want: w, got: g))
            }
            pendingWant.removeAll(keepingCapacity: true)
            pendingGot.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.type {
            case "want":
                pendingWant.append(line)
            case "got":
                pendingGot.append(line)
            default:
                flushPending()
                rows.append(TestDiffSideBySideRow(id: rows.count, want: line, got: line))
            }
        }
        flushPending()
        return rows
    }
}
