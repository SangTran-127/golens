import AppKit
import GoLensFoundation
import SwiftUI

enum CommitScope: String, CaseIterable, Identifiable {
    case all, unstaged, staged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Changes"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        }
    }
}

struct CommitChangeFile: Identifiable, Equatable {
    let absolutePath: String
    let relativePath: String
    let staged: GitChangedFile?
    let unstaged: GitChangedFile?

    var id: String { absolutePath }
    var isFolder: Bool { relativePath.hasSuffix("/") }
    var originalPath: String? { staged?.originalPath ?? unstaged?.originalPath }
    var name: String { (relativePath as NSString).lastPathComponent }
    var directory: String {
        let trimmed = isFolder ? String(relativePath.dropLast()) : relativePath
        return (trimmed as NSString).deletingLastPathComponent
    }

    func sides(in scope: CommitScope) -> [CommitDiffSide] {
        var result: [CommitDiffSide] = []
        if let staged, scope != .unstaged { result.append(CommitDiffSide(isStaged: true, file: staged)) }
        if let unstaged, scope != .staged { result.append(CommitDiffSide(isStaged: false, file: unstaged)) }
        return result
    }

    static func group(_ files: [GitChangedFile]) -> [CommitChangeFile] {
        var order: [String] = []
        var staged: [String: GitChangedFile] = [:]
        var unstaged: [String: GitChangedFile] = [:]
        for file in files {
            if staged[file.absolutePath] == nil && unstaged[file.absolutePath] == nil { order.append(file.absolutePath) }
            if file.isStaged { staged[file.absolutePath] = file } else { unstaged[file.absolutePath] = file }
        }
        let grouped = order.map { path -> CommitChangeFile in
            let entry = staged[path] ?? unstaged[path]
            return CommitChangeFile(absolutePath: path, relativePath: entry?.relativePath ?? path, staged: staged[path], unstaged: unstaged[path])
        }
        return grouped.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}

struct CommitDiffSide: Identifiable, Equatable {
    let isStaged: Bool
    let file: GitChangedFile

    var id: Bool { isStaged }
    var title: String { isStaged ? "Staged" : "Unstaged" }
    var allowsChangeActions: Bool { file.status != "??" && file.status != "U" }
}

struct CommitDiffRow: Identifiable, Equatable {
    let id: Int
    let kind: GitPatchLine.Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?

    var oldLabel: String { oldNumber.map(String.init) ?? "" }
    var newLabel: String { newNumber.map(String.init) ?? "" }

    var marker: String {
        switch kind {
        case .context: ""
        case .removed: "-"
        case .added: "+"
        }
    }

    var background: Color {
        switch kind {
        case .context: Color.clear
        case .removed: StatusTone.failure.fill
        case .added: StatusTone.success.fill
        }
    }
}

struct CommitDiffHunk: Identifiable, Equatable {
    let id: Int
    let header: String
    let rows: [CommitDiffRow]
}

struct CommitSideDiff: Equatable {
    let patch: GitFilePatch
    let hunks: [CommitDiffHunk]
    let isBinary: Bool
    let message: String?

    var lineCount: Int { hunks.reduce(0) { $0 + $1.rows.count } }

    init(raw: String) {
        let parsed = GitPatchBuilder.parse(raw).first ?? GitFilePatch()
        patch = parsed
        hunks = parsed.hunks.enumerated().map { index, hunk in Self.makeHunk(index: index, hunk: hunk) }
        isBinary = Self.hasDiffLine(raw, prefix: "Binary files ") || Self.hasDiffLine(raw, prefix: "GIT binary patch")
        message = GitDiffNotice.message(in: raw) ?? GitDiffNotice.headerOnlyMessage(in: raw) ?? (raw.hasPrefix("No changes or error loading diff") ? raw : nil)
    }

    func changeSelection(hunk index: Int) -> Set<GitPatchLineRef> {
        var refs = Set<GitPatchLineRef>()
        for (offset, line) in patch.hunks[index].lines.enumerated() where line.kind != .context {
            refs.insert(GitPatchLineRef(hunk: index, line: offset))
        }
        return refs
    }

    static func load(path: String, staged: Bool, isFolder: Bool, in workspace: WorkspaceState) async -> CommitSideDiff {
        let raw = isFolder
            ? await workspace.untrackedFolderSummary(for: path)
            : await workspace.workingDiff(for: path, fullContext: false, source: staged ? .staged : .unstaged, includeUnsavedEdits: !staged)
        return await Task.detached(priority: .userInitiated) { CommitSideDiff(raw: raw) }.value
    }

    private static func hasDiffLine(_ raw: String, prefix: String) -> Bool {
        raw.hasPrefix(prefix) || raw.contains("\n" + prefix)
    }

    private static func makeHunk(index: Int, hunk: GitPatchHunk) -> CommitDiffHunk {
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        var rows: [CommitDiffRow] = []
        for (offset, line) in hunk.lines.enumerated() {
            let text = displayText(line.text)
            switch line.kind {
            case .context:
                rows.append(CommitDiffRow(id: offset, kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            case .removed:
                rows.append(CommitDiffRow(id: offset, kind: .removed, text: text, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            case .added:
                rows.append(CommitDiffRow(id: offset, kind: .added, text: text, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            }
        }
        let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
        let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(section)"
        return CommitDiffHunk(id: index, header: header, rows: rows)
    }

    private static func displayText(_ text: String) -> String {
        var shown = text
        if shown.hasSuffix("\r") { shown.removeLast() }
        shown = shown.replacingOccurrences(of: "\t", with: "    ")
        return shown.isEmpty ? " " : shown
    }
}

struct CommitEditorView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable private var ui: SourceControlUI
    @Bindable private var signingStore = GitSigningStore.shared
    private var stamps = GitChangeStamps.shared
    @State private var scope: CommitScope = .all
    @State private var author: GitAuthorIdentity?
    @State private var collapsed: Set<String> = []
    @State private var groupedFiles: [CommitChangeFile]
    @State private var mergeOutsideCount = 0
    @State private var localReplaceWarnings: [GoModCommitReplaceSummary] = []
    @State private var isDroppingLocalReplaces = false

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.ui = workspace.sourceControlState
        _groupedFiles = State(initialValue: CommitChangeFile.group(workspace.git.changedFiles))
    }

    private static let configCommand = "git config --global user.name \"Your Name\" && git config --global user.email you@example.com"

    var body: some View {
        VStack(spacing: 0) {
            header
            bannerArea
            CommitMessageBox()
            Divider()
            scopeBar
            Divider()
            changeList
        }
        .background(ThemeColor.contentSurface)
        .task(id: workspace.activeWorkspacePath) {
            author = await workspace.gitAuthorIdentity()
            refreshLocalReplaceWarnings()
        }
        .onAppear {
            refreshLocalReplaceWarnings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { author = await workspace.gitAuthorIdentity() }
            refreshLocalReplaceWarnings()
        }
        .onChange(of: workspace.git.changedFiles) {
            groupedFiles = CommitChangeFile.group(workspace.git.changedFiles)
            refreshMergeOutsideCount()
            refreshLocalReplaceWarnings()
        }
        .onChange(of: workspace.editedFiles) {
            refreshLocalReplaceWarnings()
        }
        .onChange(of: workspace.isFinishingMerge, initial: true) { refreshMergeOutsideCount() }
        .onChange(of: workspace.git.recentCommits.isEmpty, initial: true) { _, isEmpty in
            if isEmpty && ui.commitAmend { ui.commitAmend = false }
        }
        .onChange(of: ui.commitAmend) { _, isOn in fillAmendMessage(isOn) }
    }

    private func refreshLocalReplaceWarnings() {
        localReplaceWarnings = workspace.changedGoModLocalReplaces()
    }

    private func refreshMergeOutsideCount() {
        guard workspace.isFinishingMerge else {
            mergeOutsideCount = 0
            return
        }
        let repo = workspace.activeWorkspacePath
        Task { @MainActor in
            let outside = await workspace.stagedPathsOutsideWorkspace(in: repo)
            if repo == workspace.activeWorkspacePath { mergeOutsideCount = outside.count }
        }
    }

    private var mergeNoteText: String {
        guard mergeOutsideCount > 0 else { return "Merging — committing completes the merge" }
        let noun = mergeOutsideCount == 1 ? "file" : "files"
        return "Merging — \(mergeOutsideCount) staged \(noun) outside this folder are part of the merge"
    }

    private func fillAmendMessage(_ isOn: Bool) {
        guard isOn, !CommitMessageText.hasContent(ui.commitMessage) else { return }
        ui.commitMessage = CommitMessageText.combine(subject: workspace.git.lastCommitSubject, body: workspace.git.lastCommitBody)
    }

    private var header: some View {
        HStack(spacing: Spacing.comfortable) {
            authorView
            signingIndicator
            mergeNote
            Spacer(minLength: 8)
            amendToggle
            commitButton
            closeButton
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
    }

    @ViewBuilder
    private var signingIndicator: some View {
        if signingStore.isSigningEnabled {
            HStack(spacing: Spacing.compact) {
                Image(systemName: signingStore.selectedKey?.isSecurityKey == true ? "key.horizontal" : "key")
                    .accessibilityHidden(true)
                Text("Signing On")
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(signingStore.selectedKey.map { "Commits are signed with \($0.fileName) (\($0.fingerprint))" } ?? "Commit signing is enabled in Source Control settings")
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var authorView: some View {
        if let author, !author.isComplete {
            HStack(spacing: Spacing.row) {
                Image(systemName: StatusTone.warning.symbol)
                    .foregroundStyle(StatusTone.warning.tint)
                    .accessibilityHidden(true)
                Text("Set your name and email with git config before committing")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Copy Command") { workspace.copyToPasteboard(Self.configCommand) }
                    .controlSize(.small)
                    .help("Copy the git config commands to the clipboard")
            }
        } else if let author {
            HStack(spacing: Spacing.row) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(author.display)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("Author of the commit")
        }
    }

    @ViewBuilder
    private var mergeNote: some View {
        if workspace.isFinishingMerge {
            HStack(spacing: Spacing.row) {
                Image(systemName: "arrow.triangle.merge")
                    .accessibilityHidden(true)
                Text(mergeNoteText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(mergeNoteText)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var amendToggle: some View {
        let shortHash = workspace.git.recentCommits.first?.shortHash ?? ""
        return Toggle(isOn: $ui.commitAmend) {
            Text(shortHash.isEmpty ? "Amend" : "Amend “\(shortHash)”")
        }
        .toggleStyle(.checkbox)
        .disabled(workspace.git.recentCommits.isEmpty || ui.isCommitting || workspace.isFinishingMerge)
        .help(workspace.isFinishingMerge ? "A merge can’t be amended; commit it first" : "Replace the last commit with this one")
    }

    private var commitButton: some View {
        let amend = ui.commitAmend && !workspace.isFinishingMerge
        let title = amend ? "Amend" : "Commit"
        let pushTitle = amend ? "Amend and Push" : "Commit and Push"
        return HStack(spacing: Spacing.row) {
            if ui.isCommitting {
                ProgressView()
                    .controlSize(.small)
                if !signingStore.isWaitingForSecurityKeyTouch {
                    Button("Cancel") {
                        workspace.cancelCommitFromEditor()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                }
            }
            Menu {
                Button(pushTitle) { workspace.commitFromEditor(andPush: true) }
            } label: {
                Text(title)
            } primaryAction: {
                workspace.commitFromEditor(andPush: false)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!workspace.commitDraftCanCommit)
            .help(commitHelp)
        }
    }

    private var commitHelp: String {
        if !workspace.git.conflictedPaths.isEmpty { return "Resolve every merge conflict before committing" }
        if !ui.commitMessageHasText { return "Enter a commit message to commit" }
        if workspace.isFinishingMerge { return "Commit to complete the merge (⌘↩)" }
        if workspace.git.changedFiles.isEmpty && !ui.commitAmend { return "There are no changes to commit" }
        if !ui.commitAmend && workspace.git.stagedFilesCount == 0 { return "Commit (⌘↩). Nothing is staged, so you’ll be asked whether to stage everything" }
        return "Commit the staged changes (⌘↩)"
    }

    @ViewBuilder
    private var closeButton: some View {
        if ui.isCommitting {
            closeButtonBase
                .disabled(true)
        } else {
            closeButtonBase
                .keyboardShortcut(.cancelAction)
        }
    }

    private var closeButtonBase: some View {
        Button {
            workspace.closeSourceControlSurfaceFromEscape()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close Commit Editor")
        .accessibilityLabel("Close Commit Editor")
    }

    @ViewBuilder
    private var bannerArea: some View {
        if signingStore.isWaitingForSecurityKeyTouch {
            securityKeyTouchBanner
        }
        if let failure = signingStore.signingFailureMessage {
            signingFailureBanner(failure)
        }
        if let banner = ui.commitBanner {
            committedBanner(banner)
        }
        if !workspace.git.conflictedPaths.isEmpty {
            conflictBanner
        }
        if !localReplaceWarnings.isEmpty {
            localReplaceGuardBanner
        }
        if !workspace.editedWorkspacePathsNotInGit.isEmpty {
            unsavedEditorChangesBanner
        }
    }

    private var localReplaceGuardBanner: some View {
        let fileCount = localReplaceWarnings.count
        let totalDirectives = localReplaceWarnings.reduce(0) { $0 + $1.directives.count }
        let title = fileCount == 1
            ? "Local Replace Directive in \(localReplaceWarnings[0].relativePath)"
            : "Local Replace Directives in \(fileCount) go.mod Files"
        let previewItems = localReplaceWarnings.flatMap { summary in
            summary.directives.map { "\($0.oldModule) => \($0.target)" }
        }.prefix(2).joined(separator: ", ")
        let extra = totalDirectives > 2 ? " (+\(totalDirectives - 2) more)" : ""
        let message = "\(previewItems)\(extra) points to a local path. Local replace directives bypass go.sum verification and break builds for teammates and CI if committed."
        let firstSummary = localReplaceWarnings.first
        let firstLine = firstSummary?.directives.first?.line ?? 1
        return InlineBanner(
            .status(.warning),
            title: title,
            message: message
        ) {
            if let firstSummary {
                Button("Open go.mod") {
                    workspace.jumpTo(filePath: firstSummary.path, line: firstLine, column: 1)
                }
            }
            Button("Drop Local Replaces") {
                isDroppingLocalReplaces = true
                Task { @MainActor in
                    await workspace.dropAllLocalReplacesBeforeCommit()
                    refreshLocalReplaceWarnings()
                    isDroppingLocalReplaces = false
                }
            }
            .disabled(isDroppingLocalReplaces)
        }
    }

    private var unsavedEditorChangesBanner: some View {
        let count = workspace.editedWorkspacePathsNotInGit.count
        let message = count == 1
            ? "1 modified file hasn’t been saved to disk yet."
            : "\(count) modified files haven’t been saved to disk yet."
        return InlineBanner(
            .status(.info),
            title: "Unsaved Editor Changes",
            message: message
        ) {
            Button("Save All") {
                Task {
                    _ = await workspace.saveAllEditedFilesInWorkspace()
                    workspace.refreshGitStatus()
                }
            }
        }
    }

    private var securityKeyTouchBanner: some View {
        InlineBanner(
            .accent("key.horizontal.fill"),
            title: "Touch your security key to sign this commit…"
        ) {
            Button("Cancel") {
                workspace.cancelCommitFromEditor()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func signingFailureBanner(_ message: String) -> some View {
        InlineBanner(
            .status(.warning),
            title: message
        ) {
            Button("Try Again") {
                workspace.commitFromEditor(andPush: ui.lastCommitPushRequested, forceUnsigned: false)
            }
            Button("Commit Without Signing") {
                workspace.commitFromEditor(andPush: ui.lastCommitPushRequested, forceUnsigned: true)
            }
        }
    }

    private func committedBanner(_ banner: CommitBanner) -> some View {
        InlineBanner(
            .status(.success),
            title: "Committed \(banner.shortHash): \(banner.subject)"
        ) {
            Button("Show in History") {
                workspace.showHistory(GitHistoryTarget(revision: banner.hash, title: workspace.git.branchName))
            }
        }
    }

    private var conflictBanner: some View {
        let count = workspace.git.conflictedPaths.count
        let noun = count == 1 ? "merge conflict" : "merge conflicts"
        return InlineBanner(
            .status(.warning),
            title: "Resolve \(count) \(noun) before committing"
        )
    }

    private var scopeBar: some View {
        HStack(spacing: Spacing.comfortable) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            Picker("Show", selection: $scope) {
                ForEach(CommitScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Show Changes")
            HStack(spacing: Spacing.standard) {
                Spacer(minLength: 0)
                Button("Unstage All") { workspace.unstageAllFiles() }
                    .disabled(workspace.git.stagedFilesCount == 0)
                    .help("Unstage every staged file")
                Button("Stage All") { workspace.stageAllFiles() }
                    .disabled(workspace.unstagedNonConflictFiles.isEmpty && workspace.editedWorkspacePathsNotInGit.isEmpty)
                    .help("Stage every changed file")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
    }

    private var visibleFiles: [CommitChangeFile] {
        groupedFiles.filter { !$0.sides(in: scope).isEmpty }
    }

    @ViewBuilder
    private var emptyChangeList: some View {
        if workspace.isFinishingMerge {
            ContentUnavailableView("Ready to Complete the Merge", systemImage: "arrow.triangle.merge", description: Text("The merge result matches HEAD. Commit to record the merge."))
        } else if !workspace.editedWorkspacePathsNotInGit.isEmpty {
            ContentUnavailableView("Unsaved Editor Changes", systemImage: "square.and.pencil", description: Text("Save your modified files so Git can include them in a commit."))
        } else {
            ContentUnavailableView("No Uncommitted Changes", systemImage: "checkmark.circle", description: Text("Everything is committed."))
        }
    }

    @ViewBuilder
    private var changeList: some View {
        if workspace.git.changedFiles.isEmpty {
            emptyChangeList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleFiles.isEmpty {
            ContentUnavailableView(scope == .staged ? "No Staged Changes" : "No Unstaged Changes", systemImage: "tray")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Spacing.comfortable) {
                    ForEach(visibleFiles) { file in
                        CommitFileDiffDisclosure(
                            file: file,
                            scope: scope,
                            changeStamp: stamps.stamp(for: file.absolutePath),
                            isCollapsed: collapsed.contains(file.id),
                            toggleCollapsed: { toggleCollapsed(file.id) }
                        )
                    }
                }
                .padding(Spacing.comfortable)
            }
        }
    }

    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

