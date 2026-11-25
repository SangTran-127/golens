import AppKit
import GoLensFoundation

struct IdentifierEdit {
    var start: Int
    var length: Int
    let original: String
}

struct RenameSuggestion: Equatable {
    let start: Int
    let old: String
    let new: String

    var title: String { "Rename Usages of ‘\(old)’ to ‘\(new)’" }
}

extension GoLensTextView {
    func trackIdentifierEdit(in range: NSRange, replacement: String) {
        defer { lastEditEnd = range.location + (replacement as NSString).length }
        guard !suppressIdentifierTracking else { return }
        if CompletionController.shared.suppressed {
            shiftIdentifierEdit(for: range, newLength: (replacement as NSString).length)
            return
        }
        guard filePath.hasSuffix(".go"),
              let um = undoManager, !um.isUndoing, !um.isRedoing,
              replacement.utf16.allSatisfy(GoIdentifier.isPart) else {
            endIdentifierEdit()
            return
        }
        let delta = (replacement as NSString).length - range.length
        if var edit = identifierEdit, range.location >= edit.start, NSMaxRange(range) <= edit.start + edit.length {
            edit.length += delta
            identifierEdit = edit
            scheduleRenameSuggestion()
            return
        }
        endIdentifierEdit()
        guard range.location != lastEditEnd || range.length > 0 else { return }
        let ns = string as NSString
        var lo = range.location
        var hi = NSMaxRange(range)
        while lo > 0 && GoIdentifier.isPart(ns.character(at: lo - 1)) { lo -= 1 }
        while hi < ns.length && GoIdentifier.isPart(ns.character(at: hi)) { hi += 1 }
        let original = ns.substring(with: NSRange(location: lo, length: hi - lo))
        guard GoIdentifier.isValid(original) else { return }
        identifierEdit = IdentifierEdit(start: lo, length: hi - lo + delta, original: original)
        scheduleRenameSuggestion()
    }

    private func shiftIdentifierEdit(for range: NSRange, newLength: Int) {
        guard let edit = identifierEdit else { return }
        if range.location >= edit.start + edit.length { return }
        guard NSMaxRange(range) <= edit.start else {
            endIdentifierEdit()
            return
        }
        let delta = newLength - range.length
        identifierEdit?.start += delta
        if let s = renameSuggestion {
            renameSuggestion = RenameSuggestion(start: s.start + delta, old: s.old, new: s.new)
        }
    }

    func endIdentifierEdit() {
        identifierEdit = nil
        renameSuggestionWork?.cancel()
        clearRenameSuggestion()
    }

    func clearRenameSuggestion() {
        guard renameSuggestion != nil else { return }
        renameSuggestion = nil
        renameHitRect = nil
        redrawGutter()
    }

    private func scheduleRenameSuggestion() {
        renameSuggestionWork?.cancel()
        clearRenameSuggestion()
        let work = DispatchWorkItem { [weak self] in self?.evaluateRenameSuggestion() }
        renameSuggestionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func evaluateRenameSuggestion() {
        guard let edit = identifierEdit, let session = document, session.syncsToCore,
              edit.length > 0, edit.start + edit.length <= session.length else { return }
        let new = (string as NSString).substring(with: NSRange(location: edit.start, length: edit.length))
        guard new != edit.original, GoIdentifier.isValid(new) else { return }
        let path = session.path
        let version = session.version
        let byte = session.utf8.byteOffset(edit.start)
        self.workspaceState.lspQueue.async { [weak self] in
            let declared: String? = path.withCString { p in
                guard let c = DeclarationAt(p, Int32(byte)) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            DispatchQueue.main.async {
                guard let self, declared == new, self.document === session, session.version == version,
                      self.identifierEdit?.start == edit.start else { return }
                self.renameSuggestion = RenameSuggestion(start: edit.start, old: edit.original, new: new)
                self.redrawGutter()
            }
        }
    }

    @objc func acceptRenameSuggestion() {
        guard let suggestion = renameSuggestion, let session = document, session.syncsToCore else { return }
        let newRange = NSRange(location: suggestion.start, length: (suggestion.new as NSString).length)
        guard NSMaxRange(newRange) <= session.length,
              (string as NSString).substring(with: newRange) == suggestion.new else {
            endIdentifierEdit()
            self.workspaceState.presentCommandFeedback("The edited identifier changed before usages could be updated.", title: "Rename Usages")
            return
        }
        endIdentifierEdit()
        breakUndoCoalescing()
        let oldRange = NSRange(location: suggestion.start, length: (suggestion.old as NSString).length)
        replaceWithoutUndo(newRange, with: suggestion.old)
        isEditable = false
        let path = session.path
        let byte = session.utf8.byteOffset(suggestion.start)
        let workspace = self.workspaceState
        workspace.renameSymbol(at: byte, in: path, to: suggestion.new) { [weak self] result, failure in
            guard let self else { return }
            self.isEditable = true
            guard self.document === session else { return }
            let edits = result?.editsByPath ?? []
            let local = edits.filter { $0.0 == path }.flatMap { $0.1 }
            var ranges = workspace.resolvedRanges(local, in: session)
            let undo = session.undoManager
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            defer {
                undo.endUndoGrouping()
                undo.groupsByEvent = true
            }
            self.replaceWithoutUndo(oldRange, with: suggestion.new)
            guard result != nil else {
                workspace.presentCommandFeedback(failure, title: "Couldn’t Rename Symbol", tone: .failure)
                return
            }
            let delta = newRange.length - oldRange.length
            ranges = ranges.compactMap { range, text in
                if range.location == oldRange.location { return nil }
                if range.location > oldRange.location { return (NSRange(location: range.location + delta, length: range.length), text) }
                return (range, text)
            }
            self.breakUndoCoalescing()
            workspace.applyRanges(ranges, in: session)
            let others = edits.filter { $0.0 != path }
            if !others.isEmpty {
                let changes = Dictionary(others.map { (lspURI(forPath: $0.0), $0.1) }, uniquingKeysWith: { $0 + $1 })
                workspace.applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: self)
            }
        }
    }

    private func replaceWithoutUndo(_ range: NSRange, with text: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        suppressIdentifierTracking = true
        undoManager?.disableUndoRegistration()
        if shouldChangeText(in: range, replacementString: text) {
            storage.replaceCharacters(in: range, with: text)
            didChangeText()
        }
        undoManager?.enableUndoRegistration()
        suppressIdentifierTracking = false
    }
}

extension WorkspaceState {
    func renameSymbol(at byteOffset: Int, in path: String, to newName: String, completion: @escaping (WorkspaceEdit?, String) -> Void) {
        lspRequestQueue.async { [weak self] in
            let json: String? = path.withCString { p in
                newName.withCString { n in
                    guard let c = RenameSymbol(p, Int32(byteOffset), n) else { return nil }
                    defer { FreeGoCString(c) }
                    return String(cString: c)
                }
            }
            struct RenameResponse: Decodable {
                let result: WorkspaceEdit?
                let error: String?
            }
            let response = json.flatMap { try? JSONDecoder().decode(RenameResponse.self, from: Data($0.utf8)) }
            DispatchQueue.main.async {
                if let edit = response?.result, (response?.error ?? "").isEmpty {
                    completion(edit, "")
                    return
                }
                self?.appendLog("Rename failed: \(response?.error ?? "no response from gopls")")
                completion(nil, WorkspaceState.formatCommandReason(response?.error, fallback: "The language server couldn’t rename this symbol."))
            }
        }
    }
}
