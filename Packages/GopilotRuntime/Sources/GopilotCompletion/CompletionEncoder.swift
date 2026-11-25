import Foundation
import GopilotProvider

public struct CompletionRequestOptions: Sendable, Equatable {
    public var model: String
    public var dialect: CompletionDialect
    public var maxTokensParameter: MaxTokensParameter
    public var stream: Bool
    public var singleLineMaxTokens: Int
    public var multilineMaxTokens: Int
    public var fimTemplate: FIMTemplate
    public var rawTemplatePrefixCharacters: Int
    public var rawTemplateSuffixCharacters: Int

    public init(
        model: String,
        dialect: CompletionDialect = .chatHoleFill,
        maxTokensParameter: MaxTokensParameter = .maxTokens,
        stream: Bool = true,
        singleLineMaxTokens: Int = 64,
        multilineMaxTokens: Int = 256,
        fimTemplate: FIMTemplate = .suffixParameter,
        rawTemplatePrefixCharacters: Int = 1_500,
        rawTemplateSuffixCharacters: Int = 500
    ) {
        self.model = model
        self.dialect = dialect
        self.maxTokensParameter = maxTokensParameter
        self.stream = stream
        self.singleLineMaxTokens = singleLineMaxTokens
        self.multilineMaxTokens = multilineMaxTokens
        self.fimTemplate = fimTemplate
        self.rawTemplatePrefixCharacters = rawTemplatePrefixCharacters
        self.rawTemplateSuffixCharacters = rawTemplateSuffixCharacters
    }

    public func maxTokens(for context: CompletionContext) -> Int {
        context.multiline ? multilineMaxTokens : singleLineMaxTokens
    }
}

public enum CompletionEncoder {
    public static let cursorMarker = "<CURSOR>"
    public static let systemPrompt = "You are a code completion engine inside a Go editor. Output only the exact text that replaces <CURSOR> so the file compiles. No prose, no markdown fences, do not repeat code before or after the cursor."
    public static let singleLineInstruction = " Complete only the rest of the current line."
    public static let multilineInstruction = " Complete at most the current statement or block."

    public static func chatUserContent(_ context: CompletionContext) -> String {
        var text = "// path: \(context.relativePath)\n"
        if let header = context.header, !header.isEmpty {
            text += header + "\n\n"
        }
        text += context.prefix + cursorMarker + context.suffix
        return text
    }

    public static func fimPrompt(_ context: CompletionContext) -> String {
        guard let header = context.header, !header.isEmpty else { return context.prefix }
        return header + "\n\n" + context.prefix
    }

    public static func fimStops(_ context: CompletionContext) -> [String] {
        guard context.multiline else { return ["\n"] }
        return closesEnclosingBlockNext(context) ? [] : ["\n\n"]
    }

    static func closesEnclosingBlockNext(_ context: CompletionContext) -> Bool {
        guard CompletionText.isBlank(context.lineSuffix) else { return false }
        for line in context.suffix.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = CompletionText.trimmed(line)
            if trimmed.isEmpty { continue }
            return trimmed.hasPrefix("}")
        }
        return false
    }

    public static func body(_ context: CompletionContext, options: CompletionRequestOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "temperature": 0,
            "stream": options.stream,
            options.maxTokensParameter.rawValue: options.maxTokens(for: context)
        ]
        switch options.dialect {
        case .chatHoleFill:
            let instruction = systemPrompt + (context.multiline ? multilineInstruction : singleLineInstruction)
            body["messages"] = [
                ["role": "system", "content": instruction],
                ["role": "user", "content": chatUserContent(context)]
            ]
        case .fillInTheMiddle:
            let template = options.fimTemplate
            if template.isRawTemplate {
                let prefix = trimmedPrefix(fimPrompt(context), limit: options.rawTemplatePrefixCharacters)
                let suffix = trimmedSuffix(context.suffix, limit: options.rawTemplateSuffixCharacters)
                body["prompt"] = template.prompt(prefix: prefix, suffix: suffix)
                body["stop"] = fimStops(context) + template.stopTokens
            } else {
                body["prompt"] = fimPrompt(context)
                body["suffix"] = context.suffix
                body["stop"] = fimStops(context)
            }
        }
        return body
    }

    static func trimmedPrefix(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = text.suffix(limit)
        guard let newline = window.firstIndex(of: "\n") else { return String(window) }
        return String(window[window.index(after: newline)...])
    }

    static func trimmedSuffix(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = text.prefix(limit)
        guard let first = window.firstIndex(of: "\n"), let last = window.lastIndex(of: "\n"), last > first else { return String(window) }
        return String(window[...last])
    }

    public static func encode(_ context: CompletionContext, options: CompletionRequestOptions) throws -> Data {
        try JSONSerialization.data(withJSONObject: body(context, options: options), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func endpointURL(chatCompletionsURL: URL, dialect: CompletionDialect) -> URL {
        switch dialect {
        case .chatHoleFill:
            return chatCompletionsURL
        case .fillInTheMiddle:
            guard var components = URLComponents(url: chatCompletionsURL, resolvingAgainstBaseURL: false) else { return chatCompletionsURL }
            var path = components.path
            if path.hasSuffix("/chat/completions") {
                path.removeLast("/chat/completions".count)
            }
            components.path = path + "/completions"
            return components.url ?? chatCompletionsURL
        }
    }
}
