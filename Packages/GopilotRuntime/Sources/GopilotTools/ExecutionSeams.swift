import Foundation
import GopilotPolicy
import GopilotAnalysis
import GopilotStore

public enum ApprovalDecision: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case decline
}

public struct ExecutionApprovalCard: Sendable, Equatable {
    public let operation: PolicyOperation
    public let selector: String
    public let packageSelector: String
    public let testNames: [String]
    public let benchmarkNames: [String]
    public let target: String
    public let workingDirectory: String
    public let argv: [String]
    public let timeoutSeconds: Int
    public let goCount: Int
    public let benchtime: String?
    public let runCount: Int
    public let envNames: [String]
    public let outputLimitBytes: Int
    public let mismatches: [GrantMismatch]
    public let warning: String
    public var sessionGrantMaxRuns: Int = 20
    public var sessionGrantLifetime: TimeInterval = 3600

    public var executesRepositoryCode: Bool { true }

    public var title: String { operation.approvalTitle }

    public var itemsLabel: String {
        switch operation {
        case .runBenchmark: return "Benchmarks"
        case .runGoCheck: return "Check"
        default: return "Tests"
        }
    }

    public var items: [String] {
        switch operation {
        case .runBenchmark:
            return benchmarkNames
        case .runGoCheck:
            return [argv.prefix(2).joined(separator: " ")]
        default:
            return testNames.isEmpty ? ["All tests in \(packageSelector)"] : testNames
        }
    }

    public var accessibilitySummary: String {
        switch operation {
        case .runBenchmark: return "Approval needed to run a benchmark"
        case .runGoCheck: return "Approval needed to run a Go check"
        default: return "Approval needed to run tests"
        }
    }
}

public protocol ApprovalProvider: Sendable {
    func requestApproval(_ card: ExecutionApprovalCard) async -> ApprovalDecision
}

public protocol DirtyBufferProvider: Sendable {
    func bufferStates() async -> [BufferDiskState]
    func chooseAction(dirtyPaths: [String]) async -> DirtyBufferDecision
    func save(paths: [String]) async -> Bool
}

public struct TestTarget: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case test
        case benchmark
    }

    public let package: String
    public let name: String
    public let kind: Kind
    public let moduleDirectory: String

    public var id: String { "\(package)#\(name)" }

    public init(package: String, name: String, kind: Kind, moduleDirectory: String = "") {
        self.package = package
        self.name = name
        self.kind = kind
        self.moduleDirectory = moduleDirectory
    }
}

public protocol TestTargetBackend: Sendable {
    func targets(in packageScope: String) async -> BackendOutcome<[TestTarget]>
}

public protocol SourceFingerprintProvider: Sendable {
    func diskHashes(moduleDirectory: String, package: String) async -> [String: String]
}

public struct AttachedProfileInfo: Sendable, Equatable {
    public let sourceKey: String
    public let label: String
    public let metadata: ProfileRunMetadata
    public let mapping: MappingConfidence
    public let capturedAt: Date

    public init(sourceKey: String, label: String, metadata: ProfileRunMetadata = .unknown, mapping: MappingConfidence = .unverified, capturedAt: Date = Date()) {
        self.sourceKey = sourceKey
        self.label = label
        self.metadata = metadata
        self.mapping = mapping
        self.capturedAt = capturedAt
    }
}

public protocol ProfileSource: Sendable {
    func attachedProfiles() async -> [AttachedProfileInfo]
    func payload(sourceKey: String) async -> ProfileDetailPayload?
}

public enum PatchAutoApplyOutcome: Sendable, Equatable {
    case applied
    case notPermitted
    case needsReview(String)
    case stale(String)
    case failed(String)
}

public struct PatchBackend: Sendable {
    public let store: PatchProposalStore
    public let currentFile: CurrentFileProvider
    public let turnID: @Sendable () async -> UUID
    public let allowCreateOverwrite: Bool
    public let postProposeCheck: (@Sendable (PatchProposal) async -> [String])?
    public let autoApplyIfPermitted: (@Sendable (UUID) async -> PatchAutoApplyOutcome)?
    public let postApplyDiagnostics: (@Sendable (PatchProposal) async -> [String]?)?

    public init(
        store: PatchProposalStore,
        currentFile: @escaping CurrentFileProvider,
        turnID: @escaping @Sendable () async -> UUID = { UUID() },
        allowCreateOverwrite: Bool = false,
        postProposeCheck: (@Sendable (PatchProposal) async -> [String])? = nil,
        autoApplyIfPermitted: (@Sendable (UUID) async -> PatchAutoApplyOutcome)? = nil,
        postApplyDiagnostics: (@Sendable (PatchProposal) async -> [String]?)? = nil
    ) {
        self.store = store
        self.currentFile = currentFile
        self.turnID = turnID
        self.allowCreateOverwrite = allowCreateOverwrite
        self.postProposeCheck = postProposeCheck
        self.autoApplyIfPermitted = autoApplyIfPermitted
        self.postApplyDiagnostics = postApplyDiagnostics
    }
}

public struct ExecutionBackends: Sendable {
    public var memory: MemoryStore?
    public var testTargets: TestTargetBackend?
    public var approvals: ApprovalProvider?
    public var dirtyBuffers: DirtyBufferProvider?
    public var fingerprints: SourceFingerprintProvider?
    public var profiles: ProfileSource?
    public var patch: PatchBackend?

    public init(memory: MemoryStore? = nil, testTargets: TestTargetBackend? = nil, approvals: ApprovalProvider? = nil, dirtyBuffers: DirtyBufferProvider? = nil, fingerprints: SourceFingerprintProvider? = nil, profiles: ProfileSource? = nil, patch: PatchBackend? = nil) {
        self.memory = memory
        self.testTargets = testTargets
        self.approvals = approvals
        self.dirtyBuffers = dirtyBuffers
        self.fingerprints = fingerprints
        self.profiles = profiles
        self.patch = patch
    }

    public var canRun: Bool {
        testTargets != nil && approvals != nil && dirtyBuffers != nil && fingerprints != nil
    }
}

public struct ExecutionToolContext: Sendable {
    public let workspaceID: UUID
    public let workspaceRoot: URL
    public let snapshot: @Sendable () async -> SourceSnapshot
    public let evidence: EvidenceStore
    public let grants: GrantStore
    public let arbiter: RunArbiter
    public let runs: RunResultStore
    public let profiles: ProfileRegistry
    public let redactor: @Sendable (String) -> String
    public let environment: [String: String]
    public let outputLimitBytes: Int
    public let sessionGrantMaxRuns: Int
    public let sessionGrantLifetime: TimeInterval
    public let backends: ExecutionBackends
    public let sandboxReadiness: (@Sendable () async -> SandboxReadiness)?

    public init(
        workspaceID: UUID,
        workspaceRoot: URL,
        snapshot: @escaping @Sendable () async -> SourceSnapshot,
        evidence: EvidenceStore,
        grants: GrantStore,
        arbiter: RunArbiter,
        runs: RunResultStore = RunResultStore(),
        profiles: ProfileRegistry = ProfileRegistry(),
        redactor: @escaping @Sendable (String) -> String = { SecretFilter().redact($0).text },
        environment: [String: String] = EnvironmentBuilder().build(from: ProcessInfo.processInfo.environment),
        outputLimitBytes: Int = 512 * 1024,
        sessionGrantMaxRuns: Int = 20,
        sessionGrantLifetime: TimeInterval = 3600,
        backends: ExecutionBackends,
        sandboxReadiness: (@Sendable () async -> SandboxReadiness)? = nil
    ) {
        self.workspaceID = workspaceID
        self.workspaceRoot = workspaceRoot
        self.snapshot = snapshot
        self.evidence = evidence
        self.grants = grants
        self.arbiter = arbiter
        self.runs = runs
        self.profiles = profiles
        self.redactor = redactor
        self.environment = environment
        self.outputLimitBytes = outputLimitBytes
        self.sessionGrantMaxRuns = sessionGrantMaxRuns
        self.sessionGrantLifetime = sessionGrantLifetime
        self.backends = backends
        self.sandboxReadiness = sandboxReadiness
    }
}
