import SwiftUI

struct InlineRenameHintView: View {
    let hint: InlineRenameHint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
            Image(systemName: "character.cursor.ibeam")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Rename ‘\(hint.name)’")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hint.isSubmitting {
                    HStack(spacing: Spacing.compact) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Renaming in every file…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let message = hint.message {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                        Image(systemName: StatusTone.failure.symbol)
                            .foregroundStyle(StatusTone.failure.tint)
                            .accessibilityHidden(true)
                        Text(message)
                            .foregroundStyle(StatusTone.failure.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                } else {
                    Text(hint.usages == 1 ? "1 usage in this file" : "\(hint.usages) usages in this file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Press Return to rename everywhere, or Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.standard)
        .frame(maxWidth: PopupWidth.compact.rawValue, alignment: .leading)
        .fixedSize()
        .floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)
        .accessibilityElement(children: .combine)
    }
}
