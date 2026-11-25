import SwiftUI
import AppKit
import GoLensFoundation

extension MacTextView.Coordinator {
    func undoManager(for view: NSTextView) -> UndoManager? {
        (view as? GoLensTextView)?.document?.undoManager
    }

    private static func character(_ ns: NSString, _ i: Int) -> unichar? {
        i >= 0 && i < ns.length ? ns.character(at: i) : nil
    }

    private static func classifyEdit(in ns: NSString, range: NSRange, replacement: String) -> (singleLinePlain: Bool, affectsFolding: Bool) {
        guard range.length <= 64, replacement.utf16.count <= 64, NSMaxRange(range) <= ns.length else {
            return (false, true)
        }
        var singleLinePlain = true
        var affectsFolding = false
        let inspect: (unichar) -> Void = { c in
            switch c {
            case 0x0A, 0x0D, 0x60, 0x2F, 0x2A:
                singleLinePlain = false
                affectsFolding = true
            case 0x7B, 0x7D, 0x22, 0x27, 0x5C:
                affectsFolding = true
            default:
                break
            }
        }
        for i in range.location..<NSMaxRange(range) {
            inspect(ns.character(at: i))
        }
        for c in replacement.utf16 {
            inspect(c)
        }
        return (singleLinePlain, affectsFolding)
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:], toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        var attributes = newTypingAttributes
        attributes[.kern] = nil
        attributes[.golensInlayHint] = nil
        return attributes
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if textView.selectedRanges.count > 1 || (textView as? GoLensTextView)?.hasMultipleCursors == true { return true }
        lastReplacement = replacementString
        lastReplacementComposes = textView.hasMarkedText()
        if let replacementString {
            let ns = textView.liveText
            let classified = Self.classifyEdit(in: ns, range: affectedCharRange, replacement: replacementString)
            lastEditIsSingleLinePlain = classified.singleLinePlain
            lastEditAffectsFolding = classified.affectsFolding
            lastChange = (affectedCharRange, (replacementString as NSString).length)
        } else {
            lastEditIsSingleLinePlain = false
            lastEditAffectsFolding = false
            lastChange = nil
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? GoLensTextView else { return }
        if self.windowWorkspace.activeTextView !== textView {
            self.windowWorkspace.activeTextView = textView
        }
        let inserted = lastReplacement
        let composes = lastReplacementComposes
        let change = lastChange
        let singleLinePlain = lastEditIsSingleLinePlain
        let affectsFolding = lastEditAffectsFolding
        lastReplacement = nil
        lastReplacementComposes = false
        lastChange = nil
        lastEditIsSingleLinePlain = false
        lastEditAffectsFolding = false
        documentHighlightWorkItem?.cancel()
        clearDocumentHighlights(in: textView)
        let editedLineRange = invalidateEditedLines(in: textView, change: change, singleLinePlain: singleLinePlain)
        if let session = textView.document, affectsFolding || editedLineRange == nil {
            self.windowWorkspace.scheduleFoldableUpdate(for: session.path, session: session, textView: textView)
        }
        if self.windowWorkspace.showMinimap {
            textView.minimapDelegate?.documentDidChange()
        }
        var handledFastPath = false
        if let session = textView.document,
           let editedLineRange,
           let change,
           let key = lastHighlightKey,
           key.path == session.path,
           key.theme == self.windowWorkspace.selectedThemeId {
            let delta = change.newLength - change.old.length
            let adjustedLength = min(max(0, key.range.length + delta), max(0, session.length - key.range.location))
            let adjustedRange = NSRange(location: key.range.location, length: adjustedLength)
            if editedLineRange.location >= adjustedRange.location && NSMaxRange(editedLineRange) <= NSMaxRange(adjustedRange) {
                handledFastPath = true
                highlightWorkItem?.cancel()
                let theme = self.windowWorkspace.currentTheme
                let isDark = theme.resolvedIsDark
                let syntax = session.highlighter.attributes(for: session.storage, isDark: isDark, theme: theme, in: editedLineRange)
                paint(textView, session: session, target: editedLineRange, syntax: syntax)
                lastHighlightKey = (session.path, session.version, key.theme, isDark, adjustedRange)
                pendingSemanticRange = pendingSemanticRange.map { NSUnionRange($0, editedLineRange) } ?? editedLineRange
                scheduleSemanticTokens(textView, session: session, target: adjustedRange, theme: theme, isDark: isDark, immediate: false)
            }
        }
        if !handledFastPath {
            if let change, let session = textView.document,
               NSMaxRange(NSRange(location: change.old.location, length: change.newLength)) <= session.length {
                let affectedLines = session.storage.mutableString.lineRange(for: NSRange(location: change.old.location, length: change.newLength))
                let theme = self.windowWorkspace.currentTheme
                let isDark = theme.resolvedIsDark
                let syntax = session.highlighter.attributes(for: session.storage, isDark: isDark, theme: theme, in: affectedLines)
                paint(textView, session: session, target: affectedLines, syntax: syntax)
                pendingSemanticRange = pendingSemanticRange.map { NSUnionRange($0, affectedLines) } ?? affectedLines
            }
            scheduleHighlight(for: textView)
        }
        if textView.inlineRename == nil {
            CompletionController.shared.textDidChange(in: textView, inserted: composes ? inserted?.last.map(String.init) : inserted, edit: change)
            textView.inlineSuggestions.textDidChange(inserted: inserted, change: change)
        }
        textView.scheduleInlayHintUpdate()
        self.windowWorkspace.scheduleMergeConflictScan(path: textView.filePath)
        for candidatePane in [EditorPaneID.primary, .secondary] {
            if self.windowWorkspace.filePath(for: candidatePane) == textView.filePath,
               self.windowWorkspace.paneState(for: candidatePane).showLocalSearch {
                self.windowWorkspace.scheduleLocalSearchRefresh(in: candidatePane)
            }
        }
    }

    private func invalidateEditedLines(in textView: GoLensTextView, change: (old: NSRange, newLength: Int)?, singleLinePlain: Bool) -> NSRange? {
        let lineCount = textView.document?.lines.count ?? -1
        let lineCountChanged = lineCount != lastLineCount
        lastLineCount = lineCount
        if lineCountChanged {
            textView.updateGutterWidth()
        }
        let ns = textView.liveText
        guard !lineCountChanged, let change, let lm = textView.layoutManager, let tc = textView.textContainer,
              NSMaxRange(NSRange(location: change.old.location, length: change.newLength)) <= ns.length else {
            textView.setNeedsDisplay(textView.visibleRect)
            return nil
        }
        let lines = ns.lineRange(for: NSRange(location: change.old.location, length: change.newLength))
        let glyphs = lm.glyphRange(forCharacterRange: lines, actualCharacterRange: nil)
        let box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        textView.setNeedsDisplay(NSRect(x: 0, y: box.minY + textView.textContainerOrigin.y, width: textView.bounds.width, height: max(box.height, 1)))
        return singleLinePlain ? lines : nil
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let golens = textView as? GoLensTextView, CompletionController.shared.handle(commandSelector, in: golens) {
            return true
        }
        if let golens = textView as? GoLensTextView, golens.inlineSuggestions.handle(commandSelector) {
            return true
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            let selected = textView.selectedRange()
            let ns = textView.liveText
            if selected.length == 0, let prev = Self.character(ns, selected.location - 1), let next = Self.character(ns, selected.location) {
                let pairs: [unichar: unichar] = [0x28: 0x29, 0x7B: 0x7D, 0x5B: 0x5D, 0x22: 0x22, 0x27: 0x27, 0x60: 0x60]
                if pairs[prev] == next {
                    let deleteRange = NSRange(location: selected.location - 1, length: 2)
                    if textView.shouldChangeText(in: deleteRange, replacementString: "") {
                        textView.textStorage?.replaceCharacters(in: deleteRange, with: "")
                        textView.didChangeText()
                        textView.setSelectedRange(NSRange(location: selected.location - 1, length: 0))
                    }
                    return true
                }
            }
        }
        let workspace = self.windowWorkspace
        if workspace.lsp.signatureHelp != nil, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            workspace.lsp.signatureHelp = nil
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleNewlineAutoIndentation(in: textView)
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return handleTabKey(in: textView)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktabKey(in: textView)
        }
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? GoLensTextView else { return }
        let selected = textView.selectedRange()
        let workspace = self.windowWorkspace
        CompletionController.shared.caretMoved(in: textView)
        textView.inlineSuggestions.caretMoved()
        let (line, col) = textView.lineAndCol(forCharacterIndex: selected.location)
        let hasSelection = selected.length > 0
        if textView.lastHighlightedCaretLine != line || textView.lastHadSelection != hasSelection {
            let previousLine = textView.lastHighlightedCaretLine
            textView.lastHighlightedCaretLine = line
            textView.lastHadSelection = hasSelection
            if previousLine > 0 { textView.invalidateLineBand(previousLine) }
            textView.invalidateLineBand(line)
        }
        let pane = workspace.paneState(for: textView.paneID)
        if workspace.lsp.signatureHelp != nil {
            signatureHelpWorkItem?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                guard let textView, workspace.lsp.signatureHelp != nil else { return }
                workspace.fetchSignatureHelp(for: textView, keepingAnchorOnLine: true)
            }
            signatureHelpWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        if pane.cursorLine != line {
            if workspace.issuePopup != nil { workspace.issuePopup = nil }
            pane.cursorLine = line
        }
        if pane.cursorCol != col { pane.cursorCol = col }
        if pane.hasSelection != hasSelection { pane.hasSelection = hasSelection }
        if textView.paneID == .primary {
            if workspace.activeLine != line { workspace.activeLine = line }
            if workspace.cursorLine != line { workspace.cursorLine = line }
            if workspace.cursorCol != col { workspace.cursorCol = col }
        }
        if textView.paneID == workspace.effectiveFocusedPaneID {
            if workspace.editorHasSelection != hasSelection { workspace.editorHasSelection = hasSelection }
            let position = "Ln \(line), Col \(col)" + (hasSelection ? " (\(selected.length) selected)" : "")
            if workspace.displayCursorPosition != position { workspace.displayCursorPosition = position }
        }
        updateBracketHighlighting(in: textView)
        if lastChange == nil {
            scheduleDocumentHighlight(in: textView)
        }
    }

    func clearDocumentHighlights(in textView: NSTextView) {
        guard !documentHighlightRanges.isEmpty else { return }
        let length = textView.textStorage?.length ?? 0
        let paneID = (textView as? GoLensTextView)?.paneID ?? .primary
        if !self.windowWorkspace.paneState(for: paneID).showLocalSearch, let lm = textView.layoutManager {
            for range in documentHighlightRanges where NSMaxRange(range) <= length {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
        }
        documentHighlightRanges.removeAll()
    }

    private func scheduleDocumentHighlight(in textView: GoLensTextView) {
        documentHighlightWorkItem?.cancel()
        guard textView.selectedRange().length == 0,
              textView.filePath.hasSuffix(".go"),
              !self.windowWorkspace.paneState(for: textView.paneID).showLocalSearch,
              let session = textView.document,
              session.syncsToCore else {
            clearDocumentHighlights(in: textView)
            return
        }
        let caret = textView.selectedRange().location
        let ns = session.storage.mutableString
        let isIdent: (unichar) -> Bool = { c in
            c == 0x5F || c >= 128 || (c < 128 && isalnum(Int32(c)) != 0)
        }
        let hasIdent = (caret < ns.length && isIdent(ns.character(at: caret))) ||
                       (caret > 0 && caret <= ns.length && isIdent(ns.character(at: caret - 1)))
        guard hasIdent else {
            clearDocumentHighlights(in: textView)
            return
        }
        let version = session.version
        let (line, col) = textView.lineAndCol(forCharacterIndex: caret)
        documentHighlightGeneration += 1
        let generation = documentHighlightGeneration
        let workItem = DispatchWorkItem { [weak self, weak textView, weak session] in
            guard let self, let textView, let session,
                  generation == self.documentHighlightGeneration,
                  textView.document === session,
                  session.version == version,
                  !self.windowWorkspace.paneState(for: textView.paneID).showLocalSearch,
                  textView.selectedRange().length == 0 else { return }
            let path = session.path
            Task {
                let highlights = await LSPClient.shared.requestDocumentHighlight(atLine: line, col: col, inPath: path)
                await MainActor.run {
                    guard generation == self.documentHighlightGeneration,
                          textView.document === session,
                          session.version == version,
                          !self.windowWorkspace.paneState(for: textView.paneID).showLocalSearch,
                          textView.selectedRange().length == 0,
                          let lm = textView.layoutManager else { return }
                    self.clearDocumentHighlights(in: textView)
                    guard highlights.count > 1 else { return }
                    let readColor = OccurrenceHighlight.read
                    let writeColor = OccurrenceHighlight.write
                    for h in highlights.prefix(Self.maxDocumentHighlights) {
                        guard let start = session.offset(line: h.range.start.line, utf16Column: h.range.start.character),
                              let end = session.offset(line: h.range.end.line, utf16Column: h.range.end.character),
                              end > start, end <= session.length else { continue }
                        let range = NSRange(location: start, length: end - start)
                        let color = (h.kind == 3) ? writeColor : readColor
                        lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                        self.documentHighlightRanges.append(range)
                    }
                }
            }
        }
        documentHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let textView = layoutManager.textContainers.first?.textView as? GoLensTextView,
              !textView.filePath.isEmpty,
              let merged = mergedFolds(for: textView.filePath), !merged.isEmpty, glyphRange.length > 0 else {
            return 0
        }
        var cursor = Self.foldIndex(in: merged, containingOrAfter: charIndexes[0])
        var previous = charIndexes[0]
        var foldedFlags: [Bool]?
        for i in 0..<glyphRange.length {
            let index = charIndexes[i]
            if index < previous { cursor = Self.foldIndex(in: merged, containingOrAfter: index) }
            previous = index
            while cursor < merged.count && NSMaxRange(merged[cursor]) <= index { cursor += 1 }
            if cursor < merged.count && index >= merged[cursor].location {
                if foldedFlags == nil { foldedFlags = [Bool](repeating: false, count: glyphRange.length) }
                foldedFlags?[i] = true
            }
        }
        guard let foldedFlags else { return 0 }
        let props = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { props.deallocate() }
        props.initialize(from: properties, count: glyphRange.length)
        for i in 0..<glyphRange.length where foldedFlags[i] {
            props[i] = .controlCharacter
        }
        layoutManager.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let textView = layoutManager.textContainers.first?.textView as? GoLensTextView,
              let merged = mergedFolds(for: textView.filePath), !merged.isEmpty else { return action }
        let i = Self.foldIndex(in: merged, containingOrAfter: charIndex)
        guard i < merged.count, NSLocationInRange(charIndex, merged[i]) else { return action }
        return merged[i].location == charIndex ? .whitespace : .zeroAdvancement
    }

    private func mergedFolds(for path: String) -> [NSRange]? {
        guard let folds = self.windowWorkspace.foldedCharRangesCache[path], !folds.isEmpty else { return nil }
        if let index = foldIndex, index.path == path, index.source.hasSameStorage(as: folds) { return index.merged }
        var merged: [NSRange] = []
        for fold in folds.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, fold.location < NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(fold)) - last.location
            } else {
                merged.append(fold)
            }
        }
        foldIndex = (path, folds, merged)
        return merged
    }

    static func foldIndex(in merged: [NSRange], containingOrAfter index: Int) -> Int {
        var lo = 0, hi = merged.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if NSMaxRange(merged[mid]) <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard let textView = layoutManager.textContainers.first?.textView as? GoLensTextView else { return 0 }
        return textView.inlineSuggestions.paragraphSpacing(afterGlyphAt: glyphIndex, layoutManager: layoutManager)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: glyphPosition.x, y: 0, width: GoLensTextView.foldPlaceholderWidth, height: proposedRect.height)
    }

    func handleTabKey(in textView: NSTextView) -> Bool {
        guard let textStorage = textView.textStorage else { return false }
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound else { return false }
        let tabSize = self.windowWorkspace.tabSize
        let filePath = (textView as? GoLensTextView)?.filePath ?? self.windowWorkspace.activeFilePath
        let filename = (filePath as NSString).lastPathComponent.lowercased()
        let ext = (filePath as NSString).pathExtension.lowercased()
        let usesHardTab = ext == "go" || ext == "mk" || filename == "makefile" || filename == "gnumakefile" || filename == "go.mod" || filename == "go.work"
        let usesTwoSpaces = ["yml", "yaml", "json", "jsonc", "html", "tmpl", "gotmpl", "xml", "md", "markdown"].contains(ext)
        let indent = usesHardTab ? "\t" : (usesTwoSpaces ? "  " : String(repeating: " ", count: tabSize))
        let indentLength = (indent as NSString).length
        let ns = textView.liveText
        if selectedRange.length == 0 {
            if textView.shouldChangeText(in: selectedRange, replacementString: indent) {
                textStorage.replaceCharacters(in: selectedRange, with: indent)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: selectedRange.location + indentLength, length: 0))
            }
            return true
        }
        let lineRange = ns.lineRange(for: selectedRange)
        let (indented, added) = SourceLineScanner.indentLines(in: ns.substring(with: lineRange), indent: indent)
        if textView.shouldChangeText(in: lineRange, replacementString: indented) {
            textStorage.replaceCharacters(in: lineRange, with: indented)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: lineRange.length + added))
        }
        return true
    }

    func handleBacktabKey(in textView: NSTextView) -> Bool {
        guard let textStorage = textView.textStorage else { return false }
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound else { return false }
        let tabSize = self.windowWorkspace.tabSize
        let ns = textView.liveText
        let lineRange = ns.lineRange(for: selectedRange)
        let (outdented, removed) = SourceLineScanner.outdentLines(in: ns.substring(with: lineRange), tabSize: tabSize)
        if textView.shouldChangeText(in: lineRange, replacementString: outdented) {
            textStorage.replaceCharacters(in: lineRange, with: outdented)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: max(0, lineRange.length - removed)))
        }
        return true
    }

    private static let bracketScanLimit = 20_000

    private func updateBracketHighlighting(in textView: NSTextView) {
        let length = textView.textStorage?.length ?? 0
        for range in highlightedBracketRanges where NSMaxRange(range) <= length {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedBracketRanges.removeAll()
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return }
        let ns = textView.liveText
        let loc = selected.location
        var index: Int?
        if let prev = Self.character(ns, loc - 1), Self.bracketPairs[prev] != nil {
            index = loc - 1
        } else if let next = Self.character(ns, loc), Self.bracketPairs[next] != nil {
            index = loc
        }
        let skip: (Int) -> Bool = { (textView as? GoLensTextView)?.inCommentOrString(at: $0, in: ns) == true }
        guard let idx = index, !skip(idx), let match = findMatchingBracket(at: idx, in: ns, skip: skip) else { return }
        let color = NSColor.textColor.withAlphaComponent(0.15)
        for r in [NSRange(location: idx, length: 1), NSRange(location: match, length: 1)] {
            textView.layoutManager?.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: r)
            highlightedBracketRanges.append(r)
        }
    }

    private func findMatchingBracket(at index: Int, in ns: NSString, skip: (Int) -> Bool) -> Int? {
        guard let c = Self.character(ns, index), let (target, forward) = Self.bracketPairs[c] else { return nil }
        let scanRange = forward
            ? NSRange(location: index + 1, length: min(Self.bracketScanLimit, ns.length - index - 1))
            : NSRange(location: max(0, index - Self.bracketScanLimit), length: min(Self.bracketScanLimit, index))
        guard scanRange.length > 0 else { return nil }
        let chunk = Self.bracketScanChunk
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunk) { buffer -> Int? in
            var depth = 1
            var done = 0
            while done < scanRange.length {
                let n = min(chunk, scanRange.length - done)
                let start = forward ? scanRange.location + done : NSMaxRange(scanRange) - done - n
                ns.getCharacters(buffer.baseAddress!, range: NSRange(location: start, length: n))
                for i in stride(from: forward ? 0 : n - 1, through: forward ? n - 1 : 0, by: forward ? 1 : -1) {
                    let u = buffer[i]
                    guard u == c || u == target, !skip(start + i) else { continue }
                    if u == c { depth += 1 } else {
                        depth -= 1
                        if depth == 0 { return start + i }
                    }
                }
                done += n
            }
            return nil
        }
    }

    private static let bracketScanChunk = 1024
    private static let bracketPairs: [unichar: (unichar, Bool)] = [0x28: (0x29, true), 0x7B: (0x7D, true), 0x5B: (0x5D, true), 0x29: (0x28, false), 0x7D: (0x7B, false), 0x5D: (0x5B, false)]
}

extension MacTextView {
    static let inspectConcurrencyMenuTitle = "Inspect Concurrency & Context…"
}

extension Notification.Name {
    static let golensDiagnosticsChanged = Notification.Name("GoLensDiagnosticsChanged")
    static let golensInjectedSQLChanged = Notification.Name("GoLensInjectedSQLChanged")
    static let golensLanguageServerReady = Notification.Name("GoLensLanguageServerReady")
    static let golensGoplsDiagnosticsPublished = Notification.Name("GoLensGoplsDiagnosticsPublished")
    static let golensInlayHintsToggled = Notification.Name("GoLensInlayHintsToggled")
    static let golensOpticalLensModeChanged = Notification.Name("GoLensOpticalLensModeChanged")
}
