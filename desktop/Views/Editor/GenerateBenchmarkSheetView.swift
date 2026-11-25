import AppKit
import SwiftUI

struct BenchmarkParamInfoDTO: Codable, Hashable, Identifiable {
    let name: String
    let type: String
    let sampleExpr: String

    var id: String {
        "\(name)-\(type)"
    }
}

struct BenchmarkGenPlanDTO: Codable, Hashable {
    var packageName: String
    var targetFunc: String
    var receiverType: String?
    var benchmarkName: String
    var availableFuncs: [String]
    var params: [BenchmarkParamInfoDTO]
    var reportAllocs: Bool
    var runParallel: Bool
    var tableSubBench: Bool
    var previewCode: String
    var newContent: String
    var targetFile: String
    var isExistingTestFile: Bool
    var error: String?

    static let empty = BenchmarkGenPlanDTO(
        packageName: "",
        targetFunc: "",
        receiverType: nil,
        benchmarkName: "",
        availableFuncs: [],
        params: [],
        reportAllocs: true,
        runParallel: false,
        tableSubBench: false,
        previewCode: "",
        newContent: "",
        targetFile: "",
        isExistingTestFile: false,
        error: nil
    )
}

struct GenerateBenchmarkSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var plan: BenchmarkGenPlanDTO = .empty
    @State private var selectedFunc: String = ""
    @State private var reportAllocs: Bool = true
    @State private var runParallel: Bool = false
    @State private var tableSubBench: Bool = false
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
        BackgroundFFI.isScanning(GeneratorPreviewKey.benchmarkGen)
    }

    private func loadPlan(_ updated: BenchmarkGenPlanDTO?) {
        guard let updated else { return }
        isRefreshing = true
        plan = updated
        if !updated.targetFunc.isEmpty && selectedFunc != updated.targetFunc {
            selectedFunc = updated.targetFunc
        } else if selectedFunc.isEmpty, let first = updated.availableFuncs.first {
            selectedFunc = first
        }
        DispatchQueue.main.async {
            isRefreshing = false
        }
    }

    private func refreshPreview() {
        workspace.inspectBenchmarkGen(
            funcName: selectedFunc,
            reportAllocs: reportAllocs,
            runParallel: runParallel,
            tableSubBench: tableSubBench
        ) { updated in
            loadPlan(updated)
        }
    }

    private func closeSheet() {
        workspace.showGenerateBenchmarkSheet = false
        dismiss()
    }

    private func confirmGenerate() {
        BackgroundFFI.shared.flush(GeneratorPreviewKey.benchmarkGen)
        guard canGenerate else { return }
        workspace.showGenerateBenchmarkSheet = false
        workspace.applyGeneratedBenchmark(plan)
        dismiss()
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Go Benchmark",
            subtitle: "testing.B benchmark harness with allocation metrics (b.ReportAllocs) and parallel execution",
            primaryTitle: "Generate Benchmark",
            canConfirm: canGenerate,
            isUpdating: isUpdatingPreview,
            preview: GeneratorCodePreview(
                code: plan.previewCode,
                placeholder: plan.error ?? "Select a Go function to preview the generated benchmark.",
                accessibilityLabel: "Preview of \(plan.benchmarkName)"
            ),
            onCancel: closeSheet,
            onConfirm: confirmGenerate
        ) {
            controlsSection
            paramsSection
        } accessory: {
            if !plan.targetFunc.isEmpty {
                GeneratorChip("\(plan.targetFunc) · \(plan.params.count) param\(plan.params.count == 1 ? "" : "s")")
            }
        }
        .onAppear {
            if let existing = workspace.activeBenchmarkGenPlan {
                reportAllocs = existing.reportAllocs
                runParallel = existing.runParallel
                tableSubBench = existing.tableSubBench
                loadPlan(existing)
            } else {
                refreshPreview()
            }
        }
        .onChange(of: selectedFunc) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: reportAllocs) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: runParallel) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
        .onChange(of: tableSubBench) { _, _ in
            guard !isRefreshing else { return }
            refreshPreview()
        }
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            GeneratorSection("Target Function") {
                if plan.availableFuncs.isEmpty {
                    GeneratorNote("No functions found in package")
                } else {
                    Picker("Target Function", selection: $selectedFunc) {
                        ForEach(plan.availableFuncs, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Target Function")
                }
            }

            GeneratorSection("Benchmark Options") {
                GeneratorOptionToggle(title: "b.ReportAllocs()", isOn: $reportAllocs)
                GeneratorOptionToggle(title: "b.RunParallel", isOn: $runParallel)
                GeneratorOptionToggle(title: "Table Sub-benchmarks", isOn: $tableSubBench)
            }
        }
    }

    private var paramsSection: some View {
        GeneratorSection("Parameter Samples & Target File") {
            GeneratorChipStrip(isEmpty: !(plan.error ?? "").isEmpty, emptyMessage: plan.error ?? "") {
                if plan.params.isEmpty {
                    GeneratorChip("Zero-argument benchmark call", symbol: "gauge.with.needle")
                } else {
                    ForEach(plan.params) { param in
                        GeneratorChip("\(param.name) (\(param.type)) = \(param.sampleExpr)", symbol: "gauge.with.needle")
                    }
                }
            }
        } trailing: {
            if !plan.benchmarkName.isEmpty {
                GeneratorDetail("func \(plan.benchmarkName)(b *testing.B)")
            }
            if !targetFileBadgeText.isEmpty {
                GeneratorChip("Target File: \(targetFileBadgeText)")
            }
        }
    }
}
