import AppKit
import SwiftUI

struct MergeEditorView: View {
    let path: String
    @Environment(\.windowWorkspace) private var workspace
    @State private var document: MergeEditorDocument?
    @State private var expanded: Set<Int> = []
    @State private var current = 0
    @State private var isApplying = false
    @State private var confirmsCancel = false
    @State private var errorMessage: String?

    private static let contextLines = 3
    private static let codeFont = TechnicalTypography.codeCanvasNSFont(size: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)

    private var name: String { (path as NSString).lastPathComponent }
    private var isRebase: Bool { workspace.git.mergeOperation == .rebase }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document {
                columnTitles(document)
                Divider()
                content(document)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ThemeColor.contentSurface)
        .onAppear(perform: load)
        .onChange(of: workspace.activeFilePath) { _, newPath in
            if newPath != path { cancel() }
        }
        .onChange(of: workspace.activeWorkspacePath) { workspace.closeSourceControlSurface() }
        .confirmationDialog("Discard your merge choices?", isPresented: $confirmsCancel) {
            Button("Discard Choices", role: .destructive) { workspace.closeSourceControlSurface() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The conflicts you resolved here are not written to “\(name)”.")
        }
        .alert("Couldn’t Apply the Merge", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Merge “\(name)”")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let document {
                let unresolved = document.conflicts.count - document.resolvedCount
                Label(
                    unresolved == 0 ? "All conflicts resolved" : (unresolved == 1 ? "1 conflict left" : "\(unresolved) conflicts left"),
                    systemImage: unresolved == 0 ? StatusTone.success.symbol : StatusTone.warning.symbol
                )
                .font(.subheadline)
                .foregroundStyle(unresolved == 0 ? StatusTone.success.tint : .secondary)
                .labelStyle(.titleAndIcon)
                ControlGroup {
                    Button { step(-1) } label: { Label("Previous Conflict", systemImage: "chevron.up") }
                        .help("Previous Conflict")
                    Button { step(1) } label: { Label("Next Conflict", systemImage: "chevron.down") }
                        .help("Next Conflict")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .fixedSize()
                Menu("Accept All") {
                    Button("Accept All Left") { self.document?.chooseAll(.left) }
                    Button("Accept All Right") { self.document?.chooseAll(.right) }
                }
                .controlSize(.small)
                .fixedSize()
                .help("Resolve every conflict with one side")
            }
            Spacer()
            Button("Cancel") { cancel() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button("Apply Changes") { apply() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(document?.hasChoices != true || isApplying)
                .help(applyHelp)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
    }

    private var applyHelp: String {
        guard let document, document.hasChoices else { return "Resolve at least one conflict first" }
        return document.isFullyResolved
            ? "Write the result to “\(name)” and mark it as resolved"
            : "Write the resolved conflicts to “\(name)”; the others keep their markers"
    }

    private func columnTitles(_ document: MergeEditorDocument) -> some View {
        let first = document.conflicts.first?.region
        let left = first?.currentLabel.isEmpty == false ? first!.currentLabel : "HEAD"
        let right = first?.incomingLabel ?? ""
        return HStack(spacing: 0) {
            columnTitle("Left", detail: isRebase ? "Upstream · \(left)" : "Yours · \(left)", tint: MergeConflictStyle.left)
            Divider()
            columnTitle("Result", detail: "Saved to “\(name)”", tint: nil)
            Divider()
            columnTitle("Right", detail: isRebase ? "Your Commit · \(right)" : "Incoming · \(right)", tint: MergeConflictStyle.right)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(ThemeColor.panelSurface)
    }

    private func columnTitle(_ title: String, detail: String, tint: Color?) -> some View {
        HStack(spacing: Spacing.compact) {
            if let tint {
                Circle()
                    .fill(tint)
                    .frame(width: Spacing.standard, height: Spacing.standard)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.row)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func content(_ document: MergeEditorDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.segments) { segment in
                        switch segment {
                        case .common(let index, let text):
                            commonRow(index: index, text: text)
                        case .conflict(let index):
                            conflictRow(index, in: document)
                                .id(segment.id)
                        }
                    }
                }
            }
            .onChange(of: current) { _, index in
                withAnimation(Motion.quick) { proxy.scrollTo("conflict-\(index)", anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func commonRow(index: Int, text: String) -> some View {
        let lines = Self.lines(text)
        let limit = Self.contextLines * 2 + 2
        if lines.count > limit && !expanded.contains(index) {
            commonColumns(lines.prefix(Self.contextLines).joined(separator: "\n"))
            Button {
                expanded.insert(index)
            } label: {
                Label("Show \(lines.count - Self.contextLines * 2) Unchanged Lines", systemImage: "ellipsis")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .frame(maxWidth: .infinity)
            .background(ThemeColor.panelSurface)
            commonColumns(lines.suffix(Self.contextLines).joined(separator: "\n"))
        } else if !lines.isEmpty {
            commonColumns(lines.joined(separator: "\n"))
        }
    }

    private func commonColumns(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            codeText(text, secondary: true)
            Divider()
            codeText(text, secondary: true)
            Divider()
            codeText(text, secondary: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unchanged lines")
    }

    private func conflictRow(_ index: Int, in document: MergeEditorDocument) -> some View {
        let conflict = document.conflicts[index]
        let status = conflict.choice.map { "resolved with \($0.title)" } ?? "unresolved"
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                sideControls(index: index, choice: .left, systemImage: "arrow.right.circle", title: "Accept Left")
                Divider()
                resultControls(index: index, conflict: conflict, total: document.conflicts.count)
                Divider()
                sideControls(index: index, choice: .right, systemImage: "arrow.left.circle", title: "Accept Right")
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(ThemeColor.panelSurface)
            HStack(alignment: .top, spacing: 0) {
                codeText(Self.trimmed(conflict.current), secondary: false)
                    .background(MergeConflictStyle.left.opacity(MergeConflictStyle.tintOpacity))
                Divider()
                resultEditor(index: index, conflict: conflict)
                Divider()
                codeText(Self.trimmed(conflict.incoming), secondary: false)
                    .background(MergeConflictStyle.right.opacity(MergeConflictStyle.tintOpacity))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(conflict.isResolved ? StatusTone.success.tint : StatusTone.warning.tint)
                .frame(width: Spacing.hairline)
                .accessibilityHidden(true)
        }
        .overlay {
            Rectangle()
                .strokeBorder(index == current ? ThemeColor.accent : ThemeColor.separator, lineWidth: index == current ? Stroke.standard : Stroke.hairline)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conflict \(index + 1) of \(document.conflicts.count), \(status)")
    }

    private func sideControls(index: Int, choice: MergeEditorChoice, systemImage: String, title: String) -> some View {
        HStack {
            if choice == .right { Spacer(minLength: 0) }
            Button {
                document?.choose(choice, for: index)
                current = index
            } label: {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderless)
            .help(MergeEditorView.tooltip(choice, conflict: document?.conflicts[index], isRebase: isRebase))
            .accessibilityLabel("\(title) for Conflict \(index + 1)")
            if choice == .left { Spacer(minLength: 0) }
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .frame(maxWidth: .infinity)
    }

    private func resultControls(index: Int, conflict: MergeEditorConflict, total: Int) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: conflict.isResolved ? StatusTone.success.symbol : StatusTone.warning.symbol)
                .foregroundStyle(conflict.isResolved ? StatusTone.success.tint : StatusTone.warning.tint)
                .accessibilityHidden(true)
            Text(conflict.choice.map { "Conflict \(index + 1) of \(total): \($0.title)" } ?? "Conflict \(index + 1) of \(total): Unresolved")
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu("Both") {
                Button("Left Then Right") { document?.choose(.leftThenRight, for: index); current = index }
                Button("Right Then Left") { document?.choose(.rightThenLeft, for: index); current = index }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Keep both versions")
            .accessibilityLabel("Keep Both for Conflict \(index + 1)")
            Button("Reset") { document?.reset(index) }
                .buttonStyle(.borderless)
                .disabled(!conflict.isResolved)
                .help("Put the conflict back as unresolved")
                .accessibilityLabel("Reset Conflict \(index + 1)")
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func resultEditor(index: Int, conflict: MergeEditorConflict) -> some View {
        let text = Binding<String>(
            get: { document?.displayText(for: index) ?? "" },
            set: { newValue in
                guard document?.displayText(for: index) != newValue else { return }
                document?.edit(newValue, for: index)
                current = index
            }
        )
        let shown = conflict.isResolved ? text.wrappedValue : ""
        let lineCount = max(Self.lines(conflict.isResolved ? shown : (conflict.base ?? "")).count, Self.lines(Self.trimmed(conflict.current)).count, Self.lines(Self.trimmed(conflict.incoming)).count, 1)
        ZStack(alignment: .topLeading) {
            if !conflict.isResolved {
                Text(conflict.base.map { Self.trimmed($0) } ?? "Choose a side, or type the result here.")
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.standard + Spacing.compact)
                    .padding(.vertical, Spacing.compact)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.horizontal, Spacing.compact)
                .padding(.vertical, Spacing.compact)
                .frame(height: CGFloat(lineCount) * Self.lineHeight + Spacing.standard * 2)
                .accessibilityLabel("Result of Conflict \(index + 1)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(conflict.isResolved ? Color.clear : StatusTone.warning.fill)
    }

    private func codeText(_ text: String, secondary: Bool) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.callout.monospaced())
            .foregroundStyle(secondary ? ThemeColor.textSecondary : ThemeColor.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func trimmed(_ text: String) -> String {
        lines(text).joined(separator: "\n")
    }

    static func tooltip(_ choice: MergeEditorChoice, conflict: MergeEditorConflict?, isRebase: Bool) -> String {
        guard let resolution = choice.resolution else { return "" }
        return resolution.tooltip(currentLabel: conflict?.region.currentLabel ?? "", incomingLabel: conflict?.region.incomingLabel ?? "", isRebase: isRebase)
    }

    private func load() {
        guard document == nil, let session = workspace.documents[path] else { return }
        document = MergeEditorDocument(text: session.storage.string)
    }

    private func step(_ offset: Int) {
        guard let count = document?.conflicts.count, count > 0 else { return }
        current = (current + offset + count) % count
    }

    private func cancel() {
        if document?.hasChoices == true {
            confirmsCancel = true
        } else {
            workspace.closeSourceControlSurface()
        }
    }

    private func apply() {
        guard let document else { return }
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await workspace.applyMergeEditor(document, path: path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
