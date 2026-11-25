import AppKit
import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

extension GopilotState {
    @MainActor
    func send(_ prompt: String? = nil) {
        let text = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if handleSlashMemoryCommand(text, clearDraft: prompt == nil) {
            return
        }
        if let host = GopilotProviderSettings.shared.gateway.flatMap({ AIProviderConsent.host(forBaseURL: $0.baseURL) }),
           !AIProviderConsent.shared.isAllowed(host) {
            requestProviderConsent(forHost: host) { [weak self] in
                self?.send(prompt)
            }
            return
        }
        guard viewingSaved == nil, let active = session ?? factory.makeSession(workspacePath: workspacePath, history: priorTurns.flatMap(\.messages), memory: openStore()?.memory) else { return }
        if session == nil { adopt(active) }

        let settings = GopilotProviderSettings.shared
        let chosenRoute = activeRoute
        let chosenTier = activeRouteTier
        if mode == .agent {
            if !projectContextEnabled {
                projectContextEnabled = true
            }
            if chosenTier == .verifiedChatOnly {
                mode = .ask
                items.append(
                    .notice(
                        id: UUID(),
                        kind: .info,
                        text: "Switched to Ask mode because \(chosenRoute?.displayName ?? "this model") is chat-only and does not support project tools.",
                        canRetry: false
                    )
                )
            }
        }
        syncPermissionModeWithSession()

        if prompt == nil { draft = "" }
        lastPrompt = text
        resolveInlineMentions(in: text, workspace: workspaceState)
        let turnAttachments = attachments
        attachments = []
        items = items.compactMap { item in
            guard case .notice(let id, let kind, let text, _) = item else { return item }
            switch kind {
            case .error, .authentication, .requestRejected:
                return .notice(id: id, kind: .error, text: text, canRetry: false)
            default:
                return nil
            }
        }
        let userBadge = turnAttachments.isEmpty
            ? (projectContextEnabled ? nil : "Project Context Off")
            : turnAttachments.map(\.label).joined(separator: ", ")
        let userItemID = UUID()
        items.append(.user(id: userItemID, text: text, attachment: userBadge))
        currentUserItemID = userItemID
        isRunning = true
        turnAccounting = TurnAccounting()
        turnAccounting.accessedPaths = Set(turnAttachments.map(\.relativePath))
        usageSummary = nil
        let assistantID = UUID()
        currentAssistantID = assistantID
        currentTextID = assistantID
        thinkingItemIDs = []
        isCurrentTurnThinkingStep = true
        let currentMode = mode
        currentTurnMode = mode
        let currentPermissionMode = agentPermissionMode
        let currentProjectContext = projectContextEnabled
        let routeID = chosenRoute?.id
        let effort = selectedEffort
        let routeSelection = routeID.map {
            TurnRouteSelection(routeID: $0, displayName: chosenRoute?.displayName, effort: effort)
        }

        turnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let workspaceID = active.workspaceID ?? UUID()
            let currentSnapshot = await active.snapshot?()
            var attachedRefs: [AttachedSourceRef] = []
            var attachedSnapshots: [AttachedSourceSnapshot] = []
            var attachedUsage: [SourceUsageItem] = []

            for att in turnAttachments {
                let ref = att.toAttachedSourceRef(workspaceID: workspaceID)
                attachedRefs.append(ref)
                var evidenceID: String?
                if let currentSnapshot {
                    let sourceRef = SourceRef(
                        workspaceID: workspaceID,
                        path: att.relativePath,
                        range: ref.range,
                        contentHash: ref.contentHash,
                        documentVersion: att.documentVersion
                    )
                    let ev = await active.evidence.add(
                        EvidenceDraft(
                            workspaceID: workspaceID,
                            producerID: "attachment:\(att.origin.rawValue)",
                            kind: .source,
                            sourceRefs: [sourceRef],
                            snapshotID: currentSnapshot.id,
                            content: att.text
                        )
                    )
                    evidenceID = ev.id
                }
                attachedSnapshots.append(
                    AttachedSourceSnapshot(
                        ref: ref,
                        text: att.text,
                        evidenceID: evidenceID,
                        wasTruncated: att.text.utf8.count >= ContextBuilder.maxAttachedSourceBytes
                    )
                )
                attachedUsage.append(
                    SourceUsageItem(
                        category: .attached,
                        path: att.isFolder ? "\(att.relativePath)/" : att.relativePath,
                        startLine: att.isWholeFile ? nil : att.startLine,
                        endLine: att.isWholeFile ? nil : att.endLine,
                        symbolName: att.symbolName,
                        evidenceID: evidenceID,
                        isUnsaved: att.isUnsaved
                    )
                )
            }
            self.turnAccounting.attachedItems = attachedUsage

            let readScope = TurnReadScope(projectContextEnabled: currentProjectContext, allowedSources: attachedRefs)
            await active.applyConfiguration(
                mode: currentMode,
                permissionMode: currentPermissionMode,
                readScope: readScope,
                routeID: routeID,
                settings: self.factory is GopilotLiveFactory ? .shared : nil
            )
            await self.refreshMemory()
            let notes = self.takeContextNotes()
            let requestWithNotes = notes.isEmpty ? text : "[Context from the IDE: " + notes.joined(separator: " ") + "]\n\n" + text

            let activeRegistry = currentMode == .agent
                ? (currentProjectContext ? active.agentRegistry : active.agentScopedRegistry)
                : (currentProjectContext ? active.askRegistry : active.askScopedRegistry)
            let hasTools = !activeRegistry.schemas.isEmpty && chosenTier != .verifiedChatOnly
            let systemPrompt = GopilotSystemPrompt.text(
                hasWorkspace: active.workspaceID != nil,
                hasTools: hasTools,
                mode: currentMode,
                permissionMode: currentPermissionMode,
                projectContextEnabled: currentProjectContext
            )

            var workspaceFacts: [String] = []
            if currentProjectContext, !self.workspacePath.isEmpty {
                let ws = self.workspaceState
                if !ws.git.branchName.isEmpty { workspaceFacts.append("Git branch: \(ws.git.branchName)") }
                if !ws.activeRunTarget.title.isEmpty { workspaceFacts.append("Active build target: \(ws.activeRunTarget.title)") }
                workspaceFacts.append(contentsOf: self.loadProjectBriefingFacts(secretFilter: active.secretFilter))
            }
            if self.includeProblemsInContext, let problems = self.activeProblemsSummary(in: self.workspaceState) {
                let redactedDetails = active.secretFilter.redact(problems.details).text
                workspaceFacts.append("Attached IDE Diagnostics (\(problems.label)):\n\(redactedDetails)")
            }

            let approvedNotes: [ApprovedNote]
            if currentProjectContext && self.recallEnabled {
                approvedNotes = self.memoryNotes.map {
                    ApprovedNote(id: $0.id.uuidString, text: $0.content, isStale: $0.isStale)
                }
            } else {
                approvedNotes = []
            }

            var knownEvidence: [String: Evidence] = [:]
            var priorSessionEvidence: [Evidence] = []
            let attachedEvidenceIDs = Set(attachedSnapshots.compactMap(\.evidenceID))
            if let wsID = active.workspaceID {
                let allEvidence = await active.evidence.all(workspaceID: wsID)
                for ev in allEvidence {
                    knownEvidence[ev.id] = ev
                }
                priorSessionEvidence = Array(
                    allEvidence
                        .filter { !attachedEvidenceIDs.contains($0.id) }
                        .suffix(16)
                )
            }
            let compacted = Compactor().compact(
                turns: self.priorTurns,
                keepRecent: 4,
                existing: self.compactedSummary,
                evidence: knownEvidence
            )
            self.compactedSummary = compacted.summary

            let contextInput = ContextInput(
                systemPrompt: systemPrompt,
                userRequest: requestWithNotes,
                attachedSelection: nil,
                attachedSources: attachedSnapshots,
                readScope: readScope,
                turnProvenance: self.turnProvenance,
                snapshotFacts: workspaceFacts,
                freshEvidence: priorSessionEvidence,
                approvedNotes: approvedNotes,
                recentTurns: compacted.keptTurns,
                summary: compacted.summary,
                currentSnapshot: currentSnapshot
            )
            let contextBudget = ContextBudget(
                contextWindow: chosenRoute?.contextWindowTokens ?? 64_000,
                declaredOutputLimit: chosenRoute?.outputTokenLimit
            )
            let builtContext = ContextBuilder(budget: contextBudget, filter: active.secretFilter, sessionSalt: active.sessionSalt).build(contextInput)
            let modelPrompt = builtContext.messages.last?.content ?? requestWithNotes
            let turnBudget = GopilotTurnBudget.forMode(currentMode)
            let executionOptions = TurnExecutionOptions(
                preparedMessages: builtContext.messages,
                routeSelection: routeSelection,
                providerOverride: (self.factory is GopilotLiveFactory) ? settings.makeProvider(for: routeID) : nil,
                limits: turnBudget.limits,
                inputTokenBudget: contextBudget.inputTokens,
                budgetNote: turnBudget.finalNote
            )

            let activeRecorder = await self.prepareRecorder(title: GopilotPresetPrompt.shortTitle(for: text) ?? text)
            let displayLabel = GopilotPresetPrompt.shortTitle(for: text)
            let attachedPaths = turnAttachments.map { $0.isFolder ? "\($0.relativePath)/" : $0.relativePath }

            do {
                let stream = try await active.runtime.startTurn(prompt: modelPrompt, options: executionOptions)
                var recordingStream: AsyncStream<AgentEvent>?
                var recordingContinuation: AsyncStream<AgentEvent>.Continuation?
                if activeRecorder != nil {
                    let pair = AsyncStream.makeStream(of: AgentEvent.self)
                    recordingStream = pair.stream
                    recordingContinuation = pair.continuation
                }
                if let activeRecorder, let recordingStream {
                    Task { @MainActor [weak self] in
                        do {
                            var terminalEvent: AgentEvent?
                            var recordedTurnID: UUID?
                            for await ev in recordingStream {
                                recordedTurnID = recordedTurnID ?? ev.turnID
                                if ev.kind.isTerminal {
                                    terminalEvent = ev
                                    continue
                                }
                                try await activeRecorder.ingest(
                                    ev,
                                    prompt: text,
                                    displayLabel: displayLabel,
                                    routeSelection: routeSelection,
                                    projectContextEnabled: currentProjectContext,
                                    attachedPaths: attachedPaths
                                )
                            }
                            if let terminalEvent, let recordedTurnID {
                                let turnMsgs: [ModelMessage]
                                if var slice = await active.runtime.turnMessages(recordedTurnID), !slice.isEmpty, slice[0].role == .user {
                                    slice[0] = ModelMessage(role: .user, content: text)
                                    turnMsgs = slice
                                } else {
                                    turnMsgs = [ModelMessage(role: .user, content: text)]
                                }
                                let accessed = Array(self?.turnAccounting.accessedPaths ?? []).sorted()
                                try await activeRecorder.recordMessages(turnID: recordedTurnID, messages: turnMsgs, accessedPaths: accessed)
                                try await activeRecorder.ingest(terminalEvent, prompt: text)
                                try await activeRecorder.flush()
                            }
                        } catch {
                            self?.reportSaveFailure(error)
                        }
                    }
                }
                for await event in stream {
                    recordingContinuation?.yield(event)
                    self.apply(event, assistantID: assistantID)
                }
                recordingContinuation?.finish()
            } catch {
                self.finishTurn(notice: .notice(id: UUID(), kind: .warning, text: "Gopilot is still working on the previous request.", canRetry: false))
            }
        }
    }

    @MainActor
    private func popTrailingFailedTurnForRetry() {
        while let last = items.last {
            switch last {
            case .notice, .activity:
                items.removeLast()
            case .user(_, let text, _) where text == lastPrompt:
                items.removeLast()
                return
            default:
                return
            }
        }
    }

    @MainActor
    func retry() {
        guard !lastPrompt.isEmpty else { return }
        popTrailingFailedTurnForRetry()
        send(lastPrompt)
    }

    @MainActor
    func retryWithDefaultEffort() {
        selectedEffort = .default
        guard !lastPrompt.isEmpty else { return }
        popTrailingFailedTurnForRetry()
        send(lastPrompt)
    }

    @MainActor
    private func requestProviderConsent(forHost host: String, then action: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Send Code to \(host)?"
        alert.informativeText = AIProviderConsent.disclosure(host: host)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        workspaceState.present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            AIProviderConsent.shared.allow(host)
            action()
        }
    }

    @MainActor
    func verifyAndRetryAgentRoute(_ routeID: String) {
        if let host = GopilotProviderSettings.shared.gateway.flatMap({ AIProviderConsent.host(forBaseURL: $0.baseURL) }),
           !AIProviderConsent.shared.isAllowed(host) {
            requestProviderConsent(forHost: host) { [weak self] in
                self?.verifyAndRetryAgentRoute(routeID)
            }
            return
        }
        Task { @MainActor in
            await GopilotProviderSettings.shared.testConnection(routeID: routeID)
            let tier = GopilotProviderSettings.shared.routeTier(for: routeID)
            if tier == .verifiedAgent {
                retry()
            } else if tier == .verifiedChatOnly {
                mode = .ask
                items.removeAll { if case .notice = $0 { true } else { false } }
                items.append(
                    .notice(
                        id: UUID(),
                        kind: .warning,
                        text: "\(routeID) only supports chat and cannot call project tools. Switched to Ask mode.",
                        canRetry: true
                    )
                )
            }
        }
    }

    @MainActor
    func continueFromFindings() {
        guard !isRunning else { return }
        let prompt = mode == .agent ? GopilotPresetPrompt.continueAgentTask : GopilotPresetPrompt.continueFromFindings
        if viewingSaved != nil {
            Task { @MainActor in
                await continueSaved()
                send(prompt)
            }
            return
        }
        send(prompt)
    }

    @MainActor
    func prepareNarrowerQuestion(workspace: WorkspaceState) {
        items.removeAll {
            if case .notice(_, .budgetExceeded, _, _) = $0 { return true }
            return false
        }
        if !workspace.activeFilePath.isEmpty {
            let fileName = (workspace.activeFilePath as NSString).lastPathComponent
            draft = "Explain \(fileName) and how it connects to the main flow."
        } else {
            draft = "What is the main entry point of this project and what does it call first?"
        }
    }

    @MainActor
    func stop() {
        interaction.cancelAll()
        guard let runtime = session?.runtime else { return }
        Task { await runtime.stop() }
    }

    @MainActor
    func apply(_ event: AgentEvent, assistantID: UUID) {
        #if DEBUG
        evalObserver?(event)
        #endif
        guard currentAssistantID == assistantID else { return }
        switch event.kind {
        case .turnStarted:
            activeTurnID = event.turnID
            if currentTurnMode == .agent { lastAgentTurnID = event.turnID }
            if let userItemID = currentUserItemID { turnIDByUserItemID[userItemID] = event.turnID }
        case .activity:
            if event.payload["label"] == "Requesting model" || event.payload["label"] == "Summarizing findings" {
                turnAccounting.requests += 1
                if turnAccounting.requests > 1 { beginNewStep() }
            } else if let reasoningPreview = event.payload["reasoningPreview"],
                      !reasoningPreview.isEmpty,
                      pendingText.isEmpty {
                let textID = currentTextID ?? assistantID
                if let index = items.firstIndex(where: { $0.id == textID.uuidString }) {
                    if thinkingItemIDs.contains(textID) {
                        items[index] = .assistant(id: textID, text: reasoningPreview)
                    }
                } else {
                    items.append(.assistant(id: textID, text: reasoningPreview))
                    thinkingItemIDs.insert(textID)
                }
                isCurrentTurnThinkingStep = thinkingItemIDs.contains(textID)
            } else if event.payload["warning"] == "outputTruncated" {
                flushNow(assistantID: assistantID)
                items.append(.activity(id: "warn-\(event.sequence)-\(event.turnID.uuidString)", label: "The response was cut off by the model's output limit. Continuing.", status: .failed))
            } else if event.payload["compactedToolResults"] != nil {
                flushNow(assistantID: assistantID)
                items.append(.activity(id: "compact-\(event.sequence)-\(event.turnID.uuidString)", label: "Shortened earlier steps to fit the model's context window", status: .finished))
            }
        case .usageUpdated:
            turnAccounting.inputTokens += Int(event.payload["inputTokens"] ?? "") ?? 0
            turnAccounting.outputTokens += Int(event.payload["outputTokens"] ?? "") ?? 0
            turnAccounting.reasoningTokens += Int(event.payload["reasoningTokens"] ?? "") ?? 0
        case .textDelta:
            pendingText += event.payload["text"] ?? ""
            scheduleFlush(assistantID: assistantID)
        case .toolStarted:
            flushNow(assistantID: assistantID)
            dropThinkingPlaceholder()
            let callID = event.payload["callID"] ?? UUID().uuidString
            let toolName = event.payload["name"] ?? ""
            let argsJSON = event.payload["arguments"] ?? ""
            recordToolAccess(toolName: toolName, argumentsJSON: argsJSON)
            items.append(.activity(
                id: "act-\(callID)",
                label: Self.activityLabel(for: toolName, argumentsJSON: argsJSON),
                status: .running
            ))
        case .toolFinished:
            let finishedTool = event.payload["name"] ?? ""
            let ok = event.payload["status"] == "ok"
            if finishedTool == "propose_patch" || finishedTool == "write_file" || finishedTool == "edit_file" {
                refreshProposalCards()
            }
            if finishedTool == "todo_write", ok {
                updateTodos(fromJSON: event.payload["summary"] ?? event.payload["result"] ?? "")
            }
            if finishedTool == "save_memory", ok {
                Task { @MainActor [weak self] in
                    await self?.refreshMemory()
                }
            }
            let callID = event.payload["callID"] ?? ""
            let failed = event.payload["status"] == "error"
            if failed, (event.payload["detail"] ?? "").contains("marked as trusted"), !items.contains(where: { if case .notice(_, .trust, _, _) = $0 { true } else { false } }) {
                pendingTrustNotice = true
            }
            if let index = items.firstIndex(where: { $0.id == "act-\(callID)" }), case .activity(let id, let label, _) = items[index] {
                items[index] = .activity(id: id, label: Self.finishedActivityLabel(label, payload: event.payload), status: failed ? .failed : .finished)
            }
        case .turnCompleted:
            var notice: GopilotTranscriptItem?
            if (event.payload["warnings"] ?? "").contains("outputTruncated") {
                notice = .notice(id: UUID(), kind: .warning, text: "The answer was cut off by the model's output limit, so it may be incomplete.", canRetry: false)
            }
            finishTurn(notice: notice, turnID: event.turnID)
        case .turnCancelled:
            finishTurn(notice: .notice(id: UUID(), kind: .info, text: Self.cancelledText(event.payload, changes: turnChangeSummary()), canRetry: false), turnID: event.turnID, interrupted: true)
        case .turnFailed:
            let code = event.payload["code"] ?? ""
            if code == "unsupportedParameter" {
                let routeID = activeRoute?.id ?? GopilotProviderSettings.shared.modelID
                finishTurn(
                    notice: .notice(
                        id: UUID(),
                        kind: .unsupportedEffort(routeID: routeID),
                        text: event.payload["message"] ?? "This model route rejected the selected reasoning effort. Retry with Default.",
                        canRetry: false
                    ),
                    turnID: event.turnID,
                    interrupted: true
                )
            } else {
                let kind: GopilotTranscriptItem.NoticeKind = switch code {
                case "unauthorized": .authentication
                case "requestRejected": .requestRejected
                default: .error
                }
                let text = Self.failureText(event.payload) + Self.changedFilesSentence(turnChangeSummary())
                finishTurn(notice: .notice(id: UUID(), kind: kind, text: text, canRetry: true), turnID: event.turnID, interrupted: true)
            }
        case .turnBudgetExceeded:
            handleBudgetExceeded(event: event, assistantID: assistantID)
        default:
            break
        }
    }

    @MainActor
    func beginNewStep() {
        guard let textID = currentTextID else { return }
        flushNow(assistantID: currentAssistantID ?? textID)
        if thinkingItemIDs.contains(textID) {
            return
        }
        if let index = items.firstIndex(where: { $0.id == textID.uuidString }), case .assistant(_, let text) = items[index], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            narrationItemIDs.insert(textID)
            currentTextID = UUID()
        }
        isCurrentTurnThinkingStep = true
    }

    @MainActor
    func dropThinkingPlaceholder() {
        guard let textID = currentTextID, thinkingItemIDs.contains(textID) else { return }
        thinkingItemIDs.remove(textID)
        items.removeAll { $0.id == textID.uuidString }
    }

    @MainActor
    private func handleBudgetExceeded(event: AgentEvent, assistantID: UUID) {
        flushNow(assistantID: assistantID)
        dropThinkingPlaceholder()
        let toolCallsUsed = Int(event.payload["toolCallsCompleted"] ?? event.payload["toolCallsUsed"] ?? "0") ?? 0
        let hasTrailingAssistant: Bool = {
            for item in items.reversed() {
                switch item {
                case .assistant(_, let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    return true
                case .activity, .user:
                    return false
                default:
                    continue
                }
            }
            return false
        }()
        let isAgent = currentTurnMode == .agent
        let changeSentence = Self.changedFilesSentence(turnChangeSummary())
        func noticeText(hasFindings: Bool) -> String {
            if isAgent {
                return "Gopilot stopped after reaching the step limit for one Agent turn." + changeSentence + " Continue to let it finish the remaining steps."
            }
            return hasFindings
                ? "Gopilot paused after reaching the step limit for one turn. Continue from the findings above or ask a narrower question."
                : "Gopilot reached the step limit for one turn before finishing. Try asking a narrower question about one package or file."
        }
        if !hasTrailingAssistant, !isAgent, let session, let workspaceID = session.workspaceID {
            Task { @MainActor in
                let gathered = await session.evidence.all(workspaceID: workspaceID)
                if !gathered.isEmpty {
                    let summary = Self.partialFindingsMarkdown(from: gathered)
                    let textID = UUID()
                    self.items.append(.assistant(id: textID, text: summary))
                    self.isCurrentTurnThinkingStep = false
                    self.resolveCitations(itemID: textID.uuidString, text: summary)
                }
                let hasFindings = toolCallsUsed > 0 || !gathered.isEmpty || hasTrailingAssistant
                self.finishTurn(notice: .notice(id: UUID(), kind: .budgetExceeded(hasFindings: hasFindings), text: noticeText(hasFindings: hasFindings), canRetry: false), turnID: event.turnID)
            }
            return
        }
        let hasFindings = toolCallsUsed > 0 || hasTrailingAssistant
        finishTurn(notice: .notice(id: UUID(), kind: .budgetExceeded(hasFindings: hasFindings || isAgent), text: noticeText(hasFindings: hasFindings), canRetry: false), turnID: event.turnID)
    }

    private static func partialFindingsMarkdown(from evidence: [Evidence]) -> String {
        var lines: [String] = ["**Findings gathered so far:**"]
        var seenPaths = Set<String>()
        for item in evidence.suffix(12) {
            if let ref = item.sourceRefs.first, !ref.path.isEmpty {
                let key = "\(ref.path):\(ref.range?.startLine ?? -1)"
                guard seenPaths.insert(key).inserted else { continue }
                lines.append("- Inspected `\(ref.path)` [\(item.id)]")
            } else if item.producerID == "project_summary" {
                let preview = item.content
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("}") }
                if let preview {
                    lines.append("- Project overview: \(preview.prefix(120)) [\(item.id)]")
                } else {
                    lines.append("- Inspected project overview [\(item.id)]")
                }
            }
        }
        if lines.count == 1 {
            for item in evidence.prefix(6) {
                lines.append("- Collected evidence [\(item.id)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    func scheduleFlush(assistantID: UUID) {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.flushNow(assistantID: assistantID)
        }
    }

    @MainActor
    func flushNow(assistantID: UUID) {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }
        let chunk = pendingText
        pendingText = ""
        let textID = currentTextID ?? assistantID
        var combined = chunk
        if let index = items.firstIndex(where: { $0.id == textID.uuidString }), case .assistant(let id, let text) = items[index] {
            if thinkingItemIDs.remove(textID) != nil {
                combined = chunk
            } else {
                combined = text + chunk
            }
            items[index] = .assistant(id: id, text: combined)
        } else {
            items.append(.assistant(id: textID, text: chunk))
        }
        isCurrentTurnThinkingStep = false
        resolveCitations(itemID: textID.uuidString, text: combined)
    }

    @MainActor
    func finishTurn(notice: GopilotTranscriptItem?, turnID: UUID? = nil, interrupted: Bool = false) {
        if let id = currentAssistantID {
            flushNow(assistantID: id)
        }
        for itemID in thinkingItemIDs {
            items.removeAll { $0.id == itemID.uuidString }
        }
        thinkingItemIDs = []
        isCurrentTurnThinkingStep = false
        for index in items.indices {
            if case .activity(let id, let label, .running) = items[index] {
                items[index] = .activity(id: id, label: label, status: .failed)
            }
        }
        if pendingTrustNotice {
            pendingTrustNotice = false
            items.append(.notice(id: UUID(), kind: .trust, text: "Running Go commands executes or compiles code from this project, so Gopilot needs you to trust it first. Nothing was run.", canRetry: false))
        }
        refreshChangeJournal()
        let lastAssistantEntry = items.reversed().compactMap({ item -> (UUID, String)? in
            if case .assistant(let id, let text) = item { return (id, text) }
            return nil
        }).first
        let lastAssistant = lastAssistantEntry?.0
        if let lastAssistant { narrationItemIDs.remove(lastAssistant) }
        if turnAccounting.requests > 0 {
            let formatted = Self.formatUsage(
                requests: turnAccounting.requests,
                inputTokens: turnAccounting.inputTokens,
                outputTokens: turnAccounting.outputTokens,
                reasoningTokens: turnAccounting.reasoningTokens,
                routeID: activeRoute?.id
            )
            usageSummary = "Last answer: \(formatted)"
            if let lastAssistant {
                answerUsage[lastAssistant.uuidString] = formatted
            }
        }
        if let lastAssistant {
            let existingCited = answerSourcesUsed[lastAssistant.uuidString]?.cited ?? []
            let summary = SourcesUsedSummary(
                attached: turnAccounting.attachedItems,
                lookedUp: turnAccounting.lookedUpItems,
                cited: existingCited
            )
            if !summary.isEmpty {
                answerSourcesUsed[lastAssistant.uuidString] = summary
            }
        }
        if interrupted {
            let changes = turnChangeSummary()
            if !changes.applied.isEmpty || !changes.pending.isEmpty {
                var note = "The previous turn ended before it finished."
                if !changes.applied.isEmpty { note += " Gopilot had already applied unsaved changes to: \(changes.applied.joined(separator: ", "))." }
                if !changes.pending.isEmpty { note += " Changes waiting for the user's review: \(changes.pending.joined(separator: ", "))." }
                note += " Re-read these files before editing them again."
                pendingContextNotes.append(note)
            }
        }
        if let session, let recordedID = turnID {
            let accessed = turnAccounting.accessedPaths
            Task { @MainActor [weak self] in
                guard let turnMessages = await session.runtime.turnMessages(recordedID), !turnMessages.isEmpty else { return }
                let turn = ConversationTurn(id: recordedID, messages: turnMessages)
                guard turn.isComplete, self?.priorTurns.contains(where: { $0.id == recordedID }) == false else { return }
                self?.priorTurns.append(turn)
                if !accessed.isEmpty {
                    self?.turnProvenance[recordedID] = accessed
                }
            }
        }
        if let notice { items.append(notice) }
        persistEvidence()
        isRunning = false
        currentAssistantID = nil
        currentTextID = nil
        currentUserItemID = nil
        activeTurnID = nil
        turnTask = nil
    }

    static func cancelledText(_ payload: [String: String], changes: (applied: [String], pending: [String]) = ([], [])) -> String {
        if !changes.applied.isEmpty || !changes.pending.isEmpty {
            return "Stopped." + changedFilesSentence(changes)
        }
        let started = Int(payload["toolCallsStarted"] ?? "0") ?? 0
        return started == 0 ? "Stopped. Nothing in your project changed." : "Stopped. Gopilot did not change any files in this turn."
    }

    static func failureText(_ payload: [String: String]) -> String {
        switch payload["code"] ?? "" {
        case "unauthorized": "The provider rejected authentication. Check the API key in Settings."
        case "rateLimited":
            if let seconds = payload["retryAfterSeconds"], !seconds.isEmpty { "The provider is rate limiting requests. Try again in \(seconds) seconds." }
            else { "The provider is rate limiting requests. Try again shortly." }
        case "server": "The provider reported an error (\(payload["status"] ?? "5xx")). Try again."
        case "offline": "Could not reach the provider. Your project files and documentation still work offline."
        case "truncated": "Request stopped before completion. Your question is kept; try again."
        case "outputTruncated": "The model's response was cut off by its output limit while writing a step, so that step did not run. Ask Gopilot to continue in smaller steps."
        case "contextLengthExceeded": "This conversation no longer fits in the model's context window. Start a new conversation, or attach less context."
        case "protocolError", "malformedResponse": "The provider sent a response Gopilot could not use. Try again, or check the model in Settings."
        case "requestRejected":
            if let reason = payload["message"], !reason.isEmpty {
                "The provider rejected this request: \(reason) Retry sends the same conversation again. If it keeps failing, start a new conversation."
            } else {
                "The provider rejected this request (status \(payload["status"] ?? "4xx")). Retry sends the same conversation again. If it keeps failing, start a new conversation."
            }
        default: "Request failed. Try again."
        }
    }
}
