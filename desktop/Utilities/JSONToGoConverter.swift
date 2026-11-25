import Foundation

enum JSONToGo {
    struct Field {
        let name: String
        let type: GoType
        let jsonKey: String
    }

    indirect enum GoType {
        case int
        case float
        case bool
        case string
        case any
        case array(GoType)
        case `struct`(name: String?, fields: [Field])
    }

    static func generate(from jsonString: String, rootTypeName: String = "T") -> String? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else { return nil }

        let fields = inferFields(from: dict)
        guard !fields.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("type \(goIdentifier(from: rootTypeName, canBeKeyword: true)) struct {")
        for field in fields.sorted(by: { $0.name < $1.name }) {
            lines.append(contentsOf: renderField(field, indent: "\t"))
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func renderField(_ field: Field, indent: String) -> [String] {
        let (head, body, _) = renderType(field.type)
        if body.isEmpty {
            return ["\(indent)\(field.name) \(head) `json:\"\(field.jsonKey)\"`"]
        }
        var lines: [String] = []
        lines.append("\(indent)\(field.name) \(head) {")
        for line in body {
            lines.append("\(indent)\t\(line)")
        }
        lines.append("\(indent)} `json:\"\(field.jsonKey)\"`")
        return lines
    }

    private static func renderType(_ type: GoType) -> (head: String, body: [String], tail: String) {
        switch type {
        case .int: return ("int", [], "")
        case .float: return ("float64", [], "")
        case .bool: return ("bool", [], "")
        case .string: return ("string", [], "")
        case .any: return ("interface{}", [], "")
        case .array(let element):
            let (head, body, tail) = renderType(element)
            return ("[]" + head, body, tail)
        case .struct(_, let fields):
            let body = fields.sorted(by: { $0.name < $1.name })
                .flatMap { renderField($0, indent: "\t") }
            return ("struct", body, "}")
        }
    }

    private static func inferFields(from dict: [String: Any]) -> [Field] {
        var seen = Set<String>()
        var fields: [Field] = []
        for (key, value) in dict {
            let baseName = goIdentifier(from: key)
            var name = baseName
            var suffix = 1
            while seen.contains(name) {
                suffix += 1
                name = "\(baseName)\(suffix)"
            }
            seen.insert(name)
            fields.append(Field(name: name, type: inferType(from: value), jsonKey: key))
        }
        return fields
    }

    private static func inferType(from value: Any) -> GoType {
        switch value {
        case is NSNull:
            return .any
        case let number as NSNumber:
            if number === kCFBooleanTrue as NSNumber || number === kCFBooleanFalse as NSNumber {
                return .bool
            }
            let double = number.doubleValue
            if double == double, double == Double(Int64(double)), number == NSNumber(value: Int64(double)) {
                return .int
            }
            return .float
        case is String:
            return .string
        case let array as [Any]:
            return .array(inferArrayElementType(from: array))
        case let dict as [String: Any]:
            return .struct(name: nil, fields: inferFields(from: dict))
        default:
            return .any
        }
    }

    private static func inferArrayElementType(from array: [Any]) -> GoType {
        guard !array.isEmpty else { return .any }
        var merged: GoType = inferType(from: array[0])
        for element in array.dropFirst() {
            merged = mergeTypes(merged, inferType(from: element))
        }
        return merged
    }

    private static func mergeTypes(_ a: GoType, _ b: GoType) -> GoType {
        if isSameType(a, b) { return a }
        switch (a, b) {
        case (.array(let ea), .array(let eb)):
            return .array(mergeTypes(ea, eb))
        case (.struct(let na, let fa), .struct(let nb, let fb)):
            var map: [String: Field] = [:]
            for field in fa { map[field.jsonKey] = field }
            for field in fb {
                if let existing = map[field.jsonKey] {
                    map[field.jsonKey] = Field(name: existing.name,
                                               type: mergeTypes(existing.type, field.type),
                                               jsonKey: existing.jsonKey)
                } else {
                    map[field.jsonKey] = field
                }
            }
            return .struct(name: na ?? nb, fields: Array(map.values))
        default:
            return .any
        }
    }

    private static func isSameType(_ a: GoType, _ b: GoType) -> Bool {
        switch (a, b) {
        case (.int, .int), (.float, .float), (.bool, .bool), (.string, .string), (.any, .any):
            return true
        case (.array(let ea), .array(let eb)):
            return isSameType(ea, eb)
        case (.struct(_, let fa), .struct(_, let fb)):
            guard fa.count == fb.count else { return false }
            let aMap = Dictionary(uniqueKeysWithValues: fa.map { ($0.jsonKey, $0.type) })
            for field in fb {
                guard let other = aMap[field.jsonKey], isSameType(other, field.type) else { return false }
            }
            return true
        default:
            return false
        }
    }

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type", "var"
    ]

    private static func goIdentifier(from key: String, canBeKeyword: Bool = false) -> String {
        let parts = key.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let base = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        let sanitized = base.isEmpty ? "Field" : base
        if !canBeKeyword, goKeywords.contains(sanitized.lowercased()) {
            return sanitized + "_"
        }
        return sanitized
    }
}
