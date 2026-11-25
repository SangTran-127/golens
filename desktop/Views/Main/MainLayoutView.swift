import SwiftUI

struct MainLayoutView: View {
    @Bindable var workspace: WorkspaceState
    @State private var popoverSize: CGSize = .zero
    @State private var detailToolbarWidth: CGFloat = 940
    @State private var isShowingZoomHUD = false
    @State private var zoomTask: Task<Void, Never>? = nil
    @State private var doubleShiftDetector = DoubleShiftDetector()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var windowTitle: String {
        if !workspace.activeWorkspacePath.isEmpty {
            return (workspace.activeWorkspacePath as NSString).lastPathComponent
        }
        return "GoLens"
    }

    private var windowSubtitle: String {
        guard !workspace.activeWorkspacePath.isEmpty else { return "" }
        return workspace.git.branchName
    }

    private var windowDocumentURL: URL {
        if !workspace.activeWorkspacePath.isEmpty {
            return URL(fileURLWithPath: workspace.activeWorkspacePath)
        }
        return URL(fileURLWithPath: "/")
    }

    var body: some View {
        let _ = measureStartupOnce("layout-body")
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                NavigationSplitView(columnVisibility: Binding(
                    get: { workspace.isSidebarVisible ? .all : .detailOnly },
                    set: { workspace.isSidebarVisible = $0 != .detailOnly }
                )) {
                    SidebarView(workspace: workspace)
                        .navigationSplitViewColumnWidth(
                            min: WindowLayout.sidebarMinWidth,
                            ideal: WindowLayout.sidebarIdealWidth,
                            max: WindowLayout.sidebarMaxWidth
                        )
                } detail: {
                    MainDetailView(workspace: workspace)
                        .equatable()
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            if width > 0 {
                                detailToolbarWidth = width
                            }
                        }
                }
                .navigationSplitViewStyle(.balanced)
                .navigationTitle(windowTitle)
                .navigationSubtitle(windowSubtitle)
                .navigationDocument(windowDocumentURL)
                .modifier(HidesSystemWindowTitle())

                StatusBarView(workspace: workspace)
            }

            MainFloatingPopups(workspace: workspace)
        }
        .onAppear {
            workspace.setup()
            doubleShiftDetector.start(workspace: workspace)
        }
        .onDisappear {
            doubleShiftDetector.stop()
        }
        .toolbar {
            MainToolbar(
                workspace: workspace,
                availableWidth: max(360, detailToolbarWidth - (workspace.isSidebarVisible ? 0 : 116))
            )
        }
        .modifier(WindowPresentationRouterModifier(workspace: workspace))
        .onChange(of: workspace.activeWorkspacePath) {
            workspace.sourceControl.sheet = nil
            workspace.sourceControl.resetCommitDraft()
        }
        .onChange(of: workspace.lsp.hoverText) {
            popoverSize = .zero
        }
        .onChange(of: workspace.editorFontSize) {
            withAnimation(reduceMotion ? nil : Motion.quick) {
                isShowingZoomHUD = true
            }
            zoomTask?.cancel()
            zoomTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(reduceMotion ? nil : Motion.standard) {
                        isShowingZoomHUD = false
                    }
                }
            }
        }
        .overlay {
            MainPopupLayer(workspace: workspace)

            if isShowingZoomHUD {
                VStack {
                    Spacer()
                    let percentage = Int((workspace.editorFontSize / 13.0) * 100)
                    Text("Zoom: \(percentage)%")
                        .font(.body.weight(.medium).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Spacing.section)
                        .padding(.vertical, Spacing.standard)
                        .floatingPanelBackground(cornerRadius: CornerRadius.hud)
                        .floatingHudTransition()
                        .padding(.bottom, Spacing.hudBottomOffset)
                }
            }
        }
        .background(WindowReader { window in
            if workspace.mainWindow !== window {
                workspace.mainWindow = window
                workspace.updateWindowAppearance()
            }
            MainToolbar.applyItemPriorities(to: window.toolbar)
        })
        .onChange(of: workspace.editedFiles.isEmpty, initial: true) { _, isEmpty in
            workspace.mainWindow?.isDocumentEdited = !isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            workspace.autoSaveEditedDocumentsIfEnabled()
            workspace.dismissTransientEditorOverlays(includeRename: false, includePopovers: false)
        }
    }
}

private struct MainFloatingPopups: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            FloatingPopup(isPresented: workspace.lsp.hoverText != nil,
                          origin: CGPoint(x: max(10, min(width - 410, workspace.lsp.hoverRect.midX - 200)), y: workspace.lsp.hoverRect.maxY + 8),
                          anchor: PopupAnchor(rect: workspace.lsp.hoverRect, bounds: workspace.lsp.hoverBounds)) {
                HoverPopoverView(text: workspace.lsp.hoverText ?? "")
            }
            let quickDocumentation = workspace.lsp.quickDocumentation
            FloatingPopup(isPresented: quickDocumentation != nil,
                          origin: QuickDocumentationPopoverView.origin(for: quickDocumentation, in: width),
                          anchor: quickDocumentation.map { PopupAnchor(rect: $0.anchor, bounds: $0.bounds) },
                          acceptsKeyboard: quickDocumentation?.takesFocus ?? false,
                          onCancel: { workspace.lsp.quickDocumentation?.editor?.closeQuickDocumentation() }) {
                if let quickDocumentation {
                    QuickDocumentationPopoverView(request: quickDocumentation)
                }
            }
            FloatingPopup(isPresented: workspace.lsp.signatureHelp != nil,
                          origin: CGPoint(x: max(10, min(width - 396, workspace.lsp.signatureHelpRect.origin.x)), y: workspace.lsp.signatureHelpRect.maxY + 8),
                          anchor: PopupAnchor(rect: workspace.lsp.signatureHelpRect, bounds: workspace.lsp.signatureHelpBounds)) {
                if let signatureHelp = workspace.lsp.signatureHelp {
                    SignatureHelpPopupView(helpData: signatureHelp)
                }
            }
            let issueBounds = workspace.issuePopup?.anchorBounds ?? .zero
            let issueViewportWidth = issueBounds.width > 0 ? issueBounds.width : width
            let issueEstWidth = max(260, min(520, issueViewportWidth - 32))
            let issueMinX = issueBounds.isEmpty ? 10 : issueBounds.minX + 8
            let issueMaxX = issueBounds.isEmpty ? max(10, width - issueEstWidth - 10) : max(issueMinX, issueBounds.maxX - issueEstWidth - 8)
            FloatingPopup(isPresented: workspace.issuePopup != nil,
                          origin: CGPoint(x: max(issueMinX, min(issueMaxX, workspace.issuePopup?.origin.x ?? 0)), y: workspace.issuePopup?.origin.y ?? 0),
                          anchor: workspace.issuePopup.map { PopupAnchor(rect: $0.anchorRect, bounds: $0.anchorBounds) },
                          acceptsKeyboard: true,
                          onCancel: {
                              workspace.issuePopup = nil
                              if let tv = workspace.editorTextView(for: workspace.effectiveFocusedPaneID) ?? workspace.activeTextView {
                                  tv.window?.makeFirstResponder(tv)
                              }
                          }) {
                if let popup = workspace.issuePopup {
                    IssuePopupView(popup: popup, viewportWidth: issueViewportWidth)
                }
            }
            FloatingPopup(isPresented: workspace.renameHint != nil,
                          origin: CGPoint(x: max(Spacing.inset, min(width - PopupWidth.compact.rawValue, workspace.renameRect.origin.x)), y: workspace.renameRect.maxY + Spacing.standard),
                          anchor: PopupAnchor(rect: workspace.renameRect, bounds: workspace.renameBounds)) {
                if let hint = workspace.renameHint {
                    InlineRenameHintView(hint: hint)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MainPopupLayer: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        ZStack(alignment: .top) {
            if let popup = workspace.activePopup {
                Color.clear
                    .rowButton { workspace.activePopup = nil }
                    .focusable(false)
                    .accessibilityHidden(true)
                Group {
                    switch popup {
                    case .recentFiles:
                        RecentFilesPopupView(workspace: workspace)
                    case .openQuickly, .goToSymbol, .workspaceSymbol, .commandPalette:
                        OmniFinderView(workspace: workspace, initialPopup: popup)
                    case .references:
                        ReferencesPopupView()
                    case .hierarchy:
                        HierarchyPopupView()
                    case .surroundWith:
                        SurroundWithPopupView(workspace: workspace)
                    case .queryHistory:
                        QueryHistoryPopupView(workspace: workspace)
                    }
                }
                .padding(.top, FinderPopup.topInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? WindowObserverView {
            view.onWindow = onWindow
            if let window = view.window {
                onWindow(window)
            }
        }
    }

    private final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

private final class DoubleShiftDetector {
    private var monitor: Any?
    private var isShiftDown = false
    private var shiftDownTimestamp: TimeInterval?
    private var lastShiftReleaseTimestamp: TimeInterval?
    private var invalidatedDuringHold = false

    func start(workspace: WorkspaceState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak workspace] event in
            guard let self, let workspace else { return event }
            self.handleEvent(event, workspace: workspace)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        reset()
    }

    private func reset() {
        isShiftDown = false
        shiftDownTimestamp = nil
        lastShiftReleaseTimestamp = nil
        invalidatedDuringHold = false
    }

    private func handleEvent(_ event: NSEvent, workspace: WorkspaceState) {
        guard workspace.mainWindow == nil || workspace.mainWindow === NSApp.keyWindow else {
            reset()
            return
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let winClass = event.window.map { NSStringFromClass(type(of: $0)) } ?? ""
            if !winClass.contains("PopupPanel") {
                let hitInEditor = (event.window?.contentView?.hitTest(event.locationInWindow)) is GoLensTextView
                if !hitInEditor, (workspace.lsp.hoverText != nil || workspace.lsp.signatureHelp != nil || workspace.issuePopup != nil) {
                    workspace.dismissTransientEditorOverlays(includeRename: false, includePopovers: false)
                }
            }
        }

        guard workspace.enableDoubleShiftSearch,
              workspace.mainWindow?.attachedSheet == nil,
              NSApp.keyWindow?.isSheet != true else {
            reset()
            return
        }

        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown:
            shiftDownTimestamp = nil
            lastShiftReleaseTimestamp = nil
            invalidatedDuringHold = true
        case .flagsChanged:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let otherMods: NSEvent.ModifierFlags = [.command, .option, .control, .capsLock, .function]
            if !mods.intersection(otherMods).isEmpty {
                shiftDownTimestamp = nil
                lastShiftReleaseTimestamp = nil
                invalidatedDuringHold = mods.contains(.shift)
                isShiftDown = mods.contains(.shift)
                return
            }

            let shiftActive = mods.contains(.shift)
            let now = ProcessInfo.processInfo.systemUptime

            if shiftActive {
                if !isShiftDown {
                    isShiftDown = true
                    invalidatedDuringHold = false
                    if !invalidatedDuringHold {
                        shiftDownTimestamp = now
                    }
                } else {
                    shiftDownTimestamp = nil
                    lastShiftReleaseTimestamp = nil
                    invalidatedDuringHold = true
                }
            } else if isShiftDown {
                isShiftDown = false
                defer {
                    shiftDownTimestamp = nil
                    invalidatedDuringHold = false
                }
                guard let downTime = shiftDownTimestamp, !invalidatedDuringHold else {
                    lastShiftReleaseTimestamp = nil
                    return
                }
                let pressDuration = now - downTime
                guard pressDuration >= 0.015 && pressDuration <= 0.22 else {
                    lastShiftReleaseTimestamp = nil
                    return
                }
                if let prevRelease = lastShiftReleaseTimestamp,
                   now - prevRelease >= 0.04 && now - prevRelease <= 0.32 {
                    lastShiftReleaseTimestamp = nil
                    if workspace.showCommandPalette {
                        workspace.showCommandPalette = false
                    }
                    workspace.showOpenQuickly.toggle()
                } else {
                    lastShiftReleaseTimestamp = now
                }
            }
        default:
            break
        }
    }
}

private struct HidesSystemWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(removing: .title)
    }
}
