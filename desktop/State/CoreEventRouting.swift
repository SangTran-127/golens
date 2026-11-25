import Foundation

enum CoreEventChannel: Hashable {
    case output
    case tests
    case debug
    case search
}

private final class CoreEventOwner {
    weak var workspace: WorkspaceState?

    init(_ workspace: WorkspaceState) {
        self.workspace = workspace
    }
}

extension WorkspaceState {
    private static let coreEventLock = NSLock()
    nonisolated(unsafe) private static var coreEventOwners: [CoreEventChannel: CoreEventOwner] = [:]
    nonisolated(unsafe) private static var taskOwners: [Int64: CoreEventOwner] = [:]
    nonisolated(unsafe) private static var databaseConsoleOwners: [String: CoreEventOwner] = [:]
    private static let maxTrackedTasks = 512

    func claimCoreEvents(_ channels: CoreEventChannel...) {
        Self.coreEventLock.lock()
        for channel in channels {
            Self.coreEventOwners[channel] = CoreEventOwner(self)
        }
        Self.coreEventLock.unlock()
    }

    static func coreEventTarget(_ channel: CoreEventChannel) -> WorkspaceState {
        coreEventLock.lock()
        let owner = coreEventOwners[channel]?.workspace
        coreEventLock.unlock()
        return owner ?? shared
    }

    static func statusEventTargets(topic: String, payload: String) -> [WorkspaceState] {
        if topic.hasPrefix("services.") {
            ServicesStore.receive(topic: topic, payload: payload)
            return []
        }
        switch topic {
        case "languageServer", "terminalExit":
            let all = allRegisteredWorkspaces()
            return all.isEmpty ? [shared] : all
        case "runEvent":
            guard let event = taskEvent(payload) else { return [coreEventTarget(.output)] }
            if event.state == "started" {
                registerTask(event.id, dir: event.dir, fallback: .output)
            }
            return taskTargets(event.id, fallback: .output)
        case "taskStarted":
            if let event = taskEvent(payload) {
                registerTask(event.id, dir: event.dir, fallback: event.kind == "test" ? .tests : .output)
            }
            return []
        case "taskLog":
            guard let event = taskEvent(payload) else { return [coreEventTarget(.output)] }
            return taskTargets(event.id, fallback: .output)
        case "testProfile":
            guard let event = taskEvent(payload), event.id > 0 else { return [coreEventTarget(.tests)] }
            return taskTargets(event.id, fallback: .tests)
        case "remoteIssue":
            return [coreEventTarget(.output)]
        case "database":
            return databaseEventTargets(payload)
        default:
            return [shared]
        }
    }

    static func registerDatabaseConsole(_ consoleID: String, owner: WorkspaceState) {
        coreEventLock.lock()
        databaseConsoleOwners[consoleID] = CoreEventOwner(owner)
        databaseConsoleOwners = databaseConsoleOwners.filter { $0.value.workspace != nil }
        coreEventLock.unlock()
    }

    private static func databaseEventTargets(_ payload: String) -> [WorkspaceState] {
        guard let range = payload.range(of: #""consoleId":"[^"]+""#, options: .regularExpression) else { return [] }
        let consoleID = String(payload[range].dropFirst(13).dropLast())
        coreEventLock.lock()
        let owner = databaseConsoleOwners[consoleID]?.workspace
        coreEventLock.unlock()
        guard let owner, allRegisteredWorkspaces().contains(where: { $0 === owner }) else { return [] }
        return [owner]
    }

    static func testEventTargets(_ payload: String) -> [WorkspaceState] {
        guard let range = payload.range(of: #""run":[0-9]+"#, options: .regularExpression),
              let id = Int64(payload[range].dropFirst(6)) else { return [coreEventTarget(.tests)] }
        return taskTargets(id, fallback: .tests)
    }

    func ownedTaskIDs() -> [Int64] {
        Self.coreEventLock.lock()
        defer { Self.coreEventLock.unlock() }
        return Self.taskOwners.filter { $0.value.workspace === self }.map(\.key)
    }

    func ownTask(_ id: Int64) {
        guard id > 0 else { return }
        Self.coreEventLock.lock()
        Self.taskOwners[id] = CoreEventOwner(self)
        Self.pruneTasksLocked()
        Self.coreEventLock.unlock()
    }

    private struct TaskEvent {
        let id: Int64
        let state: String?
        let dir: String?
        let kind: String?
    }

    private static func taskEvent(_ payload: String) -> TaskEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.int64Value else { return nil }
        return TaskEvent(id: id, state: object["state"] as? String, dir: object["dir"] as? String, kind: object["kind"] as? String)
    }

    private static func registerTask(_ id: Int64, dir: String?, fallback: CoreEventChannel) {
        coreEventLock.lock()
        let known = taskOwners[id] != nil
        coreEventLock.unlock()
        guard !known else { return }
        let owner = dir.flatMap { workspaceOwningPath($0) } ?? coreEventTarget(fallback)
        coreEventLock.lock()
        if taskOwners[id] == nil {
            taskOwners[id] = CoreEventOwner(owner)
            pruneTasksLocked()
        }
        coreEventLock.unlock()
    }

    private static func pruneTasksLocked() {
        guard taskOwners.count > maxTrackedTasks else { return }
        for id in taskOwners.keys.sorted().prefix(taskOwners.count - maxTrackedTasks) {
            taskOwners.removeValue(forKey: id)
        }
    }

    private static func taskTargets(_ id: Int64, fallback: CoreEventChannel) -> [WorkspaceState] {
        coreEventLock.lock()
        let entry = taskOwners[id]
        coreEventLock.unlock()
        guard let entry else { return [coreEventTarget(fallback)] }
        guard let owner = entry.workspace, allRegisteredWorkspaces().contains(where: { $0 === owner }) else { return [] }
        return [owner]
    }

    static func workspaceHoldingDocument(_ path: String) -> WorkspaceState? {
        let all = allRegisteredWorkspaces()
        if all.count <= 1 { return all.first ?? shared }
        return all.first { $0.openFiles.contains(path) }
    }

    static func workspaceForEdit(_ payload: String) -> WorkspaceState {
        guard let range = payload.range(of: #"file://[^"]+"#, options: .regularExpression),
              let url = URL(string: String(payload[range])) else { return shared }
        return workspaceOwningPath(url.path) ?? workspaceHoldingDocument(url.path) ?? shared
    }

    static func releaseCoreRoot(_ root: String, excluding workspace: WorkspaceState) {
        guard !root.isEmpty else { return }
        let stillOpen = allRegisteredWorkspaces().contains { $0 !== workspace && $0.activeWorkspacePath == root }
        guard !stillOpen else { return }
        root.withCString { CloseWorkspaceFolder($0) }
    }

    var otherWindowDebugSession: WorkspaceState? {
        Self.allRegisteredWorkspaces().first { $0 !== self && $0.debug.isDebugMode }
    }
}
