import Foundation
import AppKit
import Observation

enum ActiveModalSheet: String, Hashable, Sendable {
    case benchmarkComparison
    case attachProcess
    case implementInterface
    case moveSymbol
    case structTags
    case pasteJSONStruct
    case structLayout
    case extractMethod
    case generateTest
    case extractType
    case propagateInterface
    case generateInterfaceMock
    case generateEnumMethods
    case generateConstructor
    case generateFuzzTest
    case generateBenchmark
    case localHistory
    case workspaceDiagnostics
    case reportProblem
    case packageDependencies
    case functionComplexity
    case compilerOptimization
    case runConfigurations
    case newProject
    case goToLine
    case addGoModule
    case addFunctionBreakpoint
    case multiBuffer
}

@Observable
final class WorkspaceModalState: @unchecked Sendable {
    var debuggableProcesses: [DebuggableProcess] = []
    var localHistoryTargetPath: String = ""
    var localHistoryEntries: [LocalHistoryEntry] = []
    var activeOOMFailure: OOMFailureInfo? = nil
    var focusMemoryLimitOnOpen: Bool = false
    var newItemRequest: Bool? = nil
    var fileOpenErrors: [String: String] = [:]
    var clipboardHasJSONObject: Bool = false
    @ObservationIgnored var pasteboardChangeCount: Int = -1
    @ObservationIgnored var pasteboardTimer: Timer?
    @ObservationIgnored weak var activeEditorPopover: NSPopover?
    @ObservationIgnored var activeDraggedTabPath: String?
    @ObservationIgnored var activeDraggedNavigatorPath: String?
}

extension WorkspaceState {
    var showBenchmarkComparisonSheet: Bool {
        get { router.isPresenting(.benchmarkComparison) }
        set { router.setPresented(.benchmarkComparison, newValue) }
    }

    var showAttachProcessSheet: Bool {
        get { router.isPresenting(.attachProcess) }
        set { router.setPresented(.attachProcess, newValue) }
    }

    var debuggableProcesses: [DebuggableProcess] {
        get { modals.debuggableProcesses }
        set { modals.debuggableProcesses = newValue }
    }

    var showLocalHistorySheet: Bool {
        get { router.isPresenting(.localHistory) }
        set { router.setPresented(.localHistory, newValue) }
    }

    var localHistoryTargetPath: String {
        get { modals.localHistoryTargetPath }
        set { modals.localHistoryTargetPath = newValue }
    }

    var localHistoryEntries: [LocalHistoryEntry] {
        get { modals.localHistoryEntries }
        set { modals.localHistoryEntries = newValue }
    }

    var showWorkspaceDiagnosticsSheet: Bool {
        get { router.isPresenting(.workspaceDiagnostics) }
        set { router.setPresented(.workspaceDiagnostics, newValue) }
    }

    var showReportProblemSheet: Bool {
        get { router.isPresenting(.reportProblem) }
        set { router.setPresented(.reportProblem, newValue) }
    }

    var showPackageDependenciesSheet: Bool {
        get { router.isPresenting(.packageDependencies) }
        set { router.setPresented(.packageDependencies, newValue) }
    }

    var showFunctionComplexitySheet: Bool {
        get { router.isPresenting(.functionComplexity) }
        set { router.setPresented(.functionComplexity, newValue) }
    }

    var showCompilerOptimizationSheet: Bool {
        get { router.isPresenting(.compilerOptimization) }
        set { router.setPresented(.compilerOptimization, newValue) }
    }

    var showRunConfigurations: Bool {
        get { router.isPresenting(.runConfigurations) }
        set { router.setPresented(.runConfigurations, newValue) }
    }

    var showNewProjectSheet: Bool {
        get { router.isPresenting(.newProject) }
        set { router.setPresented(.newProject, newValue) }
    }

    var showGoToLineSheet: Bool {
        get { router.isPresenting(.goToLine) }
        set { router.setPresented(.goToLine, newValue) }
    }

    var showAddGoModuleSheet: Bool {
        get { router.isPresenting(.addGoModule) }
        set { router.setPresented(.addGoModule, newValue) }
    }

    var showAddFunctionBreakpointSheet: Bool {
        get { router.isPresenting(.addFunctionBreakpoint) }
        set { router.setPresented(.addFunctionBreakpoint, newValue) }
    }

    var activeDockerfileModel: GenerateDockerfileModel? {
        get {
            if case .generateDockerfile(let model) = router.activeSheet {
                return model
            }
            return nil
        }
        set { router.setDockerfileModel(newValue) }
    }

    var activeFileHistoryModel: FileHistoryModel? {
        get {
            if case .fileHistory(let model) = router.activeSheet {
                return model
            }
            return nil
        }
        set { router.setFileHistoryModel(newValue) }
    }

    func presentAddGoModuleSheet() {
        guard !activeWorkspacePath.isEmpty else { return }
        showAddGoModuleSheet = true
    }

    var activeOOMFailure: OOMFailureInfo? {
        get { modals.activeOOMFailure }
        set { modals.activeOOMFailure = newValue }
    }

    var focusMemoryLimitOnOpen: Bool {
        get { modals.focusMemoryLimitOnOpen }
        set { modals.focusMemoryLimitOnOpen = newValue }
    }

    var newItemRequest: Bool? {
        get { modals.newItemRequest }
        set { modals.newItemRequest = newValue }
    }

    var fileOpenErrors: [String: String] {
        get { modals.fileOpenErrors }
        set { modals.fileOpenErrors = newValue }
    }

    var clipboardHasJSONObject: Bool {
        get { modals.clipboardHasJSONObject }
        set { modals.clipboardHasJSONObject = newValue }
    }

    var pasteboardChangeCount: Int {
        get { modals.pasteboardChangeCount }
        set { modals.pasteboardChangeCount = newValue }
    }

    var pasteboardTimer: Timer? {
        get { modals.pasteboardTimer }
        set { modals.pasteboardTimer = newValue }
    }

    var activeEditorPopover: NSPopover? {
        get { modals.activeEditorPopover }
        set { modals.activeEditorPopover = newValue }
    }

    var activeDraggedTabPath: String? {
        get { modals.activeDraggedTabPath }
        set { modals.activeDraggedTabPath = newValue }
    }

    var activeDraggedNavigatorPath: String? {
        get { modals.activeDraggedNavigatorPath }
        set { modals.activeDraggedNavigatorPath = newValue }
    }

    func presentCompilerOptimizationSheet() {
        guard !activeFilePath.isEmpty else { return }
        showCompilerOptimizationSheet = true
    }

    func increaseMemoryLimitRecovery() {
        focusMemoryLimitOnOpen = true
        showRunConfigurations = true
    }

    func profileHeapRecovery() {
        activeOOMFailure = nil
        runFailure = nil
        selectedConsoleTab = Self.profilerTab
        showConsole = true
        profileProject()
    }

    func dismissOOMBanner() {
        activeOOMFailure = nil
        if case .oomKilled = runFailure?.kind {
            runFailure = nil
        }
    }
}
