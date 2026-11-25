import SwiftUI
import AppKit
import GoLensFoundation


extension GoLensTextView {
    override func characterIndex(for point: NSPoint) -> Int {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return NSNotFound }
        var localPoint = point
        localPoint.x -= self.textContainerOrigin.x
        localPoint.y -= self.textContainerOrigin.y
        return layoutManager.characterIndex(for: localPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
    }
    
    func lineAndCol(forCharacterIndex index: Int) -> (line: Int, col: Int) {
        guard let document else { return (1, 1) }
        let (line, col) = document.lineAndColumn(at: index)
        return (line + 1, col + 1)
    }

    func wordRange(at index: Int) -> NSRange {
        let nsString = self.string as NSString
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = index
        while start > 0 {
            let prev = nsString.substring(with: NSRange(location: start - 1, length: 1))
            guard let scalar = prev.unicodeScalars.first, allowed.contains(scalar) else { break }
            start -= 1
        }
        var end = index
        while end < nsString.length {
            let current = nsString.substring(with: NSRange(location: end, length: 1))
            guard let scalar = current.unicodeScalars.first, allowed.contains(scalar) else { break }
            end += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }
    
    func characterIndex(forLine line: Int, col: Int) -> Int? {
        document?.offset(line: line - 1, utf16Column: max(1, col) - 1)
    }

    func jumpTo(path: String, line: Int, col: Int) {
        let fullPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.workspaceState.recordNavigationJump(toPath: fullPath, line: line, col: col)
        if self.workspaceState.activeFilePath == fullPath {
            if let targetIdx = self.characterIndex(forLine: line, col: col) {
                let targetRange = NSRange(location: targetIdx, length: 0)
                self.setSelectedRange(targetRange)
                self.scrollRangeToVisible(targetRange)
                highlightLine(line, in: self)
            }
            self.workspaceState.cursorLine = max(1, line)
            self.workspaceState.cursorCol = max(1, col)
        } else {
            self.workspaceState.pendingJumpToLine = line
            self.workspaceState.pendingJumpToCol = col
            self.workspaceState.openFile(fullPath)
        }
    }
    
    func highlightLine(_ line: Int, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let range = document?.lineRange(line - 1) else { return }
        
        let highlightColor = NSColor.controlAccentColor.withAlphaComponent(0.2)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let currentLayoutManager = textView.layoutManager, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) {
                currentLayoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
        }
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        let clipWidth = max(100, enclosingScrollView?.contentSize.width ?? 100)
        if minSize.width != clipWidth {
            minSize = NSSize(width: clipWidth, height: minSize.height)
        }
        var resolvedWidth = max(newSize.width, clipWidth)
        let wrap = appliedWordWrapState ?? self.workspaceState.wordWrapEnabled
        if wrap {
            resolvedWidth = clipWidth
            let reserved = resolvedOpticalLensStyle(forViewportWidth: resolvedWidth).reservedMarginWidth
            let containerWidth = max(80, resolvedWidth - reserved)
            if textContainer?.containerSize.width != containerWidth {
                textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        } else if let lm = layoutManager, let tc = textContainer {
            let pad = tc.lineFragmentPadding
            let usedMaxX = max(pad, lm.usedRect(for: tc).maxX - pad) + textContainerOrigin.x
            let optW = resolvedOpticalLensStyle(forViewportWidth: clipWidth).reservedMarginWidth
            if usedMaxX > clipWidth - optW - 12 {
                resolvedWidth = max(clipWidth, ceil(usedMaxX + optW + 16))
            } else {
                resolvedWidth = clipWidth
            }
        }
        let size = NSSize(width: resolvedWidth, height: newSize.height)
        guard size != frame.size else { return }
        if size.width == frame.width, abs(size.height - frame.height) < wobbleSlack,
           visibleRect.maxY < min(size.height, frame.height) - wobbleSlack {
            deferredHeight = size.height
            return
        }
        deferredHeight = nil
        super.setFrameSize(size)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        let wrap = appliedWordWrapState ?? self.workspaceState.wordWrapEnabled
        guard !wrap,
              let lm = layoutManager,
              let tc = textContainer,
              liveText.length > 0 else { return }
        let clampedStart = min(max(0, range.location), liveText.length)
        let clampedEnd = min(max(clampedStart, NSMaxRange(range)), liveText.length)
        let safeRange = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
        let glyphRange = lm.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        let glyphRect: NSRect
        if glyphRange.length == 0 {
            let probeChar = min(clampedStart, max(0, liveText.length - 1))
            let gIdx = lm.glyphIndexForCharacter(at: probeChar)
            guard gIdx < lm.numberOfGlyphs else { return }
            let loc = lm.location(forGlyphAt: gIdx)
            let frag = lm.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: nil)
            glyphRect = NSRect(x: loc.x + textContainerOrigin.x, y: frag.minY + textContainerOrigin.y, width: 2, height: frag.height)
        } else {
            var box = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            box.origin.x += textContainerOrigin.x
            box.origin.y += textContainerOrigin.y
            glyphRect = box
        }
        let vis = visibleRect
        let leftClearance = gutterWidth + 6
        let rightClearance = opticalMarginWidth + 12
        let usableWidth = max(40, vis.width - leftClearance - rightClearance)
        var targetX: CGFloat
        if glyphRect.maxX <= leftClearance + usableWidth {
            targetX = 0
        } else {
            targetX = vis.origin.x
            if glyphRect.maxX > targetX + leftClearance + usableWidth {
                targetX = glyphRect.maxX - (leftClearance + usableWidth)
            }
            if glyphRect.minX < targetX + leftClearance {
                targetX = glyphRect.minX - leftClearance
            }
        }
        targetX = max(0, min(targetX, max(0, bounds.width - vis.width)))
        if targetX < 20 {
            targetX = 0
        }
        if abs(targetX - vis.origin.x) > 0.5 {
            scroll(NSPoint(x: round(targetX), y: vis.origin.y))
        }
    }


    override func becomeFirstResponder() -> Bool {
        let status = super.becomeFirstResponder()
        if status {
            let ws = self.workspaceState
            ws.activeTextView = self
            let resolvedPane: EditorPaneID = ws.isSplitMode ? self.paneID : .primary
            if ws.focusedPaneID != resolvedPane {
                ws.focusedPaneID = resolvedPane
            }
            setNeedsDisplay(visibleRect)
            if hasMultipleCursors { refreshMultiCursorDisplay() }
        }
        return status
    }

    override func resignFirstResponder() -> Bool {
        let status = super.resignFirstResponder()
        if status {
            inlineSuggestions.dismiss()
            finishInlineRename()
            setNeedsDisplay(visibleRect)
            if hasMultipleCursors { refreshMultiCursorDisplay() }
            let workspace = self.workspaceState
            DispatchQueue.main.async { [weak self] in
                self?.dismissHoverImmediate()
                workspace.dismissTransientEditorOverlays(includeRename: false, includePopovers: false)
            }
        }
        return status
    }

    private func runEditorShortcut(_ chord: KeyChord) -> Bool {
        let ws = self.workspaceState
        let hasProject = !ws.activeWorkspacePath.isEmpty
        let isGo = filePath.hasSuffix(".go")
        let commands: [(id: String, alias: String?, run: () -> Bool)] = [
            ("view.quickDocumentation", "f1", { guard isGo else { return false }; self.showQuickDocumentation(); return true }),
            ("view.quickDocumentation", "ctrl+shift+cmd+/", { guard isGo else { return false }; self.showQuickDocumentation(); return true }),
            ("view.commandPalette", nil, { guard hasProject else { return false }; ws.showCommandPalette.toggle(); return true }),
            ("product.attach", nil, { guard hasProject && !ws.isRunning else { return false }; ws.presentAttachProcessSheet(); return true }),
            ("navigate.callHierarchy", "ctrl+shift+cmd+h", { guard isGo else { return false }; ws.showCallHierarchyAtCaret(); return true }),
            ("product.profileTests", "ctrl+alt+cmd+u", { guard hasProject && !ws.isRunning else { return false }; ws.profileAllTests(); return true }),
            ("navigate.workspaceSymbol", nil, { guard hasProject else { return false }; ws.showWorkspaceSymbol.toggle(); return true }),
            ("product.compareBenchmarks", nil, { ws.presentBenchmarkComparisonSheet(); return true }),
            ("generate.fillStruct", nil, { guard isGo else { return false }; ws.fillStructFieldsAtCursor(); return true }),
            ("refactor.rename", nil, { guard isGo else { return false }; self.triggerRename(); return true }),
            ("navigate.toggleBookmark", nil, { guard !self.filePath.isEmpty else { return false }; ws.toggleBookmarkAtCaret(); return true }),
            ("navigate.nextBookmark", nil, { guard hasProject else { return false }; ws.navigateToNextBookmark(); return true }),
            ("navigate.previousBookmark", nil, { guard hasProject else { return false }; ws.navigateToPreviousBookmark(); return true }),
        ]
        let keymap = KeymapStore.shared.keymap
        for command in commands {
            let matches = keymap.chord(for: command.id) == chord
                || (command.alias.flatMap(KeyChord.init) == chord && keymap.commands(using: chord).isEmpty)
            if matches && command.run() { return true }
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if inlineRename != nil, window?.firstResponder === self, handleInlineRenameKeyEquivalent(event) { return true }
        if let chord = KeyChord(event: event), runEditorShortcut(chord) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard self.workspaceState.activePopup == nil, window?.attachedSheet == nil else { return }
        dismissHover()
        
        let hasOption = event.modifierFlags.contains(.option)
        let hasShift = event.modifierFlags.contains(.shift)
        let hasControl = event.modifierFlags.contains(.control)
        let hasCommand = event.modifierFlags.contains(.command)
        
        if hasOption && hasShift && !hasControl && !hasCommand, event.keyCode == 126 || event.keyCode == 125,
           let chord = KeyChord(event: event), KeymapStore.shared.keymap.commands(using: chord).isEmpty {
            duplicateLine(down: event.keyCode == 125)
            return
        }
        
        if hasControl && event.keyCode == 49 {
            CompletionController.shared.trigger(in: self)
            return
        }
        
        if let chord = KeyChord(event: event), chord.isFunctionKey, runEditorShortcut(chord) {
            return
        }
        
        super.keyDown(with: event)
    }
    
    func getWord(at location: Int) -> String? {
        let nsString = self.string as NSString
        guard location >= 0 && location <= nsString.length else { return nil }
        
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = location
        while start > 0 {
            let char = nsString.substring(with: NSRange(location: start - 1, length: 1))
            guard let scalar = char.unicodeScalars.first, validChars.contains(scalar) else { break }
            start -= 1
        }
        
        var end = location
        while end < nsString.length {
            let char = nsString.substring(with: NSRange(location: end, length: 1))
            guard let scalar = char.unicodeScalars.first, validChars.contains(scalar) else { break }
            end += 1
        }
        
        if start < end {
            return nsString.substring(with: NSRange(location: start, length: end - start))
        }
        return nil
    }
    
    private func duplicateLine(down: Bool) {
        guard let textStorage = self.textStorage else { return }
        let selectedRange = self.selectedRange()
        guard selectedRange.location != NSNotFound else { return }
        
        let nsString = self.string as NSString
        let lineRange = nsString.lineRange(for: selectedRange)
        var selectedLinesText = nsString.substring(with: lineRange)
        
        if !selectedLinesText.hasSuffix("\n") {
            selectedLinesText += "\n"
        }
        
        let insertLoc = down ? (lineRange.location + lineRange.length) : lineRange.location
        let insertRange = NSRange(location: insertLoc, length: 0)
        
        self.breakUndoCoalescing()
        if self.shouldChangeText(in: insertRange, replacementString: selectedLinesText) {
            textStorage.replaceCharacters(in: insertRange, with: selectedLinesText)
            self.didChangeText()
            self.breakUndoCoalescing()
            
            let shift = selectedLinesText.utf16.count
            self.setSelectedRange(NSRange(location: selectedRange.location + shift, length: selectedRange.length))
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let sel = selectedRange()
        breakUndoCoalescing()
        guard sel.length > 0 else { duplicateLine(down: true); return }
        let text = (string as NSString).substring(with: sel)
        let at = NSRange(location: NSMaxRange(sel), length: 0)
        guard shouldChangeText(in: at, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: at, with: text)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: NSMaxRange(sel), length: sel.length))
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        addNextOccurrence()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if let caret = quickDocumentationCaret, ranges.first?.rangeValue.location != caret {
            dismissHoverImmediate()
        }
        if !multiCursor.applying { endMultiCursor() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if inlineRename != nil, let selection = ranges.first?.rangeValue { inlineRenameSelectionChanged(selection) }
    }

    override func doCommand(by selector: Selector) {
        guard self.workspaceState.activePopup == nil else { return }
        if inlineRename != nil, handleInlineRenameCommand(selector) { return }
        if selector == #selector(NSResponder.cancelOperation(_:)), quickDocumentationCaret != nil, !CompletionController.shared.isVisible {
            closeQuickDocumentation()
            return
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), self.workspaceState.issuePopup != nil, !CompletionController.shared.isVisible {
            self.workspaceState.issuePopup = nil
            return
        }
        if handleMultiCursorCommand(selector) { return }
        super.doCommand(by: selector)
    }

    func blameHitLine(at point: NSPoint) -> Int? {
        let workspace = self.workspaceState
        guard workspace.showInlineGitBlame, let hit = blameHit, hit.rect.contains(point),
              let blame = workspace.activeLineGitBlame, blame.path == filePath, blame.line == hit.line else { return nil }
        return hit.line
    }

    override func mouseDown(with event: NSEvent) {
        let priorIssuePopup = self.workspaceState.issuePopup
        let ws = self.workspaceState
        ws.activeTextView = self
        let resolvedPane: EditorPaneID = ws.isSplitMode ? self.paneID : .primary
        if ws.focusedPaneID != resolvedPane {
            ws.focusedPaneID = resolvedPane
        }
        dismissHover()
        self.workspaceState.dismissTransientEditorOverlays(includeRename: false, includePopovers: true)
        CompletionController.shared.dismiss()
        
        let localPoint = self.convert(event.locationInWindow, from: nil)
        if let compact = compactLensItem(at: localPoint) {
            opticalLensMargin.presentCompactPopover(for: compact.item, anchorRect: compact.rect, in: self)
            return
        }
        if renameSuggestion != nil, let rect = renameHitRect, rect.insetBy(dx: -2, dy: -2).contains(localPoint) {
            acceptRenameSuggestion()
            return
        }
        if blameHitLine(at: localPoint) != nil {
            self.workspaceState.presentFileHistory(for: filePath, focusCaretLine: true)
            return
        }
        if let hit = mergeConflictAction(at: localPoint) {
            performMergeConflictAction(hit.action, line: hit.line, anchor: hit.rect)
            return
        }
        if let lens = lens(at: localPoint) {
            self.workspaceState.runEditorLensCommand(lens.command, title: lens.title)
            return
        }
        if let hit = issue(at: localPoint) {
            if priorIssuePopup?.path == self.filePath && priorIssuePopup?.line == hit.line {
                self.workspaceState.issuePopup = nil
            } else {
                self.workspaceState.toggleIssuePopup(in: self, line: hit.line, diags: hit.issues, below: hit.rect)
            }
            return
        }
        if let impls = implementations(at: localPoint) {
            if impls.count == 1, let only = impls.first {
                jumpTo(path: only.path, line: only.range.start.line + 1, col: only.range.start.character + 1)
            } else {
                let line = implHitRects.first { $0.value.0.contains(localPoint) }?.key
                let declName = line.flatMap { ln in self.workspaceState.activeGoDeclarations.first(where: { $0.line == ln })?.symbolName }
                let symbolName = declName ?? self.getWord(at: self.selectedRange().location) ?? "symbol"
                self.workspaceState.showReferences(impls, for: symbolName, kind: "Implementations")
            }
            return
        }
        if let usageLn = usageLine(at: localPoint) {
            showUsagesForDeclaration(atLine: usageLn)
            return
        }
        if isPointInOpticalMargin(localPoint) {
            return
        }
        let gutterRelativeX = localPoint.x - visibleRect.origin.x
        if gutterRelativeX >= 0 && gutterRelativeX < gutterWidth {
            if let clickedLine = findLineNumber(atY: localPoint.y) {
                let workspace = self.workspaceState
                
                if gutterRelativeX >= gutterWidth - 6, workspace.showsSourceControlChanges, workspace.git.activeFileDiffs[clickedLine] != nil {
                    showGitHunkPopover(line: clickedLine, y: localPoint.y)
                } else if isTestMarkHit(localPoint, line: clickedLine), let target = testTarget(atLine: clickedLine) {
                    if !workspace.isRunning {
                        GetStartedProgress.shared.complete(.runTestFromGutter)
                        workspace.runTests(target)
                    }
                } else if isGoGenerateMarkHit(localPoint, line: clickedLine),
                          let genLens = workspace.goplsLenses[filePath]?[clickedLine]?.first(where: { ($0.command["golensCommand"] as? String) == "goGenerate" }) {
                    if !workspace.isRunning { workspace.runLSPCommand(genLens.command, title: genLens.title) }
                } else if gutterRelativeX < Self.foldColumnWidth, workspace.foldableStartLines[filePath]?.contains(clickedLine) == true {
                    workspace.toggleFold(forLine: clickedLine, in: filePath, textView: self)
                } else if event.modifierFlags.contains(.option) {
                    workspace.toggleBookmark(forLine: clickedLine, in: filePath)
                } else if filePath.hasSuffix(".go") {
                    workspace.toggleBreakpoint(forLine: clickedLine, in: filePath)
                } else {
                    workspace.toggleBookmark(forLine: clickedLine, in: filePath)
                }
                let gutterRect = NSRect(x: visibleRect.origin.x, y: 0, width: gutterWidth, height: self.bounds.height)
                self.setNeedsDisplay(gutterRect)
                self.setNeedsDisplay(self.visibleRect)
            }
            return
        }
        
        if beginMultiCursorMouse(with: event, at: localPoint) { return }

        if event.modifierFlags.contains(.command) {
            let charIndex = self.characterIndex(for: localPoint)
            if charIndex >= 0 && charIndex < self.string.utf16.count {
                goToDefinition(at: charIndex)
            }
            return
        }
        
        super.mouseDown(with: event)
    }

    func findLineNumber(atY y: CGFloat) -> Int? {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return nil }
        let textLength = liveText.length
        let containerY = y - self.textContainerInset.height
        guard containerY >= -2 else { return nil }
        if textLength == 0 || layoutManager.numberOfGlyphs == 0 {
            let lineH = layoutManager.defaultLineHeight(for: font ?? lineNumberFont)
            return containerY <= lineH + 2 ? 1 : nil
        }
        let probe = NSPoint(x: textContainer.lineFragmentPadding + 2, y: max(0, containerY))
        let glyphIndex = layoutManager.glyphIndex(for: probe, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let clickBuffer: CGFloat = 2
        guard containerY >= fragRect.minY - clickBuffer && containerY <= fragRect.maxY + clickBuffer else {
            return nil
        }
        let charIndex = min(layoutManager.characterIndexForGlyph(at: glyphIndex), max(0, textLength - 1))
        if let document {
            return document.lines.line(at: charIndex) + 1
        }
        let prefix = (liveText as NSString).substring(to: charIndex)
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    @objc(smokeLensHitPointForCharacterIndex:title:index:)
    func smokeLensHitPoint(forCharacterIndex charIndex: Int, title: String, index: Int) -> NSPoint {
        setNeedsDisplay(visibleRect)
        displayIfNeeded()
        let safeChar = min(max(0, charIndex), max(0, liveText.length - 1))
        let lineNumber = lineAndCol(forCharacterIndex: safeChar).line

        if let actions = conflictActionHitRects[lineNumber], !actions.isEmpty {
            if let match = actions.first(where: { $0.1.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return NSPoint(x: match.0.midX, y: match.0.midY)
            }
            if actions.indices.contains(index) {
                return NSPoint(x: actions[index].0.midX, y: actions[index].0.midY)
            }
        }

        if let lenses = lensHitRects[lineNumber], !lenses.isEmpty {
            if let match = lenses.first(where: { $0.1.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return NSPoint(x: match.0.midX, y: match.0.midY)
            }
            if !title.isEmpty, let match = lenses.first(where: { $0.1.title.localizedCaseInsensitiveContains(title) }) {
                return NSPoint(x: match.0.midX, y: match.0.midY)
            }
            if lenses.indices.contains(index) {
                return NSPoint(x: lenses[index].0.midX, y: lenses[index].0.midY)
            }
        }

        if title.localizedCaseInsensitiveContains("usage"), let usageRect = usageHitRects[lineNumber] {
            return NSPoint(x: usageRect.midX, y: usageRect.midY)
        }

        if (title.localizedCaseInsensitiveContains("implement") || title.localizedCaseInsensitiveContains("interface")),
           let implEntry = implHitRects[lineNumber] {
            return NSPoint(x: implEntry.0.midX, y: implEntry.0.midY)
        }

        if let issueEntry = issueHitRects[lineNumber],
           (title.localizedCaseInsensitiveContains("error") || title.localizedCaseInsensitiveContains("warning") || title.localizedCaseInsensitiveContains("issue")) {
            return NSPoint(x: issueEntry.0.midX, y: issueEntry.0.midY)
        }

        if index == 0, let usageRect = usageHitRects[lineNumber] {
            return NSPoint(x: usageRect.midX, y: usageRect.midY)
        }

        if let compact = compactLensHitRects[lineNumber] {
            return NSPoint(x: compact.0.midX, y: compact.0.midY)
        }

        return .zero
    }

    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        let lensElements = opticalLensMargin.currentAccessibilityElements()
        return lensElements.isEmpty ? (base.isEmpty ? nil : base) : base + lensElements
    }
    
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let base = super.accessibilityCustomActions()
        let extra = inlineSuggestions.accessibilityActions() + mergeConflictAccessibilityActions()
        return extra.isEmpty ? base : extra + (base ?? [])
    }
}

extension GoLensTextView {
    func completeCurrentStatement() {
        let title = "Complete Current Statement"
        guard filePath.hasSuffix(".go"), let textStorage else {
            workspaceState.presentCommandFeedback("Complete Current Statement works in Go files.", title: title)
            return
        }
        guard !hasMultipleCursors else {
            workspaceState.presentCommandFeedback("Complete Current Statement works with one cursor. Press Esc to return to a single cursor.", title: title)
            return
        }
        guard let edit = StatementCompletion.compute(text: string, caret: selectedRange().location) else {
            workspaceState.presentCommandFeedback("Place the caret on a line of code to complete it.", title: title)
            return
        }
        CompletionController.shared.dismiss()
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        undoManager?.setActionName(title)
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: edit.caret, length: 0))
        scrollRangeToVisible(selectedRange())
    }
}
