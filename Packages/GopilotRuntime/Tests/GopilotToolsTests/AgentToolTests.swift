import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private final class AutoApplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: PatchAutoApplyOutcome
    private var seen: [UUID] = []

    init(_ outcome: PatchAutoApplyOutcome) {
        self.outcome = outcome
    }

    func decide(_ id: UUID) -> PatchAutoApplyOutcome {
        lock.withLock {
            seen.append(id)
            return outcome
        }
    }

    var calls: Int { lock.withLock { seen.count } }
}

private func agentRegistry(_ h: Harness) throws -> ToolRegistry {
    ToolRegistry(try ExecutionToolSet.makeAgentTools(context: h.makeContext(), wave: .w7))
}

private func agentCall(_ h: Harness, _ name: String, _ json: String, id: String = "call-1") async throws -> ToolResultEnvelope {
    await (try agentRegistry(h)).dispatch(ToolCall(id: id, name: name, argumentsJSON: json))
}

private func json(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func attachAgentPatch(
    _ h: Harness,
    files: [String: String],
    autoApply: AutoApplyRecorder? = nil,
    syntax: @escaping @Sendable (PatchProposal) async -> [String] = { _ in [] },
    language: (@Sendable (PatchProposal) async -> [String]?)? = nil
) throws -> PatchProposalStore {
    let store = try h.attachPatch(files: files)
    let base = h.root
    h.backends.patch = PatchBackend(
        store: store,
        currentFile: { path in
            let url = base.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
            return CurrentFileState(exists: true, text: text, documentVersion: 1)
        },
        allowCreateOverwrite: true,
        postProposeCheck: syntax,
        autoApplyIfPermitted: autoApply.map { recorder in { id in recorder.decide(id) } },
        postApplyDiagnostics: language
    )
    return store
}

@Suite("Agent file and check tools")
struct AgentToolTests {
    @Test func writeFileCreatesAProposalForANewFileWithoutTouchingDisk() async throws {
        try await withHarness { h in
            let store = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "write_file", json(["path": "./pkg/new.go", "content": "package pkg\n", "rationale": "Add pkg"]))
            #expect(result.status == .ok, "\(result.data)")
            let data = decode(result)
            #expect(data["proposalStatus"] as? String == "proposed")
            #expect(data["projectChanged"] as? Bool == false)
            #expect((data["next"] as? String)?.contains("shown to the user for review") == true)
            #expect(data["syntaxCheck"] as? String == "passed")
            #expect(data["diagnosticsPassed"] as? Bool == true)
            let files = nestedList(data, "files")
            #expect(files.first?["path"] as? String == "pkg/new.go")
            #expect(files.first?["operation"] as? String == "create")
            #expect(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("pkg/new.go").path) == false)
            #expect(await store.list().count == 1)
        }
    }

    @Test func writeFileOverExistingFileBecomesAWholeFileEdit() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: ["main.go": "package main\n"])
            let result = try await agentCall(h, "write_file", json(["path": "main.go", "content": "package main\n\nfunc main() {}\n"]))
            let files = nestedList(decode(result), "files")
            #expect(files.first?["operation"] as? String == "edit")
        }
    }

    @Test func writeFileReportsAppliedToTheBufferAndLanguageServerErrors() async throws {
        try await withHarness { h in
            let recorder = AutoApplyRecorder(.applied)
            _ = try attachAgentPatch(h, files: [:], autoApply: recorder, language: { _ in ["pkg/new.go:3:2: undefined: missing"] })
            let result = try await agentCall(h, "write_file", json(["path": "pkg/new.go", "content": "package pkg\n\nvar _ = missing\n"]))
            let data = decode(result)
            #expect(recorder.calls == 1)
            #expect(data["proposalStatus"] as? String == "applied")
            #expect(data["appliedTo"] as? String == "editorBuffer")
            #expect(data["savedToDisk"] as? Bool == false)
            #expect((data["lspDiagnostics"] as? [String])?.first?.contains("undefined: missing") == true)
            #expect(data["diagnosticsPassed"] as? Bool == false)
            #expect((data["next"] as? String)?.contains("not saved to disk") == true)
        }
    }

    @Test func syntaxErrorsAreReportedBeforeAutoApply() async throws {
        try await withHarness { h in
            let recorder = AutoApplyRecorder(.applied)
            _ = try attachAgentPatch(h, files: [:], autoApply: recorder, syntax: { proposal in
                proposal.operations.map { "\($0.path):1:1: expected 'package', found 'func'" }
            })
            let result = try await agentCall(h, "write_file", json(["path": "x.go", "content": "func main() {}\n"]))
            let data = decode(result)
            #expect(data["syntaxCheck"] as? String == "failed")
            #expect((data["postEditDiagnostics"] as? [String])?.first == "x.go:1:1: expected 'package', found 'func'")
            #expect(data["diagnosticsPassed"] as? Bool == false)
            #expect((data["next"] as? String)?.contains("syntax error") == true)
        }
    }

    @Test func autoApplyFailureLeavesTheProposalForReviewAndSaysSo() async throws {
        try await withHarness { h in
            let recorder = AutoApplyRecorder(.needsReview("main.go has unsaved changes in the editor, so Gopilot did not change it automatically."))
            let store = try attachAgentPatch(h, files: ["main.go": "package main\n"], autoApply: recorder)
            let result = try await agentCall(h, "edit_file", json(["path": "main.go", "oldText": "package main", "newText": "package app"]))
            let data = decode(result)
            #expect(data["proposalStatus"] as? String == "proposed")
            #expect(data["projectChanged"] as? Bool == false)
            #expect((data["autoApplyFailure"] as? String)?.contains("unsaved changes") == true)
            #expect((data["next"] as? String)?.contains("shown to the user for review") == true)
            let id = try #require(UUID(uuidString: data["proposalID"] as? String ?? ""))
            #expect(await store.proposal(id: id)?.status == .proposed)
        }
    }

    @Test func staleAutoApplyIsReportedAsStale() async throws {
        try await withHarness { h in
            let recorder = AutoApplyRecorder(.stale("main.go changed."))
            _ = try attachAgentPatch(h, files: ["main.go": "package main\n"], autoApply: recorder)
            let result = try await agentCall(h, "edit_file", json(["path": "main.go", "oldText": "package main", "newText": "package app"]))
            #expect(result.errorCode == .staleContext)
            #expect(result.retryable)
            #expect(decode(result)["proposalStatus"] as? String == "stale")
        }
    }

    @Test func editFileRequiresAUniqueMatch() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: ["dup.go": "package dup\n\nvar a = 1\nvar b = 1\n"])
            let missing = try await agentCall(h, "edit_file", json(["path": "dup.go", "oldText": "var c = 1", "newText": "var c = 2"]))
            #expect(missing.errorCode == .invalidArguments)
            #expect((decode(missing)["message"] as? String)?.contains("was not found") == true)
            let ambiguous = try await agentCall(h, "edit_file", json(["path": "dup.go", "oldText": " = 1", "newText": " = 2"]))
            #expect(ambiguous.errorCode == .invalidArguments)
            #expect((decode(ambiguous)["message"] as? String)?.contains("more than once") == true)
            let all = try await agentCall(h, "edit_file", json(["path": "dup.go", "oldText": " = 1", "newText": " = 2", "replaceAll": true]))
            #expect(all.status == .ok)
            #expect(nestedList(decode(all), "files").first?["replacements"] as? Int == 2)
        }
    }

    @Test func editFileOnAMissingFileExplainsHowToCreateIt() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "edit_file", json(["path": "nope.go", "oldText": "x", "newText": "y"]))
            #expect(result.errorCode == .notFound)
            #expect((decode(result)["message"] as? String)?.contains("write_file") == true)
        }
    }

    @Test func writeFileRejectsContentOverTheLimit() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let big = String(repeating: "a", count: ToolArgumentLimits.maxFileContentBytes + 10)
            let result = try await agentCall(h, "write_file", json(["path": "big.txt", "content": big]))
            #expect(result.errorCode == .invalidArguments || result.errorCode == .tooLarge)
        }
    }

    @Test func todoWriteReturnsTheChecklistWithCounts() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let todos: [[String: String]] = [
                ["id": "1", "content": "Read handler", "status": "completed"],
                ["id": "2", "content": "Edit handler", "status": "in_progress"],
                ["id": "3", "content": "Run go build", "status": "pending"]
            ]
            let result = try await agentCall(h, "todo_write", json(["todos": todos]))
            #expect(result.status == .ok)
            let data = decode(result)
            #expect(data["outcome"] as? String == "updated")
            #expect(data["totalCount"] as? Int == 3)
            #expect(data["completedCount"] as? Int == 1)
            #expect(data["inProgressCount"] as? Int == 1)
            #expect(nestedList(data, "todos").map { $0["status"] as? String } == ["completed", "in_progress", "pending"])
            let summary = ToolEventSummary.summary(toolName: "todo_write", resultData: result.data, redact: { $0 })
            #expect(summary.contains("\"todos\""))
        }
    }

    @Test func todoWriteRejectsAnUnknownStatus() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "todo_write", json(["todos": [["id": "1", "content": "x", "status": "done"]]]))
            #expect(result.status == .error)
        }
    }

    @Test func goCheckRunsInTheNearestModuleWithBuildToDevNull() async throws {
        let root = try TestFiles.makeTempDirectory("multimodule")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("core/lsp"), withIntermediateDirectories: true)
        try "module example.test/core\n\ngo 1.22\n".write(to: root.appendingPathComponent("core/go.mod"), atomically: true, encoding: .utf8)
        try "package lsp\n".write(to: root.appendingPathComponent("core/lsp/lsp.go"), atomically: true, encoding: .utf8)
        try await withHarness(workspaceRoot: root) { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "run_go_check", json(["check": "build", "packageScope": "./core/lsp/..."]))
            #expect(result.status == .ok, "\(result.data)")
            let data = decode(result)
            #expect(data["moduleDirectory"] as? String == "core")
            #expect(data["packageScope"] as? String == "./lsp/...")
            #expect((data["cwd"] as? String)?.hasSuffix("/core") == true)
            #expect(h.fakeGo.callLines.last == "build -o /dev/null ./lsp/...")
            let card = try #require(h.approvals.cards.snapshot.last)
            #expect(card.operation == .runGoCheck)
            #expect(card.title == "Run Go check?")
            #expect(card.items == ["go build"])
            #expect(card.warning.contains("Linux container"))
        }
    }

    @Test func goCheckAtTheRootPicksTheOnlyNestedModule() async throws {
        let root = try TestFiles.makeTempDirectory("nestedmodule")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("core"), withIntermediateDirectories: true)
        try "module example.test/core\n\ngo 1.22\n".write(to: root.appendingPathComponent("core/go.mod"), atomically: true, encoding: .utf8)
        try await withHarness(workspaceRoot: root) { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "run_go_check", json(["check": "vet"]))
            let data = decode(result)
            #expect(data["moduleDirectory"] as? String == "core")
            #expect(h.fakeGo.callLines.last == "vet ./...")
        }
    }

    @Test func goCheckAcrossSeveralModulesAsksForOne() async throws {
        let root = try TestFiles.makeTempDirectory("twomodules")
        for name in ["api", "worker"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try "module example.test/\(name)\n\ngo 1.22\n".write(to: root.appendingPathComponent("\(name)/go.mod"), atomically: true, encoding: .utf8)
        }
        try await withHarness(workspaceRoot: root) { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "run_go_check", json(["check": "build"]))
            #expect(result.errorCode == .invalidArguments)
            #expect((decode(result)["message"] as? String)?.contains("./api/...") == true)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func goCheckNoLongerOffersModTidy() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let result = try await agentCall(h, "run_go_check", json(["check": "mod_tidy"]))
            #expect(result.status == .error)
            #expect(h.fakeGo.calls == 0)
            let schema = try agentRegistry(h).schemas.first { $0.name == "run_go_check" }
            #expect(schema?.parametersJSON.contains("mod_tidy") == false)
        }
    }

    @Test func goCheckReportsAnUnavailableContainerWithoutRetrying() async throws {
        try await withHarness { h in
            _ = try attachAgentPatch(h, files: [:])
            let base = h.makeContext()
            let context = ExecutionToolContext(
                workspaceID: base.workspaceID,
                workspaceRoot: base.workspaceRoot,
                snapshot: base.snapshot,
                evidence: base.evidence,
                grants: base.grants,
                arbiter: base.arbiter,
                runs: base.runs,
                profiles: base.profiles,
                environment: base.environment,
                backends: base.backends,
                sandboxReadiness: { .starting("Booting") }
            )
            let registry = ToolRegistry(try ExecutionToolSet.makeAgentTools(context: context, wave: .w7))
            let result = await registry.dispatch(ToolCall(id: "c1", name: "run_go_check", argumentsJSON: #"{"check":"build"}"#))
            #expect(result.errorCode == .unavailable)
            #expect(result.retryable == false)
            let data = decode(result)
            #expect(data["outcome"] as? String == "containerUnavailable")
            #expect(data["containerState"] as? String == "starting")
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func moduleLocatorHandlesImportPathsAndWorkspaces() throws {
        let root = try TestFiles.makeTempDirectory("locator")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("svc/internal"), withIntermediateDirectories: true)
        try "module example.test/svc\n".write(to: root.appendingPathComponent("svc/go.mod"), atomically: true, encoding: .utf8)
        #expect(GoModuleLocator.resolve(scope: "example.test/svc/internal", root: root) == .resolved(moduleDirectory: "svc", scope: "example.test/svc/internal"))
        #expect(GoModuleLocator.resolve(scope: "./svc", root: root) == .resolved(moduleDirectory: "svc", scope: "."))
        #expect(GoModuleLocator.resolve(scope: "./other", root: root) == .noModule)
        try "go 1.22\n\nuse ./svc\n".write(to: root.appendingPathComponent("go.work"), atomically: true, encoding: .utf8)
        #expect(GoModuleLocator.resolve(scope: "./svc/...", root: root) == .resolved(moduleDirectory: "", scope: "./svc/..."))
        try? FileManager.default.removeItem(at: root)
    }
}
