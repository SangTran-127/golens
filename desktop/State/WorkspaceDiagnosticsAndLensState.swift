import Foundation
import AppKit
import GoLensFoundation
import Observation

@Observable
final class WorkspaceDiagnosticsAndLensState: @unchecked Sendable {
    @ObservationIgnored weak var workspace: WorkspaceState?
    var flatDiagnostics: [FlatDiagnosticItem] = []
    var hoverGutterLine: Int? = nil
    var diagnostics: [String: [DiagnosticData]] = [:]
    @ObservationIgnored var goplsDiagnostics: [String: [DiagnosticData]] = [:]
    @ObservationIgnored var lintDiagnostics: [String: [DiagnosticData]] = [:]
    @ObservationIgnored var lintPackageFiles: [String: Set<String>] = [:]
    @ObservationIgnored var lintRequestedPackages: Set<String> = []
    @ObservationIgnored var safetyDiagnostics: [String: [DiagnosticData]] = [:]
    @ObservationIgnored var safetyPackageFiles: [String: Set<String>] = [:]
    @ObservationIgnored var safetyRequestedPackages: Set<String> = []
    @ObservationIgnored var moduleDoctorBucket = ModuleDoctorDiagnosticBucket<DiagnosticData>()
    @ObservationIgnored var diagnosticStoresWorkspace: String = ""
    @ObservationIgnored let lintRunner = GolangciLintRunner()
    @ObservationIgnored let safetyRunner = SafetyAnalyzerRunner()
    var issueCounts: [String: IssueCount] = [:] {
        didSet { (workspace?.fileRowStates ?? FileRowStateStore.shared).updateIssueCounts(issueCounts) }
    }
    var issueTotals = IssueCount()
    var errorFolders: Set<String> = [] {
        didSet { (workspace?.fileRowStates ?? FileRowStateStore.shared).updateErrorFolders(errorFolders) }
    }
    var errorPackages: Set<String> = []
    @ObservationIgnored var diagnosticsIndex = DiagnosticsIndex()
    var issuePopup: IssuePopup? = nil

    var renameHint: InlineRenameHint?
    var renameRect: CGRect = .zero
    var renameBounds: CGRect = .zero

    var foldedRanges: [String: Set<FoldableRange>] = [:] {
        didSet {
            foldedLineSets = foldedRanges.mapValues { ranges in
                var set = IndexSet()
                for r in ranges where r.endLine > r.startLine { set.insert(integersIn: r.startLine..<r.endLine) }
                return set
            }
            foldedStartLines = foldedRanges.mapValues { Set($0.map(\.startLine)) }
        }
    }
    var foldableRanges: [String: [FoldableRange]] = [:] {
        didSet {
            foldableStartLines = foldableRanges.mapValues { Set($0.map(\.startLine)) }
        }
    }
    @ObservationIgnored var foldableStartLines: [String: Set<Int>] = [:]
    @ObservationIgnored var foldedStartLines: [String: Set<Int>] = [:]
    @ObservationIgnored var foldedLineSets: [String: IndexSet] = [:]
    var foldedCharRangesCache: [String: [NSRange]] = [:]
    @ObservationIgnored var foldableRangesWorkItem: DispatchWorkItem?

    var codeLensCache: [String: [Int: CodeLensInfo]] = [:]
    @ObservationIgnored var goplsLenses: [String: [Int: [CodeLensItem]]] = [:]
    @ObservationIgnored var blameCache: [String: (stamp: Date, lines: [Int], authors: [Int: String])] = [:]
    @ObservationIgnored var codeLensVersions: [String: Int] = [:]
    @ObservationIgnored var codeLensLoadTask: Task<Void, Never>?
    @ObservationIgnored var codeLensLoadPath: String?
    @ObservationIgnored var codeLensSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored var codeLensTypingWorkItem: DispatchWorkItem?
    @ObservationIgnored var codeLensProgress: [String: CodeLensProgress] = [:]
    @ObservationIgnored var codeLensScrollObserver: NSObjectProtocol?
    @ObservationIgnored var codeLensScrollWorkItem: DispatchWorkItem?

    var showEscapeAnalysis: Bool = UserDefaults.standard.bool(forKey: "GoLensShowEscapeAnalysis")
    @ObservationIgnored var escapeAnnotations: [String: [Int: String]] = [:]
    @ObservationIgnored var escapeAnalysisWorkItem: DispatchWorkItem?
    @ObservationIgnored var activeLineGitBlame: (path: String, line: Int, text: String)? = nil
    @ObservationIgnored var moduleNotes: [String: [Int: String]] = [:]

    var gitStatusTask: Task<Void, Never>? = nil
    @ObservationIgnored var gitRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored var autoFetchTimer: Timer?
    @ObservationIgnored var fileBlameCache: [String: (key: String, task: Task<GitFileBlame?, Never>)] = [:]
    @ObservationIgnored var blameHeadHash: String?
    @ObservationIgnored var activeFileDiffTask: Task<Void, Never>? = nil

    var activeGoDeclarations: [WorkspaceState.GoDeclaration] = []
    @ObservationIgnored var declarationsWorkItem: DispatchWorkItem?
    var activeDocumentSymbols: [DocumentSymbol] = []
    @ObservationIgnored var symbolFetchWorkItem: DispatchWorkItem?
    @ObservationIgnored var counterpartSyncWorkItem: DispatchWorkItem?
    @ObservationIgnored var counterpartDeclarationsCache: (path: String, stamp: String, decls: [WorkspaceState.GoDeclaration])?
    @ObservationIgnored let generatedOriginCache = GeneratedFileOriginCache()
}

extension WorkspaceState {
    var flatDiagnostics: [FlatDiagnosticItem] {
        get { diagnosticsAndLenses.flatDiagnostics }
        set { diagnosticsAndLenses.flatDiagnostics = newValue }
    }

    var hoverGutterLine: Int? {
        get { diagnosticsAndLenses.hoverGutterLine }
        set { diagnosticsAndLenses.hoverGutterLine = newValue }
    }

    var diagnostics: [String: [DiagnosticData]] {
        get { diagnosticsAndLenses.diagnostics }
        set { diagnosticsAndLenses.diagnostics = newValue }
    }

    var goplsDiagnostics: [String: [DiagnosticData]] {
        get { diagnosticsAndLenses.goplsDiagnostics }
        set { diagnosticsAndLenses.goplsDiagnostics = newValue }
    }

    var lintDiagnostics: [String: [DiagnosticData]] {
        get { diagnosticsAndLenses.lintDiagnostics }
        set { diagnosticsAndLenses.lintDiagnostics = newValue }
    }

    var lintPackageFiles: [String: Set<String>] {
        get { diagnosticsAndLenses.lintPackageFiles }
        set { diagnosticsAndLenses.lintPackageFiles = newValue }
    }

    var lintRequestedPackages: Set<String> {
        get { diagnosticsAndLenses.lintRequestedPackages }
        set { diagnosticsAndLenses.lintRequestedPackages = newValue }
    }

    var safetyDiagnostics: [String: [DiagnosticData]] {
        get { diagnosticsAndLenses.safetyDiagnostics }
        set { diagnosticsAndLenses.safetyDiagnostics = newValue }
    }

    var safetyPackageFiles: [String: Set<String>] {
        get { diagnosticsAndLenses.safetyPackageFiles }
        set { diagnosticsAndLenses.safetyPackageFiles = newValue }
    }

    var safetyRequestedPackages: Set<String> {
        get { diagnosticsAndLenses.safetyRequestedPackages }
        set { diagnosticsAndLenses.safetyRequestedPackages = newValue }
    }

    var moduleDoctorBucket: ModuleDoctorDiagnosticBucket<DiagnosticData> {
        get { diagnosticsAndLenses.moduleDoctorBucket }
        set { diagnosticsAndLenses.moduleDoctorBucket = newValue }
    }

    var diagnosticStoresWorkspace: String {
        get { diagnosticsAndLenses.diagnosticStoresWorkspace }
        set { diagnosticsAndLenses.diagnosticStoresWorkspace = newValue }
    }

    var lintRunner: GolangciLintRunner {
        diagnosticsAndLenses.lintRunner
    }

    var safetyRunner: SafetyAnalyzerRunner {
        diagnosticsAndLenses.safetyRunner
    }

    var issueCounts: [String: IssueCount] {
        get { diagnosticsAndLenses.issueCounts }
        set { diagnosticsAndLenses.issueCounts = newValue }
    }

    var issueTotals: IssueCount {
        get { diagnosticsAndLenses.issueTotals }
        set { diagnosticsAndLenses.issueTotals = newValue }
    }

    var errorFolders: Set<String> {
        get { diagnosticsAndLenses.errorFolders }
        set { diagnosticsAndLenses.errorFolders = newValue }
    }

    var errorPackages: Set<String> {
        get { diagnosticsAndLenses.errorPackages }
        set { diagnosticsAndLenses.errorPackages = newValue }
    }

    var diagnosticsIndex: DiagnosticsIndex {
        get { diagnosticsAndLenses.diagnosticsIndex }
        set { diagnosticsAndLenses.diagnosticsIndex = newValue }
    }

    var issuePopup: IssuePopup? {
        get { diagnosticsAndLenses.issuePopup }
        set { diagnosticsAndLenses.issuePopup = newValue }
    }

    var renameHint: InlineRenameHint? {
        get { diagnosticsAndLenses.renameHint }
        set { diagnosticsAndLenses.renameHint = newValue }
    }

    var isRenaming: Bool { renameHint != nil }

    var renameRect: CGRect {
        get { diagnosticsAndLenses.renameRect }
        set { diagnosticsAndLenses.renameRect = newValue }
    }

    var renameBounds: CGRect {
        get { diagnosticsAndLenses.renameBounds }
        set { diagnosticsAndLenses.renameBounds = newValue }
    }

    var foldedRanges: [String: Set<FoldableRange>] {
        get { diagnosticsAndLenses.foldedRanges }
        set { diagnosticsAndLenses.foldedRanges = newValue }
    }

    var foldableRanges: [String: [FoldableRange]] {
        get { diagnosticsAndLenses.foldableRanges }
        set { diagnosticsAndLenses.foldableRanges = newValue }
    }

    var foldableStartLines: [String: Set<Int>] {
        get { diagnosticsAndLenses.foldableStartLines }
        set { diagnosticsAndLenses.foldableStartLines = newValue }
    }

    var foldedStartLines: [String: Set<Int>] {
        get { diagnosticsAndLenses.foldedStartLines }
        set { diagnosticsAndLenses.foldedStartLines = newValue }
    }

    var foldedLineSets: [String: IndexSet] {
        get { diagnosticsAndLenses.foldedLineSets }
        set { diagnosticsAndLenses.foldedLineSets = newValue }
    }

    var foldedCharRangesCache: [String: [NSRange]] {
        get { diagnosticsAndLenses.foldedCharRangesCache }
        set { diagnosticsAndLenses.foldedCharRangesCache = newValue }
    }

    var foldableRangesWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.foldableRangesWorkItem }
        set { diagnosticsAndLenses.foldableRangesWorkItem = newValue }
    }

    var codeLensCache: [String: [Int: CodeLensInfo]] {
        get { diagnosticsAndLenses.codeLensCache }
        set { diagnosticsAndLenses.codeLensCache = newValue }
    }

    var goplsLenses: [String: [Int: [CodeLensItem]]] {
        get { diagnosticsAndLenses.goplsLenses }
        set { diagnosticsAndLenses.goplsLenses = newValue }
    }

    var blameCache: [String: (stamp: Date, lines: [Int], authors: [Int: String])] {
        get { diagnosticsAndLenses.blameCache }
        set { diagnosticsAndLenses.blameCache = newValue }
    }

    var codeLensVersions: [String: Int] {
        get { diagnosticsAndLenses.codeLensVersions }
        set { diagnosticsAndLenses.codeLensVersions = newValue }
    }

    var codeLensLoadTask: Task<Void, Never>? {
        get { diagnosticsAndLenses.codeLensLoadTask }
        set { diagnosticsAndLenses.codeLensLoadTask = newValue }
    }

    var codeLensLoadPath: String? {
        get { diagnosticsAndLenses.codeLensLoadPath }
        set { diagnosticsAndLenses.codeLensLoadPath = newValue }
    }

    var codeLensSaveWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.codeLensSaveWorkItem }
        set { diagnosticsAndLenses.codeLensSaveWorkItem = newValue }
    }

    var codeLensTypingWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.codeLensTypingWorkItem }
        set { diagnosticsAndLenses.codeLensTypingWorkItem = newValue }
    }

    var codeLensProgress: [String: CodeLensProgress] {
        get { diagnosticsAndLenses.codeLensProgress }
        set { diagnosticsAndLenses.codeLensProgress = newValue }
    }

    var codeLensScrollObserver: NSObjectProtocol? {
        get { diagnosticsAndLenses.codeLensScrollObserver }
        set { diagnosticsAndLenses.codeLensScrollObserver = newValue }
    }

    var codeLensScrollWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.codeLensScrollWorkItem }
        set { diagnosticsAndLenses.codeLensScrollWorkItem = newValue }
    }

    var showEscapeAnalysis: Bool {
        get { diagnosticsAndLenses.showEscapeAnalysis }
        set { diagnosticsAndLenses.showEscapeAnalysis = newValue }
    }

    var escapeAnnotations: [String: [Int: String]] {
        get { diagnosticsAndLenses.escapeAnnotations }
        set { diagnosticsAndLenses.escapeAnnotations = newValue }
    }

    var escapeAnalysisWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.escapeAnalysisWorkItem }
        set { diagnosticsAndLenses.escapeAnalysisWorkItem = newValue }
    }

    var activeLineGitBlame: (path: String, line: Int, text: String)? {
        get { diagnosticsAndLenses.activeLineGitBlame }
        set { diagnosticsAndLenses.activeLineGitBlame = newValue }
    }

    var moduleNotes: [String: [Int: String]] {
        get { diagnosticsAndLenses.moduleNotes }
        set { diagnosticsAndLenses.moduleNotes = newValue }
    }

    var gitStatusTask: Task<Void, Never>? {
        get { diagnosticsAndLenses.gitStatusTask }
        set { diagnosticsAndLenses.gitStatusTask = newValue }
    }

    var gitRefreshWorkItem: DispatchWorkItem? {
        get { diagnosticsAndLenses.gitRefreshWorkItem }
        set { diagnosticsAndLenses.gitRefreshWorkItem = newValue }
    }

    var autoFetchTimer: Timer? {
        get { diagnosticsAndLenses.autoFetchTimer }
        set { diagnosticsAndLenses.autoFetchTimer = newValue }
    }

    var fileBlameCache: [String: (key: String, task: Task<GitFileBlame?, Never>)] {
        get { diagnosticsAndLenses.fileBlameCache }
        set { diagnosticsAndLenses.fileBlameCache = newValue }
    }

    var blameHeadHash: String? {
        get { diagnosticsAndLenses.blameHeadHash }
        set { diagnosticsAndLenses.blameHeadHash = newValue }
    }

    var activeFileDiffTask: Task<Void, Never>? {
        get { diagnosticsAndLenses.activeFileDiffTask }
        set { diagnosticsAndLenses.activeFileDiffTask = newValue }
    }

    var activeGoDeclarations: [GoDeclaration] {
        get { primaryPane.goDeclarations }
        set { primaryPane.goDeclarations = newValue }
    }

    var declarationsWorkItem: DispatchWorkItem? {
        get { primaryPane.declarationsWorkItem }
        set { primaryPane.declarationsWorkItem = newValue }
    }

    var activeDocumentSymbols: [DocumentSymbol] {
        get { primaryPane.documentSymbols }
        set { primaryPane.documentSymbols = newValue }
    }

    var symbolFetchWorkItem: DispatchWorkItem? {
        get { primaryPane.symbolFetchWorkItem }
        set { primaryPane.symbolFetchWorkItem = newValue }
    }
}
