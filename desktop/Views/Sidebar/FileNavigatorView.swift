import AppKit
import SwiftUI

@Observable
final class FileNavigatorModel {
    struct PendingCreation: Equatable {
        let parentPath: String?
        let isFolder: Bool
    }

    var creation: PendingCreation?
    var creationName = ""
    var selection: String?
    var renamingPath: String?
    var renameInput = ""
    var itemToDelete: FileItem?
    var draggedItemPath: String?
    var dropTargetFolderPath: String? {
        didSet { workspace.fileRowStates.updateDropTarget(dropTargetFolderPath) }
    }
    @ObservationIgnored var dropTargetEnteredAt: CFAbsoluteTime = 0
    @ObservationIgnored private var springLoadWorkItem: DispatchWorkItem?
    @ObservationIgnored private var dragWatchdogTimer: Timer?
    @ObservationIgnored weak var targetWorkspace: WorkspaceState?

    var workspace: WorkspaceState { targetWorkspace ?? WorkspaceState.shared }

    func startCreation(isFolder: Bool, parentPath: String?) {
        creationName = ""
        if let parentPath { expandFolders(through: parentPath) }
        creation = PendingCreation(parentPath: parentPath, isFolder: isFolder)
    }

    func creationParent(for path: String?) -> String? {
        guard let path, !path.isEmpty, !isReadOnly(path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let folder = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
        return folder == workspace.activeWorkspacePath ? nil : folder
    }

    private func expandFolders(through folder: String) {
        let root = workspace.activeWorkspacePath
        var current = folder
        var chain: [String] = []
        while current.hasPrefix(root + "/") {
            chain.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for path in chain.reversed() where !workspace.expandedFolders.contains(path) {
            workspace.toggleFolder(at: path)
        }
    }

    static func isValidRelativePath(_ name: String) -> Bool {
        guard !name.hasPrefix("/") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    func submitCreation() {
        guard let creation else { return }
        var name = creationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if creation.isFolder { while name.hasSuffix("/") { name.removeLast() } }
        if !name.isEmpty {
            let kind = creation.isFolder ? "folder" : "file"
            guard Self.isValidRelativePath(name) else {
                let alert = NSAlert()
                alert.messageText = "“\(name)” isn’t a valid \(kind) name."
                alert.informativeText = "Use a name or a path inside the project, such as handlers/user.go. Paths can’t start with “/” or contain “..” or empty parts."
                workspace.present(alert) { _ in }
                return
            }
            let parent = creation.parentPath ?? workspace.activeWorkspacePath
            let fullPath = (parent as NSString).appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: fullPath) else {
                let alert = NSAlert()
                alert.messageText = "A \(kind) named “\(name)” already exists in “\((parent as NSString).lastPathComponent)”."
                alert.informativeText = "Choose a different name."
                workspace.present(alert) { _ in }
                return
            }
            guard workspace.createFileOrFolder(name: name, inParent: creation.parentPath, isFolder: creation.isFolder) else { return }
            expandFolders(through: (fullPath as NSString).deletingLastPathComponent)
            if creation.isFolder { selection = fullPath }
        }
        self.creation = nil
    }

    func cancelCreation() {
        creation = nil
    }

    func startRename(_ item: FileItem) {
        if item.isDirectory || item.name.hasPrefix(".") {
            renameInput = item.name
        } else {
            renameInput = (item.name as NSString).deletingPathExtension
        }
        renamingPath = item.fullPath
    }

    func cancelRename() {
        renamingPath = nil
    }

    func submitRename(_ item: FileItem) {
        defer { renamingPath = nil }
        let newName = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }

        var finalName = newName
        let originalExtension = (item.name as NSString).pathExtension
        if !item.isDirectory && !item.name.hasPrefix(".") && !newName.hasPrefix(".") && !originalExtension.isEmpty {
            let suffix = "." + originalExtension
            finalName = (newName.hasSuffix(suffix) ? String(newName.dropLast(suffix.count)) : newName) + suffix
        }

        let destination = URL(fileURLWithPath: item.fullPath).deletingLastPathComponent().appendingPathComponent(finalName).path
        guard destination != item.fullPath else { return }
        let folderName = ((destination as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !FileManager.default.fileExists(atPath: destination) else {
            workspace.appendLog("Rename failed: a file or folder named '\(finalName)' already exists.")
            workspace.presentFailure(
                "Couldn’t Rename “\(item.name)”",
                "A file or folder named “\(finalName)” already exists in “\(folderName)”. Choose another name.",
                recovery: ("Choose Another Name", { [weak self] in self?.resumeRename(item, with: newName) })
            )
            return
        }
        do {
            try FileManager.default.moveItem(atPath: item.fullPath, toPath: destination)
            workspace.renameFileOrFolder(atPath: item.fullPath, toPath: destination)
        } catch {
            workspace.appendLog("Rename failed: \(error.localizedDescription)")
            workspace.presentFailure(
                "Couldn’t Rename “\(item.name)”",
                "\(WorkspaceState.failureReason(error)) Check that you can write to “\(folderName)”, then try again.",
                recovery: ("Try Again", { [weak self] in
                    self?.renameInput = newName
                    self?.submitRename(item)
                }),
                revealing: item.fullPath
            )
        }
    }

    private func resumeRename(_ item: FileItem, with name: String) {
        renameInput = name
        renamingPath = item.fullPath
    }

    func moveToTrash(_ item: FileItem) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.fullPath), resultingItemURL: nil)
            workspace.closeFile(item.fullPath)
            workspace.loadFiles(from: workspace.activeWorkspacePath)
            workspace.gopilot.workspaceFileDidChange()
        } catch {
            workspace.appendLog("Failed to move '\(item.name)' to the Trash: \(error.localizedDescription)")
            workspace.presentFailure(
                "Couldn’t Move “\(item.name)” to the Trash",
                "\(WorkspaceState.failureReason(error)) Check that you can change the folder that contains it, then try again.",
                recovery: ("Try Again", { [weak self] in self?.moveToTrash(item) }),
                revealing: item.fullPath
            )
        }
    }

    func isReadOnly(_ path: String) -> Bool {
        !path.hasPrefix(workspace.activeWorkspacePath + "/")
    }

    func isReadOnlyFolder(_ folderPath: String) -> Bool {
        guard !workspace.activeWorkspacePath.isEmpty else { return true }
        return folderPath != workspace.activeWorkspacePath && !folderPath.hasPrefix(workspace.activeWorkspacePath + "/")
    }

    func targetFolder(for item: FileItem) -> String {
        if item.isDirectory {
            return item.fullPath
        }
        return (item.fullPath as NSString).deletingLastPathComponent
    }

    func beginDrag(for path: String) {
        workspace.activeDraggedTabPath = nil
        workspace.activeDraggedNavigatorPath = path
        draggedItemPath = path
        startDragWatchdog()
    }

    func clearDragState() {
        springLoadWorkItem?.cancel()
        springLoadWorkItem = nil
        dragWatchdogTimer?.invalidate()
        dragWatchdogTimer = nil
        dropTargetEnteredAt = 0
        if draggedItemPath != nil { draggedItemPath = nil }
        if dropTargetFolderPath != nil { dropTargetFolderPath = nil }
        workspace.activeDraggedNavigatorPath = nil
    }

    private func startDragWatchdog() {
        guard dragWatchdogTimer == nil else { return }
        dragWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.clearDragState()
            }
        }
    }

    func canMoveItem(from sourcePath: String?, intoFolder destinationFolder: String) -> Bool {
        guard workspace.activeDraggedTabPath == nil,
              !isReadOnlyFolder(destinationFolder) else {
            return false
        }
        guard let sourcePath, !sourcePath.isEmpty else {
            return true
        }
        guard !isReadOnly(sourcePath) else { return false }
        let destPath = URL(fileURLWithPath: destinationFolder).appendingPathComponent((sourcePath as NSString).lastPathComponent).path
        guard sourcePath != destPath,
              sourcePath != destinationFolder,
              !destinationFolder.hasPrefix(sourcePath + "/") else {
            return false
        }
        return true
    }

    func updateDropTargetFolder(_ folderPath: String?) {
        guard workspace.activeDraggedTabPath == nil else {
            if dropTargetFolderPath != nil { dropTargetFolderPath = nil }
            return
        }
        let activeSource = draggedItemPath ?? workspace.activeDraggedNavigatorPath
        guard let folderPath, canMoveItem(from: activeSource, intoFolder: folderPath) else {
            springLoadWorkItem?.cancel()
            springLoadWorkItem = nil
            if dropTargetFolderPath != nil { dropTargetFolderPath = nil }
            return
        }
        if dropTargetFolderPath != folderPath {
            dropTargetFolderPath = folderPath
            dropTargetEnteredAt = CFAbsoluteTimeGetCurrent()
            startDragWatchdog()
            springLoadWorkItem?.cancel()
            springLoadWorkItem = nil
            if folderPath != workspace.activeWorkspacePath && !workspace.expandedFolders.contains(folderPath) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.dropTargetFolderPath == folderPath,
                          NSEvent.pressedMouseButtons & 1 != 0,
                          !self.workspace.expandedFolders.contains(folderPath) else {
                        return
                    }
                    self.workspace.toggleFolder(at: folderPath)
                }
                springLoadWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
            }
        }
    }

    func open(_ item: FileItem, asPreview: Bool = false) {
        if item.isDirectory {
            if workspace.expandedFolders.contains(item.fullPath),
               let sel = selection, sel.hasPrefix(item.fullPath + "/") {
                selection = item.fullPath
            }
            workspace.toggleFolder(at: item.fullPath)
        } else {
            workspace.openResolvedFile(item.fullPath, readOnly: isReadOnly(item.fullPath), asPreview: asPreview)
        }
    }

    func moveItemOnDisk(from rawSourcePath: String, intoFolder rawFolderPath: String) {
        let sourcePath = URL(fileURLWithPath: rawSourcePath).resolvingSymlinksInPath().path
        let folderPath = URL(fileURLWithPath: rawFolderPath).resolvingSymlinksInPath().path
        guard canMoveItem(from: sourcePath, intoFolder: folderPath) else { return }
        let fileName = (sourcePath as NSString).lastPathComponent
        let destinationPath = URL(fileURLWithPath: folderPath).appendingPathComponent(fileName).path
        guard sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/") else { return }
        guard !FileManager.default.fileExists(atPath: destinationPath) else {
            workspace.appendLog("Move skipped: '\(fileName)' already exists in '\((folderPath as NSString).lastPathComponent)'.")
            workspace.presentFailure(
                "Couldn’t Move “\(fileName)”",
                "A file or folder named “\(fileName)” already exists in “\((folderPath as NSString).lastPathComponent)”. Rename one of them, then move it again.",
                revealing: destinationPath
            )
            return
        }
        do {
            try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
            if folderPath != workspace.activeWorkspacePath && !workspace.expandedFolders.contains(folderPath) {
                workspace.expandedFolders.insert(folderPath)
            }
            workspace.renameFileOrFolder(atPath: sourcePath, toPath: destinationPath)
            selection = destinationPath
        } catch {
            workspace.appendLog("Move failed: \(error.localizedDescription)")
            workspace.presentFailure(
                "Couldn’t Move “\(fileName)”",
                "\(WorkspaceState.failureReason(error)) Check that you can write to “\((folderPath as NSString).lastPathComponent)”, then try again.",
                recovery: ("Try Again", { [weak self] in self?.moveItemOnDisk(from: sourcePath, intoFolder: folderPath) }),
                revealing: sourcePath
            )
        }
    }

    func handleDrop(_ providers: [NSItemProvider], into folderPath: String) -> Bool {
        let directSource = draggedItemPath ?? workspace.activeDraggedNavigatorPath
        let activeTarget = dropTargetFolderPath
        let dwellTime = CFAbsoluteTimeGetCurrent() - dropTargetEnteredAt
        clearDragState()
        guard workspace.activeDraggedTabPath == nil,
              !workspace.activeWorkspacePath.isEmpty,
              !isReadOnlyFolder(folderPath),
              activeTarget == folderPath,
              dwellTime >= 0.16 else {
            return false
        }
        if let directSource, !directSource.isEmpty {
            guard canMoveItem(from: directSource, intoFolder: folderPath) else { return false }
            DispatchQueue.main.async { [weak self] in
                self?.moveItemOnDisk(from: directSource, intoFolder: folderPath)
            }
            return true
        }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let self, let sourceURL = url else { return }
            DispatchQueue.main.async {
                self.moveItemOnDisk(from: sourceURL.path, intoFolder: folderPath)
            }
        }
        return true
    }
}

struct FileNavigatorView: View {
    @Bindable var workspace: WorkspaceState
    @State private var model = FileNavigatorModel()
    @State private var clickMonitor: Any?
    @State private var filterQuery: String = ""
    @Environment(\.colorScheme) private var colorScheme

    private static let externalRootPath = "external_deps_root"

    private var trimmedFilterQuery: String {
        filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProjectTree: [FileItem] {
        let q = trimmedFilterQuery
        guard !q.isEmpty else { return workspace.fileTree }
        return filterNodes(workspace.fileTree, query: q)
    }

    private var filteredExternalTree: [FileItem] {
        let q = trimmedFilterQuery
        guard !q.isEmpty else { return workspace.externalDependencies }
        return filterNodes(workspace.externalDependencies, query: q)
    }

    var body: some View {
        let projectItems = filteredProjectTree
        let externalItems = filteredExternalTree
        let isFiltering = !trimmedFilterQuery.isEmpty
        let hasNoFilterMatches = isFiltering && projectItems.isEmpty && externalItems.isEmpty

        VStack(spacing: 0) {
            PanelFilterBar(
                placeholder: "Filter files…",
                text: $filterQuery,
                accessibilityTitle: "Filter Files",
                onSubmit: {
                    openSelectedOrFirstFilteredFile(in: projectItems + externalItems)
                },
                onMoveSelection: { delta in
                    moveVisibleSelection(by: delta, in: projectItems + externalItems, forceExpand: isFiltering)
                }
            )
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)

            Divider()

            if hasNoFilterMatches {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Files") {
                    filterQuery = ""
                }
            } else {
                List(selection: Bindable(model).selection) {
                    if let creation = model.creation, creation.parentPath == nil {
                        FileTreeCreationView(model: model, creation: creation)
                    }

                    ForEach(projectItems) { item in
                        FileNode(item: item, model: model, forceExpand: isFiltering, workspace: workspace)
                    }

                    if !externalItems.isEmpty {
                        Section(isExpanded: isFiltering ? .constant(true) : externalLibrariesExpanded) {
                            ForEach(externalItems) { item in
                                FileNode(item: item, model: model, forceExpand: isFiltering, workspace: workspace)
                            }
                        } header: {
                            Text("External Libraries")
                        }
                    }
                }
                .listStyle(.sidebar)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.automatic)
                .background(
                    OutlineSingleSelectionEnforcer(
                        expandedFolders: workspace.expandedFolders
                    )
                )
                .contextMenu(forSelectionType: String.self) { paths in
                    contextMenu(for: paths)
                } primaryAction: { paths in
                    guard model.renamingPath == nil else { return }
                    let isKeyboard = NSApp.currentEvent?.type == .keyDown
                    for item in paths.compactMap(fileItem) {
                        if item.isDirectory && !isKeyboard { continue }
                        model.open(item, asPreview: false)
                    }
                }
            }
        }
        .onChange(of: model.selection) { _, path in
            guard NSApp.currentEvent?.type != .keyDown, let item = path.flatMap(fileItem), !item.isDirectory,
                  model.renamingPath != item.fullPath, item.fullPath != workspace.activeFilePath else { return }
            model.open(item, asPreview: true)
        }
        .onAppear {
            model.targetWorkspace = workspace
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                guard workspace.mainWindow == nil || event.window === workspace.mainWindow else {
                    return event
                }
                if event.type == .leftMouseDown {
                    guard !event.modifierFlags.contains(.control),
                          model.renamingPath == nil,
                          let hitView = event.window?.contentView?.hitTest(event.locationInWindow),
                          !(hitView is NSTextField),
                          !(hitView is NSTextView) else {
                        return event
                    }
                    var v: NSView? = hitView
                    while let cur = v, !(cur is NSOutlineView) { v = cur.superview }
                    if let outline = v as? NSOutlineView {
                        outline.allowsMultipleSelection = false
                        let pt = outline.convert(event.locationInWindow, from: nil)
                        let row = outline.row(at: pt)
                        if row >= 0, !outline.frameOfOutlineCell(atRow: row).contains(pt) {
                            if let clickedPath = Self.extractRowPath(from: outline.rowView(atRow: row, makeIfNecessary: false)),
                               let item = fileItem(clickedPath) {
                                if item.isDirectory {
                                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                                    model.selection = item.fullPath
                                    model.open(item, asPreview: false)
                                    return nil
                                } else {
                                    if !outline.isRowSelected(row) {
                                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                                    }
                                    model.selection = item.fullPath
                                    if event.clickCount >= 2 {
                                        model.open(item, asPreview: false)
                                        return nil
                                    } else {
                                        model.open(item, asPreview: true)
                                    }
                                }
                            } else if !outline.isRowSelected(row) {
                                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            }
                        }
                    }
                    return event
                }
                if model.draggedItemPath != nil || model.dropTargetFolderPath != nil {
                    DispatchQueue.main.async {
                        model.clearDragState()
                    }
                }
                return event
            }
        }
        .onDisappear {
            model.clearDragState()
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.clearDragState()
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.command), let item = model.selection.flatMap(fileItem) else { return .ignored }
            model.open(item, asPreview: false)
            return .handled
        }
        .onChange(of: workspace.activeFilePath, initial: true) { _, path in
            if model.selection != path {
                model.selection = path.isEmpty ? nil : path
            }
        }
        .onChange(of: workspace.newItemRequest, initial: true) { _, folder in
            guard let folder else { return }
            workspace.newItemRequest = nil
            model.startCreation(isFolder: folder, parentPath: model.creationParent(for: model.selection ?? workspace.activeFilePath))
        }
        .alert(
            "Move “\(model.itemToDelete?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { model.itemToDelete != nil }, set: { if !$0 { model.itemToDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                if let item = model.itemToDelete {
                    model.itemToDelete = nil
                    DispatchQueue.main.async {
                        model.moveToTrash(item)
                    }
                }
            }
        } message: {
            Text("You can restore it from the Trash in Finder.")
        }
    }

    private var externalLibrariesExpanded: Binding<Bool> {
        Binding(
            get: { workspace.expandedFolders.contains(Self.externalRootPath) },
            set: { expanded in
                if expanded != workspace.expandedFolders.contains(Self.externalRootPath) {
                    workspace.toggleFolder(at: Self.externalRootPath)
                }
            }
        )
    }

    @ViewBuilder
    private func contextMenu(for paths: Set<String>) -> some View {
        if let path = paths.first, let item = fileItem(path) {
            if !item.isDirectory {
                Button("Open in Split Editor", systemImage: "rectangle.split.2x1") {
                    workspace.openFileInSplit(path)
                }
                Button("Local History…", systemImage: "clock.arrow.circlepath") {
                    workspace.presentLocalHistory(for: path)
                }
                Button("Show File History…", systemImage: "clock") {
                    workspace.presentFileHistory(for: path)
                }
                let changes = workspace.isGitRepositoryOpen ? workspace.git.changedFiles.filter { $0.absolutePath == path } : []
                if !changes.isEmpty {
                    Menu("Source Control", systemImage: "arrow.triangle.branch") {
                        let conflicted = changes.contains { $0.status == "U" }
                        Button("Stage", systemImage: "plus.circle") { workspace.stageFile(path) }
                            .disabled(conflicted || !changes.contains { !$0.isStaged })
                        Button("Unstage", systemImage: "minus.circle") { workspace.unstageFile(path) }
                            .disabled(!changes.contains { $0.isStaged })
                        Button("Mark as Resolved", systemImage: "checkmark.seal") { workspace.markResolved(path) }
                        .disabled(!conflicted)
                        Divider()
                        Button("Discard Changes…", systemImage: "arrow.uturn.backward") {
                            if let file = changes.first(where: { !$0.isStaged }) ?? changes.first {
                                workspace.confirmDiscard(file)
                            }
                        }
                        .disabled(conflicted)
                    }
                }
                Divider()
            }
            Button("Open in Integrated Terminal", systemImage: "terminal") {
                workspace.openTerminal(atDirectory: path)
            }
            Divider()
            if model.isReadOnly(path) {
                revealButton(path)
            } else {
                Button("New File", systemImage: "doc.badge.plus") { model.startCreation(isFolder: false, parentPath: model.creationParent(for: path)) }
                Button("New Folder", systemImage: "folder.badge.plus") { model.startCreation(isFolder: true, parentPath: model.creationParent(for: path)) }
                Divider()
                Button("Rename", systemImage: "pencil") { model.startRename(item) }
                if (path as NSString).deletingLastPathComponent != workspace.activeWorkspacePath {
                    Button("Move to Project Root", systemImage: "arrow.up.to.line") {
                        model.moveItemOnDisk(from: path, intoFolder: workspace.activeWorkspacePath)
                    }
                }
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.itemToDelete = item }
                Divider()
                revealButton(path)
            }
        } else {
            Button("New File", systemImage: "doc.badge.plus") { model.startCreation(isFolder: false, parentPath: nil) }
            Button("New Folder", systemImage: "folder.badge.plus") { model.startCreation(isFolder: true, parentPath: nil) }
        }
    }

    @ViewBuilder
    private func revealButton(_ path: String) -> some View {
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Button("Copy Relative Path", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.projectRelativePath(path), forType: .string)
        }
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        fileItem(path)?.isDirectory ?? false
    }

    private func fileItem(_ path: String) -> FileItem? {
        func find(in items: [FileItem]) -> FileItem? {
            for item in items {
                if item.fullPath == path { return item }
                if let children = item.children, path.hasPrefix(item.fullPath + "/"), let match = find(in: children) {
                    return match
                }
            }
            return nil
        }
        return find(in: workspace.fileTree) ?? find(in: workspace.externalDependencies)
    }

    private func filterNodes(_ items: [FileItem], query: String) -> [FileItem] {
        items.compactMap { item in
            let relPath = workspace.projectRelativePath(item.fullPath)
            let directMatch = item.name.localizedCaseInsensitiveContains(query)
                || relPath.localizedCaseInsensitiveContains(query)
            if item.isDirectory {
                let filteredChildren = filterNodes(item.children ?? [], query: query)
                if !filteredChildren.isEmpty {
                    return FileItem(
                        name: item.name,
                        fullPath: item.fullPath,
                        isDirectory: true,
                        children: filteredChildren
                    )
                }
                if directMatch {
                    return item
                }
                return nil
            }
            return directMatch ? item : nil
        }
    }

    private func flattenVisibleItems(_ items: [FileItem], forceExpand: Bool) -> [FileItem] {
        var flat: [FileItem] = []
        for item in items {
            flat.append(item)
            if item.isDirectory,
               forceExpand || workspace.expandedFolders.contains(item.fullPath),
               let children = item.children {
                flat.append(contentsOf: flattenVisibleItems(children, forceExpand: forceExpand))
            }
        }
        return flat
    }

    private func moveVisibleSelection(by delta: Int, in roots: [FileItem], forceExpand: Bool) {
        let flat = flattenVisibleItems(roots, forceExpand: forceExpand)
        guard !flat.isEmpty else { return }
        if let current = model.selection,
           let idx = flat.firstIndex(where: { $0.fullPath == current }) {
            let next = min(max(0, idx + delta), flat.count - 1)
            model.selection = flat[next].fullPath
        } else {
            model.selection = delta >= 0 ? flat.first?.fullPath : flat.last?.fullPath
        }
    }

    private func openSelectedOrFirstFilteredFile(in roots: [FileItem]) {
        if let current = model.selection, let item = fileItem(current), !item.isDirectory {
            model.open(item, asPreview: false)
            return
        }
        let flat = flattenVisibleItems(roots, forceExpand: true)
        if let firstFile = flat.first(where: { !$0.isDirectory }) {
            model.selection = firstFile.fullPath
            model.open(firstFile, asPreview: false)
        }
    }

    private static func extractRowPath(from root: NSView?) -> String? {
        guard let root else { return nil }
        if let raw = root.identifier?.rawValue, raw.hasPrefix("golens-row:") {
            return String(raw.dropFirst("golens-row:".count))
        }
        for sub in root.subviews {
            if let found = extractRowPath(from: sub) {
                return found
            }
        }
        return nil
    }
}

private struct OutlineSingleSelectionEnforcer: NSViewRepresentable {
    let expandedFolders: Set<String>

    final class Coordinator: NSObject {
        weak var observedOutline: NSOutlineView?
        weak var anchor: NSView?
        var findOutline: ((NSView) -> NSOutlineView?)?
        private var tokens: [NSObjectProtocol] = []
        private var immediatePending = false
        private var trailingPass: DispatchWorkItem?

        deinit {
            trailingPass?.cancel()
            detach()
        }

        func scheduleSanitize() {
            if !immediatePending {
                immediatePending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.immediatePending = false
                    self.sanitizeNow()
                }
            }
            trailingPass?.cancel()
            let trailing = DispatchWorkItem { [weak self] in self?.sanitizeNow() }
            trailingPass = trailing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: trailing)
        }

        private func sanitizeNow() {
            let outline: NSOutlineView
            if let cached = observedOutline, cached.window != nil, !cached.isHiddenOrHasHiddenAncestor {
                outline = cached
            } else if let anchor, let found = findOutline?(anchor) {
                attach(to: found)
                outline = found
            } else {
                return
            }
            OutlineSingleSelectionEnforcer.sanitize(outline: outline)
        }

        func attach(to outline: NSOutlineView) {
            guard observedOutline !== outline else { return }
            detach()
            observedOutline = outline
            outline.allowsMultipleSelection = false
            outline.allowsEmptySelection = true
            let center = NotificationCenter.default
            let collapseExpandNames: [Notification.Name] = [
                NSOutlineView.itemWillCollapseNotification,
                NSOutlineView.itemDidCollapseNotification,
                NSOutlineView.itemDidExpandNotification
            ]
            for name in collapseExpandNames {
                let token = center.addObserver(forName: name, object: outline, queue: .main) { [weak self, weak outline] _ in
                    guard let self, let outline, self.observedOutline === outline else { return }
                    OutlineSingleSelectionEnforcer.sanitize(outline: outline)
                    self.scheduleSanitize()
                }
                tokens.append(token)
            }
            let selToken = center.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: outline, queue: .main) { [weak outline] _ in
                guard let outline else { return }
                outline.allowsMultipleSelection = false
                if outline.selectedRowIndexes.count > 1, let lastSelected = outline.selectedRowIndexes.last {
                    outline.selectRowIndexes(IndexSet(integer: lastSelected), byExtendingSelection: false)
                }
            }
            tokens.append(selToken)
        }

        func detach() {
            let center = NotificationCenter.default
            for token in tokens {
                center.removeObserver(token)
            }
            tokens.removeAll()
            observedOutline = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.findOutline = { Self.findOutlineView(from: $0) }
        context.coordinator.scheduleSanitize()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchor = nsView
        context.coordinator.scheduleSanitize()
    }

    static func sanitize(outline: NSOutlineView) {
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        if outline.selectedRowIndexes.count > 1, let lastSelected = outline.selectedRowIndexes.last {
            outline.selectRowIndexes(IndexSet(integer: lastSelected), byExtendingSelection: false)
        }
        let rowCount = outline.numberOfRows
        let selectedRow = outline.selectedRow

        var canonicalRowViews = Set<ObjectIdentifier>()
        if rowCount > 0 {
            for row in 0..<rowCount {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
                canonicalRowViews.insert(ObjectIdentifier(rowView))
                let shouldSelect = (row == selectedRow)
                if rowView.isSelected != shouldSelect {
                    rowView.isSelected = shouldSelect
                    rowView.needsDisplay = true
                }
                if rowView.numberOfColumns > 0, let activeCell = rowView.view(atColumn: 0) as? NSView {
                    for sub in rowView.subviews where sub is NSTableCellView && sub !== activeCell {
                        sub.isHidden = true
                        sub.removeFromSuperview()
                    }
                }
            }
        }

        var needsRetile = false
        for subview in Array(outline.subviews) {
            guard let rowView = subview as? NSTableRowView else { continue }
            let mappedRow = outline.row(for: rowView)
            let isCanonical = mappedRow >= 0 && mappedRow < rowCount && canonicalRowViews.contains(ObjectIdentifier(rowView))
            if !isCanonical {
                rowView.isSelected = false
                rowView.isHidden = true
                rowView.removeFromSuperview()
                needsRetile = true
            }
        }

        if rowCount > 0 {
            for row in 0..<rowCount {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
                let expectedRect = outline.rect(ofRow: row)
                if expectedRect.height > 0 && abs(rowView.frame.minY - expectedRect.minY) > 1.0 {
                    rowView.frame = expectedRect
                    needsRetile = true
                }
            }
        }

        if needsRetile {
            outline.tile()
            outline.needsLayout = true
            outline.needsDisplay = true
        }
    }

    private static func findOutlineView(from view: NSView) -> NSOutlineView? {
        var parent: NSView? = view.superview
        while let current = parent {
            if let outline = searchSubtreeForOutline(current) {
                return outline
            }
            parent = current.superview
        }
        return nil
    }

    private static func searchSubtreeForOutline(_ root: NSView) -> NSOutlineView? {
        if root.isHidden { return nil }
        if let outline = root as? NSOutlineView {
            return outline
        }
        for sub in root.subviews {
            if let found = searchSubtreeForOutline(sub) {
                return found
            }
        }
        return nil
    }
}

private struct FileNode: View {
    let item: FileItem
    let model: FileNavigatorModel
    var parentExpanded: Bool = true
    var forceExpand: Bool = false
    @Bindable var workspace: WorkspaceState

    var body: some View {
        if item.isDirectory {
            let isExpanded = parentExpanded && (forceExpand || workspace.expandedFolders.contains(item.fullPath))
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    guard !forceExpand else { return }
                    if expanded != workspace.expandedFolders.contains(item.fullPath) {
                        if !expanded, let sel = model.selection, sel.hasPrefix(item.fullPath + "/") {
                            model.selection = item.fullPath
                        }
                        workspace.toggleFolder(at: item.fullPath)
                    }
                }
            )) {
                if let creation = model.creation, creation.parentPath == item.fullPath {
                    FileTreeCreationView(model: model, creation: creation)
                }
                ForEach(item.children ?? []) { child in
                    FileNode(item: child, model: model, parentExpanded: isExpanded, forceExpand: forceExpand, workspace: workspace)
                }
            } label: {
                FileTreeItemView(item: item, isExpanded: isExpanded, model: model, workspace: workspace)
            }
            .tag(item.fullPath)
        } else {
            FileTreeItemView(item: item, isExpanded: false, model: model, workspace: workspace)
                .tag(item.fullPath)
        }
    }
}

struct FileTreeItemView: View {
    let item: FileItem
    let isExpanded: Bool
    let model: FileNavigatorModel
    @Bindable var workspace: WorkspaceState
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    private var isOnSelection: Bool {
        prominence == .increased
    }

    var body: some View {
        let state = workspace.fileRowStates.state(for: item.fullPath)
        let gitStatus = item.isDirectory ? state.folderGitStatus : state.gitStatus
        let isDropTargetFolder = item.isDirectory && state.isDropTarget
        HStack(spacing: Spacing.row) {
            FileIconView(fileName: item.name, path: item.fullPath, isFolder: item.isDirectory, isExpanded: isExpanded, childNames: item.isDirectory ? state.childNames(of: item.children) : nil, isSelected: isOnSelection)

            if model.renamingPath == item.fullPath {
                InlineRenameField(placeholder: item.name, text: Bindable(model).renameInput) {
                    model.submitRename(item)
                } onCancel: {
                    model.cancelRename()
                }
            } else {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(nameStyle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if item.isDirectory {
                if !isExpanded && state.isErrorFolder {
                    Circle()
                        .frame(width: 6, height: 6)
                        .rowTint(StatusTone.failure.tint)
                        .help("Contains files with errors")
                        .accessibilityLabel("Contains files with errors")
                }
            } else if let issues = state.issues {
                NavigatorIssueCountBadge(count: issues)
            }

            if let gitStatus {
                GitStatusBadge(status: gitStatus)
            }
        }
        .padding(.horizontal, isDropTargetFolder ? Spacing.compact : 0)
        .background(RowPathTagger(path: item.fullPath))
        .background(
            isDropTargetFolder
                ? RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                : nil
        )
        .overlay(
            isDropTargetFolder
                ? RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: Stroke.standard)
                : nil
        )
        .contentShape(Rectangle())
        .onDrag {
            guard model.renamingPath != item.fullPath else {
                return NSItemProvider()
            }
            model.beginDrag(for: item.fullPath)
            return NSItemProvider(object: URL(fileURLWithPath: item.fullPath) as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: FileItemDropDelegate(item: item, model: model))
        .accessibilityElement(children: .combine)
    }

    private var nameStyle: AnyShapeStyle {
        if isOnSelection {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(ThemeColor.textPrimary)
    }
}

private struct RowPathTagger: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("golens-row:" + path)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let target = "golens-row:" + path
        if nsView.identifier?.rawValue != target {
            nsView.identifier = NSUserInterfaceItemIdentifier(target)
        }
    }
}

struct FileTreeCreationView: View {
    let model: FileNavigatorModel
    let creation: FileNavigatorModel.PendingCreation

    var body: some View {
        HStack(spacing: Spacing.row) {
            FileIconView(fileName: model.creationName, isFolder: creation.isFolder, isSelected: false)

            InlineRenameField(placeholder: creation.isFolder ? "Folder Name or Path" : "File Name or Path", text: Bindable(model).creationName) {
                model.submitCreation()
            } onCancel: {
                model.cancelCreation()
            }

            Button {
                model.cancelCreation()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
        .selectionDisabled()
    }
}

struct InlineRenameField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.body)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .onAppear {
                DispatchQueue.main.async { isFocused = true }
            }
    }
}

struct NavigatorIssueCountBadge: View {
    let count: IssueCount

    var body: some View {
        let errors = count.errors > 0
        let n = errors ? count.errors : count.warnings
        HStack(spacing: Spacing.hairline) {
            Image(systemName: errors ? StatusTone.failure.symbol : StatusTone.warning.symbol)
                .symbolRenderingMode(.multicolor)
            Text("\(n)")
                .rowTint(.secondary)
        }
        .font(.caption.weight(.semibold))
        .help(errors ? "\(n) error\(n == 1 ? "" : "s")" : "\(n) warning\(n == 1 ? "" : "s")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(errors ? "\(n) error\(n == 1 ? "" : "s")" : "\(n) warning\(n == 1 ? "" : "s")")
    }
}

private struct FileItemDropDelegate: DropDelegate {
    let item: FileItem
    let model: FileNavigatorModel

    func validateDrop(info: DropInfo) -> Bool {
        guard item.isDirectory,
              model.workspace.activeDraggedTabPath == nil,
              !model.isReadOnlyFolder(item.fullPath),
              info.hasItemsConforming(to: [.fileURL]) else {
            return false
        }
        let activeSource = model.draggedItemPath ?? model.workspace.activeDraggedNavigatorPath
        return model.canMoveItem(from: activeSource, intoFolder: item.fullPath)
    }

    func dropEntered(info: DropInfo) {
        guard item.isDirectory else { return }
        model.updateDropTargetFolder(item.fullPath)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard item.isDirectory else { return DropProposal(operation: .cancel) }
        let activeSource = model.draggedItemPath ?? model.workspace.activeDraggedNavigatorPath
        guard model.canMoveItem(from: activeSource, intoFolder: item.fullPath) else {
            return DropProposal(operation: .cancel)
        }
        model.updateDropTargetFolder(item.fullPath)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropTargetFolderPath == item.fullPath {
            model.updateDropTargetFolder(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard item.isDirectory else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        return model.handleDrop(providers, into: item.fullPath)
    }
}
