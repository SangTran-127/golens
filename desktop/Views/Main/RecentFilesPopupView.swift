import SwiftUI
import AppKit

struct RecentFilesPopupView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var measuredHeight: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool
    @State private var keyMonitor: Any?

    private static let maxResultsHeight: CGFloat = 380
    private static let emptyStateHeight: CGFloat = 120

    private struct ContentHeightPreference: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private enum RecentEntry {
        case file(String)
        case project(String)

        var scrollID: String {
            switch self {
            case .file(let path): "rfile:\(path)"
            case .project(let path): "rproj:\(path)"
            }
        }
    }

    private var workspaceScopedFiles: [String] {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let inWorkspace = workspace.recentFiles.filter { $0.hasPrefix(prefix) }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return inWorkspace }
        return inWorkspace.filter { path in
            let rel = workspace.projectRelativePath(path)
            return (path as NSString).lastPathComponent.localizedCaseInsensitiveContains(trimmed) ||
                rel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var otherRecentProjects: [String] {
        let others = workspace.recentProjects.filter { $0 != workspace.activeWorkspacePath }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(others.prefix(5)) }
        return others.filter { path in
            workspace.recentProjectTitle(path).localizedCaseInsensitiveContains(trimmed) ||
                path.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var entries: [RecentEntry] {
        workspaceScopedFiles.map(RecentEntry.file) + otherRecentProjects.map(RecentEntry.project)
    }

    private var listHeight: CGFloat {
        let count = entries.count
        guard count > 0 else { return Self.emptyStateHeight }
        let estimated = CGFloat(count) * 44 + Spacing.section
        let candidate = measuredHeight > 0 ? measuredHeight : estimated
        return min(Self.maxResultsHeight, max(52, candidate))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "clock")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ThemeColor.textSecondary)
                    .accessibilityHidden(true)

                TextField("Search Recent Files", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .background(PopupFieldAutoFocus())
                    .font(.callout)
                    .onChange(of: searchText) { _, _ in
                        PopupMouseTracker.markKeyboardOrOpen()
                        selectedIndex = 0
                        measuredHeight = 0
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isTextFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(ThemeColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.comfortable)

            Divider()

            if entries.isEmpty {
                VStack(spacing: Spacing.row) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(workspace.activeWorkspacePath.isEmpty
                         ? "No project open"
                         : "No recent files in this workspace")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(ThemeColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.emptyStateHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            if !workspaceScopedFiles.isEmpty {
                                Text("Recent in Workspace")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ThemeColor.textSecondary)
                                    .padding(.horizontal, Spacing.comfortable)
                                    .padding(.top, Spacing.row)
                                    .padding(.bottom, Spacing.hairline)

                                ForEach(Array(workspaceScopedFiles.enumerated()), id: \.element) { index, path in
                                    recentFileItem(path: path, index: index)
                                }
                            }

                            if !otherRecentProjects.isEmpty {
                                if !workspaceScopedFiles.isEmpty {
                                    Divider()
                                        .padding(.vertical, Spacing.compact)
                                }
                                Text("Switch Recent Project")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ThemeColor.textSecondary)
                                    .padding(.horizontal, Spacing.comfortable)
                                    .padding(.top, Spacing.row)
                                    .padding(.bottom, Spacing.hairline)

                                ForEach(Array(otherRecentProjects.enumerated()), id: \.element) { offset, projectPath in
                                    recentProjectItem(path: projectPath, index: workspaceScopedFiles.count + offset)
                                }
                            }
                        }
                        .padding(Spacing.standard)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: ContentHeightPreference.self, value: geo.size.height)
                            }
                        )
                    }
                    .frame(height: listHeight)
                    .onPreferenceChange(ContentHeightPreference.self) { height in
                        measuredHeight = height
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        guard !PopupMouseTracker.isHoverSelecting else { return }
                        let list = entries
                        guard list.indices.contains(newValue) else { return }
                        withAnimation(reduceMotion ? nil : Motion.quick) {
                            proxy.scrollTo(list[newValue].scrollID, anchor: .center)
                        }
                    }
                }
            }
        }
        .popupWidth(.standard)
        .floatingPanelBackground()
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            DispatchQueue.main.async { isTextFieldFocused = true }
            selectedIndex = 0
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                if handleKeyDown(event) {
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func recentFileItem(path: String, index: Int) -> some View {
        let fileName = (path as NSString).lastPathComponent
        let relFolder = (workspace.projectRelativePath(path) as NSString).deletingLastPathComponent
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)

        return HStack(spacing: Spacing.standard) {
            FileIconView(fileName: fileName, path: path, isSelected: isSelected, size: 16)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(fileName)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)

                if !relFolder.isEmpty {
                    Text(relFolder)
                        .font(.caption)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            openSelected(inSplit: false)
        }
        .id("rfile:\(path)")
    }

    private func recentProjectItem(path: String, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let title = workspace.recentProjectTitle(path)
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath

        return HStack(spacing: Spacing.standard) {
            Image(systemName: "folder")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? selectedText : ThemeColor.accent)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(title)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)

                Text(abbreviated)
                    .font(.caption)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            openSelected(inSplit: false)
        }
        .id("rproj:\(path)")
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.showRecentFilesPopup else { return false }
        let count = entries.count

        switch event.keyCode {
        case 53:
            workspace.showRecentFilesPopup = false
            return true
        case 36, 76:
            openSelected(inSplit: event.modifierFlags.contains(.option))
            return true
        case 125:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 {
                selectedIndex = (selectedIndex + 1) % count
            }
            return true
        case 126:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 {
                selectedIndex = (selectedIndex - 1 + count) % count
            }
            return true
        default:
            if PopupSearchKeyCapture.routeIfFieldUnfocused(event, query: &searchText, onFocus: { isTextFieldFocused = true }) {
                return true
            }
            return false
        }
    }

    private func openSelected(inSplit: Bool) {
        let list = entries
        guard list.indices.contains(selectedIndex) else {
            workspace.showRecentFilesPopup = false
            return
        }
        workspace.showRecentFilesPopup = false
        switch list[selectedIndex] {
        case .file(let path):
            if inSplit {
                workspace.openFileInSplit(path)
            } else {
                workspace.openFile(path)
            }
        case .project(let projectPath):
            workspace.openRecentProject(path: projectPath)
        }
    }
}
