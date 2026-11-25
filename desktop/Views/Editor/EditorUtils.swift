import SwiftUI
import AppKit
import GoLensFoundation

func toggleComment(in textView: NSTextView) {
    guard let textStorage = textView.textStorage else { return }
    let selectedRange = textView.selectedRange()
    guard selectedRange.location != NSNotFound else { return }
    
    let filePath = (textView as? GoLensTextView)?.filePath ?? ((textView as? GoLensTextView)?.workspaceState ?? WorkspaceState.shared).activeFilePath
    let filename = (filePath as NSString).lastPathComponent.lowercased()
    let ext = (filePath as NSString).pathExtension.lowercased()
    
    let htmlCommentExts: Set<String> = ["html", "tmpl", "gotmpl", "xml", "md", "markdown", "svg"]
    let sqlCommentExts: Set<String> = ["sql", "cql"]
    let hashCommentExts: Set<String> = [
        "yml", "yaml", "sh", "bash", "zsh", "env", "local", "beta",
        "properties", "toml", "py", "mk", "gitignore", "dockerignore",
        "editorconfig", "dockerfile", "ini", "conf"
    ]
    let isHashCommentFile = hashCommentExts.contains(ext) ||
        filename == "dockerfile" || filename == "makefile" || filename == "gnumakefile" ||
        filename == ".gitignore" || filename == ".dockerignore" || filename == ".editorconfig" ||
        filename.hasPrefix(".env") || filename.hasPrefix("dockerfile.")
    
    let string = textView.string
    let nsString = string as NSString
    
    let lineRange = nsString.lineRange(for: selectedRange)
    let selectedText = nsString.substring(with: lineRange)
    
    let lines = selectedText.components(separatedBy: .newlines)
    var newLines: [String] = []
    
    if htmlCommentExts.contains(ext) {
        var allCommented = true
        var hasNonEmpty = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                hasNonEmpty = true
                if !(trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")) {
                    allCommented = false
                    break
                }
            }
        }
        if !hasNonEmpty {
            allCommented = false
        }
        
        if allCommented {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") {
                    var updated = line
                    if let openRange = updated.range(of: "<!-- ") ?? updated.range(of: "<!--") {
                        updated.removeSubrange(openRange)
                    }
                    if let closeRange = updated.range(of: " -->", options: .backwards) ?? updated.range(of: "-->", options: .backwards) {
                        updated.removeSubrange(closeRange)
                    }
                    newLines.append(updated)
                } else {
                    newLines.append(line)
                }
            }
        } else {
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !hasNonEmpty && idx == 0 {
                        newLines.append("<!-- " + line + " -->")
                    } else {
                        newLines.append(line)
                    }
                } else {
                    newLines.append("<!-- " + line + " -->")
                }
            }
        }
    } else {
        let commentPrefix: String
        if sqlCommentExts.contains(ext) {
            commentPrefix = "--"
        } else if isHashCommentFile {
            commentPrefix = "#"
        } else {
            commentPrefix = "//"
        }
        
        var allCommented = true
        var hasNonEmpty = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                hasNonEmpty = true
                if !trimmed.hasPrefix(commentPrefix) {
                    allCommented = false
                    break
                }
            }
        }
        if !hasNonEmpty {
            allCommented = false
        }
        
        if allCommented {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(commentPrefix), let prefixRange = line.range(of: commentPrefix) {
                    var lineWithoutPrefix = line
                    let spaceIndex = prefixRange.lowerBound
                    lineWithoutPrefix.removeSubrange(prefixRange)
                    if spaceIndex < lineWithoutPrefix.endIndex && lineWithoutPrefix[spaceIndex] == " " {
                        lineWithoutPrefix.remove(at: spaceIndex)
                    }
                    newLines.append(lineWithoutPrefix)
                } else {
                    newLines.append(line)
                }
            }
        } else {
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty && idx == lines.count - 1 && line == "" && lines.count > 1 {
                    newLines.append(line)
                } else {
                    newLines.append(commentPrefix + " " + line)
                }
            }
        }
    }
    
    let replacement = newLines.joined(separator: "\n")
    
    if textView.shouldChangeText(in: lineRange, replacementString: replacement) {
        textStorage.replaceCharacters(in: lineRange, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName("Comment/Uncomment Selection")

        let newSelection = NSRange(location: lineRange.location, length: replacement.utf16.count)
        textView.setSelectedRange(newSelection)
    }
}

func editorIndentUnit(forPath filePath: String, tabSize: Int) -> String {
    let filename = (filePath as NSString).lastPathComponent.lowercased()
    let ext = (filePath as NSString).pathExtension.lowercased()
    if ext == "go" || filename == "makefile" || filename == "gnumakefile" || ext == "mk" || filename == "go.mod" || filename == "go.work" {
        return "\t"
    }
    if ["yml", "yaml", "json", "jsonc", "html", "tmpl", "gotmpl", "xml", "md", "markdown", "svg"].contains(ext) {
        return "  "
    }
    return String(repeating: " ", count: tabSize)
}

private func lineCommentContinuation(in ns: NSString, selection: NSRange, lineBeforeCaret: String) -> (range: NSRange, text: String)? {
    var start = 0, end = 0, contentsEnd = 0
    ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: NSMaxRange(selection), length: 0))
    let caret = NSMaxRange(selection)
    let after = ns.substring(with: NSRange(location: caret, length: contentsEnd - caret))
    var nextLine: String?
    if end < ns.length {
        let next = ns.lineRange(for: NSRange(location: end, length: 0))
        nextLine = ns.substring(with: next)
    }
    guard let prefix = LineCommentContinuation.prefix(lineBeforeCaret: lineBeforeCaret, lineAfterCaret: after, nextLine: nextLine) else { return nil }
    let skipped = (after.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
    return (NSRange(location: selection.location, length: selection.length + skipped), "\n" + prefix)
}

func handleNewlineAutoIndentation(in textView: NSTextView) -> Bool {
    guard let textStorage = textView.textStorage else { return false }
    let selectedRange = textView.selectedRange()
    guard selectedRange.location != NSNotFound else { return false }
    
    let string = textView.string
    let nsString = string as NSString
    
    let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
    let lengthBeforeCursor = selectedRange.location - lineRange.location
    guard lengthBeforeCursor >= 0 else { return false }
    let lineBeforeCursor = nsString.substring(with: NSRange(location: lineRange.location, length: lengthBeforeCursor))
    
    var leadingWhitespace = ""
    for char in lineBeforeCursor {
        if char == " " || char == "\t" {
            leadingWhitespace.append(char)
        } else {
            break
        }
    }
    
    let tabSize = ((textView as? GoLensTextView)?.workspaceState ?? WorkspaceState.shared).tabSize
    let filePath = (textView as? GoLensTextView)?.filePath ?? ((textView as? GoLensTextView)?.workspaceState ?? WorkspaceState.shared).activeFilePath
    let filename = (filePath as NSString).lastPathComponent.lowercased()
    let ext = (filePath as NSString).pathExtension.lowercased()
    let indentSpaces: String
    if ext == "go" || filename == "makefile" || filename == "gnumakefile" || ext == "mk" || filename == "go.mod" || filename == "go.work" {
        indentSpaces = "\t"
    } else if ["yml", "yaml", "json", "jsonc", "html", "tmpl", "gotmpl", "xml", "md", "markdown", "svg"].contains(ext) {
        indentSpaces = "  "
    } else {
        indentSpaces = String(repeating: " ", count: tabSize)
    }
    
    if ext == "go", let continued = lineCommentContinuation(in: nsString, selection: selectedRange, lineBeforeCaret: lineBeforeCursor) {
        guard textView.shouldChangeText(in: continued.range, replacementString: continued.text) else { return false }
        textStorage.replaceCharacters(in: continued.range, with: continued.text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: continued.range.location + (continued.text as NSString).length, length: 0))
        return true
    }

    var isBetweenPair = false
    if selectedRange.location > 0 && selectedRange.location < nsString.length {
        let prevChar = nsString.substring(with: NSRange(location: selectedRange.location - 1, length: 1))
        let nextChar = nsString.substring(with: NSRange(location: selectedRange.location, length: 1))
        if (prevChar == "{" && nextChar == "}") ||
           (prevChar == "(" && nextChar == ")") ||
           (prevChar == "[" && nextChar == "]") {
            isBetweenPair = true
        }
    }
    
    let replacementString: String
    let cursorOffset: Int
    
    if isBetweenPair {
        replacementString = "\n" + leadingWhitespace + indentSpaces + "\n" + leadingWhitespace
        cursorOffset = 1 + leadingWhitespace.utf16.count + indentSpaces.utf16.count
    } else {
        let trimmedLine = lineBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        var extraIndent = ""
        let isComment = trimmedLine.hasPrefix("#") || trimmedLine.hasPrefix("//") || trimmedLine.hasPrefix("--")
        if !isComment {
            if (ext == "yml" || ext == "yaml") && trimmedLine.hasPrefix("- ") && trimmedLine.hasSuffix(":") {
                extraIndent = "    "
            } else if trimmedLine.hasSuffix("{") || trimmedLine.hasSuffix("(") || trimmedLine.hasSuffix("[") || trimmedLine.hasSuffix(":") {
                extraIndent = indentSpaces
            }
        }
        replacementString = "\n" + leadingWhitespace + extraIndent
        cursorOffset = replacementString.utf16.count
    }
    
    if textView.shouldChangeText(in: selectedRange, replacementString: replacementString) {
        textStorage.replaceCharacters(in: selectedRange, with: replacementString)
        textView.didChangeText()
        
        let newCursorPos = selectedRange.location + cursorOffset
        textView.setSelectedRange(NSRange(location: newCursorPos, length: 0))
        return true
    }
    
    return false
}
