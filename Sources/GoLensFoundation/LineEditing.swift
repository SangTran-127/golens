import Foundation

public struct LineEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

struct SourceLines {
    struct Line {
        var start: Int
        var contentsEnd: Int
        var end: Int
    }

    let ns: NSString
    let lines: [Line]

    init(_ text: String) {
        ns = text as NSString
        var result: [Line] = []
        var location = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(Line(start: start, contentsEnd: contentsEnd, end: end))
            location = end
        }
        if result.isEmpty || ns.length == 0 || result.last!.end > result.last!.contentsEnd {
            result.append(Line(start: ns.length, contentsEnd: ns.length, end: ns.length))
        }
        lines = result
    }

    var count: Int { lines.count }

    func index(containing location: Int) -> Int {
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func lastIndex(of selection: NSRange) -> Int {
        let first = index(containing: selection.location)
        guard selection.length > 0 else { return first }
        let last = index(containing: NSMaxRange(selection))
        return last > first && lines[last].start == NSMaxRange(selection) ? last - 1 : last
    }

    func isTrailingEmptyLine(_ i: Int) -> Bool {
        i > 0 && i == lines.count - 1 && lines[i].start == ns.length
    }

    func content(_ i: Int) -> String {
        ns.substring(with: NSRange(location: lines[i].start, length: lines[i].contentsEnd - lines[i].start))
    }

    func full(_ i: Int) -> String {
        ns.substring(with: NSRange(location: lines[i].start, length: lines[i].end - lines[i].start))
    }
}

private func leadingWhitespace<S: StringProtocol>(_ s: S) -> String {
    String(s.prefix { $0 == " " || $0 == "\t" })
}

private func trimmedLeading<S: StringProtocol>(_ s: S) -> String {
    String(s.drop { $0 == " " || $0 == "\t" })
}

private func trimmedTrailing(_ s: String) -> String {
    var s = s
    while let last = s.last, last == " " || last == "\t" { s.removeLast() }
    return s
}

public enum LineJoiner {
    public static func join(text: String, selection: NSRange) -> LineEdit? {
        let src = SourceLines(text)
        let first = src.index(containing: selection.location)
        var last = src.lastIndex(of: selection)
        if last == first { last = first + 1 }
        guard last < src.count, !src.isTrailingEmptyLine(last) else { return nil }
        var result = trimmedTrailing(src.content(first))
        var caret = (result as NSString).length
        for i in (first + 1)...last {
            let next = src.content(i)
            var rest = trimmedLeading(next)
            if result.trimmingCharacters(in: .whitespaces).isEmpty {
                result = leadingWhitespace(next)
                caret = (result as NSString).length
                result += trimmedTrailing(rest)
                continue
            }
            if trimmedLeading(result).hasPrefix("//") && rest.hasPrefix("//") {
                rest = trimmedLeading(rest.dropFirst(2))
            }
            rest = trimmedTrailing(rest)
            caret = (result as NSString).length
            result += separator(between: result, and: rest) + rest
        }
        let range = NSRange(location: src.lines[first].start, length: src.lines[last].contentsEnd - src.lines[first].start)
        return LineEdit(range: range, replacement: result, selection: NSRange(location: range.location + caret, length: 0))
    }

    private static func separator(between left: String, and right: String) -> String {
        guard let l = left.last, let r = right.first else { return "" }
        if "([.".contains(l) || ")],".contains(r) { return "" }
        return " "
    }
}

public enum StatementMover {
    struct LineInfo {
        var depthBefore = 0
        var delta = 0
        var lowest = 0
        var blank = false
        var comment = false
        var depthAfter: Int { depthBefore + delta }
        var closesOuter: Bool { lowest < 0 }
    }

    public static func move(text: String, selection: NSRange, up: Bool) -> LineEdit? {
        let src = SourceLines(text)
        let info = scan(src)
        let first = src.index(containing: selection.location)
        let last = src.lastIndex(of: selection)
        guard !src.isTrailingEmptyLine(first), let unit = unit(first, last, info) else { return nil }
        let depth = info[unit.lowerBound].depthBefore
        let neighbor: ClosedRange<Int>
        if up {
            let p = unit.lowerBound - 1
            guard p >= 0 else { return nil }
            if info[p].blank {
                neighbor = p...p
            } else {
                guard info[p].depthAfter == depth else { return nil }
                var j = p
                while j > 0 && info[j].depthBefore > depth { j -= 1 }
                guard info[j].depthBefore == depth, let n = self.unit(j, j, info), n.upperBound == p else { return nil }
                neighbor = n
            }
        } else {
            let n = unit.upperBound + 1
            guard n < src.count, !src.isTrailingEmptyLine(n) else { return nil }
            if info[n].blank {
                neighbor = n...n
            } else {
                guard info[n].depthBefore == depth, !info[n].closesOuter, let r = self.unit(n, n, info), r.lowerBound == n else { return nil }
                neighbor = r
            }
        }
        return swap(unit, neighbor, up: up, src: src, selection: selection)
    }

    private static func swap(_ unit: ClosedRange<Int>, _ neighbor: ClosedRange<Int>, up: Bool, src: SourceLines, selection: NSRange) -> LineEdit {
        func block(_ r: ClosedRange<Int>) -> String {
            let s = r.map { src.full($0) }.joined()
            return s.hasSuffix("\n") ? s : s + "\n"
        }
        let top = up ? neighbor : unit
        let bottom = up ? unit : neighbor
        let start = src.lines[top.lowerBound].start
        let end = src.lines[bottom.upperBound].end
        let endsWithoutNewline = src.lines[bottom.upperBound].end == src.lines[bottom.upperBound].contentsEnd
        var replacement = block(bottom) + block(top)
        if endsWithoutNewline { replacement.removeLast() }
        let unitText = block(unit) as NSString
        let offset = selection.location - src.lines[unit.lowerBound].start
        let newUnitStart = up ? start : start + (block(neighbor) as NSString).length
        let length = min(selection.length, unitText.length - offset)
        return LineEdit(range: NSRange(location: start, length: end - start), replacement: replacement, selection: NSRange(location: newUnitStart + offset, length: max(0, length)))
    }

    static func unit(_ a: Int, _ b: Int, _ info: [LineInfo]) -> ClosedRange<Int>? {
        if a == b && info[a].blank { return a...a }
        var s = a, e = b
        if (s...e).allSatisfy({ info[$0].comment || info[$0].blank }) {
            let depth = info[s].depthBefore
            while e + 1 < info.count && info[e + 1].comment && info[e + 1].depthBefore == depth { e += 1 }
            let n = e + 1
            if n < info.count, !info[n].blank, !info[n].closesOuter, info[n].depthBefore == depth, let c = core(n, n, info), c.lowerBound == n {
                e = c.upperBound
            }
        } else {
            guard let c = core(s, e, info) else { return nil }
            s = c.lowerBound
            e = c.upperBound
        }
        while s > 0 && info[s - 1].comment && info[s - 1].depthBefore == info[s].depthBefore { s -= 1 }
        return s...e
    }

    private static func core(_ a: Int, _ b: Int, _ info: [LineInfo]) -> ClosedRange<Int>? {
        var s = a
        while info[s].closesOuter {
            let target = info[s].depthBefore + info[s].lowest
            guard let j = (0..<s).last(where: { info[$0].depthBefore == target }) else { return nil }
            s = j
        }
        let depth = info[s].depthBefore
        var e = max(b, s)
        for k in s...e where k > s && info[k].depthBefore + info[k].lowest < depth { return nil }
        while info[e].depthAfter != depth {
            e += 1
            guard e < info.count, info[e].depthBefore + info[e].lowest >= depth else { return nil }
        }
        return s...e
    }

    static func scan(_ src: SourceLines) -> [LineInfo] {
        var result: [LineInfo] = []
        var depth = 0
        var inRaw = false
        var inBlockComment = false
        for i in 0..<src.count {
            let line = src.content(i)
            var info = LineInfo()
            info.depthBefore = depth
            let startsInside = inRaw || inBlockComment
            let trimmed = trimmedLeading(line)
            info.blank = !startsInside && trimmed.isEmpty
            info.comment = !startsInside && trimmed.hasPrefix("//")
            var quote: Character?
            var escaped = false
            var previous: Character?
            var relative = 0
            for ch in line {
                if inBlockComment {
                    if previous == "*" && ch == "/" { inBlockComment = false; previous = nil; continue }
                } else if inRaw {
                    if ch == "`" { inRaw = false }
                } else if let q = quote {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
                } else if ch == "/" && previous == "/" {
                    break
                } else if ch == "*" && previous == "/" {
                    inBlockComment = true
                    previous = nil
                    continue
                } else if ch == "`" {
                    inRaw = true
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if "({[".contains(ch) {
                    relative += 1
                } else if ")}]".contains(ch) {
                    relative -= 1
                    info.lowest = min(info.lowest, relative)
                }
                previous = ch
            }
            info.delta = relative
            depth += relative
            result.append(info)
        }
        return result
    }
}

public enum LineCommentContinuation {
    public static func prefix(lineBeforeCaret: String, lineAfterCaret: String, nextLine: String?) -> String? {
        let indent = leadingWhitespace(lineBeforeCaret)
        let body = lineBeforeCaret.dropFirst(indent.count)
        guard body.hasPrefix("//") else { return nil }
        let afterSlashes = body.dropFirst(2)
        let spaces = leadingWhitespace(afterSlashes)
        if spaces.isEmpty && !afterSlashes.isEmpty { return nil }
        let splitting = !lineAfterCaret.trimmingCharacters(in: .whitespaces).isEmpty
        let nextIsComment = nextLine.map { trimmedLeading($0).hasPrefix("//") } ?? false
        guard splitting || nextIsComment else { return nil }
        return indent + "//" + (spaces.isEmpty ? " " : spaces)
    }
}
