import Foundation
import Testing
import GopilotRuntime
@testable import GopilotPolicy

private let readSourceSchema = #"{"type":"object","properties":{"relativePath":{"type":"string","minLength":1,"maxLength":1024},"startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1}},"required":["relativePath","startLine","endLine"],"additionalProperties":false}"#

private func violations(_ args: String, schema: String = readSourceSchema) throws -> [SchemaViolation] {
    try JSONSchemaValidator(schemaJSON: schema).validate(argumentsJSON: args)
}

private struct SpyTool: GopilotTool {
    let counter: CallCounter
    let schema = ToolSchema(name: "read_source", description: "spy", parametersJSON: readSourceSchema)

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        counter.increment()
        return ToolResultEnvelope(callID: callID, status: .ok, data: "ran")
    }
}

@Suite("JSON schema validation")
struct SchemaValidationTests {
    @Test func validArgumentsPass() throws {
        #expect(try violations(#"{"relativePath":"a.go","startLine":1,"endLine":10}"#).isEmpty)
    }

    @Test func stringIsNotCoercedToInteger() throws {
        let found = try violations(#"{"relativePath":"a.go","startLine":"5","endLine":10}"#)
        #expect(found.count == 1)
        #expect(found.first?.rule == "type")
        #expect(found.first?.path == "startLine")
    }

    @Test func fractionalAndBooleanAreNotIntegers() throws {
        #expect(try violations(#"{"relativePath":"a.go","startLine":5.5,"endLine":10}"#).first?.rule == "type")
        #expect(try violations(#"{"relativePath":"a.go","startLine":true,"endLine":10}"#).first?.rule == "type")
        #expect(try violations(#"{"relativePath":5,"startLine":1,"endLine":10}"#).first?.rule == "type")
        #expect(try violations(#"{"relativePath":null,"startLine":1,"endLine":10}"#).first?.rule == "type")
    }

    @Test func wholeNumberDoubleCountsAsInteger() throws {
        #expect(try violations(#"{"relativePath":"a.go","startLine":5.0,"endLine":10}"#).isEmpty)
    }

    @Test func missingRequiredAndExtraPropertiesAreReported() throws {
        let missing = try violations(#"{"relativePath":"a.go","startLine":1}"#)
        #expect(missing.map(\.rule) == ["required"])
        let extra = try violations(#"{"relativePath":"a.go","startLine":1,"endLine":2,"workspaceID":"other"}"#)
        #expect(extra.map(\.rule) == ["additionalProperties"])
        #expect(extra.first?.path == "workspaceID")
    }

    @Test func boundsAndLengthsAreEnforced() throws {
        #expect(try violations(#"{"relativePath":"","startLine":1,"endLine":2}"#).first?.rule == "minLength")
        let long = String(repeating: "a", count: 1025)
        #expect(try violations(#"{"relativePath":"\#(long)","startLine":1,"endLine":2}"#).first?.rule == "maxLength")
        #expect(try violations(#"{"relativePath":"a","startLine":0,"endLine":2}"#).first?.rule == "minimum")
        let capped = #"{"type":"object","properties":{"limit":{"type":"integer","maximum":100}},"additionalProperties":false}"#
        #expect(try violations(#"{"limit":101}"#, schema: capped).first?.rule == "maximum")
    }

    @Test func maxLengthCountsUnicodeScalarsNotBytes() throws {
        let schema = #"{"type":"object","properties":{"q":{"type":"string","maxLength":4}},"additionalProperties":false}"#
        #expect(try violations("{\"q\":\"\u{1EC7}\u{1EC7}\u{1EC7}\u{1EC7}\"}", schema: schema).isEmpty)
        #expect(try violations("{\"q\":\"\u{1EC7}\u{1EC7}\u{1EC7}\u{1EC7}\u{1EC7}\"}", schema: schema).first?.rule == "maxLength")
    }

    @Test func enumAndArrayItemsAreChecked() throws {
        let schema = #"{"type":"object","properties":{"direction":{"type":"string","enum":["incoming","outgoing"]},"ids":{"type":"array","items":{"type":"integer"}}},"additionalProperties":false}"#
        #expect(try violations(#"{"direction":"sideways"}"#, schema: schema).first?.rule == "enum")
        #expect(try violations(#"{"direction":"incoming","ids":[1,"2"]}"#, schema: schema).first?.path == "ids[1]")
        #expect(try violations(#"{"direction":"incoming","ids":[1,2]}"#, schema: schema).isEmpty)
    }

    @Test func invalidJSONIsReported() throws {
        #expect(try violations("{not json").first?.rule == "parse")
    }

    @Test func unsupportedSchemaIsRejectedAtConstruction() {
        #expect(throws: SchemaError.self) { try JSONSchemaValidator(schemaJSON: #"{"type":"null"}"#) }
        #expect(throws: SchemaError.self) { try JSONSchemaValidator(schemaJSON: "[]") }
    }

    @Test func validatedToolBlocksInvalidArgumentsBeforeExecution() async throws {
        let counter = CallCounter()
        let tool = try ValidatedTool(SpyTool(counter: counter))
        let bad = try await tool.execute(callID: "c1", argumentsJSON: #"{"relativePath":"a.go","startLine":"1","endLine":2}"#)
        #expect(bad.status == .error)
        #expect(bad.errorCode == .invalidArguments)
        #expect(counter.count == 0)
        let good = try await tool.execute(callID: "c2", argumentsJSON: #"{"relativePath":"a.go","startLine":1,"endLine":2}"#)
        #expect(good.status == .ok)
        #expect(counter.count == 1)
    }

    @Test func validatedToolRejectsOversizedArguments() async throws {
        let counter = CallCounter()
        let tool = try ValidatedTool(SpyTool(counter: counter))
        let padding = String(repeating: "x", count: 70 * 1024)
        let result = try await tool.execute(callID: "c1", argumentsJSON: #"{"relativePath":"\#(padding)","startLine":1,"endLine":2}"#)
        #expect(result.errorCode == .tooLarge)
        #expect(counter.count == 0)
    }

    @Test func validatedToolWorksThroughRegistryDispatch() async throws {
        let counter = CallCounter()
        let registry = ToolRegistry([try ValidatedTool(SpyTool(counter: counter))])
        let result = await registry.dispatch(ToolCall(id: "c1", name: "read_source", argumentsJSON: #"{"relativePath":"a.go","startLine":1,"endLine":2,"extra":1}"#))
        #expect(result.errorCode == .invalidArguments)
        #expect(counter.count == 0)
    }
}
