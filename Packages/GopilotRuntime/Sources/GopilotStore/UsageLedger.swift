import Foundation
import GopilotRuntime

public enum UsageSource: String, Sendable, Codable {
    case provided
    case estimated
    case unknown
}

public struct TaggedCount: Sendable, Equatable, Codable {
    public let value: Int?
    public let source: UsageSource

    public init(value: Int?, source: UsageSource) {
        self.value = value
        self.source = value == nil ? .unknown : source
    }

    public static let unknown = TaggedCount(value: nil, source: .unknown)

    static func sum(_ counts: [TaggedCount]) -> TaggedCount {
        let known = counts.compactMap(\.value)
        guard !known.isEmpty else { return .unknown }
        let allProvided = counts.allSatisfy { $0.source == .provided }
        return TaggedCount(value: known.reduce(0, +), source: allProvided ? .provided : .estimated)
    }
}

public struct PricingMetadata: Sendable, Equatable, Codable {
    public var modelID: String
    public var inputPerMillionTokens: Decimal
    public var outputPerMillionTokens: Decimal
    public var currency: String
    public var enteredAt: Date?

    public init(modelID: String, inputPerMillionTokens: Decimal, outputPerMillionTokens: Decimal, currency: String, enteredAt: Date?) {
        self.modelID = modelID
        self.inputPerMillionTokens = inputPerMillionTokens
        self.outputPerMillionTokens = outputPerMillionTokens
        self.currency = currency
        self.enteredAt = enteredAt
    }
}

public enum CostUnknownReason: String, Sendable, Codable {
    case noPricing
    case pricingMissingTimestamp
    case tokensUnknown
}

public enum CostEstimate: Sendable, Equatable, Codable {
    case known(amount: Decimal, currency: String, basis: UsageSource)
    case unknown(CostUnknownReason)
}

public struct TurnUsageRecord: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let turnID: UUID
    public let conversationID: UUID
    public let providerID: String
    public let modelID: String
    public let input: TaggedCount
    public let output: TaggedCount
    public let modelRequests: Int
    public let toolCalls: Int
    public let durationSeconds: Double?
    public let recordedAt: Date

    public init(turnID: UUID, conversationID: UUID, providerID: String, modelID: String, input: TaggedCount, output: TaggedCount, modelRequests: Int, toolCalls: Int, durationSeconds: Double?, recordedAt: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.turnID = turnID
        self.conversationID = conversationID
        self.providerID = providerID
        self.modelID = modelID
        self.input = input
        self.output = output
        self.modelRequests = modelRequests
        self.toolCalls = toolCalls
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
    }

    public init(turn: Turn, conversationID: UUID, providerID: String, modelID: String, recordedAt: Date) {
        let usage = turn.usage
        let complete = usage.modelRequests > 0 && usage.requestsWithUsage >= usage.modelRequests
        func tag(_ value: Int?) -> TaggedCount {
            guard let value else { return .unknown }
            return TaggedCount(value: value, source: complete ? .provided : .estimated)
        }
        self.init(turnID: turn.id, conversationID: conversationID, providerID: providerID, modelID: modelID, input: tag(usage.inputTokens), output: tag(usage.outputTokens), modelRequests: usage.modelRequests, toolCalls: turn.toolLifecycles.count, durationSeconds: turn.durationSeconds, recordedAt: recordedAt)
    }
}

public struct UsageTotals: Sendable, Equatable {
    public let turnCount: Int
    public let modelRequests: Int
    public let toolCalls: Int
    public let durationSeconds: Double
    public let input: TaggedCount
    public let output: TaggedCount
    public let cost: CostEstimate
    public let knownCostSubtotal: Decimal?
    public let turnsWithUnknownCost: Int
}

public struct UsageLimits: Sendable, Equatable {
    public var maxModelRequests: Int?
    public var maxOutputTokens: Int?
    public var maxDurationSeconds: Double?
    public var softBudget: Decimal?

    public init(maxModelRequests: Int? = nil, maxOutputTokens: Int? = nil, maxDurationSeconds: Double? = nil, softBudget: Decimal? = nil) {
        self.maxModelRequests = maxModelRequests
        self.maxOutputTokens = maxOutputTokens
        self.maxDurationSeconds = maxDurationSeconds
        self.softBudget = softBudget
    }
}

public enum LimitCheck: Sendable, Equatable {
    case notSet
    case within
    case exceeded
    case notEvaluable
}

public struct SoftBudgetStatus: Sendable, Equatable {
    public let check: LimitCheck
    public let isSoft: Bool
    public let estimatedCost: CostEstimate
}

public struct LimitReport: Sendable, Equatable {
    public let requests: LimitCheck
    public let outputTokens: LimitCheck
    public let duration: LimitCheck
    public let softBudget: SoftBudgetStatus
}

public struct UsageLedger: Sendable, Codable {
    public private(set) var records: [TurnUsageRecord] = []
    public private(set) var pricing: [String: PricingMetadata] = [:]

    public init() {}

    public mutating func record(_ record: TurnUsageRecord) {
        if let index = records.firstIndex(where: { $0.turnID == record.turnID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    public mutating func setPricing(_ metadata: PricingMetadata) {
        pricing[metadata.modelID] = metadata
    }

    public func cost(of record: TurnUsageRecord) -> CostEstimate {
        guard let price = pricing[record.modelID] else { return .unknown(.noPricing) }
        guard price.enteredAt != nil else { return .unknown(.pricingMissingTimestamp) }
        guard let input = record.input.value, let output = record.output.value else { return .unknown(.tokensUnknown) }
        let million = Decimal(1_000_000)
        let amount = Decimal(input) * price.inputPerMillionTokens / million + Decimal(output) * price.outputPerMillionTokens / million
        let basis: UsageSource = record.input.source == .provided && record.output.source == .provided ? .provided : .estimated
        return .known(amount: amount, currency: price.currency, basis: basis)
    }

    public func totals(conversationID: UUID? = nil) -> UsageTotals {
        let selected = records.filter { conversationID == nil || $0.conversationID == conversationID }
        var subtotal = Decimal(0)
        var currency: String?
        var unknownCount = 0
        var firstUnknown: CostUnknownReason?
        var mixedCurrency = false
        for record in selected {
            switch cost(of: record) {
            case .known(let amount, let code, _):
                if let currency, currency != code { mixedCurrency = true }
                currency = currency ?? code
                subtotal += amount
            case .unknown(let reason):
                unknownCount += 1
                firstUnknown = firstUnknown ?? reason
            }
        }
        let cost: CostEstimate
        if let firstUnknown {
            cost = .unknown(firstUnknown)
        } else if let currency, !mixedCurrency {
            let allProvided = selected.allSatisfy { $0.input.source == .provided && $0.output.source == .provided }
            cost = .known(amount: subtotal, currency: currency, basis: allProvided ? .provided : .estimated)
        } else {
            cost = .unknown(.noPricing)
        }
        return UsageTotals(
            turnCount: selected.count,
            modelRequests: selected.reduce(0) { $0 + $1.modelRequests },
            toolCalls: selected.reduce(0) { $0 + $1.toolCalls },
            durationSeconds: selected.compactMap(\.durationSeconds).reduce(0, +),
            input: TaggedCount.sum(selected.map(\.input)),
            output: TaggedCount.sum(selected.map(\.output)),
            cost: cost,
            knownCostSubtotal: currency == nil || mixedCurrency ? nil : subtotal,
            turnsWithUnknownCost: unknownCount
        )
    }

    public func evaluate(_ limits: UsageLimits, conversationID: UUID? = nil) -> LimitReport {
        let totals = totals(conversationID: conversationID)
        let requests = Self.check(limit: limits.maxModelRequests.map(Double.init), value: Double(totals.modelRequests))
        let output = Self.check(limit: limits.maxOutputTokens.map(Double.init), value: totals.output.value.map(Double.init))
        let duration = Self.check(limit: limits.maxDurationSeconds, value: totals.durationSeconds)
        let budget: LimitCheck
        if let softBudget = limits.softBudget {
            if case .known(let amount, _, _) = totals.cost {
                budget = amount > softBudget ? .exceeded : .within
            } else {
                budget = .notEvaluable
            }
        } else {
            budget = .notSet
        }
        return LimitReport(requests: requests, outputTokens: output, duration: duration, softBudget: SoftBudgetStatus(check: budget, isSoft: true, estimatedCost: totals.cost))
    }

    private static func check(limit: Double?, value: Double?) -> LimitCheck {
        guard let limit else { return .notSet }
        guard let value else { return .notEvaluable }
        return value > limit ? .exceeded : .within
    }
}

public struct TraceEntry: Sendable, Equatable, Codable {
    public let at: Date
    public let turnID: UUID
    public let sequence: Int
    public let kind: AgentEventKind
    public let toolName: String?
    public let status: String?
    public let errorCode: String?
    public let elapsedMilliseconds: Int
    public let counts: [String: Int]
    public let sizes: [String: Int]
}

public struct LocalTrace: Sendable, Codable {
    public static let defaultCapacity = 2000

    public private(set) var entries: [TraceEntry] = []
    private var capacity: Int
    private var turnStarts: [UUID: Date] = [:]
    private var textDeltaCounts: [UUID: Int] = [:]
    private var textDeltaBytes: [UUID: Int] = [:]
    private var toolCallCounts: [UUID: Int] = [:]

    public init(capacity: Int = LocalTrace.defaultCapacity) {
        self.capacity = capacity
    }

    public mutating func record(_ event: AgentEvent) {
        if event.kind == .turnStarted { turnStarts[event.turnID] = event.timestamp }
        if event.kind == .textDelta {
            textDeltaCounts[event.turnID, default: 0] += 1
            textDeltaBytes[event.turnID, default: 0] += event.payload["text"]?.utf8.count ?? 0
            return
        }
        if event.kind == .toolStarted { toolCallCounts[event.turnID, default: 0] += 1 }
        var counts: [String: Int] = [:]
        var sizes: [String: Int] = [:]
        if event.kind.isTerminal {
            counts["textDeltas"] = textDeltaCounts[event.turnID] ?? 0
            counts["toolCalls"] = toolCallCounts[event.turnID] ?? 0
            sizes["textBytes"] = textDeltaBytes[event.turnID] ?? 0
        }
        let elapsed = turnStarts[event.turnID].map { Int(event.timestamp.timeIntervalSince($0) * 1000) } ?? 0
        let entry = TraceEntry(
            at: event.timestamp,
            turnID: event.turnID,
            sequence: event.sequence,
            kind: event.kind,
            toolName: event.payload["name"],
            status: event.payload["status"],
            errorCode: event.payload["errorCode"].flatMap { $0.isEmpty ? nil : $0 } ?? event.payload["code"],
            elapsedMilliseconds: max(elapsed, 0),
            counts: counts,
            sizes: sizes
        )
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if event.kind.isTerminal {
            turnStarts[event.turnID] = nil
            textDeltaCounts[event.turnID] = nil
            textDeltaBytes[event.turnID] = nil
            toolCallCounts[event.turnID] = nil
        }
    }
}
