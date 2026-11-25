import SwiftUI

enum ServiceSymbol {
    static let services = "server.rack"
    static let container = "shippingbox"
    static let project = "square.stack.3d.up"
    static let image = "cube.transparent"
    static let volume = "externaldrive"
    static let logs = "text.alignleft"
    static let details = "list.bullet.below.rectangle"
    static let shell = "terminal"
    static let start = "play.fill"
    static let stop = "stop.fill"
    static let restart = "arrow.clockwise.circle"
    static let remove = "trash"
    static let copy = "doc.on.doc"
    static let openProvider = "arrow.up.right.square"
    static let refresh = "arrow.clockwise"
    static let openInBrowser = "arrow.up.right.square"
    static let rebuild = "hammer"
    static let network = "point.3.connected.trianglepath.dotted"
    static let cleanUp = "xmark.bin"
    static let context = "cable.connector"
    static let kubernetes = "helm"
    static let pod = "circle.grid.2x2"
    static let deployment = "rectangle.stack"
    static let kubeService = "dot.radiowaves.left.and.right"
    static let namespace = "square.dashed"
    static let portForward = "arrow.right.circle"
    static let apply = "arrow.up.doc"
    static let readOnly = "lock"
    static let kubectlDefault = "pin"
}

protocol ServiceSectionProvider {
    var id: String { get }
    var isAvailable: Bool { get }
    var blockingState: AnyView? { get }
    func hasMatches(filter: String) -> Bool
    func section(filter: String) -> AnyView
    func detail(for selection: ServiceSelection) -> AnyView
    func headerActions(for selection: ServiceSelection) -> AnyView
    func contextMenu(for selection: ServiceSelection) -> AnyView
    func primaryAction(_ selection: ServiceSelection)
    func delete(_ selection: ServiceSelection)
}

enum ServiceProviders {
    static func all(workspace: WorkspaceState, window: ServicesWindowState) -> [any ServiceSectionProvider] {
        [DockerServiceProvider(workspace: workspace, window: window), KubernetesServiceProvider(workspace: workspace, window: window)]
    }
}

struct ServicesPanelView: View {
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let store = ServicesStore.shared
        let window = store.window(for: workspace)
        let providers = ServiceProviders.all(workspace: workspace, window: window).filter(\.isAvailable)
        let prompting = window.kube.namespacePrompt
        ServicesPanelContent(workspace: workspace, window: window, providers: providers)
            .onAppear { store.panelAppeared(window, workspace: workspace) }
            .onDisappear { store.panelDisappeared(window) }
            .alert(
                confirmationTitle(window.confirmation),
                isPresented: Binding(get: { window.confirmation != nil }, set: { if !$0 { window.confirmation = nil } }),
                presenting: window.confirmation
            ) { confirmation in
                Button(confirmationAction(confirmation), role: confirmation.isDestructive ? .destructive : nil) {
                    store.confirm(confirmation, from: workspace)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmationMessage(confirmation))
            }
            .alert("Choose a Namespace", isPresented: Binding(get: { prompting }, set: { window.kube.namespacePrompt = $0 })) {
                TextField("Namespace", text: Binding(get: { window.kube.namespaceDraft }, set: { window.kube.namespaceDraft = $0 }))
                Button("Use Namespace") { store.selectKubeNamespace(window.kube.namespaceDraft) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Context “\(store.kube.context)”. Type the namespace to show.")
            }
    }

    private func confirmationTitle(_ confirmation: ServiceConfirmation?) -> String {
        switch confirmation {
        case .removeContainer(_, let name): "Remove Container “\(name)”?"
        case .removeImage(_, let name, _): "Remove Image “\(name)”?"
        case .removeVolume(let name): "Remove Volume “\(name)”?"
        case .removeNetwork(_, let name): "Remove Network “\(name)”?"
        case .deletePod(_, _, let name, _): "Delete Pod “\(name)”?"
        case .rolloutRestart(_, _, let name): "Restart Deployment “\(name)”?"
        case .useKubectlDefault(let context): "Use “\(context)” as the kubectl Default?"
        case nil: ""
        }
    }

    private func confirmationAction(_ confirmation: ServiceConfirmation) -> String {
        switch confirmation {
        case .removeContainer: "Remove Container"
        case .removeImage: "Remove Image"
        case .removeVolume: "Remove Volume"
        case .removeNetwork: "Remove Network"
        case .deletePod: "Delete Pod"
        case .rolloutRestart: "Rollout Restart"
        case .useKubectlDefault: "Use as kubectl Default"
        }
    }

    private func confirmationMessage(_ confirmation: ServiceConfirmation) -> String {
        switch confirmation {
        case .removeContainer: "Its file system is deleted. Volumes are kept."
        case .removeImage(_, _, let size): "It uses \(UserMessage.byteCount(size)). You can pull or build it again."
        case .removeVolume: "Data stored in this volume is deleted and can’t be recovered."
        case .removeNetwork: "No container uses it. Compose creates its own networks again on the next Compose Up."
        case .deletePod(let context, let namespace, _, let hasController):
            "Context “\(context)”, namespace “\(namespace)”. " + (hasController
                ? "Its controller will create a replacement."
                : "No controller manages it, so it won’t come back.")
        case .rolloutRestart(let context, let namespace, _):
            "Context “\(context)”, namespace “\(namespace)”. Pods are replaced one by one according to its rollout strategy."
        case .useKubectlDefault:
            "GoLens writes current-context in your kubeconfig, so kubectl in every terminal targets this context too."
        }
    }
}

struct ServicesPanelContent: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let providers: [any ServiceSectionProvider]

    private var query: String { window.listFilter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let blocking = blockingState {
            blocking
        } else {
            PanelListDetail {
                list
            } detail: {
                detail
            }
        }
    }

    private var blockingState: AnyView? {
        guard !providers.isEmpty else {
            return AnyView(UnifiedEmptyState.empty(
                symbol: ServiceSymbol.services,
                title: "No Services",
                message: "Services show the containers your project runs. Add a Dockerfile or compose.yaml to get started."
            ))
        }
        let states = providers.map(\.blockingState)
        guard states.allSatisfy({ $0 != nil }) else { return nil }
        return states.first ?? nil
    }

    private var list: some View {
        VStack(spacing: 0) {
            PanelFilterBar(
                placeholder: "Filter",
                text: $window.listFilter,
                accessibilityTitle: "Filter Services"
            )
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)
            Divider()
            if !query.isEmpty && !providers.contains(where: { $0.hasMatches(filter: query) }) {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Services") { window.listFilter = "" }
            } else {
                List(selection: selectionBinding) {
                    ForEach(providers, id: \.id) { provider in
                        provider.section(filter: query)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Services")
                .contextMenu(forSelectionType: ServiceSelection.self) { selections in
                    if let selection = selections.first, let provider = provider(for: selection) {
                        provider.contextMenu(for: selection)
                    }
                } primaryAction: { selections in
                    if let selection = selections.first { provider(for: selection)?.primaryAction(selection) }
                }
                .onDeleteCommand {
                    if let selection = window.selection { provider(for: selection)?.delete(selection) }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = window.selection, let provider = provider(for: selection) {
            provider.detail(for: selection)
        } else if let issue = KubernetesIssueState.visibleIssue(in: window) {
            KubernetesIssueState(workspace: workspace, window: window, issue: issue)
        } else if let blocking = providers.lazy.compactMap(\.blockingState).first {
            blocking
        } else {
            UnifiedEmptyState.empty(
                symbol: ServiceSymbol.container,
                title: "No Selection",
                message: ServicesStore.shared.kube.isAvailable ? "Select a container or pod to see its logs." : "Select a container to see its logs."
            )
        }
    }

    private var selectionBinding: Binding<ServiceSelection?> {
        Binding(
            get: { window.selection },
            set: { ServicesPanelContent.select($0, in: window) }
        )
    }

    private func provider(for selection: ServiceSelection) -> (any ServiceSectionProvider)? {
        providers.first { $0.id == selection.provider }
    }

    static func select(_ selection: ServiceSelection?, in window: ServicesWindowState) {
        guard window.selection != selection else { return }
        window.selection = selection
        window.kube.showsPrevious = false
        window.kube.forwardTarget = nil
        if let selection {
            if !selection.showsLogs { window.mode = .details }
            if !selection.showsDetails { window.mode = .logs }
        }
        let store = ServicesStore.shared
        store.syncStreams(window)
        store.loadDetailsIfNeeded(window)
    }
}

struct ServicesHeaderControls: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        let window = ServicesStore.shared.window(for: workspace)
        if let selection = window.selection,
           let provider = ServiceProviders.all(workspace: workspace, window: window).first(where: { $0.id == selection.provider && $0.isAvailable }) {
            HStack(spacing: Spacing.standard) {
                if selection.showsLogs && selection.showsDetails {
                    Picker("View", selection: Binding(
                        get: { window.mode },
                        set: { mode in
                            window.mode = mode
                            ServicesStore.shared.syncStreams(window)
                            ServicesStore.shared.loadDetailsIfNeeded(window)
                        }
                    )) {
                        ForEach(ServiceDetailMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Logs or Details")
                }
                provider.headerActions(for: selection)
            }
        }
    }
}
