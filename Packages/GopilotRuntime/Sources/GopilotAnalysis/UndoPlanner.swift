import Foundation

public struct DiffLine: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case same
        case removed
        case added
    }

    public let kind: Kind
    public let text: String
}

public enum LineDiff {
    public static let maxLinesPerSide = 1500

    public static func diff(from old: String, to new: String) -> (lines: [DiffLine], truncated: Bool) {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        if midA.count > maxLinesPerSide || midB.count > maxLinesPerSide {
            return ([], true)
        }

        let n = midA.count
        let m = midB.count
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * width + j] = midA[i] == midB[j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var lines: [DiffLine] = a[0..<prefix].map { DiffLine(kind: .same, text: $0) }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, midA[i] == midB[j] {
                lines.append(DiffLine(kind: .same, text: midA[i]))
                i += 1
                j += 1
            } else if i < n, j == m || table[(i + 1) * width + j] >= table[i * width + j + 1] {
                lines.append(DiffLine(kind: .removed, text: midA[i]))
                i += 1
            } else {
                lines.append(DiffLine(kind: .added, text: midB[j]))
                j += 1
            }
        }
        lines += a[(a.count - suffix)...].map { DiffLine(kind: .same, text: $0) }
        return (lines, false)
    }
}

public enum UndoCollisionReason: String, Sendable, Equatable {
    case fileMissing
    case contentChanged
    case versionChanged
}

public struct RecoveryDiff: Sendable, Equatable {
    public let path: String
    public let reason: UndoCollisionReason
    public let expectedAfterHash: String
    public let currentHash: String?
    public let currentText: String?
    public let originalText: String?
    public let patchedText: String
    public let currentToOriginal: [DiffLine]
    public let diffTruncated: Bool
}

public struct UndoFileAction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case revertEdits([TextEdit], resultingHash: String)
        case removeCreatedFile
    }

    public let path: String
    public let expectedAfterHash: String
    public let kind: Kind
}

public struct UndoPlan: Sendable, Equatable {
    public let proposalID: UUID
    public let undoGroupID: UUID
    public let actions: [UndoFileAction]
}

public enum UndoOutcome: Sendable, Equatable {
    case revert(UndoPlan)
    case collision([RecoveryDiff])
    case notApplicable(ApplyJournalState)
}

public enum UndoPlanner {
    public static func plan(entry: ApplyJournalEntry, current: CurrentFileProvider) -> UndoOutcome {
        guard entry.state == .applied else { return .notApplicable(entry.state) }
        var actions: [UndoFileAction] = []
        var collisions: [RecoveryDiff] = []
        for file in entry.files {
            let state = current(file.path)
            if let diff = collision(file: file, state: state) {
                collisions.append(diff)
                continue
            }
            switch file.kind {
            case .edit:
                let before = file.beforeHash ?? ""
                actions.append(UndoFileAction(path: file.path, expectedAfterHash: file.afterHash, kind: .revertEdits(file.inverseEdits, resultingHash: before)))
            case .create:
                actions.append(UndoFileAction(path: file.path, expectedAfterHash: file.afterHash, kind: .removeCreatedFile))
            }
        }
        if !collisions.isEmpty { return .collision(collisions) }
        return .revert(UndoPlan(proposalID: entry.proposalID, undoGroupID: entry.undoGroupID, actions: actions))
    }

    private static func collision(file: JournalFile, state: CurrentFileState) -> RecoveryDiff? {
        var reason: UndoCollisionReason?
        var currentHash: String?
        if !state.exists || state.text == nil {
            reason = .fileMissing
        } else if let text = state.text {
            currentHash = ContentHash.sha256Hex(text)
            if currentHash != file.afterHash {
                reason = .contentChanged
            } else if let expectedVersion = file.afterVersion, state.documentVersion != expectedVersion {
                reason = .versionChanged
            }
        }
        guard let reason else { return nil }
        let original = file.beforeText ?? ""
        let currentText = state.text ?? ""
        let diff = LineDiff.diff(from: currentText, to: original)
        return RecoveryDiff(
            path: file.path,
            reason: reason,
            expectedAfterHash: file.afterHash,
            currentHash: currentHash,
            currentText: state.text,
            originalText: file.beforeText,
            patchedText: file.afterText,
            currentToOriginal: diff.lines,
            diffTruncated: diff.truncated
        )
    }
}
