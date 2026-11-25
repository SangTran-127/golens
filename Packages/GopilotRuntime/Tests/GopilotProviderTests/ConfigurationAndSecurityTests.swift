import Foundation
import Security
import Testing
import GopilotRuntime
@testable import GopilotProvider

@Suite("Provider configuration")
struct ProviderConfigurationTests {
    @Test func endpointIsBaseURLPlusChatCompletionsWithoutAutoAppendingV1() throws {
        #expect(try makeConfiguration(baseURL: "https://api.example.test/v1").chatCompletionsURL().absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(try makeConfiguration(baseURL: "https://api.example.test/v1/").chatCompletionsURL().absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(try makeConfiguration(baseURL: "https://api.example.test").chatCompletionsURL().absoluteString == "https://api.example.test/chat/completions")
        #expect(try makeConfiguration(baseURL: "https://api.example.test/openai/deployments/x").chatCompletionsURL().absoluteString == "https://api.example.test/openai/deployments/x/chat/completions")
        #expect(try makeConfiguration(baseURL: "  https://api.example.test:8443/api/v2  ").chatCompletionsURL().absoluteString == "https://api.example.test:8443/api/v2/chat/completions")
        #expect(makeConfiguration(baseURL: "https://api.example.test/v1").previewURL == "https://api.example.test/v1/chat/completions")
    }

    @Test func httpIsRefusedUnlessLocalhostAndLocalFlagBothHold() throws {
        let remote = makeConfiguration(baseURL: "http://api.example.test/v1", local: true)
        #expect(throws: ProviderConfigurationError.insecureScheme) { try remote.chatCompletionsURL() }
        let lookalike = makeConfiguration(baseURL: "http://localhost.evil.test/v1", local: true)
        #expect(throws: ProviderConfigurationError.insecureScheme) { try lookalike.chatCompletionsURL() }
        let localWithoutFlag = makeConfiguration(baseURL: "http://localhost:1234/v1", local: false)
        #expect(throws: ProviderConfigurationError.insecureScheme) { try localWithoutFlag.chatCompletionsURL() }
        let ftp = makeConfiguration(baseURL: "ftp://localhost/v1", local: true)
        #expect(throws: ProviderConfigurationError.insecureScheme) { try ftp.chatCompletionsURL() }

        for base in ["http://localhost:1234/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1", "HTTP://LOCALHOST/v1"] {
            let configuration = makeConfiguration(baseURL: base, local: true)
            #expect(throws: Never.self, "\(base)") { try configuration.chatCompletionsURL() }
        }
        #expect(makeConfiguration(baseURL: "http://[::1]:8080/v1", local: true).previewURL == "http://[::1]:8080/v1/chat/completions")
        #expect(makeConfiguration(baseURL: "https://localhost:8443/v1").previewURL == "https://localhost:8443/v1/chat/completions")
    }

    @Test func urlsCarryingSecretsAreRejectedAndPreviewNeverShowsThem() {
        for base in ["https://user:hunter2@api.example.test/v1", "https://api.example.test/v1?api_key=hunter2", "https://api.example.test/v1#hunter2"] {
            let configuration = makeConfiguration(baseURL: base)
            #expect(throws: ProviderConfigurationError.unsupportedURLComponents) { try configuration.chatCompletionsURL() }
            #expect(configuration.previewURL == "")
            #expect(!configuration.previewURL.contains("hunter2"))
        }
        #expect(throws: ProviderConfigurationError.invalidURL) { try makeConfiguration(baseURL: "not a url").chatCompletionsURL() }
        #expect(throws: ProviderConfigurationError.missingModel) { try makeConfiguration(modelID: "  ").validate() }
    }

    @Test func configurationHoldsNoSecretsAndRoundTripsThroughCodable() throws {
        var configuration = makeConfiguration()
        configuration.authHeaderName = "X-Api-Key"
        configuration.pricing = ProviderPricing(modelID: "test-model", inputPerMillionTokens: 1, outputPerMillionTokens: 2, capturedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(configuration)
        #expect(!String(decoding: data, as: UTF8.self).contains(canaryKey))
        #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: data) == configuration)
    }

    @Test func hostOrModelChangeInvalidatesCapabilityProfile() {
        let original = makeConfiguration()
        let hash = original.capabilityHash
        var profile = CapabilityProfile()
        let now = Date(timeIntervalSince1970: 5_000)
        profile.set(.tools, .verified, configHash: hash, at: now)
        profile.set(.text, .verified, configHash: hash, at: now)
        profile.set(.strictSchema, .unsupported, configHash: hash, at: now)

        #expect(original.capabilityHash == makeConfiguration().capabilityHash)
        #expect(profile.isVerified(.tools, configHash: hash))
        #expect(original.agentMode(using: profile) == .agent)

        let otherHost = makeConfiguration(baseURL: "https://other.example.test/v1")
        let otherModel = makeConfiguration(modelID: "another-model")
        let otherPath = makeConfiguration(baseURL: "https://api.example.test/v2")
        var otherHeader = makeConfiguration()
        otherHeader.authHeaderName = "X-Api-Key"
        for changed in [otherHost, otherModel, otherPath, otherHeader] {
            #expect(changed.capabilityHash != hash)
            #expect(profile.state(of: .tools, configHash: changed.capabilityHash) == .unknown)
            #expect(!profile.isVerified(.tools, configHash: changed.capabilityHash))
            #expect(changed.agentMode(using: profile) == .unavailable)
            #expect(profile.invalidated(for: changed.capabilityHash).records.isEmpty)
        }
        #expect(profile.invalidated(for: hash).records.count == 3)
        #expect(profile.state(of: .parallelToolCalls, configHash: hash) == .unknown)
        #expect(profile.record(for: .strictSchema, configHash: hash)?.state == .unsupported)
        #expect(profile.record(for: .tools, configHash: hash)?.checkedAt == now)
    }

    @Test func profileOverwritesPreviousRecordForSameCapability() {
        var profile = CapabilityProfile()
        profile.set(.tools, .unsupported, configHash: "a", at: Date())
        profile.set(.tools, .verified, configHash: "b", at: Date())
        #expect(profile.records.count == 1)
        #expect(profile.state(of: .tools, configHash: "a") == .unknown)
        #expect(profile.state(of: .tools, configHash: "b") == .verified)
    }

    @Test func gatewayAndRouteIsolateCapabilityProfilesAndBuildProviderConfiguration() throws {
        let gateway = GatewayConfiguration(
            id: "gw-1",
            displayName: "Primary Gateway",
            baseURL: "https://api.example.test/v1",
            credentialReference: CredentialReference(profileID: "test-profile")
        )
        #expect(try gateway.chatCompletionsURL().absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(try gateway.modelsURL().absoluteString == "https://api.example.test/v1/models")
        #expect(try makeConfiguration(baseURL: "https://api.example.test/v1").modelsURL().absoluteString == "https://api.example.test/v1/models")

        let fastRoute = ModelRoute(
            id: "go-fast",
            displayName: "Go Fast",
            contextWindowTokens: 64_000,
            outputTokenLimit: 1024,
            reasoningMode: .defaultOnly
        )
        let deepRoute = ModelRoute(
            id: "go-deep",
            displayName: "Go Deep",
            contextWindowTokens: 128_000,
            outputTokenLimit: 4096,
            reasoningMode: .openAIChatEffort(supported: [.low, .medium, .high]),
            isManual: true
        )

        let fastHash = fastRoute.capabilityHash(for: gateway)
        let deepHash = deepRoute.capabilityHash(for: gateway)
        #expect(fastHash != deepHash)
        #expect(fastRoute.capabilityHash(for: gateway, dialect: "responses") != fastHash)

        let fastConfig = fastRoute.configuration(for: gateway)
        #expect(fastConfig.modelID == "go-fast")
        #expect(fastConfig.baseURL == gateway.baseURL)
        #expect(fastConfig.credentialReference == gateway.credentialReference)
        #expect(fastConfig.capabilityHash == fastHash)
        #expect(fastConfig.capabilityHash(routeOverride: "go-deep") == deepHash)

        var profile = CapabilityProfile()
        let now = Date(timeIntervalSince1970: 10_000)
        profile.setScoped(.text, .verified, configHash: fastHash, at: now)
        profile.setScoped(.tools, .verified, configHash: fastHash, at: now)
        profile.setScoped(.text, .verified, configHash: deepHash, at: now)
        profile.setScoped(.tools, .unsupported, configHash: deepHash, at: now)

        #expect(fastRoute.agentMode(for: gateway, using: profile) == .agent)
        #expect(deepRoute.agentMode(for: gateway, using: profile) == .chatOnly)

        var otherGateway = gateway
        otherGateway.baseURL = "https://other.example.test/v1"
        #expect(fastRoute.capabilityHash(for: otherGateway) != fastHash)
        #expect(fastRoute.agentMode(for: otherGateway, using: profile) == .unavailable)
    }

    @Test func reasoningConfigModeHelpersAndBackwardCompatibleDecoding() throws {
        let defaultOnly = ReasoningConfigMode.defaultOnly
        #expect(defaultOnly.supportedEfforts == [.default])
        #expect(defaultOnly.supportsEffort(.default))
        #expect(!defaultOnly.supportsEffort(.high))
        #expect(!defaultOnly.preservesReasoningContinuation)

        let openAI = ReasoningConfigMode.openAIChatEffort(supported: [.low, .high, .low, .default])
        #expect(openAI.supportedEfforts == [.default, .low, .high])
        #expect(openAI.supportsEffort(.default))
        #expect(openAI.supportsEffort(.low))
        #expect(openAI.supportsEffort(.high))
        #expect(!openAI.supportsEffort(.medium))
        #expect(!openAI.preservesReasoningContinuation)

        let deepSeek = ReasoningConfigMode.deepSeekThinking(preserveReasoningContentInToolLoop: true)
        #expect(deepSeek.supportedEfforts == [.default])
        #expect(deepSeek.supportsEffort(.default))
        #expect(!deepSeek.supportsEffort(.high))
        #expect(deepSeek.preservesReasoningContinuation)

        let legacyJSON = #"""
        {
          "id": "legacy",
          "displayName": "Legacy",
          "baseURL": "https://api.example.test/v1",
          "modelID": "gpt-4o",
          "declaredCapabilities": ["text", "streaming"],
          "outputTokenLimit": 2048,
          "maxTokensParameter": "max_tokens",
          "timeouts": {"idleSeconds": 30, "requestSeconds": 90},
          "localEndpoint": false
        }
        """#
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(decoded.reasoningMode == .defaultOnly)
    }

    @Test func modelCatalogClientParsesModelsAndHandlesErrorsForManualFallback() async throws {
        let gateway = GatewayConfiguration(
            id: "gw",
            displayName: "Gateway",
            baseURL: "https://api.example.test/v1",
            credentialReference: CredentialReference(profileID: "test-profile")
        )
        let catalogJSON = #"{"object":"list","data":[{"id":"go-deep"},{"id":"deepseek-chat"},{"id":"go-fast"},{"id":"go-deep"},{"id":"  "}]}"#
        let okTransport = MockTransport([.json(catalogJSON)])
        let client = ModelCatalogClient(transport: okTransport, credentials: makeCredentials())
        let models = try await client.fetchModelIDs(for: gateway)
        #expect(models == ["deepseek-chat", "go-deep", "go-fast"])

        let request = try #require(okTransport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.example.test/v1/models")
        #expect(request.headerValue("Authorization") == "Bearer \(canaryKey)")

        let notFoundTransport = MockTransport([.json(#"{"error":"not found \#(canaryKey)"}"#, status: 404)])
        let notFoundClient = ModelCatalogClient(transport: notFoundTransport, credentials: makeCredentials())
        do {
            _ = try await notFoundClient.fetchModelIDs(for: gateway)
            Issue.record("Expected 404 catalog error")
        } catch let error as ProviderError {
            guard case .malformedResponse(let msg) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(msg.contains("manual"))
            #expect(!msg.contains(canaryKey))
        }

        let unauthTransport = MockTransport([.json("{}", status: 401)])
        let unauthClient = ModelCatalogClient(transport: unauthTransport, credentials: makeCredentials())
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await unauthClient.fetchModelIDs(for: gateway)
        }

        let offlineTransport = MockTransport([.connectionFailure()])
        let offlineClient = ModelCatalogClient(transport: offlineTransport, credentials: makeCredentials())
        await #expect(throws: ProviderError.offline) {
            _ = try await offlineClient.fetchModelIDs(for: gateway)
        }
    }

    @Test func modelCatalogClientParsesLiteLLMModelInfoAndFallsBackToModels() async throws {
        let gateway = GatewayConfiguration(
            id: "gw",
            displayName: "LiteLLM Gateway",
            baseURL: "https://api.example.test/v1",
            credentialReference: CredentialReference(profileID: "test-profile")
        )
        let modelInfoJSON = #"""
        {
          "data": [
            {
              "model_name": "nano/sonnet-5.5",
              "model_info": {
                "model_provider": "anthropic",
                "api_provider": "nanogpt",
                "display_name": "Claude Sonnet 5.5",
                "icon": "anthropic",
                "ide_role": "coding",
                "max_tokens": 200000,
                "supports_function_calling": true,
                "supports_vision": true,
                "supports_reasoning": true
              }
            },
            {
              "model_name": "deepseek/v4.1-flash",
              "model_info": {
                "model_provider": "deepseek",
                "api_provider": "9r",
                "display_name": "DeepSeek V4.1 Flash",
                "icon": "deepseek",
                "ide_role": "coding",
                "max_tokens": 64000,
                "supports_function_calling": true,
                "supports_vision": false,
                "supports_reasoning": true
              }
            }
          ]
        }
        """#
        let infoTransport = MockTransport([.json(modelInfoJSON)])
        let infoClient = ModelCatalogClient(transport: infoTransport, credentials: makeCredentials())
        let entries = try await infoClient.fetchCatalog(for: gateway)
        #expect(entries.count == 2)
        #expect(entries[0] == CatalogModelEntry(
            id: "nano/sonnet-5.5",
            displayName: "Claude Sonnet 5.5",
            modelProvider: "anthropic",
            apiProvider: "nanogpt",
            icon: "anthropic",
            ideRole: "coding",
            maxTokens: 200_000,
            maxInputTokens: nil,
            maxOutputTokens: 200_000,
            supportsFunctionCalling: true,
            supportsVision: true,
            supportsReasoning: true
        ))
        #expect(entries[1].id == "deepseek/v4.1-flash")
        #expect(entries[1].displayName == "DeepSeek V4.1 Flash")
        #expect(entries[1].modelProvider == "deepseek")
        #expect(entries[1].apiProvider == "9r")
        #expect(entries[1].icon == "deepseek")

        // When /v1/model/info returns 404, it tries root /model/info next
        let rootFallbackTransport = MockTransport([
            .json(#"{"error":"not found"}"#, status: 404),
            .json(modelInfoJSON)
        ])
        let rootFallbackClient = ModelCatalogClient(transport: rootFallbackTransport, credentials: makeCredentials())
        let rootEntries = try await rootFallbackClient.fetchCatalog(for: gateway)
        #expect(rootEntries.count == 2)
        #expect(rootFallbackTransport.requests.map(\.url.absoluteString) == [
            "https://api.example.test/v1/model/info",
            "https://api.example.test/model/info"
        ])

        // When both /model/info endpoints return 404, it falls back to /v1/models
        let modelsFallbackTransport = MockTransport([
            .json(#"{"error":"not found"}"#, status: 404),
            .json(#"{"error":"not found"}"#, status: 404),
            .json(#"{"object":"list","data":[{"id":"gpt-4.1"}]}"#)
        ])
        let modelsFallbackClient = ModelCatalogClient(transport: modelsFallbackTransport, credentials: makeCredentials())
        let fallbackEntries = try await modelsFallbackClient.fetchCatalog(for: gateway)
        #expect(fallbackEntries == [CatalogModelEntry(id: "gpt-4.1")])
    }
}

private final class RedirectStub: URLProtocol {
    nonisolated(unsafe) static var seen: [(host: String, path: String, headers: [String: String])] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { seen = [] } }
    static var snapshot: [(host: String, path: String, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host
        return host?.hasSuffix(".redirect.test") == true || (host == "127.0.0.1" && request.url?.port == 11434)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.lock.withLock { Self.seen.append((url.host ?? "", url.path, headers)) }
        if url.path.hasPrefix("/hop/") {
            let target = String(url.path.dropFirst("/hop/".count))
            var next = request
            next.url = URL(string: "https://\(target)/landing")
            let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": next.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Redirects and transport security", .serialized)
struct RedirectTests {
    private func makeTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        return URLSessionTransport(configuration: configuration)
    }

    private func send(to url: String, transport: URLSessionTransport) async throws -> String {
        let request = HTTPRequest(
            url: URL(string: url)!,
            headers: ["Authorization": "Bearer \(canaryKey)", "X-Api-Key": canaryKey, "Content-Type": "application/json"],
            body: Data("{}".utf8),
            sensitiveHeaderNames: ["authorization", "x-api-key"],
            timeout: 10
        )
        let response = try await transport.send(request)
        var text = ""
        for try await chunk in response.body {
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text
    }

    @Test func crossOriginRedirectDropsAuthorizationAndCustomSecretHeader() async throws {
        RedirectStub.reset()
        let text = try await send(to: "https://origin.redirect.test/hop/elsewhere.redirect.test", transport: makeTransport())
        #expect(text.contains("landed"))
        let seen = RedirectStub.snapshot
        let first = try #require(seen.first { $0.host == "origin.redirect.test" })
        let landing = try #require(seen.first { $0.host == "elsewhere.redirect.test" })
        #expect(first.headers["Authorization"] == "Bearer \(canaryKey)")
        #expect(landing.headers.keys.map { $0.lowercased() }.contains("authorization") == false)
        #expect(landing.headers.keys.map { $0.lowercased() }.contains("x-api-key") == false)
        #expect(landing.headers["Content-Type"] == "application/json")
    }

    @Test func sameOriginRedirectKeepsAuthorization() async throws {
        RedirectStub.reset()
        _ = try await send(to: "https://origin.redirect.test/hop/origin.redirect.test", transport: makeTransport())
        let landing = try #require(RedirectStub.snapshot.last)
        #expect(landing.path == "/landing")
        #expect(landing.headers["Authorization"] == "Bearer \(canaryKey)")
    }

    @Test func differentPortOrSchemeCountsAsCrossOrigin() {
        let base = URL(string: "https://api.example.test/v1")!
        #expect(RedirectPolicy.sameOrigin(base, URL(string: "https://api.example.test:443/x")!))
        #expect(RedirectPolicy.sameOrigin(base, URL(string: "HTTPS://API.EXAMPLE.TEST/x")!))
        #expect(!RedirectPolicy.sameOrigin(base, URL(string: "https://api.example.test:8443/x")!))
        #expect(!RedirectPolicy.sameOrigin(base, URL(string: "http://api.example.test/x")!))
        #expect(!RedirectPolicy.sameOrigin(base, URL(string: "https://evil.example.test/x")!))

        var downgraded = URLRequest(url: URL(string: "http://api.example.test/x")!)
        downgraded.setValue("Bearer \(canaryKey)", forHTTPHeaderField: "Authorization")
        let sanitized = RedirectPolicy.sanitized(downgraded, from: base, sensitiveHeaderNames: [])
        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func unconsentedRemoteHostIsBlockedBeforeSendingAndLoopbackIsExempt() async throws {
        RedirectStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let transport = URLSessionTransport(configuration: configuration) { url in
            OutboundHostConsent.normalizedHost(for: url) == "allowed.redirect.test"
        }

        do {
            _ = try await send(to: "https://unconsented.redirect.test/v1/chat/completions", transport: transport)
            Issue.record("expected unconsented remote request to throw consentRequired")
        } catch ProviderError.consentRequired(let host) {
            #expect(host == "unconsented.redirect.test")
        }
        #expect(RedirectStub.snapshot.isEmpty)

        let allowedText = try await send(to: "https://allowed.redirect.test/v1/models", transport: transport)
        #expect(allowedText.contains("landed"))
        #expect(RedirectStub.snapshot.count == 1)

        let loopbackText = try await send(to: "http://127.0.0.1:11434/v1/models", transport: transport)
        #expect(loopbackText.contains("landed"))
    }

    @Test func redirectToUnconsentedHostIsBlocked() async throws {
        RedirectStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let transport = URLSessionTransport(configuration: configuration) { url in
            OutboundHostConsent.normalizedHost(for: url) == "allowed.redirect.test"
        }

        do {
            _ = try await send(to: "https://allowed.redirect.test/hop/unconsented.redirect.test", transport: transport)
            Issue.record("expected redirect to unconsented remote host to fail with consentRequired")
        } catch ProviderError.consentRequired(let host) {
            #expect(host == "unconsented.redirect.test")
        }
        #expect(RedirectStub.snapshot.allSatisfy { $0.host == "allowed.redirect.test" })
    }
}

@Suite("Credential stores")
struct CredentialStoreTests {
    private func uniquePrefix() -> String {
        "app.golens.gopilot.tests.\(UUID().uuidString)"
    }

    @Test func inMemoryStoreReadWriteDelete() throws {
        let store = InMemoryCredentialStore()
        let reference = CredentialReference(profileID: "p1")
        #expect(throws: CredentialError.notFound) { try store.read(reference) }
        try store.write("one", for: reference)
        #expect(try store.read(reference) == "one")
        try store.write("two", for: reference)
        #expect(try store.read(reference) == "two")
        try store.delete(reference)
        #expect(throws: CredentialError.notFound) { try store.read(reference) }
        try store.delete(reference)
    }

    @Test func keychainStatusMapping() {
        #expect(KeychainCredentialStore.mapStatus(errSecItemNotFound) == .notFound)
        #expect(KeychainCredentialStore.mapStatus(errSecInteractionNotAllowed) == .locked)
        #expect(KeychainCredentialStore.mapStatus(errSecAuthFailed) == .denied)
        #expect(KeychainCredentialStore.mapStatus(errSecUserCanceled) == .denied)
        #expect(KeychainCredentialStore.mapStatus(errSecNoAccessForItem) == .denied)
        #expect(KeychainCredentialStore.mapStatus(errSecParam) == .unexpected(status: errSecParam))
        #expect(!"\(CredentialError.unexpected(status: -50))".contains(canaryKey))
    }

    @Test func serviceIsNamespacedPerProviderProfile() {
        let store = KeychainCredentialStore(servicePrefix: "prefix")
        #expect(store.service(for: CredentialReference(profileID: "a")) == "prefix.a")
        #expect(store.service(for: CredentialReference(profileID: "b")) == "prefix.b")
        #expect(store.service(for: CredentialReference(profileID: "a")) != store.service(for: CredentialReference(profileID: "b")))
    }

    @Test func localFileCredentialStoreRoundTripWithCleanup() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopilot-cred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = LocalFileCredentialStore(fileURL: tempURL)
        let first = CredentialReference(profileID: "profile-a")
        let second = CredentialReference(profileID: "profile-b")

        try store.write(canaryKey, for: first)
        #expect(try store.read(first) == canaryKey)
        #expect(throws: CredentialError.notFound) { try store.read(second) }

        try store.write("rotated", for: first)
        #expect(try store.read(first) == "rotated")
        try store.write("other-profile", for: second)
        #expect(try store.read(first) == "rotated")
        #expect(try store.read(second) == "other-profile")

        try store.delete(first)
        #expect(throws: CredentialError.notFound) { try store.read(first) }
        #expect(try store.read(second) == "other-profile")
        try store.delete(first)
    }

    @Test func realKeychainRoundTripWithCleanup() throws {
        guard ProcessInfo.processInfo.environment["GOPILOT_TEST_REAL_KEYCHAIN"] == "1" else {
            return
        }
        let store = KeychainCredentialStore(servicePrefix: uniquePrefix())
        let first = CredentialReference(profileID: "profile-a")
        let second = CredentialReference(profileID: "profile-b")
        defer {
            try? store.delete(first)
            try? store.delete(second)
        }
        do {
            try store.write(canaryKey, for: first)
        } catch let error as CredentialError {
            Issue.record("Keychain write unavailable in this environment: \(error). Error mapping is covered by keychainStatusMapping.")
            return
        }
        #expect(try store.read(first) == canaryKey)
        #expect(throws: CredentialError.notFound) { try store.read(second) }

        try store.write("rotated", for: first)
        #expect(try store.read(first) == "rotated")
        try store.write("other-profile", for: second)
        #expect(try store.read(first) == "rotated")
        #expect(try store.read(second) == "other-profile")

        try store.delete(first)
        #expect(throws: CredentialError.notFound) { try store.read(first) }
        #expect(try store.read(second) == "other-profile")
        try store.delete(first)
    }

    @Test func credentialStoreFeedsTheProviderAuthorizationHeader() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopilot-cred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store: any CredentialStore = ProcessInfo.processInfo.environment["GOPILOT_TEST_REAL_KEYCHAIN"] == "1"
            ? KeychainCredentialStore(servicePrefix: uniquePrefix())
            : LocalFileCredentialStore(fileURL: tempURL)
        let reference = CredentialReference(profileID: "test-profile")
        defer { try? store.delete(reference) }
        try store.write(canaryKey, for: reference)
        let transport = MockTransport([.sse(simpleTextStream)])
        let provider = OpenAICompatibleProvider(configuration: makeConfiguration(), credentials: store, transport: transport)
        let result = await collect(provider.stream(userRequest))
        #expect(result.error == nil)
        #expect(transport.requests.first?.headerValue("Authorization") == "Bearer \(canaryKey)")
    }
}
