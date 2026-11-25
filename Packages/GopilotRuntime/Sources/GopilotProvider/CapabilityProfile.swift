import Foundation

public enum CapabilityState: String, Sendable, Codable, Equatable {
    case verified
    case unsupported
    case unknown
}

public enum AgentMode: String, Sendable, Codable, Equatable {
    case agent
    case chatOnly
    case unavailable
}

public struct CapabilityRecord: Sendable, Codable, Equatable {
    public let capability: ProviderCapability
    public let state: CapabilityState
    public let checkedAt: Date
    public let configHash: String
    public let detail: String?

    public init(capability: ProviderCapability, state: CapabilityState, checkedAt: Date, configHash: String, detail: String? = nil) {
        self.capability = capability
        self.state = state
        self.checkedAt = checkedAt
        self.configHash = configHash
        self.detail = detail
    }
}

public struct CapabilityProfile: Sendable, Codable, Equatable {
    public private(set) var records: [CapabilityRecord]

    public init(records: [CapabilityRecord] = []) {
        self.records = records
    }

    public func record(for capability: ProviderCapability, configHash: String) -> CapabilityRecord? {
        records.first { $0.capability == capability && $0.configHash == configHash }
    }

    public func state(of capability: ProviderCapability, configHash: String) -> CapabilityState {
        record(for: capability, configHash: configHash)?.state ?? .unknown
    }

    public func isVerified(_ capability: ProviderCapability, configHash: String) -> Bool {
        state(of: capability, configHash: configHash) == .verified
    }

    public mutating func set(
        _ capability: ProviderCapability,
        _ state: CapabilityState,
        configHash: String,
        at date: Date,
        detail: String? = nil
    ) {
        records.removeAll { $0.capability == capability }
        records.append(CapabilityRecord(capability: capability, state: state, checkedAt: date, configHash: configHash, detail: detail))
    }

    public mutating func setScoped(
        _ capability: ProviderCapability,
        _ state: CapabilityState,
        configHash: String,
        at date: Date,
        detail: String? = nil
    ) {
        records.removeAll { $0.capability == capability && $0.configHash == configHash }
        records.append(CapabilityRecord(capability: capability, state: state, checkedAt: date, configHash: configHash, detail: detail))
    }

    public func invalidated(for configHash: String) -> CapabilityProfile {
        CapabilityProfile(records: records.filter { $0.configHash == configHash })
    }

    public func agentMode(configHash: String) -> AgentMode {
        guard isVerified(.text, configHash: configHash) else { return .unavailable }
        return isVerified(.tools, configHash: configHash) ? .agent : .chatOnly
    }
}

public extension ProviderConfiguration {
    func agentMode(using profile: CapabilityProfile) -> AgentMode {
        profile.agentMode(configHash: capabilityHash)
    }
}

public extension ModelRoute {
    func agentMode(for gateway: GatewayConfiguration, using profile: CapabilityProfile) -> AgentMode {
        profile.agentMode(configHash: capabilityHash(for: gateway))
    }
}
