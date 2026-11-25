import SwiftUI
import AppKit

struct TabBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var workspace: WorkspaceState
    @State private var hoveredTab: String? = nil
    @State private var draggedTab: String? = nil
    @State private var dropTargetTab: String? = nil
    @State private var isDropTargetedOnBar: Bool = false
    @State private var lastReorderTime: CFAbsoluteTime = 0
    @State private var dragWatchdogTimer: Timer? = nil
    @State private var scrollViewportWidth: CGFloat = 0
    @State private var contentMinX: CGFloat = 0
    @State private var contentMaxX: CGFloat = 0

    private struct TabScrollBoundsPreference: PreferenceKey {
        static let defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    private var showsLeadingFade: Bool {
        contentMinX < -2
    }

    private var showsTrailingFade: Bool {
        scrollViewportWidth > 0 && contentMaxX > scrollViewportWidth + 2
    }
    
    private func revealActiveTab(_ proxy: ScrollViewProxy, animated: Bool) {
        let path = workspace.activeFilePath
        guard workspace.openFiles.contains(path) else { return }
        if animated && !reduceMotion {
            withAnimation(Motion.quick) { proxy.scrollTo(path) }
        } else {
            proxy.scrollTo(path)
        }
    }

    var body: some View {
        let isDark = workspace.systemAppearanceIsDark
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.compact) {
                    let files = workspace.openFiles
                    let nameCounts = Dictionary(files.map { (($0 as NSString).lastPathComponent, 1) }, uniquingKeysWith: +)
                    ForEach(Array(files.enumerated()), id: \.element) { index, path in
                        let fileName = (path as NSString).lastPathComponent
                        EditorTabItem(
                            workspace: workspace,
                            path: path,
                            fileName: fileName,
                            displayTitle: Self.compactTabTitle(fileName: fileName, fullPath: path, hasDuplicateName: (nameCounts[fileName] ?? 0) > 1, workspace: workspace),
                            relativePath: workspace.projectRelativePath(path),
                            isDark: isDark,
                            isActive: workspace.activeFilePath == path,
                            isHovered: hoveredTab == path,
                            isDeleted: workspace.deletedFiles.contains(path),
                            isEdited: workspace.editedFiles.contains(path),
                            isConflicted: workspace.git.conflictedPaths.contains(path),
                            isPinned: workspace.isTabPinned(path),
                            isPreview: workspace.previewTabPath == path,
                            isDraggingThis: draggedTab == path,
                            isDropTargetThis: dropTargetTab == path && draggedTab != path,
                            canCloseOthers: files.contains { $0 != path && !workspace.isTabPinned($0) },
                            canCloseRight: files[(index + 1)...].contains { !workspace.isTabPinned($0) },
                            canReveal: path.hasPrefix(workspace.activeWorkspacePath + "/"),
                            draggedTab: $draggedTab,
                            dropTargetTab: $dropTargetTab,
                            lastReorderTime: $lastReorderTime,
                            onHover: { hovered in
                                if hovered { hoveredTab = path }
                                else if hoveredTab == path { hoveredTab = nil }
                            },
                            onStartWatchdog: startDragWatchdog,
                            onClearDrag: clearDragState
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, Spacing.compact)
                .padding(.vertical, Spacing.compact)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabScrollBoundsPreference.self,
                            value: geo.frame(in: .named("tabBarScroll"))
                        )
                    }
                )
            }
            .coordinateSpace(name: "tabBarScroll")
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { scrollViewportWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in scrollViewportWidth = w }
                }
            )
            .onPreferenceChange(TabScrollBoundsPreference.self) { rect in
                contentMinX = rect.minX
                contentMaxX = rect.maxX
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [showsLeadingFade ? .clear : .black, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: Spacing.section)

                    Rectangle().fill(.black)

                    LinearGradient(
                        colors: [.black, showsTrailingFade ? .clear : .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: Spacing.section)
                }
            )
            .onAppear { revealActiveTab(proxy, animated: false) }
            .onChange(of: workspace.activeFilePath) { revealActiveTab(proxy, animated: true) }
            }
            .clipped()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onDrop(
                of: [.fileURL],
                delegate: TabBarBackgroundDropDelegate(
                    workspace: workspace,
                    isTargeted: $isDropTargetedOnBar,
                    onStartWatchdog: startDragWatchdog,
                    onClearDrag: clearDragState
                )
            )

            Divider()
                .frame(height: 14)
                .padding(.horizontal, Spacing.row)

            Menu {
                ForEach(workspace.openFiles, id: \.self) { path in
                    OpenTabMenuItem(
                        workspace: workspace,
                        path: path,
                        title: workspace.projectRelativePath(path),
                        isActive: path == workspace.activeFilePath
                    )
                    .equatable()
                }
                Divider()
                Button("Close Saved Tabs", systemImage: "checkmark.rectangle") {
                    workspace.closeSavedTabs()
                }
                Button("Close All Tabs", systemImage: "xmark.rectangle") {
                    workspace.closeTabs(workspace.openFiles.filter { !workspace.isTabPinned($0) })
                }
                Divider()
                Toggle("Preview Tab on Single-Click", systemImage: "eye", isOn: $workspace.enablePreviewTab)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open Tabs (\(workspace.openFiles.count))")
            .accessibilityLabel("Open Tabs Menu")
            .padding(.trailing, Spacing.hairline)

            Button(action: {
                workspace.isSplitMode.toggle()
                if workspace.isSplitMode {
                    workspace.secondaryFilePath = workspace.activeFilePath
                }
            }) {
                Image(systemName: "square.split.2x1")
                    .font(.callout)
                    .foregroundStyle(workspace.isSplitMode ? ThemeColor.accent : ThemeColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        workspace.isSplitMode ? ThemeColor.accent.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, Spacing.standard)
            .help(workspace.isSplitMode ? "Close Split Editor" : "Split Editor Right")
            .accessibilityLabel(workspace.isSplitMode ? "Close Split Editor" : "Split Editor Right")
        }
        .frame(height: 28)
        .background(ThemeColor.panelSurface)
        .overlay(alignment: .bottom) {
            if isDropTargetedOnBar {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isInsideBar in
            if !isInsideBar {
                hoveredTab = nil
            }
        }
        .onDisappear {
            hoveredTab = nil
            clearDragState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hoveredTab = nil
            clearDragState()
            workspace.autoSaveEditedDocumentsIfEnabled()
        }
    }

    private static func compactTabTitle(fileName: String, fullPath: String, hasDuplicateName: Bool, workspace: WorkspaceState) -> String {
        guard hasDuplicateName else { return fileName }
        let relDir = (workspace.projectRelativePath(fullPath) as NSString).deletingLastPathComponent
        guard !relDir.isEmpty else { return fileName }
        let parts = relDir.split(separator: "/").map(String.init)
        if parts.count <= 1 {
            return "\(relDir)/\(fileName)"
        }
        return "\(parts[0])/…/\(fileName)"
    }

    private func startDragWatchdog() {
        guard dragWatchdogTimer == nil else { return }
        dragWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if NSEvent.pressedMouseButtons & 1 == 0 {
                clearDragState()
                timer.invalidate()
            }
        }
    }

    private func clearDragState() {
        dragWatchdogTimer?.invalidate()
        dragWatchdogTimer = nil
        if draggedTab != nil { draggedTab = nil }
        if dropTargetTab != nil { dropTargetTab = nil }
        if isDropTargetedOnBar { isDropTargetedOnBar = false }
        workspace.activeDraggedTabPath = nil
    }
}

private struct OpenTabMenuItem: View, Equatable {
    let workspace: WorkspaceState
    let path: String
    let title: String
    let isActive: Bool

    static func == (lhs: OpenTabMenuItem, rhs: OpenTabMenuItem) -> Bool {
        lhs.workspace === rhs.workspace && lhs.path == rhs.path && lhs.title == rhs.title && lhs.isActive == rhs.isActive
    }

    var body: some View {
        Button {
            workspace.activeFilePath = path
        } label: {
            HStack {
                if isActive {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }
}

private struct EditorTabItem: View, Equatable {
    @Bindable var workspace: WorkspaceState
    let path: String
    let fileName: String
    let displayTitle: String
    let relativePath: String
    let isDark: Bool
    let isActive: Bool
    let isHovered: Bool
    let isDeleted: Bool
    let isEdited: Bool
    let isConflicted: Bool
    let isPinned: Bool
    let isPreview: Bool
    let isDraggingThis: Bool
    let isDropTargetThis: Bool
    let canCloseOthers: Bool
    let canCloseRight: Bool
    let canReveal: Bool
    @Binding var draggedTab: String?
    @Binding var dropTargetTab: String?
    @Binding var lastReorderTime: CFAbsoluteTime
    let onHover: (Bool) -> Void
    let onStartWatchdog: () -> Void
    let onClearDrag: () -> Void

    static func == (lhs: EditorTabItem, rhs: EditorTabItem) -> Bool {
        lhs.workspace === rhs.workspace && lhs.path == rhs.path && lhs.fileName == rhs.fileName
            && lhs.displayTitle == rhs.displayTitle && lhs.relativePath == rhs.relativePath && lhs.isDark == rhs.isDark
            && lhs.isActive == rhs.isActive && lhs.isHovered == rhs.isHovered && lhs.isDeleted == rhs.isDeleted
            && lhs.isEdited == rhs.isEdited && lhs.isConflicted == rhs.isConflicted && lhs.isPinned == rhs.isPinned
            && lhs.isPreview == rhs.isPreview && lhs.isDraggingThis == rhs.isDraggingThis
            && lhs.isDropTargetThis == rhs.isDropTargetThis && lhs.canCloseOthers == rhs.canCloseOthers
            && lhs.canCloseRight == rhs.canCloseRight && lhs.canReveal == rhs.canReveal
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                workspace.activeFilePath = path
            } label: {
                HStack(spacing: Spacing.row) {
                    FileIconView(fileName: fileName, path: path, isSelected: false, size: 14)
                    Text(displayTitle)
                        .font(.subheadline.weight(isActive ? .medium : .regular))
                        .italic(isPreview)
                        .foregroundStyle(workspace.tabTextColor(isActive: isActive, isHovered: isHovered, isDark: isDark))
                        .strikethrough(isDeleted)
                        .lineLimit(1)
                    if isPreview {
                        Image(systemName: "eye")
                            .font(.caption2)
                            .foregroundStyle(ThemeColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    if isConflicted {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(StatusTone.failure.tint)
                            .accessibilityHidden(true)
                    }
                    if isPinned && isEdited {
                        Image(systemName: "circle.fill")
                            .font(.caption2.weight(.bold))
                            .imageScale(.small)
                            .foregroundStyle(isHovered || isActive ? ThemeColor.textPrimary : ThemeColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, Spacing.standard)
                .padding(.trailing, Spacing.compact)
                .padding(.vertical, Spacing.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    workspace.promotePreviewTab(path)
                }
            )
            .help(isDeleted ? "Deleted on disk. Save to create the file again." : isConflicted ? "\(relativePath) (Merge conflict)" : (isPreview ? "\(relativePath) (Preview — Double-click or edit to keep open)" : relativePath))
            .accessibilityLabel(displayTitle)
            .accessibilityValue([isPinned ? "Pinned" : nil, isDeleted ? "Deleted on disk" : nil, isConflicted ? "Merge conflict" : nil, isEdited ? "Edited" : nil, isPreview ? "Preview" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if isPinned {
                Button {
                    workspace.togglePinTab(path)
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .imageScale(.small)
                        .foregroundStyle(isHovered || isActive ? ThemeColor.textPrimary : ThemeColor.textSecondary)
                        .frame(width: Spacing.inset * 2, height: Spacing.inset * 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unpin Tab")
                .accessibilityLabel("Unpin \(fileName)")
                .padding(.trailing, Spacing.compact)
            } else {
                Button {
                    workspace.closeTab(path)
                } label: {
                    Image(systemName: isEdited && !isHovered ? "circle.fill" : "xmark")
                        .font(.caption2.weight(isEdited && !isHovered ? .bold : .semibold))
                        .imageScale(.small)
                        .foregroundStyle(isHovered || isActive ? ThemeColor.textPrimary : ThemeColor.textSecondary)
                        .frame(width: Spacing.inset * 2, height: Spacing.inset * 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(KeymapStore.shared.labeled("Close Tab", "file.closeTab"))
                .accessibilityLabel("Close \(fileName)")
                .accessibilityValue(isEdited ? "Edited" : "")
                .opacity(isActive || isEdited || isHovered ? 1.0 : 0.0)
                .accessibilityHidden(!(isActive || isEdited || isHovered))
                .padding(.trailing, Spacing.compact)
            }
        }
        .background(
            isDropTargetThis
                ? ThemeColor.accent.opacity(0.24)
                : workspace.tabBackgroundColor(isActive: isActive, isHovered: isHovered, isDark: isDark)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay {
            if isDropTargetThis || isDraggingThis {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(ThemeColor.accent.opacity(isDropTargetThis ? 0.9 : 0.6), lineWidth: Stroke.standard)
            } else if isActive && isPreview {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(
                        ThemeColor.accent.opacity(isDark ? 0.62 : 0.46),
                        style: StrokeStyle(lineWidth: Stroke.standard, dash: [4, 2])
                    )
            } else if isActive {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(ThemeColor.accent.opacity(isDark ? 0.58 : 0.42), lineWidth: Stroke.standard)
            } else if isPreview {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(
                        ThemeColor.textSecondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: Stroke.hairline, dash: [3, 2])
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: Stroke.hairline)
            }
        }
        .opacity(isDraggingThis ? 0.82 : 1.0)
        .onHover(perform: onHover)
        .onDrag {
            workspace.activeDraggedNavigatorPath = nil
            workspace.activeDraggedTabPath = path
            draggedTab = path
            onStartWatchdog()
            return NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
        }
        .onDrop(
            of: [.fileURL],
            delegate: TabItemDropDelegate(
                targetPath: path,
                workspace: workspace,
                draggedTab: $draggedTab,
                dropTargetTab: $dropTargetTab,
                lastReorderTime: $lastReorderTime,
                onStartWatchdog: onStartWatchdog,
                onClearDrag: onClearDrag
            )
        )
        .contextMenu { tabMenu }
    }

    @ViewBuilder
    private var tabMenu: some View {
        if isPreview {
            Button("Keep Tab Open", systemImage: "pin.circle") {
                workspace.promotePreviewTab(path)
            }
        }
        Button(isPinned ? "Unpin Tab" : "Pin Tab", systemImage: isPinned ? "pin.slash" : "pin") {
            workspace.togglePinTab(path)
        }
        Button("Open in Split Editor", systemImage: "rectangle.split.2x1") {
            workspace.openFileInSplit(path)
        }
        Button("Local History…", systemImage: "clock.arrow.circlepath") {
            workspace.presentLocalHistory(for: path)
        }
        Button("Show File History…", systemImage: "clock") {
            workspace.presentFileHistory(for: path)
        }
        Button("Open in Integrated Terminal", systemImage: "terminal") {
            workspace.openTerminal(atDirectory: path)
        }
        Divider()
        Button("Close Tab", systemImage: "xmark") { workspace.closeTab(path) }
            .disabled(isPinned)
        Button("Close Other Tabs", systemImage: "xmark.circle") {
            workspace.closeTabs(workspace.openFiles.filter { $0 != path && !workspace.isTabPinned($0) })
        }
        .disabled(!canCloseOthers)
        Button("Close Tabs to the Right", systemImage: "arrow.right.to.line") {
            let files = workspace.openFiles
            let index = files.firstIndex(of: path) ?? files.endIndex
            workspace.closeTabs(Array(files[min(index + 1, files.endIndex)...]).filter { !workspace.isTabPinned($0) })
        }
        .disabled(!canCloseRight)
        Button("Close Saved Tabs", systemImage: "checkmark.rectangle") { workspace.closeSavedTabs() }
        Divider()
        Button("Reveal in Navigator", systemImage: "sidebar.leading") { revealInNavigator() }
            .disabled(!canReveal)
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Button("Copy Relative Path", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.projectRelativePath(path), forType: .string)
        }
        Button("Copy Path:Line", systemImage: "list.number") {
            let line = path == workspace.activeFilePath ? max(1, workspace.cursorLine) : 1
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(workspace.projectRelativePath(path)):\(line)", forType: .string)
        }
        Divider()
        Toggle("Preview Tab on Single-Click", systemImage: "eye", isOn: $workspace.enablePreviewTab)
        Toggle("Auto-Save on Focus Loss", systemImage: "square.and.arrow.down", isOn: $workspace.autoSaveOnFocusLoss)
    }

    private func revealInNavigator() {
        var folder = workspace.activeWorkspacePath
        for component in URL(fileURLWithPath: path).deletingLastPathComponent().path.dropFirst(folder.count).split(separator: "/") {
            folder += "/" + component
            if !workspace.expandedFolders.contains(folder) { workspace.toggleFolder(at: folder) }
        }
        workspace.showNavigator(.files)
        workspace.activeFilePath = path
    }
}

private struct TabItemDropDelegate: DropDelegate {
    let targetPath: String
    let workspace: WorkspaceState
    @Binding var draggedTab: String?
    @Binding var dropTargetTab: String?
    @Binding var lastReorderTime: CFAbsoluteTime
    let onStartWatchdog: () -> Void
    let onClearDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onStartWatchdog()
        dropTargetTab = targetPath
        if let activeTabDrag = draggedTab ?? workspace.activeDraggedTabPath,
           activeTabDrag != targetPath {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastReorderTime >= 0.10 else { return }
            lastReorderTime = now
            if NSWorkspace.accessibilityReduceMotion {
                workspace.moveOpenTab(fromPath: activeTabDrag, toTargetPath: targetPath)
            } else {
                withAnimation(Motion.quick) {
                    workspace.moveOpenTab(fromPath: activeTabDrag, toTargetPath: targetPath)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetTab == targetPath {
            dropTargetTab = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let activeTabDrag = draggedTab ?? workspace.activeDraggedTabPath
        let activeNavDrag = workspace.activeDraggedNavigatorPath
        onClearDrag()
        workspace.activeDraggedNavigatorPath = nil

        if let activeTabDrag {
            workspace.moveOpenTab(fromPath: activeTabDrag, toTargetPath: targetPath)
            return true
        }
        if let activeNavDrag {
            workspace.openOrReorderTab(fromPath: activeNavDrag, toTargetPath: targetPath)
            return true
        }
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let sourceURL = url else { return }
            DispatchQueue.main.async {
                workspace.openOrReorderTab(fromPath: sourceURL.path, toTargetPath: targetPath)
            }
        }
        return true
    }
}

private struct TabBarBackgroundDropDelegate: DropDelegate {
    let workspace: WorkspaceState
    @Binding var isTargeted: Bool
    let onStartWatchdog: () -> Void
    let onClearDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onStartWatchdog()
        isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let activeTabDrag = workspace.activeDraggedTabPath
        let activeNavDrag = workspace.activeDraggedNavigatorPath
        onClearDrag()
        workspace.activeDraggedNavigatorPath = nil

        if let activeTabDrag {
            workspace.openOrReorderTab(fromPath: activeTabDrag, toTargetPath: nil)
            return true
        }
        if let activeNavDrag {
            workspace.openOrReorderTab(fromPath: activeNavDrag, toTargetPath: nil)
            return true
        }
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let sourceURL = url else { return }
            DispatchQueue.main.async {
                workspace.openOrReorderTab(fromPath: sourceURL.path, toTargetPath: nil)
            }
        }
        return true
    }
}
