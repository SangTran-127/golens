import Foundation
import Testing
import GopilotRuntime
@testable import GopilotProvider

private let vietnameseText = "Xin chào, đường Nguyễn Huệ ở Thành phố Hồ Chí Minh 𠮷"

private func fixtureEvents(lineEnding: String = "\n", withNoise: Bool = false) -> String {
    var lines: [String] = []
    if withNoise {
        lines.append(": keep-alive")
        lines.append("")
    }
    lines.append(#"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Xin chào, "},"finish_reason":null}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[{"index":0,"delta":{"content":"đường Nguyễn Huệ ở Thành phố Hồ Chí Minh 𠮷"},"finish_reason":null}]}"#)
    lines.append("")
    if withNoise {
        lines.append(":")
        lines.append("event: ping")
        lines.append("")
    }
    lines.append(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_canary","arguments":""}}]},"finish_reason":null}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"na"}}]},"finish_reason":null}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"me\":\"Việt"}}]},"finish_reason":null}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" Nam 𠮷\"}"}}]},"finish_reason":null}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
    lines.append("")
    lines.append(#"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}"#)
    lines.append("")
    lines.append("data: [DONE]")
    lines.append("")
    return lines.joined(separator: lineEnding) + lineEnding
}

private let expectedFixtureEvents: [ProviderEvent] = [
    .textDelta("Xin chào, "),
    .textDelta("đường Nguyễn Huệ ở Thành phố Hồ Chí Minh 𠮷"),
    .toolCall(ToolCall(id: "call_1", name: "read_canary", argumentsJSON: #"{"name":"Việt Nam 𠮷"}"#)),
    .usage(TokenUsage(inputTokens: 12, outputTokens: 34)),
    .finish(.toolCalls)
]

private func decode(chunks: [Data], limits: SSELimits = SSELimits()) throws -> [ProviderEvent] {
    var parser = SSEParser(limits: limits)
    var assembler = ChatCompletionsStreamAssembler(limits: limits)
    var events: [ProviderEvent] = []
    var done = false
    outer: for chunk in chunks {
        for event in try parser.feed(chunk) {
            if event.isDone {
                done = true
                break outer
            }
            events.append(contentsOf: try assembler.consume(event.data))
        }
    }
    if !done {
        for event in try parser.finish() where !event.isDone {
            events.append(contentsOf: try assembler.consume(event.data))
        }
    }
    events.append(contentsOf: assembler.end())
    return events
}

private func decode(_ text: String, limits: SSELimits = SSELimits()) throws -> [ProviderEvent] {
    try decode(chunks: [Data(text.utf8)], limits: limits)
}

private func malformedMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
    } catch ProviderError.malformedResponse(let message) {
        return message
    } catch {
        return "unexpected: \(error)"
    }
    return nil
}

@Suite("SSE parser and assembler")
struct SSEAndAssemblerTests {
    @Test func fixtureDecodesToExpectedEventsInOneChunk() throws {
        #expect(try decode(fixtureEvents()) == expectedFixtureEvents)
    }

    @Test func everySingleByteSplitProducesIdenticalOutput() throws {
        for (label, text) in [("lf", fixtureEvents()), ("crlf-noise", fixtureEvents(lineEnding: "\r\n", withNoise: true))] {
            let bytes = Array(text.utf8)
            var multiByteBoundaries = 0
            for split in 0...bytes.count {
                let first = Data(bytes[0..<split])
                let second = Data(bytes[split...])
                if split > 0, split < bytes.count, bytes[split] & 0xC0 == 0x80 { multiByteBoundaries += 1 }
                let events = try decode(chunks: [first, second])
                #expect(events == expectedFixtureEvents, "split \(split) of \(label)")
            }
            #expect(multiByteBoundaries > 20)
        }
    }

    @Test func byteAtATimeDeliveryProducesIdenticalOutput() throws {
        for text in [fixtureEvents(), fixtureEvents(lineEnding: "\r\n", withNoise: true), fixtureEvents(lineEnding: "\r", withNoise: true)] {
            let chunks = Array(text.utf8).map { Data([$0]) }
            #expect(try decode(chunks: chunks) == expectedFixtureEvents)
        }
    }

    @Test func multipleEventsInOneChunkCommentsAndDone() throws {
        var parser = SSEParser()
        let events = try parser.feed(Data(": heartbeat\n\ndata: one\n\n\ndata: two\ndata: three\n\nevent: x\ndata: [DONE]\n\n".utf8))
        #expect(events.map(\.data) == ["one", "two\nthree", "[DONE]"])
        #expect(events.map(\.name) == [nil, nil, "x"])
        #expect(events.last?.isDone == true)
    }

    @Test func lineEndingsAreNormalised() throws {
        var parser = SSEParser()
        var events = try parser.feed(Data("data: a\r\n\r\ndata: b\r\r".utf8))
        events += try parser.feed(Data("data: c\n\n".utf8))
        #expect(events.map(\.data) == ["a", "b", "c"])
    }

    @Test func trailingEventWithoutBlankLineIsDispatchedButPartialLineIsDropped() throws {
        var parser = SSEParser()
        var events = try parser.feed(Data("data: complete\ndata: partial-no-newline".utf8))
        events += try parser.finish()
        #expect(events.map(\.data) == ["complete"])
    }

    @Test func eventSizeLimitGivesRecoverableError() {
        let limits = SSELimits(eventBytes: 1024, responseBytes: 1 << 20, toolArgumentBytes: 64)
        let message = malformedMessage {
            var parser = SSEParser(limits: limits)
            _ = try parser.feed(Data(("data: " + String(repeating: "a", count: 2048) + "\n\n").utf8))
        }
        #expect(message?.contains("event") == true)
        let unterminated = malformedMessage {
            var parser = SSEParser(limits: limits)
            _ = try parser.feed(Data(String(repeating: "b", count: 2048).utf8))
        }
        #expect(unterminated != nil)
    }

    @Test func defaultEventLimitIsOneMebibyte() {
        let message = malformedMessage {
            var parser = SSEParser()
            _ = try parser.feed(Data(("data: " + String(repeating: "a", count: (1 << 20) + 16) + "\n\n").utf8))
        }
        #expect(message != nil)
        var parser = SSEParser()
        #expect((try? parser.feed(Data(("data: " + String(repeating: "a", count: 1 << 19) + "\n\n").utf8)))?.count == 1)
    }

    @Test func totalResponseLimitGivesRecoverableError() {
        let limits = SSELimits(eventBytes: 1024, responseBytes: 4096, toolArgumentBytes: 64)
        let message = malformedMessage {
            var parser = SSEParser(limits: limits)
            for _ in 0..<100 {
                _ = try parser.feed(Data("data: 0123456789012345678901234567890123456789\n\n".utf8))
            }
        }
        #expect(message?.contains("limit") == true)
    }

    @Test func invalidUTF8InEventIsRejected() {
        let message = malformedMessage {
            var parser = SSEParser()
            _ = try parser.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A, 0x0A]))
        }
        #expect(message?.contains("UTF-8") == true)
    }

    @Test func toolArgumentLimitGivesRecoverableError() {
        let limits = SSELimits(toolArgumentBytes: 64 << 10)
        var assembler = ChatCompletionsStreamAssembler(limits: limits)
        let head = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{\"a\":\""}}]}}]}"#
        let filler = String(repeating: "x", count: 40 << 10)
        let body = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\#(filler)"}}]}}]}"#
        let message = malformedMessage {
            _ = try assembler.consume(head)
            _ = try assembler.consume(body)
            _ = try assembler.consume(body)
        }
        #expect(message?.contains("64 KiB") == true)
    }

    @Test func multipleInterleavedToolCallsAreEmittedInOrderWithCompleteArguments() throws {
        let stream = [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_source","arguments":"{\"path\""}},{"index":1,"id":"call_b","type":"function","function":{"name":"find_symbols","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"query\":"}},{"index":0,"function":{"arguments":":\"a.go\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"Order\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
        ].map { "data: \($0)\n\n" }.joined()
        #expect(try decode(stream) == [
            .toolCall(ToolCall(id: "call_a", name: "read_source", argumentsJSON: #"{"path":"a.go"}"#)),
            .toolCall(ToolCall(id: "call_b", name: "find_symbols", argumentsJSON: #"{"query":"Order"}"#)),
            .finish(.toolCalls)
        ])
    }

    @Test func toolCallsWithoutIndexAreSeparatedByIdAndMissingIdsAreSynthesised() throws {
        let whole = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"x1","function":{"name":"a","arguments":"{}"}},{"id":"x2","function":{"name":"b","arguments":"{\"k\":1}"}}]},"finish_reason":"tool_calls"}]}"#
        let events = try decode("data: \(whole)\n\n")
        #expect(events == [
            .toolCall(ToolCall(id: "x1", name: "a", argumentsJSON: "{}")),
            .toolCall(ToolCall(id: "x2", name: "b", argumentsJSON: #"{"k":1}"#)),
            .finish(.toolCalls)
        ])
        let anonymous = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"a","arguments":""}}]},"finish_reason":"tool_calls"}]}"#
        #expect(try decode("data: \(anonymous)\n\n") == [
            .toolCall(ToolCall(id: "call_0", name: "a", argumentsJSON: "{}")),
            .finish(.toolCalls)
        ])
    }

    @Test func invalidJSONArgumentsAreNeverEmitted() {
        let cases = [
            #"{\"a\":"#,
            #"not json"#,
            #"[1,2]"#
        ]
        for arguments in cases {
            var assembler = ChatCompletionsStreamAssembler()
            var emitted: [ProviderEvent] = []
            let first = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"\#(arguments)"}}]}}]}"#
            let last = #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
            var failure: Error?
            do {
                emitted += try assembler.consume(first)
                emitted += try assembler.consume(last)
            } catch {
                failure = error
            }
            emitted += assembler.end()
            #expect(failure as? ProviderError != nil, "arguments \(arguments)")
            #expect(emitted.isEmpty, "arguments \(arguments)")
        }
    }

    @Test func truncatedStreamHasNoFinishAndNoToolCall() throws {
        let truncated = textChunk("partial answer")
            + sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{\"a\":1}"}}]}}]}"#)
        let events = try decode(truncated)
        #expect(events == [.textDelta("partial answer")])
        #expect(events.contains { if case .finish = $0 { return true } else { return false } } == false)
    }

    @Test func streamCutInsideAnEventDropsThatEvent() throws {
        let full = textChunk("kept") + finishChunk("stop")
        let cut = String(full.dropLast(12))
        let events = try decode(cut)
        #expect(events == [.textDelta("kept")])
    }

    @Test func emptyChoicesChunkCarriesUsage() throws {
        let stream = textChunk("ok") + finishChunk("stop") + sseChunk(#"{"id":"x","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#)
        #expect(try decode(stream) == [
            .textDelta("ok"),
            .usage(TokenUsage(inputTokens: 5, outputTokens: 7)),
            .finish(.stop)
        ])
    }

    @Test func usageWithNullCountsIsNotReported() throws {
        let stream = sseChunk(#"{"choices":[{"index":0,"delta":{"content":"a"},"usage":null}],"usage":{"prompt_tokens":null,"completion_tokens":null}}"#) + finishChunk("stop")
        #expect(try decode(stream) == [.textDelta("a"), .finish(.stop)])
    }

    @Test func finishReasonMappingAndLegacyFunctionCallIsIgnored() throws {
        #expect(try decode(textChunk("a") + finishChunk("stop")) == [.textDelta("a"), .finish(.stop)])
        #expect(try decode(textChunk("a") + finishChunk("length")) == [.textDelta("a"), .finish(.length)])
        #expect(try decode(textChunk("a") + finishChunk("function_call")) == [.textDelta("a")])
        let message = malformedMessage { _ = try decode(finishChunk("content_filter")) }
        #expect(message != nil)
    }

    @Test func lengthFinishReportsCutToolCallsWithoutDispatchingThem() throws {
        let stream = sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{\"a\":"}}]}}]}"#)
            + finishChunk("length")
        #expect(try decode(stream) == [.toolCallTruncated(name: "t"), .finish(.length)])
    }

    @Test func defaultToolArgumentLimitMatchesPatchToolLimit() {
        #expect(SSELimits().toolArgumentBytes == ToolArgumentLimits.maxPatchArgumentBytes)
        #expect(ToolArgumentLimits.maxPatchArgumentBytes > ToolArgumentLimits.maxFileContentBytes)
    }

    @Test func finishIsOnlyEmittedAtEndOfStream() throws {
        var assembler = ChatCompletionsStreamAssembler()
        let early = try assembler.consume(#"{"choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"stop"}]}"#)
        #expect(early == [.textDelta("x")])
        #expect(assembler.end() == [.finish(.stop)])
        #expect(assembler.end().isEmpty)
    }

    @Test func secondChoiceIsIgnored() throws {
        let chunk = #"{"choices":[{"index":1,"delta":{"content":"other"}},{"index":0,"delta":{"content":"mine"}}]}"#
        var assembler = ChatCompletionsStreamAssembler()
        #expect(try assembler.consume(chunk) == [.textDelta("mine")])
    }

    @Test func errorPayloadAndGarbageAreMalformed() {
        let errorMessage = malformedMessage {
            var assembler = ChatCompletionsStreamAssembler()
            _ = try assembler.consume(#"{"error":{"message":"secret-body-text","type":"server_error"}}"#)
        }
        #expect(errorMessage != nil)
        #expect(errorMessage?.contains("secret-body-text") == false)
        let garbage = malformedMessage {
            var assembler = ChatCompletionsStreamAssembler()
            _ = try assembler.consume("<html>nope</html>")
        }
        #expect(garbage != nil)
    }

    @Test func nonStreamResponseProducesSameEventShape() throws {
        let body = #"""
        {"id":"r1","choices":[{"index":0,"message":{"role":"assistant","content":"Looking.","tool_calls":[
        {"id":"call_1","type":"function","function":{"name":"read_canary","arguments":"{\"name\":\"alpha\"}"}},
        {"id":"call_2","type":"function","function":{"name":"read_canary","arguments":"{\"name\":\"beta\"}"}}]},
        "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}
        """#
        #expect(try ChatCompletionsResponseDecoder.decode(Data(body.utf8)) == [
            .textDelta("Looking."),
            .toolCall(ToolCall(id: "call_1", name: "read_canary", argumentsJSON: #"{"name":"alpha"}"#)),
            .toolCall(ToolCall(id: "call_2", name: "read_canary", argumentsJSON: #"{"name":"beta"}"#)),
            .usage(TokenUsage(inputTokens: 3, outputTokens: 4)),
            .finish(.toolCalls)
        ])
    }

    @Test func nonStreamTextNullContentAndMissingFinish() throws {
        let nullContent = #"{"choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#
        #expect(try ChatCompletionsResponseDecoder.decode(Data(nullContent.utf8)) == [.finish(.stop)])
        let missingFinish = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":null}]}"#
        #expect(try ChatCompletionsResponseDecoder.decode(Data(missingFinish.utf8)) == [.textDelta("hi")])
    }

    @Test func nonStreamHTMLAndInvalidArgumentsAreMalformed() {
        let html = malformedMessage { _ = try ChatCompletionsResponseDecoder.decode(Data("<html></html>".utf8)) }
        #expect(html != nil)
        let bad = #"{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"c","function":{"name":"t","arguments":"{oops"}}]},"finish_reason":"tool_calls"}]}"#
        let message = malformedMessage { _ = try ChatCompletionsResponseDecoder.decode(Data(bad.utf8)) }
        #expect(message != nil)
    }

    @Test func vietnameseTextSurvivesSplitInsideEveryMultiByteCharacter() throws {
        let stream = textChunk(vietnameseText) + finishChunk("stop")
        let bytes = Array(stream.utf8)
        for split in 1..<bytes.count {
            let events = try decode(chunks: [Data(bytes[0..<split]), Data(bytes[split...])])
            #expect(events == [.textDelta(vietnameseText), .finish(.stop)])
        }
    }

    @Test func reasoningContentAndReasoningTokensAreDecodedWithoutMixingIntoTextDelta() throws {
        let stream = [
            #"{"model":"deepseek-reasoner","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"think-1 "},"finish_reason":null}]}"#,
            #"{"model":"deepseek-reasoner","choices":[{"index":0,"delta":{"reasoning_content":"think-2","content":"Answer"},"finish_reason":"stop"}]}"#,
            #"{"model":"deepseek-reasoner","choices":[],"usage":{"prompt_tokens":14,"completion_tokens":28,"completion_tokens_details":{"reasoning_tokens":19}}}"#
        ].map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"

        #expect(try decode(stream) == [
            .reasoningDelta("think-1 "),
            .reasoningDelta("think-2"),
            .textDelta("Answer"),
            .usage(TokenUsage(inputTokens: 14, outputTokens: 28, reasoningTokens: 19, responseModelID: "deepseek-reasoner")),
            .finish(.stop)
        ])

        let nonStream = #"""
        {"model":"o3-mini","choices":[{"index":0,"message":{"role":"assistant","reasoning_content":"internal chain","content":"Final reply"},"finish_reason":"stop"}],
        "usage":{"input_tokens":8,"output_tokens":16,"output_tokens_details":{"reasoning_tokens":11}}}
        """#
        #expect(try ChatCompletionsResponseDecoder.decode(Data(nonStream.utf8)) == [
            .reasoningDelta("internal chain"),
            .textDelta("Final reply"),
            .usage(TokenUsage(inputTokens: 8, outputTokens: 16, reasoningTokens: 11, responseModelID: "o3-mini")),
            .finish(.stop)
        ])
    }
}
