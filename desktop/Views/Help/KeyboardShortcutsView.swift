import SwiftUI

struct OpenKeyboardShortcutsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts", systemImage: "keyboard") {
            openWindow(id: KeyboardShortcutsView.windowID)
        }
        .keyboardShortcut(KeymapStore.shared.shortcut("help.keyboardShortcuts"))
    }
}

struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    private static let topMenuOrder = [
        "GoLens", "File", "Edit", "View", "Find", "Navigate",
        "Editor", "Product", "Debug", "Source Control", "Tools", "Window", "Help"
    ]

    private struct MenuGroup: Identifiable {
        let menu: String
        let commands: [KeymapCommand]
        var id: String { menu }
    }

    @Bindable private var store = KeymapStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var focusTrigger = 0

    private var boundCommands: [KeymapCommand] {
        KeymapCommand.all.filter { store.keymap.chord(for: $0.id) != nil }
    }

    private var summary: String {
        let custom = boundCommands.filter { store.keymap.source(for: $0.id) == .custom }.count
        let conflicts = boundCommands.filter { !store.keymap.conflicts(for: $0.id).isEmpty }.count
        var parts = [UserMessage.count(boundCommands.count, "shortcut")]
        if custom > 0 {
            parts.append("\(custom) custom")
        }
        if conflicts > 0 {
            parts.append(UserMessage.count(conflicts, "conflict"))
        }
        return parts.joined(separator: " · ")
    }

    private var sections: [MenuGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? boundCommands : boundCommands.filter { command in
            if command.title.lowercased().contains(q) || command.menu.lowercased().contains(q) {
                return true
            }
            guard let chord = store.keymap.chord(for: command.id) else { return false }
            return chord.display.lowercased().contains(q)
                || chord.description.lowercased().contains(q)
                || chord.spoken.lowercased().contains(q)
        }
        var grouped: [String: [KeymapCommand]] = [:]
        var encounterOrder: [String] = []
        for command in filtered {
            if grouped[command.menu] == nil {
                encounterOrder.append(command.menu)
            }
            grouped[command.menu, default: []].append(command)
        }
        return encounterOrder
            .sorted { Self.menuSortRank($0, encounterOrder) < Self.menuSortRank($1, encounterOrder) }
            .map { MenuGroup(menu: $0, commands: grouped[$0] ?? []) }
    }

    private static func menuSortRank(_ menu: String, _ encounterOrder: [String]) -> (Int, Int, Int) {
        let top = menu.components(separatedBy: " ▸ ").first ?? menu
        let topIndex = topMenuOrder.firstIndex(of: top) ?? topMenuOrder.count
        return (topIndex, menu.contains(" ▸ ") ? 1 : 0, encounterOrder.firstIndex(of: menu) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("\(store.preset.title) Keymap")
                        .font(.headline)
                    Text("\(summary). Accept completions with \(store.completionAcceptKey.title).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.standard)
                Button("Customize…", action: openKeyBindingsSettings)
                    .help("Change shortcuts in Settings ▸ Key Bindings")
            }

            PanelFilterBar(
                placeholder: "Search Keyboard Shortcuts",
                text: $query,
                accessibilityTitle: "Search Keyboard Shortcuts",
                focusTrigger: focusTrigger,
                onEscapeWhenEmpty: { dismissWindow(id: Self.windowID) }
            )

            if sections.isEmpty {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Shortcuts") {
                    query = ""
                    focusTrigger &+= 1
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { group in
                        Section(group.menu) {
                            ForEach(group.commands) { command in
                                shortcutRow(command)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(SettingsMetrics.contentInset)
        .sheetFrame(SheetSize.inspector)
        .onAppear { focusTrigger &+= 1 }
        .onExitCommand {
            if query.isEmpty {
                dismissWindow(id: Self.windowID)
            } else {
                query = ""
                focusTrigger &+= 1
            }
        }
    }

    private func openKeyBindingsSettings() {
        UserDefaults.standard.set("keyBindings", forKey: "GoLensSettingsPane")
        openSettings()
    }

    @ViewBuilder
    private func shortcutRow(_ command: KeymapCommand) -> some View {
        let chord = store.keymap.chord(for: command.id)
        let conflicts = store.keymap.conflicts(for: command.id)
        HStack(spacing: Spacing.standard) {
            Text(command.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if store.keymap.source(for: command.id) == .custom {
                Text("Custom")
                    .foregroundStyle(.secondary)
            }
            if !conflicts.isEmpty {
                let names = ListFormatter.localizedString(byJoining: conflicts.map { "“\($0.title)”" })
                Image(systemName: StatusTone.warning.symbol)
                    .foregroundStyle(StatusTone.warning.tint)
                    .help("Also assigned to \(names); the first enabled one runs")
                    .accessibilityLabel("Also assigned to \(names)")
            }
            Spacer(minLength: Spacing.standard)
            if let chord {
                Text(chord.display)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(chord.spoken)
                    .accessibilityValue(chord.display)
            }
        }
    }
}
