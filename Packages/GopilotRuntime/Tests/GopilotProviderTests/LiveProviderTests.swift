import Foundation
import Testing
import GopilotRuntime
@testable import GopilotProvider

private struct LiveEnvironment {
    let baseURL: String
    let model: String
    let key: String

    static func load() -> LiveEnvironment? {
        guard let path = ProcessInfo.processInfo.environment["GOPILOT_LIVE_ENV_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let base = values["GOPILOT_LIVE_BASE_URL"], let model = values["GOPILOT_LIVE_MODEL"], let key = values["GOPILOT_LIVE_KEY"] else { return nil }
        return LiveEnvironment(baseURL: base, model: model, key: key)
    }
}

private let liveAvailable = LiveEnvironment.load() != nil

@Suite("Live provider", .enabled(if: liveAvailable), .serialized)
struct LiveProviderTests {
    private func makeProvider(_ env: LiveEnvironment, streaming: Bool?) -> (OpenAICompatibleProvider, ProviderConfiguration) {
        let reference = CredentialReference(profileID: "live-test")
        let configuration = ProviderConfiguration(
            id: "live-test",
            displayName: "Live",
            baseURL: env.baseURL,
            modelID: env.model,
            credentialReference: reference,
            declaredCapabilities: [.text, .streaming, .tools],
            outputTokenLimit: 512
        )
        let store = InMemoryCredentialStore([reference: env.key])
        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentials: store,
            transport: URLSessionTransport(),
            streamingOverride: streaming
        )
        return (provider, configuration)
    }

    @Test func connectionReport() async throws {
        let env = try #require(LiveEnvironment.load())
        let redactor = Redactor(secrets: [env.key])
        let (streaming, configuration) = makeProvider(env, streaming: true)
        let (nonStreaming, _) = makeProvider(env, streaming: false)
        let report = await ConnectionTester().run(streaming: streaming, nonStreaming: nonStreaming, configHash: configuration.capabilityHash)

        for check in report.checks {
            print("LIVE \(check.id.rawValue): \(check.outcome.rawValue) - \(redactor.redact(check.detail))")
        }
        print("LIVE agentMode: \(report.agentMode)")
        #expect(report.outcome(.text) == .pass)
    }

    @Test func runtimeAnswersThroughRealProvider() async throws {
        let env = try #require(LiveEnvironment.load())
        let (provider, _) = makeProvider(env, streaming: true)
        let runtime = GopilotRuntime(provider: provider, systemPrompt: "You are a concise assistant.")
        let stream = try await runtime.startTurn(prompt: "Reply with exactly one word: pong")
        var text = ""
        var terminal: AgentEventKind?
        for await event in stream {
            if event.kind == .textDelta { text += event.payload["text"] ?? "" }
            if event.kind.isTerminal { terminal = event.kind }
        }
        print("LIVE reply length: \(text.count), terminal: \(String(describing: terminal))")
        #expect(terminal == .turnCompleted)
        #expect(!text.isEmpty)
        #expect(!text.contains(env.key))
    }

    @Test func wrongKeyIsRejectedWithoutLeak() async throws {
        let env = try #require(LiveEnvironment.load())
        var bad = env
        bad = LiveEnvironment(baseURL: env.baseURL, model: env.model, key: "sk-invalid-canary-0000")
        let (provider, _) = makeProvider(bad, streaming: true)
        let runtime = GopilotRuntime(provider: provider)
        let stream = try await runtime.startTurn(prompt: "hi")
        var failure: [String: String] = [:]
        for await event in stream where event.kind == .turnFailed { failure = event.payload }
        print("LIVE wrong key code: \(failure["code"] ?? "none")")
        #expect(failure["code"] == "unauthorized")
        #expect(!(failure["message"] ?? "").contains("sk-invalid-canary-0000"))
    }
}
