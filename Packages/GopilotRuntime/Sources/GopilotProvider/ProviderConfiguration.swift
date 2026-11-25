import Foundation
import GopilotRuntime

public enum ProviderCapability: String, CaseIterable, Sendable, Codable {
    case text
    case streaming
    case tools
    case parallelToolCalls
    case strictSchema
    case usage
    case streamUsage
    case maxTokensParameter
}

public enum MaxTokensParameter: String, Sendable, Codable, Equatable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"

    var alternate: MaxTokensParameter {
        self == .maxTokens ? .maxCompletionTokens : .maxTokens
    }
}

public enum ReasoningConfigMode: Sendable, Equatable, Codable {
    case defaultOnly
    case openAIChatEffort(supported: [ReasoningEffort])
    case deepSeekThinking(preserveReasoningContentInToolLoop: Bool)

    public var supportedEfforts: [ReasoningEffort] {
        switch self {
        case .defaultOnly, .deepSeekThinking:
            return [.default]
        case .openAIChatEffort(let supported):
            var result: [ReasoningEffort] = [.default]
            for effort in supported where effort != .default && !result.contains(effort) {
                result.append(effort)
            }
            return result
        }
    }

    public func supportsEffort(_ effort: ReasoningEffort) -> Bool {
        effort == .default || supportedEfforts.contains(effort)
    }

    public var preservesReasoningContinuation: Bool {
        switch self {
        case .deepSeekThinking(let preserve):
            return preserve
        case .defaultOnly, .openAIChatEffort:
            return false
        }
    }
}

public struct ProviderTimeouts: Sendable, Equatable, Codable {
    public var idleSeconds: TimeInterval
    public var requestSeconds: TimeInterval

    public init(idleSeconds: TimeInterval = 30, requestSeconds: TimeInterval = 90) {
        self.idleSeconds = idleSeconds
        self.requestSeconds = requestSeconds
    }

    public static let maximumStreamCeilingSeconds: TimeInterval = 1200
    public static let assumedSlowestTokensPerSecond: Double = 15

    public func streamCeilingSeconds(maxOutputTokens: Int) -> TimeInterval {
        let scaled = 60 + Double(max(0, maxOutputTokens)) / Self.assumedSlowestTokensPerSecond
        return max(requestSeconds, min(Self.maximumStreamCeilingSeconds, scaled))
    }
}

public struct CredentialReference: Sendable, Hashable, Codable {
    public let profileID: String
    public let slot: String

    public init(profileID: String, slot: String = "api-key") {
        self.profileID = profileID
        self.slot = slot
    }
}

public struct ProviderPricing: Sendable, Equatable, Codable {
    public let modelID: String
    public let inputPerMillionTokens: Decimal
    public let outputPerMillionTokens: Decimal
    public let currency: String
    public let capturedAt: Date

    public init(
        modelID: String,
        inputPerMillionTokens: Decimal,
        outputPerMillionTokens: Decimal,
        currency: String = "USD",
        capturedAt: Date
    ) {
        self.modelID = modelID
        self.inputPerMillionTokens = inputPerMillionTokens
        self.outputPerMillionTokens = outputPerMillionTokens
        self.currency = currency
        self.capturedAt = capturedAt
    }
}

public enum ProviderConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidURL
    case insecureScheme
    case unsupportedURLComponents
    case missingModel

    public var description: String {
        switch self {
        case .invalidURL:
            return "The base URL is not a valid web address."
        case .insecureScheme:
            return "The base URL must use HTTPS. Plain HTTP is only allowed for localhost when the local endpoint option is on."
        case .unsupportedURLComponents:
            return "The base URL must not contain credentials, a query string or a fragment."
        case .missingModel:
            return "A model ID is required."
        }
    }
}

public struct GatewayConfiguration: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var credentialReference: CredentialReference?
    public var authHeaderName: String?
    public var localEndpoint: Bool
    public var timeouts: ProviderTimeouts

    public init(
        id: String = "default",
        displayName: String = "Default Gateway",
        baseURL: String,
        credentialReference: CredentialReference? = nil,
        authHeaderName: String? = nil,
        localEndpoint: Bool = false,
        timeouts: ProviderTimeouts = ProviderTimeouts()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.credentialReference = credentialReference
        self.authHeaderName = authHeaderName
        self.localEndpoint = localEndpoint
        self.timeouts = timeouts
    }

    public func chatCompletionsURL() throws -> URL {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).chatCompletionsURL
    }

    public func modelsURL() throws -> URL {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).modelsURL
    }

    public func modelInfoURLs() throws -> [URL] {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).modelInfoURLs
    }

    public var previewURL: String {
        (try? chatCompletionsURL().absoluteString) ?? ""
    }

    public func validate() throws {
        _ = try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint)
    }
}

public struct CatalogModelEntry: Sendable, Equatable, Codable {
    public var id: String
    public var displayName: String?
    public var modelProvider: String?
    public var apiProvider: String?
    public var icon: String?
    public var ideRole: String?
    public var maxTokens: Int?
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    public var supportsFunctionCalling: Bool?
    public var supportsVision: Bool?
    public var supportsReasoning: Bool?

    public init(
        id: String,
        displayName: String? = nil,
        modelProvider: String? = nil,
        apiProvider: String? = nil,
        icon: String? = nil,
        ideRole: String? = nil,
        maxTokens: Int? = nil,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsFunctionCalling: Bool? = nil,
        supportsVision: Bool? = nil,
        supportsReasoning: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.modelProvider = modelProvider
        self.apiProvider = apiProvider
        self.icon = icon
        self.ideRole = ideRole
        self.maxTokens = maxTokens
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportsFunctionCalling = supportsFunctionCalling
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
    }
}

public struct ModelRoute: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var modelProvider: String?
    public var apiProvider: String?
    public var icon: String?
    public var ideRole: String?
    public var contextWindowTokens: Int?
    public var outputTokenLimit: Int
    public var maxTokensParameter: MaxTokensParameter
    public var reasoningMode: ReasoningConfigMode
    public var declaredCapabilities: Set<ProviderCapability>
    public var supportsFunctionCalling: Bool?
    public var supportsVision: Bool?
    public var supportsReasoning: Bool?
    public var isManual: Bool

    public init(
        id: String,
        displayName: String? = nil,
        modelProvider: String? = nil,
        apiProvider: String? = nil,
        icon: String? = nil,
        ideRole: String? = nil,
        contextWindowTokens: Int? = nil,
        outputTokenLimit: Int = 2048,
        maxTokensParameter: MaxTokensParameter = .maxTokens,
        reasoningMode: ReasoningConfigMode = .defaultOnly,
        declaredCapabilities: Set<ProviderCapability> = [.text, .streaming, .tools],
        supportsFunctionCalling: Bool? = nil,
        supportsVision: Bool? = nil,
        supportsReasoning: Bool? = nil,
        isManual: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.modelProvider = modelProvider
        self.apiProvider = apiProvider
        self.icon = icon
        self.ideRole = ideRole
        self.contextWindowTokens = contextWindowTokens
        self.outputTokenLimit = outputTokenLimit
        self.maxTokensParameter = maxTokensParameter
        self.reasoningMode = reasoningMode
        self.declaredCapabilities = declaredCapabilities
        self.supportsFunctionCalling = supportsFunctionCalling
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.isManual = isManual
    }

    public func configuration(for gateway: GatewayConfiguration) -> ProviderConfiguration {
        ProviderConfiguration(
            id: "\(gateway.id):\(id)",
            displayName: displayName,
            baseURL: gateway.baseURL,
            modelID: id,
            credentialReference: gateway.credentialReference,
            authHeaderName: gateway.authHeaderName,
            declaredCapabilities: declaredCapabilities,
            contextWindowTokens: contextWindowTokens,
            outputTokenLimit: outputTokenLimit,
            maxTokensParameter: maxTokensParameter,
            reasoningMode: reasoningMode,
            timeouts: gateway.timeouts,
            pricing: nil,
            localEndpoint: gateway.localEndpoint
        )
    }

    public func capabilityHash(for gateway: GatewayConfiguration, dialect: String = "chat_completions") -> String {
        ProviderEndpointValidator.capabilityHash(
            baseURL: gateway.baseURL,
            localEndpoint: gateway.localEndpoint,
            modelID: id,
            dialect: dialect,
            authHeaderName: gateway.authHeaderName
        )
    }
}

public struct ProviderConfiguration: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var modelID: String
    public var credentialReference: CredentialReference?
    public var authHeaderName: String?
    public var declaredCapabilities: Set<ProviderCapability>
    public var contextWindowTokens: Int?
    public var outputTokenLimit: Int
    public var maxTokensParameter: MaxTokensParameter
    public var reasoningMode: ReasoningConfigMode
    public var timeouts: ProviderTimeouts
    public var pricing: ProviderPricing?
    public var localEndpoint: Bool

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        modelID: String,
        credentialReference: CredentialReference? = nil,
        authHeaderName: String? = nil,
        declaredCapabilities: Set<ProviderCapability> = [.text, .streaming],
        contextWindowTokens: Int? = nil,
        outputTokenLimit: Int = 2048,
        maxTokensParameter: MaxTokensParameter = .maxTokens,
        reasoningMode: ReasoningConfigMode = .defaultOnly,
        timeouts: ProviderTimeouts = ProviderTimeouts(),
        pricing: ProviderPricing? = nil,
        localEndpoint: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.modelID = modelID
        self.credentialReference = credentialReference
        self.authHeaderName = authHeaderName
        self.declaredCapabilities = declaredCapabilities
        self.contextWindowTokens = contextWindowTokens
        self.outputTokenLimit = outputTokenLimit
        self.maxTokensParameter = maxTokensParameter
        self.reasoningMode = reasoningMode
        self.timeouts = timeouts
        self.pricing = pricing
        self.localEndpoint = localEndpoint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case modelID
        case credentialReference
        case authHeaderName
        case declaredCapabilities
        case contextWindowTokens
        case outputTokenLimit
        case maxTokensParameter
        case reasoningMode
        case timeouts
        case pricing
        case localEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        modelID = try container.decode(String.self, forKey: .modelID)
        credentialReference = try container.decodeIfPresent(CredentialReference.self, forKey: .credentialReference)
        authHeaderName = try container.decodeIfPresent(String.self, forKey: .authHeaderName)
        declaredCapabilities = try container.decode(Set<ProviderCapability>.self, forKey: .declaredCapabilities)
        contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        outputTokenLimit = try container.decode(Int.self, forKey: .outputTokenLimit)
        maxTokensParameter = try container.decode(MaxTokensParameter.self, forKey: .maxTokensParameter)
        reasoningMode = try container.decodeIfPresent(ReasoningConfigMode.self, forKey: .reasoningMode) ?? .defaultOnly
        timeouts = try container.decode(ProviderTimeouts.self, forKey: .timeouts)
        pricing = try container.decodeIfPresent(ProviderPricing.self, forKey: .pricing)
        localEndpoint = try container.decode(Bool.self, forKey: .localEndpoint)
    }

    public var gatewayConfiguration: GatewayConfiguration {
        GatewayConfiguration(
            id: id,
            displayName: displayName,
            baseURL: baseURL,
            credentialReference: credentialReference,
            authHeaderName: authHeaderName,
            localEndpoint: localEndpoint,
            timeouts: timeouts
        )
    }

    public var modelRoute: ModelRoute {
        ModelRoute(
            id: modelID,
            displayName: modelID,
            contextWindowTokens: contextWindowTokens,
            outputTokenLimit: outputTokenLimit,
            maxTokensParameter: maxTokensParameter,
            reasoningMode: reasoningMode,
            declaredCapabilities: declaredCapabilities,
            isManual: false
        )
    }

    public func chatCompletionsURL() throws -> URL {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).chatCompletionsURL
    }

    public func modelsURL() throws -> URL {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).modelsURL
    }

    public func modelInfoURLs() throws -> [URL] {
        try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint).modelInfoURLs
    }

    public var previewURL: String {
        (try? chatCompletionsURL().absoluteString) ?? ""
    }

    public func validate() throws {
        _ = try ProviderEndpointValidator.validate(baseURL: baseURL, localEndpoint: localEndpoint)
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderConfigurationError.missingModel
        }
    }

    public var capabilityHash: String {
        capabilityHash(routeOverride: nil)
    }

    public func capabilityHash(routeOverride: String?, dialect: String = "chat_completions") -> String {
        let effectiveModel: String
        if let override = routeOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            effectiveModel = override
        } else {
            effectiveModel = modelID
        }
        return ProviderEndpointValidator.capabilityHash(
            baseURL: baseURL,
            localEndpoint: localEndpoint,
            modelID: effectiveModel,
            dialect: dialect,
            authHeaderName: authHeaderName
        )
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
}

enum ProviderEndpointValidator {
    struct Endpoint {
        let chatCompletionsURL: URL
        let modelsURL: URL
        let modelInfoURLs: [URL]
        let host: String
        let port: Int
        let basePath: String
    }

    static func validate(baseURL: String, localEndpoint: Bool) throws -> Endpoint {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host, !rawHost.isEmpty
        else {
            throw ProviderConfigurationError.invalidURL
        }
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
            throw ProviderConfigurationError.unsupportedURLComponents
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch scheme {
        case "https":
            break
        case "http":
            guard localEndpoint, ProviderConfiguration.loopbackHosts.contains(host) else {
                throw ProviderConfigurationError.insecureScheme
            }
        default:
            throw ProviderConfigurationError.insecureScheme
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.scheme = scheme

        var chatComponents = components
        chatComponents.path = path + "/chat/completions"
        var modelsComponents = components
        modelsComponents.path = path + "/models"

        var infoURLs: [URL] = []
        var primaryInfoComponents = components
        primaryInfoComponents.path = path + "/model/info"
        if let u = primaryInfoComponents.url {
            infoURLs.append(u)
        }
        if path.lowercased().hasSuffix("/v1") {
            let strippedPath = String(path.dropLast(3))
            var rootInfoComponents = components
            rootInfoComponents.path = strippedPath + "/model/info"
            if let u = rootInfoComponents.url, !infoURLs.contains(u) {
                infoURLs.append(u)
            }
        }

        guard let chatURL = chatComponents.url, let modelsURL = modelsComponents.url, !infoURLs.isEmpty else {
            throw ProviderConfigurationError.invalidURL
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return Endpoint(
            chatCompletionsURL: chatURL,
            modelsURL: modelsURL,
            modelInfoURLs: infoURLs,
            host: host,
            port: port,
            basePath: path
        )
    }

    static func capabilityHash(
        baseURL: String,
        localEndpoint: Bool,
        modelID: String,
        dialect: String,
        authHeaderName: String?
    ) -> String {
        guard let endpoint = try? validate(baseURL: baseURL, localEndpoint: localEndpoint) else {
            return StableHash.hex("invalid|\(baseURL)|\(modelID)|\(dialect)")
        }
        return StableHash.hex("\(endpoint.host):\(endpoint.port)\(endpoint.basePath)|\(modelID)|\(dialect)|\(authHeaderName ?? "")")
    }
}

public struct ModelCatalogClient: Sendable {
    private let transport: HTTPTransport
    private let credentials: CredentialStore
    private static let responseBodyLimit = 1024 * 1024

    public init(transport: HTTPTransport, credentials: CredentialStore) {
        self.transport = transport
        self.credentials = credentials
    }

    private func buildHeaders(for gateway: GatewayConfiguration) throws -> (headers: [String: String], sensitive: Set<String>) {
        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "GoLens-Gopilot"
        ]
        var sensitive: Set<String> = ["authorization"]
        if let reference = gateway.credentialReference {
            let secret: String
            do {
                secret = try credentials.read(reference)
            } catch {
                throw ProviderError.unauthorized
            }
            if let name = gateway.authHeaderName, !name.isEmpty {
                headers[name] = secret
                sensitive.insert(name.lowercased())
            } else {
                headers["Authorization"] = "Bearer \(secret)"
            }
        }
        return (headers, sensitive)
    }

    private func readBody(_ response: HTTPResponse) async throws -> Data {
        var body = Data()
        do {
            for try await chunk in response.body {
                body.append(chunk)
                if body.count > Self.responseBodyLimit {
                    throw ProviderError.malformedResponse("The model catalog response exceeded the size limit.")
                }
            }
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.offline
        }
        return body
    }

    public func fetchCatalog(for gateway: GatewayConfiguration) async throws -> [CatalogModelEntry] {
        let infoURLs: [URL]
        do {
            infoURLs = try gateway.modelInfoURLs()
        } catch {
            throw ProviderError.malformedResponse("The provider endpoint is not valid.")
        }
        let (headers, sensitive) = try buildHeaders(for: gateway)

        for infoURL in infoURLs {
            let request = HTTPRequest(
                url: infoURL,
                method: "GET",
                headers: headers,
                body: nil,
                sensitiveHeaderNames: sensitive,
                timeout: gateway.timeouts.requestSeconds
            )
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as ProviderError {
                if case .consentRequired = error { throw error }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                continue
            }

            let status = response.head.status
            if status == 401 || status == 403 {
                throw ProviderError.unauthorized
            }
            if status == 429 {
                throw ProviderError.rateLimited(retryAfterSeconds: nil)
            }
            guard (200..<300).contains(status) else {
                continue
            }
            let contentType = (response.head.headers["content-type"] ?? "").lowercased()
            if contentType.contains("html") {
                continue
            }
            guard let body = try? await readBody(response),
                  let infoCatalog = try? JSONDecoder().decode(WireModelInfoCatalog.self, from: body) else {
                continue
            }

            var seen = Set<String>()
            var entries: [CatalogModelEntry] = []
            for item in infoCatalog.data {
                let rawID = (item.modelName ?? item.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawID.isEmpty, seen.insert(rawID).inserted else { continue }
                let info = item.modelInfo
                let trimmedDisplay = info?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedProvider = info?.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
                var resolvedAPIProvider = info?.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
                if resolvedAPIProvider == nil || resolvedAPIProvider?.isEmpty == true,
                   let apiBase = item.litellmParams?.apiBase?.lowercased() {
                    if apiBase.contains("nano-gpt") {
                        resolvedAPIProvider = "nanogpt"
                    } else if apiBase.contains("9r.") {
                        resolvedAPIProvider = "9r"
                    } else if apiBase.contains("openrouter") {
                        resolvedAPIProvider = "openrouter"
                    } else if apiBase.contains("deepseek") {
                        resolvedAPIProvider = "deepseek"
                    } else if apiBase.contains("anthropic") {
                        resolvedAPIProvider = "anthropic"
                    }
                }
                let trimmedIcon = info?.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedRole = info?.ideRole?.trimmingCharacters(in: .whitespacesAndNewlines)

                entries.append(
                    CatalogModelEntry(
                        id: rawID,
                        displayName: (trimmedDisplay?.isEmpty == false) ? trimmedDisplay : nil,
                        modelProvider: (trimmedProvider?.isEmpty == false) ? trimmedProvider : nil,
                        apiProvider: (resolvedAPIProvider?.isEmpty == false) ? resolvedAPIProvider : nil,
                        icon: (trimmedIcon?.isEmpty == false) ? trimmedIcon : nil,
                        ideRole: (trimmedRole?.isEmpty == false) ? trimmedRole : nil,
                        maxTokens: info?.maxTokens,
                        maxInputTokens: info?.maxInputTokens,
                        maxOutputTokens: info?.maxOutputTokens ?? info?.maxTokens,
                        supportsFunctionCalling: info?.supportsFunctionCalling,
                        supportsVision: info?.supportsVision,
                        supportsReasoning: info?.supportsReasoning
                    )
                )
            }
            return entries
        }

        let ids = try await fetchModelIDs(for: gateway)
        return ids.map { CatalogModelEntry(id: $0) }
    }

    public func fetchModelIDs(for gateway: GatewayConfiguration) async throws -> [String] {
        let url: URL
        do {
            url = try gateway.modelsURL()
        } catch {
            throw ProviderError.malformedResponse("The provider endpoint is not valid.")
        }
        let (headers, sensitive) = try buildHeaders(for: gateway)
        let request = HTTPRequest(
            url: url,
            method: "GET",
            headers: headers,
            body: nil,
            sensitiveHeaderNames: sensitive,
            timeout: gateway.timeouts.requestSeconds
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.offline
        }

        let status = response.head.status
        switch status {
        case 200..<300:
            let contentType = (response.head.headers["content-type"] ?? "").lowercased()
            if contentType.contains("html") {
                throw ProviderError.malformedResponse("The endpoint returned a web page instead of a model catalog.")
            }
            let body = try await readBody(response)
            guard let catalog = try? JSONDecoder().decode(WireModelCatalog.self, from: body) else {
                throw ProviderError.malformedResponse("The endpoint did not return a valid OpenAI-compatible model catalog.")
            }
            let uniqueIDs = Set(
                catalog.data
                    .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            return uniqueIDs.sorted()
        case 401, 403:
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfterSeconds: nil)
        case 500...599:
            throw ProviderError.server(status: status)
        default:
            throw ProviderError.malformedResponse("The provider does not expose a model catalog at /models (status \(status)). Enter a model ID manually.")
        }
    }

    public func fetchModelIDs(for configuration: ProviderConfiguration) async throws -> [String] {
        try await fetchModelIDs(for: configuration.gatewayConfiguration)
    }

    private struct WireModelCatalog: Decodable {
        struct Entry: Decodable {
            let id: String
        }
        let data: [Entry]
    }

    private struct WireModelInfoCatalog: Decodable {
        struct Info: Decodable {
            let modelProvider: String?
            let litellmProvider: String?
            let apiProvider: String?
            let displayName: String?
            let icon: String?
            let ideRole: String?
            let maxTokens: Int?
            let maxInputTokens: Int?
            let maxOutputTokens: Int?
            let supportsFunctionCalling: Bool?
            let supportsVision: Bool?
            let supportsReasoning: Bool?

            enum CodingKeys: String, CodingKey {
                case modelProvider = "model_provider"
                case litellmProvider = "litellm_provider"
                case apiProvider = "api_provider"
                case displayName = "display_name"
                case icon
                case ideRole = "ide_role"
                case maxTokens = "max_tokens"
                case maxInputTokens = "max_input_tokens"
                case maxOutputTokens = "max_output_tokens"
                case supportsFunctionCalling = "supports_function_calling"
                case supportsVision = "supports_vision"
                case supportsReasoning = "supports_reasoning"
            }
        }

        struct LiteLLMParams: Decodable {
            let apiBase: String?

            enum CodingKeys: String, CodingKey {
                case apiBase = "api_base"
            }
        }

        struct Entry: Decodable {
            let modelName: String?
            let id: String?
            let modelInfo: Info?
            let litellmParams: LiteLLMParams?

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case id
                case modelInfo = "model_info"
                case litellmParams = "litellm_params"
            }
        }

        let data: [Entry]
    }
}

enum StableHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
