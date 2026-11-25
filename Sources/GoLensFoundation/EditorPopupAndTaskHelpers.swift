import Foundation

public enum SignatureParameterHighlighter {
    public struct ParameterSpec: Equatable, Sendable {
        public let label: String
        public let utf16Range: Range<Int>?

        public init(label: String, utf16Range: Range<Int>? = nil) {
            self.label = label
            self.utf16Range = utf16Range
        }
    }

    public static func activeUTF16Range(
        signatureLabel: String,
        parameters: [ParameterSpec],
        activeParameter: Int
    ) -> Range<Int>? {
        guard parameters.indices.contains(activeParameter) else { return nil }
        let ns = signatureLabel as NSString
        let totalLength = ns.length
        guard totalLength > 0 else { return nil }

        let target = parameters[activeParameter]
        if let explicit = target.utf16Range,
           explicit.lowerBound >= 0,
           explicit.upperBound <= totalLength,
           explicit.lowerBound < explicit.upperBound {
            return explicit
        }

        let needle = target.label
        guard !needle.isEmpty else { return nil }

        let paramBounds = parameterListUTF16Bounds(in: ns)
        var searchStart = paramBounds?.lowerBound ?? 0
        let searchEnd = paramBounds?.upperBound ?? totalLength

        if activeParameter > 0 {
            for idx in 0..<activeParameter {
                let prev = parameters[idx]
                if let prevRange = prev.utf16Range,
                   prevRange.upperBound <= searchEnd,
                   prevRange.upperBound > searchStart {
                    searchStart = advancePastDelimiter(in: ns, from: prevRange.upperBound, limit: searchEnd)
                } else if !prev.label.isEmpty, searchStart < searchEnd {
                    if let matched = findParameterToken(prev.label, in: ns, range: NSRange(location: searchStart, length: searchEnd - searchStart)) {
                        searchStart = advancePastDelimiter(in: ns, from: NSMaxRange(matched), limit: searchEnd)
                    }
                }
            }
        }

        if searchStart < searchEnd,
           let match = findParameterToken(needle, in: ns, range: NSRange(location: searchStart, length: searchEnd - searchStart)) {
            return match.location..<(match.location + match.length)
        }

        if let bounds = paramBounds, bounds.lowerBound < bounds.upperBound,
           let fallbackInParams = findParameterToken(needle, in: ns, range: NSRange(location: bounds.lowerBound, length: bounds.upperBound - bounds.lowerBound)) {
            return fallbackInParams.location..<(fallbackInParams.location + fallbackInParams.length)
        }

        let fullMatch = ns.range(of: needle)
        if fullMatch.location != NSNotFound, fullMatch.length > 0 {
            return fullMatch.location..<(fullMatch.location + fullMatch.length)
        }
        return nil
    }

    private static func parameterListUTF16Bounds(in ns: NSString) -> Range<Int>? {
        let len = ns.length
        var groups: [Range<Int>] = []
        var depth = 0
        var currentOpen: Int? = nil
        var i = 0
        while i < len {
            let ch = ns.character(at: i)
            if ch == 0x28 {
                if depth == 0 {
                    currentOpen = i + 1
                }
                depth += 1
            } else if ch == 0x29 {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = currentOpen {
                        groups.append(start..<i)
                        currentOpen = nil
                    }
                }
            }
            i += 1
        }
        guard !groups.isEmpty else { return nil }
        let prefixBeforeFirst = ns.substring(with: NSRange(location: 0, length: max(0, groups[0].lowerBound - 1)))
            .trimmingCharacters(in: .whitespaces)
        if (prefixBeforeFirst.isEmpty || prefixBeforeFirst == "func"), groups.count >= 2 {
            let gapStart = groups[0].upperBound + 1
            let gapEnd = groups[1].lowerBound - 1
            if gapEnd > gapStart {
                let between = ns.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
                    .trimmingCharacters(in: .whitespaces)
                if !between.isEmpty && !between.hasPrefix("(") {
                    return groups[1]
                }
            }
        }
        return groups[0]
    }

    private static func advancePastDelimiter(in ns: NSString, from index: Int, limit: Int) -> Int {
        var pos = min(max(0, index), limit)
        while pos < limit {
            let ch = ns.character(at: pos)
            if ch == 0x2C {
                pos += 1
                while pos < limit && (ns.character(at: pos) == 0x20 || ns.character(at: pos) == 0x09) {
                    pos += 1
                }
                return pos
            }
            pos += 1
        }
        return min(max(0, index), limit)
    }

    private static func findParameterToken(_ needle: String, in ns: NSString, range: NSRange) -> NSRange? {
        guard range.length > 0 else { return nil }
        var searchRange = range
        var firstRawMatch: NSRange? = nil
        while searchRange.length > 0 {
            let found = ns.range(of: needle, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            if firstRawMatch == nil {
                firstRawMatch = found
            }
            let validLeading: Bool = {
                if found.location == range.location { return true }
                let prev = ns.character(at: found.location - 1)
                return prev == 0x28 || prev == 0x2C || prev == 0x20 || prev == 0x09
            }()
            let endLoc = NSMaxRange(found)
            let validTrailing: Bool = {
                if endLoc >= NSMaxRange(range) { return true }
                let next = ns.character(at: endLoc)
                return next == 0x2C || next == 0x29 || next == 0x20 || next == 0x09
            }()
            if validLeading && validTrailing {
                return found
            }
            let nextStart = found.location + 1
            let maxEnd = NSMaxRange(range)
            guard nextStart < maxEnd else { break }
            searchRange = NSRange(location: nextStart, length: maxEnd - nextStart)
        }
        return firstRawMatch
    }
}

public enum MarkdownTaskToggle {
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String

        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    public static func edit(in text: String, atZeroBasedLine lineIndex: Int) -> Edit? {
        guard lineIndex >= 0 else { return nil }
        let ns = text as NSString
        let totalLength = ns.length
        var currentLine = 0
        var lineStart = 0

        while lineStart <= totalLength {
            let newlineRange = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: totalLength - lineStart)
            )
            let lineEnd = newlineRange.location == NSNotFound ? totalLength : newlineRange.location
            if currentLine == lineIndex {
                let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let unchecked = ns.range(of: "[ ]", options: [], range: lineRange)
                let checkedLower = ns.range(of: "[x]", options: [], range: lineRange)
                let checkedUpper = ns.range(of: "[X]", options: [], range: lineRange)

                let candidates: [(NSRange, String)] = [
                    (unchecked, "[x]"),
                    (checkedLower, "[ ]"),
                    (checkedUpper, "[ ]")
                ].filter { $0.0.location != NSNotFound }

                guard let earliest = candidates.min(by: { $0.0.location < $1.0.location }) else {
                    return nil
                }
                return Edit(range: earliest.0, replacement: earliest.1)
            }
            if newlineRange.location == NSNotFound {
                break
            }
            currentLine += 1
            lineStart = newlineRange.location + 1
        }
        return nil
    }
}
