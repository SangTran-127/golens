import Foundation
import Observation

public enum WorkspacePathCanonicalizer {
    public static func canonical(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var resolved = (URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path as NSString).standardizingPath
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] {
            if resolved == prefix || resolved.hasPrefix(prefix + "/") {
                resolved = String(resolved.dropFirst("/private".count))
                break
            }
        }
        if resolved.count > 1 && resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    public static func contains(workspaceRoot: String, targetPath: String) -> Bool {
        let root = canonical(workspaceRoot)
        let target = canonical(targetPath)
        guard !root.isEmpty, !target.isEmpty else { return false }
        if root == "/" { return target.hasPrefix("/") }
        return target == root || target.hasPrefix(root + "/")
    }
}

public enum WorkspaceSheetKind: String, Hashable, Sendable, CaseIterable, Identifiable {
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
    case packageDependencies
    case functionComplexity
    case compilerOptimization
    case runConfigurations
    case newProject
    case goToLine
    case addGoModule
    case addFunctionBreakpoint
    case multiBuffer
    case interactiveForm
    case changeSignature
    case generateDockerfile
    case fileHistory
    case sourceControl
    case dataSources
    case dockerCleanUp
    case kubernetesApply

    public var id: String { rawValue }
}

public enum WorkspaceOpenRoutingDecision: Equatable, Sendable {
    case focusExistingWindow(sessionID: UUID)
    case bindCurrentWindow(sessionID: UUID)
    case openDedicatedWindow(canonicalPath: String)
}

public enum ColdLaunchWindowDecision: Equatable, Sendable {
    case claimInitialWorkspace(canonicalPath: String, initialFilePath: String?)
    case presentWelcomeAndCloseEmptyWorkspace
}

@Observable
public final class WorkspaceSessionRecord: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var activeWorkspacePath: String {
        didSet {
            let normalized = WorkspacePathCanonicalizer.canonical(activeWorkspacePath)
            if activeWorkspacePath != normalized {
                activeWorkspacePath = normalized
            }
        }
    }
    public var openFiles: [String]
    public var activeFilePath: String
    public var editedFiles: Set<String>
    public var activeSheetKind: WorkspaceSheetKind?

    public init(
        id: UUID = UUID(),
        activeWorkspacePath: String = "",
        openFiles: [String] = [],
        activeFilePath: String = "",
        editedFiles: Set<String> = [],
        activeSheetKind: WorkspaceSheetKind? = nil
    ) {
        self.id = id
        self.activeWorkspacePath = WorkspacePathCanonicalizer.canonical(activeWorkspacePath)
        self.openFiles = openFiles.map(WorkspacePathCanonicalizer.canonical)
        self.activeFilePath = WorkspacePathCanonicalizer.canonical(activeFilePath)
        self.editedFiles = Set(editedFiles.map(WorkspacePathCanonicalizer.canonical))
        self.activeSheetKind = activeSheetKind
    }

    public func openFile(_ path: String) {
        let normalized = WorkspacePathCanonicalizer.canonical(path)
        guard !normalized.isEmpty else { return }
        if !openFiles.contains(normalized) {
            openFiles.append(normalized)
        }
        activeFilePath = normalized
    }

    public func closeFile(_ path: String) {
        let normalized = WorkspacePathCanonicalizer.canonical(path)
        openFiles.removeAll { $0 == normalized }
        editedFiles.remove(normalized)
        if activeFilePath == normalized {
            activeFilePath = openFiles.last ?? ""
        }
    }

    public func setSheetPresented(_ kind: WorkspaceSheetKind, _ isPresented: Bool) {
        if isPresented {
            activeSheetKind = kind
        } else if activeSheetKind == kind {
            activeSheetKind = nil
        }
    }

    public func isSheetPresented(_ kind: WorkspaceSheetKind) -> Bool {
        activeSheetKind == kind
    }
}

@Observable
public final class WorkspaceSessionCoordinator: @unchecked Sendable {
    public private(set) var sessions: [WorkspaceSessionRecord] = []
    public private(set) var activeSessionID: UUID?

    public init() {}

    public var activeSession: WorkspaceSessionRecord? {
        if let activeSessionID, let match = sessions.first(where: { $0.id == activeSessionID }) {
            return match
        }
        return sessions.first
    }

    @discardableResult
    public func registerSession(
        id: UUID = UUID(),
        workspacePath: String = "",
        makeActive: Bool = true
    ) -> WorkspaceSessionRecord {
        let normalized = WorkspacePathCanonicalizer.canonical(workspacePath)
        if !normalized.isEmpty, let existing = session(forWorkspacePath: normalized) {
            if makeActive {
                activeSessionID = existing.id
            }
            return existing
        }
        if let existingByID = sessions.first(where: { $0.id == id }) {
            if !normalized.isEmpty {
                existingByID.activeWorkspacePath = normalized
            }
            if makeActive {
                activeSessionID = existingByID.id
            }
            return existingByID
        }
        let record = WorkspaceSessionRecord(id: id, activeWorkspacePath: normalized)
        sessions.append(record)
        if makeActive || activeSessionID == nil {
            activeSessionID = record.id
        }
        return record
    }

    public func activate(sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        activeSessionID = sessionID
    }

    public func updateWorkspacePath(_ path: String, for sessionID: UUID) {
        guard let record = sessions.first(where: { $0.id == sessionID }) else { return }
        record.activeWorkspacePath = WorkspacePathCanonicalizer.canonical(path)
    }

    public func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.last?.id
        }
    }

    public func session(forWorkspacePath path: String) -> WorkspaceSessionRecord? {
        let normalized = WorkspacePathCanonicalizer.canonical(path)
        guard !normalized.isEmpty else { return nil }
        return sessions.first { $0.activeWorkspacePath == normalized }
    }

    public func session(containingFilePath filePath: String) -> WorkspaceSessionRecord? {
        let normalized = WorkspacePathCanonicalizer.canonical(filePath)
        guard !normalized.isEmpty else { return nil }
        var bestMatch: WorkspaceSessionRecord?
        var bestLength = -1
        for candidate in sessions where !candidate.activeWorkspacePath.isEmpty {
            if WorkspacePathCanonicalizer.contains(workspaceRoot: candidate.activeWorkspacePath, targetPath: normalized),
               candidate.activeWorkspacePath.count > bestLength {
                bestMatch = candidate
                bestLength = candidate.activeWorkspacePath.count
            }
        }
        return bestMatch
    }

    public func routingDecision(
        forTargetPath rawTargetPath: String,
        preferredEmptySessionID: UUID? = nil
    ) -> WorkspaceOpenRoutingDecision {
        let canonical = WorkspacePathCanonicalizer.canonical(rawTargetPath)
        if let existing = session(forWorkspacePath: canonical) {
            return .focusExistingWindow(sessionID: existing.id)
        }
        if let preferredEmptySessionID,
           let preferred = sessions.first(where: { $0.id == preferredEmptySessionID }),
           preferred.activeWorkspacePath.isEmpty {
            return .bindCurrentWindow(sessionID: preferred.id)
        }
        if let unbound = sessions.first(where: { $0.activeWorkspacePath.isEmpty }) {
            return .bindCurrentWindow(sessionID: unbound.id)
        }
        return .openDedicatedWindow(canonicalPath: canonical)
    }

    public static func coldLaunchDecision(
        restoredWorkspacePath: String?,
        restoredFilePath: String?
    ) -> ColdLaunchWindowDecision {
        let canonicalWorkspace = WorkspacePathCanonicalizer.canonical(restoredWorkspacePath ?? "")
        guard !canonicalWorkspace.isEmpty else {
            return .presentWelcomeAndCloseEmptyWorkspace
        }
        let canonicalFile = WorkspacePathCanonicalizer.canonical(restoredFilePath ?? "")
        return .claimInitialWorkspace(
            canonicalPath: canonicalWorkspace,
            initialFilePath: canonicalFile.isEmpty ? nil : canonicalFile
        )
    }
}
