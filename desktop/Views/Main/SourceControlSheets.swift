import GoLensFoundation
import SwiftUI

struct SourceControlSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    let sheet: SourceControlSheet

    var body: some View {
        switch sheet {
        case .pull: PullSheet()
        case .push: PushSheet()
        case .stash: StashSheet()
        case .newBranch(let base): NewBranchSheet(base: base)
        case .newWorktree(let branch): NewWorktreeSheet(initialBranch: branch)
        case .newTag(let revision): NewTagSheet(revision: revision)
        case .renameBranch(let branch): RenameBranchSheet(branch: branch)
        case .interactiveRebase(let from): InteractiveRebaseSheet(from: from)
        case .addRemote: AddRemoteSheet()
        case .clone: GitCloneSheetView()
        case .gitAccount(let host, let accountID):
            GitAccountSheetView(initialHost: host, editingAccountID: accountID) { _ in
                if let retry = workspace.sourceControl.pendingAuthRetry {
                    workspace.sourceControl.pendingAuthRetry = nil
                    retry()
                }
            }
        }
    }
}

private struct SourceControlSheetFrame<Content: View>: View {
    let title: String
    let message: String?
    let actionTitle: String
    let canPerform: Bool
    var size: SheetSize = .compact
    let perform: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    perform()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPerform)
            }
        }
        .padding(Spacing.section)
        .sheetFrame(size)
    }
}

private struct PullSheet: View {
    @State private var branches: [String] = []
    @State private var selection = ""
    @State private var rebase = false
    @State private var configuredRebase = false
    @State private var loaded = false
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        SourceControlSheetFrame(
            title: "Pull remote changes from:",
            message: nil,
            actionTitle: "Pull",
            canPerform: loaded && !selection.isEmpty && workspace.sourceControl.runningOperation == nil
        ) {
            workspace.pullChanges(from: selection, rebase: rebase == configuredRebase ? nil : rebase)
        } content: {
            if loaded && branches.isEmpty {
                Text("This repository has no remote branches. Add a remote, then fetch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Branch", selection: $selection) {
                    ForEach(branches, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!loaded)
            }
            Toggle("Rebase local changes onto upstream changes", isOn: $rebase)
                .disabled(!loaded)
        }
        .task {
            async let allRun = workspace.gitRemoteBranches()
            async let upstreamRun = workspace.gitUpstream()
            async let rebaseRun = workspace.gitPrefersRebase()
            let (all, upstream) = (await allRun, await upstreamRun)
            configuredRebase = await rebaseRun
            rebase = configuredRebase
            branches = all
            let named = "origin/\(workspace.git.branchName)"
            selection = [upstream, named].compactMap { $0 }.first(where: all.contains) ?? all.first ?? ""
            loaded = true
        }
    }
}

private struct PushSheet: View {
    @State private var remotes: [String] = []
    @State private var selection = ""
    @State private var includeTags = false
    @State private var upstream: (remote: String, branch: String)?
    @State private var loaded = false
    @Environment(\.windowWorkspace) private var workspace

    private var message: String? {
        let branch = workspace.git.branchName
        guard loaded else { return nil }
        guard let upstream else { return "“\(branch)” isn’t on a remote yet. Pushing creates it there and tracks it." }
        return upstream.remote == selection ? nil : "Pushing to “\(selection)” makes “\(selection)/\(branch)” the upstream of “\(branch)”."
    }

    var body: some View {
        let branch = workspace.git.branchName
        SourceControlSheetFrame(
            title: "Push local changes to:",
            message: message,
            actionTitle: "Push",
            canPerform: loaded && !selection.isEmpty && workspace.hasNamedBranch && workspace.sourceControl.runningOperation == nil
        ) {
            workspace.pushChanges(to: selection, includeTags: includeTags)
        } content: {
            if loaded && remotes.isEmpty {
                Text("This repository has no remote to push to. Add one with git remote add origin <URL>.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Remote", selection: $selection) {
                    ForEach(remotes, id: \.self) { remote in
                        Text("\(remote)/\(upstream.map { $0.remote == remote ? $0.branch : branch } ?? branch)").tag(remote)
                    }
                }
                .disabled(!loaded)
            }
            Toggle("Include tags", isOn: $includeTags)
                .disabled(!loaded)
        }
        .task {
            let all = await workspace.gitRemotes()
            upstream = await workspace.gitUpstreamRef()
            remotes = all
            selection = upstream.flatMap { all.contains($0.remote) ? $0.remote : nil } ?? (all.contains("origin") ? "origin" : all.first ?? "")
            loaded = true
        }
    }
}

private struct StashSheet: View {
    @State private var message = ""
    @FocusState private var isMessageFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        SourceControlSheetFrame(
            title: "Stash Changes",
            message: "Enter a description for your stashed changes so you can reference them later. Stashes appear in the Source Control navigator.",
            actionTitle: "Stash",
            canPerform: true
        ) {
            let text = message
            Task { @MainActor in
                do {
                    _ = try await workspace.gitStashSave(message: text)
                } catch {
                    workspace.presentGitAlert("Couldn’t Stash Changes", error.localizedDescription)
                }
            }
        } content: {
            TextField("Optional message", text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($isMessageFocused)
        }
        .onAppear { isMessageFocused = true }
    }
}

private func isValidRefName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) }) && !name.hasPrefix("-") && !name.contains("..")
        && !name.hasSuffix("/") && !name.hasSuffix(".") && !name.hasSuffix(".lock") && !name.contains("@{") && !name.contains("//")
}

struct GitRefNameField: View {
    let prompt: String
    @Binding var name: String
    var isFocused: FocusState<Bool>.Binding? = nil

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let isFocused {
                TextField(prompt, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused(isFocused)
            } else {
                TextField(prompt, text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            if !trimmed.isEmpty && !isValidRefName(trimmed) {
                Text("Names can’t contain spaces, backslashes, the symbols ~ ^ : ? * [, two dots, or end with a slash, a dot or .lock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NewBranchSheet: View {
    let base: String?
    @State private var name = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let from = base ?? workspace.git.branchName
        SourceControlSheetFrame(
            title: "New Branch",
            message: "Create a branch from “\(from)” and switch to it. Uncommitted changes are kept on the new branch.",
            actionTitle: "Create",
            canPerform: isValidRefName(trimmed)
        ) {
            workspace.runRepositoryAction("Couldn’t Create “\(trimmed)”") {
                _ = try await workspace.runGit(args: ["switch", "-c", trimmed] + (base.map { [$0] } ?? []))
                await workspace.refreshBlameHead()
                workspace.reloadCleanOpenDocumentsFromDisk()
                workspace.refreshActiveFileDiff()
                workspace.updateCaretLineBlame()
                workspace.reloadRepositoryRefs()
            }
        } content: {
            GitRefNameField(prompt: "Branch name", name: $name, isFocused: $isNameFocused)
        }
        .onAppear { isNameFocused = true }
    }
}

private struct NewWorktreeSheet: View {
    private enum CreationMode: String, CaseIterable, Identifiable {
        case newBranch
        case existingBranch

        var id: String { rawValue }
        var title: String { self == .newBranch ? "New Branch" : "Existing Branch" }
    }

    let initialBranch: String?
    @State private var mode: CreationMode = .newBranch
    @State private var newBranchName = ""
    @State private var selectedExistingBranch = ""
    @State private var selectedBaseRef = ""
    @State private var destinationPath = ""
    @State private var didCustomizeDestination = false
    @State private var openInNewWindow = true
    @FocusState private var isBranchFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    private var localBranches: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in workspace.repositories.branches.map(\.name) + workspace.git.branches {
            if !name.isEmpty && seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    private var baseOptions: [String] {
        var opts = localBranches
        if let initialBranch, !initialBranch.isEmpty, !opts.contains(initialBranch) {
            opts.insert(initialBranch, at: 0)
        }
        return opts
    }

    private var trimmedNewBranch: String {
        newBranchName.trimmingCharacters(in: .whitespaces)
    }

    private var effectiveBranchName: String {
        mode == .newBranch ? trimmedNewBranch : selectedExistingBranch
    }

    private var trimmedDestination: String {
        destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canPerform: Bool {
        guard !trimmedDestination.isEmpty else { return false }
        if mode == .newBranch {
            return isValidRefName(trimmedNewBranch)
        }
        return !selectedExistingBranch.isEmpty
    }

    var body: some View {
        SourceControlSheetFrame(
            title: "New Worktree",
            message: "Check out a branch in a separate folder so you can work on two branches at once.",
            actionTitle: "Create Worktree",
            canPerform: canPerform,
            size: .standard
        ) {
            workspace.createWorktree(
                branchName: effectiveBranchName,
                createNewBranch: mode == .newBranch,
                baseRef: mode == .newBranch ? selectedBaseRef : nil,
                destinationPath: trimmedDestination,
                openInNewWindow: openInNewWindow
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                Picker("Branch Mode", selection: $mode) {
                    ForEach(CreationMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Worktree branch mode")

                if mode == .newBranch {
                    GitRefNameField(prompt: "Branch name", name: $newBranchName, isFocused: $isBranchFocused)
                    if !baseOptions.isEmpty {
                        Picker("Start from", selection: $selectedBaseRef) {
                            ForEach(baseOptions, id: \.self) { ref in
                                Text(ref).tag(ref)
                            }
                        }
                    }
                } else if localBranches.isEmpty {
                    Text("No local branches are available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Branch", selection: $selectedExistingBranch) {
                        ForEach(localBranches, id: \.self) { branch in
                            Text(branch).tag(branch)
                        }
                    }
                    if let activeWorktree = workspace.worktree(forBranch: selectedExistingBranch) {
                        Text("Already checked out in “\(activeWorktree.folderName)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("Folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.standard) {
                        TextField("Destination folder", text: $destinationPath)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Destination folder")
                            .onChange(of: destinationPath) { _, newValue in
                                let suggested = suggestedPath()
                                if newValue != suggested {
                                    didCustomizeDestination = true
                                }
                            }
                        Button("Choose…") {
                            chooseDestination()
                        }
                    }
                }

                Toggle("Open in New Window", isOn: $openInNewWindow)
            }
        }
        .onAppear {
            configureInitialState()
            workspace.reloadRepositoryRefs()
        }
        .onChange(of: newBranchName) { syncSuggestedDestination() }
        .onChange(of: selectedExistingBranch) { syncSuggestedDestination() }
        .onChange(of: mode) { syncSuggestedDestination() }
    }

    private func suggestedPath() -> String {
        let name = effectiveBranchName
        let seed = name.isEmpty ? "worktree" : name
        return GitWorktreeParser.defaultSiblingPath(repoPath: workspace.activeWorkspacePath, branchName: seed)
    }

    private func syncSuggestedDestination() {
        guard !didCustomizeDestination else { return }
        destinationPath = suggestedPath()
    }

    private func configureInitialState() {
        let branches = localBranches
        let current = workspace.git.branchName
        let defaultBase = (!current.isEmpty && current != "Detached HEAD") ? current : (branches.first ?? "")

        if let initialBranch, !initialBranch.isEmpty {
            let isCheckedOut = initialBranch == current || workspace.worktree(forBranch: initialBranch) != nil
            if branches.contains(initialBranch), !isCheckedOut {
                mode = .existingBranch
                selectedExistingBranch = initialBranch
                selectedBaseRef = initialBranch
            } else {
                mode = .newBranch
                selectedBaseRef = initialBranch
                selectedExistingBranch = branches.first(where: { $0 != current && workspace.worktree(forBranch: $0) == nil }) ?? branches.first ?? ""
            }
        } else {
            mode = .newBranch
            selectedBaseRef = defaultBase
            selectedExistingBranch = branches.first(where: { $0 != current && workspace.worktree(forBranch: $0) == nil }) ?? branches.first ?? ""
        }

        destinationPath = suggestedPath()
        if mode == .newBranch {
            isBranchFocused = true
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        let currentURL = URL(fileURLWithPath: (trimmedDestination as NSString).deletingLastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            panel.directoryURL = currentURL
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let leaf = (suggestedPath() as NSString).lastPathComponent
        didCustomizeDestination = true
        destinationPath = url.appendingPathComponent(leaf.isEmpty ? "worktree" : leaf).path
    }
}

private struct NewTagSheet: View {
    let revision: String
    @State private var name = ""
    @State private var message = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        SourceControlSheetFrame(
            title: "New Tag on “\(revision.count == 40 ? String(revision.prefix(7)) : revision)”",
            message: "A tag with a message is annotated; without one it is a lightweight tag.",
            actionTitle: "Create",
            canPerform: isValidRefName(trimmed)
        ) {
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.runRepositoryAction("Couldn’t Create the Tag “\(trimmed)”") {
                _ = try await workspace.gitCreateTag(name: trimmed, revision: revision, message: text)
            }
        } content: {
            GitRefNameField(prompt: "Tag", name: $name, isFocused: $isNameFocused)
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
        }
        .onAppear { isNameFocused = true }
    }
}

private struct RenameBranchSheet: View {
    let branch: String
    @State private var name = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        SourceControlSheetFrame(
            title: "Rename “\(branch)”",
            message: "Uncommitted changes stay as they are. The branch on a remote keeps its old name.",
            actionTitle: "Rename",
            canPerform: isValidRefName(trimmed) && trimmed != branch
        ) {
            workspace.runRepositoryAction("Couldn’t Rename “\(branch)”") {
                let args = (branch == workspace.git.branchName && workspace.git.recentCommits.isEmpty)
                    ? ["branch", "-m", trimmed]
                    : ["branch", "-m", branch, trimmed]
                _ = try await workspace.runGit(args: args)
            }
        } content: {
            GitRefNameField(prompt: "New name", name: $name, isFocused: $isNameFocused)
        }
        .onAppear {
            name = branch
            isNameFocused = true
        }
    }
}

private struct AddRemoteSheet: View {
    @State private var name = "origin"
    @State private var url = ""
    @FocusState private var isNameFocused: Bool
    @FocusState private var isURLFocused: Bool
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        SourceControlSheetFrame(
            title: "Add Existing Remote",
            message: "Connect this repository to a repository on a server, then fetch its branches.",
            actionTitle: "Add",
            canPerform: isValidRefName(trimmedName) && !trimmedURL.isEmpty
        ) {
            workspace.runRepositoryAction("Couldn’t Add “\(trimmedName)”") {
                _ = try await workspace.runGit(args: ["remote", "add", trimmedName, trimmedURL])
            }
        } content: {
            GitRefNameField(prompt: "Name", name: $name, isFocused: $isNameFocused)
            TextField("URL, for example git@github.com:owner/repo.git", text: $url)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFocused)
        }
        .onAppear {
            if name.isEmpty {
                isNameFocused = true
            } else {
                isURLFocused = true
            }
        }
    }
}

struct GitAccountSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    let initialHost: String?
    let editingAccountID: UUID?
    var onComplete: ((GitAccount) -> Void)? = nil

    private enum Field: Hashable {
        case serverURL
        case token
    }

    @Environment(\.dismiss) private var dismiss
    private let accountStore = GitAccountStore.shared

    @State private var providerKind: GitAccountProviderKind = .githubCloud
    @State private var serverURL: String = ""
    @State private var token: String = ""
    @State private var errorMessage: String = ""
    @FocusState private var focusedField: Field?

    private var editingAccount: GitAccount? {
        guard let editingAccountID else { return nil }
        return accountStore.accounts.first(where: { $0.id == editingAccountID })
    }

    private var canSubmit: Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty, !accountStore.isVerifying else { return false }
        if providerKind.usesCustomServerURL {
            return !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var targetHostDisplay: String {
        if let editingAccount {
            return editingAccount.host
        }
        if providerKind.usesCustomServerURL {
            let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let host = URL(string: trimmed)?.host, !host.isEmpty {
                return host
            }
            return trimmed.isEmpty ? providerKind.shortServiceName : trimmed
        }
        return providerKind.defaultHost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(editingAccount != nil ? "Update Personal Access Token" : "Add Source Control Account")
                    .font(.headline)
                Text(
                    editingAccount.map {
                        "Enter a new Personal Access Token for @\($0.username) on \($0.host)."
                    } ?? "Sign in with a Personal Access Token to clone, fetch, pull, and push repositories over HTTPS."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                HStack(spacing: Spacing.inset) {
                    GitAccountServiceIconView(providerKind: providerKind, size: 18)
                    Picker("Service", selection: $providerKind) {
                        ForEach(GitAccountProviderKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .disabled(editingAccount != nil || accountStore.isVerifying)
                    .accessibilityIdentifier("git-account-service-picker")
                }

                if providerKind.usesCustomServerURL {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("Server URL")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("", text: $serverURL, prompt: Text(providerKind.serverPlaceholder))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .serverURL)
                            .disabled(editingAccount != nil || accountStore.isVerifying)
                            .accessibilityLabel("Server URL")
                            .accessibilityIdentifier("git-account-server-url-field")
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.row) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Personal Access Token")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let tokenURL = accountStore.tokenCreationURL(for: providerKind, serverURL: serverURL) {
                            Button(providerKind.createTokenButtonTitle) {
                                NSWorkspace.shared.open(tokenURL)
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .disabled(accountStore.isVerifying)
                            .accessibilityIdentifier("git-account-create-token-link")
                        }
                    }

                    SecureField("", text: $token, prompt: Text(providerKind.tokenPlaceholder))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .token)
                        .disabled(accountStore.isVerifying)
                        .onSubmit {
                            if canSubmit { submit() }
                        }
                        .accessibilityLabel("Personal Access Token")
                        .accessibilityIdentifier("git-account-token-field")

                    Text(providerKind.requiredScopesSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if accountStore.isVerifying {
                    HStack(spacing: Spacing.standard) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying account with \(targetHostDisplay)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if !errorMessage.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("git-account-error-label")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if editingAccount == nil {
                        workspace.sourceControl.pendingAuthRetry = nil
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(accountStore.isVerifying)

                Button(editingAccount != nil ? "Update Token" : "Sign In") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("git-account-submit-button")
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.compact)
        .onAppear {
            configureInitialFields()
        }
        .onChange(of: providerKind) { _, newKind in
            errorMessage = ""
            if !newKind.usesCustomServerURL {
                serverURL = newKind.defaultServerURL
                focusedField = .token
            } else if serverURL == GitAccountProviderKind.githubCloud.defaultServerURL
                        || serverURL == GitAccountProviderKind.gitlabCloud.defaultServerURL {
                serverURL = ""
                focusedField = .serverURL
            }
        }
    }

    private func configureInitialFields() {
        if let editingAccount {
            providerKind = editingAccount.providerKind
            serverURL = editingAccount.serverURL
            focusedField = .token
            return
        }
        if let initialHost, !initialHost.isEmpty {
            let lower = initialHost.lowercased()
            if lower == "github.com" {
                providerKind = .githubCloud
                serverURL = providerKind.defaultServerURL
            } else if lower == "gitlab.com" {
                providerKind = .gitlabCloud
                serverURL = providerKind.defaultServerURL
            } else if lower.contains("gitlab") {
                providerKind = .gitlabSelfHosted
                serverURL = "https://\(lower)"
            } else {
                providerKind = .githubEnterprise
                serverURL = "https://\(lower)"
            }
        } else {
            providerKind = .githubCloud
            serverURL = providerKind.defaultServerURL
        }
        focusedField = (providerKind.usesCustomServerURL && serverURL.isEmpty) ? .serverURL : .token
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = ""
        let selectedKind = providerKind
        let selectedServer = serverURL
        let rawToken = token
        let existingID = editingAccount?.id

        Task { @MainActor in
            do {
                let account = try await accountStore.signInWithToken(
                    providerKind: selectedKind,
                    serverURL: selectedServer,
                    token: rawToken,
                    updatingAccountID: existingID
                )
                onComplete?(account)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
