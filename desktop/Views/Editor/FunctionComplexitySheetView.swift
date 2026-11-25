import AppKit
import SwiftUI

struct FunctionComplexityItem: Codable, Identifiable, Hashable {
    let name: String
    let packageName: String
    let file: String
    let relFile: String
    let line: Int
    let endLine: Int
    let lineCount: Int
    let paramCount: Int
    let returnCount: Int
    let cyclomatic: Int
    let cognitive: Int
    let maxNesting: Int
    let rating: String
    let drivers: [String]
    let suggestion: String

    var id: String {
        "\(file):\(name):\(line)"
    }
}

struct ComplexityReportDTO: Codable, Hashable {
    let totalFunctions: Int
    let highCount: Int
    let moderateCount: Int
    let goodCount: Int
    let maxCognitive: Int
    let averageCyclomatic: Double
    let functions: [FunctionComplexityItem]
    let summary: String
    let error: String?

    static let empty = ComplexityReportDTO(
        totalFunctions: 0,
        highCount: 0,
        moderateCount: 0,
        goodCount: 0,
        maxCognitive: 0,
        averageCyclomatic: 0.0,
        functions: [],
        summary: "No Go functions found in current scope.",
        error: nil
    )
}

enum FunctionComplexityScope: String, CaseIterable, Identifiable {
    case currentFile = "Current File"
    case workspace = "Workspace Go Files"

    var id: String { rawValue }
}

enum FunctionComplexityFilter: String, CaseIterable, Identifiable {
    case all = "All Functions"
    case needsAttention = "Needs Attention"
    case highOnly = "High Only"

    var id: String { rawValue }

    func matches(_ rating: String) -> Bool {
        switch self {
        case .all:
            return true
        case .needsAttention:
            return rating == "high" || rating == "moderate"
        case .highOnly:
            return rating == "high"
        }
    }
}

struct FunctionComplexitySheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var scope: FunctionComplexityScope = .currentFile
    @State private var filter: FunctionComplexityFilter = .all
    @State private var searchQuery: String = ""
    @State private var report: ComplexityReportDTO = .empty

    private var activeFileHasGoExtension: Bool {
        workspace.activeFilePath.hasSuffix(".go")
    }

    private var filteredFunctions: [FunctionComplexityItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.functions.filter { item in
            guard filter.matches(item.rating) else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(trimmed)
                || item.relFile.localizedCaseInsensitiveContains(trimmed)
                || item.packageName.localizedCaseInsensitiveContains(trimmed)
                || item.drivers.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) })
        }
    }

    private var isScanning: Bool {
        BackgroundFFI.isScanning("functionComplexity")
    }

    var body: some View {
        StandardSheetShell(
            title: "Inspect Function Complexity",
            subtitle: "Measure cyclomatic and cognitive complexity, nesting depth, and refactoring opportunities",
            size: .inspector,
            closeTitle: "Close",
            closeAccessibilityLabel: "Close Function Complexity Inspector",
            onClose: closeSheet,
            headerTrailing: {
                HStack(alignment: .center, spacing: Spacing.standard) {
                    Picker("Scope", selection: $scope) {
                        ForEach(FunctionComplexityScope.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .accessibilityLabel("Complexity Inspection Scope")

                    InspectorScanningIndicator(isScanning: isScanning)

                    Button {
                        refreshReport()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning)
                    .controlSize(.small)
                    .help("Re-run Function Complexity Inspection")
                    .accessibilityLabel("Refresh Function Complexity Inspection")
                }
            },
            footerLeading: {
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                summaryCardsBar
                filterControlBar
                functionsListSection
            }
        }
        .onAppear {
            if !activeFileHasGoExtension {
                scope = .workspace
            }
            refreshReport()
        }
        .onChange(of: scope) { _, _ in
            refreshReport()
        }
    }

    private var summaryCardsBar: some View {
        HStack(alignment: .top, spacing: Spacing.standard) {
            metricCard(
                title: "Total Functions",
                value: "\(report.totalFunctions)",
                subtitle: String(format: "Avg cyclomatic %.1f", report.averageCyclomatic),
                tint: nil
            )

            metricCard(
                title: "High Complexity",
                value: "\(report.highCount)",
                subtitle: report.highCount == 0 ? "None over threshold" : "Cognitive or cyclomatic > 15",
                tint: report.highCount > 0 ? StatusTone.failure.tint : StatusTone.success.tint
            )

            metricCard(
                title: "Moderate",
                value: "\(report.moderateCount)",
                subtitle: "Score ≥ 8 or nesting ≥ 3",
                tint: report.moderateCount > 0 ? StatusTone.warning.tint : nil
            )

            metricCard(
                title: "Max Cognitive",
                value: "\(report.maxCognitive)",
                subtitle: "Peak cognitive score",
                tint: report.maxCognitive > 15
                    ? StatusTone.failure.tint
                    : (report.maxCognitive >= 8 ? StatusTone.warning.tint : StatusTone.success.tint)
            )
        }
    }

    private var filterControlBar: some View {
        HStack(spacing: Spacing.inset) {
            Picker("Filter", selection: $filter) {
                ForEach(FunctionComplexityFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .accessibilityLabel("Function Complexity Filter")

            Spacer()

            TextField("Filter functions…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Filter functions")
        }
    }

    private var functionsListSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.standard) {
                if filteredFunctions.isEmpty {
                    emptyStateCard
                } else {
                    ForEach(filteredFunctions) { item in
                        functionRow(item)
                    }
                }
            }
            .padding(.vertical, Spacing.hairline)
        }
        .staleWhileScanning(isScanning)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(StatusTone.success.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(report.functions.isEmpty
                        ? (scope == .currentFile
                            ? "No Go functions found in the current file"
                            : "No Go functions found across workspace Go files")
                        : "No functions match the current complexity filter")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(report.functions.isEmpty
                        ? "Switch scope to Workspace Go Files or open a Go source file to inspect function complexity."
                        : "Reset the filter to All Functions or clear the search query to see all analyzed functions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Spacing.standard) {
                if report.functions.isEmpty && scope == .currentFile {
                    Button("Inspect Workspace Go Files") {
                        scope = .workspace
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Inspect Workspace Go Files")
                }

                if !report.functions.isEmpty && (filter != .all || !searchQuery.isEmpty) {
                    Button("Reset Filters") {
                        filter = .all
                        searchQuery = ""
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Reset Complexity Filters")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.comfortable)
        .wellBackground()
    }

    private func functionRow(_ item: FunctionComplexityItem) -> some View {
        let badgeColor = ratingColor(for: item.rating)
        let badgeLabel = ratingTitle(for: item.rating)

        return VStack(alignment: .leading, spacing: Spacing.row) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Text(badgeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .fill(ThemeColor.tintFill(badgeColor))
                    )

                Text(item.name)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)

                Text("\(item.relFile):\(item.line)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Cognitive: \(item.cognitive) · Cyclomatic: \(item.cyclomatic) · Nesting: \(item.maxNesting) · \(item.lineCount) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Jump to Function") {
                    jumpTo(item)
                }
                .controlSize(.small)
                .accessibilityLabel("Jump to Function \(item.name)")
            }

            if !item.drivers.isEmpty {
                HStack(spacing: Spacing.row) {
                    ForEach(item.drivers, id: \.self) { driver in
                        Text(driver)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(ThemeColor.wellFill)
                            )
                    }
                }
            }

            if !item.suggestion.isEmpty {
                Text(item.suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func metricCard(
        title: String,
        value: String,
        subtitle: String,
        tint: Color?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint ?? .primary)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func ratingTitle(for rating: String) -> String {
        switch rating {
        case "high":
            return "High"
        case "moderate":
            return "Moderate"
        default:
            return "Good"
        }
    }

    private func ratingColor(for rating: String) -> Color {
        switch rating {
        case "high":
            return StatusTone.failure.tint
        case "moderate":
            return StatusTone.warning.tint
        default:
            return StatusTone.success.tint
        }
    }

    private func refreshReport() {
        workspace.inspectFunctionComplexity(includeWorkspace: scope == .workspace) { updated in
            report = updated
        }
    }

    private func jumpTo(_ item: FunctionComplexityItem) {
        workspace.jumpToFunctionComplexity(filePath: item.file, line: item.line)
        closeSheet()
    }

    private func closeSheet() {
        if let onClose {
            onClose()
        } else {
            workspace.showFunctionComplexitySheet = false
            dismiss()
        }
    }
}
