import AppKit

extension GoLensTextView {
    static let issueFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let issueParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let issueTextAttrs: [NSAttributedString.Key: Any] = [
        .font: issueFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: issueParagraphStyle
    ]
    private static let issueMoreAttrs: [NSAttributedString.Key: Any] = [
        .font: issueFont,
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    private static let issueTextHeight: CGFloat = ceil(issueFont.ascender - issueFont.descender + issueFont.leading)
    private static var widthCache: [String: CGFloat] = [:]
    private static var firstLineCache: [String: String] = [:]

    private static func measuredWidth(for text: String) -> CGFloat {
        if let cached = widthCache[text] { return cached }
        if widthCache.count >= 512 { widthCache.removeAll(keepingCapacity: true) }
        let width = ceil((text as NSString).size(withAttributes: issueTextAttrs).width)
        widthCache[text] = width
        return width
    }

    private static func firstLine(of message: String) -> String {
        if let cached = firstLineCache[message] { return cached }
        if firstLineCache.count >= 512 { firstLineCache.removeAll(keepingCapacity: true) }
        let line = message.firstIndex(where: { $0 == "\n" || $0 == "\r" }).map { String(message[..<$0]) } ?? message
        firstLineCache[message] = line
        return line
    }

    static func issueSymbol(_ severity: Int) -> NSImage? {
        let name = severity == 1 ? StatusTone.failure.symbol : StatusTone.warning.symbol
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.preferringMulticolor())
        return NSImage(systemSymbolName: name, accessibilityDescription: severity == 1 ? "Error" : "Warning")?.withSymbolConfiguration(config)
    }

    static let errorSymbol = issueSymbol(1)
    static let warningSymbol = issueSymbol(2)
    static let testFailureSymbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.preferringMulticolor())
        return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Test Failure")?.withSymbolConfiguration(config)
    }()

    func issuesByLine() -> [Int: [DiagnosticData]] {
        let workspace = self.workspaceState
        let diags = workspace.diagnosticsForPath(filePath)
        let showInlineSafety = EditorDisplaySettings.showInlineSafety
        let findings = showInlineSafety ? workspace.safetyFindings : []
        let testFailures = workspace.testFailureAnnotationsForPath(filePath)
        if diags.isEmpty && findings.isEmpty && testFailures.isEmpty {
            if issueCache.map({ !$0.source.isEmpty }) ?? true {
                issueCache = ([], [:])
                issueHitRects.removeAll(keepingCapacity: true)
            }
            issueInputs = nil
            return [:]
        }
        if let cache = issueCache, let inputs = issueInputs, inputs.path == filePath,
           inputs.showSafety == showInlineSafety,
           inputs.diags.hasSameStorage(as: diags),
           inputs.safety.hasSameStorage(as: findings),
           inputs.failures.hasSameStorage(as: testFailures) {
            return cache.byLine
        }
        issueInputs = (filePath, diags, findings, testFailures, showInlineSafety)
        var safetyDiags: [DiagnosticData] = []
        if !findings.isEmpty {
            for finding in findings where finding.file == filePath && finding.line >= 1 {
                safetyDiags.append(
                    DiagnosticData(
                        line: finding.line - 1,
                        col: max(0, finding.col - 1),
                        endLine: finding.line - 1,
                        endCol: max(1, finding.col),
                        severity: finding.severity == 1 ? 1 : 2,
                        message: finding.title
                    )
                )
            }
        }
        var failureDiags: [DiagnosticData] = []
        for tf in testFailures where tf.line >= 1 {
            let msg = "[Test Failed] \(tf.testName): \(tf.message)"
            failureDiags.append(
                DiagnosticData(
                    line: tf.line - 1,
                    col: 0,
                    endLine: tf.line - 1,
                    endCol: 1,
                    severity: 1,
                    message: msg
                )
            )
        }
        let cacheSource = diags + safetyDiags + failureDiags
        if let cache = issueCache, cache.source == cacheSource { return cache.byLine }
        var byLine: [Int: [DiagnosticData]] = [:]
        for d in diags where d.severity == 1 || d.severity == 2 {
            byLine[d.line + 1, default: []].append(d)
        }
        for sd in safetyDiags {
            let lineKey = sd.line + 1
            if !(byLine[lineKey]?.contains(where: { $0.message == sd.message }) ?? false) {
                byLine[lineKey, default: []].append(sd)
            }
        }
        for fd in failureDiags {
            let lineKey = fd.line + 1
            if !(byLine[lineKey]?.contains(where: { $0.message == fd.message }) ?? false) {
                byLine[lineKey, default: []].insert(fd, at: 0)
            }
        }
        for key in byLine.keys { byLine[key]?.sort { $0.severity < $1.severity } }
        issueCache = (cacheSource, byLine)
        issueHitRects.removeAll(keepingCapacity: true)
        return byLine
    }

    func drawIssueAnnotation(_ issues: [DiagnosticData], line: Int, minX: CGFloat, y: CGFloat, height: CGFloat, maxX: CGFloat) {
        guard let first = issues.first, maxX > gutterWidth + 8 else { return }
        let padding: CGFloat = 6, iconSize: CGFloat = 12, gap: CGFloat = 4
        let available = maxX - minX
        let iconOnly = padding * 2 + iconSize
        guard available >= iconOnly else { return }
        let isTestFailure = first.message.hasPrefix("[Test Failed]")
        let isError = first.severity == 1
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let tint: NSColor = isError ? .systemRed : .systemOrange
        let label = Self.firstLine(of: first.message)
        let more: String? = issues.count > 1 ? "  +\(issues.count - 1)" : nil
        let moreWidth = more.map { Self.measuredWidth(for: $0) } ?? 0
        let textRoom = available - iconOnly - gap - moreWidth
        let textWidth = textRoom > 24 ? min(Self.measuredWidth(for: label), textRoom) : 0
        let width = iconOnly + (textWidth > 0 ? gap + textWidth + moreWidth : 0)
        let rect = NSRect(x: max(minX, maxX - width), y: y + 1, width: width, height: height - 2)

        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        tint.withAlphaComponent(increased ? 0.28 : 0.16).setFill()
        shape.fill()
        if increased {
            tint.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let icon = isTestFailure ? Self.testFailureSymbol : (isError ? Self.errorSymbol : Self.warningSymbol)
        icon?.draw(in: NSRect(x: rect.minX + padding, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize))
        if textWidth > 0 {
            let textHeight = Self.issueTextHeight
            let x = rect.minX + padding + iconSize + gap
            (label as NSString).draw(with: NSRect(x: x, y: rect.midY - textHeight / 2, width: textWidth, height: textHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: Self.issueTextAttrs)
            if let more {
                (more as NSString).draw(at: NSPoint(x: x + textWidth, y: rect.midY - textHeight / 2), withAttributes: Self.issueMoreAttrs)
            }
        }
        issueHitRects[line] = (rect, issues)
    }

    func issue(at point: NSPoint) -> (line: Int, rect: NSRect, issues: [DiagnosticData])? {
        issueHitRects.first { $0.value.0.insetBy(dx: -2, dy: -2).contains(point) }.map { ($0.key, $0.value.0, $0.value.1) }
    }
}
