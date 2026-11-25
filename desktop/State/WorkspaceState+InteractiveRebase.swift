import AppKit
import Foundation

struct InteractiveRebaseRange: Equatable {
    let branch: String
    let base: String?
    let baseTitle: String
    let steps: [InteractiveRebaseStep]
    let pushedCount: Int
    let hasMerges: Bool
}

extension WorkspaceState {
    static let interactiveRebaseLimit = 200
    static let interactiveRebaseDefaultCount = 10

    var canStartInteractiveRebase: Bool {
        git.isRepository == true && hasNamedBranch && !git.recentCommits.isEmpty && git.mergeOperation == nil && git.conflictedPaths.isEmpty && sourceControl.runningOperation == nil
    }

    @MainActor
    func showInteractiveRebase(from hash: String?) {
        guard canStartInteractiveRebase else {
            if git.isRepository != true {
                presentCommandFeedback("Open a Git repository before starting an interactive rebase.", title: "Interactive Rebase Unavailable")
            } else if git.mergeOperation != nil {
                presentCommandFeedback("Finish or abort the \(git.mergeOperation?.title.lowercased() ?? "operation") in progress first.", title: "Interactive Rebase Unavailable")
            } else if !git.conflictedPaths.isEmpty {
                presentCommandFeedback("Resolve all merge conflicts before starting an interactive rebase.", title: "Interactive Rebase Unavailable")
            } else if !hasNamedBranch {
                presentCommandFeedback("Switch to a branch first. Interactive rebase rewrites the current branch.", title: "Interactive Rebase Unavailable")
            } else if git.recentCommits.isEmpty {
                presentCommandFeedback("Make at least one commit before starting an interactive rebase.", title: "Interactive Rebase Unavailable")
            } else if sourceControl.runningOperation != nil {
                presentCommandFeedback("Wait for the current remote operation to finish before starting an interactive rebase.", title: "Interactive Rebase Unavailable")
            }
            return
        }
        sourceControl.sheet = .interactiveRebase(from: hash)
    }

    func loadInteractiveRebaseRange(from hash: String?, branch: String) async throws -> InteractiveRebaseRange {
        func fail(_ message: String) -> NSError {
            NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let start: String
        if let hash {
            start = hash
        } else {
            start = try await defaultInteractiveRebaseStart()
        }
        let ancestorResult = try await runGitCommand(args: ["merge-base", "--is-ancestor", start, "HEAD"])
        if ancestorResult.exitCode == 1 {
            throw fail("“\(String(start.prefix(7)))” isn’t part of “\(branch)”, so there is nothing of it to rebase. Switch to the branch that contains it first.")
        }
        if ancestorResult.exitCode != 0 {
            _ = try Self.gitOutput(ancestorResult)
        }
        let parentsLine = try await runGit(args: ["rev-list", "--parents", "-n", "1", start]).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = parentsLine.split(separator: " ").dropFirst().first.map(String.init)
        let range = base.map { [$0 + "..HEAD"] } ?? ["HEAD"]
        let count = Int(try await runGit(args: ["rev-list", "--count"] + range).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard count > 0 else { throw fail("There are no commits after “\(String(start.prefix(7)))” to rebase.") }
        guard count <= Self.interactiveRebaseLimit else {
            throw fail("That would rebase \(count) commits. Start from a more recent commit; GoLens rebases at most \(Self.interactiveRebaseLimit) at a time.")
        }
        async let logRun = runGit(args: ["--no-optional-locks", "log", "-z", "--reverse", "--format=\(GitHistoryParser.logFormat)"] + range + ["--"])
        async let messagesRun = runGit(args: ["--no-optional-locks", "log", "-z", "--format=%H%x1f%B"] + range + ["--"])
        async let unpushedRun = runGit(args: ["rev-list"] + range + ["--not", "--remotes"])
        let commits = GitHistoryParser.commits(try await logRun)
        var messages: [String: String] = [:]
        for record in GitStatusParser.split(try await messagesRun, on: "\0") {
            let parts = GitStatusParser.split(record.trimmingCharacters(in: .newlines), on: "\u{1f}", maxSplits: 1)
            guard parts.count == 2 else { continue }
            messages[parts[0]] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let unpushed = Set((try await unpushedRun).split(separator: "\n").map(String.init))
        let baseTitle: String
        if let base {
            let subject = (try? await runGit(args: ["show", "-s", "--format=%h “%s”", base]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(base.prefix(7))
            baseTitle = subject
        } else {
            baseTitle = "the start of the history"
        }
        return InteractiveRebaseRange(
            branch: branch,
            base: base,
            baseTitle: baseTitle,
            steps: commits.map { InteractiveRebaseStep(commit: $0, message: messages[$0.hash] ?? $0.subject) },
            pushedCount: commits.filter { !unpushed.contains($0.hash) }.count,
            hasMerges: commits.contains { $0.parents.count > 1 }
        )
    }

    private func defaultInteractiveRebaseStart() async throws -> String {
        if let upstream = try? await runGit(args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !upstream.isEmpty,
           let ahead = try? await runGit(args: ["rev-list", "--reverse", "--first-parent", upstream + "..HEAD"]),
           let first = ahead.split(separator: "\n").first {
            return String(first)
        }
        let recent = try await runGit(args: ["rev-list", "--first-parent", "-n", String(Self.interactiveRebaseDefaultCount), "HEAD"])
        guard let oldest = recent.split(separator: "\n").last else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "This branch has no commits yet."])
        }
        return String(oldest)
    }

    @MainActor
    func runInteractiveRebase(_ range: InteractiveRebaseRange, steps: [InteractiveRebaseStep]) {
        let changed = steps.filter { $0.action != .pick }.count
        runConflictingOperation("Couldn’t Rebase “\(range.branch)”") {
            let gitDir = try await self.runGit(args: ["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: gitDir)) ?? [] where name.hasPrefix(InteractiveRebasePlan.messageFilePrefix) {
                try? fm.removeItem(atPath: (gitDir as NSString).appendingPathComponent(name))
            }
            let plan = InteractiveRebasePlan.todo(steps)
            try plan.todo.write(toFile: (gitDir as NSString).appendingPathComponent(InteractiveRebasePlan.todoFileName), atomically: true, encoding: .utf8)
            for (name, text) in plan.messages {
                try text.write(toFile: (gitDir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            _ = try await self.runGit(args: self.unsignedGitConfigFlags() + [
                "-c", "sequence.editor=\(InteractiveRebasePlan.sequenceEditor)",
                "-c", "core.editor=true",
                "rebase", "-i", "--autostash", range.base ?? "--root",
            ])
            if GitMergeOperation.detect(gitDir: gitDir) == .rebase {
                self.sourceControl.navigatorTab = .changes
                self.showNavigator(.git)
                let alert = NSAlert()
                alert.messageText = "The rebase stopped so you can change a commit"
                alert.informativeText = "Edit the files, stage them and amend the commit (or add new commits), then choose Continue in the Source Control navigator. Abort Rebase returns “\(range.branch)” to how it was."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                self.present(alert) { _ in }
            } else {
                for name in (try? fm.contentsOfDirectory(atPath: gitDir)) ?? [] where name == InteractiveRebasePlan.todoFileName || name.hasPrefix(InteractiveRebasePlan.messageFilePrefix) {
                    try? fm.removeItem(atPath: (gitDir as NSString).appendingPathComponent(name))
                }
                self.presentCommandFeedback(
                    changed == 0 ? "Reordered \(steps.count) commits on “\(range.branch)”." : "Rebased \(steps.count) commits on “\(range.branch)”.",
                    title: "Interactive Rebase Finished",
                    tone: .success
                )
                if self.sourceControl.editorSurface == .history { self.loadHistory(reset: true) }
            }
        }
    }
}
