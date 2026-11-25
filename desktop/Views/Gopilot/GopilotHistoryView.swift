import GopilotStore
import SwiftUI

struct GopilotHistoryView: View {
    @Bindable var gopilot: GopilotState
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("History").font(.headline)
            if let trashed = gopilot.lastTrashed {
                HStack {
                    Text("Deleted \"\(trashed.title)\"")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Undo") { Task { await gopilot.undoTrash() } }
                        .controlSize(.small)
                }
                .padding(Spacing.standard)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
            }
            if gopilot.savedConversations.isEmpty {
                Text("Conversations about this project appear here. They stay on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
                    .padding(.vertical, Spacing.standard)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(gopilot.savedConversations) { summary in
                            HStack(spacing: Spacing.standard) {
                                Button {
                                    Task {
                                        await gopilot.openSaved(summary.id)
                                        dismiss()
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                                        Text(summary.title).font(.callout).lineLimit(1)
                                        Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(summary.title)
                                Button {
                                    Task { await gopilot.trashSaved(summary.id) }
                                } label: {
                                    Label("Delete Conversation", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete Conversation")
                            }
                            .padding(.vertical, Spacing.row)
                            Divider()
                        }
                    }
                }
                .frame(width: 300, height: min(CGFloat(gopilot.savedConversations.count) * 48 + 8, 280))
            }
        }
        .padding(Spacing.section)
        .task { await gopilot.refreshHistory() }
    }
}
