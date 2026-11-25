import AppKit
import GopilotProvider
import GopilotRuntime
import GopilotStore
import SwiftUI

enum GopilotModeChoice: Hashable, CaseIterable {
    case ask
    case agentAskFirst
    case agentAutoEdit
    case agentAuto

    init(mode: GopilotMode, permission: GopilotAgentPermissionMode) {
        switch (mode, permission) {
        case (.ask, _): self = .ask
        case (.agent, .permissionRequired): self = .agentAskFirst
        case (.agent, .autoEdit): self = .agentAutoEdit
        case (.agent, .auto): self = .agentAuto
        }
    }

    var mode: GopilotMode { self == .ask ? .ask : .agent }

    var permission: GopilotAgentPermissionMode? {
        switch self {
        case .ask: nil
        case .agentAskFirst: .permissionRequired
        case .agentAutoEdit: .autoEdit
        case .agentAuto: .auto
        }
    }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .agentAskFirst: "Agent · Ask First"
        case .agentAutoEdit: "Agent · Auto-Edit"
        case .agentAuto: "Agent · Auto"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Reads and explains code. Never changes files."
        case .agentAskFirst: "Default. Asks before each file change and each command."
        case .agentAutoEdit: "Applies edits to the editor unsaved, with Undo. Asks before commands."
        case .agentAuto: "Applies edits to the editor unsaved, with Undo. Runs Go checks and tests without asking."
        }
    }

    var emptyStateLine: String {
        switch self {
        case .ask: "Ask a question or start with a suggestion."
        case .agentAskFirst: "Describe a change. Gopilot asks before each file change and each command. Applied changes stay unsaved in the editor until you save."
        case .agentAutoEdit: "Describe a change. Gopilot applies edits to the editor without asking (unsaved, with Undo) and asks before running commands."
        case .agentAuto: "Describe a change. Gopilot applies edits to the editor (unsaved, with Undo) and runs Go checks and tests without asking."
        }
    }
}

struct GopilotComposerArea: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let availability: GopilotState.Availability
    var composerFocused: FocusState<Bool>.Binding
    var previewApproval: GopilotApprovalContent?
    var previewPendingProposal: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            if let pending = gopilot.interaction.approval {
                GopilotApprovalCardView(content: GopilotApprovalContent(card: pending.card)) { gopilot.interaction.resolveApproval($0) }
            } else if let previewApproval {
                GopilotApprovalCardView(content: previewApproval) { _ in }
            }
            if let pending = gopilot.interaction.dirty {
                GopilotDirtyCardView(paths: pending.paths) { gopilot.interaction.resolveDirty($0) }
            }
            if let saved = gopilot.viewingSaved {
                savedConversationBar(saved)
            } else {
                GopilotComposerStatusLine(
                    gopilot: gopilot,
                    isAwaitingPermission: gopilot.interaction.approval != nil || previewApproval != nil,
                    previewPendingProposal: previewPendingProposal
                )
                if let mentionQuery = gopilot.visibleMentionQuery, availability == .ready {
                    GopilotInlineMentionMenu(query: mentionQuery, workspace: workspace, gopilot: gopilot)
                }
                GopilotComposerSurface(
                    workspace: workspace,
                    gopilot: gopilot,
                    availability: availability,
                    composerFocused: composerFocused,
                    isAwaitingPermission: gopilot.interaction.approval != nil || previewApproval != nil
                )
            }
        }
        .padding(Spacing.comfortable)
    }

    private func savedConversationBar(_ saved: Conversation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Label {
                Text("\u{201C}\(saved.title)\u{201D} · Saved \(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .lineLimit(2)
            } icon: {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.medium))
            Text("This saved conversation is read-only. Continue it to ask follow-ups with fresh project sources.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.standard) {
                Button("Continue Conversation") {
                    Task { @MainActor in
                        await gopilot.continueSaved()
                        composerFocused.wrappedValue = true
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Close") {
                    gopilot.closeSaved()
                    composerFocused.wrappedValue = true
                }
                .help("Close the saved conversation and start a new one")
            }
            .controlSize(.small)
        }
    }
}

private struct GopilotComposerSurface: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    @Bindable private var settings = GopilotProviderSettings.shared
    let availability: GopilotState.Availability
    var composerFocused: FocusState<Bool>.Binding
    let isAwaitingPermission: Bool
    @State private var showsAddContext = ProcessInfo.processInfo.environment["GOPILOT_OPEN_ADD_CONTEXT"] == "1"
    @State private var showsModelPicker = ProcessInfo.processInfo.environment["GOPILOT_OPEN_MODEL_PICKER"] == "1"
        || ProcessInfo.processInfo.environment["GOPILOT_OPEN_REASONING_SLIDER"] == "1"
    @State private var pinnedModelLabel: (full: String, short: String)?
    @State private var previewingAttachmentID: UUID?

    private var projectName: String {
        workspace.activeWorkspacePath.isEmpty ? "No Project" : URL(fileURLWithPath: workspace.activeWorkspacePath).lastPathComponent
    }

    private var modeChoice: GopilotModeChoice {
        GopilotModeChoice(mode: gopilot.mode, permission: gopilot.agentPermissionMode)
    }

    private var placeholder: String {
        if availability == .notConfigured { return "Set up a provider in Settings to send messages" }
        if isAwaitingPermission { return "Gopilot is waiting for your permission above" }
        if gopilot.isRunning { return "Gopilot is working. Press Esc to stop." }
        if availability == .noWorkspace { return "Ask a Go question" }
        if gopilot.mode == .agent { return "Describe a change for Gopilot to make" }
        return gopilot.projectContextEnabled ? "Ask about your project" : "Ask about the attached sources"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
        let isFocused = composerFocused.wrappedValue
        VStack(alignment: .leading, spacing: Spacing.standard) {
            if availability == .ready || !gopilot.attachments.isEmpty || !gopilot.projectContextEnabled {
                contextStrip
            }

            TextField(placeholder, text: $gopilot.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...6)
                .focused(composerFocused)
                .accessibilityLabel("Message to Gopilot")
                .accessibilityHint("Return sends. Shift-Return starts a new line.")
                .help("Return sends. Shift-Return starts a new line.")
                .disabled(availability == .notConfigured || gopilot.viewingSaved != nil)
                .background(
                    GopilotComposerKeyHandler(
                        isActive: isFocused,
                        onSubmit: submit,
                        onEscape: {
                            if let query = gopilot.visibleMentionQuery {
                                gopilot.dismissedMentionQuery = query
                                return true
                            }
                            guard gopilot.isRunning else { return false }
                            gopilot.stop()
                            return true
                        },
                        onMoveMention: moveMentionSelection,
                        onAcceptMention: acceptMention
                    )
                )

            accessoryBar
        }
        .padding(Spacing.standard)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay(
            shape.strokeBorder(
                isFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : Color(nsColor: .separatorColor),
                lineWidth: isFocused ? 2 : 1
            )
        )
    }

    private func submit() {
        if gopilot.canSend(workspacePath: workspace.activeWorkspacePath) {
            gopilot.send()
        }
    }

    private var mentionCandidates: [GopilotMentionCandidate] {
        guard availability == .ready, let query = gopilot.visibleMentionQuery else { return [] }
        return GopilotMentionCandidate.candidates(for: query, workspace: workspace, gopilot: gopilot)
    }

    private func moveMentionSelection(_ delta: Int) -> Bool {
        let count = mentionCandidates.count
        guard count > 0 else { return false }
        PopupMouseTracker.markKeyboardOrOpen()
        gopilot.mentionSelection = min(max(gopilot.mentionSelection + delta, 0), count - 1)
        return true
    }

    private func acceptMention() -> Bool {
        let candidates = mentionCandidates
        guard !candidates.isEmpty else { return false }
        candidates[min(max(gopilot.mentionSelection, 0), candidates.count - 1)].attach(workspace: workspace, gopilot: gopilot)
        return true
    }

    private var contextStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            GopilotFlowLayout(spacing: Spacing.compact, lineSpacing: 4) {
                Button {
                    showsAddContext.toggle()
                } label: {
                    Label("Add Context", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(gopilot.isRunning ? "Add Context is available when Gopilot finishes" : "Add Files, Symbols, or Selection")
                .accessibilityLabel("Add Context")
                .disabled(availability != .ready || gopilot.isRunning)
                .popover(isPresented: $showsAddContext, arrowEdge: .top) {
                    GopilotAddContextPopover(workspace: workspace, gopilot: gopilot) {
                        showsAddContext = false
                    }
                }

                if availability == .ready {
                    scopeMenu
                }

                if let activeRel = gopilot.currentEditorRelativePath(in: workspace),
                   gopilot.isActiveFileSuggested(in: workspace) {
                    let fileName = (activeRel as NSString).lastPathComponent
                    let isIncluded = gopilot.activeFileAttachment(in: workspace) != nil
                    GopilotContextChip(
                        title: fileName,
                        isSuggestion: !isIncluded,
                        primaryHelp: isIncluded ? "\(fileName) is in context. Click to leave it out." : "Current file. Click to add \(fileName) to the context.",
                        removeHelp: isIncluded ? "Remove \(fileName) from Context" : "Don't Suggest \(fileName)",
                        primary: { gopilot.toggleActiveFileAttachment(in: workspace) },
                        remove: { gopilot.dismissActiveFileSuggestion(in: workspace) }
                    ) {
                        FileIconView(fileName: fileName, path: workspace.activeFilePath, isSelected: false, size: FileIconSize.compact)
                    }
                    .accessibilityLabel(isIncluded ? "Current file \(fileName), in context" : "Current file \(fileName), suggested")
                }

                if gopilot.isProblemsChipVisible(in: workspace),
                   let summary = gopilot.activeProblemsSummary(in: workspace) {
                    let isIncluded = gopilot.includeProblemsInContext
                    GopilotContextChip(
                        title: summary.label,
                        isSuggestion: !isIncluded,
                        primaryHelp: isIncluded ? "\(summary.label) are in context. Click to leave them out." : "Click to add the current compiler and lint problems to the context.",
                        removeHelp: isIncluded ? "Remove Problems from Context" : "Don't Suggest Problems",
                        primary: { gopilot.toggleProblemsAttachment() },
                        remove: { gopilot.dismissProblemsSuggestion() }
                    ) {
                        Image(systemName: StatusTone.warning.symbol)
                            .foregroundStyle(StatusTone.warning.tint)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(isIncluded ? "\(summary.label), in context" : "\(summary.label), suggested")
                }

                let attachedActiveID = gopilot.activeFileAttachment(in: workspace)?.id
                ForEach(gopilot.attachments.filter { $0.id != attachedActiveID }) { item in
                    attachmentChip(for: item)
                }
            }
            if !gopilot.projectContextEnabled && gopilot.attachments.isEmpty {
                Text("Project context is off. Attach a file with + or choose Search the Whole Project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { gopilot.projectContextEnabled },
                set: { if $0 { gopilot.projectContextEnabled = true } }
            )) {
                Text("Search the Whole Project")
                Text("Gopilot can look up any file in \(projectName).")
            }
            Toggle(isOn: Binding(
                get: { !gopilot.projectContextEnabled },
                set: { if $0 { gopilot.projectContextEnabled = false } }
            )) {
                Text("Attached Sources Only")
                Text(gopilot.mode == .agent ? "Not available in Agent mode, which needs the whole project." : "Gopilot reads only what you attach.")
            }
            .disabled(gopilot.mode == .agent)
        } label: {
            Label(
                gopilot.projectContextEnabled ? "Project: \(projectName)" : "Attached Only",
                systemImage: gopilot.projectContextEnabled ? "folder" : "folder.badge.minus"
            )
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(gopilot.isRunning)
        .help(gopilot.projectContextEnabled
              ? "Gopilot can search all of \(projectName). Click to limit it to attached sources."
              : "Gopilot reads only attached sources. Click to let it search the project.")
        .accessibilityLabel(gopilot.projectContextEnabled ? "Context scope: whole project \(projectName)" : "Context scope: attached sources only")
    }

    private func attachmentChip(for item: GopilotAttachment) -> some View {
        let fileName = (item.relativePath as NSString).lastPathComponent
        return GopilotContextChip(
            title: item.label,
            note: item.isUnsaved ? "Unsaved" : nil,
            isSuggestion: false,
            primaryHelp: "Preview \(item.label)",
            removeHelp: "Remove \(item.label)",
            primary: { previewingAttachmentID = (previewingAttachmentID == item.id) ? nil : item.id },
            remove: { gopilot.removeAttachment(id: item.id) }
        ) {
            FileIconView(
                fileName: fileName,
                path: item.absolutePath,
                isFolder: item.isFolder,
                isSelected: false,
                size: FileIconSize.compact
            )
        }
        .accessibilityLabel("Attached \(item.label)" + (item.isUnsaved ? ", unsaved" : ""))
        .popover(isPresented: Binding(
            get: { previewingAttachmentID == item.id },
            set: { if !$0 && previewingAttachmentID == item.id { previewingAttachmentID = nil } }
        ), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack(spacing: Spacing.row) {
                    FileIconView(fileName: fileName, path: item.absolutePath, isFolder: item.isFolder, isSelected: false, size: FileIconSize.compact)
                    Text(item.label)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(item.isFolder ? "Folder" : "Lines \(item.startLine)–\(item.endLine)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ScrollView {
                    Text(item.text.prefix(1200))
                        .font(.system(size: workspace.editorFontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 320, height: 160)
                if item.text.count > 1200 {
                    Text("Preview shows the first 1,200 characters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.comfortable)
        }
    }

    private var accessoryBar: some View {
        let activeRoute = gopilot.activeRoute
        let activeModelID = activeRoute?.id ?? settings.modelID
        let modelName = GopilotModelIdentity.prettyName(for: activeRoute)
        let supportsEffort = (activeRoute?.reasoningMode.supportedEfforts.count ?? 1) > 1
        let effortSuffix = supportsEffort && gopilot.selectedEffort != .default ? " · \(GopilotModelPickerPopover.effortTitle(gopilot.selectedEffort))" : ""
        let chatOnlySuffix = gopilot.activeRouteTier == .verifiedChatOnly ? " · Chat" : ""
        let liveLabel = (full: modelName + chatOnlySuffix + effortSuffix, short: modelName + chatOnlySuffix)
        let shownLabel = pinnedModelLabel ?? liveLabel

        return HStack(spacing: Spacing.standard) {
            modeMenu
                .layoutPriority(2)

            Button {
                if !showsModelPicker {
                    pinnedModelLabel = liveLabel
                }
                showsModelPicker.toggle()
            } label: {
                HStack(spacing: Spacing.compact) {
                    GopilotModelIconView(route: activeRoute, modelID: activeModelID, size: 16)
                    ViewThatFits(in: .horizontal) {
                        Text(shownLabel.full)
                            .fixedSize()
                        Text(shownLabel.short)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(availability == .notConfigured || gopilot.isRunning)
            .help("Model: \(modelName) (\(activeModelID)). Reasoning: \(GopilotModelPickerPopover.effortTitle(gopilot.selectedEffort)). Applies to your next message.")
            .accessibilityLabel("Model \(modelName), reasoning \(GopilotModelPickerPopover.effortTitle(gopilot.selectedEffort))")
            .onChange(of: showsModelPicker) { _, shown in
                if !shown {
                    pinnedModelLabel = nil
                }
            }
            .popover(isPresented: $showsModelPicker, arrowEdge: .top) {
                GopilotModelPickerPopover(
                    gopilot: gopilot,
                    settings: settings,
                    dismiss: { showsModelPicker = false }
                )
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if gopilot.isRunning {
                Button {
                    gopilot.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop (Esc)")
                .accessibilityLabel("Stop")
                .layoutPriority(3)
            } else {
                Button(action: submit) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!gopilot.canSend(workspacePath: workspace.activeWorkspacePath))
                .help("Send (Return)")
                .accessibilityLabel("Send")
                .layoutPriority(3)
            }
        }
    }

    private var modeMenu: some View {
        let isChatOnly = gopilot.activeRouteTier == .verifiedChatOnly
        return Menu {
            Section("Mode") {
                choiceToggle(.ask, disabledReason: nil)
            }
            Section("Agent Permissions") {
                ForEach([GopilotModeChoice.agentAskFirst, .agentAutoEdit, .agentAuto], id: \.self) { choice in
                    choiceToggle(choice, disabledReason: isChatOnly ? "Needs a model that supports tool calling. Choose another model." : nil)
                }
            }
        } label: {
            Text(modeChoice.title)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availability == .notConfigured || gopilot.isRunning)
        .help(gopilot.isRunning ? "Mode can change after Gopilot finishes. \(modeChoice.title): \(modeChoice.detail)" : "\(modeChoice.title): \(modeChoice.detail)")
        .accessibilityLabel("Mode and permissions: \(modeChoice.title)")
    }

    private func choiceToggle(_ choice: GopilotModeChoice, disabledReason: String?) -> some View {
        Toggle(isOn: Binding(
            get: { modeChoice == choice },
            set: { isOn in
                guard isOn else { return }
                if let permission = choice.permission {
                    gopilot.agentPermissionMode = permission
                }
                gopilot.mode = choice.mode
            }
        )) {
            Text(choice.title)
            Text(disabledReason ?? choice.detail)
        }
        .disabled(disabledReason != nil)
    }
}

struct GopilotContextChip<Icon: View>: View {
    let title: String
    var note: String? = nil
    let isSuggestion: Bool
    let primaryHelp: String
    let removeHelp: String
    let primary: () -> Void
    let remove: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
        HStack(spacing: Spacing.hairline) {
            Button(action: primary) {
                HStack(spacing: Spacing.compact) {
                    icon()
                    Text(title)
                        .foregroundStyle(isSuggestion ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryHelp)

            Button(action: remove) {
                Label(removeHelp, systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(removeHelp)
            .accessibilityLabel(removeHelp)
        }
        .font(.callout)
        .padding(.leading, Spacing.standard)
        .padding(.trailing, Spacing.hairline)
        .frame(minHeight: 24)
        .background(isSuggestion ? Color.clear : Color(nsColor: .quaternarySystemFill), in: shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: isSuggestion ? 1 : 0))
        .accessibilityElement(children: .contain)
    }
}

private struct GopilotComposerKeyHandler: NSViewRepresentable {
    var isActive: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Bool
    var onMoveMention: (Int) -> Bool
    var onAcceptMention: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.onMoveMention = onMoveMention
        context.coordinator.onAcceptMention = onAcceptMention
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        weak var view: NSView?
        var isActive = false
        var onSubmit: () -> Void = {}
        var onEscape: () -> Bool = { false }
        var onMoveMention: (Int) -> Bool = { _ in false }
        var onAcceptMention: () -> Bool = { false }
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive, let window = self.view?.window,
                      (event.window ?? NSApp.keyWindow) === window else { return event }
                let textView = window.firstResponder as? NSTextView
                if textView?.hasMarkedText() == true { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                switch event.keyCode {
                case 36, 76:
                    if modifiers.contains(.shift) || modifiers.contains(.option) {
                        textView?.insertNewlineIgnoringFieldEditor(nil)
                        return nil
                    }
                    guard modifiers.subtracting([.numericPad, .function]).isEmpty else { return event }
                    if self.onAcceptMention() { return nil }
                    self.onSubmit()
                    return nil
                case 48:
                    guard modifiers.isEmpty else { return event }
                    return self.onAcceptMention() ? nil : event
                case 125, 126:
                    guard modifiers.subtracting([.numericPad, .function]).isEmpty else { return event }
                    return self.onMoveMention(event.keyCode == 125 ? 1 : -1) ? nil : event
                case 53:
                    return self.onEscape() ? nil : event
                default:
                    return event
                }
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

struct GopilotModelPickerPopover: View {
    @Bindable var gopilot: GopilotState
    @Bindable var settings: GopilotProviderSettings
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    static func effortTitle(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .default: "Model Default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    private var allRoutes: [ModelRoute] {
        if !settings.routes.isEmpty {
            return settings.routes
        }
        if let fallback = gopilot.activeRoute {
            return [fallback]
        }
        return []
    }

    private var filteredRoutes: [ModelRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allRoutes }
        return allRoutes.filter { route in
            let pretty = GopilotModelIdentity.prettyName(for: route).lowercased()
            let apiSource = (GopilotModelIdentity.apiSourceSubtitle(for: route) ?? "").lowercased()
            return pretty.contains(trimmed) || route.id.lowercased().contains(trimmed) || apiSource.contains(trimmed)
        }
    }

    var body: some View {
        let activeRoute = gopilot.activeRoute
        let activeID = activeRoute?.id ?? settings.modelID
        let supported = activeRoute?.reasoningMode.supportedEfforts ?? [.default]
        let stops = [ReasoningEffort.default] + [.low, .medium, .high].filter { supported.contains($0) }

        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("Model")
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if allRoutes.count > 7 {
                TextField("Filter Models", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onAppear { isSearchFocused = true }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                    if filteredRoutes.isEmpty {
                        Text("No matching models.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(Spacing.standard)
                    } else {
                        ForEach(filteredRoutes) { route in
                            routeRow(route, isSelected: route.id == activeID)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Reasoning Effort")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if stops.count > 1 {
                    Picker("Reasoning Effort", selection: Binding(
                        get: { stops.contains(gopilot.selectedEffort) ? gopilot.selectedEffort : .default },
                        set: { gopilot.setReasoningEffort($0) }
                    )) {
                        ForEach(stops, id: \.self) { effort in
                            Text(Self.effortTitle(effort)).tag(effort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Model Default lets the provider decide. Higher effort is slower and uses more tokens.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(GopilotModelIdentity.prettyName(for: activeRoute)) uses its default reasoning.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Button("Manage Models…") {
                dismiss()
                openGopilotSettings()
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .padding(Spacing.comfortable)
        .frame(width: 320)
    }

    private func routeRow(_ route: ModelRoute, isSelected: Bool) -> some View {
        let pretty = GopilotModelIdentity.prettyName(for: route)
        let apiSource = GopilotModelIdentity.apiSourceSubtitle(for: route)
        let tier = settings.routeTier(for: route.id)
        return Button {
            gopilot.selectRoute(route.id)
            if isSelected { dismiss() }
        } label: {
            HStack(alignment: .center, spacing: Spacing.standard) {
                GopilotModelIconView(route: route, modelID: route.id, size: 20)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Text(pretty)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if tier == .verifiedChatOnly {
                            Text("Chat only")
                                .font(.subheadline)
                                .foregroundStyle(StatusTone.warning.tint)
                        }
                    }
                    if let apiSource, !apiSource.isEmpty {
                        Text(apiSource)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .background(
                isSelected ? Color(nsColor: .quaternarySystemFill) : Color.clear,
                in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pretty + (tier == .verifiedChatOnly ? ", chat only" : "") + (apiSource.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GopilotAddContextPopover: View {
    var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let dismiss: () -> Void
    @State private var tab = 0
    @State private var query = ""
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        let activeFileName = (workspace.activeFilePath as NSString).lastPathComponent
        let hasSelection = gopilot.hasActiveEditorSelection(in: workspace)
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Button {
                    if gopilot.attachCurrentFile(from: workspace) { dismiss() }
                } label: {
                    Label(workspace.activeFilePath.isEmpty ? "Add Current File" : "Add \(activeFileName)", systemImage: "doc.badge.plus")
                }
                .disabled(workspace.activeFilePath.isEmpty)
                .help(workspace.activeFilePath.isEmpty ? "Open a file in the editor first" : "Attach the whole file")

                Button {
                    if gopilot.attachSelection(from: workspace) { dismiss() }
                } label: {
                    Label("Add Selection", systemImage: "text.quote")
                }
                .disabled(!hasSelection)
                .help(hasSelection ? "Attach the selected code" : "Select code in the editor first")
            }
            .controlSize(.small)

            Picker("Context Type", selection: $tab) {
                Text("Files & Folders").tag(0)
                Text("Symbols").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(tab == 0 ? "Filter Files or Folders" : "Filter Go Symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFilterFocused)
                .onAppear { isFilterFocused = true }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                    if tab == 0 {
                        let isQueryEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let folders = Array(gopilot.availableFolders(in: workspace, query: query).prefix(isQueryEmpty ? 2 : 8))
                        let files = gopilot.availableFiles(in: workspace, query: query)
                        if folders.isEmpty && files.isEmpty {
                            Text("No matching files or folders in this project.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(Spacing.standard)
                        } else {
                            ForEach(folders, id: \.self) { folderRel in
                                GopilotMentionItemView(relativePath: folderRel, workspacePath: workspace.activeWorkspacePath, isFolder: true) {
                                    _ = gopilot.attachFolder(relativePath: folderRel, workspace: workspace, origin: .filePicker)
                                    dismiss()
                                }
                            }
                            ForEach(files, id: \.self) { rel in
                                GopilotMentionItemView(relativePath: rel, workspacePath: workspace.activeWorkspacePath) {
                                    _ = gopilot.attachFile(relativePath: rel, workspace: workspace, origin: .filePicker)
                                    dismiss()
                                }
                            }
                        }
                    } else {
                        let symbols = gopilot.availableSymbols(in: workspace, query: query)
                        if symbols.isEmpty {
                            Text("No matching Go symbols in this project.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(Spacing.standard)
                        } else {
                            ForEach(symbols) { sym in
                                sym.mentionItemView(workspacePath: workspace.activeWorkspacePath) {
                                    _ = gopilot.attachSymbol(sym, workspace: workspace, origin: .symbolPicker)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.compact)
            }
            .frame(height: 184)
        }
        .padding(Spacing.comfortable)
        .frame(width: 320)
    }
}

struct GopilotMentionSelection {
    let isSelected: Bool
    let select: () -> Void
}

extension View {
    @ViewBuilder
    fileprivate func gopilotContextRow(selection: GopilotMentionSelection?, isHovered: Binding<Bool>, action: @escaping () -> Void) -> some View {
        if let selection {
            popupRow(isSelected: selection.isSelected, onHoverSelect: selection.select, action: action)
        } else {
            let shape = RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
            Button(action: action) {
                background(isHovered.wrappedValue ? Color(nsColor: .quaternarySystemFill) : Color.clear, in: shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { isHovered.wrappedValue = $0 }
        }
    }
}

struct GopilotMentionItemView<Icon: View>: View {
    let title: String
    var isProminent: Bool = false
    var subtitle: String? = nil
    var subtitleFileName: String? = nil
    var subtitleFilePath: String? = nil
    let accessibilityTitle: String
    var selection: GopilotMentionSelection? = nil
    let action: () -> Void
    @ViewBuilder let icon: (Bool) -> Icon
    @State private var isHovered = false

    var body: some View {
        let isSelected = selection?.isSelected == true
        HStack(spacing: Spacing.row) {
            icon(isSelected)
            Text(title)
                .font(isProminent ? .callout.weight(.medium) : .callout)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: subtitle == nil ? 0 : Spacing.compact)
            if let subtitleFileName {
                FileIconView(
                    fileName: subtitleFileName,
                    path: subtitleFilePath,
                    isSelected: isSelected,
                    size: FileIconSize.compact
                )
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.row)
        .padding(.vertical, Spacing.compact)
        .gopilotContextRow(selection: selection, isHovered: $isHovered, action: action)
        .accessibilityLabel(accessibilityTitle)
    }
}

extension GopilotMentionItemView where Icon == FileIconView {
    init(
        relativePath: String,
        workspacePath: String,
        isFolder: Bool = false,
        selection: GopilotMentionSelection? = nil,
        action: @escaping () -> Void
    ) {
        let fileName = (relativePath as NSString).lastPathComponent
        self.init(
            title: isFolder ? "\(relativePath)/" : relativePath,
            isProminent: false,
            accessibilityTitle: "Attach \(isFolder ? "folder" : "file") \(relativePath)",
            selection: selection,
            action: action
        ) { isSelected in
            FileIconView(
                fileName: fileName,
                path: workspacePath.isEmpty ? nil : workspacePath + "/" + relativePath,
                isFolder: isFolder,
                isSelected: isSelected,
                size: FileIconSize.compact
            )
        }
    }
}

extension GopilotSymbolCandidate {
    @MainActor
    func mentionItemView(
        workspacePath: String,
        selection: GopilotMentionSelection? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let fileName = (relativePath as NSString).lastPathComponent
        return GopilotMentionItemView(
            title: name,
            isProminent: true,
            subtitle: subtitle,
            subtitleFileName: fileName,
            subtitleFilePath: workspacePath.isEmpty ? nil : workspacePath + "/" + relativePath,
            accessibilityTitle: "Attach \(kind) \(name), \(subtitle)",
            selection: selection,
            action: action
        ) { isSelected in
            Image(systemName: kind == "type" ? "cube" : "function")
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
        }
    }
}

enum GopilotMentionCandidate {
    case folder(String)
    case file(String)
    case symbol(GopilotSymbolCandidate)

    @MainActor
    static func candidates(for query: String, workspace: WorkspaceState, gopilot: GopilotState) -> [GopilotMentionCandidate] {
        gopilot.availableFolders(in: workspace, query: query).prefix(3).map { .folder($0) }
            + gopilot.availableFiles(in: workspace, query: query).prefix(4).map { .file($0) }
            + gopilot.availableSymbols(in: workspace, query: query).prefix(3).map { .symbol($0) }
    }

    @MainActor
    func attach(workspace: WorkspaceState, gopilot: GopilotState) {
        switch self {
        case .folder(let path): _ = gopilot.attachFolder(relativePath: path, workspace: workspace, origin: .atMention)
        case .file(let path): _ = gopilot.attachFile(relativePath: path, workspace: workspace, origin: .atMention)
        case .symbol(let symbol): _ = gopilot.attachSymbol(symbol, workspace: workspace, origin: .atMention)
        }
        gopilot.mentionSelection = 0
    }
}

private struct GopilotInlineMentionMenu: View {
    let query: String
    var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState

    var body: some View {
        let candidates = GopilotMentionCandidate.candidates(for: query, workspace: workspace, gopilot: gopilot)
        let selected = min(max(gopilot.mentionSelection, 0), max(candidates.count - 1, 0))

        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Attach with @")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.row)
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    row(candidate, selection: GopilotMentionSelection(isSelected: index == selected) { gopilot.mentionSelection = index })
                }
            }
            .padding(Spacing.standard)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .help("Up and Down Arrow choose, Return or Tab attaches, Esc closes")
            .onAppear { gopilot.mentionSelection = 0 }
            .onChange(of: query) { _, _ in gopilot.mentionSelection = 0 }
        }
    }

    @ViewBuilder
    private func row(_ candidate: GopilotMentionCandidate, selection: GopilotMentionSelection) -> some View {
        let attach = { candidate.attach(workspace: workspace, gopilot: gopilot) }
        switch candidate {
        case .folder(let path):
            GopilotMentionItemView(relativePath: path, workspacePath: workspace.activeWorkspacePath, isFolder: true, selection: selection, action: attach)
        case .file(let path):
            GopilotMentionItemView(relativePath: path, workspacePath: workspace.activeWorkspacePath, selection: selection, action: attach)
        case .symbol(let symbol):
            symbol.mentionItemView(workspacePath: workspace.activeWorkspacePath, selection: selection, action: attach)
        }
    }
}
