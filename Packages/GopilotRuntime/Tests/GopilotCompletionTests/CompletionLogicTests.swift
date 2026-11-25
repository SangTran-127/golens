import Foundation
import XCTest
import GopilotPolicy
import GopilotProvider
@testable import GopilotCompletion

final class CompletionContextBuilderTests: XCTestCase {
    private func snapshot(_ prefix: String, _ suffix: String, path: String = "store.go", head: String = "", start: Bool = true, end: Bool = true) -> CompletionSnapshot {
        CompletionSnapshot(relativePath: path, prefix: prefix, suffix: suffix, prefixStartsAtFileStart: start, suffixEndsAtFileEnd: end, fileHead: head)
    }

    func testBuildsSingleLineContextWhenClosersFollowCursor() throws {
        let builder = CompletionContextBuilder(pathPolicy: nil)
        let context = try XCTUnwrap(builder.build(snapshot("package main\n\nfunc f() {\n\tfmt.Println(", ")\n}\n")).context)
        XCTAssertFalse(context.multiline)
        XCTAssertEqual(context.linePrefix, "\tfmt.Println(")
        XCTAssertEqual(context.lineSuffix, ")")
        XCTAssertEqual(context.anchorIndent, "\t")
    }

    func testMultilineOnlyWhenRestOfLineIsEmpty() throws {
        let builder = CompletionContextBuilder(pathPolicy: nil)
        XCTAssertEqual(builder.build(snapshot("func f() {\n\t", "\n}\n")).context?.multiline, true)
        let single = CompletionContextBuilder(pathPolicy: nil, length: .singleLine)
        XCTAssertEqual(single.build(snapshot("func f() {\n\t", "\n}\n")).context?.multiline, false)
    }

    func testSkipsWhenOrdinaryTextFollowsCursor() {
        let builder = CompletionContextBuilder(pathPolicy: nil)
        XCTAssertEqual(builder.build(snapshot("x := ", "foo()\n")).skipReason, .textAfterCursor)
    }

    func testSkipsNonGoAndSensitivePaths() {
        let builder = CompletionContextBuilder(pathPolicy: nil)
        XCTAssertEqual(builder.build(snapshot("a", "", path: "README.md")).skipReason, .unsupportedLanguage)
        XCTAssertEqual(builder.build(snapshot("a", "", path: ".env")).skipReason, .unsupportedLanguage)
        XCTAssertEqual(builder.build(snapshot("a", "", path: "secrets/.env.go")).skipReason, .excludedPath)
    }

    func testPathPolicyDeniesUserPatternsAndOutsideRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PathPolicy(workspaceRoots: [root], userExcludePatterns: ["internal/secret/**"])
        let builder = CompletionContextBuilder(pathPolicy: policy)
        XCTAssertNotNil(builder.build(snapshot("a", "", path: "main.go")).context)
        XCTAssertEqual(builder.build(snapshot("a", "", path: "internal/secret/keys.go")).skipReason, .excludedPath)
        XCTAssertEqual(builder.build(snapshot("a", "", path: "../other/main.go")).skipReason, .excludedPath)
    }

    func testLineBoundaryWindowsDropPartialLines() throws {
        let builder = CompletionContextBuilder(pathPolicy: nil)
        let context = try XCTUnwrap(builder.build(snapshot("tial line\nfunc f() {\n\treturn ", "\n}\nfunc g() {\n\tpart", start: false, end: false)).context)
        XCTAssertEqual(context.prefix, "func f() {\n\treturn ")
        XCTAssertEqual(context.suffix, "\n}\nfunc g() {\n")
    }

    func testWindowLimitsAreApplied() throws {
        let limits = CompletionContextLimits(prefixCharacters: 20, suffixCharacters: 10)
        let builder = CompletionContextBuilder(limits: limits, pathPolicy: nil)
        let prefix = String(repeating: "aaaa\n", count: 20) + "\treturn "
        let suffix = "\n" + String(repeating: "bbbb\n", count: 20)
        let context = try XCTUnwrap(builder.build(snapshot(prefix, suffix)).context)
        XCTAssertLessThanOrEqual(context.prefix.count, 20)
        XCTAssertTrue(context.prefix.hasSuffix("\treturn "))
        XCTAssertLessThanOrEqual(context.suffix.count, 10)
    }

    func testIncludesPackageAndImportsWhenOutsideWindow() throws {
        let head = "package store\n\nimport (\n\t\"errors\"\n\t\"sync\"\n)\n\ntype Store struct{}\n"
        let builder = CompletionContextBuilder(pathPolicy: nil)
        let context = try XCTUnwrap(builder.build(snapshot("x\nfunc (s *Store) Get() {\n\t", "\n}\n", head: head, start: false)).context)
        XCTAssertEqual(context.header, "package store\nimport (\n\t\"errors\"\n\t\"sync\"\n)")
        let atStart = try XCTUnwrap(builder.build(snapshot(head + "func f() {\n\t", "\n}\n", head: head)).context)
        XCTAssertNil(atStart.header)
    }

    func testSecretNearCursorSkipsRequest() {
        let builder = CompletionContextBuilder(secretFilter: SecretFilter(literalSecrets: ["sk-live-0123456789abcdef"]), pathPolicy: nil)
        XCTAssertEqual(builder.build(snapshot("func f() {\n\tkey := \"sk-live-0123456789abcdef", "\"\n}\n")).skipReason, .secretNearCursor)
    }

    func testSecretFarFromCursorIsRedacted() throws {
        let builder = CompletionContextBuilder(secretFilter: SecretFilter(literalSecrets: ["sk-live-0123456789abcdef"]), pathPolicy: nil)
        let far = "var key = \"sk-live-0123456789abcdef\"\n" + String(repeating: "// filler line\n", count: 30) + "func f() {\n\t"
        let context = try XCTUnwrap(builder.build(snapshot(far, "\n}\n")).context)
        XCTAssertFalse(context.prefix.contains("sk-live-0123456789abcdef"))
        XCTAssertTrue(context.prefix.contains("[REDACTED"))
    }
}

final class CompletionEncoderTests: XCTestCase {
    private let context = CompletionContext(relativePath: "math.go", prefix: "func add(a, b int) int {\n\t", suffix: "\n}\n", multiline: false)

    func testChatBodyGolden() throws {
        let data = try CompletionEncoder.encode(context, options: CompletionRequestOptions(model: "mistralai/codestral-2508", stream: true))
        let expected = #"{"max_tokens":64,"messages":[{"content":"You are a code completion engine inside a Go editor. Output only the exact text that replaces <CURSOR> so the file compiles. No prose, no markdown fences, do not repeat code before or after the cursor. Complete only the rest of the current line.","role":"system"},{"content":"// path: math.go\nfunc add(a, b int) int {\n\t<CURSOR>\n}\n","role":"user"}],"model":"mistralai/codestral-2508","stream":true,"temperature":0}"#
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    func testChatBodyNeverSendsToolsOrReasoning() throws {
        let body = CompletionEncoder.body(context, options: CompletionRequestOptions(model: "m", maxTokensParameter: .maxCompletionTokens, stream: false))
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 64)
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testMultilineUsesLargerBudget() {
        var multi = context
        multi.multiline = true
        let body = CompletionEncoder.body(multi, options: CompletionRequestOptions(model: "m"))
        XCTAssertEqual(body["max_tokens"] as? Int, 256)
    }

    func testFIMBodyGolden() throws {
        var withHeader = context
        withHeader.header = "package math"
        let data = try CompletionEncoder.encode(withHeader, options: CompletionRequestOptions(model: "codestral-latest", dialect: .fillInTheMiddle, stream: true))
        let expected = #"{"max_tokens":64,"model":"codestral-latest","prompt":"package math\n\nfunc add(a, b int) int {\n\t","stop":["\n"],"stream":true,"suffix":"\n}\n","temperature":0}"#
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    func testFIMEndpointDerivedFromChatURL() {
        let chat = URL(string: "https://proxy.example.com/v1/chat/completions")!
        XCTAssertEqual(CompletionEncoder.endpointURL(chatCompletionsURL: chat, dialect: .fillInTheMiddle).absoluteString, "https://proxy.example.com/v1/completions")
        XCTAssertEqual(CompletionEncoder.endpointURL(chatCompletionsURL: chat, dialect: .chatHoleFill), chat)
    }
}

final class CompletionPostProcessorTests: XCTestCase {
    private func ctx(_ prefix: String, _ suffix: String, multiline: Bool) -> CompletionContext {
        CompletionContext(relativePath: "a.go", prefix: prefix, suffix: suffix, multiline: multiline)
    }

    func testSingleLineCutsAtNewline() {
        XCTAssertEqual(CompletionPostProcessor.process("return a + b\n}\n", context: ctx("func add(a, b int) int {\n\t", "\n}\n", multiline: false)), "return a + b")
    }

    func testStripsFencesAndTags() {
        let context = ctx("func add(a, b int) int {\n\t", "\n}\n", multiline: false)
        XCTAssertEqual(CompletionPostProcessor.process("```go\nreturn a + b\n```", context: context), "return a + b")
        XCTAssertEqual(CompletionPostProcessor.process("<COMPLETION>return a + b</COMPLETION>", context: context), "return a + b")
    }

    func testRemovesEchoedLinePrefix() {
        let context = ctx("func add(a, b int) int {\n\treturn ", "\n}\n", multiline: false)
        XCTAssertEqual(CompletionPostProcessor.process("return a + b", context: context), "a + b")
    }

    func testSuffixOverlapForClosers() {
        let context = ctx("func f() {\n\tfoo(", ")\n}\n", multiline: false)
        XCTAssertEqual(CompletionPostProcessor.process("a, b)", context: context), "a, b")
        XCTAssertEqual(CompletionPostProcessor.process("bar()", context: context), "bar()")
    }

    func testQuoteOverlap() {
        let context = ctx("func f() {\n\tfmt.Println(\"hel", "\")\n}\n", multiline: false)
        XCTAssertEqual(CompletionPostProcessor.process("lo\")", context: context), "lo")
    }

    func testIndentedLineDropsLeadingWhitespaceAndNewlines() {
        let context = ctx("func f() {\n\t", "\n}\n", multiline: true)
        XCTAssertEqual(CompletionPostProcessor.process("\n\treturn nil", context: context), "return nil")
    }

    func testMultilineBodyStopsAtEnclosingClose() {
        let context = ctx("func (s *Store) Get(k string) (string, error) {\n\t", "\n}\n", multiline: true)
        let raw = "s.mu.RLock()\n    defer s.mu.RUnlock()\n    v, ok := s.data[k]\n    if !ok {\n        return \"\", ErrNotFound\n    }\n    return v, nil\n}\n\nfunc other() {}"
        XCTAssertEqual(CompletionPostProcessor.process(raw, context: context),
                       "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\tv, ok := s.data[k]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\treturn v, nil")
    }

    func testBlankLinesInsideAKnownBlockAreKept() {
        let context = ctx("func (s *Store) Get(key string) (string, error) {\n\t", "\n}\n", multiline: true)
        let raw = "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\n\tvalue, ok := s.data[key]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\n\treturn value, nil\n}\n\n// Set sets the value for key.\nfunc (s *Store) Set(key string, value string) {\n\ts.mu.Lock()\n}"
        XCTAssertEqual(CompletionPostProcessor.process(raw, context: context),
                       "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\n\tvalue, ok := s.data[key]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\n\treturn value, nil")
    }

    func testFIMOmitsBlankLineStopWhenTheBlockClosesNext() {
        XCTAssertEqual(CompletionEncoder.fimStops(ctx("func f() {\n\t", "\n}\n", multiline: true)), [])
        XCTAssertEqual(CompletionEncoder.fimStops(ctx("func f() {\n\t", "\n\tx := 1\n}\n", multiline: true)), ["\n\n"])
        XCTAssertEqual(CompletionEncoder.fimStops(ctx("x := ", "\n", multiline: false)), ["\n"])
    }

    func testMultilineStopsAtBlankLine() {
        let context = ctx("func f() {\n\t", "\n\treturn\n}\n", multiline: true)
        XCTAssertEqual(CompletionPostProcessor.process("a := 1\n\tb := 2\n\n\tc := 3", context: context), "a := 1\n\tb := 2")
    }

    func testBlockOpenedAtEndOfLineKeepsBodyAndDropsDuplicateClose() {
        let context = ctx("func add(a, b int) int {", "\n}\n", multiline: true)
        XCTAssertEqual(CompletionPostProcessor.process("\n\treturn a + b\n}", context: context), "\n\treturn a + b")
    }

    func testKeepsCloseOfBlockItOpened() {
        let context = ctx("func f() error {\n\t", "\n\treturn nil\n}\n", multiline: true)
        XCTAssertEqual(CompletionPostProcessor.process("if err != nil {\n\t\treturn err\n\t}\n\treturn nil", context: context), "if err != nil {\n\t\treturn err\n\t}")
    }

    func testRejectsWhitespaceAndDuplicateOfNextLine() {
        let context = ctx("func f() error {\n\t", "\n\treturn nil\n}\n", multiline: false)
        XCTAssertNil(CompletionPostProcessor.process("   \n", context: context))
        XCTAssertNil(CompletionPostProcessor.process("return nil", context: context))
        XCTAssertNil(CompletionPostProcessor.process("\nfoo()", context: ctx("x := ", ")\n", multiline: false)))
    }

    func testSpacesBecomeTabs() {
        XCTAssertEqual(CompletionPostProcessor.normalizeIndentation("a\n    b\n        c\n  d", includeFirstLine: false), "a\n\tb\n\t\tc\n\td")
    }

    func testIsCompleteRules() {
        let single = ctx("func f() {\n\t", ")\n}\n", multiline: false)
        XCTAssertFalse(CompletionPostProcessor.isComplete("return a", context: single))
        XCTAssertTrue(CompletionPostProcessor.isComplete("return a\n", context: single))
        let multi = ctx("func f() {\n\t", "\n}\n", multiline: true)
        XCTAssertFalse(CompletionPostProcessor.isComplete("a := 1\n\tb", context: multi))
        XCTAssertFalse(CompletionPostProcessor.isComplete("a := 1\n\n", context: multi))
        XCTAssertTrue(CompletionPostProcessor.isComplete("a := 1\n\n\tb", context: ctx("func f() {\n\t", "\n\treturn\n}\n", multiline: true)))
        XCTAssertTrue(CompletionPostProcessor.isComplete("a := 1\n}\n", context: multi))
        XCTAssertFalse(CompletionPostProcessor.isComplete("a := 1\n", context: multi))
    }
}

final class CompletionCacheTests: XCTestCase {
    func testExactHitAndLRUEviction() {
        let cache = CompletionCache(capacity: 2)
        cache.store("one", scope: "s", path: "a.go", prefix: "p1", suffix: "x")
        cache.store("two", scope: "s", path: "a.go", prefix: "p2", suffix: "x")
        XCTAssertEqual(cache.lookup(scope: "s", path: "a.go", prefix: "p1", suffix: "x"), "one")
        cache.store("three", scope: "s", path: "a.go", prefix: "p3", suffix: "x")
        XCTAssertNil(cache.lookup(scope: "s", path: "a.go", prefix: "p2", suffix: "x"))
        XCTAssertEqual(cache.lookup(scope: "s", path: "a.go", prefix: "p1", suffix: "x"), "one")
        XCTAssertEqual(cache.count, 2)
    }

    func testTypingThroughReturnsRemainder() {
        let cache = CompletionCache()
        let prefix = "func add(a, b int) int {\n\t"
        cache.store("return a + b", scope: "s", path: "a.go", prefix: prefix, suffix: "\n}\n")
        XCTAssertEqual(cache.lookup(scope: "s", path: "a.go", prefix: prefix + "ret", suffix: "\n}\n"), "urn a + b")
        XCTAssertNil(cache.lookup(scope: "s", path: "a.go", prefix: prefix + "rex", suffix: "\n}\n"))
        XCTAssertNil(cache.lookup(scope: "s", path: "a.go", prefix: prefix + "ret", suffix: "\n}\nother"))
        XCTAssertNil(cache.lookup(scope: "other", path: "a.go", prefix: prefix + "ret", suffix: "\n}\n"))
        XCTAssertNil(cache.lookup(scope: "s", path: "a.go", prefix: prefix + "return a + b", suffix: "\n}\n"))
    }
}

final class CompletionBackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAuthFailurePausesUntilSettingsChange() {
        var backoff = CompletionBackoff()
        XCTAssertEqual(backoff.record(.unauthorized(status: 401), at: now), .untilSettingsChange(reason: "Check the API key"))
        XCTAssertTrue(backoff.isPaused(at: now.addingTimeInterval(3600)))
        backoff.reset()
        XCTAssertFalse(backoff.isPaused(at: now))
    }

    func testRateLimitUsesRetryAfterCapped() {
        var backoff = CompletionBackoff()
        backoff.record(.rateLimited(retryAfterSeconds: 5), at: now)
        XCTAssertTrue(backoff.isPaused(at: now.addingTimeInterval(4)))
        XCTAssertFalse(backoff.isPaused(at: now.addingTimeInterval(6)))
        backoff.record(.rateLimited(retryAfterSeconds: 600), at: now)
        XCTAssertFalse(backoff.isPaused(at: now.addingTimeInterval(61)))
    }

    func testTransientFailuresPauseOnlyAfterRepeatsAndGrow() {
        var backoff = CompletionBackoff()
        XCTAssertNil(backoff.record(.timeout, at: now))
        XCTAssertFalse(backoff.isPaused(at: now))
        backoff.record(.server(status: 503), at: now)
        XCTAssertTrue(backoff.isPaused(at: now.addingTimeInterval(1.9)))
        XCTAssertFalse(backoff.isPaused(at: now.addingTimeInterval(2.1)))
        backoff.record(.offline, at: now)
        XCTAssertTrue(backoff.isPaused(at: now.addingTimeInterval(3.9)))
        for _ in 0..<10 { backoff.record(.offline, at: now) }
        XCTAssertFalse(backoff.isPaused(at: now.addingTimeInterval(60.5)))
        backoff.recordSuccess()
        XCTAssertNil(backoff.pause)
        XCTAssertEqual(backoff.consecutiveFailures, 0)
    }
}

final class CompletionSchedulerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ v: Int) { lock.withLock { values.append(v) } }
        var all: [Int] { lock.withLock { values } }
    }

    func testDebounceRestartsAndOnlyLastRuns() async throws {
        let scheduler = CompletionScheduler()
        let counter = Counter()
        for i in 0..<5 {
            scheduler.schedule(after: 0.15) { counter.add(i) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(counter.all, [4])
        XCTAssertFalse(scheduler.isBusy)
    }

    func testNewScheduleCancelsInFlightWork() async throws {
        let scheduler = CompletionScheduler()
        let counter = Counter()
        scheduler.schedule(after: 0) {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                counter.add(1)
            } catch {
                counter.add(-1)
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(scheduler.isRequestInFlight)
        scheduler.schedule(after: 0) { counter.add(2) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.all.sorted(), [-1, 2])
    }

    func testCancelStopsPendingWork() async throws {
        let scheduler = CompletionScheduler()
        let counter = Counter()
        let token = scheduler.schedule(after: 0.1) { counter.add(1) }
        scheduler.cancel()
        XCTAssertFalse(scheduler.isCurrent(token))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.all, [])
    }
}
