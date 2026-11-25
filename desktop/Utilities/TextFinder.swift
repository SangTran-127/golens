import Foundation

struct TextFinder {
    struct Options: Equatable {
        var matchCase = false
        var wholeWords = false
        var regex = false
    }

    struct TimedOut: Error {}

    static let maxMatches = 10_000
    static let timeLimit: TimeInterval = 2

    let options: Options
    private let expression: NSRegularExpression

    init?(query: String, options: Options) throws {
        guard !query.isEmpty else { return nil }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWords {
            pattern = "(?<!\\w)(?:\(pattern))(?!\\w)"
        }
        expression = try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
        self.options = options
    }

    func matches(in text: NSString, limit: Int = .max, isCancelled: () -> Bool = { false }) throws -> [NSRange] {
        var ranges: [NSRange] = []
        try enumerate(in: text, range: NSRange(location: 0, length: text.length), isCancelled: isCancelled) { match in
            ranges.append(match.range)
            return ranges.count < limit
        }
        return ranges
    }

    func next(in text: NSString, from location: Int, isCancelled: () -> Bool = { false }) throws -> NSRange? {
        let location = min(max(location, 0), text.length)
        let deadline = Date(timeIntervalSinceNow: Self.timeLimit)
        return try first(in: text, range: NSRange(location: location, length: text.length - location), deadline: deadline, isCancelled: isCancelled)
            ?? first(in: text, range: NSRange(location: 0, length: location), deadline: deadline, isCancelled: isCancelled)
    }

    func replacements(in text: NSString, template: String, isCancelled: () -> Bool = { false }) throws -> [(range: NSRange, text: String)] {
        var result: [(NSRange, String)] = []
        try enumerate(in: text, range: NSRange(location: 0, length: text.length), isCancelled: isCancelled) { match in
            result.append((match.range, options.regex ? expression.replacementString(for: match, in: text as String, offset: 0, template: template) : template))
            return true
        }
        return result
    }

    func replacement(for range: NSRange, in text: NSString, template: String) throws -> String {
        guard options.regex else { return template }
        var found: NSTextCheckingResult?
        try enumerate(in: text, range: range, anchored: true) { match in
            found = match
            return false
        }
        guard let found else { return template }
        return expression.replacementString(for: found, in: text as String, offset: 0, template: template)
    }

    private func first(in text: NSString, range: NSRange, deadline: Date, isCancelled: () -> Bool) throws -> NSRange? {
        var found: NSRange?
        try enumerate(in: text, range: range, deadline: deadline, isCancelled: isCancelled) { match in
            found = match.range
            return false
        }
        return found
    }

    private func enumerate(in text: NSString, range: NSRange, anchored: Bool = false, deadline: Date = Date(timeIntervalSinceNow: timeLimit), isCancelled: () -> Bool = { false }, _ body: (NSTextCheckingResult) -> Bool) throws {
        var timedOut = false
        expression.enumerateMatches(in: text as String, options: anchored ? [.reportProgress, .anchored] : .reportProgress, range: range) { result, _, stop in
            if Date() > deadline || isCancelled() {
                timedOut = true
                stop.pointee = true
            } else if let result, result.range.length > 0, !body(result) {
                stop.pointee = true
            }
        }
        if timedOut { throw TimedOut() }
    }
}
