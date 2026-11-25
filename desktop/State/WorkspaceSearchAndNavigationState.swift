import Foundation
import GoLensFoundation
import AppKit
import Observation

@Observable
final class WorkspaceSearchAndNavigationState: @unchecked Sendable {
    var bookmarks: [BookmarkItem] = []
    var bookmarksByPath: [String: Set<Int>] = [:]
    @ObservationIgnored var storedBookmarks: [BookmarkItem] = []
    var workspaceTodos: [WorkspaceTodoItem] = []
    var isScanningTodos: Bool = false
    var selectedIssuesNavigatorSubtab: IssuesNavigatorSubtab = .issues
    @ObservationIgnored var todoScanGeneration: Int = 0
    @ObservationIgnored var todoScanTask: Task<Void, Never>?
    @ObservationIgnored var todosByFileCache: [String: [WorkspaceTodoItem]] = [:]

    var projectSearchTotalMatches: Int = 0
    var projectSearchQuery: String = ""
    var projectSearchCaseSensitive: Bool = false
    var projectSearchWholeWord: Bool = false
    var projectSearchRegex: Bool = false
    var projectSearchFileFilter: String = ""
    var projectSearchResults: [FileSearchMatches] = []
    var projectSearchResultsQuery: String = ""
    var isProjectSearching: Bool = false
    @ObservationIgnored var projectSearchWorkItem: DispatchWorkItem?
    @ObservationIgnored var projectSearchID: Int64 = 0

    var multiBufferResult: MultiBufferResultDTO? = nil
    var multiBufferTitle: String = ""

    var editorHasSelection: Bool = false
    @ObservationIgnored var localSearchRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored var findFieldTakesFocus: Bool = true
    var showLocalSearch: Bool = false
    var localSearchQuery: String = ""
    var localSearchMatches: [NSRange] = []
    var currentLocalMatchIndex: Int = -1
    var replaceQuery: String = ""
    var localSearchTruncated: Bool = false
    var localSearchInvalid: Bool = false
    var localSearchTimedOut: Bool = false
    @ObservationIgnored var localSearchTask: Task<Void, Never>?
    var findOptions = TextFinder.Options(
        matchCase: UserDefaults.standard.bool(forKey: "GoLensFindMatchCase"),
        wholeWords: UserDefaults.standard.bool(forKey: "GoLensFindWholeWords"),
        regex: UserDefaults.standard.bool(forKey: "GoLensFindRegex")
    )
    @ObservationIgnored var localSearchGeneration: Int = 0
    @ObservationIgnored var localSearchHighlightedSpan: NSRange?
    @ObservationIgnored var isApplyingFindReplacement: Bool = false

    var navigationHistory: [String] = []
    var navigationCaretHistory: [CaretHistoryEntry] = []
    var navigationIndex: Int = -1
    @ObservationIgnored var isNavigatingHistory: Bool = false

    var recentProjects: [String] = []
    var recentFiles: [String] = []

    var activePopup: WorkspaceState.Popup? = nil
    @ObservationIgnored weak var surroundTextView: GoLensTextView?
    @ObservationIgnored var surroundSelection: NSRange?
    var symbolPickerQuery: String = ""
    var referencesResults: [LSPLocation] = []
    var referencesSymbolName: String = ""
    var referencesPopupKind: String = "References"
    var referencesPhase: ReferencesPhase = .loaded
    @ObservationIgnored var navigationRequest: NavigationRequest?

    var hierarchyMode: HierarchyMode = .call
    var hierarchyDirection: HierarchyDirection = .incoming
    var hierarchyRoot: HierarchyItem? = nil
    var hierarchyItems: [HierarchyItem] = []
    var isHierarchyLoading: Bool = false
    var hierarchyFailure: LSPRequestFailure? = nil
    @ObservationIgnored var hierarchyRetry: (() -> Void)?

    var pendingJumpToLine: Int? = nil
    var pendingJumpToCol: Int? = nil
    var pendingJumpToRange: NSRange? = nil
}

extension WorkspaceState {
    static let maxNavigationHistory = 100
    static let maxHierarchyItems = 200

    var bookmarks: [BookmarkItem] {
        get { searchNav.bookmarks }
        set { searchNav.bookmarks = newValue }
    }

    var bookmarksByPath: [String: Set<Int>] {
        get { searchNav.bookmarksByPath }
        set { searchNav.bookmarksByPath = newValue }
    }

    var workspaceTodos: [WorkspaceTodoItem] {
        get { searchNav.workspaceTodos }
        set { searchNav.workspaceTodos = newValue }
    }

    var isScanningTodos: Bool {
        get { searchNav.isScanningTodos }
        set { searchNav.isScanningTodos = newValue }
    }

    var selectedIssuesNavigatorSubtab: IssuesNavigatorSubtab {
        get { searchNav.selectedIssuesNavigatorSubtab }
        set { searchNav.selectedIssuesNavigatorSubtab = newValue }
    }

    var todoScanGeneration: Int {
        get { searchNav.todoScanGeneration }
        set { searchNav.todoScanGeneration = newValue }
    }

    var todoScanTask: Task<Void, Never>? {
        get { searchNav.todoScanTask }
        set { searchNav.todoScanTask = newValue }
    }

    var todosByFileCache: [String: [WorkspaceTodoItem]] {
        get { searchNav.todosByFileCache }
        set { searchNav.todosByFileCache = newValue }
    }

    var projectSearchTotalMatches: Int {
        get { searchNav.projectSearchTotalMatches }
        set { searchNav.projectSearchTotalMatches = newValue }
    }

    var projectSearchQuery: String {
        get { searchNav.projectSearchQuery }
        set {
            searchNav.projectSearchQuery = newValue
            scheduleProjectSearch()
        }
    }

    var projectSearchCaseSensitive: Bool {
        get { searchNav.projectSearchCaseSensitive }
        set {
            searchNav.projectSearchCaseSensitive = newValue
            scheduleProjectSearch()
        }
    }

    var projectSearchWholeWord: Bool {
        get { searchNav.projectSearchWholeWord }
        set {
            searchNav.projectSearchWholeWord = newValue
            scheduleProjectSearch()
        }
    }

    var projectSearchRegex: Bool {
        get { searchNav.projectSearchRegex }
        set {
            searchNav.projectSearchRegex = newValue
            scheduleProjectSearch()
        }
    }

    var projectSearchFileFilter: String {
        get { searchNav.projectSearchFileFilter }
        set {
            searchNav.projectSearchFileFilter = newValue
            scheduleProjectSearch()
        }
    }

    var projectSearchResults: [FileSearchMatches] {
        get { searchNav.projectSearchResults }
        set { searchNav.projectSearchResults = newValue }
    }

    var projectSearchResultsQuery: String {
        get { searchNav.projectSearchResultsQuery }
        set { searchNav.projectSearchResultsQuery = newValue }
    }

    var isProjectSearching: Bool {
        get { searchNav.isProjectSearching }
        set { searchNav.isProjectSearching = newValue }
    }

    var projectSearchWorkItem: DispatchWorkItem? {
        get { searchNav.projectSearchWorkItem }
        set { searchNav.projectSearchWorkItem = newValue }
    }

    var projectSearchID: Int64 {
        get { searchNav.projectSearchID }
        set { searchNav.projectSearchID = newValue }
    }

    var isMultiBufferOpen: Bool {
        get { router.isPresenting(.multiBuffer) }
        set { router.setPresented(.multiBuffer, newValue) }
    }

    var multiBufferResult: MultiBufferResultDTO? {
        get { searchNav.multiBufferResult }
        set { searchNav.multiBufferResult = newValue }
    }

    var multiBufferTitle: String {
        get { searchNav.multiBufferTitle }
        set { searchNav.multiBufferTitle = newValue }
    }

    var editorHasSelection: Bool {
        get { searchNav.editorHasSelection }
        set { searchNav.editorHasSelection = newValue }
    }

    var localSearchRefreshWorkItem: DispatchWorkItem? {
        get { focusedPaneState.localSearchRefreshWorkItem }
        set { focusedPaneState.localSearchRefreshWorkItem = newValue }
    }

    var findFieldTakesFocus: Bool {
        get { focusedPaneState.findFieldTakesFocus }
        set { focusedPaneState.findFieldTakesFocus = newValue }
    }

    var showLocalSearch: Bool {
        get { focusedPaneState.showLocalSearch }
        set { setShowLocalSearch(newValue, in: effectiveFocusedPaneID) }
    }

    var localSearchQuery: String {
        get { focusedPaneState.findQuery }
        set { setLocalSearchQuery(newValue, in: effectiveFocusedPaneID) }
    }

    var localSearchMatches: [NSRange] {
        get { focusedPaneState.localSearchMatches }
        set { focusedPaneState.localSearchMatches = newValue }
    }

    var currentLocalMatchIndex: Int {
        get { focusedPaneState.currentLocalMatchIndex }
        set { focusedPaneState.currentLocalMatchIndex = newValue }
    }

    var replaceQuery: String {
        get { focusedPaneState.replaceQuery }
        set { focusedPaneState.replaceQuery = newValue }
    }

    var localSearchTruncated: Bool {
        get { focusedPaneState.localSearchTruncated }
        set { focusedPaneState.localSearchTruncated = newValue }
    }

    var localSearchInvalid: Bool {
        get { focusedPaneState.localSearchInvalid }
        set { focusedPaneState.localSearchInvalid = newValue }
    }

    var localSearchTimedOut: Bool {
        get { focusedPaneState.localSearchTimedOut }
        set { focusedPaneState.localSearchTimedOut = newValue }
    }

    var localSearchTask: Task<Void, Never>? {
        get { focusedPaneState.localSearchTask }
        set { focusedPaneState.localSearchTask = newValue }
    }

    var findOptions: TextFinder.Options {
        get { focusedPaneState.findOptions }
        set { setFindOptions(newValue, in: effectiveFocusedPaneID) }
    }

    var localSearchGeneration: Int {
        get { focusedPaneState.localSearchGeneration }
        set { focusedPaneState.localSearchGeneration = newValue }
    }

    var localSearchHighlightedSpan: NSRange? {
        get { focusedPaneState.localSearchHighlightedSpan }
        set { focusedPaneState.localSearchHighlightedSpan = newValue }
    }

    var isApplyingFindReplacement: Bool {
        get { focusedPaneState.isApplyingFindReplacement }
        set { focusedPaneState.isApplyingFindReplacement = newValue }
    }

    var navigationHistory: [String] {
        get { searchNav.navigationHistory }
        set { searchNav.navigationHistory = newValue }
    }

    var navigationCaretHistory: [CaretHistoryEntry] {
        get { searchNav.navigationCaretHistory }
        set { searchNav.navigationCaretHistory = newValue }
    }

    var navigationIndex: Int {
        get { searchNav.navigationIndex }
        set { searchNav.navigationIndex = newValue }
    }

    var isNavigatingHistory: Bool {
        get { searchNav.isNavigatingHistory }
        set { searchNav.isNavigatingHistory = newValue }
    }

    var recentProjects: [String] {
        get { searchNav.recentProjects }
        set { searchNav.recentProjects = newValue }
    }

    var recentFiles: [String] {
        get { searchNav.recentFiles }
        set { searchNav.recentFiles = newValue }
    }

    var activePopup: Popup? {
        get { searchNav.activePopup }
        set {
            let oldValue = searchNav.activePopup
            searchNav.activePopup = newValue
            if newValue == .commandPalette { GetStartedProgress.shared.complete(.commandPalette) }
            if newValue != nil {
                dismissTransientEditorOverlays(includeRename: true, includePopovers: true)
                if let window = mainWindow, window.firstResponder === activeTextView {
                    window.makeFirstResponder(nil)
                }
            } else if oldValue != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activePopup == nil, let tv = self.activeTextView else { return }
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
    }

    var showRecentFilesPopup: Bool { get { activePopup == .recentFiles } set { setPopup(.recentFiles, newValue) } }
    var showGoToSymbol: Bool { get { activePopup == .goToSymbol } set { setPopup(.goToSymbol, newValue) } }
    var showWorkspaceSymbol: Bool { get { activePopup == .workspaceSymbol } set { setPopup(.workspaceSymbol, newValue) } }
    var showOpenQuickly: Bool { get { activePopup == .openQuickly } set { setPopup(.openQuickly, newValue) } }
    var showCommandPalette: Bool { get { activePopup == .commandPalette } set { setPopup(.commandPalette, newValue) } }
    var showReferences: Bool { get { activePopup == .references } set { setPopup(.references, newValue) } }
    var showHierarchy: Bool { get { activePopup == .hierarchy } set { setPopup(.hierarchy, newValue) } }

    func setPopup(_ popup: Popup, _ shown: Bool) {
        if shown { activePopup = popup } else if activePopup == popup { activePopup = nil }
    }

    var symbolPickerQuery: String {
        get { searchNav.symbolPickerQuery }
        set { searchNav.symbolPickerQuery = newValue }
    }

    var referencesResults: [LSPLocation] {
        get { searchNav.referencesResults }
        set { searchNav.referencesResults = newValue }
    }

    var referencesSymbolName: String {
        get { searchNav.referencesSymbolName }
        set { searchNav.referencesSymbolName = newValue }
    }

    var referencesPopupKind: String {
        get { searchNav.referencesPopupKind }
        set { searchNav.referencesPopupKind = newValue }
    }

    var referencesPhase: ReferencesPhase {
        get { searchNav.referencesPhase }
        set { searchNav.referencesPhase = newValue }
    }

    var navigationRequest: NavigationRequest? {
        get { searchNav.navigationRequest }
        set { searchNav.navigationRequest = newValue }
    }

    var hierarchyMode: HierarchyMode {
        get { searchNav.hierarchyMode }
        set { searchNav.hierarchyMode = newValue }
    }

    var hierarchyDirection: HierarchyDirection {
        get { searchNav.hierarchyDirection }
        set { searchNav.hierarchyDirection = newValue }
    }

    var hierarchyRoot: HierarchyItem? {
        get { searchNav.hierarchyRoot }
        set { searchNav.hierarchyRoot = newValue }
    }

    var hierarchyItems: [HierarchyItem] {
        get { searchNav.hierarchyItems }
        set { searchNav.hierarchyItems = newValue }
    }

    var isHierarchyLoading: Bool {
        get { searchNav.isHierarchyLoading }
        set { searchNav.isHierarchyLoading = newValue }
    }

    var hierarchyFailure: LSPRequestFailure? {
        get { searchNav.hierarchyFailure }
        set { searchNav.hierarchyFailure = newValue }
    }

    var hierarchyRetry: (() -> Void)? {
        get { searchNav.hierarchyRetry }
        set { searchNav.hierarchyRetry = newValue }
    }

    var pendingJumpToLine: Int? {
        get { primaryPane.pendingJumpToLine }
        set { primaryPane.pendingJumpToLine = newValue }
    }

    var pendingJumpToCol: Int? {
        get { primaryPane.pendingJumpToCol }
        set { primaryPane.pendingJumpToCol = newValue }
    }

    var pendingJumpToRange: NSRange? {
        get { primaryPane.pendingJumpToRange }
        set { primaryPane.pendingJumpToRange = newValue }
    }

    func useSelectionForFind() {
        let paneID = effectiveFocusedPaneID
        guard let textView = editorTextView(for: paneID) ?? activeTextView else { return }
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 1000 else { return }
        let selection = (textView.string as NSString).substring(with: range)
        let pane = paneState(for: paneID)
        setLocalSearchQuery(selection, in: paneID)
        if !pane.showLocalSearch {
            pane.findFieldTakesFocus = false
            setShowLocalSearch(true, in: paneID)
        }
    }

    func showReferences(_ locations: [LSPLocation], for symbolName: String, kind: String = "References") {
        referencesPhase = .loaded
        referencesResults = locations
        referencesSymbolName = symbolName
        referencesPopupKind = kind
        showReferences = true
    }

    func navigateBack() {
        guard navigationIndex > 0 else { return }
        if !activeFilePath.isEmpty,
           navigationIndex < navigationCaretHistory.count,
           navigationCaretHistory[navigationIndex].path == activeFilePath {
            navigationCaretHistory[navigationIndex] = CaretHistoryEntry(
                path: activeFilePath,
                line: max(1, cursorLine),
                col: max(1, cursorCol)
            )
        }
        navigationIndex -= 1
        let targetPath = navigationHistory[navigationIndex]
        let caret = navigationIndex < navigationCaretHistory.count
            ? navigationCaretHistory[navigationIndex]
            : CaretHistoryEntry(path: targetPath, line: 1, col: 1)
        isNavigatingHistory = true
        openFile(targetPath)
        isNavigatingHistory = false
        restoreCaretLocation(line: caret.line, column: caret.col, inPath: targetPath)
    }

    func navigateForward() {
        guard navigationIndex < navigationHistory.count - 1 else { return }
        if !activeFilePath.isEmpty,
           navigationIndex >= 0,
           navigationIndex < navigationCaretHistory.count,
           navigationCaretHistory[navigationIndex].path == activeFilePath {
            navigationCaretHistory[navigationIndex] = CaretHistoryEntry(
                path: activeFilePath,
                line: max(1, cursorLine),
                col: max(1, cursorCol)
            )
        }
        navigationIndex += 1
        let targetPath = navigationHistory[navigationIndex]
        let caret = navigationIndex < navigationCaretHistory.count
            ? navigationCaretHistory[navigationIndex]
            : CaretHistoryEntry(path: targetPath, line: 1, col: 1)
        isNavigatingHistory = true
        openFile(targetPath)
        isNavigatingHistory = false
        restoreCaretLocation(line: caret.line, column: caret.col, inPath: targetPath)
    }
}
