import AppKit
import SwiftUI

struct QueryHistoryPopupView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var entries: [DBHistoryEntry] = []
    @State private var loadError: DBError?
    @State private var isLoading = true
    @State private var keyMonitor: Any?
    @State private var loadedQuery: String?
    @State private var insertWhenLoaded = false
    @FocusState private var isTextFieldFocused: Bool

    private static let maxResultsHeight: CGFloat = 380
    private static let rowEstimate: CGFloat = 48
    private static let emptyStateHeight: CGFloat = 160

    private var dataSourceID: String { workspace.database.historyDataSourceID ?? "" }
    private var dataSourceName: String { workspace.database.definition(dataSourceID)?.name ?? "Data Source" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: DatabaseSymbol.history)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ThemeColor.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search Query History of “\(dataSourceName)”", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .background(PopupFieldAutoFocus())
                    .font(.callout)
                    .accessibilityLabel("Search Query History")
                    .onSubmit(submit)
                    .onChange(of: searchText) { _, _ in
                        PopupMouseTracker.markKeyboardOrOpen()
                        selectedIndex = 0
                        load()
                    }
                if !entries.isEmpty {
                    Button {
                        workspace.clearQueryHistory(dataSourceID: dataSourceID) { load() }
                    } label: {
                        Text("Clear History…")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove every statement recorded for “\(dataSourceName)”")
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.comfortable)

            Divider()

            content
        }
        .popupWidth(.wide)
        .floatingPanelBackground()
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            DispatchQueue.main.async { isTextFieldFocused = true }
            load()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            UnifiedEmptyState.failed(title: "Couldn’t Read the Query History", message: loadError.message, onRetry: load)
                .frame(height: Self.emptyStateHeight)
        } else if entries.isEmpty {
            Group {
                if isLoading {
                    UnifiedEmptyState.loading(message: "Reading the query history…")
                } else if searchText.isEmpty {
                    UnifiedEmptyState.empty(
                        symbol: DatabaseSymbol.history,
                        title: "No Statements Yet",
                        message: "Statements you run on “\(dataSourceName)” appear here, newest first."
                    )
                } else {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Statements") { searchText = "" }
                }
            }
            .frame(height: Self.emptyStateHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, index: index)
                        }
                    }
                    .padding(Spacing.standard)
                }
                .frame(height: min(Self.maxResultsHeight, CGFloat(entries.count) * Self.rowEstimate + Spacing.section))
                .onChange(of: selectedIndex) { _, newValue in
                    guard !PopupMouseTracker.isHoverSelecting, entries.indices.contains(newValue) else { return }
                    withAnimation(reduceMotion ? nil : Motion.quick) {
                        proxy.scrollTo(entries[newValue].id, anchor: .center)
                    }
                }
            }
            Divider()
            Text("Return inserts the statement at the cursor. Command-Delete removes it from the history.")
                .font(.caption)
                .foregroundStyle(ThemeColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.section)
                .padding(.vertical, Spacing.row)
        }
    }

    private func row(_ entry: DBHistoryEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(Self.singleLine(entry.text))
                    .font(.body.monospaced().weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.detail(entry))
                    .font(.caption)
                    .foregroundStyle(isSelected ? selectedText : ThemeColor.textSecondary)
                    .lineLimit(1)
                    .help(Self.absoluteTime(entry))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            insertSelected()
        }
        .contextMenu {
            Button("Insert Statement", systemImage: "text.insert") {
                selectedIndex = index
                insertSelected()
            }
            Button("Copy Statement", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            Divider()
            Button("Remove from History", systemImage: "trash", role: .destructive) { remove(entry) }
        }
        .accessibilityLabel("\(Self.singleLine(entry.text)), \(Self.detail(entry))")
        .accessibilityAction(named: "Remove from History") { remove(entry) }
        .id(entry.id)
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private static let isoParser = ISO8601DateFormatter()

    static func date(_ entry: DBHistoryEntry) -> Date? {
        isoParser.date(from: entry.time)
    }

    static func absoluteTime(_ entry: DBHistoryEntry) -> String {
        date(entry)?.formatted(date: .abbreviated, time: .shortened) ?? entry.time
    }

    static func detail(_ entry: DBHistoryEntry) -> String {
        var parts: [String] = []
        if let date = date(entry) {
            parts.append(Date().timeIntervalSince(date) < 7 * 86_400 ? date.formatted(.relative(presentation: .named)) : date.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(UserMessage.duration(entry.durationMs / 1000))
        if let error = entry.error, !error.isEmpty {
            parts.append("Failed")
        } else if let rows = entry.rowCount {
            parts.append(UserMessage.quantity(Int(rows), "row"))
        }
        switch entry.source {
        case "table": parts.append("Table Editor")
        case "edit": parts.append("Submitted Change")
        case "explain": parts.append("Explain")
        default: break
        }
        if entry.textTruncated == true { parts.append("Shortened") }
        return parts.joined(separator: " · ")
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load() {
        let id = dataSourceID
        guard !id.isEmpty else { return }
        let requested = query
        workspace.loadQueryHistory(dataSourceID: id, query: requested) { result in
            isLoading = false
            loadError = result.error
            entries = result.entries
            loadedQuery = requested
            if selectedIndex >= entries.count { selectedIndex = max(0, entries.count - 1) }
            if insertWhenLoaded, requested == query {
                insertWhenLoaded = false
                insertSelected()
            }
        }
    }

    private func submit() {
        if loadedQuery == query {
            insertSelected()
        } else {
            insertWhenLoaded = true
        }
    }

    private func remove(_ entry: DBHistoryEntry) {
        workspace.deleteQueryHistoryEntry(entry.id, dataSourceID: dataSourceID) { load() }
    }

    private func insertSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        workspace.insertHistoryStatement(entries[selectedIndex].text, dataSourceID: dataSourceID)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.activePopup == .queryHistory else { return false }
        let count = entries.count
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            workspace.activePopup = nil
            return true
        case 36, 76:
            submit()
            return true
        case 125:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 { selectedIndex = (selectedIndex + 1) % count }
            return true
        case 126:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 { selectedIndex = (selectedIndex - 1 + count) % count }
            return true
        case 51 where modifiers.contains(.command), 117 where searchText.isEmpty, 51 where searchText.isEmpty:
            guard entries.indices.contains(selectedIndex) else { return false }
            remove(entries[selectedIndex])
            return true
        default:
            return PopupSearchKeyCapture.routeIfFieldUnfocused(event, query: &searchText, onFocus: { isTextFieldFocused = true })
        }
    }
}
