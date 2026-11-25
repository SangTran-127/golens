import AppKit
import GoLensFoundation
import SwiftUI

struct DockerServiceProvider: ServiceSectionProvider {
    let workspace: WorkspaceState
    let window: ServicesWindowState
    var store: ServicesStore { ServicesStore.shared }

    var id: String { ServicesStore.dockerProvider }
    var isAvailable: Bool { true }

    var blockingState: AnyView? {
        let status = DockerState.shared.status
        switch store.phase {
        case .unavailable(let reason, let message):
            if status?.state == "missingCLI" && reason == "down" {
                return AnyView(UnifiedEmptyState.empty(
                    symbol: ServiceSymbol.container,
                    title: "No Container Engine",
                    message: "GoLens didn’t find Docker on this Mac. Install OrbStack, Docker Desktop or Colima, then refresh.",
                    actionTitle: "Refresh",
                    action: { store.reconnect() }
                ))
            }
            if let issue = store.engine.issue, !issue.title.isEmpty {
                return AnyView(withContextPicker(engineIssue(issue)))
            }
            return AnyView(withContextPicker(engineFailure(reason: reason, message: message, status: status)))
        case .connecting where store.containers.isEmpty, .idle where store.containers.isEmpty:
            let target = store.switchingContext ?? store.contexts?.current ?? ""
            return AnyView(withContextPicker(UnifiedEmptyState.loading(message: target.isEmpty ? "Connecting to Docker…" : "Connecting to “\(target)”…")))
        default:
            return nil
        }
    }

    private func withContextPicker<Content: View>(_ content: Content) -> some View {
        VStack(spacing: 0) {
            if (store.contexts?.contexts.count ?? 0) > 1 {
                HStack(spacing: Spacing.standard) {
                    Spacer(minLength: 0)
                    DockerContextPicker(workspace: workspace, showsName: true)
                }
                .padding(.horizontal, Spacing.comfortable)
                .padding(.top, Spacing.standard)
            }
            content
        }
    }

    private func engineIssue(_ issue: RemoteIssue) -> some View {
        let opensTerminal = issue.fix == "openTerminal" && !issue.command.isEmpty
        return UnifiedEmptyState.failed(
            title: issue.title,
            message: issue.message,
            recoveryTitle: opensTerminal ? (issue.fixTitle.isEmpty ? "Connect in Terminal" : issue.fixTitle) : nil,
            recovery: opensTerminal ? { workspace.openTerminal(running: issue.command) } : nil,
            onRetry: { store.reconnect() }
        )
    }

    private func engineFailure(reason: String, message: String, status: DockerEngineInfo?) -> some View {
        let provider = status?.provider.isEmpty == false ? status!.provider : store.engine.provider
        let canOpen = status?.providerApp.isEmpty == false
        let title: String
        let text: String
        switch reason {
        case "permission":
            title = "Can’t Access Docker"
            text = "\(message) Check the socket settings of \(provider.isEmpty ? "your Docker provider" : provider), then retry."
        case "timeout":
            title = "Docker Engine Isn’t Responding"
            text = message.isEmpty ? "The engine didn’t answer in time. Check that it isn’t busy, then retry." : message
        case "tooOld", "unsupported":
            title = "Docker Engine Isn’t Supported"
            text = message
        default:
            title = "Docker Engine Isn’t Running"
            if let status, status.state == "engineDown" {
                text = status.explanation
            } else if !provider.isEmpty {
                text = "\(provider) isn’t running. Start \(provider), then retry."
            } else {
                text = message.isEmpty ? "Start your Docker engine, then retry." : message
            }
        }
        return UnifiedEmptyState.failed(
            title: title,
            message: text,
            recoveryTitle: canOpen ? "Open \(provider.isEmpty ? "Docker" : provider)" : nil,
            recovery: canOpen ? {
                workspace.openDockerProvider()
                store.reconnect()
            } : nil,
            onRetry: { store.reconnect() }
        )
    }

    func hasMatches(filter: String) -> Bool {
        DockerListModel(workspace: workspace, window: window, filter: filter).hasMatches
    }

    func section(filter: String) -> AnyView {
        AnyView(DockerServiceSection(workspace: workspace, window: window, filter: filter))
    }

    func detail(for selection: ServiceSelection) -> AnyView {
        AnyView(DockerServiceDetail(workspace: workspace, window: window, selection: selection))
    }

    func headerActions(for selection: ServiceSelection) -> AnyView {
        AnyView(DockerHeaderActions(workspace: workspace, window: window, selection: selection))
    }

    func contextMenu(for selection: ServiceSelection) -> AnyView {
        AnyView(DockerContextMenu(workspace: workspace, window: window, selection: selection))
    }

    func primaryAction(_ selection: ServiceSelection) {
        switch selection.kind {
        case .container:
            ServicesStore.shared.show(.logs, in: workspace)
        case .project:
            let group = DockerListModel.projectGroup(selection.id)
            window.setExpanded(group, !window.isExpanded(group))
        case .image, .volume, .network:
            ServicesStore.shared.show(.details, in: workspace)
        case .pod, .deployment, .kubeService:
            break
        }
    }

    func delete(_ selection: ServiceSelection) {
        store.requestRemove(selection, in: window, from: workspace)
    }
}

struct DockerListModel {
    let workspace: WorkspaceState
    let window: ServicesWindowState
    let filter: String

    var store: ServicesStore { ServicesStore.shared }
    var root: String { workspace.activeWorkspacePath }
    var composeFile: String? { store.composeFile(for: workspace) }

    static func projectGroup(_ name: String) -> String { "docker.project." + name }

    private func matches(_ container: DockerContainer) -> Bool {
        guard !filter.isEmpty else { return true }
        return [container.name, container.service, container.image, container.project].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    var thisProject: [DockerContainer] {
        let compose = composeFile
        return store.containers.filter { ServicesStore.isThisProject($0, root: root, composeFile: compose) && matches($0) }
    }

    var thisProjectName: String? {
        store.thisProjectName(root: root, composeFile: composeFile)
    }

    var otherContainers: [DockerContainer] {
        let compose = composeFile
        return store.containers.filter {
            !ServicesStore.isThisProject($0, root: root, composeFile: compose) && (store.showStopped || $0.isRunning) && matches($0)
        }
    }

    var hiddenStoppedCount: Int {
        guard !store.showStopped else { return 0 }
        let compose = composeFile
        return store.containers.filter { !ServicesStore.isThisProject($0, root: root, composeFile: compose) && !$0.isRunning }.count
    }

    var images: [DockerImage] {
        (store.images ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.tags.contains { $0.localizedCaseInsensitiveContains(filter) } }
    }

    var volumes: [DockerVolume] {
        (store.volumes ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var networks: [DockerNetworkSummary] {
        (store.networks ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.driver.localizedCaseInsensitiveContains(filter) }
    }

    var hasMatches: Bool {
        guard !filter.isEmpty else { return true }
        return !thisProject.isEmpty || !otherContainers.isEmpty || !images.isEmpty || !volumes.isEmpty || !networks.isEmpty
    }

    static func row(_ container: DockerContainer, workspace: WorkspaceState, title: String? = nil) -> ServiceResourceRow {
        let store = ServicesStore.shared
        let busy = store.pendingActions.contains(container.id)
        var actions: [ServiceRowAction] = []
        if container.isRunning {
            actions.append(ServiceRowAction(title: "Stop", symbol: ServiceSymbol.stop, help: "Stop “\(container.name)”") {
                store.perform("stop", on: container, from: workspace)
            })
        } else {
            actions.append(ServiceRowAction(title: "Start", symbol: ServiceSymbol.start, help: "Start “\(container.name)”") {
                store.perform("start", on: container, from: workspace)
            })
        }
        let shellReason = store.shellUnavailableReason(container)
        actions.append(ServiceRowAction(title: "Open Shell", symbol: ServiceSymbol.shell, help: shellReason ?? KeymapStore.shared.labeled("Open Shell", "services.openShell"), isEnabled: shellReason == nil) {
            store.openShell(container, in: workspace)
        })
        return ServiceResourceRow(
            symbol: ServiceSymbol.container,
            title: title ?? container.rowTitle,
            detail: container.detailText,
            status: busy ? .busy(container.statusText) : ServiceStatus(tone: container.statusTone, text: container.statusText),
            actions: actions
        )
    }

    static func projectSummary(_ containers: [DockerContainer]) -> ServiceStatus {
        let running = containers.filter(\.isRunning).count
        let tone: StatusTone = running == 0 ? .inactive : running == containers.count ? .success : .warning
        return ServiceStatus(tone: tone, text: "\(UserMessage.integer(running)) of \(UserMessage.integer(containers.count)) Running")
    }
}

struct DockerServiceSection: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let filter: String

    private var store: ServicesStore { ServicesStore.shared }

    private func expansion(_ group: String) -> Binding<Bool> {
        Binding(
            get: { !filter.isEmpty || window.isExpanded(group) },
            set: { on in
                guard filter.isEmpty else { return }
                window.setExpanded(group, on)
                if on && [ServicesWindowState.imagesGroup, ServicesWindowState.volumesGroup, ServicesWindowState.networksGroup].contains(group) {
                    store.reloadExpandedLists(window)
                }
            }
        )
    }

    var body: some View {
        let model = DockerListModel(workspace: workspace, window: window, filter: filter)
        Section(isExpanded: expansion(ServicesStore.dockerProvider)) {
            Group {
                thisProject(model)
                containers(model)
                images(model)
                volumes(model)
                networks(model)
            }
            .staleWhileScanning(store.phase != .running)
        } header: {
            ServiceSectionHeader(symbol: ServiceSymbol.container, title: "Docker", status: headerStatus, help: store.engine.endpoint) {
                DockerContextPicker(workspace: workspace)
            } actions: {
                DockerProviderActions(workspace: workspace)
            }
        }
    }

    private var headerStatus: ServiceStatus {
        let name = (store.contexts?.contexts.count ?? 0) > 1 ? "" : store.engine.provider
        switch store.phase {
        case .running:
            return ServiceStatus(tone: .success, text: name.isEmpty ? "Running" : "\(name) · Running")
        case .reconnecting:
            return .busy("Reconnecting…")
        case .connecting, .idle:
            return .busy("Connecting…")
        case .unavailable:
            return ServiceStatus(tone: .failure, text: "Not Running")
        }
    }

    @ViewBuilder
    private func thisProject(_ model: DockerListModel) -> some View {
        let members = model.thisProject
        let name = model.thisProjectName
        let compose = model.composeFile
        if !members.isEmpty || (compose != nil && filter.isEmpty) {
            DisclosureGroup(isExpanded: expansion(ServicesWindowState.thisProjectGroup)) {
                if members.isEmpty, let compose {
                    ServiceResourceRow(
                        symbol: ServiceSymbol.project,
                        title: (compose as NSString).lastPathComponent,
                        status: ServiceStatus(tone: .inactive, text: "Not Running"),
                        actions: [ServiceRowAction(title: "Compose Up", symbol: ServiceSymbol.start, help: "Start the services in \((compose as NSString).lastPathComponent)") {
                            workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "up")
                        }]
                    )
                    .equatable()
                } else {
                    ForEach(members) { container in
                        DockerListModel.row(container, workspace: workspace).equatable()
                            .tag(ServiceSelection.docker(.container, container.id))
                    }
                }
            } label: {
                ServiceResourceRow(
                    symbol: ServiceSymbol.project,
                    title: "This Project",
                    detail: name ?? "",
                    status: members.isEmpty ? nil : DockerListModel.projectSummary(members)
                )
                .equatable()
            }
            .serviceTag(name.map { ServiceSelection.docker(.project, $0) })
        }
    }

    @ViewBuilder
    private func containers(_ model: DockerListModel) -> some View {
        let others = model.otherContainers
        let projects = Dictionary(grouping: others.filter { !$0.project.isEmpty }, by: \.project)
        let plain = others.filter { $0.project.isEmpty }
        if filter.isEmpty || !others.isEmpty {
            DisclosureGroup(isExpanded: expansion(ServicesWindowState.containersGroup)) {
                ForEach(projects.keys.sorted(), id: \.self) { project in
                    let members = projects[project] ?? []
                    DisclosureGroup(isExpanded: expansion(DockerListModel.projectGroup(project))) {
                        ForEach(members) { container in
                            DockerListModel.row(container, workspace: workspace).equatable()
                                .tag(ServiceSelection.docker(.container, container.id))
                        }
                    } label: {
                        ServiceResourceRow(symbol: ServiceSymbol.project, title: project, status: DockerListModel.projectSummary(members))
                            .equatable()
                    }
                    .tag(ServiceSelection.docker(.project, project))
                }
                ForEach(plain) { container in
                    DockerListModel.row(container, workspace: workspace, title: container.name).equatable()
                        .tag(ServiceSelection.docker(.container, container.id))
                }
                if others.isEmpty && store.phase == .running {
                    placeholder(model.hiddenStoppedCount > 0
                        ? "No other running containers. \(UserMessage.count(model.hiddenStoppedCount, "stopped container")) hidden."
                        : "No other containers.")
                }
            } label: {
                ServiceResourceRow(
                    symbol: ServiceSymbol.container,
                    title: "Containers",
                    detail: UserMessage.integer(others.count)
                )
                .equatable()
            }
        }
    }

    @ViewBuilder
    private func images(_ model: DockerListModel) -> some View {
        let items = model.images
        if filter.isEmpty || !items.isEmpty {
            DisclosureGroup(isExpanded: expansion(ServicesWindowState.imagesGroup)) {
                if store.images == nil {
                    loadingOrError(store.imagesError)
                } else {
                    if let error = store.imagesError { errorRow(error) }
                    ForEach(items.filter { !$0.dangling }) { image in
                        imageRow(image)
                    }
                    let untagged = items.filter(\.dangling)
                    if !untagged.isEmpty {
                        DisclosureGroup(isExpanded: expansion("docker.images.untagged")) {
                            ForEach(untagged) { image in imageRow(image) }
                        } label: {
                            ServiceResourceRow(symbol: ServiceSymbol.image, title: "Untagged", detail: UserMessage.integer(untagged.count))
                                .equatable()
                        }
                    }
                    if items.isEmpty { placeholder("No images.") }
                }
            } label: {
                ServiceResourceRow(symbol: ServiceSymbol.image, title: "Images", detail: store.images.map { _ in UserMessage.integer(items.count) } ?? "")
                    .equatable()
            }
        }
    }

    private func imageRow(_ image: DockerImage) -> some View {
        let busy = store.pendingActions.contains(image.id)
        return ServiceResourceRow(
            symbol: ServiceSymbol.image,
            title: image.name,
            detail: UserMessage.byteCount(image.size),
            status: busy ? .busy("Removing…") : image.inUse ? ServiceStatus(tone: .success, text: "In Use") : nil
        )
        .equatable()
        .tag(ServiceSelection.docker(.image, image.id))
    }

    @ViewBuilder
    private func volumes(_ model: DockerListModel) -> some View {
        let items = model.volumes
        if filter.isEmpty || !items.isEmpty {
            DisclosureGroup(isExpanded: expansion(ServicesWindowState.volumesGroup)) {
                if store.volumes == nil {
                    loadingOrError(store.volumesError)
                } else {
                    if let error = store.volumesError { errorRow(error) }
                    ForEach(items) { volume in
                        let busy = store.pendingActions.contains(volume.name)
                        ServiceResourceRow(
                            symbol: ServiceSymbol.volume,
                            title: volume.name,
                            detail: volume.inUse ? volume.usedBy.joined(separator: ", ") : volume.driver,
                            status: busy ? .busy("Removing…") : volume.inUse ? ServiceStatus(tone: .success, text: "In Use") : nil
                        )
                        .equatable()
                        .tag(ServiceSelection.docker(.volume, volume.name))
                    }
                    if items.isEmpty { placeholder("No volumes.") }
                }
            } label: {
                ServiceResourceRow(symbol: ServiceSymbol.volume, title: "Volumes", detail: store.volumes.map { _ in UserMessage.integer(items.count) } ?? "")
                    .equatable()
            }
        }
    }

    @ViewBuilder
    private func networks(_ model: DockerListModel) -> some View {
        let items = model.networks
        if filter.isEmpty || !items.isEmpty {
            DisclosureGroup(isExpanded: expansion(ServicesWindowState.networksGroup)) {
                if store.networks == nil {
                    loadingOrError(store.networksError)
                } else {
                    if let error = store.networksError { errorRow(error) }
                    ForEach(items) { network in
                        let busy = store.pendingActions.contains(network.id)
                        ServiceResourceRow(
                            symbol: ServiceSymbol.network,
                            title: network.name,
                            detail: DockerDetailGroups.networkDetail(network),
                            status: busy ? .busy("Removing…") : network.containers.isEmpty ? nil : ServiceStatus(tone: .success, text: "In Use")
                        )
                        .equatable()
                        .tag(ServiceSelection.docker(.network, network.id))
                    }
                    if items.isEmpty { placeholder("No networks.") }
                }
            } label: {
                ServiceResourceRow(symbol: ServiceSymbol.network, title: "Networks", detail: store.networks.map { _ in UserMessage.integer(items.count) } ?? "")
                    .equatable()
            }
        }
    }

    @ViewBuilder
    private func loadingOrError(_ error: String?) -> some View {
        if let error {
            errorRow(error)
        } else {
            ServiceListNote(text: "Loading…", isLoading: true)
        }
    }

    private func errorRow(_ error: String) -> some View {
        ServiceListNote(text: error, tone: .failure)
    }

    private func placeholder(_ text: String) -> some View {
        ServiceListNote(text: text)
    }
}

struct DockerProviderActions: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        let store = ServicesStore.shared
        let compose = store.composeFile(for: workspace)
        Button("Compose Up", systemImage: ServiceSymbol.start) {
            if let compose { workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "up") }
        }
        .disabled(compose == nil)
        Button("Compose Down…", systemImage: ServiceSymbol.stop) {
            if let compose { workspace.confirmComposeDown(composePath: compose) }
        }
        .disabled(compose == nil)
        Divider()
        Button("Clean Up…", systemImage: ServiceSymbol.cleanUp) { store.presentCleanUp(in: workspace) }
        Divider()
        Button("Refresh", systemImage: ServiceSymbol.refresh) {
            store.reconnect()
            for window in store.allWindows where window.isVisible { store.reloadExpandedLists(window) }
        }
        Toggle("Show Stopped Containers", isOn: Binding(get: { store.showStopped }, set: { store.showStopped = $0 }))
        if let status = DockerState.shared.status, !status.providerApp.isEmpty {
            Divider()
            Button("Open \(status.provider.isEmpty ? "Docker" : status.provider)", systemImage: ServiceSymbol.openProvider) {
                workspace.openDockerProvider()
            }
        }
    }
}

struct DockerContextMenu: View {
    @Bindable var workspace: WorkspaceState
    let window: ServicesWindowState
    let selection: ServiceSelection

    var body: some View {
        let store = ServicesStore.shared
        switch selection.kind {
        case .container:
            if let container = store.container(selection.id) {
                Button("Show Logs", systemImage: ServiceSymbol.logs) { select(); store.show(.logs, in: workspace) }
                Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
                Button("Open Shell", systemImage: ServiceSymbol.shell) { store.openShell(container, in: workspace) }
                    .disabled(store.shellUnavailableReason(container) != nil)
                DockerOpenInBrowserMenu(container: container)
                Button("Restart", systemImage: ServiceSymbol.restart) { store.perform("restart", on: container, from: workspace) }
                    .disabled(!container.isRunning)
                if container.isRunning {
                    Button("Stop", systemImage: ServiceSymbol.stop) { store.perform("stop", on: container, from: workspace) }
                } else {
                    Button("Start", systemImage: ServiceSymbol.start) { store.perform("start", on: container, from: workspace) }
                }
                if store.composeService(container, in: workspace) != nil {
                    Divider()
                    DockerComposeServiceMenuItems(workspace: workspace, container: container)
                }
                Divider()
                Button("Copy Container ID", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(container.id) }
                Divider()
                Button("Remove Container…", systemImage: ServiceSymbol.remove, role: .destructive) {
                    store.requestRemove(selection, in: window, from: workspace)
                }
                .disabled(container.isRunning)
            }
        case .project:
            Button("Show Logs", systemImage: ServiceSymbol.logs) { select(); store.show(.logs, in: workspace) }
            if selection.id == store.thisProjectName(root: workspace.activeWorkspacePath, composeFile: store.composeFile(for: workspace)),
               let compose = store.composeFile(for: workspace) {
                Divider()
                Button("Compose Up", systemImage: ServiceSymbol.start) {
                    workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "up")
                }
                Button("Compose Down…", systemImage: ServiceSymbol.stop) { workspace.confirmComposeDown(composePath: compose) }
            }
        case .image:
            Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
            Button("Copy Image ID", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(selection.id) }
            Divider()
            Button("Remove Image…", systemImage: ServiceSymbol.remove, role: .destructive) {
                store.requestRemove(selection, in: window, from: workspace)
            }
        case .volume:
            Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
            Button("Copy Volume Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(selection.id) }
            Divider()
            Button("Remove Volume…", systemImage: ServiceSymbol.remove, role: .destructive) {
                store.requestRemove(selection, in: window, from: workspace)
            }
        case .network:
            if let network = store.networks?.first(where: { $0.id == selection.id }) {
                Button("Show Details", systemImage: ServiceSymbol.details) { select(); store.show(.details, in: workspace) }
                Button("Copy Network Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(network.name) }
                Divider()
                Button("Remove Network…", systemImage: ServiceSymbol.remove, role: .destructive) {
                    store.requestRemove(selection, in: window, from: workspace)
                }
                .disabled(store.networkRemovalBlocker(network) != nil)
            }
        case .pod, .deployment, .kubeService:
            EmptyView()
        }
    }

    private func select() {
        ServicesPanelContent.select(selection, in: window)
    }
}

struct DockerContextMenuItems: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        let store = ServicesStore.shared
        if let list = store.contexts {
            Picker("Docker Context", selection: Binding(
                get: { list.current },
                set: { store.useContext($0, from: workspace) }
            )) {
                ForEach(list.contexts) { context in
                    Text(context.name)
                        .tag(context.name)
                }
            }
            .pickerStyle(.inline)
            .disabled(store.switchingContext != nil)
        }
    }
}

struct DockerContextPicker: View {
    @Bindable var workspace: WorkspaceState
    var showsName = false

    var body: some View {
        let store = ServicesStore.shared
        if let list = store.contexts, list.contexts.count > 1 {
            let shown = store.switchingContext ?? list.current
            ServiceSelectionMenu(
                symbol: ServiceSymbol.context,
                title: "Docker Context",
                value: shown,
                help: "Docker Context: \(shown). Changing it here leaves the Docker CLI’s own context as it is.",
                showsValue: showsName,
                isDisabled: store.switchingContext != nil
            ) {
                DockerContextMenuItems(workspace: workspace)
            }
        }
    }
}

struct DockerOpenInBrowserMenu: View {
    let container: DockerContainer

    var body: some View {
        let store = ServicesStore.shared
        let ports = store.browserPorts(container)
        let isDisabled = store.browserUnavailableReason(container) != nil
        if ports.count == 1 {
            Button("Open in Browser", systemImage: ServiceSymbol.openInBrowser) { store.openInBrowser(ports[0]) }
                .disabled(isDisabled)
        } else if ports.count > 1 {
            Menu("Open in Browser", systemImage: ServiceSymbol.openInBrowser) {
                ForEach(ports, id: \.publicPort) { port in
                    Button("localhost:" + UserMessage.rawIdentifier(port.publicPort)) { store.openInBrowser(port) }
                }
            }
            .disabled(isDisabled)
        }
    }
}

struct DockerComposeServiceMenuItems: View {
    @Bindable var workspace: WorkspaceState
    let container: DockerContainer

    var body: some View {
        let store = ServicesStore.shared
        if store.composeService(container, in: workspace) != nil {
            Button("Rebuild and Restart", systemImage: ServiceSymbol.rebuild) {
                store.runServiceAction("rebuild", on: container, in: workspace)
            }
            if container.isRunning {
                Button("Stop Service", systemImage: ServiceSymbol.stop) { store.runServiceAction("stop", on: container, in: workspace) }
            } else {
                Button("Start Service", systemImage: ServiceSymbol.start) { store.runServiceAction("start", on: container, in: workspace) }
            }
        }
    }
}

struct DockerHeaderActions: View {
    @Bindable var workspace: WorkspaceState
    let window: ServicesWindowState
    let selection: ServiceSelection

    var body: some View {
        let store = ServicesStore.shared
        HStack(spacing: Spacing.standard) {
            switch selection.kind {
            case .container:
                if let container = store.container(selection.id) {
                    containerActions(container, store: store)
                }
            case .project:
                if selection.id == store.thisProjectName(root: workspace.activeWorkspacePath, composeFile: store.composeFile(for: workspace)),
                   let compose = store.composeFile(for: workspace) {
                    moreMenu {
                        Button("Compose Up", systemImage: ServiceSymbol.start) {
                            workspace.runDockerComposeCommand(composePath: compose, service: nil, action: "up")
                        }
                        Button("Compose Down…", systemImage: ServiceSymbol.stop) { workspace.confirmComposeDown(composePath: compose) }
                    }
                }
            case .image:
                moreMenu {
                    Button("Copy Image ID", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(selection.id) }
                    Divider()
                    Button("Remove Image…", systemImage: ServiceSymbol.remove, role: .destructive) {
                        store.requestRemove(selection, in: window, from: workspace)
                    }
                }
            case .volume:
                moreMenu {
                    Button("Copy Volume Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(selection.id) }
                    Divider()
                    Button("Remove Volume…", systemImage: ServiceSymbol.remove, role: .destructive) {
                        store.requestRemove(selection, in: window, from: workspace)
                    }
                }
            case .network:
                if let network = store.networks?.first(where: { $0.id == selection.id }) {
                    moreMenu {
                        Button("Copy Network Name", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(network.name) }
                        Divider()
                        Button("Remove Network…", systemImage: ServiceSymbol.remove, role: .destructive) {
                            store.requestRemove(selection, in: window, from: workspace)
                        }
                        .disabled(store.networkRemovalBlocker(network) != nil)
                    }
                }
            case .pod, .deployment, .kubeService:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func containerActions(_ container: DockerContainer, store: ServicesStore) -> some View {
        let busy = store.pendingActions.contains(container.id)
        if container.isRunning {
            iconButton("Stop", ServiceSymbol.stop, help: "Stop “\(container.name)”") { store.perform("stop", on: container, from: workspace) }
                .disabled(busy)
        } else {
            iconButton("Start", ServiceSymbol.start, help: "Start “\(container.name)”") { store.perform("start", on: container, from: workspace) }
                .disabled(busy)
        }
        iconButton("Restart", ServiceSymbol.restart, help: container.isRunning ? KeymapStore.shared.labeled("Restart", "services.restart") : "Start “\(container.name)” before restarting it") {
            store.perform("restart", on: container, from: workspace)
        }
        .disabled(busy || !container.isRunning)
        let shellReason = store.shellUnavailableReason(container)
        iconButton("Open Shell", ServiceSymbol.shell, help: shellReason ?? KeymapStore.shared.labeled("Open Shell", "services.openShell")) {
            store.openShell(container, in: workspace)
        }
        .disabled(shellReason != nil)
        let opensBrowser = !store.browserPorts(container).isEmpty
        let isService = store.composeService(container, in: workspace) != nil
        moreMenu {
            DockerOpenInBrowserMenu(container: container)
            if opensBrowser && isService { Divider() }
            DockerComposeServiceMenuItems(workspace: workspace, container: container)
            if opensBrowser || isService { Divider() }
            Button("Copy Container ID", systemImage: ServiceSymbol.copy) { store.copyToPasteboard(container.id) }
            Divider()
            Button("Remove Container…", systemImage: ServiceSymbol.remove, role: .destructive) {
                store.requestRemove(selection, in: window, from: workspace)
            }
            .disabled(container.isRunning)
        }
    }

    private func iconButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        ServiceHeaderButton(title: title, symbol: symbol, help: help, action: action)
    }

    private func moreMenu<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        ServiceMoreMenu(content: content)
    }
}

struct DockerServiceDetail: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var window: ServicesWindowState
    let selection: ServiceSelection

    private var store: ServicesStore { ServicesStore.shared }

    var body: some View {
        switch selection.kind {
        case .container:
            if let container = store.container(selection.id) {
                if window.mode == .logs {
                    logs(stopped: container.isRunning ? nil : container)
                } else {
                    containerDetails(container)
                }
            } else {
                gone("This container no longer exists.")
            }
        case .project:
            logs(stopped: nil)
        case .image:
            if let image = store.images?.first(where: { $0.id == selection.id }) {
                ServiceDetailsView(groups: DockerDetailGroups.image(image)).id(image.id)
            } else {
                gone("This image no longer exists.")
            }
        case .volume:
            if let volume = store.volumes?.first(where: { $0.name == selection.id }) {
                ServiceDetailsView(groups: DockerDetailGroups.volume(volume)).id(volume.name)
            } else {
                gone("This volume no longer exists.")
            }
        case .network:
            if let network = store.networks?.first(where: { $0.id == selection.id }) {
                ServiceDetailsView(groups: DockerDetailGroups.network(network)).id(network.id)
            } else {
                gone("This network no longer exists.")
            }
        case .pod, .deployment, .kubeService:
            EmptyView()
        }
    }

    private func gone(_ message: String) -> some View {
        UnifiedEmptyState.empty(symbol: ServiceSymbol.container, title: "No Selection", message: message)
    }

    @ViewBuilder
    private func containerDetails(_ container: DockerContainer) -> some View {
        if let details = window.details, details.id == container.id {
            ServiceDetailsView(groups: DockerDetailGroups.container(
                details,
                opensPorts: details.state == "running" && !store.isRemoteEngine,
                usage: window.statsTargetID == details.id ? window.stats.map(ServicesStore.statsSummary) : nil
            ))
            .id(details.id)
        } else if let error = window.detailsError {
            UnifiedEmptyState.failed(title: "Couldn’t Read the Details", message: error) {
                store.loadDetailsIfNeeded(window, force: true)
            }
        } else {
            UnifiedEmptyState.loading(message: "Reading details…")
        }
    }

    private func logs(stopped: DockerContainer?) -> some View {
        ServiceLogsView(
            window: window,
            emptyMessage: selection.kind == .project ? "The project’s services haven’t printed anything." : "The container hasn’t printed anything.",
            onRetry: {
                store.closeLogs(window)
                store.syncLogs(window)
            }
        ) {
            if let stopped {
                let failed = (stopped.exitCode ?? 0) != 0 || stopped.state == "dead"
                InlineBanner(
                    .status(failed ? .failure : .inactive),
                    title: stopped.state == "exited" ? "“\(stopped.name)” Exited with Code \(UserMessage.rawIdentifier(stopped.exitCode ?? 0))" : "“\(stopped.name)” Isn’t Running",
                    message: "Start it to follow new output.",
                    detail: stopped.status
                ) {
                    Button("Start") { store.perform("start", on: stopped, from: workspace) }
                        .disabled(store.pendingActions.contains(stopped.id))
                }
            }
        }
    }
}

enum DockerDetailGroups {
    static func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = parser.date(from: value) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }()
        guard let parsed, parsed.timeIntervalSince1970 > 0, Calendar.current.component(.year, from: parsed) > 2000 else { return "" }
        return date(parsed)
    }

    static func date(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func container(_ d: DockerContainerDetails, opensPorts: Bool, usage: String? = nil) -> [ServiceDetailGroup] {
        var overview: [ServiceDetailRow] = [
            ServiceDetailRow(label: "Name", value: d.name),
            ServiceDetailRow(label: "Image", value: d.image, copyTitle: "Copy Image Name"),
            ServiceDetailRow(label: "Command", value: d.command, isMonospaced: true),
            ServiceDetailRow(label: "State", value: state(d)),
        ]
        if let usage { overview.append(ServiceDetailRow(label: "Usage", value: usage)) }
        if !d.health.isEmpty { overview.append(ServiceDetailRow(label: "Health", value: d.health.capitalized)) }
        let created = date(d.created)
        if !created.isEmpty { overview.append(ServiceDetailRow(label: "Created", value: created)) }
        if !d.restartPolicy.isEmpty { overview.append(ServiceDetailRow(label: "Restart Policy", value: d.restartPolicy)) }
        if !d.workingDir.isEmpty { overview.append(ServiceDetailRow(label: "Working Folder", value: d.workingDir, isMonospaced: true)) }
        if !d.project.isEmpty { overview.append(ServiceDetailRow(label: "Compose Service", value: "\(d.project) / \(d.service)")) }
        overview.append(ServiceDetailRow(label: "Container ID", value: d.id, isMonospaced: true, copyTitle: "Copy Container ID"))
        let ports = d.ports.map { port in
            ServiceDetailRow(
                label: UserMessage.rawIdentifier(port.privatePort) + "/" + port.type,
                value: port.address ?? "Not published",
                isMonospaced: port.address != nil,
                copyTitle: port.address == nil ? nil : "Copy Address",
                openURL: opensPorts ? port.browserURL : nil
            )
        }
        let env = d.env.map { ServiceDetailRow(label: $0.key, value: $0.value, isMonospaced: true, isMasked: true, copyTitle: "Copy Value") }
        let mounts = d.mounts.map { mount in
            ServiceDetailRow(
                label: mount.destination,
                value: (mount.name.isEmpty ? mount.source : mount.name) + (mount.readOnly ? " (read-only)" : ""),
                isMonospaced: true,
                copyTitle: "Copy Source"
            )
        }
        let networks = d.networks.map { network in
            ServiceDetailRow(label: network.name, value: network.ipAddress.isEmpty ? "No address" : network.ipAddress, isMonospaced: true)
        }
        let labels = d.labels.map { ServiceDetailRow(label: $0.key, value: $0.value, isMonospaced: true) }
        return [
            ServiceDetailGroup(title: "Overview", rows: overview),
            ServiceDetailGroup(title: "Ports", rows: ports, emptyText: "No ports."),
            ServiceDetailGroup(title: "Environment", rows: env, emptyText: "No variables."),
            ServiceDetailGroup(title: "Mounts", rows: mounts, emptyText: "No mounts."),
            ServiceDetailGroup(title: "Networks", rows: networks, emptyText: "No networks."),
            ServiceDetailGroup(title: "Labels", rows: labels, emptyText: "No labels.", startsCollapsed: true),
        ]
    }

    private static func state(_ d: DockerContainerDetails) -> String {
        switch d.state {
        case "running": return "Running"
        case "exited": return "Exited with code \(UserMessage.rawIdentifier(d.exitCode))" + (d.oomKilled ? ", out of memory" : "")
        default: return d.state.capitalized
        }
    }

    static func image(_ image: DockerImage) -> [ServiceDetailGroup] {
        var overview = [
            ServiceDetailRow(label: "Name", value: image.name),
            ServiceDetailRow(label: "Size", value: UserMessage.byteCount(image.size)),
        ]
        if image.created > 0 {
            overview.append(ServiceDetailRow(label: "Created", value: date(Date(timeIntervalSince1970: TimeInterval(image.created)))))
        }
        overview.append(ServiceDetailRow(label: "Image ID", value: image.id, isMonospaced: true, copyTitle: "Copy Image ID"))
        return [
            ServiceDetailGroup(title: "Overview", rows: overview),
            ServiceDetailGroup(title: "Tags", rows: image.tags.map { ServiceDetailRow(label: "Tag", value: $0, isMonospaced: true, copyTitle: "Copy Tag") }, emptyText: "Untagged."),
            ServiceDetailGroup(title: "Used By", rows: image.usedBy.map { ServiceDetailRow(label: "Container", value: $0) }, emptyText: "No container uses this image."),
        ]
    }

    static func networkDetail(_ network: DockerNetworkSummary) -> String {
        if !network.containers.isEmpty { return network.containers.joined(separator: ", ") }
        return network.builtIn ? "Built In · \(network.driver)" : network.driver
    }

    static func network(_ network: DockerNetworkSummary) -> [ServiceDetailGroup] {
        var overview = [
            ServiceDetailRow(label: "Name", value: network.name, copyTitle: "Copy Network Name"),
            ServiceDetailRow(label: "Driver", value: network.driver),
        ]
        if !network.scope.isEmpty { overview.append(ServiceDetailRow(label: "Scope", value: network.scope.capitalized)) }
        overview.append(ServiceDetailRow(label: "Origin", value: network.builtIn ? "Built into Docker" : "User-created"))
        let created = date(network.created)
        if !created.isEmpty { overview.append(ServiceDetailRow(label: "Created", value: created)) }
        overview.append(ServiceDetailRow(label: "Network ID", value: network.id, isMonospaced: true, copyTitle: "Copy Network ID"))
        return [
            ServiceDetailGroup(title: "Overview", rows: overview),
            ServiceDetailGroup(title: "Containers", rows: network.containers.map { ServiceDetailRow(label: "Container", value: $0) }, emptyText: "No container uses this network."),
        ]
    }

    static func volume(_ volume: DockerVolume) -> [ServiceDetailGroup] {
        var overview = [
            ServiceDetailRow(label: "Name", value: volume.name, copyTitle: "Copy Volume Name"),
            ServiceDetailRow(label: "Driver", value: volume.driver),
            ServiceDetailRow(label: "Mount Point", value: volume.mountpoint, isMonospaced: true, copyTitle: "Copy Mount Point"),
        ]
        let created = date(volume.created)
        if !created.isEmpty { overview.append(ServiceDetailRow(label: "Created", value: created)) }
        if !volume.project.isEmpty { overview.append(ServiceDetailRow(label: "Compose Project", value: volume.project)) }
        return [
            ServiceDetailGroup(title: "Overview", rows: overview),
            ServiceDetailGroup(title: "Used By", rows: volume.usedBy.map { ServiceDetailRow(label: "Container", value: $0) }, emptyText: "No container uses this volume."),
        ]
    }
}

extension View {
    @ViewBuilder
    func serviceTag(_ selection: ServiceSelection?) -> some View {
        if let selection {
            tag(selection)
        } else {
            self
        }
    }
}
