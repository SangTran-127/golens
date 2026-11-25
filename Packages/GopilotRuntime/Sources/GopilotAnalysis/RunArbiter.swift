import Foundation

public struct RunSpec: Sendable {
    public let argv: [String]
    public let workspaceRoot: URL
    public let workingDirectory: URL
    public let environment: [String: String]
    public let deadline: TimeInterval
    public let outputLimitBytes: Int
    public let sourceHash: String
    public let configHash: String

    public init(argv: [String], workspaceRoot: URL, workingDirectory: URL? = nil, environment: [String: String], deadline: TimeInterval, outputLimitBytes: Int = 1 << 20, sourceHash: String, configHash: String) {
        self.argv = argv
        self.workspaceRoot = workspaceRoot
        self.workingDirectory = workingDirectory ?? workspaceRoot
        self.environment = environment
        self.deadline = deadline
        self.outputLimitBytes = outputLimitBytes
        self.sourceHash = sourceHash
        self.configHash = configHash
    }
}

public struct BusyInfo: Sendable, Equatable {
    public let runID: UUID
    public let owner: RunOwner
    public let startedAt: Date
    public let isExternal: Bool
}

public enum RunStartOutcome: Sendable, Equatable {
    case started(runID: UUID)
    case busy(BusyInfo)
    case failedToLaunch(String)
    case sandboxUnavailable(starting: Bool, detail: String)
}

public enum RunCancelOutcome: Sendable, Equatable {
    case cancelling
    case refusedNotOwner(active: BusyInfo)
    case externalRunNotManaged
    case notActive
}

public actor RunArbiter {
    private struct Active {
        let info: BusyInfo
        let running: RunningProcess?
    }

    private let executor: ProcessRunExecutor
    private var active: Active?
    private var records: [UUID: RunRecord] = [:]
    private var monitors: [UUID: Task<RunRecord, Never>] = [:]
    private var outputs: [UUID: String] = [:]

    public init(executor: ProcessRunExecutor) {
        self.executor = executor
    }

    public func activeRun() -> BusyInfo? { active?.info }

    public func record(for runID: UUID) -> RunRecord? { records[runID] }

    public func start(owner: RunOwner, spec: RunSpec) -> RunStartOutcome {
        if let active { return .busy(active.info) }
        let request = ProcessRunRequest(
            argv: spec.argv,
            workspaceRoot: spec.workspaceRoot,
            workingDirectory: spec.workingDirectory,
            environment: spec.environment,
            deadline: spec.deadline,
            outputLimitBytes: spec.outputLimitBytes
        )
        let running: RunningProcess
        do {
            running = try executor.start(request)
        } catch ProcessRunError.sandboxUnavailable(let starting, let detail) {
            return .sandboxUnavailable(starting: starting, detail: detail)
        } catch {
            return .failedToLaunch(String(describing: error))
        }
        let runID = UUID()
        let info = BusyInfo(runID: runID, owner: owner, startedAt: Date(), isExternal: false)
        active = Active(info: info, running: running)
        let cwd = spec.workingDirectory.resolvingSymlinksInPath().path
        monitors[runID] = Task { [weak self] in
            let result = await running.wait()
            let record = RunRecord(
                runID: runID,
                owner: owner,
                argv: spec.argv,
                cwd: cwd,
                sourceHash: spec.sourceHash,
                configHash: spec.configHash,
                startedAt: result.startedAt,
                endedAt: result.endedAt,
                exitCode: result.exitCode,
                terminationSignal: result.terminationSignal,
                outcome: result.outcome,
                outputTruncated: result.outputTruncated
            )
            await self?.finish(record: record, output: result.output)
            return record
        }
        return .started(runID: runID)
    }

    public func output(for runID: UUID) -> String? { outputs[runID] }

    private func finish(record: RunRecord, output: String) {
        records[record.runID] = record
        outputs[record.runID] = output
        if active?.info.runID == record.runID { active = nil }
    }

    public func awaitRecord(_ runID: UUID) async -> RunRecord? {
        if let record = records[runID] { return record }
        guard let monitor = monitors[runID] else { return nil }
        return await monitor.value
    }

    public func waitUntilIdle(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while active != nil {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return active == nil }
        }
        return true
    }

    public func cancel(runID: UUID, requester: RunOwner) -> RunCancelOutcome {
        guard let active, active.info.runID == runID else { return .notActive }
        if case .ai = requester, requester != active.info.owner {
            return .refusedNotOwner(active: active.info)
        }
        guard let running = active.running else { return .externalRunNotManaged }
        running.cancel()
        return .cancelling
    }

    public func cancelRuns(ownedBy owner: RunOwner) -> [UUID] {
        guard let active, active.info.owner == owner, let running = active.running else { return [] }
        running.cancel()
        return [active.info.runID]
    }

    public func shutdown() async {
        guard let active, let running = active.running else { return }
        running.cancel()
        _ = await running.wait()
        _ = await monitors[active.info.runID]?.value
    }

    public func beginExternalRun(owner: RunOwner, runID: UUID = UUID()) -> RunStartOutcome {
        if let active { return .busy(active.info) }
        active = Active(info: BusyInfo(runID: runID, owner: owner, startedAt: Date(), isExternal: true), running: nil)
        return .started(runID: runID)
    }

    public func endExternalRun(runID: UUID) {
        if let active, active.info.isExternal, active.info.runID == runID { self.active = nil }
    }
}
