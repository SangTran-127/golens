import SwiftUI

struct MergeConflictCompareView: View {
    let current: String
    let incoming: String
    let currentLabel: String
    let incomingLabel: String
    let onResolve: (MergeConflictResolution) -> Void
    let onClose: () -> Void
    let isRebase: Bool

    private struct ConflictLine: Identifiable {
        let id: Int
        let text: String
        let isUnique: Bool
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private var rows: (current: [ConflictLine], incoming: [ConflictLine]) {
        let left = Self.lines(current)
        let right = Self.lines(incoming)
        let diff = right.difference(from: left)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (
            left.enumerated().map { ConflictLine(id: $0.offset, text: $0.element, isUnique: removed.contains($0.offset)) },
            right.enumerated().map { ConflictLine(id: $0.offset, text: $0.element, isUnique: inserted.contains($0.offset)) }
        )
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("Compare Changes")
                .font(.headline)
            HStack(alignment: .top, spacing: Spacing.standard) {
                side(
                    title: "Left",
                    label: currentLabel,
                    rows: rows.current,
                    tint: MergeConflictStyle.left,
                    resolution: .left
                )
                side(
                    title: "Right",
                    label: incomingLabel,
                    rows: rows.incoming,
                    tint: MergeConflictStyle.right,
                    resolution: .right
                )
            }
            HStack(spacing: Spacing.standard) {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Left Then Right") { onResolve(.leftThenRight) }
                    .help(MergeConflictResolution.leftThenRight.tooltip(currentLabel: currentLabel, incomingLabel: incomingLabel, isRebase: isRebase))
                Button("Right Then Left") { onResolve(.rightThenLeft) }
                    .help(MergeConflictResolution.rightThenLeft.tooltip(currentLabel: currentLabel, incomingLabel: incomingLabel, isRebase: isRebase))
            }
            .controlSize(.small)
        }
        .padding(Spacing.section)
        .sheetFrame(.comparison)
    }

    private func side(title: String, label: String, rows: [ConflictLine], tint: Color, resolution: MergeConflictResolution) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.compact) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !label.isEmpty {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button(resolution.actionName) {
                    onResolve(resolution)
                }
                .controlSize(.small)
                .help(resolution.tooltip(currentLabel: currentLabel, incomingLabel: incomingLabel, isRebase: isRebase))
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("No lines")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(Spacing.standard)
                    }
                    ForEach(rows) { row in
                        Text(row.text.isEmpty ? " " : row.text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.hairline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.isUnique ? tint.opacity(MergeConflictStyle.tintOpacity) : Color.clear)
                            .accessibilityLabel(row.isUnique ? "Changed: \(row.text)" : row.text)
                    }
                }
                .padding(.vertical, Spacing.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 64, maxHeight: 280)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) Change")
    }
}
