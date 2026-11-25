import Foundation
import GoLensFoundation
import SwiftUI

struct GitCommitSummary: Identifiable, Equatable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let relativeTime: String
}

struct GitFileLineStats: Equatable {
    let added: Int
    let removed: Int
}

struct GitCommitFileChange: Identifiable, Equatable {
    var id: String { "\(commitHash)::\(relativePath)" }
    let commitHash: String
    let relativePath: String
    let absolutePath: String
    let status: String
    let added: Int
    let removed: Int
    var name: String {
        (relativePath as NSString).lastPathComponent
    }
}

struct GitStashEntry: Identifiable, Equatable {
    var id: String { ref }
    let ref: String
    let message: String
    let relativeTime: String
}

extension GitChangedFile {
    var name: String {
        (relativePath as NSString).lastPathComponent
    }
}

@Observable
class GitState {
    weak var workspace: WorkspaceState?
    
    var changedFiles: [GitChangedFile] = [] {
        didSet {
            stagedFilesCount = changedFiles.reduce(0) { $0 + ($1.isStaged ? 1 : 0) }
            workspace?.refreshCommandCapabilities()
        }
    }
    var stagedFilesCount: Int = 0
    var statusMap: [String: String] = [:] {
        didSet {
            let rowStore = workspace?.fileRowStates ?? FileRowStateStore.shared
            rowStore.updateGitStatus(statusMap)
            guard let activeWorkspacePath = workspace?.activeWorkspacePath else { return }
            var folders = Set<String>()
            var tracked = Set<String>()
            for (path, status) in statusMap {
                let isTracked = status != "??"
                var current = (path as NSString).deletingLastPathComponent
                while current != activeWorkspacePath && current != "/" && !current.isEmpty {
                    folders.insert(current)
                    if isTracked { tracked.insert(current) }
                    current = (current as NSString).deletingLastPathComponent
                }
                folders.insert(activeWorkspacePath)
                if isTracked { tracked.insert(activeWorkspacePath) }
            }
            rowStore.updateTrackedChangeFolders(tracked)
            changedFolderPaths = folders
        }
    }
    var changedFolderPaths: Set<String> = [] {
        didSet {
            (workspace?.fileRowStates ?? FileRowStateStore.shared).updateChangedFolders(changedFolderPaths)
        }
    }
    
    var isRepository: Bool? = nil
    var branchName: String = ""
    var branches: [String] = []
    var branchSummaries: [GitBranchSummary] = []
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var hasUpstream: Bool = false
    var fileLineStats: [String: GitFileLineStats] = [:]
    var activeFileDiffs: [Int: GitLineDiffType] = [:]
    var stashCount: Int = 0
    var stashes: [GitStashEntry] = []
    var recentCommits: [GitCommitSummary] = []
    @ObservationIgnored var loadedRefsFingerprint: String?
    var lastCommitSubject: String = ""
    var lastCommitBody: String = ""
    var selectedCommit: GitCommitSummary? = nil
    var selectedCommitBody: String = ""
    var selectedCommitFiles: [GitCommitFileChange] = []
    var isLoadingSelectedCommit: Bool = false
    var activeCommitDiffContext: (commit: GitCommitSummary, relativePath: String)? = nil
    var collapseUnchangedInDiff: Bool = true
    var conflictedPaths: Set<String> = [] {
        didSet {
            workspace?.refreshCommandCapabilities()
        }
    }
    var mergeOperation: GitMergeOperation? = nil
    var rebaseStoppedToEdit = false
    var conflictRegions: [String: [MergeConflictRegion]] = [:]
}

enum GitMergeOperation: Equatable {
    case merge, rebase, cherryPick, revert

    var title: String {
        switch self {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-Pick"
        case .revert: return "Revert"
        }
    }

    var command: String {
        switch self {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }

    static func detect(gitDir: String) -> GitMergeOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(name)) }
        if exists("rebase-merge") || (exists("rebase-apply") && !exists("rebase-apply/applying")) { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    static func rebaseStoppedToEdit(gitDir: String) -> Bool {
        FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent("rebase-merge/amend"))
    }
}

@Observable
class LSPState {
    weak var workspace: WorkspaceState?
    var completionsRect: CGRect = .zero
    var completionsBounds: CGRect = .zero
    
    var signatureHelp: SignatureHelpData? = nil
    var signatureHelpRect: CGRect = .zero
    var signatureHelpBounds: CGRect = .zero
    
    var hoverText: String? = nil
    var hoverRect: CGRect = .zero
    var hoverBounds: CGRect = .zero
    var isMouseInsideHoverPopover: Bool = false
    var hoveredFilePath: String = ""
    var hoveredWordRange: NSRange = NSRange(location: NSNotFound, length: 0)
    var hoveredDiagnosticRange: NSRange = NSRange(location: NSNotFound, length: 0)
    weak var hoveredEditor: GoLensTextView?
    var quickDocumentation: QuickDocumentationRequest? = nil

    var pendingForm: InteractiveForm? {
        get {
            if case .interactiveForm(let form) = workspace?.router.activeSheet {
                return form
            }
            return fallbackPendingForm
        }
        set {
            if let workspace {
                fallbackPendingForm = nil
                workspace.router.setInteractiveForm(newValue)
            } else {
                fallbackPendingForm = newValue
            }
        }
    }
    private var fallbackPendingForm: InteractiveForm? = nil
    var runningCommand: String? = nil
}

@Observable
class DebugState {
    weak var workspace: WorkspaceState?
    var isDebugMode: Bool = false
    var isPaused: Bool = false
    var activeLine: Int = 0
    var activeThreadId: Int32? = nil
    var callStack: [DAPStackFrame] = []
    var variables: [DAPVariable] = []
    var threads: [DAPThread] = []
    var breakpoints: [String: Set<Int>] = [:]
    var breakpointSpecs: [String: [Int: BreakpointSpec]] = [:]
    var functionBreakpoints: [FunctionBreakpointItem] = []
    var functionBreakpointProblems: [String: String] = [:]
    @ObservationIgnored var storedBreakpointLines: [String: [PersistedBreakpoints.Line]] = [:]
    var exceptionMessage: String? = nil
    var goroutineGroups: [GoroutineGroup] = []
    var goroutineFilter = ""
    var showsSystemGoroutines = false
    var variablesScopeReference = 0
    var inlinePath: String? = nil
    var inlineValues: [Int: String] = [:]
    var selectedFrameId: Int? = nil
    var activePath: String? = nil
    var watches: [String] = []
    var watchResults: [String: WatchEvaluationResult] = [:]
    var revealedOnPause = false
    var expressionFocusRequest = 0

    func spec(_ path: String, _ line: Int) -> BreakpointSpec {
        breakpointSpecs[path]?[line] ?? BreakpointSpec()
    }

    func breakpointsJSON(for path: String) -> String {
        let lines = (breakpoints[path] ?? []).sorted().filter { spec(path, $0).isEnabled }
        let items: [[String: Any]] = lines.map { line in
            let s = spec(path, line)
            var d: [String: Any] = ["line": line]
            if !s.condition.isEmpty { d["condition"] = s.condition }
            if !s.hitCondition.isEmpty { d["hitCondition"] = s.hitCondition }
            if !s.logMessage.isEmpty { d["logMessage"] = s.logMessage }
            return d
        }
        return jsonText(items)
    }

    func functionBreakpointsJSON() -> String {
        jsonText(functionBreakpoints.filter(\.isEnabled).map { ["name": $0.name] })
    }

}
