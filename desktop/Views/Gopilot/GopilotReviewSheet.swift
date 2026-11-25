import GopilotAnalysis
import SwiftUI

enum GopilotText {
    static func decodingEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static let applySemantics = "Applies to the editor buffer. Files show Edited until you save them, and Undo (⌘Z) reverts the change."
}

private struct GopilotCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
        content
            .padding(Spacing.comfortable)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .quaternarySystemFill), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard))
    }
}

extension View {
    func gopilotCard() -> some View {
        modifier(GopilotCardModifier())
    }
}

struct GopilotProposalCard: View {
    let summary: String
    let files: Int
    var warnings: [PatchSecurityWarning] = []
    var viewDiff: (() -> Void)? = nil
    var apply: (() -> Void)? = nil
    let review: () -> Void

    private var fileCountText: String {
        "\(files) file\(files == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(summary)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Proposed change · \(fileCountText) · Not applied yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !warnings.isEmpty {
                        Label("Adds " + Set(warnings.map(\.token)).sorted().joined(separator: ", "), systemImage: StatusTone.warning.symbol)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(StatusTone.warning.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.standard) {
                    secondaryActions
                    Spacer(minLength: 0)
                    applyButton
                }
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) { secondaryActions }
                    applyButton
                }
            }
            .controlSize(.small)
        }
        .gopilotCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed change, \(fileCountText), not applied yet: \(summary)")
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button("Review…", action: review)
            .fixedSize()
            .help("Read the full diff before deciding")
        if let viewDiff {
            Button("View Diff", action: viewDiff)
                .fixedSize()
                .help("Open the changed file in the editor's Diff view")
        }
    }

    @ViewBuilder
    private var applyButton: some View {
        if let apply {
            Button("Apply", action: apply)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help(GopilotText.applySemantics)
        }
    }
}

struct GopilotReviewSheet: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var gopilot: GopilotState
    let proposal: PatchProposal

    private var securityWarnings: [PatchSecurityWarning] {
        var baseTexts: [String: String] = [:]
        for op in proposal.operations {
            let fullPath = workspace.activeWorkspacePath + "/" + op.path
            if let text = workspace.documents[fullPath]?.storage.string {
                baseTexts[op.path] = text
            } else if let disk = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                baseTexts[op.path] = disk
            }
        }
        return PatchValidator.securityWarnings(for: proposal, baseTexts: baseTexts)
    }

    private var editorFont: Font {
        .system(size: workspace.editorFontSize, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                Text("Review Changes")
                    .font(.title3.weight(.semibold))
                Text(GopilotText.decodingEntities(proposal.rationale))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !securityWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Label("Sensitive Imports or Directives Added", systemImage: StatusTone.warning.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(StatusTone.warning.tint)
                        ForEach(securityWarnings) { warning in
                            Text("\(warning.path): \(warning.token) — \(warning.reason)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !proposal.verificationPlan.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text("How to Check It")
                            .font(.callout.weight(.semibold))
                        ForEach(proposal.verificationPlan, id: \.self) { step in
                            Text(step)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(Spacing.section)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    ForEach(gopilot.reviewDiffs) { diff in
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Label(diff.isNew ? "\(diff.path) (new file)" : diff.path, systemImage: diff.isNew ? "doc.badge.plus" : "doc.text")
                                .font(.callout.weight(.semibold))
                            diffBody(diff)
                        }
                    }
                }
                .padding(Spacing.section)
            }
            Divider()
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                Label(GopilotText.applySemantics, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.standard) {
                    Button("Reject") { Task { await gopilot.rejectReviewed() } }
                        .help("Decline this proposal. Your project is not changed.")
                    Spacer()
                    Button("Close") { close() }
                        .keyboardShortcut(.cancelAction)
                        .help("Close without deciding. The proposal stays in the conversation.")
                    Button("Apply Changes") { Task { await gopilot.applyReviewed(workspace: workspace) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.section)
        }
        .sheetFrame(.review)
    }

    private func close() {
        gopilot.reviewing = nil
        gopilot.reviewDiffs = []
    }

    private func diffBody(_ diff: GopilotFileDiff) -> some View {
        let changed = diff.lines.contains { $0.kind != .same }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { index, line in
                if line.kind != .same || nearChange(index, diff.lines) {
                    HStack(alignment: .top, spacing: Spacing.standard) {
                        Text(line.kind == .added ? "+" : (line.kind == .removed ? "-" : " "))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text(line.text.isEmpty ? " " : line.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(editorFont)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.hairline)
                    .background(background(line.kind))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(line.kind == .added ? "Added" : (line.kind == .removed ? "Removed" : "Unchanged")): \(line.text)")
                }
            }
            if !changed {
                Text("No visible change")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(Spacing.standard)
            }
            if diff.truncated {
                Label("This diff is too large to show in full. Open it in the editor's Diff view before applying.", systemImage: StatusTone.warning.symbol)
                    .font(.callout)
                    .foregroundStyle(StatusTone.warning.tint)
                    .padding(Spacing.standard)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func nearChange(_ index: Int, _ lines: [DiffLine]) -> Bool {
        let range = max(0, index - 2)...min(lines.count - 1, index + 2)
        return lines[range].contains { $0.kind != .same }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: StatusTone.success.tint.opacity(0.18)
        case .removed: StatusTone.failure.tint.opacity(0.18)
        case .same: Color.clear
        }
    }
}

struct GopilotAppliedRow: View {
    let text: String
    var viewDiff: (() -> Void)? = nil
    let undo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: StatusTone.success.symbol)
                    .foregroundStyle(StatusTone.success.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Spacing.standard) {
                if let viewDiff {
                    Button("View Diff", action: viewDiff)
                        .fixedSize()
                        .help("Open the changed file in the editor's Diff view")
                }
                Button("Undo Change", action: undo)
                    .fixedSize()
                    .help("Revert only the files Gopilot changed, if you have not edited them since")
            }
            .controlSize(.small)
            .padding(.leading, Spacing.content)
        }
        .gopilotCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applied change: \(text)")
    }
}

struct GopilotRecoverySheet: View {
    let diffs: [RecoveryDiff]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                Text("Cannot Undo Automatically").font(.title3.weight(.semibold))
                Text("These files were changed again after Gopilot's change, so reverting would overwrite your edits. Nothing was reverted. Below, each file shows what would change to get back to the original; use it to undo by hand.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.section)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Label("\(diff.path) (\(Self.reason(diff.reason)))", systemImage: "doc.text")
                                .font(.callout.weight(.semibold))
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diff.currentToOriginal.enumerated()), id: \.offset) { _, line in
                                    if line.kind != .same {
                                        HStack(alignment: .top, spacing: Spacing.standard) {
                                            Text(line.kind == .added ? "+" : "-")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 12)
                                                .accessibilityHidden(true)
                                            Text(line.text.isEmpty ? " " : line.text)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.body.monospaced())
                                        .padding(.horizontal, Spacing.standard)
                                        .padding(.vertical, Spacing.hairline)
                                        .background(line.kind == .added ? StatusTone.success.tint.opacity(0.18) : StatusTone.failure.tint.opacity(0.18))
                                    }
                                }
                            }
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                        }
                    }
                }
                .padding(Spacing.section)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.section)
        }
        .sheetFrame(.recovery)
    }

    static func reason(_ reason: UndoCollisionReason) -> String {
        switch reason {
        case .fileMissing: "file is missing"
        case .contentChanged: "edited since"
        case .versionChanged: "edited since"
        }
    }
}
