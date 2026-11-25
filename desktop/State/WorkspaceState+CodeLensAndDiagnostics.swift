import Foundation
import AppKit
import GoLensFoundation

extension WorkspaceState {
    func diagnosticsForPath(_ path: String) -> [DiagnosticData] {
        diagnostics[path] ?? []
    }

    static let diagnosticPathLock = NSLock()
    static var diagnosticCanonicalPaths: [String: String] = [:]

    static func canonicalDiagnosticPath(_ rawPath: String) -> String {
        diagnosticPathLock.lock()
        let cached = diagnosticCanonicalPaths[rawPath]
        diagnosticPathLock.unlock()
        if let cached { return cached }
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        diagnosticPathLock.lock()
        if diagnosticCanonicalPaths.count >= 4096 { diagnosticCanonicalPaths.removeAll(keepingCapacity: true) }
        diagnosticCanonicalPaths[rawPath] = resolved
        diagnosticPathLock.unlock()
        return resolved
    }

    func updateDiagnostics(path rawPath: String, payload: String) {
        let path = Self.canonicalDiagnosticPath(rawPath)
        let diags: [DiagnosticData]
        if payload.isEmpty || payload == "null" {
            diags = []
        } else if let decoded = try? JSONDecoder().decode([DiagnosticData].self, from: Data(payload.utf8)) {
            diags = decoded
        } else {
            appendLog("Failed to decode diagnostics for \((path as NSString).lastPathComponent)")
            diags = []
        }
        DispatchQueue.main.async {
            if !self.publishGoplsDiagnostics(diags, for: path) && self.issueTotals.errors == 0 {
                self.clearBuildRunFailureIfResolved()
            }
            NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: path)
            if let offline = diags.first(where: { Self.isNetworkFailure($0.message) }) {
                self.noteModuleError(offline.message)
            }
        }
    }

    static let maxCodeLensPerFile = 50

    func cachedGitAuthors(forLines lines: [Int], inPath path: String) -> [Int: String] {
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return [:] }
        let cached = Thread.isMainThread ? blameCache[path] : DispatchQueue.main.sync { blameCache[path] }
        if let cached, cached.stamp == stamp, cached.lines == lines {
            return cached.authors
        }
        let authors = getGitAuthors(forLines: lines, inPath: path)
        DispatchQueue.main.async { if self.documents[path] != nil { self.blameCache[path] = (stamp, lines, authors) } }
        return authors
    }

    func scheduleCodeLensReloadAfterSave(_ path: String) {
        codeLensSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let filename = (path as NSString).lastPathComponent
            if filename == "go.mod" || filename == "go.work", let session = self.documents[path] {
                self.codeLensVersions.removeValue(forKey: path)
                self.reloadModuleDoctorState(forPath: path, version: session.version)
                self.reloadGoplsCodeLenses(forPath: path, version: session.version)
                return
            }
            guard let tv = self.activeTextView,
                  self.activeFilePath == path || (tv as? GoLensTextView)?.filePath == path else { return }
            self.reloadCodeLens(forPath: path, textView: tv)
        }
        codeLensSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func codeLensAuthors(forLines lines: [Int], inPath path: String) async -> [Int: String] {
        guard !lines.isEmpty else { return [:] }
        let workspacePath = activeWorkspacePath
        let root = Self.canonicalPath(workspacePath)
        guard !workspacePath.isEmpty, path.hasPrefix(root + "/") else {
            return cachedGitAuthors(forLines: lines, inPath: path)
        }
        let relPath = String(path.dropFirst(root.count + 1))
        guard let blame = await fileBlame(forPath: path, relativePath: relPath, workspacePath: workspacePath) else { return [:] }
        var result: [Int: String] = [:]
        for line in lines {
            if let entry = blame.entry(forLine: line), entry.commit.author != "Not Committed Yet" {
                result[line] = entry.commit.author
            }
        }
        return result
    }

    func scheduleCodeLensRecomputeAfterTyping(_ path: String) {
        codeLensTypingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let tv = self.activeTextView as? GoLensTextView, tv.filePath == path else { return }
            self.reloadCodeLens(forPath: path, textView: tv)
        }
        codeLensTypingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LSPTimeoutPolicy.codeLensRecomputeAfterEdit, execute: work)
    }

    func usageCountsSettingChanged() {
        SetUsageIndexEnabled(showUsageCounts ? 1 : 0)
        if !showUsageCounts {
            codeLensCache = codeLensCache.mapValues { lenses in
                lenses.mapValues { CodeLensInfo(usages: nil, author: $0.author) }
            }
        }
        codeLensVersions.removeAll()
        guard let textView = activeTextView as? GoLensTextView, !textView.filePath.isEmpty, documents[textView.filePath] != nil else { return }
        textView.needsDisplay = true
        reloadCodeLens(forPath: textView.filePath, textView: textView)
    }

    func reloadCodeLens(forPath path: String, textView: NSTextView) {
        let filename = (path as NSString).lastPathComponent
        let isGoMod = filename == "go.mod"
        let isGoWork = filename == "go.work"
        let isEcosystemWithLenses = EcosystemDocumentTools.isHTTPFile(path) ||
            EcosystemDocumentTools.isMakefile(path) ||
            EcosystemDocumentTools.isDockerComposeFile(path) ||
            EcosystemDocumentTools.isDockerfile(path) ||
            EcosystemDocumentTools.isEnvFile(path) ||
            EcosystemDocumentTools.isSQLFile(path)
        guard path.hasSuffix(".go") || isGoMod || isGoWork || isEcosystemWithLenses, let session = documents[path] else { return }
        let version = session.version
        if codeLensVersions[path] == version {
            guard path.hasSuffix(".go") || EcosystemDocumentTools.isSQLFile(path) else { return }
            if let progress = codeLensProgress[path], progress.session === session {
                fetchVisibleCodeLenses(forPath: path)
                return
            }
        }
        reloadGoplsCodeLenses(forPath: path, version: version)
        guard path.hasSuffix(".go") else {
            if isGoMod {
                reloadModuleNotes(forPath: path)
            }
            if isGoMod || isGoWork {
                reloadModuleDoctorState(forPath: path, version: version)
            }
            codeLensVersions[path] = version
            return
        }
        codeLensLoadTask?.cancel()
        codeLensLoadPath = path
        codeLensVersions[path] = version
        codeLensProgress[path]?.task?.cancel()
        codeLensProgress[path] = nil
        let text = session.storage.string
        let token = nextCodeLensRunToken()
        codeLensLoadTask = Task { [weak self, weak textView, weak session] in
            guard let self else { return }
            let decls = Array(self.findGoDeclarations(in: text).prefix(Self.maxCodeLensPerFile))
            let hasGit = !self.activeWorkspacePath.isEmpty && FileManager.default.fileExists(atPath: URL(fileURLWithPath: self.activeWorkspacePath).appendingPathComponent(".git").path)
            let authors: [Int: String] = hasGit ? await self.codeLensAuthors(forLines: decls.map { $0.line }, inPath: path) : [:]
            if Task.isCancelled { return }
            let installed: Bool = await MainActor.run {
                guard let session, self.documents[path] === session, self.codeLensVersions[path] == version, !Task.isCancelled else { return false }
                let progress = CodeLensProgress(session: session, version: version, decls: decls, authorsByLine: authors)
                progress.runToken = token
                progress.isRunning = true
                self.codeLensProgress[path] = progress
                self.codeLensCache[path] = progress.retainedLenses(from: self.codeLensCache[path] ?? [:])
                textView?.needsDisplay = true
                return true
            }
            guard installed else { return }
            await self.runCodeLensFetchLoop(forPath: path, token: token)
        }
    }

    static var codeLensConcurrency: Int {
        LSPTimeoutPolicy.codeLensConcurrency(under: LSPServerConditionsStore.shared.current)
    }

    static func codeLens(for decl: GoDeclaration, inPath path: String, author: String?, indexCounts: [String: UsageIndexReply.Count]?) async -> Result<CodeLensInfo, LSPRequestFailure> {
        guard usageCountsEnabled else { return .success(CodeLensInfo(usages: nil, author: author)) }
        let source: UsageCountSource = indexCounts == nil ? .references : .index
        let needsReferences = source.needsReferences(isEntryPoint: isGoEntryPoint(decl.symbolName, inPath: path))
        let entry = indexCounts?["\(decl.line):\(decl.col)"]
        let indexed = indexedLens(for: decl, inPath: path, entry: entry, author: author)
        let needsImplementation = UsageCountSource.needsImplementation(kind: decl.kind, hasIndexedLens: entry != nil)
        if !needsReferences && !needsImplementation { return .success(indexed) }
        if GuestMemoryPressure() == 1 { return .failure(.preempted) }
        var usages = indexed.usages
        if needsReferences {
            switch await LSPClient.shared.referencesResult(atLine: decl.line, col: decl.col, inPath: path, kind: .usageLens) {
            case .success(let refs): usages = refs.count
            case .failure(let failure): return .failure(failure)
            }
        }
        var info = CodeLensInfo(usages: usages, author: author)
        guard needsImplementation else { return .success(info) }
        switch await LSPClient.shared.implementationResult(atLine: decl.line, col: decl.col, inPath: path, kind: .usageLens) {
        case .success(let impls) where !impls.isEmpty:
            info.implementations = Array(impls.prefix(100))
            info.implementsDirection = decl.isInterface ? .implementedBy : .implements
        case .failure(let failure):
            return .failure(failure)
        default:
            break
        }
        return .success(info)
    }

    func reloadModuleNotes(forPath path: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let json: String? = path.withCString { p in
                guard let c = ModuleNotes(p) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            guard let reply = json.flatMap({ try? JSONDecoder().decode(ModuleNotesReply.self, from: Data($0.utf8)) }) else { return }
            var byLine: [Int: String] = [:]
            for note in reply.notes {
                var parts: [String] = []
                if let d = note.deprecated, !d.isEmpty { parts.append("Deprecated: \(d)") }
                if let r = note.retracted, !r.isEmpty { parts.append("Retracted: \(r.joined(separator: "; "))") }
                byLine[note.line] = parts.joined(separator: " · ")
            }
            DispatchQueue.main.async {
                guard let self, self.documents[path] != nil else { return }
                if let error = reply.error {
                    measureLog("module notes unavailable: \(error)")
                    self.noteModuleError(error)
                }
                self.moduleNotes[path] = byLine
                (self.activeTextView as? GoLensTextView)?.redrawGutter()
            }
        }
    }

    func getGitAuthors(forLines lines: [Int], inPath path: String) -> [Int: String] {
        guard !lines.isEmpty else { return [:] }
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent().path
        let args = ["blame"] + lines.flatMap { ["-L", "\($0),\($0)"] } + ["--line-porcelain", fileURL.lastPathComponent]
        guard let argsJson = (try? JSONEncoder().encode(args)).flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        let resPtr: UnsafeMutablePointer<CChar>? = directory.withCString { cPath in
            argsJson.withCString { cArgs in
                RunGitCommand(cPath, cArgs, nil, 0)
            }
        }
        guard let resPtr else { return [:] }
        defer { FreeGoCString(resPtr) }
        guard let data = String(cString: resPtr).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? String else { return [:] }

        return SourceLineScanner.parseGitBlameAuthors(in: output)
    }

    static func isGoEntryPoint(_ name: String, inPath path: String) -> Bool {
        if name == "main" || name == "init" { return true }
        guard path.hasSuffix("_test.go") else { return false }
        for prefix in ["Test", "Benchmark", "Example", "Fuzz"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.isEmpty || !(rest.first!.isLowercase) { return true }
        }
        return false
    }

    func findGoDeclarations(in text: String) -> [GoDeclaration] {
        let json: String? = text.withCString { src in
            guard let c = GoDeclarations(src) else { return nil }
            defer { FreeGoCString(c) }
            return String(cString: c)
        }
        return json.flatMap { try? JSONDecoder().decode([GoDeclaration].self, from: Data($0.utf8)) } ?? []
    }
}
