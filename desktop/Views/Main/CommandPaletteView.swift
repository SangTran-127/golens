import GoLensFoundation
import SwiftUI
import AppKit

@MainActor
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    let shortcut: String
    let icon: String?
    let alias: String
    var isFeatured: Bool = false
    let commandID: String?
    let action: () -> Void

    init(
        title: String,
        category: String = "",
        shortcut: String = "",
        icon: String? = nil,
        alias: String = "",
        isFeatured: Bool = false,
        commandID: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = commandID ?? title
        self.title = title
        if !category.isEmpty {
            self.category = category
        } else if let commandID, let cmd = Keymap.commandsByID[commandID] {
            self.category = cmd.menu
        } else {
            self.category = ""
        }
        self.shortcut = shortcut
        self.icon = icon
        self.alias = alias
        self.isFeatured = isFeatured
        self.commandID = commandID
        self.action = action
    }
}

@MainActor
enum CommandPaletteView {
    static func buildCommands(
        workspace: WorkspaceState,
        invokingEditor: EditorCaretAnchor,
        openWindow: OpenWindowAction
    ) -> [PaletteCommand] {
        var all: [PaletteCommand] = [
            PaletteCommand(title: "Show Code Actions", category: "Editor", shortcut: keymapShortcut("editor.codeActions"), icon: "wand.and.stars", alias: "contextual ast quick fixes", commandID: "editor.codeActions") {
                workspace.activePopup = nil
                if let tv = workspace.activeTextView as? GoLensTextView {
                    workspace.showCodeActionsMenu(for: tv)
                }
            },
            PaletteCommand(title: "Recent Files", category: "Navigate", shortcut: keymapShortcut("navigate.recentFiles"), icon: "clock", commandID: "navigate.recentFiles") {
                workspace.activePopup = .recentFiles
            },
            PaletteCommand(title: "Toggle Bookmark on Current Line", category: "Navigate ▸ Bookmarks", shortcut: keymapShortcut("navigate.toggleBookmark"), icon: "bookmark", commandID: "navigate.toggleBookmark") {
                workspace.activePopup = nil
                workspace.toggleBookmarkAtCaret()
            },
            PaletteCommand(title: "Next Bookmark", category: "Navigate ▸ Bookmarks", shortcut: keymapShortcut("navigate.nextBookmark"), icon: "bookmark.fill", commandID: "navigate.nextBookmark") {
                workspace.activePopup = nil
                workspace.navigateToNextBookmark()
            },
            PaletteCommand(title: "Previous Bookmark", category: "Navigate ▸ Bookmarks", shortcut: keymapShortcut("navigate.previousBookmark"), icon: "bookmark", commandID: "navigate.previousBookmark") {
                workspace.activePopup = nil
                workspace.navigateToPreviousBookmark()
            },
            PaletteCommand(title: "Show Bookmarks", category: "Navigate ▸ Bookmarks", shortcut: keymapShortcut("navigate.showBookmarks"), icon: "list.bullet.rectangle", commandID: "navigate.showBookmarks") {
                workspace.activePopup = nil
                workspace.selectedIssuesNavigatorSubtab = .bookmarks
                workspace.showNavigator(.issues)
            },
            PaletteCommand(title: "Show Project TODOs & FIXMEs", category: "Navigate", shortcut: keymapShortcut("navigate.showTodos"), icon: "checklist", commandID: "navigate.showTodos") {
                workspace.activePopup = nil
                workspace.selectedIssuesNavigatorSubtab = .todos
                workspace.showNavigator(.issues)
            },
            PaletteCommand(title: "Organize Imports", category: "Editor", shortcut: keymapShortcut("editor.organizeImports"), icon: "arrow.up.arrow.down", commandID: "editor.organizeImports") {
                workspace.activePopup = nil
                workspace.organizeImportsActiveDocument()
            },
            PaletteCommand(title: "New Window", category: "File", shortcut: keymapShortcut("file.newWindow"), icon: "macwindow.badge.plus", commandID: "file.newWindow") {
                workspace.activePopup = nil
                WorkspaceSessionRegistry.shared.presentWorkspacePickerWindow()
            },
            PaletteCommand(title: "Open Quickly", category: "File", shortcut: keymapShortcut("file.openQuickly"), icon: "magnifyingglass", commandID: "file.openQuickly") {
                workspace.activePopup = .openQuickly
            },
            PaletteCommand(title: "Go to Symbol in File", category: "Navigate", shortcut: keymapShortcut("navigate.symbolInFile"), icon: "list.bullet.indent", commandID: "navigate.symbolInFile") {
                workspace.activePopup = .goToSymbol
            },
            PaletteCommand(title: "Go to Workspace Symbol…", category: "Navigate", shortcut: keymapShortcut("navigate.workspaceSymbol"), icon: "number.square", commandID: "navigate.workspaceSymbol") {
                workspace.activePopup = .workspaceSymbol
            },
            PaletteCommand(title: "Go to Line", category: "Navigate", shortcut: keymapShortcut("navigate.goToLine"), icon: "number", commandID: "navigate.goToLine") {
                workspace.activePopup = nil
                workspace.showGoToLineSheet = true
            },
            PaletteCommand(title: "Go to Implementation", category: "Navigate", shortcut: keymapShortcut("navigate.implementation"), icon: "arrow.down.right.circle", commandID: "navigate.implementation") {
                workspace.activePopup = nil
                workspace.goToImplementationAtCaret()
            },
            PaletteCommand(title: "Go to Type Definition", category: "Navigate", shortcut: keymapShortcut("navigate.typeDefinition"), icon: "t.square", commandID: "navigate.typeDefinition") {
                workspace.activePopup = nil
                workspace.goToTypeDefinitionAtCaret()
            },
            PaletteCommand(title: "Call Hierarchy", category: "Navigate", shortcut: keymapShortcut("navigate.callHierarchy"), icon: "arrow.triangle.branch", commandID: "navigate.callHierarchy") {
                workspace.activePopup = nil
                workspace.showCallHierarchyAtCaret()
            },
            PaletteCommand(title: "Type Hierarchy", category: "Navigate", shortcut: keymapShortcut("navigate.typeHierarchy"), icon: "list.bullet.indent", commandID: "navigate.typeHierarchy") {
                workspace.activePopup = nil
                workspace.showTypeHierarchyAtCaret()
            },
            PaletteCommand(title: "Inspect Package Dependencies…", category: "Tools ▸ Code Analysis", shortcut: keymapShortcut("navigate.packageDependencies"), icon: "shippingbox", commandID: "navigate.packageDependencies") {
                workspace.activePopup = nil
                workspace.presentPackageDependenciesSheet()
            },
            PaletteCommand(title: "Jump to Test / Tested Symbol", category: "Navigate", shortcut: keymapShortcut("navigate.jumpToTest"), icon: "checkmark.diamond", commandID: "navigate.jumpToTest") {
                workspace.activePopup = nil
                workspace.jumpBetweenCodeAndTest()
            },
            PaletteCommand(title: "Rename Symbol…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.rename"), icon: "character.cursor.ibeam", alias: "rename refactor identifier variable function type in place", commandID: "refactor.rename") {
                workspace.activePopup = nil
                DispatchQueue.main.async { [invokingEditor] in invokingEditor.rename() }
            },
            PaletteCommand(title: "Change Signature…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.changeSignature"), icon: "signature", commandID: "refactor.changeSignature") {
                workspace.activePopup = nil
                workspace.triggerChangeSignature()
            },
            PaletteCommand(title: "Generate Constructor", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.constructor"), icon: "hammer", commandID: "generate.constructor") {
                workspace.activePopup = nil
                workspace.generateConstructorAtCaret()
            },
            PaletteCommand(title: "Generate Constructor & Options…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.constructorOptions"), icon: "slider.horizontal.3", commandID: "generate.constructorOptions") {
                workspace.activePopup = nil
                workspace.openGenerateConstructorSheet()
            },
            PaletteCommand(title: "Extract Interface", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.extractInterface"), icon: "puzzlepiece.extension", commandID: "refactor.extractInterface") {
                workspace.activePopup = nil
                workspace.extractInterfaceAtCaret()
            },
            PaletteCommand(title: "Implement Interface…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.implementInterface"), icon: "checkmark.seal", commandID: "refactor.implementInterface") {
                workspace.activePopup = nil
                workspace.presentImplementInterfaceSheet()
            },
            PaletteCommand(title: "Generate Interface Mock…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.mock"), icon: "rectangle.on.rectangle.angled", commandID: "generate.mock") {
                workspace.activePopup = nil
                workspace.presentGenerateInterfaceMockSheet()
            },
            PaletteCommand(title: "Generate Enum / Stringer Methods…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.enumStringer"), icon: "list.bullet.indent", commandID: "generate.enumStringer") {
                workspace.activePopup = nil
                workspace.openGenerateEnumMethodsSheet()
            },
            PaletteCommand(title: "Fill Struct Fields", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.fillStruct"), icon: "list.bullet.rectangle", commandID: "generate.fillStruct") {
                workspace.activePopup = nil
                workspace.fillStructFieldsAtCursor()
            },
            PaletteCommand(title: "Add Go Module…", category: "Product", shortcut: keymapShortcut("product.addGoModule"), icon: "shippingbox", commandID: "product.addGoModule") {
                workspace.activePopup = nil
                workspace.presentAddGoModuleSheet()
            },
            PaletteCommand(title: "Move Symbol…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.moveSymbol"), icon: "arrow.right.doc.on.clipboard", commandID: "refactor.moveSymbol") {
                workspace.activePopup = nil
                workspace.presentMoveSymbolSheet()
            },
            PaletteCommand(title: "Expand Selection", category: "Edit", shortcut: keymapShortcut("edit.expandSelection"), icon: "arrow.up.left.and.arrow.down.right", commandID: "edit.expandSelection") {
                workspace.activePopup = nil
                workspace.expandSyntaxSelection()
            },
            PaletteCommand(title: "Shrink Selection", category: "Edit", shortcut: keymapShortcut("edit.shrinkSelection"), icon: "arrow.down.right.and.arrow.up.left", commandID: "edit.shrinkSelection") {
                workspace.activePopup = nil
                workspace.shrinkSyntaxSelection()
            },
            PaletteCommand(title: "Attach to Process…", category: "Product", shortcut: keymapShortcut("product.attach"), icon: "ladybug", commandID: "product.attach") {
                workspace.activePopup = nil
                workspace.presentAttachProcessSheet()
            },
            PaletteCommand(title: "Open Profile (.pprof)…", category: "Product", shortcut: keymapShortcut("product.openProfile"), icon: "gauge.with.dots.needle.67percent", commandID: "product.openProfile") {
                workspace.activePopup = nil
                workspace.promptAndImportPprofFile()
            },
            PaletteCommand(title: "Find in File", category: "Find", shortcut: keymapShortcut("find.find"), icon: "magnifyingglass", commandID: "find.find") {
                workspace.activePopup = nil
                workspace.showLocalSearch = true
            },
            PaletteCommand(title: "Find Next", category: "Find", shortcut: keymapShortcut("find.findNext"), icon: "chevron.down", commandID: "find.findNext") {
                workspace.activePopup = nil
                workspace.selectNextLocalMatch()
            },
            PaletteCommand(title: "Find Previous", category: "Find", shortcut: keymapShortcut("find.findPrevious"), icon: "chevron.up", commandID: "find.findPrevious") {
                workspace.activePopup = nil
                workspace.selectPreviousLocalMatch()
            },
            PaletteCommand(title: "Project Search", category: "Find", shortcut: keymapShortcut("find.findInProject"), icon: "text.magnifyingglass", commandID: "find.findInProject") {
                workspace.activePopup = nil
                workspace.showNavigator(.search)
            },
            PaletteCommand(title: "Local History: Show File History…", category: "File", shortcut: keymapShortcut("file.localHistory"), icon: "clock.arrow.circlepath", commandID: "file.localHistory") {
                workspace.activePopup = nil
                workspace.presentLocalHistory()
            },
            PaletteCommand(title: "Terminal: Open in Current File's Folder", category: "Tools", shortcut: "", icon: "terminal") {
                workspace.activePopup = nil
                let target = workspace.activeFilePath.isEmpty ? workspace.activeWorkspacePath : workspace.activeFilePath
                workspace.openTerminal(atDirectory: target)
            },
            PaletteCommand(title: "Docker: Generate Dockerfile for Go Project…", category: "Tools ▸ Containers & Compose", shortcut: keymapShortcut("docker.generateDockerfile"), icon: "shippingbox", commandID: "docker.generateDockerfile") {
                workspace.activePopup = nil
                workspace.presentGenerateDockerfile()
            },
            PaletteCommand(title: "Run Project", category: "Product", shortcut: keymapShortcut("product.run"), icon: "play.fill", commandID: "product.run") {
                workspace.activePopup = nil
                if !workspace.isTestRunning && !workspace.debug.isDebugMode && workspace.activeGoCommand == nil {
                    workspace.runProject()
                }
            },
            PaletteCommand(title: "Debug Project", category: "Product", shortcut: keymapShortcut("product.debug"), icon: "ladybug.fill", commandID: "product.debug") {
                workspace.activePopup = nil
                if !workspace.isRunning { workspace.debugProject() }
            },
            PaletteCommand(title: "Run HTTP Request", category: "Tools ▸ HTTP Client", shortcut: keymapShortcut("product.runHTTPRequest"), icon: "paperplane.fill", commandID: "product.runHTTPRequest") {
                workspace.activePopup = nil
                workspace.runHTTPRequestAtCaret()
            },
            PaletteCommand(title: "Run All HTTP Requests in File", category: "Tools ▸ HTTP Client", shortcut: keymapShortcut("product.runAllHTTPRequests"), icon: "paperplane.circle", commandID: "product.runAllHTTPRequests") {
                workspace.activePopup = nil
                workspace.runAllHTTPRequestsInActiveFile()
            },
            PaletteCommand(title: "New HTTP Request File", category: "Tools ▸ HTTP Client", shortcut: keymapShortcut("file.newHTTPRequest"), icon: "network", commandID: "file.newHTTPRequest") {
                workspace.activePopup = nil
                workspace.newHTTPRequestFile()
            },
            PaletteCommand(title: "Show HTTP Responses", category: "Tools ▸ HTTP Client", shortcut: keymapShortcut("product.showHTTPResponses"), icon: "network", commandID: "product.showHTTPResponses") {
                workspace.activePopup = nil
                workspace.showRequestsPanel()
            },
            PaletteCommand(title: "Data Sources…", category: "Tools ▸ Database", shortcut: keymapShortcut("database.dataSources"), icon: "cylinder.split.1x2", commandID: "database.dataSources") {
                workspace.activePopup = nil
                workspace.presentDataSources()
            },
            PaletteCommand(title: "New Query Console", category: "Tools ▸ Database", shortcut: keymapShortcut("database.newConsole"), icon: "square.and.pencil", commandID: "database.newConsole") {
                workspace.activePopup = nil
                workspace.newQueryConsole()
            },
            PaletteCommand(title: "Run Statement", category: "Tools ▸ Database", shortcut: keymapShortcut("database.runStatement"), icon: "play.fill", commandID: "database.runStatement") {
                workspace.activePopup = nil
                workspace.runDatabaseStatement()
            },
            PaletteCommand(title: "Run All Statements in File", category: "Tools ▸ Database", shortcut: keymapShortcut("database.runAll"), icon: "play.square.stack", commandID: "database.runAll") {
                workspace.activePopup = nil
                workspace.runAllDatabaseStatements()
            },
            PaletteCommand(title: "Stop Statement", category: "Tools ▸ Database", shortcut: keymapShortcut("database.stop"), icon: "stop.circle", commandID: "database.stop") {
                workspace.activePopup = nil
                workspace.stopDatabaseStatement()
            },
            PaletteCommand(title: "Show Database Panel", category: "Tools ▸ Database", shortcut: keymapShortcut("database.showPanel"), icon: "cylinder", commandID: "database.showPanel") {
                workspace.activePopup = nil
                workspace.showDatabasePanel()
            },
            PaletteCommand(title: "Run Tests with Coverage", category: "Product", shortcut: keymapShortcut("product.coverage"), icon: "checkmark.shield", commandID: "product.coverage") {
                workspace.activePopup = nil
                if !workspace.isRunning && !workspace.activeWorkspacePath.isEmpty {
                    workspace.runTestsWithCoverage()
                }
            },
            PaletteCommand(title: "Run Test at Cursor", category: "Product", shortcut: keymapShortcut("product.testAtCursor"), icon: "play.fill", commandID: "product.testAtCursor") {
                workspace.activePopup = nil
                workspace.runTestAtCursor()
            },
            PaletteCommand(title: "Debug Test at Cursor", category: "Product", shortcut: keymapShortcut("product.debugTestAtCursor"), icon: "ladybug.fill", commandID: "product.debugTestAtCursor") {
                workspace.activePopup = nil
                workspace.debugTestAtCursor()
            },
            PaletteCommand(title: "Repeat Last Test", category: "Product", shortcut: keymapShortcut("product.repeatLastTest"), icon: "arrow.clockwise", commandID: "product.repeatLastTest") {
                workspace.activePopup = nil
                workspace.repeatLastTest()
            },
            PaletteCommand(title: "Profile Tests", category: "Product", shortcut: keymapShortcut("product.profileTests"), icon: "gauge.with.dots.needle.67percent", commandID: "product.profileTests") {
                workspace.activePopup = nil
                if !workspace.isRunning && !workspace.activeWorkspacePath.isEmpty {
                    workspace.profileAllTests()
                }
            },
            PaletteCommand(title: "Run Benchmarks", category: "Product", shortcut: keymapShortcut("product.benchmarks"), icon: "stopwatch", commandID: "product.benchmarks") {
                workspace.activePopup = nil
                if !workspace.isRunning && !workspace.activeWorkspacePath.isEmpty {
                    workspace.runAllBenchmarks()
                }
            },
            PaletteCommand(title: "Run Safety Audit", category: "Product", shortcut: keymapShortcut("product.safetyAudit"), icon: "checkmark.shield", commandID: "product.safetyAudit") {
                workspace.activePopup = nil
                if !workspace.activeWorkspacePath.isEmpty {
                    workspace.runSafetyAudit()
                }
            },
            PaletteCommand(title: "Show Suggestion", category: "Editor", shortcut: keymapShortcut("editor.showSuggestion"), icon: "sparkles", commandID: "editor.showSuggestion") {
                workspace.activePopup = nil
                DispatchQueue.main.async {
                    (workspace.activeTextView as? GoLensTextView)?.inlineSuggestions.showNow()
                }
            },
            PaletteCommand(title: "Read Suggestion", category: "Editor", shortcut: keymapShortcut("editor.readSuggestion"), icon: "speaker.wave.2", commandID: "editor.readSuggestion") {
                workspace.activePopup = nil
                (workspace.activeTextView as? GoLensTextView)?.inlineSuggestions.readSuggestion()
            },
            PaletteCommand(title: "AI Suggestion Settings…", category: "Gopilot", icon: "sparkles") {
                workspace.activePopup = nil
                openAISuggestionsSettings()
            },
            PaletteCommand(title: "Reset Build Target to Host Default", category: "Product", icon: "cpu") {
                workspace.activePopup = nil
                workspace.resetBuildTarget()
            },
            PaletteCommand(title: "Run go generate", category: "Product", shortcut: keymapShortcut("product.goGenerate"), icon: "gearshape.2", commandID: "product.goGenerate") {
                workspace.activePopup = nil
                if !workspace.isRunning && !workspace.activeWorkspacePath.isEmpty && workspace.hasGoModule {
                    workspace.runGoGenerate()
                }
            },
            PaletteCommand(title: "Stop Project", category: "Product", shortcut: keymapShortcut("product.stop"), icon: "stop.fill", commandID: "product.stop") {
                workspace.activePopup = nil
                workspace.stopActiveRun()
            },
            PaletteCommand(title: "Toggle Console", category: "View", shortcut: keymapShortcut("view.console"), icon: "rectangle.bottomthird.inset.filled", commandID: "view.console") {
                workspace.activePopup = nil
                workspace.showConsole.toggle()
            },
            PaletteCommand(title: "Toggle Minimap", category: "View", shortcut: keymapShortcut("view.minimap"), icon: "sidebar.squares.right", commandID: "view.minimap") {
                workspace.activePopup = nil
                workspace.showMinimap.toggle()
            },
            PaletteCommand(title: "Toggle Word Wrap", category: "View", shortcut: keymapShortcut("view.toggleWordWrap"), icon: "text.word.spacing", commandID: "view.toggleWordWrap") {
                workspace.activePopup = nil
                workspace.wordWrapEnabled.toggle()
            },
            PaletteCommand(title: "Select Previous Tab", category: "Window", shortcut: keymapShortcut("view.previousTab"), icon: "chevron.backward.square", commandID: "view.previousTab") {
                workspace.activePopup = nil
                workspace.selectPreviousTab()
            },
            PaletteCommand(title: "Select Next Tab", category: "Window", shortcut: keymapShortcut("view.nextTab"), icon: "chevron.forward.square", commandID: "view.nextTab") {
                workspace.activePopup = nil
                workspace.selectNextTab()
            },
            PaletteCommand(title: "Toggle Inlay Hints", category: "View", shortcut: keymapShortcut("view.inlayHints"), icon: "tag", commandID: "view.inlayHints") {
                workspace.activePopup = nil
                workspace.toggleInlayHints()
            },
            PaletteCommand(title: "Explain Selection with Gopilot", category: "Gopilot", icon: "text.magnifyingglass", alias: "ai explain code selection gopilot") {
                workspace.activePopup = nil
                DispatchQueue.main.async { workspace.gopilot.explainSelection(workspace: workspace) }
            },
            PaletteCommand(title: "Trace This Flow with Gopilot", category: "Gopilot", icon: "arrow.triangle.branch", alias: "ai trace flow callers gopilot") {
                workspace.activePopup = nil
                DispatchQueue.main.async { workspace.gopilot.traceFlow(workspace: workspace) }
            },
            PaletteCommand(title: "Show Gopilot", category: "View", shortcut: keymapShortcut("view.gopilot"), icon: "sparkles", alias: "ai copilot chat assistant ask", commandID: "view.gopilot") {
                workspace.activePopup = nil
                workspace.gopilot.isPanelVisible = true
            },
            PaletteCommand(title: "Quick Documentation", category: "View", shortcut: keymapShortcut("view.quickDocumentation"), icon: "questionmark.circle", alias: "show docs hover symbol godoc", commandID: "view.quickDocumentation") {
                workspace.activePopup = nil
                DispatchQueue.main.async { [invokingEditor] in invokingEditor.showQuickDocumentation() }
            },
            PaletteCommand(title: "Quick Definition", category: "View", shortcut: keymapShortcut("view.quickDefinition"), icon: "rectangle.and.text.magnifyingglass", alias: "peek definition source declaration preview", commandID: "view.quickDefinition") {
                workspace.activePopup = nil
                DispatchQueue.main.async { [invokingEditor] in invokingEditor.showQuickDocumentation(kind: .definition) }
            },
            PaletteCommand(title: "Documentation Browser", category: "View", shortcut: keymapShortcut("view.documentationBrowser"), icon: "book", alias: "docs godoc api reference package browser", commandID: "view.documentationBrowser") {
                workspace.activePopup = nil
                DocumentationService.shared.openBrowser(for: workspace.activeWorkspacePath.isEmpty ? nil : workspace, focusSearch: true)
            },
            PaletteCommand(title: "Toggle Inline Git Blame", category: "View", shortcut: keymapShortcut("view.inlineBlame"), icon: "person.text.rectangle", commandID: "view.inlineBlame") {
                workspace.activePopup = nil
                workspace.toggleInlineGitBlame()
            },
            PaletteCommand(title: "Code Lenses: Automatic (By Display)", category: "View", shortcut: "", icon: "eyeglasses", alias: "optical lens column inline 13 inch adaptive") {
                workspace.activePopup = nil
                workspace.opticalLensDisplayMode = .automatic
            },
            PaletteCommand(title: "Code Lenses: Always Column", category: "View", shortcut: "", icon: "eyeglasses", alias: "optical lens margin wide") {
                workspace.activePopup = nil
                workspace.opticalLensDisplayMode = .column
            },
            PaletteCommand(title: "Code Lenses: Always Inline", category: "View", shortcut: "", icon: "eyeglasses", alias: "optical lens compact macbook 13 inch") {
                workspace.activePopup = nil
                workspace.opticalLensDisplayMode = .inline
            },
            PaletteCommand(title: "Code Lenses: Off", category: "View", shortcut: "", icon: "eyeglasses", alias: "hide code lenses") {
                workspace.activePopup = nil
                workspace.opticalLensDisplayMode = .off
            },
            PaletteCommand(title: "Toggle Go Escape Analysis", category: "View", shortcut: keymapShortcut("view.escapeAnalysis"), icon: "memorychip", commandID: "view.escapeAnalysis") {
                workspace.activePopup = nil
                workspace.toggleEscapeAnalysis()
            },
            PaletteCommand(title: "Profile Application", category: "Product", shortcut: keymapShortcut("product.profile"), icon: "gauge.with.dots.needle.67percent", commandID: "product.profile") {
                workspace.activePopup = nil
                workspace.profileProject()
            },
            PaletteCommand(title: "Modify Struct Tags…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.structTags"), icon: "tag", commandID: "generate.structTags") {
                workspace.activePopup = nil
                workspace.presentStructTagsSheet()
            },
            PaletteCommand(title: "Convert JSON to Go Struct…", category: "Tools ▸ Scratchpad & Data", shortcut: keymapShortcut("generate.jsonToStruct"), icon: "curlybraces", commandID: "generate.jsonToStruct") {
                workspace.activePopup = nil
                workspace.presentPasteJSONStructSheet()
            },
            PaletteCommand(title: "Inspect Struct Memory Layout…", category: "Tools ▸ Code Analysis", shortcut: keymapShortcut("inspect.structLayout"), icon: "chart.bar.doc.horizontal", commandID: "inspect.structLayout") {
                workspace.activePopup = nil
                workspace.presentStructLayoutSheet()
            },
            PaletteCommand(title: "Extract Function…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.extractFunction"), icon: "function", commandID: "refactor.extractFunction") {
                workspace.activePopup = nil
                workspace.presentExtractMethodSheet()
            },
            PaletteCommand(title: "Extract Variable", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.extractVariable"), icon: "equal.square", commandID: "refactor.extractVariable") {
                workspace.activePopup = nil
                workspace.extractVariableAtSelection()
            },
            PaletteCommand(title: "Inline Variable", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.inlineVariable"), icon: "arrow.down.to.line.compact", commandID: "refactor.inlineVariable") {
                workspace.activePopup = nil
                workspace.inlineVariableAtCaret()
            },
            PaletteCommand(title: "Extract Type Definition…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.extractType"), icon: "t.square", commandID: "refactor.extractType") {
                workspace.activePopup = nil
                workspace.presentExtractTypeSheet()
            },
            PaletteCommand(title: "Propagate Method to Implementations…", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.propagateMethod"), icon: "arrow.triangle.branch", commandID: "refactor.propagateMethod") {
                workspace.activePopup = nil
                workspace.presentPropagateInterfaceSheet()
            },
            PaletteCommand(title: "Inspect Function Complexity…", category: "Tools ▸ Code Analysis", shortcut: keymapShortcut("inspect.complexity"), icon: "chart.bar.doc.horizontal", commandID: "inspect.complexity") {
                workspace.activePopup = nil
                workspace.openFunctionComplexityInspector()
            },
            PaletteCommand(title: "Compiler Optimization & Live Disassembly…", category: "Tools ▸ Code Analysis", shortcut: keymapShortcut("inspect.disassembly"), icon: "cpu", commandID: "inspect.disassembly") {
                workspace.activePopup = nil
                workspace.presentCompilerOptimizationSheet()
            },
            PaletteCommand(title: "Generate Fuzz Test…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.fuzzTest"), icon: "wand.and.stars", commandID: "generate.fuzzTest") {
                workspace.activePopup = nil
                workspace.openGenerateFuzzTestSheet()
            },
            PaletteCommand(title: "Generate Go Benchmark…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.benchmark"), icon: "stopwatch", commandID: "generate.benchmark") {
                workspace.activePopup = nil
                workspace.openGenerateBenchmarkSheet()
            },
            PaletteCommand(title: "Generate Table-Driven Test…", category: "Editor ▸ Generate", shortcut: keymapShortcut("generate.tableTest"), icon: "checkmark.diamond", commandID: "generate.tableTest") {
                workspace.activePopup = nil
                workspace.presentGenerateTableDrivenTestSheet()
            },
            PaletteCommand(title: "Handle Error with if err != nil", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.handleError"), icon: "exclamationmark.triangle", commandID: "refactor.handleError") {
                workspace.activePopup = nil
                workspace.applyGoIntention("wrap_err")
            },
            PaletteCommand(title: "Convert Between ':=' and 'var'", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.toggleVarAssign"), icon: "arrow.left.arrow.right", commandID: "refactor.toggleVarAssign") {
                workspace.activePopup = nil
                workspace.applyGoIntention("toggle_var_assign")
            },
            PaletteCommand(title: "Convert Between Raw and Interpreted String", category: "Editor ▸ Refactor", shortcut: keymapShortcut("refactor.toggleString"), icon: "quote.opening", commandID: "refactor.toggleString") {
                workspace.activePopup = nil
                workspace.applyGoIntention("toggle_string")
            },
            PaletteCommand(title: "New Go Scratch File", category: "Tools ▸ Scratchpad & Data", shortcut: keymapShortcut("file.newScratch"), icon: "note.text.badge.plus", commandID: "file.newScratch") {
                workspace.activePopup = nil
                workspace.openOrCreateGoScratchFile()
            },
            PaletteCommand(title: "Run Go Scratch File", category: "Tools ▸ Scratchpad & Data", icon: "play.circle") {
                workspace.activePopup = nil
                workspace.runGoScratchFile()
            },
            PaletteCommand(title: "Compare Benchmarks with Baseline…", category: "Tools ▸ Code Analysis", shortcut: keymapShortcut("product.compareBenchmarks"), icon: "chart.bar.xaxis", commandID: "product.compareBenchmarks") {
                workspace.activePopup = nil
                workspace.presentBenchmarkComparisonSheet()
            },
            PaletteCommand(title: "Pin Current Benchmarks as Baseline", category: "Tools ▸ Code Analysis", icon: "pin") {
                workspace.activePopup = nil
                workspace.pinCurrentBenchmarksAsBaseline()
            },
            PaletteCommand(title: "Discard Change at Cursor", category: "Source Control", shortcut: keymapShortcut("git.revertHunk"), icon: "arrow.uturn.backward", alias: "Revert Git Hunk at Cursor") {
                workspace.activePopup = nil
                workspace.revertGitHunkAtLine(max(1, workspace.cursorLine), inPath: workspace.activeFilePath)
            },
            PaletteCommand(title: "Stage Change at Cursor", category: "Source Control", shortcut: keymapShortcut("git.stageHunk"), icon: "plus.circle", alias: "Stage Hunk at Cursor") {
                workspace.activePopup = nil
                workspace.stageGitHunkAtLine(nil, inPath: workspace.activeFilePath)
            },
            PaletteCommand(title: "Check Go Module Updates", category: "Product", icon: "arrow.triangle.2.circlepath") {
                workspace.activePopup = nil
                let goModPath = (workspace.activeWorkspacePath as NSString).appendingPathComponent("go.mod")
                workspace.checkGoModUpdates(forPath: goModPath)
            },
            PaletteCommand(title: "Workspace Diagnostics…", category: "Help", shortcut: keymapShortcut("help.diagnostics"), icon: "stethoscope", commandID: "help.diagnostics") {
                workspace.activePopup = nil
                workspace.showWorkspaceDiagnosticsSheet = true
            },
            PaletteCommand(title: "About GoLens…", category: "GoLens", icon: "info.circle") {
                workspace.activePopup = nil
                openWindow(id: "about")
            },
        ]

        all += workspace.recentProjects.filter { $0 != workspace.activeWorkspacePath }.map { path in
            PaletteCommand(title: "Open Recent Project: \(workspace.recentProjectTitle(path))", category: "File ▸ Open Recent", icon: "folder") {
                workspace.activePopup = nil
                workspace.openRecentProject(path: path)
            }
        }
        if !workspace.activeWorkspacePath.isEmpty {
            all.append(PaletteCommand(title: "Restart Language Server", category: "Help", icon: "arrow.clockwise", alias: "reload window gopls lsp", commandID: "help.restartLSP") {
                workspace.activePopup = nil
                workspace.restartLanguageServer()
            })
        }
        if SandboxVMManager.shared.executionMode == .linuxVM, case .running = SandboxVMManager.shared.state {
            all.append(PaletteCommand(title: "Restart Linux Machine", category: "Help", icon: "arrow.clockwise", alias: "reload window vm container memory", commandID: "help.restartVM") {
                workspace.activePopup = nil
                Task { try? await SandboxVMManager.shared.restart() }
            })
        }
        if workspace.hasCoverageData {
            all.append(PaletteCommand(title: "Clear Coverage", category: "Product", shortcut: keymapShortcut("product.clearCoverage"), icon: "xmark.shield", commandID: "product.clearCoverage") {
                workspace.activePopup = nil
                workspace.clearCoverage()
            })
        }
        if workspace.canPasteJSONAsGoStruct {
            all.append(PaletteCommand(title: "Paste JSON / YAML / .env as Go Struct", category: "Tools ▸ Scratchpad & Data", shortcut: keymapShortcut("edit.pasteJSONAsStruct"), icon: "curlybraces", commandID: "edit.pasteJSONAsStruct") {
                workspace.activePopup = nil
                workspace.pasteJSONAsGoStruct()
            })
        }
        if workspace.canFormatActiveEcosystemDocument {
            all.append(PaletteCommand(title: "Format Document (Go / JSON / YAML / Makefile / .env)", category: "Editor", shortcut: keymapShortcut("editor.format"), icon: "text.alignleft", commandID: "editor.format") {
                workspace.activePopup = nil
                workspace.formatActiveDocument()
            })
        }
        if EcosystemDocumentTools.isMarkdownFile(workspace.activeFilePath) {
            all.append(PaletteCommand(title: "Toggle Markdown & Mermaid Preview", category: "View", icon: "eye") {
                workspace.activePopup = nil
                let cur = workspace.markdownPreviewMode[workspace.activeFilePath] ?? false
                workspace.markdownPreviewMode[workspace.activeFilePath] = !cur
            })
        } else if EcosystemDocumentTools.isEnvFile(workspace.activeFilePath) {
            all.append(PaletteCommand(title: workspace.envSecretsMasked ? "Show .env Secrets" : "Mask .env Secrets", category: "View", icon: "eye.slash") {
                workspace.activePopup = nil
                workspace.envSecretsMasked.toggle()
                workspace.activeTextView?.needsDisplay = true
            })
            all.append(PaletteCommand(title: "Apply .env Variables to Active Run Configuration", category: "Product", icon: "play.circle") {
                workspace.activePopup = nil
                workspace.applyEnvFileToActiveRunConfig(envPath: workspace.activeFilePath)
            })
        }
        if workspace.isGitRepositoryOpen {
            let sc: [(String, String, String, String, () -> Void)] = [
                ("Commit…", "sc.commit", "checkmark.circle", "git commit", { workspace.showCommitEditor() }),
                ("Push…", "sc.push", "arrow.up.circle", "git push", { workspace.sourceControl.sheet = .push }),
                ("Pull…", "sc.pull", "arrow.down.circle", "git pull", { workspace.sourceControl.sheet = .pull }),
                ("Fetch Changes", "sc.fetch", "arrow.down.to.line", "git fetch", { workspace.fetchChanges() }),
                ("Refresh File Status", "sc.refresh", "arrow.clockwise", "git status", { workspace.refreshFileStatusFromUser() }),
                ("Stage All Changes", "sc.stageAll", "plus.circle", "git add", { workspace.stageAllFiles() }),
                ("Unstage All Changes", "sc.unstageAll", "minus.circle", "git reset", { workspace.unstageAllFiles() }),
                ("Stash Changes…", "sc.stash", "archivebox", "git stash", { workspace.sourceControl.sheet = .stash }),
                ("Discard All Changes…", "sc.discardAll", "trash", "git checkout revert", { workspace.confirmDiscardAllChanges() }),
                ("New Branch…", "sc.newBranch", "arrow.triangle.branch", "git branch create", { workspace.sourceControl.sheet = .newBranch(from: nil) }),
                ("New Worktree…", "scm.newWorktree", "folder.badge.plus", "git worktree add", { workspace.sourceControl.sheet = .newWorktree(branch: nil) }),
                ("Jump to Next Change", "navigate.nextChange", "chevron.down", "git next hunk", { workspace.jumpToChange(forward: true) }),
                ("Jump to Previous Change", "navigate.previousChange", "chevron.up", "git previous hunk", { workspace.jumpToChange(forward: false) }),
                ("Show Code Review", "view.codeReview", "rectangle.split.2x1", "git diff compare", { workspace.toggleCodeReview() }),
            ]
            let busy = workspace.sourceControl.runningOperation != nil
            let changed = !workspace.git.changedFiles.isEmpty
            for (title, id, icon, alias, run) in sc {
                if busy && ["sc.push", "sc.pull", "sc.fetch"].contains(id) { continue }
                if !changed && ["sc.stash", "sc.discardAll", "sc.stageAll"].contains(id) { continue }
                all.append(PaletteCommand(title: title, category: "Source Control", shortcut: keymapShortcut(id), icon: icon, alias: alias, commandID: id) {
                    workspace.activePopup = nil
                    run()
                })
            }
        }
        if !workspace.showsSourceControlChanges {
            let changeCommands: Set<String> = ["Discard Change at Cursor", "Stage Change at Cursor", "Jump to Next Change", "Jump to Previous Change"]
            all.removeAll { changeCommands.contains($0.title) }
        }

        appendRemainingKeymapCommands(into: &all, workspace: workspace)
        all.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return all
    }

    private static func appendRemainingKeymapCommands(into commands: inout [PaletteCommand], workspace: WorkspaceState) {
        var coveredIDs = Set(commands.compactMap(\.commandID))
        coveredIDs.insert("view.commandPalette")
        coveredIDs.insert("generate.test")
        var coveredNormalized = Set(commands.map { normalizeCommandTitle($0.title) })

        for cmd in KeymapCommand.all where !cmd.isSystemOnly {
            guard !coveredIDs.contains(cmd.id) else { continue }
            let norm = normalizeCommandTitle(cmd.title)
            guard !coveredNormalized.contains(norm) else { continue }
            guard let menuItem = findMainMenuItem(menuPath: cmd.menu, title: cmd.title), menuItem.isEnabled else {
                continue
            }
            coveredIDs.insert(cmd.id)
            coveredNormalized.insert(norm)
            let targetMenuPath = cmd.menu
            let targetTitle = cmd.title
            let dynamicTitle = cmd.title
            commands.append(
                PaletteCommand(
                    title: dynamicTitle,
                    category: cmd.menu,
                    shortcut: KeymapStore.shared.display(cmd.id),
                    icon: iconForMenuCategory(cmd.menu),
                    alias: cmd.menu.lowercased(),
                    commandID: cmd.id
                ) {
                    workspace.activePopup = nil
                    DispatchQueue.main.async {
                        invokeMainMenuItem(menuPath: targetMenuPath, title: targetTitle)
                    }
                }
            )
        }
    }

    private static func normalizeCommandTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("…") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private static func findMainMenuItem(menuPath: String, title: String) -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let parts = menuPath.components(separatedBy: " ▸ ").map { $0.trimmingCharacters(in: .whitespaces) }
        var currentMenu: NSMenu? = mainMenu
        for part in parts {
            currentMenu?.update()
            guard let match = currentMenu?.items.first(where: { $0.title == part }),
                  let sub = match.submenu else {
                return nil
            }
            currentMenu = sub
        }
        currentMenu?.update()
        let normalizedTarget = normalizeCommandTitle(title)
        return currentMenu?.items.first(where: {
            $0.title == title || normalizeCommandTitle($0.title) == normalizedTarget
        })
    }

    private static func invokeMainMenuItem(menuPath: String, title: String) {
        guard let item = findMainMenuItem(menuPath: menuPath, title: title),
              let menu = item.menu,
              item.isEnabled else { return }
        let idx = menu.index(of: item)
        if idx >= 0 {
            menu.performActionForItem(at: idx)
        }
    }

    private static func iconForMenuCategory(_ menu: String) -> String {
        if menu.hasPrefix("File") { return "doc" }
        if menu.hasPrefix("Edit") { return "pencil" }
        if menu.hasPrefix("View") { return "sidebar.left" }
        if menu.hasPrefix("Find") { return "magnifyingglass" }
        if menu.hasPrefix("Navigate") { return "location" }
        if menu.hasPrefix("Editor ▸ Refactor") { return "slider.horizontal.3" }
        if menu.hasPrefix("Editor ▸ Generate") { return "wand.and.stars" }
        if menu.hasPrefix("Editor") { return "curlybraces" }
        if menu.hasPrefix("Product") { return "hammer" }
        if menu.hasPrefix("Debug") { return "ladybug" }
        if menu.hasPrefix("Source Control") { return "arrow.triangle.branch" }
        if menu.hasPrefix("Tools ▸ HTTP Client") { return "network" }
        if menu.hasPrefix("Tools ▸ Containers") { return "shippingbox" }
        if menu.hasPrefix("Tools ▸ Kubernetes") { return ServiceSymbol.kubernetes }
        if menu.hasPrefix("Tools ▸ Code Analysis") { return "chart.bar.doc.horizontal" }
        if menu.hasPrefix("Tools") { return "wrench.and.screwdriver" }
        if menu.hasPrefix("Window") { return "macwindow" }
        return "command"
    }
}

private func keymapShortcut(_ id: String) -> String {
    KeymapStore.shared.display(id)
}
