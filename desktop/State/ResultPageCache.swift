import AppKit
import Foundation
import GoLensFoundation
import Observation

@Observable
final class ResultPageCache: DataGridSource {
    static let maxPages = 8
    static let prefetchMargin = 200
    static let viewerMaxBytes: Int32 = 65_536
    static let copyMaxBytes: Int32 = 16 << 20
    static let numericMinimumCharacters = 8
    static var pageSize: Int { DatabaseState.pageSize }

    private(set) var isLoadingMore = false

    @ObservationIgnored let tabID: String
    @ObservationIgnored let resultID: String
    @ObservationIgnored let columns: [DBColumn]
    @ObservationIgnored private(set) var gridColumns: [DataGridColumn]
    @ObservationIgnored var gridOnChange: ((DataGridChange) -> Void)?
    @ObservationIgnored var onRowsLoaded: ((Int, Bool) -> Void)?
    @ObservationIgnored var onSort: (([DataGridSortKey], Int64) -> Void)?
    @ObservationIgnored var onFirstRowsShown: (() -> Void)?
    @ObservationIgnored var onMenu: ((NSMenu, IndexSet, Int) -> Void)?
    @ObservationIgnored private(set) var selectedRows = IndexSet()
    @ObservationIgnored private weak var state: DatabaseState?
    @ObservationIgnored private var version: UInt32
    @ObservationIgnored private var pages: [Int: ResultPage] = [:]
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private var inFlight: Set<Int> = []
    @ObservationIgnored private var visible: Range<Int> = 0..<0
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private let queue = DispatchQueue(label: "golens.database.pages", qos: .userInitiated)

    init(tab: DBResultTab, state: DatabaseState, firstPage: ResultPage?) {
        tabID = tab.id
        resultID = tab.resultID ?? ""
        columns = tab.statement.columns
        version = tab.resultVersion
        self.state = state
        if let firstPage, firstPage.firstRow == 0, firstPage.resultVersion == tab.resultVersion {
            pages[0] = firstPage
            recent = [0]
        }
        gridColumns = Self.makeGridColumns(columns: tab.statement.columns, firstPage: firstPage)
    }

    private static func makeGridColumns(columns: [DBColumn], firstPage: ResultPage?) -> [DataGridColumn] {
        columns.enumerated().map { index, column in
            var widest = column.name.count
            if let firstPage, index < firstPage.columnCount {
                for row in 0..<firstPage.rowCount {
                    widest = max(widest, firstPage.isNull(row: row, column: index) ? DataGridMetrics.nullText.count : firstPage.displayByteCount(row: row, column: index))
                }
            }
            let numeric = ResultCellKind(name: column.kind).isNumeric
            return DataGridColumn(
                title: column.name,
                detail: column.dbType,
                alignment: numeric ? .trailing : .leading,
                idealCharacters: numeric ? max(widest, Self.numericMinimumCharacters) : widest
            )
        }
    }

    private var tab: DBResultTab? { state?.result(tabID) }

    var gridIdentity: String { tabID }
    var gridRowCount: Int { Int(tab?.rowsFetched ?? 0) }
    var gridSortKeys: [DataGridSortKey] { (tab?.sortKeys ?? []).map { DataGridSortKey(column: $0.column, descending: $0.descending) } }

    private func page(containing row: Int) -> (ResultPage, Int)? {
        guard let page = pages[row / Self.pageSize], page.resultVersion == version else { return nil }
        let local = row - Int(page.firstRow)
        guard local >= 0, local < page.rowCount else { return nil }
        return (page, local)
    }

    func gridCell(row: Int, column: Int) -> DataGridCell {
        guard let (page, local) = page(containing: row) else {
            request(row / Self.pageSize)
            return .pending
        }
        if page.isNull(row: local, column: column) { return .null }
        return .text(page.string(row: local, column: column) ?? "")
    }

    func isTruncated(row: Int, column: Int) -> Bool {
        guard let (page, local) = page(containing: row) else { return false }
        return page.isTruncated(row: local, column: column)
    }

    func gridVisibleRowsChanged(_ rows: Range<Int>) {
        visible = rows
        guard !isClosed, let tab else { return }
        let fetched = Int(tab.rowsFetched)
        guard fetched > 0 || !tab.complete else { return }
        let first = rows.lowerBound / Self.pageSize
        let last = max(first, (max(rows.upperBound, 1) - 1) / Self.pageSize)
        for index in first...last {
            touch(index)
            request(index)
        }
        if last + 1 < (fetched + Self.pageSize - 1) / Self.pageSize { request(last + 1) }
        if first > 0 { request(first - 1) }
        if !tab.complete, tab.sortKeys.isEmpty, !tab.statement.truncated, rows.upperBound + Self.prefetchMargin >= fetched {
            request(fetched / Self.pageSize)
        }
    }

    func gridSort(_ keys: [DataGridSortKey]) {
        guard !isClosed, let tab, !tab.isFetchingAll, !tab.isSorting, !(keys.isEmpty && tab.sortKeys.isEmpty) else { return }
        onSort?(keys, Int64((visible.lowerBound / Self.pageSize) * Self.pageSize))
    }

    func gridSelectionChanged(_ rows: IndexSet) {
        selectedRows = rows
    }

    func gridAddMenuItems(to menu: NSMenu, rows: IndexSet, column: Int) {
        onMenu?(menu, rows, column)
    }

    func seed(_ page: ResultPage) {
        guard !isClosed else { return }
        let index = Int(page.firstRow) / Self.pageSize
        pages[index] = page
        touch(index)
    }

    func seedFirstPage(_ page: ResultPage) {
        guard !isClosed, page.firstRow == 0, page.resultVersion == version else { return }
        pages[0] = page
        touch(0)
        gridColumns = Self.makeGridColumns(columns: columns, firstPage: page)
        gridOnChange?(.reload)
    }

    func resultChanged(_ tab: DBResultTab) {
        guard !isClosed else { return }
        if tab.resultVersion != version {
            version = tab.resultVersion
            pages = pages.filter { $0.value.resultVersion == version }
            recent.removeAll { pages[$0] == nil }
            inFlight.removeAll()
            updateLoadingMore()
            gridOnChange?(.reload)
        } else {
            gridOnChange?(.rowCount)
        }
    }

    private func touch(_ index: Int) {
        recent.removeAll { $0 == index }
        recent.append(index)
    }

    private func request(_ index: Int) {
        guard !isClosed, index >= 0, !inFlight.contains(index), let tab, !tab.isSorting else { return }
        let start = index * Self.pageSize
        if let page = pages[index], page.resultVersion == version, page.rowCount == Self.pageSize || page.isEndOfResult { return }
        let beyondLoaded = start >= Int(tab.rowsFetched)
        if beyondLoaded && (tab.complete || !tab.sortKeys.isEmpty || tab.statement.truncated) { return }
        inFlight.insert(index)
        updateLoadingMore()
        let id = resultID
        let requested = version
        queue.async { [weak self] in
            let page = DatabaseCore.fetchPage(resultID: id, firstRow: Int64(start), maxRows: Int32(Self.pageSize))
            DispatchQueue.main.async {
                self?.landed(page, index: index, requestedVersion: requested)
            }
        }
    }

    private func updateLoadingMore() {
        let fetched = Int(tab?.rowsFetched ?? 0)
        let loading = inFlight.contains { $0 * Self.pageSize >= fetched }
        if loading != isLoadingMore { isLoadingMore = loading }
    }

    private func landed(_ page: ResultPage?, index: Int, requestedVersion: UInt32) {
        inFlight.remove(index)
        defer { updateLoadingMore() }
        guard !isClosed, let page, requestedVersion == version, page.resultVersion == version, let tab else { return }
        pages[index] = page
        touch(index)
        evict()
        let end = Int(page.firstRow) + page.rowCount
        let reachedEnd = page.isEndOfResult && tab.sortKeys.isEmpty && !tab.complete
        if end > Int(tab.rowsFetched) || reachedEnd {
            onRowsLoaded?(end, reachedEnd)
        }
        gridOnChange?(.rows(Int(page.firstRow)..<end))
    }

    private func evict() {
        let keep = Set((visible.lowerBound / Self.pageSize)...(max(visible.lowerBound, visible.upperBound - 1) / Self.pageSize))
        while pages.count > Self.maxPages, let victim = recent.first(where: { !keep.contains($0) }) {
            recent.removeAll { $0 == victim }
            pages[victim] = nil
        }
    }

    func cellValue(row: Int, column: Int, maxBytes: Int32 = viewerMaxBytes, completion: @escaping (Result<DBCellValueResponse, DBError>) -> Void) {
        let id = resultID
        DispatchQueue.global(qos: .userInitiated).async {
            let value = DatabaseCore.cellValue(resultID: id, row: Int64(row), column: Int32(column), maxBytes: maxBytes)
            DispatchQueue.main.async {
                if let value, value.error == nil {
                    completion(.success(value))
                } else {
                    completion(.failure(value?.error ?? .internalFailure("GoLens couldn’t read this value. Try again.")))
                }
            }
        }
    }

    func gridCopyValue(row: Int, column: Int) {
        let kind = columns.indices.contains(column) ? ResultCellKind(name: columns[column].kind) : .unknown
        guard isTruncated(row: row, column: column) || kind == .binary else {
            guard case .text(let text) = gridCell(row: row, column: column) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        cellValue(row: row, column: column, maxBytes: Self.copyMaxBytes) { result in
            guard case .success(let value) = result, !value.isNull else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value.isHex ? "0x" + value.text : value.text, forType: .string)
        }
    }

    func reportFirstRowsShown() {
        guard let report = onFirstRowsShown else { return }
        onFirstRowsShown = nil
        report()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pages.removeAll()
        recent.removeAll()
        gridOnChange = nil
        onRowsLoaded = nil
        onSort = nil
        onMenu = nil
    }
}
