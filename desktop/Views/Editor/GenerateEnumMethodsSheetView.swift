import AppKit
import SwiftUI

struct EnumConstItemDTO: Codable, Hashable, Identifiable {
    let name: String
    let label: String

    var id: String {
        "\(name)-\(label)"
    }
}

struct EnumMethodsPlanDTO: Codable, Hashable {
    var packageName: String
    var targetEnum: String
    var underlyingType: String
    var availableEnums: [String]
    var constants: [EnumConstItemDTO]
    var trimPrefix: Bool
    var includeParse: Bool
    var includeIsValid: Bool
    var includeValues: Bool
    var previewCode: String
    var newContent: String
    var targetFile: String
    var error: String?

    static let empty = EnumMethodsPlanDTO(
        packageName: "",
        targetEnum: "",
        underlyingType: "",
        availableEnums: [],
        constants: [],
        trimPrefix: true,
        includeParse: true,
        includeIsValid: true,
        includeValues: true,
        previewCode: "",
        newContent: "",
        targetFile: "",
        error: nil
    )
}

struct GenerateEnumMethodsSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var plan: EnumMethodsPlanDTO = .empty
    @State private var selectedEnum: String = ""
    @State private var trimPrefix: Bool = true
    @State private var includeParse: Bool = true
    @State private var includeIsValid: Bool = true
    @State private var includeValues: Bool = true
    @State private var isRefreshing: Bool = false

    private var canGenerate: Bool {
        !plan.targetEnum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.previewCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isUpdatingPreview: Bool {
        BackgroundFFI.isScanning(GeneratorPreviewKey.enumMethods)
    }

    private func loadPlan(_ updated: EnumMethodsPlanDTO?) {
        guard let updated else { return }
        isRefreshing = true
        plan = updated
        if !updated.targetEnum.isEmpty && selectedEnum != updated.targetEnum {
            selectedEnum = updated.targetEnum
        } else if selectedEnum.isEmpty, let first = updated.availableEnums.first {
            selectedEnum = first
        }
        DispatchQueue.main.async {
            isRefreshing = false
        }
    }

    private func refreshPreview() {
        workspace.inspectEnumMethods(
            typeName: selectedEnum,
            trimPrefix: trimPrefix,
            includeParse: includeParse,
            includeIsValid: includeIsValid,
            includeValues: includeValues
        ) { updated in
            loadPlan(updated)
        }
    }

    private func closeSheet() {
        workspace.showGenerateEnumMethodsSheet = false
        dismiss()
    }

    private func confirmGenerate() {
        BackgroundFFI.shared.flush(GeneratorPreviewKey.enumMethods)
        guard canGenerate else { return }
        let targetPath = plan.targetFile.isEmpty ? workspace.activeFilePath : plan.targetFile
        workspace.showGenerateEnumMethodsSheet = false
        workspace.applyInPlaceEdit(
            newText: plan.newContent,
            actionName: "Generate Enum Methods",
            targetPath: targetPath
        )
        let fileName = (targetPath as NSString).lastPathComponent
        workspace.appendLog("Generated enum methods for \(plan.targetEnum) in \(fileName)")
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Enum / Stringer Methods",
            subtitle: "Zero-dependency String(), Parse<Enum>(s), IsValid(), and All<Enum>Values() methods",
            primaryTitle: "Generate Enum Methods",
            canConfirm: canGenerate,
            isUpdating: isUpdatingPreview,
            preview: GeneratorCodePreview(
                code: plan.previewCode,
                placeholder: plan.error ?? "Select a Go const/iota enum in the current file to preview its String(), Parse, IsValid() and All Values methods.",
                accessibilityLabel: "Preview of generated enum methods for \(plan.targetEnum)"
            ),
            onCancel: closeSheet,
            onConfirm: confirmGenerate
        ) {
            controlsSection
            mappedConstantsSection
        } accessory: {
            if !plan.targetEnum.isEmpty {
                let count = plan.constants.count
                GeneratorChip("\(plan.targetEnum) (\(plan.underlyingType)) · \(count) value\(count == 1 ? "" : "s")")
            }
        }
        .onAppear {
            if let existing = workspace.activeEnumMethodsPlan {
                trimPrefix = existing.trimPrefix
                includeParse = existing.includeParse
                includeIsValid = existing.includeIsValid
                includeValues = existing.includeValues
                loadPlan(existing)
            } else {
                refreshPreview()
            }
        }
        .onChange(of: selectedEnum) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: trimPrefix) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: includeParse) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: includeIsValid) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: includeValues) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
    }

    private var controlsSection: some View {
        let enumLabel = plan.targetEnum.isEmpty ? "Enum" : plan.targetEnum
        return HStack(alignment: .top, spacing: Spacing.section) {
            GeneratorSection("Enum Type") {
                if plan.availableEnums.isEmpty {
                    GeneratorNote("No enums found")
                } else {
                    Picker("Enum Type", selection: $selectedEnum) {
                        ForEach(plan.availableEnums, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Target Enum Type")
                }
            }

            GeneratorSection("Options & Generated Helpers") {
                GeneratorOptionToggle(title: "Trim Prefix", isOn: $trimPrefix, accessibilityLabel: "Trim Type Prefix")
                GeneratorOptionToggle(title: "Parse\(enumLabel)(s)", isOn: $includeParse, accessibilityLabel: "Generate Parse Function")
                GeneratorOptionToggle(title: "IsValid()", isOn: $includeIsValid, accessibilityLabel: "Generate IsValid Method")
                GeneratorOptionToggle(title: "All\(enumLabel)Values()", isOn: $includeValues, accessibilityLabel: "Generate AllValues Function")
            }
        }
    }

    private var mappedConstantsSection: some View {
        GeneratorSection("Mapped Enum Constants & String Labels") {
            GeneratorChipStrip(isEmpty: plan.constants.isEmpty, emptyMessage: plan.error ?? "No enum constants found in package") {
                ForEach(plan.constants) { item in
                    GeneratorChip("\(item.name) → \"\(item.label)\"", symbol: "tag")
                }
            }
        } trailing: {
            if !plan.targetEnum.isEmpty {
                GeneratorDetail("func (e \(plan.targetEnum)) String() string")
            }
        }
    }
}
