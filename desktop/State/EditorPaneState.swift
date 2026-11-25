import Foundation
import AppKit
import Observation

enum EditorPaneID: String, Equatable, Sendable {
    case primary
    case secondary
}

@Observable
final class EditorPaneState: @unchecked Sendable {
    let paneID: EditorPaneID

    var showLocalSearch: Bool = false
    var findQuery: String = ""
    var replaceQuery: String = ""
    var isRegexSearch: Bool
    var isCaseSensitiveSearch: Bool
    var wholeWordsSearch: Bool

    var findOptions: TextFinder.Options {
        get {
            TextFinder.Options(
                matchCase: isCaseSensitiveSearch,
                wholeWords: wholeWordsSearch,
                regex: isRegexSearch
            )
        }
        set {
            isCaseSensitiveSearch = newValue.matchCase
            wholeWordsSearch = newValue.wholeWords
            isRegexSearch = newValue.regex
        }
    }

    var localSearchMatches: [NSRange] = []
    var currentLocalMatchIndex: Int = -1
    var localSearchTruncated: Bool = false
    var localSearchInvalid: Bool = false
    var localSearchTimedOut: Bool = false
    var findFocusRequestID: Int = 0
    @ObservationIgnored var findFieldTakesFocus: Bool = true
    @ObservationIgnored var localSearchTask: Task<Void, Never>?
    @ObservationIgnored var localSearchRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored var localSearchGeneration: Int = 0
    @ObservationIgnored var localSearchHighlightedSpan: NSRange?
    @ObservationIgnored var isApplyingFindReplacement: Bool = false

    var pendingJumpToLine: Int? = nil
    var pendingJumpToCol: Int? = nil
    var pendingJumpToRange: NSRange? = nil

    var cursorLine: Int = 1
    var cursorCol: Int = 1
    var hasSelection: Bool = false
    var lineCount: Int = 1

    var goDeclarations: [WorkspaceState.GoDeclaration] = []
    var documentSymbols: [DocumentSymbol] = []
    var breadcrumbSegments: [BreadcrumbStep] = []
    @ObservationIgnored var declarationsWorkItem: DispatchWorkItem?
    @ObservationIgnored var symbolFetchWorkItem: DispatchWorkItem?

    init(paneID: EditorPaneID) {
        self.paneID = paneID
        self.isCaseSensitiveSearch = UserDefaults.standard.bool(forKey: "GoLensFindMatchCase")
        self.wholeWordsSearch = UserDefaults.standard.bool(forKey: "GoLensFindWholeWords")
        self.isRegexSearch = UserDefaults.standard.bool(forKey: "GoLensFindRegex")
    }

    func resetLocalSearch() {
        localSearchTask?.cancel()
        localSearchTask = nil
        localSearchRefreshWorkItem?.cancel()
        localSearchRefreshWorkItem = nil
        showLocalSearch = false
        findQuery = ""
        localSearchMatches = []
        currentLocalMatchIndex = -1
        localSearchTruncated = false
        localSearchInvalid = false
        localSearchTimedOut = false
        localSearchHighlightedSpan = nil
    }
}
