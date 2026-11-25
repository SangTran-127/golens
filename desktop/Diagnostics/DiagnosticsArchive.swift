import Foundation

struct DiagnosticItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let filename: String
    let summary: String
    let content: String
    var isIncluded: Bool
    var byteCount: Int { content.utf8.count }
}

enum DiagnosticsArchiveError: LocalizedError, Sendable {
    case noIncludedItems
    case archiveCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noIncludedItems:
            return "Select at least one diagnostic item before exporting."
        case .archiveCreationFailed(let detail):
            return "Couldn’t create the diagnostics archive: \(detail)"
        }
    }
}

enum DiagnosticsArchiveExporter {
    static func includedItems(from items: [DiagnosticItem]) -> [DiagnosticItem] {
        items.filter(\.isIncluded)
    }

    static func exportArchive(items: [DiagnosticItem], to destinationURL: URL) throws {
        let selected = includedItems(from: items)
        guard !selected.isEmpty else {
            throw DiagnosticsArchiveError.noIncludedItems
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("golens-diag-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        var usedNames = Set<String>()
        var stagedFiles: [String] = []
        for (idx, item) in selected.enumerated() {
            let base = sanitizeFilename(item.filename, fallbackIndex: idx)
            var uniqueName = base
            var suffix = 2
            while usedNames.contains(uniqueName) {
                let ns = base as NSString
                let ext = ns.pathExtension
                let stem = ns.deletingPathExtension
                uniqueName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            usedNames.insert(uniqueName)
            let fileURL = stagingDir.appendingPathComponent(uniqueName)
            let redacted = DiagnosticsRedactor.redact(item.content)
            try redacted.write(to: fileURL, atomically: true, encoding: .utf8)
            stagedFiles.append(uniqueName)
        }

        let tempZip = stagingDir.appendingPathComponent("archive.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = stagingDir
        proc.arguments = ["-j", "-q", tempZip.path] + stagedFiles
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fm.fileExists(atPath: tempZip.path) else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DiagnosticsArchiveError.archiveCreationFailed(errMsg.isEmpty ? "exit \(proc.terminationStatus)" : errMsg)
        }

        let parent = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempZip, to: destinationURL)
    }

    private static func sanitizeFilename(_ raw: String, fallbackIndex: Int) -> String {
        let leaf = URL(fileURLWithPath: raw).lastPathComponent
        let cleaned = leaf.replacingOccurrences(of: "/", with: "-")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "diagnostic-\(fallbackIndex + 1).txt"
        }
        return cleaned
    }
}
