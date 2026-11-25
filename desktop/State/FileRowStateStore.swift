import Foundation

@Observable
final class FileRowState {
    private(set) var gitStatus: String?
    private(set) var isChangedFolder: Bool
    private(set) var hasTrackedChanges: Bool
    private(set) var issues: IssueCount?
    private(set) var isErrorFolder: Bool
    private(set) var isDropTarget: Bool

    @ObservationIgnored private var childNamesSource: [FileItem]?
    @ObservationIgnored private var cachedChildNames: [String]?

    fileprivate init(gitStatus: String?, isChangedFolder: Bool, hasTrackedChanges: Bool, issues: IssueCount?, isErrorFolder: Bool, isDropTarget: Bool) {
        self.gitStatus = gitStatus
        self.isChangedFolder = isChangedFolder
        self.hasTrackedChanges = hasTrackedChanges
        self.issues = issues
        self.isErrorFolder = isErrorFolder
        self.isDropTarget = isDropTarget
    }

    func childNames(of children: [FileItem]?) -> [String]? {
        guard let children else { return nil }
        if let source = childNamesSource, source.hasSameStorage(as: children) {
            return cachedChildNames
        }
        let names = children.map(\.name)
        childNamesSource = children
        cachedChildNames = names
        return names
    }

    fileprivate func setGitStatus(_ value: String?) { if gitStatus != value { gitStatus = value } }
    fileprivate func setChangedFolder(_ value: Bool) { if isChangedFolder != value { isChangedFolder = value } }
    fileprivate func setTrackedChanges(_ value: Bool) { if hasTrackedChanges != value { hasTrackedChanges = value } }

    var folderGitStatus: String? {
        isChangedFolder ? (hasTrackedChanges ? "M" : "??") : nil
    }
    fileprivate func setIssues(_ value: IssueCount?) { if issues != value { issues = value } }
    fileprivate func setErrorFolder(_ value: Bool) { if isErrorFolder != value { isErrorFolder = value } }
    fileprivate func setDropTarget(_ value: Bool) { if isDropTarget != value { isDropTarget = value } }
}

@Observable
final class FileRowStateStore {
    static var shared: FileRowStateStore { WorkspaceState.shared.fileRowStates }

    private var generation = 0

    @ObservationIgnored private var states: [String: FileRowState] = [:]
    @ObservationIgnored private var statusMap: [String: String] = [:]
    @ObservationIgnored private var changedFolders: Set<String> = []
    @ObservationIgnored private var trackedChangeFolders: Set<String> = []
    @ObservationIgnored private var untrackedFolders: [String] = []
    @ObservationIgnored private var issueCounts: [String: IssueCount] = [:]
    @ObservationIgnored private var errorFolders: Set<String> = []
    @ObservationIgnored private var dropTarget: String?

    func state(for path: String) -> FileRowState {
        _ = generation
        if let state = states[path] { return state }
        let state = FileRowState(
            gitStatus: gitStatus(for: path),
            isChangedFolder: isChangedFolder(path),
            hasTrackedChanges: trackedChangeFolders.contains(path),
            issues: issueCounts[path],
            isErrorFolder: errorFolders.contains(path),
            isDropTarget: dropTarget == path
        )
        states[path] = state
        return state
    }

    func reset() {
        states.removeAll()
        generation &+= 1
    }

    private func isInsideUntrackedFolder(_ path: String, includingSelf: Bool) -> Bool {
        untrackedFolders.contains { path.hasPrefix($0 + "/") || (includingSelf && path == $0) }
    }

    private func gitStatus(for path: String) -> String? {
        statusMap[path] ?? (isInsideUntrackedFolder(path, includingSelf: false) ? "??" : nil)
    }

    private func isChangedFolder(_ path: String) -> Bool {
        changedFolders.contains(path) || isInsideUntrackedFolder(path, includingSelf: true)
    }

    func updateGitStatus(_ new: [String: String]) {
        let old = statusMap
        statusMap = new
        guard !states.isEmpty else { return }
        for (path, value) in new where old[path] != value {
            states[path]?.setGitStatus(value)
        }
        for path in old.keys where new[path] == nil {
            states[path]?.setGitStatus(gitStatus(for: path))
        }
    }

    func updateChangedFolders(_ new: Set<String>) {
        let old = changedFolders
        changedFolders = new
        guard !states.isEmpty, old != new else { return }
        for path in old.symmetricDifference(new) {
            states[path]?.setChangedFolder(isChangedFolder(path))
        }
    }

    func updateUntrackedFolders(_ new: [String]) {
        let old = untrackedFolders
        guard old != new else { return }
        untrackedFolders = new
        guard !states.isEmpty else { return }
        let touched = Set(old).symmetricDifference(new)
        for (path, state) in states where touched.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            state.setGitStatus(gitStatus(for: path))
            state.setChangedFolder(isChangedFolder(path))
        }
    }

    func updateTrackedChangeFolders(_ new: Set<String>) {
        let old = trackedChangeFolders
        trackedChangeFolders = new
        guard !states.isEmpty, old != new else { return }
        for path in old.symmetricDifference(new) {
            states[path]?.setTrackedChanges(new.contains(path))
        }
    }

    func updateIssueCounts(_ new: [String: IssueCount]) {
        let old = issueCounts
        issueCounts = new
        guard !states.isEmpty else { return }
        for (path, value) in new where old[path] != value {
            states[path]?.setIssues(value)
        }
        for path in old.keys where new[path] == nil {
            states[path]?.setIssues(nil)
        }
    }

    func updateErrorFolders(_ new: Set<String>) {
        let old = errorFolders
        errorFolders = new
        guard !states.isEmpty, old != new else { return }
        for path in old.symmetricDifference(new) {
            states[path]?.setErrorFolder(new.contains(path))
        }
    }

    func updateDropTarget(_ new: String?) {
        let old = dropTarget
        guard old != new else { return }
        dropTarget = new
        if let old { states[old]?.setDropTarget(false) }
        if let new { states[new]?.setDropTarget(true) }
    }
}
