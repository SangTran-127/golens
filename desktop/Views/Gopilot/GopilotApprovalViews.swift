import GopilotAnalysis
import GopilotPolicy
import GopilotTools
import SwiftUI

struct GopilotApprovalContent: Equatable {
    var title: String
    var rows: [(title: String, value: String)]
    var command: String
    var notes: [String]
    var warning: String
    var accessibilitySummary: String
    var sessionScope: String = GopilotApprovalContent.sessionScope(maxRuns: 20, lifetime: 3600)

    static func sessionScope(maxRuns: Int, lifetime: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = lifetime >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        let duration = formatter.string(from: max(lifetime, 60)) ?? "\(Int(lifetime / 60)) minutes"
        let runs = maxRuns == 1 ? "once" : "up to \(maxRuns) times"
        return "\(runs) within \(duration)"
    }

    static func == (lhs: GopilotApprovalContent, rhs: GopilotApprovalContent) -> Bool {
        lhs.title == rhs.title
            && lhs.command == rhs.command
            && lhs.notes == rhs.notes
            && lhs.warning == rhs.warning
            && lhs.sessionScope == rhs.sessionScope
            && lhs.rows.map(\.title) == rhs.rows.map(\.title)
            && lhs.rows.map(\.value) == rhs.rows.map(\.value)
    }

    init(title: String, rows: [(title: String, value: String)], command: String, notes: [String], warning: String, accessibilitySummary: String) {
        self.title = title
        self.accessibilitySummary = accessibilitySummary
        self.rows = rows
        self.command = command
        self.notes = notes
        self.warning = warning
    }

    init(card: ExecutionApprovalCard) {
        let isBenchmark = card.operation == .runBenchmark
        var rows: [(title: String, value: String)] = [("Package", card.packageSelector)]
        if !card.items.isEmpty {
            rows.append((card.itemsLabel, card.items.joined(separator: ", ")))
        }
        rows.append(("Folder", card.workingDirectory))
        rows.append(("Limit", "\(card.timeoutSeconds) s, \(isBenchmark ? "\(card.goCount) samples" : "1 run")"))
        if !card.envNames.isEmpty {
            rows.append(("Environment", card.envNames.joined(separator: ", ")))
        }
        self.init(
            title: card.title,
            rows: rows,
            command: card.argv.joined(separator: " "),
            notes: card.mismatches.contains(.noGrant) ? [] : card.mismatches.map(\.explanation),
            warning: card.warning,
            accessibilitySummary: card.accessibilitySummary
        )
        sessionScope = Self.sessionScope(maxRuns: card.sessionGrantMaxRuns, lifetime: card.sessionGrantLifetime)
    }
}

struct GopilotApprovalCardView: View {
    let content: GopilotApprovalContent
    let decide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(StatusTone.warning.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(content.title)
                        .font(.body.weight(.semibold))
                    Text("Waiting for your permission")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                    detailRow(row.title, row.value)
                }
            }
            Text(content.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Command: \(content.command)")
            ForEach(Array(content.notes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.warning.isEmpty {
                Text(content.warning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.standard) {
                    declineButton
                    Spacer(minLength: 0)
                    sessionButton
                    onceButton
                }
                VStack(alignment: .trailing, spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) {
                        sessionButton
                        onceButton
                    }
                    declineButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .controlSize(.small)
            Text("Allow for Session lets Gopilot run this same command again without asking, \(content.sessionScope). It ends sooner when project files change or you close the project.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .gopilotCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.accessibilitySummary). Waiting for your permission.")
    }

    private var declineButton: some View {
        Button("Decline") { decide(.decline) }
            .fixedSize()
            .help("Don't run it. Gopilot is told you declined.")
    }

    private var sessionButton: some View {
        Button("Allow for Session") { decide(.allowForSession) }
            .fixedSize()
            .help("Run this command now and again without asking, \(content.sessionScope), until project files change")
    }

    private var onceButton: some View {
        Button("Allow Once") { decide(.allowOnce) }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Run this command one time")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GopilotDirtyCardView: View {
    let paths: [String]
    let decide: (DirtyBufferDecision) -> Void
    @State private var selected: Set<String>

    init(paths: [String], decide: @escaping (DirtyBufferDecision) -> Void) {
        self.paths = paths
        self.decide = decide
        _selected = State(initialValue: Set(paths))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundStyle(StatusTone.warning.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("Unsaved Changes")
                    .font(.body.weight(.semibold))
            }
            Text("Gopilot read these files from the editor, but tests run the version saved on disk. Choose which files to save first.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(paths, id: \.self) { path in
                Toggle(isOn: Binding(
                    get: { selected.contains(path) },
                    set: { value in if value { selected.insert(path) } else { selected.remove(path) } }
                )) {
                    Text(path).font(.callout)
                }
                .toggleStyle(.checkbox)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.standard) {
                    cancelButton
                    Spacer(minLength: 0)
                    savedVersionButton
                    saveButton
                }
                VStack(alignment: .trailing, spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) {
                        savedVersionButton
                        saveButton
                    }
                    cancelButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .controlSize(.small)
        }
        .gopilotCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unsaved changes. Choose how to run tests.")
    }

    private var cancelButton: some View {
        Button("Cancel") { decide(.cancel) }.fixedSize()
    }

    private var savedVersionButton: some View {
        Button("Run Saved Version") { decide(.runSavedVersion) }.fixedSize()
    }

    private var saveButton: some View {
        Button("Save Selected and Run") { decide(.saveSelectedAndRun(paths: paths.filter { selected.contains($0) })) }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(selected.isEmpty)
    }
}
