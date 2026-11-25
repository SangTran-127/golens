import AppKit
import GoLensFoundation
import SwiftUI

struct SourceControlRepositoriesView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable private var store: GitRepositoryStore
    @State private var selection: String? = nil
    @State private var showBranches = true
    @State private var showRemotes = true
    @State private var showTags = true
    @State private var showStashes = true
    @State private var showWorktrees = true

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.store = workspace.repositories
    }

    private var repositoryName: String {
        (workspace.activeWorkspacePath as NSString).lastPathComponent
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                DisclosureGroup(isExpanded: $showBranches) {
                    if store.branches.isEmpty {
                        emptyRow("No Branches")
                    }
                    ForEach(store.branches) { ref in
                        refRow(ref).tag(ref.id).contextMenu { branchMenu(ref) }
                    }
                } label: {
                    groupLabel("Branches", symbol: "arrow.triangle.branch", count: store.branches.count)
                }

                DisclosureGroup(isExpanded: $showRemotes) {
                    if store.remotes.isEmpty {
                        emptyRow("No Remotes")
                    }
                    ForEach(store.remotes) { remote in
                        DisclosureGroup {
                            ForEach(store.remoteBranches(of: remote.name)) { ref in
                                refRow(ref).tag(ref.id).contextMenu { remoteBranchMenu(ref) }
                            }
                        } label: {
                            Label(remote.name, systemImage: "cloud")
                                .help(remote.url)
                                .contextMenu { remoteMenu(remote) }
                        }
                    }
                } label: {
                    groupLabel("Remotes", symbol: "cloud", count: store.remotes.count)
                        .contextMenu {
                            Button("Add Existing Remote…", systemImage: "plus.circle") { workspace.sourceControl.sheet = .addRemote }
                        }
                }

                DisclosureGroup(isExpanded: $showTags) {
                    if store.tags.isEmpty {
                        emptyRow("No Tags")
                    }
                    ForEach(store.tags) { ref in
                        refRow(ref).tag(ref.id).contextMenu { tagMenu(ref) }
                    }
                } label: {
                    groupLabel("Tags", symbol: "tag", count: store.tags.count)
                }

                DisclosureGroup(isExpanded: $showStashes) {
                    if workspace.git.stashes.isEmpty {
                        emptyRow("No Stashed Changes")
                    }
                    ForEach(workspace.git.stashes) { entry in
                        stashRow(entry).tag("stash:" + entry.ref).contextMenu { stashMenu(entry) }
                    }
                } label: {
                    groupLabel("Stashed Changes", symbol: "archivebox", count: workspace.git.stashes.count)
                }

                DisclosureGroup(isExpanded: $showWorktrees) {
                    if store.worktrees.isEmpty {
                        emptyRow("No Worktrees")
                    }
                    ForEach(store.worktrees) { entry in
                        worktreeRow(entry).tag("worktree:" + entry.path).contextMenu { worktreeMenu(entry) }
                    }
                } label: {
                    groupLabel("Worktrees", symbol: "folder.badge.plus", count: store.worktrees.count)
                        .contextMenu {
                            Button("New Worktree…", systemImage: "folder.badge.plus") { workspace.sourceControl.sheet = .newWorktree(branch: nil) }
                            Button("Prune Stale Worktrees", systemImage: "arrow.clockwise") { workspace.pruneWorktrees() }
                        }
                }
            } header: {
                HStack(spacing: Spacing.row) {
                    Text(repositoryName)
                    Text(workspace.git.branchName)
                        .foregroundStyle(.secondary)
                }
                .contextMenu { repositoryMenu() }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.automatic)
        .onChange(of: selection) { _, id in select(id) }
        .onChange(of: workspace.sourceControl.editorSurface) { _, surface in
            if surface != .history { selection = nil }
        }
        .onAppear { workspace.reloadRepositoryRefs() }
        .onChange(of: workspace.git.branchName) { workspace.reloadRepositoryRefs() }
        .onChange(of: workspace.git.recentCommits.first?.hash) { workspace.reloadRepositoryRefs() }
    }

    private func select(_ id: String?) {
        guard let id else { return }
        if id.hasPrefix("stash:") {
            let ref = String(id.dropFirst("stash:".count))
            let title = workspace.git.stashes.first { $0.ref == ref }.map { $0.message.isEmpty ? $0.ref : $0.message } ?? ref
            workspace.showHistory(GitHistoryTarget(revision: ref, title: title, isSingleCommit: true))
        } else if id.hasPrefix("worktree:") {
            let path = String(id.dropFirst("worktree:".count))
            if let entry = store.worktrees.first(where: { $0.path == path }) {
                let rev = entry.branchName.map { "refs/heads/\($0)" } ?? entry.headHash
                if !rev.isEmpty {
                    workspace.showHistory(GitHistoryTarget(revision: rev, title: entry.folderName, isSingleCommit: false))
                }
            }
        } else if let ref = store.refs.first(where: { $0.id == id }) {
            workspace.showHistory(GitHistoryTarget(revision: ref.fullName, title: ref.name, isSingleCommit: false))
        }
    }

    private func groupLabel(_ title: String, symbol: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }

    private func refRow(_ ref: GitRef) -> some View {
        let isCurrent = ref.kind == .branch && ref.name == workspace.git.branchName
        return HStack(spacing: Spacing.row) {
            Image(systemName: ref.kind == .tag ? "tag" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(ref.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current branch")
            }
            Text(ref.shortHash)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .help(ref.subject)
        .accessibilityElement(children: .combine)
    }

    private func stashRow(_ entry: GitStashEntry) -> some View {
        HStack(spacing: Spacing.row) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(entry.message.isEmpty ? entry.ref : entry.message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(entry.relativeTime)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func worktreeRow(_ entry: GitWorktreeEntry) -> some View {
        let isCurrent = workspace.isCurrentWorktree(entry)
        var detailParts = [entry.displayBranch]
        if entry.isLocked { detailParts.append("Locked") }
        if entry.isPrunable { detailParts.append("Missing") }
        let detail = detailParts.joined(separator: " · ")

        return HStack(spacing: Spacing.row) {
            Image(systemName: entry.isPrunable ? "folder.badge.questionmark" : "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(entry.folderName)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Spacing.compact)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current worktree")
            }
            if !entry.shortHash.isEmpty {
                Text(entry.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .help(entry.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.folderName), \(detail)\(isCurrent ? ", current worktree" : "")")
    }

    @ViewBuilder
    private func repositoryMenu() -> some View {
        Button("New Branch…", systemImage: "arrow.triangle.branch") { workspace.sourceControl.sheet = .newBranch(from: nil) }
        Button("New Worktree…", systemImage: "folder.badge.plus") { workspace.sourceControl.sheet = .newWorktree(branch: nil) }
        Button("New Tag…", systemImage: "tag") { workspace.sourceControl.sheet = .newTag(at: "HEAD") }
            .disabled(workspace.git.recentCommits.isEmpty)
        Divider()
        Button("Fetch Changes", systemImage: "arrow.down.circle") { workspace.fetchChanges() }
        Button("Add Existing Remote…", systemImage: "network") { workspace.sourceControl.sheet = .addRemote }
    }

    @ViewBuilder
    private func branchMenu(_ ref: GitRef) -> some View {
        let current = workspace.git.branchName
        let isCurrent = ref.name == current
        Button("Switch to “\(ref.name)”…", systemImage: "arrow.left.arrow.right") { workspace.switchToRef(ref) }
            .disabled(isCurrent)
        Button("New Branch from “\(ref.name)”…", systemImage: "arrow.triangle.branch") { workspace.sourceControl.sheet = .newBranch(from: ref.name) }
        Button("New Worktree from “\(ref.name)”…", systemImage: "folder.badge.plus") { workspace.sourceControl.sheet = .newWorktree(branch: ref.name) }
        Button("New Tag on “\(ref.name)”…", systemImage: "tag") { workspace.sourceControl.sheet = .newTag(at: ref.name) }
        Button("Rename…", systemImage: "pencil") { workspace.sourceControl.sheet = .renameBranch(ref.name) }
        Divider()
        Button("Merge “\(ref.name)” into “\(current)”…", systemImage: "arrow.triangle.merge") { workspace.mergeIntoCurrent(ref) }
            .disabled(isCurrent || !workspace.hasNamedBranch)
        Button("Rebase “\(current)” onto “\(ref.name)”…", systemImage: "arrow.triangle.pull") { workspace.rebaseCurrent(onto: ref) }
            .disabled(isCurrent || !workspace.hasNamedBranch)
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { workspace.copyToPasteboard(ref.name) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { workspace.confirmDeleteBranch(ref) }
            .disabled(isCurrent)
    }

    @ViewBuilder
    private func remoteBranchMenu(_ ref: GitRef) -> some View {
        let current = workspace.git.branchName
        Button("Switch to “\(ref.name)”…", systemImage: "arrow.left.arrow.right") { workspace.switchToRef(ref) }
            .disabled(ref.name == current)
        Button("New Branch from “\(ref.fullName.replacingOccurrences(of: "refs/remotes/", with: ""))”…", systemImage: "arrow.triangle.branch") {
            workspace.sourceControl.sheet = .newBranch(from: ref.fullName.replacingOccurrences(of: "refs/remotes/", with: ""))
        }
        Divider()
        Button("Merge into “\(current)”…", systemImage: "arrow.triangle.merge") { workspace.mergeIntoCurrent(ref) }
            .disabled(!workspace.hasNamedBranch)
        Button("Rebase “\(current)” onto It…", systemImage: "arrow.triangle.pull") { workspace.rebaseCurrent(onto: ref) }
            .disabled(!workspace.hasNamedBranch)
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { workspace.copyToPasteboard(ref.fullName.replacingOccurrences(of: "refs/remotes/", with: "")) }
    }

    @ViewBuilder
    private func remoteMenu(_ remote: GitRemoteInfo) -> some View {
        Button("Fetch “\(remote.name)”", systemImage: "arrow.down.circle") {
            workspace.runRemoteOperation(.fetch) { try await workspace.runGit(args: ["fetch", "--prune", remote.name]) }
        }
        Button("Copy URL", systemImage: "link") { workspace.copyToPasteboard(remote.url) }
        Divider()
        Button("Remove “\(remote.name)”…", systemImage: "trash", role: .destructive) {
            workspace.confirm("Remove the remote “\(remote.name)”?", "Its remote branches disappear from this repository. Nothing changes on the server.", action: "Remove", destructive: true) {
                workspace.runRepositoryAction("Couldn’t Remove “\(remote.name)”") {
                    _ = try await workspace.runGit(args: ["remote", "remove", remote.name])
                }
            }
        }
    }

    @ViewBuilder
    private func tagMenu(_ ref: GitRef) -> some View {
        Button("Switch to “\(ref.name)”…", systemImage: "arrow.left.arrow.right") { workspace.switchToRef(ref) }
        Button("New Branch from “\(ref.name)”…", systemImage: "arrow.triangle.branch") { workspace.sourceControl.sheet = .newBranch(from: ref.name) }
        Button("Push “\(ref.name)”", systemImage: "arrow.up") {
            workspace.runRemoteOperation(.push) {
                let remote = store.remotes.contains { $0.name == "origin" } ? "origin" : (store.remotes.first?.name ?? "origin")
                return try await workspace.runGit(args: ["push", remote, "refs/tags/\(ref.name)"])
            }
        }
        .disabled(store.remotes.isEmpty)
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { workspace.copyToPasteboard(ref.name) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { workspace.confirmDeleteTag(ref) }
    }

    @ViewBuilder
    private func stashMenu(_ entry: GitStashEntry) -> some View {
        Button("Apply Stashed Changes", systemImage: "tray.and.arrow.down") { workspace.applyStash(entry, delete: false) }
        Button("Apply and Delete", systemImage: "tray.and.arrow.down.fill") { workspace.applyStash(entry, delete: true) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { workspace.confirmDeleteStash(entry) }
    }

    @ViewBuilder
    private func worktreeMenu(_ entry: GitWorktreeEntry) -> some View {
        let isCurrent = workspace.isCurrentWorktree(entry)
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { workspace.openWorktree(entry) }
            .disabled(isCurrent)
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        Button("Copy Path", systemImage: "doc.on.doc") { workspace.copyToPasteboard(entry.path) }
        Divider()
        Button("Remove Worktree…", systemImage: "trash", role: .destructive) { workspace.confirmAndRemoveWorktree(entry) }
            .disabled(workspace.worktreeRemovalDisabledReason(entry) != nil)
    }
}
