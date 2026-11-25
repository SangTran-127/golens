import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis

final class ApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApprovalDecision?, Never>?
    private var finished = false
    private var task: Task<Void, Never>?

    func install(_ next: CheckedContinuation<ApprovalDecision?, Never>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            next.resume(returning: nil)
            return false
        }
        continuation = next
        lock.unlock()
        return true
    }

    func setTask(_ next: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            next.cancel()
            return
        }
        task = next
        lock.unlock()
    }

    func finish(_ value: ApprovalDecision?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        let running = task
        continuation = nil
        task = nil
        lock.unlock()
        pending?.resume(returning: value)
        if value == nil { running?.cancel() }
    }
}

enum ApprovalAwait {
    static func request(_ card: ExecutionApprovalCard, from provider: ApprovalProvider) async -> ApprovalDecision? {
        if Task.isCancelled { return nil }
        let gate = ApprovalGate()
        let decision: ApprovalDecision? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision?, Never>) in
                guard gate.install(continuation) else { return }
                let task = Task {
                    let answer = await provider.requestApproval(card)
                    gate.finish(answer)
                }
                gate.setTask(task)
            }
        } onCancel: {
            gate.finish(nil)
        }
        if Task.isCancelled { return nil }
        return decision
    }
}

struct RunTargets: Sendable {
    let package: String
    let moduleDirectory: String
    let names: [String]
    let namedSelection: [String]
}

struct RunPlan: Sendable {
    let kind: GoCommand.Kind
    let targets: RunTargets
    let command: GoCommand
    let timeoutSeconds: Int
    let goCount: Int
    let benchtime: String?
    let targetHash: String
    let selector: String
    let workingDirectory: URL
}

extension ExecutionKit {
    static let toolchainTimeoutMargin = 20

    static let readOnlyAdvice = "Continue with the read-only tools (read_source, search_code, find_references and similar); do not retry the run."

    func listTestTargets() -> ExecTool {
        makeTool(
            name: "list_test_targets",
            description: "List the test and benchmark IDs available in a package scope (default ./...). IDs have the form <package>#<Name> and are what run_tests and run_benchmark accept.",
            parameters: ToolSchemas.object(properties: [
                #""packageScope":{"type":"string","minLength":1,"maxLength":256}"#,
                ToolSchemas.cursor, ToolSchemas.limit(200)
            ])
        ) { callID, args in
            guard let backend = context.backends.testTargets else {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "list_test_targets has no backend in this host."])
            }
            let scope = args["packageScope"]?.stringValue ?? "./..."
            do { try GoCommandBuilder.validatePackageSelector(scope) } catch {
                return failure(callID: callID, code: .invalidArguments, message: "packageScope is not a valid Go package selector.")
            }
            guard let offset = cursorOffset(args["cursor"]?.stringValue) else {
                return failure(callID: callID, code: .invalidArguments, message: "cursor is not valid.")
            }
            let limit = args["limit"]?.intValue ?? 100
            let snapshot = await context.snapshot()
            switch await backend.targets(in: scope) {
            case .empty:
                return envelope(callID: callID, outcome: "empty", code: nil, retryable: false, snapshotID: snapshot.id, fields: ["message": "No tests or benchmarks were found in this scope.", "complete": true])
            case .unavailable(let reason):
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: snapshot.id, fields: ["reason": redact(JSONText.clip(reason, 200))])
            case .timeout:
                return envelope(callID: callID, outcome: "timeout", code: .timeout, retryable: true, snapshotID: snapshot.id, fields: ["message": "The backend did not answer in time. This does not mean there are no targets."])
            case .found(let found):
                let sorted = found.sorted { ($0.package, $0.kind.rawValue, $0.name) < ($1.package, $1.kind.rawValue, $1.name) }
                let window = Array(sorted.dropFirst(offset).prefix(limit))
                let items: [[String: Any]] = window.map { ["id": $0.id, "package": $0.package, "name": redact($0.name), "kind": $0.kind.rawValue] }
                let base: [String: Any] = ["scope": scope, "total": sorted.count]
                let shown = ItemFit.shownCount(base: base, key: "targets", items: items)
                var fields = base
                fields["targets"] = Array(items.prefix(shown))
                let next = offset + shown
                let hasMore = next < sorted.count
                return await self.found(callID: callID, toolName: "list_test_targets", kind: .listing, snapshotID: snapshot.id, fields: fields, truncated: hasMore, nextCursor: hasMore ? String(next) : nil)
            }
        }
    }

    func runTests() -> ExecTool {
        makeTool(
            name: "run_tests",
            description: "Run Go tests by resolved target ID (<package>#<TestName>, or a package ID for every test in it) from list_test_targets. Running tests executes arbitrary code from this repository, so it needs explicit user approval and a trusted workspace; it may be declined. The result states the exit code and terminal status; a run is only passed when the exit code is 0.",
            parameters: ToolSchemas.object(properties: [
                #""targetIDs":{"type":"array","items":{"type":"string","minLength":1,"maxLength":300},"minItems":1,"maxItems":50}"#,
                #""timeoutSeconds":{"type":"integer","minimum":1,"maximum":600}"#
            ], required: ["targetIDs"])
        ) { callID, args in
            await executeRun(callID: callID, kind: .test, args: args)
        }
    }

    func runBenchmark() -> ExecTool {
        makeTool(
            name: "run_benchmark",
            description: "Run Go benchmarks by resolved target ID (<package>#<BenchmarkName>) with repeated samples (count, default 10). Timed runs never use -race or profiling flags. Needs explicit user approval because benchmarks execute repository code. Returns the run ID, raw samples and the comparability fingerprint.",
            parameters: ToolSchemas.object(properties: [
                #""benchmarkIDs":{"type":"array","items":{"type":"string","minLength":1,"maxLength":300},"minItems":1,"maxItems":50}"#,
                #""count":{"type":"integer","minimum":1,"maximum":100}"#,
                #""benchtime":{"type":"string","minLength":2,"maxLength":16}"#,
                #""timeoutSeconds":{"type":"integer","minimum":1,"maximum":600}"#
            ], required: ["benchmarkIDs"])
        ) { callID, args in
            await executeRun(callID: callID, kind: .benchmark, args: args)
        }
    }

    func readRunResult() -> ExecTool {
        makeTool(
            name: "read_run_result",
            description: "Read a finished run you started or one the user attached: status, exit code, fingerprints and redacted output in bounded pages. Pass nextCursor to continue.",
            parameters: ToolSchemas.object(properties: [
                #""runID":{"type":"string","minLength":1,"maxLength":64}"#,
                ToolSchemas.cursor
            ], required: ["runID"])
        ) { callID, args in
            guard let runID = UUID(uuidString: args["runID"]?.stringValue ?? "") else {
                return failure(callID: callID, code: .invalidArguments, message: "runID is not a valid run ID.")
            }
            guard let offset = cursorOffset(args["cursor"]?.stringValue) else {
                return failure(callID: callID, code: .invalidArguments, message: "cursor is not valid.")
            }
            guard let stored = await context.runs.run(runID) else {
                return failure(callID: callID, code: .notFound, message: "No run with this ID was started in this session or attached by the user.")
            }
            let snapshot = await context.snapshot()
            var fields = runSummaryFields(stored)
            fields["benchmarks"] = benchmarkSummaries(stored)
            var pageBytes = 3 * 1024
            var page = JSONText.page(stored.output, startScalar: offset, maxBytes: pageBytes)
            var withOutput = fields
            while true {
                withOutput["output"] = page.text
                withOutput["outputOffset"] = offset
                withOutput["outputEndOffset"] = page.endScalar
                withOutput["outputTotalLength"] = page.totalScalars
                if JSONText.size(withOutput) <= ToolLimits.resultBytes - ToolLimits.envelopeReserve || pageBytes <= 128 { break }
                pageBytes /= 2
                page = JSONText.page(stored.output, startScalar: offset, maxBytes: pageBytes)
            }
            let end = page.endScalar
            let hasMore = end < page.totalScalars
            if hasMore { withOutput["outputNote"] = "More output remains; pass nextCursor to read it." }
            return await self.found(callID: callID, toolName: "read_run_result", kind: stored.kind == .test ? .run : .benchmark, snapshotID: snapshot.id, fields: withOutput, truncated: hasMore || stored.record.outputTruncated, nextCursor: hasMore ? String(end) : nil)
        }
    }

    func executeRun(callID: String, kind: GoCommand.Kind, args: [String: JSONValue]) async -> ToolResultEnvelope {
        guard context.backends.canRun, let approvals = context.backends.approvals, let dirty = context.backends.dirtyBuffers, let fingerprints = context.backends.fingerprints else {
            return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "Running is not available in this host."])
        }
        let snapshot = await context.snapshot()
        let plan: RunPlan
        switch await makePlan(callID: callID, kind: kind, args: args, snapshot: snapshot) {
        case .reply(let reply): return reply
        case .value(let value): plan = value
        }

        if let active = await context.arbiter.activeRun() {
            return busyReply(callID: callID, info: active, snapshotID: snapshot.id)
        }
        if Task.isCancelled { return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled before anything ran.") }

        let operation: PolicyOperation = kind == .test ? .runTests : .runBenchmark
        let envNames = Set(context.environment.keys)
        let hashes = await fingerprints.diskHashes(moduleDirectory: plan.targets.moduleDirectory, package: plan.targets.package)
        let sourceHash = ContentHash.combined(hashes)
        let request = PermissionRequest(workspaceID: context.workspaceID, operation: operation, selector: plan.selector, targetConfigHash: plan.targetHash, workspaceSnapshotHash: sourceHash, envNames: envNames, timeoutSeconds: plan.timeoutSeconds, runCount: 1)
        switch await context.grants.authorize(request) {
        case .allow:
            break
        case .deny(let reason):
            return denied(callID: callID, message: reason.message, snapshotID: snapshot.id)
        case .needsApproval(let policyCard):
            let card = ExecutionApprovalCard(
                operation: operation,
                selector: plan.selector,
                packageSelector: plan.targets.package,
                testNames: kind == .test ? plan.targets.names : [],
                benchmarkNames: kind == .benchmark ? plan.targets.names : [],
                target: plan.targetHash,
                workingDirectory: plan.workingDirectory.path,
                argv: plan.command.argv,
                timeoutSeconds: plan.timeoutSeconds,
                goCount: plan.goCount,
                benchtime: plan.benchtime,
                runCount: 1,
                envNames: envNames.sorted(),
                outputLimitBytes: context.outputLimitBytes,
                mismatches: policyCard.mismatches,
                warning: policyCard.explanation,
                sessionGrantMaxRuns: max(1, context.sessionGrantMaxRuns),
                sessionGrantLifetime: context.sessionGrantLifetime
            )
            guard let decision = await ApprovalAwait.request(card, from: approvals) else {
                return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled while waiting for approval. Nothing was run.")
            }
            if decision == .decline {
                return denied(callID: callID, message: "The user declined to run this.", snapshotID: snapshot.id)
            }
            let grant = ExecutionGrant(
                workspaceID: context.workspaceID,
                operation: operation,
                selector: plan.selector,
                targetConfigHash: plan.targetHash,
                workspaceSnapshotHash: request.workspaceSnapshotHash,
                envNames: envNames,
                timeoutSeconds: plan.timeoutSeconds,
                maxRuns: decision == .allowOnce ? 1 : max(1, context.sessionGrantMaxRuns),
                expiresAt: Date().addingTimeInterval(decision == .allowOnce ? 300 : context.sessionGrantLifetime),
                ownerActionID: callID
            )
            do { try await context.grants.add(grant) } catch {
                return denied(callID: callID, message: "The approval could not be recorded.", snapshotID: snapshot.id)
            }
            guard case .allow = await context.grants.authorize(request) else {
                return denied(callID: callID, message: "The approval did not cover this run.", snapshotID: snapshot.id)
            }
        }
        if Task.isCancelled { return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled before anything ran.") }

        var runsSavedVersion = false
        var unsavedPaths: [String] = []
        switch await resolveDirtyBuffers(dirty) {
        case .stop(let message, let saveFailed):
            if saveFailed {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: snapshot.id, fields: ["message": message])
            }
            return cancelledReply(callID: callID, snapshotID: snapshot.id, message: message)
        case .proceed(let saved, let paths):
            runsSavedVersion = saved
            unsavedPaths = paths
        }
        if Task.isCancelled { return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled before anything ran.") }
        if let gate = await sandboxGate(callID: callID, snapshotID: snapshot.id) {
            return gate
        }

        let configHash = RunConfigHash.compute(argv: plan.command.argv, environmentNames: envNames.sorted(), extra: ["target": plan.targetHash])
        let spec = RunSpec(argv: plan.command.argv, workspaceRoot: context.workspaceRoot, workingDirectory: plan.workingDirectory, environment: context.environment, deadline: TimeInterval(plan.timeoutSeconds), outputLimitBytes: context.outputLimitBytes, sourceHash: sourceHash, configHash: configHash)

        let runID: UUID
        switch await context.arbiter.start(owner: .ai(actionID: callID), spec: spec) {
        case .busy(let info):
            return busyReply(callID: callID, info: info, snapshotID: snapshot.id)
        case .failedToLaunch(let reason):
            return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: snapshot.id, fields: ["message": "The process could not be started: \(redact(JSONText.clip(reason, 200)))"])
        case .sandboxUnavailable(let starting, let detail):
            return sandboxReply(callID: callID, snapshotID: snapshot.id, starting: starting, detail: detail)
        case .started(let id):
            runID = id
        }

        let arbiter = context.arbiter
        let finished = await withTaskCancellationHandler {
            await arbiter.awaitRecord(runID)
        } onCancel: {
            Task { _ = await arbiter.cancel(runID: runID, requester: .ai(actionID: callID)) }
        }
        guard let record = finished else {
            return failure(callID: callID, code: .unavailable, message: "The run finished without a record.", retryable: true)
        }
        let output = redact(await arbiter.output(for: runID) ?? "")
        var benchmark: BenchmarkRun?
        var ignored = 0
        if kind == .benchmark {
            let parsed = BenchmarkParser.parse(output)
            ignored = parsed.ignoredLineCount
            benchmark = BenchmarkRun(fingerprint: benchmarkFingerprint(plan: plan, snapshot: snapshot, sourceHash: sourceHash, parsed: parsed.environment, samples: parsed.samples), samples: parsed.samples)
        }
        let stored = StoredRun(record: record, kind: kind, packageSelector: plan.targets.package, output: output, benchmark: benchmark, ignoredBenchmarkLines: ignored, runsSavedVersion: runsSavedVersion, unsavedPaths: unsavedPaths, sourceFileCount: hashes.count)
        await context.runs.store(stored)
        return await runReply(callID: callID, toolName: kind == .test ? "run_tests" : "run_benchmark", stored: stored, snapshotID: snapshot.id)
    }

    func runStatusLabel(_ record: RunRecord) -> String {
        if record.status == .passed { return record.exitCode == 0 ? "passed" : "unknown" }
        return record.status.rawValue
    }

    func runSummaryFields(_ stored: StoredRun) -> [String: Any] {
        let record = stored.record
        var fields: [String: Any] = [
            "runID": record.runID.uuidString,
            "kind": stored.kind.rawValue,
            "runStatus": runStatusLabel(record),
            "exitCode": record.exitCode.map { Int($0) } ?? NSNull(),
            "terminationSignal": record.terminationSignal.map { Int($0) } ?? NSNull(),
            "argv": record.argv.map { JSONText.clip(redact($0), 300) },
            "cwd": record.cwd,
            "sourceHash": record.sourceHash,
            "configHash": record.configHash,
            "sourceFileCount": stored.sourceFileCount,
            "outputTruncatedByLimit": record.outputTruncated,
            "owner": ownerLabel(record.owner),
            "runsSavedVersion": stored.runsSavedVersion
        ]
        if let ended = record.endedAt {
            fields["durationSeconds"] = (ended.timeIntervalSince(record.startedAt) * 1000).rounded() / 1000
        }
        if !stored.unsavedPaths.isEmpty {
            fields["unsavedPathsNotIncluded"] = stored.unsavedPaths
            fields["note"] = "The run used the files saved on disk. Unsaved editor changes in the listed paths were not part of it."
        }
        return fields
    }

    func ownerLabel(_ owner: RunOwner) -> String {
        switch owner {
        case .user: return "user"
        case .ai(let id): return "ai:\(id)"
        }
    }

    func benchmarkSummaries(_ stored: StoredRun) -> [[String: Any]] {
        guard let run = stored.benchmark else { return [] }
        var names: [String] = []
        for sample in run.samples where !names.contains(sample.name) { names.append(sample.name) }
        return names.map { name in
            let samples = run.samples.filter { $0.name == name }
            let times = samples.compactMap(\.nsPerOp)
            let summary = BenchmarkStatistics.summarize(times)
            return [
                "name": redact(name),
                "sampleCount": samples.count,
                "nsPerOpSamples": times.map { JSONText.finite($0) },
                "medianNsPerOp": JSONText.finite(summary?.median)
            ]
        }
    }

    func benchmarkFingerprint(plan: RunPlan, snapshot: SourceSnapshot, sourceHash: String, parsed: [String: String], samples: [BenchSample]) -> BenchmarkFingerprint {
        var fingerprint = BenchmarkFingerprint(
            goVersion: snapshot.goVersion,
            gomaxprocs: context.environment["GOMAXPROCS"].flatMap { Int($0) },
            tags: snapshot.tags,
            benchmarkSelector: plan.selector,
            benchtime: plan.benchtime,
            count: plan.goCount,
            instrumentation: [],
            sourceHash: sourceHash
        ).filling(from: parsed)
        if fingerprint.package == nil { fingerprint.package = plan.targets.package }
        return fingerprint
    }

    func runReply(callID: String, toolName: String, stored: StoredRun, snapshotID: String, extraFields: [String: Any] = [:]) async -> ToolResultEnvelope {
        let record = stored.record
        var fields = runSummaryFields(stored).merging(extraFields) { _, new in new }
        var truncated = record.outputTruncated
        if stored.kind == .benchmark, let run = stored.benchmark {
            fields["fingerprint"] = JSONText.object(from: run.fingerprint)
            fields["parsedSampleCount"] = run.samples.count
            fields["ignoredOutputLines"] = stored.ignoredBenchmarkLines
            let items = benchmarkSummaries(stored)
            let shown = ItemFit.shownCount(base: fields, key: "benchmarks", items: items, budget: ToolLimits.resultBytes / 2)
            fields["benchmarks"] = Array(items.prefix(shown))
            if shown < items.count {
                fields["omittedBenchmarks"] = items.count - shown
                truncated = true
            }
            if run.samples.isEmpty { fields["warning"] = "No benchmark samples were parsed from the output, so there is nothing to compare." }
        }

        var budget = 4096
        var withTail = fields
        var omitted = 0
        while true {
            let tail = JSONText.tail(stored.output, maxBytes: budget)
            omitted = tail.omittedBytes
            withTail = fields
            withTail["outputTail"] = tail.text
            withTail["outputOmittedBytes"] = omitted
            if JSONText.size(withTail) <= ToolLimits.resultBytes - ToolLimits.envelopeReserve || budget <= 128 { break }
            budget /= 2
        }
        if omitted > 0 { truncated = true }

        let label = runStatusLabel(record)
        var code: ToolErrorCode?
        var retryable = false
        switch record.status {
        case .passed, .failed: code = label == "unknown" ? .unavailable : nil
        case .cancelled: code = .cancelled
        case .timedOut:
            code = .timeout
            retryable = true
        case .unknown: code = .unavailable
        }
        return await found(callID: callID, toolName: toolName, kind: stored.kind == .test ? .run : .benchmark, snapshotID: snapshotID, fields: withTail, truncated: truncated, nextCursor: omitted > 0 ? "0" : nil, code: code, retryable: retryable, outcome: label)
    }

    func busyReply(callID: String, info: BusyInfo, snapshotID: String) -> ToolResultEnvelope {
        let owner = ownerLabel(info.owner)
        let who = info.owner == .user ? "the user" : owner
        return envelope(callID: callID, outcome: "busy", code: .busy, retryable: true, snapshotID: snapshotID, fields: [
            "activeRunID": info.runID.uuidString,
            "activeOwner": owner,
            "activeRunIsExternal": info.isExternal,
            "message": "A run owned by \(who) is already active. It was not stopped and was not replaced. Wait for it to finish, then try again, or continue with read-only tools."
        ])
    }

    func denied(callID: String, message: String, snapshotID: String) -> ToolResultEnvelope {
        envelope(callID: callID, outcome: "denied", code: .denied, retryable: false, snapshotID: snapshotID, fields: [
            "message": message + " Nothing was run. " + Self.readOnlyAdvice
        ])
    }

    func cancelledReply(callID: String, snapshotID: String, message: String) -> ToolResultEnvelope {
        envelope(callID: callID, outcome: "cancelled", code: .cancelled, retryable: false, snapshotID: snapshotID, fields: ["message": message])
    }
}

enum DirtyResolution {
    case proceed(runsSavedVersion: Bool, unsavedPaths: [String])
    case stop(message: String, saveFailed: Bool)
}

extension ExecutionKit {
    func resolveDirtyBuffers(_ provider: DirtyBufferProvider) async -> DirtyResolution {
        let states = await provider.bufferStates()
        switch DirtyBufferPolicy.evaluate(buffers: states, decision: nil) {
        case .proceed:
            return .proceed(runsSavedVersion: false, unsavedPaths: [])
        case .cancelled, .saveThenRerunGate:
            return .stop(message: "Nothing was run.", saveFailed: false)
        case .needsDecision(let dirtyPaths):
            let decision = await provider.chooseAction(dirtyPaths: dirtyPaths)
            if Task.isCancelled { return .stop(message: "Cancelled at the unsaved-changes prompt. Nothing was run.", saveFailed: false) }
            switch DirtyBufferPolicy.evaluate(buffers: states, decision: decision) {
            case .proceed(let revision):
                return .proceed(runsSavedVersion: revision.runsSavedVersion, unsavedPaths: revision.dirtyPathsNotIncluded)
            case .cancelled:
                return .stop(message: "The user cancelled at the unsaved-changes prompt. Nothing was run.", saveFailed: false)
            case .needsDecision:
                return .stop(message: "No unsaved file was selected to save. Nothing was run.", saveFailed: false)
            case .saveThenRerunGate(let paths):
                guard await provider.save(paths: paths) else {
                    return .stop(message: "The selected files could not be saved, so nothing was run.", saveFailed: true)
                }
                let after = await provider.bufferStates()
                if case .proceed(let revision) = DirtyBufferPolicy.evaluate(buffers: after, decision: .runSavedVersion) {
                    return .proceed(runsSavedVersion: revision.runsSavedVersion, unsavedPaths: revision.dirtyPathsNotIncluded)
                }
                return .stop(message: "Nothing was run.", saveFailed: false)
            }
        }
    }
}

extension ExecutionKit {
    func makePlan(callID: String, kind: GoCommand.Kind, args: [String: JSONValue], snapshot: SourceSnapshot) async -> Step<RunPlan> {
        let key = kind == .test ? "targetIDs" : "benchmarkIDs"
        guard let ids = args[key]?.stringArray, !ids.isEmpty else {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "\(key) must list at least one ID from list_test_targets."))
        }
        let targets: RunTargets
        switch await resolveTargets(callID: callID, ids: ids, kind: kind) {
        case .reply(let reply): return .reply(reply)
        case .value(let value): targets = value
        }
        if let problem = PatchValidator.lexicalPathIssue(targets.moduleDirectory), !targets.moduleDirectory.isEmpty {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "The backend returned an unusable module directory: \(problem)."))
        }
        let timeout = args["timeoutSeconds"]?.intValue ?? (kind == .test ? 120 : 300)
        let goCount = kind == .benchmark ? (args["count"]?.intValue ?? 10) : 1
        let benchtime = kind == .benchmark ? args["benchtime"]?.stringValue : nil
        let toolchainTimeout = min(timeout + Self.toolchainTimeoutMargin, GoCommandBuilder.maxTimeoutSeconds)
        let command: GoCommand
        do {
            switch kind {
            case .test:
                command = try GoCommandBuilder.test(packages: [targets.package], tests: targets.names, count: 1, timeoutSeconds: toolchainTimeout, tags: snapshot.tags)
            case .benchmark:
                command = try GoCommandBuilder.benchmark(packages: [targets.package], benchmarks: targets.names, count: goCount, benchtime: benchtime, timeoutSeconds: toolchainTimeout, tags: snapshot.tags)
                try GoCommandBuilder.audit(argv: command.argv, timedComparison: true)
                let flags = (context.environment["GOFLAGS"] ?? "").split(separator: " ").map(String.init)
                try GoCommandBuilder.audit(argv: ["go", "test"] + flags, timedComparison: true)
            }
        } catch let error as GoCommandError {
            return .reply(failure(callID: callID, code: .invalidArguments, message: describe(error)))
        } catch {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "The command could not be built."))
        }
        var configParts: [String: String] = [
            "buildTarget": snapshot.buildTarget ?? "",
            "goVersion": snapshot.goVersion ?? "",
            "tags": snapshot.tags.sorted().joined(separator: ",")
        ]
        if kind == .benchmark {
            configParts["count"] = String(goCount)
            configParts["benchtime"] = benchtime ?? ""
        }
        let workingDirectory = targets.moduleDirectory.isEmpty ? context.workspaceRoot : context.workspaceRoot.appendingPathComponent(targets.moduleDirectory, isDirectory: true)
        return .value(RunPlan(
            kind: kind,
            targets: targets,
            command: command,
            timeoutSeconds: timeout,
            goCount: goCount,
            benchtime: benchtime,
            targetHash: ContentHash.combined(configParts),
            selector: PermissionPolicy.canonicalSelector(package: targets.package, tests: targets.namedSelection),
            workingDirectory: workingDirectory
        ))
    }

    func describe(_ error: GoCommandError) -> String {
        switch error {
        case .invalidPackageSelector(let value): return "\(JSONText.clip(value, 80)) is not a valid package selector."
        case .invalidTestName(let value): return "\(JSONText.clip(value, 80)) is not a valid Go test or benchmark name."
        case .invalidTag(let value): return "Build tag \(JSONText.clip(value, 40)) is not valid."
        case .invalidBenchtime(let value): return "benchtime \(JSONText.clip(value, 40)) is not a valid duration or Nx count."
        case .countOutOfRange(let value): return "count \(value) is out of range."
        case .timeoutOutOfRange(let value): return "timeoutSeconds \(value) is out of range."
        case .noTargets: return "No targets were selected."
        case .forbiddenArgument(let value): return "Argument \(JSONText.clip(value, 40)) is not allowed."
        case .notAGoTestCommand: return "Only go test commands can run."
        case .instrumentationOnTimedRun(let value): return "\(JSONText.clip(value, 40)) is not allowed on a timed benchmark run: -race, coverage, tracing and profiling flags distort timing. Profile in a separate, untimed run."
        }
    }

    func resolveTargets(callID: String, ids: [String], kind: GoCommand.Kind) async -> Step<RunTargets> {
        guard let backend = context.backends.testTargets else {
            return .reply(envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "No test target backend in this host."]))
        }
        var package: String?
        var named: [String] = []
        for id in ids {
            let parts = id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let idPackage = parts[0]
            if let package, package != idPackage {
                return .reply(failure(callID: callID, code: .invalidArguments, message: "All IDs in one run must belong to the same package; split the request into separate runs."))
            }
            package = idPackage
            if parts.count == 2 {
                if parts[1].isEmpty { return .reply(failure(callID: callID, code: .invalidArguments, message: "ID \(JSONText.clip(id, 80)) has an empty name.")) }
                if !named.contains(parts[1]) { named.append(parts[1]) }
            }
        }
        guard let package else {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "No IDs were given."))
        }
        do { try GoCommandBuilder.validatePackageSelector(package) } catch {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "\(JSONText.clip(package, 80)) is not a valid package selector."))
        }
        if kind == .test, !named.isEmpty, named.count != ids.count {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "Do not mix a package ID with named test IDs in one run."))
        }
        let wanted: TestTarget.Kind = kind == .test ? .test : .benchmark
        let available: [TestTarget]
        switch await backend.targets(in: package) {
        case .found(let list): available = list.filter { $0.kind == wanted }
        case .empty: available = []
        case .unavailable(let reason):
            return .reply(envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: nil, fields: ["reason": redact(JSONText.clip(reason, 200))]))
        case .timeout:
            return .reply(envelope(callID: callID, outcome: "timeout", code: .timeout, retryable: true, snapshotID: nil, fields: ["message": "The target backend did not answer in time."]))
        }
        let matched: [TestTarget]
        if named.isEmpty {
            matched = available
            if matched.isEmpty {
                return .reply(failure(callID: callID, code: .notFound, message: "No \(wanted.rawValue) targets exist in \(JSONText.clip(package, 80)). Use list_test_targets."))
            }
        } else {
            var found: [TestTarget] = []
            for name in named {
                guard let target = available.first(where: { $0.package == package && $0.name == name }) else {
                    return .reply(failure(callID: callID, code: .notFound, message: "\(JSONText.clip(package, 80))#\(JSONText.clip(name, 80)) is not a known \(wanted.rawValue) target. Use list_test_targets."))
                }
                found.append(target)
            }
            matched = found
        }
        let directories = Set(matched.map(\.moduleDirectory))
        guard directories.count == 1, let directory = directories.first else {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "The selection spans several modules; run each module separately."))
        }
        let names: [String]
        if kind == .test {
            names = named
        } else {
            var unique: [String] = []
            for target in matched where !unique.contains(target.name) { unique.append(target.name) }
            names = unique
        }
        return .value(RunTargets(package: package, moduleDirectory: directory, names: names, namedSelection: named))
    }

    func runGoCheck() -> ExecTool {
        makeTool(
            name: "run_go_check",
            description: "Compile-check Go code inside GoLens's Linux container: 'build' runs go build -o /dev/null <packageScope> (no binary is written), 'vet' runs go vet <packageScope>. The command runs in the module that contains packageScope (the nearest go.mod), so pass a path such as ./internal/api/... or ./core/.... It uses the files saved on disk, needs user approval unless the user chose Auto, and never changes go.mod. Use it after editing Go files.",
            parameters: ToolSchemas.object(properties: [
                #""check":{"type":"string","enum":["build","vet"]}"#,
                #""packageScope":{"type":"string","minLength":1,"maxLength":256}"#,
                #""timeoutSeconds":{"type":"integer","minimum":1,"maximum":300}"#
            ], required: ["check"])
        ) { callID, args in
            guard context.backends.canRun,
                  let approvals = context.backends.approvals,
                  let dirty = context.backends.dirtyBuffers,
                  let fingerprints = context.backends.fingerprints else {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "Running Go toolchain checks is not available in this host."])
            }
            guard let check = args["check"]?.stringValue, check == "build" || check == "vet" else {
                return failure(callID: callID, code: .invalidArguments, message: "check must be 'build' or 'vet'. go mod tidy is not available to the model because it rewrites go.mod and needs the network; ask the user to run it.")
            }
            let requestedScope = args["packageScope"]?.stringValue ?? "./..."
            do { try GoCommandBuilder.validatePackageSelector(requestedScope) } catch {
                return failure(callID: callID, code: .invalidArguments, message: "\(JSONText.clip(requestedScope, 80)) is not a valid Go package selector.")
            }
            let moduleDirectory: String
            let scope: String
            switch GoModuleLocator.resolve(scope: requestedScope, root: context.workspaceRoot) {
            case .resolved(let directory, let resolvedScope):
                moduleDirectory = directory
                scope = resolvedScope
            case .ambiguous(let directories):
                let listed = directories.prefix(8).map { "./\($0)/..." }.joined(separator: ", ")
                return failure(callID: callID, code: .invalidArguments, message: "\(JSONText.clip(requestedScope, 80)) spans several Go modules. Run the check once per module with a packageScope inside it, for example \(listed).", fields: ["modules": Array(directories.prefix(8))])
            case .noModule:
                return failure(callID: callID, code: .notFound, message: "No go.mod was found for \(JSONText.clip(requestedScope, 80)), so Go cannot build it. Pass a packageScope inside a Go module.")
            }
            if !moduleDirectory.isEmpty, let problem = PatchValidator.lexicalPathIssue(moduleDirectory) {
                return failure(callID: callID, code: .invalidArguments, message: "The module directory is not usable: \(problem).")
            }
            let argv: [String] = check == "build" ? ["go", "build", "-o", "/dev/null", scope] : ["go", "vet", scope]
            let timeout = args["timeoutSeconds"]?.intValue ?? 120
            let workingDirectory = moduleDirectory.isEmpty ? context.workspaceRoot : context.workspaceRoot.appendingPathComponent(moduleDirectory, isDirectory: true)
            let snapshot = await context.snapshot()
            if let active = await context.arbiter.activeRun() {
                return busyReply(callID: callID, info: active, snapshotID: snapshot.id)
            }
            if Task.isCancelled {
                return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled before anything ran.")
            }

            let operation: PolicyOperation = .runGoCheck
            let selector = "go-\(check):\(moduleDirectory.isEmpty ? "." : moduleDirectory):\(scope)"
            let envNames = Set(context.environment.keys)
            let hashes = await fingerprints.diskHashes(moduleDirectory: moduleDirectory, package: scope)
            let sourceHash = ContentHash.combined(hashes)
            let targetHash = ContentHash.combined([
                "check": check,
                "scope": scope,
                "module": moduleDirectory,
                "buildTarget": snapshot.buildTarget ?? "",
                "goVersion": snapshot.goVersion ?? ""
            ])
            let request = PermissionRequest(
                workspaceID: context.workspaceID,
                operation: operation,
                selector: selector,
                targetConfigHash: targetHash,
                workspaceSnapshotHash: sourceHash,
                envNames: envNames,
                timeoutSeconds: timeout,
                runCount: 1
            )
            switch await context.grants.authorize(request) {
            case .allow:
                break
            case .deny(let reason):
                return denied(callID: callID, message: reason.message, snapshotID: snapshot.id)
            case .needsApproval(let policyCard):
                let card = ExecutionApprovalCard(
                    operation: operation,
                    selector: selector,
                    packageSelector: scope,
                    testNames: [],
                    benchmarkNames: [],
                    target: targetHash,
                    workingDirectory: workingDirectory.path,
                    argv: argv,
                    timeoutSeconds: timeout,
                    goCount: 1,
                    benchtime: nil,
                    runCount: 1,
                    envNames: envNames.sorted(),
                    outputLimitBytes: context.outputLimitBytes,
                    mismatches: policyCard.mismatches,
                    warning: policyCard.explanation,
                    sessionGrantMaxRuns: max(1, context.sessionGrantMaxRuns),
                    sessionGrantLifetime: context.sessionGrantLifetime
                )
                guard let decision = await ApprovalAwait.request(card, from: approvals) else {
                    return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled while waiting for approval. Nothing was run.")
                }
                if decision == .decline {
                    return denied(callID: callID, message: "The user declined to run this Go check.", snapshotID: snapshot.id)
                }
                let grant = ExecutionGrant(
                    workspaceID: context.workspaceID,
                    operation: operation,
                    selector: selector,
                    targetConfigHash: targetHash,
                    workspaceSnapshotHash: request.workspaceSnapshotHash,
                    envNames: envNames,
                    timeoutSeconds: timeout,
                    maxRuns: decision == .allowOnce ? 1 : max(1, context.sessionGrantMaxRuns),
                    expiresAt: Date().addingTimeInterval(decision == .allowOnce ? 300 : context.sessionGrantLifetime),
                    ownerActionID: callID
                )
                do { try await context.grants.add(grant) } catch {
                    return denied(callID: callID, message: "The approval could not be recorded.", snapshotID: snapshot.id)
                }
                guard case .allow = await context.grants.authorize(request) else {
                    return denied(callID: callID, message: "The approval did not cover this check.", snapshotID: snapshot.id)
                }
            }
            if Task.isCancelled {
                return cancelledReply(callID: callID, snapshotID: snapshot.id, message: "Cancelled before anything ran.")
            }

            var runsSavedVersion = false
            var unsavedPaths: [String] = []
            switch await resolveDirtyBuffers(dirty) {
            case .stop(let message, let saveFailed):
                if saveFailed {
                    return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: snapshot.id, fields: ["message": message])
                }
                return cancelledReply(callID: callID, snapshotID: snapshot.id, message: message)
            case .proceed(let saved, let paths):
                runsSavedVersion = saved
                unsavedPaths = paths
            }
            if let gate = await sandboxGate(callID: callID, snapshotID: snapshot.id) {
                return gate
            }

            let configHash = RunConfigHash.compute(argv: argv, environmentNames: envNames.sorted(), extra: ["target": targetHash])
            let spec = RunSpec(
                argv: argv,
                workspaceRoot: context.workspaceRoot,
                workingDirectory: workingDirectory,
                environment: context.environment,
                deadline: TimeInterval(timeout),
                outputLimitBytes: context.outputLimitBytes,
                sourceHash: sourceHash,
                configHash: configHash
            )
            let runID: UUID
            switch await context.arbiter.start(owner: .ai(actionID: callID), spec: spec) {
            case .busy(let info):
                return busyReply(callID: callID, info: info, snapshotID: snapshot.id)
            case .failedToLaunch(let reason):
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: snapshot.id, fields: ["message": "The process could not be started: \(redact(JSONText.clip(reason, 200)))"])
            case .sandboxUnavailable(let starting, let detail):
                return sandboxReply(callID: callID, snapshotID: snapshot.id, starting: starting, detail: detail)
            case .started(let id):
                runID = id
            }
            let arbiter = context.arbiter
            let finished = await withTaskCancellationHandler {
                await arbiter.awaitRecord(runID)
            } onCancel: {
                Task { _ = await arbiter.cancel(runID: runID, requester: .ai(actionID: callID)) }
            }
            guard let record = finished else {
                return failure(callID: callID, code: .unavailable, message: "The check finished without a record.", retryable: true)
            }
            let output = redact(await arbiter.output(for: runID) ?? "")
            let stored = StoredRun(
                record: record,
                kind: .test,
                packageSelector: scope,
                output: output,
                benchmark: nil,
                ignoredBenchmarkLines: 0,
                runsSavedVersion: runsSavedVersion,
                unsavedPaths: unsavedPaths,
                sourceFileCount: hashes.count
            )
            await context.runs.store(stored)
            return await runReply(callID: callID, toolName: "run_go_check", stored: stored, snapshotID: snapshot.id, extraFields: [
                "check": check,
                "moduleDirectory": moduleDirectory.isEmpty ? "." : moduleDirectory,
                "packageScope": scope
            ])
        }
    }

    func sandboxGate(callID: String, snapshotID: String) async -> ToolResultEnvelope? {
        guard let readiness = context.sandboxReadiness else { return nil }
        switch await readiness() {
        case .ready:
            return nil
        case .starting(let detail):
            return sandboxReply(callID: callID, snapshotID: snapshotID, starting: true, detail: detail)
        case .unavailable(let detail):
            return sandboxReply(callID: callID, snapshotID: snapshotID, starting: false, detail: detail)
        }
    }

    func sandboxReply(callID: String, snapshotID: String, starting: Bool, detail: String) -> ToolResultEnvelope {
        let reason = redact(JSONText.clip(detail, 200))
        let message = starting
            ? "The Linux container that runs Go commands is still starting, so nothing was run. Do not retry in this turn. Continue with read-only tools and tell the user they can ask again once the container is ready."
            : "The Linux container that runs Go commands is not available, so nothing was run (\(reason)). Do not retry. Tell the user to restart the Linux container, then ask again."
        return envelope(callID: callID, outcome: "containerUnavailable", code: .unavailable, retryable: false, snapshotID: snapshotID, fields: [
            "containerState": starting ? "starting" : "unavailable",
            "message": message
        ])
    }

    func todoWrite() -> ExecTool {
        makeTool(
            name: "todo_write",
            description: "Create or update a concise step-by-step task checklist for multi-step Agent tasks so the developer can see your plan and live progress in the Gopilot panel. Call this when starting a multi-step task and update item statuses ('pending', 'in_progress', 'completed') as you complete each step.",
            parameters: ToolSchemas.object(properties: [
                #""todos":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":64},"content":{"type":"string","minLength":1,"maxLength":240},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["id","content","status"],"additionalProperties":false}}"#
            ], required: ["todos"])
        ) { callID, args in
            guard case .array(let rawTodos)? = args["todos"], !rawTodos.isEmpty else {
                return failure(callID: callID, code: .invalidArguments, message: "todos must be a non-empty array of checklist items.")
            }
            var items: [[String: String]] = []
            var completedCount = 0
            var inProgressCount = 0
            for entry in rawTodos.prefix(12) {
                guard let obj = entry.objectValue,
                      let id = obj["id"]?.stringValue,
                      let content = obj["content"]?.stringValue,
                      let status = obj["status"]?.stringValue else {
                    return failure(callID: callID, code: .invalidArguments, message: "Each todo item requires id, content, and status ('pending', 'in_progress', or 'completed').")
                }
                if status == "completed" { completedCount += 1 }
                if status == "in_progress" { inProgressCount += 1 }
                items.append([
                    "id": JSONText.clip(id, 64),
                    "content": redact(JSONText.clip(content, 240)),
                    "status": status
                ])
            }
            let snapshot = await context.snapshot()
            let fields: [String: Any] = [
                "todos": items,
                "totalCount": items.count,
                "completedCount": completedCount,
                "inProgressCount": inProgressCount
            ]
            return await found(
                callID: callID,
                toolName: "todo_write",
                kind: .listing,
                snapshotID: snapshot.id,
                fields: fields,
                truncated: false,
                nextCursor: nil,
                outcome: "updated"
            )
        }
    }
}
