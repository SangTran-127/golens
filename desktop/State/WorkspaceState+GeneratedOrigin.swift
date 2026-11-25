import Foundation
import GoLensFoundation

extension WorkspaceState {
    func generatedOrigin(for path: String) -> GeneratedFileOriginResult? {
        diagnosticsAndLenses.generatedOriginCache.origin(for: path)
    }

    private func storeGeneratedOrigin(_ value: GeneratedFileOriginResult?, for path: String, version: Int) {
        diagnosticsAndLenses.generatedOriginCache.store(value, for: path, version: version)
    }

    func refreshGeneratedOrigin(for path: String, text: String? = nil, version: Int? = nil) {
        guard path.hasSuffix(".go"), !path.isEmpty else {
            diagnosticsAndLenses.generatedOriginCache.remove(for: path)
            return
        }
        let session = documents[path]
        if let session, !session.syncsToCore {
            storeGeneratedOrigin(nil, for: path, version: session.version)
            return
        }
        let targetVersion = version ?? session?.version ?? 0
        if diagnosticsAndLenses.generatedOriginCache.hasCachedVersion(targetVersion, for: path) {
            return
        }
        let sourceText = text ?? session?.storage.string
        guard let sourceText else { return }
        guard GeneratedFileOrigin.parseHeader(sourceText) != nil else {
            storeGeneratedOrigin(nil, for: path, version: targetVersion)
            return
        }
        let workspaceRoot = activeWorkspacePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = GeneratedFileOrigin.resolve(
                content: sourceText,
                goFilePath: path,
                workspaceRoot: workspaceRoot
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if let current = self.documents[path], current.version != targetVersion {
                    return
                }
                self.storeGeneratedOrigin(resolved, for: path, version: targetVersion)
            }
        }
    }

    func clearGeneratedOriginCache(for path: String? = nil) {
        if let path {
            diagnosticsAndLenses.generatedOriginCache.remove(for: path)
        } else {
            diagnosticsAndLenses.generatedOriginCache.clear()
        }
    }

    func openGeneratedFileOrigin(for goPath: String, line1Based: Int? = nil) {
        let workspaceRoot = activeWorkspacePath
        let content = documents[goPath]?.storage.string ?? (try? String(contentsOfFile: goPath, encoding: .utf8)) ?? ""
        let origin = generatedOrigin(for: goPath)
            ?? GeneratedFileOrigin.resolve(content: content, goFilePath: goPath, workspaceRoot: workspaceRoot)

        if let line1Based, !content.isEmpty,
           let mapped = GeneratedFileOrigin.mappedOriginLocation(
               in: content,
               forGeneratedLine: line1Based,
               goFilePath: goPath,
               workspaceRoot: workspaceRoot
           ),
           FileManager.default.fileExists(atPath: mapped.path) {
            pendingJumpToLine = mapped.line
            pendingJumpToCol = 1
            openFile(mapped.path)
            return
        }

        if let origin, let sourcePath = origin.sourcePath, FileManager.default.fileExists(atPath: sourcePath) {
            pendingJumpToLine = max(1, origin.defaultLine)
            pendingJumpToCol = 1
            openFile(sourcePath)
            return
        }

        if let directive = origin?.generateDirective, FileManager.default.fileExists(atPath: directive.filePath) {
            pendingJumpToLine = max(1, directive.line)
            pendingJumpToCol = 1
            openFile(directive.filePath)
            return
        }

        presentCommandFeedback(
            "The origin source file could not be found on disk.",
            title: "Open Source",
            tone: .warning
        )
    }

    func regenerateGeneratedFile(for goPath: String) {
        guard !isRunning else {
            presentCommandFeedback(
                "Wait for the active task to finish before running code generation.",
                title: "Regenerate"
            )
            return
        }
        let workspaceRoot = activeWorkspacePath
        let content = documents[goPath]?.storage.string ?? (try? String(contentsOfFile: goPath, encoding: .utf8)) ?? ""
        let origin = generatedOrigin(for: goPath)
            ?? GeneratedFileOrigin.resolve(content: content, goFilePath: goPath, workspaceRoot: workspaceRoot)
        guard let directive = origin?.generateDirective else {
            presentCommandFeedback(
                "No matching //go:generate directive was found in this package.",
                title: "Regenerate"
            )
            return
        }
        runGoGenerate(forPath: directive.filePath)
    }
}
