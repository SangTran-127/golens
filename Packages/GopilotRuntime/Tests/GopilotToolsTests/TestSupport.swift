import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
import GopilotStore
@testable import GopilotTools

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var snapshot: Value { with { $0 } }
}

enum TestFiles {
    static func makeTempDirectory(_ label: String = "tools") throws -> URL {
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

    static var goAvailable: Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/go") }
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static func waitUntilDead(_ pid: Int32, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }

    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func diskHashes(in root: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in enumerator where url.pathExtension == "go" {
            if let data = try? Data(contentsOf: url) {
                let rootPath = root.resolvingSymlinksInPath().path + "/"
                let key = url.resolvingSymlinksInPath().path.replacingOccurrences(of: rootPath, with: "")
                out[key] = GopilotAnalysis.ContentHash.sha256Hex(data)
            }
        }
        return out
    }
}

struct FakeGo {
    let directory: URL

    init() throws {
        directory = try TestFiles.makeTempDirectory("fakego")
        let script = """
        #!/bin/sh
        here="$(dirname "$0")"
        echo "$@" >> "$here/calls.log"
        mode="$(cat "$here/behavior" 2>/dev/null)"
        case "$mode" in
        fail) echo "--- FAIL: TestSomething"; echo "FAIL"; exit 1;;
        bench) cat "$here/bench.txt"; exit 0;;
        benchfail) cat "$here/bench.txt"; exit 1;;
        sleep) sleep 30; exit 0;;
        secret) echo "password=hunter2hunter2 key sk-abcdefghijklmnopqrstuvwxyz123456"; exit 0;;
        big) i=0; while [ $i -lt 1500 ]; do echo "noisy output line number $i for truncation"; i=$((i+1)); done; exit 0;;
        *) echo "ok  example.test/pkg 0.01s"; exit 0;;
        esac
        """
        let url = directory.appendingPathComponent("go")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        setBehavior("pass")
    }

    func setBehavior(_ name: String) {
        try? name.write(to: directory.appendingPathComponent("behavior"), atomically: true, encoding: .utf8)
    }

    func setBenchOutput(_ text: String) {
        try? text.write(to: directory.appendingPathComponent("bench.txt"), atomically: true, encoding: .utf8)
    }

    var callLines: [String] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    var calls: Int { callLines.count }

    var path: String { directory.path + ":/usr/bin:/bin" }
}

func benchOutput(name: String = "BenchmarkEncode", nsPerOp: [Double], procs: Int = 8, cpu: String = "Test CPU") -> String {
    var lines = ["goos: darwin", "goarch: arm64", "pkg: example.test/pkg", "cpu: \(cpu)"]
    for value in nsPerOp {
        lines.append("\(name)-\(procs)\t1000\t\(value) ns/op\t16 B/op\t1 allocs/op")
    }
    lines.append("PASS")
    return lines.joined(separator: "\n") + "\n"
}

final class FakeTargets: TestTargetBackend, @unchecked Sendable {
    let all: [TestTarget]
    let outcomeOverride: Locked<BackendOutcome<[TestTarget]>?> = Locked(nil)

    init(_ all: [TestTarget]) {
        self.all = all
    }

    func targets(in packageScope: String) async -> BackendOutcome<[TestTarget]> {
        if let override = outcomeOverride.snapshot { return override }
        let matched = packageScope == "./..." ? all : all.filter { $0.package == packageScope }
        return matched.isEmpty ? .empty : .found(matched)
    }
}

final class FakeApprovals: ApprovalProvider, @unchecked Sendable {
    let cards = Locked<[ExecutionApprovalCard]>([])
    let queue = Locked<[ApprovalDecision]>([])
    let fallback = Locked<ApprovalDecision>(.allowOnce)
    let hangs = Locked<Bool>(false)

    func requestApproval(_ card: ExecutionApprovalCard) async -> ApprovalDecision {
        cards.with { $0.append(card) }
        if hangs.snapshot {
            try? await Task.sleep(for: .seconds(30))
            return .allowOnce
        }
        return queue.with { $0.isEmpty ? fallback.snapshot : $0.removeFirst() }
    }

    var requestCount: Int { cards.snapshot.count }
}

final class FakeDirtyBuffers: DirtyBufferProvider, @unchecked Sendable {
    let states = Locked<[BufferDiskState]>([])
    let decision = Locked<DirtyBufferDecision>(.runSavedVersion)
    let saveSucceeds = Locked<Bool>(true)
    let savedBatches = Locked<[[String]]>([])
    let promptCount = Locked<Int>(0)

    func bufferStates() async -> [BufferDiskState] { states.snapshot }

    func chooseAction(dirtyPaths: [String]) async -> DirtyBufferDecision {
        promptCount.with { $0 += 1 }
        return decision.snapshot
    }

    func save(paths: [String]) async -> Bool {
        savedBatches.with { $0.append(paths) }
        guard saveSucceeds.snapshot else { return false }
        states.with { all in
            all = all.map { paths.contains($0.path) ? BufferDiskState(path: $0.path, diskContentHash: $0.bufferContentHash, bufferContentHash: $0.bufferContentHash, documentVersion: $0.documentVersion) : $0 }
        }
        return true
    }

    func setDirty(_ path: String, disk: String = "disk-hash", buffer: String = "buffer-hash") {
        states.with { $0 = [BufferDiskState(path: path, diskContentHash: disk, bufferContentHash: buffer, documentVersion: 3)] }
    }
}

struct DiskFingerprints: SourceFingerprintProvider {
    let root: URL

    func diskHashes(moduleDirectory: String, package: String) async -> [String: String] {
        TestFiles.diskHashes(in: moduleDirectory.isEmpty ? root : root.appendingPathComponent(moduleDirectory))
    }
}

final class FakeProfileSource: ProfileSource, @unchecked Sendable {
    let infos = Locked<[AttachedProfileInfo]>([])
    let payloads = Locked<[String: ProfileDetailPayload]>([:])

    func attach(_ key: String, payload: ProfileDetailPayload, metadata: ProfileRunMetadata = .unknown, mapping: MappingConfidence = .unverified) {
        infos.with { list in
            list.removeAll { $0.sourceKey == key }
            list.append(AttachedProfileInfo(sourceKey: key, label: key, metadata: metadata, mapping: mapping))
        }
        payloads.with { $0[key] = payload }
    }

    func detach(_ key: String) {
        infos.with { $0.removeAll { $0.sourceKey == key } }
    }

    func attachedProfiles() async -> [AttachedProfileInfo] { infos.snapshot }

    func payload(sourceKey: String) async -> ProfileDetailPayload? { payloads.snapshot[sourceKey] }
}

struct EntrySpec {
    let function: String
    let flat: Int64
    let cum: Int64
    var file = "work.go"
    var line = 10
    var children: [String] = []
    var callers: [String] = []
}

func makePayload(mode: String = "cpu", sampleType: String = "cpu", unit: String = "nanoseconds", hash: String, total: Int64 = 1000, samples: Int = 100, skipped: Int = 0, truncated: Bool = false, before: Int? = nil, entries: [EntrySpec]) throws -> ProfileDetailPayload {
    let entryObjects: [[String: Any]] = entries.map {
        ["function": $0.function, "file": $0.file, "line": $0.line, "flat": $0.flat, "flatPercent": 0.0, "cum": $0.cum, "cumPercent": 0.0, "formattedFlat": "", "formattedCum": "", "children": $0.children, "callers": $0.callers, "count": 0]
    }
    let object: [String: Any] = [
        "contentSha256": hash, "mode": mode, "sampleType": sampleType, "unit": unit,
        "sampleTypes": [["type": sampleType, "unit": unit]],
        "totalValue": total, "sampleCount": samples, "skippedSamples": skipped, "zeroValueSamples": 0,
        "durationNanos": 3_000_000_000, "period": 10_000_000, "periodType": "cpu", "periodUnit": "nanoseconds",
        "truncated": truncated, "entriesBeforeCap": before ?? entries.count, "entryCap": 500, "entries": entryObjects
    ]
    return try JSONDecoder().decode(ProfileDetailPayload.self, from: JSONSerialization.data(withJSONObject: object))
}

func simpleEntries() -> [EntrySpec] {
    [
        EntrySpec(function: "pkg.Hot", flat: 600, cum: 700, callers: ["pkg.Run"]),
        EntrySpec(function: "pkg.Run", flat: 100, cum: 1000, children: ["pkg.Hot", "pkg.Cold"]),
        EntrySpec(function: "pkg.Cold", flat: 300, cum: 300, callers: ["pkg.Run"])
    ]
}

let knownMetadata = ProfileRunMetadata(workload: .known("bench make"), config: .known("cfg-1"), sourceHash: .known("src-1"), build: .known("go1.27.1"))

final class Harness: @unchecked Sendable {
    let workspaceID = UUID()
    let root: URL
    let fakeGo: FakeGo
    let grants: GrantStore
    let evidence = EvidenceStore()
    let arbiter = RunArbiter(executor: ProcessRunExecutor())
    let runs = RunResultStore()
    let profiles = ProfileRegistry()
    let approvals = FakeApprovals()
    let dirty = FakeDirtyBuffers()
    let targets: FakeTargets
    let profileSource = FakeProfileSource()
    let environment: [String: String]
    let snapshot: Locked<SourceSnapshot>
    var backends: ExecutionBackends

    init(trusted: Bool = true, denyRules: [PolicyDenyRule] = [], extraEnvironment: [String: String] = [:], targets: [TestTarget]? = nil, workspaceRoot: URL? = nil, realGo: Bool = false, sessionGrantMaxRuns: Int = 20) async throws {
        if let workspaceRoot {
            root = workspaceRoot
        } else {
            root = try TestFiles.makeTempDirectory("workspace")
            try "module example.test\n\ngo 1.22\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            try "package pkg\n".write(to: root.appendingPathComponent("a.go"), atomically: true, encoding: .utf8)
        }
        fakeGo = try FakeGo()
        let policy = PermissionPolicy(denyRules: denyRules, trustedWorkspaces: [])
        grants = GrantStore(policy: policy)
        if trusted { await grants.setTrusted(true, workspaceID: workspaceID) }
        var env = realGo ? EnvironmentBuilder().build(from: ProcessInfo.processInfo.environment) : ["PATH": fakeGo.path, "HOME": root.path]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
        self.targets = FakeTargets(targets ?? [
            TestTarget(package: "./pkg", name: "TestAlpha", kind: .test),
            TestTarget(package: "./pkg", name: "TestBeta", kind: .test),
            TestTarget(package: "./pkg", name: "BenchmarkEncode", kind: .benchmark),
            TestTarget(package: "./other", name: "TestGamma", kind: .test)
        ])
        snapshot = Locked(SourceSnapshot(id: "S1", workspaceID: workspaceID, buildTarget: "darwin/arm64", goVersion: "go1.22"))
        backends = ExecutionBackends(testTargets: self.targets, approvals: approvals, dirtyBuffers: dirty, fingerprints: DiskFingerprints(root: root), profiles: profileSource)
        sessionGrantMax = sessionGrantMaxRuns
    }

    let sessionGrantMax: Int

    func makeContext(environment override: [String: String]? = nil, backends custom: ExecutionBackends? = nil) -> ExecutionToolContext {
        let box = snapshot
        return ExecutionToolContext(
            workspaceID: workspaceID,
            workspaceRoot: root,
            snapshot: { box.snapshot },
            evidence: evidence,
            grants: grants,
            arbiter: arbiter,
            runs: runs,
            profiles: profiles,
            environment: override ?? environment,
            sessionGrantMaxRuns: sessionGrantMax,
            backends: custom ?? backends
        )
    }

    func registry(wave: GopilotWave = .w7, backends custom: ExecutionBackends? = nil, environment override: [String: String]? = nil) throws -> ToolRegistry {
        try ExecutionToolSet.makeRegistry(context: makeContext(environment: override, backends: custom), wave: wave)
    }

    func call(_ name: String, _ json: String, id: String = "call-1", environment override: [String: String]? = nil) async throws -> ToolResultEnvelope {
        await (try registry(environment: override)).dispatch(ToolCall(id: id, name: name, argumentsJSON: json))
    }

    func targetHash(extra: [String: String] = [:]) -> String {
        let current = snapshot.snapshot
        var parts: [String: String] = [
            "buildTarget": current.buildTarget ?? "",
            "goVersion": current.goVersion ?? "",
            "tags": current.tags.sorted().joined(separator: ",")
        ]
        for (key, value) in extra { parts[key] = value }
        return GopilotAnalysis.ContentHash.combined(parts)
    }

    func setSnapshot(id: String) {
        snapshot.with { current in
            current = SourceSnapshot(id: id, workspaceID: current.workspaceID, buildTarget: current.buildTarget, goVersion: current.goVersion)
        }
    }

    func grant(selector: String = "./pkg#TestAlpha", operation: PolicyOperation = .runTests, targetHash: String? = nil, snapshotHash: String? = nil, envNames: Set<String>? = nil, timeout: Int = 600, maxRuns: Int = 5, expiresAt: Date = Date().addingTimeInterval(600), workspace: UUID? = nil, runsUsed: Int = 0) async throws {
        let hash: String
        if let snapshotHash {
            hash = snapshotHash
        } else {
            let pkg = selector.components(separatedBy: "#").first ?? "./pkg"
            let hashes = await backends.fingerprints?.diskHashes(moduleDirectory: "", package: pkg) ?? [:]
            hash = GopilotAnalysis.ContentHash.combined(hashes)
        }
        try await grants.add(ExecutionGrant(
            workspaceID: workspace ?? workspaceID,
            operation: operation,
            selector: selector,
            targetConfigHash: targetHash ?? self.targetHash(),
            workspaceSnapshotHash: hash,
            envNames: envNames ?? Set(environment.keys),
            timeoutSeconds: timeout,
            maxRuns: maxRuns,
            expiresAt: expiresAt,
            ownerActionID: "test-grant",
            runsUsed: runsUsed
        ))
    }

    func cleanup() async {
        await arbiter.shutdown()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: fakeGo.directory)
    }
}

func decode(_ envelope: ToolResultEnvelope) -> [String: Any] {
    guard let data = envelope.data.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

func nestedList(_ object: [String: Any], _ key: String) -> [[String: Any]] {
    object[key] as? [[String: Any]] ?? []
}
