import AppKit
import Foundation
import GoLensFoundation

enum GeneratorPreviewKey {
    static let jsonToGoStruct = "preview.jsonToGoStruct"
    static let interfaceMock = "preview.interfaceMock"
    static let enumMethods = "preview.enumMethods"
    static let constructor = "preview.constructor"
    static let fuzzTest = "preview.fuzzTest"
    static let benchmarkGen = "preview.benchmarkGen"
}

struct CaretHistoryEntry: Equatable {
    let path: String
    let line: Int
    let col: Int
}

struct SyntaxByteSpan: Codable, Equatable {
    let startByte: Int
    let endByte: Int
}

struct FillStructResultDTO: Codable, Hashable {
    let updatedSource: String
    let structName: String
    let addedFieldCount: Int
    let addedFields: [String]?
    let error: String?
}

extension WorkspaceState {
    func recordNavigationJump(toPath targetPath: String, line: Int, col: Int) {
        guard !isNavigatingHistory, !targetPath.isEmpty else { return }
        let clampedLine = max(1, line)
        let clampedCol = max(1, col)

        if !activeFilePath.isEmpty,
           navigationIndex >= 0,
           navigationIndex < navigationCaretHistory.count,
           navigationCaretHistory[navigationIndex].path == activeFilePath {
            navigationCaretHistory[navigationIndex] = CaretHistoryEntry(
                path: activeFilePath,
                line: max(1, cursorLine),
                col: max(1, cursorCol)
            )
        } else if !activeFilePath.isEmpty, navigationHistory.isEmpty {
            navigationHistory.append(activeFilePath)
            navigationCaretHistory.append(CaretHistoryEntry(
                path: activeFilePath,
                line: max(1, cursorLine),
                col: max(1, cursorCol)
            ))
            navigationIndex = 0
        }

        if targetPath == activeFilePath {
            guard clampedLine != max(1, cursorLine) || clampedCol != max(1, cursorCol) else { return }
            if navigationIndex >= 0 && navigationIndex < navigationHistory.count - 1 {
                navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
                if navigationCaretHistory.count > navigationIndex + 1 {
                    navigationCaretHistory = Array(navigationCaretHistory.prefix(navigationIndex + 1))
                }
            }
            navigationHistory.append(targetPath)
            navigationCaretHistory.append(CaretHistoryEntry(
                path: targetPath,
                line: clampedLine,
                col: clampedCol
            ))
            if navigationHistory.count > Self.maxNavigationHistory {
                let excess = navigationHistory.count - Self.maxNavigationHistory
                navigationHistory.removeFirst(excess)
                if navigationCaretHistory.count >= excess {
                    navigationCaretHistory.removeFirst(excess)
                }
            }
            navigationIndex = navigationHistory.count - 1
        } else {
            pendingJumpToLine = clampedLine
            pendingJumpToCol = clampedCol
        }
    }

    func restoreCaretLocation(line: Int, column: Int, inPath path: String) {
        let clampedLine = max(1, line)
        let clampedCol = max(1, column)
        cursorLine = clampedLine
        cursorCol = clampedCol
        if activeFilePath == path {
            moveActiveTextViewCaret(toLine: clampedLine, column: clampedCol, inPath: path)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.activeFilePath == path else { return }
            self.cursorLine = clampedLine
            self.cursorCol = clampedCol
            self.moveActiveTextViewCaret(toLine: clampedLine, column: clampedCol, inPath: path)
        }
    }

    private func moveActiveTextViewCaret(toLine line: Int, column: Int, inPath path: String) {
        guard let textView = activeTextView else { return }
        if let session = documents[path],
           let location = session.offset(line: max(0, line - 1), utf16Column: max(0, column - 1)) {
            let range = NSRange(location: location, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            lsp.hoverText = nil
            return
        }
        let text = textView.string
        let targetRange = Self.utf16RangeForLineAndColumn(in: text, line: line, column: column)
        textView.setSelectedRange(targetRange)
        textView.scrollRangeToVisible(targetRange)
        lsp.hoverText = nil
    }

    static func utf16RangeForLineAndColumn(in text: String, line: Int, column: Int) -> NSRange {
        let targetLine = max(1, line)
        let targetCol = max(1, column)
        var currentLine = 1
        var lineStartIdx = text.startIndex

        var idx = text.startIndex
        while idx < text.endIndex && currentLine < targetLine {
            if text[idx] == "\n" {
                currentLine += 1
                lineStartIdx = text.index(after: idx)
            }
            idx = text.index(after: idx)
        }

        var lineEndIdx = lineStartIdx
        while lineEndIdx < text.endIndex && text[lineEndIdx] != "\n" {
            lineEndIdx = text.index(after: lineEndIdx)
        }

        var caretIdx = lineStartIdx
        var colCount = 1
        while caretIdx < lineEndIdx && colCount < targetCol {
            caretIdx = text.index(after: caretIdx)
            colCount += 1
        }

        return NSRange(caretIdx..<caretIdx, in: text)
    }

    func expandSyntaxSelection() {
        guard let tv = activeTextView else { return }
        let text = tv.string
        guard !text.isEmpty else { return }

        let currentNSRange = tv.selectedRange()
        guard let swiftRange = Range(currentNSRange, in: text) else { return }

        let selStartByte = text.utf8.distance(from: text.startIndex, to: swiftRange.lowerBound)
        let selEndByte = text.utf8.distance(from: text.startIndex, to: swiftRange.upperBound)

        if transientEditorState.lastExpandedRange != currentNSRange || transientEditorState.syntaxSelectionPath != activeFilePath {
            transientEditorState.syntaxSelectionStack.removeAll()
            transientEditorState.syntaxAnchorByteOffset = selStartByte
            transientEditorState.syntaxSelectionPath = activeFilePath
        }

        let queryOffset = transientEditorState.syntaxAnchorByteOffset ?? selStartByte
        let spans = Self.querySyntaxSelectionSpans(in: text, byteOffset: queryOffset)
        guard !spans.isEmpty else { return }

        guard let nextSpan = spans.first(where: { span in
            span.startByte <= selStartByte
                && span.endByte >= selEndByte
                && (span.startByte < selStartByte || span.endByte > selEndByte)
        }) else {
            return
        }

        guard let nextNSRange = Self.nsRangeForByteSpan(nextSpan, in: text) else { return }
        transientEditorState.syntaxSelectionStack.append(currentNSRange)
        transientEditorState.lastExpandedRange = nextNSRange
        tv.setSelectedRange(nextNSRange)
        tv.scrollRangeToVisible(nextNSRange)
    }

    func shrinkSyntaxSelection() {
        guard let tv = activeTextView else { return }
        let text = tv.string
        guard !text.isEmpty else { return }

        let currentNSRange = tv.selectedRange()
        if transientEditorState.lastExpandedRange == currentNSRange,
           transientEditorState.syntaxSelectionPath == activeFilePath,
           let previousRange = transientEditorState.syntaxSelectionStack.popLast() {
            transientEditorState.lastExpandedRange = previousRange
            tv.setSelectedRange(previousRange)
            tv.scrollRangeToVisible(previousRange)
            return
        }

        guard let swiftRange = Range(currentNSRange, in: text), currentNSRange.length > 0 else { return }
        let selStartByte = text.utf8.distance(from: text.startIndex, to: swiftRange.lowerBound)
        let selEndByte = text.utf8.distance(from: text.startIndex, to: swiftRange.upperBound)
        let queryOffset = transientEditorState.syntaxAnchorByteOffset ?? selStartByte

        let spans = Self.querySyntaxSelectionSpans(in: text, byteOffset: queryOffset)
        if let narrowerSpan = spans.last(where: { span in
            span.startByte >= selStartByte
                && span.endByte <= selEndByte
                && (span.startByte > selStartByte || span.endByte < selEndByte)
        }), let narrowerRange = Self.nsRangeForByteSpan(narrowerSpan, in: text) {
            transientEditorState.lastExpandedRange = narrowerRange
            tv.setSelectedRange(narrowerRange)
            tv.scrollRangeToVisible(narrowerRange)
        } else {
            let collapsed = NSRange(location: currentNSRange.location, length: 0)
            transientEditorState.lastExpandedRange = nil
            transientEditorState.syntaxSelectionStack.removeAll()
            tv.setSelectedRange(collapsed)
        }
    }

    static func querySyntaxSelectionSpans(in text: String, byteOffset: Int) -> [SyntaxByteSpan] {
        return text.withCString { cSrc in
            guard let ptr = GoSyntaxSelectionRanges(cSrc, Int32(byteOffset)) else {
                return []
            }
            defer { FreeGoCString(ptr) }
            let jsonStr = String(cString: ptr)
            guard let data = jsonStr.data(using: .utf8),
                  let spans = try? JSONDecoder().decode([SyntaxByteSpan].self, from: data) else {
                return []
            }
            return spans
        }
    }

    static func nsRangeForByteSpan(_ span: SyntaxByteSpan, in text: String) -> NSRange? {
        let utf8 = text.utf8
        guard span.startByte >= 0,
              span.endByte >= span.startByte,
              span.endByte <= utf8.count else {
            return nil
        }
        let startUtf8 = utf8.index(utf8.startIndex, offsetBy: span.startByte)
        let endUtf8 = utf8.index(utf8.startIndex, offsetBy: span.endByte)
        guard let startIdx = startUtf8.samePosition(in: text),
              let endIdx = endUtf8.samePosition(in: text) else {
            return nil
        }
        return NSRange(startIdx..<endIdx, in: text)
    }

    func fetchWorkspaceInterfaceCandidates() -> [InterfaceCandidateItem] {
        let wsPath = activeWorkspacePath
        let curPath = activeFilePath
        return wsPath.withCString { cWs in
            curPath.withCString { cCur in
                guard let ptr = ListGoWorkspaceInterfaces(cWs, cCur) else {
                    return []
                }
                defer { FreeGoCString(ptr) }
                let jsonStr = String(cString: ptr)
                guard let data = jsonStr.data(using: .utf8),
                      let items = try? JSONDecoder().decode([InterfaceCandidateItem].self, from: data) else {
                    return []
                }
                return items
            }
        }
    }

    func siblingGoFilesForCurrentTab() -> [String] {
        let currentPath = activeFilePath
        guard !currentPath.isEmpty else { return [] }
        let dir = (currentPath as NSString).deletingLastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        let currentBase = (currentPath as NSString).lastPathComponent
        return entries
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && $0 != currentBase }
            .sorted()
    }

    func presentImplementInterfaceSheet() {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file to implement an interface.", title: "Implement Interface")
            return
        }
        if let tv = activeTextView, let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        let text = activeTextView?.string ?? documents[activeFilePath]?.storage.string ?? ""
        let decls = activeGoDeclarations.isEmpty ? findGoDeclarations(in: text) : activeGoDeclarations
        let structDecls = decls.filter { $0.kind == "struct" || $0.kind == "type" }
        let nearStruct = structDecls.last(where: { $0.line <= cursorLine }) ?? structDecls.first
        activeStructNameForInterface = nearStruct?.symbolName ?? ""
        interfaceCandidates = fetchWorkspaceInterfaceCandidates()
        showImplementInterfaceSheet = true
    }

    func performImplementInterface(_ interfaceName: String) {
        showImplementInterfaceSheet = false
        let trimmed = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performGoCodeGeneration(kind: "implement_interface", targetName: trimmed, title: "Implement Interface")
    }

    func presentMoveSymbolSheet() {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor on a top-level declaration to move it.", title: "Move Symbol")
            return
        }
        if let tv = activeTextView, let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        let text = activeTextView?.string ?? documents[activeFilePath]?.storage.string ?? ""
        let decls = activeGoDeclarations.isEmpty ? findGoDeclarations(in: text) : activeGoDeclarations
        let nearDecl = decls.last(where: { $0.line <= cursorLine }) ?? decls.first
        activeSymbolNameForMove = nearDecl?.symbolName ?? ""
        showMoveSymbolSheet = true
    }

    func performMoveSymbol(to targetFile: String) {
        showMoveSymbolSheet = false
        let trimmed = targetFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performGoCodeGeneration(kind: "move_symbol", targetName: trimmed, title: "Move Symbol")
    }

    func presentAttachProcessSheet() {
        if let tv = activeTextView, let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        refreshDebuggableProcesses()
        showAttachProcessSheet = true
    }

    func refreshDebuggableProcesses() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let ptr = ListGoProcesses() else { return }
            defer { FreeGoCString(ptr) }
            let jsonStr = String(cString: ptr)
            let procs = (try? JSONDecoder().decode([DebuggableProcess].self, from: Data(jsonStr.utf8))) ?? []
            DispatchQueue.main.async {
                self?.debuggableProcesses = procs
            }
        }
    }

    func attachToProcess(pid: Int) {
        showAttachProcessSheet = false
        guard pid > 0, !isRunning else { return }
        startAttachedDebugSession(attachPID: pid, remoteAddr: nil)
    }

    func attachToRemoteDelve(address: String) {
        showAttachProcessSheet = false
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        startAttachedDebugSession(attachPID: 0, remoteAddr: trimmed)
    }

    private func startAttachedDebugSession(attachPID: Int, remoteAddr: String?) {
        runFailure = nil
        debug.isDebugMode = true
        showConsole = true
        selectedConsoleTab = Self.debuggerTab
        debug.revealedOnPause = false
        selectedRunSessionId = nil
        consoleOutput.removeAll()
        consoleOutputBytes = 0
        if let remoteAddr, !remoteAddr.isEmpty {
            appendLog("Connecting to remote Delve at \(remoteAddr)…")
        } else {
            appendLog("Attaching debugger to PID \(attachPID)…")
        }

        var configDict: [String: Any] = [
            "workingDirectory": activeWorkspacePath,
            "activeFilePath": activeFilePath,
            "debugLogging": UserDefaults.standard.bool(forKey: Self.diagnosticLogsKey)
        ]
        if attachPID > 0 {
            configDict["attachPID"] = attachPID
        }
        if let remoteAddr, !remoteAddr.isEmpty {
            configDict["remoteAddr"] = remoteAddr
        }
        let configJsonStr: String
        if let data = try? JSONSerialization.data(withJSONObject: configDict, options: []),
           let str = String(data: data, encoding: .utf8) {
            configJsonStr = str
        } else {
            configJsonStr = "{}"
        }
        saveAllEdited { self.launchDebugSession(configJsonStr) }
    }

    func presentStructTagsSheet() {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor inside a struct declaration.", title: "Struct Tags")
            return
        }
        if let tv = activeTextView, let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        showStructTagsSheet = true
    }

    func applyStructTags(action: String, tags: [String], transform: String, omitEmpty: Bool) {
        showStructTagsSheet = false
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor inside a struct declaration.", title: "Struct Tags")
            return
        }
        let path = session.path
        let src = session.storage.string
        let byteOffset = session.utf8.byteOffset(tv.selectedRange().location)

        struct StructTagReq: Encodable {
            let path: String
            let src: String
            let offset: Int
            let action: String
            let tags: [String]
            let transform: String
            let omitempty: Bool
        }
        struct StructTagReply: Decodable {
            let editsByPath: [String: [LSPTextEdit]]?
            let error: String?
        }

        let payload = StructTagReq(
            path: path,
            src: src,
            offset: byteOffset,
            action: action,
            tags: tags,
            transform: transform,
            omitempty: omitEmpty
        )
        guard let reqData = try? JSONEncoder().encode(payload),
              let reqJSON = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the struct tag request.", title: "Struct Tags", tone: .failure)
            return
        }

        lspQueue.async { [weak self] in
            let replyStr: String? = reqJSON.withCString { cReq in
                guard let ptr = ModifyGoStructTags(cReq) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
            guard let replyStr,
                  let reply = try? JSONDecoder().decode(StructTagReply.self, from: Data(replyStr.utf8)) else {
                DispatchQueue.main.async {
                    self?.presentCommandFeedback("Could not read the struct declaration at the cursor.", title: "Struct Tags", tone: .failure)
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let err = reply.error, !err.isEmpty {
                    self.appendLog("Modify Struct Tags failed: \(err)")
                    self.presentCommandFeedback(Self.formatCommandReason(err, fallback: "Place the cursor inside a struct declaration."), title: "Struct Tags", tone: .warning)
                    return
                }
                guard let editsByPath = reply.editsByPath, !editsByPath.isEmpty else {
                    self.presentCommandFeedback("Struct tags already match the requested configuration.", title: "Struct Tags")
                    return
                }
                var changes: [String: [LSPTextEdit]] = [:]
                for (editPath, edits) in editsByPath where !edits.isEmpty {
                    changes[lspURI(forPath: editPath)] = edits
                }
                guard !changes.isEmpty else {
                    self.presentCommandFeedback("Struct tags already match the requested configuration.", title: "Struct Tags")
                    return
                }
                let wsEdit = WorkspaceEdit(changes: changes)
                self.applyWorkspaceEdit(wsEdit, activeTextView: self.activeTextView)
                if let tv = self.activeTextView as? GoLensTextView {
                    (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
                    tv.needsDisplay = true
                }
            }
        }
    }

    func presentPasteJSONStructSheet() {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file in the editor to insert a generated struct.", title: "Paste JSON as Go Struct")
            return
        }
        if let tv = activeTextView, let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        showPasteJSONStructSheet = true
    }

    func previewJSONToGoStruct(jsonText: String, typeName: String, completion: @escaping (String) -> Void) {
        BackgroundFFI.shared.run(GeneratorPreviewKey.jsonToGoStruct, debounce: 0.15, work: {
            Self.previewJSONToGoStructSync(jsonText: jsonText, typeName: typeName)
        }, deliver: completion)
    }

    func previewJSONToGoStruct(jsonText: String, typeName: String) -> String {
        Self.previewJSONToGoStructSync(jsonText: jsonText, typeName: typeName)
    }

    private static func previewJSONToGoStructSync(jsonText: String, typeName: String) -> String {
        struct Req: Encodable {
            let jsonText: String
            let typeName: String
        }
        struct Resp: Decodable {
            let goCode: String?
            let error: String?
        }
        guard let data = try? JSONEncoder().encode(Req(jsonText: jsonText, typeName: typeName)),
              let reqStr = String(data: data, encoding: .utf8) else {
            return "// Invalid request"
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = ConvertJSONToGoStruct(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr,
              let resp = try? JSONDecoder().decode(Resp.self, from: Data(replyStr.utf8)) else {
            return "// Failed to parse JSON"
        }
        if let err = resp.error, !err.isEmpty {
            return "// \(err)"
        }
        return resp.goCode ?? "// Empty output"
    }

    func insertJSONStructIntoEditor(jsonText: String, typeName: String) {
        showPasteJSONStructSheet = false
        let code = previewJSONToGoStruct(jsonText: jsonText, typeName: typeName)
        guard !code.isEmpty, !code.hasPrefix("//"),
              let textView = activeTextView as? GoLensTextView,
              textView.isEditable else {
            let reason = code.hasPrefix("// ") ? String(code.dropFirst(3)) : "Open a writable Go file and enter valid JSON."
            presentCommandFeedback(Self.formatCommandReason(reason, fallback: "Open a writable Go file and enter valid JSON."), title: "Paste JSON as Go Struct", tone: .warning)
            return
        }
        let ns = textView.string as NSString
        let caretLoc = min(max(0, textView.selectedRange().location), ns.length)
        let caretLineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: caretLoc, length: 0)))
        var depth = 0
        var inBacktick = false
        var inQuotes = false
        var escaped = false
        var insertPos = ns.length
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if escaped {
                escaped = false
                continue
            }
            if inQuotes {
                if ch == 0x5C { escaped = true }
                else if ch == 0x22 { inQuotes = false }
                continue
            }
            if inBacktick {
                if ch == 0x60 { inBacktick = false }
                continue
            }
            if ch == 0x22 { inQuotes = true; continue }
            if ch == 0x60 { inBacktick = true; continue }
            if ch == 0x7B { depth += 1 }
            else if ch == 0x7D { depth = max(0, depth - 1) }

            if i + 1 >= caretLineEnd && depth == 0 && (ch == 0x0A || i + 1 == ns.length) {
                insertPos = i + 1
                break
            }
        }
        let prefix = (insertPos > 0 && ns.character(at: insertPos - 1) != 0x0A) ? "\n\n" : "\n"
        let insertion = prefix + code + "\n"
        textView.window?.makeFirstResponder(textView)
        textView.breakUndoCoalescing()
        textView.insertText(insertion, replacementRange: NSRange(location: insertPos, length: 0))
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName("Insert JSON Struct")
        let newCaret = insertPos + (prefix as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.scrollRangeToVisible(NSRange(location: newCaret, length: (code as NSString).length))
        let (line, col) = textView.lineAndCol(forCharacterIndex: newCaret)
        cursorLine = line
        cursorCol = col
    }

    var showInlineGitBlame: Bool {
        UserDefaults.standard.object(forKey: "GoLensShowInlineGitBlame") as? Bool ?? true
    }

    func toggleInlineGitBlame() {
        let current = showInlineGitBlame
        UserDefaults.standard.set(!current, forKey: "GoLensShowInlineGitBlame")
        updateCaretLineBlame()
    }

    static func inspectGoModLenses(forPath path: String, content: String, checkUpdates: Bool) -> [CodeLensItem] {
        guard (path as NSString).lastPathComponent == "go.mod",
              let dto = inspectModuleManifestReport(forPath: path, content: content, checkUpdates: checkUpdates) else {
            return []
        }
        return lenses(from: dto, path: path)
    }

    func checkGoModUpdates(forPath path: String? = nil) {
        let targetPath = path ?? activeFilePath
        guard (targetPath as NSString).lastPathComponent == "go.mod" else { return }
        let content = documents[targetPath]?.storage.string ?? ""
        appendLog("Checking module updates for \((targetPath as NSString).lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dto = Self.inspectModuleManifestReport(forPath: targetPath, content: content, checkUpdates: true)
            let modLenses = dto.map { Self.lenses(from: $0, path: targetPath) } ?? []
            DispatchQueue.main.async {
                guard let self, self.documents[targetPath] != nil else { return }
                guard let dto else {
                    let msg = "Could not inspect module updates for \((targetPath as NSString).lastPathComponent)."
                    self.appendLog(msg, isStderr: true)
                    self.presentCommandFeedback(msg, title: "Couldn’t Check Module Updates")
                    return
                }
                if let updateErr = dto.updateError, !updateErr.isEmpty {
                    self.appendLog("Check Module Updates failed: \(updateErr)", isStderr: true)
                    self.presentCommandFeedback(updateErr, title: "Couldn’t Check Module Updates")
                    return
                }
                var current = self.goplsLenses[targetPath] ?? [:]
                for key in Array(current.keys) {
                    var items = current[key] ?? []
                    items.removeAll { ($0.command["golensCommand"] as? String)?.hasPrefix("goMod") == true }
                    if items.isEmpty {
                        current.removeValue(forKey: key)
                    } else {
                        current[key] = items
                    }
                }
                for ml in modLenses {
                    var items = (current[ml.line] ?? []).filter {
                        ($0.command["golensCommand"] as? String) != (ml.command["golensCommand"] as? String)
                            || ($0.command["arg"] as? String) != (ml.command["arg"] as? String)
                    }
                    items.append(ml)
                    current[ml.line] = items
                }
                self.goplsLenses[targetPath] = current
                let upgradeCount = modLenses.filter { ($0.command["golensCommand"] as? String) == "goModGet" }.count
                self.appendLog(upgradeCount == 0 ? "All Go module dependencies are up to date." : "Found \(upgradeCount) module update(s) in go.mod.")
                self.activeTextView?.needsDisplay = true
            }
        }
    }

    func presentStructLayoutSheet() {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor inside a struct declaration.", title: "Inspect Struct Layout")
            return
        }
        let path = session.path
        let src = session.storage.string
        let byteOffset = Int32(session.utf8.byteOffset(tv.selectedRange().location))
        let configuredArch = UserDefaults.standard.string(forKey: "GoLensBuildGOARCH") ?? ""
        let arch = configuredArch.isEmpty ? BuildTargetStatusBarItem.hostGOARCH : configuredArch

        let jsonStr: String? = path.withCString { (cPath) -> String? in
            src.withCString { (cSrc) -> String? in
                arch.withCString { (cArch) -> String? in
                    guard let ptr = InspectGoStructLayout(cPath, cSrc, byteOffset, cArch) else { return nil }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }
        }
        let decodedReport = jsonStr.flatMap { try? JSONDecoder().decode(StructLayoutReportDTO.self, from: Data($0.utf8)) }
        guard let report = decodedReport,
              (report.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(decodedReport?.error, fallback: "Place the cursor inside a Go struct declaration to inspect its memory layout."),
                title: "Inspect Struct Layout"
            )
            return
        }
        if let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeStructLayoutReport = report
        showStructLayoutSheet = true
    }

    func optimizeCurrentStructLayout() {
        showStructLayoutSheet = false
        guard let report = activeStructLayoutReport,
              let editsByPath = report.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback("This struct’s field order is already optimal.", title: "Optimize Struct Layout")
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else { return }
        let wsEdit = WorkspaceEdit(changes: changes)
        applyWorkspaceEdit(wsEdit, activeTextView: activeTextView)
        if let tv = activeTextView as? GoLensTextView {
            (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
            tv.needsDisplay = true
        }
    }

    func applyGoIntention(_ action: String) {
        let actionTitle = UserMessage.humanized(action)
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file in the editor to run this code action.", title: actionTitle)
            return
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let offset: Int
            let action: String
        }
        struct Reply: Decodable {
            let editsByPath: [String: [LSPTextEdit]]?
            let error: String?
        }
        let path = session.path
        let src = session.storage.string
        let byteOffset = session.utf8.byteOffset(tv.selectedRange().location)
        guard let reqData = try? JSONEncoder().encode(Req(path: path, src: src, offset: byteOffset, action: action)),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the code action request.", title: actionTitle, tone: .failure)
            return
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = ApplyGoASTIntention(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(replyStr.utf8)) else {
            presentCommandFeedback("Could not analyze the statement at the cursor.", title: actionTitle, tone: .failure)
            return
        }
        if let err = reply.error, !err.isEmpty {
            appendLog("Code Action: \(err)")
            presentCommandFeedback(Self.formatCommandReason(err, fallback: "No matching syntax node found at the cursor."), title: actionTitle)
            return
        }
        guard let editsByPath = reply.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback("No changes were needed at the cursor.", title: actionTitle)
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else {
            presentCommandFeedback("No changes were needed at the cursor.", title: actionTitle)
            return
        }
        let wsEdit = WorkspaceEdit(changes: changes)
        applyWorkspaceEdit(wsEdit, activeTextView: activeTextView)
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
        tv.needsDisplay = true
    }

    func presentExtractMethodSheet() {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and select one or more statements to extract.", title: "Extract Function")
            return
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let startByte: Int
            let endByte: Int
        }
        let path = session.path
        let src = session.storage.string
        let sel = tv.selectedRange()
        let startByte = session.utf8.byteOffset(sel.location)
        let endByte = session.utf8.byteOffset(sel.location + sel.length)
        guard let reqData = try? JSONEncoder().encode(Req(path: path, src: src, startByte: startByte, endByte: endByte)),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the extract function preview.", title: "Extract Function", tone: .failure)
            return
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = InspectGoExtractMethod(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        let decodedPreview = replyStr.flatMap { try? JSONDecoder().decode(ExtractMethodPreviewDTO.self, from: Data($0.utf8)) }
        guard let preview = decodedPreview,
              (preview.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(decodedPreview?.error, fallback: "Select one or more complete statements inside a Go function to extract."),
                title: "Extract Function"
            )
            return
        }
        if let win = tv.window, win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeExtractMethodPreview = preview
        showExtractMethodSheet = true
    }

    func applyExtractMethod(funcName: String) {
        showExtractMethodSheet = false
        guard let preview = activeExtractMethodPreview,
              let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file in the editor to apply the extracted function.", title: "Extract Function")
            return
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let startByte: Int
            let endByte: Int
            let funcName: String
        }
        let path = session.path
        let src = session.storage.string
        guard let reqData = try? JSONEncoder().encode(Req(
            path: path,
            src: src,
            startByte: preview.startByte,
            endByte: preview.endByte,
            funcName: funcName
        )), let reqStr = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the extract function edit.", title: "Extract Function", tone: .failure)
            return
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = ApplyGoExtractMethod(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        let decodedReply = replyStr.flatMap { try? JSONDecoder().decode(ExtractMethodPreviewDTO.self, from: Data($0.utf8)) }
        guard let reply = decodedReply,
              let editsByPath = reply.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(decodedReply?.error, fallback: "Could not apply the extracted function edit."),
                title: "Extract Function",
                tone: .failure
            )
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else { return }
        applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: activeTextView, actionName: "Extract Function")
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
        tv.needsDisplay = true
    }

    func extractVariableAtSelection() {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and select an expression to extract into a variable.", title: "Extract Variable")
            return
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let startByte: Int
            let endByte: Int
            let varName: String
        }
        struct Reply: Decodable {
            let varName: String?
            let editsByPath: [String: [LSPTextEdit]]?
            let error: String?
        }
        let path = session.path
        let src = session.storage.string
        let sel = tv.selectedRange()
        let startByte = session.utf8.byteOffset(sel.location)
        let endByte = session.utf8.byteOffset(sel.location + sel.length)
        guard let reqData = try? JSONEncoder().encode(Req(path: path, src: src, startByte: startByte, endByte: endByte, varName: "")),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the extract variable request.", title: "Extract Variable", tone: .failure)
            return
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = ApplyGoExtractVariable(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(replyStr.utf8)) else {
            presentCommandFeedback("Select a valid Go expression to extract into a variable.", title: "Extract Variable")
            return
        }
        if let err = reply.error, !err.isEmpty {
            appendLog("Extract Variable: \(err)")
            presentCommandFeedback(Self.formatCommandReason(err, fallback: "Select a valid Go expression to extract into a variable."), title: "Can’t Extract Variable", tone: .warning)
            return
        }
        guard let editsByPath = reply.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback("Select a valid Go expression to extract into a variable.", title: "Extract Variable")
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else { return }
        applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: activeTextView, actionName: "Extract Variable")
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
        tv.needsDisplay = true
    }

    func inlineVariableAtCaret() {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor on a local variable to inline it.", title: "Inline Variable")
            return
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let offset: Int
        }
        struct Reply: Decodable {
            let varName: String?
            let editsByPath: [String: [LSPTextEdit]]?
            let error: String?
        }
        let path = session.path
        let src = session.storage.string
        let offset = session.utf8.byteOffset(tv.selectedRange().location)
        guard let reqData = try? JSONEncoder().encode(Req(path: path, src: src, offset: offset)),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the inline variable request.", title: "Inline Variable", tone: .failure)
            return
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = ApplyGoInlineVariable(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(replyStr.utf8)) else {
            presentCommandFeedback("Place the cursor on a local variable declaration or reference to inline it.", title: "Inline Variable")
            return
        }
        if let err = reply.error, !err.isEmpty {
            appendLog("Inline Variable: \(err)")
            presentCommandFeedback(Self.formatCommandReason(err, fallback: "Place the cursor on a local variable declaration or reference to inline it."), title: "Can’t Inline Variable", tone: .warning)
            return
        }
        guard let editsByPath = reply.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback("No inlineable usages found for the variable at the cursor.", title: "Inline Variable")
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else { return }
        applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: activeTextView, actionName: "Inline Variable")
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
        tv.needsDisplay = true
    }

    func toggleEscapeAnalysis() {
        showEscapeAnalysis.toggle()
        UserDefaults.standard.set(showEscapeAnalysis, forKey: "GoLensShowEscapeAnalysis")
        if showEscapeAnalysis {
            reloadEscapeAnalysis(forPath: activeFilePath)
        } else {
            escapeAnnotations.removeAll()
            activeTextView?.needsDisplay = true
            (activeTextView as? GoLensTextView)?.redrawGutter()
        }
    }

    func reloadEscapeAnalysis(forPath path: String? = nil) {
        escapeAnalysisWorkItem?.cancel()
        let targetPath = path ?? activeFilePath
        guard showEscapeAnalysis, !targetPath.isEmpty, targetPath.hasSuffix(".go") else { return }
        let workspaceDir = activeWorkspacePath
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showEscapeAnalysis, self.activeWorkspacePath == workspaceDir else { return }
            if let session = self.documents[targetPath], session.isEdited {
                self.save(session)
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let jsonStr: String? = workspaceDir.withCString { cWs in
                    targetPath.withCString { cPath in
                        guard let ptr = AnalyzeGoEscape(cWs, cPath) else { return nil }
                        defer { FreeGoCString(ptr) }
                        return String(cString: ptr)
                    }
                }
                guard let jsonStr,
                      let result = try? JSONDecoder().decode(EscapeAnalysisResultDTO.self, from: Data(jsonStr.utf8)) else {
                    return
                }
                let items = result.items ?? []
                var byLineList: [Int: [String]] = [:]
                var heapCount = 0
                var leakCount = 0
                var inlineCount = 0
                for item in items {
                    switch item.kind {
                    case "heap":
                        heapCount += 1
                        if byLineList[item.line, default: []].count < 2 {
                            byLineList[item.line, default: []].append(item.summary)
                        }
                    case "leak":
                        leakCount += 1
                        if byLineList[item.line, default: []].count < 2 {
                            byLineList[item.line, default: []].append(item.summary)
                        }
                    case "inline":
                        inlineCount += 1
                    case "bce_check", "inline_blocked":
                        if byLineList[item.line, default: []].count < 2 {
                            byLineList[item.line, default: []].append(item.summary)
                        }
                    default:
                        break
                    }
                }
                let byLine = byLineList.mapValues { $0.joined(separator: " · ") }
                DispatchQueue.main.async {
                    guard let self, self.showEscapeAnalysis else { return }
                    self.escapeAnnotations[targetPath] = byLine
                    let fileName = (targetPath as NSString).lastPathComponent
                    self.appendLog("Escape analysis for \(fileName): \(heapCount) heap escape(s), \(leakCount) leaking param(s), \(inlineCount) inlineable call(s).")
                    self.activeTextView?.needsDisplay = true
                    (self.activeTextView as? GoLensTextView)?.redrawGutter()
                }
            }
        }
        escapeAnalysisWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func searchWorkspaceSymbols(query: String, limit: Int = 100) -> [WorkspaceSymbolDTO] {
        guard !activeWorkspacePath.isEmpty else { return [] }
        let jsonStr: String? = activeWorkspacePath.withCString { cWs in
            query.withCString { cQuery in
                guard let ptr = SearchGoWorkspaceSymbols(cWs, cQuery, Int32(limit)) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
        }
        guard let jsonStr,
              let items = try? JSONDecoder().decode([WorkspaceSymbolDTO].self, from: Data(jsonStr.utf8)) else {
            return []
        }
        return items
    }

    func selectWorkspaceSymbol(_ item: WorkspaceSymbolDTO) {
        activePopup = nil
        guard !item.file.isEmpty else { return }
        recordNavigationJump(toPath: item.file, line: item.line, col: item.col)
        openFile(item.file)
        restoreCaretLocation(line: max(1, item.line), column: max(1, item.col), inPath: item.file)
    }

    func fillStructFieldsAtCursor() {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file and place the cursor inside a struct literal.", title: "Fill Struct Fields")
            return
        }
        let filePath = session.path
        let dirPath: String
        if !filePath.isEmpty {
            dirPath = (filePath as NSString).deletingLastPathComponent
        } else {
            dirPath = activeWorkspacePath
        }
        let currentSource = session.storage.string
        guard !currentSource.isEmpty else {
            presentCommandFeedback("Place the cursor inside a Go struct literal to fill missing fields.", title: "Fill Struct Fields")
            return
        }

        let (rawLine, rawCol) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
        let line = max(1, rawLine)
        let col = max(1, rawCol)
        cursorLine = line
        cursorCol = col

        let jsonStr: String? = dirPath.withCString { cDir in
            filePath.withCString { cFile in
                currentSource.withCString { cContent in
                    guard let ptr = FillGoStructFields(cDir, cFile, cContent, Int32(line), Int32(col)) else {
                        return nil
                    }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }
        }

        guard let jsonStr,
              let result = try? JSONDecoder().decode(FillStructResultDTO.self, from: Data(jsonStr.utf8)) else {
            presentCommandFeedback("Place the cursor inside a Go struct literal to fill missing fields.", title: "Fill Struct Fields")
            return
        }

        if let err = result.error, !err.isEmpty {
            appendLog("Fill Struct Fields: \(err)")
            presentCommandFeedback(Self.formatCommandReason(err, fallback: "Place the cursor inside a Go struct literal to fill missing fields."), title: "Fill Struct Fields", tone: .warning)
            return
        }

        guard !result.updatedSource.isEmpty, result.updatedSource != currentSource else {
            if !result.structName.isEmpty {
                let msg = "All fields on \(result.structName) are already populated."
                appendLog(msg)
                presentCommandFeedback(msg, title: "Fill Struct Fields")
            } else {
                presentCommandFeedback("Place the cursor inside a Go struct literal to fill missing fields.", title: "Fill Struct Fields")
            }
            return
        }

        replaceChangedRegion(with: result.updatedSource, in: session)
        editedFiles.insert(session.path)
        documentDidEdit(session)
        let (newLine, newCol) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
        cursorLine = max(1, newLine)
        cursorCol = max(1, newCol)
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv, immediate: true)
        activeGoDeclarations = findGoDeclarations(in: tv.string)
        tv.needsDisplay = true
        appendLog("Filled \(result.addedFieldCount) field(s) on \(result.structName)")
    }

    func applyInPlaceEdit(newText: String, actionName: String = "Edit", targetPath: String? = nil) {
        let resolvedPath = (targetPath?.isEmpty == false) ? targetPath! : activeFilePath
        guard !resolvedPath.isEmpty else {
            presentCommandFeedback("No active file is open to apply this edit.", title: actionName, tone: .warning)
            return
        }
        if documents[resolvedPath] == nil {
            loadDocument(resolvedPath)
        }
        guard let session = documents[resolvedPath] else {
            presentCommandFeedback("Could not open \((resolvedPath as NSString).lastPathComponent) to apply this edit.", title: actionName, tone: .failure)
            return
        }
        guard !newText.isEmpty, replaceChangedRegion(with: newText, in: session, actionName: actionName) else { return }
        editedFiles.insert(session.path)
        documentDidEdit(session)
        if let tv = textView(showing: session) {
            let (newLine, newCol) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
            cursorLine = max(1, newLine)
            cursorCol = max(1, newCol)
            (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv, immediate: true)
            activeGoDeclarations = tv.filePath.hasSuffix(".go") ? findGoDeclarations(in: tv.string) : []
            tv.needsDisplay = true
        }
    }

    func jumpToLocation(file: String, line: Int, column: Int = 1) {
        jumpToLocation(path: file, line: line, column: column)
    }

    @discardableResult
    func replaceChangedRegion(with newText: String, in session: DocumentSession, actionName: String? = nil) -> Bool {
        let old = session.storage.string as NSString
        let new = newText as NSString
        let oldLength = old.length
        let newLength = new.length
        let shared = min(oldLength, newLength)
        var prefix = 0
        while prefix < shared, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLength, prefix == newLength { return false }
        if prefix < oldLength { prefix = old.rangeOfComposedCharacterSequence(at: prefix).location }
        var suffix = 0
        while suffix < shared - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        while suffix > 0, old.rangeOfComposedCharacterSequence(at: oldLength - suffix).location != oldLength - suffix {
            suffix -= 1
        }
        let replaced = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let inserted = NSRange(location: prefix, length: newLength - prefix - suffix)
        let textView = textView(showing: session)
        let anchor = textView.flatMap { Self.viewportAnchor(in: $0) }
        applyRanges([(replaced, new.substring(with: inserted))], in: session, actionName: actionName)
        guard let textView else { return true }
        if let anchor {
            let delta = inserted.length - replaced.length
            let index = anchor.index >= NSMaxRange(replaced) ? anchor.index + delta : min(anchor.index, NSMaxRange(inserted))
            Self.restoreViewport(in: textView, index: index, offset: anchor.offset)
        }
        Self.revealChange(inserted, in: textView)
        return true
    }

    private static func lineRect(at index: Int, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager else { return nil }
        let length = (textView.string as NSString).length
        let clamped = min(max(0, index), length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: clamped, length: 0))
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: clamped), layoutManager.numberOfGlyphs - 1)
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    private static func viewportAnchor(in textView: NSTextView) -> (index: Int, offset: CGFloat)? {
        let visible = textView.visibleRect
        let caret = textView.selectedRange().location
        if let rect = lineRect(at: caret, in: textView), visible.intersects(rect) {
            return (caret, rect.minY - visible.minY)
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let point = NSPoint(x: visible.minX, y: visible.minY - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let rect = lineRect(at: index, in: textView) else { return nil }
        return (index, rect.minY - visible.minY)
    }

    private static func restoreViewport(in textView: NSTextView, index: Int, offset: CGFloat) {
        guard let rect = lineRect(at: index, in: textView) else { return }
        textView.scroll(NSPoint(x: textView.visibleRect.minX, y: max(0, rect.minY - offset)))
    }

    private static func revealChange(_ range: NSRange, in textView: NSTextView) {
        let text = textView.string as NSString
        guard range.location <= text.length else { return }
        var lines = text.lineRange(for: NSRange(location: range.location, length: min(range.length, text.length - range.location)))
        while lines.length > 0, CharacterSet.newlines.contains(UnicodeScalar(text.character(at: NSMaxRange(lines) - 1)) ?? " ") {
            lines.length -= 1
        }
        if let rect = lineRect(at: range.location, in: textView), !textView.visibleRect.contains(rect) {
            textView.scrollRangeToVisible(lines)
        }
        guard lines.length > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        textView.showFindIndicator(for: lines)
    }
}
