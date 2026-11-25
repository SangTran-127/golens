import Foundation

public struct DependencyRoot: Sendable, Equatable {
    public let id: String
    public let path: String

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

public struct ResolvedPath: Sendable, Equatable {
    public let relativePath: String
    public let dependencyRootID: String?
    public let url: URL

    public init(relativePath: String, dependencyRootID: String?, url: URL) {
        self.relativePath = relativePath
        self.dependencyRootID = dependencyRootID
        self.url = url
    }
}

public enum ExclusionRule: Sendable, Equatable {
    case gitInternals
    case environmentFile
    case privateKeyOrCertificate
    case credentialFile
    case buildArtifact
    case binaryFile
    case userPattern(String)

    public var isOverridable: Bool {
        switch self {
        case .environmentFile, .buildArtifact, .userPattern: return true
        case .gitInternals, .privateKeyOrCertificate, .credentialFile, .binaryFile: return false
        }
    }
}

public enum PathDenial: Error, Sendable, Equatable {
    case empty
    case tooLong
    case nulCharacter
    case absolutePath
    case traversal
    case outsideAllowedRoots
    case dependencyRootNotApproved(String)
    case excluded(ExclusionRule)
    case notFound
    case previewRequired
}

public enum PathDecision: Sendable, Equatable {
    case allowed(ResolvedPath)
    case denied(PathDenial)

    public var resolved: ResolvedPath? {
        if case .allowed(let path) = self { return path }
        return nil
    }

    public var denial: PathDenial? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}

public struct PathPolicy: Sendable {
    public static let defaultMaxPathLength = 1024

    private let workspaceRoots: [String]
    private let dependencyRoots: [String: String]
    private let userPatterns: [String]
    private let maxPathLength: Int
    private let overrides: Set<String>

    public init(workspaceRoots: [URL], approvedDependencyRoots: [DependencyRoot] = [], userExcludePatterns: [String] = [], maxPathLength: Int = PathPolicy.defaultMaxPathLength) {
        self.workspaceRoots = workspaceRoots.compactMap { Self.realPath($0.path) }
        var deps: [String: String] = [:]
        for root in approvedDependencyRoots {
            if let real = Self.realPath(root.path) { deps[root.id] = real }
        }
        dependencyRoots = deps
        userPatterns = userExcludePatterns
        self.maxPathLength = maxPathLength
        overrides = []
    }

    private init(copying other: PathPolicy, overrides: Set<String>) {
        workspaceRoots = other.workspaceRoots
        dependencyRoots = other.dependencyRoots
        userPatterns = other.userPatterns
        maxPathLength = other.maxPathLength
        self.overrides = overrides
    }

    public func approvingDependencyRoot(_ root: DependencyRoot) -> PathPolicy {
        var copy = dependencyRoots
        if let real = Self.realPath(root.path) { copy[root.id] = real }
        return PathPolicy(workspaceRoots: workspaceRoots, dependencyRoots: copy, userPatterns: userPatterns, maxPathLength: maxPathLength, overrides: overrides)
    }

    private init(workspaceRoots: [String], dependencyRoots: [String: String], userPatterns: [String], maxPathLength: Int, overrides: Set<String>) {
        self.workspaceRoots = workspaceRoots
        self.dependencyRoots = dependencyRoots
        self.userPatterns = userPatterns
        self.maxPathLength = maxPathLength
        self.overrides = overrides
    }

    public func evaluate(relativePath: String, dependencyRootID: String? = nil, allowsRoot: Bool = false, mustExist: Bool = true) -> PathDecision {
        evaluate(relativePath: insideWorkspaceRelative(relativePath, dependencyRootID: dependencyRootID), dependencyRootID: dependencyRootID, allowsRoot: allowsRoot, ignoringOverridableRules: false, mustExist: mustExist)
    }

    private func insideWorkspaceRelative(_ path: String, dependencyRootID: String?) -> String {
        guard dependencyRootID == nil, path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return path }
        let candidates = [(path as NSString).standardizingPath, Self.realPath(path)].compactMap { $0 }
        for candidate in candidates {
            for root in workspaceRoots {
                if candidate == root { return "" }
                if candidate.hasPrefix(root + "/") { return String(candidate.dropFirst(root.count + 1)) }
            }
        }
        return path
    }

    public func attachOverride(relativePath: String, dependencyRootID: String? = nil, previewConfirmed: Bool) -> Result<PathPolicy, PathDenial> {
        guard previewConfirmed else { return .failure(.previewRequired) }
        switch evaluate(relativePath: relativePath, dependencyRootID: dependencyRootID, allowsRoot: false, ignoringOverridableRules: true, mustExist: true) {
        case .denied(let reason):
            return .failure(reason)
        case .allowed(let resolved):
            var next = overrides
            next.insert(resolved.url.path)
            return .success(PathPolicy(copying: self, overrides: next))
        }
    }

    public func isApproved(dependencyRootID: String) -> Bool {
        dependencyRoots[dependencyRootID] != nil
    }

    public func lexicalExclusion(relativePath: String) -> ExclusionRule? {
        guard case .success(let components) = Self.components(of: relativePath, maxLength: maxPathLength, allowsEmpty: true) else { return nil }
        return exclusion(for: components)
    }

    public func isExcluded(relativePath: String) -> Bool {
        guard case .success(let components) = Self.components(of: relativePath, maxLength: maxPathLength, allowsEmpty: true) else { return true }
        return exclusion(for: components) != nil
    }

    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.contains(0) { return true }
        if String(data: sample, encoding: .utf8) != nil { return false }
        for trim in 1...3 where sample.count > trim {
            if String(data: sample.dropLast(trim), encoding: .utf8) != nil { return false }
        }
        return true
    }

    private func evaluate(relativePath: String, dependencyRootID: String?, allowsRoot: Bool, ignoringOverridableRules: Bool, mustExist: Bool) -> PathDecision {
        let components: [String]
        switch Self.components(of: relativePath, maxLength: maxPathLength, allowsEmpty: allowsRoot) {
        case .failure(let denial): return .denied(denial)
        case .success(let parts): components = parts
        }

        let lexicalRule = exclusion(for: components)
        if let rule = lexicalRule, !rule.isOverridable { return .denied(.excluded(rule)) }

        let roots: [String]
        if let rootID = dependencyRootID {
            guard let root = dependencyRoots[rootID] else { return .denied(.dependencyRootNotApproved(rootID)) }
            roots = [root]
        } else {
            roots = workspaceRoots
        }

        var denial: PathDenial = .notFound
        for root in roots {
            let candidate = components.isEmpty ? root : root + "/" + components.joined(separator: "/")
            let resolvedCandidate: String?
            if let existingReal = Self.realPath(candidate) {
                resolvedCandidate = existingReal
            } else if !mustExist {
                switch Self.resolveNonExistentTarget(root: root, components: components) {
                case .resolved(let constructed):
                    resolvedCandidate = constructed
                case .outsideRoot:
                    denial = .outsideAllowedRoots
                    continue
                case .unresolved:
                    resolvedCandidate = nil
                }
            } else {
                resolvedCandidate = nil
            }
            guard let real = resolvedCandidate else { continue }
            guard Self.contains(root: root, path: real) else {
                denial = .outsideAllowedRoots
                continue
            }
            let realRelative = Self.relative(real, to: root)
            let realRule = exclusion(for: realRelative.split(separator: "/").map(String.init))
            for rule in [lexicalRule, realRule].compactMap({ $0 }) {
                if !rule.isOverridable { return .denied(.excluded(rule)) }
                if !ignoringOverridableRules && !overrides.contains(real) { return .denied(.excluded(rule)) }
            }
            return .allowed(ResolvedPath(relativePath: components.joined(separator: "/"), dependencyRootID: dependencyRootID, url: URL(fileURLWithPath: real)))
        }
        return .denied(denial)
    }

    private enum NonExistentResolution {
        case resolved(String)
        case outsideRoot
        case unresolved
    }

    private static func resolveNonExistentTarget(root: String, components: [String]) -> NonExistentResolution {
        for k in stride(from: components.count - 1, through: 0, by: -1) {
            let prefixPath = k == 0 ? root : root + "/" + components[0..<k].joined(separator: "/")
            if let realPrefix = realPath(prefixPath) {
                guard contains(root: root, path: realPrefix) else {
                    return .outsideRoot
                }
                let nextComponentPath = prefixPath + "/" + components[k]
                var st = stat()
                if lstat(nextComponentPath, &st) == 0 {
                    return .outsideRoot
                }
                let suffix = components[k...].joined(separator: "/")
                return .resolved(realPrefix + "/" + suffix)
            }
        }
        return .unresolved
    }

    private static func components(of path: String, maxLength: Int, allowsEmpty: Bool) -> Result<[String], PathDenial> {
        if path.unicodeScalars.contains(where: { $0.value == 0 }) { return .failure(.nulCharacter) }
        if path.utf8.count > maxLength { return .failure(.tooLong) }
        if path.hasPrefix("/") || path.hasPrefix("~") { return .failure(.absolutePath) }
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", scalars[0].properties.isAlphabetic { return .failure(.absolutePath) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") { return .failure(.traversal) }
        let kept = parts.filter { $0 != "." }
        if kept.isEmpty && !allowsEmpty { return .failure(.empty) }
        return .success(kept)
    }

    private func exclusion(for components: [String]) -> ExclusionRule? {
        let lowered = components.map { $0.lowercased() }
        guard let name = lowered.last else { return nil }

        if lowered.contains(".git") { return .gitInternals }

        let keyExtensions: Set<String> = ["pem", "p12", "pfx", "key", "p8", "jks", "keystore", "kdbx", "ppk"]
        let keyNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
        let ext = (name as NSString).pathExtension
        if keyExtensions.contains(ext) || keyNames.contains(name) || (name.hasPrefix("id_") && !name.hasSuffix(".pub"))
            || lowered.contains(".ssh") || lowered.contains(".gnupg") {
            return .privateKeyOrCertificate
        }

        let credentialNames: Set<String> = [".netrc", "_netrc", ".npmrc", ".pypirc", ".dockercfg", ".htpasswd", ".git-credentials",
                                            "credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml", "service-account.json",
                                            "kubeconfig"]
        let credentialExtensions: Set<String> = ["tfvars", "tfstate"]
        let isServiceAccountJSON = (name.contains("service-account") || name.contains("serviceaccount")) && ext == "json"
        let isCredentialsJSON = name.contains("credentials") && (ext == "json" || ext == "yaml" || ext == "yml")
        let isTerraformStateOrVars = credentialExtensions.contains(ext) || name.hasSuffix(".tfvars.json") || name.contains(".tfstate.")
        let isKubeconfig = name.hasPrefix("kubeconfig") || name.hasSuffix(".kubeconfig") || name.contains(".kubeconfig.")
        if credentialNames.contains(name) || name.hasPrefix("credentials.")
            || isCredentialsJSON || isServiceAccountJSON || isTerraformStateOrVars || isKubeconfig
            || lowered.contains(".aws") || lowered.contains(".kube") || lowered.contains(".docker") {
            return .credentialFile
        }

        let binaryExtensions: Set<String> = ["o", "a", "dylib", "so", "dll", "exe", "test", "out", "class", "pyc", "png", "jpg", "jpeg", "gif", "ico",
                                             "pdf", "zip", "gz", "tar", "tgz", "xz", "bz2", "7z", "jar", "woff", "woff2", "ttf", "otf", "mp3", "mp4",
                                             "mov", "wasm", "sqlite", "db", "bin", "dmg", "heic", "webp"]
        if binaryExtensions.contains(ext) { return .binaryFile }

        if name.hasPrefix(".env") { return .environmentFile }

        let artifactDirs: Set<String> = [".build", "node_modules", "deriveddata", "dist", "__pycache__", ".gradle"]
        if lowered.contains(where: { artifactDirs.contains($0) }) { return .buildArtifact }

        let joined = components.joined(separator: "/")
        for pattern in userPatterns where Glob.matches(pattern: pattern, path: joined) {
            return .userPattern(pattern)
        }
        return nil
    }

    private static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func relative(_ path: String, to root: String) -> String {
        guard path != root else { return "" }
        return String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum Glob {
    static func matches(pattern: String, path: String) -> Bool {
        var trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let rootAnchored = trimmed.hasPrefix("/")
        if rootAnchored { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let regex = regex(for: trimmed) else { return false }
        if !rootAnchored && !trimmed.contains("/") {
            return path.split(separator: "/").contains { piece in
                regex.firstMatch(in: String(piece), range: NSRange(location: 0, length: (String(piece) as NSString).length)) != nil
            }
        }
        return regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    private static func regex(for glob: String) -> NSRegularExpression? {
        var out = "^"
        let chars = Array(glob)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "*" {
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        out += "(?:.*/)?"
                        index += 3
                    } else {
                        out += ".*"
                        index += 2
                    }
                    continue
                }
                out += "[^/]*"
            } else if char == "?" {
                out += "[^/]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        out += "(?:/.*)?$"
        return try? NSRegularExpression(pattern: out)
    }
}
