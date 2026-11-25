import SwiftUI
import AppKit

struct LocalSearchView: View {
    var paneID: EditorPaneID = .primary
    @Environment(\.windowWorkspace) private var workspace
    @FocusState private var isFindFieldFocused: Bool
    @FocusState private var isReplaceFieldFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var pane: EditorPaneState {
        workspace.paneState(for: paneID)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { pane.findQuery },
            set: { newValue in
                if workspace.isSplitMode && workspace.focusedPaneID != paneID {
                    workspace.focusedPaneID = paneID
                }
                workspace.setLocalSearchQuery(newValue, in: paneID)
            }
        )
    }

    private var replaceBinding: Binding<String> {
        Binding(
            get: { pane.replaceQuery },
            set: { newValue in
                if workspace.isSplitMode && workspace.focusedPaneID != paneID {
                    workspace.focusedPaneID = paneID
                }
                pane.replaceQuery = newValue
            }
        )
    }

    private var matchCaseBinding: Binding<Bool> {
        Binding(
            get: { pane.isCaseSensitiveSearch },
            set: { newValue in
                var opts = pane.findOptions
                opts.matchCase = newValue
                workspace.setFindOptions(opts, in: paneID)
                restoreFindFocusIfUnfocused()
            }
        )
    }

    private var wholeWordsBinding: Binding<Bool> {
        Binding(
            get: { pane.wholeWordsSearch },
            set: { newValue in
                var opts = pane.findOptions
                opts.wholeWords = newValue
                workspace.setFindOptions(opts, in: paneID)
                restoreFindFocusIfUnfocused()
            }
        )
    }

    private var regexBinding: Binding<Bool> {
        Binding(
            get: { pane.isRegexSearch },
            set: { newValue in
                var opts = pane.findOptions
                opts.regex = newValue
                workspace.setFindOptions(opts, in: paneID)
                restoreFindFocusIfUnfocused()
            }
        )
    }

    var body: some View {
        VStack(spacing: Spacing.row) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Find", text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($isFindFieldFocused)
                    .background(
                        LocalFindFocusTrigger(
                            requestID: pane.findFocusRequestID,
                            paneID: paneID
                        )
                    )
                    .onKeyPress { press in
                        if press.key == .return {
                            if press.modifiers.contains(.shift) {
                                workspace.selectPreviousLocalMatch(in: paneID)
                            } else {
                                workspace.selectNextLocalMatch(in: paneID)
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onExitCommand {
                        workspace.setShowLocalSearch(false, in: paneID)
                    }

                HStack(spacing: Spacing.hairline) {
                    FindOptionToggle(title: "Match Case", glyph: Text("Aa"), isOn: matchCaseBinding)
                    FindOptionToggle(title: "Whole Words", glyph: Text("ab").underline(), isOn: wholeWordsBinding)
                    FindOptionToggle(title: "Regular Expression", glyph: Text(".*"), isOn: regexBinding)
                }

                if !pane.findQuery.isEmpty {
                    Text(matchCountText)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(patternFailed ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(patternFailed ? StatusTone.failure.fill : ThemeColor.wellFill)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                        .help(pane.localSearchTimedOut ? "This regular expression took more than \(Int(TextFinder.timeLimit)) seconds, so the search stopped. Try a simpler pattern." : "")
                }

                Divider().frame(height: 14)

                HStack(spacing: Spacing.compact) {
                    Button(action: { workspace.selectPreviousLocalMatch(in: paneID) }) {
                        Image(systemName: "chevron.up").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Previous Match")
                    .accessibilityLabel("Previous Match")
                    .disabled(pane.localSearchMatches.isEmpty)

                    Button(action: { workspace.selectNextLocalMatch(in: paneID) }) {
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Next Match (↩)")
                    .accessibilityLabel("Next Match")
                    .disabled(pane.localSearchMatches.isEmpty)
                }

                Divider().frame(height: 14)

                Button(action: { workspace.setShowLocalSearch(false, in: paneID) }) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .help("Close Find Bar (Esc)")
                .accessibilityLabel("Close Find Bar")
            }

            HStack(spacing: Spacing.standard) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(width: 11)

                TextField("Replace With", text: replaceBinding)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($isReplaceFieldFocused)
                    .onExitCommand {
                        workspace.setShowLocalSearch(false, in: paneID)
                    }

                Spacer()

                Button(action: { workspace.replaceCurrentLocalMatch(in: paneID) }) {
                    Text("Replace")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(pane.localSearchMatches.isEmpty)

                Button(action: { workspace.replaceAllLocalMatches(in: paneID) }) {
                    Text("Replace All")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(pane.localSearchMatches.isEmpty)
            }
        }
        .padding(.horizontal, Spacing.inset)
        .padding(.vertical, Spacing.standard)
        .frame(width: 360)
        .floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)
        .onAppear {
            focusFindFieldIfRequested()
            if !pane.findQuery.isEmpty {
                workspace.performLocalSearch(in: paneID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { note in
            if let clip = note.object as? NSClipView,
               clip === workspace.editorTextView(for: paneID)?.enclosingScrollView?.contentView {
                workspace.applyLocalSearchHighlights(in: paneID)
            }
        }
        .onChange(of: pane.findFocusRequestID) { _, _ in
            isFindFieldFocused = true
        }
        .onChange(of: isFindFieldFocused) { _, focused in
            if focused && workspace.isSplitMode && workspace.focusedPaneID != paneID {
                workspace.focusedPaneID = paneID
            }
        }
        .onChange(of: isReplaceFieldFocused) { _, focused in
            if focused && workspace.isSplitMode && workspace.focusedPaneID != paneID {
                workspace.focusedPaneID = paneID
            }
        }
    }

    private func focusFindFieldIfRequested() {
        guard pane.findFieldTakesFocus else {
            pane.findFieldTakesFocus = true
            return
        }
        isFindFieldFocused = true
    }

    private func restoreFindFocusIfUnfocused() {
        if !isReplaceFieldFocused {
            pane.findFocusRequestID &+= 1
            isFindFieldFocused = true
        }
    }

    private var patternFailed: Bool {
        pane.localSearchInvalid || pane.localSearchTimedOut
    }

    private var matchCountText: String {
        if pane.localSearchInvalid { return "Invalid Pattern" }
        if pane.localSearchTimedOut { return "Pattern Too Slow" }
        if pane.localSearchMatches.isEmpty { return "0/0" }
        let total = pane.localSearchMatches.count.formatted() + (pane.localSearchTruncated ? "+" : "")
        return "\(pane.currentLocalMatchIndex + 1)/\(total)"
    }
}

private struct LocalFindFocusTrigger: NSViewRepresentable {
    let requestID: Int
    let paneID: EditorPaneID

    func makeNSView(context: Context) -> FocusBridgeView {
        let view = FocusBridgeView()
        view.paneID = paneID
        view.triggerFocus(for: requestID)
        return view
    }

    func updateNSView(_ nsView: FocusBridgeView, context: Context) {
        nsView.paneID = paneID
        nsView.triggerFocus(for: requestID)
    }

    final class FocusBridgeView: NSView {
        var paneID: EditorPaneID = .primary
        private var handledRequestID: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let req = handledRequestID {
                handledRequestID = nil
                triggerFocus(for: req)
            }
        }

        func triggerFocus(for requestID: Int) {
            guard handledRequestID != requestID else { return }
            let pane = WorkspaceState.owning(window: window).paneState(for: paneID)
            guard pane.findFieldTakesFocus else {
                handledRequestID = requestID
                return
            }
            if focusEnclosingFindField() {
                handledRequestID = requestID
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.focusEnclosingFindField() {
                    self.handledRequestID = requestID
                }
            }
        }

        @discardableResult
        private func focusEnclosingFindField() -> Bool {
            guard let window else { return false }
            var node: NSView? = superview
            while let current = node {
                if let field = Self.findEditableField(in: current) {
                    if let editor = window.firstResponder as? NSTextView,
                       editor.isFieldEditor,
                       editor.delegate === field {
                        return true
                    }
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                    return (window.firstResponder as? NSTextView)?.isFieldEditor == true || window.firstResponder === field
                }
                node = current.superview
            }
            return false
        }

        private static func findEditableField(in root: NSView) -> NSTextField? {
            if let tf = root as? NSTextField, tf.isEditable {
                if tf.placeholderString == "Find" || tf.placeholderString == nil {
                    return tf
                }
            }
            for sub in root.subviews {
                if let found = findEditableField(in: sub) {
                    return found
                }
            }
            return nil
        }
    }
}

private struct FindOptionToggle: View {
    let title: String
    let glyph: Text
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            glyph
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(isOn ? Color(nsColor: .alternateSelectedControlTextColor) : ThemeColor.textSecondary)
                .frame(minWidth: 20, minHeight: 18)
                .background(
                    isOn ? ThemeColor.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
