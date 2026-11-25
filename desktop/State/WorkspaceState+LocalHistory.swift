import Foundation
import SwiftUI

struct LocalHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let label: String
    let content: String
    let lineCount: Int
    let byteCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        label: String,
        content: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.content = content
        var lines = 1
        for b in content.utf8 where b == 0x0A {
            lines += 1
        }
        self.lineCount = lines
        self.byteCount = content.utf8.count
    }
}

private let localHistoryIOQueue = DispatchQueue(label: "golens.local-history.io", qos: .utility)

extension WorkspaceState {
    static let maxLocalHistoryEntriesPerFile = 15
    static let maxLocalHistoryFileBytes = 256 * 1024

    private func localHistoryStorageURL(for filePath: String) -> URL? {
        guard !activeWorkspacePath.isEmpty else { return nil }
        let rel = projectRelativePath(filePath)
        var hash: UInt64 = 14695981039346656037
        for byte in rel.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let baseName = (filePath as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileName = String(format: "%@-%016llx.json", baseName, hash)
        return URL(fileURLWithPath: activeWorkspacePath)
            .appendingPathComponent(".golens", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    @discardableResult
    func recordLocalHistorySnapshot(for filePath: String, content: String, label: String = "Saved", synchronous: Bool = false) -> Bool {
        let byteLen = content.utf8.count
        guard !filePath.isEmpty,
              byteLen > 0,
              byteLen <= Self.maxLocalHistoryFileBytes,
              let storageURL = localHistoryStorageURL(for: filePath) else {
            return false
        }
        let maxEntries = Self.maxLocalHistoryEntriesPerFile
        let workspacePath = activeWorkspacePath
        let write: () -> Bool = {
            let fm = FileManager.default
            let dirURL = storageURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dirURL.path) {
                try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            }
            let ignoreURL = dirURL.appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignoreURL.path) {
                try? "*\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
            }
            Self.excludeLocalHistoryFromGit(workspacePath: workspacePath)
            var existing: [LocalHistoryEntry] = []
            if let data = try? Data(contentsOf: storageURL) {
                if let decoded = try? JSONDecoder().decode([LocalHistoryEntry].self, from: data) {
                    existing = decoded
                } else {
                    let keptURL = storageURL.appendingPathExtension("unreadable")
                    try? fm.removeItem(at: keptURL)
                    guard (try? fm.moveItem(at: storageURL, to: keptURL)) != nil else { return false }
                }
            }
            if let newest = existing.first, newest.content == content {
                return true
            }
            let entry = LocalHistoryEntry(label: label, content: content)
            existing.insert(entry, at: 0)
            if existing.count > maxEntries {
                existing = Array(existing.prefix(maxEntries))
            }
            var written = false
            if let encoded = try? JSONEncoder().encode(existing) {
                written = (try? encoded.write(to: storageURL, options: .atomic)) != nil
            }
            let snapshotList = existing
            DispatchQueue.main.async {
                if self.showLocalHistorySheet && self.localHistoryTargetPath == filePath {
                    self.localHistoryEntries = snapshotList
                }
            }
            return written
        }
        if synchronous { return localHistoryIOQueue.sync(execute: write) }
        localHistoryIOQueue.async { _ = write() }
        return true
    }

    private static func excludeLocalHistoryFromGit(workspacePath: String) {
        let excludePath = (workspacePath as NSString).appendingPathComponent(".git/info/exclude")
        let entry = ".golens/history/"
        guard FileManager.default.fileExists(atPath: excludePath),
              let existing = try? String(contentsOfFile: excludePath, encoding: .utf8),
              !existing.contains(entry) else { return }
        let updated = existing.hasSuffix("\n") ? existing + entry + "\n" : existing + "\n" + entry + "\n"
        try? updated.write(toFile: excludePath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func recordLocalHistoryBeforeDiscard(for filePath: String) -> Bool {
        if let doc = documents[filePath] {
            return recordLocalHistorySnapshot(for: filePath, content: doc.storage.string, label: "Before Git Discard", synchronous: true)
        }
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return false }
        let data = (try? handle.read(upToCount: Self.maxLocalHistoryFileBytes + 1)) ?? Data()
        try? handle.close()
        guard data.count > 0, data.count <= Self.maxLocalHistoryFileBytes,
              let text = String(data: data, encoding: .utf8) else { return false }
        return recordLocalHistorySnapshot(for: filePath, content: text, label: "Before Git Discard", synchronous: true)
    }

    func presentLocalHistory(for filePath: String? = nil) {
        let target = (filePath?.isEmpty == false ? filePath! : activeFilePath)
        guard !target.isEmpty else { return }
        localHistoryTargetPath = target
        localHistoryEntries = []
        showLocalHistorySheet = true
        guard let storageURL = localHistoryStorageURL(for: target) else { return }
        localHistoryIOQueue.async {
            var loaded: [LocalHistoryEntry] = []
            if let data = try? Data(contentsOf: storageURL),
               let decoded = try? JSONDecoder().decode([LocalHistoryEntry].self, from: data) {
                loaded = decoded
            }
            let entries = loaded
            DispatchQueue.main.async {
                if self.localHistoryTargetPath == target {
                    self.localHistoryEntries = entries
                }
            }
        }
    }

    func restoreLocalHistoryEntry(_ entry: LocalHistoryEntry, for filePath: String, onComplete: @escaping (Bool) -> Void = { _ in }) {
        guard !filePath.isEmpty else {
            onComplete(false)
            return
        }
        if let session = documents[filePath] {
            let currentText = session.storage.string
            if currentText != entry.content {
                recordLocalHistorySnapshot(for: filePath, content: currentText, label: "Before Restore")
            }
            openFile(filePath)
            let fullRange = NSRange(location: 0, length: session.storage.length)
            if let tv = activeTextView as? GoLensTextView, tv.document === session,
               tv.shouldChangeText(in: fullRange, replacementString: entry.content) {
                tv.textStorage?.replaceCharacters(in: fullRange, with: entry.content)
                tv.didChangeText()
            } else {
                session.replaceAll(with: entry.content)
                documentDidEdit(session)
            }
            save(session, reportsFailure: true, then: onComplete)
        } else {
            if let existingDisk = try? String(contentsOfFile: filePath, encoding: .utf8),
               existingDisk != entry.content {
                recordLocalHistorySnapshot(for: filePath, content: existingDisk, label: "Before Restore")
            }
            do {
                try entry.content.write(toFile: filePath, atomically: true, encoding: .utf8)
            } catch {
                presentFailure(
                    "Couldn’t Restore “\((filePath as NSString).lastPathComponent)”",
                    "\(Self.failureReason(error)) The file wasn’t changed. Check that you can write to it, then try again.",
                    recovery: ("Try Again", { [weak self] in self?.restoreLocalHistoryEntry(entry, for: filePath, onComplete: onComplete) }),
                    revealing: filePath,
                    dismissed: { onComplete(false) }
                )
                return
            }
            openFile(filePath)
            onComplete(true)
        }
    }
}
