import Foundation
import GoLensFoundation
import SwiftUI

extension WorkspaceState {
    func scheduleGitStatusRefresh(after delay: TimeInterval = 0.3) {
        gitRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshGitStatus()
        }
        gitRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setGit<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<GitState, Value>, _ value: Value) {
        if git[keyPath: keyPath] != value {
            git[keyPath: keyPath] = value
        }
    }

    static func gitChangedFiles(from snapshot: GitStatusSnapshot, repoRoot: String, workspacePrefix: String) -> [GitChangedFile] {
        GitStatusParser.rows(from: snapshot, workspacePrefix: workspacePrefix).map {
            GitChangedFile(
                relativePath: $0.relativePath,
                absolutePath: repoAbsolutePath(repoRoot: repoRoot, relativePath: $0.repoPath),
                status: $0.status,
                isStaged: $0.isStaged,
                originalPath: $0.originalPath,
                repoPath: $0.repoPath,
                originalRepoPath: $0.originalRepoPath
            )
        }
    }

    static func repoAbsolutePath(repoRoot: String, relativePath: String) -> String {
        let joined = URL(fileURLWithPath: (repoRoot as NSString).appendingPathComponent(relativePath)).standardizedFileURL.path
        if relativePath.contains("..") {
            return canonicalizePath(joined)
        }
        if let type = (try? FileManager.default.attributesOfItem(atPath: joined))?[.type] as? FileAttributeType {
            return type == .typeSymbolicLink ? URL(fileURLWithPath: joined).resolvingSymlinksInPath().path : joined
        }
        return canonicalizePath(joined)
    }

    func refreshGitStatus() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshGitStatus() }
            return
        }
        gitRefreshWorkItem?.cancel()
        gitRefreshWorkItem = nil
        let coordinator = GitRefreshCoordinator.shared
        guard !activeWorkspacePath.isEmpty else {
            coordinator.token += 1
            gitStatusTask?.cancel()
            gitStatusTask = nil
            coordinator.inFlightWorkspace = nil
            coordinator.pending = false
            coordinator.untrackedDirectories = []
            clearGitState(isRepository: nil)
            return
        }

        let workspacePath = self.activeWorkspacePath
        if coordinator.inFlightWorkspace == workspacePath {
            coordinator.pending = true
            return
        }
        gitStatusTask?.cancel()
        coordinator.token += 1
        let token = coordinator.token
        coordinator.inFlightWorkspace = workspacePath
        coordinator.pending = false
        coordinator.reset(keeping: workspacePath)
        gitStatusTask = Task { @MainActor in
            await self.performGitStatusRefresh(workspacePath: workspacePath)
            guard coordinator.token == token else { return }
            coordinator.inFlightWorkspace = nil
            self.gitStatusTask = nil
            if coordinator.pending && self.activeWorkspacePath == workspacePath {
                coordinator.pending = false
                self.refreshGitStatus()
            }
        }
    }

    private func gitAttempt(_ args: [String], in workspacePath: String) async -> Result<GitCommandResult, Error> {
        do {
            return .success(try await runGitCommand(args: args, in: workspacePath))
        } catch {
            return .failure(error)
        }
    }

    private func gitOutputIf(_ condition: Bool, _ args: [String], in workspacePath: String) async -> String? {
        guard condition else { return nil }
        do {
            let result = try await runGitCommand(args: args, in: workspacePath)
            if result.exitCode == 0 {
                return result.output
            }
            if let message = GitCommandFailureFormatter.formatFailure(
                args: args,
                exitCode: result.exitCode,
                stderr: result.errorText,
                stdout: result.output
            ) {
                logGitRefreshFailure(message)
            }
            return nil
        } catch {
            let nsError = error as NSError
            if let message = GitCommandFailureFormatter.formatFailure(
                args: args,
                exitCode: nsError.code,
                stderr: nsError.localizedDescription,
                stdout: ""
            ) {
                logGitRefreshFailure(message)
            }
            return nil
        }
    }

    private func logGitRefreshFailure(_ message: String) {
        appendLog(message, isStderr: true)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @MainActor
    private func gitRepoLocation(for workspacePath: String) async -> Result<GitRepoLocation, Error> {
        let coordinator = GitRefreshCoordinator.shared
        if let cached = coordinator.locations[workspacePath], FileManager.default.fileExists(atPath: cached.gitDir) {
            return .success(cached)
        }
        coordinator.locations[workspacePath] = nil
        do {
            let top = try await runGit(args: ["--no-optional-locks", "rev-parse", "--show-toplevel", "--absolute-git-dir"], in: workspacePath)
            let lines = top.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let repoRoot = Self.canonicalizePath(lines.first ?? "")
            let gitDir = lines.count > 1 ? lines[1] : (repoRoot as NSString).appendingPathComponent(".git")
            let workspaceRoot = Self.canonicalizePath(workspacePath)
            let prefix = (workspaceRoot.hasPrefix(repoRoot + "/") && workspaceRoot.count > repoRoot.count)
                ? String(workspaceRoot.dropFirst(repoRoot.count + 1)) + "/"
                : ""
            let location = GitRepoLocation(repoRoot: repoRoot, gitDir: gitDir, workspacePrefix: prefix)
            if !Task.isCancelled && activeWorkspacePath == workspacePath {
                coordinator.locations[workspacePath] = location
            }
            return .success(location)
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func markGitUnavailable(workspacePath: String) {
        let status = GitRefreshStatus.shared
        let message = "The Linux VM isn’t running, so Git status can’t be read. GoLens refreshes it as soon as the VM is ready."
        if status.unavailableMessage != message {
            status.unavailableMessage = message
        }
        let coordinator = GitRefreshCoordinator.shared
        coordinator.unavailableAttempts += 1
        let backoff = min(30.0, pow(2.0, Double(min(coordinator.unavailableAttempts, 5))))
        coordinator.unavailableRetryTask?.cancel()
        coordinator.unavailableRetryTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled && self.activeWorkspacePath == workspacePath {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled || self.activeWorkspacePath != workspacePath { return }
                if SandboxVMManager.shared.isRunning && Date().timeIntervalSince(start) >= min(backoff, 2) {
                    self.refreshGitStatus()
                    return
                }
                if Date().timeIntervalSince(start) >= backoff * 8 {
                    return
                }
            }
        }
    }

    @MainActor
    private func retryGitRefreshAfterTransientFailure(workspacePath: String) -> Bool {
        let coordinator = GitRefreshCoordinator.shared
        if coordinator.transientRetryWorkspace != workspacePath {
            coordinator.transientRetryWorkspace = workspacePath
            coordinator.transientAttempts = 0
        }
        guard coordinator.transientAttempts < GitRefreshCoordinator.maxTransientAttempts else { return false }
        let delay = 0.5 * pow(2.0, Double(coordinator.transientAttempts))
        coordinator.transientAttempts += 1
        coordinator.transientRetryTask?.cancel()
        coordinator.transientRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.activeWorkspacePath == workspacePath else { return }
            self.refreshGitStatus()
        }
        return true
    }

    @MainActor
    private func settleTransientGitRetry() {
        let coordinator = GitRefreshCoordinator.shared
        coordinator.transientAttempts = 0
        coordinator.transientRetryTask?.cancel()
        coordinator.transientRetryTask = nil
    }

    @MainActor
    private func clearGitUnavailable() {
        let coordinator = GitRefreshCoordinator.shared
        coordinator.unavailableAttempts = 0
        coordinator.unavailableRetryTask?.cancel()
        coordinator.unavailableRetryTask = nil
        if GitRefreshStatus.shared.unavailableMessage != nil {
            GitRefreshStatus.shared.unavailableMessage = nil
        }
    }

    private struct GitStatusRefreshResult {
        let snapshot: GitStatusSnapshot
        let changedFiles: [GitChangedFile]
        let unmergedStatuses: [String: String]
        let mergeOperation: GitMergeOperation?
        let rebaseStoppedToEdit: Bool
        let lineStats: [String: GitFileLineStats]?
        let fileStamps: [String: String]
        let untrackedDirectories: [String]
    }

    static func buildGitStatusMap(from changedFiles: [GitChangedFile]) -> [String: String] {
        var map: [String: String] = [:]
        var hasUnstaged: Set<String> = []
        for file in changedFiles {
            let path = file.absolutePath
            if file.status == "U" {
                map[path] = "U"
            } else if !file.isStaged {
                if map[path] != "U" {
                    map[path] = file.status
                    hasUnstaged.insert(path)
                }
            } else if map[path] == nil && !hasUnstaged.contains(path) {
                map[path] = file.status
            }
        }
        return map
    }

    private static func lineStats(fromNumstat output: String, repoRoot: String) -> [String: GitFileLineStats] {
        var stats: [String: GitFileLineStats] = [:]
        for (rel, counts) in GitStatusParser.numstat(output) {
            stats[repoAbsolutePath(repoRoot: repoRoot, relativePath: rel)] = GitFileLineStats(added: counts.added, removed: counts.removed)
        }
        return stats
    }

    @MainActor
    private func performGitStatusRefresh(workspacePath: String) async {
        let coordinator = GitRefreshCoordinator.shared
        let location: GitRepoLocation
        switch await gitRepoLocation(for: workspacePath) {
        case .success(let found):
            location = found
        case .failure(let error):
            guard !Task.isCancelled, !(error is CancellationError), activeWorkspacePath == workspacePath else { return }
            if GitCommandError.isUnavailable(error) {
                markGitUnavailable(workspacePath: workspacePath)
            } else if GitRefreshCoordinator.hostSeesRepository(at: workspacePath), retryGitRefreshAfterTransientFailure(workspacePath: workspacePath) {
                return
            } else {
                clearGitUnavailable()
                coordinator.untrackedDirectories = []
                clearGitState(isRepository: false)
            }
            return
        }
        if Task.isCancelled { return }

        let indexPath = (location.gitDir as NSString).appendingPathComponent("index")
        let gitDir = location.gitDir
        let (indexStamp, fingerprint) = await Task.detached(priority: .userInitiated) {
            (GitChangeStamps.stamp(ofPath: indexPath), GitRefsFingerprint.compute(gitDir: gitDir))
        }.value
        GitIndexWatch.shared.record(indexPath: indexPath, stamp: indexStamp)
        let refsChanged = git.loadedRefsFingerprint != fingerprint

        async let statusRun = gitAttempt(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--", "."], in: workspacePath)
        async let numstatRun = gitAttempt(["--no-optional-locks", "diff-index", "--numstat", "-z", "--no-renames", "HEAD", "--", "."], in: workspacePath)
        async let branchRun = gitOutputIf(refsChanged, ["--no-optional-locks", "for-each-ref", "--sort=-committerdate", "--format=\(GitBranchSummary.refFormat)", "refs/heads"], in: workspacePath)
        async let stashRun = gitOutputIf(refsChanged, ["--no-optional-locks", "stash", "list", "-n", "50", "--pretty=format:%gd%x09%gs%x09%cr"], in: workspacePath)
        async let logRun = gitOutputIf(refsChanged, ["--no-optional-locks", "log", "-n", "30", "-z", "--pretty=format:%H%x09%h%x09%s%x09%an%x09%cr%x09%b"], in: workspacePath)

        let statusAttempt = await statusRun
        let status: GitCommandResult
        switch statusAttempt {
        case .success(let result) where result.exitCode == 0:
            status = result
        case .failure(let error) where GitCommandError.isUnavailable(error):
            if !Task.isCancelled && activeWorkspacePath == workspacePath {
                markGitUnavailable(workspacePath: workspacePath)
            }
            return
        default:
            if !Task.isCancelled && activeWorkspacePath == workspacePath {
                _ = retryGitRefreshAfterTransientFailure(workspacePath: workspacePath)
            }
            return
        }
        if Task.isCancelled { return }
        var numstatOutput: String?
        if case .success(let result) = await numstatRun, result.exitCode == 0, !result.isTruncated {
            numstatOutput = result.output
        }

        let repoRoot = location.repoRoot
        let workspacePrefix = location.workspacePrefix
        let statusOutput = status.output
        let firstNumstat = numstatOutput
        var parsed = await Task.detached(priority: .userInitiated) { () -> GitStatusRefreshResult in
            let snapshot = GitStatusParser.parse(statusOutput)
            let changedFiles = Self.gitChangedFiles(from: snapshot, repoRoot: repoRoot, workspacePrefix: workspacePrefix)
            var indexObjects: [String: String] = [:]
            var unmergedStatuses: [String: String] = [:]
            for entry in snapshot.entries {
                if entry.isUnmerged, let xy = entry.unmergedXY {
                    unmergedStatuses[Self.repoAbsolutePath(repoRoot: repoRoot, relativePath: entry.path)] = xy
                }
                guard let object = entry.indexObject else { continue }
                let relative = entry.path.hasPrefix(workspacePrefix) ? String(entry.path.dropFirst(workspacePrefix.count)) : entry.path
                indexObjects[relative] = object
            }
            var stamps: [String: String] = [:]
            var untrackedDirectories: [String] = []
            for file in changedFiles {
                if file.status == "??" && file.relativePath.hasSuffix("/") {
                    untrackedDirectories.append(file.absolutePath)
                } else if stamps[file.absolutePath] == nil {
                    stamps[file.absolutePath] = GitChangeStamps.stamp(ofPath: file.absolutePath) + "|" + (indexObjects[file.relativePath] ?? "")
                }
            }
            return GitStatusRefreshResult(
                snapshot: snapshot,
                changedFiles: changedFiles,
                unmergedStatuses: unmergedStatuses,
                mergeOperation: GitMergeOperation.detect(gitDir: gitDir),
                rebaseStoppedToEdit: GitMergeOperation.rebaseStoppedToEdit(gitDir: gitDir),
                lineStats: firstNumstat.map { Self.lineStats(fromNumstat: $0, repoRoot: repoRoot) },
                fileStamps: stamps,
                untrackedDirectories: untrackedDirectories
            )
        }.value
        if Task.isCancelled || activeWorkspacePath != workspacePath { return }
        if parsed.lineStats == nil && !parsed.snapshot.hasCommits {
            async let diffFilesRun = gitOutputIf(true, ["--no-optional-locks", "diff-files", "--numstat", "-z", "--no-renames", "--", "."], in: workspacePath)
            async let diffCachedRun = gitOutputIf(true, ["--no-optional-locks", "diff", "--cached", "--numstat", "-z", "--no-renames", "--", "."], in: workspacePath)
            let diffFilesOut = await diffFilesRun
            let diffCachedOut = await diffCachedRun
            if Task.isCancelled || activeWorkspacePath != workspacePath { return }
            if diffFilesOut != nil || diffCachedOut != nil {
                var combined = diffCachedOut.map { Self.lineStats(fromNumstat: $0, repoRoot: repoRoot) } ?? [:]
                if let diffFilesOut {
                    for (absPath, counts) in Self.lineStats(fromNumstat: diffFilesOut, repoRoot: repoRoot) {
                        if let existing = combined[absPath] {
                            combined[absPath] = GitFileLineStats(added: existing.added + counts.added, removed: existing.removed + counts.removed)
                        } else {
                            combined[absPath] = counts
                        }
                    }
                }
                parsed = GitStatusRefreshResult(
                    snapshot: parsed.snapshot,
                    changedFiles: parsed.changedFiles,
                    unmergedStatuses: parsed.unmergedStatuses,
                    mergeOperation: parsed.mergeOperation,
                    rebaseStoppedToEdit: parsed.rebaseStoppedToEdit,
                    lineStats: combined,
                    fileStamps: parsed.fileStamps,
                    untrackedDirectories: parsed.untrackedDirectories
                )
            }
        }

        clearGitUnavailable()
        let snapshot = parsed.snapshot
        let changedFiles = parsed.changedFiles
        coordinator.untrackedDirectories = parsed.untrackedDirectories
        fileRowStates.updateUntrackedFolders(parsed.untrackedDirectories)
        let stamps = GitChangeStamps.shared
        if stamps.fileStamps != parsed.fileStamps { stamps.fileStamps = parsed.fileStamps }
        if stamps.indexStamp != indexStamp { stamps.indexStamp = indexStamp }
        setGit(\.isRepository, true)
        let resolvedBranch = snapshot.head ?? "Detached HEAD"
        let branchDidChange = git.branchName != resolvedBranch
        setGit(\.branchName, resolvedBranch)
        if branchDidChange,
           let target = repositories.historyTarget,
           target.revision == "HEAD",
           !target.isSingleCommit,
           target.title != resolvedBranch {
            repositories.historyTarget = GitHistoryTarget(revision: "HEAD", title: resolvedBranch)
            if sourceControl.editorSurface == .history {
                loadHistory(reset: true)
            }
        }
        setGit(\.hasUpstream, snapshot.hasUpstream)
        setGit(\.aheadCount, snapshot.ahead)
        setGit(\.behindCount, snapshot.behind)
        setGit(\.changedFiles, changedFiles)
        setGit(\.statusMap, Self.buildGitStatusMap(from: changedFiles))
        setGit(\.unmergedStatuses, parsed.unmergedStatuses)
        if let lineStats = parsed.lineStats {
            setGit(\.fileLineStats, lineStats)
        }
        applyMergeConflictState(conflictedPaths: Set(changedFiles.lazy.filter { $0.status == "U" }.map(\.absolutePath)), operation: parsed.mergeOperation)
        if git.rebaseStoppedToEdit != parsed.rebaseStoppedToEdit { git.rebaseStoppedToEdit = parsed.rebaseStoppedToEdit }
        refreshActiveFileDiff()

        guard refsChanged else {
            settleTransientGitRetry()
            return
        }
        let branchesOutput = await branchRun
        let stashOutput = await stashRun
        let logOutput = await logRun
        if Task.isCancelled || activeWorkspacePath != workspacePath { return }
        if let branchesOutput {
            let summaries = GitBranchSummary.parseForEachRef(branchesOutput)
            setGit(\.branchSummaries, summaries)
            setGit(\.branches, summaries.map(\.name).sorted())
        }
        if let stashOutput {
            let entries = Self.parseGitStashList(stashOutput)
            setGit(\.stashes, entries)
            setGit(\.stashCount, entries.count)
        }
        if logOutput != nil || !snapshot.hasCommits {
            let (recent, lastBody) = Self.parseGitLog(logOutput ?? "")
            setBlameHead(recent.first?.hash ?? "")
            setGit(\.recentCommits, recent)
            setGit(\.lastCommitSubject, recent.first?.subject ?? "")
            setGit(\.lastCommitBody, lastBody)
            if let sel = git.selectedCommit, !recent.contains(where: { $0.hash == sel.hash }) {
                git.selectedCommit = nil
                git.selectedCommitBody = ""
                git.selectedCommitFiles = []
            }
        }
        if branchesOutput != nil && stashOutput != nil && (logOutput != nil || !snapshot.hasCommits) {
            git.loadedRefsFingerprint = fingerprint
            settleTransientGitRetry()
        } else {
            _ = retryGitRefreshAfterTransientFailure(workspacePath: workspacePath)
        }
    }

    private func clearGitState(isRepository: Bool?) {
        GitRefreshCoordinator.shared.untrackedDirectories = []
        fileRowStates.updateUntrackedFolders([])
        git.isRepository = isRepository
        git.changedFiles = []
        git.statusMap = [:]
        git.branchName = ""
        git.branches = []
        git.branchSummaries = []
        git.aheadCount = 0
        git.behindCount = 0
        git.hasUpstream = false
        git.fileLineStats = [:]
        git.stashCount = 0
        git.stashes = []
        git.recentCommits = []
        git.loadedRefsFingerprint = nil
        git.lastCommitSubject = ""
        git.lastCommitBody = ""
        git.selectedCommit = nil
        git.selectedCommitBody = ""
        git.selectedCommitFiles = []
        git.unmergedStatuses = [:]
        git.activeCommitDiffContext = nil
        git.commitDiffReturnHistory = nil
        applyMergeConflictState(conflictedPaths: [], operation: nil)
    }

    static func parseGitStashList(_ output: String) -> [GitStashEntry] {
        var entries: [GitStashEntry] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            if parts.count >= 3 {
                let message = parts[1].replacingOccurrences(of: #"^On [^:]+: "#, with: "", options: .regularExpression)
                entries.append(GitStashEntry(ref: parts[0], message: message, relativeTime: parts[2]))
            } else {
                entries.append(GitStashEntry(ref: "stash@{\(entries.count)}", message: trimmed, relativeTime: ""))
            }
        }
        return entries
    }

    static func parseGitLog(_ output: String) -> (commits: [GitCommitSummary], lastBody: String) {
        var commits: [GitCommitSummary] = []
        var lastBody = ""
        for record in output.split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            if commits.isEmpty, parts.count == 6 {
                lastBody = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            commits.append(GitCommitSummary(hash: parts[0], shortHash: parts[1], subject: parts[2], author: parts[3], relativeTime: parts[4]))
        }
        return (commits, lastBody)
    }
}
