import Foundation
import GoLensFoundation
import SwiftUI
import Observation
import SwiftTerm

struct WindowEditorTransientState {
    var documentSymbolsPath: String = ""
    var syntaxSelectionStack: [NSRange] = []
    var lastExpandedRange: NSRange? = nil
    var syntaxAnchorByteOffset: Int? = nil
    var syntaxSelectionPath: String? = nil
    var caretBlameTask: Task<Void, Never>? = nil
    var commitDetailTask: Task<Void, Never>? = nil
    var signatureHelpGeneration: Int = 0
    var lastRunToken: Int = 0

    mutating func resetForWorkspaceChange() {
        documentSymbolsPath = ""
        syntaxSelectionStack.removeAll()
        lastExpandedRange = nil
        syntaxAnchorByteOffset = nil
        syntaxSelectionPath = nil
        caretBlameTask?.cancel()
        caretBlameTask = nil
        commitDetailTask?.cancel()
        commitDetailTask = nil
        signatureHelpGeneration &+= 1
        lastRunToken &+= 1
    }
}

@Observable
class WorkspaceState: @unchecked Sendable {
    let router = WindowPresentationRouter()
    let sourceControlState = SourceControlUI()
    let fileRowStates = FileRowStateStore()
    let diagnosticsCenter = DiagnosticsCenter()
    let repositories = GitRepositoryStore()
    let commandCapabilities = CommandCapabilitiesStore()
    let modals = WorkspaceModalState()
    let refactorPreviews = WorkspaceRefactorPreviewState()
    let testing = WorkspaceTestingState()
    let diagnosticsAndLenses = WorkspaceDiagnosticsAndLensState()
    let searchNav = WorkspaceSearchAndNavigationState()
    let execution = WorkspaceExecutionState()
    let primaryPane = EditorPaneState(paneID: .primary)
    let secondaryPane = EditorPaneState(paneID: .secondary)
    let restoreLastOnSetup: Bool

    var focusedPaneID: EditorPaneID = .primary {
        didSet {
            guard focusedPaneID != oldValue else { return }
            if let tv = editorTextView(for: focusedPaneID) {
                activeTextView = tv
            }
            let pane = paneState(for: focusedPaneID)
            editorHasSelection = pane.hasSelection
            let position = "Ln \(pane.cursorLine), Col \(pane.cursorCol)"
            if displayCursorPosition != position {
                displayCursorPosition = position
            }
            refreshCommandCapabilities()
        }
    }

    var git = GitState()
    var lsp = LSPState()
    var gopilot = GopilotState()
    var debug = DebugState()
    var http = HTTPClientState()
    let database = DatabaseState()

    var displayCursorPosition: String = ""
    var largeFileModeRevision: Int = 0
    var commandFeedback: CommandFeedbackNotice? = nil
    @ObservationIgnored var commandFeedbackDismissWorkItem: DispatchWorkItem? = nil
    @ObservationIgnored var commandFeedbackKeyMonitor: Any? = nil
    var activeTraceSummary: TraceResult? = nil
    var activeTraceErrorMessage: String? = nil
    var isDebuggerPaused: Bool { debug.isDebugMode && debug.isPaused }
    @ObservationIgnored var memoryPressureSource: DispatchSourceMemoryPressure? = nil
    @ObservationIgnored var transientEditorState = WindowEditorTransientState()

    let lspQueue = DispatchQueue(label: "golens.lsp.queue", qos: .userInitiated)
    let lspRequestQueue = DispatchQueue(label: "golens.lsp.requests", qos: .userInitiated, attributes: .concurrent)
    let lspCommandQueue = DispatchQueue(label: "golens.lsp.commands", qos: .userInitiated)
    let agentQueue = DispatchQueue(label: "golens.agent.queue", qos: .userInitiated)
    var fileSystemWatcher: FileSystemWatcher?
    @ObservationIgnored
    var isReloading = false
    @ObservationIgnored
    var pendingFileSystemChange = FileSystemChange()
    @ObservationIgnored
    var pendingReload = false

    var activeWorkspacePath: String = "" {
        didSet {
            if !activeWorkspacePath.isEmpty {
                let canonical = URL(fileURLWithPath: activeWorkspacePath).resolvingSymlinksInPath().path
                if activeWorkspacePath != canonical {
                    activeWorkspacePath = canonical
                    return
                }
            }
            defer { refreshCommandCapabilities() }

            if activeWorkspacePath != openedWorkspaceRoot {
                if !openedWorkspaceRoot.isEmpty {
                    shutdownDatabase(root: openedWorkspaceRoot)
                    closeAllDocuments()
                    resetTerminalSessions()
                    resetRunSessions()
                    let rootToUnmount = openedWorkspaceRoot
                    if !activeWorkspacePath.isEmpty {
                        Self.releaseCoreRoot(rootToUnmount, excluding: self)
                    }
                    if Thread.isMainThread {
                        _ = MainActor.assumeIsolated {
                            SandboxVMManager.shared.unmountWorkspace(url: URL(fileURLWithPath: rootToUnmount))
                        }
                    } else {
                        _ = DispatchQueue.main.sync {
                            MainActor.assumeIsolated {
                                SandboxVMManager.shared.unmountWorkspace(url: URL(fileURLWithPath: rootToUnmount))
                            }
                        }
                    }
                }
                openedWorkspaceRoot = activeWorkspacePath
                transientEditorState.resetForWorkspaceChange()
                fileRowStates.reset()
                resetTestState()
                loadSavedBenchmarkBaseline()
                safetyFindings = []
                safetySummary = ""
                isSafetyAuditRunning = false
                hasSafetyData = false
                activeFileExcludedReason = nil
                moduleDownloadError = nil
                activeTraceSummary = nil
                activeTraceErrorMessage = nil
                dismissCommandFeedback()
                languageServerState = .idle
                DispatchQueue.main.async {
                    self.git.branchName = ""
                    self.git.branches = []
                    self.git.branchSummaries = []
                    self.git.changedFiles = []
                    self.git.isRepository = nil
                }
                if activeWorkspacePath.isEmpty {
                    if !Self.hasOtherOpenWorkspaces(excluding: self) {
                        CloseWorkspace()
                    }
                } else {
                    _ = SecurityScopedBookmarkManager.shared.resolveAndAccess(path: activeWorkspacePath)
                    let pathToMount = activeWorkspacePath
                    if Thread.isMainThread {
                        _ = MainActor.assumeIsolated {
                            SandboxVMManager.shared.mountWorkspaceSync(url: URL(fileURLWithPath: pathToMount))
                        }
                    } else {
                        _ = DispatchQueue.main.sync {
                            MainActor.assumeIsolated {
                                SandboxVMManager.shared.mountWorkspaceSync(url: URL(fileURLWithPath: pathToMount))
                            }
                        }
                    }
                    SetUsageIndexEnabled(Self.usageCountsEnabled ? 1 : 0)
                    activeWorkspacePath.withCString { OpenWorkspace($0) }
                    restoreSession(for: activeWorkspacePath)
                }
                let updatedPath = activeWorkspacePath
                Self.updateCallbackRoutingTable(for: self, workspacePath: updatedPath)
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        WorkspaceSessionRegistry.shared.notifyWorkspaceDidChange(for: self, canonicalPath: updatedPath)
                    }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            WorkspaceSessionRegistry.shared.notifyWorkspaceDidChange(for: self, canonicalPath: updatedPath)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.updateAutoFetchTimer() }
            }

            if activeWorkspacePath.isEmpty {
                DispatchQueue.main.async { LinuxSandboxProjects.shared.applyExecutionMode() }
                if !Self.hasOtherOpenWorkspaces(excluding: self) {
                    UserDefaults.standard.removeObject(forKey: "GoLensLastWorkspacePath")
                    UserDefaults.standard.removeObject(forKey: "GoLensLastFilePath")
                }
                loadBookmarksForWorkspace()
                loadBreakpointsForWorkspace()
                refreshWorkspaceTodos()
            } else {
                UserDefaults.standard.set(activeWorkspacePath, forKey: "GoLensLastWorkspacePath")
                SecurityScopedBookmarkManager.shared.saveBookmark(for: URL(fileURLWithPath: activeWorkspacePath))
                DispatchQueue.main.async {
                    GetStartedProgress.shared.complete(.openProject)
                    LinuxSandboxProjects.shared.applyExecutionMode()
                }
                refreshWorkspaceHealth()
                loadFiles(from: activeWorkspacePath)
                refreshDependencies()
                loadRunConfigurations()
                loadBookmarksForWorkspace()
                loadBreakpointsForWorkspace()
                refreshWorkspaceTodos()
            }

            loadDataSources()
            configureFileSystemWatcher()
        }
    }

    @ObservationIgnored
    var activeFileSwitchWorkItem: DispatchWorkItem?

    var activeFilePath: String = "" {
        didSet {
            defer { refreshCommandCapabilities() }
            dismissTransientEditorOverlays(includeRename: true, includePopovers: true)
            if activePopup == .references || activePopup == .hierarchy { activePopup = nil }
            if !isNavigatingHistory && !activeFilePath.isEmpty {
                if !oldValue.isEmpty,
                   navigationIndex >= 0,
                   navigationIndex < navigationCaretHistory.count,
                   navigationCaretHistory[navigationIndex].path == oldValue {
                    navigationCaretHistory[navigationIndex] = CaretHistoryEntry(
                        path: oldValue,
                        line: max(1, cursorLine),
                        col: max(1, cursorCol)
                    )
                }
                if navigationIndex >= 0 && navigationIndex < navigationHistory.count - 1 {
                    navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
                    if navigationCaretHistory.count > navigationIndex + 1 {
                        navigationCaretHistory = Array(navigationCaretHistory.prefix(navigationIndex + 1))
                    }
                }
                if navigationHistory.last != activeFilePath {
                    navigationHistory.append(activeFilePath)
                    navigationCaretHistory.append(CaretHistoryEntry(
                        path: activeFilePath,
                        line: max(1, pendingJumpToLine ?? 1),
                        col: max(1, pendingJumpToCol ?? 1)
                    ))
                    if navigationHistory.count > Self.maxNavigationHistory {
                        let excess = navigationHistory.count - Self.maxNavigationHistory
                        navigationHistory.removeFirst(excess)
                        if navigationCaretHistory.count >= excess {
                            navigationCaretHistory.removeFirst(excess)
                        }
                    }
                    navigationIndex = navigationHistory.count - 1
                }
            }

            if !activeFilePath.isEmpty {
                if let index = recentFiles.firstIndex(of: activeFilePath) {
                    recentFiles.remove(at: index)
                }
                recentFiles.insert(activeFilePath, at: 0)
                if recentFiles.count > 50 {
                    recentFiles.removeLast()
                }
            }

            guard activeFilePath != oldValue || (!activeFilePath.isEmpty && documents[activeFilePath] == nil) else {
                updateCaretLineBlame()
                return
            }

            clearLocalSearchHighlights(in: .primary)
            primaryPane.resetLocalSearch()
            dismissTransientEditorOverlays(includeRename: true, includePopovers: true)
            if !activeFilePath.hasSuffix(".go") {
                declarationsWorkItem?.cancel()
                activeGoDeclarations = []
            }

            if activeFilePath.isEmpty {
                UserDefaults.standard.removeObject(forKey: "GoLensLastFilePath")
            } else {
                UserDefaults.standard.set(activeFilePath, forKey: "GoLensLastFilePath")
            }
            scheduleSessionSave()
            activeFileSwitchWorkItem?.cancel()
            if !activeFilePath.isEmpty && editorMode(for: activeFilePath) == .diff {
                activeFileDiffTask?.cancel()
                return
            }
            if !activeFilePath.isEmpty {
                loadDocument(activeFilePath, synchronously: isRestoringAtLaunch)
            }
            syncVisibleDocuments()
            let targetPath = activeFilePath
            let switchWork = DispatchWorkItem { [weak self] in
                guard let self, self.activeFilePath == targetPath else { return }
                self.refreshActiveFileDiff()
                self.fetchDocumentSymbols()
                self.refreshActiveFileBuildTarget()
                self.syncCounterpartFile()
                self.updateCaretLineBlame()
                if self.showEscapeAnalysis && targetPath.hasSuffix(".go") {
                    self.reloadEscapeAnalysis(forPath: targetPath)
                }
            }
            activeFileSwitchWorkItem = switchWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: switchWork)
        }
    }

    var languageServerState: LanguageServerState = .idle {
        didSet { if oldValue != languageServerState { updateLanguageServerConditions(reportedRemote: nil) } }
    }

    var activeLine: Int = 1

    private static var initialShowConsole: Bool {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let flag = args["GoLensShowConsole"] as? Bool {
            return flag
        }
        if let text = args["GoLensShowConsole"] as? NSString {
            return text.boolValue
        }
        UserDefaults.standard.removeObject(forKey: "GoLensShowConsole")
        return false
    }

    var showConsole: Bool = WorkspaceState.initialShowConsole

    var showInlayHints: Bool = UserDefaults.standard.object(forKey: "GoLensShowInlayHints") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.showInlayHints, from: self)
            guard showInlayHints != oldValue else { return }
            UserDefaults.standard.set(showInlayHints, forKey: "GoLensShowInlayHints")
            NotificationCenter.default.post(name: .golensInlayHintsToggled, object: nil)
        }
    }

    static let showUsageCountsKey = "GoLensShowUsageCounts"
    static var usageCountsEnabled: Bool {
        UserDefaults.standard.object(forKey: showUsageCountsKey) as? Bool ?? true
    }

    var showUsageCounts: Bool = WorkspaceState.usageCountsEnabled {
        didSet {
            Self.shareSetting(\.showUsageCounts, from: self)
            guard showUsageCounts != oldValue else { return }
            UserDefaults.standard.set(showUsageCounts, forKey: Self.showUsageCountsKey)
            usageCountsSettingChanged()
        }
    }

    static let opticalLensDisplayModeKey = "GoLensOpticalLensDisplayMode"
    static var persistedOpticalLensDisplayMode: OpticalLensDisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: opticalLensDisplayModeKey),
              let parsed = OpticalLensDisplayMode(rawValue: raw) else {
            return .automatic
        }
        return parsed
    }
    static var currentOpticalLensDisplayMode: OpticalLensDisplayMode = WorkspaceState.persistedOpticalLensDisplayMode

    var opticalLensDisplayMode: OpticalLensDisplayMode = WorkspaceState.persistedOpticalLensDisplayMode {
        didSet {
            Self.shareSetting(\.opticalLensDisplayMode, from: self)
            guard opticalLensDisplayMode != oldValue else { return }
            Self.currentOpticalLensDisplayMode = opticalLensDisplayMode
            UserDefaults.standard.set(opticalLensDisplayMode.rawValue, forKey: Self.opticalLensDisplayModeKey)
            NotificationCenter.default.post(name: .golensOpticalLensModeChanged, object: nil)
            applyWordWrap(to: activeTextView)
            if primaryTextView !== activeTextView {
                applyWordWrap(to: primaryTextView)
            }
            applyWordWrap(to: secondaryTextView)
        }
    }

    var showMinimap: Bool = UserDefaults.standard.object(forKey: "GoLensShowMinimap") as? Bool ?? false {
        didSet {
            Self.shareSetting(\.showMinimap, from: self)
            UserDefaults.standard.set(showMinimap, forKey: "GoLensShowMinimap")
        }
    }

    var wordWrapEnabled: Bool = UserDefaults.standard.object(forKey: "GoLensWordWrap") as? Bool ?? false {
        didSet {
            Self.shareSetting(\.wordWrapEnabled, from: self)
            guard wordWrapEnabled != oldValue else { return }
            UserDefaults.standard.set(wordWrapEnabled, forKey: "GoLensWordWrap")
            applyWordWrap(to: activeTextView)
            if primaryTextView !== activeTextView {
                applyWordWrap(to: primaryTextView)
            }
            applyWordWrap(to: secondaryTextView)
        }
    }

    static let customGoBinaryPathKey = "GoLensCustomGoBinaryPath"

    var customGoBinaryPath: String = UserDefaults.standard.string(forKey: WorkspaceState.customGoBinaryPathKey) ?? "" {
        didSet {
            Self.shareSetting(\.customGoBinaryPath, from: self)
            guard customGoBinaryPath != oldValue else { return }
            if customGoBinaryPath.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.customGoBinaryPathKey)
            } else {
                UserDefaults.standard.set(customGoBinaryPath, forKey: Self.customGoBinaryPathKey)
            }
            syncCustomGoBinaryWithCore()
            refreshWorkspaceHealth()
        }
    }

    var editorFontSize: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "GoLensEditorFontSize")) == 0 ? 13.0 : CGFloat(UserDefaults.standard.double(forKey: "GoLensEditorFontSize")) {
        didSet {
            Self.shareSetting(\.editorFontSize, from: self)
            UserDefaults.standard.set(editorFontSize, forKey: "GoLensEditorFontSize")
            let updatedFont = TechnicalTypography.codeCanvasNSFont(size: editorFontSize, weight: .regular)
            activeTextView?.font = updatedFont
            activeTextView?.setNeedsDisplay(activeTextView?.bounds ?? .zero)
            if primaryTextView !== activeTextView {
                primaryTextView?.font = updatedFont
                primaryTextView?.setNeedsDisplay(primaryTextView?.bounds ?? .zero)
            }
            secondaryTextView?.font = updatedFont
            secondaryTextView?.setNeedsDisplay(secondaryTextView?.bounds ?? .zero)
        }
    }

    @ObservationIgnored
    var effectiveAppearanceObservation: NSKeyValueObservation? = nil

    var systemAppearanceIsDark: Bool = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua || UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

    var selectedThemeId: String = UserDefaults.standard.string(forKey: "GoLensSelectedThemeId") ?? "xcode" {
        didSet {
            Self.shareSetting(\.selectedThemeId, from: self)
            UserDefaults.standard.set(selectedThemeId, forKey: "GoLensSelectedThemeId")
            activeTextView?.needsDisplay = true
            updateWindowAppearance()
            if Thread.isMainThread {
                let themeId = selectedThemeId
                MainActor.assumeIsolated {
                    if AppEnvironment.shared.selectedThemeId != themeId {
                        AppEnvironment.shared.selectedThemeId = themeId
                    }
                }
            }
        }
    }

    var openFiles: [String] = [] {
        didSet { scheduleSessionSave() }
    }
    @ObservationIgnored
    var restoredViewStates: [String: SavedWorkspaceTabSession.View] = [:]
    @ObservationIgnored
    var sessionSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored
    var isClosingAllDocuments = false
    @ObservationIgnored
    var documents: [String: DocumentSession] = [:]
    var editedFiles: Set<String> = [] {
        didSet {
            for path in oldValue.subtracting(editedFiles) {
                UnsavedBufferJournal.forget(path)
            }
        }
    }
    var diskConflicts: Set<String> = []
    var deletedFiles: Set<String> = []
    var loadedDocuments: Set<String> = [] {
        didSet { refreshCommandCapabilities() }
    }
    @ObservationIgnored
    var pendingDocumentLoads: Set<String> = []
    @ObservationIgnored
    var openedWorkspaceRoot = ""
    var markdownPreviewMode: [String: Bool] = [:]
    var envSecretsMasked: Bool = true {
        didSet {
            if !activeFilePath.isEmpty, let session = documents[activeFilePath] {
                reloadGoplsCodeLenses(forPath: activeFilePath, version: session.version)
            }
            activeTextView?.needsDisplay = true
        }
    }
    var activeFileLineCount: Int = 1

    var isSplitMode: Bool = false {
        didSet {
            if isSplitMode {
                if (secondaryFilePath ?? "").isEmpty, !activeFilePath.isEmpty {
                    secondaryFilePath = activeFilePath
                }
                if isCounterpartSplitEnabled {
                    syncCounterpartFile()
                }
                refreshPaneSymbols(for: .secondary)
            } else {
                clearLocalSearchHighlights(in: .secondary)
                secondaryPane.resetLocalSearch()
                if focusedPaneID != .primary {
                    focusedPaneID = .primary
                }
                if let ptv = primaryTextView {
                    activeTextView = ptv
                    if let win = ptv.window, win.firstResponder === secondaryTextView {
                        win.makeFirstResponder(ptv)
                    }
                }
            }
            syncVisibleDocuments()
            scheduleSessionSave()
            refreshCommandCapabilities()
        }
    }
    var secondaryFilePath: String? = nil {
        didSet {
            if secondaryFilePath != oldValue {
                clearLocalSearchHighlights(in: .secondary)
                secondaryPane.resetLocalSearch()
            }
            if let secondary = secondaryFilePath, !secondary.isEmpty {
                loadDocument(secondary)
                if let session = documents[secondary] {
                    secondaryPane.lineCount = session.lines.count
                }
            } else {
                secondaryPane.goDeclarations = []
                secondaryPane.documentSymbols = []
                secondaryPane.breadcrumbSegments = []
            }
            refreshPaneSymbols(for: .secondary)
            syncVisibleDocuments()
            scheduleSessionSave()
            refreshCommandCapabilities()
        }
    }

    @ObservationIgnored
    weak var primaryTextView: NSTextView? = nil

    @ObservationIgnored
    weak var secondaryTextView: NSTextView? = nil

    func paneState(for paneID: EditorPaneID) -> EditorPaneState {
        paneID == .primary ? primaryPane : secondaryPane
    }

    var effectiveFocusedPaneID: EditorPaneID {
        isSplitMode ? focusedPaneID : .primary
    }

    var focusedPaneState: EditorPaneState {
        paneState(for: effectiveFocusedPaneID)
    }

    func filePath(for paneID: EditorPaneID) -> String {
        switch paneID {
        case .primary: return activeFilePath
        case .secondary: return secondaryFilePath ?? ""
        }
    }

    var focusedFilePath: String {
        let path = filePath(for: effectiveFocusedPaneID)
        return path.isEmpty ? activeFilePath : path
    }

    func editorTextView(for paneID: EditorPaneID) -> GoLensTextView? {
        switch paneID {
        case .primary: return primaryTextView as? GoLensTextView
        case .secondary: return secondaryTextView as? GoLensTextView
        }
    }

    func focusPane(_ paneID: EditorPaneID) {
        let resolved: EditorPaneID = isSplitMode ? paneID : .primary
        if focusedPaneID != resolved {
            focusedPaneID = resolved
        }
        if let tv = editorTextView(for: resolved) {
            activeTextView = tv
            tv.window?.makeFirstResponder(tv)
        }
    }

    func closeSecondarySplitPane() {
        if let sec = secondaryFilePath, !sec.isEmpty, editedFiles.contains(sec), !openFiles.contains(sec) {
            openFiles.append(sec)
        }
        isSplitMode = false
    }

    var files: [String] = []
    var fileTree: [FileItem] = []
    var externalDependencies: [FileItem] = []

    var externalTerminalApp: String = UserDefaults.standard.string(forKey: "GoLensExternalTerminalApp") ?? "Terminal" {
        didSet {
            Self.shareSetting(\.externalTerminalApp, from: self)
            UserDefaults.standard.set(externalTerminalApp, forKey: "GoLensExternalTerminalApp")
        }
    }
    var isSidebarVisible: Bool = true
    var cursorLine: Int = 1 {
        didSet {
            if cursorLine != oldValue {
                updateCaretLineBlame()
                syncCounterpartFunctionCaret(sourceLine: cursorLine)
            }
        }
    }
    var cursorCol: Int = 1
    var defaultTabSize: Int = UserDefaults.standard.object(forKey: "GoLensDefaultTabSize") as? Int ?? 4 {
        didSet {
            Self.shareSetting(\.defaultTabSize, from: self)
            UserDefaults.standard.set(defaultTabSize, forKey: "GoLensDefaultTabSize")
            tabSize = defaultTabSize
        }
    }
    var tabSize: Int = UserDefaults.standard.object(forKey: "GoLensDefaultTabSize") as? Int ?? 4

    var activeAIModel: String = UserDefaults.standard.string(forKey: "GoLensActiveAIModel") ?? "Gemini 1.5 Pro" {
        didSet {
            Self.shareSetting(\.activeAIModel, from: self)
            UserDefaults.standard.set(activeAIModel, forKey: "GoLensActiveAIModel")
        }
    }

    var selectedSidebarTab: Navigator = .files
    var pinnedTabs: Set<String> = []
    var previewTabPath: String? = nil
    var enablePreviewTab: Bool = UserDefaults.standard.object(forKey: "GoLensEnablePreviewTab") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.enablePreviewTab, from: self)
            UserDefaults.standard.set(enablePreviewTab, forKey: "GoLensEnablePreviewTab")
            if !enablePreviewTab {
                previewTabPath = nil
            }
        }
    }
    var formatOnSave: Bool = UserDefaults.standard.object(forKey: "GoLensFormatOnSave") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.formatOnSave, from: self)
            UserDefaults.standard.set(formatOnSave, forKey: "GoLensFormatOnSave")
        }
    }
    var organizeImportsOnSave: Bool = UserDefaults.standard.object(forKey: "GoLensOrganizeImportsOnSave") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.organizeImportsOnSave, from: self)
            UserDefaults.standard.set(organizeImportsOnSave, forKey: "GoLensOrganizeImportsOnSave")
        }
    }
    var autoSaveOnFocusLoss: Bool = UserDefaults.standard.object(forKey: "GoLensAutoSaveOnFocusLoss") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.autoSaveOnFocusLoss, from: self)
            UserDefaults.standard.set(autoSaveOnFocusLoss, forKey: "GoLensAutoSaveOnFocusLoss")
        }
    }
    var enableDoubleShiftSearch: Bool = UserDefaults.standard.object(forKey: "GoLensEnableDoubleShiftSearch") as? Bool ?? true {
        didSet {
            Self.shareSetting(\.enableDoubleShiftSearch, from: self)
            UserDefaults.standard.set(enableDoubleShiftSearch, forKey: "GoLensEnableDoubleShiftSearch")
        }
    }

    var expandedFolders: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(expandedFolders), forKey: "GoLensLastExpandedFolders")
        }
    }

    static let consoleTab = 0
    static let debuggerTab = 1
    static let terminalTab = 2
    static let profilerTab = 3
    static let safetyTab = 4
    static let databaseTab = 6
    static let servicesTab = 7

    var selectedConsoleTab: Int = 0 {
        didSet {
            UserDefaults.standard.set(selectedConsoleTab, forKey: "GoLensLastConsoleTab")
        }
    }

    weak var activeTextView: NSTextView? {
        didSet {
            if oldValue !== activeTextView { observeCodeLensScrolling() }
        }
    }
    @ObservationIgnored
    weak var mainWindow: NSWindow?

    var fileEditorModes: [String: EditorMode] = [:] {
        didSet { refreshCommandCapabilities() }
    }
    var diffStyle: GitDiffView.DiffStyle = GitDiffView.DiffStyle(rawValue: UserDefaults.standard.string(forKey: "GoLensDiffStyle") ?? "") ?? .sideBySide {
        didSet { UserDefaults.standard.set(diffStyle.rawValue, forKey: "GoLensDiffStyle") }
    }

    private static let sharedRegistryLock = NSLock()
    private static var activeSharedInstance: WorkspaceState?
    private static var allLiveWorkspaces: [ObjectIdentifier: WeakWorkspaceBox] = [:]
    private static var didRegisterGoBridge = false
    private static var didInitializeCoreRuntime = false

    private struct WeakWorkspaceBox {
        weak var workspace: WorkspaceState?
        var workspacePath: String
    }

    static var shared: WorkspaceState {
        sharedRegistryLock.lock()
        if let active = activeSharedInstance {
            sharedRegistryLock.unlock()
            return active
        }
        sharedRegistryLock.unlock()

        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                let active = WorkspaceSessionRegistry.shared.activeWorkspace
                setActiveShared(active)
                return active
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let active = WorkspaceSessionRegistry.shared.activeWorkspace
                setActiveShared(active)
                return active
            }
        }
    }

    static func setActiveShared(_ workspace: WorkspaceState) {
        sharedRegistryLock.lock()
        activeSharedInstance = workspace
        allLiveWorkspaces[ObjectIdentifier(workspace)] = WeakWorkspaceBox(
            workspace: workspace,
            workspacePath: workspace.activeWorkspacePath
        )
        sharedRegistryLock.unlock()
    }

    static func updateCallbackRoutingTable(for workspace: WorkspaceState, workspacePath: String) {
        sharedRegistryLock.lock()
        allLiveWorkspaces[ObjectIdentifier(workspace)] = WeakWorkspaceBox(
            workspace: workspace,
            workspacePath: workspacePath
        )
        allLiveWorkspaces = allLiveWorkspaces.filter { $0.value.workspace != nil }
        sharedRegistryLock.unlock()
    }

    static func unregisterLiveWorkspace(_ workspace: WorkspaceState) {
        sharedRegistryLock.lock()
        allLiveWorkspaces.removeValue(forKey: ObjectIdentifier(workspace))
        if activeSharedInstance === workspace {
            activeSharedInstance = allLiveWorkspaces.values.compactMap(\.workspace).first
        }
        sharedRegistryLock.unlock()
    }

    static func hasOtherOpenWorkspaces(excluding target: WorkspaceState) -> Bool {
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        return allLiveWorkspaces.values.contains { box in
            guard let ws = box.workspace, ws !== target else { return false }
            return !box.workspacePath.isEmpty
        }
    }

    static func allRegisteredWorkspaces() -> [WorkspaceState] {
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        return allLiveWorkspaces.values.compactMap(\.workspace)
    }

    static func workspaceOwningPath(_ rawPath: String) -> WorkspaceState? {
        let canonical = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        guard !canonical.isEmpty else { return nil }
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        var best: WorkspaceState?
        var bestLen = -1
        for box in allLiveWorkspaces.values {
            guard let ws = box.workspace, !box.workspacePath.isEmpty else { continue }
            let root = box.workspacePath
            if canonical == root || canonical.hasPrefix(root + "/"), root.count > bestLen {
                best = ws
                bestLen = root.count
            }
        }
        return best
    }

    var hasSetup = false

    func activeFilePrefix(_ length: Int) -> String {
        guard let text = documents[activeFilePath]?.storage.string else { return "" }
        let ns = text as NSString
        return ns.substring(to: min(length, ns.length))
    }

    func refreshCommandCapabilities() {
        let mode = editorMode(for: activeFilePath)
        let canSaveDoc = (!activeFilePath.isEmpty && loadedDocuments.contains(activeFilePath)) ||
            (isSplitMode && secondaryFilePath != nil && loadedDocuments.contains(secondaryFilePath!))
        commandCapabilities.update(
            workspacePath: activeWorkspacePath,
            filePath: activeFilePath,
            canSave: canSaveDoc,
            isCodeMode: mode == .code,
            isDiffMode: mode == .diff,
            canStageActiveFile: selectedGitFiles(staged: false).contains { $0.status != "U" },
            canUnstageActiveFile: !selectedGitFiles(staged: true).isEmpty,
            isActiveFileConflicted: git.conflictedPaths.contains(activeFilePath),
            hasActiveFileGitChanges: !selectedGitFiles().isEmpty,
            hasDataSources: database.hasDataSources,
            isAttachedConsole: activeDatabaseConsoleDataSourceID != nil,
            canStopDatabaseStatement: canStopDatabaseStatement,
            isAttachedDataSourceConnected: activeDatabaseConsoleDataSourceID.map(isDataSourceConnected) == true,
            isKubernetesManifest: ActiveCommandCapabilities.isYAMLFile(activeFilePath) && KubeManifest.isManifest(activeFilePrefix(KubeManifest.sniffLength))
        )
    }

    func dismissTransientEditorOverlays(includeRename: Bool = true, includePopovers: Bool = false) {
        (activeTextView as? GoLensTextView)?.cancelHoverTimersAndRequests()
        (activeTextView as? GoLensTextView)?.inlineSuggestions.dismiss()
        lsp.isMouseInsideHoverPopover = false
        lsp.hoveredFilePath = ""
        lsp.hoveredWordRange = NSRange(location: NSNotFound, length: 0)
        if lsp.hoverText != nil { lsp.hoverText = nil }
        if lsp.quickDocumentation != nil { lsp.quickDocumentation = nil }
        if lsp.signatureHelp != nil { lsp.signatureHelp = nil }
        if issuePopup != nil { issuePopup = nil }
        if hoverGutterLine != nil { hoverGutterLine = nil }
        if includeRename { finishInlineRenames() }
        if includePopovers, let pop = activeEditorPopover, pop.isShown {
            pop.performClose(nil)
            activeEditorPopover = nil
        }
        CompletionController.shared.dismiss()
    }

    init(restoreLastOnSetup: Bool = false) {
        self.restoreLastOnSetup = restoreLastOnSetup
        self.git.workspace = self
        self.lsp.workspace = self
        self.debug.workspace = self
        self.sourceControlState.workspace = self
        self.diagnosticsAndLenses.workspace = self
        self.gopilot.hostWorkspace = self
        UserDefaults.standard.register(defaults: [
            "GoLensSelectedThemeId": "xcode"
        ])
        self.selectedTerminalId = self.terminalSessions.first?.id
        Self.sharedRegistryLock.lock()
        let shouldRegisterCallbacks = !Self.didRegisterGoBridge
        if shouldRegisterCallbacks {
            Self.didRegisterGoBridge = true
        }
        Self.allLiveWorkspaces[ObjectIdentifier(self)] = WeakWorkspaceBox(workspace: self, workspacePath: "")
        if Self.activeSharedInstance == nil {
            Self.activeSharedInstance = self
        }
        Self.sharedRegistryLock.unlock()
        if shouldRegisterCallbacks {
            registerGoCallbacks()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = SandboxVMManager.shared }
        }
        loadRecentProjects()
        refreshCommandCapabilities()
    }

    @ObservationIgnored private var isRestoringAtLaunch = false

    func setup(opening explicitPath: String? = nil) {
        guard !hasSetup else { return }
        hasSetup = true
        if !Self.didInitializeCoreRuntime {
            Self.didInitializeCoreRuntime = true
            InitEditor()
            measureStartup("core-init")
            syncCustomGoBinaryWithCore()
            CodeCheck.apply()
            measureStartup("core-config")
            NotificationCenter.default.addObserver(forName: .golensBuildTargetChanged, object: nil, queue: .main) { _ in
                for ws in Self.allRegisteredWorkspaces() {
                    ws.syncBuildTargetWithCore()
                }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                SecurityScopedBookmarkManager.shared.stopAllAccess()
                for ws in Self.allRegisteredWorkspaces() {
                    ws.closeAllDocuments()
                }
                ShutdownGoLensCore()
            }
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                for ws in Self.allRegisteredWorkspaces() {
                    ws.activeDraggedTabPath = nil
                    ws.activeDraggedNavigatorPath = nil
                    if ws.activePopup != nil {
                        ws.activePopup = nil
                    }
                    ws.dismissTransientEditorOverlays(includeRename: true, includePopovers: true)
                }
            }
        }
        syncBuildTargetWithCore()
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window === self.mainWindow,
                  self.lsp.quickDocumentation?.takesFocus != true else { return }
            let keyClass = NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) } ?? ""
            let isPopupPanelKey = self.issuePopup != nil && keyClass.contains("PopupPanel")
            if isPopupPanelKey { return }
            self.dismissTransientEditorOverlays(includeRename: true, includePopovers: false)
        }
        if restoreLastOnSetup {
            isRestoringAtLaunch = true
            restoreLastWorkspace(opening: explicitPath)
            isRestoringAtLaunch = false
            measureStartup("restore-workspace")
        }
        startPasteboardMonitor()
        setupMemoryPressureObserver()
    }

    func teardownClosedSessionWindow() {
        saveSession()
        fileSystemWatcher?.stop()
        fileSystemWatcher = nil
        modals.pasteboardTimer?.invalidate()
        modals.pasteboardTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        router.dismissActiveSheet()
        sourceControlState.operationTask?.cancel()
        sourceControlState.backgroundFetchTask?.cancel()
        let oldRoot = openedWorkspaceRoot
        shutdownDatabase(root: oldRoot)
        openedWorkspaceRoot = ""
        transientEditorState.resetForWorkspaceChange()
        closeAllDocuments()
        resetTerminalSessions()
        resetRunSessions()
        activeWorkspacePath = ""
        if Self.hasOtherOpenWorkspaces(excluding: self) {
            Self.releaseCoreRoot(oldRoot, excluding: self)
        }
        if !oldRoot.isEmpty, !Self.allRegisteredWorkspaces().contains(where: { $0 !== self && $0.activeWorkspacePath == oldRoot }) {
            SecurityScopedBookmarkManager.shared.stopAccessing(url: URL(fileURLWithPath: oldRoot))
            if Thread.isMainThread {
                _ = MainActor.assumeIsolated {
                    SandboxVMManager.shared.unmountWorkspace(url: URL(fileURLWithPath: oldRoot))
                }
            }
        }
        Self.unregisterLiveWorkspace(self)
    }
}
