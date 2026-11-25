import GoLensFoundation
import SwiftUI

struct ProfilerView: View {
    enum Mode: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
        case block = "Block"
        case mutex = "Mutex"
        case trace = "Trace"
        case kernel = "Kernel"
    }

    enum ViewPresentation: String, CaseIterable {
        case table = "Table"
        case flameGraph = "Flame Graph"
    }

    struct FlameNode: Identifiable, Hashable {
        let id: String
        let entry: ProfileEntry
        let depth: Int
        let startFraction: Double
        let widthFraction: Double

        var name: String { entry.function }
    }

    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Bindable private var vm = SandboxVMManager.shared
    @State private var selectedMode: Mode = .cpu
    @State private var presentation: ViewPresentation = .table
    @State private var workspaceOnly: Bool = true
    @State private var zoomedFunction: String? = nil
    @State private var selectedEntry: ProfileEntry? = nil
    @State private var hoveredEntry: ProfileEntry? = nil
    @State private var traceZoomScale: Double = 1.0
    @State private var traceFilterText: String = ""
    @State private var traceShowCausationArrows: Bool = true
    @State private var openTraceTrigger: Int = 0
    @State private var fitTraceZoomTrigger: Int = 0
    @AppStorage("GoLensShowProfileLineHeat") private var showLineHeat: Bool = true

    private var rawEntries: [ProfileEntry] {
        switch selectedMode {
        case .cpu:
            return workspace.cpuProfileEntries
        case .memory:
            return workspace.memProfileEntries
        case .block:
            return workspace.blockProfileEntries
        case .mutex:
            return workspace.mutexProfileEntries
        case .trace, .kernel:
            return []
        }
    }

    private var workspaceEntries: [ProfileEntry] {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return [] }
        let prefix = root + "/"
        return rawEntries.filter { entry in
            !entry.file.isEmpty && (entry.file == root || entry.file.hasPrefix(prefix))
        }
    }

    private var showingRuntimeFallback: Bool {
        workspaceOnly && workspaceEntries.isEmpty && !rawEntries.isEmpty
    }

    private var displayedEntries: [ProfileEntry] {
        if workspaceOnly {
            return workspaceEntries.isEmpty ? rawEntries : workspaceEntries
        }
        return rawEntries
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if selectedMode == .trace {
                TraceTimelineView(
                    zoomScale: $traceZoomScale,
                    filterText: $traceFilterText,
                    showCausationArrows: $traceShowCausationArrows,
                    openTraceTrigger: openTraceTrigger,
                    fitZoomTrigger: fitTraceZoomTrigger
                )
            } else if selectedMode == .kernel && vm.executionMode == .linuxVM {
                KernelTelemetryView(workspace: workspace)
            } else if displayedEntries.isEmpty {
                emptyState
            } else if presentation == .flameGraph {
                flameGraphView
            } else {
                columnHeader
                Divider()
                entriesList
            }
        }
        .background(ThemeColor.contentSurface)
        .onAppear {
            syncDefaultMode()
        }
        .onChange(of: workspace.cpuProfileEntries) {
            syncDefaultMode()
        }
        .onChange(of: workspace.memProfileEntries) {
            syncDefaultMode()
        }
        .onChange(of: workspace.blockProfileEntries) {
            syncDefaultMode()
        }
        .onChange(of: workspace.mutexProfileEntries) {
            syncDefaultMode()
        }
        .onChange(of: vm.executionMode) {
            if vm.executionMode != .linuxVM && selectedMode == .kernel {
                selectedMode = .cpu
                syncDefaultMode()
            }
        }
        .onChange(of: selectedMode) {
            workspace.selectedProfileMode = selectedMode.rawValue
            zoomedFunction = nil
            selectedEntry = nil
            hoveredEntry = nil
            workspace.activeTextView?.needsDisplay = true
            (workspace.activeTextView as? GoLensTextView)?.redrawGutter()
        }
        .onChange(of: showLineHeat) {
            workspace.activeTextView?.needsDisplay = true
            (workspace.activeTextView as? GoLensTextView)?.redrawGutter()
        }
    }

    private func syncDefaultMode() {
        if vm.executionMode != .linuxVM && selectedMode == .kernel {
            selectedMode = .cpu
        }
        if !workspace.cpuProfileEntries.isEmpty {
            selectedMode = .cpu
        } else if !workspace.memProfileEntries.isEmpty {
            selectedMode = .memory
        } else if !workspace.blockProfileEntries.isEmpty {
            selectedMode = .block
        } else if !workspace.mutexProfileEntries.isEmpty {
            selectedMode = .mutex
        }
    }

    private var functionCountLabel: String {
        displayedEntries.count == 1 ? "1 function" : "\(displayedEntries.count) functions"
    }

    private var visibleModes: [Mode] {
        vm.executionMode == .linuxVM ? Mode.allCases : Mode.allCases.filter { $0 != .kernel }
    }

    private var segmentedModePicker: some View {
        Picker("Profile Mode", selection: $selectedMode) {
            ForEach(visibleModes, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Profile Mode")
    }

    private var menuModePicker: some View {
        Picker("Profile Mode", selection: $selectedMode) {
            ForEach(visibleModes, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Profile Mode")
    }

    private var presentationPicker: some View {
        Picker("View", selection: $presentation) {
            ForEach(ViewPresentation.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Profiler View Mode")
    }

    private var profilerOverflowMenu: some View {
        Menu {
            Toggle("Workspace Only", isOn: $workspaceOnly)
            if showingRuntimeFallback {
                Text("Showing runtime & stdlib frames")
            }
            Divider()
            Button("Clear Profile", systemImage: "trash") {
                workspace.clearProfile()
            }
            .disabled(!workspace.hasProfileData)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(ChromeColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Profiler Options")
        .accessibilityLabel("More Profiler Options")
    }

    private var profilerTopBarWide: some View {
        HStack(spacing: Spacing.standard) {
            segmentedModePicker
            presentationPicker

            Toggle("Workspace Only", isOn: $workspaceOnly)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize()

            Toggle("Line Heat", isOn: $showLineHeat)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize()
                .accessibilityLabel("Show Editor Line Heat")

            Spacer(minLength: Spacing.standard)

            Text(functionCountLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Button("Profile") {
                workspace.profileProject()
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
            .accessibilityLabel("Profile Application")

            Button("Open…") {
                workspace.promptAndImportPprofFile()
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .accessibilityLabel("Open pprof Profile")

            Button("Clear") {
                workspace.clearProfile()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize()
            .disabled(!workspace.hasProfileData)
            .help("Clear Profile")
            .accessibilityLabel("Clear Profile")
        }
    }

    private var profilerTopBarMedium: some View {
        HStack(spacing: Spacing.row) {
            menuModePicker
            presentationPicker

            Toggle("Line Heat", isOn: $showLineHeat)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize()
                .accessibilityLabel("Show Editor Line Heat")

            Spacer(minLength: Spacing.compact)

            Text(functionCountLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Button("Profile") {
                workspace.profileProject()
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
            .accessibilityLabel("Profile Application")

            Button("Open…") {
                workspace.promptAndImportPprofFile()
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .accessibilityLabel("Open pprof Profile")

            profilerOverflowMenu
        }
    }

    private var profilerTopBarCompact: some View {
        HStack(spacing: Spacing.compact) {
            menuModePicker
            presentationPicker

            Toggle(isOn: $showLineHeat) {
                Image(systemName: "flame")
                    .font(.subheadline)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Show Editor Line Heat")
            .accessibilityLabel("Show Editor Line Heat")

            Spacer(minLength: Spacing.hairline)

            Text(functionCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Button {
                workspace.profileProject()
            } label: {
                Image(systemName: "play.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
            .help("Profile Application")
            .accessibilityLabel("Profile Application")

            Button {
                workspace.promptAndImportPprofFile()
            } label: {
                Image(systemName: "folder")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Open pprof Profile")
            .accessibilityLabel("Open pprof Profile")

            profilerOverflowMenu
        }
    }

    private var traceTopBarWide: some View {
        HStack(spacing: Spacing.standard) {
            segmentedModePicker

            if let result = workspace.activeTraceSummary {
                Text("\(result.lanes.count) lanes")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            TraceLegendStrip()

            Spacer(minLength: Spacing.standard)

            PanelFilterBar(
                placeholder: "Filter goroutines…",
                text: $traceFilterText,
                accessibilityTitle: "Filter Goroutines"
            )
            .frame(width: 156)

            Toggle(isOn: $traceShowCausationArrows) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.subheadline)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Show Unblock Causation Arrows")
            .accessibilityLabel("Show Unblock Causation Arrows")

            HStack(spacing: Spacing.compact) {
                Button {
                    traceZoomScale = max(0.1, traceZoomScale / 1.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help(KeymapStore.shared.labeled("Zoom Out", "view.zoomOut"))
                .accessibilityLabel("Zoom Out")

                Button("Fit") {
                    fitTraceZoomTrigger &+= 1
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .fixedSize()
                .help("Zoom to Fit Timeline")
                .accessibilityLabel("Zoom to Fit Timeline")

                Button {
                    traceZoomScale = min(20.0, traceZoomScale * 1.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help(KeymapStore.shared.labeled("Zoom In", "view.zoomIn"))
                .accessibilityLabel("Zoom In")
            }
            .fixedSize()

            Button("Open Trace…") {
                openTraceTrigger &+= 1
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .accessibilityLabel("Open Execution Trace")
        }
    }

    private var traceTopBarCompact: some View {
        HStack(spacing: Spacing.row) {
            menuModePicker

            PanelFilterBar(
                placeholder: "Filter goroutines…",
                text: $traceFilterText,
                accessibilityTitle: "Filter Goroutines"
            )
            .frame(maxWidth: 156)

            Spacer(minLength: Spacing.compact)

            Button("Open Trace…") {
                openTraceTrigger &+= 1
            }
            .controlSize(.small)
            .font(.subheadline)
            .fixedSize()
            .accessibilityLabel("Open Execution Trace")

            Menu {
                Toggle("Show Unblock Causation Arrows", isOn: $traceShowCausationArrows)
                Divider()
                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    traceZoomScale = min(20.0, traceZoomScale * 1.5)
                }
                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    traceZoomScale = max(0.1, traceZoomScale / 1.5)
                }
                Button("Zoom to Fit Timeline", systemImage: "arrow.left.and.right") {
                    fitTraceZoomTrigger &+= 1
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
                    .foregroundStyle(ChromeColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Trace Options")
            .accessibilityLabel("More Trace Options")
        }
    }

    private var kernelTopBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.standard) {
                segmentedModePicker
                Spacer(minLength: Spacing.standard)
                Button("Run Target") {
                    workspace.runProject()
                }
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize()
                .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
                .accessibilityLabel("Run Target in Linux Micro-VM")
            }
            HStack(spacing: Spacing.row) {
                menuModePicker
                Spacer(minLength: Spacing.compact)
                Button("Run Target") {
                    workspace.runProject()
                }
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize()
                .disabled(workspace.activeWorkspacePath.isEmpty || workspace.isRunning)
                .accessibilityLabel("Run Target in Linux Micro-VM")
            }
        }
    }

    private var topBar: some View {
        Group {
            if selectedMode == .trace {
                ViewThatFits(in: .horizontal) {
                    traceTopBarWide
                    traceTopBarCompact
                }
            } else if selectedMode == .kernel && vm.executionMode == .linuxVM {
                kernelTopBar
            } else {
                ViewThatFits(in: .horizontal) {
                    profilerTopBarWide
                    profilerTopBarMedium
                    profilerTopBarCompact
                }
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .frame(height: 28)
        .background(ThemeColor.panelSurface)
    }

    private var columnHeader: some View {
        HStack(spacing: Spacing.standard) {
            Text("Function")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Flat")
                .frame(width: 128, alignment: .trailing)
            Text("Cum")
                .frame(width: 128, alignment: .trailing)
            Text("Location")
                .frame(width: 160, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.compact)
    }

    private var entriesList: some View {
        let totalDisplayedFlat = max(Int64(1), displayedEntries.reduce(Int64(0)) { $0 + max(0, $1.flat) })
        let maxDisplayedCum = max(totalDisplayedFlat, displayedEntries.map(\.cum).max() ?? 1)
        let useRelativePct = workspaceOnly && !showingRuntimeFallback
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayedEntries) { entry in
                    let flatPct = useRelativePct
                        ? (entry.flat > 0 ? Double(entry.flat) * 100.0 / Double(totalDisplayedFlat) : 0.0)
                        : entry.flatPercent
                    let cumPct = useRelativePct
                        ? (entry.cum > 0 ? min(100.0, Double(entry.cum) * 100.0 / Double(maxDisplayedCum)) : 0.0)
                        : entry.cumPercent
                    ProfileEntryRow(
                        entry: entry,
                        displayFlatPercent: flatPct,
                        displayCumPercent: cumPct,
                        workspace: workspace
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        let alternateAction: (String, () -> Void)? = {
            if selectedMode == .cpu && !workspace.memProfileEntries.isEmpty {
                return ("Show Memory Profile", { selectedMode = .memory })
            }
            if selectedMode == .memory && !workspace.cpuProfileEntries.isEmpty {
                return ("Show CPU Profile", { selectedMode = .cpu })
            }
            if selectedMode != .block && !workspace.blockProfileEntries.isEmpty {
                return ("Show Block Profile", { selectedMode = .block })
            }
            if selectedMode != .mutex && !workspace.mutexProfileEntries.isEmpty {
                return ("Show Mutex Profile", { selectedMode = .mutex })
            }
            return nil
        }()

        return UnifiedEmptyState.empty(
            symbol: "gauge.with.dots.needle.67percent",
            badge: "profiler",
            title: workspace.hasProfileData ? "No \(selectedMode.rawValue) Samples" : "No Profile Samples",
            message: workspace.hasProfileData
                ? "No samples were recorded for \(selectedMode.rawValue) — the run may have completed before sampling or allocated zero bytes."
                : "Profile your Go project or open an existing .pprof file to inspect CPU, memory, block, and mutex hotspots.",
            actionTitle: alternateAction?.0 ?? "Profile Application",
            action: alternateAction?.1 ?? { workspace.profileProject() },
            secondaryActionTitle: "Open pprof Profile",
            secondaryAction: { workspace.promptAndImportPprofFile() }
        )
    }

    private var entriesByFunction: [String: ProfileEntry] {
        var dict: [String: ProfileEntry] = [:]
        for entry in displayedEntries where dict[entry.function] == nil {
            dict[entry.function] = entry
        }
        return dict
    }

    private var flameNodes: [FlameNode] {
        guard !displayedEntries.isEmpty else { return [] }
        let byFunction = entriesByFunction
        let maxDepth = 12
        let hasCallEdges = displayedEntries.contains { entry in
            guard let children = entry.children else { return false }
            return children.contains { byFunction[$0] != nil }
        }

        var nodes: [FlameNode] = []

        if let zoom = zoomedFunction, let zoomEntry = byFunction[zoom] {
            layoutSubtree(
                entry: zoomEntry,
                depth: 0,
                startFraction: 0.0,
                widthFraction: 1.0,
                visited: [zoomEntry.function],
                byFunction: byFunction,
                maxDepth: maxDepth,
                into: &nodes
            )
            return nodes
        }

        if hasCallEdges {
            var roots = displayedEntries.filter { entry in
                guard let callers = entry.callers, !callers.isEmpty else { return true }
                return !callers.contains { byFunction[$0] != nil }
            }
            if roots.isEmpty, let maxEntry = displayedEntries.max(by: { $0.cum < $1.cum }) {
                roots = [maxEntry]
            }
            roots.sort {
                if $0.cum != $1.cum { return $0.cum > $1.cum }
                if $0.flat != $1.flat { return $0.flat > $1.flat }
                return $0.function < $1.function
            }
            let totalRootWeight = max(1.0, roots.reduce(0.0) { $0 + Double(max(1, $1.cum)) })
            var cursor = 0.0
            for root in roots {
                let w = Double(max(1, root.cum)) / totalRootWeight
                layoutSubtree(
                    entry: root,
                    depth: 0,
                    startFraction: cursor,
                    widthFraction: w,
                    visited: [root.function],
                    byFunction: byFunction,
                    maxDepth: maxDepth,
                    into: &nodes
                )
                cursor += w
            }
            return nodes
        }

        let callers = displayedEntries.filter { $0.cum > $0.flat }
        let leaves = displayedEntries.filter { $0.cum <= $0.flat }
        if !callers.isEmpty && !leaves.isEmpty {
            let callerTotal = max(1.0, callers.reduce(0.0) { $0 + Double(max(1, $1.cum)) })
            var cCursor = 0.0
            for caller in callers {
                let w = Double(max(1, caller.cum)) / callerTotal
                nodes.append(FlameNode(
                    id: "0:\(caller.function):\(String(format: "%.6f", cCursor))",
                    entry: caller,
                    depth: 0,
                    startFraction: cCursor,
                    widthFraction: w
                ))
                cCursor += w
            }
            let leafTotal = max(1.0, leaves.reduce(0.0) { $0 + Double(max(1, max($1.flat, $1.cum))) })
            var lCursor = 0.0
            for leaf in leaves {
                let w = Double(max(1, max(leaf.flat, leaf.cum))) / leafTotal
                nodes.append(FlameNode(
                    id: "1:\(leaf.function):\(String(format: "%.6f", lCursor))",
                    entry: leaf,
                    depth: 1,
                    startFraction: lCursor,
                    widthFraction: w
                ))
                lCursor += w
            }
        } else {
            let topEntries = Array(displayedEntries.prefix(32))
            let totalWeight = max(1.0, topEntries.reduce(0.0) { $0 + Double(max(1, max($1.cum, $1.flat))) })
            var cursor = 0.0
            for entry in topEntries {
                let w = Double(max(1, max(entry.cum, entry.flat))) / totalWeight
                nodes.append(FlameNode(
                    id: "0:\(entry.function):\(String(format: "%.6f", cursor))",
                    entry: entry,
                    depth: 0,
                    startFraction: cursor,
                    widthFraction: w
                ))
                cursor += w
            }
        }
        return nodes
    }

    private func layoutSubtree(
        entry: ProfileEntry,
        depth: Int,
        startFraction: Double,
        widthFraction: Double,
        visited: Set<String>,
        byFunction: [String: ProfileEntry],
        maxDepth: Int,
        into nodes: inout [FlameNode]
    ) {
        nodes.append(FlameNode(
            id: "\(depth):\(entry.function):\(String(format: "%.6f", startFraction))",
            entry: entry,
            depth: depth,
            startFraction: startFraction,
            widthFraction: widthFraction
        ))
        guard depth < maxDepth else { return }
        let childEntries: [ProfileEntry] = (entry.children ?? []).compactMap { childName in
            guard !visited.contains(childName), let child = byFunction[childName] else { return nil }
            return child
        }
        guard !childEntries.isEmpty else { return }
        let childrenSum = childEntries.reduce(Int64(0)) { $0 + max(1, $1.cum) }
        let totalParent = max(entry.cum, childrenSum + max(0, entry.flat))
        let childShare = totalParent > 0
            ? min(1.0, max(0.25, Double(childrenSum) / Double(totalParent)))
            : 1.0
        let totalChildrenWidth = widthFraction * childShare
        var childCursor = startFraction
        for child in childEntries {
            let w = totalChildrenWidth * (Double(max(1, child.cum)) / Double(max(1, childrenSum)))
            var nextVisited = visited
            nextVisited.insert(child.function)
            layoutSubtree(
                entry: child,
                depth: depth + 1,
                startFraction: childCursor,
                widthFraction: w,
                visited: nextVisited,
                byFunction: byFunction,
                maxDepth: maxDepth,
                into: &nodes
            )
            childCursor += w
        }
    }

    private func shortFunctionName(_ function: String) -> String {
        if let slashIdx = function.lastIndex(of: "/") {
            return String(function[function.index(after: slashIdx)...])
        }
        return function
    }

    private func flameFillColor(for entry: ProfileEntry) -> Color {
        let fraction = min(max(entry.cumPercent / 100.0, 0.0), 1.0)
        return DataVizTone.heatFill(fraction: fraction, isDark: colorScheme == .dark)
    }

    private func flameStrokeColor(for entry: ProfileEntry) -> Color {
        if selectedEntry?.function == entry.function {
            return ChromeColor.accent
        }
        if differentiateWithoutColor {
            return ChromeColor.textSecondary
        }
        let fraction = min(max(entry.cumPercent / 100.0, 0.0), 1.0)
        return DataVizTone.heatStroke(fraction: fraction, isDark: colorScheme == .dark)
    }

    private var flameInspectorBar: some View {
        let inspected = hoveredEntry ?? selectedEntry ?? displayedEntries.first
        return HStack(spacing: Spacing.inset) {
            Image(systemName: "flame.fill")
                .font(.subheadline)
                .foregroundStyle(DataVizTone.heatStroke(fraction: 0.75, isDark: colorScheme == .dark))
                .accessibilityHidden(true)

            Text(zoomedFunction ?? "All Sampled Stacks")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if zoomedFunction != nil {
                Button("Reset Zoom") {
                    zoomedFunction = nil
                }
                .controlSize(.small)
                .font(.subheadline)
                .accessibilityLabel("Reset Flame Graph Zoom")
            }

            Spacer(minLength: 8)

            if let entry = inspected {
                Text(entry.function)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Flat: \(entry.formattedFlat) (\(String(format: "%.1f%%", entry.flatPercent)))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Cum: \(entry.formattedCum) (\(String(format: "%.1f%%", entry.cumPercent)))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !entry.file.isEmpty {
                    Button("Jump to Source") {
                        if FileManager.default.fileExists(atPath: entry.file) {
                            workspace.jumpToLocation(path: entry.file, line: max(1, entry.line), column: 1)
                        }
                    }
                    .controlSize(.small)
                    .font(.subheadline)
                    .accessibilityLabel("Jump to Source")
                }
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private var flameGraphView: some View {
        let allNodes = flameNodes
        let maxDepth = allNodes.map(\.depth).max() ?? 0
        return VStack(spacing: 0) {
            flameInspectorBar
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(0...maxDepth, id: \.self) { depth in
                        let rowNodes = allNodes.filter { $0.depth == depth }
                        GeometryReader { geo in
                            let totalWidth = max(1.0, geo.size.width)
                            ZStack(alignment: .leading) {
                                ForEach(rowNodes) { node in
                                    let x = node.startFraction * totalWidth
                                    let w = max(2.0, node.widthFraction * totalWidth)
                                    let isSelected = selectedEntry?.function == node.entry.function
                                    let percentText = String(format: "%.1f%%", node.entry.cumPercent)
                                    let compactPercentText = "\(Int(node.entry.cumPercent.rounded()))%"
                                    Button {
                                        selectedEntry = node.entry
                                        zoomedFunction = node.entry.function
                                        if !node.entry.file.isEmpty && FileManager.default.fileExists(atPath: node.entry.file) {
                                            workspace.jumpToLocation(path: node.entry.file, line: max(1, node.entry.line), column: 1)
                                        }
                                    } label: {
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                                .fill(flameFillColor(for: node.entry))
                                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                                .strokeBorder(
                                                    flameStrokeColor(for: node.entry),
                                                    lineWidth: (differentiateWithoutColor || isSelected) ? Stroke.standard : Stroke.hairline
                                                )
                                            if w >= 56 {
                                                HStack(spacing: Spacing.compact) {
                                                    Text(shortFunctionName(node.name))
                                                        .font(.subheadline.monospaced())
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                    Spacer(minLength: 0)
                                                    Text(compactPercentText)
                                                        .font(TechnicalTypography.metricMono)
                                                        .foregroundStyle(differentiateWithoutColor ? .primary : .secondary)
                                                        .lineLimit(1)
                                                        .layoutPriority(1)
                                                }
                                                .padding(.horizontal, Spacing.row)
                                            } else if w >= 36 {
                                                Text(shortFunctionName(node.name))
                                                    .font(.subheadline.monospaced())
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                    .padding(.horizontal, Spacing.row)
                                            }
                                        }
                                        .frame(width: max(2.0, w - 1.0), height: 24)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: x)
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredEntry = node.entry
                                        } else if hoveredEntry?.function == node.entry.function {
                                            hoveredEntry = nil
                                        }
                                    }
                                    .help("\(node.name) — Flat: \(node.entry.formattedFlat) (\(String(format: "%.1f%%", node.entry.flatPercent))), Cum: \(node.entry.formattedCum) (\(percentText))")
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(node.name), \(percentText) of samples")
                                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                                }
                            }
                        }
                        .frame(height: 26)
                    }
                }
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.standard)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Flame Bar Graph")
            }
        }
    }
}

struct ProfileEntryRow: View {
    let entry: ProfileEntry
    let displayFlatPercent: Double
    let displayCumPercent: Double
    @Bindable var workspace: WorkspaceState
    @State private var isHovered = false

    private var canJump: Bool {
        !entry.file.isEmpty && FileManager.default.fileExists(atPath: entry.file)
    }

    private var locationLabel: String {
        guard !entry.file.isEmpty else { return "—" }
        return "\(URL(fileURLWithPath: entry.file).lastPathComponent):\(entry.line)"
    }

    private static func formatPct(_ pct: Double, rawValue: Int64) -> String {
        if rawValue > 0 && pct < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", pct)
    }

    var body: some View {
        Button {
            if canJump {
                workspace.jumpToLocation(path: entry.file, line: max(1, entry.line), column: 1)
            }
        } label: {
            HStack(spacing: Spacing.standard) {
                Text(entry.function)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(entry.formattedFlat) (\(Self.formatPct(displayFlatPercent, rawValue: entry.flat)))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)
                    .frame(width: 128, alignment: .trailing)
                    .background(alignment: .trailing) {
                        GeometryReader { geo in
                            let fraction = min(max(displayFlatPercent / 100.0, 0), 1)
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: geo.size.width * fraction)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }

                Text("\(entry.formattedCum) (\(Self.formatPct(displayCumPercent, rawValue: entry.cum)))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .trailing)

                Text(locationLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 160, alignment: .trailing)
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.compact)
            .background(isHovered && canJump ? ThemeColor.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Investigate Hotspot", systemImage: "sparkles") {
                workspace.gopilot.investigateHotspot(function: entry.function, file: entry.file, line: entry.line, kind: workspace.selectedProfileMode)
            }
            .disabled(workspace.gopilot.profilePaths.isEmpty)
        }
        .onHover { isHovered = $0 }
        .help(entry.file.isEmpty ? entry.function : "\(entry.function) — \(entry.file):\(entry.line)")
    }
}

struct KernelTelemetryView: View {
    @Bindable var workspace: WorkspaceState
    @State private var fdFilter: FDEntry.FDKind? = nil

    private var telemetry: KernelTelemetry? {
        workspace.kernelTelemetry
    }

    var body: some View {
        if let telemetry {
            VStack(spacing: 0) {
                if telemetry.psi == nil {
                    InlineBanner(
                        .status(.inactive),
                        title: "Pressure Unavailable",
                        message: "The Linux kernel in the VM doesn’t report pressure stall information, so memory, CPU and I/O pressure can’t be shown."
                    )
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        summaryBar(telemetry)
                        if let psi = telemetry.psi {
                            psiSection(psi)
                        }
                        tcpSection(telemetry.tcpSockets)
                        fdsSection(telemetry.openFDs)
                    }
                    .padding(Spacing.section)
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        UnifiedEmptyState.empty(
            symbol: "gauge.with.dots.needle.67percent",
            title: "No Kernel Telemetry",
            message: "Run or profile a target in the Linux Micro-VM to observe live TCP sockets, file descriptors, and Pressure Stall Information.",
            actionTitle: "Run Target",
            action: { workspace.runProject() }
        )
    }

    private func summaryBar(_ t: KernelTelemetry) -> some View {
        HStack(spacing: Spacing.section) {
            HStack(spacing: Spacing.row) {
                Circle()
                    .fill(StatusTone.success.tint)
                    .frame(width: 8, height: 8)
                Text(t.targetName.isEmpty ? "Target Process" : t.targetName)
                    .font(.callout.weight(.semibold))
                Text("PID \(UserMessage.rawIdentifier(t.pid))")
                    .font(.subheadline.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Divider().frame(height: 14)

            HStack(spacing: Spacing.row) {
                Image(systemName: "network")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text(verbatim: UserMessage.quantity(t.tcpSockets.count, "TCP Socket"))
                    .font(.subheadline)
                    .monospacedDigit()
            }

            Divider().frame(height: 14)

            HStack(spacing: Spacing.row) {
                Image(systemName: "doc")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text(verbatim: "\(UserMessage.rawIdentifier(t.openFDs.count)) / \(UserMessage.rawIdentifier(t.openFDs.limit)) FDs")
                    .font(.subheadline)
                    .monospacedDigit()
            }

            Spacer()

            Text("Live")
                .font(.caption.weight(.medium))
                .foregroundStyle(StatusTone.success.tint)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.hairline)
                .background(StatusTone.success.fill)
                .clipShape(Capsule())
        }
        .padding(Spacing.comfortable)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func psiSection(_ psi: PSITelemetry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("Pressure Stall Information (PSI)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            HStack(spacing: Spacing.comfortable) {
                psiCard(title: "Memory", symbol: "memorychip", resource: psi.memory)
                psiCard(title: "CPU", symbol: "cpu", resource: psi.cpu)
                psiCard(title: "I/O", symbol: "externaldrive", resource: psi.io)
            }
        }
    }

    private func psiCard(title: String, symbol: String, resource: PSIResource) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack(spacing: Spacing.row) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer()
                Text("some: \(String(format: "%.1f%%", resource.somePressure.avg10))")
                    .font(.caption.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(psiColor(resource.somePressure.avg10))
            }

            HStack(spacing: Spacing.standard) {
                Text("avg10: \(String(format: "%.2f", resource.somePressure.avg10))")
                Text("avg60: \(String(format: "%.2f", resource.somePressure.avg60))")
                Text("avg300: \(String(format: "%.2f", resource.somePressure.avg300))")
            }
            .font(.caption.monospaced())
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            if let full = resource.fullPressure {
                HStack(spacing: Spacing.row) {
                    Text("full stall:")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    Text("\(String(format: "%.2f", full.avg10)) / \(String(format: "%.2f", full.avg60))")
                        .font(.caption.monospaced())
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }

            Text(verbatim: "total: \(UserMessage.integer(Int(clamping: resource.somePressure.totalMicros / 1000))) ms")
                .font(TechnicalTypography.metricMono)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(Spacing.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func psiColor(_ val: Double) -> Color {
        if val > 20.0 {
            return StatusTone.failure.tint
        } else if val > 5.0 {
            return StatusTone.warning.tint
        }
        return StatusTone.success.tint
    }

    private func tcpSection(_ sockets: [TCPSocketTelemetry]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text(verbatim: "Active TCP Sockets (\(UserMessage.integer(sockets.count)))")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            if sockets.isEmpty {
                Text("No active TCP sockets recorded for target.")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.vertical, Spacing.standard)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.standard) {
                        Text("Local Address").frame(width: 170, alignment: .leading)
                        Text("Remote Address").frame(width: 170, alignment: .leading)
                        Text("State").frame(width: 100, alignment: .leading)
                        Text("Inode & Queues").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, Spacing.inset)
                    .padding(.vertical, Spacing.row)

                    Divider()

                    LazyVStack(spacing: 0) {
                        ForEach(sockets) { s in
                            HStack(spacing: Spacing.standard) {
                                Text(verbatim: s.localEndpoint)
                                    .frame(width: 170, alignment: .leading)
                                Text(verbatim: s.remoteEndpoint)
                                    .frame(width: 170, alignment: .leading)
                                Text(s.state.rawValue)
                                    .font(TechnicalTypography.badgeMicro.monospaced())
                                    .foregroundStyle(Color(nsColor: s.state.color))
                                    .padding(.horizontal, Spacing.row)
                                    .padding(.vertical, Spacing.hairline)
                                    .background(Color(nsColor: s.state.color).opacity(0.12))
                                    .clipShape(Capsule())
                                    .frame(width: 100, alignment: .leading)
                                Text(verbatim: "inode: \(UserMessage.rawIdentifier(s.inode))  tx: \(UserMessage.rawIdentifier(s.txQueue))  rx: \(UserMessage.rawIdentifier(s.rxQueue))")
                                    .font(.caption)
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline.monospaced())
                            .monospacedDigit()
                            .padding(.horizontal, Spacing.inset)
                            .padding(.vertical, Spacing.row)

                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private func fdsSection(_ fds: OpenFDsTelemetry) -> some View {
        let filteredEntries = fds.entries.filter { entry in
            if let fdFilter {
                return entry.kind == fdFilter
            }
            return true
        }

        return VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack {
                Text(verbatim: "Open File Descriptors (\(UserMessage.integer(filteredEntries.count)) / \(UserMessage.integer(fds.count)))")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))

                Spacer()

                HStack(spacing: Spacing.compact) {
                    fdFilterButton(nil, title: "All")
                    fdFilterButton(.socket, title: "Sockets")
                    fdFilterButton(.pipe, title: "Pipes")
                    fdFilterButton(.file, title: "Files")
                    fdFilterButton(.character, title: "Devices")
                }
            }

            if filteredEntries.isEmpty {
                Text("No matching file descriptors.")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.vertical, Spacing.standard)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.standard) {
                        Text("FD").frame(width: 36, alignment: .trailing)
                        Text("Type").frame(width: 90, alignment: .leading)
                        Text("Target Path").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, Spacing.inset)
                    .padding(.vertical, Spacing.row)

                    Divider()

                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            HStack(spacing: Spacing.standard) {
                                Text(verbatim: UserMessage.rawIdentifier(entry.fd))
                                    .frame(width: 36, alignment: .trailing)
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                                Label(entry.kind.badgeTitle, systemImage: entry.kind.symbol)
                                    .font(.caption)
                                    .padding(.horizontal, Spacing.compact)
                                    .padding(.vertical, Spacing.hairline)
                                    .background(Color(nsColor: .secondaryLabelColor).opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                                    .frame(width: 90, alignment: .leading)

                                Text(entry.target)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline.monospaced())
                            .monospacedDigit()
                            .padding(.horizontal, Spacing.inset)
                            .padding(.vertical, Spacing.compact)

                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private func fdFilterButton(_ kind: FDEntry.FDKind?, title: String) -> some View {
        Button(title) {
            fdFilter = kind
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(fdFilter == kind ? Color.accentColor : nil)
        .accessibilityLabel("Filter by \(title)")
    }
}
