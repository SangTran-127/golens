import SwiftUI
import AppKit
import GoLensFoundation


extension GoLensTextView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            self.removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow]
        let newArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        self.addTrackingArea(newArea)
        self.trackingArea = newArea
    }
    private var isOverlayBlockingEditorHover: Bool {
        CompletionController.shared.isVisible ||
            self.workspaceState.activePopup != nil ||
            self.workspaceState.isRenaming
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverlayBlockingEditorHover {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverlayBlockingEditorHover {
            clearTableLink()
            dismissHoverImmediate()
            NSCursor.arrow.set()
            return
        }

        super.mouseMoved(with: event)
        
        let localPoint = self.convert(event.locationInWindow, from: nil)

        if !event.modifierFlags.contains(.command) { clearTableLink() }
        if event.modifierFlags.contains(.command) {
            if !isPointInGutter(localPoint) && !isPointInOpticalMargin(localPoint) {
                let charIdx = self.characterIndex(for: localPoint)
                let nsStr = liveText
                updateTableLink(atCharacter: charIdx)
                if charIdx >= 0 && charIdx < nsStr.length {
                    let char = Character(UnicodeScalar(nsStr.character(at: charIdx))!)
                    if !char.isWhitespace && !char.isNewline {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.iBeam.set()
                    }
                } else {
                    NSCursor.iBeam.set()
                }
            } else {
                clearTableLink()
                NSCursor.arrow.set()
            }
        } else if compactLensItem(at: localPoint) != nil || mergeConflictAction(at: localPoint) != nil || lens(at: localPoint) != nil || implementations(at: localPoint) != nil || usageLine(at: localPoint) != nil || issue(at: localPoint) != nil || (renameSuggestion != nil && renameHitRect?.contains(localPoint) == true) || blameHitLine(at: localPoint) != nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
            scheduleHoverDismiss()
            NSCursor.pointingHand.set()
            return
        } else if isPointInOpticalMargin(localPoint) {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if quickDocumentationCaret == nil { hoverRequestID += 1 }
            scheduleHoverDismiss()
            NSCursor.arrow.set()
            return
        } else {
            if isPointInGutter(localPoint) {
                if let clickedLine = findLineNumber(atY: localPoint.y),
                   isTestMarkHit(localPoint, line: clickedLine) || isGoGenerateMarkHit(localPoint, line: clickedLine) {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            } else {
                NSCursor.iBeam.set()
            }
        }
        
        if isPointInGutter(localPoint) {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if quickDocumentationCaret == nil { hoverRequestID += 1 }
            scheduleHoverDismiss()
            let hoverLine = findLineNumber(atY: localPoint.y)
            if self.workspaceState.hoverGutterLine != hoverLine {
                self.workspaceState.hoverGutterLine = hoverLine
                let gutterInvalidRect = NSRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: gutterWidth, height: visibleRect.height)
                self.setNeedsDisplay(gutterInvalidRect)
            }
            return
        } else {
            if self.workspaceState.hoverGutterLine != nil {
                self.workspaceState.hoverGutterLine = nil
                let gutterInvalidRect = NSRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: gutterWidth, height: visibleRect.height)
                self.setNeedsDisplay(gutterInvalidRect)
            }
        }
        
        let charIdx = self.characterIndex(for: localPoint)
        let nsStr = liveText
        guard charIdx >= 0 && charIdx < nsStr.length else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if quickDocumentationCaret == nil { hoverRequestID += 1 }
            scheduleHoverDismiss()
            return
        }
        
        guard let scalar = UnicodeScalar(nsStr.character(at: charIdx)) else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if quickDocumentationCaret == nil { hoverRequestID += 1 }
            scheduleHoverDismiss()
            return
        }
        let char = Character(scalar)
        if char.isWhitespace || char.isNewline {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if quickDocumentationCaret == nil { hoverRequestID += 1 }
            scheduleHoverDismiss()
            return
        }

        if CFAbsoluteTimeGetCurrent() - lastScrollTime < 0.15 {
            hoverTimer?.invalidate()
            hoverTimer = nil
            return
        }

        let wRange = wordRangeForHover(at: charIdx, in: nsStr)
        let lsp = self.workspaceState.lsp
        if lsp.hoverText != nil,
           lsp.hoveredFilePath == self.filePath,
           lsp.hoveredWordRange.location != NSNotFound,
           NSLocationInRange(charIdx, lsp.hoveredWordRange) {
            hoverDismissTimer?.invalidate()
            hoverDismissTimer = nil
            return
        }

        if lsp.hoverText != nil || self.workspaceState.issuePopup != nil {
            scheduleHoverDismiss()
        } else {
            hoverDismissTimer?.invalidate()
            hoverDismissTimer = nil
        }

        hoverTimer?.invalidate()
        if quickDocumentationCaret != nil { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.workspaceState.lsp.hoverText != nil && self.workspaceState.lsp.isMouseInsideHoverPopover { return }
            self.triggerHover(at: charIdx, wordRange: wRange)
        }
    }
    
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)

        if isOverlayBlockingEditorHover {
            clearTableLink()
            NSCursor.arrow.set()
            return
        }
        
        let windowPoint = self.window?.mouseLocationOutsideOfEventStream ?? .zero
        let localPoint = self.convert(windowPoint, from: nil)
        
        if event.modifierFlags.contains(.command) {
            if !isPointInGutter(localPoint) && !isPointInOpticalMargin(localPoint) && self.bounds.contains(localPoint) {
                let charIdx = self.characterIndex(for: localPoint)
                let nsStr = liveText
                updateTableLink(atCharacter: charIdx)
                if charIdx >= 0 && charIdx < nsStr.length {
                    let char = Character(UnicodeScalar(nsStr.character(at: charIdx))!)
                    if !char.isWhitespace && !char.isNewline {
                        NSCursor.pointingHand.set()
                        return
                    }
                }
            }
        } else {
            clearTableLink()
            if self.bounds.contains(localPoint) {
                if isPointInGutter(localPoint) || isPointInOpticalMargin(localPoint) {
                    NSCursor.arrow.set()
                } else {
                    NSCursor.iBeam.set()
                }
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearTableLink()
        hoverTimer?.invalidate()
        hoverTimer = nil
        if quickDocumentationCaret == nil { hoverRequestID += 1 }
        scheduleHoverDismiss()
        if self.workspaceState.hoverGutterLine != nil {
            self.workspaceState.hoverGutterLine = nil
            let gutterInvalidRect = NSRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: gutterWidth, height: visibleRect.height)
            self.setNeedsDisplay(gutterInvalidRect)
        }
    }

    private func wordRangeForHover(at charIndex: Int, in nsStr: NSString) -> NSRange {
        let len = nsStr.length
        guard charIndex >= 0 && charIndex < len else {
            return NSRange(location: charIndex, length: 0)
        }
        let inString = inCommentOrString(at: charIndex, in: nsStr)
        func isTokenChar(_ c: unichar) -> Bool {
            guard let s = UnicodeScalar(c) else { return false }
            if CharacterSet.alphanumerics.contains(s) { return true }
            if inString {
                return s == "_" || s == "/" || s == "." || s == "-"
            }
            return s == "_"
        }
        if !isTokenChar(nsStr.character(at: charIndex)) {
            return NSRange(location: charIndex, length: 1)
        }
        var start = charIndex
        while start > 0 && isTokenChar(nsStr.character(at: start - 1)) {
            start -= 1
        }
        var end = charIndex + 1
        while end < len && isTokenChar(nsStr.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: max(1, end - start))
    }

    func showCodeActionsForHover() {
        let lsp = self.workspaceState.lsp
        guard lsp.hoveredFilePath == filePath,
              let target = CodeActionTarget.hover(word: lsp.hoveredWordRange, diagnostic: lsp.hoveredDiagnosticRange, textLength: (string as NSString).length) else {
            self.workspaceState.presentCommandFeedback("No code actions are available at the hovered symbol.", title: "Code Actions")
            return
        }
        dismissHoverImmediate()
        self.workspaceState.showCodeActionsMenu(for: self, target: target)
    }

    func popupBoundsInWindow() -> CGRect {
        guard let window, let contentView = window.contentView, let scrollView = enclosingScrollView else { return .zero }
        let insets = scrollView.contentInsets
        var visible = scrollView.bounds
        visible.origin.y += scrollView.isFlipped ? insets.top : insets.bottom
        visible.size.height -= insets.top + insets.bottom
        let inWindow = scrollView.convert(visible, to: nil)
        return CGRect(x: inWindow.minX, y: contentView.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    func isMouseStillOverHoveredTokenOrPopup() -> Bool {
        let lsp = self.workspaceState.lsp
        let mouseScreen = NSEvent.mouseLocation
        for win in NSApp.windows where win.isVisible {
            let className = NSStringFromClass(type(of: win))
            if className.contains("PopupPanel") {
                if win.frame.insetBy(dx: -10, dy: -10).contains(mouseScreen) {
                    return true
                }
            }
        }
        if lsp.isMouseInsideHoverPopover {
            lsp.isMouseInsideHoverPopover = false
        }
        if let win = self.window {
            let winPoint = win.convertPoint(fromScreen: mouseScreen)
            let localPoint = self.convert(winPoint, from: nil)
            if let activeIssuePopup = self.workspaceState.issuePopup,
               activeIssuePopup.path == self.filePath,
               let hit = issue(at: localPoint),
               hit.line == activeIssuePopup.line {
                return true
            }
            if lsp.hoveredFilePath == self.filePath,
               lsp.hoveredWordRange.location != NSNotFound,
               self.bounds.contains(localPoint) && localPoint.x >= gutterWidth {
                let idx = self.characterIndex(for: localPoint)
                if idx != NSNotFound && NSLocationInRange(idx, lsp.hoveredWordRange) {
                    return true
                }
            }
        }
        return false
    }
    
    private func triggerHover(at charIndex: Int, wordRange: NSRange? = nil) {
        guard !CompletionController.shared.isVisible, let window = self.window, let contentView = window.contentView else { return }
        
        let nsString = self.string as NSString
        let resolvedWordRange = wordRange ?? wordRangeForHover(at: charIndex, in: nsString)
        let anchorIndex = min(max(0, resolvedWordRange.location), max(0, nsString.length - 1))
        let screenRect = self.firstRect(forCharacterRange: NSRange(location: anchorIndex, length: max(1, min(resolvedWordRange.length, nsString.length - anchorIndex))), actualRange: nil)
        let windowRect = window.convertFromScreen(screenRect)
        let windowHeight = contentView.bounds.height
        let swiftUIX = windowRect.origin.x
        let swiftUIY = windowHeight - (windowRect.origin.y + windowRect.size.height)
        
        let targetRect = CGRect(x: swiftUIX, y: swiftUIY, width: max(16, windowRect.width), height: windowRect.height)
        let targetBounds = popupBoundsInWindow()
        var diagnosticRange = NSRange(location: NSNotFound, length: 0)
        let presentHover: (String) -> Void = { [weak self] text in
            guard let self else { return }
            let lsp = self.workspaceState.lsp
            lsp.hoveredFilePath = self.filePath
            lsp.hoveredWordRange = resolvedWordRange
            lsp.hoveredDiagnosticRange = diagnosticRange
            lsp.hoveredEditor = self
            lsp.hoverRect = targetRect
            lsp.hoverBounds = targetBounds
            lsp.hoverText = text
        }
        
        var combinedText = ""
        var foundDiag: DiagnosticData? = nil
        let workspace = self.workspaceState
        
        let diags = workspace.diagnosticsForPath(self.filePath)
        
        for diag in diags {
            guard let startIdx = self.characterIndex(forLine: diag.line + 1, col: diag.col + 1) else { continue }
            
            let endIdx: Int
            if let calculatedEnd = self.characterIndex(forLine: diag.endLine + 1, col: diag.endCol + 1) {
                endIdx = max(startIdx + 1, calculatedEnd)
            } else {
                endIdx = startIdx + 5
            }
            
            let range = NSRange(location: startIdx, length: min(endIdx - startIdx, nsString.length - startIdx))
            if charIndex >= range.location && charIndex < (range.location + range.length) {
                foundDiag = diag
                diagnosticRange = range
                break
            }
        }

        hoverRequestID += 1
        let currentReqID = hoverRequestID
        
        if let diag = foundDiag {
            let severityHeader: String
            switch diag.severity {
            case 1: severityHeader = "### Error\n"
            case 2: severityHeader = "### Warning\n"
            case 3: severityHeader = "### Info\n"
            default: severityHeader = "### Hint\n"
            }
            combinedText = "\(severityHeader)\(diag.message)"
            let causes = workspace.likelyCauses(of: diag, in: self.filePath)
            if !causes.isEmpty {
                combinedText += "\n\nErrors elsewhere may cause this:" + causes.map { "\n\(($0.path as NSString).lastPathComponent):\($0.diag.line + 1) — \($0.diag.message)" }.joined()
            }

            presentHover(combinedText)
        }
        
        let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
        let path = self.filePath
        if EcosystemDocumentTools.isEnvFile(path) {
            if !workspace.activeWorkspacePath.isEmpty,
               let (lineText, col0) = lineTextAndColumn0(at: charIndex),
               let envKey = EcosystemDocumentTools.detectEnvKeyAtOffset(inLine: lineText, column0: col0) {
                let wsPath = workspace.activeWorkspacePath
                let openDocs = openDocumentsTextMap()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let usages = EcosystemDocumentTools.findGoEnvKeyUsages(
                        forKey: envKey,
                        in: wsPath,
                        openDocuments: openDocs
                    )
                    let usageSummary: String
                    if usages.isEmpty {
                        usageSummary = "**Environment Variable** `\(envKey)`\n\nNo Go usages found in workspace."
                    } else {
                        let preview = usages.prefix(5).map { loc in
                            "- `\((loc.path as NSString).lastPathComponent):\(loc.range.start.line + 1)`"
                        }.joined(separator: "\n")
                        let countLabel = usages.count == 1 ? "1 Go usage" : "\(usages.count) Go usages"
                        usageSummary = "**Environment Variable** `\(envKey)` (\(countLabel))\n\n\(preview)\n\nCommand-click to jump to Go usage."
                    }
                    let finalHover = combinedText.isEmpty ? usageSummary : (combinedText + "\n\n---\n\n" + usageSummary)
                    DispatchQueue.main.async {
                        guard let self, self.hoverRequestID == currentReqID else { return }
                        presentHover(finalHover)
                    }
                }
                return
            }
            if foundDiag == nil {
                self.dismissHoverImmediate()
            }
            return
        }
        if EcosystemDocumentTools.isDockerfile(path), let markdown = DockerfileAssist.hoverMarkdown(in: nsString, at: charIndex) {
            presentHover(combinedText.isEmpty ? markdown : combinedText + "\n\n---\n\n" + markdown)
            return
        }
        guard path.hasSuffix(".go") else {
            if foundDiag == nil {
                self.dismissHoverImmediate()
            }
            return
        }

        if !workspace.activeWorkspacePath.isEmpty,
           let (lineText, col0) = lineTextAndColumn0(at: charIndex),
           let envKey = EcosystemDocumentTools.detectGoEnvKeyAtOffset(inLine: lineText, column0: col0) {
            let openDocs = openEnvDocumentsTextMap()
            let envHover: String
            if let def = EcosystemDocumentTools.findEnvDefinition(forKey: envKey, in: workspace.activeWorkspacePath, openDocuments: openDocs) {
                envHover = "**Environment Variable** `\(def.key)`\n\nValue: `\(def.displayValue)`\n\nDefined in `\(def.fileName):\(def.line)` (Command-click to jump to definition)"
            } else {
                envHover = "**Environment Variable** `\(envKey)`\n\nNot defined in workspace `.env` files (Right-click to add `\(envKey)=` to `.env`)"
            }
            presentHover(combinedText.isEmpty ? envHover : (combinedText + "\n\n---\n\n" + envHover))
            return
        }
        
        Task {
            let lspHoverResult = await LSPClient.shared.requestHover(atLine: line, col: col, inPath: path)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.hoverRequestID == currentReqID else { return }
                if let lspResult = lspHoverResult, !lspResult.isEmpty {
                    presentHover(combinedText.isEmpty ? lspResult : combinedText + "\n\n---\n\n" + lspResult)
                } else if foundDiag == nil {
                    self.dismissHoverImmediate()
                }
            }
        }
    }

    private func scheduleHoverDismiss() {
        if quickDocumentationCaret != nil { return }
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if self.workspaceState.lsp.hoverText == nil && self.workspaceState.issuePopup == nil {
                timer.invalidate()
                self.hoverDismissTimer = nil
                return
            }
            if self.isMouseStillOverHoveredTokenOrPopup() {
                return
            }
            timer.invalidate()
            self.hoverDismissTimer = nil
            self.clearHoverPresentation()
        }
    }

    func cancelHoverTimersAndRequests() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
        hoverRequestID += 1
    }

    func dismissHoverImmediate() {
        cancelHoverTimersAndRequests()
        clearHoverPresentation()
    }

    private func clearHoverPresentation() {
        let clearState = {
            let lsp = self.workspaceState.lsp
            lsp.isMouseInsideHoverPopover = false
            lsp.hoveredFilePath = ""
            lsp.hoveredWordRange = NSRange(location: NSNotFound, length: 0)
            lsp.hoveredDiagnosticRange = NSRange(location: NSNotFound, length: 0)
            lsp.hoveredEditor = nil
            if lsp.hoverText != nil {
                lsp.hoverText = nil
            }
            if lsp.quickDocumentation != nil {
                lsp.quickDocumentation = nil
            }
            if self.workspaceState.issuePopup != nil {
                self.workspaceState.issuePopup = nil
            }
        }
        if Thread.isMainThread {
            clearState()
        } else {
            DispatchQueue.main.async(execute: clearState)
        }
    }
    
    func dismissHover() {
        dismissHoverImmediate()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstURL = urls.first {
            let workspace = self.workspaceState
            workspace.activeDraggedTabPath = nil
            workspace.activeDraggedNavigatorPath = nil
            let fullPath = firstURL.resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                return false
            }
            let readOnly = !workspace.activeWorkspacePath.isEmpty && !fullPath.hasPrefix(workspace.activeWorkspacePath + "/")
            if workspace.isSplitMode && self.filePath == workspace.secondaryFilePath && self.filePath != workspace.activeFilePath {
                workspace.openFileInSplit(fullPath)
            } else {
                workspace.openFile(fullPath, readOnly: readOnly)
            }
            return true
        }
        return super.performDragOperation(sender)
    }
    
}
