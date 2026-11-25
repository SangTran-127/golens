import Foundation
import GopilotAnalysis
import Darwin

public final class VsockMicroVMDriver: ProcessExecutionDriver, Sendable {
    public static let shared = VsockMicroVMDriver()

    public init() {}

    static var isTestTransport: Bool {
        guard let value = ProcessInfo.processInfo.environment["GOLENS_TEST_VSOCK_PATH"] else { return false }
        return !value.isEmpty
    }

    private static func currentStateIsStarting() -> Bool {
        let read: () -> Bool = {
            MainActor.assumeIsolated {
                switch SandboxVMManager.shared.state {
                case .starting, .restarting, .stopped, .paused: return true
                case .running, .failed: return false
                }
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    static func readiness(workspaceRoot: String, timeout: Duration = .seconds(45)) async -> SandboxReadiness {
        if isTestTransport { return .ready }
        if await MainActor.run(body: { SandboxVMManager.shared.executionMode == .host }) {
            return .ready
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var requestedStart = false
        var requestedMount = false
        var lastPhase = "The Linux container is starting."
        while true {
            let state = await MainActor.run { SandboxVMManager.shared.state }
            switch state {
            case .running:
                let mapped = await MainActor.run { SandboxVMManager.shared.hostToGuestPath(workspaceRoot) != workspaceRoot }
                if mapped { return .ready }
                if !requestedMount {
                    requestedMount = true
                    await MainActor.run { _ = SandboxVMManager.shared.mountWorkspaceSync(url: URL(fileURLWithPath: workspaceRoot)) }
                    continue
                }
                return .unavailable("The project folder is not shared with the Linux container.")
            case .failed(let description, let suggestion):
                return .unavailable([description, suggestion].filter { !$0.isEmpty }.joined(separator: " "))
            case .stopped, .paused:
                if !requestedStart {
                    requestedStart = true
                    SandboxVMManager.ensureStartedFromBackground()
                }
            case .starting(let phase):
                if !phase.isEmpty { lastPhase = phase }
            case .restarting:
                lastPhase = "The Linux container is restarting."
            }
            if clock.now >= deadline { return .starting(lastPhase) }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return .starting(lastPhase) }
        }
    }

    public func start(_ request: ProcessRunRequest, redactor: @escaping @Sendable (String) -> String) throws -> RunningProcess {
        if !Self.isTestTransport {
            let isHost: Bool = Thread.isMainThread
                ? MainActor.assumeIsolated { SandboxVMManager.shared.executionMode == .host }
                : DispatchQueue.main.sync {
                    MainActor.assumeIsolated { SandboxVMManager.shared.executionMode == .host }
                }
            if isHost {
                return try ProcessRunExecutor(redactor: redactor, driver: nil).start(request)
            }
        }
        let hostCwdPath = request.workingDirectory.path
        let guestCwd: String = Thread.isMainThread
            ? MainActor.assumeIsolated {
                SandboxVMManager.shared.hostToGuestPath(hostCwdPath)
            }
            : DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    SandboxVMManager.shared.hostToGuestPath(hostCwdPath)
                }
            }
        if !Self.isTestTransport, guestCwd == hostCwdPath {
            throw ProcessRunError.sandboxUnavailable(starting: false, detail: "The project folder is not shared with the Linux container.")
        }
        let fd = SandboxVMManager.shared.connectVsockSync(port: 2002, timeoutMs: 3000)
        if fd == -2 {
            let starting = Self.currentStateIsStarting()
            throw ProcessRunError.sandboxUnavailable(
                starting: starting,
                detail: starting ? "The Linux container is starting." : "The Linux container is not running."
            )
        }
        guard fd >= 0 else {
            throw ProcessRunError.spawnFailed(-1)
        }
        let envStrings = request.environment.keys.sorted().map { "\($0)=\(request.environment[$0] ?? "")" }

        var isReadOnly = true
        var isLoopbackOnly = true
        if case let .linuxMicroVM(ro, lo) = request.isolationProfile {
            isReadOnly = ro
            isLoopbackOnly = lo
        }

        let payloadDict: [String: Any] = [
            "argv": request.argv,
            "env": envStrings,
            "cwd": guestCwd,
            "read_only_workspace": isReadOnly,
            "loopback_only_network": isLoopbackOnly
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict, options: []) else {
            close(fd)
            throw ProcessRunError.spawnFailed(-2)
        }

        var flags: UInt16 = 0
        if isReadOnly { flags |= 0x0010 }
        if isLoopbackOnly { flags |= 0x0020 }

        var header = [UInt8](repeating: 0, count: 8)
        header[0] = 0x01
        header[1] = 0x01
        header[2] = UInt8((flags >> 8) & 0xff)
        header[3] = UInt8(flags & 0xff)
        let payloadLen = UInt32(payloadData.count)
        header[4] = UInt8((payloadLen >> 24) & 0xff)
        header[5] = UInt8((payloadLen >> 16) & 0xff)
        header[6] = UInt8((payloadLen >> 8) & 0xff)
        header[7] = UInt8(payloadLen & 0xff)

        var packet = Data(header)
        packet.append(payloadData)

        let writeSuccess = packet.withUnsafeBytes { rawPtr -> Bool in
            guard let baseAddress = rawPtr.baseAddress else { return false }
            var written = 0
            let total = packet.count
            while written < total {
                let n = write(fd, baseAddress + written, total - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }

        guard writeSuccess else {
            close(fd)
            throw ProcessRunError.spawnFailed(errno)
        }

        let controller = VsockProcessController(socketFd: fd, request: request, redactor: redactor)
        controller.begin()
        return RunningProcess(controller: controller)
    }
}

private final class VsockProcessController: ProcessController, @unchecked Sendable {
    let socketFd: Int32
    private let request: ProcessRunRequest
    private let redactor: @Sendable (String) -> String
    private let startedAt = Date()

    private let lock = NSLock()
    private var isDone = false
    private var outcome: ProcessRunResult.Outcome?
    private var exitCode: Int32?
    private var terminationSignal: Int32?
    private var outputData = Data()
    private var droppedBytes = 0
    private var waiters: [CheckedContinuation<ProcessRunResult, Never>] = []
    private var deadlineItem: DispatchWorkItem?
    private var cachedResult: ProcessRunResult?

    var processGroupID: Int32 { socketFd }

    init(socketFd: Int32, request: ProcessRunRequest, redactor: @escaping @Sendable (String) -> String) {
        self.socketFd = socketFd
        self.request = request
        self.redactor = redactor
    }

    func begin() {
        let item = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        lock.lock()
        deadlineItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + request.deadline, execute: item)

        Thread.detachNewThread { [weak self] in
            self?.readFrames()
        }
    }

    func cancel() {
        terminate(reason: .cancelled, signal: 15)
    }

    private func handleTimeout() {
        terminate(reason: .timedOut, signal: 15)
    }

    private func terminate(reason: ProcessRunResult.Outcome, signal: UInt32) {
        lock.lock()
        if isDone {
            lock.unlock()
            return
        }
        if outcome == nil {
            outcome = reason
            terminationSignal = Int32(signal)
        }
        lock.unlock()

        sendSignal(signal)
        DispatchQueue.global().asyncAfter(deadline: .now() + request.terminationGrace) { [weak self] in
            self?.sendSignal(9)
            self?.forceClose()
        }
    }

    private func sendSignal(_ sig: UInt32) {
        var frame = [UInt8](repeating: 0, count: 12)
        frame[0] = 0x01
        frame[1] = 0x07
        frame[2] = 0
        frame[3] = 0
        frame[4] = 0
        frame[5] = 0
        frame[6] = 0
        frame[7] = 4
        frame[8] = UInt8((sig >> 24) & 0xff)
        frame[9] = UInt8((sig >> 16) & 0xff)
        frame[10] = UInt8((sig >> 8) & 0xff)
        frame[11] = UInt8(sig & 0xff)

        _ = frame.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            _ = write(socketFd, base, frame.count)
        }
    }

    private func forceClose() {
        lock.lock()
        let done = isDone
        lock.unlock()
        if !done {
            close(socketFd)
            finish(status: nil)
        }
    }

    private func readFrames() {
        var headerBuf = [UInt8](repeating: 0, count: 8)
        while true {
            guard readFull(socketFd, buffer: &headerBuf, count: 8) else {
                break
            }
            let version = headerBuf[0]
            guard version == 0x01 else { break }
            let frameType = headerBuf[1]
            let payloadLen = (UInt32(headerBuf[4]) << 24) |
                             (UInt32(headerBuf[5]) << 16) |
                             (UInt32(headerBuf[6]) << 8) |
                             UInt32(headerBuf[7])

            var payload = [UInt8](repeating: 0, count: Int(payloadLen))
            if payloadLen > 0 {
                guard readFull(socketFd, buffer: &payload, count: Int(payloadLen)) else {
                    break
                }
            }

            switch frameType {
            case 0x04, 0x05:
                appendOutput(payload)
            case 0x06:
                var code: Int32 = 0
                if payloadLen >= 4 {
                    let ucode = (UInt32(payload[0]) << 24) |
                                (UInt32(payload[1]) << 16) |
                                (UInt32(payload[2]) << 8) |
                                UInt32(payload[3])
                    code = Int32(bitPattern: ucode)
                }
                if payloadLen > 4 {
                    let msgBytes = Array(payload[4...])
                    appendOutput(msgBytes)
                }
                close(socketFd)
                finish(status: code)
                return
            case 0x09:
                appendOutput(payload)
                close(socketFd)
                finish(status: 1)
                return
            default:
                break
            }
        }

        close(socketFd)
        finish(status: nil)
    }

    private func readFull(_ fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var totalRead = 0
        while totalRead < count {
            let n = buffer.withUnsafeMutableBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                return read(fd, base + totalRead, count - totalRead)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            totalRead += n
        }
        return true
    }

    private func appendOutput(_ chunk: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let limit = request.outputLimitBytes
        if outputData.count + chunk.count <= limit {
            outputData.append(contentsOf: chunk)
        } else {
            let remaining = limit - outputData.count
            if remaining > 0 {
                outputData.append(contentsOf: chunk.prefix(remaining))
            }
            droppedBytes += (chunk.count - remaining)
        }
    }

    private func finish(status: Int32?) {
        lock.lock()
        if isDone {
            lock.unlock()
            return
        }
        isDone = true
        self.exitCode = status
        deadlineItem?.cancel()
        deadlineItem = nil

        let finalOutcome = outcome ?? .exited
        var combinedText = String(decoding: outputData, as: UTF8.self)
        if droppedBytes > 0 {
            combinedText += "\n[... \(droppedBytes) bytes omitted ...]\n"
        }
        let redacted = redactor(combinedText)

        let result = ProcessRunResult(
            outcome: finalOutcome,
            exitCode: status,
            terminationSignal: terminationSignal,
            output: redacted,
            outputTruncated: droppedBytes > 0,
            startedAt: startedAt,
            endedAt: Date(),
            processGroupID: socketFd
        )
        self.cachedResult = result
        let pending = waiters
        waiters = []
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isDone {
                if let cached = cachedResult {
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                let finalOutcome = outcome ?? .exited
                var combinedText = String(decoding: outputData, as: UTF8.self)
                if droppedBytes > 0 {
                    combinedText += "\n[... \(droppedBytes) bytes omitted ...]\n"
                }
                let redacted = redactor(combinedText)
                let result = ProcessRunResult(
                    outcome: finalOutcome,
                    exitCode: exitCode,
                    terminationSignal: terminationSignal,
                    output: redacted,
                    outputTruncated: droppedBytes > 0,
                    startedAt: startedAt,
                    endedAt: Date(),
                    processGroupID: socketFd
                )
                cachedResult = result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
