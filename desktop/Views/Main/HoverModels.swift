import SwiftUI
import Foundation

struct DiagnosticAction: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let filePath: String
    let line: Int
    let column: Int
}

enum HoverDocBlock: Identifiable, Hashable {
    case heading(id: Int, level: Int, text: String)
    case bullet(id: Int, text: String)
    case codeBlock(id: Int, code: String)
    case paragraph(id: Int, text: String)

    var id: Int {
        switch self {
        case .heading(let id, _, _),
             .bullet(let id, _),
             .codeBlock(let id, _),
             .paragraph(let id, _):
            return id
        }
    }
}

struct HoverContent {
    var severity: Int? = nil
    var diagnosticMessage: String? = nil
    var signature: String? = nil
    var documentation: String = ""
    var pkgGoDevURL: (label: String, url: URL)? = nil
    var actions: [DiagnosticAction] = []
    var upgradableModule: String? = nil
    var rawText: String = ""
}

func parseUpgradableModuleFromDiagnostic(_ message: String) -> String? {
    let lines = message.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " can be upgraded") {
            let prefix = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = prefix.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if let candidate = tokens.last, candidate.contains("/") || candidate.contains(".") {
                return candidate
            }
        }
    }
    return nil
}

func parseHoverDocBlocks(_ documentation: String) -> [HoverDocBlock] {
    let rawLines = documentation.components(separatedBy: .newlines)
    var blocks: [HoverDocBlock] = []
    var nextID = 0
    var paragraphLines: [String] = []
    var inCodeFence = false
    var codeFenceLines: [String] = []

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        paragraphLines.removeAll()
        if !joined.isEmpty {
            blocks.append(.paragraph(id: nextID, text: joined))
            nextID += 1
        }
    }

    func flushCodeBlock() {
        let code = codeFenceLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        codeFenceLines.removeAll()
        if !code.isEmpty {
            blocks.append(.codeBlock(id: nextID, code: code))
            nextID += 1
        }
    }

    for rawLine in rawLines {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flushParagraph()
            if inCodeFence {
                flushCodeBlock()
                inCodeFence = false
            } else {
                inCodeFence = true
            }
            continue
        }

        if inCodeFence {
            codeFenceLines.append(rawLine)
            continue
        }

        if trimmed.isEmpty {
            flushParagraph()
            continue
        }

        if (rawLine.hasPrefix("\t") || rawLine.hasPrefix("    ")) && paragraphLines.isEmpty {
            let unindented = rawLine.hasPrefix("\t")
                ? String(rawLine.dropFirst())
                : String(rawLine.dropFirst(4))
            if case .codeBlock(let prevID, let prevCode) = blocks.last {
                blocks.removeLast()
                blocks.append(.codeBlock(id: prevID, code: prevCode + "\n" + unindented))
            } else {
                blocks.append(.codeBlock(id: nextID, code: unindented))
                nextID += 1
            }
            continue
        }

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let level = hashes.count
            let afterHashes = trimmed.dropFirst(level)
            if level >= 1 && level <= 6 && (afterHashes.isEmpty || afterHashes.first?.isWhitespace == true) {
                flushParagraph()
                let headingText = afterHashes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !headingText.isEmpty {
                    blocks.append(.heading(id: nextID, level: level, text: headingText))
                    nextID += 1
                }
                continue
            }
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            flushParagraph()
            let bulletText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !bulletText.isEmpty {
                blocks.append(.bullet(id: nextID, text: bulletText))
                nextID += 1
            }
            continue
        }

        paragraphLines.append(trimmed)
    }

    if inCodeFence {
        flushCodeBlock()
    }
    flushParagraph()
    return blocks
}

func parseDiagnosticActions(from message: String) -> [DiagnosticAction] {
    var actions: [DiagnosticAction] = []
    let lines = message.components(separatedBy: .newlines)
    for lineText in lines {
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("other declaration") || trimmed.contains("previous declaration") || trimmed.contains("redeclared") || trimmed.contains("redefinition") else {
            continue
        }
        
        let parts = trimmed.components(separatedBy: ":")
        if parts.count >= 3 {
            let possiblePath = parts[0].trimmingCharacters(in: .whitespaces)
            if FileManager.default.fileExists(atPath: possiblePath) {
                let line = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 1
                let col = parts.count >= 4 ? (Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 1) : 1
                actions.append(DiagnosticAction(
                    title: "Navigate to duplicate line",
                    filePath: possiblePath,
                    line: line,
                    column: col
                ))
            }
        }
    }
    return actions
}

func parseSymbolPkgGoDevURL(from text: String) -> (label: String, url: URL)? {
    let lines = text.components(separatedBy: .newlines)
    var pkgName: String? = nil
    var symbolName: String? = nil
    
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("package ") {
            pkgName = trimmed.replacingOccurrences(of: "package ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("func ") {
            let namePart = trimmed.replacingOccurrences(of: "func ", with: "")
            if let openParen = namePart.firstIndex(of: "(") {
                let candidate = String(namePart[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.contains(")") {
                    if let closeParen = candidate.range(of: ")", options: .backwards) {
                        symbolName = String(candidate[closeParen.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else {
                    symbolName = candidate
                }
            }
        } else if trimmed.hasPrefix("type ") {
            let namePart = trimmed.replacingOccurrences(of: "type ", with: "")
            let parts = namePart.components(separatedBy: .whitespaces)
            if !parts.isEmpty {
                symbolName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    
    if let pkg = pkgName, let sym = symbolName, !pkg.isEmpty && !sym.isEmpty {
        if pkg != "main" {
            let cleanSym = sym.components(separatedBy: ".").last ?? sym
            let urlString = "https://pkg.go.dev/\(pkg)#\(cleanSym)"
            if let url = URL(string: urlString) {
                return (cleanSym, url)
            }
        }
    }
    return nil
}

func parseHoverText(_ text: String) -> HoverContent {
    var content = HoverContent(rawText: text)
    var remainingText = text
    
    if text.hasPrefix("### Error\n") {
        content.severity = 1
        let prefix = "### Error\n"
        remainingText = String(text.dropFirst(prefix.count))
    } else if text.hasPrefix("### Warning\n") {
        content.severity = 2
        let prefix = "### Warning\n"
        remainingText = String(text.dropFirst(prefix.count))
    } else if text.hasPrefix("### Info\n") {
        content.severity = 3
        let prefix = "### Info\n"
        remainingText = String(text.dropFirst(prefix.count))
    } else if text.hasPrefix("### Hint\n") {
        content.severity = 4
        let prefix = "### Hint\n"
        remainingText = String(text.dropFirst(prefix.count))
    }
    
    if content.severity != nil {
        if let dividerIndex = remainingText.range(of: "\n\n---\n\n") {
            content.diagnosticMessage = remainingText[..<dividerIndex.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            remainingText = String(remainingText[dividerIndex.upperBound...])
        } else {
            content.diagnosticMessage = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
            remainingText = ""
        }
    }
    
    if remainingText.hasPrefix("```go\n") {
        let parts = remainingText.components(separatedBy: "```")
        if parts.count >= 3 {
            let rawSig = parts[1]
            content.signature = rawSig.replacingOccurrences(of: "go\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            content.documentation = parts[2...].joined(separator: "```").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    } else if remainingText.contains("```go\n") {
        let parts = remainingText.components(separatedBy: "```go\n")
        if parts.count >= 2 {
            let prefix = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let subparts = parts[1].components(separatedBy: "```")
            if subparts.count >= 1 {
                content.signature = subparts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = subparts[1...].joined(separator: "```").trimmingCharacters(in: .whitespacesAndNewlines)
                content.documentation = prefix + "\n\n" + suffix
            }
        }
    } else {
        content.documentation = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    let docLines = content.documentation.components(separatedBy: .newlines)
    var filteredDocLines: [String] = []
    for line in docLines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isDivider = trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "—" || $0 == "*" || $0 == "_" })
        if !isDivider {
            filteredDocLines.append(line)
        }
    }
    content.documentation = filteredDocLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    
    if let diagMsg = content.diagnosticMessage {
        content.actions = parseDiagnosticActions(from: diagMsg)
        content.upgradableModule = parseUpgradableModuleFromDiagnostic(diagMsg)
    }
    
    if let sig = content.signature {
        if let devLink = parseSymbolPkgGoDevURL(from: sig) {
            content.pkgGoDevURL = devLink
        }
    } else if !content.documentation.isEmpty {
        if let devLink = parseSymbolPkgGoDevURL(from: content.documentation) {
            content.pkgGoDevURL = devLink
        }
    }
    
    return content
}

func highlightGoCode(_ text: String, isDark: Bool) -> AttributedString {
    var attrStr = HighlightedCodeText.attributed(text, isDark: isDark)
    attrStr.font = .subheadline.weight(.semibold).monospaced()
    return attrStr
}
