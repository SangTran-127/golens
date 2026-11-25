import SwiftUI
import AppKit
import GoLensFoundation

private final class CaretTestMenuPayload: NSObject {
    let resolved: ResolvedCaretTest

    init(_ resolved: ResolvedCaretTest) {
        self.resolved = resolved
    }
}

extension GoLensTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        let gutterX = clickPoint.x - visibleRect.origin.x
        if gutterX >= 0 && gutterX < gutterWidth, let line = findLineNumber(atY: clickPoint.y) {
            return gutterContextMenu(forLine: line, clickY: clickPoint.y)
        }
        let characterIndex = self.characterIndex(for: clickPoint)
        let targetLine = resolvedContextTargetLine(characterIndex: characterIndex)
        if let conflictMenu = mergeConflictContextMenu(characterIndex: characterIndex, targetLine: targetLine) {
            return conflictMenu
        }
        if EcosystemDocumentTools.isHTTPFile(filePath) {
            return httpFileContextMenu(characterIndex: characterIndex, targetLine: targetLine)
        }

        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        let hasSymbol = characterIndex != NSNotFound && getWord(at: characterIndex) != nil
        let hasSelection = selectedRange().length > 0
        let isGoFile = filePath.hasSuffix(".go")
        let activeTestTarget = isGoFile ? enclosingTestTarget(atLine: targetLine) : nil

        if isGoFile && self.workspaceState.debug.isDebugMode {
            menu.addItem(makeContextItem("Run to Cursor", icon: "arrow.right.to.line", keymapID: "debug.runToCursor", action: #selector(contextRunToCursor(_:)), rep: targetLine))
            appendSeparatorIfNeeded(to: menu)
        }

        if let resolved = activeTestTarget {
            let busy = self.workspaceState.isRunning
            let payload = CaretTestMenuPayload(resolved)
            menu.addItem(makeContextItem("Run “\(resolved.target.title)”", icon: "play.fill", keymapID: "product.testAtCursor", action: busy ? nil : #selector(contextRunEnclosingTest(_:)), rep: payload))
            menu.addItem(makeContextItem("Debug “\(resolved.target.title)”", icon: "ladybug.fill", keymapID: "product.debugTestAtCursor", action: busy ? nil : #selector(contextDebugEnclosingTest(_:)), rep: payload))
            appendSeparatorIfNeeded(to: menu)
        }

        if hasSymbol {
            menu.addItem(makeContextItem("Go to Definition", icon: "arrow.right.circle", keymapID: "navigate.definition", action: #selector(contextGoToDefinition(_:)), rep: characterIndex))
            menu.addItem(makeNavigateSubmenu(characterIndex: characterIndex, isGoFile: isGoFile))
            appendSeparatorIfNeeded(to: menu)
        }

        if isGoFile {
            if hasSelection {
                menu.addItem(makeContextItem("Surround With…", icon: "curlybraces", keymapID: "editor.surroundWith", action: #selector(contextSurroundWith(_:)), rep: characterIndex))
            }
            menu.addItem(makeRefactorSubmenu(characterIndex: characterIndex))
            menu.addItem(makeGenerateSubmenu(characterIndex: characterIndex))
            menu.addItem(makeContextItem("Show Code Actions", icon: "wand.and.stars", keymapID: "editor.codeActions", action: #selector(contextShowCodeActions(_:)), rep: characterIndex))
            appendSeparatorIfNeeded(to: menu)
        } else {
            if hasSymbol {
                menu.addItem(makeContextItem("Rename Symbol…", icon: "character.cursor.ibeam", keymapID: "refactor.rename", action: #selector(contextRenameSymbol(_:)), rep: characterIndex))
                appendSeparatorIfNeeded(to: menu)
            }
            if ActiveCommandCapabilities.isYAMLFile(filePath), !EcosystemDocumentTools.isDockerComposeFile(filePath),
               KubeManifest.isManifest((string as NSString).substring(to: min(KubeManifest.sniffLength, (string as NSString).length))) {
                menu.addItem(makeContextItem("Apply to Cluster…", icon: ServiceSymbol.apply, keymapID: "kube.applyToCluster", action: #selector(contextApplyToCluster(_:)), rep: characterIndex))
                appendSeparatorIfNeeded(to: menu)
            }
        }

        if !(hasSymbol && activeTestTarget != nil) {
            menu.addItem(makeContextItem("Toggle Comment", icon: "text.bubble", keymapID: "editor.toggleComment", action: #selector(contextToggleComment(_:)), rep: characterIndex))
        }
        if !hasSymbol {
            menu.addItem(makeContextItem("Format Document", icon: "text.alignleft", keymapID: "editor.format", action: #selector(contextFormatDocument(_:)), rep: characterIndex))
        }
        appendSeparatorIfNeeded(to: menu)

        if (!hasSymbol && activeTestTarget == nil) || (hasSelection && activeTestTarget == nil) {
            menu.addItem(makeContextItem("Cut", icon: "scissors", keymapID: "edit.cut", action: #selector(NSText.cut(_:)), rep: characterIndex))
        }
        menu.addItem(makeContextItem("Copy", icon: "doc.on.doc", keymapID: "edit.copy", action: #selector(NSText.copy(_:)), rep: characterIndex))
        menu.addItem(makeContextItem("Paste", icon: "doc.on.clipboard", keymapID: "edit.paste", action: #selector(NSText.paste(_:)), rep: characterIndex))

        if !filePath.isEmpty {
            menu.addItem(makeCopyPathSubmenu(forLine: targetLine, characterIndex: characterIndex))
        }

        return menu
    }

    private func appendSeparatorIfNeeded(to menu: NSMenu) {
        guard !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true else { return }
        menu.addItem(.separator())
    }

    private func resolvedContextTargetLine(characterIndex: Int) -> Int {
        if characterIndex != NSNotFound {
            return lineAndCol(forCharacterIndex: characterIndex).line
        }
        if selectedRange().location != NSNotFound {
            return lineAndCol(forCharacterIndex: selectedRange().location).line
        }
        return max(1, self.workspaceState.cursorLine)
    }

    private func makeContextItem(
        _ title: String,
        icon: String? = nil,
        keymapID: String? = nil,
        action: Selector?,
        rep: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = rep
        if let icon {
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        if let keymapID {
            KeymapStore.shared.applyMenuShortcut(keymapID, to: item)
        }
        return item
    }

    private func gutterContextMenu(forLine line: Int, clickY: CGFloat) -> NSMenu {
        let gutterMenu = NSMenu()
        gutterMenu.allowsContextMenuPlugIns = false
        if filePath.hasSuffix(".go"), let target = testTarget(atLine: line) {
            let busy = self.workspaceState.isRunning
            let run = NSMenuItem(title: "Run “\(target.title)”", action: busy ? nil : #selector(runTestFromGutter(_:)), keyEquivalent: "")
            run.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            run.tag = line
            run.target = self
            gutterMenu.addItem(run)
            let debug = NSMenuItem(title: "Debug “\(target.title)”", action: busy ? nil : #selector(debugTestFromGutter(_:)), keyEquivalent: "")
            debug.image = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: nil)
            debug.tag = line
            debug.target = self
            gutterMenu.addItem(debug)
            let profile = NSMenuItem(title: "Profile “\(target.title)”", action: busy ? nil : #selector(profileTestFromGutter(_:)), keyEquivalent: "")
            profile.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)
            profile.tag = line
            profile.target = self
            gutterMenu.addItem(profile)
            gutterMenu.addItem(.separator())
        }
        let hasBookmark = self.workspaceState.hasBookmark(in: filePath, atLine: line)
        let toggleBM = NSMenuItem(title: hasBookmark ? "Remove Bookmark" : "Add Bookmark", action: #selector(toggleBookmarkFromGutter(_:)), keyEquivalent: "")
        toggleBM.image = NSImage(systemSymbolName: hasBookmark ? "bookmark.slash" : "bookmark", accessibilityDescription: nil)
        toggleBM.tag = line
        toggleBM.target = self
        gutterMenu.addItem(toggleBM)
        if !self.workspaceState.bookmarks.isEmpty {
            let clearBM = NSMenuItem(title: "Clear All Bookmarks", action: #selector(clearAllBookmarksFromGutter(_:)), keyEquivalent: "")
            clearBM.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            clearBM.target = self
            gutterMenu.addItem(clearBM)
        }
        if filePath.hasSuffix(".go") {
            gutterMenu.addItem(.separator())
            let has = self.workspaceState.debug.breakpoints[filePath]?.contains(line) == true
            let edit = NSMenuItem(title: has ? "Edit Breakpoint…" : "Add Conditional Breakpoint…", action: #selector(editBreakpoint(_:)), keyEquivalent: "")
            edit.image = NSImage(systemSymbolName: has ? "pencil" : "plus.circle", accessibilityDescription: nil)
            edit.representedObject = NSValue(point: NSPoint(x: CGFloat(line), y: clickY))
            edit.target = self
            gutterMenu.addItem(edit)
            if has {
                let delete = NSMenuItem(title: "Delete Breakpoint", action: #selector(deleteBreakpoint(_:)), keyEquivalent: "")
                delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                delete.tag = line
                delete.target = self
                gutterMenu.addItem(delete)
            }
        }
        if self.workspaceState.showsSourceControlChanges, self.workspaceState.git.activeFileDiffs[line] != nil {
            gutterMenu.addItem(.separator())
            let showDiff = NSMenuItem(title: "Show Change…", action: #selector(showGitHunkFromGutter(_:)), keyEquivalent: "")
            showDiff.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            showDiff.representedObject = NSValue(point: NSPoint(x: CGFloat(line), y: clickY))
            showDiff.target = self
            gutterMenu.addItem(showDiff)

            let stageDiff = NSMenuItem(title: "Stage Change", action: #selector(stageGitHunkFromGutter(_:)), keyEquivalent: "")
            stageDiff.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
            stageDiff.tag = line
            stageDiff.target = self
            gutterMenu.addItem(stageDiff)

            let revertDiff = NSMenuItem(title: "Discard Change", action: #selector(revertGitHunkFromGutter(_:)), keyEquivalent: "")
            revertDiff.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            revertDiff.tag = line
            revertDiff.target = self
            gutterMenu.addItem(revertDiff)
        }
        return gutterMenu
    }

    private func mergeConflictContextMenu(characterIndex: Int, targetLine: Int) -> NSMenu? {
        let conflictMenu = NSMenu()
        conflictMenu.allowsContextMenuPlugIns = false
        addMergeConflictMenuItems(to: conflictMenu, characterIndex: characterIndex)
        guard conflictMenu.numberOfItems > 0 else { return nil }
        conflictMenu.addItem(makeContextItem("Cut", icon: "scissors", keymapID: "edit.cut", action: #selector(NSText.cut(_:)), rep: characterIndex))
        conflictMenu.addItem(makeContextItem("Copy", icon: "doc.on.doc", keymapID: "edit.copy", action: #selector(NSText.copy(_:)), rep: characterIndex))
        conflictMenu.addItem(makeContextItem("Paste", icon: "doc.on.clipboard", keymapID: "edit.paste", action: #selector(NSText.paste(_:)), rep: characterIndex))
        if !filePath.isEmpty {
            conflictMenu.addItem(.separator())
            conflictMenu.addItem(makeCopyPathSubmenu(forLine: targetLine, characterIndex: characterIndex))
        }
        return conflictMenu
    }

    private func httpFileContextMenu(characterIndex: Int, targetLine: Int) -> NSMenu {
        let httpMenu = NSMenu()
        httpMenu.allowsContextMenuPlugIns = false
        let request = self.workspaceState.httpRequest(atLine: targetLine, in: filePath)
        httpMenu.addItem(makeContextItem(
            "Run HTTP Request",
            icon: "paperplane.fill",
            keymapID: "product.runHTTPRequest",
            action: request == nil ? nil : #selector(contextRunHTTPRequest(_:)),
            rep: request?.index
        ))
        httpMenu.addItem(makeContextItem(
            "Run All HTTP Requests in File",
            icon: "paperplane.circle",
            keymapID: "product.runAllHTTPRequests",
            action: #selector(contextRunAllHTTPRequests(_:)),
            rep: characterIndex
        ))
        httpMenu.addItem(.separator())
        httpMenu.addItem(makeContextItem("Toggle Comment", icon: "text.bubble", keymapID: "editor.toggleComment", action: #selector(contextToggleComment(_:)), rep: characterIndex))
        httpMenu.addItem(.separator())
        httpMenu.addItem(makeContextItem("Cut", icon: "scissors", keymapID: "edit.cut", action: #selector(NSText.cut(_:)), rep: characterIndex))
        httpMenu.addItem(makeContextItem("Copy", icon: "doc.on.doc", keymapID: "edit.copy", action: #selector(NSText.copy(_:)), rep: characterIndex))
        httpMenu.addItem(makeContextItem("Paste", icon: "doc.on.clipboard", keymapID: "edit.paste", action: #selector(NSText.paste(_:)), rep: characterIndex))
        if !filePath.isEmpty {
            httpMenu.addItem(makeCopyPathSubmenu(forLine: targetLine, characterIndex: characterIndex))
        }
        return httpMenu
    }

    private func makeNavigateSubmenu(characterIndex: Int, isGoFile: Bool) -> NSMenuItem {
        let navMenu = NSMenu(title: "Navigate")
        navMenu.allowsContextMenuPlugIns = false
        if isGoFile {
            navMenu.addItem(makeContextItem("Quick Documentation", icon: "questionmark.circle", keymapID: "view.quickDocumentation", action: #selector(contextQuickDocumentation(_:)), rep: characterIndex))
            navMenu.addItem(makeContextItem("Quick Definition", icon: "rectangle.and.text.magnifyingglass", keymapID: "view.quickDefinition", action: #selector(contextQuickDefinition(_:)), rep: characterIndex))
        }
        navMenu.addItem(makeContextItem("Go to Implementation", icon: "arrow.down.right.circle", keymapID: "navigate.implementation", action: #selector(contextGoToImplementation(_:)), rep: characterIndex))
        navMenu.addItem(makeContextItem("Find References", icon: "link", keymapID: "navigate.references", action: #selector(contextFindReferences(_:)), rep: characterIndex))
        let root = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        root.submenu = navMenu
        return root
    }

    private func makeRefactorSubmenu(characterIndex: Int) -> NSMenuItem {
        let refactorMenu = NSMenu(title: "Refactor")
        refactorMenu.allowsContextMenuPlugIns = false
        refactorMenu.addItem(makeContextItem("Rename Symbol…", icon: "character.cursor.ibeam", keymapID: "refactor.rename", action: #selector(contextRenameSymbol(_:)), rep: characterIndex))
        refactorMenu.addItem(makeContextItem("Change Signature…", icon: "signature", keymapID: "refactor.changeSignature", action: #selector(contextChangeSignature(_:)), rep: characterIndex))
        refactorMenu.addItem(makeContextItem("Move Symbol…", icon: "arrow.right.doc.on.clipboard", keymapID: "refactor.moveSymbol", action: #selector(contextMoveSymbol(_:)), rep: characterIndex))
        refactorMenu.addItem(.separator())
        refactorMenu.addItem(makeContextItem("Extract Function…", icon: "function", keymapID: "refactor.extractFunction", action: #selector(contextExtractMethod(_:)), rep: characterIndex))
        refactorMenu.addItem(makeContextItem("Extract Variable", icon: "equal.square", keymapID: "refactor.extractVariable", action: #selector(contextExtractVariable(_:)), rep: characterIndex))
        refactorMenu.addItem(makeContextItem("Inline Variable", icon: "arrow.down.to.line.compact", keymapID: "refactor.inlineVariable", action: #selector(contextInlineVariable(_:)), rep: characterIndex))
        refactorMenu.addItem(.separator())
        refactorMenu.addItem(makeContextItem("Extract Interface", icon: "puzzlepiece.extension", keymapID: "refactor.extractInterface", action: #selector(contextExtractInterface(_:)), rep: characterIndex))
        refactorMenu.addItem(makeContextItem("Implement Interface…", icon: "checkmark.seal", keymapID: "refactor.implementInterface", action: #selector(contextImplementInterface(_:)), rep: characterIndex))
        refactorMenu.addItem(.separator())
        refactorMenu.addItem(makeContextItem("Handle Error with if err != nil", icon: "exclamationmark.triangle", keymapID: "refactor.handleError", action: #selector(contextHandleError(_:)), rep: characterIndex))
        let refactorRoot = NSMenuItem(title: "Refactor", action: nil, keyEquivalent: "")
        refactorRoot.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        refactorRoot.submenu = refactorMenu
        return refactorRoot
    }

    private func makeGenerateSubmenu(characterIndex: Int) -> NSMenuItem {
        let generateMenu = NSMenu(title: "Generate")
        generateMenu.allowsContextMenuPlugIns = false
        generateMenu.addItem(makeContextItem("Generate Constructor & Options…", icon: "hammer", keymapID: "generate.constructorOptions", action: #selector(contextGenerateConstructorOptions(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Generate Constructor", icon: "hammer", keymapID: "generate.constructor", action: #selector(contextGenerateConstructor(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Fill Struct Fields", icon: "list.bullet.rectangle", keymapID: "generate.fillStruct", action: #selector(contextFillStructFields(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Modify Struct Tags…", icon: "tag", keymapID: "generate.structTags", action: #selector(contextModifyStructTags(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Convert JSON to Go Struct…", icon: "curlybraces", keymapID: "generate.jsonToStruct", action: #selector(contextConvertJSONToStruct(_:)), rep: characterIndex))
        generateMenu.addItem(.separator())
        generateMenu.addItem(makeContextItem("Generate Enum / Stringer Methods…", icon: "list.number", keymapID: "generate.enumStringer", action: #selector(contextGenerateEnumMethods(_:)), rep: characterIndex))
        generateMenu.addItem(.separator())
        if !filePath.hasSuffix("_test.go") {
            generateMenu.addItem(makeContextItem("Generate Table-Driven Test…", icon: "checkmark.diamond", keymapID: "generate.tableTest", action: #selector(contextGenerateTableDrivenTest(_:)), rep: characterIndex))
        }
        generateMenu.addItem(makeContextItem("Generate Fuzz Test…", icon: "sparkles", keymapID: "generate.fuzzTest", action: #selector(contextGenerateFuzzTest(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Generate Go Benchmark…", icon: "stopwatch", keymapID: "generate.benchmark", action: #selector(contextGenerateBenchmark(_:)), rep: characterIndex))
        generateMenu.addItem(makeContextItem("Generate Interface Mock…", icon: "theatermasks", keymapID: "generate.mock", action: #selector(contextGenerateInterfaceMock(_:)), rep: characterIndex))
        let generateRoot = NSMenuItem(title: "Generate", action: nil, keyEquivalent: "")
        generateRoot.image = NSImage(systemSymbolName: "wand.and.rays", accessibilityDescription: nil)
        generateRoot.submenu = generateMenu
        return generateRoot
    }

    private func makeCopyPathSubmenu(forLine line: Int, characterIndex: Int) -> NSMenuItem {
        let sub = NSMenu(title: "Copy Path / Reference")
        sub.allowsContextMenuPlugIns = false
        sub.addItem(makeContextItem("Copy Relative Path", icon: "doc.on.doc", action: #selector(contextCopyRelativePath(_:)), rep: line))
        sub.addItem(makeContextItem("Copy File:Line Reference", icon: "link", action: #selector(contextCopyFileLineReference(_:)), rep: line))
        let root = NSMenuItem(title: "Copy Path / Reference", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        root.submenu = sub
        return root
    }

    private func enclosingTestTarget(atLine line: Int) -> ResolvedCaretTest? {
        if let resolved = self.workspaceState.resolveCaretTestTarget(in: filePath, line: line) {
            return resolved
        }
        if let direct = testTarget(atLine: line) {
            return ResolvedCaretTest(target: direct, patternOverride: nil)
        }
        return nil
    }

    private func relativeWorkspacePath(for path: String) -> String {
        let root = self.workspaceState.activeWorkspacePath
        guard !root.isEmpty else { return (path as NSString).lastPathComponent }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    @objc private func contextRunEnclosingTest(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? CaretTestMenuPayload {
            self.workspaceState.runTests(payload.resolved.target, patternOverride: payload.resolved.patternOverride)
        } else if let target = sender.representedObject as? TestTarget {
            self.workspaceState.runTests(target)
        }
    }

    @objc private func contextDebugEnclosingTest(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? CaretTestMenuPayload {
            self.workspaceState.debugProject(test: payload.resolved.target, patternOverride: payload.resolved.patternOverride)
        } else if let target = sender.representedObject as? TestTarget {
            self.workspaceState.debugProject(test: target)
        }
    }

    @objc private func contextToggleComment(_ sender: NSMenuItem) {
        if selectedRange().length == 0, let charIndex = sender.representedObject as? Int, charIndex != NSNotFound {
            setSelectedRange(NSRange(location: charIndex, length: 0))
        }
        toggleComment(in: self)
    }

    @objc private func contextApplyToCluster(_ sender: NSMenuItem) {
        ServicesStore.shared.presentApply(in: self.workspaceState)
    }

    @objc private func contextFormatDocument(_ sender: NSMenuItem) {
        self.workspaceState.formatActiveDocument()
    }

    @objc private func contextCopyRelativePath(_ sender: NSMenuItem) {
        let rel = relativeWorkspacePath(for: filePath)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rel, forType: .string)
    }

    @objc private func contextCopyFileLineReference(_ sender: NSMenuItem) {
        let line = (sender.representedObject as? Int) ?? max(1, self.workspaceState.cursorLine)
        let rel = relativeWorkspacePath(for: filePath)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(rel):\(line)", forType: .string)
    }

    @objc private func runTestFromGutter(_ sender: NSMenuItem) {
        guard let target = testTarget(atLine: sender.tag) else { return }
        GetStartedProgress.shared.complete(.runTestFromGutter)
        self.workspaceState.runTests(target)
    }

    @objc private func debugTestFromGutter(_ sender: NSMenuItem) {
        if let target = testTarget(atLine: sender.tag) { self.workspaceState.debugProject(test: target) }
    }

    @objc private func profileTestFromGutter(_ sender: NSMenuItem) {
        if let target = testTarget(atLine: sender.tag) { self.workspaceState.runTests(target, profile: true) }
    }

    @objc private func contextSurroundWith(_ sender: NSMenuItem) {
        self.workspaceState.presentSurroundWith()
    }

    @objc private func contextRunToCursor(_ sender: NSMenuItem) {
        self.workspaceState.debugRunToCursor(line: sender.representedObject as? Int)
    }

    @objc private func deleteBreakpoint(_ sender: NSMenuItem) {
        self.workspaceState.toggleBreakpoint(forLine: sender.tag, in: filePath)
        needsDisplay = true
    }

    @objc private func editBreakpoint(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else { return }
        let line = Int(value.pointValue.x)
        showBreakpointEditor(line: line, y: value.pointValue.y)
    }

    func showBreakpointEditor(line: Int, y: CGFloat) {
        let path = filePath
        let workspace = self.workspaceState
        self.workspaceState.activeEditorPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        self.workspaceState.activeEditorPopover = popover
        let editor = BreakpointEditorView(spec: self.workspaceState.debug.spec(path, line), line: line) { [weak self] spec in
            workspace.updateBreakpoint(spec, line: line, in: path)
            self?.needsDisplay = true
        } close: { [weak popover] in
            popover?.performClose(nil)
        }
        popover.contentViewController = NSHostingController(rootView: editor.windowScope(workspace))
        let anchor = NSRect(x: visibleRect.origin.x + gutterWidth - 24, y: y - 8, width: 12, height: 16)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
    }

    @objc private func toggleBookmarkFromGutter(_ sender: NSMenuItem) {
        self.workspaceState.toggleBookmark(forLine: sender.tag, in: filePath)
    }

    @objc private func clearAllBookmarksFromGutter(_ sender: NSMenuItem) {
        self.workspaceState.clearAllBookmarks()
    }

    @objc private func contextShowCodeActions(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        self.workspaceState.showCodeActionsMenu(for: self, at: charIndex)
    }

    @objc private func contextRenameSymbol(_ sender: NSMenuItem) {
        guard let characterIndex = sender.representedObject as? Int else { return }
        self.setSelectedRange(NSRange(location: characterIndex, length: 0))
        triggerRename()
    }

    @objc private func contextChangeSignature(_ sender: NSMenuItem) {
        guard let characterIndex = sender.representedObject as? Int else { return }
        self.setSelectedRange(NSRange(location: characterIndex, length: 0))
        self.workspaceState.triggerChangeSignature()
    }

    @objc private func contextGenerateConstructor(_ sender: NSMenuItem) {
        guard let characterIndex = sender.representedObject as? Int else { return }
        self.setSelectedRange(NSRange(location: characterIndex, length: 0))
        self.workspaceState.generateConstructorAtCaret()
    }

    @objc private func contextExtractInterface(_ sender: NSMenuItem) {
        guard let characterIndex = sender.representedObject as? Int else { return }
        self.setSelectedRange(NSRange(location: characterIndex, length: 0))
        self.workspaceState.extractInterfaceAtCaret()
    }

    @objc private func contextImplementInterface(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentImplementInterfaceSheet()
    }

    @objc private func contextMoveSymbol(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentMoveSymbolSheet()
    }

    @objc private func contextModifyStructTags(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentStructTagsSheet()
    }

    @objc private func contextConvertJSONToStruct(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentPasteJSONStructSheet()
    }

    @objc private func contextHandleError(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.applyGoIntention("wrap_err")
    }

    @objc private func contextExtractMethod(_ sender: NSMenuItem) {
        if self.selectedRange().length == 0, let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentExtractMethodSheet()
    }

    @objc private func contextExtractVariable(_ sender: NSMenuItem) {
        if self.selectedRange().length == 0, let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.extractVariableAtSelection()
    }

    @objc private func contextInlineVariable(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.inlineVariableAtCaret()
    }

    @objc private func contextGenerateTableDrivenTest(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentGenerateTableDrivenTestSheet()
    }

    @objc private func contextGenerateFuzzTest(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.openGenerateFuzzTestSheet()
    }

    @objc private func contextGenerateBenchmark(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.openGenerateBenchmarkSheet()
    }

    @objc private func contextGenerateInterfaceMock(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.presentGenerateInterfaceMockSheet()
    }

    @objc private func contextGenerateEnumMethods(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.openGenerateEnumMethodsSheet()
    }

    @objc private func contextGenerateConstructorOptions(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.openGenerateConstructorSheet()
    }

    @objc private func contextFillStructFields(_ sender: NSMenuItem) {
        if let characterIndex = sender.representedObject as? Int {
            self.setSelectedRange(NSRange(location: characterIndex, length: 0))
            let (line, col) = self.lineAndCol(forCharacterIndex: characterIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.fillStructFieldsAtCursor()
    }

    @objc private func showGitHunkFromGutter(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else { return }
        let line = Int(value.pointValue.x)
        showGitHunkPopover(line: line, y: value.pointValue.y)
    }

    @objc private func revertGitHunkFromGutter(_ sender: NSMenuItem) {
        let line = sender.tag
        self.workspaceState.revertGitHunkAtLine(line, inPath: filePath)
    }

    @objc private func stageGitHunkFromGutter(_ sender: NSMenuItem) {
        self.workspaceState.stageGitHunkAtLine(sender.tag, inPath: filePath)
    }

    func showGitHunkPopover(line: Int, y: CGFloat) {
        let path = filePath
        Task { @MainActor [weak self] in
            guard let self else { return }
            let workspace = self.workspaceState
            guard let hunk = await workspace.fetchGitHunk(forPath: path, atLine: line) else { return }
            self.workspaceState.activeEditorPopover?.performClose(nil)
            let popover = NSPopover()
            popover.behavior = .transient
            self.workspaceState.activeEditorPopover = popover
            let contentView = GitHunkPopoverView(
                hunk: hunk,
                onShow: {
                    self.workspaceState.openFileInDiff(path, source: .unstaged)
                },
                onStage: {
                    self.workspaceState.stageGitHunkAtLine(line, inPath: path)
                },
                onDiscard: { [weak self] in
                    workspace.revertGitHunk(hunk, inPath: path)
                    self?.needsDisplay = true
                },
                onClose: { [weak popover] in
                    popover?.performClose(nil)
                }
            )
            popover.contentViewController = NSHostingController(rootView: contentView.windowScope(workspace))
            let anchor = NSRect(x: self.visibleRect.origin.x + self.gutterWidth - 8, y: y - 8, width: 8, height: 16)
            popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
        }
    }

    @objc private func contextRunHTTPRequest(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        self.workspaceState.runHTTPRequest(path: filePath, index: index)
    }

    @objc private func contextRunAllHTTPRequests(_ sender: NSMenuItem) {
        self.workspaceState.runAllHTTPRequests(path: filePath)
    }

    @objc private func contextGoToDefinition(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        goToDefinition(at: charIndex)
    }
}
