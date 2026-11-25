import AppKit
import GoLensFoundation
import SwiftUI

struct IssuePopupView: View {
    let popup: IssuePopup
    var viewportWidth: CGFloat = 560
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.popupAvailableHeight) private var popupAvailableHeight

    enum DiffMode: String, CaseIterable {
        case sideBySide = "Side-by-Side"
        case unified = "Unified"
    }

    private enum FocusTarget: Hashable {
        case quickFix(UUID)
        case openGeneratorSource
        case rerunTest
        case copyMessage
    }

    @State private var diffMode: DiffMode = .sideBySide
    @State private var didCopyMessage = false
    @FocusState private var focusedControl: FocusTarget?

    private var testFailure: TestFailureAnnotation? {
        popup.testFailure ?? workspace.testFailureAnnotationsForPath(popup.path).first { $0.line == popup.line }
    }

    private var resolvedPopupWidth: CGFloat {
        max(260, min(520, viewportWidth - 32))
    }

    private var diffColumnMinWidth: CGFloat {
        max(110, (resolvedPopupWidth - Spacing.inset * 2 - Spacing.row) / 2 - Spacing.compact * 2)
    }

    private var unifiedDiffMinWidth: CGFloat {
        max(180, resolvedPopupWidth - Spacing.inset * 2 - Spacing.compact * 2)
    }

    private var diffScrollMaxHeight: CGFloat {
        let available = popupAvailableHeight ?? 480
        return min(240, max(120, available - 180))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.inset) {
            if let tf = testFailure {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) {
                        Image(systemName: StatusTone.failure.symbol)
                            .foregroundStyle(StatusTone.failure.tint)
                            .font(.body)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text("Test Failed: \(tf.testName)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .textSelection(.enabled)
                            if tf.diffLines?.isEmpty == false,
                               !tf.message.isEmpty,
                               tf.message != "Test failed",
                               !tf.message.contains("\n"),
                               !tf.message.hasPrefix("Error Trace:") {
                                Text(tf.message)
                                    .font(.caption)
                                    .foregroundStyle(ChromeColor.textSecondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }

                        Spacer()

                        Button {
                            dismissPopupAndRestoreFocus()
                            workspace.rerunTestFailure(tf)
                        } label: {
                            HStack(spacing: Spacing.compact) {
                                Image(systemName: "arrow.clockwise")
                                    .accessibilityHidden(true)
                                Text("Rerun Test")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .controlSize(.small)
                        .focused($focusedControl, equals: .rerunTest)
                    }

                    if let diffLines = tf.diffLines, !diffLines.isEmpty {
                        Picker("Diff Format", selection: $diffMode) {
                            ForEach(DiffMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .accessibilityLabel("Diff Format")

                        if diffMode == .sideBySide {
                            renderSideBySideDiff(diffLines)
                        } else {
                            renderUnifiedDiff(diffLines)
                        }

                        if tf.diffTruncated == true {
                            let total = tf.diffTotalLines ?? diffLines.count
                            Label {
                                Text("Showing first \(UserMessage.integer(diffLines.count)) of \(UserMessage.integer(total)) diff lines. Open Console for full output.")
                                    .font(TechnicalTypography.badgeMicro)
                                    .foregroundStyle(ChromeColor.textSecondary)
                            } icon: {
                                Image(systemName: StatusTone.info.symbol)
                                    .font(TechnicalTypography.badgeMicro)
                                    .foregroundStyle(StatusTone.info.tint)
                            }
                            .accessibilityElement(children: .combine)
                            .help("Full test output and diff are recorded in the Console.")
                        }
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(tf.message)
                                .font(TechnicalTypography.codeCompact)
                                .foregroundStyle(CodeSurfaceTheme.textPrimary)
                                .textSelection(.enabled)
                                .padding(Spacing.row)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: diffScrollMaxHeight)
                        .background(CodeSurfaceTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .strokeBorder(ThemeColor.wellStroke, lineWidth: Stroke.hairline)
                        )
                        .environment(\.colorScheme, CodeSurfaceTheme.isDark ? .dark : .light)
                    }
                }
                .padding(.bottom, Spacing.hairline)

                if !nonTestDiags.isEmpty || !popup.related.isEmpty || !popup.fixes.isEmpty {
                    Divider()
                }
            }

            ForEach(nonTestDiags) { diag in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    Image(systemName: diag.severity == 1 ? StatusTone.failure.symbol : StatusTone.warning.symbol)
                        .foregroundStyle(diag.severity == 1 ? StatusTone.failure.tint : StatusTone.warning.tint)
                        .accessibilityLabel(diag.severity == 1 ? "Error" : "Warning")
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(diag.message)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let label = diag.sourceLabel {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !popup.related.isEmpty {
                Divider()
                Text("Errors elsewhere may cause this:")
                    .foregroundStyle(.secondary)
                ForEach(popup.related) { item in
                    Button {
                        workspace.openIssue(item)
                    } label: {
                        Text("\((item.path as NSString).lastPathComponent):\(item.diag.line + 1) — \(item.diag.message)")
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                    .help("Go to \((item.path as NSString).lastPathComponent), line \(item.diag.line + 1)")
                }
            }

            Divider()

            actionFooter
        }
        .font(.subheadline)
        .padding(Spacing.inset)
        .frame(width: resolvedPopupWidth, alignment: .leading)
        .floatingPanelBackground()
        .onAppear {
            assignInitialFocus()
        }
        .onChange(of: popup.fixes.map(\.id)) {
            if let firstFix = popup.fixes.first {
                if focusedControl == nil || focusedControl == .copyMessage {
                    focusedControl = .quickFix(firstFix.id)
                }
            }
        }
        .onExitCommand {
            dismissPopupAndRestoreFocus()
        }
        .onHover { hovering in
            workspace.lsp.isMouseInsideHoverPopover = hovering
        }
        .onDisappear {
            workspace.lsp.isMouseInsideHoverPopover = false
        }
    }

    private var generatedOrigin: GeneratedFileOriginResult? {
        workspace.generatedOrigin(for: popup.path)
    }

    @ViewBuilder
    private var actionFooter: some View {
        let primaryFixID = popup.fixes.first?.id
        HStack(alignment: .top, spacing: Spacing.standard) {
            if !popup.fixes.isEmpty || generatedOrigin?.sourcePath != nil {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(popup.fixes) { fix in
                        if fix.id == primaryFixID {
                            Button(fix.title) {
                                applyQuickFix(fix)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                            .focused($focusedControl, equals: .quickFix(fix.id))
                            .accessibilityLabel(fix.title)
                        } else {
                            Button(fix.title) {
                                applyQuickFix(fix)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focused($focusedControl, equals: .quickFix(fix.id))
                            .accessibilityLabel(fix.title)
                        }
                    }
                    if let origin = generatedOrigin, origin.sourcePath != nil {
                        Button {
                            let targetPath = popup.path
                            let targetLine = popup.line
                            dismissPopupAndRestoreFocus()
                            workspace.openGeneratedFileOrigin(for: targetPath, line1Based: targetLine)
                        } label: {
                            Label("Open Generator Source", systemImage: "arrow.up.forward.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focused($focusedControl, equals: .openGeneratorSource)
                        .accessibilityLabel("Open Generator Source")
                        .help(origin.sourceDisplayName.map { "Open origin source “\($0)”" } ?? "Open generator source file")
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                copyDiagnosticMessages()
            } label: {
                Label(didCopyMessage ? "Copied" : "Copy Message", systemImage: didCopyMessage ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focused($focusedControl, equals: .copyMessage)
            .accessibilityLabel("Copy Message")
            .help("Copy diagnostic message to clipboard")
        }
    }

    private func assignInitialFocus() {
        if let firstFix = popup.fixes.first {
            focusedControl = .quickFix(firstFix.id)
        } else if testFailure != nil {
            focusedControl = .rerunTest
        } else {
            focusedControl = .copyMessage
        }
    }

    private func applyQuickFix(_ fix: LSPCodeActionItem) {
        if let event = NSApp.currentEvent, [.keyDown, .keyUp].contains(event.type), !popup.acceptsKeyboardActivation(at: event.timestamp) {
            measureLog("quick fix ignored a key pressed before \(fix.title) could be read")
            return
        }
        dismissPopupAndRestoreFocus()
        workspace.performCodeAction(fix)
    }

    private func dismissPopupAndRestoreFocus() {
        workspace.issuePopup = nil
        if let tv = workspace.editorTextView(for: workspace.effectiveFocusedPaneID) ?? workspace.activeTextView {
            tv.window?.makeFirstResponder(tv)
        }
    }

    private func copyDiagnosticMessages() {
        var lines: [String] = []
        if let tf = testFailure {
            lines.append("Test Failed (\(tf.testName)): \(tf.message)")
        }
        for diag in nonTestDiags {
            if let label = diag.sourceLabel {
                lines.append("\(diag.message) [\(label)]")
            } else {
                lines.append(diag.message)
            }
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopyMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopyMessage = false
        }
    }

    private var nonTestDiags: [DiagnosticData] {
        popup.diags.filter { !$0.message.hasPrefix("[Test Failed]") }
    }

    @ViewBuilder
    private func renderSideBySideDiff(_ diffLines: [TestDiffLine]) -> some View {
        let alignedRows = TestFailureDiffAlignment.alignSideBySide(diffLines.map(\.foundationItem))
        let canvasShape = RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)

        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.row) {
                Text("Want (Expected)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StatusTone.success.tint)
                    .padding(.horizontal, Spacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Got (Actual)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StatusTone.failure.tint)
                    .padding(.horizontal, Spacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: Spacing.row) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            ForEach(alignedRows) { row in
                                sideBySideDiffCell(row.want, expectedSide: true)
                            }
                        }
                        .frame(minWidth: diffColumnMinWidth, alignment: .leading)
                        .padding(Spacing.compact)
                    }
                    .frame(maxWidth: .infinity)
                    .background(CodeSurfaceTheme.background)
                    .clipShape(canvasShape)
                    .overlay(canvasShape.strokeBorder(ThemeColor.wellStroke, lineWidth: Stroke.hairline))

                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            ForEach(alignedRows) { row in
                                sideBySideDiffCell(row.got, expectedSide: false)
                            }
                        }
                        .frame(minWidth: diffColumnMinWidth, alignment: .leading)
                        .padding(Spacing.compact)
                    }
                    .frame(maxWidth: .infinity)
                    .background(CodeSurfaceTheme.background)
                    .clipShape(canvasShape)
                    .overlay(canvasShape.strokeBorder(ThemeColor.wellStroke, lineWidth: Stroke.hairline))
                }
            }
            .frame(maxHeight: diffScrollMaxHeight)
            .environment(\.colorScheme, CodeSurfaceTheme.isDark ? .dark : .light)
        }
    }

    @ViewBuilder
    private func sideBySideDiffCell(_ line: TestDiffLineItem?, expectedSide: Bool) -> some View {
        let isChanged = line != nil && line?.type != "same"
        let toneTint = expectedSide ? StatusTone.success.tint : StatusTone.failure.tint
        let toneFill = expectedSide ? StatusTone.success.fill : StatusTone.failure.fill
        let marker = isChanged ? (expectedSide ? "+" : "-") : " "
        HStack(spacing: Spacing.compact) {
            Text(line.map { "\($0.lineNum)" } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CodeSurfaceTheme.lineNumber)
                .frame(minWidth: 24, alignment: .trailing)
            Text(marker)
                .font(TechnicalTypography.codeCompact.weight(.semibold))
                .foregroundStyle(isChanged ? toneTint : CodeSurfaceTheme.lineNumber)
            Text(line?.text ?? " ")
                .font(TechnicalTypography.codeCompact)
                .foregroundStyle(isChanged ? toneTint : CodeSurfaceTheme.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.hairline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isChanged ? toneFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    @ViewBuilder
    private func renderUnifiedDiff(_ diffLines: [TestDiffLine]) -> some View {
        let canvasShape = RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(diffLines) { dl in
                    let isWant = dl.type == "want"
                    let isGot = dl.type == "got"
                    HStack(spacing: Spacing.row) {
                        Text("\(dl.lineNum)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(CodeSurfaceTheme.lineNumber)
                            .frame(minWidth: 24, alignment: .trailing)

                        Text(isWant ? "+" : (isGot ? "-" : " "))
                            .font(TechnicalTypography.codeCompact.weight(.bold))
                            .foregroundStyle(isWant ? StatusTone.success.tint : (isGot ? StatusTone.failure.tint : CodeSurfaceTheme.lineNumber))

                        Text(dl.text)
                            .font(TechnicalTypography.codeCompact)
                            .foregroundStyle(isWant ? StatusTone.success.tint : (isGot ? StatusTone.failure.tint : CodeSurfaceTheme.textPrimary))
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isWant ? StatusTone.success.fill :
                        (isGot ? StatusTone.failure.fill : Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                }
            }
            .frame(minWidth: unifiedDiffMinWidth, alignment: .leading)
            .padding(Spacing.compact)
        }
        .frame(maxHeight: diffScrollMaxHeight)
        .background(CodeSurfaceTheme.background)
        .clipShape(canvasShape)
        .overlay(canvasShape.strokeBorder(ThemeColor.wellStroke, lineWidth: Stroke.hairline))
        .environment(\.colorScheme, CodeSurfaceTheme.isDark ? .dark : .light)
    }
}
