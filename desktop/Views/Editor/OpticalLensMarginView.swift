import AppKit
import SwiftUI

final class OpticalLensAccessibilityElement: NSAccessibilityElement {
    private weak var ownerTextView: GoLensTextView?
    private let localRect: NSRect
    private let onPress: (() -> Void)?

    init(textView: GoLensTextView, line: Int, title: String, rect: NSRect, onPress: (() -> Void)?) {
        self.ownerTextView = textView
        self.localRect = rect
        self.onPress = onPress
        super.init()
        setAccessibilityParent(textView)
        setAccessibilityRole(onPress != nil ? .button : .staticText)
        setAccessibilityLabel("Line \(line): \(title)")
    }

    override func accessibilityFrame() -> NSRect {
        guard let tv = ownerTextView, let win = tv.window else { return .zero }
        let inWindow = tv.convert(localRect, to: nil)
        return win.convertToScreen(inWindow)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

final class OpticalLensMarginView: NSView {
    private var lineElements: [Int: [OpticalLensAccessibilityElement]] = [:]

    static let truncatingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func resetAllAccessibilityElements() {
        lineElements.removeAll(keepingCapacity: true)
    }

    func clearLineAccessibilityElements(_ lineNumber: Int) {
        lineElements[lineNumber] = nil
    }

    func currentAccessibilityElements() -> [OpticalLensAccessibilityElement] {
        guard !lineElements.isEmpty else { return [] }
        var result: [OpticalLensAccessibilityElement] = []
        for key in lineElements.keys.sorted() {
            if let items = lineElements[key] {
                result.append(contentsOf: items)
            }
        }
        return result
    }

    func drawSurface(in dirtyRect: NSRect, visibleRect: NSRect, marginWidth: CGFloat) {
        guard marginWidth > 0 else { return }
        let marginRect = NSRect(
            x: visibleRect.maxX - marginWidth,
            y: visibleRect.origin.y,
            width: marginWidth,
            height: visibleRect.height
        )
        let clipped = marginRect.intersection(dirtyRect)
        guard !clipped.isEmpty else { return }

        CodeSurfaceTheme.nsBackground.withAlphaComponent(1.0).setFill()
        clipped.fill()

        CodeSurfaceTheme.nsLensMarginBackground.setFill()
        clipped.fill()

        let dividerRect = NSRect(
            x: marginRect.minX,
            y: clipped.minY,
            width: Stroke.hairline,
            height: clipped.height
        )
        if dividerRect.intersects(dirtyRect) {
            CodeSurfaceTheme.nsLensDivider.setFill()
            dividerRect.fill()
        }
    }

    func drawLineItem(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        visibleRect: NSRect,
        marginWidth: CGFloat,
        inlineStartX: CGFloat = 0,
        textView: GoLensTextView
    ) {
        let line = item.lineNumber
        var axItems: [OpticalLensAccessibilityElement] = []

        let fontSize = max(10, WorkspaceState.owning(window: window).editorFontSize - 2)
        let regularFont = TechnicalTypography.codeCanvasNSFont(size: fontSize, weight: .regular)
        let mediumFont = TechnicalTypography.codeCanvasNSFont(size: fontSize, weight: .medium)

        if marginWidth <= 0 {
            let minInlineX = visibleRect.origin.x + textView.gutterWidth + 24
            let contentMinX = max(minInlineX, ceil(inlineStartX))
            let viewportMaxX = visibleRect.maxX - Spacing.comfortable

            if item.mode == .conflict {
                drawExpandedConflictActions(
                    item,
                    yPos: yPos,
                    height: height,
                    visibleRect: visibleRect,
                    marginMinX: contentMinX,
                    contentMinX: contentMinX,
                    contentMaxX: viewportMaxX,
                    regularFont: regularFont,
                    mediumFont: mediumFont,
                    textView: textView,
                    axItems: &axItems
                )
                lineElements[line] = axItems
                return
            }

            if viewportMaxX - contentMinX >= 48 {
                drawExpandedItemContent(
                    item,
                    yPos: yPos,
                    height: height,
                    contentMinX: contentMinX,
                    contentMaxX: viewportMaxX,
                    regularFont: regularFont,
                    mediumFont: mediumFont,
                    textView: textView,
                    axItems: &axItems
                )
                lineElements[line] = axItems
                return
            }

            let rawGlyphEnd = inlineStartX - Spacing.comfortable
            if visibleRect.maxX - 6 - (rawGlyphEnd + 8) >= 28 {
                let pillX = max(rawGlyphEnd + 8, visibleRect.maxX - 34)
                drawCompactPill(
                    item,
                    yPos: yPos,
                    height: height,
                    pillMinX: pillX,
                    pillWidth: 28,
                    opaqueHalo: false,
                    textView: textView,
                    axItems: &axItems
                )
                lineElements[line] = axItems
                return
            }

            if !item.issues.isEmpty || !item.goplsLenses.isEmpty || item.moduleNote != nil {
                drawCompactPill(
                    item,
                    yPos: yPos,
                    height: height,
                    pillMinX: visibleRect.maxX - 36,
                    pillWidth: 28,
                    opaqueHalo: true,
                    haloMaxX: visibleRect.maxX,
                    textView: textView,
                    axItems: &axItems
                )
                lineElements[line] = axItems
                return
            }

            let docMaxX = min(textView.bounds.maxX - Spacing.standard, contentMinX + 240)
            if docMaxX - contentMinX >= 48 {
                drawExpandedItemContent(
                    item,
                    yPos: yPos,
                    height: height,
                    contentMinX: contentMinX,
                    contentMaxX: docMaxX,
                    regularFont: regularFont,
                    mediumFont: mediumFont,
                    textView: textView,
                    axItems: &axItems
                )
            }
            lineElements[line] = axItems
            return
        }

        if marginWidth < 64 {
            drawCompactPill(
                item,
                yPos: yPos,
                height: height,
                pillMinX: visibleRect.maxX - marginWidth + 4,
                pillWidth: max(20, marginWidth - 8),
                opaqueHalo: false,
                textView: textView,
                axItems: &axItems
            )
            lineElements[line] = axItems
            return
        }

        let marginMinX = visibleRect.maxX - marginWidth
        let contentMinX = marginMinX + Spacing.standard
        let contentMaxX = visibleRect.maxX - Spacing.standard
        guard contentMaxX > contentMinX + 16 else { return }

        if item.mode == .conflict {
            drawExpandedConflictActions(
                item,
                yPos: yPos,
                height: height,
                visibleRect: visibleRect,
                marginMinX: marginMinX,
                contentMinX: contentMinX,
                contentMaxX: contentMaxX,
                regularFont: regularFont,
                mediumFont: mediumFont,
                textView: textView,
                axItems: &axItems
            )
        } else {
            drawExpandedItemContent(
                item,
                yPos: yPos,
                height: height,
                contentMinX: contentMinX,
                contentMaxX: contentMaxX,
                regularFont: regularFont,
                mediumFont: mediumFont,
                textView: textView,
                axItems: &axItems
            )
        }

        lineElements[line] = axItems
    }

    private func drawExpandedItemContent(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        contentMinX: CGFloat,
        contentMaxX: CGFloat,
        regularFont: NSFont,
        mediumFont: NSFont,
        textView: GoLensTextView,
        axItems: inout [OpticalLensAccessibilityElement]
    ) {
        switch item.mode {
        case .conflict:
            break
        case .debug:
            drawExpandedDebugValue(
                item,
                yPos: yPos,
                height: height,
                contentMinX: contentMinX,
                contentMaxX: contentMaxX,
                regularFont: regularFont,
                textView: textView,
                axItems: &axItems
            )
        case .profile:
            drawExpandedProfileRow(
                item,
                yPos: yPos,
                height: height,
                contentMinX: contentMinX,
                contentMaxX: contentMaxX,
                mediumFont: mediumFont,
                textView: textView,
                axItems: &axItems
            )
        case .edit:
            drawExpandedEditRow(
                item,
                yPos: yPos,
                height: height,
                contentMinX: contentMinX,
                contentMaxX: contentMaxX,
                regularFont: regularFont,
                mediumFont: mediumFont,
                textView: textView,
                axItems: &axItems
            )
        }
    }

    private func drawCompactPill(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        pillMinX: CGFloat,
        pillWidth: CGFloat,
        opaqueHalo: Bool,
        haloMaxX: CGFloat? = nil,
        textView: GoLensTextView,
        axItems: inout [OpticalLensAccessibilityElement]
    ) {
        let spec = item.compactPillSpec
        let pillHeight = max(13, min(height - 2, 16))
        let pillRect = NSRect(
            x: pillMinX,
            y: yPos + (height - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )
        if opaqueHalo {
            let haloMinX = pillRect.minX - 3
            let haloRightEdge = max(pillRect.maxX + 3, haloMaxX ?? (pillRect.maxX + 3))
            let haloRect = NSRect(
                x: haloMinX,
                y: yPos,
                width: max(0, haloRightEdge - haloMinX),
                height: height
            )
            CodeSurfaceTheme.nsBackground.withAlphaComponent(1.0).setFill()
            haloRect.fill()
        }
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let shape = NSBezierPath(roundedRect: pillRect, xRadius: CornerRadius.small, yRadius: CornerRadius.small)
        let textColor: NSColor

        if spec.tone == .failure || spec.tone == .warning {
            let tint: NSColor = spec.tone == .failure ? .systemRed : .systemOrange
            tint.withAlphaComponent(increased ? 0.28 : 0.16).setFill()
            shape.fill()
            if increased {
                tint.setStroke()
                shape.lineWidth = Stroke.standard
                shape.stroke()
            }
            textColor = .labelColor
        } else {
            NSColor.quaternarySystemFill.setFill()
            shape.fill()
            CodeSurfaceTheme.nsLensDivider.setStroke()
            shape.lineWidth = Stroke.hairline
            shape.stroke()
            textColor = CodeSurfaceTheme.nsLensActionText
        }

        let pillFont = TechnicalTypography.codeCanvasNSFont(size: 10, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: pillFont,
            .foregroundColor: textColor
        ]
        let label = spec.text as NSString
        let tsize = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(
                x: pillRect.midX - tsize.width / 2,
                y: pillRect.midY - tsize.height / 2
            ),
            withAttributes: attrs
        )

        textView.compactLensHitRects[item.lineNumber] = (pillRect, item)
        let line = item.lineNumber
        axItems.append(
            OpticalLensAccessibilityElement(
                textView: textView,
                line: line,
                title: item.accessibilitySummary,
                rect: pillRect,
                onPress: { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.presentCompactPopover(for: item, anchorRect: pillRect, in: textView)
                }
            )
        )
    }

    private func drawExpandedConflictActions(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        visibleRect: NSRect,
        marginMinX: CGFloat,
        contentMinX: CGFloat,
        contentMaxX: CGFloat,
        regularFont: NSFont,
        mediumFont: NSFont,
        textView: GoLensTextView,
        axItems: inout [OpticalLensAccessibilityElement]
    ) {
        let actionAttrs: [NSAttributedString.Key: Any] = [
            .font: mediumFont,
            .foregroundColor: CodeSurfaceTheme.nsLensActionText
        ]
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: regularFont,
            .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
        ]
        let sepStr = "|" as NSString
        let sepWidth = sepStr.size(withAttributes: sepAttrs).width
        let gap: CGFloat = 5

        var totalWidth: CGFloat = 0
        var sizes: [NSSize] = []
        sizes.reserveCapacity(item.conflictActions.count)
        for (idx, action) in item.conflictActions.enumerated() {
            if idx > 0 { totalWidth += sepWidth + gap * 2 }
            let sz = (action.title as NSString).size(withAttributes: actionAttrs)
            sizes.append(sz)
            totalWidth += sz.width
        }

        let minAllowedX = visibleRect.origin.x + textView.gutterWidth + 104
        let startX = max(minAllowedX, min(contentMinX, contentMaxX - totalWidth))

        if startX < marginMinX {
            let bannerRect = NSRect(
                x: startX - Spacing.row,
                y: yPos + 1,
                width: (marginMinX - startX) + Spacing.row + 2,
                height: max(13, height - 2)
            )
            let bannerPath = NSBezierPath(roundedRect: bannerRect, xRadius: CornerRadius.small, yRadius: CornerRadius.small)
            CodeSurfaceTheme.nsBackground.withAlphaComponent(1.0).setFill()
            bannerPath.fill()
            CodeSurfaceTheme.nsLensMarginBackground.setFill()
            bannerPath.fill()
            CodeSurfaceTheme.nsLensDivider.setStroke()
            bannerPath.lineWidth = Stroke.hairline
            bannerPath.stroke()
        }

        var currentX = startX
        var rects: [(NSRect, MergeConflictLensAction)] = []
        let line = item.lineNumber
        for (idx, action) in item.conflictActions.enumerated() {
            if idx > 0 {
                let sepY = yPos + (height - sizes[idx].height) / 2
                sepStr.draw(at: NSPoint(x: currentX, y: sepY), withAttributes: sepAttrs)
                currentX += sepWidth + gap
            }
            let sz = sizes[idx]
            let drawRect = NSRect(
                x: currentX,
                y: yPos + (height - sz.height) / 2,
                width: sz.width,
                height: sz.height
            )
            (action.title as NSString).draw(at: drawRect.origin, withAttributes: actionAttrs)
            let hitRect = NSRect(x: currentX, y: yPos, width: sz.width, height: height)
            rects.append((hitRect, action))
            axItems.append(
                OpticalLensAccessibilityElement(
                    textView: textView,
                    line: line,
                    title: action.title,
                    rect: hitRect,
                    onPress: { [weak textView] in
                        textView?.performMergeConflictAction(action, line: line, anchor: hitRect)
                    }
                )
            )
            currentX += sz.width + gap
        }
        textView.conflictActionHitRects[line] = rects
        textView.scheduleConflictToolTipRefresh()
    }

    private func drawExpandedDebugValue(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        contentMinX: CGFloat,
        contentMaxX: CGFloat,
        regularFont: NSFont,
        textView: GoLensTextView,
        axItems: inout [OpticalLensAccessibilityElement]
    ) {
        guard let debugValue = item.debugValue else { return }
        let available = contentMaxX - contentMinX
        guard available > 24 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: regularFont,
            .foregroundColor: CodeSurfaceTheme.nsLensMetadataText,
            .paragraphStyle: Self.truncatingParagraphStyle
        ]
        let textHeight = ceil(regularFont.ascender - regularFont.descender + regularFont.leading)
        let drawRect = NSRect(
            x: contentMinX,
            y: yPos + (height - textHeight) / 2,
            width: available,
            height: textHeight
        )
        (debugValue as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
        axItems.append(
            OpticalLensAccessibilityElement(
                textView: textView,
                line: item.lineNumber,
                title: debugValue,
                rect: drawRect,
                onPress: nil
            )
        )
    }

    private func drawExpandedProfileRow(
        _ item: OpticalLensLineItem,
        yPos: CGFloat,
        height: CGFloat,
        contentMinX: CGFloat,
        contentMaxX: CGFloat,
        mediumFont: NSFont,
        textView: GoLensTextView,
        axItems: inout [OpticalLensAccessibilityElement]
    ) {
        var x = contentMinX
        let isDark = CodeSurfaceTheme.isDark
        let textHeight = ceil(mediumFont.ascender - mediumFont.descender + mediumFont.leading)

        if let heat = item.profileHeat {
            let clamped = min(max(heat, 0), 1)
            let barWidth: CGFloat = 28
            let barHeight: CGFloat = 5
            let barRect = NSRect(x: x, y: yPos + (height - barHeight) / 2, width: barWidth, height: barHeight)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5).fill()

            let strokeColor = NSColor(DataVizTone.heatStroke(fraction: clamped, isDark: isDark))
            strokeColor.setFill()
            let fillWidth = max(3, barWidth * CGFloat(clamped))
            NSBezierPath(
                roundedRect: NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barHeight),
                xRadius: 2.5,
                yRadius: 2.5
            ).fill()
            x += barWidth + Spacing.compact

            let pctText = String(format: "%.0f%%", clamped * 100) as NSString
            let pctAttrs: [NSAttributedString.Key: Any] = [
                .font: mediumFont,
                .foregroundColor: strokeColor
            ]
            let pctSize = pctText.size(withAttributes: pctAttrs)
            pctText.draw(at: NSPoint(x: x, y: yPos + (height - pctSize.height) / 2), withAttributes: pctAttrs)
            x += pctSize.width + Spacing.row
        }

        if let escapeNote = item.escapeNote, contentMaxX - x > 24 {
            let escapeAttrs: [NSAttributedString.Key: Any] = [
                .font: mediumFont,
                .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.92),
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let rect = NSRect(
                x: x,
                y: yPos + (height - textHeight) / 2,
                width: contentMaxX - x,
                height: textHeight
            )
            (escapeNote as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: escapeAttrs
            )
        }

        let rowRect = NSRect(x: contentMinX, y: yPos, width: contentMaxX - contentMinX, height: height)
        axItems.append(
            OpticalLensAccessibilityElement(
                textView: textView,
                line: item.lineNumber,
                title: item.accessibilitySummary,
                rect: rowRect,
                onPress: nil
            )
        )
    }

}
