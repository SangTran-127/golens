import AppKit
import SwiftUI

struct StructFieldLayoutDTO: Codable, Identifiable, Hashable {
    let name: String
    let typeExpr: String
    let tag: String?
    let size: Int
    let align: Int
    let offset: Int
    let paddingBefore: Int

    var id: String {
        "\(offset)-\(name)-\(typeExpr)"
    }

    init(
        name: String,
        typeExpr: String,
        tag: String? = nil,
        size: Int,
        align: Int,
        offset: Int,
        paddingBefore: Int
    ) {
        self.name = name
        self.typeExpr = typeExpr
        self.tag = tag
        self.size = size
        self.align = align
        self.offset = offset
        self.paddingBefore = paddingBefore
    }
}

struct StructLayoutReportDTO: Codable, Hashable {
    let structName: String
    let arch: String
    let wordSize: Int
    let currentSize: Int
    let currentAlign: Int
    let currentPadding: Int
    let tailPadding: Int
    let optimizedSize: Int
    let savedBytes: Int
    let fields: [StructFieldLayoutDTO]
    let optimizedFields: [StructFieldLayoutDTO]
    let editsByPath: [String: [LSPTextEdit]]?
    let error: String?

    init(
        structName: String,
        arch: String,
        wordSize: Int,
        currentSize: Int,
        currentAlign: Int,
        currentPadding: Int,
        tailPadding: Int,
        optimizedSize: Int,
        savedBytes: Int,
        fields: [StructFieldLayoutDTO],
        optimizedFields: [StructFieldLayoutDTO],
        editsByPath: [String: [LSPTextEdit]]? = nil,
        error: String? = nil
    ) {
        self.structName = structName
        self.arch = arch
        self.wordSize = wordSize
        self.currentSize = currentSize
        self.currentAlign = currentAlign
        self.currentPadding = currentPadding
        self.tailPadding = tailPadding
        self.optimizedSize = optimizedSize
        self.savedBytes = savedBytes
        self.fields = fields
        self.optimizedFields = optimizedFields
        self.editsByPath = editsByPath
        self.error = error
    }

    static func == (lhs: StructLayoutReportDTO, rhs: StructLayoutReportDTO) -> Bool {
        lhs.structName == rhs.structName
            && lhs.arch == rhs.arch
            && lhs.wordSize == rhs.wordSize
            && lhs.currentSize == rhs.currentSize
            && lhs.currentAlign == rhs.currentAlign
            && lhs.currentPadding == rhs.currentPadding
            && lhs.tailPadding == rhs.tailPadding
            && lhs.optimizedSize == rhs.optimizedSize
            && lhs.savedBytes == rhs.savedBytes
            && lhs.fields == rhs.fields
            && lhs.optimizedFields == rhs.optimizedFields
            && lhs.error == rhs.error
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(structName)
        hasher.combine(arch)
        hasher.combine(wordSize)
        hasher.combine(currentSize)
        hasher.combine(currentAlign)
        hasher.combine(currentPadding)
        hasher.combine(tailPadding)
        hasher.combine(optimizedSize)
        hasher.combine(savedBytes)
        hasher.combine(fields)
        hasher.combine(optimizedFields)
        hasher.combine(error)
    }
}

struct StructLayoutSheetView: View {
    let report: StructLayoutReportDTO
    let onOptimize: () -> Void
    let onCancel: () -> Void

    private var hasSavings: Bool {
        report.savedBytes > 0
    }

    var body: some View {
        StandardSheetShell(
            title: "Struct Memory Layout — \(report.structName)",
            scopeBadge: "\(report.arch) · \(report.wordSize * 8)-bit",
            size: .medium,
            primaryTitle: "Optimize Struct Field Order",
            primaryAccessibilityLabel: "Optimize Struct Field Order",
            isPrimaryDisabled: !hasSavings || report.fields.count < 2,
            closeTitle: "Close",
            closeAccessibilityLabel: "Close Struct Layout",
            onPrimary: onOptimize,
            onClose: onCancel,
            footerLeading: {
                if !hasSavings && !report.fields.isEmpty {
                    Text("Already Optimal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                HStack(alignment: .top, spacing: Spacing.standard) {
                    metricCard(
                        title: "Current Size: \(report.currentSize) B",
                        subtitle: "Alignment: \(report.currentAlign) B",
                        badgeText: nil,
                        badgeColor: nil
                    )

                    metricCard(
                        title: hasSavings ? "Wasted Padding: \(report.currentPadding) B" : "Alignment Padding: \(report.currentPadding) B",
                        subtitle: hasSavings
                            ? (report.tailPadding > 0 ? "Includes \(report.tailPadding) B tail" : "Zero tail padding")
                            : (report.currentPadding > 0 ? "Required by field alignment" : "Zero padding"),
                        badgeText: nil,
                        badgeColor: hasSavings && report.currentPadding > 0 ? StatusTone.warning.tint : nil
                    )

                    metricCard(
                        title: "Optimized Size: \(report.optimizedSize) B",
                        subtitle: hasSavings ? "Reorder fields by alignment" : "Already optimal",
                        badgeText: hasSavings ? "Saves \(report.savedBytes) B" : nil,
                        badgeColor: hasSavings ? StatusTone.success.tint : nil
                    )
                }

                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text("Field Offsets & Padding")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.row) {
                            if report.fields.isEmpty {
                                Text("Empty struct (0 B)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Spacing.comfortable)
                                    .wellBackground()
                            } else {
                                ForEach(report.fields) { field in
                                    if field.paddingBefore > 0 {
                                        paddingRow(text: "\(field.paddingBefore) B padding")
                                    }

                                    HStack(spacing: Spacing.standard) {
                                        Text("+\(field.offset)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48, alignment: .leading)

                                        Text(field.name)
                                            .font(.callout.monospaced().weight(.medium))
                                            .foregroundStyle(.primary)

                                        Text(field.typeExpr)
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        Text("\(field.size) B · align \(field.align)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, Spacing.inset)
                                    .padding(.vertical, Spacing.row)
                                    .wellBackground()
                                }

                                if report.tailPadding > 0 {
                                    paddingRow(text: "\(report.tailPadding) B tail padding")
                                }
                            }
                        }
                        .padding(.vertical, Spacing.hairline)
                    }
                    .frame(minHeight: 200, maxHeight: 280)
                }
            }
        }
    }

    private func metricCard(
        title: String,
        subtitle: String,
        badgeText: String?,
        badgeColor: Color?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(badgeColor ?? .primary)

            HStack(spacing: Spacing.row) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let badgeText, let badgeColor {
                    Spacer(minLength: 4)
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .fill(ThemeColor.tintFill(badgeColor))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func paddingRow(text: String) -> some View {
        let labelStyle: Color = hasSavings ? StatusTone.warning.tint : .secondary
        let fillStyle: Color = hasSavings ? StatusTone.warning.fill : Color.secondary.opacity(0.18)
        let strokeStyle: Color = hasSavings ? StatusTone.warning.tint.opacity(0.35) : ChromeColor.separator
        let strokeWidth: CGFloat = hasSavings ? Stroke.standard : Stroke.hairline
        return HStack(spacing: Spacing.row) {
            Image(systemName: hasSavings ? StatusTone.warning.symbol : StatusTone.info.symbol)
                .font(.caption2)
                .foregroundStyle(labelStyle)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(labelStyle)
            Spacer()
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.compact)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                .fill(fillStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                .strokeBorder(strokeStyle, lineWidth: strokeWidth)
        )
    }
}
