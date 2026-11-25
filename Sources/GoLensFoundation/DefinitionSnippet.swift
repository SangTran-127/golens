import Foundation

public struct DefinitionSnippet: Equatable, Sendable {
    public var firstLine: Int
    public var code: String
    public var truncated: Bool

    public init(firstLine: Int, code: String, truncated: Bool) {
        self.firstLine = firstLine
        self.code = code
        self.truncated = truncated
    }

    public static func extract(text: String, line: Int, maxLines: Int = 40, tabWidth: Int = 4) -> DefinitionSnippet? {
        let src = SourceLines(text)
        guard line >= 0, line < src.count, !src.isTrailingEmptyLine(line) else { return nil }
        let info = StatementMover.scan(src)
        let depth = info[line].depthBefore
        var start = line
        while start > 0 && info[start - 1].comment && info[start - 1].depthBefore == depth { start -= 1 }
        var end = line
        while info[end].depthAfter > depth && end + 1 < src.count && info[end + 1].depthBefore + info[end + 1].lowest >= depth {
            end += 1
        }
        let last = min(end, start + max(1, maxLines) - 1)
        let lines = (start...last).map { src.content($0) }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" } }
            .reduce(nil as Substring?) { common, next in
                guard let common else { return next }
                return Substring(zip(common, next).prefix { $0 == $1 }.map(\.0))
            } ?? ""
        let spaces = String(repeating: " ", count: tabWidth)
        let code = lines.map { raw -> String in
            let body = raw.hasPrefix(indent) ? String(raw.dropFirst(indent.count)) : raw.trimmingCharacters(in: .whitespaces)
            let lead = body.prefix { $0 == "\t" }
            return String(repeating: spaces, count: lead.count) + body.dropFirst(lead.count)
        }.joined(separator: "\n")
        return DefinitionSnippet(firstLine: start, code: code, truncated: last < end)
    }
}
