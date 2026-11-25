import Foundation
import GopilotRuntime

public actor SessionRecorder {
    public nonisolated let conversationID: UUID

    private let store: WorkspaceStore
    private var builder: ConversationBuilder
    private var pending: [Data] = []
    private var pendingUpdatedAt: Date?
    private var pendingTitle: String?
    private var nextSeq: Int
    private var lastFlush: Date
    private var needsLineGuard = false
    public private(set) var lastWriteError: StoreError?

    init(store: WorkspaceStore, conversationID: UUID, builder: ConversationBuilder) {
        self.store = store
        self.conversationID = conversationID
        self.builder = builder
        self.nextSeq = builder.lastSeq + 1
        self.lastFlush = store.now()
    }

    public var pendingRecordCount: Int { pending.count }

    public func snapshot() -> Conversation? {
        builder.build(finalize: false)
    }

    public func setTitle(_ title: String) async throws {
        var record = makeRecord(.titleChanged, at: store.now())
        record.text = title
        try append(record)
        pendingTitle = title
        try await flush()
    }

    public func ingest(
        _ event: AgentEvent,
        prompt: String? = nil,
        displayLabel: String? = nil,
        routeSelection: TurnRouteSelection? = nil,
        projectContextEnabled: Bool? = nil,
        attachedPaths: [String]? = nil
    ) async throws {
        guard let record = record(
            for: event,
            prompt: prompt,
            displayLabel: displayLabel,
            routeSelection: routeSelection,
            projectContextEnabled: projectContextEnabled,
            attachedPaths: attachedPaths
        ) else { return }
        try append(record)
        await flushIfDue(force: event.kind.isTerminal)
    }

    public func recordMessages(turnID: UUID, messages: [ModelMessage], accessedPaths: [String]? = nil) async throws {
        var record = makeRecord(.messages, at: store.now(), turnID: turnID)
        record.messages = messages
        record.accessedPaths = accessedPaths
        try append(record)
    }

    @discardableResult
    public func consume(_ events: AsyncStream<AgentEvent>, prompt: String, finalMessages: @Sendable () async -> [ModelMessage]) async throws -> TurnTerminalState? {
        var terminal: AgentEvent?
        var turnID: UUID?
        for await event in events {
            turnID = turnID ?? event.turnID
            if event.kind.isTerminal {
                terminal = event
                continue
            }
            try await ingest(event, prompt: prompt)
        }
        guard let terminal, let turnID else {
            try await flush()
            return nil
        }
        let messages: [ModelMessage]
        if terminal.kind == .turnCompleted {
            let transcript = await finalMessages()
            if let start = transcript.lastIndex(where: { $0.role == .user && $0.content == prompt }) {
                messages = Array(transcript[start...])
            } else {
                messages = [ModelMessage(role: .user, content: prompt)]
            }
        } else {
            messages = [ModelMessage(role: .user, content: prompt)]
        }
        try await recordMessages(turnID: turnID, messages: messages)
        try await ingest(terminal, prompt: prompt)
        try await flush()
        return builder.build(finalize: false)?.turns.last(where: { $0.id == turnID })?.terminal
    }

    public func flush() async throws {
        try await writePending()
        try await store.persistIndexIfDirty()
    }

    private func flushIfDue(force: Bool) async {
        guard !pending.isEmpty else { return }
        let elapsed = store.now().timeIntervalSince(lastFlush)
        guard force || pending.count >= store.limits.flushRecordThreshold || elapsed >= store.limits.flushInterval else { return }
        do { try await writePending() } catch {
            lastWriteError = StoreError.mapping(error)
        }
    }

    private func writePending() async throws {
        guard !pending.isEmpty else { return }
        var data = Data()
        if needsLineGuard { data.append(0x0A) }
        for line in pending { data.append(line) }
        let turnCount = builder.build(finalize: false)?.turns.count ?? 0
        do {
            try await store.appendJournal(id: conversationID, data: data, updatedAt: pendingUpdatedAt ?? store.now(), turnCount: turnCount, title: pendingTitle)
        } catch {
            needsLineGuard = true
            let mapped = StoreError.mapping(error)
            lastWriteError = mapped
            throw mapped
        }
        pending.removeAll()
        pendingUpdatedAt = nil
        pendingTitle = nil
        needsLineGuard = false
        lastWriteError = nil
        lastFlush = store.now()
    }

    private func append(_ record: JournalRecord) throws {
        let line: Data
        do { line = try record.encodedLine() } catch { throw StoreError.mapping(error) }
        builder.apply(record)
        pending.append(line)
        pendingUpdatedAt = max(pendingUpdatedAt ?? record.at, record.at)
    }

    private func makeRecord(_ kind: JournalRecord.Kind, at: Date, turnID: UUID? = nil) -> JournalRecord {
        defer { nextSeq += 1 }
        return JournalRecord(seq: nextSeq, at: at, kind: kind, turnID: turnID)
    }

    private func record(
        for event: AgentEvent,
        prompt: String?,
        displayLabel: String? = nil,
        routeSelection: TurnRouteSelection? = nil,
        projectContextEnabled: Bool? = nil,
        attachedPaths: [String]? = nil
    ) -> JournalRecord? {
        switch event.kind {
        case .turnStarted:
            var record = makeRecord(.turnStarted, at: event.timestamp, turnID: event.turnID)
            record.text = prompt ?? ""
            record.displayLabel = displayLabel
            record.routeSelection = routeSelection ?? event.payload["routeID"].map {
                TurnRouteSelection(
                    routeID: $0,
                    displayName: event.payload["modelID"],
                    effort: event.payload["reasoningEffort"].flatMap(ReasoningEffort.init(rawValue:)) ?? .default
                )
            }
            record.projectContextEnabled = projectContextEnabled
            record.attachedPaths = attachedPaths
            return record
        case .activity:
            guard event.payload["label"] == "Requesting model" else { return nil }
            return makeRecord(.modelRequested, at: event.timestamp, turnID: event.turnID)
        case .toolRequested:
            var record = makeRecord(.toolRequested, at: event.timestamp, turnID: event.turnID)
            record.callID = event.payload["callID"]
            record.name = event.payload["name"]
            record.argsHash = event.payload["argumentsJSON"].map(ContentHash.normalizedArgumentsHash)
            return record.callID == nil ? nil : record
        case .toolStarted:
            var record = makeRecord(.toolStarted, at: event.timestamp, turnID: event.turnID)
            record.callID = event.payload["callID"]
            record.name = event.payload["name"]
            return record.callID == nil ? nil : record
        case .toolFinished:
            var record = makeRecord(.toolFinished, at: event.timestamp, turnID: event.turnID)
            record.callID = event.payload["callID"]
            record.status = event.payload["status"]
            record.errorCode = event.payload["errorCode"].flatMap { $0.isEmpty ? nil : $0 }
            return record.callID == nil ? nil : record
        case .usageUpdated:
            var record = makeRecord(.usage, at: event.timestamp, turnID: event.turnID)
            record.inputTokens = event.payload["inputTokens"].flatMap(Int.init)
            record.outputTokens = event.payload["outputTokens"].flatMap(Int.init)
            record.reasoningTokens = event.payload["reasoningTokens"].flatMap(Int.init)
            return record
        case .turnCompleted:
            return terminalRecord(.completed, event: event, text: nil)
        case .turnCancelled:
            return terminalRecord(.cancelled, event: event, text: nil)
        case .turnFailed:
            return terminalRecord(.failed, event: event, text: event.payload["code"])
        case .turnBudgetExceeded:
            return terminalRecord(.budgetExceeded, event: event, text: event.payload["limit"])
        case .textDelta:
            return nil
        }
    }

    private func terminalRecord(_ state: TurnTerminalState, event: AgentEvent, text: String?) -> JournalRecord {
        var record = makeRecord(.turnTerminal, at: event.timestamp, turnID: event.turnID)
        record.terminal = state
        record.text = text
        return record
    }
}
