import AppKit
import Foundation
import GoLensFoundation
import Observation

enum DBPendingValue: Hashable, Sendable {
    case text(String)
    case null

    var text: String {
        switch self {
        case .text(let value): value
        case .null: ""
        }
    }

    var isNull: Bool { self == .null }
}

@Observable
final class DatabaseEditSession {
    private(set) var edits: [Int64: [Int: DBPendingValue]] = [:]
    private(set) var inserts: [[Int: DBPendingValue]] = []
    private(set) var deletes: Set<Int64> = []
    var issues: [DBEditIssue] = []

    var hasChanges: Bool { !edits.isEmpty || !inserts.isEmpty || !deletes.isEmpty }

    var changeCount: Int {
        edits.keys.filter { !deletes.contains($0) }.count + inserts.count + deletes.count
    }

    func value(row: Int64, column: Int) -> DBPendingValue? {
        edits[row]?[column]
    }

    func insertValue(_ index: Int, column: Int) -> DBPendingValue? {
        inserts.indices.contains(index) ? inserts[index][column] : nil
    }

    func isDeleted(_ row: Int64) -> Bool { deletes.contains(row) }

    func isEdited(_ row: Int64) -> Bool { edits[row]?.isEmpty == false }

    func setValue(_ value: DBPendingValue, row: Int64, column: Int, original: DBPendingValue?) {
        var cells = edits[row] ?? [:]
        if let original, original == value {
            cells[column] = nil
        } else {
            cells[column] = value
        }
        edits[row] = cells.isEmpty ? nil : cells
        clearIssues(row: row, insert: nil, column: column)
    }

    func setInsertValue(_ value: DBPendingValue, insert index: Int, column: Int) {
        guard inserts.indices.contains(index) else { return }
        inserts[index][column] = value
        clearIssues(row: nil, insert: index, column: column)
    }

    @discardableResult
    func addInsert(_ values: [Int: DBPendingValue] = [:]) -> Int {
        inserts.append(values)
        return inserts.count - 1
    }

    func delete(rows: [Int64], inserts removed: [Int]) {
        for row in rows { deletes.insert(row) }
        removeInserts(removed)
    }

    func revert(rows: [Int64], inserts removed: [Int]) {
        for row in rows {
            edits[row] = nil
            deletes.remove(row)
        }
        removeInserts(removed)
        issues.removeAll { issue in issue.row.map(rows.contains) == true }
    }

    func revertAll() {
        edits = [:]
        inserts = []
        deletes = []
        issues = []
    }

    private func removeInserts(_ indices: [Int]) {
        guard !indices.isEmpty else { return }
        for index in indices.sorted(by: >) where inserts.indices.contains(index) {
            inserts.remove(at: index)
        }
        issues.removeAll { $0.insert != nil }
    }

    private func clearIssues(row: Int64?, insert: Int?, column: Int) {
        guard !issues.isEmpty else { return }
        issues.removeAll { issue in
            (issue.column == nil || issue.column == column) && ((row != nil && issue.row == row) || (insert != nil && issue.insert == insert))
        }
    }

    func request(resultID: String) -> DBEditRequest {
        var cellEdits: [DBCellEdit] = []
        for row in edits.keys.sorted() where !deletes.contains(row) {
            for (column, value) in (edits[row] ?? [:]).sorted(by: { $0.key < $1.key }) {
                cellEdits.append(DBCellEdit(row: row, column: column, value: value.text, isNull: value.isNull))
            }
        }
        let rowInserts = inserts.map { cells in
            DBRowInsert(cells: cells.sorted { $0.key < $1.key }.map { DBInsertCell(column: $0.key, value: $0.value.text, isNull: $0.value.isNull) })
        }
        return DBEditRequest(resultId: resultID, edits: cellEdits, inserts: rowInserts, deletes: deletes.sorted())
    }
}

final class DatabaseTableGridSource: DataGridEditableSource {
    static let defaultPlaceholder = "DEFAULT"

    let cache: ResultPageCache
    let session: DatabaseEditSession
    let isEditable: Bool
    let readOnlyReason: String?
    let readOnlyColumns: [Int: String]
    let keyColumns: Set<Int>
    let gridColumns: [DataGridColumn]
    var sortKeys: [DataGridSortKey]
    var onSort: (([DataGridSortKey]) -> Void)?
    var onRefused: ((String) -> Void)?
    var gridOnChange: ((DataGridChange) -> Void)?
    var gridOnRequest: ((DataGridRequest) -> Void)?
    private var editStart: [DataGridCellRef: String] = [:]

    init(cache: ResultPageCache, session: DatabaseEditSession, table: DBTableBinding, dataSourceReadOnlyReason: String?) {
        self.cache = cache
        self.session = session
        let readOnly = Dictionary(table.readOnlyColumns.map { ($0.column, $0.reason) }, uniquingKeysWith: { first, _ in first })
        readOnlyColumns = readOnly
        isEditable = table.editable && dataSourceReadOnlyReason == nil
        readOnlyReason = table.editable ? dataSourceReadOnlyReason : (table.reason.isEmpty ? dataSourceReadOnlyReason : table.reason)
        keyColumns = Set(cache.columns.indices.filter { table.keyColumns.contains(cache.columns[$0].name) })
        sortKeys = table.sortKeys.map { DataGridSortKey(column: $0.column, descending: $0.descending) }
        gridColumns = cache.gridColumns.enumerated().map { index, column in
            var column = column
            if let reason = readOnly[index] {
                column.detail = [column.detail, "read-only. \(reason)"].compactMap { $0 }.joined(separator: ", ")
            }
            return column
        }
        cache.gridOnChange = { [weak self] change in self?.forward(change) }
    }

    private var insertCount: Int { session.inserts.count }

    func loadedRow(_ row: Int) -> Int? {
        row >= insertCount ? row - insertCount : nil
    }

    func insertIndex(_ row: Int) -> Int? {
        row < insertCount ? row : nil
    }

    private func forward(_ change: DataGridChange) {
        switch change {
        case .rows(let range):
            gridOnChange?(.rows((range.lowerBound + insertCount)..<(range.upperBound + insertCount)))
        case .rowCount, .reload:
            gridOnChange?(change)
        }
    }

    private func reshaped() {
        gridOnChange?(.rowCount)
        gridOnChange?(.rows(0..<gridRowCount))
    }

    var gridIdentity: String { cache.gridIdentity + "#table" }
    var gridRowCount: Int { insertCount + cache.gridRowCount }
    var gridSortKeys: [DataGridSortKey] { sortKeys }
    var gridIsEditable: Bool { isEditable }
    var gridReadOnlyReason: String? { readOnlyReason }
    var gridHasChanges: Bool { session.hasChanges }

    func gridCell(row: Int, column: Int) -> DataGridCell {
        if let index = insertIndex(row) {
            switch session.insertValue(index, column: column) {
            case .text(let text): return .text(text)
            case .null: return .null
            case nil: return .placeholder(Self.defaultPlaceholder)
            }
        }
        guard let loaded = loadedRow(row) else { return .pending }
        switch session.value(row: Int64(loaded), column: column) {
        case .text(let text): return .text(text)
        case .null: return .null
        case nil: return cache.gridCell(row: loaded, column: column)
        }
    }

    func gridVisibleRowsChanged(_ rows: Range<Int>) {
        let lower = max(0, rows.lowerBound - insertCount)
        let upper = max(lower + 1, rows.upperBound - insertCount)
        cache.gridVisibleRowsChanged(lower..<upper)
    }

    func gridSort(_ keys: [DataGridSortKey]) {
        onSort?(keys)
    }

    func gridCopyValue(row: Int, column: Int) {
        guard let loaded = loadedRow(row), session.value(row: Int64(loaded), column: column) == nil else {
            guard case .text(let text) = gridCell(row: row, column: column) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        cache.gridCopyValue(row: loaded, column: column)
    }

    func gridSelectionChanged(_ rows: IndexSet) {
        cache.gridSelectionChanged(IndexSet(rows.compactMap(loadedRow)))
    }

    func gridAddMenuItems(to menu: NSMenu, rows: IndexSet, column: Int) {
        cache.gridAddMenuItems(to: menu, rows: IndexSet(rows.compactMap(loadedRow)), column: column)
    }

    func gridRowState(row: Int) -> DataGridRowState {
        if insertIndex(row) != nil { return .inserted }
        guard let loaded = loadedRow(row) else { return .unchanged }
        if session.isDeleted(Int64(loaded)) { return .deleted }
        return session.isEdited(Int64(loaded)) ? .edited : .unchanged
    }

    func gridCellIsChanged(row: Int, column: Int) -> Bool {
        guard let loaded = loadedRow(row) else { return false }
        return session.value(row: Int64(loaded), column: column) != nil
    }

    func gridEditAccess(row: Int, column: Int) -> DataGridEditAccess {
        guard isEditable else { return .readOnly(readOnlyReason ?? "This table can’t be edited.") }
        if let reason = readOnlyColumns[column] { return .readOnly(reason) }
        if let loaded = loadedRow(row), session.isDeleted(Int64(loaded)) {
            return .readOnly("This row is marked for deletion. Revert it to change its values.")
        }
        return .editable
    }

    func gridEditText(row: Int, column: Int, completion: @escaping (String?) -> Void) {
        let ref = DataGridCellRef(row: row, column: column)
        let start: (String) -> Void = { [weak self] text in
            self?.editStart[ref] = text
            completion(text)
        }
        if let index = insertIndex(row) {
            start(session.insertValue(index, column: column)?.text ?? "")
            return
        }
        guard let loaded = loadedRow(row) else { return completion(nil) }
        if let pending = session.value(row: Int64(loaded), column: column) {
            start(pending.text)
            return
        }
        if needsFullValue(row: loaded, column: column) {
            cache.cellValue(row: loaded, column: column, maxBytes: ResultPageCache.copyMaxBytes) { [weak self] result in
                guard case .success(let value) = result else {
                    self?.onRefused?("GoLens couldn’t read the full value of this cell, so it can’t be edited now. Try again.")
                    return completion(nil)
                }
                start(value.isNull ? "" : (value.isHex ? "0x" + value.text : value.text))
            }
            return
        }
        switch cache.gridCell(row: loaded, column: column) {
        case .text(let text): start(text)
        case .null, .placeholder: start("")
        case .pending: completion(nil)
        }
    }

    private func needsFullValue(row: Int, column: Int) -> Bool {
        let kind = cache.columns.indices.contains(column) ? ResultCellKind(name: cache.columns[column].kind) : .unknown
        return cache.isTruncated(row: row, column: column) || kind == .binary
    }

    private func original(row: Int, column: Int) -> DBPendingValue? {
        guard !cache.isTruncated(row: row, column: column) else { return nil }
        switch cache.gridCell(row: row, column: column) {
        case .text(let text): return .text(text)
        case .null: return .null
        case .placeholder, .pending: return nil
        }
    }

    func gridCommitEdit(row: Int, column: Int, text: String) {
        let ref = DataGridCellRef(row: row, column: column)
        let startText = editStart.removeValue(forKey: ref)
        guard startText != text else { return }
        if let index = insertIndex(row) {
            session.setInsertValue(.text(text), insert: index, column: column)
        } else if let loaded = loadedRow(row) {
            session.setValue(.text(text), row: Int64(loaded), column: column, original: original(row: loaded, column: column))
        }
        gridOnChange?(.rows(row..<(row + 1)))
    }

    func gridSetNull(_ cells: [DataGridCellRef]) {
        for cell in cells where gridEditAccess(row: cell.row, column: cell.column) == .editable {
            if let index = insertIndex(cell.row) {
                session.setInsertValue(.null, insert: index, column: cell.column)
            } else if let loaded = loadedRow(cell.row) {
                session.setValue(.null, row: Int64(loaded), column: cell.column, original: original(row: loaded, column: cell.column))
            }
        }
        gridOnChange?(.rows(0..<gridRowCount))
    }

    private var firstEditableColumn: Int {
        let columns = cache.columns.indices
        return columns.first { readOnlyColumns[$0] == nil && !keyColumns.contains($0) }
            ?? columns.first { readOnlyColumns[$0] == nil } ?? 0
    }

    func gridAddRow() {
        guard isEditable else { return refuse() }
        let index = session.addInsert()
        reshaped()
        gridOnRequest?(.edit(DataGridCellRef(row: index, column: firstEditableColumn)))
    }

    func gridDuplicateRows(_ rows: IndexSet) {
        guard isEditable else { return refuse() }
        var pending: [(values: [Int: DBPendingValue], missing: [(row: Int, column: Int)])] = []
        for row in rows {
            var values: [Int: DBPendingValue] = [:]
            var missing: [(row: Int, column: Int)] = []
            for column in cache.columns.indices where !keyColumns.contains(column) && readOnlyColumns[column] == nil {
                if let index = insertIndex(row) {
                    if let value = session.insertValue(index, column: column) { values[column] = value }
                } else if let loaded = loadedRow(row) {
                    if let value = session.value(row: Int64(loaded), column: column) {
                        values[column] = value
                    } else if needsFullValue(row: loaded, column: column) {
                        missing.append((loaded, column))
                    } else if let value = original(row: loaded, column: column) {
                        values[column] = value
                    }
                }
            }
            pending.append((values, missing))
        }
        let group = DispatchGroup()
        var filled = pending.map(\.values)
        var failed = false
        for (index, item) in pending.enumerated() {
            for cell in item.missing {
                group.enter()
                cache.cellValue(row: cell.row, column: cell.column, maxBytes: ResultPageCache.copyMaxBytes) { result in
                    switch result {
                    case .success(let value): filled[index][cell.column] = value.isNull ? .null : .text(value.isHex ? "0x" + value.text : value.text)
                    case .failure: failed = true
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard !failed else {
                self.onRefused?("GoLens couldn’t read every value of the row, so it didn’t duplicate it. Try again.")
                return
            }
            var last = 0
            for values in filled { last = self.session.addInsert(values) }
            self.reshaped()
            self.gridOnRequest?(.edit(DataGridCellRef(row: last, column: self.firstEditableColumn)))
        }
    }

    func gridDeleteRows(_ rows: IndexSet) {
        guard isEditable else { return refuse() }
        session.delete(rows: rows.compactMap(loadedRow).map(Int64.init), inserts: rows.compactMap(insertIndex))
        reshaped()
    }

    func gridRevertRows(_ rows: IndexSet) {
        session.revert(rows: rows.compactMap(loadedRow).map(Int64.init), inserts: rows.compactMap(insertIndex))
        reshaped()
    }

    func gridRevertAll() {
        session.revertAll()
        reshaped()
    }

    func gridEditRefused(_ reason: String) {
        onRefused?(reason)
    }

    private func refuse() {
        if let readOnlyReason { onRefused?(readOnlyReason) }
    }
}
