import AppKit

extension Notification.Name {
    static let mergeConflictRegionsDidChange = Notification.Name("GoLensMergeConflictRegionsDidChange")
}

struct MergeConflictError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension WorkspaceState {
    private static var conflictScanWorkItems: [String: DispatchWorkItem] = [:]

    func applyMergeConflictState(conflictedPaths: Set<String>, operation: GitMergeOperation?) {
        if git.mergeOperation != operation {
            if git.mergeOperation == .merge, operation != .merge { sourceControl.discardMergeMessageDraft() }
            git.mergeOperation = operation
        }
        let previous = git.conflictedPaths
        if previous != conflictedPaths { git.conflictedPaths = conflictedPaths }
        for path in git.conflictRegions.keys where !conflictedPaths.contains(path) {
            git.conflictRegions.removeValue(forKey: path)
            NotificationCenter.default.post(name: .mergeConflictRegionsDidChange, object: path)
        }
        for path in conflictedPaths {
            scanMergeConflicts(path: path)
        }
    }

    func scanMergeConflicts(path: String) {
        Self.conflictScanWorkItems.removeValue(forKey: path)?.cancel()
        guard git.conflictedPaths.contains(path), let session = documents[path] else { return }
        let regions = MergeConflictScanner.scan(session.storage.mutableString)
        guard git.conflictRegions[path] != regions else { return }
        git.conflictRegions[path] = regions
        NotificationCenter.default.post(name: .mergeConflictRegionsDidChange, object: path)
    }

    func scheduleMergeConflictScan(path: String) {
        guard git.conflictedPaths.contains(path) else { return }
        Self.conflictScanWorkItems[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scanMergeConflicts(path: path)
        }
        Self.conflictScanWorkItems[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func mergeConflictCount(for path: String) -> Int {
        git.conflictRegions[path]?.count ?? 0
    }

    func isTreeOrBinaryMergeConflict(for path: String) -> Bool {
        let canon = Self.canonicalizePath(path)
        guard git.conflictedPaths.contains(path) || git.conflictedPaths.contains(canon) else { return false }
        let xy = git.unmergedStatuses[path] ?? git.unmergedStatuses[canon] ?? ""
        if ["UD", "DU", "AU", "UA", "DD"].contains(xy) {
            return true
        }
        let checkPath = FileManager.default.fileExists(atPath: path) ? path : canon
        if !FileManager.default.fileExists(atPath: checkPath) {
            return true
        }
        return GitDiffNotice.isBinaryFile(atPath: checkPath)
    }

    @MainActor
    func keepConflictedFile(_ path: String) async throws {
        let name = (path as NSString).lastPathComponent
        let filePath = Self.canonicalizePath(path)
        if let session = documentSession(forPath: path) {
            if !MergeConflictScanner.scan(session.storage.mutableString).isEmpty {
                throw MergeConflictError(message: "“\(name)” still contains conflict markers. Resolve every conflict before keeping the file.")
            }
            if session.isEdited || !FileManager.default.fileExists(atPath: filePath) {
                let saved = await withCheckedContinuation { continuation in
                    save(session) { continuation.resume(returning: $0) }
                }
                guard saved else {
                    throw MergeConflictError(message: "Couldn’t save “\(name)”, so it wasn’t kept.")
                }
            }
        } else if !GitDiffNotice.isBinaryFile(atPath: filePath),
                  let text = try? NSString(contentsOfFile: filePath, encoding: String.Encoding.utf8.rawValue),
                  !MergeConflictScanner.scan(text).isEmpty {
            throw MergeConflictError(message: "“\(name)” still contains conflict markers. Resolve every conflict before keeping the file.")
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw MergeConflictError(message: "“\(name)” doesn’t exist on disk, so it can’t be kept. Choose Delete File instead, or restore its contents first.")
        }
        let relPath = Self.gitRelativePath(forAbsolutePath: filePath, from: activeWorkspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            throw MergeConflictError(message: "“\(name)” isn’t inside the active repository.")
        }
        _ = try await runGit(args: ["--literal-pathspecs", "add", "--", relPath])
        refreshGitStatus()
        refreshActiveFileDiff()
    }

    @MainActor
    func deleteConflictedFile(_ path: String) async throws {
        let name = (path as NSString).lastPathComponent
        let filePath = Self.canonicalizePath(path)
        let relPath = Self.gitRelativePath(forAbsolutePath: filePath, from: activeWorkspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            throw MergeConflictError(message: "“\(name)” isn’t inside the active repository.")
        }
        _ = try await runGit(args: ["--literal-pathspecs", "rm", "-f", "--quiet", "--", relPath])
        for openPath in [path, filePath] where openFiles.contains(openPath) {
            if let session = documents[openPath] {
                session.savedVersion = session.version
            }
            editedFiles.remove(openPath)
            closeTab(openPath)
        }
        refreshGitStatus()
        refreshActiveFileDiff()
    }

    func resolveMergeConflict(atLine line: Int, in path: String, with resolution: MergeConflictResolution) {
        let name = (path as NSString).lastPathComponent
        guard let session = documents[path] else {
            presentCommandFeedback("Open “\(name)” before resolving conflicts.", title: "Resolve Conflict Unavailable")
            return
        }
        let text = session.storage.mutableString
        let regions = MergeConflictScanner.scan(text)
        guard let index = MergeConflictScanner.regionIndex(containingLine: line, in: regions) else {
            presentCommandFeedback("Move the cursor inside a conflict block in “\(name)” to resolve it.", title: "No Conflict on Line")
            return
        }
        let region = regions[index]
        let replacement = MergeConflictScanner.replacement(for: region, resolution: resolution, in: text)
        applyRanges([(region.range, replacement)], in: session, actionName: resolution.actionName)
        if let textView = textView(showing: session), region.range.location <= session.length {
            textView.setSelectedRange(NSRange(location: region.range.location, length: 0))
        }
        scanMergeConflicts(path: path)
    }

    func navigateMergeConflict(in path: String, forward: Bool, inSplitPane: Bool = false) {
        let name = (path as NSString).lastPathComponent
        guard let session = documents[path] else {
            presentCommandFeedback("Open a conflicted file to navigate between merge conflicts.", title: "Navigate Conflicts Unavailable")
            return
        }
        let regions = git.conflictRegions[path] ?? MergeConflictScanner.scan(session.storage.mutableString)
        let candidates = inSplitPane ? [secondaryTextView, activeTextView] : [activeTextView, secondaryTextView]
        let textView = candidates.lazy.compactMap { $0 as? GoLensTextView }.first { $0.document === session }
        let caretLine = textView.map { session.lines.line(at: min($0.selectedRange().location, session.length)) + 1 } ?? 0
        guard let index = MergeConflictScanner.neighborIndex(fromLine: caretLine, forward: forward, in: regions) else {
            presentCommandFeedback("“\(name)” has no merge conflicts.", title: "No Merge Conflicts")
            return
        }
        let region = regions[index]
        if let textView {
            textView.setSelectedRange(NSRange(location: region.range.location, length: 0))
            textView.scrollRangeToVisible(region.range)
            textView.window?.makeFirstResponder(textView)
        } else {
            jumpTo(filePath: path, line: region.startLine, column: 1)
        }
        let announcer: Any = textView.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(
            element: announcer,
            notification: .announcementRequested,
            userInfo: [.announcement: "Conflict \(index + 1) of \(regions.count)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    @MainActor
    func markMergeConflictResolved(_ path: String) async throws {
        if let session = documents[path] {
            if !MergeConflictScanner.scan(session.storage.mutableString).isEmpty {
                throw MergeConflictError(message: "“\((path as NSString).lastPathComponent)” still contains conflict markers. Resolve every conflict before marking the file as resolved.")
            }
            if session.isEdited {
                let saved = await withCheckedContinuation { continuation in
                    save(session) { continuation.resume(returning: $0) }
                }
                guard saved else {
                    throw MergeConflictError(message: "Couldn’t save “\((path as NSString).lastPathComponent)”, so it wasn’t marked as resolved.")
                }
            }
        } else if let text = try? NSString(contentsOfFile: path, encoding: String.Encoding.utf8.rawValue),
                  !MergeConflictScanner.scan(text).isEmpty {
            throw MergeConflictError(message: "“\((path as NSString).lastPathComponent)” still contains conflict markers. Resolve every conflict before marking the file as resolved.")
        }
        let filePath = Self.canonicalizePath(path)
        let relPath = Self.gitRelativePath(forAbsolutePath: filePath, from: activeWorkspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else {
            throw MergeConflictError(message: "“\((path as NSString).lastPathComponent)” isn’t inside the active repository.")
        }
        let args = FileManager.default.fileExists(atPath: filePath)
            ? ["--literal-pathspecs", "add", "--", relPath]
            : ["--literal-pathspecs", "rm", "--quiet", "--", relPath]
        _ = try await runGit(args: args)
        refreshGitStatus()
        refreshActiveFileDiff()
    }

    @MainActor
    func abortMergeOperation() async throws {
        guard let operation = git.mergeOperation else {
            throw MergeConflictError(message: "There is no merge, rebase, or cherry-pick in progress.")
        }
        _ = try await runGit(args: [operation.command, "--abort"])
        sourceControl.discardMergeMessageDraft()
        await finishMergeOperationStep()
    }

    @MainActor
    func continueMergeOperation() async throws {
        guard let operation = git.mergeOperation else {
            throw MergeConflictError(message: "There is no merge, rebase, or cherry-pick in progress.")
        }
        if operation == .merge {
            showCommitEditor()
            return
        }
        _ = try await runGit(args: unsignedGitConfigFlags() + ["-c", "core.editor=true", operation.command, "--continue"])
        await finishMergeOperationStep()
    }

    @MainActor
    func fillMergeCommitMessage() async {
        let ui = sourceControl
        guard git.mergeOperation == .merge, git.conflictedPaths.isEmpty, !ui.commitMessageIsMergeMessage else { return }
        let amendPrefill = CommitMessageText.combine(subject: git.lastCommitSubject, body: git.lastCommitBody)
        let holdsOnlyAmendPrefill = ui.commitAmend && ui.commitMessage == amendPrefill
        guard !CommitMessageText.hasContent(ui.commitMessage) || holdsOnlyAmendPrefill else { return }
        let gitDir = ((try? await runGit(args: ["rev-parse", "--absolute-git-dir"])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDir.isEmpty,
              let raw = try? Data(contentsOf: URL(fileURLWithPath: (gitDir as NSString).appendingPathComponent("MERGE_MSG"))),
              let stripped = try? await runGit(args: ["stripspace", "-s"], input: raw) else { return }
        let message = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommitMessageText.hasContent(message), git.mergeOperation == .merge,
              !CommitMessageText.hasContent(ui.commitMessage) || (ui.commitAmend && ui.commitMessage == amendPrefill) else { return }
        ui.commitAmend = false
        ui.commitMessage = message
        ui.commitMessageIsMergeMessage = true
    }

    var canOpenMergeEditor: Bool {
        let path = activeFilePath
        guard !path.isEmpty, git.conflictedPaths.contains(path) else { return false }
        return mergeConflictCount(for: path) > 0
    }

    @MainActor
    func openMergeEditor(_ path: String) {
        let name = (path as NSString).lastPathComponent
        if documents[path] == nil { openFile(path) }
        guard let session = documents[path] else {
            presentCommandFeedback("GoLens couldn’t open “\(name)”.", title: "Merge Editor Unavailable", tone: .warning)
            return
        }
        guard !MergeConflictScanner.scan(session.storage.mutableString).isEmpty else {
            presentCommandFeedback(
                isTreeOrBinaryMergeConflict(for: path)
                    ? "“\(name)” conflicts as a whole file, so there are no lines to merge. Keep or delete it from the banner above the editor."
                    : "“\(name)” has no conflict markers left. Mark it as resolved to stage it.",
                title: "Nothing to Merge"
            )
            return
        }
        sourceControl.editorSurface = .mergeEditor(path)
    }

    @MainActor
    func applyMergeEditor(_ document: MergeEditorDocument, path: String) async throws {
        let name = (path as NSString).lastPathComponent
        guard let session = documents[path] else {
            throw MergeConflictError(message: "“\(name)” is no longer open, so the choices couldn’t be applied.")
        }
        guard session.storage.string == document.original else {
            throw MergeConflictError(message: "“\(name)” changed after the merge editor opened. Open the merge editor again to see the current conflicts.")
        }
        let replacements = document.replacements.sorted { $0.range.location > $1.range.location }.map { ($0.range, $0.text) }
        applyRanges(replacements, in: session, actionName: "Resolve Conflicts")
        scanMergeConflicts(path: path)
        closeSourceControlSurface()
        if document.isFullyResolved {
            try await markMergeConflictResolved(path)
        }
    }

    @MainActor
    private func finishMergeOperationStep() async {
        await refreshBlameHead()
        reloadCleanOpenDocumentsFromDisk()
        refreshGitStatus()
        refreshActiveFileDiff()
        updateCaretLineBlame()
    }
}
