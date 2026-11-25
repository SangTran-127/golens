import Foundation

public enum PatchOperationKind: String, Sendable, Equatable, Codable {
    case edit
    case create
    case rename
    case delete
    case binary
    case dependencyInstall
}

public struct TextEdit: Sendable, Equatable, Codable {
    public let startUTF16: Int
    public let endUTF16: Int
    public let replacement: String

    public init(startUTF16: Int, endUTF16: Int, replacement: String) {
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.replacement = replacement
    }
}

public struct PatchFileOperation: Sendable, Equatable, Codable {
    public let kind: PatchOperationKind
    public let path: String
    public let baseHash: String?
    public let documentVersion: Int?
    public let edits: [TextEdit]
    public let content: String?

    public init(kind: PatchOperationKind, path: String, baseHash: String? = nil, documentVersion: Int? = nil, edits: [TextEdit] = [], content: String? = nil) {
        self.kind = kind
        self.path = path
        self.baseHash = baseHash
        self.documentVersion = documentVersion
        self.edits = edits
        self.content = content
    }

    public static func edit(path: String, baseHash: String, documentVersion: Int?, edits: [TextEdit]) -> PatchFileOperation {
        PatchFileOperation(kind: .edit, path: path, baseHash: baseHash, documentVersion: documentVersion, edits: edits)
    }

    public static func create(path: String, content: String) -> PatchFileOperation {
        PatchFileOperation(kind: .create, path: path, content: content)
    }
}

public enum PatchStatus: Sendable, Equatable, Codable {
    case proposed
    case stale(reason: String)
    case rejected
    case applied
    case rolledBack
}

public struct PatchProposal: Sendable, Equatable, Codable {
    public let id: UUID
    public let turnID: UUID
    public let rationale: String
    public let operations: [PatchFileOperation]
    public let verificationPlan: [String]
    public let expectedAfterHashes: [String: String]
    public let status: PatchStatus
    public let createdAt: Date

    public init(id: UUID = UUID(), turnID: UUID, rationale: String, operations: [PatchFileOperation], verificationPlan: [String] = [], expectedAfterHashes: [String: String] = [:], status: PatchStatus = .proposed, createdAt: Date = Date()) {
        self.id = id
        self.turnID = turnID
        self.rationale = rationale
        self.operations = operations
        self.verificationPlan = verificationPlan
        self.expectedAfterHashes = expectedAfterHashes
        self.status = status
        self.createdAt = createdAt
    }

    public var contentHash: String {
        var parts: [String: String] = [
            "id": id.uuidString,
            "turn": turnID.uuidString,
            "rationale": ContentHash.sha256Hex(rationale),
            "verification": verificationPlan.map { ContentHash.sha256Hex($0) }.joined(separator: ","),
            "after": ContentHash.combined(expectedAfterHashes)
        ]
        for (index, operation) in operations.enumerated() {
            let edits = operation.edits.map { "\($0.startUTF16):\($0.endUTF16):\(ContentHash.sha256Hex($0.replacement))" }.joined(separator: ";")
            let fields = [
                operation.kind.rawValue,
                operation.path,
                operation.baseHash ?? "-",
                operation.documentVersion.map(String.init) ?? "-",
                edits,
                operation.content.map { ContentHash.sha256Hex($0) } ?? "-"
            ]
            parts["op\(index)"] = fields.joined(separator: "|")
        }
        return ContentHash.combined(parts)
    }

    public func withStatus(_ newStatus: PatchStatus) -> PatchProposal {
        PatchProposal(id: id, turnID: turnID, rationale: rationale, operations: operations, verificationPlan: verificationPlan, expectedAfterHashes: expectedAfterHashes, status: newStatus, createdAt: createdAt)
    }

    public func withExpectedAfterHashes(_ hashes: [String: String]) -> PatchProposal {
        PatchProposal(id: id, turnID: turnID, rationale: rationale, operations: operations, verificationPlan: verificationPlan, expectedAfterHashes: hashes, status: status, createdAt: createdAt)
    }

    public func rejected() -> PatchProposal { withStatus(.rejected) }
}

public struct UserActionToken: Sendable, Equatable {
    public static let lifetime: TimeInterval = 120

    public let id: UUID
    public let issuedAt: Date
    public let approvedProposalHash: String

    init(approvedProposalHash: String, issuedAt: Date) {
        self.id = UUID()
        self.issuedAt = issuedAt
        self.approvedProposalHash = approvedProposalHash
    }

    public static func makeFromUserAction(approvingProposalHash: String, at issuedAt: Date = Date()) -> UserActionToken {
        UserActionToken(approvedProposalHash: approvingProposalHash, issuedAt: issuedAt)
    }

    public func isValid(at date: Date) -> Bool {
        date >= issuedAt && date.timeIntervalSince(issuedAt) <= Self.lifetime
    }
}
