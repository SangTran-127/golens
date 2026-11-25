import Foundation
import Testing
import GopilotRuntime
@testable import GopilotPolicy

@Suite("Argument normalization")
struct ArgumentNormalizationTests {
    @Test func keyOrderAndWhitespaceDoNotChangeTheHash() {
        let a = #"{"b":1,"a":{"y":2,"x":[1,2]}}"#
        let b = "{ \"a\" : { \"x\" : [1, 2], \"y\" : 2 }, \"b\" : 1 }"
        #expect(ArgumentNormalizer.normalized(a) == ArgumentNormalizer.normalized(b))
        #expect(ArgumentNormalizer.hash(a) == ArgumentNormalizer.hash(b))
    }

    @Test func valuesAndArrayOrderDoChangeTheHash() {
        #expect(ArgumentNormalizer.hash(#"{"a":1}"#) != ArgumentNormalizer.hash(#"{"a":2}"#))
        #expect(ArgumentNormalizer.hash(#"{"a":[1,2]}"#) != ArgumentNormalizer.hash(#"{"a":[2,1]}"#))
        #expect(ArgumentNormalizer.hash(#"{"a":"1"}"#) != ArgumentNormalizer.hash(#"{"a":1}"#))
    }

    @Test func unparseableArgumentsStillHashDeterministically() {
        #expect(ArgumentNormalizer.hash("{oops") == ArgumentNormalizer.hash("{oops"))
        #expect(ArgumentNormalizer.hash("{oops") != ArgumentNormalizer.hash("{oops2"))
    }
}

@Suite("Tool call ledger")
struct ToolCallLedgerTests {
    private let turn = UUID()

    private func call(_ id: String = "call_1", _ args: String = #"{"relativePath":"a.go","startLine":1,"endLine":9}"#) -> ToolCall {
        ToolCall(id: id, name: "read_source", argumentsJSON: args)
    }

    @Test func firstSightExecutesAndSameIDWithSameArgsReusesTheResult() async {
        let ledger = ToolCallLedger()
        #expect(await ledger.begin(turnID: turn, call: call()) == .execute)
        await ledger.markStarted(turnID: turn, callID: "call_1")
        #expect(await ledger.state(turnID: turn, callID: "call_1") == .started)
        let result = ToolResultEnvelope(callID: "call_1", status: .ok, data: "done", evidenceIDs: ["E1"])
        await ledger.complete(turnID: turn, callID: "call_1", result: result)
        #expect(await ledger.state(turnID: turn, callID: "call_1") == .completed)

        let reordered = call("call_1", #"{"endLine":9,"startLine":1,"relativePath":"a.go"}"#)
        #expect(await ledger.begin(turnID: turn, call: reordered) == .reuse(result))
    }

    @Test func sameIDWithDifferentArgsIsAProtocolError() async {
        let ledger = ToolCallLedger()
        _ = await ledger.begin(turnID: turn, call: call())
        let different = call("call_1", #"{"relativePath":"b.go","startLine":1,"endLine":9}"#)
        if case .protocolError = await ledger.begin(turnID: turn, call: different) {} else { Issue.record("expected a protocol error") }
        await ledger.complete(turnID: turn, callID: "call_1", result: ToolResultEnvelope(callID: "call_1", status: .ok, data: "x"))
        if case .protocolError = await ledger.begin(turnID: turn, call: different) {} else { Issue.record("expected a protocol error after completion") }
    }

    @Test func inFlightDuplicatesAreNotExecutedAgain() async {
        let ledger = ToolCallLedger()
        #expect(await ledger.begin(turnID: turn, call: call()) == .execute)
        #expect(await ledger.begin(turnID: turn, call: call()) == .inFlight)
        await ledger.markStarted(turnID: turn, callID: "call_1")
        #expect(await ledger.begin(turnID: turn, call: call()) == .inFlight)
    }

    @Test func idsAreScopedByTurn() async {
        let ledger = ToolCallLedger()
        #expect(await ledger.begin(turnID: turn, call: call()) == .execute)
        #expect(await ledger.begin(turnID: UUID(), call: call()) == .execute)
    }

    @Test func interruptedRunsBecomeUnknownAndAreNeverRerun() async {
        let ledger = ToolCallLedger()
        _ = await ledger.begin(turnID: turn, call: call("a"))
        await ledger.markStarted(turnID: turn, callID: "a")
        _ = await ledger.begin(turnID: turn, call: call("b"))
        _ = await ledger.begin(turnID: turn, call: call("c"))
        await ledger.complete(turnID: turn, callID: "c", result: ToolResultEnvelope(callID: "c", status: .ok, data: "ok"))

        #expect(await ledger.recoverInterrupted() == 2)
        #expect(await ledger.state(turnID: turn, callID: "a") == .unknown)
        #expect(await ledger.state(turnID: turn, callID: "b") == .unknown)
        #expect(await ledger.state(turnID: turn, callID: "c") == .completed)
        #expect(await ledger.begin(turnID: turn, call: call("a")) == .interrupted)
    }

    @Test func completionIsFinal() async {
        let ledger = ToolCallLedger()
        _ = await ledger.begin(turnID: turn, call: call())
        let first = ToolResultEnvelope(callID: "call_1", status: .ok, data: "first")
        await ledger.complete(turnID: turn, callID: "call_1", result: first)
        await ledger.complete(turnID: turn, callID: "call_1", result: ToolResultEnvelope(callID: "call_1", status: .ok, data: "second"))
        #expect(await ledger.begin(turnID: turn, call: call()) == .reuse(first))
    }
}

@Suite("Loop detector")
struct LoopDetectorTests {
    private let args = #"{"query":"Create"}"#

    @Test func thirdIdenticalCallWithoutNewEvidenceStops() {
        var detector = LoopDetector()
        #expect(detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"]) == .proceed)
        #expect(detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"]) == .proceed)
        let third = detector.record(toolName: "search_code", argumentsJSON: #"{ "query" : "Create" }"#, snapshotID: "S1", evidenceIDs: ["E1"])
        guard case .stop(let explanation) = third else {
            Issue.record("expected a stop signal")
            return
        }
        #expect(explanation.contains("search_code"))
        #expect(explanation.contains("no new evidence"))
    }

    @Test func emptyResultsRepeatedAreAlsoALoop() {
        var detector = LoopDetector()
        var verdicts: [LoopVerdict] = []
        for _ in 0..<3 {
            verdicts.append(detector.record(toolName: "find_references", argumentsJSON: args, snapshotID: "S1", evidenceIDs: []))
        }
        #expect(verdicts[0] == .proceed)
        #expect(verdicts[1] == .proceed)
        if case .stop = verdicts[2] {} else { Issue.record("expected stop on the third repeat") }
    }

    @Test func newEvidenceResetsTheCount() {
        var detector = LoopDetector()
        _ = detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"])
        _ = detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"])
        #expect(detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E2"]) == .proceed)
        #expect(detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E2"]) == .proceed)
        if case .stop = detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E2"]) {} else { Issue.record("expected stop") }
    }

    @Test func differentArgsToolOrSnapshotAreSeparateKeys() {
        var detector = LoopDetector()
        for _ in 0..<2 {
            _ = detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"])
        }
        #expect(detector.record(toolName: "search_code", argumentsJSON: #"{"query":"Other"}"#, snapshotID: "S1", evidenceIDs: ["E1"]) == .proceed)
        #expect(detector.record(toolName: "find_symbols", argumentsJSON: args, snapshotID: "S1", evidenceIDs: ["E1"]) == .proceed)
        #expect(detector.record(toolName: "search_code", argumentsJSON: args, snapshotID: "S2", evidenceIDs: ["E1"]) == .proceed)
    }

    @Test func stopDoesNotDependOnAnyPermissionState() {
        var detector = LoopDetector(threshold: 2)
        _ = detector.record(toolName: "read_source", argumentsJSON: args, snapshotID: nil, evidenceIDs: [])
        if case .stop = detector.record(toolName: "read_source", argumentsJSON: args, snapshotID: nil, evidenceIDs: []) {} else { Issue.record("expected stop at threshold 2") }
    }
}
