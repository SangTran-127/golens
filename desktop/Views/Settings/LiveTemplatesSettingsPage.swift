import SwiftUI

struct LiveTemplatesSettingsPage: View {
    @Bindable private var store = LiveTemplateStore.shared
    @State private var editing: EditorTarget?
    @State private var confirmRestore = false
    @State private var templateToDelete: LiveTemplate?

    var body: some View {
        SettingsForm {
            SettingsSection(
                "Go Templates",
                footer: "Type an abbreviation in a Go file and accept it from the completion list. In a body, $1, ${2:default} and $0 mark tab stops and $TM_SELECTED_TEXT is the selected text, which also makes the template available in Surround With."
            ) {
                ForEach(store.templates) { template in
                    SettingsItemRow(template.abbreviation, subtitle: template.description) {
                        if template.isBuiltIn {
                            SettingsBadge("Built-in")
                        }
                    } accessory: {
                        Toggle("Enabled", isOn: Binding(
                            get: { template.isEnabled },
                            set: { store.setEnabled($0, for: template.id) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Enable \(template.abbreviation)")
                        Menu {
                            Button("Edit…") { begin(template, isNew: false) }
                            Button("Duplicate") { begin(store.duplicate(template), isNew: false) }
                            if !template.isBuiltIn {
                                Divider()
                                Button("Delete…", role: .destructive) { templateToDelete = template }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(template.abbreviation)")
                    }
                }

                SettingsActionRow {
                    Button("Restore Defaults…") { confirmRestore = true }
                        .accessibilityLabel("Restore Default Templates")
                } trailing: {
                    Button("Add…") {
                        begin(LiveTemplate(abbreviation: "", description: "", body: "$0"), isNew: true)
                    }
                    .accessibilityLabel("Add Template")
                }
            }
        }
        .sheet(item: $editing) { target in
            LiveTemplateEditorSheet(template: target.template, isNew: target.isNew) { saved in
                store.save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog("Restore the built-in templates?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { store.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The built-in templates go back to their original text and are enabled again. Your own templates are kept.")
        }
        .confirmationDialog(
            "Delete the template “\(templateToDelete?.abbreviation ?? "")”?",
            isPresented: Binding(get: { templateToDelete != nil }, set: { if !$0 { templateToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Template", role: .destructive) {
                if let template = templateToDelete { store.delete(template.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func begin(_ template: LiveTemplate, isNew: Bool) {
        editing = EditorTarget(template: template, isNew: isNew)
    }

    private struct EditorTarget: Identifiable {
        let template: LiveTemplate
        let isNew: Bool
        var id: UUID { template.id }
    }
}

private struct LiveTemplateEditorSheet: View {
    @State var template: LiveTemplate
    let isNew: Bool
    let onSave: (LiveTemplate) -> Void
    let onCancel: () -> Void

    private var problem: String? {
        LiveTemplateStore.shared.problem(abbreviation: template.abbreviation, excluding: template.id)
            ?? (template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter the text the template inserts." : nil)
    }

    var body: some View {
        StandardSheetShell(
            title: isNew ? "New Template" : "Edit Template",
            subtitle: "Applies to Go files.",
            size: .medium,
            primaryTitle: "Save",
            isPrimaryDisabled: problem != nil,
            closeTitle: "Cancel",
            onPrimary: { onSave(template) },
            onClose: onCancel
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                Form {
                    TextField("Abbreviation:", text: $template.abbreviation, prompt: Text("forr"))
                        .background(PopupFieldAutoFocus())
                    TextField("Description:", text: $template.description, prompt: Text("Range loop over a slice or map"))
                }
                .formStyle(.columns)

                Text("Body")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $template.body)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.standard)
                    .frame(maxWidth: .infinity, minHeight: 132)
                    .wellBackground()
                    .accessibilityLabel("Template Body")

                Text(problem ?? "Use $1, ${2:default} and $0 for tab stops, and $TM_SELECTED_TEXT for the selected text. Curly quotes are saved as straight quotes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
