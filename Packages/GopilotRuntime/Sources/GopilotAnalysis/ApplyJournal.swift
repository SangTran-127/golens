import Foundation

public enum ApplyJournalState: String, Sendable, Equatable, Codable {
    case prepared
    case applying
    case applied
    case rolledBack
}

public struct JournalFile: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case edit
        case create
    }

    public let kind: Kind
    public let path: String
    public let beforeHash: String?
    public let beforeText: String?
    public let afterHash: String
    public let afterText: String
    public let inverseEdits: [TextEdit]
    public let afterVersion: Int?
}

public struct ApplyJournalEntry: Sendable, Equatable, Codable {
    public let proposalID: UUID
    public let proposalHash: String
    public let undoGroupID: UUID
    public let preparedAt: Date
    public let state: ApplyJournalState
    public let updatedAt: Date
    public let files: [JournalFile]
}

public enum ApplyJournalError: Error, Sendable, Equatable {
    case duplicateProposal(UUID)
    case unknownProposal(UUID)
    case invalidTransition(from: ApplyJournalState, to: ApplyJournalState)
}

public enum FileObservation: Sendable, Equatable {
    case matchesBefore
    case matchesAfter
    case other
    case missing
}

public enum RecoveryClassification: String, Sendable, Equatable {
    case notApplied
    case fullyApplied
    case partiallyApplied
    case diverged
}

public enum RecoveryAction: String, Sendable, Equatable {
    case discardPrepared
    case confirmApplied
    case reviewRecoveryDiff
}

public struct RecoveryReport: Sendable, Equatable {
    public let proposalID: UUID
    public let state: ApplyJournalState
    public let classification: RecoveryClassification
    public let perFile: [String: FileObservation]
    public let recommended: RecoveryAction
}

public struct ApplyJournal: Sendable, Equatable, Codable {
    public private(set) var entries: [ApplyJournalEntry] = []

    public init() {}

    public func entry(for proposalID: UUID) -> ApplyJournalEntry? {
        entries.first { $0.proposalID == proposalID }
    }

    public mutating func prepare(plan: ApplyPlan, now: Date = Date()) throws -> ApplyJournalEntry {
        guard entry(for: plan.proposalID) == nil else { throw ApplyJournalError.duplicateProposal(plan.proposalID) }
        var files: [JournalFile] = []
        for edit in plan.fileEdits {
            files.append(JournalFile(kind: .edit, path: edit.path, beforeHash: edit.beforeHash, beforeText: edit.beforeText, afterHash: edit.afterHash, afterText: edit.afterText, inverseEdits: edit.inverseEdits, afterVersion: nil))
        }
        for creation in plan.creations {
            files.append(JournalFile(kind: .create, path: creation.path, beforeHash: nil, beforeText: nil, afterHash: creation.afterHash, afterText: creation.content, inverseEdits: [], afterVersion: nil))
        }
        let entry = ApplyJournalEntry(proposalID: plan.proposalID, proposalHash: plan.proposalHash, undoGroupID: plan.undoGroupID, preparedAt: now, state: .prepared, updatedAt: now, files: files)
        entries.append(entry)
        return entry
    }

    public mutating func markApplying(_ proposalID: UUID, now: Date = Date()) throws {
        try transition(proposalID, to: .applying, now: now)
    }

    public mutating func markApplied(_ proposalID: UUID, afterVersions: [String: Int] = [:], now: Date = Date()) throws {
        try transition(proposalID, to: .applied, now: now) { files in
            files.map { file in
                JournalFile(kind: file.kind, path: file.path, beforeHash: file.beforeHash, beforeText: file.beforeText, afterHash: file.afterHash, afterText: file.afterText, inverseEdits: file.inverseEdits, afterVersion: afterVersions[file.path] ?? file.afterVersion)
            }
        }
    }

    public mutating func markRolledBack(_ proposalID: UUID, now: Date = Date()) throws {
        try transition(proposalID, to: .rolledBack, now: now)
    }

    public func recover(observe: (String) -> FileObservationInput) -> [RecoveryReport] {
        entries.filter { $0.state == .prepared || $0.state == .applying }.map { entry in
            var perFile: [String: FileObservation] = [:]
            for file in entry.files {
                let input = observe(file.path)
                perFile[file.path] = classify(file: file, input: input)
            }
            let values = Array(perFile.values)
            let allBefore = values.allSatisfy { $0 == .matchesBefore }
            let allAfter = values.allSatisfy { $0 == .matchesAfter }
            let anyOther = values.contains { $0 == .other || $0 == .missing }
            let classification: RecoveryClassification
            let action: RecoveryAction
            if allBefore {
                classification = .notApplied
                action = .discardPrepared
            } else if allAfter {
                classification = .fullyApplied
                action = .confirmApplied
            } else if anyOther {
                classification = .diverged
                action = .reviewRecoveryDiff
            } else {
                classification = .partiallyApplied
                action = .reviewRecoveryDiff
            }
            return RecoveryReport(proposalID: entry.proposalID, state: entry.state, classification: classification, perFile: perFile, recommended: action)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ApplyJournal {
        try JSONDecoder().decode(ApplyJournal.self, from: data)
    }

    private func classify(file: JournalFile, input: FileObservationInput) -> FileObservation {
        switch file.kind {
        case .edit:
            guard input.exists, let hash = input.contentHash else { return .missing }
            if hash == file.afterHash { return .matchesAfter }
            if hash == file.beforeHash { return .matchesBefore }
            return .other
        case .create:
            guard input.exists, let hash = input.contentHash else { return .matchesBefore }
            return hash == file.afterHash ? .matchesAfter : .other
        }
    }

    private static let allowedTransitions: [ApplyJournalState: Set<ApplyJournalState>] = [
        .prepared: [.applying, .rolledBack],
        .applying: [.applied, .rolledBack],
        .applied: [.rolledBack],
        .rolledBack: []
    ]

    private mutating func transition(_ proposalID: UUID, to newState: ApplyJournalState, now: Date, files transform: (([JournalFile]) -> [JournalFile])? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.proposalID == proposalID }) else { throw ApplyJournalError.unknownProposal(proposalID) }
        let entry = entries[index]
        guard Self.allowedTransitions[entry.state]?.contains(newState) == true else {
            throw ApplyJournalError.invalidTransition(from: entry.state, to: newState)
        }
        entries[index] = ApplyJournalEntry(proposalID: entry.proposalID, proposalHash: entry.proposalHash, undoGroupID: entry.undoGroupID, preparedAt: entry.preparedAt, state: newState, updatedAt: now, files: transform?(entry.files) ?? entry.files)
    }
}

public struct FileObservationInput: Sendable, Equatable {
    public let exists: Bool
    public let contentHash: String?

    public init(exists: Bool, contentHash: String?) {
        self.exists = exists
        self.contentHash = contentHash
    }
}
