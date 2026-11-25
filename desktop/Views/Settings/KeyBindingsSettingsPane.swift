import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyBindingsSettingsPane: View {
    @Bindable private var store = KeymapStore.shared
    @State private var query = ""
    @State private var selection = Set<KeymapCommand.ID>()
    @State private var recordingID: String?
    @State private var monitor: Any?
    @State private var hint: String?
    @State private var prompt: Prompt?
    @State private var pendingImport: PendingImport?

    private enum Prompt: Identifiable {
        case conflict(commandID: String, chord: KeyChord, others: [KeymapCommand])
        case system(chord: KeyChord, command: KeymapCommand)
        case error(String)

        var id: String {
            switch self {
            case .conflict(let id, let chord, _): "conflict \(id) \(chord)"
            case .system(let chord, _): "system \(chord)"
            case .error(let message): "error \(message)"
            }
        }
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let keymap: Keymap
        let report: KeymapImportReport
    }

    private var rows: [KeymapCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return KeymapCommand.all }
        return KeymapCommand.all.filter { c in
            c.title.lowercased().contains(q) || c.menu.lowercased().contains(q)
                || (store.keymap.chord(for: c.id).map { $0.display.lowercased().contains(q) || $0.description.contains(q) } ?? false)
        }
    }

    private var presetFooter: String {
        switch store.preset {
        case .golens: "Xcode-style shortcuts. Standard macOS shortcuts are the same in every keymap."
        case .vscode: "VS Code’s macOS shortcuts for the commands GoLens has; other commands keep their GoLens shortcut."
        case .goland: "GoLand’s macOS keymap for the commands GoLens has; other commands keep their GoLens shortcut."
        }
    }

    var body: some View {
        SettingsTablePane {
            SettingsSection(footer: presetFooter) {
                Picker("Keymap", selection: $store.preset) {
                    ForEach(KeymapPreset.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Keymap")

                Picker("Accept Completions With", selection: $store.completionAcceptKey) {
                    ForEach(CompletionAcceptKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Accept Completions With")
            }
        } search: {
            SettingsSearchField(text: $query, prompt: "Search Key Bindings")
        } table: {
            Table(rows, selection: $selection) {
                TableColumn("Command") { command in
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(command.title)
                        Text(command.menu)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .width(min: 180)

                TableColumn("Shortcut") { command in
                    shortcutCell(command)
                }
                .width(min: 104, ideal: 128, max: 160)

                TableColumn("Source") { command in
                    sourceCell(command)
                }
                .width(min: 72, ideal: 80, max: 104)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: KeymapCommand.ID.self) { ids in
                if let id = ids.first, let command = Keymap.commandsByID[id], !command.isSystem {
                    Button("Record Shortcut", systemImage: "keyboard") { startRecording(id) }
                    Button("Clear Shortcut", systemImage: "xmark.circle") { assign(nil, to: id) }
                        .disabled(store.keymap.chord(for: id) == nil)
                    Button("Reset to Preset", systemImage: "arrow.uturn.backward") { store.reset(id) }
                        .disabled(store.keymap.source(for: id) != .custom)
                }
            }
        } actions: {
            SettingsActionRow {
                Button("Import…", action: importKeymap)
                    .help("Import a VS Code keybindings.json, a GoLand keymap .xml or an exported GoLens keymap")
                Button("Export…", action: exportKeymap)
                    .help("Save the current keymap as JSON")
                if let hint {
                    SettingsFieldHelp(hint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } trailing: {
                Button("Reset All to Preset") { store.resetAll() }
                    .disabled(store.keymap.overrides.isEmpty && store.keymap.completionAcceptKeyOverride == nil)
                    .help("Remove every custom shortcut and use the \(store.preset.title) keymap")
            }
        }
        .onDisappear(perform: stopRecording)
        .alert(item: $prompt) { prompt in
            switch prompt {
            case .conflict(let id, let chord, let others):
                Alert(
                    title: Text("\(chord.display) is used by \(names(others))"),
                    message: Text("Replacing removes the shortcut from \(names(others))."),
                    primaryButton: .default(Text("Replace")) { store.assign(chord, to: id, replacing: true) },
                    secondaryButton: .cancel()
                )
            case .system(let chord, let command):
                Alert(
                    title: Text("\(chord.display) is a macOS shortcut"),
                    message: Text("It’s used for \(command.title) in every app. Choose a different shortcut."),
                    dismissButton: .default(Text("OK"))
                )
            case .error(let message):
                Alert(title: Text("Can’t Import or Export the Keymap"), message: Text(message), dismissButton: .default(Text("OK")))
            }
        }
        .sheet(item: $pendingImport) { pending in
            KeymapImportSheet(report: pending.report) {
                store.replace(with: pending.keymap)
                pendingImport = nil
            } onCancel: {
                pendingImport = nil
            }
        }
    }

    private func names(_ commands: [KeymapCommand]) -> String {
        ListFormatter.localizedString(byJoining: commands.map { "“\($0.title)”" })
    }

    @ViewBuilder
    private func shortcutCell(_ command: KeymapCommand) -> some View {
        let chord = store.keymap.chord(for: command.id)
        if command.isSystem {
            Text(chord?.display ?? "")
                .foregroundStyle(.secondary)
                .help("Standard macOS shortcut; it can’t be changed")
                .accessibilityLabel("Shortcut for \(command.title)")
                .accessibilityValue(chord?.spoken ?? "None")
        } else {
            let isRecording = recordingID == command.id
            let others = store.keymap.conflicts(for: command.id)
            HStack(spacing: Spacing.compact) {
                Button {
                    isRecording ? stopRecording() : startRecording(command.id)
                } label: {
                    Text(isRecording ? "Type Shortcut" : chord?.display ?? "None")
                        .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : chord == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isRecording ? "Press keys; Esc cancels, Delete removes the shortcut" : "Click to record a shortcut")
                .accessibilityLabel("Shortcut for \(command.title)")
                .accessibilityValue(isRecording ? "Recording" : chord?.spoken ?? "None")
                .accessibilityHint("Records a new shortcut; Escape cancels, Delete removes it")
                if !others.isEmpty {
                    Image(systemName: StatusTone.warning.symbol)
                        .foregroundStyle(StatusTone.warning.tint)
                        .help("Also assigned to \(names(others)); the first enabled one runs")
                        .accessibilityLabel("Also assigned to \(names(others))")
                }
            }
        }
    }

    @ViewBuilder
    private func sourceCell(_ command: KeymapCommand) -> some View {
        let source = store.keymap.source(for: command.id)
        HStack(spacing: Spacing.compact) {
            Text(source.rawValue)
                .foregroundStyle(source == .custom ? .primary : .secondary)
            if source == .custom {
                Button {
                    store.reset(command.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to Preset")
                .accessibilityLabel("Reset \(command.title) to Preset")
            }
        }
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recordingID = id
        hint = "Esc cancels, Delete removes the shortcut."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, for: id)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
        hint = nil
    }

    private func handle(_ event: NSEvent, for id: String) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty && event.keyCode == 53 {
            stopRecording()
            return
        }
        if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            stopRecording()
            assign(nil, to: id)
            return
        }
        guard let chord = KeyChord(event: event) else { return }
        if chord.key.count == 1 && !chord.command && !chord.control && !chord.option {
            hint = "Add ⌘, ⌥ or ⌃ to a letter or symbol key."
            return
        }
        stopRecording()
        assign(chord, to: id)
    }

    private func assign(_ chord: KeyChord?, to id: String) {
        switch store.assign(chord, to: id) {
        case .assigned:
            break
        case .system(let command):
            if let chord { prompt = .system(chord: chord, command: command) }
        case .conflict(let others):
            if let chord { prompt = .conflict(commandID: id, chord: chord, others: others) }
        }
    }

    private func importKeymap() {
        stopRecording()
        let panel = NSOpenPanel()
        panel.title = "Import Key Bindings"
        panel.message = "Choose a VS Code keybindings.json, a GoLand keymap .xml or an exported GoLens keymap."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json, .xml, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = try Self.readImport(url)
        } catch {
            prompt = .error(error.localizedDescription)
        }
    }

    static func readImport(_ url: URL) throws -> PendingImport {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Keymap.ImportError("“\(url.lastPathComponent)” isn’t a text file.")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            let (keymap, report) = try KeymapImport.goland(text)
            return PendingImport(keymap: keymap, report: report)
        }
        if Keymap.isExport(data) {
            let (keymap, skipped) = try Keymap.importJSON(data)
            var report = KeymapImportReport(source: "GoLens keymap (\(keymap.preset.title) with \(keymap.overrides.count) custom shortcuts)")
            report.notImported = skipped
            return PendingImport(keymap: keymap, report: report)
        }
        let (keymap, report) = try KeymapImport.vscode(text)
        return PendingImport(keymap: keymap, report: report)
    }

    private func exportKeymap() {
        stopRecording()
        let panel = NSSavePanel()
        panel.title = "Export Key Bindings"
        panel.nameFieldStringValue = "GoLens Keymap.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.keymap.exportJSON().write(to: url, options: .atomic)
        } catch {
            prompt = .error(error.localizedDescription)
        }
    }
}

private struct KeymapImportSheet: View {
    let report: KeymapImportReport
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Import Key Bindings")
                    .font(.headline)
                Text("\(report.source): \(report.mapped.count) mapped, \(report.removed.count) removed, \(report.notImported.count) not imported. Importing replaces the current keymap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                group("Mapped", report.mapped)
                group("Removed", report.removed)
                group("Not Imported", report.notImported)
                group("Notes", report.notes)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SettingsMetrics.contentInset)
        .sheetFrame(.keymapImport)
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
