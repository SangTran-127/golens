import Foundation
import GoLensFoundation
import SwiftUI

struct SignatureHelpData: Equatable {
    struct Signature: Equatable {
        let label: String
        let documentation: String?
        let parameters: [Parameter]
        
        struct Parameter: Equatable {
            let label: String
            let documentation: String?
            let labelRange: Range<Int>?

            init(label: String, documentation: String?, labelRange: Range<Int>? = nil) {
                self.label = label
                self.documentation = documentation
                self.labelRange = labelRange
            }
        }
    }
    let signatures: [Signature]
    let activeSignature: Int
    let activeParameter: Int
}

struct FlatDiagnosticItem: Identifiable, Equatable {
    var id: UUID { diag.id }
    let path: String
    let diag: DiagnosticData
}

struct DiagnosticData: Codable, Identifiable, Equatable {
    var id = UUID()
    let line: Int
    let col: Int
    let endLine: Int
    let endCol: Int
    let severity: Int
    let message: String
    var source: String? = nil
    var code: String? = nil

    enum CodingKeys: String, CodingKey {
        case line, col, endLine, endCol, severity, message, source, code
    }

    var sourceLabel: String? {
        guard let source, !source.isEmpty else { return nil }
        guard let code, !code.isEmpty else { return source }
        return "\(code) (\(source))"
    }

    static func == (lhs: DiagnosticData, rhs: DiagnosticData) -> Bool {
        lhs.line == rhs.line &&
        lhs.col == rhs.col &&
        lhs.endLine == rhs.endLine &&
        lhs.endCol == rhs.endCol &&
        lhs.severity == rhs.severity &&
        lhs.message == rhs.message &&
        lhs.source == rhs.source &&
        lhs.code == rhs.code
    }
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let fullPath: String
    let isDirectory: Bool
    var children: [FileItem]?

    init(name: String, fullPath: String, isDirectory: Bool, children: [FileItem]? = nil) {
        self.id = fullPath
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.children = children
    }
}

struct SearchMatch: Identifiable, Hashable {
    let id = UUID()
    let lineNumber: Int
    let lineContent: String
    let range: NSRange
}

struct FileSearchMatches: Identifiable, Hashable {
    var id: String { filePath }
    let filePath: String
    let relativePath: String
    let matches: [SearchMatch]
}

enum GitLineDiffType: String, Codable {
    case added
    case modified
    case deleted
}

struct GitChangedFile: Identifiable, Hashable {
    var id: String { (isStaged ? "staged:" : "unstaged:") + (repoPath.isEmpty ? relativePath : repoPath) }
    let relativePath: String
    let absolutePath: String
    let status: String
    var isStaged: Bool
    var originalPath: String? = nil
    var repoPath: String = ""
    var originalRepoPath: String? = nil
}

struct TerminalSession: Identifiable, Hashable {
    let id: String
    var title: String
    var exitCode: Int32? = nil
    var cwd: String? = nil
}

private let terminalOSCSequence = try! NSRegularExpression(pattern: "\u{001b}].*?(\u{0007}|\\\\)", options: [.dotMatchesLineSeparators])
private let terminalControlSequence = try! NSRegularExpression(pattern: "\u{001b}\\[[\\??0-9;]*[a-zA-Z=]")

func sanitizeTerminalStream(_ input: String) -> String {
    guard input.utf8.contains(0x1b) else { return input }
    var output = input
    for expression in [terminalOSCSequence, terminalControlSequence] {
        output = expression.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
    }
    return output
}

struct FoldableRange: Hashable, Codable {
    let startLine: Int
    let endLine: Int
}

func findFoldableRanges(in text: NSString, path: String = "") -> [FoldableRange] {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "yml" || ext == "yaml" {
        return findYAMLIndentationFoldableRanges(in: text)
    }
    if ext == "md" || ext == "markdown" {
        return findMarkdownFoldableRanges(in: text)
    }
    let foldBrackets = (ext == "json" || ext == "jsonc")
    var ranges: [FoldableRange] = []
    var braceStack: [Int] = []
    var bracketStack: [Int] = []
    var line = 0
    var inBlockComment = false
    var inLineComment = false
    var quote: unichar = 0
    var escaped = false
    var prev: unichar = 0
    let length = text.length
    var buffer = [unichar](repeating: 0, count: 4096)
    var loc = 0
    while loc < length {
        let n = min(buffer.count, length - loc)
        text.getCharacters(&buffer, range: NSRange(location: loc, length: n))
        for i in 0..<n {
            let c = buffer[i]
            defer { prev = c }
            if c == 0x0A {
                line += 1
                inLineComment = false
                if quote != 0x60 { quote = 0 }
                escaped = false
                continue
            }
            if inLineComment { continue }
            if inBlockComment {
                if prev == 0x2A && c == 0x2F { inBlockComment = false; prev = 0 }
                continue
            }
            if quote != 0 {
                if escaped { escaped = false } else if c == 0x5C && quote != 0x60 { escaped = true } else if c == quote { quote = 0 }
                continue
            }
            switch c {
            case 0x2F where prev == 0x2F: inLineComment = true
            case 0x2A where prev == 0x2F: inBlockComment = true; continue
            case 0x22, 0x27, 0x60: quote = c
            case 0x7B: braceStack.append(line)
            case 0x7D:
                if let start = braceStack.popLast(), line - start >= 1 {
                    ranges.append(FoldableRange(startLine: start + 1, endLine: line + 1))
                }
            case 0x5B where foldBrackets:
                bracketStack.append(line)
            case 0x5D where foldBrackets:
                if let start = bracketStack.popLast(), line - start >= 1 {
                    ranges.append(FoldableRange(startLine: start + 1, endLine: line + 1))
                }
            default: break
            }
        }
        loc += n
    }
    return ranges
}

private func findYAMLIndentationFoldableRanges(in text: NSString) -> [FoldableRange] {
    let lines = (text as String).components(separatedBy: "\n")
    guard lines.count > 1 else { return [] }
    struct LineMeta {
        let indent: Int
        let isBlank: Bool
        let isComment: Bool
        let isDocSeparator: Bool
    }
    var meta: [LineMeta] = []
    meta.reserveCapacity(lines.count)
    for raw in lines {
        var indent = 0
        var firstNonSpace: Character? = nil
        for ch in raw {
            if ch == " " {
                indent += 1
            } else if ch == "\t" {
                indent += 2
            } else if ch == "\r" {
                continue
            } else {
                firstNonSpace = ch
                break
            }
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBlank = firstNonSpace == nil
        let isComment = firstNonSpace == "#"
        let isDocSep = indent == 0 && (trimmed == "---" || trimmed == "...")
        meta.append(LineMeta(indent: indent, isBlank: isBlank, isComment: isComment, isDocSeparator: isDocSep))
    }

    var ranges: [FoldableRange] = []
    for i in 0..<meta.count {
        let m = meta[i]
        if m.isBlank || m.isComment || m.isDocSeparator { continue }
        var nextIdx: Int? = nil
        for j in (i + 1)..<meta.count {
            if meta[j].isDocSeparator { break }
            if !meta[j].isBlank && !meta[j].isComment {
                nextIdx = j
                break
            }
        }
        guard let firstChild = nextIdx, meta[firstChild].indent > m.indent else { continue }
        var lastNonBlank = firstChild
        for j in (firstChild + 1)..<meta.count {
            if meta[j].isDocSeparator { break }
            if !meta[j].isBlank && !meta[j].isComment && meta[j].indent <= m.indent {
                break
            }
            if !meta[j].isBlank {
                lastNonBlank = j
            }
        }
        if lastNonBlank > i {
            ranges.append(FoldableRange(startLine: i + 1, endLine: lastNonBlank + 1))
        }
    }
    return ranges
}

private func findMarkdownFoldableRanges(in text: NSString) -> [FoldableRange] {
    let lines = (text as String).components(separatedBy: "\n")
    guard lines.count > 1 else { return [] }
    var ranges: [FoldableRange] = []
    var headings: [(line1: Int, level: Int)] = []
    var inFence = false
    var fencePrefix = ""
    var fenceStartLine1 = 0

    for (idx, raw) in lines.enumerated() {
        let line1 = idx + 1
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            let marker = trimmed.hasPrefix("~~~") ? "~~~" : "```"
            if !inFence {
                inFence = true
                fencePrefix = marker
                fenceStartLine1 = line1
            } else if trimmed.hasPrefix(fencePrefix) {
                inFence = false
                if line1 > fenceStartLine1 {
                    ranges.append(FoldableRange(startLine: fenceStartLine1, endLine: line1))
                }
            }
            continue
        }
        if inFence { continue }
        if trimmed.hasPrefix("#") {
            var hashes = 0
            for ch in trimmed {
                if ch == "#" { hashes += 1 } else { break }
            }
            if hashes >= 1 && hashes <= 6 {
                let afterIdx = trimmed.index(trimmed.startIndex, offsetBy: hashes)
                if afterIdx == trimmed.endIndex || trimmed[afterIdx] == " " || trimmed[afterIdx] == "\t" {
                    headings.append((line1: line1, level: hashes))
                }
            }
        }
    }

    for (hIdx, heading) in headings.enumerated() {
        var sectionMaxLine1 = lines.count
        for nextIdx in (hIdx + 1)..<headings.count {
            if headings[nextIdx].level <= heading.level {
                sectionMaxLine1 = headings[nextIdx].line1 - 1
                break
            }
        }
        var endLine1 = heading.line1
        if sectionMaxLine1 > heading.line1 {
            for ln in stride(from: sectionMaxLine1, through: heading.line1 + 1, by: -1) {
                if !lines[ln - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endLine1 = ln
                    break
                }
            }
        }
        if endLine1 > heading.line1 {
            ranges.append(FoldableRange(startLine: heading.line1, endLine: endLine1))
        }
    }

    ranges.sort { $0.startLine < $1.startLine }
    return ranges
}

extension DocumentSession {
    func charRange(forFoldableRange range: FoldableRange) -> NSRange? {
        guard let startLine = lineRange(range.startLine - 1), let endStart = lines.start(ofLine: range.endLine - 1) else { return nil }
        let text = storage.string as NSString
        let ext = (path as NSString).pathExtension.lowercased()
        if ext != "yml" && ext != "yaml" && ext != "md" && ext != "markdown" {
            let brace = text.range(of: "{", options: .backwards, range: startLine)
            let bracket = (ext == "json" || ext == "jsonc") ? text.range(of: "[", options: .backwards, range: startLine) : NSRange(location: NSNotFound, length: 0)
            let openLoc: Int
            if brace.location != NSNotFound && bracket.location != NSNotFound {
                openLoc = max(brace.location, bracket.location)
            } else if brace.location != NSNotFound {
                openLoc = brace.location
            } else {
                openLoc = bracket.location
            }
            if openLoc != NSNotFound {
                let foldStart = openLoc + 1
                let foldLength = endStart - foldStart
                return foldLength > 0 ? NSRange(location: foldStart, length: foldLength) : nil
            }
        }
        let foldStart = NSMaxRange(startLine)
        let foldEnd = lines.contentEnd(ofLine: range.endLine - 1, length: text.length)
        let foldLength = foldEnd - foldStart
        return foldLength > 0 ? NSRange(location: foldStart, length: foldLength) : nil
    }
}

struct CodeLensInfo {
    let usages: Int?
    let author: String?
    var implementations: [LSPLocation] = []
    var implementsDirection: ImplementationDirection = .none
}

enum ImplementationDirection {
    case none
    case implementedBy
    case implements
}

enum TestStatus: String, Codable, Equatable {
    case none, running, passed, failed, skipped
}

struct GoTestRow: Codable, Hashable, Identifiable {
    let name: String
    let id: String
    let line: Int
    var endLine: Int? = nil
    var file: String? = nil
}

struct GoTestFunc: Codable, Hashable, Identifiable {
    var id: String { "\(file):\(name)" }
    let name: String
    let file: String
    let line: Int
    var endLine: Int? = nil
    let package: String
    let rows: [GoTestRow]

    enum CodingKeys: String, CodingKey {
        case name, file, line, endLine, package, rows
    }

    init(name: String, file: String, line: Int, endLine: Int? = nil, package: String, rows: [GoTestRow] = []) {
        self.name = name
        self.file = file
        self.line = line
        self.endLine = endLine
        self.package = package
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(String.self, forKey: .file)
        line = try c.decode(Int.self, forKey: .line)
        endLine = try c.decodeIfPresent(Int.self, forKey: .endLine)
        package = try c.decode(String.self, forKey: .package)
        rows = try c.decodeIfPresent([GoTestRow].self, forKey: .rows) ?? []
    }
}

struct UntestedGoFunction: Decodable, Equatable {
    let testName: String
    let funcName: String
    let receiver: String?
    let signature: String
    let file: String
    let line: Int
}

struct GoTestSuite: Codable, Hashable, Identifiable {
    var id: String { dir }
    let package: String
    let dir: String
    let importPath: String
    var tests: [GoTestFunc]
}

struct FileTestsInfo: Decodable {
    let importPath: String
    let tests: [GoTestFunc]
}

struct FileCoveragePayload: Decodable {
    let file: String
    let coveredLines: [Int]
    let uncoveredLines: [Int]
}

struct ProfileEntry: Codable, Hashable, Identifiable {
    var id: String { "\(function):\(file):\(line)" }
    let function: String
    let file: String
    let line: Int
    let flat: Int64
    let flatPercent: Double
    let cum: Int64
    let cumPercent: Double
    let formattedFlat: String
    let formattedCum: String
    var children: [String]? = nil
    var callers: [String]? = nil
    var count: Int64? = nil
}

struct EscapeItemDTO: Codable, Hashable {
    let file: String
    let line: Int
    let col: Int
    let kind: String
    let category: String?
    let subject: String
    let message: String
    let summary: String
    let hint: String?
}

struct EscapeAnalysisResultDTO: Codable {
    let items: [EscapeItemDTO]?
    let error: String?
}

struct CompilerDecisionItem: Codable, Hashable, Identifiable {
    var id: String { "\(file):\(line):\(col):\(summary)" }
    let file: String
    let line: Int
    let col: Int
    let kind: String
    let category: String?
    let subject: String
    let message: String
    let summary: String
    let hint: String?
}

struct DisasmInstruction: Codable, Hashable, Identifiable {
    var id: String { "\(address):\(line):\(mnemonic):\(operands)" }
    let address: String
    let mnemonic: String
    let operands: String
    let source: String
    let line: Int
}

struct DisasmResult: Codable {
    let function: String
    let targetArch: String
    let instructions: [DisasmInstruction]
    let error: String?
}

struct FuncParamSpec: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var origIndex: Int
    var name: String
    var type: String
    var defaultValue: String = ""

    enum CodingKeys: String, CodingKey {
        case origIndex, name, type, defaultValue
    }

    init(origIndex: Int, name: String, type: String, defaultValue: String = "") {
        self.origIndex = origIndex
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origIndex = try c.decodeIfPresent(Int.self, forKey: .origIndex) ?? -1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decode(String.self, forKey: .type)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
    }
}

struct FuncSignatureSpec: Codable, Identifiable {
    var id: String { "\(path):\(nameLine):\(origName)" }
    var path: String
    var name: String
    var origName: String
    var receiver: String
    var nameLine: Int
    var nameCol: Int
    var params: [FuncParamSpec]
    var results: [FuncParamSpec]
}

struct TestDiffLine: Codable, Hashable, Identifiable {
    var id: String { "\(lineNum):\(type):\(text)" }
    let type: String
    let text: String
    let lineNum: Int

    var foundationItem: TestDiffLineItem {
        TestDiffLineItem(id: id, type: type, text: text, lineNum: lineNum)
    }
}

struct TestFailureAnnotation: Codable, Hashable, Identifiable {
    var id: String { "\(file):\(line):\(testName)" }
    let file: String
    let line: Int
    let testName: String
    let message: String
    let got: String?
    let want: String?
    let diffLines: [TestDiffLine]?
    var diffTruncated: Bool? = nil
    var diffTotalLines: Int? = nil
}

struct TestResultEvent: Decodable {
    let run: Int64
    let kind: String
    let package: String?
    let test: String?
    let status: String?
    let elapsed: Double?
    let passed: Int?
    let failed: Int?
    let skipped: Int?
    let packageCoverage: [String: Double]?
    let filesCoverage: [FileCoveragePayload]?
    let profileFiles: [String: [String]]?
    let cpuProfile: [ProfileEntry]?
    let memProfile: [ProfileEntry]?
    let blockProfile: [ProfileEntry]?
    let mutexProfile: [ProfileEntry]?
    let benchMetric: String?
    let failures: [TestFailureAnnotation]?
}

enum HierarchyMode: String, Codable, CaseIterable {
    case call
    case type
}

enum HierarchyDirection: String, Codable, CaseIterable {
    case incoming
    case outgoing
}

struct HierarchyItem: Codable, Hashable, Identifiable {
    var id: String { "\(uri):\(selectionRange.start.line):\(selectionRange.start.character):\(name)" }
    let name: String
    let detail: String?
    let kind: Int
    let uri: String
    let range: LSPRange
    let selectionRange: LSPRange
    let rawJSON: String

    var filePath: String {
        if let url = URL(string: uri), url.isFileURL {
            return url.path
        }
        return uri.replacingOccurrences(of: "file://", with: "")
    }
}

struct TestTarget: Equatable {
    let dir: String
    let importPath: String
    let test: String
    let row: String?

    var title: String { row.map { "\(test)/\($0)" } ?? test }
}

public enum TargetArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64 = "arm64"
    case amd64 = "amd64"

    public var title: String {
        switch self {
        case .arm64: return "Linux (arm64 native)"
        case .amd64: return "Linux (amd64 Rosetta 2)"
        }
    }

    public var shortTitle: String { rawValue }

    public var systemImage: String {
        switch self {
        case .arm64: return "cpu"
        case .amd64: return "cpu.fill"
        }
    }
}

struct RunTarget: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case local, compose, ssh
    }

    static let defaultSSHPort = 22
    static let defaultDebugPort = 2345

    var kind: Kind = .local
    var composeFile: String = ""
    var service: String = ""
    var host: String = ""
    var port: Int = RunTarget.defaultSSHPort
    var workDir: String = ""
    var debugPort: Int = RunTarget.defaultDebugPort

    static let local = RunTarget()

    enum CodingKeys: String, CodingKey {
        case kind, composeFile, service, host, port, workDir, debugPort
    }

    init(kind: Kind = .local, composeFile: String = "", service: String = "", host: String = "", port: Int = RunTarget.defaultSSHPort, workDir: String = "", debugPort: Int = RunTarget.defaultDebugPort) {
        self.kind = kind
        self.composeFile = composeFile
        self.service = service
        self.host = host
        self.port = port
        self.workDir = workDir
        self.debugPort = debugPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .local
        composeFile = (try? c.decodeIfPresent(String.self, forKey: .composeFile)) ?? ""
        service = (try? c.decodeIfPresent(String.self, forKey: .service)) ?? ""
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? RunTarget.defaultSSHPort
        workDir = (try? c.decodeIfPresent(String.self, forKey: .workDir)) ?? ""
        debugPort = (try? c.decodeIfPresent(Int.self, forKey: .debugPort)) ?? RunTarget.defaultDebugPort
    }

    var isRemote: Bool { kind != .local }

    var title: String {
        switch kind {
        case .local: return SandboxVMManager.activeMode == .linuxVM ? "Linux VM" : "My Mac"
        case .compose: return service.isEmpty ? "Compose Service" : service
        case .ssh: return host.isEmpty ? "SSH Host" : (port == RunTarget.defaultSSHPort ? host : "\(host):\(port)")
        }
    }

    var kindTitle: String {
        switch kind {
        case .local: return SandboxVMManager.activeMode == .linuxVM ? "Linux Micro-VM (This Mac)" : "My Mac"
        case .compose: return "Docker Compose"
        case .ssh: return "SSH"
        }
    }

    var symbol: String {
        switch kind {
        case .local: return SandboxVMManager.activeMode == .linuxVM ? "cpu" : "desktopcomputer"
        case .compose: return "square.stack.3d.up"
        case .ssh: return "server.rack"
        }
    }

    var jsonObject: [String: Any] {
        ["kind": kind.rawValue, "composeFile": composeFile, "service": service, "host": host, "port": port, "workDir": workDir, "debugPort": debugPort]
    }

    var jsonString: String {
        (try? JSONSerialization.data(withJSONObject: jsonObject)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

enum MemoryLimit: String, Codable, CaseIterable, Identifiable {
    case unlimited = "unlimited"
    case mb128 = "128MB"
    case mb256 = "256MB"
    case mb512 = "512MB"
    case gb1 = "1GB"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unlimited: return "Unlimited"
        case .mb128: return "128 MB"
        case .mb256: return "256 MB"
        case .mb512: return "512 MB"
        case .gb1: return "1 GB"
        }
    }
    var bytes: UInt64? {
        switch self {
        case .unlimited: return nil
        case .mb128: return 128 * 1024 * 1024
        case .mb256: return 256 * 1024 * 1024
        case .mb512: return 512 * 1024 * 1024
        case .gb1: return 1024 * 1024 * 1024
        }
    }
}

enum CPUQuota: String, Codable, CaseIterable, Identifiable {
    case unlimited = "unlimited"
    case q025 = "0.25"
    case q050 = "0.5"
    case q100 = "1.0"
    case q200 = "2.0"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unlimited: return "Unlimited"
        case .q025: return "0.25 vCPU"
        case .q050: return "0.5 vCPU"
        case .q100: return "1.0 vCPU"
        case .q200: return "2.0 vCPU"
        }
    }
    var quotaAndPeriod: (quotaUS: UInt32, periodUS: UInt32)? {
        let period: UInt32 = 100_000
        switch self {
        case .unlimited: return nil
        case .q025: return (25_000, period)
        case .q050: return (50_000, period)
        case .q100: return (100_000, period)
        case .q200: return (200_000, period)
        }
    }
}

struct RunConfiguration: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case go, docker
    }

    var id: UUID = UUID()
    var name: String
    var envVars: [String: String]
    var buildFlags: String
    var args: String
    var workingDirectory: String
    var envFilePath: String = ""
    var kind: Kind = .go
    var dockerfile: String = "Dockerfile"
    var targetStage: String = ""
    var imageTag: String = ""
    var ports: String = ""
    var dockerRunArgs: String = ""
    var target: RunTarget = .local
    var architecture: TargetArchitecture = .arm64
    var memoryLimit: MemoryLimit = .unlimited
    var cpuQuota: CPUQuota = .unlimited

    enum CodingKeys: String, CodingKey {
        case id, name, envVars, buildFlags, args, workingDirectory, envFilePath
        case kind, dockerfile, targetStage, imageTag, ports, dockerRunArgs, target, architecture
        case memoryLimit, cpuQuota
    }

    var runTarget: RunTarget { kind == .go ? target : .local }

    init(
        id: UUID = UUID(),
        name: String,
        envVars: [String: String],
        buildFlags: String,
        args: String,
        workingDirectory: String,
        envFilePath: String = "",
        kind: Kind = .go,
        dockerfile: String = "Dockerfile",
        targetStage: String = "",
        imageTag: String = "",
        ports: String = "",
        dockerRunArgs: String = "",
        target: RunTarget = .local,
        architecture: TargetArchitecture = .arm64,
        memoryLimit: MemoryLimit = .unlimited,
        cpuQuota: CPUQuota = .unlimited
    ) {
        self.id = id
        self.name = name
        self.envVars = envVars
        self.buildFlags = buildFlags
        self.args = args
        self.workingDirectory = workingDirectory
        self.envFilePath = envFilePath
        self.kind = kind
        self.dockerfile = dockerfile
        self.targetStage = targetStage
        self.imageTag = imageTag
        self.ports = ports
        self.dockerRunArgs = dockerRunArgs
        self.target = target
        self.architecture = architecture
        self.memoryLimit = memoryLimit
        self.cpuQuota = cpuQuota
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        buildFlags = try c.decodeIfPresent(String.self, forKey: .buildFlags) ?? ""
        args = try c.decodeIfPresent(String.self, forKey: .args) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "."
        envFilePath = try c.decodeIfPresent(String.self, forKey: .envFilePath) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .go
        dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile) ?? "Dockerfile"
        targetStage = try c.decodeIfPresent(String.self, forKey: .targetStage) ?? ""
        imageTag = try c.decodeIfPresent(String.self, forKey: .imageTag) ?? ""
        ports = try c.decodeIfPresent(String.self, forKey: .ports) ?? ""
        dockerRunArgs = try c.decodeIfPresent(String.self, forKey: .dockerRunArgs) ?? ""
        target = (try? c.decodeIfPresent(RunTarget.self, forKey: .target)) ?? .local
        architecture = (try? c.decodeIfPresent(TargetArchitecture.self, forKey: .architecture)) ?? .arm64
        memoryLimit = (try? c.decodeIfPresent(MemoryLimit.self, forKey: .memoryLimit)) ?? .unlimited
        cpuQuota = (try? c.decodeIfPresent(CPUQuota.self, forKey: .cpuQuota)) ?? .unlimited
    }
}

struct RunSession: Identifiable {
    let id: Int64
    let key: String
    var title: String
    var dir: String
    var isRunning: Bool
    var output: [WorkspaceState.LogMessage] = []
    var outputBytes: Int = 0
    var failure: RunFailure? = nil
}

struct OOMFailureInfo: Equatable, Identifiable {
    var id: UUID = UUID()
    var sessionID: Int64
    var targetName: String
    var memoryLimit: String
    var detail: String
}

extension FDEntry.FDKind {
    var symbol: String {
        switch self {
        case .file: return "doc"
        case .socket: return "network"
        case .pipe: return "arrow.left.arrow.right"
        case .character: return "terminal"
        case .anonInode: return "cpu"
        case .other: return "ellipsis"
        }
    }

    var badgeTitle: String {
        switch self {
        case .file: return "file"
        case .socket: return "socket"
        case .pipe: return "pipe"
        case .character: return "dev"
        case .anonInode: return "epoll/event"
        case .other: return "other"
        }
    }
}

extension TCPSocketTelemetry.TCPState {
    var color: NSColor {
        switch self {
        case .established, .listen:
            return .systemGreen
        case .synSent, .synRecv, .timeWait, .closeWait, .finWait1, .finWait2, .closing, .lastAck:
            return .systemOrange
        case .close, .unknown:
            return .secondaryLabelColor
        }
    }
}

@Observable
private final class GitExtendedStateStore {
    static let shared = GitExtendedStateStore()
    var unmergedStatusesByState: [ObjectIdentifier: [String: String]] = [:]
    var commitDiffReturnHistoryByState: [ObjectIdentifier: GitHistoryTarget] = [:]
}

extension GitState {
    var unmergedStatuses: [String: String] {
        get { GitExtendedStateStore.shared.unmergedStatusesByState[ObjectIdentifier(self)] ?? [:] }
        set {
            let id = ObjectIdentifier(self)
            if newValue.isEmpty {
                GitExtendedStateStore.shared.unmergedStatusesByState.removeValue(forKey: id)
            } else {
                GitExtendedStateStore.shared.unmergedStatusesByState[id] = newValue
            }
        }
    }

    var commitDiffReturnHistory: GitHistoryTarget? {
        get { GitExtendedStateStore.shared.commitDiffReturnHistoryByState[ObjectIdentifier(self)] }
        set {
            let id = ObjectIdentifier(self)
            if let newValue {
                GitExtendedStateStore.shared.commitDiffReturnHistoryByState[id] = newValue
            } else {
                GitExtendedStateStore.shared.commitDiffReturnHistoryByState.removeValue(forKey: id)
            }
        }
    }
}

