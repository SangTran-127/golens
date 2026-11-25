import AppKit
import GoLensFoundation

struct QuickDefinitionTarget: Equatable {
    let path: String
    let line: Int
    let column: Int
    let snippet: DefinitionSnippet

    var title: String { "\((path as NSString).lastPathComponent):\(line)" }
}

struct QuickDocumentationRequest {
    enum Kind {
        case documentation
        case definition

        var title: String { self == .documentation ? "Quick Documentation" : "Quick Definition" }
    }

    enum Phase: Equatable {
        case noSymbol
        case loading
        case loaded(String)
        case definition(QuickDefinitionTarget)
        case unresolved
    }

    var id: Int
    weak var editor: GoLensTextView?
    let caret: Int
    let selection: [NSValue]
    let scrollOrigin: NSPoint
    let symbolIndex: Int?
    let anchor: CGRect
    let bounds: CGRect
    var phase: Phase
    var kind: Kind = .documentation

    var takesFocus: Bool { phase != .noSymbol }
}

struct EditorCaretAnchor {
    weak var editor: GoLensTextView?
    let location: Int
    weak var workspace: WorkspaceState? = nil

    static func current(in workspace: WorkspaceState) -> EditorCaretAnchor {
        let editor = workspace.activeTextView as? GoLensTextView
        return EditorCaretAnchor(editor: editor, location: editor?.selectedRange().location ?? 0, workspace: workspace)
    }

    func showQuickDocumentation(kind: QuickDocumentationRequest.Kind = .documentation) {
        guard let editor else {
            (workspace ?? WorkspaceState.shared).presentCommandFeedback(
                "Open a Go file in the editor to view \(kind.title).",
                title: kind.title
            )
            return
        }
        editor.showQuickDocumentation(at: location, kind: kind)
    }
}

extension GoLensTextView {
    private static var quickDocumentationSerial = 0
    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto",
        "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]

    var quickDocumentationRequest: QuickDocumentationRequest? {
        guard let request = self.workspaceState.lsp.quickDocumentation, request.editor === self else { return nil }
        return request
    }

    func showQuickDocumentation(at location: Int? = nil, kind: QuickDocumentationRequest.Kind = .documentation) {
        let workspace = self.workspaceState
        guard filePath.hasSuffix(".go"), workspace.editorMode(for: filePath) == .code else {
            workspace.presentCommandFeedback(
                "\(kind.title) works in Go source files.",
                title: kind.title
            )
            return
        }
        dismissHoverImmediate()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let text = string as NSString
        let caret = selectedRange().location
        let target = min(max(0, location ?? caret), text.length)
        let symbol = quickDocumentationSymbol(near: target, in: text)
        Self.quickDocumentationSerial += 1
        let request = QuickDocumentationRequest(
            id: Self.quickDocumentationSerial,
            editor: self,
            caret: caret,
            selection: selectedRanges,
            scrollOrigin: enclosingScrollView?.contentView.bounds.origin ?? .zero,
            symbolIndex: symbol?.location,
            anchor: quickDocumentationAnchor(for: symbol ?? NSRange(location: target, length: 0)),
            bounds: popupBoundsInWindow(),
            phase: symbol == nil ? .noSymbol : .loading,
            kind: kind
        )
        workspace.lsp.quickDocumentation = request
        if symbol != nil { load(request) }
    }

    func showQuickDefinition(at location: Int? = nil) {
        showQuickDocumentation(at: location, kind: .definition)
    }

    func retryQuickDocumentation() {
        guard var request = quickDocumentationRequest, request.symbolIndex != nil else { return }
        Self.quickDocumentationSerial += 1
        request.id = Self.quickDocumentationSerial
        request.phase = .loading
        self.workspaceState.lsp.quickDocumentation = request
        load(request)
    }

    @discardableResult
    func presentModuleWhyDocumentation(module: String, line: Int) -> Int {
        let workspace = self.workspaceState
        dismissHoverImmediate()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let nsText = string as NSString
        var cursor = 0
        var currentLine = 1
        var anchorRange = NSRange(location: 0, length: 0)
        while cursor < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            if currentLine == line {
                let match = nsText.range(of: module, options: [], range: lineRange)
                anchorRange = match.location != NSNotFound ? match : NSRange(location: lineRange.location, length: min(lineRange.length, 1))
                break
            }
            if lineRange.length == 0 { break }
            cursor = NSMaxRange(lineRange)
            currentLine += 1
        }
        Self.quickDocumentationSerial += 1
        let requestID = Self.quickDocumentationSerial
        let request = QuickDocumentationRequest(
            id: requestID,
            editor: self,
            caret: selectedRange().location,
            selection: selectedRanges,
            scrollOrigin: enclosingScrollView?.contentView.bounds.origin ?? .zero,
            symbolIndex: nil,
            anchor: quickDocumentationAnchor(for: anchorRange),
            bounds: popupBoundsInWindow(),
            phase: .loading
        )
        workspace.lsp.quickDocumentation = request
        return requestID
    }

    func updateModuleWhyDocumentation(id: Int, markdown: String) {
        let lsp = self.workspaceState.lsp
        guard var current = lsp.quickDocumentation, current.id == id else { return }
        current.phase = .loaded(markdown)
        lsp.quickDocumentation = current
    }

    func closeQuickDocumentation() {
        guard let request = quickDocumentationRequest else { return }
        dismissHoverImmediate()
        returnFocusFromQuickDocumentation()
        let length = (string as NSString).length
        let selection = request.selection.filter { NSMaxRange($0.rangeValue) <= length }
        if !selection.isEmpty, selection != selectedRanges {
            setSelectedRanges(selection, affinity: .downstream, stillSelecting: false)
        }
        if let scrollView = enclosingScrollView, scrollView.contentView.bounds.origin != request.scrollOrigin {
            scrollView.contentView.scroll(to: request.scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func openQuickDocumentationSource() {
        guard let request = quickDocumentationRequest, let index = request.symbolIndex else { return }
        dismissHoverImmediate()
        returnFocusFromQuickDocumentation()
        if case .definition(let target) = request.phase {
            jumpTo(path: target.path, line: target.line, col: target.column)
        } else {
            goToDefinition(at: index)
        }
    }

    @objc func contextQuickDocumentation(_ sender: NSMenuItem) {
        showQuickDocumentation(at: sender.representedObject as? Int)
    }

    @objc func contextQuickDefinition(_ sender: NSMenuItem) {
        showQuickDefinition(at: sender.representedObject as? Int)
    }

    private func returnFocusFromQuickDocumentation() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    private func load(_ request: QuickDocumentationRequest) {
        switch request.kind {
        case .documentation: loadQuickDocumentation(request)
        case .definition: loadQuickDefinition(request)
        }
    }

    private func loadQuickDefinition(_ request: QuickDocumentationRequest) {
        guard let index = request.symbolIndex else { return }
        let (line, col) = lineAndCol(forCharacterIndex: index)
        let path = filePath
        let id = request.id
        Task {
            let locations = await LSPClient.shared.requestDefinition(atLine: line, col: col, inPath: path)
            await MainActor.run {
                let lsp = self.workspaceState.lsp
                guard var current = lsp.quickDocumentation, current.id == id else { return }
                current.phase = locations.first.flatMap { self.quickDefinitionTarget(for: $0) }.map { .definition($0) } ?? .unresolved
                lsp.quickDocumentation = current
            }
        }
    }

    private func quickDefinitionTarget(for location: LSPLocation) -> QuickDefinitionTarget? {
        let path = location.path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let open = openDocumentsTextMap().first { URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().path == resolved }?.value
        guard let text = open ?? (try? String(contentsOfFile: path, encoding: .utf8)),
              let snippet = DefinitionSnippet.extract(text: text, line: location.range.start.line) else { return nil }
        return QuickDefinitionTarget(path: path, line: location.range.start.line + 1, column: location.range.start.character + 1, snippet: snippet)
    }

    private func loadQuickDocumentation(_ request: QuickDocumentationRequest) {
        guard let index = request.symbolIndex else { return }
        let (line, col) = lineAndCol(forCharacterIndex: index)
        let path = filePath
        let id = request.id
        Task {
            let markdown = await LSPClient.shared.requestHover(atLine: line, col: col, inPath: path, kind: .quickDocumentation)
            await MainActor.run {
                let lsp = self.workspaceState.lsp
                guard var current = lsp.quickDocumentation, current.id == id else { return }
                if let markdown, !markdown.isEmpty {
                    let content = parseHoverText(markdown)
                    current.phase = content.signature != nil || !content.documentation.isEmpty ? .loaded(markdown) : .unresolved
                } else {
                    current.phase = .unresolved
                }
                lsp.quickDocumentation = current
            }
        }
    }

    private func quickDocumentationSymbol(near location: Int, in text: NSString) -> NSRange? {
        func isIdentifier(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        var index = location
        if !isIdentifier(index), isIdentifier(index - 1) { index -= 1 }
        guard isIdentifier(index) else { return nil }
        var start = index
        while isIdentifier(start - 1) { start -= 1 }
        var end = index + 1
        while isIdentifier(end) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        let word = text.substring(with: range)
        if Self.goKeywords.contains(word) || word.first?.isNumber == true { return nil }
        return range
    }

    private func quickDocumentationAnchor(for range: NSRange) -> CGRect {
        guard let window, let contentView = window.contentView else { return .zero }
        let windowRect = window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil))
        return CGRect(x: windowRect.minX, y: contentView.bounds.height - windowRect.maxY, width: max(16, windowRect.width), height: windowRect.height)
    }
}
