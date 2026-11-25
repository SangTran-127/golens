import AppKit
import SwiftUI

struct WelcomeView: View {
    @Bindable var appEnvironment = AppEnvironment.shared
    @Bindable var sessionRegistry = WorkspaceSessionRegistry.shared
    @Bindable var toolSetup = ToolSetupStatus.shared
    @Bindable var getStarted = GetStartedProgress.shared
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"

    @State private var searchFilter = ""
    @State private var showCloneRepoSheet = false
    @State private var selection: String?
    @State private var titlebarHeight: CGFloat = 0
    @FocusState private var listFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var palette: WelcomePalette { WelcomePalette() }

    private var isHighContrast: Bool {
        colorSchemeContrast == .increased || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var welcomeMedallionImage: NSImage {
        let costumeKey = ThemeManager.shared.effectiveCostumeId(
            themeId: appEnvironment.selectedThemeId,
            costume: mascotCostume
        )
        if let url = AppResourceBundle.url(forResource: "welcome-medallion-\(costumeKey)", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return ThemeManager.shared.appIconImage(themeId: appEnvironment.selectedThemeId, costume: mascotCostume)
    }

    private var welcomeCanvasResourceName: String {
        let tone = colorScheme == .dark ? "dark" : "light"
        return isHighContrast ? "welcome-canvas-\(tone)-hc" : "welcome-canvas-\(tone)"
    }

    @ViewBuilder
    private var welcomeStudioBackground: some View {
        if let url = AppResourceBundle.url(forResource: welcomeCanvasResourceName, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .accessibilityHidden(true)
        } else if reduceTransparency {
            ChromeColor.panelSurface.ignoresSafeArea()
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    private var filteredRecents: [String] {
        guard !searchFilter.isEmpty else { return appEnvironment.recentProjects }
        return appEnvironment.recentProjects.filter { path in
            (path as NSString).lastPathComponent.localizedCaseInsensitiveContains(searchFilter)
                || path.localizedCaseInsensitiveContains(searchFilter)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            introPane
                .frame(width: WelcomeLayout.introWidth)
            recentsPane
                .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea()
        .frame(width: WelcomeLayout.windowWidth, height: WelcomeLayout.windowHeight - titlebarHeight)
        .background(WelcomeWindowConfigurator(titlebarHeight: $titlebarHeight))
        .sheet(isPresented: $sessionRegistry.showWelcomeNewProjectSheet) {
            NewProjectSheetView()
        }
        .sheet(isPresented: $showCloneRepoSheet) {
            GitCloneSheetView()
        }
        .onAppear {
            sessionRegistry.openWorkspaceWindowHandler = { url in
                openWindow(id: "workspace", value: url)
            }
            sessionRegistry.openWelcomeWindowHandler = {
                openWindow(id: "welcome")
            }
            selection = filteredRecents.first
            DispatchQueue.main.async { listFocused = true }
            appEnvironment.firstWindowDrawn()
            toolSetup.check()
            if !appEnvironment.recentProjects.isEmpty { getStarted.complete(.openProject) }
        }
        .onChange(of: appearsActive) { _, active in
            if active { toolSetup.check() }
        }
        .onChange(of: filteredRecents) { _, recents in
            if selection.map({ !recents.contains($0) }) ?? true {
                selection = recents.first
            }
        }
        .onExitCommand {
            if searchFilter.isEmpty {
                dismissWindow(id: "welcome")
            } else {
                searchFilter = ""
            }
        }
    }

    private var introPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: welcomeMedallionImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 136, height: 136)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            palette.contrastBorder,
                            lineWidth: isHighContrast ? Stroke.standard : Stroke.hairline
                        )
                }
                .accessibilityHidden(true)

            Text("GoLens")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(palette.primary)
                .padding(.top, Spacing.standard)

            Text(versionString)
                .font(.body.monospacedDigit())
                .foregroundStyle(palette.primary)
                .padding(.top, Spacing.hairline)

            WelcomeActionStack {
                Button { sessionRegistry.showWelcomeNewProjectSheet = true } label: {
                    WelcomeActionLabel(title: "Create New Project…", symbol: "plus.square")
                }
                .help(KeymapStore.shared.labeled("Start a Go CLI app or HTTP server from a template", "file.newProject"))

                Button { showCloneRepoSheet = true } label: {
                    WelcomeActionLabel(title: "Clone Git Repository…", symbol: "square.and.arrow.down")
                }
                .help("Clone a Go project from GitHub, GitLab, or any remote")

                Button { sessionRegistry.activeWorkspace.pickDirectory() } label: {
                    WelcomeActionLabel(title: "Open Existing Project…", symbol: "folder")
                }
                .help(KeymapStore.shared.labeled("Open any Go module directory on your local drive", "file.openProject"))
            }
            .buttonStyle(WelcomeCapsuleButtonStyle())
            .padding(.top, Spacing.hero)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.welcomeHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { welcomeStudioBackground }
        .chromeMaterialSurface(.regular)
    }

    private var recentsPane: some View {
        VStack(spacing: 0) {
            if !toolSetup.missing.isEmpty {
                ToolSetupChecklist()
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.comfortable)
            } else if toolSetup.hasChecked, !getStarted.checklist.isHidden {
                GetStartedChecklistView()
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.comfortable)
            }
            if !appEnvironment.recentProjects.isEmpty {
                filterField
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.comfortable)
                    .padding(.bottom, Spacing.row)
            }

            let recents = filteredRecents
            if recents.isEmpty {
                Text(appEnvironment.recentProjects.isEmpty ? "No Recent Projects" : "No Matching Projects")
                    .font(.body)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                recentList(recents)
            }
        }
        .frame(maxHeight: .infinity)
        .chromeMaterialSurface(.thick)
    }

    private var filterField: some View {
        HStack(spacing: Spacing.row) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            TextField("Filter", text: $searchFilter)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(palette.primary)
                .accessibilityLabel("Filter Recent Projects")
                .onSubmit {
                    if let selection { open(selection) }
                }
            if !searchFilter.isEmpty {
                Button { searchFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, Spacing.inset)
        .frame(height: 28)
        .background(palette.restFill, in: Capsule())
    }

    private func recentList(_ recents: [String]) -> some View {
        let emphasized = listFocused && appearsActive
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.hairline) {
                    ForEach(recents, id: \.self) { path in
                        WelcomeRecentProjectRow(
                            path: path,
                            isSelected: selection == path,
                            isEmphasized: emphasized,
                            onSelect: {
                                selection = path
                                listFocused = true
                            },
                            onOpen: { open(path) }
                        )
                        .id(path)
                    }
                }
                .padding(.horizontal, Spacing.inset)
                .padding(.trailing, NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0)
                .padding(.vertical, Spacing.row)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1, in: recents, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(by: -1, in: recents, proxy: proxy) }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                open(selection)
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recent Projects")
        }
    }

    private func moveSelection(by delta: Int, in recents: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !recents.isEmpty else { return .ignored }
        let current = selection.flatMap { recents.firstIndex(of: $0) } ?? (delta > 0 ? -1 : recents.count)
        let next = recents[min(max(current + delta, 0), recents.count - 1)]
        selection = next
        proxy.scrollTo(next)
        return .handled
    }

    private func open(_ path: String) {
        sessionRegistry.openProject(at: path)
    }
}

private struct WelcomePalette {
    var primary: Color {
        ChromeColor.textPrimary
    }

    var secondary: Color {
        ChromeColor.textSecondary
    }

    var restFill: Color {
        ChromeColor.hover
    }

    var pressedFill: Color {
        Color(nsColor: .secondarySystemFill)
    }

    var contrastBorder: Color {
        ChromeColor.separator
    }

    var selectionFill: Color {
        ChromeColor.selection
    }

    var selectedText: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
}

private struct WelcomeActionStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let stack = VStack(spacing: Spacing.standard) { content }
        if !reduceTransparency {
            GlassEffectContainer(spacing: 0) { stack }
        } else {
            stack
        }
    }
}

private struct WelcomeActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: Spacing.inset) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeCapsuleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let palette = WelcomePalette()
        let shape = Capsule()
        let usesGlass = !reduceTransparency

        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(palette.primary)
            .padding(.horizontal, Spacing.section)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                configuration.isPressed ? palette.pressedFill : .clear,
                in: shape
            )
            .glassControlCapsule(interactive: true)
            .overlay {
                if !usesGlass && contrast == .increased {
                    shape.strokeBorder(palette.contrastBorder, lineWidth: Stroke.standard)
                }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
    }
}

struct WelcomeRecentProjectRow: View {
    let path: String
    let isSelected: Bool
    let isEmphasized: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @Bindable private var workspace = WorkspaceState.shared
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = WelcomePalette()
        let name = (path as NSString).lastPathComponent
        let displayPath = (path as NSString).abbreviatingWithTildeInPath
        let highlighted = isSelected && isEmphasized
        let shape = RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)

        Button(action: activate) {
            HStack(spacing: Spacing.inset) {
                FileIconView(fileName: name, path: path, isFolder: true, isSelected: highlighted, size: 28)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(highlighted ? palette.selectedText : palette.primary)
                        .lineLimit(1)
                    Text(displayPath)
                        .font(.subheadline)
                        .foregroundStyle(highlighted ? palette.selectedText : palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.inset)
            .padding(.vertical, Spacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(palette), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Motion.quick) { isHovered = hovering }
        }
        .help(path)
        .contextMenu {
            Button("Open", systemImage: "folder", action: onOpen)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(displayPath)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func activate() {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown else {
            onOpen()
            return
        }
        if event.clickCount >= 2 {
            onOpen()
        } else {
            onSelect()
        }
    }

    private func rowFill(_ palette: WelcomePalette) -> Color {
        if isSelected {
            return isEmphasized ? palette.selectionFill : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return isHovered ? palette.restFill : .clear
    }
}

private struct WelcomeWindowConfigurator: NSViewRepresentable {
    @Binding var titlebarHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = WindowHookView()
        view.onTitlebarHeight = { height in
            guard titlebarHeight != height else { return false }
            titlebarHeight = height
            return true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowHookView)?.configure()
    }

    final class WindowHookView: NSView {
        var onTitlebarHeight: ((CGFloat) -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let window else { return }
            window.styleMask.remove([.miniaturizable, .resizable])
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "welcome")
                window.toolbarStyle = .unified
            }
            let height = window.frame.height - window.contentLayoutRect.height
            DispatchQueue.main.async { [weak self] in
                guard self?.onTitlebarHeight?(height) == true else { return }
                DispatchQueue.main.async { self?.window?.center() }
            }
        }
    }
}

struct GitCloneSheetView: View {
    private struct AccountSheetContext: Identifiable {
        let id = UUID()
        let host: String?
        let accountID: UUID?
        let retryCloneOnComplete: Bool
    }

    @Environment(\.dismiss) var dismiss
    @Bindable var workspace = WorkspaceState.shared
    private let accountStore = GitAccountStore.shared

    @State private var gitURL = ""
    @State private var selectedParentFolder = ""
    @State private var isCloning = false
    @State private var errorMessage = ""
    @State private var authRecoveryContext: GitAuthRecoveryContext?
    @State private var accountSheetContext: AccountSheetContext?
    @FocusState private var isURLFieldFocused: Bool

    private var canClone: Bool {
        !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedParentFolder.isEmpty &&
        !isCloning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Clone Git Repository")
                    .font(.headline)
                Text("Enter a repository URL or choose a repository from a connected GitHub or GitLab account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.row) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Repository URL")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if accountStore.accounts.isEmpty {
                            Button("Add Account…") {
                                accountSheetContext = AccountSheetContext(host: nil, accountID: nil, retryCloneOnComplete: false)
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .accessibilityIdentifier("git-clone-add-account-button")
                        } else {
                            Menu {
                                ForEach(accountStore.accounts) { account in
                                    Section("\(account.formattedIdentity) (\(account.host))") {
                                        let repos = accountStore.repositoriesByAccount[account.id] ?? []
                                        if repos.isEmpty {
                                            Button("Refresh Repositories…") {
                                                Task { await accountStore.fetchRepositories(for: account) }
                                            }
                                        } else {
                                            ForEach(repos.prefix(30)) { repo in
                                                Button {
                                                    gitURL = repo.cloneURL
                                                    errorMessage = ""
                                                    authRecoveryContext = nil
                                                } label: {
                                                    Label(
                                                        repo.fullName,
                                                        systemImage: repo.isPrivate ? "lock.fill" : "book.closed"
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button("Add Account…", systemImage: "plus") {
                                    accountSheetContext = AccountSheetContext(host: nil, accountID: nil, retryCloneOnComplete: false)
                                }
                            } label: {
                                Label("Choose from Account", systemImage: "person.crop.circle")
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityIdentifier("git-clone-account-repo-menu")
                        }
                    }

                    TextField("", text: $gitURL, prompt: Text("https://github.com/owner/repo.git"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($isURLFieldFocused)
                        .disabled(isCloning)
                        .onChange(of: gitURL) { _, _ in
                            if authRecoveryContext != nil {
                                authRecoveryContext = nil
                            }
                        }
                        .accessibilityLabel("Repository URL")
                }

                VStack(alignment: .leading, spacing: Spacing.row) {
                    Text("Clone Location")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.standard) {
                        Text(selectedParentFolder.isEmpty ? "No folder selected" : selectedParentFolder)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(selectedParentFolder.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { chooseLocation() }
                            .disabled(isCloning)
                    }
                }

                if isCloning {
                    HStack(spacing: Spacing.standard) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Cloning repository…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let authRecoveryContext {
                    VStack(alignment: .leading, spacing: Spacing.standard) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                            Text(authRecoveryContext.alertMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(authRecoveryContext.primaryActionTitle) {
                            accountSheetContext = AccountSheetContext(
                                host: authRecoveryContext.host,
                                accountID: authRecoveryContext.existingAccount?.id,
                                retryCloneOnComplete: true
                            )
                        }
                        .controlSize(.small)
                    }
                } else if !errorMessage.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCloning)
                Button("Clone") { performClone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(Spacing.section)
        .frame(width: WelcomeLayout.cloneSheetWidth)
        .onAppear {
            isURLFieldFocused = true
        }
        .sheet(item: $accountSheetContext) { ctx in
            GitAccountSheetView(initialHost: ctx.host, editingAccountID: ctx.accountID) { account in
                Task { await accountStore.fetchRepositories(for: account) }
                if ctx.retryCloneOnComplete, canClone {
                    performClone()
                }
            }
        }
        .task {
            for account in accountStore.accounts where accountStore.repositoriesByAccount[account.id] == nil {
                await accountStore.fetchRepositories(for: account)
            }
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Clone Destination"
        if panel.runModal() == .OK, let url = panel.url {
            selectedParentFolder = url.path
        }
    }

    private func performClone() {
        let urlStr = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty && !selectedParentFolder.isEmpty else { return }

        isCloning = true
        errorMessage = ""
        authRecoveryContext = nil

        workspace.cloneRepository(url: urlStr, destinationParent: selectedParentFolder) { result in
            isCloning = false
            switch result {
            case .success(let clonedPath):
                WorkspaceSessionRegistry.shared.openProject(at: clonedPath)
                dismiss()
            case .failure(let error):
                if let recovery = accountStore.detectAuthenticationFailure(errorText: error.localizedDescription, remoteURLs: [urlStr]) {
                    authRecoveryContext = recovery
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
