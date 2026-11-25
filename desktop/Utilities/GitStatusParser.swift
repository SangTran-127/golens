import Foundation

struct GitStatusSnapshot: Equatable {
    struct Entry: Equatable {
        let x: Character
        let y: Character
        let path: String
        let originalPath: String?
        let isUnmerged: Bool
        let isUntracked: Bool
        var indexObject: String? = nil
        var unmergedXY: String? = nil
    }

    var head: String?
    var hasCommits = true
    var upstream: String?
    var upstreamExists = false
    var ahead = 0
    var behind = 0
    var entries: [Entry] = []

    var hasUpstream: Bool { upstream != nil && upstreamExists }
}

struct GitStatusRow: Equatable {
    let repoPath: String
    let relativePath: String
    let status: String
    let isStaged: Bool
    var originalPath: String? = nil
    var originalRepoPath: String? = nil
    var unmergedXY: String? = nil
}

struct GitPathChange: Equatable {
    let status: String
    let path: String
    let originalPath: String?
}

enum GitStatusParser {
    static func split(_ text: Substring.UnicodeScalarView, on separator: Unicode.Scalar, maxSplits: Int = .max) -> [String] {
        text.split(separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    static func split(_ text: String, on separator: Unicode.Scalar, maxSplits: Int = .max) -> [String] {
        split(Substring(text).unicodeScalars, on: separator, maxSplits: maxSplits)
    }

    static func parse(_ output: String) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        var fields = split(output, on: "\0").makeIterator()
        while let field = fields.next() {
            guard let kind = field.unicodeScalars.first else { continue }
            switch kind {
            case "#":
                parseHeader(field, into: &snapshot)
            case "1", "2", "u":
                let parts = split(field, on: " ", maxSplits: kind == "1" ? 8 : (kind == "2" ? 9 : 10))
                guard parts.count > 8, parts[1].unicodeScalars.count == 2, let path = parts.last else { continue }
                let xy = Array(parts[1].unicodeScalars)
                let original = kind == "2" ? fields.next() : nil
                snapshot.entries.append(GitStatusSnapshot.Entry(
                    x: unchanged(xy[0]),
                    y: unchanged(xy[1]),
                    path: path,
                    originalPath: original,
                    isUnmerged: kind == "u",
                    isUntracked: false,
                    indexObject: kind == "u" ? nil : parts[7],
                    unmergedXY: kind == "u" ? parts[1] : nil
                ))
            case "?":
                let path = String(String.UnicodeScalarView(field.unicodeScalars.dropFirst(2)))
                snapshot.entries.append(GitStatusSnapshot.Entry(x: "?", y: "?", path: path, originalPath: nil, isUnmerged: false, isUntracked: true))
            default:
                continue
            }
        }
        return snapshot
    }

    private static func unchanged(_ scalar: Unicode.Scalar) -> Character { scalar == "." ? " " : Character(scalar) }

    private static func parseHeader(_ field: String, into snapshot: inout GitStatusSnapshot) {
        let parts = split(field, on: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = parts[2]
        switch parts[1] {
        case "branch.oid": snapshot.hasCommits = value != "(initial)"
        case "branch.head": snapshot.head = value == "(detached)" ? nil : value
        case "branch.upstream": snapshot.upstream = value
        case "branch.ab":
            snapshot.upstreamExists = true
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                snapshot.ahead = Int(counts[0].dropFirst()) ?? 0
                snapshot.behind = Int(counts[1].dropFirst()) ?? 0
            }
        default: break
        }
    }

    static func rows(from snapshot: GitStatusSnapshot, workspacePrefix: String) -> [GitStatusRow] {
        var rows: [GitStatusRow] = []
        for entry in snapshot.entries {
            let relativePath = entry.path.hasPrefix(workspacePrefix) ? String(entry.path.dropFirst(workspacePrefix.count)) : entry.path
            let status: String
            if entry.isUnmerged {
                status = "U"
            } else if entry.isUntracked {
                status = "??"
            } else {
                status = String(entry.x != " " ? entry.x : entry.y)
            }
            let isStaged = !entry.isUnmerged && !entry.isUntracked && entry.x != " "
            let original = entry.originalPath.map { $0.hasPrefix(workspacePrefix) ? String($0.dropFirst(workspacePrefix.count)) : $0 }
            rows.append(GitStatusRow(repoPath: entry.path, relativePath: relativePath, status: status, isStaged: isStaged, originalPath: original, originalRepoPath: entry.originalPath, unmergedXY: entry.isUnmerged ? entry.unmergedXY : nil))
            if isStaged && entry.y != " " {
                rows.append(GitStatusRow(repoPath: entry.path, relativePath: relativePath, status: String(entry.y), isStaged: false, originalPath: original, originalRepoPath: entry.originalPath))
            }
        }
        return rows
    }

    static func numstat(_ output: String) -> [String: (added: Int, removed: Int)] {
        var stats: [String: (added: Int, removed: Int)] = [:]
        var fields = split(output, on: "\0").makeIterator()
        while let field = fields.next() {
            let parts = split(field, on: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            var path = parts[2]
            if path.isEmpty {
                _ = fields.next()
                guard let new = fields.next() else { break }
                path = new
            }
            stats[path] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
        return stats
    }

    static func nameStatus(_ output: String) -> [GitPathChange] {
        var changes: [GitPathChange] = []
        var fields = split(output, on: "\0").makeIterator()
        while let field = fields.next() {
            guard let letter = field.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(letter) else { continue }
            guard let first = fields.next() else { break }
            if letter == "R" || letter == "C" {
                guard let second = fields.next() else { break }
                changes.append(GitPathChange(status: String(letter), path: second, originalPath: first))
            } else {
                changes.append(GitPathChange(status: String(letter), path: first, originalPath: nil))
            }
        }
        return changes
    }
}
