import AppKit
import SwiftUI

struct InterfaceMockResultDTO: Codable, Hashable {
    var packageName: String?
    var interfaceName: String?
    var mockName: String?
    var availableInterfaces: [String]?
    var methodCount: Int?
    var generatedCode: String?
    var standaloneFileCode: String?
    var suggestedFileName: String?
    var error: String?
}

enum InterfaceMockDestination: String, CaseIterable, Identifiable {
    case currentFile = "currentFile"
    case newTestFile = "newTestFile"

    var id: String { rawValue }
}

struct GenerateInterfaceMockSheetView: View {
    @Environment(\.windowWorkspace) private var workspace

    @State private var availableInterfaces: [String] = []
    @State private var selectedInterface: String = ""
    @State private var mockName: String = ""
    @State private var destination: InterfaceMockDestination = .currentFile
    @State private var methodCount: Int = 0
    @State private var generatedCode: String = ""
    @State private var standaloneFileCode: String = ""
    @State private var suggestedFileName: String = "mock_test.go"
    @State private var errorMessage: String = ""
    @State private var suppressAutoMockRename: Bool = false

    private var displayedPreviewCode: String {
        switch destination {
        case .currentFile:
            return generatedCode
        case .newTestFile:
            return standaloneFileCode.isEmpty ? generatedCode : standaloneFileCode
        }
    }

    private var canGenerate: Bool {
        !selectedInterface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !mockName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !generatedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isUpdatingPreview: Bool {
        BackgroundFFI.isScanning(GeneratorPreviewKey.interfaceMock)
    }

    private func loadFromResult(_ result: InterfaceMockResultDTO?) {
        guard let result else { return }
        if let err = result.error, !err.isEmpty {
            errorMessage = err
        } else {
            errorMessage = ""
        }
        let list = result.availableInterfaces ?? []
        if !list.isEmpty {
            availableInterfaces = list
        }
        if let iface = result.interfaceName, !iface.isEmpty {
            if selectedInterface != iface {
                selectedInterface = iface
            }
        } else if selectedInterface.isEmpty, let first = availableInterfaces.first {
            selectedInterface = first
        }
        if let mName = result.mockName, !mName.isEmpty, mockName != mName {
            suppressAutoMockRename = true
            mockName = mName
            suppressAutoMockRename = false
        }
        methodCount = result.methodCount ?? 0
        generatedCode = result.generatedCode ?? ""
        standaloneFileCode = result.standaloneFileCode ?? ""
        if let suggested = result.suggestedFileName, !suggested.isEmpty {
            suggestedFileName = suggested
        } else if !selectedInterface.isEmpty {
            suggestedFileName = "mock_\(selectedInterface.lowercased())_test.go"
        }
    }

    private func refreshPreview(interfaceName: String, customMockName: String) {
        workspace.refreshInterfaceMockPreview(
            interfaceName: interfaceName,
            mockName: customMockName
        ) { updated in
            loadFromResult(updated)
        }
    }

    private func closeSheet() {
        workspace.showGenerateInterfaceMockSheet = false
    }

    private func confirmGenerate() {
        BackgroundFFI.shared.flush(GeneratorPreviewKey.interfaceMock)
        guard canGenerate else { return }
        workspace.applyGenerateInterfaceMock(
            interfaceName: selectedInterface,
            mockName: mockName,
            createNewTestFile: destination == .newTestFile
        )
    }

    var body: some View {
        GeneratorSheet(
            title: "Generate Interface Mock",
            subtitle: "Zero-dependency concurrency-safe Go test double",
            primaryTitle: "Generate Mock",
            canConfirm: canGenerate,
            isUpdating: isUpdatingPreview,
            preview: GeneratorCodePreview(
                code: displayedPreviewCode,
                placeholder: errorMessage.isEmpty ? "No interfaces found in the current Go package." : errorMessage,
                accessibilityLabel: "Preview of \(mockName) for \(selectedInterface)"
            ),
            previewDetail: mockName.isEmpty ? "" : "type \(mockName) struct",
            onCancel: closeSheet,
            onConfirm: confirmGenerate
        ) {
            targetSection
            destinationSection
        } accessory: {
            if !selectedInterface.isEmpty {
                GeneratorChip("\(selectedInterface) · \(methodCount) method\(methodCount == 1 ? "" : "s")")
            }
        }
        .onAppear {
            if let existing = workspace.activeInterfaceMockPreview {
                loadFromResult(existing)
            } else {
                workspace.refreshInterfaceMockPreview(interfaceName: "", mockName: "") { initial in
                    loadFromResult(initial)
                }
            }
        }
    }

    private var targetSection: some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            GeneratorSection("Interface") {
                if availableInterfaces.isEmpty {
                    GeneratorNote("No interfaces found in package")
                } else {
                    Picker("Interface", selection: $selectedInterface) {
                        ForEach(availableInterfaces, id: \.self) { iface in
                            Text(iface).tag(iface)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Target Interface")
                }
            }

            GeneratorSection("Mock Struct Name") {
                TextField("Mock Struct Name", text: $mockName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel("Mock Struct Name")
                    .onSubmit {
                        confirmGenerate()
                    }
            }
        }
        .onChange(of: selectedInterface) { _, newInterface in
            guard !newInterface.isEmpty else { return }
            let autoMock = "Mock\(newInterface)"
            suppressAutoMockRename = true
            mockName = autoMock
            suppressAutoMockRename = false
            refreshPreview(interfaceName: newInterface, customMockName: autoMock)
        }
        .onChange(of: mockName) { _, newMock in
            guard !suppressAutoMockRename, !selectedInterface.isEmpty else { return }
            refreshPreview(interfaceName: selectedInterface, customMockName: newMock)
        }
    }

    private var destinationSection: some View {
        GeneratorSection("Destination") {
            Picker("Destination", selection: $destination) {
                Text("Current File")
                    .tag(InterfaceMockDestination.currentFile)
                Text("New Test File (\(suggestedFileName))")
                    .tag(InterfaceMockDestination.newTestFile)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Destination")
        }
    }
}
