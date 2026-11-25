import SwiftUI

struct GoToLineSheetView: View {
    @Environment(\.dismiss) var dismiss
    @State private var lineInput = ""
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            Text("Go to Line")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("Line number (1–\(maxLine))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Line", text: $lineInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .background(PopupFieldAutoFocus())
                    .accessibilityLabel("Line Number")
                    .onSubmit { navigate() }
            }

            HStack(spacing: Spacing.standard) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { navigate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lineInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.section)
        .frame(width: 280)
        .onExitCommand {
            dismiss()
        }
    }

    private var targetPaneID: EditorPaneID {
        workspace.effectiveFocusedPaneID
    }

    private var targetFilePath: String {
        let path = workspace.filePath(for: targetPaneID)
        return path.isEmpty ? workspace.activeFilePath : path
    }

    private var maxLine: Int {
        if let session = workspace.documents[targetFilePath] {
            return max(1, session.lines.count)
        }
        return max(1, workspace.paneState(for: targetPaneID).lineCount)
    }

    private func navigate() {
        let paneID = targetPaneID
        let targetPath = targetFilePath
        guard let line = Int(lineInput.trimmingCharacters(in: .whitespaces)),
              line >= 1, line <= maxLine,
              let textView = workspace.editorTextView(for: paneID) ?? workspace.activeTextView else {
            dismiss()
            return
        }

        let location: Int
        if let golens = textView as? GoLensTextView,
           let idx = golens.characterIndex(forLine: line, col: 1) {
            location = idx
        } else {
            var loc = 0
            let lines = textView.string.components(separatedBy: .newlines)
            for i in 0..<(line - 1) {
                guard i < lines.count else { break }
                loc += lines[i].utf16.count + 1
            }
            location = loc
        }

        if paneID == .primary {
            workspace.recordNavigationJump(toPath: targetPath, line: line, col: 1)
            workspace.cursorLine = line
            workspace.cursorCol = 1
        }
        let pane = workspace.paneState(for: paneID)
        pane.cursorLine = line
        pane.cursorCol = 1
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if let golens = textView as? GoLensTextView {
            golens.highlightLine(line, in: golens)
        }
        dismiss()
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }
}
