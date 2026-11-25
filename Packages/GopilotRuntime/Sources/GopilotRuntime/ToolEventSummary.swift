import Foundation

public enum ToolArgumentLimits {
    public static let maxFileContentBytes = 200 * 1024
    public static let maxPatchArgumentBytes = 320 * 1024
}

public enum ToolEventSummary {
    public static let argumentsLimit = 400
    public static let resultExcerptLimit = 700
    static let inlineStringLimit = 160
    static let keyFields: [String] = [
        "path", "relativePath", "query", "check", "packageScope", "symbol", "name",
        "targetIDs", "benchmarkIDs", "runID", "profileID", "category", "replaceAll",
        "startLine", "endLine", "line", "column", "relation", "direction"
    ]
    static let summaryStringFields: [String] = [
        "outcome", "proposalID", "proposalStatus", "runStatus", "path", "relativePath",
        "message", "reason", "next", "autoApplyFailure", "runID", "cwd", "check"
    ]
    static let summaryScalarFields: [String] = [
        "projectChanged", "diagnosticsPassed", "exitCode", "totalCount", "completedCount",
        "inProgressCount", "truncated", "durationSeconds", "lineCount", "total"
    ]

    public static func arguments(_ json: String, redact: (String) -> String) -> String {
        guard let object = parseObject(json) else { return "{}" }
        var compact: [String: Any] = [:]
        for (key, value) in object {
            compact[key] = compactValue(value, redact: redact)
        }
        let full = encode(compact)
        if full.utf8.count <= argumentsLimit { return full }
        var reduced: [String: Any] = [:]
        for key in keyFields where compact[key] != nil {
            reduced[key] = compact[key]
        }
        let reducedText = encode(reduced)
        if reducedText.utf8.count <= argumentsLimit { return reducedText }
        var minimal: [String: Any] = [:]
        for key in ["path", "relativePath", "query", "check"] {
            if let text = compact[key] as? String { minimal[key] = clip(text, 120) }
        }
        return encode(minimal)
    }

    public static func summary(toolName: String, resultData: String, redact: (String) -> String) -> String {
        guard let object = parseObject(resultData) else { return "{}" }
        var summary: [String: Any] = ["tool": toolName]
        for key in summaryStringFields {
            if let text = object[key] as? String, !text.isEmpty {
                summary[key] = redact(clip(text, 240))
            }
        }
        for key in summaryScalarFields {
            if let value = object[key], value is NSNumber {
                summary[key] = value
            }
        }
        if let files = object["files"] as? [[String: Any]] {
            summary["files"] = files.prefix(10).map { file -> [String: Any] in
                var entry: [String: Any] = [:]
                if let path = file["path"] as? String { entry["path"] = redact(clip(path, 300)) }
                if let operation = file["operation"] as? String { entry["operation"] = operation }
                return entry
            }
        }
        if let diagnostics = object["postEditDiagnostics"] as? [String] {
            summary["postEditDiagnostics"] = diagnostics.prefix(5).map { redact(clip($0, 200)) }
            summary["postEditDiagnosticCount"] = diagnostics.count
        }
        if let diagnostics = object["lspDiagnostics"] as? [String] {
            summary["lspDiagnosticCount"] = diagnostics.count
        }
        if let todos = object["todos"] as? [[String: Any]] {
            summary["todos"] = todos.prefix(12).map { todo -> [String: Any] in
                var entry: [String: Any] = [:]
                if let id = todo["id"] as? String { entry["id"] = clip(id, 64) }
                if let content = todo["content"] as? String { entry["content"] = redact(clip(content, 240)) }
                if let status = todo["status"] as? String { entry["status"] = status }
                return entry
            }
        }
        if let argv = object["argv"] as? [String] {
            summary["argv"] = argv.prefix(12).map { redact(clip($0, 120)) }
        }
        return encode(summary)
    }

    public static func excerpt(_ data: String, redact: (String) -> String) -> String {
        let redacted = redact(data)
        guard redacted.utf8.count > resultExcerptLimit else { return redacted }
        var used = 0
        var out = String.UnicodeScalarView()
        for scalar in redacted.unicodeScalars {
            let width = String(scalar).utf8.count
            if used + width > resultExcerptLimit { break }
            used += width
            out.append(scalar)
        }
        return String(out)
    }

    static func compactValue(_ value: Any, redact: (String) -> String) -> Any {
        switch value {
        case let text as String:
            let bytes = text.utf8.count
            if bytes > inlineStringLimit {
                return "[\(bytes) bytes]"
            }
            return redact(text)
        case let list as [Any]:
            if list.allSatisfy({ $0 is String }) {
                let strings = list.compactMap { $0 as? String }
                return strings.prefix(5).map { redact(clip($0, 120)) }
            }
            return "[\(list.count) items]"
        case is [String: Any]:
            return "{object}"
        default:
            return value
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
