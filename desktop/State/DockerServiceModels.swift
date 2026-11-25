import Foundation
import GoLensFoundation

struct DockerPort: Decodable, Hashable {
    var ip = ""
    var privatePort = 0
    var publicPort = 0
    var type = "tcp"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        ip = c.dockerValue("ip", "")
        privatePort = c.dockerValue("privatePort", 0)
        publicPort = c.dockerValue("publicPort", 0)
        type = c.dockerValue("type", "tcp")
    }
}

struct DockerContainer: Decodable, Hashable, Identifiable {
    var id = ""
    var name = ""
    var image = ""
    var imageId = ""
    var command = ""
    var created: Int64 = 0
    var state = ""
    var status = ""
    var exitCode: Int?
    var health = ""
    var ports: [DockerPort] = []
    var project = ""
    var service = ""
    var projectDir = ""
    var configFiles: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        id = c.dockerValue("id", "")
        name = c.dockerValue("name", "")
        image = c.dockerValue("image", "")
        imageId = c.dockerValue("imageId", "")
        command = c.dockerValue("command", "")
        created = c.dockerValue("created", Int64(0))
        state = c.dockerValue("state", "")
        status = c.dockerValue("status", "")
        exitCode = c.dockerValue("exitCode", Int?.none)
        health = c.dockerValue("health", "")
        ports = c.dockerValue("ports", [DockerPort]())
        project = c.dockerValue("project", "")
        service = c.dockerValue("service", "")
        projectDir = c.dockerValue("projectDir", "")
        configFiles = c.dockerValue("configFiles", [String]())
    }

    var isRunning: Bool { state == "running" || state == "restarting" }
    var shortID: String { String(id.prefix(12)) }
}

struct DockerEngineLink: Decodable, Equatable {
    var state = ""
    var reason = ""
    var error = ""
    var endpoint = ""
    var context = ""
    var provider = ""
    var apiVersion = ""
    var issue: RemoteIssue?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        state = c.dockerValue("state", "")
        reason = c.dockerValue("reason", "")
        error = c.dockerValue("error", "")
        endpoint = c.dockerValue("endpoint", "")
        context = c.dockerValue("context", "")
        provider = c.dockerValue("provider", "")
        apiVersion = c.dockerValue("apiVersion", "")
        issue = c.dockerValue("issue", RemoteIssue?.none)
    }
}

struct DockerEventBatch: Decodable {
    var seq: Int64 = 0
    var reset = false
    var upserts: [DockerContainer] = []
    var removals: [String] = []
    var invalidated: [String] = []
    var engine = DockerEngineLink()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        seq = c.dockerValue("seq", Int64(0))
        reset = c.dockerValue("reset", false)
        upserts = c.dockerValue("upserts", [DockerContainer]())
        removals = c.dockerValue("removals", [String]())
        invalidated = c.dockerValue("invalidated", [String]())
        engine = c.dockerValue("engine", DockerEngineLink())
    }
}

struct DockerLogLine: Decodable {
    var text = ""
    var stderr = false
    var prefix = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        text = c.dockerValue("text", "")
        stderr = c.dockerValue("stderr", false)
        prefix = c.dockerValue("prefix", "")
    }
}

struct DockerLogBatch: Decodable {
    var stream: Int64 = 0
    var lines: [DockerLogLine] = []
    var dropped = 0
    var closed = false
    var reason = ""
    var error = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        stream = c.dockerValue("stream", Int64(0))
        lines = c.dockerValue("lines", [DockerLogLine]())
        dropped = c.dockerValue("dropped", 0)
        closed = c.dockerValue("closed", false)
        reason = c.dockerValue("reason", "")
        error = c.dockerValue("error", "")
    }
}

struct DockerKeyValue: Decodable, Hashable {
    var key = ""
    var value = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        key = c.dockerValue("key", "")
        value = c.dockerValue("value", "")
    }
}

struct DockerMount: Decodable, Hashable {
    var type = ""
    var name = ""
    var source = ""
    var destination = ""
    var mode = ""
    var readOnly = false

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        type = c.dockerValue("type", "")
        name = c.dockerValue("name", "")
        source = c.dockerValue("source", "")
        destination = c.dockerValue("destination", "")
        mode = c.dockerValue("mode", "")
        readOnly = c.dockerValue("readOnly", false)
    }
}

struct DockerNetwork: Decodable, Hashable {
    var name = ""
    var ipAddress = ""
    var gateway = ""
    var macAddress = ""
    var aliases: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        ipAddress = c.dockerValue("ipAddress", "")
        gateway = c.dockerValue("gateway", "")
        macAddress = c.dockerValue("macAddress", "")
        aliases = c.dockerValue("aliases", [String]())
    }
}

struct DockerContainerDetails: Decodable, Hashable {
    var id = ""
    var name = ""
    var image = ""
    var imageId = ""
    var created = ""
    var state = ""
    var exitCode = 0
    var oomKilled = false
    var stateError = ""
    var startedAt = ""
    var finishedAt = ""
    var health = ""
    var restartPolicy = ""
    var command = ""
    var workingDir = ""
    var tty = false
    var project = ""
    var service = ""
    var ports: [DockerPort] = []
    var env: [DockerKeyValue] = []
    var mounts: [DockerMount] = []
    var networks: [DockerNetwork] = []
    var labels: [DockerKeyValue] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        id = c.dockerValue("id", "")
        name = c.dockerValue("name", "")
        image = c.dockerValue("image", "")
        imageId = c.dockerValue("imageId", "")
        created = c.dockerValue("created", "")
        state = c.dockerValue("state", "")
        exitCode = c.dockerValue("exitCode", 0)
        oomKilled = c.dockerValue("oomKilled", false)
        stateError = c.dockerValue("stateError", "")
        startedAt = c.dockerValue("startedAt", "")
        finishedAt = c.dockerValue("finishedAt", "")
        health = c.dockerValue("health", "")
        restartPolicy = c.dockerValue("restartPolicy", "")
        command = c.dockerValue("command", "")
        workingDir = c.dockerValue("workingDir", "")
        tty = c.dockerValue("tty", false)
        project = c.dockerValue("project", "")
        service = c.dockerValue("service", "")
        ports = c.dockerValue("ports", [DockerPort]())
        env = c.dockerValue("env", [DockerKeyValue]())
        mounts = c.dockerValue("mounts", [DockerMount]())
        networks = c.dockerValue("networks", [DockerNetwork]())
        labels = c.dockerValue("labels", [DockerKeyValue]())
    }
}

struct DockerInspectResult: Decodable {
    var container: DockerContainerDetails?
    var error = ""

    init(error: String) {
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        container = c.dockerValue("container", DockerContainerDetails?.none)
        error = c.dockerValue("error", "")
    }
}

struct DockerImage: Decodable, Hashable, Identifiable {
    var id = ""
    var name = ""
    var tags: [String] = []
    var size: Int64 = 0
    var created: Int64 = 0
    var dangling = false
    var inUse = false
    var usedBy: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        id = c.dockerValue("id", "")
        name = c.dockerValue("name", "")
        tags = c.dockerValue("tags", [String]())
        size = c.dockerValue("size", Int64(0))
        created = c.dockerValue("created", Int64(0))
        dangling = c.dockerValue("dangling", false)
        inUse = c.dockerValue("inUse", false)
        usedBy = c.dockerValue("usedBy", [String]())
    }
}

struct DockerVolume: Decodable, Hashable, Identifiable {
    var name = ""
    var driver = ""
    var mountpoint = ""
    var created = ""
    var project = ""
    var inUse = false
    var usedBy: [String] = []

    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DockerAnyKey.self)
        name = c.dockerValue("name", "")
        driver = c.dockerValue("driver", "")
        mountpoint = c.dockerValue("mountpoint", "")
        created = c.dockerValue("created", "")
        project = c.dockerValue("project", "")
        inUse = c.dockerValue("inUse", false)
        usedBy = c.dockerValue("usedBy", [String]())
    }
}
