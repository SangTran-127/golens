import AppKit
import SwiftUI

struct DatabasePanelView: View {
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let model = workspace.databaseUI
        if model.uiDataSources.isEmpty {
            UnifiedEmptyState.empty(
                symbol: DatabaseSymbol.dataSource,
                title: "No Data Sources",
                message: "Add a PostgreSQL, MySQL or SQLite data source to browse its schema and run SQL from .sql files.",
                actionTitle: "Data Sources…",
                action: { model.uiShowDataSources() },
                secondaryActionTitle: "Detect Data Sources in Project…",
                secondaryAction: { workspace.detectDataSourcesInProject() }
            )
        } else {
            PanelListDetail {
                SchemaOutlineView(model: model)
            } detail: {
                DatabaseResultsView(workspace: workspace, model: model)
            }
        }
    }
}

enum DatabaseErrorPresentation {
    static func isConnection(_ error: DBError) -> Bool {
        error.isConnectionFailure || error.kind == DBError.needsSecret
    }

    static func detail(_ error: DBError) -> String? {
        let detail = [error.detail, error.code].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }
}

struct DatabaseResultsView: View {
    @Bindable var workspace: WorkspaceState
    let model: any DatabaseUIModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.uiRunError {
                runErrorBanner(error)
            }
            if model.uiRunError == nil, let tab = model.uiSelectedResult {
                header(tab)
                Divider()
                DatabaseResultContent(workspace: workspace, model: model, tab: tab)
            } else if model.uiIsRunningAny {
                UnifiedEmptyState.loading(message: "Running the statement…")
            } else if model.uiRunError == nil {
                nothingRun
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var nothingRun: some View {
        let path = workspace.activeFilePath
        if EcosystemDocumentTools.isSQLFile(path), model.uiAttachedDataSource(path: path) != nil {
            UnifiedEmptyState.empty(
                symbol: DatabaseSymbol.table,
                title: "No Results",
                message: "Place the cursor in a statement and run it. Its rows appear here.",
                actionTitle: KeymapStore.shared.labeled("Run Statement", DatabaseCommandID.runStatement),
                action: { model.uiRunStatement(path: path) }
            )
        } else {
            UnifiedEmptyState.empty(
                symbol: DatabaseSymbol.table,
                title: "No Results",
                message: "Run a statement from a .sql file attached to a data source, or open a table from the schema."
            )
        }
    }

    private func runErrorBanner(_ error: DBError) -> some View {
        let title: String
        switch error.kind {
        case DBError.needsSecret: title = "Password Needed"
        case DBError.connect, DBError.auth, DBError.tls, DBError.timeout: title = "Couldn’t Connect"
        case DBError.readOnly: title = "Read-Only Data Source"
        case DBError.cancelled: title = "Statement Canceled"
        case DBError.connectionLost: title = "Connection Lost"
        default: title = "Couldn’t Run the Statement"
        }
        let tone: InlineBannerIcon = error.kind == DBError.cancelled ? .status(.inactive) : error.kind == DBError.readOnly ? .status(.warning) : .status(.failure)
        return InlineBanner(
            tone,
            title: title,
            message: error.message,
            detail: DatabaseErrorPresentation.detail(error),
            onClose: { model.uiDismissRunError() }
        ) {
            if DatabaseErrorPresentation.isConnection(error) || error.kind == DBError.readOnly, let id = model.uiRunDataSourceID {
                Button("Edit Data Source…") { model.uiEditDataSource(id: id) }
            }
        }
    }

    private func header(_ tab: DBResultTab) -> some View {
        HStack(spacing: Spacing.standard) {
            if model.uiResults.count > 1 {
                Picker("Result", selection: Binding(
                    get: { model.uiSelectedResult?.id ?? "" },
                    set: { model.uiSelectedResultID = $0 }
                )) {
                    ForEach(model.uiResults) { result in
                        Text(result.title).tag(result.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Result")
            } else if let location = tab.sourceLocation {
                Text(location.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(location.path)
            }
            DatabaseResultSummary(tab: tab)
                .layoutPriority(-1)
            Spacer(minLength: Spacing.standard)
            if let source = workspace.database.definition(tab.dataSourceID), tab.explain == nil,
               tab.table != nil || workspace.database.session(forConsole: tab.consoleID)?.hasOpenTransaction == true {
                DatabaseTransactionControls(
                    workspace: workspace,
                    source: source,
                    consoleID: { tab.consoleID },
                    knownConsoleID: tab.consoleID,
                    showsModeMenu: tab.table != nil,
                    showsState: true
                )
            }
            if tab.hasSource {
                Button {
                    workspace.jumpToLocation(path: tab.sourcePath, line: tab.sourceLine)
                } label: {
                    Image(systemName: DatabaseSymbol.goToStatement)
                }
                .buttonStyle(.borderless)
                .help("Go to Statement in \((tab.sourcePath as NSString).lastPathComponent)")
                .accessibilityLabel("Go to Statement")
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }
}

struct DatabaseResultSummary: View {
    let tab: DBResultTab

    var body: some View {
        HStack(spacing: Spacing.compact) {
            symbol
            Text(text)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .help(tab.statement.error?.message ?? text)
    }

    @ViewBuilder
    private var symbol: some View {
        let tone: StatusTone = tab.statement.error?.kind == DBError.cancelled ? .inactive : tab.statement.error != nil ? .failure : .success
        Image(systemName: tone.symbol).foregroundStyle(tone.tint)
    }

    private var text: String {
        let statement = tab.statement
        let duration = UserMessage.duration(statement.durationMs / 1000)
        if let error = statement.error {
            return (error.kind == DBError.cancelled ? "Canceled" : "Failed") + " · " + duration
        }
        if !statement.columns.isEmpty || tab.explain != nil {
            return "Finished in " + duration
        }
        return Self.affectedSummary(statement) + " · " + duration
    }

    static func affectedSummary(_ statement: DBStatementResult) -> String {
        guard let affected = statement.rowsAffected else { return "Statement Finished" }
        let rows = UserMessage.quantity(Int(affected), "row")
        switch statement.kind {
        case "insert": return "Inserted \(rows)"
        case "delete": return "Deleted \(rows)"
        case "update": return "Updated \(rows)"
        default: return "Affected \(rows)"
        }
    }
}

struct DatabaseResultContent: View {
    @Bindable var workspace: WorkspaceState
    let model: any DatabaseUIModel
    let tab: DBResultTab
    @State private var room = Room.full
    @State private var chromeHeights: [Room: CGFloat] = [:]
    @State private var contentHeight: CGFloat = 0
    @State private var gridHeight: CGFloat?
    @State private var gridObscuredHeight = DataGridMetrics.headerHeight

    private enum Room: Int, Comparable {
        case full, compactBanners, noBanners, noStatusLine, noTableBar

        static func < (a: Room, b: Room) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        let statement = tab.statement
        let font = TechnicalTypography.codeCanvasNSFont(size: workspace.editorFontSize)
        let readOnly = tab.table.flatMap(readOnlyReason)
        let compact = room >= .compactBanners
        VStack(spacing: 0) {
            if let error = statement.error {
                statementErrorBanner(error)
            }
            if room < .noBanners, let notice = tab.notice {
                noticeBanner(notice, compact: compact)
            }
            if room < .noBanners, statement.truncated {
                secondaryBanner(
                    .symbol("info.circle"),
                    title: "Showing the First \(UserMessage.quantity(Int(tab.rowsFetched), "Row"))",
                    message: "Run this statement alone to load more.",
                    compact: compact
                )
            }
            if let error = tab.fetchAllError ?? tab.sortError {
                InlineBanner(.status(.failure), title: tab.fetchAllError != nil ? "Couldn’t Load the Rows" : "Couldn’t Sort the Rows", message: error.message, detail: DatabaseErrorPresentation.detail(error))
            }
            if let table = tab.table {
                if room < .noTableBar {
                    DatabaseTableBar(workspace: workspace, tab: tab, table: table)
                    Divider()
                }
                if room < .noBanners, let readOnly {
                    secondaryBanner(.symbol(DatabaseSymbol.readOnly), title: "Read-Only Table", message: readOnly, compact: compact)
                }
            }
            if let explain = tab.explain {
                ExplainPlanView(outcome: explain)
            } else if let cache = model.uiPageCache(for: tab), let source = workspace.databaseGridSource(for: tab) {
                DataGridView(
                    source: source,
                    font: font,
                    accessibilityLabel: tab.table.map { "Rows of \($0.table)" } ?? "Results",
                    onFirstRowsShown: { cache.reportFirstRowsShown() },
                    onObscuredHeightChange: { obscured in
                        gridObscuredHeight = obscured
                        fitRoom(font: font)
                    }
                ) { cell in
                    detail(cell, cache: cache)
                        .windowScope(workspace)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    gridHeight = height
                    fitRoom(font: font)
                }
                .onDisappear { gridHeight = nil }
                if room < .noStatusLine {
                    Divider()
                    DatabaseResultStatusLine(workspace: workspace, model: model, tab: tab, cache: cache)
                }
            } else if statement.error == nil {
                if !statement.notices.isEmpty {
                    ReadOnlyCodeView(text: statement.notices.joined(separator: "\n"))
                } else {
                    UnifiedEmptyState.empty(
                        symbol: "checkmark.circle",
                        title: DatabaseResultSummary.affectedSummary(statement),
                        message: "The statement finished in \(UserMessage.duration(statement.durationMs / 1000)) and returned no rows."
                    )
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            contentHeight = height
            fitRoom(font: font)
        }
        .onChange(of: [tab.notice?.title, statement.truncated ? "truncated" : nil, readOnly]) { _, _ in
            chromeHeights = [:]
            fitRoom(font: font)
        }
        .onChange(of: tab.id) { _, _ in
            room = .full
            chromeHeights = [:]
        }
    }

    private func fitRoom(font: NSFont) {
        guard let gridHeight, contentHeight > 0 else {
            room = .full
            return
        }
        let needed = DataGridMetrics.minimumHeight(font, obscured: gridObscuredHeight)
        chromeHeights[room] = contentHeight - gridHeight
        if gridHeight < needed {
            if let next = Room(rawValue: room.rawValue + 1) { room = next }
        } else if let previous = Room(rawValue: room.rawValue - 1), contentHeight - (chromeHeights[previous] ?? 0) >= needed {
            room = previous
        }
    }

    private func secondaryBanner(_ icon: InlineBannerIcon, title: String, message: String, compact: Bool) -> some View {
        InlineBanner(icon, title: title, message: compact ? nil : message)
            .help(compact ? message : "")
    }

    @ViewBuilder
    private func detail(_ cell: DataGridCellRef, cache: ResultPageCache) -> some View {
        if let source = workspace.database.tableSources[tab.id] {
            if let loaded = source.loadedRow(cell.row) {
                CellValuePopover(cache: cache, cell: DataGridCellRef(row: loaded, column: cell.column), pending: source.session.value(row: Int64(loaded), column: cell.column))
            } else {
                CellValuePopover(cache: cache, cell: cell, pending: source.session.insertValue(cell.row, column: cell.column) ?? .text(""))
            }
        } else {
            CellValuePopover(cache: cache, cell: cell)
        }
    }

    private func readOnlyReason(_ table: DBTableBinding) -> String? {
        if !table.editable { return table.reason.isEmpty ? nil : table.reason }
        guard let source = workspace.database.definition(tab.dataSourceID), source.readOnly else { return nil }
        return "“\(source.name)” is read-only. Turn off Read-only in Edit Data Source to change rows."
    }

    private func noticeBanner(_ notice: DBResultNotice, compact: Bool) -> some View {
        let icon: InlineBannerIcon = switch notice.kind {
        case .success: .status(.success)
        case .warning: .status(.warning)
        case .info: .status(.info)
        }
        return InlineBanner(icon, title: notice.title, message: compact ? nil : notice.message, onClose: {
            workspace.database.updateResult(tab.id) { $0.notice = nil }
        }) {
            if let path = notice.revealPath, FileManager.default.fileExists(atPath: path) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .help(compact ? notice.message : "")
    }

    private func statementErrorBanner(_ error: DBError) -> some View {
        let canceled = error.kind == DBError.cancelled
        let readOnly = error.kind == DBError.readOnly
        let soft = canceled || error.kind == DBError.unsupported
        let title: String = if canceled {
            "Statement Canceled"
        } else if readOnly {
            "Read-Only Data Source"
        } else if error.kind == DBError.unsupported {
            "Not Available for This Statement"
        } else if tab.explain != nil {
            "Couldn’t Explain the Statement"
        } else {
            "Statement Failed"
        }
        return InlineBanner(
            canceled ? .status(.inactive) : (readOnly || soft) ? .status(.warning) : .status(.failure),
            title: title,
            message: error.message,
            detail: DatabaseErrorPresentation.detail(error)
        ) {
            if readOnly || DatabaseErrorPresentation.isConnection(error) {
                Button("Edit Data Source…") { model.uiEditDataSource(id: tab.dataSourceID) }
            }
            if tab.hasSource {
                Button("Go to Statement") {
                    workspace.jumpToLocation(path: tab.sourcePath, line: tab.sourceLine)
                }
            }
        }
    }
}

struct DatabaseTableBar: View {
    @Bindable var workspace: WorkspaceState
    let tab: DBResultTab
    let table: DBTableBinding
    @State private var filter = ""
    @State private var orderBy = ""

    var body: some View {
        let session = workspace.database.editSessions[tab.id]
        let changes = session?.changeCount ?? 0
        let editable = workspace.database.tableSources[tab.id]?.gridIsEditable ?? (table.editable && workspace.database.definition(tab.dataSourceID)?.readOnly != true)
        HStack(spacing: Spacing.standard) {
            Text("WHERE")
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            SQLClauseField(
                label: "Filter Rows (WHERE)",
                placeholder: "Filter, for example status = 'paid'",
                text: $filter,
                completionContext: { text, caret in completion("WHERE", text, caret) },
                onSubmit: apply
            )
            .frame(minWidth: DatabaseTableBarMetrics.filterMinWidth)
            Text("ORDER BY")
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            SQLClauseField(
                label: "Sort Rows (ORDER BY)",
                placeholder: "Column, for example created_at DESC",
                text: $orderBy,
                completionContext: { text, caret in completion("ORDER BY", text, caret) },
                onSubmit: apply
            )
            .frame(minWidth: DatabaseTableBarMetrics.orderMinWidth, maxWidth: DatabaseTableBarMetrics.orderMaxWidth)
            if filter != table.filter || orderBy != table.orderBy {
                Button("Apply") { apply() }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Load the rows again with this filter and order. Return in either field does the same.")
            }
            if editable {
                Divider().frame(height: DatabaseTableBarMetrics.dividerHeight)
                ViewThatFits(in: .horizontal) {
                    editActions(changes: changes, showsCount: true)
                    editActions(changes: changes, showsCount: false)
                }
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .onAppear(perform: sync)
        .onChange(of: tab.id) { _, _ in sync() }
    }

    private func editActions(changes: Int, showsCount: Bool) -> some View {
        HStack(spacing: Spacing.standard) {
            Button {
                workspace.addDatabaseRowFromToolbar(tab.id)
            } label: {
                Image(systemName: DatabaseSymbol.addRow)
            }
            .buttonStyle(.borderless)
            .help("Add Row")
            .accessibilityLabel("Add Row")
            if changes > 0 {
                if showsCount {
                    Text(UserMessage.count(changes, "row", "rows") + " changed")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Revert All") { workspace.revertAllDatabaseChanges(tab.id) }
                    .controlSize(.small)
                    .help("Undo every change in this table that is not submitted.")
                Button("Submit Changes") { workspace.submitDatabaseChanges() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(KeymapStore.shared.labeled("Preview the SQL for \(UserMessage.count(changes, "changed row", "changed rows")) and run it in one transaction", DatabaseCommandID.submitChanges))
            }
        }
        .fixedSize()
    }

    private func sync() {
        filter = table.filter
        orderBy = table.orderBy
    }

    private func apply() {
        workspace.reloadDatabaseTable(tab.id, filter: filter, orderBy: orderBy)
    }

    private func completion(_ clause: String, _ text: String, _ caretByte: Int) -> (request: DBCompleteRequest, prefixBytes: Int)? {
        guard let engine = workspace.database.definition(tab.dataSourceID)?.engineKind else { return nil }
        let name = table.schema.isEmpty ? engine.quoteIdentifier(table.table) : engine.quoteIdentifier(table.schema) + "." + engine.quoteIdentifier(table.table)
        let prefix = "SELECT * FROM \(name) \(clause) "
        let request = DBCompleteRequest(dataSourceId: tab.dataSourceID, dialect: engine.dialect, text: prefix + text, caretByte: prefix.utf8.count + caretByte)
        return (request, prefix.utf8.count)
    }
}

enum DatabaseTableBarMetrics {
    static let filterMinWidth: CGFloat = 160
    static let orderMinWidth: CGFloat = 120
    static let orderMaxWidth: CGFloat = 260
    static let dividerHeight: CGFloat = 16
}

struct DatabaseResultStatusLine: View {
    @Bindable var workspace: WorkspaceState
    let model: any DatabaseUIModel
    let tab: DBResultTab
    let cache: ResultPageCache

    var body: some View {
        HStack(spacing: Spacing.standard) {
            Text(UserMessage.quantity(Int(tab.rowsFetched), "row") + (tab.complete ? "" : " loaded"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if tab.isSortedLoadedRowsOnly {
                Text("Sorted loaded rows only")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help("Choose Fetch All to sort every row.")
            }
            if tab.cursorClosed && !tab.complete {
                Text("The rest was exported")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help("An export read the remaining rows straight into its file, so the grid keeps only the rows already loaded. Run the statement again to load more.")
            }
            if let table = tab.table {
                rowCount(table)
            }
            if tab.isSorting || cache.isLoadingMore {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(tab.isSorting ? "Sorting" : "Loading more rows")
            }
            Spacer(minLength: Spacing.standard)
            if let export = tab.export {
                ProgressView()
                    .controlSize(.mini)
                Text("Exporting to “\((export.path as NSString).lastPathComponent)”…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { workspace.stopDatabaseExport(tab.id) }
                    .controlSize(.small)
                    .help("Stop the export. The file keeps the rows written so far.")
            } else if tab.isFetchingAll {
                ProgressView()
                    .controlSize(.mini)
                Text("Fetching all rows…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Stop") { model.uiStopFetchAll(id: tab.id) }
                    .controlSize(.small)
                    .help("Stop reading rows. The rows already loaded stay.")
            } else {
                if tab.canFetchMore {
                    Button("Fetch All") { model.uiFetchAll(id: tab.id) }
                        .controlSize(.small)
                        .help("Read every remaining row of this result.")
                }
                Button("Export…") { workspace.presentExportResult(tab.id) }
                    .controlSize(.small)
                    .help(KeymapStore.shared.labeled("Save the rows as CSV, TSV, JSON, SQL INSERT or Markdown", DatabaseCommandID.exportResult))
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .background(ThemeColor.panelSurface)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowCount(_ table: DBTableBinding) -> some View {
        switch table.rowCount {
        case .unknown:
            Button("Count Rows") { workspace.countDatabaseTableRows(tab.id) }
                .buttonStyle(.link)
                .font(.subheadline)
                .help(table.filter.isEmpty ? "Count every row in the table." : "Count the rows that match the filter.")
        case .counting:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text("Counting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Stop") { workspace.countDatabaseTableRows(tab.id) }
                    .controlSize(.mini)
            }
        case .counted(let count):
            Text(UserMessage.quantity(Int(count), "row") + (table.filter.isEmpty ? " in the table" : " match the filter"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed(let error):
            Label("Couldn’t Count", systemImage: StatusTone.warning.symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .help(error.message)
        }
    }
}
