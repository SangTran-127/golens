import AppKit
import SwiftUI

enum DatabaseSymbol {
    static let dataSource = "cylinder.split.1x2"
    static let schema = "square.3.layers.3d"
    static let table = "tablecells"
    static let view = "tablecells.badge.ellipsis"
    static let column = "rectangle.portrait"
    static let primaryKey = "key"
    static let foreignKey = "key.horizontal"
    static let index = "list.bullet.rectangle"
    static let openTable = "tablecells"
    static let production = StatusTone.warning.symbol
    static let readOnly = "lock"
    static let goToStatement = "arrow.up.forward.square"
    static let disconnect = "bolt.slash"
    static let history = "clock.arrow.trianglehead.counterclockwise.rotate.90"
    static let explain = "chart.bar.doc.horizontal"
    static let submit = "arrow.up.circle"
    static let commit = "checkmark.circle"
    static let rollBack = "arrow.uturn.backward.circle"
    static let export = "square.and.arrow.up"
    static let detect = "sparkle.magnifyingglass"
    static let addRow = "plus"
    static let deleteRows = "trash"
    static let referencedRow = "arrow.turn.down.right"
    static let referencingRows = "arrow.turn.up.left"
}

struct SchemaOutlineItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case dataSource, schema, tables, views, table, view, column, primaryKey, foreignKey, index, other

        init(core: String) {
            switch core {
            case "schema": self = .schema
            case "table": self = .table
            case "view": self = .view
            case "column": self = .column
            case "primaryKey": self = .primaryKey
            case "foreignKey": self = .foreignKey
            case "index": self = .index
            default: self = .other
            }
        }

        var symbol: String {
            switch self {
            case .dataSource: DatabaseSymbol.dataSource
            case .schema: DatabaseSymbol.schema
            case .tables, .table: DatabaseSymbol.table
            case .views, .view: DatabaseSymbol.view
            case .column, .other: DatabaseSymbol.column
            case .primaryKey: DatabaseSymbol.primaryKey
            case .foreignKey: DatabaseSymbol.foreignKey
            case .index: DatabaseSymbol.index
            }
        }

        var isRelation: Bool { self == .table || self == .view }
    }

    let id: String
    let dataSourceID: String
    let path: [String]
    let kind: Kind
    let name: String
    let detail: String
    let hasChildren: Bool
}

@Observable
final class SchemaOutlineState {
    var expanded: Set<String> = []
    var children: [String: [SchemaOutlineItem]] = [:]
    var loading: Set<String> = []
    var errors: [String: DBError] = [:]
    var filter = ""
    var selection: String?
    var items: [String: SchemaOutlineItem] = [:]

    func reset(dataSourceID: String) {
        let prefix = dataSourceID + "/"
        for key in children.keys where key == dataSourceID || key.hasPrefix(prefix) { children[key] = nil }
        for key in errors.keys where key == dataSourceID || key.hasPrefix(prefix) { errors[key] = nil }
    }
}

struct SchemaOutlineView: View {
    let model: any DatabaseUIModel
    @State private var state = SchemaOutlineState()

    private var roots: [SchemaOutlineItem] {
        model.uiDataSources.map { ds in
            var detail = ds.engineTitle
            if ds.production { detail += " · Production" } else if ds.readOnly { detail += " · Read-Only" }
            return SchemaOutlineItem(id: ds.id, dataSourceID: ds.id, path: [], kind: .dataSource, name: ds.name, detail: detail, hasChildren: true)
        }
    }

    private var query: String { state.filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                PanelFilterBar(
                    placeholder: "Filter",
                    text: $state.filter,
                    accessibilityTitle: "Filter Schema"
                )
                Button(action: refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(ChromeColor.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh Schema")
                .accessibilityLabel("Refresh Schema")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)
            Divider()
            let visibleRoots = roots.filter { matches($0) }
            if !query.isEmpty && visibleRoots.isEmpty {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Objects") { state.filter = "" }
            } else {
                List(selection: $state.selection) {
                    ForEach(visibleRoots) { item in
                        SchemaOutlineNode(item: item, state: state, query: query, load: load)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Schema")
                .contextMenu(forSelectionType: String.self) { ids in
                    menu(for: ids.first.flatMap { state.items[$0] })
                } primaryAction: { ids in
                    if let item = ids.first.flatMap({ state.items[$0] }) { primary(item) }
                }
            }
        }
        .onAppear {
            for root in roots { state.items[root.id] = root }
        }
        .onChange(of: model.uiDataSources) { _, sources in
            for ds in sources {
                state.reset(dataSourceID: ds.id)
            }
            for root in roots { state.items[root.id] = root }
            for id in state.expanded { reload(id) }
        }
    }

    private func matches(_ item: SchemaOutlineItem) -> Bool {
        guard !query.isEmpty else { return true }
        if item.name.localizedCaseInsensitiveContains(query) { return true }
        return (state.children[item.id] ?? []).contains { matches($0) }
    }

    @ViewBuilder
    private func menu(for item: SchemaOutlineItem?) -> some View {
        if let item {
            if item.kind.isRelation, item.path.count == 2 {
                Button("Open Table", systemImage: DatabaseSymbol.openTable) { primary(item) }
            }
            if item.kind == .dataSource {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh(item.dataSourceID) }
                if model.uiIsConnected(dataSourceID: item.dataSourceID) {
                    Button("Disconnect", systemImage: DatabaseSymbol.disconnect) { model.uiDisconnect(dataSourceID: item.dataSourceID) }
                }
                Button("Edit Data Source…") { model.uiEditDataSource(id: item.dataSourceID) }
            } else if item.kind != .tables && item.kind != .views {
                Button("Copy Name", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.name, forType: .string)
                }
            }
        }
    }

    private func primary(_ item: SchemaOutlineItem) {
        if item.kind.isRelation, item.path.count == 2 {
            model.uiOpenTable(dataSourceID: item.dataSourceID, schema: item.path[0], table: item.path[1])
        } else if item.hasChildren {
            if state.expanded.contains(item.id) {
                state.expanded.remove(item.id)
            } else {
                state.expanded.insert(item.id)
                load(item)
            }
        }
    }

    private func refreshAll() {
        for root in roots { refresh(root.id) }
    }

    private func refresh(_ dataSourceID: String) {
        state.reset(dataSourceID: dataSourceID)
        guard let root = state.items[dataSourceID] else { return }
        fetch(root, refresh: true)
        for id in state.expanded where id.hasPrefix(dataSourceID + "/") { reload(id) }
    }

    private func reload(_ id: String) {
        guard let item = state.items[id] else { return }
        load(item)
    }

    private func load(_ item: SchemaOutlineItem) {
        guard item.hasChildren, state.children[item.id] == nil, !state.loading.contains(item.id) else { return }
        if item.kind == .tables || item.kind == .views { return }
        fetch(item, refresh: false)
    }

    private func fetch(_ item: SchemaOutlineItem, refresh: Bool) {
        let state = self.state
        state.loading.insert(item.id)
        state.errors[item.id] = nil
        model.uiSchemaChildren(dataSourceID: item.dataSourceID, path: item.path, refresh: refresh) { result in
            state.loading.remove(item.id)
            switch result {
            case .failure(let error):
                state.errors[item.id] = error
            case .success(let nodes):
                Self.apply(nodes, to: item, in: state)
            }
        }
    }

    private static func apply(_ nodes: [DBNode], to parent: SchemaOutlineItem, in state: SchemaOutlineState) {
        func make(_ node: DBNode, parentID: String, path: [String]) -> SchemaOutlineItem {
            let kind = SchemaOutlineItem.Kind(core: node.kind)
            let item = SchemaOutlineItem(
                id: parentID + "/" + node.kind + ":" + node.name,
                dataSourceID: parent.dataSourceID,
                path: path,
                kind: kind,
                name: node.name,
                detail: node.detail,
                hasChildren: node.hasChildren
            )
            state.items[item.id] = item
            return item
        }
        switch parent.kind {
        case .schema:
            let schema = parent.path.first ?? parent.name
            var groups: [SchemaOutlineItem] = []
            for (groupKind, coreKind, title) in [(SchemaOutlineItem.Kind.tables, "table", "Tables"), (.views, "view", "Views")] {
                let members = nodes.filter { $0.kind == coreKind }
                guard !members.isEmpty else { continue }
                let groupID = parent.id + "/" + title
                let group = SchemaOutlineItem(id: groupID, dataSourceID: parent.dataSourceID, path: [schema], kind: groupKind, name: title, detail: UserMessage.integer(members.count), hasChildren: true)
                state.items[groupID] = group
                state.children[groupID] = members.map { make($0, parentID: groupID, path: [schema, $0.name]) }
                groups.append(group)
            }
            state.children[parent.id] = groups
        default:
            state.children[parent.id] = nodes.map { make($0, parentID: parent.id, path: parent.path.isEmpty ? [$0.name] : parent.path + [$0.name]) }
        }
    }
}

struct SchemaOutlineNode: View {
    let item: SchemaOutlineItem
    let state: SchemaOutlineState
    let query: String
    let load: (SchemaOutlineItem) -> Void

    private func visibleChildren() -> [SchemaOutlineItem] {
        let all = state.children[item.id] ?? []
        guard !query.isEmpty else { return all }
        return all.filter { matches($0) }
    }

    private func matches(_ node: SchemaOutlineItem) -> Bool {
        if node.name.localizedCaseInsensitiveContains(query) { return true }
        return (state.children[node.id] ?? []).contains { matches($0) }
    }

    var body: some View {
        if item.hasChildren {
            let forced = !query.isEmpty && (state.children[item.id] ?? []).contains { matches($0) }
            DisclosureGroup(isExpanded: Binding(
                get: { forced || state.expanded.contains(item.id) },
                set: { expanded in
                    guard !forced else { return }
                    if expanded {
                        state.expanded.insert(item.id)
                        load(item)
                    } else {
                        state.expanded.remove(item.id)
                    }
                }
            )) {
                if state.loading.contains(item.id) && state.children[item.id] == nil {
                    HStack(spacing: Spacing.row) {
                        ProgressView().controlSize(.mini)
                        Text("Loading…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let error = state.errors[item.id] {
                    Label {
                        Text(error.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } icon: {
                        Image(systemName: StatusTone.failure.symbol)
                            .rowTint(StatusTone.failure.tint)
                    }
                    .help(error.detail ?? error.message)
                } else if let children = state.children[item.id], children.isEmpty {
                    Text(item.kind == .dataSource ? "No schemas" : "No objects")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleChildren()) { child in
                        SchemaOutlineNode(item: child, state: state, query: query, load: load)
                    }
                }
            } label: {
                label
            }
            .tag(item.id)
        } else {
            label.tag(item.id)
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.row) {
            Image(systemName: item.kind.symbol)
                .rowTint(item.kind == .dataSource && item.detail.hasSuffix("Production") ? StatusTone.warning.tint : ChromeColor.textSecondary)
                .frame(width: Spacing.section)
                .accessibilityHidden(true)
            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(item.detail.isEmpty ? item.name : "\(item.name) · \(item.detail)")
        .accessibilityElement(children: .combine)
    }
}
