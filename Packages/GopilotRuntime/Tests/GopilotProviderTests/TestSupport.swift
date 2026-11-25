import Foundation
import GopilotRuntime
@testable import GopilotProvider

let canaryKey = "sk-canary-7f3a9c1e5b2d48a6"

func makeConfiguration(
    baseURL: String = "https://api.example.test/v1",
    modelID: String = "test-model",
    reference: CredentialReference? = CredentialReference(profileID: "test-profile"),
    local: Bool = false,
    timeouts: ProviderTimeouts = ProviderTimeouts(idleSeconds: 5, requestSeconds: 30)
) -> ProviderConfiguration {
    ProviderConfiguration(
        id: "test-profile",
        displayName: "Test",
        baseURL: baseURL,
        modelID: modelID,
        credentialReference: reference,
        declaredCapabilities: [.text, .streaming, .tools],
        outputTokenLimit: 512,
        timeouts: timeouts,
        localEndpoint: local
    )
}

func makeCredentials() -> InMemoryCredentialStore {
    InMemoryCredentialStore([CredentialReference(profileID: "test-profile"): canaryKey])
}

func makeProvider(
    transport: HTTPTransport,
    configuration: ProviderConfiguration = makeConfiguration(),
    profile: CapabilityProfile = CapabilityProfile(),
    streaming: Bool? = nil,
    clock: ManualClock = ManualClock(),
    retry: RetryPolicy = RetryPolicy()
) -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
        configuration: configuration,
        credentials: makeCredentials(),
        transport: transport,
        profile: profile,
        streamingOverride: streaming,
        retryPolicy: retry,
        clock: clock,
        jitter: { 0 }
    )
}

struct CollectedStream {
    var events: [ProviderEvent] = []
    var error: Error?
}

func collect(_ stream: AsyncThrowingStream<ProviderEvent, Error>) async -> CollectedStream {
    var result = CollectedStream()
    do {
        for try await event in stream {
            result.events.append(event)
        }
    } catch {
        result.error = error
    }
    return result
}

let userRequest = ProviderRequest(messages: [ModelMessage(role: .user, content: "hello")], tools: [])

let readCanaryTool = ToolSchema(
    name: "read_canary",
    description: "Reads a synthetic value.",
    parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
)

func sseChunk(_ json: String) -> String {
    "data: \(json)\n\n"
}

func textChunk(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return sseChunk(#"{"choices":[{"index":0,"delta":{"content":"\#(escaped)"},"finish_reason":null}]}"#)
}

func finishChunk(_ reason: String) -> String {
    sseChunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"\#(reason)"}]}"#)
}

let simpleTextStream = textChunk("Hi") + textChunk(" there") + finishChunk("stop") + "data: [DONE]\n\n"
