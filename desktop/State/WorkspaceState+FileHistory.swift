import Foundation
import SwiftUI
import AppKit

struct FileHistoryEntry: Identifiable, Equatable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date?
    let gitRelativeDate: String
    let status: String
    let path: String
    let previousPath: String?

    var isRename: Bool { status.hasPrefix("R") && previousPath != nil }
}

enum FileHistoryLogParser {
    static let recordSeparator: Character = "\u{1e}"
    static let fieldSeparator: Character = "\u{1f}"
    static let format = "--format=%x1e%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%ar"

    static func parse(_ output: String) -> [FileHistoryEntry] {
        let isoFormatter = ISO8601DateFormatter()
        var entries: [FileHistoryEntry] = []
        for record in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { continue }
            let fields = header.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, fields[0].count >= 40 else { continue }
            var status = ""
            var path = ""
            var previousPath: String?
            for line in lines.dropFirst() {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { continue }
                status = parts[0]
                path = parts[parts.count - 1]
                previousPath = (parts.count >= 3 && (status.hasPrefix("R") || status.hasPrefix("C"))) ? parts[1] : nil
            }
            entries.append(FileHistoryEntry(
                hash: fields[0],
                shortHash: fields[1],
                subject: fields[2],
                author: fields[3],
                date: isoFormatter.date(from: fields[4]),
                gitRelativeDate: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
                status: status,
                path: path,
                previousPath: previousPath
            ))
        }
        return entries
    }
}

@MainActor
@Observable
final class FileHistoryModel: Identifiable {
    let id = UUID()
    enum LoadState: Equatable {
        case loading
        case loaded
        case notInRepository
        case untracked
        case noCommits
        case failed(String)
    }

    enum DiffMode: String, CaseIterable, Identifiable {
        case commitChanges = "Changes in Commit"
        case compareWithCurrent = "Compare with Current"
        var id: String { rawValue }
    }

    static let pageSize = 100

    let filePath: String
    private(set) var repoRoot = ""
    private(set) var relativePath = ""
    private(set) var entries: [FileHistoryEntry] = []
    private(set) var loadState: LoadState = .loading
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    var selectedHash: String? {
        didSet { if oldValue != selectedHash { loadDiff() } }
    }
    var diffMode: DiffMode = .commitChanges {
        didSet { if oldValue != diffMode { loadDiff() } }
    }
    private(set) var diffItems: [DisplayDiffItem] = []
    private(set) var diffEstimatedWidth: CGFloat = 0
    private(set) var diffAdded = 0
    private(set) var diffRemoved = 0
    private(set) var isLoadingDiff = false
    private(set) var diffNotice: String?

    private var focusHash: String?
    private var diffTask: Task<Void, Never>?

    init(filePath: String, focusHash: String? = nil) {
        self.filePath = filePath
        self.focusHash = focusHash
    }

    var fileName: String { (filePath as NSString).lastPathComponent }

    var selectedEntry: FileHistoryEntry? {
        guard let selectedHash else { return nil }
        return entries.first { $0.hash == selectedHash }
    }

    weak var workspace: WorkspaceState?
    private var git: WorkspaceState { workspace ?? WorkspaceState.shared }

    func start() {
        Task { await initialLoad() }
    }

    func retry() {
        entries = []
        loadState = .loading
        start()
    }

    private func initialLoad() async {
        let fileURL = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        let directory = fileURL.deletingLastPathComponent().path
        guard let topLevel = try? await git.runGit(args: ["rev-parse", "--show-toplevel"], in: directory) else {
            loadState = .notInRepository
            return
        }
        let root = URL(fileURLWithPath: topLevel.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        guard fileURL.path.hasPrefix(root + "/") else {
            loadState = .notInRepository
            return
        }
        repoRoot = root
        relativePath = String(fileURL.path.dropFirst(root.count + 1))

        do {
            let page = try await fetchLog(count: Self.pageSize)
            if page.isEmpty {
                let tracked = (try? await git.runGit(args: ["ls-files", "--error-unmatch", "--", relativePath], in: root)) != nil
                loadState = tracked ? .noCommits : .untracked
                return
            }
            entries = page
            hasMore = page.count >= Self.pageSize
            loadState = .loaded
            if let focus = focusHash {
                focusHash = nil
                while !entries.contains(where: { $0.hash == focus }), hasMore, entries.count < 2000 {
                    await loadMore()
                }
                selectedHash = entries.contains(where: { $0.hash == focus }) ? focus : entries.first?.hash
            } else {
                selectedHash = entries.first?.hash
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, loadState == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let existing = entries
        let requested = existing.count + Self.pageSize
        guard let all = try? await fetchLog(count: requested) else {
            hasMore = false
            return
        }
        if all.count >= existing.count, zip(all, existing).allSatisfy({ $0.hash == $1.hash }) {
            entries.append(contentsOf: all.dropFirst(existing.count))
        } else {
            entries = all
        }
        hasMore = all.count >= requested
    }

    private func fetchLog(count: Int) async throws -> [FileHistoryEntry] {
        let output = try await git.runGit(args: [
            "-c", "core.quotepath=off", "--no-optional-locks", "log", "--follow", "-M",
            FileHistoryLogParser.format, "--name-status", "--max-count=\(count)",
            "--", relativePath
        ], in: repoRoot)
        return await Task.detached { FileHistoryLogParser.parse(output) }.value
    }

    func loadDiff() {
        diffTask?.cancel()
        guard let entry = selectedEntry else {
            diffItems = []
            diffNotice = nil
            isLoadingDiff = false
            return
        }
        isLoadingDiff = true
        diffNotice = nil
        let mode = diffMode
        let root = repoRoot
        let currentText = currentFileText()
        let baseColor = Color(nsColor: .labelColor)
        diffTask = Task {
            let output: String
            do {
                switch mode {
                case .commitChanges:
                    var paths = [entry.path]
                    if let previous = entry.previousPath { paths.append(previous) }
                    output = try await git.runGit(args: [
                        "-c", "core.quotepath=off", "--no-optional-locks", "show", "--format=", "-M",
                        "--diff-merges=first-parent", "-U3", entry.hash, "--"
                    ] + paths, in: root)
                case .compareWithCurrent:
                    let oldText = try await git.runGit(args: ["--no-optional-locks", "show", "\(entry.hash):\(entry.path)"], in: root)
                    output = await git.diffTexts(old: oldText, new: currentText ?? "", contextFlag: "-U3", in: root)
                }
            } catch {
                if Task.isCancelled { return }
                diffItems = []
                diffEstimatedWidth = 0
                diffAdded = 0
                diffRemoved = 0
                diffNotice = error.localizedDescription
                isLoadingDiff = false
                return
            }
            if Task.isCancelled { return }
            if let notice = GitDiffNotice.message(in: output) {
                diffItems = []
                diffEstimatedWidth = 0
                diffAdded = 0
                diffRemoved = 0
                diffNotice = notice
                isLoadingDiff = false
                return
            }
            let computed = await Task.detached {
                buildDisplayDiffOffMainThread(
                    diffOutput: output,
                    hunks: [],
                    collapseEnabled: true,
                    expandedBlockIds: [],
                    baseTextColor: baseColor
                )
            }.value
            if Task.isCancelled { return }
            diffItems = computed.items
            diffEstimatedWidth = computed.estimatedUnifiedWidth
            diffAdded = computed.addedCount
            diffRemoved = computed.removedCount
            if computed.items.isEmpty {
                if let headerNotice = GitDiffNotice.headerOnlyMessage(in: output) {
                    diffNotice = headerNotice
                } else {
                    switch mode {
                    case .commitChanges:
                        if let previous = entry.previousPath {
                            diffNotice = "Renamed from \(previous) with no content changes."
                        } else {
                            diffNotice = "This commit made no content changes to the file."
                        }
                    case .compareWithCurrent:
                        diffNotice = currentText == nil
                            ? "The file no longer exists on disk."
                            : "The current file is identical to this version."
                    }
                }
            }
            isLoadingDiff = false
        }
    }

    private func currentFileText() -> String? {
        if let doc = git.documents[filePath] {
            return doc.storage.string
        }
        return try? String(contentsOfFile: filePath, encoding: .utf8)
    }


    func copyHash(_ entry: FileHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hash, forType: .string)
    }

    func openVersion(_ entry: FileHistoryEntry) async -> Bool {
        guard let content = try? await git.runGit(args: ["--no-optional-locks", "show", "\(entry.hash):\(entry.path)"], in: repoRoot) else {
            return false
        }
        let name = (entry.path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let versionName = ext.isEmpty ? "\(base)@\(entry.shortHash)" : "\(base)@\(entry.shortHash).\(ext)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("golens-file-history", isDirectory: true)
            .appendingPathComponent(entry.hash, isDirectory: true)
        let url = directory.appendingPathComponent(versionName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        } catch {
            return false
        }
        git.openFile(url.path, readOnly: true)
        return true
    }
}

extension WorkspaceState {
    @MainActor
    func presentFileHistory(for path: String? = nil, focusCaretLine: Bool = false) {
        let paneID = effectiveFocusedPaneID
        let focusedPath = filePath(for: paneID)
        let target = path ?? (focusedPath.isEmpty ? activeFilePath : focusedPath)
        guard !target.isEmpty else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue { return }
        let caretLineForTarget: Int? = if target == focusedPath {
            max(1, paneState(for: paneID).cursorLine)
        } else if target == activeFilePath {
            max(1, primaryPane.cursorLine)
        } else if isSplitMode, target == secondaryFilePath {
            max(1, secondaryPane.cursorLine)
        } else {
            nil
        }
        guard focusCaretLine, let line = caretLineForTarget else {
            let model = FileHistoryModel(filePath: target)
            model.workspace = self
            activeFileHistoryModel = model
            model.start()
            return
        }
        let workspacePath = activeWorkspacePath
        let root = Self.canonicalPath(workspacePath)
        guard !workspacePath.isEmpty, target.hasPrefix(root + "/") else {
            let model = FileHistoryModel(filePath: target)
            model.workspace = self
            activeFileHistoryModel = model
            model.start()
            return
        }
        let relPath = String(target.dropFirst(root.count + 1))
        Task { @MainActor in
            let blame = await self.fileBlame(forPath: target, relativePath: relPath, workspacePath: workspacePath)
            let sha = blame?.entry(forLine: line)?.sha
            let focus = (sha?.allSatisfy { $0 == "0" } ?? true) ? nil : sha
            let model = FileHistoryModel(filePath: target, focusHash: focus)
            model.workspace = self
            self.activeFileHistoryModel = model
            model.start()
        }
    }
}
