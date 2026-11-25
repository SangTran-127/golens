import Foundation
import CryptoKit
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private let alphaArgs = #"{"targetIDs":["./pkg#TestAlpha"]}"#

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("Run tools", .serialized)
struct RunToolTests {
    @Test func passingRunCarriesExactArgvCardAndEvidence() async throws {
        try await withHarness { h in
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.status == .ok)
            #expect(result.errorCode == nil)
            let data = decode(result)
            #expect(data["outcome"] as? String == "passed")
            #expect(data["runStatus"] as? String == "passed")
            #expect(data["exitCode"] as? Int == 0)
            let argv = try #require(data["argv"] as? [String])
            #expect(argv.first == "go")
            #expect(argv.contains("-mod=readonly"))
            #expect(argv.contains("-count=1"))
            #expect(argv.contains("^(TestAlpha)$"))
            #expect(argv.last == "./pkg")
            #expect(!argv.contains("sh") && !argv.contains("-c"))
            #expect(h.fakeGo.calls == 1)
            #expect(h.fakeGo.callLines[0].contains("test -mod=readonly"))

            let card = try #require(h.approvals.cards.snapshot.first)
            #expect(h.approvals.requestCount == 1)
            #expect(card.operation == .runTests)
            #expect(card.selector == "./pkg#TestAlpha")
            #expect(card.packageSelector == "./pkg")
            #expect(card.testNames == ["TestAlpha"])
            #expect(card.workingDirectory == h.root.path)
            #expect(card.timeoutSeconds == 120)
            #expect(card.runCount == 1)
            #expect(card.envNames == h.environment.keys.sorted())
            #expect(card.outputLimitBytes == 512 * 1024)
            #expect(card.target == h.targetHash())
            #expect(card.warning.contains("executes code from this repository"))
            #expect(card.argv == argv)
            #expect(card.executesRepositoryCode)

            #expect(result.evidenceIDs.count == 1)
            let evidence = try #require(await h.evidence.resolve(id: result.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidence.kind == .run)
            #expect(evidence.basis == .observed)
            let stored = decode(ToolResultEnvelope(callID: "x", status: .ok, data: evidence.content))
            #expect(stored["runID"] as? String == data["runID"] as? String)
            #expect(stored["exitCode"] as? Int == 0)
            #expect(stored["runStatus"] as? String == "passed")
            #expect(stored["argv"] as? [String] == argv)
            #expect(!((stored["sourceHash"] as? String) ?? "").isEmpty)
            #expect(!((stored["configHash"] as? String) ?? "").isEmpty)
            #expect(result.sourceSnapshotID == "S1")
        }
    }

    @Test func failingRunIsNeverReportedAsPassed() async throws {
        try await withHarness { h in
            h.fakeGo.setBehavior("fail")
            let result = try await h.call("run_tests", alphaArgs)
            let data = decode(result)
            #expect(data["outcome"] as? String == "failed")
            #expect(data["runStatus"] as? String == "failed")
            #expect(data["exitCode"] as? Int == 1)
            #expect(!result.data.contains("\"outcome\":\"passed\""))
            #expect(!result.data.contains("\"runStatus\":\"passed\""))
            #expect((data["outputTail"] as? String)?.contains("FAIL") == true)
        }
    }

    @Test func statusLabelRequiresExitCodeZero() async throws {
        try await withHarness { h in
            let kit = ExecutionKit(context: h.makeContext())
            let now = Date()
            func record(exit: Int32?, ended: Date?, outcome: ProcessRunResult.Outcome = .exited, signal: Int32? = nil) -> RunRecord {
                RunRecord(owner: .user, argv: ["go"], cwd: "/", sourceHash: "s", configHash: "c", startedAt: now, endedAt: ended, exitCode: exit, terminationSignal: signal, outcome: outcome)
            }
            #expect(kit.runStatusLabel(record(exit: nil, ended: now)) == "unknown")
            #expect(kit.runStatusLabel(record(exit: 0, ended: nil)) == "unknown")
            #expect(kit.runStatusLabel(record(exit: 0, ended: now)) == "passed")
            #expect(kit.runStatusLabel(record(exit: 2, ended: now)) == "failed")
            #expect(kit.runStatusLabel(record(exit: nil, ended: now, signal: 9)) == "failed")
            #expect(kit.runStatusLabel(record(exit: 0, ended: now, outcome: .cancelled)) == "cancelled")
            #expect(kit.runStatusLabel(record(exit: 0, ended: now, outcome: .timedOut)) == "timedOut")
            #expect(kit.runStatusLabel(record(exit: 0, ended: now, outcome: .abandoned)) == "unknown")
        }
    }

    @Test func userOwnedRunIsNeverStoppedAndBusyNamesTheOwner() async throws {
        try await withHarness { h in
            h.fakeGo.setBehavior("sleep")
            let command = try GoCommandBuilder.test(packages: ["./pkg"], tests: ["TestAlpha"])
            let spec = RunSpec(argv: command.argv, workspaceRoot: h.root, environment: h.environment, deadline: 60, sourceHash: "u", configHash: "u")
            guard case .started(let userRun) = await h.arbiter.start(owner: .user, spec: spec) else {
                Issue.record("user run did not start")
                return
            }
            #expect(await h.waitForCalls(1))

            let result = try await h.call("run_tests", alphaArgs, id: "ai-call")
            #expect(result.status == .error)
            #expect(result.errorCode == .busy)
            #expect(result.retryable)
            let data = decode(result)
            #expect(data["outcome"] as? String == "busy")
            #expect(data["activeOwner"] as? String == "user")
            #expect(data["activeRunID"] as? String == userRun.uuidString)
            #expect((data["message"] as? String)?.contains("was not stopped") == true)
            #expect(h.fakeGo.calls == 1)
            #expect(h.approvals.requestCount == 0)
            #expect(await h.grants.activeGrants(workspaceID: h.workspaceID).isEmpty)

            let active = try #require(await h.arbiter.activeRun())
            #expect(active.runID == userRun)
            #expect(active.owner == .user)
            #expect(await h.arbiter.cancel(runID: userRun, requester: .ai(actionID: "ai-call")) == .refusedNotOwner(active: active))
            #expect(await h.arbiter.cancelRuns(ownedBy: .ai(actionID: "ai-call")).isEmpty)
            #expect(await h.arbiter.activeRun()?.runID == userRun)
            #expect(await h.arbiter.record(for: userRun) == nil)

            let names = ExecutionToolSet.catalog.map(\.name)
            #expect(!names.contains { $0.contains("cancel") || $0.contains("stop") || $0.contains("kill") })

            #expect(await h.arbiter.cancel(runID: userRun, requester: .user) == .cancelling)
            let record = try #require(await h.arbiter.awaitRecord(userRun))
            #expect(record.owner == .user)
            #expect(record.status == .cancelled)
        }
    }

    @Test func dirtyBuffersAreNeverSavedByTheModuleAndFingerprintReflectsDisk() async throws {
        try await withHarness { h in
            h.dirty.setDirty("a.go")
            h.dirty.decision.with { $0 = .runSavedVersion }
            let original = try String(contentsOf: h.root.appendingPathComponent("a.go"), encoding: .utf8)

            let first = decode(try await h.call("run_tests", alphaArgs))
            #expect(first["outcome"] as? String == "passed")
            #expect(first["runsSavedVersion"] as? Bool == true)
            #expect(first["unsavedPathsNotIncluded"] as? [String] == ["a.go"])
            #expect((first["note"] as? String)?.contains("saved on disk") == true)
            #expect(h.dirty.promptCount.snapshot == 1)
            #expect(h.dirty.savedBatches.snapshot.isEmpty)
            #expect(try String(contentsOf: h.root.appendingPathComponent("a.go"), encoding: .utf8) == original)

            let diskHash = sha256(try Data(contentsOf: h.root.appendingPathComponent("a.go")))
            let expected = ContentHash.combined(["a.go": diskHash])
            #expect(first["sourceHash"] as? String == expected)
            #expect(first["sourceFileCount"] as? Int == 1)

            try "package pkg\n\nvar Changed = 1\n".write(to: h.root.appendingPathComponent("a.go"), atomically: true, encoding: .utf8)
            let second = decode(try await h.call("run_tests", alphaArgs))
            let changedHash = sha256(try Data(contentsOf: h.root.appendingPathComponent("a.go")))
            #expect(second["sourceHash"] as? String == ContentHash.combined(["a.go": changedHash]))
            #expect(second["sourceHash"] as? String != first["sourceHash"] as? String)
            #expect(h.dirty.savedBatches.snapshot.isEmpty)
        }
    }

    @Test func cancellingAtTheDirtyPromptRunsNothing() async throws {
        try await withHarness { h in
            h.dirty.setDirty("a.go")
            h.dirty.decision.with { $0 = .cancel }
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.errorCode == .cancelled)
            #expect(h.fakeGo.calls == 0)
            #expect(h.dirty.savedBatches.snapshot.isEmpty)
            #expect(await h.arbiter.activeRun() == nil)
        }
    }

    @Test func saveSelectedIsDelegatedToTheHostAndFailureRunsNothing() async throws {
        try await withHarness { h in
            h.dirty.setDirty("a.go")
            h.dirty.decision.with { $0 = .saveSelectedAndRun(paths: ["a.go"]) }
            let ok = decode(try await h.call("run_tests", alphaArgs))
            #expect(ok["outcome"] as? String == "passed")
            #expect(h.dirty.savedBatches.snapshot == [["a.go"]])
            #expect(ok["runsSavedVersion"] as? Bool == false)
            #expect(ok["unsavedPathsNotIncluded"] == nil)
            #expect(h.fakeGo.calls == 1)

            h.dirty.setDirty("a.go")
            h.dirty.saveSucceeds.with { $0 = false }
            let failed = try await h.call("run_tests", alphaArgs, id: "call-2")
            #expect(failed.errorCode == .unavailable)
            #expect(h.fakeGo.calls == 1)
            #expect(h.dirty.savedBatches.snapshot.count == 2)
        }
    }

    @Test func declinedApprovalReturnsDeniedWithReadOnlyAdviceAndSpawnsNothing() async throws {
        try await withHarness { h in
            h.approvals.fallback.with { $0 = .decline }
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.status == .error)
            #expect(result.errorCode == .denied)
            let data = decode(result)
            #expect(data["outcome"] as? String == "denied")
            let message = try #require(data["message"] as? String)
            #expect(message.contains("declined"))
            #expect(message.contains("read-only"))
            #expect(h.approvals.requestCount == 1)
            #expect(h.fakeGo.calls == 0)
            #expect(await h.arbiter.activeRun() == nil)
            #expect(await h.grants.activeGrants(workspaceID: h.workspaceID).isEmpty)
        }
    }

    @Test func cancelWhileAwaitingApprovalReturnsPromptlyAndSpawnsNothing() async throws {
        try await withHarness { h in
            h.approvals.hangs.with { $0 = true }
            let registry = try h.registry()
            let task = Task { await registry.dispatch(ToolCall(id: "c", name: "run_tests", argumentsJSON: alphaArgs)) }
            let deadline = Date().addingTimeInterval(10)
            while h.approvals.requestCount == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(h.approvals.requestCount == 1)
            let started = ContinuousClock.now
            task.cancel()
            let result = await task.value
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < .seconds(5))
            #expect(result.errorCode == .cancelled)
            #expect(decode(result)["outcome"] as? String == "cancelled")
            try await Task.sleep(for: .milliseconds(200))
            #expect(h.fakeGo.calls == 0)
            #expect(await h.arbiter.activeRun() == nil)
            #expect(await h.grants.activeGrants(workspaceID: h.workspaceID).isEmpty)
        }
    }

    @Test func alreadyCancelledCallNeverAsksOrRuns() async throws {
        try await withHarness { h in
            let registry = try h.registry()
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                return await registry.dispatch(ToolCall(id: "c", name: "run_tests", argumentsJSON: alphaArgs))
            }
            task.cancel()
            let result = await task.value
            #expect(result.errorCode == .cancelled)
            #expect(h.approvals.requestCount == 0)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func matchingScopedGrantRunsWithoutPromptAndMaxRunsDecrements() async throws {
        try await withHarness { h in
            try await h.grant(selector: "./pkg#TestAlpha", maxRuns: 2)
            let first = try await h.call("run_tests", alphaArgs)
            #expect(decode(first)["outcome"] as? String == "passed")
            #expect(h.approvals.requestCount == 0)
            var grant = try #require(await h.grants.activeGrants(workspaceID: h.workspaceID).first)
            #expect(grant.runsUsed == 1)
            #expect(grant.runsRemaining == 1)

            let second = try await h.call("run_tests", alphaArgs, id: "call-2")
            #expect(decode(second)["outcome"] as? String == "passed")
            #expect(h.approvals.requestCount == 0)
            grant = try #require(await h.grants.activeGrants(workspaceID: h.workspaceID).first)
            #expect(grant.runsRemaining == 0)
            #expect(h.fakeGo.calls == 2)

            h.approvals.fallback.with { $0 = .decline }
            let third = try await h.call("run_tests", alphaArgs, id: "call-3")
            #expect(third.errorCode == .denied)
            #expect(h.approvals.requestCount == 1)
            #expect(h.approvals.cards.snapshot[0].mismatches.contains(.runCount(remaining: 0, requested: 1)))
            #expect(h.fakeGo.calls == 2)
        }
    }

    enum GrantVariant: String, CaseIterable {
        case selector, target, environment, timeout, count, expiry, workspace, operation

        func matches(_ mismatch: GrantMismatch) -> Bool {
            switch (self, mismatch) {
            case (.selector, .selector), (.target, .targetConfig), (.environment, .environment), (.timeout, .timeout),
                 (.count, .runCount), (.expiry, .expired), (.workspace, .workspace), (.operation, .operation):
                return true
            default:
                return false
            }
        }
    }

    @Test(arguments: GrantVariant.allCases) func everyGrantMismatchProducesAnApprovalCard(_ variant: GrantVariant) async throws {
        try await withHarness { h in
            h.approvals.fallback.with { $0 = .decline }
            switch variant {
            case .selector: try await h.grant(selector: "./pkg#TestBeta")
            case .target: try await h.grant(targetHash: "another-target")
            case .environment: try await h.grant(envNames: ["PATH"])
            case .timeout: try await h.grant(timeout: 10)
            case .count: try await h.grant(maxRuns: 1, runsUsed: 1)
            case .expiry: try await h.grant(expiresAt: Date().addingTimeInterval(-30))
            case .workspace: try await h.grant(workspace: UUID())
            case .operation: try await h.grant(operation: .runBenchmark)
            }
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.errorCode == .denied)
            #expect(h.approvals.requestCount == 1)
            let card = try #require(h.approvals.cards.snapshot.first)
            #expect(card.mismatches.contains(where: variant.matches), "mismatches: \(card.mismatches)")
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func denyRuleBeatsAGrantAndNeverPrompts() async throws {
        try await withHarness(denyRules: [PolicyDenyRule(operation: .runTests)]) { h in
            try await h.grant(selector: "./pkg#TestAlpha")
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.errorCode == .denied)
            #expect((decode(result)["message"] as? String)?.contains("deny rule") == true)
            #expect(h.approvals.requestCount == 0)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func untrustedWorkspaceDeniesExecutionBeforeAnyPrompt() async throws {
        try await withHarness(trusted: false) { h in
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.errorCode == .denied)
            #expect((decode(result)["message"] as? String)?.contains("trusted") == true)
            #expect(h.approvals.requestCount == 0)
            #expect(h.fakeGo.calls == 0)
            await h.grants.setTrusted(true, workspaceID: h.workspaceID)
            let trusted = try await h.call("run_tests", alphaArgs, id: "call-2")
            #expect(decode(trusted)["outcome"] as? String == "passed")
        }
    }

    @Test func secretLookingEnvironmentNamesAreDenied() async throws {
        try await withHarness(extraEnvironment: ["MY_API_TOKEN": "value"]) { h in
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.errorCode == .denied)
            #expect((decode(result)["message"] as? String)?.contains("MY_API_TOKEN") == true)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func sessionApprovalCreatesAScopedGrantAndOnceDoesNot() async throws {
        try await withHarness { h in
            h.approvals.queue.with { $0 = [.allowForSession] }
            _ = try await h.call("run_tests", alphaArgs)
            _ = try await h.call("run_tests", alphaArgs, id: "call-2")
            #expect(h.approvals.requestCount == 1)
            #expect(h.fakeGo.calls == 2)
            let grant = try #require(await h.grants.activeGrants(workspaceID: h.workspaceID).first)
            #expect(grant.selector == "./pkg#TestAlpha")
            #expect(grant.maxRuns == 20)
            #expect(grant.runsUsed == 2)
            #expect(grant.targetConfigHash == h.targetHash())

            let other = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestBeta"]}"#, id: "call-3")
            #expect(decode(other)["outcome"] as? String == "passed")
            #expect(h.approvals.requestCount == 2)
        }
        try await withHarness { h in
            h.approvals.fallback.with { $0 = .allowOnce }
            _ = try await h.call("run_tests", alphaArgs)
            _ = try await h.call("run_tests", alphaArgs, id: "call-2")
            #expect(h.approvals.requestCount == 2)
            #expect(h.fakeGo.calls == 2)
        }
    }

    @Test func unknownMixedAndWrongKindTargetsAreRejectedBeforeApproval() async throws {
        try await withHarness { h in
            let unknown = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestNope"]}"#)
            #expect(unknown.errorCode == .notFound)
            let mixed = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestAlpha","./other#TestGamma"]}"#)
            #expect(mixed.errorCode == .invalidArguments)
            let wrongKind = try await h.call("run_tests", #"{"targetIDs":["./pkg#BenchmarkEncode"]}"#)
            #expect(wrongKind.errorCode == .notFound)
            let badPackage = try await h.call("run_tests", #"{"targetIDs":["-exec=evil#TestAlpha"]}"#)
            #expect(badPackage.errorCode == .invalidArguments)
            let injected = try await h.call("run_tests", #"{"targetIDs":["./pkg#TestAlpha$(rm)"]}"#)
            #expect(injected.errorCode == .notFound)
            #expect(h.approvals.requestCount == 0)
            #expect(h.fakeGo.calls == 0)
        }
    }

    @Test func packageLevelIDRunsEveryTestWithoutARunFilter() async throws {
        try await withHarness { h in
            let result = try await h.call("run_tests", #"{"targetIDs":["./pkg"],"timeoutSeconds":30}"#)
            let data = decode(result)
            let argv = try #require(data["argv"] as? [String])
            #expect(!argv.contains("-run"))
            #expect(argv.contains("-timeout=\(30 + ExecutionKit.toolchainTimeoutMargin)s"))
            #expect(h.approvals.cards.snapshot[0].selector == "./pkg")
            #expect(h.approvals.cards.snapshot[0].timeoutSeconds == 30)
        }
    }

    @Test func outputIsRedactedBeforeItReachesTheModelAndTheStore() async throws {
        try await withHarness { h in
            h.fakeGo.setBehavior("secret")
            let result = try await h.call("run_tests", alphaArgs)
            #expect(!result.data.contains("hunter2hunter2"))
            #expect(!result.data.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
            #expect(result.data.contains("REDACTED"))
            let runID = try #require(UUID(uuidString: decode(result)["runID"] as? String ?? ""))
            let stored = try #require(await h.runs.run(runID))
            #expect(!stored.output.contains("hunter2hunter2"))
            let evidence = try #require(await h.evidence.resolve(id: result.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(!evidence.content.contains("hunter2hunter2"))
        }
    }

    @Test func largeOutputIsCappedAt8KiBWithMarkersAndPagesThroughReadRunResult() async throws {
        try await withHarness { h in
            h.fakeGo.setBehavior("big")
            let result = try await h.call("run_tests", alphaArgs)
            #expect(result.data.utf8.count <= 8 * 1024)
            #expect(result.truncated)
            #expect(result.nextCursor == "0")
            let data = decode(result)
            #expect((data["outputOmittedBytes"] as? Int ?? 0) > 0)
            #expect(data["truncated"] as? Bool == true)
            #expect((data["outputTail"] as? String)?.contains("line number 1499") == true)
            let runID = try #require(UUID(uuidString: data["runID"] as? String ?? ""))
            let full = try #require(await h.runs.run(runID)).output
            #expect(full.utf8.count > 40_000)

            var assembled = ""
            var cursor: String? = "0"
            var pages = 0
            while let current = cursor, pages < 200 {
                let page = try await h.call("read_run_result", "{\"runID\":\"\(runID.uuidString)\",\"cursor\":\"\(current)\"}", id: "page-\(pages)")
                #expect(page.data.utf8.count <= 8 * 1024)
                assembled += decode(page)["output"] as? String ?? ""
                cursor = page.nextCursor
                pages += 1
                #expect(page.evidenceIDs.count == 1)
            }
            #expect(pages > 5)
            #expect(assembled == full)

            let beyond = try await h.call("read_run_result", "{\"runID\":\"\(runID.uuidString)\",\"cursor\":\"\(full.unicodeScalars.count + 50)\"}")
            #expect(decode(beyond)["output"] as? String == "")
            #expect(beyond.nextCursor == nil)
        }
    }

    @Test func readRunResultOnlyServesOwnedOrAttachedRuns() async throws {
        try await withHarness { h in
            let unknown = try await h.call("read_run_result", "{\"runID\":\"\(UUID().uuidString)\"}")
            #expect(unknown.errorCode == .notFound)
            let malformed = try await h.call("read_run_result", #"{"runID":"not-a-uuid"}"#)
            #expect(malformed.errorCode == .invalidArguments)

            let owned = try await h.call("run_tests", alphaArgs)
            let ownedID = try #require(decode(owned)["runID"] as? String)
            let read = try await h.call("read_run_result", "{\"runID\":\"\(ownedID)\"}")
            #expect(read.status == .ok)
            #expect(decode(read)["runStatus"] as? String == "passed")
            #expect(decode(read)["owner"] as? String == "ai:call-1")

            let command = try GoCommandBuilder.test(packages: ["./pkg"], tests: ["TestBeta"])
            let spec = RunSpec(argv: command.argv, workspaceRoot: h.root, environment: h.environment, deadline: 30, sourceHash: "user-src", configHash: "user-cfg")
            guard case .started(let userRun) = await h.arbiter.start(owner: .user, spec: spec) else {
                Issue.record("user run did not start")
                return
            }
            _ = await h.arbiter.awaitRecord(userRun)
            let notAttached = try await h.call("read_run_result", "{\"runID\":\"\(userRun.uuidString)\"}")
            #expect(notAttached.errorCode == .notFound)
            #expect(await h.runs.attach(runID: userRun, from: h.arbiter))
            let attached = try await h.call("read_run_result", "{\"runID\":\"\(userRun.uuidString)\"}")
            #expect(attached.status == .ok)
            #expect(decode(attached)["owner"] as? String == "user")
            #expect(decode(attached)["sourceHash"] as? String == "user-src")
            #expect(await h.runs.attach(runID: UUID(), from: h.arbiter) == false)
        }
    }

    @Test func listTestTargetsReturnsStableIDsAndPagesWithinTheCap() async throws {
        let many = (0..<400).map { TestTarget(package: "./pkg", name: "TestCase\(String(format: "%04d", $0))", kind: .test) }
        try await withHarness(targets: many) { h in
            let first = try await h.call("list_test_targets", #"{"packageScope":"./pkg","limit":200}"#)
            #expect(first.data.utf8.count <= 8 * 1024)
            #expect(first.truncated)
            let nextCursor = try #require(first.nextCursor)
            #expect(Int(nextCursor) != nil)
            #expect(first.evidenceIDs.count == 1)
            let evidence = try #require(await h.evidence.resolve(id: first.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidence.kind == .listing)

            var ids: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let args = cursor.map { "{\"packageScope\":\"./pkg\",\"limit\":200,\"cursor\":\"\($0)\"}" } ?? #"{"packageScope":"./pkg","limit":200}"#
                let page = try await h.call("list_test_targets", args, id: "p\(pages)")
                #expect(page.data.utf8.count <= 8 * 1024)
                ids += nestedList(decode(page), "targets").compactMap { $0["id"] as? String }
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < 100
            #expect(ids.count == 400)
            #expect(Set(ids).count == 400)
            #expect(ids.first == "./pkg#TestCase0000")
            #expect(ids.allSatisfy { $0.hasPrefix("./pkg#") })
        }
    }

    @Test func listTestTargetsReportsBackendStatesHonestly() async throws {
        try await withHarness { h in
            let all = try await h.call("list_test_targets", "{}")
            let targets = nestedList(decode(all), "targets")
            #expect(targets.count == 4)
            #expect(Set(targets.compactMap { $0["kind"] as? String }) == ["test", "benchmark"])
            #expect(targets.contains { $0["id"] as? String == "./pkg#BenchmarkEncode" })

            let none = try await h.call("list_test_targets", #"{"packageScope":"./missing"}"#)
            #expect(none.status == .ok)
            #expect(decode(none)["outcome"] as? String == "empty")
            let bad = try await h.call("list_test_targets", #"{"packageScope":"--evil"}"#)
            #expect(bad.errorCode == .invalidArguments)

            h.targets.outcomeOverride.with { $0 = .unavailable("gopls is starting") }
            let unavailable = try await h.call("list_test_targets", "{}")
            #expect(unavailable.errorCode == .unavailable)
            #expect(unavailable.retryable)
            h.targets.outcomeOverride.with { $0 = .timeout }
            let timeout = try await h.call("list_test_targets", "{}")
            #expect(timeout.errorCode == .timeout)
            #expect(decode(timeout)["targets"] == nil)
        }
    }
}
