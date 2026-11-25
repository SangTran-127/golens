import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis

public actor PatchProposalStore {
    public nonisolated let validation: PatchValidationContext
    private var proposals: [UUID: PatchProposal] = [:]
    private var order: [UUID] = []
    private var versionsAfterApply: [UUID: [String: Int]] = [:]

    public init(validation: PatchValidationContext) {
        self.validation = validation
    }

    public func add(_ proposal: PatchProposal) {
        if proposals[proposal.id] == nil { order.append(proposal.id) }
        proposals[proposal.id] = proposal
    }

    public func proposal(id: UUID) -> PatchProposal? {
        proposals[id]
    }

    public func list() -> [PatchProposal] {
        order.compactMap { proposals[$0] }
    }

    @discardableResult
    public func reject(id: UUID) -> Bool {
        guard let current = proposals[id] else { return false }
        switch current.status {
        case .proposed, .stale:
            proposals[id] = current.rejected()
            return true
        case .rejected, .applied, .rolledBack:
            return false
        }
    }

    @discardableResult
    public func markStale(id: UUID, reason: String) -> Bool {
        guard let current = proposals[id], current.status == .proposed else { return false }
        proposals[id] = current.withStatus(.stale(reason: reason))
        return true
    }

    public func plan(id: UUID, token: UserActionToken, currentText: CurrentFileProvider, now: Date = Date()) -> PlanResult? {
        guard let current = proposals[id] else { return nil }
        let result = PatchApplyPlanner.plan(proposal: current, token: token, context: validation, current: currentText, now: now)
        proposals[id] = result.proposal
        return result
    }

    @discardableResult
    public func recordApplied(id: UUID, afterVersions: [String: Int]) -> Bool {
        guard let current = proposals[id], current.status == .proposed else { return false }
        proposals[id] = current.withStatus(.applied)
        versionsAfterApply[id] = afterVersions
        return true
    }

    @discardableResult
    public func recordRolledBack(id: UUID) -> Bool {
        guard let current = proposals[id], current.status == .applied else { return false }
        proposals[id] = current.withStatus(.rolledBack)
        return true
    }

    public func appliedVersions(id: UUID) -> [String: Int]? {
        versionsAfterApply[id]
    }
}

extension ExecutionKit {
    func proposePatch() -> ExecTool {
        makeTool(
            name: "propose_patch",
            description: "Propose a code change for the user to review. Edits replace text in existing files; creates add new files (or overwrite existing files in Agent mode). At most 10 files and 200 KiB.",
            parameters: ToolSchemas.object(properties: [
                #""baseSnapshotID":{"type":"string","minLength":1,"maxLength":128}"#,
                #""rationale":{"type":"string","minLength":1,"maxLength":2000}"#,
                #""edits":{"type":"array","maxItems":10,"items":{"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":1024},"baseHash":{"type":"string","minLength":1,"maxLength":128},"documentVersion":{"type":"integer","minimum":0},"replacements":{"type":"array","minItems":1,"maxItems":50,"items":{"type":"object","properties":{"oldText":{"type":"string","minLength":0,"maxLength":20000},"newText":{"type":"string","maxLength":20000}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["path","baseHash","replacements"],"additionalProperties":false}}"#,
                #""creates":{"type":"array","maxItems":10,"items":{"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":1024},"content":{"type":"string","maxLength":204800}},"required":["path","content"],"additionalProperties":false}}"#,
                #""verificationPlan":{"type":"array","maxItems":10,"items":{"type":"string","minLength":1,"maxLength":500}}"#
            ], required: ["baseSnapshotID", "rationale"])
        ) { callID, args in
            guard let backend = context.backends.patch else {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "propose_patch has no backend in this host."])
            }
            let snapshot = await context.snapshot()
            guard args["baseSnapshotID"]?.stringValue == snapshot.id else {
                return envelope(callID: callID, outcome: "stale", code: .staleContext, retryable: true, snapshotID: snapshot.id, fields: ["message": "baseSnapshotID is not the current snapshot (\(snapshot.id)). Re-read the files and propose again."])
            }
            let editValues = args["edits"]?.arrayValue ?? []
            let createValues = args["creates"]?.arrayValue ?? []
            guard !editValues.isEmpty || !createValues.isEmpty else {
                return failure(callID: callID, code: .invalidArguments, message: "Provide at least one edit or create.")
            }

            var operations: [PatchFileOperation] = []
            var refs: [SourceRef] = []
            for value in editValues {
                switch buildEdit(value, backend: backend, callID: callID) {
                case .reply(let reply): return reply
                case .value(let operation):
                    operations.append(operation)
                    refs.append(SourceRef(workspaceID: context.workspaceID, path: operation.path, contentHash: operation.baseHash, documentVersion: operation.documentVersion))
                }
            }
            for value in createValues {
                guard let rawPath = value["path"]?.stringValue, let content = value["content"]?.stringValue else {
                    return failure(callID: callID, code: .invalidArguments, message: "Each create needs path and content.")
                }
                let path = normalizeWorkspacePath(rawPath)
                let existing = backend.currentFile(path)
                if existing.exists, let existingText = existing.text, (backend.allowCreateOverwrite || existingText.isEmpty) {
                    let baseHash = ContentHash.sha256Hex(existingText)
                    let nsExisting = existingText as NSString
                    let op = PatchFileOperation.edit(
                        path: path,
                        baseHash: baseHash,
                        documentVersion: existing.documentVersion,
                        edits: [TextEdit(startUTF16: 0, endUTF16: nsExisting.length, replacement: content)]
                    )
                    operations.append(op)
                    refs.append(SourceRef(workspaceID: context.workspaceID, path: path, contentHash: baseHash, documentVersion: existing.documentVersion))
                } else {
                    operations.append(.create(path: path, content: content))
                }
            }

            return await storeAndFormatProposal(
                callID: callID,
                toolName: "propose_patch",
                rationale: args["rationale"]?.stringValue ?? "",
                operations: operations,
                verificationPlan: args["verificationPlan"]?.stringArray ?? [],
                refs: refs,
                backend: backend,
                snapshot: snapshot
            )
        }
    }

    func writeFile() -> ExecTool {
        makeTool(
            name: "write_file",
            description: "Write the complete content of a workspace file, creating it if it does not exist or replacing all of its text if it does. Prefer edit_file for changes inside an existing file. In Auto-Edit and Auto the change is applied to the editor buffer (unsaved, undoable); in Ask First it is shown to the user for review. Content is limited to 200 KiB; for larger files write a first part and add the rest with edit_file.",
            parameters: ToolSchemas.object(properties: [
                #""path":{"type":"string","minLength":1,"maxLength":1024}"#,
                #""content":{"type":"string","maxLength":\#(ToolArgumentLimits.maxFileContentBytes)}"#,
                #""rationale":{"type":"string","minLength":1,"maxLength":2000}"#
            ], required: ["path", "content"])
        ) { callID, args in
            guard let backend = context.backends.patch else {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "write_file has no backend in this host."])
            }
            guard let rawPath = args["path"]?.stringValue, let content = args["content"]?.stringValue else {
                return failure(callID: callID, code: .invalidArguments, message: "write_file requires path and content.")
            }
            let path = normalizeWorkspacePath(rawPath)
            let rationale = args["rationale"]?.stringValue ?? "Write \(path)"
            let snapshot = await context.snapshot()
            let existing = backend.currentFile(path)
            var operations: [PatchFileOperation] = []
            var refs: [SourceRef] = []
            if existing.exists, let existingText = existing.text {
                let baseHash = ContentHash.sha256Hex(existingText)
                let nsExisting = existingText as NSString
                operations.append(.edit(
                    path: path,
                    baseHash: baseHash,
                    documentVersion: existing.documentVersion,
                    edits: [TextEdit(startUTF16: 0, endUTF16: nsExisting.length, replacement: content)]
                ))
                refs.append(SourceRef(workspaceID: context.workspaceID, path: path, contentHash: baseHash, documentVersion: existing.documentVersion))
            } else {
                operations.append(.create(path: path, content: content))
                refs.append(SourceRef(workspaceID: context.workspaceID, path: path, contentHash: ContentHash.sha256Hex(content), documentVersion: 1))
            }
            return await storeAndFormatProposal(
                callID: callID,
                toolName: "write_file",
                rationale: rationale,
                operations: operations,
                verificationPlan: [],
                refs: refs,
                backend: backend,
                snapshot: snapshot
            )
        }
    }

    func editFile() -> ExecTool {
        makeTool(
            name: "edit_file",
            description: "Replace exact text in an existing workspace file (or fill an empty file when oldText is empty). oldText must match the current file exactly once unless replaceAll is true; read the file first. In Auto-Edit and Auto the change is applied to the editor buffer (unsaved, undoable); in Ask First it is shown to the user for review.",
            parameters: ToolSchemas.object(properties: [
                #""path":{"type":"string","minLength":1,"maxLength":1024}"#,
                #""oldText":{"type":"string","maxLength":50000}"#,
                #""newText":{"type":"string","maxLength":50000}"#,
                #""replaceAll":{"type":"boolean"}"#,
                #""rationale":{"type":"string","minLength":1,"maxLength":2000}"#
            ], required: ["path", "oldText", "newText"])
        ) { callID, args in
            guard let backend = context.backends.patch else {
                return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "edit_file has no backend in this host."])
            }
            guard let rawPath = args["path"]?.stringValue,
                  let oldText = args["oldText"]?.stringValue,
                  let newText = args["newText"]?.stringValue else {
                return failure(callID: callID, code: .invalidArguments, message: "edit_file requires path, oldText, and newText.")
            }
            let path = normalizeWorkspacePath(rawPath)
            let replaceAll = args["replaceAll"]?.boolValue ?? false
            let rationale = args["rationale"]?.stringValue ?? "Edit \(path)"
            let snapshot = await context.snapshot()
            let state = backend.currentFile(path)
            if !state.exists {
                if oldText.isEmpty {
                    let op = PatchFileOperation.create(path: path, content: newText)
                    let ref = SourceRef(workspaceID: context.workspaceID, path: path, contentHash: ContentHash.sha256Hex(newText), documentVersion: 1)
                    return await storeAndFormatProposal(
                        callID: callID,
                        toolName: "edit_file",
                        rationale: rationale,
                        operations: [op],
                        verificationPlan: [],
                        refs: [ref],
                        backend: backend,
                        snapshot: snapshot
                    )
                }
                return failure(callID: callID, code: .notFound, message: "\(JSONText.clip(path, 120)) does not exist. Use write_file to create a new file.")
            }
            let text = state.text ?? ""
            let baseHash = ContentHash.sha256Hex(text)
            let nsText = text as NSString
            var edits: [TextEdit] = []
            if text.isEmpty && oldText.isEmpty {
                edits.append(TextEdit(startUTF16: 0, endUTF16: 0, replacement: newText))
            } else {
                guard !oldText.isEmpty else {
                    return failure(callID: callID, code: .invalidArguments, message: "oldText cannot be empty when \(JSONText.clip(path, 120)) is non-empty. Use write_file to overwrite the entire file.")
                }
                let matches = findMatches(in: nsText, oldText: oldText, allowMultiple: replaceAll)
                if matches.isEmpty {
                    return failure(callID: callID, code: .invalidArguments, message: "oldText \"\(JSONText.clip(oldText, 60))\" was not found in \(JSONText.clip(path, 120)). Read the file first or use write_file to overwrite the whole file.")
                }
                if !replaceAll && matches.count > 1 {
                    return failure(callID: callID, code: .invalidArguments, message: "oldText \"\(JSONText.clip(oldText, 60))\" occurs more than once in \(JSONText.clip(path, 120)); include more surrounding text or set replaceAll: true.")
                }
                for match in matches {
                    edits.append(TextEdit(startUTF16: match.location, endUTF16: match.location + match.length, replacement: newText))
                }
            }
            let op = PatchFileOperation.edit(path: path, baseHash: baseHash, documentVersion: state.documentVersion, edits: edits)
            let ref = SourceRef(workspaceID: context.workspaceID, path: path, contentHash: baseHash, documentVersion: state.documentVersion)
            return await storeAndFormatProposal(
                callID: callID,
                toolName: "edit_file",
                rationale: rationale,
                operations: [op],
                verificationPlan: [],
                refs: [ref],
                backend: backend,
                snapshot: snapshot
            )
        }
    }

    private func storeAndFormatProposal(
        callID: String,
        toolName: String,
        rationale: String,
        operations: [PatchFileOperation],
        verificationPlan: [String],
        refs: [SourceRef],
        backend: PatchBackend,
        snapshot: SourceSnapshot
    ) async -> ToolResultEnvelope {
        let proposal = PatchProposal(
            turnID: await backend.turnID(),
            rationale: rationale,
            operations: operations,
            verificationPlan: verificationPlan
        )
        let issues = PatchValidator.validate(proposal, context: backend.store.validation)
        guard issues.isEmpty else {
            let detail = issues.prefix(8).map { "\($0.path ?? "proposal"): \($0.code.rawValue) (\(JSONText.clip($0.detail, 120)))" }.joined(separator: "; ")
            return failure(callID: callID, code: .invalidArguments, message: "The proposal was not stored because it failed validation: \(detail)")
        }
        guard let expected = PatchApplyPlanner.expectedAfterHashes(for: proposal, current: backend.currentFile) else {
            return envelope(callID: callID, outcome: "stale", code: .staleContext, retryable: true, snapshotID: snapshot.id, fields: ["message": "The files no longer match what the edits were written against. Re-read them and propose again."])
        }
        let stored = proposal.withExpectedAfterHashes(expected)
        await backend.store.add(stored)
        var syntaxIssues: [String]?
        if let postProposeCheck = backend.postProposeCheck {
            syntaxIssues = await postProposeCheck(stored).map { redact(JSONText.clip($0, 240)) }
        }
        let autoOutcome = await backend.autoApplyIfPermitted?(stored.id) ?? .notPermitted
        if case .stale(let reason) = autoOutcome {
            return envelope(callID: callID, outcome: "stale", code: .staleContext, retryable: true, snapshotID: snapshot.id, fields: [
                "proposalID": stored.id.uuidString,
                "proposalStatus": "stale",
                "projectChanged": false,
                "message": "The change was not applied because the file changed after it was read: \(redact(JSONText.clip(reason, 240))) Re-read the file and make the edit again."
            ])
        }
        var lspDiagnostics: [String]?
        if autoOutcome == .applied, let postApply = backend.postApplyDiagnostics {
            lspDiagnostics = await postApply(stored)?.map { redact(JSONText.clip($0, 240)) }
        }

        let files: [[String: Any]] = stored.operations.map { operation in
            var object: [String: Any] = ["path": operation.path, "operation": operation.kind.rawValue]
            if operation.kind == .edit {
                object["replacements"] = operation.edits.count
                object["replacementBytes"] = operation.edits.reduce(0) { $0 + $1.replacement.utf8.count }
            } else {
                object["contentBytes"] = operation.content?.utf8.count ?? 0
            }
            object["expectedAfterHash"] = expected[operation.path] ?? ""
            return object
        }
        let applied = autoOutcome == .applied
        var next: String
        var fields: [String: Any] = [
            "proposalID": stored.id.uuidString,
            "proposalStatus": applied ? "applied" : "proposed",
            "projectChanged": applied,
            "files": files,
            "validation": ["passed": true, "issues": 0, "maxFiles": backend.store.validation.limits.maxFiles, "maxBytes": backend.store.validation.limits.maxBytes],
            "verificationPlan": stored.verificationPlan.map { redact($0) }
        ]
        switch autoOutcome {
        case .applied:
            fields["appliedTo"] = "editorBuffer"
            fields["savedToDisk"] = false
            next = "The change was applied to the editor buffer. The file is marked Edited and is not saved to disk yet; the user saves or undoes it. run_tests and run_go_check use the files saved on disk, so unsaved changes are only included after the user saves them."
        case .notPermitted:
            next = "The change is shown to the user for review. Nothing was applied and you cannot apply it yourself."
        case .needsReview(let reason):
            fields["autoApplyFailure"] = redact(JSONText.clip(reason, 240))
            next = "Gopilot did not apply this change automatically: \(redact(JSONText.clip(reason, 240))) It is shown to the user for review. Nothing was applied."
        case .failed(let reason):
            fields["autoApplyFailure"] = redact(JSONText.clip(reason, 240))
            next = "Applying this change failed: \(redact(JSONText.clip(reason, 240))) Nothing was applied. It is shown to the user for review."
        case .stale:
            next = ""
        }
        if let syntaxIssues {
            fields["syntaxCheck"] = syntaxIssues.isEmpty ? "passed" : "failed"
            if !syntaxIssues.isEmpty {
                fields["postEditDiagnostics"] = Array(syntaxIssues.prefix(12))
                next += " The Go parser reported \(syntaxIssues.count) syntax error(s) in the updated code (see postEditDiagnostics). Fix them before finishing."
            }
        }
        if let lspDiagnostics {
            fields["lspDiagnostics"] = Array(lspDiagnostics.prefix(12))
            if !lspDiagnostics.isEmpty {
                next += " The language server reports \(lspDiagnostics.count) error(s) in the changed files (see lspDiagnostics). Fix them before finishing."
            }
        } else if applied, stored.operations.contains(where: { $0.path.hasSuffix(".go") }), backend.postApplyDiagnostics != nil {
            fields["lspDiagnosticsNote"] = "Language server diagnostics were not ready yet. Call read_diagnostics for the changed file before finishing."
        }
        if syntaxIssues != nil || lspDiagnostics != nil {
            fields["diagnosticsPassed"] = (syntaxIssues ?? []).isEmpty && (lspDiagnostics ?? []).isEmpty
        }
        fields["next"] = next.trimmingCharacters(in: .whitespaces)
        return await self.found(callID: callID, toolName: toolName, kind: .patch, refs: refs, snapshotID: snapshot.id, fields: fields, basis: .inferred)
    }

    private func normalizeWorkspacePath(_ rawPath: String) -> String {
        var cleaned = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("@") {
            cleaned.removeFirst()
        }
        let wsRoot = context.workspaceRoot.standardizedFileURL.path
        if cleaned.hasPrefix(wsRoot + "/") {
            cleaned = String(cleaned.dropFirst(wsRoot.count + 1))
        }
        while cleaned.hasPrefix("./") {
            cleaned = String(cleaned.dropFirst(2))
        }
        while cleaned.contains("//") {
            cleaned = cleaned.replacingOccurrences(of: "//", with: "/")
        }
        return cleaned
    }

    private func findMatches(in nsText: NSString, oldText: String, allowMultiple: Bool) -> [NSRange] {
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.length > 0 {
            let found = nsText.range(of: oldText, options: .literal, range: searchRange)
            if found.location == NSNotFound { break }
            matches.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: nsText.length - next)
            if !allowMultiple && matches.count > 1 { break }
        }
        return matches
    }

    func buildEdit(_ value: JSONValue, backend: PatchBackend, callID: String) -> Step<PatchFileOperation> {
        guard let rawPath = value["path"]?.stringValue, let baseHash = value["baseHash"]?.stringValue,
              let replacements = value["replacements"]?.arrayValue else {
            return .reply(failure(callID: callID, code: .invalidArguments, message: "Each edit needs path, baseHash and replacements."))
        }
        let path = normalizeWorkspacePath(rawPath)
        let state = backend.currentFile(path)
        guard state.exists, let text = state.text else {
            return .reply(failure(callID: callID, code: .notFound, message: "\(JSONText.clip(path, 120)) does not exist. Use creates for new files."))
        }
        guard ContentHash.sha256Hex(text) == baseHash else {
            return .reply(failure(callID: callID, code: .staleContext, message: "\(JSONText.clip(path, 120)) changed since it was read (baseHash no longer matches). Read it again.", retryable: true))
        }
        let nsText = text as NSString
        var edits: [TextEdit] = []
        for replacement in replacements {
            guard let oldText = replacement["oldText"]?.stringValue, let newText = replacement["newText"]?.stringValue else {
                return .reply(failure(callID: callID, code: .invalidArguments, message: "Each replacement needs oldText and newText."))
            }
            if text.isEmpty && oldText.isEmpty {
                edits.append(TextEdit(startUTF16: 0, endUTF16: 0, replacement: newText))
                continue
            }
            guard !oldText.isEmpty else {
                return .reply(failure(callID: callID, code: .invalidArguments, message: "Each replacement needs a non-empty oldText when editing a non-empty file."))
            }
            let matches = findMatches(in: nsText, oldText: oldText, allowMultiple: false)
            guard matches.count == 1, let match = matches.first else {
                let why = matches.isEmpty ? "was not found" : "occurs more than once; include more surrounding text"
                return .reply(failure(callID: callID, code: .invalidArguments, message: "oldText \"\(JSONText.clip(oldText, 60))\" \(why) in \(JSONText.clip(path, 120))."))
            }
            edits.append(TextEdit(startUTF16: match.location, endUTF16: match.location + match.length, replacement: newText))
        }
        let version = value["documentVersion"]?.intValue ?? state.documentVersion
        return .value(.edit(path: path, baseHash: baseHash, documentVersion: version, edits: edits))
    }
}
