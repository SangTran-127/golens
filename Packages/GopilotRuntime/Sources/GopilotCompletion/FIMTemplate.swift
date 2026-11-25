import Foundation

public enum FIMTemplate: String, Sendable, Codable, CaseIterable {
    case suffixParameter = "suffix"
    case qwen
    case codestral
    case deepSeekCoder = "deepseek"
    case starCoder = "starcoder"

    public var isRawTemplate: Bool { self != .suffixParameter }

    public var displayName: String {
        switch self {
        case .suffixParameter: return "Suffix Parameter"
        case .qwen: return "Qwen2.5-Coder"
        case .codestral: return "Codestral"
        case .deepSeekCoder: return "DeepSeek Coder"
        case .starCoder: return "StarCoder"
        }
    }

    public var stopTokens: [String] {
        switch self {
        case .suffixParameter: return []
        case .qwen: return ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|fim_prefix|>"]
        case .codestral: return ["</s>", "[PREFIX]", "[SUFFIX]"]
        case .deepSeekCoder: return ["<｜end▁of▁sentence｜>", "<｜fim▁begin｜>"]
        case .starCoder: return ["<|endoftext|>", "<file_sep>"]
        }
    }

    public var controlTokens: [String] {
        switch self {
        case .suffixParameter: return []
        case .qwen: return ["<|fim_suffix|>", "<|fim_middle|>", "<|im_end|>"] + stopTokens
        case .codestral: return ["[SUFFIX]", "[PREFIX]", "[MIDDLE]"] + stopTokens
        case .deepSeekCoder: return ["<｜fim▁begin｜>", "<｜fim▁hole｜>", "<｜fim▁end｜>"] + stopTokens
        case .starCoder: return ["<fim_prefix>", "<fim_suffix>", "<fim_middle>"] + stopTokens
        }
    }

    public func prompt(prefix: String, suffix: String) -> String {
        switch self {
        case .suffixParameter: return prefix
        case .qwen: return "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
        case .codestral: return "[SUFFIX]\(suffix)[PREFIX]\(prefix)"
        case .deepSeekCoder: return "<｜fim▁begin｜>\(prefix)<｜fim▁hole｜>\(suffix)<｜fim▁end｜>"
        case .starCoder: return "<fim_prefix>\(prefix)<fim_suffix>\(suffix)<fim_middle>"
        }
    }

    public static func suggested(forModelID modelID: String) -> FIMTemplate {
        let id = modelID.lowercased()
        if id.contains("qwen") && id.contains("coder") { return .qwen }
        if id.contains("deepseek-coder") || id.contains("deepseek_coder") { return .deepSeekCoder }
        if id.contains("starcoder") { return .starCoder }
        return .suffixParameter
    }

    static let allControlTokens: [String] = {
        var seen = Set<String>()
        return FIMTemplate.allCases.flatMap(\.controlTokens).filter { seen.insert($0).inserted }
    }()
}
