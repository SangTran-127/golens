import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS\t\(label)")
    } else {
        failures += 1
        print("FAIL\t\(label)")
    }
}

let arguments = CommandLine.arguments
let expectedFile = arguments.count > 1 ? arguments[1] : ""

let local = LSPServerConditions(isRemote: false, isLoading: false)
let remote = LSPServerConditions(isRemote: true, isLoading: false)
let remoteLoading = LSPServerConditions(isRemote: true, isLoading: true)
let localLoading = LSPServerConditions(isRemote: false, isLoading: true)

expect(LSPTimeoutPolicy.seconds(for: .hover, under: local) == 2.5, "hover keeps the 2.5 s local budget")
expect(LSPTimeoutPolicy.seconds(for: .documentHighlight, under: local) == 1, "document highlight keeps the 1 s local budget")
expect(LSPTimeoutPolicy.seconds(for: .inlayHint, under: local) == 1, "inlay hints keep the 1 s local budget")
for kind in LSPRequestKind.allCases {
    let l = LSPTimeoutPolicy.seconds(for: kind, under: local)
    let r = LSPTimeoutPolicy.seconds(for: kind, under: remote)
    let rl = LSPTimeoutPolicy.seconds(for: kind, under: remoteLoading)
    let ll = LSPTimeoutPolicy.seconds(for: kind, under: localLoading)
    expect(r >= l, "\(kind.rawValue): VM budget \(r) s is at least the local \(l) s")
    expect(rl >= r && ll >= l, "\(kind.rawValue): loading budget is at least the settled budget")
}
for kind in [LSPRequestKind.definition, .references, .implementation, .typeDefinition, .hierarchyPrepare, .hierarchyExpand] {
    expect(kind.priority == .navigation, "\(kind.rawValue) is user navigation")
    expect(LSPTimeoutPolicy.seconds(for: kind, under: remote) >= 20, "\(kind.rawValue) gets at least 20 s in the VM")
    expect(LSPTimeoutPolicy.seconds(for: kind, under: remoteLoading) >= 45, "\(kind.rawValue) gets at least 45 s while gopls loads")
}
expect(LSPRequestKind.usageLens.priority == .background, "usage lenses are background work")
expect(UsageCountSource(indexState: "ready") == .index, "usage counts come from the core index when it is ready")
expect(!UsageCountSource.index.needsReferences(isEntryPoint: false), "no usage-lens references request while the index is ready")
expect(UsageCountSource(indexState: "building") == .waitForIndex, "usage counts wait while the index builds")
expect(UsageCountSource(indexState: "unavailable") == .references && UsageCountSource(indexState: nil) == .references, "an unavailable or unanswered index falls back to gopls references")
expect(UsageCountSource.references.needsReferences(isEntryPoint: false) && !UsageCountSource.references.needsReferences(isEntryPoint: true), "the fallback skips entry points as before")
expect(UsageCountSource(indexState: "refreshing") == .refreshingIndex, "a refreshing index is recognised")
expect(UsageCountSource.refreshingIndex.answersFromIndex && UsageCountSource.refreshingIndex.retriesLater, "while the index refreshes its last lenses show and the batch retries")
expect(!UsageCountSource.refreshingIndex.needsReferences(isEntryPoint: false), "no usage-lens references request while the index refreshes")
expect(UsageCountSource.index.answersFromIndex && !UsageCountSource.index.retriesLater, "a ready index answers without a retry")
expect(UsageCountSource.waitForIndex.retriesLater && !UsageCountSource.waitForIndex.answersFromIndex, "a building index shows nothing new and retries")
expect(!UsageCountSource.references.answersFromIndex && !UsageCountSource.references.retriesLater, "the gopls fallback neither reads the index nor waits for it")
expect(["type", "interface", "method"].allSatisfy { !UsageCountSource.needsImplementation(kind: $0, hasIndexedLens: true) }, "no implementation request for a type, interface or method the index has a lens for")
expect(["type", "interface", "method"].allSatisfy { UsageCountSource.needsImplementation(kind: $0, hasIndexedLens: false) }, "a type, interface or method without an index lens falls back to gopls implementation")
expect(!UsageCountSource.needsImplementation(kind: "func", hasIndexedLens: false) && !UsageCountSource.needsImplementation(kind: "func", hasIndexedLens: true), "funcs never ask for implementations")
expect(LSPRequestKind.documentHighlight.priority == .interactive, "document highlight is passive, not navigation")
expect(LSPTimeoutPolicy.seconds(for: .documentHighlight, under: remoteLoading) <= 3, "passive highlight stays short in the VM")
expect(LSPTimeoutPolicy.codeLensConcurrency(under: local) == 6, "local lens concurrency stays 6")
expect(LSPTimeoutPolicy.codeLensConcurrency(under: remote) == 1, "VM lenses are fetched one at a time")
expect(LSPTimeoutPolicy.codeLensRecomputeAfterEdit > LSPTimeoutPolicy.backgroundQuietAfterEdit, "lens counts are recomputed only after a typing pause longer than the background quiet period")
expect(LSPTimeoutPolicy.timeout(for: .references, under: remote) == .seconds(30), "Duration conversion is exact")
expect(LSPTimeoutPolicy.backgroundMayRun(secondsSinceEdit: nil), "background work runs when nothing was typed")
expect(!LSPTimeoutPolicy.backgroundMayRun(secondsSinceEdit: 0.2), "background work waits while the user types")
expect(LSPTimeoutPolicy.backgroundMayRun(secondsSinceEdit: LSPTimeoutPolicy.backgroundQuietAfterEdit), "background work resumes after the quiet period")
expect((1...5).map { LSPTimeoutPolicy.codeLensRetryDelay(afterFailedRounds: $0, resumeDelay: 1.5, maxRounds: 5) } == [1.5, 3, 6, 12, 24], "lens retries back off from 1.5 s to 24 s")
expect(LSPTimeoutPolicy.codeLensRetryDelay(afterFailedRounds: 9, resumeDelay: 1.5, maxRounds: 5) == 48, "lens retries after the last round wait 48 s, even when scrolling")

expect(LSPRequestFailure.fromResponseError(code: -32800, message: "x") == .cancelled, "RequestCancelled maps to cancelled")
expect(LSPRequestFailure.fromResponseError(code: -32801, message: "x") == .contentModified, "ContentModified maps to contentModified")
expect(LSPRequestFailure.fromResponseError(code: 0, message: "no identifier found").meansNoResult, "gopls no identifier found means no result")
expect(LSPRequestFailure.fromResponseError(code: 0, message: "identifier not found").meansNoResult, "gopls identifier not found means no result")
expect(!LSPRequestFailure.fromResponseError(code: 0, message: "no package metadata for file file:///x.go").meansNoResult, "missing package metadata is retryable")
expect(!LSPRequestFailure.timedOut(seconds: 30, whileLoading: false).meansNoResult, "a timeout is never an empty result")
expect(!LSPRequestFailure.timedOut(seconds: 30, whileLoading: false).isSilent, "a timeout is shown to the user")
expect(LSPRequestFailure.preempted.isSilent && LSPRequestFailure.cancelled.isSilent, "cancel and preempt stay silent")
expect(LSPRequestFailure.timedOut(seconds: 30, whileLoading: true).explanation.contains("still loading"), "a timeout while loading says gopls is loading")
expect(LSPRequestFailure.timedOut(seconds: 30, whileLoading: false).explanation == "gopls didn’t answer within 30 seconds.", "a timeout names the budget")
expect((LSPRequestFailure.timedOut(seconds: 5, whileLoading: false) as NSError).localizedDescription == "cancelled", "legacy description for Gopilot timeouts is kept")
expect((LSPRequestFailure.serverNotRunning as NSError).localizedDescription.contains("not running"), "legacy description for a stopped server is kept")

let samples = [
    "/Users/dev/My Project (copy)!/main.go",
    "/Users/dev/T\u{00E0}i li\u{1EC7}u/d\u{1EF1} \u{00E1}n/main.go",
    "/Users/dev/Ta\u{0300}i/x.go",
    "/Users/dev/a+b,c;d=e@f$g&h:i/~j_k-l.m.go",
    "/Users/dev/100% done/#hash?/[x]{y}'z\"q`*.go",
    "/Users/dev/emoji \u{1F600}/main.go",
]
if !expectedFile.isEmpty, let expected = try? String(contentsOfFile: expectedFile, encoding: .utf8) {
    let lines = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, sample) in samples.enumerated() where index < lines.count {
        let got = LSPFileURI.uri(forPath: sample)
        expect(got == lines[index], "URI matches Go url.URL for \(sample): \(got)")
        expect(LSPFileURI.path(fromURI: got) == sample.precomposedStringWithCanonicalMapping, "URI decodes back to the NFC path for \(sample)")
    }
} else {
    expect(false, "expected Go URIs were provided")
}
let nfd = "/Users/dev/Ta\u{0300}i/x.go"
expect(LSPFileURI.uri(forPath: nfd).contains("%C3%A0"), "NFD input is encoded as NFC like Go")
expect(LSPFileURI.path(fromURI: "file:///Users/dev/Ta%CC%80i/x.go") == "/Users/dev/T\u{00E0}i/x.go", "NFD percent-encoding decodes to NFC")
expect(LSPFileURI.path(fromURI: "file://localhost/tmp/a%20b.go") == "/tmp/a b.go", "localhost authority is accepted")
expect(LSPFileURI.path(fromURI: "file:///tmp/100%zz.go") == "/tmp/100%zz.go", "an invalid escape is kept as written")
expect(LSPFileURI.path(fromURI: "file:///tmp/a%28b%29.go") == "/tmp/a(b).go", "escaped parentheses decode")
expect(LSPFileURI.path(fromURI: "untitled:Untitled-1") == "untitled:Untitled-1", "non-file URIs pass through")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
