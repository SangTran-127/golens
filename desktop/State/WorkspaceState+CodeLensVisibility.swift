import AppKit

final class CodeLensProgress {
    weak var session: DocumentSession?
    let version: Int
    private(set) var declsVersion: Int
    private(set) var decls: [WorkspaceState.GoDeclaration]
    private(set) var keys: [String]
    let authorsByKey: [String: String]
    var fetched: Set<String> = []
    var unplaced: [String: CodeLensInfo] = [:]
    var isRunning = false
    var runToken = 0
    var task: Task<Void, Never>?
    var failedRounds = 0
    var retryNotBefore: Date?

    init(session: DocumentSession, version: Int, decls: [WorkspaceState.GoDeclaration], authorsByLine: [Int: String]) {
        self.session = session
        self.version = version
        self.declsVersion = version
        self.decls = decls
        let keys = Self.keys(for: decls)
        self.keys = keys
        var authors: [String: String] = [:]
        for (decl, key) in zip(decls, keys) {
            if let author = authorsByLine[decl.line] { authors[key] = author }
        }
        self.authorsByKey = authors
    }

    static func keys(for decls: [WorkspaceState.GoDeclaration]) -> [String] {
        var seen: [String: Int] = [:]
        return decls.map { decl in
            let base = decl.kind + "|" + decl.symbolName
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return base + "|" + String(n)
        }
    }

    func install(decls: [WorkspaceState.GoDeclaration], version: Int) {
        self.decls = decls
        self.keys = Self.keys(for: decls)
        self.declsVersion = version
    }

    var isComplete: Bool {
        keys.allSatisfy { fetched.contains($0) }
    }

    func retainedLenses(from old: [Int: CodeLensInfo]) -> [Int: CodeLensInfo] {
        var result: [Int: CodeLensInfo] = [:]
        for (decl, key) in zip(decls, keys) {
            guard let previous = old[decl.line] else { continue }
            var info = CodeLensInfo(usages: previous.usages, author: authorsByKey[key])
            info.implementations = previous.implementations
            info.implementsDirection = previous.implementsDirection
            result[decl.line] = info
        }
        return result
    }
}

extension WorkspaceState {
    static let codeLensVisibleMargin = 40
    static let codeLensResumeDelay: TimeInterval = 1.5
    static let codeLensMaxRetryRounds = 5

    private enum CodeLensStep {
        case finished
        case reparse(text: String, version: Int)
        case fetch(batch: [(key: String, decl: GoDeclaration, author: String?)], version: Int)
    }

    func observeCodeLensScrolling() {
        if let token = codeLensScrollObserver {
            NotificationCenter.default.removeObserver(token)
            codeLensScrollObserver = nil
        }
        codeLensScrollWorkItem?.cancel()
        guard let clip = activeTextView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        codeLensScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.scheduleVisibleCodeLensFetch()
        }
        scheduleVisibleCodeLensFetch()
    }

    func scheduleVisibleCodeLensFetch() {
        codeLensScrollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let textView = self.activeTextView as? GoLensTextView, !textView.filePath.isEmpty else { return }
            self.fetchVisibleCodeLenses(forPath: textView.filePath)
        }
        codeLensScrollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func fetchVisibleCodeLenses(forPath path: String) {
        guard let progress = codeLensProgress[path], let session = progress.session,
              documents[path] === session, !progress.isRunning else { return }
        if let notBefore = progress.retryNotBefore, Date() < notBefore { return }
        if progress.declsVersion == session.version {
            if progress.isComplete { return }
            switch codeLensVisibleLines(forPath: path) {
            case .none:
                return
            case .some(.some(let lines)):
                let hasMissing = zip(progress.decls, progress.keys).contains { decl, key in
                    lines.contains(decl.line) && !progress.fetched.contains(key)
                }
                if !hasMissing { return }
            case .some(.none):
                break
            }
        }
        let token = nextCodeLensRunToken()
        progress.runToken = token
        progress.isRunning = true
        progress.task = Task { [weak self] in
            await self?.runCodeLensFetchLoop(forPath: path, token: token)
        }
    }

    func codeLensVisibleLines(forPath path: String) -> ClosedRange<Int>?? {
        guard let textView = activeTextView as? GoLensTextView, textView.filePath == path,
              let session = textView.document, documents[path] === session else { return nil }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              layoutManager.textStorage === session.storage else { return nil }
        let visible = textView.visibleRect
        guard visible.height > 0 else { return .some(nil) }
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = session.storage.length
        let first = session.lineAndColumn(at: min(chars.location, length)).line + 1
        let last = session.lineAndColumn(at: min(NSMaxRange(chars), length)).line + 1
        return max(1, first - Self.codeLensVisibleMargin)...(last + Self.codeLensVisibleMargin)
    }

    func runCodeLensFetchLoop(forPath path: String, token: Int) async {
        while true {
            let step: CodeLensStep = await MainActor.run { self.nextCodeLensStep(forPath: path, token: token) }
            switch step {
            case .finished:
                return
            case .reparse(let text, let version):
                let decls = Array(findGoDeclarations(in: text).prefix(Self.maxCodeLensPerFile))
                let installed: Bool? = await MainActor.run {
                    guard let progress = self.currentCodeLensProgress(path, token: token) else { return nil }
                    guard !Task.isCancelled else {
                        progress.isRunning = false
                        return nil
                    }
                    guard progress.session?.version == version else { return false }
                    progress.install(decls: decls, version: version)
                    self.placeUnplacedCodeLenses(progress, path: path)
                    return true
                }
                guard let installed else { return }
                if !installed {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            case .fetch(let batch, let version):
                let started = CFAbsoluteTimeGetCurrent()
                var results: [(key: String, line: Int, info: CodeLensInfo)] = []
                var deferred = 0
                var yielded = 0
                let reply = Self.usageCountsEnabled ? Self.usageIndexReply(forPath: path) : nil
                let source = UsageCountSource(indexState: reply?.state)
                let indexCounts = source.answersFromIndex ? Self.indexCountsByPosition(reply) : nil
                if let indexCounts {
                    await showIndexedUsages(batch, counts: indexCounts, keepUnlisted: source == .refreshingIndex, path: path, version: version, token: token)
                }
                if source.retriesLater {
                    yielded = batch.count
                } else {
                    await withTaskGroup(of: (String, Int, Result<CodeLensInfo, LSPRequestFailure>).self) { group in
                        var pending = batch[...]
                        func addNext() {
                            guard let item = pending.popFirst() else { return }
                            group.addTask { (item.key, item.decl.line, await Self.codeLens(for: item.decl, inPath: path, author: item.author, indexCounts: indexCounts)) }
                        }
                        for _ in 0..<Self.codeLensConcurrency { addNext() }
                        for await (key, line, outcome) in group {
                            switch outcome {
                            case .success(let info): results.append((key, line, info))
                            case .failure(.preempted): yielded += 1
                            case .failure: deferred += 1
                            }
                            if Task.isCancelled { group.cancelAll(); return }
                            if deferred > 0 || yielded > 0 { continue }
                            addNext()
                        }
                    }
                }
                measureLog("code-lens \(results.count)/\(batch.count) decls \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000)) ms usages=\(source)")
                let fetchedResults = results
                let deferredCount = deferred
                let yieldedCount = yielded
                let merged: Bool = await MainActor.run {
                    guard let progress = self.currentCodeLensProgress(path, token: token) else { return false }
                    guard let session = progress.session, self.documents[path] === session else {
                        progress.isRunning = false
                        return false
                    }
                    if session.version != version {
                        for result in fetchedResults { progress.unplaced[result.key] = result.info }
                    } else if !fetchedResults.isEmpty {
                        var lenses = self.codeLensCache[path] ?? [:]
                        for result in fetchedResults {
                            progress.fetched.insert(result.key)
                            lenses[result.line] = result.info
                        }
                        self.codeLensCache[path] = lenses
                        if let textView = self.activeTextView as? GoLensTextView, textView.filePath == path {
                            textView.needsDisplay = true
                        }
                    }
                    if Task.isCancelled {
                        progress.isRunning = false
                        return false
                    }
                    if deferredCount > 0 {
                        progress.isRunning = false
                        progress.failedRounds += 1
                        let delay = LSPTimeoutPolicy.codeLensRetryDelay(afterFailedRounds: progress.failedRounds, resumeDelay: Self.codeLensResumeDelay, maxRounds: Self.codeLensMaxRetryRounds)
                        progress.retryNotBefore = Date().addingTimeInterval(delay)
                        if progress.failedRounds <= Self.codeLensMaxRetryRounds {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                self?.scheduleVisibleCodeLensFetch()
                            }
                        }
                        return false
                    }
                    if yieldedCount > 0 {
                        progress.isRunning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.codeLensResumeDelay) { [weak self] in
                            self?.scheduleVisibleCodeLensFetch()
                        }
                        return false
                    }
                    progress.failedRounds = 0
                    progress.retryNotBefore = nil
                    return true
                }
                if !merged { return }
            }
        }
    }

    struct UsageIndexReply: Decodable {
        struct Location: Decodable {
            let file: String
            let line: Int
            let col: Int
            let endCol: Int

            var lspLocation: LSPLocation {
                let start = LSPPosition(line: line - 1, character: col - 1)
                let end = LSPPosition(line: line - 1, character: endCol - 1)
                return LSPLocation(uri: lspURI(forPath: file), range: LSPRange(start: start, end: end))
            }
        }

        struct Count: Decodable {
            let line: Int
            let col: Int
            let count: Int
            let impls: [Location]?
        }
        let state: String
        let reason: String?
        let counts: [Count]?
    }

    static func usageIndexReply(forPath path: String) -> UsageIndexReply? {
        let json: String? = path.withCString { p in
            guard let c = UsageCounts(p) else { return nil }
            defer { FreeGoCString(c) }
            return String(cString: c)
        }
        guard let json else { return nil }
        return try? JSONDecoder().decode(UsageIndexReply.self, from: Data(json.utf8))
    }

    static func indexCountsByPosition(_ reply: UsageIndexReply?) -> [String: UsageIndexReply.Count] {
        var byPosition: [String: UsageIndexReply.Count] = [:]
        for count in reply?.counts ?? [] {
            byPosition["\(count.line):\(count.col)"] = count
        }
        return byPosition
    }

    static func indexedLens(for decl: GoDeclaration, inPath path: String, entry: UsageIndexReply.Count?, author: String?) -> CodeLensInfo {
        let usages = isGoEntryPoint(decl.symbolName, inPath: path) ? nil : entry?.count
        var info = CodeLensInfo(usages: usages, author: author)
        let impls = entry?.impls ?? []
        if decl.kind != "func" && !impls.isEmpty {
            info.implementations = impls.prefix(100).map { $0.lspLocation }
            info.implementsDirection = decl.isInterface ? .implementedBy : .implements
        }
        return info
    }

    private func showIndexedUsages(_ batch: [(key: String, decl: GoDeclaration, author: String?)], counts: [String: UsageIndexReply.Count], keepUnlisted: Bool, path: String, version: Int, token: Int) async {
        await MainActor.run {
            guard let progress = self.currentCodeLensProgress(path, token: token), let session = progress.session,
                  self.documents[path] === session, session.version == version else { return }
            var lenses = self.codeLensCache[path] ?? [:]
            for item in batch {
                let entry = counts["\(item.decl.line):\(item.decl.col)"]
                if entry == nil && keepUnlisted { continue }
                var info = Self.indexedLens(for: item.decl, inPath: path, entry: entry, author: item.author)
                if entry == nil, let previous = lenses[item.decl.line] {
                    info.implementations = previous.implementations
                    info.implementsDirection = previous.implementsDirection
                }
                lenses[item.decl.line] = info
            }
            self.codeLensCache[path] = lenses
            if let textView = self.activeTextView as? GoLensTextView, textView.filePath == path {
                textView.needsDisplay = true
            }
        }
    }

    private func placeUnplacedCodeLenses(_ progress: CodeLensProgress, path: String) {
        guard !progress.unplaced.isEmpty else { return }
        var lenses = codeLensCache[path] ?? [:]
        for (decl, key) in zip(progress.decls, progress.keys) {
            guard let info = progress.unplaced[key] else { continue }
            lenses[decl.line] = info
            progress.fetched.insert(key)
        }
        progress.unplaced.removeAll()
        codeLensCache[path] = lenses
        if let textView = activeTextView as? GoLensTextView, textView.filePath == path {
            textView.needsDisplay = true
        }
    }

    func nextCodeLensRunToken() -> Int {
        transientEditorState.lastRunToken &+= 1
        return transientEditorState.lastRunToken
    }

    private func currentCodeLensProgress(_ path: String, token: Int) -> CodeLensProgress? {
        guard let progress = codeLensProgress[path], progress.runToken == token else { return nil }
        return progress
    }

    private func nextCodeLensStep(forPath path: String, token: Int) -> CodeLensStep {
        guard let progress = currentCodeLensProgress(path, token: token) else { return .finished }
        guard !Task.isCancelled, let session = progress.session, documents[path] === session,
              let visibleLines = codeLensVisibleLines(forPath: path) else {
            progress.isRunning = false
            return .finished
        }
        if progress.declsVersion != session.version {
            return .reparse(text: session.storage.string, version: session.version)
        }
        var batch: [(key: String, decl: GoDeclaration, author: String?)] = []
        for (decl, key) in zip(progress.decls, progress.keys) where !progress.fetched.contains(key) {
            if let lines = visibleLines, !lines.contains(decl.line) { continue }
            batch.append((key, decl, progress.authorsByKey[key]))
        }
        guard !batch.isEmpty else {
            progress.isRunning = false
            return .finished
        }
        return .fetch(batch: batch, version: session.version)
    }
}
