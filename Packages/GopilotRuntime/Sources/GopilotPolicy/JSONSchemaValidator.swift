import Foundation
import GopilotRuntime

public struct SchemaViolation: Sendable, Equatable {
    public let path: String
    public let rule: String
    public let message: String

    public init(path: String, rule: String, message: String) {
        self.path = path
        self.rule = rule
        self.message = message
    }

    public var description: String { "\(path.isEmpty ? "$" : path): \(message)" }
}

public enum SchemaError: Error, Sendable, Equatable {
    case invalidSchema(String)
}

public struct JSONSchemaValidator: Sendable {
    private let schema: JSONValue

    public init(schemaJSON: String) throws {
        guard let parsed = JSONValue.parse(schemaJSON), case .object = parsed else {
            throw SchemaError.invalidSchema("Schema must be a JSON object.")
        }
        try Self.check(parsed, path: "$")
        schema = parsed
    }

    private static let knownTypes: Set<String> = ["object", "string", "integer", "number", "boolean", "array"]

    private static func check(_ node: JSONValue, path: String) throws {
        guard case .object(let map) = node else { throw SchemaError.invalidSchema("\(path) must be an object.") }
        if let type = map["type"] {
            guard let name = type.stringValue, knownTypes.contains(name) else {
                throw SchemaError.invalidSchema("\(path) has unsupported type.")
            }
        }
        if let properties = map["properties"] {
            guard case .object(let props) = properties else { throw SchemaError.invalidSchema("\(path).properties must be an object.") }
            for (key, child) in props { try check(child, path: "\(path).\(key)") }
        }
        if let items = map["items"] { try check(items, path: "\(path)[]") }
        if let required = map["required"] {
            guard case .array(let names) = required, names.allSatisfy({ $0.stringValue != nil }) else {
                throw SchemaError.invalidSchema("\(path).required must be a string array.")
            }
        }
        if let values = map["enum"] {
            guard case .array = values else { throw SchemaError.invalidSchema("\(path).enum must be an array.") }
        }
    }

    public func validate(argumentsJSON: String) -> [SchemaViolation] {
        guard let value = JSONValue.parse(argumentsJSON) else {
            return [SchemaViolation(path: "", rule: "parse", message: "Arguments are not valid JSON.")]
        }
        var violations: [SchemaViolation] = []
        validate(value, against: schema, path: "", into: &violations)
        return violations
    }

    private func validate(_ value: JSONValue, against node: JSONValue, path: String, into out: inout [SchemaViolation]) {
        guard case .object(let rules) = node else { return }

        if let typeName = rules["type"]?.stringValue, !Self.matches(value, type: typeName) {
            out.append(SchemaViolation(path: path, rule: "type", message: "Expected \(typeName), got \(Self.describe(value))."))
            return
        }

        if case .array(let allowed)? = rules["enum"], !allowed.contains(where: { Self.sameValue($0, value) }) {
            out.append(SchemaViolation(path: path, rule: "enum", message: "Value is not one of the allowed values."))
        }

        switch value {
        case .string(let text):
            let count = text.unicodeScalars.count
            if let min = rules["minLength"]?.intValue, count < min {
                out.append(SchemaViolation(path: path, rule: "minLength", message: "Length \(count) is below minimum \(min)."))
            }
            if let max = rules["maxLength"]?.intValue, count > max {
                out.append(SchemaViolation(path: path, rule: "maxLength", message: "Length \(count) exceeds maximum \(max)."))
            }
        case .integer, .number:
            if let number = Self.doubleValue(value) {
                if let min = rules["minimum"].flatMap(Self.doubleValue), number < min {
                    out.append(SchemaViolation(path: path, rule: "minimum", message: "Value is below minimum \(min)."))
                }
                if let max = rules["maximum"].flatMap(Self.doubleValue), number > max {
                    out.append(SchemaViolation(path: path, rule: "maximum", message: "Value exceeds maximum \(max)."))
                }
            }
        case .array(let items):
            if let min = rules["minItems"]?.intValue, items.count < min {
                out.append(SchemaViolation(path: path, rule: "minItems", message: "Fewer than \(min) items."))
            }
            if let max = rules["maxItems"]?.intValue, items.count > max {
                out.append(SchemaViolation(path: path, rule: "maxItems", message: "More than \(max) items."))
            }
            if let itemSchema = rules["items"] {
                for (index, item) in items.enumerated() {
                    validate(item, against: itemSchema, path: "\(path)[\(index)]", into: &out)
                }
            }
        case .object(let map):
            let properties = rules["properties"]?.objectValue ?? [:]
            if case .array(let required)? = rules["required"] {
                for name in required.compactMap(\.stringValue) where map[name] == nil {
                    out.append(SchemaViolation(path: join(path, name), rule: "required", message: "Missing required property \(name)."))
                }
            }
            for key in map.keys.sorted() {
                guard let childValue = map[key] else { continue }
                if let child = properties[key] {
                    validate(childValue, against: child, path: join(path, key), into: &out)
                } else if case .bool(false)? = rules["additionalProperties"] {
                    out.append(SchemaViolation(path: join(path, key), rule: "additionalProperties", message: "Unknown property \(key)."))
                } else if let extra = rules["additionalProperties"], case .object = extra {
                    validate(childValue, against: extra, path: join(path, key), into: &out)
                }
            }
        default:
            break
        }
    }

    private func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("string", .string), ("boolean", .bool), ("array", .array): return true
        case ("integer", .integer): return true
        case ("number", .integer), ("number", .number): return true
        default: return false
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func doubleValue(_ value: JSONValue) -> Double? {
        switch value {
        case .integer(let number): return Double(number)
        case .number(let number): return number
        default: return nil
        }
    }

    private static func sameValue(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.integer, .number), (.number, .integer): return doubleValue(a) == doubleValue(b)
        default: return a == b
        }
    }
}

public struct ValidatedTool: GopilotTool {
    public static let defaultMaxArgumentBytes = 64 * 1024

    private let inner: GopilotTool
    private let validator: JSONSchemaValidator
    private let maxArgumentBytes: Int

    public var schema: ToolSchema { inner.schema }

    public init(_ tool: GopilotTool, maxArgumentBytes: Int = ValidatedTool.defaultMaxArgumentBytes) throws {
        inner = tool
        validator = try JSONSchemaValidator(schemaJSON: tool.schema.parametersJSON)
        self.maxArgumentBytes = maxArgumentBytes
    }

    public func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        let size = argumentsJSON.utf8.count
        if size > maxArgumentBytes {
            return .failure(callID: callID, code: .tooLarge, message: "Arguments are \(size) bytes; the limit is \(maxArgumentBytes).")
        }
        let violations = validator.validate(argumentsJSON: argumentsJSON)
        if !violations.isEmpty {
            let detail = violations.prefix(8).map(\.description).joined(separator: "; ")
            return .failure(callID: callID, code: .invalidArguments, message: "Invalid arguments for \(inner.schema.name): \(detail)")
        }
        return try await inner.execute(callID: callID, argumentsJSON: argumentsJSON)
    }
}
