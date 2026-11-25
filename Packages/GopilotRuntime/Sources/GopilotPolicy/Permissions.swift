import Foundation

public enum PolicyOperation: String, Codable, Sendable, CaseIterable {
    case read
    case runTests
    case runBenchmark
    case runGoCheck
    case writeFile
    case applyPatch
    case shell

    public var isModelOperation: Bool {
        switch self {
        case .read, .runTests, .runBenchmark, .runGoCheck: return true
        case .writeFile, .applyPatch, .shell: return false
        }
    }

    public var isExecution: Bool {
        self == .runTests || self == .runBenchmark || self == .runGoCheck
    }

    public var approvalTitle: String {
        switch self {
        case .runTests: return "Run tests?"
        case .runBenchmark: return "Run benchmark?"
        case .runGoCheck: return "Run Go check?"
        case .read: return "Read files?"
        case .writeFile, .applyPatch: return "Change files?"
        case .shell: return "Run command?"
        }
    }

    public var executionNoun: String {
        switch self {
        case .runBenchmark: return "benchmarks"
        case .runGoCheck: return "a Go build or vet check"
        default: return "tests"
        }
    }
}

public enum ExecutionIsolation: Sendable, Equatable {
    case linuxContainer
    case hostProcess

    public func summary(for operation: PolicyOperation) -> String {
        let action = operation == .runGoCheck
            ? "Running a Go build or vet check compiles code from this repository and can run its build steps"
            : "Running \(operation.executionNoun) executes code from this repository"
        switch self {
        case .linuxContainer:
            return "\(action) inside GoLens's Linux container. The project folder is shared with the container read-write, so this code can change or delete files in the project. Apart from GoLens's own Go module and build caches, other files on your Mac are not shared with it. Network access follows the Linux container setting (loopback only unless you allowed outbound network). A grant limits what the model may ask for; it does not make the code safe."
        case .hostProcess:
            return "\(action) on your Mac with your user permissions. A grant limits what the model may ask for; it does not sandbox the code."
        }
    }
}

public struct ExecutionGrant: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspaceID: UUID
    public let operation: PolicyOperation
    public let selector: String
    public let targetConfigHash: String
    public let workspaceSnapshotHash: String
    public let envNames: Set<String>
    public let timeoutSeconds: Int
    public let maxRuns: Int
    public let expiresAt: Date
    public let ownerActionID: String
    public internal(set) var runsUsed: Int

    public var runsRemaining: Int { max(0, maxRuns - runsUsed) }

    public init(id: UUID = UUID(), workspaceID: UUID, operation: PolicyOperation, selector: String, targetConfigHash: String, workspaceSnapshotHash: String = "", envNames: Set<String> = [], timeoutSeconds: Int, maxRuns: Int, expiresAt: Date, ownerActionID: String, runsUsed: Int = 0) {
        self.id = id
        self.workspaceID = workspaceID
        self.operation = operation
        self.selector = selector
        self.targetConfigHash = targetConfigHash
        self.workspaceSnapshotHash = workspaceSnapshotHash
        self.envNames = envNames
        self.timeoutSeconds = timeoutSeconds
        self.maxRuns = maxRuns
        self.expiresAt = expiresAt
        self.ownerActionID = ownerActionID
        self.runsUsed = runsUsed
    }
}

public struct PermissionRequest: Sendable, Equatable {
    public let workspaceID: UUID
    public let operation: PolicyOperation
    public let selector: String
    public let targetConfigHash: String
    public let workspaceSnapshotHash: String
    public let envNames: Set<String>
    public let timeoutSeconds: Int
    public let runCount: Int

    public init(workspaceID: UUID, operation: PolicyOperation, selector: String = "", targetConfigHash: String = "", workspaceSnapshotHash: String = "", envNames: Set<String> = [], timeoutSeconds: Int = 0, runCount: Int = 1) {
        self.workspaceID = workspaceID
        self.operation = operation
        self.selector = selector
        self.targetConfigHash = targetConfigHash
        self.workspaceSnapshotHash = workspaceSnapshotHash
        self.envNames = envNames
        self.timeoutSeconds = timeoutSeconds
        self.runCount = runCount
    }
}

public enum GrantMismatch: Sendable, Equatable {
    case noGrant
    case workspace
    case operation
    case selector(granted: String, requested: String)
    case targetConfig
    case workspaceSnapshot(granted: String, current: String)
    case environment(extraNames: [String])
    case timeout(granted: Int, requested: Int)
    case runCount(remaining: Int, requested: Int)
    case expired

    public var explanation: String {
        switch self {
        case .noGrant: return "No execution grant covers this request."
        case .workspace: return "The grant belongs to a different workspace."
        case .operation: return "The grant covers a different operation."
        case .selector(let granted, let requested): return "The grant covers \(granted) but the request selects \(requested)."
        case .targetConfig: return "The build target or configuration changed since the grant was approved."
        case .workspaceSnapshot: return "The workspace code changed since the grant was approved."
        case .environment(let names): return "The request needs environment variables that were not approved: \(names.joined(separator: ", "))."
        case .timeout(let granted, let requested): return "The request asks for a \(requested) second timeout; the grant allows \(granted)."
        case .runCount(let remaining, let requested): return "The request needs \(requested) run(s); the grant has \(remaining) left."
        case .expired: return "The grant has expired."
        }
    }
}

public struct ApprovalCard: Sendable, Equatable {
    public let workspaceID: UUID
    public let operation: PolicyOperation
    public let selector: String
    public let targetConfigHash: String
    public let envNames: [String]
    public let timeoutSeconds: Int
    public let runCount: Int
    public let mismatches: [GrantMismatch]
    public let executesRepositoryCode: Bool
    public let explanation: String
}

public enum DenyReason: Sendable, Equatable {
    case notAModelOperation
    case denyRule
    case workspaceNotTrusted
    case invalidRequest(String)
    case secretEnvironmentName(String)
    case timeoutAboveLimit(Int)

    public var message: String {
        switch self {
        case .notAModelOperation: return "This operation is never performed by the model."
        case .denyRule: return "A deny rule blocks this operation."
        case .workspaceNotTrusted: return "Execution is only available in a workspace the user has marked as trusted."
        case .invalidRequest(let detail): return "Invalid request: \(detail)"
        case .secretEnvironmentName(let name): return "Environment variable \(name) looks like a secret and cannot be forwarded."
        case .timeoutAboveLimit(let limit): return "Timeout exceeds the \(limit) second limit."
        }
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow(grantID: UUID?)
    case needsApproval(ApprovalCard)
    case deny(DenyReason)
}

public struct PolicyDenyRule: Sendable, Equatable {
    public let operation: PolicyOperation
    public let workspaceID: UUID?
    public let selector: String?

    public init(operation: PolicyOperation, workspaceID: UUID? = nil, selector: String? = nil) {
        self.operation = operation
        self.workspaceID = workspaceID
        self.selector = selector
    }

    func matches(_ request: PermissionRequest) -> Bool {
        guard request.operation == operation else { return false }
        if let workspaceID, workspaceID != request.workspaceID { return false }
        if let selector, selector != request.selector { return false }
        return true
    }
}

public struct PermissionPolicy: Sendable {
    public static let maxTimeoutSeconds = 600

    public let denyRules: [PolicyDenyRule]
    public let trustedWorkspaces: Set<UUID>
    public let isolation: ExecutionIsolation

    public init(denyRules: [PolicyDenyRule] = [], trustedWorkspaces: Set<UUID> = [], isolation: ExecutionIsolation = .linuxContainer) {
        self.denyRules = denyRules
        self.trustedWorkspaces = trustedWorkspaces
        self.isolation = isolation
    }

    public static func canonicalSelector(package: String, tests: [String] = []) -> String {
        let names = Array(Set(tests)).sorted()
        return names.isEmpty ? package : package + "#" + names.joined(separator: ",")
    }

    public func decide(_ request: PermissionRequest, grants: [ExecutionGrant], now: Date = Date()) -> PermissionDecision {
        guard request.operation.isModelOperation else { return .deny(.notAModelOperation) }
        if denyRules.contains(where: { $0.matches(request) }) { return .deny(.denyRule) }
        guard request.operation.isExecution else { return .allow(grantID: nil) }

        guard trustedWorkspaces.contains(request.workspaceID) else { return .deny(.workspaceNotTrusted) }
        if request.selector.isEmpty { return .deny(.invalidRequest("selector is empty")) }
        if request.runCount < 1 { return .deny(.invalidRequest("run count must be at least 1")) }
        if request.timeoutSeconds < 1 { return .deny(.invalidRequest("timeout must be at least 1 second")) }
        if request.timeoutSeconds > Self.maxTimeoutSeconds { return .deny(.timeoutAboveLimit(Self.maxTimeoutSeconds)) }
        if let name = request.envNames.sorted().first(where: { EnvironmentBuilder.looksSecret(name: $0) }) {
            return .deny(.secretEnvironmentName(name))
        }

        var best: (grant: ExecutionGrant, mismatches: [GrantMismatch])?
        for grant in grants {
            let mismatches = Self.mismatches(of: grant, for: request, now: now)
            if mismatches.isEmpty { return .allow(grantID: grant.id) }
            let isBetter: Bool
            if let current = best {
                let sameWorkspace = grant.workspaceID == request.workspaceID
                let currentSame = current.grant.workspaceID == request.workspaceID
                isBetter = (sameWorkspace && !currentSame) || (sameWorkspace == currentSame && mismatches.count < current.mismatches.count)
            } else {
                isBetter = true
            }
            if isBetter { best = (grant, mismatches) }
        }
        return .needsApproval(card(for: request, mismatches: best?.mismatches ?? [.noGrant], grantID: best?.grant.id))
    }

    static func mismatches(of grant: ExecutionGrant, for request: PermissionRequest, now: Date) -> [GrantMismatch] {
        var found: [GrantMismatch] = []
        if grant.workspaceID != request.workspaceID { found.append(.workspace) }
        if grant.operation != request.operation { found.append(.operation) }
        if grant.selector != request.selector { found.append(.selector(granted: grant.selector, requested: request.selector)) }
        if grant.targetConfigHash != request.targetConfigHash { found.append(.targetConfig) }
        if grant.workspaceSnapshotHash != request.workspaceSnapshotHash {
            found.append(.workspaceSnapshot(granted: grant.workspaceSnapshotHash, current: request.workspaceSnapshotHash))
        }
        let extra = request.envNames.subtracting(grant.envNames).sorted()
        if !extra.isEmpty { found.append(.environment(extraNames: extra)) }
        if request.timeoutSeconds > grant.timeoutSeconds { found.append(.timeout(granted: grant.timeoutSeconds, requested: request.timeoutSeconds)) }
        if request.runCount > grant.runsRemaining { found.append(.runCount(remaining: grant.runsRemaining, requested: request.runCount)) }
        if now >= grant.expiresAt { found.append(.expired) }
        return found
    }

    private func card(for request: PermissionRequest, mismatches: [GrantMismatch], grantID: UUID?) -> ApprovalCard {
        var lines = [isolation.summary(for: request.operation)]
        lines.append(contentsOf: mismatches.map(\.explanation))
        return ApprovalCard(
            workspaceID: request.workspaceID,
            operation: request.operation,
            selector: request.selector,
            targetConfigHash: request.targetConfigHash,
            envNames: request.envNames.sorted(),
            timeoutSeconds: request.timeoutSeconds,
            runCount: request.runCount,
            mismatches: mismatches,
            executesRepositoryCode: true,
            explanation: lines.joined(separator: " ")
        )
    }
}

public enum GrantError: Error, Sendable, Equatable {
    case invalid(String)
}

public actor GrantStore {
    private var policy: PermissionPolicy
    private var grants: [UUID: ExecutionGrant] = [:]

    public init(policy: PermissionPolicy = PermissionPolicy()) {
        self.policy = policy
    }

    public func add(_ grant: ExecutionGrant) throws {
        guard grant.operation.isExecution else { throw GrantError.invalid("only execution operations take grants") }
        guard !grant.selector.isEmpty else { throw GrantError.invalid("selector is empty") }
        guard grant.maxRuns >= 1 else { throw GrantError.invalid("maxRuns must be at least 1") }
        guard (1...PermissionPolicy.maxTimeoutSeconds).contains(grant.timeoutSeconds) else { throw GrantError.invalid("timeout out of range") }
        guard !grant.ownerActionID.isEmpty else { throw GrantError.invalid("owner action is required") }
        grants[grant.id] = grant
    }

    public func authorize(_ request: PermissionRequest, now: Date = Date()) -> PermissionDecision {
        let decision = policy.decide(request, grants: Array(grants.values), now: now)
        if case .allow(let grantID?) = decision, var grant = grants[grantID] {
            grant.runsUsed += request.runCount
            grants[grantID] = grant
        }
        return decision
    }

    public func setTrusted(_ trusted: Bool, workspaceID: UUID) {
        var set = policy.trustedWorkspaces
        if trusted { set.insert(workspaceID) } else { set.remove(workspaceID) }
        policy = PermissionPolicy(denyRules: policy.denyRules, trustedWorkspaces: set, isolation: policy.isolation)
    }

    public func activeGrants(workspaceID: UUID) -> [ExecutionGrant] {
        grants.values.filter { $0.workspaceID == workspaceID }
    }

    public func revokeAll(workspaceID: UUID) {
        grants = grants.filter { $0.value.workspaceID != workspaceID }
    }

    public func revokeOnWorkspaceMutation(workspaceID: UUID) {
        grants = grants.filter { $0.value.workspaceID != workspaceID }
    }

    public func workspaceChanged(activeWorkspaceID: UUID?) {
        grants = grants.filter { $0.value.workspaceID == activeWorkspaceID }
    }

    public func revokeAll() {
        grants.removeAll()
    }
}
