import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotProvider
import GopilotRuntime
import GopilotStore
import GopilotTools

extension GopilotState {
    @MainActor
    func autoApplyProposalIfPermitted(_ proposalID: UUID) async -> PatchAutoApplyOutcome {
        guard let patches = session?.patches,
              let proposal = await patches.store.proposal(id: proposalID),
              proposal.status == .proposed else {
            return .notPermitted
        }
        let touchedPaths = proposal.operations.map(\.path)
        proposalPaths[proposal.id] = touchedPaths
        guard mode == .agent && agentPermissionMode.autoAppliesWorkspaceEdits else {
            return .notPermitted
        }
        let protectedPaths = touchedPaths.filter { GopilotAgentPermissionMode.isProtectedPath($0) }
        if !protectedPaths.isEmpty {
            let names = protectedPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let reason = "\(names) \(protectedPaths.count == 1 ? "is a protected file" : "are protected files"), so changes to \(protectedPaths.count == 1 ? "it" : "them") always need review."
            autoApplyNotes[proposal.id] = reason
            return .needsReview(reason)
        }
        let outcome = await patches.apply(proposalID: proposal.id, workspace: workspaceState, requireCleanBuffers: true)
        switch outcome {
        case .applied(let files, let changes):
            cardedProposals.insert(proposal.id)
            recordApplied(proposal: proposal, changes: changes)
            await revokeGrantsAfterMutation()
            items.append(.applied(id: proposal.id, text: Self.appliedText(prefix: "Auto-applied", paths: touchedPaths, files: files)))
            return .applied
        case .blocked(let reason):
            autoApplyNotes[proposal.id] = reason
            return .needsReview(reason)
        case .stale(let reason):
            cardedProposals.insert(proposal.id)
            recordProposal(proposal, status: .failed, detail: reason)
            return .stale(reason)
        case .invalid(let reason), .failed(let reason):
            autoApplyNotes[proposal.id] = reason
            if let current = await patches.store.proposal(id: proposal.id), current.status != .proposed {
                cardedProposals.insert(proposal.id)
                recordProposal(proposal, status: .failed, detail: reason)
            }
            return .failed(reason)
        }
    }

    static func appliedText(prefix: String, paths: [String], files: Int) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let target = names.isEmpty ? "\(files) file\(files == 1 ? "" : "s")" : names
        return "\(prefix) changes to \(target) in the editor. Not saved yet: the file\(files == 1 ? " is" : "s are") marked Edited. Save to keep \(files == 1 ? "it" : "them"), or undo."
    }

    @MainActor
    func revokeGrantsAfterMutation() async {
        if let workspaceID = session?.workspaceID {
            await session?.grants?.revokeOnWorkspaceMutation(workspaceID: workspaceID)
        }
    }

    @MainActor
    func refreshProposalCards() {
        guard let patches = session?.patches else { return }
        Task { @MainActor in
            for proposal in await patches.store.list() where proposal.status == .proposed && !cardedProposals.contains(proposal.id) {
                cardedProposals.insert(proposal.id)
                let touchedPaths = proposal.operations.map(\.path)
                proposalPaths[proposal.id] = touchedPaths
                var baseTexts: [String: String] = [:]
                let root = self.workspaceState.activeWorkspacePath
                for op in proposal.operations {
                    let fullPath = root + "/" + op.path
                    if let text = self.workspaceState.documents[fullPath]?.storage.string {
                        baseTexts[op.path] = text
                    } else if let disk = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        baseTexts[op.path] = disk
                    }
                }
                let warnings = PatchValidator.securityWarnings(for: proposal, baseTexts: baseTexts)
                recordProposal(proposal, status: .pendingReview, detail: autoApplyNotes[proposal.id])
                items.append(.proposal(id: proposal.id, summary: String(GopilotText.decodingEntities(proposal.rationale).prefix(160)), files: proposal.operations.count, warnings: warnings))
            }
        }
    }

    @MainActor
    private func recordApplied(proposal: PatchProposal, changes: [GopilotAppliedFileChange]) {
        let turnID = journalTurnID(for: proposal)
        for change in changes {
            upsertChange(GopilotTurnChange(
                turnID: turnID,
                proposalID: proposal.id,
                path: change.path,
                isNewFile: change.isNew,
                status: .applied,
                additions: change.additions,
                deletions: change.deletions,
                isUnsaved: true,
                detail: nil
            ))
        }
    }

    @MainActor
    private func recordProposal(_ proposal: PatchProposal, status: GopilotTurnChange.Status, detail: String?) {
        let turnID = journalTurnID(for: proposal)
        let stats = session?.patches?.proposedLineStats(proposal) ?? []
        for operation in proposal.operations {
            let stat = stats.first { $0.path == operation.path }
            upsertChange(GopilotTurnChange(
                turnID: turnID,
                proposalID: proposal.id,
                path: operation.path,
                isNewFile: stat?.isNew ?? (operation.kind == .create),
                status: status,
                additions: stat?.additions ?? 0,
                deletions: stat?.deletions ?? 0,
                isUnsaved: false,
                detail: detail
            ))
        }
    }

    @MainActor
    private func journalTurnID(for proposal: PatchProposal) -> UUID {
        if turnChanges.contains(where: { $0.turnID == proposal.turnID }) || proposal.turnID == activeTurnID {
            return proposal.turnID
        }
        return activeTurnID ?? lastAgentTurnID ?? proposal.turnID
    }

    @MainActor
    private func upsertChange(_ change: GopilotTurnChange) {
        if let index = turnChanges.firstIndex(where: { $0.id == change.id }) {
            var merged = change
            if change.status == .applied || change.status == .pendingReview {
                merged = GopilotTurnChange(
                    turnID: turnChanges[index].turnID,
                    proposalID: change.proposalID,
                    path: change.path,
                    isNewFile: change.isNewFile,
                    status: change.status,
                    additions: change.additions,
                    deletions: change.deletions,
                    isUnsaved: change.isUnsaved,
                    detail: change.detail
                )
            } else {
                merged = turnChanges[index]
                merged.status = change.status
                merged.detail = change.detail ?? merged.detail
                merged.isUnsaved = false
            }
            turnChanges[index] = merged
        } else {
            turnChanges.append(change)
        }
    }

    @MainActor
    private func setStatus(_ status: GopilotTurnChange.Status, forProposal proposalID: UUID, detail: String? = nil) {
        for index in turnChanges.indices where turnChanges[index].proposalID == proposalID {
            turnChanges[index].status = status
            turnChanges[index].isUnsaved = false
            if let detail { turnChanges[index].detail = detail }
        }
    }

    func changes(inTurn turnID: UUID) -> [GopilotTurnChange] {
        turnChanges.filter { $0.turnID == turnID }
    }

    var changedTurnIDs: [UUID] {
        var seen = Set<UUID>()
        return turnChanges.compactMap { seen.insert($0.turnID).inserted ? $0.turnID : nil }
    }

    var pendingReviewCount: Int {
        Set(turnChanges.filter { $0.status == .pendingReview }.map(\.proposalID)).count
    }

    func pendingReviewCount(inTurn turnID: UUID) -> Int {
        Set(turnChanges.filter { $0.turnID == turnID && $0.status == .pendingReview }.map(\.proposalID)).count
    }

    func unsavedChangeCount(inTurn turnID: UUID) -> Int {
        Set(turnChanges.filter { $0.turnID == turnID && $0.status == .applied && $0.isUnsaved }.map(\.path)).count
    }

    func turnID(forUserItemID itemID: UUID) -> UUID? {
        turnIDByUserItemID[itemID]
    }

    func unsavedGopilotPaths() -> Set<String> {
        Set(turnChanges.filter { $0.status == .applied && $0.isUnsaved }.map(\.path))
    }

    @MainActor
    func refreshChangeJournal() {
        guard let patches = session?.patches else { return }
        let root = workspaceState.activeWorkspacePath
        let edited = workspaceState.editedFiles
        for index in turnChanges.indices where turnChanges[index].status == .applied {
            let change = turnChanges[index]
            if patches.isStillApplied(change.proposalID) == false {
                turnChanges[index].status = .undone
                turnChanges[index].isUnsaved = false
                continue
            }
            let absolute = URL(fileURLWithPath: root + "/" + change.path).resolvingSymlinksInPath().path
            let unsaved = edited.contains(absolute) || edited.contains(root + "/" + change.path)
            if turnChanges[index].isUnsaved != unsaved {
                turnChanges[index].isUnsaved = unsaved
            }
        }
    }

    @MainActor
    func saveChanges(inTurn turnID: UUID) {
        let workspace = workspaceState
        let root = workspace.activeWorkspacePath
        let paths = Set(changes(inTurn: turnID).filter { $0.status == .applied && $0.isUnsaved }.map(\.path))
        for path in paths {
            let absolute = URL(fileURLWithPath: root + "/" + path).resolvingSymlinksInPath().path
            guard let session = workspace.documents[absolute] ?? workspace.documents[root + "/" + path] else { continue }
            workspace.save(session, reportsFailure: true) { [weak self] _ in
                self?.refreshChangeJournal()
            }
        }
    }

    @MainActor
    @discardableResult
    func undoAllChanges(inTurn turnID: UUID) async -> GopilotUndoAllResult {
        refreshChangeJournal()
        var result = GopilotUndoAllResult()
        let turnEntries = changes(inTurn: turnID)
        var orderedProposals: [UUID] = []
        for change in turnEntries where !orderedProposals.contains(change.proposalID) {
            orderedProposals.append(change.proposalID)
        }
        let workspace = workspaceState
        for proposalID in orderedProposals.reversed() {
            let entries = turnEntries.filter { $0.proposalID == proposalID }
            if entries.contains(where: { $0.status == .applied }) {
                guard let patches = session?.patches else {
                    result.failures.append("Gopilot is not connected to this project, so the change could not be undone.")
                    continue
                }
                switch await patches.undoApplied(proposalID: proposalID, workspace: workspace) {
                case .reverted(let files):
                    result.revertedFiles += files
                    setStatus(.undone, forProposal: proposalID)
                    items.removeAll { $0.id == "applied-\(proposalID.uuidString)" }
                case .collision(let diffs):
                    result.collisions.append(contentsOf: diffs.map(\.path))
                    recovery.append(contentsOf: diffs)
                case .failed(let message):
                    result.failures.append(message)
                }
            } else if entries.contains(where: { $0.status == .pendingReview }) {
                if let patches = session?.patches, await patches.store.reject(id: proposalID) {
                    result.rejectedProposals += 1
                }
                setStatus(.rejected, forProposal: proposalID)
                items.removeAll { $0.id == "proposal-\(proposalID.uuidString)" }
                if reviewing?.id == proposalID {
                    reviewing = nil
                    reviewDiffs = []
                }
            }
        }
        if result.revertedFiles > 0 {
            await revokeGrantsAfterMutation()
        }
        var parts: [String] = []
        if result.revertedFiles > 0 { parts.append("Undid changes to \(result.revertedFiles) file\(result.revertedFiles == 1 ? "" : "s") in the editor.") }
        if result.rejectedProposals > 0 { parts.append("Rejected \(result.rejectedProposals) change\(result.rejectedProposals == 1 ? "" : "s") that \(result.rejectedProposals == 1 ? "was" : "were") waiting for review.") }
        if !result.collisions.isEmpty { parts.append("\(result.collisions.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) changed after Gopilot edited \(result.collisions.count == 1 ? "it" : "them"), so \(result.collisions.count == 1 ? "it was" : "they were") left as is. Review the differences to restore them by hand.") }
        if !result.failures.isEmpty { parts.append(result.failures.joined(separator: " ")) }
        if !parts.isEmpty {
            items.append(.notice(id: UUID(), kind: result.isComplete ? .info : .warning, text: parts.joined(separator: " "), canRetry: false))
        }
        return result
    }

    @MainActor
    func review(_ id: UUID) async {
        guard let patches = session?.patches, let proposal = await patches.store.proposal(id: id) else { return }
        reviewDiffs = patches.diffs(for: proposal)
        reviewing = proposal
    }

    func workspaceFileDidChange() {
        guard let session, let workspaceID = session.workspaceID else { return }
        Task {
            await session.grants?.revokeOnWorkspaceMutation(workspaceID: workspaceID)
        }
    }

    @MainActor
    func openProposalInEditorDiff(_ id: UUID, workspace: WorkspaceState) async {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return }
        var paths = proposalPaths[id] ?? []
        if paths.isEmpty, let patches = session?.patches, let proposal = await patches.store.proposal(id: id) {
            paths = proposal.operations.map(\.path)
            proposalPaths[id] = paths
        }
        guard let firstRel = paths.first else {
            await review(id)
            return
        }
        let fullPath = root + "/" + firstRel
        if FileManager.default.fileExists(atPath: fullPath) {
            workspace.openFile(fullPath)
            workspace.clearCommitDiffContext()
            workspace.setEditorMode(.diff, for: fullPath)
        } else {
            await review(id)
        }
    }

    @MainActor
    func applyProposalDirectly(_ id: UUID, workspace: WorkspaceState, autoApplied: Bool = false) async {
        guard let patches = session?.patches, let proposal = await patches.store.proposal(id: id) else { return }
        let touchedPaths = proposal.operations.map(\.path)
        proposalPaths[proposal.id] = touchedPaths
        let outcome = await patches.apply(proposalID: proposal.id, workspace: workspace, requireCleanBuffers: autoApplied)
        if reviewing?.id == proposal.id {
            reviewing = nil
            reviewDiffs = []
        }
        switch outcome {
        case .applied(let files, let changes):
            items.removeAll { $0.id == "proposal-\(proposal.id.uuidString)" }
            recordApplied(proposal: proposal, changes: changes)
            await revokeGrantsAfterMutation()
            items.append(.applied(id: proposal.id, text: Self.appliedText(prefix: autoApplied ? "Auto-applied" : "Applied", paths: touchedPaths, files: files)))
        case .blocked(let message):
            items.append(.notice(id: UUID(), kind: .warning, text: message, canRetry: false))
        case .stale(let message), .invalid(let message), .failed(let message):
            items.removeAll { $0.id == "proposal-\(proposal.id.uuidString)" }
            setStatus(.failed, forProposal: proposal.id, detail: message)
            items.append(.notice(id: UUID(), kind: .warning, text: message, canRetry: false))
        }
    }

    @MainActor
    func applyReviewed(workspace: WorkspaceState) async {
        guard let proposal = reviewing else { return }
        await applyProposalDirectly(proposal.id, workspace: workspace, autoApplied: false)
    }

    @MainActor
    func undoApplied(_ id: UUID, workspace: WorkspaceState) async {
        guard let patches = session?.patches else { return }
        switch await patches.undoApplied(proposalID: id, workspace: workspace) {
        case .reverted(let files):
            await revokeGrantsAfterMutation()
            setStatus(.undone, forProposal: id)
            items.removeAll { $0.id == "applied-\(id.uuidString)" }
            items.append(.notice(id: UUID(), kind: .info, text: "Undid the change to \(files) file\(files == 1 ? "" : "s") in the editor.", canRetry: false))
        case .collision(let diffs):
            recovery = diffs
        case .failed(let message):
            items.append(.notice(id: UUID(), kind: .warning, text: message, canRetry: false))
        }
    }

    @MainActor
    func rejectReviewed() async {
        guard let patches = session?.patches, let proposal = reviewing else { return }
        _ = await patches.store.reject(id: proposal.id)
        setStatus(.rejected, forProposal: proposal.id)
        reviewing = nil
        reviewDiffs = []
        items.removeAll { $0.id == "proposal-\(proposal.id.uuidString)" }
        items.append(.notice(id: UUID(), kind: .info, text: "Rejected. Your project was not changed.", canRetry: false))
    }

    @MainActor
    func turnChangeSummary() -> (applied: [String], pending: [String]) {
        guard let turnID = activeTurnID else { return ([], []) }
        let entries = changes(inTurn: turnID)
        let applied = Array(Set(entries.filter { $0.status == .applied }.map(\.path))).sorted()
        let pending = Array(Set(entries.filter { $0.status == .pendingReview }.map(\.path))).sorted()
        return (applied, pending)
    }

    static func changedFilesSentence(_ changes: (applied: [String], pending: [String])) -> String {
        var parts: [String] = []
        if !changes.applied.isEmpty {
            let names = changes.applied.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            parts.append(" Gopilot already changed \(names) in this turn. The changes are in the editor and not saved; review or undo them.")
        }
        if !changes.pending.isEmpty {
            let count = changes.pending.count
            parts.append(" \(count) proposed change\(count == 1 ? " is" : "s are") waiting for your review.")
        }
        return parts.joined()
    }
}
