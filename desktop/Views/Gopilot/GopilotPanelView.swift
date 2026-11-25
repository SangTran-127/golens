import AppKit
import GopilotAnalysis
import GopilotProvider
import GopilotRuntime
import GopilotStore
import SwiftUI

@MainActor
func openGopilotSettings() {
    UserDefaults.standard.set("gopilot", forKey: "GoLensSettingsPane")
    if let appMenu = NSApp.mainMenu?.items.first?.submenu,
       let item = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
        appMenu.performActionForItem(at: appMenu.index(of: item))
        return
    }
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

private struct ReviewItem: Identifiable {
    let proposal: PatchProposal
    var id: UUID { proposal.id }
}

struct GopilotPanelView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    @FocusState private var composerFocused: Bool
    @State private var showsHistory = false
    @State private var showsProjectNotes = false
    @State private var previewApproval: GopilotApprovalContent?
    @State private var previewTurnChanges: [GopilotTurnChange] = []
    @State private var previewPendingProposal: UUID?

    private var availability: GopilotState.Availability {
        gopilot.availability(workspacePath: workspace.activeWorkspacePath)
    }

    private var hasActiveChatState: Bool {
        !gopilot.items.isEmpty || gopilot.viewingSaved != nil || gopilot.conversationID != nil
    }

    private var showsComposer: Bool {
        availability != .notConfigured || hasActiveChatState
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsComposer {
                GopilotComposerArea(
                    workspace: workspace,
                    gopilot: gopilot,
                    availability: availability,
                    composerFocused: $composerFocused,
                    previewApproval: previewApproval,
                    previewPendingProposal: previewPendingProposal
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            composerFocused = true
            runLaunchHooks()
        }
        .onChange(of: workspace.activeFilePath) { _, _ in
            gopilot.dismissedActiveFilePath = nil
        }
        .sheet(isPresented: Binding(get: { !gopilot.recovery.isEmpty }, set: { if !$0 { gopilot.recovery = [] } })) {
            GopilotRecoverySheet(diffs: gopilot.recovery) { gopilot.recovery = [] }
        }
        .sheet(item: Binding(get: { gopilot.reviewing.map { ReviewItem(proposal: $0) } }, set: { if $0 == nil { gopilot.reviewing = nil; gopilot.reviewDiffs = [] } })) { item in
            GopilotReviewSheet(workspace: workspace, gopilot: gopilot, proposal: item.proposal)
        }
    }

    private func runLaunchHooks() {
        let env = ProcessInfo.processInfo.environment
        if env["GOPILOT_TOGGLE_ACTIVE_FILE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                gopilot.toggleActiveFileAttachment(in: workspace)
            }
        }
        if env["GOPILOT_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                openGopilotSettings()
            }
        }
        if let prefillDraft = env["GOPILOT_PREFILL_DRAFT"], !prefillDraft.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                gopilot.draft = prefillDraft
            }
        }
        if let viewState = env["GOPILOT_DEV_VIEW_STATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                applyPreviewState(viewState)
            }
        }
    }

    private func applyPreviewState(_ name: String) {
        switch name {
        case "approval_waiting":
            gopilot.items.append(.user(id: UUID(), text: "Run the order service tests and fix any failure", attachment: nil))
            gopilot.items.append(.activity(id: "preview-read", label: "Reading service.go", status: .finished))
            gopilot.items.append(.activity(id: "preview-edit", label: "Editing service.go", status: .finished))
            gopilot.items.append(.activity(id: "preview-run", label: "Running tests", status: .running))
            gopilot.agentTodos = [
                GopilotTodoItem(id: "p1", content: "Read the reservation flow in service.go", status: .completed),
                GopilotTodoItem(id: "p2", content: "Fix the stock check in Reserve", status: .completed),
                GopilotTodoItem(id: "p3", content: "Run go test for the order package", status: .inProgress)
            ]
            gopilot.isRunning = true
            previewApproval = GopilotApprovalContent(
                title: "Run tests?",
                rows: [
                    ("Package", "example.com/order-service"),
                    ("Tests", "TestReserve, TestCreateOrder"),
                    ("Folder", "orders"),
                    ("Limit", "60 s, 1 run")
                ],
                command: "go test -run ^(TestReserve|TestCreateOrder)$ -count=1 .",
                notes: [],
                warning: "Runs in the Linux container. The project folder is shared read-write, so the code can change or delete project files.",
                accessibilitySummary: "Approval needed to run tests"
            )
        case "turn_summary":
            let turnID = UUID()
            let pendingID = UUID()
            previewPendingProposal = pendingID
            previewTurnChanges = [
                GopilotTurnChange(turnID: turnID, proposalID: UUID(), path: "README.md", isNewFile: true, status: .applied, additions: 68, deletions: 0, isUnsaved: true, detail: nil),
                GopilotTurnChange(turnID: turnID, proposalID: UUID(), path: "service.go", isNewFile: false, status: .applied, additions: 6, deletions: 2, isUnsaved: false, detail: nil),
                GopilotTurnChange(turnID: turnID, proposalID: pendingID, path: "GOLENS.md", isNewFile: false, status: .pendingReview, additions: 12, deletions: 1, isUnsaved: false, detail: "GOLENS.md had unsaved edits, so the change waits for your review."),
                GopilotTurnChange(turnID: turnID, proposalID: UUID(), path: "go.mod", isNewFile: false, status: .failed, additions: 1, deletions: 1, isUnsaved: false, detail: "The file changed on disk before the edit could be applied.")
            ]
        case "review_sheet":
            let before = "# Order Service\n\nA small HTTP service.\n"
            let after = "# Order Service\n\nA small HTTP service that reserves stock and stores orders.\n\n## Architecture\n\n- handler.go decodes requests\n- service.go reserves inventory\n- repository.go stores orders\n\n## Tests\n\nRun go test ./... before committing.\n"
            gopilot.reviewDiffs = [
                GopilotFileDiff(path: "GOLENS.md", isNew: false, lines: LineDiff.diff(from: before, to: after).lines, truncated: false)
            ]
            gopilot.reviewing = PatchProposal(
                turnID: UUID(),
                rationale: "Update GOLENS.md with repository architecture and test conventions",
                operations: [PatchFileOperation(kind: .edit, path: "GOLENS.md")],
                verificationPlan: ["Open GOLENS.md and read the new Architecture section."]
            )
        default:
            break
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.standard) {
            Text("Gopilot")
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if gopilot.viewingSaved != nil {
                Label("Saved Conversation", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if availability != .notConfigured || hasActiveChatState {
                HStack(spacing: Spacing.hairline) {
                    TabButton(
                        title: workspace.activeWorkspacePath.isEmpty ? "Project Notes are available when a project is open" : "Project Notes",
                        icon: "note.text",
                        isSelected: showsProjectNotes
                    ) {
                        showsProjectNotes.toggle()
                    }
                    .frame(width: 32)
                    .accessibilityLabel("Project Notes")
                    .disabled(workspace.activeWorkspacePath.isEmpty)
                    .popover(isPresented: $showsProjectNotes, arrowEdge: .bottom) {
                        GopilotProjectNotesPopover(workspace: workspace, gopilot: gopilot) {
                            showsProjectNotes = false
                        }
                    }

                    TabButton(
                        title: workspace.activeWorkspacePath.isEmpty ? "History is available when a project is open" : "Conversation History",
                        icon: "clock.arrow.circlepath",
                        isSelected: showsHistory
                    ) {
                        showsHistory.toggle()
                    }
                    .frame(width: 32)
                    .accessibilityLabel("Conversation History")
                    .disabled(workspace.activeWorkspacePath.isEmpty)
                    .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                        GopilotHistoryView(gopilot: gopilot) { showsHistory = false }
                    }

                    TabButton(title: "New Conversation", icon: "square.and.pencil", isSelected: false) {
                        gopilot.newConversation()
                        composerFocused = true
                    }
                    .frame(width: 32)
                    .disabled(gopilot.items.isEmpty && !gopilot.isRunning && gopilot.viewingSaved == nil)
                }
                .padding(Spacing.hairline)
                .modifier(NavigatorTabCluster())
            }
        }
        .frame(minHeight: 30)
        .padding(.leading, Spacing.section)
        .padding(.trailing, Spacing.standard)
        .padding(.vertical, Spacing.row)
    }

    @ViewBuilder
    private var content: some View {
        if !gopilot.items.isEmpty {
            GopilotTranscriptView(
                workspace: workspace,
                gopilot: gopilot,
                previewAwaitingPermission: previewApproval != nil,
                previewTurnChanges: previewTurnChanges,
                focusComposer: { composerFocused = true }
            )
        } else if availability == .notConfigured && !hasActiveChatState {
            setupState
        } else {
            emptyState
        }
    }

    private var setupState: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("Set Up Gopilot")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Connect an OpenAI-compatible provider to ask about your project. Code is sent to the provider only when you ask.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Agent mode, which can change files and run checks, needs a model that supports tool calling.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Gopilot…", action: openGopilotSettings)
                .buttonStyle(.borderedProminent)
                .padding(.top, Spacing.standard)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        _ = (workspace.cursorLine, workspace.cursorCol, workspace.activeFilePath)
        let hasSelection = gopilot.hasActiveEditorSelection(in: workspace)
        let choice = GopilotModeChoice(mode: gopilot.mode, permission: gopilot.agentPermissionMode)
        let title: String
        let subtitle: String
        if availability == .noWorkspace {
            title = "Ask About Go"
            subtitle = "Open a project to ask about its code. You can still ask general Go questions."
        } else {
            title = gopilot.mode == .agent ? "Change Your Project" : "Explore Your Project"
            subtitle = choice.emptyStateLine
        }
        return VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if availability == .ready {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    GopilotSuggestionRow(
                        symbol: "map",
                        title: "Understand Project",
                        detail: nil,
                        help: "Summarize the module and trace one main flow",
                        isEnabled: !gopilot.isRunning
                    ) {
                        gopilot.send(GopilotPresetPrompt.understandProject)
                    }
                    GopilotSuggestionRow(
                        symbol: "text.magnifyingglass",
                        title: "Explain Selection",
                        detail: hasSelection ? nil : "Select code in the editor first",
                        help: hasSelection ? "Explain the selected code" : "Select code in the editor first",
                        isEnabled: !gopilot.isRunning && hasSelection
                    ) {
                        gopilot.explainSelection(workspace: workspace)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GopilotSuggestionRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.standard) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .frame(minHeight: 32)
            .background(
                Color(nsColor: .quaternarySystemFill),
                in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? help)
    }
}

struct GopilotModelIconView: View {
    var route: ModelRoute? = nil
    let modelID: String
    var size: CGFloat = 15

    @AppStorage(FileIconPalette.coloredKey) private var colored = true

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var imageCache: [String: NSImage] = [:]

    init(route: ModelRoute? = nil, modelID: String? = nil, size: CGFloat = 15) {
        self.route = route
        self.modelID = modelID ?? route?.id ?? ""
        self.size = size
    }

    private var iconSlug: String? {
        if let route, let slug = GopilotModelIdentity.resolveIconSlug(for: route) {
            return slug
        }
        return GopilotModelIdentity.resolveIconSlug(modelID: modelID)
    }

    private static func loadBundledPDF(named resourceName: String, isTemplate: Bool) -> NSImage? {
        let key = "\(resourceName)|\(isTemplate ? "T" : "O")"
        cacheLock.lock()
        if let cached = imageCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let url = AppResourceBundle.url(forResource: resourceName, withExtension: "pdf")
            ?? AppResourceBundle.bundle.url(forResource: resourceName, withExtension: "pdf", subdirectory: "ProviderIcons")
        guard let url, let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.isTemplate = isTemplate
        cacheLock.lock()
        imageCache[key] = img
        cacheLock.unlock()
        return img
    }

    var body: some View {
        let isDark = WorkspaceState.shared.currentTheme.resolvedIsDark
        Group {
            if let slug = iconSlug {
                if colored,
                   let colorImg = Self.resolveColorImage(for: slug, isDark: isDark) {
                    Image(nsImage: colorImg)
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else if let templateImg = Self.loadBundledPDF(named: "provider-\(slug)", isTemplate: true) {
                    Image(nsImage: templateImg)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                } else {
                    fallbackSymbol
                }
            } else {
                fallbackSymbol
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func resolveColorImage(for slug: String, isDark: Bool) -> NSImage? {
        if slug == "kimi" {
            let name = isDark ? "provider-kimi-color-dark" : "provider-kimi-color-light"
            return loadBundledPDF(named: name, isTemplate: false)
        }
        return loadBundledPDF(named: "provider-\(slug)-color", isTemplate: false)
    }

    private var fallbackSymbol: some View {
        Image(systemName: "cpu")
            .resizable()
            .scaledToFit()
            .frame(width: max(10, size * 0.78), height: max(10, size * 0.78))
            .foregroundStyle(.secondary)
    }
}

private struct GopilotProjectNotesPopover: View {
    var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let onDismiss: () -> Void

    private var workspaceName: String {
        let path = workspace.activeWorkspacePath
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var golensNotesPath: String {
        guard !workspace.activeWorkspacePath.isEmpty else { return "" }
        return (workspace.activeWorkspacePath as NSString).appendingPathComponent("GOLENS.md")
    }

    private var hasGolensNotesFile: Bool {
        !golensNotesPath.isEmpty && FileManager.default.fileExists(atPath: golensNotesPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            HStack(alignment: .center, spacing: Spacing.standard) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("Project Notes")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Spacing.standard)

                if !golensNotesPath.isEmpty {
                    Button {
                        openOrCreateGolensFile()
                    } label: {
                        Label(hasGolensNotesFile ? "Open GOLENS.md" : "Create GOLENS.md", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(hasGolensNotesFile ? "Open GOLENS.md" : "Create GOLENS.md")
                }
            }

            if workspace.activeWorkspacePath.isEmpty {
                Text("Open a project in GoLens to use or manage project notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Use Project Notes", isOn: Binding(
                    get: { gopilot.recallEnabled },
                    set: { value in Task { await gopilot.setRecall(value) } }
                ))
                .controlSize(.small)

                Divider()

                if gopilot.memoryNotes.isEmpty {
                    Text("No notes saved for \(workspaceName) yet. Click “Save Note” under any useful answer in Gopilot chat to keep it for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.standard) {
                            ForEach(gopilot.memoryNotes) { note in
                                HStack(alignment: .top, spacing: Spacing.standard) {
                                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                                        Text(note.content)
                                            .font(.callout)
                                            .lineLimit(3)
                                        HStack(spacing: Spacing.row) {
                                            if let approved = note.userApprovedAt {
                                                Text(approved.formatted(date: .abbreviated, time: .shortened))
                                            }
                                            if note.isStale {
                                                Label("May be out of date", systemImage: "exclamationmark.triangle")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: Spacing.standard)
                                    Button {
                                        Task { await gopilot.deleteNote(note.id) }
                                    } label: {
                                        Label("Delete Note", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete Note")
                                    .accessibilityLabel("Delete Note")
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }

                if let message = gopilot.memoryMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.comfortable)
        .frame(width: 360)
        .task { await gopilot.refreshMemory() }
    }

    private func openOrCreateGolensFile() {
        guard !golensNotesPath.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: golensNotesPath) {
            let initial = "# Project Notes (\(workspaceName))\n\nDocument architecture conventions, build flags, and test instructions for Gopilot here.\n"
            try? initial.write(toFile: golensNotesPath, atomically: true, encoding: .utf8)
        }
        onDismiss()
        workspace.openFile(golensNotesPath)
    }
}

struct GopilotPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.sidebarPanel, style: .continuous)
        let edge = ChromeColor.separator
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .clipShape(shape)
                .overlay(shape.stroke(edge, lineWidth: Stroke.standard))
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}
