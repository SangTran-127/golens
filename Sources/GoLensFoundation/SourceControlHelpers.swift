import Foundation

public enum IssueBadgeAccessibility {
    public static func countText(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    public static func label(errors: Int, warnings: Int) -> String {
        "\(countText(errors, "error")), \(countText(warnings, "warning")). Show Issues"
    }
}

public struct GitBranchDeleteDecision: Equatable, Sendable {
    public let messageText: String
    public let informativeText: String
    public let actionTitle: String
    public let showsDeleteRemoteOption: Bool
    public let deleteRemoteTitle: String?

    public static func evaluate(
        branchName: String,
        targetBranchName: String,
        upstream: String,
        mergedIntoHead: Bool,
        hasRemoteTrackingRef: Bool
    ) -> GitBranchDeleteDecision {
        let safeTarget = targetBranchName.isEmpty ? "HEAD" : targetBranchName
        let canDeleteRemote = !upstream.isEmpty && hasRemoteTrackingRef
        let messageText = "Delete the branch “\(branchName)”?"
        let informativeText: String
        if mergedIntoHead {
            informativeText = "Its commits are already in “\(safeTarget)”, so none are lost."
        } else {
            let remoteNote = canDeleteRemote ? " (especially if also deleted on the remote)" : ""
            informativeText = "“\(branchName)” has commits that aren’t merged into “\(safeTarget)”. Deleting it\(remoteNote) can permanently lose those commits."
        }
        let actionTitle = mergedIntoHead ? "Delete" : "Force Delete"
        let deleteRemoteTitle = canDeleteRemote ? "Also delete “\(upstream)” on the remote" : nil
        return GitBranchDeleteDecision(
            messageText: messageText,
            informativeText: informativeText,
            actionTitle: actionTitle,
            showsDeleteRemoteOption: canDeleteRemote,
            deleteRemoteTitle: deleteRemoteTitle
        )
    }

    public static func branchDeleteFlag(mergedIntoHead: Bool, mergedIntoUpstream: Bool, deleteRemote: Bool) -> String {
        (mergedIntoHead && !deleteRemote && mergedIntoUpstream) ? "-d" : "-D"
    }
}

public enum GitExcludesFileHelper {
    public static func resolvePath(
        configuredValue: String,
        workspacePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackHomeDirectory: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let trimmed = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultExcludesPath(environment: environment, fallbackHomeDirectory: fallbackHomeDirectory)
        }
        let home = resolvedHomeDirectory(environment: environment, fallback: fallbackHomeDirectory)
        let expanded = expandTilde(trimmed, homeDirectory: home)
        if expanded.hasPrefix("/") {
            return expanded
        }
        if !workspacePath.isEmpty {
            let workspaceCandidate = URL(
                fileURLWithPath: expanded,
                relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true)
            ).standardizedFileURL.path
            if fileExists(workspaceCandidate) {
                return workspaceCandidate
            }
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: home, isDirectory: true)
        ).standardizedFileURL.path
    }

    public static func defaultExcludesPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackHomeDirectory: String = NSHomeDirectory()
    ) -> String {
        let xdg = (environment["XDG_CONFIG_HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let home = resolvedHomeDirectory(environment: environment, fallback: fallbackHomeDirectory)
        let base: String = xdg.isEmpty
            ? (home as NSString).appendingPathComponent(".config")
            : expandTilde(xdg, homeDirectory: home)
        return (base as NSString).appendingPathComponent("git/ignore")
    }

    public static func withoutCarriageReturn(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    public static func isEditablePatternLine(_ line: String) -> Bool {
        let trimmed = withoutCarriageReturn(line).trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    public static func patternTexts(in lines: [String]) -> [String] {
        lines.map { withoutCarriageReturn($0) }.filter { isEditablePatternLine($0) }
    }

    public static func lineIndex(of pattern: String, occurrence: Int, in lines: [String]) -> Int? {
        var seen = 0
        for (index, line) in lines.enumerated() where isEditablePatternLine(line) {
            if withoutCarriageReturn(line) == pattern {
                if seen == occurrence { return index }
                seen += 1
            }
        }
        return nil
    }

    private static func resolvedHomeDirectory(environment: [String: String], fallback: String) -> String {
        if let envHome = environment["HOME"], !envHome.isEmpty {
            return envHome
        }
        return fallback
    }

    private static func expandTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return (path as NSString).expandingTildeInPath
    }
}

public enum GitCommandFailureFormatter {
    public static func subcommand(from args: [String]) -> String {
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "-C" || arg == "-c" || arg == "--git-dir" || arg == "--work-tree" {
                idx += 2
                continue
            }
            if arg.hasPrefix("-") {
                idx += 1
                continue
            }
            if arg == "stash", idx + 1 < args.count, !args[idx + 1].hasPrefix("-") {
                return "stash \(args[idx + 1])"
            }
            return arg
        }
        return "git"
    }

    public static func formatFailure(
        args: [String],
        exitCode: Int,
        stderr: String,
        stdout: String
    ) -> String? {
        let subcommand = subcommand(from: args)
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = !trimmedOut.isEmpty ? trimmedOut : (!trimmedErr.isEmpty ? trimmedErr : "no output")
        if subcommand == "log" && detail.localizedCaseInsensitiveContains("does not have any commits yet") {
            return nil
        }
        return "git \(subcommand) failed (exit \(exitCode)): \(detail)"
    }
}

public struct GitWorktreeEntry: Identifiable, Equatable, Hashable, Sendable {
    public let path: String
    public let headHash: String
    public let branchName: String?
    public let isDetached: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let pruneReason: String?

    public init(
        path: String,
        headHash: String = "",
        branchName: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        pruneReason: String? = nil
    ) {
        self.path = path
        self.headHash = headHash
        self.branchName = branchName
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.pruneReason = pruneReason
    }

    public var id: String { path }
    public var folderName: String { (path as NSString).lastPathComponent }
    public var shortHash: String { headHash.isEmpty ? "" : String(headHash.prefix(7)) }

    public var displayBranch: String {
        if let branchName, !branchName.isEmpty {
            return branchName
        }
        if isBare {
            return "Bare Repository"
        }
        if isDetached {
            return "Detached HEAD"
        }
        return shortHash.isEmpty ? "HEAD" : shortHash
    }
}

public enum GitWorktreeParser {
    public static func parsePorcelain(
        _ output: String,
        canonicalize: (String) -> String = { WorkspacePathCanonicalizer.canonical($0) }
    ) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var path: String?
        var headHash = ""
        var branchName: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var pruneReason: String?

        func flush() {
            guard let currentPath = path, !currentPath.isEmpty else { return }
            entries.append(
                GitWorktreeEntry(
                    path: currentPath,
                    headHash: headHash,
                    branchName: branchName,
                    isDetached: isDetached,
                    isBare: isBare,
                    isLocked: isLocked,
                    lockReason: lockReason,
                    isPrunable: isPrunable,
                    pruneReason: pruneReason
                )
            )
            path = nil
            headHash = ""
            branchName = nil
            isDetached = false
            isBare = false
            isLocked = false
            lockReason = nil
            isPrunable = false
            pruneReason = nil
        }

        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                let rawPath = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespaces)
                path = canonicalize(rawPath)
            } else if line.hasPrefix("HEAD ") {
                headHash = String(line.dropFirst("HEAD ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("branch ") {
                let rawRef = String(line.dropFirst("branch ".count)).trimmingCharacters(in: .whitespaces)
                if rawRef.hasPrefix("refs/heads/") {
                    branchName = String(rawRef.dropFirst("refs/heads/".count))
                } else {
                    branchName = rawRef
                }
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
                let reason = String(line.dropFirst("locked".count)).trimmingCharacters(in: .whitespaces)
                lockReason = reason.isEmpty ? nil : reason
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                isPrunable = true
                let reason = String(line.dropFirst("prunable".count)).trimmingCharacters(in: .whitespaces)
                pruneReason = reason.isEmpty ? nil : reason
            }
        }
        flush()
        return entries
    }

    public static func defaultSiblingPath(repoPath: String, branchName: String) -> String {
        let trimmedRepo = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty else { return "" }
        let cleanRepo: String = {
            var s = (trimmedRepo as NSString).standardizingPath
            while s.count > 1 && s.hasSuffix("/") {
                s.removeLast()
            }
            return s
        }()
        let parent = (cleanRepo as NSString).deletingLastPathComponent
        let repoName = (cleanRepo as NSString).lastPathComponent
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        var sanitized = ""
        var prevDash = false
        for scalar in trimmedBranch.unicodeScalars {
            let isSeparator = scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSeparator {
                if !sanitized.isEmpty && !prevDash {
                    sanitized.append("-")
                    prevDash = true
                }
            } else {
                sanitized.unicodeScalars.append(scalar)
                prevDash = (scalar == "-")
            }
        }
        while sanitized.hasSuffix("-") {
            sanitized.removeLast()
        }
        if sanitized.isEmpty {
            sanitized = "worktree"
        }
        let dirName = repoName.isEmpty ? sanitized : "\(repoName)-\(sanitized)"
        if parent.isEmpty || parent == "." {
            return dirName
        }
        return (parent as NSString).appendingPathComponent(dirName)
    }

    public static func checkedOutWorktreePath(fromGitError output: String) -> String? {
        let markers = [
            "is already used by worktree at ",
            "is already checked out at ",
            "already used by worktree at ",
            "already checked out at ",
        ]
        for marker in markers {
            guard let range = output.range(of: marker, options: .caseInsensitive) else { continue }
            var tail = String(output[range.upperBound...])
            if let newline = tail.firstIndex(of: "\n") {
                tail = String(tail[..<newline])
            }
            tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else { continue }
            let quotePairs: [(Character, Character)] = [("'", "'"), ("\"", "\""), ("‘", "’"), ("`", "`")]
            for (open, close) in quotePairs {
                if tail.first == open {
                    let innerStart = tail.index(after: tail.startIndex)
                    if let closeIdx = tail[innerStart...].lastIndex(of: close) {
                        let extracted = String(tail[innerStart..<closeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        return extracted.isEmpty ? nil : extracted
                    }
                    let extracted = String(tail[innerStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return extracted.isEmpty ? nil : extracted
                }
            }
            return tail
        }
        return nil
    }
}
