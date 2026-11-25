import AppKit
import SwiftUI

struct BenchmarkComparisonSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    let onClose: () -> Void

    var body: some View {
        StandardSheetShell(
            title: "Compare Benchmarks with Baseline",
            size: .inspector,
            closeTitle: "Close",
            closeAccessibilityLabel: "Close Benchmark Comparison",
            onClose: onClose,
            headerTrailing: {
                HStack(spacing: Spacing.standard) {
                    Button {
                        workspace.runBenchmarks()
                    } label: {
                        Label(workspace.isTestRunning ? "Running…" : "Run Benchmarks", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(workspace.isTestRunning)
                    .help("Run Go benchmarks in workspace (go test -bench=. -benchmem)")
                    .accessibilityLabel("Run Benchmarks")

                    Button {
                        workspace.saveBenchmarkBaseline()
                    } label: {
                        Label("Save Current as Baseline", systemImage: "pin.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(workspace.benchMetrics.isEmpty && workspace.benchmarkDiffItems.allSatisfy { $0.currentNsPerOp <= 0 })
                    .help("Pin current benchmark results as baseline for delta comparison")
                    .accessibilityLabel("Save Current as Baseline")
                }
            },
            footerLeading: {
                if workspace.hasBenchmarkBaseline {
                    Button("Clear Baseline") {
                        workspace.clearBenchmarkBaseline()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Remove saved benchmark baseline for this workspace")
                    .accessibilityLabel("Clear Baseline")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                HStack(alignment: .top, spacing: Spacing.standard) {
                    summaryCard(
                        title: "Faster",
                        count: workspace.benchmarkFasterCount,
                        subtitle: "≤ -3.0% ns/op",
                        symbol: "arrow.down.right.circle.fill",
                        tint: workspace.benchmarkFasterCount > 0 ? StatusTone.success.tint : .secondary
                    )

                    summaryCard(
                        title: "Regressed",
                        count: workspace.benchmarkRegressedCount,
                        subtitle: "≥ +5.0% ns/op",
                        symbol: "arrow.up.right.circle.fill",
                        tint: workspace.benchmarkRegressedCount > 0 ? StatusTone.failure.tint : .secondary
                    )

                    summaryCard(
                        title: "Unchanged",
                        count: workspace.benchmarkUnchangedCount,
                        subtitle: "Within threshold",
                        symbol: "equal.circle.fill",
                        tint: .secondary
                    )
                }

                if let banner = workspace.benchmarkBaselineSavedBanner {
                    HStack(spacing: Spacing.standard) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(StatusTone.success.tint)
                        Text(banner)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("Baseline Saved")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StatusTone.success.tint)
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(StatusTone.success.fill)
                            )
                    }
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.vertical, Spacing.standard)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                            .fill(ThemeColor.wellFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                            .strokeBorder(StatusTone.success.tint.opacity(0.35), lineWidth: Stroke.hairline)
                    )
                }

                VStack(alignment: .leading, spacing: Spacing.row) {
                    HStack(spacing: Spacing.row) {
                        Text("Benchmark Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Baseline")
                            .frame(width: 122, alignment: .leading)
                        Text("Current")
                            .frame(width: 122, alignment: .leading)
                        Text("Δ Time %")
                            .frame(width: 58, alignment: .trailing)
                        Text("Δ Memory")
                            .frame(width: 62, alignment: .trailing)
                        Text("Verdict")
                            .frame(width: 92, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.inset)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.row) {
                            if workspace.benchmarkDiffItems.isEmpty {
                                VStack(spacing: Spacing.standard) {
                                    Image(systemName: "speedometer")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("No Benchmark Results Yet")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Click Run Benchmarks to measure ns/op, B/op, and allocs/op against your saved baseline.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(Spacing.content)
                                .wellBackground()
                            } else {
                                ForEach(workspace.benchmarkDiffItems) { item in
                                    benchmarkRow(item)
                                }
                            }
                        }
                        .padding(.vertical, Spacing.hairline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            workspace.recomputeBenchmarkComparison()
        }
    }

    private func summaryCard(
        title: String,
        count: Int,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.row) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text("\(title): \(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func benchmarkRow(_ item: BenchmarkDiffRow) -> some View {
        HStack(spacing: Spacing.row) {
            Text(item.name)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatMetricsTuple(ns: item.baselineNsPerOp, bytes: item.baselineBytesPerOp, allocs: item.baselineAllocsPerOp))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 122, alignment: .leading)

            Text(formatMetricsTuple(ns: item.currentNsPerOp, bytes: item.currentBytesPerOp, allocs: item.currentAllocsPerOp))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 122, alignment: .leading)

            Text(formatTimeDelta(item))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(verdictColor(item.verdict))
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)

            Text(formatMemoryDelta(item))
                .font(.caption.monospaced())
                .foregroundStyle(memoryDeltaColor(item))
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)

            verdictBadge(item.verdict)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.standard)
        .wellBackground()
    }

    private func formatMetricsTuple(ns: Double, bytes: Int64, allocs: Int64) -> String {
        guard ns > 0 else { return "—" }
        let nsStr = CodeLensProvider.formatNsPerOp(ns)
        if allocs > 0 {
            return "\(nsStr) · \(bytes) B/op · \(allocs) allocs"
        }
        return "\(nsStr) · \(bytes) B/op"
    }

    private func formatTimeDelta(_ item: BenchmarkDiffRow) -> String {
        guard item.baselineNsPerOp > 0 && item.currentNsPerOp > 0 else {
            return "—"
        }
        return String(format: "%+.1f%%", item.nsDeltaPct)
    }

    private func formatMemoryDelta(_ item: BenchmarkDiffRow) -> String {
        guard item.baselineNsPerOp > 0 && item.currentNsPerOp > 0 else {
            return "\(item.currentBytesPerOp) B/op"
        }
        let diffBytes = item.currentBytesPerOp - item.baselineBytesPerOp
        if diffBytes == 0 {
            return "0 B/op"
        }
        return String(format: "%+lld B/op", diffBytes)
    }

    private func memoryDeltaColor(_ item: BenchmarkDiffRow) -> Color {
        let diff = item.currentBytesPerOp - item.baselineBytesPerOp
        if diff < 0 {
            return StatusTone.success.tint
        }
        if diff > 0 {
            return StatusTone.warning.tint
        }
        return .secondary
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "faster":
            return StatusTone.success.tint
        case "regressed":
            return StatusTone.failure.tint
        default:
            return .secondary
        }
    }

    private func verdictSpec(_ verdict: String) -> (label: String, symbol: String, tint: Color) {
        switch verdict {
        case "faster":
            return ("Faster", "arrow.down.right", StatusTone.success.tint)
        case "regressed":
            return ("Regressed", "arrow.up.right", StatusTone.failure.tint)
        case "new":
            return ("New", "gauge.with.dots.needle.33percent", ChromeColor.accent)
        default:
            return ("Unchanged", "equal", .secondary)
        }
    }

    private func verdictBadge(_ verdict: String) -> some View {
        let spec = verdictSpec(verdict)
        return HStack(spacing: Spacing.compact) {
            Image(systemName: spec.symbol)
                .font(.caption2.weight(.bold))
            Text(spec.label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(spec.tint)
        .padding(.horizontal, Spacing.row)
        .padding(.vertical, Spacing.hairline)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(ThemeColor.tintFill(spec.tint))
        )
    }
}
