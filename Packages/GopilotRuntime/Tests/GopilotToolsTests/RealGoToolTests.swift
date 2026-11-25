import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private let sleepyTest = """
package sleepy

import (
\t"os"
\t"os/exec"
\t"strconv"
\t"testing"
\t"time"
)

func TestHoldsChild(t *testing.T) {
\tcmd := exec.Command("sleep", "300")
\tif err := cmd.Start(); err != nil {
\t\tt.Fatal(err)
\t}
\t_ = os.WriteFile("child.pid", []byte(strconv.Itoa(cmd.Process.Pid)), 0o644)
\t_ = os.WriteFile("started", []byte("1"), 0o644)
\ttime.Sleep(300 * time.Second)
}
"""

private func sleepyModule() throws -> URL {
    let root = try TestFiles.makeTempDirectory("sleepy")
    try "module example.test/sleepy\n\ngo 1.22\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
    try sleepyTest.write(to: root.appendingPathComponent("sleepy_test.go"), atomically: true, encoding: .utf8)
    return root
}

private let sleepyTargets = [TestTarget(package: ".", name: "TestHoldsChild", kind: .test)]
private let sleepyArgs = #"{"targetIDs":[".#TestHoldsChild"],"timeoutSeconds":600}"#

private func startUnrelatedProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["120"]
    try process.run()
    return process
}

@Suite("Real go processes", .serialized, .enabled(if: TestFiles.goAvailable))
struct RealGoToolTests {
    @Test func fixtureTestPassesThroughTheRealToolchainWithExitZero() async throws {
        let root = try TestFiles.fixtureCopy("cli")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let targets = [TestTarget(package: ".", name: "TestRunText", kind: .test)]
        try await withHarness(targets: targets, workspaceRoot: root, realGo: true) { h in
            let result = try await h.call("run_tests", #"{"targetIDs":[".#TestRunText"],"timeoutSeconds":300}"#)
            let data = decode(result)
            #expect(result.status == .ok, "\(result.data)")
            #expect(data["outcome"] as? String == "passed", "\(result.data)")
            #expect(data["exitCode"] as? Int == 0)
            #expect(data["cwd"] as? String == root.path)
            let argv = try #require(data["argv"] as? [String])
            #expect(argv.starts(with: ["go", "test", "-mod=readonly"]))
            let hashes = TestFiles.diskHashes(in: root)
            #expect(data["sourceFileCount"] as? Int == hashes.count)
            #expect(data["sourceHash"] as? String == GopilotAnalysis.ContentHash.combined(hashes))
        }
    }

    @Test func cancellingTheCallStopsTheOwnedProcessGroupAndNothingElse() async throws {
        let root = try sleepyModule()
        defer { try? FileManager.default.removeItem(at: root) }
        let bystander = try startUnrelatedProcess()
        defer { if bystander.isRunning { bystander.terminate() } }
        try await withHarness(targets: sleepyTargets, workspaceRoot: root, realGo: true) { h in
            let registry = try h.registry()
            let task = Task { await registry.dispatch(ToolCall(id: "sleepy", name: "run_tests", argumentsJSON: sleepyArgs)) }
            #expect(await TestFiles.waitForFile(root.appendingPathComponent("started"), timeout: 180))
            let childPID = try #require(TestFiles.readPID(root.appendingPathComponent("child.pid")))
            #expect(kill(childPID, 0) == 0)
            #expect(await h.arbiter.activeRun()?.owner == .ai(actionID: "sleepy"))

            task.cancel()
            let result = await task.value
            #expect(result.errorCode == .cancelled)
            let data = decode(result)
            #expect(data["outcome"] as? String == "cancelled")
            #expect(data["runStatus"] as? String == "cancelled")
            #expect(await TestFiles.waitUntilDead(childPID, timeout: 15))
            #expect(await h.arbiter.activeRun() == nil)
            #expect(bystander.isRunning)
            let runID = try #require(UUID(uuidString: data["runID"] as? String ?? ""))
            #expect(await h.runs.run(runID)?.record.status == .cancelled)
        }
    }

    @Test func timeoutProducesATimedOutRecordAndCleansUpTheChild() async throws {
        let root = try sleepyModule()
        defer { try? FileManager.default.removeItem(at: root) }
        let bystander = try startUnrelatedProcess()
        defer { if bystander.isRunning { bystander.terminate() } }
        try await withHarness(targets: sleepyTargets, workspaceRoot: root, realGo: true) { h in
            let result = try await h.call("run_tests", #"{"targetIDs":[".#TestHoldsChild"],"timeoutSeconds":12}"#)
            #expect(result.errorCode == .timeout, "\(result.data)")
            #expect(result.retryable)
            let data = decode(result)
            #expect(data["outcome"] as? String == "timedOut")
            #expect(data["runStatus"] as? String == "timedOut")
            #expect(!result.data.contains("\"outcome\":\"passed\""))
            if let childPID = TestFiles.readPID(root.appendingPathComponent("child.pid")) {
                #expect(await TestFiles.waitUntilDead(childPID, timeout: 15))
            }
            #expect(await h.arbiter.activeRun() == nil)
            #expect(bystander.isRunning)
        }
    }
}
