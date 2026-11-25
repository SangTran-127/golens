import Foundation

public struct GoModuleInfo: Sendable, Equatable {
    public let directory: String
    public let modulePath: String?

    public init(directory: String, modulePath: String?) {
        self.directory = directory
        self.modulePath = modulePath
    }
}

public enum GoModuleResolution: Sendable, Equatable {
    case resolved(moduleDirectory: String, scope: String)
    case ambiguous([String])
    case noModule
}

public enum GoModuleLocator {
    static let skippedDirectories: Set<String> = ["vendor", "node_modules", "testdata", "build", "dist", ".build"]

    public static func discover(root: URL, maxDepth: Int = 4, limit: Int = 64) -> [GoModuleInfo] {
        let fileManager = FileManager.default
        var found: [GoModuleInfo] = []
        var queue: [(URL, String, Int)] = [(root, "", 0)]
        while !queue.isEmpty, found.count < limit {
            let (directory, relative, depth) = queue.removeFirst()
            let goMod = directory.appendingPathComponent("go.mod")
            if fileManager.fileExists(atPath: goMod.path) {
                found.append(GoModuleInfo(directory: relative, modulePath: modulePath(in: goMod)))
            }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !skippedDirectories.contains(name), !name.hasPrefix("_") else { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                queue.append((child, relative.isEmpty ? name : relative + "/" + name, depth + 1))
            }
        }
        return found
    }

    public static func hasWorkspaceFile(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("go.work").path)
    }

    public static func resolve(scope rawScope: String, root: URL, modules providedModules: [GoModuleInfo]? = nil) -> GoModuleResolution {
        let scope = rawScope.trimmingCharacters(in: .whitespaces)
        if hasWorkspaceFile(root: root) {
            return .resolved(moduleDirectory: "", scope: scope)
        }
        let modules = providedModules ?? discover(root: root)
        if scope.hasPrefix(".") {
            var directory = scope
            var recursive = false
            if directory == "..." || directory == "./..." {
                directory = ""
                recursive = true
            } else if directory.hasSuffix("/...") {
                directory = String(directory.dropLast(4))
                recursive = true
            }
            while directory.hasPrefix("./") { directory = String(directory.dropFirst(2)) }
            if directory == "." { directory = "" }
            while directory.hasSuffix("/") { directory = String(directory.dropLast()) }

            let containing = modules
                .filter { $0.directory.isEmpty || directory == $0.directory || directory.hasPrefix($0.directory + "/") }
                .max { $0.directory.count < $1.directory.count }
            if let module = containing {
                let remainder = module.directory.isEmpty ? directory : String(directory.dropFirst(min(directory.count, module.directory.count + 1)))
                return .resolved(moduleDirectory: module.directory, scope: relativeScope(remainder, recursive: recursive))
            }
            guard recursive else { return .noModule }
            let nested = modules.filter { directory.isEmpty || $0.directory.hasPrefix(directory + "/") }
            if nested.count == 1, let only = nested.first {
                return .resolved(moduleDirectory: only.directory, scope: "./...")
            }
            if nested.count > 1 {
                return .ambiguous(nested.map(\.directory))
            }
            return .noModule
        }
        let importPath = scope.hasSuffix("/...") ? String(scope.dropLast(4)) : scope
        let owner = modules
            .filter { module in
                guard let path = module.modulePath, !path.isEmpty else { return false }
                return importPath == path || importPath.hasPrefix(path + "/")
            }
            .max { ($0.modulePath ?? "").count < ($1.modulePath ?? "").count }
        if let owner {
            return .resolved(moduleDirectory: owner.directory, scope: scope)
        }
        if modules.contains(where: { $0.directory.isEmpty }) {
            return .resolved(moduleDirectory: "", scope: scope)
        }
        return .noModule
    }

    static func relativeScope(_ remainder: String, recursive: Bool) -> String {
        if remainder.isEmpty { return recursive ? "./..." : "." }
        return "./" + remainder + (recursive ? "/..." : "")
    }

    static func modulePath(in goMod: URL) -> String? {
        guard let text = try? String(contentsOf: goMod, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("module ") {
                let value = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}
