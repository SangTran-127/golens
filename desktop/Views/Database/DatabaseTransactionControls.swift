import SwiftUI

struct DatabaseTransactionControls: View {
    @Bindable var workspace: WorkspaceState
    let source: DBDataSourceDefinition
    let consoleID: () -> String
    let knownConsoleID: String?
    var showsModeMenu = true
    var showsState = false

    private var console: DatabaseConsoleRef {
        DatabaseConsoleRef(consoleID: consoleID(), dataSourceID: source.id, path: "")
    }

    var body: some View {
        let session = knownConsoleID.flatMap(workspace.database.session(forConsole:))
        let mode = session?.transactionMode ?? source.effectiveTransactionMode
        let isOpen = session?.hasOpenTransaction == true
        let levels = workspace.database.isolationLevels[source.id] ?? []
        HStack(spacing: Spacing.standard) {
            if isOpen && showsState {
                let tone: StatusTone = session?.transaction == "failed" ? .failure : .warning
                let state = tone == .failure ? "Transaction Failed" : "Transaction Active"
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: tone.symbol).foregroundStyle(tone.tint)
                        Text(state)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    Image(systemName: tone.symbol)
                        .foregroundStyle(tone.tint)
                        .help(state)
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state)
            }
            if isOpen {
                Button("Commit") { workspace.endDatabaseTransaction(console, commit: true) }
                    .fixedSize()
                    .help(KeymapStore.shared.labeled("Keep the changes made since the transaction began", DatabaseCommandID.commit))
                Button("Roll Back") { workspace.endDatabaseTransaction(console, commit: false) }
                    .fixedSize()
                    .help(KeymapStore.shared.labeled("Undo the changes made since the transaction began", DatabaseCommandID.rollBack))
            }
            if showsModeMenu {
                Menu {
                    Picker("Transaction Mode", selection: Binding(
                        get: { mode },
                        set: { workspace.setDatabaseTransactionMode($0, console: console) }
                    )) {
                        ForEach(DBTransactionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    if levels.count > 1 {
                        Picker("Isolation Level", selection: Binding(
                            get: { session?.isolation ?? "" },
                            set: { workspace.setDatabaseIsolation($0, console: console) }
                        )) {
                            Text("Server Default").tag("")
                            ForEach(levels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                    }
                    if isOpen {
                        Divider()
                        Text("Commit or roll back the open transaction to change these settings.")
                    }
                } label: {
                    Text(mode.title)
                }
                .menuStyle(.button)
                .fixedSize()
                .help(mode == .manual
                      ? "Manual: statements stay in a transaction until you commit or roll back. Choose Auto-Commit or an isolation level."
                      : "Auto-Commit: each statement is kept as soon as it runs. Choose Manual to commit yourself, or an isolation level.")
                .accessibilityLabel("Transaction Mode for \(source.name)")
                .accessibilityValue(mode.title)
                .task(id: source.id) {
                    workspace.loadDatabaseTransactionStatus(console)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
