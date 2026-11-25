import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

extension GopilotState {
    static func savedActiveConversationID(for workspacePath: String) -> UUID? {
        guard !workspacePath.isEmpty,
              let map = UserDefaults.standard.dictionary(forKey: activeConversationMapKey) as? [String: String],
              let raw = map[workspacePath],
              !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func setSavedActiveConversationID(_ id: UUID?, for workspacePath: String) {
        guard !workspacePath.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: activeConversationMapKey) as? [String: String]) ?? [:]
        map[workspacePath] = id?.uuidString ?? ""
        UserDefaults.standard.set(map, forKey: activeConversationMapKey)
    }

    @MainActor
    func restoreLastConversationIfAvailable(for path: String) async {
        guard factory is GopilotLiveFactory else { return }
        guard workspacePath == path, items.isEmpty, viewingSaved == nil, !isRunning else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["GOPILOT_DEV_UI_STATE"] == nil,
              env["GOPILOT_DEV_STATE"] == nil,
              env["GOPILOT_DEV_FILL"] == nil else { return }
        await refreshHistory()
        guard workspacePath == path, items.isEmpty, viewingSaved == nil, !isRunning else { return }
        let targetID: UUID?
        if let savedID = Self.savedActiveConversationID(for: path),
           savedConversations.contains(where: { $0.id == savedID }) {
            targetID = savedID
        } else {
            targetID = savedConversations.first?.id
        }
        guard let targetID else { return }
        await openSaved(targetID)
        if viewingSaved != nil {
            await continueSaved(showStaleNotice: false)
        }
    }

    static func storeBaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "GoLens", isDirectory: true).appendingPathComponent("Gopilot", isDirectory: true)
    }

    @MainActor
    func openStore() -> WorkspaceStore? {
        if let store { return store }
        guard !workspacePath.isEmpty else { return nil }
        let id = GopilotLiveFactory.workspaceID(for: workspacePath)
        store = try? WorkspaceStore(baseURL: Self.storeBaseURL(), workspaceID: id)
        return store
    }

    @MainActor
    func prepareRecorder(title: String) async -> SessionRecorder? {
        if let recorder { return recorder }
        guard let store = openStore() else { return nil }
        do {
            if let existingID = conversationID {
                Self.setSavedActiveConversationID(existingID, for: workspacePath)
                let created = try await store.recorder(for: existingID)
                recorder = created
                return created
            }
            let modelName = activeRoute?.id ?? GopilotProviderSettings.shared.modelID
            let conversation = try await store.createConversation(providerID: "default", modelID: modelName, title: String(title.prefix(60)))
            conversationID = conversation.id
            Self.setSavedActiveConversationID(conversation.id, for: workspacePath)
            let created = try await store.recorder(for: conversation.id)
            recorder = created
            return created
        } catch {
            reportSaveFailure(error)
            return nil
        }
    }

    @MainActor
    func reportSaveFailure(_ error: Error) {
        guard !saveFailureReported else { return }
        saveFailureReported = true
        items.append(.notice(id: UUID(), kind: .warning, text: "This conversation could not be saved: \(error.localizedDescription) It still works, but it will not appear in History.", canRetry: false))
    }

    @MainActor
    func refreshNoteStaleness() async {
        guard let store = openStore() else { return }
        let workspace = workspaceState
        var hashes: [String: String] = [:]
        for note in await store.memory.notes() {
            for ref in note.sourceRefs where hashes[ref.path] == nil {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: workspacePath + "/" + ref.path)) {
                    hashes[ref.path] = GopilotStore.ContentHash.sha256Hex(data)
                }
            }
        }
        let facts = SnapshotFacts(branch: workspace.git.branchName, buildTarget: workspace.activeRunTarget.title, fileHashes: hashes)
        _ = try? await store.memory.markStale(against: facts)
    }

    @MainActor
    func refreshMemory() async {
        await refreshNoteStaleness()
        guard let store = openStore() else {
            memoryNotes = []
            return
        }
        memoryNotes = await store.memory.notes()
        recallEnabled = await store.memory.isRecallEnabled
    }

    @MainActor
    func pinNote(_ text: String, itemID: String) async {
        guard let store = openStore() else { return }
        let workspace = workspaceState
        var refs: [MemorySourceRef] = []
        var seen = Set<String>()
        for case .citation(let evidence) in citationSegments[itemID] ?? [] {
            for ref in evidence.sourceRefs where ref.dependencyRootID == nil && seen.insert(ref.path).inserted {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: workspacePath + "/" + ref.path)) {
                    refs.append(MemorySourceRef(path: ref.path, contentHash: GopilotStore.ContentHash.sha256Hex(data)))
                }
            }
        }
        let facts = MemoryContextFacts(branch: workspace.git.branchName, buildTarget: workspace.activeRunTarget.title)
        let provenance = MemoryProvenance(origin: "user-pinned", sourceConversationID: conversationID, pinnedContext: facts)
        do {
            _ = try await store.memory.pin(content: GopilotCitationNormalizer.normalize(text), provenance: provenance, sourceRefs: refs)
            memoryMessage = "Saved to notes for this project."
            await refreshMemory()
        } catch {
            memoryMessage = "The note could not be saved: \(error.localizedDescription)"
        }
    }

    @MainActor
    func deleteNote(_ id: UUID) async {
        guard let store = openStore() else { return }
        try? await store.memory.delete(id: id)
        await refreshMemory()
    }

    @MainActor
    func setRecall(_ enabled: Bool) async {
        guard let store = openStore() else { return }
        try? await store.memory.setRecallEnabled(enabled)
        await refreshMemory()
    }

    @MainActor
    func handleSlashMemoryCommand(_ text: String, clearDraft: Bool) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("/remember ") {
            let fact = String(text.dropFirst("/remember ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty else { return false }
            if clearDraft { draft = "" }
            items.append(.user(id: UUID(), text: text, attachment: nil))
            Task { @MainActor in
                guard let store = openStore() else {
                    items.append(.notice(id: UUID(), kind: .warning, text: "Open a project workspace first to save project memories.", canRetry: false))
                    return
                }
                let ws = self.workspaceState
                let provenance = MemoryProvenance(
                    origin: "user-command",
                    sourceConversationID: conversationID,
                    pinnedContext: MemoryContextFacts(branch: ws.git.branchName, buildTarget: ws.activeRunTarget.title)
                )
                do {
                    let result = try await store.memory.saveOrConsolidate(content: fact, category: nil, provenance: provenance, sourceRefs: [])
                    await refreshMemory()
                    let verb = result.consolidated ? "Updated existing project memory" : "Saved to project memory"
                    items.append(.assistant(id: UUID(), text: "**\(verb):** \(result.note.content)"))
                } catch {
                    items.append(.notice(id: UUID(), kind: .warning, text: "Could not save memory: \(error.localizedDescription)", canRetry: false))
                }
            }
            return true
        }
        if lower.hasPrefix("/forget ") {
            let query = String(text.dropFirst("/forget ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return false }
            if clearDraft { draft = "" }
            items.append(.user(id: UUID(), text: text, attachment: nil))
            Task { @MainActor in
                guard let store = openStore() else { return }
                let matches = await store.memory.recall(query: query, limit: 1)
                if let first = matches.first {
                    try? await store.memory.delete(id: first.note.id)
                    await refreshMemory()
                    items.append(.assistant(id: UUID(), text: "**Removed project memory:** \(first.note.content)"))
                } else {
                    items.append(.assistant(id: UUID(), text: "No saved project memory matched `\(query)`."))
                }
            }
            return true
        }
        return false
    }

    @MainActor
    func persistEvidence() {
        guard let session, let workspaceID = session.workspaceID, let store, let conversationID else { return }
        Task { @MainActor in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for evidence in await session.evidence.all(workspaceID: workspaceID) {
                let key = "\(conversationID.uuidString)-\(evidence.id)"
                guard !persistedEvidence.contains(key), let data = try? encoder.encode(evidence) else { continue }
                if (try? await store.artifacts.put(id: "ev-" + key, bytes: data, contentHash: GopilotStore.ContentHash.sha256Hex(data))) != nil {
                    persistedEvidence.insert(key)
                }
            }
        }
    }

    @MainActor
    func loadEvidence(for conversation: Conversation) async -> [Evidence] {
        guard let store = openStore() else { return [] }
        let expression = try! NSRegularExpression(pattern: #"\bE[0-9]{1,6}\b"#)
        var ids = Set<String>()
        for message in conversation.turns.flatMap(\.messages) {
            let text = message.content as NSString
            for match in expression.matches(in: message.content, range: NSRange(location: 0, length: text.length)) {
                ids.insert(text.substring(with: match.range))
            }
        }
        var loaded: [Evidence] = []
        for id in ids.sorted() {
            if case .found(let data, _) = await store.artifacts.get(id: "ev-\(conversation.id.uuidString)-\(id)"),
               let evidence = try? JSONDecoder().decode(Evidence.self, from: data) {
                loaded.append(evidence)
            }
        }
        return loaded
    }

    @MainActor
    func refreshHistory() async {
        guard let store = openStore() else {
            savedConversations = []
            return
        }
        savedConversations = await store.listConversations().sorted { $0.updatedAt > $1.updatedAt }
    }

    @MainActor
    func openSaved(_ id: UUID) async {
        guard let store = openStore(), !isRunning else { return }
        do {
            let opened = try await store.openConversation(id: id)
            let built = Self.itemsAndUsage(from: opened.conversation)
            let restored = EvidenceStore()
            let workspaceID = GopilotLiveFactory.workspaceID(for: workspacePath)
            for evidence in await loadEvidence(for: opened.conversation) { await restored.restore(evidence) }
            var resolvedSegments: [String: [CitationSegment]] = [:]
            var updatedSources = built.sources
            for case .assistant(let id, let text) in built.items {
                let segments = await CitationResolver().resolve(text, workspaceID: workspaceID, store: restored)
                resolvedSegments[id.uuidString] = segments
                var cited: [SourceUsageItem] = []
                var seen = Set<String>()
                for case .citation(let evidence) in segments {
                    for ref in evidence.sourceRefs {
                        let s = ref.range.map { $0.startLine + 1 }
                        let e = ref.range.map { $0.endLine + 1 }
                        let rangeKey = "\(ref.path)|\(s ?? 0):\(e ?? 0)"
                        guard seen.insert(rangeKey).inserted else { continue }
                        cited.append(
                            SourceUsageItem(
                                category: .cited,
                                path: ref.path,
                                startLine: s,
                                endLine: e,
                                evidenceID: evidence.id
                            )
                        )
                    }
                }
                var current = updatedSources[id.uuidString] ?? SourcesUsedSummary(attached: [], lookedUp: [], cited: [])
                current.cited = cited
                if !current.isEmpty {
                    updatedSources[id.uuidString] = current
                }
            }
            viewingSaved = opened.conversation
            citationSegments = resolvedSegments
            answerUsage = built.usage
            answerSourcesUsed = updatedSources
            items = built.items
            attachments = []
        } catch {
            items = [.notice(id: UUID(), kind: .error, text: "This conversation could not be opened: \(error.localizedDescription)", canRetry: false)]
        }
    }

    @MainActor
    func closeSaved() {
        viewingSaved = nil
        items = []
        agentTodos = []
        proposalPaths = [:]
        includeProblemsInContext = false
        dismissedProblemsSuggestion = false
        citationSegments = [:]
        answerUsage = [:]
        answerSourcesUsed = [:]
    }

    @MainActor
    func continueSaved(showStaleNotice: Bool = true) async {
        guard let store = openStore(), let saved = viewingSaved, !isRunning else { return }
        do {
            let result = try await store.resume(id: saved.id, revalidate: { _ in .needsRefresh })
            let completedTurns = saved.turns.filter { $0.terminal == .completed || $0.terminal == .budgetExceeded }
            let prior = completedTurns.flatMap(\.messages)
            priorTurns = completedTurns.map { turn in
                ConversationTurn(id: turn.id, messages: turn.messages)
            }
            for turn in completedTurns {
                var paths = Set(turn.attachedPaths ?? [])
                paths.formUnion(turn.accessedPaths ?? [])
                if !paths.isEmpty {
                    turnProvenance[turn.id] = paths
                }
            }
            conversationID = saved.id
            Self.setSavedActiveConversationID(saved.id, for: workspacePath)
            recorder = try await store.recorder(for: saved.id)
            viewingSaved = nil
            if let resumed = factory.makeSession(workspacePath: workspacePath, history: prior, memory: store.memory) {
                adopt(resumed)
                for evidence in await loadEvidence(for: saved) {
                    await resumed.evidence.restore(evidence)
                    persistedEvidence.insert("\(saved.id.uuidString)-\(evidence.id)")
                }
            }
            if showStaleNotice, (!result.evidenceIDsNeedingRefresh.isEmpty || !result.unknownToolCallIDs.isEmpty) {
                items.append(.notice(id: UUID(), kind: .info, text: "Sources from this saved conversation are not linked anymore. Ask again and Gopilot will read them fresh.", canRetry: false))
            }
        } catch {
            items.append(.notice(id: UUID(), kind: .error, text: "This conversation could not be continued: \(error.localizedDescription)", canRetry: false))
        }
    }

    @MainActor
    func trashSaved(_ id: UUID) async {
        guard let store = openStore() else { return }
        if (try? await store.trash(id: id)) != nil {
            lastTrashed = savedConversations.first { $0.id == id }
            if viewingSaved?.id == id || conversationID == id {
                closeSaved()
                conversationID = nil
                recorder = nil
                priorTurns = []
                Self.setSavedActiveConversationID(nil, for: workspacePath)
            }
            await refreshHistory()
        }
    }

    @MainActor
    func undoTrash() async {
        guard let store = openStore(), let trashed = lastTrashed else { return }
        try? await store.undoTrash(id: trashed.id)
        lastTrashed = nil
        await refreshHistory()
    }

    static func items(from conversation: Conversation) -> [GopilotTranscriptItem] {
        itemsAndUsage(from: conversation).items
    }

    static func itemsAndUsage(from conversation: Conversation) -> (items: [GopilotTranscriptItem], usage: [String: String], sources: [String: SourcesUsedSummary]) {
        var result: [GopilotTranscriptItem] = []
        var usageMap: [String: String] = [:]
        var sourcesMap: [String: SourcesUsedSummary] = [:]
        let turns = conversation.turns
        for (turnIndex, turn) in turns.enumerated() {
            let hasAssistantAnswer = turn.messages.contains {
                $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !hasAssistantAnswer,
               turn.terminal == .failed,
               turnIndex + 1 < turns.count,
               turns[turnIndex + 1].userPrompt == turn.userPrompt {
                continue
            }
            let visible = turn.displayLabel ?? (turn.userPrompt.components(separatedBy: "\n\nAttached selection from").first ?? turn.userPrompt)
            let attachedBadge = turn.attachedPaths?.first.map { rawPath -> String in
                if rawPath.hasSuffix("/") {
                    return rawPath
                }
                let base = (rawPath as NSString).lastPathComponent
                let ext = (base as NSString).pathExtension
                let knownExtensionless: Set<String> = [
                    "makefile", "dockerfile", "gnumakefile", "procfile",
                    "jenkinsfile", "license", "caddyfile", "vagrantfile"
                ]
                if ext.isEmpty && !knownExtensionless.contains(base.lowercased()) {
                    return "\(rawPath)/"
                }
                return base
            }
            result.append(.user(id: UUID(), text: visible, attachment: attachedBadge))
            var lastAssistantID: UUID?
            for message in turn.messages where message.role == .assistant {
                for call in message.toolCalls {
                    let lifecycle = turn.toolLifecycles.first { $0.callID == call.id }
                    let status: GopilotTranscriptItem.ActivityStatus = lifecycle?.state == .completed && lifecycle?.status != "error" ? .finished : .failed
                    result.append(.activity(id: "act-\(call.id)-\(turn.id.uuidString)", label: activityLabel(for: call.name, argumentsJSON: call.argumentsJSON), status: status))
                }
            }
            if let finalAssistantMessage = turn.messages.last(where: { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let assistantID = UUID()
                lastAssistantID = assistantID
                result.append(.assistant(id: assistantID, text: GopilotCitationNormalizer.normalize(finalAssistantMessage.content)))
            }
            if let lastAssistantID {
                if turn.usage.modelRequests > 0 {
                    usageMap[lastAssistantID.uuidString] = formatUsage(
                        requests: turn.usage.modelRequests,
                        inputTokens: turn.usage.inputTokens ?? 0,
                        outputTokens: turn.usage.outputTokens ?? 0,
                        reasoningTokens: turn.usage.reasoningTokens ?? 0,
                        routeID: turn.routeSelection?.routeID
                    )
                }
                let attachedItems = (turn.attachedPaths ?? []).map {
                    SourceUsageItem(category: .attached, path: $0)
                }
                let lookedUpItems = (turn.accessedPaths ?? []).filter { !(turn.attachedPaths ?? []).contains($0) }.map {
                    SourceUsageItem(category: .lookedUp, path: $0)
                }
                let summary = SourcesUsedSummary(attached: attachedItems, lookedUp: lookedUpItems, cited: [])
                if !summary.isEmpty {
                    sourcesMap[lastAssistantID.uuidString] = summary
                }
            }
            switch turn.terminal {
            case .cancelled:
                result.append(.notice(id: UUID(), kind: .info, text: "This request was stopped.", canRetry: false))
            case .failed:
                result.append(.notice(id: UUID(), kind: .error, text: "This request did not finish.", canRetry: false))
            case .interrupted, nil:
                result.append(.notice(id: UUID(), kind: .warning, text: "This request was interrupted when the app closed. Tool results from it are unknown and were not run again.", canRetry: false))
            case .budgetExceeded:
                let hasFindings = lastAssistantID != nil || !turn.toolLifecycles.isEmpty
                let message = hasFindings
                    ? "Gopilot paused after reaching the step limit for one turn. Continue from the findings above or ask a narrower question."
                    : "Gopilot reached the step limit for one turn before finishing. Try asking a narrower question about one package or file."
                result.append(.notice(id: UUID(), kind: .budgetExceeded(hasFindings: hasFindings), text: message, canRetry: false))
            case .completed:
                break
            }
        }
        return (result, usageMap, sourcesMap)
    }

    static func formatUsage(
        requests: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        routeID: String? = nil
    ) -> String {
        var parts: [String] = []
        if let routeID, !routeID.isEmpty {
            parts.append(routeID)
        }
        parts.append("\(requests) request\(requests == 1 ? "" : "s")")
        let tokens = inputTokens + outputTokens
        if tokens > 0 {
            parts.append("\(inputTokens.formatted()) in")
            parts.append("\(outputTokens.formatted()) out")
            if reasoningTokens > 0 {
                parts.append("\(reasoningTokens.formatted()) reasoning")
            }
        } else {
            parts.append("token usage not reported")
        }
        return parts.joined(separator: " · ")
    }
}
