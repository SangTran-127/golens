import AppKit
import SwiftUI

struct IssuesNavigatorView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var center: DiagnosticsCenter
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"
    @State private var selectedItemID: String? = nil

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.center = workspace.diagnosticsCenter
    }

    var body: some View {
        let allItems = center.allItems(in: workspace)
        let filtered = center.filteredItems(from: allItems)

        VStack(spacing: 0) {
            VStack(spacing: Spacing.row) {
                PanelFilterBar(
                    placeholder: "Filter issues, files, rules, or comments…",
                    text: $center.filterQuery,
                    accessibilityTitle: "Filter Issues",
                    onSubmit: {
                        openSelected(in: filtered)
                    },
                    onMoveSelection: { delta in
                        moveSelection(by: delta, in: filtered)
                    }
                ) {
                    if center.scope == .todos {
                        Button {
                            workspace.refreshWorkspaceTodos()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline)
                                .foregroundStyle(ChromeColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rescan Workspace for TODOs")
                        .accessibilityLabel("Rescan Workspace for TODOs")
                        .disabled(workspace.isScanningTodos)
                    } else if center.scope == .bookmarks, !workspace.bookmarks.isEmpty {
                        Button {
                            workspace.clearAllBookmarks()
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .foregroundStyle(ChromeColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear All Bookmarks")
                        .accessibilityLabel("Clear All Bookmarks")
                    } else if center.scope == .breakpoints {
                        Button {
                            workspace.presentAddFunctionBreakpoint()
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline)
                                .foregroundStyle(ChromeColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(KeymapStore.shared.labeled("Add Function Breakpoint…", "debug.addFunctionBreakpoint"))
                        .accessibilityLabel("Add Function Breakpoint")
                    } else {
                        Button {
                            center.refreshWorkspaceChecksIfNeeded(for: workspace, force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline)
                                .foregroundStyle(ChromeColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Static Checks")
                        .accessibilityLabel("Refresh Static Checks")
                        .disabled(center.isRefreshingStaticChecks)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.compact) {
                        ForEach(DiagnosticsNavigatorScope.allCases) { scopeItem in
                            scopeChip(scopeItem, count: center.count(for: scopeItem, in: allItems))
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Issues, TODOs, Bookmarks, and Breakpoints")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)

            Divider()

            contentBody(allItems: allItems, filtered: filtered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            center.syncWithLegacySubtab(workspace.selectedIssuesNavigatorSubtab)
            center.refreshWorkspaceChecksIfNeeded(for: workspace)
        }
        .onChange(of: workspace.selectedIssuesNavigatorSubtab) { _, subtab in
            center.syncWithLegacySubtab(subtab)
        }
        .onChange(of: workspace.activeWorkspacePath) { _, _ in
            center.refreshWorkspaceChecksIfNeeded(for: workspace, force: true)
        }
    }

    private func scopeChip(_ item: DiagnosticsNavigatorScope, count: Int) -> some View {
        let isSelected = center.scope == item
        return Button {
            center.selectScope(item, in: workspace)
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(item.rawValue)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(TechnicalTypography.metricMono)
                        .opacity(isSelected ? 0.95 : 0.75)
                }
            }
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ChromeColor.textSecondary)
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .background(
                isSelected ? ThemeColor.accent : ThemeColor.wellFill,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(item.rawValue) (\(count))" : item.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func contentBody(allItems: [UnifiedDiagnosticItem], filtered: [UnifiedDiagnosticItem]) -> some View {
        let hasTextFilter = !center.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let scopeHasItems = allItems.contains { center.matchesScope($0, scope: center.scope) }
        let narrowsIssues = [.errors, .warnings, .safety].contains(center.scope)
        let issuesExist = allItems.contains { center.matchesScope($0, scope: .all) }
        let hasActiveFilterHidingItems = filtered.isEmpty && ((hasTextFilter && scopeHasItems) || (narrowsIssues && issuesExist))

        if (workspace.isScanningTodos && center.scope == .todos && filtered.isEmpty)
            || (workspace.isSafetyAuditRunning && center.scope == .safety && filtered.isEmpty) {
            UnifiedEmptyState.loading(
                message: center.scope == .todos
                    ? "Scanning workspace for TODO and FIXME comments…"
                    : "Running Go safety and vulnerability checks…"
            )
        } else if hasActiveFilterHidingItems {
            UnifiedEmptyState.filteredEmpty(itemNoun: center.scope.itemNoun) {
                center.resetFilters(in: workspace)
            }
        } else if filtered.isEmpty {
            emptyUnfilteredState
        } else {
            let grouped = Dictionary(grouping: filtered, by: { $0.path.isEmpty ? $0.relativePath : $0.path })
            let sortedKeys = grouped.keys.sorted()

            List(selection: $selectedItemID) {
                ForEach(sortedKeys, id: \.self) { groupKey in
                    let itemsInFile = grouped[groupKey] ?? []
                    Section(sectionTitle(for: groupKey, sample: itemsInFile.first)) {
                        ForEach(itemsInFile) { item in
                            diagnosticRow(item)
                                .tag(item.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.automatic)
            .onKeyPress(.return) {
                openSelected(in: filtered)
                return .handled
            }
            .onDeleteCommand {
                removeSelected(in: filtered)
            }
        }
    }

    @ViewBuilder
    private var emptyUnfilteredState: some View {
        switch center.scope {
        case .todos:
            UnifiedEmptyState.empty(
                symbol: "checklist",
                title: "No TODOs or FIXMEs",
                message: "Comments starting with TODO, FIXME, HACK, or NOTE across your project appear here."
            )
        case .bookmarks:
            let toggleKey = KeymapStore.shared.display("navigate.toggleBookmark")
            UnifiedEmptyState.empty(
                symbol: "bookmark",
                title: "No Bookmarks",
                message: toggleKey.isEmpty
                    ? "Option-click a line number or right-click the editor gutter to bookmark lines as you trace code."
                    : "Press \(toggleKey), Option-click a line number, or right-click the editor gutter to bookmark lines as you trace code.",
                actionTitle: workspace.activeFilePath.isEmpty ? nil : KeymapStore.shared.labeled("Bookmark Current Line", "navigate.toggleBookmark"),
                action: workspace.activeFilePath.isEmpty ? nil : { workspace.toggleBookmarkAtCaret() }
            )
        case .breakpoints:
            UnifiedEmptyState.empty(
                symbol: "arrowshape.right",
                title: "No Breakpoints",
                message: "A breakpoint pauses your program while you debug it, so you can inspect its state. Click a line number in a Go file to stop at that line, or add a function breakpoint to stop each time a function starts.",
                actionTitle: KeymapStore.shared.labeled("Add Function Breakpoint…", "debug.addFunctionBreakpoint"),
                action: { workspace.presentAddFunctionBreakpoint() }
            )
        case .safety:
            UnifiedEmptyState.empty(
                symbol: "checkmark.shield",
                badge: "safety",
                title: "No Safety Findings",
                message: "Run a workspace safety audit to scan for race hazards, vulnerabilities, and capability risks.",
                actionTitle: KeymapStore.shared.labeled("Run Safety Audit", "product.safetyAudit"),
                action: { workspace.runSafetyAudit() }
            )
        case .all, .errors, .warnings:
            UnifiedEmptyState.empty(
                symbol: "checkmark.circle",
                badge: "issues",
                title: "No Issues",
                message: GopherLore.emptyIssuesSubtitle(themeId: workspace.selectedThemeId, costume: mascotCostume)
            )
        }
    }

    private func sectionTitle(for key: String, sample: UnifiedDiagnosticItem?) -> String {
        guard let sample, !sample.path.isEmpty else { return key }
        let fileName = (sample.path as NSString).lastPathComponent
        let relDir = (sample.relativePath as NSString).deletingLastPathComponent
        return (relDir.isEmpty || relDir == ".") ? fileName : "\(fileName) — \(relDir)"
    }

    private func diagnosticRow(_ item: UnifiedDiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.row) {
            if let breakpoint = item.breakpoint {
                Button {
                    workspace.setBreakpoint(breakpoint, enabled: !item.isEnabled)
                } label: {
                    rowSymbol(item)
                }
                .buttonStyle(.plain)
                .help(item.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint")
                .accessibilityLabel(item.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint")
            }
            Button {
                selectedItemID = item.id
                jump(to: item)
            } label: {
                HStack(alignment: .top, spacing: Spacing.row) {
                    if item.breakpoint == nil {
                        rowSymbol(item)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(ChromeColor.textPrimary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(ChromeColor.textSecondary)
                                .lineLimit(2)
                        }

                        HStack(spacing: Spacing.compact) {
                            if let badge = item.badgeLabel, !badge.isEmpty {
                                Text(badge)
                                    .font(TechnicalTypography.badgeMicro)
                                    .foregroundStyle(ChromeColor.textSecondary)
                                    .padding(.horizontal, Spacing.compact)
                                    .padding(.vertical, Spacing.hairline)
                                    .wellBackground(cornerRadius: CornerRadius.small)
                            }
                            if item.line > 0 {
                                Text("Ln \(item.line)")
                                    .font(TechnicalTypography.metricMono)
                                    .foregroundStyle(ChromeColor.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.line > 0 ? "\(item.relativePath):\(item.line)\n\(item.title)" : item.detail.map { "\(item.title)\n\($0)" } ?? item.title)

            if let quickFix = item.quickFix {
                Button {
                    center.performQuickFix(quickFix, in: workspace)
                } label: {
                    Image(systemName: quickFix.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ThemeColor.accent)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.compact)
                        .wellBackground(cornerRadius: CornerRadius.small)
                }
                .buttonStyle(.plain)
                .help(quickFix.helpText)
                .accessibilityLabel("\(quickFix.buttonTitle): \(item.title)")
            }
        }
        .contextMenu {
            if !item.path.isEmpty {
                Button("Jump to Source", systemImage: "arrow.up.forward.square") {
                    jump(to: item)
                }
            }
            if let breakpoint = item.breakpoint {
                Button(item.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint",
                       systemImage: item.isEnabled ? "arrowshape.right" : "arrowshape.right.fill") {
                    workspace.setBreakpoint(breakpoint, enabled: !item.isEnabled)
                }
            }
            if let quickFix = item.quickFix {
                Button(quickFix.helpText, systemImage: quickFix.symbolName) {
                    center.performQuickFix(quickFix, in: workspace)
                }
            }
            if item.source == .bookmark {
                Divider()
                Button("Clear All Bookmarks", systemImage: "trash", role: .destructive) {
                    workspace.clearAllBookmarks()
                }
            }
        }
    }

    private func rowSymbol(_ item: UnifiedDiagnosticItem) -> some View {
        Image(systemName: item.symbolName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(item.tint)
            .frame(width: 14, alignment: .center)
            .padding(.top, Spacing.hairline)
    }

    private func removeSelected(in items: [UnifiedDiagnosticItem]) {
        guard let currentID = selectedItemID,
              let match = items.first(where: { $0.id == currentID }),
              match.isRemovable, let quickFix = match.quickFix else { return }
        center.performQuickFix(quickFix, in: workspace)
        selectedItemID = nil
    }

    private func jump(to item: UnifiedDiagnosticItem) {
        guard !item.path.isEmpty else { return }
        workspace.jumpTo(filePath: item.path, line: item.line, column: item.column)
    }

    private func moveSelection(by delta: Int, in items: [UnifiedDiagnosticItem]) {
        guard !items.isEmpty else { return }
        if let currentID = selectedItemID,
           let idx = items.firstIndex(where: { $0.id == currentID }) {
            let next = min(max(0, idx + delta), items.count - 1)
            selectedItemID = items[next].id
        } else {
            selectedItemID = delta >= 0 ? items.first?.id : items.last?.id
        }
    }

    private func openSelected(in items: [UnifiedDiagnosticItem]) {
        if let currentID = selectedItemID,
           let match = items.first(where: { $0.id == currentID }) {
            jump(to: match)
        } else if let first = items.first {
            selectedItemID = first.id
            jump(to: first)
        }
    }
}
