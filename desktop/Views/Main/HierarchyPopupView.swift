import SwiftUI
import AppKit

struct HierarchyPopupView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedIndex = 0
    @State private var linePreviews: [String: String] = [:]
    @State private var keyMonitor: Any? = nil

    private var items: [HierarchyItem] { workspace.hierarchyItems }
    private var itemKeys: [String] { items.map(\.id) }

    private var emptyMessage: String {
        switch (workspace.hierarchyMode, workspace.hierarchyDirection) {
        case (.call, .incoming): return "No callers found"
        case (.call, .outgoing): return "No callees found"
        case (.type, .incoming): return "No supertypes found"
        case (.type, .outgoing): return "No subtypes found"
        }
    }

    private var listHeight: CGFloat {
        if workspace.hierarchyFailure != nil {
            return 112
        }
        if workspace.isHierarchyLoading || items.isEmpty {
            return 96
        }
        let rowsHeight = CGFloat(items.count) * 32 + 16
        return min(max(rowsHeight, 64), 320)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: workspace.hierarchyMode == .call ? "arrow.triangle.branch" : "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(workspace.hierarchyMode == .call ? "Call Hierarchy" : "Type Hierarchy")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                if let rootName = workspace.hierarchyRoot?.name, !rootName.isEmpty {
                    Text(rootName)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Picker("", selection: Binding(
                    get: { workspace.hierarchyDirection },
                    set: { workspace.setHierarchyDirection($0) }
                )) {
                    if workspace.hierarchyMode == .call {
                        Text("Callers").tag(HierarchyDirection.incoming)
                        Text("Callees").tag(HierarchyDirection.outgoing)
                    } else {
                        Text("Supertypes").tag(HierarchyDirection.incoming)
                        Text("Subtypes").tag(HierarchyDirection.outgoing)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 170)
                .labelsHidden()
                .accessibilityLabel("Hierarchy Direction")
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.inset)

            Divider()

            Group {
                if workspace.isHierarchyLoading {
                    VStack(spacing: Spacing.standard) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading hierarchy…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure = workspace.hierarchyFailure {
                    NavigationFailureView(subject: "the hierarchy", failure: failure) {
                        workspace.retryHierarchy()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                    let isSelected = index == selectedIndex
                                    let preview = linePreviews[previewKey(for: item)] ?? (item.detail ?? "")
                                    let locationLabel = "\(URL(fileURLWithPath: item.filePath).lastPathComponent):\(item.selectionRange.start.line + 1)"

                                    HStack(spacing: Spacing.standard) {
                                        SymbolIconView(lspKind: item.kind, fallbackModeIsCall: workspace.hierarchyMode == .call, isSelected: isSelected, size: 16)

                                        Text(item.name)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                                            .lineLimit(1)

                                        if !preview.isEmpty {
                                            Text(preview)
                                                .font(.subheadline.monospaced())
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }

                                        Spacer(minLength: 8)

                                        Text(locationLabel)
                                            .font(.subheadline.monospaced())
                                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                            .lineLimit(1)

                                        Button {
                                            workspace.drillIntoHierarchyItem(item)
                                        } label: {
                                            Image(systemName: "arrow.turn.down.right")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                                .frame(width: 16, height: 16)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Inspect Hierarchy of \(item.name) (→)")
                                        .accessibilityLabel("Inspect Hierarchy of \(item.name)")
                                    }
                                    .padding(.horizontal, Spacing.comfortable)
                                    .padding(.vertical, Spacing.row)
                                    .popupRow(isSelected: isSelected, onHoverSelect: {
                                        selectedIndex = index
                                    }) {
                                        selectedIndex = index
                                        openSelected()
                                    }
                                    .id(index)
                                }
                            }
                            .padding(Spacing.standard)
                        }
                        .onChange(of: selectedIndex) { _, newValue in
                            guard !PopupMouseTracker.isHoverSelecting else { return }
                            withAnimation(reduceMotion ? nil : Motion.quick) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
            .popupWidth(.wide, height: listHeight)
        }
        .popupWidth(.wide)
        .floatingPanelBackground(cornerRadius: CornerRadius.panel)
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            selectedIndex = 0
            loadLinePreviews()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                if handleKeyDown(event) { return nil }
                return event
            }
        }
        .onChange(of: itemKeys) { _, _ in
            PopupMouseTracker.markKeyboardOrOpen()
            selectedIndex = 0
            loadLinePreviews()
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private static func symbolIcon(for kind: Int, mode: HierarchyMode) -> String {
        switch kind {
        case 6, 9, 12:
            return "f.cursive"
        case 5, 11, 23, 26:
            return "t.square"
        default:
            return mode == .call ? "f.cursive" : "t.square"
        }
    }

    private func previewKey(for item: HierarchyItem) -> String {
        "\(item.filePath):\(item.selectionRange.start.line)"
    }

    private func loadLinePreviews() {
        var previews: [String: String] = [:]
        let grouped = Dictionary(grouping: items, by: \.filePath)
        for (path, groupItems) in grouped {
            let neededLines = Set(groupItems.map { $0.selectionRange.start.line })
            let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let session = workspace.documents[path] ?? workspace.documents[resolvedPath] {
                let ns = session.storage.string as NSString
                for line in neededLines {
                    if let range = session.lineRange(line) {
                        previews["\(path):\(line)"] = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let maxLine = neededLines.max() ?? 0
                var currentLine = 0
                text.enumerateLines { lineText, stop in
                    if neededLines.contains(currentLine) {
                        previews["\(path):\(currentLine)"] = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if currentLine >= maxLine {
                        stop = true
                    }
                    currentLine += 1
                }
            }
        }
        linePreviews = previews
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.showHierarchy else { return false }

        if event.keyCode == 53 {
            workspace.showHierarchy = false
            return true
        }
        if event.keyCode == 36 {
            if workspace.hierarchyFailure != nil {
                workspace.retryHierarchy()
            } else {
                openSelected()
            }
            return true
        }
        if event.keyCode == 124 {
            if selectedIndex >= 0 && selectedIndex < items.count {
                workspace.drillIntoHierarchyItem(items[selectedIndex])
            }
            return true
        }
        if event.keyCode == 125 {
            PopupMouseTracker.markKeyboardOrOpen()
            if selectedIndex < items.count - 1 {
                selectedIndex += 1
            }
            return true
        }
        if event.keyCode == 126 {
            PopupMouseTracker.markKeyboardOrOpen()
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return true
        }
        return false
    }

    private func openSelected() {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        workspace.jumpTo(
            filePath: item.filePath,
            line: item.selectionRange.start.line + 1,
            column: item.selectionRange.start.character + 1
        )
        workspace.showHierarchy = false
    }
}
