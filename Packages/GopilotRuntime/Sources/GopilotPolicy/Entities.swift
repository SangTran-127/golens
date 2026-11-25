import Foundation
import CryptoKit

enum Hashing {
    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkspaceIdentity: Codable, Sendable, Equatable {
    public let id: UUID
    public let canonicalRoots: [String]
    public let moduleGraphHash: String

    public init(id: UUID, canonicalRoots: [String], moduleGraphHash: String) {
        self.id = id
        self.canonicalRoots = canonicalRoots
        self.moduleGraphHash = moduleGraphHash
    }
}

public struct SourceSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let workspaceID: UUID
    public let gitHead: String?
    public let dirtyFileHashes: [String: String]
    public let documentVersions: [String: Int]
    public let buildTarget: String?
    public let goVersion: String?
    public let tags: [String]
    public let effectiveModuleVersions: [String: String]

    public init(id: String, workspaceID: UUID, gitHead: String? = nil, dirtyFileHashes: [String: String] = [:], documentVersions: [String: Int] = [:], buildTarget: String? = nil, goVersion: String? = nil, tags: [String] = [], effectiveModuleVersions: [String: String] = [:]) {
        self.id = id
        self.workspaceID = workspaceID
        self.gitHead = gitHead
        self.dirtyFileHashes = dirtyFileHashes
        self.documentVersions = documentVersions
        self.buildTarget = buildTarget
        self.goVersion = goVersion
        self.tags = tags
        self.effectiveModuleVersions = effectiveModuleVersions
    }
}

public struct SourceRange: Codable, Sendable, Equatable {
    public let startLine: Int
    public let startCharacter: Int
    public let endLine: Int
    public let endCharacter: Int

    public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
    }
}

public struct SourceRef: Codable, Sendable, Equatable {
    public let workspaceID: UUID
    public let dependencyRootID: String?
    public let path: String
    public let range: SourceRange?
    public let contentHash: String?
    public let documentVersion: Int?
    public let symbolID: String?

    public init(workspaceID: UUID, dependencyRootID: String? = nil, path: String, range: SourceRange? = nil, contentHash: String? = nil, documentVersion: Int? = nil, symbolID: String? = nil) {
        self.workspaceID = workspaceID
        self.dependencyRootID = dependencyRootID
        self.path = path
        self.range = range
        self.contentHash = contentHash
        self.documentVersion = documentVersion
        self.symbolID = symbolID
    }
}

public enum EvidenceKind: String, Codable, Sendable {
    case workspaceFact
    case listing
    case search
    case source
    case symbol
    case reference
    case callHierarchy
    case documentation
    case diagnostic
    case run
    case benchmark
    case profile
    case patch
    case memory
}

public enum EvidenceBasis: String, Codable, Sendable {
    case observed
    case inferred
}

public struct EvidenceDraft: Sendable, Equatable {
    public let workspaceID: UUID
    public let producerID: String
    public let kind: EvidenceKind
    public let sourceRefs: [SourceRef]
    public let snapshotID: String
    public let content: String
    public let isTruncated: Bool
    public let basis: EvidenceBasis
    public let expiresAt: Date?

    public init(workspaceID: UUID, producerID: String, kind: EvidenceKind, sourceRefs: [SourceRef] = [], snapshotID: String, content: String, isTruncated: Bool = false, basis: EvidenceBasis = .observed, expiresAt: Date? = nil) {
        self.workspaceID = workspaceID
        self.producerID = producerID
        self.kind = kind
        self.sourceRefs = sourceRefs
        self.snapshotID = snapshotID
        self.content = content
        self.isTruncated = isTruncated
        self.basis = basis
        self.expiresAt = expiresAt
    }
}

public struct Evidence: Codable, Sendable, Equatable {
    public let id: String
    public let workspaceID: UUID
    public let producerID: String
    public let kind: EvidenceKind
    public let sourceRefs: [SourceRef]
    public let capturedAt: Date
    public let snapshotID: String
    public let content: String
    public let contentHash: String
    public let isTruncated: Bool
    public let basis: EvidenceBasis
    public let expiresAt: Date?

    public var isComplete: Bool { !isTruncated }

    public init(id: String, workspaceID: UUID, producerID: String, kind: EvidenceKind, sourceRefs: [SourceRef], capturedAt: Date, snapshotID: String, content: String, contentHash: String, isTruncated: Bool, basis: EvidenceBasis, expiresAt: Date? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.producerID = producerID
        self.kind = kind
        self.sourceRefs = sourceRefs
        self.capturedAt = capturedAt
        self.snapshotID = snapshotID
        self.content = content
        self.contentHash = contentHash
        self.isTruncated = isTruncated
        self.basis = basis
        self.expiresAt = expiresAt
    }
}

public enum StalenessReason: String, Codable, Sendable, Equatable {
    case workspaceMismatch
    case snapshotChanged
    case documentVersionChanged
    case contentHashChanged
}

public struct Staleness: Sendable, Equatable {
    public let reasons: [StalenessReason]
    public var isStale: Bool { !reasons.isEmpty }

    public static let fresh = Staleness(reasons: [])

    public init(reasons: [StalenessReason]) {
        self.reasons = reasons
    }

    public static func assess(_ evidence: Evidence, against snapshot: SourceSnapshot) -> Staleness {
        if evidence.workspaceID != snapshot.workspaceID {
            return Staleness(reasons: [.workspaceMismatch])
        }
        if evidence.snapshotID == snapshot.id { return .fresh }
        var reasons: [StalenessReason] = [.snapshotChanged]
        for ref in evidence.sourceRefs where ref.dependencyRootID == nil {
            if let version = ref.documentVersion, let current = snapshot.documentVersions[ref.path], version != current,
               !reasons.contains(.documentVersionChanged) {
                reasons.append(.documentVersionChanged)
            }
            if let hash = ref.contentHash, let current = snapshot.dirtyFileHashes[ref.path], hash != current,
               !reasons.contains(.contentHashChanged) {
                reasons.append(.contentHashChanged)
            }
        }
        return Staleness(reasons: reasons)
    }
}

public enum AttachmentOrigin: String, Codable, Sendable, Equatable {
    case filePicker
    case symbolPicker
    case editorSelection
    case atMention
}

public struct AttachedSourceRef: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspaceID: UUID
    public let relativePath: String
    public let symbolName: String?
    public let range: SourceRange?
    public let documentVersion: Int?
    public let contentHash: String
    public let isUnsaved: Bool
    public let origin: AttachmentOrigin

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        relativePath: String,
        symbolName: String? = nil,
        range: SourceRange? = nil,
        documentVersion: Int? = nil,
        contentHash: String,
        isUnsaved: Bool = false,
        origin: AttachmentOrigin = .filePicker
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.symbolName = symbolName
        self.range = range
        self.documentVersion = documentVersion
        self.contentHash = contentHash
        self.isUnsaved = isUnsaved
        self.origin = origin
    }

    public var deduplicationKey: String {
        let r = range.map { "\($0.startLine):\($0.endLine)" } ?? "all"
        return "\(relativePath)|\(r)|\(symbolName ?? "")"
    }

    public var displayLabel: String {
        let base = (relativePath as NSString).lastPathComponent
        if let symbolName, !symbolName.isEmpty {
            return "\(symbolName) (\(base))"
        }
        if let range {
            let s = range.startLine + 1
            let e = range.endLine + 1
            return s == e ? "\(base):\(s)" : "\(base):\(s)–\(e)"
        }
        return relativePath
    }
}

public struct AttachedSourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { ref.id }
    public let ref: AttachedSourceRef
    public let text: String
    public let evidenceID: String?
    public let wasTruncated: Bool

    public init(ref: AttachedSourceRef, text: String, evidenceID: String? = nil, wasTruncated: Bool = false) {
        self.ref = ref
        self.text = text
        self.evidenceID = evidenceID
        self.wasTruncated = wasTruncated
    }
}

public struct TurnReadScope: Codable, Sendable, Equatable {
    public let projectContextEnabled: Bool
    public let allowedSources: [AttachedSourceRef]

    public static let unrestricted = TurnReadScope(projectContextEnabled: true, allowedSources: [])

    public init(projectContextEnabled: Bool = true, allowedSources: [AttachedSourceRef] = []) {
        self.projectContextEnabled = projectContextEnabled
        self.allowedSources = allowedSources
    }

    public func allowsFile(relativePath: String, dependencyRootID: String? = nil) -> Bool {
        if projectContextEnabled { return true }
        guard dependencyRootID == nil else { return false }
        return allowedSources.contains { $0.relativePath == relativePath }
    }

    public func allowsPosition(relativePath: String, dependencyRootID: String? = nil, lineZeroBased: Int) -> Bool {
        if projectContextEnabled { return true }
        guard dependencyRootID == nil else { return false }
        let matching = allowedSources.filter { $0.relativePath == relativePath }
        guard !matching.isEmpty else { return false }
        for source in matching {
            guard let range = source.range else { return true }
            if lineZeroBased >= range.startLine && lineZeroBased <= range.endLine {
                return true
            }
        }
        return false
    }

    public func allowedLineBounds(for relativePath: String, requestedStart: Int, requestedEnd: Int) -> (start: Int, end: Int)? {
        if projectContextEnabled { return (requestedStart, requestedEnd) }
        let matching = allowedSources.filter { $0.relativePath == relativePath }
        guard !matching.isEmpty else { return nil }
        if matching.contains(where: { $0.range == nil }) {
            return (requestedStart, requestedEnd)
        }
        var bestOverlap: (start: Int, end: Int)?
        for source in matching {
            guard let range = source.range else { continue }
            let allowedStart = range.startLine + 1
            let allowedEnd = range.endLine + 1
            let clampedStart = max(requestedStart, allowedStart)
            let clampedEnd = min(requestedEnd, allowedEnd)
            if clampedStart <= clampedEnd {
                if let existing = bestOverlap {
                    bestOverlap = (min(existing.start, clampedStart), max(existing.end, clampedEnd))
                } else {
                    bestOverlap = (clampedStart, clampedEnd)
                }
            }
        }
        return bestOverlap
    }
}

public enum SourceUsageCategory: String, Codable, Sendable, Equatable {
    case attached
    case lookedUp
    case cited
}

public struct SourceUsageItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(category.rawValue)|\(path)|\(startLine ?? 0):\(endLine ?? 0)|\(evidenceID ?? "")" }
    public let category: SourceUsageCategory
    public let path: String
    public let startLine: Int?
    public let endLine: Int?
    public let symbolName: String?
    public let evidenceID: String?
    public let isUnsaved: Bool

    public init(
        category: SourceUsageCategory,
        path: String,
        startLine: Int? = nil,
        endLine: Int? = nil,
        symbolName: String? = nil,
        evidenceID: String? = nil,
        isUnsaved: Bool = false
    ) {
        self.category = category
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.symbolName = symbolName
        self.evidenceID = evidenceID
        self.isUnsaved = isUnsaved
    }

    public var label: String {
        let base = (path as NSString).lastPathComponent
        if let symbolName, !symbolName.isEmpty {
            return "\(symbolName) (\(base))"
        }
        if let s = startLine, let e = endLine, s > 0 {
            return s == e ? "\(base):\(s)" : "\(base):\(s)–\(e)"
        }
        return path
    }
}

public struct SourcesUsedSummary: Codable, Sendable, Equatable {
    public var attached: [SourceUsageItem]
    public var lookedUp: [SourceUsageItem]
    public var cited: [SourceUsageItem]

    public init(attached: [SourceUsageItem] = [], lookedUp: [SourceUsageItem] = [], cited: [SourceUsageItem] = []) {
        self.attached = attached
        self.lookedUp = lookedUp
        self.cited = cited
    }

    public var isEmpty: Bool {
        attached.isEmpty && lookedUp.isEmpty && cited.isEmpty
    }

    public var all: [SourceUsageItem] {
        attached + lookedUp + cited
    }

    public var totalCount: Int {
        attached.count + lookedUp.count + cited.count
    }
}
