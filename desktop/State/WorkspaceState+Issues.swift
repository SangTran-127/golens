import AppKit

struct IssueCount: Equatable {
    var errors = 0
    var warnings = 0
}

struct IssuePopup {
    let path: String
    let line: Int
    let origin: CGPoint
    var anchorRect: CGRect = .zero
    var anchorBounds: CGRect = .zero
    let diags: [DiagnosticData]
    var fixes: [LSPCodeActionItem] = [] {
        didSet {
            if fixes.first?.id != oldValue.first?.id { primaryFixShownAt = ProcessInfo.processInfo.systemUptime }
        }
    }
    let related: [FlatDiagnosticItem]
    var testFailure: TestFailureAnnotation? = nil
    private(set) var primaryFixShownAt = ProcessInfo.processInfo.systemUptime

    static let keyboardActivationDelay: TimeInterval = 0.25

    func acceptsKeyboardActivation(at timestamp: TimeInterval) -> Bool {
        timestamp >= primaryFixShownAt + Self.keyboardActivationDelay
    }
}

extension WorkspaceState {
    static let showIssuesInlineKey = "GoLensShowIssuesInline"

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func rebuildDiagnosticsIndex() {
        var index = DiagnosticsIndex()
        index.workspaceKey = activeWorkspacePath
        index.root = Self.canonicalPath(activeWorkspacePath)
        var counts: [String: IssueCount] = [:]
        var totals = IssueCount()
        for (path, diags) in diagnostics {
            index.slices[path] = DiagnosticsIndex.slice(path: path, diags: diags)
            let count = DiagnosticsIndex.count(diags)
            guard count != IssueCount() else { continue }
            totals.errors += count.errors
            totals.warnings += count.warnings
            counts[path] = count
            if count.errors > 0 { index.addErrorFile(path) }
        }
        index.paths = index.slices.keys.sorted()
        diagnosticsIndex = index
        publishFlatDiagnostics()
        if counts != issueCounts { issueCounts = counts }
        publishIssueIndex(totals: totals)
    }

    func updateDiagnosticsIndex(changedPath path: String) {
        let indexedOthers = diagnosticsIndex.slices.count - (diagnosticsIndex.slices[path] == nil ? 0 : 1)
        let currentOthers = diagnostics.count - (diagnostics[path] == nil ? 0 : 1)
        guard diagnosticsIndex.workspaceKey == activeWorkspacePath, indexedOthers == currentOthers else {
            rebuildDiagnosticsIndex()
            return
        }
        let diags = diagnostics[path] ?? []
        var index = diagnosticsIndex
        let hadSlice = index.slices[path] != nil
        if diags.isEmpty {
            index.slices.removeValue(forKey: path)
            if hadSlice, let at = index.position(of: path) { index.paths.remove(at: at) }
        } else {
            index.slices[path] = DiagnosticsIndex.slice(path: path, diags: diags)
            if !hadSlice { index.paths.insert(path, at: index.insertionPoint(for: path)) }
        }
        let oldCount = issueCounts[path] ?? IssueCount()
        let newCount = DiagnosticsIndex.count(diags)
        if (oldCount.errors > 0) != (newCount.errors > 0) {
            if newCount.errors > 0 { index.addErrorFile(path) } else { index.removeErrorFile(path) }
        }
        diagnosticsIndex = index
        publishFlatDiagnostics()
        if oldCount != newCount {
            if newCount == IssueCount() {
                issueCounts.removeValue(forKey: path)
            } else {
                issueCounts[path] = newCount
            }
        }
        var totals = issueTotals
        totals.errors += newCount.errors - oldCount.errors
        totals.warnings += newCount.warnings - oldCount.warnings
        publishIssueIndex(totals: totals)
    }

    private func publishFlatDiagnostics() {
        var flat: [FlatDiagnosticItem] = []
        flat.reserveCapacity(diagnosticsIndex.slices.values.reduce(0) { $0 + $1.count })
        for path in diagnosticsIndex.paths {
            flat.append(contentsOf: diagnosticsIndex.slices[path] ?? [])
        }
        if flat != flatDiagnostics { flatDiagnostics = flat }
    }

    private func publishIssueIndex(totals: IssueCount) {
        if totals != issueTotals { issueTotals = totals }
        let folders = Set(diagnosticsIndex.folderRefs.keys)
        if folders != errorFolders { errorFolders = folders }
        let packages = Set(diagnosticsIndex.packageRefs.keys)
        if packages != errorPackages { errorPackages = packages }
        if totals.errors == 0 {
            clearBuildRunFailureIfResolved()
        }
    }

    func clearBuildRunFailureIfResolved() {
        guard issueTotals.errors == 0 else { return }
        if let kind = runFailure?.kind, kind == .build || kind == .command("Build") {
            runFailure = nil
        }
        for i in runSessions.indices {
            if let kind = runSessions[i].failure?.kind, kind == .build || kind == .command("Build") {
                runSessions[i].failure = nil
            }
        }
    }

    func packageHasErrors(_ filePath: String) -> Bool {
        errorPackages.contains((filePath as NSString).deletingLastPathComponent)
    }

    func likelyCauses(of diag: DiagnosticData, in path: String) -> [FlatDiagnosticItem] {
        let m = diag.message
        guard diag.severity == 1, m.contains("undefined") || m.contains("has no field or method") || m.contains("could not import") else { return [] }
        let isSyntax = { (msg: String) in msg.hasPrefix("expected ") || msg.hasPrefix("missing ") || msg.hasPrefix("illegal ") || msg.contains("syntax error") }
        return Array(flatDiagnostics.filter { $0.path != path && $0.diag.severity == 1 && isSyntax($0.diag.message) }.prefix(3))
    }

    func toggleIssuePopup(in textView: GoLensTextView, line: Int, diags: [DiagnosticData], below rect: NSRect) {
        if issuePopup?.path == textView.filePath && issuePopup?.line == line {
            issuePopup = nil
            return
        }
        presentIssuePopup(in: textView, line: line, diags: diags, below: rect, preferredTestFailure: nil)
    }

    func presentIssuePopup(
        in textView: GoLensTextView,
        line: Int,
        diags: [DiagnosticData],
        below rect: NSRect,
        preferredTestFailure: TestFailureAnnotation?
    ) {
        guard let window = textView.window, let contentView = window.contentView else { return }
        let windowRect = textView.convert(rect, to: nil)
        let contentHeight = contentView.bounds.height
        let anchorRect = CGRect(
            x: windowRect.minX,
            y: contentHeight - windowRect.maxY,
            width: max(16, windowRect.width),
            height: max(14, windowRect.height)
        )
        let anchorBounds = textView.popupBoundsInWindow()
        let origin = CGPoint(x: windowRect.minX, y: contentHeight - windowRect.minY + 4)
        let path = textView.filePath
        let testFailure = preferredTestFailure ?? testFailureAnnotationsForPath(path).first { $0.line == line }
        issuePopup = IssuePopup(path: path, line: line, origin: origin, anchorRect: anchorRect, anchorBounds: anchorBounds, diags: diags,
                                related: diags.lazy.map { self.likelyCauses(of: $0, in: path) }.first { !$0.isEmpty } ?? [],
                                testFailure: testFailure)
        if EcosystemDocumentTools.isDockerfile(path) {
            issuePopup?.fixes = dockerfileFixItems(path: path, lines: Set(diags.map(\.line)))
            return
        }
        guard let session = textView.document, session.syncsToCore,
              let first = diags.first else { return }
        if path.hasSuffix(".go") {
            let astContent = session.storage.string
            let astLine = line
            BackgroundFFI.shared.run("issuePopup.astQuickFixes", work: {
                Self.computeASTQuickFixes(filePath: path, content: astContent, line: astLine)
            }, deliver: { [weak self] fixes in
                guard let self, self.issuePopup?.path == path, self.issuePopup?.line == line else { return }
                let astItems = fixes.compactMap { fix -> LSPCodeActionItem? in
                    guard let title = fix["title"] as? String,
                          let updated = fix["updatedSource"] as? String else { return nil }
                    let actionDict: [String: Any] = [
                        "title": title,
                        "kind": "quickfix.golens",
                        "golens": "astQuickFix",
                        "filePath": path,
                        "updatedSource": updated,
                        "summary": fix["summary"] as? String ?? ""
                    ]
                    return LSPCodeActionItem(actionDict)
                }
                guard !astItems.isEmpty else { return }
                let existingNonAST = (self.issuePopup?.fixes ?? []).filter { $0.raw["golens"] as? String != "astQuickFix" }
                self.issuePopup?.fixes = astItems + existingNonAST
            })
        }
        guard let start = session.offset(line: first.line, utf16Column: first.col) else { return }
        let end = session.offset(line: first.endLine, utf16Column: first.endCol) ?? start
        requestCodeActions(in: session, range: NSRange(location: start, length: max(0, end - start)), only: ["quickfix"]) { [weak self] items in
            guard let self, self.issuePopup?.path == path, self.issuePopup?.line == line else { return }
            let existingAST = (self.issuePopup?.fixes ?? []).filter { $0.raw["golens"] as? String == "astQuickFix" }
            let lspItems = items.filter { $0.disabledReason == nil && $0.kind.hasPrefix("quickfix") }
            self.issuePopup?.fixes = existingAST + lspItems
        }
    }

    func openIssue(_ item: FlatDiagnosticItem) {
        issuePopup = nil
        jumpTo(filePath: item.path, line: item.diag.line + 1, column: item.diag.col + 1)
    }

    func jumpToIssue(forward: Bool) {
        let title = forward ? "Next Issue" : "Previous Issue"
        guard let textView = activeTextView as? GoLensTextView, !textView.filePath.isEmpty,
              let session = textView.document else {
            presentCommandFeedback("Open a file in the editor to move between its issues.", title: title)
            return
        }
        let byLine = textView.issuesByLine()
        let lines = byLine.keys.sorted()
        guard let first = lines.first, let last = lines.last else {
            presentCommandFeedback("No issues in this file.", title: title)
            return
        }
        let current = textView.lineAndCol(forCharacterIndex: textView.selectedRange().location).line
        let target = forward ? (lines.first { $0 > current } ?? first) : (lines.last { $0 < current } ?? last)
        let issues = byLine[target] ?? []
        let column = issues.map(\.col).min() ?? 0
        guard let offset = session.offset(line: target - 1, utf16Column: column) ?? session.lines.start(ofLine: target - 1) else { return }
        let caret = NSRange(location: offset, length: 0)
        issuePopup = nil
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: offset < session.length ? 1 : 0), actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        anchor.origin.x += textView.textContainerOrigin.x
        anchor.origin.y += textView.textContainerOrigin.y
        toggleIssuePopup(in: textView, line: target, diags: issues, below: anchor)
    }
}

struct DiagnosticsIndex {
    var workspaceKey: String?
    var root = ""
    var slices: [String: [FlatDiagnosticItem]] = [:]
    var paths: [String] = []
    var packageRefs: [String: Int] = [:]
    var folderRefs: [String: Int] = [:]

    static func slice(path: String, diags: [DiagnosticData]) -> [FlatDiagnosticItem] {
        diags.enumerated().sorted { a, b in
            a.element.line != b.element.line ? a.element.line < b.element.line : a.offset < b.offset
        }.map { FlatDiagnosticItem(path: path, diag: $0.element) }
    }

    static func count(_ diags: [DiagnosticData]) -> IssueCount {
        var count = IssueCount()
        for d in diags {
            if d.severity == 1 { count.errors += 1 } else if d.severity == 2 { count.warnings += 1 }
        }
        return count
    }

    func insertionPoint(for path: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < path { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func position(of path: String) -> Int? {
        let at = insertionPoint(for: path)
        return at < paths.count && paths[at] == path ? at : nil
    }

    private func errorFolders(of file: String) -> [String] {
        var result: [String] = []
        var dir = (file as NSString).deletingLastPathComponent
        while dir.count > 1, dir.hasPrefix(root) {
            result.append(dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        return result
    }

    mutating func addErrorFile(_ file: String) {
        packageRefs[(file as NSString).deletingLastPathComponent, default: 0] += 1
        for dir in errorFolders(of: file) {
            folderRefs[dir, default: 0] += 1
        }
    }

    mutating func removeErrorFile(_ file: String) {
        let package = (file as NSString).deletingLastPathComponent
        if let n = packageRefs[package] {
            packageRefs[package] = n > 1 ? n - 1 : nil
        }
        for dir in errorFolders(of: file) {
            if let n = folderRefs[dir] {
                folderRefs[dir] = n > 1 ? n - 1 : nil
            }
        }
    }
}
