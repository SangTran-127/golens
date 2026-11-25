import AppKit
import SwiftUI
import Observation
import os

struct CompletionRow: Decodable, Identifiable, Equatable {
    let i: Int
    let label: String
    let kind: String
    let params: String?
    let type: String?
    let pkg: String?
    let m: [Int]?
    let dep: Bool?
    var insert: String? = nil

    var id: Int { i }
    var detail: String? { type }
    var insertText: String { insert ?? label }
}

struct CompletionDocInfo: Decodable, Equatable {
    let signature: String
    let doc: String
}

private struct CompletionStartResult: Decodable {
    let ok: Bool
    let error: String?
    let stale: Bool?
    let session: Int64?
    let anchor: Int
    let incomplete: Bool?
}

private struct CompletionFilterResult: Decodable {
    let action: String
    let refresh: Bool?
    let total: Int
    let rows: [CompletionRow]
}

private struct TemplateExpansion: Decodable {
    let text: String
    let stops: [SnippetStop]
    let final: Int
}

private struct CompletionCommitResult: Decodable {
    let ok: Bool
    let start: Int
    let end: Int
    let text: String
    let stops: [SnippetStop]
    let final: Int
    let additional: [LSPTextEdit]
}

private func takeGoString(_ c: UnsafeMutablePointer<CChar>?) -> String? {
    guard let c else { return nil }
    defer { FreeGoCString(c) }
    return String(cString: c)
}

private func decodeGo<T: Decodable>(_ type: T.Type, _ c: UnsafeMutablePointer<CChar>?) -> T? {
    guard let json = takeGoString(c) else { return nil }
    return try? JSONDecoder().decode(type, from: Data(json.utf8))
}

@Observable
final class CompletionController {
    static let shared = CompletionController()
    static let maxVisibleRows = 10

    private(set) var rows: [CompletionRow] = []
    private(set) var selected = 0
    private(set) var doc: CompletionDocInfo?
    var query = ""

    @ObservationIgnored var session: Int64 = 0
    @ObservationIgnored var localSource: LocalSource = .env
    @ObservationIgnored var anchor = 0
    @ObservationIgnored var path = ""
    @ObservationIgnored var generation = 0 {
        didSet { liveGeneration.withLock { $0 = generation } }
    }
    @ObservationIgnored let liveGeneration = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var requestPending = false
    @ObservationIgnored private var requestStarted: CFAbsoluteTime = 0
    @ObservationIgnored weak var textView: GoLensTextView?
    var ws: WorkspaceState { textView?.workspaceState ?? WorkspaceState.shared }
    @ObservationIgnored var snippet: SnippetSession?
    @ObservationIgnored var docCache: [Int: CompletionDocInfo] = [:]
    @ObservationIgnored var suppressed = false
    @ObservationIgnored private var createdPanel: CompletionPanel?

    private var panel: CompletionPanel {
        if let createdPanel { return createdPanel }
        let created = CompletionPanel()
        createdPanel = created
        return created
    }
    @ObservationIgnored let queue = DispatchQueue(label: "golens.completion", qos: .userInteractive)
    @ObservationIgnored var goTestState = GoTestCompletionState()

    enum LocalSource { case env, dockerfile, sql, goTest }

    var isVisible: Bool { !rows.isEmpty }
    var hasActiveSnippet: Bool { snippet != nil }
    var isRequestPending: Bool { requestPending }

    private static func isIdentifier(_ u: unichar) -> Bool {
        u == 0x5F || (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u >= 0x80
    }

    private static func isEnvKeyChar(_ u: unichar) -> Bool {
        isIdentifier(u) || u == 0x2E || u == 0x2D
    }

    private func eligible(_ tv: GoLensTextView) -> DocumentSession? {
        guard let doc = tv.document, doc.syncsToCore, doc.path.hasSuffix(".go") else { return nil }
        return doc
    }

    private func dockerfileDocument(_ tv: GoLensTextView) -> DocumentSession? {
        guard let doc = tv.document, EcosystemDocumentTools.isDockerfile(doc.path) else { return nil }
        return doc
    }

    private func sqlDocument(_ tv: GoLensTextView) -> DocumentSession? {
        guard let doc = tv.document, EcosystemDocumentTools.isSQLFile(doc.path),
              tv.workspaceState.databaseDataSourceID(forConsole: doc.path) != nil else { return nil }
        return doc
    }

    private static func sqlRowKind(_ kind: String) -> String {
        switch kind {
        case "column": "field"
        case "table": "struct"
        case "view": "interface"
        case "schema": "package"
        case "function": "func"
        case "keyword": "keyword"
        default: "var"
        }
    }

    private func goSQLContext(_ tv: GoLensTextView) -> (doc: DocumentSession, context: GoSQLCompletionContext)? {
        guard let doc = eligible(tv), !doc.highlighter.injectedSQL.isEmpty, tv.selectedRange().length == 0,
              let context = tv.workspaceState.goSQLCompletionContext(doc: doc, caret: tv.selectedRange().location) else { return nil }
        return (doc, context)
    }

    private func requestSQLCompletions(in tv: GoLensTextView, explicit: Bool) {
        let caret = tv.selectedRange().location
        let doc: DocumentSession
        let request: DBCompleteRequest
        let anchorFor: (Int) -> Int
        if let sqlDoc = sqlDocument(tv) {
            guard tv.selectedRange().length == 0, caret <= sqlDoc.length else { return dismiss() }
            guard let found = tv.workspaceState.databaseUI.uiCompletionContext(path: sqlDoc.path, text: sqlDoc.storage.string, caretByte: sqlDoc.utf8.byteOffset(caret)) else { return }
            doc = sqlDoc
            request = found
            anchorFor = { sqlDoc.utf8.utf16Offset(byte: $0) }
        } else if let go = goSQLContext(tv) {
            doc = go.doc
            request = go.context.request
            anchorFor = go.context.anchor
        } else {
            return dismiss()
        }
        let wasOpen = session == -1 && localSource == .sql && tv === textView
        generation += 1
        let gen = generation
        textView = tv
        path = doc.path
        let filePath = doc.path
        let live = liveGeneration
        let started = CFAbsoluteTimeGetCurrent()
        queue.async { [weak self] in
            guard live.withLock({ $0 }) == gen else { return }
            let result = DatabaseCore.complete(request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            DispatchQueue.main.async {
                guard let self, gen == self.generation, let tv = self.textView, let doc = tv.document, doc.path == filePath else { return }
                measureLog(String(format: "completion sql %.1f ms", elapsed))
                guard let result else { return self.dismiss() }
                let caret = tv.selectedRange().location
                let anchor = min(anchorFor(result.replaceStartByte), caret)
                let query = doc.storage.mutableString.substring(with: NSRange(location: anchor, length: caret - anchor))
                self.beginLocal(.sql, in: tv, doc: doc, anchor: anchor, query: query)
                if result.items.isEmpty {
                    if !result.hint.isEmpty, explicit || wasOpen {
                        self.showHint(result.hint, in: tv)
                    } else {
                        self.dismiss()
                    }
                    return
                }
                var newRows: [CompletionRow] = []
                newRows.reserveCapacity(result.items.count)
                for (idx, item) in result.items.enumerated() {
                    let matched = Self.matchedOffsets(in: item.label, query: query)
                    newRows.append(CompletionRow(i: -(idx + 1), label: item.label, kind: Self.sqlRowKind(item.kind), params: nil, type: item.detail.isEmpty ? nil : item.detail, pkg: nil, m: matched.isEmpty ? nil : matched, dep: nil, insert: item.insert.isEmpty ? nil : item.insert))
                }
                self.showLocal(newRows, in: tv)
            }
        }
    }

    private func showHint(_ text: String, in tv: GoLensTextView) {
        if !rows.isEmpty { rows = [] }
        doc = CompletionDocInfo(signature: "", doc: text)
        showPanel(tv)
    }

    private func linePrefixBeforeCaret(in ns: NSString, caret: Int) -> String {
        let clampedCaret = max(0, min(caret, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: clampedCaret, length: 0))
        return ns.substring(with: NSRange(location: lineRange.location, length: max(0, clampedCaret - lineRange.location)))
    }

    @discardableResult
    func updateEnvCompletionsIfInsideEnvString(in tv: GoLensTextView, doc: DocumentSession) -> Bool {
        let caret = tv.selectedRange().location
        let ns: NSString = doc.storage.mutableString
        let prefixOnLine = linePrefixBeforeCaret(in: ns, caret: caret)
        guard let envPrefix = EcosystemDocumentTools.isCursorInsideGoEnvStringArg(linePrefix: prefixOnLine) else {
            if session == -1 && localSource == .env {
                dismiss()
            }
            return false
        }

        beginLocal(.env, in: tv, doc: doc, anchor: max(0, caret - (envPrefix as NSString).length), query: envPrefix)

        var openEnvDocs: [String: String] = [:]
        for (docPath, sess) in self.ws.documents where EcosystemDocumentTools.isEnvFile(docPath) {
            openEnvDocs[docPath] = sess.storage.string
        }
        let allEntries = EcosystemDocumentTools.workspaceEnvEntries(
            in: self.ws.activeWorkspacePath,
            openDocuments: openEnvDocs
        )
        var deduped: [EnvEntryInfo] = []
        var seenKeys = Set<String>()
        for entry in allEntries {
            if seenKeys.insert(entry.key).inserted {
                deduped.append(entry)
            }
        }

        let lowerQuery = envPrefix.lowercased()
        let filtered: [EnvEntryInfo]
        if lowerQuery.isEmpty {
            filtered = deduped
        } else {
            filtered = deduped.filter { $0.key.lowercased().contains(lowerQuery) }
                .sorted { a, b in
                    let aPrefix = a.key.lowercased().hasPrefix(lowerQuery)
                    let bPrefix = b.key.lowercased().hasPrefix(lowerQuery)
                    if aPrefix != bPrefix { return aPrefix }
                    return a.key.localizedStandardCompare(b.key) == .orderedAscending
                }
        }

        var envRows: [CompletionRow] = []
        envRows.reserveCapacity(filtered.count)
        for (idx, entry) in filtered.enumerated() {
            let rowId = -(idx + 1)
            let matchedIndices = Self.matchedOffsets(in: entry.key, query: envPrefix)
            let detailText = "\(entry.fileName) = \(entry.displayValue)"
            envRows.append(
                CompletionRow(
                    i: rowId,
                    label: entry.key,
                    kind: "const",
                    params: nil,
                    type: detailText,
                    pkg: nil,
                    m: matchedIndices.isEmpty ? nil : matchedIndices,
                    dep: false
                )
            )
            docCache[rowId] = CompletionDocInfo(
                signature: "\(entry.key) = \(entry.displayValue)",
                doc: "Defined in \(entry.fileName):\(entry.line)"
            )
        }

        showLocal(envRows, in: tv)
        return true
    }

    func beginLocal(_ source: LocalSource, in tv: GoLensTextView, doc: DocumentSession, anchor: Int, query: String) {
        if session > 0 || requestPending {
            CompletionCancel()
            requestPending = false
        }
        generation += 1
        session = -1
        localSource = source
        textView = tv
        path = doc.path
        self.anchor = anchor
        self.query = query
        docCache.removeAll()
    }

    func showLocal(_ newRows: [CompletionRow], in tv: GoLensTextView) {
        if newRows.isEmpty {
            if !rows.isEmpty { rows = []; self.doc = nil }
            hidePanel()
            return
        }
        let previous = rows.indices.contains(selected) ? rows[selected].label : nil
        rows = newRows
        selected = previous.flatMap { label in rows.firstIndex { $0.label == label } } ?? 0
        selectionChanged()
        showPanel(tv)
    }

    private func dockerfileCompletion(in tv: GoLensTextView, doc: DocumentSession, explicit: Bool, withGoVersion: Bool) -> DockerfileAssist.Completion? {
        guard tv.selectedRange().length == 0 else { return nil }
        let path = doc.path
        return DockerfileAssist.completion(in: doc.storage.mutableString, caret: tv.selectedRange().location, explicit: explicit) {
            guard withGoVersion else { return nil }
            return DockerfileAssist.goVersion(nearDockerfile: path) { self.ws.documents[$0]?.storage.string }
        }
    }

    @discardableResult
    private func updateDockerfileCompletions(in tv: GoLensTextView, doc: DocumentSession, explicit: Bool) -> Bool {
        guard let result = dockerfileCompletion(in: tv, doc: doc, explicit: explicit, withGoVersion: true) else {
            if session == -1 { dismiss() }
            return false
        }
        beginLocal(.dockerfile, in: tv, doc: doc, anchor: result.anchor, query: result.query)
        var newRows: [CompletionRow] = []
        for (idx, item) in result.items.enumerated() {
            let rowId = -(idx + 1)
            let matched = Self.matchedOffsets(in: item.label, query: result.query)
            newRows.append(CompletionRow(i: rowId, label: item.label, kind: item.kind, params: nil, type: item.detail, pkg: nil, m: matched.isEmpty ? nil : matched, dep: item.deprecated, insert: item.insert))
            docCache[rowId] = CompletionDocInfo(signature: item.signature, doc: item.doc)
        }
        showLocal(newRows, in: tv)
        return true
    }

    private static func matchedOffsets(in label: String, query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        let nsLabel = label as NSString
        let r = nsLabel.range(of: query, options: .caseInsensitive)
        guard r.location != NSNotFound else { return [] }
        return Array(r.location..<(r.location + r.length))
    }

    func textDidChange(in tv: GoLensTextView, inserted: String?, edit exact: (old: NSRange, newLength: Int)? = nil) {
        if snippet != nil, tv === textView, let edit = exact ?? tv.document?.lastEdit {
            if snippet?.apply(edit: edit.old, newLength: edit.newLength) != true {
                snippet = nil
            }
        }
        guard !suppressed else { return }
        if sqlDocument(tv) != nil {
            let open = session == -1 && localSource == .sql && tv === textView
            let typed = inserted.flatMap { ($0 as NSString).length == 1 ? ($0 as NSString).character(at: 0) : nil }
            if open || typed.map({ Self.isIdentifier($0) || $0 == 0x2E }) == true {
                requestSQLCompletions(in: tv, explicit: typed == 0x2E)
            }
            return
        }
        if let doc = dockerfileDocument(tv) {
            let open = session == -1 && localSource == .dockerfile && tv === textView
            if open || (inserted.map { ($0 as NSString).length == 1 } ?? false) {
                updateDockerfileCompletions(in: tv, doc: doc, explicit: open)
            }
            return
        }
        guard let doc = eligible(tv) else { return }
        if goSQLContext(tv) != nil {
            let open = session == -1 && localSource == .sql && tv === textView
            let typed = inserted.flatMap { ($0 as NSString).length == 1 ? ($0 as NSString).character(at: 0) : nil }
            if open || typed.map({ Self.isIdentifier($0) || $0 == 0x2E }) == true {
                requestSQLCompletions(in: tv, explicit: typed == 0x2E)
            } else if session != 0 {
                dismiss()
            }
            return
        }
        if updateEnvCompletionsIfInsideEnvString(in: tv, doc: doc) {
            return
        }
        if updateGoTestCompletionsIfEligible(in: tv, doc: doc, explicit: false) {
            return
        }
        if let inserted, inserted.contains("\"") {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv, !self.suppressed, let doc = self.eligible(tv) else { return }
                _ = self.updateEnvCompletionsIfInsideEnvString(in: tv, doc: doc)
            }
        }
        let caret = tv.selectedRange().location
        let ns: NSString = doc.storage.mutableString
        if session != 0 || requestPending {
            if path == doc.path, caret >= anchor {
                if (inserted == "." || inserted == "("), commitExactUniqueMatch(tv, doc: doc, typed: caret - 1) {
                    if inserted == "." { start(in: tv, doc: doc, kind: 2, trigger: ".") }
                    return
                }
                refilter(tv, doc: doc)
                if inserted == "." && canTrigger(doc, ns, caret: caret, dot: true) { start(in: tv, doc: doc, kind: 2, trigger: ".") }
                return
            }
            dismiss()
        }
        guard let inserted, (inserted as NSString).length == 1 else { return }
        let ch = (inserted as NSString).character(at: 0)
        if ch == 0x2E {
            if canTrigger(doc, ns, caret: caret, dot: true) { start(in: tv, doc: doc, kind: 2, trigger: ".") }
        } else if Self.isIdentifier(ch), canTrigger(doc, ns, caret: caret, dot: false) {
            start(in: tv, doc: doc, kind: 1, trigger: "")
        }
    }

    private func canTrigger(_ doc: DocumentSession, _ ns: NSString, caret: Int, dot: Bool) -> Bool {
        guard caret > 0, caret <= ns.length else { return false }
        var i = dot ? caret - 1 : caret
        while i > 0, Self.isIdentifier(ns.character(at: i - 1)) { i -= 1 }
        let wordEnd = dot ? caret - 1 : caret
        if i < wordEnd {
            let first = ns.character(at: i)
            if first >= 0x30 && first <= 0x39 { return false }
        } else if !dot {
            return false
        }
        return !(doc.highlighter.inCommentOrString(at: caret, in: ns) ?? Self.inCommentOrString(ns, caret: caret))
    }

    static func inCommentOrString(_ ns: NSString, caret: Int) -> Bool {
        let lineStart = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0)).location
        var quote: unichar = 0
        var i = lineStart
        var blockComment = false
        while i < caret {
            let c = ns.character(at: i)
            if blockComment {
                if c == 0x2A, i + 1 < caret, ns.character(at: i + 1) == 0x2F { blockComment = false; i += 1 }
            } else if quote != 0 {
                if c == 0x5C, quote != 0x60 { i += 1 } else if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 || c == 0x60 {
                quote = c
            } else if c == 0x2F, i + 1 < ns.length {
                let n = ns.character(at: i + 1)
                if n == 0x2F { return true }
                if n == 0x2A { blockComment = true; i += 1 }
            }
            i += 1
        }
        return quote != 0 || blockComment
    }

    func trigger(in tv: GoLensTextView) {
        if sqlDocument(tv) != nil {
            requestSQLCompletions(in: tv, explicit: true)
            return
        }
        if let doc = dockerfileDocument(tv) {
            updateDockerfileCompletions(in: tv, doc: doc, explicit: true)
            return
        }
        guard let doc = eligible(tv) else { return }
        if goSQLContext(tv) != nil {
            requestSQLCompletions(in: tv, explicit: true)
            return
        }
        if updateEnvCompletionsIfInsideEnvString(in: tv, doc: doc) {
            return
        }
        if updateGoTestCompletionsIfEligible(in: tv, doc: doc, explicit: true) {
            return
        }
        start(in: tv, doc: doc, kind: 1, trigger: "")
    }

    func isEditingPlaceholder(_ range: NSRange, in tv: GoLensTextView) -> Bool {
        guard let s = snippet, tv === textView, range.length > 0 else { return false }
        return NSEqualRanges(s.currentRange, range)
    }

    func caretMoved(in tv: GoLensTextView) {
        let sel = tv.selectedRange()
        if requestPending || session != 0 {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv, tv === self.textView, self.requestPending || self.session != 0, !self.queryIsWord(tv) else { return }
                self.dismiss()
            }
        }
        if snippet != nil {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv, let s = self.snippet else { return }
                let now = tv.selectedRange()
                let r = s.currentRange
                if tv !== self.textView || now.location < r.location || NSMaxRange(now) > NSMaxRange(r) { self.snippet = nil }
            }
        }
        guard isVisible || requestPending || session != 0, tv === textView else { return }
        if sel.length > 0 || sel.location < anchor || sel.location - anchor > 256 {
            dismiss()
        }
    }

    private func start(in tv: GoLensTextView, doc: DocumentSession, kind: Int32, trigger: String, background: Bool = false) {
        generation += 1
        let gen = generation
        if !background {
            hidePanel()
            session = 0
        }
        textView = tv
        path = doc.path
        requestPending = true
        let caret = tv.selectedRange().location
        if !background { anchor = wordStart(in: doc, caret: caret) }
        let caretByte = doc.utf8.byteOffset(caret)
        let filePath = doc.path
        requestStarted = CFAbsoluteTimeGetCurrent()
        let live = liveGeneration
        queue.async { [weak self] in
            guard live.withLock({ $0 }) == gen else { return }
            let result = filePath.withCString { p in
                trigger.withCString { decodeGo(CompletionStartResult.self, CompletionStart(p, Int32(caretByte), kind, $0)) }
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.requestPending = false
                guard let result, result.stale != true, result.ok, let id = result.session else {
                    if background { return }
                    if let error = result?.error { self.ws.appendLog("Completion failed: \(error)") }
                    if result?.stale == true { return }
                    return self.dismiss()
                }
                guard let tv = self.textView, let doc = tv.document, doc.path == filePath else { return self.dismiss() }
                let newAnchor = doc.utf8.utf16Offset(byte: result.anchor)
                if background && newAnchor != self.anchor { return }
                self.session = id
                self.anchor = newAnchor
                self.docCache.removeAll()
                self.refilter(tv, doc: doc, allowRefresh: false)
                if self.isVisible && !background {
                    measureLog(String(format: "completion first-results %.1f ms", (CFAbsoluteTimeGetCurrent() - self.requestStarted) * 1000))
                }
            }
        }
    }

    private func typedWord(_ tv: GoLensTextView) -> String? {
        let caret = tv.selectedRange().location
        guard let doc = tv.document, caret >= anchor, caret <= doc.length else { return nil }
        return doc.storage.mutableString.substring(with: NSRange(location: anchor, length: caret - anchor))
    }

    private func queryIsWord(_ tv: GoLensTextView) -> Bool {
        guard let doc = tv.document else { return false }
        let caret = tv.selectedRange().location
        guard caret >= anchor, caret - anchor <= 256, caret <= doc.length else { return false }
        let ns: NSString = doc.storage.mutableString
        if session == -1 {
            switch localSource {
            case .env:
                for i in anchor..<caret where !Self.isEnvKeyChar(ns.character(at: i)) { return false }
                let prefixOnLine = linePrefixBeforeCaret(in: ns, caret: caret)
                return EcosystemDocumentTools.isCursorInsideGoEnvStringArg(linePrefix: prefixOnLine) != nil
            case .dockerfile:
                return dockerfileCompletion(in: tv, doc: doc, explicit: true, withGoVersion: false)?.anchor == anchor
            case .sql:
                for i in anchor..<caret where !Self.isIdentifier(ns.character(at: i)) { return false }
                return true
            case .goTest:
                return isGoTestQueryValid(in: doc, caret: caret)
            }
        }
        for i in anchor..<caret where !Self.isIdentifier(ns.character(at: i)) { return false }
        return true
    }

    private func wordStart(in doc: DocumentSession, caret: Int) -> Int {
        let ns: NSString = doc.storage.mutableString
        var i = caret
        while i > 0, caret - i < 256, Self.isIdentifier(ns.character(at: i - 1)) { i -= 1 }
        return i
    }

    private func refilter(_ tv: GoLensTextView, doc: DocumentSession, allowRefresh: Bool = true) {
        if session == -1 {
            switch localSource {
            case .env: updateEnvCompletionsIfInsideEnvString(in: tv, doc: doc)
            case .dockerfile: updateDockerfileCompletions(in: tv, doc: doc, explicit: true)
            case .sql: requestSQLCompletions(in: tv, explicit: false)
            case .goTest: updateGoTestCompletionsIfEligible(in: tv, doc: doc, explicit: true)
            }
            return
        }
        guard session > 0 else { return }
        let caret = tv.selectedRange().location
        guard queryIsWord(tv) else { return dismiss() }
        let started = CFAbsoluteTimeGetCurrent()
        let q = doc.storage.mutableString.substring(with: NSRange(location: anchor, length: caret - anchor))
        let caretByte = doc.utf8.byteOffset(caret)
        let result = doc.path.withCString { p in
            q.withCString { decodeGo(CompletionFilterResult.self, CompletionFilter(session, p, Int32(caretByte), $0)) }
        }
        measureLog(String(format: "completion refilter %.3f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000))
        guard let result else { return dismiss() }
        switch result.action {
        case "show":
            let sameQuery = q == query
            query = q
            let merged = Self.mergingTemplates(into: result.rows, query: q)
            if merged.isEmpty {
                if !rows.isEmpty { rows = []; self.doc = nil }
                hidePanel()
            } else {
                let previous = sameQuery && rows.indices.contains(selected) ? rows[selected].label : nil
                rows = merged
                selected = previous.flatMap { label in rows.firstIndex { $0.label == label } } ?? 0
                selectionChanged()
                showPanel(tv)
            }
            if allowRefresh, result.refresh == true {
                start(in: tv, doc: doc, kind: 3, trigger: "", background: true)
            }
        case "requery":
            if requestPending { return }
            if rows.isEmpty {
                dismiss()
                start(in: tv, doc: doc, kind: 1, trigger: "")
            } else {
                start(in: tv, doc: doc, kind: 3, trigger: "", background: true)
            }
        default:
            dismiss()
        }
    }

    private static func mergingTemplates(into rows: [CompletionRow], query: String) -> [CompletionRow] {
        let templates = LiveTemplateStore.shared.matching(prefix: query)
        guard !templates.isEmpty else { return rows }
        let matched = Array(0..<query.utf16.count)
        let templateRows = templates.map { entry in
            CompletionRow(i: entry.row, label: entry.template.abbreviation, kind: "snippet", params: nil,
                          type: entry.template.description, pkg: "Template", m: matched, dep: nil)
        }
        let exact = templateRows.filter { $0.label == query }
        let partial = templateRows.filter { $0.label != query }
        let leading = rows.prefix { $0.label.hasPrefix(query) }.count
        return exact + Array(rows.prefix(leading)) + partial + Array(rows.dropFirst(leading))
    }

    func expandTemplate(_ body: String, replacing range: NSRange, selection: String, in tv: GoLensTextView, actionName: String) {
        guard let doc = tv.document, NSMaxRange(range) <= doc.length else { return }
        let ns: NSString = doc.storage.mutableString
        let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        var indentEnd = lineStart
        while indentEnd < range.location, [0x20, 0x09].contains(ns.character(at: indentEnd)) { indentEnd += 1 }
        let indent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        let expansion = body.withCString { b in indent.withCString { i in selection.withCString { s in
            decodeGo(TemplateExpansion.self, ExpandLiveTemplate(b, i, s))
        } } }
        guard let expansion else { return }
        snippet = nil
        tv.workspaceState.applyRanges([(range, expansion.text)], in: doc, actionName: actionName)
        if let s = SnippetSession(base: range.location, stops: expansion.stops, final: expansion.final) {
            snippet = s
            textView = tv
            tv.setSelectedRange(s.currentRange)
        } else {
            let caret = range.location + (expansion.final >= 0 ? expansion.final : (expansion.text as NSString).length)
            tv.setSelectedRange(NSRange(location: min(caret, doc.length), length: 0))
        }
    }

    private func commitExactUniqueMatch(_ tv: GoLensTextView, doc: DocumentSession, typed: Int) -> Bool {
        guard rows.count == 1, rows[0].label == query, rows[0].i >= 0, session > 0 else { return false }
        if rows[0].kind == "package", typed < doc.length, doc.storage.mutableString.character(at: typed) == 0x28 { return false }
        let itemIndex = rows[0].i
        let result = decodeGo(CompletionCommitResult.self, CompletionCommit(session, Int32(itemIndex), Int32(doc.utf8.byteOffset(typed))))
        dismiss()
        guard let result, result.ok, !result.additional.isEmpty else { return true }
        let caret = tv.selectedRange().location
        let ranges = tv.workspaceState.resolvedRanges(result.additional, in: doc)
        let shift: Int = ranges.filter { $0.0.location < caret }.reduce(0) { (acc: Int, r: (NSRange, String)) in acc + (r.1 as NSString).length - r.0.length }
        tv.workspaceState.applyRanges(ranges, in: doc)
        tv.setSelectedRange(NSRange(location: min(caret + shift, doc.length), length: 0))
        return true
    }

    private func selectionChanged() {
        guard rows.indices.contains(selected) else { doc = nil; return }
        let index = rows[selected].i
        if let template = LiveTemplateStore.shared.template(forRow: index) {
            doc = CompletionDocInfo(signature: template.description, doc: template.body)
        } else if let cached = docCache[index] {
            doc = cached
        } else if session > 0 && index >= 0 {
            let info = decodeGo(CompletionDocInfo.self, CompletionDoc(session, Int32(index)))
            docCache[index] = info
            doc = info
        } else {
            doc = nil
        }
        let row = rows[selected]
        let announcement = [row.label, row.kind, row.type ?? "", "row \(selected + 1) of \(rows.count)"].filter { !$0.isEmpty }.joined(separator: ", ")
        if let window = textView?.window {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selected = index
        selectionChanged()
    }

    private static var acceptSelector: Selector {
        shared.ws.completionAcceptKey == .tab ? #selector(NSResponder.insertTab(_:)) : #selector(NSResponder.insertNewline(_:))
    }

    func handle(_ selector: Selector, in tv: GoLensTextView) -> Bool {
        if (requestPending || session != 0) && !queryIsWord(tv) { dismiss() }
        if !isVisible && (requestPending || session != 0) {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                dismiss()
            case #selector(NSResponder.cancelOperation(_:)):
                dismiss()
                return true
            default:
                break
            }
        }
        if isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                PopupMouseTracker.markKeyboardOrOpen()
                select((selected - 1 + rows.count) % rows.count)
                return true
            case #selector(NSResponder.moveDown(_:)):
                PopupMouseTracker.markKeyboardOrOpen()
                select((selected + 1) % rows.count)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                guard selector == Self.acceptSelector else {
                    dismiss()
                    return false
                }
                commit(selected, in: tv)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismiss()
                return true
            default:
                return false
            }
        }
        guard var s = snippet else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if let next = s.next() {
                snippet = s
                tv.setSelectedRange(next)
            } else {
                snippet = nil
                tv.setSelectedRange(NSRange(location: min(s.exitCaret, tv.document?.length ?? 0), length: 0))
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if let prev = s.previous() {
                snippet = s
                tv.setSelectedRange(prev)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:)):
            snippet = nil
            return selector == #selector(NSResponder.cancelOperation(_:))
        default:
            return false
        }
    }

    func commit(_ rowIndex: Int, in tv: GoLensTextView) {
        guard rows.indices.contains(rowIndex), let doc = tv.document else { return }
        let row = rows[rowIndex]
        let itemIndex = row.i
        let caret = tv.selectedRange().location
        if let template = LiveTemplateStore.shared.template(forRow: itemIndex) {
            let start = max(0, min(anchor, caret))
            dismiss()
            expandTemplate(template.body, replacing: NSRange(location: start, length: max(anchor, caret) - start), selection: "",
                           in: tv, actionName: "Insert Template")
            return
        }
        if itemIndex < 0 || session == -1 {
            if session == -1 && localSource == .goTest {
                commitGoTestCompletion(row, caret: caret, in: tv, doc: doc)
                return
            }
            let start = max(0, min(anchor, caret))
            var end = max(anchor, caret)
            let ns: NSString = doc.storage.mutableString
            let isSQL = session == -1 && localSource == .sql
            while end < ns.length, isSQL ? Self.isIdentifier(ns.character(at: end)) : Self.isEnvKeyChar(ns.character(at: end)) {
                end += 1
            }
            let replaceRange = NSRange(location: start, length: max(0, end - start))
            var insertedKey = row.insertText
            var caretShift = 0
            if insertedKey.hasSuffix(" "), end < ns.length, ns.character(at: end) == 0x20 {
                insertedKey.removeLast()
                caretShift = 1
            }
            let continueDockerfile = session == -1 && localSource == .dockerfile && (row.insertText.hasSuffix(" ") || row.insertText.hasSuffix("="))
            dismiss()
            tv.workspaceState.applyRanges([(replaceRange, insertedKey)], in: doc)
            let newCaret = start + (insertedKey as NSString).length + caretShift
            tv.setSelectedRange(NSRange(location: min(newCaret, doc.length), length: 0))
            if continueDockerfile {
                updateDockerfileCompletions(in: tv, doc: doc, explicit: false)
            }
            return
        }
        guard let result = decodeGo(CompletionCommitResult.self, CompletionCommit(session, Int32(itemIndex), Int32(doc.utf8.byteOffset(caret)))), result.ok else {
            return dismiss()
        }
        dismiss()
        let start = doc.utf8.utf16Offset(byte: result.start)
        let end = max(start, doc.utf8.utf16Offset(byte: result.end))
        var ranges = tv.workspaceState.resolvedRanges(result.additional, in: doc)
        ranges.append((NSRange(location: start, length: end - start), result.text))
        ranges.sort { $0.0.location > $1.0.location }
        let shiftBefore = ranges.filter { $0.0.location < start }.reduce(0) { $0 + ($1.1 as NSString).length - $1.0.length }
        tv.workspaceState.applyRanges(ranges, in: doc)
        let base = start + shiftBefore
        if var s = SnippetSession(base: base, stops: result.stops, final: result.final) {
            if var outer = snippet, tv === textView, outer.nest(s) { s = outer }
            snippet = s
            textView = tv
            tv.setSelectedRange(s.currentRange)
        } else {
            let end = result.final >= 0 ? base + result.final : base + (result.text as NSString).length
            tv.setSelectedRange(NSRange(location: min(end, doc.length), length: 0))
        }
    }

    func dismiss() {
        let hadGoRequest = requestPending || session > 0
        generation += 1
        requestPending = false
        session = 0
        goTestState.reset()
        if !rows.isEmpty {
            rows = []
            doc = nil
            query = ""
        } else if doc != nil {
            doc = nil
        }
        hidePanel()
        if hadGoRequest { CompletionCancel() }
    }

    private func hidePanel() {
        guard let panel = createdPanel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func showPanel(_ tv: GoLensTextView) {
        guard let window = tv.window else { return }
        tv.inlineSuggestions.dismiss()
        panel.syncThemeAppearance()
        let font = TechnicalTypography.codeCanvasNSFont(size: self.ws.editorFontSize, weight: .regular)
        let size = CompletionLayout.size(rows: rows, doc: doc, font: font)
        let anchorRect = tv.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchorRect.minX - CompletionLayout.nameInset, y: anchorRect.minY - 2 - size.height)
        if origin.y < screen.minY {
            origin.y = anchorRect.maxY + 2
        }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

