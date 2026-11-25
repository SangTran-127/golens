import Foundation
import AppKit

extension EcosystemDocumentTools {

    struct EnvEntryInfo: Equatable {
        let key: String
        let value: String
        let filePath: String
        let fileName: String
        let line: Int
        let isSensitive: Bool
        var displayValue: String {
            isSensitive ? "•••••••• (masked)" : value
        }
    }

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", "vendor", "node_modules", ".golens", "DerivedData"
    ]

    private static func isEnvCandidateFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") {
            return true
        }
        return lower.hasSuffix(".env")
    }

    private static func envFileSortKey(path: String, workspaceRoot: String) -> (Int, Int, String) {
        let dir = (path as NSString).deletingLastPathComponent
        let depthRank = (dir == workspaceRoot) ? 0 : 1
        let name = (path as NSString).lastPathComponent.lowercased()
        let nameRank: Int
        if name == ".env" {
            nameRank = 0
        } else if name == ".env.local" {
            nameRank = 1
        } else if name == ".env.development" || name == ".env.dev" {
            nameRank = 2
        } else if name.hasPrefix(".env.") && !name.contains("example") && !name.contains("sample") && !name.contains("template") {
            nameRank = 3
        } else if name.hasPrefix(".env.") {
            nameRank = 4
        } else {
            nameRank = 5
        }
        return (depthRank, nameRank, path)
    }

    private static let envCacheLock = NSLock()
    private static var cachedEnvWorkspacePath: String = ""
    private static var cachedEnvOpenDocHash: Int = 0
    private static var cachedEnvTimestamp: TimeInterval = 0
    private static var cachedEnvEntries: [EnvEntryInfo] = []

    static func workspaceEnvEntries(in workspacePath: String, openDocuments: [String: String] = [:]) -> [EnvEntryInfo] {
        guard !workspacePath.isEmpty else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        var docHasher = Hasher()
        for k in openDocuments.keys.sorted() where isEnvFile(k) {
            docHasher.combine(k)
            docHasher.combine(openDocuments[k]?.utf8.count ?? 0)
        }
        let openHash = docHasher.finalize()

        envCacheLock.lock()
        if cachedEnvWorkspacePath == workspacePath,
           cachedEnvOpenDocHash == openHash,
           now - cachedEnvTimestamp < 2.0 {
            let hit = cachedEnvEntries
            envCacheLock.unlock()
            return hit
        }
        envCacheLock.unlock()

        let fm = FileManager.default
        let rootPath = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().path

        var candidatePaths = Set<String>()

        if let rootEntries = try? fm.contentsOfDirectory(atPath: rootPath) {
            for entry in rootEntries {
                if skippedDirectoryNames.contains(entry) { continue }
                let fullPath = (rootPath as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if entry.hasPrefix(".") { continue }
                    if let subEntries = try? fm.contentsOfDirectory(atPath: fullPath) {
                        for sub in subEntries where isEnvCandidateFileName(sub) {
                            let subFull = (fullPath as NSString).appendingPathComponent(sub)
                            var subIsDir: ObjCBool = false
                            if fm.fileExists(atPath: subFull, isDirectory: &subIsDir), !subIsDir.boolValue {
                                candidatePaths.insert(URL(fileURLWithPath: subFull).resolvingSymlinksInPath().path)
                            }
                        }
                    }
                } else if isEnvCandidateFileName(entry) {
                    candidatePaths.insert(URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path)
                }
            }
        }

        var normalizedOpenDocs: [String: String] = [:]
        for (docPath, content) in openDocuments {
            let resolved = URL(fileURLWithPath: docPath).resolvingSymlinksInPath().path
            normalizedOpenDocs[resolved] = content
            normalizedOpenDocs[docPath] = content
            if (resolved.hasPrefix(rootPath + "/") || docPath.hasPrefix(workspacePath + "/")),
               isEnvCandidateFileName((resolved as NSString).lastPathComponent) {
                candidatePaths.insert(resolved)
            }
        }

        let sortedPaths = candidatePaths.sorted {
            envFileSortKey(path: $0, workspaceRoot: rootPath) < envFileSortKey(path: $1, workspaceRoot: rootPath)
        }

        var results: [EnvEntryInfo] = []
        for filePath in sortedPaths {
            autoreleasepool {
                let text: String
                if let openText = normalizedOpenDocs[filePath] {
                    text = openText
                } else {
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let size = attrs[.size] as? NSNumber,
                          size.intValue <= 512_000,
                          let diskText = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                        return
                    }
                    text = diskText
                }
                let fileName = (filePath as NSString).lastPathComponent
                let lines = text.components(separatedBy: .newlines)
                for (lineIdx, rawLine) in lines.enumerated() {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") || trimmed.hasPrefix("[") {
                        continue
                    }
                    var working = trimmed
                    if working.hasPrefix("export ") || working.hasPrefix("export\t") {
                        working = String(working.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    }
                    guard let eqIdx = working.firstIndex(of: "=") else { continue }
                    let key = String(working[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    guard isValidEnvKeyIdentifier(key) else { continue }
                    let rawVal = String(working[working.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                    let withoutComment = stripInlineYAMLComment(rawVal).trimmingCharacters(in: .whitespaces)
                    let cleanValue = unquoteEnvValue(withoutComment)
                    results.append(
                        EnvEntryInfo(
                            key: key,
                            value: cleanValue,
                            filePath: filePath,
                            fileName: fileName,
                            line: lineIdx + 1,
                            isSensitive: isSensitiveEnvKey(key)
                        )
                    )
                }
            }
        }

        envCacheLock.lock()
        cachedEnvWorkspacePath = workspacePath
        cachedEnvOpenDocHash = openHash
        cachedEnvTimestamp = now
        cachedEnvEntries = results
        envCacheLock.unlock()

        return results
    }

    static func findEnvDefinition(forKey key: String, in workspacePath: String, openDocuments: [String: String] = [:]) -> EnvEntryInfo? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let entries = workspaceEnvEntries(in: workspacePath, openDocuments: openDocuments)
        return entries.first(where: { $0.key == trimmedKey })
    }

    private static let goEnvCallRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:os|syscall)\.\s*(?:Getenv|LookupEnv|Setenv|Unsetenv)\s*\(\s*["`]([^"`\n]+)["`]"#
    )

    private static let goEnvStructTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\benv:"([A-Za-z_][A-Za-z0-9_.-]*)(?:,[^"]*)?""#
    )

    private static let goEnvPrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:(?:os|syscall)\.\s*(?:Getenv|LookupEnv|Setenv|Unsetenv)\s*\(\s*|\benv:)"([A-Za-z0-9_.-]*)$"#
    )

    static func detectGoEnvKeyAtOffset(inLine lineText: String, column0: Int) -> String? {
        guard !lineText.isEmpty else { return nil }
        let nsLine = lineText as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let clampedCol = max(0, min(column0, nsLine.length))

        if let regex = goEnvCallRegex {
            let matches = regex.matches(in: lineText, range: fullRange)
            for match in matches where match.numberOfRanges > 1 {
                let keyRange = match.range(at: 1)
                guard keyRange.location != NSNotFound, keyRange.length > 0 else { continue }
                let quoteStart = max(0, keyRange.location - 1)
                let quoteEnd = min(nsLine.length, NSMaxRange(keyRange) + 1)
                if clampedCol >= quoteStart && clampedCol <= quoteEnd {
                    let key = nsLine.substring(with: keyRange)
                    return key.isEmpty ? nil : key
                }
            }
        }

        if let tagRegex = goEnvStructTagRegex {
            let matches = tagRegex.matches(in: lineText, range: fullRange)
            for match in matches where match.numberOfRanges > 1 {
                let keyRange = match.range(at: 1)
                guard keyRange.location != NSNotFound, keyRange.length > 0 else { continue }
                let quoteStart = max(0, keyRange.location - 1)
                let quoteEnd = min(nsLine.length, NSMaxRange(keyRange) + 1)
                if clampedCol >= quoteStart && clampedCol <= quoteEnd {
                    let key = nsLine.substring(with: keyRange)
                    return key.isEmpty ? nil : key
                }
            }
        }

        return nil
    }

    static func isCursorInsideGoEnvStringArg(linePrefix: String) -> String? {
        guard !linePrefix.isEmpty, let regex = goEnvPrefixRegex else { return nil }
        let nsPrefix = linePrefix as NSString
        let range = NSRange(location: 0, length: nsPrefix.length)
        guard let match = regex.firstMatch(in: linePrefix, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        let prefixRange = match.range(at: 1)
        guard prefixRange.location != NSNotFound else { return nil }
        return nsPrefix.substring(with: prefixRange)
    }

    static func detectEnvKeyAtOffset(inLine lineText: String, column0: Int) -> String? {
        guard !lineText.isEmpty else { return nil }
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") || trimmed.hasPrefix("[") {
            return nil
        }
        let nsLine = lineText as NSString
        let eqRange = nsLine.range(of: "=")
        guard eqRange.location != NSNotFound else { return nil }
        let clampedCol = max(0, min(column0, nsLine.length))
        guard clampedCol <= eqRange.location else { return nil }
        var rawKey = nsLine.substring(to: eqRange.location).trimmingCharacters(in: .whitespaces)
        if rawKey.hasPrefix("export ") || rawKey.hasPrefix("export\t") {
            rawKey = String(rawKey.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        guard isValidEnvKeyIdentifier(rawKey) else { return nil }
        return rawKey
    }

    static func findGoEnvKeyUsages(forKey key: String, in workspacePath: String, openDocuments: [String: String] = [:]) -> [LSPLocation] {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !workspacePath.isEmpty else { return [] }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath()
        let rootPath = rootURL.path

        var goFiles: [String] = []
        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                if skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if name.hasSuffix(".go") {
                    goFiles.append(fileURL.resolvingSymlinksInPath().path)
                    if goFiles.count >= 400 {
                        break
                    }
                }
            }
        }
        goFiles.sort()

        var normalizedOpenDocs: [String: String] = [:]
        for (docPath, content) in openDocuments {
            normalizedOpenDocs[URL(fileURLWithPath: docPath).resolvingSymlinksInPath().path] = content
            normalizedOpenDocs[docPath] = content
        }
        for docPath in normalizedOpenDocs.keys where docPath.hasSuffix(".go") && docPath.hasPrefix(rootPath + "/") {
            if !goFiles.contains(docPath) {
                goFiles.append(docPath)
            }
        }

        let quotedDouble = "\"\(trimmedKey)\""
        let quotedBacktick = "`\(trimmedKey)`"
        let structTagPrefix = "env:\"\(trimmedKey)"
        var locations: [LSPLocation] = []

        for filePath in goFiles {
            if locations.count >= 200 { break }
            autoreleasepool {
                let content: String
                if let openText = normalizedOpenDocs[filePath] {
                    content = openText
                } else {
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let size = attrs[.size] as? Int,
                          size > 0,
                          size <= 256_000,
                          let diskText = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
                    content = diskText
                }
                guard content.contains(trimmedKey) else { return }

                let lines = content.components(separatedBy: .newlines)
                for (lineIdx, line) in lines.enumerated() {
                    guard line.contains(trimmedKey) else { continue }
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.hasPrefix("//") { continue }

                    let hasEnvCall = (line.contains("Getenv") || line.contains("LookupEnv") || line.contains("Setenv") || line.contains("Unsetenv")) &&
                        (line.contains(quotedDouble) || line.contains(quotedBacktick))
                    let hasStructTag: Bool = {
                        guard line.contains(structTagPrefix) else { return false }
                        let ns = line as NSString
                        let r = ns.range(of: structTagPrefix)
                        guard r.location != NSNotFound else { return false }
                        let afterIdx = NSMaxRange(r)
                        guard afterIdx < ns.length else { return false }
                        let nextChar = ns.character(at: afterIdx)
                        return nextChar == 0x22 || nextChar == 0x2C
                    }()

                    guard hasEnvCall || hasStructTag else { continue }

                    let nsLine = line as NSString
                    var keyStartCol = 0
                    let doubleRange = nsLine.range(of: quotedDouble)
                    if doubleRange.location != NSNotFound {
                        keyStartCol = doubleRange.location + 1
                    } else {
                        let tickRange = nsLine.range(of: quotedBacktick)
                        if tickRange.location != NSNotFound {
                            keyStartCol = tickRange.location + 1
                        } else {
                            let tagRange = nsLine.range(of: structTagPrefix)
                            if tagRange.location != NSNotFound {
                                keyStartCol = tagRange.location + 5
                            }
                        }
                    }
                    let keyEndCol = keyStartCol + (trimmedKey as NSString).length
                    locations.append(
                        LSPLocation(
                            uri: lspURI(forPath: filePath),
                            range: LSPRange(
                                start: LSPPosition(line: lineIdx, character: keyStartCol),
                                end: LSPPosition(line: lineIdx, character: keyEndCol)
                            )
                        )
                    )
                    if locations.count >= 200 { break }
                }
            }
        }

        return locations
    }

    private static func isValidEnvKeyIdentifier(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        for (idx, scalar) in key.unicodeScalars.enumerated() {
            let v = scalar.value
            let isAlpha = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = (v >= 0x30 && v <= 0x39)
            if idx == 0 {
                if !isAlpha && v != 0x5F { return false }
            } else {
                if !isAlpha && !isDigit && v != 0x5F && v != 0x2E && v != 0x2D { return false }
            }
        }
        return true
    }

    private static func unquoteEnvValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
           (trimmed.hasPrefix("`") && trimmed.hasSuffix("`")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static let sensitiveKeyTokens: [String] = [
        "SECRET", "PASSWORD", "PASSWD", "TOKEN", "API_KEY", "APIKEY",
        "PRIVATE_KEY", "ACCESS_KEY", "CLIENT_SECRET", "AUTH",
        "CREDENTIAL", "DSN", "DATABASE_URL", "REDIS_URL", "JWT"
    ]

    static func isSensitiveEnvKey(_ key: String) -> Bool {
        let upper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return false }
        for token in sensitiveKeyTokens {
            if upper.contains(token) {
                return true
            }
        }
        return false
    }

    static func maskedEnvValueRanges(in text: String) -> [(key: String, line: Int, valueRange: NSRange)] {
        maskedEnvValueRanges(in: text as NSString)
    }

    static func maskedEnvValueRanges(in text: NSString) -> [(key: String, line: Int, valueRange: NSRange)] {
        let totalLen = text.length
        guard totalLen > 0, totalLen <= maxDocumentBytes else { return [] }

        var results: [(key: String, line: Int, valueRange: NSRange)] = []
        var location = 0
        var lineNumber = 1

        while location < totalLen {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location {
                let ch = text.character(at: contentEnd - 1)
                if ch == 0x0A || ch == 0x0D {
                    contentEnd -= 1
                } else {
                    break
                }
            }

            let contentLen = contentEnd - lineRange.location
            if contentLen > 0 {
                let lineStr = text.substring(with: NSRange(location: lineRange.location, length: contentLen))
                let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(";") {
                    let nsLine = lineStr as NSString
                    let eqRange = nsLine.range(of: "=")
                    if eqRange.location != NSNotFound {
                        var rawKey = nsLine.substring(to: eqRange.location).trimmingCharacters(in: .whitespaces)
                        if rawKey.hasPrefix("export ") {
                            rawKey = String(rawKey.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        }
                        if isSensitiveEnvKey(rawKey) {
                            var valStart = eqRange.location + 1
                            while valStart < contentLen {
                                let c = nsLine.character(at: valStart)
                                if c == 0x20 || c == 0x09 {
                                    valStart += 1
                                } else {
                                    break
                                }
                            }
                            let valEnd = contentLen
                            if valEnd > valStart {
                                let absRange = NSRange(location: lineRange.location + valStart, length: valEnd - valStart)
                                results.append((key: rawKey, line: lineNumber, valueRange: absRange))
                            }
                        }
                    }
                }
            }

            location = NSMaxRange(lineRange)
            lineNumber += 1
        }

        return results
    }
}
