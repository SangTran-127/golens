import AppKit
import Foundation
import GoLensFoundation
import Observation

struct KubeKindStatus: Equatable {
    var state = "connecting"
    var error: KubeError?
    var total = 0
    var truncated = false
}

struct KubeForwardTarget: Equatable, Identifiable {
    let kind: ServiceSelection.Kind
    let name: String
    let ports: [Int]

    var id: String { kind.rawValue + "/" + name }
    var resource: String { (kind == .pod ? "pod/" : "svc/") + name }
}

struct KubeForward: Identifiable, Equatable {
    let sessionID: Int64
    let target: String
    let local: Int
    let remote: Int
    let isRunning: Bool

    var id: Int64 { sessionID }
    var title: String { "localhost:\(local) → \(remote)" }
    var url: URL? { URL(string: "http://localhost:\(local)") }
}

struct KubeIssue: Equatable {
    let title: String
    let message: String
    let error: KubeError
}

struct KubeApplyRequest: Identifiable, Hashable {
    let id = UUID()
    let filePath: String
    let context: String
    let namespace: String
}

struct KubePodScope: Equatable {
    let deployment: String
    let selector: [String: String]
}

@Observable
final class KubeWindowState {
    var details: KubeDetails?
    var detailsError: KubeError?
    var isLoadingDetails = false
    var containerChoice: [String: String] = [:]
    var showsPrevious = false
    var forwardTarget: KubeForwardTarget?
    var podScope: KubePodScope?
    var namespacePrompt = false
    var namespaceDraft = ""

    @ObservationIgnored var detailsKey = ""
    @ObservationIgnored var logStreamID: Int64 = 0
    @ObservationIgnored var logTarget = ""
    @ObservationIgnored var logRequest = 0
}

@Observable
final class KubeStore {
    static let sectionGroup = "kube"
    static let contextKey = "GoLensKubeContext"
    static let namespacesKey = "GoLensKubeNamespaces"
    static let readOnlyKey = "GoLensKubeReadOnlyContexts"
    static let projectsKey = "GoLensKubeProjects"
    static let logTail: Int32 = 500
    static let rowCap = 500

    var contexts: KubeContextList?
    var selectedContext: String {
        didSet { UserDefaults.standard.set(selectedContext, forKey: Self.contextKey) }
    }
    var namespaceByContext: [String: String] {
        didSet { UserDefaults.standard.set(namespaceByContext, forKey: Self.namespacesKey) }
    }
    var namespaces: KubeNamespaceList?
    var isLoadingNamespaces = false
    var pods: [KubePod] = []
    var deployments: [KubeDeployment] = []
    var services: [KubeServiceObject] = []
    var kinds: [KubeKind: KubeKindStatus] = [:]
    var readOnlyContexts: Set<String> {
        didSet { UserDefaults.standard.set(Array(readOnlyContexts).sorted(), forKey: Self.readOnlyKey) }
    }
    var usedProjects: Set<String> {
        didSet { UserDefaults.standard.set(Array(usedProjects).sorted(), forKey: Self.projectsKey) }
    }
    var pending: Set<String> = []
    var settingDefault = false
    var hasWatch = false

    @ObservationIgnored var isActive = false
    @ObservationIgnored var watchID: Int64 = 0
    @ObservationIgnored var watchContext = ""
    @ObservationIgnored var watchNamespace = ""
    @ObservationIgnored var watchKinds: Set<KubeKind> = []
    @ObservationIgnored var watchRequest = 0
    @ObservationIgnored var pendingBatches: [KubeBatch] = []
    @ObservationIgnored var logOwners: [Int64: ServicesWindowState] = [:]
    @ObservationIgnored var pendingLogBatches: [Int64: [KubeLogBatch]] = [:]
    @ObservationIgnored var namespacesLoadedFor = ""
    @ObservationIgnored var kubectlCache: (path: String?, checkedAt: Date)?

    init() {
        let defaults = UserDefaults.standard
        selectedContext = defaults.string(forKey: Self.contextKey) ?? ""
        namespaceByContext = defaults.dictionary(forKey: Self.namespacesKey) as? [String: String] ?? [:]
        readOnlyContexts = Set(defaults.stringArray(forKey: Self.readOnlyKey) ?? [])
        usedProjects = Set(defaults.stringArray(forKey: Self.projectsKey) ?? [])
    }

    var isAvailable: Bool { contexts?.available == true && !(contexts?.contexts.isEmpty ?? true) }

    var context: String { contexts?.resolved(selectedContext) ?? selectedContext }

    var contextInfo: KubeContext? { contexts?.context(context) }

    var namespace: String {
        if let chosen = namespaceByContext[context], !chosen.isEmpty { return chosen }
        return contextInfo?.namespace ?? "default"
    }

    var isReadOnly: Bool { readOnlyContexts.contains(context) }

    func status(_ kind: KubeKind) -> KubeKindStatus? { kinds[kind] }

    var contextIssue: KubeIssue? {
        let errors = kinds.values.compactMap { $0.state == "error" || $0.state == "reconnecting" ? $0.error : nil }
        guard let error = errors.first(where: { !$0.isForbidden && !$0.isNotFound }) else { return nil }
        return KubeIssue(title: Self.issueTitle(error), message: error.message, error: error)
    }

    func kindIssue(_ kind: KubeKind) -> KubeIssue? {
        guard let status = kinds[kind], status.state == "error" || status.state == "reconnecting",
              let error = status.error, error.isForbidden || error.isNotFound else { return nil }
        let title = error.isForbidden ? "Can’t List \(kind.title)" : "Namespace Not Found"
        return KubeIssue(title: title, message: error.message, error: error)
    }

    static func issueTitle(_ error: KubeError) -> String {
        switch error.kind {
        case "unreachable": "Can’t Reach Cluster"
        case "credentialPluginMissing": "Credential Helper Not Found"
        case "credentialPluginFailed": "Couldn’t Sign In"
        case "needsSignIn": "Sign-In Expired"
        case "unauthorized": "Credentials Not Accepted"
        case "forbidden": "Access Denied"
        case "notFound": "Not Found"
        case "config": "Can’t Use This Context"
        default: "Couldn’t Load the Cluster"
        }
    }

    func pod(_ name: String) -> KubePod? { pods.first { $0.name == name } }
    func deployment(_ name: String) -> KubeDeployment? { deployments.first { $0.name == name } }
    func service(_ name: String) -> KubeServiceObject? { services.first { $0.name == name } }

    func clearRows(_ kind: KubeKind? = nil) {
        if kind == nil || kind == .pods, !pods.isEmpty { pods = [] }
        if kind == nil || kind == .deployments, !deployments.isEmpty { deployments = [] }
        if kind == nil || kind == .services, !services.isEmpty { services = [] }
        if let kind { kinds[kind] = nil } else if !kinds.isEmpty { kinds = [:] }
    }
}

enum KubectlLocator {
    static func searchDirectories() -> [String] {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
                 home + "/.rd/bin", home + "/google-cloud-sdk/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func find(_ name: String) -> String? {
        searchDirectories()
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirectories().joined(separator: ":")
        return env
    }
}

enum KubeBridge {
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { FreeGoCString(pointer) }
        return String(cString: pointer)
    }

    static func contexts() -> String? { take(KubeContexts()) }
    static func namespaces(_ context: String) -> String? { take(context.withCString { KubeNamespaces($0) }) }

    static func watchStart(_ context: String, _ namespace: String, _ kinds: [KubeKind]) -> Int64 {
        let json = jsonText(kinds.map(\.rawValue))
        return Int64(context.withCString { c in namespace.withCString { n in json.withCString { k in KubeWatchStart(c, n, k) } } })
    }

    static func watchStop(_ id: Int64) { KubeWatchStop(id) }

    static func details(_ context: String, _ namespace: String, _ kind: String, _ name: String) -> String? {
        take(context.withCString { c in namespace.withCString { n in kind.withCString { k in name.withCString { KubeDetails(c, n, k, $0) } } } })
    }

    static func logsOpen(_ context: String, _ namespace: String, _ pod: String, _ container: String, previous: Bool) -> Int64 {
        Int64(context.withCString { c in namespace.withCString { n in pod.withCString { p in container.withCString { k in
            KubeLogsOpen(c, n, p, k, previous ? 1 : 0, KubeStore.logTail)
        } } } })
    }

    static func logsClose(_ stream: Int64) { KubeLogsClose(stream) }

    static func deletePod(_ context: String, _ namespace: String, _ name: String) -> String? {
        take(context.withCString { c in namespace.withCString { n in name.withCString { KubeDeletePod(c, n, $0) } } })
    }

    static func rolloutRestart(_ context: String, _ namespace: String, _ name: String) -> String? {
        take(context.withCString { c in namespace.withCString { n in name.withCString { KubeRolloutRestart(c, n, $0) } } })
    }
}

enum LocalPortProbe {
    static func isFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    static func suggest(from port: Int) -> Int {
        let start = port < 1024 ? 8000 + port : port
        for candidate in start..<min(start + 200, 65535) where isFree(candidate) {
            return candidate
        }
        return start
    }
}

extension ServicesStore {
    func isKubernetesRelevant(for workspace: WorkspaceState) -> Bool {
        let root = workspace.activeWorkspacePath
        if !root.isEmpty, kube.usedProjects.contains(root) { return true }
        return workspace.commandCapabilities.current.isKubernetesManifest
    }

    func markKubernetesUsed(in workspace: WorkspaceState) {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty, !kube.usedProjects.contains(root) else { return }
        kube.usedProjects.insert(root)
    }

    func kubePanelAppeared(_ window: ServicesWindowState, workspace: WorkspaceState) {
        kube.isActive = true
        if kube.usedProjects.contains(workspace.activeWorkspacePath), !window.kubeSectionInitialized {
            window.setExpanded(KubeStore.sectionGroup, true)
        }
        window.kubeSectionInitialized = true
        loadKubeContexts { self.syncKubeWatch() }
    }

    func kubeDeactivate() {
        kube.isActive = false
        stopKubeWatch()
        for window in allWindows { closeKubeLogs(window) }
    }

    func loadKubeContexts(then done: (() -> Void)? = nil) {
        BackgroundFFI.shared.run("services.kube.contexts") {
            KubeBridge.contexts()
        } deliver: { json in
            let list = BackgroundFFI.decode(KubeContextList.self, from: json)
                ?? KubeContextList(error: KubeError(kind: "config", message: "GoLens couldn’t read the kubeconfig."))
            self.kube.contexts = list
            done?()
        }
    }

    func loadKubeNamespaces(force: Bool = false) {
        let context = kube.context
        guard kube.isAvailable, !context.isEmpty else { return }
        guard force || kube.namespacesLoadedFor != context || kube.namespaces == nil else { return }
        kube.namespacesLoadedFor = context
        kube.isLoadingNamespaces = true
        BackgroundFFI.shared.run("services.kube.namespaces") {
            KubeBridge.namespaces(context)
        } deliver: { json in
            guard self.kube.context == context else { return }
            self.kube.isLoadingNamespaces = false
            self.kube.namespaces = BackgroundFFI.decode(KubeNamespaceList.self, from: json)
                ?? KubeNamespaceList(error: KubeError(kind: "other", message: "GoLens couldn’t read the namespaces."))
        }
    }

    func selectKubeContext(_ name: String) {
        guard name != kube.context else { return }
        kube.selectedContext = name
        kube.namespaces = nil
        kube.namespacesLoadedFor = ""
        resetKubeScope()
    }

    func selectKubeNamespace(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != kube.namespace else { return }
        kube.namespaceByContext[kube.context] = trimmed
        resetKubeScope()
    }

    private func resetKubeScope() {
        stopKubeWatch()
        clearKubeScopeState()
        syncKubeWatch()
    }

    private func clearKubeScopeState() {
        kube.clearRows()
        for window in allWindows {
            closeKubeLogs(window)
            window.kube.details = nil
            window.kube.detailsError = nil
            window.kube.detailsKey = ""
            window.kube.podScope = nil
            window.kube.forwardTarget = nil
            if window.selection?.provider == Self.kubernetesProvider { window.selection = nil }
        }
    }

    func requestedKubeKinds() -> Set<KubeKind> {
        guard kube.isActive, kube.isAvailable else { return [] }
        var kinds = Set<KubeKind>()
        for window in allWindows where window.isVisible && window.isExpanded(KubeStore.sectionGroup) {
            for kind in KubeKind.allCases where window.isExpanded(Self.kubeGroup(kind)) {
                kinds.insert(kind)
            }
        }
        return kinds
    }

    static func kubeGroup(_ kind: KubeKind) -> String { "kube." + kind.rawValue }

    func syncKubeWatch() {
        if kube.isActive, visibleTokens.isEmpty { return }
        let kinds = requestedKubeKinds()
        guard !kinds.isEmpty else {
            stopKubeWatch()
            kube.clearRows()
            return
        }
        let context = kube.context
        let namespace = kube.namespace
        let sameScope = kube.watchContext == context && kube.watchNamespace == namespace && kube.hasWatch
        if sameScope && kinds == kube.watchKinds { return }
        if KubeWatchScope.needsReset(previousContext: kube.watchContext, previousNamespace: kube.watchNamespace, context: context, namespace: namespace) {
            stopKubeWatch()
            clearKubeScopeState()
        }
        for kind in KubeKind.allCases where !kinds.contains(kind) { kube.clearRows(kind) }
        for kind in kinds where !sameScope || !kube.watchKinds.contains(kind) {
            kube.kinds[kind] = KubeKindStatus()
        }
        if !sameScope {
            kube.watchID = 0
            kube.pendingBatches = []
        }
        kube.watchContext = context
        kube.watchNamespace = namespace
        kube.watchKinds = kinds
        kube.hasWatch = true
        kube.watchRequest += 1
        let request = kube.watchRequest
        let ordered = KubeKind.allCases.filter { kinds.contains($0) }
        loadKubeNamespaces()
        ffiQueue.async {
            let id = KubeBridge.watchStart(context, namespace, ordered)
            DispatchQueue.main.async {
                guard self.kube.hasWatch, self.kube.watchContext == context, self.kube.watchNamespace == namespace else {
                    if id > 0, self.kube.watchID != id { self.ffiQueue.async { KubeBridge.watchStop(id) } }
                    return
                }
                guard request == self.kube.watchRequest || self.kube.watchID == 0 else { return }
                self.kube.watchID = id
                let buffered = self.kube.pendingBatches.filter { $0.watch == id }
                self.kube.pendingBatches = []
                for batch in buffered { self.applyKubeBatch(batch) }
            }
        }
    }

    func stopKubeWatch() {
        guard kube.hasWatch else { return }
        kube.hasWatch = false
        kube.watchKinds = []
        kube.watchRequest += 1
        kube.pendingBatches = []
        let id = kube.watchID
        kube.watchID = 0
        if id > 0 { ffiQueue.async { KubeBridge.watchStop(id) } }
    }

    func retryKube() {
        loadKubeContexts {
            self.loadKubeNamespaces(force: true)
            self.stopKubeWatch()
            self.syncKubeWatch()
            for window in self.allWindows where window.isVisible { self.loadKubeDetailsIfNeeded(window, force: true) }
        }
    }

    func applyKubeBatch(_ batch: KubeBatch) {
        guard kube.hasWatch, let kind = batch.kind else { return }
        guard kube.watchID != 0 else {
            if kube.pendingBatches.count < 60 { kube.pendingBatches.append(batch) }
            return
        }
        guard batch.watch == kube.watchID, kube.watchKinds.contains(kind) else { return }
        var status = kube.kinds[kind] ?? KubeKindStatus()
        status.state = batch.state
        status.error = batch.error
        if batch.state == "live" || batch.reset || !batch.pods.isEmpty || !batch.deployments.isEmpty || !batch.services.isEmpty {
            status.total = batch.total
            status.truncated = batch.truncated
        }
        if kube.kinds[kind] != status { kube.kinds[kind] = status }
        switch kind {
        case .pods:
            let next = KubeRows.merge(kube.pods, upserts: batch.pods, removals: batch.removals, reset: batch.reset)
            if next != kube.pods { kube.pods = next }
        case .deployments:
            let next = KubeRows.merge(kube.deployments, upserts: batch.deployments, removals: batch.removals, reset: batch.reset)
            if next != kube.deployments { kube.deployments = next }
        case .services:
            let next = KubeRows.merge(kube.services, upserts: batch.services, removals: batch.removals, reset: batch.reset)
            if next != kube.services { kube.services = next }
        }
        if kind == .pods {
            for window in allWindows where window.isVisible { syncKubeLogs(window) }
        }
    }

    func kubeContainer(for pod: KubePod, in window: ServicesWindowState) -> String {
        if let chosen = window.kube.containerChoice[pod.name], pod.containers.contains(chosen) { return chosen }
        return pod.containers.count > 1 ? pod.containers[0] : ""
    }

    func syncKubeLogs(_ window: ServicesWindowState) {
        var target = ""
        var pod: KubePod?
        if window.isVisible, window.mode == .logs, let selection = window.selection,
           selection.provider == Self.kubernetesProvider, selection.kind == .pod, let found = kube.pod(selection.id) {
            pod = found
            target = [kube.context, kube.namespace, found.name, kubeContainer(for: found, in: window), window.kube.showsPrevious ? "1" : "0"].joined(separator: "\u{1F}")
        }
        guard target != window.kube.logTarget else { return }
        let opening = !target.isEmpty
        closeKubeLogs(window)
        window.kube.logTarget = target
        guard opening, let pod else { return }
        window.clearLogs()
        window.kube.logRequest += 1
        let request = window.kube.logRequest
        let context = kube.context
        let namespace = kube.namespace
        let container = kubeContainer(for: pod, in: window)
        let previous = window.kube.showsPrevious
        ffiQueue.async {
            let stream = KubeBridge.logsOpen(context, namespace, pod.name, container, previous: previous)
            DispatchQueue.main.async {
                guard window.kube.logRequest == request, window.kube.logTarget == target else {
                    if stream > 0 { self.ffiQueue.async { KubeBridge.logsClose(stream) } }
                    return
                }
                guard stream > 0 else {
                    window.logEndedMessage = "GoLens couldn’t open the logs."
                    return
                }
                window.kube.logStreamID = stream
                self.kube.logOwners[stream] = window
                for batch in self.kube.pendingLogBatches.removeValue(forKey: stream) ?? [] {
                    self.applyKubeLogs(batch, messages: Self.kubeMessages(batch))
                }
                self.kube.pendingLogBatches = self.kube.pendingLogBatches.filter { $0.key > stream }
            }
        }
    }

    func closeKubeLogs(_ window: ServicesWindowState) {
        window.kube.logRequest += 1
        window.kube.logTarget = ""
        let stream = window.kube.logStreamID
        window.kube.logStreamID = 0
        guard stream > 0 else { return }
        kube.logOwners[stream] = nil
        ffiQueue.async { KubeBridge.logsClose(stream) }
    }

    func reopenKubeLogs(_ window: ServicesWindowState) {
        closeKubeLogs(window)
        syncKubeLogs(window)
    }

    static func kubeMessages(_ batch: KubeLogBatch) -> [WorkspaceState.LogMessage] {
        batch.lines.map { WorkspaceState.consoleMessage($0.prefix.isEmpty ? $0.text : $0.prefix + " | " + $0.text, isStderr: $0.stderr) }
    }

    func applyKubeLogs(_ batch: KubeLogBatch, messages: [WorkspaceState.LogMessage]) {
        guard let window = kube.logOwners[batch.stream] else {
            let awaiting = allWindows.contains { $0.kube.logStreamID == 0 && !$0.kube.logTarget.isEmpty }
            if batch.stream > 0, awaiting, (kube.pendingLogBatches[batch.stream]?.count ?? 0) < 20 {
                kube.pendingLogBatches[batch.stream, default: []].append(batch)
            }
            return
        }
        var lines = messages
        if batch.dropped > 0 {
            lines.insert(WorkspaceState.LogMessage(text: "… \(UserMessage.quantity(batch.dropped, "line")) skipped to keep up with the output."), at: 0)
        }
        window.appendLogs(lines)
        guard batch.closed else { return }
        kube.logOwners[batch.stream] = nil
        window.kube.logStreamID = 0
        switch batch.reason {
        case "ended" where window.kube.showsPrevious:
            window.logEndedMessage = nil
        case "ended":
            window.logEndedMessage = "The pod finished, so its logs ended."
        case "removed":
            window.logEndedMessage = "The pod was deleted, so its logs ended."
        default:
            window.logEndedMessage = batch.error?.message ?? "The log stream stopped."
        }
    }

    func showPreviousLogs(_ on: Bool, in window: ServicesWindowState) {
        guard window.kube.showsPrevious != on || window.mode != .logs else { return }
        window.kube.showsPrevious = on
        window.mode = .logs
        syncStreams(window)
    }

    func chooseContainer(_ container: String, for pod: String, in window: ServicesWindowState) {
        window.kube.containerChoice[pod] = container
        syncKubeLogs(window)
    }

    func loadKubeDetailsIfNeeded(_ window: ServicesWindowState, force: Bool = false) {
        guard window.isVisible, window.mode == .details, let selection = window.selection,
              selection.provider == Self.kubernetesProvider else { return }
        let kind: String
        switch selection.kind {
        case .pod: kind = "pods"
        case .deployment: kind = "deployments"
        case .kubeService: kind = "services"
        default: return
        }
        let context = kube.context
        let namespace = kube.namespace
        let key = [context, namespace, kind, selection.id].joined(separator: "\u{1F}")
        let state = window.kube
        guard force || state.detailsKey != key || (state.details == nil && state.detailsError == nil) else { return }
        if state.detailsKey != key {
            state.details = nil
            state.detailsError = nil
        }
        state.detailsKey = key
        state.isLoadingDetails = true
        let name = selection.id
        BackgroundFFI.shared.run("services.kube.details." + String(describing: ObjectIdentifier(window))) {
            BackgroundFFI.decode(KubeDetails.self, from: KubeBridge.details(context, namespace, kind, name))
                ?? KubeDetails(error: KubeError(kind: "other", message: "GoLens couldn’t read the details."))
        } deliver: { details in
            guard state.detailsKey == key else { return }
            state.isLoadingDetails = false
            if let error = details.error {
                state.detailsError = error
            } else {
                if state.details != details { state.details = details }
                state.detailsError = nil
            }
        }
    }

    func kubeActionBlocker(mutating: Bool) -> String? {
        if mutating && kube.isReadOnly {
            return "“\(kube.context)” is read-only in GoLens. Turn off Read-Only for This Context to change it."
        }
        return nil
    }

    func requestDeletePod(_ name: String, in window: ServicesWindowState, from workspace: WorkspaceState) {
        if let reason = kubeActionBlocker(mutating: true) {
            workspace.presentCommandFeedback(reason, title: "Context Is Read-Only", tone: .info)
            return
        }
        let hasController = kube.pod(name)?.hasController ?? false
        workspace.showServicesPanel()
        window.confirmation = .deletePod(context: kube.context, namespace: kube.namespace, name: name, hasController: hasController)
    }

    func requestRolloutRestart(_ name: String, in window: ServicesWindowState, from workspace: WorkspaceState) {
        if let reason = kubeActionBlocker(mutating: true) {
            workspace.presentCommandFeedback(reason, title: "Context Is Read-Only", tone: .info)
            return
        }
        workspace.showServicesPanel()
        window.confirmation = .rolloutRestart(context: kube.context, namespace: kube.namespace, name: name)
    }

    func requestKubeDelete(_ selection: ServiceSelection, in window: ServicesWindowState, from workspace: WorkspaceState) {
        guard selection.kind == .pod else { return }
        requestDeletePod(selection.id, in: window, from: workspace)
    }

    func requestUseAsKubectlDefault(in window: ServicesWindowState, from workspace: WorkspaceState) {
        let context = kube.context
        guard !context.isEmpty else { return }
        workspace.showServicesPanel()
        window.confirmation = .useKubectlDefault(context: context)
    }

    func confirmKube(_ confirmation: ServiceConfirmation, from workspace: WorkspaceState) {
        switch confirmation {
        case .deletePod(let context, let namespace, let name, _):
            runKubeAction("pod:" + name, title: "Couldn’t Delete “\(name)”", from: workspace) {
                KubeBridge.deletePod(context, namespace, name)
            }
        case .rolloutRestart(let context, let namespace, let name):
            runKubeAction("deployment:" + name, title: "Couldn’t Restart “\(name)”", from: workspace) {
                KubeBridge.rolloutRestart(context, namespace, name)
            }
        case .useKubectlDefault(let context):
            useAsKubectlDefault(context, from: workspace)
        default:
            break
        }
    }

    private func runKubeAction(_ key: String, title: String, from workspace: WorkspaceState, _ call: @escaping () -> String?) {
        guard !kube.pending.contains(key) else { return }
        kube.pending.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BackgroundFFI.decode(KubeActionResult.self, from: call())
                ?? KubeActionResult(error: KubeError(kind: "other", message: "The cluster gave no answer. Check the connection, then try again."))
            DispatchQueue.main.async {
                self.kube.pending.remove(key)
                guard !result.ok else { return }
                workspace.presentCommandFeedback(result.error?.message ?? "The cluster gave no reason.", title: title, tone: .failure)
            }
        }
    }

    func toggleReadOnly() {
        let context = kube.context
        guard !context.isEmpty else { return }
        if kube.readOnlyContexts.contains(context) {
            kube.readOnlyContexts.remove(context)
        } else {
            kube.readOnlyContexts.insert(context)
        }
    }

    func useAsKubectlDefault(_ context: String, from workspace: WorkspaceState) {
        guard let kubectl = kubectlPath() else {
            workspace.presentCommandFeedback("Use as kubectl Default needs the kubectl command. Install it with Homebrew (brew install kubectl).", title: "kubectl Not Found", tone: .info)
            return
        }
        kube.settingDefault = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kubectl)
            process.arguments = ["config", "use-context", context]
            process.environment = KubectlLocator.environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            var message = ""
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if message.isEmpty { message = "kubectl couldn’t change the current context." }
                }
            } catch {
                message = "GoLens couldn’t run kubectl."
            }
            DispatchQueue.main.async {
                self.kube.settingDefault = false
                if message.isEmpty {
                    workspace.presentCommandFeedback("Terminals and kubectl now use “\(context)”.", title: "kubectl Default Changed", tone: .success)
                } else {
                    workspace.presentCommandFeedback(message, title: "Couldn’t Change the kubectl Default", tone: .failure)
                }
                self.loadKubeContexts()
            }
        }
    }

    func kubectlPath() -> String? {
        if let cache = kube.kubectlCache, Date().timeIntervalSince(cache.checkedAt) < 5 { return cache.path }
        let path = KubectlLocator.find("kubectl")
        kube.kubectlCache = (path, Date())
        return path
    }

    func kubeShellUnavailableReason(_ pod: KubePod) -> String? {
        if kubectlPath() == nil { return "Open Shell needs the kubectl command. Install it with Homebrew (brew install kubectl)." }
        if !pod.isRunning { return "“\(pod.name)” isn’t running, so it has no shell to open." }
        return nil
    }

    func openKubeShell(_ pod: KubePod, in window: ServicesWindowState, workspace: WorkspaceState) {
        if let reason = kubeShellUnavailableReason(pod) {
            workspace.presentCommandFeedback(reason, title: "Can’t Open a Shell", tone: .info)
            return
        }
        let argv = KubeCommandLine.exec(kubectl: kubectlPath() ?? "kubectl", context: kube.context, namespace: kube.namespace,
                                        pod: pod.name, container: kubeContainer(for: pod, in: window))
        workspace.openCommandTerminal(title: "\(pod.name) (pod)", argv: argv)
    }

    func forwardUnavailableReason(ports: [Int]) -> String? {
        if kubectlPath() == nil { return "Port Forward needs the kubectl command. Install it with Homebrew (brew install kubectl)." }
        if ports.isEmpty { return "It declares no TCP port to forward." }
        return nil
    }

    func podForwardTarget(_ pod: KubePod) -> KubeForwardTarget {
        KubeForwardTarget(kind: .pod, name: pod.name, ports: pod.tcpPorts)
    }

    func serviceForwardTarget(_ service: KubeServiceObject) -> KubeForwardTarget {
        KubeForwardTarget(kind: .kubeService, name: service.name, ports: service.tcpPorts)
    }

    func requestForward(_ target: KubeForwardTarget, in window: ServicesWindowState, workspace: WorkspaceState) {
        if let reason = forwardUnavailableReason(ports: target.ports) {
            workspace.presentCommandFeedback(reason, title: "Can’t Forward a Port", tone: .info)
            return
        }
        ServicesPanelContent.select(.kube(target.kind, target.name), in: window)
        workspace.showServicesPanel()
        DispatchQueue.main.async { window.kube.forwardTarget = target }
    }

    func startForward(_ target: KubeForwardTarget, local: Int, remote: Int, workspace: WorkspaceState) {
        guard let kubectl = kubectlPath() else { return }
        let context = kube.context
        let namespace = kube.namespace
        let argv = KubeCommandLine.portForward(kubectl: kubectl, context: context, namespace: namespace, target: target.resource, local: local, remote: remote)
        let dir = workspace.activeWorkspacePath.isEmpty ? NSHomeDirectory() : workspace.activeWorkspacePath
        workspace.runExternalCommand(
            argv,
            in: dir,
            key: KubeCommandLine.forwardKey(context: context, namespace: namespace, target: target.resource, local: local, remote: remote),
            title: KubeCommandLine.forwardTitle(target: target.resource, local: local, remote: remote),
            savesEdited: false,
            revealsConsole: false
        )
    }

    func forwards(for target: String, in workspace: WorkspaceState) -> [KubeForward] {
        workspace.runSessions.compactMap { session in
            guard let key = KubeCommandLine.parseForwardKey(session.key), key.context == kube.context,
                  key.namespace == kube.namespace, key.target == target else { return nil }
            return KubeForward(sessionID: session.id, target: key.target, local: key.local, remote: key.remote, isRunning: session.isRunning)
        }
    }

    func applyUnavailableReason(for path: String) -> String? {
        if kubectlPath() == nil { return "Apply to Cluster needs the kubectl command. Install it with Homebrew (brew install kubectl)." }
        if !kube.isAvailable { return "GoLens found no kubeconfig. Add a cluster with kubectl first." }
        return nil
    }

    func presentApply(in workspace: WorkspaceState) {
        let path = workspace.activeFilePath
        let text = workspace.documents[path]?.storage.string ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard ActiveCommandCapabilities.isYAMLFile(path), KubeManifest.isManifest(text) else {
            workspace.presentCommandFeedback("Open a Kubernetes manifest (a YAML file with apiVersion and kind) to apply it.", title: "Not a Kubernetes Manifest", tone: .info)
            return
        }
        let show = {
            if let reason = self.applyUnavailableReason(for: path) {
                workspace.presentCommandFeedback(reason, title: "Can’t Apply to Cluster", tone: .info)
                return
            }
            workspace.router.activeSheet = .kubernetesApply(KubeApplyRequest(filePath: path, context: self.kube.context, namespace: self.kube.namespace))
        }
        if kube.contexts == nil { loadKubeContexts(then: show) } else { show() }
    }

    func selectedKubePod(in workspace: WorkspaceState) -> KubePod? {
        guard let selection = window(for: workspace).selection, selection.provider == Self.kubernetesProvider, selection.kind == .pod else { return nil }
        return kube.pod(selection.id)
    }

    func selectedKubeDeployment(in workspace: WorkspaceState) -> KubeDeployment? {
        guard let selection = window(for: workspace).selection, selection.provider == Self.kubernetesProvider, selection.kind == .deployment else { return nil }
        return kube.deployment(selection.id)
    }

    func selectedForwardTarget(in workspace: WorkspaceState) -> KubeForwardTarget? {
        guard let selection = window(for: workspace).selection, selection.provider == Self.kubernetesProvider else { return nil }
        switch selection.kind {
        case .pod: return kube.pod(selection.id).map(podForwardTarget)
        case .kubeService: return kube.service(selection.id).map(serviceForwardTarget)
        default: return nil
        }
    }

    func showKubernetes(in workspace: WorkspaceState) {
        let window = window(for: workspace)
        window.setExpanded(KubeStore.sectionGroup, true)
        window.kubeSectionInitialized = true
        markKubernetesUsed(in: workspace)
        workspace.showServicesPanel()
        if kube.contexts == nil { loadKubeContexts { self.syncKubeWatch() } } else { syncKubeWatch() }
    }

    func showPods(of deployment: KubeDeployment, in window: ServicesWindowState) {
        window.kube.podScope = KubePodScope(deployment: deployment.name, selector: deployment.selector)
        window.setExpanded(KubeStore.sectionGroup, true)
        window.setExpanded(Self.kubeGroup(.pods), true)
        syncKubeWatch()
    }
}
