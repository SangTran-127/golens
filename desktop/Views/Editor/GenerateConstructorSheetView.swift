import AppKit
import SwiftUI

struct ConstructorFieldItemDTO: Codable, Hashable, Identifiable {
    let fieldName: String
    let paramName: String
    let fieldType: String
    let optionFuncName: String
    let isMap: Bool?

    var id: String {
        "\(fieldName)-\(paramName)-\(optionFuncName)"
    }
}

struct ConstructorPlanDTO: Codable, Hashable {
    var packageName: String
    var targetStruct: String
    var availableStructs: [String]
    var constructorName: String
    var includeOptions: Bool
    var returnPointer: Bool
    var fields: [ConstructorFieldItemDTO]
    var previewCode: String
    var newContent: String
    var targetFile: String
    var error: String?

    static let empty = ConstructorPlanDTO(
        packageName: "",
        targetStruct: "",
        availableStructs: [],
        constructorName: "",
        includeOptions: true,
        returnPointer: true,
        fields: [],
        previewCode: "",
        newContent: "",
        targetFile: "",
        error: nil
    )
}

struct GenerateConstructorSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var plan: ConstructorPlanDTO = .empty
    @State private var selectedStruct: String = ""
    @State private var includeOptions: Bool = true
    @State private var returnPointer: Bool = true
    @State private var isRefreshing: Bool = false

    private var canGenerate: Bool {
        !plan.targetStruct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.previewCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (plan.error ?? "").isEmpty
    }

    private var isUpdatingPreview: Bool {
        BackgroundFFI.isScanning(GeneratorPreviewKey.constructor)
    }

    private func loadPlan(_ updated: ConstructorPlanDTO?) {
        guard let updated else { return }
        isRefreshing = true
        plan = updated
        if !updated.targetStruct.isEmpty && selectedStruct != updated.targetStruct {
            selectedStruct = updated.targetStruct
        } else if selectedStruct.isEmpty, let first = updated.availableStructs.first {
            selectedStruct = first
        }
        DispatchQueue.main.async {
            isRefreshing = false
        }
    }

    private func refreshPreview() {
        workspace.inspectStructConstructor(
            structName: selectedStruct,
            includeOptions: includeOptions,
            returnPointer: returnPointer
        ) { updated in
            loadPlan(updated)
        }
    }

    private func closeSheet() {
        workspace.showGenerateConstructorSheet = false
        dismiss()
    }

    private func confirmGenerate() {
        BackgroundFFI.shared.flush(GeneratorPreviewKey.constructor)
        guard canGenerate else { return }
        let targetPath = plan.targetFile.isEmpty ? workspace.activeFilePath : plan.targetFile
        workspace.showGenerateConstructorSheet = false
        workspace.applyInPlaceEdit(
            newText: plan.newContent,
            actionName: "Generate Constructor",
            targetPath: targetPath
        )
        let fileName = (targetPath as NSString).lastPathComponent
        workspace.appendLog("Generated \(plan.constructorName) for \(plan.targetStruct) in \(fileName)")
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Constructor & Options",
            subtitle: "Idiomatic Go constructor with optional functional options (WithField…)",
            primaryTitle: "Generate Constructor",
            canConfirm: canGenerate,
            isUpdating: isUpdatingPreview,
            preview: GeneratorCodePreview(
                code: plan.previewCode,
                placeholder: plan.error ?? "Select a Go struct in the current file to preview its constructor and functional options.",
                accessibilityLabel: "Preview of \(plan.constructorName)"
            ),
            onCancel: closeSheet,
            onConfirm: confirmGenerate
        ) {
            controlsSection
            mappedFieldsSection
        } accessory: {
            if !plan.targetStruct.isEmpty {
                GeneratorChip("\(plan.targetStruct) · \(plan.fields.count) field\(plan.fields.count == 1 ? "" : "s")")
            }
        }
        .onAppear {
            if let existing = workspace.activeConstructorPlan {
                includeOptions = existing.includeOptions
                returnPointer = existing.returnPointer
                loadPlan(existing)
            } else {
                refreshPreview()
            }
        }
        .onChange(of: selectedStruct) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: includeOptions) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: returnPointer) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            GeneratorSection("Struct") {
                if plan.availableStructs.isEmpty {
                    GeneratorNote("No structs found in package")
                } else {
                    Picker("Struct", selection: $selectedStruct) {
                        ForEach(plan.availableStructs, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Target Struct")
                }
            }

            GeneratorSection("Pattern") {
                GeneratorOptionToggle(title: "Generate Functional Options (WithField…)", isOn: $includeOptions)
            }

            GeneratorSection("Return Type") {
                GeneratorOptionToggle(title: "Return Pointer (*Struct)", isOn: $returnPointer)
            }
        }
    }

    private var signatureText: String {
        guard !plan.constructorName.isEmpty else { return "" }
        let retType = returnPointer ? "*\(plan.targetStruct)" : plan.targetStruct
        return includeOptions
            ? "func \(plan.constructorName)(opts ...\(plan.targetStruct)Option) \(retType)"
            : "func \(plan.constructorName)(…) \(retType)"
    }

    private var mappedFieldsSection: some View {
        GeneratorSection(includeOptions ? "Functional Option Helpers" : "Constructor Parameters") {
            GeneratorChipStrip(isEmpty: plan.fields.isEmpty, emptyMessage: plan.error ?? "No struct fields found") {
                ForEach(plan.fields) { field in
                    GeneratorChip(fieldLabel(for: field), symbol: includeOptions ? "slider.horizontal.3" : "hammer")
                }
            }
        } trailing: {
            if !signatureText.isEmpty {
                GeneratorDetail(signatureText)
            }
        }
    }

    private func fieldLabel(for field: ConstructorFieldItemDTO) -> String {
        includeOptions
            ? "\(field.optionFuncName)(\(field.paramName) \(field.fieldType))"
            : "\(field.paramName) \(field.fieldType) → \(field.fieldName)"
    }
}
