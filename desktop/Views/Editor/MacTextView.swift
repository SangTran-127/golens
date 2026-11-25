import SwiftUI
import AppKit
import GoLensFoundation

struct MacTextView: NSViewRepresentable {
    var filePath: String
    var isLoaded: Bool
    var themeId: String
    var isDark: Bool
    @Binding var localTextView: GoLensTextView?
    var pendingJumpToLine: Int?
    var pendingJumpToCol: Int?
    var pendingJumpToRange: NSRange?
    var paneID: EditorPaneID = .primary
    var isSecondaryPane: Bool { paneID == .secondary }
    @Environment(WorkspaceSession.self) private var session: WorkspaceSession?
    @Environment(\.windowWorkspace) private var windowWorkspace

    nonisolated(unsafe) static var didMeasureFirstDraw = false

    func makeNSView(context: Context) -> NSScrollView {
        measureStartup("editor-view")
        let workspace = session?.workspace ?? windowWorkspace
        context.coordinator.hostWorkspace = workspace
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !workspace.wordWrapEnabled
        scrollView.drawsBackground = true

        let contentSize = scrollView.contentSize
        let textView = GoLensTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.filePath = filePath
        textView.paneID = paneID
        textView.hostWorkspace = workspace
        textView.minSize = NSSize(width: contentSize.width, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !workspace.wordWrapEnabled
        textView.autoresizingMask = workspace.wordWrapEnabled ? .width : [.width, .height]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.updateGutterWidth()
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator

        textView.font = TechnicalTypography.codeCanvasNSFont(size: workspace.editorFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        let theme = workspace.currentTheme
        let systemDark = theme.resolvedIsDark
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = highContrast
            ? (systemDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (systemDark ? .darkAqua : .aqua)
        scrollView.appearance = NSAppearance(named: appearanceName)
        textView.backgroundColor = theme.backgroundColor(isDark: systemDark)
        textView.insertionPointColor = theme.insertionPointColor(isDark: systemDark)
        scrollView.backgroundColor = theme.backgroundColor(isDark: systemDark)
        scrollView.documentView = textView
        workspace.applyWordWrap(to: textView)
        textView.setupScrollNotification()

        if paneID == .secondary {
            workspace.secondaryTextView = textView
        } else {
            workspace.primaryTextView = textView
            if workspace.activeTextView == nil || workspace.effectiveFocusedPaneID == .primary {
                workspace.activeTextView = textView
            }
        }
        DispatchQueue.main.async {
            self.localTextView = textView
        }
        context.coordinator.attach(workspace.documents[filePath], path: filePath, to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? GoLensTextView else { return }
        let workspace = session?.workspace ?? windowWorkspace
        context.coordinator.parent = self
        context.coordinator.hostWorkspace = workspace
        if textView.hostWorkspace !== workspace {
            textView.hostWorkspace = workspace
        }
        textView.paneID = paneID
        let activeTV = workspace.activeTextView as? GoLensTextView
        let activeTVIsVisible = activeTV.map { workspace.visibleDocumentPaths.contains($0.filePath) } ?? false
        if paneID == .secondary {
            workspace.secondaryTextView = textView
        } else {
            workspace.primaryTextView = textView
        }
        if workspace.activeTextView !== textView,
           textView.window?.firstResponder === textView || workspace.activeTextView == nil || (workspace.effectiveFocusedPaneID == paneID && !activeTVIsVisible) {
            workspace.activeTextView = textView
        }
        textView.layoutManager?.delegate = context.coordinator

        let session = isLoaded ? workspace.documents[filePath] : nil
        if textView.document !== session || textView.filePath != filePath {
            context.coordinator.attach(session, path: filePath, to: textView)
        }

        textView.isEditable = session != nil && workspace.editorMode(for: filePath) != .readOnly
        if textView.appliedWordWrapState != workspace.wordWrapEnabled {
            workspace.applyWordWrap(to: textView)
        }

        let theme = workspace.currentTheme
        let systemDark = theme.resolvedIsDark
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = highContrast
            ? (systemDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (systemDark ? .darkAqua : .aqua)
        if scrollView.appearance?.name != appearanceName {
            scrollView.appearance = NSAppearance(named: appearanceName)
        }
        context.coordinator.applyTypography(to: textView, theme: theme, isDark: systemDark)
        let bgColor = theme.backgroundColor(isDark: systemDark)
        if textView.backgroundColor != bgColor {
            textView.backgroundColor = bgColor
            scrollView.backgroundColor = bgColor
        }
        let caretColor = theme.insertionPointColor(isDark: systemDark)
        if textView.insertionPointColor != caretColor {
            textView.insertionPointColor = caretColor
        }

        let targetPane = workspace.paneState(for: paneID)
        var applyJump = isLoaded
        if pendingJumpToLine == nil && pendingJumpToRange == nil {
            context.coordinator.pendingJumpPath = nil
        } else if !isLoaded {
            context.coordinator.pendingJumpPath = filePath
        } else if let waitingFor = context.coordinator.pendingJumpPath, waitingFor != filePath {
            context.coordinator.pendingJumpPath = nil
            applyJump = false
            DispatchQueue.main.async {
                targetPane.pendingJumpToLine = nil
                targetPane.pendingJumpToCol = nil
                targetPane.pendingJumpToRange = nil
            }
        }

        if applyJump, let jumpLine = pendingJumpToLine, let jumpCol = pendingJumpToCol {
            DispatchQueue.main.async {
                targetPane.pendingJumpToLine = nil
                targetPane.pendingJumpToCol = nil
                if let targetIdx = textView.characterIndex(forLine: jumpLine, col: jumpCol) {
                    let targetRange = NSRange(location: targetIdx, length: 0)
                    textView.setSelectedRange(targetRange)
                    textView.scrollRangeToVisible(targetRange)
                    textView.highlightLine(jumpLine, in: textView)
                }
            }
        }

        if applyJump, let jumpRange = pendingJumpToRange {
            DispatchQueue.main.async {
                targetPane.pendingJumpToRange = nil
                guard NSMaxRange(jumpRange) <= (textView.textStorage?.length ?? 0) else { return }
                textView.setSelectedRange(jumpRange)
                textView.scrollRangeToVisible(jumpRange)
                let highlightColor = NSColor.controlAccentColor.withAlphaComponent(0.3)
                textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: jumpRange)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard NSMaxRange(jumpRange) <= (textView.textStorage?.length ?? 0) else { return }
                    textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: jumpRange)
                }
            }
        }

        if context.coordinator.lastHighlightedThemeId != workspace.selectedThemeId || context.coordinator.lastHighlightedIsDark != systemDark {
            context.coordinator.refreshAppearance(in: textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightWorkItem?.cancel()
        if let textView = scrollView.documentView as? GoLensTextView {
            if let lm = textView.layoutManager {
                lm.textStorage?.removeLayoutManager(lm)
            }
            textView.document = nil
            let workspace = textView.workspaceState
            if workspace.primaryTextView === textView {
                workspace.primaryTextView = nil
            }
            if workspace.secondaryTextView === textView {
                workspace.secondaryTextView = nil
            }
            if workspace.activeTextView === textView {
                workspace.activeTextView = workspace.primaryTextView
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MacTextView
        weak var hostWorkspace: WorkspaceState?
        var windowWorkspace: WorkspaceState { hostWorkspace ?? WorkspaceState.shared }
        var highlightWorkItem: DispatchWorkItem?
        private var semanticWorkItem: DispatchWorkItem?
        var pendingSemanticRange: NSRange?
        var lastHighlightedThemeId = ""
        var pendingJumpPath: String?
        var lastHighlightedIsDark = false
        var lastHighlightKey: (path: String, version: Int, theme: String, isDark: Bool, range: NSRange)?
        private var syntaxCache: (version: Int, range: NSRange, attributes: [(NSRange, NSColor)])?
        var highlightedBracketRanges: [NSRange] = []
        var foldIndex: (path: String, source: [NSRange], merged: [NSRange])?
        private var lastDiagnostics: [DiagnosticData]?
        var lastReplacement: String?
        var lastReplacementComposes = false
        var lastChange: (old: NSRange, newLength: Int)?
        var lastEditIsSingleLinePlain = false
        var lastEditAffectsFolding = false
        var lastLineCount = -1
        private let emptyStorage = NSTextStorage()
        private var semanticGeneration = 0
        private var semanticRetryCount = 0
        private static let maxSemanticRetries = 6
        static let maxDocumentHighlights = 200
        var documentHighlightRanges: [NSRange] = []
        var documentHighlightWorkItem: DispatchWorkItem?
        var signatureHelpWorkItem: DispatchWorkItem?
        var documentHighlightGeneration = 0

        init(_ parent: MacTextView) {
            self.parent = parent
            super.init()
            diagnosticsObserver = NotificationCenter.default.addObserver(forName: .golensDiagnosticsChanged, object: nil, queue: .main) { [weak self] note in
                guard let self, let textView = self.textView, textView.filePath == note.object as? String else { return }
                self.applyDiagnostics(self.windowWorkspace.diagnostics[textView.filePath] ?? [], to: textView)
            }
            languageServerReadyObserver = NotificationCenter.default.addObserver(forName: .golensLanguageServerReady, object: nil, queue: .main) { [weak self] _ in
                guard let self, let textView = self.textView else { return }
                self.refreshSemanticTokens(for: textView)
                textView.scheduleInlayHintUpdate()
                self.applyDiagnostics(self.windowWorkspace.diagnostics[textView.filePath] ?? [], to: textView)
            }
            injectedSQLObserver = NotificationCenter.default.addObserver(forName: .golensInjectedSQLChanged, object: nil, queue: .main) { [weak self] note in
                guard let self, let textView = self.textView, textView.filePath == note.object as? String,
                      let session = textView.document, let cache = self.syntaxCache, cache.version == session.version else { return }
                self.paint(textView, session: session, target: cache.range, syntax: cache.attributes)
            }
        }

        deinit {
            diagnosticsObserver.map(NotificationCenter.default.removeObserver)
            languageServerReadyObserver.map(NotificationCenter.default.removeObserver)
            injectedSQLObserver.map(NotificationCenter.default.removeObserver)
        }

        private var diagnosticsObserver: NSObjectProtocol?
        private var languageServerReadyObserver: NSObjectProtocol?
        private var injectedSQLObserver: NSObjectProtocol?

        private weak var textView: GoLensTextView?

        func attach(_ session: DocumentSession?, path: String, to textView: GoLensTextView) {
            measureStartupOnce(session == nil ? "document-attach-empty" : "document-attach-file")
            self.textView = textView
            if let previous = textView.document {
                previous.lastSelection = textView.selectedRange()
                previous.lastScrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
            }
            CompletionController.shared.dismiss()
            textView.inlineSuggestions.dismiss()
            textView.endIdentifierEdit()
            highlightWorkItem?.cancel()
            semanticWorkItem?.cancel()
            self.windowWorkspace.cancelFoldableUpdate()
            pendingSemanticRange = nil
            documentHighlightWorkItem?.cancel()
            clearDocumentHighlights(in: textView)
            textView.document = session
            textView.filePath = path
            highlightedBracketRanges.removeAll()
            lastHighlightKey = nil
            semanticRetryCount = 0
            syntaxCache = nil
            lastDiagnostics = nil
            lastLineCount = session?.lines.count ?? -1
            let storage = session?.storage ?? emptyStorage
            let selection: NSRange
            if let session, NSMaxRange(session.lastSelection) <= storage.length {
                selection = session.lastSelection
            } else {
                selection = NSRange(location: 0, length: 0)
            }
            if let lm = textView.layoutManager, lm.textStorage !== storage {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                lm.textStorage?.removeLayoutManager(lm)
                storage.addLayoutManager(lm)
            }
            textView.setSelectedRange(selection)
            textView.updateGutterWidth()
            if let lm = textView.layoutManager, storage.length > 0 {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
                lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: storage.length))
            }
            textView.breakUndoCoalescing()
            let theme = self.windowWorkspace.currentTheme
            let isDark = theme.resolvedIsDark
            applyTypography(to: textView, theme: theme, isDark: isDark)
            if let session {
                textView.enclosingScrollView?.contentView.scroll(to: session.lastScrollOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
                if self.windowWorkspace.foldableRanges[path] == nil {
                    self.windowWorkspace.updateFoldableRanges(for: path, session: session)
                }
                self.windowWorkspace.documentDidEdit(session)
                self.windowWorkspace.reloadCodeLens(forPath: path, textView: textView)
                self.windowWorkspace.scanMergeConflicts(path: path)
            }
            if self.windowWorkspace.showMinimap {
                textView.minimapDelegate?.documentDidChange()
            }
            textView.scheduleInlayHintUpdate()
            applyDiagnostics(self.windowWorkspace.diagnostics[path] ?? [], to: textView)
            textView.needsDisplay = true
            applyHighlighting(to: textView, immediateSemantic: true)
        }

        func applyTypography(to textView: GoLensTextView, theme: Theme, isDark: Bool) {
            let font = TechnicalTypography.codeCanvasNSFont(size: self.windowWorkspace.editorFontSize, weight: .regular)
            let color = theme.textColor(isDark: isDark)
            let session = textView.document
            if (session != nil && session?.appliedFont != font) || textView.font != font {
                textView.font = font
                session?.appliedFont = font
                textView.scheduleInlayHintLayout()
            }
            if (session != nil && session?.appliedTextColor != color) || textView.textColor != color {
                textView.textColor = color
                session?.appliedTextColor = color
            }
            let typing = textView.typingAttributes
            if typing[.font] as? NSFont != font || typing[.foregroundColor] as? NSColor != color {
                var updated = typing
                updated[.font] = font
                updated[.foregroundColor] = color
                textView.typingAttributes = updated
            }
        }

        func refreshAppearance(in textView: GoLensTextView) {
            let theme = self.windowWorkspace.currentTheme
            let isDark = theme.resolvedIsDark
            let bgColor = theme.backgroundColor(isDark: isDark)
            if textView.backgroundColor != bgColor {
                textView.backgroundColor = bgColor
                textView.enclosingScrollView?.backgroundColor = bgColor
            }
            let caretColor = theme.insertionPointColor(isDark: isDark)
            if textView.insertionPointColor != caretColor {
                textView.insertionPointColor = caretColor
            }
            applyTypography(to: textView, theme: theme, isDark: isDark)
            lastHighlightedThemeId = self.windowWorkspace.selectedThemeId
            lastHighlightedIsDark = isDark
            lastHighlightKey = nil
            syntaxCache = nil
            applyHighlighting(to: textView, immediateSemantic: true)
            if self.windowWorkspace.showMinimap {
                textView.minimapDelegate?.documentDidChange()
            }
            textView.needsDisplay = true
        }

        func restoreDiagnosticUnderlines(in textView: GoLensTextView) {
            lastDiagnostics = nil
            applyDiagnostics(self.windowWorkspace.diagnostics[textView.filePath] ?? [], to: textView)
        }

        func applyDiagnostics(_ diags: [DiagnosticData], to textView: GoLensTextView) {
            guard lastDiagnostics != diags, let session = textView.document, let lm = textView.layoutManager else { return }
            lastDiagnostics = diags
            let full = NSRange(location: 0, length: session.length)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            for diag in diags {
                guard let start = session.offset(line: diag.line, utf16Column: diag.col) else { continue }
                let end = session.offset(line: diag.endLine, utf16Column: diag.endCol) ?? start
                let length = min(max(1, end - start), session.length - start)
                guard length > 0 else { continue }
                let range = length > 1 ? NSRange(location: start, length: length) : Self.visibleRange(around: start, in: session.storage.mutableString)
                let color: NSColor = switch diag.severity {
                case 1: .systemRed
                case 2: .systemOrange
                default: .secondaryLabelColor
                }
                lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: color], forCharacterRange: range)
            }
        }

        static func visibleRange(around location: Int, in ns: NSString) -> NSRange {
            let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
            var lineEnd = NSMaxRange(line)
            while lineEnd > line.location, [0x0A, 0x0D].contains(ns.character(at: lineEnd - 1)) { lineEnd -= 1 }
            let isWord = { (c: unichar) in c == 0x5F || c >= 128 || (c < 128 && isalnum(Int32(c)) != 0) }
            let isSpace = { (c: unichar) in c == 0x20 || c == 0x09 }
            var end = min(location, lineEnd)
            if end < lineEnd { end += 1 }
            while end < lineEnd, isWord(ns.character(at: end)) { end += 1 }
            if end - location > 1 { return NSRange(location: location, length: end - location) }
            var stop = min(location, lineEnd)
            while stop > line.location, isSpace(ns.character(at: stop - 1)) { stop -= 1 }
            var start = stop
            while start > line.location, !isSpace(ns.character(at: start - 1)) { start -= 1 }
            if stop > start { return NSRange(location: start, length: stop - start) }
            return NSRange(location: line.location, length: max(1, lineEnd - line.location))
        }

        func scheduleHighlight(for textView: NSTextView, immediate: Bool = false) {
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView = textView as? GoLensTextView else { return }
                self.applyHighlighting(to: textView, immediateSemantic: immediate)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.12), execute: workItem)
        }

        func scheduleSemanticTokens(_ textView: GoLensTextView, session: DocumentSession, target: NSRange, theme: Theme, isDark: Bool, immediate: Bool) {
            semanticWorkItem?.cancel()
            if immediate {
                requestSemanticTokens(textView, session: session, target: target, theme: theme, isDark: isDark)
                return
            }
            let workItem = DispatchWorkItem { [weak self, weak textView, weak session] in
                guard let self, let textView, let session, textView.document === session else { return }
                let refreshTarget: NSRange
                if self.pendingSemanticRange != nil {
                    refreshTarget = self.targetRange(for: textView, length: session.length)
                    let syntax = session.highlighter.attributes(for: session.storage, isDark: isDark, theme: theme, in: refreshTarget)
                    self.syntaxCache = (session.version, refreshTarget, syntax)
                } else {
                    refreshTarget = target
                }
                self.requestSemanticTokens(textView, session: session, target: refreshTarget, theme: theme, isDark: isDark)
            }
            semanticWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func visibleViewportRange(for textView: NSTextView, length: Int) -> NSRange {
            guard let lm = textView.layoutManager, let tc = textView.textContainer, length > 0 else {
                return NSRange(location: 0, length: length)
            }
            let visibleRect = textView.visibleRect
            let glyphs = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
            let visible = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let pad = 512
            let start = max(0, visible.location - pad)
            let end = min(length, NSMaxRange(visible) + pad)
            return NSRange(location: start, length: end - start)
        }

        private func targetRange(for textView: NSTextView, length: Int) -> NSRange {
            guard let lm = textView.layoutManager, let tc = textView.textContainer, length > 0 else {
                return NSRange(location: 0, length: length)
            }
            let visibleRect = textView.visibleRect
            let glyphs = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
            let visible = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let pad = max(visible.length, 2000)
            let start = max(0, visible.location - pad)
            let end = min(length, NSMaxRange(visible) + pad)
            return NSRange(location: start, length: end - start)
        }

        func applyHighlighting(to textView: GoLensTextView, immediateSemantic: Bool = false) {
            guard let session = textView.document else { return }
            let theme = self.windowWorkspace.currentTheme
            let themeId = self.windowWorkspace.selectedThemeId
            let isDark = theme.resolvedIsDark
            let target = targetRange(for: textView, length: session.length)
            if let key = lastHighlightKey, key.path == session.path, key.version == session.version, key.theme == themeId, key.isDark == isDark,
               target.location >= key.range.location, NSMaxRange(target) <= NSMaxRange(key.range) {
                return
            }
            let hasPendingEdit = pendingSemanticRange != nil
            if immediateSemantic {
                pendingSemanticRange = nil
            }
            lastHighlightKey = (session.path, session.version, themeId, isDark, target)
            lastHighlightedThemeId = themeId
            lastHighlightedIsDark = isDark
            let started = CFAbsoluteTimeGetCurrent()
            let syntax = session.highlighter.attributes(for: session.storage, isDark: isDark, theme: theme, in: target)
            syntaxCache = (session.version, target, syntax)
            paint(textView, session: session, target: target, syntax: syntax)
            measureLog(String(format: "highlight %.2f ms range=%d", (CFAbsoluteTimeGetCurrent() - started) * 1000, target.length))
            if !MacTextView.didMeasureFirstDraw {
                MacTextView.didMeasureFirstDraw = true
                measureStartup("first-draw")
                MainActor.assumeIsolated { AppEnvironment.shared.firstWindowDrawn() }
            }
            scheduleSemanticTokens(textView, session: session, target: target, theme: theme, isDark: isDark, immediate: immediateSemantic || hasPendingEdit)
        }

        func paint(_ textView: GoLensTextView, session: DocumentSession, target: NSRange, syntax: [(NSRange, NSColor)]) {
            guard let lm = textView.layoutManager, NSMaxRange(target) <= session.length else { return }
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: target)
            for (range, color) in syntax where NSIntersectionRange(range, target).length > 0 && NSMaxRange(range) <= session.length {
                lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            }
            let highlights = session.semanticHighlights
            for i in session.semanticHighlightWindow(intersecting: target) {
                let (range, color) = highlights[i]
                guard NSIntersectionRange(range, target).length > 0 && NSMaxRange(range) <= session.length else { continue }
                lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            }
            if !session.highlighter.injectedSQL.isEmpty {
                let theme = windowWorkspace.currentTheme
                for (range, color) in session.highlighter.injectedSQLAttributes(in: session.storage.mutableString, theme: theme, isDark: theme.resolvedIsDark, target: target)
                where NSMaxRange(range) <= session.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                }
            }
            lm.invalidateDisplay(forCharacterRange: target)
        }

        func refreshSemanticTokens(for textView: GoLensTextView) {
            guard let session = textView.document else { return }
            semanticRetryCount = 0
            let theme = self.windowWorkspace.currentTheme
            let target = targetRange(for: textView, length: session.length)
            scheduleSemanticTokens(textView, session: session, target: target, theme: theme, isDark: theme.resolvedIsDark, immediate: true)
        }

        private func scheduleSemanticRetry(_ textView: GoLensTextView, session: DocumentSession, target: NSRange, theme: Theme, isDark: Bool, version: Int) {
            guard semanticRetryCount < Self.maxSemanticRetries else { return }
            let delay = min(0.5 * pow(2, Double(semanticRetryCount)), 8)
            semanticRetryCount += 1
            semanticWorkItem?.cancel()
            let retry = DispatchWorkItem { [weak self, weak textView, weak session] in
                guard let self, let textView, let session,
                      textView.document === session, session.version == version else { return }
                self.requestSemanticTokens(textView, session: session, target: target, theme: theme, isDark: isDark)
            }
            semanticWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        }

        private func requestSemanticTokens(_ textView: GoLensTextView, session: DocumentSession, target: NSRange, theme: Theme, isDark: Bool) {
            guard !session.isEffectiveLargeFileMode,
                  session.syncsToCore, session.path.hasSuffix(".go"), textView.window != nil, !textView.isHiddenOrHasHiddenAncestor,
                  textView.document === session, self.windowWorkspace.visibleDocumentPaths.contains(session.path) else { return }
            let requestTarget: NSRange
            let followUpTarget: NSRange?
            if pendingSemanticRange != nil {
                pendingSemanticRange = nil
                let viewport = visibleViewportRange(for: textView, length: session.length)
                requestTarget = viewport
                if target.location < viewport.location || NSMaxRange(target) > NSMaxRange(viewport) {
                    followUpTarget = target
                } else {
                    followUpTarget = nil
                }
            } else {
                requestTarget = target
                followUpTarget = nil
            }
            let path = session.path
            let version = session.version
            let startByte = session.utf8.byteOffset(requestTarget.location)
            let endByte = session.utf8.byteOffset(NSMaxRange(requestTarget))
            semanticGeneration += 1
            let generation = semanticGeneration
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak textView] in
                var count: Int32 = 0
                let buffer = path.withCString { GetSemanticTokens($0, Int32(startByte), Int32(endByte), &count) }
                let triples: [Int32]
                let available = buffer != nil
                if let buffer {
                    triples = Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
                    FreeGoBuffer(buffer)
                } else {
                    triples = []
                }
                DispatchQueue.main.async {
                    guard let self, let textView, generation == self.semanticGeneration,
                          textView.document === session, session.version == version else { return }
                    guard available else {
                        self.scheduleSemanticRetry(textView, session: session, target: followUpTarget ?? requestTarget, theme: theme, isDark: isDark, version: version)
                        return
                    }
                    self.semanticRetryCount = 0
                    if !triples.isEmpty {
                        var fresh: [(NSRange, NSColor)] = []
                        fresh.reserveCapacity(triples.count / 3)
                        var i = 0
                        while i + 2 < triples.count {
                            let startByte = Int(triples[i]), length = Int(triples[i + 1])
                            if let color = Self.colorForSemanticTokenType(Int(triples[i + 2]), theme: theme, isDark: isDark) {
                                let start = session.utf8.utf16Offset(byte: startByte)
                                let end = session.utf8.utf16Offset(byte: startByte + length)
                                if end > start { fresh.append((NSRange(location: start, length: end - start), color)) }
                            }
                            i += 3
                        }
                        measureLog("semantic-tokens \(fresh.count) bytes=\(startByte)..<\(endByte) of \(session.utf8.byteLength)")
                        session.replaceSemanticHighlights(in: requestTarget, with: fresh)
                        if let cache = self.syntaxCache, cache.version == version {
                            self.paint(textView, session: session, target: cache.range, syntax: cache.attributes)
                        } else {
                            let syntax = session.highlighter.attributes(for: session.storage, isDark: isDark, theme: theme, in: requestTarget)
                            self.paint(textView, session: session, target: requestTarget, syntax: syntax)
                        }
                        if self.windowWorkspace.showMinimap {
                            textView.minimapDelegate?.documentDidChange()
                        }
                    }
                    if let followUpTarget {
                        self.semanticWorkItem?.cancel()
                        let followUp = DispatchWorkItem { [weak self, weak textView, weak session] in
                            guard let self, let textView, let session,
                                  textView.document === session, session.version == version else { return }
                            self.requestSemanticTokens(textView, session: session, target: followUpTarget, theme: theme, isDark: isDark)
                        }
                        self.semanticWorkItem = followUp
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: followUp)
                    }
                }
            }
        }

        static func colorForSemanticTokenType(_ typeIdx: Int, theme: Theme, isDark: Bool) -> NSColor? {
            switch typeIdx {
            case 0: return theme.namespaceColor(isDark: isDark)
            case 1, 2: return theme.typeColor(isDark: isDark)
            case 3: return theme.parameterColor(isDark: isDark)
            case 4: return theme.propertyColor(isDark: isDark)
            case 5: return theme.variableColor(isDark: isDark)
            case 6, 7, 8: return theme.functionColor(isDark: isDark)
            case 9: return theme.keywordColor(isDark: isDark)
            case 10: return theme.commentColor(isDark: isDark)
            case 11: return theme.stringColor(isDark: isDark)
            case 12: return theme.numberColor(isDark: isDark)
            default: return nil
            }
        }

    }
}
