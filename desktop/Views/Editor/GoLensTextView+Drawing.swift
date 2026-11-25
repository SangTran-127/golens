import SwiftUI
import AppKit

extension GoLensTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let visibleRect = self.visibleRect
        let dirtyRect = visibleRect.intersection(rect)
        guard !dirtyRect.isEmpty else { return }
        drawMultiCursorSelections(in: dirtyRect)

        let textString = liveText
        let workspace = self.workspaceState
        let theme = workspace.currentTheme
        let systemDark = theme.resolvedIsDark
        let marginWidth = opticalMarginWidth
        let codeMinX = visibleRect.origin.x + gutterWidth
        let codeWidth = max(0, visibleRect.width - gutterWidth - marginWidth)

        let selected = selectedRange()
        let isFocusedSingleCaret = (window?.firstResponder === self) && selected.length == 0

        if textString.length == 0 {
            if isFocusedSingleCaret && !(workspace.debug.isDebugMode && workspace.debug.activeLine == 1 && workspace.debug.activePath == filePath) {
                let lineH = layoutManager.defaultLineHeight(for: font ?? lineNumberFont)
                CodeSurfaceTheme.nsCurrentLineFill.setFill()
                NSRect(x: codeMinX, y: textContainerInset.height, width: codeWidth, height: lineH).fill()
            }
            return
        }

        let caretLine = isFocusedSingleCaret ? lineAndCol(forCharacterIndex: selected.location).line : -1
        let coverageLines = workspace.fileCoverage[filePath]
        let foldedLineSet = workspace.foldedLineSets[filePath] ?? IndexSet()
        let foldedStarts = workspace.foldedStartLines[filePath] ?? []
        let profileHeat = workspace.profileHeatLines(forFile: filePath)
        let conflictRegions = mergeConflictRegions
        let ghostLine = inlineSuggestions.suggestionLine ?? -1

        let containerBand = NSRect(
            x: max(0, visibleRect.origin.x - textContainerOrigin.x),
            y: max(0, dirtyRect.minY - textContainerOrigin.y),
            width: visibleRect.width,
            height: dirtyRect.height
        )
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerBand, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineNumber = (document?.lines.line(at: visibleCharRange.location) ?? 0) + 1
        var index = visibleCharRange.location

        while index < NSMaxRange(visibleCharRange) {
            let lineRange = textString.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let isFolded = foldedLineSet.contains(lineNumber - 1)

            if !isFolded, glyphIndex < layoutManager.numberOfGlyphs {
                let (_, fullSpanRect) = lineFragmentGeometry(
                    lineRange: lineRange,
                    firstGlyphIndex: glyphIndex,
                    lineNumber: lineNumber,
                    ghostLine: ghostLine,
                    layoutManager: layoutManager
                )
                let ySpanPos = fullSpanRect.minY + textContainerInset.height
                let spanHeight = fullSpanRect.height

                let isDebugActiveLine = workspace.debug.isDebugMode &&
                    workspace.debug.activeLine == lineNumber &&
                    workspace.debug.activePath == filePath

                if isFocusedSingleCaret && lineNumber == caretLine && !isDebugActiveLine && codeWidth > 0 {
                    CodeSurfaceTheme.nsCurrentLineFill.setFill()
                    NSRect(x: codeMinX, y: ySpanPos, width: codeWidth, height: spanHeight).fill()
                }

                if isDebugActiveLine && codeWidth > 0 {
                    Self.cachedDebugLineColor.setFill()
                    NSRect(x: codeMinX, y: ySpanPos, width: codeWidth, height: spanHeight).fill()
                }

                if let isCovered = coverageLines?[lineNumber], codeWidth > 0 {
                    let tintRect = NSRect(x: codeMinX, y: ySpanPos, width: codeWidth, height: spanHeight)
                    if isCovered {
                        NSColor.systemGreen.withAlphaComponent(systemDark ? 0.05 : 0.04).setFill()
                    } else {
                        NSColor.systemRed.withAlphaComponent(systemDark ? 0.06 : 0.04).setFill()
                    }
                    tintRect.fill()
                }

                if let heat = profileHeat?[lineNumber], codeWidth > 0 {
                    let tintRect = NSRect(x: codeMinX, y: ySpanPos, width: codeWidth, height: spanHeight)
                    NSColor(DataVizTone.heatFill(fraction: heat, isDark: systemDark)).setFill()
                    tintRect.fill()
                }

                let conflictRole = conflictRegions.isEmpty ? nil : MergeConflictScanner.role(forLine: lineNumber, in: conflictRegions)
                if let conflictRole {
                    drawMergeConflictTint(conflictRole, yPos: ySpanPos, height: spanHeight, visibleRect: visibleRect, isDark: systemDark)
                }

                drawTabIndentGuides(
                    lineRange: lineRange,
                    in: textString,
                    ySpanPos: ySpanPos,
                    spanHeight: spanHeight,
                    codeMinX: codeMinX,
                    codeMaxX: codeMinX + codeWidth,
                    layoutManager: layoutManager
                )

                if foldedStarts.contains(lineNumber),
                   let fold = workspace.foldedCharRangesCache[filePath]?.first(where: { NSLocationInRange($0.location, lineRange) }) {
                    drawFoldPlaceholder(at: fold.location, layoutManager: layoutManager, textContainer: textContainer)
                }
            }

            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        drawInlineRenameOccurrences(in: dirtyRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        inlayHintManager?.drawInlineHints(in: dirtyRect)
        inlineSuggestions.draw(in: dirtyRect)
        drawEnvSecretMasks(in: dirtyRect)
        drawPinnedChrome(in: dirtyRect)
    }

    private func lineFragmentGeometry(
        lineRange: NSRange,
        firstGlyphIndex: Int,
        lineNumber: Int,
        ghostLine: Int,
        layoutManager: NSLayoutManager
    ) -> (firstFragment: NSRect, fullSpan: NSRect) {
        var firstRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyphIndex, effectiveRange: nil)
        var minY = firstRect.minY
        var maxY = firstRect.maxY
        let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        if lineGlyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: lineGlyphRange) { fragRect, _, _, _, _ in
                if fragRect.minY < minY { minY = fragRect.minY }
                if fragRect.maxY > maxY { maxY = fragRect.maxY }
            }
        }
        let extraGhost = lineNumber == ghostLine ? inlineSuggestions.extraHeight(forLine: lineNumber) : 0
        if extraGhost > 0 && abs(maxY - firstRect.maxY) < 0.5 {
            firstRect.size.height = max(1, firstRect.height - extraGhost)
        }
        let fullHeight = max(1, (maxY - minY) - extraGhost)
        let fullRect = NSRect(x: firstRect.minX, y: minY, width: firstRect.width, height: fullHeight)
        return (firstRect, fullRect)
    }

    private func inlineAnnotationGeometry(
        lineRange: NSRange,
        firstRect: NSRect,
        firstGlyphIndex: Int,
        layoutManager: NSLayoutManager
    ) -> (startX: CGFloat, yPos: CGFloat, height: CGFloat) {
        let wrap = appliedWordWrapState ?? self.workspaceState.wordWrapEnabled
        var targetFrag = firstRect
        var targetUsed = layoutManager.lineFragmentUsedRect(forGlyphAt: firstGlyphIndex, effectiveRange: nil)
        if wrap {
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if lineGlyphRange.length > 0 {
                layoutManager.enumerateLineFragments(forGlyphRange: lineGlyphRange) { fragRect, usedRect, _, _, _ in
                    targetFrag = fragRect
                    targetUsed = usedRect
                }
            }
        }
        let pad = textContainer?.lineFragmentPadding ?? 0
        let glyphEndX = max(pad, targetUsed.maxX - pad) + textContainerOrigin.x
        let endX = glyphEndX + Spacing.comfortable
        return (endX, targetFrag.minY + textContainerInset.height, max(1, targetFrag.height))
    }

    private func drawTabIndentGuides(
        lineRange: NSRange,
        in textString: NSString,
        ySpanPos: CGFloat,
        spanHeight: CGFloat,
        codeMinX: CGFloat,
        codeMaxX: CGFloat,
        layoutManager: NSLayoutManager
    ) {
        guard codeMaxX > codeMinX else { return }
        let lineEnd = NSMaxRange(lineRange)
        var tabCount = 0
        while lineRange.location + tabCount < lineEnd && textString.character(at: lineRange.location + tabCount) == 0x09 {
            tabCount += 1
        }
        guard tabCount >= 2 else { return }

        var hasContent = false
        var scanIdx = lineRange.location + tabCount
        while scanIdx < lineEnd {
            let ch = textString.character(at: scanIdx)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                hasContent = true
                break
            }
            scanIdx += 1
        }
        guard hasContent else { return }

        CodeSurfaceTheme.nsIndentGuide.setFill()
        let originX = textContainerOrigin.x
        for tabIdx in 1..<tabCount {
            let charPos = lineRange.location + tabIdx
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charPos)
            guard glyphIdx < layoutManager.numberOfGlyphs else { continue }
            let guideX = floor(layoutManager.location(forGlyphAt: glyphIdx).x + originX) + 0.5
            if guideX > codeMinX && guideX < codeMaxX {
                NSRect(x: guideX, y: ySpanPos, width: Stroke.hairline, height: spanHeight).fill()
            }
        }
    }

    private func drawPinnedChrome(in rect: NSRect) {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let visibleRect = self.visibleRect
        let dirtyRect = visibleRect.intersection(rect)
        guard !dirtyRect.isEmpty else { return }

        let gutterOriginX = visibleRect.origin.x
        let gutterRect = NSRect(x: gutterOriginX, y: visibleRect.origin.y, width: gutterWidth, height: visibleRect.height)
        let lensStyle = effectiveOpticalLensStyle
        let marginWidth = lensStyle.reservedMarginWidth
        let marginRect = NSRect(x: visibleRect.maxX - marginWidth, y: visibleRect.origin.y, width: marginWidth, height: visibleRect.height)
        let conflictRegions = mergeConflictRegions

        let needsGutterPass = dirtyRect.intersects(gutterRect)
        let needsMarginSurface = marginWidth > 0 && dirtyRect.intersects(marginRect)
        let needsMarginPass = marginWidth > 0
            ? (needsMarginSurface || !conflictRegions.isEmpty)
            : (dirtyRect.maxX > gutterOriginX + gutterWidth)
        guard needsGutterPass || needsMarginPass else { return }

        let workspace = self.workspaceState
        let theme = workspace.currentTheme
        let systemDark = theme.resolvedIsDark
        let textString = liveText

        if rect.contains(visibleRect) {
            lensHitRects.removeAll(keepingCapacity: true)
            conflictActionHitRects.removeAll(keepingCapacity: true)
            if !conflictToolTipRects.isEmpty { scheduleConflictToolTipRefresh() }
            issueHitRects.removeAll(keepingCapacity: true)
            implHitRects.removeAll(keepingCapacity: true)
            usageHitRects.removeAll(keepingCapacity: true)
            compactLensHitRects.removeAll(keepingCapacity: true)
            blameHit = nil
            renameHitRect = nil
            opticalLensMargin.resetAllAccessibilityElements()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: theme.lineNumberColor(isDark: systemDark)
        ]

        if needsGutterPass {
            let gutterClip = gutterRect.intersection(dirtyRect)
            theme.gutterBackgroundColor(isDark: systemDark).setFill()
            gutterClip.fill()

            let borderRect = NSRect(x: gutterOriginX + gutterWidth - 1, y: gutterClip.minY, width: 1, height: gutterClip.height)
            if borderRect.intersects(dirtyRect) {
                theme.gutterBorderColor(isDark: systemDark).setFill()
                borderRect.fill()
            }
        }

        if needsMarginSurface {
            opticalLensMargin.drawSurface(in: dirtyRect, visibleRect: visibleRect, marginWidth: marginWidth)
        }

        if textString.length == 0 {
            if needsGutterPass {
                let lineStr = "1" as NSString
                let size = lineStr.size(withAttributes: attrs)
                let yPos = self.textContainerInset.height
                let drawPoint = NSPoint(x: gutterOriginX + gutterWidth - size.width - 8, y: yPos)
                lineStr.draw(at: drawPoint, withAttributes: attrs)
            }
            return
        }

        let foldableStartLines = workspace.foldableStartLines[filePath] ?? []
        let testLines = workspace.fileTestLines[filePath]
        let bookmarkedLines = workspace.bookmarksByPath[filePath]
        let coverageLines = workspace.fileCoverage[filePath]
        let suggestionLine = renameSuggestion.flatMap { s in document.map { $0.lines.line(at: s.start) + 1 } } ?? -1
        let renameShortcut = renameSuggestion != nil ? KeymapStore.shared.display("editor.codeActions") : ""
        let foldedLineSet = workspace.foldedLineSets[filePath] ?? IndexSet()
        let foldedStarts = workspace.foldedStartLines[filePath] ?? []
        let issues = EditorDisplaySettings.showIssuesInline ? issuesByLine() : [:]
        let profileHeat = workspace.profileHeatLines(forFile: filePath)
        let escapeNotes = workspace.showEscapeAnalysis ? workspace.escapeAnnotations[filePath] : nil
        let hasProfileModeInFile = !(profileHeat?.isEmpty ?? true) || !(escapeNotes?.isEmpty ?? true)
        let isDebugInlineActive = workspace.debug.isDebugMode && workspace.debug.inlinePath == filePath
        let isGoFile = filePath.hasSuffix(".go")
        let fileBase = (filePath as NSString).lastPathComponent
        let isGoModFile = fileBase == "go.mod" || fileBase == "go.work"
        let pkgHasErrors = isGoFile ? workspace.packageHasErrors(filePath) : false
        let ghostLine = inlineSuggestions.suggestionLine ?? -1

        let containerBand = NSRect(
            x: max(0, visibleRect.origin.x - textContainerOrigin.x),
            y: max(0, dirtyRect.minY - textContainerOrigin.y),
            width: visibleRect.width,
            height: dirtyRect.height
        )
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerBand, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineNumber = (document?.lines.line(at: visibleCharRange.location) ?? 0) + 1
        var index = visibleCharRange.location

        while index < NSMaxRange(visibleCharRange) {
            let lineRange = textString.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let isFolded = foldedLineSet.contains(lineNumber - 1)

            if !isFolded, glyphIndex < layoutManager.numberOfGlyphs {
                let (firstRect, fullSpanRect) = lineFragmentGeometry(
                    lineRange: lineRange,
                    firstGlyphIndex: glyphIndex,
                    lineNumber: lineNumber,
                    ghostLine: ghostLine,
                    layoutManager: layoutManager
                )
                let yPos = firstRect.minY + self.textContainerInset.height
                let firstHeight = firstRect.height
                let ySpanPos = fullSpanRect.minY + self.textContainerInset.height
                let spanHeight = fullSpanRect.height
                let showsAnnotations = lineNumber != ghostLine
                let conflictRole = conflictRegions.isEmpty ? nil : MergeConflictScanner.role(forLine: lineNumber, in: conflictRegions)

                if needsGutterPass {
                    let isDebugActiveLine = workspace.debug.isDebugMode &&
                        workspace.debug.activeLine == lineNumber &&
                        workspace.debug.activePath == filePath

                    if isDebugActiveLine {
                        Self.cachedDebugLineColor.setFill()
                        NSRect(x: gutterOriginX, y: ySpanPos, width: gutterWidth - 1, height: spanHeight).fill()
                    }

                    if let isCovered = coverageLines?[lineNumber] {
                        let stripeX = gutterOriginX + 3
                        if isCovered {
                            NSColor.systemGreen.withAlphaComponent(0.75).setFill()
                            NSRect(x: stripeX, y: ySpanPos, width: 3, height: spanHeight).fill()
                        } else {
                            let gap: CGFloat = 2
                            let dashHeight = max(2, (spanHeight - gap) / 2)
                            NSColor.systemRed.withAlphaComponent(0.8).setFill()
                            NSRect(x: stripeX, y: ySpanPos, width: 3, height: dashHeight).fill()
                            NSRect(x: stripeX, y: ySpanPos + dashHeight + gap, width: 3, height: max(2, spanHeight - dashHeight - gap)).fill()
                        }
                    }

                    if let heat = profileHeat?[lineNumber] {
                        let stripeX = gutterOriginX + Self.foldColumnWidth
                        NSColor(DataVizTone.heatStroke(fraction: heat, isDark: systemDark)).setFill()
                        NSRect(x: stripeX, y: ySpanPos, width: 3, height: spanHeight).fill()
                    }

                    if let conflictRole {
                        drawMergeConflictGutterStripe(conflictRole, yPos: ySpanPos, height: spanHeight, visibleRect: visibleRect)
                    }

                    if workspace.showsSourceControlChanges, let diffType = workspace.git.activeFileDiffs[lineNumber] {
                        if diffType == .deleted {
                            let stripeWidth: CGFloat = 4
                            let markerRect = NSRect(
                                x: gutterOriginX + gutterWidth - stripeWidth,
                                y: yPos,
                                width: stripeWidth,
                                height: 2
                            )
                            NSColor.systemRed.setFill()
                            markerRect.fill()
                        } else {
                            let stripeWidth: CGFloat = 3
                            let stripeRect = NSRect(
                                x: gutterOriginX + gutterWidth - stripeWidth,
                                y: ySpanPos,
                                width: stripeWidth,
                                height: spanHeight
                            )
                            let stripeColor = diffType == .added ? NSColor.systemGreen : NSColor.secondaryLabelColor
                            stripeColor.setFill()
                            stripeRect.fill()
                        }
                    }

                    let lineStr = "\(lineNumber)" as NSString
                    let size = lineStr.size(withAttributes: attrs)
                    let drawPoint = NSPoint(x: gutterOriginX + gutterWidth - size.width - 8, y: yPos)
                    let testMark = testLines?[lineNumber].flatMap { workspace.debug.breakpoints[filePath]?.contains(lineNumber) == true ? nil : $0 }
                    let hasGoGenerateMark = testMark == nil &&
                        workspace.debug.breakpoints[filePath]?.contains(lineNumber) != true &&
                        workspace.goplsLenses[filePath]?[lineNumber]?.contains(where: { ($0.command["golensCommand"] as? String) == "goGenerate" }) == true
                    let isBookmarked = bookmarkedLines?.contains(lineNumber) == true
                    let tagRect = NSRect(
                        x: gutterOriginX + Self.foldColumnWidth + 2,
                        y: yPos + 1,
                        width: gutterWidth - Self.foldColumnWidth - 4,
                        height: firstHeight - 2
                    )

                    if isBookmarked, let bmImage = Self.cachedBookmarkSymbol {
                        let bmRect = NSRect(
                            x: gutterOriginX + (coverageLines?[lineNumber] != nil ? 7 : 3),
                            y: yPos + (firstHeight - 10) / 2,
                            width: 9,
                            height: 10
                        )
                        bmImage.draw(in: bmRect)
                    }

                    if isGoFile, let breakpoints = workspace.debug.breakpoints[filePath], breakpoints.contains(lineNumber) {
                        let spec = workspace.debug.spec(filePath, lineNumber)
                        NSColor.selectedContentBackgroundColor.withAlphaComponent(spec.isEnabled ? 1 : 0.4).setFill()
                        Self.breakpointTag(in: tagRect, logpoint: spec.isLogpoint).fill()
                        if !spec.isLogpoint && spec.hasCondition {
                            NSColor.alternateSelectedControlTextColor.setFill()
                            NSBezierPath(ovalIn: NSRect(x: tagRect.minX + 3, y: tagRect.midY - 1.5, width: 3, height: 3)).fill()
                        }
                        lineStr.draw(at: drawPoint, withAttributes: [.font: lineNumberFont, .foregroundColor: NSColor.alternateSelectedControlTextColor])
                    } else {
                        if isGoFile, workspace.hoverGutterLine == lineNumber, testMark == nil, !hasGoGenerateMark {
                            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                            Self.breakpointTag(in: tagRect, logpoint: false).fill()
                        } else if isBookmarked {
                            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                            NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3).fill()
                        }
                        if testMark == nil && !hasGoGenerateMark {
                            let lineAttrs: [NSAttributedString.Key: Any] = isBookmarked
                                ? [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
                                : attrs
                            lineStr.draw(at: drawPoint, withAttributes: lineAttrs)
                        }
                    }

                    if isDebugActiveLine, let pcSymbol = Self.cachedDebugPCSymbol {
                        let pcSize = pcSymbol.size
                        let pcRect = NSRect(
                            x: gutterOriginX + Self.foldColumnWidth + 2,
                            y: yPos + (firstHeight - pcSize.height) / 2,
                            width: pcSize.width,
                            height: pcSize.height
                        )
                        pcSymbol.draw(in: pcRect)
                    }

                    if let target = testMark {
                        let name = target.row.map { target.test + "/" + $0 } ?? target.test
                        let image: NSImage?
                        switch workspace.testStatus(target.importPath, name) {
                        case .passed: image = Self.cachedTestPassed
                        case .failed: image = Self.cachedTestFailed
                        case .skipped: image = Self.cachedTestSkipped
                        case .running: image = Self.cachedTestRunning
                        case .none: image = nil
                        }
                        let markRight = gutterOriginX + gutterWidth - 8
                        if let image {
                            image.draw(in: NSRect(x: markRight - image.size.width, y: yPos + (firstHeight - image.size.height) / 2, width: image.size.width, height: image.size.height))
                        } else {
                            Self.cachedPlayButton.draw(at: NSPoint(x: markRight - 9, y: yPos + (firstHeight - 10) / 2), from: .zero, operation: .sourceOver, fraction: 1.0)
                        }
                    } else if hasGoGenerateMark {
                        let markRight = gutterOriginX + gutterWidth - 8
                        Self.cachedPlayButton.draw(at: NSPoint(x: markRight - 9, y: yPos + (firstHeight - 10) / 2), from: .zero, operation: .sourceOver, fraction: 1.0)
                    }

                    if foldableStartLines.contains(lineNumber) {
                        let isFoldedBlock = foldedStarts.contains(lineNumber)
                        let color = isFoldedBlock ? NSColor.controlAccentColor : theme.lineNumberColor(isDark: systemDark)
                        let chevronPath = NSBezierPath()
                        chevronPath.lineWidth = 1.5
                        chevronPath.lineCapStyle = .round
                        chevronPath.lineJoinStyle = .round
                        let cx = gutterOriginX + Self.foldColumnWidth / 2
                        let cy = yPos + size.height / 2
                        if isFoldedBlock {
                            chevronPath.move(to: NSPoint(x: cx - 2, y: cy - 3.5))
                            chevronPath.line(to: NSPoint(x: cx + 2, y: cy))
                            chevronPath.line(to: NSPoint(x: cx - 2, y: cy + 3.5))
                        } else {
                            chevronPath.move(to: NSPoint(x: cx - 3.5, y: cy - 2))
                            chevronPath.line(to: NSPoint(x: cx, y: cy + 2))
                            chevronPath.line(to: NSPoint(x: cx + 3.5, y: cy - 2))
                        }
                        color.setStroke()
                        chevronPath.stroke()
                    }
                }

                if needsMarginPass {
                    implHitRects[lineNumber] = nil
                    usageHitRects[lineNumber] = nil
                    lensHitRects[lineNumber] = nil
                    conflictActionHitRects[lineNumber] = nil
                    issueHitRects[lineNumber] = nil
                    compactLensHitRects[lineNumber] = nil
                    if blameHit?.line == lineNumber { blameHit = nil }
                    if renameSuggestion == nil || lineNumber == suggestionLine { renameHitRect = nil }
                    opticalLensMargin.clearLineAccessibilityElements(lineNumber)

                    if showsAnnotations {
                        let showBlame = workspace.showInlineGitBlame
                        let activeBlame: String?
                        if showBlame,
                           let blame = workspace.activeLineGitBlame,
                           blame.path == filePath,
                           blame.line == lineNumber {
                            activeBlame = blame.text
                        } else {
                            activeBlame = nil
                        }

                        if let lensItem = OpticalLensCoordinator.lineItem(
                            lineNumber: lineNumber,
                            filePath: filePath,
                            isGoFile: isGoFile,
                            isGoModFile: isGoModFile,
                            lensStyle: lensStyle,
                            showGitBlame: showBlame,
                            conflictRole: conflictRole,
                            isDebugInlineActive: isDebugInlineActive,
                            debugValue: isDebugInlineActive ? workspace.debug.inlineValues[lineNumber] : nil,
                            hasProfileModeInFile: hasProfileModeInFile,
                            profileHeat: profileHeat?[lineNumber],
                            escapeNote: isGoFile ? escapeNotes?[lineNumber] : nil,
                            lineIssues: issues[lineNumber],
                            lensInfo: isGoFile ? workspace.codeLensCache[filePath]?[lineNumber] : nil,
                            packageHasErrors: pkgHasErrors,
                            goplsLenses: workspace.goplsLenses[filePath]?[lineNumber],
                            moduleNote: isGoModFile ? workspace.moduleNotes[filePath]?[lineNumber] : nil,
                            renameOffer: lineNumber == suggestionLine ? renameSuggestion : nil,
                            renameShortcutDisplay: renameShortcut,
                            activeLineBlame: activeBlame
                        ) {
                            let inlineAnchor: (startX: CGFloat, yPos: CGFloat, height: CGFloat)
                            if marginWidth > 0 {
                                inlineAnchor = (0, yPos, firstHeight)
                            } else {
                                inlineAnchor = inlineAnnotationGeometry(
                                    lineRange: lineRange,
                                    firstRect: firstRect,
                                    firstGlyphIndex: glyphIndex,
                                    layoutManager: layoutManager
                                )
                            }
                            opticalLensMargin.drawLineItem(
                                lensItem,
                                yPos: inlineAnchor.yPos,
                                height: inlineAnchor.height,
                                visibleRect: visibleRect,
                                marginWidth: marginWidth,
                                inlineStartX: inlineAnchor.startX,
                                textView: self
                            )
                        }
                    }
                }
            }

            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }

    private func drawEnvSecretMasks(in rect: NSRect) {
        let workspace = self.workspaceState
        guard EcosystemDocumentTools.isEnvFile(filePath),
              workspace.envSecretsMasked,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let textString = liveText
        guard textString.length > 0 else { return }

        let visibleRect = self.visibleRect
        let dirtyRect = visibleRect.intersection(rect)
        guard !dirtyRect.isEmpty else { return }

        let theme = workspace.currentTheme
        let systemDark = theme.resolvedIsDark
        let bgColor = theme.backgroundColor(isDark: systemDark).withAlphaComponent(1.0)
        let maskStr = "•••••••• (masked)" as NSString
        let maskAttrs: [NSAttributedString.Key: Any] = [
            .font: TechnicalTypography.codeCanvasNSFont(size: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let mSize = maskStr.size(withAttributes: maskAttrs)

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var index = visibleCharRange.location
        while index < NSMaxRange(visibleCharRange) {
            let lineRange = textString.lineRange(for: NSRange(location: index, length: 0))
            let rawLineSub = textString.substring(with: lineRange)
            let rawLine = rawLineSub.trimmingCharacters(in: .whitespacesAndNewlines)

            if !rawLine.hasPrefix("#"), let eqIdx = rawLine.firstIndex(of: "=") {
                let rawKey = String(rawLine[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let key = rawKey.hasPrefix("export ") ? String(rawKey.dropFirst(7)).trimmingCharacters(in: .whitespaces) : rawKey
                let val = String(rawLine[rawLine.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty, EcosystemDocumentTools.isSensitiveEnvKey(key) {
                    let nsLine = rawLineSub as NSString
                    let eqLoc = nsLine.range(of: "=").location
                    if eqLoc != NSNotFound {
                        let valStart = lineRange.location + eqLoc + 1
                        var contentEnd = NSMaxRange(lineRange)
                        while contentEnd > valStart {
                            let ch = textString.character(at: contentEnd - 1)
                            if ch == 10 || ch == 13 {
                                contentEnd -= 1
                            } else {
                                break
                            }
                        }
                        if contentEnd > valStart {
                            let valCharRange = NSRange(location: valStart, length: contentEnd - valStart)
                            let valGlyphRange = layoutManager.glyphRange(forCharacterRange: valCharRange, actualCharacterRange: nil)
                            if valGlyphRange.location < layoutManager.numberOfGlyphs {
                                var valRect = layoutManager.boundingRect(forGlyphRange: valGlyphRange, in: textContainer)
                                valRect.origin.x += self.textContainerOrigin.x
                                valRect.origin.y += self.textContainerOrigin.y

                                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: valGlyphRange.location, effectiveRange: nil)
                                let yPos = lineRect.minY + self.textContainerOrigin.y
                                let pillWidth = mSize.width + 14
                                let coverWidth = max(valRect.width + 8, pillWidth + 8)
                                let coverHeight = max(lineRect.height, valRect.height)

                                let coverRect = NSRect(
                                    x: valRect.minX - 1,
                                    y: min(yPos, valRect.minY),
                                    width: coverWidth,
                                    height: coverHeight
                                )
                                bgColor.setFill()
                                coverRect.fill()

                                let pillHeight = max(15, min(lineRect.height - 2, mSize.height + 4))
                                let pillRect = NSRect(
                                    x: valRect.minX + 2,
                                    y: yPos + (lineRect.height - pillHeight) / 2,
                                    width: pillWidth,
                                    height: pillHeight
                                )
                                let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
                                NSColor.quaternaryLabelColor.setFill()
                                pillPath.fill()
                                NSColor.separatorColor.setStroke()
                                pillPath.lineWidth = 0.5
                                pillPath.stroke()

                                maskStr.draw(
                                    at: NSPoint(x: pillRect.minX + 7, y: pillRect.midY - mSize.height / 2),
                                    withAttributes: maskAttrs
                                )
                            }
                        }
                    }
                }
            }

            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }

    static let foldPlaceholderWidth: CGFloat = 24

    func drawFoldPlaceholder(at charIndex: Int, layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let capsule = NSRect(x: box.minX + 2, y: box.midY - 7, width: Self.foldPlaceholderWidth - 4, height: 14)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 7, yRadius: 7).fill()
        let dots = "…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let size = dots.size(withAttributes: attrs)
        dots.draw(at: NSPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2), withAttributes: attrs)
    }
}
