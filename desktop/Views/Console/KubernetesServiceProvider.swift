import AppKit
import GoLensFoundation
import SwiftUI

struct KubernetesServiceProvider: ServiceSectionProvider {
    let workspace: WorkspaceState
    let window: ServicesWindowState
    var store: ServicesStore { ServicesStore.shared }

    var id: String { ServicesStore.kubernetesProvider }
    var isAvailable: Bool { store.kube.isAvailable }
    var blockingState: AnyView? { nil }

    func hasMatches(filter: String) -> Bool {
        KubernetesListModel(window: window, filter: filter).hasMatches
    }

    func section(filter: String) -> AnyView {
        AnyView(KubernetesServiceSection(workspace: workspace, window: window, filter: filter))
    }

    func detail(for selection: ServiceSelection) -> AnyView {
        AnyView(KubernetesServiceDetail(workspace: workspace, window: window, selection: selection))
    }

    func headerActions(for selection: ServiceSelection) -> AnyView {
        AnyView(KubernetesHeaderActions(workspace: workspace, window: window, selection: selection))
    }

    func contextMenu(for selection: ServiceSelection) -> AnyView {
        AnyView(KubernetesContextMenu(workspace: workspace, window: window, selection: selection))
    }

    func primaryAction(_ selection: ServiceSelection) {
        store.show(selection.kind == .pod ? .logs : .details, in: workspace)
    }

    func delete(_ selection: ServiceSelection) {
        guard selection.kind == .pod else { return }
        store.requestDeletePod(selection.id, in: window, from: workspace)
    }
}

struct KubernetesListModel {
    let window: ServicesWindowState
    let filter: String

    var kube: KubeStore { ServicesStore.shared.kube }

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
    }

    var pods: [KubePod] {
        let scope = window.kube.podScope
        return kube.pods.filter { pod in
            matches(pod.name) && (scope.map { KubeLabels.matches($0.selector, pod.labels) } ?? true)
        }
    }

    var deployments: [KubeDeployment] { kube.deployments.filter { matches($0.name) } }
    var services: [KubeServiceObject] { kube.services.filter { matches($0.name) } }

    var hasMatches: Bool {
        guard !filter.isEmpty else { return true }
        return !pods.isEmpty || !deployments.isEmpty || !services.isEmpty
    }

    static func podRow(_ pod: KubePod, window: ServicesWindowState, workspace: WorkspaceState) -> ServiceResourceRow {
        let store = ServicesStore.shared
        var actions: [ServiceRowAction] = []
        let shellReason = store.kubeShellUnavailableReason(pod)
        actions.append(ServiceRowAction(title: "Open Shell", symbol: ServiceSymbol.shell, help: shellReason ?? "Open a shell in “\(pod.name)”", isEnabled: shellReason == nil) {
            store.openKubeShell(pod, in: window, workspace: workspace)
        })
        if !pod.tcpPorts.isEmpty {
            let reason = store.forwardUnavailableReason(ports: pod.tcpPorts)
            actions.append(ServiceRowAction(title: "Port Forward…", symbol: ServiceSymbol.portForward, help: reason ?? "Forward a local port to “\(pod.name)”", isEnabled: reason == nil) {
                store.requestForward(store.podForwardTarget(pod), in: window, workspace: workspace)
            })
        }
        let busy = store.kube.pending.contains("pod:" + pod.name)
        return ServiceResourceRow(
            symbol: ServiceSymbol.pod,
            title: pod.name,
            detail: pod.detail(),
            status: busy ? .busy("Deleting…") : ServiceStatus(tone: pod.tone.statusTone, text: pod.status),
            actions: actions
        )
    }
}

extension KubeTone {
    var statusTone: StatusTone {
        switch self {
        case .ok: .success
        case .warning: .warning
        case .failure: .failure
        case .neutral: .inactive
        }
    }
}

struct KubernetesServiceSection: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let filter: String

    private var store: ServicesStore { ServicesStore.shared }
    private var kube: KubeStore { store.kube }

    private func expansion(_ group: String) -> Binding<Bool> {
        Binding(
            get: { window.isExpanded(group) },
            set: { on in
                window.setExpanded(group, on)
                if on && group == KubeStore.sectionGroup { store.markKubernetesUsed(in: workspace) }
                store.syncKubeWatch()
            }
        )
    }

    var body: some View {
        let model = KubernetesListModel(window: window, filter: filter)
        Section(isExpanded: expansion(KubeStore.sectionGroup)) {
            if let issue = kube.contextIssue {
                issueRow(issue, kind: nil)
            }
            pods(model)
            deployments(model)
            services(model)
        } header: {
            ServiceSectionHeader(symbol: ServiceSymbol.kubernetes, title: "Kubernetes", status: headerStatus, help: headerHelp) {
                KubeContextPicker()
                KubeNamespacePicker(window: window)
            } actions: {
                KubernetesProviderActions(workspace: workspace, window: window)
            }
        }
    }

    private var headerHelp: String {
        let server = kube.contextInfo?.server ?? ""
        return "Context “\(kube.context)”" + (server.isEmpty ? "" : " at \(server)") + " · Namespace “\(kube.namespace)”"
    }

    private var headerStatus: ServiceStatus {
        guard kube.hasWatch else { return ServiceStatus(tone: .inactive, text: "Not Connected") }
        if let issue = kube.contextIssue { return ServiceStatus(tone: .failure, text: issue.title) }
        let states = kube.kinds.values.map(\.state)
        if states.contains("connecting") || states.isEmpty { return .busy("Connecting…") }
        if states.contains("reconnecting") { return .busy("Reconnecting…") }
        let suffix = kube.isReadOnly ? " · Read-Only" : ""
        let limited = KubeKind.allCases.contains { kube.kindIssue($0) != nil }
        return ServiceStatus(tone: limited ? .warning : .success, text: kube.namespace + suffix)
    }

    private func issueRow(_ issue: KubeIssue, kind: KubeKind?) -> some View {
        var actions = [ServiceRowAction(title: "Retry", symbol: ServiceSymbol.refresh, help: "Retry") { store.retryKube() }]
        if let recovery = KubernetesIssueState.recovery(for: issue.error, window: window, workspace: workspace) {
            actions.insert(ServiceRowAction(title: recovery.title, symbol: recovery.symbol, help: recovery.title, perform: recovery.action), at: 0)
        }
        return ServiceResourceRow(
            symbol: ServiceSymbol.kubernetes,
            title: issue.title,
            detail: issue.message,
            status: ServiceStatus(tone: .failure, text: ""),
            actions: actions
        )
        .equatable()
    }

    @ViewBuilder
    private func loadingOrEmpty(_ kind: KubeKind, isEmpty: Bool) -> some View {
        let status = kube.status(kind)
        if let issue = kube.kindIssue(kind) {
            issueRow(issue, kind: kind)
        } else if isEmpty && (status == nil || status?.state == "connecting") && kube.contextIssue == nil {
            ServiceListNote(text: "Loading…", isLoading: true)
        } else if isEmpty && status?.state == "live" {
            ServiceListNote(text: filter.isEmpty && (kind != .pods || window.kube.podScope == nil)
                ? "No \(kind.title.lowercased()) in “\(kube.namespace)”."
                : "No matching \(kind.title.lowercased()).")
        }
        if let status, let note = KubeRows.capNote(shown: kind == .pods ? kube.pods.count : kind == .deployments ? kube.deployments.count : kube.services.count, total: status.total, truncated: status.truncated) {
            ServiceListNote(text: note, tone: .info)
        }
    }

    private func groupLabel(_ kind: KubeKind, symbol: String, count: Int) -> some View {
        ServiceResourceRow(
            symbol: symbol,
            title: kind.title,
            detail: kube.status(kind) == nil ? "" : UserMessage.integer(count),
            accessibilityTitle: kind == .services ? "Kubernetes Services" : nil
        )
        .equatable()
    }

    @ViewBuilder
    private func pods(_ model: KubernetesListModel) -> some View {
        let items = model.pods
        DisclosureGroup(isExpanded: expansion(ServicesStore.kubeGroup(.pods))) {
            if let scope = window.kube.podScope {
                HStack(spacing: Spacing.standard) {
                    ServiceListNote(text: "Pods of “\(scope.deployment)”")
                    Spacer(minLength: 0)
                    Button("Show All Pods") { window.kube.podScope = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            loadingOrEmpty(.pods, isEmpty: items.isEmpty)
            Group {
                ForEach(items) { pod in
                    let forwards = store.forwards(for: "pod/" + pod.name, in: workspace)
                    if forwards.isEmpty {
                        KubernetesListModel.podRow(pod, window: window, workspace: workspace).equatable()
                            .tag(ServiceSelection.kube(.pod, pod.name))
                    } else {
                        DisclosureGroup(isExpanded: forwardExpansion("pod/" + pod.name)) {
                            forwardRows(forwards)
                        } label: {
                            KubernetesListModel.podRow(pod, window: window, workspace: workspace).equatable()
                        }
                        .tag(ServiceSelection.kube(.pod, pod.name))
                    }
                }
            }
            .staleWhileScanning(kube.status(.pods)?.state == "relisting")
        } label: {
            groupLabel(.pods, symbol: ServiceSymbol.pod, count: items.count)
        }
    }

    @ViewBuilder
    private func deployments(_ model: KubernetesListModel) -> some View {
        let items = model.deployments
        DisclosureGroup(isExpanded: expansion(ServicesStore.kubeGroup(.deployments))) {
            loadingOrEmpty(.deployments, isEmpty: items.isEmpty)
            Group {
                ForEach(items) { deployment in
                    let busy = kube.pending.contains("deployment:" + deployment.name)
                    ServiceResourceRow(
                        symbol: ServiceSymbol.deployment,
                        title: deployment.name,
                        status: busy ? .busy("Restarting…") : ServiceStatus(tone: deployment.tone.statusTone, text: deployment.readyText),
                        actions: [ServiceRowAction(title: "Show Pods", symbol: ServiceSymbol.pod, help: "Show the pods of “\(deployment.name)”") {
                            store.showPods(of: deployment, in: window)
                        }]
                    )
                    .equatable()
                    .tag(ServiceSelection.kube(.deployment, deployment.name))
                }
            }
            .staleWhileScanning(kube.status(.deployments)?.state == "relisting")
        } label: {
            groupLabel(.deployments, symbol: ServiceSymbol.deployment, count: items.count)
        }
    }

    @ViewBuilder
    private func services(_ model: KubernetesListModel) -> some View {
        let items = model.services
        DisclosureGroup(isExpanded: expansion(ServicesStore.kubeGroup(.services))) {
            loadingOrEmpty(.services, isEmpty: items.isEmpty)
            Group {
                ForEach(items) { service in
                    let forwards = store.forwards(for: "svc/" + service.name, in: workspace)
                    if forwards.isEmpty {
                        serviceRow(service)
                            .tag(ServiceSelection.kube(.kubeService, service.name))
                    } else {
                        DisclosureGroup(isExpanded: forwardExpansion("svc/" + service.name)) {
                            forwardRows(forwards)
                        } label: {
                            serviceRow(service)
                        }
                        .tag(ServiceSelection.kube(.kubeService, service.name))
                    }
                }
            }
            .staleWhileScanning(kube.status(.services)?.state == "relisting")
        } label: {
            groupLabel(.services, symbol: ServiceSymbol.kubeService, count: items.count)
        }
    }

    private func serviceRow(_ service: KubeServiceObject) -> some View {
        var actions: [ServiceRowAction] = []
        if service.canForward {
            let reason = store.forwardUnavailableReason(ports: service.tcpPorts)
            actions.append(ServiceRowAction(title: "Port Forward…", symbol: ServiceSymbol.portForward, help: reason ?? "Forward a local port to “\(service.name)”", isEnabled: reason == nil) {
                store.requestForward(store.serviceForwardTarget(service), in: window, workspace: workspace)
            })
        }
        return ServiceResourceRow(
            symbol: ServiceSymbol.kubeService,
            title: service.name,
            detail: [service.type, service.portsText].filter { !$0.isEmpty }.joined(separator: " · "),
            actions: actions
        )
        .equatable()
    }

    private func forwardExpansion(_ target: String) -> Binding<Bool> {
        let key = "kube.forwards.collapsed." + target
        return Binding(
            get: { !window.isExpanded(key) },
            set: { window.setExpanded(key, !$0) }
        )
    }

    private func forwardRows(_ forwards: [KubeForward]) -> some View {
        ForEach(forwards) { forward in
            var actions: [ServiceRowAction] = []
            if forward.isRunning {
                actions.append(ServiceRowAction(title: "Stop", symbol: ServiceSymbol.stop, help: "Stop forwarding localhost:\(forward.local)") {
                    workspace.stopRunSession(forward.sessionID)
                })
                if let url = forward.url {
                    actions.append(ServiceRowAction(title: "Open in Browser", symbol: ServiceSymbol.openInBrowser, help: "Open \(url.absoluteString)") {
                        NSWorkspace.shared.open(url)
                    })
                }
            } else {
                actions.append(ServiceRowAction(title: "Close", symbol: "xmark", help: "Remove this ended forward. Its output stays in the Console until you close it there.") {
                    workspace.closeRunSession(forward.sessionID)
                })
            }
            return ServiceResourceRow(
                symbol: ServiceSymbol.portForward,
                title: forward.title,
                status: forward.isRunning ? ServiceStatus(tone: .success, text: "Forwarding") : ServiceStatus(tone: .inactive, text: "Ended"),
                actions: actions
            )
            .equatable()
        }
    }
}

struct KubeContextPicker: View {
    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        if let list = kube.contexts, !list.contexts.isEmpty {
            let server = kube.contextInfo?.server ?? ""
            ServiceSelectionMenu(
                symbol: ServiceSymbol.context,
                title: "Kubernetes Context",
                value: kube.context,
                help: "Kubernetes Context: \(kube.context)" + (server.isEmpty ? "" : " (\(server))") + ". Choosing one here leaves your kubeconfig as it is."
            ) {
                KubeContextMenuItems()
            }
        }
    }
}

struct KubeContextMenuItems: View {
    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        if let list = kube.contexts {
            Picker("Kubernetes Context", selection: Binding(get: { kube.context }, set: { store.selectKubeContext($0) })) {
                ForEach(list.contexts) { context in
                    Text(context.current ? "\(context.name) (kubectl default)" : context.name)
                        .tag(context.name)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

struct KubeNamespacePicker: View {
    let window: ServicesWindowState

    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        ServiceSelectionMenu(
            symbol: ServiceSymbol.namespace,
            title: "Namespace",
            value: kube.namespace,
            help: "Namespace: \(kube.namespace)"
        ) {
            KubeNamespaceMenuItems(window: window)
        }
    }
}

struct KubeNamespaceMenuItems: View {
    let window: ServicesWindowState

    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        let list = kube.namespaces
        let names = namespaceNames(list, current: kube.namespace)
        Picker("Namespace", selection: Binding(get: { kube.namespace }, set: { store.selectKubeNamespace($0) })) {
            ForEach(names, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.inline)
        .onAppear { store.loadKubeNamespaces() }
        if kube.isLoadingNamespaces && list == nil {
            Text("Loading Namespaces…")
        } else if let error = list?.error {
            Text(error.isForbidden ? "Your account can’t list namespaces." : error.message)
        }
        Divider()
        Button("Other Namespace…") {
            window.kube.namespaceDraft = kube.namespace
            window.kube.namespacePrompt = true
        }
    }

    private func namespaceNames(_ list: KubeNamespaceList?, current: String) -> [String] {
        var names: [String] = []
        if let list {
            names.append(list.defaultNamespace)
            names += list.namespaces.map(\.name)
        }
        names.append(current)
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct KubernetesProviderActions: View {
    @Bindable var workspace: WorkspaceState
    let window: ServicesWindowState

    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        Button("Refresh", systemImage: ServiceSymbol.refresh) { store.retryKube() }
        Divider()
        Toggle("Read-Only for This Context", isOn: Binding(get: { kube.isReadOnly }, set: { _ in store.toggleReadOnly() }))
        Button("Use as kubectl Default…", systemImage: ServiceSymbol.kubectlDefault) {
            store.requestUseAsKubectlDefault(in: window, from: workspace)
        }
        .disabled(kube.contexts?.current == kube.context || kube.settingDefault)
        Divider()
        Button("Apply to Cluster…", systemImage: ServiceSymbol.apply) { store.presentApply(in: workspace) }
            .disabled(!workspace.commandCapabilities.current.isKubernetesManifest)
    }
}

struct KubernetesContextMenu: View {
    @Bindable var workspace: WorkspaceState
    let window: ServicesWindowState
    let selection: ServiceSelection

    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        switch selection.kind {
        case .pod:
            if let pod = kube.pod(selection.id) {
                Button("Show Logs", systemImage: ServiceSymbol.logs) {
                    select()
                    store.showPreviousLogs(false, in: window)
                    workspace.showServicesPanel()
                }
                if pod.restarts > 0 {
                    Button("Show Previous Logs", systemImage: ServiceSymbol.logs) {
                        select()
                        store.showPreviousLogs(true, in: window)
                        workspace.showServicesPanel()
                    }
                }
                Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
                Button("Open Shell", systemImage: ServiceSymbol.shell) { store.openKubeShell(pod, in: window, workspace: workspace) }
                    .disabled(store.kubeShellUnavailableReason(pod) != nil)
                if !pod.tcpPorts.isEmpty {
                    Button("Port Forward…", systemImage: ServiceSymbol.portForward) {
                        store.requestForward(store.podForwardTarget(pod), in: window, workspace: workspace)
                    }
                    .disabled(store.forwardUnavailableReason(ports: pod.tcpPorts) != nil)
                }
                Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(pod.name) }
                Divider()
                Button("Delete Pod…", systemImage: ServiceSymbol.remove, role: .destructive) {
                    store.requestDeletePod(pod.name, in: window, from: workspace)
                }
                .disabled(kube.isReadOnly)
            }
        case .deployment:
            if let deployment = kube.deployment(selection.id) {
                Button("Show Pods", systemImage: ServiceSymbol.pod) { store.showPods(of: deployment, in: window) }
                Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
                Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(deployment.name) }
                Divider()
                Button("Rollout Restart…", systemImage: ServiceSymbol.restart) {
                    store.requestRolloutRestart(deployment.name, in: window, from: workspace)
                }
                .disabled(kube.isReadOnly)
            }
        case .kubeService:
            if let service = kube.service(selection.id) {
                if service.canForward {
                    Button("Port Forward…", systemImage: ServiceSymbol.portForward) {
                        store.requestForward(store.serviceForwardTarget(service), in: window, workspace: workspace)
                    }
                    .disabled(store.forwardUnavailableReason(ports: service.tcpPorts) != nil)
                }
                Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
                Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(service.name) }
            }
        default:
            EmptyView()
        }
    }

    private func select() {
        ServicesPanelContent.select(selection, in: window)
    }
}

struct KubernetesHeaderActions: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let selection: ServiceSelection

    var body: some View {
        let store = ServicesStore.shared
        let kube = store.kube
        HStack(spacing: Spacing.standard) {
            switch selection.kind {
            case .pod:
                if let pod = kube.pod(selection.id) {
                    podActions(pod, store: store)
                }
            case .deployment:
                if let deployment = kube.deployment(selection.id) {
                    ServiceHeaderButton(
                        title: "Rollout Restart…",
                        symbol: ServiceSymbol.restart,
                        help: store.kubeActionBlocker(mutating: true) ?? "Restart “\(deployment.name)” in “\(kube.namespace)”"
                    ) {
                        store.requestRolloutRestart(deployment.name, in: window, from: workspace)
                    }
                    .disabled(kube.isReadOnly)
                    ServiceMoreMenu {
                        Button("Show Pods", systemImage: ServiceSymbol.pod) { store.showPods(of: deployment, in: window) }
                        Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(deployment.name) }
                    }
                }
            case .kubeService:
                if let service = kube.service(selection.id) {
                    if service.canForward {
                        forwardButton(store.serviceForwardTarget(service), store: store)
                    }
                    ServiceMoreMenu {
                        Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(service.name) }
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func podActions(_ pod: KubePod, store: ServicesStore) -> some View {
        if pod.containers.count > 1 && window.mode == .logs {
            Picker("Container", selection: Binding(
                get: { store.kubeContainer(for: pod, in: window) },
                set: { store.chooseContainer($0, for: pod.name, in: window) }
            )) {
                ForEach(pod.containers, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Container whose logs are shown")
            .accessibilityLabel("Container")
        }
        let shellReason = store.kubeShellUnavailableReason(pod)
        ServiceHeaderButton(title: "Open Shell", symbol: ServiceSymbol.shell, help: shellReason ?? "Open a shell in “\(pod.name)”") {
            store.openKubeShell(pod, in: window, workspace: workspace)
        }
        .disabled(shellReason != nil)
        if !pod.tcpPorts.isEmpty {
            forwardButton(store.podForwardTarget(pod), store: store)
        }
        ServiceMoreMenu {
            if pod.restarts > 0 {
                if window.kube.showsPrevious {
                    Button("Show Current Logs", systemImage: ServiceSymbol.logs) { store.showPreviousLogs(false, in: window) }
                } else {
                    Button("Show Previous Logs", systemImage: ServiceSymbol.logs) { store.showPreviousLogs(true, in: window) }
                }
            }
            Button("Copy Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(pod.name) }
            Divider()
            Button("Delete Pod…", systemImage: ServiceSymbol.remove, role: .destructive) {
                store.requestDeletePod(pod.name, in: window, from: workspace)
            }
            .disabled(store.kube.isReadOnly)
        }
    }

    private func forwardButton(_ target: KubeForwardTarget, store: ServicesStore) -> some View {
        let reason = store.forwardUnavailableReason(ports: target.ports)
        let presented = window.kube.forwardTarget?.id == target.id
        return ServiceHeaderButton(title: "Port Forward…", symbol: ServiceSymbol.portForward, help: reason ?? "Forward a local port to \(target.resource)") {
            window.kube.forwardTarget = target
        }
        .disabled(reason != nil)
        .popover(isPresented: Binding(
            get: { presented },
            set: { if !$0 { window.kube.forwardTarget = nil } }
        ), arrowEdge: .bottom) {
            KubernetesPortForwardPopover(workspace: workspace, target: target) {
                window.kube.forwardTarget = nil
            }
        }
    }
}

struct KubernetesPortForwardPopover: View {
    let workspace: WorkspaceState
    let target: KubeForwardTarget
    let dismiss: () -> Void

    @State private var remote = 0
    @State private var localText = ""
    @State private var suggestionNote: String?
    @FocusState private var fieldFocused: Bool

    private var store: ServicesStore { ServicesStore.shared }

    private var local: Int? {
        guard let value = Int(localText.trimmingCharacters(in: .whitespaces)), value > 0, value < 65536 else { return nil }
        return value
    }

    private var problem: String? {
        guard let local else { return "Enter a port from 1 to 65535." }
        if !LocalPortProbe.isFree(local) { return "Port \(UserMessage.rawIdentifier(local)) is in use on this Mac. Choose another one." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Port Forward")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(target.resource) in “\(store.kube.namespace)” · Context “\(store.kube.context)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                if target.ports.count > 1 {
                    Picker("Remote Port", selection: $remote) {
                        ForEach(target.ports, id: \.self) { port in
                            Text(UserMessage.rawIdentifier(port)).tag(port)
                        }
                    }
                } else {
                    LabeledContent("Remote Port", value: UserMessage.rawIdentifier(remote))
                }
                TextField("Local Port", text: $localText)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(forward)
            }
            .font(.subheadline)
            if let note = problem ?? suggestionNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Forward", action: forward)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .controlSize(.small)
        }
        .padding(Spacing.section)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            remote = target.ports.first ?? 0
            suggest()
            fieldFocused = true
        }
        .onChange(of: remote) { _, _ in suggest() }
    }

    private func suggest() {
        let wanted = remote
        let chosen = LocalPortProbe.isFree(wanted) && wanted >= 1024 ? wanted : LocalPortProbe.suggest(from: wanted)
        localText = UserMessage.rawIdentifier(chosen)
        if chosen == wanted {
            suggestionNote = nil
        } else if wanted < 1024 {
            suggestionNote = "Ports below 1024 need administrator rights on this Mac, so GoLens picked \(UserMessage.rawIdentifier(chosen))."
        } else {
            suggestionNote = "Port \(UserMessage.rawIdentifier(wanted)) is in use on this Mac, so GoLens picked \(UserMessage.rawIdentifier(chosen))."
        }
    }

    private func forward() {
        guard problem == nil, let local else { return }
        store.startForward(target, local: local, remote: remote, workspace: workspace)
        dismiss()
    }
}

struct KubernetesIssueState: View {
    @Bindable var workspace: WorkspaceState
    let window: ServicesWindowState
    let issue: KubeIssue

    struct Recovery {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    static func visibleIssue(in window: ServicesWindowState) -> KubeIssue? {
        let kube = ServicesStore.shared.kube
        guard kube.isAvailable, window.isExpanded(KubeStore.sectionGroup) else { return nil }
        if let issue = kube.contextIssue { return issue }
        return KubeKind.allCases.lazy.compactMap { window.isExpanded(ServicesStore.kubeGroup($0)) ? kube.kindIssue($0) : nil }.first
    }

    static func recovery(for error: KubeError, window: ServicesWindowState, workspace: WorkspaceState) -> Recovery? {
        let kube = ServicesStore.shared.kube
        switch error.kind {
        case "forbidden", "notFound":
            return Recovery(title: "Choose Namespace…", symbol: ServiceSymbol.namespace) {
                window.kube.namespaceDraft = kube.namespaces?.defaultNamespace ?? kube.namespace
                window.kube.namespacePrompt = true
            }
        case "needsSignIn", "credentialPluginFailed":
            return Recovery(title: "Open Terminal", symbol: ServiceSymbol.shell) {
                if error.signInCommand.isEmpty {
                    workspace.openTerminal(atDirectory: workspace.activeWorkspacePath)
                } else {
                    workspace.openCommandTerminal(title: "Sign In (\(kube.context))", argv: error.signInCommand)
                }
            }
        default:
            return nil
        }
    }

    var body: some View {
        let recovery = Self.recovery(for: issue.error, window: window, workspace: workspace)
        let server = issue.error.server
        let message = issue.error.kind == "unreachable" && !server.isEmpty && !issue.message.contains(server)
            ? issue.message + " Server: " + server
            : issue.message
        UnifiedEmptyState.failed(
            title: issue.title,
            message: message,
            recoveryTitle: recovery?.title,
            recovery: recovery?.action,
            onRetry: { ServicesStore.shared.retryKube() }
        )
    }
}

struct KubernetesServiceDetail: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let selection: ServiceSelection

    private var store: ServicesStore { ServicesStore.shared }
    private var kube: KubeStore { store.kube }

    var body: some View {
        switch selection.kind {
        case .pod:
            if let pod = kube.pod(selection.id) {
                if window.mode == .logs {
                    logs(pod)
                } else {
                    details
                }
            } else {
                gone("This pod no longer exists in “\(kube.namespace)”.")
            }
        case .deployment:
            if kube.deployment(selection.id) != nil { details } else { gone("This deployment no longer exists in “\(kube.namespace)”.") }
        case .kubeService:
            if kube.service(selection.id) != nil { details } else { gone("This service no longer exists in “\(kube.namespace)”.") }
        default:
            EmptyView()
        }
    }

    private func gone(_ message: String) -> some View {
        UnifiedEmptyState.empty(symbol: ServiceSymbol.kubernetes, title: "No Selection", message: message)
    }

    @ViewBuilder
    private var details: some View {
        let state = window.kube
        if let details = state.details, details.name == selection.id {
            ServiceDetailsView(groups: KubeDetailGroups.groups(details))
                .id(details.kind + "/" + details.name)
        } else if let error = state.detailsError {
            UnifiedEmptyState.failed(title: "Couldn’t Read the Details", message: error.message) {
                store.loadKubeDetailsIfNeeded(window, force: true)
            }
        } else {
            UnifiedEmptyState.loading(message: "Reading details…")
        }
    }

    private func logs(_ pod: KubePod) -> some View {
        let container = store.kubeContainer(for: pod, in: window)
        let containerName = container.isEmpty ? (pod.containers.first ?? pod.name) : container
        return ServiceLogsView(
            window: window,
            emptyMessage: window.kube.showsPrevious ? "The previous container printed nothing." : "The pod hasn’t printed anything.",
            onRetry: { store.reopenKubeLogs(window) }
        ) {
            if window.kube.showsPrevious {
                InlineBanner(
                    .symbol(ServiceSymbol.logs),
                    title: "Previous Container",
                    message: "Logs of “\(containerName)” before its last restart. The pod has restarted \(UserMessage.count(pod.restarts, "time"))."
                ) {
                    Button("Show Current Logs") { store.showPreviousLogs(false, in: window) }
                }
            } else if pod.tone == .failure && pod.restarts > 0 {
                InlineBanner(
                    .status(.failure),
                    title: "“\(pod.name)” Is Failing",
                    message: "\(pod.status) after \(UserMessage.count(pod.restarts, "restart")). The previous container’s logs often show why."
                ) {
                    Button("Show Previous Logs") { store.showPreviousLogs(true, in: window) }
                }
            }
        }
    }
}

enum KubeDetailGroups {
    static func groups(_ d: KubeDetails) -> [ServiceDetailGroup] {
        var overview = [
            ServiceDetailRow(label: "Name", value: d.name, copyTitle: "Copy Name"),
            ServiceDetailRow(label: "Namespace", value: d.namespace),
            ServiceDetailRow(label: "Context", value: d.context),
        ]
        overview += d.overview.filter { !$0.value.isEmpty }.map { item in
            ServiceDetailRow(label: item.label, value: item.value, isMonospaced: ["Pod IP", "Cluster IP", "Selector", "Node"].contains(item.label))
        }
        let created = DockerDetailGroups.date(d.created)
        if !created.isEmpty { overview.append(ServiceDetailRow(label: "Created", value: created)) }
        var groups = [ServiceDetailGroup(title: "Overview", rows: overview)]
        for container in d.containers {
            groups.append(ServiceDetailGroup(title: "Container “\(container.name)”", rows: containerRows(container)))
        }
        if d.kind != "services" {
            groups.append(ServiceDetailGroup(title: "Conditions", rows: d.conditions.map(conditionRow), emptyText: "No conditions."))
        }
        groups.append(ServiceDetailGroup(
            title: "Events",
            rows: d.events.map(eventRow),
            emptyText: d.eventsError?.message ?? "No recent events."
        ))
        let labels = d.labels.sorted { $0.key < $1.key }.map { ServiceDetailRow(label: $0.key, value: $0.value, isMonospaced: true) }
        groups.append(ServiceDetailGroup(title: "Labels", rows: labels, emptyText: "No labels.", startsCollapsed: true))
        return groups
    }

    private static func containerRows(_ c: KubeContainerDetail) -> [ServiceDetailRow] {
        var rows = [ServiceDetailRow(label: "Image", value: c.image, isMonospaced: true, copyTitle: "Copy Image Name")]
        if c.state != "template" {
            var state = c.state.capitalized
            if !c.reason.isEmpty { state += " (\(c.reason))" }
            let tone: StatusTone? = c.state == "waiting" && !c.reason.isEmpty && c.reason != "ContainerCreating" ? .failure : nil
            rows.append(ServiceDetailRow(label: "State", value: state, tone: tone))
            rows.append(ServiceDetailRow(label: "Ready", value: c.ready ? "Yes" : "No"))
            rows.append(ServiceDetailRow(label: "Restarts", value: UserMessage.integer(c.restarts)))
        }
        if let last = c.lastTermination {
            var text = "\(last.reason.isEmpty ? "Terminated" : last.reason), exit code \(UserMessage.rawIdentifier(last.exitCode))"
            let finished = DockerDetailGroups.date(last.finishedAt)
            if !finished.isEmpty { text += ", " + finished }
            rows.append(ServiceDetailRow(label: "Last Termination", value: text, tone: last.exitCode == 0 ? nil : .failure))
        }
        let requests = KubeContainerDetail.resources(c.requests)
        let limits = KubeContainerDetail.resources(c.limits)
        rows.append(ServiceDetailRow(label: "Requests", value: requests.isEmpty ? "None" : requests))
        rows.append(ServiceDetailRow(label: "Limits", value: limits.isEmpty ? "None" : limits))
        if !c.ports.isEmpty {
            let ports = c.ports.map { ($0.name.isEmpty ? "" : $0.name + " ") + UserMessage.rawIdentifier($0.port) + ($0.isTCP ? "" : "/" + $0.proto) }
            rows.append(ServiceDetailRow(label: "Ports", value: ports.joined(separator: ", "), isMonospaced: true))
        }
        return rows
    }

    private static func conditionRow(_ c: KubeCondition) -> ServiceDetailRow {
        var value = c.status
        let extra = [c.reason, c.message].filter { !$0.isEmpty }.joined(separator: ": ")
        if !extra.isEmpty { value += " · " + extra }
        return ServiceDetailRow(label: c.type, value: value)
    }

    private static func eventRow(_ e: KubeEvent) -> ServiceDetailRow {
        var suffix: [String] = []
        if e.count > 1 { suffix.append("\(UserMessage.integer(e.count)) times") }
        let seen = DockerDetailGroups.date(e.lastSeen)
        if !seen.isEmpty { suffix.append(seen) }
        if !e.source.isEmpty { suffix.append(e.source) }
        let value = e.message + (suffix.isEmpty ? "" : " (" + suffix.joined(separator: ", ") + ")")
        return ServiceDetailRow(label: e.reason, value: value, tone: e.isWarning ? .warning : nil)
    }
}
