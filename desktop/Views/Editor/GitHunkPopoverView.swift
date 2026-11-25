import AppKit
import SwiftUI

struct GitHunkPopoverView: View {
    let hunk: GitDiffHunk
    let onShow: () -> Void
    let onStage: () -> Void
    let onDiscard: () -> Void
    var onClose: (() -> Void)? = nil

    private func perform(_ action: () -> Void) {
        action()
        onClose?()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Text("Change at Line \(max(1, hunk.newStart))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hunk.removedLines.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(hunk.removedLines.isEmpty)
                .accessibilityLabel("Copy Original Lines")
                .help("Copy the original lines to the clipboard")
            }

            HStack(spacing: Spacing.standard) {
                Button { perform(onShow) } label: {
                    Label("Show Change", systemImage: "eye")
                }
                Button { perform(onStage) } label: {
                    Label("Stage Change", systemImage: "plus.circle")
                }
                .help("Stage this change for the next commit")
                Button(role: .destructive) { perform(onDiscard) } label: {
                    Label("Discard Change", systemImage: "trash")
                }
                .help(KeymapStore.shared.labeled("Discard this change", "git.revertHunk"))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            if hunk.removedLines.isEmpty && hunk.addedLines.isEmpty {
                Text("No diff lines")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.standard)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunk.removedLines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: Spacing.row) {
                                Text("-")
                                    .foregroundStyle(StatusTone.failure.tint)
                                Text(line)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.subheadline.monospaced())
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.hairline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StatusTone.failure.fill)
                        }

                        ForEach(Array(hunk.addedLines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: Spacing.row) {
                                Text("+")
                                    .foregroundStyle(StatusTone.success.tint)
                                Text(line)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.subheadline.monospaced())
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.hairline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StatusTone.success.fill)
                        }
                    }
                    .frame(minWidth: 396, alignment: .topLeading)
                }
                .frame(height: min(220, CGFloat(hunk.removedLines.count + hunk.addedLines.count) * 19 + 2))
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
                )
            }
        }
        .padding(Spacing.comfortable)
        .popupWidth(.compact)
    }
}
