import SwiftUI
import GopilotCompletion
import GopilotProvider

struct AISuggestionsSettingsPage: View {
    @Bindable private var settings = AICompletionSettings.shared
    @Bindable private var provider = GopilotProviderSettings.shared
    private var consent = AIProviderConsent.shared
    @State private var confirmingEnable = false
    @State private var showingPrivacyDetails = false
    @State private var pendingActionHost: String?
    @State private var pendingAction: (@MainActor () async -> Void)?
    @Environment(\.openSettingsPane) private var openPane

    private var hostName: String {
        settings.consentHost ?? "your Gopilot provider"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.isEnabled }, set: { newValue in
            if newValue && (!settings.privacyAcknowledged || !consent.isAllowed(settings.consentHost)) {
                confirmingEnable = true
            } else {
                settings.isEnabled = newValue
            }
        })
    }

    private var routeBinding: Binding<String> {
        Binding(get: { settings.routeID }, set: { settings.routeID = $0 })
    }

    private var styleBinding: Binding<CompletionDialect> {
        Binding(get: { settings.currentRequestStyle }, set: { settings.setRequestStyle($0, for: settings.routeID) })
    }

    private var templateBinding: Binding<FIMTemplate> {
        Binding(get: { settings.currentFIMTemplate }, set: { settings.setFIMTemplate($0, for: settings.routeID) })
    }

    var body: some View {
        SettingsForm {
            SettingsSection(footer: "Shows gray suggestions in Go files as you type. Press Tab to accept or Esc to dismiss.") {
                Toggle("Suggest Code While Typing", isOn: enabledBinding)
                    .disabled(!settings.hasProvider)
                    .accessibilityLabel("Suggest Code While Typing")
                if !settings.hasProvider {
                    SettingsNote("Set up a provider in Gopilot settings to use AI Suggestions.") {
                        Button("Open Gopilot Settings") { openPane("gopilot") }
                    }
                }
                if settings.needsConsent {
                    SettingsNote("AI Suggestions are paused until you allow GoLens to send code to \(hostName).") {
                        Button("Allow…") { confirmingEnable = true }
                    }
                }
            }

            SettingsSection("Model", footer: modelFooter) {
                modelRow
                Picker("Request Style", selection: styleBinding) {
                    Text("Chat").tag(CompletionDialect.chatHoleFill)
                    Text("Fill-in-the-Middle").tag(CompletionDialect.fillInTheMiddle)
                }
                .disabled(settings.routeID.isEmpty)
                .accessibilityLabel("Request Style")
                if settings.currentRequestStyle == .fillInTheMiddle, !settings.routeID.isEmpty {
                    Picker("FIM Template", selection: templateBinding) {
                        Text("Suffix Parameter").tag(FIMTemplate.suffixParameter)
                        Divider()
                        ForEach(FIMTemplate.allCases.filter(\.isRawTemplate), id: \.self) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                    .accessibilityLabel("FIM Template")
                }
                statusRow
            }

            SettingsSection("Behavior", footer: "Multiple lines appear only when the rest of the line is empty. Suggestions don’t appear while the completion list or a snippet is active.") {
                Picker("Suggestion Length", selection: $settings.length) {
                    Text("Automatic (Multiple Lines When Useful)").tag(CompletionLengthPreference.automatic)
                    Text("Single Line").tag(CompletionLengthPreference.singleLine)
                }
                .accessibilityLabel("Suggestion Length")
            }

            SettingsSection("Privacy") {
                SettingsExplanation([privacyText], detailsTitle: "Privacy Details…", isPresented: $showingPrivacyDetails) {
                    AISuggestionsPrivacyDetails()
                }
            }
        }
        .alert("Turn On AI Suggestions?", isPresented: $confirmingEnable) {
            Button("Turn On") {
                if let host = settings.consentHost { consent.allow(host) }
                settings.privacyAcknowledged = true
                settings.isEnabled = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("After each pause in typing in a Go file, GoLens sends the code around the cursor and the file’s path to \(hostName). Environment files, private keys and certificates are never sent, and recognized credentials are removed first. Gopilot chat uses the same permission for this provider.")
        }
        .alert(
            "Send Code to \(pendingActionHost ?? "Provider")?",
            isPresented: Binding(
                get: { pendingActionHost != nil },
                set: { presented in
                    if !presented {
                        pendingActionHost = nil
                        pendingAction = nil
                    }
                }
            )
        ) {
            Button("Allow") {
                let host = pendingActionHost
                let action = pendingAction
                pendingActionHost = nil
                pendingAction = nil
                if let host { consent.allow(host) }
                if let action { Task { @MainActor in await action() } }
            }
            Button("Cancel", role: .cancel) {
                pendingActionHost = nil
                pendingAction = nil
            }
        } message: {
            Text(AIProviderConsent.disclosure(host: pendingActionHost ?? hostName))
        }
    }

    private func runWithConsent(_ action: @escaping @MainActor () async -> Void) {
        guard let host = settings.consentHost else { return }
        if consent.isAllowed(host) {
            Task { @MainActor in await action() }
            return
        }
        pendingActionHost = host
        pendingAction = action
    }

    private var privacyText: String {
        "After each pause in typing, GoLens sends about 200 lines of code around the cursor in the current Go file, and the file’s path, to \(hostName). Environment files, private keys and certificates are never sent, and recognized credentials are removed first. The provider’s terms decide whether it keeps this code."
    }

    private var modelFooter: String {
        let base = "Suggestions use their own model, separate from Gopilot chat. Fast models without reasoning work best."
        guard !settings.routeID.isEmpty else { return base }
        switch settings.currentRequestStyle {
        case .fillInTheMiddle:
            let template = settings.currentFIMTemplate
            let detail = template.isRawTemplate
                ? " Fill-in-the-Middle writes the code before and after the cursor into the \(template.displayName) template and sends it to the provider’s completions endpoint; use this when the route ignores the suffix parameter."
                : " Fill-in-the-Middle sends the code before and after the cursor to the provider’s completions endpoint with the suffix parameter."
            let streaming = settings.streamingUnsupported ? " Streaming fails on this route, so single responses are used." : ""
            return base + detail + streaming
        case .chatHoleFill:
            return base + " Chat asks the model to fill the gap at the cursor."
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        let loading = provider.isFetchingModels || provider.catalogLoadState == .loading
        LabeledContent("Model") {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                if loading {
                    SettingsStatus(busy: "Loading Models…")
                } else if provider.routes.isEmpty {
                    SettingsStatus(provider.catalogLoadState == .failed ? "Couldn’t load models" : (provider.catalogLoadState == .notLoaded ? "Models not loaded" : "No models available"))
                    Button("Fetch Models") { runWithConsent { await provider.fetchModels() } }
                        .controlSize(.small)
                        .disabled(!settings.hasProvider)
                } else {
                    GopilotModelIconView(route: settings.selectedRoute, modelID: settings.routeID, size: 16)
                        .accessibilityHidden(true)
                    Picker("Model", selection: routeBinding) {
                        if settings.routeID.isEmpty {
                            Text("Choose a Model").tag("")
                        }
                        ForEach(provider.routes) { route in
                            Text(GopilotModelIdentity.prettyName(for: route)).tag(route.id)
                        }
                        if !settings.routeID.isEmpty, !provider.routes.contains(where: { $0.id == settings.routeID }) {
                            Text(settings.routeID).tag(settings.routeID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Model")
                }
            }
        }
        if settings.routeID.isEmpty, let recommended = settings.recommendedRoute {
            LabeledContent {
                Button("Use \(GopilotModelIdentity.prettyName(for: recommended))") { settings.routeID = recommended.id }
                    .controlSize(.small)
            } label: {
                Text("Recommended for suggestions")
                    .foregroundStyle(.secondary)
            }
        } else if let route = settings.selectedRoute {
            LabeledContent("Model ID") {
                Text(route.id)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.rowSpacing) {
                statusContent
                Button("Test") { runWithConsent { settings.runCheck() } }
                    .controlSize(.small)
                    .disabled(settings.endpoint() == nil || settings.checkState == .checking)
                    .help("Send one small suggestion request and report the result")
                    .accessibilityLabel("Test Suggestions")
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if settings.routeID.isEmpty {
            SettingsStatus("Choose a model to start")
        } else {
            switch settings.checkState {
            case .checking:
                SettingsStatus(busy: "Checking…")
            case .finished(let result):
                let described = AICompletionSettings.describe(result)
                SettingsStatus(described.text, tone: described.isProblem ? .warning : .success)
            case .notChecked:
                if let pause = settings.pause {
                    SettingsStatus("Paused: \(pause.reason)", tone: .warning)
                } else if let latency = settings.lastLatency {
                    SettingsStatus("Last suggestion took \(AICompletionSettings.format(latency))")
                } else {
                    SettingsStatus("Not tested")
                }
            }
        }
    }
}

private struct AISuggestionsPrivacyDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text("What AI Suggestions Send")
                .font(.headline)
            Text("Only while the setting is on and you type in a Go file: up to about 6,000 characters before the cursor, 2,000 after it, the package and import lines, and the file’s path inside the project.")
            Text("Environment files (.env), private keys, certificates and credential files are never sent, and neither are files that Gopilot excludes. Recognized credentials, including your API key, are replaced before sending; if one is right before the cursor, no request is made.")
            Text("Requests go to the Gopilot provider with your saved API key. Nothing is stored by GoLens beyond a short-lived in-memory cache.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.comfortable)
        .frame(width: 380)
    }
}
