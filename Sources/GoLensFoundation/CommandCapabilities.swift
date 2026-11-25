import Foundation

public struct ActiveCommandCapabilities: Equatable, Sendable {
    public var hasWorkspace: Bool
    public var hasActiveFile: Bool
    public var isGoFile: Bool
    public var isGoTestFile: Bool
    public var isNonTestGoFile: Bool
    public var isGoModFile: Bool
    public var isJSONFile: Bool
    public var isYAMLFile: Bool
    public var isSQLFile: Bool
    public var isDockerfile: Bool
    public var isDockerComposeFile: Bool
    public var isKubernetesManifest: Bool
    public var isMarkdownFile: Bool
    public var isHTTPFile: Bool
    public var isEnvFile: Bool
    public var isProtoFile: Bool
    public var isMakefile: Bool
    public var canFormatDocument: Bool
    public var canSave: Bool
    public var isCodeMode: Bool
    public var isDiffMode: Bool
    public var canStageActiveFile: Bool
    public var canUnstageActiveFile: Bool
    public var isActiveFileConflicted: Bool
    public var hasActiveFileGitChanges: Bool
    public var hasDataSources: Bool
    public var isAttachedConsole: Bool
    public var canStopDatabaseStatement: Bool
    public var isAttachedDataSourceConnected: Bool

    public init(
        workspacePath: String = "",
        filePath: String = "",
        canSave: Bool = false,
        isCodeMode: Bool = true,
        isDiffMode: Bool = false,
        canStageActiveFile: Bool = false,
        canUnstageActiveFile: Bool = false,
        isActiveFileConflicted: Bool = false,
        hasActiveFileGitChanges: Bool = false,
        hasDataSources: Bool = false,
        isAttachedConsole: Bool = false,
        canStopDatabaseStatement: Bool = false,
        isAttachedDataSourceConnected: Bool = false,
        isKubernetesManifest: Bool = false
    ) {
        let hasWs = !workspacePath.isEmpty
        let hasFile = !filePath.isEmpty
        let goFile = hasFile && filePath.hasSuffix(".go")
        let goTest = goFile && filePath.hasSuffix("_test.go")
        let nonTestGo = goFile && !goTest
        let goMod = hasFile && (filePath as NSString).lastPathComponent == "go.mod"
        let json = hasFile && Self.isJSONFile(filePath)
        let yaml = hasFile && Self.isYAMLFile(filePath)
        let sql = hasFile && Self.isSQLFile(filePath)
        let dockerfile = hasFile && Self.isDockerfile(filePath)
        let compose = hasFile && Self.isDockerComposeFile(filePath)
        let markdown = hasFile && Self.isMarkdownFile(filePath)
        let http = hasFile && Self.isHTTPFile(filePath)
        let env = hasFile && Self.isEnvFile(filePath)
        let proto = hasFile && Self.isProtoFile(filePath)
        let makefile = hasFile && Self.isMakefile(filePath)

        self.hasWorkspace = hasWs
        self.hasActiveFile = hasFile
        self.isGoFile = goFile
        self.isGoTestFile = goTest
        self.isNonTestGoFile = nonTestGo
        self.isGoModFile = goMod
        self.isJSONFile = json
        self.isYAMLFile = yaml
        self.isSQLFile = sql
        self.isDockerfile = dockerfile
        self.isDockerComposeFile = compose
        self.isKubernetesManifest = yaml && !compose && isKubernetesManifest
        self.isMarkdownFile = markdown
        self.isHTTPFile = http
        self.isEnvFile = env
        self.isProtoFile = proto
        self.isMakefile = makefile
        self.canFormatDocument = hasFile && (goFile || json || yaml || makefile || env)
        self.canSave = canSave
        self.isCodeMode = isCodeMode
        self.isDiffMode = isDiffMode
        self.canStageActiveFile = canStageActiveFile
        self.canUnstageActiveFile = canUnstageActiveFile
        self.isActiveFileConflicted = isActiveFileConflicted
        self.hasActiveFileGitChanges = hasActiveFileGitChanges
        self.hasDataSources = hasWs && hasDataSources
        self.isAttachedConsole = sql && hasDataSources && isAttachedConsole
        self.canStopDatabaseStatement = canStopDatabaseStatement
        self.isAttachedDataSourceConnected = self.isAttachedConsole && isAttachedDataSourceConnected
    }

    public static func isJSONFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "json" || ext == "jsonc"
    }

    public static func isYAMLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    public static func isEnvFile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if filename == ".env" || filename.hasPrefix(".env.") {
            return true
        }
        return ["env", "local", "beta", "properties"].contains(ext)
    }

    public static func isMakefile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        return filename == "makefile" || filename == "gnumakefile" || filename.hasPrefix("makefile.") || ext == "mk"
    }

    public static func isDockerfile(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        return filename == "dockerfile" || filename.hasPrefix("dockerfile.") || ext == "dockerfile"
    }

    public static func isDockerComposeFile(_ path: String) -> Bool {
        guard isYAMLFile(path) else { return false }
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename.contains("docker-compose") || filename.contains("compose")
    }

    public static func isSQLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "sql" || ext == "cql"
    }

    public static func isProtoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "proto"
    }

    public static func isMarkdownFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    public static func isHTTPFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "http" || ext == "rest"
    }
}
