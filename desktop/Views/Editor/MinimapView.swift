import SwiftUI
import AppKit

protocol MinimapSyncDelegate: AnyObject {
    func documentDidChange()
}

struct MinimapView: NSViewRepresentable {
    weak var sourceTextView: GoLensTextView?

    func makeNSView(context: Context) -> MinimapCanvas {
        let canvas = MinimapCanvas(frame: .zero)
        canvas.bind(to: sourceTextView)
        return canvas
    }

    func updateNSView(_ canvas: MinimapCanvas, context: Context) {
        if canvas.source !== sourceTextView {
            canvas.bind(to: sourceTextView)
        }
        canvas.needsDisplay = true
    }

    static func dismantleNSView(_ canvas: MinimapCanvas, coordinator: ()) {
        canvas.bind(to: nil)
    }
}

final class MinimapCanvas: NSView, MinimapSyncDelegate {
    static let lineHeight: CGFloat = 2
    static let charWidth: CGFloat = 1
    static let maxColumns = 120

    private(set) weak var source: GoLensTextView?
    private var redrawPending = false

    override var isFlipped: Bool { true }

    func bind(to textView: GoLensTextView?) {
        NotificationCenter.default.removeObserver(self)
        if source?.minimapDelegate === self {
            source?.minimapDelegate = nil
        }
        source = textView
        textView?.minimapDelegate = self
        if let clip = textView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(sourceDidScroll), name: NSView.boundsDidChangeNotification, object: clip)
        }
        needsDisplay = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sourceDidScroll() {
        needsDisplay = true
    }

    func documentDidChange() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.redrawPending = false
            self?.needsDisplay = true
        }
    }

    private struct Geometry {
        let offset: CGFloat
        let firstVisibleLine: Int
        let visibleLineCount: Int
    }

    private func geometry(lineCount: Int) -> Geometry? {
        guard let source, let scroll = source.enclosingScrollView, let doc = source.document,
              let lm = source.layoutManager, let tc = source.textContainer else { return nil }
        let clip = scroll.contentView.bounds
        let docHeight = max(1, source.bounds.height - clip.height)
        let fraction = min(1, max(0, clip.origin.y / docHeight))
        let total = CGFloat(lineCount) * Self.lineHeight
        let offset = max(0, total - bounds.height) * fraction
        let glyphs = lm.glyphRange(forBoundingRect: source.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = doc.lines.line(at: chars.location)
        let last = doc.lines.line(at: NSMaxRange(chars))
        return Geometry(offset: offset, firstVisibleLine: first, visibleLineCount: max(1, last - first + 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let source, let doc = source.document, let lm = source.layoutManager else { return }
        let lineCount = doc.lines.count
        guard let geo = geometry(lineCount: lineCount) else { return }
        let text = doc.storage.string as NSString
        let base = (source.textColor ?? .textColor).withAlphaComponent(0.35)
        let first = Int(geo.offset / Self.lineHeight)
        let last = min(lineCount - 1, first + Int(bounds.height / Self.lineHeight) + 1)
        var buffer = [unichar](repeating: 0, count: Self.maxColumns)
        if first <= last {
            for line in first...last {
                guard let range = doc.lineRange(line), range.length > 0 else { continue }
                let n = min(range.length, Self.maxColumns)
                text.getCharacters(&buffer, range: NSRange(location: range.location, length: n))
                let y = CGFloat(line) * Self.lineHeight - geo.offset
                var col = 0
                var i = 0
                while i < n {
                    let u = buffer[i]
                    if u == 0x09 { col += 4; i += 1; continue }
                    if u == 0x20 { col += 1; i += 1; continue }
                    let start = i
                    let startCol = col
                    while i < n, buffer[i] != 0x20, buffer[i] != 0x09 { i += 1; col += 1 }
                    let color = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location + start, effectiveRange: nil) as? NSColor
                    (color?.withAlphaComponent(0.7) ?? base).setFill()
                    NSRect(x: 4 + CGFloat(startCol) * Self.charWidth, y: y, width: CGFloat(col - startCol) * Self.charWidth, height: Self.lineHeight * 0.75).fill()
                }
            }
        }
        let thumb = NSRect(x: 0, y: CGFloat(geo.firstVisibleLine) * Self.lineHeight - geo.offset, width: bounds.width, height: max(10, CGFloat(geo.visibleLineCount) * Self.lineHeight))
        (source.textColor ?? .textColor).withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 4, yRadius: 4).fill()
    }

    private func scrollSource(toMinimapY y: CGFloat) {
        guard let source, let doc = source.document, let geo = geometry(lineCount: doc.lines.count) else { return }
        let line = max(0, min(doc.lines.count - 1, Int((y + geo.offset) / Self.lineHeight) - geo.visibleLineCount / 2))
        guard let offset = doc.lines.start(ofLine: line), let lm = source.layoutManager, let tc = source.textContainer else { return }
        let glyph = lm.glyphIndexForCharacter(at: offset)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        source.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + source.textContainerOrigin.y))
        source.enclosingScrollView?.reflectScrolledClipView(source.enclosingScrollView!.contentView)
        _ = tc
    }

    override func mouseDown(with event: NSEvent) {
        scrollSource(toMinimapY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        scrollSource(toMinimapY: convert(event.locationInWindow, from: nil).y)
    }
}
