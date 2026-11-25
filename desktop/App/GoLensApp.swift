import GoLensFoundation
import SwiftUI

struct EditorCommentSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var commentSelectionAction: EditorCommentSelectionKey.Value? {
        get { self[EditorCommentSelectionKey.self] }
        set { self[EditorCommentSelectionKey.self] = newValue }
    }
}

extension NSWorkspace {
    static var accessibilityReduceMotion: Bool {
        shared.accessibilityDisplayShouldReduceMotion
    }
}

@main
struct GoLensApp: App {
    @FocusedValue(\.commentSelectionAction) var commentSelectionAction: (() -> Void)?

    private var appEnvironment = AppEnvironment.shared
    private var sessionRegistry = WorkspaceSessionRegistry.shared
    private var workspace: WorkspaceState { sessionRegistry.activeWorkspace }
    private var workspaceBindable: Bindable<WorkspaceState> { Bindable(workspace) }
    @AppStorage(WorkspaceState.showIssuesInlineKey) private var showIssuesInline = true
    @AppStorage(WorkspaceState.showSourceControlChangesKey) private var showsSourceControlChanges = true
    @NSApplicationDelegateAdaptor(GoLensAppDelegate.self) private var appDelegate

    private var consoleVisibleBinding: Binding<Bool> {
        Binding(
            get: { workspace.showConsole },
            set: { newValue in
                guard workspace.showConsole != newValue else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.standard) {
                    workspace.showConsole = newValue
                }
            }
        )
    }

    private var inlineGitBlameBinding: Binding<Bool> {
        Binding(
            get: { workspace.showInlineGitBlame },
            set: { newValue in
                if workspace.showInlineGitBlame != newValue {
                    workspace.toggleInlineGitBlame()
                }
            }
        )
    }

    private var escapeAnalysisBinding: Binding<Bool> {
        Binding(
            get: { workspace.showEscapeAnalysis },
            set: { newValue in
                if workspace.showEscapeAnalysis != newValue {
                    workspace.toggleEscapeAnalysis()
                }
            }
        )
    }

    private func navigatorBinding(for navigator: WorkspaceState.Navigator) -> Binding<Bool> {
        Binding(
            get: { workspace.isSidebarVisible && workspace.selectedSidebarTab == navigator },
            set: { isOn in
                if isOn {
                    workspace.showNavigator(navigator)
                } else if workspace.selectedSidebarTab == navigator {
                    workspace.isSidebarVisible = false
                }
            }
        )
    }

    private var caps: ActiveCommandCapabilities {
        workspace.commandCapabilities.current
    }

    private func key(_ id: String) -> KeyboardShortcut? {
        KeymapStore.shared.shortcut(id)
    }

    init() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        measureLog("launch")
        measureStartup("init")
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            measureStartup("did-finish-launching")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { AppEnvironment.shared.firstWindowDrawn() }
            }
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        measureStartup("activated")
        ThemeManager.shared.applyAppIcon(themeId: AppEnvironment.shared.selectedThemeId)
        measureStartup("app-icon")
        WorkspaceState.shared.updateWindowAppearance()
        measureStartup("window-appearance")
        _ = AppEnvironment.shared
        _ = SandboxVMManager.shared
        measureStartup("vm-manager")
        _ = GitAccountStore.shared
        MetricKitDiagnosticsStore.shared.start()
        measureStartup("git-accounts-metrickit")
        WorkspaceState.shared.setup()
        measureStartup("workspace-setup")
    }

    static let credits = NSAttributedString(
        string: "Acknowledgements\n\nThe Go gopher was designed by Renée French and is licensed under Creative Commons Attribution 4.0 (creativecommons.org/licenses/by/4.0). The GoLens mascot is an original drawing based on her design. The GoLens app icons are original artwork.\n\nThe GoLens file and AST symbol icons are original vector drawings created for GoLens. Go, Docker, Kubernetes, Helm, Terraform and other names are trademarks of their owners.",
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
    )

    var body: some Scene {
        WindowGroup("GoLens", id: "workspace", for: URL.self) { $workspaceURL in
            AppContentView(workspaceURL: $workspaceURL)
                .background(DocumentationWindowOpenerBridge())
        }
        .defaultSize(width: WindowLayout.defaultWidth, height: WindowLayout.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutGoLensCommandButton()
                Button("Check for Updates…", systemImage: "arrow.down.app") {
                    AppUpdater.shared.checkForUpdates()
                }
                .disabled(!AppUpdater.shared.isAvailable || (AppUpdater.shared.isStarted && !AppUpdater.shared.canCheckForUpdates))
            }

            CommandGroup(replacing: .newItem) {
                Button("New File", systemImage: "doc.badge.plus") {
                    workspace.requestNewItem(folder: false)
                }
                .keyboardShortcut(key("file.newFile"))
                .disabled(!caps.hasWorkspace)

                Button("New Folder", systemImage: "folder.badge.plus") {
                    workspace.requestNewItem(folder: true)
                }
                .keyboardShortcut(key("file.newFolder"))
                .disabled(!caps.hasWorkspace)

                Button("New Window", systemImage: "macwindow.badge.plus") {
                    sessionRegistry.presentWorkspacePickerWindow()
                }
                .keyboardShortcut(key("file.newWindow"))

                Divider()

                Button("New Project…", systemImage: "plus.rectangle.on.folder") {
                    if caps.hasWorkspace {
                        workspace.showNewProjectSheet = true
                    } else {
                        sessionRegistry.presentWorkspacePickerWindow()
                        sessionRegistry.showWelcomeNewProjectSheet = true
                    }
                }
                .keyboardShortcut(key("file.newProject"))

                Button("Open Project…", systemImage: "folder") {
                    workspace.pickDirectory()
                }
                .keyboardShortcut(key("file.openProject"))

                Menu("Open Recent", systemImage: "clock") {
                    ForEach(appEnvironment.recentProjects, id: \.self) { path in
                        Button(appEnvironment.recentProjectTitle(path), systemImage: "folder") {
                            sessionRegistry.openProject(at: path)
                        }
                    }
                    if !appEnvironment.recentProjects.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu", systemImage: "trash") {
                        appEnvironment.clearRecentProjects()
                    }
                    .disabled(appEnvironment.recentProjects.isEmpty)
                }

                Divider()

                Button("Open Quickly…", systemImage: "magnifyingglass") {
                    workspace.showOpenQuickly.toggle()
                }
                .keyboardShortcut(key("file.openQuickly"))
                .disabled(!caps.hasWorkspace)
            }

            CommandGroup(replacing: .saveItem) {
                Button(caps.hasActiveFile ? "Close Tab" : "Close", systemImage: "xmark") {
                    workspace.closeCurrentTab()
                }
                .keyboardShortcut(key("file.closeTab"))

                Button("Close Window", systemImage: "xmark.rectangle") {
                    workspace.closeMainWindow()
                }
                .keyboardShortcut(key("file.closeWindow"))

                Divider()

                Button("Save", systemImage: "square.and.arrow.down") {
                    workspace.saveActiveFileAndFormat()
                }
                .keyboardShortcut(key("file.save"))
                .disabled(!caps.canSave)

                Button("Show Local History…", systemImage: "clock.arrow.circlepath") {
                    workspace.presentLocalHistory()
                }
                .keyboardShortcut(key("file.localHistory"))
                .disabled(!caps.hasActiveFile)
            }

            CommandGroup(after: .pasteboard) {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    if let tv = workspace.activeTextView as? GoLensTextView,
                       tv.window?.firstResponder === tv || NSApp.keyWindow == nil || !(NSApp.keyWindow?.firstResponder is NSTextView) {
                        tv.duplicate(nil)
                    } else if !NSApp.sendAction(#selector(GoLensTextView.duplicate(_:)), to: nil, from: nil) {
                        (workspace.activeTextView as? GoLensTextView)?.duplicate(nil)
                    }
                }
                .keyboardShortcut(key("edit.duplicate"))
                .disabled(!caps.hasActiveFile)

                Button("Paste JSON as Go Struct", systemImage: "curlybraces") {
                    workspace.pasteJSONAsGoStruct()
                }
                .keyboardShortcut(key("edit.pasteJSONAsStruct"))
                .disabled(!workspace.clipboardHasJSONObject || !caps.isGoFile || !caps.isCodeMode)

                Divider()

                Button("Expand Selection", systemImage: "arrow.up.left.and.arrow.down.right") {
                    workspace.expandSyntaxSelection()
                }
                .keyboardShortcut(key("edit.expandSelection"))
                .disabled(!caps.isGoFile)

                Button("Shrink Selection", systemImage: "arrow.down.right.and.arrow.up.left") {
                    workspace.shrinkSyntaxSelection()
                }
                .keyboardShortcut(key("edit.shrinkSelection"))
                .disabled(!caps.isGoFile)

                Divider()

                Button("Add Cursor Above", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    NSApp.sendAction(#selector(GoLensTextView.addCursorAbove(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(key("edit.addCursorAbove"))
                .disabled(!caps.hasActiveFile)

                Button("Add Cursor Below", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    NSApp.sendAction(#selector(GoLensTextView.addCursorBelow(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(key("edit.addCursorBelow"))
                .disabled(!caps.hasActiveFile)

                Divider()

                Button("Join Lines", systemImage: "arrow.merge") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.joinLines() }
                }
                .keyboardShortcut(key("edit.joinLines"))
                .disabled(!caps.hasActiveFile || !caps.isCodeMode)

                Button("Move Line Up", systemImage: "arrow.up") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.moveLine(up: true) }
                }
                .keyboardShortcut(key("edit.moveLineUp"))
                .disabled(!caps.hasActiveFile || !caps.isCodeMode)

                Button("Move Line Down", systemImage: "arrow.down") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.moveLine(up: false) }
                }
                .keyboardShortcut(key("edit.moveLineDown"))
                .disabled(!caps.hasActiveFile || !caps.isCodeMode)

                Button("Move Statement Up", systemImage: "arrow.up.square") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.moveStatement(up: true) }
                }
                .keyboardShortcut(key("edit.moveStatementUp"))
                .disabled(!caps.isGoFile || !caps.isCodeMode)

                Button("Move Statement Down", systemImage: "arrow.down.square") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.moveStatement(up: false) }
                }
                .keyboardShortcut(key("edit.moveStatementDown"))
                .disabled(!caps.isGoFile || !caps.isCodeMode)
            }

            CommandGroup(replacing: .printItem) {}

            CommandGroup(replacing: .sidebar) {
                Button("Command Palette…", systemImage: "command.square") {
                    workspace.showCommandPalette.toggle()
                }
                .keyboardShortcut(key("view.commandPalette"))
                .disabled(!caps.hasWorkspace)

                Divider()

                Toggle("Console", systemImage: "rectangle.bottomthird.inset.filled", isOn: consoleVisibleBinding)
                    .keyboardShortcut(key("view.console"))
                    .disabled(!caps.hasWorkspace)

                Button("Show Services", systemImage: ServiceSymbol.services) {
                    workspace.showServicesPanel()
                }
                .keyboardShortcut(key("view.showServices"))
                .disabled(!caps.hasWorkspace)

                Toggle("Gopilot", systemImage: "sparkles", isOn: workspaceBindable.gopilot.isPanelVisible)
                    .keyboardShortcut(key("view.gopilot"))

                Toggle("Minimap", systemImage: "sidebar.squares.right", isOn: workspaceBindable.showMinimap)
                    .keyboardShortcut(key("view.minimap"))
                    .disabled(!caps.hasWorkspace)

                Toggle("Toggle Word Wrap", systemImage: "text.word.spacing", isOn: workspaceBindable.wordWrapEnabled)
                    .keyboardShortcut(key("view.toggleWordWrap"))
                    .disabled(!caps.hasWorkspace)

                Toggle("Inline Issues", systemImage: "exclamationmark.bubble", isOn: $showIssuesInline)
                    .onChange(of: showIssuesInline) { (workspace.activeTextView as? GoLensTextView)?.needsDisplay = true }
                    .keyboardShortcut(key("view.inlineIssues"))
                    .disabled(!caps.hasWorkspace)

                Toggle("Inline Git Blame", systemImage: "person.text.rectangle", isOn: inlineGitBlameBinding)
                    .keyboardShortcut(key("view.inlineBlame"))
                    .disabled(!caps.hasWorkspace)

                Button("Quick Documentation", systemImage: "questionmark.circle") {
                    (workspace.activeTextView as? GoLensTextView)?.showQuickDocumentation()
                }
                .keyboardShortcut(key("view.quickDocumentation"))
                .disabled(!caps.isGoFile || !caps.isCodeMode)

                Button("Quick Definition", systemImage: "rectangle.and.text.magnifyingglass") {
                    GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.showQuickDefinition() }
                }
                .keyboardShortcut(key("view.quickDefinition"))
                .disabled(!caps.isGoFile || !caps.isCodeMode)

                Button("Parameter Info", systemImage: "parentheses") {
                    (workspace.activeTextView as? GoLensTextView).map { workspace.fetchSignatureHelp(for: $0) }
                }
                .keyboardShortcut(key("view.parameterInfo"))
                .disabled(!caps.isGoFile || !caps.isCodeMode)

                Button("Documentation Browser", systemImage: "book") {
                    DocumentationService.shared.openBrowser(for: caps.hasWorkspace ? workspace : nil, focusSearch: true)
                }
                .keyboardShortcut(key("view.documentationBrowser"))

                Toggle("Show Code Review", systemImage: "arrow.left.arrow.right", isOn: Binding(
                    get: { caps.isDiffMode },
                    set: { _ in workspace.toggleCodeReview() }
                ))
                .keyboardShortcut(key("view.codeReview"))
                .disabled(!caps.hasWorkspace || workspace.git.isRepository != true || !caps.hasActiveFile)

                Toggle("Inlay Hints", systemImage: "tag", isOn: workspaceBindable.showInlayHints)
                    .keyboardShortcut(key("view.inlayHints"))
                    .disabled(!caps.hasWorkspace)

                Menu("Code Lenses", systemImage: "eyeglasses") {
                    Picker("Code Lenses", selection: workspaceBindable.opticalLensDisplayMode) {
                        ForEach(OpticalLensDisplayMode.allCases) { mode in
                            Text(mode.menuTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(!caps.hasWorkspace)

                Toggle("Escape Analysis", systemImage: "memorychip", isOn: escapeAnalysisBinding)
                    .keyboardShortcut(key("view.escapeAnalysis"))
                    .disabled(!caps.isGoFile)

                Divider()

                Menu("Code Folding", systemImage: "chevron.down.square") {
                    Button("Fold", systemImage: "chevron.right") { workspace.setFold(true, all: false) }
                        .keyboardShortcut(key("view.fold"))
                        .disabled(!caps.hasActiveFile)
                    Button("Unfold", systemImage: "chevron.down") { workspace.setFold(false, all: false) }
                        .keyboardShortcut(key("view.unfold"))
                        .disabled(!caps.hasActiveFile)

                    Divider()

                    Button("Fold All", systemImage: "arrow.down.right.and.arrow.up.left") { workspace.setFold(true, all: true) }
                        .keyboardShortcut(key("view.foldAll"))
                        .disabled(!caps.hasActiveFile)
                    Button("Unfold All", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.setFold(false, all: true) }
                        .keyboardShortcut(key("view.unfoldAll"))
                        .disabled(!caps.hasActiveFile)
                }

                Divider()

                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    workspace.editorFontSize += 1
                }
                .keyboardShortcut(key("view.zoomIn"))
                .disabled(!caps.hasWorkspace)

                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    if workspace.editorFontSize > 6 {
                        workspace.editorFontSize -= 1
                    }
                }
                .keyboardShortcut(key("view.zoomOut"))
                .disabled(!caps.hasWorkspace)

                Button("Actual Size", systemImage: "1.magnifyingglass") {
                    workspace.editorFontSize = 13.0
                }
                .keyboardShortcut(key("view.actualSize"))
                .disabled(!caps.hasWorkspace)

                Divider()

                Toggle("Navigator", systemImage: "sidebar.leading", isOn: workspaceBindable.isSidebarVisible)
                    .keyboardShortcut(key("view.navigator"))
                    .disabled(!caps.hasWorkspace)

                Menu("Navigators", systemImage: "sidebar.leading") {
                    ForEach(WorkspaceState.Navigator.allCases, id: \.self) { navigator in
                        Toggle(navigator.title, systemImage: navigator.symbol, isOn: navigatorBinding(for: navigator))
                            .keyboardShortcut(key(navigator.keymapID))
                    }
                }
                .disabled(!caps.hasWorkspace)

                Divider()
            }

            Group {
                CommandMenu("Find") {
                    if appEnvironment.menusReady {
                        let _ = measureStartupOnce("menu-build")
                        Button("Find…", systemImage: "magnifyingglass") {
                            workspace.openLocalSearch()
                        }
                        .keyboardShortcut(key("find.find"))
                        .disabled(workspace.focusedFilePath.isEmpty)

                        Button("Find Next", systemImage: "chevron.down") {
                            workspace.selectNextLocalMatch()
                        }
                        .keyboardShortcut(key("find.findNext"))
                        .disabled(workspace.localSearchMatches.isEmpty)

                        Button("Find Previous", systemImage: "chevron.up") {
                            workspace.selectPreviousLocalMatch()
                        }
                        .keyboardShortcut(key("find.findPrevious"))
                        .disabled(workspace.localSearchMatches.isEmpty)

                        Button("Find in Project…", systemImage: "text.magnifyingglass") {
                            workspace.showNavigator(.search)
                        }
                        .keyboardShortcut(key("find.findInProject"))
                        .disabled(!caps.hasWorkspace)

                        Divider()

                        Button("Use Selection for Find", systemImage: "selection.pin.in.out") {
                            workspace.useSelectionForFind()
                        }
                        .keyboardShortcut(key("find.useSelection"))
                        .disabled(!workspace.editorHasSelection)

                        Button("Select Next Occurrence", systemImage: "plus.magnifyingglass") {
                            NSApp.sendAction(#selector(GoLensTextView.selectNextOccurrence(_:)), to: nil, from: nil)
                        }
                        .keyboardShortcut(key("find.selectNextOccurrence"))
                        .disabled(!caps.hasActiveFile)
                    }
                }

                CommandMenu("Navigate") {
                    if appEnvironment.menusReady {
                        Button("Back", systemImage: "chevron.backward") {
                            workspace.navigateBack()
                        }
                        .keyboardShortcut(key("navigate.back"))
                        .disabled(workspace.navigationIndex <= 0)

                        Button("Forward", systemImage: "chevron.forward") {
                            workspace.navigateForward()
                        }
                        .keyboardShortcut(key("navigate.forward"))
                        .disabled(workspace.navigationIndex >= workspace.navigationHistory.count - 1)

                        Divider()

                        Button("Recent Files…", systemImage: "clock") {
                            workspace.showRecentFilesPopup.toggle()
                        }
                        .keyboardShortcut(key("navigate.recentFiles"))
                        .disabled(!caps.hasWorkspace)

                        Button("Go to Symbol in File…", systemImage: "list.bullet.indent") {
                            workspace.showGoToSymbol.toggle()
                        }
                        .keyboardShortcut(key("navigate.symbolInFile"))
                        .disabled(!caps.hasActiveFile)

                        Button("Go to Workspace Symbol…", systemImage: "number.square") {
                            workspace.showWorkspaceSymbol.toggle()
                        }
                        .keyboardShortcut(key("navigate.workspaceSymbol"))
                        .disabled(!caps.hasWorkspace)

                        Button("Go to Line…", systemImage: "number") {
                            workspace.showGoToLineSheet = true
                        }
                        .keyboardShortcut(key("navigate.goToLine"))
                        .disabled(!caps.hasActiveFile)

                        Divider()

                        Button("Go to Definition", systemImage: "arrow.right.circle") {
                            workspace.goToDefinitionAtCaret()
                        }
                        .keyboardShortcut(key("navigate.definition"))
                        .disabled(!caps.isGoFile)

                        Button("Go to Implementation", systemImage: "arrow.down.right.circle") {
                            workspace.goToImplementationAtCaret()
                        }
                        .keyboardShortcut(key("navigate.implementation"))
                        .disabled(!caps.isGoFile)

                        Button("Go to Type Definition", systemImage: "t.square") {
                            workspace.goToTypeDefinitionAtCaret()
                        }
                        .keyboardShortcut(key("navigate.typeDefinition"))
                        .disabled(!caps.isGoFile)

                        Button("Find References", systemImage: "link") {
                            workspace.findReferencesAtCaret()
                        }
                        .keyboardShortcut(key("navigate.references"))
                        .disabled(!caps.isGoFile)

                        Button(caps.isGoTestFile ? "Jump to Tested Symbol" : "Jump to Test", systemImage: "checkmark.diamond") {
                            workspace.jumpBetweenCodeAndTest()
                        }
                        .keyboardShortcut(key("navigate.jumpToTest"))
                        .disabled(!caps.isGoFile)

                        Divider()

                        Button("Call Hierarchy", systemImage: "arrow.triangle.branch") {
                            workspace.showCallHierarchyAtCaret()
                        }
                        .keyboardShortcut(key("navigate.callHierarchy"))
                        .disabled(!caps.isGoFile)

                        Button("Type Hierarchy", systemImage: "list.bullet.indent") {
                            workspace.showTypeHierarchyAtCaret()
                        }
                        .keyboardShortcut(key("navigate.typeHierarchy"))
                        .disabled(!caps.isGoFile)

                        Divider()

                        Button("Toggle Bookmark", systemImage: "bookmark") {
                            workspace.toggleBookmarkAtCaret()
                        }
                        .keyboardShortcut(key("navigate.toggleBookmark"))
                        .disabled(!caps.hasActiveFile)

                        Button("Next Bookmark", systemImage: "bookmark.fill") {
                            workspace.navigateToNextBookmark()
                        }
                        .keyboardShortcut(key("navigate.nextBookmark"))
                        .disabled(workspace.bookmarks.isEmpty)

                        Button("Previous Bookmark", systemImage: "bookmark") {
                            workspace.navigateToPreviousBookmark()
                        }
                        .keyboardShortcut(key("navigate.previousBookmark"))
                        .disabled(workspace.bookmarks.isEmpty)

                        Button("Show Bookmarks", systemImage: "list.bullet.rectangle") {
                            workspace.selectedIssuesNavigatorSubtab = .bookmarks
                            workspace.showNavigator(.issues)
                        }
                        .keyboardShortcut(key("navigate.showBookmarks"))
                        .disabled(!caps.hasWorkspace)

                        Button("Show Project TODOs & FIXMEs", systemImage: "checklist") {
                            workspace.selectedIssuesNavigatorSubtab = .todos
                            workspace.showNavigator(.issues)
                        }
                        .keyboardShortcut(key("navigate.showTodos"))
                        .disabled(!caps.hasWorkspace)

                        Divider()

                        Button("Jump to Next Change", systemImage: "arrow.down.to.line") { workspace.jumpToChange(forward: true) }
                            .keyboardShortcut(key("navigate.nextChange"))
                            .disabled(!showsSourceControlChanges || workspace.git.activeFileDiffs.isEmpty)
                        Button("Jump to Previous Change", systemImage: "arrow.up.to.line") { workspace.jumpToChange(forward: false) }
                            .keyboardShortcut(key("navigate.previousChange"))
                            .disabled(!showsSourceControlChanges || workspace.git.activeFileDiffs.isEmpty)

                        Divider()

                        Button("Next Issue", systemImage: "chevron.down") { workspace.jumpToIssue(forward: true) }
                            .keyboardShortcut(key("navigate.nextIssue"))
                            .disabled(!caps.hasActiveFile)
                        Button("Previous Issue", systemImage: "chevron.up") { workspace.jumpToIssue(forward: false) }
                            .keyboardShortcut(key("navigate.previousIssue"))
                            .disabled(!caps.hasActiveFile)
                    }
                }

                CommandMenu("Editor") {
                    if appEnvironment.menusReady {
                        Button("Comment/Uncomment Selection", systemImage: "text.bubble") {
                            commentSelectionAction?()
                        }
                        .keyboardShortcut(key("editor.toggleComment"))
                        .disabled(commentSelectionAction == nil)

                        Button("Format Document", systemImage: "text.alignleft") {
                            workspace.formatActiveDocument()
                        }
                        .keyboardShortcut(key("editor.format"))
                        .disabled(!caps.canFormatDocument)

                        Button("Organize Imports", systemImage: "arrow.up.arrow.down") {
                            workspace.organizeImportsActiveDocument()
                        }
                        .keyboardShortcut(key("editor.organizeImports"))
                        .disabled(!caps.isGoFile)

                        Button("Surround With…", systemImage: "curlybraces") {
                            workspace.presentSurroundWith()
                        }
                        .keyboardShortcut(key("editor.surroundWith"))
                        .disabled(!caps.isGoFile)

                        Button("Complete Current Statement", systemImage: "return") {
                            (workspace.activeTextView as? GoLensTextView)?.completeCurrentStatement()
                        }
                        .keyboardShortcut(key("editor.completeStatement"))
                        .disabled(!caps.isGoFile || !caps.isCodeMode)

                        Button("Show Code Actions", systemImage: "wand.and.stars") {
                            if let tv = workspace.activeTextView as? GoLensTextView {
                                workspace.showCodeActionsMenu(for: tv, at: tv.selectedRange().location)
                            }
                        }
                        .keyboardShortcut(key("editor.codeActions"))
                        .disabled(!caps.isGoFile && !caps.isDockerfile)

                        Button("Show Suggestion") {
                            (workspace.activeTextView as? GoLensTextView)?.inlineSuggestions.showNow()
                        }
                        .keyboardShortcut(key("editor.showSuggestion"))
                        .disabled(!AICompletionSettings.shared.isReady || !caps.isGoFile)

                        Button("Read Suggestion") {
                            (workspace.activeTextView as? GoLensTextView)?.inlineSuggestions.readSuggestion()
                        }
                        .keyboardShortcut(key("editor.readSuggestion"))
                        .disabled(!AICompletionSettings.shared.isEnabled || !caps.isGoFile)

                        Divider()

                        Menu("Refactor", systemImage: "slider.horizontal.3") {
                            Button("Rename Symbol…", systemImage: "character.cursor.ibeam") {
                                GoLensTextView.runLineCommand(fallback: workspace.activeTextView) { $0.triggerRename() }
                            }
                            .keyboardShortcut(key("refactor.rename"))
                            .disabled(!caps.isGoFile || !caps.isCodeMode)

                            Button("Change Signature…", systemImage: "signature") {
                                workspace.triggerChangeSignature()
                            }
                            .keyboardShortcut(key("refactor.changeSignature"))
                            .disabled(!caps.isGoFile)

                            Button("Move Symbol…", systemImage: "arrow.right.doc.on.clipboard") {
                                workspace.presentMoveSymbolSheet()
                            }
                            .keyboardShortcut(key("refactor.moveSymbol"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Extract Function…", systemImage: "function") {
                                workspace.presentExtractMethodSheet()
                            }
                            .keyboardShortcut(key("refactor.extractFunction"))
                            .disabled(!caps.isGoFile)

                            Button("Extract Variable", systemImage: "equal.square") {
                                workspace.extractVariableAtSelection()
                            }
                            .keyboardShortcut(key("refactor.extractVariable"))
                            .disabled(!caps.isGoFile)

                            Button("Extract Type Definition…", systemImage: "t.square") {
                                workspace.presentExtractTypeSheet()
                            }
                            .keyboardShortcut(key("refactor.extractType"))
                            .disabled(!caps.isGoFile)

                            Button("Inline Variable", systemImage: "arrow.down.to.line.compact") {
                                workspace.inlineVariableAtCaret()
                            }
                            .keyboardShortcut(key("refactor.inlineVariable"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Extract Interface", systemImage: "puzzlepiece.extension") {
                                workspace.extractInterfaceAtCaret()
                            }
                            .keyboardShortcut(key("refactor.extractInterface"))
                            .disabled(!caps.isGoFile)

                            Button("Implement Interface…", systemImage: "checkmark.seal") {
                                workspace.presentImplementInterfaceSheet()
                            }
                            .keyboardShortcut(key("refactor.implementInterface"))
                            .disabled(!caps.isGoFile)

                            Button("Propagate Method to Implementations…", systemImage: "arrow.triangle.branch") {
                                workspace.presentPropagateInterfaceSheet()
                            }
                            .keyboardShortcut(key("refactor.propagateMethod"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Handle Error with if err != nil", systemImage: "exclamationmark.triangle") {
                                workspace.applyGoIntention("wrap_err")
                            }
                            .keyboardShortcut(key("refactor.handleError"))
                            .disabled(!caps.isGoFile)

                            Button("Convert Between ':=' and 'var'", systemImage: "arrow.left.arrow.right") {
                                workspace.applyGoIntention("toggle_var_assign")
                            }
                            .keyboardShortcut(key("refactor.toggleVarAssign"))
                            .disabled(!caps.isGoFile)

                            Button("Convert Between Raw and Interpreted String", systemImage: "quote.opening") {
                                workspace.applyGoIntention("toggle_string")
                            }
                            .keyboardShortcut(key("refactor.toggleString"))
                            .disabled(!caps.isGoFile)
                        }

                        Menu("Generate", systemImage: "wand.and.rays") {
                            Button("Generate Constructor & Options…", systemImage: "hammer") {
                                workspace.openGenerateConstructorSheet()
                            }
                            .keyboardShortcut(key("generate.constructorOptions"))
                            .disabled(!caps.isGoFile)

                            Button("Generate Constructor", systemImage: "hammer") {
                                workspace.generateConstructorAtCaret()
                            }
                            .keyboardShortcut(key("generate.constructor"))
                            .disabled(!caps.isGoFile)

                            Button("Fill Struct Fields", systemImage: "list.bullet.rectangle") {
                                workspace.fillStructFieldsAtCursor()
                            }
                            .keyboardShortcut(key("generate.fillStruct"))
                            .disabled(!caps.isGoFile)

                            Button("Modify Struct Tags…", systemImage: "tag") {
                                workspace.presentStructTagsSheet()
                            }
                            .keyboardShortcut(key("generate.structTags"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Generate Enum / Stringer Methods…", systemImage: "list.number") {
                                workspace.openGenerateEnumMethodsSheet()
                            }
                            .keyboardShortcut(key("generate.enumStringer"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Generate Table-Driven Test…", systemImage: "checkmark.diamond") {
                                workspace.presentGenerateTableDrivenTestSheet()
                            }
                            .keyboardShortcut(key("generate.tableTest"))
                            .disabled(!caps.isNonTestGoFile)

                            Button("Generate Test", systemImage: "checkmark.diamond") {
                                workspace.generateTestForSelection()
                            }
                            .keyboardShortcut(key("generate.test"))
                            .disabled(!caps.isNonTestGoFile)

                            Button("Generate Fuzz Test…", systemImage: "sparkles") {
                                workspace.openGenerateFuzzTestSheet()
                            }
                            .keyboardShortcut(key("generate.fuzzTest"))
                            .disabled(!caps.isGoFile)

                            Button("Generate Go Benchmark…", systemImage: "stopwatch") {
                                workspace.openGenerateBenchmarkSheet()
                            }
                            .keyboardShortcut(key("generate.benchmark"))
                            .disabled(!caps.isGoFile)

                            Button("Generate Interface Mock…", systemImage: "theatermasks") {
                                workspace.presentGenerateInterfaceMockSheet()
                            }
                            .keyboardShortcut(key("generate.mock"))
                            .disabled(!caps.isGoFile)
                        }

                        Divider()

                        GitHunkMenuItems(workspace: workspace, isAvailable: showsSourceControlChanges && caps.hasActiveFile)

                        Button("Show File History…", systemImage: "clock") {
                            workspace.presentFileHistory(focusCaretLine: true)
                        }
                        .keyboardShortcut(key("git.fileHistory"))
                        .disabled(workspace.focusedFilePath.isEmpty)

                        Menu("Comparison", systemImage: "arrow.left.arrow.right") {
                            Toggle("Inline Comparison", systemImage: "rectangle.grid.1x2", isOn: Binding(get: { workspace.diffStyle == .unified }, set: { _ in workspace.diffStyle = .unified }))
                                .keyboardShortcut(key("editor.comparisonInline"))
                            Toggle("Side By Side Comparison", systemImage: "rectangle.split.2x1", isOn: Binding(get: { workspace.diffStyle == .sideBySide }, set: { _ in workspace.diffStyle = .sideBySide }))
                                .keyboardShortcut(key("editor.comparisonSideBySide"))
                        }

                        Divider()

                        Picker("Indentation", systemImage: "increase.indent", selection: workspaceBindable.tabSize) {
                            Text("2 Spaces").tag(2)
                            Text("4 Spaces").tag(4)
                            Text("8 Spaces").tag(8)
                        }
                        .disabled(!caps.hasActiveFile || caps.isGoFile)
                    }
                }

                CommandMenu("Product") {
                    if appEnvironment.menusReady {
                        Button("Run", systemImage: "play.fill") {
                            workspace.runProject()
                        }
                        .keyboardShortcut(key("product.run"))
                        .disabled(!caps.hasWorkspace || workspace.isTestRunning || workspace.debug.isDebugMode || workspace.activeGoCommand != nil)

                        Button("Debug", systemImage: "ladybug.fill") {
                            if !workspace.isRunning {
                                workspace.debugProject()
                            }
                        }
                        .keyboardShortcut(key("product.debug"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Attach to Process…", systemImage: "ladybug") {
                            workspace.presentAttachProcessSheet()
                        }
                        .keyboardShortcut(key("product.attach"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Build", systemImage: "hammer.fill") {
                            workspace.buildProject()
                        }
                        .keyboardShortcut(key("product.build"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Stop", systemImage: "stop.fill") {
                            workspace.stopActiveRun()
                        }
                        .keyboardShortcut(key("product.stop"))
                        .disabled(!workspace.isRunning)

                        Divider()

                        Button("Test", systemImage: "checkmark.diamond") {
                            workspace.runAllTests()
                        }
                        .keyboardShortcut(key("product.test"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Run Test at Cursor", systemImage: "play.fill") {
                            workspace.runTestAtCursor()
                        }
                        .keyboardShortcut(key("product.testAtCursor"))
                        .disabled(!caps.isGoTestFile || workspace.isRunning)

                        Button("Debug Test at Cursor", systemImage: "ladybug.fill") {
                            workspace.debugTestAtCursor()
                        }
                        .keyboardShortcut(key("product.debugTestAtCursor"))
                        .disabled(!caps.isGoTestFile || workspace.isRunning)

                        Button("Repeat Last Test", systemImage: "arrow.clockwise") {
                            workspace.repeatLastTest()
                        }
                        .keyboardShortcut(key("product.repeatLastTest"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || !workspace.hasLastTestInvocation)

                        Button("Rerun Failed Tests", systemImage: "arrow.clockwise") {
                            workspace.rerunFailedTests()
                        }
                        .keyboardShortcut(key("product.rerunFailed"))
                        .disabled(workspace.isRunning || !workspace.hasFailedTests)

                        Button("Run Tests with Coverage", systemImage: "checkmark.shield") {
                            workspace.runTestsWithCoverage()
                        }
                        .keyboardShortcut(key("product.coverage"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Clear Coverage", systemImage: "xmark.shield") {
                            workspace.clearCoverage()
                        }
                        .keyboardShortcut(key("product.clearCoverage"))
                        .disabled(!workspace.hasCoverageData)

                        Toggle("Auto-Test Package on Save", systemImage: "bolt.badge.checkmark", isOn: workspaceBindable.isAutoTestOnSaveEnabled)
                            .keyboardShortcut(key("product.autoTest"))

                        Divider()

                        Button("Profile Application", systemImage: "gauge.with.dots.needle.67percent") {
                            workspace.profileProject()
                        }
                        .keyboardShortcut(key("product.profile"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning)

                        Button("Profile Tests", systemImage: "gauge.with.dots.needle.67percent") {
                            workspace.profileAllTests()
                        }
                        .keyboardShortcut(key("product.profileTests"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || workspace.goToolchainMissing || !workspace.hasGoModule)

                        Button("Open Profile (.pprof)…", systemImage: "doc.badge.gearshape") {
                            workspace.promptAndImportPprofFile()
                        }
                        .keyboardShortcut(key("product.openProfile"))
                        .disabled(!caps.hasWorkspace)

                        Button("Run Benchmarks", systemImage: "stopwatch") {
                            workspace.runAllBenchmarks()
                        }
                        .keyboardShortcut(key("product.benchmarks"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || workspace.goToolchainMissing || !workspace.hasGoModule)

                        Divider()

                        Button("Run Safety Audit", systemImage: "checkmark.shield") {
                            workspace.runSafetyAudit()
                        }
                        .keyboardShortcut(key("product.safetyAudit"))
                        .disabled(!caps.hasWorkspace || workspace.isSafetyAuditRunning)

                        Divider()

                        Button("Run go generate", systemImage: "gearshape.2") {
                            workspace.runGoGenerate()
                        }
                        .keyboardShortcut(key("product.goGenerate"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || !workspace.hasGoModule)

                        Button("Add Go Module…", systemImage: "shippingbox.and.arrow.backward") {
                            workspace.presentAddGoModuleSheet()
                        }
                        .keyboardShortcut(key("product.addGoModule"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || !workspace.hasGoModule)

                        Button("Run go mod tidy", systemImage: "wand.and.stars") {
                            workspace.tidyModule()
                        }
                        .keyboardShortcut(key("product.goModTidy"))
                        .disabled(!caps.hasWorkspace || workspace.isRunning || !workspace.hasGoModule)

                        Divider()

                        RunConfigurationMenuItems(workspace: workspace, showAttachToProcess: false)
                            .disabled(!caps.hasWorkspace)

                        Menu("Run Destination", systemImage: "desktopcomputer") {
                            RunDestinationMenuItems(workspace: workspace)
                        }
                        .disabled(!caps.hasWorkspace || workspace.activeRunConfiguration?.kind == .docker)
                    }
                }

                CommandMenu("Debug") {
                    if appEnvironment.menusReady {
                        Button("Continue", systemImage: "play.fill") {
                            workspace.debugContinue()
                        }
                        .keyboardShortcut(key("debug.continue"))
                        .disabled(!workspace.isDebuggerPaused)

                        Button("Pause", systemImage: "pause.fill") {
                            workspace.debugPause()
                        }
                        .keyboardShortcut(key("debug.pause"))
                        .disabled(!workspace.debug.isDebugMode || workspace.debug.isPaused)

                        Button("Run to Cursor", systemImage: "arrow.right.to.line") {
                            workspace.debugRunToCursor()
                        }
                        .keyboardShortcut(key("debug.runToCursor"))
                        .disabled(!workspace.debug.isDebugMode)

                        Divider()

                        Button("Step Over", systemImage: "arrow.uturn.forward") {
                            workspace.debugStepOver()
                        }
                        .keyboardShortcut(key("debug.stepOver"))
                        .disabled(!workspace.isDebuggerPaused)

                        Button("Step Into", systemImage: "arrow.down.right") {
                            workspace.debugStepInto()
                        }
                        .keyboardShortcut(key("debug.stepInto"))
                        .disabled(!workspace.isDebuggerPaused)

                        Button("Step Out", systemImage: "arrow.up.left") {
                            workspace.debugStepOut()
                        }
                        .keyboardShortcut(key("debug.stepOut"))
                        .disabled(!workspace.isDebuggerPaused)

                        Divider()

                        Button("Evaluate Expression…", systemImage: "function") {
                            workspace.showConsole = true
                            workspace.selectedConsoleTab = WorkspaceState.debuggerTab
                            workspace.debug.expressionFocusRequest += 1
                        }
                        .keyboardShortcut(key("debug.evaluate"))
                        .disabled(!workspace.debug.isDebugMode)

                        Divider()

                        Button("Add Function Breakpoint…", systemImage: "plus") {
                            workspace.presentAddFunctionBreakpoint()
                        }
                        .keyboardShortcut(key("debug.addFunctionBreakpoint"))
                        .disabled(!caps.hasWorkspace)

                        Divider()

                        Toggle("Show System Goroutines", isOn: workspaceBindable.debug.showsSystemGoroutines)
                            .keyboardShortcut(key("debug.showSystemGoroutines"))
                            .disabled(!workspace.debug.isDebugMode)

                        Button("Copy Goroutine Dump", systemImage: "doc.on.doc") {
                            workspace.copyGoroutineDump()
                        }
                        .keyboardShortcut(key("debug.copyGoroutineDump"))
                        .disabled(!workspace.debug.isDebugMode)

                        Button("Save Goroutine Dump…", systemImage: "square.and.arrow.down") {
                            workspace.saveGoroutineDump()
                        }
                        .keyboardShortcut(key("debug.saveGoroutineDump"))
                        .disabled(!workspace.debug.isDebugMode)
                    }
                }

                CommandMenu("Source Control") {
                    if appEnvironment.menusReady {
                        let repo = caps.hasWorkspace && workspace.git.isRepository == true
                        let idle = workspace.sourceControl.runningOperation == nil
                        let changed = !workspace.git.changedFiles.isEmpty
                        let conflicted = !workspace.git.conflictedPaths.isEmpty
                        Button("Commit…", systemImage: "checkmark.circle") { workspace.showCommitEditor() }
                            .keyboardShortcut(key("sc.commit"))
                            .disabled(!repo)
                        Button("Commit Changes", systemImage: "checkmark.circle.fill") { workspace.commitFromEditor(andPush: false) }
                            .keyboardShortcut(key("sc.commitChanges"))
                            .disabled(!workspace.commitEditorCanCommit)
                        Button("Push…", systemImage: "arrow.up") { workspace.sourceControl.sheet = .push }
                            .keyboardShortcut(key("sc.push"))
                            .disabled(!repo || !idle || !workspace.hasNamedBranch)
                        Button("Pull…", systemImage: "arrow.down") { workspace.sourceControl.sheet = .pull }
                            .keyboardShortcut(key("sc.pull"))
                            .disabled(!repo || !idle || !workspace.hasNamedBranch)
                        Button("Fetch Changes", systemImage: "arrow.down.circle") { workspace.fetchChanges() }
                            .keyboardShortcut(key("sc.fetch"))
                            .disabled(!repo || !idle)
                        Button("Refresh File Status", systemImage: "arrow.clockwise") { workspace.refreshFileStatusFromUser() }
                            .keyboardShortcut(key("sc.refresh"))
                            .disabled(!repo)

                        Divider()

                        Button("Stage All Changes", systemImage: "plus.circle") { workspace.stageAllFiles() }
                            .keyboardShortcut(key("sc.stageAll"))
                            .disabled(!repo || (workspace.unstagedNonConflictFiles.isEmpty && workspace.editedWorkspacePathsNotInGit.isEmpty))
                        Button("Unstage All Changes", systemImage: "minus.circle") { workspace.unstageAllFiles() }
                            .keyboardShortcut(key("sc.unstageAll"))
                            .disabled(!repo || workspace.git.stagedFilesCount == 0)
                        Button("Stage Selected Files", systemImage: "plus") { workspace.stageSelectedFiles() }
                            .keyboardShortcut(key("sc.stageSelected"))
                            .disabled(!repo || !caps.canStageActiveFile)
                        Button("Unstage Selected Files", systemImage: "minus") { workspace.unstageSelectedFiles() }
                            .keyboardShortcut(key("sc.unstageSelected"))
                            .disabled(!repo || !caps.canUnstageActiveFile)
                        Button("Mark as Resolved", systemImage: "checkmark.seal") { workspace.markSelectedFileResolved() }
                            .keyboardShortcut(key("sc.markResolved"))
                            .disabled(!repo || !caps.isActiveFileConflicted)
                        Button("Open in Merge Editor", systemImage: "rectangle.split.3x1") { workspace.openMergeEditor(workspace.activeFilePath) }
                            .keyboardShortcut(key("sc.mergeEditor"))
                            .disabled(!repo || !workspace.canOpenMergeEditor)

                        Divider()

                        Button("Stash Changes…", systemImage: "archivebox") { workspace.sourceControl.sheet = .stash }
                            .keyboardShortcut(key("sc.stash"))
                            .disabled(!repo || workspace.git.recentCommits.isEmpty || workspace.git.changedFiles.isEmpty || conflicted)
                        Button("Interactive Rebase…", systemImage: "list.bullet.indent") { workspace.showInteractiveRebase(from: nil) }
                            .keyboardShortcut(key("sc.interactiveRebase"))
                            .disabled(!workspace.canStartInteractiveRebase)

                        Divider()

                        Button("Discard All Changes…", systemImage: "arrow.uturn.backward.circle") { workspace.confirmDiscardAllChanges() }
                            .keyboardShortcut(key("sc.discardAll"))
                            .disabled(!repo || !changed)
                        Button("Discard Changes in Selected Files…", systemImage: "arrow.uturn.backward") { workspace.confirmDiscardSelectedFiles() }
                            .keyboardShortcut(key("sc.discardSelected"))
                            .disabled(!repo || !caps.hasActiveFileGitChanges)

                        Divider()

                        Button("New Branch…", systemImage: "arrow.triangle.branch") { workspace.sourceControl.sheet = .newBranch(from: nil) }
                            .keyboardShortcut(key("sc.newBranch"))
                            .disabled(!repo)
                        Button("New Worktree…", systemImage: "folder.badge.plus") { workspace.sourceControl.sheet = .newWorktree(branch: nil) }
                            .keyboardShortcut(key("scm.newWorktree"))
                            .disabled(!repo)
                        Menu("Switch Branch", systemImage: "arrow.left.arrow.right") {
                            ForEach(workspace.git.branches, id: \.self) { branch in
                                Toggle(branch, systemImage: "arrow.triangle.branch", isOn: Binding(
                                    get: { branch == workspace.git.branchName },
                                    set: { _ in workspace.switchBranchStashingIfNeeded(branch) }
                                ))
                            }
                        }
                        .disabled(!repo || workspace.git.branches.count < 2)

                        Divider()

                        Button("New Git Repository", systemImage: "plus.rectangle.on.folder") { workspace.createGitRepository() }
                            .keyboardShortcut(key("sc.newRepository"))
                            .disabled(!caps.hasWorkspace || workspace.git.isRepository != false)
                        Button("Clone…", systemImage: "square.and.arrow.down") { workspace.sourceControl.sheet = .clone }
                            .keyboardShortcut(key("sc.clone"))
                            .disabled(!caps.hasWorkspace)
                    }
                }

                CommandMenu("Tools") {
                    if appEnvironment.menusReady {
                        Menu("HTTP Client", systemImage: "network") {
                            Button("New HTTP Request File", systemImage: "network.badge.shield.half.filled") {
                                workspace.newHTTPRequestFile()
                            }
                            .keyboardShortcut(key("file.newHTTPRequest"))
                            .disabled(!caps.hasWorkspace)

                            Divider()

                            Button("Run HTTP Request", systemImage: "paperplane.fill") {
                                workspace.runHTTPRequestAtCaret()
                            }
                            .keyboardShortcut(key("product.runHTTPRequest"))
                            .disabled(!caps.isHTTPFile)

                            Button("Run All HTTP Requests in File", systemImage: "paperplane.circle") {
                                workspace.runAllHTTPRequestsInActiveFile()
                            }
                            .keyboardShortcut(key("product.runAllHTTPRequests"))
                            .disabled(!caps.isHTTPFile || (!workspace.http.runAllPaths.isEmpty && workspace.http.runAllPaths.contains(workspace.activeFilePath)))

                            Button("Stop HTTP Requests", systemImage: "stop.circle") {
                                workspace.stopAllHTTPRequests()
                            }
                            .keyboardShortcut(key("product.stopHTTPRequests"))
                            .disabled(!workspace.isAnyHTTPRequestRunning)

                            Menu("HTTP Environment", systemImage: "globe") {
                                HTTPEnvironmentMenuItems(workspace: workspace, path: caps.isHTTPFile ? workspace.activeFilePath : "")
                            }
                            .disabled(!caps.isHTTPFile)

                            Button("Show HTTP Responses", systemImage: "network") {
                                workspace.showRequestsPanel()
                            }
                            .keyboardShortcut(key("product.showHTTPResponses"))
                        }

                        Menu("Database", systemImage: "cylinder.split.1x2") {
                            Button("Data Sources…", systemImage: "cylinder.split.1x2") {
                                workspace.presentDataSources()
                            }
                            .keyboardShortcut(key("database.dataSources"))
                            .disabled(!caps.hasWorkspace)

                            Button("Detect Data Sources in Project…", systemImage: DatabaseSymbol.detect) {
                                workspace.detectDataSourcesInProject()
                            }
                            .keyboardShortcut(key("database.detectDataSources"))
                            .disabled(!caps.hasWorkspace)

                            Button("New Query Console", systemImage: "square.and.pencil") {
                                workspace.newQueryConsole()
                            }
                            .keyboardShortcut(key("database.newConsole"))
                            .disabled(!caps.hasDataSources)

                            Divider()

                            Button("Run Statement", systemImage: "play.fill") {
                                workspace.runDatabaseStatement()
                            }
                            .keyboardShortcut(key("database.runStatement"))
                            .disabled(!caps.isAttachedConsole)

                            Button("Run All Statements in File", systemImage: "play.square.stack") {
                                workspace.runAllDatabaseStatements()
                            }
                            .keyboardShortcut(key("database.runAll"))
                            .disabled(!caps.isAttachedConsole)

                            Button("Stop Statement", systemImage: "stop.circle") {
                                workspace.stopDatabaseStatement()
                            }
                            .keyboardShortcut(key("database.stop"))
                            .disabled(!caps.canStopDatabaseStatement)

                            Button("Explain Plan", systemImage: DatabaseSymbol.explain) {
                                workspace.explainDatabaseStatement(analyze: false)
                            }
                            .keyboardShortcut(key("database.explainPlan"))
                            .disabled(!caps.isAttachedConsole)

                            Button("Explain Analyze", systemImage: DatabaseSymbol.explain) {
                                workspace.explainDatabaseStatement(analyze: true)
                            }
                            .keyboardShortcut(key("database.explainAnalyze"))
                            .disabled(!caps.isAttachedConsole)

                            Button("Query History…", systemImage: DatabaseSymbol.history) {
                                workspace.showQueryHistory()
                            }
                            .keyboardShortcut(key("database.queryHistory"))
                            .disabled(!caps.hasDataSources)

                            Divider()

                            Button("Run SQL", systemImage: "play.fill") {
                                workspace.runGoSQLAtCaret()
                            }
                            .keyboardShortcut(key("database.runGoSQL"))
                            .disabled(!caps.isGoFile || !caps.hasDataSources)

                            Button("Run Query", systemImage: "play.fill") {
                                workspace.runSqlcQueryAtCaret()
                            }
                            .keyboardShortcut(key("database.runSqlcQuery"))
                            .disabled(!caps.isSQLFile || !caps.hasDataSources)

                            Menu("Default Data Source") {
                                Picker("Default Data Source", selection: Binding(
                                    get: { workspace.defaultDataSource?.id ?? "" },
                                    set: { workspace.setDefaultDataSource($0) }
                                )) {
                                    ForEach(workspace.database.definitions) { source in
                                        Text(source.name).tag(source.id)
                                    }
                                }
                                .pickerStyle(.inline)
                            }
                            .disabled(!caps.hasDataSources)

                            Divider()

                            Button("Submit Changes", systemImage: DatabaseSymbol.submit) {
                                workspace.submitDatabaseChanges()
                            }
                            .keyboardShortcut(key("database.submitChanges"))
                            .disabled(!caps.hasDataSources)

                            Button("Commit", systemImage: DatabaseSymbol.commit) {
                                workspace.commitActiveDatabaseTransaction()
                            }
                            .keyboardShortcut(key("database.commit"))
                            .disabled(!caps.hasDataSources)

                            Button("Roll Back", systemImage: DatabaseSymbol.rollBack) {
                                workspace.rollBackActiveDatabaseTransaction()
                            }
                            .keyboardShortcut(key("database.rollBack"))
                            .disabled(!caps.hasDataSources)

                            Menu("Transaction Mode") {
                                Button("Auto-Commit") { workspace.setActiveDatabaseTransactionMode(.auto) }
                                Button("Manual") { workspace.setActiveDatabaseTransactionMode(.manual) }
                            }
                            .disabled(!caps.hasDataSources)

                            Button("Export Result…", systemImage: DatabaseSymbol.export) {
                                workspace.presentExportResult()
                            }
                            .keyboardShortcut(key("database.exportResult"))
                            .disabled(!caps.hasDataSources)

                            Divider()

                            Menu("Attach Console To", systemImage: "link") {
                                DatabaseAttachMenuItems(workspace: workspace, path: caps.isSQLFile ? workspace.activeFilePath : "")
                            }
                            .disabled(!caps.isSQLFile || !caps.hasDataSources)

                            Button("Disconnect", systemImage: "bolt.slash") {
                                if let id = workspace.activeDatabaseConsoleDataSourceID { workspace.disconnectDataSource(id) }
                            }
                            .keyboardShortcut(key("database.disconnect"))
                            .disabled(!caps.isAttachedDataSourceConnected)

                            Button("Show Database Panel", systemImage: "cylinder") {
                                workspace.showDatabasePanel()
                            }
                            .keyboardShortcut(key("database.showPanel"))
                            .disabled(!caps.hasDataSources)
                        }

                        Menu("Containers & Compose", systemImage: "shippingbox") {
                            let compose = workspace.projectComposeFile
                            let services = ServicesStore.shared
                            let container = services.selectedContainer(in: workspace)
                            Button("Generate Dockerfile for Go Project…", systemImage: "doc.badge.plus") {
                                workspace.presentGenerateDockerfile()
                            }
                            .keyboardShortcut(key("docker.generateDockerfile"))
                            .disabled(!caps.hasWorkspace || !workspace.hasGoModule)

                            Divider()

                            Button("Validate Compose File", systemImage: "checkmark.seal") {
                                workspace.validateComposeFile(workspace.activeFilePath)
                            }
                            .keyboardShortcut(key("docker.validateCompose"))
                            .disabled(!caps.isDockerComposeFile)

                            Divider()

                            Button("Build Image", systemImage: "hammer") {
                                workspace.runDockerBuildCommand(dockerfilePath: workspace.activeFilePath, stage: nil)
                            }
                            .keyboardShortcut(key("docker.buildImage"))
                            .disabled(!caps.isDockerfile)

                            Button("Compose Up", systemImage: "play.fill") {
                                if let compose { workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "up") }
                            }
                            .keyboardShortcut(key("docker.composeUp"))
                            .disabled(compose == nil)

                            Button("Compose Down…", systemImage: "stop.fill") {
                                if let compose { workspace.confirmComposeDown(composePath: compose) }
                            }
                            .keyboardShortcut(key("docker.composeDown"))
                            .disabled(compose == nil)

                            Button("Compose Logs", systemImage: "text.alignleft") {
                                if let compose { workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "logs") }
                            }
                            .keyboardShortcut(key("docker.composeLogs"))
                            .disabled(compose == nil)

                            Divider()

                            Button("Show Logs", systemImage: ServiceSymbol.logs) {
                                services.show(.logs, in: workspace)
                            }
                            .keyboardShortcut(key("services.showLogs"))
                            .disabled(container == nil)

                            Button("Show Details", systemImage: ServiceSymbol.details) {
                                services.show(.details, in: workspace)
                            }
                            .keyboardShortcut(key("services.showDetails"))
                            .disabled(container == nil)

                            Button("Open Shell", systemImage: ServiceSymbol.shell) {
                                if let container { services.openShell(container, in: workspace) }
                            }
                            .keyboardShortcut(key("services.openShell"))
                            .disabled(container.map { services.shellUnavailableReason($0) != nil } ?? true)

                            Button("Restart", systemImage: ServiceSymbol.restart) {
                                if let container { services.perform("restart", on: container, from: workspace) }
                            }
                            .keyboardShortcut(key("services.restart"))
                            .disabled(container?.isRunning != true)

                            Button("Open in Browser", systemImage: ServiceSymbol.openInBrowser) {
                                if let container { services.openInBrowser(container, from: workspace) }
                            }
                            .keyboardShortcut(key("services.openInBrowser"))
                            .disabled(container.map { services.browserUnavailableReason($0) != nil } ?? true)

                            Button("Rebuild and Restart", systemImage: ServiceSymbol.rebuild) {
                                if let container { services.runServiceAction("rebuild", on: container, in: workspace) }
                            }
                            .keyboardShortcut(key("services.rebuildService"))
                            .disabled(container.map { services.composeService($0, in: workspace) == nil } ?? true)

                            Divider()

                            Button("Clean Up…", systemImage: ServiceSymbol.cleanUp) {
                                services.presentCleanUp(in: workspace)
                            }
                            .keyboardShortcut(key("services.cleanUp"))
                            .disabled(!caps.hasWorkspace)

                            Menu("Docker Context", systemImage: ServiceSymbol.context) {
                                DockerContextMenuItems(workspace: workspace)
                            }
                            .disabled((services.contexts?.contexts.count ?? 0) < 2)
                            .onAppear { if services.contexts == nil { services.loadContexts() } }
                        }

                        Menu("Kubernetes", systemImage: ServiceSymbol.kubernetes) {
                            let services = ServicesStore.shared
                            let kube = services.kube
                            let window = services.window(for: workspace)
                            let pod = services.selectedKubePod(in: workspace)
                            let deployment = services.selectedKubeDeployment(in: workspace)
                            let forwardTarget = services.selectedForwardTarget(in: workspace)
                            Button("Show Kubernetes", systemImage: ServiceSymbol.kubernetes) {
                                services.showKubernetes(in: workspace)
                            }
                            .keyboardShortcut(key("kube.show"))
                            .disabled(!caps.hasWorkspace)

                            Button("Apply to Cluster…", systemImage: ServiceSymbol.apply) {
                                services.presentApply(in: workspace)
                            }
                            .keyboardShortcut(key("kube.applyToCluster"))
                            .disabled(!caps.isKubernetesManifest)

                            Divider()

                            Button("Show Previous Logs", systemImage: ServiceSymbol.logs) {
                                services.showPreviousLogs(true, in: window)
                                workspace.showServicesPanel()
                            }
                            .keyboardShortcut(key("kube.showPreviousLogs"))
                            .disabled((pod?.restarts ?? 0) == 0)

                            Button("Open Shell in Pod", systemImage: ServiceSymbol.shell) {
                                if let pod { services.openKubeShell(pod, in: window, workspace: workspace) }
                            }
                            .keyboardShortcut(key("kube.openShell"))
                            .disabled(pod.map { services.kubeShellUnavailableReason($0) != nil } ?? true)

                            Button("Port Forward…", systemImage: ServiceSymbol.portForward) {
                                if let forwardTarget { services.requestForward(forwardTarget, in: window, workspace: workspace) }
                            }
                            .keyboardShortcut(key("kube.portForward"))
                            .disabled(forwardTarget.map { services.forwardUnavailableReason(ports: $0.ports) != nil } ?? true)

                            Button("Delete Pod…", systemImage: ServiceSymbol.remove) {
                                if let pod { services.requestDeletePod(pod.name, in: window, from: workspace) }
                            }
                            .keyboardShortcut(key("kube.deletePod"))
                            .disabled(pod == nil || kube.isReadOnly)

                            Button("Rollout Restart…", systemImage: ServiceSymbol.restart) {
                                if let deployment { services.requestRolloutRestart(deployment.name, in: window, from: workspace) }
                            }
                            .keyboardShortcut(key("kube.rolloutRestart"))
                            .disabled(deployment == nil || kube.isReadOnly)

                            Divider()

                            Menu("Context", systemImage: ServiceSymbol.context) {
                                KubeContextMenuItems()
                            }
                            .disabled(!kube.isAvailable)

                            Menu("Namespace", systemImage: ServiceSymbol.namespace) {
                                KubeNamespaceMenuItems(window: window)
                            }
                            .disabled(!kube.isAvailable)

                            Toggle("Read-Only for This Context", isOn: Binding(get: { kube.isReadOnly }, set: { _ in services.toggleReadOnly() }))
                                .keyboardShortcut(key("kube.readOnly"))
                                .disabled(!kube.isAvailable)

                            Button("Use as kubectl Default…", systemImage: ServiceSymbol.kubectlDefault) {
                                services.requestUseAsKubectlDefault(in: window, from: workspace)
                            }
                            .keyboardShortcut(key("kube.useAsDefault"))
                            .disabled(!kube.isAvailable || kube.contexts?.current == kube.context || kube.settingDefault)
                        }
                        .onAppear { if ServicesStore.shared.kube.contexts == nil { ServicesStore.shared.loadKubeContexts() } }

                        Menu("Code Analysis", systemImage: "doc.text.magnifyingglass") {
                            Button("Inspect Struct Memory Layout…", systemImage: "memorychip") {
                                workspace.presentStructLayoutSheet()
                            }
                            .keyboardShortcut(key("inspect.structLayout"))
                            .disabled(!caps.isGoFile)

                            Button("Inspect Function Complexity…", systemImage: "chart.bar.xaxis") {
                                workspace.openFunctionComplexityInspector()
                            }
                            .keyboardShortcut(key("inspect.complexity"))
                            .disabled(!caps.hasWorkspace && !caps.isGoFile)

                            Button("Compiler Optimization & Live Disassembly…", systemImage: "cpu") {
                                workspace.presentCompilerOptimizationSheet()
                            }
                            .keyboardShortcut(key("inspect.disassembly"))
                            .disabled(!caps.isGoFile)

                            Divider()

                            Button("Inspect Package Dependencies…", systemImage: "shippingbox") {
                                workspace.presentPackageDependenciesSheet()
                            }
                            .keyboardShortcut(key("navigate.packageDependencies"))
                            .disabled(!caps.hasWorkspace)

                            Button("Compare Benchmarks with Baseline…", systemImage: "chart.bar.xaxis") {
                                workspace.presentBenchmarkComparisonSheet()
                            }
                            .keyboardShortcut(key("product.compareBenchmarks"))
                            .disabled(!caps.hasWorkspace)
                        }

                        Menu("Scratchpad & Data", systemImage: "note.text.badge.plus") {
                            Button("New Go Scratch File", systemImage: "note.text.badge.plus") {
                                workspace.openOrCreateGoScratchFile()
                            }
                            .keyboardShortcut(key("file.newScratch"))
                            .disabled(!caps.hasWorkspace)

                            Button("Convert JSON to Go Struct…", systemImage: "curlybraces") {
                                workspace.presentPasteJSONStructSheet()
                            }
                            .keyboardShortcut(key("generate.jsonToStruct"))
                            .disabled(!caps.isGoFile)
                        }
                    }
                }

                CommandGroup(before: .windowList) {
                    Button("Select Previous Tab", systemImage: "chevron.backward.square") {
                        workspace.selectPreviousTab()
                    }
                    .keyboardShortcut(key("view.previousTab"))
                    .disabled(workspace.openFiles.count < 2)

                    Button("Select Next Tab", systemImage: "chevron.forward.square") {
                        workspace.selectNextTab()
                    }
                    .keyboardShortcut(key("view.nextTab"))
                    .disabled(workspace.openFiles.count < 2)

                    Divider()
                }

                CommandGroup(replacing: .help) {
                    OpenGetStartedCommand()
                    OpenKeyboardShortcutsCommand()
                    Divider()
                    Button("Workspace Diagnostics…", systemImage: "stethoscope") {
                        workspace.showWorkspaceDiagnosticsSheet = true
                    }
                    .keyboardShortcut(key("help.diagnostics"))
                    Button("Report a Problem…", systemImage: "exclamationmark.bubble") {
                        workspace.showReportProblemSheet = true
                    }
                    .keyboardShortcut(key("help.reportProblem"))
                }
            }
        }

        Window("Welcome to GoLens", id: "welcome") {
            WelcomeView()
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
                .background(DocumentationWindowOpenerBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About GoLens", id: "about") {
            AboutGoLensView()
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView()
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("Documentation Browser", id: DocumentationBrowserView.windowID, for: String.self) { $workspaceRoot in
            DocumentationBrowserView(workspaceRoot: workspaceRoot ?? "")
                .background(DocumentationWindowOpenerBridge())
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
        }
        .defaultSize(width: WindowLayout.defaultWidth, height: WindowLayout.defaultHeight)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        Settings {
            SettingsView()
                .preferredColorScheme(workspace.systemAppearanceIsDark ? .dark : .light)
        }
    }
}

