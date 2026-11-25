import SwiftUI
import Foundation

struct MarkdownParsedDocument {
    let blocks: [MarkdownBlock]
    let headings: [MarkdownHeadingOutlineItem]
}

struct MarkdownHeadingOutlineItem: Identifiable, Equatable {
    let id: String
    let blockID: String
    let level: Int
    let title: String
    let slug: String
}

enum GFMAlertKind: String, Equatable {
    case note = "NOTE"
    case tip = "TIP"
    case important = "IMPORTANT"
    case warning = "WARNING"
    case caution = "CAUTION"

    var title: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    var symbolName: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.bubble.fill"
        case .warning: return StatusTone.warning.symbol
        case .caution: return StatusTone.failure.symbol
        }
    }

    var tintColor: Color {
        switch self {
        case .note: return .blue
        case .tip: return StatusTone.success.tint
        case .important: return .purple
        case .warning: return StatusTone.warning.tint
        case .caution: return StatusTone.failure.tint
        }
    }
}

enum GFMTableAlignment: Equatable {
    case leading
    case center
    case trailing

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

struct GFMListItem: Identifiable, Equatable {
    let id: String
    let indentLevel: Int
    let isOrdered: Bool
    let orderNumber: Int
    let taskState: Bool?
    let sourceLineIndex: Int
    let text: String
}

enum MarkdownBlock: Identifiable {
    case heading(id: String, level: Int, text: String, slug: String)
    case paragraph(id: String, text: String)
    case codeBlock(id: String, language: String, code: String)
    case mermaid(id: String, code: String)
    case alert(id: String, kind: GFMAlertKind, bodyBlocks: [MarkdownBlock])
    case blockquote(id: String, bodyBlocks: [MarkdownBlock])
    case table(id: String, headers: [String], alignments: [GFMTableAlignment], rows: [[String]])
    case list(id: String, items: [GFMListItem])
    case image(id: String, alt: String, path: String)
    case thematicBreak(id: String)

    var id: String {
        switch self {
        case .heading(let id, _, _, _),
             .paragraph(let id, _),
             .codeBlock(let id, _, _),
             .mermaid(let id, _),
             .alert(let id, _, _),
             .blockquote(let id, _),
             .table(let id, _, _, _),
             .list(let id, _),
             .image(let id, _, _),
             .thematicBreak(let id):
            return id
        }
    }
}

enum GFMParser {
    static func parseDocument(_ text: String, idPrefix: String = "md") -> MarkdownParsedDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var headings: [MarkdownHeadingOutlineItem] = []

        var i = 0
        var blockCounter = 0

        func nextID(_ kind: String) -> String {
            blockCounter += 1
            return "\(idPrefix)-\(kind)-\(blockCounter)"
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let fence = parseFenceOpening(trimmed) {
                let lang = fence.language
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if isFenceClosing(candidate, fenceChar: fence.char, minCount: fence.count) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let codeContent = codeLines.joined(separator: "\n")
                if lang.lowercased() == "mermaid" {
                    blocks.append(.mermaid(id: nextID("mermaid"), code: codeContent))
                } else {
                    blocks.append(.codeBlock(id: nextID("code"), language: lang, code: codeContent))
                }
                continue
            }

            if let heading = parseHeading(trimmed) {
                let slug = slugify(heading.text)
                let blockID = "\(nextID("heading"))-\(slug)"
                blocks.append(.heading(id: blockID, level: heading.level, text: heading.text, slug: slug))
                if heading.level <= 4 {
                    headings.append(
                        MarkdownHeadingOutlineItem(
                            id: blockID,
                            blockID: blockID,
                            level: heading.level,
                            title: stripInlineMarkdownFormatting(heading.text),
                            slug: slug
                        )
                    )
                }
                i += 1
                continue
            }

            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak(id: nextID("hr")))
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let currentTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard currentTrimmed.hasPrefix(">") else { break }
                    let stripped = stripLeadingBlockquoteMarker(currentTrimmed)
                    quoteLines.append(stripped)
                    i += 1
                }

                if let firstLine = quoteLines.first,
                   let alertMatch = parseAlertMarker(firstLine) {
                    var bodyLines = Array(quoteLines.dropFirst())
                    if !alertMatch.inlineRemainder.isEmpty {
                        bodyLines.insert(alertMatch.inlineRemainder, at: 0)
                    }
                    let nested = parseDocument(bodyLines.joined(separator: "\n"), idPrefix: nextID("alert-inner"))
                    blocks.append(.alert(id: nextID("alert"), kind: alertMatch.kind, bodyBlocks: nested.blocks))
                } else {
                    let nested = parseDocument(quoteLines.joined(separator: "\n"), idPrefix: nextID("quote-inner"))
                    blocks.append(.blockquote(id: nextID("quote"), bodyBlocks: nested.blocks))
                }
                continue
            }

            if i + 1 < lines.count,
               trimmed.contains("|"),
               let alignments = parseTableSeparatorRow(lines[i + 1]) {
                let headerCells = parseTableRowCells(line, targetCount: alignments.count)
                i += 2
                var bodyRows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || !rowTrimmed.contains("|") || rowTrimmed.hasPrefix(">") || parseFenceOpening(rowTrimmed) != nil {
                        break
                    }
                    bodyRows.append(parseTableRowCells(rowLine, targetCount: alignments.count))
                    i += 1
                }
                blocks.append(.table(id: nextID("table"), headers: headerCells, alignments: alignments, rows: bodyRows))
                continue
            }

            if parseListItemLine(lines[i], lineIndex: i) != nil {
                var listItems: [GFMListItem] = []
                while i < lines.count {
                    if let parsedItem = parseListItemLine(lines[i], lineIndex: i) {
                        listItems.append(parsedItem)
                        i += 1
                    } else if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        if i + 1 < lines.count, parseListItemLine(lines[i + 1], lineIndex: i + 1) != nil {
                            i += 1
                            continue
                        }
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.list(id: nextID("list"), items: listItems))
                continue
            }

            if let imageMatch = parseStandaloneImage(trimmed) {
                blocks.append(.image(id: nextID("img"), alt: imageMatch.alt, path: imageMatch.path))
                i += 1
                continue
            }

            var paraLines: [String] = []
            while i < lines.count {
                let candidate = lines[i]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty
                    || parseFenceOpening(candidateTrimmed) != nil
                    || parseHeading(candidateTrimmed) != nil
                    || candidateTrimmed.hasPrefix(">")
                    || parseListItemLine(candidate, lineIndex: i) != nil
                    || parseStandaloneImage(candidateTrimmed) != nil
                    || (isThematicBreak(candidateTrimmed) && paraLines.isEmpty) {
                    break
                }
                if i + 1 < lines.count,
                   candidateTrimmed.contains("|"),
                   parseTableSeparatorRow(lines[i + 1]) != nil {
                    break
                }
                paraLines.append(candidateTrimmed)
                i += 1
            }

            if !paraLines.isEmpty {
                let joined = paraLines.joined(separator: " ")
                blocks.append(.paragraph(id: nextID("para"), text: joined))
            } else {
                i += 1
            }
        }

        return MarkdownParsedDocument(blocks: blocks, headings: headings)
    }

    static func slugify(_ raw: String) -> String {
        let stripped = stripInlineMarkdownFormatting(raw).lowercased()
        var result = ""
        var prevHyphen = false
        for scalar in stripped.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                prevHyphen = false
            } else if scalar == " " || scalar == "-" || scalar == "_" {
                if !prevHyphen && !result.isEmpty {
                    result.append("-")
                    prevHyphen = true
                }
            }
        }
        if result.hasSuffix("-") {
            result.removeLast()
        }
        return result.isEmpty ? "section" : result
    }

    static func stripInlineMarkdownFormatting(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseFenceOpening(_ trimmed: String) -> (char: Character, count: Int, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fencePrefix = trimmed.prefix { $0 == first }
        guard fencePrefix.count >= 3 else { return nil }
        let remainder = trimmed.dropFirst(fencePrefix.count).trimmingCharacters(in: .whitespaces)
        if first == "`" && remainder.contains("`") {
            return nil
        }
        let langToken = remainder.split(separator: " ").first.map(String.init) ?? ""
        return (first, fencePrefix.count, langToken)
    }

    private static func isFenceClosing(_ trimmed: String, fenceChar: Character, minCount: Int) -> Bool {
        let prefix = trimmed.prefix { $0 == fenceChar }
        guard prefix.count >= minCount else { return false }
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty && hashes.count <= 6 else { return nil }
        let afterHashes = trimmed.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        var text = afterHashes.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return (hashes.count, text)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func stripLeadingBlockquoteMarker(_ trimmed: String) -> String {
        guard trimmed.hasPrefix(">") else { return trimmed }
        let after = trimmed.dropFirst()
        if after.first == " " {
            return String(after.dropFirst())
        }
        return String(after)
    }

    private static func parseAlertMarker(_ line: String) -> (kind: GFMAlertKind, inlineRemainder: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let token = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracket]).uppercased()
        guard let kind = GFMAlertKind(rawValue: token) else { return nil }
        let remainder = String(trimmed[trimmed.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
        return (kind, remainder)
    }

    private static func parseTableSeparatorRow(_ line: String) -> [GFMTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return nil }
        let rawCells = splitTableLine(trimmed)
        guard !rawCells.isEmpty else { return nil }

        var alignments: [GFMTableAlignment] = []
        for cell in rawCells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            let leftColon = c.hasPrefix(":")
            let rightColon = c.hasSuffix(":")
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 3 && core.allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func parseTableRowCells(_ line: String, targetCount: Int) -> [String] {
        var cells = splitTableLine(line.trimmingCharacters(in: .whitespaces))
        if cells.count < targetCount {
            cells.append(contentsOf: Array(repeating: "", count: targetCount - cells.count))
        } else if cells.count > targetCount {
            cells = Array(cells.prefix(targetCount))
        }
        return cells
    }

    private static func splitTableLine(_ trimmed: String) -> [String] {
        var working = trimmed
        if working.hasPrefix("|") {
            working.removeFirst()
        }
        if working.hasSuffix("|") && !working.hasSuffix("\\|") {
            working.removeLast()
        }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false

        for ch in working {
            if escaped {
                if ch == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(ch)
                }
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
                continue
            }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func parseListItemLine(_ line: String, lineIndex: Int) -> GFMListItem? {
        var leadingSpaces = 0
        for ch in line {
            if ch == " " {
                leadingSpaces += 1
            } else if ch == "\t" {
                leadingSpaces += 4
            } else {
                break
            }
        }
        let indentLevel = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if isThematicBreak(trimmed) {
            return nil
        }

        var isOrdered = false
        var orderNumber = 1
        var remainder: String? = nil

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            remainder = String(trimmed.dropFirst(2))
        } else {
            let digits = trimmed.prefix { $0.isNumber }
            if !digits.isEmpty, let num = Int(digits) {
                let afterDigits = trimmed.dropFirst(digits.count)
                if afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
                    isOrdered = true
                    orderNumber = num
                    remainder = String(afterDigits.dropFirst(2))
                }
            }
        }

        guard var itemText = remainder?.trimmingCharacters(in: .whitespaces) else { return nil }

        var taskState: Bool? = nil
        if itemText.hasPrefix("[ ] ") || itemText == "[ ]" {
            taskState = false
            itemText = String(itemText.dropFirst(min(4, itemText.count)))
        } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") || itemText == "[x]" || itemText == "[X]" {
            taskState = true
            itemText = String(itemText.dropFirst(min(4, itemText.count)))
        }

        return GFMListItem(
            id: "list-item-\(lineIndex)",
            indentLevel: indentLevel,
            isOrdered: isOrdered,
            orderNumber: orderNumber,
            taskState: taskState,
            sourceLineIndex: lineIndex,
            text: itemText
        )
    }

    private static func parseStandaloneImage(_ trimmed: String) -> (alt: String, path: String)? {
        guard trimmed.hasPrefix("![") && trimmed.hasSuffix(")") else { return nil }
        guard let midRange = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<midRange.lowerBound])
        var rawPath = String(trimmed[midRange.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        if let quoteIdx = rawPath.firstIndex(of: "\"") {
            rawPath = String(rawPath[..<quoteIdx]).trimmingCharacters(in: .whitespaces)
        }
        guard !rawPath.isEmpty else { return nil }
        return (alt, rawPath)
    }
}
