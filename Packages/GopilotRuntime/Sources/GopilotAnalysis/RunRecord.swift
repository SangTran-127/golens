import Foundation

public enum RunOwner: Sendable, Equatable, Hashable, Codable {
    case user
    case ai(actionID: String)
}

public enum RunTerminalStatus: String, Sendable, Equatable, Codable {
    case passed
    case failed
    case cancelled
    case timedOut
    case unknown
}

public struct RunArtifactRef: Sendable, Equatable, Codable {
    public let kind: String
    public let path: String
    public let sha256: String?

    public init(kind: String, path: String, sha256: String? = nil) {
        self.kind = kind
        self.path = path
        self.sha256 = sha256
    }
}

public struct RunRecord: Sendable, Equatable, Codable {
    public let runID: UUID
    public let owner: RunOwner
    public let argv: [String]
    public let cwd: String
    public let sourceHash: String
    public let configHash: String
    public let startedAt: Date
    public let endedAt: Date?
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let status: RunTerminalStatus
    public let outputTruncated: Bool
    public let artifacts: [RunArtifactRef]

    public init(runID: UUID = UUID(), owner: RunOwner, argv: [String], cwd: String, sourceHash: String, configHash: String, startedAt: Date, endedAt: Date?, exitCode: Int32?, terminationSignal: Int32? = nil, outcome: ProcessRunResult.Outcome, outputTruncated: Bool = false, artifacts: [RunArtifactRef] = []) {
        self.runID = runID
        self.owner = owner
        self.argv = argv
        self.cwd = cwd
        self.sourceHash = sourceHash
        self.configHash = configHash
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.status = Self.resolveStatus(outcome: outcome, exitCode: exitCode, terminationSignal: terminationSignal, ended: endedAt != nil)
        self.outputTruncated = outputTruncated
        self.artifacts = artifacts
    }

    public static func resolveStatus(outcome: ProcessRunResult.Outcome, exitCode: Int32?, terminationSignal: Int32?, ended: Bool) -> RunTerminalStatus {
        switch outcome {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .abandoned: return .unknown
        case .exited:
            guard ended else { return .unknown }
            if let exitCode { return exitCode == 0 ? .passed : .failed }
            return terminationSignal != nil ? .failed : .unknown
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runID, owner, argv, cwd, sourceHash, configHash, startedAt, endedAt, exitCode, terminationSignal, status, outputTruncated, artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(UUID.self, forKey: .runID)
        owner = try container.decode(RunOwner.self, forKey: .owner)
        argv = try container.decode([String].self, forKey: .argv)
        cwd = try container.decode(String.self, forKey: .cwd)
        sourceHash = try container.decode(String.self, forKey: .sourceHash)
        configHash = try container.decode(String.self, forKey: .configHash)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        terminationSignal = try container.decodeIfPresent(Int32.self, forKey: .terminationSignal)
        outputTruncated = try container.decode(Bool.self, forKey: .outputTruncated)
        artifacts = try container.decode([RunArtifactRef].self, forKey: .artifacts)
        let stored = try container.decode(RunTerminalStatus.self, forKey: .status)
        if stored == .passed, endedAt == nil || exitCode != 0 {
            status = .unknown
        } else {
            status = stored
        }
    }
}

public enum RunConfigHash {
    public static func compute(argv: [String], environmentNames: [String], extra: [String: String] = [:]) -> String {
        var parts = extra
        parts["argv"] = argv.joined(separator: "\u{1F}")
        parts["envNames"] = environmentNames.sorted().joined(separator: ",")
        return ContentHash.combined(parts)
    }
}
