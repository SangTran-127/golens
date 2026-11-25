import SwiftUI

struct GitHistoryView: View {
    @Environment(\.windowWorkspace) private var workspace
    private var store: GitRepositoryStore { workspace.repositories }
    @State private var queryText = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                commitList
                    .frame(minWidth: 320, idealWidth: 460)
                detailPane
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ThemeColor.contentSurface)
        .onAppear {
            queryText = store.historyQuery
            syncHeadHistoryTitle(with: workspace.git.branchName, reload: false)
        }
        .onChange(of: workspace.git.branchName) { _, newBranch in
            syncHeadHistoryTitle(with: newBranch, reload: true)
        }
        .onChange(of: workspace.git.recentCommits.first?.hash) {
            if let target = store.historyTarget,
               !target.isSingleCommit,
               (target.revision == "HEAD" || target.revision == workspace.git.branchName || target.revision == "refs/heads/" + workspace.git.branchName) {
                workspace.loadHistory(reset: true)
            }
        }
        .onChange(of: store.commits) { _, commits in
            if store.historyTarget?.isSingleCommit == true, let first = commits.first, store.selectedCommitHash == nil {
                workspace.selectHistoryCommit(first)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(store.historyShowsAllBranches && store.historyTarget?.isSingleCommit != true ? "All Branches" : (store.historyTarget?.title ?? "History"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if store.historyTarget?.isSingleCommit != true {
                Picker("Show", selection: Bindable(store).historyScope) {
                    ForEach(GitHistoryScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Time Range")
                .onChange(of: store.historyScope) { workspace.loadHistory(reset: true) }
                Toggle("All Branches", isOn: Bindable(store).historyShowsAllBranches)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show commits from every branch, remote branch and tag")
                    .onChange(of: store.historyShowsAllBranches) { workspace.loadHistory(reset: true) }
                TextField("Filter by message, author or hash", text: $queryText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                    .onChange(of: queryText) { _, text in
                        searchTask?.cancel()
                        searchTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            store.historyQuery = text
                            workspace.loadHistory(reset: true)
                        }
                    }
            }
            Spacer()
            Button {
                workspace.closeSourceControlSurfaceFromEscape()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close History")
            .accessibilityLabel("Close History")
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
    }

    private var commitList: some View {
        List(selection: Binding(
            get: { store.selectedCommitHash },
            set: { hash in workspace.selectHistoryCommit(store.commits.first { $0.hash == hash }) }
        )) {
            let graph = store.graph.count == store.commits.count ? store.graph : []
            let lanes = graph.lazy.map(\.width).max() ?? 0
            ForEach(Array(store.commits.enumerated()), id: \.element.id) { index, commit in
                HStack(spacing: Spacing.standard) {
                    if !graph.isEmpty {
                        GitGraphCell(row: graph[index], lanes: lanes)
                    }
                    GitRevisionRow(
                        subject: commit.subject,
                        author: commit.author,
                        date: commit.date,
                        relativeDateText: nil,
                        shortHash: commit.shortHash,
                        refs: commit.refs
                    )
                    .padding(.vertical, graph.isEmpty ? 0 : Spacing.compact)
                }
                .listRowInsets(graph.isEmpty ? nil : EdgeInsets(top: 0, leading: Spacing.standard, bottom: 0, trailing: Spacing.standard))
                .tag(commit.hash)
                .contextMenu { commitMenu(commit) }
            }
            if store.hasMoreCommits {
                Button("Load More Commits") { workspace.loadHistory(reset: false) }
                    .buttonStyle(.link)
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.commits.isEmpty {
                if store.isLoadingHistory {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ContentUnavailableView(
                        store.historyQuery.isEmpty ? "No Commits" : "No Matching Commits",
                        systemImage: "clock",
                        description: Text(store.historyQuery.isEmpty
                            ? "There are no commits in this range."
                            : "No commit message, author or hash matches “\(store.historyQuery)”.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let detail = store.detail {
            GitCommitDetailView(detail: detail)
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Select a commit to see its message and changed files."))
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: GitHistoryCommit) -> some View {
        Button("Copy Commit Message", systemImage: "doc.on.doc") {
            Task { @MainActor in
                let body = (try? await workspace.runGit(args: ["show", "-s", "--format=%B", commit.hash])) ?? commit.subject
                workspace.copyToPasteboard(body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        Button("Copy Identifier", systemImage: "number") { workspace.copyToPasteboard(commit.hash) }
        Divider()
        Button("New Branch from “\(commit.shortHash)”…", systemImage: "arrow.triangle.branch") { workspace.sourceControl.sheet = .newBranch(from: commit.hash) }
        Button("New Tag on “\(commit.shortHash)”…", systemImage: "tag") { workspace.sourceControl.sheet = .newTag(at: commit.hash) }
        Divider()
        Button("Cherry-Pick…", systemImage: "arrow.turn.down.right") { workspace.cherryPick(commit) }
            .disabled(!workspace.hasNamedBranch)
        Button("Revert Commit…", systemImage: "arrow.uturn.backward.circle") { workspace.revertCommit(commit) }
            .disabled(!workspace.hasNamedBranch)
        Button("Interactively Rebase from Here…", systemImage: "list.bullet.indent") { workspace.showInteractiveRebase(from: commit.hash) }
            .disabled(!workspace.canStartInteractiveRebase)
        Divider()
        Button("Switch to “\(commit.shortHash)”…", systemImage: "clock.arrow.circlepath") { workspace.switchToRevision(commit.hash, title: "“\(commit.shortHash)”") }
    }

    private func syncHeadHistoryTitle(with branchName: String, reload: Bool) {
        guard !branchName.isEmpty,
              let target = store.historyTarget,
              target.revision == "HEAD",
              !target.isSingleCommit,
              target.title != branchName else { return }
        store.historyTarget = GitHistoryTarget(revision: "HEAD", title: branchName)
        if reload {
            workspace.loadHistory(reset: true)
        }
    }
}

struct GitCommitDetailView: View {
    let detail: GitCommitDetail
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(detail.commit.subject)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: Spacing.row) {
                        Text("\(detail.commit.author) <\(detail.commit.email)>")
                        Text("·")
                        Text(detail.commit.date.formatted(date: .long, time: .shortened))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    HStack(spacing: Spacing.row) {
                        Text(detail.commit.hash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            workspace.copyToPasteboard(detail.commit.hash)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy Identifier")
                        .accessibilityLabel("Copy Identifier")
                        signatureBadge(detail.signature)
                    }
                }

                if !detail.body.isEmpty {
                    Text(detail.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text(detail.files.count == 1 ? "1 File Changed" : "\(detail.files.count) Files Changed")
                    .font(.headline)
                if detail.files.isEmpty {
                    Text("This commit changes no files.")
                        .foregroundStyle(.secondary)
                }
                ForEach(detail.files) { file in
                    Button {
                        workspace.openHistoryFileDiff(file, in: detail.commit)
                    } label: {
                        HStack(spacing: Spacing.standard) {
                            GitStatusBadge(status: file.status)
                            Text(file.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Text("+\(file.added) −\(file.removed)")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(file.added) lines added, \(file.removed) removed")
                        }
                        .font(.callout.monospacedDigit())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the change to \(file.relativePath) in this commit")
                }
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func signatureBadge(_ signature: CommitSignatureInfo) -> some View {
        let fp = signature.fingerprint ?? "unknown key"
        switch signature.status {
        case "G":
            HStack(spacing: Spacing.compact) {
                Image(systemName: "checkmark.seal.fill")
                    .accessibilityHidden(true)
                Text("Verified")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(StatusTone.success.tint)
            .help("Signature verified against your configured signing key in GoLens (\(fp)).")
            .accessibilityElement(children: .combine)
        case "U":
            HStack(spacing: Spacing.compact) {
                Image(systemName: "checkmark.seal")
                    .accessibilityHidden(true)
                Text("Signed")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Valid signature by key \(fp), which isn’t your configured signing key in GoLens.")
            .accessibilityElement(children: .combine)
        case "B":
            HStack(spacing: Spacing.compact) {
                Image(systemName: StatusTone.warning.symbol)
                    .accessibilityHidden(true)
                Text("Invalid Signature")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(StatusTone.warning.tint)
            .help("This commit’s signature could not be verified against its contents.")
            .accessibilityElement(children: .combine)
        default:
            EmptyView()
        }
    }
}
