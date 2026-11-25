import Foundation
import GopilotRuntime

public enum UsageValue: Sendable, Equatable {
    case reported(Int)
    case estimated(Int)
    case unknown

    public var tokens: Int? {
        switch self {
        case .reported(let value), .estimated(let value): return value
        case .unknown: return nil
        }
    }

    public var displayText: String {
        switch self {
        case .reported(let value): return value.formatted(.number.grouping(.automatic))
        case .estimated(let value): return "~" + value.formatted(.number.grouping(.automatic))
        case .unknown: return "Unknown"
        }
    }

    public func combined(with other: UsageValue) -> UsageValue {
        switch (self, other) {
        case (.unknown, _), (_, .unknown):
            return .unknown
        case (.reported(let lhs), .reported(let rhs)):
            return .reported(lhs + rhs)
        case (.estimated(let lhs), .reported(let rhs)),
             (.reported(let lhs), .estimated(let rhs)),
             (.estimated(let lhs), .estimated(let rhs)):
            return .estimated(lhs + rhs)
        }
    }

    init(provider: Int?, estimate: Int?) {
        if let provider {
            self = .reported(provider)
        } else if let estimate {
            self = .estimated(estimate)
        } else {
            self = .unknown
        }
    }
}

public enum CostUnknownReason: Sendable, Equatable {
    case noPricing
    case modelMismatch
    case usageUnknown
}

public enum CostValue: Sendable, Equatable {
    case estimated(amount: Decimal, currency: String, pricedAt: Date)
    case unknown(CostUnknownReason)

    public func combined(with other: CostValue) -> CostValue {
        switch (self, other) {
        case (.unknown(let reason), _), (_, .unknown(let reason)):
            return .unknown(reason)
        case (.estimated(let lhs, let currency, let lhsDate), .estimated(let rhs, let otherCurrency, let rhsDate)):
            guard currency == otherCurrency else { return .unknown(.noPricing) }
            return .estimated(amount: lhs + rhs, currency: currency, pricedAt: min(lhsDate, rhsDate))
        }
    }
}

public struct TurnUsage: Sendable, Equatable {
    public let inputTokens: UsageValue
    public let outputTokens: UsageValue

    public init(inputTokens: UsageValue, outputTokens: UsageValue) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public init(provider: TokenUsage?, estimatedInput: Int? = nil, estimatedOutput: Int? = nil) {
        inputTokens = UsageValue(provider: provider?.inputTokens, estimate: estimatedInput)
        outputTokens = UsageValue(provider: provider?.outputTokens, estimate: estimatedOutput)
    }

    public static let unknown = TurnUsage(inputTokens: .unknown, outputTokens: .unknown)

    public static func from(events: [ProviderEvent], estimatedInput: Int? = nil, estimatedOutput: Int? = nil) -> TurnUsage {
        var latest: TokenUsage?
        for case .usage(let usage) in events {
            latest = usage
        }
        return TurnUsage(provider: latest, estimatedInput: estimatedInput, estimatedOutput: estimatedOutput)
    }

    public func merged(with other: TurnUsage) -> TurnUsage {
        TurnUsage(
            inputTokens: inputTokens.combined(with: other.inputTokens),
            outputTokens: outputTokens.combined(with: other.outputTokens)
        )
    }

    public var totalTokens: UsageValue {
        inputTokens.combined(with: outputTokens)
    }

    public func cost(pricing: ProviderPricing?, modelID: String) -> CostValue {
        guard let pricing else { return .unknown(.noPricing) }
        guard pricing.modelID == modelID else { return .unknown(.modelMismatch) }
        guard let input = inputTokens.tokens, let output = outputTokens.tokens else {
            return .unknown(.usageUnknown)
        }
        let million = Decimal(1_000_000)
        let amount = Decimal(input) * pricing.inputPerMillionTokens / million
            + Decimal(output) * pricing.outputPerMillionTokens / million
        return .estimated(amount: amount, currency: pricing.currency, pricedAt: pricing.capturedAt)
    }
}

public struct UsageTracker: Sendable, Equatable {
    public private(set) var turns: [TurnUsage]

    public init(turns: [TurnUsage] = []) {
        self.turns = turns
    }

    public mutating func record(_ usage: TurnUsage) {
        turns.append(usage)
    }

    public var total: TurnUsage? {
        guard var running = turns.first else { return nil }
        for turn in turns.dropFirst() {
            running = running.merged(with: turn)
        }
        return running
    }

    public func totalCost(pricing: ProviderPricing?, modelID: String) -> CostValue? {
        guard var running = turns.first?.cost(pricing: pricing, modelID: modelID) else { return nil }
        for turn in turns.dropFirst() {
            running = running.combined(with: turn.cost(pricing: pricing, modelID: modelID))
        }
        return running
    }
}
