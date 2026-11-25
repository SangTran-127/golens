import SwiftUI
import AppKit

struct TraceSpan: Codable, Identifiable, Hashable {
    var id: String { "\(state)-\(startNs)-\(endNs)" }
    let state: String
    let startNs: Int64
    let endNs: Int64
    let durationNs: Int64
    let reason: String?
    let file: String?
    let line: Int?
    let function: String?

    var traceStateKind: DataVizTone.TraceStateKind? {
        switch state {
        case "running":
            return .running
        case "runnable":
            return .runnable
        case "syscall":
            return .syscall
        case "waiting", "blocked":
            return .blocked
        case "gc":
            return .gc
        default:
            return nil
        }
    }

    func stateColor(isDark: Bool) -> Color {
        if let kind = traceStateKind {
            return kind.color(isDark: isDark)
        }
        return ChromeColor.textSecondary
    }
}

struct GoroutineTimelineLane: Codable, Identifiable, Hashable {
    var id: UInt64 { goroutineId }
    let goroutineId: UInt64
    let name: String
    let spans: [TraceSpan]
    let totalActiveNs: Int64
    let totalWaitNs: Int64
    let eventCount: Int
}

struct CausationLink: Codable, Identifiable, Hashable {
    var id: String { "\(fromG)->\(toG)@\(timestampNs)" }
    let fromG: UInt64
    let toG: UInt64
    let timestampNs: Int64
    let reason: String?
    let file: String?
    let line: Int?
    let function: String?
}

struct TraceResult: Codable {
    let startNs: Int64
    let endNs: Int64
    let totalDurationNs: Int64
    let totalGoroutines: Int
    let lanes: [GoroutineTimelineLane]
    let causationLinks: [CausationLink]
    let gcPeriods: [TraceSpan]?
    let truncated: Bool
    let error: String?
}

struct TraceLegendStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let isDark = colorScheme == .dark
        ViewThatFits(in: .horizontal) {
            legendRow(isDark: isDark, compact: false)
            legendRow(isDark: isDark, compact: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trace states: Running, Runnable, Syscall, Waiting, GC")
    }

    private func legendRow(isDark: Bool, compact: Bool) -> some View {
        HStack(spacing: Spacing.standard) {
            ForEach(DataVizTone.TraceStateKind.allCases, id: \.rawValue) { kind in
                HStack(spacing: Spacing.compact) {
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(kind.color(isDark: isDark))
                        .overlay {
                            if differentiateWithoutColor {
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .strokeBorder(ChromeColor.textSecondary, lineWidth: Stroke.standard)
                            }
                        }
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)

                    Text(legendLabel(for: kind, compact: compact))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func legendLabel(for kind: DataVizTone.TraceStateKind, compact: Bool) -> String {
        if compact {
            return kind.shortCode
        }
        return differentiateWithoutColor ? "\(kind.label) (\(kind.shortCode))" : kind.label
    }
}

struct TraceTimelineView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @Binding var zoomScale: Double
    @Binding var filterText: String
    @Binding var showCausationArrows: Bool
    var openTraceTrigger: Int = 0
    var fitZoomTrigger: Int = 0

    @State private var isLoading: Bool = false
    @State private var selectedLane: GoroutineTimelineLane? = nil
    @State private var selectedSpan: TraceSpan? = nil
    @State private var hoveredSpan: TraceSpan? = nil
    @State private var didFitLoadedTrace: Bool = false

    private let laneHeight: CGFloat = 28.0
    private let laneHeaderWidth: CGFloat = 220.0
    private let rulerHeight: CGFloat = 24.0

    init(
        zoomScale: Binding<Double> = .constant(1.0),
        filterText: Binding<String> = .constant(""),
        showCausationArrows: Binding<Bool> = .constant(true),
        openTraceTrigger: Int = 0,
        fitZoomTrigger: Int = 0
    ) {
        self._zoomScale = zoomScale
        self._filterText = filterText
        self._showCausationArrows = showCausationArrows
        self.openTraceTrigger = openTraceTrigger
        self.fitZoomTrigger = fitZoomTrigger
    }

    private var traceResult: TraceResult? {
        get { workspace.activeTraceSummary }
        nonmutating set { workspace.activeTraceSummary = newValue }
    }

    private var errorMessage: String? {
        get { workspace.activeTraceErrorMessage }
        nonmutating set { workspace.activeTraceErrorMessage = newValue }
    }

    private var filteredLanes: [GoroutineTimelineLane] {
        guard let result = traceResult else { return [] }
        if filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            return result.lanes
        }
        let lower = filterText.lowercased()
        return result.lanes.filter { lane in
            lane.name.lowercased().contains(lower) || "g\(lane.goroutineId)".contains(lower)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                loadingState
            } else if let error = errorMessage {
                errorState(error)
            } else if let result = traceResult, !result.lanes.isEmpty {
                if filteredLanes.isEmpty {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Goroutines") {
                        filterText = ""
                    }
                } else {
                    timelineContent(result: result)
                }
            } else {
                emptyState
            }
        }
        .background(ThemeColor.contentSurface)
        .onAppear {
            if traceResult != nil && !didFitLoadedTrace {
                didFitLoadedTrace = true
                fitZoom()
            }
        }
        .onChange(of: openTraceTrigger) { _, _ in
            selectAndLoadTraceFile()
        }
        .onChange(of: fitZoomTrigger) { _, _ in
            fitZoom()
        }
    }

    @ViewBuilder
    private var goroutineHeaderCell: some View {
        Rectangle()
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: laneHeaderWidth, height: rulerHeight)
            .overlay(alignment: .leading) {
                Text("Goroutine")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Spacing.standard)
            }
    }

    @ViewBuilder
    private var laneHeadersColumn: some View {
        VStack(spacing: 0) {
            ForEach(filteredLanes) { lane in
                laneHeaderRow(lane)
                    .frame(height: laneHeight)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
            }
        }
        .frame(width: laneHeaderWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func timelineContent(result: TraceResult) -> some View {
        let totalDurationUs = max(1.0, Double(result.totalDurationNs) / 1000.0)
        let canvasWidth = max(600.0, totalDurationUs * zoomScale)
        let canvasHeight = CGFloat(filteredLanes.count) * laneHeight

        return Group {
            SyncedTraceTimelineArea(
                rulerHeight: rulerHeight,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                headerCell: { goroutineHeaderCell },
                rulerContent: {
                    timeRulerView(totalDurationUs: totalDurationUs, width: canvasWidth)
                        .frame(width: canvasWidth, height: rulerHeight)
                },
                laneHeaders: { laneHeadersColumn },
                canvasContent: {
                    timelineCanvas(result: result, width: canvasWidth, height: canvasHeight)
                        .frame(width: canvasWidth, height: canvasHeight)
                }
            )
        }
        .popover(item: $selectedSpan) { span in
            TraceSpanInspectorPopover(span: span) { path, line in
                workspace.jumpToLocation(path: path, line: line, column: 1)
            }
        }
    }

    private func laneHeaderRow(_ lane: GoroutineTimelineLane) -> some View {
        let isSelected = selectedLane?.id == lane.id
        return Button {
            selectedLane = (selectedLane?.id == lane.id) ? nil : lane
        } label: {
            HStack(spacing: Spacing.row) {
                Text("G\(lane.goroutineId)")
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .frame(width: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(lane.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(formatDuration(lane.totalActiveNs)) active · \(lane.eventCount) ev")
                        .font(TechnicalTypography.metricMono)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.standard)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Goroutine \(lane.goroutineId), \(lane.name), \(formatDuration(lane.totalActiveNs)) active")
    }

    private func timeRulerView(totalDurationUs: Double, width: CGFloat) -> some View {
        Canvas { context, size in
            let stepUs = calculateRulerStep(totalDurationUs: totalDurationUs, width: width)
            var currentUs: Double = 0.0

            while currentUs <= totalDurationUs {
                let x = CGFloat(currentUs * zoomScale)
                var tickPath = Path()
                tickPath.move(to: CGPoint(x: x, y: size.height - 8))
                tickPath.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tickPath, with: .color(Color(nsColor: .separatorColor)), lineWidth: Stroke.standard)

                let labelText = formatRulerTime(us: currentUs)
                let text = Text(labelText)
                    .font(TechnicalTypography.metricMono)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                context.draw(text, at: CGPoint(x: x + 2, y: size.height - 14), anchor: .topLeading)

                currentUs += stepUs
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func timelineCanvas(result: TraceResult, width: CGFloat, height: CGFloat) -> some View {
        let isDark = colorScheme == .dark
        return Canvas { context, size in
            let baseStartNs = result.startNs

            if let gcPeriods = result.gcPeriods {
                let gcBandColor = DataVizTone.TraceStateKind.gc.color(isDark: isDark).opacity(0.15)
                for gc in gcPeriods {
                    let startX = CGFloat(Double(gc.startNs - baseStartNs) / 1000.0 * zoomScale)
                    let endX = CGFloat(Double(gc.endNs - baseStartNs) / 1000.0 * zoomScale)
                    let rect = CGRect(x: startX, y: 0, width: max(2, endX - startX), height: size.height)
                    context.fill(Path(rect), with: .color(gcBandColor))
                }
            }

            for (laneIndex, lane) in filteredLanes.enumerated() {
                let laneY = CGFloat(laneIndex) * laneHeight
                let barHeight = laneHeight - 6.0
                let barY = laneY + 3.0

                for span in lane.spans {
                    let startX = CGFloat(Double(span.startNs - baseStartNs) / 1000.0 * zoomScale)
                    let endX = CGFloat(Double(span.endNs - baseStartNs) / 1000.0 * zoomScale)
                    let spanWidth = max(2.0, endX - startX)
                    let spanRect = CGRect(x: startX, y: barY, width: spanWidth, height: barHeight)

                    let isHovered = hoveredSpan?.id == span.id
                    let path = Path(roundedRect: spanRect, cornerRadius: CornerRadius.small)
                    context.fill(path, with: .color(span.stateColor(isDark: isDark)))

                    if isHovered || selectedSpan?.id == span.id {
                        context.stroke(path, with: .color(ChromeColor.textPrimary), lineWidth: Stroke.standard)
                    } else if differentiateWithoutColor {
                        context.stroke(path, with: .color(ChromeColor.textSecondary), lineWidth: Stroke.standard)
                    }

                    if differentiateWithoutColor && spanWidth >= 28 {
                        let code = span.traceStateKind?.shortCode ?? String(span.state.prefix(3)).uppercased()
                        let codeText = Text(code)
                            .font(TechnicalTypography.badgeMicro)
                            .foregroundColor(isDark ? Color(nsColor: .black) : Color(nsColor: .white))
                        context.draw(codeText, at: CGPoint(x: spanRect.midX, y: spanRect.midY), anchor: .center)
                    }
                }
            }

            if showCausationArrows {
                let laneYMap = Dictionary(uniqueKeysWithValues: filteredLanes.enumerated().map { ($0.element.goroutineId, CGFloat($0.offset) * laneHeight + (laneHeight / 2)) })

                for link in result.causationLinks {
                    guard let fromY = laneYMap[link.fromG], let toY = laneYMap[link.toG] else { continue }
                    let x = CGFloat(Double(link.timestampNs - baseStartNs) / 1000.0 * zoomScale)

                    var arrowPath = Path()
                    arrowPath.move(to: CGPoint(x: x - 4, y: fromY))
                    let midX = x + (toY > fromY ? 12 : -12)
                    arrowPath.addCurve(to: CGPoint(x: x, y: toY),
                                       control1: CGPoint(x: midX, y: fromY),
                                       control2: CGPoint(x: midX, y: toY))

                    let isArrowActive = selectedLane?.id == link.fromG || selectedLane?.id == link.toG
                    let arrowColor = isArrowActive ? Color.accentColor : StatusTone.warning.tint.opacity(0.6)
                    context.stroke(arrowPath, with: .color(arrowColor), lineWidth: isArrowActive ? 2 : 1)
                }
            }
        }
        .gesture(
            SpatialTapGesture().onEnded { val in
                handleTapAt(point: val.location, result: result)
            }
        )
    }

    private func handleTapAt(point: CGPoint, result: TraceResult) {
        let laneIndex = Int(point.y / laneHeight)
        guard laneIndex >= 0 && laneIndex < filteredLanes.count else { return }
        let lane = filteredLanes[laneIndex]
        selectedLane = lane

        let tappedUs = Double(point.x) / zoomScale
        let tappedNs = result.startNs + Int64(tappedUs * 1000.0)

        if let span = lane.spans.first(where: { tappedNs >= $0.startNs && tappedNs <= $0.endNs }) {
            selectedSpan = span
        }
    }

    private func fitZoom() {
        guard let result = traceResult, result.totalDurationNs > 0 else { return }
        let totalUs = Double(result.totalDurationNs) / 1000.0
        zoomScale = max(0.1, min(10.0, 700.0 / totalUs))
    }

    private func selectAndLoadTraceFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadTraceFile(at: url.path)
        }
    }

    func loadTraceFile(at path: String) {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cPath = path.cString(using: .utf8),
                  let cStr = ParseGoTraceFile(cPath) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Couldn’t read the trace file."
                }
                return
            }
            defer { FreeGoCString(cStr) }
            let jsonString = String(cString: cStr)
            guard let data = jsonString.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Invalid UTF-8 trace parser response"
                }
                return
            }

            do {
                let parsed = try JSONDecoder().decode(TraceResult.self, from: data)
                DispatchQueue.main.async {
                    self.isLoading = false
                    if let err = parsed.error {
                        self.errorMessage = err
                    } else {
                        self.traceResult = parsed
                        self.didFitLoadedTrace = true
                        self.fitZoom()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "JSON Decode Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private var emptyState: some View {
        UnifiedEmptyState.empty(
            symbol: "waveform.path.ecg",
            badge: "profiler",
            title: "No Execution Trace Loaded",
            message: "Run tests with -trace or open an existing trace.out file to inspect scheduler latencies, goroutine states, and channel unblocks.",
            actionTitle: "Open Execution Trace",
            action: selectAndLoadTraceFile
        )
    }

    private var loadingState: some View {
        UnifiedEmptyState.loading(message: "Parsing execution trace…")
    }

    private func errorState(_ msg: String) -> some View {
        UnifiedEmptyState.failed(
            title: "Couldn’t Load Trace",
            message: msg,
            onRetry: selectAndLoadTraceFile
        )
    }

    private func formatDuration(_ ns: Int64) -> String {
        if ns < 1_000 { return "\(ns)ns" }
        if ns < 1_000_000 { return String(format: "%.1fµs", Double(ns) / 1000.0) }
        if ns < 1_000_000_000 { return String(format: "%.2fms", Double(ns) / 1_000_000.0) }
        return String(format: "%.2fs", Double(ns) / 1_000_000_000.0)
    }

    private func calculateRulerStep(totalDurationUs: Double, width: CGFloat) -> Double {
        let approxTicks = max(4.0, Double(width / 80.0))
        let rawStep = totalDurationUs / approxTicks
        let magnitude = pow(10.0, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        if normalized < 2.0 { return magnitude }
        if normalized < 5.0 { return 2.0 * magnitude }
        return 5.0 * magnitude
    }

    private func formatRulerTime(us: Double) -> String {
        if us < 1_000 { return String(format: "%.0fµs", us) }
        if us < 1_000_000 { return String(format: "%.1fms", us / 1000.0) }
        return String(format: "%.2fs", us / 1_000_000.0)
    }
}

struct TraceSpanInspectorPopover: View {
    let span: TraceSpan
    let onJumpToSource: (String, Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack {
                Circle()
                    .fill(span.stateColor(isDark: isDark))
                    .frame(width: 8, height: 8)
                Text(span.traceStateKind?.label ?? span.state.capitalized)
                    .font(.callout.weight(.bold))
                Spacer()
                Text(formatDuration(span.durationNs))
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let reason = span.reason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("REASON")
                        .font(TechnicalTypography.badgeMicro)
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.subheadline)
                }
            }

            if let fn = span.function, !fn.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("FUNCTION")
                        .font(TechnicalTypography.badgeMicro)
                        .foregroundStyle(.secondary)
                    Text(fn)
                        .font(.subheadline.monospaced())
                        .lineLimit(2)
                }
            }

            if let file = span.file, let line = span.line, !file.isEmpty {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(URL(fileURLWithPath: file).lastPathComponent)
                            .font(.subheadline.weight(.medium))
                        Text("Line \(line)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Jump to Source") {
                        onJumpToSource(file, line)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(Spacing.comfortable)
        .frame(width: 280)
    }

    private func formatDuration(_ ns: Int64) -> String {
        if ns < 1_000 { return "\(ns) ns" }
        if ns < 1_000_000 { return String(format: "%.1f µs", Double(ns) / 1000.0) }
        if ns < 1_000_000_000 { return String(format: "%.2f ms", Double(ns) / 1_000_000.0) }
        return String(format: "%.3f s", Double(ns) / 1_000_000_000.0)
    }
}

private struct SyncedTraceTimelineArea<HeaderCell: View, RulerContent: View, LaneHeaders: View, CanvasContent: View>: View {
    let rulerHeight: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    @ViewBuilder let headerCell: () -> HeaderCell
    @ViewBuilder let rulerContent: () -> RulerContent
    @ViewBuilder let laneHeaders: () -> LaneHeaders
    @ViewBuilder let canvasContent: () -> CanvasContent

    @State private var horizontalScroll = ScrollPosition(edge: .leading)
    @State private var rulerScroll = ScrollPosition(edge: .leading)
    @State private var syncedOffsetX: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                headerCell()
                Divider().frame(height: rulerHeight)
                ScrollView(.horizontal, showsIndicators: false) {
                    rulerContent()
                }
                .scrollPosition($rulerScroll)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.x
                } action: { _, newX in
                    let clamped = max(0, newX)
                    guard abs(clamped - syncedOffsetX) > 0.5 else { return }
                    syncedOffsetX = clamped
                    horizontalScroll.scrollTo(x: clamped)
                }
            }

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    laneHeaders()
                    Divider()
                    ScrollView(.horizontal, showsIndicators: true) {
                        canvasContent()
                    }
                    .scrollPosition($horizontalScroll)
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.x
                    } action: { _, newX in
                        let clamped = max(0, newX)
                        guard abs(clamped - syncedOffsetX) > 0.5 else { return }
                        syncedOffsetX = clamped
                        rulerScroll.scrollTo(x: clamped)
                    }
                }
            }
        }
    }
}
