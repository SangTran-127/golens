import Foundation

struct GitRef: Identifiable, Hashable {
    enum Kind: Hashable {
        case branch
        case remoteBranch(remote: String)
        case tag
    }

    let kind: Kind
    let fullName: String
    let name: String
    let shortHash: String
    let upstream: String
    let date: Date?
    let subject: String

    var id: String { fullName }
}

struct GitRemoteInfo: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { name }
}

struct GitHistoryCommit: Identifiable, Hashable {
    let hash: String
    let shortHash: String
    let author: String
    let email: String
    let date: Date
    let refs: [String]
    let subject: String
    var parents: [String] = []
    var id: String { hash }
}

enum GitHistoryParser {
    static let refFormat = "%(refname)%00%(objectname:short)%00%(upstream:short)%00%(creatordate:unix)%00%(subject)"
    static let logFormat = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%P%x1f%s"

    static func refs(_ output: String) -> [GitRef] {
        output.split(separator: "\n").compactMap { line in
            let parts = GitStatusParser.split(String(line), on: "\0")
            guard parts.count >= 5 else { return nil }
            let full = parts[0]
            let kind: GitRef.Kind
            let name: String
            if full.hasPrefix("refs/heads/") {
                kind = .branch
                name = String(full.dropFirst("refs/heads/".count))
            } else if full.hasPrefix("refs/tags/") {
                kind = .tag
                name = String(full.dropFirst("refs/tags/".count))
            } else if full.hasPrefix("refs/remotes/") {
                let rest = full.dropFirst("refs/remotes/".count)
                guard let slash = rest.firstIndex(of: "/") else { return nil }
                let remote = String(rest[..<slash])
                name = String(rest[rest.index(after: slash)...])
                if name == "HEAD" { return nil }
                kind = .remoteBranch(remote: remote)
            } else {
                return nil
            }
            return GitRef(
                kind: kind,
                fullName: full,
                name: name,
                shortHash: parts[1],
                upstream: parts[2],
                date: TimeInterval(parts[3]).map { Date(timeIntervalSince1970: $0) },
                subject: parts[4...].joined(separator: "\0")
            )
        }
    }

    static func remotes(_ output: String) -> [GitRemoteInfo] {
        var seen = Set<String>()
        var result: [GitRemoteInfo] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, !seen.contains(String(fields[0])) else { continue }
            seen.insert(String(fields[0]))
            result.append(GitRemoteInfo(name: String(fields[0]), url: String(fields[1])))
        }
        return result
    }

    static func commits(_ output: String) -> [GitHistoryCommit] {
        GitStatusParser.split(output, on: "\0").compactMap { record in
            let parts = GitStatusParser.split(record.trimmingCharacters(in: .newlines), on: "\u{1f}", maxSplits: 7)
            guard parts.count == 8, let seconds = TimeInterval(parts[4]) else { return nil }
            let refs = parts[5].isEmpty ? [] : parts[5].components(separatedBy: ", ")
            return GitHistoryCommit(
                hash: parts[0],
                shortHash: parts[1],
                author: parts[2],
                email: parts[3],
                date: Date(timeIntervalSince1970: seconds),
                refs: refs,
                subject: parts[7],
                parents: parts[6].split(separator: " ").map(String.init)
            )
        }
    }
}
