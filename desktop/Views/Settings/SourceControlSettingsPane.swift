import GoLensFoundation
import SwiftUI

private struct IgnoredPattern: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var saved: String?
}

private enum ExcludesFile {
    case lines([String])
    case unavailable(String)
}

private enum ExcludesChange {
    case add(String)
    case remove(saved: String, occurrence: Int)
    case replace(saved: String, occurrence: Int, text: String)
}

struct SourceControlSettingsPane: View {
    enum GitConfigScope: String, CaseIterable, Identifiable {
        case repository = "This Repository (.git/config)"
        case global = "Global (~/.gitconfig)"

        var id: String { rawValue }
    }

    private enum Field: Hashable {
        case name, email, pattern(UUID)
    }

    private struct AccountSheetRequest: Identifiable {
        let id = UUID()
        let host: String?
        let accountID: UUID?
    }

    private let workspace = WorkspaceState.shared
    private let accountStore = GitAccountStore.shared
    @Bindable private var signingStore = GitSigningStore.shared
    @AppStorage(WorkspaceState.showSourceControlChangesKey) private var showChanges = true
    @AppStorage(WorkspaceState.comparisonLocalOnLeftKey) private var localOnLeft = false
    @AppStorage(WorkspaceState.refreshGitStatusAutomaticallyKey) private var refreshStatus = true
    @AppStorage(WorkspaceState.fetchAutomaticallyKey) private var fetchAutomatically = false

    @State private var gitConfigScope: GitConfigScope = WorkspaceState.shared.isGitRepositoryOpen ? .repository : .global
    @State private var hasExplicitScopeChoice = false
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var savedName = ""
    @State private var savedEmail = ""
    @State private var prefersRebase = false
    @State private var globalPersistedName = ""
    @State private var globalPersistedEmail = ""
    @State private var globalPersistedRebase = false
    @State private var localPersistedName = ""
    @State private var localPersistedEmail = ""
    @State private var localPersistedRebase = false
    @State private var writeQueue: Task<Void, Never>?
    @State private var saveError: String?
    @State private var removeError: String?
    @State private var excludesPath = ""
    @State private var excludesFailure: String?
    @State private var isLoaded = false
    @State private var patterns: [IgnoredPattern] = []
    @State private var selection: UUID?
    @State private var editing: UUID?
    @State private var accountSheetRequest: AccountSheetRequest?
    @State private var accountPendingRemoval: GitAccount?
    @State private var verifyingAccountID: UUID?
    @FocusState private var focus: Field?

    private var repositoryKey: String {
        "\(workspace.activeWorkspacePath)|\(workspace.git.isRepository == true)"
    }

    private var repositoryOverride: String {
        var parts: [String] = []
        if !localPersistedName.isEmpty, localPersistedName != globalPersistedName { parts.append(localPersistedName) }
        if !localPersistedEmail.isEmpty, localPersistedEmail != globalPersistedEmail { parts.append(localPersistedEmail) }
        return parts.joined(separator: " ")
    }

    private var globalSummary: String {
        [globalPersistedName, globalPersistedEmail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var scopeBinding: Binding<GitConfigScope> {
        Binding(
            get: { gitConfigScope },
            set: { switchScope(to: $0) }
        )
    }

    private var canEditExcludes: Bool {
        isLoaded && excludesFailure == nil
    }

    private var saveErrorShown: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var rebaseBinding: Binding<Bool> {
        Binding(get: { prefersRebase }, set: { setRebase($0) })
    }

    var body: some View {
        SettingsForm {
            gitSection
            commitSigningSection
            accountsSection
            editorSection
            statusSection
            ignoredFilesSection
        }
        .sheet(item: $accountSheetRequest) { req in
            GitAccountSheetView(initialHost: req.host, editingAccountID: req.accountID)
        }
        .alert(
            accountPendingRemoval.map { "Remove “@\($0.username)” on \($0.host)?" } ?? "Remove Account?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            )
        ) {
            Button("Remove Account", role: .destructive) {
                if let account = accountPendingRemoval {
                    do {
                        try accountStore.removeAccount(id: account.id)
                    } catch {
                        removeError = error.localizedDescription
                    }
                }
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: {
            if let account = accountPendingRemoval {
                Text("Removes the Personal Access Token for @\(account.username) from your macOS Keychain. Local repositories on your Mac are not affected.")
            }
        }
        .alert("Couldn’t Save the Setting", isPresented: saveErrorShown) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
        .alert("Couldn’t Remove the Account", isPresented: Binding(
            get: { removeError != nil },
            set: { if !$0 { removeError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(removeError ?? "")
        }
        .task { await loadGlobalSettings() }
        .task(id: repositoryKey) { await loadRepositoryOverride() }
        .onChange(of: focus) { old, _ in focusChanged(from: old) }
        .onDisappear {
            saveAuthorName()
            saveAuthorEmail()
            finishEditing()
        }
    }

    private var accountsSection: some View {
        SettingsSection("Accounts", footer: "Personal Access Tokens are stored in your macOS Keychain and used automatically when cloning, fetching, pulling, and pushing over HTTPS.") {
            if accountStore.accounts.isEmpty {
                SettingsNote("No accounts connected") {
                    addAccountButton
                }
            } else {
                ForEach(accountStore.accounts) { account in
                    accountRow(account)
                }
                SettingsActionRow {
                    addAccountButton
                }
            }
        }
    }

    private var addAccountButton: some View {
        Button("Add Account…") {
            accountSheetRequest = AccountSheetRequest(host: nil, accountID: nil)
        }
        .accessibilityIdentifier("source-control-add-account-button")
    }

    @ViewBuilder
    private func accountRow(_ account: GitAccount) -> some View {
        SettingsItemRow(account.formattedIdentity, subtitle: "\(account.providerKind.title) · \(account.host)") {
            GitAccountServiceIconView(providerKind: account.providerKind, size: 18)
        } badges: {
            EmptyView()
        } accessory: {
            if verifyingAccountID == account.id {
                SettingsStatus(busy: "Verifying…")
            } else if account.statusSummary == "Connected" {
                SettingsStatus(
                    accountStore.usesKeychainStore ? "Connected · Keychain" : "Connected",
                    symbol: accountStore.usesKeychainStore ? "lock.fill" : "checkmark.circle.fill",
                    tint: .secondary
                )
            } else {
                SettingsStatus(account.statusSummary, tone: .warning)
                Button("Update Token…") {
                    accountSheetRequest = AccountSheetRequest(host: account.host, accountID: account.id)
                }
            }

            Menu {
                Button("Verify Connection", systemImage: "checkmark.shield") {
                    verifyAccount(account)
                }
                Button("Update Token…", systemImage: "key") {
                    accountSheetRequest = AccountSheetRequest(host: account.host, accountID: account.id)
                }
                if let profileURL = URL(string: "\(account.serverURL)/\(account.username)") {
                    Button("Open on \(account.providerKind.shortServiceName)", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(profileURL)
                    }
                }
                Divider()
                Button("Remove Account…", systemImage: "trash", role: .destructive) {
                    accountPendingRemoval = account
                }
            } label: {
                Label("Account Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Account management options")
            .accessibilityLabel("Account management options for \(account.username)")
            .accessibilityIdentifier("source-control-account-menu-\(account.username)")
        }
    }

    private func verifyAccount(_ account: GitAccount) {
        verifyingAccountID = account.id
        Task { @MainActor in
            await accountStore.verifyExistingAccount(id: account.id)
            if verifyingAccountID == account.id {
                verifyingAccountID = nil
            }
        }
    }

    private var gitSection: some View {
        let footerText = gitConfigScope == .repository
            ? "Saved in .git/config for the current repository only."
            : "Saved in your global Git configuration and used by every repository."
        let namePrompt = (gitConfigScope == .repository && !globalPersistedName.isEmpty) ? globalPersistedName : "Your name"
        let emailPrompt = (gitConfigScope == .repository && !globalPersistedEmail.isEmpty) ? globalPersistedEmail : "you@example.com"

        return SettingsSection("Git", footer: footerText) {
            SettingsFieldRow("Scope") {
                Picker("Git Configuration Scope", selection: scopeBinding) {
                    ForEach(GitConfigScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!workspace.isGitRepositoryOpen)
                .accessibilityLabel("Git Configuration Scope")
            } help: {
                if !workspace.isGitRepositoryOpen {
                    SettingsFieldHelp("Open a Git repository to edit repository-local Git configuration.")
                }
            }

            SettingsFieldRow("Author Name") {
                TextField("", text: $authorName, prompt: Text(namePrompt))
                    .settingsTextField()
                    .focused($focus, equals: .name)
                    .onSubmit { saveAuthorName() }
                    .accessibilityLabel("Author Name")
            }

            SettingsFieldRow("Author Email") {
                TextField("", text: $authorEmail, prompt: Text(emailPrompt))
                    .settingsTextField()
                    .focused($focus, equals: .email)
                    .onSubmit { saveAuthorEmail() }
                    .accessibilityLabel("Author Email")
            }

            if gitConfigScope == .global, !repositoryOverride.isEmpty {
                SettingsNote("This repository uses \(repositoryOverride).")
            } else if gitConfigScope == .repository, !globalSummary.isEmpty {
                if localPersistedName.isEmpty && localPersistedEmail.isEmpty {
                    SettingsNote("Inherits global Git identity (\(globalSummary)) until overridden for this repository.")
                } else {
                    SettingsNote("Global fallback: \(globalSummary).")
                }
            }

            Toggle("Prefer to Rebase When Pulling", isOn: rebaseBinding)
                .accessibilityLabel("Prefer to Rebase When Pulling")
        }
    }

    private var commitSigningSection: some View {
        SettingsSection(
            "Commit Signing",
            footer: "Applies to commits and annotated tags created in GoLens. Your global Git configuration for Terminal is not modified."
        ) {
            Toggle("Sign Commits and Tags", isOn: $signingStore.isSigningEnabled)
                .accessibilityLabel("Sign Commits and Tags")

            if signingStore.isSigningEnabled {
                SettingsFieldRow("Signing Key") {
                    Picker("Signing Key", selection: $signingStore.selectedKeyPath) {
                        if signingStore.availableKeys.isEmpty {
                            Text("No SSH Keys Found").tag("")
                        }
                        ForEach(signingStore.availableKeys) { key in
                            Text(key.displayTitle).tag(key.path)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Signing Key")
                } help: {
                    if let selected = signingStore.selectedKey {
                        SettingsFieldHelp(selected.fingerprintSubtitle, systemImage: selected.isSecurityKey ? "key.horizontal" : "key")
                    } else {
                        SettingsFieldHelp("Generate a security key in Terminal with ssh-keygen -t ed25519-sk, or choose an existing key file.")
                    }
                }

                if !signingStore.hasHomebrewOpenSSH {
                    SettingsNote(
                        "OpenSSH from Homebrew is required to sign with a security key (brew install openssh).",
                        systemImage: "exclamationmark.triangle.fill"
                    ) {
                        Button("Copy Command") {
                            workspace.copyToPasteboard("brew install openssh")
                        }
                    }
                }

                if let tokenIssue = signingStore.tokenPermissionIssue {
                    SettingsNote(tokenIssue.message, systemImage: "exclamationmark.triangle.fill") {
                        HStack(spacing: SettingsMetrics.rowSpacing) {
                            if let url = tokenIssue.tokenCreationURL {
                                Button("Create New Token…") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Update Token…") {
                                accountSheetRequest = AccountSheetRequest(host: tokenIssue.host, accountID: tokenIssue.accountID)
                            }
                        }
                    }
                }

                if let statusMsg = signingStore.uploadStatusMessage {
                    SettingsNote(statusMsg, systemImage: "checkmark.circle.fill")
                } else if let errorMsg = signingStore.uploadErrorMessage {
                    SettingsNote(errorMsg, systemImage: "exclamationmark.triangle.fill")
                }

                SettingsActionRow {
                    HStack(spacing: SettingsMetrics.rowSpacing) {
                        Button("Choose Key File…") {
                            signingStore.chooseKeyFileWithOpenPanel()
                        }
                        if signingStore.availableKeys.isEmpty {
                            Button("Copy Keygen Command") {
                                let email = authorEmail.isEmpty ? "you@example.com" : authorEmail
                                workspace.copyToPasteboard("ssh-keygen -t ed25519-sk -C \"\(email)\"")
                            }
                        }
                    }
                } trailing: {
                    uploadSigningKeyControls
                }
            }
        }
    }

    @ViewBuilder
    private var uploadSigningKeyControls: some View {
        if signingStore.selectedKey != nil, !accountStore.accounts.isEmpty {
            if accountStore.accounts.count == 1, let account = accountStore.accounts.first {
                if signingStore.uploadingAccountID == account.id {
                    SettingsStatus(busy: "Uploading…")
                } else if signingStore.isKeyUploaded(for: account) {
                    SettingsStatus("Added to @\(account.username)", symbol: "checkmark.circle.fill", tint: .secondary)
                } else {
                    Button("Add Key to \(account.providerKind.shortServiceName)") {
                        Task { await signingStore.uploadSigningKey(to: account) }
                    }
                }
            } else {
                Menu("Add Signing Key to Account") {
                    ForEach(accountStore.accounts) { account in
                        Button {
                            Task { await signingStore.uploadSigningKey(to: account) }
                        } label: {
                            if signingStore.isKeyUploaded(for: account) {
                                Text("\(account.formattedIdentity) (\(account.host)) — Added")
                            } else {
                                Text("\(account.formattedIdentity) (\(account.host))")
                            }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var editorSection: some View {
        SettingsSection("Editor", footer: "Change bars in the editor gutter mark added, modified and removed lines. The comparison view sets which side of a side-by-side diff shows your file.") {
            Toggle("Show Source Control Changes", isOn: $showChanges)
                .accessibilityLabel("Show Source Control Changes")
                .onChange(of: showChanges) { _, _ in workspace.redrawSourceControlChanges() }

            Picker("Comparison View", selection: $localOnLeft) {
                Text("Local Revision on Left Side").tag(true)
                Text("Local Revision on Right Side").tag(false)
            }
            .accessibilityLabel("Comparison View")
        }
    }

    private var statusSection: some View {
        SettingsSection("Status", footer: "With automatic refresh off, Refresh File Status in the Source Control menu updates the Changes navigator. Fetching runs every 15 minutes for repositories with a remote.") {
            Toggle("Refresh Local Status Automatically", isOn: $refreshStatus)
                .accessibilityLabel("Refresh Local Status Automatically")
                .onChange(of: refreshStatus) { _, isOn in
                    if isOn { workspace.scheduleGitStatusRefresh() }
                }

            Toggle("Fetch and Refresh Server Status Automatically", isOn: $fetchAutomatically)
                .accessibilityLabel("Fetch and Refresh Server Status Automatically")
                .onChange(of: fetchAutomatically) { _, _ in workspace.updateAutoFetchTimer() }
        }
    }

    private var ignoredFilesSection: some View {
        SettingsSection("Ignored Files", footer: "Files matching these patterns are ignored in every repository.") {
            ignoredList
            if let failure = excludesFailure {
                excludesFailureNote(failure)
            }
            HStack(spacing: SettingsMetrics.compactSpacing) {
                Button(action: addPattern) {
                    Image(systemName: "plus")
                }
                .help("Add Pattern")
                .accessibilityLabel("Add Pattern")
                .disabled(!canEditExcludes)

                Button(action: removeSelectedPattern) {
                    Image(systemName: "minus")
                }
                .help("Remove Pattern")
                .accessibilityLabel("Remove Pattern")
                .disabled(selection == nil || !canEditExcludes)

                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    private var ignoredList: some View {
        List(selection: $selection) {
            ForEach($patterns) { $pattern in
                patternRow($pattern)
                    .tag(pattern.id)
            }
        }
        .listStyle(.bordered)
        .frame(height: 128)
        .help(excludesPath)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if canEditExcludes, let id = ids.first {
                Button("Edit Pattern", systemImage: "pencil") { beginEditing(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { beginEditing(id) }
        }
        .onDeleteCommand(perform: removeSelectedPattern)
        .onKeyPress(.return) {
            guard let id = selection, editing == nil, canEditExcludes else { return .ignored }
            beginEditing(id)
            return .handled
        }
        .overlay {
            if isLoaded, excludesFailure == nil, patterns.isEmpty {
                Text("No Patterns")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func excludesFailureNote(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Text(message)
            Text(excludesPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func patternRow(_ pattern: Binding<IgnoredPattern>) -> some View {
        let id: UUID = pattern.wrappedValue.id
        if editing == id {
            TextField("Pattern", text: pattern.text)
                .font(.body.monospaced())
                .focused($focus, equals: .pattern(id))
                .onSubmit { finishEditing() }
                .accessibilityLabel("Pattern")
        } else {
            Text(pattern.wrappedValue.text)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel(pattern.wrappedValue.text)
                .accessibilityHint("Double-click or press Return to edit")
                .accessibilityAction(named: "Edit Pattern") { beginEditing(id) }
        }
    }

    private func focusChanged(from old: Field?) {
        switch old {
        case .name: saveAuthorName()
        case .email: saveAuthorEmail()
        case .pattern(let id):
            if editing == id { finishEditing() }
        case nil: break
        }
    }

    private func globalConfig() async -> [String: String] {
        let output: String? = try? await workspace.runGit(args: ["config", "--global", "--includes", "--list", "-z"], in: NSHomeDirectory())
        return Self.parseNullSeparatedConfig(output)
    }

    private func localConfig() async -> [String: String] {
        guard workspace.isGitRepositoryOpen, !workspace.activeWorkspacePath.isEmpty else { return [:] }
        let output: String? = try? await workspace.runGit(args: ["config", "--local", "--list", "-z"], in: workspace.activeWorkspacePath)
        return Self.parseNullSeparatedConfig(output)
    }

    private static func parseNullSeparatedConfig(_ output: String?) -> [String: String] {
        var values: [String: String] = [:]
        for entry in (output ?? "").split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        return values
    }

    private func switchScope(to newScope: GitConfigScope) {
        guard newScope != gitConfigScope else { return }
        if newScope == .repository && !workspace.isGitRepositoryOpen { return }
        saveAuthorName(for: gitConfigScope)
        saveAuthorEmail(for: gitConfigScope)
        hasExplicitScopeChoice = true
        gitConfigScope = newScope
        syncActiveScopeFields()
    }

    private func syncActiveScopeFields() {
        switch gitConfigScope {
        case .repository:
            authorName = localPersistedName
            savedName = localPersistedName
            authorEmail = localPersistedEmail
            savedEmail = localPersistedEmail
            prefersRebase = localPersistedRebase
        case .global:
            authorName = globalPersistedName
            savedName = globalPersistedName
            authorEmail = globalPersistedEmail
            savedEmail = globalPersistedEmail
            prefersRebase = globalPersistedRebase
        }
    }

    private func writeConfig(_ key: String, _ value: String, scope: GitConfigScope) async -> Bool {
        let flag = scope == .global ? "--global" : "--local"
        let dir = scope == .global ? NSHomeDirectory() : workspace.activeWorkspacePath
        guard scope == .global || (workspace.isGitRepositoryOpen && !dir.isEmpty) else { return false }
        do {
            if value.isEmpty {
                _ = try await workspace.runGit(args: ["config", flag, "--unset-all", key], in: dir)
            } else {
                _ = try await workspace.runGit(args: ["config", flag, key, value], in: dir)
            }
            return true
        } catch let error as NSError where value.isEmpty && error.code == 5 {
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func writeRebase(_ on: Bool, scope: GitConfigScope) async -> Bool {
        if on {
            let flag = scope == .global ? "--global" : "--local"
            let dir = scope == .global ? NSHomeDirectory() : workspace.activeWorkspacePath
            let args = scope == .global
                ? ["config", flag, "--includes", "--get", "pull.rebase"]
                : ["config", flag, "--get", "pull.rebase"]
            let current: String = (try? await workspace.runGit(args: args, in: dir)) ?? ""
            if WorkspaceState.isRebaseValue(current) { return true }
        }
        return await writeConfig("pull.rebase", on ? "true" : "false", scope: scope)
    }

    private func enqueueWrite(_ operation: @escaping @MainActor () async -> Void) {
        let previous: Task<Void, Never>? = writeQueue
        writeQueue = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func loadGlobalSettings() async {
        let config: [String: String] = await globalConfig()
        let name: String = config["user.name"] ?? ""
        let email: String = config["user.email"] ?? ""
        let rebase: Bool = WorkspaceState.isRebaseValue(config["pull.rebase"] ?? "")
        if writeQueue == nil {
            globalPersistedName = name
            globalPersistedEmail = email
            globalPersistedRebase = rebase
            if gitConfigScope == .global {
                syncActiveScopeFields()
            }
        }
        let configured: String = config["core.excludesfile"] ?? ""
        excludesPath = GitExcludesFileHelper.resolvePath(
            configuredValue: configured,
            workspacePath: workspace.activeWorkspacePath
        )
        loadExcludes()
    }

    private func loadRepositoryOverride() async {
        guard workspace.isGitRepositoryOpen else {
            localPersistedName = ""
            localPersistedEmail = ""
            localPersistedRebase = false
            if gitConfigScope == .repository {
                gitConfigScope = .global
                syncActiveScopeFields()
            }
            return
        }
        let config: [String: String] = await localConfig()
        localPersistedName = (config["user.name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        localPersistedEmail = (config["user.email"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        localPersistedRebase = WorkspaceState.isRebaseValue(config["pull.rebase"] ?? "")
        if !hasExplicitScopeChoice {
            gitConfigScope = .repository
        }
        if gitConfigScope == .repository, writeQueue == nil {
            syncActiveScopeFields()
        }
    }

    private func saveAuthorName(for explicitScope: GitConfigScope? = nil) {
        let targetScope = explicitScope ?? gitConfigScope
        let value: String = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != savedName else { return }
        let fallback = targetScope == .global ? globalPersistedName : localPersistedName
        savedName = value
        if targetScope == .global {
            globalPersistedName = value
        } else {
            localPersistedName = value
        }
        enqueueWrite {
            if await writeConfig("user.name", value, scope: targetScope) {
                if targetScope == .global {
                    globalPersistedName = value
                } else {
                    localPersistedName = value
                }
            } else {
                if targetScope == .global {
                    globalPersistedName = fallback
                } else {
                    localPersistedName = fallback
                }
                if gitConfigScope == targetScope, savedName == value {
                    savedName = fallback
                    authorName = fallback
                }
            }
        }
    }

    private func saveAuthorEmail(for explicitScope: GitConfigScope? = nil) {
        let targetScope = explicitScope ?? gitConfigScope
        let value: String = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != savedEmail else { return }
        let fallback = targetScope == .global ? globalPersistedEmail : localPersistedEmail
        savedEmail = value
        if targetScope == .global {
            globalPersistedEmail = value
        } else {
            localPersistedEmail = value
        }
        enqueueWrite {
            if await writeConfig("user.email", value, scope: targetScope) {
                if targetScope == .global {
                    globalPersistedEmail = value
                } else {
                    localPersistedEmail = value
                }
                if !value.isEmpty {
                    signingStore.syncAllowedSigners(email: value)
                }
            } else {
                if targetScope == .global {
                    globalPersistedEmail = fallback
                } else {
                    localPersistedEmail = fallback
                }
                if gitConfigScope == targetScope, savedEmail == value {
                    savedEmail = fallback
                    authorEmail = fallback
                }
            }
        }
    }

    private func setRebase(_ on: Bool) {
        guard on != prefersRebase else { return }
        let targetScope = gitConfigScope
        let previous = targetScope == .global ? globalPersistedRebase : localPersistedRebase
        prefersRebase = on
        if targetScope == .global {
            globalPersistedRebase = on
        } else {
            localPersistedRebase = on
        }
        enqueueWrite {
            if await writeRebase(on, scope: targetScope) {
                if targetScope == .global {
                    globalPersistedRebase = on
                } else {
                    localPersistedRebase = on
                }
            } else if gitConfigScope == targetScope, prefersRebase == on {
                prefersRebase = previous
                if targetScope == .global {
                    globalPersistedRebase = previous
                } else {
                    localPersistedRebase = previous
                }
            }
        }
    }

    private func beginEditing(_ id: UUID) {
        guard canEditExcludes else { return }
        if let current = editing, current != id { finishEditing() }
        guard patterns.contains(where: { $0.id == id }) else { return }
        selection = id
        editing = id
        Task { focus = .pattern(id) }
    }

    private func addPattern() {
        guard canEditExcludes else { return }
        finishEditing()
        let pattern = IgnoredPattern(text: "", saved: nil)
        patterns.append(pattern)
        beginEditing(pattern.id)
    }

    private func removeSelectedPattern() {
        guard canEditExcludes else { return }
        finishEditing()
        guard let id = selection, let index = patterns.firstIndex(where: { $0.id == id }) else { return }
        guard let saved = patterns[index].saved else {
            patterns.remove(at: index)
            selection = nil
            return
        }
        commitExcludes(.remove(saved: saved, occurrence: occurrence(of: saved, before: index)), row: id)
    }

    private func finishEditing() {
        guard let id = editing else { return }
        editing = nil
        guard let index = patterns.firstIndex(where: { $0.id == id }) else { return }
        let text: String = Self.singleLine(patterns[index].text)
        patterns[index].text = text
        let isEmpty: Bool = text.trimmingCharacters(in: .whitespaces).isEmpty
        guard let saved = patterns[index].saved else {
            if isEmpty {
                patterns.remove(at: index)
                selection = nil
            } else {
                commitExcludes(.add(text), row: id)
            }
            return
        }
        let occurrence: Int = occurrence(of: saved, before: index)
        if isEmpty {
            commitExcludes(.remove(saved: saved, occurrence: occurrence), row: id)
        } else if text != saved {
            commitExcludes(.replace(saved: saved, occurrence: occurrence, text: text), row: id)
        }
    }

    private func occurrence(of saved: String, before index: Int) -> Int {
        patterns[..<index].filter { $0.saved == saved }.count
    }

    private func loadExcludes() {
        switch Self.readLines(at: excludesPath) {
        case .lines(let lines):
            excludesFailure = nil
            patterns = Self.patternTexts(in: lines).map { IgnoredPattern(text: $0, saved: $0) }
        case .unavailable(let message):
            excludesFailure = message
            patterns = []
            selection = nil
            editing = nil
        }
        isLoaded = true
    }

    private func commitExcludes(_ change: ExcludesChange, row: UUID) {
        guard !excludesPath.isEmpty else { return }
        var lines: [String] = []
        switch Self.readLines(at: excludesPath) {
        case .unavailable(let message):
            excludesFailure = message
            patterns = []
            selection = nil
            editing = nil
            return
        case .lines(let current):
            lines = current
        }
        let external: Bool = Self.patternTexts(in: lines) != patterns.compactMap(\.saved)
        if Self.apply(change, to: &lines) {
            let body: String = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            let directory: String = (excludesPath as NSString).deletingLastPathComponent
            do {
                if !directory.isEmpty {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                }
                try body.write(toFile: excludesPath, atomically: false, encoding: .utf8)
            } catch {
                saveError = error.localizedDescription
                return
            }
            workspace.scheduleGitStatusRefresh()
        }
        if external {
            patterns = Self.patternTexts(in: lines).map { IgnoredPattern(text: $0, saved: $0) }
            selection = nil
            editing = nil
            return
        }
        guard let index = patterns.firstIndex(where: { $0.id == row }) else { return }
        if case .remove = change {
            patterns.remove(at: index)
            selection = nil
        } else {
            patterns[index].saved = patterns[index].text
        }
    }

    private static func apply(_ change: ExcludesChange, to lines: inout [String]) -> Bool {
        switch change {
        case .add(let text):
            lines.append(text)
            return true
        case .remove(let saved, let occurrence):
            guard let index = lineIndex(of: saved, occurrence: occurrence, in: lines) else { return false }
            lines.remove(at: index)
            return true
        case .replace(let saved, let occurrence, let text):
            if let index = lineIndex(of: saved, occurrence: occurrence, in: lines) {
                lines[index] = text + (lines[index].hasSuffix("\r") ? "\r" : "")
            } else {
                lines.append(text)
            }
            return true
        }
    }

    private static func lineIndex(of pattern: String, occurrence: Int, in lines: [String]) -> Int? {
        GitExcludesFileHelper.lineIndex(of: pattern, occurrence: occurrence, in: lines)
    }

    private static func withoutCarriageReturn(_ line: String) -> String {
        GitExcludesFileHelper.withoutCarriageReturn(line)
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func defaultExcludesPath() -> String {
        GitExcludesFileHelper.defaultExcludesPath()
    }

    private static func readLines(at path: String) -> ExcludesFile {
        guard FileManager.default.fileExists(atPath: path) else { return .lines([]) }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .unavailable("This file can’t be edited here because it can’t be read.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable("This file can’t be edited here because it isn’t UTF-8 text.")
        }
        var lines: [String] = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return .lines(lines)
    }

    private static func patternTexts(in lines: [String]) -> [String] {
        GitExcludesFileHelper.patternTexts(in: lines)
    }
}
