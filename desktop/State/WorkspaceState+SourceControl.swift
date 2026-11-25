import AppKit
import SwiftUI

enum SourceControlSheet: Identifiable, Equatable {
    case pull, push, stash, clone, addRemote
    case newBranch(from: String?)
    case newWorktree(branch: String?)
    case newTag(at: String)
    case renameBranch(String)
    case interactiveRebase(from: String?)
    case gitAccount(host: String?, accountID: UUID?)

    var id: String {
        switch self {
        case .pull: "pull"
        case .push: "push"
        case .stash: "stash"
        case .clone: "clone"
        case .addRemote: "addRemote"
        case .newBranch(let base): "newBranch:" + (base ?? "")
        case .newWorktree(let branch): "newWorktree:" + (branch ?? "")
        case .newTag(let revision): "newTag:" + revision
        case .renameBranch(let name): "renameBranch:" + name
        case .interactiveRebase(let from): "interactiveRebase:" + (from ?? "")
        case .gitAccount(let host, let accountID): "gitAccount:" + (host ?? "") + ":" + (accountID?.uuidString ?? "")
        }
    }
}

enum SourceControlSurface: Equatable {
    case history
    case commit
    case mergeEditor(String)
}

enum SourceControlNavigatorTab: String, CaseIterable, Identifiable {
    case changes, repositories
    var id: String { rawValue }
    var title: String { self == .changes ? "Changes" : "Repositories" }
}

enum GitRemoteOperation: String {
    case fetch, pull, push

    var progressTitle: String {
        switch self {
        case .fetch: "Fetching…"
        case .pull: "Pulling…"
        case .push: "Pushing…"
        }
    }

    var failureTitle: String {
        switch self {
        case .fetch: "Couldn’t Fetch Changes"
        case .pull: "Couldn’t Pull"
        case .push: "Couldn’t Push"
        }
    }
}

@Observable
final class SourceControlUI {
    @ObservationIgnored weak var workspace: WorkspaceState?

    var sheet: SourceControlSheet? {
        get {
            if case .sourceControl(let current) = workspace?.router.activeSheet {
                return current
            }
            return fallbackSheet
        }
        set {
            if let workspace {
                fallbackSheet = nil
                workspace.router.setSourceControlSheet(newValue)
            } else {
                fallbackSheet = newValue
            }
        }
    }
    private var fallbackSheet: SourceControlSheet?
    var runningOperation: GitRemoteOperation?
    var pendingCommitFocus = false
    var editorSurface: SourceControlSurface?
    var commitMessage = "" {
        didSet {
            let hasText = CommitMessageText.hasContent(commitMessage)
            if hasText != commitMessageHasText { commitMessageHasText = hasText }
            if !hasText && commitMessageIsMergeMessage { commitMessageIsMergeMessage = false }
        }
    }
    var commitMessageHasText = false
    var commitMessageIsMergeMessage = false
    var commitAmend = false
    var isCommitting = false
    var lastCommitPushRequested = false
    var commitBanner: CommitBanner?
    @ObservationIgnored var commitTask: Task<Void, Never>?
    @ObservationIgnored var commitBannerTask: Task<Void, Never>?
    var navigatorTab: SourceControlNavigatorTab = .changes
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored var backgroundFetchTask: Task<Void, Never>?
    @ObservationIgnored var pendingAuthRetry: (@MainActor () -> Void)?

    func discardMergeMessageDraft() {
        guard commitMessageIsMergeMessage else { return }
        commitMessage = ""
        commitMessageIsMergeMessage = false
    }

    func resetCommitDraft() {
        commitMessage = ""
        commitMessageIsMergeMessage = false
        commitAmend = false
        isCommitting = false
        commitBanner = nil
        commitBannerTask?.cancel()
        commitBannerTask = nil
    }
}

extension WorkspaceState {
    static let showSourceControlChangesKey = "GoLensShowSourceControlChanges"
    static let comparisonLocalOnLeftKey = "GoLensComparisonLocalOnLeft"
    static let refreshGitStatusAutomaticallyKey = "GoLensRefreshGitStatusAutomatically"
    static let fetchAutomaticallyKey = "GoLensFetchAutomatically"
    static let autoFetchInterval: TimeInterval = 15 * 60
    static let autoFetchTimeout: TimeInterval = 120

    var sourceControl: SourceControlUI { sourceControlState }

    var showsSourceControlChanges: Bool {
        UserDefaults.standard.object(forKey: Self.showSourceControlChangesKey) as? Bool ?? true
    }

    var refreshesGitStatusAutomatically: Bool {
        UserDefaults.standard.object(forKey: Self.refreshGitStatusAutomaticallyKey) as? Bool ?? true
    }

    var fetchesAutomatically: Bool {
        UserDefaults.standard.bool(forKey: Self.fetchAutomaticallyKey)
    }

    func scheduleGitStatusRefreshFromFileEvent() {
        guard refreshesGitStatusAutomatically else { return }
        scheduleGitStatusRefresh()
    }

    @MainActor
    func updateAutoFetchTimer() {
        autoFetchTimer?.invalidate()
        autoFetchTimer = nil
        sourceControl.backgroundFetchTask?.cancel()
        guard fetchesAutomatically, !activeWorkspacePath.isEmpty else { return }
        autoFetchTimer = Timer.scheduledTimer(withTimeInterval: Self.autoFetchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoFetchTick() }
        }
    }

    @MainActor
    private func autoFetchTick() {
        guard isGitRepositoryOpen, sourceControl.runningOperation == nil, sourceControl.backgroundFetchTask == nil else { return }
        let fetch = Task { @MainActor in
            let remotes = await self.gitRemotes()
            guard !Task.isCancelled, !remotes.isEmpty, self.isGitRepositoryOpen, self.sourceControl.runningOperation == nil else { return }
            _ = try? await self.gitFetch()
        }
        sourceControl.backgroundFetchTask = fetch
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(Self.autoFetchTimeout))
            fetch.cancel()
        }
        Task { @MainActor in
            await fetch.value
            watchdog.cancel()
            self.sourceControl.backgroundFetchTask = nil
        }
    }

    @MainActor
    func redrawSourceControlChanges() {
        for window in NSApp.windows {
            redrawEditors(in: window.contentView)
        }
    }

    @MainActor
    private func redrawEditors(in view: NSView?) {
        guard let view else { return }
        if let editor = view as? GoLensTextView {
            editor.needsDisplay = true
            editor.redrawGutter()
        }
        for child in view.subviews {
            redrawEditors(in: child)
        }
    }

    var isGitRepositoryOpen: Bool {
        !activeWorkspacePath.isEmpty && git.isRepository == true
    }

    var hasNamedBranch: Bool {
        !git.branchName.isEmpty && git.branchName != "Detached HEAD"
    }

    var unstagedNonConflictFiles: [GitChangedFile] {
        git.changedFiles.filter { !$0.isStaged && $0.status != "U" && !git.conflictedPaths.contains($0.absolutePath) }
    }

    var editedWorkspacePathsNotInGit: [String] {
        _ = editedFiles
        let workspaceCanon = Self.canonicalizePath(activeWorkspacePath)
        guard !workspaceCanon.isEmpty else { return [] }
        let known = Set(git.changedFiles.map { Self.canonicalizePath($0.absolutePath) })
        let paths = documents.compactMap { (path, session) -> String? in
            guard session.isEdited else { return nil }
            let canon = Self.canonicalizePath(path)
            guard canon == workspaceCanon || canon.hasPrefix(workspaceCanon + "/") else { return nil }
            return known.contains(canon) ? nil : canon
        }
        return Array(Set(paths)).sorted()
    }

    func selectedGitFiles(staged: Bool? = nil) -> [GitChangedFile] {
        let path = activeFilePath
        guard !path.isEmpty else { return [] }
        return git.changedFiles.filter { $0.absolutePath == path && (staged == nil || $0.isStaged == staged) }
    }

    @MainActor
    func createGitRepository() {
        Task { @MainActor in
            do {
                _ = try await self.runGit(args: ["init"])
                self.refreshGitStatus()
                self.refreshActiveFileDiff()
            } catch {
                let recovery = self.gitRecovery(for: error) {
                    self.createGitRepository()
                }
                self.presentGitAlert("Couldn’t Create a Git Repository", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func refreshFileStatus() {
        refreshGitStatus()
        refreshActiveFileDiff()
    }

    @MainActor
    func refreshFileStatusFromUser() {
        let workspacePath = activeWorkspacePath
        guard !workspacePath.isEmpty else {
            presentCommandFeedback("Open a project folder before refreshing Source Control status.", title: "Refresh Unavailable")
            return
        }
        Task { @MainActor in
            do {
                _ = try await self.runGit(args: ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--", "."], in: workspacePath)
                self.refreshGitStatus()
                self.refreshActiveFileDiff()
            } catch {
                self.refreshGitStatus()
                let recovery = self.gitRecovery(for: error) {
                    self.refreshFileStatusFromUser()
                }
                self.presentGitAlert("Couldn’t Refresh File Status", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func stageSelectedFiles() {
        let files = selectedGitFiles()
        if let file = files.first(where: { !$0.isStaged && $0.status != "U" && !git.conflictedPaths.contains($0.absolutePath) }) {
            stageFile(file.absolutePath)
            return
        }
        if !activeFilePath.isEmpty, files.isEmpty, documentSession(forPath: activeFilePath)?.isEdited == true {
            stageFile(activeFilePath)
            return
        }
        if let conflicted = files.first(where: { $0.status == "U" || git.conflictedPaths.contains($0.absolutePath) }) {
            presentCommandFeedback("Resolve merge conflicts in “\(conflicted.name)” before staging it.", title: "Stage File Unavailable")
            return
        }
        let name = activeFilePath.isEmpty ? nil : (activeFilePath as NSString).lastPathComponent
        presentCommandFeedback(
            name.map { "“\($0)” has no unstaged changes to stage." } ?? "Open or select a modified file in Source Control to stage it.",
            title: name == nil ? "No File Selected" : "Nothing to Stage"
        )
    }

    @MainActor
    func unstageSelectedFiles() {
        if let file = selectedGitFiles(staged: true).first {
            unstageFile(file.absolutePath)
            return
        }
        let name = activeFilePath.isEmpty ? nil : (activeFilePath as NSString).lastPathComponent
        presentCommandFeedback(
            name.map { "“\($0)” has no staged changes to unstage." } ?? "Open or select a staged file in Source Control to unstage it.",
            title: name == nil ? "No File Selected" : "Nothing to Unstage"
        )
    }

    @MainActor
    func markSelectedFileResolved() {
        markResolved(activeFilePath)
    }

    @MainActor
    func markResolved(_ path: String) {
        guard !path.isEmpty else {
            presentCommandFeedback("Open or select a conflicted file to mark it as resolved.", title: "Mark as Resolved Unavailable")
            return
        }
        let name = (path as NSString).lastPathComponent
        guard git.conflictedPaths.contains(path) else {
            presentCommandFeedback("“\(name)” has no unresolved merge conflict.", title: "Not Conflicted")
            return
        }
        Task { @MainActor in
            do {
                try await self.markMergeConflictResolved(path)
            } catch {
                let recovery = self.gitRecovery(for: error, preferredPath: path) {
                    self.markResolved(path)
                }
                self.presentGitAlert("Couldn’t Mark “\(name)” as Resolved", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func confirmDiscardAllChanges() {
        if let op = git.mergeOperation {
            let alert = NSAlert()
            alert.messageText = "Can’t Discard All Changes During a \(op.title)"
            alert.informativeText = "A \(op.title.lowercased()) is in progress. Use Abort \(op.title) in the Source Control navigator to return to how things were."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            present(alert) { _ in }
            return
        }
        let count = Set(git.changedFiles.map { Self.canonicalizePath($0.absolutePath) }).union(editedWorkspacePathsNotInGit).count
        guard count > 0 else {
            presentCommandFeedback("There are no local changes to discard.", title: "Nothing to Discard")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to discard all uncommitted, local changes?"
        alert.informativeText = "\(count == 1 ? "1 file returns" : "\(count) files return") to the last commit and new files move to the Trash. Local History keeps a copy of each changed text file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.performDiscardAllChanges()
        }
    }

    @MainActor
    private func performDiscardAllChanges() {
        Task { @MainActor in
            do {
                try await self.gitDiscardAllChanges()
            } catch {
                let recovery = self.gitRecovery(for: error) {
                    self.performDiscardAllChanges()
                }
                self.presentGitAlert("Couldn’t Discard All Changes", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func confirmDiscardSelectedFiles() {
        let files = selectedGitFiles()
        guard let file = files.first(where: { !$0.isStaged }) ?? files.first else {
            presentCommandFeedback("Open or select a changed file to discard its changes.", title: "Nothing to Discard")
            return
        }
        confirmDiscard(file)
    }

    @MainActor
    func confirmDiscard(_ file: GitChangedFile) {
        if file.status == "U" || git.conflictedPaths.contains(file.absolutePath) {
            let alert = NSAlert()
            alert.messageText = "Can’t Discard Changes to “\(file.name)”"
            alert.informativeText = "Resolve or abort the merge conflict instead of discarding changes."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            present(alert) { _ in }
            return
        }
        let changeState = gitChangeState(for: file.absolutePath)
        let alert = NSAlert()
        alert.messageText = "Discard Changes to “\(file.name)”?"
        if (file.status == "A" || file.status == "C") && file.isStaged && changeState.hasUnstaged {
            alert.informativeText = "“\(file.relativePath)” is a newly added file, so discarding it removes both staged and unstaged changes and moves it to the Trash. Local History keeps a copy if it’s a text file."
        } else if file.status == "??" || file.status == "A" || file.status == "C" {
            alert.informativeText = "“\(file.relativePath)” is new, so it moves to the Trash. Local History keeps a copy if it’s a text file."
        } else if file.status == "R", let originalPath = file.originalPath, !originalPath.isEmpty {
            alert.informativeText = "“\(originalPath)” is restored from the last commit and “\(file.relativePath)” moves to the Trash. Local History keeps a copy if it’s a text file."
        } else if !file.isStaged && changeState.hasStaged {
            alert.informativeText = "The unstaged changes to “\(file.relativePath)” are discarded. Its staged changes are kept, and Local History keeps a copy of your version if it’s a text file."
        } else {
            alert.informativeText = "“\(file.relativePath)” returns to the last commit. Local History keeps a copy of your version if it’s a text file."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.performDiscard(file)
        }
    }

    @MainActor
    private func performDiscard(_ file: GitChangedFile) {
        Task { @MainActor in
            do {
                try await self.gitDiscardFileChanges(file)
                if self.editorMode(for: file.absolutePath) == .diff {
                    self.setEditorMode(.code, for: file.absolutePath)
                }
            } catch {
                let recovery = self.gitRecovery(for: error, preferredPath: file.absolutePath) {
                    self.performDiscard(file)
                }
                self.presentGitAlert("Couldn’t Discard “\(file.name)”", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func runRemoteOperation(_ kind: GitRemoteOperation, reportsFailure: Bool = true, _ body: @escaping @MainActor () async throws -> String) {
        guard sourceControl.runningOperation == nil else {
            presentCommandFeedback(
                "Wait for the current \(sourceControl.runningOperation?.rawValue ?? "remote") operation to finish before starting another one.",
                title: "Remote Operation in Progress"
            )
            return
        }
        sourceControl.runningOperation = kind
        sourceControl.operationTask = Task { @MainActor in
            if let background = self.sourceControl.backgroundFetchTask {
                background.cancel()
                await background.value
            }
            do {
                _ = try await body()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    if kind == .pull {
                        let gitDir = (try? await self.runGit(args: ["rev-parse", "--absolute-git-dir"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if let operation = gitDir.isEmpty ? nil : GitMergeOperation.detect(gitDir: gitDir) {
                            await self.refreshBlameHead()
                            self.reloadCleanOpenDocumentsFromDisk()
                            self.refreshGitStatus()
                            self.refreshActiveFileDiff()
                            self.reloadRepositoryRefs()
                            self.sourceControl.runningOperation = nil
                            self.sourceControl.operationTask = nil
                            self.sourceControl.navigatorTab = .changes
                            self.showNavigator(.git)
                            if reportsFailure {
                                let alert = NSAlert()
                                alert.messageText = "The \(operation.title.lowercased()) stopped on conflicts"
                                alert.informativeText = "Resolve the files listed under Merge Conflicts in the Source Control navigator, mark each as resolved, then choose Continue. Abort returns everything to how it was."
                                alert.alertStyle = .informational
                                alert.addButton(withTitle: "OK")
                                self.present(alert) { _ in }
                            }
                            return
                        }
                    }
                    if reportsFailure {
                        let remoteURLs = await self.gitRemoteURLs()
                        if let authContext = GitAccountStore.shared.detectAuthenticationFailure(errorText: error.localizedDescription, remoteURLs: remoteURLs) {
                            self.presentGitAuthenticationAlert(context: authContext, operation: kind) {
                                self.runRemoteOperation(kind, reportsFailure: reportsFailure, body)
                            }
                        } else {
                            let recovery = self.gitRecovery(for: error, remoteOperation: kind) {
                                self.runRemoteOperation(kind, reportsFailure: reportsFailure, body)
                            }
                            self.presentGitAlert(kind.failureTitle, Self.failureReason(error), recovery: recovery)
                        }
                    }
                }
            }
            self.sourceControl.runningOperation = nil
            self.sourceControl.operationTask = nil
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.reloadRepositoryRefs()
        }
    }

    @MainActor
    func presentGitAuthenticationAlert(context: GitAuthRecoveryContext, operation: GitRemoteOperation, retry: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = context.alertTitle
        alert.informativeText = context.alertMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: context.primaryActionTitle)
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.sourceControl.pendingAuthRetry = retry
            self.sourceControl.sheet = .gitAccount(host: context.host, accountID: context.existingAccount?.id)
        }
    }

    func gitRemoteURLs() async -> [String] {
        let raw = (try? await runGit(args: ["config", "--get-regexp", "^remote\\..*\\.url$"])) ?? ""
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            return parts.count == 2 ? String(parts[1]) : nil
        }
    }

    @MainActor
    func stopRemoteOperation() {
        sourceControl.operationTask?.cancel()
    }

    @MainActor
    func fetchChanges() {
        runRemoteOperation(.fetch) { try await self.gitFetch() }
    }

    @MainActor
    func pullChanges(from remoteBranch: String?, rebase: Bool?) {
        runRemoteOperation(.pull) { try await self.gitPull(from: remoteBranch, rebase: rebase) }
    }

    @MainActor
    func pushChanges(to remote: String?, includeTags: Bool) {
        runRemoteOperation(.push) { try await self.gitPush(to: remote, includeTags: includeTags) }
    }

    @MainActor
    func switchBranch(_ branch: String) {
        guard branch != git.branchName else { return }
        Task { @MainActor in
            do {
                _ = try await self.checkoutBranch(branch)
            } catch {
                self.presentBranchSwitchFailure(branch: branch, error: error)
            }
        }
    }

    @MainActor
    func jumpToChange(forward: Bool) {
        if let terminal = NSApp.keyWindow?.firstResponder as? GoLensTerminalView, let event = NSApp.currentEvent, event.type == .keyDown {
            terminal.keyDown(with: event)
            return
        }
        guard let textView = activeTextView, let session = documentSession(forPath: activeFilePath) else {
            presentCommandFeedback("Open a file in a Git repository to jump between changes.", title: "Jump to Change Unavailable")
            return
        }
        let lines = git.activeFileDiffs.keys.sorted()
        let starts = lines.filter { !git.activeFileDiffs.keys.contains($0 - 1) }
        guard !starts.isEmpty else {
            let name = (activeFilePath as NSString).lastPathComponent
            presentCommandFeedback("“\(name)” has no uncommitted changes to jump to.", title: "No Uncommitted Changes")
            return
        }
        let current = max(1, cursorLine)
        let next: Int?
        if forward {
            next = starts.first(where: { $0 > current })
        } else {
            var runStart = current
            while git.activeFileDiffs[runStart] != nil && git.activeFileDiffs[runStart - 1] != nil { runStart -= 1 }
            next = starts.last(where: { $0 < runStart })
        }
        let target = next ?? (forward ? starts[0] : starts[starts.count - 1])
        guard let offset = session.lines.start(ofLine: target - 1) else { return }
        let range = NSRange(location: offset, length: 0)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    @MainActor
    func toggleCodeReview() {
        let path = activeFilePath
        guard !path.isEmpty else { return }
        if editorMode(for: path) == .diff {
            setEditorMode(.code, for: path)
        } else {
            openFileInDiff(path)
        }
    }

    func gitRemotes() async -> [String] {
        ((try? await runGit(args: ["remote"])) ?? "").split(separator: "\n").map(String.init)
    }

    func gitRemoteBranches() async -> [String] {
        ((try? await runGit(args: ["--no-optional-locks", "for-each-ref", "--format=%(refname:short)", "refs/remotes"])) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    func gitUpstream() async -> String? {
        (try? await runGit(args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitPrefersRebase() async -> Bool {
        let branch = await MainActor.run { git.branchName }
        var value = (try? await runGit(args: ["config", "--get", "branch.\(branch).rebase"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            value = (try? await runGit(args: ["config", "--get", "pull.rebase"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return Self.isRebaseValue(value)
    }

    static func isRebaseValue(_ value: String) -> Bool {
        ["true", "yes", "on", "1", "interactive", "i", "merges", "m"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
