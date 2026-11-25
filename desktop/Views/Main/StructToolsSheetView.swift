import AppKit
import SwiftUI

struct StructTagsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowWorkspace) private var workspace

    @State private var actionMode: String = "add"
    @State private var useJSON: Bool = true
    @State private var useYAML: Bool = false
    @State private var useDB: Bool = false
    @State private var useXML: Bool = false
    @State private var transform: String = "snake"
    @State private var omitEmpty: Bool = false

    private var selectedTags: [String] {
        var tags: [String] = []
        if useJSON { tags.append("json") }
        if useYAML { tags.append("yaml") }
        if useDB { tags.append("db") }
        if useXML { tags.append("xml") }
        return tags
    }

    private var transformedSampleKey: String {
        switch transform {
        case "camel":
            return "userId"
        case "pascal":
            return "UserID"
        case "kebab":
            return "user-id"
        default:
            return "user_id"
        }
    }

    private var livePreviewText: String {
        if actionMode == "remove" {
            if selectedTags.isEmpty {
                return "UserID int"
            }
            return "UserID int // removes \(selectedTags.joined(separator: ", "))"
        }
        let activeTags = selectedTags.isEmpty ? ["json"] : selectedTags
        let parts = activeTags.map { key -> String in
            let suffix = (omitEmpty && key != "db") ? ",omitempty" : ""
            return "\(key):\"\(transformedSampleKey)\(suffix)\""
        }
        return "UserID int `\(parts.joined(separator: " "))`"
    }

    var body: some View {
        StandardSheetShell(
            title: "Go Struct Tags",
            subtitle: "Add, update, or remove struct field tags on the struct at the cursor.",
            size: .compact,
            primaryTitle: actionMode == "remove" ? "Remove Tags" : "Apply Tags",
            primaryAccessibilityLabel: "Apply Struct Tags",
            isPrimaryDisabled: actionMode == "add" && selectedTags.isEmpty,
            closeTitle: "Cancel",
            closeAccessibilityLabel: "Cancel Struct Tags",
            onPrimary: {
                workspace.applyStructTags(
                    action: actionMode,
                    tags: selectedTags,
                    transform: transform,
                    omitEmpty: omitEmpty
                )
            },
            onClose: {
                workspace.showStructTagsSheet = false
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text("Action")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Action", selection: $actionMode) {
                        Text("Add / Update Tags").tag("add")
                        Text("Remove Tags").tag("remove")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Struct Tag Action")
                }

                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text(actionMode == "remove" ? "Tags to Remove (leave unchecked to remove all)" : "Tag Keys")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.section) {
                        Toggle("json", isOn: $useJSON)
                            .font(.callout.monospaced())
                        Toggle("yaml", isOn: $useYAML)
                            .font(.callout.monospaced())
                        Toggle("db", isOn: $useDB)
                            .font(.callout.monospaced())
                        Toggle("xml", isOn: $useXML)
                            .font(.callout.monospaced())
                    }
                    .toggleStyle(.checkbox)
                }

                if actionMode == "add" {
                    VStack(alignment: .leading, spacing: Spacing.standard) {
                        Text("Key Case Transform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Key Case Transform", selection: $transform) {
                            Text("snake_case").tag("snake")
                            Text("camelCase").tag("camel")
                            Text("PascalCase").tag("pascal")
                            Text("kebab-case").tag("kebab")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Key Case Transform")

                        Toggle("Append ,omitempty (except db)", isOn: $omitEmpty)
                            .font(.callout)
                            .toggleStyle(.checkbox)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text("Preview")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(livePreviewText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.inset)
                        .wellBackground()
                }
            }
        }
    }
}

struct PasteJSONAsStructSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowWorkspace) private var workspace

    @State private var structName: String = "Payload"
    @State private var jsonInput: String = "{\n  \"id\": 1,\n  \"user_name\": \"golens\",\n  \"active\": true\n}"
    @State private var preview: String = ""

    private var isUpdatingPreview: Bool {
        BackgroundFFI.isScanning(GeneratorPreviewKey.jsonToGoStruct)
    }

    private var isError: Bool {
        preview.hasPrefix("//") || preview.isEmpty
    }

    private func refreshPreview() {
        workspace.previewJSONToGoStruct(jsonText: jsonInput, typeName: structName) { updated in
            preview = updated
        }
    }

    var body: some View {
        GeneratorSheet(
            title: "Paste JSON as Go Struct",
            subtitle: "Infer a Go struct definition with json tags from a JSON object or array.",
            primaryTitle: "Insert Struct",
            primaryAccessibilityLabel: "Insert Generated Struct",
            cancelAccessibilityLabel: "Cancel JSON to Struct",
            canConfirm: !jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isError,
            isUpdating: isUpdatingPreview,
            errorMessage: preview.hasPrefix("//") ? String(preview.drop(while: { $0 == "/" || $0 == " " })) : "",
            preview: GeneratorCodePreview(
                code: isError ? "" : preview,
                placeholder: preview.isEmpty ? "Enter valid JSON to preview the generated Go struct." : preview,
                accessibilityLabel: "Go Struct Preview"
            ),
            onCancel: {
                dismiss()
            },
            onConfirm: {
                BackgroundFFI.shared.cancel(GeneratorPreviewKey.jsonToGoStruct)
                workspace.insertJSONStructIntoEditor(jsonText: jsonInput, typeName: structName)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.comfortable) {
                    Text("Struct Name")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Payload", text: $structName)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .background(PopupFieldAutoFocus())
                        .accessibilityLabel("Struct Name")
                }

                VStack(alignment: .leading, spacing: Spacing.row) {
                    Text("JSON Input")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $jsonInput)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.standard)
                        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 168)
                        .wellBackground()
                }
            }
        }
        .onAppear {
            refreshPreview()
        }
        .onChange(of: jsonInput) { _, _ in
            refreshPreview()
        }
        .onChange(of: structName) { _, _ in
            refreshPreview()
        }
    }
}
