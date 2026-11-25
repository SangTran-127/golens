import SwiftUI

struct SafetyFinding: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let severity: Int
    let title: String
    let detail: String
    let file: String
    let relFile: String
    let line: Int
    let col: Int
    let symbol: String?
    let callChain: [String]?

    var isSupplyChainFinding: Bool {
        relFile == "go.mod" || relFile.hasSuffix("/go.mod") || file.hasSuffix("/go.mod")
            || id.hasPrefix("DEP_")
    }
}

struct SafetyAuditReport: Codable {
    let findings: [SafetyFinding]
    let summary: String
}

enum SafetyFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case hazards = "Hazards"
    case dependencies = "Dependencies"
    case races = "Races"
    case deadcode = "Dead Code"
    case capabilities = "Capabilities"
    var id: String { rawValue }
}

struct SafetyView: View {
    static let maxSafetyFindings = 200
    @Environment(\.windowWorkspace) private var workspace

    let findings: [SafetyFinding]
    let summary: String
    let isRunning: Bool
    let onRunAudit: () -> Void
    let onClear: () -> Void
    let onSelectFinding: (SafetyFinding) -> Void

    @State private var selectedFilter: SafetyFilter = .all
    @AppStorage("GoLensShowInlineSafety") private var showInlineSafety: Bool = true

    private var supplyChainFindings: [SafetyFinding] {
        findings.filter(\.isSupplyChainFinding)
    }

    private var filteredFindings: [SafetyFinding] {
        let matching: [SafetyFinding]
        switch selectedFilter {
        case .all:
            matching = findings
        case .hazards:
            matching = findings.filter { $0.kind == "hazard" || $0.kind == "vuln" }
        case .dependencies:
            matching = supplyChainFindings
        case .races:
            matching = findings.filter { $0.kind == "race" }
        case .deadcode:
            matching = findings.filter { $0.kind == "deadcode" }
        case .capabilities:
            matching = findings.filter { $0.kind == "capability" }
        }
        if matching.count > Self.maxSafetyFindings {
            return Array(matching.prefix(Self.maxSafetyFindings))
        }
        return matching
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.contentSurface)
    }

    private var topBar: some View {
        HStack(spacing: Spacing.standard) {
            Picker("Category", selection: $selectedFilter) {
                ForEach(SafetyFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Safety finding category filter")

            Text(filteredFindings.count == 1 ? "1 finding" : "\(filteredFindings.count) findings")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("\(filteredFindings.count) safety findings")

            if !supplyChainFindings.isEmpty {
                Button {
                    selectedFilter = .dependencies
                    if let first = supplyChainFindings.first {
                        onSelectFinding(first)
                    }
                } label: {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "shippingbox.fill")
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text("go.mod (\(supplyChainFindings.count))")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(StatusTone.warning.tint)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(StatusTone.warning.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("Filter go.mod Module / Supply Chain findings and jump to go.mod")
                .accessibilityLabel("go.mod Supply Chain findings: \(supplyChainFindings.count)")
            }

            Spacer(minLength: 8)

            Toggle("Inline", isOn: $showInlineSafety)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.subheadline)
                .fixedSize(horizontal: true, vertical: false)
                .help("Show Safety Findings Inline in Editor")
                .accessibilityLabel("Show Safety Findings Inline in Editor")
                .onChange(of: showInlineSafety) { _, _ in
                    workspace.activeTextView?.needsDisplay = true
                }

            Button(action: onRunAudit) {
                Label("Audit", systemImage: "checkmark.shield")
                    .font(.subheadline)
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isRunning)
            .help(KeymapStore.shared.labeled("Run Safety Audit", "product.safetyAudit"))
            .accessibilityLabel("Run Safety Audit")

            Button("Clear", action: onClear)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(findings.isEmpty)
                .help("Clear Safety Findings")
                .accessibilityLabel("Clear Safety Findings")
        }
        .padding(.horizontal, Spacing.comfortable)
        .frame(height: 28)
        .background(
            ThemeColor.panelSurface
        )
    }

    @ViewBuilder
    private var contentArea: some View {
        if isRunning {
            UnifiedEmptyState.loading(
                message: "Scanning AST hazards, dead code, race traces, and vulnerabilities…"
            )
            .accessibilityLabel("Scanning AST hazards, dead code, race traces and vulnerabilities")
        } else if !findings.isEmpty && filteredFindings.isEmpty {
            UnifiedEmptyState.filteredEmpty(itemNoun: "Safety Findings") {
                selectedFilter = .all
            }
        } else if findings.isEmpty {
            UnifiedEmptyState.empty(
                symbol: "checkmark.shield",
                badge: "safety",
                title: "No Safety Findings",
                message: summary.isEmpty
                    ? "Run a \(KeymapStore.shared.labeled("Safety Audit", "product.safetyAudit")) to check for concurrency hazards, dead code, data races, and reachable vulnerabilities."
                    : summary,
                actionTitle: summary.isEmpty ? "Run Safety Audit" : nil,
                action: summary.isEmpty ? onRunAudit : nil
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredFindings) { finding in
                        SafetyFindingRow(
                            finding: finding,
                            onSelect: { onSelectFinding(finding) }
                        )
                        Divider()
                    }
                }
            }
        }
    }
}

struct SafetyFindingRow: View {
    let finding: SafetyFinding
    let onSelect: () -> Void

    @State private var isHovered = false

    private var iconName: String {
        if finding.isSupplyChainFinding {
            if finding.severity == 1 {
                return "lock.shield"
            }
            return "shippingbox.fill"
        }
        switch finding.kind {
        case "race", "vuln":
            return "bolt.trianglebadge.exclamationmark.fill"
        case "hazard":
            return "exclamationmark.shield.fill"
        case "deadcode":
            return "scissors"
        case "capability":
            if finding.id.hasPrefix("CAPABILITY_NETWORK:") {
                return "network"
            } else if finding.id.hasPrefix("CAPABILITY_EXEC:") {
                return "terminal"
            } else if finding.id.hasPrefix("CAPABILITY_FILESYSTEM:") {
                return "externaldrive"
            } else if finding.id.hasPrefix("CAPABILITY_UNSAFE:") {
                return "cpu"
            }
            return "lock.shield"
        default:
            return "exclamationmark.shield.fill"
        }
    }

    private var iconColor: Color {
        if finding.isSupplyChainFinding {
            return finding.severity == 1 ? StatusTone.failure.tint : StatusTone.warning.tint
        }
        switch finding.kind {
        case "race", "vuln":
            return StatusTone.failure.tint
        case "hazard":
            return StatusTone.warning.tint
        case "deadcode":
            return Color(nsColor: .secondaryLabelColor)
        case "capability":
            return Color(nsColor: .secondaryLabelColor)
        default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var locationText: String {
        let path = finding.relFile.isEmpty ? finding.file : finding.relFile
        guard !path.isEmpty else { return "" }
        return "\(path):\(max(1, finding.line))"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Spacing.standard) {
                Image(systemName: iconName)
                    .font(.callout)
                    .foregroundStyle(iconColor)
                    .frame(width: 16, height: 16, alignment: .center)
                    .padding(.top, Spacing.hairline)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                        Text(finding.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if finding.isSupplyChainFinding {
                            HStack(spacing: Spacing.compact) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.caption)
                                    .accessibilityHidden(true)
                                Text("Module / Supply Chain")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(finding.severity == 1 ? StatusTone.failure.tint : StatusTone.warning.tint)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                finding.severity == 1 ? StatusTone.failure.fill : StatusTone.warning.fill,
                                in: Capsule()
                            )
                        }

                        if !locationText.isEmpty {
                            Text(locationText)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if !finding.detail.isEmpty {
                        Text(finding.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let chain = finding.callChain, !chain.isEmpty {
                        Text(chain.joined(separator: " → "))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .background(isHovered ? ThemeColor.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(locationText.isEmpty ? finding.title : "\(finding.title) — \(locationText)")
        .accessibilityLabel(
            finding.isSupplyChainFinding
                ? "\(finding.title), Module / Supply Chain, \(finding.detail), at \(locationText)"
                : "\(finding.title), \(finding.detail), at \(locationText)"
        )
    }
}
