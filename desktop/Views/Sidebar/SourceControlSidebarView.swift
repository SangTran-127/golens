import SwiftUI

struct SourceControlSidebarView: View {
    @Bindable var workspace: WorkspaceState
    private var refreshStatus = GitRefreshStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showStagedChanges = true
    @State private var showUnstagedChanges = true
    @State private var showRecentCommits = true
    @State private var showCommitFilter = false
    @State private var commitFilterQuery = ""
    @State private var commitFilterFocusTrigger = 0
    @State private var changedFilesFilterQuery = ""
    @State private var selectedChangeRowID: String? = nil
    
    @State private var initError: String? = nil
    @State private var showMergeConflicts = true
    @State private var showAbortOperationConfirmation = false
    @State private var isRunningMergeOperation = false

    init(workspace: WorkspaceState) {
        self.workspace = workspace
    }
    
    var body: some View {
        if workspace.git.isRepository == false {
            notRepositoryView
        } else {
            VStack(spacing: 0) {
                Picker("Source Control", selection: Bindable(workspace.sourceControl).navigatorTab) {
                    ForEach(SourceControlNavigatorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Changes or Repositories")
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.standard)
                Divider()
                if workspace.sourceControl.navigatorTab == .repositories {
                    SourceControlRepositoriesView(workspace: workspace)
                } else {
                    repositoryView
                }
            }
        }
    }

    private var notRepositoryView: some View {
        Group {
            if let initError {
                UnifiedEmptyState.failed(
                    title: "Not a Git Repository",
                    message: initError,
                    onRetry: createGitRepository
                )
            } else {
                UnifiedEmptyState.empty(
                    symbol: "arrow.triangle.branch",
                    badge: "git",
                    title: "Not a Git Repository",
                    message: "\((workspace.activeWorkspacePath as NSString).lastPathComponent) isn’t under version control. Create a repository to track changes, or open a folder that has one.",
                    actionTitle: "Create Git Repository",
                    action: createGitRepository
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createGitRepository() {
        Task {
            do {
                _ = try await workspace.runGit(args: ["init"])
                initError = nil
                workspace.refreshGitStatus()
            } catch {
                initError = "Couldn’t create a repository: \(error.localizedDescription)"
            }
        }
    }

    private var filteredCommits: [GitCommitSummary] {
        let q = commitFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return workspace.git.recentCommits }
        return workspace.git.recentCommits.filter {
            $0.subject.lowercased().contains(q) ||
            $0.shortHash.lowercased().contains(q) ||
            $0.author.lowercased().contains(q)
        }
    }

    private var repositoryView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack(spacing: Spacing.row) {
                    Menu {
                        if workspace.git.branches.isEmpty {
                            Text("No Branches")
                        } else {
                            ForEach(workspace.git.branches, id: \.self) { branch in
                                Button(action: {
                                    workspace.switchBranchStashingIfNeeded(branch)
                                }) {
                                    HStack {
                                        if branch == workspace.git.branchName {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(branch)
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button(action: {
                            workspace.sourceControl.sheet = .newBranch(from: nil)
                        }) {
                            Label("New Branch…", systemImage: "plus")
                        }

                        if workspace.hasNamedBranch && workspace.git.branchName != "No Branch" {
                            Button(action: {
                                workspace.sourceControl.sheet = .renameBranch(workspace.git.branchName)
                            }) {
                                Label("Rename Current Branch…", systemImage: "pencil")
                            }
                        }

                        let deletableBranches = workspace.git.branches.filter { $0 != workspace.git.branchName }
                        if !deletableBranches.isEmpty {
                            Menu("Delete Branch", systemImage: "trash") {
                                ForEach(deletableBranches, id: \.self) { b in
                                    Button("\(b)…", systemImage: "trash", role: .destructive) {
                                        workspace.confirmDeleteBranch(workspace.repositories.branches.first { $0.name == b }
                                            ?? GitRef(kind: .branch, fullName: "refs/heads/" + b, name: b, shortHash: "", upstream: "", date: nil, subject: ""))
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: Spacing.compact) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            
                            Text(workspace.git.branchName.isEmpty ? "Loading branch…" : workspace.git.branchName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .help("Switch or manage branches")
                    .accessibilityLabel("Current Branch: \(workspace.git.branchName)")

                    if workspace.git.hasUpstream && (workspace.git.aheadCount > 0 || workspace.git.behindCount > 0) {
                        HStack(spacing: Spacing.compact) {
                            if workspace.git.aheadCount > 0 {
                                HStack(spacing: Spacing.hairline) {
                                    Image(systemName: "arrow.up")
                                    Text("\(workspace.git.aheadCount)")
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            if workspace.git.behindCount > 0 {
                                HStack(spacing: Spacing.hairline) {
                                    Image(systemName: "arrow.down")
                                    Text("\(workspace.git.behindCount)")
                                }
                                .foregroundStyle(StatusTone.warning.tint)
                            }
                        }
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                        .help("Ahead \(workspace.git.aheadCount), Behind \(workspace.git.behindCount) relative to upstream")
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        workspace.refreshFileStatusFromUser()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(KeymapStore.shared.labeled("Refresh Status", "sc.refresh"))
                    .accessibilityLabel("Refresh Git Status")

                    Menu {
                        Button {
                            workspace.stageAllFiles()
                        } label: {
                            Label("Stage All Changes", systemImage: "plus.circle")
                        }
                        .disabled(workspace.unstagedNonConflictFiles.isEmpty && workspace.editedWorkspacePathsNotInGit.isEmpty)

                        Button {
                            workspace.unstageAllFiles()
                        } label: {
                            Label("Unstage All Changes", systemImage: "minus.circle")
                        }
                        .disabled(workspace.git.stagedFilesCount == 0)

                        Button(role: .destructive) {
                            workspace.confirmDiscardAllChanges()
                        } label: {
                            Label("Discard All Changes…", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(workspace.git.changedFiles.isEmpty)

                        Divider()

                        Button {
                            workspace.sourceControl.sheet = .stash
                        } label: {
                            Label("Stash Changes…", systemImage: "archivebox")
                        }
                        .disabled(workspace.git.changedFiles.isEmpty || workspace.git.recentCommits.isEmpty)

                        if !workspace.git.stashes.isEmpty {
                            Menu("Stashed Changes (\(workspace.git.stashes.count))", systemImage: "archivebox") {
                                ForEach(workspace.git.stashes) { entry in
                                    Menu(entry.message.isEmpty ? entry.ref : entry.message, systemImage: "archivebox") {
                                        Button("Apply Stashed Changes", systemImage: "tray.and.arrow.down") {
                                            workspace.applyStash(entry, delete: false)
                                        }
                                        Button("Apply and Delete", systemImage: "tray.and.arrow.down.fill") {
                                            workspace.applyStash(entry, delete: true)
                                        }
                                        Divider()
                                        Button("Delete…", systemImage: "trash", role: .destructive) {
                                            workspace.confirmDeleteStash(entry)
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            performUndoLastCommit()
                        } label: {
                            Label("Undo Last Commit…", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(workspace.git.recentCommits.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Git Actions")
                    .accessibilityLabel("Git Actions")
                }
                .padding(.horizontal, Spacing.comfortable)
                .padding(.top, Spacing.inset)
                
                HStack(spacing: Spacing.row) {
                    remoteButton(
                        "Fetch",
                        badge: nil,
                        symbol: "arrow.down.circle",
                        busy: workspace.sourceControl.runningOperation == .fetch,
                        prominent: false,
                        disabled: false,
                        help: "Fetch changes from the remote"
                    ) { workspace.fetchChanges() }
                    remoteButton(
                        "Pull",
                        badge: workspace.git.behindCount > 0 ? "\(workspace.git.behindCount)" : nil,
                        symbol: "arrow.down.to.line.circle",
                        busy: workspace.sourceControl.runningOperation == .pull,
                        prominent: workspace.git.behindCount > 0,
                        disabled: !workspace.hasNamedBranch,
                        help: workspace.hasNamedBranch ? "Pull changes from the upstream branch" : "Switch to or create a branch before pulling"
                    ) { performPull() }
                    remoteButton(
                        "Push",
                        badge: workspace.git.aheadCount > 0 ? "\(workspace.git.aheadCount)" : nil,
                        symbol: "arrow.up.circle",
                        busy: workspace.sourceControl.runningOperation == .push,
                        prominent: workspace.git.aheadCount > 0,
                        disabled: !workspace.hasNamedBranch,
                        help: !workspace.hasNamedBranch
                            ? "Switch to or create a branch before pushing"
                            : (workspace.git.hasUpstream ? "Push to the upstream branch" : "Push this branch to a remote and track it")
                    ) { performPush() }
                }
                .padding(.horizontal, Spacing.inset)
                .padding(.bottom, Spacing.inset)
            }

            Divider()

            if let message = refreshStatus.unavailableMessage {
                InlineBanner(
                    .status(.warning),
                    title: "Git Status Unavailable",
                    message: message
                ) {
                    Button("Retry") {
                        workspace.refreshGitStatus()
                    }
                }
            }

            if let operation = workspace.git.mergeOperation {
                mergeOperationHeader(operation)
                Divider()
            }

            uncommittedChangesRow
            Divider()

            if !workspace.editedWorkspacePathsNotInGit.isEmpty {
                unsavedEditorChangesBanner
            }

            if workspace.git.changedFiles.isEmpty {
                if workspace.editedWorkspacePathsNotInGit.isEmpty {
                    UnifiedEmptyState.empty(
                        symbol: "checkmark.circle",
                        badge: "git",
                        title: "Working Tree Clean",
                        message: "All changes have been committed."
                    )
                } else {
                    Spacer(minLength: 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                let activePath = workspace.git.activeCommitDiffContext == nil ? workspace.activeFilePath : ""
                let isDark = workspace.currentTheme.resolvedIsDark
                let lists = SourceControlChangeLists(files: workspace.git.changedFiles, query: changedFilesFilterQuery)
                let visibleRows = visibleChangedFiles(from: lists)
                let allFilteredOut = lists.conflicted.isEmpty && lists.staged.isEmpty && lists.unstaged.isEmpty

                PanelFilterBar(
                    placeholder: "Filter changed files…",
                    text: $changedFilesFilterQuery,
                    accessibilityTitle: "Filter Changed Files",
                    onSubmit: {
                        openSelectedOrFirstChange(in: visibleRows)
                    },
                    onMoveSelection: { delta in
                        moveChangeSelection(by: delta, in: visibleRows)
                    }
                )
                .padding(.horizontal, Spacing.inset)
                .padding(.top, Spacing.standard)
                .padding(.bottom, Spacing.hairline)

                if allFilteredOut {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Changes") {
                        changedFilesFilterQuery = ""
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                                if !lists.conflicted.isEmpty {
                                    mergeConflictsSection(lists.conflicted, isDark: isDark, activePath: activePath)
                                }

                                if !lists.staged.isEmpty {
                                    HStack(spacing: Spacing.row) {
                                        Button {
                                            showStagedChanges.toggle()
                                        } label: {
                                            HStack(spacing: Spacing.compact) {
                                                Image(systemName: showStagedChanges ? "chevron.down" : "chevron.right")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 10)
                                                Text("Staged Changes")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                Text("\(lists.staged.count)")
                                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                                    .foregroundStyle(ThemeColor.accent)
                                                    .padding(.horizontal, Spacing.row)
                                                    .padding(.vertical, Spacing.hairline)
                                                    .background(ThemeColor.accent.opacity(0.12), in: Capsule())
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        Spacer()

                                        Button("Unstage All") {
                                            workspace.unstageAllFiles()
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(ThemeColor.accent)
                                        .help("Unstage all files")
                                    }
                                    .padding(.horizontal, Spacing.inset)
                                    .padding(.vertical, Spacing.compact)
                                    .padding(.top, lists.conflicted.isEmpty ? 0 : Spacing.compact)

                                    if showStagedChanges {
                                        ForEach(lists.staged, id: \.listRowID) { file in
                                            GitFileRow(
                                                file: file,
                                                isSelected: selectedChangeRowID == file.listRowID || lists.isRowSelected(file, activePath: activePath, workspace: workspace),
                                                stats: workspace.git.fileLineStats[file.absolutePath],
                                                isDark: isDark
                                            )
                                            .equatable()
                                            .id(file.listRowID)
                                        }
                                    }
                                }

                                if !lists.unstaged.isEmpty {
                                    HStack(spacing: Spacing.row) {
                                        Button {
                                            showUnstagedChanges.toggle()
                                        } label: {
                                            HStack(spacing: Spacing.compact) {
                                                Image(systemName: showUnstagedChanges ? "chevron.down" : "chevron.right")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 10)
                                                Text("Changes")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                Text("\(lists.unstaged.count)")
                                                    .font(.caption2.weight(.medium).monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, Spacing.row)
                                                    .padding(.vertical, Spacing.hairline)
                                                    .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        Spacer()

                                        Button {
                                            workspace.confirmDiscardAllChanges()
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Discard All Changes…")
                                        .accessibilityLabel("Discard All Changes")

                                        Button("Stage All") {
                                            workspace.stageAllFiles()
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(ThemeColor.accent)
                                        .disabled(workspace.unstagedNonConflictFiles.isEmpty && workspace.editedWorkspacePathsNotInGit.isEmpty)
                                        .help("Stage all changed files")
                                    }
                                    .padding(.horizontal, Spacing.inset)
                                    .padding(.vertical, Spacing.compact)
                                    .padding(.top, lists.conflicted.isEmpty && lists.staged.isEmpty ? 0 : Spacing.compact)

                                    if showUnstagedChanges {
                                        ForEach(lists.unstaged, id: \.listRowID) { file in
                                            GitFileRow(
                                                file: file,
                                                isSelected: selectedChangeRowID == file.listRowID || lists.isRowSelected(file, activePath: activePath, workspace: workspace),
                                                stats: workspace.git.fileLineStats[file.absolutePath],
                                                isDark: isDark
                                            )
                                            .equatable()
                                            .id(file.listRowID)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, Spacing.compact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: selectedChangeRowID) { _, id in
                            guard let id else { return }
                            withAnimation(reduceMotion ? nil : Motion.quick) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onKeyPress(.upArrow) {
                        guard !visibleRows.isEmpty else { return .ignored }
                        moveChangeSelection(by: -1, in: visibleRows)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !visibleRows.isEmpty else { return .ignored }
                        moveChangeSelection(by: 1, in: visibleRows)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard !visibleRows.isEmpty else { return .ignored }
                        openSelectedOrFirstChange(in: visibleRows)
                        return .handled
                    }
                }
            }

            Divider()

            recentCommitsSection
        }
        .alert(
            "Abort \(workspace.git.mergeOperation?.title ?? "Operation")?",
            isPresented: $showAbortOperationConfirmation
        ) {
            Button("Abort \(workspace.git.mergeOperation?.title ?? "")", role: .destructive) {
                performMergeOperation(abort: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your branch returns to how it was before the \((workspace.git.mergeOperation?.title ?? "operation").lowercased()) started. Conflict resolutions you’ve made will be lost.")
        }
    }

    private var uncommittedChangesRow: some View {
        let count = Set(workspace.git.changedFiles.map(\.absolutePath)).count
        let isOpen = workspace.sourceControl.editorSurface == .commit
        let fill = isOpen ? Color.accentColor.opacity(0.18) : Color.clear
        return Button {
            workspace.showCommitEditor()
        } label: {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Uncommitted Changes")
                    .font(.callout)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .background(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.row)
        .padding(.vertical, Spacing.compact)
        .help("Review the changes and commit them")
        .accessibilityLabel("Uncommitted Changes")
        .accessibilityValue(count == 1 ? "1 file" : "\(count) files")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
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
                saveAllUnsavedChanges()
            }
        }
    }

    private func saveAllUnsavedChanges() {
        Task { @MainActor in
            let saved = await workspace.saveAllEditedFilesInWorkspace()
            workspace.refreshGitStatus()
            if !saved {
                workspace.presentGitAlert(
                    "Couldn’t Save Modified Files",
                    "One or more modified files couldn’t be saved. Check file permissions and try again.",
                    recovery: WorkspaceState.GitAlertRecovery(title: "Try Again") {
                        saveAllUnsavedChanges()
                    }
                )
            }
        }
    }

    private func mergeOperationHeader(_ operation: GitMergeOperation) -> some View {
        let conflictCount = workspace.git.conflictedPaths.count
        return VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .top, spacing: Spacing.standard) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("\(operation.title) in Progress")
                        .font(.caption.weight(.semibold))
                    Text(conflictCount == 0
                        ? (operation == .rebase && workspace.git.rebaseStoppedToEdit
                            ? "Stopped so you can change a commit. Stage your edits and amend it, then Continue."
                            : "All conflicts are resolved. Continue to finish the \(operation.title.lowercased()).")
                        : (conflictCount == 1 ? "1 file has conflicts." : "\(conflictCount) files have conflicts."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.standard) {
                Spacer(minLength: 0)
                Button("Abort \(operation.title)…") {
                    showAbortOperationConfirmation = true
                }
                .help("Stop the \(operation.title.lowercased()) and restore the branch")
                Button("Continue") {
                    performMergeOperation(abort: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(conflictCount > 0)
                .help(continueHelp(operation, conflictCount: conflictCount))
            }
            .controlSize(.small)
            .disabled(isRunningMergeOperation)
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.standard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(operation.title) in Progress")
    }

    private func mergeConflictsSection(_ conflicted: [GitChangedFile], isDark: Bool, activePath: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Button {
                showMergeConflicts.toggle()
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: showMergeConflicts ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("Merge Conflicts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(conflicted.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(StatusTone.failure.tint)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(StatusTone.failure.fill, in: Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.inset)
            .padding(.vertical, Spacing.compact)
            .accessibilityLabel("Merge Conflicts, \(conflicted.count) files")
            .accessibilityHint(showMergeConflicts ? "Collapses the list" : "Expands the list")

            if showMergeConflicts {
                ForEach(conflicted) { file in
                    MergeConflictFileRow(file: file, isSelected: activePath == file.absolutePath, isDark: isDark) { error in
                        let recovery = workspace.gitRecovery(for: error, preferredPath: file.absolutePath) {
                            workspace.markResolved(file.absolutePath)
                        }
                        workspace.presentGitAlert("Couldn’t Mark “\(file.name)” as Resolved", WorkspaceState.failureReason(error), recovery: recovery)
                    }
                }
            }
        }
    }

    private func continueHelp(_ operation: GitMergeOperation, conflictCount: Int) -> String {
        if conflictCount > 0 { return "Resolve and mark every conflicted file as resolved first" }
        if operation == .merge { return "Open the commit editor to commit the merge" }
        return "Finish the \(operation.title.lowercased())"
    }

    private func performMergeOperation(abort: Bool) {
        isRunningMergeOperation = true
        Task { @MainActor in
            defer { isRunningMergeOperation = false }
            do {
                if abort {
                    try await workspace.abortMergeOperation()
                } else {
                    try await workspace.continueMergeOperation()
                }
            } catch {
                let recovery = workspace.gitRecovery(for: error) {
                    performMergeOperation(abort: abort)
                }
                workspace.presentGitAlert("Couldn’t \(abort ? "Abort" : "Continue") the \(workspace.git.mergeOperation?.title ?? "Operation")", WorkspaceState.failureReason(error), recovery: recovery)
            }
        }
    }

    @ViewBuilder
    private var recentCommitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.row) {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.quick) {
                        showRecentCommits.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.row) {
                        Image(systemName: showRecentCommits ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text("Recent Commits (\(workspace.git.recentCommits.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showRecentCommits && !workspace.git.recentCommits.isEmpty {
                    Button {
                        let willShow = !showCommitFilter
                        withAnimation(reduceMotion ? nil : Motion.quick) {
                            showCommitFilter = willShow
                            if !willShow {
                                commitFilterQuery = ""
                            }
                        }
                        if willShow {
                            commitFilterFocusTrigger &+= 1
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(showCommitFilter || !commitFilterQuery.isEmpty ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter Recent Commits")
                    .accessibilityLabel("Filter Recent Commits")

                    Button {
                        workspace.showHistory(GitHistoryTarget(revision: "HEAD", title: workspace.git.branchName))
                    } label: {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show History")
                    .accessibilityLabel("Show History")
                }
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)

            if showRecentCommits {
                if showCommitFilter {
                    PanelFilterBar(
                        placeholder: "Filter by message, hash, or author…",
                        text: $commitFilterQuery,
                        accessibilityTitle: "Filter Recent Commits",
                        focusTrigger: commitFilterFocusTrigger,
                        onEscapeWhenEmpty: {
                            withAnimation(reduceMotion ? nil : Motion.quick) {
                                showCommitFilter = false
                            }
                        }
                    )
                    .padding(.horizontal, Spacing.inset)
                    .padding(.bottom, Spacing.compact)
                }

                if workspace.git.recentCommits.isEmpty {
                    Text("No commits yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.bottom, Spacing.row)
                } else if filteredCommits.isEmpty {
                    Text("No matching commits")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.bottom, Spacing.row)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                            ForEach(filteredCommits) { commit in
                                CommitHistoryRow(
                                    commit: commit,
                                    isSelected: workspace.git.selectedCommit?.hash == commit.hash,
                                    onSelect: {
                                        withAnimation(reduceMotion ? nil : Motion.quick) {
                                            workspace.selectGitCommit(commit)
                                        }
                                    }
                                )

                                if workspace.git.selectedCommit?.hash == commit.hash {
                                    CommitInspectorCard(
                                        commit: commit,
                                        commitBody: workspace.git.selectedCommitBody,
                                        files: workspace.git.selectedCommitFiles,
                                        isLoading: workspace.git.isLoadingSelectedCommit,
                                        activeDiffRelPath: workspace.git.activeCommitDiffContext?.commit.hash == commit.hash
                                            ? workspace.git.activeCommitDiffContext?.relativePath
                                            : nil,
                                        onOpenFileDiff: { fileChange in
                                            workspace.openCommitFileDiff(fileChange, commit: commit)
                                        }
                                    )
                                    .padding(.horizontal, Spacing.standard)
                                    .padding(.bottom, Spacing.compact)
                                }
                            }
                        }
                        .padding(.bottom, Spacing.compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: workspace.git.selectedCommit != nil ? 240 : 164)
                }
            }
        }
    }
    
    private func performUndoLastCommit() {
        let previousSubject = workspace.git.lastCommitSubject
        let previousBody = workspace.git.lastCommitBody
        workspace.confirmUndoLastCommit {
            let ui = workspace.sourceControl
            if !CommitMessageText.hasContent(ui.commitMessage) {
                ui.commitMessage = CommitMessageText.combine(subject: previousSubject, body: previousBody)
            }
        }
    }

    private func visibleChangedFiles(from lists: SourceControlChangeLists) -> [GitChangedFile] {
        var rows: [GitChangedFile] = []
        if showMergeConflicts {
            rows.append(contentsOf: lists.conflicted)
        }
        if showStagedChanges {
            rows.append(contentsOf: lists.staged)
        }
        if showUnstagedChanges {
            rows.append(contentsOf: lists.unstaged)
        }
        return rows
    }

    private func moveChangeSelection(by delta: Int, in rows: [GitChangedFile]) {
        guard !rows.isEmpty else { return }
        if let currentID = selectedChangeRowID,
           let idx = rows.firstIndex(where: { $0.listRowID == currentID }) {
            let next = min(max(0, idx + delta), rows.count - 1)
            selectedChangeRowID = rows[next].listRowID
        } else {
            let target = delta >= 0 ? rows.first : rows.last
            selectedChangeRowID = target?.listRowID
        }
    }

    private func openSelectedOrFirstChange(in rows: [GitChangedFile]) {
        let chosen: GitChangedFile? = {
            if let currentID = selectedChangeRowID,
               let match = rows.first(where: { $0.listRowID == currentID }) {
                return match
            }
            return rows.first
        }()
        guard let file = chosen else { return }
        selectedChangeRowID = file.listRowID
        workspace.clearCommitDiffContext()
        workspace.openFileInDiff(file.absolutePath, source: file.isStaged ? .staged : .unstaged)
    }
    
    private func remoteButton(_ title: String, badge: String?, symbol: String, busy: Bool, prominent: Bool, disabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.compact) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(prominent ? Color.accentColor : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled || workspace.sourceControl.runningOperation != nil)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(busy ? "In progress" : (badge ?? ""))
    }

    private func performPull() {
        if workspace.git.hasUpstream {
            workspace.pullChanges(from: nil, rebase: nil)
        } else {
            workspace.sourceControl.sheet = .pull
        }
    }

    private func performPush() {
        if workspace.git.hasUpstream {
            workspace.pushChanges(to: nil, includeTags: false)
        } else {
            workspace.sourceControl.sheet = .push
        }
    }
}

struct CommitHistoryRow: View {
    let commit: GitCommitSummary
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        let accent = ThemeColor.accent
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.row) {
                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)

                    Text(commit.shortHash)
                        .font(.caption2.weight(.medium).monospaced())
                        .foregroundStyle(isSelected ? accent : .secondary)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(
                            (isSelected ? accent.opacity(0.14) : Color(nsColor: .quaternarySystemFill)),
                            in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        )

                    Text(commit.subject)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)
                }

                HStack(spacing: Spacing.compact) {
                    Text(commit.author)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.relativeTime)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, Spacing.comfortable)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? accent.opacity(0.12)
                    : (isHovered ? Color(nsColor: .quaternarySystemFill) : Color.clear),
                in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
            )
            .padding(.horizontal, Spacing.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Inspect Commit Files", systemImage: "doc.text.magnifyingglass") {
                onSelect()
            }
            Divider()
            Button("Copy Commit Hash (\(commit.shortHash))", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
            Button("Copy Commit Subject", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.subject, forType: .string)
            }
        }
        .help("\(commit.shortHash) — \(commit.subject) (\(commit.author), \(commit.relativeTime)). Click to inspect changed files.")
    }
}

struct CommitInspectorCard: View {
    let commit: GitCommitSummary
    let commitBody: String
    let files: [GitCommitFileChange]
    let isLoading: Bool
    let activeDiffRelPath: String?
    let onOpenFileDiff: (GitCommitFileChange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            if !commitBody.isEmpty {
                Text(commitBody)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.row)
            }

            if isLoading {
                HStack(spacing: Spacing.row) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading changed files…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.standard)
            } else if files.isEmpty {
                Text("No file modifications in this commit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(Spacing.standard)
            } else {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(files) { file in
                        let isSelected = activeDiffRelPath == file.relativePath
                        Button {
                            onOpenFileDiff(file)
                        } label: {
                            HStack(spacing: Spacing.row) {
                                FileIconView(fileName: file.relativePath, path: file.absolutePath, isSelected: false, size: 12)
                                Text(file.name)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                if file.added > 0 || file.removed > 0 {
                                    HStack(spacing: Spacing.compact) {
                                        if file.added > 0 {
                                            Text("+\(file.added)")
                                                .foregroundStyle(StatusTone.success.tint)
                                        }
                                        if file.removed > 0 {
                                            Text("-\(file.removed)")
                                                .foregroundStyle(StatusTone.failure.tint)
                                        }
                                    }
                                    .font(.caption2.monospacedDigit())
                                }
                                GitStatusBadge(status: file.status)
                            }
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.compact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("View commit diff for \(file.relativePath)")
                    }
                }
                .padding(.vertical, Spacing.compact)
            }
        }
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: Stroke.hairline)
        )
    }
}

extension GitChangedFile {
    var listRowID: String { (isStaged ? "staged:" : "unstaged:") + relativePath }
}

struct SourceControlChangeLists {
    let staged: [GitChangedFile]
    let unstaged: [GitChangedFile]
    let conflicted: [GitChangedFile]
    private let listedTwice: Set<String>

    init(files: [GitChangedFile], query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var staged: [GitChangedFile] = []
        var unstaged: [GitChangedFile] = []
        var conflicted: [GitChangedFile] = []
        var stagedPaths = Set<String>()
        var unstagedPaths = Set<String>()
        for file in files {
            if file.status != "U" {
                if file.isStaged { stagedPaths.insert(file.absolutePath) } else { unstagedPaths.insert(file.absolutePath) }
            }
            guard q.isEmpty || file.relativePath.lowercased().contains(q) else { continue }
            if file.status == "U" {
                conflicted.append(file)
            } else if file.isStaged {
                staged.append(file)
            } else {
                unstaged.append(file)
            }
        }
        self.staged = staged
        self.unstaged = unstaged
        self.conflicted = conflicted
        self.listedTwice = stagedPaths.intersection(unstagedPaths)
    }

    func isRowSelected(_ file: GitChangedFile, activePath: String, workspace: WorkspaceState) -> Bool {
        guard activePath == file.absolutePath else { return false }
        return !listedTwice.contains(file.absolutePath) || workspace.effectiveDiffSource(for: file.absolutePath) == (file.isStaged ? .staged : .unstaged)
    }
}

struct GitFileRow: View, Equatable {
    @Environment(\.windowWorkspace) private var workspace
    static func == (lhs: GitFileRow, rhs: GitFileRow) -> Bool {
        lhs.file.absolutePath == rhs.file.absolutePath &&
        lhs.file.originalPath == rhs.file.originalPath &&
        lhs.file.status == rhs.file.status &&
        lhs.file.isStaged == rhs.file.isStaged &&
        lhs.isSelected == rhs.isSelected &&
        lhs.stats == rhs.stats &&
        lhs.isDark == rhs.isDark
    }
    
    let file: GitChangedFile
    let isSelected: Bool
    let stats: GitFileLineStats?
    let isDark: Bool
    @State private var isHovered = false

    private var isFolder: Bool { file.relativePath.hasSuffix("/") }
    private var canOpen: Bool { file.status != "D" && !isFolder }

    var body: some View {
        HStack(spacing: Spacing.row) {
            Button(action: {
                if file.isStaged {
                    workspace.unstageFile(file.absolutePath)
                } else {
                    workspace.stageFile(file.absolutePath)
                }
            }) {
                Image(systemName: file.isStaged ? "checkmark.square.fill" : "square")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : (file.isStaged ? ThemeColor.accent : ThemeColor.textSecondary))
            }
            .buttonStyle(.plain)
            .padding(.leading, Spacing.row)
            .help(file.isStaged ? "Unstage file" : "Stage file")
            .accessibilityLabel(file.isStaged ? "Unstage \(file.name)" : "Stage \(file.name)")
            
            Button {
                workspace.clearCommitDiffContext()
                if canOpen, let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.clickCount >= 2 {
                    workspace.openFile(file.absolutePath)
                    workspace.setEditorMode(.code, for: file.absolutePath)
                } else {
                    workspace.openFileInDiff(file.absolutePath, source: file.isStaged ? .staged : .unstaged)
                }
            } label: {
                HStack(spacing: Spacing.row) {
                    FileIconView(fileName: file.name, path: file.absolutePath, isFolder: isFolder, isSelected: isSelected, size: 14)
            
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        HStack(spacing: Spacing.compact) {
                            if let orig = file.originalPath, !orig.isEmpty {
                                Text("\((orig as NSString).lastPathComponent) →")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ThemeColor.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text(file.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ThemeColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                
                        let dirPath = (file.relativePath as NSString).deletingLastPathComponent
                        if !dirPath.isEmpty {
                            Text(dirPath)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : ThemeColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.relativePath)
            .accessibilityHint("Shows the changes")
            .accessibilityAction(named: "Open File") {
                guard canOpen else { return }
                workspace.clearCommitDiffContext()
                workspace.openFile(file.absolutePath)
                workspace.setEditorMode(.code, for: file.absolutePath)
            }

            if isHovered {
                HStack(spacing: Spacing.compact) {
                    if canOpen {
                        Button {
                            workspace.clearCommitDiffContext()
                            workspace.openFile(file.absolutePath)
                            workspace.setEditorMode(.code, for: file.absolutePath)
                        } label: {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open File in Code Editor")
                        .accessibilityLabel("Open File")
                    }

                    Button {
                        workspace.confirmDiscard(file)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Discard Changes…")
                    .accessibilityLabel("Discard Changes")

                    Button {
                        if file.isStaged {
                            workspace.unstageFile(file.absolutePath)
                        } else {
                            workspace.stageFile(file.absolutePath)
                        }
                    } label: {
                        Image(systemName: file.isStaged ? "minus.circle" : "plus.circle")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(file.isStaged ? "Unstage File" : "Stage File")
                    .accessibilityLabel(file.isStaged ? "Unstage File" : "Stage File")
                }
            } else if let stats, (stats.added > 0 || stats.removed > 0) {
                HStack(spacing: Spacing.compact) {
                    if stats.added > 0 {
                        Text("+\(stats.added)")
                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : StatusTone.success.tint)
                    }
                    if stats.removed > 0 {
                        Text("-\(stats.removed)")
                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : StatusTone.failure.tint)
                    }
                }
                .font(.caption2.monospacedDigit())
            }

            GitStatusBadge(status: file.status)
                .padding(.trailing, Spacing.row)
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.compact)
        .background(
            isSelected
                ? (ThemeColor.selection)
                : (isHovered ? Color(nsColor: .quaternarySystemFill) : Color.clear),
            in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
        )
        .padding(.horizontal, Spacing.row)
        .contentShape(Rectangle())
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Show Diff", systemImage: "arrow.left.arrow.right") {
                workspace.clearCommitDiffContext()
                workspace.openFileInDiff(file.absolutePath, source: file.isStaged ? .staged : .unstaged)
            }
            
            if canOpen {
                Button("Open File", systemImage: "doc.text") {
                    workspace.clearCommitDiffContext()
                    workspace.openFile(file.absolutePath)
                    workspace.setEditorMode(.code, for: file.absolutePath)
                }
            }

            Divider()
            
            if file.isStaged {
                Button("Unstage File", systemImage: "minus.circle") {
                    workspace.unstageFile(file.absolutePath)
                }
            } else {
                Button("Stage File", systemImage: "plus.circle") {
                    workspace.stageFile(file.absolutePath)
                }
            }
            
            Button("Discard Changes…", systemImage: "arrow.uturn.backward", role: .destructive) {
                workspace.confirmDiscard(file)
            }

            Divider()

            Button("Show in Finder", systemImage: "folder") {
                revealPathOrExistingParentInFinder(file.absolutePath)
            }

            Button("Copy Relative Path", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.relativePath, forType: .string)
            }
        }
    }
}

struct MergeConflictFileRow: View {
    @Environment(\.windowWorkspace) private var workspace
    let file: GitChangedFile
    let isSelected: Bool
    let isDark: Bool
    let onError: (Error) -> Void
    @State private var isHovered = false

    var body: some View {
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        Button(action: openFile) {
            HStack(spacing: Spacing.row) {
                FileIconView(fileName: file.relativePath, path: file.absolutePath, isSelected: isSelected, size: 14)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(file.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let dirPath = (file.relativePath as NSString).deletingLastPathComponent
                    if !dirPath.isEmpty {
                        Text(dirPath)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? selectedText.opacity(0.85) : ThemeColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? selectedText : StatusTone.failure.tint)
                    .help("Merge Conflict")
                    .accessibilityHidden(true)
                    .padding(.trailing, Spacing.row)
            }
            .padding(.leading, Spacing.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.compact)
        .background(
            isSelected
                ? (ThemeColor.selection)
                : (isHovered ? Color(nsColor: .quaternarySystemFill) : Color.clear),
            in: RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
        )
        .padding(.horizontal, Spacing.row)
        .onHover { hovering in
            if isHovered != hovering { isHovered = hovering }
        }
        .accessibilityLabel("\(file.relativePath), merge conflict")
        .accessibilityHint("Opens the file to resolve its conflicts")
        .accessibilityAction(named: "Mark as Resolved", markResolved)
        .accessibilityAction(named: "Open in Merge Editor") { workspace.openMergeEditor(file.absolutePath) }
        .contextMenu {
            Button("Open File", systemImage: "doc.text", action: openFile)
            Button("Open in Merge Editor", systemImage: "rectangle.split.3x1") {
                workspace.clearCommitDiffContext()
                workspace.openMergeEditor(file.absolutePath)
            }
            .disabled(workspace.isTreeOrBinaryMergeConflict(for: file.absolutePath) && workspace.mergeConflictCount(for: file.absolutePath) == 0)
            Button("Mark as Resolved", systemImage: "checkmark.seal", action: markResolved)
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                revealPathOrExistingParentInFinder(file.absolutePath)
            }
            Button("Copy Relative Path", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.relativePath, forType: .string)
            }
        }
    }

    private func openFile() {
        workspace.clearCommitDiffContext()
        workspace.openFile(file.absolutePath)
        workspace.setEditorMode(.code, for: file.absolutePath)
    }

    private func markResolved() {
        Task { @MainActor in
            do {
                try await workspace.markMergeConflictResolved(file.absolutePath)
            } catch {
                onError(error)
            }
        }
    }
}

private func revealPathOrExistingParentInFinder(_ path: String) {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return
    }
    var dir = (path as NSString).deletingLastPathComponent
    while !dir.isEmpty && dir != "/" && !fm.fileExists(atPath: dir) {
        dir = (dir as NSString).deletingLastPathComponent
    }
    if !dir.isEmpty && fm.fileExists(atPath: dir) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }
}
