import AppKit
import Foundation
import GoLensFoundation
import Observation
import SwiftTerm

@Observable
final class WorkspaceExecutionState: @unchecked Sendable {
    var activeFileExcludedReason: String? = nil
    var activeBuildTargetIsCustom: Bool = false
    var consoleFilterText: String = ""
    var runConfigurations: [RunConfiguration] = []
    var activeRunConfigId: UUID? = nil
    @ObservationIgnored var runConfigurationSaveFailed = false
    var lastActivity: WorkspaceState.FinishedActivity? = nil
    var goCommand: String? = nil
    var goToolchainMissing: Bool = false
    var toolchainHealth: ToolchainHealthInfo? = nil
    var hasGoModule: Bool = true
    var moduleDownloadError: String? = nil
    var runFailure: RunFailure? = nil {
        didSet {
            guard let failure = runFailure, failure != oldValue else { return }
            if case .build = failure.kind {
                lastActivity = WorkspaceState.FinishedActivity(title: "Build Failed", failed: true, date: Date())
            } else {
                lastActivity = WorkspaceState.FinishedActivity(title: "Run Failed", failed: true, date: Date())
            }
        }
    }
    var kernelTelemetry: KernelTelemetry? = nil
    @ObservationIgnored var pendingTidyAfterGoGet: Set<String> = []

    var consoleOutput: [WorkspaceState.LogMessage] = []
    @ObservationIgnored var consoleOutputBytes: Int = 0
    var runSessions: [RunSession] = [] {
        didSet {
            let running = runSessions.contains(where: \.isRunning)
            if running != hasRunningSession { hasRunningSession = running }
        }
    }
    private(set) var hasRunningSession: Bool = false
    var selectedRunSessionId: Int64? = nil
    var isStartingRun: Bool = false
    @ObservationIgnored var pendingRunPrelude: [WorkspaceState.LogMessage] = []
    @ObservationIgnored let runnerLogLock = NSLock()
    @ObservationIgnored var suppressedRunnerLogs: [(text: String, isStderr: Bool)] = []
    @ObservationIgnored var pendingRunEvents: [[String: Any]] = []
    @ObservationIgnored var runEventDrainScheduled: Bool = false
    @ObservationIgnored var pendingLogEntries = PendingLogQueue()
    @ObservationIgnored var logDrainScheduled: Bool = false

    var terminalSessions: [TerminalSession] = [TerminalSession(id: UUID().uuidString, title: "zsh")]
    var selectedTerminalId: String? = nil
    var terminalEngines: [String: TerminalView] = [:]
}

extension WorkspaceState {
    static let maxRunSessions = 8
    static let terminalScrollbackLines = 1000
    static let maxTerminalSessions = 8

    var activeFileExcludedReason: String? {
        get { execution.activeFileExcludedReason }
        set { execution.activeFileExcludedReason = newValue }
    }

    var activeBuildTargetIsCustom: Bool {
        get { execution.activeBuildTargetIsCustom }
        set { execution.activeBuildTargetIsCustom = newValue }
    }

    var consoleFilterText: String {
        get { execution.consoleFilterText }
        set { execution.consoleFilterText = newValue }
    }

    var runConfigurations: [RunConfiguration] {
        get { execution.runConfigurations }
        set { execution.runConfigurations = newValue }
    }

    var activeRunConfigId: UUID? {
        get { execution.activeRunConfigId }
        set { execution.activeRunConfigId = newValue }
    }

    var lastActivity: FinishedActivity? {
        get { execution.lastActivity }
        set { execution.lastActivity = newValue }
    }

    var goCommand: String? {
        get { execution.goCommand }
        set { execution.goCommand = newValue }
    }

    var activeGoCommand: String? { goCommand }

    var goToolchainMissing: Bool {
        get { execution.goToolchainMissing }
        set { execution.goToolchainMissing = newValue }
    }

    var toolchainHealth: ToolchainHealthInfo? {
        get { execution.toolchainHealth }
        set { execution.toolchainHealth = newValue }
    }

    var hasGoModule: Bool {
        get { execution.hasGoModule }
        set { execution.hasGoModule = newValue }
    }

    var moduleDownloadError: String? {
        get { execution.moduleDownloadError }
        set { execution.moduleDownloadError = newValue }
    }

    var runFailure: RunFailure? {
        get { execution.runFailure }
        set { execution.runFailure = newValue }
    }

    var kernelTelemetry: KernelTelemetry? {
        get { execution.kernelTelemetry }
        set { execution.kernelTelemetry = newValue }
    }

    var pendingTidyAfterGoGet: Set<String> {
        get { execution.pendingTidyAfterGoGet }
        set { execution.pendingTidyAfterGoGet = newValue }
    }

    var consoleOutput: [LogMessage] {
        get { execution.consoleOutput }
        set { execution.consoleOutput = newValue }
    }

    var consoleOutputBytes: Int {
        get { execution.consoleOutputBytes }
        set { execution.consoleOutputBytes = newValue }
    }

    var isRunning: Bool {
        isStartingRun || isTestRunning || debug.isDebugMode || hasRunningSession
    }

    var runSessions: [RunSession] {
        get { execution.runSessions }
        set { execution.runSessions = newValue }
    }

    var hasRunningSession: Bool {
        execution.hasRunningSession
    }

    var selectedRunSessionId: Int64? {
        get { execution.selectedRunSessionId }
        set { execution.selectedRunSessionId = newValue }
    }

    var isStartingRun: Bool {
        get { execution.isStartingRun }
        set { execution.isStartingRun = newValue }
    }

    var pendingRunPrelude: [LogMessage] {
        get { execution.pendingRunPrelude }
        set { execution.pendingRunPrelude = newValue }
    }

    var runnerLogLock: NSLock {
        execution.runnerLogLock
    }

    var suppressedRunnerLogs: [(text: String, isStderr: Bool)] {
        get { execution.suppressedRunnerLogs }
        set { execution.suppressedRunnerLogs = newValue }
    }

    var pendingRunEvents: [[String: Any]] {
        get { execution.pendingRunEvents }
        set { execution.pendingRunEvents = newValue }
    }

    var runEventDrainScheduled: Bool {
        get { execution.runEventDrainScheduled }
        set { execution.runEventDrainScheduled = newValue }
    }

    var pendingLogEntries: PendingLogQueue {
        get { execution.pendingLogEntries }
        set { execution.pendingLogEntries = newValue }
    }

    var logDrainScheduled: Bool {
        get { execution.logDrainScheduled }
        set { execution.logDrainScheduled = newValue }
    }

    var terminalSessions: [TerminalSession] {
        get { execution.terminalSessions }
        set { execution.terminalSessions = newValue }
    }

    var selectedTerminalId: String? {
        get { execution.selectedTerminalId }
        set { execution.selectedTerminalId = newValue }
    }

    var terminalEngines: [String: TerminalView] {
        get { execution.terminalEngines }
        set { execution.terminalEngines = newValue }
    }

    func resetTerminalSessions() {
        terminalSessions.map(\.id).forEach(closeTerminalSession)
        let session = TerminalSession(id: UUID().uuidString, title: "zsh")
        terminalSessions = [session]
        selectedTerminalId = session.id
    }

    func closeTerminalSession(_ id: String) {
        guard let idx = terminalSessions.firstIndex(where: { $0.id == id }) else { return }
        terminalSessions.remove(at: idx)
        if selectedTerminalId == id {
            selectedTerminalId = terminalSessions.last?.id
        }
        if let engine = terminalEngines.removeValue(forKey: id) {
            engine.terminalDelegate = nil
            engine.removeFromSuperview()
        }
        DispatchQueue.global(qos: .utility).async {
            id.withCString { CloseTerminal($0) }
        }
    }
}

struct HostGoToolchainStatus: Equatable, Sendable {
    var version: String
    var goBinaryPath: String
    var goroot: String
    var isCustom: Bool
}

extension WorkspaceState {
    var executionMode: SandboxVMManager.ExecutionMode {
        SandboxVMManager.activeMode
    }

    func syncCustomGoBinaryWithCore() {
        customGoBinaryPath.withCString { SetHostGoBinary($0) }
    }

    func applyWordWrap(to textView: NSTextView?) {
        guard let textView else { return }
        if let golens = textView as? GoLensTextView {
            golens.applyWordWrapLayout(wordWrapEnabled)
            return
        }
        let scrollView = textView.enclosingScrollView
        if wordWrapEnabled {
            scrollView?.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = .width
            let width = scrollView?.contentSize.width ?? textView.bounds.width
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            if width > 0 && textView.frame.width != width {
                textView.frame.size.width = width
            }
        } else {
            scrollView?.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    static func inspectGoBinary(at binaryPath: String, isCustom: Bool) async -> HostGoToolchainStatus? {
        await Task.detached(priority: .utility) {
            guard !binaryPath.isEmpty, FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = ["env", "GOVERSION", "GOROOT"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                return nil
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            let rawVersion = lines.first ?? ""
            let goroot = lines.count > 1 ? lines[1] : ""
            let displayVersion = ToolchainHealthInfo.display(rawVersion)
            guard !displayVersion.isEmpty else { return nil }
            return HostGoToolchainStatus(
                version: displayVersion,
                goBinaryPath: binaryPath,
                goroot: goroot,
                isCustom: isCustom
            )
        }.value
    }

    func detectHostGoToolchain() async -> HostGoToolchainStatus? {
        let custom = customGoBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, let info = await Self.inspectGoBinary(at: custom, isCustom: true) {
            return info
        }
        guard let found = Self.findTool("go") else { return nil }
        return await Self.inspectGoBinary(at: found, isCustom: false)
    }

    func getGoExecutablePath() -> String {
        let custom = customGoBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        return Self.findTool("go") ?? "/usr/local/go/bin/go"
    }

    func fetchRuntimeDiagnostics() -> RuntimeDiagnosticsData {
        guard let cPtr = GetGoRuntimeDiagnostics() else { return .empty }
        defer { FreeGoCString(cPtr) }
        let jsonStr = String(cString: cPtr)
        return (try? JSONDecoder().decode(RuntimeDiagnosticsData.self, from: Data(jsonStr.utf8))) ?? .empty
    }
}
