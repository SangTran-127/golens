import Foundation
@testable import GopilotAnalysis

enum TestSupport {
    static func makeTempDirectory(_ label: String = "analysis") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gopilot-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }

    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static func fixtureCopy(_ name: String) throws -> URL {
        let source = repoRoot.appendingPathComponent("tests/gopilot/fixtures/\(name)", isDirectory: true)
        let destination = try makeTempDirectory(name).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.resolvingSymlinksInPath()
    }

    static func writeModule(name: String, files: [String: String]) throws -> URL {
        let root = try makeTempDirectory(name)
        try "module example.test/\(name)\n\ngo 1.22\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        for (file, content) in files {
            try content.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root
    }

    static var goEnvironment: [String: String] {
        EnvironmentAllowlist.goToolchain.apply(to: ProcessInfo.processInfo.environment)
    }

    static var goAvailable: Bool {
        ProcessRunExecutor.resolveExecutable("go", path: goEnvironment["PATH"]) != nil
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    static func waitUntilDead(_ pid: Int32, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !processAlive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !processAlive(pid)
    }

    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let sleepyGoTest = """
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

    static func shellRequest(_ script: String, root: URL, deadline: TimeInterval = 20, outputLimit: Int = 1 << 20, grace: TimeInterval = 0.3) -> ProcessRunRequest {
        ProcessRunRequest(argv: ["/bin/sh", "-c", script], workspaceRoot: root, environment: ["PATH": "/usr/bin:/bin"], deadline: deadline, outputLimitBytes: outputLimit, terminationGrace: grace)
    }

    static func goSpec(argv: [String], root: URL, deadline: TimeInterval = 300, sourceHash: String = "src", configHash: String = "cfg") -> RunSpec {
        RunSpec(argv: argv, workspaceRoot: root, environment: goEnvironment, deadline: deadline, sourceHash: sourceHash, configHash: configHash)
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func values(center: Double, spread: Double, count: Int) -> [Double] {
        (0..<count).map { _ in center + (next() * 2 - 1) * spread }
    }
}
