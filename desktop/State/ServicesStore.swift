import Foundation
import GoLensFoundation
import Observation

struct ServiceSelection: Hashable {
    enum Kind: String {
        case container, project, image, volume, network
        case pod, deployment, kubeService
    }

    let provider: String
    let kind: Kind
    let id: String

    static func docker(_ kind: Kind, _ id: String) -> ServiceSelection {
        ServiceSelection(provider: ServicesStore.dockerProvider, kind: kind, id: id)
    }

    static func kube(_ kind: Kind, _ name: String) -> ServiceSelection {
        ServiceSelection(provider: ServicesStore.kubernetesProvider, kind: kind, id: name)
    }

    var showsLogs: Bool { kind == .container || kind == .project || kind == .pod }
    var showsDetails: Bool { kind != .project }
}

enum ServiceDetailMode: String, CaseIterable, Identifiable {
    case logs = "Logs"
    case details = "Details"

    var id: String { rawValue }
}

enum DockerEnginePhase: Equatable {
    case idle
    case connecting
    case running
    case reconnecting
    case unavailable(reason: String, message: String)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum ServiceConfirmation: Identifiable, Equatable {
    case removeContainer(id: String, name: String)
    case removeImage(id: String, name: String, size: Int64)
    case removeVolume(name: String)
    case removeNetwork(id: String, name: String)
    case deletePod(context: String, namespace: String, name: String, hasController: Bool)
    case rolloutRestart(context: String, namespace: String, name: String)
    case useKubectlDefault(context: String)

    var id: String {
        switch self {
        case .removeContainer(let id, _): "container:" + id
        case .removeImage(let id, _, _): "image:" + id
        case .removeVolume(let name): "volume:" + name
        case .removeNetwork(let id, _): "network:" + id
        case .deletePod(let context, let namespace, let name, _): "pod:" + context + "/" + namespace + "/" + name
        case .rolloutRestart(let context, let namespace, let name): "rollout:" + context + "/" + namespace + "/" + name
        case .useKubectlDefault(let context): "kubectl-default:" + context
        }
    }

    var isDestructive: Bool {
        if case .useKubectlDefault = self { return false }
        return true
    }
}

struct DockerProjectFiles: Equatable {
    var composeFile: String?
    var hasDockerfile = false

    var isRelevant: Bool { composeFile != nil || hasDockerfile }
}

@Observable
final class ServicesWindowState {
    static let thisProjectGroup = "docker.thisProject"
    static let containersGroup = "docker.containers"
    static let imagesGroup = "docker.images"
    static let volumesGroup = "docker.volumes"
    static let networksGroup = "docker.networks"

    var selection: ServiceSelection?
    var mode: ServiceDetailMode = .logs
    var listFilter = ""
    var logFilter = ""
    var expanded: Set<String> = [ServicesStore.dockerProvider, thisProjectGroup, containersGroup, "kube.pods"]
    var logs: [WorkspaceState.LogMessage] = []
    var logEndedMessage: String?
    var prettyLogIDs: Set<UUID> = []
    var details: DockerContainerDetails?
    var detailsError: String?
    var isLoadingDetails = false
    var confirmation: ServiceConfirmation?
    var stats: DockerStatsSample?
    var isVisible = false
    let kube = KubeWindowState()

    @ObservationIgnored var logBytes = 0
    @ObservationIgnored var logStreamID: Int64 = 0
    @ObservationIgnored var logTargetIDs: [String] = []
    @ObservationIgnored var logRequest = 0
    @ObservationIgnored var detailsKey = ""
    @ObservationIgnored var statsStreamID: Int64 = 0
    @ObservationIgnored var statsTargetID: String?
    @ObservationIgnored var statsRequest = 0
    @ObservationIgnored var kubeSectionInitialized = false
    @ObservationIgnored let token = UUID()

    func isExpanded(_ group: String) -> Bool { expanded.contains(group) }

    func setExpanded(_ group: String, _ on: Bool) {
        if on { expanded.insert(group) } else { expanded.remove(group) }
    }

    func appendLogs(_ messages: [WorkspaceState.LogMessage]) {
        guard !messages.isEmpty else { return }
        var next = logs
        next.append(contentsOf: messages)
        logBytes += messages.reduce(0) { $0 + $1.text.utf8.count }
        var drop = 0
        var droppedBytes = 0
        while next.count - drop > WorkspaceState.maxLogLines || logBytes - droppedBytes > WorkspaceState.maxLogBytes {
            droppedBytes += next[drop].text.utf8.count
            drop += 1
        }
        if drop > 0 {
            next.removeFirst(drop)
            logBytes -= droppedBytes
        }
        logs = next
    }

    func clearLogs() {
        if !logs.isEmpty { logs = [] }
        logBytes = 0
        logEndedMessage = nil
        if !prettyLogIDs.isEmpty { prettyLogIDs = [] }
    }
}

@Observable
final class ServicesStore {
    static let shared = ServicesStore()
    static let dockerProvider = "docker"
    static let kubernetesProvider = "kubernetes"
    static let hideGraceSeconds: TimeInterval = 30
    static let logTail: Int32 = 500
    static let showStoppedKey = "GoLensServicesShowStopped"
    static let composeFileNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]

    var phase: DockerEnginePhase = .idle
    var engine = DockerEngineLink()
    var containers: [DockerContainer] = []
    var images: [DockerImage]?
    var imagesError: String?
    var volumes: [DockerVolume]?
    var volumesError: String?
    var networks: [DockerNetworkSummary]?
    var networksError: String?
    var contexts: DockerContextList?
    var contextsError: String?
    var switchingContext: String?
    var pendingActions: Set<String> = []
    var showStopped: Bool {
        didSet { UserDefaults.standard.set(showStopped, forKey: Self.showStoppedKey) }
    }

    @ObservationIgnored let ffiQueue = DispatchQueue(label: "dev.golens.services", qos: .userInitiated)
    @ObservationIgnored var visibleTokens: Set<UUID> = []
    @ObservationIgnored var hideTimer: DispatchSourceTimer?
    @ObservationIgnored var isConnected = false
    @ObservationIgnored var watchID: Int64 = 0
    @ObservationIgnored var watchKinds: Set<String> = []
    @ObservationIgnored var lastSeq: Int64 = 0
    @ObservationIgnored var connectStartedAt: DispatchTime?
    @ObservationIgnored weak var statusWorkspace: WorkspaceState?
    @ObservationIgnored var windowStates = NSMapTable<WorkspaceState, ServicesWindowState>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    @ObservationIgnored var logOwners: [Int64: ServicesWindowState] = [:]
    @ObservationIgnored var pendingLogBatches: [Int64: [DockerLogBatch]] = [:]
    @ObservationIgnored var statsOwners: [Int64: ServicesWindowState] = [:]
    @ObservationIgnored private var projectFileCache: [String: (files: DockerProjectFiles, checkedAt: Date)] = [:]
    let kube = KubeStore()

    private init() {
        showStopped = UserDefaults.standard.bool(forKey: Self.showStoppedKey)
    }

    func window(for workspace: WorkspaceState) -> ServicesWindowState {
        if let state = windowStates.object(forKey: workspace) { return state }
        let state = ServicesWindowState()
        windowStates.setObject(state, forKey: workspace)
        return state
    }

    var allWindows: [ServicesWindowState] {
        windowStates.objectEnumerator()?.allObjects.compactMap { $0 as? ServicesWindowState } ?? []
    }

    func projectFiles(root: String) -> DockerProjectFiles {
        guard !root.isEmpty else { return DockerProjectFiles() }
        if let cached = projectFileCache[root], Date().timeIntervalSince(cached.checkedAt) < 5 {
            return cached.files
        }
        let fm = FileManager.default
        var files = DockerProjectFiles()
        files.composeFile = Self.composeFileNames
            .map { (root as NSString).appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0) }
        files.hasDockerfile = fm.fileExists(atPath: (root as NSString).appendingPathComponent("Dockerfile"))
        projectFileCache[root] = (files, Date())
        return files
    }

    func isRelevant(for workspace: WorkspaceState) -> Bool {
        projectFiles(root: workspace.activeWorkspacePath).isRelevant || isKubernetesRelevant(for: workspace)
    }

    func composeFile(for workspace: WorkspaceState) -> String? {
        let active = workspace.activeFilePath
        if EcosystemDocumentTools.isDockerComposeFile(active) { return active }
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return nil }
        if let found = projectFiles(root: root).composeFile { return found }
        let runTargets = RunTargetState.shared
        let known = runTargets.compose.file
        if runTargets.loadedRoot == root, known.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: known) {
            return known
        }
        return nil
    }

    func panelAppeared(_ window: ServicesWindowState, workspace: WorkspaceState) {
        window.isVisible = true
        statusWorkspace = workspace
        visibleTokens.insert(window.token)
        hideTimer?.cancel()
        hideTimer = nil
        if !isConnected { connect() } else { widenWatchIfNeeded() }
        if DockerState.shared.status == nil { workspace.refreshDockerStatus() }
        loadContexts()
        kubePanelAppeared(window, workspace: workspace)
        syncStreams(window)
        loadDetailsIfNeeded(window)
    }

    func panelDisappeared(_ window: ServicesWindowState) {
        window.isVisible = false
        visibleTokens.remove(window.token)
        syncStreams(window)
        guard visibleTokens.isEmpty, isConnected || kube.isActive else { return }
        hideTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + Self.hideGraceSeconds, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.visibleTokens.isEmpty else { return }
            self.hideTimer?.cancel()
            self.hideTimer = nil
            self.disconnect()
            self.kubeDeactivate()
        }
        hideTimer = timer
        timer.resume()
    }

    var isAnyPanelVisible: Bool { !visibleTokens.isEmpty }

    private var requestedKinds: [String] {
        var kinds = ["containers"]
        for window in allWindows where window.isVisible {
            if window.isExpanded(ServicesWindowState.imagesGroup) { kinds.append("images") }
            if window.isExpanded(ServicesWindowState.volumesGroup) { kinds.append("volumes") }
        }
        return Array(Set(kinds)).sorted()
    }

    func connect() {
        isConnected = true
        lastSeq = 0
        connectStartedAt = .now()
        switch phase {
        case .running, .reconnecting:
            phase = .reconnecting
        default:
            phase = .connecting
        }
        let kinds = requestedKinds
        watchKinds = Set(kinds)
        let json = jsonText(kinds)
        ffiQueue.async {
            let id = json.withCString { DockerWatchStart($0) }
            DispatchQueue.main.async {
                guard self.isConnected else {
                    self.ffiQueue.async { DockerWatchStop(id) }
                    return
                }
                self.watchID = id
            }
        }
    }

    func disconnect() {
        guard isConnected else { return }
        isConnected = false
        let id = watchID
        watchID = 0
        watchKinds = []
        if id > 0 { ffiQueue.async { DockerWatchStop(id) } }
        if phase == .running || phase == .reconnecting || phase == .connecting { phase = .idle }
    }

    func reconnect() {
        if isConnected { disconnect() }
        connect()
        statusWorkspace?.refreshDockerStatus(force: true)
    }

    func widenWatchIfNeeded() {
        guard isConnected else { return }
        let kinds = Set(requestedKinds)
        guard !kinds.isSubset(of: watchKinds) else { return }
        watchKinds.formUnion(kinds)
        let json = jsonText(Array(watchKinds).sorted())
        ffiQueue.async { _ = json.withCString { DockerWatchStart($0) } }
    }

    static func receive(topic: String, payload: String) {
        let data = Data(payload.utf8)
        switch topic {
        case "services.docker.batch":
            guard let batch = try? JSONDecoder().decode(DockerEventBatch.self, from: data) else { return }
            DispatchQueue.main.async { shared.apply(batch) }
        case "services.docker.logs":
            guard let batch = try? JSONDecoder().decode(DockerLogBatch.self, from: data) else { return }
            let messages = messages(batch)
            DispatchQueue.main.async { shared.applyLogs(batch, messages: messages) }
        case "services.kube.batch":
            guard let batch = try? JSONDecoder().decode(KubeBatch.self, from: data) else { return }
            DispatchQueue.main.async { shared.applyKubeBatch(batch) }
        case "services.kube.logs":
            guard let batch = try? JSONDecoder().decode(KubeLogBatch.self, from: data) else { return }
            let messages = kubeMessages(batch)
            DispatchQueue.main.async { shared.applyKubeLogs(batch, messages: messages) }
        case "services.docker.stats":
            guard let sample = try? JSONDecoder().decode(DockerStatsSample.self, from: data) else { return }
            DispatchQueue.main.async { shared.applyStats(sample) }
        default:
            break
        }
    }

    private func apply(_ batch: DockerEventBatch) {
        guard isConnected else { return }
        if batch.seq > 0 {
            guard batch.seq > lastSeq || batch.reset else { return }
            lastSeq = batch.seq
        }
        engine = batch.engine
        let previousPhase = phase
        switch batch.engine.state {
        case "running":
            phase = .running
        default:
            let reason = batch.engine.reason
            if ["down", "permission", "unsupported", "tooOld"].contains(reason) {
                phase = .unavailable(reason: reason, message: batch.engine.error)
            } else {
                phase = containers.isEmpty && previousPhase != .running ? .unavailable(reason: reason, message: batch.engine.error) : .reconnecting
            }
        }
        if phase.isUnavailable && !previousPhase.isUnavailable {
            statusWorkspace?.refreshDockerStatus(force: true)
        }
        measureLog(String(format: "services batch applied at %.3f reset %d upserts %d removals %d", Date().timeIntervalSince1970, batch.reset ? 1 : 0, batch.upserts.count, batch.removals.count))
        let addsContainers = batch.upserts.contains { upsert in !containers.contains { $0.id == upsert.id } }
        if batch.reset {
            containers = batch.upserts
            if let started = connectStartedAt {
                connectStartedAt = nil
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                let count = batch.upserts.count
                DispatchQueue.main.async {
                    measureLog(String(format: "services first list %.1f ms (%d containers)", ms, count))
                }
            }
        } else if !batch.upserts.isEmpty || !batch.removals.isEmpty {
            var next = containers
            let removed = Set(batch.removals)
            if !removed.isEmpty { next.removeAll { removed.contains($0.id) } }
            for container in batch.upserts {
                if let index = next.firstIndex(where: { $0.id == container.id }) {
                    if next[index] != container { next[index] = container }
                } else {
                    next.append(container)
                }
            }
            next.sort(by: Self.containerOrder)
            if next != containers { containers = next }
        }
        if batch.invalidated.contains("images"), images != nil || isExpandedAnywhere(ServicesWindowState.imagesGroup) { loadList("images") }
        if batch.invalidated.contains("volumes"), volumes != nil || isExpandedAnywhere(ServicesWindowState.volumesGroup) { loadList("volumes") }
        if networks != nil, batch.reset || !batch.removals.isEmpty || addsContainers { loadList("network") }
        let changed = Set(batch.upserts.map(\.id)).union(batch.removals)
        for window in allWindows where window.isVisible {
            syncStreams(window)
            if batch.reset || window.selection.map({ changed.contains($0.id) }) == true {
                loadDetailsIfNeeded(window, force: true)
            }
        }
    }

    func isExpandedAnywhere(_ group: String) -> Bool {
        allWindows.contains { $0.isVisible && $0.isExpanded(group) }
    }

    static func containerOrder(_ a: DockerContainer, _ b: DockerContainer) -> Bool {
        if a.project != b.project { return a.project < b.project }
        if a.service != b.service { return a.service < b.service }
        return a.name < b.name
    }

    static func isThisProject(_ container: DockerContainer, root: String, composeFile: String?) -> Bool {
        guard !container.project.isEmpty else { return false }
        if let composeFile {
            let want = (composeFile as NSString).standardizingPath
            if container.configFiles.contains(where: { ($0 as NSString).standardizingPath == want }) { return true }
        }
        guard !root.isEmpty, !container.projectDir.isEmpty else { return false }
        let ws = (root as NSString).standardizingPath
        let wd = (container.projectDir as NSString).standardizingPath
        return wd == ws || wd.hasPrefix(ws + "/")
    }

    func thisProjectName(root: String, composeFile: String?) -> String? {
        containers.first { Self.isThisProject($0, root: root, composeFile: composeFile) }?.project
    }

    func container(_ id: String) -> DockerContainer? {
        containers.first { $0.id == id }
    }

    func projectContainers(_ project: String) -> [DockerContainer] {
        containers.filter { $0.project == project }
    }
}
