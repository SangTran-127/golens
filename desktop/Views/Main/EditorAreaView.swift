import SwiftUI
import AppKit
import GoLensFoundation

struct EditorAreaView: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            if workspace.openFiles.isEmpty || workspace.sourceControl.editorSurface != nil {
                CommandFeedbackPresenter(workspace: workspace)
            }
            switch workspace.sourceControl.editorSurface {
            case .history:
                GitHistoryView()
                    .onChange(of: workspace.activeFilePath) { workspace.closeSourceControlSurface() }
                    .onChange(of: workspace.activeWorkspacePath) { workspace.closeSourceControlSurface() }
            case .commit:
                CommitEditorView(workspace: workspace)
                    .onChange(of: workspace.activeFilePath) { old, _ in
                        if workspace.openFiles.contains(old) { workspace.closeSourceControlSurface() }
                    }
                    .onChange(of: workspace.activeWorkspacePath) { workspace.closeSourceControlSurface() }
            case .mergeEditor(let path):
                MergeEditorView(path: path)
                    .id(path)
            case nil:
                editorBody
            }
        }
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            if !workspace.openFiles.isEmpty {
                TabBarView(workspace: workspace)
                    .frame(minWidth: 0, maxWidth: .infinity)

                Divider()

                if !workspace.isSplitMode {
                    BreadcrumbBarView(workspace: workspace, paneID: .primary, isFocused: true)
                        .padding(.horizontal, Spacing.section)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 28)
                        .background(ThemeColor.panelSurface)

                    Divider()
                }

                CommandFeedbackPresenter(workspace: workspace)
            }

            EditorHorizontalSplitView(
                isSplitMode: workspace.isSplitMode,
                primaryContent: {
                    primaryPaneContent
                },
                secondaryContent: {
                    secondaryPaneContent
                }
            )
            .frame(minHeight: 240)
            .background(ThemeColor.editorSurface)
        }
        .onChange(of: workspace.activeFilePath, initial: true) { _, path in
            if WorkspaceState.isDockerFile(path) { workspace.refreshDockerStatus() }
        }
    }

    private var primaryPaneContent: some View {
        VStack(spacing: 0) {
            if workspace.isSplitMode && !workspace.openFiles.isEmpty {
                SplitEditorPaneChromeBar(workspace: workspace, paneID: .primary)
                Divider()
            }
            if (workspace.git.conflictRegions[workspace.activeFilePath] != nil || workspace.git.conflictedPaths.contains(workspace.activeFilePath)),
               workspace.editorMode(for: workspace.activeFilePath) == .code {
                MergeConflictBanner(path: workspace.activeFilePath)
            }
            if let blocker = workspace.activeDockerBlocker {
                DockerEngineBanner(info: blocker)
            }
            if let oom = workspace.activeOOMFailure {
                OOMKilledBannerView(workspace: workspace, memoryLimit: oom.memoryLimit) {
                    workspace.dismissOOMBanner()
                }
            }
            NativeEditorView(paneID: .primary)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                    handleEditorDrop(providers: providers, intoSplitPane: false)
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var secondaryPaneContent: some View {
        VStack(spacing: 0) {
            SplitEditorPaneChromeBar(workspace: workspace, paneID: .secondary)
            Divider()
            if let secondary = workspace.secondaryFilePath,
               (workspace.git.conflictRegions[secondary] != nil || workspace.git.conflictedPaths.contains(secondary)),
               workspace.editorMode(for: secondary) == .code {
                MergeConflictBanner(path: secondary, inSplitPane: true)
            }
            NativeEditorView(paneID: .secondary, customFilePath: workspace.secondaryFilePath)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                    handleEditorDrop(providers: providers, intoSplitPane: true)
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func handleEditorDrop(providers: [NSItemProvider], intoSplitPane: Bool) -> Bool {
        if let tabPath = workspace.activeDraggedTabPath {
            workspace.activeDraggedTabPath = nil
            if intoSplitPane {
                workspace.isCounterpartSplitEnabled = false
                workspace.openFileInSplit(tabPath)
            } else {
                workspace.openFile(tabPath)
            }
            return true
        }
        if let navPath = workspace.activeDraggedNavigatorPath {
            workspace.activeDraggedNavigatorPath = nil
            let readOnly = !workspace.activeWorkspacePath.isEmpty && !navPath.hasPrefix(workspace.activeWorkspacePath + "/")
            if intoSplitPane {
                workspace.isCounterpartSplitEnabled = false
                workspace.openFileInSplit(navPath)
            } else {
                workspace.openFile(navPath, readOnly: readOnly)
            }
            return true
        }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let sourceURL = url else { return }
            DispatchQueue.main.async {
                let path = sourceURL.resolvingSymlinksInPath().path
                let readOnly = !workspace.activeWorkspacePath.isEmpty && !path.hasPrefix(workspace.activeWorkspacePath + "/")
                if intoSplitPane {
                    workspace.isCounterpartSplitEnabled = false
                    workspace.openFileInSplit(path)
                } else {
                    workspace.openFile(path, readOnly: readOnly)
                }
            }
        }
        return true
    }
}

struct SplitEditorPaneChromeBar: View {
    @Bindable var workspace: WorkspaceState
    let paneID: EditorPaneID

    private var isFocused: Bool {
        workspace.focusedPaneID == paneID
    }

    private var paneFilePath: String {
        workspace.filePath(for: paneID)
    }

    var body: some View {
        let fileName = (paneFilePath as NSString).lastPathComponent
        HStack(spacing: Spacing.standard) {
            BreadcrumbBarView(
                workspace: workspace,
                paneID: paneID,
                isFocused: isFocused
            )
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if paneID == .secondary {
                HStack(spacing: Spacing.row) {
                    Picker("Split Mode", selection: $workspace.isCounterpartSplitEnabled) {
                        Text("Manual").tag(false)
                        Text("Counterpart").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .accessibilityLabel("Split Mode")
                    .onChange(of: workspace.isCounterpartSplitEnabled) {
                        if workspace.isCounterpartSplitEnabled {
                            workspace.syncCounterpartFile()
                        }
                    }

                    Button {
                        guard let sec = workspace.secondaryFilePath, !sec.isEmpty else { return }
                        let primary = workspace.activeFilePath
                        workspace.isCounterpartSplitEnabled = false
                        workspace.openFile(sec)
                        workspace.secondaryFilePath = primary
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ThemeColor.textSecondary)
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.secondaryFilePath == nil || workspace.secondaryFilePath == workspace.activeFilePath)
                    .help("Swap Left and Right Editor Panes")
                    .accessibilityLabel("Swap Left and Right Editor Panes")

                    Button(action: { workspace.closeSecondarySplitPane() }) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ThemeColor.textSecondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Close Split Editor")
                    .accessibilityLabel("Close Split Pane \(fileName)")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .frame(height: 28)
        .background {
            Button {
                workspace.focusPane(paneID)
            } label: {
                ThemeColor.panelSurface
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if isFocused {
                Rectangle()
                    .fill(ChromeColor.accent)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct EditorHorizontalSplitView<Primary: View, Secondary: View>: NSViewRepresentable {
    static var ratioKey: String { "GoLensEditorSplitRatio" }
    static var minPaneWidth: CGFloat { 300 }

    let isSplitMode: Bool
    @Environment(\.windowWorkspace) private var windowWorkspace
    @Environment(WorkspaceSession.self) private var session: WorkspaceSession?
    let primaryContent: () -> Primary
    let secondaryContent: () -> Secondary

    init(
        isSplitMode: Bool,
        @ViewBuilder primaryContent: @escaping () -> Primary,
        @ViewBuilder secondaryContent: @escaping () -> Secondary
    ) {
        self.isSplitMode = isSplitMode
        self.primaryContent = primaryContent
        self.secondaryContent = secondaryContent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let leftHost = NSHostingView(rootView: AnyView(primaryContent().windowScope(windowWorkspace, session: session)))
        leftHost.sizingOptions = []
        leftHost.translatesAutoresizingMaskIntoConstraints = true

        let rightHost = NSHostingView(rootView: AnyView(EmptyView()))
        rightHost.sizingOptions = []
        rightHost.translatesAutoresizingMaskIntoConstraints = true

        context.coordinator.splitView = splitView
        context.coordinator.leftHost = leftHost
        context.coordinator.rightHost = rightHost

        splitView.addSubview(leftHost)
        if isSplitMode {
            rightHost.rootView = AnyView(secondaryContent().windowScope(windowWorkspace, session: session))
            splitView.addSubview(rightHost)
            context.coordinator.needsInitialDividerPlacement = true
        }
        splitView.adjustSubviews()
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.leftHost?.rootView = AnyView(primaryContent().windowScope(windowWorkspace, session: session))

        if isSplitMode {
            coordinator.rightHost?.rootView = AnyView(secondaryContent().windowScope(windowWorkspace, session: session))
            if let rightHost = coordinator.rightHost, rightHost.superview == nil {
                coordinator.isProgrammaticLayout = true
                splitView.addSubview(rightHost)
                rightHost.isHidden = false
                coordinator.applyRatio(in: splitView)
                coordinator.isProgrammaticLayout = false
            } else if coordinator.needsInitialDividerPlacement, splitView.bounds.width > 0 {
                coordinator.applyRatio(in: splitView)
            }
        } else {
            if let rightHost = coordinator.rightHost, rightHost.superview != nil {
                coordinator.isProgrammaticLayout = true
                rightHost.removeFromSuperview()
                rightHost.rootView = AnyView(EmptyView())
                splitView.adjustSubviews()
                coordinator.isProgrammaticLayout = false
            }
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var leftHost: NSHostingView<AnyView>?
        var rightHost: NSHostingView<AnyView>?
        var isProgrammaticLayout = false
        var needsInitialDividerPlacement = false
        var splitRatio: CGFloat = {
            let saved = CGFloat(UserDefaults.standard.double(forKey: "GoLensEditorSplitRatio"))
            return (saved >= 0.2 && saved <= 0.8) ? saved : 0.5
        }()

        private func effectiveMinWidth(for splitView: NSSplitView) -> CGFloat {
            let available = max(0, splitView.bounds.width - splitView.dividerThickness)
            if available >= 600 {
                return 300
            }
            return max(120, floor(available * 0.4))
        }

        func applyRatio(in splitView: NSSplitView) {
            guard splitView.subviews.count == 2 else { return }
            let total = splitView.bounds.width
            guard total > splitView.dividerThickness + 20 else {
                needsInitialDividerPlacement = true
                splitView.adjustSubviews()
                return
            }
            needsInitialDividerPlacement = false
            isProgrammaticLayout = true
            defer { isProgrammaticLayout = false }
            let minW = effectiveMinWidth(for: splitView)
            let usable = max(0, total - splitView.dividerThickness)
            let proposed = round(usable * splitRatio)
            let clamped = min(max(proposed, minW), max(minW, usable - minW))
            splitView.adjustSubviews()
            splitView.setPosition(clamped, ofDividerAt: 0)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, effectiveMinWidth(for: splitView))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let maxCoord = splitView.bounds.width - splitView.dividerThickness - effectiveMinWidth(for: splitView)
            return min(proposedMaximumPosition, max(effectiveMinWidth(for: splitView), maxCoord))
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            let bounds = splitView.bounds
            guard bounds.width > 0, bounds.height > 0 else {
                splitView.adjustSubviews()
                return
            }
            if splitView.subviews.count == 1, let only = splitView.subviews.first {
                only.frame = bounds
                return
            }
            guard splitView.subviews.count == 2 else {
                splitView.adjustSubviews()
                return
            }
            isProgrammaticLayout = true
            defer { isProgrammaticLayout = false }
            let divider = splitView.dividerThickness
            let usable = max(0, bounds.width - divider)
            let minW = effectiveMinWidth(for: splitView)
            let leftWidth = min(max(round(usable * splitRatio), minW), max(minW, usable - minW))
            let rightWidth = max(0, usable - leftWidth)
            splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            splitView.subviews[1].frame = NSRect(x: leftWidth + divider, y: 0, width: rightWidth, height: bounds.height)
            needsInitialDividerPlacement = false
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isProgrammaticLayout,
                  let splitView = notification.object as? NSSplitView,
                  splitView.subviews.count == 2 else { return }
            let usable = splitView.bounds.width - splitView.dividerThickness
            guard usable > 240 else { return }
            let leftWidth = splitView.subviews[0].frame.width
            let nextRatio = min(max(leftWidth / usable, 0.2), 0.8)
            if abs(nextRatio - splitRatio) > 0.002 {
                splitRatio = nextRatio
                UserDefaults.standard.set(Double(nextRatio), forKey: "GoLensEditorSplitRatio")
            }
        }
    }
}

struct MainDetailView: View, Equatable {
    @Bindable var workspace: WorkspaceState
    @AppStorage("GoLensGopilotPanelWidth") private var panelWidth: Double = Double(WindowLayout.gopilotIdealWidth)
    @State private var dragStartWidth: Double?
    @State private var detailWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let panelInset: CGFloat = Spacing.standard

    static func == (lhs: MainDetailView, rhs: MainDetailView) -> Bool {
        lhs.workspace === rhs.workspace
    }

    private var currentWindowWidth: CGFloat {
        NSApp.keyWindow?.contentLayoutRect.width
            ?? NSApp.mainWindow?.contentLayoutRect.width
            ?? 0
    }

    private var columnResolution: WorkspaceColumnLayoutMath.ColumnResolution {
        WorkspaceColumnLayoutMath.resolveDetailColumns(
            windowWidth: currentWindowWidth,
            detailWidth: detailWidth,
            isSidebarVisible: workspace.isSidebarVisible,
            isGopilotVisible: workspace.gopilot.isPanelVisible,
            requestedGopilotWidth: CGFloat(panelWidth),
            gopilotChromeInset: Self.panelInset * 2
        )
    }

    var body: some View {
        let resolution = columnResolution
        HStack(spacing: 0) {
            EditorConsoleSplitView(workspace: workspace, showConsole: workspace.showConsole)
                .frame(minWidth: WindowLayout.editorMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .transaction(value: workspace.gopilot.isPanelVisible) { $0.animation = nil }

            if workspace.gopilot.isPanelVisible {
                HStack(spacing: 0) {
                    GopilotPanelResizeHandle(
                        width: $panelWidth,
                        dragStartWidth: $dragStartWidth,
                        clampedWidth: resolution.clampedGopilotWidth,
                        maxAllowedWidth: min(
                            WindowLayout.gopilotMaxWidth,
                            max(
                                WindowLayout.gopilotMinWidth,
                                (detailWidth > 0 ? detailWidth : WindowLayout.defaultWidth) - WindowLayout.editorMinWidth - Self.panelInset * 2
                            )
                        )
                    )
                    .frame(width: Self.panelInset)

                    GopilotPanelView(workspace: workspace, gopilot: workspace.gopilot)
                        .frame(width: resolution.clampedGopilotWidth)
                        .frame(maxHeight: .infinity)
                        .modifier(GopilotPanelSurface())
                        .padding(.trailing, Self.panelInset)
                        .padding(.bottom, Self.panelInset)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            guard newWidth > 0 else { return }
            let previousWidth = detailWidth
            detailWidth = newWidth
            if workspace.gopilot.isPanelVisible,
               workspace.isSidebarVisible,
               previousWidth > 0,
               newWidth < previousWidth,
               newWidth < (WindowLayout.editorMinWidth + WindowLayout.gopilotMinWidth + Self.panelInset * 2) {
                workspace.isSidebarVisible = false
            }
        }
        .onChange(of: workspace.gopilot.isPanelVisible) { _, isVisible in
            guard isVisible else { return }
            if WorkspaceColumnLayoutMath.shouldAutoCollapseSidebarOnGopilotOpen(
                windowWidth: currentWindowWidth,
                detailWidth: detailWidth,
                isSidebarVisible: workspace.isSidebarVisible,
                gopilotChromeInset: Self.panelInset * 2
            ) {
                workspace.isSidebarVisible = false
            }
        }
        .animation(reduceMotion ? nil : Motion.standard, value: workspace.gopilot.isPanelVisible)
        .background(ThemeColor.editorSurface)
        .onAppear {
            workspace.gopilot.workspaceChanged(to: workspace.activeWorkspacePath)
        }
        .onChange(of: workspace.activeWorkspacePath) { _, path in workspace.gopilot.workspaceChanged(to: path) }
    }
}

private final class ResizeCursorRectNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}

private struct ResizeCursorRectBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeCursorRectNSView {
        ResizeCursorRectNSView(frame: .zero)
    }

    func updateNSView(_ nsView: ResizeCursorRectNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private struct GopilotPanelResizeHandle: View {
    @Binding var width: Double
    @Binding var dragStartWidth: Double?
    let clampedWidth: CGFloat
    let maxAllowedWidth: CGFloat

    private var effectiveMax: Double {
        Double(min(WindowLayout.gopilotMaxWidth, max(WindowLayout.gopilotMinWidth, maxAllowedWidth)))
    }

    var body: some View {
        ResizeCursorRectBridge()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let initial = dragStartWidth ?? Double(clampedWidth)
                        if dragStartWidth == nil {
                            dragStartWidth = initial
                        }
                        let proposed = initial - Double(value.translation.width)
                        width = min(max(proposed, Double(WindowLayout.gopilotMinWidth)), effectiveMax)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize Gopilot Panel")
            .accessibilityValue("\(Int(clampedWidth.rounded())) points")
            .accessibilityAdjustableAction { direction in
                let step = 20.0
                switch direction {
                case .increment:
                    width = min(max(Double(clampedWidth) + step, Double(WindowLayout.gopilotMinWidth)), effectiveMax)
                case .decrement:
                    width = min(max(Double(clampedWidth) - step, Double(WindowLayout.gopilotMinWidth)), effectiveMax)
                @unknown default:
                    break
                }
            }
    }
}
