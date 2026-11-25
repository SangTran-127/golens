import Foundation
import GoLensFoundation
import Observation
import SwiftUI

enum PresentedWorkspaceSheet: Identifiable {
    case modal(ActiveModalSheet)
    case interactiveForm(InteractiveForm)
    case changeSignature(FuncSignatureSpec)
    case generateDockerfile(GenerateDockerfileModel)
    case fileHistory(FileHistoryModel)
    case sourceControl(SourceControlSheet)
    case dataSources(DataSourcesSheetRequest)
    case submitChanges(DBSubmitPreview)
    case queryParameters(DBParameterPrompt)
    case exportResult(DBExportSheetRequest)
    case detectDataSources(DBDetectSheetRequest)
    case dockerCleanUp(DockerCleanUpRequest)
    case kubernetesApply(KubeApplyRequest)

    var id: String {
        switch self {
        case .modal(let sheet):
            return "modal.\(sheet.rawValue)"
        case .interactiveForm(let form):
            return "interactiveForm.\(form.id.uuidString)"
        case .changeSignature(let spec):
            return "changeSignature.\(spec.id)"
        case .generateDockerfile(let model):
            return "generateDockerfile.\(model.id.uuidString)"
        case .fileHistory(let model):
            return "fileHistory.\(model.id.uuidString)"
        case .sourceControl(let sheet):
            return "sourceControl.\(sheet.id)"
        case .dataSources(let request):
            return "dataSources.\(request.id.uuidString)"
        case .submitChanges(let preview):
            return "submitChanges.\(preview.id.uuidString)"
        case .queryParameters(let prompt):
            return "queryParameters.\(prompt.id.uuidString)"
        case .exportResult(let request):
            return "exportResult.\(request.id.uuidString)"
        case .detectDataSources(let request):
            return "detectDataSources.\(request.id.uuidString)"
        case .dockerCleanUp(let request):
            return "dockerCleanUp.\(request.id.uuidString)"
        case .kubernetesApply(let request):
            return "kubernetesApply.\(request.id.uuidString)"
        }
    }

    var kind: WorkspaceSheetKind {
        switch self {
        case .modal(let sheet):
            return WorkspaceSheetKind(rawValue: sheet.rawValue) ?? .goToLine
        case .interactiveForm:
            return .interactiveForm
        case .changeSignature:
            return .changeSignature
        case .generateDockerfile:
            return .generateDockerfile
        case .fileHistory:
            return .fileHistory
        case .sourceControl:
            return .sourceControl
        case .dataSources, .submitChanges, .queryParameters, .exportResult, .detectDataSources:
            return .dataSources
        case .dockerCleanUp:
            return .dockerCleanUp
        case .kubernetesApply:
            return .kubernetesApply
        }
    }
}

struct DataSourcesSheetRequest: Hashable {
    let id = UUID()
    let selectedDataSourceID: String?
}

@Observable
final class WindowPresentationRouter: @unchecked Sendable {
    var activeSheet: PresentedWorkspaceSheet? = nil {
        didSet {
            onActiveSheetChanged?(activeSheet)
        }
    }

    @ObservationIgnored
    var onActiveSheetChanged: ((PresentedWorkspaceSheet?) -> Void)?

    var activeSheetKind: WorkspaceSheetKind? {
        activeSheet?.kind
    }

    func isPresenting(_ sheet: ActiveModalSheet) -> Bool {
        if case .modal(let current) = activeSheet {
            return current == sheet
        }
        return false
    }

    func setPresented(_ sheet: ActiveModalSheet, _ presented: Bool) {
        if presented {
            activeSheet = .modal(sheet)
        } else if case .modal(let current) = activeSheet, current == sheet {
            activeSheet = nil
        }
    }

    func setInteractiveForm(_ form: InteractiveForm?) {
        if let form {
            activeSheet = .interactiveForm(form)
        } else if case .interactiveForm = activeSheet {
            activeSheet = nil
        }
    }

    func setChangeSignature(_ spec: FuncSignatureSpec?) {
        if let spec {
            activeSheet = .changeSignature(spec)
        } else if case .changeSignature = activeSheet {
            activeSheet = nil
        }
    }

    func setDockerfileModel(_ model: GenerateDockerfileModel?) {
        if let model {
            activeSheet = .generateDockerfile(model)
        } else if case .generateDockerfile = activeSheet {
            activeSheet = nil
        }
    }

    func setFileHistoryModel(_ model: FileHistoryModel?) {
        if let model {
            activeSheet = .fileHistory(model)
        } else if case .fileHistory = activeSheet {
            activeSheet = nil
        }
    }

    func setSourceControlSheet(_ sheet: SourceControlSheet?) {
        if let sheet {
            activeSheet = .sourceControl(sheet)
        } else if case .sourceControl = activeSheet {
            activeSheet = nil
        }
    }

    func dismissActiveSheet() {
        activeSheet = nil
    }
}

struct WindowPresentationRouterModifier: ViewModifier {
    @Bindable var workspace: WorkspaceState

    func body(content: Content) -> some View {
        @Bindable var router = workspace.router
        content
            .sheet(item: $router.activeSheet) { presented in
                sheetDestination(for: presented)
            }
    }

    @ViewBuilder
    private func sheetDestination(for presented: PresentedWorkspaceSheet) -> some View {
        switch presented {
        case .modal(let modal):
            modalDestination(for: modal)
        case .interactiveForm(let form):
            InteractiveFormSheet(form: form)
        case .changeSignature(let spec):
            ChangeSignatureSheetView(
                spec: spec,
                onApply: { updated in
                    workspace.pendingChangeSignature = nil
                    workspace.performChangeSignature(updated)
                },
                onCancel: {
                    workspace.pendingChangeSignature = nil
                }
            )
        case .generateDockerfile(let model):
            GenerateDockerfileSheet(model: model) {
                workspace.activeDockerfileModel = nil
            }
        case .fileHistory(let model):
            FileHistorySheetView(model: model) {
                workspace.activeFileHistoryModel = nil
            }
        case .sourceControl(let sheet):
            SourceControlSheetView(sheet: sheet)
        case .dataSources(let request):
            DataSourcesSheet(workspace: workspace, initialSelection: request.selectedDataSourceID)
        case .submitChanges(let preview):
            SubmitChangesSheet(workspace: workspace, preview: preview)
        case .queryParameters(let prompt):
            QueryParametersSheet(workspace: workspace, prompt: prompt)
        case .exportResult(let request):
            ExportResultSheet(workspace: workspace, request: request)
        case .detectDataSources(let request):
            DetectDataSourcesSheet(workspace: workspace, request: request)
        case .dockerCleanUp(let request):
            DockerCleanUpSheet(workspace: workspace, request: request)
        case .kubernetesApply(let request):
            KubernetesApplySheet(workspace: workspace, request: request)
        }
    }

    @ViewBuilder
    private func modalDestination(for modal: ActiveModalSheet) -> some View {
        switch modal {
        case .goToLine:
            GoToLineSheetView()
        case .runConfigurations:
            RunConfigurationsModal(workspace: workspace)
        case .localHistory:
            LocalHistorySheetView()
        case .newProject:
            NewProjectSheetView()
        case .attachProcess:
            AttachProcessSheetView(
                processes: workspace.debuggableProcesses,
                onRefresh: {
                    workspace.refreshDebuggableProcesses()
                },
                onAttachPID: { pid in
                    workspace.attachToProcess(pid: pid)
                },
                onAttachRemote: { addr in
                    workspace.attachToRemoteDelve(address: addr)
                },
                onCancel: {
                    workspace.showAttachProcessSheet = false
                }
            )
        case .implementInterface:
            ImplementInterfaceSheetView(
                structName: workspace.activeStructNameForInterface,
                candidates: workspace.interfaceCandidates,
                onImplement: { ifaceName in
                    workspace.performImplementInterface(ifaceName)
                },
                onCancel: {
                    workspace.showImplementInterfaceSheet = false
                }
            )
        case .moveSymbol:
            MoveSymbolSheetView(
                symbolName: workspace.activeSymbolNameForMove,
                currentFile: workspace.activeFilePath,
                siblingFiles: workspace.siblingGoFilesForCurrentTab(),
                onMove: { targetFile in
                    workspace.performMoveSymbol(to: targetFile)
                },
                onCancel: {
                    workspace.showMoveSymbolSheet = false
                }
            )
        case .structTags:
            StructTagsSheetView()
        case .pasteJSONStruct:
            PasteJSONAsStructSheetView()
        case .structLayout:
            if let report = workspace.activeStructLayoutReport {
                StructLayoutSheetView(
                    report: report,
                    onOptimize: {
                        workspace.optimizeCurrentStructLayout()
                    },
                    onCancel: {
                        workspace.showStructLayoutSheet = false
                    }
                )
            }
        case .extractMethod:
            if let preview = workspace.activeExtractMethodPreview {
                ExtractMethodSheetView(
                    preview: preview,
                    onApply: { funcName in
                        workspace.applyExtractMethod(funcName: funcName)
                    },
                    onCancel: {
                        workspace.showExtractMethodSheet = false
                    }
                )
            }
        case .generateTest:
            if let preview = workspace.activeGenerateTestPreview {
                GenerateTestSheetView(
                    preview: preview,
                    onRefreshPreview: { testFuncName, includeParallel in
                        workspace.refreshTableDrivenTestPreview(testFuncName: testFuncName, includeParallel: includeParallel)
                    },
                    onGenerate: { testFuncName, includeParallel in
                        workspace.applyGenerateTableDrivenTest(testFuncName: testFuncName, includeParallel: includeParallel)
                    },
                    onCancel: {
                        workspace.showGenerateTestSheet = false
                    }
                )
            }
        case .extractType:
            if let preview = workspace.activeExtractTypePreview {
                ExtractTypeSheetView(
                    initialPreview: preview,
                    onRefresh: { newTypeName in
                        workspace.refreshExtractTypePreview(newTypeName: newTypeName)
                    },
                    onApply: { newTypeName in
                        workspace.applyExtractType(newTypeName: newTypeName)
                    },
                    onCancel: {
                        workspace.showExtractTypeSheet = false
                    }
                )
            }
        case .propagateInterface:
            if let preview = workspace.activePropagateInterfacePreview {
                PropagateInterfaceSheetView(
                    preview: preview,
                    onApply: {
                        workspace.applyPropagateInterfaceMethods()
                    },
                    onCancel: {
                        workspace.showPropagateInterfaceSheet = false
                    }
                )
            }
        case .workspaceDiagnostics:
            WorkspaceDiagnosticsSheetView(
                onClose: {
                    workspace.showWorkspaceDiagnosticsSheet = false
                }
            )
        case .reportProblem:
            ReportProblemSheetView {
                workspace.showReportProblemSheet = false
            }
        case .benchmarkComparison:
            BenchmarkComparisonSheetView(
                onClose: {
                    workspace.showBenchmarkComparisonSheet = false
                }
            )
        case .packageDependencies:
            PackageDependenciesSheetView(
                onClose: {
                    workspace.showPackageDependenciesSheet = false
                }
            )
        case .functionComplexity:
            FunctionComplexitySheetView(
                onClose: {
                    workspace.showFunctionComplexitySheet = false
                }
            )
        case .compilerOptimization:
            CompilerOptimizationSheetView {
                workspace.showCompilerOptimizationSheet = false
            }
        case .multiBuffer:
            MultiBufferEditorView()
        case .addGoModule:
            AddGoModuleSheet {
                workspace.showAddGoModuleSheet = false
            }
        case .addFunctionBreakpoint:
            AddFunctionBreakpointSheet {
                workspace.showAddFunctionBreakpointSheet = false
            }
        case .generateInterfaceMock:
            GenerateInterfaceMockSheetView()
        case .generateEnumMethods:
            GenerateEnumMethodsSheetView()
        case .generateConstructor:
            GenerateConstructorSheetView()
        case .generateFuzzTest:
            GenerateFuzzTestSheetView()
        case .generateBenchmark:
            GenerateBenchmarkSheetView()
        }
    }
}
