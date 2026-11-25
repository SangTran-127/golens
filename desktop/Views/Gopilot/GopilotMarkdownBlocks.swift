import Foundation

enum GopilotMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [GopilotListItem])
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule

    static func parse(_ source: String) -> [GopilotMarkdownBlock] {
        var blocks: [GopilotMarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let rawLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                let language = rawLang.isEmpty ? nil : rawLang
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                if !code.isEmpty {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                }
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if listMarker(line) != nil {
                flushParagraph()
                var items: [GopilotListItem] = []
                while index < lines.count {
                    if let marker = listMarker(lines[index]) {
                        items.append(
                            GopilotListItem(
                                marker: marker.marker,
                                indent: marker.indent,
                                text: marker.text,
                                isOrdered: marker.isOrdered
                            )
                        )
                        index += 1
                    } else {
                        let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                        let leadingSpaces = lines[index].prefix { $0 == " " }.count
                        if !nextTrimmed.isEmpty,
                           leadingSpaces >= 2,
                           !nextTrimmed.hasPrefix("```"),
                           headingLevel(nextTrimmed) == nil,
                           !items.isEmpty {
                            let last = items.removeLast()
                            items.append(
                                GopilotListItem(
                                    marker: last.marker,
                                    indent: last.indent,
                                    text: last.text + " " + nextTrimmed,
                                    isOrdered: last.isOrdered
                                )
                            )
                            index += 1
                        } else {
                            break
                        }
                    }
                }
                blocks.append(.list(items: items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func listMarker(_ line: String) -> (marker: String, indent: Int, text: String, isOrdered: Bool)? {
        let indent = line.prefix { $0 == " " }.count / 2
        let body = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return ("•", indent, String(body.dropFirst(2)), false)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (String(digits) + ".", indent, String(rest.dropFirst(2)), true)
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct GopilotListItem: Equatable {
    let marker: String
    let indent: Int
    let text: String
    var isOrdered: Bool = false
}
