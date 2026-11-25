import AppKit

extension NSAttributedString.Key {
    static let golensInlayHint = NSAttributedString.Key("GoLensInlayHint")
}

final class InlayHintManager {
    private weak var textView: GoLensTextView?
    private var currentHints: [InlayHint] = []
    private var hintsByLine0: [Int: [InlayHint]] = [:]
    private var fetchTask: Task<Void, Never>?
    private var debounceWorkItem: DispatchWorkItem?
    private var layoutWorkItem: DispatchWorkItem?
    private var appliedVersion: Int?
    private var failedFetches = 0
    private var fetchedLines: ClosedRange<Int>?
    private var fetchedVersion: Int?

    private static let maxVisibleHints = 100
    private static let maxHintsPerLine = 3
    private static let maxFetchRetries = 3
    private static let retryDelay: TimeInterval = 2
    private static let updateDelay: TimeInterval = 0.35
    private static let layoutDelay: TimeInterval = 0.03
    private static let pillPadding: CGFloat = 3
    private static let pillGap: CGFloat = 2

    init(textView: GoLensTextView) {
        self.textView = textView
    }

    func ignoredErrorLines() -> Set<Int> {
        Set(currentHints.filter { $0.label.contains("ignore error") }.map { $0.position.line })
    }

    func scheduleUpdate() {
        debounceWorkItem?.cancel()
        guard isEnabled(),
              let textView = textView,
              textView.filePath.hasSuffix(".go"),
              let session = textView.document,
              session.syncsToCore,
              !session.isEffectiveLargeFileMode,
              session.length > 0 else {
            removeAllHints()
            return
        }
        if let applied = appliedVersion, applied != session.version, let edit = session.lastEdit {
            appliedVersion = session.version
            let edited = NSRange(location: edit.old.location, length: edit.newLength)
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let storage = textView?.textStorage, NSMaxRange(edited) <= storage.length else { return }
                self.clearInlineHints(in: storage, range: edited)
            }
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.fetchHints()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.updateDelay, execute: workItem)
    }

    func scheduleLayout() {
        guard isEnabled() else {
            removeAllHints()
            return
        }
        if visibleLines() != fetchedLines || textView?.document?.version != fetchedVersion {
            scheduleUpdate()
        }
        guard !currentHints.isEmpty else { return }
        layoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.renderHints()
        }
        layoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutDelay, execute: workItem)
    }

    func removeAllHints() {
        debounceWorkItem?.cancel()
        layoutWorkItem?.cancel()
        fetchTask?.cancel()
        let hadHints = !currentHints.isEmpty
        currentHints.removeAll()
        hintsByLine0.removeAll()
        fetchedLines = nil
        fetchedVersion = nil
        if let storage = textView?.textStorage {
            clearInlineHints(in: storage, range: NSRange(location: 0, length: storage.length))
        }
        if hadHints, let textView = textView {
            textView.setNeedsDisplay(textView.visibleRect)
        }
    }

    func drawInlineHints(in rect: NSRect) {
        guard isEnabled(), let textView, let storage = textView.textStorage,
              let lm = textView.layoutManager, let container = textView.textContainer, storage.length > 0 else { return }
        let origin = textView.textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0 else { return }
        let attrs = Self.labelAttributes(for: textView)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath.clip(rect)
        storage.enumerateAttribute(.golensInlayHint, in: chars) { value, range, _ in
            guard let label = value as? String else { return }
            let anchor = NSMaxRange(range) - 1
            let next = anchor + 1
            guard next < storage.length, let kern = storage.attribute(.kern, at: anchor, effectiveRange: nil) as? CGFloat, kern > 0 else { return }
            let glyph = lm.glyphIndexForCharacter(at: next)
            guard glyph < lm.numberOfGlyphs, lm.isValidGlyphIndex(glyph), !lm.notShownAttribute(forGlyphAt: glyph) else { return }
            let anchorGlyph = lm.glyphIndexForCharacter(at: anchor)
            var fragmentRange = NSRange()
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentRange)
            guard fragment.height > 0 else { return }
            let gapStart: CGFloat
            let lineRect: NSRect
            if NSLocationInRange(anchorGlyph, fragmentRange) {
                gapStart = fragment.minX + lm.location(forGlyphAt: glyph).x + origin.x - kern
                lineRect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                let anchorFragment = lm.lineFragmentRect(forGlyphAt: anchorGlyph, effectiveRange: nil)
                let anchorChar = storage.mutableString.substring(with: NSRange(location: anchor, length: 1)) as NSString
                let advance = anchorChar.size(withAttributes: [.font: textView.font ?? TechnicalTypography.codeCanvasNSFont(size: 13, weight: .regular)]).width
                gapStart = anchorFragment.minX + lm.location(forGlyphAt: anchorGlyph).x + advance + origin.x
                lineRect = lm.lineFragmentUsedRect(forGlyphAt: anchorGlyph, effectiveRange: nil)
            }
            let text = label as NSString
            let size = text.size(withAttributes: attrs)
            let pill = NSRect(x: gapStart + Self.pillGap, y: lineRect.minY + origin.y + (lineRect.height - size.height) / 2 - 1,
                              width: kern - Self.pillGap * 2, height: size.height + 2)
            guard pill.intersects(rect) else { return }
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            text.draw(at: NSPoint(x: pill.minX + Self.pillPadding, y: pill.minY + 1), withAttributes: attrs)
        }
    }

    private static func labelAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
        let size = max(10, (textView.font?.pointSize ?? 13) - 2)
        return [
            .font: TechnicalTypography.codeCanvasNSFont(size: size, weight: .regular),
            .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
        ]
    }

    private func isEnabled() -> Bool {
        (textView?.workspaceState ?? WorkspaceState.shared).showInlayHints
    }

    private func fetchHints() {
        guard let textView = textView,
              !textView.filePath.isEmpty,
              textView.filePath.hasSuffix(".go") else {
            removeAllHints()
            return
        }

        let visibleRange = visibleCharacterRange()
        guard visibleRange.length > 0 else { return }

        guard let lines = visibleLines() else { return }
        let lspRange = LSPRange(
            start: LSPPosition(line: lines.lowerBound - 1, character: 0),
            end: LSPPosition(line: lines.upperBound, character: 0)
        )

        let path = textView.filePath
        let version = textView.document?.version
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            let fetched = await LSPClient.shared.requestInlayHints(range: lspRange, inPath: path)
            guard let self = self else { return }
            guard let hints = fetched else {
                if !Task.isCancelled, self.failedFetches < Self.maxFetchRetries {
                    self.failedFetches += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                        self?.scheduleUpdate()
                    }
                }
                return
            }
            self.failedFetches = 0
            guard let textView = self.textView,
                  textView.filePath == path,
                  textView.document?.version == version else { return }
            self.fetchedLines = lines
            self.fetchedVersion = version
            let ordered = hints.sorted {
                ($0.position.line, $0.position.character) < ($1.position.line, $1.position.character)
            }
            self.currentHints = Array(ordered.prefix(Self.maxVisibleHints))
            var grouped: [Int: [InlayHint]] = [:]
            for hint in self.currentHints {
                grouped[hint.position.line, default: []].append(hint)
            }
            self.hintsByLine0 = grouped
            self.applyInlineHints(in: visibleRange)
            self.renderHints()
        }
    }

    private func applyInlineHints(in range: NSRange) {
        guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let ns = storage.mutableString
        let target = NSIntersectionRange(ns.lineRange(for: range), NSRange(location: 0, length: storage.length))
        let attrs = Self.labelAttributes(for: textView)
        var placements: [(anchor: Int, label: String, width: CGFloat)] = []
        var perLineCounts: [Int: Int] = [:]
        for hint in currentHints {
            let lineCount = perLineCounts[hint.position.line, default: 0]
            guard lineCount < Self.maxHintsPerLine else { continue }
            guard let index = textView.characterIndex(forLine: hint.position.line + 1, col: hint.position.character + 1),
                  index > 0, index < ns.length, NSLocationInRange(index, target) else { continue }
            let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            let trailing = ns.substring(with: NSRange(location: index, length: lineEnd - index)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trailing.isEmpty else { continue }
            let previous = ns.character(at: index - 1)
            guard previous != 0x0A, previous != 0x0D else { continue }
            let label = hint.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !placements.contains(where: { $0.anchor == index - 1 }) else { continue }
            let width = ceil((label as NSString).size(withAttributes: attrs).width) + Self.pillPadding * 2 + Self.pillGap * 2
            placements.append((index - 1, label, width))
            perLineCounts[hint.position.line] = lineCount + 1
        }
        appliedVersion = textView.document?.version
        var existing: [(anchor: Int, label: String)] = []
        storage.enumerateAttribute(.golensInlayHint, in: target) { value, r, _ in
            if let label = value as? String { existing.append((r.location, label)) }
        }
        let desired = placements.map { (anchor: $0.anchor, label: $0.label) }.sorted { $0.anchor < $1.anchor }
        if existing.count == desired.count,
           zip(existing, desired).allSatisfy({ $0.anchor == $1.anchor && $0.label == $1.label }) {
            return
        }
        storage.beginEditing()
        clearInlineHints(in: storage, range: target)
        for placement in placements {
            let r = NSRange(location: placement.anchor, length: 1)
            storage.addAttributes([.kern: placement.width, .golensInlayHint: placement.label], range: r)
        }
        storage.endEditing()
    }

    private func clearInlineHints(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var marked: [NSRange] = []
        storage.enumerateAttribute(.golensInlayHint, in: range) { value, r, _ in
            if value != nil { marked.append(r) }
        }
        guard !marked.isEmpty else { return }
        storage.beginEditing()
        for r in marked {
            storage.removeAttribute(.golensInlayHint, range: r)
            storage.removeAttribute(.kern, range: r)
        }
        storage.endEditing()
    }

    private func renderHints() {
        guard let textView = textView else { return }
        textView.setNeedsDisplay(textView.visibleRect)
    }

    private func visibleLines() -> ClosedRange<Int>? {
        guard let textView else { return nil }
        let range = visibleCharacterRange()
        guard range.length > 0 else { return nil }
        let first = textView.lineAndCol(forCharacterIndex: range.location).line
        let last = textView.lineAndCol(forCharacterIndex: NSMaxRange(range)).line
        return max(1, first)...max(max(1, first), last)
    }

    private func visibleCharacterRange() -> NSRange {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return NSRange(location: 0, length: 0) }

        let visibleRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let rectInContainer = NSRect(
            x: visibleRect.origin.x - containerOrigin.x,
            y: visibleRect.origin.y - containerOrigin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rectInContainer, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }
}
