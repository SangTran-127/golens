import AppKit
import GoLensFoundation
import SwiftUI

struct CommitMessageBox: View {
    @Environment(\.windowWorkspace) private var workspace
    private var ui: SourceControlUI { workspace.sourceControlState }
    @State private var isFocused = false

    var body: some View {
        let length = CommitMessageText.subjectLength(ui.commitMessage)
        let isLong = length > 50 && !ui.commitMessageIsMergeMessage
        let noun = length == 1 ? "character" : "characters"
        let subjectText = isLong
            ? "Subject: \(length) \(noun). Keep it under 50 so it reads well in history"
            : "Subject: \(length) \(noun)"
        let subjectColor = isLong ? StatusTone.warning.tint : Color(nsColor: .secondaryLabelColor)
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            CommitMessageTextEditor(
                text: Bindable(ui).commitMessage,
                placeholder: "Commit message (required)",
                focusPending: ui.pendingCommitFocus,
                isEditable: !ui.isCommitting,
                onFocusChange: { focused in
                    if isFocused != focused { isFocused = focused }
                },
                onCommit: { workspace.commitFromEditor(andPush: false) }
            )
            .frame(height: messageHeight)
            .padding(Spacing.row)
            .background(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(border)
            .accessibilityLabel("Commit message")
            Text(subjectText)
                .font(.caption)
                .foregroundStyle(subjectColor)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.bottom, Spacing.standard)
    }

    private var border: some View {
        let color = isFocused ? Color.accentColor : Color(nsColor: .separatorColor)
        return RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
            .strokeBorder(color, lineWidth: isFocused ? 2 : Stroke.standard)
    }

    private var messageHeight: CGFloat {
        let lines = ui.commitMessage.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(8, max(3, lines))) * 16 + 8
    }
}

private struct CommitLoadKey: Hashable {
    let changeStamp: String
    let sides: [String]
    let isCollapsed: Bool
    let reloadToken: Int
    let sessionVersion: Int
}

private enum CommitChangeAction {
    case stage, unstage, discard
}

struct CommitFileDiffDisclosure: View {
    let file: CommitChangeFile
    let scope: CommitScope
    let changeStamp: String
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    @Environment(\.windowWorkspace) private var workspace
    @State private var diffs: [Bool: CommitSideDiff] = [:]
    @State private var isApplying = false
    @State private var fileExists = true
    @State private var reloadToken = 0

    private var sides: [CommitDiffSide] { file.sides(in: scope) }

    var body: some View {
        VStack(spacing: 0) {
            disclosureHeader
            if !isCollapsed {
                Divider()
                ForEach(sides) { side in
                    sideSection(side)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: loadKey) { await loadDiffs() }
    }

    private var loadKey: CommitLoadKey {
        CommitLoadKey(
            changeStamp: changeStamp,
            sides: sides.map { "\($0.isStaged):\($0.file.status)" },
            isCollapsed: isCollapsed,
            reloadToken: reloadToken,
            sessionVersion: workspace.documentSession(forPath: file.absolutePath)?.version ?? 0
        )
    }

    private func loadDiffs() async {
        let path = file.absolutePath
        let exists = await Task.detached(priority: .userInitiated) { FileManager.default.fileExists(atPath: path) }.value
        if fileExists != exists { fileExists = exists }
        guard !isCollapsed else { return }
        for side in sides {
            let loaded = await CommitSideDiff.load(path: file.absolutePath, staged: side.isStaged, isFolder: file.isFolder, in: workspace)
            if Task.isCancelled { return }
            diffs[side.isStaged] = loaded
        }
    }

    private var disclosureHeader: some View {
        HStack(spacing: Spacing.standard) {
            Button(action: toggleCollapsed) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Expand" : "Collapse")
            .accessibilityLabel(isCollapsed ? "Expand \(file.name)" : "Collapse \(file.name)")
            FileIconView(fileName: file.name, path: file.absolutePath, isFolder: file.isFolder, isSelected: false)
            Text(file.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let original = file.originalPath {
                let isCopy = file.staged?.status == "C" || file.unstaged?.status == "C"
                Text(isCopy ? "Copied from \(original)" : "Renamed from \(original)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            ForEach(sides) { side in
                GitStatusBadge(status: side.file.status)
            }
            actionsMenu
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.row)
    }

    private var actionsMenu: some View {
        let hasConflict = sides.contains { $0.file.status == "U" }
        return Menu {
            if sides.contains(where: { !$0.isStaged }) && !hasConflict {
                Button(file.isFolder ? "Stage Folder" : "Stage File", systemImage: "plus.circle") { workspace.stageFile(file.absolutePath) }
            }
            if sides.contains(where: { $0.isStaged }) {
                Button("Unstage File", systemImage: "minus.circle") { workspace.unstageFile(file.absolutePath) }
            }
            Divider()
            if file.isFolder {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.absolutePath)]) }
                    .disabled(!fileExists)
            } else {
                Button("Open File", systemImage: "doc.text") { openFile() }
                    .disabled(!fileExists)
                Button("Show in Diff", systemImage: "arrow.left.arrow.right") { showInDiff() }
            }
            if !hasConflict {
                Divider()
                Button("Discard Changes…", systemImage: "arrow.uturn.backward.circle", role: .destructive) { discardFile() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File Actions")
        .accessibilityLabel("File Actions")
    }

    private func openFile() {
        workspace.closeSourceControlSurface()
        workspace.openFile(file.absolutePath)
    }

    private func showInDiff() {
        workspace.closeSourceControlSurface()
        let staged = sides.first?.isStaged == true
        workspace.openFileInDiff(file.absolutePath, source: staged ? .staged : .unstaged)
    }

    private func discardFile() {
        let target = scope == .staged ? file.staged : (file.unstaged ?? file.staged)
        if let target, target.status != "U" { workspace.confirmDiscard(target) }
    }

    private func sideSection(_ side: CommitDiffSide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if sides.count > 1 {
                Text(side.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.vertical, Spacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .quaternarySystemFill))
            }
            if let diff = diffs[side.isStaged] {
                CommitSideBody(side: side, diff: diff, isBusy: isApplying) { action, hunk in
                    perform(action, hunk: hunk, side: side, diff: diff)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(Spacing.comfortable)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func perform(_ action: CommitChangeAction, hunk: Int, side: CommitDiffSide, diff: CommitSideDiff) {
        guard !isApplying else { return }
        isApplying = true
        let selection = diff.changeSelection(hunk: hunk)
        let path = file.absolutePath
        Task { @MainActor in
            switch action {
            case .stage:
                await workspace.applyGitLineSelection(selection, from: diff.patch, inPath: path, source: .unstaged, fullContext: false)
            case .unstage:
                await workspace.applyGitLineSelection(selection, from: diff.patch, inPath: path, source: .staged, fullContext: false)
            case .discard:
                await workspace.discardGitPatchSelection(selection, from: diff.patch, inPath: path)
            }
            isApplying = false
            reloadToken += 1
        }
    }
}

private struct CommitSideBody: View {
    let side: CommitDiffSide
    let diff: CommitSideDiff
    let isBusy: Bool
    let perform: (CommitChangeAction, Int) -> Void
    @State private var showAll = false

    private static let lineLimit = 300

    var body: some View {
        if diff.isBinary {
            note("Binary file")
        } else if diff.hunks.isEmpty {
            note(diff.message ?? "No textual changes")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleHunks) { entry in
                    hunkView(entry.hunk, shownRows: entry.rows)
                }
                if hiddenLines {
                    Button("Show All \(diff.lineCount) Lines") { showAll = true }
                        .buttonStyle(.link)
                        .padding(Spacing.inset)
                }
            }
        }
    }

    private var hiddenLines: Bool { !showAll && diff.lineCount > Self.lineLimit }

    private struct VisibleHunk: Identifiable {
        let hunk: CommitDiffHunk
        let rows: [CommitDiffRow]
        var id: Int { hunk.id }
    }

    private var visibleHunks: [VisibleHunk] {
        var budget = showAll ? Int.max : Self.lineLimit
        var result: [VisibleHunk] = []
        for hunk in diff.hunks where budget > 0 {
            let rows = budget >= hunk.rows.count ? hunk.rows : Array(hunk.rows.prefix(budget))
            budget -= rows.count
            result.append(VisibleHunk(hunk: hunk, rows: rows))
        }
        return result
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(Spacing.comfortable)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hunkView(_ hunk: CommitDiffHunk, shownRows: [CommitDiffRow]) -> some View {
        let isComplete = shownRows.count == hunk.rows.count
        return VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.inset)
                .padding(.vertical, Spacing.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shownRows) { row in
                    CommitDiffRowView(row: row)
                }
            }
            if isComplete && side.allowsChangeActions {
                actionRow(hunk: hunk.id)
            }
        }
    }

    private func actionRow(hunk: Int) -> some View {
        HStack(spacing: Spacing.standard) {
            Spacer(minLength: 0)
            if !side.isStaged {
                Button("Discard Change", role: .destructive) { perform(.discard, hunk) }
                    .help("Discard this change. Local History keeps a copy when the file is small enough; otherwise you’re asked first.")
            }
            Button(side.isStaged ? "Unstage Change" : "Stage Change") { perform(side.isStaged ? .unstage : .stage, hunk) }
                .help(side.isStaged ? "Remove this change from the commit" : "Add this change to the commit")
        }
        .controlSize(.small)
        .disabled(isBusy)
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.row)
    }
}

private struct CommitDiffRowView: View {
    let row: CommitDiffRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.oldLabel)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(row.newLabel)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(row.marker)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(row.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .background(row.background)
    }
}

final class CommitComposerNSTextView: NSTextView {
    private static let maxCommitLengthUTF16 = 8_192

    var placeholderString: String = "" {
        didSet {
            if oldValue != placeholderString {
                needsDisplay = true
            }
        }
    }
    var onCommitShortcut: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
            needsDisplay = true
        }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command && (event.keyCode == 36 || event.keyCode == 76) {
            onCommitShortcut?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let raw: String
        if let str = insertString as? String {
            raw = str
        } else if let attr = insertString as? NSAttributedString {
            raw = attr.string
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let currentLen = (string as NSString).length
        let effectiveReplacement = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let remaining = max(0, Self.maxCommitLengthUTF16 - (currentLen - effectiveReplacement.length))
        guard remaining > 0 else { return }

        let nsRaw = raw as NSString
        let clipped = nsRaw.length > remaining ? nsRaw.substring(to: remaining) : raw
        super.insertText(clipped, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 2
        let origin = CGPoint(
            x: textContainerInset.width + padding,
            y: textContainerInset.height
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}

struct CommitMessageTextEditor: NSViewRepresentable {
    @Environment(\.windowWorkspace) private var workspace
    @Binding var text: String
    var placeholder: String
    var focusPending = false
    var isEditable = true
    var onFocusChange: (Bool) -> Void
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = CommitComposerNSTextView()
        textView.delegate = context.coordinator
        textView.placeholderString = placeholder
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.onCommitShortcut = onCommit
        textView.onFocusChange = onFocusChange
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = NSFont.systemFont(ofSize: 12)
        let theme = workspace.currentTheme
        let isDark = theme.resolvedIsDark
        textView.textColor = NSColor(ThemeColor.textPrimary)
        textView.insertionPointColor = theme.accentNSColor(isDark: isDark)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CommitComposerNSTextView else { return }
        let theme = workspace.currentTheme
        let isDark = theme.resolvedIsDark
        textView.textColor = NSColor(ThemeColor.textPrimary)
        textView.insertionPointColor = theme.accentNSColor(isDark: isDark)
        textView.placeholderString = placeholder
        textView.isEditable = isEditable
        textView.onCommitShortcut = onCommit
        textView.onFocusChange = onFocusChange
        if focusPending {
            let ui = workspace.sourceControlState
            DispatchQueue.main.async {
                guard ui.pendingCommitFocus, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                ui.pendingCommitFocus = false
            }
        }

        if !context.coordinator.isUpdatingFromTextView && textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            let shouldShowScroller = text.utf8.count > 120 || text.utf8.contains(10)
            if scrollView.hasVerticalScroller != shouldShowScroller {
                scrollView.hasVerticalScroller = shouldShowScroller
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageTextEditor
        var isUpdatingFromTextView = false

        init(_ parent: CommitMessageTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommitComposerNSTextView else { return }
            isUpdatingFromTextView = true
            let current = textView.string
            parent.text = current
            if let scrollView = textView.enclosingScrollView {
                let shouldShowScroller = current.utf8.count > 120 || current.utf8.contains(10)
                if scrollView.hasVerticalScroller != shouldShowScroller {
                    scrollView.hasVerticalScroller = shouldShowScroller
                }
            }
            isUpdatingFromTextView = false
        }
    }
}

