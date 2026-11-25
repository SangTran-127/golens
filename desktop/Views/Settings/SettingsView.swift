import SwiftUI

struct SettingsPane: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let content: () -> AnyView

    init<Content: View>(_ id: String, _ title: String, _ symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = { AnyView(content()) }
    }

    static let all: [SettingsPane] = [
        SettingsPane("general", "General", "gearshape") { GeneralSettingsPane() },
        SettingsPane("editor", "Editing", "character.cursor.ibeam") { EditingSettingsPane() },
        SettingsPane("codeChecks", "Code Checks", "checklist") { CodeChecksSettingsPane() },
        SettingsPane("container", "Execution", "cpu") { ContainerSettingsPane() },
        SettingsPane("sourceControl", "Source Control", "arrow.triangle.branch") { SourceControlSettingsPane() },
        SettingsPane("keyBindings", "Key Bindings", "keyboard") { KeyBindingsSettingsPane() },
        SettingsPane("gopilot", "Gopilot", "sparkles") { GopilotSettingsPane() },
    ]
}

enum SettingsPage: String {
    case inlayHints
    case goToolchains
    case aiSuggestions
    case liveTemplates

    static let pendingKey = "GoLensSettingsPendingPage"

    var title: String {
        switch self {
        case .inlayHints: "Inlay Hints"
        case .goToolchains: "Installed Go Versions"
        case .aiSuggestions: "AI Suggestions"
        case .liveTemplates: "Live Templates"
        }
    }

    var paneID: String {
        switch self {
        case .inlayHints, .aiSuggestions, .liveTemplates: "editor"
        case .goToolchains: "container"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .inlayHints: InlayHintsSettingsPage()
        case .goToolchains: GoToolchainsSettingsPage()
        case .aiSuggestions: AISuggestionsSettingsPage()
        case .liveTemplates: LiveTemplatesSettingsPage()
        }
    }
}

private struct SettingsRoute: Equatable {
    var pane: String
    var page: SettingsPage?
}

private struct OpenSettingsPageKey: EnvironmentKey {
    static let defaultValue: (SettingsPage) -> Void = { _ in }
}

private struct OpenSettingsPaneKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var openSettingsPage: (SettingsPage) -> Void {
        get { self[OpenSettingsPageKey.self] }
        set { self[OpenSettingsPageKey.self] = newValue }
    }

    var openSettingsPane: (String) -> Void {
        get { self[OpenSettingsPaneKey.self] }
        set { self[OpenSettingsPaneKey.self] = newValue }
    }
}

struct SettingsView: View {
    @AppStorage("GoLensSettingsPane") private var paneID = SettingsPane.all[0].id
    @AppStorage(SettingsPage.pendingKey) private var pendingPage = ""
    @State private var page: SettingsPage?
    @State private var backStack: [SettingsRoute] = []
    @State private var forwardStack: [SettingsRoute] = []

    private var pane: SettingsPane {
        SettingsPane.all.first { $0.id == paneID } ?? SettingsPane.all[0]
    }

    private var route: SettingsRoute { SettingsRoute(pane: pane.id, page: page) }

    private var sidebarSelection: Binding<String?> {
        Binding(get: { pane.id }, set: { id in
            guard let id else { return }
            paneID = id
            page = nil
            backStack.removeAll()
            forwardStack.removeAll()
        })
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.all, selection: sidebarSelection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .foregroundStyle(.primary)
                }
                .tag(pane.id)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                if let page {
                    page.content
                } else {
                    pane.content()
                }
            }
            .environment(\.openSettingsPage) { navigate(to: SettingsRoute(pane: pane.id, page: $0)) }
            .environment(\.openSettingsPane) { navigate(to: SettingsRoute(pane: $0, page: nil)) }
            .navigationTitle(page?.title ?? pane.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button(action: goBack) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back")
                        .keyboardShortcut(KeymapStore.shared.shortcut("navigate.back"))
                        .disabled(backStack.isEmpty)

                        Button(action: goForward) {
                            Label("Forward", systemImage: "chevron.right")
                        }
                        .help("Forward")
                        .keyboardShortcut(KeymapStore.shared.shortcut("navigate.forward"))
                        .disabled(forwardStack.isEmpty)
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        .background(SettingsWindowChrome())
        .onAppear(perform: openPendingPage)
        .onChange(of: pendingPage) { _, _ in openPendingPage() }
        .sheetFrame(.settings)
        .frame(minHeight: 400, maxHeight: .infinity)
    }

    private func openPendingPage() {
        guard let target = SettingsPage(rawValue: pendingPage) else { return }
        pendingPage = ""
        navigate(to: SettingsRoute(pane: target.paneID, page: target))
    }

    private func navigate(to target: SettingsRoute) {
        guard target != route else { return }
        backStack.append(route)
        forwardStack.removeAll()
        show(target)
    }

    private func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(route)
        show(target)
    }

    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(route)
        show(target)
    }

    private func show(_ target: SettingsRoute) {
        paneID = target.pane
        page = target.page
    }
}

private struct SettingsWindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        private var observer: NSObjectProtocol?
        private var sized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            apply()
            if !sized {
                sized = true
                if UserDefaults.standard.object(forKey: "NSWindow Frame \(window.frameAutosaveName)") == nil {
                    var frame = window.frame
                    frame.origin.y -= 720 - frame.height
                    frame.size.height = 720
                    window.setFrame(frame, display: true)
                }
            }
        }

        private func apply() {
            guard let window else { return }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            if let zoom = window.standardWindowButton(.zoomButton), zoom.isEnabled { zoom.isEnabled = false }
        }
    }

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {}
}
