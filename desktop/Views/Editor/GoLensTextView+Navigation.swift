import SwiftUI
import AppKit
import GoLensFoundation

extension GoLensTextView {
    func lineTextAndColumn0(at charIndex: Int) -> (lineText: String, column0: Int)? {
        let ns = self.string as NSString
        guard charIndex >= 0 && charIndex <= ns.length else { return nil }
        let safeIndex = min(charIndex, max(0, ns.length - 1))
        let lineRange = ns.lineRange(for: NSRange(location: safeIndex, length: 0))
        let rawLine = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let col0 = max(0, charIndex - lineRange.location)
        return (rawLine, col0)
    }

    func openDocumentsTextMap() -> [String: String] {
        var map: [String: String] = [:]
        for (path, session) in self.workspaceState.documents {
            map[path] = session.storage.string
        }
        if !self.filePath.isEmpty {
            map[self.filePath] = self.string
        }
        return map
    }

    func openEnvDocumentsTextMap() -> [String: String] {
        var map: [String: String] = [:]
        for (path, session) in self.workspaceState.documents where EcosystemDocumentTools.isEnvFile(path) {
            map[path] = session.storage.string
        }
        if !self.filePath.isEmpty, EcosystemDocumentTools.isEnvFile(self.filePath) {
            map[self.filePath] = self.string
        }
        return map
    }

    @discardableResult
    func handleEnvCrossLinkJump(at charIndex: Int) -> Bool {
        let workspace = self.workspaceState
        guard !workspace.activeWorkspacePath.isEmpty,
              let (lineText, col0) = lineTextAndColumn0(at: charIndex) else {
            return false
        }
        if self.filePath.hasSuffix(".go"),
           let envKey = EcosystemDocumentTools.detectGoEnvKeyAtOffset(inLine: lineText, column0: col0) {
            let openDocs = openEnvDocumentsTextMap()
            if let def = EcosystemDocumentTools.findEnvDefinition(forKey: envKey, in: workspace.activeWorkspacePath, openDocuments: openDocs) {
                jumpTo(path: def.filePath, line: def.line, col: 1)
            } else {
                let msg = "Environment variable “\(envKey)” is not defined in workspace .env files."
                workspace.appendLog(msg)
                workspace.presentCommandFeedback(msg, title: "Environment Variable")
            }
            return true
        }
        if EcosystemDocumentTools.isEnvFile(self.filePath),
           let envKey = EcosystemDocumentTools.detectEnvKeyAtOffset(inLine: lineText, column0: col0) {
            let wsPath = workspace.activeWorkspacePath
            let openDocs = openDocumentsTextMap()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let usages = EcosystemDocumentTools.findGoEnvKeyUsages(
                    forKey: envKey,
                    in: wsPath,
                    openDocuments: openDocs
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    if usages.count == 1, let only = usages.first {
                        self.jumpTo(path: only.path, line: only.range.start.line + 1, col: only.range.start.character + 1)
                    } else if !usages.isEmpty {
                        workspace.showReferences(usages, for: envKey, kind: "Env Key Usages")
                    } else {
                        let msg = "No Go usages found for environment variable “\(envKey)”."
                        workspace.appendLog(msg)
                        workspace.presentCommandFeedback(msg, title: "Environment Variable")
                    }
                }
            }
            return true
        }
        return false
    }

    func goToDefinition(at charIndex: Int) {
        if EcosystemDocumentTools.isDockerfile(filePath) {
            if let stage = DockerfileAssist.stageReference(in: liveText, at: charIndex)?.stage {
                jumpTo(path: filePath, line: stage.line, col: 1)
            } else {
                self.workspaceState.presentCommandFeedback("Place the cursor on a Dockerfile build stage reference (such as COPY --from=stage).", title: "Go to Definition")
            }
            return
        }
        if EcosystemDocumentTools.isSQLFile(filePath) {
            openTableOrSQLMethod(at: charIndex)
            return
        }
        if handleEnvCrossLinkJump(at: charIndex) {
            return
        }
        let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
        let word = self.getWord(at: charIndex)
        let symbolName = word ?? "symbol"
        let path = self.filePath
        let workspace = self.workspaceState
        let currentResolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let onDeclaration = word.map { isDeclarationIdentifier($0, line: line, col: col) } ?? false
        if onDeclaration { measureLog("navigation: \(symbolName) is a declaration, showing usages directly") }
        self.workspaceState.runNavigationRequest(kind: onDeclaration ? "Usages" : "Definition", symbol: symbolName) { [weak self] setKind in
            if !onDeclaration {
                let locations: [LSPLocation]
                switch await LSPClient.shared.definitionResult(atLine: line, col: col, inPath: path) {
                case .success(let found): locations = found
                case .failure(let failure): return .failure(failure)
                }
                guard let first = locations.first else { return .success(.empty) }
                let targetLine = first.range.start.line + 1
                let targetResolved = URL(fileURLWithPath: first.path).resolvingSymlinksInPath().path
                if targetResolved != currentResolved || targetLine != line {
                    let queries = await workspace.sqlcQueryLocations(forDefinition: first)
                    if queries.count == 1, let query = queries.first {
                        return .success(.perform { self?.jumpTo(path: query.path, line: query.line, col: query.col) })
                    }
                    if queries.count > 1 {
                        return .success(.list(queries.map(\.lspLocation), kind: "SQL Queries"))
                    }
                    return .success(.perform {
                        GetStartedProgress.shared.complete(.goToDefinition)
                        self?.jumpTo(path: first.path, line: targetLine, col: first.range.start.character + 1)
                    })
                }
                setKind("Usages")
            }
            return await LSPClient.shared.referencesResult(atLine: line, col: col, inPath: path).map { refs -> NavigationOutcome in
                .list(Self.usagesExcludingDeclaration(refs, resolvedPath: currentResolved, line: line), kind: "Usages")
            }
        }
    }

    func goToSQLMethod(at charIndex: Int) {
        let (line, _) = lineAndCol(forCharacterIndex: charIndex)
        let path = filePath
        let text = string
        Task {
            guard let (query, _) = await self.workspaceState.sqlcQuery(inFile: path, text: text, line: line) else {
                self.workspaceState.presentCommandFeedback("Place the cursor inside an sqlc query annotation (-- name: QueryName :one).", title: "Go to SQL Method")
                return
            }
            if let go = query.go {
                jumpTo(path: go.path, line: go.line, col: go.col)
            } else {
                let msg = "\(query.name) has no generated Go method yet. Run sqlc generate first."
                self.workspaceState.appendLog(msg)
                self.workspaceState.presentCommandFeedback(msg, title: "Go to SQL Method")
            }
        }
    }

    private func isDeclarationIdentifier(_ word: String, line: Int, col: Int) -> Bool {
        guard filePath.hasSuffix(".go") else { return false }
        let length = word.utf16.count
        return self.workspaceState.findGoDeclarations(in: string).contains { decl in
            decl.line == line && decl.symbolName == word && col >= decl.col && col <= decl.col + length
        }
    }

    private static func usagesExcludingDeclaration(_ refs: [LSPLocation], resolvedPath: String, line: Int) -> [LSPLocation] {
        let filtered = refs.filter {
            !(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedPath && $0.range.start.line + 1 == line)
        }
        return filtered.isEmpty ? refs : filtered
    }

    func showUsagesForDeclaration(atLine lineNumber: Int) {
        let workspace = self.workspaceState
        let decl = workspace.activeGoDeclarations.first(where: { $0.line == lineNumber })
            ?? workspace.findGoDeclarations(in: self.string).first(where: { $0.line == lineNumber })
        let queryLine = decl?.line ?? lineNumber
        let queryCol = decl?.col ?? 1
        let symbolName = decl?.symbolName ?? "symbol"
        let path = self.filePath
        let currentResolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        workspace.runNavigationRequest(kind: "Usages", symbol: symbolName, showProgressImmediately: true) { _ in
            await LSPClient.shared.referencesResult(atLine: queryLine, col: queryCol, inPath: path).map { refs -> NavigationOutcome in
                .list(Self.usagesExcludingDeclaration(refs, resolvedPath: currentResolved, line: queryLine), kind: "Usages")
            }
        }
    }

    @objc func contextGoToImplementation(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        goToImplementation(at: charIndex)
    }

    func goToImplementation(at charIndex: Int) {
        let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
        let symbolName = self.getWord(at: charIndex) ?? "symbol"
        let path = self.filePath
        self.workspaceState.runNavigationRequest(kind: "Implementations", symbol: symbolName) { [weak self] _ in
            WorkspaceState.locationsOutcome(await LSPClient.shared.implementationResult(atLine: line, col: col, inPath: path), kind: "Implementations") { first in
                self?.jumpTo(path: first.path, line: first.range.start.line + 1, col: first.range.start.character + 1)
            }
        }
    }

    @objc func contextGoToTypeDefinition(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        goToTypeDefinition(at: charIndex)
    }

    func goToTypeDefinition(at charIndex: Int) {
        let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
        let symbolName = self.getWord(at: charIndex) ?? "symbol"
        let path = self.filePath
        self.workspaceState.runNavigationRequest(kind: "Type Definitions", symbol: symbolName) { [weak self] _ in
            WorkspaceState.locationsOutcome(await LSPClient.shared.typeDefinitionResult(atLine: line, col: col, inPath: path), kind: "Type Definitions") { first in
                self?.jumpTo(path: first.path, line: first.range.start.line + 1, col: first.range.start.character + 1)
            }
        }
    }

    @objc func contextJumpBetweenCodeAndTest(_ sender: NSMenuItem) {
        if let charIndex = sender.representedObject as? Int {
            let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
            self.workspaceState.cursorLine = line
            self.workspaceState.cursorCol = col
        }
        self.workspaceState.jumpBetweenCodeAndTest()
    }

    @objc func contextFindReferences(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        findReferences(at: charIndex)
    }

    func findReferences(at charIndex: Int) {
        let workspace = self.workspaceState
        if !workspace.activeWorkspacePath.isEmpty,
           let (lineText, col0) = lineTextAndColumn0(at: charIndex) {
            let openDocs = openDocumentsTextMap()
            if EcosystemDocumentTools.isEnvFile(self.filePath),
               let envKey = EcosystemDocumentTools.detectEnvKeyAtOffset(inLine: lineText, column0: col0) {
                let usages = EcosystemDocumentTools.findGoEnvKeyUsages(
                    forKey: envKey,
                    in: workspace.activeWorkspacePath,
                    openDocuments: openDocs
                )
                workspace.showReferences(usages, for: envKey, kind: "Env Key Usages")
                return
            }
            if self.filePath.hasSuffix(".go"),
               let envKey = EcosystemDocumentTools.detectGoEnvKeyAtOffset(inLine: lineText, column0: col0) {
                var usages = EcosystemDocumentTools.findGoEnvKeyUsages(
                    forKey: envKey,
                    in: workspace.activeWorkspacePath,
                    openDocuments: openDocs
                )
                if let def = EcosystemDocumentTools.findEnvDefinition(forKey: envKey, in: workspace.activeWorkspacePath, openDocuments: openDocs) {
                    let defLoc = LSPLocation(
                        uri: lspURI(forPath: def.filePath),
                        range: LSPRange(
                            start: LSPPosition(line: max(0, def.line - 1), character: 0),
                            end: LSPPosition(line: max(0, def.line - 1), character: def.key.utf16.count)
                        )
                    )
                    usages.insert(defLoc, at: 0)
                }
                workspace.showReferences(usages, for: envKey, kind: "Env Key References")
                return
            }
        }
        let (line, col) = self.lineAndCol(forCharacterIndex: charIndex)
        let symbolName = self.getWord(at: charIndex) ?? "symbol"
        let path = self.filePath
        workspace.runNavigationRequest(kind: "References", symbol: symbolName, showProgressImmediately: true) { _ in
            await LSPClient.shared.referencesResult(atLine: line, col: col, inPath: path).map { refs -> NavigationOutcome in .list(refs, kind: "References") }
        }
    }
}
