import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var workspace: WorkspaceState

    var body: some View {
        let _ = measureStartupOnce("sidebar-body")
        VStack(spacing: 0) {
            if !workspace.activeWorkspacePath.isEmpty {
                HStack(spacing: Spacing.hairline) {
                    ForEach(WorkspaceState.Navigator.allCases, id: \.self) { navigator in
                        TabButton(
                            title: navigator.title,
                            helpText: KeymapStore.shared.labeled(navigator.title, navigator.keymapID),
                            icon: navigator.symbol,
                            isSelected: workspace.selectedSidebarTab == navigator
                        ) {
                            workspace.selectedSidebarTab = navigator
                        }
                    }
                }
                .padding(Spacing.hairline)
                .modifier(NavigatorTabCluster())
                .padding(.horizontal, Spacing.standard)
                .padding(.top, Spacing.row)
                .padding(.bottom, Spacing.row)
            }

            if workspace.activeWorkspacePath.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "folder",
                    title: "No Workspace",
                    message: "Open a Go project folder to browse files, search, and run tests."
                )
            } else {
                SidebarNavigatorHost(workspace: workspace, selectedTab: workspace.selectedSidebarTab)
            }
        }
        .frame(minWidth: WindowLayout.sidebarMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarNavigatorHost: NSViewRepresentable {
    let workspace: WorkspaceState
    let selectedTab: WorkspaceState.Navigator

    func makeNSView(context: Context) -> SidebarNavigatorContainerView {
        let view = SidebarNavigatorContainerView(workspace: workspace)
        view.selectTab(selectedTab)
        return view
    }

    func updateNSView(_ nsView: SidebarNavigatorContainerView, context: Context) {
        nsView.selectTab(selectedTab)
    }
}

private final class SidebarNavigatorContainerView: NSView {
    private let workspace: WorkspaceState
    private var tabViews: [WorkspaceState.Navigator: NSView] = [:]
    private var currentTab: WorkspaceState.Navigator?
    private var prewarmScheduled = false

    init(workspace: WorkspaceState, frame frameRect: NSRect = .zero) {
        self.workspace = workspace
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectTab(_ tab: WorkspaceState.Navigator) {
        let targetView = view(for: tab)
        if currentTab != tab {
            currentTab = tab
            for (nav, v) in tabViews {
                let isSelected = (nav == tab)
                if v.isHidden == isSelected {
                    v.isHidden = !isSelected
                }
            }
            if subviews.last !== targetView {
                addSubview(targetView)
                targetView.frame = bounds
            }
        }
        if !prewarmScheduled {
            prewarmScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.window != nil else { return }
                if self.tabViews[.tests] == nil {
                    let testsView = self.view(for: .tests)
                    if self.currentTab != .tests {
                        testsView.isHidden = true
                        if let active = self.currentTab, let activeView = self.tabViews[active] {
                            self.addSubview(activeView)
                        }
                    }
                }
            }
        }
    }

    override func layout() {
        super.layout()
        for v in subviews where v.frame != bounds {
            v.frame = bounds
        }
    }

    private func view(for tab: WorkspaceState.Navigator) -> NSView {
        if let existing = tabViews[tab] {
            return existing
        }
        let hosted: NSView
        switch tab {
        case .files:
            hosted = host(FileNavigatorView(workspace: workspace))
        case .git:
            hosted = host(SourceControlSidebarView(workspace: workspace))
        case .search:
            hosted = host(ProjectSearchView(workspace: workspace))
        case .issues:
            hosted = host(IssuesNavigatorView(workspace: workspace))
        case .tests:
            hosted = host(TestSidebarView(workspace: workspace))
        }
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.autoresizingMask = [.width, .height]
        hosted.frame = bounds
        hosted.isHidden = (tab != currentTab && currentTab != nil)
        tabViews[tab] = hosted
        addSubview(hosted)
        return hosted
    }

    private func host<Content: View>(_ content: Content) -> NSView {
        let hosting = NSHostingView(rootView: content.windowScope(workspace))
        hosting.sizingOptions = []
        return hosting
    }
}

struct ProjectSearchView: View {
    @Bindable var workspace: WorkspaceState
    @AppStorage("GoLensShowProjectReplace") private var showReplace = false
    @State private var replacement = ""
    @State private var searchFocusTrigger = 0
    @State private var selectedMatchKey: String? = nil
    @State private var collapsedFilePaths: Set<String> = []

    init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    private struct FlatMatchRef {
        let key: String
        let filePath: String
        let match: SearchMatch
    }

    private static func matchKey(filePath: String, matchID: UUID) -> String {
        "\(filePath)::\(matchID.uuidString)"
    }

    private var flatMatches: [FlatMatchRef] {
        var list: [FlatMatchRef] = []
        for fileResult in workspace.projectSearchResults where !collapsedFilePaths.contains(fileResult.filePath) {
            for match in fileResult.matches {
                list.append(FlatMatchRef(
                    key: Self.matchKey(filePath: fileResult.filePath, matchID: match.id),
                    filePath: fileResult.filePath,
                    match: match
                ))
            }
        }
        return list
    }

    var body: some View {
        let trimmedQuery = workspace.projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleMatches = flatMatches

        VStack(spacing: Spacing.standard) {
            HStack(spacing: Spacing.compact) {
                Button {
                    showReplace.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(TechnicalTypography.badgeMicro)
                        .rotationEffect(.degrees(showReplace ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ChromeColor.textSecondary)
                .help(showReplace ? "Hide Replace" : "Show Replace")
                .accessibilityLabel(showReplace ? "Hide Replace" : "Show Replace")

                PanelFilterBar(
                    placeholder: "Search in project…",
                    text: $workspace.projectSearchQuery,
                    accessibilityTitle: "Search in Project",
                    focusTrigger: searchFocusTrigger,
                    onSubmit: {
                        if let key = selectedMatchKey,
                           let chosen = visibleMatches.first(where: { $0.key == key }),
                           !workspace.isProjectSearching {
                            openMatch(chosen)
                        } else {
                            workspace.performProjectSearch(query: workspace.projectSearchQuery)
                        }
                    },
                    onMoveSelection: { delta in
                        moveSelection(by: delta, in: visibleMatches)
                    }
                ) {
                    HStack(spacing: Spacing.hairline) {
                        ProjectSearchOptionToggle(title: "Match Case", glyph: Text("Aa"), isOn: $workspace.projectSearchCaseSensitive)
                        ProjectSearchOptionToggle(title: "Whole Words", glyph: Text("W"), isOn: $workspace.projectSearchWholeWord)
                        ProjectSearchOptionToggle(title: "Regular Expression", glyph: Text(".*"), isOn: $workspace.projectSearchRegex)
                    }
                }
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.top, Spacing.row)

            PanelFilterBar(
                placeholder: "Files to include/exclude (e.g. *.go, !*_test.go)",
                text: $workspace.projectSearchFileFilter,
                leadingSymbol: "line.3.horizontal.decrease.circle",
                accessibilityTitle: "Filter Search Files",
                onSubmit: {
                    workspace.performProjectSearch(query: workspace.projectSearchQuery)
                },
                onMoveSelection: { delta in
                    moveSelection(by: delta, in: visibleMatches)
                }
            )
            .padding(.horizontal, Spacing.comfortable)

            if showReplace {
                HStack(spacing: Spacing.row) {
                    PanelFilterBar(
                        placeholder: "Replace with…",
                        text: $replacement,
                        leadingSymbol: "arrow.left.arrow.right",
                        accessibilityTitle: "Replace With",
                        onSubmit: confirmReplaceAll
                    )

                    Button("Replace All", action: confirmReplaceAll)
                        .controlSize(.small)
                        .disabled(workspace.projectSearchResults.isEmpty || workspace.isProjectSearching)
                        .help("Replace every match listed below")

                    Button("Open in Multi-Buffer") {
                        workspace.openMultiBufferFromProjectSearch()
                    }
                    .controlSize(.small)
                    .disabled(workspace.projectSearchResults.isEmpty || workspace.isProjectSearching)
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                    .help("Open all search results in the editable multi-buffer editor")
                }
                .padding(.horizontal, Spacing.comfortable)
            }

            Divider()

            if workspace.isProjectSearching {
                UnifiedEmptyState.loading(message: "Searching workspace…")
            } else if trimmedQuery.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "magnifyingglass",
                    title: "Search in Project",
                    message: "Find text or regular expressions across every file in your workspace."
                )
            } else if workspace.projectSearchResults.isEmpty {
                let hasFileFilter = !workspace.projectSearchFileFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasFileFilter {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Matches") {
                        workspace.projectSearchFileFilter = ""
                        workspace.performProjectSearch(query: workspace.projectSearchQuery)
                    }
                } else {
                    UnifiedEmptyState.empty(
                        symbol: "magnifyingglass",
                        title: "No Matches",
                        message: "No occurrences of “\(trimmedQuery)” were found in this workspace."
                    )
                }
            } else {
                let totalMatches = workspace.projectSearchTotalMatches
                let totalFiles = workspace.projectSearchResults.count
                HStack {
                    Text("\(totalMatches) \(totalMatches == 1 ? "result" : "results") in \(totalFiles) \(totalFiles == 1 ? "file" : "files")")
                        .font(.caption)
                        .foregroundStyle(ChromeColor.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.comfortable)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.compact) {
                            ForEach(workspace.projectSearchResults) { fileResult in
                                FileSearchResultRow(
                                    fileResult: fileResult,
                                    isExpanded: !collapsedFilePaths.contains(fileResult.filePath),
                                    selectedMatchKey: selectedMatchKey,
                                    onToggleExpanded: {
                                        if collapsedFilePaths.contains(fileResult.filePath) {
                                            collapsedFilePaths.remove(fileResult.filePath)
                                        } else {
                                            collapsedFilePaths.insert(fileResult.filePath)
                                        }
                                    },
                                    onSelectMatch: { match in
                                        let key = Self.matchKey(filePath: fileResult.filePath, matchID: match.id)
                                        selectedMatchKey = key
                                        workspace.openFile(fileResult.filePath)
                                        workspace.pendingJumpToRange = match.range
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, Spacing.compact)
                        .padding(.bottom, Spacing.standard)
                    }
                    .onChange(of: selectedMatchKey) { _, key in
                        guard let key else { return }
                        withAnimation(Motion.quick) {
                            proxy.scrollTo(key, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onKeyPress(.upArrow) {
            guard !visibleMatches.isEmpty else { return .ignored }
            moveSelection(by: -1, in: visibleMatches)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !visibleMatches.isEmpty else { return .ignored }
            moveSelection(by: 1, in: visibleMatches)
            return .handled
        }
        .onKeyPress(.return) {
            guard let key = selectedMatchKey,
                  let chosen = visibleMatches.first(where: { $0.key == key }) else {
                return .ignored
            }
            openMatch(chosen)
            return .handled
        }
        .onAppear {
            if workspace.selectedSidebarTab == .search {
                searchFocusTrigger &+= 1
            }
        }
        .onChange(of: workspace.selectedSidebarTab) { _, newTab in
            if newTab == .search {
                searchFocusTrigger &+= 1
            }
        }
        .onChange(of: workspace.projectSearchResults) { _, _ in
            let currentKeys = Set(flatMatches.map(\.key))
            if let existing = selectedMatchKey, currentKeys.contains(existing) {
                return
            }
            selectedMatchKey = flatMatches.first?.key
        }
    }

    private func moveSelection(by delta: Int, in list: [FlatMatchRef]) {
        guard !list.isEmpty else { return }
        if let current = selectedMatchKey,
           let idx = list.firstIndex(where: { $0.key == current }) {
            let next = min(max(0, idx + delta), list.count - 1)
            selectedMatchKey = list[next].key
        } else {
            selectedMatchKey = delta >= 0 ? list.first?.key : list.last?.key
        }
    }

    private func openMatch(_ entry: FlatMatchRef) {
        workspace.openFile(entry.filePath)
        workspace.pendingJumpToRange = entry.match.range
    }

    private func confirmReplaceAll() {
        let matches = workspace.projectSearchTotalMatches
        let files = workspace.projectSearchResults.count
        guard matches > 0, !workspace.isProjectSearching else { return }
        let alert = NSAlert()
        alert.messageText = "Replace \(matches == 1 ? "1 match" : "\(matches) matches") in \(files == 1 ? "1 file" : "\(files) files") with “\(replacement)”?"
        alert.informativeText = "Open files change in the editor and stay unsaved. Other files are saved right away."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        workspace.present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            let result = workspace.replaceAllInProject(with: replacement)
            guard result.skipped > 0 || !result.failed.isEmpty else { return }
            let report = NSAlert()
            report.messageText = "Replaced \(result.replaced) of \(matches) matches."
            var lines: [String] = []
            if result.skipped > 0 { lines.append("\(result.skipped) changed since the search and were left as they are.") }
            if !result.failed.isEmpty { lines.append("Couldn’t write: \(result.failed.joined(separator: ", ")).") }
            report.informativeText = lines.joined(separator: " ")
            workspace.present(report) { _ in }
        }
    }
}

private struct ProjectSearchOptionToggle: View {
    let title: String
    let glyph: Text
    @Binding var isOn: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        Button { isOn.toggle() } label: {
            glyph
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(isOn ? Color(nsColor: .alternateSelectedControlTextColor) : ThemeColor.textSecondary)
                .frame(minWidth: 18, minHeight: 16)
                .background(
                    isOn ? ThemeColor.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct FileSearchResultRow: View {
    let fileResult: FileSearchMatches
    var isExpanded: Bool = true
    var selectedMatchKey: String? = nil
    var onToggleExpanded: () -> Void = {}
    var onSelectMatch: (SearchMatch) -> Void = { _ in }
    @Environment(\.windowWorkspace) private var workspace
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headerForegroundColor: Color {
        ThemeColor.textPrimary
    }

    private func rowBackground(isHovered: Bool) -> Color {
        isHovered ? ThemeColor.hover : Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            HStack(spacing: Spacing.compact) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChromeColor.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)

                    let resultFileName = (fileResult.filePath as NSString).lastPathComponent
                    FileIconView(fileName: resultFileName, path: fileResult.filePath, isSelected: false, size: 14)

                    Text(resultFileName)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(headerForegroundColor)

                    Text(fileResult.relativePath)
                        .font(.caption)
                        .foregroundStyle(ChromeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .contentShape(Rectangle())
                .rowButton {
                    withAnimation(reduceMotion ? nil : Motion.quick) {
                        onToggleExpanded()
                    }
                }
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isHovered {
                    Button {
                        workspace.dismissProjectSearchFile(fileResult.filePath)
                    } label: {
                        Image(systemName: "xmark")
                            .font(TechnicalTypography.badgeMicro)
                            .foregroundStyle(ChromeColor.textSecondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss file from search results")
                    .accessibilityLabel("Dismiss file from search results")
                }
            }
            .padding(.vertical, Spacing.compact)
            .padding(.horizontal, Spacing.row)
            .background(rowBackground(isHovered: isHovered), in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fileResult.matches) { match in
                        let key = "\(fileResult.filePath)::\(match.id.uuidString)"
                        MatchLineView(
                            match: match,
                            filePath: fileResult.filePath,
                            isSelected: selectedMatchKey == key,
                            onSelect: { onSelectMatch(match) }
                        )
                        .id(key)
                    }
                }
                .padding(.leading, Spacing.section)
            }
        }
    }
}

struct MatchLineView: View {
    let match: SearchMatch
    let filePath: String
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.windowWorkspace) private var workspace
    @State private var isHovered = false
    @State private var trimmedContent = ""

    private var lineNumberColor: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : ThemeColor.textSecondary
    }

    private var contentColor: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ThemeColor.textPrimary
    }

    private func rowBackground(isHovered: Bool) -> Color {
        if isSelected {
            return ThemeColor.selection
        }
        return isHovered ? ThemeColor.hover : Color.clear
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.compact) {
            HStack(alignment: .top, spacing: Spacing.row) {
                Text("\(match.lineNumber):")
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(lineNumberColor)
                    .frame(minWidth: 22, alignment: .trailing)

                Text(trimmedContent)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(contentColor)
                    .lineLimit(1)

                Spacer()
            }
            .contentShape(Rectangle())
            .rowButton {
                if let onSelect {
                    onSelect()
                } else {
                    workspace.openFile(filePath)
                    workspace.pendingJumpToRange = match.range
                }
            }

            if isHovered {
                Button {
                    workspace.dismissProjectSearchMatch(filePath: filePath, matchID: match.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(TechnicalTypography.badgeMicro)
                        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ChromeColor.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss match from search results")
                .accessibilityLabel("Dismiss match from search results")
            }
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.compact)
        .background(rowBackground(isHovered: isHovered), in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear {
            if trimmedContent.isEmpty {
                trimmedContent = match.lineContent.trimmingCharacters(in: .whitespaces)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct NavigatorTabCluster: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }
}

struct TabButton: View {
    let title: String
    var helpText: String? = nil
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let idleColor: Color = isEnabled ? ChromeColor.textSecondary : ChromeColor.textTertiary
        let hoverColor: Color = ChromeColor.textPrimary
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : (isHovered && isEnabled ? hoverColor : idleColor))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if isSelected {
                        Capsule().fill(ChromeColor.selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
