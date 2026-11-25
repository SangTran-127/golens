import GopilotProvider
import GopilotRuntime
import GopilotStore
import SwiftUI

struct GopilotSettingsPane: View {
    @Bindable private var settings = GopilotProviderSettings.shared
    #if DEBUG
    @State private var showsModels = ProcessInfo.processInfo.environment["GOPILOT_DEV_SETTINGS_MODELS"] == "1"
    @State private var showsAdvanced =
        ProcessInfo.processInfo.environment["GOPILOT_DEV_SETTINGS_ADVANCED"] == "1"
        || ProcessInfo.processInfo.environment["GOPILOT_DEV_SETTINGS_DETAILS"] == "1"
    #else
    @State private var showsModels = false
    @State private var showsAdvanced = false
    #endif
    @State private var confirmingRemoveKey = false
    @State private var showingPrivacyDetails = false
    @State private var pendingConsentHost: String?
    @State private var pendingConsentAction: (@MainActor () async -> Void)?
    private var consent = AIProviderConsent.shared

    private var availableModelsTitle: String {
        if settings.isFetchingModels || settings.catalogLoadState == .loading {
            return "Available Models — Loading…"
        }
        if !settings.routes.isEmpty {
            return "Available Models (\(settings.routes.count))"
        }
        switch settings.catalogLoadState {
        case .notLoaded:
            return "Available Models — Not loaded"
        case .loading:
            return "Available Models — Loading…"
        case .failed:
            return "Available Models — Couldn’t load"
        case .loaded(let count):
            return count == 0 ? "Available Models (0) — No models returned" : "Available Models (\(count))"
        }
    }

    private var privacyParagraphs: [String] {
        var paragraphs = ["Relevant code is sent to your configured provider when you ask. Conversations are stored on this Mac."]
        if AICompletionSettings.shared.isEnabled {
            paragraphs.append("AI Suggestions also send code around the cursor while you type.")
        }
        return paragraphs
    }

    var body: some View {
        SettingsForm {
            SettingsSection("Provider", footer: "Provider used across projects in GoLens.") {
                SettingsFieldRow("Provider URL") {
                    TextField("", text: $settings.baseURL, prompt: Text("https://api.openai.com/v1"))
                        .settingsTextField()
                        .accessibilityLabel("Provider URL")
                } help: {
                    if let problem = settings.urlProblem {
                        SettingsFieldHelp(problem, systemImage: "exclamationmark.triangle")
                    } else {
                        SettingsFieldHelp("OpenAI-compatible base URL (OpenAI, DeepSeek, LiteLLM, or local Ollama).")
                    }
                }

                apiKeyRow

                defaultModelRow

                statusRow

                DisclosureGroup(availableModelsTitle, isExpanded: $showsModels) {
                    availableModelsContent
                }

                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    advancedContent
                }
            }

            SettingsSection("Project Notes") {
                SettingsNote("Project Notes live per project in the Gopilot panel header, where you can toggle note recall, manage saved notes, or open GOLENS.md.")
            }

            SettingsSection("Privacy") {
                SettingsExplanation(privacyParagraphs, detailsTitle: "Privacy Details…", isPresented: $showingPrivacyDetails) {
                    GopilotPrivacyDetailsPopover()
                }
                if let host = AIProviderConsent.host(forBaseURL: settings.baseURL), !AIProviderConsent.isLoopback(host) {
                    SettingsFieldRow("Sending Code") {
                        HStack(spacing: SettingsMetrics.rowSpacing) {
                            if consent.isAllowed(host) {
                                SettingsStatus("Allowed to \(host)", tone: .success)
                                Spacer(minLength: SettingsMetrics.rowSpacing)
                                Button("Revoke") { consent.revoke(host) }
                                    .help("Gopilot and AI Suggestions ask again before sending code to \(host).")
                            } else {
                                SettingsStatus("Asks before sending to \(host)")
                            }
                        }
                    }
                }
            }
        }
        .alert("Remove API Key?", isPresented: $confirmingRemoveKey) {
            Button("Remove Key", role: .destructive) {
                settings.removeKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gopilot disconnects from this provider until you save a new key.")
        }
        .alert(
            "Send Code to \(pendingConsentHost ?? "Provider")?",
            isPresented: Binding(
                get: { pendingConsentHost != nil },
                set: { presented in
                    if !presented {
                        pendingConsentHost = nil
                        pendingConsentAction = nil
                    }
                }
            )
        ) {
            Button("Allow") {
                let host = pendingConsentHost
                let action = pendingConsentAction
                pendingConsentHost = nil
                pendingConsentAction = nil
                if let host { consent.allow(host) }
                if let action { Task { @MainActor in await action() } }
            }
            Button("Cancel", role: .cancel) {
                pendingConsentHost = nil
                pendingConsentAction = nil
            }
        } message: {
            Text(AIProviderConsent.disclosure(host: pendingConsentHost ?? "this provider"))
        }
    }

    private func runWithConsent(_ action: @escaping @MainActor () async -> Void) {
        guard let host = AIProviderConsent.host(forBaseURL: settings.baseURL) else { return }
        if consent.isAllowed(host) {
            Task { @MainActor in await action() }
            return
        }
        pendingConsentHost = host
        pendingConsentAction = action
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        if settings.hasStoredKey && !settings.isEditingKey {
            SettingsFieldRow("API Key") {
                    HStack(spacing: SettingsMetrics.rowSpacing) {
                        SettingsStatus(settings.storedKeyStatusText, symbol: settings.credentialLocation == .keychain ? "lock.fill" : "key.fill")
                            .help("The API key is sent only to the provider URL above.")
                        Spacer(minLength: SettingsMetrics.rowSpacing)
                        Button("Change…") {
                            settings.beginEditingKey()
                        }
                        Menu {
                            Button("Change Key…", systemImage: "key") {
                                settings.beginEditingKey()
                            }
                            Divider()
                            Button("Remove Key…", systemImage: "trash", role: .destructive) {
                                confirmingRemoveKey = true
                            }
                        } label: {
                            Label("Key Options", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Key management options")
                        .accessibilityLabel("Key management options")
                    }
            } help: {
                if let message = settings.credentialMigrationMessage {
                    SettingsFieldHelp(message, systemImage: "exclamationmark.triangle.fill")
                }
            }
        } else {
            SettingsFieldRow("API Key") {
                HStack(spacing: SettingsMetrics.rowSpacing) {
                    SecureField("", text: $settings.apiKeyDraft, prompt: Text(settings.hasStoredKey ? "Enter new API key" : "Enter API key"))
                        .settingsTextField()
                        .accessibilityLabel(settings.hasStoredKey ? "New API key" : "API key")
                    Button("Save") {
                        settings.saveKey()
                    }
                    .disabled(settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasStoredKey {
                        Button("Cancel") {
                            settings.cancelEditingKey()
                        }
                    }
                }
            } help: {
                if let message = settings.credentialMigrationMessage {
                    SettingsFieldHelp(message, systemImage: "exclamationmark.triangle.fill")
                }
                if let message = settings.keychainMessage {
                    SettingsFieldHelp(message, systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    @ViewBuilder
    private var defaultModelRow: some View {
        SettingsFieldRow("Default Model") {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                if settings.routes.count > 1 {
                    GopilotModelIconView(
                        route: settings.defaultRoute,
                        modelID: settings.defaultRoute?.id ?? settings.modelID,
                        size: 16
                    )
                    Picker("Default Model", selection: Binding(
                        get: { settings.defaultRoute?.id ?? settings.modelID },
                        set: { newID in settings.setDefaultRoute(id: newID) }
                    )) {
                        ForEach(settings.routes) { route in
                            let pretty = GopilotModelIdentity.prettyName(for: route)
                            Text(pretty).tag(route.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Default Model")
                } else {
                    GopilotModelIconView(
                        route: settings.defaultRoute,
                        modelID: settings.modelID,
                        size: 16
                    )
                    TextField("", text: $settings.modelID, prompt: Text("Enter model ID or fetch"))
                        .settingsTextField()
                        .accessibilityLabel("Default Model")
                }

                Button {
                    runWithConsent { await settings.fetchModels() }
                } label: {
                    if settings.isFetchingModels {
                        HStack(spacing: Spacing.compact) {
                            ProgressView().controlSize(.small)
                            Text("Fetching…")
                        }
                    } else {
                        Label("Fetch Models", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .controlSize(.small)
                .disabled(settings.isFetchingModels || settings.gateway == nil || !settings.hasStoredKey)
                .help(
                    settings.gateway == nil
                        ? "Enter a valid Provider URL first"
                        : (!settings.hasStoredKey ? "Save an API key first" : "Load available models from your provider")
                )
            }
        } help: {
            if let msg = settings.catalogMessage {
                SettingsFieldHelp(msg)
            }
            SettingsFieldHelp("Used for new conversations. Active chats keep their selected model.")
        }
    }

    private var statusRow: some View {
        SettingsFieldRow("Status") {
            HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
                if settings.isTesting {
                    SettingsStatus(busy: settings.testingRouteID.map { "Testing \($0)…" } ?? "Testing connection…")
                } else if let report = settings.report {
                    SettingsStatus(Self.modeHeadline(report.agentMode), detail: Self.modeDetail(report), tone: Self.modeTone(report.agentMode))
                } else {
                    SettingsStatus("Not tested", detail: settings.missingConfigurationHint ?? "Test connection to verify model and tool support.")
                }
                Spacer(minLength: SettingsMetrics.rowSpacing)
                Button("Test Connection") {
                    runWithConsent { await settings.testConnection() }
                }
                .disabled(settings.isTesting || settings.configuration == nil || !settings.hasStoredKey)
            }
        }
    }

    private var availableModelsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            if !settings.routes.isEmpty {
                ForEach(settings.routes) { route in
                    let pretty = GopilotModelIdentity.prettyName(for: route)
                    let apiSource = GopilotModelIdentity.prettyAPISource(route.apiProvider)
                    let tier = settings.routeTier(for: route.id)
                    SettingsItemRow(pretty, subtitle: Self.routeMetadataSubtitle(route: route, prettyName: pretty, apiSource: apiSource)) {
                        GopilotModelIconView(route: route, modelID: route.id, size: 18)
                            .frame(width: SettingsMetrics.tileSize, height: SettingsMetrics.tileSize)
                    } badges: {
                        if route.id == settings.defaultRoute?.id {
                            SettingsBadge("Default")
                        }
                        SettingsBadge(tier.badgeTitle, tint: tier == .verifiedChatOnly ? .orange : .secondary)
                    } accessory: {
                        Menu {
                            if route.id != settings.defaultRoute?.id {
                                Button("Set as Default", systemImage: "star") {
                                    settings.setDefaultRoute(id: route.id)
                                }
                            }
                            Button("Check This Model", systemImage: "checkmark.circle") {
                                runWithConsent { await settings.testConnection(routeID: route.id) }
                            }
                            .disabled(settings.isTesting || !settings.hasStoredKey)

                            Menu("Reasoning Profile", systemImage: "brain") {
                                ForEach(GopilotProviderSettings.ReasoningChoice.allCases.filter { $0 != .auto }) { choice in
                                    Button {
                                        let mode = GopilotProviderSettings.reasoningMode(for: route.id, choice: choice)
                                        settings.updateRouteReasoning(id: route.id, mode: mode)
                                    } label: {
                                        if GopilotProviderSettings.choice(for: route.reasoningMode) == choice {
                                            Label(choice.title, systemImage: "checkmark")
                                        } else {
                                            Text(choice.title)
                                        }
                                    }
                                }
                            }

                            if settings.routes.count > 1 {
                                Divider()
                                Button("Remove Route", systemImage: "trash", role: .destructive) {
                                    settings.removeRoute(id: route.id)
                                }
                            }
                        } label: {
                            Label("Route Actions for \(route.displayName)", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Actions for \(route.displayName)")
                        .accessibilityLabel("Actions for \(route.displayName)")
                    }
                }
            } else {
                SettingsFieldHelp("Click “Fetch Models” above to load models from your provider, or add a model ID manually below.")
            }

            HStack(spacing: SettingsMetrics.rowSpacing) {
                TextField("", text: $settings.manualRouteDraft, prompt: Text("Add model ID manually (for example, gpt-4.1)"))
                    .settingsTextField()
                    .accessibilityLabel("Add model ID manually")
                    .onSubmit { settings.addManualRoute() }
                Button("Add Model") {
                    settings.addManualRoute()
                }
                .disabled(settings.manualRouteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.top, Spacing.compact)
    }

    @ViewBuilder
    private var advancedContent: some View {
        SettingsFieldRow("Context Window") {
            TextField("", text: $settings.contextWindowText, prompt: Text("Tokens (optional, e.g. 64000)"))
                .settingsTextField()
                .accessibilityLabel("Context window in tokens, optional")
        }
        Toggle("Allow Local HTTP Endpoint (localhost)", isOn: $settings.localEndpoint)

        if !settings.previewURL.isEmpty {
            LabeledContent("Chat Endpoint") {
                Text(settings.previewURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if !settings.modelsPreviewURL.isEmpty {
            LabeledContent("Models Endpoint") {
                Text(settings.modelsPreviewURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let report = settings.report {
            LabeledContent("Last Verified") {
                Text(report.testedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.checks, id: \.id) { check in
                LabeledContent(Self.checkTitle(check.id)) {
                    SettingsStatus(Self.checkOutcomeTitle(check.outcome), tone: Self.checkTone(check.outcome))
                        .font(.caption)
                        .help(check.detail)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.checkTitle(check.id)): \(Self.checkOutcomeTitle(check.outcome)). \(check.detail)")
            }
        }
    }

    static func routeMetadataSubtitle(route: ModelRoute, prettyName: String, apiSource: String?) -> String {
        var parts: [String] = []
        if let apiSource, !apiSource.isEmpty {
            parts.append(apiSource)
        }
        if prettyName != route.id {
            parts.append(route.id)
        }
        parts.append(Self.reasoningLabel(route.reasoningMode))
        return parts.joined(separator: " · ")
    }

    static func reasoningLabel(_ mode: ReasoningConfigMode) -> String {
        switch mode {
        case .defaultOnly:
            "Reasoning: Default only"
        case .openAIChatEffort:
            "Reasoning: Effort (Low / Medium / High)"
        case .deepSeekThinking:
            "Reasoning: DeepSeek thinking"
        }
    }

    static func modeHeadline(_ mode: AgentMode) -> String {
        switch mode {
        case .agent: "Connected"
        case .chatOnly: "Connected"
        case .unavailable: "Connection failed"
        }
    }

    static func modeDetail(_ report: CompatibilityReport) -> String {
        switch report.agentMode {
        case .agent:
            return "Project tools available"
        case .chatOnly:
            return "Chat only (tools unavailable)"
        case .unavailable:
            let detail = report.check(.text).detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty && detail != "Not part of this run." {
                return detail
            }
            return "Check URL, model, or key"
        }
    }

    static func modeDetail(_ mode: AgentMode) -> String {
        switch mode {
        case .agent: "Project tools available"
        case .chatOnly: "Chat only (tools unavailable)"
        case .unavailable: "Check URL, model, or key"
        }
    }

    static func modeText(_ mode: AgentMode) -> String {
        switch mode {
        case .agent: "Connected · Project tools available"
        case .chatOnly: "Connected · Chat only (tools unavailable)"
        case .unavailable: "Connection failed · Check URL, model, or key"
        }
    }

    static func modeTone(_ mode: AgentMode) -> StatusTone {
        switch mode {
        case .agent: .success
        case .chatOnly: .warning
        case .unavailable: .failure
        }
    }

    static func checkTitle(_ id: CheckID) -> String {
        switch id {
        case .text: "Chat"
        case .streaming: "Streaming"
        case .nonStreaming: "Non-streaming"
        case .tools: "Tool calls"
        case .jsonArguments: "Tool arguments"
        case .toolRoundTrip: "Tool round trip"
        case .cancellation: "Cancellation"
        case .usage: "Usage reporting"
        case .streamUsage: "Usage while streaming"
        case .parallelToolCalls: "Parallel tool calls"
        case .strictSchema: "Strict schema"
        case .maxTokensParameter: "Output limit parameter"
        }
    }

    static func checkOutcomeTitle(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .pass: "Pass"
        case .unsupported: "Unsupported"
        case .notTested: "Not tested"
        }
    }

    static func checkTone(_ outcome: CheckOutcome) -> StatusTone {
        switch outcome {
        case .pass: .success
        case .unsupported: .failure
        case .notTested: .inactive
        }
    }
}

private struct GopilotPrivacyDetailsPopover: View {
    @Bindable private var settings = GopilotProviderSettings.shared

    static func keyStorageSentence(_ location: GopilotProviderSettings.CredentialLocation) -> String {
        switch location {
        case .keychain: "Your API key is stored in the macOS Keychain."
        case .localFile: "Your API key is stored in a local file on this Mac."
        case .memory: "Your API key is kept in memory for this session only."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("Gopilot Privacy Details")
                .font(.headline)
            Text("When you send a message, Gopilot transmits your prompt, explicitly attached files or symbols, and any project evidence read during that turn to the configured gateway URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("When Project Context is turned off in the composer, Gopilot only reads the sources you explicitly attach to that turn and blocks workspace-wide search and tool calls.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Sensitive paths such as .env files, SSH keys, and private certificates are blocked by path policy, and known credential patterns are redacted on a best-effort basis before sending.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Conversation history and saved project notes stay on this Mac. \(Self.keyStorageSentence(settings.credentialLocation)) It is only sent to the configured gateway.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.comfortable)
        .frame(width: 380)
    }
}
