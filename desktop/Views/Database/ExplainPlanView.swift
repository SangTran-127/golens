import SwiftUI

struct ExplainPlanRow: Identifiable, Hashable {
    let node: DBPlanNode
    let depth: Int
    let costFraction: Double

    var id: Int { node.id }
}

enum ExplainPlanLayout {
    static func rows(_ plan: DBPlan) -> [ExplainPlanRow] {
        var children: [Int?: [DBPlanNode]] = [:]
        for node in plan.nodes { children[node.parent, default: []].append(node) }
        let maxCost = plan.nodes.compactMap(\.cost).max() ?? 0
        var rows: [ExplainPlanRow] = []
        func visit(_ node: DBPlanNode, depth: Int) {
            rows.append(ExplainPlanRow(node: node, depth: depth, costFraction: maxCost > 0 ? (node.cost ?? 0) / maxCost : 0))
            for child in children[node.id] ?? [] { visit(child, depth: depth + 1) }
        }
        let ids = Set(plan.nodes.map(\.id))
        for root in plan.nodes where root.parent.map({ !ids.contains($0) }) ?? true {
            visit(root, depth: 0)
        }
        return rows
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func time(_ ms: Double?) -> String {
        guard let ms else { return "" }
        return UserMessage.duration(ms / 1000)
    }
}

struct ExplainPlanView: View {
    let outcome: DBExplainOutcome
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Int?
    @State private var showsRaw = false

    private var plan: DBPlan? { outcome.result.plan }

    var body: some View {
        VStack(spacing: 0) {
            if outcome.result.rolledBack {
                InlineBanner(
                    .symbol("arrow.uturn.backward"),
                    title: "Changes Rolled Back",
                    message: "GoLens ran the statement inside a transaction to measure it and rolled it back, so the data is unchanged."
                )
            }
            if let plan {
                header(plan)
                Divider()
                if showsRaw {
                    ReadOnlyCodeView(text: plan.raw)
                } else {
                    outline(plan)
                }
            } else if outcome.result.error == nil {
                UnifiedEmptyState.empty(
                    symbol: DatabaseSymbol.explain,
                    title: "No Plan",
                    message: "The database returned no plan for this statement."
                )
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ plan: DBPlan) -> some View {
        HStack(spacing: Spacing.standard) {
            Text(summary(plan))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.standard)
            Picker("View", selection: $showsRaw) {
                Text("Outline").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Plan View")
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private func summary(_ plan: DBPlan) -> String {
        var parts = [outcome.analyze ? "Explain Analyze" : "Explain Plan", UserMessage.count(plan.nodes.count, "node")]
        if let planning = plan.planningMs { parts.append("Planning \(ExplainPlanLayout.time(planning))") }
        if let execution = plan.executionMs { parts.append("Execution \(ExplainPlanLayout.time(execution))") }
        if let rows = plan.actualRows { parts.append(UserMessage.quantity(Int(rows), "row")) }
        return parts.joined(separator: " · ")
    }

    private func outline(_ plan: DBPlan) -> some View {
        let rows = ExplainPlanLayout.rows(plan)
        let hasActual = plan.nodes.contains { $0.actRows != nil || $0.timeMs != nil }
        let selected = rows.first { $0.id == selection }
        return VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Node") { row in
                    nodeLabel(row, mostExpensive: plan.mostExpensive == row.id)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Relation") { row in
                    Text(row.node.relation).font(.body.monospaced())
                }
                .width(min: 80, ideal: 140)
                TableColumn("Est. Rows") { row in
                    Text(ExplainPlanLayout.number(row.node.estRows)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 80)
                TableColumn("Actual Rows") { row in
                    Text(ExplainPlanLayout.number(row.node.actRows)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 88)
                TableColumn("Loops") { row in
                    Text(ExplainPlanLayout.number(row.node.loops)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 44, ideal: 56)
                TableColumn("Cost") { row in
                    Text(ExplainPlanLayout.number(row.node.cost)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 72)
                TableColumn("Time") { row in
                    Text(ExplainPlanLayout.time(row.node.timeMs)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 80)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel(hasActual ? "Measured plan" : "Estimated plan")
            if let selected, !selected.node.detail.isEmpty {
                Divider()
                ScrollView {
                    Text(selected.node.detail)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.comfortable)
                }
                .frame(maxHeight: ExplainPlanMetrics.detailHeight)
                .background(ThemeColor.panelSurface)
                .accessibilityLabel("Details of \(selected.node.label)")
            }
        }
    }

    private func nodeLabel(_ row: ExplainPlanRow, mostExpensive: Bool) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(row.node.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.node.label)
            if mostExpensive {
                Text("Most Expensive")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        Capsule().fill(DataVizTone.heatFill(fraction: 1, isDark: colorScheme == .dark))
                    )
                    .overlay(
                        Capsule().strokeBorder(DataVizTone.heatStroke(fraction: 1, isDark: colorScheme == .dark), lineWidth: Stroke.hairline)
                    )
            }
        }
        .padding(.leading, CGFloat(row.depth) * Spacing.section)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.label + (mostExpensive ? ", most expensive" : "") + (row.depth > 0 ? ", level \(row.depth + 1)" : ""))
    }
}

enum ExplainPlanMetrics {
    static let detailHeight: CGFloat = 140
}
