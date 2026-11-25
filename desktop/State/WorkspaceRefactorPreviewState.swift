import Foundation
import Observation

@Observable
final class WorkspaceRefactorPreviewState: @unchecked Sendable {
    var interfaceCandidates: [InterfaceCandidateItem] = []
    var activeStructNameForInterface: String = ""
    var activeSymbolNameForMove: String = ""
    var activeStructLayoutReport: StructLayoutReportDTO? = nil
    var activeExtractMethodPreview: ExtractMethodPreviewDTO? = nil
    var activeGenerateTestPreview: GenerateTestPreviewDTO? = nil
    var activeExtractTypePreview: ExtractTypeReplyDTO? = nil
    var activePropagateInterfacePreview: ExtractTypeReplyDTO? = nil
    var activeInterfaceMockPreview: InterfaceMockResultDTO? = nil
    var activeEnumMethodsPlan: EnumMethodsPlanDTO? = nil
    var activeConstructorPlan: ConstructorPlanDTO? = nil
    var activeFuzzTestPlan: FuzzTestPlanDTO? = nil
    var activeBenchmarkGenPlan: BenchmarkGenPlanDTO? = nil
}

extension WorkspaceState {
    var pendingChangeSignature: FuncSignatureSpec? {
        get {
            if case .changeSignature(let spec) = router.activeSheet {
                return spec
            }
            return nil
        }
        set { router.setChangeSignature(newValue) }
    }

    var showImplementInterfaceSheet: Bool {
        get { router.isPresenting(.implementInterface) }
        set { router.setPresented(.implementInterface, newValue) }
    }

    var interfaceCandidates: [InterfaceCandidateItem] {
        get { refactorPreviews.interfaceCandidates }
        set { refactorPreviews.interfaceCandidates = newValue }
    }

    var activeStructNameForInterface: String {
        get { refactorPreviews.activeStructNameForInterface }
        set { refactorPreviews.activeStructNameForInterface = newValue }
    }

    var showMoveSymbolSheet: Bool {
        get { router.isPresenting(.moveSymbol) }
        set { router.setPresented(.moveSymbol, newValue) }
    }

    var activeSymbolNameForMove: String {
        get { refactorPreviews.activeSymbolNameForMove }
        set { refactorPreviews.activeSymbolNameForMove = newValue }
    }

    var showStructTagsSheet: Bool {
        get { router.isPresenting(.structTags) }
        set { router.setPresented(.structTags, newValue) }
    }

    var showPasteJSONStructSheet: Bool {
        get { router.isPresenting(.pasteJSONStruct) }
        set { router.setPresented(.pasteJSONStruct, newValue) }
    }

    var showStructLayoutSheet: Bool {
        get { router.isPresenting(.structLayout) }
        set { router.setPresented(.structLayout, newValue) }
    }

    var activeStructLayoutReport: StructLayoutReportDTO? {
        get { refactorPreviews.activeStructLayoutReport }
        set { refactorPreviews.activeStructLayoutReport = newValue }
    }

    var showExtractMethodSheet: Bool {
        get { router.isPresenting(.extractMethod) }
        set { router.setPresented(.extractMethod, newValue) }
    }

    var activeExtractMethodPreview: ExtractMethodPreviewDTO? {
        get { refactorPreviews.activeExtractMethodPreview }
        set { refactorPreviews.activeExtractMethodPreview = newValue }
    }

    var showGenerateTestSheet: Bool {
        get { router.isPresenting(.generateTest) }
        set { router.setPresented(.generateTest, newValue) }
    }

    var activeGenerateTestPreview: GenerateTestPreviewDTO? {
        get { refactorPreviews.activeGenerateTestPreview }
        set { refactorPreviews.activeGenerateTestPreview = newValue }
    }

    var showExtractTypeSheet: Bool {
        get { router.isPresenting(.extractType) }
        set { router.setPresented(.extractType, newValue) }
    }

    var activeExtractTypePreview: ExtractTypeReplyDTO? {
        get { refactorPreviews.activeExtractTypePreview }
        set { refactorPreviews.activeExtractTypePreview = newValue }
    }

    var showPropagateInterfaceSheet: Bool {
        get { router.isPresenting(.propagateInterface) }
        set { router.setPresented(.propagateInterface, newValue) }
    }

    var activePropagateInterfacePreview: ExtractTypeReplyDTO? {
        get { refactorPreviews.activePropagateInterfacePreview }
        set { refactorPreviews.activePropagateInterfacePreview = newValue }
    }

    var showGenerateInterfaceMockSheet: Bool {
        get { router.isPresenting(.generateInterfaceMock) }
        set { router.setPresented(.generateInterfaceMock, newValue) }
    }

    var activeInterfaceMockPreview: InterfaceMockResultDTO? {
        get { refactorPreviews.activeInterfaceMockPreview }
        set { refactorPreviews.activeInterfaceMockPreview = newValue }
    }

    var showGenerateEnumMethodsSheet: Bool {
        get { router.isPresenting(.generateEnumMethods) }
        set { router.setPresented(.generateEnumMethods, newValue) }
    }

    var activeEnumMethodsPlan: EnumMethodsPlanDTO? {
        get { refactorPreviews.activeEnumMethodsPlan }
        set { refactorPreviews.activeEnumMethodsPlan = newValue }
    }

    var showGenerateConstructorSheet: Bool {
        get { router.isPresenting(.generateConstructor) }
        set { router.setPresented(.generateConstructor, newValue) }
    }

    var activeConstructorPlan: ConstructorPlanDTO? {
        get { refactorPreviews.activeConstructorPlan }
        set { refactorPreviews.activeConstructorPlan = newValue }
    }

    var showGenerateFuzzTestSheet: Bool {
        get { router.isPresenting(.generateFuzzTest) }
        set { router.setPresented(.generateFuzzTest, newValue) }
    }

    var activeFuzzTestPlan: FuzzTestPlanDTO? {
        get { refactorPreviews.activeFuzzTestPlan }
        set { refactorPreviews.activeFuzzTestPlan = newValue }
    }

    var showGenerateBenchmarkSheet: Bool {
        get { router.isPresenting(.generateBenchmark) }
        set { router.setPresented(.generateBenchmark, newValue) }
    }

    var activeBenchmarkGenPlan: BenchmarkGenPlanDTO? {
        get { refactorPreviews.activeBenchmarkGenPlan }
        set { refactorPreviews.activeBenchmarkGenPlan = newValue }
    }
}
