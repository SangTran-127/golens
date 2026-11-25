import AppKit
import Foundation
import GoLensFoundation
import Observation

extension DockerPort {
    var mapping: String {
        let inner = UserMessage.rawIdentifier(privatePort) + (type == "tcp" ? "" : "/" + type)
        guard publicPort > 0 else { return inner }
        return UserMessage.rawIdentifier(publicPort) + "→" + inner
    }

    var address: String? {
        guard publicPort > 0 else { return nil }
        let host = ip.isEmpty || ip == "0.0.0.0" || ip == "::" ? "localhost" : ip
        return host + ":" + UserMessage.rawIdentifier(publicPort)
    }

    var browserURL: URL? {
        guard publicPort > 0, type == "tcp", ["", "0.0.0.0", "::", "127.0.0.1"].contains(ip) else { return nil }
        return URL(string: "http://localhost:" + UserMessage.rawIdentifier(publicPort))
    }
}

extension DockerContainer {
    var statusTone: StatusTone {
        switch state {
        case "running": health == "unhealthy" ? .warning : .success
        case "restarting": .warning
        case "dead": .failure
        case "exited": (exitCode ?? 0) == 0 ? .inactive : .failure
        default: .inactive
        }
    }

    var statusText: String {
        switch state {
        case "running":
            switch health {
            case "healthy": "Running (Healthy)"
            case "unhealthy": "Running (Unhealthy)"
            case "starting": "Running (Starting)"
            default: "Running"
            }
        case "exited": "Exited (\(UserMessage.rawIdentifier(exitCode ?? 0)))"
        case "restarting": "Restarting"
        case "paused": "Paused"
        case "created": "Created"
        case "dead": "Dead"
        case "removing": "Removing"
        default: state.isEmpty ? "Unknown" : state.capitalized
        }
    }

    var detailText: String {
        if isRunning {
            return ports.filter { $0.publicPort > 0 }.map(\.mapping).joined(separator: ", ")
        }
        if state == "exited", let close = status.range(of: ") ") {
            return String(status[close.upperBound...])
        }
        return state == "created" ? "" : status
    }

    var rowTitle: String { service.isEmpty ? name : service }
}

extension ServicesStore {

    func syncLogs(_ window: ServicesWindowState) {
        var ids: [String] = []
        if window.isVisible, window.mode == .logs, let selection = window.selection, selection.provider == Self.dockerProvider {
            switch selection.kind {
            case .container:
                if container(selection.id) != nil { ids = [selection.id] }
            case .project:
                ids = projectContainers(selection.id).map(\.id)
            default:
                break
            }
        }
        guard ids != window.logTargetIDs else { return }
        closeLogs(window)
        window.logTargetIDs = ids
        window.clearLogs()
        guard !ids.isEmpty else { return }
        window.logRequest += 1
        let request = window.logRequest
        let json = jsonText(ids)
        ffiQueue.async {
            let stream = json.withCString { DockerLogsOpen($0, Self.logTail) }
            DispatchQueue.main.async {
                guard window.logRequest == request, window.logTargetIDs == ids else {
                    if stream > 0 { self.ffiQueue.async { DockerLogsClose(stream) } }
                    return
                }
                guard stream > 0 else {
                    window.logEndedMessage = "GoLens couldn’t open the logs."
                    return
                }
                window.logStreamID = stream
                self.logOwners[stream] = window
                for batch in self.pendingLogBatches.removeValue(forKey: stream) ?? [] {
                    self.applyLogs(batch, messages: Self.messages(batch))
                }
                self.pendingLogBatches = self.pendingLogBatches.filter { $0.key > stream }
            }
        }
    }

    func closeLogs(_ window: ServicesWindowState) {
        window.logRequest += 1
        let stream = window.logStreamID
        window.logStreamID = 0
        window.logTargetIDs = []
        guard stream > 0 else { return }
        logOwners[stream] = nil
        ffiQueue.async { DockerLogsClose(stream) }
    }

    static func messages(_ batch: DockerLogBatch) -> [WorkspaceState.LogMessage] {
        batch.lines.map { line in
            WorkspaceState.consoleMessage(line.prefix.isEmpty ? line.text : line.prefix + " | " + line.text, isStderr: line.stderr)
        }
    }

    func applyLogs(_ batch: DockerLogBatch, messages: [WorkspaceState.LogMessage]) {
        guard let window = logOwners[batch.stream] else {
            let awaiting = allWindows.contains { $0.logStreamID == 0 && !$0.logTargetIDs.isEmpty }
            if batch.stream > 0, awaiting, (pendingLogBatches[batch.stream]?.count ?? 0) < 20 {
                pendingLogBatches[batch.stream, default: []].append(batch)
            }
            return
        }
        var lines = messages
        if batch.dropped > 0 {
            lines.insert(WorkspaceState.LogMessage(text: "… \(UserMessage.quantity(batch.dropped, "line")) skipped to keep up with the output."), at: 0)
        }
        window.appendLogs(lines)
        if batch.closed {
            logOwners[batch.stream] = nil
            window.logStreamID = 0
            switch batch.reason {
            case "removed": window.logEndedMessage = "The container was removed, so its logs ended."
            case "error": window.logEndedMessage = batch.error.isEmpty ? "The log stream stopped." : batch.error
            default: window.logEndedMessage = "The log stream ended."
            }
        }
    }

    func loadDetailsIfNeeded(_ window: ServicesWindowState, force: Bool = false) {
        if window.selection?.provider == Self.kubernetesProvider {
            loadKubeDetailsIfNeeded(window, force: force)
            return
        }
        guard window.isVisible, window.mode == .details, let selection = window.selection,
              selection.provider == Self.dockerProvider, selection.kind == .container else { return }
        let id = selection.id
        guard force || window.detailsKey != id || (window.details == nil && window.detailsError == nil) else { return }
        if window.detailsKey != id {
            window.details = nil
            window.detailsError = nil
        }
        window.detailsKey = id
        window.isLoadingDetails = window.details == nil
        BackgroundFFI.shared.run(ObjectIdentifier(window)) {
            BackgroundFFI.decode(DockerInspectResult.self, from: BackgroundFFI.callString(id) { DockerContainerInspect($0) })
                ?? DockerInspectResult(error: "GoLens couldn’t read the container’s details.")
        } deliver: { result in
            guard window.detailsKey == id else { return }
            window.isLoadingDetails = false
            if let details = result.container {
                if window.details != details { window.details = details }
                window.detailsError = nil
            } else {
                window.detailsError = result.error.isEmpty ? "GoLens couldn’t read the container’s details." : result.error
            }
        }
    }

    func reloadExpandedLists(_ window: ServicesWindowState) {
        if window.isExpanded(ServicesWindowState.imagesGroup) { loadList("images") }
        if window.isExpanded(ServicesWindowState.volumesGroup) { loadList("volumes") }
        if window.isExpanded(ServicesWindowState.networksGroup) { loadList("network") }
        widenWatchIfNeeded()
    }

    func loadList(_ kind: String) {
        BackgroundFFI.shared.run("services.list." + kind, debounce: 0.3) {
            BackgroundFFI.callString(kind) { DockerList($0) }
        } deliver: { json in
            switch kind {
            case "images":
                let result = BackgroundFFI.decode(DockerListResult<DockerImage>.self, from: json) ?? DockerListResult(error: "GoLens couldn’t read the image list.")
                self.imagesError = result.error.isEmpty ? nil : result.error
                if result.error.isEmpty || self.images == nil {
                    let sorted = result.items.sorted { ($0.dangling ? 1 : 0, $0.name) < ($1.dangling ? 1 : 0, $1.name) }
                    if self.images != sorted { self.images = sorted }
                }
            case "network":
                let result = BackgroundFFI.decode(DockerListResult<DockerNetworkSummary>.self, from: json) ?? DockerListResult(error: "GoLens couldn’t read the network list.")
                self.networksError = result.error.isEmpty ? nil : result.error
                if result.error.isEmpty || self.networks == nil {
                    let sorted = result.items.sorted { ($0.builtIn ? 1 : 0, $0.name) < ($1.builtIn ? 1 : 0, $1.name) }
                    if self.networks != sorted { self.networks = sorted }
                }
            default:
                let result = BackgroundFFI.decode(DockerListResult<DockerVolume>.self, from: json) ?? DockerListResult(error: "GoLens couldn’t read the volume list.")
                self.volumesError = result.error.isEmpty ? nil : result.error
                if result.error.isEmpty || self.volumes == nil {
                    let sorted = result.items.sorted { $0.name < $1.name }
                    if self.volumes != sorted { self.volumes = sorted }
                }
            }
        }
    }

    func isLoadingList(_ kind: String) -> Bool {
        BackgroundFFI.shared.isPending("services.list." + kind)
    }

    func perform(_ action: String, on container: DockerContainer, from workspace: WorkspaceState) {
        let id = container.id
        let name = container.name
        guard !pendingActions.contains(id) else { return }
        pendingActions.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = id.withCString { i in
                action.withCString { a -> DockerActionResult in
                    guard let out = DockerContainerAction(i, a) else { return DockerActionResult(error: "") }
                    defer { FreeGoCString(out) }
                    return (try? JSONDecoder().decode(DockerActionResult.self, from: Data(String(cString: out).utf8))) ?? DockerActionResult(error: "")
                }
            }
            DispatchQueue.main.async {
                self.pendingActions.remove(id)
                guard !result.ok else { return }
                let verb = ["start": "Start", "stop": "Stop", "restart": "Restart"][action] ?? "Change"
                workspace.presentCommandFeedback(
                    result.error.isEmpty ? "The engine gave no reason. Check that Docker is running, then try again." : result.error,
                    title: "Couldn’t \(verb) “\(name)”",
                    tone: .failure
                )
            }
        }
    }

    func remove(kind: String, id: String, name: String, from workspace: WorkspaceState) {
        guard !pendingActions.contains(id) else { return }
        pendingActions.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = kind.withCString { k in
                id.withCString { i -> DockerActionResult in
                    guard let out = DockerRemove(k, i) else { return DockerActionResult(error: "") }
                    defer { FreeGoCString(out) }
                    return (try? JSONDecoder().decode(DockerActionResult.self, from: Data(String(cString: out).utf8))) ?? DockerActionResult(error: "")
                }
            }
            DispatchQueue.main.async {
                self.pendingActions.remove(id)
                if result.ok {
                    switch kind {
                    case "image":
                        self.images?.removeAll { $0.id == id }
                        self.loadList("images")
                    case "volume":
                        self.volumes?.removeAll { $0.name == id }
                        self.loadList("volumes")
                    case "network":
                        self.networks?.removeAll { $0.id == id }
                        self.loadList("network")
                    default:
                        break
                    }
                    return
                }
                let noun = ["container": "Container", "image": "Image", "volume": "Volume", "network": "Network"][kind] ?? "Object"
                workspace.presentCommandFeedback(
                    result.error.isEmpty ? "The engine gave no reason. Check that Docker is running, then try again." : result.error,
                    title: "Couldn’t Remove the \(noun) “\(name)”",
                    tone: .failure
                )
            }
        }
    }

    func requestRemove(_ selection: ServiceSelection, in window: ServicesWindowState, from workspace: WorkspaceState) {
        switch selection.kind {
        case .container:
            guard let container = container(selection.id) else { return }
            if container.isRunning {
                workspace.presentCommandFeedback("Stop “\(container.name)” before removing it.", title: "Container Is Running", tone: .info)
                return
            }
            window.confirmation = .removeContainer(id: container.id, name: container.name)
        case .image:
            guard let image = images?.first(where: { $0.id == selection.id }) else { return }
            window.confirmation = .removeImage(id: image.id, name: image.name, size: image.size)
        case .volume:
            window.confirmation = .removeVolume(name: selection.id)
        case .network:
            guard let network = networks?.first(where: { $0.id == selection.id }) else { return }
            if let reason = networkRemovalBlocker(network) {
                workspace.presentCommandFeedback(reason, title: "Can’t Remove “\(network.name)”", tone: .info)
                return
            }
            window.confirmation = .removeNetwork(id: network.id, name: network.name)
        case .project:
            break
        case .pod, .deployment, .kubeService:
            requestKubeDelete(selection, in: window, from: workspace)
        }
    }

    func confirm(_ confirmation: ServiceConfirmation, from workspace: WorkspaceState) {
        switch confirmation {
        case .removeContainer(let id, let name): remove(kind: "container", id: id, name: name, from: workspace)
        case .removeImage(let id, let name, _): remove(kind: "image", id: id, name: name, from: workspace)
        case .removeVolume(let name): remove(kind: "volume", id: name, name: name, from: workspace)
        case .removeNetwork(let id, let name): remove(kind: "network", id: id, name: name, from: workspace)
        case .deletePod, .rolloutRestart, .useKubectlDefault: confirmKube(confirmation, from: workspace)
        }
    }

    func networkRemovalBlocker(_ network: DockerNetworkSummary) -> String? {
        if network.builtIn { return "“\(network.name)” is built into Docker, so it can’t be removed." }
        if !network.containers.isEmpty {
            return "Remove or disconnect \(UserMessage.count(network.containers.count, "container")) first: \(network.containers.joined(separator: ", "))."
        }
        return nil
    }

    var dockerCLIMissing: Bool {
        guard let status = DockerState.shared.status else { return false }
        return status.cliPath.isEmpty
    }

    func shellUnavailableReason(_ container: DockerContainer) -> String? {
        if dockerCLIMissing { return "Open Shell needs the docker command. Install OrbStack, Docker Desktop or Colima." }
        if !container.isRunning { return "Start “\(container.name)” to open a shell in it." }
        return nil
    }

    func openShell(_ container: DockerContainer, in workspace: WorkspaceState) {
        if let reason = shellUnavailableReason(container) {
            workspace.presentCommandFeedback(reason, title: "Can’t Open a Shell", tone: .info)
            return
        }
        let cli = DockerState.shared.status?.cliPath ?? ""
        let argv = [cli.isEmpty ? "docker" : cli, "exec", "-it", container.id, "sh", "-c",
                    "if command -v bash >/dev/null; then exec bash; else exec sh; fi"]
        workspace.openCommandTerminal(title: "\(container.name) (container)", argv: argv)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func selectedContainer(in workspace: WorkspaceState) -> DockerContainer? {
        guard let selection = window(for: workspace).selection, selection.kind == .container else { return nil }
        return container(selection.id)
    }

    func show(_ mode: ServiceDetailMode, in workspace: WorkspaceState) {
        let window = window(for: workspace)
        if window.mode != mode {
            window.mode = mode
            syncStreams(window)
            loadDetailsIfNeeded(window)
        }
        workspace.showServicesPanel()
    }
}

enum DockerEngineBridge {
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { FreeGoCString(pointer) }
        return String(cString: pointer)
    }

    static func diskUsage() -> String? { take(DockerDiskUsage()) }
    static func prune(_ optionsJSON: String) -> String? { take(optionsJSON.withCString { DockerPrune($0) }) }
    static func statsStart(_ id: String) -> Int64 { Int64(id.withCString { DockerStatsStart($0) }) }
    static func statsStop(_ stream: Int64) { DockerStatsStop(stream) }
    static func contexts() -> String? { take(DockerContexts()) }
    static func useContext(_ name: String) -> String? { take(name.withCString { DockerUseContext($0) }) }
}

extension ServicesStore {
    func syncStreams(_ window: ServicesWindowState) {
        syncLogs(window)
        syncStats(window)
        syncKubeLogs(window)
    }

    func syncStats(_ window: ServicesWindowState) {
        var target: String?
        if window.isVisible, window.mode == .details, let selection = window.selection,
           selection.provider == Self.dockerProvider, selection.kind == .container,
           let container = container(selection.id), container.state == "running" {
            target = container.id
        }
        guard target != window.statsTargetID else { return }
        closeStats(window)
        window.statsTargetID = target
        guard let id = target else { return }
        window.statsRequest += 1
        let request = window.statsRequest
        ffiQueue.async {
            let stream = DockerEngineBridge.statsStart(id)
            DispatchQueue.main.async {
                guard window.statsRequest == request, window.statsTargetID == id else {
                    if stream > 0 { self.ffiQueue.async { DockerEngineBridge.statsStop(stream) } }
                    return
                }
                guard stream > 0 else { return }
                window.statsStreamID = stream
                self.statsOwners[stream] = window
            }
        }
    }

    func closeStats(_ window: ServicesWindowState) {
        window.statsRequest += 1
        let stream = window.statsStreamID
        window.statsStreamID = 0
        window.statsTargetID = nil
        if window.stats != nil { window.stats = nil }
        guard stream > 0 else { return }
        statsOwners[stream] = nil
        ffiQueue.async { DockerEngineBridge.statsStop(stream) }
    }

    func applyStats(_ sample: DockerStatsSample) {
        guard let window = statsOwners[sample.stream], window.statsTargetID == sample.id else { return }
        if sample.closed {
            statsOwners[sample.stream] = nil
            window.statsStreamID = 0
            window.stats = nil
            return
        }
        if window.stats != sample { window.stats = sample }
    }

    static func statsSummary(_ sample: DockerStatsSample) -> String {
        let cpu = (sample.cpuPercent / 100).formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        var memory = UserMessage.byteCount(sample.memoryBytes, style: .memory)
        if sample.memoryLimitBytes > 0 {
            memory += " of " + UserMessage.byteCount(sample.memoryLimitBytes, style: .memory)
        }
        return "CPU \(cpu) · Memory \(memory)"
    }

    var isRemoteEngine: Bool {
        if let current = contexts?.currentContext { return current.isRemote }
        return engine.endpoint.hasPrefix("ssh://") || engine.endpoint.hasPrefix("tcp://")
    }

    func loadContexts() {
        BackgroundFFI.shared.run("services.contexts") {
            DockerEngineBridge.contexts()
        } deliver: { json in
            let list = BackgroundFFI.decode(DockerContextList.self, from: json) ?? DockerContextList(error: "GoLens couldn’t read the Docker contexts.")
            guard list.error.isEmpty else {
                self.contextsError = list.error
                return
            }
            self.contextsError = nil
            self.contexts = list
        }
    }

    func useContext(_ name: String, from workspace: WorkspaceState) {
        guard name != contexts?.current, switchingContext == nil else { return }
        switchingContext = name
        ffiQueue.async {
            let json = DockerEngineBridge.useContext(name)
            DispatchQueue.main.async {
                self.switchingContext = nil
                let result = BackgroundFFI.decode(DockerActionResult.self, from: json) ?? DockerActionResult(error: "")
                guard result.ok else {
                    workspace.presentCommandFeedback(
                        result.error.isEmpty ? "GoLens couldn’t switch the Docker context. Check that the context still exists, then try again." : result.error,
                        title: "Couldn’t Switch to “\(name)”",
                        tone: .failure
                    )
                    return
                }
                self.contexts?.current = name
                self.containers = []
                self.images = nil
                self.volumes = nil
                self.networks = nil
                self.engine = DockerEngineLink()
                for window in self.allWindows {
                    self.closeLogs(window)
                    self.closeStats(window)
                    window.clearLogs()
                    window.selection = nil
                    window.details = nil
                    window.detailsError = nil
                    window.detailsKey = ""
                }
                if self.isConnected {
                    self.lastSeq = 0
                    self.connectStartedAt = .now()
                    self.phase = .connecting
                }
                self.loadContexts()
                self.statusWorkspace?.refreshDockerStatus(force: true)
                for window in self.allWindows where window.isVisible { self.reloadExpandedLists(window) }
            }
        }
    }

    func browserPorts(_ container: DockerContainer) -> [DockerPort] {
        var seen: Set<Int> = []
        return container.ports.filter { port in
            guard port.browserURL != nil, !seen.contains(port.publicPort) else { return false }
            seen.insert(port.publicPort)
            return true
        }
    }

    func browserUnavailableReason(_ container: DockerContainer) -> String? {
        if isRemoteEngine { return "Open in Browser works only with a Docker engine on this Mac." }
        if !container.isRunning { return "Start “\(container.name)” to open its port in a browser." }
        if browserPorts(container).isEmpty { return "“\(container.name)” publishes no TCP port on this Mac." }
        return nil
    }

    func openInBrowser(_ port: DockerPort) {
        guard let url = port.browserURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openInBrowser(_ container: DockerContainer, from workspace: WorkspaceState) {
        if let reason = browserUnavailableReason(container) {
            workspace.presentCommandFeedback(reason, title: "Can’t Open in Browser", tone: .info)
            return
        }
        if let port = browserPorts(container).first { openInBrowser(port) }
    }

    func composeService(_ container: DockerContainer, in workspace: WorkspaceState) -> (composePath: String, service: String)? {
        guard !container.service.isEmpty, let compose = composeFile(for: workspace),
              Self.isThisProject(container, root: workspace.activeWorkspacePath, composeFile: compose) else { return nil }
        return (compose, container.service)
    }

    func runServiceAction(_ action: String, on container: DockerContainer, in workspace: WorkspaceState) {
        guard let target = composeService(container, in: workspace) else {
            workspace.presentCommandFeedback("“\(container.name)” isn’t a service of this project’s compose file.", title: "Not a Project Service", tone: .info)
            return
        }
        workspace.runDockerComposeCommand(composePath: target.composePath, service: target.service, action: action)
    }

    var engineContextName: String {
        let name = contexts?.current ?? ""
        return name.isEmpty ? engine.context : name
    }

    func presentCleanUp(in workspace: WorkspaceState) {
        workspace.router.activeSheet = .dockerCleanUp(DockerCleanUpRequest(context: engineContextName))
    }
}

extension DockerPruneKind {
    var title: String {
        switch self {
        case .containers: "Stopped Containers"
        case .images: "Dangling Images"
        case .volumes: "Unused Volumes"
        case .networks: "Unused Networks"
        case .buildCache: "Build Cache"
        }
    }

    func noun(_ count: Int) -> String {
        switch self {
        case .containers: UserMessage.count(count, "stopped container")
        case .images: UserMessage.count(count, "dangling image")
        case .volumes: UserMessage.count(count, "unused volume")
        case .networks: UserMessage.count(count, "unused network")
        case .buildCache: UserMessage.count(count, "build cache entry", "build cache entries")
        }
    }
}

struct DockerCleanUpRequest: Identifiable, Hashable {
    let id = UUID()
    let context: String
}

@Observable
final class DockerCleanUpModel {
    enum Phase: Equatable {
        case ready
        case cleaning(DockerPruneKind)
        case failed(DockerPruneKind, String)
    }

    var usage: DockerDiskUsage?
    var usageError: String?
    var isMeasuring = false
    var selected: Set<DockerPruneKind> = Set(DockerPruneKind.allCases.filter(\.isCheckedByDefault))
    var phase: Phase = .ready
    var results: [DockerPruneResult] = []
    var runTotal = 0
    var isCanceling = false
    var wasCanceled = false

    static var pruneLabel: String? {
        let label = ProcessInfo.processInfo.environment["GOLENS_SMOKE_PRUNE_LABEL"] ?? ""
        return label.isEmpty ? nil : label
    }

    var isCleaning: Bool {
        if case .cleaning = phase { return true }
        return false
    }

    var plannedKinds: [DockerPruneKind] {
        guard let usage else { return [] }
        return DockerPruneKind.allCases.filter { selected.contains($0) && usage.category($0).count > 0 }
    }

    var plannedBytes: Int64 {
        usage?.reclaimableBytes(Set(plannedKinds)) ?? 0
    }

    var removedBytes: Int64 { results.reduce(0) { $0 + $1.bytes } }

    func measure() {
        isMeasuring = true
        usageError = nil
        BackgroundFFI.shared.run("services.diskUsage") {
            DockerEngineBridge.diskUsage()
        } deliver: { json in
            let usage = BackgroundFFI.decode(DockerDiskUsage.self, from: json)
                ?? DockerDiskUsage(error: "GoLens couldn’t measure Docker’s disk usage. Check that the engine is running, then try again.")
            self.isMeasuring = false
            if usage.error.isEmpty {
                self.usage = usage
            } else {
                self.usageError = usage.error
            }
        }
    }

    func cleanUp(onFinished: @escaping () -> Void) {
        let kinds = plannedKinds
        guard !kinds.isEmpty, !isCleaning, !isMeasuring else { return }
        results = []
        runTotal = kinds.count
        wasCanceled = false
        isCanceling = false
        run(kinds[...], onFinished: onFinished)
    }

    func cancel() {
        guard isCleaning else { return }
        isCanceling = true
    }

    private func run(_ remaining: ArraySlice<DockerPruneKind>, onFinished: @escaping () -> Void) {
        guard let kind = remaining.first else {
            phase = .ready
            onFinished()
            return
        }
        if isCanceling {
            isCanceling = false
            wasCanceled = true
            phase = .ready
            measure()
            return
        }
        phase = .cleaning(kind)
        let options = DockerPruneOptions(kind: kind, label: Self.pruneLabel).json
        ServicesStore.shared.ffiQueue.async {
            let json = DockerEngineBridge.prune(options)
            DispatchQueue.main.async {
                let result = BackgroundFFI.decode(DockerPruneResult.self, from: json)
                    ?? DockerPruneResult(error: "GoLens couldn’t reach the Docker engine. Check that it is running, then try again.")
                guard result.error.isEmpty else {
                    self.isCanceling = false
                    self.phase = .failed(kind, result.error)
                    self.measure()
                    return
                }
                self.results.append(result)
                self.run(remaining.dropFirst(), onFinished: onFinished)
            }
        }
    }

    var summary: String {
        let removed = results.filter { $0.removed > 0 }.compactMap { result in
            DockerPruneKind(rawValue: result.kind).map { $0.noun(result.removed) }
        }
        guard !removed.isEmpty else { return "Nothing needed removing." }
        return "Removed \(removed.joined(separator: ", ")) and freed \(UserMessage.byteCount(removedBytes))."
    }
}
