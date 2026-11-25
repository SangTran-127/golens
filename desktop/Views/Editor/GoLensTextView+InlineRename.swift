import AppKit
import GoLensFoundation

struct InlineRenameHint: Equatable {
    var name: String
    var usages: Int
    var message: String?
    var isSubmitting = false
}

final class InlineRenameSession {
    var model: LinkedRename
    let document: DocumentSession
    let originalSelection: NSRange
    let allowedUndo: Bool
    var isCommitting = false
    var isApplying = false
    var foreignEdit: (range: NSRange, newLength: Int)?

    init(model: LinkedRename, document: DocumentSession, originalSelection: NSRange, allowedUndo: Bool) {
        self.model = model
        self.document = document
        self.originalSelection = originalSelection
        self.allowedUndo = allowedUndo
    }
}

extension EditorCaretAnchor {
    func rename() {
        guard let editor else {
            (workspace ?? WorkspaceState.shared).presentCommandFeedback("Open a Go file in the editor to rename a symbol.", title: "Can’t Rename Here")
            return
        }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.triggerRename()
    }
}

extension WorkspaceState {
    func finishInlineRenames() {
        for view in [primaryTextView, secondaryTextView] {
            (view as? GoLensTextView)?.finishInlineRename()
        }
    }
}

extension GoLensTextView {
    func triggerRename() {
        guard inlineRename == nil else { return }
        let workspace = self.workspaceState
        guard filePath.hasSuffix(".go"), let session = document, session.syncsToCore else {
            workspace.presentCommandFeedback("Rename works on Go files that the language server is tracking. Open the file from the project to rename its symbols.", title: "Can’t Rename Here")
            return
        }
        let selection = selectedRange()
        guard selection.location != NSNotFound else { return }
        let caret = selection.location
        let version = session.version
        let path = session.path
        let (line, col) = lineAndCol(forCharacterIndex: caret)
        Task { @MainActor [weak self] in
            let prepared = await LSPClient.shared.prepareRenameResult(atLine: line, col: col, inPath: path)
            let occurrences = await LSPClient.shared.renameOccurrences(atLine: line, col: col, inPath: path)
            guard let self, self.document === session, session.version == version, self.selectedRange() == selection else { return }
            switch prepared {
            case .failure(let failure):
                let reason: String
                if case .serverError(_, let message) = failure {
                    reason = WorkspaceState.formatCommandReason(message, fallback: failure.explanation)
                } else {
                    reason = failure.explanation
                }
                workspace.presentCommandFeedback(reason, title: "Can’t Rename This Symbol", tone: .failure)
            case .success(nil):
                workspace.presentCommandFeedback("Place the cursor on a name declared in this project, then try again.", title: "Nothing to Rename")
            case .success(let range?):
                self.beginInlineRename(primary: range, occurrences: occurrences, in: session, selection: selection)
            }
        }
    }

    private func nsRange(_ range: LSPRange, in session: DocumentSession) -> NSRange? {
        guard let start = session.offset(line: range.start.line, utf16Column: range.start.character),
              let end = session.offset(line: range.end.line, utf16Column: range.end.character),
              end > start, end <= session.length else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func beginInlineRename(primary: LSPRange, occurrences: [LSPRange], in session: DocumentSession, selection: NSRange) {
        let workspace = self.workspaceState
        let ns = session.storage.string as NSString
        guard let primaryRange = nsRange(primary, in: session) else { return }
        let name = ns.substring(with: primaryRange)
        let ranges = occurrences.compactMap { nsRange($0, in: session) }.filter { ns.substring(with: $0) == name } + [primaryRange]
        guard GoIdentifier.isValid(name),
              let model = LinkedRename(original: name, ranges: ranges, primaryLocation: primaryRange.location) else {
            workspace.presentCommandFeedback("Place the cursor on a name declared in this project, then try again.", title: "Nothing to Rename")
            return
        }
        endMultiCursor()
        CompletionController.shared.dismiss()
        inlineSuggestions.dismiss()
        dismissHoverImmediate()
        endIdentifierEdit()
        breakUndoCoalescing()
        let renaming = InlineRenameSession(model: model, document: session, originalSelection: selection, allowedUndo: allowsUndo)
        inlineRename = renaming
        allowsUndo = false
        renaming.isApplying = true
        setSelectedRange(model.primaryRange)
        renaming.isApplying = false
        workspace.renameHint = InlineRenameHint(name: name, usages: model.ranges.count)
        refreshInlineRenameHint()
        setNeedsDisplay(visibleRect)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "Renaming \(name). Type the new name, then press Return to rename it everywhere, or Escape to cancel.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    func refreshInlineRenameHint() {
        guard let renaming = inlineRename, renaming.document === document else { return }
        let workspace = self.workspaceState
        workspace.updateCaretRect(for: self)
        workspace.renameRect = workspace.lsp.completionsRect
        workspace.renameBounds = popupBoundsInWindow()
        if workspace.renameHint == nil {
            workspace.renameHint = InlineRenameHint(name: renaming.model.original, usages: renaming.model.ranges.count)
        }
    }

    private func showInlineRenameProblem(_ message: String?) {
        guard inlineRename != nil else { return }
        if workspaceState.renameHint == nil { refreshInlineRenameHint() }
        workspaceState.renameHint?.message = message
    }

    func inlineRenameShouldChange(_ range: NSRange, replacement: String) -> Bool {
        guard let renaming = inlineRename else { return true }
        if renaming.isApplying { return true }
        if renaming.isCommitting { return false }
        if let undo = undoManager, undo.isUndoing || undo.isRedoing {
            renaming.foreignEdit = (range, (replacement as NSString).length)
            return true
        }
        guard renaming.model.contains(range) else {
            showInlineRenameProblem("Only the highlighted name changes while renaming. Press Return to finish or Esc to cancel.")
            return false
        }
        let before = renaming.model.primaryRange
        guard let edits = renaming.model.apply(range, replacement: replacement) else {
            showInlineRenameProblem("Go names use only letters, digits and _.")
            return false
        }
        apply(edits, for: renaming)
        let caret = renaming.model.primaryRange.location + range.location - before.location + (replacement as NSString).length
        renaming.isApplying = true
        setSelectedRange(NSRange(location: caret, length: 0))
        renaming.isApplying = false
        workspaceState.renameHint?.message = GoIdentifier.problem(with: renaming.model.name)
        refreshInlineRenameHint()
        setNeedsDisplay(visibleRect)
        return false
    }

    override func didChangeText() {
        super.didChangeText()
        guard let renaming = inlineRename, !renaming.isApplying, let foreign = renaming.foreignEdit else { return }
        renaming.foreignEdit = nil
        let restorable = renaming.model.shift(byEditAt: foreign.range, newLength: foreign.newLength)
        endInlineRename(restoring: restorable ? renaming.model.original : nil, selection: nil)
    }

    private func apply(_ edits: [LinkedEdit], for renaming: InlineRenameSession) {
        guard !edits.isEmpty else { return }
        renaming.isApplying = true
        workspaceState.applyRanges(edits.map { ($0.range, $0.text) }, in: renaming.document, registersUndo: false)
        renaming.isApplying = false
    }

    func inlineRenameSelectionChanged(_ selection: NSRange) {
        guard let renaming = inlineRename, !renaming.isApplying, !renaming.isCommitting else { return }
        if renaming.document !== document || !renaming.model.contains(selection) {
            finishInlineRename()
        }
    }

    func handleInlineRenameCommand(_ selector: Selector) -> Bool {
        guard let renaming = inlineRename else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if !renaming.isCommitting { commitInlineRename(explicit: true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !renaming.isCommitting { cancelInlineRename() }
            return true
        default:
            return false
        }
    }

    func handleInlineRenameKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if !flags.contains(.shift), inlineRename?.isCommitting == false { cancelInlineRename() }
        return true
    }

    func finishInlineRename() {
        guard let renaming = inlineRename, !renaming.isCommitting else { return }
        commitInlineRename(explicit: false)
    }

    func cancelInlineRename() {
        guard let renaming = inlineRename else { return }
        endInlineRename(restoring: renaming.model.original, selection: renaming.originalSelection)
    }

    private func endInlineRename(restoring text: String?, selection: NSRange?) {
        guard let renaming = inlineRename else { return }
        if let text, renaming.model.name != text {
            apply(renaming.model.setAll(to: text), for: renaming)
        }
        inlineRename = nil
        allowsUndo = renaming.allowedUndo
        workspaceState.renameHint = nil
        if let selection, document === renaming.document, NSMaxRange(selection) <= renaming.document.length {
            setSelectedRange(selection)
            scrollRangeToVisible(selection)
        }
        breakUndoCoalescing()
        setNeedsDisplay(visibleRect)
    }

    private func commitInlineRename(explicit: Bool) {
        guard let renaming = inlineRename, !renaming.isCommitting else { return }
        let model = renaming.model
        guard model.changed else {
            endInlineRename(restoring: nil, selection: nil)
            return
        }
        if let problem = GoIdentifier.problem(with: model.name) {
            if explicit {
                    showInlineRenameProblem(problem)
            } else {
                endInlineRename(restoring: model.original, selection: renaming.originalSelection)
                workspaceState.presentCommandFeedback("\(problem) ‘\(model.original)’ keeps its name.", title: "Rename Cancelled")
            }
            return
        }
        let session = renaming.document
        let newName = model.name
        let workspace = self.workspaceState
        renaming.isCommitting = true
        apply(renaming.model.setAll(to: model.original), for: renaming)
        let primary = renaming.model.primaryRange
        workspace.renameHint?.message = nil
        workspace.renameHint?.isSubmitting = true
        isEditable = false
        workspace.renameSymbol(at: session.utf8.byteOffset(primary.location), in: session.path, to: newName) { [weak self] result, failure in
            guard let self else { return }
            self.isEditable = true
            guard let result else {
                renaming.isCommitting = false
                self.apply(renaming.model.setAll(to: newName), for: renaming)
                workspace.renameHint?.isSubmitting = false
                self.showInlineRenameProblem(failure)
                if self.document === session {
                    renaming.isApplying = true
                    self.setSelectedRange(NSRange(location: NSMaxRange(renaming.model.primaryRange), length: 0))
                    renaming.isApplying = false
                }
                return
            }
            self.endInlineRename(restoring: nil, selection: nil)
            let edits = result.editsByPath
            let local = edits.filter { $0.0 == session.path }.flatMap { $0.1 }
            self.breakUndoCoalescing()
            workspace.applyRanges(workspace.resolvedRanges(local, in: session), in: session, actionName: "Rename")
            let others = edits.filter { $0.0 != session.path && !$0.1.isEmpty }
            if !others.isEmpty {
                let changes = Dictionary(others.map { (lspURI(forPath: $0.0), $0.1) }, uniquingKeysWith: { $0 + $1 })
                workspace.applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: self, actionName: "Rename")
            }
            let files = Set(edits.filter { !$0.1.isEmpty }.map(\.0)).count
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: "Renamed \(model.original) to \(newName) in \(files == 1 ? "1 file" : "\(files) files").",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
    }

    func drawInlineRenameOccurrences(in dirtyRect: NSRect) {
        guard let renaming = inlineRename, renaming.document === document,
              let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let length = textStorage?.length ?? 0
        for (index, range) in renaming.model.ranges.enumerated() where NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: origin.x, dy: origin.y)
            if range.length == 0 { box.size.width = Stroke.standard }
            guard box.intersects(dirtyRect) else { continue }
            if index == renaming.model.primaryIndex {
                OccurrenceHighlight.write.setFill()
                box.fill()
                OccurrenceHighlight.edited.setStroke()
                let outline = NSBezierPath(roundedRect: box.insetBy(dx: Stroke.hairline, dy: Stroke.hairline), xRadius: CornerRadius.small, yRadius: CornerRadius.small)
                outline.lineWidth = Stroke.standard
                outline.stroke()
            } else {
                OccurrenceHighlight.read.setFill()
                box.fill()
            }
        }
    }
}
