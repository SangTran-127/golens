import SwiftUI
import AppKit
import GoLensFoundation

enum DisplayDiffItem: Identifiable {
    case collapsedBlock(id: String, lineCount: Int, startLine: Int, endLine: Int)
    case hunkHeader(id: String, ordinal: Int, leftStart: Int?, rightStart: Int?, hunk: GitDiffHunk?)
    case line(AlignedLine)

    var id: String {
        switch self {
        case .collapsedBlock(let id, _, _, _):
            return id
        case .hunkHeader(let id, _, _, _, _):
            return id
        case .line(let line):
            return line.id
        }
    }
}

enum DiffRenderBlock: Identifiable {
    case collapsed(id: String, count: Int, startLine: Int, endLine: Int)
    case hunk(id: String, ordinal: Int, leftStart: Int?, rightStart: Int?, hunk: GitDiffHunk?)
    case lines(id: String, lines: [AlignedLine])

    var id: String {
        switch self {
        case .collapsed(let id, _, _, _):
            return id
        case .hunk(let id, _, _, _, _):
            return id
        case .lines(let id, _):
            return id
        }
    }

    static func grouped(from items: [DisplayDiffItem], maxLinesPerBlock: Int = 120) -> [DiffRenderBlock] {
        var blocks: [DiffRenderBlock] = []
        var pending: [AlignedLine] = []
        var blockIndex = 0

        func flushPending() {
            guard !pending.isEmpty else { return }
            let firstId = pending[0].id
            blocks.append(.lines(id: "diff-lines-\(blockIndex)-\(firstId)", lines: pending))
            blockIndex += 1
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            switch item {
            case .collapsedBlock(let id, let count, let startLine, let endLine):
                flushPending()
                blocks.append(.collapsed(id: id, count: count, startLine: startLine, endLine: endLine))
            case .hunkHeader(let id, let ordinal, let leftStart, let rightStart, let hunk):
                flushPending()
                blocks.append(.hunk(id: id, ordinal: ordinal, leftStart: leftStart, rightStart: rightStart, hunk: hunk))
            case .line(let line):
                pending.append(line)
                if pending.count >= maxLinesPerBlock {
                    flushPending()
                }
            }
        }
        flushPending()
        return blocks
    }
}

struct DiffCodeColumnLayout: Layout {
    var minWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var maxIdealWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            if ideal.width > maxIdealWidth {
                maxIdealWidth = ideal.width
            }
            totalHeight += ideal.height
        }
        let width = max(minWidth, proposal.width ?? 0, maxIdealWidth)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let h = subview.sizeThatFits(.unspecified).height
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: h)
            )
            y += h
        }
    }
}

struct DiffCodeViewport<Content: View>: View {
    let blockHeight: CGFloat
    let contentWidth: CGFloat
    let scrollOffset: CGFloat
    let onViewportWidthChange: (CGFloat) -> Void
    let onMeasuredWidthChange: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let viewportWidth = geo.size.width
            let metrics = DiffHorizontalScrollMetrics(
                contentWidth: contentWidth,
                viewportWidth: viewportWidth,
                offset: scrollOffset
            )
            DiffCodeColumnLayout(minWidth: max(viewportWidth, contentWidth)) {
                content()
            }
            .background(
                GeometryReader { innerGeo in
                    Color.clear
                        .onAppear {
                            onMeasuredWidthChange(innerGeo.size.width)
                        }
                        .onChange(of: innerGeo.size.width) { _, newWidth in
                            onMeasuredWidthChange(newWidth)
                        }
                }
            )
            .offset(x: -metrics.clampedOffset)
            .onAppear {
                onViewportWidthChange(viewportWidth)
            }
            .onChange(of: viewportWidth) { _, newWidth in
                onViewportWidthChange(newWidth)
            }
        }
        .frame(height: blockHeight)
        .clipped()
    }
}

struct DiffHorizontalScroller: NSViewRepresentable {
    let metrics: DiffHorizontalScrollMetrics
    let accessibilityLabel: String
    let onOffsetChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: metrics, onOffsetChange: onOffsetChange)
    }

    func makeNSView(context: Context) -> DiffHorizontalScrollerHostNSView {
        let host = DiffHorizontalScrollerHostNSView()
        host.scroller.target = context.coordinator
        host.scroller.action = #selector(Coordinator.scrollerChanged(_:))
        host.scroller.setAccessibilityLabel(accessibilityLabel)
        host.apply(metrics: metrics)
        return host
    }

    func updateNSView(_ nsView: DiffHorizontalScrollerHostNSView, context: Context) {
        context.coordinator.metrics = metrics
        context.coordinator.onOffsetChange = onOffsetChange
        nsView.scroller.setAccessibilityLabel(accessibilityLabel)
        nsView.apply(metrics: metrics)
    }

    final class Coordinator: NSObject {
        var metrics: DiffHorizontalScrollMetrics
        var onOffsetChange: (CGFloat) -> Void

        init(metrics: DiffHorizontalScrollMetrics, onOffsetChange: @escaping (CGFloat) -> Void) {
            self.metrics = metrics
            self.onOffsetChange = onOffsetChange
        }

        @objc func scrollerChanged(_ sender: NSScroller) {
            guard metrics.maxOffset > 0 else { return }
            if let stepped = DiffHorizontalScrollMetrics.steppedOffset(
                current: metrics.clampedOffset,
                maxOffset: metrics.maxOffset,
                viewportWidth: metrics.viewportWidth,
                part: sender.hitPart
            ) {
                onOffsetChange(stepped)
            } else if sender.hitPart == .knob || sender.hitPart == .knobSlot || sender.hitPart == .noPart {
                onOffsetChange(DiffHorizontalScrollMetrics.offset(fromNormalized: sender.doubleValue, maxOffset: metrics.maxOffset))
            }
        }
    }
}

final class DiffHorizontalScrollerHostNSView: NSView {
    let scrollerHeight = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
    let scroller: NSScroller

    override init(frame frameRect: NSRect) {
        let h = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let s = NSScroller(frame: NSRect(x: 0, y: 0, width: 320, height: h))
        s.controlSize = .small
        s.scrollerStyle = .legacy
        s.isEnabled = true
        s.isContinuous = true
        self.scroller = s
        super.init(frame: frameRect)
        addSubview(s)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width, scrollerHeight + 4)
        let y = floor((bounds.height - scrollerHeight) * 0.5)
        scroller.frame = NSRect(x: 0, y: y, width: width, height: scrollerHeight)
    }

    func apply(metrics: DiffHorizontalScrollMetrics) {
        scroller.isEnabled = metrics.needsScrollbar
        if abs(scroller.knobProportion - metrics.knobProportion) > 0.0005 {
            scroller.knobProportion = metrics.knobProportion
        }
        if abs(scroller.doubleValue - metrics.normalizedValue) > 0.0005 {
            scroller.doubleValue = metrics.normalizedValue
        }
    }
}

struct DiffHorizontalWheelCatcher: NSViewRepresentable {
    enum Mode {
        case single
        case split
    }

    let mode: Mode
    let leadingMetrics: DiffHorizontalScrollMetrics
    let trailingMetrics: DiffHorizontalScrollMetrics
    let onLeadingOffsetChange: (CGFloat) -> Void
    let onTrailingOffsetChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> DiffWheelAnchorNSView {
        let view = DiffWheelAnchorNSView()
        updateState(on: view)
        return view
    }

    func updateNSView(_ nsView: DiffWheelAnchorNSView, context: Context) {
        updateState(on: nsView)
    }

    private func updateState(on view: DiffWheelAnchorNSView) {
        view.mode = mode
        view.leadingMetrics = leadingMetrics
        view.trailingMetrics = trailingMetrics
        view.onLeadingOffsetChange = onLeadingOffsetChange
        view.onTrailingOffsetChange = onTrailingOffsetChange
    }
}

final class DiffWheelAnchorNSView: NSView {
    private enum Side {
        case leading
        case trailing
    }

    var mode: DiffHorizontalWheelCatcher.Mode = .single
    var leadingMetrics = DiffHorizontalScrollMetrics(contentWidth: 0, viewportWidth: 0, offset: 0)
    var trailingMetrics = DiffHorizontalScrollMetrics(contentWidth: 0, viewportWidth: 0, offset: 0)
    var onLeadingOffsetChange: ((CGFloat) -> Void)?
    var onTrailingOffsetChange: ((CGFloat) -> Void)?

    private var monitor: Any?
    private var lockedSide: Side?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
        }
    }

    deinit {
        removeMonitor()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        lockedSide = nil
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window,
              window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 1,
              bounds.height > 1 else {
            return event
        }

        let windowPoint: NSPoint
        if let eventWindow = event.window {
            guard eventWindow === window else { return event }
            windowPoint = event.locationInWindow
        } else {
            let activeWin = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
            let targetWin = (activeWin?.attachedSheet?.isVisible == true) ? activeWin?.attachedSheet : activeWin
            guard targetWin === window else { return event }
            windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
        }

        let point = convert(windowPoint, from: nil)
        let inGestureContinuation = lockedSide != nil && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
        guard bounds.contains(point) || inGestureContinuation else {
            return event
        }

        let targetSide: Side
        switch mode {
        case .single:
            targetSide = .leading
        case .split:
            if event.phase == .began {
                let resolved: Side = point.x < bounds.midX ? .leading : .trailing
                lockedSide = resolved
                targetSide = resolved
            } else if let lockedSide {
                targetSide = lockedSide
            } else {
                targetSide = point.x < bounds.midX ? .leading : .trailing
            }
        }

        let finishedDirect = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        let finishedMomentum = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
        let shouldClearLock = finishedMomentum || (finishedDirect && event.momentumPhase.isEmpty)
        defer {
            if shouldClearLock {
                lockedSide = nil
            }
        }

        let metrics = targetSide == .leading ? leadingMetrics : trailingMetrics
        guard metrics.maxOffset > 0 else {
            return event
        }

        guard let adjusted = DiffHorizontalScrollMetrics.wheelAdjustedOffset(
            current: metrics.clampedOffset,
            maxOffset: metrics.maxOffset,
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            shiftHeld: event.modifierFlags.contains(.shift)
        ) else {
            return event
        }

        if abs(adjusted.newOffset - metrics.clampedOffset) > 0.1 {
            if targetSide == .leading {
                onLeadingOffsetChange?(adjusted.newOffset)
            } else {
                onTrailingOffsetChange?(adjusted.newOffset)
            }
        }

        return adjusted.consumedVerticalAsHorizontal ? nil : event
    }
}

extension View {
    @ViewBuilder
    func jumpToCodeAccessibility(enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            self.accessibilityAction(named: "Jump to Line in Code Editor", action)
        } else {
            self
        }
    }

    @ViewBuilder
    func lineSelectionAccessibility(refs: [GitPatchLineRef], selected: Set<GitPatchLineRef>, enabled: Bool, toggle: @escaping () -> Void) -> some View {
        if enabled && !refs.isEmpty {
            let isSelected = refs.allSatisfy { selected.contains($0) }
            self
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: isSelected ? "Deselect Line" : "Select Line", toggle)
        } else {
            self
        }
    }
}

struct DiffControls: View {
    let filePath: String
    @Environment(\.windowWorkspace) private var workspace

    private var changedFile: GitChangedFile? {
        let wantsStaged = workspace.effectiveDiffSource(for: filePath) == .staged
        let entries = workspace.git.changedFiles.filter { $0.absolutePath == filePath }
        return entries.first(where: { $0.isStaged == wantsStaged }) ?? entries.first
    }

    private var isConflicted: Bool {
        changedFile?.status == "U" || workspace.git.conflictedPaths.contains(filePath)
    }

    var body: some View {
        HStack(spacing: Spacing.standard) {
            Picker("Layout", selection: Bindable(workspace).diffStyle) {
                ForEach(GitDiffView.DiffStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Diff Layout")
            .help("Switch between Unified and Side-by-Side diff")

            if workspace.git.activeCommitDiffContext == nil {
                if isConflicted {
                    Button("Resolve in Editor") {
                        workspace.setEditorMode(.code, for: filePath)
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Open this file in the Code Editor to resolve merge conflicts")
                } else {
                    let changeState = workspace.gitChangeState(for: filePath)
                    if changeState.hasStaged && changeState.hasUnstaged {
                        Picker("Changes", selection: Binding(
                            get: { workspace.effectiveDiffSource(for: filePath) },
                            set: { workspace.setDiffSource($0, for: filePath) }
                        )) {
                            Text("Unstaged").tag(GitDiffSource.unstaged)
                            Text("Staged").tag(GitDiffSource.staged)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Show the changes that aren’t staged yet, or the changes staged for the next commit")
                    }

                    if let changedFile {
                        Button(changedFile.isStaged ? "Unstage" : "Stage") {
                            changedFile.isStaged ? workspace.unstageFile(filePath) : workspace.stageFile(filePath)
                        }
                        .fixedSize()
                        .help(changedFile.isStaged ? "Unstage file" : "Stage file")

                        Button("Discard", role: .destructive) {
                            workspace.confirmDiscard(changedFile)
                        }
                        .fixedSize()
                        .help("Discard changes to this file")
                    }
                }
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }
}
