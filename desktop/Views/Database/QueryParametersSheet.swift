import SwiftUI

struct QueryParametersSheet: View {
    @Bindable var workspace: WorkspaceState
    let prompt: DBParameterPrompt

    private struct Entry: Identifiable {
        let parameter: DBParameter
        var value: String
        var isNull: Bool
        var isSecret: Bool

        var id: String { parameter.name }
    }

    @State private var entries: [Entry] = []
    @State private var prepared = false
    @FocusState private var focused: String?

    var body: some View {
        StandardSheetShell(
            title: "Query Parameters",
            subtitle: "GoLens sends these values to the database separately from the statement, so they are never run as SQL.",
            scopeBadge: workspace.database.definition(prompt.dataSourceID)?.name,
            size: .generator,
            primaryTitle: prompt.actionTitle,
            primaryAccessibilityLabel: "\(prompt.actionTitle) with These Values",
            closeTitle: "Cancel",
            onPrimary: run,
            onClose: { workspace.finishDatabaseParameterPrompt(prompt, values: nil) }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                GeneratorSection("Values") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.comfortable, verticalSpacing: Spacing.standard) {
                        ForEach($entries) { $entry in
                            GridRow {
                                VStack(alignment: .leading, spacing: Spacing.hairline) {
                                    Text(entry.parameter.name)
                                        .font(.body.monospaced())
                                    if !entry.parameter.typeHint.isEmpty {
                                        Text(entry.parameter.typeHint)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .gridColumnAlignment(.trailing)
                                field($entry)
                                Toggle("NULL", isOn: $entry.isNull)
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("\(entry.parameter.name) is NULL")
                                Toggle("Secret", isOn: $entry.isSecret)
                                    .toggleStyle(.checkbox)
                                    .help("Keep this value out of the query history and don’t remember it.")
                                    .accessibilityLabel("\(entry.parameter.name) is secret")
                            }
                        }
                    }
                }
                GeneratorCodePreview(
                    code: prompt.statementText,
                    accessibilityLabel: "Statement",
                    path: "preview.sql",
                    copyHelp: "Copy the statement to the clipboard"
                )
            }
        }
        .onAppear(perform: prepare)
        .onDisappear { workspace.finishDatabaseParameterPrompt(prompt, values: nil) }
    }

    @ViewBuilder
    private func field(_ entry: Binding<Entry>) -> some View {
        let name = entry.wrappedValue.parameter.name
        let prompt = Text(entry.wrappedValue.parameter.typeHint.isEmpty ? "Value" : entry.wrappedValue.parameter.typeHint)
        Group {
            if entry.wrappedValue.isSecret {
                SecureField("Value of \(name)", text: entry.value, prompt: prompt)
            } else {
                TextField("Value of \(name)", text: entry.value, prompt: prompt)
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .disabled(entry.wrappedValue.isNull)
        .focused($focused, equals: name)
        .onSubmit(run)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        entries = prompt.parameters.map { parameter in
            let remembered = prompt.remembered[parameter.name]
            return Entry(
                parameter: parameter,
                value: remembered?.value ?? "",
                isNull: remembered?.isNull ?? false,
                isSecret: remembered?.isSecret ?? false
            )
        }
        DispatchQueue.main.async { focused = entries.first?.id }
    }

    private func run() {
        let values = entries.map { entry in
            DBParamValue(name: entry.parameter.name, value: entry.isNull ? "" : entry.value, isNull: entry.isNull, secret: entry.isSecret ? true : nil)
        }
        workspace.finishDatabaseParameterPrompt(prompt, values: values)
    }
}
