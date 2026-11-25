#if DEBUG
import AppKit
import Foundation
import GopilotPolicy
import GopilotRuntime

private struct EvalPrompt: Decodable {
    let id: String
    let prompt: String
    let allowsExecution: Bool?
    let followUps: [String]?
    let applyProposals: Bool?
}

@MainActor
final class GopilotEvalHarness {
    static let shared = GopilotEvalHarness()

    private var started = false
    private var runs: [[String: Any]] = []
    private var cancelProbes: [Int] = []

    func startIfRequested(state: GopilotState) {
        let environment = ProcessInfo.processInfo.environment
        guard !started, let promptsPath = environment["GOPILOT_EVAL_PROMPTS"], let outPath = environment["GOPILOT_EVAL_OUT"] else { return }
        started = true
        let repeats = max(1, Int(environment["GOPILOT_EVAL_RUNS"] ?? "") ?? 1)
        let probes = Int(environment["GOPILOT_EVAL_CANCEL_PROBES"] ?? "") ?? 0
        let warmup = Double(environment["GOPILOT_EVAL_WARMUP"] ?? "") ?? 15
        let waitsForProfile = environment["GOPILOT_DEV_PROFILE"] != nil
        let startedAt = ISO8601DateFormatter().string(from: Date())
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(warmup))
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: promptsPath)), let prompts = try? JSONDecoder().decode([EvalPrompt].self, from: data) else {
                print("GOPILOT eval: prompts file unreadable")
                NSApp.terminate(nil)
                return
            }
            for prompt in prompts {
                for run in 1...repeats {
                    let record = await self.execute(prompt: prompt, run: run, state: state, waitsForProfile: waitsForProfile)
                    self.runs.append(record)
                    self.write(to: outPath, startedAt: startedAt)
                    print("GOPILOT eval done \(prompt.id) run \(run) terminal=\(record["terminal"] ?? "")")
                }
            }
            for _ in 0..<probes {
                if let latency = await self.probeCancel(state: state) { self.cancelProbes.append(latency) }
                self.write(to: outPath, startedAt: startedAt)
            }
            self.write(to: outPath, startedAt: startedAt)
            NSApp.terminate(nil)
        }
    }

    private func write(to path: String, startedAt: String) {
        let object: [String: Any] = [
            "schema": 1,
            "model": GopilotProviderSettings.shared.modelID,
            "startedAt": startedAt,
            "runs": runs,
            "cancelProbesMs": cancelProbes
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func prepare(state: GopilotState, allowsExecution: Bool, waitsForProfile: Bool) async {
        state.mode = .agent
        state.newConversation()
        state.interaction.autoApprove = allowsExecution
        state.interaction.approvalLog = []
        if allowsExecution { GopilotTrust.set(true, path: state.workspacePath) }
        if waitsForProfile {
            var waited = 0
            while state.profilePaths.isEmpty, waited < 100 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 1
            }
        }
    }

    private func runTurn(_ text: String, state: GopilotState) async -> Bool {
        state.send(text)
        var waited = 0
        while state.isRunning, waited < 1500 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        guard state.isRunning else { return false }
        state.stop()
        var grace = 0
        while state.isRunning, grace < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            grace += 1
        }
        return true
    }

    private func applyAndSave(state: GopilotState) async {
        let ids: [UUID] = state.items.compactMap { if case .proposal(let id, _, _, _) = $0 { id } else { nil } }
        for id in ids {
            await state.review(id)
            await state.applyReviewed(workspace: WorkspaceState.shared)
        }
        await withCheckedContinuation { continuation in
            WorkspaceState.shared.saveAllEdited(then: { continuation.resume() }, onFailure: { continuation.resume() })
        }
        try? await Task.sleep(for: .seconds(1))
    }

    private func probeCancel(state: GopilotState) async -> Int? {
        await prepare(state: state, allowsExecution: false, waitsForProfile: false)
        var toolStarted = false
        var terminalAt: Double?
        state.evalObserver = { event in
            if event.kind == .toolStarted { toolStarted = true }
            if event.kind.isTerminal { terminalAt = ProcessInfo.processInfo.systemUptime }
        }
        state.send("Read every Go file in this project one by one and explain each in detail.")
        var waited = 0
        while !toolStarted, state.isRunning, waited < 200 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard toolStarted else {
            state.evalObserver = nil
            return nil
        }
        let stopAt = ProcessInfo.processInfo.systemUptime
        state.stop()
        waited = 0
        while terminalAt == nil, waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        state.evalObserver = nil
        guard let terminalAt else { return nil }
        return Int((terminalAt - stopAt) * 1000)
    }

    private func execute(prompt: EvalPrompt, run: Int, state: GopilotState, waitsForProfile: Bool) async -> [String: Any] {
        await prepare(state: state, allowsExecution: prompt.allowsExecution ?? false, waitsForProfile: waitsForProfile)
        var events: [AgentEvent] = []
        state.evalObserver = { events.append($0) }
        let began = ProcessInfo.processInfo.systemUptime
        var timedOut = await runTurn(prompt.prompt, state: state)
        for followUp in prompt.followUps ?? [] where !timedOut {
            if prompt.applyProposals == true { await applyAndSave(state: state) }
            timedOut = await runTurn(followUp, state: state)
        }
        state.evalObserver = nil
        try? await Task.sleep(for: .milliseconds(300))
        return await assemble(prompt: prompt, run: run, events: events, state: state, began: began, timedOut: timedOut)
    }

    private func assemble(prompt: EvalPrompt, run: Int, events: [AgentEvent], state: GopilotState, began: Double, timedOut: Bool) async -> [String: Any] {
        let first = events.first?.timestamp ?? Date()
        func ms(_ date: Date) -> Int { Int(date.timeIntervalSince(first) * 1000) }
        var trace: [[String: Any]] = []
        var open: [String: Int] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var anyUsage = false
        var requests = 0
        var ttft: Int?
        var firstEvidence: Int?
        var terminal = timedOut ? "turnCancelled" : "turnFailed"
        var totalMs = 0
        var errorText: String?
        for event in events {
            switch event.kind {
            case .toolStarted:
                open[event.payload["callID"] ?? ""] = trace.count
                trace.append(["name": event.payload["name"] ?? "", "args": event.payload["arguments"] ?? "", "status": "error", "errorCode": "unfinished", "startMs": ms(event.timestamp), "endMs": ms(event.timestamp), "result": ""])
            case .toolFinished:
                if let index = open[event.payload["callID"] ?? ""] {
                    trace[index]["status"] = event.payload["status"] ?? "error"
                    trace[index]["errorCode"] = event.payload["errorCode"] ?? ""
                    trace[index]["endMs"] = ms(event.timestamp)
                    trace[index]["result"] = event.payload["result"] ?? event.payload["detail"] ?? ""
                }
                if firstEvidence == nil, event.payload["status"] == "ok" { firstEvidence = ms(event.timestamp) }
            case .textDelta:
                if ttft == nil { ttft = ms(event.timestamp) }
            case .activity:
                if event.payload["label"] == "Requesting model" || event.payload["label"] == "Summarizing findings" { requests += 1 }
            case .usageUpdated:
                if let value = Int(event.payload["inputTokens"] ?? "") { inputTokens += value; anyUsage = true }
                if let value = Int(event.payload["outputTokens"] ?? "") { outputTokens += value; anyUsage = true }
            default:
                break
            }
            if event.kind.isTerminal {
                terminal = event.kind.rawValue
                totalMs = ms(event.timestamp)
                if event.kind == .turnFailed { errorText = event.payload["message"] ?? event.payload["code"] }
            }
        }
        var answer = ""
        var proposals = 0
        for item in state.items {
            if case .assistant(_, let text) = item { answer += (answer.isEmpty ? "" : "\n\n") + text }
            if case .proposal = item { proposals += 1 }
        }
        proposals = max(proposals, trace.filter { ($0["name"] as? String) == "propose_patch" && ($0["status"] as? String) == "ok" }.count)
        let normalized = GopilotCitationNormalizer.normalize(answer)
        var citations: [[String: Any]] = []
        var evidenceList: [[String: Any]] = []
        if let session = state.evalSession, let workspaceID = session.workspaceID {
            let snapshot = await session.snapshot?()
            let expression = try! NSRegularExpression(pattern: #"\[E[0-9]+\]"#)
            var seen = Set<String>()
            for match in expression.matches(in: normalized, range: NSRange(location: 0, length: (normalized as NSString).length)) {
                let token = (normalized as NSString).substring(with: match.range)
                guard seen.insert(token).inserted else { continue }
                let id = String(token.dropFirst().dropLast())
                if case .found(let evidence) = await session.evidence.lookup(id: id, workspaceID: workspaceID) {
                    var stale = false
                    if let snapshot {
                        let staleness = await session.evidence.isStale(evidence, against: snapshot)
                        stale = staleness.reasons.contains(.documentVersionChanged) || staleness.reasons.contains(.contentHashChanged)
                    }
                    let ref = evidence.sourceRefs.first
                    citations.append(["token": token, "resolved": true, "path": ref?.path ?? NSNull(), "startLine": ref?.range.map { $0.startLine + 1 } ?? NSNull(), "endLine": ref?.range.map { $0.endLine + 1 } ?? NSNull(), "stale": stale])
                } else {
                    citations.append(["token": token, "resolved": false, "path": NSNull(), "startLine": NSNull(), "endLine": NSNull(), "stale": false])
                }
            }
            for evidence in await session.evidence.all(workspaceID: workspaceID) {
                evidenceList.append(["id": evidence.id, "kind": evidence.kind.rawValue, "path": evidence.sourceRefs.first?.path ?? NSNull(), "contentHash": evidence.contentHash, "truncated": evidence.isTruncated])
            }
        }
        let approvals = state.interaction.approvalLog.map { ["operation": $0.0, "decision": $0.1] }
        let record: [String: Any] = [
            "promptID": prompt.id,
            "run": run,
            "terminal": terminal,
            "answer": answer,
            "toolTrace": trace,
            "citations": citations,
            "evidence": evidenceList,
            "usage": ["requests": requests, "inputTokens": (anyUsage ? inputTokens as Any : NSNull()), "outputTokens": (anyUsage ? outputTokens as Any : NSNull())],
            "ttftMs": ttft.map { $0 as Any } ?? NSNull(),
            "firstEvidenceMs": firstEvidence.map { $0 as Any } ?? NSNull(),
            "totalMs": totalMs,
            "approvals": approvals,
            "proposals": proposals,
            "error": errorText.map { $0 as Any } ?? (timedOut ? "timed out after 300 s" : NSNull())
        ]
        return record
    }
}
#endif
