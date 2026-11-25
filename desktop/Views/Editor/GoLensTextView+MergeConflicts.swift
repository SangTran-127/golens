import AppKit
import SwiftUI

enum MergeConflictLensAction: Equatable {
    case resolve(MergeConflictResolution)
    case compare

    static let all: [MergeConflictLensAction] = [
        .resolve(.left), .resolve(.right), .resolve(.leftThenRight), .resolve(.rightThenLeft), .compare
    ]

    var title: String {
        switch self {
        case .resolve(let resolution): return resolution.lensTitle
        case .compare: return "Compare"
        }
    }

    func tooltip(for region: MergeConflictRegion?, isRebase: Bool) -> String {
        switch self {
        case .resolve(let resolution):
            return resolution.tooltip(currentLabel: region?.currentLabel ?? "", incomingLabel: region?.incomingLabel ?? "", isRebase: isRebase)
        case .compare:
            return "Compare both versions side by side"
        }
    }

    var menuTitle: String {
        switch self {
        case .resolve(let resolution): return resolution.actionName
        case .compare: return "Compare Changes…"
        }
    }

    var menuIcon: String {
        switch self {
        case .resolve(.left): return "arrow.left.circle"
        case .resolve(.right): return "arrow.right.circle"
        case .resolve(.leftThenRight), .resolve(.rightThenLeft): return "arrow.triangle.merge"
        case .compare: return "arrow.left.arrow.right"
        }
    }
}

extension GoLensTextView: NSViewToolTipOwner {
    var mergeConflictRegions: [MergeConflictRegion] {
        self.workspaceState.git.conflictRegions[filePath] ?? []
    }

    func drawMergeConflictTint(_ role: MergeConflictLineRole, yPos: CGFloat, height: CGFloat, visibleRect: NSRect, isDark: Bool) {
        let contrast: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.6 : 1
        let color: NSColor
        let alpha: CGFloat
        switch role {
        case .currentMarker:
            color = .systemTeal
            alpha = isDark ? 0.22 : 0.16
        case .current:
            color = .systemTeal
            alpha = isDark ? 0.10 : 0.07
        case .incomingMarker:
            color = .systemIndigo
            alpha = isDark ? 0.22 : 0.16
        case .incoming:
            color = .systemIndigo
            alpha = isDark ? 0.10 : 0.07
        case .baseMarker, .separator:
            color = .systemGray
            alpha = isDark ? 0.16 : 0.12
        case .base:
            color = .systemGray
            alpha = isDark ? 0.08 : 0.06
        }
        color.withAlphaComponent(min(1, alpha * contrast)).setFill()
        let codeWidth = max(0, visibleRect.width - gutterWidth - opticalMarginWidth)
        NSRect(x: visibleRect.origin.x + gutterWidth, y: yPos, width: codeWidth, height: height).fill()
    }

    func drawMergeConflictGutterStripe(_ role: MergeConflictLineRole, yPos: CGFloat, height: CGFloat, visibleRect: NSRect) {
        let color: NSColor
        switch role {
        case .currentMarker, .current:
            color = .systemTeal
        case .incomingMarker, .incoming:
            color = .systemIndigo
        case .baseMarker, .separator, .base:
            color = .systemGray
        }
        color.withAlphaComponent(0.8).setFill()
        NSRect(x: visibleRect.origin.x + Self.foldColumnWidth, y: yPos, width: 3, height: height).fill()
    }

    func scheduleConflictToolTipRefresh() {
        guard !conflictToolTipRefreshPending else { return }
        conflictToolTipRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshConflictToolTips()
        }
    }

    private func refreshConflictToolTips() {
        conflictToolTipRefreshPending = false
        var rects: [NSRect] = []
        for lineRects in conflictActionHitRects.values {
            for entry in lineRects { rects.append(entry.0) }
        }
        rects.sort { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        guard rects != conflictToolTipRects else { return }
        conflictToolTipRects = rects
        removeAllToolTips()
        for rect in rects {
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        mergeConflictTooltip(at: point) ?? ""
    }

    func mergeConflictAction(at point: NSPoint) -> (line: Int, action: MergeConflictLensAction, rect: NSRect)? {
        for (line, rects) in conflictActionHitRects {
            if let hit = rects.first(where: { $0.0.insetBy(dx: -2, dy: -2).contains(point) }) {
                return (line, hit.1, hit.0)
            }
        }
        return nil
    }

    func mergeConflictTooltip(at point: NSPoint) -> String? {
        guard let hit = mergeConflictAction(at: point) else { return nil }
        let regions = mergeConflictRegions
        let region = MergeConflictScanner.regionIndex(containingLine: hit.line, in: regions).map { regions[$0] }
        return hit.action.tooltip(for: region, isRebase: self.workspaceState.git.mergeOperation == .rebase)
    }

    func performMergeConflictAction(_ action: MergeConflictLensAction, line: Int, anchor: NSRect?) {
        self.workspaceState.activeTextView = self
        switch action {
        case .resolve(let resolution):
            self.workspaceState.resolveMergeConflict(atLine: line, in: filePath, with: resolution)
        case .compare:
            showMergeConflictComparison(line: line, anchor: anchor)
        }
    }

    func showMergeConflictComparison(line: Int, anchor: NSRect?) {
        guard let session = document, let layoutManager, let textContainer else { return }
        let text = session.storage.mutableString
        let regions = MergeConflictScanner.scan(text)
        guard let index = MergeConflictScanner.regionIndex(containingLine: line, in: regions) else { return }
        let region = regions[index]
        let rect: NSRect
        if let anchor {
            rect = anchor
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: region.range.location, length: 0), actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: textContainer)
            rect = box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        self.workspaceState.activeEditorPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        self.workspaceState.activeEditorPopover = popover
        let path = filePath
        let workspace = self.workspaceState
        let view = MergeConflictCompareView(
            current: text.substring(with: region.currentRange),
            incoming: text.substring(with: region.incomingRange),
            currentLabel: region.currentLabel,
            incomingLabel: region.incomingLabel,
            onResolve: { [weak self, weak popover] resolution in
                popover?.performClose(nil)
                workspace.activeTextView = self
                workspace.resolveMergeConflict(atLine: line, in: path, with: resolution)
            },
            onClose: { [weak popover] in popover?.performClose(nil) },
            isRebase: self.workspaceState.git.mergeOperation == .rebase
        )
        popover.contentViewController = NSHostingController(rootView: view.windowScope(workspace))
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    private func caretLine() -> Int {
        guard let session = document else { return 0 }
        return session.lines.line(at: min(selectedRange().location, session.length)) + 1
    }

    func addMergeConflictMenuItems(to menu: NSMenu, characterIndex: Int) {
        let regions = mergeConflictRegions
        guard !regions.isEmpty, let session = document else { return }
        let location = characterIndex != NSNotFound ? characterIndex : selectedRange().location
        let line = session.lines.line(at: min(location, session.length)) + 1
        if let index = MergeConflictScanner.regionIndex(containingLine: line, in: regions) {
            let startLine = regions[index].startLine
            for (tag, action) in MergeConflictLensAction.all.enumerated() {
                let item = NSMenuItem(title: action.menuTitle, action: #selector(contextMergeConflictAction(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: action.menuIcon, accessibilityDescription: nil)
                item.target = self
                item.tag = tag
                item.representedObject = startLine
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let next = NSMenuItem(title: "Next Conflict", action: #selector(contextNextMergeConflict(_:)), keyEquivalent: "")
        next.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        next.target = self
        menu.addItem(next)
        let previous = NSMenuItem(title: "Previous Conflict", action: #selector(contextPreviousMergeConflict(_:)), keyEquivalent: "")
        previous.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
        previous.target = self
        menu.addItem(previous)
        menu.addItem(.separator())
    }

    @objc func contextMergeConflictAction(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int,
              MergeConflictLensAction.all.indices.contains(sender.tag) else { return }
        performMergeConflictAction(MergeConflictLensAction.all[sender.tag], line: line, anchor: nil)
    }

    @objc func contextNextMergeConflict(_ sender: Any?) {
        self.workspaceState.activeTextView = self
        self.workspaceState.navigateMergeConflict(in: filePath, forward: true)
    }

    @objc func contextPreviousMergeConflict(_ sender: Any?) {
        self.workspaceState.activeTextView = self
        self.workspaceState.navigateMergeConflict(in: filePath, forward: false)
    }

    @objc func mergeConflictRegionsDidChange(_ notification: Notification) {
        guard (notification.object as? String) == filePath else { return }
        conflictActionHitRects.removeAll()
        scheduleConflictToolTipRefresh()
        needsDisplay = true
    }

    func mergeConflictAccessibilityActions() -> [NSAccessibilityCustomAction] {
        let regions = mergeConflictRegions
        guard !regions.isEmpty else { return [] }
        var actions: [NSAccessibilityCustomAction] = []
        if let index = MergeConflictScanner.regionIndex(containingLine: caretLine(), in: regions) {
            let startLine = regions[index].startLine
            for action in MergeConflictLensAction.all {
                actions.append(NSAccessibilityCustomAction(name: action.menuTitle) { [weak self] in
                    self?.performMergeConflictAction(action, line: startLine, anchor: nil)
                    return true
                })
            }
        }
        actions.append(NSAccessibilityCustomAction(name: "Next Conflict") { [weak self] in
            self?.contextNextMergeConflict(nil)
            return true
        })
        actions.append(NSAccessibilityCustomAction(name: "Previous Conflict") { [weak self] in
            self?.contextPreviousMergeConflict(nil)
            return true
        })
        return actions
    }
}
