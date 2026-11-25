import SwiftUI

struct SQLConsoleControlsView: View {
    @Bindable var workspace: WorkspaceState
    let path: String

    var body: some View {
        let model = workspace.databaseUI
        if !model.uiDataSources.isEmpty {
            let attached = model.uiAttachedDataSource(path: path)
            let connection = model.uiConnection(path: path)
            let isRunning = model.uiIsRunning(path: path)
            HStack(spacing: Spacing.standard) {
                if let attached {
                    if attached.production {
                        Label("Production", systemImage: DatabaseSymbol.production)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StatusTone.warning.tint)
                            .help("“\(attached.name)” is marked as production. Every write asks first.")
                    } else if attached.readOnly {
                        Label("Read-Only", systemImage: DatabaseSymbol.readOnly)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .help("“\(attached.name)” is read-only. GoLens refuses statements that write.")
                    }
                    connectionStatus(connection)
                    DatabaseTransactionControls(
                        workspace: workspace,
                        source: attached,
                        consoleID: { workspace.database.consoleID(forPath: path) },
                        knownConsoleID: workspace.database.consoleIDs[path]
                    )
                }

                Menu {
                    DatabaseAttachMenuItems(workspace: workspace, path: path)
                    Divider()
                    if attached != nil {
                        Button("Query History…", systemImage: DatabaseSymbol.history) { workspace.showQueryHistory() }
                    }
                    if let attached, model.uiIsConnected(dataSourceID: attached.id) {
                        Button("Disconnect", systemImage: DatabaseSymbol.disconnect) { model.uiDisconnect(dataSourceID: attached.id) }
                    }
                    Button("Data Sources…", systemImage: DatabaseSymbol.dataSource) {
                        if let attached { model.uiEditDataSource(id: attached.id) } else { model.uiShowDataSources() }
                    }
                } label: {
                    Label(attached?.name ?? "No Data Source", systemImage: DatabaseSymbol.dataSource)
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(attached.map { "Statements in this file run on “\($0.name)” (\($0.engineTitle)). Choose another data source." } ?? "Choose the data source that runs the statements in this file")
                .accessibilityLabel("Data Source")
                .accessibilityValue(attached?.name ?? "None")

                Button {
                    if isRunning {
                        model.uiStop(path: path)
                    } else {
                        model.uiRunStatement(path: path)
                    }
                } label: {
                    Label(isRunning ? "Stop" : "Run", systemImage: isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRunning && !model.uiCanRun(path: path))
                .help(
                    isRunning
                        ? KeymapStore.shared.labeled("Stop the running statement", DatabaseCommandID.stopStatement)
                        : attached == nil
                            ? "Choose a data source first"
                            : KeymapStore.shared.labeled("Run the statement at the cursor, or the selection", DatabaseCommandID.runStatement)
                )
                .accessibilityLabel(isRunning ? "Stop Statement" : "Run Statement")
            }
        }
    }

    @ViewBuilder
    private func connectionStatus(_ connection: DatabaseUIConnection) -> some View {
        HStack(spacing: Spacing.compact) {
            switch connection {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .connected(let transaction) where transaction == "failed":
                Image(systemName: StatusTone.failure.symbol).foregroundStyle(StatusTone.failure.tint)
            case .connected(let transaction) where transaction == "active":
                Image(systemName: StatusTone.warning.symbol).foregroundStyle(StatusTone.warning.tint)
            case .connected:
                Image(systemName: StatusTone.success.symbol).foregroundStyle(StatusTone.success.tint)
            case .failed:
                Image(systemName: StatusTone.failure.symbol).foregroundStyle(StatusTone.failure.tint)
            case .notConnected:
                Image(systemName: StatusTone.inactive.symbol).foregroundStyle(StatusTone.inactive.tint)
            }
            Text(connection.title)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .help(connectionHelp(connection))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(connection.title)")
    }

    private func connectionHelp(_ connection: DatabaseUIConnection) -> String {
        if case .failed(let error) = connection, let error { return error.message }
        return connection.title
    }
}
