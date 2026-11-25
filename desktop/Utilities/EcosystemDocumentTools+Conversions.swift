import Foundation
import AppKit

extension EcosystemDocumentTools {
    private indirect enum OrderedValue {
        case object([(String, OrderedValue)])
        case array([OrderedValue])
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null
    }

    private struct YAMLLine {
        let indent: Int
        let text: String
    }

    private static func parseYAMLToOrderedValue(_ text: String) -> OrderedValue? {
        let rawLines = text.components(separatedBy: .newlines)
        var lines: [YAMLLine] = []

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" || trimmed == "..." {
                continue
            }
            let indent = yamlLeadingIndent(of: raw)
            let clean = stripInlineYAMLComment(trimmed).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                lines.append(YAMLLine(indent: indent, text: clean))
            }
        }

        guard !lines.isEmpty else { return nil }
        var index = 0
        return parseYAMLBlock(lines: lines, index: &index, minIndent: lines[0].indent)
    }

    private static func parseYAMLBlock(lines: [YAMLLine], index: inout Int, minIndent: Int) -> OrderedValue {
        guard index < lines.count else { return .null }

        if lines[index].text.hasPrefix("-") && (lines[index].text.count == 1 || lines[index].text.hasPrefix("- ")) {
            return parseYAMLSequence(lines: lines, index: &index, seqIndent: lines[index].indent)
        }

        var pairs: [(String, OrderedValue)] = []
        let baseIndent = lines[index].indent

        while index < lines.count {
            let current = lines[index]
            if current.indent < minIndent || current.indent < baseIndent {
                break
            }
            if current.text.hasPrefix("-") && (current.text.count == 1 || current.text.hasPrefix("- ")) {
                break
            }
            guard let (rawKey, rawVal) = splitYAMLKeyValue(current.text) else {
                index += 1
                continue
            }
            let key = unquoteYAMLString(rawKey)
            let valText = rawVal.trimmingCharacters(in: .whitespaces)
            index += 1

            if valText.isEmpty || valText == "|" || valText == "|-" || valText == ">" || valText == ">-" {
                if index < lines.count && lines[index].indent > current.indent {
                    let child = parseYAMLBlock(lines: lines, index: &index, minIndent: lines[index].indent)
                    pairs.append((key, child))
                } else {
                    pairs.append((key, .null))
                }
            } else {
                pairs.append((key, parseYAMLScalarOrFlowValue(valText)))
            }
        }

        return .object(pairs)
    }

    private static func parseYAMLSequence(lines: [YAMLLine], index: inout Int, seqIndent: Int) -> OrderedValue {
        var items: [OrderedValue] = []

        while index < lines.count {
            let current = lines[index]
            if current.indent < seqIndent {
                break
            }
            guard current.indent == seqIndent,
                  current.text.hasPrefix("-") && (current.text.count == 1 || current.text.hasPrefix("- ")) else {
                break
            }

            let afterDash = String(current.text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            index += 1

            if afterDash.isEmpty {
                if index < lines.count && lines[index].indent > seqIndent {
                    items.append(parseYAMLBlock(lines: lines, index: &index, minIndent: lines[index].indent))
                } else {
                    items.append(.null)
                }
            } else if let (rawKey, rawVal) = splitYAMLKeyValue(afterDash) {
                var itemPairs: [(String, OrderedValue)] = []
                let key = unquoteYAMLString(rawKey)
                let valText = rawVal.trimmingCharacters(in: .whitespaces)
                if valText.isEmpty {
                    if index < lines.count && lines[index].indent > seqIndent {
                        let child = parseYAMLBlock(lines: lines, index: &index, minIndent: lines[index].indent)
                        itemPairs.append((key, child))
                    } else {
                        itemPairs.append((key, .null))
                    }
                } else {
                    itemPairs.append((key, parseYAMLScalarOrFlowValue(valText)))
                }

                if index < lines.count && lines[index].indent > seqIndent && !lines[index].text.hasPrefix("-") {
                    let extra = parseYAMLBlock(lines: lines, index: &index, minIndent: lines[index].indent)
                    if case .object(let extraPairs) = extra {
                        itemPairs.append(contentsOf: extraPairs)
                    }
                }
                items.append(.object(itemPairs))
            } else {
                items.append(parseYAMLScalarOrFlowValue(afterDash))
            }
        }

        return .array(items)
    }

    private static func parseYAMLScalarOrFlowValue(_ raw: String) -> OrderedValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "null" || trimmed == "~" || trimmed == "NULL" {
            return .null
        }
        if trimmed == "{}" {
            return .object([])
        }
        if trimmed == "[]" {
            return .array([])
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            let parts = splitFlowItems(inner)
            return .array(parts.map { parseYAMLScalarOrFlowValue($0) })
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .object([]) }
            let parts = splitFlowItems(inner)
            var pairs: [(String, OrderedValue)] = []
            for part in parts {
                if let (k, v) = splitYAMLKeyValue(part) {
                    pairs.append((unquoteYAMLString(k), parseYAMLScalarOrFlowValue(v)))
                }
            }
            return .object(pairs)
        }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(unquoteYAMLString(trimmed))
        }
        let lower = trimmed.lowercased()
        if lower == "true" || lower == "yes" {
            return .bool(true)
        }
        if lower == "false" || lower == "no" {
            return .bool(false)
        }
        if let i = Int64(trimmed) {
            return .int(i)
        }
        if let d = Double(trimmed), trimmed.contains(".") {
            return .double(d)
        }
        return .string(trimmed)
    }

    private static func splitFlowItems(_ inner: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0

        for ch in inner {
            if inDouble {
                if ch == "\"" { inDouble = false }
                current.append(ch)
            } else if inSingle {
                if ch == "'" { inSingle = false }
                current.append(ch)
            } else {
                if ch == "\"" { inDouble = true; current.append(ch) }
                else if ch == "'" { inSingle = true; current.append(ch) }
                else if ch == "[" || ch == "{" { depth += 1; current.append(ch) }
                else if ch == "]" || ch == "}" { depth = max(0, depth - 1); current.append(ch) }
                else if ch == "," && depth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    static func generateGoStruct(fromConfigText text: String, rootTypeName: String = "Config") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxDocumentBytes else { return nil }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let goCode = JSONToGo.generate(from: trimmed, rootTypeName: rootTypeName) {
                return goCode
            }
        }

        if looksLikeEnvConfig(trimmed) {
            return generateGoStructFromEnv(trimmed, rootTypeName: rootTypeName)
        }

        if let parsed = parseYAMLToOrderedValue(trimmed), case .object(let pairs) = parsed, !pairs.isEmpty {
            return generateGoStructFromYAMLObject(pairs, rootTypeName: rootTypeName)
        }

        return JSONToGo.generate(from: trimmed, rootTypeName: rootTypeName)
    }

    private static func looksLikeEnvConfig(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var envLineCount = 0
        var yamlColonLineCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            var working = trimmed
            if working.hasPrefix("export ") {
                working = String(working.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            if working.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\s*="#, options: .regularExpression) != nil {
                envLineCount += 1
            } else if containsYAMLMappingColon(in: working) {
                yamlColonLineCount += 1
            }
        }
        return envLineCount > 0 && envLineCount >= yamlColonLineCount
    }

    private static func generateGoStructFromEnv(_ text: String, rootTypeName: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var fields: [(fieldName: String, goType: String, envKey: String, jsonKey: String)] = []
        var seenFieldNames = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("[") {
                continue
            }
            var working = trimmed
            if working.hasPrefix("export ") {
                working = String(working.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let eqIdx = working.firstIndex(of: "=") else { continue }
            let rawKey = String(working[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty, !rawKey.contains(" ") else { continue }

            let rawVal = String(working[working.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            let unquotedVal = unquoteYAMLString(stripInlineYAMLComment(rawVal).trimmingCharacters(in: .whitespaces))

            let goType: String
            let lowerVal = unquotedVal.lowercased()
            if lowerVal == "true" || lowerVal == "false" {
                goType = "bool"
            } else if Int64(unquotedVal) != nil {
                goType = "int"
            } else if Double(unquotedVal) != nil && unquotedVal.contains(".") {
                goType = "float64"
            } else {
                goType = "string"
            }

            let baseName = goExportedIdentifier(from: rawKey)
            var uniqueName = baseName
            var suffix = 2
            while seenFieldNames.contains(uniqueName) {
                uniqueName = "\(baseName)\(suffix)"
                suffix += 1
            }
            seenFieldNames.insert(uniqueName)
            fields.append((
                fieldName: uniqueName,
                goType: goType,
                envKey: rawKey,
                jsonKey: rawKey.lowercased()
            ))
        }

        guard !fields.isEmpty else { return nil }
        let structName = goExportedIdentifier(from: rootTypeName)
        var out: [String] = ["type \(structName) struct {"]
        for f in fields {
            out.append("\t\(f.fieldName) \(f.goType) `env:\"\(f.envKey)\" json:\"\(f.jsonKey)\"`")
        }
        out.append("}")
        return out.joined(separator: "\n")
    }

    private static func generateGoStructFromYAMLObject(_ pairs: [(String, OrderedValue)], rootTypeName: String) -> String? {
        let structName = goExportedIdentifier(from: rootTypeName)
        let bodyLines = renderYAMLStructFields(pairs, indent: "\t")
        guard !bodyLines.isEmpty else { return nil }
        var out: [String] = ["type \(structName) struct {"]
        out.append(contentsOf: bodyLines)
        out.append("}")
        return out.joined(separator: "\n")
    }

    private static func renderYAMLStructFields(_ pairs: [(String, OrderedValue)], indent: String) -> [String] {
        var lines: [String] = []
        var seenNames = Set<String>()

        for (key, value) in pairs {
            let baseName = goExportedIdentifier(from: key)
            var fieldName = baseName
            var suffix = 2
            while seenNames.contains(fieldName) {
                fieldName = "\(baseName)\(suffix)"
                suffix += 1
            }
            seenNames.insert(fieldName)
            let tag = "`yaml:\"\(key)\" json:\"\(key)\"`"

            switch value {
            case .object(let childPairs) where !childPairs.isEmpty:
                lines.append("\(indent)\(fieldName) struct {")
                lines.append(contentsOf: renderYAMLStructFields(childPairs, indent: indent + "\t"))
                lines.append("\(indent)} \(tag)")
            case .array(let items):
                if let first = items.first, case .object(let itemPairs) = first, !itemPairs.isEmpty {
                    lines.append("\(indent)\(fieldName) []struct {")
                    lines.append(contentsOf: renderYAMLStructFields(itemPairs, indent: indent + "\t"))
                    lines.append("\(indent)} \(tag)")
                } else {
                    let elemType = items.first.map { goScalarType(for: $0) } ?? "interface{}"
                    lines.append("\(indent)\(fieldName) []\(elemType) \(tag)")
                }
            default:
                let scalarType = goScalarType(for: value)
                lines.append("\(indent)\(fieldName) \(scalarType) \(tag)")
            }
        }
        return lines
    }

    private static func goScalarType(for value: OrderedValue) -> String {
        switch value {
        case .int: return "int"
        case .double: return "float64"
        case .bool: return "bool"
        case .string: return "string"
        default: return "interface{}"
        }
    }

    private static let commonGoInitialisms: Set<String> = [
        "ACL", "API", "ASCII", "CPU", "CSS", "DB", "DNS", "EOF", "GRPC", "GUID",
        "HTML", "HTTP", "HTTPS", "ID", "IP", "JSON", "JWT", "LHS", "QPS", "RAM",
        "RHS", "RPC", "SLA", "SMTP", "SQL", "SSH", "TCP", "TLS", "TTL", "UDP",
        "UI", "UID", "URI", "URL", "UTF8", "UUID", "VM", "XML", "XMPP", "XSRF", "XSS", "YAML", "DSN"
    ]

    private static func goExportedIdentifier(from raw: String) -> String {
        let parts = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Field" }
        let transformed = parts.map { part -> String in
            let upper = part.uppercased()
            if commonGoInitialisms.contains(upper) {
                return upper
            }
            return part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }.joined()
        if let first = transformed.first, first.isNumber {
            return "Field" + transformed
        }
        return transformed
    }
}
