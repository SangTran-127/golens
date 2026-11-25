import Foundation
import SwiftUI
import Observation
import Virtualization
import CryptoKit
import Darwin

#if !arch(arm64)
#error("GoLens requires Apple Silicon (arm64). Intel x86_64 architecture is not supported.")
#endif

public struct MountedWorkspace: Sendable, Equatable {
    public let slug: String
    public let hostURL: URL
    public let guestPath: String

    public init(slug: String, hostURL: URL, guestPath: String) {
        self.slug = slug
        self.hostURL = hostURL
        self.guestPath = guestPath
    }
}

private final class AtomicSocketDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var device: VZVirtioSocketDevice?
    private var queue: DispatchQueue?
    private var isRunning: Bool = false

    private final class DialSession: @unchecked Sendable {
        let lock = NSLock()
        var timedOut: Bool = false
        var duplicatedFd: Int32 = -1
    }

    private var isUnavailable: Bool = false

    func set(device: VZVirtioSocketDevice?, queue: DispatchQueue? = nil, running: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.device = device
        if let queue {
            self.queue = queue
        }
        self.isRunning = running
        if running {
            self.isUnavailable = false
        }
    }

    func markUnavailable() {
        lock.lock()
        defer { lock.unlock() }
        device = nil
        isRunning = false
        isUnavailable = true
    }

    func markRecovering() {
        lock.lock()
        defer { lock.unlock() }
        isUnavailable = false
    }

    func connectSync(port: UInt32, timeoutMs: UInt32) -> Int32 {
        if let testPath = getenv("GOLENS_TEST_VSOCK_PATH"), let path = String(utf8String: testPath), !path.isEmpty {
            return Self.connectUnixSocket(path: "\(path)/vsock_\(port).sock")
        }

        let effectiveTimeoutMs = max(Int(timeoutMs), 50)
        let deadline = Date().addingTimeInterval(Double(effectiveTimeoutMs) / 1000.0)

        lock.lock()
        var currentDevice = self.device
        var currentQueue = self.queue
        var running = self.isRunning
        var unavailable = self.isUnavailable
        lock.unlock()

        if unavailable {
            return -2
        }

        if !running || currentDevice == nil || currentQueue == nil {
            SandboxVMManager.ensureStartedFromBackground()
            while Date() < deadline {
                usleep(25_000)
                lock.lock()
                currentDevice = self.device
                currentQueue = self.queue
                running = self.isRunning
                unavailable = self.isUnavailable
                lock.unlock()
                if unavailable {
                    return -2
                }
                if running, currentDevice != nil, currentQueue != nil {
                    break
                }
            }
        }

        guard running, let activeDevice = currentDevice, let activeQueue = currentQueue else {
            return -2
        }

        while Date() < deadline {
            let session = DialSession()
            let sema = DispatchSemaphore(value: 0)

            activeQueue.async {
                activeDevice.connect(toPort: port) { result in
                    session.lock.lock()
                    defer {
                        session.lock.unlock()
                        sema.signal()
                    }
                    if session.timedOut {
                        return
                    }
                    switch result {
                    case .success(let connection):
                        session.duplicatedFd = dup(connection.fileDescriptor)
                    case .failure:
                        session.duplicatedFd = -1
                    }
                }
            }

            let remainingMs = max(100, Int(deadline.timeIntervalSinceNow * 1000.0))
            let attemptTimeout = DispatchTime.now() + .milliseconds(min(remainingMs, 1000))
            if sema.wait(timeout: attemptTimeout) == .timedOut {
                session.lock.lock()
                session.timedOut = true
                let lateFd = session.duplicatedFd
                session.duplicatedFd = -1
                session.lock.unlock()
                if lateFd >= 0 {
                    close(lateFd)
                }
            } else {
                session.lock.lock()
                let fd = session.duplicatedFd
                session.lock.unlock()
                if fd >= 0 {
                    return fd
                }
            }

            if Date() < deadline {
                usleep(40_000)
            }
        }

        return -1
    }

    private static func connectUnixSocket(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBytes { b in
                raw.copyMemory(from: b.baseAddress!, byteCount: b.count)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, len)
            }
        }
        if res < 0 {
            close(fd)
            return -2
        }
        return fd
    }
}

@MainActor
@Observable
public final class SandboxVMManager: NSObject, @unchecked Sendable {
    public static let shared = SandboxVMManager()

    public enum ExecutionMode: String, CaseIterable, Sendable {
        case host = "host"
        case linuxVM = "vm"
    }

    public static let executionModeKey = "GoLensExecutionMode"
    nonisolated(unsafe) public private(set) static var activeMode: ExecutionMode = .host

    public enum VMState: Equatable, Sendable {
        case stopped
        case starting(phase: String)
        case running(kernelVersion: String, arch: String, bootTime: Date)
        case paused(idleSince: Date)
        case restarting
        case failed(errorDescription: String, recoverySuggestion: String)
    }

    public enum InactivePauseInterval: Int, CaseIterable, Identifiable, Sendable {
        case after5Minutes = 300
        case after10Minutes = 600
        case after30Minutes = 1800
        case never = 0

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .after5Minutes: return "After 5 Minutes"
            case .after10Minutes: return "After 10 Minutes"
            case .after30Minutes: return "After 30 Minutes"
            case .never: return "Never"
            }
        }
    }

    public enum NetworkMode: String, CaseIterable, Identifiable, Sendable {
        case loopbackOnly = "loopback"
        case allowOutbound = "outbound"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .loopbackOnly: return "Loopback Only (127.0.0.1)"
            case .allowOutbound: return "Allow Outbound Network"
            }
        }
    }

    public var executionMode: ExecutionMode = .host
    public var state: VMState = .stopped
    public var cpuCores: Int = min(ProcessInfo.processInfo.activeProcessorCount, 2)
    public static let defaultMemoryLimitMB = 2048
    public static let baseMemoryMB = 512
    static let guestXDGCacheDirectoryName = "golens-xdg"
    static let goplsCacheDirectoryName = "gopls"
    public static let minimumMemoryLimitMB = 512
    public var memoryLimitMB: Int = SandboxVMManager.defaultMemoryLimitMB
    public var isRosettaEnabled: Bool = true
    public var pauseWhenInactive: InactivePauseInterval = .after5Minutes
    public var fastResumeEnabled: Bool = true
    public var networkMode: NetworkMode = .loopbackOnly
    public var forwardListeningPorts: Bool = true

    public var pendingRestart: Bool = false
    public var buildCacheSizeBytes: Int64 = 0
    public var moduleCacheSizeBytes: Int64 = 0

    public var linuxGoVersion: String?
    @ObservationIgnored private var linuxKernelVersion: String?
    public var mountedWorkspaces: [String: MountedWorkspace] = [:]

    @ObservationIgnored private var virtualMachine: VZVirtualMachine?
    @ObservationIgnored private var socketDevice: VZVirtioSocketDevice?
    @ObservationIgnored private var memoryBalloonDevice: VZVirtioTraditionalMemoryBalloonDevice?
    @ObservationIgnored private var bootedMemoryBytes: UInt64 = 0
    @ObservationIgnored private var guestMemoryTargetBytes: UInt64 = 0
    private static let guestMemoryIdleSeconds: TimeInterval = 60
    private static let guestMemoryStepInterval: UInt64 = 2_000_000_000
    @ObservationIgnored private var inactivityTimerTask: Task<Void, Never>?
    @ObservationIgnored private var guestMemoryStepTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivityTime: Date = Date()
    @ObservationIgnored private var activeOperationsCount: Int = 0
    @ObservationIgnored private var recycledWhileIdle = false
    @ObservationIgnored private let vmQueue = DispatchQueue(label: "dev.golens.microvm", qos: .userInitiated)
    @ObservationIgnored private let atomicSocket = AtomicSocketDevice()
    @ObservationIgnored private var syncedWorkspaceSlugs: Set<String> = []
    nonisolated private let portForwarder = PortForwardManager()

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private override init() {
        super.init()
        portForwarder.dialer = { [weak self] port in
            self?.connectVsockSync(port: port) ?? -1
        }
        loadPreferences()
        premountSavedWorkspace()
        refreshLinuxGoVersion()
        refreshLinuxKernelVersion()
        startInactivityMonitor()
        startGuestMemoryStepper()
        registerVsockDialer()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recordActivity()
            }
        }
        let shouldAutoBootVM: Bool = {
            guard executionMode == .linuxVM, getenv("GOLENS_TEST_VSOCK_PATH") == nil else { return false }
            if getenv("GOLENS_VERIFY_VM_PAUSE_RESUME") != nil { return true }
            let lastWorkspace = UserDefaults.standard.string(forKey: "GoLensLastWorkspacePath") ?? ""
            return !lastWorkspace.isEmpty
        }()
        if shouldAutoBootVM {
            Task { @MainActor [weak self] in
                try? await self?.start()
                if getenv("GOLENS_VERIFY_VM_PAUSE_RESUME") != nil {
                    try? await self?.pause()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? await self?.resume()
                }
            }
        }
    }

    nonisolated public static func recordActivityFromBackground() {
        Task { @MainActor in
            SandboxVMManager.shared.recordActivity()
        }
    }

    nonisolated public static func ensureStartedFromBackground() {
        Task { @MainActor in
            let mgr = SandboxVMManager.shared
            guard mgr.executionMode == .linuxVM else { return }
            if mgr.state == .stopped {
                try? await mgr.start()
            } else if case .paused = mgr.state {
                try? await mgr.resume()
            }
        }
    }

    private func registerVsockDialer() {
        let cb: @convention(c) (UInt32) -> Int32 = { port in
            SandboxVMManager.shared.connectVsockSync(port: port)
        }
        RegisterSandboxVsockDialer(cb)
        let timeoutCb: @convention(c) (UInt32, UInt32) -> Int32 = { port, timeoutMs in
            SandboxVMManager.shared.connectVsockSync(port: port, timeoutMs: timeoutMs)
        }
        RegisterSandboxVsockTimeoutDialer(timeoutCb)
    }

    public func loadPreferences() {
        let defaults = UserDefaults.standard
        if getenv("GOLENS_VERIFY_VM_PAUSE_RESUME") != nil {
            executionMode = .linuxVM
        } else if let envMode = ProcessInfo.processInfo.environment["GOLENS_EXECUTION_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let parsed = ExecutionMode(rawValue: envMode) {
            executionMode = parsed
        } else if let testPath = ProcessInfo.processInfo.environment["GOLENS_TEST_VSOCK_PATH"],
                  !testPath.isEmpty {
            executionMode = .linuxVM
        } else {
            executionMode = .host
        }
        Self.activeMode = executionMode
        executionMode.rawValue.withCString { SetExecutionEnvironment($0) }
        if executionMode == .host {
            atomicSocket.markUnavailable()
        } else {
            atomicSocket.markRecovering()
        }
        migrateResourcePreferences(defaults)
        if defaults.object(forKey: "GoLensContainerPauseMinutes") != nil {
            let mins = defaults.integer(forKey: "GoLensContainerPauseMinutes")
            pauseWhenInactive = InactivePauseInterval(rawValue: mins * 60) ?? .after5Minutes
        }
        if defaults.object(forKey: "GoLensContainerFastResume") != nil {
            fastResumeEnabled = defaults.bool(forKey: "GoLensContainerFastResume")
        }
        if defaults.object(forKey: "GoLensContainerCPUCores") != nil {
            let c = defaults.integer(forKey: "GoLensContainerCPUCores")
            cpuCores = c > 0 ? c : min(ProcessInfo.processInfo.activeProcessorCount, 2)
        }
        if defaults.object(forKey: "GoLensContainerMemoryMB") != nil {
            let m = defaults.integer(forKey: "GoLensContainerMemoryMB")
            if m >= Self.minimumMemoryLimitMB { memoryLimitMB = m }
        }
        if let rawEnv = getenv("GOLENS_VM_MEMORY_MB"),
           let envStr = String(validatingUTF8: rawEnv),
           let envMB = Int(envStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           envMB >= Self.minimumMemoryLimitMB {
            memoryLimitMB = envMB
        }
        if defaults.object(forKey: "GoLensContainerRosetta2") != nil {
            isRosettaEnabled = defaults.bool(forKey: "GoLensContainerRosetta2")
        }
        if let net = defaults.string(forKey: "GoLensContainerNetworkMode"), let mode = NetworkMode(rawValue: net) {
            networkMode = mode
        }
        if defaults.object(forKey: "GoLensContainerForwardPorts") != nil {
            forwardListeningPorts = defaults.bool(forKey: "GoLensContainerForwardPorts")
        }
    }

    private func migrateResourcePreferences(_ defaults: UserDefaults) {
        migrateMemoryCeiling(defaults)
        let migrationKey = "GoLensContainerResourceMigratedV6"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let previousDefaultCores = min(ProcessInfo.processInfo.activeProcessorCount, 6)
        let previousDefaultMemoryGB: Set<Int> = [1, 2, 4]
        let previousDefaultMemoryMB: Set<Int> = [1024, 2048]

        if defaults.object(forKey: "GoLensContainerMemoryGB") != nil {
            let gb = defaults.integer(forKey: "GoLensContainerMemoryGB")
            if gb > 0, !previousDefaultMemoryGB.contains(gb), defaults.object(forKey: "GoLensContainerMemoryMB") == nil {
                defaults.set(gb * 1024, forKey: "GoLensContainerMemoryMB")
            }
            defaults.removeObject(forKey: "GoLensContainerMemoryGB")
        }
        if defaults.object(forKey: "GoLensContainerMemoryMB") != nil,
           previousDefaultMemoryMB.contains(defaults.integer(forKey: "GoLensContainerMemoryMB")) {
            defaults.set(Self.defaultMemoryLimitMB, forKey: "GoLensContainerMemoryMB")
        }
        if defaults.object(forKey: "GoLensContainerCPUCores") != nil,
           defaults.integer(forKey: "GoLensContainerCPUCores") == previousDefaultCores {
            defaults.set(0, forKey: "GoLensContainerCPUCores")
        }
        if defaults.object(forKey: "GoLensContainerPauseMinutes") != nil,
           defaults.integer(forKey: "GoLensContainerPauseMinutes") == 10 {
            defaults.removeObject(forKey: "GoLensContainerPauseMinutes")
        }

        try? FileManager.default.removeItem(at: snapshotFileURL())
        try? FileManager.default.removeItem(at: appSupportDirectoryURL().appendingPathComponent("go-build-cache.ext4"))
    }

    private func migrateMemoryCeiling(_ defaults: UserDefaults) {
        let migrationKey = "GoLensContainerMemoryCeilingMigratedV7"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        if defaults.object(forKey: "GoLensContainerMemoryMB") != nil,
           defaults.integer(forKey: "GoLensContainerMemoryMB") == Self.baseMemoryMB {
            defaults.set(Self.defaultMemoryLimitMB, forKey: "GoLensContainerMemoryMB")
        }
    }

    private func premountSavedWorkspace() {
        let defaults = UserDefaults.standard
        guard let lastWorkspace = defaults.string(forKey: "GoLensLastWorkspacePath"), !lastWorkspace.isEmpty else { return }
        _ = SecurityScopedBookmarkManager.shared.resolveAndAccess(path: lastWorkspace)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lastWorkspace, isDirectory: &isDir), isDir.boolValue else { return }
        let canonicalURL = URL(fileURLWithPath: lastWorkspace).resolvingSymlinksInPath()
        _ = mountWorkspaceSync(url: canonicalURL)
    }

    public func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(pauseWhenInactive.rawValue / 60, forKey: "GoLensContainerPauseMinutes")
        defaults.set(fastResumeEnabled, forKey: "GoLensContainerFastResume")
        defaults.set(cpuCores, forKey: "GoLensContainerCPUCores")
        defaults.set(memoryLimitMB, forKey: "GoLensContainerMemoryMB")
        defaults.set(isRosettaEnabled, forKey: "GoLensContainerRosetta2")
        defaults.set(networkMode.rawValue, forKey: "GoLensContainerNetworkMode")
        defaults.set(forwardListeningPorts, forKey: "GoLensContainerForwardPorts")
    }

    public func start() async throws {
        guard state == .stopped || isFailedState else { return }
        atomicSocket.markRecovering()
        recordActivity()
        state = .starting(phase: "Initializing configuration…")

        let snapshotURL = snapshotFileURL()
        if fastResumeEnabled, FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                state = .starting(phase: "Restoring warm snapshot…")
                let restored = try await restoreSnapshot(from: snapshotURL)
                if restored {
                    state = .running(kernelVersion: kernelLabel, arch: "arm64", bootTime: Date())
                    syncWorkspacesShare()
                    atomicSocket.set(device: socketDevice, queue: vmQueue, running: true)
                    pendingRestart = false
                    if forwardListeningPorts {
                        startPortForwarding()
                    }
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        state = .starting(phase: "Booting Linux Micro-VM…")
        do {
            let config = try buildConfiguration()
            let queue = self.vmQueue

            let (vm, sock, balloon) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(VZVirtualMachine, VZVirtioSocketDevice?, VZVirtioTraditionalMemoryBalloonDevice?), Error>) in
                queue.async {
                    let instance = VZVirtualMachine(configuration: config, queue: queue)
                    instance.start { result in
                        switch result {
                        case .success:
                            let s = instance.socketDevices.first as? VZVirtioSocketDevice
                            let b = instance.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                            continuation.resume(returning: (instance, s, b))
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            self.virtualMachine = vm
            self.socketDevice = sock
            self.memoryBalloonDevice = balloon
            self.syncWorkspacesShare()
            atomicSocket.set(device: sock, queue: vmQueue, running: true)

            state = .starting(phase: "Connecting guest agent…")
            try await waitForGuestAgent()
            setGuestMemoryTarget(Self.baseMemoryBytes(booted: bootedMemoryBytes))

            state = .running(kernelVersion: kernelLabel, arch: "arm64", bootTime: Date())
            self.syncWorkspacesShare()
            atomicSocket.set(device: socketDevice, queue: vmQueue, running: true)
            pendingRestart = false
            if forwardListeningPorts {
                startPortForwarding()
            }
            for workspace in WorkspaceState.allRegisteredWorkspaces() where !workspace.activeWorkspacePath.isEmpty {
                workspace.refreshGitStatus()
                workspace.refreshActiveFileDiff()
            }
        } catch {
            atomicSocket.markUnavailable()
            if let vm = virtualMachine {
                let queue = self.vmQueue
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async {
                        if vm.canStop {
                            vm.stop { _ in continuation.resume() }
                        } else {
                            continuation.resume()
                        }
                    }
                }
                virtualMachine = nil
                socketDevice = nil
                memoryBalloonDevice = nil
            }
            let suggestion = error is GuestAgentError
                ? "Restart the container in Settings. If it still does not respond, use Repair."
                : "Verify Virtualization entitlements and disk image integrity."
            state = .failed(errorDescription: error.localizedDescription, recoverySuggestion: suggestion)
            throw error
        }
    }

    public func pause() async throws {
        stopForwardingAllPorts()
        atomicSocket.set(device: socketDevice, queue: vmQueue, running: false)
        guard let vm = virtualMachine else {
            if case .running = state {
                state = .paused(idleSince: Date())
            }
            return
        }
        let queue = self.vmQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard vm.canPause else {
                    continuation.resume()
                    return
                }
                vm.pause { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        state = .paused(idleSince: Date())
    }

    public func resume() async throws {
        guard let vm = virtualMachine else {
            if case .paused = state {
                state = .running(kernelVersion: kernelLabel, arch: "arm64", bootTime: Date())
                syncWorkspacesShare()
                atomicSocket.set(device: socketDevice, queue: vmQueue, running: true)
                if forwardListeningPorts {
                    startPortForwarding()
                }
            }
            return
        }
        let queue = self.vmQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard vm.canResume else {
                    continuation.resume()
                    return
                }
                vm.resume { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        state = .running(kernelVersion: kernelLabel, arch: "arm64", bootTime: Date())
        syncWorkspacesShare()
        let currentSock = socketDevice ?? (vm.socketDevices.first as? VZVirtioSocketDevice)
        atomicSocket.set(device: currentSock, queue: vmQueue, running: true)
        recordActivity()
        if forwardListeningPorts {
            startPortForwarding()
        }
    }

    public func restart() async throws {
        state = .restarting
        stopForwardingAllPorts()
        atomicSocket.set(device: nil, running: false)
        if let vm = virtualMachine {
            let queue = self.vmQueue
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    if vm.canStop {
                        vm.stop { _ in continuation.resume() }
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        virtualMachine = nil
        state = .stopped
        try await start()
    }

    public func repair() async throws {
        let snapshot = snapshotFileURL()
        try? FileManager.default.removeItem(at: snapshot)
        try await restart()
    }

    public func stop() async {
        stopForwardingAllPorts()
        atomicSocket.markUnavailable()
        if let vm = virtualMachine {
            let queue = self.vmQueue
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    if vm.canStop {
                        vm.stop { _ in continuation.resume() }
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        virtualMachine = nil
        socketDevice = nil
        memoryBalloonDevice = nil
        state = .stopped
    }

    public func setExecutionMode(_ mode: ExecutionMode) {
        guard executionMode != mode else { return }
        executionMode = mode
        Self.activeMode = mode
        switch mode {
        case .host:
            recycledWhileIdle = false
            atomicSocket.markUnavailable()
            mode.rawValue.withCString { SetExecutionEnvironment($0) }
            NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
            WorkspaceState.allRegisteredWorkspaces().forEach { $0.updateLanguageServerConditions(reportedRemote: nil) }
            if !WorkspaceState.shared.activeWorkspacePath.isEmpty {
                WorkspaceState.shared.restartLanguageServer()
            }
            if state != .stopped {
                Task {
                    await self.stop()
                }
            }
        case .linuxVM:
            atomicSocket.markRecovering()
            let activePath = WorkspaceState.shared.activeWorkspacePath
            if !activePath.isEmpty {
                let canonicalURL = URL(fileURLWithPath: activePath).resolvingSymlinksInPath()
                _ = registerMountedWorkspace(url: canonicalURL)
                syncWorkspacesShare()
            }
            mode.rawValue.withCString { SetExecutionEnvironment($0) }
            NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
            WorkspaceState.allRegisteredWorkspaces().forEach { $0.updateLanguageServerConditions(reportedRemote: nil) }
            if !activePath.isEmpty, getenv("GOLENS_TEST_VSOCK_PATH") == nil {
                Task {
                    if self.state == .stopped || self.isFailedState {
                        try? await self.start()
                    } else if case .paused = self.state {
                        try? await self.resume()
                    }
                    guard self.executionMode == .linuxVM else { return }
                    WorkspaceState.allRegisteredWorkspaces().forEach { $0.updateLanguageServerConditions(reportedRemote: nil) }
                    WorkspaceState.shared.restartLanguageServer()
                }
            }
        }
    }

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    public func recordActivity() {
        lastActivityTime = Date()
        guard executionMode == .linuxVM else { return }
        switch state {
        case .paused:
            Task {
                try? await self.resume()
            }
        case .stopped where recycledWhileIdle && !WorkspaceState.shared.activeWorkspacePath.isEmpty:
            recycledWhileIdle = false
            Task {
                try? await self.start()
                guard self.executionMode == .linuxVM else { return }
                WorkspaceState.shared.restartLanguageServer()
            }
        default:
            break
        }
    }

    static func baseMemoryBytes(booted: UInt64) -> UInt64 {
        let mib: UInt64 = 1024 * 1024
        let floor = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, UInt64(baseMemoryMB) * mib)
        return min(booted, floor / mib * mib)
    }

    private func setGuestMemoryTarget(_ bytes: UInt64) {
        guard let balloon = memoryBalloonDevice, bytes > 0 else { return }
        guestMemoryTargetBytes = bytes
        let mib: UInt64 = 1024 * 1024
        GuestMemoryStepApplied(Int32(bytes / mib), Int32(bootedMemoryBytes / mib))
        vmQueue.async {
            balloon.targetVirtualMachineMemorySize = bytes
        }
    }

    private func startGuestMemoryStepper() {
        guestMemoryStepTask?.cancel()
        guestMemoryStepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.guestMemoryStepInterval)
                guard let self else { break }
                self.stepGuestMemory()
            }
        }
    }

    private func stepGuestMemory() {
        guard case .running = state, memoryBalloonDevice != nil, guestMemoryTargetBytes > 0 else { return }
        let mib: UInt64 = 1024 * 1024
        let base = Self.baseMemoryBytes(booted: bootedMemoryBytes)
        guard bootedMemoryBytes > base else { return }
        let idle = !NSApplication.shared.isActive
            && activeOperationsCount == 0
            && Date().timeIntervalSince(lastActivityTime) >= Self.guestMemoryIdleSeconds
        let target = UInt64(max(0, GuestMemoryStepTarget(
            Int32(guestMemoryTargetBytes / mib),
            Int32(base / mib),
            Int32(bootedMemoryBytes / mib),
            idle ? 1 : 0
        ))) * mib
        guard target >= base, target <= bootedMemoryBytes, target != guestMemoryTargetBytes else { return }
        setGuestMemoryTarget(target)
    }

    public func beginOperation() {
        activeOperationsCount += 1
        recordActivity()
    }

    public func endOperation() {
        activeOperationsCount = max(0, activeOperationsCount - 1)
        recordActivity()
    }

    private func startInactivityMonitor() {
        inactivityTimerTask?.cancel()
        inactivityTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { break }
                let (idleTime, pauseInterval, ops, currentState, isAppActive, mode, shouldWarmRecycle) = await MainActor.run { () -> (TimeInterval, Int, Int, VMState, Bool, ExecutionMode, Bool) in
                    let active = NSApplication.shared.isActive
                    if active {
                        self.lastActivityTime = Date()
                    }
                    let noActiveSession = !WorkspaceState.allRegisteredWorkspaces().contains { $0.isRunning || $0.isTestRunning || $0.debug.isDebugMode }
                    let balloonedAboveBase = self.bootedMemoryBytes > Self.baseMemoryBytes(booted: self.bootedMemoryBytes)
                    return (
                        Date().timeIntervalSince(self.lastActivityTime),
                        self.pauseWhenInactive.rawValue,
                        self.activeOperationsCount,
                        self.state,
                        active,
                        self.executionMode,
                        noActiveSession && balloonedAboveBase
                    )
                }

                guard mode == .linuxVM, case .running = currentState, !isAppActive, ops == 0 else { continue }
                if pauseInterval > 0 && idleTime >= Double(pauseInterval) {
                    if shouldWarmRecycle {
                        self.recycledWhileIdle = true
                        await self.stop()
                    } else {
                        try? await self.pause()
                    }
                }
            }
        }
    }

    nonisolated public func connectVsockSync(port: UInt32, timeoutMs: UInt32 = 5000) -> Int32 {
        if port != 2004 {
            Self.recordActivityFromBackground()
        }
        return atomicSocket.connectSync(port: port, timeoutMs: timeoutMs)
    }

    public static var rosettaAvailability: VZLinuxRosettaAvailability {
        VZLinuxRosettaDirectoryShare.availability
    }

    public static func installRosetta() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            VZLinuxRosettaDirectoryShare.installRosetta { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func startPortForwarding() {
        guard forwardListeningPorts else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let fd = self.connectVsockSync(port: 2004, timeoutMs: 2000)
            guard fd >= 0 else { return }
            self.portForwarder.start(eventStreamFd: fd)
        }
    }

    nonisolated public func stopForwardingAllPorts() {
        portForwarder.unbindAll()
    }

    private func vmRuntimeDirectoryURL() -> URL {
        LinuxRuntimeLocation.directory
    }

    private func prepareGuestRootfsDirectory(from vmRuntimeDir: URL) throws -> URL {
        let rootDir = appSupportDirectoryURL().appendingPathComponent("VMRootfs")
        try? FileManager.default.removeItem(at: rootDir)
        let subdirs = [
            "sbin", "bin", "lib", "usr",
            "dev", "proc", "sys", "tmp", "run", "root", "var/tmp",
            "mnt/erofs", "mnt/rosetta", "workspaces",
            "cache/gomod", "cache/gobuild", "etc"
        ]
        for sub in subdirs {
            try FileManager.default.createDirectory(at: rootDir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let agentSrc = vmRuntimeDir.appendingPathComponent("golens-vm-agent")
        let initDst = rootDir.appendingPathComponent("sbin/init")
        if FileManager.default.fileExists(atPath: agentSrc.path) {
            try FileManager.default.copyItem(at: agentSrc, to: initDst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initDst.path)
        }
        return rootDir
    }

    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, cpuCores)
        config.memorySize = UInt64(max(Self.minimumMemoryLimitMB, memoryLimitMB)) * 1024 * 1024
        bootedMemoryBytes = config.memorySize
        config.platform = VZGenericPlatformConfiguration()

        let vmRuntimeDir = vmRuntimeDirectoryURL()
        guard ["vmlinuz", "golens-vm-agent"].allSatisfy({ FileManager.default.fileExists(atPath: vmRuntimeDir.appendingPathComponent($0).path) }) else {
            throw GuestAgentError.runtimeNotInstalled
        }
        let rootfsDir = try prepareGuestRootfsDirectory(from: vmRuntimeDir)

        let bootLoader = try makeBootLoaderConfiguration(vmRuntimeDir: vmRuntimeDir)
        config.bootLoader = bootLoader

        var storageDevices: [VZStorageDeviceConfiguration] = []
        let erofsURL = vmRuntimeDir.appendingPathComponent("rootfs.img")
        if FileManager.default.fileExists(atPath: erofsURL.path) {
            let erofsAttachment = try VZDiskImageStorageDeviceAttachment(url: erofsURL, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: erofsAttachment))
        }
        config.storageDevices = storageDevices

        var fsDevices: [VZDirectorySharingDeviceConfiguration] = []

        let rootVfs = VZVirtioFileSystemDeviceConfiguration(tag: "rootfs")
        rootVfs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: rootfsDir, readOnly: false))
        fsDevices.append(rootVfs)

        let gorootURL = vmRuntimeDir.appendingPathComponent("goroot")
        if FileManager.default.fileExists(atPath: gorootURL.path) {
            let goVfs = VZVirtioFileSystemDeviceConfiguration(tag: "goroot")
            goVfs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: gorootURL, readOnly: true))
            fsDevices.append(goVfs)
        }

        if let modShare = try? makeModuleCacheFileSystemConfiguration() {
            fsDevices.append(modShare)
        }

        if let buildShare = try? makeBuildCacheFileSystemConfiguration() {
            fsDevices.append(buildShare)
        }

        let initialWsDirs = buildWorkspaceShareDictionary()
        syncedWorkspaceSlugs = Set(initialWsDirs.keys)
        let wsVfs = VZVirtioFileSystemDeviceConfiguration(tag: "workspaces")
        wsVfs.share = VZMultipleDirectoryShare(directories: initialWsDirs)
        fsDevices.append(wsVfs)

        if isRosettaEnabled && VZLinuxRosettaDirectoryShare.availability == .installed {
            if let rosettaShare = try? VZLinuxRosettaDirectoryShare() {
                let rosettaConfig = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosettaConfig.share = rosettaShare
                fsDevices.append(rosettaConfig)
            }
        }

        config.directorySharingDevices = fsDevices

        let socketConfig = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketConfig]

        let balloonConfig = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        config.memoryBalloonDevices = [balloonConfig]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if networkMode == .allowOutbound {
            let netConfig = VZVirtioNetworkDeviceConfiguration()
            netConfig.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [netConfig]
        } else {
            config.networkDevices = []
        }

        try config.validate()
        return config
    }

    private func makeBootLoaderConfiguration(vmRuntimeDir: URL) throws -> VZBootLoader {
        let kernelURL = vmRuntimeDir.appendingPathComponent("vmlinuz")
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = "console=hvc0 root=rootfs rootfstype=virtiofs rw init=/sbin/init quiet"
        return bootLoader
    }

    public func buildCacheDiskURL() -> URL {
        cachesDirectoryURL().appendingPathComponent("gobuild")
    }

    public func moduleCacheDirectoryURL() -> URL {
        cachesDirectoryURL().appendingPathComponent("gomod")
    }

    public func snapshotFileURL() -> URL {
        appSupportDirectoryURL().appendingPathComponent("VMState").appendingPathComponent("snapshot.bin")
    }

    private func makeBuildCacheFileSystemConfiguration() throws -> VZVirtioFileSystemDeviceConfiguration {
        let gobuildURL = buildCacheDiskURL()
        try FileManager.default.createDirectory(at: gobuildURL, withIntermediateDirectories: true)
        let sharedDir = VZSharedDirectory(url: gobuildURL, readOnly: false)
        let singleShare = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "gobuildcache")
        fsConfig.share = singleShare
        return fsConfig
    }

    private func makeModuleCacheFileSystemConfiguration() throws -> VZVirtioFileSystemDeviceConfiguration {
        var gomodURL = moduleCacheDirectoryURL()
        try FileManager.default.createDirectory(at: gomodURL, withIntermediateDirectories: true)
        if let pw = getpwuid(getuid()), let dirPtr = pw.pointee.pw_dir {
            let realHome = String(cString: dirPtr)
            let realGoMod = URL(fileURLWithPath: realHome).appendingPathComponent("go/pkg/mod")
            if FileManager.default.fileExists(atPath: realGoMod.path) {
                gomodURL = realGoMod
            }
        }
        let sharedDir = VZSharedDirectory(url: gomodURL, readOnly: false)
        let singleShare = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "gomodcache")
        fsConfig.share = singleShare
        return fsConfig
    }

    private func saveSnapshot(to url: URL) async throws {
        guard let vm = virtualMachine else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await pause()
        let queue = self.vmQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                vm.saveMachineStateTo(url: url) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func restoreSnapshot(from url: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let config = try buildConfiguration()
        let queue = self.vmQueue
        let (vm, sock, balloon) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(VZVirtualMachine, VZVirtioSocketDevice?, VZVirtioTraditionalMemoryBalloonDevice?), Error>) in
            queue.async {
                let instance = VZVirtualMachine(configuration: config, queue: queue)
                instance.restoreMachineStateFrom(url: url) { restoreError in
                    if let restoreError {
                        continuation.resume(throwing: restoreError)
                        return
                    }
                    instance.resume { result in
                        switch result {
                        case .success:
                            let s = instance.socketDevices.first as? VZVirtioSocketDevice
                            let b = instance.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                            continuation.resume(returning: (instance, s, b))
                        case .failure(let resumeError):
                            continuation.resume(throwing: resumeError)
                        }
                    }
                }
            }
        }
        self.virtualMachine = vm
        self.socketDevice = sock
        self.memoryBalloonDevice = balloon
        setGuestMemoryTarget(Self.baseMemoryBytes(booted: bootedMemoryBytes))
        return true
    }

    public func workspaceSlug(for url: URL) -> String {
        let canonical = url.standardizedFileURL.path
        let name = url.lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        let shortHash = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(name)-\(shortHash)"
    }

    private func buildWorkspaceShareDictionary() -> [String: VZSharedDirectory] {
        var dirs: [String: VZSharedDirectory] = [:]
        for (slug, ws) in mountedWorkspaces {
            if FileManager.default.fileExists(atPath: ws.hostURL.path) {
                dirs[slug] = VZSharedDirectory(url: ws.hostURL, readOnly: false)
                let resolved = ws.hostURL.resolvingSymlinksInPath()
                let resolvedSlug = workspaceSlug(for: resolved)
                if resolvedSlug != slug && FileManager.default.fileExists(atPath: resolved.path) {
                    dirs[resolvedSlug] = VZSharedDirectory(url: resolved, readOnly: false)
                }
            }
        }
        return dirs
    }

    private func syncWorkspacesShare() {
        guard let vm = virtualMachine else { return }
        let dirs = buildWorkspaceShareDictionary()
        let newSlugs = Set(dirs.keys)
        guard newSlugs != syncedWorkspaceSlugs else { return }
        syncedWorkspaceSlugs = newSlugs
        let queue = self.vmQueue
        queue.async {
            for case let vfs as VZVirtioFileSystemDevice in vm.directorySharingDevices where vfs.tag == "workspaces" {
                vfs.share = VZMultipleDirectoryShare(directories: dirs)
            }
        }
    }

    private func registerMountedWorkspace(url: URL) -> MountedWorkspace {
        _ = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        let slug = workspaceSlug(for: url)
        let guestPath = "/workspaces/\(slug)"
        let ws = MountedWorkspace(slug: slug, hostURL: url, guestPath: guestPath)
        mountedWorkspaces[slug] = ws
        return ws
    }

    @discardableResult
    public func mountWorkspaceSync(url: URL) -> MountedWorkspace {
        let ws = registerMountedWorkspace(url: url)
        if executionMode == .linuxVM {
            syncWorkspacesShare()
            if state == .stopped && getenv("GOLENS_TEST_VSOCK_PATH") == nil {
                Self.ensureStartedFromBackground()
            }
        }
        return ws
    }

    public func mountWorkspace(url: URL) async throws -> MountedWorkspace {
        return mountWorkspaceSync(url: url)
    }

    public func unmountWorkspace(url: URL) {
        let slug = workspaceSlug(for: url)
        mountedWorkspaces.removeValue(forKey: slug)
        syncWorkspacesShare()
        SecurityScopedBookmarkManager.shared.stopAccessing(url: url)
    }

    public func hostToGuestPath(_ hostPath: String) -> String {
        for (_, ws) in mountedWorkspaces {
            if hostPath.hasPrefix(ws.hostURL.path) {
                let relative = hostPath.dropFirst(ws.hostURL.path.count)
                return "\(ws.guestPath)\(relative)"
            }
        }
        return hostPath
    }

    public func guestToHostPath(_ guestPath: String) -> String {
        for (_, ws) in mountedWorkspaces {
            if guestPath.hasPrefix(ws.guestPath) {
                let relative = guestPath.dropFirst(ws.guestPath.count)
                return "\(ws.hostURL.path)\(relative)"
            }
        }
        return guestPath
    }

    private var kernelLabel: String {
        linuxKernelVersion.map { "Linux \($0)" } ?? "Linux"
    }

    func refreshLinuxKernelVersion() {
        let kernelURL = vmRuntimeDirectoryURL().appendingPathComponent("vmlinuz")
        Task.detached(priority: .utility) {
            let version = Self.kernelVersion(inImageAt: kernelURL)
            await MainActor.run {
                SandboxVMManager.shared.linuxKernelVersion = version
            }
        }
    }

    nonisolated static func kernelVersion(inImageAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let marker = "Linux version ".data(using: .utf8),
              let range = data.range(of: marker) else { return nil }
        let tail = data[range.upperBound..<min(data.endIndex, range.upperBound + 64)]
        let token = tail.prefix { $0 != 0x20 && $0 != 0 }
        let numeric = token.prefix { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }
        return numeric.isEmpty ? nil : String(decoding: numeric, as: UTF8.self)
    }

    public func refreshLinuxGoVersion() {
        let versionURL = vmRuntimeDirectoryURL().appendingPathComponent("goroot/VERSION")
        guard let text = try? String(contentsOf: versionURL, encoding: .utf8),
              let first = text.split(separator: "\n").first,
              first.hasPrefix("go") else {
            linuxGoVersion = nil
            return
        }
        linuxGoVersion = String(first.dropFirst(2))
    }

    public func updateCacheSizesAsync() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let buildURL = await self.buildCacheDiskURL()
            let modURL = await self.moduleCacheDirectoryURL()

            let buildSize = self.buildCacheSize(at: buildURL)
            let modSize = self.calculateDirectorySize(at: modURL)

            await MainActor.run {
                self.buildCacheSizeBytes = buildSize
                self.moduleCacheSizeBytes = modSize
            }
        }
    }

    public func clearBuildCache() async throws {
        let buildURL = buildCacheDiskURL()
        try FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true)
        let entries = try FileManager.default.contentsOfDirectory(at: buildURL, includingPropertiesForKeys: nil)
        for entry in entries {
            if entry.lastPathComponent == Self.guestXDGCacheDirectoryName {
                let xdgEntries = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                for xdgEntry in xdgEntries where xdgEntry.lastPathComponent != Self.goplsCacheDirectoryName {
                    try FileManager.default.removeItem(at: xdgEntry)
                }
                continue
            }
            try FileManager.default.removeItem(at: entry)
        }
        let legacyExt4 = appSupportDirectoryURL().appendingPathComponent("go-build-cache.ext4")
        if FileManager.default.fileExists(atPath: legacyExt4.path) {
            try? FileManager.default.removeItem(at: legacyExt4)
        }
        buildCacheSizeBytes = buildCacheSize(at: buildURL)
    }

    private nonisolated func buildCacheSize(at buildURL: URL) -> Int64 {
        let goplsIndex = buildURL
            .appendingPathComponent(Self.guestXDGCacheDirectoryName)
            .appendingPathComponent(Self.goplsCacheDirectoryName)
        return max(0, calculateDirectorySize(at: buildURL) - calculateDirectorySize(at: goplsIndex))
    }

    public func clearModuleCache() async throws {
        let modURL = moduleCacheDirectoryURL()
        if FileManager.default.fileExists(atPath: modURL.path) {
            try FileManager.default.removeItem(at: modURL)
            try FileManager.default.createDirectory(at: modURL, withIntermediateDirectories: true)
        }
        moduleCacheSizeBytes = 0
    }

    private nonisolated func calculateDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        var finished = false
        while !finished {
            autoreleasepool {
                guard let fileURL = enumerator.nextObject() as? URL else {
                    finished = true
                    return
                }
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = resourceValues.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private func appSupportDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GoLens", isDirectory: true)
    }

    private func cachesDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.golens.app", isDirectory: true)
    }

    private func waitForGuestAgent() async throws {
        let deadline = Date().addingTimeInterval(Self.guestAgentReadyTimeoutSeconds)
        while Date() < deadline {
            let fd = await Task.detached(priority: .userInitiated) { [weak self] in
                self?.connectVsockSync(port: 2002, timeoutMs: 250) ?? -1
            }.value
            if fd >= 0 {
                close(fd)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw GuestAgentError.notReady(seconds: Int(Self.guestAgentReadyTimeoutSeconds))
    }

    private static let guestAgentReadyTimeoutSeconds: TimeInterval = 15

    enum GuestAgentError: LocalizedError {
        case notReady(seconds: Int)
        case runtimeNotInstalled

        var errorDescription: String? {
            switch self {
            case .notReady(let seconds):
                return "The Linux container started, but its agent did not respond within \(seconds) seconds."
            case .runtimeNotInstalled:
                return "The Linux Sandbox isn’t installed. Download it in Settings ▸ Execution."
            }
        }
    }
}

final class PortForwardManager: @unchecked Sendable {
    private let lock = NSLock()
    private var activeListeners: [UInt16: ActiveListener] = [:]
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamFd: Int32 = -1
    private let queue = DispatchQueue(label: "dev.golens.portforward", qos: .userInitiated)
    var dialer: (@Sendable (UInt32) -> Int32)?

    struct ActiveListener {
        let port: UInt16
        let socketFd: Int32
        let source: DispatchSourceRead
    }

    func start(eventStreamFd: Int32) {
        lock.lock()
        if self.eventStreamFd >= 0 {
            close(self.eventStreamFd)
        }
        self.eventStreamFd = eventStreamFd
        lock.unlock()

        eventStreamTask?.cancel()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runEventStream(fd: eventStreamFd)
        }
    }

    private func runEventStream(fd: Int32) {
        var mode: UInt8 = 0x01
        let written = write(fd, &mode, 1)
        guard written == 1 else {
            closeEventStreamFdIfCurrent(fd)
            return
        }

        var ack: UInt8 = 0
        let ackRead = read(fd, &ack, 1)
        guard ackRead == 1, ack == 0x00 else {
            closeEventStreamFdIfCurrent(fd)
            return
        }

        var buffer = [UInt8](repeating: 0, count: 3)
        while isCurrentEventStreamFd(fd) {
            var bytesRead = 0
            while bytesRead < 3 {
                let offset = bytesRead
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, 3 - offset) }
                if n <= 0 {
                    closeEventStreamFdIfCurrent(fd)
                    return
                }
                bytesRead += n
            }

            let opcode = buffer[0]
            let port = (UInt16(buffer[1]) << 8) | UInt16(buffer[2])

            if opcode == 0x01 {
                bindPort(port)
            } else if opcode == 0x02 {
                unbindPort(port)
            }
        }
        closeEventStreamFdIfCurrent(fd)
    }

    private func isCurrentEventStreamFd(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.eventStreamFd == fd && fd >= 0
    }

    private func closeEventStreamFdIfCurrent(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if self.eventStreamFd == fd {
            self.eventStreamFd = -1
        }
        close(fd)
    }

    func bindPort(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard activeListeners[port] == nil else { return }

        let listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else { return }

        var opt: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = in_port_t(port.bigEndian)
        sin.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, listen(listenFd, 128) == 0 else {
            close(listenFd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &addrLen)
                }
            }
            guard clientFd >= 0 else { return }
            self?.handleClientConnection(clientFd: clientFd, targetPort: port)
        }
        source.setCancelHandler {
            close(listenFd)
        }
        source.resume()
        activeListeners[port] = ActiveListener(port: port, socketFd: listenFd, source: source)
    }

    func unbindPort(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard let listener = activeListeners.removeValue(forKey: port) else { return }
        listener.source.cancel()
    }

    func unbindAll() {
        lock.lock()
        let currentStreamFd = self.eventStreamFd
        self.eventStreamFd = -1
        for (_, listener) in activeListeners {
            listener.source.cancel()
        }
        activeListeners.removeAll()
        lock.unlock()
        if currentStreamFd >= 0 {
            shutdown(currentStreamFd, SHUT_RDWR)
            close(currentStreamFd)
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], count: Int) -> Bool {
        buf.withUnsafeBytes { raw in
            var written = 0
            while written < count {
                let w = write(fd, raw.baseAddress! + written, count - written)
                if w <= 0 { return false }
                written += w
            }
            return true
        }
    }

    private func handleClientConnection(clientFd: Int32, targetPort: UInt16) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let dialer = self.dialer else {
                close(clientFd)
                return
            }
            let vsockFd = dialer(2004)
            guard vsockFd >= 0 else {
                close(clientFd)
                return
            }

            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(vsockFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(vsockFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var header: [UInt8] = [0x02, UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF)]
            guard write(vsockFd, &header, 3) == 3 else {
                close(clientFd)
                close(vsockFd)
                return
            }

            var status: UInt8 = 0xFF
            guard read(vsockFd, &status, 1) == 1, status == 0x00 else {
                close(clientFd)
                close(vsockFd)
                return
            }

            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buf = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(clientFd, &buf, buf.count)
                    if n <= 0 {
                        shutdown(vsockFd, SHUT_WR)
                        break
                    }
                    if !Self.writeAll(vsockFd, buf, count: n) {
                        shutdown(clientFd, SHUT_RD)
                        break
                    }
                }
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buf = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(vsockFd, &buf, buf.count)
                    if n <= 0 {
                        shutdown(clientFd, SHUT_WR)
                        break
                    }
                    if !Self.writeAll(clientFd, buf, count: n) {
                        shutdown(vsockFd, SHUT_RD)
                        break
                    }
                }
                group.leave()
            }

            group.wait()
            close(clientFd)
            close(vsockFd)
        }
    }
}

