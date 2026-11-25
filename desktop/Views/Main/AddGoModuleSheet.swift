import AppKit
import SwiftUI

struct AddGoModuleSheet: View {
    @Environment(\.windowWorkspace) private var workspace
    let close: () -> Void
    @State private var path = ""
    @State private var version = ""
    @FocusState private var pathFocused: Bool

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedVersion: String { version.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var spec: String { trimmedVersion.isEmpty ? trimmedPath : "\(trimmedPath)@\(trimmedVersion)" }
    private var isValid: Bool { !trimmedPath.isEmpty && WorkspaceState.isGoGetSpec(spec) }

    var body: some View {
        StandardSheetShell(
            title: "Add Go Module",
            subtitle: "Runs go get in the module folder and updates go.mod and go.sum.",
            size: .compact,
            primaryTitle: "Add",
            isPrimaryDisabled: !isValid,
            closeTitle: "Cancel",
            onPrimary: {
                workspace.addGoModule(spec)
                close()
            },
            onClose: close
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                Form {
                    TextField("Module or package:", text: $path, prompt: Text("go.mongodb.org/mongo-driver/v2/mongo"))
                        .focused($pathFocused)
                        .background(PopupFieldAutoFocus())
                        .onSubmit {
                            if isValid {
                                workspace.addGoModule(spec)
                                close()
                            }
                        }
                    TextField("Version:", text: $version, prompt: Text("latest"))
                }
                .formStyle(.columns)

                Text(trimmedPath.isEmpty || isValid
                     ? "Leave Version empty for the latest release."
                     : "Enter a module path such as golang.org/x/sync, without spaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { pathFocused = true }
    }
}
