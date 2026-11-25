import AppKit

extension WorkspaceState {
    func saveAllEdited(then: @escaping () -> Void, onFailure: (() -> Void)? = nil) {
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()
        (primaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        (secondaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        let sessions = editedFiles.compactMap { documents[$0] }.filter { fileEditorModes[$0.path] != .readOnly }
        guard !sessions.isEmpty else { then(); return }
        var remaining = sessions.count
        var failedFiles: [String] = []
        for session in sessions {
            save(session, reportsFailure: true) { [weak self] saved in
                if !saved {
                    failedFiles.append((session.path as NSString).lastPathComponent)
                }
                remaining -= 1
                if remaining == 0 {
                    if failedFiles.isEmpty {
                        then()
                    } else {
                        let list = failedFiles.joined(separator: ", ")
                        self?.appendLog("Save failed or cancelled for \(list); operation aborted.")
                        onFailure?()
                    }
                }
            }
        }
    }

    func isTabPinned(_ path: String) -> Bool {
        pinnedTabs.contains(path)
    }

    func togglePinTab(_ path: String) {
        if previewTabPath == path {
            previewTabPath = nil
        }
        if pinnedTabs.contains(path) {
            pinnedTabs.remove(path)
        } else {
            pinnedTabs.insert(path)
        }
        let pinned = openFiles.filter { pinnedTabs.contains($0) }
        let unpinned = openFiles.filter { !pinnedTabs.contains($0) }
        openFiles = pinned + unpinned
    }

    func closeSavedTabs() {
        let targets = openFiles.filter { !pinnedTabs.contains($0) && documents[$0]?.isEdited != true && !editedFiles.contains($0) }
        confirmDatabaseConsolesClose(targets) { [weak self] proceed in
            if proceed { self?.closeFiles(targets) }
        }
    }

    func autoSaveEditedDocumentsIfEnabled() {
        guard autoSaveOnFocusLoss else { return }
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()
        (primaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        (secondaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        let sessions = editedFiles.compactMap { documents[$0] }.filter {
            fileEditorModes[$0.path] != .readOnly &&
            !deletedFiles.contains($0.path) &&
            !diskConflicts.contains($0.path) &&
            FileManager.default.fileExists(atPath: $0.path)
        }
        for session in sessions {
            save(session)
        }
    }

    func closeTab(_ path: String) {
        if databaseConsoleNeedsCloseConfirmation(path) { return }
        guard let session = documents[path], session.isEdited else {
            pinnedTabs.remove(path)
            closeFile(path)
            return
        }
        activeFilePath = path
        askToSave(session) { [weak self] proceed in
            if proceed {
                self?.pinnedTabs.remove(path)
                self?.closeFile(path)
            }
        }
    }

    func closeTabs(_ paths: [String]) {
        confirmDatabaseConsolesClose(paths) { [weak self] proceed in
            guard proceed, let self else { return }
            self.reviewNext(paths.filter { self.documents[$0]?.isEdited == true }) { [weak self] proceed in
                guard proceed else { return }
                self?.closeFiles(paths)
            }
        }
    }

    func closeCurrentTab() {
        if sourceControl.editorSurface != nil {
            sourceControl.editorSurface = nil
            return
        }
        if isSplitMode && focusedPaneID == .secondary {
            closeSecondarySplitPane()
            return
        }
        if activeFilePath.isEmpty {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        if pinnedTabs.contains(activeFilePath) {
            presentCommandFeedback(
                "Unpin \"\((activeFilePath as NSString).lastPathComponent)\" from its tab menu before closing.",
                title: "Tab Is Pinned"
            )
            return
        }
        closeTab(activeFilePath)
    }

    func selectNextTab() {
        guard openFiles.count > 1 else { return }
        if sourceControl.editorSurface != nil {
            sourceControl.editorSurface = nil
        }
        if let idx = openFiles.firstIndex(of: activeFilePath) {
            activeFilePath = openFiles[(idx + 1) % openFiles.count]
        } else if let first = openFiles.first {
            activeFilePath = first
        }
    }

    func selectPreviousTab() {
        guard openFiles.count > 1 else { return }
        if sourceControl.editorSurface != nil {
            sourceControl.editorSurface = nil
        }
        if let idx = openFiles.firstIndex(of: activeFilePath) {
            activeFilePath = openFiles[(idx - 1 + openFiles.count) % openFiles.count]
        } else if let last = openFiles.last {
            activeFilePath = last
        }
    }

    func closeMainWindow() {
        guard let window = NSApp.keyWindow else { return }
        guard window === mainWindow else {
            window.performClose(nil)
            return
        }
        reviewEditedDocuments(before: "closing the window") { [weak self] proceed in
            guard proceed else { return }
            self?.closeAllDocuments()
            window.performClose(nil)
        }
    }

    func askToSave(_ session: DocumentSession, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\((session.path as NSString).lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(session, reportsFailure: true, then: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    func reviewEditedDocuments(before action: String, completion: @escaping (Bool) -> Void) {
        if database.sessions.values.contains(where: \.hasOpenTransaction) {
            confirmDatabaseTransactionsBeforeClosing { [weak self] proceed in
                guard proceed, let self else { return completion(false) }
                self.reviewEditedDocuments(before: action, completion: completion)
            }
            return
        }
        let paths = openFiles.filter { documents[$0]?.isEdited == true }
        guard !paths.isEmpty else { completion(true); return }
        guard paths.count > 1 else { reviewNext(paths, completion: completion); return }
        let alert = NSAlert()
        alert.messageText = "You have \(paths.count) documents with unsaved changes. Do you want to review these changes before \(action)?"
        alert.informativeText = "If you don’t review your documents, all your changes will be lost."
        alert.addButton(withTitle: "Review Changes…")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Discard Changes")
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.reviewNext(paths, completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    private func reviewNext(_ paths: [String], completion: @escaping (Bool) -> Void) {
        guard let path = paths.first else { completion(true); return }
        let rest = Array(paths.dropFirst())
        guard let session = documents[path], session.isEdited else { reviewNext(rest, completion: completion); return }
        activeFilePath = path
        askToSave(session) { [weak self] proceed in
            if proceed { self?.reviewNext(rest, completion: completion) } else { completion(false) }
        }
    }

    private func notifyLanguageServerOfDiskChanges(_ paths: [String]) {
        let moduleFiles: Set<String> = ["go.mod", "go.sum", "go.work", "go.work.sum"]
        let relevant = paths.filter { path in
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".go") || moduleFiles.contains(name) else { return false }
            return documents[path]?.syncsToCore != true
        }
        let deleted = relevant.filter { !FileManager.default.fileExists(atPath: $0) }
        LSPClient.notifyWatchedFilesChanged(relevant.filter { !deleted.contains($0) })
        LSPClient.notifyWatchedFilesChanged(deleted, changeType: 3)
    }

    func filesChangedOnDisk(_ paths: Set<String>) {
        for path in paths { InvalidateWorkspaceSymbolFile(path) }
        if paths.contains(where: { ["go.mod", "go.sum", "go.work", "go.work.sum"].contains(($0 as NSString).lastPathComponent) }) {
            let wsRoot = activeWorkspacePath
            Task { @MainActor in
                DocumentationService.shared.invalidate(root: wsRoot)
            }
        }
        let resolved = paths.map { path -> String in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        notifyLanguageServerOfDiskChanges(resolved)
        for path in resolved {
            guard let session = documents[path] else {
                if openFiles.contains(path), (fileOpenErrors[path] != nil || deletedFiles.contains(path)), FileManager.default.fileExists(atPath: path) {
                    fileOpenErrors.removeValue(forKey: path)
                    deletedFiles.remove(path)
                    if path == activeFilePath || path == secondaryFilePath {
                        loadDocument(path)
                    }
                }
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let modified = attributes?[.modificationDate] as? Date else {
                deletedFiles.insert(path)
                continue
            }
            deletedFiles.remove(path)
            guard modified != session.diskModified else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    guard let self, self.documents[path] === session else { return }
                    if text == session.storage.string {
                        session.diskModified = modified
                        self.diskConflicts.remove(path)
                    } else if session.isEdited {
                        self.diskConflicts.insert(path)
                    } else {
                        self.reload(session, with: text, modified: modified)
                    }
                }
            }
        }
    }

    func keepGoLensVersion(_ path: String) {
        documents[path]?.diskModified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        diskConflicts.remove(path)
    }

    func revertToDiskVersion(_ path: String, reportsFailure: Bool = false) {
        guard let session = documents[path] else {
            if openFiles.contains(path), FileManager.default.fileExists(atPath: path) {
                fileOpenErrors.removeValue(forKey: path)
                deletedFiles.remove(path)
                if path == activeFilePath || path == secondaryFilePath {
                    loadDocument(path)
                }
            }
            return
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            guard reportsFailure else { return }
            presentFailure(
                "Couldn’t Revert “\((path as NSString).lastPathComponent)”",
                "GoLens couldn’t read the version on disk. \(Self.failureReason(error)) The text in the editor is unchanged.",
                recovery: ("Try Again", { [weak self] in self?.revertToDiskVersion(path, reportsFailure: true) }),
                revealing: path
            )
            return
        }
        reload(session, with: text, modified: modified)
        restoreSavedBookmarks(for: path)
        restoreSavedBreakpointLines(for: path)
    }

    private func editorViews(displaying session: DocumentSession) -> [GoLensTextView] {
        var result: [GoLensTextView] = []
        var seen = Set<ObjectIdentifier>()
        func addIfMatching(_ candidate: NSTextView?) {
            guard let view = candidate as? GoLensTextView, view.document === session else { return }
            if seen.insert(ObjectIdentifier(view)).inserted {
                result.append(view)
            }
        }
        addIfMatching(activeTextView)
        addIfMatching(primaryTextView)
        addIfMatching(secondaryTextView)
        func walk(_ view: NSView?) {
            guard let view else { return }
            if let editor = view as? GoLensTextView {
                addIfMatching(editor)
            }
            for child in view.subviews {
                walk(child)
            }
        }
        for window in NSApp.windows {
            walk(window.contentView)
        }
        return result
    }

    private func reload(_ session: DocumentSession, with text: String, modified: Date?) {
        let views = editorViews(displaying: session)
        let snapshots = views.map { view in
            (view: view, selection: view.selectedRange(), origin: view.enclosingScrollView?.contentView.bounds.origin)
        }
        let primarySelection = snapshots.first?.selection ?? session.lastSelection
        let all = NSRange(location: 0, length: session.storage.length)
        if let primary = snapshots.first?.view, primary.shouldChangeText(in: all, replacementString: text) {
            primary.textStorage?.replaceCharacters(in: all, with: text)
            primary.didChangeText()
        } else {
            session.replaceAll(with: text)
        }
        session.undoManager.removeAllActions()
        session.savedText = text
        session.savedVersion = session.version
        session.diskModified = modified
        editedFiles.remove(session.path)
        diskConflicts.remove(session.path)
        deletedFiles.remove(session.path)
        let filename = (session.path as NSString).lastPathComponent
        if filename == "go.mod" || filename == "go.work" {
            codeLensVersions.removeValue(forKey: session.path)
            reloadModuleDoctorState(forPath: session.path, version: session.version)
            reloadGoplsCodeLenses(forPath: session.path, version: session.version)
        } else if session.path.hasSuffix(".go") {
            clearGeneratedOriginCache(for: session.path)
            refreshGeneratedOrigin(for: session.path, text: text, version: session.version)
        }
        session.lastSelection = NSRange(location: min(primarySelection.location, session.length), length: 0)
        for snapshot in snapshots {
            let clamped = NSRange(location: min(snapshot.selection.location, session.length), length: 0)
            snapshot.view.setSelectedRange(clamped)
            if let origin = snapshot.origin {
                snapshot.view.enclosingScrollView?.contentView.scroll(to: origin)
            }
            snapshot.view.needsDisplay = true
            snapshot.view.redrawGutter()
        }
    }

    func present(_ alert: NSAlert, _ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = mainWindow, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    func presentFailure(
        _ title: String,
        _ message: String,
        recovery: (title: String, action: () -> Void)? = nil,
        revealing path: String? = nil,
        dismissed: @escaping () -> Void = {}
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let recovery {
            alert.addButton(withTitle: recovery.title)
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        } else {
            alert.addButton(withTitle: "OK")
        }
        let revealed = path.map(Self.nearestExistingPath)
        if revealed != nil {
            alert.addButton(withTitle: "Show in Finder")
        }
        let revealResponse: NSApplication.ModalResponse = recovery == nil ? .alertSecondButtonReturn : .alertThirdButtonReturn
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if let recovery, response == .alertFirstButtonReturn {
                recovery.action()
                return
            }
            if let revealed, response == revealResponse {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealed)])
            }
            dismissed()
        }
        if let window = mainWindow, window.isVisible {
            let host = Self.alertPresentationHost(from: window)
            presentAlertSheet(alert, on: host, handler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func presentAlertSheet(_ alert: NSAlert, on host: NSWindow, handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let attached = host.attachedSheet, Self.isAlertSheet(attached) {
            final class ObserverBox: @unchecked Sendable { var token: NSObjectProtocol? }
            let observerBox = ObserverBox()
            observerBox.token = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: host, queue: .main) { [weak self, weak host, observerBox] _ in
                if let token = observerBox.token {
                    NotificationCenter.default.removeObserver(token)
                    observerBox.token = nil
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let host, host.isVisible else {
                        handler(alert.runModal())
                        return
                    }
                    self.presentAlertSheet(alert, on: host, handler: handler)
                }
            }
            return
        }
        alert.layout()
        alert.beginSheetModal(for: host, completionHandler: handler)
    }

    private static func isAlertSheet(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).contains("Alert")
    }

    private static func alertPresentationHost(from window: NSWindow) -> NSWindow {
        var host = window
        while let sheet = host.attachedSheet, sheet.isVisible, !isAlertSheet(sheet) {
            host = sheet
        }
        return host
    }

    static func failureReason(_ error: Error) -> String {
        formatCommandReason(error.localizedDescription, fallback: "The system reported an error.")
    }

    private static func nearestExistingPath(_ path: String) -> String {
        var current = path
        while !current.isEmpty, current != "/", !FileManager.default.fileExists(atPath: current) {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }
}

final class GoLensAppDelegate: NSObject, NSApplicationDelegate {
    private var reviewed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pendingSessions = MainActor.assumeIsolated {
            WorkspaceSessionRegistry.shared.sessionsWithUnsavedDocuments()
        }
        guard !reviewed, let firstDirty = pendingSessions.first else { return .terminateNow }
        DispatchQueue.main.async {
            Self.reviewSessionsSequentially(pendingSessions, index: 0, fallback: firstDirty) { [weak self] proceed in
                guard proceed else { return }
                self?.reviewed = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }

    private static func reviewSessionsSequentially(
        _ sessions: [WorkspaceSession],
        index: Int,
        fallback: WorkspaceSession,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < sessions.count else {
            completion(true)
            return
        }
        let session = sessions[index]
        session.workspace.mainWindow?.makeKeyAndOrderFront(nil)
        session.workspace.reviewEditedDocuments(before: "quitting") { proceed in
            guard proceed else {
                completion(false)
                return
            }
            reviewSessionsSequentially(sessions, index: index + 1, fallback: fallback, completion: completion)
        }
    }
}
