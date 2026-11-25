import AppKit
import SwiftUI

struct CoreReply {
    let result: Any?
    let error: String?

    init(_ c: UnsafeMutablePointer<CChar>?) {
        guard let c else { result = nil; error = "Language server is not running"; return }
        defer { FreeGoCString(c) }
        let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: c, count: strlen(c)), options: [.fragmentsAllowed])) as? [String: Any]
        result = obj?["result"].flatMap { $0 is NSNull ? nil : $0 }
        error = obj?["error"] as? String
    }
}

func jsonText(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

struct LSPCodeActionItem: Identifiable {
    let id = UUID()
    let title: String
    let kind: String
    let disabledReason: String?
    let isPreferred: Bool
    let raw: [String: Any]

    init?(_ raw: [String: Any]) {
        guard let title = raw["title"] as? String else { return nil }
        self.title = title
        self.kind = raw["kind"] as? String ?? ""
        self.disabledReason = (raw["disabled"] as? [String: Any])?["reason"] as? String
        self.isPreferred = raw["isPreferred"] as? Bool ?? false
        self.raw = raw
    }

    var section: String {
        if let sec = raw["section"] as? String { return sec }
        if kind.hasPrefix("quickfix") || kind.isEmpty { return "Quick Fix" }
        if kind.hasPrefix("refactor") { return "Refactor" }
        return "Source"
    }
}

struct InteractiveForm: Identifiable {
    let id = UUID()
    let title: String
    var params: [String: Any]
    var fields: [[String: Any]]

    var heading: String {
        var t = title
        while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast() }
        return t
    }

    var actionTitle: String {
        let verb = heading.split(separator: " ").first.map(String.init) ?? "OK"
        return verb.first?.isUppercase == true ? verb : "OK"
    }
}

final class CodeActionMenuTarget: NSObject {
    static let shared = CodeActionMenuTarget()
    var actions: [LSPCodeActionItem] = []

    var chosen: Int?

    @objc func perform(_ sender: NSMenuItem) {
        chosen = sender.tag
    }
}

extension WorkspaceState {
    static let unsupportedActionKinds = ["source.doc", "source.assembly", "source.freesymbols", "source.test", "source.splitPackage", "gopls.doc"]

    func diagnosticsJSON(for path: String) -> String {
        let diags: [[String: Any]] = (diagnostics[path] ?? []).map { d in
            ["range": ["start": ["line": d.line, "character": d.col], "end": ["line": d.endLine, "character": d.endCol]],
             "message": d.message, "severity": d.severity]
        }
        return jsonText(diags)
    }

    func requestCodeActions(in session: DocumentSession, range: NSRange, only: [String], completion: @escaping ([LSPCodeActionItem]) -> Void) {
        let path = session.path
        let start = session.utf8.byteOffset(range.location)
        let end = session.utf8.byteOffset(NSMaxRange(range))
        let diags = diagnosticsJSON(for: path)
        let onlyText = only.joined(separator: ",")
        lspRequestQueue.async {
            let reply = path.withCString { p in onlyText.withCString { o in diags.withCString { d in CoreReply(CodeActions(p, Int32(start), Int32(end), o, d)) } } }
            let order = ["Quick Fix": 0, "Refactor": 1, "Source": 2]
            let items = (reply.result as? [[String: Any]] ?? []).compactMap(LSPCodeActionItem.init).filter { item in
                !Self.unsupportedActionKinds.contains { item.kind.hasPrefix($0) }
            }.enumerated().sorted { (order[$0.element.section] ?? 3, $0.offset) < (order[$1.element.section] ?? 3, $1.offset) }.map(\.element)
            DispatchQueue.main.async { completion(items) }
        }
    }

    func showCodeActionsMenu(for textView: GoLensTextView, at characterIndex: Int? = nil, target explicitTarget: CodeActionTarget? = nil) {
        if let session = textView.document, EcosystemDocumentTools.isDockerfile(session.path) {
            let location = explicitTarget?.anchor ?? characterIndex ?? textView.selectedRange().location
            let line = session.lineAndColumn(at: location).line
            presentCodeActionsMenu(dockerfileFixItems(path: session.path, lines: [line]), in: textView, at: location)
            return
        }
        guard let session = textView.document, session.path.hasSuffix(".go"), session.syncsToCore else {
            presentCommandFeedback("Code actions are available inside Go source files and Dockerfiles.", title: "Code Actions")
            return
        }
        let target = explicitTarget ?? CodeActionTarget.caret(selection: textView.selectedRange(), characterIndex: characterIndex) { textView.wordRange(at: $0) }
        let range = target.range
        let caretLine = session.lineAndColumn(at: range.location).0
        let droppedError = textView.hasIgnoredErrorHint(line0: caretLine)
        let astPath = session.path
        let astContent = session.storage.string
        let astLine = caretLine + 1
        let pending = DispatchGroup()
        var astFixes: [[String: Any]] = []
        var fetched: [LSPCodeActionItem] = []
        pending.enter()
        BackgroundFFI.shared.run("codeActions.astQuickFixes", work: {
            Self.computeASTQuickFixes(filePath: astPath, content: astContent, line: astLine)
        }, deliver: { fixes in
            astFixes = fixes
            pending.leave()
        })
        pending.enter()
        requestCodeActions(in: session, range: range, only: []) { items in
            fetched = items
            pending.leave()
        }
        pending.notify(queue: .main) { [weak textView] in
            guard let textView, textView.document === session else { return }
            var items = fetched
            if let suggestion = textView.renameSuggestion,
               let rename = LSPCodeActionItem(["title": suggestion.title, "kind": "refactor.rename", "golens": "renameUsages"]) {
                let at = items.firstIndex { $0.section != "Quick Fix" } ?? items.endIndex
                items.insert(rename, at: at)
            }
            if droppedError {
                let golens = [["title": "Handle Error", "kind": "quickfix", "golens": "handleError", "line": caretLine],
                            ["title": "Ignore Error Explicitly", "kind": "quickfix", "golens": "ignoreError", "line": caretLine]]
                items.insert(contentsOf: golens.compactMap { LSPCodeActionItem($0) }, at: 0)
            }
            for fix in astFixes {
                if let title = fix["title"] as? String,
                   let updated = fix["updatedSource"] as? String {
                    let actionDict: [String: Any] = [
                        "title": title,
                        "kind": "quickfix.golens",
                        "golens": "astQuickFix",
                        "updatedSource": updated,
                        "summary": fix["summary"] as? String ?? ""
                    ]
                    if let item = LSPCodeActionItem(actionDict) {
                        items.insert(item, at: 0)
                    }
                }
            }
            self.presentCodeActionsMenu(items, in: textView, at: target.anchor)
        }
    }

    private func presentCodeActionsMenu(_ items: [LSPCodeActionItem], in textView: GoLensTextView, at location: Int) {
        let menu = NSMenu(title: "Code Actions")
        menu.autoenablesItems = false
        if items.isEmpty {
            let none = NSMenuItem(title: "No Code Actions Available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        CodeActionMenuTarget.shared.actions = items
        CodeActionMenuTarget.shared.chosen = nil
        var lastSection = ""
        for (i, item) in items.enumerated() {
            if item.section != lastSection {
                if !lastSection.isEmpty { menu.addItem(.separator()) }
                menu.addItem(NSMenuItem.sectionHeader(title: item.section))
                lastSection = item.section
            }
            let mi = NSMenuItem(title: item.title, action: #selector(CodeActionMenuTarget.perform(_:)), keyEquivalent: "")
            let symbolName: String = {
                if item.kind.hasPrefix("refactor") { return "slider.horizontal.3" }
                if item.kind.hasPrefix("source.organizeImports") { return "arrow.up.arrow.down" }
                if item.kind.hasPrefix("source") { return "gearshape" }
                return "wand.and.stars"
            }()
            mi.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            mi.target = CodeActionMenuTarget.shared
            mi.tag = i
            mi.isEnabled = item.disabledReason == nil
            mi.toolTip = item.disabledReason
            menu.addItem(mi)
        }
        let caret = NSRange(location: location, length: 0)
        var rect = textView.firstRect(forCharacterRange: caret, actualRange: nil)
        if let window = textView.window {
            rect = textView.convert(window.convertFromScreen(rect), from: nil)
        }
        let picked = menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: textView)
        if picked, let tag = CodeActionMenuTarget.shared.chosen ?? menu.highlightedItem?.tag, items.indices.contains(tag) {
            self.performCodeAction(items[tag])
        }
    }

    func generateTestForSelection() {
        presentGenerateTableDrivenTestSheet()
    }

    func fetchASTQuickFixes(filePath: String, content: String, line: Int) -> [[String: Any]] {
        Self.computeASTQuickFixes(filePath: filePath, content: content, line: line)
    }

    static func computeASTQuickFixes(filePath: String, content: String, line: Int) -> [[String: Any]] {
        guard let cPath = filePath.cString(using: .utf8),
              let cContent = content.cString(using: .utf8) else { return [] }
        guard let ptr = ContextualASTQuickFixes(cPath, cContent, Int32(line)) else { return [] }
        defer { FreeGoCString(ptr) }
        let jsonStr = String(cString: ptr)
        let data = Data(jsonStr.utf8)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    func performCodeAction(_ item: LSPCodeActionItem) {
        measureLog("code action \(item.title) kind=\(item.kind)")
        if item.raw["golens"] as? String == "astQuickFix",
           let updatedSource = item.raw["updatedSource"] as? String {
            let targetPath = (item.raw["filePath"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? activeFilePath
            applyInPlaceEdit(newText: updatedSource, actionName: item.title, targetPath: targetPath)
            if !targetPath.isEmpty {
                scheduleSafetyAnalysis(for: targetPath, debounce: 0.1)
            }
            return
        }
        if item.raw["golens"] as? String == "dockerfileFix" {
            applyDockerfileFix(item)
            return
        }
        if item.raw["golens"] as? String == "renameUsages" {
            (activeTextView as? GoLensTextView)?.acceptRenameSuggestion()
            return
        }
        if let golens = item.raw["golens"] as? String, let line = item.raw["line"] as? Int {
            fixDroppedError(line: line, handle: golens == "handleError")
            return
        }
        if item.raw["edit"] != nil || item.raw["command"] != nil {
            finishCodeAction(item.raw)
            return
        }
        let raw = jsonText(item.raw)
        lspRequestQueue.async {
            let reply = raw.withCString { CoreReply(ResolveCodeAction($0)) }
            DispatchQueue.main.async {
                guard let resolved = reply.result as? [String: Any] else {
                    let detail = reply.error ?? "no edit returned"
                    self.appendLog("Code action failed: \(detail)")
                    self.presentCommandFeedback(Self.formatCommandReason(reply.error, fallback: "The language server did not return an edit for this code action."), title: "Code Action Failed", tone: .failure)
                    return
                }
                self.finishCodeAction(resolved)
            }
        }
    }

    private func finishCodeAction(_ action: [String: Any]) {
        if let edit = action["edit"] as? [String: Any] {
            _ = applyLSPWorkspaceEdit(edit, revealCreated: true)
        }
        if let command = action["command"] as? [String: Any] {
            runLSPCommand(command)
        }
    }

    static func resultsPart(ofSignature sig: String) -> String? {
        let chars = Array(sig)
        func skipGroup(_ i: inout Int) {
            var depth = 0
            while i < chars.count {
                if chars[i] == "(" || chars[i] == "[" { depth += 1 }
                if chars[i] == ")" || chars[i] == "]" { depth -= 1; if depth == 0 { i += 1; return } }
                i += 1
            }
        }
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        if i < chars.count, chars[i] == "(" { skipGroup(&i) }
        while i < chars.count, chars[i] != "(" && chars[i] != "[" { i += 1 }
        if i < chars.count, chars[i] == "[" { skipGroup(&i) }
        guard i < chars.count, chars[i] == "(" else { return nil }
        skipGroup(&i)
        var rest = String(chars[min(i, chars.count)...]).trimmingCharacters(in: .whitespaces)
        if let brace = rest.firstIndex(of: "{"), !rest.hasPrefix("interface"), !rest.hasPrefix("struct") { rest = String(rest[..<brace]).trimmingCharacters(in: .whitespaces) }
        return rest
    }

    static func resultCount(fromHover markdown: String) -> Int? {
        guard let start = markdown.range(of: "func ") else { return nil }
        var sig = String(markdown[start.upperBound...])
        if let nl = sig.firstIndex(of: "\n") { sig = String(sig[..<nl]) }
        guard let results = resultsPart(ofSignature: sig) else { return nil }
        if results.isEmpty { return 0 }
        guard results.first == "(" else { return 1 }
        var depth = 0, commas = 0
        for c in results {
            if c == "(" || c == "[" || c == "{" { depth += 1 } else if c == ")" || c == "]" || c == "}" { depth -= 1 } else if c == ",", depth == 1 { commas += 1 }
        }
        return commas + 1
    }

    static func callNameColumn(in stmt: String) -> Int? {
        let chars = Array(stmt)
        guard chars.last == ")" else { return nil }
        var depth = 0
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] == ")" { depth += 1 } else if chars[i] == "(" { depth -= 1; if depth == 0 { break } }
            i -= 1
        }
        var j = i - 1
        while j >= 0, chars[j] == "_" || chars[j].isLetter || chars[j].isNumber { j -= 1 }
        return j + 1 < i ? j + 1 : nil
    }

    static func enclosingFuncReturnsError(_ lines: [String], from line: Int) -> Bool {
        var i = line
        while i >= 0 {
            let l = lines[i]
            if l.hasPrefix("func ") {
                return resultsPart(ofSignature: String(l.dropFirst(5)))?.contains("error") ?? false
            }
            i -= 1
        }
        return false
    }

    func fixDroppedError(line: Int, handle: Bool) {
        guard let tv = activeTextView as? GoLensTextView, let session = tv.document, let lineRange = session.lineRange(line) else { return }
        let ns = session.storage.string as NSString
        var lineText = ns.substring(with: lineRange)
        if lineText.hasSuffix("\n") { lineText.removeLast() }
        let text = lineText
        let indent = String(text.prefix { $0 == "\t" || $0 == " " })
        let stmt = text.trimmingCharacters(in: .whitespaces)
        guard let nameCol = Self.callNameColumn(in: stmt) else {
            presentCommandFeedback("Place the cursor on a function call statement to handle its returned error.", title: "Handle Error")
            return
        }
        let path = session.path
        let replaceRange = NSRange(location: lineRange.location, length: (text as NSString).length)
        let allLines = handle ? ns.substring(to: lineRange.location).components(separatedBy: "\n") : []
        Task {
            let hover = await LSPClient.shared.requestHover(atLine: line + 1, col: indent.count + nameCol + 1, inPath: path) ?? ""
            let count = max(1, Self.resultCount(fromHover: hover) ?? 1)
            await MainActor.run {
                guard session.storage.length >= NSMaxRange(replaceRange), (session.storage.string as NSString).substring(with: replaceRange) == text else { return }
                let replacement: String
                if handle {
                    let names = (Array(repeating: "_", count: count - 1) + ["err"]).joined(separator: ", ")
                    let body = Self.enclosingFuncReturnsError(allLines, from: allLines.count - 1) ? "return err" : "panic(err)"
                    replacement = "\(indent)if \(names) := \(stmt); err != nil {\n\(indent)\t\(body)\n\(indent)}"
                } else {
                    replacement = "\(indent)\(Array(repeating: "_", count: count).joined(separator: ", ")) = \(stmt)"
                }
                self.applyRanges([(replaceRange, replacement)], in: session)
                if handle { self.fillReturnValues(in: session, line: line + 1) }
            }
        }
    }

    private func fillReturnValues(in session: DocumentSession, line: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let range = session.lineRange(line) else { return }
            self.requestCodeActions(in: session, range: range, only: ["quickfix"]) { items in
                if let fill = items.first(where: { $0.title.localizedCaseInsensitiveContains("fill in return values") }) {
                    self.performCodeAction(fill)
                }
            }
        }
    }

    @discardableResult
    func applyLSPWorkspaceEdit(_ edit: [String: Any], revealCreated: Bool) -> Bool {
        var perPath: [(String, [LSPTextEdit])] = []
        var pendingCreates: [(path: String, overwrite: Bool)] = []
        var created: [String] = []
        func decodeEdits(_ any: Any?) -> [LSPTextEdit]? {
            guard let any else { return [] }
            guard let data = try? JSONSerialization.data(withJSONObject: any),
                  let decoded = try? JSONDecoder().decode([LSPTextEdit].self, from: data) else {
                return nil
            }
            return decoded
        }
        for (uri, rawEdits) in edit["changes"] as? [String: Any] ?? [:] {
            guard let decoded = decodeEdits(rawEdits) else {
                appendLog("Failed to decode workspace edits for \(uri)")
                return false
            }
            perPath.append((lspPath(fromURI: uri), decoded))
        }
        for change in edit["documentChanges"] as? [[String: Any]] ?? [] {
            if let kind = change["kind"] as? String {
                guard kind == "create", let uri = change["uri"] as? String else { return false }
                let path = lspPath(fromURI: uri)
                guard !path.isEmpty else { return false }
                let parentDir = (path as NSString).deletingLastPathComponent
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else {
                    appendLog("Failed to create \((path as NSString).lastPathComponent): parent directory does not exist")
                    presentFailure(
                        "Couldn’t Create “\((path as NSString).lastPathComponent)”",
                        "The folder “\((parentDir as NSString).lastPathComponent)” doesn’t exist, so no files were changed."
                    )
                    return false
                }
                let overwrite = (change["options"] as? [String: Any])?["overwrite"] as? Bool ?? false
                pendingCreates.append((path: path, overwrite: overwrite))
            } else if let doc = change["textDocument"] as? [String: Any], let uri = doc["uri"] as? String {
                guard let decoded = decodeEdits(change["edits"]) else {
                    appendLog("Failed to decode documentChanges edits for \(uri)")
                    return false
                }
                perPath.append((lspPath(fromURI: uri), decoded))
            } else {
                return false
            }
        }

        let willCreateOrOverwrite = Set(
            pendingCreates
                .filter { !FileManager.default.fileExists(atPath: $0.path) || $0.overwrite }
                .map(\.path)
        )
        var preflightDiskContents: [String: String] = [:]
        for (path, edits) in perPath where !edits.isEmpty {
            guard !path.isEmpty else { return false }
            if documents[path] != nil {
                if fileEditorModes[path] == .readOnly || diskConflicts.contains(path) {
                    appendLog("Cannot apply edit to \((path as NSString).lastPathComponent): document is read-only or has an unresolved disk conflict")
                    presentFailure(
                        "Couldn’t Edit “\((path as NSString).lastPathComponent)”",
                        diskConflicts.contains(path)
                            ? "Another app changed this file. Choose which version to keep, then try again. No files were changed."
                            : "This file is open as read-only, so no files were changed."
                    )
                    return false
                }
            } else if willCreateOrOverwrite.contains(path) {
                preflightDiskContents[path] = ""
            } else if preflightDiskContents[path] == nil {
                do {
                    preflightDiskContents[path] = try String(contentsOfFile: path, encoding: .utf8)
                } catch {
                    appendLog("Failed to read \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                    presentFailure(
                        "Couldn’t Edit “\((path as NSString).lastPathComponent)”",
                        "\(Self.failureReason(error)) No files were changed.",
                        revealing: path
                    )
                    return false
                }
            }
        }

        for item in pendingCreates {
            if !FileManager.default.fileExists(atPath: item.path) || item.overwrite {
                do {
                    try "".write(toFile: item.path, atomically: true, encoding: .utf8)
                    created.append(item.path)
                    LSPClient.notifyWatchedFilesChanged([item.path], changeType: 1)
                } catch {
                    appendLog("Failed to create \((item.path as NSString).lastPathComponent): \(error.localizedDescription)")
                    presentFailure(
                        "Couldn’t Create “\((item.path as NSString).lastPathComponent)”",
                        "\(Self.failureReason(error)) Check that you can write to the folder, then try again.",
                        revealing: item.path
                    )
                    return false
                }
            }
        }

        var firstTouched: (String, Int)?
        for (path, edits) in perPath where !edits.isEmpty {
            if firstTouched == nil || created.contains(path) {
                let line = edits.map { $0.range.start.line }.min() ?? 0
                if firstTouched == nil || created.contains(path) && firstTouched?.0 != path { firstTouched = (path, line) }
            }
            if let session = documents[path] {
                applyTextEdits(edits, in: session)
            } else if let content = preflightDiskContents[path] {
                let scratch = DocumentSession(path: path, text: content, syncsToCore: false)
                scratch.workspace = self
                applyTextEdits(edits, in: scratch)
                do {
                    try scratch.storage.string.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
                    preflightDiskContents[path] = scratch.storage.string
                    LSPClient.notifyWatchedFilesChanged([path])
                } catch {
                    appendLog("Failed to apply edit to \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                    presentFailure(
                        "Couldn’t Edit “\((path as NSString).lastPathComponent)”",
                        "\(Self.failureReason(error)) Files edited before this one keep their changes. Check that you can write to this file, then try again.",
                        revealing: path
                    )
                    return false
                }
            } else {
                return false
            }
        }
        if revealCreated, let (path, line) = firstTouched, path != activeFilePath {
            pendingJumpToLine = line + 1
            pendingJumpToCol = 1
            openFile(path)
        }
        return true
    }

    func handleServerApplyEdit(token: Int64, payload: String) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        guard let edit = obj?["edit"] as? [String: Any] else {
            ApplyEditResult(token, 0, "malformed edit")
            return
        }
        let applied = applyLSPWorkspaceEdit(edit, revealCreated: true)
        ApplyEditResult(token, applied ? 1 : 0, applied ? nil : "the edit could not be applied")
    }

    func goToDefinitionAtCaret() {
        if let tv = activeTextView as? GoLensTextView {
            tv.goToDefinition(at: tv.selectedRange().location)
        } else {
            presentCommandFeedback("Open a Go file in the editor and place the cursor on a symbol.", title: "Go to Definition")
        }
    }

    func goToImplementationAtCaret() {
        if let tv = activeTextView as? GoLensTextView {
            tv.goToImplementation(at: tv.selectedRange().location)
        } else {
            presentCommandFeedback("Open a Go file in the editor and place the cursor on an interface or method.", title: "Go to Implementation")
        }
    }

    func goToTypeDefinitionAtCaret() {
        if let tv = activeTextView as? GoLensTextView {
            tv.goToTypeDefinition(at: tv.selectedRange().location)
        } else {
            presentCommandFeedback("Open a Go file in the editor and place the cursor on a symbol.", title: "Go to Type Definition")
        }
    }

    func findReferencesAtCaret() {
        if let tv = activeTextView as? GoLensTextView {
            tv.findReferences(at: tv.selectedRange().location)
        } else {
            presentCommandFeedback("Open a Go file in the editor and place the cursor on a symbol.", title: "Find Usages")
        }
    }

    func jumpBetweenCodeAndTest() {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go source or test file to jump between implementation and tests.", title: "Jump to Test")
            return
        }
        let currentText = documents[activeFilePath]?.storage.string ?? (try? String(contentsOfFile: activeFilePath, encoding: .utf8)) ?? ""
        let decls = activeGoDeclarations.isEmpty ? findGoDeclarations(in: currentText) : activeGoDeclarations
        let decl = decls.last(where: { $0.line <= cursorLine }) ?? decls.first
        let dir = (activeFilePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let dirEntries = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()

        func fileText(_ path: String) -> String? {
            if let doc = documents[path] {
                return doc.storage.string
            }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }

        if activeFilePath.hasSuffix("_test.go") {
            let stem = String(activeFilePath.dropLast("_test.go".count)) + ".go"
            var candidates: [String] = []
            if fm.fileExists(atPath: stem) {
                candidates.append(stem)
            }
            for entry in dirEntries where entry.hasSuffix(".go") && !entry.hasSuffix("_test.go") {
                let full = (dir as NSString).appendingPathComponent(entry)
                if full != stem {
                    candidates.append(full)
                }
            }

            var targetNames: [String] = []
            if let sym = decl?.symbolName {
                for prefix in ["Test", "Benchmark", "Example", "Fuzz"] where sym.hasPrefix(prefix) && sym.count > prefix.count {
                    var rest = String(sym.dropFirst(prefix.count))
                    if rest.hasPrefix("_") { rest = String(rest.dropFirst()) }
                    if !rest.isEmpty {
                        targetNames.append(rest)
                        let parts = rest.split(separator: "_").map(String.init).filter { !$0.isEmpty }
                        if parts.count >= 2 {
                            if let last = parts.last { targetNames.append(last) }
                            if let first = parts.first { targetNames.append(first) }
                        }
                    }
                }
            }

            if !targetNames.isEmpty {
                for file in candidates {
                    guard let text = fileText(file) else { continue }
                    let fileDecls = findGoDeclarations(in: text)
                    for name in targetNames {
                        if let match = fileDecls.first(where: { $0.symbolName == name }) {
                            jumpTo(filePath: file, line: match.line, column: match.col)
                            return
                        }
                    }
                }
                for file in candidates {
                    guard let text = fileText(file) else { continue }
                    let fileDecls = findGoDeclarations(in: text)
                    for name in targetNames {
                        if let match = fileDecls.first(where: { $0.symbolName.caseInsensitiveCompare(name) == .orderedSame }) {
                            jumpTo(filePath: file, line: match.line, column: match.col)
                            return
                        }
                    }
                }
            }

            if fm.fileExists(atPath: stem) {
                openFile(stem)
            } else if let firstFile = candidates.first {
                openFile(firstFile)
            } else {
                presentCommandFeedback("No non-test Go source file was found in this package directory.", title: "Jump to Implementation")
            }
        } else {
            let testPath = String(activeFilePath.dropLast(".go".count)) + "_test.go"
            var testCandidates: [String] = []
            if fm.fileExists(atPath: testPath) {
                testCandidates.append(testPath)
            }
            for entry in dirEntries where entry.hasSuffix("_test.go") {
                let full = (dir as NSString).appendingPathComponent(entry)
                if full != testPath {
                    testCandidates.append(full)
                }
            }

            if let sym = decl?.symbolName, !sym.isEmpty {
                let exactNames: Set<String> = ["Test" + sym, "Test_" + sym]
                let suffix = "_" + sym
                for file in testCandidates {
                    guard let text = fileText(file) else { continue }
                    let fileDecls = findGoDeclarations(in: text)
                    if let match = fileDecls.first(where: {
                        exactNames.contains($0.symbolName) ||
                        ($0.symbolName.hasPrefix("Test") && $0.symbolName.hasSuffix(suffix))
                    }) {
                        jumpTo(filePath: file, line: match.line, column: match.col)
                        return
                    }
                }
                for file in testCandidates {
                    guard let text = fileText(file) else { continue }
                    let fileDecls = findGoDeclarations(in: text)
                    if let match = fileDecls.first(where: {
                        $0.symbolName.hasPrefix("Test") && $0.symbolName.localizedCaseInsensitiveContains(sym)
                    }) {
                        jumpTo(filePath: file, line: match.line, column: match.col)
                        return
                    }
                }
            }

            if fm.fileExists(atPath: testPath) {
                openFile(testPath)
            } else if let decl, (decl.kind == "func" || decl.kind == "method") {
                generateTestForSelection()
            } else {
                var pkgName = "main"
                for line in currentText.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("package ") || trimmed.hasPrefix("package\t") {
                        let rest = trimmed.dropFirst("package".count).trimmingCharacters(in: .whitespaces)
                        let token = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if !token.isEmpty { pkgName = String(token) }
                        break
                    }
                }
                let initialContent = "package \(pkgName)\n\nimport \"testing\"\n"
                do {
                    try initialContent.write(toFile: testPath, atomically: true, encoding: .utf8)
                    openFile(testPath)
                } catch {
                    presentCommandFeedback("Could not create \((testPath as NSString).lastPathComponent): \(error.localizedDescription)", title: "Jump to Test", tone: .failure)
                }
            }
        }
    }

    func triggerChangeSignature() {
        guard !activeFilePath.isEmpty, let textView = activeTextView else {
            presentCommandFeedback("Open a Go file and place the cursor on a function or method declaration.", title: "Change Signature")
            return
        }
        let path: String
        if let vtv = textView as? GoLensTextView, !vtv.filePath.isEmpty {
            path = vtv.filePath
        } else {
            path = activeFilePath
        }
        guard path.hasSuffix(".go") else {
            presentCommandFeedback("Change Signature is only available inside Go source files.", title: "Change Signature")
            return
        }
        let source = textView.string
        let byteOffset: Int
        if let session = (textView as? GoLensTextView)?.document {
            byteOffset = session.utf8.byteOffset(textView.selectedRange().location)
        } else {
            let ns = source as NSString
            let clamped = max(0, min(textView.selectedRange().location, ns.length))
            byteOffset = ns.substring(to: clamped).utf8.count
        }
        let jsonStr: String? = path.withCString { cPath in
            source.withCString { cSrc in
                guard let c = InspectGoFuncSignature(cPath, cSrc, Int32(byteOffset)) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
        }
        guard let jsonStr, !jsonStr.isEmpty,
              var spec = try? JSONDecoder().decode(FuncSignatureSpec.self, from: Data(jsonStr.utf8)) else {
            presentCommandFeedback("Place the cursor on a Go function or method declaration to change its signature.", title: "Change Signature")
            return
        }
        if spec.path != path, let targetSession = documents[spec.path] {
            let targetSource = targetSession.storage.string
            let targetByteOffset = targetSession.offset(line: max(0, spec.nameLine - 1), utf16Column: max(0, spec.nameCol - 1))
                .map { targetSession.utf8.byteOffset($0) } ?? 0
            if let liveJSON: String = spec.path.withCString({ cPath in
                targetSource.withCString { cSrc in
                    guard let c = InspectGoFuncSignature(cPath, cSrc, Int32(targetByteOffset)) else { return nil }
                    defer { FreeGoCString(c) }
                    return String(cString: c)
                }
            }), !liveJSON.isEmpty,
               let liveSpec = try? JSONDecoder().decode(FuncSignatureSpec.self, from: Data(liveJSON.utf8)) {
                spec = liveSpec
            }
        }
        pendingChangeSignature = spec
    }

    func performChangeSignature(_ spec: FuncSignatureSpec) {
        struct SigRefPayload: Encodable {
            let path: String
            let line: Int
            let col: Int
        }
        struct ChangeSigPayload: Encodable {
            let spec: FuncSignatureSpec
            let references: [SigRefPayload]
            let buffers: [String: String]
        }
        struct ChangeSigReply: Decodable {
            let editsByPath: [String: [LSPTextEdit]]?
            let error: String?
        }

        var openBuffers: [String: String] = [:]
        for (path, session) in documents {
            openBuffers[path] = session.storage.string
        }

        Task {
            let refs: [LSPLocation]
            switch await LSPClient.shared.referencesResult(atLine: spec.nameLine, col: max(1, spec.nameCol), inPath: spec.path) {
            case .success(let found):
                refs = found
            case .failure(let failure):
                await MainActor.run {
                    let message = "Couldn’t find callers for this function. \(failure.explanation)"
                    if !failure.isSilent {
                        self.appendLog("Change Signature didn’t change anything because GoLens couldn’t find the callers. \(failure.explanation)")
                    }
                    self.presentCommandFeedback(message, title: "Change Signature Failed", tone: .failure)
                }
                return
            }
            let refPayloads = refs.map { loc in
                SigRefPayload(
                    path: loc.path,
                    line: loc.range.start.line,
                    col: loc.range.start.character
                )
            }
            let payload = ChangeSigPayload(spec: spec, references: refPayloads, buffers: openBuffers)
            guard let reqData = try? JSONEncoder().encode(payload),
                  let reqJSON = String(data: reqData, encoding: .utf8) else {
                await MainActor.run {
                    self.presentCommandFeedback("Could not prepare the signature update request.", title: "Change Signature Failed", tone: .failure)
                }
                return
            }

            let replyJSON: String? = reqJSON.withCString { cReq in
                guard let c = ApplyGoChangeSignature(cReq) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }

            guard let replyJSON,
                  let reply = try? JSONDecoder().decode(ChangeSigReply.self, from: Data(replyJSON.utf8)) else {
                await MainActor.run {
                    self.presentCommandFeedback("Could not apply the signature update across callers.", title: "Change Signature Failed", tone: .failure)
                }
                return
            }

            await MainActor.run {
                if let err = reply.error, !err.isEmpty {
                    self.appendLog("Change Signature failed: \(err)")
                    self.presentCommandFeedback(Self.formatCommandReason(err, fallback: "Could not apply the signature update."), title: "Change Signature Failed", tone: .failure)
                    return
                }
                guard let editsByPath = reply.editsByPath, !editsByPath.isEmpty else { return }
                var changes: [String: [LSPTextEdit]] = [:]
                for (path, edits) in editsByPath where !edits.isEmpty {
                    changes[lspURI(forPath: path)] = edits
                }
                guard !changes.isEmpty else { return }
                let wsEdit = WorkspaceEdit(changes: changes)
                self.applyWorkspaceEdit(wsEdit, activeTextView: self.activeTextView)
                if let tv = self.activeTextView as? GoLensTextView {
                    (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
                    self.codeLensVersions.removeValue(forKey: tv.filePath)
                    self.reloadCodeLens(forPath: tv.filePath, textView: tv)
                    self.activeGoDeclarations = self.findGoDeclarations(in: tv.string)
                    tv.needsDisplay = true
                }
            }
        }
    }

    var hasProject: Bool {
        !activeWorkspacePath.isEmpty
    }

    func showCallHierarchyAtCaret() {
        startHierarchy(mode: .call)
    }

    func showTypeHierarchyAtCaret() {
        startHierarchy(mode: .type)
    }

    private func startHierarchy(mode: HierarchyMode) {
        let title = mode == .call ? "Call Hierarchy" : "Type Hierarchy"
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go"), let tv = activeTextView as? GoLensTextView else {
            let targetHint = mode == .call ? "a function or method" : "a type or interface"
            presentCommandFeedback("Open a Go file and place the cursor on \(targetHint).", title: title)
            return
        }
        let path = activeFilePath
        let charIdx = tv.selectedRange().location
        let (line, col) = tv.lineAndCol(forCharacterIndex: charIdx)
        let fallbackName = tv.getWord(at: charIdx) ?? ""
        loadHierarchy(mode: mode, path: path, line: line, col: col, fallbackName: fallbackName)
    }

    private func loadHierarchy(mode: HierarchyMode, path: String, line: Int, col: Int, fallbackName: String) {
        hierarchyMode = mode
        hierarchyDirection = .incoming
        hierarchyRoot = nil
        hierarchyItems = []
        hierarchyFailure = nil
        hierarchyRetry = { [weak self] in
            self?.loadHierarchy(mode: mode, path: path, line: line, col: col, fallbackName: fallbackName)
        }
        isHierarchyLoading = true
        showHierarchy = true

        Task {
            let prepared: Result<[HierarchyItem], LSPRequestFailure>
            switch mode {
            case .call:
                prepared = await LSPClient.shared.prepareCallHierarchy(atLine: line, col: col, inPath: path)
            case .type:
                prepared = await LSPClient.shared.prepareTypeHierarchy(atLine: line, col: col, inPath: path)
            }
            let roots: [HierarchyItem]
            switch prepared {
            case .success(let items):
                roots = items
            case .failure(let failure):
                await MainActor.run {
                    guard self.hierarchyMode == mode, self.hierarchyRoot == nil, self.isHierarchyLoading else { return }
                    self.hierarchyRoot = self.fallbackHierarchyRoot(name: fallbackName, mode: mode, path: path, line: line, col: col)
                    self.hierarchyItems = []
                    self.hierarchyFailure = failure.isSilent ? nil : failure
                    self.isHierarchyLoading = false
                }
                return
            }
            guard let root = roots.first else {
                await MainActor.run {
                    self.hierarchyRoot = self.fallbackHierarchyRoot(name: fallbackName, mode: mode, path: path, line: line, col: col)
                    self.hierarchyItems = []
                    self.isHierarchyLoading = false
                }
                return
            }
            let direction = await MainActor.run { () -> HierarchyDirection in
                self.hierarchyRoot = root
                return self.hierarchyDirection
            }
            await fetchHierarchyChildren(for: root, mode: mode, direction: direction)
        }
    }

    private func fallbackHierarchyRoot(name: String, mode: HierarchyMode, path: String, line: Int, col: Int) -> HierarchyItem? {
        guard !name.isEmpty else { return nil }
        let pos = LSPPosition(line: max(0, line - 1), character: max(0, col - 1))
        let rng = LSPRange(start: pos, end: pos)
        return HierarchyItem(
            name: name,
            detail: (path as NSString).lastPathComponent,
            kind: mode == .call ? 12 : 5,
            uri: lspURI(forPath: path),
            range: rng,
            selectionRange: rng,
            rawJSON: "{}"
        )
    }

    func retryHierarchy() {
        hierarchyRetry?()
    }

    func setHierarchyDirection(_ direction: HierarchyDirection) {
        guard hierarchyDirection != direction else { return }
        hierarchyDirection = direction
        guard let root = hierarchyRoot else { return }
        reloadHierarchyChildren(of: root)
    }

    func drillIntoHierarchyItem(_ item: HierarchyItem) {
        hierarchyRoot = item
        reloadHierarchyChildren(of: item)
    }

    private func reloadHierarchyChildren(of root: HierarchyItem) {
        let mode = hierarchyMode
        let direction = hierarchyDirection
        hierarchyItems = []
        hierarchyFailure = nil
        hierarchyRetry = { [weak self] in
            guard let self, self.hierarchyRoot?.id == root.id else { return }
            self.reloadHierarchyChildren(of: root)
        }
        isHierarchyLoading = true
        Task {
            await fetchHierarchyChildren(for: root, mode: mode, direction: direction)
        }
    }

    private func fetchHierarchyChildren(for root: HierarchyItem, mode: HierarchyMode, direction: HierarchyDirection) async {
        let result: Result<[HierarchyItem], LSPRequestFailure>
        switch (mode, direction) {
        case (.call, .incoming):
            result = await LSPClient.shared.incomingCalls(for: root)
        case (.call, .outgoing):
            result = await LSPClient.shared.outgoingCalls(for: root)
        case (.type, .incoming):
            result = await LSPClient.shared.supertypes(for: root)
        case (.type, .outgoing):
            result = await LSPClient.shared.subtypes(for: root)
        }
        await MainActor.run {
            guard self.hierarchyRoot?.id == root.id,
                  self.hierarchyMode == mode,
                  self.hierarchyDirection == direction else { return }
            switch result {
            case .success(let items):
                self.hierarchyItems = Array(items.prefix(Self.maxHierarchyItems))
                self.hierarchyFailure = nil
            case .failure(let failure):
                self.hierarchyItems = []
                self.hierarchyFailure = failure.isSilent ? nil : failure
            }
            self.isHierarchyLoading = false
        }
    }

    func generateConstructorAtCaret() {
        performGoCodeGeneration(kind: "constructor", title: "Generate Constructor")
    }

    func extractInterfaceAtCaret() {
        performGoCodeGeneration(kind: "extract_interface", title: "Extract Interface")
    }

    func performGoCodeGeneration(kind: String, targetName: String = "", title: String) {
        guard !activeFilePath.isEmpty, activeFilePath.hasSuffix(".go"), let textView = activeTextView else {
            presentCommandFeedback("Open a Go file and place the cursor on a declaration to run \(title).", title: title)
            return
        }
        let path = activeFilePath
        let wsDir = activeWorkspacePath
        let source = textView.string
        let byteOffset: Int
        if let session = (textView as? GoLensTextView)?.document {
            byteOffset = session.utf8.byteOffset(textView.selectedRange().location)
        } else {
            let ns = source as NSString
            let clamped = max(0, min(textView.selectedRange().location, ns.length))
            byteOffset = ns.substring(to: clamped).utf8.count
        }

        struct GeneratePayload: Encodable {
            let kind: String
            let path: String
            let offset: Int
            let targetName: String
            let workspaceDir: String
            let buffers: [String: String]
        }
        struct GenerateReply: Decodable {
            let editsByPath: [String: [LSPTextEdit]]?
            let targetPath: String?
            let error: String?
        }

        var openBuffers: [String: String] = [:]
        for (docPath, session) in documents {
            openBuffers[docPath] = session.storage.string
        }
        openBuffers[path] = source

        let payload = GeneratePayload(
            kind: kind,
            path: path,
            offset: byteOffset,
            targetName: targetName,
            workspaceDir: wsDir,
            buffers: openBuffers
        )
        guard let reqData = try? JSONEncoder().encode(payload),
              let reqJSON = String(data: reqData, encoding: .utf8) else {
            presentCommandFeedback("Could not prepare the \(title) request.", title: title, tone: .failure)
            return
        }

        lspQueue.async {
            let replyJSON: String? = reqJSON.withCString { cReq in
                guard let resPtr = GenerateGoCode(UnsafeMutablePointer(mutating: cReq)) else { return nil }
                defer { FreeGoCString(resPtr) }
                return String(cString: resPtr)
            }

            guard let replyJSON,
                  let reply = try? JSONDecoder().decode(GenerateReply.self, from: Data(replyJSON.utf8)) else {
                DispatchQueue.main.async {
                    self.presentCommandFeedback("Place the cursor on a matching Go declaration to run \(title).", title: title)
                }
                return
            }

            DispatchQueue.main.async {
                if let err = reply.error, !err.isEmpty {
                    self.appendLog("\(title) failed: \(err)")
                    self.presentCommandFeedback(Self.formatCommandReason(err, fallback: "Place the cursor on a matching Go declaration to run \(title)."), title: title, tone: .warning)
                    return
                }
                guard let editsByPath = reply.editsByPath, !editsByPath.isEmpty else {
                    self.presentCommandFeedback("No new code needed to be generated for the current declaration.", title: title)
                    return
                }
                var changes: [String: [LSPTextEdit]] = [:]
                var newlyCreatedPaths = reply.targetPath.flatMap { editsByPath[$0] == nil ? [$0] : nil } ?? []
                for (editPath, edits) in editsByPath where !edits.isEmpty {
                    if self.documents[editPath] == nil,
                       edits.count == 1,
                       let first = edits.first,
                       first.range.start.line == 0,
                       first.range.start.character == 0,
                       first.range.end.line == 0,
                       first.range.end.character == 0,
                       (try? String(contentsOfFile: editPath, encoding: .utf8)) == first.newText {
                        newlyCreatedPaths.append(editPath)
                    } else {
                        changes[lspURI(forPath: editPath)] = edits
                    }
                }
                if !newlyCreatedPaths.isEmpty {
                    LSPClient.notifyWatchedFilesChanged(newlyCreatedPaths, changeType: 1)
                    if !self.activeWorkspacePath.isEmpty {
                        self.loadFiles(from: self.activeWorkspacePath)
                    }
                }
                guard !changes.isEmpty || !newlyCreatedPaths.isEmpty else {
                    self.presentCommandFeedback("No new code needed to be generated for the current declaration.", title: title)
                    return
                }
                if !changes.isEmpty {
                    let wsEdit = WorkspaceEdit(changes: changes)
                    self.applyWorkspaceEdit(wsEdit, activeTextView: self.activeTextView)
                }
                if let tv = self.activeTextView as? GoLensTextView {
                    (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
                    self.codeLensVersions.removeValue(forKey: tv.filePath)
                    self.reloadCodeLens(forPath: tv.filePath, textView: tv)
                    self.activeGoDeclarations = self.findGoDeclarations(in: tv.string)
                    tv.needsDisplay = true
                }
            }
        }
    }

    func syncBuildTargetWithCore() {
        let defaults = UserDefaults.standard
        let goos = defaults.string(forKey: "GoLensBuildGOOS") ?? ""
        let goarch = defaults.string(forKey: "GoLensBuildGOARCH") ?? ""
        let tags = defaults.string(forKey: "GoLensBuildTags") ?? ""
        lspQueue.async {
            goos.withCString { cGoos in
                goarch.withCString { cGoarch in
                    tags.withCString { cTags in
                        SetGoplsBuildTarget(cGoos, cGoarch, cTags)
                    }
                }
            }
        }
        refreshActiveFileBuildTarget()
        let wsRoot = activeWorkspacePath
        if !wsRoot.isEmpty {
            Task { @MainActor in
                DocumentationService.shared.notifyBuildTargetChanged(root: wsRoot)
            }
        }
    }

    func refreshActiveFileBuildTarget() {
        let path = activeFilePath
        guard !path.isEmpty, path.hasSuffix(".go") else {
            if activeFileExcludedReason != nil {
                activeFileExcludedReason = nil
            }
            return
        }
        let defaults = UserDefaults.standard
        let goos = defaults.string(forKey: "GoLensBuildGOOS") ?? ""
        let goarch = defaults.string(forKey: "GoLensBuildGOARCH") ?? ""
        let tags = defaults.string(forKey: "GoLensBuildTags") ?? ""
        let isCustom = !goos.isEmpty || !goarch.isEmpty || !tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if activeBuildTargetIsCustom != isCustom {
            activeBuildTargetIsCustom = isCustom
        }
        let content: String
        if let tv = activeTextView as? GoLensTextView, tv.filePath == path {
            content = tv.string
        } else {
            content = documents[path]?.storage.string ?? ""
        }

        struct BuildTargetCheckReply: Decodable {
            let excluded: Bool
            let reason: String?
        }

        lspQueue.async { [weak self] in
            let jsonStr: String? = path.withCString { cPath in
                content.withCString { cContent in
                    goos.withCString { cGoos in
                        goarch.withCString { cGoarch in
                            tags.withCString { cTags in
                                guard let c = CheckGoBuildTarget(cPath, cContent, cGoos, cGoarch, cTags) else { return nil }
                                defer { FreeGoCString(c) }
                                return String(cString: c)
                            }
                        }
                    }
                }
            }
            let reply = jsonStr.flatMap { try? JSONDecoder().decode(BuildTargetCheckReply.self, from: Data($0.utf8)) }
            let reason = (reply?.excluded == true) ? (reply?.reason ?? "Excluded from active build target.") : nil
            DispatchQueue.main.async {
                guard let self, self.activeFilePath == path else { return }
                if self.activeFileExcludedReason != reason {
                    self.activeFileExcludedReason = reason
                }
            }
        }
    }

    func setBuildTarget(goos: String, goarch: String, tags: String) {
        let defaults = UserDefaults.standard
        defaults.set(goos, forKey: "GoLensBuildGOOS")
        defaults.set(goarch, forKey: "GoLensBuildGOARCH")
        defaults.set(tags, forKey: "GoLensBuildTags")
        NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
    }

    func resetBuildTarget() {
        setBuildTarget(goos: "", goarch: "", tags: "")
    }

    func runSafetyAudit() {
        guard !activeWorkspacePath.isEmpty, !isSafetyAuditRunning else { return }
        let root = activeWorkspacePath
        let consoleText = consoleOutput.map(\.text).joined(separator: "\n")
        isSafetyAuditRunning = true
        hasSafetyData = true
        showConsole = true
        selectedConsoleTab = Self.safetyTab

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let jsonStr: String? = root.withCString { cRoot in
                consoleText.withCString { cConsole in
                    guard let c = RunGoSafetyAudit(cRoot, cConsole) else { return nil }
                    defer { FreeGoCString(c) }
                    return String(cString: c)
                }
            }
            let report = jsonStr.flatMap { try? JSONDecoder().decode(SafetyAuditReport.self, from: Data($0.utf8)) }
            DispatchQueue.main.async {
                guard let self, self.activeWorkspacePath == root else { return }
                self.isSafetyAuditRunning = false
                if let report {
                    self.safetyFindings = Array(report.findings.prefix(SafetyView.maxSafetyFindings))
                    self.safetySummary = report.summary
                } else {
                    self.safetyFindings = []
                    self.safetySummary = "Safety audit completed with 0 findings."
                }
                self.hasSafetyData = true
                self.activeTextView?.needsDisplay = true
            }
        }
    }

    func clearSafetyFindings() {
        safetyFindings = []
        safetySummary = ""
        hasSafetyData = false
        if selectedConsoleTab == Self.safetyTab {
            selectedConsoleTab = Self.consoleTab
        }
        activeTextView?.needsDisplay = true
    }
}

func goApplyEditCallback(token: Int64, payload: UnsafePointer<CChar>?) {
    guard let payload else { ApplyEditResult(token, 0, "empty edit"); return }
    let text = String(cString: payload)
    DispatchQueue.main.async {
        WorkspaceState.workspaceForEdit(text).handleServerApplyEdit(token: token, payload: text)
    }
}

struct InteractiveFormSheet: View {
    @Environment(\.windowWorkspace) private var workspace
    let form: InteractiveForm
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var lazyEntries: [String: [(value: String, description: String)]] = [:]

    private func fieldType(_ field: [String: Any]) -> [String: Any] { field["type"] as? [String: Any] ?? [:] }
    private func kind(_ field: [String: Any]) -> String { fieldType(field)["kind"] as? String ?? "string" }
    private func fieldID(_ field: [String: Any]) -> String { field["id"] as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(form.heading)
                .font(.headline)
                .padding([.top, .horizontal], 20)
            Form {
                ForEach(Array(form.fields.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    workspace.lsp.pendingForm = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(form.actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding(Spacing.section)
        }
        .sheetFrame(.compact)
        .onAppear(perform: loadDefaults)
    }

    @ViewBuilder
    private func fieldView(_ field: [String: Any]) -> some View {
        let id = fieldID(field)
        let label = field["description"] as? String ?? id
        let error = field["error"] as? String
        Section {
            switch kind(field) {
            case "bool":
                Toggle(label, isOn: Binding(get: { bools[id] ?? false }, set: { bools[id] = $0 }))
            case "enum":
                let entries = (fieldType(field)["entries"] as? [[String: Any]] ?? []).compactMap { e -> (String, String)? in
                    guard let v = e["value"] as? String else { return nil }
                    return (v, e["description"] as? String ?? v)
                }
                Picker(label, selection: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })) {
                    ForEach(entries, id: \.0) { entry in Text(entry.1).tag(entry.0) }
                }
            case "lazyEnum":
                TextField(label, text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0; search(field, query: $0) }), prompt: Text("Search"))
                let entries = lazyEntries[id] ?? []
                if !entries.isEmpty {
                    List(entries.prefix(50), id: \.value, selection: Binding(get: { values[id] }, set: { values[id] = $0 ?? "" })) { entry in
                        Text(entry.description).tag(entry.value)
                    }
                    .frame(height: 160)
                }
            default:
                TextField(label, text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 }))
            }
        } footer: {
            if let error, !error.isEmpty {
                Text(error).foregroundStyle(StatusTone.failure.tint).font(.callout)
            }
        }
    }

    private var isComplete: Bool {
        form.fields.allSatisfy { field in
            guard field["required"] as? Bool == true, kind(field) != "bool" else { return true }
            return !(values[fieldID(field)] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func loadDefaults() {
        let previous = Dictionary((form.params["formAnswers"] as? [[String: Any]] ?? []).compactMap { a -> (String, Any)? in
            guard let id = a["id"] as? String, let v = a["value"] else { return nil }
            return (id, v)
        }, uniquingKeysWith: { a, _ in a })
        for field in form.fields {
            let id = fieldID(field)
            let value = previous[id] ?? field["default"]
            if kind(field) == "bool" {
                bools[id] = value as? Bool ?? false
            } else if let v = value {
                values[id] = "\(v)"
            }
            if kind(field) == "lazyEnum" { search(field, query: values[id] ?? "") }
        }
    }

    private func search(_ field: [String: Any], query: String) {
        let id = fieldID(field)
        let type = fieldType(field)
        let source = type["source"] as? String ?? ""
        let config = type["config"].map { jsonText($0) } ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = source.withCString { s in config.withCString { c in query.withCString { q in CoreReply(ListEnum(s, c, q)) } } }
            let entries = (reply.result as? [[String: Any]] ?? []).compactMap { e -> (value: String, description: String)? in
                guard let v = e["value"] as? String else { return nil }
                return (v, e["description"] as? String ?? v)
            }
            DispatchQueue.main.async { lazyEntries[id] = entries }
        }
    }

    private func submit() {
        var answers: [[String: Any]] = []
        for field in form.fields {
            let id = fieldID(field)
            switch kind(field) {
            case "bool":
                answers.append(["id": id, "value": bools[id] ?? false])
            case "number":
                if let n = Double(values[id] ?? "") { answers.append(["id": id, "value": n]) }
            default:
                if let v = values[id], !v.isEmpty { answers.append(["id": id, "value": v]) }
            }
        }
        workspace.submitInteractiveForm(form, answers: answers)
        dismiss()
    }
}

extension WorkspaceState {
    func applyEnvFileToActiveRunConfig(envPath: String) {
        let text = documents[envPath]?.storage.string ?? (try? String(contentsOfFile: envPath, encoding: .utf8)) ?? ""
        var parsed: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            var key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") {
                key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }
            var val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2) ||
               (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                val = String(val.dropFirst().dropLast())
            }
            parsed[key] = val
        }
        guard !parsed.isEmpty else {
            appendLog("No KEY=VALUE entries found in \((envPath as NSString).lastPathComponent).")
            return
        }
        if var config = activeRunConfiguration {
            for (k, v) in parsed {
                config.envVars[k] = v
            }
            updateRunConfiguration(config)
            appendLog("Loaded \(parsed.count) environment variable(s) from \((envPath as NSString).lastPathComponent) into Run Configuration “\(config.name)”.")
        } else {
            let newConfig = RunConfiguration(
                name: "Default (\((envPath as NSString).lastPathComponent))",
                envVars: parsed,
                buildFlags: "",
                args: "",
                workingDirectory: "."
            )
            updateRunConfiguration(newConfig)
            activeRunConfigId = newConfig.id
            appendLog("Created Run Configuration “\(newConfig.name)” with \(parsed.count) variable(s) from \((envPath as NSString).lastPathComponent).")
        }
        showConsole = true
        selectedConsoleTab = 0
    }

    var canFormatActiveEcosystemDocument: Bool {
        guard !activeFilePath.isEmpty else { return false }
        return activeFilePath.hasSuffix(".go") ||
            EcosystemDocumentTools.isJSONFile(activeFilePath) ||
            EcosystemDocumentTools.isYAMLFile(activeFilePath) ||
            EcosystemDocumentTools.isMakefile(activeFilePath) ||
            EcosystemDocumentTools.isEnvFile(activeFilePath)
    }

    func formatActiveDocument() {
        guard !activeFilePath.isEmpty else { return }
        if activeFilePath.hasSuffix(".go") {
            if let tv = activeTextView, tv.selectedRange().length > 0 {
                formatSelection(in: tv)
            } else {
                saveActiveFileAndFormat()
            }
            return
        }
        guard let session = documents[activeFilePath],
              let formatted = EcosystemDocumentTools.formatDocument(path: activeFilePath, text: session.storage.string),
              formatted != session.storage.string else {
            return
        }
        replaceActiveDocumentText(with: formatted, actionName: "Format Document")
    }

    private func replaceActiveDocumentText(with newText: String, actionName: String) {
        if let tv = activeTextView as? GoLensTextView, tv.filePath == activeFilePath {
            let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
            let savedSelection = tv.selectedRange()
            if tv.shouldChangeText(in: fullRange, replacementString: newText) {
                tv.textStorage?.replaceCharacters(in: fullRange, with: newText)
                tv.didChangeText()
                let clampedLoc = min(savedSelection.location, (newText as NSString).length)
                tv.setSelectedRange(NSRange(location: clampedLoc, length: 0))
                tv.undoManager?.setActionName(actionName)
            }
        } else if let session = documents[activeFilePath] {
            session.storage.replaceCharacters(in: NSRange(location: 0, length: session.storage.length), with: newText)
            documentDidEdit(session)
        }
    }
}
