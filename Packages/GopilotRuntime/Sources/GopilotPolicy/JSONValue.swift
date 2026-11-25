import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return convert(raw)
    }

    private static func convert(_ raw: Any) -> JSONValue? {
        switch raw {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let kind = String(cString: number.objCType)
            if kind == "d" || kind == "f" {
                let value = number.doubleValue
                if value.rounded() == value, abs(value) < 9.0e15 { return .integer(Int64(value)) }
                return .number(value)
            }
            return .integer(number.int64Value)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            for element in array {
                guard let value = convert(element) else { return nil }
                items.append(value)
            }
            return .array(items)
        case let object as [String: Any]:
            var map: [String: JSONValue] = [:]
            for (key, element) in object {
                guard let value = convert(element) else { return nil }
                map[key] = value
            }
            return .object(map)
        default:
            return nil
        }
    }

    public var canonicalString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let items): return "[" + items.map(\.canonicalString).joined(separator: ",") + "]"
        case .object(let map):
            let body = map.keys.sorted().map { Self.quote($0) + ":" + (map[$0]?.canonicalString ?? "null") }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let map) = self { return map[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let map) = self { return map }
        return nil
    }
}

enum JSONOutput {
    static func string(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
