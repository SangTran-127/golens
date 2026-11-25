import Foundation

public struct DocsTargetDTO: Codable, Hashable, Sendable {
    public var goos: String
    public var goarch: String
    public var tags: String
    public var includeStd: Bool
    public var includeUnexported: Bool
    public var scope: String

    public init(
        goos: String = "",
        goarch: String = "",
        tags: String = "",
        includeStd: Bool = false,
        includeUnexported: Bool = false,
        scope: String = "all"
    ) {
        self.goos = goos
        self.goarch = goarch
        self.tags = tags
        self.includeStd = includeStd
        self.includeUnexported = includeUnexported
        self.scope = scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goos = try c.decodeIfPresent(String.self, forKey: .goos) ?? ""
        goarch = try c.decodeIfPresent(String.self, forKey: .goarch) ?? ""
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        includeStd = try c.decodeIfPresent(Bool.self, forKey: .includeStd) ?? false
        includeUnexported = try c.decodeIfPresent(Bool.self, forKey: .includeUnexported) ?? false
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "all"
    }

    public var displayLabel: String {
        let base = [goos, goarch].filter { !$0.isEmpty }.joined(separator: "/")
        let trimmedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTags.isEmpty { return base.isEmpty ? "Host Default" : base }
        return base.isEmpty ? trimmedTags : "\(base) · \(trimmedTags)"
    }

    public var targetKey: String {
        "\(goos)|\(goarch)|\(tags.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public struct DocsReplaceDTO: Codable, Hashable, Sendable {
    public let path: String
    public let version, dir: String?
}

public struct DocsModuleDTO: Codable, Hashable, Sendable, Identifiable {
    public let path, source: String
    public let version, dir, goVersion, error, errorKind: String?
    public let main, missing: Bool?
    public let replace: DocsReplaceDTO?
    public var id: String { path }
    public var isMain: Bool { main ?? false }
    public var isMissing: Bool { missing ?? false }

    public var versionBadge: String {
        if source == "local-replace" { return "Local replacement" }
        if let version, !version.isEmpty { return version }
        switch source {
        case "workspace": return "Workspace"
        case "vendor": return "Vendored"
        case "stdlib": return "Standard library"
        default: return source
        }
    }
}

public struct DocsPackageDTO: Codable, Hashable, Sendable, Identifiable {
    public let importPath, origin: String
    public let name, synopsis, dir, modulePath, source, version, error, errorKind, missingModule, missingVersion: String?
    public let missing: Bool?
    public let goFiles, ignoredGoFiles, testGoFiles, xTestGoFiles: [String]?
    public var id: String { importPath }
    public var isMissing: Bool { missing ?? false }
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return importPath.split(separator: "/").last.map(String.init) ?? importPath
    }
}

public struct DocsIndexDTO: Codable, Hashable, Sendable {
    public let root: String
    public let goVersion, goWork, goMod, error, errorKind: String?
    public let vendor, cancelled: Bool?
    public let target: DocsTargetDTO
    public let modules: [DocsModuleDTO]?
    public let packages: [DocsPackageDTO]?
    public let errors: [String]?
    public let generation: Int64?
}

public struct DocsPositionDTO: Codable, Hashable, Sendable {
    public let file: String
    public let line, column: Int
}

public struct DocsExampleDTO: Codable, Hashable, Sendable, Identifiable {
    public let name, code: String
    public let suffix, doc, output: String?
    public let unordered: Bool?
    public let position: DocsPositionDTO
    public var id: String { "\(name)#\(position.line):\(position.column)" }
}

public struct DocsSymbolDTO: Codable, Hashable, Sendable, Identifiable {
    public let name, kind, signature: String
    public let recv, doc: String?
    public let missingDoc, generic, alias, exported: Bool?
    public let position: DocsPositionDTO
    public let examples: [DocsExampleDTO]?
    public let funcs, methods: [DocsSymbolDTO]?

    public var id: String {
        if let recv, !recv.isEmpty { return "\(kind):\(recv).\(name)" }
        return "\(kind):\(name):\(position.line)"
    }

    public var anchorName: String {
        if let recv, !recv.isEmpty {
            let cleanRecv = recv.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                .split(separator: "[").first.map(String.init) ?? recv
            return "\(cleanRecv).\(name)"
        }
        return name
    }
}

public struct DocsExcludedSymbolDTO: Codable, Hashable, Sendable, Identifiable {
    public let name, kind, reason, file: String
    public let build: String?
    public let position: DocsPositionDTO
    public var id: String { "\(reason):\(name):\(file):\(position.line)" }
}

public struct DocsPackageDocDTO: Codable, Hashable, Sendable {
    public let importPath: String
    public let root, name, dir, origin, source, modulePath, version, replacePath, replaceDir: String?
    public let synopsis, doc, missingModule, missingVersion, error, errorKind: String?
    public let generation: Int64?
    public let missingDoc, missingSource, cancelled, includeUnexported: Bool?
    public let target: DocsTargetDTO
    public let fromBuffer, parseErrors: [String]?
    public let consts, vars, funcs, types: [DocsSymbolDTO]?
    public let examples: [DocsExampleDTO]?
    public let excluded: [DocsExcludedSymbolDTO]?
}

public struct DocsSearchResultDTO: Codable, Hashable, Sendable, Identifiable {
    public let importPath, kind, origin, source: String
    public let packageName, symbol, signature, modulePath, version, build: String?
    public let excluded, missing: Bool?
    public var id: String { "\(origin)|\(importPath)|\(symbol ?? "")|\(kind)|\(excluded ?? false)" }
}

public struct DocsSearchResponseDTO: Codable, Hashable, Sendable {
    public let root, query, error: String?
    public let target: DocsTargetDTO
    public let generation: Int64?
    public let results: [DocsSearchResultDTO]?
    public let cancelled: Bool?
}

public enum DocsSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, project, dependencies, stdlib
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All"
        case .project: "Project"
        case .dependencies: "Dependencies"
        case .stdlib: "Stdlib"
        }
    }
}

public enum DocsRoute: Codable, Hashable, Sendable {
    case module(path: String)
    case package(importPath: String, symbol: String?)

    public var importPath: String? {
        if case .package(let path, _) = self { return path }
        return nil
    }

    public var symbolAnchor: String? {
        if case .package(_, let symbol) = self { return symbol }
        return nil
    }
}

public enum DocsDocLinkParser {
    public static let scheme = "golens-doc"

    public static func url(importPath: String, symbol: String? = nil) -> URL? {
        let trimmed = importPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var raw = "\(scheme):\(trimmed)"
        if let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty { raw += "#\(symbol)" }
        return URL(string: raw)
    }

    public static func parse(_ url: URL) -> DocsRoute? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let raw = url.absoluteString
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let body = String(raw[raw.index(after: colon)...])
        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let importPath = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !importPath.isEmpty else { return nil }
        let symbol: String? = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return .package(importPath: importPath, symbol: symbol?.isEmpty == true ? nil : symbol)
    }

    public static func isPublicImportPath(_ importPath: String, origin: String?, source: String?) -> Bool {
        if origin == "project" || source == "local-replace" || source == "workspace" { return false }
        if origin == "stdlib" || source == "stdlib" { return !importPath.isEmpty && importPath != "main" }
        guard let first = importPath.split(separator: "/").first.map(String.init), first.contains(".") else { return false }
        let lower = first.lowercased()
        let blocked = ["example.com", "example.org", "example.net", "localhost"]
        return !blocked.contains(lower) && !lower.hasSuffix(".local") && !lower.hasSuffix(".internal") && !lower.hasSuffix(".test")
    }

    public static func publicPkgGoDevURL(
        importPath: String,
        version: String?,
        source: String?,
        origin: String?,
        symbol: String? = nil
    ) -> (url: URL, hasExactVersion: Bool)? {
        guard isPublicImportPath(importPath, origin: origin, source: source) else { return nil }
        let isStdlib = origin == "stdlib" || source == "stdlib"
        var pathSegment = importPath
        var hasExactVersion = isStdlib
        if !isStdlib, let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            if !(version.contains("-20") && version.contains("-")) {
                pathSegment += "@\(version)"
                hasExactVersion = true
            }
        }
        var raw = "https://pkg.go.dev/\(pathSegment)"
        if let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty { raw += "#\(symbol)" }
        guard let url = URL(string: raw) else { return nil }
        return (url, hasExactVersion)
    }
}

public struct DocsHistoryEntry: Equatable, Sendable {
    public let route: DocsRoute
    public var scrollTarget: String
    public init(route: DocsRoute, scrollTarget: String = "") {
        self.route = route
        self.scrollTarget = scrollTarget
    }
}

public struct DocsHistoryStack: Sendable {
    public static let maxEntries = 100
    public private(set) var entries: [DocsHistoryEntry] = []
    public private(set) var currentIndex: Int = -1
    public init() {}
    public var currentEntry: DocsHistoryEntry? { entries.indices.contains(currentIndex) ? entries[currentIndex] : nil }
    public var canGoBack: Bool { currentIndex > 0 }
    public var canGoForward: Bool { currentIndex >= 0 && currentIndex + 1 < entries.count }

    public mutating func push(_ route: DocsRoute, scrollTarget: String? = nil) {
        let next = DocsHistoryEntry(route: route, scrollTarget: scrollTarget ?? route.symbolAnchor ?? "")
        if currentEntry == next { return }
        if currentIndex >= 0 && currentIndex + 1 < entries.count { entries.removeSubrange((currentIndex + 1)..<entries.count) }
        entries.append(next)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        currentIndex = entries.count - 1
    }

    public mutating func updateCurrentScrollTarget(_ scrollTarget: String) {
        if entries.indices.contains(currentIndex) { entries[currentIndex].scrollTarget = scrollTarget }
    }

    public mutating func goBack() -> DocsHistoryEntry? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return entries[currentIndex]
    }

    public mutating func goForward() -> DocsHistoryEntry? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return entries[currentIndex]
    }

    public mutating func clear() {
        entries.removeAll()
        currentIndex = -1
    }
}

public struct DocsHoverResolution: Equatable, Sendable {
    public let importPath: String?
    public let symbolName: String?
    public init(importPath: String?, symbolName: String?) {
        self.importPath = importPath
        self.symbolName = symbolName
    }
}

public enum DocsHoverResolver {
    public static func resolve(rawMarkdown: String, signature: String?, activeFileDirPackage: String? = nil) -> DocsHoverResolution {
        if let linked = extractPkgGoDevLink(from: rawMarkdown) {
            return DocsHoverResolution(importPath: linked.importPath, symbolName: linked.symbol ?? extractSymbolName(from: signature))
        }
        return DocsHoverResolution(
            importPath: extractPackagePath(from: rawMarkdown) ?? activeFileDirPackage,
            symbolName: extractSymbolName(from: signature)
        )
    }

    public static func extractPkgGoDevLink(from text: String) -> (importPath: String, symbol: String?)? {
        guard let range = text.range(of: "https://pkg.go.dev/") else { return nil }
        let tail = text[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == ")" || $0 == " " || $0 == "\n" || $0 == ">" || $0 == "\"" }) ?? tail.endIndex
        let parts = String(tail[..<end]).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var pkg = String(parts[0])
        if let at = pkg.lastIndex(of: "@"), pkg[pkg.index(after: at)...].hasPrefix("v") { pkg = String(pkg[..<at]) }
        pkg = pkg.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !pkg.isEmpty else { return nil }
        let sym = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return (pkg, sym?.isEmpty == true ? nil : sym)
    }

    public static func extractPackagePath(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("package "), let q1 = trimmed.firstIndex(of: "\""), let q2 = trimmed.lastIndex(of: "\""), q2 > q1 {
                let inner = String(trimmed[trimmed.index(after: q1)..<q2])
                if !inner.isEmpty { return inner }
            }
            if let r = trimmed.range(of: "on package `"), let e = trimmed[r.upperBound...].firstIndex(of: "`") {
                let pkg = String(trimmed[r.upperBound..<e])
                if !pkg.isEmpty { return pkg }
            }
        }
        return nil
    }

    public static func extractSymbolName(from signature: String?) -> String? {
        guard let signature else { return nil }
        for line in signature.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("func ") {
                let rest = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                    let recv = String(rest[rest.index(after: rest.startIndex)..<close])
                    let after = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                    let method = identifierPrefix(after)
                    let rawType = recv.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                    let cleanType = rawType.trimmingCharacters(in: CharacterSet(charactersIn: "*")).split(separator: "[").first.map(String.init) ?? ""
                    if !cleanType.isEmpty, let method { return "\(cleanType).\(method)" }
                    return method
                }
                return identifierPrefix(rest)
            }
            for kw in ["type ", "const ", "var "] where t.hasPrefix(kw) {
                if let name = identifierPrefix(String(t.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)) { return name }
            }
        }
        return nil
    }

    private static func identifierPrefix(_ s: String) -> String? {
        let name = String(s.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        return name.isEmpty ? nil : name
    }
}

public enum DocsChannel: Sendable {
    case index
    case page
    case search
}

public struct DocsChannelGenerations: Equatable, Sendable {
    public private(set) var index: Int64 = 0
    public private(set) var page: Int64 = 0
    public private(set) var search: Int64 = 0

    public init() {}

    public func floor(for channel: DocsChannel) -> Int64 {
        switch channel {
        case .index: return index
        case .page: return page
        case .search: return search
        }
    }

    public mutating func record(_ generation: Int64?, for channel: DocsChannel) {
        guard let generation, generation > 0 else { return }
        switch channel {
        case .index: index = max(index, generation)
        case .page: page = max(page, generation)
        case .search: search = max(search, generation)
        }
    }
}

public enum DocsRequestGuard {
    public static func accepts(
        expectedRoot: String,
        expectedTargetKey: String,
        expectedSerial: Int,
        activeRoot: String,
        activeTargetKey: String,
        activeSerial: Int,
        responseRoot: String?,
        responseGeneration: Int64?,
        minimumGeneration: Int64,
        cancelled: Bool?
    ) -> Bool {
        let canonExpected = WorkspacePathCanonicalizer.canonical(expectedRoot)
        let canonActive = WorkspacePathCanonicalizer.canonical(activeRoot)
        guard cancelled != true, expectedSerial == activeSerial, canonExpected == canonActive, expectedTargetKey == activeTargetKey else { return false }
        if let responseRoot, !responseRoot.isEmpty, WorkspacePathCanonicalizer.canonical(responseRoot) != canonActive { return false }
        if let responseGeneration, responseGeneration > 0, responseGeneration < minimumGeneration { return false }
        return true
    }
}

public enum DocsErrorSanitizer {
    public static func redact(_ raw: String) -> String {
        var result = raw
        for (pattern, template) in [
            ("(https?://)([^/@\\s]+)@", "$1***@"),
            ("(?i)(bearer\\s+)[A-Za-z0-9._\\-+/=]+", "$1***"),
            ("(?i)((?:token|password|secret|apikey|api_key)=)[^\\s&\"']+", "$1***")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }
        return result
    }
}
