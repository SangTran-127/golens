import AppKit
import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

extension GopilotState {
    func currentEditorRelativePath(in workspace: WorkspaceState) -> String? {
        let active = workspace.activeFilePath
        let root = workspace.activeWorkspacePath
        guard !active.isEmpty, !root.isEmpty else { return nil }
        let relative = active.hasPrefix(root + "/")
            ? String(active.dropFirst(root.count + 1))
            : (active as NSString).lastPathComponent
        let policy = PathPolicy(workspaceRoots: [URL(fileURLWithPath: root)])
        guard policy.lexicalExclusion(relativePath: relative) == nil else { return nil }
        return relative
    }

    func isActiveFileSuggested(in workspace: WorkspaceState) -> Bool {
        guard currentEditorRelativePath(in: workspace) != nil else { return false }
        return dismissedActiveFilePath != workspace.activeFilePath
    }

    func activeFileAttachment(in workspace: WorkspaceState) -> GopilotAttachment? {
        guard let rel = currentEditorRelativePath(in: workspace) else { return nil }
        return attachments.first { $0.relativePath == rel && $0.isWholeFile && $0.symbolName == nil }
    }

    @MainActor
    func toggleActiveFileAttachment(in workspace: WorkspaceState) {
        if let existing = activeFileAttachment(in: workspace) {
            removeAttachment(id: existing.id)
        } else {
            dismissedActiveFilePath = nil
            _ = attachCurrentFile(from: workspace)
        }
    }

    @MainActor
    func dismissActiveFileSuggestion(in workspace: WorkspaceState) {
        if let existing = activeFileAttachment(in: workspace) {
            removeAttachment(id: existing.id)
        }
        dismissedActiveFilePath = workspace.activeFilePath
    }

    func activeProblemsSummary(in workspace: WorkspaceState) -> (count: Int, label: String, details: String)? {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return nil }
        let activeFile = workspace.activeFilePath
        let activeDiags = !activeFile.isEmpty ? workspace.diagnosticsForPath(activeFile) : []
        if !activeDiags.isEmpty {
            let rel = currentEditorRelativePath(in: workspace) ?? (activeFile as NSString).lastPathComponent
            let lines = activeDiags.prefix(12).map { diag in
                "\(rel):\(diag.line):\(diag.col): [\(diag.severity == 1 ? "error" : "warning")] \(diag.message)"
            }
            let count = activeDiags.count
            return (
                count: count,
                label: "\(count) Problem\(count == 1 ? "" : "s") in \((rel as NSString).lastPathComponent)",
                details: lines.joined(separator: "\n")
            )
        }
        var allLines: [String] = []
        var totalCount = 0
        for (fullPath, diags) in workspace.diagnostics.sorted(by: { $0.key < $1.key }) where !diags.isEmpty {
            totalCount += diags.count
            let rel = fullPath.hasPrefix(root + "/")
                ? String(fullPath.dropFirst(root.count + 1))
                : (fullPath as NSString).lastPathComponent
            for diag in diags where allLines.count < 15 {
                allLines.append("\(rel):\(diag.line):\(diag.col): [\(diag.severity == 1 ? "error" : "warning")] \(diag.message)")
            }
        }
        guard totalCount > 0 else { return nil }
        return (
            count: totalCount,
            label: "\(totalCount) Problem\(totalCount == 1 ? "" : "s")",
            details: allLines.joined(separator: "\n")
        )
    }

    func isProblemsChipVisible(in workspace: WorkspaceState) -> Bool {
        guard activeProblemsSummary(in: workspace) != nil else { return false }
        return includeProblemsInContext || !dismissedProblemsSuggestion
    }

    @MainActor
    func toggleProblemsAttachment() {
        includeProblemsInContext.toggle()
        if includeProblemsInContext {
            dismissedProblemsSuggestion = false
        }
    }

    @MainActor
    func dismissProblemsSuggestion() {
        includeProblemsInContext = false
        dismissedProblemsSuggestion = true
    }

    func hasActiveEditorSelection(in workspace: WorkspaceState) -> Bool {
        guard let textView = workspace.activeTextView as? NSTextView, !workspace.activeFilePath.isEmpty else { return false }
        return textView.selectedRange().length > 0
    }

    var activeMentionQuery: String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let prev = draft[draft.index(before: atIndex)]
            if !prev.isWhitespace && prev != "(" && prev != "[" {
                return nil
            }
        }
        let suffix = String(draft[draft.index(after: atIndex)...])
        if suffix.contains(where: { $0.isWhitespace }) || suffix.count > 48 {
            return nil
        }
        return suffix
    }

    var visibleMentionQuery: String? {
        guard let query = activeMentionQuery, query != dismissedMentionQuery else { return nil }
        return query
    }

    @MainActor
    func completeMention(with attachment: GopilotAttachment) {
        guard let atIndex = draft.lastIndex(of: "@") else { return }
        let prefix = String(draft[..<atIndex])
        draft = prefix + "@\(attachment.label) "
    }

    func upsertAttachment(_ item: GopilotAttachment) {
        if let index = attachments.firstIndex(where: { $0.deduplicationKey == item.deduplicationKey }) {
            attachments[index] = item
        } else {
            attachments.append(item)
        }
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    @MainActor
    @discardableResult
    func attachSelection(from workspace: WorkspaceState) -> Bool {
        guard let textView = workspace.activeTextView as? NSTextView, !workspace.activeFilePath.isEmpty else { return false }
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        let full = textView.string as NSString
        guard NSMaxRange(range) <= full.length else { return false }
        let text = full.substring(with: range)
        let prefix = full.substring(to: range.location)
        let startLine = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let endLine = startLine + text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let absolute = workspace.activeFilePath
        let root = workspace.activeWorkspacePath
        let relative = absolute.hasPrefix(root + "/") ? String(absolute.dropFirst(root.count + 1)) : (absolute as NSString).lastPathComponent
        guard validateAttachmentPath(relativePath: relative, workspaceRoot: root) else { return false }
        let doc = workspace.documents[absolute]
        let item = GopilotAttachment(
            relativePath: relative,
            absolutePath: absolute,
            startLine: startLine,
            endLine: max(startLine, text.hasSuffix("\n") ? endLine - 1 : endLine),
            text: String(text.prefix(16_000)),
            documentVersion: doc?.version ?? 0,
            isUnsaved: workspace.editedFiles.contains(absolute),
            isWholeFile: false,
            origin: .editorSelection
        )
        upsertAttachment(item)
        return true
    }

    @MainActor
    @discardableResult
    func attachCurrentFile(from workspace: WorkspaceState) -> Bool {
        guard !workspace.activeFilePath.isEmpty, !workspace.activeWorkspacePath.isEmpty else { return false }
        dismissedActiveFilePath = nil
        let absolute = workspace.activeFilePath
        let root = workspace.activeWorkspacePath
        let relative = absolute.hasPrefix(root + "/") ? String(absolute.dropFirst(root.count + 1)) : (absolute as NSString).lastPathComponent
        return attachFile(relativePath: relative, workspace: workspace, origin: .filePicker)
    }

    @MainActor
    @discardableResult
    func attachFile(relativePath: String, workspace: WorkspaceState, origin: AttachmentOrigin = .filePicker) -> Bool {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return false }
        guard validateAttachmentPath(relativePath: relativePath, workspaceRoot: root) else { return false }
        let absolute = root + "/" + relativePath
        let doc = workspace.documents[absolute]
        let rawText: String
        if let doc {
            rawText = doc.storage.string
        } else if let diskText = try? String(contentsOfFile: absolute, encoding: .utf8) {
            rawText = diskText
        } else {
            return false
        }
        let lineCount = max(1, rawText.components(separatedBy: "\n").count)
        let item = GopilotAttachment(
            relativePath: relativePath,
            absolutePath: absolute,
            startLine: 1,
            endLine: lineCount,
            symbolName: nil,
            text: String(rawText.prefix(16_000)),
            documentVersion: doc?.version ?? 0,
            isUnsaved: workspace.editedFiles.contains(absolute),
            isWholeFile: true,
            origin: origin
        )
        upsertAttachment(item)
        if origin == .atMention {
            completeMention(with: item)
        }
        return true
    }

    @MainActor
    @discardableResult
    func attachFolder(relativePath: String, workspace: WorkspaceState, origin: AttachmentOrigin = .filePicker, updateDraft: Bool = true) -> Bool {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return false }
        var normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
        while normalized.hasPrefix("/") { normalized = String(normalized.dropFirst()) }
        while normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        guard !normalized.isEmpty else { return false }
        guard validateAttachmentPath(relativePath: normalized, workspaceRoot: root) else { return false }
        let absolute = root + "/" + normalized
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        ensureWorkspaceIndex(for: root)
        let prefix = normalized + "/"
        let folderFiles = indexCache.files.filter { $0.hasPrefix(prefix) }
        var sections: [String] = []
        sections.append("Directory structure for `\(normalized)/` (\(folderFiles.count) file\(folderFiles.count == 1 ? "" : "s")):")
        let treePreview = folderFiles.prefix(80).map { "  - \($0)" }.joined(separator: "\n")
        if !treePreview.isEmpty {
            sections.append(treePreview)
        }

        let keyCandidates = folderFiles.filter { rel in
            let name = (rel as NSString).lastPathComponent.lowercased()
            return name == "go.mod"
                || name == "go.work"
                || name == "makefile"
                || name == "dockerfile"
                || name == "readme.md"
                || name == "architecture.md"
                || name == "main.go"
                || rel.contains("/cmd/") && name.hasSuffix(".go")
                || rel.contains("/bootstrap/") && name.hasSuffix(".go")
                || rel.contains("/routes/") && name.hasSuffix(".go")
                || rel.contains("/config/") && name.hasSuffix(".go")
        }
        var remainingBudget = 12_000
        for rel in keyCandidates.prefix(8) where remainingBudget > 400 {
            let fileAbs = root + "/" + rel
            let content = workspace.documents[fileAbs]?.storage.string ?? (try? String(contentsOfFile: fileAbs, encoding: .utf8)) ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let snippet = String(trimmed.prefix(min(remainingBudget, 2_200)))
            sections.append("--- File: \(rel) ---\n\(snippet)")
            remainingBudget -= snippet.count
        }

        let summaryText = sections.joined(separator: "\n\n")
        let lineCount = max(1, summaryText.components(separatedBy: "\n").count)
        let item = GopilotAttachment(
            relativePath: normalized,
            absolutePath: absolute,
            startLine: 1,
            endLine: lineCount,
            symbolName: nil,
            text: String(summaryText.prefix(16_000)),
            documentVersion: 0,
            isUnsaved: false,
            isWholeFile: true,
            isFolder: true,
            origin: origin
        )
        upsertAttachment(item)
        if origin == .atMention && updateDraft {
            completeMention(with: item)
        }
        return true
    }

    @MainActor
    @discardableResult
    func attachSymbol(_ symbol: GopilotSymbolCandidate, workspace: WorkspaceState, origin: AttachmentOrigin = .symbolPicker) -> Bool {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return false }
        guard validateAttachmentPath(relativePath: symbol.relativePath, workspaceRoot: root) else { return false }
        let absolute = root + "/" + symbol.relativePath
        let doc = workspace.documents[absolute]
        let rawText: String
        if let doc {
            rawText = doc.storage.string
        } else if let diskText = try? String(contentsOfFile: absolute, encoding: .utf8) {
            rawText = diskText
        } else {
            return false
        }
        let lines = rawText.components(separatedBy: "\n")
        let s = max(1, min(symbol.startLine, lines.count))
        let e = max(s, min(symbol.endLine, lines.count))
        let slice = lines[(s - 1)..<e].joined(separator: "\n")
        let item = GopilotAttachment(
            relativePath: symbol.relativePath,
            absolutePath: absolute,
            startLine: s,
            endLine: e,
            symbolName: symbol.name,
            text: String(slice.prefix(16_000)),
            documentVersion: doc?.version ?? 0,
            isUnsaved: workspace.editedFiles.contains(absolute),
            isWholeFile: false,
            origin: origin
        )
        upsertAttachment(item)
        if origin == .atMention {
            completeMention(with: item)
        }
        return true
    }

    @MainActor
    private func validateAttachmentPath(relativePath: String, workspaceRoot: String) -> Bool {
        guard !workspaceRoot.isEmpty else { return true }
        let policy = PathPolicy(workspaceRoots: [URL(fileURLWithPath: workspaceRoot)])
        switch policy.evaluate(relativePath: relativePath) {
        case .allowed:
            return true
        case .denied:
            items.removeAll { if case .notice = $0 { true } else { false } }
            items.append(
                .notice(
                    id: UUID(),
                    kind: .warning,
                    text: "Cannot attach \(relativePath): sensitive, binary, or excluded files are never sent to the provider.",
                    canRetry: false
                )
            )
            return false
        }
    }

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".venv", "venv", "vendor", ".git", ".build", "build",
        "dist", ".next", "__pycache__", "target", ".gradle", "Pods", "DerivedData", ".idea",
        "output", "submission-source", "artifacts", "coverage", "logs"
    ]

    private static let primaryCodeFolderNames: Set<String> = [
        "backend", "cmd", "internal", "pkg", "api", "core", "desktop",
        "frontend", "services", "apps", "src", "lib", "server", "worker"
    ]

    private static let skippedFileExtensions: Set<String> = [
        "aux", "blg", "bbl", "fls", "fdb_latexmk", "toc", "out", "lof", "lot",
        "synctex", "gz", "pdf", "png", "jpg", "jpeg", "gif", "webp", "ico",
        "zip", "tar", "o", "a", "dylib", "so", "exe", "bin", "pyc", "class", "wasm"
    ]

    private static func filePriorityBucket(for relativePath: String) -> Int {
        let lower = relativePath.lowercased()
        let base = (lower as NSString).lastPathComponent
        let ext = (base as NSString).pathExtension
        if ext == "go" || base == "go.mod" || base == "go.work" || base == "go.sum" {
            return 0
        }
        if base == "dockerfile" || base.hasPrefix("dockerfile.") || base == "makefile"
            || ["sql", "proto", "yaml", "yml", "json", "toml", "sh", "ts", "tsx", "js", "py", "rs", "swift"].contains(ext) {
            return 1
        }
        if ext == "md" {
            return 2
        }
        return 3
    }

    func ensureWorkspaceIndex(for root: String) {
        guard !root.isEmpty else {
            indexCache.files = []
            indexCache.folders = []
            indexCache.workspacePath = ""
            return
        }
        let now = Date()
        if root == indexCache.workspacePath,
           now.timeIntervalSince(indexCache.timestamp) < 8,
           (!indexCache.files.isEmpty || !indexCache.folders.isEmpty) {
            return
        }
        let rootURL = URL(fileURLWithPath: root)
        let policy = PathPolicy(workspaceRoots: [rootURL])
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var files: [String] = []
        var folders: [String] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if Self.skippedDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let path = fileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let rel = String(path.dropFirst(root.count + 1))
            if policy.lexicalExclusion(relativePath: rel) != nil {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if folders.count < 400 {
                    folders.append(rel)
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if Self.skippedFileExtensions.contains(ext) || name.hasSuffix(".synctex.gz") {
                continue
            }
            files.append(rel)
            if files.count >= 1500 { break }
        }

        files.sort { lhs, rhs in
            let lBucket = Self.filePriorityBucket(for: lhs)
            let rBucket = Self.filePriorityBucket(for: rhs)
            if lBucket != rBucket { return lBucket < rBucket }
            return lhs < rhs
        }
        folders.sort { lhs, rhs in
            let lBase = (lhs as NSString).lastPathComponent.lowercased()
            let rBase = (rhs as NSString).lastPathComponent.lowercased()
            let lPrimary = Self.primaryCodeFolderNames.contains(lBase)
            let rPrimary = Self.primaryCodeFolderNames.contains(rBase)
            let lDepth = lhs.filter { $0 == "/" }.count
            let rDepth = rhs.filter { $0 == "/" }.count
            if lDepth != rDepth { return lDepth < rDepth }
            if lPrimary != rPrimary { return lPrimary }
            return lhs < rhs
        }

        indexCache.workspacePath = root
        indexCache.timestamp = now
        indexCache.files = files
        indexCache.folders = folders
    }

    func availableFolders(in workspace: WorkspaceState, query: String = "") -> [String] {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return [] }
        ensureWorkspaceIndex(for: root)
        var trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmedQuery.hasSuffix("/") { trimmedQuery = String(trimmedQuery.dropLast()) }
        if trimmedQuery.isEmpty {
            return Array(indexCache.folders.prefix(16))
        }
        let matches = indexCache.folders.filter { $0.lowercased().contains(trimmedQuery) }
        return Array(matches.sorted { lhs, rhs in
            let lLow = lhs.lowercased()
            let rLow = rhs.lowercased()
            let lBase = (lLow as NSString).lastPathComponent
            let rBase = (rLow as NSString).lastPathComponent
            func folderRank(_ path: String, base: String) -> Int {
                if path == trimmedQuery { return 0 }
                if path.hasPrefix(trimmedQuery + "/") { return 1 }
                if base == trimmedQuery { return 2 }
                if path.hasPrefix(trimmedQuery) || base.hasPrefix(trimmedQuery) { return 3 }
                return 4
            }
            let lRank = folderRank(lLow, base: lBase)
            let rRank = folderRank(rLow, base: rBase)
            if lRank != rRank { return lRank < rRank }
            let lDepth = lhs.filter { $0 == "/" }.count
            let rDepth = rhs.filter { $0 == "/" }.count
            if lDepth != rDepth { return lDepth < rDepth }
            return lhs < rhs
        }.prefix(24))
    }

    func availableFiles(in workspace: WorkspaceState, query: String = "") -> [String] {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return [] }
        ensureWorkspaceIndex(for: root)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmedQuery.isEmpty {
            return Array(indexCache.files.prefix(60))
        }
        let matches = indexCache.files.filter { $0.lowercased().contains(trimmedQuery) }
        return Array(matches.sorted { lhs, rhs in
            let lBase = ((lhs as NSString).lastPathComponent).lowercased()
            let rBase = ((rhs as NSString).lastPathComponent).lowercased()
            let lExact = lBase == trimmedQuery || lhs.lowercased() == trimmedQuery
            let rExact = rBase == trimmedQuery || rhs.lowercased() == trimmedQuery
            if lExact != rExact { return lExact }
            let lBucket = Self.filePriorityBucket(for: lhs)
            let rBucket = Self.filePriorityBucket(for: rhs)
            if lBucket != rBucket { return lBucket < rBucket }
            return lhs < rhs
        }.prefix(60))
    }

    @MainActor
    func resolveInlineMentions(in text: String, workspace: WorkspaceState) {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty, text.contains("@") else { return }
        ensureWorkspaceIndex(for: root)
        let regex = try! NSRegularExpression(pattern: #"(?:^|[\s(\[])@([A-Za-z0-9_./-]+)"#)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            var token = ns.substring(with: match.range(at: 1))
            while let last = token.last, [",", ".", ":", ";", ")", "]"].contains(String(last)) {
                token.removeLast()
            }
            var clean = token
            while clean.hasSuffix("/") { clean.removeLast() }
            guard !clean.isEmpty else { continue }
            let lower = clean.lowercased()
            if attachments.contains(where: { $0.relativePath.lowercased() == lower }) {
                continue
            }
            if let exactFolder = indexCache.folders.first(where: { $0.lowercased() == lower })
                ?? indexCache.folders.first(where: { ($0 as NSString).lastPathComponent.lowercased() == lower }) {
                _ = attachFolder(relativePath: exactFolder, workspace: workspace, origin: .atMention, updateDraft: false)
                continue
            }
            if let exactFile = indexCache.files.first(where: { $0.lowercased() == lower })
                ?? indexCache.files.first(where: { ($0 as NSString).lastPathComponent.lowercased() == lower }) {
                let savedDraft = draft
                _ = attachFile(relativePath: exactFile, workspace: workspace, origin: .filePicker)
                draft = savedDraft
            }
        }
    }

    func availableSymbols(in workspace: WorkspaceState, query: String = "") -> [GopilotSymbolCandidate] {
        let files = availableFiles(in: workspace, query: "").filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        let root = workspace.activeWorkspacePath
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let declRegex = try! NSRegularExpression(pattern: #"^(func\s+(?:\([^)]+\)\s*)?([A-Za-z_][A-Za-z0-9_]*)|type\s+([A-Za-z_][A-Za-z0-9_]*)\s+(struct|interface|[A-Za-z0-9_\[\]\*\.]+))"#)
        var results: [GopilotSymbolCandidate] = []
        for rel in files.prefix(25) {
            autoreleasepool {
                let abs = root + "/" + rel
                let content = workspace.documents[abs]?.storage.string ?? (try? String(contentsOfFile: abs, encoding: .utf8)) ?? ""
                let lines = content.components(separatedBy: "\n")
                for (idx, line) in lines.enumerated() {
                    let ns = line as NSString
                    guard let match = declRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let funcName = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
                    let typeName = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : nil
                    guard let name = funcName ?? typeName else { continue }
                    if !trimmedQuery.isEmpty && !name.lowercased().contains(trimmedQuery) && !rel.lowercased().contains(trimmedQuery) {
                        continue
                    }
                    let kind = funcName != nil ? "func" : "type"
                    var endIdx = idx
                    var depth = 0
                    var sawBrace = false
                    for scan in idx..<min(lines.count, idx + 80) {
                        for ch in lines[scan] {
                            if ch == "{" { depth += 1; sawBrace = true }
                            else if ch == "}" { depth -= 1 }
                        }
                        endIdx = scan
                        if sawBrace && depth <= 0 { break }
                        if !sawBrace && !lines[scan].trimmingCharacters(in: CharacterSet.whitespaces).hasSuffix("(") { break }
                    }
                    results.append(
                        GopilotSymbolCandidate(
                            name: name,
                            kind: kind,
                            relativePath: rel,
                            startLine: idx + 1,
                            endLine: endIdx + 1
                        )
                    )
                    if results.count >= 60 { return }
                }
            }
            if results.count >= 60 { return results }
        }
        return results
    }

    static func composePrompt(_ text: String, attachment: GopilotAttachment?, session: GopilotSessionContext) async -> String {
        guard let attachment else { return text }
        var evidenceTag = ""
        if let workspaceID = session.workspaceID, let snapshot = await session.snapshot?() {
            let range = SourceRange(startLine: attachment.startLine - 1, startCharacter: 0, endLine: attachment.endLine - 1, endCharacter: 0)
            let ref = SourceRef(workspaceID: workspaceID, path: attachment.relativePath, range: range, documentVersion: attachment.documentVersion)
            let evidence = await session.evidence.add(EvidenceDraft(
                workspaceID: workspaceID,
                producerID: "attachment",
                kind: .source,
                sourceRefs: [ref],
                snapshotID: snapshot.id,
                content: attachment.text
            ))
            evidenceTag = " Cite it as [\(evidence.id)]."
        }
        return """
        \(text)

        Attached selection from \(attachment.relativePath), lines \(attachment.startLine)-\(attachment.endLine), taken from the editor buffer.\(evidenceTag)
        ```go
        \(attachment.text)
        ```
        """
    }

    @MainActor
    func loadProjectBriefingFacts(secretFilter: SecretFilter) -> [String] {
        guard !workspacePath.isEmpty else { return [] }
        let candidates = ["GOLENS.md", ".golens/MEMORY.md", "QWEN.md", "AGENTS.md"]
        var facts: [String] = []
        var totalBudget = 2400
        for rel in candidates where totalBudget > 120 {
            let fullPath = workspacePath + "/" + rel
            guard let raw = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let redacted = secretFilter.redact(String(trimmed.prefix(min(totalBudget, 1200)))).text
            facts.append("Project briefing (\(rel)):\n\(redacted)")
            totalBudget -= redacted.count
        }
        return facts
    }
}
