import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
import GopilotStore
@testable import GopilotTools

private let allNames = [
    "read_memory", "list_test_targets", "run_tests", "run_benchmark", "read_run_result",
    "list_profiles", "profile_hotspots", "profile_frame", "compare_benchmarks", "propose_patch"
]

private struct ProjectStub: ProjectInfoBackend {
    func projectSummary(includeReadme: Bool) async -> BackendOutcome<ProjectSummaryInfo> {
        .found(ProjectSummaryInfo(moduleName: "example.test", goVersion: "1.22", buildTarget: "darwin/arm64"))
    }
}

private func fullBackends(_ h: Harness) throws -> ExecutionBackends {
    _ = try h.attachMemory()
    _ = try h.attachPatch(files: ["main.go": "package main\n"])
    return h.backends
}

@Suite("Execution tool set")
struct ToolSetTests {
    @Test func waveGatingFollowsTheCatalog() async throws {
        #expect(ExecutionToolSet.enabledNames(wave: .w3).isEmpty)
        #expect(ExecutionToolSet.enabledNames(wave: .w4) == ["read_memory"])
        #expect(ExecutionToolSet.enabledNames(wave: .w5) == ["read_memory", "list_test_targets", "run_tests", "run_benchmark", "read_run_result"])
        #expect(ExecutionToolSet.enabledNames(wave: .w6).count == 9)
        #expect(ExecutionToolSet.enabledNames(wave: .w7) == allNames)
        #expect(ExecutionToolSet.catalog.map(\.name) == allNames)
        #expect(Set(ExecutionToolSet.catalog.map(\.name)).count == allNames.count)
    }

    @Test func aToolIsOfferedOnlyWhenItsBackendIsProvided() async throws {
        try await withHarness { h in
            let none = ExecutionBackends()
            #expect(ExecutionToolSet.enabledNames(wave: .w7, backends: none).isEmpty)
            #expect(!none.canRun)

            var targetsOnly = ExecutionBackends()
            targetsOnly.testTargets = h.targets
            #expect(ExecutionToolSet.enabledNames(wave: .w7, backends: targetsOnly) == ["list_test_targets"])

            var missingApprovals = h.backends
            missingApprovals.approvals = nil
            #expect(!missingApprovals.canRun)
            let names = ExecutionToolSet.enabledNames(wave: .w7, backends: missingApprovals)
            #expect(names == ["list_test_targets", "list_profiles", "profile_hotspots", "profile_frame"])

            var missingDirty = h.backends
            missingDirty.dirtyBuffers = nil
            #expect(!ExecutionToolSet.enabledNames(wave: .w7, backends: missingDirty).contains("run_tests"))
            var missingFingerprints = h.backends
            missingFingerprints.fingerprints = nil
            #expect(!ExecutionToolSet.enabledNames(wave: .w7, backends: missingFingerprints).contains("run_benchmark"))

            let withoutMemoryAndPatch = ExecutionToolSet.enabledNames(wave: .w7, backends: h.backends)
            #expect(!withoutMemoryAndPatch.contains("read_memory") && !withoutMemoryAndPatch.contains("propose_patch"))
            #expect(withoutMemoryAndPatch.contains("run_tests") && withoutMemoryAndPatch.contains("compare_benchmarks"))

            let backends = try fullBackends(h)
            #expect(ExecutionToolSet.enabledNames(wave: .w7, backends: backends) == allNames)
            let registry = try h.registry(wave: .w5, backends: backends)
            #expect(registry.schemas.map(\.name) == ["read_memory", "list_test_targets", "run_tests", "run_benchmark", "read_run_result"])
            let unknown = await registry.dispatch(ToolCall(id: "x", name: "propose_patch", argumentsJSON: "{}"))
            #expect(unknown.errorCode == .notFound)
        }
    }

    @Test func everySchemaForbidsExtraPropertiesAndDeclaresBounds() async throws {
        try await withHarness { h in
            let registry = try h.registry(backends: try fullBackends(h))
            let schemas = registry.schemas
            #expect(schemas.map(\.name) == allNames)
            for schema in schemas {
                #expect(!schema.description.isEmpty, "\(schema.name)")
                let object = try #require(JSONValue.parse(schema.parametersJSON)?.objectValue, "\(schema.name)")
                #expect(object["type"]?.stringValue == "object")
                if case .bool(false)? = object["additionalProperties"] {} else { Issue.record("\(schema.name) allows extra properties") }
                #expect(object["required"] != nil)
                #expect(object["properties"]?.objectValue != nil)
                if let properties = object["properties"]?.objectValue {
                    #expect(properties["workspaceID"] == nil && properties["workspace"] == nil && properties["sessionID"] == nil, "\(schema.name) exposes workspace identity")
                }
            }
            let required: [String: [String]] = [
                "read_memory": ["query"], "run_tests": ["targetIDs"], "run_benchmark": ["benchmarkIDs"], "read_run_result": ["runID"],
                "profile_hotspots": ["profileID"], "profile_frame": ["profileID", "frameID"],
                "compare_benchmarks": ["baselineRunID", "candidateRunID"], "propose_patch": ["baseSnapshotID", "rationale"]
            ]
            for (name, expected) in required {
                let schema = try #require(schemas.first { $0.name == name })
                let list = JSONValue.parse(schema.parametersJSON)?["required"]?.stringArray
                #expect(Set(list ?? []) == Set(expected), "\(name)")
            }
        }
    }

    @Test func everyToolRejectsInvalidArgumentsThroughTheValidator() async throws {
        try await withHarness { h in
            let registry = try h.registry(backends: try fullBackends(h))
            let longQuery = String(repeating: "q", count: 257)
            let longRationale = String(repeating: "r", count: 2001)
            let cases: [(String, String)] = [
                ("read_memory", "{}"),
                ("read_memory", #"{"query":"x","limit":11}"#),
                ("read_memory", #"{"query":"x","limit":0}"#),
                ("read_memory", #"{"query":"x","unexpected":true}"#),
                ("read_memory", "{\"query\":\"\(longQuery)\"}"),
                ("list_test_targets", #"{"limit":201}"#),
                ("list_test_targets", #"{"packageScope":""}"#),
                ("list_test_targets", #"{"packageScope":3}"#),
                ("run_tests", "{}"),
                ("run_tests", #"{"targetIDs":[]}"#),
                ("run_tests", #"{"targetIDs":["./pkg#TestAlpha"],"timeoutSeconds":601}"#),
                ("run_tests", #"{"targetIDs":["./pkg#TestAlpha"],"timeoutSeconds":0}"#),
                ("run_tests", #"{"targetIDs":["./pkg#TestAlpha"],"command":"rm -rf /"}"#),
                ("run_tests", #"{"targetIDs":[1]}"#),
                ("run_benchmark", "{}"),
                ("run_benchmark", #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":101}"#),
                ("run_benchmark", #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"count":0}"#),
                ("run_benchmark", #"{"benchmarkIDs":["./pkg#BenchmarkEncode"],"flags":"-race"}"#),
                ("read_run_result", "{}"),
                ("read_run_result", #"{"runID":"x","cursor":""}"#),
                ("list_profiles", #"{"limit":21}"#),
                ("profile_hotspots", #"{"profileID":"P","limit":51}"#),
                ("profile_hotspots", #"{"profileID":"P","metric":"total"}"#),
                ("profile_hotspots", #"{"limit":5}"#),
                ("profile_frame", #"{"profileID":"P"}"#),
                ("compare_benchmarks", #"{"baselineRunID":"a"}"#),
                ("propose_patch", #"{"baseSnapshotID":"S1"}"#),
                ("propose_patch", "{\"baseSnapshotID\":\"S1\",\"rationale\":\"\(longRationale)\"}"),
                ("propose_patch", #"{"baseSnapshotID":"S1","rationale":"r","edits":[{"path":"a.go","baseHash":"h"}]}"#),
                ("propose_patch", #"{"baseSnapshotID":"S1","rationale":"r","edits":[{"path":"a.go","baseHash":"h","replacements":[{"oldText":"a","newText":"b"}],"mode":"x"}]}"#),
                ("propose_patch", #"{"baseSnapshotID":"S1","rationale":"r","creates":[{"path":"a.go"}]}"#),
                ("propose_patch", #"{"baseSnapshotID":"S1","rationale":"r","verificationPlan":["1","2","3","4","5","6","7","8","9","10","11"]}"#)
            ]
            for (name, json) in cases {
                let result = await registry.dispatch(ToolCall(id: "bad", name: name, argumentsJSON: json))
                #expect(result.status == .error, "\(name) \(json.prefix(80))")
                #expect(result.errorCode == .invalidArguments, "\(name) \(json.prefix(80))")
                #expect(result.data.contains("Invalid arguments for \(name)"), "\(name)")
            }
            #expect(h.fakeGo.calls == 0)
            #expect(h.approvals.requestCount == 0)
        }
    }

    @Test func oversizedArgumentsAreRefusedExceptForPatchProposals() async throws {
        try await withHarness { h in
            let registry = try h.registry(backends: try fullBackends(h))
            let padding = String(repeating: "a", count: 70_000)
            let run = await registry.dispatch(ToolCall(id: "big", name: "read_memory", argumentsJSON: "{\"query\":\"\(padding)\"}"))
            #expect(run.errorCode == .tooLarge)
            let patchTool = await registry.dispatch(ToolCall(id: "p", name: "propose_patch", argumentsJSON: "{\"baseSnapshotID\":\"S1\",\"rationale\":\"r\",\"creates\":[{\"path\":\"a.go\",\"content\":\"\(padding)\"}]}"))
            #expect(patchTool.errorCode != .tooLarge)
        }
    }

    @Test func nonObjectArgumentsAreRefusedByTheRegistry() async throws {
        try await withHarness { h in
            let registry = try h.registry()
            let result = await registry.dispatch(ToolCall(id: "x", name: "run_tests", argumentsJSON: "[1,2]"))
            #expect(result.errorCode == .invalidArguments)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func combinedRegistryMergesReadAndExecutionTools() async throws {
        try await withHarness { h in
            let backends = try fullBackends(h)
            let executionContext = h.makeContext(backends: backends)
            let box = h.snapshot
            let policy = PathPolicy(workspaceRoots: [h.root], approvedDependencyRoots: [], userExcludePatterns: [])
            let readContext = ReadToolContext(workspaceID: h.workspaceID, snapshot: { box.snapshot }, pathPolicy: policy, evidence: h.evidence, backends: ReadBackends(project: ProjectStub()))
            let combined = try ExecutionToolSet.combinedRegistry(readContext: readContext, executionContext: executionContext, wave: .w7)
            let names = combined.schemas.map(\.name)
            #expect(names == ["project_summary"] + allNames)
            #expect(Set(names).count == names.count)

            let summary = await combined.dispatch(ToolCall(id: "s", name: "project_summary", argumentsJSON: "{}"))
            #expect(summary.status == .ok)
            let targets = await combined.dispatch(ToolCall(id: "t", name: "list_test_targets", argumentsJSON: "{}"))
            #expect(targets.status == .ok)
            #expect(Set(summary.evidenceIDs).isDisjoint(with: targets.evidenceIDs))

            let early = try ExecutionToolSet.combinedRegistry(readContext: readContext, executionContext: executionContext, wave: .w4)
            #expect(early.schemas.map(\.name) == ["project_summary", "read_memory"])
        }
    }

    @Test func evidenceKindsForExecutionResultsExist() throws {
        let kinds: [EvidenceKind] = [.run, .benchmark, .profile, .patch, .memory]
        #expect(kinds.map(\.rawValue) == ["run", "benchmark", "profile", "patch", "memory"])
        for kind in kinds {
            let data = try JSONEncoder().encode([kind])
            #expect(try JSONDecoder().decode([EvidenceKind].self, from: data) == [kind])
        }
    }

    @Test func successfulCallsAlwaysReturnEvidenceIDs() async throws {
        try await withHarness { h in
            let backends = try fullBackends(h)
            h.profileSource.attach("p", payload: try makePayload(hash: "ev", entries: simpleEntries()))
            let registry = try h.registry(backends: backends)
            let store = try #require(backends.memory)
            _ = try await store.pin(content: "evidence note", provenance: MemoryProvenance(sourceConversationID: nil))
            let id = ProfileRecord.deriveID(contentSHA256: "ev", kind: .cpu, sampleType: "cpu")
            let calls: [(String, String)] = [
                ("read_memory", #"{"query":"evidence"}"#),
                ("list_test_targets", "{}"),
                ("run_tests", #"{"targetIDs":["./pkg#TestAlpha"]}"#),
                ("list_profiles", "{}"),
                ("profile_hotspots", "{\"profileID\":\"\(id)\"}"),
                ("propose_patch", #"{"baseSnapshotID":"S1","rationale":"r","creates":[{"path":"new.go","content":"package main\n"}]}"#)
            ]
            for (name, json) in calls {
                let result = await registry.dispatch(ToolCall(id: "ev-\(name)", name: name, argumentsJSON: json))
                #expect(result.status == .ok, "\(name): \(result.data.prefix(200))")
                #expect(!result.evidenceIDs.isEmpty, "\(name)")
                #expect(result.data.utf8.count <= 8 * 1024, "\(name)")
                for evidenceID in result.evidenceIDs {
                    #expect(await h.evidence.resolve(id: evidenceID, workspaceID: h.workspaceID) != nil, "\(name) \(evidenceID)")
                }
            }
        }
    }
}
