import AppKit
import GopilotCompletion
import GopilotPolicy

final class InlineSuggestionController {
    struct Suggestion {
        var anchor: Int
        var version: Int
        var text: String
        var lineRange: NSRange
        var lastFragmentStart: Int
        var trailingRange: NSRange?
        var layout: GhostTextLayout
    }

    private struct Request {
        let session: DocumentSession
        let version: Int
        let caret: Int
        let length: Int
        let snapshot: CompletionSnapshot
        let workspaceRoot: String?
        let secrets: [String]
        let preference: CompletionLengthPreference
        let endpoint: CompletionEndpoint
    }

    private enum Result {
        case skipped(CompletionSkipReason)
        case outcome(CompletionOutcome)
    }

    static let prefixWindow = 6_200
    static let suffixWindow = 2_100
    static let headWindow = 1_500
    static let announcementInterval: TimeInterval = 4

    private weak var textView: GoLensTextView?
    private(set) var suggestion: Suggestion?
    private var accepting = false
    private var lastEditVersion = -1
    private var editInProgress = false
    private var lastAnnouncement = Date.distantPast
    private var observer: NSObjectProtocol?

    init(textView: GoLensTextView) {
        self.textView = textView
        observer = NotificationCenter.default.addObserver(forName: .golensAISuggestionsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }

    var isVisible: Bool { suggestion != nil }

    var suggestionLine: Int? {
        guard let suggestion, let session = textView?.document, suggestion.version == session.version else { return nil }
        return session.lines.line(at: suggestion.anchor) + 1
    }

    func extraHeight(forLine line: Int) -> CGFloat {
        guard let suggestion, suggestionLine == line else { return 0 }
        return suggestion.layout.extraHeight
    }

    var debugState: String {
        guard let suggestion else { return "hidden" }
        let escaped = suggestion.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "visible|\(suggestion.anchor)|\(escaped)"
    }

    private func eligibleSession() -> DocumentSession? {
        guard let textView, let session = textView.document,
              AICompletionSettings.shared.isReady,
              session.syncsToCore, !session.isEffectiveLargeFileMode,
              CompletionContextBuilder.isSupported(path: session.path),
              textView.isEditable,
              textView.window?.firstResponder === textView,
              textView.selectedRanges.count == 1, !textView.hasMultipleCursors, textView.selectedRange().length == 0,
              !textView.hasMarkedText(),
              !CompletionController.shared.isVisible, !CompletionController.shared.hasActiveSnippet,
              textView.workspaceState.activePopup == nil,
              !session.undoManager.isUndoing, !session.undoManager.isRedoing else { return nil }
        return session
    }

    func textDidChange(inserted: String?, change: (old: NSRange, newLength: Int)?) {
        guard !accepting, let textView, let session = textView.document else { return }
        lastEditVersion = session.version
        if !editInProgress {
            editInProgress = true
            DispatchQueue.main.async { [weak self] in self?.editInProgress = false }
        }
        if session.undoManager.isUndoing || session.undoManager.isRedoing {
            dismiss()
            AISuggestionEngine.shared.scheduler.cancel()
            return
        }
        if let current = suggestion {
            if let inserted, !inserted.isEmpty, let change, change.old.length == 0, change.old.location == current.anchor {
                let typed = inserted as NSString
                let ghost = current.text as NSString
                let newAnchor = current.anchor + typed.length
                if ghost.hasPrefix(inserted), textView.selectedRange() == NSRange(location: newAnchor, length: 0) {
                    let remaining = ghost.substring(from: typed.length)
                    dismiss()
                    if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        show(remaining, at: newAnchor, announce: false)
                        return
                    }
                    scheduleRequest()
                    return
                }
            }
            dismiss()
        }
        scheduleRequest()
    }

    func caretMoved() {
        guard !accepting, !editInProgress, let textView, let session = textView.document, session.version == lastEditVersion || suggestion != nil else { return }
        if let current = suggestion {
            if current.version != session.version { return }
            if textView.selectedRange() == NSRange(location: current.anchor, length: 0) { return }
            dismiss()
        }
        AISuggestionEngine.shared.scheduler.cancel()
    }

    func handle(_ selector: Selector) -> Bool {
        guard suggestion != nil else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            accept()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            AISuggestionEngine.shared.scheduler.cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertBacktab(_:)):
            dismiss()
            AISuggestionEngine.shared.scheduler.cancel()
            return false
        default:
            return false
        }
    }

    func showNow() {
        guard suggestion == nil else { return }
        scheduleRequest(immediate: true)
    }

    func scheduleRequest(immediate: Bool = false) {
        let engine = AISuggestionEngine.shared
        guard eligibleSession() != nil, engine.activePause() == nil else {
            engine.scheduler.cancel()
            return
        }
        engine.scheduler.schedule(after: immediate ? 0 : engine.debounce) { [weak self] in
            let request: Request? = await MainActor.run { self?.makeRequest() }
            guard let request else { return }
            let result = await Self.perform(request)
            await MainActor.run { self?.deliver(result, for: request) }
        }
    }

    private func makeRequest() -> Request? {
        guard let textView, let session = eligibleSession(), let endpoint = AICompletionSettings.shared.endpoint() else { return nil }
        let caret = textView.selectedRange().location
        let ns = session.storage.mutableString
        let length = ns.length
        guard caret <= length else { return nil }
        let prefixStart = max(0, caret - Self.prefixWindow)
        let suffixEnd = min(length, caret + Self.suffixWindow)
        let prefix = ns.substring(with: NSRange(location: prefixStart, length: caret - prefixStart))
        let suffix = ns.substring(with: NSRange(location: caret, length: suffixEnd - caret))
        let head = prefixStart > 0 ? ns.substring(with: NSRange(location: 0, length: min(length, Self.headWindow))) : ""
        let root = textView.workspaceState.activeWorkspacePath
        let relative: String
        let workspaceRoot: String?
        if !root.isEmpty, session.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            relative = String(session.path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
            workspaceRoot = root
        } else {
            relative = (session.path as NSString).lastPathComponent
            workspaceRoot = (session.path as NSString).deletingLastPathComponent
        }
        let snapshot = CompletionSnapshot(
            relativePath: relative,
            prefix: prefix,
            suffix: suffix,
            prefixStartsAtFileStart: prefixStart == 0,
            suffixEndsAtFileEnd: suffixEnd == length,
            fileHead: head
        )
        return Request(
            session: session,
            version: session.version,
            caret: caret,
            length: length,
            snapshot: snapshot,
            workspaceRoot: workspaceRoot,
            secrets: AICompletionSettings.shared.provider.currentSecrets(),
            preference: AICompletionSettings.shared.length,
            endpoint: endpoint
        )
    }

    private static func perform(_ request: Request) async -> Result {
        let policy = request.workspaceRoot.map { PathPolicy(workspaceRoots: [URL(fileURLWithPath: $0)]) }
        let builder = CompletionContextBuilder(secretFilter: SecretFilter(literalSecrets: request.secrets), pathPolicy: policy, length: request.preference)
        switch builder.build(request.snapshot) {
        case .skip(let reason):
            return .skipped(reason)
        case .ready(let context):
            let started = CFAbsoluteTimeGetCurrent()
            let outcome = await AISuggestionEngine.shared.service.suggest(context: context, endpoint: request.endpoint)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            measureLog("ai suggestion \(String(String(describing: outcome).prefix(80))) \(elapsed) ms")
            return .outcome(outcome)
        }
    }

    private func deliver(_ result: Result, for request: Request) {
        guard case .outcome(let outcome) = result else { return }
        AISuggestionEngine.shared.record(outcome)
        guard case .suggestion(let text, _, _) = outcome,
              let textView, textView.document === request.session,
              suggestion == nil,
              let session = eligibleSession(),
              !CompletionController.shared.isRequestPending else { return }
        let caret = textView.selectedRange().location
        if session.version == request.version, caret == request.caret {
            show(text, at: caret, announce: true)
            return
        }
        let ns = session.storage.mutableString
        let typedLength = caret - request.caret
        guard typedLength > 0, ns.length == request.length + typedLength else { return }
        let typed = ns.substring(with: NSRange(location: request.caret, length: typedLength))
        let ghost = text as NSString
        guard ghost.length > typedLength, ghost.hasPrefix(typed) else { return }
        show(ghost.substring(from: typedLength), at: caret, announce: true)
    }

    private func show(_ rawText: String, at anchor: Int, announce: Bool) {
        guard let textView, let session = textView.document, let storage = textView.textStorage,
              let lm = textView.layoutManager, let container = textView.textContainer,
              anchor <= storage.length else { return }
        dismiss()
        let ns = storage.mutableString
        let lineRange = ns.lineRange(for: NSRange(location: anchor, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, contentEnd > anchor, [0x0A, 0x0D].contains(ns.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }
        let trailing = NSRange(location: anchor, length: max(0, contentEnd - anchor))
        let trailingText = ns.substring(with: trailing)
        let hasTrailing = !trailingText.trimmingCharacters(in: .whitespaces).isEmpty
        var text = rawText
        if hasTrailing, let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let font = textView.font ?? TechnicalTypography.codeCanvasNSFont(size: 13, weight: .regular)
        let linePrefix = storage.attributedSubstring(from: NSRange(location: lineRange.location, length: anchor - lineRange.location))
        let trailingAttributed = hasTrailing
            ? NSAttributedString(string: trailingText, attributes: [.font: font, .foregroundColor: textView.textColor ?? NSColor.textColor])
            : nil

        var realHeight: CGFloat = 0
        var lastFragmentStart = lineRange.location
        let lineGlyphs = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        if lineGlyphs.length > 0 {
            lm.enumerateLineFragments(forGlyphRange: lineGlyphs) { _, usedRect, _, glyphRange, _ in
                realHeight += usedRect.height
                lastFragmentStart = lm.characterIndexForGlyph(at: glyphRange.location)
            }
        } else {
            realHeight = lm.extraLineFragmentUsedRect.height
        }
        if realHeight <= 0 {
            realHeight = lm.defaultLineHeight(for: font)
        }

        let layout = GhostTextLayout(
            linePrefix: linePrefix,
            ghost: text,
            trailing: trailingAttributed,
            font: font,
            ghostColor: GoLensTextView.ghostTextColor,
            containerWidth: container.size.width,
            lineFragmentPadding: container.lineFragmentPadding,
            realLineHeight: realHeight
        )
        suggestion = Suggestion(
            anchor: anchor,
            version: session.version,
            text: text,
            lineRange: lineRange,
            lastFragmentStart: lastFragmentStart,
            trailingRange: hasTrailing ? trailing : nil,
            layout: layout
        )
        if layout.extraHeight > 0 {
            lm.invalidateLayout(forCharacterRange: lineRange, actualCharacterRange: nil)
            lm.ensureLayout(forCharacterRange: lineRange)
        }
        textView.setNeedsDisplay(textView.visibleRect)
        if announce { announceIfNeeded() }
    }

    func dismiss() {
        guard let current = suggestion else { return }
        suggestion = nil
        guard let textView else { return }
        if current.layout.extraHeight > 0, let lm = textView.layoutManager, let storage = textView.textStorage,
           NSMaxRange(current.lineRange) <= storage.length {
            lm.invalidateLayout(forCharacterRange: current.lineRange, actualCharacterRange: nil)
        }
        textView.setNeedsDisplay(textView.visibleRect)
    }

    func accept() {
        guard let current = suggestion, let textView, let session = textView.document,
              current.version == session.version,
              textView.selectedRange() == NSRange(location: current.anchor, length: 0) else {
            dismiss()
            return
        }
        dismiss()
        AISuggestionEngine.shared.scheduler.cancel()
        accepting = true
        defer { accepting = false }
        measureLog("ai suggestion accept undo grouping level \(session.undoManager.groupingLevel)")
        textView.workspaceState.applyRanges([(NSRange(location: current.anchor, length: 0), current.text)], in: session, actionName: "Accept Suggestion")
        let end = NSRange(location: min(current.anchor + (current.text as NSString).length, session.length), length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        lastEditVersion = session.version
        if NSWorkspace.shared.isVoiceOverEnabled {
            let lines = current.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            post(lines == 1 ? "Inserted 1 line" : "Inserted \(lines) lines", priority: .medium)
        }
    }

    func readSuggestion() {
        post(suggestion.map { "Suggestion: \($0.text)" } ?? "No suggestion", priority: .high)
    }

    private func announceIfNeeded() {
        guard NSWorkspace.shared.isVoiceOverEnabled, Date().timeIntervalSince(lastAnnouncement) > Self.announcementInterval else { return }
        lastAnnouncement = Date()
        post("Suggestion available", priority: .low)
    }

    private func post(_ message: String, priority: NSAccessibilityPriorityLevel) {
        guard let textView else { return }
        measureLog("ai suggestion announcement: \(message)")
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: priority.rawValue
        ])
    }

    func paragraphSpacing(afterGlyphAt glyphIndex: Int, layoutManager lm: NSLayoutManager) -> CGFloat {
        guard let current = suggestion, current.layout.extraHeight > 0, glyphIndex < lm.numberOfGlyphs else { return 0 }
        let character = lm.characterIndexForGlyph(at: glyphIndex)
        guard character >= current.lastFragmentStart, character < max(NSMaxRange(current.lineRange), current.lastFragmentStart + 1) else { return 0 }
        return current.layout.extraHeight
    }

    func draw(in dirtyRect: NSRect) {
        guard let current = suggestion, let textView, let session = textView.document, current.version == session.version,
              let lm = textView.layoutManager, let storage = textView.textStorage, current.anchor <= storage.length else { return }
        let origin = textView.textContainerOrigin
        let lineTop: CGFloat
        if current.lineRange.location < storage.length, lm.numberOfGlyphs > 0 {
            let glyph = lm.glyphIndexForCharacter(at: current.lineRange.location)
            lineTop = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil).minY
        } else {
            lineTop = lm.extraLineFragmentRect.minY
        }
        let drawOrigin = NSPoint(x: origin.x, y: lineTop + origin.y)
        if let trailing = current.trailingRange, NSMaxRange(trailing) <= storage.length, let container = textView.textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: trailing, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            textView.backgroundColor.setFill()
            rect.fill()
        }
        current.layout.draw(at: drawOrigin)
    }

    func accessibilityActions() -> [NSAccessibilityCustomAction] {
        guard suggestion != nil else { return [] }
        return [
            NSAccessibilityCustomAction(name: "Accept Suggestion") { [weak self] in
                self?.accept()
                return true
            },
            NSAccessibilityCustomAction(name: "Dismiss Suggestion") { [weak self] in
                self?.dismiss()
                return true
            }
        ]
    }
}
