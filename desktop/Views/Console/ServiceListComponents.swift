import AppKit
import SwiftUI

struct ServiceStatus: Equatable {
    var tone: StatusTone?
    var text: String
    var isBusy = false

    static func busy(_ text: String) -> ServiceStatus { ServiceStatus(tone: nil, text: text, isBusy: true) }
}

struct ServiceStatusSymbol: View {
    let status: ServiceStatus?
    let fallbackSymbol: String

    var body: some View {
        Group {
            if status?.isBusy == true {
                ProgressView()
                    .controlSize(.mini)
            } else if let tone = status?.tone {
                Image(systemName: tone.symbol)
                    .rowTint(tone.tint)
            } else {
                Image(systemName: fallbackSymbol)
                    .rowTint(ChromeColor.textSecondary)
            }
        }
        .frame(width: Spacing.section)
        .accessibilityHidden(true)
    }
}

struct ServiceSectionHeader<SelectionMenu: View, Actions: View>: View {
    let symbol: String
    let title: String
    let status: ServiceStatus
    var help: String = ""
    @ViewBuilder var selectionMenu: () -> SelectionMenu
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Spacing.row) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.row) {
                    ServiceStatusSymbol(status: status, fallbackSymbol: symbol)
                    Text(status.text)
                        .foregroundStyle(ChromeColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                ServiceStatusSymbol(status: status, fallbackSymbol: symbol)
                    .help(status.text)
            }
            Spacer(minLength: Spacing.compact)
            selectionMenu()
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(title) Actions")
            .accessibilityLabel("\(title) Actions")
        }
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.text)")
    }
}

extension ServiceSectionHeader where SelectionMenu == EmptyView {
    init(symbol: String, title: String, status: ServiceStatus, help: String = "", @ViewBuilder actions: @escaping () -> Actions) {
        self.init(symbol: symbol, title: title, status: status, help: help, selectionMenu: { EmptyView() }, actions: actions)
    }
}

struct ServiceRowAction: Identifiable {
    let title: String
    let symbol: String
    var help: String = ""
    var isEnabled = true
    let perform: () -> Void

    var id: String { title + "|" + symbol + "|" + (isEnabled ? "1" : "0") + "|" + help }
}

struct ServiceResourceRow: View, Equatable {
    let symbol: String
    let title: String
    var detail: String = ""
    var status: ServiceStatus?
    var actions: [ServiceRowAction] = []
    var accessibilityTitle: String?

    @State private var isHovering = false

    static func == (lhs: ServiceResourceRow, rhs: ServiceResourceRow) -> Bool {
        lhs.symbol == rhs.symbol && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.status == rhs.status
            && lhs.actions.map(\.id) == rhs.actions.map(\.id) && lhs.accessibilityTitle == rhs.accessibilityTitle
    }

    private var secondary: String {
        [status?.text ?? "", detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Spacing.row) {
            ServiceStatusSymbol(status: status, fallbackSymbol: symbol)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !secondary.isEmpty {
                Text(secondary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isHovering {
                ForEach(actions.prefix(2)) { action in
                    Button(action: action.perform) {
                        Image(systemName: action.symbol)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!action.isEnabled)
                    .help(action.help.isEmpty ? action.title : action.help)
                    .accessibilityLabel(action.title)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(secondary.isEmpty ? title : "\(title) · \(secondary)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([accessibilityTitle ?? title, status?.text ?? "", detail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityActions {
            ForEach(actions.prefix(2).filter(\.isEnabled)) { action in
                Button(action.title, action: action.perform)
            }
        }
    }
}

struct ServiceDetailRow: Identifiable, Equatable {
    let label: String
    let value: String
    var isMonospaced = false
    var isMasked = false
    var copyTitle: String?
    var openURL: URL?
    var openTitle = "Open in Browser"
    var tone: StatusTone?

    var id: String { label + "\u{1F}" + value }
}

struct ServiceDetailGroup: Identifiable, Equatable {
    let title: String
    var rows: [ServiceDetailRow]
    var emptyText = "None"
    var startsCollapsed = false

    var id: String { title }
}

struct ServiceDetailsView: View {
    let groups: [ServiceDetailGroup]

    @State private var revealed: Set<String> = []
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                ForEach(groups) { group in
                    if group.startsCollapsed {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedGroups.contains(group.id) },
                            set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } }
                        )) {
                            rows(group)
                                .padding(.top, Spacing.compact)
                        } label: {
                            heading(group)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            heading(group)
                            rows(group)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ThemeColor.contentSurface)
    }

    private func heading(_ group: ServiceDetailGroup) -> some View {
        Text(group.startsCollapsed ? "\(group.title) (\(UserMessage.integer(group.rows.count)))" : group.title)
            .font(.headline)
            .foregroundStyle(ThemeColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(_ group: ServiceDetailGroup) -> some View {
        if group.rows.isEmpty {
            Text(group.emptyText)
                .font(.callout)
                .foregroundStyle(ThemeColor.textSecondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.comfortable, verticalSpacing: Spacing.compact) {
                ForEach(group.rows) { row in
                    GridRow {
                        label(row)
                            .gridColumnAlignment(.leading)
                        value(row, groupID: group.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func label(_ row: ServiceDetailRow) -> some View {
        let text = Text(row.label)
            .font(.callout)
            .foregroundStyle(ThemeColor.textSecondary)
            .textSelection(.enabled)
        if let tone = row.tone {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: tone.symbol)
                    .foregroundStyle(tone.tint)
                    .accessibilityHidden(true)
                text
                    .accessibilityLabel(tone == .warning ? "Warning, \(row.label)" : tone == .failure ? "Error, \(row.label)" : row.label)
            }
        } else {
            text
        }
    }

    private func value(_ row: ServiceDetailRow, groupID: String) -> some View {
        let key = groupID + "\u{1F}" + row.id
        let hidden = row.isMasked && !revealed.contains(key)
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
            Text(hidden ? "••••" : row.value)
                .font(row.isMonospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(ThemeColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(hidden ? "\(row.label), hidden value" : "\(row.label), \(row.value)")
            if row.isMasked {
                Button {
                    if hidden { revealed.insert(key) } else { revealed.remove(key) }
                } label: {
                    Image(systemName: hidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(hidden ? "Show Value" : "Hide Value")
                .accessibilityLabel(hidden ? "Show Value of \(row.label)" : "Hide Value of \(row.label)")
            }
            if let copyTitle = row.copyTitle {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copyTitle)
                .accessibilityLabel("\(copyTitle) of \(row.label)")
            }
            if let url = row.openURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: ServiceSymbol.openInBrowser)
                }
                .buttonStyle(.borderless)
                .help("\(row.openTitle) (\(url.absoluteString))")
                .accessibilityLabel("\(row.openTitle): \(row.value)")
            }
        }
    }
}

struct ServiceSelectionMenu<Items: View>: View {
    let symbol: String
    let title: String
    let value: String
    var help = ""
    var showsValue = false
    var isDisabled = false
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            if showsValue {
                Label(value, systemImage: symbol)
                    .accessibilityLabel("\(title), \(value)")
            } else {
                Label("\(title), \(value)", systemImage: symbol)
                    .labelStyle(.iconOnly)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isDisabled)
        .help(help.isEmpty ? "\(title): \(value)" : help)
    }
}

struct ServiceHeaderButton: View {
    let title: String
    let symbol: String
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(ChromeColor.textSecondary)
        }
        .buttonStyle(.borderless)
        .help(help.isEmpty ? title : help)
        .accessibilityLabel(title)
    }
}

struct ServiceMoreMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(ChromeColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions")
        .accessibilityLabel("More Actions")
    }
}

struct ServiceListNote: View {
    let text: String
    var tone: StatusTone?
    var isLoading = false

    var body: some View {
        if isLoading {
            HStack(spacing: Spacing.row) {
                ProgressView().controlSize(.mini)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let tone {
            Label {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } icon: {
                Image(systemName: tone.symbol)
                    .rowTint(tone.tint)
            }
            .help(text)
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ServiceLogsView<Banners: View>: View {
    @Bindable var window: ServicesWindowState
    let emptyMessage: String
    let onRetry: () -> Void
    @ViewBuilder var banners: () -> Banners

    private var filteredLogs: [WorkspaceState.LogMessage] {
        let query = window.logFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return window.logs }
        return window.logs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            banners()
            if let ended = window.logEndedMessage {
                InlineBanner(.status(.inactive), title: "Logs Ended", message: ended) {
                    Button("Retry", action: onRetry)
                }
            }
            PanelFilterBar(
                placeholder: "Filter logs",
                text: $window.logFilter,
                leadingSymbol: "line.3.horizontal.decrease.circle",
                accessibilityTitle: "Filter Logs"
            )
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)
            Divider()
            let messages = filteredLogs
            if window.logs.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: ServiceSymbol.logs,
                    title: "No Output Yet",
                    message: emptyMessage
                )
                .background(ThemeColor.editorSurface)
            } else if messages.isEmpty {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Log Lines") { window.logFilter = "" }
                    .background(ThemeColor.editorSurface)
            } else {
                ConsoleLogView(
                    messages: messages,
                    normalColor: CodeSurfaceTheme.nsTextPrimary,
                    background: CodeSurfaceTheme.nsBackground,
                    isDark: CodeSurfaceTheme.isDark,
                    prettyMessageIDs: $window.prettyLogIDs
                )
            }
        }
    }
}
