import Foundation
import Testing
@testable import GopilotAnalysis

@Suite("Process run executor", .serialized)
struct ProcessRunExecutorTests {
    @Test func capturesExitCodeAndOutput() async throws {
        let root = try TestSupport.makeTempDirectory()
        let result = try await ProcessRunExecutor().run(TestSupport.shellRequest("echo out; echo err 1>&2; exit 3", root: root))
        #expect(result.outcome == .exited)
        #expect(result.exitCode == 3)
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
        #expect(!result.outputTruncated)
    }

    @Test func signalKilledProcessHasNoExitCode() async throws {
        let root = try TestSupport.makeTempDirectory()
        let result = try await ProcessRunExecutor().run(TestSupport.shellRequest("kill -9 $$", root: root))
        #expect(result.exitCode == nil)
        #expect(result.terminationSignal == 9)
    }

    @Test func runsInItsOwnProcessGroup() async throws {
        let root = try TestSupport.makeTempDirectory()
        let running = try ProcessRunExecutor().start(TestSupport.shellRequest("ps -o pgid= -p $$", root: root))
        let result = await running.wait()
        let childGroup = Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(childGroup == result.processGroupID)
        #expect(result.processGroupID != getpgrp())
    }

    @Test func environmentIsExactlyTheRequestedOne() async throws {
        let root = try TestSupport.makeTempDirectory()
        setenv("GOPILOT_PARENT_CANARY", "leak-me", 1)
        defer { unsetenv("GOPILOT_PARENT_CANARY") }
        let request = ProcessRunRequest(argv: ["/usr/bin/env"], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin", "ONLY_VAR": "kept"], deadline: 10, isolationProfile: .hostProcessGroup)
        let result = try await ProcessRunExecutor().run(request)
        let lines = Set(result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("_=") && !$0.hasPrefix("PWD=") && !$0.hasPrefix("SHLVL=") })
        #expect(lines == ["PATH=/usr/bin:/bin", "ONLY_VAR=kept"])
        #expect(!result.output.contains("leak-me"))
    }

    @Test func allowlistDropsKeysTokensAndCredentialUrls() {
        let source = [
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
            "OPENAI_API_KEY": "sk-secret",
            "ANTHROPIC_API_KEY": "sk-ant",
            "GITHUB_TOKEN": "ghp_x",
            "AWS_SECRET_ACCESS_KEY": "aws",
            "GOPROXY": "https://user:pass@proxy.example.test",
            "GOFLAGS": "-mod=readonly",
            "UNLISTED": "value"
        ]
        let filtered = EnvironmentAllowlist.goToolchain.apply(to: source)
        #expect(filtered == ["PATH": "/usr/bin", "HOME": "/Users/x", "GOFLAGS": "-mod=readonly"])
        let hostile = EnvironmentAllowlist(names: ["OPENAI_API_KEY", "GOPROXY"]).apply(to: source)
        #expect(hostile.isEmpty)
    }

    @Test func workingDirectoryMustStayInsideWorkspace() throws {
        let root = try TestSupport.makeTempDirectory()
        let outside = try TestSupport.makeTempDirectory("outside")
        #expect(throws: ProcessRunError.self) {
            try ProcessRunExecutor().start(ProcessRunRequest(argv: ["/bin/echo", "x"], workspaceRoot: root, workingDirectory: outside, environment: [:], deadline: 5))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: ProcessRunError.self) {
            try ProcessRunExecutor().start(ProcessRunRequest(argv: ["/bin/echo", "x"], workspaceRoot: root, workingDirectory: root.appendingPathComponent("escape"), environment: [:], deadline: 5))
        }
        #expect(throws: ProcessRunError.self) {
            try ProcessRunExecutor().start(ProcessRunRequest(argv: ["/bin/echo", "x"], workspaceRoot: root, workingDirectory: root.appendingPathComponent("../"), environment: [:], deadline: 5))
        }
    }

    @Test func rejectsEmptyArgvAndMissingExecutable() throws {
        let root = try TestSupport.makeTempDirectory()
        #expect(throws: ProcessRunError.emptyArgv) {
            try ProcessRunExecutor().start(ProcessRunRequest(argv: [], workspaceRoot: root, environment: [:], deadline: 5))
        }
        #expect(throws: ProcessRunError.executableNotFound("definitely-not-a-binary")) {
            try ProcessRunExecutor().start(ProcessRunRequest(argv: ["definitely-not-a-binary"], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: 5))
        }
    }

    @Test func outputIsBoundedWithHeadAndTail() async throws {
        let root = try TestSupport.makeTempDirectory()
        let script = "echo HEAD-MARKER; yes filler-line | head -c 3000000; echo TAIL-MARKER"
        let result = try await ProcessRunExecutor().run(TestSupport.shellRequest(script, root: root, outputLimit: 4096))
        #expect(result.exitCode == 0)
        #expect(result.outputTruncated)
        #expect(result.output.utf8.count < 4096 + 200)
        #expect(result.output.hasPrefix("HEAD-MARKER"))
        #expect(result.output.contains("TAIL-MARKER"))
        #expect(result.output.contains("bytes omitted"))
    }

    @Test func redactorRunsBeforeOutputIsStored() async throws {
        let root = try TestSupport.makeTempDirectory()
        let redactor = LiteralRedactor(secrets: ["canary-8d3f"])
        let executor = ProcessRunExecutor(redactor: { redactor.redact($0) })
        let result = try await executor.run(TestSupport.shellRequest("echo token=canary-8d3f", root: root))
        #expect(!result.output.contains("canary-8d3f"))
        #expect(result.output.contains("token=[REDACTED]"))
    }

    @Test func deadlineKillsWholeGroupIncludingChildren() async throws {
        let root = try TestSupport.makeTempDirectory()
        let request = TestSupport.shellRequest("sleep 300 & echo $! > child.pid; wait", root: root, deadline: 1.0, grace: 0.3)
        let result = try await ProcessRunExecutor().run(request)
        #expect(result.outcome == .timedOut)
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(await TestSupport.waitUntilDead(childPID))
    }

    @Test func termIgnoringChildIsEscalatedToKill() async throws {
        let root = try TestSupport.makeTempDirectory()
        let request = TestSupport.shellRequest("trap '' TERM; sh -c \"trap '' TERM; echo \\$\\$ > child.pid; sleep 300\" & wait", root: root, deadline: 1.0, grace: 0.3)
        let result = try await ProcessRunExecutor().run(request)
        #expect(result.outcome == .timedOut)
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(await TestSupport.waitUntilDead(childPID))
    }

    @Test func leftoverBackgroundChildIsReapedAfterNormalExit() async throws {
        let root = try TestSupport.makeTempDirectory()
        let request = TestSupport.shellRequest("sleep 300 > /dev/null 2>&1 & echo $! > child.pid; exit 0", root: root)
        let result = try await ProcessRunExecutor().run(request)
        #expect(result.exitCode == 0)
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(await TestSupport.waitUntilDead(childPID))
    }

    @Test func taskCancellationStopsTheGroup() async throws {
        let root = try TestSupport.makeTempDirectory()
        let executor = ProcessRunExecutor()
        let task = Task { try await executor.run(TestSupport.shellRequest("sleep 300 & echo $! > child.pid; wait", root: root, deadline: 60)) }
        #expect(await TestSupport.waitForFile(root.appendingPathComponent("child.pid"), timeout: 10))
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try await task.value
        #expect(result.outcome == .cancelled)
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(await TestSupport.waitUntilDead(childPID))
    }

    @Test func droppingTheHandleKillsTheGroup() async throws {
        let root = try TestSupport.makeTempDirectory()
        var running: RunningProcess? = try ProcessRunExecutor().start(TestSupport.shellRequest("sleep 300 & echo $! > child.pid; wait", root: root, deadline: 120))
        #expect(await TestSupport.waitForFile(root.appendingPathComponent("child.pid"), timeout: 10))
        try await Task.sleep(for: .milliseconds(100))
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(TestSupport.processAlive(childPID))
        running = nil
        #expect(await TestSupport.waitUntilDead(childPID, timeout: 10))
    }

    @Test func neverSignalsProcessesOutsideItsOwnGroup() async throws {
        let root = try TestSupport.makeTempDirectory()
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["300"]
        try bystander.run()
        defer { bystander.terminate() }

        let executor = ProcessRunExecutor()
        let running = try executor.start(TestSupport.shellRequest("sleep 300", root: root, deadline: 60))
        #expect(running.processGroupID != getpgrp())
        #expect(running.processGroupID != getpgid(bystander.processIdentifier))
        running.cancel()
        let result = await running.wait()
        #expect(result.outcome == .cancelled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(bystander.isRunning)
        #expect(getpgrp() > 1)
        #expect(TestSupport.processAlive(getpid()))
    }

    @Test func cancelAfterNaturalExitKeepsTheExitOutcome() async throws {
        let root = try TestSupport.makeTempDirectory()
        let running = try ProcessRunExecutor().start(TestSupport.shellRequest("exit 0", root: root))
        let result = await running.wait()
        running.cancel()
        #expect(result.outcome == .exited)
        #expect(result.exitCode == 0)
        #expect(await running.wait() == result)
    }

    @Test func goTestOnLibraryFixturePasses() async throws {
        try #require(TestSupport.goAvailable)
        let root = try TestSupport.fixtureCopy("library")
        let command = try GoCommandBuilder.test(packages: ["./..."], count: 1, timeoutSeconds: 120)
        let request = ProcessRunRequest(argv: command.argv, workspaceRoot: root, environment: TestSupport.goEnvironment, deadline: 240)
        let result = try await ProcessRunExecutor().run(request)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("ok"))
    }

    @Test func goChildProcessesDieWhenTheRunIsCancelled() async throws {
        try #require(TestSupport.goAvailable)
        let root = try TestSupport.writeModule(name: "sleepy", files: ["sleepy_test.go": TestSupport.sleepyGoTest])
        let command = try GoCommandBuilder.test(packages: ["."], tests: ["TestHoldsChild"], timeoutSeconds: 600)
        let running = try ProcessRunExecutor().start(ProcessRunRequest(argv: command.argv, workspaceRoot: root, environment: TestSupport.goEnvironment, deadline: 300, terminationGrace: 1))
        #expect(await TestSupport.waitForFile(root.appendingPathComponent("started")))
        let childPID = try #require(TestSupport.readPID(root.appendingPathComponent("child.pid")))
        #expect(TestSupport.processAlive(childPID))
        running.cancel()
        let result = await running.wait()
        #expect(result.outcome == .cancelled)
        #expect(await TestSupport.waitUntilDead(childPID, timeout: 10))
        #expect(kill(-running.processGroupID, 0) != 0)
    }

    @Test func cgoDisabledByDefaultWhenUnspecified() async throws {
        let root = try TestSupport.makeTempDirectory()
        let request = ProcessRunRequest(
            argv: ["/usr/bin/env"],
            workspaceRoot: root,
            environment: ["PATH": "/usr/bin:/bin"],
            deadline: 10,
            isolationProfile: .linuxMicroVM(workspaceReadOnly: true, loopbackOnlyNetwork: true)
        )
        let result = try await ProcessRunExecutor().run(request)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("CGO_ENABLED=0"))
    }

    @Test func processExecutionDriverDelegatesForLinuxMicroVM() throws {
        final class MockController: ProcessController, @unchecked Sendable {
            let processGroupID: pid_t = 1234
            func wait() async -> ProcessRunResult {
                let now = Date()
                return ProcessRunResult(
                    outcome: .exited,
                    exitCode: 0,
                    terminationSignal: nil,
                    output: "mock-vm-output",
                    outputTruncated: false,
                    startedAt: now,
                    endedAt: now,
                    processGroupID: 1234
                )
            }
            func cancel() {}
        }

        final class MockDriver: ProcessExecutionDriver, @unchecked Sendable {
            var capturedRequest: ProcessRunRequest?
            func start(_ request: ProcessRunRequest, redactor: @escaping @Sendable (String) -> String) throws -> RunningProcess {
                capturedRequest = request
                return RunningProcess(controller: MockController())
            }
        }

        let root = URL(fileURLWithPath: "/tmp")
        let driver = MockDriver()
        let executor = ProcessRunExecutor(driver: driver)
        let request = ProcessRunRequest(
            argv: ["go", "test", "./..."],
            workspaceRoot: root,
            environment: ["PATH": "/usr/bin"],
            deadline: 30,
            isolationProfile: .linuxMicroVM(workspaceReadOnly: true, loopbackOnlyNetwork: true)
        )
        let running = try executor.start(request)
        #expect(running.processGroupID == 1234)
        #expect(driver.capturedRequest != nil)
        #expect(driver.capturedRequest?.environment["CGO_ENABLED"] == "0")
        #expect(driver.capturedRequest?.argv == ["go", "test", "./..."])
    }
}
