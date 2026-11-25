import Foundation
import Observation

struct GitRepoLocation: Equatable {
    let repoRoot: String
    let gitDir: String
    let workspacePrefix: String
}

final class GitRefreshCoordinator {
    static let shared = GitRefreshCoordinator()

    var token = 0
    var inFlightWorkspace: String?
    var pending = false
    var locations: [String: GitRepoLocation] = [:]
    var untrackedDirectories: [String] = []
    var unavailableRetryTask: Task<Void, Never>?
    var unavailableAttempts = 0
    var transientRetryTask: Task<Void, Never>?
    var transientRetryWorkspace: String?
    var transientAttempts = 0
    static let maxTransientAttempts = 6

    static func hostSeesRepository(at workspacePath: String) -> Bool {
        var dir = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return true
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return false }
            dir = parent
        }
    }

    func reset(keeping workspacePath: String) {
        locations = locations.filter { $0.key == workspacePath }
    }

    func isInsideUntrackedDirectory(_ path: String) -> Bool {
        untrackedDirectories.contains { path.hasPrefix($0 + "/") }
    }
}

@Observable
final class GitRefreshStatus {
    static let shared = GitRefreshStatus()
    var unavailableMessage: String?
}

@Observable
final class GitChangeStamps {
    static let shared = GitChangeStamps()
    var fileStamps: [String: String] = [:]
    var indexStamp = ""

    func stamp(for path: String) -> String {
        fileStamps[path] ?? ""
    }

    static func stamp(ofPath path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "missing" }
        return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_size):\(info.st_ino)"
    }
}

final class GitIndexWatch: @unchecked Sendable {
    static let shared = GitIndexWatch()

    private let lock = NSLock()
    private var knownStamps: [String: String] = [:]
    private var runningWrites = 0
    private var lastWriteEnd = Date.distantPast

    static let readSubcommands: Set<String> = [
        "status", "diff", "diff-files", "diff-index", "diff-tree", "show", "log", "rev-parse", "rev-list",
        "for-each-ref", "blame", "ls-files", "ls-tree", "cat-file", "merge-base", "name-rev", "describe",
        "shortlog", "grep", "check-ignore", "remote", "branch", "tag", "config", "version", "reflog"
    ]

    func record(indexPath: String, stamp: String) {
        lock.lock()
        defer { lock.unlock() }
        knownStamps[indexPath] = stamp
    }

    func commandStarted(_ args: [String]) -> Bool {
        guard GitCommandRunner.subcommand(of: args) != nil, !GitCommandRunner.isReadOnly(args) else { return false }
        lock.lock()
        defer { lock.unlock() }
        runningWrites += 1
        return true
    }

    func writeCommandFinished() {
        lock.lock()
        defer { lock.unlock() }
        runningWrites = max(0, runningWrites - 1)
        lastWriteEnd = Date()
    }

    func shouldRefresh(forIndexAt indexPath: String) -> Bool {
        let current = GitChangeStamps.stamp(ofPath: indexPath)
        lock.lock()
        defer { lock.unlock() }
        if runningWrites > 0 || Date().timeIntervalSince(lastWriteEnd) < 1.0 {
            return false
        }
        if knownStamps[indexPath] == current {
            return false
        }
        knownStamps[indexPath] = current
        return true
    }
}

enum GitRefsFingerprint {
    static func compute(gitDir: String) -> String {
        let fm = FileManager.default
        var commonDir = gitDir
        if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            commonDir = trimmed.hasPrefix("/") ? trimmed : URL(fileURLWithPath: (gitDir as NSString).appendingPathComponent(trimmed)).standardizedFileURL.path
        }
        var parts: [String] = []
        let head = (try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
        parts.append(head)
        if head.hasPrefix("ref: ") {
            let ref = head.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append((try? String(contentsOfFile: (commonDir as NSString).appendingPathComponent(ref), encoding: .utf8)) ?? "")
        }
        for name in ["packed-refs", "refs/stash", "logs/refs/stash"] {
            parts.append(GitChangeStamps.stamp(ofPath: (commonDir as NSString).appendingPathComponent(name)))
        }
        parts.append(GitChangeStamps.stamp(ofPath: (gitDir as NSString).appendingPathComponent("logs/HEAD")))
        let headsDir = (commonDir as NSString).appendingPathComponent("refs/heads")
        if let enumerator = fm.enumerator(atPath: headsDir) {
            var heads: [String] = []
            while let name = enumerator.nextObject() as? String {
                heads.append(name + "=" + GitChangeStamps.stamp(ofPath: (headsDir as NSString).appendingPathComponent(name)))
            }
            parts.append(heads.sorted().joined(separator: ","))
        }
        return parts.joined(separator: "|")
    }
}
