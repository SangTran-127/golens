import Foundation
import SwiftUI
import SwiftTerm

extension WorkspaceState {
    func loadFiles(from path: String, completion: (() -> Void)? = nil) {
        let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let expanded = expandedFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let tree = self._loadDirectoryContents(at: canonicalPath, depth: 0, expandedFolders: expanded)
            DispatchQueue.main.async {
                guard canonicalPath == URL(fileURLWithPath: self.activeWorkspacePath).resolvingSymlinksInPath().path else {
                    completion?()
                    return
                }
                self.fileTree = tree
                self.expandedFolders.subtracting(expanded).forEach(self.expandFolderInTree)
                self.files = self.fileTree.map { $0.name }
                self.refreshExternalDependencyChildren()
                if self.refreshesGitStatusAutomatically {
                    self.refreshGitStatus()
                }
                self.loadWorkspaceTests()
                completion?()
            }
        }
    }

    func refreshExternalDependencyChildren() {
        for i in externalDependencies.indices {
            let dep = externalDependencies[i]
            if self.expandedFolders.contains(dep.fullPath) {
                externalDependencies[i].children = self.loadDirectoryContents(at: dep.fullPath, depth: 0)
            } else {
                externalDependencies[i].children = nil
            }
        }
    }

    func folderItemsForMenu(at path: String) -> [FileItem] {
        let folder = Self.canonicalPath(path)
        let root = Self.canonicalPath(activeWorkspacePath)
        if !activeWorkspacePath.isEmpty, folder == root || folder.hasPrefix(root + "/") {
            var nodes: [FileItem]? = fileTree
            if folder != root {
                for name in folder.dropFirst(root.count + 1).split(separator: "/") {
                    nodes = nodes?.first { $0.isDirectory && $0.name == name }?.children
                }
            }
            if let nodes, !nodes.isEmpty { return nodes }
        }
        return _listDirectory(at: folder, depth: 9, expandedFolders: [], reusing: nil)
    }

    func loadDirectoryContents(at path: String, depth: Int = 0) -> [FileItem] {
        return _loadDirectoryContents(at: path, depth: depth, expandedFolders: expandedFolders)
    }

    func allWorkspaceRelativeFilePaths() -> [String] {
        let root = activeWorkspacePath.hasSuffix("/") ? activeWorkspacePath : activeWorkspacePath + "/"
        var result: [String] = []
        func collect(_ items: [FileItem]) {
            for item in items {
                if item.isDirectory {
                    if let children = item.children {
                        collect(children)
                    }
                } else if item.fullPath.hasPrefix(root) {
                    result.append(String(item.fullPath.dropFirst(root.count)))
                }
            }
        }
        collect(fileTree)
        return result
    }

    static let treeExcludedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "bmp", "pdf", "zip", "tar", "gz",
        "exe", "dylib", "so", "a", "o", "bin", "db", "sqlite", "swp", "swo"
    ]
    static let treeExcludedDirs: Set<String> = [
        ".git", ".build", "build", "node_modules", "vendor",
        ".golens", ".swiftpm", ".idea", ".vscode", ".agents",
        ".scannerwork", ".cursor", ".cache", ".gemini", ".claude", ".Trash",
        ".next", "dist", "target", ".venv", "venv", "__pycache__", "DerivedData", "Pods"
    ]
    static let treeExcludedFiles: Set<String> = [".DS_Store", ".localized"]
    static let sqliteCompanionSuffixes = ["-journal", "-wal", "-shm"]

    static func isExcludedFromTree(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if treeExcludedFiles.contains(name) || name.hasPrefix("._") || isSQLiteCompanion(url) { return true }
        return treeExcludedExtensions.contains(url.pathExtension.lowercased()) || treeExcludedDirs.contains(name)
    }

    static func isSQLiteCompanion(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let suffix = sqliteCompanionSuffixes.first(where: { name.count > $0.count && name.hasSuffix($0) }) else { return false }
        let database = url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count)))
        return FileManager.default.fileExists(atPath: database.path)
    }

    func _loadDirectoryContents(at path: String, depth: Int, expandedFolders: Set<String>) -> [FileItem] {
        _listDirectory(at: path, depth: depth, expandedFolders: expandedFolders, reusing: nil)
    }

    func _listDirectory(at path: String, depth: Int, expandedFolders: Set<String>, reusing previous: [FileItem]?) -> [FileItem] {
        guard depth < 10 else { return [] }

        let fileManager = FileManager.default
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            var reusable: [String: FileItem] = [:]
            for item in previous ?? [] where item.isDirectory && item.children != nil {
                reusable[item.fullPath] = item
            }

            return urls.filter { url in
                !Self.isExcludedFromTree(url)
            }.map { url in
                let name = url.lastPathComponent
                let canonicalUrlPath = url.resolvingSymlinksInPath().path
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: canonicalUrlPath, isDirectory: &isDir)

                var children: [FileItem]? = nil
                if isDir.boolValue {
                    if let kept = reusable[canonicalUrlPath] {
                        children = kept.children
                    } else if depth < 6 || expandedFolders.contains(canonicalUrlPath) {
                        children = _listDirectory(at: canonicalUrlPath, depth: depth + 1, expandedFolders: expandedFolders, reusing: nil)
                    } else {
                        children = []
                    }
                }

                return FileItem(name: name, fullPath: canonicalUrlPath, isDirectory: isDir.boolValue, children: children)
            }.sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            return []
        }
    }

    private enum TreePatchResult {
        case patched(changed: Bool)
        case notLoaded
        case missing
    }

    private func patchTree(_ items: inout [FileItem], dir: String, nesting: Int, expandedFolders: Set<String>) -> TreePatchResult {
        var result = TreePatchResult.missing
        for i in items.indices {
            guard items[i].isDirectory else { continue }
            let fullPath = items[i].fullPath
            if fullPath == dir {
                guard let children = items[i].children, nesting < 6 || expandedFolders.contains(dir) else {
                    if case .missing = result { result = .notLoaded }
                    continue
                }
                let fresh = _listDirectory(at: dir, depth: nesting + 1, expandedFolders: expandedFolders, reusing: children)
                var changed = false
                if fresh != children {
                    items[i].children = fresh
                    changed = true
                }
                if case .patched(let earlier) = result { changed = changed || earlier }
                result = .patched(changed: changed)
            } else if dir.hasPrefix(fullPath + "/") {
                guard var children = items[i].children, nesting < 6 || expandedFolders.contains(fullPath) else {
                    if case .missing = result { result = .notLoaded }
                    continue
                }
                switch patchTree(&children, dir: dir, nesting: nesting + 1, expandedFolders: expandedFolders) {
                case .patched(let changed):
                    if changed { items[i].children = children }
                    if case .patched(let earlier) = result {
                        result = .patched(changed: changed || earlier)
                    } else {
                        result = .patched(changed: changed)
                    }
                case .notLoaded:
                    if case .missing = result { result = .notLoaded }
                case .missing:
                    break
                }
            }
        }
        return result
    }

    func applyFileSystemChange(_ change: FileSystemChange, completion: @escaping () -> Void) {
        let workspace = activeWorkspacePath
        guard !workspace.isEmpty else {
            completion()
            return
        }
        guard !change.needsFullReload, !fileTree.isEmpty else {
            loadFiles(from: workspace, completion: completion)
            refreshDependencies()
            return
        }
        let snapshot = fileTree
        let expanded = expandedFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
            let rootPrefix = root + "/"
            var dirs = Set<String>()
            var needsFullReload = false
            for raw in change.paths {
                var path = raw
                if !path.hasPrefix(rootPrefix) {
                    let parent = URL(fileURLWithPath: (raw as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
                    path = (parent as NSString).appendingPathComponent((raw as NSString).lastPathComponent)
                }
                guard path.hasPrefix(rootPrefix) else {
                    needsFullReload = true
                    break
                }
                let components = path.dropFirst(rootPrefix.count).split(separator: "/").map(String.init)
                guard !components.isEmpty else {
                    needsFullReload = true
                    break
                }
                if components.dropLast().contains(where: { Self.treeExcludedDirs.contains($0) }) || Self.isExcludedFromTree(URL(fileURLWithPath: path)) {
                    continue
                }
                dirs.insert((path as NSString).deletingLastPathComponent)
            }

            var tree = snapshot
            var changed = false
            if !needsFullReload {
                for dir in dirs.sorted(by: { $0.count < $1.count }) {
                    if dir == root {
                        let fresh = self._listDirectory(at: root, depth: 0, expandedFolders: expanded, reusing: tree)
                        if fresh != tree {
                            tree = fresh
                            changed = true
                        }
                        continue
                    }
                    switch self.patchTree(&tree, dir: dir, nesting: 0, expandedFolders: expanded) {
                    case .patched(let patched):
                        changed = changed || patched
                    case .notLoaded:
                        break
                    case .missing:
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                            needsFullReload = true
                        }
                    }
                    if needsFullReload { break }
                }
            }

            DispatchQueue.main.async {
                guard self.activeWorkspacePath == workspace else {
                    completion()
                    return
                }
                if needsFullReload {
                    self.loadFiles(from: workspace, completion: completion)
                    self.refreshDependencies()
                    return
                }
                if changed {
                    self.fileTree = tree
                    self.expandedFolders.subtracting(expanded).forEach(self.expandFolderInTree)
                    let names = self.fileTree.map { $0.name }
                    if names != self.files { self.files = names }
                }
                self.scheduleGitStatusRefreshFromFileEvent()
                if !change.directoryPaths.isEmpty || change.paths.contains(where: { $0.hasSuffix("_test.go") }) {
                    self.loadWorkspaceTests()
                }
                let moduleFiles: Set<String> = ["go.mod", "go.sum", "go.work", "go.work.sum"]
                if change.paths.contains(where: { moduleFiles.contains(($0 as NSString).lastPathComponent) }) {
                    self.refreshDependencies()
                }
                completion()
            }
        }
    }

    func isTextFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let binaryExtensions = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "pdf", "zip", "tar", "gz", "exe", "dylib", "so", "a", "o", "bin", "db", "sqlite"]
        return !binaryExtensions.contains(ext)
    }

    func updateFlatDiagnostics(changedPath: String? = nil) {
        if let changedPath {
            updateDiagnosticsIndex(changedPath: changedPath)
        } else {
            rebuildDiagnosticsIndex()
        }
    }

    func jumpTo(filePath: String, line: Int, column: Int) {
        let rawPath = filePath.hasPrefix("/") ? filePath : (activeWorkspacePath as NSString).appendingPathComponent(filePath)
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        recordNavigationJump(toPath: fullPath, line: line, col: column)
        openFile(fullPath)
        restoreCaretLocation(line: line, column: column, inPath: fullPath)
    }

    static let maxOpenFileBytes = 50 << 20
    static let maxLanguageServerFileBytes = 10 << 20

    func openFile(_ nameOrPath: String, readOnly: Bool = false, asPreview: Bool = false) {
        measureStartup("open-file")
        if sourceControl.editorSurface != nil { sourceControl.editorSurface = nil }
        let rawPath = nameOrPath.hasPrefix("/") ? nameOrPath : (activeWorkspacePath as NSString).appendingPathComponent(nameOrPath)
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return
        }
        openResolvedFile(fullPath, readOnly: readOnly, asPreview: asPreview)
    }

    func openResolvedFile(_ fullPath: String, readOnly: Bool = false, asPreview: Bool = false) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return
        }
        if readOnly {
            fileEditorModes[fullPath] = .readOnly
        }
        if openFiles.contains(fullPath) {
            if !asPreview && previewTabPath == fullPath {
                previewTabPath = nil
            }
        } else if asPreview && enablePreviewTab {
            if let oldPreview = previewTabPath,
               oldPreview != fullPath,
               !editedFiles.contains(oldPreview),
               !pinnedTabs.contains(oldPreview),
               documents[oldPreview]?.isEdited != true,
               let idx = openFiles.firstIndex(of: oldPreview) {
                openFiles[idx] = fullPath
                if secondaryFilePath != oldPreview {
                    releaseDocumentState(oldPreview)
                }
            } else {
                openFiles.append(fullPath)
            }
            previewTabPath = fullPath
        } else {
            openFiles.append(fullPath)
        }
        if activeFilePath != fullPath {
            activeFilePath = fullPath
        }
    }

    @discardableResult
    func openBackgroundDocument(_ nameOrPath: String) -> DocumentSession? {
        let rawPath = nameOrPath.hasPrefix("/") ? nameOrPath : (activeWorkspacePath as NSString).appendingPathComponent(nameOrPath)
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        if let existing = documents[fullPath] { return existing }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue, isTextFile(fullPath) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath)
        let size = attributes?[.size] as? Int ?? 0
        guard size <= Self.maxOpenFileBytes, let text = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
        if !openFiles.contains(fullPath) {
            openFiles.append(fullPath)
        }
        let large = text.utf8.count > Self.maxLanguageServerFileBytes
        if large && fileEditorModes[fullPath] == nil {
            fileEditorModes[fullPath] = .readOnly
        }
        let session = DocumentSession(path: fullPath, text: text, syncsToCore: !large)
        session.workspace = self
        session.diskModified = attributes?[.modificationDate] as? Date
        session.onEdit = { [weak self] session, _, _ in
            self?.documentDidEdit(session)
        }
        documents[fullPath] = session
        loadedDocuments.insert(fullPath)
        refreshGeneratedOrigin(for: fullPath, text: text, version: session.version)
        if !large { scheduleLintOnOpen(fullPath) }
        return session
    }

    func promotePreviewTab(_ path: String) {
        if previewTabPath == path {
            previewTabPath = nil
        }
    }

    func openFileInDiff(_ resolvedOrRawPath: String) {
        if sourceControl.editorSurface != nil { sourceControl.editorSurface = nil }
        let rawPath = resolvedOrRawPath.hasPrefix("/") ? resolvedOrRawPath : (activeWorkspacePath as NSString).appendingPathComponent(resolvedOrRawPath)
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            guard isUntrackedPath(fullPath) else { return }
        }
        if fileEditorModes[fullPath] == nil || fileEditorModes[fullPath] == .code {
            breakEditorUndoCoalescing(for: fullPath)
        }
        fileEditorModes[fullPath] = .diff
        if !openFiles.contains(fullPath) {
            openFiles.append(fullPath)
        }
        if activeFilePath != fullPath {
            activeFilePath = fullPath
        }
    }

    func openFileInSplit(_ nameOrPath: String, line: Int? = nil, column: Int = 1) {
        let rawPath = nameOrPath.hasPrefix("/") ? nameOrPath : (activeWorkspacePath as NSString).appendingPathComponent(nameOrPath)
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return
        }
        if !openFiles.contains(fullPath) {
            openFiles.append(fullPath)
        }
        loadDocument(fullPath)
        if !isSplitMode {
            isSplitMode = true
        }
        secondaryFilePath = fullPath
        if let line {
            secondaryPane.pendingJumpToLine = line
            secondaryPane.pendingJumpToCol = column
        }
    }

    func loadDocument(_ path: String, synchronously: Bool = false) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return }
        guard (openFiles.contains(path) || secondaryFilePath == path), isTextFile(path), documents[path] == nil, !pendingDocumentLoads.contains(path) else { return }
        pendingDocumentLoads.insert(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if synchronously, size <= 1 << 20 {
            let (result, modified) = Self.readDocument(path)
            finishLoadingDocument(path, result: result, modified: modified)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (result, modified) = Self.readDocument(path)
            DispatchQueue.main.async {
                self?.finishLoadingDocument(path, result: result, modified: modified)
            }
        }
    }

    nonisolated static func readDocument(_ path: String) -> (Result<String, Error>, Date?) {
        let exists = FileManager.default.fileExists(atPath: path)
        let attributes = exists ? (try? FileManager.default.attributesOfItem(atPath: path)) : nil
        let size = attributes?[.size] as? Int ?? 0
        let modified = attributes?[.modificationDate] as? Date
        let name = (path as NSString).lastPathComponent
        if !exists {
            return (.failure(NSError(domain: "GoLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "“\(name)” was deleted from disk."])), modified)
        }
        if size > maxOpenFileBytes {
            let sizeText = UserMessage.byteCount(Int64(size))
            return (.failure(NSError(domain: "GoLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) is \(sizeText). GoLens opens files up to 50 MB so editing stays fast. Open it in another app instead."])), modified)
        }
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return (.success(text), modified)
        }
        return (.failure(NSError(domain: "GoLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) isn’t a UTF-8 text file, so GoLens can’t show it. Open it in another app instead."])), modified)
    }

    private func finishLoadingDocument(_ path: String, result: Result<String, Error>, modified: Date?) {
        pendingDocumentLoads.remove(path)
        guard (openFiles.contains(path) || secondaryFilePath == path), documents[path] == nil else { return }
        switch result {
        case .success(let content):
            fileOpenErrors.removeValue(forKey: path)
            deletedFiles.remove(path)
            let large = content.utf8.count > Self.maxLanguageServerFileBytes
            if large && fileEditorModes[path] == nil {
                fileEditorModes[path] = .readOnly
            }
            let session = DocumentSession(path: path, text: content, syncsToCore: !large)
            session.workspace = self
            session.diskModified = modified
            if let view = restoredViewStates.removeValue(forKey: path) {
                session.lastSelection = NSRange(location: view.caret, length: 0)
                session.lastScrollOrigin = NSPoint(x: 0, y: view.scrollY)
            }
            session.onEdit = { [weak self] session, _, _ in
                self?.documentDidEdit(session)
            }
            documents[path] = session
            loadedDocuments.insert(path)
            if !large {
                scheduleLintOnOpen(path)
                refreshGeneratedOrigin(for: path, text: content, version: session.version)
            }
            if path == activeFilePath || path == secondaryFilePath {
                documentDidEdit(session)
            }
        case .failure(let error):
            if (error as NSError).code == 3 {
                deletedFiles.insert(path)
            }
            fileOpenErrors[path] = error.localizedDescription
        }
    }

    func documentDidEdit(_ session: DocumentSession) {
        if session.isEdited {
            if previewTabPath == session.path {
                previewTabPath = nil
            }
            if !editedFiles.contains(session.path) {
                editedFiles.insert(session.path)
            }
            MainActor.assumeIsolated { UnsavedBufferJournal.shared.noteEdit(session) }
            gopilot.workspaceFileDidChange()
        } else if editedFiles.contains(session.path) {
            editedFiles.remove(session.path)
            gopilot.workspaceFileDidChange()
        }
        if isSplitMode, session.path == secondaryFilePath {
            if secondaryPane.lineCount != session.lines.count {
                secondaryPane.lineCount = session.lines.count
            }
            if session.path != activeFilePath {
                secondaryPane.declarationsWorkItem?.cancel()
                let secPath = session.path
                let secWork = DispatchWorkItem { [weak self, weak session] in
                    guard let self, let session, self.secondaryFilePath == secPath else { return }
                    let text = session.storage.string
                    let version = session.version
                    if secPath.hasSuffix(".go"), !session.isEffectiveLargeFileMode {
                        DispatchQueue.global(qos: .utility).async {
                            let decls = self.findGoDeclarations(in: text)
                            DispatchQueue.main.async {
                                if self.secondaryFilePath == secPath {
                                    self.secondaryPane.goDeclarations = decls
                                }
                                self.refreshGeneratedOrigin(for: secPath, text: text, version: version)
                            }
                        }
                    } else if EcosystemDocumentTools.isNonGoEcosystemFile(secPath), !session.isEffectiveLargeFileMode {
                        DispatchQueue.global(qos: .utility).async {
                            let symbols = EcosystemDocumentTools.documentSymbols(forPath: secPath, text: text)
                            DispatchQueue.main.async {
                                if self.secondaryFilePath == secPath {
                                    self.secondaryPane.documentSymbols = symbols
                                }
                            }
                        }
                    }
                }
                secondaryPane.declarationsWorkItem = secWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: secWork)
            }
        }
        guard session.path == activeFilePath else { return }
        if primaryPane.lineCount != session.lines.count {
            primaryPane.lineCount = session.lines.count
        }
        if activeFileLineCount != session.lines.count {
            activeFileLineCount = session.lines.count
        }
        guard session.path.hasSuffix(".go"), !session.isEffectiveLargeFileMode else {
            declarationsWorkItem?.cancel()
            activeGoDeclarations = []
            let filename = (session.path as NSString).lastPathComponent
            if (filename == "go.mod" || filename == "go.work") && !session.isEffectiveLargeFileMode {
                scheduleCodeLensRecomputeAfterTyping(session.path)
            }
            if EcosystemDocumentTools.isNonGoEcosystemFile(session.path) && !session.isEffectiveLargeFileMode {
                let path = session.path
                let work = DispatchWorkItem { [weak self, weak session] in
                    guard let self, let session else { return }
                    let text = session.storage.string
                    let version = session.version
                    DispatchQueue.global(qos: .utility).async {
                        let symbols = EcosystemDocumentTools.documentSymbols(forPath: path, text: text)
                        let diags: [DiagnosticData]?
                        if EcosystemDocumentTools.isJSONFile(path) || EcosystemDocumentTools.isYAMLFile(path) || EcosystemDocumentTools.isMakefile(path) {
                            diags = EcosystemDocumentTools.validate(path: path, text: text)
                        } else {
                            diags = nil
                        }
                        DispatchQueue.main.async {
                            if self.activeFilePath == path {
                                self.activeDocumentSymbols = symbols
                            }
                            if let diags {
                                self.replaceDiagnostics(at: path, dropping: { !Self.dockerCommandDiagnosticSources.contains($0.source ?? "") }, with: diags)
                            }
                            if EcosystemDocumentTools.isDockerfile(path) {
                                self.refreshDockerfileFindings(path)
                            }
                            self.reloadGoplsCodeLenses(forPath: path, version: version)
                        }
                    }
                }
                declarationsWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            return
        }
        refreshFileTests(session.path)
        scheduleCodeLensRecomputeAfterTyping(session.path)
        declarationsWorkItem?.cancel()
        let path = session.path
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            let text = session.storage.string
            let version = session.version
            DispatchQueue.global(qos: .utility).async {
                let decls = self.findGoDeclarations(in: text)
                DispatchQueue.main.async {
                    if self.activeFilePath == path {
                        self.activeGoDeclarations = decls
                    }
                    self.refreshGeneratedOrigin(for: path, text: text, version: version)
                }
            }
        }
        declarationsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func releaseDocumentState(_ path: String) {
        documents.removeValue(forKey: path)?.close()
        editedFiles.remove(path)
        diskConflicts.remove(path)
        deletedFiles.remove(path)
        loadedDocuments.remove(path)
        pendingDocumentLoads.remove(path)
        diagnostics.removeValue(forKey: path)
        let canon = Self.canonicalDiagnosticPath(path)
        if moduleDoctorBucket.release(path: path, canonicalPath: canon) {
            _ = publishMergedDiagnostics(for: canon)
            NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: canon)
        }
        codeLensCache.removeValue(forKey: path)
        codeLensVersions.removeValue(forKey: path)
        codeLensProgress.removeValue(forKey: path)
        goplsLenses.removeValue(forKey: path)
        blameCache.removeValue(forKey: path)
        foldableRanges.removeValue(forKey: path)
        foldedRanges.removeValue(forKey: path)
        foldedCharRangesCache.removeValue(forKey: path)
        fileEditorModes.removeValue(forKey: path)
        fileOpenErrors.removeValue(forKey: path)
        markdownPreviewMode.removeValue(forKey: path)
        fileTests.removeValue(forKey: path)
        fileTestLines.removeValue(forKey: path)
        moduleNotes.removeValue(forKey: path)
        escapeAnnotations.removeValue(forKey: path)
        clearGeneratedOriginCache(for: path)
    }

    func closeFile(_ fullPath: String) {
        if previewTabPath == fullPath {
            previewTabPath = nil
        }
        openFiles.removeAll { $0 == fullPath }
        releaseDatabaseConsole(fullPath)
        releaseDocumentState(fullPath)
        restoreSavedBookmarks(for: fullPath)
        restoreSavedBreakpointLines(for: fullPath)
        updateFlatDiagnostics(changedPath: fullPath)
        if activeFilePath == fullPath {
            activeFilePath = openFiles.last ?? ""
        }
    }

    func closeFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if paths.count == 1 {
            closeFile(paths[0])
            return
        }
        let closing = Set(paths)
        if let preview = previewTabPath, closing.contains(preview) {
            previewTabPath = nil
        }
        openFiles.removeAll { closing.contains($0) }
        var released = Set<String>()
        for path in paths where released.insert(path).inserted {
            releaseDatabaseConsole(path)
            releaseDocumentState(path)
            restoreSavedBookmarks(for: path)
            restoreSavedBreakpointLines(for: path)
        }
        updateFlatDiagnostics()
        if closing.contains(activeFilePath) {
            activeFilePath = openFiles.last ?? ""
        }
    }

    func saveFile() {
        saveActiveFileAndFormat()
    }

    func closeAllDocuments() {
        saveSession()
        isClosingAllDocuments = true
        defer { isClosingAllDocuments = false }
        for path in Array(documents.keys) {
            documents.removeValue(forKey: path)?.close()
        }
        for path in openFiles {
            releaseDocumentState(path)
        }
        openFiles.removeAll()
        editedFiles.removeAll()
        diskConflicts.removeAll()
        deletedFiles.removeAll()
        activeFilePath = ""
        moduleDoctorBucket.removeAll()
        diagnostics.removeAll()
        updateFlatDiagnostics()
    }

    func renameFileOrFolder(atPath oldPath: String, toPath newPath: String) {
        var updatedExpandedFolders = Set<String>()
        for folder in expandedFolders {
            if folder == oldPath {
                updatedExpandedFolders.insert(newPath)
            } else if folder.hasPrefix(oldPath + "/") {
                updatedExpandedFolders.insert(newPath + String(folder.dropFirst(oldPath.count)))
            } else {
                updatedExpandedFolders.insert(folder)
            }
        }
        self.expandedFolders = updatedExpandedFolders

        var newOpenFiles: [String] = []
        var reopen: [String] = []
        for file in openFiles {
            if file == oldPath || file.hasPrefix(oldPath + "/") {
                let updated = newPath + String(file.dropFirst(oldPath.count))
                let preview = markdownPreviewMode[file]
                if let session = documents[file] {
                    let dirty = session.storage.string
                    let wasEdited = session.isEdited
                    releaseDocumentState(file)
                    let moved = DocumentSession(path: updated, text: dirty, syncsToCore: session.syncsToCore)
                    moved.workspace = self
                    moved.onEdit = { [weak self] session, _, _ in self?.documentDidEdit(session) }
                    moved.diskModified = session.diskModified
                    if wasEdited {
                        moved.savedText = nil
                        moved.savedVersion = -1
                        editedFiles.insert(updated)
                    }
                    documents[updated] = moved
                    loadedDocuments.insert(updated)
                } else {
                    releaseDocumentState(file)
                    reopen.append(updated)
                }
                markdownPreviewMode[updated] = preview
                newOpenFiles.append(updated)
            } else {
                newOpenFiles.append(file)
            }
        }
        self.openFiles = newOpenFiles

        var updatedPinned = Set<String>()
        for pinned in pinnedTabs {
            if pinned == oldPath {
                updatedPinned.insert(newPath)
            } else if pinned.hasPrefix(oldPath + "/") {
                updatedPinned.insert(newPath + String(pinned.dropFirst(oldPath.count)))
            } else {
                updatedPinned.insert(pinned)
            }
        }
        if updatedPinned != pinnedTabs {
            pinnedTabs = updatedPinned
        }

        if let sec = secondaryFilePath {
            if sec == oldPath {
                secondaryFilePath = newPath
            } else if sec.hasPrefix(oldPath + "/") {
                secondaryFilePath = newPath + String(sec.dropFirst(oldPath.count))
            }
        }

        recentFiles = recentFiles.map { recent in
            if recent == oldPath {
                return newPath
            } else if recent.hasPrefix(oldPath + "/") {
                return newPath + String(recent.dropFirst(oldPath.count))
            }
            return recent
        }

        if activeFilePath == oldPath || activeFilePath.hasPrefix(oldPath + "/") {
            activeFilePath = newPath + String(activeFilePath.dropFirst(oldPath.count))
        }
        for path in reopen where path == activeFilePath {
            openFile(path)
        }
        updateBookmarksAndTodosForRenamedPath(from: oldPath, to: newPath)
        scheduleSessionSave()
        loadFiles(from: activeWorkspacePath)
        gopilot.workspaceFileDidChange()
    }

    func moveOpenTab(fromPath sourcePath: String, toTargetPath targetPath: String) {
        guard sourcePath != targetPath,
              let fromIndex = openFiles.firstIndex(of: sourcePath),
              let toIndex = openFiles.firstIndex(of: targetPath),
              fromIndex != toIndex else {
            return
        }
        var updated = openFiles
        let moved = updated.remove(at: fromIndex)
        updated.insert(moved, at: toIndex)
        openFiles = updated
        scheduleSessionSave()
    }

    func openOrReorderTab(fromPath rawSourcePath: String, toTargetPath targetPath: String?) {
        let fullPath = URL(fileURLWithPath: rawSourcePath).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
            return
        }
        let wasAlreadyOpen = openFiles.contains(fullPath)
        if !wasAlreadyOpen {
            let readOnly = !activeWorkspacePath.isEmpty && !fullPath.hasPrefix(activeWorkspacePath + "/")
            openFile(fullPath, readOnly: readOnly)
        }
        if let targetPath, targetPath != fullPath {
            moveOpenTab(fromPath: fullPath, toTargetPath: targetPath)
        } else if targetPath == nil, let currentIdx = openFiles.firstIndex(of: fullPath), currentIdx != openFiles.count - 1 {
            var updated = openFiles
            let moved = updated.remove(at: currentIdx)
            updated.append(moved)
            openFiles = updated
            scheduleSessionSave()
        }
        if !wasAlreadyOpen || activeFilePath != fullPath {
            activeFilePath = fullPath
        }
    }

    @discardableResult
    func createFileOrFolder(name: String, inParent parentPath: String? = nil, isFolder: Bool) -> Bool {
        guard !activeWorkspacePath.isEmpty else { return false }
        let parent = parentPath ?? activeWorkspacePath
        let fullPath = (parent as NSString).appendingPathComponent(name)
        
        let errPtr = fullPath.withCString { pathCStr in
            CreateFileOrFolder(pathCStr, isFolder ? 1 : 0)
        }
        if let errPtr {
            let rawReason = String(cString: errPtr)
            FreeGoCString(errPtr)
            let reason = Self.formatCommandReason(rawReason, fallback: "The operation couldn’t be completed.")
            presentFailure(
                "Couldn’t Create “\(name)”",
                "\(reason) Check that “\((parent as NSString).lastPathComponent)” still exists and that you can write to it, then try again.",
                recovery: ("Try Again", { [weak self] in _ = self?.createFileOrFolder(name: name, inParent: parentPath, isFolder: isFolder) }),
                revealing: parent
            )
            return false
        }
        loadFiles(from: activeWorkspacePath)
        if !isFolder {
            let resolved = URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path
            let length = ((try? String(contentsOfFile: resolved, encoding: .utf8)) ?? "").utf16.count
            restoredViewStates[resolved] = SavedWorkspaceTabSession.View(caret: length, scrollY: 0)
            openFile(fullPath)
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.activeTextView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return true
    }

}
