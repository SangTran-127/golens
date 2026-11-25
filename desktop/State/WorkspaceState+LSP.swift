import Foundation
import SwiftUI
import SwiftTerm

extension WorkspaceState {
    func updateCaretRect(for textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        guard let window = textView.window,
              let contentView = window.contentView else {
            return
        }
        
        let screenRect = textView.firstRect(forCharacterRange: selectedRange, actualRange: nil)
        let windowRect = window.convertFromScreen(screenRect)
        let windowHeight = contentView.bounds.height
        
        var swiftUIX = windowRect.origin.x
        var swiftUIY = windowHeight - (windowRect.origin.y + windowRect.size.height)
        
        if windowRect.width == 0 && windowRect.height == 0 {
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
                let caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                var textViewRect = caretRect
                textViewRect.origin.x += textView.textContainerOrigin.x
                textViewRect.origin.y += textView.textContainerOrigin.y
                let winRect = textView.convert(textViewRect, to: nil)
                swiftUIX = winRect.origin.x
                swiftUIY = windowHeight - (winRect.origin.y + winRect.size.height)
            }
        }
        
        let w = windowRect.width > 0 ? windowRect.width : 1
        let h = windowRect.height > 0 ? windowRect.height : 15
        
        self.lsp.completionsRect = CGRect(x: swiftUIX, y: swiftUIY, width: w, height: h)
        self.lsp.completionsBounds = (textView as? GoLensTextView)?.popupBoundsInWindow() ?? .zero
    }

    func fetchSignatureHelp(for textView: NSTextView, keepingAnchorOnLine: Bool = false) {
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound, let session = (textView as? GoLensTextView)?.document, session.syncsToCore else { return }
        updateCaretRect(for: textView)
        let anchor = keepingAnchorOnLine && lsp.signatureHelp != nil && lsp.completionsRect.minY == lsp.signatureHelpRect.minY ? lsp.signatureHelpRect : lsp.completionsRect
        let path = session.path
        let utf8Offset = session.utf8.byteOffset(selectedRange.location)
        transientEditorState.signatureHelpGeneration &+= 1
        let generation = transientEditorState.signatureHelpGeneration

        lspRequestQueue.async {
            guard let cPath = path.cString(using: .utf8) else { return }
            guard let cStr = GetSignatureHelp(cPath, Int32(utf8Offset)) else { return }
            defer { FreeGoCString(cStr) }
            
            let jsonStr = String(cString: cStr)
            if jsonStr.isEmpty {
                DispatchQueue.main.async { if generation == self.transientEditorState.signatureHelpGeneration { self.lsp.signatureHelp = nil } }
                return
            }
            
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let signaturesArr = result["signatures"] as? [[String: Any]],
                  !signaturesArr.isEmpty else {
                DispatchQueue.main.async { if generation == self.transientEditorState.signatureHelpGeneration { self.lsp.signatureHelp = nil } }
                return
            }
            
            var parsedSignatures: [SignatureHelpData.Signature] = []
            for sig in signaturesArr {
                let label = sig["label"] as? String ?? ""
                var docStr: String?
                if let doc = sig["documentation"] as? String {
                    docStr = doc
                } else if let docDict = sig["documentation"] as? [String: Any], let val = docDict["value"] as? String {
                    docStr = val
                }
                
                var parsedParams: [SignatureHelpData.Signature.Parameter] = []
                if let paramsArr = sig["parameters"] as? [[String: Any]] {
                    for p in paramsArr {
                        var pLabelStr = ""
                        var pLabelRange: Range<Int>? = nil
                        if let pLabel = p["label"] as? String {
                            pLabelStr = pLabel
                        } else if let pLabelArr = (p["label"] as? [Int]) ?? (p["label"] as? [NSNumber])?.map({ $0.intValue }), pLabelArr.count == 2 {
                            let start = pLabelArr[0]
                            let end = pLabelArr[1]
                            if start >= 0 && end <= label.utf16.count && start <= end {
                                pLabelRange = start..<end
                                let startIdx = label.utf16.index(label.utf16.startIndex, offsetBy: start)
                                let endIdx = label.utf16.index(label.utf16.startIndex, offsetBy: end)
                                pLabelStr = String(utf16CodeUnits: Array(label.utf16[startIdx..<endIdx]), count: end - start)
                            }
                        }
                        
                        var pDocStr: String?
                        if let pDoc = p["documentation"] as? String {
                            pDocStr = pDoc
                        } else if let pDocDict = p["documentation"] as? [String: Any], let val = pDocDict["value"] as? String {
                            pDocStr = val
                        }
                        parsedParams.append(SignatureHelpData.Signature.Parameter(label: pLabelStr, documentation: pDocStr, labelRange: pLabelRange))
                    }
                }
                parsedSignatures.append(SignatureHelpData.Signature(label: label, documentation: docStr, parameters: parsedParams))
            }
            
            let activeSignature = result["activeSignature"] as? Int ?? 0
            let activeSigDict = signaturesArr.indices.contains(activeSignature) ? signaturesArr[activeSignature] : nil
            let activeParameter = (activeSigDict?["activeParameter"] as? Int) ?? (result["activeParameter"] as? Int) ?? 0
            
            let helpData = SignatureHelpData(
                signatures: parsedSignatures,
                activeSignature: activeSignature,
                activeParameter: activeParameter
            )
            
            DispatchQueue.main.async {
                guard generation == self.transientEditorState.signatureHelpGeneration else { return }
                self.lsp.signatureHelp = helpData
                self.lsp.signatureHelpRect = anchor
                self.lsp.signatureHelpBounds = self.lsp.completionsBounds
            }
        }
    }

    func toggleInlayHints() {
        showInlayHints.toggle()
    }

    func formatSelection(in textView: NSTextView) {
        guard activeFilePath.hasSuffix(".go") else { return }
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0, let golens = textView as? GoLensTextView,
              let session = golens.document, session.syncsToCore else { return }
        let firstLine = golens.lineAndCol(forCharacterIndex: selectedRange.location).line - 1
        let endLC = golens.lineAndCol(forCharacterIndex: NSMaxRange(selectedRange))
        let lastLine = endLC.col == 1 && endLC.line - 1 > firstLine ? endLC.line - 2 : endLC.line - 1
        let path = session.path
        let version = session.version
        lspRequestQueue.async {
            let json: String? = path.withCString { p in
                guard let c = FormattingEdits(p, 8) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            DispatchQueue.main.async {
                guard session.version == version else { return }
                guard let json, !json.isEmpty,
                      let response = try? JSONDecoder().decode(CoreEdits.self, from: Data(json.utf8)) else {
                    let fileName = (path as NSString).lastPathComponent
                    self.appendLog("Format Selection: gopls couldn’t format \(fileName). Fix syntax errors in the file and try again.")
                    self.presentCommandFeedback(
                        "gopls couldn’t format \(fileName). Fix syntax errors in the file and try again.",
                        title: "Couldn’t Format Selection",
                        tone: .warning
                    )
                    return
                }
                let edits = Self.formattingEdits(response.edits, withinLines: firstLine...max(firstLine, lastLine))
                guard !edits.isEmpty else { return }
                (self.textView(showing: session))?.breakUndoCoalescing()
                self.applyRanges(self.resolvedRanges(edits, in: session), in: session)
            }
        }
    }

    static func formattingEdits(_ edits: [LSPTextEdit], withinLines lines: ClosedRange<Int>) -> [LSPTextEdit] {
        edits.filter { edit in
            let start = edit.range.start
            let end = edit.range.end
            guard lines.contains(start.line) else { return false }
            return end.line <= lines.upperBound || (end.line == lines.upperBound + 1 && end.character == 0)
        }
    }

    func applyWorkspaceEdit(_ edit: WorkspaceEdit, activeTextView: NSTextView?, actionName: String? = nil) {
        let nonEmpty = edit.editsByPath.filter { !$0.1.isEmpty }
        let saveOpenFiles = nonEmpty.count > 1
        for (path, edits) in nonEmpty {
            if let session = documents[path] {
                let wasClean = !session.isEdited
                applyTextEdits(edits, in: session, actionName: actionName)
                if saveOpenFiles || wasClean {
                    writeDocument(session, reportsFailure: true)
                }
            } else if let content = try? String(contentsOfFile: path, encoding: String.Encoding.utf8) {
                let scratch = DocumentSession(path: path, text: content, syncsToCore: false)
                scratch.workspace = self
                applyTextEdits(edits, in: scratch)
                do {
                    try scratch.storage.string.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
                    LSPClient.notifyWatchedFilesChanged([path])
                } catch {
                    appendLog("Failed to apply edit to \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                    presentFailure(
                        "Couldn’t Edit “\((path as NSString).lastPathComponent)”",
                        "\(Self.failureReason(error)) The change wasn’t applied to this file. Check that you can write to it, then try again.",
                        recovery: ("Try Again", { [weak self] in
                            self?.applyWorkspaceEdit(WorkspaceEdit(changes: [lspURI(forPath: path): edits]), activeTextView: nil)
                        }),
                        revealing: path
                    )
                }
            }
        }
    }

    func applyLSPTextEdits(_ edits: [LSPTextEdit], to textView: NSTextView) {
        guard let session = (textView as? GoLensTextView)?.document else { return }
        applyTextEdits(edits, in: session)
    }

    func resolvedRanges(_ edits: [LSPTextEdit], in session: DocumentSession) -> [(NSRange, String)] {
        func offset(_ p: LSPPosition) -> Int? {
            p.line >= session.lines.count ? session.length : session.offset(line: p.line, utf16Column: p.character)
        }
        let resolved = edits.enumerated().compactMap { i, edit -> (Int, NSRange, String)? in
            guard let start = offset(edit.range.start), let end = offset(edit.range.end), end >= start else { return nil }
            return (i, NSRange(location: start, length: end - start), edit.newText)
        }
        return resolved.sorted { $0.1.location != $1.1.location ? $0.1.location > $1.1.location : $0.0 > $1.0 }.map { ($0.1, $0.2) }
    }

    func textView(showing session: DocumentSession) -> GoLensTextView? {
        if let tv = activeTextView as? GoLensTextView, tv.document === session { return tv }
        if let tv = primaryTextView as? GoLensTextView, tv.document === session { return tv }
        if isSplitMode, let tv = secondaryTextView as? GoLensTextView, tv.document === session { return tv }
        return nil
    }

    func applyTextEdits(_ edits: [LSPTextEdit], in session: DocumentSession, actionName: String? = nil) {
        applyRanges(resolvedRanges(edits, in: session), in: session, actionName: actionName)
    }

    func applyRanges(_ ranges: [(NSRange, String)], in session: DocumentSession, actionName: String? = nil, registersUndo: Bool = true) {
        guard !ranges.isEmpty else { return }
        guard let textView = textView(showing: session) else {
            breakEditorUndoCoalescing(for: session.path)
            let undo = session.undoManager
            let storage = session.storage
            func applyUndoableReplacement(_ range: NSRange, _ text: String) {
                guard NSMaxRange(range) <= storage.length else { return }
                let oldText = (storage.string as NSString).substring(with: range)
                let inverseRange = NSRange(location: range.location, length: (text as NSString).length)
                storage.replaceCharacters(in: range, with: text)
                guard registersUndo else { return }
                undo.registerUndo(withTarget: storage) { [weak self] _ in
                    self?.applyRanges([(inverseRange, oldText)], in: session)
                }
            }
            if registersUndo && !undo.isUndoing && !undo.isRedoing {
                while undo.groupingLevel > 0 {
                    undo.endUndoGrouping()
                }
            }
            let groupsByEvent = undo.groupsByEvent
            if registersUndo {
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
            }
            for (range, text) in ranges where NSMaxRange(range) <= storage.length {
                applyUndoableReplacement(range, text)
            }
            if registersUndo {
                if let actionName { undo.setActionName(actionName) }
                undo.endUndoGrouping()
                undo.groupsByEvent = groupsByEvent
            }
            return
        }
        var caret = textView.selectedRange().location
        CompletionController.shared.suppressed = true
        defer { CompletionController.shared.suppressed = false }
        let undo = session.undoManager
        let groupsByEvent = undo.groupsByEvent
        let allowsUndo = textView.allowsUndo
        textView.breakUndoCoalescing()
        textView.allowsUndo = false
        if registersUndo {
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
        }
        for (range, text) in ranges where NSMaxRange(range) <= session.storage.length {
            guard textView.shouldChangeText(in: range, replacementString: text) else { continue }
            let old = (session.storage.string as NSString).substring(with: range)
            let inverse = NSRange(location: range.location, length: (text as NSString).length)
            session.storage.replaceCharacters(in: range, with: text)
            textView.didChangeText()
            if registersUndo {
                undo.registerUndo(withTarget: session.storage) { [weak self] _ in
                    self?.applyRanges([(inverse, old)], in: session)
                }
            }
            if range.location < caret {
                caret = max(range.location, caret + (text as NSString).length - range.length)
            }
        }
        if registersUndo {
            if let actionName { undo.setActionName(actionName) }
            undo.endUndoGrouping()
            undo.groupsByEvent = groupsByEvent
        }
        textView.allowsUndo = allowsUndo
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: min(caret, session.length), length: 0))
    }

    static func changedRegion(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        return (NSRange(location: prefix, length: old.length - prefix - suffix), NSRange(location: prefix, length: new.length - prefix - suffix))
    }

    func registerNetUndo(for chain: EditUndoChain, in session: DocumentSession) {
        let (oldRange, newRange) = Self.changedRegion(from: chain.before as NSString, to: session.storage.string as NSString)
        guard oldRange.length > 0 || newRange.length > 0 else { return }
        registerReplacementUndo(target: chain.token, in: session, range: newRange,
                                text: (chain.before as NSString).substring(with: oldRange),
                                selection: chain.selection, redoSelection: textView(showing: session)?.selectedRange(),
                                actionName: chain.actionName)
    }

    private func registerReplacementUndo(target: AnyObject, in session: DocumentSession, range: NSRange, text: String,
                                         selection: NSRange?, redoSelection: NSRange?, actionName: String) {
        let undo = session.undoManager
        let topLevel = !undo.isUndoing && !undo.isRedoing
        let groupsByEvent = undo.groupsByEvent
        if topLevel {
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
        }
        undo.registerUndo(withTarget: target) { [weak self, target] _ in
            guard let self, NSMaxRange(range) <= session.storage.length else { return }
            let replaced = (session.storage.string as NSString).substring(with: range)
            self.applyRanges([(range, text)], in: session, registersUndo: false)
            if let selection, let textView = self.textView(showing: session) {
                let location = min(selection.location, session.length)
                let restored = NSRange(location: location, length: min(selection.length, session.length - location))
                textView.setSelectedRange(restored)
                textView.scrollRangeToVisible(restored)
            }
            self.registerReplacementUndo(target: target, in: session, range: NSRange(location: range.location, length: (text as NSString).length),
                                         text: replaced, selection: redoSelection, redoSelection: selection, actionName: actionName)
        }
        undo.setActionName(actionName)
        if topLevel {
            undo.endUndoGrouping()
            undo.groupsByEvent = groupsByEvent
        }
    }
}

final class EditUndoChain {
    let actionName: String
    var before = ""
    var selection: NSRange?
    var version: Int?
    var token = NSObject()

    init(actionName: String) {
        self.actionName = actionName
    }
}
