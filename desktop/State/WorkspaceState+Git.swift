import Foundation
import SwiftUI

struct GitDiffHunk: Identifiable, Equatable {
    var id: String { "\(newStart):\(newCount):\(oldStart):\(oldCount)" }
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let removedLines: [String]
    let addedLines: [String]
    let header: String
    var oldHasTrailingNewline: Bool = true
    var newHasTrailingNewline: Bool = true

    func contains(line1Based: Int) -> Bool {
        if newCount == 0 {
            return line1Based == max(1, newStart)
        }
        let end = max(newStart, newStart + max(newCount, 1) - 1)
        return (newStart ... end).contains(line1Based)
    }
}

enum GitDiffSource: Equatable {
    case unstaged
    case staged
}

@Observable
final class GitDiffSourceStore {
    static let shared = GitDiffSourceStore()
    var requested: [String: GitDiffSource] = [:]
}

extension WorkspaceState {
    static let gitPatchDiffFlags = ["--no-renames", "--no-color", "--no-ext-diff"]

    func gitStatus(for path: String) -> String? {
        return git.statusMap[path]
    }

    static func canonicalizePath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        var current = standardized
        var missingTail: [String] = []
        let fm = FileManager.default
        while !current.isEmpty && current != "/" && !fm.fileExists(atPath: current) {
            missingTail.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
        var base = URL(fileURLWithPath: current.isEmpty ? "/" : current).resolvingSymlinksInPath().path
        for component in missingTail.reversed() {
            base = (base as NSString).appendingPathComponent(component)
        }
        return base
    }

    static func gitRelativePath(forAbsolutePath path: String, from directory: String) -> String {
        let baseCanon = canonicalizePath(directory)
        let fileCanon = canonicalizePath(path)
        guard !baseCanon.isEmpty, !fileCanon.isEmpty else { return "" }
        let baseComps = baseCanon.split(separator: "/").map(String.init)
        let fileComps = fileCanon.split(separator: "/").map(String.init)
        var common = 0
        while common < baseComps.count && common < fileComps.count && baseComps[common] == fileComps[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: baseComps.count - common)
        let down = Array(fileComps[common...])
        return (up + down).joined(separator: "/")
    }

    func isCommitDiffActive(for path: String) -> Bool {
        guard let ctx = git.activeCommitDiffContext, !ctx.relativePath.isEmpty else { return false }
        let fileCanon = Self.canonicalizePath(path)
        if let repoRoot = GitRefreshCoordinator.shared.locations[activeWorkspacePath]?.repoRoot {
            let expected = Self.repoAbsolutePath(repoRoot: repoRoot, relativePath: ctx.relativePath)
            return Self.canonicalizePath(expected) == fileCanon
        }
        return fileCanon == Self.canonicalizePath((activeWorkspacePath as NSString).appendingPathComponent(ctx.relativePath))
            || fileCanon.hasSuffix("/" + ctx.relativePath)
    }

    func hasStashUntrackedParent(for revision: String, in workspacePath: String) async -> Bool {
        guard (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--verify", "--quiet", "\(revision)^3"], in: workspacePath)) != nil else {
            return false
        }
        if revision.hasPrefix("stash@{") {
            return true
        }
        return (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--verify", "--quiet", "\(revision)^3^1"], in: workspacePath)) == nil
    }

    func getFullDiff(for path: String, fullContext: Bool = false, source: GitDiffSource = .unstaged) async -> String {
        let contextFlag = fullContext ? "-U99999" : "-U3"
        let (workspacePath, commitCtx, matchesCommitDiff): (String, (commit: GitCommitSummary, relativePath: String)?, Bool) = await MainActor.run {
            (self.activeWorkspacePath, self.git.activeCommitDiffContext, self.isCommitDiffActive(for: path))
        }
        let relPath = await workspaceRelativeGitPath(for: path, workspacePath: workspacePath)

        if let commitCtx, matchesCommitDiff {
            do {
                let targetPath = commitCtx.relativePath.isEmpty ? relPath : ":(top,literal)" + commitCtx.relativePath
                let output = try await runGitDiff(args: ["--no-optional-locks", "show", "--format=", "--diff-merges=first-parent", contextFlag, commitCtx.commit.hash, "--", targetPath], in: workspacePath)
                if output.isEmpty, await hasStashUntrackedParent(for: commitCtx.commit.hash, in: workspacePath) {
                    return try await runGitDiff(args: ["--no-optional-locks", "show", "--format=", contextFlag, "\(commitCtx.commit.hash)^3", "--", targetPath], in: workspacePath)
                }
                return output
            } catch {
                return GitDiffNotice.make("Couldn’t load diff: \(error.localizedDescription)")
            }
        }
        return await workingDiff(for: path, fullContext: fullContext, source: source, includeUnsavedEdits: true, detectRenames: true)
    }

    func workspaceRelativeGitPath(for path: String, workspacePath: String) async -> String {
        if let matched = await MainActor.run(body: { self.git.changedFiles.first(where: { $0.absolutePath == path }) }) {
            let fromWorkspace = Self.gitRelativePath(forAbsolutePath: matched.absolutePath, from: workspacePath)
            if !fromWorkspace.isEmpty { return fromWorkspace }
            return matched.relativePath
        }
        return Self.gitRelativePath(forAbsolutePath: path, from: workspacePath)
    }

    func repoRelativeGitPath(for path: String, workspacePath: String) async -> String {
        if let matched = await MainActor.run(body: { self.git.changedFiles.first(where: { $0.absolutePath == path && !$0.repoPath.isEmpty }) }) {
            return matched.repoPath
        }
        if let top = await gitRepoRoot(for: workspacePath), !top.isEmpty {
            let rel = Self.gitRelativePath(forAbsolutePath: path, from: top)
            if !rel.isEmpty && !rel.hasPrefix("../") { return rel }
        }
        return "./" + (await workspaceRelativeGitPath(for: path, workspacePath: workspacePath))
    }

    func isUntrackedPath(_ path: String) -> Bool {
        if git.statusMap[path] == "??" { return true }
        return GitRefreshCoordinator.shared.isInsideUntrackedDirectory(path)
    }

    func workingDiff(for path: String, fullContext: Bool, source: GitDiffSource, includeUnsavedEdits: Bool, detectRenames: Bool = false) async -> String {
        let contextFlag = fullContext ? "-U99999" : "-U3"
        let (workspacePath, isUntracked, isConflicted, inMemoryText, stagedRenameEntry): (String, Bool, Bool, String?, GitChangedFile?) = await MainActor.run {
            let entries = self.git.changedFiles.filter { $0.absolutePath == path }
            let session = includeUnsavedEdits ? self.documentSession(forPath: path) : nil
            let renameEntry = detectRenames ? entries.first(where: { $0.isStaged && ($0.status == "R" || $0.status == "C") }) : nil
            return (
                self.activeWorkspacePath,
                entries.contains { $0.status == "??" } || GitRefreshCoordinator.shared.isInsideUntrackedDirectory(path),
                entries.contains { $0.status == "U" } || self.git.conflictedPaths.contains(path),
                session?.isEdited == true ? session?.storage.string : nil,
                renameEntry
            )
        }
        let relPath = await workspaceRelativeGitPath(for: path, workspacePath: workspacePath)
        guard !relPath.isEmpty else { return "" }

        if source == .staged && !isConflicted {
            do {
                if let stagedRenameEntry {
                    var origRel: String?
                    if let origRepo = stagedRenameEntry.originalRepoPath, !origRepo.isEmpty,
                       let repoRoot = await gitRepoRoot(for: workspacePath) {
                        let origAbs = Self.repoAbsolutePath(repoRoot: Self.canonicalizePath(repoRoot), relativePath: origRepo)
                        let computed = Self.gitRelativePath(forAbsolutePath: origAbs, from: workspacePath)
                        if !computed.isEmpty {
                            origRel = computed
                        }
                    }
                    if origRel == nil, let fallback = stagedRenameEntry.originalPath, !fallback.isEmpty {
                        origRel = fallback
                    }
                    if let origRel, origRel != relPath {
                        let raw = try await runGitDiff(
                            args: ["--no-optional-locks", "--literal-pathspecs", "diff", "--cached", "-M", "-C", contextFlag, "--no-color", "--no-ext-diff", "--", origRel, relPath],
                            in: workspacePath
                        )
                        let destRepo = stagedRenameEntry.repoPath.isEmpty
                            ? await repoRelativeGitPath(for: path, workspacePath: workspacePath)
                            : stagedRenameEntry.repoPath
                        return Self.extractSingleFileDiffSection(from: raw, targetRepoPath: destRepo)
                    }
                }
                return try await runGitDiff(args: ["--no-optional-locks", "--literal-pathspecs", "diff", "--cached", contextFlag] + Self.gitPatchDiffFlags + ["--", relPath], in: workspacePath)
            } catch {
                return GitDiffNotice.make("Couldn’t load diff: \(error.localizedDescription)")
            }
        }

        if isUntracked {
            if let inMemoryText {
                return await diffTexts(old: nil, new: inMemoryText, contextFlag: contextFlag, in: workspacePath)
            }
            if let notice = await Task.detached(priority: .userInitiated, operation: { GitDiffNotice.untrackedNotice(forPath: path) }).value {
                return notice
            }
            return await noIndexDiff(["/dev/null", relPath], contextFlag: contextFlag, in: workspacePath)
        }

        if let inMemoryText {
            let repoRel = await repoRelativeGitPath(for: path, workspacePath: workspacePath)
            let showSpec = isConflicted ? "HEAD:\(repoRel)" : ":\(repoRel)"
            if let base = try? await runGitCommand(args: ["--no-optional-locks", "show", showSpec], in: workspacePath, maxOutputBytes: GitCommandRunner.diffMaxOutputBytes),
               base.exitCode == 0, !base.isTruncated {
                if base.output == inMemoryText {
                    return ""
                }
                let output = await diffTexts(old: base.output, new: inMemoryText, contextFlag: contextFlag, in: workspacePath)
                if !output.isEmpty {
                    return output
                }
            }
        }

        do {
            let args = isConflicted
                ? ["--no-optional-locks", "--literal-pathspecs", "diff-index", "-p", contextFlag] + Self.gitPatchDiffFlags + ["HEAD", "--", relPath]
                : ["--no-optional-locks", "--literal-pathspecs", "diff-files", "-p", contextFlag] + Self.gitPatchDiffFlags + ["--", relPath]
            return try await runGitDiff(args: args, in: workspacePath)
        } catch {
            return GitDiffNotice.make("Couldn’t load diff: \(error.localizedDescription)")
        }
    }

    private static func extractSingleFileDiffSection(from raw: String, targetRepoPath: String) -> String {
        guard !raw.isEmpty, !GitDiffNotice.marker.isEmpty, GitDiffNotice.message(in: raw) == nil else { return raw }
        let parts = raw.components(separatedBy: "\ndiff --git ")
        guard parts.count > 1 else { return raw }
        let sections = parts.enumerated().map { idx, chunk in
            idx == 0 ? chunk : "diff --git " + chunk
        }
        let quotedTarget = GitPatchBuilder.quotedPath(targetRepoPath)
        let quotedB = GitPatchBuilder.quotedPath("b/" + targetRepoPath)
        for section in sections {
            let headerEnd = section.range(of: "\n@@ ")?.lowerBound ?? section.endIndex
            let headerLines = section[..<headerEnd].split(whereSeparator: \.isNewline).map(String.init)
            if headerLines.contains("rename to \(targetRepoPath)")
                || headerLines.contains("rename to \(quotedTarget)")
                || headerLines.contains("copy to \(targetRepoPath)")
                || headerLines.contains("copy to \(quotedTarget)")
                || headerLines.contains("+++ b/\(targetRepoPath)")
                || headerLines.contains("+++ \(quotedB)")
                || headerLines.first?.hasSuffix(" \(quotedB)") == true
                || headerLines.first?.hasSuffix(" b/\(targetRepoPath)") == true {
                return section.hasSuffix("\n") ? section : section + "\n"
            }
        }
        return sections[0]
    }

    func untrackedFolderSummary(for path: String) async -> String {
        let workspacePath = await MainActor.run { self.activeWorkspacePath }
        let relPath = await workspaceRelativeGitPath(for: path, workspacePath: workspacePath)
        let folder = relPath.hasSuffix("/") ? relPath : relPath + "/"
        guard let result = try? await runGitCommand(args: ["--no-optional-locks", "--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--", folder], in: workspacePath, maxOutputBytes: 1 << 20),
              result.exitCode == 0 else {
            return GitDiffNotice.untrackedFolder
        }
        let count = result.output.utf8.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        let shown = result.isTruncated ? "More than \(count) files" : (count == 1 ? "1 file" : "\(count) files")
        return GitDiffNotice.make("Untracked folder with \(shown). Stage the folder to add everything inside.")
    }

    func runGitDiff(args: [String], in workspacePath: String) async throws -> String {
        let result = try await runGitCommand(args: args, in: workspacePath, maxOutputBytes: GitCommandRunner.diffMaxOutputBytes)
        if result.isTruncated {
            return GitDiffNotice.tooLargeDiff
        }
        return try Self.gitOutput(result)
    }

    func diffTexts(old: String?, new: String, contextFlag: String, in workspacePath: String) async -> String {
        let useHostTemp = await MainActor.run { SandboxVMManager.shared.executionMode == .host }
        let scratch = Self.diffScratchLocation(in: workspacePath, preferTemporaryDirectory: useHostTemp)
        let token = UUID().uuidString
        let oldName = "golens-diff-old-\(token)"
        let newName = "golens-diff-new-\(token)"
        let oldURL = scratch.directory.appendingPathComponent(oldName)
        let newURL = scratch.directory.appendingPathComponent(newName)
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }
        do {
            if let old {
                try old.write(to: oldURL, atomically: false, encoding: .utf8)
            }
            try new.write(to: newURL, atomically: false, encoding: .utf8)
        } catch {
            return GitDiffNotice.make("Couldn’t compare changes: \(error.localizedDescription)")
        }
        let oldArg = old == nil ? "/dev/null" : scratch.argumentPrefix + oldName
        return await noIndexDiff([oldArg, scratch.argumentPrefix + newName], contextFlag: contextFlag, in: workspacePath)
    }

    static func diffScratchLocation(in workspacePath: String, preferTemporaryDirectory: Bool = true) -> (directory: URL, argumentPrefix: String) {
        if !preferTemporaryDirectory {
            let gitDir = URL(fileURLWithPath: workspacePath).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return (gitDir, ".git/")
            }
        }
        let tmp = FileManager.default.temporaryDirectory
        return (tmp, tmp.path.hasSuffix("/") ? tmp.path : tmp.path + "/")
    }

    func noIndexDiff(_ paths: [String], contextFlag: String, in workspacePath: String) async -> String {
        let args = ["--no-optional-locks", "diff", "--no-index", contextFlag, "--no-color", "--no-ext-diff", "--"] + paths
        do {
            let result = try await runGitCommand(args: args, in: workspacePath, maxOutputBytes: GitCommandRunner.diffMaxOutputBytes)
            if result.isTruncated {
                return GitDiffNotice.tooLargeDiff
            }
            if result.exitCode == 0 || result.exitCode == 1 {
                return result.output
            }
            _ = try Self.gitOutput(result)
            return ""
        } catch {
            return GitDiffNotice.make("Couldn’t load diff: \(error.localizedDescription)")
        }
    }

    func refreshActiveFileDiff() {
        activeFileDiffTask?.cancel()

        let workspacePath = activeWorkspacePath
        guard !activeFilePath.isEmpty, !workspacePath.isEmpty else {
            DispatchQueue.main.async {
                self.git.activeFileDiffs = [:]
            }
            return
        }

        let path = activeFilePath
        let relPath = Self.gitRelativePath(forAbsolutePath: path, from: workspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            DispatchQueue.main.async {
                self.git.activeFileDiffs = [:]
            }
            return
        }

        let isUntracked = isUntrackedPath(path)
        let untrackedLineCount = max(1, activeFileLineCount)

        activeFileDiffTask = Task {
            if Task.isCancelled { return }

            let dotGitExists = FileManager.default.fileExists(atPath: (workspacePath as NSString).appendingPathComponent(".git"))
            let isInsideWorkTree: Bool
            if dotGitExists {
                isInsideWorkTree = true
            } else if self.git.isRepository == false {
                isInsideWorkTree = false
            } else if self.git.isRepository == true {
                isInsideWorkTree = true
            } else {
                isInsideWorkTree = (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--is-inside-work-tree"], in: workspacePath)) != nil
            }

            guard isInsideWorkTree else {
                await MainActor.run {
                    if self.activeFilePath == path {
                        self.git.activeFileDiffs = [:]
                        self.activeTextView?.needsDisplay = true
                    }
                }
                return
            }

            if Task.isCancelled { return }

            if isUntracked {
                var diffs: [Int: GitLineDiffType] = [:]
                for l in 1...untrackedLineCount {
                    diffs[l] = .added
                }
                if Task.isCancelled { return }
                let untrackedDiffs = diffs
                await MainActor.run {
                    if self.activeFilePath == path {
                        self.git.activeFileDiffs = untrackedDiffs
                        self.activeTextView?.needsDisplay = true
                    }
                }
                return
            }

            var diffOutputOpt: String?
            for attempt in 0..<3 {
                do {
                    diffOutputOpt = try await unifiedZeroDiffOutput(forPath: path, relPath: relPath, in: workspacePath)
                    break
                } catch {
                    if Task.isCancelled { return }
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 250_000_000)
                    }
                }
            }
            guard let diffOutput = diffOutputOpt else {
                if Task.isCancelled { return }
                await MainActor.run {
                    if self.activeFilePath == path {
                        self.git.activeFileDiffs = [:]
                        self.activeTextView?.needsDisplay = true
                    }
                }
                return
            }

            if Task.isCancelled { return }

            var diffs: [Int: GitLineDiffType] = [:]
            for hunk in parseGitHunks(fromUnifiedDiff: diffOutput) {
                if Task.isCancelled { return }
                if hunk.newCount == 0 && hunk.oldCount > 0 {
                    diffs[max(1, hunk.newStart)] = .deleted
                } else if hunk.newCount > 0 && hunk.oldCount == 0 {
                    for l in hunk.newStart..<(hunk.newStart + hunk.newCount) {
                        diffs[l] = .added
                    }
                } else if hunk.newCount > 0 && hunk.oldCount > 0 {
                    for l in hunk.newStart..<(hunk.newStart + hunk.newCount) {
                        diffs[l] = .modified
                    }
                }
            }

            if Task.isCancelled { return }
            let finalDiffs = diffs
            await MainActor.run {
                if self.activeFilePath == path {
                    self.git.activeFileDiffs = finalDiffs
                    self.activeTextView?.needsDisplay = true
                }
            }
        }
    }

    @MainActor
    func selectGitCommit(_ commit: GitCommitSummary?) {
        transientEditorState.commitDetailTask?.cancel()
        if let commit, git.selectedCommit?.hash == commit.hash {
            git.selectedCommit = nil
            git.selectedCommitBody = ""
            git.selectedCommitFiles = []
            git.isLoadingSelectedCommit = false
            return
        }
        git.selectedCommit = commit
        git.selectedCommitBody = ""
        git.selectedCommitFiles = []
        guard let commit else {
            git.isLoadingSelectedCommit = false
            return
        }
        git.isLoadingSelectedCommit = true
        let workspacePath = activeWorkspacePath
        transientEditorState.commitDetailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bodyOut = try await self.runGit(args: ["--no-optional-locks", "show", "-s", "--format=%b", commit.hash], in: workspacePath)
                if Task.isCancelled { return }
                let statusOut = try await self.runGit(args: ["--no-optional-locks", "show", "--name-status", "-z", "-M", "--diff-merges=first-parent", "--format=", commit.hash], in: workspacePath)
                if Task.isCancelled { return }
                let numstatOut = try await self.runGit(args: ["--no-optional-locks", "show", "--numstat", "-z", "-M", "--diff-merges=first-parent", "--format=", commit.hash], in: workspacePath)
                if Task.isCancelled { return }

                var stats = GitStatusParser.numstat(numstatOut)
                let repoRoot = await self.gitRepoRoot(for: workspacePath) ?? workspacePath
                let canonRoot = Self.canonicalizePath(repoRoot)
                var files = GitStatusParser.nameStatus(statusOut).map { change in
                    GitCommitFileChange(
                        commitHash: commit.hash,
                        relativePath: change.path,
                        absolutePath: Self.repoAbsolutePath(repoRoot: canonRoot, relativePath: change.path),
                        status: change.status,
                        added: stats[change.path]?.added ?? 0,
                        removed: stats[change.path]?.removed ?? 0
                    )
                }
                if await self.hasStashUntrackedParent(for: commit.hash, in: workspacePath) {
                    let p3Status = try await self.runGit(args: ["--no-optional-locks", "show", "--name-status", "-z", "--format=", "\(commit.hash)^3"], in: workspacePath)
                    let p3Numstat = try await self.runGit(args: ["--no-optional-locks", "show", "--numstat", "-z", "--format=", "\(commit.hash)^3"], in: workspacePath)
                    if Task.isCancelled { return }
                    let p3Stats = GitStatusParser.numstat(p3Numstat)
                    for (k, v) in p3Stats where stats[k] == nil { stats[k] = v }
                    let existingPaths = Set(files.map(\.relativePath))
                    for change in GitStatusParser.nameStatus(p3Status) where !existingPaths.contains(change.path) {
                        files.append(GitCommitFileChange(
                            commitHash: commit.hash,
                            relativePath: change.path,
                            absolutePath: Self.repoAbsolutePath(repoRoot: canonRoot, relativePath: change.path),
                            status: "A",
                            added: stats[change.path]?.added ?? 0,
                            removed: stats[change.path]?.removed ?? 0
                        ))
                    }
                }

                if self.git.selectedCommit?.hash == commit.hash {
                    self.git.selectedCommitBody = bodyOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.git.selectedCommitFiles = files
                    self.git.isLoadingSelectedCommit = false
                }
            } catch {
                if Task.isCancelled { return }
                if self.git.selectedCommit?.hash == commit.hash {
                    self.git.isLoadingSelectedCommit = false
                    self.git.selectedCommit = nil
                    let recovery = self.gitRecovery(for: error) {
                        self.selectGitCommit(commit)
                    }
                    self.presentGitAlert("Couldn’t Load Commit “\(commit.shortHash)”", Self.failureReason(error), recovery: recovery)
                }
            }
        }
    }

    @MainActor
    func openCommitFileDiff(_ fileChange: GitCommitFileChange, commit: GitCommitSummary) {
        git.commitDiffReturnHistory = nil
        git.activeCommitDiffContext = (commit: commit, relativePath: fileChange.relativePath)
        openFileInDiff(fileChange.absolutePath)
    }

    @MainActor
    func clearCommitDiffContext() {
        git.activeCommitDiffContext = nil
        git.commitDiffReturnHistory = nil
    }

    @MainActor
    func returnFromCommitDiffToHistory() {
        let target = git.commitDiffReturnHistory ?? GitHistoryTarget(
            revision: "HEAD",
            title: hasNamedBranch ? git.branchName : "HEAD",
            isSingleCommit: false
        )
        clearCommitDiffContext()
        if repositories.historyTarget == target, !repositories.commits.isEmpty {
            sourceControl.editorSurface = .history
        } else {
            showHistory(target)
        }
    }
}
