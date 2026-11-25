import Foundation
import GoLensFoundation
import GopilotProvider
import GopilotRuntime
import Observation

enum RouteCapabilityTier: String, Equatable, Sendable {
    case verifiedAgent
    case verifiedChatOnly
    case untested
    case unavailable

    var badgeTitle: String {
        switch self {
        case .verifiedAgent: "Tools ready"
        case .verifiedChatOnly: "Chat only"
        case .untested: "Untested"
        case .unavailable: "Unavailable"
        }
    }

    var allowsAgentImmediately: Bool {
        self == .verifiedAgent
    }

    var isChatOnly: Bool {
        self == .verifiedChatOnly
    }
}

enum GopilotModelFamily: String, CaseIterable, Sendable {
    case deepseek
    case openai
    case claude
    case gemini
    case qwen
    case llama
    case mistral
    case grok
    case kimi
    case copilot
    case local
    case generic

    var brandName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        case .llama: "Llama"
        case .mistral: "Mistral"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .copilot: "Copilot"
        case .local: "Local"
        case .generic: "Model"
        }
    }

    var monogram: String {
        switch self {
        case .deepseek: "DS"
        case .openai: "OA"
        case .claude: "CL"
        case .gemini: "GM"
        case .qwen: "QW"
        case .llama: "LL"
        case .mistral: "MS"
        case .grok: "GK"
        case .kimi: "KM"
        case .copilot: "CP"
        case .local: "LC"
        case .generic: "AI"
        }
    }

    var symbolName: String {
        switch self {
        case .deepseek: "waveform.path.ecg"
        case .openai: "sparkles"
        case .claude: "sun.max.fill"
        case .gemini: "sparkle"
        case .qwen: "aqi.medium"
        case .llama: "cpu"
        case .mistral: "wind"
        case .grok: "bolt.fill"
        case .kimi: "moon.stars.fill"
        case .copilot: "airplane.circle.fill"
        case .local: "desktopcomputer"
        case .generic: "cube.transparent"
        }
    }
}

enum GopilotModelIdentity {
    static func detectFamily(for rawModelID: String) -> GopilotModelFamily {
        let lower = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let prefix = parts.first ?? lower
        let slug = parts.last ?? lower

        if prefix.contains("deepseek") || slug.contains("deepseek") || slug == "r1" || slug.hasPrefix("r1-") || slug.hasPrefix("v4.") || slug.hasPrefix("v3.") {
            return .deepseek
        }
        if prefix.contains("anthropic") || lower.contains("claude") || slug.contains("sonnet") || slug.contains("opus") || slug.contains("haiku") {
            return .claude
        }
        if prefix.contains("openai") || slug.hasPrefix("gpt") || slug.hasPrefix("o1") || slug.hasPrefix("o3") || slug.hasPrefix("o4") || slug.contains("codex") || slug.contains("chatgpt") {
            return .openai
        }
        if prefix.contains("google") || prefix.contains("gemini") || prefix.contains("vertex") || slug.contains("gemini") || slug.contains("gemma") {
            return .gemini
        }
        if prefix.contains("qwen") || prefix.contains("dashscope") || slug.contains("qwen") || slug.hasPrefix("qwq") {
            return .qwen
        }
        if prefix.contains("meta") || lower.contains("llama") {
            return .llama
        }
        if prefix.contains("mistral") || slug.contains("mistral") || slug.contains("codestral") || slug.contains("pixtral") || slug.contains("mixtral") || slug.contains("ministral") {
            return .mistral
        }
        if prefix.contains("xai") || slug.contains("grok") {
            return .grok
        }
        if prefix.contains("moonshot") || slug.contains("kimi") {
            return .kimi
        }
        if prefix.contains("github") || lower.contains("copilot") {
            return .copilot
        }
        if prefix.contains("ollama") || prefix.contains("lmstudio") || prefix.contains("vllm") || prefix.contains("mlx") {
            return .local
        }
        return .generic
    }

    static func prettyName(for route: ModelRoute?) -> String {
        guard let route else { return "Model" }
        return prettyName(modelID: route.id, customDisplayName: route.displayName)
    }

    static func prettyName(modelID: String, customDisplayName: String? = nil) -> String {
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           custom != trimmedID {
            return custom
        }
        guard !trimmedID.isEmpty else { return "Model" }

        let family = detectFamily(for: trimmedID)
        let slashParts = trimmedID.split(separator: "/").map(String.init)
        var slug = slashParts.last ?? trimmedID
        if slashParts.count > 1 {
            let providerPrefix = slashParts[0].lowercased()
            let lowerSlug = slug.lowercased()
            if lowerSlug.hasPrefix(providerPrefix + "-") || lowerSlug.hasPrefix(providerPrefix + "_") {
                slug = String(slug.dropFirst(providerPrefix.count + 1))
            }
        }

        let lowerSlug = slug.lowercased()
        if lowerSlug.hasPrefix("o1") || lowerSlug.hasPrefix("o3") || lowerSlug.hasPrefix("o4") {
            return slug
        }

        let rawTokens = slug
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        guard !rawTokens.isEmpty else { return trimmedID }

        var formattedTokens: [String] = []
        for token in rawTokens {
            let low = token.lowercased()
            if low == "deepseek" {
                formattedTokens.append("DeepSeek")
            } else if low == "openai" {
                formattedTokens.append("OpenAI")
            } else if low == "gpt" {
                formattedTokens.append("GPT")
            } else if low.hasPrefix("gpt"), low.count <= 5 {
                formattedTokens.append(token.uppercased())
            } else if low == "claude" {
                formattedTokens.append("Claude")
            } else if low == "gemini" {
                formattedTokens.append("Gemini")
            } else if low == "qwen" || low == "qwen2" || low == "qwen3" || low == "qwq" {
                formattedTokens.append(low == "qwq" ? "QwQ" : token.prefix(1).uppercased() + token.dropFirst())
            } else if low == "r1" || low == "v3" || low == "v4" || low == "vl" {
                formattedTokens.append(low.hasPrefix("v") && low.count == 2 ? low.uppercased() : token.uppercased())
            } else if low.first == "v", low.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                formattedTokens.append(low)
            } else if low.allSatisfy({ $0.isNumber || $0 == "." }) {
                formattedTokens.append(token)
            } else if low == "latest" {
                continue
            } else {
                formattedTokens.append(token.prefix(1).uppercased() + token.dropFirst())
            }
        }

        var joined = formattedTokens.joined(separator: " ")
        joined = joined.replacingOccurrences(of: "GPT ", with: "GPT-")

        if family != .generic && family != .openai && family != .local {
            let brand = family.brandName
            if !joined.lowercased().hasPrefix(brand.lowercased()) {
                joined = "\(brand) \(joined)"
            }
        }
        return joined.isEmpty ? trimmedID : joined
    }

    static func resolveIconSlug(for route: ModelRoute?) -> String? {
        guard let route else { return nil }
        return resolveIconSlug(
            modelID: route.id,
            explicitIcon: route.icon,
            modelProvider: route.modelProvider
        )
    }

    static func resolveIconSlug(
        modelID: String,
        explicitIcon: String? = nil,
        modelProvider: String? = nil
    ) -> String? {
        for candidate in [explicitIcon, modelProvider] {
            if let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !raw.isEmpty,
               let mapped = mapProviderSlug(raw) {
                return mapped
            }
        }
        let lower = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let prefix = parts.first ?? lower
        let slug = parts.last ?? lower

        if let mappedPrefix = mapProviderSlug(prefix) {
            return mappedPrefix
        }
        if slug.contains("deepseek") || slug == "r1" || slug.hasPrefix("r1-") || slug.hasPrefix("v4.") || slug.hasPrefix("v3.") {
            return "deepseek"
        }
        if slug.contains("claude") || slug.contains("sonnet") || slug.contains("opus") || slug.contains("haiku") {
            return "claude"
        }
        if slug.hasPrefix("gpt") || slug.hasPrefix("o1") || slug.hasPrefix("o3") || slug.hasPrefix("o4") || slug.contains("codex") || slug.contains("chatgpt") {
            return "openai"
        }
        if slug.contains("gemini") || slug.contains("gemma") {
            return "google"
        }
        if slug.contains("qwen") || slug.hasPrefix("qwq") {
            return "qwen"
        }
        if slug.contains("llama") {
            return "meta"
        }
        if slug.contains("mistral") || slug.contains("codestral") || slug.contains("pixtral") || slug.contains("mixtral") || slug.contains("ministral") {
            return "mistral"
        }
        if slug.contains("grok") {
            return "grok"
        }
        if slug.contains("kimi") {
            return "kimi"
        }
        if slug.contains("moonshot") {
            return "moonshot"
        }
        if slug.contains("glm") || slug.contains("zhipu") {
            return "zhipu"
        }
        if slug.contains("minimax") || slug.contains("abab") {
            return "minimax"
        }
        if slug.contains("mimo") || slug.contains("xiaomi") {
            return "xiaomimimo"
        }
        if slug.contains("command-r") || slug.contains("cohere") {
            return "cohere"
        }
        if slug.contains("sonar") || slug.contains("perplexity") {
            return "perplexity"
        }
        if slug.contains("doubao") {
            return "doubao"
        }
        if slug.contains("step-") || slug.contains("stepfun") {
            return "stepfun"
        }
        if slug.hasPrefix("yi-") {
            return "yi"
        }
        if slug.contains("copilot") {
            return "githubcopilot"
        }
        return nil
    }

    private static func mapProviderSlug(_ raw: String) -> String? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "anthropic", "claude": return "claude"
        case "openai", "azureopenai": return "openai"
        case "deepseek": return "deepseek"
        case "google", "googleai", "palm": return "google"
        case "gemini": return "gemini"
        case "vertexai", "vertex", "googlevertex": return "vertexai"
        case "qwen", "dashscope", "alibaba", "aliyun", "tongyi": return "qwen"
        case "meta", "llama", "metallama": return "meta"
        case "mistral", "mistralai": return "mistral"
        case "grok": return "grok"
        case "xai": return "xai"
        case "kimi": return "kimi"
        case "moonshot", "moonshotai": return "moonshot"
        case "zhipu", "zhipuai", "glm", "chatglm", "bigmodel", "zai": return "zhipu"
        case "minimax": return "minimax"
        case "xiaomi", "xiaomimimo", "mimo": return "xiaomimimo"
        case "cohere": return "cohere"
        case "perplexity", "pplx": return "perplexity"
        case "ollama": return "ollama"
        case "openrouter": return "openrouter"
        case "github": return "github"
        case "githubcopilot": return "githubcopilot"
        case "copilot": return "copilot"
        case "azure": return "azure"
        case "bedrock", "awsbedrock", "amazonbedrock": return "bedrock"
        case "yi", "01ai", "zeroone": return "yi"
        case "stepfun", "step": return "stepfun"
        case "doubao", "bytedance", "volcengine", "ark": return "doubao"
        case "groq": return "groq"
        default: return nil
        }
    }

    static func prettyAPISource(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "nanogpt", "nano": return "NanoGPT"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "claude": return "Claude"
        case "deepseek": return "DeepSeek"
        case "google", "googleai": return "Google"
        case "gemini": return "Gemini"
        case "vertexai", "vertex": return "Vertex AI"
        case "openrouter": return "OpenRouter"
        case "litellm": return "LiteLLM"
        case "github", "githubcopilot": return "GitHub Copilot"
        case "copilot": return "Copilot"
        case "xai": return "xAI"
        case "grok": return "Grok"
        case "qwen", "dashscope": return "Qwen"
        case "meta", "metallama": return "Meta"
        case "mistral", "mistralai": return "Mistral"
        case "moonshot", "moonshotai": return "Moonshot"
        case "kimi": return "Kimi"
        case "zhipu", "zhipuai": return "Zhipu AI"
        case "zai": return "Z.ai"
        case "minimax": return "MiniMax"
        case "xiaomi", "xiaomimimo": return "Xiaomi MiMo"
        case "cohere": return "Cohere"
        case "perplexity": return "Perplexity"
        case "ollama": return "Ollama"
        case "azure", "azureopenai": return "Azure"
        case "bedrock", "awsbedrock": return "AWS Bedrock"
        case "groq": return "Groq"
        case "vllm": return "vLLM"
        case "9r": return "9r"
        default:
            if trimmed.contains(where: { $0.isUppercase || $0.isNumber }) {
                return trimmed
            }
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }

    static func apiSourceSubtitle(for route: ModelRoute) -> String? {
        if let api = prettyAPISource(route.apiProvider) {
            return api
        }
        if let provider = prettyAPISource(route.modelProvider) {
            return provider
        }
        let parts = route.id.split(separator: "/").map(String.init)
        if parts.count > 1, let prefix = parts.first {
            return prettyAPISource(prefix)
        }
        let pretty = prettyName(for: route)
        if pretty != route.id {
            return route.id
        }
        return nil
    }
}

@Observable
final class GopilotProviderSettings {
    static let shared = GopilotProviderSettings()

    private enum Key {
        static let baseURL = "GoLensGopilotBaseURL"
        static let model = "GoLensGopilotModel"
        static let contextWindow = "GoLensGopilotContextWindow"
        static let report = "GoLensGopilotCompatibilityReport"
        static let routes = "GoLensGopilotRoutes"
        static let defaultRouteID = "GoLensGopilotDefaultRouteID"
        static let reportsByHash = "GoLensGopilotReportsByHash"
        static let localEndpoint = "GoLensGopilotLocalEndpoint"
    }

    static let credentialReference = CredentialReference(profileID: "default")

    var baseURL = "" {
        didSet {
            if !loading {
                let oldHost = URL(string: oldValue.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
                let newHost = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
                if oldHost != newHost, let newHost, !newHost.isEmpty {
                    routes = []
                    catalogLoadState = .notLoaded
                    catalogMessage = nil
                }
            }
            persist()
            reportInvalidated()
        }
    }

    var modelID = "" {
        didSet {
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !loading, !trimmed.isEmpty {
                ensureRouteExists(id: trimmed, makeDefault: true)
            }
            persist()
            reportInvalidated()
        }
    }

    var contextWindowText = "" {
        didSet {
            if !loading, let defaultRoute = defaultRoute {
                let tokens = Int(contextWindowText.trimmingCharacters(in: .whitespaces))
                updateRouteContextWindow(id: defaultRoute.id, tokens: tokens)
            }
            persist()
        }
    }

    var localEndpoint = false {
        didSet {
            persist()
            reportInvalidated()
        }
    }

    var routes: [ModelRoute] = [] {
        didSet { persist() }
    }

    var defaultRouteID = "" {
        didSet {
            if !loading, !defaultRouteID.isEmpty, modelID != defaultRouteID {
                loading = true
                modelID = defaultRouteID
                if let r = routes.first(where: { $0.id == defaultRouteID }) {
                    contextWindowText = r.contextWindowTokens.map(String.init) ?? ""
                }
                loading = false
            }
            persist()
        }
    }

    var apiKeyDraft = ""
    var isEditingKey = false
    var manualRouteDraft = ""
    var manualRouteReasoningChoice = ReasoningChoice.auto
    private(set) var hasStoredKey = false
    private(set) var keychainMessage: String?
    private(set) var report: CompatibilityReport?
    private(set) var reportsByHash: [String: CompatibilityReport] = [:]
    private(set) var isTesting = false
    private(set) var testingRouteID: String?
    private(set) var isFetchingModels = false
    private(set) var catalogLoadState: CatalogLoadState = .notLoaded
    private(set) var catalogMessage: String?

    enum CatalogLoadState: Equatable {
        case notLoaded
        case loading
        case loaded(count: Int)
        case failed
    }

    enum ReasoningChoice: String, CaseIterable, Identifiable {
        case auto
        case defaultOnly
        case openAIEffort
        case deepSeekThinking

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: "Automatic"
            case .defaultOnly: "Default only"
            case .openAIEffort: "Reasoning effort (Low / Medium / High)"
            case .deepSeekThinking: "DeepSeek thinking"
            }
        }
    }

    enum CredentialLocation: Equatable {
        case keychain
        case localFile
        case memory
    }

    static let maxRequestedOutputTokens = 32_768

    @ObservationIgnored private let credentials: any CredentialStore
    let credentialLocation: CredentialLocation
    private(set) var credentialMigrationMessage: String?
    @ObservationIgnored private var loading = false

    var credentialLocationDescription: String {
        switch credentialLocation {
        case .keychain: "Saved in Keychain"
        case .localFile: "Saved in a local file"
        case .memory: "Kept in memory for this session"
        }
    }

    var storedKeyStatusText: String {
        hasStoredKey ? credentialLocationDescription : "Not saved"
    }

    private static func makeDefaultCredentialStore() -> (store: any CredentialStore, location: CredentialLocation, message: String?) {
        let env = ProcessInfo.processInfo.environment
        switch GopilotCredentialStorePolicy.resolveMode(environment: env) {
        case .memory:
            return (InMemoryCredentialStore([credentialReference: "dev-seeded-key"]), .memory, nil)
        case .localFile:
            return (LocalFileCredentialStore(), .localFile, nil)
        case .keychain:
            let keychain = KeychainCredentialStore()
            let legacyURL = LocalFileCredentialStore().fileURL
            let storageKey = GopilotCredentialStorePolicy.storageKey(
                profileID: credentialReference.profileID,
                slot: credentialReference.slot
            )
            let outcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
                fileURL: legacyURL,
                storageKey: storageKey,
                writeToTarget: { secret in
                    try keychain.write(secret, for: credentialReference)
                },
                readBackFromTarget: {
                    try keychain.read(credentialReference)
                }
            )
            let message = GopilotCredentialStorePolicy.migrationFailureMessage(
                for: outcome,
                fileName: legacyURL.lastPathComponent
            )
            return (CachingCredentialStore(keychain), .keychain, message)
        }
    }

    init() {
        let made = Self.makeDefaultCredentialStore()
        credentials = made.store
        credentialLocation = made.location
        credentialMigrationMessage = made.message
        load()
    }

    var gateway: GatewayConfiguration? {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let autoLocal = localEndpoint || Self.looksLikeLoopbackHTTP(url)
        let gw = GatewayConfiguration(
            id: "default",
            displayName: "Default Gateway",
            baseURL: url,
            credentialReference: Self.credentialReference,
            localEndpoint: autoLocal,
            timeouts: ProviderTimeouts(idleSeconds: 60, requestSeconds: 180)
        )
        return (try? gw.validate()) != nil ? gw : nil
    }

    var defaultRoute: ModelRoute? {
        if let match = routes.first(where: { $0.id == defaultRouteID }) {
            return match
        }
        if let first = routes.first {
            return first
        }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ModelRoute(
            id: trimmed,
            displayName: trimmed,
            contextWindowTokens: Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
            outputTokenLimit: 16_384,
            reasoningMode: Self.defaultReasoningMode(for: trimmed),
            declaredCapabilities: [.text, .streaming, .tools],
            isManual: true
        )
    }

    func route(for id: String?) -> ModelRoute? {
        if let id, !id.isEmpty {
            if let found = routes.first(where: { $0.id == id }) {
                return found
            }
            return ModelRoute(
                id: id,
                displayName: id,
                contextWindowTokens: Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
                outputTokenLimit: 16_384,
                reasoningMode: Self.defaultReasoningMode(for: id),
                declaredCapabilities: [.text, .streaming, .tools],
                isManual: true
            )
        }
        return defaultRoute
    }

    func configuration(for routeID: String? = nil) -> ProviderConfiguration? {
        guard let gateway, let activeRoute = route(for: routeID) else { return nil }
        let cfg = activeRoute.configuration(for: gateway)
        return (try? cfg.validate()) != nil ? cfg : nil
    }

    var configuration: ProviderConfiguration? {
        configuration(for: nil)
    }

    var isConfigured: Bool { configuration != nil && hasStoredKey }

    var previewURL: String { configuration?.previewURL ?? "" }

    var modelsPreviewURL: String {
        guard let gateway, let url = try? gateway.modelsURL() else { return "" }
        return url.absoluteString
    }

    var urlProblem: String? {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let probe = ProviderConfiguration(
            id: "probe",
            displayName: "probe",
            baseURL: url,
            modelID: "probe",
            localEndpoint: localEndpoint || Self.looksLikeLoopbackHTTP(url)
        )
        if case .failure(let error) = Result(catching: { try probe.validate() }) {
            return Self.describe(error)
        }
        return nil
    }

    var summary: String? {
        guard isConfigured, let configuration else { return nil }
        let host = URL(string: configuration.baseURL)?.host ?? configuration.baseURL
        return "\(configuration.modelID) · \(host)"
    }

    var missingConfigurationHint: String? {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasModel = defaultRoute != nil
        if trimmedURL.isEmpty && !hasModel && !hasStoredKey {
            return "Enter a provider URL, save an API key, and choose a model to test the connection."
        }
        if trimmedURL.isEmpty && !hasModel {
            return "Enter a provider URL and choose a model to test the connection."
        }
        if trimmedURL.isEmpty {
            return "Enter a provider URL to test the connection."
        }
        if let problem = urlProblem {
            return problem
        }
        if !hasStoredKey && !hasModel {
            return "Save an API key and choose a model to test the connection."
        }
        if !hasStoredKey {
            return "Save an API key to test the connection."
        }
        if !hasModel {
            return "Fetch models or enter a model ID to test the connection."
        }
        return nil
    }

    func report(for routeID: String? = nil) -> CompatibilityReport? {
        guard let cfg = configuration(for: routeID) else { return nil }
        if let stored = reportsByHash[cfg.capabilityHash] {
            return stored
        }
        if let report, report.configHash == cfg.capabilityHash {
            return report
        }
        return nil
    }

    func routeTier(for routeID: String? = nil) -> RouteCapabilityTier {
        if let rep = report(for: routeID) {
            switch rep.agentMode {
            case .agent: return .verifiedAgent
            case .chatOnly: return .verifiedChatOnly
            case .unavailable: return .unavailable
            }
        }
        if let candidate = route(for: routeID) {
            if candidate.supportsFunctionCalling == false || !candidate.declaredCapabilities.contains(.tools) {
                return .verifiedChatOnly
            }
        }
        return .untested
    }

    func firstToolCapableRoute(excluding excludedID: String? = nil) -> ModelRoute? {
        for candidate in routes where candidate.id != excludedID {
            if routeTier(for: candidate.id) == .verifiedAgent {
                return candidate
            }
        }
        return nil
    }

    var agentMode: AgentMode {
        guard let rep = report(for: nil) else { return .agent }
        return rep.agentMode
    }

    func profile(for routeID: String? = nil) -> CapabilityProfile {
        guard let rep = report(for: routeID) else { return CapabilityProfile() }
        return rep.updatedProfile()
    }

    var profile: CapabilityProfile {
        profile(for: nil)
    }

    func load() {
        loading = true
        defer { loading = false }
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Key.baseURL) ?? ""
        modelID = defaults.string(forKey: Key.model) ?? ""
        contextWindowText = defaults.string(forKey: Key.contextWindow) ?? ""
        localEndpoint = defaults.bool(forKey: Key.localEndpoint)
        if let data = defaults.data(forKey: Key.routes),
           let decoded = try? JSONDecoder().decode([ModelRoute].self, from: data) {
            let upgraded = decoded.map { route -> ModelRoute in
                guard route.outputTokenLimit <= 4_096 else { return route }
                var copy = route
                copy.outputTokenLimit = 16_384
                return copy
            }
            routes = Self.prioritizedRoutes(upgraded)
        }
        defaultRouteID = defaults.string(forKey: Key.defaultRouteID) ?? ""
        if let data = defaults.data(forKey: Key.reportsByHash),
           let decoded = try? JSONDecoder().decode([String: CompatibilityReport].self, from: data) {
            reportsByHash = decoded
        }
        if let data = defaults.data(forKey: Key.report),
           let legacy = try? JSONDecoder().decode(CompatibilityReport.self, from: data) {
            report = legacy
            reportsByHash[legacy.configHash] = legacy
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if routes.isEmpty, !trimmedModel.isEmpty {
            let migrated = ModelRoute(
                id: trimmedModel,
                displayName: trimmedModel,
                contextWindowTokens: Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
                outputTokenLimit: 16_384,
                reasoningMode: Self.defaultReasoningMode(for: trimmedModel),
                declaredCapabilities: [.text, .streaming, .tools],
                isManual: true
            )
            routes = [migrated]
            defaultRouteID = migrated.id
        } else if defaultRouteID.isEmpty, let first = routes.first {
            defaultRouteID = first.id
            modelID = first.id
        }
        refreshKeyState()
        isEditingKey = !hasStoredKey
        seedFromDeveloperFile()
        catalogLoadState = routes.isEmpty ? .notLoaded : .loaded(count: routes.count)
        syncLegacyReport()
        let env = ProcessInfo.processInfo.environment
        if hasStoredKey, let gw = gateway, AIProviderConsent.shared.isAllowed(baseURL: gw.baseURL),
           env["GOPILOT_DEV_SEED_CONNECTED"] != "1", env["GOPILOT_DEV_SETTINGS_STATE"] == nil {
            Task { @MainActor [weak self] in
                await self?.fetchModels()
            }
        }
    }

    func refreshKeyState() {
        do {
            _ = try credentials.read(Self.credentialReference)
            hasStoredKey = true
            keychainMessage = nil
        } catch CredentialError.notFound {
            hasStoredKey = false
            keychainMessage = nil
        } catch {
            hasStoredKey = false
            keychainMessage = "\(error)"
        }
    }

    func beginEditingKey() {
        apiKeyDraft = ""
        keychainMessage = nil
        isEditingKey = true
    }

    func cancelEditingKey() {
        apiKeyDraft = ""
        keychainMessage = nil
        isEditingKey = false
    }

    func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try credentials.write(key, for: Self.credentialReference)
            apiKeyDraft = ""
            hasStoredKey = true
            isEditingKey = false
            keychainMessage = nil
            if credentialLocation == .keychain {
                credentialMigrationMessage = GopilotCredentialStorePolicy.cleanupLegacyCredentialFile(
                    fileURL: LocalFileCredentialStore().fileURL,
                    storageKey: GopilotCredentialStorePolicy.storageKey(
                        profileID: Self.credentialReference.profileID,
                        slot: Self.credentialReference.slot
                    )
                )
            }
            if let gw = gateway, AIProviderConsent.shared.isAllowed(baseURL: gw.baseURL) {
                Task { @MainActor [weak self] in
                    await self?.fetchModels()
                }
            }
        } catch {
            keychainMessage = "\(error)"
        }
    }

    func removeKey() {
        do {
            try credentials.delete(Self.credentialReference)
            hasStoredKey = false
            isEditingKey = true
            keychainMessage = nil
            if credentialLocation == .keychain {
                credentialMigrationMessage = GopilotCredentialStorePolicy.cleanupLegacyCredentialFile(
                    fileURL: LocalFileCredentialStore().fileURL,
                    storageKey: GopilotCredentialStorePolicy.storageKey(
                        profileID: Self.credentialReference.profileID,
                        slot: Self.credentialReference.slot
                    )
                )
            }
        } catch CredentialError.notFound {
            hasStoredKey = false
            isEditingKey = true
            if credentialLocation == .keychain {
                credentialMigrationMessage = GopilotCredentialStorePolicy.cleanupLegacyCredentialFile(
                    fileURL: LocalFileCredentialStore().fileURL,
                    storageKey: GopilotCredentialStorePolicy.storageKey(
                        profileID: Self.credentialReference.profileID,
                        slot: Self.credentialReference.slot
                    )
                )
            }
        } catch {
            keychainMessage = "\(error)"
        }
    }

    func currentSecrets() -> [String] {
        guard let key = try? credentials.read(Self.credentialReference) else { return [] }
        return [key]
    }

    func ensureRouteExists(id: String, makeDefault: Bool = false) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !routes.contains(where: { $0.id == trimmed }) {
            let created = ModelRoute(
                id: trimmed,
                displayName: trimmed,
                contextWindowTokens: Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
                outputTokenLimit: 16_384,
                reasoningMode: Self.defaultReasoningMode(for: trimmed),
                declaredCapabilities: [.text, .streaming, .tools],
                isManual: true
            )
            routes.append(created)
        }
        if makeDefault || defaultRouteID.isEmpty {
            defaultRouteID = trimmed
        }
    }

    func addManualRoute(id: String? = nil, reasoningChoice: ReasoningChoice? = nil) {
        let raw = (id ?? manualRouteDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let choice = reasoningChoice ?? manualRouteReasoningChoice
        let mode = Self.reasoningMode(for: raw, choice: choice)
        if let idx = routes.firstIndex(where: { $0.id == raw }) {
            routes[idx].reasoningMode = mode
        } else {
            let route = ModelRoute(
                id: raw,
                displayName: raw,
                contextWindowTokens: Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
                outputTokenLimit: 16_384,
                reasoningMode: mode,
                declaredCapabilities: [.text, .streaming, .tools],
                isManual: true
            )
            routes.append(route)
        }
        if defaultRouteID.isEmpty {
            setDefaultRoute(id: raw)
        }
        manualRouteDraft = ""
        manualRouteReasoningChoice = .auto
        catalogLoadState = .loaded(count: routes.count)
        catalogMessage = nil
    }

    func removeRoute(id: String) {
        routes.removeAll { $0.id == id }
        if defaultRouteID == id {
            let next = routes.first?.id ?? ""
            defaultRouteID = next
            modelID = next
        }
        catalogLoadState = routes.isEmpty ? .notLoaded : .loaded(count: routes.count)
        syncLegacyReport()
    }

    func setDefaultRoute(id: String) {
        guard routes.contains(where: { $0.id == id }) else { return }
        defaultRouteID = id
        modelID = id
        if let route = routes.first(where: { $0.id == id }) {
            contextWindowText = route.contextWindowTokens.map(String.init) ?? ""
        }
        syncLegacyReport()
        if !loading {
            Task { @MainActor in
                WorkspaceState.shared.gopilot.selectRoute(id)
            }
        }
    }

    func updateRouteReasoning(id: String, mode: ReasoningConfigMode) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].reasoningMode = mode
    }

    func updateRouteDisplayName(id: String, displayName: String) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        routes[index].displayName = trimmed.isEmpty ? id : trimmed
    }

    func updateRouteContextWindow(id: String, tokens: Int?) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].contextWindowTokens = tokens
    }

    @MainActor
    func fetchModels() async {
        guard !isFetchingModels, let gateway else { return }
        if let host = AIProviderConsent.host(forBaseURL: gateway.baseURL), !AIProviderConsent.shared.isAllowed(host) {
            catalogLoadState = .notLoaded
            catalogMessage = "Permission is required before sending requests to \(host)."
            return
        }
        isFetchingModels = true
        catalogLoadState = .loading
        catalogMessage = nil
        defer { isFetchingModels = false }
        let client = ModelCatalogClient(transport: AIProviderConsent.makeTransport(), credentials: credentials)
        do {
            let fetched = try await client.fetchCatalog(for: gateway)
            if fetched.isEmpty {
                catalogLoadState = .loaded(count: routes.count)
                catalogMessage = "No models returned by the provider. Enter a model ID manually."
                return
            }
            let existingByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
            var updatedRoutes: [ModelRoute] = []
            for entry in fetched {
                var capabilities: Set<ProviderCapability> = [.text, .streaming]
                if entry.supportsFunctionCalling != false {
                    capabilities.insert(.tools)
                }
                let reasoning: ReasoningConfigMode
                if let explicitReasoning = entry.supportsReasoning {
                    reasoning = explicitReasoning
                        ? Self.reasoningModeForSupportedModel(id: entry.id, provider: entry.modelProvider)
                        : .defaultOnly
                } else {
                    reasoning = Self.defaultReasoningMode(for: entry.id)
                }

                let existing = existingByID[entry.id]
                let previousLimit = existing?.outputTokenLimit ?? 16_384
                let staleWindow = existing?.contextWindowTokens != nil && existing?.contextWindowTokens == entry.maxTokens
                let contextWindow = entry.maxInputTokens ?? (staleWindow ? nil : existing?.contextWindowTokens)
                let outputLimit = entry.maxOutputTokens.map { max(1_024, min($0, Self.maxRequestedOutputTokens)) } ?? previousLimit
                updatedRoutes.append(
                    ModelRoute(
                        id: entry.id,
                        displayName: (entry.displayName?.isEmpty == false ? entry.displayName : existing?.displayName) ?? entry.id,
                        modelProvider: entry.modelProvider ?? existing?.modelProvider,
                        apiProvider: entry.apiProvider ?? existing?.apiProvider,
                        icon: entry.icon ?? existing?.icon,
                        ideRole: entry.ideRole ?? existing?.ideRole,
                        contextWindowTokens: contextWindow,
                        outputTokenLimit: outputLimit,
                        reasoningMode: entry.supportsReasoning != nil ? reasoning : (existing?.reasoningMode ?? reasoning),
                        declaredCapabilities: capabilities,
                        supportsFunctionCalling: entry.supportsFunctionCalling ?? existing?.supportsFunctionCalling,
                        supportsVision: entry.supportsVision ?? existing?.supportsVision,
                        supportsReasoning: entry.supportsReasoning ?? existing?.supportsReasoning,
                        isManual: false
                    )
                )
            }
            let previousDefault = defaultRouteID
            routes = Self.prioritizedRoutes(updatedRoutes)
            if !routes.contains(where: { $0.id == defaultRouteID })
                || (defaultRouteID.lowercased().hasPrefix("9r/") && routeTier(for: defaultRouteID) != .verifiedAgent) {
                if let preferred = Self.preferredDefaultRoute(from: routes, previousDefaultID: previousDefault) {
                    setDefaultRoute(id: preferred.id)
                }
            } else {
                setDefaultRoute(id: defaultRouteID)
            }
            catalogLoadState = .loaded(count: routes.count)
            catalogMessage = "Found \(fetched.count) model\(fetched.count == 1 ? "" : "s") from provider."
            if hasStoredKey, report(for: defaultRouteID) == nil {
                await testConnection(routeID: defaultRouteID)
            }
        } catch let error as ProviderError {
            catalogLoadState = .failed
            switch error {
            case .unauthorized:
                catalogMessage = "Authentication failed when fetching models. Check your API key."
            case .offline:
                catalogMessage = "Could not reach the provider to list models. You can still enter a model ID manually."
            case .malformedResponse(let detail):
                catalogMessage = detail
            case .requestRejected(let status, let reason):
                catalogMessage = reason.map { "The provider rejected the model list request: \($0)" } ?? "The provider rejected the model list request (status \(status)). Enter a model ID manually."
            case .consentRequired(let host):
                catalogLoadState = .notLoaded
                catalogMessage = "Permission is required before sending requests to \(host)."
            default:
                catalogMessage = "Couldn’t load models from this provider. Enter a model ID manually."
            }
        } catch {
            catalogLoadState = .failed
            catalogMessage = "Couldn’t load models from this provider. Enter a model ID manually."
        }
    }

    func makeProvider(for routeID: String? = nil, streamingOverride: Bool? = nil) -> OpenAICompatibleProvider? {
        guard let cfg = configuration(for: routeID) else { return nil }
        return OpenAICompatibleProvider(
            configuration: cfg,
            credentials: credentials,
            transport: AIProviderConsent.makeTransport(),
            profile: profile(for: routeID),
            streamingOverride: streamingOverride
        )
    }

    private static func prioritizedRoutes(_ available: [ModelRoute]) -> [ModelRoute] {
        available.enumerated().sorted { lhs, rhs in
            let lRank = routeSortBucket(lhs.element)
            let rRank = routeSortBucket(rhs.element)
            if lRank != rRank { return lRank < rRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func routeSortBucket(_ route: ModelRoute) -> Int {
        let lowerID = route.id.lowercased()
        let api = route.apiProvider?.lowercased() ?? ""
        if lowerID.hasPrefix("nano/") {
            return 0
        }
        if api == "nanogpt" {
            return 1
        }
        if lowerID.hasPrefix("9r/") || api == "9r" {
            return 3
        }
        return 2
    }

    private static func preferredDefaultRoute(from available: [ModelRoute], previousDefaultID: String) -> ModelRoute? {
        guard !available.isEmpty else { return nil }
        let prevLower = previousDefaultID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prevSlug = prevLower.split(separator: "/").last.map(String.init) ?? prevLower
        if !prevSlug.isEmpty {
            let matchingSlug = available.filter {
                let candidateSlug = $0.id.lowercased().split(separator: "/").last.map(String.init) ?? $0.id.lowercased()
                return candidateSlug == prevSlug || candidateSlug.contains(prevSlug) || prevSlug.contains(candidateSlug)
            }
            if let nanoMatch = matchingSlug.first(where: { $0.id.lowercased().hasPrefix("nano/") || $0.apiProvider?.lowercased() == "nanogpt" }) {
                return nanoMatch
            }
            if let firstMatch = matchingSlug.first {
                return firstMatch
            }
        }
        if let sonnet = available.first(where: { $0.id == "nano/sonnet-5.5" }) {
            return sonnet
        }
        if let nanoTool = available.first(where: { ($0.id.lowercased().hasPrefix("nano/") || $0.apiProvider?.lowercased() == "nanogpt") && $0.supportsFunctionCalling != false }) {
            return nanoTool
        }
        if let toolCapable = available.first(where: { $0.supportsFunctionCalling != false }) {
            return toolCapable
        }
        return available.first
    }

    @MainActor
    func testConnection(routeID: String? = nil) async {
        guard !isTesting, hasStoredKey else { return }
        if let gw = gateway, !AIProviderConsent.shared.isAllowed(baseURL: gw.baseURL) {
            return
        }
        if routeID == nil, routes.isEmpty, gateway != nil {
            await fetchModels()
            if report != nil { return }
        }
        let targetID = routeID ?? defaultRoute?.id
        guard let cfg = configuration(for: targetID),
              let streaming = makeProvider(for: targetID, streamingOverride: true),
              let nonStreaming = makeProvider(for: targetID, streamingOverride: false) else { return }
        isTesting = true
        testingRouteID = cfg.modelID
        let result = await ConnectionTester().run(streaming: streaming, nonStreaming: nonStreaming, configHash: cfg.capabilityHash)
        reportsByHash[cfg.capabilityHash] = result
        syncLegacyReport()
        persist()
        isTesting = false
        testingRouteID = nil
    }

    private func syncLegacyReport() {
        if let cfg = configuration(for: nil), let current = reportsByHash[cfg.capabilityHash] {
            report = current
            if let data = try? JSONEncoder().encode(current) {
                UserDefaults.standard.set(data, forKey: Key.report)
            }
        } else {
            report = nil
            UserDefaults.standard.removeObject(forKey: Key.report)
        }
    }

    private func persist() {
        guard !loading else { return }
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(modelID, forKey: Key.model)
        defaults.set(contextWindowText, forKey: Key.contextWindow)
        defaults.set(localEndpoint, forKey: Key.localEndpoint)
        defaults.set(defaultRouteID, forKey: Key.defaultRouteID)
        if let routeData = try? JSONEncoder().encode(routes) {
            defaults.set(routeData, forKey: Key.routes)
        }
        if let reportsData = try? JSONEncoder().encode(reportsByHash) {
            defaults.set(reportsData, forKey: Key.reportsByHash)
        }
    }

    private func reportInvalidated() {
        guard !loading else { return }
        syncLegacyReport()
    }

    static func looksLikeLoopbackHTTP(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func reasoningModeForSupportedModel(id: String, provider: String?) -> ReasoningConfigMode {
        let lower = id.lowercased()
        let slug = lower.components(separatedBy: "/").last ?? lower
        if slug.contains("deepseek-reasoner") || slug.contains("deepseek-r1") || slug == "r1" || slug.hasPrefix("r1-") {
            return .deepSeekThinking(preserveReasoningContentInToolLoop: true)
        }
        return .openAIChatEffort(supported: [.low, .medium, .high])
    }

    static func defaultReasoningMode(for modelID: String) -> ReasoningConfigMode {
        let lower = modelID.lowercased()
        let slug = lower.components(separatedBy: "/").last ?? lower
        if slug.contains("deepseek-reasoner") || slug.contains("deepseek-r1") || slug == "r1" || slug.hasPrefix("r1-") {
            return .deepSeekThinking(preserveReasoningContentInToolLoop: true)
        }
        if slug.hasPrefix("o1") || slug.hasPrefix("o3") || slug.hasPrefix("o4")
            || lower.contains("gpt-5") || lower.contains("codex") || lower.contains("reason")
            || lower.contains("thinking") || lower.contains("v4") || lower.contains("claude-3-7")
            || lower.contains("claude-3.7") || lower.contains("claude-4") || lower.contains("sonnet-4")
            || lower.contains("sonnet-5") || lower.contains("opus-4") || lower.contains("gemini-2.5")
            || lower.contains("gemini-3") || lower.contains("gemini-4")
            || lower.contains("qwq") || lower.contains("qwen3") {
            return .openAIChatEffort(supported: [.low, .medium, .high])
        }
        return .defaultOnly
    }

    static func reasoningMode(for modelID: String, choice: ReasoningChoice) -> ReasoningConfigMode {
        switch choice {
        case .auto:
            return defaultReasoningMode(for: modelID)
        case .defaultOnly:
            return .defaultOnly
        case .openAIEffort:
            return .openAIChatEffort(supported: [.low, .medium, .high])
        case .deepSeekThinking:
            return .deepSeekThinking(preserveReasoningContentInToolLoop: true)
        }
    }

    static func choice(for mode: ReasoningConfigMode) -> ReasoningChoice {
        switch mode {
        case .defaultOnly: return .defaultOnly
        case .openAIChatEffort: return .openAIEffort
        case .deepSeekThinking: return .deepSeekThinking
        }
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? ProviderConfigurationError else { return "The provider settings are not valid." }
        switch error {
        case .invalidURL: return "Enter a full URL such as https://api.example.com/v1."
        case .unsupportedURLComponents: return "Remove credentials, query or fragment from the URL."
        case .insecureScheme: return "Use https. Plain http is only allowed for a local endpoint."
        case .missingModel: return "Enter a model ID."
        }
    }

    private func seedFromDeveloperFile() {
        let env = ProcessInfo.processInfo.environment
        if env["GOPILOT_DEV_SETTINGS_STATE"] == "unconfigured_with_key" {
            baseURL = ""
            modelID = ""
            routes = []
            defaultRouteID = ""
            hasStoredKey = true
            isEditingKey = false
            report = nil
            reportsByHash = [:]
            catalogLoadState = .notLoaded
            return
        }
        if env["GOPILOT_DEV_SEED_CONNECTED"] == "1" {
            baseURL = "https://api.deepseek.com/v1"
            let sonnetRoute = ModelRoute(
                id: "nano/sonnet-5.5",
                displayName: "Claude Sonnet 5.5",
                modelProvider: "anthropic",
                apiProvider: "nanogpt",
                icon: "claude",
                ideRole: "coding",
                contextWindowTokens: 200_000,
                outputTokenLimit: 8_192,
                reasoningMode: .openAIChatEffort(supported: [.low, .medium, .high]),
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsVision: true,
                supportsReasoning: true,
                isManual: false
            )
            let flashRoute = ModelRoute(
                id: "deepseek/v4.1-flash",
                displayName: "DeepSeek V4.1 Flash",
                modelProvider: "deepseek",
                apiProvider: "9r",
                icon: "deepseek",
                ideRole: "coding",
                contextWindowTokens: 64_000,
                outputTokenLimit: 8_192,
                reasoningMode: .openAIChatEffort(supported: [.low, .medium, .high]),
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsVision: false,
                supportsReasoning: true,
                isManual: false
            )
            let geminiRoute = ModelRoute(
                id: "nano/gemini-4-argon",
                displayName: "Gemini 4 Argon",
                modelProvider: "google",
                apiProvider: "nanogpt",
                icon: "google",
                ideRole: "coding",
                contextWindowTokens: 1_000_000,
                outputTokenLimit: 8_192,
                reasoningMode: .openAIChatEffort(supported: [.low, .medium, .high]),
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsVision: true,
                supportsReasoning: true,
                isManual: false
            )
            let chatRoute = ModelRoute(
                id: "deepseek-chat",
                displayName: "DeepSeek V3 Chat",
                modelProvider: "deepseek",
                apiProvider: "9r",
                icon: "deepseek",
                contextWindowTokens: 64_000,
                outputTokenLimit: 4_096,
                reasoningMode: .defaultOnly,
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsReasoning: false,
                isManual: false
            )
            let reasonerRoute = ModelRoute(
                id: "deepseek-reasoner",
                displayName: "DeepSeek R1",
                modelProvider: "deepseek",
                apiProvider: "9r",
                icon: "deepseek",
                contextWindowTokens: 64_000,
                outputTokenLimit: 8_192,
                reasoningMode: .deepSeekThinking(preserveReasoningContentInToolLoop: true),
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsReasoning: true,
                isManual: false
            )
            let effortRoute = ModelRoute(
                id: "o3-mini",
                displayName: "o3-mini",
                modelProvider: "openai",
                apiProvider: "openai",
                icon: "openai",
                contextWindowTokens: 128_000,
                outputTokenLimit: 8_192,
                reasoningMode: .openAIChatEffort(supported: [.low, .medium, .high]),
                declaredCapabilities: [.text, .streaming, .tools],
                supportsFunctionCalling: true,
                supportsReasoning: true,
                isManual: true
            )
            let chatOnlyRoute = ModelRoute(
                id: "deepseek-chat-lite",
                displayName: "DeepSeek Chat Lite",
                modelProvider: "deepseek",
                apiProvider: "9r",
                icon: "deepseek",
                contextWindowTokens: 32_000,
                outputTokenLimit: 2_048,
                reasoningMode: .defaultOnly,
                declaredCapabilities: [.text, .streaming],
                supportsFunctionCalling: false,
                supportsReasoning: false,
                isManual: true
            )
            if let devBaseURL = env["GOPILOT_DEV_BASE_URL"], !devBaseURL.isEmpty {
                baseURL = devBaseURL
            }
            let completionRoutes: [ModelRoute] = env["GOLENS_AI_SUGGESTIONS_DEV_ROUTES"] == "1" ? [
                ModelRoute(id: "mistralai/codestral-2508", displayName: "Codestral 25.08", modelProvider: "mistral", apiProvider: "nanogpt", icon: "mistral",
                           contextWindowTokens: 256_000, outputTokenLimit: 4_096, declaredCapabilities: [.text, .streaming], supportsFunctionCalling: false, supportsReasoning: false),
                ModelRoute(id: "text-completion-codestral/codestral-latest", displayName: "Codestral (FIM)", modelProvider: "mistral", icon: "mistral",
                           contextWindowTokens: 256_000, outputTokenLimit: 4_096, declaredCapabilities: [.text, .streaming], supportsFunctionCalling: false, supportsReasoning: false),
                ModelRoute(id: "openai/qwen2.5-coder-0.5b-base", displayName: "Qwen2.5 Coder 0.5B Base", modelProvider: "qwen",
                           contextWindowTokens: 32_768, outputTokenLimit: 2_048, declaredCapabilities: [.text, .streaming], supportsFunctionCalling: false, supportsReasoning: false)
            ] : []
            if env["GOPILOT_DEV_MODEL_INFO_SAMPLE"] == "1" {
                routes = [sonnetRoute, flashRoute, geminiRoute, effortRoute, chatOnlyRoute]
                defaultRouteID = env["GOPILOT_DEV_DEFAULT_ROUTE"] ?? sonnetRoute.id
            } else {
                routes = [sonnetRoute, flashRoute, geminiRoute, chatRoute, reasonerRoute, effortRoute, chatOnlyRoute] + completionRoutes
                defaultRouteID = env["GOPILOT_DEV_DEFAULT_ROUTE"] ?? flashRoute.id
            }
            modelID = defaultRouteID
            hasStoredKey = true
            isEditingKey = env["GOPILOT_DEV_SETTINGS_STATE"] == "edit_key"

            if let gw = gateway {
                for r in [sonnetRoute, flashRoute, geminiRoute, chatRoute, reasonerRoute, effortRoute] {
                    let hash = r.capabilityHash(for: gw)
                    reportsByHash[hash] = CompatibilityReport(
                        checks: [
                            CompatibilityCheck(id: .text, outcome: .pass, detail: "Chat completion succeeded."),
                            CompatibilityCheck(id: .streaming, outcome: .pass, detail: "SSE stream completed."),
                            CompatibilityCheck(id: .tools, outcome: .pass, detail: "Tool calls supported."),
                            CompatibilityCheck(id: .jsonArguments, outcome: .pass, detail: "JSON arguments valid."),
                            CompatibilityCheck(id: .toolRoundTrip, outcome: .pass, detail: "Tool round-trip succeeded."),
                            CompatibilityCheck(id: .usage, outcome: .pass, detail: "Token usage reported.")
                        ],
                        configHash: hash,
                        testedAt: Date()
                    )
                }
                let chatOnlyHash = chatOnlyRoute.capabilityHash(for: gw)
                reportsByHash[chatOnlyHash] = CompatibilityReport(
                    checks: [
                        CompatibilityCheck(id: .text, outcome: .pass, detail: "Chat completion succeeded."),
                        CompatibilityCheck(id: .streaming, outcome: .pass, detail: "SSE stream completed."),
                        CompatibilityCheck(id: .tools, outcome: .unsupported, detail: "Model answered in text without calling tools."),
                        CompatibilityCheck(id: .jsonArguments, outcome: .notTested, detail: "Skipped because tool calling is unsupported."),
                        CompatibilityCheck(id: .toolRoundTrip, outcome: .notTested, detail: "Skipped because tool calling is unsupported."),
                        CompatibilityCheck(id: .usage, outcome: .pass, detail: "Token usage reported.")
                    ],
                    configHash: chatOnlyHash,
                    testedAt: Date()
                )
            }
            return
        }
        guard let path = env["GOPILOT_DEV_ENV_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        if let base = values["GOPILOT_LIVE_BASE_URL"] { baseURL = base }
        if let model = values["GOPILOT_LIVE_MODEL"] {
            modelID = model
            ensureRouteExists(id: model, makeDefault: true)
        }
        if let key = values["GOPILOT_LIVE_KEY"], !key.isEmpty {
            do {
                try credentials.write(key, for: Self.credentialReference)
                hasStoredKey = true
                isEditingKey = false
                keychainMessage = nil
            } catch {
                keychainMessage = "\(error)"
            }
        }
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(modelID, forKey: Key.model)
    }
}
