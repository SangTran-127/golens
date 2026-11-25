import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

extension GopilotState {
    @MainActor
    func noteProfile(path: String) {
        profilePaths.removeAll { $0 == path }
        profilePaths.append(path)
    }

    @MainActor
    func investigateHotspot(function: String, file: String, line: Int, kind: String) {
        isPanelVisible = true
        guard !profilePaths.isEmpty else {
            items.append(.notice(id: UUID(), kind: .info, text: "Open a .pprof profile first, then choose Investigate Hotspot on a function.", canRetry: false))
            return
        }
        let location = file.isEmpty ? "" : " (\((file as NSString).lastPathComponent):\(line))"
        send("Investigate the \(kind) hotspot \(function)\(location) in the attached profile. Read the profile data and the source, say what the profile shows and what it does not show, give hypotheses with their trade-offs, and propose how to measure it. Do not claim any speedup.")
    }

    @MainActor
    func explainSelection(workspace: WorkspaceState) {
        isPanelVisible = true
        guard attachSelection(from: workspace) else {
            items.removeAll { if case .notice = $0 { true } else { false } }
            items.append(.notice(id: UUID(), kind: .info, text: "Select some code in the editor first, then choose Explain Selection.", canRetry: false))
            return
        }
        send(GopilotPresetPrompt.explainSelection)
    }

    @MainActor
    func traceFlow(workspace: WorkspaceState) {
        isPanelVisible = true
        guard attachSelection(from: workspace) else {
            items.removeAll { if case .notice = $0 { true } else { false } }
            items.append(.notice(id: UUID(), kind: .info, text: "Select a function or call in the editor first, then choose Trace This Flow.", canRetry: false))
            return
        }
        send(GopilotPresetPrompt.traceFlow)
    }

    func evidence(forID id: String) -> Evidence? {
        for segments in citationSegments.values {
            for case .citation(let evidence) in segments where evidence.id == id { return evidence }
        }
        return nil
    }

    @MainActor
    func trustProject() {
        GopilotTrust.set(true, path: workspacePath)
        if let id = session?.workspaceID, let grants = session?.grants {
            Task { await grants.setTrusted(true, workspaceID: id) }
        }
        pendingContextNotes.append("The user has just marked this project as trusted for test runs. Any earlier denial about trust no longer applies; call the run tool again if the user asks to run something.")
        items.removeAll { if case .notice(_, .trust, _, _) = $0 { true } else { false } }
        let followUp = agentPermissionMode.autoApprovesWorkspaceRuns
            ? "Ask again and Gopilot will run Go checks and tests without asking, because the permission is set to Auto."
            : "Ask again and Gopilot will request approval for each run."
        items.append(.notice(id: UUID(), kind: .info, text: "This project is trusted for running Go commands. " + followUp, canRetry: false))
    }

    @MainActor
    var sandboxStatus: GopilotSandboxStatus {
        if SandboxVMManager.shared.executionMode == .host {
            return .ready
        }
        return switch SandboxVMManager.shared.state {
        case .running: .ready
        case .starting(let phase): .starting(phase)
        case .restarting: .starting("Restarting")
        case .paused: .paused
        case .stopped: .stopped
        case .failed(let description, let suggestion): .unavailable(reason: description, recovery: suggestion)
        }
    }

    @MainActor
    func restartLinuxContainer() {
        Task { @MainActor in
            let manager = SandboxVMManager.shared
            switch manager.state {
            case .stopped:
                try? await manager.start()
            case .paused:
                try? await manager.resume()
            case .failed:
                try? await manager.restart()
            case .running, .starting, .restarting:
                break
            }
        }
    }

    @MainActor
    func takeContextNotes() -> [String] {
        let notes = pendingContextNotes
        pendingContextNotes = []
        return notes
    }

    @MainActor
    func openCitation(_ evidence: Evidence, workspace: WorkspaceState) {
        guard let ref = evidence.sourceRefs.first else { return }
        let absolute = workspace.activeWorkspacePath + "/" + ref.path
        Task { @MainActor in
            if session == nil {
                items.append(.notice(id: UUID(), kind: .info, text: "This citation comes from a saved conversation. The file may have changed since, so the lines may have moved.", canRetry: false))
                workspace.jumpToLocation(path: absolute, line: (ref.range?.startLine ?? 0) + 1)
                return
            }
            if let session, let snapshot = await session.snapshot?() {
                let staleness = await session.evidence.isStale(evidence, against: snapshot)
                let changed = staleness.reasons.contains(.documentVersionChanged) || staleness.reasons.contains(.contentHashChanged) || staleness.reasons.contains(.workspaceMismatch)
                if changed {
                    items.append(.notice(id: UUID(), kind: .warning, text: "This source changed since the answer was generated, so the cited lines may have moved. Ask again to refresh the answer.", canRetry: false))
                    return
                }
            }
            workspace.jumpToLocation(path: absolute, line: (ref.range?.startLine ?? 0) + 1)
        }
    }

    @MainActor
    func openSourceUsageItem(_ item: SourceUsageItem, workspace: WorkspaceState) {
        guard !workspace.activeWorkspacePath.isEmpty else { return }
        let absolute = workspace.activeWorkspacePath + "/" + item.path
        workspace.jumpToLocation(path: absolute, line: max(1, item.startLine ?? 1))
    }

    @MainActor
    func openRelativeFile(path: String, line: Int, workspace: WorkspaceState) {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return }
        let candidate = root + "/" + path
        if FileManager.default.fileExists(atPath: candidate) {
            workspace.jumpToLocation(path: candidate, line: max(1, line))
            return
        }
        let baseName = (path as NSString).lastPathComponent
        if let matched = availableFiles(in: workspace, query: baseName).first(where: { ($0 as NSString).lastPathComponent == baseName }) {
            workspace.jumpToLocation(path: root + "/" + matched, line: max(1, line))
        }
    }

    static func finishedActivityLabel(_ label: String, payload: [String: String]) -> String {
        guard let raw = payload["summary"], let data = raw.data(using: .utf8),
              let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return label }
        switch payload["name"] ?? "" {
        case "write_file", "edit_file", "propose_patch":
            let status = summary["proposalStatus"] as? String
            if status == "applied" { return label + ", applied unsaved" }
            if status == "proposed" { return label + ", waiting for review" }
            if status == "stale" { return label + ", not applied" }
            return label
        case "run_go_check", "run_tests", "run_benchmark":
            if summary["outcome"] as? String == "containerUnavailable" { return label + ", Linux container unavailable" }
            if let runStatus = summary["runStatus"] as? String { return label + ", " + runStatus }
            return label
        default:
            return label
        }
    }

    @MainActor
    func updateTodos(fromJSON rawJSON: String) {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawList = obj["todos"] as? [[String: Any]] else { return }
        var parsed: [GopilotTodoItem] = []
        for entry in rawList {
            guard let id = entry["id"] as? String,
                  let content = entry["content"] as? String,
                  let statusRaw = entry["status"] as? String,
                  let status = GopilotTodoItem.Status(rawValue: statusRaw) else { continue }
            parsed.append(GopilotTodoItem(id: id, content: content, status: status))
        }
        if !parsed.isEmpty {
            agentTodos = parsed
        }
    }

    @MainActor
    func recordToolAccess(toolName: String, argumentsJSON: String) {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rel = (obj["relativePath"] as? String) ?? (obj["path"] as? String),
              !rel.isEmpty else { return }
        turnAccounting.accessedPaths.insert(rel)
        let sLine = obj["startLine"] as? Int ?? obj["line"] as? Int
        let eLine = obj["endLine"] as? Int ?? sLine
        let item = SourceUsageItem(
            category: .lookedUp,
            path: rel,
            startLine: sLine,
            endLine: eLine
        )
        if !turnAccounting.lookedUpItems.contains(where: { $0.path == item.path && $0.startLine == item.startLine && $0.endLine == item.endLine }),
           !turnAccounting.attachedItems.contains(where: { $0.path == item.path }) {
            turnAccounting.lookedUpItems.append(item)
        }
    }

    @MainActor
    func resolveCitations(itemID: String, text: String) {
        guard text.contains("[E"), let session, let workspaceID = session.workspaceID else { return }
        Task { @MainActor in
            let segments = await CitationResolver().resolve(GopilotCitationNormalizer.normalize(text), workspaceID: workspaceID, store: session.evidence)
            citationSegments[itemID] = segments
            updateCitedSources(for: itemID, segments: segments)
        }
    }

    @MainActor
    func updateCitedSources(for itemID: String, segments: [CitationSegment]) {
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
        var current = answerSourcesUsed[itemID] ?? SourcesUsedSummary(attached: turnAccounting.attachedItems, lookedUp: turnAccounting.lookedUpItems, cited: [])
        current.cited = cited
        if !current.isEmpty {
            answerSourcesUsed[itemID] = current
        }
    }

    static func activityLabel(for tool: String, argumentsJSON: String? = nil) -> String {
        var target: String?
        if let argumentsJSON,
           let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rel = (obj["relativePath"] as? String) ?? (obj["path"] as? String), !rel.isEmpty {
                target = (rel as NSString).lastPathComponent
            } else if let query = obj["query"] as? String, !query.isEmpty {
                target = String(query.prefix(24))
            }
        }
        switch tool {
        case "project_summary": return "Reading project overview"
        case "list_files": return "Listing files"
        case "search_code": return target.map { "Searching for \($0)" } ?? "Searching code"
        case "read_source": return target.map { "Reading \($0)" } ?? "Reading source"
        case "document_symbols": return target.map { "Reading symbols in \($0)" } ?? "Reading symbols"
        case "find_symbols": return target.map { "Finding symbol \($0)" } ?? "Finding symbols"
        case "resolve_symbol": return target.map { "Resolving symbol in \($0)" } ?? "Resolving symbol"
        case "find_references": return target.map { "Finding references in \($0)" } ?? "Finding references"
        case "call_hierarchy": return target.map { "Reading call hierarchy in \($0)" } ?? "Reading call hierarchy"
        case "read_documentation": return "Reading documentation"
        case "read_diagnostics": return target.map { "Reading diagnostics in \($0)" } ?? "Reading diagnostics"
        case "read_memory": return "Checking saved notes"
        case "save_memory": return "Saving project memory"
        case "list_test_targets": return "Listing tests"
        case "run_tests": return "Running tests"
        case "run_benchmark": return "Running benchmark"
        case "read_run_result": return "Reading run result"
        case "list_profiles": return "Listing profiles"
        case "profile_hotspots": return "Reading profile hotspots"
        case "profile_frame": return "Reading profile frame"
        case "compare_benchmarks": return "Comparing benchmarks"
        case "propose_patch": return "Preparing a proposed change"
        case "write_file": return target.map { "Writing \($0)" } ?? "Writing file"
        case "edit_file": return target.map { "Editing \($0)" } ?? "Editing file"
        case "todo_write": return "Updating task plan"
        case "run_go_check":
            if let argumentsJSON,
               let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let check = obj["check"] as? String {
                switch check {
                case "build": return "Running go build"
                case "vet": return "Running go vet"
                case "mod_tidy": return "Running go mod tidy"
                default: break
                }
            }
            return "Running Go check"
        default: return "Using \(tool)"
        }
    }

    @MainActor
    func seedDebugUIState(_ stateName: String) {
        switch stateName {
        case "understand_recovery":
            let findingsID = UUID()
            let answerID = UUID()
            items = [
                .user(id: UUID(), text: GopilotPresetPrompt.understandProject, attachment: "README.md"),
                .activity(id: "act-1", label: "Reading project overview", status: .finished),
                .activity(id: "act-2", label: "Reading main.go", status: .finished),
                .activity(id: "act-3", label: "Reading service.go", status: .finished),
                .assistant(
                    id: findingsID,
                    text: """
                    **Findings gathered so far:**
                    - Inspected `go.mod` go.mod:1
                    - Inspected `main.go` main.go:1
                    - Inspected `service.go` service.go:12
                    """
                ),
                .assistant(
                    id: answerID,
                    text: """
                    ### What actually exists

                    - **Module & Go version:** `example.com/order-service` targeting Go `1.22` in `go.mod:1`.
                    - **Bootstrap package:** `main` wires the HTTP mux and storage backend in `main.go:14`.

                    ### Issues, by severity

                    1. **Unbounded request body decoding in `handler.go`:** `handleCreateOrder` decodes JSON directly from `r.Body` without `http.MaxBytesReader` in `handler.go:28`.
                    2. **Context cancellation not propagated in `store.go`:** `Store.SaveOrder` writes the order record without checking `ctx.Err()` in `store.go:42`.

                    **Concrete verification steps:**

                    ```
                    go test -run=^$ -bench=. -benchmem ./...
                    ```
                    """
                ),
                .notice(
                    id: UUID(),
                    kind: .budgetExceeded(hasFindings: true),
                    text: "Gopilot paused after reaching the step limit for one turn. Continue from the findings above or ask a narrower question.",
                    canRetry: false
                )
            ]
            answerUsage[answerID.uuidString] = "deepseek-chat · 6 requests · 2,480 in · 410 out"
            answerSourcesUsed[answerID.uuidString] = SourcesUsedSummary(
                attached: [
                    SourceUsageItem(category: .attached, path: "README.md", startLine: 1, endLine: 24)
                ],
                lookedUp: [
                    SourceUsageItem(category: .lookedUp, path: "main.go", startLine: 1, endLine: 42),
                    SourceUsageItem(category: .lookedUp, path: "service.go", startLine: 1, endLine: 68)
                ],
                cited: [
                    SourceUsageItem(category: .cited, path: "main.go", startLine: 1, endLine: 42),
                    SourceUsageItem(category: .cited, path: "handler.go", startLine: 1, endLine: 53),
                    SourceUsageItem(category: .cited, path: "store.go", startLine: 1, endLine: 48)
                ]
            )
        case "composer_context":
            attachments = [
                GopilotAttachment(
                    relativePath: "service.go",
                    absolutePath: workspacePath + "/service.go",
                    startLine: 1,
                    endLine: 48,
                    symbolName: nil,
                    text: "package main\n\ntype OrderService struct {\n    repo Repository\n}\n",
                    documentVersion: 3,
                    isUnsaved: true,
                    isWholeFile: true,
                    origin: .filePicker
                ),
                GopilotAttachment(
                    relativePath: "main.go",
                    absolutePath: workspacePath + "/main.go",
                    startLine: 10,
                    endLine: 28,
                    symbolName: "CreateOrder",
                    text: "func CreateOrder(ctx context.Context) error {\n    return nil\n}\n",
                    documentVersion: 1,
                    isUnsaved: false,
                    isWholeFile: false,
                    origin: .symbolPicker
                )
            ]
            projectContextEnabled = true
            selectedRouteID = "deepseek/v4.1-flash"
            selectedEffort = .medium
            let answerID = UUID()
            items = [
                .user(id: UUID(), text: "How does CreateOrder validate inventory before writing to the repository?", attachment: "service.go, CreateOrder · main.go"),
                .activity(id: "act-1", label: "Reading service.go", status: .finished),
                .activity(id: "act-2", label: "Resolving symbol in main.go", status: .finished),
                .assistant(
                    id: answerID,
                    text: """
                    `CreateOrder` validates the incoming item count before delegating to `OrderService.Reserve` in `service.go:18`.

                    1. Checks that `req.Quantity > 0` before touching the store.
                    2. Calls `repo.InsertOrder(ctx, order)` inside the same request context.
                    """
                )
            ]
            answerUsage[answerID.uuidString] = "deepseek-reasoner · 2 requests · 1,420 in · 280 out · 190 reasoning"
            answerSourcesUsed[answerID.uuidString] = SourcesUsedSummary(
                attached: [
                    SourceUsageItem(category: .attached, path: "service.go", startLine: 1, endLine: 48, isUnsaved: true),
                    SourceUsageItem(category: .attached, path: "main.go", startLine: 10, endLine: 28, symbolName: "CreateOrder")
                ],
                lookedUp: [
                    SourceUsageItem(category: .lookedUp, path: "repo.go", startLine: 12, endLine: 36)
                ],
                cited: []
            )
        case "project_context_off":
            projectContextEnabled = false
            attachments = [
                GopilotAttachment(
                    relativePath: "main.go",
                    absolutePath: workspacePath + "/main.go",
                    startLine: 1,
                    endLine: 30,
                    symbolName: nil,
                    text: "package main\n",
                    documentVersion: 1,
                    isUnsaved: false,
                    isWholeFile: true,
                    origin: .filePicker
                )
            ]
            let answerID = UUID()
            items = [
                .user(id: UUID(), text: "Check error handling in main.go only.", attachment: "main.go"),
                .activity(id: "act-1", label: "Reading main.go", status: .finished),
                .assistant(
                    id: answerID,
                    text: """
                    With **Project Context** off, Gopilot inspected only the attached `main.go` buffer.

                    - `main` logs startup errors directly and exits if listener binding fails.
                    """
                )
            ]
            answerUsage[answerID.uuidString] = "deepseek-chat · 1 request · 620 in · 115 out"
            answerSourcesUsed[answerID.uuidString] = SourcesUsedSummary(
                attached: [
                    SourceUsageItem(category: .attached, path: "main.go", startLine: 1, endLine: 30)
                ],
                lookedUp: [],
                cited: []
            )
        case "agent_mode_demo":
            mode = .agent
            agentPermissionMode = .auto
            projectContextEnabled = true
            selectedRouteID = "deepseek/v4.1-flash"
            selectedEffort = .medium
            let answerID = UUID()
            let appliedID = UUID()
            let proposalID = UUID()
            proposalPaths[appliedID] = ["README.md"]
            proposalPaths[proposalID] = ["GOLENS.md"]
            agentTodos = [
                GopilotTodoItem(id: "1", content: "Inspect go.mod and main.go service bootstrap", status: .completed),
                GopilotTodoItem(id: "2", content: "Write README.md and verify syntax diagnostics", status: .completed),
                GopilotTodoItem(id: "3", content: "Save architecture notes to .golens/MEMORY.md", status: .completed)
            ]
            items = [
                .user(id: UUID(), text: "Generate a comprehensive README.md for this repository and save the architecture to memory", attachment: nil),
                .activity(id: "act-1", label: "Reading project overview", status: .finished),
                .activity(id: "act-2", label: "Reading main.go", status: .finished),
                .activity(id: "act-3", label: "Writing README.md", status: .finished),
                .activity(id: "act-4", label: "Saving project memory", status: .finished),
                .applied(
                    id: appliedID,
                    text: GopilotState.appliedText(prefix: "Auto-applied", paths: ["README.md"], files: 1)
                ),
                .proposal(
                    id: proposalID,
                    summary: "Update GOLENS.md with repository architecture and test conventions",
                    files: 1
                ),
                .assistant(
                    id: answerID,
                    text: """
                    Generated and applied `README.md` with architecture overview, configuration table, and setup instructions, and saved the core service flow to project memory (`.golens/MEMORY.md`).

                    - **Module:** `example.com/order-service` in `go.mod:1`
                    - **Entry point:** HTTP server and store bootstrap in `main.go:14`
                    """
                )
            ]
            answerUsage[answerID.uuidString] = "deepseek/v4.1-flash · 3 requests · 1,840 in · 520 out"
            answerSourcesUsed[answerID.uuidString] = SourcesUsedSummary(
                attached: [],
                lookedUp: [
                    SourceUsageItem(category: .lookedUp, path: "go.mod", startLine: 1, endLine: 12),
                    SourceUsageItem(category: .lookedUp, path: "main.go", startLine: 1, endLine: 42),
                    SourceUsageItem(category: .lookedUp, path: "README.md", startLine: 1, endLine: 68)
                ],
                cited: []
            )
        case "saved_conversation_review":
            let wsUUID = UUID()
            let now = Date()
            var turn = Turn(id: UUID(), userPrompt: "Summarize the project and highlight what could not be verified", startedAt: now)
            turn.messages = [
                ModelMessage(role: .user, content: "Summarize the project and highlight what could not be verified"),
                ModelMessage(role: .assistant, content: "Summary")
            ]
            turn.terminal = .completed
            turn.endedAt = now
            let savedConv = Conversation(
                id: UUID(),
                workspaceID: wsUUID,
                providerID: "default",
                modelID: "deepseek/v4.1-flash",
                title: "summaries for me",
                createdAt: now,
                updatedAt: now,
                turns: [turn]
            )
            viewingSaved = savedConv
            let answerID = UUID()
            func makeEv(_ id: String, path: String, start: Int, end: Int, content: String) -> Evidence {
                Evidence(
                    id: id,
                    workspaceID: wsUUID,
                    producerID: "read_source",
                    kind: .source,
                    sourceRefs: [SourceRef(workspaceID: wsUUID, path: path, range: SourceRange(startLine: start, startCharacter: 0, endLine: end, endCharacter: 0))],
                    capturedAt: now,
                    snapshotID: "dev",
                    content: content,
                    contentHash: id,
                    isTruncated: false,
                    basis: .observed
                )
            }
            let e1 = makeEv("E1", path: "pkg/config/config.go", start: 0, end: 20, content: "package config")
            let e2 = makeEv("E2", path: "internal/bootstrap/app.go", start: 14, end: 30, content: "package bootstrap")
            let e3 = makeEv("E3", path: "deploy/Dockerfile", start: 0, end: 1, content: "FROM g")
            let e4 = makeEv("E4", path: "internal/identity/ports/customer_repo.go", start: 0, end: 24, content: "package ports")
            let e5 = makeEv("E5", path: "internal/identity/adapters/mongo/customer_repo.go", start: 0, end: 48, content: "package mongo")
            citationSegments[answerID.uuidString] = [
                .citation(e1), .citation(e2), .citation(e3), .citation(e4), .citation(e5)
            ]
            items = [
                .user(id: UUID(), text: "Summarize the project and highlight what could not be verified", attachment: nil),
                .assistant(
                    id: answerID,
                    text: """
                    6. **Configuration** — `pkg/config` defines the environment struct; loading happens in [config.go:1](gopilot-citation://E1) and `go.mod:1` `config.go:1`.

                    7. **Deployment** — `deploy/Dockerfile` contains only `FROM g` [Dockerfile:1](gopilot-citation://E3), a truncated/broken file.

                    ### What I could not verify

                    - Runtime wiring: `cmd/api/` is empty and there is no `main` that calls `bootstrap.New`/`openInfra` [app.go:15](gopilot-citation://E2); `Run` has no body, so no request flow is traceable end-to-end.
                    - Customer repository interface and Mongo adapter are split across [customer_repo.go:1](gopilot-citation://E4) and [customer_repo.go:1](gopilot-citation://E5).
                    """
                )
            ]
            answerUsage[answerID.uuidString] = "deepseek/v4.1-flash · 4 requests · 2,140 in · 390 out"
            answerSourcesUsed[answerID.uuidString] = SourcesUsedSummary(
                attached: [],
                lookedUp: [],
                cited: [
                    SourceUsageItem(category: .cited, path: "pkg/config/config.go", startLine: 1, endLine: 21, evidenceID: "E1"),
                    SourceUsageItem(category: .cited, path: "internal/bootstrap/app.go", startLine: 15, endLine: 31, evidenceID: "E2"),
                    SourceUsageItem(category: .cited, path: "internal/identity/ports/customer_repo.go", startLine: 1, endLine: 25, evidenceID: "E4"),
                    SourceUsageItem(category: .cited, path: "internal/identity/adapters/mongo/customer_repo.go", startLine: 1, endLine: 48, evidenceID: "E5")
                ]
            )
        default:
            break
        }
    }
}
