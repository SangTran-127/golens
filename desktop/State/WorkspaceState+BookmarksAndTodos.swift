import AppKit
import Foundation
import GoLensFoundation

enum IssuesNavigatorSubtab: String, CaseIterable, Identifiable {
    case issues = "Issues"
    case todos = "TODOs"
    case bookmarks = "Bookmarks"
    case breakpoints = "Breakpoints"

    var id: String { rawValue }
}

struct BookmarkItem: Codable, Identifiable, Equatable, Hashable {
    var path: String
    var line: Int
    var preview: String

    var id: String { "\(path):\(line)" }
}

enum TodoTagKind: String, Codable, CaseIterable, Identifiable {
    case todo = "TODO"
    case fixme = "FIXME"
    case hack = "HACK"
    case note = "NOTE"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .fixme:
            return "exclamationmark.triangle.fill"
        case .hack:
            return "wrench.and.screwdriver.fill"
        case .todo:
            return "checklist"
        case .note:
            return "note.text"
        }
    }

    var sortPriority: Int {
        switch self {
        case .fixme: return 0
        case .hack: return 1
        case .todo: return 2
        case .note: return 3
        }
    }
}

struct WorkspaceTodoItem: Identifiable, Equatable, Hashable {
    let path: String
    let line: Int
    let column: Int
    let tag: TodoTagKind
    let text: String

    var id: String { "\(path):\(line):\(column):\(tag.rawValue)" }
}

extension WorkspaceState {
    static let maxBookmarksPerWorkspace = 200
    static let maxTodoScanFiles = 1500
    static let maxTodoScanFileBytes = 512 * 1024
    static let maxTodoItems = 500

    private var bookmarksStorageKey: String {
        "GoLensBookmarks.\(activeWorkspacePath)"
    }

    func loadBookmarksForWorkspace() {
        guard !activeWorkspacePath.isEmpty else {
            bookmarks = []
            bookmarksByPath = [:]
            searchNav.storedBookmarks = []
            return
        }
        if let data = UserDefaults.standard.data(forKey: bookmarksStorageKey),
           let decoded = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            let valid = decoded.filter { FileManager.default.fileExists(atPath: $0.path) && $0.line >= 1 }
            bookmarks = sortBookmarks(valid)
            searchNav.storedBookmarks = bookmarks
            rebuildBookmarksIndex()
        } else {
            bookmarks = []
            bookmarksByPath = [:]
            searchNav.storedBookmarks = []
        }
    }

    func saveBookmarksForWorkspace() {
        guard !activeWorkspacePath.isEmpty else { return }
        let dirty = Set(bookmarks.map(\.path)).union(searchNav.storedBookmarks.map(\.path)).filter { documents[$0]?.isEdited == true }
        let stored = sortBookmarks(bookmarks.filter { !dirty.contains($0.path) } + searchNav.storedBookmarks.filter { dirty.contains($0.path) })
        searchNav.storedBookmarks = stored
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: bookmarksStorageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: bookmarksStorageKey)
        }
    }

    func bookmarkLinesDidMove(in path: String, to items: [Int: BookmarkItem]) {
        let moved = items.map { line, item -> BookmarkItem in
            var copy = item
            copy.line = line
            return copy
        }
        bookmarks = sortBookmarks(bookmarks.filter { $0.path != path } + moved)
        rebuildBookmarksIndex()
    }

    func restoreSavedBookmarks(for path: String) {
        guard bookmarksByPath[path] != nil || searchNav.storedBookmarks.contains(where: { $0.path == path }) else { return }
        bookmarks = sortBookmarks(bookmarks.filter { $0.path != path } + searchNav.storedBookmarks.filter { $0.path == path })
        rebuildBookmarksIndex()
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func rebuildBookmarksIndex() {
        var index: [String: Set<Int>] = [:]
        for item in bookmarks {
            index[item.path, default: []].insert(item.line)
        }
        bookmarksByPath = index
    }

    func hasBookmark(in path: String, atLine line: Int) -> Bool {
        bookmarksByPath[path]?.contains(line) == true
    }

    func toggleBookmarkAtCaret() {
        guard !activeFilePath.isEmpty else { return }
        let line: Int
        if let tv = activeTextView as? GoLensTextView, tv.filePath == activeFilePath {
            let loc = tv.selectedRange().location
            line = max(1, tv.lineAndCol(forCharacterIndex: loc).line)
        } else {
            line = max(1, cursorLine)
        }
        toggleBookmark(forLine: line, in: activeFilePath)
    }

    func toggleBookmark(forLine line: Int, in rawPath: String) {
        let fullPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        guard !fullPath.isEmpty, line >= 1 else { return }

        if let existingIdx = bookmarks.firstIndex(where: { $0.path == fullPath && $0.line == line }) {
            bookmarks.remove(at: existingIdx)
        } else {
            if bookmarks.count >= Self.maxBookmarksPerWorkspace {
                bookmarks.removeFirst()
            }
            let preview = extractLinePreview(forPath: fullPath, line: line)
            bookmarks.append(BookmarkItem(path: fullPath, line: line, preview: preview))
            bookmarks = sortBookmarks(bookmarks)
        }
        rebuildBookmarksIndex()
        saveBookmarksForWorkspace()
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func removeBookmark(_ item: BookmarkItem) {
        bookmarks.removeAll { $0.id == item.id }
        rebuildBookmarksIndex()
        saveBookmarksForWorkspace()
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func clearAllBookmarks() {
        guard !bookmarks.isEmpty else { return }
        bookmarks.removeAll()
        bookmarksByPath.removeAll()
        saveBookmarksForWorkspace()
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func navigateToNextBookmark() {
        guard !bookmarks.isEmpty else { return }
        let currentPath = activeFilePath
        let currentLine = max(1, cursorLine)

        if let next = bookmarks.first(where: {
            $0.path > currentPath || ($0.path == currentPath && $0.line > currentLine)
        }) ?? bookmarks.first {
            jumpTo(filePath: next.path, line: next.line, column: 1)
        }
    }

    func navigateToPreviousBookmark() {
        guard !bookmarks.isEmpty else { return }
        let currentPath = activeFilePath
        let currentLine = max(1, cursorLine)

        if let prev = bookmarks.last(where: {
            $0.path < currentPath || ($0.path == currentPath && $0.line < currentLine)
        }) ?? bookmarks.last {
            jumpTo(filePath: prev.path, line: prev.line, column: 1)
        }
    }

    func syncBookmarksAfterSave(forPath path: String, content: String) {
        guard let rawTargetLines = bookmarksByPath[path], !rawTargetLines.isEmpty else { return }
        let targetLines = Set(rawTargetLines.lazy.map { max(1, $0) })
        var totalLines = 1
        var collected: [Int: Substring] = [:]
        var lastLine: Substring = ""
        SourceLineScanner.enumerateLines(in: content) { lineNumber, line, _ in
            totalLines = lineNumber
            lastLine = line
            if targetLines.contains(lineNumber) {
                collected[lineNumber] = line
            }
        }
        let maxLine = max(1, totalLines)
        var changed = false
        var seenLines = Set<Int>()
        var updated: [BookmarkItem] = []

        for var bm in bookmarks {
            guard bm.path == path else {
                updated.append(bm)
                continue
            }
            let clampedLine = min(max(1, bm.line), maxLine)
            guard seenLines.insert(clampedLine).inserted else {
                changed = true
                continue
            }
            let rawLine = (collected[clampedLine] ?? lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = rawLine.count > 140 ? String(rawLine.prefix(140)) + "…" : rawLine
            if bm.line != clampedLine || bm.preview != clipped {
                bm.line = clampedLine
                bm.preview = clipped
                changed = true
            }
            updated.append(bm)
        }

        if changed {
            bookmarks = sortBookmarks(updated)
            rebuildBookmarksIndex()
            saveBookmarksForWorkspace()
            (activeTextView as? GoLensTextView)?.redrawGutter()
        }
    }

    func updateBookmarksAndTodosForRenamedPath(from oldPath: String, to newPath: String) {
        var bmChanged = false
        for i in bookmarks.indices {
            if bookmarks[i].path == oldPath {
                bookmarks[i].path = newPath
                bmChanged = true
            } else if bookmarks[i].path.hasPrefix(oldPath + "/") {
                bookmarks[i].path = newPath + String(bookmarks[i].path.dropFirst(oldPath.count))
                bmChanged = true
            }
        }
        if bmChanged {
            bookmarks = sortBookmarks(bookmarks)
            rebuildBookmarksIndex()
            saveBookmarksForWorkspace()
        }

        if !workspaceTodos.isEmpty {
            refreshWorkspaceTodos()
        }
    }

    private func sortBookmarks(_ list: [BookmarkItem]) -> [BookmarkItem] {
        list.sorted { a, b in
            if a.path != b.path { return a.path < b.path }
            return a.line < b.line
        }
    }

    func extractLinePreview(forPath path: String, line: Int) -> String {
        let text: String?
        if let doc = documents[path] {
            text = doc.storage.string
        } else {
            text = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let text else { return "Line \(line)" }
        var currentLine = 1
        var result = ""
        text.enumerateLines { lineStr, stop in
            if currentLine == line {
                let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                result = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
                stop = true
            }
            currentLine += 1
        }
        return result.isEmpty ? "Line \(line)" : result
    }

    func refreshWorkspaceTodos() {
        todoScanTask?.cancel()
        let root = activeWorkspacePath
        guard !root.isEmpty else {
            workspaceTodos = []
            todosByFileCache = [:]
            isScanningTodos = false
            return
        }

        todoScanGeneration &+= 1
        let generation = todoScanGeneration
        isScanningTodos = true

        todoScanTask = Task.detached(priority: .utility) { [weak self] in
            let candidateFiles = Self.collectScannableFiles(inRoot: root, limit: Self.maxTodoScanFiles)
            guard !Task.isCancelled else { return }

            var byFile: [String: [WorkspaceTodoItem]] = [:]
            var allItems: [WorkspaceTodoItem] = []
            allItems.reserveCapacity(min(128, Self.maxTodoItems))

            for filePath in candidateFiles {
                if Task.isCancelled { return }
                if allItems.count >= Self.maxTodoItems { break }

                autoreleasepool {
                    let remainingBudget = Self.maxTodoItems - allItems.count
                    let items = Self.scanTodosInFile(atPath: filePath, content: nil, maxItems: remainingBudget)
                    if !items.isEmpty {
                        byFile[filePath] = items
                        allItems.append(contentsOf: items)
                    }
                }
            }

            let snapshotByFile = byFile
            let sorted = Self.sortTodos(allItems)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.todoScanGeneration == generation, self.activeWorkspacePath == root else { return }
                self.todosByFileCache = snapshotByFile
                self.workspaceTodos = sorted
                self.isScanningTodos = false
            }
        }
    }

    func updateTodosForSavedFile(path: String, content: String) {
        guard !activeWorkspacePath.isEmpty, path.hasPrefix(activeWorkspacePath + "/") else { return }
        guard content.utf8.count <= Self.maxTodoScanFileBytes else { return }

        Task.detached(priority: .utility) { [weak self] in
            let scanned = Self.scanTodosInFile(atPath: path, content: content, maxItems: 100)
            await MainActor.run { [weak self] in
                guard let self, !self.activeWorkspacePath.isEmpty else { return }
                if scanned.isEmpty {
                    guard self.todosByFileCache[path] != nil else { return }
                    self.todosByFileCache.removeValue(forKey: path)
                } else {
                    self.todosByFileCache[path] = scanned
                }
                let combined = self.todosByFileCache.values.flatMap { $0 }
                self.workspaceTodos = Array(Self.sortTodos(combined).prefix(Self.maxTodoItems))
            }
        }
    }

    private nonisolated static func sortTodos(_ items: [WorkspaceTodoItem]) -> [WorkspaceTodoItem] {
        items.sorted { a, b in
            if a.path != b.path { return a.path < b.path }
            if a.line != b.line { return a.line < b.line }
            return a.column < b.column
        }
    }

    private nonisolated static let scannableExtensions: Set<String> = [
        "go", "mod", "sum", "work", "sh", "zsh", "bash", "py", "js", "ts", "tsx", "jsx",
        "json", "yaml", "yml", "toml", "md", "sql", "proto", "dockerfile", "makefile",
        "env", "txt", "html", "css", "scss", "c", "h", "cpp", "rs", "swift"
    ]

    private nonisolated static let skippedDirectories: Set<String> = [
        ".git", "vendor", "node_modules", ".build", "build", "dist", "out", "output", "target",
        ".idea", ".vscode", ".golens", "DerivedData", "coverage", "__pycache__",
        ".next", ".venv", "venv", "Pods"
    ]

    private nonisolated static func collectScannableFiles(inRoot root: String, limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [String] = []
        files.reserveCapacity(min(limit, 512))

        while let itemURL = enumerator.nextObject() as? URL {
            let name = itemURL.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
                continue
            }
            if values.isDirectory == true {
                if name.hasPrefix(".") && name != ".github" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard size > 0 && size <= maxTodoScanFileBytes else { continue }

            let ext = itemURL.pathExtension.lowercased()
            let lowerName = name.lowercased()
            if scannableExtensions.contains(ext) || lowerName == "makefile" || lowerName == "dockerfile" || lowerName.hasPrefix(".env") {
                files.append(itemURL.path)
                if files.count >= limit {
                    break
                }
            }
        }
        return files
    }

    nonisolated static func scanTodosInFile(atPath path: String, content: String?, maxItems: Int) -> [WorkspaceTodoItem] {
        guard maxItems > 0 else { return [] }
        let text: String
        if let content {
            text = content
        } else {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int,
                  size > 0, size <= maxTodoScanFileBytes,
                  let loaded = try? String(contentsOfFile: path, encoding: .utf8) else {
                return []
            }
            text = loaded
        }

        guard text.contains("TODO") || text.contains("FIXME") || text.contains("HACK") || text.contains("NOTE") else {
            return []
        }

        var found: [WorkspaceTodoItem] = []
        var lineNumber = 0

        text.enumerateLines { line, stop in
            lineNumber += 1
            guard line.contains("TODO") || line.contains("FIXME") || line.contains("HACK") || line.contains("NOTE") else {
                return
            }
            if let match = parseTodoComment(inLine: line, path: path, lineNumber: lineNumber) {
                found.append(match)
                if found.count >= maxItems {
                    stop = true
                }
            }
        }
        return found
    }

    private nonisolated static func parseTodoComment(inLine line: String, path: String, lineNumber: Int) -> WorkspaceTodoItem? {
        let commentStartIdx: String.Index? = {
            if let r = line.range(of: "//") { return r.lowerBound }
            if let r = line.range(of: "/*") { return r.lowerBound }
            if let r = line.range(of: "#") { return r.lowerBound }
            if let r = line.range(of: "--") { return r.lowerBound }
            if let r = line.range(of: "<!--") { return r.lowerBound }
            return nil
        }()

        guard let startIdx = commentStartIdx else { return nil }
        let commentSlice = line[startIdx...]

        for tag in TodoTagKind.allCases {
            let token = tag.rawValue
            guard let tagRange = commentSlice.range(of: token) else { continue }

            if tagRange.lowerBound > commentSlice.startIndex {
                let prevChar = commentSlice[commentSlice.index(before: tagRange.lowerBound)]
                if prevChar.isLetter || prevChar.isNumber || prevChar == "_" {
                    continue
                }
            }
            if tagRange.upperBound < commentSlice.endIndex {
                let nextChar = commentSlice[tagRange.upperBound]
                if nextChar.isLetter || nextChar.isNumber || nextChar == "_" {
                    continue
                }
                if nextChar != ":" && nextChar != "(" && !nextChar.isWhitespace {
                    continue
                }
            }

            let col = line.distance(from: line.startIndex, to: tagRange.lowerBound) + 1
            var detail = String(commentSlice[tagRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if detail.hasPrefix(":") {
                detail = String(detail.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if detail.hasSuffix("*/") {
                detail = String(detail.dropLast(2)).trimmingCharacters(in: .whitespaces)
            }
            if detail.hasSuffix("-->") {
                detail = String(detail.dropLast(3)).trimmingCharacters(in: .whitespaces)
            }
            let display = detail.isEmpty ? token : "\(token): \(detail)"
            let clipped = display.count > 160 ? String(display.prefix(160)) + "…" : display

            return WorkspaceTodoItem(
                path: path,
                line: lineNumber,
                column: col,
                tag: tag,
                text: clipped
            )
        }
        return nil
    }
}
