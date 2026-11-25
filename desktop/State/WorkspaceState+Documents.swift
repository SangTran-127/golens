import Foundation
import AppKit

extension WorkspaceState {
    var visibleDocumentPaths: [String] {
        var paths = activeFilePath.isEmpty ? [] : [activeFilePath]
        if isSplitMode, let secondary = secondaryFilePath, !secondary.isEmpty, secondary != activeFilePath {
            paths.append(secondary)
        }
        return paths
    }

    func syncVisibleDocuments() {
        let visible = visibleDocumentPaths
        if let loading = codeLensLoadPath, !visible.contains(loading) {
            codeLensLoadTask?.cancel()
        }
        for (path, progress) in codeLensProgress where progress.isRunning && !visible.contains(path) {
            progress.task?.cancel()
        }
        let others = Self.allRegisteredWorkspaces().filter { $0 !== self }.flatMap(\.visibleDocumentPaths)
        let joined = (visible + others.filter { !visible.contains($0) }).joined(separator: "\n")
        lspQueue.async {
            joined.withCString { SetVisibleDocuments($0) }
        }
    }

    func fetchDocumentSymbols() {
        refreshPaneSymbols(for: .primary)
    }

    func refreshPaneSymbols(for paneID: EditorPaneID) {
        let pane = paneState(for: paneID)
        let path = filePath(for: paneID)
        guard !path.isEmpty else {
            pane.goDeclarations = []
            pane.documentSymbols = []
            return
        }
        if path.hasSuffix(".go") {
            let session = documents[path]
            if session?.isEffectiveLargeFileMode != true {
                let text = session?.storage.string ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if !text.isEmpty {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        guard let self else { return }
                        let decls = self.findGoDeclarations(in: text)
                        DispatchQueue.main.async {
                            guard self.filePath(for: paneID) == path else { return }
                            pane.goDeclarations = decls
                        }
                    }
                } else {
                    pane.goDeclarations = []
                }
            } else {
                pane.goDeclarations = []
            }
        } else {
            pane.goDeclarations = []
            pane.symbolFetchWorkItem?.cancel()
            guard EcosystemDocumentTools.isNonGoEcosystemFile(path) else {
                pane.documentSymbols = []
                return
            }
            let text = documents[path]?.storage.string ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let symbols = EcosystemDocumentTools.documentSymbols(forPath: path, text: text)
                DispatchQueue.main.async {
                    guard let self, self.filePath(for: paneID) == path else { return }
                    pane.documentSymbols = symbols
                }
            }
            return
        }

        pane.symbolFetchWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.filePath(for: paneID) == path else { return }
            Task {
                let result = await LSPClient.shared.documentSymbolsResult(inPath: path)
                await MainActor.run {
                    guard self.filePath(for: paneID) == path else { return }
                    switch result {
                    case .success(let symbols):
                        pane.documentSymbols = symbols
                        if paneID == .primary {
                            self.transientEditorState.documentSymbolsPath = path
                        }
                    case .failure:
                        if paneID != .primary || self.transientEditorState.documentSymbolsPath != path {
                            pane.documentSymbols = []
                        }
                    }
                }
            }
        }

        pane.symbolFetchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    var activeDocument: DocumentSession? { documents[activeFilePath] }

    var isCounterpartSplitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "GoLensCounterpartSplitEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "GoLensCounterpartSplitEnabled")
            if newValue {
                if !isSplitMode { isSplitMode = true }
                syncCounterpartFile()
            }
        }
    }

    var activeFileUsesTabs: Bool {
        activeFilePath.hasSuffix(".go")
    }

    var activeLineEnding: String {
        _ = loadedDocuments
        return documents[activeFilePath]?.lineEnding ?? "LF"
    }

    var completionAcceptKey: CompletionAcceptKey {
        get { KeymapStore.shared.completionAcceptKey }
        set { KeymapStore.shared.completionAcceptKey = newValue }
    }

    func counterpartDeclarations(_ path: String) -> [GoDeclaration] {
        let stamp: String
        if let session = documents[path] {
            stamp = "doc:\(ObjectIdentifier(session).hashValue):\(session.version)"
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = attributes?[.size] as? Int ?? -1
            stamp = "disk:\(modified):\(size)"
        }
        if let cached = diagnosticsAndLenses.counterpartDeclarationsCache, cached.path == path, cached.stamp == stamp {
            return cached.decls
        }
        let text = documents[path]?.storage.string ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let decls = findGoDeclarations(in: text)
        diagnosticsAndLenses.counterpartDeclarationsCache = (path, stamp, decls)
        return decls
    }

    func resolveCounterpart(for filePath: String) -> (path: String, isTest: Bool)? {
        guard filePath.hasSuffix(".go") else { return nil }
        if filePath.hasSuffix("_test.go") {
            let base = String(filePath.dropLast("_test.go".count))
            return (base + ".go", false)
        }
        let base = String(filePath.dropLast(".go".count))
        return (base + "_test.go", true)
    }

    func syncCounterpartFile() {
        guard isSplitMode && isCounterpartSplitEnabled, !activeFilePath.isEmpty else { return }
        guard let counterpart = resolveCounterpart(for: activeFilePath) else { return }

        if secondaryFilePath != counterpart.path {
            secondaryFilePath = counterpart.path
            if FileManager.default.fileExists(atPath: counterpart.path) {
                loadDocument(counterpart.path)
            }
        }
    }

    func syncCounterpartFunctionCaret(sourceLine: Int) {
        guard isSplitMode && isCounterpartSplitEnabled,
              let secondaryPath = secondaryFilePath,
              !secondaryPath.isEmpty,
              FileManager.default.fileExists(atPath: secondaryPath) else { return }

        diagnosticsAndLenses.counterpartSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let srcText = self.activeTextView?.string ?? self.documents[self.activeFilePath]?.storage.string ?? ""
            let decls = self.activeGoDeclarations.isEmpty ? self.findGoDeclarations(in: srcText) : self.activeGoDeclarations
            guard let currentDecl = decls.last(where: { $0.line <= sourceLine }),
                  currentDecl.kind == "func" || currentDecl.kind == "method" else { return }

            let secDecls = self.counterpartDeclarations(secondaryPath)

            var targetLine: Int? = nil
            if self.activeFilePath.hasSuffix("_test.go") {
                var targetName = currentDecl.symbolName
                for prefix in ["Test", "Benchmark", "Example", "Fuzz"] where targetName.hasPrefix(prefix) {
                    targetName = String(targetName.dropFirst(prefix.count))
                    if targetName.hasPrefix("_") { targetName = String(targetName.dropFirst()) }
                    break
                }
                targetLine = secDecls.first(where: { $0.symbolName == targetName })?.line
            } else {
                let exactNames = ["Test" + currentDecl.symbolName, "Test_" + currentDecl.symbolName, "Benchmark" + currentDecl.symbolName]
                targetLine = secDecls.first(where: { exactNames.contains($0.symbolName) })?.line
            }

            if let line = targetLine, let secTV = self.secondaryTextView as? GoLensTextView {
                DispatchQueue.main.async {
                    if let targetIdx = secTV.characterIndex(forLine: line, col: 1) {
                        let range = NSRange(location: targetIdx, length: 0)
                        secTV.scrollRangeToVisible(range)
                    }
                }
            }
        }
        diagnosticsAndLenses.counterpartSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func saveActiveFileAndFormat() {
        let responderTV = (NSApp.keyWindow?.firstResponder as? GoLensTextView)
            ?? (mainWindow?.firstResponder as? GoLensTextView)
            ?? (activeTextView as? GoLensTextView)
        responderTV?.breakUndoCoalescing()
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()

        var sessionsToSave: [DocumentSession] = []
        var seenPaths = Set<String>()

        if let responderDoc = responderTV?.document {
            sessionsToSave.append(responderDoc)
            seenPaths.insert(responderDoc.path)
        } else if let responderPath = responderTV?.filePath, !responderPath.isEmpty, let doc = documents[responderPath] {
            sessionsToSave.append(doc)
            seenPaths.insert(doc.path)
        }

        if let activeDoc = activeDocument, !seenPaths.contains(activeDoc.path) {
            if sessionsToSave.isEmpty || activeDoc.isEdited || editedFiles.contains(activeDoc.path) {
                sessionsToSave.append(activeDoc)
                seenPaths.insert(activeDoc.path)
            }
        }

        if isSplitMode, let secondaryPath = secondaryFilePath, !secondaryPath.isEmpty,
           let secondaryDoc = documents[secondaryPath], !seenPaths.contains(secondaryDoc.path) {
            if sessionsToSave.isEmpty || secondaryDoc.isEdited || editedFiles.contains(secondaryDoc.path) {
                sessionsToSave.append(secondaryDoc)
                seenPaths.insert(secondaryDoc.path)
            }
        }

        for session in sessionsToSave {
            save(session, reportsFailure: true)
        }
    }

    func save(_ session: DocumentSession, reportsFailure: Bool = false, then: @escaping (Bool) -> Void = { _ in }) {
        if EcosystemDocumentTools.isHTTPEnvironmentFile(session.path) {
            writeDocument(session, reportsFailure: reportsFailure) { [weak self] ok in
                self?.refreshAllHTTPOutlines()
                then(ok)
            }
            return
        }
        guard session.syncsToCore, session.path.hasSuffix(".go"), (organizeImportsOnSave || formatOnSave) else {
            writeDocument(session, reportsFailure: reportsFailure, then: then)
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        let shouldOrganize = organizeImportsOnSave
        let shouldFormat = formatOnSave
        let undoChain = EditUndoChain(actionName: shouldFormat ? "Format Document" : "Organize Imports")

        let runFormatAndWrite: () -> Void = { [weak self] in
            guard let self else { return }
            if shouldFormat {
                self.applyCoreEdits({ FormattingEdits($0, 8) }, to: session, undoChain: undoChain) {
                    measureLog(String(format: "save-format %.1f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000))
                    self.writeDocument(session, reportsFailure: reportsFailure, then: then)
                }
            } else {
                measureLog(String(format: "save-imports %.1f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000))
                self.writeDocument(session, reportsFailure: reportsFailure, then: then)
            }
        }

        if shouldOrganize {
            applyCoreEdits({ OrganizeImportsEdits($0) }, to: session, undoChain: undoChain) {
                runFormatAndWrite()
            }
        } else {
            runFormatAndWrite()
        }
    }

    func organizeImportsActiveDocument() {
        guard activeFilePath.hasSuffix(".go"), let session = documents[activeFilePath], session.syncsToCore else { return }
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()
        applyCoreEdits({ OrganizeImportsEdits($0) }, to: session) {}
    }

    func applyCoreEdits(_ fetch: @escaping (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?, to session: DocumentSession,
                        undoChain: EditUndoChain? = nil, then: @escaping () -> Void) {
        let path = session.path
        let version = session.version
        lspRequestQueue.async {
            let json: String? = path.withCString { p in
                guard let c = fetch(p) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            DispatchQueue.main.async {
                defer { then() }
                guard let json, !json.isEmpty, session.version == version,
                      let response = try? JSONDecoder().decode(CoreEdits.self, from: Data(json.utf8)),
                      !response.edits.isEmpty else { return }
                guard let undoChain else {
                    self.applyTextEdits(response.edits, in: session)
                    return
                }
                if undoChain.version == version {
                    session.undoManager.removeAllActions(withTarget: undoChain.token)
                } else {
                    undoChain.before = session.storage.string
                    undoChain.selection = self.textView(showing: session)?.selectedRange()
                    undoChain.token = NSObject()
                }
                self.applyRanges(self.resolvedRanges(response.edits, in: session), in: session, registersUndo: false)
                undoChain.version = session.version
                self.registerNetUndo(for: undoChain, in: session)
            }
        }
    }

    func writeDocument(_ session: DocumentSession, replacingDiskChanges: Bool = false, reportsFailure: Bool = false, then: @escaping (Bool) -> Void = { _ in }) {
        let path = session.path
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if !replacingDiskChanges, let onDisk, let known = session.diskModified, onDisk != known {
            let alert = NSAlert()
            alert.messageText = "“\((path as NSString).lastPathComponent)” was changed by another app since you opened it."
            alert.informativeText = "If you save, the changes made by the other app will be lost."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            present(alert) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.writeDocument(session, replacingDiskChanges: true, reportsFailure: reportsFailure, then: then)
                } else {
                    then(false)
                }
            }
            return
        }
        let text = session.storage.string
        let version = session.version
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                InvalidateWorkspaceSymbolFile(path)
            } catch {
                self.appendLog("Failed to save \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard reportsFailure else { then(false); return }
                    self.presentFailure(
                        "Couldn’t Save “\((path as NSString).lastPathComponent)”",
                        "\(Self.failureReason(error)) Your changes are still in the editor. Check that you can write to this location, then try again.",
                        recovery: ("Try Again", { self.writeDocument(session, replacingDiskChanges: replacingDiskChanges, reportsFailure: true, then: then) }),
                        revealing: path,
                        dismissed: { then(false) }
                    )
                }
                return
            }
            let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            DispatchQueue.main.async {
                session.diskModified = written
                self.diskConflicts.remove(path)
                self.deletedFiles.remove(path)
                session.savedText = text
                session.savedVersion = version
                self.recordLocalHistorySnapshot(for: path, content: text, label: "Saved")
                if !session.isEdited {
                    self.editedFiles.remove(path)
                }
                self.clearBuildRunFailureIfResolved()
                self.refreshActiveFileDiff()
                self.scheduleGitStatusRefresh(after: 0.5)
                self.fetchDocumentSymbols()
                self.refreshActiveFileBuildTarget()
                self.scheduleCodeLensReloadAfterSave(path)
                if ["go.mod", "go.work"].contains((path as NSString).lastPathComponent) {
                    self.refreshWorkspaceHealth()
                    DocumentationService.shared.invalidate(root: self.activeWorkspacePath)
                }
                if path.hasSuffix(".go") {
                    self.clearGeneratedOriginCache(for: path)
                    self.refreshGeneratedOrigin(for: path, text: text, version: version)
                }
                if path.hasSuffix(".go") || path.hasSuffix("go.mod") || path.hasSuffix("go.sum") {
                    self.gopilot.workspaceFileDidChange()
                }
                self.triggerDebouncedAutoTest(forFilePath: path)
                self.syncBookmarksAfterSave(forPath: path, content: text)
                self.saveBookmarksForWorkspace()
                self.saveBreakpointsForWorkspace()
                self.updateTodosForSavedFile(path: path, content: text)
                self.scheduleLintAfterSave(path)
                then(true)
            }
        }
    }

    func editorMode(for path: String) -> EditorMode {
        return fileEditorModes[path] ?? .code
    }

    func breakEditorUndoCoalescing(for path: String? = nil) {
        let canonicalTarget = path.map(Self.canonicalPath)
        let candidates: [GoLensTextView?] = [
            NSApp.keyWindow?.firstResponder as? GoLensTextView,
            mainWindow?.firstResponder as? GoLensTextView,
            activeTextView as? GoLensTextView,
            primaryTextView as? GoLensTextView,
            secondaryTextView as? GoLensTextView
        ]
        var seenViews = Set<ObjectIdentifier>()
        var undoManagers: [UndoManager] = []
        var seenUndoManagers = Set<ObjectIdentifier>()
        func appendUndoManager(_ undoManager: UndoManager?) {
            guard let undoManager, seenUndoManagers.insert(ObjectIdentifier(undoManager)).inserted else { return }
            undoManagers.append(undoManager)
        }
        for tv in candidates {
            guard let tv, seenViews.insert(ObjectIdentifier(tv)).inserted else { continue }
            if let path, let canonicalTarget {
                let tvPath = tv.filePath
                let docPath = tv.document?.path
                let matches = tvPath == path
                    || docPath == path
                    || Self.canonicalPath(tvPath) == canonicalTarget
                    || (docPath.map(Self.canonicalPath) == canonicalTarget)
                if !matches { continue }
            }
            tv.breakUndoCoalescing()
            appendUndoManager(tv.undoManager)
            appendUndoManager(tv.document?.undoManager)
        }
        if let path, let session = documentSession(forPath: path) {
            appendUndoManager(session.undoManager)
        }
        for undo in undoManagers where !undo.isUndoing && !undo.isRedoing {
            while undo.groupingLevel > 0 {
                undo.endUndoGrouping()
            }
        }
    }

    func focusCodeEditor(for path: String) {
        let canonicalTarget = Self.canonicalPath(path)
        let applyFocus = { [weak self] in
            guard let self,
                  Self.canonicalPath(self.activeFilePath) == canonicalTarget,
                  self.editorMode(for: path) != .diff else { return }
            let candidates = [self.activeTextView, self.primaryTextView, self.secondaryTextView]
            if let tv = candidates.compactMap({ $0 as? GoLensTextView }).first(where: {
                $0.filePath == path || Self.canonicalPath($0.filePath) == canonicalTarget
            }) {
                if tv.window?.firstResponder !== tv {
                    tv.window?.makeFirstResponder(tv)
                }
                self.activeTextView = tv
            }
        }
        DispatchQueue.main.async {
            applyFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                applyFocus()
            }
        }
    }

    func setEditorMode(_ mode: EditorMode, for path: String) {
        let oldMode = fileEditorModes[path] ?? .code
        guard oldMode != mode else { return }
        if oldMode == .code {
            breakEditorUndoCoalescing(for: path)
        }
        fileEditorModes[path] = mode
        if mode != .diff && path == activeFilePath && !path.isEmpty {
            loadDocument(path)
            refreshActiveFileDiff()
            fetchDocumentSymbols()
            syncVisibleDocuments()
            refreshActiveFileBuildTarget()
            syncCounterpartFile()
            updateCaretLineBlame()
            if showEscapeAnalysis && path.hasSuffix(".go") {
                reloadEscapeAnalysis(forPath: path)
            }
            if oldMode == .diff && mode == .code {
                focusCodeEditor(for: path)
            }
        }
    }

    func setupMemoryPressureObserver() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.releaseUnusedCaches()
        }
        source.resume()
        memoryPressureSource = source
    }

    func releaseUnusedCaches() {
        let visible = Set(visibleDocumentPaths)
        for (path, session) in documents {
            if !visible.contains(path) && !session.isEdited && !editedFiles.contains(path) {
                session.close()
                documents.removeValue(forKey: path)
                loadedDocuments.remove(path)
                codeLensCache.removeValue(forKey: path)
                codeLensProgress.removeValue(forKey: path)
                goplsLenses.removeValue(forKey: path)
                moduleNotes.removeValue(forKey: path)
                foldableRanges.removeValue(forKey: path)
            }
        }
        if consoleOutput.count > 200 {
            consoleOutput = Array(consoleOutput.suffix(200))
            consoleOutputBytes = consoleOutput.reduce(0) { $0 + $1.text.utf8.count }
        }
        DispatchQueue.global(qos: .utility).async {
            ReleaseGoMemory()
        }
    }

    func enableFullAnalysisForLargeFile(_ path: String) {
        guard let session = documents[path] else { return }
        session.largeFileAnalysisOverride = true
        largeFileModeRevision &+= 1
        if let tv = activeTextView as? GoLensTextView, tv.document === session {
            tv.needsDisplay = true
            documentDidEdit(session)
        }
    }
}
