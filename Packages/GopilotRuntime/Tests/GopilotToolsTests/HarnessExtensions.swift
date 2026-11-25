import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
import GopilotStore
@testable import GopilotTools

func withHarness(trusted: Bool = true, denyRules: [PolicyDenyRule] = [], extraEnvironment: [String: String] = [:], targets: [TestTarget]? = nil, workspaceRoot: URL? = nil, realGo: Bool = false, sessionGrantMaxRuns: Int = 20, body: (Harness) async throws -> Void) async throws {
    let harness = try await Harness(trusted: trusted, denyRules: denyRules, extraEnvironment: extraEnvironment, targets: targets, workspaceRoot: workspaceRoot, realGo: realGo, sessionGrantMaxRuns: sessionGrantMaxRuns)
    do {
        try await body(harness)
    } catch {
        await harness.cleanup()
        throw error
    }
    await harness.cleanup()
}

extension Harness {
    func attachMemory(workspace: UUID? = nil) throws -> MemoryStore {
        let directory = try TestFiles.makeTempDirectory("memory")
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json"), workspaceID: workspace ?? workspaceID, fileSystem: LocalFileSystem())
        backends.memory = store
        return store
    }

    func attachPatch(files: [String: String] = [:], secretCheck: @escaping @Sendable (String) -> Bool = { SecretFilter().containsSecret($0) }) throws -> PatchProposalStore {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let base = root
        let validation = PatchValidationContext(
            pathCheck: { _ in .ok },
            secretCheck: secretCheck,
            pathExists: { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
        )
        let store = PatchProposalStore(validation: validation)
        backends.patch = PatchBackend(store: store, currentFile: { path in
            let url = base.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
            return CurrentFileState(exists: true, text: text, documentVersion: 1)
        })
        return store
    }

    func waitForCalls(_ count: Int, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fakeGo.calls >= count { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return fakeGo.calls >= count
    }
}
