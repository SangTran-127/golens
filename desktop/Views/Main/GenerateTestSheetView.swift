import AppKit
import SwiftUI

struct GenerateTestPreviewDTO: Codable, Hashable {
    var targetFuncName: String?
    var receiverType: String?
    var testFuncName: String?
    var testFilePath: String?
    var previewCode: String?
    var applied: Bool?
    var error: String?

    init(
        targetFuncName: String? = nil,
        receiverType: String? = nil,
        testFuncName: String? = nil,
        testFilePath: String? = nil,
        previewCode: String? = nil,
        applied: Bool? = nil,
        error: String? = nil
    ) {
        self.targetFuncName = targetFuncName
        self.receiverType = receiverType
        self.testFuncName = testFuncName
        self.testFilePath = testFilePath
        self.previewCode = previewCode
        self.applied = applied
        self.error = error
    }
}

struct GenerateTestSheetView: View {
    let preview: GenerateTestPreviewDTO
    let onRefreshPreview: (String, Bool) -> GenerateTestPreviewDTO?
    let onGenerate: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var testFuncName: String
    @State private var includeParallel: Bool = false
    @State private var currentPreviewCode: String

    init(
        preview: GenerateTestPreviewDTO,
        onRefreshPreview: @escaping (String, Bool) -> GenerateTestPreviewDTO?,
        onGenerate: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preview = preview
        self.onRefreshPreview = onRefreshPreview
        self.onGenerate = onGenerate
        self.onCancel = onCancel
        _testFuncName = State(initialValue: preview.testFuncName ?? "TestFunc")
        _currentPreviewCode = State(initialValue: preview.previewCode ?? "")
    }

    private var targetBadgeText: String {
        let fn = preview.targetFuncName ?? ""
        if let recv = preview.receiverType, !recv.isEmpty {
            return "(\(recv)) \(fn)"
        }
        return fn
    }

    private var destinationFileName: String {
        let raw = preview.testFilePath ?? ""
        if raw.isEmpty {
            return ""
        }
        return URL(fileURLWithPath: raw).lastPathComponent
    }

    private func refreshLivePreview() {
        if let updated = onRefreshPreview(testFuncName, includeParallel),
           let code = updated.previewCode, !code.isEmpty {
            currentPreviewCode = code
        }
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Table-Driven Test",
            subtitle: "Generate an idiomatic Go table-driven test function with subtests and starter cases.",
            primaryTitle: "Generate Test",
            primaryAccessibilityLabel: "Confirm Generate Table-Driven Test",
            cancelAccessibilityLabel: "Cancel Generate Table-Driven Test",
            canConfirm: !testFuncName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            preview: GeneratorCodePreview(code: currentPreviewCode, accessibilityLabel: "Preview of \(testFuncName)"),
            onCancel: onCancel,
            onConfirm: { onGenerate(testFuncName, includeParallel) }
        ) {
            GeneratorSection("Test Function Name") {
                TextField("Test Function Name", text: $testFuncName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .background(PopupFieldAutoFocus())
                    .accessibilityLabel("Test Function Name")

                GeneratorOptionToggle(title: "Include t.Parallel()", isOn: $includeParallel)
            }
            .onChange(of: testFuncName) { _, _ in
                refreshLivePreview()
            }
            .onChange(of: includeParallel) { _, _ in
                refreshLivePreview()
            }
        } accessory: {
            if !targetBadgeText.isEmpty {
                GeneratorChip(targetBadgeText)
            }
            if !destinationFileName.isEmpty {
                GeneratorChip(destinationFileName, symbol: "doc.text")
            }
        }
    }
}
