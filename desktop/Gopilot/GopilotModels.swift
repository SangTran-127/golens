import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

protocol GopilotRuntimeFactory {
    var providerSummary: String? { get }
    func makeSession(workspacePath: String, history: [ModelMessage], memory: MemoryStore?) -> GopilotSessionContext?
}

struct GopilotSymbolCandidate: Identifiable, Equatable, Sendable {
    var id: String { "\(relativePath):\(name):\(startLine)" }
    let name: String
    let kind: String
    let relativePath: String
    let startLine: Int
    let endLine: Int

    var subtitle: String {
        let base = (relativePath as NSString).lastPathComponent
        return startLine == endLine ? "\(base):\(startLine)" : "\(base):\(startLine)–\(endLine)"
    }
}

struct GopilotAttachment: Identifiable, Equatable {
    let id: UUID
    let relativePath: String
    let absolutePath: String
    let startLine: Int
    let endLine: Int
    let symbolName: String?
    let text: String
    let documentVersion: Int
    let isUnsaved: Bool
    let isWholeFile: Bool
    let isFolder: Bool
    let origin: AttachmentOrigin

    init(
        id: UUID = UUID(),
        relativePath: String,
        absolutePath: String,
        startLine: Int,
        endLine: Int,
        symbolName: String? = nil,
        text: String,
        documentVersion: Int,
        isUnsaved: Bool = false,
        isWholeFile: Bool = false,
        isFolder: Bool = false,
        origin: AttachmentOrigin = .editorSelection
    ) {
        self.id = id
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.startLine = startLine
        self.endLine = endLine
        self.symbolName = symbolName
        self.text = text
        self.documentVersion = documentVersion
        self.isUnsaved = isUnsaved
        self.isWholeFile = isWholeFile
        self.isFolder = isFolder
        self.origin = origin
    }

    var deduplicationKey: String {
        if isFolder {
            return "folder|\(relativePath)"
        }
        let rangeKey = isWholeFile ? "all" : "\(startLine):\(endLine)"
        return "\(relativePath)|\(rangeKey)|\(symbolName ?? "")"
    }

    var label: String {
        if isFolder {
            return "\(relativePath)/"
        }
        let name = (relativePath as NSString).lastPathComponent
        if let symbolName, !symbolName.isEmpty {
            return "\(symbolName) · \(name)"
        }
        if isWholeFile {
            return name
        }
        return startLine == endLine ? "\(name):\(startLine)" : "\(name):\(startLine)–\(endLine)"
    }

    var iconName: String {
        if isFolder { return "folder.fill" }
        if symbolName != nil { return "function" }
        if !isWholeFile && origin == .editorSelection { return "text.quote" }
        return "doc.text"
    }

    func toAttachedSourceRef(workspaceID: UUID) -> AttachedSourceRef {
        let sourceRange: SourceRange?
        if isWholeFile {
            sourceRange = nil
        } else {
            sourceRange = SourceRange(
                startLine: max(0, startLine - 1),
                startCharacter: 0,
                endLine: max(0, endLine - 1),
                endCharacter: 0
            )
        }
        return AttachedSourceRef(
            id: id,
            workspaceID: workspaceID,
            relativePath: relativePath,
            symbolName: symbolName,
            range: sourceRange,
            documentVersion: documentVersion,
            contentHash: GopilotAnalysis.ContentHash.sha256Hex(text),
            isUnsaved: isUnsaved,
            origin: origin
        )
    }
}

enum GopilotPresetPrompt {
    static let understandProject = "What does this project do, and where should I start reading? Pick one representative flow and trace it from the entry point to where data is stored or the output is produced."
    static let explainSelection = "Explain this selection: what it does, the Go idioms and error paths involved, and how it relates to the rest of the project."
    static let traceFlow = "Trace the flow that passes through this selection: who calls it, what it calls next, and where the data ends up. Say where you are unsure."
    static let continueFromFindings = "Continue from the files and evidence you already read in this conversation. Summarize what the project does and trace the main flow using the evidence gathered so far, then read only the remaining files needed to finish."
    static let continueAgentTask = "Continue the task from where you stopped. Re-read any file you already changed before editing it again, finish the remaining steps, verify them, and then summarize the files you changed."

    static func shortTitle(for prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == understandProject { return "Understand Project" }
        if trimmed == explainSelection { return "Explain Selected Code" }
        if trimmed == traceFlow { return "Trace This Flow" }
        if trimmed == continueFromFindings { return "Continue from Findings" }
        if trimmed == continueAgentTask { return "Continue Task" }
        if trimmed.hasPrefix("Investigate the ") && trimmed.contains(" hotspot ") && trimmed.contains(" in the attached profile.") {
            return "Investigate Hotspot"
        }
        return nil
    }

    static func symbol(for shortTitle: String) -> String {
        switch shortTitle {
        case "Understand Project": "map"
        case "Explain Selected Code": "text.magnifyingglass"
        case "Trace This Flow": "point.topleft.down.curvedto.point.bottomright.up"
        case "Continue from Findings", "Continue Task": "arrow.clockwise"
        case "Investigate Hotspot": "flame"
        default: "sparkles"
        }
    }
}

struct GopilotTurnChange: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case applied
        case pendingReview
        case rejected
        case failed
        case undone
    }

    var id: String { "\(proposalID.uuidString)|\(path)" }
    let turnID: UUID
    let proposalID: UUID
    let path: String
    let isNewFile: Bool
    var status: Status
    var additions: Int
    var deletions: Int
    var isUnsaved: Bool
    var detail: String?
}

struct GopilotUndoAllResult: Equatable {
    var revertedFiles: Int = 0
    var rejectedProposals: Int = 0
    var collisions: [String] = []
    var failures: [String] = []

    var isComplete: Bool { collisions.isEmpty && failures.isEmpty }
}

enum GopilotSandboxStatus: Equatable {
    case ready
    case starting(String)
    case paused
    case stopped
    case unavailable(reason: String, recovery: String)

    var title: String {
        switch self {
        case .ready: "Linux container ready"
        case .starting: "Starting Linux container"
        case .paused: "Linux container paused"
        case .stopped: "Linux container stopped"
        case .unavailable: "Linux container unavailable"
        }
    }
}

struct GopilotTodoItem: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    let id: String
    var content: String
    var status: Status
}

enum GopilotTranscriptItem: Identifiable, Equatable {
    case user(id: UUID, text: String, attachment: String?)
    case assistant(id: UUID, text: String)
    case activity(id: String, label: String, status: ActivityStatus)
    case notice(id: UUID, kind: NoticeKind, text: String, canRetry: Bool)
    case proposal(id: UUID, summary: String, files: Int, warnings: [PatchSecurityWarning] = [])
    case applied(id: UUID, text: String)

    enum ActivityStatus: Equatable {
        case running
        case finished
        case failed
    }

    enum NoticeKind: Equatable {
        case info
        case warning
        case error
        case authentication
        case requestRejected
        case trust
        case budgetExceeded(hasFindings: Bool)
        case unsupportedEffort(routeID: String)
        case untestedAgentRoute(routeID: String)
    }

    var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _): id.uuidString
        case .activity(let id, _, _): id
        case .notice(let id, _, _, _): id.uuidString
        case .proposal(let id, _, _, _): "proposal-\(id.uuidString)"
        case .applied(let id, _): "applied-\(id.uuidString)"
        }
    }
}
