import AppKit
import SwiftUI

struct CommitBanner: Equatable, Identifiable {
    let id = UUID()
    let hash: String
    let shortHash: String
    let subject: String
}

struct GitAuthorIdentity: Equatable {
    var name: String
    var email: String

    var isComplete: Bool { !name.isEmpty && !email.isEmpty }
    var display: String { "\(name) <\(email)>" }
}

enum CommitMessageText {
    static func hasContent(_ text: String) -> Bool {
        for byte in text.utf8 where byte != 32 && byte != 9 && byte != 10 && byte != 13 {
            return true
        }
        return false
    }

    static func subjectLength(_ text: String) -> Int {
        text.prefix(while: { !$0.isNewline }).count
    }

    static func split(_ text: String) -> (summary: String, description: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.range(of: "\n") else { return (trimmed, "") }
        let summary = String(trimmed[..<newline.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(trimmed[newline.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, description)
    }

    static func combine(subject: String, body: String) -> String {
        body.isEmpty ? subject : "\(subject)\n\n\(body)"
    }
}

extension WorkspaceState {
    @MainActor
    func showCommitEditor() {
        showNavigator(.git)
        sourceControl.editorSurface = .commit
        sourceControl.pendingCommitFocus = true
        Task { @MainActor in await fillMergeCommitMessage() }
    }

    @MainActor
    var isFinishingMerge: Bool {
        git.mergeOperation == .merge && git.conflictedPaths.isEmpty
    }

    @MainActor
    var commitDraftCanCommit: Bool {
        let ui = sourceControl
        guard ui.commitMessageHasText, !ui.isCommitting, git.conflictedPaths.isEmpty else { return false }
        if isFinishingMerge { return true }
        return (ui.commitAmend && !git.recentCommits.isEmpty) || !git.changedFiles.isEmpty || !editedWorkspacePathsNotInGit.isEmpty
    }

    @MainActor
    var commitEditorCanCommit: Bool {
        sourceControl.editorSurface == .commit && commitDraftCanCommit
    }

    @MainActor
    func gitAuthorIdentity() async -> GitAuthorIdentity {
        let name = (try? await runGit(args: ["config", "user.name"])) ?? ""
        let email = (try? await runGit(args: ["config", "user.email"])) ?? ""
        return GitAuthorIdentity(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @MainActor
    func commitFromEditor(andPush: Bool, forceUnsigned: Bool = false) {
        guard commitEditorCanCommit else {
            if sourceControl.isCommitting {
                presentCommandFeedback("A commit is already in progress.", title: "Commit Changes")
            } else if !git.conflictedPaths.isEmpty {
                presentCommandFeedback("Resolve all merge conflicts before committing.", title: "Commit Changes", tone: .warning)
            } else if !sourceControl.commitMessageHasText {
                presentCommandFeedback("Enter a commit message before committing.", title: "Commit Changes")
            } else {
                presentCommandFeedback("Stage or make changes before committing.", title: "Commit Changes")
            }
            return
        }
        let repo = activeWorkspacePath
        sourceControl.isCommitting = true
        sourceControl.lastCommitPushRequested = andPush
        GitSigningStore.shared.signingFailureMessage = nil
        sourceControl.commitTask?.cancel()
        sourceControl.commitTask = Task { @MainActor in
            await self.runEditorCommit(andPush: andPush, forceUnsigned: forceUnsigned, in: repo)
            if self.activeWorkspacePath == repo {
                self.sourceControl.isCommitting = false
                GitSigningStore.shared.isWaitingForSecurityKeyTouch = false
            }
            self.sourceControl.commitTask = nil
        }
    }

    @MainActor
    func cancelCommitFromEditor() {
        sourceControl.commitTask?.cancel()
        sourceControl.commitTask = nil
        sourceControl.isCommitting = false
        GitSigningStore.shared.isWaitingForSecurityKeyTouch = false
    }

    @MainActor
    private func runEditorCommit(andPush: Bool, forceUnsigned: Bool = false, in repo: String) async {
        let ui = sourceControl
        let signingStore = GitSigningStore.shared
        let shouldSign = signingStore.isSigningEnabled && !forceUnsigned
        let parts = CommitMessageText.split(ui.commitMessage)
        let finishingMerge = isFinishingMerge
        let amend = ui.commitAmend && !git.recentCommits.isEmpty && !finishingMerge
        let outside = finishingMerge ? [] : await stagedPathsOutsideWorkspace(in: repo)
        guard activeWorkspacePath == repo else { return }
        if !outside.isEmpty {
            let folder = (repo as NSString).lastPathComponent
            guard await confirmAlert(Self.outsideWorkspaceAlert(paths: outside, folder: folder)), activeWorkspacePath == repo else { return }
        }
        var amendedPushedCommit: String?
        if amend {
            amendedPushedCommit = await remoteBranchContainingHead(in: repo)
            guard activeWorkspacePath == repo else { return }
            if let remoteBranch = amendedPushedCommit {
                let shortHash = git.recentCommits.first?.shortHash ?? "The last commit"
                guard await confirmAlert(Self.amendPushedCommitAlert(shortHash: shortHash, remoteBranch: remoteBranch)), activeWorkspacePath == repo else { return }
            }
        }
        var stagedEverything = false
        if !amend && !finishingMerge && git.stagedFilesCount == 0 {
            guard await confirmAlert(Self.noStagedChangesAlert()), activeWorkspacePath == repo else { return }
            guard await saveAllEditedFilesInWorkspace() else {
                presentGitAlert("Couldn’t Save Modified Files", "Save all modified files before committing.")
                return
            }
            guard activeWorkspacePath == repo else { return }
            do {
                try await stageAllNonConflictedFiles(in: repo)
            } catch {
                presentGitAlert("Couldn’t Stage All Changes", error.localizedDescription)
                return
            }
            guard activeWorkspacePath == repo else { return }
            stagedEverything = true
        }
        do {
            try await gitCommit(
                summary: parts.summary,
                description: parts.description,
                amend: amend,
                assumeStaged: stagedEverything || finishingMerge,
                forceUnsigned: forceUnsigned,
                in: repo
            )
        } catch is CancellationError {
            refreshGitStatus()
            return
        } catch {
            if shouldSign || (!forceUnsigned && Self.isExternalGitSigningFailure(error.localizedDescription)) {
                signingStore.signingFailureMessage = error.localizedDescription
            } else {
                presentGitAlert("Couldn’t Commit", error.localizedDescription)
            }
            refreshGitStatus()
            return
        }
        guard activeWorkspacePath == repo else { return }
        let head = await committedHead(in: repo)
        guard activeWorkspacePath == repo else { return }
        ui.commitMessage = ""
        ui.commitAmend = false
        showCommitBanner(CommitBanner(hash: head.hash, shortHash: head.shortHash, subject: parts.summary))
        if andPush {
            if let remoteBranch = amendedPushedCommit {
                presentGitAlert("Amended, but not pushed", "The amended commit replaces one that’s already on \(remoteBranch), so pushing it needs a force push. Push it yourself when you’re ready.")
            } else if sourceControl.runningOperation != nil {
                presentGitAlert("Committed, but not pushed", "Another fetch, pull or push is running. Push again when it finishes.")
            } else if git.hasUpstream {
                pushChanges(to: nil, includeTags: false)
            } else {
                ui.sheet = .push
            }
        }
    }

    @MainActor
    private func remoteBranchContainingHead(in repo: String) async -> String? {
        let output = (try? await runGit(args: ["branch", "-r", "--contains", "HEAD"], in: repo)) ?? ""
        let names = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.first(where: { !$0.contains("->") }) ?? names.first
    }

    @MainActor
    private func committedHead(in repo: String) async -> (hash: String, shortHash: String) {
        let output = (try? await runGit(args: ["log", "-1", "--format=%H%n%h"], in: repo)) ?? ""
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        return (lines.first ?? "", lines.count > 1 ? lines[1] : "")
    }

    @MainActor
    private func showCommitBanner(_ banner: CommitBanner) {
        let ui = sourceControl
        ui.commitBanner = banner
        ui.commitBannerTask?.cancel()
        ui.commitBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, ui.commitBanner?.id == banner.id else { return }
            ui.commitBanner = nil
        }
    }

    @MainActor
    func stagedPathsOutsideWorkspace(in repo: String) async -> [String] {
        let prefix = ((try? await runGit(args: ["rev-parse", "--show-prefix"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return [] }
        let output = (try? await runGit(args: ["-c", "core.quotePath=false", "diff", "--cached", "--name-only", "-z"], in: repo)) ?? ""
        return output.split(separator: "\0").map(String.init).filter { !$0.hasPrefix(prefix) }
    }

    @MainActor
    func confirmAlert(_ alert: NSAlert) async -> Bool {
        await withCheckedContinuation { continuation in
            present(alert) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private static func noStagedChangesAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "No Staged Changes"
        alert.informativeText = "No changes have been staged for committing. Do you want to commit all your changes?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Stage All and Commit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static func amendPushedCommitAlert(shortHash: String, remoteBranch: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Amend a commit that’s already on a remote?"
        alert.informativeText = "\(shortHash) is on \(remoteBranch). Amending rewrites it, so pushing afterwards needs a force push."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Amend").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static func isExternalGitSigningFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("gpg failed to sign")
            || lower.contains("signing failed")
            || lower.contains("op-ssh-sign")
            || lower.contains("ssh-keygen")
            || (lower.contains("failed to write commit object") && lower.contains("sign"))
    }

    private static func outsideWorkspaceAlert(paths: [String], folder: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Also commit \(paths.count) \(paths.count == 1 ? "file" : "files") outside “\(folder)”?"
        var lines = paths.prefix(5).map { "• \($0)" }
        if paths.count > 5 { lines.append("and \(paths.count - 5) more") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
