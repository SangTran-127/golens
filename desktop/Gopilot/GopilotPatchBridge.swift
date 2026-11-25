import AppKit
import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotTools

struct GopilotFileDiff: Identifiable {
    let id = UUID()
    let path: String
    let isNew: Bool
    let lines: [DiffLine]
    let truncated: Bool
}

struct GopilotAppliedFileChange: Equatable {
    let path: String
    let isNew: Bool
    let additions: Int
    let deletions: Int
}

enum GopilotApplyOutcome {
    case applied(files: Int, changes: [GopilotAppliedFileChange])
    case stale(String)
    case invalid(String)
    case blocked(String)
    case failed(String)
}

enum GopilotUndoOutcome {
    case reverted(files: Int)
    case collision([RecoveryDiff])
    case failed(String)
}

final class GopilotPatchCoordinator: @unchecked Sendable {
    let store: PatchProposalStore
    private let access: GopilotWorkspaceAccess
    private let journalDirectory: URL
    @MainActor private var journal = ApplyJournal()
    @MainActor private var plans: [UUID: ApplyPlan] = [:]
    @MainActor private var goplsPublishCounts: [String: Int] = [:]
    @MainActor private var goplsPublishBaseline: [String: Int] = [:]
    private var goplsPublishObserver: NSObjectProtocol?

    init(access: GopilotWorkspaceAccess, pathPolicy: PathPolicy, filter: SecretFilter, journalDirectory: URL) {
        self.access = access
        self.journalDirectory = journalDirectory
        let root = access.root
        let validation = PatchValidationContext(
            pathCheck: { path in
                switch pathPolicy.evaluate(relativePath: path, mustExist: false) {
                case .allowed: return .ok
                case .denied(let reason):
                    switch reason {
                    case .outsideAllowedRoots: return .symlinkEscape
                    case .traversal, .absolutePath: return .escapesWorkspace
                    default: return .denied("The path is not allowed.")
                    }
                }
            },
            secretCheck: { filter.redact($0).didRedact },
            pathExists: { FileManager.default.fileExists(atPath: root + "/" + $0) }
        )
        store = PatchProposalStore(validation: validation)
        goplsPublishObserver = NotificationCenter.default.addObserver(forName: .golensGoplsDiagnosticsPublished, object: nil, queue: .main) { [weak self] note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated {
                self?.goplsPublishCounts[path, default: 0] += 1
            }
        }
    }

    func currentFile(_ relativePath: String) -> CurrentFileState {
        let absolute = access.root + "/" + relativePath
        let buffer: (text: String, version: Int)? = Thread.isMainThread
            ? MainActor.assumeIsolated { access.bufferText(at: absolute) }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { access.bufferText(at: absolute) } }
        if let buffer { return CurrentFileState(exists: true, text: buffer.text, documentVersion: buffer.version) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolute)), let text = String(data: data, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: absolute) ? CurrentFileState(exists: true, text: nil) : .missing
        }
        return CurrentFileState(exists: true, text: text)
    }

    func diffs(for proposal: PatchProposal) -> [GopilotFileDiff] {
        proposal.operations.compactMap { operation in
            switch operation.kind {
            case .create:
                let result = LineDiff.diff(from: "", to: operation.content ?? "")
                return GopilotFileDiff(path: operation.path, isNew: true, lines: result.lines, truncated: result.truncated)
            case .edit:
                guard let before = currentFile(operation.path).text else { return nil }
                let after = Self.apply(operation.edits, to: before)
                let result = LineDiff.diff(from: before, to: after)
                return GopilotFileDiff(path: operation.path, isNew: false, lines: result.lines, truncated: result.truncated)
            default:
                return nil
            }
        }
    }

    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let storage = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.startUTF16 > $1.startUTF16 }) where edit.endUTF16 <= storage.length && edit.startUTF16 <= edit.endUTF16 {
            storage.replaceCharacters(in: NSRange(location: edit.startUTF16, length: edit.endUTF16 - edit.startUTF16), with: edit.replacement)
        }
        return storage as String
    }

    func checkProposedGoFiles(_ proposal: PatchProposal) -> [String] {
        var issues: [String] = []
        for operation in proposal.operations where operation.path.hasSuffix(".go") {
            let afterText: String
            switch operation.kind {
            case .create:
                afterText = operation.content ?? ""
            case .edit:
                let before = currentFile(operation.path).text ?? ""
                afterText = Self.apply(operation.edits, to: before)
            default:
                continue
            }
            issues.append(contentsOf: Self.goSyntaxIssues(in: afterText, displayPath: operation.path))
        }
        return issues
    }

    private struct SyntaxCheckPayload: Decodable {
        struct Issue: Decodable {
            let path: String
            let line: Int
            let column: Int
            let message: String
        }
        let issues: [Issue]
        let truncated: Bool?
    }

    static func goSyntaxIssues(in source: String, displayPath: String) -> [String] {
        var copy = source
        let json: String? = copy.withUTF8 { buffer in
            displayPath.withCString { cPath in
                buffer.withMemoryRebound(to: CChar.self) { chars in
                    guard let pointer = CheckGoSyntax(cPath, chars.baseAddress, Int32(chars.count)) else { return nil }
                    defer { FreeGoCString(pointer) }
                    return String(cString: pointer)
                }
            }
        }
        guard let json, let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SyntaxCheckPayload.self, from: data) else { return [] }
        var lines = payload.issues.map { "\($0.path):\($0.line):\($0.column): \($0.message)" }
        if payload.truncated == true {
            lines.append("\(displayPath): more syntax errors were found and not listed")
        }
        return lines
    }

    deinit {
        if let goplsPublishObserver {
            NotificationCenter.default.removeObserver(goplsPublishObserver)
        }
    }

    @MainActor
    private var diagnosticsBaseline: [String: [DiagnosticData]] = [:]

    func languageServerErrors(for proposal: PatchProposal, workspace: WorkspaceState, timeout: Duration = .milliseconds(2500)) async -> [String]? {
        let goPaths = proposal.operations.map(\.path).filter { $0.hasSuffix(".go") }
        guard !goPaths.isEmpty else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let collected: [String]? = await MainActor.run {
                var lines: [String] = []
                for path in goPaths {
                    let absolute = resolvedAbsolute(path)
                    let current = workspace.diagnostics[absolute]
                    let republished = goplsPublishCounts[absolute, default: 0] > goplsPublishBaseline[absolute, default: 0]
                    if !republished && current == diagnosticsBaseline[absolute] { return nil }
                    for diagnostic in current ?? [] where diagnostic.severity == 1 {
                        lines.append("\(path):\(diagnostic.line + 1):\(diagnostic.col + 1): \(diagnostic.message)")
                    }
                }
                return lines
            }
            if let collected {
                await MainActor.run {
                    for path in goPaths {
                        diagnosticsBaseline[resolvedAbsolute(path)] = nil
                        goplsPublishBaseline[resolvedAbsolute(path)] = nil
                    }
                }
                return collected
            }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
        }
    }

    func resolvedAbsolute(_ relativePath: String) -> String {
        URL(fileURLWithPath: access.root + "/" + relativePath).resolvingSymlinksInPath().path
    }

    @MainActor
    private func document(_ relativePath: String, in workspace: WorkspaceState) -> DocumentSession? {
        let raw = access.root + "/" + relativePath
        return workspace.documents[raw] ?? workspace.documents[resolvedAbsolute(relativePath)]
    }

    @MainActor
    private var gopilotBufferHashes: [String: String] = [:]

    @MainActor
    private func noteGopilotBuffer(_ relativePath: String, _ session: DocumentSession) {
        gopilotBufferHashes[relativePath] = ContentHash.sha256Hex(session.storage.string)
    }

    @MainActor
    func hasUnsavedChanges(_ proposal: PatchProposal, workspace: WorkspaceState) -> [String] {
        proposal.operations.map(\.path).filter { path in
            guard let session = document(path, in: workspace), session.isEdited else { return false }
            return gopilotBufferHashes[path] != ContentHash.sha256Hex(session.storage.string)
        }
    }

    static func lineStats(before: String, after: String) -> (additions: Int, deletions: Int) {
        let diff = LineDiff.diff(from: before, to: after)
        if diff.truncated {
            let beforeLines = before.isEmpty ? 0 : before.components(separatedBy: "\n").count
            let afterLines = after.isEmpty ? 0 : after.components(separatedBy: "\n").count
            return (max(0, afterLines - beforeLines), max(0, beforeLines - afterLines))
        }
        let additions = diff.lines.filter { $0.kind == .added }.count
        let deletions = diff.lines.filter { $0.kind == .removed }.count
        return (additions, deletions)
    }

    func proposedLineStats(_ proposal: PatchProposal) -> [GopilotAppliedFileChange] {
        proposal.operations.compactMap { operation in
            switch operation.kind {
            case .create:
                let stats = Self.lineStats(before: "", after: operation.content ?? "")
                return GopilotAppliedFileChange(path: operation.path, isNew: true, additions: stats.additions, deletions: stats.deletions)
            case .edit:
                let before = currentFile(operation.path).text ?? ""
                let stats = Self.lineStats(before: before, after: Self.apply(operation.edits, to: before))
                return GopilotAppliedFileChange(path: operation.path, isNew: false, additions: stats.additions, deletions: stats.deletions)
            default:
                return nil
            }
        }
    }

    @MainActor
    func apply(proposalID: UUID, workspace: WorkspaceState, requireCleanBuffers: Bool = false) async -> GopilotApplyOutcome {
        guard let proposal = await store.proposal(id: proposalID) else { return .failed("This proposal no longer exists.") }
        if requireCleanBuffers {
            let dirty = hasUnsavedChanges(proposal, workspace: workspace)
            if !dirty.isEmpty {
                let names = dirty.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                return .blocked("\(names) \(dirty.count == 1 ? "has" : "have") unsaved changes in the editor, so Gopilot did not change \(dirty.count == 1 ? "it" : "them") automatically.")
            }
        }
        let token = UserActionToken.makeFromUserAction(approvingProposalHash: proposal.contentHash)
        let provider: CurrentFileProvider = { [self] path in currentFile(path) }
        guard let result = await store.plan(id: proposalID, token: token, currentText: provider) else { return .failed("This proposal can no longer be applied.") }
        switch result.outcome {
        case .notAuthorized:
            return .failed("The approval expired. Review the changes and apply again.")
        case .invalid(let issues):
            return .invalid("The proposal has problems: \(issues.map { "\($0)" }.prefix(3).joined(separator: "; "))")
        case .stale(let files):
            let names = files.map(\.path).joined(separator: ", ")
            _ = await store.markStale(id: proposalID, reason: "Changed since the proposal: \(names)")
            return .stale("These files changed since the proposal was made: \(names). Ask Gopilot to propose the change again on the current version.")
        case .ready(let plan):
            return await execute(plan, workspace: workspace)
        }
    }

    @MainActor
    private func execute(_ plan: ApplyPlan, workspace: WorkspaceState) async -> GopilotApplyOutcome {
        do {
            _ = try journal.prepare(plan: plan)
            try journal.markApplying(plan.proposalID)
        } catch {
            return .failed("The change could not be recorded in the apply journal, so nothing was applied.")
        }
        persistJournal()
        var versions: [String: Int] = [:]
        var appliedEdits: [(PlannedFileEdit, DocumentSession)] = []
        var created: [String] = []
        var changes: [GopilotAppliedFileChange] = []

        func abort(_ message: String, stale: Bool = false) -> GopilotApplyOutcome {
            for (done, session) in appliedEdits.reversed() {
                replaceInBuffer(session, edits: done.inverseEdits)
            }
            for path in created.reversed() {
                let absolute = resolvedAbsolute(path)
                workspace.closeFile(absolute)
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: absolute), resultingItemURL: nil)
            }
            try? journal.markRolledBack(plan.proposalID)
            persistJournal()
            return stale ? .stale(message) : .failed(message)
        }

        for fileEdit in plan.fileEdits {
            guard let session = document(fileEdit.path, in: workspace) ?? workspace.openBackgroundDocument(resolvedAbsolute(fileEdit.path)) else {
                return abort("\(fileEdit.path) could not be opened in the editor. Nothing was changed.")
            }
            guard session.storage.string == fileEdit.beforeText else {
                return abort("\(fileEdit.path) changed while applying. Nothing was changed.", stale: true)
            }
            diagnosticsBaseline[session.path] = workspace.diagnostics[session.path]
            goplsPublishBaseline[session.path] = goplsPublishCounts[session.path, default: 0]
            replaceInBuffer(session, edits: fileEdit.edits)
            noteGopilotBuffer(fileEdit.path, session)
            appliedEdits.append((fileEdit, session))
            versions[fileEdit.path] = session.version
            let stats = Self.lineStats(before: fileEdit.beforeText, after: fileEdit.afterText)
            changes.append(GopilotAppliedFileChange(path: fileEdit.path, isNew: false, additions: stats.additions, deletions: stats.deletions))
        }
        for creation in plan.creations {
            let absolute = resolvedAbsolute(creation.path)
            guard !FileManager.default.fileExists(atPath: absolute) else {
                return abort("\(creation.path) already exists. It was not overwritten.")
            }
            do {
                try FileManager.default.createDirectory(atPath: (absolute as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try "".write(toFile: absolute, atomically: true, encoding: .utf8)
            } catch {
                return abort("\(creation.path) could not be created: \(error.localizedDescription)")
            }
            created.append(creation.path)
            guard let session = workspace.openBackgroundDocument(absolute) else {
                return abort("\(creation.path) could not be opened in the editor. Nothing was changed.")
            }
            diagnosticsBaseline[session.path] = workspace.diagnostics[session.path]
            goplsPublishBaseline[session.path] = goplsPublishCounts[session.path, default: 0]
            replaceInBuffer(session, edits: [TextEdit(startUTF16: 0, endUTF16: session.storage.length, replacement: creation.content)])
            noteGopilotBuffer(creation.path, session)
            versions[creation.path] = session.version
            let stats = Self.lineStats(before: "", after: creation.content)
            changes.append(GopilotAppliedFileChange(path: creation.path, isNew: true, additions: stats.additions, deletions: stats.deletions))
        }
        if !created.isEmpty {
            workspace.loadFiles(from: workspace.activeWorkspacePath)
        }
        _ = await store.recordApplied(id: plan.proposalID, afterVersions: versions)
        try? journal.markApplied(plan.proposalID, afterVersions: versions)
        persistJournal()
        plans[plan.proposalID] = plan
        return .applied(files: plan.fileEdits.count + plan.creations.count, changes: changes)
    }

    @MainActor
    private func replaceInBuffer(_ session: DocumentSession, edits: [TextEdit]) {
        let undo = session.undoManager
        let storage = session.storage
        func replace(_ range: NSRange, _ text: String) {
            guard NSMaxRange(range) <= storage.length else { return }
            let old = (storage.string as NSString).substring(with: range)
            let inverse = NSRange(location: range.location, length: (text as NSString).length)
            storage.replaceCharacters(in: range, with: text)
            undo.registerUndo(withTarget: storage) { _ in replace(inverse, old) }
        }
        let groups = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.startUTF16 > $1.startUTF16 }) {
            replace(NSRange(location: edit.startUTF16, length: edit.endUTF16 - edit.startUTF16), edit.replacement)
        }
        undo.setActionName("Gopilot Change")
        undo.endUndoGrouping()
        undo.groupsByEvent = groups
    }

    @MainActor
    func journalState(for proposalID: UUID) -> ApplyJournalState? {
        journal.entry(for: proposalID)?.state
    }

    @MainActor
    func isStillApplied(_ proposalID: UUID) -> Bool? {
        guard let entry = journal.entry(for: proposalID), entry.state == .applied else { return nil }
        for file in entry.files {
            let state = currentFile(file.path)
            guard let text = state.text else { return false }
            if ContentHash.sha256Hex(text) == file.afterHash { continue }
            if let before = file.beforeHash, ContentHash.sha256Hex(text) == before { return false }
            if file.kind == .create, text.isEmpty { return false }
        }
        return true
    }

    @MainActor
    func undoApplied(proposalID: UUID, workspace: WorkspaceState) async -> GopilotUndoOutcome {
        guard let entry = journal.entry(for: proposalID) else { return .failed("There is no record of this change to undo.") }
        let provider: CurrentFileProvider = { [self] path in currentFile(path) }
        switch UndoPlanner.plan(entry: entry, current: provider) {
        case .notApplicable:
            return .failed("This change is not applied, so there is nothing to undo.")
        case .collision(let diffs):
            return .collision(diffs)
        case .revert(let plan):
            for action in plan.actions {
                let absolute = resolvedAbsolute(action.path)
                switch action.kind {
                case .revertEdits(let edits, _):
                    guard let session = document(action.path, in: workspace) ?? workspace.openBackgroundDocument(absolute) else {
                        return .failed("\(action.path) could not be opened to undo the change.")
                    }
                    replaceInBuffer(session, edits: edits)
                    noteGopilotBuffer(action.path, session)
                case .removeCreatedFile:
                    workspace.closeFile(absolute)
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: absolute), resultingItemURL: nil)
                }
            }
            if plan.actions.contains(where: { if case .removeCreatedFile = $0.kind { true } else { false } }) {
                workspace.loadFiles(from: workspace.activeWorkspacePath)
            }
            try? journal.markRolledBack(proposalID)
            persistJournal()
            _ = await store.recordRolledBack(id: proposalID)
            return .reverted(files: plan.actions.count)
        }
    }

    private var journalFile: URL { journalDirectory.appendingPathComponent("journal.json") }

    @MainActor
    private func persistJournal() {
        try? FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        if let data = try? journal.encoded() { try? data.write(to: journalFile, options: .atomic) }
    }

    @MainActor
    func loadJournalAndReportInterrupted() -> String? {
        if let data = try? Data(contentsOf: journalFile), let loaded = try? ApplyJournal.decode(data) { journal = loaded }
        let root = access.root
        let reports = journal.recover { path in
            let url = URL(fileURLWithPath: root + "/" + path)
            guard let data = try? Data(contentsOf: url) else { return FileObservationInput(exists: false, contentHash: nil) }
            return FileObservationInput(exists: true, contentHash: ContentHash.sha256Hex(data))
        }
        guard !reports.isEmpty else { return nil }
        var parts: [String] = []
        for report in reports {
            switch report.classification {
            case .notApplied:
                try? journal.markRolledBack(report.proposalID)
                parts.append("a change that was being applied when the app stopped left your files untouched")
            case .fullyApplied:
                try? journal.markRolledBack(report.proposalID)
                parts.append("a change that was being applied is present on disk in full")
            case .partiallyApplied, .diverged:
                try? journal.markRolledBack(report.proposalID)
                let files = report.perFile.filter { $0.value != .matchesBefore }.keys.sorted().joined(separator: ", ")
                parts.append("a change that was being applied left these files different from before: \(files). Review them in Source Control")
            }
        }
        persistJournal()
        return "Earlier, " + parts.joined(separator: "; ") + ". Gopilot never re-applies anything on its own."
    }

    func recoveryOriginalText(for diff: RecoveryDiff) -> String { diff.originalText ?? "" }
}
