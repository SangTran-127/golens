import AppKit
import Foundation

extension WorkspaceState {
    static let gitEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }()

    @MainActor
    func unsignedGitConfigFlags(forceUnsigned: Bool = false) -> [String] {
        if forceUnsigned || SandboxVMManager.shared.executionMode != .host {
            return ["-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false"]
        }
        return []
    }

    @MainActor
    func reloadCleanOpenDocumentsFromDisk() {
        let cleanOpenPaths = Set(openFiles.filter { documents[$0]?.isEdited != true })
        if !cleanOpenPaths.isEmpty {
            filesChangedOnDisk(cleanOpenPaths)
        }
    }

    func hasGitHead(in workspacePath: String) async -> Bool {
        (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--verify", "HEAD"], in: workspacePath)) != nil
    }

    func runGit(args: [String], in workspacePath: String? = nil, input: Data? = nil, maxOutputBytes: Int = GitCommandRunner.defaultMaxOutputBytes) async throws -> String {
        try Self.gitOutput(try await runGitCommand(args: args, in: workspacePath, input: input, maxOutputBytes: maxOutputBytes))
    }

    func runGitCommand(args: [String], in workspacePath: String? = nil, input: Data? = nil, maxOutputBytes: Int = GitCommandRunner.defaultMaxOutputBytes) async throws -> GitCommandResult {
        let root = self.activeWorkspacePath
        let directory = workspacePath ?? root
        guard !directory.isEmpty else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No active workspace"])
        }
        let result = try await GitCommandRunner.shared.run(args: args, root: root, directory: directory, input: input, maxOutputBytes: maxOutputBytes)
        if result.isUnavailable {
            throw NSError(domain: GitCommandError.domain, code: GitCommandError.unavailableCode, userInfo: [NSLocalizedDescriptionKey: "The Linux VM isn’t ready, so Git couldn’t run. Try again in a moment."])
        }
        if result.isOutsideWorkspace {
            throw NSError(domain: GitCommandError.domain, code: GitCommandError.outsideWorkspaceCode, userInfo: [NSLocalizedDescriptionKey: "Git can only run inside the open project folder, which is the folder shared with the Linux VM."])
        }
        return result
    }

    static func gitOutput(_ result: GitCommandResult) throws -> String {
        if result.exitCode == 0 {
            return result.output
        }
        let outText = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let errMsg = !outText.isEmpty ? outText : (!errText.isEmpty ? errText : "Git exited with status \(result.exitCode).")
        throw NSError(domain: GitCommandError.domain, code: result.exitCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
    }

    func checkoutBranch(_ branch: String) async throws -> String {
        let output = try await runGit(args: ["checkout", branch])
        await refreshBlameHead()
        await MainActor.run {
            self.reloadCleanOpenDocumentsFromDisk()
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @discardableResult
    func gitCommit(summary: String, description: String = "", amend: Bool = false, assumeStaged: Bool = false, forceUnsigned: Bool = false, in workspacePath: String? = nil) async throws -> String {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Commit message cannot be empty"])
        }

        let stagedFiles = await MainActor.run { self.git.changedFiles.filter { $0.isStaged } }
        if !amend && !assumeStaged && stagedFiles.isEmpty {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No changes staged for commit"])
        }

        let fullMessage = trimmedDescription.isEmpty ? trimmedSummary : "\(trimmedSummary)\n\n\(trimmedDescription)"
        let (shouldSign, selectedKeyPath, unsignedFlags): (Bool, String, [String]) = await MainActor.run {
            let store = GitSigningStore.shared
            return (
                store.isSigningEnabled && !forceUnsigned,
                store.selectedKey?.path ?? "",
                self.unsignedGitConfigFlags(forceUnsigned: forceUnsigned)
            )
        }

        let output: String
        if shouldSign {
            guard !selectedKeyPath.isEmpty else {
                throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No SSH signing key is selected. Choose a signing key in Settings ▸ Source Control."
                ])
            }
            let root = await MainActor.run { self.activeWorkspacePath }
            let directory = workspacePath ?? root
            let result = try await GitCommandRunner.shared.runSignedCommit(
                root: root,
                directory: directory,
                keyPath: selectedKeyPath,
                message: fullMessage,
                amend: amend
            )
            if result.isUnavailable {
                throw NSError(domain: GitCommandError.domain, code: GitCommandError.unavailableCode, userInfo: [NSLocalizedDescriptionKey: "The Linux VM isn’t ready, so Git couldn’t run. Try again in a moment."])
            }
            if result.isOutsideWorkspace {
                throw NSError(domain: GitCommandError.domain, code: GitCommandError.outsideWorkspaceCode, userInfo: [NSLocalizedDescriptionKey: "Git can only run inside the open project folder, which is the folder shared with the Linux VM."])
            }
            output = try Self.gitOutput(result)
        } else {
            var args = unsignedFlags + ["commit"]
            if amend {
                args.append("--amend")
            }
            args.append(contentsOf: ["-m", fullMessage])
            output = try await runGit(args: args, in: workspacePath)
        }
        await refreshBlameHead()

        await MainActor.run {
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @discardableResult
    func gitCreateTag(name: String, revision: String, message: String, in workspacePath: String? = nil) async throws -> String {
        let trimmedMsg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsignedFlags = await MainActor.run { self.unsignedGitConfigFlags() }
        if trimmedMsg.isEmpty {
            return try await runGit(args: unsignedFlags + ["tag", name, revision], in: workspacePath)
        }
        let (shouldSign, selectedKeyPath): (Bool, String) = await MainActor.run {
            let store = GitSigningStore.shared
            return (store.isSigningEnabled, store.selectedKey?.path ?? "")
        }
        if shouldSign {
            guard !selectedKeyPath.isEmpty else {
                throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No SSH signing key is selected. Choose a signing key in Settings ▸ Source Control."
                ])
            }
            let root = await MainActor.run { self.activeWorkspacePath }
            let directory = workspacePath ?? root
            let result = try await GitCommandRunner.shared.runSignedTag(
                root: root,
                directory: directory,
                keyPath: selectedKeyPath,
                tagName: name,
                revision: revision,
                message: trimmedMsg
            )
            if result.isUnavailable {
                throw NSError(domain: GitCommandError.domain, code: GitCommandError.unavailableCode, userInfo: [NSLocalizedDescriptionKey: "The Linux VM isn’t ready, so Git couldn’t run. Try again in a moment."])
            }
            if result.isOutsideWorkspace {
                throw NSError(domain: GitCommandError.domain, code: GitCommandError.outsideWorkspaceCode, userInfo: [NSLocalizedDescriptionKey: "Git can only run inside the open project folder, which is the folder shared with the Linux VM."])
            }
            return try Self.gitOutput(result)
        }
        let stripped = try await runGit(args: ["stripspace"], in: workspacePath, input: Data(trimmedMsg.utf8))
        return try await runGit(
            args: unsignedFlags + ["tag", "-a", "--cleanup=verbatim", "-F", "-", name, revision],
            in: workspacePath,
            input: Data(stripped.utf8)
        )
    }

    @discardableResult
    func gitStashSave(message: String? = nil) async throws -> String {
        let saved = await saveAllEditedFilesInWorkspace()
        guard saved else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Save modified files before stashing changes."
            ])
        }
        var args = ["stash", "push", "-u"]
        if let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            args.append(contentsOf: ["-m", trimmed])
        }
        args.append(contentsOf: ["--", "."])
        let output = try await runGit(args: args)
        await MainActor.run {
            self.reloadCleanOpenDocumentsFromDisk()
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @discardableResult
    func gitStashPop() async throws -> String {
        let output = try await runGit(args: ["stash", "pop"])
        await MainActor.run {
            self.reloadCleanOpenDocumentsFromDisk()
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @discardableResult
    func gitApplyStash(_ ref: String, dropAfter: Bool) async throws -> String {
        let subcommand = dropAfter ? "pop" : "apply"
        let output = try await runGit(args: ["stash", subcommand, ref])
        await MainActor.run {
            self.reloadCleanOpenDocumentsFromDisk()
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @discardableResult
    func gitDropStash(_ ref: String) async throws -> String {
        let output = try await runGit(args: ["stash", "drop", ref])
        await MainActor.run {
            self.refreshGitStatus()
        }
        return output
    }

    @discardableResult
    func gitUndoLastCommit() async throws -> String {
        let output = try await runGit(args: ["reset", "--soft", "HEAD~1"])
        await refreshBlameHead()
        await MainActor.run {
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        return output
    }

    @MainActor
    func gitPull(from remoteBranch: String? = nil, rebase: Bool? = nil) async throws -> String {
        var args = unsignedGitConfigFlags() + ["pull"]
        if let rebase { args.append(rebase ? "--rebase" : "--no-rebase") }
        let upstreamResult = try await runGitCommand(args: ["--no-optional-locks", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        let upstream = upstreamResult.exitCode == 0 ? upstreamResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let remoteBranch, remoteBranch != upstream, let slash = remoteBranch.firstIndex(of: "/") {
            args += [String(remoteBranch[..<slash]), String(remoteBranch[remoteBranch.index(after: slash)...])]
        }
        let before = try? await runGit(args: ["--no-optional-locks", "rev-parse", "HEAD"])
        let res = try await runGit(args: args)
        let after = try? await runGit(args: ["--no-optional-locks", "rev-parse", "HEAD"])
        await refreshBlameHead()
        reloadCleanOpenDocumentsFromDisk()
        refreshGitStatus()
        refreshActiveFileDiff()
        updateCaretLineBlame()
        return before == after ? "" : res
    }

    @MainActor
    func gitUpstreamRef() async -> (remote: String, branch: String)? {
        let branch = git.branchName
        guard git.hasUpstream, !branch.isEmpty, branch != "Detached HEAD",
              let remote = (try? await runGit(args: ["config", "--get", "branch.\(branch).remote"]))?.trimmingCharacters(in: .whitespacesAndNewlines),
              let merge = (try? await runGit(args: ["config", "--get", "branch.\(branch).merge"]))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty, !merge.isEmpty else { return nil }
        return (remote, merge.hasPrefix("refs/heads/") ? String(merge.dropFirst("refs/heads/".count)) : merge)
    }

    @MainActor
    func gitPush(to remote: String? = nil, includeTags: Bool = false) async throws -> String {
        let branch = git.branchName
        guard !branch.isEmpty && branch != "Detached HEAD" else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "HEAD isn’t on a branch. Create a branch, then push it."])
        }
        let upstream = await gitUpstreamRef()
        let target: String
        if let remote { target = remote } else if let upstream { target = upstream.remote } else { target = try await pushRemote(for: branch) }
        var args = ["push"]
        if let upstream, upstream.remote == target {
            args += [target, "HEAD:refs/heads/\(upstream.branch)"]
        } else {
            args += ["-u", target, "HEAD:refs/heads/\(branch)"]
        }
        if includeTags { args.append("--tags") }
        let res = try await runGit(args: args)
        refreshGitStatus()
        refreshActiveFileDiff()
        return res
    }

    @MainActor
    private func pushRemote(for branch: String) async throws -> String {
        for key in ["branch.\(branch).pushRemote", "remote.pushDefault"] {
            let result = try await runGitCommand(args: ["config", "--get", key])
            if result.exitCode == 0 {
                let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            } else if result.exitCode > 1 {
                _ = try Self.gitOutput(result)
            }
        }
        let remotes = try await runGit(args: ["remote"]).split(separator: "\n").map(String.init)
        if remotes.isEmpty {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "This repository has no remote to push to. Add one, then push again."])
        }
        return remotes.count == 1 ? remotes[0] : (remotes.contains("origin") ? "origin" : remotes[0])
    }

    @MainActor
    func gitFetch() async throws -> String {
        let res = try await runGit(args: ["fetch"])
        refreshGitStatus()
        refreshActiveFileDiff()
        return res
    }

    struct GitAlertRecovery {
        let title: String
        let handler: @MainActor () -> Void
    }

    @MainActor
    func presentGitAlert(_ title: String, _ message: String, recovery: GitAlertRecovery? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        presentFailure(
            title,
            trimmed.isEmpty ? "Check Source Control status and try again." : trimmed,
            recovery: recovery.map { recovery in
                (title: recovery.title, action: { MainActor.assumeIsolated { recovery.handler() } })
            }
        )
    }

    @MainActor
    func openConflictsInSidebar(preferredPath: String? = nil) {
        sourceControl.navigatorTab = .changes
        showNavigator(.git)
        if let path = preferredPath ?? git.conflictedPaths.sorted().first {
            openFile(path)
            setEditorMode(.code, for: path)
        }
    }

    @MainActor
    func gitRecovery(
        for error: Error,
        preferredPath: String? = nil,
        remoteOperation: GitRemoteOperation? = nil,
        targetBranch: String? = nil,
        retry: (@MainActor () -> Void)? = nil
    ) -> GitAlertRecovery? {
        let text = error.localizedDescription.lowercased()
        let hasDirtyTreeMessage = text.contains("would be overwritten")
            || text.contains("unstaged changes")
            || text.contains("uncommitted changes")
            || text.contains("commit your changes or stash them")
        let hasConflictMessage = error is MergeConflictError
            || text.contains("conflict")
            || text.contains("unmerged")
            || text.contains("resolve your current index")
            || text.contains("needs merge")

        if let targetBranch, hasDirtyTreeMessage {
            return GitAlertRecovery(title: "Stash and Switch") {
                self.switchBranchStashingIfNeeded(targetBranch)
            }
        } else if hasDirtyTreeMessage {
            return GitAlertRecovery(title: "Stash Changes…") {
                self.sourceControl.sheet = .stash
            }
        } else if remoteOperation == .push && (
            text.contains("non-fast-forward")
                || text.contains("fetch first")
                || text.contains("updates were rejected")
                || text.contains("tip of your current branch is behind")
        ) {
            return GitAlertRecovery(title: "Pull") {
                if self.git.hasUpstream {
                    self.pullChanges(from: nil, rebase: nil)
                } else {
                    self.sourceControl.sheet = .pull
                }
            }
        } else if remoteOperation == .push && (
            text.contains("no remote to push to")
                || text.contains("does not appear to be a git repository")
                || text.contains("no configured push destination")
        ) {
            return GitAlertRecovery(title: "Add Remote…") {
                self.sourceControl.sheet = .addRemote
            }
        } else if remoteOperation == .pull && (
            text.contains("no tracking information")
                || text.contains("no upstream branch")
                || text.contains("specify which branch")
        ) {
            return GitAlertRecovery(title: "Choose Branch…") {
                self.sourceControl.sheet = .pull
            }
        } else if hasConflictMessage {
            if let preferredPath, mergeConflictCount(for: preferredPath) > 0 {
                return GitAlertRecovery(title: "Open in Merge Editor") {
                    self.openMergeEditor(preferredPath)
                }
            } else if !git.conflictedPaths.isEmpty || text.contains("conflict") || text.contains("unmerged") || text.contains("resolve") {
                return GitAlertRecovery(title: "Open Conflicts") {
                    self.openConflictsInSidebar(preferredPath: preferredPath)
                }
            }
        }

        return retry.map { GitAlertRecovery(title: "Try Again", handler: $0) }
    }
}
