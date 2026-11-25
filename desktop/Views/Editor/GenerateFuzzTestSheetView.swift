import AppKit
import SwiftUI

struct FuzzSeedRowDTO: Codable, Hashable, Identifiable {
    let label: String
    let values: [String]

    var id: String {
        "\(label)-\(values.joined(separator: ","))"
    }
}

struct FuzzParamItemDTO: Codable, Hashable, Identifiable {
    let name: String
    let type: String
    let supported: Bool

    var id: String {
        "\(name)-\(type)"
    }
}

struct FuzzTestPlanDTO: Codable, Hashable {
    var packageName: String
    var targetFunc: String
    var receiverType: String?
    var availableFunctions: [String]
    var fuzzFuncName: String
    var params: [FuzzParamItemDTO]
    var seeds: [FuzzSeedRowDTO]
    var includeEdgeSeeds: Bool
    var checkDeterminism: Bool
    var previewCode: String
    var newContent: String
    var targetFile: String
    var error: String?

    static let empty = FuzzTestPlanDTO(
        packageName: "",
        targetFunc: "",
        receiverType: nil,
        availableFunctions: [],
        fuzzFuncName: "",
        params: [],
        seeds: [],
        includeEdgeSeeds: true,
        checkDeterminism: true,
        previewCode: "",
        newContent: "",
        targetFile: "",
        error: nil
    )
}

struct GenerateFuzzTestSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var plan: FuzzTestPlanDTO = .empty
    @State private var selectedFunc: String = ""
    @State private var includeEdgeSeeds: Bool = true
    @State private var checkDeterminism: Bool = true
    @State private var isRefreshing: Bool = false

    private var canGenerate: Bool {
        !plan.targetFunc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.previewCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !plan.newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (plan.error ?? "").isEmpty
    }

    private var targetFileBadgeText: String {
        guard !plan.targetFile.isEmpty else { return "" }
        return (plan.targetFile as NSString).lastPathComponent
    }

    private var isUpdatingPreview: Bool {
        BackgroundFFI.isScanning(GeneratorPreviewKey.fuzzTest)
    }

    private func loadPlan(_ updated: FuzzTestPlanDTO?) {
        guard let updated else { return }
        isRefreshing = true
        plan = updated
        if !updated.targetFunc.isEmpty && selectedFunc != updated.targetFunc {
            selectedFunc = updated.targetFunc
        } else if selectedFunc.isEmpty, let first = updated.availableFunctions.first {
            selectedFunc = first
        }
        DispatchQueue.main.async {
            isRefreshing = false
        }
    }

    private func refreshPreview() {
        workspace.inspectFuzzTest(
            funcName: selectedFunc,
            includeEdgeSeeds: includeEdgeSeeds,
            checkDeterminism: checkDeterminism
        ) { updated in
            loadPlan(updated)
        }
    }

    private func closeSheet() {
        workspace.showGenerateFuzzTestSheet = false
        dismiss()
    }

    private func confirmGenerate() {
        BackgroundFFI.shared.flush(GeneratorPreviewKey.fuzzTest)
        guard canGenerate else { return }
        workspace.showGenerateFuzzTestSheet = false
        workspace.applyGeneratedFuzzTest(plan)
        dismiss()
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Fuzz Test",
            subtitle: "Go 1.18+ testing.F harness with automated seed corpus (f.Add) and invariant checks",
            primaryTitle: "Generate Fuzz Test",
            canConfirm: canGenerate,
            isUpdating: isUpdatingPreview,
            preview: GeneratorCodePreview(
                code: plan.previewCode,
                placeholder: plan.error ?? "Select a Go function with fuzz-compatible parameters to preview its FuzzXxx(f *testing.F) harness.",
                accessibilityLabel: "Preview of \(plan.fuzzFuncName)"
            ),
            onCancel: closeSheet,
            onConfirm: confirmGenerate
        ) {
            controlsSection
            seedCorpusSection
        } accessory: {
            if !plan.targetFunc.isEmpty {
                GeneratorChip("\(plan.targetFunc) · \(plan.seeds.count) seed\(plan.seeds.count == 1 ? "" : "s")")
            }
        }
        .onAppear {
            if let existing = workspace.activeFuzzTestPlan {
                includeEdgeSeeds = existing.includeEdgeSeeds
                checkDeterminism = existing.checkDeterminism
                loadPlan(existing)
            } else {
                refreshPreview()
            }
        }
        .onChange(of: selectedFunc) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: includeEdgeSeeds) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: checkDeterminism) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            GeneratorSection("Target Function") {
                if plan.availableFunctions.isEmpty {
                    GeneratorNote("No functions found in package")
                } else {
                    Picker("Target Function", selection: $selectedFunc) {
                        ForEach(plan.availableFunctions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Target Function")
                }
            }

            GeneratorSection("Seed Corpus") {
                GeneratorOptionToggle(title: "Include Edge-Case Seeds", isOn: $includeEdgeSeeds)
            }

            GeneratorSection("Invariant") {
                GeneratorOptionToggle(title: "Check Deterministic Output", isOn: $checkDeterminism)
            }
        }
    }

    private var seedCorpusSection: some View {
        GeneratorSection("Seed Corpus & Fuzz Parameters") {
            GeneratorChipStrip(isEmpty: plan.seeds.isEmpty, emptyMessage: plan.error ?? "No fuzz seed corpus generated") {
                ForEach(plan.seeds) { row in
                    GeneratorChip(seedLabel(for: row), symbol: "sparkles")
                }
            }
        } trailing: {
            if !plan.fuzzFuncName.isEmpty {
                GeneratorDetail("func \(plan.fuzzFuncName)(f *testing.F)")
            }
            if !targetFileBadgeText.isEmpty {
                GeneratorChip(targetFileBadgeText)
            }
        }
    }

    private func seedLabel(for row: FuzzSeedRowDTO) -> String {
        let argsText = row.values.joined(separator: ", ")
        return "\(row.label): f.Add(\(argsText))"
    }
}
