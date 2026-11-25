import Foundation
import Testing
import GopilotRuntime
@testable import GopilotStore

@Suite("Usage ledger and trace")
struct UsageLedgerTests {
    private let conversation = UUID()
    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(model: String = "m1", input: Int? = 1000, output: Int? = 500, source: UsageSource = .provided, requests: Int = 1, duration: Double? = 2) -> TurnUsageRecord {
        TurnUsageRecord(turnID: UUID(), conversationID: conversation, providerID: "p", modelID: model, input: TaggedCount(value: input, source: source), output: TaggedCount(value: output, source: source), modelRequests: requests, toolCalls: 1, durationSeconds: duration, recordedAt: stamp)
    }

    private func pricing(model: String = "m1", enteredAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> PricingMetadata {
        PricingMetadata(modelID: model, inputPerMillionTokens: 2, outputPerMillionTokens: 10, currency: "USD", enteredAt: enteredAt)
    }

    @Test func costIsUnknownNeverZeroWithoutPricingForTheSameModelAndTimestamp() {
        var ledger = UsageLedger()
        let turn = record()
        ledger.record(turn)
        #expect(ledger.cost(of: turn) == .unknown(.noPricing))

        ledger.setPricing(pricing(model: "other"))
        #expect(ledger.cost(of: turn) == .unknown(.noPricing))

        ledger.setPricing(pricing(enteredAt: nil))
        #expect(ledger.cost(of: turn) == .unknown(.pricingMissingTimestamp))

        let totals = ledger.totals()
        #expect(totals.cost == .unknown(.pricingMissingTimestamp))
        #expect(totals.knownCostSubtotal == nil)
    }

    @Test func costComputedFromPricingForTheSameModel() {
        var ledger = UsageLedger()
        ledger.setPricing(pricing())
        let provided = record(input: 1_000_000, output: 500_000)
        let estimated = record(input: 1_000_000, output: 500_000, source: .estimated)
        ledger.record(provided)
        ledger.record(estimated)
        #expect(ledger.cost(of: provided) == .known(amount: 7, currency: "USD", basis: .provided))
        #expect(ledger.cost(of: estimated) == .known(amount: 7, currency: "USD", basis: .estimated))
        #expect(ledger.totals().cost == .known(amount: 14, currency: "USD", basis: .estimated))
    }

    @Test func unknownTokensMakeCostUnknownAndTotalsReportTheKnownSubtotal() {
        var ledger = UsageLedger()
        ledger.setPricing(pricing())
        ledger.record(record(input: 1_000_000, output: 0))
        let unknown = record(input: nil, output: nil, source: .unknown)
        ledger.record(unknown)
        #expect(ledger.cost(of: unknown) == .unknown(.tokensUnknown))
        let totals = ledger.totals()
        #expect(totals.cost == .unknown(.tokensUnknown))
        #expect(totals.knownCostSubtotal == 2)
        #expect(totals.turnsWithUnknownCost == 1)
        #expect(totals.input.source == .estimated)
    }

    @Test func requestOutputAndTimeLimitsWorkWithoutPricingAndSoftBudgetIsFlaggedSoft() {
        var ledger = UsageLedger()
        ledger.record(record(output: 800, requests: 3, duration: 90))
        let report = ledger.evaluate(UsageLimits(maxModelRequests: 2, maxOutputTokens: 1000, maxDurationSeconds: 60, softBudget: 5))
        #expect(report.requests == .exceeded)
        #expect(report.outputTokens == .within)
        #expect(report.duration == .exceeded)
        #expect(report.softBudget.check == .notEvaluable)
        #expect(report.softBudget.isSoft)
        #expect(report.softBudget.estimatedCost == .unknown(.noPricing))

        let none = ledger.evaluate(UsageLimits())
        #expect(none.requests == .notSet)
        #expect(none.softBudget.check == .notSet)

        ledger.setPricing(pricing())
        let priced = ledger.evaluate(UsageLimits(softBudget: 0.001))
        #expect(priced.softBudget.check == .exceeded)
        #expect(priced.softBudget.isSoft)
    }

    @Test func outputLimitIsNotEvaluableWhenProviderGaveNoUsage() {
        var ledger = UsageLedger()
        ledger.record(record(input: nil, output: nil, source: .unknown))
        #expect(ledger.evaluate(UsageLimits(maxOutputTokens: 10)).outputTokens == .notEvaluable)
    }

    @Test func turnUsageIsTaggedProvidedOnlyWhenEveryRequestReportedIt() {
        var complete = Turn(id: UUID(), userPrompt: "p", startedAt: stamp)
        complete.usage = TurnUsage(inputTokens: 30, outputTokens: 8, modelRequests: 2, requestsWithUsage: 2)
        complete.endedAt = stamp.addingTimeInterval(4)
        let provided = TurnUsageRecord(turn: complete, conversationID: conversation, providerID: "p", modelID: "m1", recordedAt: stamp)
        #expect(provided.input == TaggedCount(value: 30, source: .provided))
        #expect(provided.durationSeconds == 4)

        var partial = complete
        partial.usage = TurnUsage(inputTokens: 10, outputTokens: nil, modelRequests: 2, requestsWithUsage: 1)
        let estimated = TurnUsageRecord(turn: partial, conversationID: conversation, providerID: "p", modelID: "m1", recordedAt: stamp)
        #expect(estimated.input == TaggedCount(value: 10, source: .estimated))
        #expect(estimated.output == .unknown)
    }

    @Test func ledgerRoundTripsThroughCodable() throws {
        var ledger = UsageLedger()
        ledger.setPricing(pricing())
        ledger.record(record())
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: data)
        #expect(decoded.records == ledger.records)
        #expect(decoded.pricing == ledger.pricing)
    }

    @Test func traceKeepsOnlyIdentifiersTimingsToolNamesStatusCountsAndSizes() throws {
        var trace = LocalTrace()
        let turn = UUID()
        let secret = "sk-SECRET-VALUE"
        trace.record(event(turn, 1, .turnStarted, ["prompt": secret]))
        trace.record(event(turn, 2, .textDelta, ["text": "answer containing \(secret)"]))
        trace.record(event(turn, 3, .textDelta, ["text": "more"]))
        trace.record(event(turn, 4, .toolRequested, ["callID": "c1", "name": "read_file", "argumentsJSON": #"{"path":"\#(secret)"}"#]))
        trace.record(event(turn, 5, .toolStarted, ["callID": "c1", "name": "read_file"]))
        trace.record(event(turn, 6, .toolFinished, ["callID": "c1", "status": "error", "errorCode": "timeout", "Authorization": "Bearer \(secret)"]))
        trace.record(event(turn, 7, .turnCompleted))

        let encoded = try #require(String(data: JSONEncoder().encode(trace), encoding: .utf8))
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("Bearer"))
        #expect(!encoded.contains("answer containing"))
        #expect(trace.entries.map(\.kind) == [.turnStarted, .toolRequested, .toolStarted, .toolFinished, .turnCompleted])
        let finished = try #require(trace.entries.first { $0.kind == .toolFinished })
        #expect(finished.toolName == nil)
        #expect(finished.status == "error")
        #expect(finished.errorCode == "timeout")
        #expect(finished.elapsedMilliseconds == 5000)
        let requested = try #require(trace.entries.first { $0.kind == .toolRequested })
        #expect(requested.toolName == "read_file")
        let terminal = try #require(trace.entries.last)
        #expect(terminal.counts["textDeltas"] == 2)
        #expect(terminal.counts["toolCalls"] == 1)
        #expect(terminal.sizes["textBytes"] == ("answer containing \(secret)".utf8.count + 4))
    }

    @Test func traceIsBounded() {
        var trace = LocalTrace(capacity: 5)
        let turn = UUID()
        for index in 1...20 { trace.record(event(turn, index, .activity, ["label": "x"])) }
        #expect(trace.entries.count == 5)
        #expect(trace.entries.first?.sequence == 16)
    }
}
