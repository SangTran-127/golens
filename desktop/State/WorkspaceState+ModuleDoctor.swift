import AppKit
import Foundation
import GoLensFoundation

extension WorkspaceState {
    static let moduleDoctorDiagnosticSource = "Module Doctor"

    @MainActor
    func runEditorLensCommand(_ command: [String: Any], title: String? = nil) {
        let cmdName = command["golensCommand"] as? String ?? ""
        let path = (command["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? activeFilePath
        let line = max(1, command["line"] as? Int ?? 1)
        let arg = command["arg"] as? String ?? ""

        switch cmdName {
        case "goModWhy":
            explainModuleWhy(module: arg, inFile: path, line: line)
        case "goModOpenDocs":
            guard !activeWorkspacePath.isEmpty else { return }
            let route: DocsRoute? = arg.isEmpty ? nil : .module(path: arg)
            DocumentationService.shared.openBrowser(for: self, route: route)
        case "goModDropReplace":
            let targetLine = Int(arg) ?? line
            dropReplaceDirective(inFile: path, line: targetLine)
        case "goModOpenReplace":
            openReplacedModule(targetPath: arg, sourceFile: path)
        case "goWorkUpdateGoVersion":
            updateGoWorkGoVersion(inFile: path, version: arg)
        case "goWorkAddModule":
            addModuleToGoWork(inFile: path, relPath: arg)
        case "goWorkDropUse":
            dropUseFromGoWork(inFile: path, rawEntry: arg)
        case "goWorkSync":
            syncGoWorkspace(goWorkPath: path)
        default:
            runLSPCommand(command, title: title)
        }
    }

    static func inspectModuleManifestReport(forPath path: String, content: String, checkUpdates: Bool) -> GoModInspectDTO? {
        let filename = (path as NSString).lastPathComponent
        guard filename == "go.mod" || filename == "go.work" else { return nil }
        let mode: Int32 = (filename == "go.mod" && checkUpdates) ? 1 : 0
        let jsonStr: String? = path.withCString { cPath in
            content.withCString { cContent in
                guard let ptr = InspectGoModFile(cPath, cContent, mode) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
        }
        guard let jsonStr else { return nil }
        return try? JSONDecoder().decode(GoModInspectDTO.self, from: Data(jsonStr.utf8))
    }

    static func lenses(from dto: GoModInspectDTO, path: String) -> [CodeLensItem] {
        (dto.lenses ?? []).map { l in
            var cmd: [String: Any] = ["golensCommand": l.command, "path": path, "line": l.line]
            if let compact = l.compactTitle, !compact.isEmpty {
                cmd["compactTitle"] = compact
            }
            if let arg = l.arg, !arg.isEmpty {
                cmd["arg"] = arg
            }
            return CodeLensItem(line: max(1, l.line), title: l.title, command: cmd)
        }
    }

    func reloadModuleDoctorState(forPath path: String, version: Int) {
        let filename = (path as NSString).lastPathComponent
        guard filename == "go.mod" || filename == "go.work",
              let session = documents[path] else { return }
        let content = session.storage.string
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let dto = Self.inspectModuleManifestReport(forPath: path, content: content, checkUpdates: false) else { return }
            DispatchQueue.main.async {
                guard let self,
                      let currentSession = self.documents[path],
                      currentSession.version == version else { return }
                self.applyModuleInspectDTO(dto, forPath: path, text: content, dropSafetyReplaces: false)
            }
        }
    }

    @MainActor
    func refreshModuleDoctorFromText(forPath path: String, content: String, dropSafetyReplaces: Bool = false) {
        let filename = (path as NSString).lastPathComponent
        guard filename == "go.mod" || filename == "go.work" else { return }
        codeLensVersions.removeValue(forKey: path)
        guard let dto = Self.inspectModuleManifestReport(forPath: path, content: content, checkUpdates: false) else { return }
        applyModuleInspectDTO(dto, forPath: path, text: content, dropSafetyReplaces: dropSafetyReplaces)
    }

    @MainActor
    private func applyModuleInspectDTO(_ dto: GoModInspectDTO, forPath path: String, text: String, dropSafetyReplaces: Bool) {
        let filename = (path as NSString).lastPathComponent
        var doctorLenses = Self.lenses(from: dto, path: path)
        if filename == "go.mod", let existing = goplsLenses[path] {
            doctorLenses = Self.mergingCachedUpgradeLenses(into: doctorLenses, existing: existing, requires: dto.requires ?? [], path: path)
        }
        var current = goplsLenses[path] ?? [:]
        for key in Array(current.keys) {
            var items = current[key] ?? []
            items.removeAll {
                let cmd = $0.command["golensCommand"] as? String ?? ""
                return cmd.hasPrefix("goWork") || cmd.hasPrefix("goMod")
            }
            if items.isEmpty {
                current.removeValue(forKey: key)
            } else {
                current[key] = items
            }
        }
        for lens in doctorLenses {
            var items = (current[lens.line] ?? []).filter {
                ($0.command["golensCommand"] as? String) != (lens.command["golensCommand"] as? String)
                    || ($0.command["arg"] as? String) != (lens.command["arg"] as? String)
            }
            items.append(lens)
            current[lens.line] = items
        }
        goplsLenses[path] = current
        publishModuleDoctorDiagnostics(dto.diagnostics ?? [], forPath: path, text: text, dropSafetyReplaces: dropSafetyReplaces)
        if let tv = editorTextView(forPath: path) ?? (activeTextView as? GoLensTextView) {
            tv.needsDisplay = true
            tv.redrawGutter()
        }
    }

    private static func mergingCachedUpgradeLenses(
        into doctorLenses: [CodeLensItem],
        existing: [Int: [CodeLensItem]],
        requires: [GoModRequireDTO],
        path: String
    ) -> [CodeLensItem] {
        var upgradeByModule: [String: (title: String, compact: String?, arg: String)] = [:]
        for items in existing.values {
            for item in items where (item.command["golensCommand"] as? String) == "goModGet" {
                guard let arg = item.command["arg"] as? String,
                      let mod = arg.split(separator: "@", maxSplits: 1).first.map(String.init),
                      !mod.isEmpty else { continue }
                upgradeByModule[mod] = (item.title, item.command["compactTitle"] as? String, arg)
            }
        }
        guard !upgradeByModule.isEmpty else { return doctorLenses }
        var extra: [CodeLensItem] = []
        for req in requires {
            guard let cached = upgradeByModule[req.module] else { continue }
            let targetVer = cached.arg.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard !targetVer.isEmpty, targetVer != req.version else { continue }
            var cmd: [String: Any] = ["golensCommand": "goModGet", "path": path, "line": req.line, "arg": cached.arg]
            if let compact = cached.compact, !compact.isEmpty {
                cmd["compactTitle"] = compact
            }
            extra.append(CodeLensItem(line: max(1, req.line), title: cached.title, command: cmd))
        }
        return doctorLenses + extra
    }

    @MainActor
    private func publishModuleDoctorDiagnostics(_ dtos: [GoModDiagnosticDTO], forPath path: String, text: String, dropSafetyReplaces: Bool = false) {
        let canon = Self.canonicalDiagnosticPath(path)
        let lines = text.components(separatedBy: "\n")
        let mapped: [DiagnosticData] = dtos.map { d in
            let zeroLine = max(0, d.line - 1)
            let lineLen = zeroLine < lines.count ? (lines[zeroLine] as NSString).length : 80
            return DiagnosticData(
                line: zeroLine,
                col: 0,
                endLine: zeroLine,
                endCol: max(1, lineLen),
                severity: d.severity,
                message: d.message,
                source: Self.moduleDoctorDiagnosticSource,
                code: d.code
            )
        }
        moduleDoctorBucket.set(mapped, forPath: canon, activeWorkspace: activeWorkspacePath)
        if dropSafetyReplaces, var safetyList = safetyDiagnostics[canon], !safetyList.isEmpty {
            safetyList.removeAll { ($0.code ?? "").hasPrefix("DEP_REPLACE:") }
            if safetyList.isEmpty {
                safetyDiagnostics.removeValue(forKey: canon)
            } else {
                safetyDiagnostics[canon] = safetyList
            }
        }
        _ = publishMergedDiagnostics(for: canon)
        NotificationCenter.default.post(name: .golensDiagnosticsChanged, object: canon)
    }

    @MainActor
    private func editorTextView(forPath path: String) -> GoLensTextView? {
        if let active = activeTextView as? GoLensTextView, active.filePath == path {
            return active
        }
        if let p = primaryTextView as? GoLensTextView, p.filePath == path {
            return p
        }
        if let s = secondaryTextView as? GoLensTextView, s.filePath == path {
            return s
        }
        return nil
    }

    @MainActor
    func explainModuleWhy(module: String, inFile path: String, line: Int) {
        let trimmedModule = module.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModule.isEmpty else {
            appendLog("Missing module name for go mod why.", isStderr: true)
            presentCommandFeedback("Select a dependency line in go.mod to inspect why it is used.", title: "Module Name Required")
            return
        }
        guard let textView = editorTextView(forPath: path) ?? (activeTextView as? GoLensTextView) else {
            appendLog("Open go.mod in an active editor tab to inspect \(trimmedModule).", isStderr: true)
            presentCommandFeedback("Open go.mod in the editor before running Why Used.", title: "Editor Not Focused")
            return
        }
        let requestID = textView.presentModuleWhyDocumentation(module: trimmedModule, line: line)
        appendLog("Running go mod why -m \(trimmedModule)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let jsonStr: String? = path.withCString { cPath in
                trimmedModule.withCString { cMod in
                    guard let ptr = InspectGoModFile(cPath, cMod, 2) else { return nil }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }
            let reply: GoModWhyReplyDTO
            if let jsonStr,
               let decoded = try? JSONDecoder().decode(GoModWhyReplyDTO.self, from: Data(jsonStr.utf8)) {
                reply = decoded
            } else {
                reply = GoModWhyReplyDTO(
                    module: trimmedModule,
                    needed: false,
                    summary: "",
                    error: "Could not execute go mod why for \(trimmedModule)."
                )
            }
            let markdown = GoModDoctorHelpers.formatGoModWhyMarkdown(module: trimmedModule, reply: reply)
            DispatchQueue.main.async {
                guard let self else { return }
                textView.updateModuleWhyDocumentation(id: requestID, markdown: markdown)
                if let err = reply.error, !err.isEmpty {
                    self.appendLog("go mod why -m \(trimmedModule) failed: \(err)", isStderr: true)
                } else {
                    self.appendLog("go mod why -m \(trimmedModule): \(reply.summary)")
                }
            }
        }
    }

    @MainActor
    func dropReplaceDirective(inFile path: String, line: Int) {
        guard let original = currentManifestText(forPath: path) else {
            appendLog("Could not read \((path as NSString).lastPathComponent).", isStderr: true)
            presentCommandFeedback("Could not read \((path as NSString).lastPathComponent) to drop the replace directive.", title: "Drop Replace Failed")
            return
        }
        let updated = GoModDoctorHelpers.removingLocalReplaces(in: original, matchingLines: [line])
        guard updated != original else {
            appendLog("No matching replace directive found on line \(line).", isStderr: true)
            return
        }
        applyManifestReplacement(updated, toFile: path, actionName: "Drop Replace", logMessage: "Removed local replace directive on line \(line) in \((path as NSString).lastPathComponent).")
    }

    @MainActor
    func openReplacedModule(targetPath rawTarget: String, sourceFile: String) {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("Missing target path for replace directive.", isStderr: true)
            presentCommandFeedback("This replace directive does not specify a target path.", title: "Missing Target Path")
            return
        }
        let resolved: String
        if trimmed.hasPrefix("/") {
            resolved = trimmed
        } else {
            let baseDir = (sourceFile as NSString).deletingLastPathComponent
            resolved = URL(fileURLWithPath: baseDir).appendingPathComponent(trimmed).standardized.path
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            appendLog("Local replace target path not found: \(resolved)", isStderr: true)
            presentCommandFeedback("The target directory “\((resolved as NSString).lastPathComponent)” does not exist at \(resolved).", title: "Replaced Module Not Found")
            return
        }
        if isDir.boolValue {
            let childMod = (resolved as NSString).appendingPathComponent("go.mod")
            if FileManager.default.fileExists(atPath: childMod) {
                openFile(childMod)
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: resolved)
            }
        } else {
            openFile(resolved)
        }
    }

    @MainActor
    func updateGoWorkGoVersion(inFile path: String, version: String) {
        guard let original = currentManifestText(forPath: path) else {
            appendLog("Could not read go.work.", isStderr: true)
            presentCommandFeedback("Open or save go.work before updating its Go version.", title: "Update go.work Failed")
            return
        }
        let updated = GoModDoctorHelpers.updatingGoWorkVersion(in: original, to: version)
        guard updated != original else { return }
        applyManifestReplacement(updated, toFile: path, actionName: "Update go.work Go Version", logMessage: "Updated go.work Go directive to \(version).")
    }

    @MainActor
    func addModuleToGoWork(inFile path: String, relPath: String) {
        guard let original = currentManifestText(forPath: path) else {
            appendLog("Could not read go.work.", isStderr: true)
            presentCommandFeedback("Open or save go.work before adding a module.", title: "Update go.work Failed")
            return
        }
        let updated = GoModDoctorHelpers.addingUseModule(in: original, relPath: relPath)
        guard updated != original else { return }
        applyManifestReplacement(updated, toFile: path, actionName: "Add Module to go.work", logMessage: "Added \(relPath) to go.work.")
    }

    @MainActor
    func dropUseFromGoWork(inFile path: String, rawEntry: String) {
        guard let original = currentManifestText(forPath: path) else {
            appendLog("Could not read go.work.", isStderr: true)
            presentCommandFeedback("Open or save go.work before removing an entry.", title: "Update go.work Failed")
            return
        }
        let updated = GoModDoctorHelpers.removingUseModule(in: original, rawEntry: rawEntry)
        guard updated != original else { return }
        applyManifestReplacement(updated, toFile: path, actionName: "Remove Missing Module", logMessage: "Removed \(rawEntry) from go.work.")
    }

    @MainActor
    func syncGoWorkspace(goWorkPath: String) {
        let target = goWorkPath.isEmpty ? activeFilePath : goWorkPath
        appendLog("Running go work sync…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let jsonStr: String? = target.withCString { cPath in
                guard let ptr = InspectGoModFile(cPath, nil, 3) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
            let result = jsonStr.flatMap { try? JSONDecoder().decode(GoWorkSyncResultDTO.self, from: Data($0.utf8)) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let result, result.ok {
                    self.appendLog("go work sync completed.")
                    if let session = self.documents[target], let tv = self.editorTextView(forPath: target) ?? self.activeTextView {
                        self.reloadCodeLens(forPath: target, textView: tv)
                        self.reloadModuleDoctorState(forPath: target, version: session.version)
                    }
                    DocumentationService.shared.invalidate(root: self.activeWorkspacePath)
                    self.refreshWorkspaceHealth()
                    self.refreshGitStatus()
                } else {
                    let msg = result?.error ?? "go work sync failed."
                    self.appendLog("go work sync failed: \(msg)", isStderr: true)
                    self.presentCommandFeedback(msg, title: "Sync Workspace Failed")
                }
            }
        }
    }

    @MainActor
    func changedGoModLocalReplaces() -> [GoModCommitReplaceSummary] {
        var candidates: [String] = []
        var seenCanon = Set<String>()

        func consider(_ rawPath: String) {
            guard (rawPath as NSString).lastPathComponent == "go.mod" else { return }
            let canon = Self.canonicalizePath(rawPath)
            guard seenCanon.insert(canon).inserted else { return }
            candidates.append(rawPath)
        }

        for file in git.changedFiles where file.status != "D" {
            consider(file.absolutePath)
        }
        for path in editedWorkspacePathsNotInGit {
            consider(path)
        }
        let wsCanon = Self.canonicalizePath(activeWorkspacePath)
        for (path, session) in documents where session.isEdited {
            let fileCanon = Self.canonicalizePath(path)
            if !wsCanon.isEmpty && (fileCanon == wsCanon || fileCanon.hasPrefix(wsCanon + "/")) {
                consider(path)
            }
        }

        var summaries: [GoModCommitReplaceSummary] = []
        for path in candidates {
            guard let text = currentManifestText(forPath: path) else { continue }
            let local = GoModDoctorHelpers.localReplaces(in: text)
            guard !local.isEmpty else { continue }
            let rel = projectRelativePath(path)
            let displayRel = rel.isEmpty ? (path as NSString).lastPathComponent : rel
            summaries.append(GoModCommitReplaceSummary(path: path, relativePath: displayRel, directives: local))
        }
        return summaries
    }

    @MainActor
    func dropAllLocalReplacesBeforeCommit() async {
        let summaries = changedGoModLocalReplaces()
        guard !summaries.isEmpty else { return }
        let stagedCanonPaths = Set(git.changedFiles.filter(\.isStaged).map { Self.canonicalizePath($0.absolutePath) })
        let repo = activeWorkspacePath
        var restageRelPaths: [String] = []

        for summary in summaries {
            let path = summary.path
            guard let original = currentManifestText(forPath: path) else { continue }
            let updated = GoModDoctorHelpers.removingLocalReplaces(in: original)
            guard updated != original else { continue }

            if let session = documents[path] {
                let range = NSRange(location: 0, length: (session.storage.string as NSString).length)
                applyRanges([(range, updated)], in: session, actionName: "Drop Local Replaces")
                let saved = await withCheckedContinuation { continuation in
                    save(session) { ok in continuation.resume(returning: ok) }
                }
                if !saved {
                    try? updated.write(toFile: path, atomically: true, encoding: .utf8)
                }
            } else {
                do {
                    try updated.write(toFile: path, atomically: true, encoding: .utf8)
                    InvalidateWorkspaceSymbolFile(path)
                    LSPClient.notifyWatchedFilesChanged([path])
                } catch {
                    appendLog("Failed to update \(summary.relativePath): \(error.localizedDescription)", isStderr: true)
                    continue
                }
            }

            let canon = Self.canonicalizePath(path)
            if stagedCanonPaths.contains(canon) {
                let rel = Self.gitRelativePath(forAbsolutePath: path, from: repo)
                if !rel.isEmpty {
                    restageRelPaths.append(rel)
                }
            }
            refreshModuleDoctorFromText(forPath: path, content: updated, dropSafetyReplaces: true)
            appendLog("Removed \(summary.directives.count) local replace directive(s) from \(summary.relativePath).")
        }

        if !restageRelPaths.isEmpty && !repo.isEmpty {
            _ = try? await runGit(args: ["add", "--"] + restageRelPaths, in: repo)
        }
        refreshGitStatus()
        refreshActiveFileDiff()
        refreshWorkspaceHealth()
    }

    @MainActor
    private func currentManifestText(forPath path: String) -> String? {
        if let session = documents[path] {
            return session.storage.string
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @MainActor
    private func applyManifestReplacement(_ updated: String, toFile path: String, actionName: String, logMessage: String) {
        if let session = documents[path] {
            let fullRange = NSRange(location: 0, length: (session.storage.string as NSString).length)
            applyRanges([(fullRange, updated)], in: session, actionName: actionName)
            refreshModuleDoctorFromText(forPath: path, content: updated, dropSafetyReplaces: false)
            save(session) { [weak self] _ in
                guard let self else { return }
                DocumentationService.shared.invalidate(root: self.activeWorkspacePath)
                self.refreshModuleDoctorFromText(forPath: path, content: updated, dropSafetyReplaces: false)
                self.refreshWorkspaceHealth()
                self.refreshGitStatus()
            }
        } else {
            do {
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
                InvalidateWorkspaceSymbolFile(path)
                LSPClient.notifyWatchedFilesChanged([path])
                DocumentationService.shared.invalidate(root: activeWorkspacePath)
                refreshModuleDoctorFromText(forPath: path, content: updated, dropSafetyReplaces: false)
                refreshWorkspaceHealth()
                refreshGitStatus()
            } catch {
                appendLog("Failed to save \((path as NSString).lastPathComponent): \(error.localizedDescription)", isStderr: true)
                return
            }
        }
        appendLog(logMessage)
    }
}
