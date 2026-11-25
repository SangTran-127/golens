import AppKit
import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools
import Observation

@Observable
final class GopilotState {
    @ObservationIgnored weak var hostWorkspace: WorkspaceState?
    var workspaceState: WorkspaceState { hostWorkspace ?? WorkspaceState.shared }
    enum Availability: Equatable {
        case notConfigured
        case noWorkspace
        case ready
    }

    struct TurnAccounting {
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var requests = 0
        var attachedItems: [SourceUsageItem] = []
        var lookedUpItems: [SourceUsageItem] = []
        var accessedPaths: Set<String> = []
    }

    struct WorkspaceIndexCache {
        var workspacePath = ""
        var timestamp: Date = .distantPast
        var files: [String] = []
        var folders: [String] = []
    }

    private static let visibilityKey = "GoLensShowGopilot"
    private static let modeKey = "GoLensGopilotMode"
    private static let agentPermissionModeKey = "GoLensGopilotAgentPermissionMode"
    private static let projectContextKey = "GoLensGopilotProjectContext"
    static let activeConversationMapKey = "GoLensGopilotActiveConversationByWorkspace"
    private static let permissionDefaultMigrationKey = "GoLensGopilotPermissionDefaultMigrated"

    var isPanelVisible: Bool = UserDefaults.standard.bool(forKey: GopilotState.visibilityKey) {
        didSet { UserDefaults.standard.set(isPanelVisible, forKey: Self.visibilityKey) }
    }
    var mode: GopilotMode = GopilotMode(rawValue: UserDefaults.standard.string(forKey: GopilotState.modeKey) ?? "") ?? .ask {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .agent && !projectContextEnabled {
                projectContextEnabled = true
            }
            syncPermissionModeWithSession()
        }
    }

    static func initialAgentPermissionMode(defaults: UserDefaults = .standard) -> GopilotAgentPermissionMode {
        if let raw = defaults.string(forKey: agentPermissionModeKey), let chosen = GopilotAgentPermissionMode(rawValue: raw) {
            defaults.set(true, forKey: permissionDefaultMigrationKey)
            return chosen
        }
        if !defaults.bool(forKey: permissionDefaultMigrationKey) {
            defaults.set(true, forKey: permissionDefaultMigrationKey)
            GopilotTrust.removeAll(defaults: defaults)
        }
        return GopilotAgentPermissionMode.defaultMode
    }

    var agentPermissionMode: GopilotAgentPermissionMode = GopilotState.initialAgentPermissionMode() {
        didSet {
            UserDefaults.standard.set(agentPermissionMode.rawValue, forKey: Self.agentPermissionModeKey)
            syncPermissionModeWithSession()
        }
    }
    var projectContextEnabled: Bool = (UserDefaults.standard.object(forKey: GopilotState.projectContextKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(projectContextEnabled, forKey: Self.projectContextKey) }
    }
    var selectedRouteID: String = GopilotProviderSettings.shared.defaultRouteID
    var selectedEffort: ReasoningEffort = .default
    var dismissedActiveFilePath: String?
    var includeProblemsInContext = false
    var dismissedProblemsSuggestion = false
    var agentTodos: [GopilotTodoItem] = []
    var proposalPaths: [UUID: [String]] = [:]
    var draft: String = "" {
        didSet {
            if dismissedMentionQuery != nil, activeMentionQuery != dismissedMentionQuery { dismissedMentionQuery = nil }
        }
    }
    var mentionSelection = 0
    var dismissedMentionQuery: String?
    var items: [GopilotTranscriptItem] = []
    var isRunning = false
    var attachments: [GopilotAttachment] = []
    var attachment: GopilotAttachment? {
        get { attachments.first }
        set {
            if let newValue {
                upsertAttachment(newValue)
            } else {
                attachments.removeAll()
            }
        }
    }
    var citationSegments: [String: [CitationSegment]] = [:]
    var savedConversations: [GopilotStore.ConversationSummary] = []
    var viewingSaved: Conversation?
    var lastTrashed: GopilotStore.ConversationSummary?
    var memoryNotes: [MemoryNote] = []
    var recallEnabled = true
    var memoryMessage: String?
    var reviewing: PatchProposal?
    var recovery: [RecoveryDiff] = []
    var usageSummary: String?
    var answerUsage: [String: String] = [:]
    var answerSourcesUsed: [String: SourcesUsedSummary] = [:]
    #if DEBUG
    @ObservationIgnored var evalObserver: ((AgentEvent) -> Void)?
    var evalSession: GopilotSessionContext? { session }
    #endif
    var reviewDiffs: [GopilotFileDiff] = []
    @ObservationIgnored var cardedProposals: Set<UUID> = []
    @ObservationIgnored var persistedEvidence: Set<String> = []
    @ObservationIgnored var turnAccounting = TurnAccounting()
    @ObservationIgnored var turnProvenance: [UUID: Set<String>] = [:]
    @ObservationIgnored var priorTurns: [ConversationTurn] = []
    @ObservationIgnored var compactedSummary: GopilotPolicy.ConversationSummary?
    var workspacePath = ""
    var lastPrompt = ""

    let interaction = GopilotInteractionCenter()
    var profilePaths: [String] = []
    @ObservationIgnored lazy var factory: GopilotRuntimeFactory = GopilotLiveFactory(
        settings: .shared,
        center: interaction,
        profilePaths: { [weak self] in
            await MainActor.run { self?.profilePaths ?? [] }
        },
        autoApplyProposal: { [weak self] proposalID in
            guard let self else { return .notPermitted }
            return await self.autoApplyProposalIfPermitted(proposalID)
        },
        currentTurnID: { [weak self] in
            await MainActor.run { self?.activeTurnID } ?? UUID()
        }
    )
    @ObservationIgnored var session: GopilotSessionContext?
    @ObservationIgnored var turnTask: Task<Void, Never>?
    @ObservationIgnored var pendingText = ""
    @ObservationIgnored var flushTask: Task<Void, Never>?
    @ObservationIgnored var currentAssistantID: UUID?
    @ObservationIgnored var currentTextID: UUID?
    @ObservationIgnored var thinkingItemIDs: Set<UUID> = []
    var narrationItemIDs: Set<UUID> = []
    var isCurrentTurnThinkingStep = false
    var turnChanges: [GopilotTurnChange] = []
    var activeTurnID: UUID?
    var lastAgentTurnID: UUID?
    @ObservationIgnored var turnIDByUserItemID: [UUID: UUID] = [:]
    @ObservationIgnored var currentUserItemID: UUID?
    @ObservationIgnored var currentTurnMode: GopilotMode = .ask
    @ObservationIgnored var autoApplyNotes: [UUID: String] = [:]
    @ObservationIgnored var store: WorkspaceStore?
    @ObservationIgnored var recorder: SessionRecorder?
    var conversationID: UUID?
    @ObservationIgnored var suppressAutoRestore = false
    @ObservationIgnored var saveFailureReported = false
    @ObservationIgnored var pendingTrustNotice = false
    @ObservationIgnored var pendingContextNotes: [String] = []
    @ObservationIgnored var indexCache = WorkspaceIndexCache()

    var providerSummary: String? { factory.providerSummary }

    var activeRoute: ModelRoute? {
        let settings = GopilotProviderSettings.shared
        let id: String
        if !selectedRouteID.isEmpty,
           (settings.routes.isEmpty || settings.routes.contains(where: { $0.id == selectedRouteID })) {
            id = selectedRouteID
        } else {
            id = settings.defaultRouteID
        }
        return settings.route(for: id)
    }

    func isThinkingLine(for itemID: UUID, text: String) -> Bool {
        guard isRunning else { return false }
        return thinkingItemIDs.contains(itemID)
    }

    func isStepNarration(_ itemID: UUID) -> Bool {
        narrationItemIDs.contains(itemID)
    }

    var activeRouteTier: RouteCapabilityTier {
        GopilotProviderSettings.shared.routeTier(for: activeRoute?.id)
    }

    func selectRoute(_ routeID: String) {
        selectedRouteID = routeID
        if let route = GopilotProviderSettings.shared.route(for: routeID) {
            if !route.reasoningMode.supportsEffort(selectedEffort) {
                selectedEffort = .default
            }
            if GopilotProviderSettings.shared.routeTier(for: routeID) == .verifiedChatOnly, mode == .agent {
                mode = .ask
            }
        }
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        selectedEffort = effort
        if effort != .default, let route = activeRoute, !route.reasoningMode.supportsEffort(effort) {
            GopilotProviderSettings.shared.updateRouteReasoning(
                id: route.id,
                mode: .openAIChatEffort(supported: [.low, .medium, .high])
            )
        }
    }

    func availability(workspacePath: String) -> Availability {
        if factory.providerSummary == nil { return .notConfigured }
        return workspacePath.isEmpty ? .noWorkspace : .ready
    }

    func canSend(workspacePath: String) -> Bool {
        availability(workspacePath: workspacePath) != .notConfigured
            && !isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTools: Bool { !(session?.toolNames.isEmpty ?? true) }

    @MainActor
    func workspaceChanged(to path: String) {
        guard path != workspacePath else { return }
        let task = turnTask
        let sessionToStop = session
        turnTask = nil
        session = nil
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
        currentAssistantID = nil
        currentTextID = nil
        thinkingItemIDs = []
        narrationItemIDs = []
        isCurrentTurnThinkingStep = false
        turnChanges = []
        activeTurnID = nil
        lastAgentTurnID = nil
        turnIDByUserItemID = [:]
        currentUserItemID = nil
        autoApplyNotes = [:]
        reviewing = nil
        reviewDiffs = []
        cardedProposals = []
        profilePaths = []
        interaction.cancelAll()
        isRunning = false
        items = []
        agentTodos = []
        proposalPaths = [:]
        includeProblemsInContext = false
        dismissedProblemsSuggestion = false
        citationSegments = [:]
        answerUsage = [:]
        answerSourcesUsed = [:]
        attachments = []
        turnProvenance = [:]
        priorTurns = []
        compactedSummary = nil
        lastPrompt = ""
        store = nil
        recorder = nil
        conversationID = nil
        memoryNotes = []
        memoryMessage = nil
        savedConversations = []
        viewingSaved = nil
        lastTrashed = nil
        saveFailureReported = false
        projectContextEnabled = true
        workspacePath = path
        let skipRestore = suppressAutoRestore
        suppressAutoRestore = false
        if selectedRouteID.isEmpty || (!GopilotProviderSettings.shared.routes.isEmpty && !GopilotProviderSettings.shared.routes.contains(where: { $0.id == selectedRouteID })) {
            selectedRouteID = GopilotProviderSettings.shared.defaultRouteID
        }
        syncPermissionModeWithSession()
        if !path.isEmpty {
            Task { @MainActor [weak self] in
                await self?.refreshMemory()
                if !skipRestore {
                    await self?.restoreLastConversationIfAvailable(for: path)
                }
            }
        }
        if !path.isEmpty, let uiState = ProcessInfo.processInfo.environment["GOPILOT_DEV_UI_STATE"] ?? ProcessInfo.processInfo.environment["GOPILOT_DEV_STATE"] {
            seedDebugUIState(uiState)
        }
        #if DEBUG
        if !path.isEmpty, let profile = ProcessInfo.processInfo.environment["GOPILOT_DEV_PROFILE"], FileManager.default.fileExists(atPath: profile) {
            workspaceState.importPprofFile(at: profile)
        }
        if !path.isEmpty, let fill = Int(ProcessInfo.processInfo.environment["GOPILOT_DEV_FILL"] ?? ""), fill > 0 {
            for index in 0..<fill {
                items.append(index % 2 == 0
                    ? .user(id: UUID(), text: "Question \(index) about the order flow and the inventory reservation", attachment: nil)
                    : .assistant(id: UUID(), text: "Answer \(index): the handler decodes the request, the service reserves stock and the repository inserts the order. See `service.go` for the check."))
            }
        }
        if !path.isEmpty { GopilotEvalHarness.shared.startIfRequested(state: self) }
        #endif
        if let sessionToStop {
            Task {
                await sessionToStop.runtime.stop()
                if let id = sessionToStop.workspaceID { await sessionToStop.evidence.expireAll(workspaceID: id) }
            }
        }
        task?.cancel()
    }

    @MainActor
    func newConversation() {
        let path = workspacePath
        Self.setSavedActiveConversationID(nil, for: path)
        suppressAutoRestore = true
        workspacePath = ""
        draft = ""
        workspaceChanged(to: path)
    }

    @MainActor
    func adopt(_ context: GopilotSessionContext) {
        session = context
        syncPermissionModeWithSession()
        if let note = context.patches?.loadJournalAndReportInterrupted() {
            items.append(.notice(id: UUID(), kind: .info, text: note, canRetry: false))
        }
    }

    func syncPermissionModeWithSession() {
        interaction.autoApprove = (mode == .agent && agentPermissionMode.autoApprovesWorkspaceRuns)
        interaction.gopilotEditedPaths = { [weak self] in
            self?.unsavedGopilotPaths() ?? []
        }
    }
}
