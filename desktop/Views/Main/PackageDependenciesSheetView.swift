import AppKit
import SwiftUI

struct PackageImportEdgeDTO: Codable, Hashable, Identifiable {
    let targetPath: String
    let category: String
    let filePath: String
    let line: Int

    var id: String {
        "\(targetPath):\(filePath):\(line)"
    }
}

struct PackageNodeDTO: Codable, Hashable, Identifiable {
    let importPath: String
    let packageName: String
    let relativeDir: String
    let goFiles: [String]
    let fanIn: Int
    let fanOut: Int
    let imports: [PackageImportEdgeDTO]
    let importedBy: [String]

    var id: String { importPath }
}

struct ImportEdgeLocationDTO: Codable, Hashable, Identifiable {
    let fromPkg: String
    let toPkg: String
    let filePath: String
    let line: Int

    var id: String {
        "\(fromPkg)->\(toPkg):\(filePath):\(line)"
    }
}

struct ImportCycleDTO: Codable, Hashable, Identifiable {
    let id: String
    let chain: [String]
    let edges: [ImportEdgeLocationDTO]
}

struct PackageDependencyReportDTO: Codable, Hashable {
    let modulePath: String
    let packageCount: Int
    let stdlibImportCount: Int
    let externalImportCount: Int
    let cycles: [ImportCycleDTO]
    let packages: [PackageNodeDTO]

    static let empty = PackageDependencyReportDTO(
        modulePath: "",
        packageCount: 0,
        stdlibImportCount: 0,
        externalImportCount: 0,
        cycles: [],
        packages: []
    )
}

enum PackageImportCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All Imports"
    case internalOnly = "Internal"
    case stdlib = "Standard Library"
    case external = "External"

    var id: String { rawValue }

    func matches(_ category: String) -> Bool {
        switch self {
        case .all:
            return true
        case .internalOnly:
            return category == "internal"
        case .stdlib:
            return category == "stdlib"
        case .external:
            return category == "external"
        }
    }
}

struct PackageDependenciesSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var report: PackageDependencyReportDTO = .empty
    @State private var categoryFilter: PackageImportCategoryFilter = .all
    @State private var searchQuery: String = ""

    private var moduleBadgeTitle: String {
        if !report.modulePath.isEmpty {
            return report.modulePath
        }
        if !workspace.activeWorkspacePath.isEmpty {
            return (workspace.activeWorkspacePath as NSString).lastPathComponent
        }
        return "No Module"
    }

    private var filteredPackages: [PackageNodeDTO] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.packages.compactMap { pkg in
            let matchingImports = pkg.imports.filter { imp in
                guard categoryFilter.matches(imp.category) else { return false }
                guard !trimmedQuery.isEmpty else { return true }
                return imp.targetPath.localizedCaseInsensitiveContains(trimmedQuery)
                    || pkg.packageName.localizedCaseInsensitiveContains(trimmedQuery)
                    || pkg.relativeDir.localizedCaseInsensitiveContains(trimmedQuery)
                    || pkg.importPath.localizedCaseInsensitiveContains(trimmedQuery)
            }

            let pkgMatchesQuery = trimmedQuery.isEmpty
                || pkg.packageName.localizedCaseInsensitiveContains(trimmedQuery)
                || pkg.relativeDir.localizedCaseInsensitiveContains(trimmedQuery)
                || pkg.importPath.localizedCaseInsensitiveContains(trimmedQuery)

            if categoryFilter == .all && pkgMatchesQuery && matchingImports.isEmpty && pkg.imports.isEmpty {
                return pkg
            }
            guard !matchingImports.isEmpty else { return nil }
            return PackageNodeDTO(
                importPath: pkg.importPath,
                packageName: pkg.packageName,
                relativeDir: pkg.relativeDir,
                goFiles: pkg.goFiles,
                fanIn: pkg.fanIn,
                fanOut: pkg.fanOut,
                imports: matchingImports,
                importedBy: pkg.importedBy
            )
        }
    }

    private var isScanning: Bool {
        BackgroundFFI.isScanning("packageDependencies")
    }

    var body: some View {
        StandardSheetShell(
            title: "Inspect Package Dependencies",
            subtitle: "Analyze internal package topology, standard library and external imports, fan-in/fan-out, and circular import cycles",
            scopeBadge: moduleBadgeTitle,
            size: .inspector,
            closeTitle: "Close",
            closeAccessibilityLabel: "Close Package Dependencies Inspector",
            onClose: closeSheet,
            headerTrailing: {
                HStack(spacing: Spacing.standard) {
                    InspectorScanningIndicator(isScanning: isScanning)

                    Button {
                        refreshReport()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning)
                    .controlSize(.small)
                    .help("Re-scan workspace package dependencies")
                    .accessibilityLabel("Refresh Package Dependencies")
                }
            },
            footerLeading: {
                if report.cycles.isEmpty && report.packageCount > 0 {
                    HStack(spacing: Spacing.row) {
                        Image(systemName: StatusTone.success.symbol)
                            .font(.caption)
                            .foregroundStyle(StatusTone.success.tint)
                            .accessibilityHidden(true)

                        Text("No circular package dependencies detected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                summaryCardsBar

                filterControlBar

                if !report.cycles.isEmpty {
                    cycleBannerSection
                }

                packageListSection
            }
        }
        .onAppear {
            refreshReport()
        }
    }

    private var summaryCardsBar: some View {
        HStack(alignment: .top, spacing: Spacing.standard) {
            metricCard(
                title: "Internal Packages",
                value: "\(report.packageCount)",
                subtitle: report.packageCount == 1 ? "1 package in module" : "\(report.packageCount) packages in module",
                tint: nil
            )

            metricCard(
                title: "Stdlib Imports",
                value: "\(report.stdlibImportCount)",
                subtitle: "Unique Go stdlib",
                tint: nil
            )

            metricCard(
                title: "External Imports",
                value: "\(report.externalImportCount)",
                subtitle: "Unique 3rd-party",
                tint: nil
            )

            let cycleCount = report.cycles.count
            metricCard(
                title: "Circular Cycles",
                value: "\(cycleCount)",
                subtitle: cycleCount == 0 ? "Acyclic graph" : (cycleCount == 1 ? "1 cycle detected" : "\(cycleCount) cycles detected"),
                tint: cycleCount == 0 ? StatusTone.success.tint : StatusTone.failure.tint
            )
        }
    }

    private var filterControlBar: some View {
        HStack(spacing: Spacing.inset) {
            Picker("Category", selection: $categoryFilter) {
                ForEach(PackageImportCategoryFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Import Category Filter")

            TextField("Filter packages or imports…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityLabel("Filter packages or imports")
        }
    }

    private var cycleBannerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            InlineBanner(
                .status(.failure),
                title: "\(UserMessage.count(report.cycles.count, "Circular Import Cycle")) Detected",
                message: "Go forbids circular imports between packages. Break an edge below to restore a clean build."
            )

            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(report.cycles) { cycle in
                    let chainLabel = cycle.chain.joined(separator: " → ")
                    HStack(alignment: .center, spacing: Spacing.standard) {
                        Text(chainLabel)
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer()

                        if let firstEdge = cycle.edges.first {
                            let edgeFile = (firstEdge.filePath as NSString).lastPathComponent
                            Text("\(edgeFile):\(firstEdge.line)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            Button("Jump to Import") {
                                workspace.jumpToPackageImport(filePath: firstEdge.filePath, line: firstEdge.line)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Jump to Import in \(edgeFile) line \(firstEdge.line)")
                        }
                    }
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.row)
                    .wellBackground(cornerRadius: CornerRadius.panelRow)
                }
            }
            .padding(Spacing.compact)
        }
        .wellBackground(cornerRadius: CornerRadius.compactPanel)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
    }

    private var packageListSection: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack {
                Text("Workspace Packages & Imports")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(filteredPackages.count) of \(report.packages.count) packages shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.standard) {
                    if filteredPackages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(filteredPackages) { pkg in
                            packageCard(pkg)
                        }
                    }
                }
                .padding(.vertical, Spacing.hairline)
            }
            .staleWhileScanning(isScanning)
            .frame(minHeight: 220, maxHeight: 320)
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(report.packages.isEmpty
                        ? "No Go packages found in the current workspace"
                        : "No packages or imports match the current filter")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(report.packages.isEmpty
                        ? "Open a Go workspace containing .go source files to inspect package dependencies."
                        : "Switch the category filter to All Imports or clear the search query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !report.packages.isEmpty && (categoryFilter != .all || !searchQuery.isEmpty) {
                Button("Reset Filters") {
                    categoryFilter = .all
                    searchQuery = ""
                }
                .controlSize(.small)
                .accessibilityLabel("Reset Package Dependency Filters")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.comfortable)
        .wellBackground()
    }

    private func packageCard(_ pkg: PackageNodeDTO) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .accessibilityHidden(true)

                Text("\(pkg.packageName) · \(pkg.relativeDir)")
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)

                if pkg.importPath != pkg.relativeDir {
                    Text(pkg.importPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text("Fan-In: \(pkg.fanIn)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .fill(ThemeColor.wellFill)
                    )

                Text("Fan-Out: \(pkg.fanOut)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .fill(ThemeColor.wellFill)
                    )
            }

            if pkg.imports.isEmpty {
                Text("No imports in this package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(pkg.imports) { imp in
                        importEdgeRow(imp)
                    }
                }
            }
        }
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func importEdgeRow(_ imp: PackageImportEdgeDTO) -> some View {
        let badge = categoryBadgeSpec(for: imp.category)
        let fileName = (imp.filePath as NSString).lastPathComponent

        return HStack(alignment: .center, spacing: Spacing.standard) {
            Text(badge.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.tint)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.hairline)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(ThemeColor.tintFill(badge.tint))
                )

            Text(imp.targetPath)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("\(fileName):\(imp.line)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button("Jump to Import") {
                workspace.jumpToPackageImport(filePath: imp.filePath, line: imp.line)
            }
            .controlSize(.small)
            .accessibilityLabel("Jump to Import \(imp.targetPath) at \(fileName) line \(imp.line)")
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                .fill(ThemeColor.wellFill)
        )
    }

    private func categoryBadgeSpec(for category: String) -> (label: String, tint: Color) {
        switch category {
        case "internal":
            return ("Internal", Color(nsColor: .controlAccentColor))
        case "external":
            return ("External", StatusTone.warning.tint)
        default:
            return ("Stdlib", .secondary)
        }
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
                    .lineLimit(1)
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

    private func refreshReport() {
        workspace.inspectWorkspacePackageDependencies { updated in
            report = updated
        }
    }

    private func closeSheet() {
        if let onClose {
            onClose()
        } else {
            workspace.showPackageDependenciesSheet = false
            dismiss()
        }
    }
}
