import Foundation
import XCTest
import GopilotProvider
@testable import GopilotCompletion

final class LiveFIMProbeTests: XCTestCase {
    func testLiveEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LIVE_FIM_CHAT_URL"], let url = URL(string: base), let key = env["LIVE_FIM_KEY"], let model = env["LIVE_FIM_MODEL"] else {
            throw XCTSkip("live endpoint not configured")
        }
        let template = FIMTemplate(rawValue: env["LIVE_FIM_TEMPLATE"] ?? "qwen") ?? .qwen
        let transport = URLSessionTransport()
        for stream in [true, false] {
            let endpoint = CompletionEndpoint(chatCompletionsURL: url, apiKey: key, options: CompletionRequestOptions(model: model, dialect: .fillInTheMiddle, stream: stream, fimTemplate: template))
            let report = await CompletionProbe(transport: transport, userAgent: "GoLens/live-probe").run(endpoint: endpoint)
            print("LIVE probe stream=\(stream) url=\(endpoint.url.absoluteString) -> \(report)")
        }
        let prefix = "package store\n\nimport (\n\t\"errors\"\n\t\"sync\"\n)\n\nvar ErrNotFound = errors.New(\"not found\")\n\ntype Store struct {\n\tmu   sync.RWMutex\n\tdata map[string]string\n}\n\n// Get returns the value for key or ErrNotFound.\nfunc (s *Store) Get(key string) (string, error) {\n\t"
        let suffix = "\n}\n"
        let built = CompletionContextBuilder(pathPolicy: nil).build(CompletionSnapshot(relativePath: "store.go", prefix: prefix, suffix: suffix, prefixStartsAtFileStart: true, suffixEndsAtFileEnd: true))
        guard let context = built.context else { return XCTFail("context skipped: \(String(describing: built.skipReason))") }
        let service = CompletionService(client: CompletionClient(transport: transport, userAgent: "GoLens/live-probe", timeoutSeconds: 15))
        for stream in [true, false] {
            let endpoint = CompletionEndpoint(chatCompletionsURL: url, apiKey: key, options: CompletionRequestOptions(model: model, dialect: .fillInTheMiddle, stream: stream, fimTemplate: template))
            let outcome = await service.suggest(context: context, endpoint: endpoint, useCache: false)
            print("LIVE Store.Get stream=\(stream) -> \(outcome)")
        }
    }
}
