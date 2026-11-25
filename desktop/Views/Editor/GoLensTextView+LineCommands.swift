import AppKit
import GoLensFoundation

extension GoLensTextView {
    static func runLineCommand(fallback: NSTextView?, _ command: (GoLensTextView) -> Void) {
        let responder = NSApp.keyWindow?.firstResponder
        if let editor = responder as? GoLensTextView {
            command(editor)
            return
        }
        if let event = NSApp.currentEvent, event.type == .keyDown, let view = responder as? NSView {
            view.keyDown(with: event)
            return
        }
        if let editor = fallback as? GoLensTextView { command(editor) }
    }

    func joinLines() {
        let title = "Join Lines"
        guard !hasMultipleCursors else {
            workspaceState.presentCommandFeedback("Join Lines works with one cursor. Press Esc to return to a single cursor.", title: title)
            return
        }
        guard let edit = LineJoiner.join(text: string, selection: selectedRange()) else {
            workspaceState.presentCommandFeedback("There is no line below the caret to join.", title: title)
            return
        }
        apply(edit, title: title)
    }

    func moveStatement(up: Bool) {
        let title = up ? "Move Statement Up" : "Move Statement Down"
        guard filePath.hasSuffix(".go") else {
            workspaceState.presentCommandFeedback("\(title) works in Go files. Use Move Line in other files.", title: title)
            return
        }
        guard !hasMultipleCursors else {
            workspaceState.presentCommandFeedback("\(title) works with one cursor. Press Esc to return to a single cursor.", title: title)
            return
        }
        guard let edit = StatementMover.move(text: string, selection: selectedRange(), up: up) else {
            let edge = up ? "first" : "last"
            workspaceState.presentCommandFeedback("This statement is already the \(edge) one in its block. Use Move Line to move it out of the block.", title: title)
            return
        }
        apply(edit, title: title)
    }

    func moveLine(up: Bool) {
        let selection = selectedRange()
        guard selection.location != NSNotFound, !hasMultipleCursors else { return }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: selection)
        var lines = ns.substring(with: lineRange)
        if !lines.hasSuffix("\n") { lines += "\n" }
        let offset = selection.location - lineRange.location
        if up {
            guard lineRange.location > 0 else { return }
            let previous = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            var previousText = ns.substring(with: previous)
            if !previousText.hasSuffix("\n") { previousText += "\n" }
            let range = NSRange(location: previous.location, length: previous.length + lineRange.length)
            let replacement = trimmedToRange(lines + previousText, range: range, in: ns)
            apply(LineEdit(range: range, replacement: replacement, selection: NSRange(location: previous.location + offset, length: selection.length)), title: "Move Line Up")
        } else {
            let end = NSMaxRange(lineRange)
            guard end < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n" }
            let range = NSRange(location: lineRange.location, length: lineRange.length + next.length)
            let replacement = trimmedToRange(nextText + lines, range: range, in: ns)
            apply(LineEdit(range: range, replacement: replacement, selection: NSRange(location: lineRange.location + (nextText as NSString).length + offset, length: selection.length)), title: "Move Line Down")
        }
    }

    private func trimmedToRange(_ text: String, range: NSRange, in ns: NSString) -> String {
        let endsFile = NSMaxRange(range) == ns.length
        let hadNewline = endsFile ? ns.substring(with: range).hasSuffix("\n") : true
        return hadNewline ? text : String(text.dropLast())
    }

    private func apply(_ edit: LineEdit, title: String) {
        guard let textStorage else { return }
        CompletionController.shared.dismiss()
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        undoManager?.setActionName(title)
        breakUndoCoalescing()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }
}
