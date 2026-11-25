import Foundation
import MetricKit
import OSLog

final class MetricKitDiagnosticsStore: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticsStore()

    private let lock = NSLock()
    private var isStarted = false
    private let maxStoredFiles = 20

    let directoryURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("GoLens", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    private override init() {
        super.init()
    }

    func start() {
        lock.lock()
        let shouldStart = !isStarted
        isStarted = true
        lock.unlock()
        guard shouldStart else { return }
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persistPayloads(kind: "metrics", payloads: payloads.map { $0.jsonRepresentation() })
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persistPayloads(kind: "diagnostics", payloads: payloads.map { $0.jsonRepresentation() })
    }

    func loadSavedSummary(limit: Int = 5) -> String {
        let fm = FileManager.default
        let storageDisplay = DiagnosticsRedactor.redact(directoryURL.path)
        guard fm.fileExists(atPath: directoryURL.path),
              let urls = try? fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return emptyStatusText(storagePath: storageDisplay)
        }

        let jsonFiles = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)

        guard !jsonFiles.isEmpty else {
            return emptyStatusText(storagePath: storageDisplay)
        }

        var parts: [String] = ["Storage: \(storageDisplay)"]
        var totalChars = 0
        let maxChars = 24_000
        for file in jsonFiles {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let redacted = DiagnosticsRedactor.redact(raw)
            let block = "=== \(file.lastPathComponent) ===\n\(redacted)"
            if totalChars + block.count > maxChars {
                let remaining = max(0, maxChars - totalChars)
                if remaining > 120 {
                    parts.append(String(block.prefix(remaining)) + "\n[Truncated]")
                }
                break
            }
            parts.append(block)
            totalChars += block.count
        }
        return DiagnosticsRedactor.redact(parts.joined(separator: "\n\n"))
    }

    private func emptyStatusText(storagePath: String) -> String {
        DiagnosticsRedactor.redact(
            "Storage: \(storagePath)\nStatus: Subscribed to MetricKit (MXMetricManager). No metric or diagnostic payloads have been delivered by macOS yet."
        )
    }

    private func persistPayloads(kind: String, payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        for (index, data) in payloads.enumerated() {
            guard let raw = String(data: data, encoding: .utf8) else { continue }
            let redacted = DiagnosticsRedactor.redact(raw)
            let filename = "metrickit-\(kind)-\(stamp)-\(index + 1).json"
            let target = directoryURL.appendingPathComponent(filename)
            try? redacted.write(to: target, atomically: true, encoding: .utf8)
        }

        pruneOldFiles()
    }

    private func pruneOldFiles() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if sorted.count > maxStoredFiles {
            for obsolete in sorted.dropFirst(maxStoredFiles) {
                try? fm.removeItem(at: obsolete)
            }
        }
    }
}

private struct ToolchainReport: Decodable {
    let goPath: String?
    let goVersion: String?
    let toolchain: String?
    let toolchainSource: String?
    let effective: String?
    let required: String?
    let directive: String?
    let requiredBy: String?
    let goplsPath: String?
    let goplsGo: String?
    let goplsVersion: String?
    let goTooOld: Bool?
    let goplsOutdated: Bool?
    let buildWith: String?
}

enum DiagnosticsCollector {
    private struct WorkspaceSnapshot: Sendable {
        let activeWorkspacePath: String
        let languageServerStatus: String

        var projectPaths: [String] {
            guard !activeWorkspacePath.isEmpty else { return [] }
            let resolved = URL(fileURLWithPath: activeWorkspacePath).resolvingSymlinksInPath().path
            return Array(Set([activeWorkspacePath, resolved]))
        }
    }

    @MainActor
    private static func captureSnapshot() -> WorkspaceSnapshot {
        let workspace = WorkspaceSessionRegistry.shared.activeWorkspace
        return WorkspaceSnapshot(
            activeWorkspacePath: workspace.activeWorkspacePath,
            languageServerStatus: describeLanguageServerState(workspace.languageServerState)
        )
    }

    @MainActor
    private static func describeLanguageServerState(_ state: LanguageServerState) -> String {
        switch state {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .indexing(let detail):
            return detail.isEmpty ? "Indexing" : "Indexing (\(detail))"
        case .ready:
            return "Ready"
        case .crashed(let reason, let retryIn):
            return "Crashed (\(reason); retry in \(retryIn)s)"
        case .restarting:
            return "Restarting"
        case .missing:
            return "Missing"
        }
    }

    static func collectInitial() async -> [DiagnosticItem] {
        MetricKitDiagnosticsStore.shared.start()
        let snapshot = await captureSnapshot()

        return await Task.detached(priority: .userInitiated) {
            async let systemContent = collectSystemInfo()
            async let toolchainContent = collectToolchainInfo(snapshot: snapshot)
            async let logsContent = collectLogs(projectPaths: snapshot.projectPaths, includeOSLog: false)
            async let metricKitContent = MetricKitDiagnosticsStore.shared.loadSavedSummary()

            let (sys, tc, logs, mk) = await (systemContent, toolchainContent, logsContent, metricKitContent)

            return [
                DiagnosticItem(
                    id: "system",
                    title: "App & System",
                    filename: "system-info.txt",
                    summary: "GoLens version, macOS version, architecture and memory.",
                    content: sys,
                    isIncluded: true
                ),
                DiagnosticItem(
                    id: "toolchain",
                    title: "Go & gopls Toolchain",
                    filename: "toolchain-health.txt",
                    summary: "Go and gopls versions, the toolchain the project needs and the language server state.",
                    content: tc,
                    isIncluded: true
                ),
                DiagnosticItem(
                    id: "logs",
                    title: "GoLens Logs",
                    filename: "golens-logs.txt",
                    summary: "Recent GoLens log entries, without program output, secrets or project and home folder paths.",
                    content: logs,
                    isIncluded: true
                ),
                DiagnosticItem(
                    id: "metrickit",
                    title: "MetricKit Diagnostics",
                    filename: "metrickit-diagnostics.json",
                    summary: "Local MetricKit performance and crash payloads saved under Application Support.",
                    content: mk,
                    isIncluded: true
                )
            ]
        }.value
    }

    static func collectFullLogs() async -> String {
        let snapshot = await captureSnapshot()
        return await Task.detached(priority: .utility) {
            collectLogs(projectPaths: snapshot.projectPaths, includeOSLog: true)
        }.value
    }

    static func collectAll() async -> [DiagnosticItem] {
        let initial = await collectInitial()
        let fullLogs = await collectFullLogs()
        return initial.map { item in
            guard item.id == "logs" else { return item }
            return DiagnosticItem(
                id: item.id,
                title: item.title,
                filename: item.filename,
                summary: item.summary,
                content: fullLogs,
                isIncluded: item.isIncluded
            )
        }
    }

    private static func collectSystemInfo() -> String {
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleName"] as? String) ?? "GoLens"
        let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? "Unknown"
        let buildNumber = (info?["CFBundleVersion"] as? String) ?? "Unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "Unknown"

        let process = ProcessInfo.processInfo
        let osVersion = process.operatingSystemVersionString
        let memory = UserMessage.byteCount(Int64(process.physicalMemory), style: .memory)
        let architecture = machineArchitecture()

        let lines = [
            "App: \(appName) \(shortVersion) (Build \(buildNumber))",
            "Bundle Identifier: \(bundleID)",
            "macOS: \(osVersion)",
            "Architecture: \(architecture)",
            "Logical CPUs: \(process.processorCount)",
            "Physical Memory: \(memory)"
        ]
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n"))
    }

    private static func machineArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let bytes = withUnsafeBytes(of: &sysinfo.machine) { raw in
            raw.prefix { $0 != 0 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func collectToolchainInfo(snapshot: WorkspaceSnapshot) -> String {
        let root = snapshot.activeWorkspacePath
        let rawJSON: String? = root.withCString { cRoot in
            guard let ptr = ToolchainHealth(cRoot) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }

        var lines: [String] = []
        if let rawJSON,
           let data = rawJSON.data(using: .utf8),
           let report = try? JSONDecoder().decode(ToolchainReport.self, from: data) {
            lines.append("Go Version: \(nonEmpty(report.goVersion, fallback: "Not detected"))")
            lines.append("Toolchain: \(nonEmpty(report.toolchain, fallback: "Default"))")
            if let source = report.toolchainSource, !source.isEmpty {
                lines.append("Toolchain Source: \(source)")
            }
            if let effective = report.effective, !effective.isEmpty {
                lines.append("Effective Version: \(effective)")
            }
            if let required = report.required, !required.isEmpty {
                lines.append("Required Version: \(required)")
            }
            if let directive = report.directive, !directive.isEmpty {
                lines.append("Directive: \(directive)")
            }
            lines.append("gopls Version: \(nonEmpty(report.goplsVersion, fallback: "Not detected"))")
            if let goplsGo = report.goplsGo, !goplsGo.isEmpty {
                lines.append("gopls Built With Go: \(goplsGo)")
            }
            if let buildWith = report.buildWith, !buildWith.isEmpty {
                lines.append("Build Environment: \(buildWith)")
            }
            lines.append("Go Too Old: \((report.goTooOld ?? false) ? "Yes" : "No")")
            lines.append("gopls Outdated: \((report.goplsOutdated ?? false) ? "Yes" : "No")")
        } else {
            lines.append("Toolchain probe returned no structured report.")
        }

        lines.append("Language Server State: \(snapshot.languageServerStatus)")
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n"), projectPaths: snapshot.projectPaths)
    }

    private static func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private static func collectLogs(projectPaths: [String], includeOSLog: Bool) -> String {
        var sections: [String] = []

        if includeOSLog {
            let osLogTail = readCurrentProcessOSLogs(limit: 120)
            if !osLogTail.isEmpty {
                sections.append("=== Process Logs ===\n" + osLogTail.joined(separator: "\n"))
            }
        }

        let fileLogsTail = readLogDirectoryTail()
        if !fileLogsTail.isEmpty {
            sections.append(fileLogsTail)
        }

        if sections.isEmpty {
            return includeOSLog
                ? "No log entries recorded in this session."
                : "Reading this session’s log…"
        }

        let combined = sections.joined(separator: "\n\n")
        let maxChars = 32_000
        let clipped = combined.count > maxChars ? String(combined.suffix(maxChars)) : combined
        return DiagnosticsRedactor.redact(clipped, projectPaths: projectPaths)
    }

    private static func readCurrentProcessOSLogs(limit: Int) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: since)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]

            var lines: [String] = []
            for entry in entries {
                let message = entry.composedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { continue }
                let stamp = formatter.string(from: entry.date)
                if let logEntry = entry as? OSLogEntryLog {
                    let category = logEntry.category.isEmpty ? "app" : logEntry.category
                    lines.append("[\(stamp)] [\(category)] \(message)")
                } else {
                    lines.append("[\(stamp)] \(message)")
                }
            }
            return Array(lines.suffix(limit))
        } catch {
            return []
        }
    }

    private static func readLogDirectoryTail() -> String {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return ""
        }
        let logsDir = library.appendingPathComponent("Logs/GoLens", isDirectory: true)
        guard fm.fileExists(atPath: logsDir.path),
              let entries = try? fm.contentsOfDirectory(
                at: logsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return ""
        }

        let files = entries
            .filter { ["log", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(2)

        var chunks: [String] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tail = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n")
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append("=== \(file.lastPathComponent) ===\n\(tail)")
            }
        }
        return chunks.joined(separator: "\n\n")
    }
}
