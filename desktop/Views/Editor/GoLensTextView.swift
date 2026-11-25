import SwiftUI
import AppKit
import GoLensFoundation

class GoLensTextView: NSTextView {
    @objc var filePath: String = ""
    var paneID: EditorPaneID = .primary
    weak var document: DocumentSession?
    weak var hostWorkspace: WorkspaceState?
    var workspaceState: WorkspaceState { hostWorkspace ?? WorkspaceState.owning(window: window) }
    weak var minimapDelegate: MinimapSyncDelegate?
    let multiCursor = MultiCursorState()
    private(set) var gutterWidth: CGFloat = 56
    let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let foldColumnWidth: CGFloat = 16
    static let minGutterWidth: CGFloat = 56
    static let opticalMarginExpandedThreshold: CGFloat = WorkspaceColumnLayoutMath.forcedColumnMinEditorWidth
    static let opticalMarginExpandedWidth: CGFloat = WorkspaceColumnLayoutMath.opticalLensExpandedWidth
    static let opticalMarginCompactWidth: CGFloat = 36
    private lazy var digitWidth = ("0" as NSString).size(withAttributes: [.font: lineNumberFont]).width
    private var screenChangeObserver: NSObjectProtocol?
    private var lastResolvedMarginWidth: CGFloat = -1

    var currentScreenWidth: CGFloat {
        window?.screen?.frame.width ?? NSScreen.main?.frame.width ?? 0
    }

    func resolvedOpticalLensStyle(forViewportWidth viewportWidth: CGFloat) -> EffectiveOpticalLensStyle {
        WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
            mode: WorkspaceState.currentOpticalLensDisplayMode,
            viewportWidth: viewportWidth,
            screenWidth: currentScreenWidth
        )
    }

    var effectiveOpticalLensStyle: EffectiveOpticalLensStyle {
        resolvedOpticalLensStyle(forViewportWidth: visibleRect.width)
    }

    var opticalMarginWidth: CGFloat {
        effectiveOpticalLensStyle.reservedMarginWidth
    }

    static func computeGutterWidth(lineCount: Int, digitWidth: CGFloat) -> CGFloat {
        let digits = CGFloat(max(3, String(max(1, lineCount)).count))
        return max(minGutterWidth, ceil((foldColumnWidth + digits * digitWidth + 26) / 8) * 8)
    }

    func updateGutterWidth() {
        let width = Self.computeGutterWidth(lineCount: document?.lines.count ?? 1, digitWidth: digitWidth)
        let targetPadding = width + 6
        guard width != gutterWidth || textContainer?.lineFragmentPadding != targetPadding else { return }
        gutterWidth = width
        textContainer?.lineFragmentPadding = targetPadding
        needsDisplay = true
    }
    
    static let cachedDebugLineColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3)
    static let cachedInlineAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.tertiaryLabelColor,
        .font: TechnicalTypography.codeCanvasNSFont(size: 11, weight: .regular)
    ]

    static let cachedPlayButton = NSImage(size: NSSize(width: 8, height: 10), flipped: false) { _ in
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 8, y: 5))
        path.line(to: NSPoint(x: 0, y: 10))
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
        return true
    }

    static func testSymbol(_ name: String, _ colors: [NSColor]) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
    static let cachedModuleWarning: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?.withSymbolConfiguration(config)
    }()
    static let cachedTestPassed = testSymbol("checkmark.circle.fill", [.white, .systemGreen])
    static let cachedTestFailed = testSymbol("xmark.circle.fill", [.white, .systemRed])
    static let cachedTestSkipped = testSymbol("minus.circle", [.secondaryLabelColor])
    static let cachedTestRunning = testSymbol("circle.dotted", [.secondaryLabelColor])
    static let cachedBookmarkSymbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
        return NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")?.withSymbolConfiguration(config)
    }()
    static let cachedDebugPCSymbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
        return NSImage(systemSymbolName: "arrowtriangle.right.fill", accessibilityDescription: "Program Counter")?.withSymbolConfiguration(config)
    }()

    let opticalLensMargin = OpticalLensMarginView()
    var compactLensHitRects: [Int: (NSRect, OpticalLensLineItem)] = [:]
    var appliedWordWrapState: Bool?
    var lastHighlightedCaretLine: Int = -1
    var lastHadSelection: Bool = false
    private var lastScrollOriginX: CGFloat = 0
    private var lastVisibleWidth: CGFloat = 0

    func applyWordWrapLayout(_ wrap: Bool) {
        appliedWordWrapState = wrap
        let scrollView = enclosingScrollView
        let viewportWidth = max(100, scrollView?.contentSize.width ?? bounds.width)
        minSize = NSSize(width: viewportWidth, height: minSize.height)
        if wrap {
            scrollView?.hasHorizontalScroller = false
            isHorizontallyResizable = false
            autoresizingMask = .width
            let reserved = resolvedOpticalLensStyle(forViewportWidth: viewportWidth).reservedMarginWidth
            let containerWidth = max(80, viewportWidth - reserved)
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            if frame.width != viewportWidth {
                super.setFrameSize(NSSize(width: viewportWidth, height: frame.height))
            }
        } else {
            scrollView?.hasHorizontalScroller = true
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if frame.width < viewportWidth {
                super.setFrameSize(NSSize(width: viewportWidth, height: frame.height))
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    func invalidateLineBand(_ line1: Int) {
        guard line1 >= 1, let lm = layoutManager, let tc = textContainer, let range = document?.lineRange(line1 - 1) else {
            setNeedsDisplay(visibleRect)
            return
        }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.location < lm.numberOfGlyphs else { return }
        let box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let vis = visibleRect
        setNeedsDisplay(NSRect(x: vis.minX, y: box.minY + textContainerOrigin.y - 2, width: vis.width, height: max(box.height, 16) + 4))
    }

    var identifierEdit: IdentifierEdit?
    var renameSuggestion: RenameSuggestion?
    var renameSuggestionWork: DispatchWorkItem?
    var renameHitRect: NSRect?
    var blameHit: (rect: NSRect, line: Int)?
    var tableLink: (path: String, range: NSRange)?
    var tableLinkRequest: NSRange?
    var lastEditEnd = -1
    var suppressIdentifierTracking = false
    var inlineRename: InlineRenameSession?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if inlineRename != nil { return inlineRenameShouldChange(affectedCharRange, replacement: replacementString ?? "") }
        if !multiCursor.applying { endMultiCursor() }
        if let replacementString {
            trackIdentifierEdit(in: affectedCharRange, replacement: replacementString)
        }
        if self.workspaceState.issuePopup != nil { self.workspaceState.issuePopup = nil }
        return true
    }

    func redrawGutter() {
        setNeedsDisplay(visibleRect)
    }

    func testTarget(atLine line: Int) -> TestTarget? {
        self.workspaceState.fileTestLines[filePath]?[line]
    }

    func isPointInGutter(_ point: NSPoint) -> Bool {
        let relX = point.x - visibleRect.origin.x
        return relX >= 0 && relX < gutterWidth
    }

    func isPointInOpticalMargin(_ point: NSPoint) -> Bool {
        let mw = opticalMarginWidth
        return mw > 0 && point.x >= visibleRect.maxX - mw && point.x <= visibleRect.maxX
    }

    func isTestMarkHit(_ point: NSPoint, line: Int) -> Bool {
        let relX = point.x - visibleRect.origin.x
        return relX >= Self.foldColumnWidth + 4 && relX < gutterWidth - 4 && testTarget(atLine: line) != nil && self.workspaceState.debug.breakpoints[filePath]?.contains(line) != true
    }

    func isGoGenerateMarkHit(_ point: NSPoint, line: Int) -> Bool {
        let relX = point.x - visibleRect.origin.x
        return relX >= Self.foldColumnWidth + 4 &&
            relX < gutterWidth - 4 &&
            testTarget(atLine: line) == nil &&
            self.workspaceState.debug.breakpoints[filePath]?.contains(line) != true &&
            self.workspaceState.goplsLenses[filePath]?[line]?.contains(where: { ($0.command["golensCommand"] as? String) == "goGenerate" }) == true
    }

    static func breakpointTag(in rect: NSRect, logpoint: Bool) -> NSBezierPath {
        let tip: CGFloat = 5
        let radius: CGFloat = 3
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - tip, y: rect.maxY))
        if logpoint {
            path.line(to: NSPoint(x: rect.minX + tip, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + tip, y: rect.minY))
        } else {
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.minY), radius: radius)
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.maxX - tip, y: rect.minY), radius: radius)
        }
        path.line(to: NSPoint(x: rect.maxX - tip, y: rect.minY))
        path.close()
        return path
    }

    static let lensTextColor = NSColor(name: "GoLensLensText") { appearance in
        var color = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            if let secondary = NSColor.secondaryLabelColor.usingColorSpace(.sRGB),
               let label = NSColor.labelColor.usingColorSpace(.sRGB),
               let mixed = secondary.blended(withFraction: 0.25, of: label) {
                color = mixed
            }
        }
        return color
    }

    static let cachedChevronDown: NSImage = {
        let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()
    static let cachedChevronRight: NSImage = {
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard !invalidRect.isEmpty else { return }
        if invalidRect.width <= 4 {
            super.setNeedsDisplay(invalidRect)
            return
        }
        let vis = visibleRect
        let minX = min(invalidRect.minX, vis.minX)
        let maxX = max(invalidRect.maxX, max(vis.maxX, gutterWidth))
        let rect = NSRect(x: minX, y: invalidRect.minY, width: max(0, maxX - minX), height: invalidRect.height)
        super.setNeedsDisplay(rect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        (delegate as? MacTextView.Coordinator)?.refreshAppearance(in: self)
    }

    var hoverTimer: Timer?
    var hoverDismissTimer: Timer?
    var hoverRequestID: Int = 0
    var quickDocumentationCaret: Int? { quickDocumentationRequest?.caret }
    var lastScrollTime: CFAbsoluteTime = 0
    var trackingArea: NSTrackingArea?
    var inlayHintManager: InlayHintManager?
    lazy var inlineSuggestions = InlineSuggestionController(textView: self)

    @objc var inlineSuggestionDebugState: String { inlineSuggestions.debugState }
    @objc var issueHitRectsDebug: [NSValue] { issueHitRects.values.map { NSValue(rect: $0.0) } }
    var lensHitRects: [Int: [(NSRect, CodeLensItem)]] = [:]
    var conflictActionHitRects: [Int: [(NSRect, MergeConflictLensAction)]] = [:]
    var conflictToolTipRects: [NSRect] = []
    var conflictToolTipRefreshPending = false
    var issueHitRects: [Int: (NSRect, [DiagnosticData])] = [:]
    var issueCache: (source: [DiagnosticData], byLine: [Int: [DiagnosticData]])?
    var issueInputs: (path: String, diags: [DiagnosticData], safety: [SafetyFinding], failures: [TestFailureAnnotation], showSafety: Bool)?
    var implHitRects: [Int: (NSRect, [LSPLocation])] = [:]
    var usageHitRects: [Int: NSRect] = [:]

    func compactLensItem(at point: NSPoint) -> (line: Int, rect: NSRect, item: OpticalLensLineItem)? {
        compactLensHitRects.first { $0.value.0.insetBy(dx: -2, dy: -2).contains(point) }.map { ($0.key, $0.value.0, $0.value.1) }
    }

    func implementations(at point: NSPoint) -> [LSPLocation]? {
        implHitRects.values.first { $0.0.contains(point) }?.1
    }

    func usageLine(at point: NSPoint) -> Int? {
        usageHitRects.first { $0.value.insetBy(dx: -2, dy: -2).contains(point) }?.key
    }

    func lens(at point: NSPoint) -> CodeLensItem? {
        for rects in lensHitRects.values {
            if let hit = rects.first(where: { $0.0.insetBy(dx: -2, dy: -2).contains(point) }) { return hit.1 }
        }
        return nil
    }

    func lensRect(forLine line: Int, golensCommand: String) -> NSRect? {
        lensHitRects[line]?.first(where: { ($0.1.command["golensCommand"] as? String) == golensCommand })?.0
    }

    func setupInlayHintManager() {
        guard inlayHintManager == nil else { return }
        inlayHintManager = InlayHintManager(textView: self)
    }

    func scheduleInlayHintUpdate() {
        inlayHintManager?.scheduleUpdate()
    }

    func hasIgnoredErrorHint(line0: Int) -> Bool {
        inlayHintManager?.ignoredErrorLines().contains(line0) == true
    }

    func scheduleInlayHintLayout() {
        inlayHintManager?.scheduleLayout()
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        NotificationCenter.default.removeObserver(self)
        if let area = trackingArea {
            self.removeTrackingArea(area)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if let window {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshOpticalLensLayout()
            }
        }
        refreshOpticalLensLayout()
    }

    func setupScrollNotification() {
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.removeObserver(self, name: .mergeConflictRegionsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mergeConflictRegionsDidChange(_:)), name: .mergeConflictRegionsDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .golensInlayHintsToggled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inlayHintsToggled(_:)), name: .golensInlayHintsToggled, object: nil)
        NotificationCenter.default.removeObserver(self, name: .golensOpticalLensModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(opticalLensModeChanged(_:)), name: .golensOpticalLensModeChanged, object: nil)
        setupInlayHintManager()
    }

    @objc private func inlayHintsToggled(_ note: Notification) {
        scheduleInlayHintUpdate()
    }

    @objc private func opticalLensModeChanged(_ note: Notification) {
        refreshOpticalLensLayout()
    }

    func refreshOpticalLensLayout() {
        let wrap = appliedWordWrapState ?? self.workspaceState.wordWrapEnabled
        lastResolvedMarginWidth = opticalMarginWidth
        applyWordWrapLayout(wrap)
        setFrameSize(frame.size)
        super.setNeedsDisplay(visibleRect)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard self.workspaceState.activePopup == nil else { return }
        let insertString: String
        if let str = string as? String {
            insertString = str
        } else if let attrStr = string as? NSAttributedString {
            insertString = attrStr.string
        } else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if hasMultipleCursors {
            if hasMarkedText() {
                multiCursorCommitMarkedText { super.insertText(string, replacementRange: replacementRange) }
            } else {
                multiCursorInsert(insertString)
            }
            return
        }
        
        let selectedRange = self.selectedRange()
        
        if selectedRange.length > 0 {
            if let closingChar = closingCharacter(for: insertString), !CompletionController.shared.isEditingPlaceholder(selectedRange, in: self) {
                let nsString = liveText
                let selectedText = nsString.substring(with: selectedRange)
                let wrappedText = insertString + selectedText + closingChar
                
                if self.shouldChangeText(in: selectedRange, replacementString: wrappedText) {
                    self.textStorage?.replaceCharacters(in: selectedRange, with: wrappedText)
                    self.didChangeText()
                    self.setSelectedRange(NSRange(location: selectedRange.location + 1, length: selectedRange.length))
                }
                return
            }
        } else {
            let cursorLoc = selectedRange.location
            let nsString = liveText
            
            if isClosingCharacter(insertString) {
                if insertString == ")" {
                    self.workspaceState.lsp.signatureHelp = nil
                }
                
                if cursorLoc < nsString.length {
                    let nextChar = nsString.substring(with: NSRange(location: cursorLoc, length: 1))
                    if nextChar == insertString {
                        self.setSelectedRange(NSRange(location: cursorLoc + 1, length: 0))
                        return
                    }
                }
            }
            
            if let closingChar = closingCharacter(for: insertString) {
                var shouldAutoClose = !inCommentOrString(at: cursorLoc, in: nsString)
                if insertString == "\"" || insertString == "'" || insertString == "`" {
                    for i in [cursorLoc - 1, cursorLoc] where i >= 0 && i < nsString.length {
                        if let scalar = UnicodeScalar(nsString.character(at: i)), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                            shouldAutoClose = false
                        }
                    }
                }
                
                if shouldAutoClose {
                    let pairText = insertString + closingChar
                    if self.shouldChangeText(in: selectedRange, replacementString: pairText) {
                        self.textStorage?.replaceCharacters(in: selectedRange, with: pairText)
                        self.didChangeText()
                        self.setSelectedRange(NSRange(location: cursorLoc + 1, length: 0))
                        
                        if insertString == "(" {
                            self.workspaceState.fetchSignatureHelp(for: self)
                        }
                    }
                    return
                }
            }
        }
        
        super.insertText(string, replacementRange: replacementRange)
        if insertString == ":" || insertString == "}" {
            outdentLabelOrBrace()
        }

        if let insertString = string as? String, (insertString == "(" || insertString == ",") {
            self.workspaceState.fetchSignatureHelp(for: self)
        }
    }
    
    private func outdentLabelOrBrace() {
        guard filePath.hasSuffix(".go"), let storage = textStorage else { return }
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let text = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isLabel = trimmed.hasSuffix(":") && (trimmed.hasPrefix("case ") || trimmed == "default:")
        guard isLabel || trimmed == "}", !inCommentOrString(at: caret - 1, in: ns),
              let open = enclosingOpenBrace(before: line.location, in: ns) else { return }
        let openLine = ns.substring(with: ns.lineRange(for: NSRange(location: open, length: 0)))
        let target = String(openLine.prefix { $0 == "\t" || $0 == " " })
        let current = String(text.prefix { $0 == "\t" || $0 == " " })
        guard target != current else { return }
        let range = NSRange(location: line.location, length: (current as NSString).length)
        guard shouldChangeText(in: range, replacementString: target) else { return }
        storage.replaceCharacters(in: range, with: target)
        didChangeText()
        setSelectedRange(NSRange(location: caret - range.length + (target as NSString).length, length: 0))
    }

    private func enclosingOpenBrace(before location: Int, in ns: NSString) -> Int? {
        var depth = 0
        var i = location - 1
        let floor = max(0, location - 20_000)
        while i >= floor {
            let c = ns.character(at: i)
            if (c == 0x7D || c == 0x7B), !inCommentOrString(at: i, in: ns) {
                if c == 0x7D { depth += 1 } else if depth == 0 { return i } else { depth -= 1 }
            }
            i -= 1
        }
        return nil
    }

    func inCommentOrString(at location: Int, in ns: NSString) -> Bool {
        guard filePath.hasSuffix(".go") else { return false }
        return document?.highlighter.inCommentOrString(at: location, in: ns) ?? CompletionController.inCommentOrString(ns, caret: location)
    }

    private func closingCharacter(for char: String) -> String? {
        switch char {
        case "(": return ")"
        case "{": return "}"
        case "[": return "]"
        case "\"": return "\""
        case "'": return "'"
        case "`": return "`"
        default: return nil
        }
    }
    
    private func isClosingCharacter(_ char: String) -> Bool {
        return char == ")" || char == "}" || char == "]" || char == "\"" || char == "'" || char == "`"
    }
    
    @objc private func scrollViewDidScroll(_ notification: Notification) {
        if let height = deferredHeight, visibleRect.maxY >= min(height, frame.height) - wobbleSlack {
            deferredHeight = nil
            super.setFrameSize(NSSize(width: frame.width, height: height))
        }
        let vis = visibleRect
        let currentMargin = opticalMarginWidth
        let marginChanged = abs(currentMargin - lastResolvedMarginWidth) > 0.5
        if marginChanged {
            lastResolvedMarginWidth = currentMargin
            setFrameSize(frame.size)
        }
        if marginChanged || abs(vis.origin.x - lastScrollOriginX) > 0.1 || abs(vis.width - lastVisibleWidth) > 0.1 {
            lastScrollOriginX = vis.origin.x
            lastVisibleWidth = vis.width
            super.setNeedsDisplay(vis)
        }
        lastScrollTime = CFAbsoluteTimeGetCurrent()
        self.workspaceState.dismissTransientEditorOverlays(includeRename: false, includePopovers: true)
        refreshInlineRenameHint()
        dismissHoverImmediate()
        scheduleInlayHintLayout()
        (delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        lastScrollTime = CFAbsoluteTimeGetCurrent()
        self.workspaceState.dismissTransientEditorOverlays(includeRename: false, includePopovers: true)
        refreshInlineRenameHint()
        dismissHoverImmediate()
        super.scrollWheel(with: event)
    }


    var deferredHeight: CGFloat?
    var wobbleSlack: CGFloat { (layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) ?? 16) * 3 }
}
