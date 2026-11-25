import Foundation

public struct KubeError: Decodable, Hashable, Sendable {
    public var kind = "other"
    public var message = ""
    public var server = ""
    public var plugin = ""
    public var verb = ""
    public var resource = ""
    public var namespace = ""
    public var signInCommand: [String] = []

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        kind = c.dockerValue("kind", "other")
        message = c.dockerValue("message", "")
        server = c.dockerValue("server", "")
        plugin = c.dockerValue("plugin", "")
        verb = c.dockerValue("verb", "")
        resource = c.dockerValue("resource", "")
        namespace = c.dockerValue("namespace", "")
        signInCommand = c.dockerValue("signInCommand", [String]())
    }

    public var isForbidden: Bool { kind == "forbidden" }
    public var isNotFound: Bool { kind == "notFound" }
}

public struct KubeContext: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var cluster = ""
    public var user = ""
    public var namespace = "default"
    public var server = ""
    public var local = false
    public var current = false
    public var authPlugin = ""

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        cluster = c.dockerValue("cluster", "")
        user = c.dockerValue("user", "")
        namespace = c.dockerValue("namespace", "")
        if namespace.isEmpty { namespace = "default" }
        server = c.dockerValue("server", "")
        local = c.dockerValue("local", false)
        current = c.dockerValue("current", false)
        authPlugin = c.dockerValue("authPlugin", "")
    }
}

public struct KubeContextList: Decodable, Sendable {
    public var available = false
    public var current = ""
    public var contexts: [KubeContext] = []
    public var error: KubeError?

    public init(error: KubeError?) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        available = c.dockerValue("available", false)
        current = c.dockerValue("current", "")
        contexts = c.dockerValue("contexts", [KubeContext]())
        error = c.dockerValue("error", KubeError?.none)
    }

    public func context(_ name: String) -> KubeContext? {
        contexts.first { $0.name == name }
    }

    public func resolved(_ name: String) -> String {
        if !name.isEmpty, context(name) != nil { return name }
        if !current.isEmpty, context(current) != nil { return current }
        return contexts.first?.name ?? ""
    }
}

public struct KubeNamespace: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var phase = ""

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        phase = c.dockerValue("phase", "")
    }
}

public struct KubeNamespaceList: Decodable, Sendable {
    public var context = ""
    public var defaultNamespace = "default"
    public var namespaces: [KubeNamespace] = []
    public var error: KubeError?

    public init(error: KubeError) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        context = c.dockerValue("context", "")
        defaultNamespace = c.dockerValue("defaultNamespace", "")
        if defaultNamespace.isEmpty { defaultNamespace = "default" }
        namespaces = c.dockerValue("namespaces", [KubeNamespace]())
        error = c.dockerValue("error", KubeError?.none)
    }
}

public struct KubePort: Decodable, Hashable, Sendable {
    public var name = ""
    public var port = 0
    public var proto = "TCP"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        port = c.dockerValue("port", 0)
        proto = c.dockerValue("protocol", "TCP")
    }

    public var isTCP: Bool { proto.isEmpty || proto.uppercased() == "TCP" }
}

public struct KubeOwner: Decodable, Hashable, Sendable {
    public var kind = ""
    public var name = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        kind = c.dockerValue("kind", "")
        name = c.dockerValue("name", "")
    }
}

public enum KubeTone: String, Sendable {
    case ok, warning, failure, neutral

    public init(raw: String) {
        self = KubeTone(rawValue: raw) ?? .neutral
    }
}

public enum KubeAge {
    public static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    public static func short(since created: String, now: Date = Date()) -> String {
        guard let date = date(created) else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 86_400 ? [.days] : seconds >= 3600 ? [.hours] : seconds >= 60 ? [.minutes] : [.seconds]
        return Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .narrow, maximumUnitCount: 1, fractionalPart: .hide(rounded: .down))
                .locale(Locale(identifier: "en_US"))
        )
    }
}

public struct KubePod: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var namespace = ""
    public var phase = ""
    public var status = ""
    public var tone = KubeTone.neutral
    public var ready = 0
    public var total = 0
    public var restarts = 0
    public var created = ""
    public var node = ""
    public var containers: [String] = []
    public var ports: [KubePort] = []
    public var labels: [String: String] = [:]
    public var owner: KubeOwner?

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        namespace = c.dockerValue("namespace", "")
        phase = c.dockerValue("phase", "")
        status = c.dockerValue("status", "")
        tone = KubeTone(raw: c.dockerValue("tone", ""))
        ready = c.dockerValue("ready", 0)
        total = c.dockerValue("total", 0)
        restarts = c.dockerValue("restarts", 0)
        created = c.dockerValue("created", "")
        node = c.dockerValue("node", "")
        containers = c.dockerValue("containers", [String]())
        ports = c.dockerValue("ports", [KubePort]())
        labels = c.dockerValue("labels", [String: String]())
        owner = c.dockerValue("owner", KubeOwner?.none)
    }

    public var isRunning: Bool { phase == "Running" && status != "Terminating" }
    public var hasController: Bool { owner != nil }
    public var tcpPorts: [Int] { Array(Set(ports.filter(\.isTCP).map(\.port).filter { $0 > 0 })).sorted() }

    public func restartsText() -> String {
        "\(restarts) \(restarts == 1 ? "restart" : "restarts")"
    }

    public func detail(now: Date = Date()) -> String {
        var parts: [String] = []
        if tone != .failure { parts.append("\(ready)/\(total) ready") }
        if restarts > 0 || isRunning || tone == .failure { parts.append(restartsText()) }
        if tone != .failure {
            let age = KubeAge.short(since: created, now: now)
            if !age.isEmpty { parts.append(age) }
        }
        return parts.joined(separator: " · ")
    }
}

public struct KubeDeployment: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var namespace = ""
    public var desired = 0
    public var ready = 0
    public var updated = 0
    public var available = 0
    public var paused = false
    public var tone = KubeTone.neutral
    public var created = ""
    public var selector: [String: String] = [:]

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        namespace = c.dockerValue("namespace", "")
        desired = c.dockerValue("desired", 0)
        ready = c.dockerValue("ready", 0)
        updated = c.dockerValue("updated", 0)
        available = c.dockerValue("available", 0)
        paused = c.dockerValue("paused", false)
        tone = KubeTone(raw: c.dockerValue("tone", ""))
        created = c.dockerValue("created", "")
        selector = c.dockerValue("selector", [String: String]())
    }

    public var readyText: String { "\(ready)/\(desired) ready" + (paused ? " · Paused" : "") }

    public func selects(_ pod: KubePod) -> Bool {
        KubeLabels.matches(selector, pod.labels)
    }
}

public struct KubeServicePort: Decodable, Hashable, Sendable {
    public var name = ""
    public var port = 0
    public var targetPort = ""
    public var proto = "TCP"
    public var nodePort = 0

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        port = c.dockerValue("port", 0)
        if let text = c.dockerValue("targetPort", String?.none) {
            targetPort = text
        } else if let number = c.dockerValue("targetPort", Int?.none) {
            targetPort = String(number)
        }
        proto = c.dockerValue("protocol", "TCP")
        nodePort = c.dockerValue("nodePort", 0)
    }

    public var isTCP: Bool { proto.isEmpty || proto.uppercased() == "TCP" }

    public var text: String {
        var out = String(port)
        if !targetPort.isEmpty && targetPort != String(port) { out += "→" + targetPort }
        if !isTCP { out += "/" + proto }
        return out
    }
}

public struct KubeServiceObject: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var namespace = ""
    public var type = ""
    public var clusterIP = ""
    public var ports: [KubeServicePort] = []
    public var created = ""
    public var selector: [String: String] = [:]

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        namespace = c.dockerValue("namespace", "")
        type = c.dockerValue("type", "")
        clusterIP = c.dockerValue("clusterIP", "")
        ports = c.dockerValue("ports", [KubeServicePort]())
        created = c.dockerValue("created", "")
        selector = c.dockerValue("selector", [String: String]())
    }

    public var portsText: String { ports.map(\.text).joined(separator: ", ") }
    public var tcpPorts: [Int] { ports.filter { $0.isTCP && $0.port > 0 }.map(\.port) }
    public var canForward: Bool { !tcpPorts.isEmpty && !selector.isEmpty }
}

public enum KubeLabels {
    public static func matches(_ selector: [String: String], _ labels: [String: String]) -> Bool {
        guard !selector.isEmpty else { return false }
        return selector.allSatisfy { labels[$0.key] == $0.value }
    }
}

public enum KubeKind: String, CaseIterable, Sendable {
    case pods, deployments, services

    public init?(loose: String) {
        switch loose.lowercased() {
        case "pods", "pod": self = .pods
        case "deployments", "deployment": self = .deployments
        case "services", "service": self = .services
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .services: "Services"
        }
    }

    public var noun: String {
        switch self {
        case .pods: "pod"
        case .deployments: "deployment"
        case .services: "service"
        }
    }
}

public struct KubeBatch: Decodable, Sendable {
    public var seq: Int64 = 0
    public var watch: Int64 = 0
    public var context = ""
    public var namespace = ""
    public var kind: KubeKind?
    public var state = "live"
    public var reset = false
    public var pods: [KubePod] = []
    public var deployments: [KubeDeployment] = []
    public var services: [KubeServiceObject] = []
    public var removals: [String] = []
    public var total = 0
    public var truncated = false
    public var error: KubeError?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        seq = c.dockerValue("seq", Int64(0))
        watch = c.dockerValue("watch", Int64(0))
        context = c.dockerValue("context", "")
        namespace = c.dockerValue("namespace", "")
        kind = KubeKind(loose: c.dockerValue("kind", ""))
        state = c.dockerValue("state", "live")
        reset = c.dockerValue("reset", false)
        switch kind {
        case .pods: pods = c.dockerValue("upserts", [KubePod]())
        case .deployments: deployments = c.dockerValue("upserts", [KubeDeployment]())
        case .services: services = c.dockerValue("upserts", [KubeServiceObject]())
        case nil: break
        }
        removals = c.dockerValue("removals", [String]())
        total = c.dockerValue("total", 0)
        truncated = c.dockerValue("truncated", false)
        error = c.dockerValue("error", KubeError?.none)
    }

    public var upsertNames: [String] {
        switch kind {
        case .pods: pods.map(\.name)
        case .deployments: deployments.map(\.name)
        case .services: services.map(\.name)
        case nil: []
        }
    }
}

public enum KubeRows {
    public static func merge<T: Identifiable & Equatable>(_ rows: [T], upserts: [T], removals: [String], reset: Bool) -> [T] where T.ID == String {
        var next: [T]
        if reset {
            next = upserts
        } else {
            next = rows
            let removed = Set(removals)
            if !removed.isEmpty { next.removeAll { removed.contains($0.id) } }
            for row in upserts {
                if let index = next.firstIndex(where: { $0.id == row.id }) {
                    next[index] = row
                } else {
                    next.append(row)
                }
            }
        }
        next.sort { $0.id < $1.id }
        return next
    }

    public static func capNote(shown: Int, total: Int, truncated: Bool) -> String? {
        guard truncated, total > shown else { return nil }
        return "Showing \(shown.formatted(.number.locale(Locale(identifier: "en_US")))) of \(total.formatted(.number.locale(Locale(identifier: "en_US")))). Filter to narrow."
    }
}

public struct KubeLogLine: Decodable, Sendable {
    public var text = ""
    public var stderr = false
    public var prefix = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        text = c.dockerValue("text", "")
        stderr = c.dockerValue("stderr", false)
        prefix = c.dockerValue("prefix", "")
    }
}

public struct KubeLogBatch: Decodable, Sendable {
    public var stream: Int64 = 0
    public var lines: [KubeLogLine] = []
    public var dropped = 0
    public var closed = false
    public var reason = ""
    public var error: KubeError?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        stream = c.dockerValue("stream", Int64(0))
        lines = c.dockerValue("lines", [KubeLogLine]())
        dropped = c.dockerValue("dropped", 0)
        closed = c.dockerValue("closed", false)
        reason = c.dockerValue("reason", "")
        error = c.dockerValue("error", KubeError?.none)
    }
}

public struct KubeActionResult: Decodable, Sendable {
    public var ok = false
    public var error: KubeError?

    public init(error: KubeError) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        ok = c.dockerValue("ok", false)
        error = c.dockerValue("error", KubeError?.none)
    }
}

public struct KubeDetailItem: Decodable, Hashable, Sendable {
    public var label = ""
    public var value = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        label = c.dockerValue("label", "")
        value = c.dockerValue("value", "")
    }
}

public struct KubeTermination: Decodable, Hashable, Sendable {
    public var reason = ""
    public var exitCode = 0
    public var finishedAt = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        reason = c.dockerValue("reason", "")
        exitCode = c.dockerValue("exitCode", 0)
        finishedAt = c.dockerValue("finishedAt", "")
    }
}

public struct KubeContainerDetail: Decodable, Hashable, Sendable {
    public var name = ""
    public var image = ""
    public var state = ""
    public var reason = ""
    public var startedAt = ""
    public var ready = false
    public var restarts = 0
    public var lastTermination: KubeTermination?
    public var requests: [String: String] = [:]
    public var limits: [String: String] = [:]
    public var ports: [KubePort] = []

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        image = c.dockerValue("image", "")
        state = c.dockerValue("state", "")
        reason = c.dockerValue("reason", "")
        startedAt = c.dockerValue("startedAt", "")
        ready = c.dockerValue("ready", false)
        restarts = c.dockerValue("restarts", 0)
        lastTermination = c.dockerValue("lastTermination", KubeTermination?.none)
        requests = c.dockerValue("requests", [String: String]())
        limits = c.dockerValue("limits", [String: String]())
        ports = c.dockerValue("ports", [KubePort]())
    }

    public static func resources(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

public struct KubeCondition: Decodable, Hashable, Sendable {
    public var type = ""
    public var status = ""
    public var reason = ""
    public var message = ""
    public var lastTransition = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        type = c.dockerValue("type", "")
        status = c.dockerValue("status", "")
        reason = c.dockerValue("reason", "")
        message = c.dockerValue("message", "")
        lastTransition = c.dockerValue("lastTransition", "")
    }
}

public struct KubeEvent: Decodable, Hashable, Sendable {
    public var type = ""
    public var reason = ""
    public var message = ""
    public var count = 0
    public var lastSeen = ""
    public var source = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        type = c.dockerValue("type", "")
        reason = c.dockerValue("reason", "")
        message = c.dockerValue("message", "")
        count = c.dockerValue("count", 0)
        lastSeen = c.dockerValue("lastSeen", "")
        source = c.dockerValue("source", "")
    }

    public var isWarning: Bool { type == "Warning" }
}

public struct KubeDetails: Decodable, Hashable, Sendable {
    public var context = ""
    public var namespace = ""
    public var kind = ""
    public var name = ""
    public var created = ""
    public var labels: [String: String] = [:]
    public var overview: [KubeDetailItem] = []
    public var containers: [KubeContainerDetail] = []
    public var conditions: [KubeCondition] = []
    public var events: [KubeEvent] = []
    public var eventsError: KubeError?
    public var error: KubeError?

    public init(error: KubeError) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        context = c.dockerValue("context", "")
        namespace = c.dockerValue("namespace", "")
        kind = c.dockerValue("kind", "")
        name = c.dockerValue("name", "")
        created = c.dockerValue("created", "")
        labels = c.dockerValue("labels", [String: String]())
        overview = c.dockerValue("overview", [KubeDetailItem]())
        containers = c.dockerValue("containers", [KubeContainerDetail]())
        conditions = c.dockerValue("conditions", [KubeCondition]())
        events = c.dockerValue("events", [KubeEvent]())
        eventsError = c.dockerValue("eventsError", KubeError?.none)
        error = c.dockerValue("error", KubeError?.none)
    }
}

public enum KubeWatchScope {
    public static func needsReset(previousContext: String, previousNamespace: String, context: String, namespace: String) -> Bool {
        guard !previousContext.isEmpty else { return false }
        return previousContext != context || previousNamespace != namespace
    }
}

public enum KubeManifest {
    public static let sniffLength = 4096

    public static func isManifest(_ text: String) -> Bool {
        var apiVersion = false
        var kind = false
        for line in text.prefix(sniffLength).split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("apiVersion:") { apiVersion = true }
            if line.hasPrefix("kind:") { kind = true }
            if apiVersion && kind { return true }
        }
        return false
    }
}

public struct KubeDiffObject: Equatable, Sendable, Identifiable {
    public var kind: String
    public var name: String
    public var namespace: String
    public var isNew: Bool
    public var isRemoved: Bool
    public var patch: String

    public var id: String { kind + "/" + namespace + "/" + name }

    public var title: String {
        let base = "\(kind) “\(name)”"
        if isNew { return base + " (New)" }
        if isRemoved { return base + " (Removed)" }
        return base
    }

    public static func split(_ output: String) -> [KubeDiffObject] {
        var objects: [KubeDiffObject] = []
        var current: [String] = []
        var header = ""

        func finish() {
            guard !header.isEmpty else { return }
            let patch = current.joined(separator: "\n")
            let path = header.split(separator: " ").last.map(String.init) ?? ""
            let file = (path as NSString).lastPathComponent
            var parts = file.split(separator: ".").map(String.init)
            var kind = "Object"
            var namespace = ""
            var name = file
            if parts.count >= 4 {
                name = parts.removeLast()
                namespace = parts.removeLast()
                kind = parts.removeLast()
            } else if parts.count == 3 {
                name = parts.removeLast()
                kind = parts.removeLast()
            }
            let isNew = current.contains { $0.hasPrefix("@@ -0,0 ") }
            let isRemoved = current.contains { $0.hasPrefix("@@ ") && $0.contains(" +0,0 @@") }
            objects.append(KubeDiffObject(kind: kind, name: name, namespace: namespace, isNew: isNew, isRemoved: isRemoved, patch: patch))
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("diff ") {
                finish()
                header = line
                current = []
                continue
            }
            if !header.isEmpty { current.append(line) }
        }
        finish()
        return objects
    }
}

public enum KubeCommandLine {
    public static func shellCommand() -> [String] {
        ["sh", "-c", "if command -v bash >/dev/null; then exec bash; else exec sh; fi"]
    }

    public static func scope(context: String, namespace: String) -> [String] {
        var args: [String] = []
        if !context.isEmpty { args += ["--context", context] }
        if !namespace.isEmpty { args += ["-n", namespace] }
        return args
    }

    public static func exec(kubectl: String, context: String, namespace: String, pod: String, container: String) -> [String] {
        var argv = [kubectl] + scope(context: context, namespace: namespace) + ["exec", "-it", pod]
        if !container.isEmpty { argv += ["-c", container] }
        return argv + ["--"] + shellCommand()
    }

    public static func portForward(kubectl: String, context: String, namespace: String, target: String, local: Int, remote: Int) -> [String] {
        [kubectl] + scope(context: context, namespace: namespace) + ["port-forward", target, "\(local):\(remote)"]
    }

    public static func forwardTitle(target: String, local: Int, remote: Int) -> String {
        "Forward localhost:\(local) → \(target):\(remote)"
    }

    public static func forwardKey(context: String, namespace: String, target: String, local: Int, remote: Int) -> String {
        "kube:forward:\(context)|\(namespace)|\(target)|\(local)|\(remote)"
    }

    public static func parseForwardKey(_ key: String) -> (context: String, namespace: String, target: String, local: Int, remote: Int)? {
        guard key.hasPrefix("kube:forward:") else { return nil }
        let parts = key.dropFirst("kube:forward:".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, let local = Int(parts[3]), let remote = Int(parts[4]) else { return nil }
        return (parts[0], parts[1], parts[2], local, remote)
    }

    public static func diff(kubectl: String, context: String, namespace: String, file: String) -> [String] {
        [kubectl] + scope(context: context, namespace: namespace) + ["diff", "-f", file]
    }

    public static func apply(kubectl: String, context: String, namespace: String, file: String) -> [String] {
        [kubectl] + scope(context: context, namespace: namespace) + ["apply", "-f", file]
    }
}
