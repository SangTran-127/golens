import Foundation
import GoLensFoundation

enum CodeLensProvider {
    static func benchmarkLenses(in text: String, path: String, workspace: WorkspaceState) -> [CodeLensItem] {
        guard path.hasSuffix(".go"), text.contains("Benchmark") else { return [] }
        let fileInfo = workspace.fileTests[path]
        let importPath = fileInfo?.importPath ?? ""
        let astBenchmarks = (fileInfo?.tests ?? [])
            .filter { $0.name.hasPrefix("Benchmark") && $0.line > 0 }
            .map { BenchmarkSignatureParser.DiscoveredBenchmark(line: $0.line, name: $0.name) }
        let isEdited = workspace.documents[path]?.isEdited == true
        let discovered = BenchmarkSignatureParser.resolve(
            astBenchmarks: astBenchmarks,
            text: text,
            isEdited: isEdited
        )
        guard !discovered.isEmpty else { return [] }
        workspace.ensureBenchmarkPreviewSeeded(discoveredNames: discovered.map(\.name))

        var items: [CodeLensItem] = []
        items.reserveCapacity(discovered.count * 3)
        for entry in discovered {
            let lineNum = entry.line
            let benchName = entry.name

            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Run Bench",
                    command: [
                        "golensCommand": "runBenchmark",
                        "path": path,
                        "name": benchName,
                        "line": lineNum
                    ]
                )
            )

            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Profile Bench",
                    command: [
                        "golensCommand": "profileBenchmark",
                        "path": path,
                        "name": benchName,
                        "line": lineNum
                    ]
                )
            )

            let compareTitles = benchmarkCompareLensTitles(
                for: benchName,
                importPath: importPath,
                workspace: workspace
            )
            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: compareTitles.full,
                    command: [
                        "golensCommand": "compareBenchmarkBaseline",
                        "compactTitle": compareTitles.compact,
                        "path": path,
                        "name": benchName,
                        "line": lineNum
                    ]
                )
            )
        }
        return items
    }

    static func benchmarkCompareLensTitle(
        for benchName: String,
        importPath: String,
        workspace: WorkspaceState
    ) -> String {
        benchmarkCompareLensTitles(for: benchName, importPath: importPath, workspace: workspace).full
    }

    static func benchmarkCompareLensTitles(
        for benchName: String,
        importPath: String,
        workspace: WorkspaceState
    ) -> (full: String, compact: String) {
        let diff = workspace.benchmarkDiffItems
            .first(where: { $0.matches(importPath: importPath, name: benchName) })?
            .asSnapshot
        let baseline = workspace.lookupBenchmarkBaseline(importPath: importPath, name: benchName)?.asMetricValues
        let currentMetric = workspace.lookupBenchmarkCurrentEntry(importPath: importPath, name: benchName)?.asMetricValues
        return (
            full: BenchmarkMetricsFormatter.compareLensTitle(
                current: currentMetric,
                baseline: baseline,
                diff: diff
            ),
            compact: BenchmarkMetricsFormatter.compactCompareLensTitle(
                current: currentMetric,
                baseline: baseline,
                diff: diff
            )
        )
    }

    static func formatNsPerOp(_ ns: Double) -> String {
        BenchmarkMetricsFormatter.formatNsPerOp(ns)
    }

    static func parseBenchmarkFuncName(in line: String) -> String? {
        BenchmarkSignatureParser.parseBenchmarkFuncName(in: line)
    }
}

struct HTTPRouteLensDTO: Decodable {
    let method: String
    let path: String
    let line: Int
    let framework: String
    let pathParams: [String]?
    let handlerName: String?
    let sampleRequestBodyJSON: String?
}

extension CodeLensProvider {
    static func httpRouteLenses(in text: String, path: String) -> [CodeLensItem] {
        guard path.hasSuffix(".go") else { return [] }
        guard text.contains("HandleFunc") || text.contains("Handle") ||
              text.contains(".Get(") || text.contains(".Post(") ||
              text.contains(".Put(") || text.contains(".Delete(") ||
              text.contains(".Patch(") || text.contains(".Options(") ||
              text.contains(".Head(") || text.contains(".GET(") ||
              text.contains(".POST(") || text.contains(".PUT(") ||
              text.contains(".DELETE(") || text.contains(".PATCH(") ||
              text.contains(".OPTIONS(") || text.contains(".HEAD(") ||
              text.contains(".Route(") || text.contains(".Group(") else {
            return []
        }
        guard let cSrc = text.cString(using: .utf8),
              let ptr = ScanGoHTTPRoutes(cSrc) else {
            return []
        }
        defer { FreeGoCString(ptr) }
        let jsonStr = String(cString: ptr)
        guard let data = jsonStr.data(using: .utf8),
              let routes = try? JSONDecoder().decode([HTTPRouteLensDTO].self, from: data) else {
            return []
        }
        return routes.map { route in
            let title = "Test Route [\(route.method) \(route.path)]"
            var cmd: [String: Any] = [
                "golensCommand": "testHTTPRoute",
                "path": path,
                "line": route.line,
                "method": route.method,
                "routePath": route.path,
                "framework": route.framework,
                "sampleBody": route.sampleRequestBodyJSON ?? ""
            ]
            if let params = route.pathParams {
                cmd["pathParams"] = params
            }
            return CodeLensItem(line: route.line, title: title, command: cmd)
        }
    }

    static let maxCodeLensPerFile = 50

    static func makefileLenses(in text: String, path: String) -> [CodeLensItem] {
        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent.lowercased()
        let ext = nsPath.pathExtension.lowercased()
        guard filename == "makefile" || filename == "gnumakefile" || ext == "mk" else {
            return []
        }

        guard let targetRegex = try? NSRegularExpression(pattern: "^([A-Za-z0-9_.-]+)\\s*:([^=]|$)") else {
            return []
        }

        var items: [CodeLensItem] = []

        SourceLineScanner.enumerateLines(in: text) { lineNum, rawLine, stop in
            if items.count >= maxCodeLensPerFile {
                stop = true
                return
            }
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = targetRegex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges > 1 else {
                return
            }
            let targetName = nsLine.substring(with: match.range(at: 1))
            if targetName.hasPrefix(".") || targetName.contains("%") || line.contains("%") {
                return
            }
            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Run make \(targetName)",
                    command: [
                        "golensCommand": "runMakeTarget",
                        "path": path,
                        "target": targetName,
                        "line": lineNum
                    ]
                )
            )
        }

        return items
    }

    static func dockerComposeLenses(in text: String, path: String) -> [CodeLensItem] {
        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent.lowercased()
        let ext = nsPath.pathExtension.lowercased()
        guard (filename.contains("docker-compose") || filename.contains("compose")) &&
              (ext == "yml" || ext == "yaml") else {
            return []
        }

        guard let servicesHeaderRegex = try? NSRegularExpression(pattern: "^services:\\s*(#.*)?$"),
              let serviceKeyRegex = try? NSRegularExpression(pattern: "^([A-Za-z0-9_.-]+)\\s*:\\s*(#.*)?$") else {
            return []
        }

        var items = [CodeLensItem(line: 1, title: "Validate", command: ["golensCommand": "dockerValidateCompose", "path": path, "line": 1])]
        var inServicesBlock = false
        var serviceIndent: Int?

        SourceLineScanner.enumerateLines(in: text) { lineNum, rawLine, stop in
            if items.count >= maxCodeLensPerFile {
                stop = true
                return
            }
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                return
            }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if servicesHeaderRegex.firstMatch(in: line, options: [], range: fullRange) != nil {
                inServicesBlock = true
                serviceIndent = nil
                items.append(
                    CodeLensItem(
                        line: lineNum,
                        title: "Compose Up All",
                        command: [
                            "golensCommand": "dockerComposeAll",
                            "path": path,
                            "action": "up",
                            "line": lineNum
                        ]
                    )
                )
                items.append(
                    CodeLensItem(
                        line: lineNum,
                        title: "Compose Down…",
                        command: [
                            "golensCommand": "dockerComposeAll",
                            "path": path,
                            "action": "down",
                            "line": lineNum
                        ]
                    )
                )
                return
            }

            guard inServicesBlock else { return }

            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inServicesBlock = false
                serviceIndent = nil
                return
            }

            if serviceIndent == nil && (indent == 2 || indent == 4) {
                serviceIndent = indent
            }

            guard let expectedIndent = serviceIndent, indent == expectedIndent else {
                return
            }

            let nsTrimmed = trimmed as NSString
            let trimmedRange = NSRange(location: 0, length: nsTrimmed.length)
            guard let match = serviceKeyRegex.firstMatch(in: trimmed, options: [], range: trimmedRange),
                  match.numberOfRanges > 1 else {
                return
            }

            let serviceName = nsTrimmed.substring(with: match.range(at: 1))
            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Up \(serviceName)",
                    command: [
                        "golensCommand": "dockerComposeService",
                        "path": path,
                        "service": serviceName,
                        "action": "up",
                        "line": lineNum
                    ]
                )
            )
            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Stop",
                    command: [
                        "golensCommand": "dockerComposeService",
                        "path": path,
                        "service": serviceName,
                        "action": "stop",
                        "line": lineNum
                    ]
                )
            )
            items.append(
                CodeLensItem(
                    line: lineNum,
                    title: "Logs",
                    command: [
                        "golensCommand": "dockerComposeService",
                        "path": path,
                        "service": serviceName,
                        "action": "logs",
                        "line": lineNum
                    ]
                )
            )
        }

        return items
    }

    static func dockerfileLenses(in text: String, path: String) -> [CodeLensItem] {
        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent.lowercased()
        let ext = nsPath.pathExtension.lowercased()
        guard filename == "dockerfile" || filename.hasPrefix("dockerfile.") || ext == "dockerfile" else {
            return []
        }

        guard let fromRegex = try? NSRegularExpression(
            pattern: "^FROM\\s+(?:--\\S+\\s+)*\\S+(?:\\s+AS\\s+([A-Za-z0-9_.-]+))?",
            options: [.caseInsensitive]
        ) else {
            return []
        }

        var stageItems: [CodeLensItem] = []
        var lastStagelessFromLine: Int?
        var firstFromLine: Int?

        SourceLineScanner.enumerateLines(in: text) { lineNum, rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { return }
            let codePart: String
            if let hashIdx = line.firstIndex(of: "#") {
                codePart = String(line[..<hashIdx])
            } else {
                codePart = line
            }
            let nsLine = codePart as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = fromRegex.firstMatch(in: codePart, options: [], range: range) else {
                return
            }
            if firstFromLine == nil {
                firstFromLine = lineNum
            }
            let stageRange = match.range(at: 1)
            if stageRange.location != NSNotFound && stageRange.length > 0 {
                let stage = nsLine.substring(with: stageRange)
                stageItems.append(
                    CodeLensItem(
                        line: lineNum,
                        title: "Build Stage (\(stage))",
                        command: [
                            "golensCommand": "dockerBuildImage",
                            "path": path,
                            "stage": stage,
                            "line": lineNum
                        ]
                    )
                )
            } else {
                lastStagelessFromLine = lineNum
            }
        }

        guard firstFromLine != nil else { return [] }
        let buildImageLine = lastStagelessFromLine ?? firstFromLine ?? 1
        var items = stageItems
        items.append(
            CodeLensItem(
                line: buildImageLine,
                title: "Build Image",
                command: [
                    "golensCommand": "dockerBuildImage",
                    "path": path,
                    "line": buildImageLine
                ]
            )
        )
        items.sort { $0.line < $1.line }
        return Array(items.prefix(maxCodeLensPerFile))
    }

    static func envFileLenses(in text: String, path: String, secretsMasked: Bool) -> [CodeLensItem] {
        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent.lowercased()
        let ext = nsPath.pathExtension.lowercased()
        guard filename == ".env" || filename.hasPrefix(".env.") || ["env", "local", "beta"].contains(ext) else {
            return []
        }

        guard let envPairRegex = try? NSRegularExpression(pattern: "^(?:export\\s+)?([A-Za-z_][A-Za-z0-9_.]*)\\s*=") else {
            return []
        }

        var firstLine: Int?
        var pairCount = 0

        SourceLineScanner.enumerateLines(in: text) { lineNum, rawLine, _ in
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && firstLine == nil {
                firstLine = lineNum
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                return
            }
            let nsTrimmed = trimmed as NSString
            let range = NSRange(location: 0, length: nsTrimmed.length)
            if envPairRegex.firstMatch(in: trimmed, options: [], range: range) != nil {
                pairCount += 1
            }
        }

        let targetLine = firstLine ?? 1
        return [
            CodeLensItem(
                line: targetLine,
                title: "Apply \(pairCount) Env Vars to Run Config",
                command: [
                    "golensCommand": "applyEnvFileToRunConfig",
                    "path": path,
                    "line": targetLine
                ]
            ),
            CodeLensItem(
                line: targetLine,
                title: secretsMasked ? "Show Secrets" : "Mask Secrets",
                command: [
                    "golensCommand": "toggleEnvSecretMask",
                    "path": path,
                    "line": targetLine
                ]
            )
        ]
    }

    static func ecosystemLenses(in text: String, path: String, secretsMasked: Bool = false) -> [CodeLensItem] {
        var items: [CodeLensItem] = []
        items.append(contentsOf: makefileLenses(in: text, path: path))
        items.append(contentsOf: dockerComposeLenses(in: text, path: path))
        items.append(contentsOf: dockerfileLenses(in: text, path: path))
        items.append(contentsOf: envFileLenses(in: text, path: path, secretsMasked: secretsMasked))
        return items
    }
}
