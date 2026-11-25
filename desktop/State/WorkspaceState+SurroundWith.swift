import AppKit

struct SurroundOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let body: String
    let wrapsLines: Bool

    static let builtIns: [SurroundOption] = [
        SurroundOption(id: "if", title: "if", detail: "Run the lines only when a condition holds",
                       body: "if ${1:condition} {\n\t$TM_SELECTED_TEXT\n}$0", wrapsLines: true),
        SurroundOption(id: "for", title: "for", detail: "Repeat the lines in a loop",
                       body: "for ${1:condition} {\n\t$TM_SELECTED_TEXT\n}$0", wrapsLines: true),
        SurroundOption(id: "func", title: "func() { }()", detail: "Run the lines in a function literal called at once",
                       body: "func() {\n\t$TM_SELECTED_TEXT\n}()$0", wrapsLines: true),
        SurroundOption(id: "go", title: "go func() { }()", detail: "Run the lines in a new goroutine",
                       body: "go func() {\n\t$TM_SELECTED_TEXT\n}()$0", wrapsLines: true),
        SurroundOption(id: "defer", title: "defer func() { }()", detail: "Run the lines when the function returns",
                       body: "defer func() {\n\t$TM_SELECTED_TEXT\n}()$0", wrapsLines: true),
        SurroundOption(id: "paren", title: "( )", detail: "Parenthesize the expression",
                       body: "($TM_SELECTED_TEXT)$0", wrapsLines: false),
    ]

    static func fromTemplate(_ template: LiveTemplate) -> SurroundOption {
        let wraps = template.body.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "$TM_SELECTED_TEXT" || trimmed == "${TM_SELECTED_TEXT}"
        }
        return SurroundOption(id: "template:\(template.id)", title: template.abbreviation, detail: template.description,
                              body: template.body, wrapsLines: wraps)
    }

    static var all: [SurroundOption] {
        builtIns + LiveTemplateStore.shared.surroundTemplates.map(fromTemplate)
    }
}

extension WorkspaceState {
    func presentSurroundWith() {
        guard let textView = activeTextView as? GoLensTextView, textView.filePath.hasSuffix(".go"), textView.document != nil else {
            presentCommandFeedback("Surround With works in Go files. Open one and select the lines or expression to wrap.", title: "Surround With")
            return
        }
        searchNav.surroundTextView = textView
        searchNav.surroundSelection = textView.selectedRange()
        activePopup = .surroundWith
    }

    func surround(with option: SurroundOption) {
        let textView = searchNav.surroundTextView
        let selection = searchNav.surroundSelection
        activePopup = nil
        guard let textView, let doc = textView.document, let selection, NSMaxRange(selection) <= doc.length else { return }
        let ns: NSString = doc.storage.mutableString
        var range = selection
        if option.wrapsLines || selection.length == 0 {
            var lines = ns.lineRange(for: selection.length > 0 ? NSRange(location: selection.location, length: selection.length - 1) : selection)
            while lines.length > 0, [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(lines) - 1)) {
                lines.length -= 1
            }
            var start = lines.location
            while start < NSMaxRange(lines), [0x20, 0x09].contains(ns.character(at: start)) { start += 1 }
            range = NSRange(location: start, length: NSMaxRange(lines) - start)
        }
        let selected = ns.substring(with: range)
        textView.window?.makeFirstResponder(textView)
        CompletionController.shared.expandTemplate(option.body, replacing: range, selection: firstLineIndented(selected, in: ns, at: range.location),
                                                   in: textView, actionName: "Surround With")
    }

    private func firstLineIndented(_ text: String, in ns: NSString, at location: Int) -> String {
        let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
        let indent = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
        guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { return text }
        return indent + text
    }
}
