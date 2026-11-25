import AppKit

extension GoLensTextView {
    static let ghostTextColor = NSColor(name: "GoLensGhostText") { appearance in
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var color = highContrast ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            if highContrast, let secondary = NSColor.secondaryLabelColor.usingColorSpace(.sRGB),
               let label = NSColor.labelColor.usingColorSpace(.sRGB),
               let mixed = secondary.blended(withFraction: 0.2, of: label) {
                color = mixed
            } else if let tertiary = NSColor.tertiaryLabelColor.usingColorSpace(.sRGB),
                      let secondary = NSColor.secondaryLabelColor.usingColorSpace(.sRGB),
                      let mixed = tertiary.blended(withFraction: 0.35, of: secondary) {
                color = mixed
            }
        }
        return color
    }
}

final class GhostTextLayout {
    let ghostRange: NSRange
    let trailingRange: NSRange?
    let extraHeight: CGFloat
    let lineCount: Int
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer

    init(linePrefix: NSAttributedString, ghost: String, trailing: NSAttributedString?, font: NSFont, ghostColor: NSColor,
         containerWidth: CGFloat, lineFragmentPadding: CGFloat, realLineHeight: CGFloat) {
        container = NSTextContainer(size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = lineFragmentPadding
        container.widthTracksTextView = false
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.usesFontLeading = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let text = NSMutableAttributedString(attributedString: linePrefix)
        let ghostStart = text.length
        text.append(NSAttributedString(string: ghost, attributes: [.font: font, .foregroundColor: ghostColor]))
        ghostRange = NSRange(location: ghostStart, length: text.length - ghostStart)
        if let trailing, trailing.length > 0 {
            let start = text.length
            text.append(trailing)
            trailingRange = NSRange(location: start, length: trailing.length)
        } else {
            trailingRange = nil
        }
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        extraHeight = max(0, ceil(used.height - realLineHeight))
        lineCount = ghost.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    func draw(at origin: NSPoint) {
        var range = ghostRange
        if let trailingRange { range = NSUnionRange(range, trailingRange) }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    func boundingRect(at origin: NSPoint) -> NSRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: ghostRange, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
    }
}
