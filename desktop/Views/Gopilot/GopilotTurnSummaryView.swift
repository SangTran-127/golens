import SwiftUI

struct GopilotTurnChangesCard: View {
    @Environment(\.windowWorkspace) private var workspace
    let changes: [GopilotTurnChange]
    let isLive: Bool
    let refresh: () -> Void
    let review: (UUID) -> Void
    let saveAll: () -> Void
    let undoAll: () async -> GopilotUndoAllResult
    @State private var undoResult: GopilotUndoAllResult?
    @State private var isUndoing = false

    private var pendingCount: Int {
        Set(changes.filter { $0.status == .pendingReview }.map(\.proposalID)).count
    }

    private var unsavedCount: Int {
        Set(changes.filter { $0.status == .applied && $0.isUnsaved }.map(\.path)).count
    }

    private var summaryText: String {
        let files = Set(changes.map(\.path)).count
        var parts = ["\(files) file\(files == 1 ? "" : "s")"]
        if pendingCount > 0 { parts.append("\(pendingCount) waiting for review") }
        if unsavedCount > 0 { parts.append("\(unsavedCount) unsaved") }
        return parts.joined(separator: " · ")
    }

    private var canUndo: Bool {
        changes.contains { $0.status == .applied || $0.status == .pendingReview }
    }

    var body: some View {
        let unsaved = unsavedCount
        VStack(alignment: .leading, spacing: Spacing.standard) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Changes in This Turn")
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(changes) { change in
                    changeRow(change)
                }
            }

            if let undoResult {
                undoResultView(undoResult)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.standard) {
                    undoButton
                    Spacer(minLength: 0)
                    saveButton(unsaved: unsaved)
                }
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    saveButton(unsaved: unsaved)
                    undoButton
                }
            }
            .controlSize(.small)
        }
        .gopilotCard()
        .onAppear(perform: refresh)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes in this turn: \(summaryText)")
    }

    private func saveButton(unsaved: Int) -> some View {
        Button(unsaved > 1 ? "Save All (\(unsaved))" : "Save All") {
            saveAll()
        }
        .fixedSize()
        .disabled(unsaved == 0 || isLive)
        .help(unsaved == 0 ? "No unsaved changes from this turn" : "Save the files Gopilot changed in this turn")
    }

    private var undoButton: some View {
        Button(isUndoing ? "Undoing…" : "Undo All Changes") {
            isUndoing = true
            Task { @MainActor in
                undoResult = await undoAll()
                isUndoing = false
            }
        }
        .fixedSize()
        .disabled(!canUndo || isLive || isUndoing)
        .help(isLive ? "Available when Gopilot finishes" : "Undo every change Gopilot applied in this turn and reject the ones waiting for review")
    }

    private func changeRow(_ change: GopilotTurnChange) -> some View {
        let fileName = (change.path as NSString).lastPathComponent
        let root = workspace.activeWorkspacePath
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            FileIconView(
                fileName: fileName,
                path: root.isEmpty ? nil : root + "/" + change.path,
                isSelected: false,
                size: FileIconSize.compact
            )
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 0) {
                Text(fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(change.path)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    if change.isNewFile {
                        Text("New")
                            .foregroundStyle(.secondary)
                    }
                    lineCounts(change)
                    if change.status == .applied && change.isUnsaved {
                        Text("Unsaved")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                if let detail = change.detail, change.status == .failed || change.status == .pendingReview {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            status(change)
        }
        .accessibilityElement(children: .combine)
    }

    private func lineCounts(_ change: GopilotTurnChange) -> some View {
        HStack(spacing: Spacing.compact) {
            if change.additions > 0 {
                Text("+\(change.additions)")
                    .foregroundStyle(StatusTone.success.tint)
            }
            if change.deletions > 0 {
                Text("−\(change.deletions)")
                    .foregroundStyle(StatusTone.failure.tint)
            }
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityLabel("\(change.additions) lines added, \(change.deletions) removed")
    }

    @ViewBuilder
    private func status(_ change: GopilotTurnChange) -> some View {
        switch change.status {
        case .applied:
            Label("Applied", systemImage: StatusTone.success.symbol)
                .foregroundStyle(StatusTone.success.tint)
                .font(.subheadline)
                .fixedSize()
        case .pendingReview:
            Button("Review…") {
                review(change.proposalID)
            }
            .controlSize(.small)
            .fixedSize()
            .help("Waiting for your review. Read the diff, then apply or reject it.")
            .accessibilityLabel("Waiting for review. Review \(change.path)")
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
        case .failed:
            Label("Failed", systemImage: StatusTone.failure.symbol)
                .font(.subheadline)
                .foregroundStyle(StatusTone.failure.tint)
                .fixedSize()
        case .undone:
            Label("Undone", systemImage: "arrow.uturn.backward.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func undoResultView(_ result: GopilotUndoAllResult) -> some View {
        var lines: [String] = []
        if result.revertedFiles > 0 {
            lines.append("Undid changes to \(result.revertedFiles) file\(result.revertedFiles == 1 ? "" : "s").")
        }
        if result.rejectedProposals > 0 {
            lines.append("Rejected \(result.rejectedProposals) change\(result.rejectedProposals == 1 ? "" : "s") waiting for review.")
        }
        if !result.collisions.isEmpty {
            let names = result.collisions.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            lines.append("Not undone because they changed afterwards: \(names). Use the differences shown to restore them by hand.")
        }
        lines.append(contentsOf: result.failures)
        if lines.isEmpty {
            lines.append("Nothing to undo.")
        }
        return Label {
            Text(lines.joined(separator: " "))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: result.isComplete ? StatusTone.success.symbol : StatusTone.warning.symbol)
                .foregroundStyle(result.isComplete ? StatusTone.success.tint : StatusTone.warning.tint)
        }
        .font(.subheadline)
    }
}

struct GopilotComposerStatusLine: View {
    @Bindable var gopilot: GopilotState
    let isAwaitingPermission: Bool
    var previewPendingProposal: UUID?

    private var runningStepLabel: String? {
        for item in gopilot.items.reversed() {
            if case .activity(_, let label, .running) = item, label != "Updating task plan" {
                return label
            }
        }
        return nil
    }

    private var firstPendingProposal: UUID? {
        gopilot.turnChanges.first { $0.status == .pendingReview }?.proposalID ?? previewPendingProposal
    }

    private var pendingCount: Int {
        max(gopilot.pendingReviewCount, previewPendingProposal == nil ? 0 : 1)
    }

    var body: some View {
        Group {
            if gopilot.mode == .agent {
                sandboxLine
            }
            if gopilot.isRunning && !isAwaitingPermission {
                HStack(spacing: Spacing.standard) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    Text(runningStepLabel ?? "Gopilot is working")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            } else if pendingCount > 0 {
                let count = pendingCount
                HStack(spacing: Spacing.standard) {
                    Image(systemName: "doc.badge.clock")
                        .foregroundStyle(StatusTone.warning.tint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("\(count) change\(count == 1 ? "" : "s") waiting for review")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let proposalID = firstPendingProposal {
                        Button("Review…") {
                            Task { await gopilot.review(proposalID) }
                        }
                        .controlSize(.small)
                        .help("Read the diff, then apply or reject it")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private var sandboxLine: some View {
        switch gopilot.sandboxStatus {
        case .starting(let phase):
            HStack(spacing: Spacing.standard) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text(phase.isEmpty ? "Starting Linux container" : "Starting Linux container: \(phase)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("Gopilot runs Go checks and tests in the Linux container")
        case .unavailable(let reason, let recovery):
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                    Image(systemName: StatusTone.failure.symbol)
                        .foregroundStyle(StatusTone.failure.tint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text("Linux container unavailable")
                            .font(.callout.weight(.medium))
                        Text([reason, recovery].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("Restart Container") { gopilot.restartLinuxContainer() }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Gopilot can't run Go checks or tests until the container is running")
                }
            }
            .accessibilityElement(children: .contain)
        case .ready, .paused, .stopped:
            EmptyView()
        }
    }
}
