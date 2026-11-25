import AppKit
import Foundation
import Observation
import GopilotCompletion
import GopilotPolicy
import GopilotProvider

@Observable
final class AICompletionSettings {
    static let shared = AICompletionSettings()

    enum Key {
        static let enabled = "GoLensAICompletionEnabled"
        static let routeID = "GoLensAICompletionRouteID"
        static let requestStyles = "GoLensAICompletionRequestStyles"
        static let fimTemplates = "GoLensAICompletionFIMTemplates"
        static let length = "GoLensAICompletionMultiline"
        static let privacyAcknowledged = "GoLensAICompletionPrivacyAcknowledged"
        static let privacyMigrated = "GoLensAICompletionPrivacyMigrated"
    }

    enum CheckState: Equatable {
        case notChecked
        case checking
        case finished(CompletionProbeReport)
    }

    var isEnabled = false {
        didSet {
            guard !loading, isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            settingsChanged()
        }
    }

    var routeID = "" {
        didSet {
            guard !loading, routeID != oldValue else { return }
            UserDefaults.standard.set(routeID, forKey: Key.routeID)
            checkState = .notChecked
            settingsChanged()
        }
    }

    var length: CompletionLengthPreference = .automatic {
        didSet {
            guard !loading, length != oldValue else { return }
            UserDefaults.standard.set(length.rawValue, forKey: Key.length)
            settingsChanged()
        }
    }

    private(set) var requestStyles: [String: String] = [:]
    private(set) var fimTemplates: [String: String] = [:]
    private(set) var streamingUnsupported = false
    var privacyAcknowledged = false {
        didSet {
            guard !loading else { return }
            UserDefaults.standard.set(privacyAcknowledged, forKey: Key.privacyAcknowledged)
        }
    }

    var checkState: CheckState = .notChecked
    private(set) var pause: CompletionPause?
    private(set) var lastLatency: TimeInterval?

    @ObservationIgnored private var loading = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    init() {
        load()
    }

    func load() {
        loading = true
        defer { loading = false }
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        routeID = defaults.string(forKey: Key.routeID) ?? ""
        length = defaults.string(forKey: Key.length).flatMap(CompletionLengthPreference.init(rawValue:)) ?? .automatic
        requestStyles = defaults.dictionary(forKey: Key.requestStyles) as? [String: String] ?? [:]
        fimTemplates = defaults.dictionary(forKey: Key.fimTemplates) as? [String: String] ?? [:]
        privacyAcknowledged = defaults.bool(forKey: Key.privacyAcknowledged)
        if !defaults.bool(forKey: Key.privacyMigrated) {
            defaults.set(true, forKey: Key.privacyMigrated)
            if privacyAcknowledged, isEnabled, let host = consentHost {
                AIProviderConsent.shared.allow(host)
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let route = env["GOLENS_AI_SUGGESTIONS_DEV_ROUTE"], !route.isEmpty {
            routeID = route
        }
    }

    var provider: GopilotProviderSettings { GopilotProviderSettings.shared }

    var hasProvider: Bool {
        provider.gateway != nil && provider.hasStoredKey
    }

    var providerHost: String? {
        guard let gateway = provider.gateway else { return nil }
        return URL(string: gateway.baseURL)?.host
    }

    var consentHost: String? {
        provider.gateway.flatMap { AIProviderConsent.host(forBaseURL: $0.baseURL) }
    }

    var needsConsent: Bool {
        isEnabled && hasProvider && !AIProviderConsent.shared.isAllowed(consentHost)
    }

    var selectedRoute: ModelRoute? {
        guard !routeID.isEmpty else { return nil }
        return provider.routes.first { $0.id == routeID } ?? provider.route(for: routeID)
    }

    var selectedModelName: String? {
        selectedRoute.map { GopilotModelIdentity.prettyName(for: $0) }
    }

    var recommendedRoute: ModelRoute? {
        provider.routes.first { $0.id.lowercased().contains("codestral") }
            ?? provider.routes.first { CompletionDialect.suggested(forModelID: $0.id) == .fillInTheMiddle }
    }

    var isReady: Bool {
        isEnabled && hasProvider && selectedRoute != nil && AIProviderConsent.shared.isAllowed(consentHost)
    }

    func requestStyle(for routeID: String) -> CompletionDialect {
        if let stored = requestStyles[routeID], let dialect = CompletionDialect(rawValue: stored) {
            return dialect
        }
        return CompletionDialect.suggested(forModelID: routeID)
    }

    func isRequestStyleOverridden(for routeID: String) -> Bool {
        requestStyles[routeID] != nil
    }

    func setRequestStyle(_ dialect: CompletionDialect, for routeID: String) {
        guard !routeID.isEmpty else { return }
        if dialect == CompletionDialect.suggested(forModelID: routeID) {
            requestStyles[routeID] = nil
        } else {
            requestStyles[routeID] = dialect.rawValue
        }
        UserDefaults.standard.set(requestStyles, forKey: Key.requestStyles)
        checkState = .notChecked
        settingsChanged()
    }

    var currentRequestStyle: CompletionDialect {
        requestStyle(for: routeID)
    }

    func fimTemplate(for routeID: String) -> FIMTemplate {
        if let stored = fimTemplates[routeID], let template = FIMTemplate(rawValue: stored) {
            return template
        }
        return FIMTemplate.suggested(forModelID: routeID)
    }

    func setFIMTemplate(_ template: FIMTemplate, for routeID: String) {
        guard !routeID.isEmpty else { return }
        if template == FIMTemplate.suggested(forModelID: routeID) {
            fimTemplates[routeID] = nil
        } else {
            fimTemplates[routeID] = template.rawValue
        }
        UserDefaults.standard.set(fimTemplates, forKey: Key.fimTemplates)
        checkState = .notChecked
        settingsChanged()
    }

    var currentFIMTemplate: FIMTemplate {
        fimTemplate(for: routeID)
    }

    func updateStreamingUnsupported(_ value: Bool) {
        if streamingUnsupported != value { streamingUnsupported = value }
    }

    var settingsFingerprint: String {
        let gateway = provider.gateway
        return [String(isEnabled), routeID, currentRequestStyle.rawValue, currentFIMTemplate.rawValue, gateway?.baseURL ?? "", String(provider.hasStoredKey)].joined(separator: "|")
    }

    func endpoint(stream: Bool = true) -> CompletionEndpoint? {
        guard hasProvider, let configuration = provider.configuration(for: routeID), !routeID.isEmpty else { return nil }
        return try? CompletionEndpoint(configuration: configuration, apiKey: provider.currentSecrets().first, dialect: currentRequestStyle, fimTemplate: currentFIMTemplate, stream: stream)
    }

    func updatePause(_ pause: CompletionPause?) {
        if self.pause != pause { self.pause = pause }
    }

    func recordLatency(_ seconds: TimeInterval) {
        lastLatency = seconds
    }

    private func settingsChanged() {
        AISuggestionEngine.shared.settingsDidChange()
    }

    func runCheck() {
        guard AIProviderConsent.shared.isAllowed(consentHost), let endpoint = endpoint(stream: true) else { return }
        checkTask?.cancel()
        checkState = .checking
        let probe = CompletionProbe(transport: AISuggestionEngine.shared.transport, userAgent: AISuggestionEngine.userAgent)
        checkTask = Task { @MainActor [weak self] in
            let report = await probe.run(endpoint: endpoint)
            guard let self, !Task.isCancelled else { return }
            self.checkState = .finished(report)
            if report.streamingFailed { self.updateStreamingUnsupported(true) }
            switch report.result {
            case .fimHonored, .fimUnconfirmed, .chatWorks, .fimTemplateWorks:
                AISuggestionEngine.shared.settingsDidChange()
            default:
                break
            }
        }
    }

    static func describe(_ report: CompletionProbeReport) -> (text: String, isProblem: Bool) {
        var described = describe(report.result)
        if report.usedNativeContent {
            described.text += " The proxy passed the server’s own response format through (the text arrived in a top-level “content” field instead of choices[0].text). GoLens reads it, but other clients of this route may not."
        }
        if report.streamingFailed {
            described.text += " Streaming requests fail on this route, so GoLens asks for single responses instead."
        }
        return described
    }

    static func describe(_ result: CompletionProbeResult) -> (text: String, isProblem: Bool) {
        switch result {
        case .fimHonored(let latency, _, _):
            return ("Responds in \(format(latency)). Code after the cursor is used.", false)
        case .fimUnconfirmed(let latency):
            return ("Responds in \(format(latency)). The provider didn’t report token usage, so GoLens couldn’t confirm that code after the cursor is used.", false)
        case .fimSuffixIgnored:
            return ("The provider ignored the code after the cursor: this route doesn’t support the suffix parameter, or the template doesn’t match the model. Choose the model’s template under FIM Template (for example Qwen2.5-Coder), or choose Chat.", true)
        case .fimTemplateWorks(let latency):
            return ("Responds in \(format(latency)) using the model’s fill-in-the-middle template.", false)
        case .fimNotSupported:
            return ("This model doesn’t support fill-in-the-middle requests. Choose Chat as the request style.", true)
        case .chatWorks(let latency):
            return ("Responds in \(format(latency))", false)
        case .empty(let latency):
            return ("Responded in \(format(latency)) without a suggestion. Try another model.", true)
        case .failed(let failure):
            return ("Couldn’t get a suggestion: \(failure.shortReason).", true)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }
}

final class AISuggestionEngine {
    static let shared = AISuggestionEngine()
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "GoLens/\(version)"
    }()
    static let remoteDebounce: TimeInterval = 0.3
    static let loopbackDebounce: TimeInterval = 0.2

    let transport: URLSessionTransport
    let service: CompletionService
    let scheduler = CompletionScheduler()
    private var backoff = CompletionBackoff()
    private var pausedFingerprint: String?
    private(set) var requestCount = 0

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = CompletionClient.defaultTimeoutSeconds + 1
        transport = AIProviderConsent.makeTransport(configuration: configuration)
        service = CompletionService(client: CompletionClient(transport: transport, userAgent: Self.userAgent))
    }

    var debounce: TimeInterval {
        let host = AICompletionSettings.shared.providerHost?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "::1"].contains(host) ? Self.loopbackDebounce : Self.remoteDebounce
    }

    func activePause() -> CompletionPause? {
        let settings = AICompletionSettings.shared
        if case .untilSettingsChange = backoff.pause, pausedFingerprint != settings.settingsFingerprint {
            backoff.reset()
        }
        let pause = backoff.activePause(at: Date())
        settings.updatePause(pause)
        return pause
    }

    func settingsDidChange() {
        backoff.reset()
        service.resetStreamingObservations()
        AICompletionSettings.shared.updateStreamingUnsupported(false)
        pausedFingerprint = nil
        scheduler.cancel()
        service.cache.removeAll()
        AICompletionSettings.shared.updatePause(nil)
        NotificationCenter.default.post(name: .golensAISuggestionsChanged, object: nil)
    }

    func record(_ outcome: CompletionOutcome) {
        let settings = AICompletionSettings.shared
        switch outcome {
        case .suggestion(_, let cached, let latency):
            backoff.recordSuccess()
            if !cached { settings.recordLatency(latency) }
            requestCount += cached ? 0 : 1
        case .empty(let latency):
            backoff.recordSuccess()
            settings.recordLatency(latency)
            requestCount += 1
        case .failed(let failure):
            requestCount += 1
            var effective = failure
            if failure == .endpointNotFound, settings.currentRequestStyle == .fillInTheMiddle {
                settings.checkState = .finished(CompletionProbeReport(result: .fimNotSupported))
                effective = .endpointNotFound
            }
            backoff.record(effective, at: Date())
            if failure.requiresSettingsChange { pausedFingerprint = settings.settingsFingerprint }
            measureLog("ai suggestion failed: \(failure.shortReason)")
        case .cancelled:
            break
        }
        if let endpoint = settings.endpoint(), service.streamingUnsupported(for: endpoint) {
            settings.updateStreamingUnsupported(true)
        }
        settings.updatePause(backoff.activePause(at: Date()))
    }
}

extension Notification.Name {
    static let golensAISuggestionsChanged = Notification.Name("GoLensAISuggestionsChanged")
}
