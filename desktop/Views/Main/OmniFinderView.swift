import AppKit
import SwiftUI

struct WorkspaceSymbolDTO: Codable, Identifiable, Equatable, Hashable {
    var name: String
    var kind: String
    var receiver: String?
    var signature: String
    var package: String
    var file: String
    var relPath: String
    var line: Int
    var col: Int
    var score: Int

    var id: String {
        "\(file):\(line):\(col):\(kind):\(receiver ?? ""):\(name)"
    }

    init(
        name: String,
        kind: String,
        receiver: String? = nil,
        signature: String = "",
        package: String = "",
        file: String = "",
        relPath: String = "",
        line: Int = 1,
        col: Int = 1,
        score: Int = 0
    ) {
        self.name = name
        self.kind = kind
        self.receiver = receiver
        self.signature = signature
        self.package = package
        self.file = file
        self.relPath = relPath
        self.line = line
        self.col = col
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case name
        case kind
        case receiver
        case signature
        case package
        case file
        case relPath
        case line
        case col
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "func"
        self.receiver = try container.decodeIfPresent(String.self, forKey: .receiver)
        self.signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
        self.package = try container.decodeIfPresent(String.self, forKey: .package) ?? ""
        self.file = try container.decodeIfPresent(String.self, forKey: .file) ?? ""
        self.relPath = try container.decodeIfPresent(String.self, forKey: .relPath) ?? ""
        self.line = try container.decodeIfPresent(Int.self, forKey: .line) ?? 1
        self.col = try container.decodeIfPresent(Int.self, forKey: .col) ?? 1
        self.score = try container.decodeIfPresent(Int.self, forKey: .score) ?? 0
    }

    var displayName: String {
        if let recv = receiver, !recv.isEmpty {
            if recv.hasPrefix("*") {
                return "(\(recv)).\(name)"
            }
            return "\(recv).\(name)"
        }
        return name
    }

    var iconName: String {
        switch kind {
        case "func":
            return "f.circle"
        case "method":
            return "m.circle"
        case "struct":
            return "s.square"
        case "interface":
            return "i.square"
        case "type":
            return "t.square"
        case "const":
            return "c.square"
        case "var":
            return "v.square"
        default:
            return "e.square"
        }
    }
}

enum OmniFinderScope: String, CaseIterable, Identifiable {
    case filesAndSymbols
    case commands
    case fileSymbols

    var id: String { rawValue }

    var pillTitle: String {
        switch self {
        case .filesAndSymbols: "Files & Symbols"
        case .commands: "> Commands"
        case .fileSymbols: "@ File Symbols"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .filesAndSymbols: "Files and Workspace Symbols"
        case .commands: "Commands"
        case .fileSymbols: "Symbols in Active File"
        }
    }
}

struct OmniFinderView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let initialPopup: WorkspaceState.Popup

    @State private var scope: OmniFinderScope
    @State private var preferWorkspaceSymbols: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var candidates: [FuzzyPathMatcher.Candidate] = []
    @State private var fileResults: [String] = []
    @State private var workspaceSymbols: [WorkspaceSymbolDTO] = []
    @State private var bookmarkResults: [BookmarkItem] = []
    @State private var todoResults: [WorkspaceTodoItem] = []
    @State private var measuredContentHeight: CGFloat = 0
    @State private var searchGeneration = 0
    @State private var keyMonitor: Any?
    @State private var invokingEditor: EditorCaretAnchor
    @FocusState private var isFieldFocused: Bool

    private static let fileLimit = 40
    private static let symbolLimit = 60
    private static let bookmarkLimit = 8
    private static let todoLimit = 10
    private static let maxResultsHeight: CGFloat = 380
    private static let emptyStateHeight: CGFloat = 120

    private enum UnifiedEntry {
        case file(String)
        case workspaceSymbol(WorkspaceSymbolDTO)
        case bookmark(BookmarkItem)
        case todo(WorkspaceTodoItem)
        case command(PaletteCommand)
        case documentSymbol(DocumentSymbol, String)

        var scrollID: String {
            switch self {
            case .file(let rel):
                return "file:\(rel)"
            case .workspaceSymbol(let sym):
                return "wsym:\(sym.id)"
            case .bookmark(let bm):
                return "bm:\(bm.id)"
            case .todo(let todo):
                return "todo:\(todo.id)"
            case .command(let cmd):
                return "cmd:\(cmd.id):\(cmd.title)"
            case .documentSymbol(let sym, let path):
                return "dsym:\(path):\(sym.range.start.line):\(sym.range.start.character)"
            }
        }
    }

    init(workspace: WorkspaceState, initialPopup: WorkspaceState.Popup) {
        self.workspace = workspace
        _invokingEditor = State(initialValue: EditorCaretAnchor.current(in: workspace))
        self.initialPopup = initialPopup
        switch initialPopup {
        case .commandPalette:
            _scope = State(initialValue: .commands)
            _preferWorkspaceSymbols = State(initialValue: false)
        case .goToSymbol:
            _scope = State(initialValue: .fileSymbols)
            _preferWorkspaceSymbols = State(initialValue: false)
        case .workspaceSymbol:
            _scope = State(initialValue: .filesAndSymbols)
            _preferWorkspaceSymbols = State(initialValue: true)
        default:
            _scope = State(initialValue: .filesAndSymbols)
            _preferWorkspaceSymbols = State(initialValue: false)
        }
    }

    private var windowWidth: CGFloat {
        workspace.mainWindow?.frame.width ?? NSApp.keyWindow?.frame.width ?? 1200
    }

    private var parsedQuery: (text: String, line: Int?) {
        guard scope == .filesAndSymbols else { return (query, nil) }
        if let colon = query.lastIndex(of: ":"),
           let line = Int(query[query.index(after: colon)...]),
           line > 0 {
            return (String(query[..<colon]), line)
        }
        return (query, nil)
    }

    private var filteredCommands: [PaletteCommand] {
        let all = CommandPaletteView.buildCommands(
            workspace: workspace,
            invokingEditor: invokingEditor,
            openWindow: openWindow
        )
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return all.filter(\.isFeatured) + all.filter { !$0.isFeatured }
        }
        let q = FuzzyPathMatcher.query(trimmed)
        var scored: [(score: Int, index: Int, cmd: PaletteCommand)] = []
        scored.reserveCapacity(all.count)
        for (idx, cmd) in all.enumerated() {
            if cmd.title.caseInsensitiveCompare(trimmed) == .orderedSame {
                scored.append((10_000, idx, cmd))
            } else if cmd.title.lowercased().hasPrefix(trimmed.lowercased()) {
                scored.append((6_000, idx, cmd))
            } else if cmd.title.localizedCaseInsensitiveContains(trimmed) {
                let fuzzy = FuzzyPathMatcher.score(q, FuzzyPathMatcher.Candidate(cmd.title)) ?? 0
                scored.append((3_000 + fuzzy, idx, cmd))
            } else if cmd.alias.localizedCaseInsensitiveContains(trimmed) ||
                        cmd.category.localizedCaseInsensitiveContains(trimmed) ||
                        (!cmd.shortcut.isEmpty && cmd.shortcut.localizedCaseInsensitiveContains(trimmed)) {
                scored.append((1_500, idx, cmd))
            } else if let fuzzy = FuzzyPathMatcher.score(q, FuzzyPathMatcher.Candidate(cmd.title)) {
                scored.append((fuzzy, idx, cmd))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        return scored.map(\.cmd)
    }

    private var filteredDocumentSymbols: [(symbol: DocumentSymbol, path: String)] {
        let flat = flattenDocumentSymbols(workspace.activeDocumentSymbols, prefix: "")
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return flat }
        let lower = trimmed.lowercased()
        let matching = flat.enumerated().compactMap { idx, entry -> (rank: Int, idx: Int, entry: (DocumentSymbol, String))? in
            let nameLower = entry.0.name.lowercased()
            let pathLower = entry.1.lowercased()
            if nameLower == lower {
                return (0, idx, entry)
            }
            if nameLower.hasPrefix(lower) {
                return (1, idx, entry)
            }
            if nameLower.contains(lower) {
                return (2, idx, entry)
            }
            if pathLower.contains(lower) {
                return (3, idx, entry)
            }
            return nil
        }
        return matching
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return a.idx < b.idx
            }
            .map(\.entry)
    }

    private var symbolsRankAheadOfFiles: Bool {
        guard !workspaceSymbols.isEmpty else { return false }
        let trimmed = parsedQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsedQuery.line != nil || trimmed.contains("/") {
            return false
        }
        if preferWorkspaceSymbols {
            return true
        }
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let hasStrongFileMatch = fileResults.prefix(3).contains { rel in
            let base = (rel as NSString).lastPathComponent.lowercased()
            let stem = (base as NSString).deletingPathExtension
            return base == lower || stem == lower || base.hasPrefix(lower)
        }
        return !hasStrongFileMatch
    }

    private var entries: [UnifiedEntry] {
        switch scope {
        case .filesAndSymbols:
            let fileEntries = fileResults.map(UnifiedEntry.file)
            let symbolEntries = workspaceSymbols.map(UnifiedEntry.workspaceSymbol)
            let bmEntries = bookmarkResults.map(UnifiedEntry.bookmark)
            let tdEntries = todoResults.map(UnifiedEntry.todo)
            if symbolsRankAheadOfFiles {
                return symbolEntries + fileEntries + bmEntries + tdEntries
            }
            return fileEntries + symbolEntries + bmEntries + tdEntries
        case .commands:
            return filteredCommands.map(UnifiedEntry.command)
        case .fileSymbols:
            return filteredDocumentSymbols.map { UnifiedEntry.documentSymbol($0.symbol, $0.path) }
        }
    }

    private var placeholderText: String {
        switch scope {
        case .commands:
            return "Type a command…"
        case .fileSymbols:
            return "Go to symbol in file…"
        case .filesAndSymbols:
            return preferWorkspaceSymbols
                ? "Search workspace symbols or files…"
                : "Search files, symbols, > commands, or @ file symbols…"
        }
    }

    private var activeSectionHeaderCount: Int {
        guard scope == .filesAndSymbols else { return 0 }
        var sections = 0
        if !fileResults.isEmpty { sections += 1 }
        if !workspaceSymbols.isEmpty { sections += 1 }
        if !bookmarkResults.isEmpty { sections += 1 }
        if !todoResults.isEmpty { sections += 1 }
        return sections
    }

    private var computedListHeight: CGFloat {
        let count = entries.count
        guard count > 0 else { return Self.emptyStateHeight }
        let estimated = CGFloat(count) * 52 + CGFloat(activeSectionHeaderCount) * 28 + Spacing.standard * 2
        let candidate = measuredContentHeight > 0 ? measuredContentHeight : estimated
        return min(Self.maxResultsHeight, max(76, candidate))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            scopeBar
            Divider()

            let currentEntries = entries
            if currentEntries.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.emptyStateHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        resultsContent
                            .padding(Spacing.standard)
                            .onGeometryChange(for: CGFloat.self) { geo in
                                geo.size.height
                            } action: { newHeight in
                                measuredContentHeight = newHeight
                            }
                    }
                    .frame(height: computedListHeight)
                    .onChange(of: selectedIndex) { _, newValue in
                        guard !PopupMouseTracker.isHoverSelecting else { return }
                        let list = entries
                        guard list.indices.contains(newValue) else { return }
                        let targetID = list[newValue].scrollID
                        withAnimation(reduceMotion ? nil : Motion.quick) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
        }
        .omniFinderWidth(in: windowWidth)
        .floatingPanelBackground()
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            invokingEditor = EditorCaretAnchor.current(in: workspace)
            DispatchQueue.main.async { isFieldFocused = true }
            selectedIndex = 0
            loadProjectFiles()
            if scope == .fileSymbols {
                workspace.fetchDocumentSymbols()
            }
            refreshFilesAndSymbols()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event) ? nil : event
            }
        }
        .onChange(of: workspace.activePopup) { _, newPopup in
            guard let newPopup else { return }
            applyPopupMode(newPopup)
        }
        .onDisappear {
            searchGeneration &+= 1
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.standard) {
            switch scope {
            case .filesAndSymbols:
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ThemeColor.textSecondary)
                    .accessibilityHidden(true)
            case .commands:
                Text(">")
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(ThemeColor.accent)
                    .padding(.horizontal, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)
                    .wellBackground(cornerRadius: CornerRadius.small)
                    .accessibilityHidden(true)
            case .fileSymbols:
                Text("@")
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(ThemeColor.accent)
                    .padding(.horizontal, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)
                    .wellBackground(cornerRadius: CornerRadius.small)
                    .accessibilityHidden(true)
            }

            TextField(placeholderText, text: $query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .background(PopupFieldAutoFocus())
                .font(.callout)
                .accessibilityLabel(scope.accessibilityTitle)
                .onChange(of: query) { _, newValue in
                    handleQueryChange(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    isFieldFocused = true
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
    }

    private var scopeBar: some View {
        HStack(spacing: Spacing.row) {
            ForEach(OmniFinderScope.allCases) { targetScope in
                let isSelected = scope == targetScope
                Button {
                    switchScope(to: targetScope)
                } label: {
                    Text(targetScope.pillTitle)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? ThemeColor.accent : ThemeColor.textSecondary)
                        .padding(.horizontal, Spacing.standard)
                        .padding(.vertical, Spacing.hairline)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .fill(isSelected ? ThemeColor.tintFill(ThemeColor.accent) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .strokeBorder(
                                    isSelected ? ThemeColor.accent.opacity(0.35) : ThemeColor.wellStroke,
                                    lineWidth: Stroke.hairline
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(targetScope.accessibilityTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            Spacer(minLength: Spacing.standard)

            if scope == .filesAndSymbols || scope == .fileSymbols {
                Text("⌥↩ Split")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ThemeColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.bottom, Spacing.standard)
    }

    @ViewBuilder
    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            switch scope {
            case .filesAndSymbols:
                if symbolsRankAheadOfFiles {
                    workspaceSymbolsSection(baseOffset: 0)
                    filesSection(baseOffset: workspaceSymbols.count)
                } else {
                    filesSection(baseOffset: 0)
                    workspaceSymbolsSection(baseOffset: fileResults.count)
                }
                bookmarksSection(baseOffset: fileResults.count + workspaceSymbols.count)
                todosSection(baseOffset: fileResults.count + workspaceSymbols.count + bookmarkResults.count)
            case .commands:
                ForEach(Array(filteredCommands.enumerated()), id: \.offset) { index, cmd in
                    commandItemView(cmd, index: index)
                }
            case .fileSymbols:
                ForEach(Array(filteredDocumentSymbols.enumerated()), id: \.offset) { index, entry in
                    documentSymbolItemView(entry.symbol, path: entry.path, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private func filesSection(baseOffset: Int) -> some View {
        if !fileResults.isEmpty {
            sectionTitleView(parsedQuery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recent Files" : "Files")
            ForEach(Array(fileResults.enumerated()), id: \.element) { offset, rel in
                fileItemView(rel, index: baseOffset + offset)
            }
        }
    }

    @ViewBuilder
    private func workspaceSymbolsSection(baseOffset: Int) -> some View {
        if !workspaceSymbols.isEmpty {
            sectionTitleView("Workspace Symbols")
            ForEach(Array(workspaceSymbols.enumerated()), id: \.element.id) { offset, sym in
                workspaceSymbolItemView(sym, index: baseOffset + offset)
            }
        }
    }

    @ViewBuilder
    private func bookmarksSection(baseOffset: Int) -> some View {
        if !bookmarkResults.isEmpty {
            sectionTitleView("Bookmarks")
            ForEach(Array(bookmarkResults.enumerated()), id: \.element.id) { offset, bm in
                bookmarkItemView(bm, index: baseOffset + offset)
            }
        }
    }

    @ViewBuilder
    private func todosSection(baseOffset: Int) -> some View {
        if !todoResults.isEmpty {
            sectionTitleView("TODOs & FIXMEs")
            ForEach(Array(todoResults.enumerated()), id: \.element.id) { offset, todo in
                todoItemView(todo, index: baseOffset + offset)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.row) {
            Image(systemName: emptyStateSymbol)
                .font(.title3)
                .foregroundStyle(ThemeColor.textSecondary)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(ThemeColor.textSecondary)
        }
        .padding(Spacing.section)
    }

    private var emptyStateSymbol: String {
        switch scope {
        case .filesAndSymbols: "magnifyingglass"
        case .commands: "command"
        case .fileSymbols: "curlybraces.square"
        }
    }

    private var emptyStateTitle: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch scope {
        case .filesAndSymbols:
            return trimmed.isEmpty ? "No files or Go symbols in workspace" : "No matching files or symbols"
        case .commands:
            return "No matching commands"
        case .fileSymbols:
            return trimmed.isEmpty ? "No symbols in active file" : "No matching symbols in file"
        }
    }

    private func sectionTitleView(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ThemeColor.textSecondary)
            .padding(.horizontal, Spacing.comfortable)
            .padding(.top, Spacing.row)
            .padding(.bottom, Spacing.hairline)
    }

    private func fileItemView(_ relativePath: String, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let name = (relativePath as NSString).lastPathComponent
        let folder = (relativePath as NSString).deletingLastPathComponent
        return navigableRow(index: index, scrollID: "file:\(relativePath)", supportsSplit: true) {
            FileIconView(fileName: name, path: absolutePath(relativePath), isSelected: isSelected, size: 16)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(name)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func workspaceSymbolItemView(_ item: WorkspaceSymbolDTO, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let locationLabel = "\(item.relPath.isEmpty ? relativePath(item.file) : item.relPath):\(item.line)"
        return navigableRow(index: index, scrollID: "wsym:\(item.id)", supportsSplit: true) {
            SymbolIconView(kind: item.kind, isSelected: isSelected, size: 16)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.row) {
                    Text(item.displayName)
                        .font(.body.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                        .lineLimit(1)
                    if !item.package.isEmpty {
                        Text(item.package)
                            .font(.caption.weight(.medium).monospaced())
                            .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor))
                            )
                    }
                }
                HStack(spacing: Spacing.row) {
                    if !item.signature.isEmpty {
                        Text(item.signature)
                            .font(.caption.monospaced())
                            .foregroundStyle(isSelected ? selectedText.opacity(0.82) : ThemeColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(locationLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func bookmarkItemView(_ bm: BookmarkItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let place = "\(relativePath(bm.path)):\(bm.line)"
        return navigableRow(index: index, scrollID: "bm:\(bm.id)", supportsSplit: true) {
            Image(systemName: "bookmark.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? selectedText : ThemeColor.accent)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(bm.preview)
                    .font(.callout.weight(isSelected ? .medium : .regular).monospaced())
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                Text(place)
                    .font(.caption)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func todoItemView(_ todo: WorkspaceTodoItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let place = "\(relativePath(todo.path)):\(todo.line)"
        let tint = (todo.tag == .fixme || todo.tag == .hack) ? StatusTone.warning.tint : ThemeColor.accent
        return navigableRow(index: index, scrollID: "todo:\(todo.id)", supportsSplit: true) {
            Image(systemName: todo.tag.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? selectedText : tint)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(todo.text)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                Text(place)
                    .font(.caption)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func commandItemView(_ cmd: PaletteCommand, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(spacing: Spacing.standard) {
            Group {
                if let icon = cmd.icon, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
            .foregroundStyle(isSelected ? selectedText : ThemeColor.textSecondary)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(cmd.title)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                if !cmd.category.isEmpty {
                    Text(cmd.category)
                        .font(.caption)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.82) : ThemeColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.standard)

            if !cmd.shortcut.isEmpty {
                Text(cmd.shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textSecondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .fill(isSelected ? selectedText.opacity(0.16) : Color(nsColor: .quaternarySystemFill))
                    )
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            executeSelected(inSplit: false)
        }
        .id("cmd:\(cmd.id):\(cmd.title)")
    }

    private func documentSymbolItemView(_ symbol: DocumentSymbol, path: String, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let scrollID = "dsym:\(path):\(symbol.range.start.line):\(symbol.range.start.character)"
        return navigableRow(index: index, scrollID: scrollID, supportsSplit: true) {
            SymbolIconView(lspKind: symbol.kind, isSelected: isSelected, size: 16)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(symbol.name)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Spacing.row) {
                    if !path.isEmpty && path != symbol.name {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                            .lineLimit(1)
                    }
                    Text("Line \(symbol.range.start.line + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? selectedText.opacity(0.82) : ThemeColor.textSecondary)
                }
            }
        }
    }

    private func navigableRow<RowContent: View>(
        index: Int,
        scrollID: String,
        supportsSplit: Bool,
        @ViewBuilder content: () -> RowContent
    ) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(spacing: Spacing.standard) {
            content()
            Spacer(minLength: 0)
            if supportsSplit && isSelected {
                Button {
                    selectedIndex = index
                    executeSelected(inSplit: true)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedText.opacity(0.85))
                        .padding(Spacing.compact)
                }
                .buttonStyle(.plain)
                .help("Open in Split Editor")
                .accessibilityLabel("Open in Split Editor")
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            executeSelected(inSplit: false)
        }
        .id(scrollID)
    }

    private func applyPopupMode(_ popup: WorkspaceState.Popup) {
        switch popup {
        case .openQuickly:
            preferWorkspaceSymbols = false
            switchScope(to: .filesAndSymbols, resetQuery: true)
        case .workspaceSymbol:
            preferWorkspaceSymbols = true
            switchScope(to: .filesAndSymbols, resetQuery: true)
        case .commandPalette:
            preferWorkspaceSymbols = false
            switchScope(to: .commands, resetQuery: true)
        case .goToSymbol:
            preferWorkspaceSymbols = false
            switchScope(to: .fileSymbols, resetQuery: true)
        default:
            break
        }
    }

    private func switchScope(to newScope: OmniFinderScope, resetQuery: Bool = false) {
        PopupMouseTracker.markKeyboardOrOpen()
        scope = newScope
        if resetQuery {
            query = ""
        }
        selectedIndex = 0
        measuredContentHeight = 0
        if newScope == .fileSymbols {
            workspace.fetchDocumentSymbols()
        } else if newScope == .filesAndSymbols {
            refreshFilesAndSymbols()
        }
        DispatchQueue.main.async { isFieldFocused = true }
    }

    private func handleQueryChange(_ newValue: String) {
        PopupMouseTracker.markKeyboardOrOpen()
        if scope == .filesAndSymbols {
            if newValue.hasPrefix(">") {
                let stripped = String(newValue.dropFirst()).drop(while: { $0 == " " })
                scope = .commands
                query = String(stripped)
                selectedIndex = 0
                measuredContentHeight = 0
                return
            }
            if newValue.hasPrefix("@") {
                let stripped = String(newValue.dropFirst()).drop(while: { $0 == " " })
                scope = .fileSymbols
                workspace.fetchDocumentSymbols()
                query = String(stripped)
                selectedIndex = 0
                measuredContentHeight = 0
                return
            }
            refreshFilesAndSymbols()
        } else {
            selectedIndex = 0
            measuredContentHeight = 0
        }
    }

    private func absolutePath(_ relative: String) -> String {
        (workspace.activeWorkspacePath as NSString).appendingPathComponent(relative)
    }

    private func relativePath(_ path: String) -> String {
        workspace.projectRelativePath(path)
    }

    private func loadProjectFiles() {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return }
        let treePaths = workspace.allWorkspaceRelativeFilePaths()
        DispatchQueue.global(qos: .userInitiated).async {
            let json: String? = root.withCString { r in
                guard let c = ListProjectFiles(r) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            var paths = json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            if !treePaths.isEmpty {
                var seen = Set(paths)
                for p in treePaths where seen.insert(p).inserted {
                    paths.append(p)
                }
            }
            let list = paths.map(FuzzyPathMatcher.Candidate.init)
            DispatchQueue.main.async {
                candidates = list
                if scope == .filesAndSymbols {
                    refreshFilesAndSymbols(keepSymbols: true)
                }
            }
        }
    }

    private func refreshFilesAndSymbols(keepSymbols: Bool = false) {
        selectedIndex = 0
        measuredContentHeight = 0
        let text = parsedQuery.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            let root = workspace.activeWorkspacePath + "/"
            fileResults = workspace.recentFiles
                .filter { $0.hasPrefix(root) }
                .prefix(Self.fileLimit)
                .map(relativePath)
            bookmarkResults = Array(workspace.bookmarks.prefix(5))
            todoResults = []
        } else {
            fileResults = FuzzyPathMatcher.rank(text, candidates, limit: Self.fileLimit)
            bookmarkResults = rankBookmarks(query: trimmed)
            todoResults = rankTodos(query: trimmed)
        }

        guard !keepSymbols else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        let root = workspace.activeWorkspacePath

        if parsedQuery.line != nil || trimmed.contains("/") || root.isEmpty {
            workspaceSymbols = []
            return
        }
        if trimmed.isEmpty && !preferWorkspaceSymbols {
            workspaceSymbols = []
            return
        }

        let symbolQuery = trimmed
        let limit = Self.symbolLimit
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.fetchWorkspaceSymbols(workspacePath: root, query: symbolQuery, limit: limit)
            DispatchQueue.main.async {
                guard generation == searchGeneration else { return }
                workspaceSymbols = items
                selectedIndex = 0
            }
        }
    }

    private nonisolated static func fetchWorkspaceSymbols(
        workspacePath: String,
        query: String,
        limit: Int
    ) -> [WorkspaceSymbolDTO] {
        guard !workspacePath.isEmpty else { return [] }
        let jsonStr: String? = workspacePath.withCString { cWs in
            query.withCString { cQuery in
                guard let ptr = SearchGoWorkspaceSymbols(cWs, cQuery, Int32(limit)) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
        }
        guard let jsonStr,
              let items = try? JSONDecoder().decode([WorkspaceSymbolDTO].self, from: Data(jsonStr.utf8)) else {
            return []
        }
        return items
    }

    private func rankBookmarks(query trimmed: String) -> [BookmarkItem] {
        guard !workspace.bookmarks.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let matchesAll = "bookmarks".hasPrefix(lower)
        let filtered = workspace.bookmarks.filter { bm in
            if matchesAll { return true }
            let rel = relativePath(bm.path)
            return bm.preview.localizedCaseInsensitiveContains(trimmed) ||
                rel.localizedCaseInsensitiveContains(trimmed)
        }
        return Array(filtered.prefix(Self.bookmarkLimit))
    }

    private func rankTodos(query trimmed: String) -> [WorkspaceTodoItem] {
        guard !trimmed.isEmpty, !workspace.workspaceTodos.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let matchesAllTodos = lower == "todo" || lower == "todos" || lower == "fixme" || lower == "hack"
        let filtered = workspace.workspaceTodos.filter { todo in
            if matchesAllTodos && todo.tag.rawValue.lowercased().hasPrefix(lower.replacingOccurrences(of: "s", with: "")) {
                return true
            }
            let rel = relativePath(todo.path)
            return todo.text.localizedCaseInsensitiveContains(trimmed) ||
                rel.localizedCaseInsensitiveContains(trimmed)
        }
        return Array(filtered.prefix(Self.todoLimit))
    }

    private func flattenDocumentSymbols(_ symbols: [DocumentSymbol], prefix: String) -> [(DocumentSymbol, String)] {
        var result: [(DocumentSymbol, String)] = []
        for symbol in symbols {
            let path = prefix.isEmpty ? symbol.name : prefix + " › " + symbol.name
            result.append((symbol, path))
            result.append(contentsOf: flattenDocumentSymbols(symbol.children ?? [], prefix: path))
        }
        return result
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let popup = workspace.activePopup,
              popup == .openQuickly || popup == .workspaceSymbol || popup == .commandPalette || popup == .goToSymbol else {
            return false
        }

        let count = entries.count
        switch event.keyCode {
        case 53:
            workspace.activePopup = nil
            return true
        case 36, 76:
            executeSelected(inSplit: event.modifierFlags.contains(.option))
            return true
        case 48:
            let allScopes = OmniFinderScope.allCases
            if let currentIdx = allScopes.firstIndex(of: scope) {
                let step = event.modifierFlags.contains(.shift) ? -1 : 1
                let nextIdx = (currentIdx + step + allScopes.count) % allScopes.count
                switchScope(to: allScopes[nextIdx])
            }
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
            if PopupSearchKeyCapture.routeIfFieldUnfocused(event, query: &query, onFocus: { isFieldFocused = true }) {
                return true
            }
            return false
        }
    }

    private func executeSelected(inSplit: Bool) {
        let list = entries
        guard list.indices.contains(selectedIndex) else { return }

        switch list[selectedIndex] {
        case .file(let relative):
            let fullPath = absolutePath(relative)
            let line = parsedQuery.line
            workspace.activePopup = nil
            openLocation(path: fullPath, line: line, column: 1, inSplit: inSplit)

        case .workspaceSymbol(let item):
            workspace.activePopup = nil
            guard !item.file.isEmpty else { return }
            if inSplit {
                workspace.openFileInSplit(item.file, line: max(1, item.line), column: max(1, item.col))
            } else {
                workspace.selectWorkspaceSymbol(item)
            }

        case .bookmark(let bm):
            workspace.activePopup = nil
            openLocation(path: bm.path, line: bm.line, column: 1, inSplit: inSplit)

        case .todo(let todo):
            workspace.activePopup = nil
            openLocation(path: todo.path, line: todo.line, column: todo.column, inSplit: inSplit)

        case .command(let cmd):
            cmd.action()

        case .documentSymbol(let symbol, _):
            let line = symbol.range.start.line + 1
            let col = symbol.range.start.character + 1
            let path = workspace.activeFilePath
            workspace.activePopup = nil
            if inSplit, !path.isEmpty {
                workspace.openFileInSplit(path, line: line, column: col)
            } else if let tv = workspace.activeTextView as? GoLensTextView {
                tv.jumpTo(path: path, line: line, col: col)
            } else if !path.isEmpty {
                workspace.jumpTo(filePath: path, line: line, column: col)
            }
        }
    }

    private func openLocation(path: String, line: Int?, column: Int, inSplit: Bool) {
        if inSplit {
            workspace.openFileInSplit(path, line: line, column: column)
        } else if let line {
            workspace.jumpTo(filePath: path, line: line, column: column)
        } else {
            workspace.openFile(path)
        }
    }
}
