import AppKit
import SwiftUI

struct DataGridColumn: Hashable {
    enum Alignment: Hashable { case leading, trailing }

    let title: String
    var detail: String? = nil
    var alignment: Alignment = .leading
    var idealCharacters: Int = 0
}

enum DataGridCell: Equatable {
    case text(String)
    case null
    case placeholder(String)
    case pending
}

enum DataGridChange {
    case rows(Range<Int>)
    case rowCount
    case reload
}

struct DataGridSortKey: Hashable {
    let column: Int
    let descending: Bool
}

struct DataGridCellRef: Hashable {
    let row: Int
    let column: Int
}

enum DataGridRowState: Equatable {
    case unchanged
    case edited
    case inserted
    case deleted

    var marker: String {
        switch self {
        case .unchanged: ""
        case .edited: "Edited"
        case .inserted: "New"
        case .deleted: "Deleted"
        }
    }
}

enum DataGridEditAccess: Equatable {
    case editable
    case readOnly(String)
}

enum DataGridRequest {
    case edit(DataGridCellRef)
    case reveal(Int)
}

protocol DataGridSource: AnyObject {
    var gridIdentity: String { get }
    var gridColumns: [DataGridColumn] { get }
    var gridRowCount: Int { get }
    var gridSortKeys: [DataGridSortKey] { get }
    var gridOnChange: ((DataGridChange) -> Void)? { get set }
    func gridCell(row: Int, column: Int) -> DataGridCell
    func gridVisibleRowsChanged(_ rows: Range<Int>)
    func gridSort(_ keys: [DataGridSortKey])
    func gridCopyValue(row: Int, column: Int)
    func gridSelectionChanged(_ rows: IndexSet)
    func gridAddMenuItems(to menu: NSMenu, rows: IndexSet, column: Int)
}

protocol DataGridEditableSource: DataGridSource {
    var gridIsEditable: Bool { get }
    var gridReadOnlyReason: String? { get }
    var gridHasChanges: Bool { get }
    var gridOnRequest: ((DataGridRequest) -> Void)? { get set }
    func gridRowState(row: Int) -> DataGridRowState
    func gridCellIsChanged(row: Int, column: Int) -> Bool
    func gridEditAccess(row: Int, column: Int) -> DataGridEditAccess
    func gridEditText(row: Int, column: Int, completion: @escaping (String?) -> Void)
    func gridCommitEdit(row: Int, column: Int, text: String)
    func gridSetNull(_ cells: [DataGridCellRef])
    func gridAddRow()
    func gridDuplicateRows(_ rows: IndexSet)
    func gridDeleteRows(_ rows: IndexSet)
    func gridRevertRows(_ rows: IndexSet)
    func gridRevertAll()
    func gridEditRefused(_ reason: String)
}

extension DataGridSource {
    func gridSort(_ keys: [DataGridSortKey]) {}

    func gridSelectionChanged(_ rows: IndexSet) {}

    func gridAddMenuItems(to menu: NSMenu, rows: IndexSet, column: Int) {}

    func gridCopyValue(row: Int, column: Int) {
        guard case .text(let text) = gridCell(row: row, column: column) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func gridDisplayText(row: Int, column: Int) -> String {
        switch gridCell(row: row, column: column) {
        case .text(let text): text
        case .null: "NULL"
        case .placeholder, .pending: ""
        }
    }
}

final class DataGridMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func runAction(_ sender: Any?) { handler() }
}

extension NSMenu {
    @discardableResult
    func addGridItem(_ title: String, symbol: String? = nil, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = DataGridMenuAction(action)
        let item = addItem(withTitle: title, action: enabled ? #selector(DataGridMenuAction.runAction(_:)) : nil, keyEquivalent: "")
        item.target = target
        item.representedObject = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

struct DataGridDismissDetailAction {
    let action: () -> Void

    func callAsFunction() { action() }
}

private struct DataGridDismissDetailKey: EnvironmentKey {
    static let defaultValue = DataGridDismissDetailAction {}
}

extension EnvironmentValues {
    var dataGridDismissDetail: DataGridDismissDetailAction {
        get { self[DataGridDismissDetailKey.self] }
        set { self[DataGridDismissDetailKey.self] = newValue }
    }
}

enum DataGridMetrics {
    static let minColumnWidth: CGFloat = 48
    static let maxColumnWidth: CGFloat = 360
    static let cellInset: CGFloat = Spacing.compact
    static let sortIndicatorWidth: CGFloat = Spacing.section
    static let nullText = "NULL"
    static let stateColumnID = NSUserInterfaceItemIdentifier("state")
    static let stateColumnTitle = "Change"

    static var markerFont: NSFont { NSFont.preferredFont(forTextStyle: .caption1) }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func rowHeight(_ font: NSFont) -> CGFloat {
        lineHeight(font) + Spacing.row
    }

    static let headerHeight: CGFloat = NSTableView().headerView?.frame.height ?? 0

    static func minimumHeight(_ font: NSFont, obscured: CGFloat = headerHeight) -> CGFloat {
        obscured + rowHeight(font)
    }

    static func stateColumnWidth() -> CGFloat {
        let widest = [DataGridRowState.edited, .inserted, .deleted]
            .map { ($0.marker as NSString).size(withAttributes: [.font: markerFont]).width }
            .max() ?? 0
        return ceil(widest + 2 * cellInset + Spacing.compact)
    }
}

struct DataGridView<CellDetail: View>: NSViewRepresentable {
    let source: any DataGridSource
    let font: NSFont
    var accessibilityLabel: String = "Data Grid"
    var onFirstRowsShown: (() -> Void)? = nil
    var onObscuredHeightChange: ((CGFloat) -> Void)? = nil
    @ViewBuilder var cellDetail: (DataGridCellRef) -> CellDetail

    func makeCoordinator() -> DataGridCoordinator {
        DataGridCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = DataGridTableView()
        table.coordinator = coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.focusRingType = .default
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(DataGridCoordinator.doubleClicked(_:))
        table.setAccessibilityLabel(accessibilityLabel)
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(DataGridCoordinator.boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(DataGridCoordinator.columnResized(_:)), name: NSTableView.columnDidResizeNotification, object: table)
        scroll.postsFrameChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(DataGridCoordinator.frameChanged(_:)), name: NSView.frameDidChangeNotification, object: scroll)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(DataGridCoordinator.frameChanged(_:)), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        coordinator.table = table
        coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: DataGridCoordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.detach()
    }
}

final class DataGridTableView: NSTableView {
    weak var coordinator: DataGridCoordinator?

    private var dataRowViews: [DataGridRowView] {
        var rows: [DataGridRowView] = []
        enumerateAvailableRowViews { view, _ in
            if let view = view as? DataGridRowView, view.row >= 0 { rows.append(view) }
        }
        return rows.sorted { $0.row < $1.row }
    }

    private func nonRowAccessibilityChildren() -> [Any] {
        (super.accessibilityColumns() ?? []) + [headerView].compactMap { $0 }
    }

    private var unobscuredRect: NSRect {
        guard let clip = enclosingScrollView?.contentView else { return visibleRect }
        var rect = clip.bounds
        rect.origin.y += clip.contentInsets.top
        rect.size.height = max(0, rect.height - clip.contentInsets.top - clip.contentInsets.bottom)
        return convert(rect, from: clip).intersection(bounds)
    }

    private var visibleDataRowViews: [DataGridRowView] {
        let unobscured = unobscuredRect
        let visible = rows(in: unobscured)
        return dataRowViews.filter { NSLocationInRange($0.row, visible) && unobscured.contains(NSPoint(x: unobscured.midX, y: rect(ofRow: $0.row).midY)) }
    }

    override func accessibilityChildren() -> [Any]? {
        visibleDataRowViews + nonRowAccessibilityChildren()
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        visibleDataRowViews
    }

    override func accessibilityVisibleRows() -> [any NSAccessibilityRow]? {
        visibleDataRowViews
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case .children: accessibilityChildren()
        case .rows: accessibilityRows()
        case .visibleRows: accessibilityVisibleRows()
        default: super.accessibilityAttributeValue(attribute)
        }
    }

    var firstDataColumn = 0

    var focusedColumn = 0 {
        didSet {
            guard focusedColumn != oldValue else { return }
            for row in selectedRowIndexes { rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true }
            if focusedColumn >= 0, focusedColumn < numberOfColumns { scrollColumnToVisible(focusedColumn) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers.isEmpty, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSLeftArrowFunctionKey:
                focusedColumn = max(firstDataColumn, focusedColumn - 1)
                coordinator.announceFocusedCell()
                return
            case NSRightArrowFunctionKey:
                focusedColumn = min(numberOfColumns - 1, focusedColumn + 1)
                coordinator.announceFocusedCell()
                return
            case 0x20:
                coordinator.showDetailForFocusedCell()
                return
            case 0x0D, 0x03:
                if coordinator.beginEditingFocusedCell() { return }
            default:
                break
            }
        }
        if modifiers == .command, event.keyCode == 51, coordinator.deleteSelectedRows() {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column >= firstDataColumn { focusedColumn = column }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        if column >= firstDataColumn { focusedColumn = column }
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let menu = super.menu(for: event) else { return nil }
        coordinator?.menuNeedsUpdate(menu)
        return menu
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelectedRows()
    }
}

final class DataGridRowView: NSTableRowView {
    weak var table: DataGridTableView?
    weak var coordinator: DataGridCoordinator?
    var row = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        guard let table, table.focusedColumn >= table.firstDataColumn, table.focusedColumn < table.numberOfColumns else { return }
        let columnRect = table.rect(ofColumn: table.focusedColumn)
        let rect = NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: bounds.height)
            .insetBy(dx: Stroke.standard, dy: Stroke.standard)
        let path = NSBezierPath(roundedRect: rect, xRadius: CornerRadius.small, yRadius: CornerRadius.small)
        path.lineWidth = Stroke.standard
        (isEmphasized ? NSColor.alternateSelectedControlTextColor : NSColor.keyboardFocusIndicatorColor).setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let table, let coordinator, row >= 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let selectedText = isSelected && isEmphasized
        coordinator.drawCells(row: row, in: table, bounds: bounds, dirtyRect: dirtyRect, context: context, selectedText: selectedText, selected: isSelected)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .row }

    override func accessibilityIndex() -> Int { row }

    override func accessibilityParent() -> Any? { table ?? super.accessibilityParent() }

    override func accessibilityChildren() -> [Any]? {
        guard let table, let coordinator, row >= 0 else { return super.accessibilityChildren() }
        return coordinator.accessibilityCells(row: row, in: table, parent: self)
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case .role: NSAccessibility.Role.row.rawValue
        case .children, .visibleChildren: accessibilityChildren()
        case .index: row
        default: super.accessibilityAttributeValue(attribute)
        }
    }
}

final class DataGridCellEditor: NSTextField {
    var gridCell: DataGridCellRef?
}

final class DataGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSPopoverDelegate, NSTextFieldDelegate {
    weak var table: DataGridTableView?
    private var source: (any DataGridSource)?
    private var editable: (any DataGridEditableSource)?
    private var identity = ""
    private var columns: [DataGridColumn] = []
    private var hasStateColumn = false
    private var rowCount = 0
    private var font = TechnicalTypography.codeCanvasNSFont(size: NSFont.systemFontSize, weight: .regular) {
        didSet { lineHeight = DataGridMetrics.lineHeight(font) }
    }
    private lazy var lineHeight = DataGridMetrics.lineHeight(font)
    private var applyingSort = false
    private var firstRowsReported = false
    private var onFirstRowsShown: (() -> Void)?
    private var onObscuredHeightChange: ((CGFloat) -> Void)?
    private var lastObscuredHeight: CGFloat?
    private var detail: ((DataGridCellRef) -> AnyView)?
    private weak var popover: NSPopover?
    private var lastVisible: Range<Int> = 0..<0
    private var lastVisibleX: CGFloat = 0
    private var editor: DataGridCellEditor?
    private var editGeneration = 0

    private var columnOffset: Int { hasStateColumn ? 1 : 0 }

    private func dataColumn(_ tableColumn: Int) -> Int? {
        let column = tableColumn - columnOffset
        return columns.indices.contains(column) ? column : nil
    }

    private func tableColumnIndex(_ dataColumn: Int) -> Int { dataColumn + columnOffset }

    private var focusedDataColumn: Int? {
        guard let table else { return nil }
        return dataColumn(table.focusedColumn)
    }

    func update<D: View>(_ view: DataGridView<D>) {
        guard let table else { return }
        detail = { AnyView(view.cellDetail($0)) }
        onFirstRowsShown = view.onFirstRowsShown
        onObscuredHeightChange = view.onObscuredHeightChange
        table.setAccessibilityLabel(view.accessibilityLabel)
        var needsReload = false
        if font != view.font {
            font = view.font
            table.rowHeight = DataGridMetrics.rowHeight(font)
            needsReload = true
        }
        if source !== view.source || identity != view.source.gridIdentity {
            endEditing(commit: false)
            source?.gridOnChange = nil
            editable?.gridOnRequest = nil
            source = view.source
            editable = view.source as? any DataGridEditableSource
            identity = view.source.gridIdentity
            firstRowsReported = false
            lastVisible = 0..<0
            popover?.close()
            view.source.gridOnChange = { [weak self] change in self?.apply(change) }
            editable?.gridOnRequest = { [weak self] request in self?.handle(request) }
            if let scroll = table.enclosingScrollView {
                let insets = scroll.contentView.contentInsets
                scroll.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            rebuildColumns()
            rowCount = view.source.gridRowCount
            table.rowHeight = DataGridMetrics.rowHeight(font)
            table.focusedColumn = table.firstDataColumn
            table.reloadData()
            if rowCount > 0 { table.scrollRowToVisible(0) }
            needsReload = false
            DispatchQueue.main.async { [weak self] in self?.reportVisibleRows() }
        }
        if needsReload { table.reloadData() }
    }

    func detach() {
        endEditing(commit: false)
        source?.gridOnChange = nil
        editable?.gridOnRequest = nil
        popover?.close()
    }

    private func columnWidth(for column: DataGridColumn, digit: CGFloat, headerFont: NSFont) -> CGFloat {
        let header = (column.title as NSString).size(withAttributes: [.font: headerFont]).width + DataGridMetrics.sortIndicatorWidth
        let content = CGFloat(min(column.idealCharacters, 64)) * digit
        return min(DataGridMetrics.maxColumnWidth, max(DataGridMetrics.minColumnWidth, ceil(max(header, content) + 2 * DataGridMetrics.cellInset + Spacing.compact)))
    }

    private func rebuildColumns() {
        guard let table, let source else { return }
        let next = source.gridColumns
        let previous = columns
        let wantsState = editable?.gridIsEditable == true
        let sameShape = wantsState == hasStateColumn && next.count == columns.count && next.count + (wantsState ? 1 : 0) == table.numberOfColumns
            && zip(next, columns).allSatisfy { $0.title == $1.title && $0.alignment == $1.alignment && $0.detail == $1.detail }
        columns = next
        hasStateColumn = wantsState
        table.firstDataColumn = columnOffset
        guard !sameShape else {
            if zip(previous, next).contains(where: { $0.idealCharacters != $1.idealCharacters }) {
                let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
                let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
                for (index, column) in next.enumerated() where previous[index].idealCharacters != column.idealCharacters {
                    let tableIndex = index + columnOffset
                    guard tableIndex < table.numberOfColumns else { continue }
                    table.tableColumns[tableIndex].width = columnWidth(for: column, digit: digit, headerFont: headerFont)
                }
            }
            applySortIndicators()
            return
        }
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        if wantsState {
            let state = NSTableColumn(identifier: DataGridMetrics.stateColumnID)
            state.title = ""
            state.headerToolTip = DataGridMetrics.stateColumnTitle
            state.width = DataGridMetrics.stateColumnWidth()
            state.minWidth = state.width
            state.maxWidth = state.width
            state.resizingMask = []
            table.addTableColumn(state)
        }
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            tableColumn.title = column.title
            tableColumn.headerCell.alignment = column.alignment == .trailing ? .right : .left
            tableColumn.headerToolTip = column.detail.map { "\(column.title): \($0)" } ?? column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            tableColumn.minWidth = DataGridMetrics.minColumnWidth
            tableColumn.resizingMask = .userResizingMask
            tableColumn.width = columnWidth(for: column, digit: digit, headerFont: headerFont)
            table.addTableColumn(tableColumn)
        }
        applySortIndicators()
    }

    private func applySortIndicators() {
        guard let table, let source else { return }
        let descriptors = source.gridSortKeys.map { NSSortDescriptor(key: "\($0.column)", ascending: !$0.descending) }
        guard descriptors != table.sortDescriptors else { return }
        applyingSort = true
        table.sortDescriptors = descriptors
        applyingSort = false
    }

    private func apply(_ change: DataGridChange) {
        guard let table, let source else { return }
        switch change {
        case .rowCount:
            let count = source.gridRowCount
            if count != rowCount {
                rowCount = count
                table.noteNumberOfRowsChanged()
            }
            reportVisibleRows()
        case .reload:
            endEditing(commit: false)
            rebuildColumns()
            rowCount = source.gridRowCount
            applySortIndicators()
            table.reloadData()
            reportVisibleRows()
        case .rows(let range):
            redrawRows(range)
        }
    }

    private func handle(_ request: DataGridRequest) {
        guard let table else { return }
        switch request {
        case .reveal(let row):
            guard row >= 0, row < rowCount else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case .edit(let cell):
            guard cell.row >= 0, cell.row < rowCount, columns.indices.contains(cell.column) else { return }
            table.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
            table.focusedColumn = tableColumnIndex(cell.column)
            table.scrollRowToVisible(cell.row)
            beginEditing(row: cell.row, column: cell.column)
        }
    }

    @objc func frameChanged(_ note: Notification) {
        guard let scroll = table?.enclosingScrollView else { return }
        let clip = scroll.contentView
        let obscured = scroll.frame.height - (clip.frame.height - clip.contentInsets.top - clip.contentInsets.bottom)
        guard obscured != lastObscuredHeight else { return }
        lastObscuredHeight = obscured
        DispatchQueue.main.async { [weak self] in self?.onObscuredHeightChange?(obscured) }
    }

    @objc func boundsChanged(_ note: Notification) {
        if let table, table.visibleRect.minX != lastVisibleX {
            lastVisibleX = table.visibleRect.minX
            redrawRows(nil)
        }
        reportVisibleRows()
    }

    private func reportVisibleRows() {
        guard let table, let source else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location < max(rowCount, 1) else { return }
        let range = visible.location..<(visible.location + max(visible.length, 1))
        guard range != lastVisible || visible.length == 0 else { return }
        lastVisible = range
        source.gridVisibleRowsChanged(range)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("DataGridRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? DataGridRowView ?? DataGridRowView()
        view.identifier = identifier
        view.table = table
        view.coordinator = self
        view.row = row
        view.needsDisplay = true
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? DataGridRowView else { return }
        if rowView.row != row {
            rowView.row = row
            rowView.needsDisplay = true
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table, let source else { return }
        source.gridSelectionChanged(table.selectedRowIndexes)
    }

    func drawCells(row: Int, in table: NSTableView, bounds: NSRect, dirtyRect: NSRect, context: CGContext, selectedText: Bool, selected: Bool) {
        guard let source, row < rowCount else { return }
        if !firstRowsReported, columns.isEmpty || (0..<columns.count).contains(where: {
            if case .pending = source.gridCell(row: row, column: $0) { return false }
            return true
        }) {
            firstRowsReported = true
            onFirstRowsShown?()
        }
        let rowState: DataGridRowState = hasStateColumn ? (editable?.gridRowState(row: row) ?? .unchanged) : .unchanged
        let primary = selectedText ? NSColor.alternateSelectedControlTextColor : rowState == .deleted ? NSColor.secondaryLabelColor : NSColor.labelColor
        let tertiary = selectedText ? NSColor.alternateSelectedControlTextColor : NSColor.tertiaryLabelColor
        var textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: primary]
        var nullAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tertiary]
        if rowState == .deleted {
            textAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            nullAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let baseline = floor((bounds.height - lineHeight) / 2 + font.ascender)
        let visible = table.visibleRect
        let minX = max(dirtyRect.minX, visible.minX)
        let maxX = min(dirtyRect.maxX, visible.maxX)
        if hasStateColumn, !selected, let fill = Self.rowFill(rowState) {
            context.setFillColor(fill.cgColor)
            context.fill(NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if hasStateColumn, rowState != .unchanged, table.numberOfColumns > 0 {
            let rect = table.rect(ofColumn: 0)
            if rect.maxX >= minX, rect.minX <= maxX {
                let markerFont = DataGridMetrics.markerFont
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: markerFont,
                    .foregroundColor: selectedText ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: rowState.marker, attributes: attributes))
                let markerBaseline = floor((bounds.height - DataGridMetrics.lineHeight(markerFont)) / 2 + markerFont.ascender)
                context.textPosition = CGPoint(x: rect.minX + DataGridMetrics.cellInset, y: markerBaseline)
                CTLineDraw(line, context)
            }
        }
        for (index, column) in columns.enumerated() {
            let tableIndex = index + columnOffset
            guard tableIndex < table.numberOfColumns else { break }
            let rect = table.rect(ofColumn: tableIndex)
            guard rect.maxX >= minX, rect.minX <= maxX else { continue }
            if hasStateColumn, !selected, rowState == .edited, editable?.gridCellIsChanged(row: row, column: index) == true {
                context.saveGState()
                context.setFillColor(Self.changedCellFill.cgColor)
                context.fill(NSRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height))
                context.restoreGState()
            }
            let text: String
            let attributes: [NSAttributedString.Key: Any]
            switch source.gridCell(row: row, column: index) {
            case .text(let value):
                text = value
                attributes = textAttributes
            case .null:
                text = DataGridMetrics.nullText
                attributes = nullAttributes
            case .placeholder(let value):
                text = value
                attributes = nullAttributes
            case .pending:
                continue
            }
            guard !text.isEmpty else { continue }
            let available = rect.width - 2 * DataGridMetrics.cellInset
            guard available > 0 else { continue }
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if width > available {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
                if let truncated = CTLineCreateTruncatedLine(line, Double(available), .end, token) {
                    line = truncated
                    width = CTLineGetTypographicBounds(line, nil, nil, nil)
                }
            }
            let x = column.alignment == .trailing ? rect.maxX - DataGridMetrics.cellInset - CGFloat(width) : rect.minX + DataGridMetrics.cellInset
            context.saveGState()
            context.clip(to: NSRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height))
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func rowFill(_ state: DataGridRowState) -> NSColor? {
        switch state {
        case .inserted: NSColor(StatusTone.success.fill)
        case .deleted: NSColor(StatusTone.failure.fill)
        case .edited, .unchanged: nil
        }
    }

    private static var changedCellFill: NSColor { NSColor(ThemeColor.tintFill(ThemeColor.accent)) }

    func accessibilityCells(row: Int, in table: NSTableView, parent: NSView) -> [Any] {
        guard let source, row < rowCount else { return [] }
        let rowState: DataGridRowState = hasStateColumn ? (editable?.gridRowState(row: row) ?? .unchanged) : .unchanged
        var elements: [Any] = []
        if hasStateColumn, rowState != .unchanged, table.numberOfColumns > 0 {
            let rect = table.rect(ofColumn: 0)
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.cell)
            element.setAccessibilityLabel("\(DataGridMetrics.stateColumnTitle), \(rowState.marker)")
            element.setAccessibilityParent(parent)
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: parent, rect: NSRect(x: rect.minX, y: 0, width: rect.width, height: parent.bounds.height)))
            element.setAccessibilityColumnIndexRange(NSRange(location: 0, length: 1))
            element.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
            elements.append(element)
        }
        for (index, column) in columns.enumerated() {
            let tableIndex = index + columnOffset
            guard tableIndex < table.numberOfColumns else { break }
            let rect = table.rect(ofColumn: tableIndex)
            var value: String
            switch source.gridCell(row: row, column: index) {
            case .text(let text): value = text
            case .null: value = "null"
            case .placeholder(let text): value = text.lowercased()
            case .pending: value = "loading"
            }
            if rowState == .edited, editable?.gridCellIsChanged(row: row, column: index) == true {
                value += ", edited"
            }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.cell)
            element.setAccessibilityLabel("\(column.title), \(value)")
            element.setAccessibilityParent(parent)
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: parent, rect: NSRect(x: rect.minX, y: 0, width: rect.width, height: parent.bounds.height)))
            element.setAccessibilityColumnIndexRange(NSRange(location: tableIndex, length: 1))
            element.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
            elements.append(element)
        }
        return elements
    }

    private func redrawRows(_ range: Range<Int>?) {
        guard let table else { return }
        table.enumerateAvailableRowViews { rowView, row in
            if range?.contains(row) ?? true { rowView.needsDisplay = true }
        }
    }

    @objc func columnResized(_ note: Notification) {
        endEditing(commit: true)
        redrawRows(nil)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSort, let source else { return }
        let keys = tableView.sortDescriptors.prefix(1).compactMap { descriptor -> DataGridSortKey? in
            guard let key = descriptor.key, let column = Int(key) else { return nil }
            return DataGridSortKey(column: column, descending: !descriptor.ascending)
        }
        source.gridSort(keys)
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0 else { return }
        if table.clickedColumn >= table.firstDataColumn { table.focusedColumn = table.clickedColumn }
        guard let column = focusedDataColumn else { return }
        if let editable, editable.gridIsEditable, editable.gridEditAccess(row: table.clickedRow, column: column) == .editable {
            beginEditing(row: table.clickedRow, column: column)
            return
        }
        showDetail(row: table.clickedRow, column: column)
    }

    func showDetailForFocusedCell() {
        guard let table, let column = focusedDataColumn else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        showDetail(row: row, column: column)
    }

    private func showDetail(row: Int, column: Int) {
        guard let table, let detail, row < rowCount, columns.indices.contains(column) else { return }
        popover?.close()
        let tableIndex = tableColumnIndex(column)
        table.scrollColumnToVisible(tableIndex)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let dismiss = DataGridDismissDetailAction { [weak popover] in popover?.performClose(nil) }
        let host = NSHostingController(rootView: detail(DataGridCellRef(row: row, column: column)).environment(\.dataGridDismissDetail, dismiss))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: table.frameOfCell(atColumn: tableIndex, row: row), of: table, preferredEdge: .maxY)
        self.popover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        guard let table, let window = table.window else { return }
        window.makeFirstResponder(table)
    }

    func announceFocusedCell() {
        guard let table, let source, table.selectedRow >= 0, let column = focusedDataColumn else { return }
        let text = source.gridCell(row: table.selectedRow, column: column) == .null ? "null" : source.gridDisplayText(row: table.selectedRow, column: column)
        NSAccessibility.post(element: table, notification: .announcementRequested, userInfo: [
            .announcement: "\(columns[column].title), \(text)",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    func copySelectedRows() {
        guard let table, let source else { return }
        var lines: [String] = []
        for row in table.selectedRowIndexes where row < rowCount {
            lines.append((0..<columns.count).map { source.gridDisplayText(row: row, column: $0) }.joined(separator: "\t"))
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @discardableResult
    func beginEditingFocusedCell() -> Bool {
        guard let table, let editable, table.selectedRow >= 0, let column = focusedDataColumn else { return false }
        guard editable.gridIsEditable else {
            if let reason = editable.gridReadOnlyReason { editable.gridEditRefused(reason) }
            return editable.gridReadOnlyReason != nil
        }
        beginEditing(row: table.selectedRow, column: column)
        return true
    }

    @discardableResult
    func deleteSelectedRows() -> Bool {
        guard let table, let editable, editable.gridIsEditable, !table.selectedRowIndexes.isEmpty else { return false }
        endEditing(commit: true)
        editable.gridDeleteRows(table.selectedRowIndexes)
        return true
    }

    private func beginEditing(row: Int, column: Int) {
        guard let table, let editable, editable.gridIsEditable else { return }
        endEditing(commit: true)
        if case .readOnly(let reason) = editable.gridEditAccess(row: row, column: column) {
            editable.gridEditRefused(reason)
            return
        }
        popover?.close()
        editGeneration += 1
        let generation = editGeneration
        editable.gridEditText(row: row, column: column) { [weak self, weak table] text in
            guard let self, let table, let text, generation == self.editGeneration, row < self.rowCount else { return }
            let tableIndex = self.tableColumnIndex(column)
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(tableIndex)
            let field = DataGridCellEditor(frame: table.frameOfCell(atColumn: tableIndex, row: row))
            field.gridCell = DataGridCellRef(row: row, column: column)
            field.font = self.font
            field.stringValue = text
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.focusRingType = .exterior
            field.usesSingleLineMode = true
            field.lineBreakMode = .byClipping
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.delegate = self
            field.alignment = self.columns[column].alignment == .trailing ? .right : .left
            field.placeholderString = self.columns[column].title
            field.setAccessibilityLabel("Edit \(self.columns[column].title)")
            table.addSubview(field)
            self.editor = field
            table.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func endEditing(commit: Bool) {
        guard let field = editor, let cell = field.gridCell else { return }
        editor = nil
        let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let hadFocus = field.currentEditor() != nil
        field.delegate = nil
        field.removeFromSuperview()
        if commit { editable?.gridCommitEdit(row: cell.row, column: cell.column, text: text) }
        if hadFocus, let table { table.window?.makeFirstResponder(table) }
    }

    private func moveEditing(from cell: DataGridCellRef, by step: Int) {
        guard let editable else { return }
        var column = cell.column + step
        while columns.indices.contains(column) {
            if editable.gridEditAccess(row: cell.row, column: column) == .editable {
                table?.focusedColumn = tableColumnIndex(column)
                beginEditing(row: cell.row, column: column)
                return
            }
            column += step
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? DataGridCellEditor, field === editor, let cell = field.gridCell else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            return true
        case #selector(NSResponder.insertTab(_:)):
            endEditing(commit: true)
            moveEditing(from: cell, by: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            endEditing(commit: true)
            moveEditing(from: cell, by: -1)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? DataGridCellEditor, field === editor else { return }
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, field === self.editor, field.currentEditor() == nil else { return }
            self.endEditing(commit: true)
        }
    }

    @objc private func copyRowsAction(_ sender: Any?) { copySelectedRows() }

    @objc private func copyValueAction(_ sender: Any?) {
        guard let table, let source, table.selectedRow >= 0, let column = focusedDataColumn else { return }
        source.gridCopyValue(row: table.selectedRow, column: column)
    }

    @objc private func showValueAction(_ sender: Any?) { showDetailForFocusedCell() }

    @objc private func clearSortAction(_ sender: Any?) {
        source?.gridSort([])
    }

    @objc private func sortAscendingAction(_ sender: Any?) {
        guard let column = focusedDataColumn else { return }
        source?.gridSort([DataGridSortKey(column: column, descending: false)])
    }

    @objc private func sortDescendingAction(_ sender: Any?) {
        guard let column = focusedDataColumn else { return }
        source?.gridSort([DataGridSortKey(column: column, descending: true)])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        let selection = table.selectedRowIndexes
        let hasSelection = !selection.isEmpty
        let copy = menu.addItem(withTitle: "Copy", action: hasSelection ? #selector(copyRowsAction(_:)) : nil, keyEquivalent: "")
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.target = self
        let value = menu.addItem(withTitle: "Copy Value", action: hasSelection ? #selector(copyValueAction(_:)) : nil, keyEquivalent: "")
        value.target = self
        let show = menu.addItem(withTitle: "Show Value", action: hasSelection ? #selector(showValueAction(_:)) : nil, keyEquivalent: "")
        show.target = self
        let column = focusedDataColumn ?? 0
        if let source {
            let before = menu.numberOfItems
            source.gridAddMenuItems(to: menu, rows: selection, column: column)
            if menu.numberOfItems > before { menu.insertItem(.separator(), at: before) }
        }
        if let editable, editable.gridIsEditable {
            addEditItems(to: menu, editable: editable, selection: selection)
        }
        guard focusedDataColumn != nil else { return }
        menu.addItem(.separator())
        let ascending = menu.addItem(withTitle: "Sort Ascending", action: #selector(sortAscendingAction(_:)), keyEquivalent: "")
        ascending.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        ascending.target = self
        let descending = menu.addItem(withTitle: "Sort Descending", action: #selector(sortDescendingAction(_:)), keyEquivalent: "")
        descending.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        descending.target = self
        if let source, !source.gridSortKeys.isEmpty {
            let clear = menu.addItem(withTitle: "Clear Sort", action: #selector(clearSortAction(_:)), keyEquivalent: "")
            clear.target = self
        }
    }

    private func addEditItems(to menu: NSMenu, editable: any DataGridEditableSource, selection: IndexSet) {
        let hasSelection = !selection.isEmpty
        let column = focusedDataColumn
        menu.addItem(.separator())
        let canEditCell = hasSelection && column.map { col in selection.contains { editable.gridEditAccess(row: $0, column: col) == .editable } } == true
        menu.addGridItem("Edit Value", symbol: "pencil", enabled: canEditCell && selection.count == 1) { [weak self] in
            guard let self, let column, let row = selection.first else { return }
            self.beginEditing(row: row, column: column)
        }
        menu.addGridItem("Set NULL", enabled: canEditCell) { [weak self] in
            guard let self, let column else { return }
            self.endEditing(commit: true)
            editable.gridSetNull(selection.map { DataGridCellRef(row: $0, column: column) })
        }
        menu.addItem(.separator())
        menu.addGridItem("Add Row", symbol: "plus") { [weak self] in
            self?.endEditing(commit: true)
            editable.gridAddRow()
        }
        menu.addGridItem("Duplicate Row", symbol: "plus.square.on.square", enabled: hasSelection) { [weak self] in
            self?.endEditing(commit: true)
            editable.gridDuplicateRows(selection)
        }
        let delete = menu.addGridItem("Delete Rows", symbol: "trash", enabled: hasSelection) { [weak self] in
            self?.endEditing(commit: true)
            editable.gridDeleteRows(selection)
        }
        delete.keyEquivalent = "\u{8}"
        delete.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        let selectionChanged = selection.contains { editable.gridRowState(row: $0) != .unchanged }
        menu.addGridItem("Revert Selected", symbol: "arrow.uturn.backward", enabled: selectionChanged) { [weak self] in
            self?.endEditing(commit: false)
            editable.gridRevertRows(selection)
        }
        menu.addGridItem("Revert All", enabled: editable.gridHasChanges) { [weak self] in
            self?.endEditing(commit: false)
            editable.gridRevertAll()
        }
    }
}
