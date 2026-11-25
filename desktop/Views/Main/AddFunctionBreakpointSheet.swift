import SwiftUI

struct AddFunctionBreakpointSheet: View {
    @Environment(\.windowWorkspace) private var workspace
    let close: () -> Void
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var problem: String? { workspace.functionBreakpointInputProblem(name) }

    var body: some View {
        StandardSheetShell(
            title: "Add Function Breakpoint",
            subtitle: "While you debug, the program pauses each time this function starts.",
            size: .compact,
            primaryTitle: "Add",
            isPrimaryDisabled: problem != nil,
            closeTitle: "Cancel",
            onPrimary: add,
            onClose: close
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                Form {
                    TextField("Function:", text: $name, prompt: Text("main.handler"))
                        .focused($nameFocused)
                        .background(PopupFieldAutoFocus())
                        .accessibilityLabel("Function Name")
                        .onSubmit(add)
                }
                .formStyle(.columns)

                Text(name.isEmpty ? "Use the package and function name, such as main.handler, or a method such as (*Server).Serve." : (problem ?? "The breakpoint applies to every debug session in this project."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func add() {
        guard problem == nil else { return }
        workspace.addFunctionBreakpoint(name)
        workspace.showBreakpointsNavigator()
        close()
    }
}
