import Foundation

extension WorkspaceState {
    func fetchLineGitBlameSummary(forPath path: String, line: Int) async -> String? {
        let workspacePath = activeWorkspacePath
        guard !workspacePath.isEmpty, !path.isEmpty, line >= 1 else { return nil }
        let relPath = Self.gitRelativePath(forAbsolutePath: path, from: workspacePath)
        guard !relPath.isEmpty, !relPath.hasPrefix("../") else { return nil }

        if await MainActor.run(body: { self.isUntrackedPath(path) }) {
            return "Uncommitted changes"
        }

        let isModifiedLineInDiff = await MainActor.run {
            self.activeFilePath == path && self.git.activeFileDiffs[line] != nil
        }
        if isModifiedLineInDiff {
            let isDocumentEdited = await MainActor.run {
                self.documentSession(forPath: path)?.isEdited == true
            }
            if isDocumentEdited {
                return "Uncommitted changes"
            }
        }

        guard let blame = await fileBlame(forPath: path, relativePath: relPath, workspacePath: workspacePath),
              let entry = blame.entry(forLine: line) else {
            return isModifiedLineInDiff ? "Uncommitted changes" : nil
        }
        let sha = entry.sha
        if sha.count == 40 && sha.allSatisfy({ $0 == "0" }) {
            return "Uncommitted changes"
        }

        let author = entry.commit.author
        let authorTime = entry.commit.authorTime
        let summary = entry.commit.summary

        if author == "Not Committed Yet" {
            return "Uncommitted changes"
        }
        guard !author.isEmpty else { return nil }

        let relTime: String
        if let ts = authorTime {
            let elapsed = max(0, Date().timeIntervalSince1970 - ts)
            if elapsed < 60 {
                relTime = "just now"
            } else if elapsed < 3600 {
                relTime = "\(Int(elapsed / 60))m ago"
            } else if elapsed < 86400 {
                relTime = "\(Int(elapsed / 3600))h ago"
            } else if elapsed < 86400 * 30 {
                relTime = "\(Int(elapsed / 86400))d ago"
            } else {
                relTime = Date(timeIntervalSince1970: ts).formatted(.iso8601.year().month().day())
            }
        } else {
            relTime = "just now"
        }

        if summary.isEmpty {
            return "\(author), \(relTime)"
        }
        return "\(author), \(relTime) — \(summary)"
    }

    func fileBlame(forPath path: String, relativePath: String, workspacePath: String) async -> GitFileBlame? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = attributes?[.size] as? Int ?? -1
        let task: Task<GitFileBlame?, Never> = await MainActor.run {
            let key = "\(workspacePath)|\(modified)|\(size)|\(self.blameHeadHash ?? self.git.recentCommits.first?.hash ?? "")"
            if let cached = self.fileBlameCache[path], cached.key == key {
                return cached.task
            }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> GitFileBlame? in
                guard let self,
                      let output = try? await self.runGit(args: ["--no-optional-locks", "blame", "--porcelain", "--", relativePath], in: workspacePath) else { return nil }
                return GitFileBlame(porcelain: output)
            }
            if self.fileBlameCache.count >= 32 { self.fileBlameCache.removeAll() }
            self.fileBlameCache[path] = (key, task)
            return task
        }
        return await task.value
    }

    func refreshBlameHead() async {
        let workspacePath = await MainActor.run { self.activeWorkspacePath }
        guard !workspacePath.isEmpty else { return }
        let head = (try? await runGit(args: ["--no-optional-locks", "rev-parse", "--verify", "-q", "HEAD"], in: workspacePath))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            guard self.activeWorkspacePath == workspacePath else { return }
            self.setBlameHead(head)
        }
    }

    func setBlameHead(_ head: String) {
        guard head != blameHeadHash else { return }
        let hadHead = blameHeadHash != nil
        blameHeadHash = head
        if hadHead {
            fileBlameCache.removeAll()
            updateCaretLineBlame()
        }
    }

    func updateCaretLineBlame() {
        transientEditorState.caretBlameTask?.cancel()
        let showBlame = UserDefaults.standard.object(forKey: "GoLensShowInlineGitBlame") as? Bool ?? true
        guard showBlame, !activeFilePath.isEmpty, !activeWorkspacePath.isEmpty else {
            activeLineGitBlame = nil
            activeTextView?.needsDisplay = true
            return
        }
        let path = activeFilePath
        let line = max(1, cursorLine)
        if activeLineGitBlame?.path != path || activeLineGitBlame?.line != line {
            activeLineGitBlame = nil
            activeTextView?.needsDisplay = true
        }
        transientEditorState.caretBlameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            if Task.isCancelled { return }
            let summary = await self.fetchLineGitBlameSummary(forPath: path, line: line)
            if Task.isCancelled { return }
            await MainActor.run {
                guard self.activeFilePath == path, max(1, self.cursorLine) == line else { return }
                let stillEnabled = UserDefaults.standard.object(forKey: "GoLensShowInlineGitBlame") as? Bool ?? true
                guard stillEnabled, let summary, !summary.isEmpty else {
                    self.activeLineGitBlame = nil
                    self.activeTextView?.needsDisplay = true
                    return
                }
                self.activeLineGitBlame = (path: path, line: line, text: summary)
                self.activeTextView?.needsDisplay = true
            }
        }
    }
}

struct GitFileBlame {
    struct Commit {
        var author = ""
        var authorTime: TimeInterval?
        var summary = ""
    }

    private var lineCommits: [String] = []
    private var commits: [String: Commit] = [:]

    init(porcelain output: String) {
        var lineCommits: [String] = []
        var commits: [String: Commit] = [:]
        var current: String?
        for bytes in output.utf8.split(separator: UInt8(ascii: "\n")) {
            if bytes.first == UInt8(ascii: "\t") { continue }
            let line = String(decoding: bytes, as: UTF8.self)
            let fields = line.split(separator: " ", maxSplits: 3)
            if fields.count >= 3, fields[0].count == 40, fields[0].allSatisfy(\.isHexDigit), let finalLine = Int(fields[2]), finalLine >= 1 {
                let sha = String(fields[0])
                current = sha
                if lineCommits.count < finalLine {
                    lineCommits.append(contentsOf: repeatElement("", count: finalLine - lineCommits.count))
                }
                lineCommits[finalLine - 1] = sha
                if commits[sha] == nil { commits[sha] = Commit() }
                continue
            }
            guard let sha = current else { continue }
            if line.hasPrefix("author ") {
                commits[sha]?.author = String(line.dropFirst("author ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("author-time ") {
                commits[sha]?.authorTime = TimeInterval(String(line.dropFirst("author-time ".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if line.hasPrefix("summary ") {
                commits[sha]?.summary = String(line.dropFirst("summary ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        self.lineCommits = lineCommits
        self.commits = commits
    }

    func entry(forLine line: Int) -> (sha: String, commit: Commit)? {
        guard line >= 1, line <= lineCommits.count else { return nil }
        let sha = lineCommits[line - 1]
        guard !sha.isEmpty, let commit = commits[sha] else { return nil }
        return (sha, commit)
    }
}
