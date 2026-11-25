import AppKit
import GoLensFoundation
import SwiftUI

struct MainToolbar: ToolbarContent {
    @Bindable var workspace: WorkspaceState
    var availableWidth: CGFloat = 940

    private var hasIssues: Bool {
        workspace.issueTotals.errors > 0 || workspace.issueTotals.warnings > 0
    }

    private var resolvedWidths: ToolbarClusterMetrics.ResolvedWidths {
        ToolbarClusterMetrics.resolve(availableWidth: availableWidth, hasIssues: hasIssues)
    }

    private var titleMaxWidth: CGFloat {
        resolvedWidths.titleMaxWidth
    }

    private var pillWidth: CGFloat {
        resolvedWidths.pillWidth
    }

    static func applyItemPriorities(to toolbar: NSToolbar?) {
        guard let items = toolbar?.items else { return }
        for item in items where item.view != nil {
            switch item.label {
            case "":
                item.visibilityPriority = .user
            case "Gopilot":
                item.visibilityPriority = .low
            case "Debug":
                item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: 800)
            case "Run", "Stop":
                item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: 900)
            default:
                if item.visibilityPriority == .standard {
                    item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: 950)
                }
            }
        }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ProjectTitleButton(workspace: workspace, maxWidth: titleMaxWidth)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: {
                if workspace.isCurrentRunTargetRunning {
                    workspace.stopActiveRun()
                } else {
                    workspace.runProject()
                }
            }) {
                Label(workspace.isCurrentRunTargetRunning ? "Stop" : "Run", systemImage: workspace.isCurrentRunTargetRunning ? "stop.fill" : "play.fill")
            }
            .disabled(workspace.activeWorkspacePath.isEmpty)
            .help(
                workspace.isCurrentRunTargetRunning
                    ? KeymapStore.shared.labeled("Stop Project", "product.stop")
                    : KeymapStore.shared.labeled("Run Project", "product.run")
            )
            .accessibilityLabel(workspace.isCurrentRunTargetRunning ? "Stop" : "Run")

            Button(action: {
                if !workspace.isRunning {
                    workspace.debugProject()
                }
            }) {
                Label("Debug", systemImage: "ladybug.fill")
            }
            .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
            .help(KeymapStore.shared.labeled("Debug Project", "product.debug"))
            .accessibilityLabel("Debug")

            Button {
                workspace.gopilot.isPanelVisible.toggle()
            } label: {
                Label("Gopilot", systemImage: "sparkles")
            }
            .help(KeymapStore.shared.labeled(workspace.gopilot.isPanelVisible ? "Hide Gopilot" : "Show Gopilot", "view.gopilot"))
            .accessibilityLabel(workspace.gopilot.isPanelVisible ? "Hide Gopilot" : "Show Gopilot")
        }

        ToolbarItem(placement: .principal) {
            CenterActivityCluster(workspace: workspace, pillWidth: pillWidth)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

struct ActivityPill: View {
    @Bindable var workspace: WorkspaceState
    var width: CGFloat = ToolbarLayout.activityPillMaxWidth
    private var vm: SandboxVMManager { SandboxVMManager.shared }

    private var isDockerKind: Bool { workspace.activeRunConfiguration?.kind == .docker }

    private var destinationTitle: String {
        if isDockerKind { return "Docker" }
        if workspace.activeRunTarget.kind == .local {
            return vm.executionMode == .linuxVM ? "Linux VM" : "My Mac"
        }
        return workspace.activeRunTarget.title
    }

    private var destinationSymbol: String {
        if isDockerKind { return "square.stack.3d.up" }
        if workspace.activeRunTarget.kind == .local {
            return vm.executionMode == .linuxVM ? "cpu" : "desktopcomputer"
        }
        return workspace.activeRunTarget.symbol
    }

    private var destinationHelp: String {
        if isDockerKind { return "Run Destination: this configuration builds and runs a Docker image" }
        let target = workspace.activeRunTarget
        switch target.kind {
        case .local: return vm.executionMode == .linuxVM ? "Run Destination: Linux Micro-VM" : "Run Destination: My Mac"
        case .compose: return "Run Destination: Docker Compose service \(target.service)"
        case .ssh: return "Run Destination: SSH host \(target.title)"
        }
    }

    private var configurationSymbol: String {
        isDockerKind ? "shippingbox" : "terminal"
    }

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Menu {
                RunConfigurationMenuItems(workspace: workspace)
            } label: {
                Label(workspace.activeRunConfigurationName, systemImage: configurationSymbol)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .disabled(workspace.activeWorkspacePath.isEmpty)
            .help(workspace.runConfigurations.isEmpty ? "Run Configuration: Default (go run .)" : "Run Configuration: \(workspace.activeRunConfigurationName)")
            .accessibilityLabel("Run Configuration")
            .accessibilityValue(workspace.activeRunConfigurationName)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            Image(systemName: "chevron.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .layoutPriority(1)

            Menu {
                RunDestinationMenuItems(workspace: workspace)
            } label: {
                Label(destinationTitle, systemImage: destinationSymbol)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .disabled(workspace.activeWorkspacePath.isEmpty || isDockerKind)
            .help(destinationHelp)
            .accessibilityLabel("Run Destination")
            .accessibilityValue(destinationTitle)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .task(id: workspace.activeWorkspacePath) {
                workspace.loadComposeServices()
            }

            Spacer(minLength: 8)

            ActivityStatusView(workspace: workspace)
                .frame(minWidth: 52, alignment: .trailing)
                .layoutPriority(0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Spacing.standard)
        .frame(width: width)
    }
}

struct ActivityStatusView: View {
    @Bindable var workspace: WorkspaceState

    private var project: String {
        (workspace.activeWorkspacePath as NSString).lastPathComponent
    }

    private var liveActivity: String? {
        if workspace.activeWorkspacePath.isEmpty { return nil }
        let config = workspace.activeRunConfigurationName
        let destination = workspace.activeRunConfiguration?.kind == .docker ? "Docker" : workspace.activeRunTarget.title
        if workspace.debug.isDebugMode { return "Debugging \(config) on \(destination)" }
        if workspace.isTestRunning { return "Testing…" }
        if let command = workspace.goCommand {
            return command == "Build" ? "Building…" : "Running \(command)…"
        }
        if workspace.isStartingRun || workspace.isCurrentRunTargetRunning {
            return "Running \(config) on \(destination)"
        }
        let running = workspace.runSessions.filter(\.isRunning)
        guard let latest = running.last else { return nil }
        return running.count > 1 ? "Running \(latest.title) and \(running.count - 1) more" : "Running \(latest.title)"
    }

    var body: some View {
        let live = liveActivity
        let last = workspace.lastActivity
        HStack(spacing: Spacing.standard) {
            if live != nil {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else if let last, last.failed {
                Image(systemName: StatusTone.failure.symbol)
                    .foregroundStyle(StatusTone.failure.tint)
                    .accessibilityHidden(true)
            }
            statusText(live: live, last: last)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity")
        .accessibilityValue(accessibilityValue(live: live, last: last))
        .help(accessibilityValue(live: live, last: last))
    }

    private func visualLiveText(for live: String) -> String {
        if workspace.debug.isDebugMode { return "Debugging…" }
        if workspace.isStartingRun || workspace.isCurrentRunTargetRunning { return "Running…" }
        if !project.isEmpty, live == "Running \(project)" { return "Running…" }
        return live
    }

    private func visualFinishedTitle(for title: String) -> String {
        if !project.isEmpty {
            if title == "Finished Running \(project)" { return "Finished Running" }
            if title == "Stopped \(project)" { return "Stopped" }
        }
        if title == "Finished Running Default" { return "Finished Running" }
        if title == "Stopped Default" { return "Stopped" }
        return title
    }

    private func statusText(live: String?, last: WorkspaceState.FinishedActivity?) -> Text {
        if let live {
            return Text(visualLiveText(for: live)).fontWeight(.semibold)
        }
        if let last {
            return Text(visualFinishedTitle(for: last.title)).fontWeight(.semibold)
                + Text(" · \(last.date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
        }
        return Text("Ready").foregroundStyle(.secondary).fontWeight(.medium)
    }

    private func accessibilityValue(live: String?, last: WorkspaceState.FinishedActivity?) -> String {
        let head = (project.isEmpty ? "" : "\(project): ")
        if let live { return head + live }
        if let last { return head + last.title + ", " + last.date.formatted(date: .abbreviated, time: .shortened) }
        return head + "Ready"
    }
}

struct RunDestinationMenuItems: View {
    @Bindable var workspace: WorkspaceState
    private var vm: SandboxVMManager { SandboxVMManager.shared }

    private var targets: RunTargetState { workspace.runTargets }

    private func id(_ t: RunTarget) -> String {
        switch t.kind {
        case .local: return "local"
        case .compose: return "compose:\(t.service)"
        case .ssh: return "ssh:\(t.host):\(t.port)"
        }
    }

    private var composeFileRelative: String {
        let file = targets.compose.file
        return file.isEmpty ? "" : workspace.projectRelativePath(file)
    }

    private var composeTargets: [RunTarget] {
        let current = workspace.activeRunTarget
        return targets.compose.services.map { service in
            var t = current.kind == .compose ? current : RunTarget(kind: .compose)
            t.kind = .compose
            t.service = service
            if t.composeFile.isEmpty { t.composeFile = composeFileRelative }
            return t
        }
    }

    private var sshTargets: [RunTarget] {
        workspace.knownSSHTargets
    }

    var body: some View {
        let all = [RunTarget.local] + composeTargets + sshTargets
        Picker("Run Destination", selection: Binding(
            get: { id(workspace.activeRunTarget) },
            set: { newID in
                guard let target = all.first(where: { id($0) == newID }) else { return }
                var chosen = target
                let current = workspace.activeRunTarget
                if chosen.kind == current.kind && chosen.kind != .local {
                    chosen.workDir = current.workDir
                    chosen.debugPort = current.debugPort
                }
                workspace.setActiveRunTarget(chosen)
            }
        )) {
            Label(
                vm.executionMode == .linuxVM ? "Linux Micro-VM (This Mac)" : "My Mac",
                systemImage: vm.executionMode == .linuxVM ? "cpu" : "desktopcomputer"
            ).tag("local")
            if !composeTargets.isEmpty {
                Section("Docker Compose") {
                    ForEach(composeTargets, id: \.service) { t in
                        Label(t.service, systemImage: t.symbol).tag(id(t))
                    }
                }
            }
            if !sshTargets.isEmpty {
                Section("SSH") {
                    ForEach(sshTargets, id: \.self) { t in
                        Label(t.title, systemImage: t.symbol).tag(id(t))
                    }
                }
            }
        }
        .pickerStyle(.inline)

        if targets.compose.services.isEmpty {
            Text(targets.isLoadingServices ? "Looking for Compose Services…" : "No Compose Services in This Project")
        }

        if let config = workspace.activeRunConfiguration, config.kind == .go, workspace.activeRunTarget.kind == .local {
            Divider()
            Menu {
                ForEach(TargetArchitecture.allCases, id: \.self) { arch in
                    Button {
                        var updated = config
                        updated.architecture = arch
                        workspace.updateRunConfiguration(updated)
                    } label: {
                        HStack {
                            Text(arch.title)
                            if config.architecture == arch {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Architecture: \(config.architecture.shortTitle)", systemImage: config.architecture.systemImage)
            }
        }

        Divider()

        Button("Add SSH Host…", systemImage: "server.rack") {
            workspace.runTargets.requestedKind = .ssh
            workspace.showRunConfigurations = true
        }
        Button("Refresh Compose Services", systemImage: "arrow.clockwise") {
            workspace.loadComposeServices(force: true)
        }
        Button("Edit Destination…", systemImage: "slider.horizontal.3") {
            workspace.showRunConfigurations = true
        }
    }
}

struct RunConfigurationMenuItems: View {
    @Bindable var workspace: WorkspaceState
    var showAttachToProcess: Bool = true

    var body: some View {
        if workspace.runConfigurations.isEmpty {
            Picker("Run Configuration", selection: .constant(0)) {
                Label(workspace.activeRunConfigurationName, systemImage: "terminal").tag(0)
            }
            .pickerStyle(.inline)
        } else {
            Picker("Run Configuration", selection: Binding(
                get: { workspace.activeRunConfiguration?.id },
                set: { workspace.activeRunConfigId = $0 }
            )) {
                ForEach(workspace.runConfigurations) { config in
                    Label(config.name, systemImage: config.kind == .docker ? "shippingbox" : "terminal").tag(Optional(config.id))
                }
            }
            .pickerStyle(.inline)
        }

        Divider()

        Button("Edit Run Configurations…", systemImage: "slider.horizontal.3") {
            workspace.showRunConfigurations = true
        }
        .keyboardShortcut(KeymapStore.shared.shortcut("product.editRunConfigurations"))

        if showAttachToProcess {
            Button("Attach to Process…", systemImage: "ladybug.fill") {
                workspace.presentAttachProcessSheet()
            }
            .disabled(workspace.isRunning)
        }
    }
}

struct CenterActivityCluster: View {
    @Bindable var workspace: WorkspaceState
    var pillWidth: CGFloat = ToolbarLayout.activityPillMaxWidth

    private var hasIssues: Bool {
        workspace.issueTotals.errors > 0 || workspace.issueTotals.warnings > 0
    }

    var body: some View {
        HStack(spacing: Spacing.standard) {
            ActivityPill(workspace: workspace, width: pillWidth)
                .padding(.vertical, Spacing.row)
                .glassControlCapsule(interactive: false)
            if hasIssues {
                IssuesToolbarBadge(workspace: workspace)
            }
        }
    }
}

struct IssuesToolbarBadge: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        let errors = workspace.issueTotals.errors
        let warnings = workspace.issueTotals.warnings
        Button {
            workspace.showNavigator(.issues)
        } label: {
            HStack(spacing: Spacing.inset) {
                if errors > 0 {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                        Text("\(errors)")
                    }
                }
                if warnings > 0 {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                        Text("\(warnings)")
                    }
                }
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, Spacing.row)
            .padding(.vertical, Spacing.row)
            .padding(.horizontal, Spacing.compact)
            .glassControlCapsule(interactive: true)
        }
        .buttonStyle(.borderless)
        .help("Show Issues")
        .accessibilityLabel(IssueBadgeAccessibility.label(errors: errors, warnings: warnings))
    }
}

struct ProjectTitleButton: View {
    @Bindable var workspace: WorkspaceState
    var maxWidth: CGFloat = ToolbarLayout.titleMaxWidth
    @State private var isHovering = false
    @State private var showBranches = false

    var body: some View {
        let project = workspace.activeWorkspacePath.isEmpty ? "GoLens" : (workspace.activeWorkspacePath as NSString).lastPathComponent
        let branch = workspace.git.branchName
        let hasBranch = workspace.git.isRepository == true && !branch.isEmpty
        ConstrainedWidthLayout(maxWidth: maxWidth) {
            Button {
                if hasBranch { showBranches.toggle() }
            } label: {
                HStack(spacing: Spacing.standard) {
                    if hasBranch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if hasBranch {
                            HStack(spacing: Spacing.compact) {
                                Text(branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.down")
                                    .font(TechnicalTypography.badgeMicro)
                                    .opacity(isHovering || showBranches ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, Spacing.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(hasBranch ? "Switch Branch" : project)
            .accessibilityLabel(project)
            .accessibilityValue(hasBranch ? branch : "")
            .accessibilityHint(hasBranch ? "Shows the branches" : "")
            .popover(isPresented: $showBranches, arrowEdge: .bottom) {
                BranchSwitcherPopover(workspace: workspace, isPresented: $showBranches)
            }
        }
    }
}

private struct ConstrainedWidthLayout: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let intrinsic = subview.sizeThatFits(.unspecified)
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        let width = min(intrinsic.width, max(0, limit))
        let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct BranchSwitcherPopover: View {
    private enum ActiveRow: Equatable {
        case branch(String)
        case worktree(String)
        case newBranch
        case newWorktree
    }

    @Bindable var workspace: WorkspaceState
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var loadedBranches: [GitBranchSummary] = []
    @State private var measuredContentHeight: CGFloat = 0
    @State private var activeRow: ActiveRow?
    @State private var keyMonitor: Any?
    @FocusState private var isFindFocused: Bool

    private var effectiveBranches: [GitBranchSummary] {
        GitBranchSummary.resolveEffectiveBranches(
            currentBranch: workspace.git.branchName,
            loaded: loadedBranches,
            cached: workspace.git.branchSummaries,
            knownBranchNames: workspace.git.branches
        )
    }

    private var filtered: [GitBranchSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? effectiveBranches : effectiveBranches.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var currentBranchInfo: GitBranchSummary? {
        let current = workspace.git.branchName
        return filtered.first { $0.name == current }
    }

    private var otherBranches: [GitBranchSummary] {
        let current = workspace.git.branchName
        return filtered.filter { $0.name != current }
    }

    private var filteredWorktrees: [GitWorktreeEntry] {
        guard workspace.repositories.worktrees.count > 1 else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty
            ? workspace.repositories.worktrees
            : workspace.repositories.worktrees.filter {
                $0.folderName.localizedCaseInsensitiveContains(q) || $0.displayBranch.localizedCaseInsensitiveContains(q)
            }
    }

    private var resolvedListHeight: CGFloat {
        BranchPopoverLayoutMath.resolvedListHeight(
            measuredContentHeight: measuredContentHeight,
            currentBranch: currentBranchInfo,
            otherBranches: otherBranches
        )
    }

    var body: some View {
        let currentInfo = currentBranchInfo
        let others = otherBranches
        let worktrees = filteredWorktrees
        VStack(alignment: .leading, spacing: Spacing.standard) {
            TextField("Find", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFindFocused)
                .background(PopupFieldAutoFocus())
                .accessibilityLabel("Find Branch")
                .onChange(of: query) { _, newValue in
                    measuredContentHeight = 0
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        activeRow = nil
                    } else if let firstMatch = otherBranches.first {
                        activeRow = .branch(firstMatch.name)
                    } else if let firstWorktree = filteredWorktrees.first(where: { !workspace.isCurrentWorktree($0) }) {
                        activeRow = .worktree(firstWorktree.path)
                    } else {
                        activeRow = nil
                    }
                }
                .onSubmit {
                    submitSelection(others: others, worktrees: worktrees)
                }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        if let currentInfo {
                            sectionHeader("Current Branch")
                            row(currentInfo, isCurrent: true)
                                .id(currentInfo.name)
                        }
                        if !others.isEmpty {
                            sectionHeader("Branches")
                            ForEach(others) { branch in
                                row(branch, isCurrent: false)
                                    .id(branch.name)
                            }
                        }
                        if !worktrees.isEmpty {
                            sectionHeader("Worktrees")
                            ForEach(worktrees) { entry in
                                worktreeRow(entry)
                                    .id("worktree:" + entry.path)
                            }
                        }
                        if currentInfo == nil && others.isEmpty && worktrees.isEmpty {
                            Text(query.isEmpty ? "No Branches" : "No Matching Branches")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.row)
                                .padding(.vertical, Spacing.standard)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { newHeight in
                        if abs(newHeight - measuredContentHeight) > 0.5 {
                            measuredContentHeight = newHeight
                        }
                    }
                }
                .frame(height: resolvedListHeight)
                .onChange(of: activeRow) { _, target in
                    guard !PopupMouseTracker.isHoverSelecting else { return }
                    switch target {
                    case .branch(let branchName):
                        scrollProxy.scrollTo(branchName)
                    case .worktree(let path):
                        scrollProxy.scrollTo("worktree:" + path)
                    default:
                        break
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                newBranchAction
                newWorktreeAction
            }
        }
        .padding(Spacing.comfortable)
        .frame(width: ToolbarLayout.branchPopoverWidth)
        .background(PopoverContentSizeSync(trigger: resolvedListHeight))
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            isFindFocused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .task { await load() }
    }

    private var newBranchAction: some View {
        let isSelected = activeRow == .newBranch
        return HStack(spacing: Spacing.standard) {
            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text("New Branch…")
                .font(.body)
                .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.row)
        .popupRow(
            isSelected: isSelected,
            onHoverSelect: { activeRow = .newBranch },
            action: openNewBranchSheet
        )
        .accessibilityLabel("New Branch…")
    }

    private var newWorktreeAction: some View {
        let isSelected = activeRow == .newWorktree
        return HStack(spacing: Spacing.standard) {
            Image(systemName: "folder.badge.plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text("New Worktree…")
                .font(.body)
                .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.row)
        .popupRow(
            isSelected: isSelected,
            onHoverSelect: { activeRow = .newWorktree },
            action: openNewWorktreeSheet
        )
        .accessibilityLabel("New Worktree…")
    }

    private func worktreeRow(_ entry: GitWorktreeEntry) -> some View {
        let isCurrent = workspace.isCurrentWorktree(entry)
        let isSelected = activeRow == .worktree(entry.path)
        let detail = entry.isPrunable ? "\(entry.displayBranch) · Missing" : entry.displayBranch
        return HStack(spacing: Spacing.inset) {
            Image(systemName: entry.isPrunable ? "folder.badge.questionmark" : "folder")
                .font(.callout.weight(.medium))
                .foregroundStyle(isSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(entry.folderName)
                    .font(.body.weight(isCurrent ? .medium : .regular))
                    .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Spacing.compact)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.row)
        .popupRow(
            isSelected: isSelected,
            onHoverSelect: { activeRow = .worktree(entry.path) },
            action: {
                isPresented = false
                if !isCurrent { workspace.openWorktree(entry) }
            }
        )
        .help(entry.path)
        .accessibilityLabel(worktreeRowLabel(entry, isCurrent: isCurrent, detail: detail))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Spacing.compact)
            .padding(.horizontal, Spacing.row)
    }

    private func row(_ info: GitBranchSummary, isCurrent: Bool) -> some View {
        let isSelected = activeRow == .branch(info.name)
        return HStack(spacing: Spacing.inset) {
            Image(systemName: "arrow.triangle.branch")
                .font(.callout.weight(.medium))
                .foregroundStyle(isSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(info.name)
                    .font(.body.weight(isCurrent ? .medium : .regular))
                    .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !info.author.isEmpty {
                    Text(commitLine(info))
                        .font(.caption)
                        .foregroundStyle(isSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Spacing.compact)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.row)
        .popupRow(
            isSelected: isSelected,
            onHoverSelect: { activeRow = .branch(info.name) },
            action: {
                isPresented = false
                if !isCurrent { workspace.switchBranchStashingIfNeeded(info.name) }
            }
        )
        .accessibilityLabel(rowLabel(info, isCurrent: isCurrent))
    }

    private func openNewBranchSheet() {
        isPresented = false
        workspace.sourceControl.sheet = .newBranch(from: nil)
    }

    private func openNewWorktreeSheet() {
        isPresented = false
        workspace.sourceControl.sheet = .newWorktree(branch: nil)
    }

    private func submitSelection(others: [GitBranchSummary], worktrees: [GitWorktreeEntry]) {
        if activeRow == .newBranch {
            openNewBranchSheet()
            return
        }
        if activeRow == .newWorktree {
            openNewWorktreeSheet()
            return
        }
        if case .worktree(let selectedPath) = activeRow,
           let entry = worktrees.first(where: { $0.path == selectedPath }) {
            isPresented = false
            if !workspace.isCurrentWorktree(entry) {
                workspace.openWorktree(entry)
            }
            return
        }
        if case .branch(let selectedName) = activeRow {
            if selectedName == workspace.git.branchName {
                isPresented = false
                return
            }
            if others.contains(where: { $0.name == selectedName }) {
                isPresented = false
                workspace.switchBranchStashingIfNeeded(selectedName)
                return
            }
        }
        if let firstMatch = others.first {
            isPresented = false
            workspace.switchBranchStashingIfNeeded(firstMatch.name)
        } else if let firstWorktree = worktrees.first(where: { !workspace.isCurrentWorktree($0) }) {
            isPresented = false
            workspace.openWorktree(firstWorktree)
        }
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPresented else { return event }
            if let eventWindow = event.window,
               !isFindFocused,
               !NSStringFromClass(type(of: eventWindow)).contains("Popover") {
                return event
            }
            let worktrees = filteredWorktrees
            let candidates = otherBranches.map { "b:" + $0.name }
                + worktrees.filter { !workspace.isCurrentWorktree($0) }.map { "w:" + $0.path }
            let currentToken: String? = switch activeRow {
            case .branch(let name): "b:" + name
            case .worktree(let path): "w:" + path
            default: nil
            }
            switch event.keyCode {
            case 125:
                PopupMouseTracker.markKeyboardOrOpen()
                if let next = BranchPopoverLayoutMath.moveSelection(current: currentToken, candidates: candidates, delta: 1) {
                    activeRow = rowForToken(next)
                }
                return nil
            case 126:
                PopupMouseTracker.markKeyboardOrOpen()
                if let prev = BranchPopoverLayoutMath.moveSelection(current: currentToken, candidates: candidates, delta: -1) {
                    activeRow = rowForToken(prev)
                }
                return nil
            case 36, 76:
                submitSelection(others: otherBranches, worktrees: worktrees)
                return nil
            case 53:
                isPresented = false
                return nil
            default:
                return event
            }
        }
    }

    private func rowForToken(_ token: String) -> ActiveRow? {
        if token.hasPrefix("b:") {
            return .branch(String(token.dropFirst(2)))
        }
        if token.hasPrefix("w:") {
            return .worktree(String(token.dropFirst(2)))
        }
        return nil
    }

    private func commitLine(_ info: GitBranchSummary) -> String {
        guard let date = info.date else { return info.author }
        return "\(info.author) committed \(date.formatted(.relative(presentation: .named)))"
    }

    private func rowLabel(_ info: GitBranchSummary, isCurrent: Bool) -> String {
        var parts: [String] = [info.name]
        if isCurrent { parts.append("current branch") }
        if !info.author.isEmpty { parts.append(commitLine(info)) }
        return parts.joined(separator: ", ")
    }

    private func worktreeRowLabel(_ entry: GitWorktreeEntry, isCurrent: Bool, detail: String) -> String {
        var parts: [String] = ["Worktree \(entry.folderName)", detail]
        if isCurrent { parts.append("current worktree") }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        let workspacePath = workspace.activeWorkspacePath
        async let branchOutput = (try? workspace.runGit(
            args: ["--no-optional-locks", "for-each-ref", "--sort=-committerdate", "--format=\(GitBranchSummary.refFormat)", "refs/heads"],
            in: workspacePath
        )) ?? ""
        async let worktreeOutput = (try? workspace.runGit(
            args: ["--no-optional-locks", "worktree", "list", "--porcelain"],
            in: workspacePath
        )) ?? ""
        let parsed = GitBranchSummary.parseForEachRef(await branchOutput)
        let worktrees = GitWorktreeParser.parsePorcelain(await worktreeOutput)
        guard workspace.activeWorkspacePath == workspacePath else { return }
        if parsed != loadedBranches {
            loadedBranches = parsed
        }
        if !parsed.isEmpty && workspace.git.branchSummaries != parsed {
            workspace.git.branchSummaries = parsed
            let sortedNames = parsed.map(\.name).sorted()
            if workspace.git.branches != sortedNames {
                workspace.git.branches = sortedNames
            }
        }
        if workspace.repositories.worktrees != worktrees {
            workspace.repositories.worktrees = worktrees
        }
    }
}

private struct PopoverContentSizeSync: NSViewRepresentable {
    let trigger: CGFloat

    final class Coordinator {
        var lastTrigger: CGFloat = -1
    }

    private final class SyncView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = SyncView(frame: .zero)
        let coord = context.coordinator
        view.onMoveToWindow = { [weak view] in
            guard let view else { return }
            syncSize(for: view, trigger: coord.lastTrigger, coordinator: coord, force: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard abs(context.coordinator.lastTrigger - trigger) > 0.5 else { return }
        syncSize(for: nsView, trigger: trigger, coordinator: context.coordinator, force: false)
    }

    private func syncSize(for nsView: NSView, trigger: CGFloat, coordinator: Coordinator, force: Bool) {
        DispatchQueue.main.async {
            guard let window = nsView.window,
                  NSStringFromClass(type(of: window)).contains("Popover"),
                  let contentView = window.contentView else { return }
            if !force {
                coordinator.lastTrigger = trigger
            }
            contentView.invalidateIntrinsicContentSize()
            contentView.layoutSubtreeIfNeeded()
            let fitting = contentView.fittingSize
            if fitting.width > 0, fitting.height > 0,
               let controller = window.contentViewController,
               abs(controller.preferredContentSize.height - fitting.height) > 1 {
                controller.preferredContentSize = fitting
            }
        }
    }
}

