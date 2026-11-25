import Foundation
import GopilotPolicy

public struct CompletionContextLimits: Sendable, Equatable {
    public var prefixCharacters: Int
    public var suffixCharacters: Int
    public var headerCharacters: Int
    public var secretGuardCharacters: Int

    public init(prefixCharacters: Int = 6_000, suffixCharacters: Int = 2_000, headerCharacters: Int = 1_500, secretGuardCharacters: Int = 200) {
        self.prefixCharacters = prefixCharacters
        self.suffixCharacters = suffixCharacters
        self.headerCharacters = headerCharacters
        self.secretGuardCharacters = secretGuardCharacters
    }
}

public struct CompletionContextBuilder: Sendable {
    public static let supportedExtensions: Set<String> = ["go"]
    public static let allowedAfterCursor: Set<Character> = [")", "]", "}", "\"", "'", "`", ",", ";", ":", " ", "\t"]

    public let limits: CompletionContextLimits
    public let secretFilter: SecretFilter
    public let pathPolicy: PathPolicy?
    public let length: CompletionLengthPreference

    public init(
        limits: CompletionContextLimits = CompletionContextLimits(),
        secretFilter: SecretFilter = SecretFilter(),
        pathPolicy: PathPolicy?,
        length: CompletionLengthPreference = .automatic
    ) {
        self.limits = limits
        self.secretFilter = secretFilter
        self.pathPolicy = pathPolicy
        self.length = length
    }

    public static func isSupported(path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public func build(_ snapshot: CompletionSnapshot) -> CompletionBuildResult {
        guard Self.isSupported(path: snapshot.relativePath) else { return .skip(.unsupportedLanguage) }
        if let pathPolicy {
            if case .denied = pathPolicy.evaluate(relativePath: snapshot.relativePath, mustExist: false) {
                return .skip(.excludedPath)
            }
        } else if PathPolicy(workspaceRoots: []).isExcluded(relativePath: snapshot.relativePath) {
            return .skip(.excludedPath)
        }

        let prefix = Self.prefixWindow(snapshot.prefix, startsAtFileStart: snapshot.prefixStartsAtFileStart, limit: limits.prefixCharacters)
        let suffix = Self.suffixWindow(snapshot.suffix, endsAtFileEnd: snapshot.suffixEndsAtFileEnd, limit: limits.suffixCharacters)
        let lineSuffix = CompletionText.firstLine(of: suffix)
        guard lineSuffix.allSatisfy({ Self.allowedAfterCursor.contains($0) }) else { return .skip(.textAfterCursor) }

        let redactedPrefix = secretFilter.redact(prefix)
        if redactedPrefix.didRedact,
           String(prefix.suffix(limits.secretGuardCharacters)) != String(redactedPrefix.text.suffix(limits.secretGuardCharacters)) {
            return .skip(.secretNearCursor)
        }
        let redactedSuffix = secretFilter.redact(suffix).text

        var header: String?
        if !snapshot.prefixStartsAtFileStart {
            let extracted = Self.header(from: snapshot.fileHead, limit: limits.headerCharacters)
            if !extracted.isEmpty, !prefix.hasPrefix(extracted) {
                header = secretFilter.redact(extracted).text
            }
        }

        let linePrefix = CompletionText.lastLine(of: redactedPrefix.text)
        let multiline = length == .automatic && CompletionText.isBlank(lineSuffix)
        return .ready(CompletionContext(
            relativePath: snapshot.relativePath,
            prefix: redactedPrefix.text,
            suffix: redactedSuffix,
            header: header,
            multiline: multiline,
            linePrefix: linePrefix,
            lineSuffix: CompletionText.firstLine(of: redactedSuffix)
        ))
    }

    static func prefixWindow(_ text: String, startsAtFileStart: Bool, limit: Int) -> String {
        var window = Substring(text)
        var trimmedFront = !startsAtFileStart
        if window.count > limit {
            window = window.suffix(limit)
            trimmedFront = true
        }
        if trimmedFront, let newline = window.firstIndex(of: "\n") {
            window = window[window.index(after: newline)...]
        }
        return String(window)
    }

    static func suffixWindow(_ text: String, endsAtFileEnd: Bool, limit: Int) -> String {
        var window = Substring(text)
        var trimmedBack = !endsAtFileEnd
        if window.count > limit {
            window = window.prefix(limit)
            trimmedBack = true
        }
        if trimmedBack, let firstNewline = window.firstIndex(of: "\n"), let lastNewline = window.lastIndex(of: "\n"), lastNewline > firstNewline {
            window = window[...lastNewline]
        }
        return String(window)
    }

    static func header(from fileHead: String, limit: Int) -> String {
        var kept: [Substring] = []
        var inImportBlock = false
        var sawPackage = false
        for line in fileHead.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inImportBlock {
                kept.append(line)
                if trimmed == ")" { inImportBlock = false }
                continue
            }
            if trimmed.hasPrefix("package ") {
                kept.append(line)
                sawPackage = true
            } else if sawPackage, trimmed.hasPrefix("import (") {
                kept.append(line)
                inImportBlock = !trimmed.hasSuffix(")")
            } else if sawPackage, trimmed.hasPrefix("import ") {
                kept.append(line)
            } else if sawPackage, trimmed.hasPrefix("func ") || trimmed.hasPrefix("type ") || trimmed.hasPrefix("var ") || trimmed.hasPrefix("const ") {
                break
            }
        }
        guard sawPackage else { return "" }
        if inImportBlock { kept.append(")") }
        let joined = kept.joined(separator: "\n")
        return joined.count > limit ? String(joined.prefix(limit)) : joined
    }
}
