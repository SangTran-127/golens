import AppKit
import SwiftUI

extension OpticalLensMarginView {
    func drawExpandedEditRow(
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
        let line = item.lineNumber
        var x = contentMinX
        let textHeight = ceil(regularFont.ascender - regularFont.descender + regularFont.leading)

        if let renameOffer = item.renameOffer {
            let fullTitle = item.renameShortcutDisplay.isEmpty
                ? renameOffer.title
                : "\(renameOffer.title)  \(item.renameShortcutDisplay)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: mediumFont,
                .foregroundColor: CodeSurfaceTheme.nsLensActionText,
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let measured = (fullTitle as NSString).size(withAttributes: [.font: mediumFont]).width
            let width = min(contentMaxX - x, ceil(measured))
            let rect = NSRect(x: x, y: yPos + (height - textHeight) / 2, width: width, height: textHeight)
            (fullTitle as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrs
            )
            let hitRect = NSRect(x: x, y: yPos, width: width, height: height)
            textView.renameHitRect = hitRect
            axItems.append(
                OpticalLensAccessibilityElement(
                    textView: textView,
                    line: line,
                    title: renameOffer.title,
                    rect: hitRect,
                    onPress: { [weak textView] in textView?.acceptRenameSuggestion() }
                )
            )
            return
        }

        if !item.issues.isEmpty {
            if let usagesText = item.usagesLabel {
                let usageAttrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont,
                    .foregroundColor: item.usageInteractive ? CodeSurfaceTheme.nsLensActionText : CodeSurfaceTheme.nsLensMetadataText
                ]
                let uSize = (usagesText as NSString).size(withAttributes: usageAttrs)
                if contentMaxX - (x + uSize.width + Spacing.row) >= 96 {
                    (usagesText as NSString).draw(
                        at: NSPoint(x: x, y: yPos + (height - uSize.height) / 2),
                        withAttributes: usageAttrs
                    )
                    if item.usageInteractive {
                        let hitRect = NSRect(x: x, y: yPos, width: uSize.width, height: height)
                        textView.usageHitRects[line] = hitRect
                        axItems.append(
                            OpticalLensAccessibilityElement(
                                textView: textView,
                                line: line,
                                title: usagesText,
                                rect: hitRect,
                                onPress: { [weak textView] in textView?.showUsagesForDeclaration(atLine: line) }
                            )
                        )
                    }
                    x += uSize.width + Spacing.row
                }
            }

            let capsuleMaxX = item.goplsLenses.isEmpty ? contentMaxX : min(contentMaxX, x + (contentMaxX - x >= 180 ? 34 : 26))
            if let capsuleRect = drawDiagnosticCapsule(
                item.issues,
                line: line,
                minX: x,
                maxX: capsuleMaxX,
                yPos: yPos,
                height: height,
                font: mediumFont,
                textView: textView
            ) {
                let diags = item.issues
                axItems.append(
                    OpticalLensAccessibilityElement(
                        textView: textView,
                        line: line,
                        title: diags.first?.message ?? "Diagnostic",
                        rect: capsuleRect,
                        onPress: { [weak textView] in
                            guard let textView else { return }
                            textView.workspaceState.toggleIssuePopup(in: textView, line: line, diags: diags, below: capsuleRect)
                        }
                    )
                )
                x = capsuleRect.maxX + Spacing.compact
            }
            if item.goplsLenses.isEmpty || contentMaxX - x <= 28 {
                return
            }
        }

        if let usagesText = item.usagesLabel, contentMaxX - x > 28 {
            let usageAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: item.usageInteractive ? CodeSurfaceTheme.nsLensActionText : CodeSurfaceTheme.nsLensMetadataText
            ]
            let uSize = (usagesText as NSString).size(withAttributes: usageAttrs)
            let drawWidth = min(uSize.width, contentMaxX - x)
            (usagesText as NSString).draw(
                with: NSRect(x: x, y: yPos + (height - uSize.height) / 2, width: drawWidth, height: uSize.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: usageAttrs
            )
            let hitRect = NSRect(x: x, y: yPos, width: drawWidth, height: height)
            if item.usageInteractive {
                textView.usageHitRects[line] = hitRect
                axItems.append(
                    OpticalLensAccessibilityElement(
                        textView: textView,
                        line: line,
                        title: usagesText,
                        rect: hitRect,
                        onPress: { [weak textView] in textView?.showUsagesForDeclaration(atLine: line) }
                    )
                )
            } else {
                axItems.append(
                    OpticalLensAccessibilityElement(
                        textView: textView,
                        line: line,
                        title: usagesText,
                        rect: hitRect,
                        onPress: nil
                    )
                )
            }
            x += drawWidth + Spacing.row
        }

        if item.implementsDirection != .none, contentMaxX - x > 36 {
            if x > contentMinX {
                let dot = "·" as NSString
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont,
                    .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
                ]
                let dotSize = dot.size(withAttributes: dotAttrs)
                dot.draw(at: NSPoint(x: x, y: yPos + (height - dotSize.height) / 2), withAttributes: dotAttrs)
                x += dotSize.width + Spacing.compact
            }
            let startX = x
            let up = item.implementsDirection == .implements
            let symbolName = up ? "arrow.up.right.circle" : "arrow.down.right.circle"
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [CodeSurfaceTheme.nsLensActionText]))
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                img.draw(in: NSRect(x: x, y: yPos + (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
                x += img.size.width + 3
            }
            let implAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensActionText,
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let fullLabel = item.implementationsLabel ?? ""
            let shortLabel = item.compactImplementationsLabel ?? fullLabel
            let fullWidth = (fullLabel as NSString).size(withAttributes: [.font: regularFont]).width
            let chosen = fullWidth <= (contentMaxX - x) ? fullLabel : shortLabel
            let chosenWidth = min(contentMaxX - x, ceil((chosen as NSString).size(withAttributes: [.font: regularFont]).width))
            (chosen as NSString).draw(
                with: NSRect(x: x, y: yPos + (height - textHeight) / 2, width: chosenWidth, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: implAttrs
            )
            let hitRect = NSRect(x: startX, y: yPos, width: (x + chosenWidth) - startX, height: height)
            let impls = item.implementations
            textView.implHitRects[line] = (hitRect, impls)
            axItems.append(
                OpticalLensAccessibilityElement(
                    textView: textView,
                    line: line,
                    title: fullLabel,
                    rect: hitRect,
                    onPress: { [weak textView] in
                        guard let textView else { return }
                        if impls.count == 1, let only = impls.first {
                            textView.jumpTo(path: only.path, line: only.range.start.line + 1, col: only.range.start.character + 1)
                        } else {
                            let declName = textView.workspaceState.activeGoDeclarations.first(where: { $0.line == line })?.symbolName
                            let sym = declName ?? textView.getWord(at: textView.selectedRange().location) ?? "symbol"
                            textView.workspaceState.showReferences(impls, for: sym, kind: "Implementations")
                        }
                    }
                )
            )
            x += chosenWidth + Spacing.row
        }

        if !item.goplsLenses.isEmpty, contentMaxX - x > 28 {
            if x > contentMinX {
                let dot = "·" as NSString
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont,
                    .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
                ]
                let dotSize = dot.size(withAttributes: dotAttrs)
                dot.draw(at: NSPoint(x: x, y: yPos + (height - dotSize.height) / 2), withAttributes: dotAttrs)
                x += dotSize.width + Spacing.compact
            }
            let sepStr = "|" as NSString
            let sepAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
            ]
            let sepWidth = sepStr.size(withAttributes: sepAttrs).width
            let count = item.goplsLenses.count
            let fullTitles = item.goplsLenses.map(\.title)
            let compactTitles = item.goplsLenses.map { ($0.command["compactTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.title }
            func measureWidths(_ titles: [String]) -> [CGFloat] {
                zip(item.goplsLenses, titles).map { lens, title in
                    let isCompare = (lens.command["golensCommand"] as? String) == "compareBenchmarkBaseline"
                    let f = isCompare ? mediumFont : regularFont
                    let iconExtra: CGFloat = ((lens.command["golensCommand"] as? String) == "httpShowResponse" && (lens.command["outcome"] as? String) != "neutral") ? 13 : 0
                    return ceil((title as NSString).size(withAttributes: [.font: f]).width) + iconExtra
                }
            }
            let fullWidths = measureWidths(fullTitles)
            let compactWidths = measureWidths(compactTitles)
            let moreTitle = "More…" as NSString
            let moreAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensActionText
            ]
            let moreWidth = ceil(moreTitle.size(withAttributes: moreAttrs).width)
            let gap = sepWidth + 6 + 3
            func fitCount(_ widths: [CGFloat]) -> Int {
                var fitted = 0
                var used: CGFloat = 0
                for idx in 0..<count {
                    let next = used + (idx > 0 ? gap : 0) + widths[idx]
                    let reserve: CGFloat = idx + 1 < count ? gap + moreWidth : 0
                    guard x + next + reserve <= contentMaxX else { break }
                    used = next
                    fitted = idx + 1
                }
                return fitted
            }
            let fullFitted = fitCount(fullWidths)
            let compactFitted = fitCount(compactWidths)
            let useCompactTitles = compactTitles != fullTitles && fullFitted < count && (compactFitted == count || compactFitted > fullFitted)
            let displayTitles = useCompactTitles ? compactTitles : fullTitles
            let naturalWidths = useCompactTitles ? compactWidths : fullWidths
            var visibleCount = useCompactTitles ? compactFitted : fullFitted
            var firstLensBudget: CGFloat?
            if visibleCount == 0 {
                let room = contentMaxX - x - (count > 1 ? gap + moreWidth : 0)
                let minLegible = count == 1 ? 28 : min(naturalWidths[0], 72)
                if room >= minLegible {
                    visibleCount = 1
                    firstLensBudget = room
                }
            }
            let overflows = visibleCount < count
            let scale: CGFloat = 1.0

            for (idx, lens) in item.goplsLenses.prefix(visibleCount).enumerated() {
                if idx > 0 {
                    sepStr.draw(at: NSPoint(x: x, y: yPos + (height - textHeight) / 2), withAttributes: sepAttrs)
                    x += sepWidth + 6
                }
                let isCompareLens = (lens.command["golensCommand"] as? String) == "compareBenchmarkBaseline"
                let httpOutcome = (lens.command["golensCommand"] as? String) == "httpShowResponse" ? lens.command["outcome"] as? String : nil
                let fgColor: NSColor
                if httpOutcome != nil {
                    fgColor = CodeSurfaceTheme.nsLensMetadataText
                } else if isCompareLens && lens.title.contains("faster") {
                    fgColor = NSColor.systemGreen.withAlphaComponent(0.9)
                } else if isCompareLens && lens.title.contains("slower") {
                    fgColor = NSColor.systemRed.withAlphaComponent(0.9)
                } else {
                    fgColor = CodeSurfaceTheme.nsLensActionText
                }

                let startX = x
                let slotBudget = min(contentMaxX - x, idx == 0 ? (firstLensBudget ?? max(22, floor(naturalWidths[idx] * scale))) : max(22, floor(naturalWidths[idx] * scale)))
                var textStartX = x
                if let httpOutcome, httpOutcome != "neutral" {
                    let success = httpOutcome == "success"
                    let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [success ? NSColor.systemGreen : NSColor.systemRed]))
                    if let img = NSImage(
                        systemSymbolName: success ? StatusTone.success.symbol : StatusTone.failure.symbol,
                        accessibilityDescription: success ? "Passed" : "Failed"
                    )?.withSymbolConfiguration(config) {
                        img.draw(in: NSRect(x: textStartX, y: yPos + (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
                        textStartX += img.size.width + 3
                    }
                }

                let textBudget = max(12, slotBudget - (textStartX - startX))
                let actionAttrs: [NSAttributedString.Key: Any] = [
                    .font: isCompareLens ? mediumFont : regularFont,
                    .foregroundColor: fgColor,
                    .paragraphStyle: Self.truncatingParagraphStyle
                ]
                let drawRect = NSRect(x: textStartX, y: yPos + (height - textHeight) / 2, width: textBudget, height: textHeight)
                (displayTitles[idx] as NSString).draw(
                    with: drawRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: actionAttrs
                )
                let hitRect = NSRect(x: startX, y: yPos, width: (textStartX - startX) + textBudget, height: height)
                textView.lensHitRects[line, default: []].append((hitRect, lens))
                axItems.append(
                    OpticalLensAccessibilityElement(
                        textView: textView,
                        line: line,
                        title: lens.title,
                        rect: hitRect,
                        onPress: { [weak textView] in
                            textView?.workspaceState.runEditorLensCommand(lens.command, title: lens.title)
                        }
                    )
                )
                x = hitRect.maxX + (idx + 1 < count ? 3 : Spacing.row)
            }
            if overflows {
                if visibleCount > 0 {
                    sepStr.draw(at: NSPoint(x: x, y: yPos + (height - textHeight) / 2), withAttributes: sepAttrs)
                    x += sepWidth + 6
                }
                let moreRect = NSRect(x: x, y: yPos + (height - textHeight) / 2, width: min(moreWidth, contentMaxX - x), height: textHeight)
                moreTitle.draw(with: moreRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: moreAttrs)
                let hitRect = NSRect(x: moreRect.minX, y: yPos, width: moreRect.width, height: height)
                textView.compactLensHitRects[line] = (hitRect, item)
                let hidden = item.goplsLenses.dropFirst(visibleCount).map(\.title).joined(separator: ", ")
                axItems.append(
                    OpticalLensAccessibilityElement(
                        textView: textView,
                        line: line,
                        title: "More Actions: \(hidden)",
                        rect: hitRect,
                        onPress: { [weak self, weak textView] in
                            guard let self, let textView else { return }
                            self.presentCompactPopover(for: item, anchorRect: hitRect, in: textView)
                        }
                    )
                )
            }
            return
        }

        if let moduleNote = item.moduleNote, contentMaxX - x > 32 {
            if let img = GoLensTextView.cachedModuleWarning {
                img.draw(in: NSRect(x: x, y: yPos + (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
                x += img.size.width + 3
            }
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensMetadataText,
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let width = contentMaxX - x
            let rect = NSRect(x: x, y: yPos + (height - textHeight) / 2, width: width, height: textHeight)
            (moduleNote as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: noteAttrs
            )
            axItems.append(
                OpticalLensAccessibilityElement(
                    textView: textView,
                    line: line,
                    title: moduleNote,
                    rect: rect,
                    onPress: nil
                )
            )
            return
        }

        if let blame = item.activeLineBlame, contentMaxX - x > 36 {
            if x > contentMinX {
                let dot = "·" as NSString
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont,
                    .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
                ]
                let dotSize = dot.size(withAttributes: dotAttrs)
                dot.draw(at: NSPoint(x: x, y: yPos + (height - dotSize.height) / 2), withAttributes: dotAttrs)
                x += dotSize.width + Spacing.compact
            }
            let blameAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensMetadataText,
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let measured = ceil((blame as NSString).size(withAttributes: [.font: regularFont]).width)
            let width = min(contentMaxX - x, measured)
            let rect = NSRect(x: x, y: yPos + (height - textHeight) / 2, width: width, height: textHeight)
            (blame as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: blameAttrs
            )
            let hitRect = NSRect(x: x, y: yPos, width: width, height: height)
            textView.blameHit = (hitRect, line)
            let path = textView.filePath
            axItems.append(
                OpticalLensAccessibilityElement(
                    textView: textView,
                    line: line,
                    title: blame,
                    rect: hitRect,
                    onPress: { [weak textView] in
                        textView?.workspaceState.presentFileHistory(for: path, focusCaretLine: true)
                    }
                )
            )
            return
        }

        if let author = item.author, contentMaxX - x > 36 {
            if x > contentMinX {
                let dot = "·" as NSString
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont,
                    .foregroundColor: CodeSurfaceTheme.nsLensMetadataText
                ]
                let dotSize = dot.size(withAttributes: dotAttrs)
                dot.draw(at: NSPoint(x: x, y: yPos + (height - dotSize.height) / 2), withAttributes: dotAttrs)
                x += dotSize.width + Spacing.compact
            }
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [CodeSurfaceTheme.nsLensMetadataText]))
            if let personImage = NSImage(systemSymbolName: "person", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                personImage.draw(in: NSRect(x: x, y: yPos + (height - personImage.size.height) / 2, width: personImage.size.width, height: personImage.size.height))
                x += personImage.size.width + 3
            }
            let authorAttrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: CodeSurfaceTheme.nsLensMetadataText,
                .paragraphStyle: Self.truncatingParagraphStyle
            ]
            let width = contentMaxX - x
            let rect = NSRect(x: x, y: yPos + (height - textHeight) / 2, width: width, height: textHeight)
            (author as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: authorAttrs
            )
        }
    }

    func drawDiagnosticCapsule(
        _ issues: [DiagnosticData],
        line: Int,
        minX: CGFloat,
        maxX: CGFloat,
        yPos: CGFloat,
        height: CGFloat,
        font: NSFont,
        textView: GoLensTextView
    ) -> NSRect? {
        guard let first = issues.first else { return nil }
        let padding: CGFloat = 6
        let iconSize: CGFloat = 12
        let gap: CGFloat = 4
        let available = maxX - minX
        let iconOnly = padding * 2 + iconSize
        guard available >= iconOnly else { return nil }

        let isTestFailure = first.message.hasPrefix("[Test Failed]")
        let isError = first.severity == 1
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let tint: NSColor = isError ? .systemRed : .systemOrange

        let rawMessage = first.message.firstIndex(where: { $0 == "\n" || $0 == "\r" })
            .map { String(first.message[..<$0]) } ?? first.message

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.truncatingParagraphStyle
        ]
        let moreAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let more: String? = issues.count > 1 ? " +\(issues.count - 1)" : nil
        let moreWidth = more.map { ceil(($0 as NSString).size(withAttributes: moreAttrs).width) } ?? 0
        let measuredLabel = ceil((rawMessage as NSString).size(withAttributes: [.font: font]).width)
        let textRoom = available - iconOnly - gap - moreWidth
        let textWidth = textRoom > 18 ? min(measuredLabel, textRoom) : 0
        let capsuleWidth = iconOnly + (textWidth > 0 ? gap + textWidth + moreWidth : 0)
        let rect = NSRect(x: minX, y: yPos + 1, width: capsuleWidth, height: max(13, height - 2))

        let shape = NSBezierPath(roundedRect: rect, xRadius: CornerRadius.small, yRadius: CornerRadius.small)
        tint.withAlphaComponent(increased ? 0.28 : 0.16).setFill()
        shape.fill()
        if increased {
            tint.setStroke()
            shape.lineWidth = Stroke.standard
            shape.stroke()
        }

        let icon = isTestFailure ? GoLensTextView.testFailureSymbol : (isError ? GoLensTextView.errorSymbol : GoLensTextView.warningSymbol)
        icon?.draw(in: NSRect(x: rect.minX + padding, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize))

        if textWidth > 0 {
            let textHeight = ceil(font.ascender - font.descender + font.leading)
            let tx = rect.minX + padding + iconSize + gap
            (rawMessage as NSString).draw(
                with: NSRect(x: tx, y: rect.midY - textHeight / 2, width: textWidth, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: textAttrs
            )
            if let more {
                (more as NSString).draw(at: NSPoint(x: tx + textWidth, y: rect.midY - textHeight / 2), withAttributes: moreAttrs)
            }
        }

        textView.issueHitRects[line] = (rect, issues)
        return rect
    }

    func presentCompactPopover(for item: OpticalLensLineItem, anchorRect: NSRect, in textView: GoLensTextView) {
        let workspace = textView.workspaceState
        workspace.activeEditorPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        workspace.activeEditorPopover = popover
        let content = OpticalLensCompactPopoverView(
            item: item,
            anchorRect: anchorRect,
            textView: textView,
            onDismiss: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: content.windowScope(workspace))
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .minX)
    }
}
