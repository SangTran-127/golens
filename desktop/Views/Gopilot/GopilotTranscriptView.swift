import AppKit
import GopilotPolicy
import SwiftUI

struct GopilotTurn: Identifiable {
    let id: String
    var promptText: String?
    var promptAttachment: String?
    var steps: [GopilotActivityStep] = []
    var results: [GopilotTranscriptItem] = []

    var hasPlanUpdate: Bool { steps.contains { $0.isPlanUpdate } }

    static func group(_ items: [GopilotTranscriptItem], isNarration: (UUID) -> Bool) -> [GopilotTurn] {
        var turns: [GopilotTurn] = []
        for item in items {
            switch item {
            case .user(let id, let text, let attachment):
                turns.append(GopilotTurn(id: id.uuidString, promptText: text, promptAttachment: attachment))
            case .activity(let id, let label, let status):
                if turns.isEmpty { turns.append(GopilotTurn(id: "lead-\(id)")) }
                turns[turns.count - 1].steps.append(GopilotActivityStep(id: id, label: label, status: status))
            case .assistant(let id, let text) where isNarration(id):
                if turns.isEmpty { turns.append(GopilotTurn(id: "lead-\(item.id)")) }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    turns[turns.count - 1].steps.append(GopilotActivityStep(id: id.uuidString, label: trimmed, status: .finished, isNarration: true))
                }
            default:
                if turns.isEmpty { turns.append(GopilotTurn(id: "lead-\(item.id)")) }
                turns[turns.count - 1].results.append(item)
            }
        }
        return turns
    }
}

private struct GopilotScrollMetrics: Equatable {
    let visibleMaxY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

private struct GopilotFollowLatest: ViewModifier {
    @Binding var isPinned: Bool
    @State private var isReaderScrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if isReaderScrolling != scrolling { isReaderScrolling = scrolling }
            }
            .onScrollGeometryChange(for: GopilotScrollMetrics.self) { geometry in
                GopilotScrollMetrics(
                    visibleMaxY: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { old, new in
                guard old.contentHeight == new.contentHeight, old.containerHeight == new.containerHeight else { return }
                let wanted: Bool
                if new.visibleMaxY >= new.contentHeight - 24 {
                    wanted = true
                } else if isReaderScrolling, new.visibleMaxY < old.visibleMaxY - 1 {
                    wanted = false
                } else {
                    return
                }
                guard wanted != isPinned else { return }
                let pinned = $isPinned
                DispatchQueue.main.async {
                    if pinned.wrappedValue != wanted { pinned.wrappedValue = wanted }
                }
            }
    }
}

struct GopilotTranscriptView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let previewAwaitingPermission: Bool
    let previewTurnChanges: [GopilotTurnChange]
    let focusComposer: () -> Void
    @State private var isPinnedToBottom = true

    private static let bottomID = "gopilot-transcript-bottom"

    private var contentSignature: String {
        var signature = "\(gopilot.items.count)|\(gopilot.agentTodos.count)|\(gopilot.interaction.approval != nil)|\(gopilot.isRunning)"
        if let last = gopilot.items.last {
            switch last {
            case .assistant(let id, let text): signature += "|\(id)|\(text.utf16.count)"
            case .activity(let id, _, let status): signature += "|\(id)|\(status)"
            default: signature += "|\(last.id)"
            }
        }
        return signature
    }

    private var latestPromptID: String? {
        gopilot.items.last { if case .user = $0 { true } else { false } }?.id
    }

    private func planTurnID(in turns: [GopilotTurn]) -> String? {
        guard !gopilot.agentTodos.isEmpty else { return nil }
        return turns.last(where: { $0.hasPlanUpdate })?.id ?? turns.last?.id
    }

    var body: some View {
        let turns = GopilotTurn.group(gopilot.items, isNarration: { gopilot.isStepNarration($0) })
        let planTurn = planTurnID(in: turns)
        let isAwaitingPermission = gopilot.interaction.approval != nil || previewAwaitingPermission
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.content) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        let isLast = index == turns.count - 1
                        GopilotTurnView(
                            workspace: workspace,
                            gopilot: gopilot,
                            turn: turn,
                            isLive: isLast && gopilot.isRunning,
                            todos: turn.id == planTurn ? gopilot.agentTodos : [],
                            isAwaitingPermission: isLast && isAwaitingPermission,
                            previewChanges: isLast ? previewTurnChanges : [],
                            focusComposer: focusComposer
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.section)
                .padding(.bottom, Spacing.standard)
            }
            .modifier(GopilotFollowLatest(isPinned: $isPinnedToBottom))
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    Button {
                        isPinnedToBottom = true
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(Spacing.comfortable)
                    .help("Scroll to the newest message")
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: latestPromptID) { _, _ in
                isPinnedToBottom = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: contentSignature) { _, _ in
                if isPinnedToBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == GopilotAssistantText.citationScheme, let id = url.host?.uppercased() {
                    if let evidence = gopilot.evidence(forID: id) {
                        gopilot.openCitation(evidence, workspace: workspace)
                    }
                    return .handled
                }
                if url.scheme == GopilotAssistantText.fileScheme,
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value {
                    let line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init) ?? 1
                    gopilot.openRelativeFile(path: rawPath, line: line, workspace: workspace)
                    return .handled
                }
                if url.scheme == "http" || url.scheme == "https" {
                    return .handled
                }
                return .discarded
            })
        }
    }
}

private struct GopilotTurnView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let turn: GopilotTurn
    let isLive: Bool
    let todos: [GopilotTodoItem]
    let isAwaitingPermission: Bool
    let previewChanges: [GopilotTurnChange]
    let focusComposer: () -> Void

    private var showsRun: Bool {
        turn.steps.contains { !$0.isPlanUpdate } || !todos.isEmpty || isAwaitingPermission
    }

    private var journalTurnID: UUID? {
        UUID(uuidString: turn.id).flatMap { gopilot.turnID(forUserItemID: $0) }
    }

    private var turnChanges: [GopilotTurnChange] {
        if let journalTurnID {
            let recorded = gopilot.changes(inTurn: journalTurnID)
            if !recorded.isEmpty { return recorded }
        }
        return previewChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            if let prompt = turn.promptText {
                GopilotUserBubble(text: prompt, attachment: turn.promptAttachment)
            }
            if showsRun {
                GopilotRunSection(
                    steps: turn.steps,
                    todos: todos,
                    isLive: isLive,
                    isAwaitingPermission: isAwaitingPermission
                )
            }
            let changes = turnChanges
            ForEach(changes.isEmpty ? turn.results : turn.results.filter { if case .applied = $0 { false } else { true } }, id: \.id) { item in
                resultRow(item)
            }
            if !changes.isEmpty {
                GopilotTurnChangesCard(
                    changes: changes,
                    isLive: isLive,
                    refresh: { gopilot.refreshChangeJournal() },
                    review: { proposalID in Task { await gopilot.review(proposalID) } },
                    saveAll: { if let journalTurnID { gopilot.saveChanges(inTurn: journalTurnID) } },
                    undoAll: {
                        guard let journalTurnID else { return GopilotUndoAllResult() }
                        return await gopilot.undoAllChanges(inTurn: journalTurnID)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultRow(_ item: GopilotTranscriptItem) -> some View {
        switch item {
        case .assistant(let id, let text):
            if gopilot.isThinkingLine(for: id, text: text) {
                GopilotLiveThinkingRow(text: text)
            } else {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    GopilotAssistantText(text: text, citations: gopilot.citationSegments[id.uuidString])
                        .equatable()
                    GopilotAssistantFooter(
                        canSaveNote: !isLive && !workspace.activeWorkspacePath.isEmpty && text.count > 40,
                        usage: gopilot.answerUsage[id.uuidString],
                        sourcesUsed: gopilot.answerSourcesUsed[id.uuidString],
                        openSource: { sourceItem in
                            gopilot.openSourceUsageItem(sourceItem, workspace: workspace)
                        },
                        saveNote: { Task { await gopilot.pinNote(text, itemID: id.uuidString) } }
                    )
                }
            }
        case .applied(let id, let text):
            GopilotAppliedRow(
                text: text,
                viewDiff: gopilot.proposalPaths[id]?.isEmpty == false ? {
                    Task { await gopilot.openProposalInEditorDiff(id, workspace: workspace) }
                } : nil
            ) {
                Task { await gopilot.undoApplied(id, workspace: workspace) }
            }
        case .proposal(let id, let summary, let files, let warnings):
            GopilotProposalCard(
                summary: summary,
                files: files,
                warnings: warnings,
                viewDiff: gopilot.proposalPaths[id]?.isEmpty == false ? {
                    Task { await gopilot.openProposalInEditorDiff(id, workspace: workspace) }
                } : nil,
                apply: { Task { await gopilot.applyProposalDirectly(id, workspace: workspace, autoApplied: false) } },
                review: { Task { await gopilot.review(id) } }
            )
        case .notice(_, let kind, let text, let canRetry):
            GopilotNoticeRow(
                kind: kind,
                text: text,
                canRetry: canRetry,
                isAgentMode: gopilot.mode == .agent,
                retry: { gopilot.retry() },
                openSettings: openGopilotSettings,
                trust: { gopilot.trustProject() },
                continueFindings: { gopilot.continueFromFindings() },
                narrowQuestion: {
                    gopilot.prepareNarrowerQuestion(workspace: workspace)
                    focusComposer()
                },
                retryDefaultEffort: { gopilot.retryWithDefaultEffort() },
                verifyRoute: { routeID in gopilot.verifyAndRetryAgentRoute(routeID) },
                newConversation: { gopilot.newConversation() }
            )
        case .user(_, let text, let attachment):
            GopilotUserBubble(text: text, attachment: attachment)
        case .activity(_, let label, let status):
            GopilotRunSection(
                steps: [GopilotActivityStep(id: item.id, label: label, status: status)],
                todos: [],
                isLive: isLive,
                isAwaitingPermission: false
            )
        }
    }
}
