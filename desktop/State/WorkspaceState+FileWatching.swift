import Foundation
import AppKit

extension WorkspaceState {
    var externalLibrariesNode: FileItem? {
        if externalDependencies.isEmpty {
            return nil
        }
        return FileItem(
            name: "External Libraries",
            fullPath: "external_deps_root",
            isDirectory: true,
            children: externalDependencies
        )
    }

    func requestNewItem(folder: Bool) {
        showNavigator(.files)
        newItemRequest = folder
    }

    func projectRelativePath(_ path: String) -> String {
        let root = activeWorkspacePath + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    func showNavigator(_ navigator: Navigator) {
        selectedSidebarTab = navigator
        isSidebarVisible = true
    }

    func configureFileSystemWatcher() {
        fileSystemWatcher?.stop()
        if !activeWorkspacePath.isEmpty {
            fileSystemWatcher = FileSystemWatcher(path: activeWorkspacePath) { [weak self] change in
                guard let self = self else { return }
                if self.isReloading {
                    self.pendingReload = true
                    self.pendingFileSystemChange.merge(change)
                    return
                }
                self.isReloading = true
                self.applyFileSystemChange(change) { [weak self] in
                    guard let self = self else { return }
                    self.isReloading = false
                    if self.pendingReload {
                        self.pendingReload = false
                        let pending = self.pendingFileSystemChange
                        self.pendingFileSystemChange = FileSystemChange()
                        self.fileSystemWatcher?.triggerReload(pending)
                    }
                }
            } onFilesChanged: { [weak self] paths in
                self?.filesChangedOnDisk(paths)
            } onGitChanged: { [weak self] in
                self?.scheduleGitStatusRefreshFromFileEvent()
            }
            fileSystemWatcher?.start()
        } else {
            fileSystemWatcher = nil
        }
    }

    func restoreLastWorkspace(opening explicitPath: String? = nil) {
        let defaults = UserDefaults.standard
        if let lastWorkspace = explicitPath ?? defaults.string(forKey: "GoLensLastWorkspacePath"), !lastWorkspace.isEmpty {
            _ = SecurityScopedBookmarkManager.shared.resolveAndAccess(path: lastWorkspace)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: lastWorkspace, isDirectory: &isDir), isDir.boolValue {
                let lastFile = defaults.string(forKey: "GoLensLastFilePath")
                self.activeWorkspacePath = lastWorkspace

                if let savedExpanded = defaults.stringArray(forKey: "GoLensLastExpandedFolders") {
                    let rawSet = Set(savedExpanded)
                    let rootPrefix = lastWorkspace.hasSuffix("/") ? lastWorkspace : lastWorkspace + "/"
                    self.expandedFolders = rawSet.filter { folder in
                        guard folder.hasPrefix(rootPrefix) else { return true }
                        var parent = (folder as NSString).deletingLastPathComponent
                        while parent.hasPrefix(rootPrefix) && parent != lastWorkspace {
                            if !rawSet.contains(parent) { return false }
                            parent = (parent as NSString).deletingLastPathComponent
                        }
                        return true
                    }
                }

                loadFiles(from: lastWorkspace)
                self.selectedConsoleTab = defaults.integer(forKey: "GoLensLastConsoleTab")

                if let lastFile, lastFile.hasPrefix(lastWorkspace + "/") {
                    if FileManager.default.fileExists(atPath: lastFile) {
                        openFile(lastFile)
                    }
                }
            }
        }
    }

    func loadRecentProjects() {
        let stored = UserDefaults.standard.stringArray(forKey: "GoLensRecentProjects") ?? []
        let existing = stored.filter { path in
            if SecurityScopedBookmarkManager.shared.isSandboxed {
                return SecurityScopedBookmarkManager.shared.canAccess(path: path)
            }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        if existing != stored {
            UserDefaults.standard.set(existing, forKey: "GoLensRecentProjects")
        }
        recentProjects = existing
    }

    func clearRecentProjects() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppEnvironment.shared.clearRecentProjects()
            }
            return
        }
        for path in recentProjects {
            SecurityScopedBookmarkManager.shared.removeBookmark(for: path)
        }
        UserDefaults.standard.removeObject(forKey: "GoLensRecentProjects")
        recentProjects = []
    }

    func recentProjectTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let clashes = recentProjects.filter { ($0 as NSString).lastPathComponent == name }.count > 1
        guard clashes else { return name }
        return "\(name) — \(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)"
    }

    func addToRecentProjects(_ path: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppEnvironment.shared.addRecentProject(path)
            }
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppEnvironment.shared.addRecentProject(path)
            }
        }
    }

    func openRecentProject(path: String, then: @escaping () -> Void = {}) {
        let openBlock = {
            MainActor.assumeIsolated {
                WorkspaceSessionRegistry.shared.openProject(at: path) { _ in
                    then()
                }
            }
        }
        if Thread.isMainThread {
            openBlock()
        } else {
            DispatchQueue.main.async(execute: openBlock)
        }
    }

    func switchWorkspace(to path: String, then: @escaping () -> Void = {}) {
        guard path != activeWorkspacePath else { then(); return }
        reviewEditedDocuments(before: "opening another project") { proceed in
            guard proceed else { return }
            if !self.activeWorkspacePath.isEmpty {
                SecurityScopedBookmarkManager.shared.stopAccessing(url: URL(fileURLWithPath: self.activeWorkspacePath))
            }
            _ = SecurityScopedBookmarkManager.shared.resolveAndAccess(path: path)
            self.activeWorkspacePath = path
            then()
        }
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            if let url = panel.url {
                SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
                openRecentProject(path: url.path)
            }
        }
    }

    func cloneRepository(url: String, destinationParent: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLastComponent = URL(string: cleanedURL)?.deletingPathExtension().lastPathComponent ?? "cloned-repo"
        let repoName = (rawLastComponent.isEmpty || rawLastComponent == "/") ? "cloned-repo" : rawLastComponent
        let destinationPath = (destinationParent as NSString).appendingPathComponent(repoName)
        let parentURL = URL(fileURLWithPath: destinationParent, isDirectory: true)
        SecurityScopedBookmarkManager.shared.saveBookmark(for: parentURL)
        _ = MainActor.assumeIsolated {
            SandboxVMManager.shared.mountWorkspaceSync(url: parentURL)
        }

        Task {
            do {
                let result = try await GitCommandRunner.shared.run(
                    args: ["clone", cleanedURL, repoName],
                    root: destinationParent,
                    directory: destinationParent
                )
                if result.isUnavailable {
                    throw NSError(domain: GitCommandError.domain, code: GitCommandError.unavailableCode, userInfo: [NSLocalizedDescriptionKey: "The Linux VM isn’t ready, so Git couldn’t run. Try again in a moment."])
                }
                if result.isOutsideWorkspace {
                    throw NSError(domain: GitCommandError.domain, code: GitCommandError.outsideWorkspaceCode, userInfo: [NSLocalizedDescriptionKey: "Git can only run inside a folder shared with the Linux VM."])
                }
                _ = try Self.gitOutput(result)
                await MainActor.run {
                    let clonedURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
                    SecurityScopedBookmarkManager.shared.saveBookmark(for: clonedURL)
                    completion(.success(destinationPath))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func refreshDependencies() {
        guard !activeWorkspacePath.isEmpty else {
            DispatchQueue.main.async { self.externalDependencies = [] }
            return
        }

        let goModPath = (activeWorkspacePath as NSString).appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: goModPath) else {
            DispatchQueue.main.async { self.externalDependencies = [] }
            return
        }

        Task.detached {
            guard let cRes = goModPath.withCString({ cPath in InspectGoModFile(cPath, nil, 0) }) else { return }
            let jsonStr = String(cString: cRes)
            FreeGoCString(cRes)
            struct ModReport: Decodable {
                struct Req: Decodable {
                    let module: String
                    let version: String
                }
                let requires: [Req]?
            }
            guard let data = jsonStr.data(using: .utf8),
                  let report = try? JSONDecoder().decode(ModReport.self, from: data),
                  let reqs = report.requires else { return }
            var deps: [FileItem] = []
            for req in reqs {
                let name = "\(req.module)@\(req.version)"
                deps.append(FileItem(name: name, fullPath: req.module, isDirectory: true, children: nil))
            }
            await MainActor.run {
                self.externalDependencies = deps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
    }

    func toggleFolder(at path: String) {
        let isExternal = externalDependencies.contains { $0.fullPath == path } ||
                         externalDependencies.contains { dep in
                             guard let children = dep.children else { return false }
                             return children.contains { $0.fullPath == path } ||
                                    (children.contains(where: { $0.isDirectory }) && path.hasPrefix(dep.fullPath + "/"))
                         }

        let wasExpanded = expandedFolders.contains(path)
        if wasExpanded {
            let prefix = path + "/"
            expandedFolders = expandedFolders.filter { $0 != path && !$0.hasPrefix(prefix) }
        } else {
            expandedFolders.insert(path)
        }

        if isExternal {
            if !wasExpanded {
                DispatchQueue.main.async { [weak self] in
                    self?.toggleExternalDependencyFolder(at: path, wasExpanded: false)
                }
            }
            return
        }

        if !wasExpanded {
            expandFolderInTree(path)
        }
    }

    func expandFolderInTree(_ path: String) {
        func expand(in items: inout [FileItem]) -> Bool {
            for i in items.indices {
                if items[i].fullPath == path && items[i].isDirectory {
                    if items[i].children == nil {
                        items[i].children = loadDirectoryContents(at: path, depth: 0)
                        return true
                    }
                    return false
                }
                if items[i].children != nil && path.hasPrefix(items[i].fullPath + "/") {
                    if expand(in: &items[i].children!) {
                        return true
                    }
                }
            }
            return false
        }
        var updated = fileTree
        if expand(in: &updated) {
            DispatchQueue.main.async { [weak self] in
                self?.fileTree = updated
            }
        }
    }

    func toggleExternalDependencyFolder(at path: String, wasExpanded: Bool) {
        for i in externalDependencies.indices {
            if externalDependencies[i].fullPath == path {
                if !wasExpanded && externalDependencies[i].children == nil {
                    externalDependencies[i].children = loadDirectoryContents(at: path, depth: 0)
                }
                return
            }
            if externalDependencies[i].children != nil && path.hasPrefix(externalDependencies[i].fullPath + "/") {
                toggleInSubtree(&externalDependencies[i].children!, path: path, wasExpanded: wasExpanded)
            }
        }
    }

    func toggleInSubtree(_ items: inout [FileItem], path: String, wasExpanded: Bool) {
        for i in items.indices {
            if items[i].fullPath == path && items[i].isDirectory {
                if !wasExpanded && items[i].children == nil {
                    items[i].children = loadDirectoryContents(at: path, depth: 0)
                }
                return
            }
            if items[i].children != nil && path.hasPrefix(items[i].fullPath + "/") {
                toggleInSubtree(&items[i].children!, path: path, wasExpanded: wasExpanded)
            }
        }
    }
}
