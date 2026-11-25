import SwiftUI
import AppKit

struct DebuggerView: View {
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            if let message = workspace.debug.exceptionMessage {
                Label(message, systemImage: StatusTone.warning.symbol)
                    .font(.callout)
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.vertical, Spacing.standard)
                    .background(StatusTone.warning.fill)
                    .accessibilityLabel("Paused on panic: \(message)")
                Divider()
            }
            DebuggerSplit(
                snapshot: DebuggerSnapshot(debug: workspace.debug, root: workspace.activeWorkspacePath),
                background: background,
                isDark: workspace.systemAppearanceIsDark,
                theme: workspace.currentTheme
            )
                .overlay {
                    if workspace.debug.callStack.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text("Running")
                            } icon: {
                                EmptyStateBadgeView(badge: "debugger", size: 32)
                            }
                        } description: {
                            Text("Frames and variables appear when the program pauses at a breakpoint.")
                        }
                        .background(Color(nsColor: background))
                    }
                }
        }
    }

    private var background: NSColor {
        .textBackgroundColor
    }
}

struct GoroutineFilterBar: View {
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let visibility = workspace.goroutineVisibility
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.row) {
                PanelFilterBar(
                    placeholder: "Filter",
                    text: Bindable(workspace).debug.goroutineFilter,
                    accessibilityTitle: "Filter Goroutines"
                )
                .help("Filter by function, file, goroutine ID or pprof label")

                Text("\(visibility.shown) of \(visibility.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(countHelp(visibility))
                    .accessibilityLabel(countHelp(visibility))

                Menu {
                    Toggle("Show System Goroutines", isOn: Bindable(workspace).debug.showsSystemGoroutines)
                    Divider()
                    Button("Copy Goroutine Dump", systemImage: "doc.on.doc") { workspace.copyGoroutineDump() }
                    Button("Save Goroutine Dump…", systemImage: "square.and.arrow.down") { workspace.saveGoroutineDump() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Goroutine Actions")
                .accessibilityLabel("More Goroutine Actions")
            }

            if let note = note(visibility) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func countHelp(_ v: GoroutineVisibility) -> String {
        var text = "\(v.shown) of \(UserMessage.count(v.total, "goroutine")) listed"
        if v.hiddenSystem > 0 && !workspace.debug.showsSystemGoroutines {
            text += "; \(UserMessage.count(v.hiddenSystem, "system goroutine")) hidden (Show System Goroutines in the More menu or the Debug menu)"
        }
        return text + "."
    }

    private func note(_ v: GoroutineVisibility) -> String? {
        let query = workspace.debug.goroutineFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if v.keptActive {
            return v.shown == 1 ? "No goroutine matches “\(query)”. The current one stays listed." : "The current goroutine stays listed though it doesn’t match."
        }
        return v.shown == 1 ? "Only the current goroutine matches." : nil
    }
}

struct DebuggerSnapshot: Equatable {
    var frames: [DAPStackFrame]
    var selectedFrameId: Int?
    var groups: [GoroutineGroup]
    var threads: [DAPThread]
    var activeThreadId: Int32?
    var variables: [DAPVariable]
    var scopeReference: Int
    var watches: [String]
    var watchResults: [String: WatchEvaluationResult]
    var focusRequest: Int
    var root: String
    var goroutineFilter: String
    var showsSystemGoroutines: Bool

    init(debug: DebugState, root: String) {
        frames = debug.callStack
        selectedFrameId = debug.selectedFrameId
        groups = debug.goroutineGroups
        threads = debug.threads
        activeThreadId = debug.activeThreadId
        variables = debug.variables
        scopeReference = debug.variablesScopeReference
        watches = debug.watches
        watchResults = debug.watchResults
        focusRequest = debug.expressionFocusRequest
        self.root = root
        goroutineFilter = debug.goroutineFilter
        showsSystemGoroutines = debug.showsSystemGoroutines
    }
}

struct DebuggerSplit: NSViewRepresentable {
    let snapshot: DebuggerSnapshot
    let background: NSColor
    let isDark: Bool
    let theme: Theme

    func makeCoordinator() -> DebuggerController { DebuggerController() }
    func makeNSView(context: Context) -> NSSplitView { context.coordinator.makeView(workspace: context.environment.windowWorkspace) }
    func updateNSView(_ view: NSSplitView, context: Context) {
        context.coordinator.apply(snapshot, background: background, isDark: isDark, theme: theme)
    }
}

final class VarNode: NSObject {
    let name: String
    let value: String
    let type: String
    let reference: Int
    let parentReference: Int
    let isWatch: Bool
    let key: String
    var children: [VarNode]?

    init(name: String, value: String, type: String, reference: Int, parentReference: Int, isWatch: Bool, key: String) {
        self.name = name
        self.value = value
        self.type = type
        self.reference = reference
        self.parentReference = parentReference
        self.isWatch = isWatch
        self.key = key
    }

    convenience init(_ v: DAPVariable, parentReference: Int, parentKey: String) {
        self.init(name: v.name, value: v.value, type: v.type ?? "", reference: v.variablesReference, parentReference: parentReference, isWatch: false, key: parentKey + "/" + v.name)
    }

    var isError: Bool { isWatch && value.hasPrefix("Error: ") }
    var shownValue: String { value }

    static func shortType(_ type: String) -> String {
        guard type.contains("struct {") else { return type }
        var out = ""
        var depth = 0
        var i = type.startIndex
        while i < type.endIndex {
            if depth == 0, type[i...].hasPrefix("struct {}") {
                out += "struct {}"
                i = type.index(i, offsetBy: 9)
            } else if depth == 0, type[i...].hasPrefix("struct {") {
                out += "struct {…}"
                depth = 1
                i = type.index(i, offsetBy: 8)
            } else {
                if depth > 0 {
                    if type[i] == "{" { depth += 1 } else if type[i] == "}" { depth -= 1 }
                } else {
                    out.append(type[i])
                }
                i = type.index(after: i)
            }
        }
        return out
    }
}

final class DebuggerTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class VariablesOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
}

final class DebuggerSplitView: NSSplitView {
    var needsRestore = true
    var isRestoring = false

    override func layout() {
        super.layout()
        guard needsRestore, bounds.width > 0, arrangedSubviews.count == 2 else { return }
        needsRestore = false
        let saved = CGFloat(UserDefaults.standard.double(forKey: DebuggerController.framesWidthKey))
        let ideal = saved > 0 ? saved : (bounds.width * 0.4).rounded()
        let maxFrames = max(bounds.width - dividerThickness - DebuggerController.minColumnWidth, DebuggerController.minColumnWidth)
        isRestoring = true
        setPosition(min(max(ideal, DebuggerController.minColumnWidth), maxFrames), ofDividerAt: 0)
        isRestoring = false
    }
}

final class DebuggerController: NSObject, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    static let framesWidthKey = "GoLensDebuggerFramesWidth"
    static let minColumnWidth: CGFloat = 200
    static var handledFocusRequest = 0

    private let split = DebuggerSplitView()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterBar = NSHostingView(rootView: AnyView(EmptyView()))
    private let frames = DebuggerTableView()
    private let field = NSTextField()
    private let outline = VariablesOutlineView()
    private var snapshot: DebuggerSnapshot?
    private var roots: [VarNode] = []
    private var expanded: Set<String> = []
    private var generation = 0
    private var applyingSelection = false
    private var editingNode: VarNode?
    private var currentTheme: Theme = WorkspaceState.shared.currentTheme
    private var currentIsDark: Bool = WorkspaceState.shared.currentTheme.resolvedIsDark
    private weak var hostWorkspace: WorkspaceState?

    private var workspace: WorkspaceState { hostWorkspace ?? WorkspaceState.shared }
    private var codeFont: NSFont { TechnicalTypography.codeCanvasNSFont(size: 11, weight: .regular) }

    func makeView(workspace: WorkspaceState) -> NSSplitView {
        hostWorkspace = workspace
        filterBar.rootView = AnyView(GoroutineFilterBar().windowScope(workspace))
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(makeFramesPane())
        split.addArrangedSubview(makeVariablesPane())
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        popup.nextKeyView = frames
        frames.nextKeyView = field
        field.nextKeyView = outline
        outline.nextKeyView = popup
        return split
    }

    private func pane(top: NSView, body: NSScrollView) -> NSView {
        let container = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        for v in [top, separator, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            separator.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        return s
    }

    private func makeFramesPane() -> NSView {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.target = self
        popup.action = #selector(goroutineChosen)
        popup.setAccessibilityLabel("Goroutine")
        popup.cell?.setAccessibilityLabel("Goroutine")
        popup.toolTip = "Goroutines with the same stack are grouped, with their count"
        frames.addTableColumn(NSTableColumn(identifier: .init("frame")))
        frames.headerView = nil
        frames.style = .plain
        frames.rowHeight = 20
        frames.dataSource = self
        frames.delegate = self
        frames.target = self
        frames.doubleAction = #selector(jumpToSelectedFrame)
        frames.onReturn = { [weak self] in self?.jumpToSelectedFrame() }
        frames.setAccessibilityLabel("Frames")
        let stack = NSStackView(views: [filterBar, popup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [filterBar, popup] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return pane(top: stack, body: scroll(frames))
    }

    private func makeVariablesPane() -> NSView {
        field.placeholderString = "Evaluate or add watch"
        field.placeholderAttributedString = NSAttributedString(string: "Evaluate or add watch", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
        field.font = codeFont
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(submitExpression)
        field.toolTip = KeymapStore.shared.labeled("Evaluate an expression in the selected frame; it stays as a watch", "debug.evaluate")
        field.setAccessibilityLabel("Evaluate or add watch")
        for (id, title, width) in [("name", "Name", 140.0), ("value", "Value", 260.0), ("type", "Type", 120.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.style = .plain
        outline.rowHeight = 20
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Variables")
        outline.onDelete = { [weak self] in self?.removeSelectedWatch() }
        outline.onCopy = { [weak self] in self?.copySelectedValue() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        return pane(top: field, body: scroll(outline))
    }

    func apply(_ s: DebuggerSnapshot, background: NSColor, isDark: Bool, theme: Theme) {
        let old = snapshot
        let themeChanged = (currentIsDark != isDark || currentTheme.id != theme.id)
        currentIsDark = isDark
        currentTheme = theme
        snapshot = s
        filterBar.isHidden = s.groups.isEmpty
        frames.backgroundColor = background
        outline.backgroundColor = background
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = highContrast
            ? (isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (isDark ? .darkAqua : .aqua)
        let targetAppearance = NSAppearance(named: appearanceName)
        if frames.appearance != targetAppearance {
            split.appearance = targetAppearance
            frames.appearance = targetAppearance
            outline.appearance = targetAppearance
            popup.appearance = targetAppearance
            field.appearance = targetAppearance
        }
        if themeChanged {
            frames.reloadData()
            outline.reloadData()
        }
        if old?.groups != s.groups || old?.threads != s.threads || old?.activeThreadId != s.activeThreadId
            || old?.goroutineFilter != s.goroutineFilter || old?.showsSystemGoroutines != s.showsSystemGoroutines {
            rebuildPopup(s)
        }
        if old?.frames != s.frames {
            frames.reloadData()
        }
        if old?.frames != s.frames || old?.selectedFrameId != s.selectedFrameId {
            applyingSelection = true
            if let id = s.selectedFrameId, let row = s.frames.firstIndex(where: { $0.id == id }) {
                frames.selectRowIndexes([row], byExtendingSelection: false)
                frames.scrollRowToVisible(row)
            } else {
                frames.deselectAll(nil)
            }
            applyingSelection = false
        }
        if old?.variables != s.variables || old?.watches != s.watches || old?.watchResults != s.watchResults || old?.scopeReference != s.scopeReference {
            rebuildVariables(s)
        }
        if s.focusRequest != Self.handledFocusRequest {
            Self.handledFocusRequest = s.focusRequest
            DispatchQueue.main.async { self.field.window?.makeFirstResponder(self.field) }
        }
    }

    private func rebuildPopup(_ s: DebuggerSnapshot) {
        let active = Int(s.activeThreadId ?? -1)
        let menu = popup.menu ?? NSMenu()
        menu.removeAllItems()

        var selectedMenuItem: NSMenuItem?
        var firstSelectableItem: NSMenuItem?
        let threadNames = Dictionary(uniqueKeysWithValues: s.threads.map { ($0.id, $0.name) })

        func appendSelectableItem(title: String, threadId: Int, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.indentationLevel = indent
            item.representedObject = threadId
            menu.addItem(item)
            if firstSelectableItem == nil {
                firstSelectableItem = item
            }
            if threadId == active {
                selectedMenuItem = item
            }
        }

        if s.groups.isEmpty {
            var orderedThreads = s.threads
            if let current = orderedThreads.firstIndex(where: { $0.id == active }), current > 0 {
                orderedThreads.insert(orderedThreads.remove(at: current), at: 0)
            }
            for thread in orderedThreads {
                let suffix = thread.name.isEmpty ? "" : ": \(thread.name)"
                appendSelectableItem(title: "Goroutine #\(thread.id)\(suffix)", threadId: thread.id)
            }
        } else {
            let visibility = GoroutineVisibility(groups: s.groups, query: s.goroutineFilter, showsSystem: s.showsSystemGoroutines, active: s.activeThreadId.map(Int.init))
            var ordered = visibility.entries
            if let current = ordered.firstIndex(where: { $0.threadIds.contains(active) }), current > 0 {
                ordered.insert(ordered.remove(at: current), at: 0)
            }
            func title(_ group: GoroutineGroup, _ tid: Int) -> String {
                let place = group.location.isEmpty ? "" : " — \(group.location)"
                let label = group.label(for: tid)
                let detail = group.top.isEmpty ? (threadNames[tid] ?? "") : "\(group.top)\(place)"
                return "Goroutine #\(tid)\(label.isEmpty ? "" : " [\(label)]")\(detail.isEmpty ? "" : ": \(detail)")"
            }
            for entry in ordered {
                let group = entry.group
                if group.threadIds.count <= 1 {
                    let tid = entry.threadIds.first ?? 0
                    appendSelectableItem(title: title(group, tid), threadId: tid)
                } else {
                    let place = group.location.isEmpty ? "" : " — \(group.location)"
                    let shown = entry.threadIds.count == group.count ? "\(group.count) goroutines" : "\(entry.threadIds.count) of \(group.count) goroutines"
                    menu.addItem(.sectionHeader(title: "\(shown): \(group.top)\(place)"))
                    for tid in entry.threadIds {
                        appendSelectableItem(title: title(group, tid), threadId: tid, indent: 1)
                    }
                }
            }
        }

        popup.menu = menu
        let targetItem = selectedMenuItem ?? firstSelectableItem
        popup.isEnabled = targetItem != nil
        if let targetItem {
            popup.select(targetItem)
        }
    }

    @objc private func goroutineChosen() {
        guard let tid = popup.selectedItem?.representedObject as? Int else { return }
        guard workspace.debug.activeThreadId != Int32(tid) else { return }
        workspace.debug.activeThreadId = Int32(tid)
        workspace.fetchDebugState(for: Int32(tid))
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot?.frames.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let frame = snapshot?.frames[row] else { return nil }
        let cell = frameCell(tableView)
        let file = frame.source?.name ?? ""
        cell.textField?.stringValue = frame.name
        cell.textField?.textColor = .labelColor
        if let loc = cell.subviews.first(where: { $0.identifier?.rawValue == "location" }) as? NSTextField {
            loc.stringValue = file.isEmpty ? "" : "\(file):\(frame.line)"
            loc.textColor = .secondaryLabelColor
        }
        cell.toolTip = frame.source?.path.map { "\($0):\(frame.line)" }
        cell.setAccessibilityLabel("frame \(row), \(frame.name)" + (file.isEmpty ? "" : ", \(file) line \(frame.line)"))
        return cell
    }

    private func frameCell(_ tableView: NSTableView) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: .init("frameCell"), owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = .init("frameCell")
        let name = NSTextField(labelWithString: "")
        name.font = codeFont
        name.lineBreakMode = .byTruncatingTail
        let location = NSTextField(labelWithString: "")
        location.identifier = .init("location")
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.alignment = .right
        location.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [name, location] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            location.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            location.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            location.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let s = snapshot, s.frames.indices.contains(frames.selectedRow) else { return }
        let frame = s.frames[frames.selectedRow]
        guard frame.id != workspace.debug.selectedFrameId else { return }
        workspace.selectFrame(frame)
    }

    @objc private func jumpToSelectedFrame() {
        guard let s = snapshot, s.frames.indices.contains(frames.selectedRow) else { return }
        workspace.selectFrame(s.frames[frames.selectedRow], focusEditor: true)
    }

    @objc private func submitExpression() {
        let expr = field.stringValue
        guard !expr.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        workspace.addWatch(expr)
        field.stringValue = ""
    }

    private func rebuildVariables(_ s: DebuggerSnapshot) {
        generation += 1
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? VarNode)?.key
        roots = s.watches.map { expr in
            let eval = s.watchResults[expr]
            let displayValue: String
            let ref: Int
            let typeName: String
            if let err = eval?.error, !err.isEmpty {
                displayValue = err.hasPrefix("Error: ") ? err : "Error: \(err)"
                ref = 0
                typeName = ""
            } else {
                displayValue = eval?.value ?? ""
                ref = eval?.variablesReference ?? 0
                typeName = eval?.type ?? ""
            }
            return VarNode(
                name: expr,
                value: displayValue,
                type: typeName,
                reference: ref,
                parentReference: 0,
                isWatch: true,
                key: "watch:" + expr
            )
        } + s.variables.map { VarNode($0, parentReference: s.scopeReference, parentKey: "var") }
        outline.reloadData()
        for node in roots where expanded.contains(node.key) {
            outline.expandItem(node)
        }
        if let selectedKey, let node = roots.first(where: { $0.key == selectedKey }) {
            outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
        }
    }

    private func load(_ node: VarNode) {
        let reference = node.reference
        let generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let vars = WorkspaceState.debugVariables(reference) ?? []
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                node.children = vars.map { VarNode($0, parentReference: reference, parentKey: node.key) }
                self.outline.reloadItem(node, reloadChildren: true)
                for child in node.children ?? [] where self.expanded.contains(child.key) {
                    self.outline.expandItem(child)
                }
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? VarNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? VarNode else { return roots[index] }
        return node.children?[index] ?? node
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? VarNode)?.reference ?? 0) > 0
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? VarNode else { return }
        expanded.insert(node.key)
        if node.children == nil { load(node) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? VarNode else { return }
        expanded.remove(node.key)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? VarNode, let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = textCell(outlineView, id: id == "name" && node.isWatch ? "watchName" : id)
        let text = cell.textField!
        let primaryColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        switch id {
        case "name":
            text.stringValue = node.name
            text.textColor = primaryColor
            cell.toolTip = node.isWatch ? "Watch: \(node.name)" : nil
        case "value":
            text.stringValue = node.isWatch && node.value.isEmpty ? "…" : node.shownValue
            text.textColor = node.isError ? NSColor(StatusTone.failure.tint) : primaryColor
            cell.toolTip = node.shownValue.count > 40 ? node.shownValue : nil
        default:
            let short = VarNode.shortType(node.type)
            text.stringValue = short
            text.textColor = secondaryColor
            cell.toolTip = short == node.type ? nil : node.type
            text.setAccessibilityLabel(node.type.isEmpty ? nil : "type \(short)")
        }
        return cell
    }

    private func textCell(_ outlineView: NSOutlineView, id: String) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: .init(id), owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = .init(id)
        let text = NSTextField(labelWithString: "")
        text.font = id == "type" ? .systemFont(ofSize: 11) : codeFont
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if id == "watchName" {
            let image = NSImageView(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Watch") ?? NSImage())
            image.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private var selectedNode: VarNode? { outline.item(atRow: outline.selectedRow) as? VarNode }

    private func clickedOrSelected() -> VarNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? VarNode
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedOrSelected() else { return }
        if node.isWatch {
            let remove = menu.addItem(withTitle: "Remove Watch", action: #selector(removeClickedWatch), keyEquivalent: "")
            remove.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
            remove.target = self
        } else {
            let set = menu.addItem(withTitle: "Set Value…", action: node.parentReference != 0 ? #selector(beginSetValue) : nil, keyEquivalent: "")
            set.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            set.target = self
            if outline.parent(forItem: node) == nil {
                let watch = menu.addItem(withTitle: "Add Watch", action: #selector(addClickedWatch), keyEquivalent: "")
                watch.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
                watch.target = self
            }
        }
        let inspect = menu.addItem(withTitle: "Inspect Value (JSON / UTF-8 / Hex)…", action: #selector(inspectClickedValue), keyEquivalent: "")
        inspect.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        inspect.target = self
        let copy = menu.addItem(withTitle: "Copy Value", action: #selector(copyClickedValue), keyEquivalent: "")
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.target = self
    }

    @objc private func inspectClickedValue() {
        guard let node = clickedOrSelected() else { return }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return }
        let rowRect = outline.rect(ofRow: row)
        let popover = NSPopover()
        popover.behavior = .transient
        let inspectorView = DebuggerValueInspectorPopover(
            varName: node.name,
            varType: node.type,
            varValue: node.value
        ) { [weak popover] in
            popover?.performClose(nil)
        }
        popover.contentViewController = NSHostingController(rootView: inspectorView.windowScope(workspace))
        popover.show(relativeTo: rowRect, of: outline, preferredEdge: .maxY)
    }

    @objc private func removeClickedWatch() {
        if let node = clickedOrSelected(), node.isWatch { workspace.removeWatch(node.name) }
    }

    private func removeSelectedWatch() {
        if let node = selectedNode, node.isWatch { workspace.removeWatch(node.name) }
    }

    @objc private func addClickedWatch() {
        if let node = clickedOrSelected() { workspace.addWatch(node.name) }
    }

    @objc private func copyClickedValue() {
        if let node = clickedOrSelected() { copy(node) }
    }

    private func copySelectedValue() {
        if let node = selectedNode { copy(node) }
    }

    private func copy(_ node: VarNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.shownValue, forType: .string)
    }

    @objc private func beginSetValue() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? VarNode,
              let cell = outline.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView,
              let text = cell.textField else { return }
        editingNode = node
        text.isEditable = true
        text.delegate = self
        text.stringValue = node.value
        outline.window?.makeFirstResponder(text)
        text.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control !== field, commandSelector == #selector(NSResponder.cancelOperation(_:)), let node = editingNode else { return false }
        editingNode = nil
        (control as? NSTextField)?.stringValue = node.shownValue
        outline.window?.makeFirstResponder(outline)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let text = notification.object as? NSTextField, text !== field else { return }
        text.isEditable = false
        guard let node = editingNode else { return }
        editingNode = nil
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        guard movement == NSTextMovement.return.rawValue, text.stringValue != node.value else {
            text.stringValue = node.shownValue
            return
        }
        let variable = DAPVariable(name: node.name, value: node.value, type: node.type, variablesReference: node.reference)
        workspace.setDebugVariable(variable, parentReference: node.parentReference, to: text.stringValue)
        outline.window?.makeFirstResponder(outline)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.minColumnWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - Self.minColumnWidth)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !split.needsRestore, !split.isRestoring, split.arrangedSubviews.count == 2, split.bounds.width > 0 else { return }
        let width = split.arrangedSubviews[0].frame.width
        guard width >= Self.minColumnWidth else { return }
        UserDefaults.standard.set(Double(width), forKey: Self.framesWidthKey)
    }
}
