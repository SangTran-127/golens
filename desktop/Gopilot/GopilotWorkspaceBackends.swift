import Foundation
import GopilotAnalysis
import GopilotPolicy

final class GopilotWorkspaceAccess: @unchecked Sendable {
    let root: String
    private weak var workspace: WorkspaceState?

    init(root: String, workspace: WorkspaceState) {
        self.root = root
        self.workspace = workspace
    }

    func absolute(_ resolved: ResolvedPath) -> String {
        resolved.url.path
    }

    func relative(_ absolutePath: String) -> String? {
        let canonical = URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().path
        guard canonical.hasPrefix(root + "/") else { return nil }
        return String(canonical.dropFirst(root.count + 1))
    }

    @MainActor
    func bufferText(at absolutePath: String) -> (text: String, version: Int)? {
        guard let session = workspace?.documents[absolutePath] else { return nil }
        return (session.storage.string, session.version)
    }

    @MainActor
    func editedBuffers() -> [String: (text: String, version: Int)] {
        guard let workspace else { return [:] }
        var result: [String: (String, Int)] = [:]
        for path in workspace.editedFiles {
            if let session = workspace.documents[path] {
                result[path] = (session.storage.string, session.version)
            }
        }
        return result
    }

    @MainActor
    func openDocumentVersions() -> [String: Int] {
        guard let workspace else { return [:] }
        var result: [String: Int] = [:]
        for (path, session) in workspace.documents {
            if let relative = relative(path) { result[relative] = session.version }
        }
        return result
    }

    @MainActor
    func diagnostics() -> [FlatDiagnosticItem] {
        workspace?.flatDiagnostics ?? []
    }

    @MainActor
    func snapshot(workspaceID: UUID) -> SourceSnapshot {
        let edited = editedBuffers()
        var dirty: [String: String] = [:]
        for (path, value) in edited {
            if let relative = relative(path) { dirty[relative] = ContentHash.sha256Hex(value.text) }
        }
        let versions = openDocumentVersions()
        let goVersion = Self.goModInfo(root: root).goVersion
        let fingerprint = ContentHash.combined(dirty.merging(versions.mapValues(String.init)) { first, _ in first })
        return SourceSnapshot(
            id: "S-" + String(ContentHash.sha256Hex(workspaceID.uuidString + fingerprint).prefix(12)),
            workspaceID: workspaceID,
            dirtyFileHashes: dirty,
            documentVersions: versions,
            goVersion: goVersion
        )
    }

    static func goModInfo(root: String) -> (module: String?, goVersion: String?) {
        guard let text = try? String(contentsOfFile: root + "/go.mod", encoding: .utf8) else { return (nil, nil) }
        var module: String?
        var version: String?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("module "), module == nil { module = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("go "), version == nil { version = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        }
        return (module, version)
    }

    static let skippedDirectories: Set<String> = [
        ".git", ".build", "node_modules", "vendor", ".idea", ".vscode", "build", "dist",
        ".claude", ".agents", ".next", "out", "output", "target", ".venv", "venv",
        "__pycache__", "DerivedData", "Pods", "submission-source", "research", "artifacts", "coverage"
    ]
}

struct GopilotProjectBackend: ProjectInfoBackend {
    let access: GopilotWorkspaceAccess

    func projectSummary(includeReadme: Bool) async -> BackendOutcome<ProjectSummaryInfo> {
        let root = access.root
        return await Task.detached(priority: .utility) {
            let info = GopilotWorkspaceAccess.goModInfo(root: root)
            var entries: [EntryCandidate] = []
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var scanned = 0
            while scanned < 4000 {
                var shouldBreak = false
                autoreleasepool {
                    guard let url = enumerator?.nextObject() as? URL else {
                        shouldBreak = true
                        return
                    }
                    if GopilotWorkspaceAccess.skippedDirectories.contains(url.lastPathComponent) {
                        enumerator?.skipDescendants()
                        return
                    }
                    guard url.pathExtension == "go", !url.lastPathComponent.hasSuffix("_test.go") else { return }
                    scanned += 1
                    guard let data = try? Data(contentsOf: url), data.count < 512 * 1024, let text = String(data: data, encoding: .utf8) else { return }
                    if text.contains("\nfunc main()") && text.contains("package main") {
                        let relative = String(url.path.dropFirst(root.count + 1))
                        entries.append(EntryCandidate(path: relative, kind: "main", note: "package main with func main"))
                    }
                }
                if shouldBreak { break }
            }
            entries.sort { $0.path < $1.path }
            var readme: String?
            if includeReadme {
                for name in ["README.md", "README", "readme.md", "README.txt"] {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/" + name)), let text = String(data: data.prefix(4000), encoding: .utf8) {
                        readme = text
                        break
                    }
                }
            }
            if info.module == nil && entries.isEmpty && readme == nil { return .empty }
            return .found(ProjectSummaryInfo(moduleName: info.module, goVersion: info.goVersion, buildTarget: nil, entries: Array(entries.prefix(50)), readmeExcerpt: readme))
        }.value
    }
}

struct GopilotListingBackend: FileListingBackend {
    let access: GopilotWorkspaceAccess

    func listFiles(directory: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<String>> {
        let root = access.root
        let url = directory.url
        return await Task.detached(priority: .utility) {
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
                return .unavailable("The directory could not be read.")
            }
            let names = children.map { child -> String in
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let base = child.path.hasPrefix(root + "/") ? String(child.path.dropFirst(root.count + 1)) : child.lastPathComponent
                return isDirectory ? base + "/" : base
            }.sorted()
            if names.isEmpty { return .empty }
            let offset = Int(cursor ?? "") ?? 0
            let page = Array(names.dropFirst(offset).prefix(limit))
            let next = offset + page.count < names.count ? String(offset + page.count) : nil
            return .found(BackendPage(items: page, nextCursor: next, isTruncated: next != nil))
        }.value
    }
}

struct GopilotSearchBackend: CodeSearchBackend {
    let access: GopilotWorkspaceAccess

    func search(query: String, scope: SearchScope, regex: Bool, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SearchHit>> {
        let root = access.root
        let buffers = await MainActor.run { access.editedBuffers() }
        return await Task.detached(priority: .utility) {
            var expression: NSRegularExpression?
            if regex {
                guard let compiled = try? NSRegularExpression(pattern: query, options: []) else { return .unavailable("The pattern is not a valid regular expression.") }
                expression = compiled
            }
            var hits: [SearchHit] = []
            let maxHits = 500
            var scanned = 0
            var paths: [String] = []
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if GopilotWorkspaceAccess.skippedDirectories.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                switch scope {
                case .workspace: break
                case .goFiles: guard url.pathExtension == "go" else { continue }
                case .testFiles: guard name.hasSuffix("_test.go") else { continue }
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                paths.append(url.path)
                if paths.count >= 5000 { break }
            }
            paths.sort()
            for path in paths where hits.count < maxHits {
                autoreleasepool {
                    scanned += 1
                    let text: String
                    if let buffer = buffers[path] {
                        text = buffer.text
                    } else {
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1024 * 1024, let decoded = String(data: data, encoding: .utf8) else { return }
                        text = decoded
                    }
                    let relative = String(path.dropFirst(root.count + 1))
                    var lineNumber = 0
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        lineNumber += 1
                        let matches: Bool
                        if let expression {
                            let value = String(line)
                            matches = expression.firstMatch(in: value, options: [], range: NSRange(location: 0, length: (value as NSString).length)) != nil
                        } else {
                            matches = line.range(of: query) != nil
                        }
                        if matches {
                            hits.append(SearchHit(path: relative, line: lineNumber, text: String(line.prefix(300))))
                            if hits.count >= maxHits { break }
                        }
                    }
                }
            }
            if hits.isEmpty { return .empty }
            let offset = Int(cursor ?? "") ?? 0
            let page = Array(hits.dropFirst(offset).prefix(limit))
            let next = offset + page.count < hits.count ? String(offset + page.count) : nil
            return .found(BackendPage(items: page, nextCursor: next, isTruncated: next != nil || hits.count >= maxHits))
        }.value
    }
}

struct GopilotSourceBackend: SourceProviding {
    let access: GopilotWorkspaceAccess
    private let disk = DiskSourceProvider()

    init(access: GopilotWorkspaceAccess) {
        self.access = access
    }

    func source(for path: ResolvedPath) async -> BackendOutcome<SourceDocument> {
        let absolute = access.absolute(path)
        if let buffer = await MainActor.run(body: { access.bufferText(at: absolute) }) {
            return .found(SourceDocument(text: buffer.text, documentVersion: buffer.version, fromBuffer: true))
        }
        return await disk.source(for: path)
    }
}

struct GopilotDiagnosticsBackend: DiagnosticsBackend {
    let access: GopilotWorkspaceAccess

    func diagnostics(in path: ResolvedPath?, limit: Int) async -> BackendOutcome<BackendPage<DiagnosticInfo>> {
        let items = await MainActor.run { access.diagnostics() }
        let target = path.map { access.absolute($0) }
        let filtered = items.filter { target == nil || $0.path == target }
        let mapped: [DiagnosticInfo] = filtered.compactMap { item in
            guard let relative = access.relative(item.path) else { return nil }
            let severity: String
            switch item.diag.severity {
            case 1: severity = "error"
            case 2: severity = "warning"
            case 3: severity = "information"
            default: severity = "hint"
            }
            return DiagnosticInfo(path: relative, line: item.diag.line, column: item.diag.col, severity: severity, message: item.diag.message, source: item.diag.source)
        }
        if mapped.isEmpty { return .empty }
        let page = Array(mapped.prefix(limit))
        return .found(BackendPage(items: page, nextCursor: nil, isTruncated: mapped.count > page.count))
    }
}
