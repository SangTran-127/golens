import Foundation

public struct DockerAnyKey: CodingKey {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == DockerAnyKey {
    public func dockerValue<T: Decodable>(_ key: String, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: DockerAnyKey(key))) ?? fallback
    }
}

public struct DockerListResult<Item: Decodable>: Decodable {
    public var kind = ""
    public var items: [Item] = []
    public var error = ""

    public init(error: String) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        kind = c.dockerValue("kind", "")
        items = c.dockerValue("items", [Item]())
        error = c.dockerValue("error", "")
    }
}

public struct DockerActionResult: Decodable {
    public var ok = false
    public var error = ""

    public init(error: String) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        ok = c.dockerValue("ok", false)
        error = c.dockerValue("error", "")
    }
}

public struct DockerNetworkSummary: Decodable, Hashable, Identifiable, Sendable {
    public var id = ""
    public var name = ""
    public var driver = ""
    public var scope = ""
    public var builtIn = false
    public var containers: [String] = []
    public var created = ""

    public var isRemovable: Bool { !builtIn && containers.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        id = c.dockerValue("id", "")
        name = c.dockerValue("name", "")
        driver = c.dockerValue("driver", "")
        scope = c.dockerValue("scope", "")
        builtIn = c.dockerValue("builtIn", false)
        containers = c.dockerValue("containers", [String]())
        if let text = c.dockerValue("created", String?.none) {
            created = text
        } else if let seconds = c.dockerValue("created", Int64?.none), seconds > 0 {
            created = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
    }
}

public enum DockerPruneKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case containers, images, volumes, networks, buildCache

    public var id: String { rawValue }
    public var isCheckedByDefault: Bool { self != .volumes }
}

public struct DockerDiskCategory: Decodable, Hashable, Sendable {
    public var kind: DockerPruneKind?
    public var count = 0
    public var bytes: Int64 = 0

    public init(kind: DockerPruneKind, count: Int, bytes: Int64) {
        self.kind = kind
        self.count = count
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        kind = DockerPruneKind(rawValue: c.dockerValue("kind", ""))
        count = c.dockerValue("count", 0)
        bytes = c.dockerValue("bytes", Int64(0))
    }
}

public struct DockerDiskUsage: Decodable, Sendable {
    public var categories: [DockerDiskCategory] = []
    public var error = ""

    public init(error: String) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        categories = c.dockerValue("categories", [DockerDiskCategory]()).filter { $0.kind != nil }
        error = c.dockerValue("error", "")
    }

    public func category(_ kind: DockerPruneKind) -> DockerDiskCategory {
        categories.first { $0.kind == kind } ?? DockerDiskCategory(kind: kind, count: 0, bytes: 0)
    }

    public func reclaimableBytes(_ kinds: Set<DockerPruneKind>) -> Int64 {
        kinds.reduce(Int64(0)) { $0 + category($1).bytes }
    }
}

public struct DockerPruneOptions: Encodable, Equatable, Sendable {
    public var kind: DockerPruneKind
    public var label: String?

    public init(kind: DockerPruneKind, label: String? = nil) {
        self.kind = kind
        self.label = label
    }

    public var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct DockerPruneResult: Decodable, Sendable {
    public var kind = ""
    public var removed = 0
    public var bytes: Int64 = 0
    public var error = ""

    public init(error: String) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        kind = c.dockerValue("kind", "")
        if let count = c.dockerValue("removed", Int?.none) {
            removed = count
        } else {
            removed = c.dockerValue("removed", [String]()).count
        }
        bytes = c.dockerValue("bytes", Int64(0))
        error = c.dockerValue("error", "")
    }
}

public struct DockerStatsSample: Decodable, Equatable, Sendable {
    public var stream: Int64 = 0
    public var id = ""
    public var cpuPercent = 0.0
    public var memoryBytes: Int64 = 0
    public var memoryLimitBytes: Int64 = 0
    public var closed = false
    public var error = ""

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        stream = c.dockerValue("stream", Int64(0))
        id = c.dockerValue("id", "")
        cpuPercent = c.dockerValue("cpuPercent", 0.0)
        memoryBytes = c.dockerValue("memoryBytes", Int64(0))
        memoryLimitBytes = c.dockerValue("memoryLimitBytes", Int64(0))
        closed = c.dockerValue("closed", false)
        error = c.dockerValue("error", "")
    }

    public var hasReading: Bool { !closed && error.isEmpty && (memoryBytes > 0 || cpuPercent > 0) }
}

public struct DockerContextInfo: Decodable, Hashable, Identifiable, Sendable {
    public var name = ""
    public var description = ""
    public var endpoint = ""
    public var transport = ""
    public var current = false

    public var id: String { name }
    public var isRemote: Bool { transport == "ssh" || transport == "tcp" || transport == "tls" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        description = c.dockerValue("description", "")
        endpoint = c.dockerValue("endpoint", "")
        transport = c.dockerValue("transport", "")
        current = c.dockerValue("current", false)
    }
}

public struct DockerContextList: Decodable, Sendable {
    public var current = ""
    public var contexts: [DockerContextInfo] = []
    public var error = ""

    public init(error: String) {
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        current = c.dockerValue("current", "")
        contexts = c.dockerValue("contexts", [DockerContextInfo]())
        error = c.dockerValue("error", "")
        if current.isEmpty, let marked = contexts.first(where: \.current) {
            current = marked.name
        }
    }

    public var currentContext: DockerContextInfo? {
        contexts.first { $0.name == current }
    }
}
