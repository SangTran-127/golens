import Foundation

public enum PathVerdict: Sendable, Equatable {
    case ok
    case escapesWorkspace
    case symlinkEscape
    case denied(String)
}

public struct PatchLimits: Sendable, Equatable {
    public var maxFiles: Int
    public var maxBytes: Int

    public init(maxFiles: Int = 10, maxBytes: Int = 200 * 1024) {
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
    }
}

public struct PatchValidationContext: Sendable {
    public let limits: PatchLimits
    public let pathCheck: @Sendable (String) -> PathVerdict
    public let secretCheck: @Sendable (String) -> Bool
    public let binaryCheck: @Sendable (String) -> Bool
    public let pathExists: @Sendable (String) -> Bool

    public init(limits: PatchLimits = PatchLimits(), pathCheck: @escaping @Sendable (String) -> PathVerdict, secretCheck: @escaping @Sendable (String) -> Bool, binaryCheck: @escaping @Sendable (String) -> Bool = PatchValidationContext.containsNul, pathExists: @escaping @Sendable (String) -> Bool) {
        self.limits = limits
        self.pathCheck = pathCheck
        self.secretCheck = secretCheck
        self.binaryCheck = binaryCheck
        self.pathExists = pathExists
    }

    public static let containsNul: @Sendable (String) -> Bool = { $0.unicodeScalars.contains { $0.value == 0 } }
}

public enum PatchIssueCode: String, Sendable, Equatable {
    case emptyProposal
    case tooManyFiles
    case tooLarge
    case duplicatePath
    case unsupportedOperation
    case invalidPath
    case pathEscape
    case symlinkEscape
    case invalidRange
    case overlappingRanges
    case secretDetected
    case binaryContent
    case missingBaseHash
    case missingContent
    case missingEdits
    case createWouldOverwrite
}

public struct PatchIssue: Sendable, Equatable {
    public let path: String?
    public let code: PatchIssueCode
    public let detail: String
}

public struct PatchSecurityWarning: Sendable, Equatable, Identifiable {
    public var id: String { "\(path):\(token)" }
    public let path: String
    public let token: String
    public let reason: String

    public init(path: String, token: String, reason: String) {
        self.path = path
        self.token = token
        self.reason = reason
    }
}

public enum GoASTCapabilityScanner {
    public static let capabilityReasons: [String: String] = [
        "os/exec": "Spawns external OS processes",
        "syscall": "Invokes low-level OS syscalls",
        "unsafe": "Bypasses Go type and memory safety",
        "net/http": "Opens HTTP server listeners or outbound HTTP connections",
        "net": "Opens low-level network sockets",
        "// #cgo": "Invokes cgo compiler or linker directives",
        "//go:linkname": "Links unexported runtime symbols"
    ]

    public static func scan(_ source: String) -> Set<String> {
        var capabilities = Set<String>()
        let scalars = Array(source.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let ch = scalars[i]

            // Check for line comment //
            if ch == "/" && i + 1 < n && scalars[i + 1] == "/" {
                var commentText = ""
                i += 2
                while i < n && scalars[i] != "\n" {
                    commentText.unicodeScalars.append(scalars[i])
                    i += 1
                }
                if commentText.contains("#cgo") {
                    capabilities.insert("// #cgo")
                }
                if commentText.contains("go:linkname") {
                    capabilities.insert("//go:linkname")
                }
                continue
            }

            // Check for block comment /*
            if ch == "/" && i + 1 < n && scalars[i + 1] == "*" {
                var commentText = ""
                i += 2
                while i + 1 < n && !(scalars[i] == "*" && scalars[i + 1] == "/") {
                    commentText.unicodeScalars.append(scalars[i])
                    i += 1
                }
                if i + 1 < n { i += 2 }
                if commentText.contains("#cgo") {
                    capabilities.insert("// #cgo")
                }
                continue
            }

            // Check for string literal outside import
            if ch == "\"" {
                i += 1
                while i < n {
                    if scalars[i] == "\\" {
                        i += 2
                        continue
                    }
                    if scalars[i] == "\"" {
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }

            if ch == "`" {
                i += 1
                while i < n && scalars[i] != "`" {
                    i += 1
                }
                if i < n { i += 1 }
                continue
            }

            if ch == "'" {
                i += 1
                while i < n {
                    if scalars[i] == "\\" {
                        i += 2
                        continue
                    }
                    if scalars[i] == "'" {
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }

            // Check for keyword 'import'
            if ch == "i" && isWordStart(scalars, at: i) && matchesKeyword(scalars, at: i, keyword: "import") {
                i += 6
                while i < n && (scalars[i] == " " || scalars[i] == "\t" || scalars[i] == "\r" || scalars[i] == "\n") {
                    i += 1
                }
                if i < n && scalars[i] == "(" {
                    i += 1
                    while i < n && scalars[i] != ")" {
                        let inner = scalars[i]
                        if inner == "/" && i + 1 < n && scalars[i + 1] == "/" {
                            var comment = ""
                            i += 2
                            while i < n && scalars[i] != "\n" {
                                comment.unicodeScalars.append(scalars[i])
                                i += 1
                            }
                            if comment.contains("#cgo") { capabilities.insert("// #cgo") }
                            continue
                        }
                        if inner == "\"" || inner == "`" {
                            let quote = inner
                            i += 1
                            var importPath = ""
                            while i < n && scalars[i] != quote {
                                if quote == "\"" && scalars[i] == "\\" && i + 1 < n {
                                    i += 1
                                }
                                importPath.unicodeScalars.append(scalars[i])
                                i += 1
                            }
                            if i < n { i += 1 }
                            checkImport(importPath, into: &capabilities)
                            continue
                        }
                        i += 1
                    }
                    if i < n { i += 1 }
                } else {
                    while i < n && scalars[i] != "\n" {
                        let inner = scalars[i]
                        if inner == "\"" || inner == "`" {
                            let quote = inner
                            i += 1
                            var importPath = ""
                            while i < n && scalars[i] != quote {
                                if quote == "\"" && scalars[i] == "\\" && i + 1 < n {
                                    i += 1
                                }
                                importPath.unicodeScalars.append(scalars[i])
                                i += 1
                            }
                            if i < n { i += 1 }
                            checkImport(importPath, into: &capabilities)
                            break
                        }
                        i += 1
                    }
                }
                continue
            }

            i += 1
        }

        return capabilities
    }

    private static func isWordStart(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        if index == 0 { return true }
        let prev = scalars[index - 1]
        return !CharacterSet.alphanumerics.contains(prev) && prev != "_"
    }

    private static func matchesKeyword(_ scalars: [UnicodeScalar], at index: Int, keyword: String) -> Bool {
        let keyScalars = Array(keyword.unicodeScalars)
        guard index + keyScalars.count <= scalars.count else { return false }
        for j in 0..<keyScalars.count {
            if scalars[index + j] != keyScalars[j] { return false }
        }
        let afterIndex = index + keyScalars.count
        if afterIndex < scalars.count {
            let next = scalars[afterIndex]
            if CharacterSet.alphanumerics.contains(next) || next == "_" {
                return false
            }
        }
        return true
    }

    private static func checkImport(_ path: String, into capabilities: inout Set<String>) {
        if path == "C" {
            capabilities.insert("// #cgo")
        } else if path == "os/exec" {
            capabilities.insert("os/exec")
        } else if path == "syscall" {
            capabilities.insert("syscall")
        } else if path == "unsafe" {
            capabilities.insert("unsafe")
        } else if path == "net/http" || path.hasPrefix("net/http/") {
            capabilities.insert("net/http")
            capabilities.insert("net")
        } else if path == "net" || path.hasPrefix("net/") {
            capabilities.insert("net")
        }
    }
}

public enum PatchValidator {
    public static func securityWarnings(for proposal: PatchProposal, baseTexts: [String: String] = [:]) -> [PatchSecurityWarning] {
        var warnings: [PatchSecurityWarning] = []
        for operation in proposal.operations {
            let beforeText = baseTexts[operation.path] ?? ""
            let beforeCapabilities = beforeText.isEmpty ? Set<String>() : GoASTCapabilityScanner.scan(beforeText)

            let afterText: String
            switch operation.kind {
            case .create:
                afterText = operation.content ?? ""
            case .edit:
                if !beforeText.isEmpty {
                    var units = Array(beforeText.utf16)
                    let ascending = operation.edits.sorted { ($0.startUTF16, $0.endUTF16) < ($1.startUTF16, $1.endUTF16) }
                    for edit in ascending.reversed() {
                        if edit.startUTF16 <= units.count && edit.endUTF16 <= units.count {
                            units.replaceSubrange(edit.startUTF16..<edit.endUTF16, with: Array(edit.replacement.utf16))
                        }
                    }
                    afterText = String(decoding: units, as: UTF16.self)
                } else {
                    afterText = operation.edits.map(\.replacement).joined(separator: "\n")
                }
            default:
                continue
            }

            let afterCapabilities = GoASTCapabilityScanner.scan(afterText)
            let newlyIntroduced = afterCapabilities.subtracting(beforeCapabilities)

            for token in newlyIntroduced.sorted() {
                let reason = GoASTCapabilityScanner.capabilityReasons[token] ?? "High-risk capability"
                warnings.append(PatchSecurityWarning(path: operation.path, token: token, reason: reason))
            }
        }
        return warnings
    }
    public static func lexicalPathIssue(_ path: String) -> String? {
        if path.isEmpty { return "path is empty" }
        if path.hasPrefix("/") || path.hasPrefix("~") { return "path must be relative to the workspace" }
        if path.contains("\\") { return "path contains a backslash" }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "path contains control characters" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return "path has empty, dot or parent components" }
        return nil
    }

    public static func validate(_ proposal: PatchProposal, context: PatchValidationContext) -> [PatchIssue] {
        var issues: [PatchIssue] = []
        let operations = proposal.operations
        if operations.isEmpty {
            return [PatchIssue(path: nil, code: .emptyProposal, detail: "proposal has no operations")]
        }
        if operations.count > context.limits.maxFiles {
            issues.append(PatchIssue(path: nil, code: .tooManyFiles, detail: "\(operations.count) files exceeds the limit of \(context.limits.maxFiles)"))
        }
        var totalBytes = 0
        var seen = Set<String>()
        for operation in operations {
            let path = operation.path
            if !seen.insert(path).inserted {
                issues.append(PatchIssue(path: path, code: .duplicatePath, detail: "path appears more than once"))
            }
            if let problem = lexicalPathIssue(path) {
                issues.append(PatchIssue(path: path, code: .invalidPath, detail: problem))
            } else {
                switch context.pathCheck(path) {
                case .ok: break
                case .escapesWorkspace: issues.append(PatchIssue(path: path, code: .pathEscape, detail: "path escapes the workspace"))
                case .symlinkEscape: issues.append(PatchIssue(path: path, code: .symlinkEscape, detail: "path resolves through a symlink outside the workspace"))
                case .denied(let why): issues.append(PatchIssue(path: path, code: .pathEscape, detail: why))
                }
            }
            switch operation.kind {
            case .edit:
                totalBytes += validateEdit(operation, context: context, issues: &issues)
            case .create:
                totalBytes += validateCreate(operation, context: context, issues: &issues)
            case .rename, .delete, .binary, .dependencyInstall:
                issues.append(PatchIssue(path: path, code: .unsupportedOperation, detail: "\(operation.kind.rawValue) is not supported; only text edits and new files are"))
            }
        }
        if totalBytes > context.limits.maxBytes {
            issues.append(PatchIssue(path: nil, code: .tooLarge, detail: "\(totalBytes) bytes exceeds the limit of \(context.limits.maxBytes)"))
        }
        return issues
    }

    private static func validateEdit(_ operation: PatchFileOperation, context: PatchValidationContext, issues: inout [PatchIssue]) -> Int {
        let path = operation.path
        if operation.baseHash == nil || operation.baseHash?.isEmpty == true {
            issues.append(PatchIssue(path: path, code: .missingBaseHash, detail: "edit needs the base content hash"))
        }
        if operation.edits.isEmpty {
            issues.append(PatchIssue(path: path, code: .missingEdits, detail: "edit has no text edits"))
        }
        if operation.content != nil {
            issues.append(PatchIssue(path: path, code: .unsupportedOperation, detail: "edit must not carry full file content"))
        }
        var bytes = 0
        for edit in operation.edits {
            bytes += edit.replacement.utf8.count
            if edit.startUTF16 < 0 || edit.endUTF16 < edit.startUTF16 {
                issues.append(PatchIssue(path: path, code: .invalidRange, detail: "range \(edit.startUTF16)..<\(edit.endUTF16) is invalid"))
            }
            if context.binaryCheck(edit.replacement) {
                issues.append(PatchIssue(path: path, code: .binaryContent, detail: "replacement text looks binary"))
            }
            if context.secretCheck(edit.replacement) {
                issues.append(PatchIssue(path: path, code: .secretDetected, detail: "replacement text contains a secret"))
            }
        }
        let ordered = operation.edits.sorted { ($0.startUTF16, $0.endUTF16) < ($1.startUTF16, $1.endUTF16) }
        for index in ordered.indices.dropFirst() {
            let previous = ordered[index - 1]
            let current = ordered[index]
            if current.startUTF16 < previous.endUTF16 || current.startUTF16 == previous.startUTF16 {
                issues.append(PatchIssue(path: path, code: .overlappingRanges, detail: "ranges \(previous.startUTF16)..<\(previous.endUTF16) and \(current.startUTF16)..<\(current.endUTF16) overlap"))
                break
            }
        }
        return bytes
    }

    private static func validateCreate(_ operation: PatchFileOperation, context: PatchValidationContext, issues: inout [PatchIssue]) -> Int {
        let path = operation.path
        guard let content = operation.content else {
            issues.append(PatchIssue(path: path, code: .missingContent, detail: "create needs file content"))
            return 0
        }
        if !operation.edits.isEmpty || operation.baseHash != nil {
            issues.append(PatchIssue(path: path, code: .unsupportedOperation, detail: "create must not carry edits or a base hash"))
        }
        if context.binaryCheck(content) {
            issues.append(PatchIssue(path: path, code: .binaryContent, detail: "new file content looks binary"))
        }
        if context.secretCheck(content) {
            issues.append(PatchIssue(path: path, code: .secretDetected, detail: "new file content contains a secret"))
        }
        if context.pathExists(path) {
            issues.append(PatchIssue(path: path, code: .createWouldOverwrite, detail: "a file already exists at this path"))
        }
        return content.utf8.count
    }
}
