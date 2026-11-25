import AppKit
import Foundation

extension WorkspaceState {
    func runGitAction(_ failureTitle: String, preferredPath: String? = nil, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
            } catch {
                let recovery = self.gitRecovery(for: error, preferredPath: preferredPath) {
                    self.runGitAction(failureTitle, preferredPath: preferredPath, body)
                }
                self.presentGitAlert(failureTitle, Self.failureReason(error), recovery: recovery)
            }
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
        }
    }

    @MainActor
    func saveAllEditedFilesInWorkspace() async -> Bool {
        let workspaceCanon = Self.canonicalizePath(activeWorkspacePath)
        guard !workspaceCanon.isEmpty else { return true }
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()
        (primaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        (secondaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        for (path, session) in documents where session.isEdited {
            let fileCanon = Self.canonicalizePath(path)
            guard fileCanon == workspaceCanon || fileCanon.hasPrefix(workspaceCanon + "/") else { continue }
            let saved = await withCheckedContinuation { continuation in
                save(session) { ok in continuation.resume(returning: ok) }
            }
            if !saved {
                return false
            }
        }
        return true
    }

    private func validatedRepoRelativePath(for path: String, actionVerb: String) -> String? {
        let workspacePath = activeWorkspacePath
        let name = path.isEmpty ? "File" : (path as NSString).lastPathComponent
        guard !path.isEmpty, !workspacePath.isEmpty else {
            let title = path.isEmpty ? "Couldn’t \(actionVerb) File" : "Couldn’t \(actionVerb) “\(name)”"
            Task { @MainActor in
                self.presentGitAlert(title, "Open a Git repository folder first.")
            }
            return nil
        }
        let relPath = Self.gitRelativePath(forAbsolutePath: path, from: workspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            Task { @MainActor in
                self.presentGitAlert("Couldn’t \(actionVerb) “\(name)”", "“\(name)” isn’t inside the active repository.")
            }
            return nil
        }
        return relPath
    }

    func stageFile(_ path: String) {
        let workspacePath = activeWorkspacePath
        guard let relPath = validatedRepoRelativePath(for: path, actionVerb: "Stage") else { return }
        let name = (path as NSString).lastPathComponent
        let canon = Self.canonicalizePath(path)
        runGitAction("Couldn’t Stage “\(name)”", preferredPath: path) {
            if self.git.conflictedPaths.contains(path)
                || self.git.conflictedPaths.contains(canon)
                || self.git.changedFiles.contains(where: { ($0.absolutePath == path || $0.absolutePath == canon) && $0.status == "U" }) {
                throw MergeConflictError(message: "Resolve merge conflicts in “\(name)” before staging it.")
            }
            guard await self.saveBeforeStaging(path) else {
                throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn’t save “\(name)” before staging."
                ])
            }
            _ = try await self.runGit(args: ["--literal-pathspecs", "add", "-A", "--", relPath], in: workspacePath)
        }
    }

    func unstageFile(_ path: String) {
        let workspacePath = activeWorkspacePath
        guard let relPath = validatedRepoRelativePath(for: path, actionVerb: "Unstage") else { return }
        let name = (path as NSString).lastPathComponent
        runGitAction("Couldn’t Unstage “\(name)”", preferredPath: path) {
            let entry = self.git.changedFiles.first(where: { $0.absolutePath == path && $0.isStaged })
            let status = entry?.status
            let hasHead = await self.hasGitHead(in: workspacePath)
            var pathsToReset = [relPath]
            if let origRepo = entry?.originalRepoPath, !origRepo.isEmpty,
               let repoRoot = await self.gitRepoRoot(for: workspacePath) {
                let origAbs = Self.repoAbsolutePath(repoRoot: Self.canonicalizePath(repoRoot), relativePath: origRepo)
                let origRel = Self.gitRelativePath(forAbsolutePath: origAbs, from: workspacePath)
                if !origRel.isEmpty && !pathsToReset.contains(origRel) {
                    pathsToReset.append(origRel)
                }
            } else if let origRel = entry?.originalPath, !origRel.isEmpty, !pathsToReset.contains(origRel) {
                pathsToReset.append(origRel)
            }

            if status == "A" || status == "C" || !hasHead {
                _ = try await self.runGit(args: ["--literal-pathspecs", "rm", "-r", "--cached", "-q", "--ignore-unmatch", "--"] + pathsToReset, in: workspacePath)
            } else {
                _ = try await self.runGit(args: ["--literal-pathspecs", "reset", "-q", "HEAD", "--"] + pathsToReset, in: workspacePath)
            }
        }
    }

    func stageAllFiles() {
        let workspacePath = activeWorkspacePath
        runGitAction("Couldn’t Stage All Changes") {
            guard await self.saveAllEditedFilesInWorkspace() else {
                throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Save all modified files before staging all changes."
                ])
            }
            try await self.stageAllNonConflictedFiles(in: workspacePath)
        }
    }

    @MainActor
    func stageAllNonConflictedFiles(in workspacePath: String) async throws {
        let statusOut = try await runGit(args: ["--no-optional-locks", "status", "--porcelain=v2", "-z", "--untracked-files=all", "--", "."], in: workspacePath)
        let snapshot = GitStatusParser.parse(statusOut)
        if !snapshot.entries.contains(where: \.isUnmerged) && git.conflictedPaths.isEmpty {
            guard snapshot.entries.contains(where: { $0.isUntracked || $0.y != " " }) else { return }
            _ = try await runGit(args: ["add", "-A", "--", "."], in: workspacePath)
            return
        }
        let repoRoot = Self.canonicalizePath(await gitRepoRoot(for: workspacePath) ?? workspacePath)
        var relPaths: [String] = []
        for entry in snapshot.entries where !entry.isUnmerged && (entry.isUntracked || entry.y != " ") {
            let absPath = Self.repoAbsolutePath(repoRoot: repoRoot, relativePath: entry.path)
            guard !git.conflictedPaths.contains(absPath) else { continue }
            let rel = Self.gitRelativePath(forAbsolutePath: absPath, from: workspacePath)
            if !rel.isEmpty && !rel.hasPrefix("../") {
                relPaths.append(rel)
            }
        }
        guard !relPaths.isEmpty else {
            presentCommandFeedback("Resolve the remaining merge conflicts before staging them.", title: "Nothing Else to Stage")
            return
        }
        let input = Data((relPaths.joined(separator: "\0") + "\0").utf8)
        _ = try await runGit(args: ["--literal-pathspecs", "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], in: workspacePath, input: input)
    }

    func unstageAllFiles() {
        let workspacePath = activeWorkspacePath
        runGitAction("Couldn’t Unstage All Changes") {
            if await self.hasGitHead(in: workspacePath) {
                _ = try await self.runGit(args: ["reset", "-q", "HEAD", "--", "."], in: workspacePath)
            } else {
                _ = try await self.runGit(args: ["rm", "-r", "--cached", "-q", "--ignore-unmatch", "--", "."], in: workspacePath)
            }
        }
    }

    func gitDiscardAllChanges() async throws {
        if let op = await MainActor.run(body: { self.git.mergeOperation }) {
            throw MergeConflictError(message: "A \(op.title.lowercased()) is in progress. Use Abort \(op.title) in the Source Control navigator to return to how things were.")
        }
        let workspacePath = await MainActor.run { self.activeWorkspacePath }
        let (filesToDiscard, extraEditedPaths) = await MainActor.run {
            (self.git.changedFiles, self.editedWorkspacePathsNotInGit)
        }
        await MainActor.run {
            var recorded = Set<String>()
            for file in filesToDiscard where recorded.insert(file.absolutePath).inserted {
                self.recordLocalHistoryBeforeDiscard(for: file.absolutePath)
            }
            for path in extraEditedPaths where recorded.insert(path).inserted {
                self.recordLocalHistoryBeforeDiscard(for: path)
            }
        }
        let hasHead = await hasGitHead(in: workspacePath)
        let repoRoot = Self.canonicalizePath(await gitRepoRoot(for: workspacePath) ?? workspacePath)
        var failures: [String] = []
        var trashedAbsolutePaths = Set<String>()
        var handledPaths = Set<String>()

        for file in filesToDiscard where (file.status == "??" || file.status == "A" || file.status == "C" || file.status == "R") && !handledPaths.contains(file.absolutePath) {
            handledPaths.insert(file.absolutePath)
            let relPath = Self.gitRelativePath(forAbsolutePath: file.absolutePath, from: workspacePath)
            do {
                if file.status == "R" {
                    var resetTargets = [relPath]
                    var origRel: String?
                    if let origRepo = file.originalRepoPath, !origRepo.isEmpty {
                        let origAbs = Self.repoAbsolutePath(repoRoot: repoRoot, relativePath: origRepo)
                        let computed = Self.gitRelativePath(forAbsolutePath: origAbs, from: workspacePath)
                        if !computed.isEmpty {
                            origRel = computed
                            resetTargets.append(computed)
                        }
                    } else if let fallbackOrig = file.originalPath, !fallbackOrig.isEmpty {
                        origRel = fallbackOrig
                        resetTargets.append(fallbackOrig)
                    }
                    if hasHead {
                        _ = try await runGit(args: ["--literal-pathspecs", "reset", "-q", "HEAD", "--"] + resetTargets, in: workspacePath)
                    } else {
                        _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--cached", "-q", "--ignore-unmatch", "--"] + resetTargets, in: workspacePath)
                    }
                    let destExistedInHead: Bool
                    if hasHead {
                        destExistedInHead = (try? await runGit(args: ["--no-optional-locks", "cat-file", "-e", "HEAD:\(file.repoPath.isEmpty ? relPath : file.repoPath)"], in: workspacePath)) != nil
                    } else {
                        destExistedInHead = false
                    }
                    if destExistedInHead {
                        _ = try await runGit(args: ["--literal-pathspecs", "checkout", "HEAD", "--", relPath], in: workspacePath)
                    } else if FileManager.default.fileExists(atPath: file.absolutePath) {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: file.absolutePath), resultingItemURL: nil)
                        trashedAbsolutePaths.insert(file.absolutePath)
                    }
                    if hasHead, let origRel {
                        _ = try await runGit(args: ["--literal-pathspecs", "checkout", "HEAD", "--", origRel], in: workspacePath)
                    }
                } else {
                    if file.status == "A" || file.status == "C" {
                        _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--cached", "-q", "--ignore-unmatch", "--", relPath], in: workspacePath)
                    }
                    if FileManager.default.fileExists(atPath: file.absolutePath) {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: file.absolutePath), resultingItemURL: nil)
                    }
                    trashedAbsolutePaths.insert(file.absolutePath)
                }
            } catch {
                failures.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }

        if filesToDiscard.contains(where: { !handledPaths.contains($0.absolutePath) && !["??", "A", "C", "R", "U"].contains($0.status) }) {
            do {
                if hasHead {
                    _ = try await runGit(args: ["reset", "-q", "HEAD", "--", "."], in: workspacePath)
                    _ = try await runGit(args: ["checkout", "HEAD", "--", "."], in: workspacePath)
                } else {
                    _ = try await runGit(args: ["rm", "-rf", "--cached", "-q", "--ignore-unmatch", "--", "."], in: workspacePath)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        await MainActor.run {
            let workspaceCanon = Self.canonicalizePath(workspacePath)
            for trashed in trashedAbsolutePaths where self.openFiles.contains(trashed) {
                if let session = self.documents[trashed] {
                    session.savedVersion = session.version
                }
                self.editedFiles.remove(trashed)
                self.closeTab(trashed)
            }
            for openPath in self.openFiles {
                let canon = Self.canonicalizePath(openPath)
                guard !workspaceCanon.isEmpty, canon == workspaceCanon || canon.hasPrefix(workspaceCanon + "/") else { continue }
                if FileManager.default.fileExists(atPath: openPath) {
                    self.revertToDiskVersion(openPath)
                } else {
                    if let session = self.documents[openPath] {
                        session.savedVersion = session.version
                    }
                    self.editedFiles.remove(openPath)
                    self.closeTab(openPath)
                }
            }
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
        if !failures.isEmpty {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
    }

    func gitDiscardFileChanges(_ file: GitChangedFile) async throws {
        let isConflicted = await MainActor.run {
            file.status == "U" || self.git.conflictedPaths.contains(file.absolutePath)
        }
        if isConflicted {
            throw MergeConflictError(message: "Resolve or abort the merge conflict instead of discarding changes.")
        }
        let workspacePath = await MainActor.run { self.activeWorkspacePath }
        await MainActor.run {
            self.recordLocalHistoryBeforeDiscard(for: file.absolutePath)
        }
        let relPath = Self.gitRelativePath(forAbsolutePath: file.absolutePath, from: workspacePath)
        let hasHead = await hasGitHead(in: workspacePath)

        if file.status == "??" {
            if FileManager.default.fileExists(atPath: file.absolutePath) {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.absolutePath), resultingItemURL: nil)
            }
            await MainActor.run {
                if self.openFiles.contains(file.absolutePath) {
                    if let session = self.documents[file.absolutePath] {
                        session.savedVersion = session.version
                    }
                    self.editedFiles.remove(file.absolutePath)
                    self.closeTab(file.absolutePath)
                }
            }
        } else if file.status == "A" || file.status == "C" {
            _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--cached", "-q", "--ignore-unmatch", "--", relPath], in: workspacePath)
            if FileManager.default.fileExists(atPath: file.absolutePath) {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.absolutePath), resultingItemURL: nil)
            }
            await MainActor.run {
                if self.openFiles.contains(file.absolutePath) {
                    if let session = self.documents[file.absolutePath] {
                        session.savedVersion = session.version
                    }
                    self.editedFiles.remove(file.absolutePath)
                    self.closeTab(file.absolutePath)
                }
            }
        } else if file.status == "R" {
            let repoRoot = Self.canonicalizePath(await gitRepoRoot(for: workspacePath) ?? workspacePath)
            var resetTargets = [relPath]
            var origRel: String?
            var origAbs: String?
            if let origRepo = file.originalRepoPath, !origRepo.isEmpty {
                let abs = Self.repoAbsolutePath(repoRoot: repoRoot, relativePath: origRepo)
                origAbs = abs
                let computed = Self.gitRelativePath(forAbsolutePath: abs, from: workspacePath)
                if !computed.isEmpty {
                    origRel = computed
                    resetTargets.append(computed)
                }
            } else if let fallbackOrig = file.originalPath, !fallbackOrig.isEmpty {
                origRel = fallbackOrig
                origAbs = Self.canonicalizePath((workspacePath as NSString).appendingPathComponent(fallbackOrig))
                resetTargets.append(fallbackOrig)
            }

            if hasHead {
                _ = try await runGit(args: ["--literal-pathspecs", "reset", "-q", "HEAD", "--"] + resetTargets, in: workspacePath)
            } else {
                _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--cached", "-q", "--ignore-unmatch", "--"] + resetTargets, in: workspacePath)
            }

            let destRepoPath = file.repoPath.isEmpty ? relPath : file.repoPath
            let destExistedInHead: Bool
            if hasHead {
                destExistedInHead = (try? await runGit(args: ["--no-optional-locks", "cat-file", "-e", "HEAD:\(destRepoPath)"], in: workspacePath)) != nil
            } else {
                destExistedInHead = false
            }
            if destExistedInHead {
                _ = try await runGit(args: ["--literal-pathspecs", "checkout", "HEAD", "--", relPath], in: workspacePath)
                await MainActor.run { self.revertToDiskVersion(file.absolutePath) }
            } else {
                if FileManager.default.fileExists(atPath: file.absolutePath) {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: file.absolutePath), resultingItemURL: nil)
                }
                await MainActor.run {
                    if self.openFiles.contains(file.absolutePath) {
                        if let session = self.documents[file.absolutePath] {
                            session.savedVersion = session.version
                        }
                        self.editedFiles.remove(file.absolutePath)
                        self.closeTab(file.absolutePath)
                    }
                }
            }

            if hasHead, let origRel {
                _ = try await runGit(args: ["--literal-pathspecs", "checkout", "HEAD", "--", origRel], in: workspacePath)
                if let origAbs {
                    await MainActor.run {
                        if self.openFiles.contains(origAbs) {
                            self.revertToDiskVersion(origAbs)
                        }
                    }
                }
            }
        } else if file.isStaged {
            if hasHead {
                _ = try await runGit(args: ["--literal-pathspecs", "reset", "-q", "HEAD", "--", relPath], in: workspacePath)
                _ = try await runGit(args: ["--literal-pathspecs", "checkout", "HEAD", "--", relPath], in: workspacePath)
            } else {
                _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--cached", "-q", "--ignore-unmatch", "--", relPath], in: workspacePath)
            }
            await MainActor.run {
                if FileManager.default.fileExists(atPath: file.absolutePath) {
                    self.revertToDiskVersion(file.absolutePath)
                }
            }
        } else {
            _ = try await runGit(args: ["--literal-pathspecs", "checkout", "--", relPath], in: workspacePath)
            await MainActor.run {
                if FileManager.default.fileExists(atPath: file.absolutePath) {
                    self.revertToDiskVersion(file.absolutePath)
                }
            }
        }

        await MainActor.run {
            self.refreshGitStatus()
            self.refreshActiveFileDiff()
            self.updateCaretLineBlame()
        }
    }

    func unifiedZeroDiffOutput(forPath path: String, relPath: String, in workspacePath: String) async throws -> String {
        let (inMemoryText, isConflicted): (String?, Bool) = await MainActor.run {
            let session = self.documentSession(forPath: path)
            return (session?.isEdited == true ? session?.storage.string : nil, self.git.statusMap[path] == "U")
        }
        let diffArgs = isConflicted
            ? ["--no-optional-locks", "--literal-pathspecs", "diff-index", "-p", "-U0", "--no-color", "--no-ext-diff", "HEAD", "--", relPath]
            : ["--no-optional-locks", "--literal-pathspecs", "diff-files", "-p", "-U0", "--no-color", "--no-ext-diff", "--", relPath]
        if let inMemoryText {
            let repoRel = await repoRelativeGitPath(for: path, workspacePath: workspacePath)
            let showSpec = isConflicted ? "HEAD:\(repoRel)" : ":\(repoRel)"
            let base = try await runGitCommand(args: ["--no-optional-locks", "show", showSpec], in: workspacePath, maxOutputBytes: GitCommandRunner.diffMaxOutputBytes)
            if base.exitCode == 0, !base.isTruncated {
                if base.output == inMemoryText {
                    return ""
                }
                return await diffTexts(old: base.output, new: inMemoryText, contextFlag: "-U0", in: workspacePath)
            }
        }
        let result = try await runGitCommand(args: diffArgs, in: workspacePath, maxOutputBytes: GitCommandRunner.diffMaxOutputBytes)
        return result.isTruncated ? "" : try Self.gitOutput(result)
    }

    func parseGitHunks(fromUnifiedDiff diffOutput: String) -> [GitDiffHunk] {
        enum LastDiffLineKind {
            case none, removed, added, context
        }
        var hunks: [GitDiffHunk] = []
        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String)?
        var removed: [String] = []
        var added: [String] = []
        var oldHasTrailingNewline = true
        var newHasTrailingNewline = true
        var lastKind: LastDiffLineKind = .none

        func flushCurrent() {
            guard let cur = currentHeader else { return }
            hunks.append(GitDiffHunk(
                oldStart: cur.oldStart,
                oldCount: cur.oldCount,
                newStart: cur.newStart,
                newCount: cur.newCount,
                removedLines: removed,
                addedLines: added,
                header: cur.header,
                oldHasTrailingNewline: oldHasTrailingNewline,
                newHasTrailingNewline: newHasTrailingNewline
            ))
            currentHeader = nil
            removed = []
            added = []
            oldHasTrailingNewline = true
            newHasTrailingNewline = true
            lastKind = .none
        }

        let rawLines = diffOutput.components(separatedBy: "\n")
        for rawLine in rawLines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("diff --git ") {
                flushCurrent()
                continue
            }
            if line.hasPrefix("@@") {
                flushCurrent()
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 4 else { continue }
                let oldPart = parts[1].replacingOccurrences(of: "-", with: "")
                let newPart = parts[2].replacingOccurrences(of: "+", with: "")
                let oldRange = oldPart.components(separatedBy: ",")
                let newRange = newPart.components(separatedBy: ",")
                let oldStart = Int(oldRange[0]) ?? 0
                let oldCount = oldRange.count > 1 ? (Int(oldRange[1]) ?? 1) : 1
                let newStart = Int(newRange[0]) ?? 0
                let newCount = newRange.count > 1 ? (Int(newRange[1]) ?? 1) : 1
                currentHeader = (oldStart, oldCount, newStart, newCount, line)
                continue
            }
            guard currentHeader != nil else { continue }
            if line.hasPrefix("\\") {
                switch lastKind {
                case .removed:
                    oldHasTrailingNewline = false
                case .added:
                    newHasTrailingNewline = false
                case .context:
                    oldHasTrailingNewline = false
                    newHasTrailingNewline = false
                case .none:
                    break
                }
                continue
            }
            if line.hasPrefix("-") {
                removed.append(String(line.dropFirst()))
                lastKind = .removed
            } else if line.hasPrefix("+") {
                added.append(String(line.dropFirst()))
                lastKind = .added
            } else if line.hasPrefix(" ") {
                lastKind = .context
            }
        }
        flushCurrent()
        return hunks
    }

    func fetchGitHunk(forPath path: String, atLine line: Int) async -> GitDiffHunk? {
        try? await loadGitHunk(forPath: path, atLine: line)
    }

    func loadGitHunk(forPath path: String, atLine line: Int) async throws -> GitDiffHunk? {
        let workspacePath = activeWorkspacePath
        guard !workspacePath.isEmpty, !path.isEmpty else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Open a file inside a Git repository first."])
        }
        let relPath = Self.gitRelativePath(forAbsolutePath: path, from: workspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "“\((path as NSString).lastPathComponent)” isn’t inside the active repository."])
        }

        let diffOutput = try await unifiedZeroDiffOutput(forPath: path, relPath: relPath, in: workspacePath)
        if let notice = GitDiffNotice.message(in: diffOutput) {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: notice])
        }
        let hunks = parseGitHunks(fromUnifiedDiff: diffOutput)
        if let exact = hunks.first(where: { $0.contains(line1Based: line) }) {
            return exact
        }
        return hunks.first(where: { $0.newCount == 0 && line == $0.newStart + 1 })
    }

    @MainActor
    func revertGitHunkAtLine(_ line: Int, inPath path: String) {
        let targetLine = max(1, line)
        let targetPath = path.isEmpty ? activeFilePath : path
        guard !targetPath.isEmpty else {
            presentCommandFeedback("Open a file in the repository to discard a change.", title: "Discard Change Unavailable")
            return
        }
        let name = (targetPath as NSString).lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let hunk = try await self.loadGitHunk(forPath: targetPath, atLine: targetLine) else {
                    self.presentCommandFeedback("There’s no unstaged change on line \(targetLine) of “\(name)”.", title: "No Change on Line")
                    return
                }
                self.revertGitHunk(hunk, inPath: targetPath)
                self.activeTextView?.needsDisplay = true
            } catch {
                let recovery = self.gitRecovery(for: error) {
                    self.revertGitHunkAtLine(targetLine, inPath: targetPath)
                }
                self.presentGitAlert("Couldn’t Discard Change in “\(name)”", Self.failureReason(error), recovery: recovery)
            }
        }
    }

    @MainActor
    func revertGitHunk(_ hunk: GitDiffHunk, inPath path: String) {
        let name = (path as NSString).lastPathComponent
        if documentSession(forPath: path) == nil, FileManager.default.fileExists(atPath: path) {
            _ = openBackgroundDocument(path)
        }
        guard let session = documentSession(forPath: path) else {
            presentGitAlert(
                "Couldn’t Discard Change in “\(name)”",
                "GoLens couldn’t open “\(name)” to revert the change.",
                recovery: GitAlertRecovery(title: "Try Again") { self.revertGitHunk(hunk, inPath: path) }
            )
            return
        }
        let currentString = session.storage.string
        let eol = currentString.contains("\r\n") ? "\r\n" : (session.lineEnding == "\r\n" ? "\r\n" : "\n")
        let replaceRange: NSRange
        let replacement: String

        if hunk.newCount == 0 {
            let targetLine0 = max(0, hunk.newStart)
            let insertOffset = session.lines.start(ofLine: targetLine0) ?? session.length
            replaceRange = NSRange(location: insertOffset, length: 0)
            let joined = hunk.removedLines.joined(separator: eol)
            let atEOF = insertOffset == session.length
            if atEOF {
                let needsLeadingEOL = session.length > 0 && (currentString as NSString).character(at: session.length - 1) != 0x0A
                let prefix = needsLeadingEOL ? eol : ""
                let suffix = hunk.oldHasTrailingNewline ? eol : ""
                replacement = prefix + joined + suffix
            } else {
                replacement = joined + eol
            }
        } else {
            let startLine0 = max(0, hunk.newStart - 1)
            let endLine0 = max(startLine0, hunk.newStart + hunk.newCount - 2)
            guard let startOffset = session.lines.start(ofLine: startLine0) else {
                presentGitAlert("Couldn’t Discard Change in “\(name)”", "“\(name)” changed after the diff was loaded. Review the updated changes and try again.")
                refreshActiveFileDiff()
                return
            }
            let nextLineStart = session.lines.start(ofLine: endLine0 + 1)
            let endOffset = nextLineStart ?? session.length
            replaceRange = NSRange(location: startOffset, length: max(0, endOffset - startOffset))
            if hunk.oldCount == 0 {
                replacement = ""
            } else {
                let joined = hunk.removedLines.joined(separator: eol)
                let atEOF = endOffset == session.length
                if atEOF {
                    replacement = hunk.oldHasTrailingNewline ? (joined + eol) : joined
                } else {
                    replacement = joined + eol
                }
            }
        }

        applyRanges([(replaceRange, replacement)], in: session, actionName: "Revert Git Hunk")
        observeUndoRedoForDiffRefresh(on: session.undoManager)
        refreshActiveFileDiff()
        updateCaretLineBlame()
    }

    @MainActor
    func revertOrDiscardHunkInDiffView(runRefs: Set<GitPatchLineRef>, patch: GitFilePatch, hunk: GitDiffHunk, inPath path: String) async {
        if documentSession(forPath: path)?.isEdited == true {
            revertGitHunk(hunk, inPath: path)
            return
        }
        _ = await discardGitPatchSelection(runRefs, from: patch, inPath: path)
    }

    func documentSession(forPath path: String) -> DocumentSession? {
        if let session = documents[path] {
            return session
        }
        let resolvedPath = Self.canonicalizePath(path)
        return documents.first(where: {
            Self.canonicalizePath($0.key) == resolvedPath
        })?.value
    }

    func gitChangeState(for path: String) -> (hasStaged: Bool, hasUnstaged: Bool) {
        var hasStaged = false
        var hasUnstaged = false
        for file in git.changedFiles where file.absolutePath == path {
            if file.isStaged {
                hasStaged = true
            } else {
                hasUnstaged = true
            }
        }
        if !hasStaged && !hasUnstaged && GitRefreshCoordinator.shared.isInsideUntrackedDirectory(path) {
            hasUnstaged = true
        }
        if documentSession(forPath: path)?.isEdited == true {
            hasUnstaged = true
        }
        return (hasStaged, hasUnstaged)
    }

    func effectiveDiffSource(for path: String) -> GitDiffSource {
        let state = gitChangeState(for: path)
        if state.hasStaged && !state.hasUnstaged {
            return .staged
        }
        if !state.hasStaged {
            return .unstaged
        }
        return GitDiffSourceStore.shared.requested[Self.canonicalizePath(path)] ?? .unstaged
    }

    func setDiffSource(_ source: GitDiffSource, for path: String) {
        let key = Self.canonicalizePath(path)
        if GitDiffSourceStore.shared.requested[key] != source {
            GitDiffSourceStore.shared.requested[key] = source
        }
    }

    func openFileInDiff(_ path: String, source: GitDiffSource) {
        setDiffSource(source, for: path)
        openFileInDiff(path)
    }

    @MainActor
    @discardableResult
    func applyGitLineSelection(_ selection: Set<GitPatchLineRef>, from displayed: GitFilePatch, inPath path: String, source: GitDiffSource, fullContext: Bool) async -> Bool {
        let unstage = source == .staged
        let name = (path as NSString).lastPathComponent
        if !unstage {
            guard await saveBeforeStaging(path, preserveExactBuffer: true) else {
                presentGitAlert(
                    "Couldn’t Save “\(name)”",
                    "Nothing was staged. Save the file, then try again.",
                    recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.applyGitLineSelection(selection, from: displayed, inPath: path, source: source, fullContext: fullContext) } }
                )
                return false
            }
        }
        let freshDiff = await workingDiff(for: path, fullContext: fullContext, source: source, includeUnsavedEdits: false)
        if let notice = GitDiffNotice.message(in: freshDiff) {
            presentGitAlert(
                "Couldn’t \(unstage ? "Unstage" : "Stage") Change in “\(name)”",
                notice,
                recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.applyGitLineSelection(selection, from: displayed, inPath: path, source: source, fullContext: fullContext) } }
            )
            return false
        }
        var freshPatch = GitPatchBuilder.parse(freshDiff).first
        if unstage, (freshPatch == nil || !GitPatchBuilder.sameChanges(freshPatch!, displayed)) {
            let renamedFresh = await workingDiff(for: path, fullContext: fullContext, source: source, includeUnsavedEdits: false, detectRenames: true)
            if let notice = GitDiffNotice.message(in: renamedFresh) {
                presentGitAlert(
                    "Couldn’t Unstage Change in “\(name)”",
                    notice,
                    recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.applyGitLineSelection(selection, from: displayed, inPath: path, source: source, fullContext: fullContext) } }
                )
                return false
            }
            if let candidate = GitPatchBuilder.parse(renamedFresh).first, GitPatchBuilder.sameChanges(candidate, displayed) {
                freshPatch = candidate
            }
        }
        guard let matchedPatch = freshPatch, GitPatchBuilder.sameChanges(matchedPatch, displayed) else {
            presentGitAlert(
                "“\(name)” Changed",
                "The file changed after the diff was shown, so nothing was \(unstage ? "unstaged" : "staged"). Review the updated changes and try again."
            )
            refreshGitStatus()
            refreshActiveFileDiff()
            return false
        }
        return await applyGitPatchSelection(selection, from: matchedPatch, inPath: path, unstage: unstage)
    }

    @MainActor
    func stageGitHunkAtLine(_ line: Int?, inPath path: String) {
        let targetPath = path.isEmpty ? activeFilePath : path
        guard !targetPath.isEmpty else {
            presentCommandFeedback("Open a file in the repository to stage a change.", title: "Stage Change Unavailable")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = (targetPath as NSString).lastPathComponent
            guard await self.saveBeforeStaging(targetPath, preserveExactBuffer: true) else {
                self.presentGitAlert(
                    "Couldn’t Save “\(name)”",
                    "Nothing was staged. Save the file, then try again.",
                    recovery: GitAlertRecovery(title: "Try Again") { self.stageGitHunkAtLine(line, inPath: targetPath) }
                )
                return
            }
            let targetLine = max(1, line ?? self.caretLine(inPath: targetPath))
            let diff = await self.workingDiff(for: targetPath, fullContext: false, source: .unstaged, includeUnsavedEdits: false)
            if let notice = GitDiffNotice.message(in: diff) {
                self.presentGitAlert(
                    "Couldn’t Stage Change in “\(name)”",
                    notice,
                    recovery: GitAlertRecovery(title: "Try Again") { self.stageGitHunkAtLine(targetLine, inPath: targetPath) }
                )
                return
            }
            guard let patch = GitPatchBuilder.parse(diff).first,
                  let run = Self.gitPatchRun(atLine: targetLine, in: patch) else {
                self.presentGitAlert(
                    "No Unstaged Change on Line \(targetLine)",
                    "There’s nothing to stage on this line of “\(name)”. Its change may already be staged."
                )
                return
            }
            await self.applyGitPatchSelection(Set(run.refs), from: patch, inPath: targetPath, unstage: false)
            self.activeTextView?.needsDisplay = true
        }
    }

    static func gitPatchRun(atLine line: Int, in patch: GitFilePatch) -> GitPatchRun? {
        let runs = GitPatchBuilder.runs(in: patch)
        if let exact = runs.first(where: { $0.newCount > 0 && line >= $0.newStart && line < $0.newStart + $0.newCount }) {
            return exact
        }
        return runs.first(where: { $0.newCount == 0 && (line == max(1, $0.newStart) || line == $0.newStart + 1) })
    }

    @MainActor
    private func caretLine(inPath path: String) -> Int {
        if let textView = activeTextView as? GoLensTextView, textView.filePath == path {
            return textView.lineAndCol(forCharacterIndex: textView.selectedRange().location).line
        }
        return cursorLine
    }

    @MainActor
    func saveBeforeStaging(_ path: String, preserveExactBuffer: Bool = false) async -> Bool {
        guard let session = documentSession(forPath: path), session.isEdited else { return true }
        (activeTextView as? GoLensTextView)?.breakUndoCoalescing()
        (primaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        (secondaryTextView as? GoLensTextView)?.breakUndoCoalescing()
        return await withCheckedContinuation { continuation in
            if preserveExactBuffer {
                writeDocument(session) { saved in
                    continuation.resume(returning: saved)
                }
            } else {
                save(session) { saved in
                    continuation.resume(returning: saved)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    func applyGitPatchSelection(_ selection: Set<GitPatchLineRef>, from patch: GitFilePatch, inPath path: String, unstage: Bool) async -> Bool {
        do {
            let (root, relativePath) = try await gitRepoRelativePath(for: path)
            let text = try GitPatchBuilder.build(patch, path: relativePath, selecting: selection, reverse: unstage)
            _ = try await runGit(
                args: ["apply", "--cached", "--whitespace=nowarn"] + (unstage ? ["-R"] : []) + ["-"],
                in: root,
                input: Data(text.utf8)
            )
        } catch {
            let recovery = gitRecovery(for: error, preferredPath: path) {
                Task { _ = await self.applyGitPatchSelection(selection, from: patch, inPath: path, unstage: unstage) }
            }
            presentGitAlert(unstage ? "Couldn’t Unstage the Change" : "Couldn’t Stage the Change", Self.failureReason(error), recovery: recovery)
            return false
        }
        refreshGitStatus()
        refreshActiveFileDiff()
        return true
    }

    @MainActor
    @discardableResult
    func discardGitPatchSelection(_ selection: Set<GitPatchLineRef>, from displayed: GitFilePatch, inPath path: String, fullContext: Bool = false) async -> Bool {
        let name = (path as NSString).lastPathComponent
        guard await saveBeforeStaging(path, preserveExactBuffer: true) else {
            presentGitAlert(
                "Couldn’t Save “\(name)”",
                "Nothing was discarded. Save the file, then try again.",
                recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.discardGitPatchSelection(selection, from: displayed, inPath: path, fullContext: fullContext) } }
            )
            return false
        }
        let freshDiff = await workingDiff(for: path, fullContext: fullContext, source: .unstaged, includeUnsavedEdits: false)
        if let notice = GitDiffNotice.message(in: freshDiff) {
            presentGitAlert(
                "Couldn’t Discard Change in “\(name)”",
                notice,
                recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.discardGitPatchSelection(selection, from: displayed, inPath: path, fullContext: fullContext) } }
            )
            return false
        }
        var matchedPatch = GitPatchBuilder.parse(freshDiff).first
        if matchedPatch == nil || !GitPatchBuilder.sameChanges(matchedPatch!, displayed) {
            let alt = await workingDiff(for: path, fullContext: !fullContext, source: .unstaged, includeUnsavedEdits: false)
            if let notice = GitDiffNotice.message(in: alt) {
                presentGitAlert(
                    "Couldn’t Discard Change in “\(name)”",
                    notice,
                    recovery: GitAlertRecovery(title: "Try Again") { Task { _ = await self.discardGitPatchSelection(selection, from: displayed, inPath: path, fullContext: fullContext) } }
                )
                return false
            }
            if let candidate = GitPatchBuilder.parse(alt).first, GitPatchBuilder.sameChanges(candidate, displayed) {
                matchedPatch = candidate
            }
        }
        guard let freshPatch = matchedPatch, GitPatchBuilder.sameChanges(freshPatch, displayed) else {
            presentGitAlert("“\(name)” Changed", "The file changed after the diff was shown, so nothing was discarded. Review the updated changes and try again.")
            refreshGitStatus()
            refreshActiveFileDiff()
            return false
        }
        let diskSize = ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        if FileManager.default.fileExists(atPath: path), diskSize > 0, !recordLocalHistoryBeforeDiscard(for: path) {
            guard await confirmAlert(Self.discardWithoutHistoryAlert(name: name)) else { return false }
        }
        do {
            let (root, relativePath) = try await gitRepoRelativePath(for: path)
            let text = try GitPatchBuilder.build(freshPatch, path: relativePath, selecting: selection, reverse: true)
            _ = try await runGit(args: ["apply", "-R", "--whitespace=nowarn", "-"], in: root, input: Data(text.utf8))
        } catch {
            let recovery = gitRecovery(for: error, preferredPath: path) {
                Task { _ = await self.discardGitPatchSelection(selection, from: displayed, inPath: path, fullContext: fullContext) }
            }
            presentGitAlert("Couldn’t Discard the Change", Self.failureReason(error), recovery: recovery)
            return false
        }
        filesChangedOnDisk([path])
        refreshGitStatus()
        refreshActiveFileDiff()
        updateCaretLineBlame()
        return true
    }

    private static func discardWithoutHistoryAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Discard this change in “\(name)”?"
        alert.informativeText = "Local History can’t keep a copy of this file, so the change can’t be recovered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Change").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func gitRepoRoot(for workspacePath: String) async -> String? {
        if let cached = await MainActor.run(body: { GitRefreshCoordinator.shared.locations[workspacePath]?.repoRoot }) {
            return cached
        }
        return (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--show-toplevel"], in: workspacePath))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitRepoRelativePath(for path: String) async throws -> (root: String, relativePath: String) {
        guard let top = await gitRepoRoot(for: activeWorkspacePath), !top.isEmpty else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "This folder isn’t inside a Git repository."])
        }
        let root = Self.canonicalizePath(top)
        let full = Self.canonicalizePath(path)
        guard full.hasPrefix(root + "/") else {
            throw NSError(domain: GitCommandError.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "“\((path as NSString).lastPathComponent)” isn’t inside the Git repository."])
        }
        return (root, String(full.dropFirst(root.count + 1)))
    }

    private static var observedUndoManagers = NSHashTable<UndoManager>.weakObjects()

    private func observeUndoRedoForDiffRefresh(on undoManager: UndoManager) {
        guard !Self.observedUndoManagers.contains(undoManager) else { return }
        Self.observedUndoManagers.add(undoManager)
        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main) { [weak self] _ in
            self?.refreshActiveFileDiff()
            self?.updateCaretLineBlame()
        }
        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: .main) { [weak self] _ in
            self?.refreshActiveFileDiff()
            self?.updateCaretLineBlame()
        }
    }
}
