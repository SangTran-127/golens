import Foundation
import Testing
@testable import GopilotAnalysis

@Suite("Run arbiter and records", .serialized)
struct RunArbiterTests {
    private func shellSpec(_ script: String, root: URL, deadline: TimeInterval = 60) -> RunSpec {
        RunSpec(argv: ["/bin/sh", "-c", script], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: deadline, sourceHash: "src", configHash: "cfg")
    }

    private func startedID(_ outcome: RunStartOutcome) throws -> UUID {
        guard case .started(let id) = outcome else {
            Issue.record("expected a started run, got \(outcome)")
            throw CancellationError()
        }
        return id
    }

    @Test func aiCancelCannotStopUserOwnedGoRun() async throws {
        try #require(TestSupport.goAvailable)
        let root = try TestSupport.writeModule(name: "sleepy", files: ["sleepy_test.go": TestSupport.sleepyGoTest])
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let command = try GoCommandBuilder.test(packages: ["."], tests: ["TestHoldsChild"], timeoutSeconds: 600)
        let userRun = try startedID(await arbiter.start(owner: .user, spec: TestSupport.goSpec(argv: command.argv, root: root)))
        #expect(await TestSupport.waitForFile(root.appendingPathComponent("started")))
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        let busy = try #require(await arbiter.activeRun())
        #expect(busy.owner == .user)

        let refused = await arbiter.cancel(runID: userRun, requester: .ai(actionID: "ai-action-1"))
        #expect(refused == .refusedNotOwner(active: busy))
        let refusedBulk = await arbiter.cancelRuns(ownedBy: .ai(actionID: "ai-action-1"))
        #expect(refusedBulk.isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        #expect(TestSupport.processAlive(childPID))
        #expect(await arbiter.activeRun()?.runID == userRun)
        #expect(await arbiter.record(for: userRun) == nil)

        let aiStart = await arbiter.start(owner: .ai(actionID: "ai-action-1"), spec: shellSpec("echo hi", root: root))
        #expect(aiStart == .busy(busy))
        #expect(await arbiter.waitUntilIdle(timeout: .milliseconds(300)) == false)

        #expect(await arbiter.cancel(runID: userRun, requester: .user) == .cancelling)
        let record = try #require(await arbiter.awaitRecord(userRun))
        #expect(record.owner == .user)
        #expect(record.status == .cancelled)
        #expect(await TestSupport.waitUntilDead(childPID, timeout: 10))
        #expect(await arbiter.activeRun() == nil)
    }

    @Test func aiOwnsOnlyItsOwnActionAndUserCanStopAiRuns() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let first = try startedID(await arbiter.start(owner: .ai(actionID: "A"), spec: shellSpec("sleep 300", root: root)))
        let info = try #require(await arbiter.activeRun())
        #expect(await arbiter.cancel(runID: first, requester: .ai(actionID: "B")) == .refusedNotOwner(active: info))
        #expect(await arbiter.cancel(runID: UUID(), requester: .ai(actionID: "A")) == .notActive)
        #expect(await arbiter.cancel(runID: first, requester: .ai(actionID: "A")) == .cancelling)
        let record = try #require(await arbiter.awaitRecord(first))
        #expect(record.status == .cancelled)
        #expect(record.owner == .ai(actionID: "A"))

        let second = try startedID(await arbiter.start(owner: .ai(actionID: "B"), spec: shellSpec("sleep 300", root: root)))
        #expect(await arbiter.cancel(runID: second, requester: .user) == .cancelling)
        #expect(try #require(await arbiter.awaitRecord(second)).status == .cancelled)
    }

    @Test func busyReportsOwnerAndAiCanWaitForIdle() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let userRun = try startedID(await arbiter.start(owner: .user, spec: shellSpec("sleep 1", root: root)))
        let outcome = await arbiter.start(owner: .ai(actionID: "A"), spec: shellSpec("echo ai", root: root))
        guard case .busy(let info) = outcome else {
            Issue.record("expected busy")
            return
        }
        #expect(info.owner == .user)
        #expect(info.runID == userRun)
        #expect(!info.isExternal)
        #expect(await arbiter.waitUntilIdle(timeout: .seconds(10)))
        let aiRun = try startedID(await arbiter.start(owner: .ai(actionID: "A"), spec: shellSpec("echo ai", root: root)))
        let record = try #require(await arbiter.awaitRecord(aiRun))
        #expect(record.status == .passed)
        #expect(await arbiter.output(for: aiRun)?.contains("ai") == true)
    }

    @Test func externalUserRunBlocksAiAndCannotBeCancelledByIt() async throws {
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let root = try TestSupport.makeTempDirectory()
        let external = UUID()
        #expect(await arbiter.beginExternalRun(owner: .user, runID: external) == .started(runID: external))
        let info = try #require(await arbiter.activeRun())
        #expect(info.isExternal)
        #expect(await arbiter.cancel(runID: external, requester: .ai(actionID: "A")) == .refusedNotOwner(active: info))
        #expect(await arbiter.cancel(runID: external, requester: .user) == .externalRunNotManaged)
        #expect(await arbiter.start(owner: .ai(actionID: "A"), spec: shellSpec("echo x", root: root)) == .busy(info))
        #expect(await arbiter.beginExternalRun(owner: .user) == .busy(info))
        await arbiter.endExternalRun(runID: UUID())
        #expect(await arbiter.activeRun() != nil)
        await arbiter.endExternalRun(runID: external)
        #expect(await arbiter.activeRun() == nil)
    }

    @Test func shutdownStopsOwnedRunAndLeavesNoActiveRun() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let run = try startedID(await arbiter.start(owner: .ai(actionID: "A"), spec: shellSpec("sleep 300 & echo $! > child.pid; wait", root: root)))
        #expect(await TestSupport.waitForFile(root.appendingPathComponent("child.pid"), timeout: 10))
        try await Task.sleep(for: .milliseconds(100))
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        await arbiter.shutdown()
        #expect(await arbiter.activeRun() == nil)
        #expect(await TestSupport.waitUntilDead(childPID))
        #expect(try #require(await arbiter.awaitRecord(run)).status == .cancelled)
    }

    @Test func launchFailureIsReportedAndDoesNotBlockTheArbiter() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let spec = RunSpec(argv: ["no-such-binary-xyz"], workspaceRoot: root, environment: ["PATH": "/usr/bin"], deadline: 5, sourceHash: "s", configHash: "c")
        guard case .failedToLaunch = await arbiter.start(owner: .user, spec: spec) else {
            Issue.record("expected launch failure")
            return
        }
        #expect(await arbiter.activeRun() == nil)
    }

    @Test func exitStatusMapsToTerminalStatus() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let passed = try startedID(await arbiter.start(owner: .user, spec: shellSpec("exit 0", root: root)))
        #expect(try #require(await arbiter.awaitRecord(passed)).status == .passed)
        let failed = try startedID(await arbiter.start(owner: .user, spec: shellSpec("exit 1", root: root)))
        let failedRecord = try #require(await arbiter.awaitRecord(failed))
        #expect(failedRecord.status == .failed)
        #expect(failedRecord.exitCode == 1)
        let signaled = try startedID(await arbiter.start(owner: .user, spec: shellSpec("kill -9 $$", root: root)))
        let signaledRecord = try #require(await arbiter.awaitRecord(signaled))
        #expect(signaledRecord.exitCode == nil)
        #expect(signaledRecord.status != .passed)
        let timedOut = try startedID(await arbiter.start(owner: .user, spec: RunSpec(argv: ["/bin/sleep", "300"], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: 0.5, sourceHash: "s", configHash: "c")))
        #expect(try #require(await arbiter.awaitRecord(timedOut)).status == .timedOut)
    }

    @Test func realGoTestsMapToPassedAndFailed() async throws {
        try #require(TestSupport.goAvailable)
        let root = try TestSupport.writeModule(name: "mixed", files: [
            "mixed_test.go": "package mixed\n\nimport \"testing\"\n\nfunc TestGood(t *testing.T) {}\n\nfunc TestBad(t *testing.T) { t.Fatal(\"boom\") }\n"
        ])
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let good = try GoCommandBuilder.test(packages: ["."], tests: ["TestGood"])
        let bad = try GoCommandBuilder.test(packages: ["."], tests: ["TestBad"])
        let goodID = try startedID(await arbiter.start(owner: .ai(actionID: "A"), spec: TestSupport.goSpec(argv: good.argv, root: root)))
        let goodRecord = try #require(await arbiter.awaitRecord(goodID))
        #expect(goodRecord.status == .passed)
        #expect(goodRecord.exitCode == 0)
        let badID = try startedID(await arbiter.start(owner: .ai(actionID: "A"), spec: TestSupport.goSpec(argv: bad.argv, root: root)))
        let badRecord = try #require(await arbiter.awaitRecord(badID))
        #expect(badRecord.status == .failed)
        #expect(badRecord.exitCode == 1)
        #expect(await arbiter.output(for: badID)?.contains("boom") == true)
    }

    @Test func recordWithoutExitCodeIsNeverPassed() throws {
        let now = Date()
        let noCode = RunRecord(owner: .ai(actionID: "A"), argv: ["go", "test"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: nil, outcome: .exited)
        #expect(noCode.status == .unknown)
        let unfinished = RunRecord(owner: .user, argv: ["go"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: nil, exitCode: 0, outcome: .exited)
        #expect(unfinished.status == .unknown)
        let abandoned = RunRecord(owner: .user, argv: ["go"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: 0, outcome: .abandoned)
        #expect(abandoned.status == .unknown)
        let zero = RunRecord(owner: .user, argv: ["go"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: 0, outcome: .exited)
        #expect(zero.status == .passed)
        let nonzero = RunRecord(owner: .user, argv: ["go"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: 2, outcome: .exited)
        #expect(nonzero.status == .failed)
        let cancelledWithZero = RunRecord(owner: .user, argv: ["go"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: 0, outcome: .cancelled)
        #expect(cancelledWithZero.status == .cancelled)
    }

    @Test func tamperedRecordCannotDecodeAsPassed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let good = RunRecord(owner: .ai(actionID: "A"), argv: ["go", "test"], cwd: "/w", sourceHash: "s", configHash: "c", startedAt: now, endedAt: now, exitCode: 0, outcome: .exited)
        let encoder = JSONEncoder()
        let data = try encoder.encode(good)
        #expect(try JSONDecoder().decode(RunRecord.self, from: data) == good)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "exitCode")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decodedWithoutCode = try JSONDecoder().decode(RunRecord.self, from: stripped)
        #expect(decodedWithoutCode.status == .unknown)

        object["exitCode"] = 1
        let nonzero = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(RunRecord.self, from: nonzero).status == .unknown)
    }

    @Test func recordCarriesOwnerArgvCwdAndHashesFromARealRun() async throws {
        let root = try TestSupport.makeTempDirectory()
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let spec = RunSpec(argv: ["/bin/sh", "-c", "pwd"], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: 10, sourceHash: "source-h", configHash: "config-h")
        let id = try startedID(await arbiter.start(owner: .ai(actionID: "act-7"), spec: spec))
        let record = try #require(await arbiter.awaitRecord(id))
        #expect(record.owner == .ai(actionID: "act-7"))
        #expect(record.argv == spec.argv)
        #expect(record.cwd == root.path)
        #expect(record.sourceHash == "source-h")
        #expect(record.configHash == "config-h")
        #expect(record.endedAt != nil)
        #expect(record.startedAt <= record.endedAt!)
    }

    @Test func configHashChangesWithArgvAndEnvNames() {
        let a = RunConfigHash.compute(argv: ["go", "test", "./a"], environmentNames: ["PATH", "HOME"])
        let sameDifferentOrder = RunConfigHash.compute(argv: ["go", "test", "./a"], environmentNames: ["HOME", "PATH"])
        let otherArgv = RunConfigHash.compute(argv: ["go", "test", "./b"], environmentNames: ["PATH", "HOME"])
        let otherEnv = RunConfigHash.compute(argv: ["go", "test", "./a"], environmentNames: ["PATH"])
        #expect(a == sameDifferentOrder)
        #expect(a != otherArgv)
        #expect(a != otherEnv)
    }
}

@Suite("Dirty buffer policy")
struct DirtyBufferPolicyTests {
    private func states(disk: [String: String], buffer: [String: String]) -> [BufferDiskState] {
        disk.keys.sorted().enumerated().map { index, path in
            BufferDiskState(path: path, diskContentHash: ContentHash.sha256Hex(disk[path] ?? ""), bufferContentHash: ContentHash.sha256Hex(buffer[path] ?? disk[path] ?? ""), documentVersion: index + 1)
        }
    }

    @Test func cleanBuffersProceedWithDiskFingerprint() {
        let buffers = states(disk: ["a.go": "package a", "b.go": "package b"], buffer: [:])
        guard case .proceed(let revision) = DirtyBufferPolicy.evaluate(buffers: buffers, decision: nil) else {
            Issue.record("expected proceed")
            return
        }
        #expect(!revision.runsSavedVersion)
        #expect(revision.dirtyPathsNotIncluded.isEmpty)
        #expect(revision.fingerprint == DirtyBufferPolicy.diskFingerprint(buffers))
    }

    @Test func dirtyBufferNeverRunsWithoutADecision() {
        let buffers = states(disk: ["a.go": "package a", "b.go": "package b"], buffer: ["b.go": "package b // edited"])
        #expect(DirtyBufferPolicy.evaluate(buffers: buffers, decision: nil) == .needsDecision(dirtyPaths: ["b.go"]))
    }

    @Test func runSavedVersionKeepsFingerprintOnDiskContent() {
        let clean = states(disk: ["a.go": "package a"], buffer: [:])
        let dirty = states(disk: ["a.go": "package a"], buffer: ["a.go": "package a\n// unsaved edit"])
        guard case .proceed(let cleanRevision) = DirtyBufferPolicy.evaluate(buffers: clean, decision: nil),
              case .proceed(let dirtyRevision) = DirtyBufferPolicy.evaluate(buffers: dirty, decision: .runSavedVersion) else {
            Issue.record("expected proceed")
            return
        }
        #expect(dirtyRevision.fingerprint == cleanRevision.fingerprint)
        #expect(dirtyRevision.runsSavedVersion)
        #expect(dirtyRevision.dirtyPathsNotIncluded == ["a.go"])
    }

    @Test func fingerprintFollowsDiskNotBuffer() {
        let before = states(disk: ["a.go": "v1"], buffer: ["a.go": "typed"])
        let afterDiskChange = states(disk: ["a.go": "v2"], buffer: ["a.go": "typed"])
        #expect(DirtyBufferPolicy.diskFingerprint(before) != DirtyBufferPolicy.diskFingerprint(afterDiskChange))
        let differentBuffer = states(disk: ["a.go": "v1"], buffer: ["a.go": "typed more"])
        #expect(DirtyBufferPolicy.diskFingerprint(before) == DirtyBufferPolicy.diskFingerprint(differentBuffer))
    }

    @Test func saveSelectedAsksTheAppToSaveAndNeverSavesItself() throws {
        let root = try TestSupport.makeTempDirectory()
        let file = root.appendingPathComponent("a.go")
        try "package a".write(to: file, atomically: true, encoding: .utf8)
        let diskHash = ContentHash.sha256Hex(try Data(contentsOf: file))
        let buffers = [
            BufferDiskState(path: "a.go", diskContentHash: diskHash, bufferContentHash: ContentHash.sha256Hex("package a // edit"), documentVersion: 3),
            BufferDiskState(path: "b.go", diskContentHash: "x", bufferContentHash: "y", documentVersion: 1)
        ]
        let outcome = DirtyBufferPolicy.evaluate(buffers: buffers, decision: .saveSelectedAndRun(paths: ["a.go", "not-dirty.go"]))
        #expect(outcome == .saveThenRerunGate(pathsToSave: ["a.go"]))
        #expect(try String(contentsOf: file, encoding: .utf8) == "package a")
        #expect(DirtyBufferPolicy.evaluate(buffers: buffers, decision: .saveSelectedAndRun(paths: ["zzz.go"])) == .needsDecision(dirtyPaths: ["a.go", "b.go"]))
    }

    @Test func cancelDecisionCancels() {
        let buffers = states(disk: ["a.go": "a"], buffer: ["a.go": "b"])
        #expect(DirtyBufferPolicy.evaluate(buffers: buffers, decision: .cancel) == .cancelled)
    }

    @Test func runRecordSourceHashMatchesDiskContents() async throws {
        let root = try TestSupport.makeTempDirectory()
        let file = root.appendingPathComponent("a.go")
        try "package a".write(to: file, atomically: true, encoding: .utf8)
        let diskData = try Data(contentsOf: file)
        let sourceHash = ContentHash.sourceHash(diskContents: ["a.go": diskData])
        let arbiter = RunArbiter(executor: ProcessRunExecutor())
        let spec = RunSpec(argv: ["/usr/bin/true"], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: 5, sourceHash: sourceHash, configHash: "c")
        guard case .started(let id) = await arbiter.start(owner: .ai(actionID: "A"), spec: spec) else {
            Issue.record("expected start")
            return
        }
        let record = try #require(await arbiter.awaitRecord(id))
        #expect(record.sourceHash == ContentHash.sourceHash(diskContents: ["a.go": Data("package a".utf8)]))
        #expect(record.sourceHash != ContentHash.sourceHash(diskContents: ["a.go": Data("package a // unsaved".utf8)]))
    }
}

@Suite("Content hash")
struct ContentHashTests {
    @Test func matchesKnownSha256Vectors() {
        #expect(ContentHash.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(ContentHash.sha256Hex(String(repeating: "a", count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func combinedHashIgnoresInsertionOrderButNotContent() {
        #expect(ContentHash.combined(["a": "1", "b": "2"]) == ContentHash.combined(["b": "2", "a": "1"]))
        #expect(ContentHash.combined(["a": "1", "b": "2"]) != ContentHash.combined(["a": "1", "b": "3"]))
        #expect(ContentHash.combined(["a": "1b"]) != ContentHash.combined(["a1": "b"]))
    }
}
