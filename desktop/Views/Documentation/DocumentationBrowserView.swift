import AppKit
import GoLensFoundation
import SwiftUI

struct DocumentationWindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                DocumentationService.shared.registerOpenWindowHandler { root in
                    openWindow(id: DocumentationBrowserView.windowID, value: root)
                }
            }
    }
}

private struct DocumentationWindowHostBridge: NSViewRepresentable {
    let session: DocumentationBrowserSession
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { attachWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attachWindow(for: nsView) }
    }

    private func attachWindow(for view: NSView) {
        guard let window = view.window else { return }
        session.hostWindow = window
        if window.title != title {
            window.title = title
        }
    }
}

struct DocumentationBrowserView: View {
    static let windowID = "documentation-browser"

    let workspaceRoot: String
    @State private var showTargetPopover = false
    @State private var showDownloadDetails = false

    private var session: DocumentationBrowserSession {
        DocumentationService.shared.session(forWorkspaceRoot: workspaceRoot)
    }

    private var windowTitle: String {
        session.root.isEmpty ? "Documentation Browser" : "Documentation — \(session.workspaceName)"
    }

    var body: some View {
        @Bindable var bindableSession = session

        Group {
            if session.root.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "book",
                    title: "No Project Open",
                    message: "Open a project to browse its documentation.",
                    actionTitle: "Open Project",
                    action: { WorkspaceSessionRegistry.shared.activeWorkspace.pickDirectory() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ThemeColor.contentSurface)
            } else {
                NavigationSplitView {
                    DocumentationSidebarView(session: session)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } detail: {
                    detailColumn(session: bindableSession)
                }
                .toolbar {
                    browserToolbar(session: bindableSession)
                }
                .onAppear {
                    session.consumePendingSearchFocus()
                }
                .onChange(of: session.pendingSearchFocus) { _, pending in
                    if pending { session.consumePendingSearchFocus() }
                }
            }
        }
        .background(DocumentationWindowHostBridge(session: session, title: windowTitle))
        .navigationTitle(windowTitle)
        .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
        .task(id: session.root) {
            session.prepareOnOpen()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                session.checkFreshness()
            }
        }
        .onAppear {
            session.checkFreshness()
            session.consumePendingSearchFocus()
        }
        .alert(item: $bindableSession.pendingDownload) { item in
            let spec = item.version.isEmpty ? item.module : "\(item.module)@\(item.version)"
            return Alert(
                title: Text("Download \(spec)?"),
                message: Text("GoLens will run go mod download \(spec) without modifying go.mod or go.sum."),
                primaryButton: .default(Text("Download Dependency")) {
                    session.confirmDownloadDependency()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Open External Documentation?",
            isPresented: Binding(
                get: { session.pendingExternalURL != nil },
                set: { if !$0 { session.pendingExternalURL = nil } }
            )
        ) {
            Button("Open in Browser") { session.confirmOpenExternal() }
            Button("Cancel", role: .cancel) { session.pendingExternalURL = nil }
        } message: {
            Text("External documentation may describe a different version.")
        }
    }

    @ViewBuilder
    private func detailColumn(session: DocumentationBrowserSession) -> some View {
        VStack(spacing: 0) {
            if session.isWorkspaceClosed {
                InlineBanner(.status(.warning), title: "This project is closed. Showing saved documentation.") {
                    Button("Open Project") {
                        WorkspaceSessionRegistry.shared.openProject(at: session.root)
                    }
                    .buttonStyle(.bordered)
                }
            } else if session.isRemoteTarget {
                InlineBanner(
                    .status(.info),
                    title: "Showing documentation from local source.",
                    message: "Remote target active (\(session.target.displayLabel))."
                )
            }

            if let failure = session.downloadFailure {
                InlineBanner(
                    .status(.failure),
                    title: failure.summary,
                    detail: showDownloadDetails ? failure.details : "\(failure.module)@\(failure.version)",
                    onClose: { session.downloadFailure = nil }
                ) {
                    Button("Retry") {
                        session.requestDownload(module: failure.module, version: failure.version)
                        session.confirmDownloadDependency()
                    }
                    .buttonStyle(.bordered)
                    Button(showDownloadDetails ? "Hide Details" : "Show Details") {
                        showDownloadDetails.toggle()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if session.isDownloading {
                InlineBanner(.status(.info), title: "Downloading dependency source…")
            }

            if session.isSearchResultsVisible {
                searchResultsView
            } else {
                DocumentationPageView(session: session, showTargetPopover: $showTargetPopover)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.contentSurface)
    }

    @ViewBuilder
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Picker("Search Scope", selection: Binding(
                    get: { session.searchScope },
                    set: { next in
                        session.searchScope = next
                        if next == .stdlib && !session.includeStd { session.includeStd = true }
                        session.runSearch()
                    }
                )) {
                    ForEach(DocsSearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                Spacer(minLength: Spacing.standard)

                if session.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(UserMessage.quantity(session.searchResults.count, "result"))
                        .font(.caption)
                        .foregroundStyle(ThemeColor.textSecondary)
                }

                Button("Done") { session.isSearchResultsVisible = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .background(ThemeColor.panelSurface)
            .overlay(alignment: .bottom) { Divider() }

            if session.isSearching && session.searchResults.isEmpty {
                UnifiedEmptyState.loading(message: "Searching packages and symbols…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.searchResults.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "magnifyingglass",
                    title: "No symbols match your search.",
                    message: "Try another name or reset the search filters.",
                    actionTitle: "Clear Search",
                    action: { session.clearSearchAndFilters() },
                    secondaryActionTitle: session.searchScope != .all ? "Reset Filters" : nil,
                    secondaryAction: session.searchScope != .all ? {
                        session.searchScope = .all
                        session.runSearch()
                    } : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(session.searchResults) { hit in
                    Button {
                        session.navigate(to: .package(importPath: hit.importPath, symbol: hit.symbol))
                    } label: {
                        searchRowLabel(hit)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
    }

    private func searchRowLabel(_ hit: DocsSearchResultDTO) -> some View {
        HStack(spacing: Spacing.standard) {
            SymbolIconView(kind: hit.kind == "package" ? "package" : hit.kind, isSelected: false, size: 16)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.row) {
                    Text(hit.symbol?.isEmpty == false ? hit.symbol! : (hit.packageName ?? hit.importPath))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(ThemeColor.textPrimary)
                    if hit.excluded == true {
                        Text(hit.build?.isEmpty == false ? "Excluded (\(hit.build!))" : "Excluded")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(StatusTone.warning.tint)
                            .padding(.horizontal, Spacing.compact)
                            .padding(.vertical, Spacing.hairline)
                            .background(Capsule().fill(StatusTone.warning.fill))
                    }
                    if hit.missing == true {
                        Text("Not Downloaded")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(StatusTone.warning.tint)
                    }
                }
                HStack(spacing: Spacing.row) {
                    Text(hit.importPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ver = hit.version, !ver.isEmpty {
                        Text(ver)
                            .font(.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                    } else if hit.source == "local-replace" {
                        Text("Local replacement")
                            .font(.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                    }
                }
            }
            Spacer(minLength: Spacing.standard)
            Text(hit.origin.capitalized)
                .font(.caption2.weight(.medium))
                .foregroundStyle(ThemeColor.textSecondary)
        }
        .padding(.vertical, Spacing.hairline)
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private func browserToolbar(session: DocumentationBrowserSession) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    session.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!session.history.canGoBack)
                .help("Navigate back")
                .keyboardShortcut(KeymapStore.shared.shortcut("navigate.back"))

                Button {
                    session.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!session.history.canGoForward)
                .help("Navigate forward")
                .keyboardShortcut(KeymapStore.shared.shortcut("navigate.forward"))
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItem(placement: .principal) {
            PanelFilterBar(
                placeholder: "Search Packages and Symbols",
                text: Binding(
                    get: { session.searchQuery },
                    set: { session.updateSearchQuery($0) }
                ),
                accessibilityTitle: "Search Documentation",
                focusTrigger: session.searchFocusTrigger,
                onSubmit: {
                    if let first = session.searchResults.first {
                        session.navigate(to: .package(importPath: first.importPath, symbol: first.symbol))
                    } else {
                        session.runSearch()
                    }
                },
                onEscapeWhenEmpty: { session.clearSearchAndFilters() }
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(
                get: { session.includeUnexported },
                set: { _ in session.toggleIncludeUnexported() }
            )) {
                Label("Include Unexported", systemImage: "eye")
            }
            .help("Include unexported symbols in workspace and local replacement packages")
            .accessibilityLabel("Include Unexported")

            Button {
                session.refreshCurrent()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(session.isLoadingIndex || session.isLoadingPage)
            .help("Refresh documentation")
            .accessibilityLabel("Refresh")

            Button {
                session.openPackageSource()
            } label: {
                Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(session.packageSourceLocation() == nil)
            .help("Open package source in the editor")
            .accessibilityLabel("Open Source")
        }
    }
}
