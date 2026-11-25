import AppKit
import GoLensFoundation
import SwiftUI

enum GitHistoryScope: String, CaseIterable, Identifiable {
    case all, day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        }
    }

    var since: String? {
        switch self {
        case .all: nil
        case .day: "24.hours.ago"
        case .week: "7.days.ago"
        case .month: "30.days.ago"
        }
    }
}

struct GitHistoryTarget: Equatable {
    let revision: String
    let title: String
    var isSingleCommit = false
}

struct GitCommitDetail: Equatable {
    let commit: GitHistoryCommit
    let body: String
    let files: [GitCommitFileChange]
    var signature: CommitSignatureInfo = CommitSignatureInfo(status: "N", fingerprint: nil, signerEmail: nil)
}

@Observable
final class GitRepositoryStore {
    var refs: [GitRef] = []
    var remotes: [GitRemoteInfo] = []
    var worktrees: [GitWorktreeEntry] = []
    var isLoaded = false
    @ObservationIgnored var refsTask: Task<Void, Never>?

    var historyTarget: GitHistoryTarget?
    var historyScope: GitHistoryScope = .all
    var historyQuery = ""
    var historyShowsAllBranches = false
    var commits: [GitHistoryCommit] = []
    var graph: [GitGraphRow] = []
    var hasMoreCommits = false
    var isLoadingHistory = false
    var selectedCommitHash: String?
    var detail: GitCommitDetail?
    @ObservationIgnored var historyTask: Task<Void, Never>?
    @ObservationIgnored var detailTask: Task<Void, Never>?

    var branches: [GitRef] { refs.filter { $0.kind == .branch } }
    var tags: [GitRef] { refs.filter { $0.kind == .tag }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
    func remoteBranches(of remote: String) -> [GitRef] { refs.filter { $0.kind == .remoteBranch(remote: remote) } }
}

extension WorkspaceState {
    static let historyPageSize = 200

    @MainActor
    func reloadRepositoryRefs() {
        let workspacePath = activeWorkspacePath
        guard isGitRepositoryOpen else {
            repositories.refs = []
            repositories.remotes = []
            repositories.worktrees = []
            return
        }
        repositories.refsTask?.cancel()
        repositories.refsTask = Task { @MainActor in
            async let refsRun = try? runGit(args: ["--no-optional-locks", "for-each-ref", "--format=\(GitHistoryParser.refFormat)", "refs/heads", "refs/remotes", "refs/tags"], in: workspacePath)
            async let remotesRun = try? runGit(args: ["remote", "-v"], in: workspacePath)
            async let worktreesRun = try? runGit(args: ["--no-optional-locks", "worktree", "list", "--porcelain"], in: workspacePath)
            let refs = GitHistoryParser.refs(await refsRun ?? "")
            let remotes = GitHistoryParser.remotes(await remotesRun ?? "")
            let worktrees = GitWorktreeParser.parsePorcelain(await worktreesRun ?? "")
            guard !Task.isCancelled, self.activeWorkspacePath == workspacePath else { return }
            if self.repositories.refs != refs { self.repositories.refs = refs }
            if self.repositories.remotes != remotes { self.repositories.remotes = remotes }
            if self.repositories.worktrees != worktrees { self.repositories.worktrees = worktrees }
            self.repositories.isLoaded = true
        }
    }

    @MainActor
    func showHistory(_ target: GitHistoryTarget) {
        repositories.historyTarget = target
        repositories.selectedCommitHash = nil
        repositories.detail = nil
        sourceControl.editorSurface = .history
        loadHistory(reset: true)
    }

    @MainActor
    func closeSourceControlSurface() {
        sourceControl.editorSurface = nil
    }

    @MainActor
    func closeSourceControlSurfaceFromEscape() {
        if let terminal = NSApp.keyWindow?.firstResponder as? GoLensTerminalView, let event = NSApp.currentEvent, event.type == .keyDown {
            terminal.keyDown(with: event)
            return
        }
        closeSourceControlSurface()
    }

    @MainActor
    func loadHistory(reset: Bool) {
        guard let target = repositories.historyTarget else { return }
        let store = repositories
        let workspacePath = activeWorkspacePath
        let query = store.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let skip = reset || !query.isEmpty ? 0 : store.commits.count
        var base = ["--no-optional-locks", "log", "-z", "--format=\(GitHistoryParser.logFormat)"]
        if let since = store.historyScope.since { base.append("--since=\(since)") }
        store.historyTask?.cancel()
        store.isLoadingHistory = true
        if reset {
            store.commits = []
            store.graph = []
        }
        let revisions = store.historyShowsAllBranches && !target.isSingleCommit ? ["--branches", "--remotes", "--tags", "HEAD"] : [target.revision]
        store.historyTask = Task { @MainActor in
            var page: [GitHistoryCommit]
            if target.isSingleCommit {
                let output = (try? await self.runGit(args: base + ["-n", "1", target.revision, "--"], in: workspacePath)) ?? ""
                page = GitHistoryParser.commits(output)
            } else if query.isEmpty {
                let output = (try? await self.runGit(args: base + ["--date-order", "-n", String(Self.historyPageSize + 1), "--skip", String(skip)] + revisions + ["--"], in: workspacePath)) ?? ""
                page = GitHistoryParser.commits(output)
            } else {
                let filter = ["-n", "1000", "--regexp-ignore-case", "--fixed-strings"]
                async let byMessage = try? self.runGit(args: base + filter + ["--grep=\(query)"] + revisions + ["--"], in: workspacePath)
                async let byAuthor = try? self.runGit(args: base + filter + ["--author=\(query)"] + revisions + ["--"], in: workspacePath)
                var seen = Set<String>()
                page = (GitHistoryParser.commits(await byMessage ?? "") + GitHistoryParser.commits(await byAuthor ?? ""))
                    .filter { seen.insert($0.hash).inserted }
                    .sorted { $0.date > $1.date }
                if query.count >= 4, query.allSatisfy(\.isHexDigit),
                   let output = try? await self.runGit(args: base + ["-n", "1", query, "--"], in: workspacePath),
                   let match = GitHistoryParser.commits(output).first, !seen.contains(match.hash) {
                    page.insert(match, at: 0)
                }
            }
            guard !Task.isCancelled, self.activeWorkspacePath == workspacePath else { return }
            store.hasMoreCommits = query.isEmpty && page.count > Self.historyPageSize
            let existing = skip == 0 ? [] : store.commits
            let known = Set(existing.map(\.hash))
            store.commits = existing + page.prefix(query.isEmpty ? Self.historyPageSize : page.count).filter { !known.contains($0.hash) }
            store.graph = query.isEmpty && !target.isSingleCommit ? GitGraphLayout.rows(for: store.commits) : []
            store.isLoadingHistory = false
        }
    }

    @MainActor
    func selectHistoryCommit(_ commit: GitHistoryCommit?) {
        let store = repositories
        store.selectedCommitHash = commit?.hash
        store.detailTask?.cancel()
        guard let commit else {
            store.detail = nil
            return
        }
        let workspacePath = activeWorkspacePath
        store.detailTask = Task { @MainActor in
            guard let detail = await self.gitCommitDetail(commit, in: workspacePath), !Task.isCancelled else { return }
            if store.selectedCommitHash == commit.hash { store.detail = detail }
        }
    }

    func gitCommitDetail(_ commit: GitHistoryCommit, in workspacePath: String) async -> GitCommitDetail? {
        async let bodyRun = try? runGit(args: ["--no-optional-locks", "show", "-s", "--format=%b", commit.hash], in: workspacePath)
        async let statusRun = try? runGit(args: ["--no-optional-locks", "show", "--name-status", "-z", "-M", "--diff-merges=first-parent", "--format=", commit.hash], in: workspacePath)
        async let numstatRun = try? runGit(args: ["--no-optional-locks", "show", "--numstat", "-z", "-M", "--diff-merges=first-parent", "--format=", commit.hash], in: workspacePath)
        async let rootRun = try? runGit(args: ["rev-parse", "--show-toplevel"], in: workspacePath)
        async let rawCommitRun = try? runGit(args: ["--no-optional-locks", "cat-file", "commit", commit.hash], in: workspacePath)
        let stats = GitStatusParser.numstat(await numstatRun ?? "")
        let root = URL(fileURLWithPath: (await rootRun ?? workspacePath).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        var files = GitStatusParser.nameStatus(await statusRun ?? "").map { change in
            GitCommitFileChange(
                commitHash: commit.hash,
                relativePath: change.path,
                absolutePath: Self.repoAbsolutePath(repoRoot: root, relativePath: change.path),
                status: change.status,
                added: stats[change.path]?.added ?? 0,
                removed: stats[change.path]?.removed ?? 0
            )
        }
        if await hasStashUntrackedParent(for: commit.hash, in: workspacePath) {
            async let untrackedStatusRun = try? runGit(args: ["--no-optional-locks", "show", "--name-status", "-z", "--format=", "\(commit.hash)^3"], in: workspacePath)
            async let untrackedNumstatRun = try? runGit(args: ["--no-optional-locks", "show", "--numstat", "-z", "--format=", "\(commit.hash)^3"], in: workspacePath)
            let untrackedStats = GitStatusParser.numstat(await untrackedNumstatRun ?? "")
            var seen = Set(files.map(\.relativePath))
            for change in GitStatusParser.nameStatus(await untrackedStatusRun ?? "") where seen.insert(change.path).inserted {
                files.append(GitCommitFileChange(
                    commitHash: commit.hash,
                    relativePath: change.path,
                    absolutePath: Self.repoAbsolutePath(repoRoot: root, relativePath: change.path),
                    status: "A",
                    added: untrackedStats[change.path]?.added ?? 0,
                    removed: untrackedStats[change.path]?.removed ?? 0
                ))
            }
        }
        let rawCommit = Data((await rawCommitRun ?? "").utf8)
        let signature = await MainActor.run {
            GitSigningStore.shared.verifyCommitSignature(rawCommit: rawCommit)
        }
        return GitCommitDetail(
            commit: commit,
            body: (await bodyRun ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            files: files,
            signature: signature
        )
    }

    @MainActor
    func openHistoryFileDiff(_ file: GitCommitFileChange, in commit: GitHistoryCommit) {
        let previousTarget = repositories.historyTarget
        let summary = GitCommitSummary(hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject, author: commit.author, relativeTime: "")
        closeSourceControlSurface()
        openCommitFileDiff(file, commit: summary)
        git.commitDiffReturnHistory = previousTarget
    }

    @MainActor
    func runRepositoryAction(_ failureTitle: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
            } catch {
                self.presentGitAlert(failureTitle, error.localizedDescription)
            }
            self.refreshFileStatus()
            self.reloadRepositoryRefs()
        }
    }

    @MainActor
    func runConflictingOperation(_ failureTitle: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
                await self.refreshBlameHead()
            } catch {
                let gitDir = (try? await self.runGit(args: ["rev-parse", "--absolute-git-dir"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let operation = gitDir.isEmpty ? nil : GitMergeOperation.detect(gitDir: gitDir) {
                    self.sourceControl.navigatorTab = .changes
                    self.showNavigator(.git)
                    let alert = NSAlert()
                    alert.messageText = "The \(operation.title.lowercased()) stopped on conflicts"
                    alert.informativeText = "Resolve the files listed under Merge Conflicts in the Source Control navigator, mark each as resolved, then choose Continue. Abort returns everything to how it was."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    self.present(alert) { _ in }
                } else {
                    self.presentGitAlert(failureTitle, error.localizedDescription)
                }
            }
            self.reloadCleanOpenDocumentsFromDisk()
            self.refreshFileStatus()
            self.reloadRepositoryRefs()
        }
    }

    @MainActor
    func confirm(_ title: String, _ message: String, action: String, destructive: Bool = false, then perform: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in perform() }
        }
    }

    @MainActor
    func switchToRef(_ ref: GitRef) {
        switch ref.kind {
        case .branch:
            switchBranchStashingIfNeeded(ref.name)
        case .remoteBranch(let remote):
            let local = ref.name
            let remoteShort = ref.fullName.replacingOccurrences(of: "refs/remotes/", with: "")
            if let existing = repositories.branches.first(where: { $0.name == local }) {
                if existing.upstream == remoteShort || existing.shortHash == ref.shortHash {
                    switchBranchStashingIfNeeded(local)
                    return
                }
                let prefixed = "\(remote)-\(local)"
                if let matchingAlt = repositories.branches.first(where: { $0.name == prefixed && ($0.upstream == remoteShort || $0.shortHash == ref.shortHash) }) {
                    switchBranchStashingIfNeeded(matchingAlt.name)
                    return
                }
                let existingNames = Set(repositories.branches.map(\.name))
                var candidate = prefixed
                var suffix = 2
                while existingNames.contains(candidate) {
                    candidate = "\(prefixed)-\(suffix)"
                    suffix += 1
                }
                let alert = NSAlert()
                alert.messageText = "A local branch named “\(local)” already exists."
                if !existing.upstream.isEmpty {
                    alert.informativeText = "“\(local)” tracks “\(existing.upstream)”, not “\(remoteShort)”. Create a new branch “\(candidate)” tracking “\(remoteShort)”, or switch to your existing “\(local)” branch?"
                } else {
                    alert.informativeText = "“\(local)” points to \(existing.shortHash) instead of “\(remoteShort)” (\(ref.shortHash)). Create a new branch “\(candidate)” tracking “\(remoteShort)”, or switch to your existing “\(local)” branch?"
                }
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Create “\(candidate)”")
                alert.addButton(withTitle: "Switch to “\(local)”")
                alert.addButton(withTitle: "Cancel")
                present(alert) { response in
                    switch response {
                    case .alertFirstButtonReturn:
                        self.createTrackingBranch(candidate, tracking: remoteShort)
                    case .alertSecondButtonReturn:
                        self.switchBranchStashingIfNeeded(local)
                    default:
                        break
                    }
                }
            } else {
                createTrackingBranch(local, tracking: remoteShort)
            }
        case .tag:
            switchToRevision(ref.name, title: "tag “\(ref.name)”")
        }
    }

    @MainActor
    private func createTrackingBranch(_ localName: String, tracking remoteShort: String) {
        let performCreate: @MainActor () -> Void = {
            self.runRepositoryAction("Couldn’t Switch to “\(localName)”") {
                _ = try await self.runGit(args: ["switch", "--track", "-c", localName, remoteShort])
                await self.refreshBlameHead()
                self.reloadCleanOpenDocumentsFromDisk()
                self.refreshActiveFileDiff()
                self.updateCaretLineBlame()
            }
        }
        guard !git.changedFiles.isEmpty || !editedWorkspacePathsNotInGit.isEmpty else {
            performCreate()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch to “\(localName)” with uncommitted changes?"
        alert.informativeText = "Stash and Switch saves your changes as a stash you can apply later. Switch tries to carry them over and stops if they conflict."
        alert.addButton(withTitle: "Stash and Switch")
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            Task { @MainActor in
                switch response {
                case .alertFirstButtonReturn:
                    do {
                        _ = try await self.gitStashSave(message: "Switch to \(localName)")
                    } catch {
                        self.presentGitAlert("Couldn’t Stash Your Changes", error.localizedDescription)
                        return
                    }
                    performCreate()
                case .alertSecondButtonReturn:
                    guard await self.saveAllEditedFilesInWorkspace() else {
                        self.presentGitAlert("Couldn’t Save Modified Files", "Save all modified files before switching branches.")
                        return
                    }
                    performCreate()
                default:
                    break
                }
            }
        }
    }

    @MainActor
    func switchBranchStashingIfNeeded(_ branch: String) {
        guard branch != git.branchName else { return }
        guard !git.changedFiles.isEmpty || !editedWorkspacePathsNotInGit.isEmpty else {
            switchBranch(branch)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch to “\(branch)” with uncommitted changes?"
        alert.informativeText = "Stash and Switch saves your changes as a stash you can apply later. Switch tries to carry them over and stops if they conflict."
        alert.addButton(withTitle: "Stash and Switch")
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            Task { @MainActor in
                switch response {
                case .alertFirstButtonReturn:
                    do {
                        _ = try await self.gitStashSave(message: "Switch to \(branch)")
                    } catch {
                        self.presentGitAlert("Couldn’t Stash Your Changes", error.localizedDescription)
                        return
                    }
                    do {
                        _ = try await self.checkoutBranch(branch)
                    } catch {
                        self.presentBranchSwitchFailure(branch: branch, error: error, stashMessage: "Switch to \(branch)")
                    }
                    self.reloadRepositoryRefs()
                case .alertSecondButtonReturn:
                    guard await self.saveAllEditedFilesInWorkspace() else {
                        self.presentGitAlert("Couldn’t Save Modified Files", "Save all modified files before switching branches.")
                        return
                    }
                    self.switchBranch(branch)
                default:
                    break
                }
            }
        }
    }

    @MainActor
    func switchToRevision(_ revision: String, title: String) {
        confirm("Switch to \(title)?", "You’ll be on a detached HEAD: new commits won’t belong to any branch until you create one.", action: "Switch") {
            self.runRepositoryAction("Couldn’t Switch to \(title)") {
                _ = try await self.runGit(args: ["switch", "--detach", revision])
                await self.refreshBlameHead()
                self.reloadCleanOpenDocumentsFromDisk()
                self.refreshActiveFileDiff()
                self.updateCaretLineBlame()
            }
        }
    }

    @MainActor
    func confirmDeleteBranch(_ ref: GitRef) {
        Task { @MainActor in
            let upstream = ((try? await self.runGit(args: ["for-each-ref", "--format=%(upstream:short)", "refs/heads/" + ref.name])) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedIntoHead = (try? await self.runGit(args: ["merge-base", "--is-ancestor", "refs/heads/" + ref.name, "HEAD"])) != nil
            let hasRemote: Bool
            if upstream.isEmpty {
                hasRemote = false
            } else {
                hasRemote = (try? await self.runGit(args: ["show-ref", "--verify", "--quiet", "refs/remotes/" + upstream])) != nil
            }
            let mergedIntoUpstream: Bool
            if !hasRemote {
                mergedIntoUpstream = true
            } else {
                mergedIntoUpstream = (try? await self.runGit(args: ["merge-base", "--is-ancestor", "refs/heads/" + ref.name, "refs/remotes/" + upstream])) != nil
            }
            let targetBranchName = self.git.branchName.isEmpty ? "HEAD" : self.git.branchName
            let decision = GitBranchDeleteDecision.evaluate(
                branchName: ref.name,
                targetBranchName: targetBranchName,
                upstream: upstream,
                mergedIntoHead: mergedIntoHead,
                hasRemoteTrackingRef: hasRemote
            )
            let alert = NSAlert()
            alert.messageText = decision.messageText
            alert.informativeText = decision.informativeText
            alert.alertStyle = .warning
            alert.addButton(withTitle: decision.actionTitle).hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            if decision.showsDeleteRemoteOption, let deleteRemoteTitle = decision.deleteRemoteTitle {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = deleteRemoteTitle
                alert.suppressionButton?.state = .off
            }
            self.present(alert) { response in
                guard response == .alertFirstButtonReturn else { return }
                let deleteRemote = alert.suppressionButton?.state == .on
                let flag = GitBranchDeleteDecision.branchDeleteFlag(
                    mergedIntoHead: mergedIntoHead,
                    mergedIntoUpstream: mergedIntoUpstream,
                    deleteRemote: deleteRemote
                )
                self.runRepositoryAction("Couldn’t Delete “\(ref.name)”") {
                    _ = try await self.runGit(args: ["branch", flag, ref.name])
                    if deleteRemote, let slash = upstream.firstIndex(of: "/") {
                        _ = try await self.runGit(args: ["push", String(upstream[..<slash]), "--delete", String(upstream[upstream.index(after: slash)...])])
                    }
                }
            }
        }
    }

    @MainActor
    func confirmDeleteTag(_ ref: GitRef) {
        confirm("Delete the tag “\(ref.name)”?", "The tag is removed from this repository. A copy already pushed to a remote stays there.", action: "Delete", destructive: true) {
            self.runRepositoryAction("Couldn’t Delete “\(ref.name)”") {
                _ = try await self.runGit(args: ["tag", "-d", ref.name])
            }
        }
    }

    @MainActor
    func confirmDeleteStash(_ entry: GitStashEntry) {
        confirm("Delete the stash “\(entry.message.isEmpty ? entry.ref : entry.message)”?", "Its changes are removed from the stash list and can’t be applied again.", action: "Delete", destructive: true) {
            self.runRepositoryAction("Couldn’t Delete the Stash") {
                _ = try await self.gitDropStash(entry.ref)
            }
        }
    }

    @MainActor
    func applyStash(_ entry: GitStashEntry, delete: Bool) {
        runRepositoryAction("Couldn’t Apply the Stash") {
            _ = try await self.gitApplyStash(entry.ref, dropAfter: delete)
        }
    }

    @MainActor
    func mergeIntoCurrent(_ ref: GitRef) {
        let current = git.branchName
        confirm("Merge “\(ref.name)” into “\(current)”?", "Changes from “\(ref.name)” are merged into your current branch. If they conflict, GoLens lists the files to resolve.", action: "Merge") {
            self.runConflictingOperation("Couldn’t Merge “\(ref.name)”") {
                _ = try await self.runGit(args: self.unsignedGitConfigFlags() + ["merge", "--no-edit", ref.fullName])
            }
        }
    }

    @MainActor
    func rebaseCurrent(onto ref: GitRef) {
        let current = git.branchName
        confirm("Rebase “\(current)” onto “\(ref.name)”?", "Your commits on “\(current)” are replayed on top of “\(ref.name)”. If they conflict, GoLens lists the files to resolve.", action: "Rebase") {
            self.runConflictingOperation("Couldn’t Rebase onto “\(ref.name)”") {
                _ = try await self.runGit(args: self.unsignedGitConfigFlags() + ["rebase", ref.fullName])
            }
        }
    }

    @MainActor
    func cherryPick(_ commit: GitHistoryCommit) {
        confirm("Cherry-pick “\(commit.subject)” onto “\(git.branchName)”?", "The change from \(commit.shortHash) is applied as a new commit on your current branch.", action: "Cherry-Pick") {
            self.runConflictingOperation("Couldn’t Cherry-Pick \(commit.shortHash)") {
                _ = try await self.runGit(args: self.unsignedGitConfigFlags() + ["cherry-pick", commit.hash])
            }
        }
    }

    @MainActor
    func revertCommit(_ commit: GitHistoryCommit) {
        confirm("Revert “\(commit.subject)”?", "A new commit on “\(git.branchName)” undoes the change from \(commit.shortHash). History is not rewritten.", action: "Revert") {
            self.runConflictingOperation("Couldn’t Revert \(commit.shortHash)") {
                _ = try await self.runGit(args: self.unsignedGitConfigFlags() + ["revert", "--no-edit", commit.hash])
            }
        }
    }

    @MainActor
    func confirmUndoLastCommit(then onUndone: (@MainActor () -> Void)? = nil) {
        guard let last = git.recentCommits.first else { return }
        Task { @MainActor in
            let pushed = ((try? await self.runGit(args: ["branch", "-r", "--contains", last.hash])) ?? "").contains { !$0.isWhitespace }
            self.confirm(
                "Undo the commit “\(last.subject)”?",
                pushed
                    ? "\(last.shortHash) is already on a remote. Undoing it here doesn’t remove it there, and pushing afterwards needs a force push. Its changes stay staged."
                    : "\(last.shortHash) is removed from “\(self.git.branchName)” and its changes stay staged, so you can commit them again.",
                action: "Undo Commit",
                destructive: pushed
            ) {
                self.runRepositoryAction("Couldn’t Undo the Last Commit") {
                    _ = try await self.gitUndoLastCommit()
                    onUndone?()
                }
            }
        }
    }

    @MainActor
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
