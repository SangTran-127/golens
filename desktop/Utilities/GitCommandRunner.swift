import Foundation

struct GitCommandResult: Sendable {
    static let truncatedFlag: UInt32 = 1 << 0
    static let unavailableFlag: UInt32 = 1 << 1
    static let cancelledFlag: UInt32 = 1 << 2
    static let outsideWorkspaceFlag: UInt32 = 1 << 3

    let output: String
    let exitCode: Int
    let errorText: String
    let flags: UInt32

    var isTruncated: Bool { flags & Self.truncatedFlag != 0 }
    var isUnavailable: Bool { flags & Self.unavailableFlag != 0 }
    var isCancelled: Bool { flags & Self.cancelledFlag != 0 }
    var isOutsideWorkspace: Bool { flags & Self.outsideWorkspaceFlag != 0 }

    static func decode(_ raw: UnsafeRawPointer, length: Int) -> GitCommandResult? {
        guard length >= 16 else { return nil }
        let exitCode = Int32(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
        let flags = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let errorLength = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        let outputLength = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        guard 16 + errorLength + outputLength == length else { return nil }
        let errorText = String(decoding: UnsafeRawBufferPointer(start: raw + 16, count: errorLength), as: UTF8.self)
        let output = String(decoding: UnsafeRawBufferPointer(start: raw + 16 + errorLength, count: outputLength), as: UTF8.self)
        return GitCommandResult(output: output, exitCode: Int(exitCode), errorText: errorText, flags: flags)
    }
}

enum GitCommandError {
    static let domain = "GitError"
    static let unavailableCode = -1001
    static let outsideWorkspaceCode = -1002

    static func isUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == domain && nsError.code == unavailableCode
    }
}

final class GitCommandRunner: @unchecked Sendable {
    static let shared = GitCommandRunner()
    static let defaultMaxOutputBytes = 32 << 20
    static let diffMaxOutputBytes = GitDiffNotice.maxDiffOutputBytes

    private static let networkOnlySubcommands: Set<String> = ["fetch", "push", "clone", "ls-remote"]
    private static let pureReadSubcommands: Set<String> = [
        "diff", "diff-files", "diff-index", "diff-tree", "show", "log", "rev-parse", "rev-list",
        "for-each-ref", "blame", "ls-files", "ls-tree", "cat-file", "merge-base", "name-rev",
        "describe", "shortlog", "grep", "check-ignore", "version", "reflog", "stripspace"
    ]

    private let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "GoLens Git Read"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "GoLens Git Write"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let networkQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "GoLens Git Network"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let idLock = NSLock()
    private var lastID: Int64 = 0

    private final class CallState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            started = true
            return true
        }

        func cancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            return started
        }
    }

    private func makeID() -> Int64 {
        idLock.lock()
        defer { idLock.unlock() }
        lastID &+= 1
        return lastID
    }

    static func subcommandAndTail(of args: [String]) -> (subcommand: String, tail: [String])? {
        var skipNext = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "-c" || arg == "-C" {
                skipNext = true
                continue
            }
            if arg.hasPrefix("-") { continue }
            return (arg, Array(args[(idx + 1)...]))
        }
        return nil
    }

    static func subcommand(of args: [String]) -> String? {
        subcommandAndTail(of: args)?.subcommand
    }

    static func isReadOnly(_ args: [String]) -> Bool {
        guard let (sub, tail) = subcommandAndTail(of: args) else { return false }
        if pureReadSubcommands.contains(sub) { return true }
        switch sub {
        case "status":
            return args.contains("--no-optional-locks")
        case "stash":
            let verb = tail.first(where: { !$0.hasPrefix("-") })
            return verb == "list" || verb == "show"
        case "config":
            return tail.contains(where: { ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains($0) })
        case "branch":
            let writeFlags: Set<String> = ["-d", "-D", "-m", "-M", "-c", "-C", "-f", "--delete", "--move", "--copy", "--force", "--set-upstream-to", "--unset-upstream"]
            if tail.contains(where: { writeFlags.contains($0) }) { return false }
            let readFlags: Set<String> = ["--list", "-l", "-r", "-a", "--remotes", "--all", "--contains", "--merged", "--no-merged", "--show-current"]
            return tail.isEmpty || tail.contains(where: { readFlags.contains($0) || $0.hasPrefix("--format=") })
        case "tag":
            let writeFlags: Set<String> = ["-d", "-a", "-s", "-u", "-f", "--delete", "--annotate", "--sign", "--force"]
            if tail.contains(where: { writeFlags.contains($0) }) { return false }
            let readFlags: Set<String> = ["-l", "--list", "-v", "--verify", "--points-at", "--contains"]
            return tail.isEmpty || tail.contains(where: { readFlags.contains($0) })
        case "remote":
            let writeVerbs: Set<String> = ["add", "remove", "rm", "rename", "set-url", "set-head", "set-branches", "prune", "update"]
            let verb = tail.first(where: { !$0.hasPrefix("-") })
            return verb == nil || verb == "get-url" || (!writeVerbs.contains(verb!) && tail.contains("-v"))
        case "worktree":
            return tail.first(where: { !$0.hasPrefix("-") }) == "list"
        default:
            return false
        }
    }

    static func isTransientLockContention(_ result: GitCommandResult) -> Bool {
        guard result.exitCode != 0, !result.isCancelled, !result.isUnavailable else { return false }
        let combined = result.output + "\n" + result.errorText
        return combined.contains(".lock': File exists") ||
            (combined.contains("Unable to create '") && combined.contains(".lock'")) ||
            combined.contains("Another git process seems to be running")
    }

    private func selectQueue(for args: [String]) -> OperationQueue {
        if let sub = Self.subcommand(of: args), Self.networkOnlySubcommands.contains(sub) {
            return networkQueue
        }
        return Self.isReadOnly(args) ? readQueue : writeQueue
    }

    func run(args: [String], root: String, directory: String, input: Data? = nil, maxOutputBytes: Int = GitCommandRunner.defaultMaxOutputBytes) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let id = makeID()
        let state = CallState()
        let queue = selectQueue(for: args)
        let result: GitCommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCommandResult, Error>) in
                queue.addOperation {
                    guard state.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let tracksWrite = GitIndexWatch.shared.commandStarted(args)
                    var result = Self.invoke(id: id, args: args, root: root, directory: directory, input: input, maxOutputBytes: maxOutputBytes)
                    let retryDelaysMs = [60, 120, 220, 350]
                    for delayMs in retryDelaysMs where Self.isTransientLockContention(result) {
                        Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                        let retryID = self.makeID()
                        result = Self.invoke(id: retryID, args: args, root: root, directory: directory, input: input, maxOutputBytes: maxOutputBytes)
                    }
                    if tracksWrite {
                        GitIndexWatch.shared.writeCommandFinished()
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            if state.cancel() {
                CancelGitCommand(id)
            }
        }
        if result.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return result
    }

    private static func invoke(id: Int64, args: [String], root: String, directory: String, input: Data?, maxOutputBytes: Int) -> GitCommandResult {
        let argsJson = (try? JSONEncoder().encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var length: Int64 = 0
        let raw: UnsafeMutableRawPointer? = root.withCString { cRoot in
            directory.withCString { cDir in
                argsJson.withCString { cArgs in
                    if let input, !input.isEmpty {
                        return input.withUnsafeBytes { buffer in
                            RunGitCommandEx(id, cRoot, cDir, cArgs, buffer.bindMemory(to: CChar.self).baseAddress, Int32(input.count), Int64(maxOutputBytes), &length)
                        }
                    }
                    return RunGitCommandEx(id, cRoot, cDir, cArgs, nil, 0, Int64(maxOutputBytes), &length)
                }
            }
        }
        guard let raw else {
            return GitCommandResult(output: "", exitCode: -1, errorText: "Git returned no result.", flags: 0)
        }
        defer { FreeGoBuffer(raw) }
        return GitCommandResult.decode(UnsafeRawPointer(raw), length: Int(length))
            ?? GitCommandResult(output: "", exitCode: -1, errorText: "Git returned an unreadable result.", flags: 0)
    }

    func runSignedCommit(root: String, directory: String, keyPath: String, message: String, amend: Bool) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let id = makeID()
        let state = CallState()
        let result: GitCommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCommandResult, Error>) in
                writeQueue.addOperation {
                    guard state.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let tracksWrite = GitIndexWatch.shared.commandStarted(["commit"])
                    let result = Self.invokeSignedCommit(id: id, root: root, directory: directory, keyPath: keyPath, message: message, amend: amend)
                    if tracksWrite {
                        GitIndexWatch.shared.writeCommandFinished()
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            if state.cancel() {
                CancelGitCommand(id)
            }
        }
        if result.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return result
    }

    func runSignedTag(root: String, directory: String, keyPath: String, tagName: String, revision: String, message: String) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let id = makeID()
        let state = CallState()
        let result: GitCommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCommandResult, Error>) in
                writeQueue.addOperation {
                    guard state.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let tracksWrite = GitIndexWatch.shared.commandStarted(["tag", "-s"])
                    let result = Self.invokeSignedTag(id: id, root: root, directory: directory, keyPath: keyPath, tagName: tagName, revision: revision, message: message)
                    if tracksWrite {
                        GitIndexWatch.shared.writeCommandFinished()
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            if state.cancel() {
                CancelGitCommand(id)
            }
        }
        if result.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return result
    }

    private static func invokeSignedCommit(id: Int64, root: String, directory: String, keyPath: String, message: String, amend: Bool) -> GitCommandResult {
        var length: Int64 = 0
        let raw: UnsafeMutableRawPointer? = root.withCString { cRoot in
            directory.withCString { cDir in
                keyPath.withCString { cKey in
                    message.withCString { cMsg in
                        RunSignedGitCommitEx(id, cRoot, cDir, cKey, cMsg, amend ? 1 : 0, &length)
                    }
                }
            }
        }
        guard let raw else {
            return GitCommandResult(output: "", exitCode: -1, errorText: "Git returned no result.", flags: 0)
        }
        defer { FreeGoBuffer(raw) }
        return GitCommandResult.decode(UnsafeRawPointer(raw), length: Int(length))
            ?? GitCommandResult(output: "", exitCode: -1, errorText: "Git returned an unreadable result.", flags: 0)
    }

    private static func invokeSignedTag(id: Int64, root: String, directory: String, keyPath: String, tagName: String, revision: String, message: String) -> GitCommandResult {
        var length: Int64 = 0
        let raw: UnsafeMutableRawPointer? = root.withCString { cRoot in
            directory.withCString { cDir in
                keyPath.withCString { cKey in
                    tagName.withCString { cTag in
                        revision.withCString { cRev in
                            message.withCString { cMsg in
                                RunSignedGitTagEx(id, cRoot, cDir, cKey, cTag, cRev, cMsg, &length)
                            }
                        }
                    }
                }
            }
        }
        guard let raw else {
            return GitCommandResult(output: "", exitCode: -1, errorText: "Git returned no result.", flags: 0)
        }
        defer { FreeGoBuffer(raw) }
        return GitCommandResult.decode(UnsafeRawPointer(raw), length: Int(length))
            ?? GitCommandResult(output: "", exitCode: -1, errorText: "Git returned an unreadable result.", flags: 0)
    }
}
