import SwiftUI

struct InteractiveRebaseSheet: View {
    let from: String?
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var range: InteractiveRebaseRange?
    @State private var steps: [InteractiveRebaseStep] = []
    @State private var selection: String?
    @State private var loadError: String?

    private var problem: String? {
        guard let range else { return nil }
        if range.hasMerges {
            return "These commits include a merge, which interactive rebase would flatten. Start from a commit after the last merge."
        }
        return InteractiveRebasePlan.problem(steps, original: range.steps.map(\.commit.hash))
    }

    private var selectedIndex: Int? { steps.firstIndex { $0.id == selection } }

    var body: some View {
        StandardSheetShell(
            title: "Interactive Rebase",
            subtitle: subtitle,
            scopeBadge: range?.branch,
            size: .generator,
            primaryTitle: "Start Rebasing",
            isPrimaryDisabled: range == nil || problem != nil,
            closeTitle: "Cancel",
            onPrimary: start,
            onClose: { dismiss() },
            footerLeading: { footer }
        ) {
            if let loadError {
                InlineBanner(.status(.warning), title: "Can’t Rebase From Here", message: loadError)
                Spacer(minLength: 0)
            } else if range == nil {
                ProgressView("Loading Commits…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                notices
                stepList
                messageEditor
            }
        }
        .task { await load() }
    }

    private var subtitle: String {
        guard let range else { return "Reorder, reword, squash or drop commits on the current branch." }
        let count = range.steps.count == 1 ? "1 commit" : "\(range.steps.count) commits"
        return "Replays \(count) on top of \(range.baseTitle), top to bottom. Drag a commit to reorder it."
    }

    @ViewBuilder
    private var notices: some View {
        if let range, range.pushedCount > 0 {
            InlineBanner(
                .status(.warning),
                title: range.pushedCount == 1 ? "1 commit is already on a remote" : "\(range.pushedCount) commits are already on a remote",
                message: "Rewriting them means the next push needs a force push, and anyone who pulled them has to rebase too."
            )
        }
        if !workspace.git.changedFiles.isEmpty {
            InlineBanner(
                .symbol("archivebox"),
                title: "Uncommitted changes are set aside",
                message: "GoLens stashes them before the rebase and restores them when it finishes."
            )
        }
    }

    private var stepList: some View {
        List(selection: $selection) {
            ForEach($steps) { $step in
                InteractiveRebaseStepRow(step: $step)
                    .tag(step.id)
                    .onChange(of: step.action) { _, action in
                        if action == .reword { selection = step.id }
                    }
            }
            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 160, maxHeight: .infinity)
        .accessibilityLabel("Commits to Rebase")
    }

    @ViewBuilder
    private var messageEditor: some View {
        if let index = selectedIndex {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(steps[index].action == .reword ? "New Message" : "Message")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if steps[index].action == .reword {
                    TextEditor(text: $steps[index].message)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.compact)
                        .wellBackground(cornerRadius: CornerRadius.control)
                        .frame(height: 88)
                        .accessibilityLabel("New message for “\(steps[index].commit.subject)”")
                } else {
                    ScrollView {
                        Text(steps[index].message)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.standard)
                    }
                    .wellBackground(cornerRadius: CornerRadius.control)
                    .frame(height: 88)
                    .help("Choose Reword to change this message")
                }
            }
        } else {
            Text("Select a commit to see its message. Choose Reword to change it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.standard) {
            Button {
                move(by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Move Up: apply the selected commit earlier")
            .accessibilityLabel("Move Up")
            .disabled((selectedIndex ?? 0) == 0)
            Button {
                move(by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .help("Move Down: apply the selected commit later")
            .accessibilityLabel("Move Down")
            .disabled(selectedIndex.map { $0 >= steps.count - 1 } ?? true)
            if let problem {
                Text(problem)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.borderless)
    }

    private func move(by offset: Int) {
        guard let index = selectedIndex else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    private func load() async {
        do {
            let loaded = try await workspace.loadInteractiveRebaseRange(from: from, branch: workspace.git.branchName)
            range = loaded
            steps = loaded.steps
            selection = loaded.steps.last?.id
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func start() {
        guard let range, problem == nil else { return }
        let plan = steps
        dismiss()
        workspace.runInteractiveRebase(range, steps: plan)
    }
}

struct InteractiveRebaseStepRow: View {
    @Binding var step: InteractiveRebaseStep

    private var folds: Bool { step.action == .squash || step.action == .fixup }

    var body: some View {
        HStack(spacing: Spacing.standard) {
            Picker("Action", selection: $step.action) {
                ForEach(InteractiveRebaseAction.allCases) { action in
                    Label(action.title, systemImage: action.symbol).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(step.action.help)
            .accessibilityLabel("Action for “\(step.commit.subject)”")
            Text(step.commit.shortHash)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if folds {
                Image(systemName: "arrow.turn.left.up")
                    .foregroundStyle(.secondary)
                    .help("Folded into the commit above")
                    .accessibilityHidden(true)
            }
            Text(step.action == .reword && step.rewordsMessage ? firstLine(step.message) : step.commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(step.action == .drop)
                .foregroundStyle(step.action == .drop || folds ? .secondary : .primary)
            Spacer(minLength: Spacing.compact)
            Text(step.commit.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, Spacing.hairline)
        .accessibilityElement(children: .contain)
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}
