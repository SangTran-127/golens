import SwiftUI

struct BreakpointEditorView: View {
    @State var spec: BreakpointSpec
    let line: Int
    let apply: (BreakpointSpec) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            Text("Breakpoint at Line \(line)")
                .font(.headline)
            Form {
                TextField("Condition", text: $spec.condition, prompt: Text("i > 10"))
                    .font(.system(.body, design: .monospaced))
                TextField("Hit Count", text: $spec.hitCondition, prompt: Text("5, >5 or %2"))
                    .font(.system(.body, design: .monospaced))
                TextField("Log Message", text: $spec.logMessage, prompt: Text("i = {i}"))
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.columns)
            Text("A breakpoint with a log message prints it to the console and keeps running. Use {expression} to include values.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    apply(spec)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.section)
        .frame(width: 340)
    }
}
