import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportResultSheet: View {
    @Bindable var workspace: WorkspaceState
    let request: DBExportSheetRequest
    @Environment(\.dismiss) private var dismiss

    @AppStorage("GoLensDatabaseExportFormat") private var formatName = DBExportFormat.csv.rawValue
    @State private var scope: DBExportScope = .all
    @State private var includeHeader = true
    @State private var tableName = ""
    @State private var nullText = ""
    @State private var previewText = ""
    @State private var prepared = false

    private var tab: DBResultTab? { workspace.database.result(request.tabID) }
    private var format: DBExportFormat { DBExportFormat(rawValue: formatName) ?? .csv }
    private var selectedCount: Int { workspace.selectedDatabaseRows(request.tabID).count }

    private var options: DBExportOptions {
        var options = DBExportOptions()
        if format.hasHeaderOption { options.includeHeader = includeHeader }
        if format == .sql { options.tableName = tableName.trimmingCharacters(in: .whitespacesAndNewlines) }
        if format != .json { options.nullText = nullText }
        return options
    }

    var body: some View {
        StandardSheetShell(
            title: "Export Result",
            subtitle: subtitle,
            scopeBadge: tab?.table?.table,
            size: .generator,
            primaryTitle: "Export…",
            primaryAccessibilityLabel: "Choose the Export File",
            isPrimaryDisabled: tab == nil || (scope == .selection && selectedCount == 0) || (format == .sql && tableName.trimmingCharacters(in: .whitespaces).isEmpty),
            closeTitle: "Cancel",
            onPrimary: chooseFile,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                GeneratorSection("Options") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.comfortable, verticalSpacing: Spacing.standard) {
                        GridRow {
                            Text("Format").gridColumnAlignment(.trailing)
                            Picker("Format", selection: $formatName) {
                                ForEach(DBExportFormat.allCases) { format in
                                    Text(format.title).tag(format.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        GridRow {
                            Text("Rows")
                            Picker("Rows", selection: $scope) {
                                Text("All Rows").tag(DBExportScope.all)
                                Text("Loaded Rows (\(UserMessage.integer(Int(tab?.rowsFetched ?? 0))))").tag(DBExportScope.loaded)
                                Text("Selected Rows (\(UserMessage.integer(selectedCount)))").tag(DBExportScope.selection)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        if format == .sql {
                            GridRow {
                                Text("Table Name")
                                TextField("Table Name", text: $tableName, prompt: Text("table_name"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospaced())
                            }
                        }
                        if format != .json {
                            GridRow {
                                Text("NULL As")
                                TextField("NULL As", text: $nullText, prompt: Text(format == .sql ? "NULL" : "Empty"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospaced())
                            }
                        }
                        if format.hasHeaderOption {
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                Toggle("Include column names as the first line", isOn: $includeHeader)
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                Text(scopeNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GeneratorCodePreview(
                    code: previewText,
                    placeholder: "The preview shows the first rows in the chosen format.",
                    accessibilityLabel: "Export preview",
                    path: format == .sql ? "preview.sql" : "preview.txt",
                    copyHelp: "Copy the preview to the clipboard"
                )
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: formatName) { _, _ in refreshPreview() }
        .onChange(of: includeHeader) { _, _ in refreshPreview() }
        .onChange(of: tableName) { _, _ in refreshPreview() }
        .onChange(of: nullText) { _, _ in refreshPreview() }
    }

    private var subtitle: String {
        guard let tab else { return "The result was closed." }
        let rows = UserMessage.quantity(Int(tab.rowsFetched), "row")
        return tab.complete ? "The result has \(rows)." : "\(rows) are loaded; the result has more."
    }

    private var scopeNote: String {
        switch scope {
        case .all:
            guard let tab, !tab.complete else { return "GoLens writes every row of the result." }
            return "GoLens reads the rows that are not loaded yet straight into the file. Afterward the grid keeps only the rows already loaded."
        case .loaded:
            return "GoLens writes the rows already loaded in the grid."
        case .selection:
            return selectedCount == 0 ? "Select rows in the grid first, or export all rows." : "GoLens writes the rows selected in the grid."
        }
    }

    private func prepare() {
        guard !prepared, let tab else { return }
        prepared = true
        scope = selectedCount > 1 ? .selection : .all
        if let table = tab.table {
            tableName = table.schema.isEmpty ? table.table : "\(table.schema).\(table.table)"
        } else {
            tableName = "exported_rows"
        }
        refreshPreview()
    }

    private func refreshPreview() {
        workspace.databaseExportPreview(tabID: request.tabID, format: format, options: options) { text in
            previewText = text
        }
    }

    private func chooseFile() {
        let panel = NSSavePanel()
        panel.title = "Export Result"
        panel.prompt = "Export"
        let base = tab?.table?.table ?? "result"
        panel.nameFieldStringValue = base + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let root = workspace.activeWorkspacePath
        if !root.isEmpty { panel.directoryURL = URL(fileURLWithPath: root) }
        let format = self.format
        let scope = self.scope
        let options = self.options
        let start: (URL) -> Void = { url in
            workspace.startDatabaseExport(tabID: request.tabID, format: format, scope: scope, options: options, path: url.path)
            dismiss()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
    }
}
