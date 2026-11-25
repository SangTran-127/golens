import AppKit
import CryptoKit
import Foundation

struct UnsavedBufferEntry: Codable, Equatable {
    let path: String
    let text: String
    let savedAt: Date
}

@MainActor
final class UnsavedBufferJournal {
    static let shared = UnsavedBufferJournal()

    static let writeDelay: TimeInterval = 2
    static let maxBytes = 5_000_000

    private let liveDirectory: URL
    private let pendingDirectory: URL
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var pending: [UnsavedBufferEntry]
    private var offeredWorkspaces: Set<String> = []
    private var reportedWriteFailure = false
    private let isEnabled = ProcessInfo.processInfo.environment["GOLENS_UNSAVED_RECOVERY"] != "off"

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "GoLens", isDirectory: true)
            .appendingPathComponent("UnsavedBuffers", isDirectory: true)
        liveDirectory = root.appendingPathComponent("live", isDirectory: true)
        pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
        for dir in [liveDirectory, pendingDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in (try? fm.contentsOfDirectory(atPath: liveDirectory.path)) ?? [] {
            let from = liveDirectory.appendingPathComponent(name)
            let to = pendingDirectory.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
        pending = Self.entries(in: pendingDirectory)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UnsavedBufferJournal.shared.clearLive() }
        }
    }

    func noteEdit(_ session: DocumentSession) {
        guard isEnabled else { return }
        let path = session.path
        writeTasks[path]?.cancel()
        writeTasks[path] = Task { @MainActor [weak session] in
            try? await Task.sleep(nanoseconds: UInt64(Self.writeDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.writeTasks[path] = nil
            guard let session, session.workspace?.documents[path] === session, session.isEdited else {
                self.remove(path)
                return
            }
            self.write(path: path, text: session.storage.string, workspace: session.workspace)
        }
    }

    nonisolated static func forget(_ path: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.documentDidSaveOrClose(path) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { shared.documentDidSaveOrClose(path) } }
        }
    }

    func documentDidSaveOrClose(_ path: String) {
        writeTasks[path]?.cancel()
        writeTasks[path] = nil
        remove(path)
    }

    func offerRecovery(for workspace: WorkspaceState, workspacePath: String) {
        guard isEnabled, !workspacePath.isEmpty, !offeredWorkspaces.contains(workspacePath) else { return }
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        let entries = pending.filter { $0.path.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0.path) }
        guard !entries.isEmpty else { return }
        offeredWorkspaces.insert(workspacePath)
        let names = entries.map { ($0.path as NSString).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Restore Unsaved Changes?" : "Restore Unsaved Changes in \(entries.count) Files?"
        alert.informativeText = "GoLens quit before these changes were saved: \(ListFormatter.localizedString(byJoining: names)). Restore opens the files with your changes, unsaved. The files on disk stay as they are until you save."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard Changes")
        workspace.present(alert) { [weak workspace] response in
            MainActor.assumeIsolated {
                let journal = UnsavedBufferJournal.shared
                if response == .alertFirstButtonReturn, let workspace {
                    journal.restore(entries, in: workspace)
                }
                journal.discardPending(entries)
            }
        }
    }

    private func restore(_ entries: [UnsavedBufferEntry], in workspace: WorkspaceState) {
        for entry in entries {
            guard let session = workspace.openBackgroundDocument(entry.path), session.storage.string != entry.text else { continue }
            workspace.applyRanges([(NSRange(location: 0, length: session.storage.length), entry.text)], in: session, actionName: "Restore Unsaved Changes")
        }
        if let first = entries.first {
            workspace.openFile(first.path)
        }
    }

    private func discardPending(_ entries: [UnsavedBufferEntry]) {
        let paths = Set(entries.map(\.path))
        pending.removeAll { paths.contains($0.path) }
        for path in paths {
            try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent(Self.fileName(for: path)))
        }
    }

    private func write(path: String, text: String, workspace: WorkspaceState?) {
        guard text.utf8.count <= Self.maxBytes else {
            remove(path)
            return
        }
        let entry = UnsavedBufferEntry(path: path, text: text, savedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let url = liveDirectory.appendingPathComponent(Self.fileName(for: path))
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            reportedWriteFailure = false
        } catch {
            NSLog("GoLens could not keep a recovery copy of %@: %@", path, error.localizedDescription)
            guard !reportedWriteFailure, let workspace else { return }
            reportedWriteFailure = true
            workspace.presentCommandFeedback(
                "GoLens couldn’t keep a copy of your unsaved changes in case it quits unexpectedly. \(error.localizedDescription) Save your files to keep your work safe.",
                title: "Unsaved Changes Aren’t Protected",
                tone: .warning
            )
        }
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(at: liveDirectory.appendingPathComponent(Self.fileName(for: path)))
    }

    private func clearLive() {
        for task in writeTasks.values { task.cancel() }
        writeTasks.removeAll()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: liveDirectory.path)) ?? [] {
            try? FileManager.default.removeItem(at: liveDirectory.appendingPathComponent(name))
        }
    }

    private static func fileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private static func entries(in directory: URL) -> [UnsavedBufferEntry] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap { name in
            guard let data = fm.contents(atPath: directory.appendingPathComponent(name).path) else { return nil }
            return try? JSONDecoder().decode(UnsavedBufferEntry.self, from: data)
        }
    }
}
