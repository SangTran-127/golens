import Foundation

public struct CurrentFileState: Sendable, Equatable {
    public let exists: Bool
    public let text: String?
    public let documentVersion: Int?

    public init(exists: Bool, text: String?, documentVersion: Int? = nil) {
        self.exists = exists
        self.text = text
        self.documentVersion = documentVersion
    }

    public static let missing = CurrentFileState(exists: false, text: nil)
}

public typealias CurrentFileProvider = @Sendable (String) -> CurrentFileState

public enum StaleReason: Sendable, Equatable {
    case missingFile
    case hashMismatch(expected: String, actual: String)
    case versionMismatch(expected: Int, actual: Int?)
    case rangeOutOfBounds(start: Int, end: Int, length: Int)
    case rangeSplitsCharacter(offset: Int)
    case createTargetExists
}

public struct StaleFile: Sendable, Equatable {
    public let path: String
    public let reason: StaleReason
}

public enum AuthorizationFailure: Sendable, Equatable {
    case tokenExpired
    case proposalHashMismatch
    case proposalNotApplicable(PatchStatus)
}

public struct PlannedFileEdit: Sendable, Equatable, Codable {
    public let path: String
    public let documentVersion: Int?
    public let beforeHash: String
    public let beforeText: String
    public let edits: [TextEdit]
    public let inverseEdits: [TextEdit]
    public let afterText: String
    public let afterHash: String
}

public struct PlannedFileCreation: Sendable, Equatable, Codable {
    public let path: String
    public let content: String
    public let afterHash: String
}

public struct ApplyPlan: Sendable, Equatable {
    public let proposalID: UUID
    public let proposalHash: String
    public let undoGroupID: UUID
    public let fileEdits: [PlannedFileEdit]
    public let creations: [PlannedFileCreation]

    public var afterHashes: [String: String] {
        var out: [String: String] = [:]
        for edit in fileEdits { out[edit.path] = edit.afterHash }
        for creation in creations { out[creation.path] = creation.afterHash }
        return out
    }
}

public enum PlanOutcome: Sendable, Equatable {
    case ready(ApplyPlan)
    case invalid([PatchIssue])
    case stale([StaleFile])
    case notAuthorized(AuthorizationFailure)
}

public struct PlanResult: Sendable, Equatable {
    public let outcome: PlanOutcome
    public let proposal: PatchProposal
}

public enum PatchApplyPlanner {
    public static func plan(proposal: PatchProposal, token: UserActionToken, context: PatchValidationContext, current: CurrentFileProvider, now: Date = Date()) -> PlanResult {
        guard token.isValid(at: now) else {
            return PlanResult(outcome: .notAuthorized(.tokenExpired), proposal: proposal)
        }
        guard token.approvedProposalHash == proposal.contentHash else {
            return PlanResult(outcome: .notAuthorized(.proposalHashMismatch), proposal: proposal)
        }
        guard proposal.status == .proposed else {
            return PlanResult(outcome: .notAuthorized(.proposalNotApplicable(proposal.status)), proposal: proposal)
        }
        let issues = PatchValidator.validate(proposal, context: context)
        if !issues.isEmpty {
            let reason = "invalid proposal (" + issues.map { $0.code.rawValue }.joined(separator: ", ") + "); regenerate it"
            return PlanResult(outcome: .invalid(issues), proposal: proposal.withStatus(.stale(reason: reason)))
        }

        var stale: [StaleFile] = []
        var fileEdits: [PlannedFileEdit] = []
        var creations: [PlannedFileCreation] = []
        for operation in proposal.operations {
            let state = current(operation.path)
            switch operation.kind {
            case .edit:
                switch planEdit(operation, state: state) {
                case .success(let planned): fileEdits.append(planned)
                case .failure(let failure): stale.append(StaleFile(path: operation.path, reason: failure.reason))
                }
            case .create:
                if state.exists {
                    stale.append(StaleFile(path: operation.path, reason: .createTargetExists))
                } else if let content = operation.content {
                    creations.append(PlannedFileCreation(path: operation.path, content: content, afterHash: ContentHash.sha256Hex(content)))
                }
            default:
                break
            }
        }
        if !stale.isEmpty {
            let reason = "stale files: " + stale.map(\.path).joined(separator: ", ") + "; regenerate the proposal against the current files"
            return PlanResult(outcome: .stale(stale), proposal: proposal.withStatus(.stale(reason: reason)))
        }
        let plan = ApplyPlan(proposalID: proposal.id, proposalHash: proposal.contentHash, undoGroupID: UUID(), fileEdits: fileEdits, creations: creations)
        return PlanResult(outcome: .ready(plan), proposal: proposal)
    }

    public static func expectedAfterHashes(for proposal: PatchProposal, current: CurrentFileProvider) -> [String: String]? {
        var out: [String: String] = [:]
        for operation in proposal.operations {
            switch operation.kind {
            case .edit:
                guard case .success(let planned) = planEdit(operation, state: current(operation.path)) else { return nil }
                out[operation.path] = planned.afterHash
            case .create:
                guard let content = operation.content else { return nil }
                out[operation.path] = ContentHash.sha256Hex(content)
            default:
                return nil
            }
        }
        return out
    }

    private struct EditFailure: Error {
        let reason: StaleReason
    }

    private static func planEdit(_ operation: PatchFileOperation, state: CurrentFileState) -> Result<PlannedFileEdit, EditFailure> {
        guard state.exists, let text = state.text else { return .failure(EditFailure(reason: .missingFile)) }
        let actualHash = ContentHash.sha256Hex(text)
        if let expected = operation.baseHash, expected != actualHash {
            return .failure(EditFailure(reason: .hashMismatch(expected: expected, actual: actualHash)))
        }
        if let expectedVersion = operation.documentVersion, state.documentVersion != expectedVersion {
            return .failure(EditFailure(reason: .versionMismatch(expected: expectedVersion, actual: state.documentVersion)))
        }
        let units = Array(text.utf16)
        let ascending = operation.edits.sorted { ($0.startUTF16, $0.endUTF16) < ($1.startUTF16, $1.endUTF16) }
        for edit in ascending {
            if edit.endUTF16 > units.count || edit.startUTF16 > units.count {
                return .failure(EditFailure(reason: .rangeOutOfBounds(start: edit.startUTF16, end: edit.endUTF16, length: units.count)))
            }
            for boundary in [edit.startUTF16, edit.endUTF16] where splitsSurrogatePair(units, at: boundary) {
                return .failure(EditFailure(reason: .rangeSplitsCharacter(offset: boundary)))
            }
        }

        var inverse: [TextEdit] = []
        var delta = 0
        for edit in ascending {
            let original = String(decoding: units[edit.startUTF16..<edit.endUTF16], as: UTF16.self)
            let start = edit.startUTF16 + delta
            let replacementLength = edit.replacement.utf16.count
            inverse.append(TextEdit(startUTF16: start, endUTF16: start + replacementLength, replacement: original))
            delta += replacementLength - (edit.endUTF16 - edit.startUTF16)
        }

        var result = units
        for edit in ascending.reversed() {
            result.replaceSubrange(edit.startUTF16..<edit.endUTF16, with: Array(edit.replacement.utf16))
        }
        let afterText = String(decoding: result, as: UTF16.self)
        return .success(PlannedFileEdit(
            path: operation.path,
            documentVersion: state.documentVersion,
            beforeHash: actualHash,
            beforeText: text,
            edits: Array(ascending.reversed()),
            inverseEdits: Array(inverse.reversed()),
            afterText: afterText,
            afterHash: ContentHash.sha256Hex(afterText)
        ))
    }

    static func splitsSurrogatePair(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0, index < units.count else { return false }
        return UTF16.isLeadSurrogate(units[index - 1]) && UTF16.isTrailSurrogate(units[index])
    }
}
