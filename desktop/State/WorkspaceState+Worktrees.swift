import AppKit
import Foundation
import GoLensFoundation
import SwiftUI

extension WorkspaceState {
    var currentWorktreeCanonicalPath: String {
        WorkspacePathCanonicalizer.canonical(activeWorkspacePath)
    }

    func isCurrentWorktree(_ entry: GitWorktreeEntry) -> Bool {
        let current = currentWorktreeCanonicalPath
        return !current.isEmpty && WorkspacePathCanonicalizer.canonical(entry.path) == current
    }

    func isPrimaryWorktree(_ entry: GitWorktreeEntry) -> Bool {
        guard let primary = repositories.worktrees.first else { return false }
        return WorkspacePathCanonicalizer.canonical(primary.path) == WorkspacePathCanonicalizer.canonical(entry.path)
    }

    func worktree(forBranch branch: String) -> GitWorktreeEntry? {
        repositories.worktrees.first { $0.branchName == branch }
    }

    func worktreeRemovalDisabledReason(_ entry: GitWorktreeEntry) -> String? {
        if isPrimaryWorktree(entry) {
            return "The main repository worktree can’t be removed."
        }
        if isCurrentWorktree(entry) {
            return "Switch to another window or worktree before removing the current one."
        }
        return nil
    }

    @MainActor
    func openWorktree(_ entry: GitWorktreeEntry) {
        openWorktree(at: entry.path, displayName: entry.folderName)
    }

    @MainActor
    func openWorktree(at rawPath: String, displayName: String? = nil) {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        let targetPath = canonical.isEmpty ? rawPath : canonical
        let name = displayName ?? ((targetPath as NSString).lastPathComponent.isEmpty ? targetPath : (targetPath as NSString).lastPathComponent)
        var isDir: ObjCBool = false
        guard !targetPath.isEmpty,
              FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDir),
              isDir.boolValue else {
            let parent = (targetPath as NSString).deletingLastPathComponent
            presentFailure(
                "Couldn’t Open Worktree “\(name)”",
                "The folder at \(targetPath) no longer exists on disk. Prune stale worktree records to clean up the list.",
                recovery: ("Prune Stale Worktrees", { [weak self] in
                    self?.pruneWorktrees()
                }),
                revealing: parent.isEmpty ? nil : parent
            )
            return
        }
        WorkspaceSessionRegistry.shared.openProject(at: targetPath)
    }

    @MainActor
    func createWorktree(
        branchName: String,
        createNewBranch: Bool,
        baseRef: String?,
        destinationPath: String,
        openInNewWindow: Bool
    ) {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGitRepositoryOpen, !trimmedBranch.isEmpty, !trimmedPath.isEmpty else { return }

        let resolvedDest = (trimmedPath as NSString).expandingTildeInPath
        let trimmedBase = (baseRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["worktree", "add"]
        if createNewBranch {
            args.append(contentsOf: ["-b", trimmedBranch, resolvedDest])
            if !trimmedBase.isEmpty {
                args.append(trimmedBase)
            }
        } else {
            args.append(contentsOf: [resolvedDest, trimmedBranch])
        }

        Task { @MainActor in
            do {
                _ = try await self.runGit(args: args)
                self.reloadRepositoryRefs()
                self.refreshFileStatus()
                if openInNewWindow {
                    self.openWorktree(at: resolvedDest)
                }
            } catch {
                if let conflictPath = GitWorktreeParser.checkedOutWorktreePath(fromGitError: error.localizedDescription) {
                    self.presentWorktreeCheckoutConflictAlert(branch: trimmedBranch, worktreePath: conflictPath, stashMessage: nil)
                } else {
                    let parent = (resolvedDest as NSString).deletingLastPathComponent
                    self.presentFailure(
                        "Couldn’t Create Worktree",
                        Self.failureReason(error),
                        revealing: parent.isEmpty ? nil : parent
                    )
                }
                self.reloadRepositoryRefs()
            }
        }
    }

    @MainActor
    func confirmAndRemoveWorktree(_ entry: GitWorktreeEntry, force: Bool = false) {
        if let reason = worktreeRemovalDisabledReason(entry) {
            presentCommandFeedback(reason, title: "Can’t Remove Worktree")
            return
        }
        if force {
            performRemoveWorktree(entry, force: true)
            return
        }
        confirm(
            "Remove the worktree “\(entry.folderName)”?",
            "Git deletes the linked working tree at \(entry.path). Its branch “\(entry.displayBranch)” and commits remain in the repository.",
            action: "Remove",
            destructive: true
        ) {
            self.performRemoveWorktree(entry, force: false)
        }
    }

    @MainActor
    private func performRemoveWorktree(_ entry: GitWorktreeEntry, force: Bool) {
        Task { @MainActor in
            do {
                var args = ["worktree", "remove"]
                if force {
                    args.append("--force")
                    if entry.isLocked {
                        args.append("--force")
                    }
                }
                args.append(entry.path)
                _ = try await self.runGit(args: args)
                self.reloadRepositoryRefs()
                self.refreshFileStatus()
            } catch {
                let rawReason = Self.failureReason(error)
                let lower = rawReason.lowercased()
                let needsForce = !force && (
                    lower.contains("modified or untracked")
                        || lower.contains("contains modified")
                        || lower.contains("--force")
                        || lower.contains("is locked")
                )
                if needsForce {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Remove “\(entry.folderName)”"
                    alert.informativeText = "\(rawReason)\n\nForce removing discards any uncommitted or untracked changes inside \(entry.path)."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Force Remove").hasDestructiveAction = true
                    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
                    self.present(alert) { response in
                        guard response == .alertFirstButtonReturn else { return }
                        Task { @MainActor in
                            self.performRemoveWorktree(entry, force: true)
                        }
                    }
                } else {
                    self.presentFailure(
                        "Couldn’t Remove Worktree “\(entry.folderName)”",
                        rawReason,
                        revealing: entry.path
                    )
                }
                self.reloadRepositoryRefs()
            }
        }
    }

    @MainActor
    func pruneWorktrees() {
        runRepositoryAction("Couldn’t Prune Worktrees") {
            _ = try await self.runGit(args: ["worktree", "prune"])
        }
    }

    @MainActor
    func presentBranchSwitchFailure(branch: String, error: Error, stashMessage: String? = nil) {
        let message = Self.failureReason(error)
        if let conflictPath = GitWorktreeParser.checkedOutWorktreePath(fromGitError: error.localizedDescription)
            ?? GitWorktreeParser.checkedOutWorktreePath(fromGitError: message) {
            presentWorktreeCheckoutConflictAlert(branch: branch, worktreePath: conflictPath, stashMessage: stashMessage)
            return
        }
        if let stashMessage {
            presentGitAlert(
                "Couldn’t Switch to “\(branch)”",
                "Your changes are saved in the stash “\(stashMessage)”. Apply it from Repositories ▸ Stashed Changes.\n\n\(message)"
            )
            return
        }
        let recovery = gitRecovery(for: error, targetBranch: branch) {
            self.switchBranch(branch)
        }
        presentGitAlert("Couldn’t Switch to “\(branch)”", message, recovery: recovery)
    }

    @MainActor
    private func presentWorktreeCheckoutConflictAlert(branch: String, worktreePath: String, stashMessage: String?) {
        let canonical = WorkspacePathCanonicalizer.canonical(worktreePath)
        let matching = repositories.worktrees.first {
            WorkspacePathCanonicalizer.canonical($0.path) == canonical
        }
        let rawName = (worktreePath as NSString).lastPathComponent
        let folderName = matching?.folderName ?? (rawName.isEmpty ? worktreePath : rawName)
        let stashNote = stashMessage.map {
            "\n\nYour changes are saved in the stash “\($0)”. Apply it from Repositories ▸ Stashed Changes."
        } ?? ""

        let alert = NSAlert()
        alert.messageText = "Couldn’t Switch to “\(branch)”"
        alert.informativeText = "Branch “\(branch)” is already checked out in worktree “\(folderName)” at \(worktreePath). Open that worktree window instead of switching here.\(stashNote)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Worktree")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                self.openWorktree(at: worktreePath, displayName: folderName)
            }
        }
    }
}
