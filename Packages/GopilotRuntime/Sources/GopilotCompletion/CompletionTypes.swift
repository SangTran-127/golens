import Foundation

public enum CompletionDialect: String, Sendable, Codable, CaseIterable {
    case chatHoleFill = "chat"
    case fillInTheMiddle = "fim"
}

extension CompletionDialect {
    public static func suggested(forModelID modelID: String) -> CompletionDialect {
        let id = modelID.lowercased()
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        if id.hasPrefix("text-completion") || leaf.contains("fim") { return .fillInTheMiddle }
        if leaf.contains("codestral") && !id.hasPrefix("mistralai/") { return .fillInTheMiddle }
        if leaf.contains("deepseek-coder") || leaf.contains("starcoder") { return .fillInTheMiddle }
        if leaf.contains("qwen") && leaf.contains("coder") && leaf.contains("base") { return .fillInTheMiddle }
        return .chatHoleFill
    }
}

public enum CompletionLengthPreference: String, Sendable, Codable, CaseIterable {
    case automatic
    case singleLine
}

public struct CompletionSnapshot: Sendable, Equatable {
    public var relativePath: String
    public var prefix: String
    public var suffix: String
    public var prefixStartsAtFileStart: Bool
    public var suffixEndsAtFileEnd: Bool
    public var fileHead: String

    public init(
        relativePath: String,
        prefix: String,
        suffix: String,
        prefixStartsAtFileStart: Bool,
        suffixEndsAtFileEnd: Bool,
        fileHead: String = ""
    ) {
        self.relativePath = relativePath
        self.prefix = prefix
        self.suffix = suffix
        self.prefixStartsAtFileStart = prefixStartsAtFileStart
        self.suffixEndsAtFileEnd = suffixEndsAtFileEnd
        self.fileHead = fileHead
    }
}

public struct CompletionContext: Sendable, Equatable {
    public var relativePath: String
    public var prefix: String
    public var suffix: String
    public var header: String?
    public var multiline: Bool
    public var linePrefix: String
    public var lineSuffix: String
    public var anchorIndent: String

    public init(
        relativePath: String,
        prefix: String,
        suffix: String,
        header: String? = nil,
        multiline: Bool,
        linePrefix: String? = nil,
        lineSuffix: String? = nil,
        anchorIndent: String? = nil
    ) {
        self.relativePath = relativePath
        self.prefix = prefix
        self.suffix = suffix
        self.header = header
        self.multiline = multiline
        let line = linePrefix ?? CompletionText.lastLine(of: prefix)
        self.linePrefix = line
        self.lineSuffix = lineSuffix ?? CompletionText.firstLine(of: suffix)
        self.anchorIndent = anchorIndent ?? CompletionText.leadingWhitespace(of: line)
    }
}

public enum CompletionSkipReason: String, Sendable, Equatable {
    case unsupportedLanguage
    case excludedPath
    case secretNearCursor
    case textAfterCursor
}

public enum CompletionBuildResult: Sendable, Equatable {
    case ready(CompletionContext)
    case skip(CompletionSkipReason)

    public var context: CompletionContext? {
        if case .ready(let context) = self { return context }
        return nil
    }

    public var skipReason: CompletionSkipReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

public enum CompletionFailure: Error, Sendable, Equatable {
    case unauthorized(status: Int)
    case endpointNotFound
    case rateLimited(retryAfterSeconds: Int?)
    case server(status: Int)
    case timeout
    case offline
    case invalidResponse(String)
    case invalidConfiguration
    case consentRequired(host: String)

    public var shortReason: String {
        switch self {
        case .unauthorized: return "Check the API key"
        case .endpointNotFound: return "Model or endpoint not found"
        case .rateLimited: return "Rate limited by the provider"
        case .server(let status): return "Provider error (\(status))"
        case .timeout: return "The provider took too long"
        case .offline: return "Can’t reach the provider"
        case .invalidResponse: return "Unexpected response"
        case .invalidConfiguration: return "Provider settings are incomplete"
        case .consentRequired(let host): return "Permission required for \(host)"
        }
    }

    public var requiresSettingsChange: Bool {
        switch self {
        case .unauthorized, .endpointNotFound, .invalidConfiguration, .consentRequired: return true
        default: return false
        }
    }
}

enum CompletionText {
    static func lastLine(of text: String) -> String {
        guard let newline = text.lastIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    static func firstLine(of text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[..<newline])
    }

    static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    static func isBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func indentWidth(_ indent: some StringProtocol) -> Int {
        var width = 0
        for ch in indent {
            if ch == "\t" { width += 4 } else if ch == " " { width += 1 } else { break }
        }
        return width
    }
}
