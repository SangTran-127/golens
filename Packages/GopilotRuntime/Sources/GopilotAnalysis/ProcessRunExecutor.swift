import Foundation

public enum ProcessRunError: Error, Sendable, Equatable {
    case emptyArgv
    case workingDirectoryOutsideWorkspace(String)
    case executableNotFound(String)
    case pipeFailed(Int32)
    case spawnFailed(Int32)
    case sandboxUnavailable(starting: Bool, detail: String)
}

public enum SandboxReadiness: Sendable, Equatable {
    case ready
    case starting(String)
    case unavailable(String)
}

public struct EnvironmentAllowlist: Sendable, Equatable {
    public let names: Set<String>

    public init(names: Set<String>) {
        self.names = names
    }

    public static let goToolchain = EnvironmentAllowlist(names: [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "GOCACHE", "GOMODCACHE", "GOPATH", "GOROOT", "GOFLAGS",
        "GOPROXY", "GONOSUMDB", "GONOSUMCHECK", "GOSUMDB", "GOTOOLCHAIN", "GOOS", "GOARCH", "CGO_ENABLED", "GOMAXPROCS"
    ])

    public func apply(to source: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for name in names {
            guard let value = source[name], !Self.looksSecret(name: name, value: value) else { continue }
            out[name] = value
        }
        return out
    }

    public static func looksSecret(name: String, value: String) -> Bool {
        let upper = name.uppercased()
        for marker in ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "COOKIE", "SESSION"] where upper.contains(marker) {
            return true
        }
        return value.range(of: #"://[^/@\s]+@"#, options: .regularExpression) != nil
    }
}

public struct LiteralRedactor: Sendable {
    private let secrets: [String]
    private let replacement: String

    public init(secrets: [String], replacement: String = "[REDACTED]") {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        self.replacement = replacement
    }

    public func redact(_ text: String) -> String {
        var out = text
        for secret in secrets { out = out.replacingOccurrences(of: secret, with: replacement) }
        return out
    }
}

public enum SandboxIsolationProfile: Sendable, Equatable {
    case hostProcessGroup
    case linuxMicroVM(workspaceReadOnly: Bool = true, loopbackOnlyNetwork: Bool = true)
}

public struct ProcessRunRequest: Sendable {
    public let argv: [String]
    public let workspaceRoot: URL
    public let workingDirectory: URL
    public let environment: [String: String]
    public let deadline: TimeInterval
    public let outputLimitBytes: Int
    public let terminationGrace: TimeInterval
    public let isolationProfile: SandboxIsolationProfile

    public init(
        argv: [String],
        workspaceRoot: URL,
        workingDirectory: URL? = nil,
        environment: [String: String],
        deadline: TimeInterval,
        outputLimitBytes: Int = 1 << 20,
        terminationGrace: TimeInterval = 2,
        isolationProfile: SandboxIsolationProfile = .linuxMicroVM(workspaceReadOnly: true, loopbackOnlyNetwork: true)
    ) {
        self.argv = argv
        self.workspaceRoot = workspaceRoot
        self.workingDirectory = workingDirectory ?? workspaceRoot
        self.environment = environment
        self.deadline = deadline
        self.outputLimitBytes = max(256, outputLimitBytes)
        self.terminationGrace = max(0.05, terminationGrace)
        self.isolationProfile = isolationProfile
    }
}

public struct ProcessRunResult: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        case exited
        case cancelled
        case timedOut
        case abandoned
    }

    public let outcome: Outcome
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let output: String
    public let outputTruncated: Bool
    public let startedAt: Date
    public let endedAt: Date
    public let processGroupID: Int32

    public init(
        outcome: Outcome,
        exitCode: Int32?,
        terminationSignal: Int32?,
        output: String,
        outputTruncated: Bool,
        startedAt: Date,
        endedAt: Date,
        processGroupID: Int32
    ) {
        self.outcome = outcome
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.output = output
        self.outputTruncated = outputTruncated
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.processGroupID = processGroupID
    }
}

public protocol ProcessController: Sendable {
    var processGroupID: Int32 { get }
    func cancel()
    func wait() async -> ProcessRunResult
}

public protocol ProcessExecutionDriver: Sendable {
    func start(_ request: ProcessRunRequest, redactor: @escaping @Sendable (String) -> String) throws -> RunningProcess
}

public final class ProcessRunExecutor: Sendable {
    private let redactor: @Sendable (String) -> String
    private let driver: (any ProcessExecutionDriver)?

    public init(
        redactor: @escaping @Sendable (String) -> String = { $0 },
        driver: (any ProcessExecutionDriver)? = nil
    ) {
        self.redactor = redactor
        self.driver = driver
    }

    public func start(_ request: ProcessRunRequest) throws -> RunningProcess {
        switch request.isolationProfile {
        case .linuxMicroVM:
            var effectiveEnvironment = request.environment
            if effectiveEnvironment["CGO_ENABLED"] == nil {
                effectiveEnvironment["CGO_ENABLED"] = "0"
            }
            let effectiveRequest = ProcessRunRequest(
                argv: request.argv,
                workspaceRoot: request.workspaceRoot,
                workingDirectory: request.workingDirectory,
                environment: effectiveEnvironment,
                deadline: request.deadline,
                outputLimitBytes: request.outputLimitBytes,
                terminationGrace: request.terminationGrace,
                isolationProfile: request.isolationProfile
            )
            if let driver {
                return try driver.start(effectiveRequest, redactor: redactor)
            }
            return try startHostProcess(effectiveRequest)
        case .hostProcessGroup:
            return try startHostProcess(request)
        }
    }

    private func startHostProcess(_ request: ProcessRunRequest) throws -> RunningProcess {
        guard let program = request.argv.first, !program.isEmpty else { throw ProcessRunError.emptyArgv }
        let cwd = try Self.canonicalWorkingDirectory(root: request.workspaceRoot, directory: request.workingDirectory)
        guard let executable = Self.resolveExecutable(program, path: request.environment["PATH"]) else {
            throw ProcessRunError.executableNotFound(program)
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunError.pipeFailed(errno) }
        let readFd = fds[0]
        let writeFd = fds[1]
        _ = fcntl(readFd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFd, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var argvPointers: [UnsafeMutablePointer<CChar>?] = request.argv.map { strdup($0) }
        argvPointers.append(nil)
        var envPointers: [UnsafeMutablePointer<CChar>?] = request.environment.keys.sorted().map { strdup("\($0)=\(request.environment[$0] ?? "")") }
        envPointers.append(nil)
        defer {
            for pointer in argvPointers { free(pointer) }
            for pointer in envPointers { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, argvPointers, envPointers)
        close(writeFd)
        guard spawnStatus == 0 else {
            close(readFd)
            throw ProcessRunError.spawnFailed(spawnStatus)
        }

        let state = ProcessState(pid: pid, readFd: readFd, request: request, redactor: redactor)
        state.begin()
        return RunningProcess(state: state)
    }

    public func run(_ request: ProcessRunRequest) async throws -> ProcessRunResult {
        let running = try start(request)
        return await withTaskCancellationHandler {
            await running.wait()
        } onCancel: {
            running.cancel()
        }
    }

    static func canonicalWorkingDirectory(root: URL, directory: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let dirPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard dirPath == rootPath || dirPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw ProcessRunError.workingDirectoryOutsideWorkspace(dirPath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessRunError.workingDirectoryOutsideWorkspace(dirPath)
        }
        return dirPath
    }

    static func resolveExecutable(_ program: String, path: String?) -> String? {
        if program.contains("/") {
            return access(program, X_OK) == 0 ? program : nil
        }
        for directory in (path ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(program)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }
}

public final class RunningProcess: Sendable {
    private let controller: any ProcessController

    public init(controller: any ProcessController) {
        self.controller = controller
    }

    fileprivate init(state: ProcessState) {
        self.controller = StateProcessController(state: state)
    }

    public var processGroupID: Int32 { controller.processGroupID }

    public func cancel() {
        controller.cancel()
    }

    public func wait() async -> ProcessRunResult {
        await controller.wait()
    }

    deinit {
        controller.cancel()
    }
}

private final class StateProcessController: ProcessController {
    let state: ProcessState

    init(state: ProcessState) {
        self.state = state
    }

    var processGroupID: Int32 { state.pgid }

    func cancel() {
        state.terminate(reason: .cancelled)
    }

    func wait() async -> ProcessRunResult {
        await state.result()
    }
}

private final class ProcessState: @unchecked Sendable {
    let pid: pid_t
    let pgid: pid_t
    private let readFd: Int32
    private let request: ProcessRunRequest
    private let redactor: @Sendable (String) -> String
    private let startedAt = Date()

    private let lock = NSLock()
    private var exited = false
    private var reason: ProcessRunResult.Outcome?
    private var termSent = false
    private var finished: ProcessRunResult?
    private var waiters: [CheckedContinuation<ProcessRunResult, Never>] = []
    private var deadlineItem: DispatchWorkItem?
    private var stopReading = false

    private var head = Data()
    private var tail = Data()
    private var dropped = 0
    private let headCap: Int
    private let tailCap: Int
    private let readerDone = DispatchSemaphore(value: 0)

    init(pid: pid_t, readFd: Int32, request: ProcessRunRequest, redactor: @escaping @Sendable (String) -> String) {
        self.pid = pid
        self.pgid = pid
        self.readFd = readFd
        self.request = request
        self.redactor = redactor
        self.headCap = request.outputLimitBytes / 2
        self.tailCap = request.outputLimitBytes - request.outputLimitBytes / 2
    }

    func begin() {
        let item = DispatchWorkItem { [weak self] in self?.terminate(reason: .timedOut) }
        lock.lock()
        deadlineItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + request.deadline, execute: item)
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in waitLoop() }
    }

    func result() async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(returning: finished)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func terminate(reason newReason: ProcessRunResult.Outcome) {
        lock.lock()
        if exited || finished != nil {
            lock.unlock()
            return
        }
        if reason == nil { reason = newReason }
        let alreadySent = termSent
        termSent = true
        lock.unlock()
        if alreadySent { return }
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + request.terminationGrace) { [self] in forceKillIfAlive() }
    }

    private func forceKillIfAlive() {
        lock.lock()
        let done = finished != nil
        lock.unlock()
        if !done { signalGroup(SIGKILL) }
    }

    private func groupAlive() -> Bool {
        guard ownsGroup else { return false }
        return kill(-pgid, 0) == 0
    }

    private var ownsGroup: Bool {
        pgid > 1 && pgid != getpgrp() && pgid == pid
    }

    private func signalGroup(_ signal: Int32) {
        guard ownsGroup else { return }
        _ = killpg(pgid, signal)
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var descriptor = pollfd(fd: readFd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                lock.lock()
                let stop = stopReading
                lock.unlock()
                if stop { break }
                continue
            }
            let count = read(readFd, &buffer, buffer.count)
            if count > 0 {
                ingest(Data(buffer[0..<count]))
            } else if count == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        close(readFd)
        readerDone.signal()
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        var rest = chunk
        if head.count < headCap {
            let take = min(headCap - head.count, rest.count)
            head.append(rest.prefix(take))
            rest = rest.dropFirst(take)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        if tail.count > tailCap * 2 {
            let excess = tail.count - tailCap
            dropped += excess
            tail = Data(tail.suffix(tailCap))
        }
    }

    private func waitLoop() {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { break }
            if result < 0 && errno == EINTR { continue }
            break
        }
        lock.lock()
        exited = true
        deadlineItem?.cancel()
        deadlineItem = nil
        lock.unlock()

        cleanupGroup()

        lock.lock()
        stopReading = true
        lock.unlock()
        readerDone.wait()
        finish(status: status)
    }

    private func cleanupGroup() {
        guard groupAlive() else { return }
        signalGroup(SIGTERM)
        let deadline = Date().addingTimeInterval(request.terminationGrace)
        while groupAlive() && Date() < deadline { usleep(20_000) }
        if groupAlive() { signalGroup(SIGKILL) }
        let hardDeadline = Date().addingTimeInterval(2)
        while groupAlive() && Date() < hardDeadline { usleep(20_000) }
    }

    private func finish(status: Int32) {
        lock.lock()
        if tail.count > tailCap {
            dropped += tail.count - tailCap
            tail = Data(tail.suffix(tailCap))
        }
        var combined = head
        if dropped > 0 {
            combined.append(Data("\n[... \(dropped) bytes omitted ...]\n".utf8))
        }
        combined.append(tail)
        let truncated = dropped > 0
        let requestedReason = reason
        lock.unlock()

        let isExit = (status & 0x7f) == 0
        let isSignal = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        let exitCode: Int32? = isExit ? (status >> 8) & 0xff : nil
        let signal: Int32? = isSignal ? status & 0x7f : nil
        let outcome: ProcessRunResult.Outcome = requestedReason ?? .exited
        let text = redactor(String(decoding: combined, as: UTF8.self))
        let result = ProcessRunResult(
            outcome: outcome,
            exitCode: exitCode,
            terminationSignal: signal,
            output: text,
            outputTruncated: truncated,
            startedAt: startedAt,
            endedAt: Date(),
            processGroupID: pgid
        )
        lock.lock()
        finished = result
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: result) }
    }
}
