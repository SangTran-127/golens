import Foundation

public enum SourceLineScanner {
    public static func enumerateLines(
        in text: String,
        _ body: (_ lineNumber: Int, _ line: Substring, _ stop: inout Bool) -> Void
    ) {
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var lineNumber = 1
        var stop = false
        var idx = lineStart
        while idx < utf8.endIndex {
            if utf8[idx] == 0x0A {
                body(lineNumber, text[lineStart..<idx], &stop)
                if stop { return }
                lineNumber += 1
                idx = utf8.index(after: idx)
                lineStart = idx
            } else {
                idx = utf8.index(after: idx)
            }
        }
        body(lineNumber, text[lineStart..<utf8.endIndex], &stop)
    }

    public static func indentLines(in text: String, indent: String) -> (text: String, utf16Delta: Int) {
        if text.isEmpty { return ("", 0) }
        let utf8 = text.utf8
        let indentUTF16Length = indent.utf16.count
        var out = String()
        out.reserveCapacity(utf8.count + indent.utf8.count * 4)
        var added = 0
        var lineStart = utf8.startIndex
        var idx = lineStart
        while idx < utf8.endIndex {
            if utf8[idx] == 0x0A {
                out.append(indent)
                out += text[lineStart..<idx]
                out.append("\n")
                added += indentUTF16Length
                idx = utf8.index(after: idx)
                lineStart = idx
            } else {
                idx = utf8.index(after: idx)
            }
        }
        if lineStart < utf8.endIndex {
            out.append(indent)
            out += text[lineStart..<utf8.endIndex]
            added += indentUTF16Length
        }
        return (out, added)
    }

    public static func outdentLines(in text: String, tabSize: Int) -> (text: String, utf16Delta: Int) {
        if text.isEmpty { return ("", 0) }
        let utf8 = text.utf8
        var out = String()
        out.reserveCapacity(utf8.count)
        var removed = 0
        func appendOutdented(_ line: Substring) {
            if line.hasPrefix("\t") {
                removed += 1
                out += line.dropFirst()
                return
            }
            var spaces = 0
            var cursor = line.startIndex
            while spaces < tabSize && cursor < line.endIndex && line[cursor] == " " {
                spaces += 1
                cursor = line.index(after: cursor)
            }
            removed += spaces
            out += line[cursor...]
        }
        var lineStart = utf8.startIndex
        var idx = lineStart
        while idx < utf8.endIndex {
            if utf8[idx] == 0x0A {
                appendOutdented(text[lineStart..<idx])
                out.append("\n")
                idx = utf8.index(after: idx)
                lineStart = idx
            } else {
                idx = utf8.index(after: idx)
            }
        }
        if lineStart < utf8.endIndex {
            appendOutdented(text[lineStart..<utf8.endIndex])
        }
        return (out, removed)
    }

    public static func parseGitBlameAuthors(in output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var currentLine: Int?
        enumerateLines(in: output) { _, rawLine, _ in
            let l = rawLine.last == "\r" ? rawLine.dropLast() : rawLine
            let trimmedStart = l.drop(while: { $0 == " " })
            if let s1 = trimmedStart.firstIndex(of: " "),
               trimmedStart[..<s1].count == 40,
               trimmedStart[..<s1].allSatisfy(\.isHexDigit) {
                let rest1 = trimmedStart[s1...].drop(while: { $0 == " " })
                if let s2 = rest1.firstIndex(of: " ") {
                    let rest2 = rest1[s2...].drop(while: { $0 == " " })
                    let s3 = rest2.firstIndex(of: " ") ?? rest2.endIndex
                    if let line = Int(rest2[..<s3]) {
                        currentLine = line
                        return
                    }
                }
            }
            if l.hasPrefix("author "), let line = currentLine {
                let author = l.dropFirst("author ".count)
                if author != "Not Committed Yet" {
                    result[line] = String(author)
                }
            }
        }
        return result
    }
}

public enum BenchmarkSignatureParser {
    public struct DiscoveredBenchmark: Equatable, Sendable {
        public let line: Int
        public let name: String

        public init(line: Int, name: String) {
            self.line = line
            self.name = name
        }
    }

    private static let maxSignatureParenScanBytes = 256

    public static func parseBenchmarkFuncName(in line: String) -> String? {
        parseBenchmarkFuncName(in: line[...])
    }

    public static func parseBenchmarkFuncName(in line: Substring) -> String? {
        let trimmed = trimHorizontalAndCR(line)
        guard trimmed.hasPrefix("func") else { return nil }
        let afterFuncKeyword = trimmed.dropFirst(4)
        guard let firstSpace = afterFuncKeyword.first, isHorizontalSpace(firstSpace) else {
            return nil
        }
        let afterSpaces = dropLeadingHorizontalSpace(afterFuncKeyword)
        guard afterSpaces.hasPrefix("Benchmark") else { return nil }

        var nameEnd = afterSpaces.startIndex
        while nameEnd < afterSpaces.endIndex, isGoIdentCharacter(afterSpaces[nameEnd]) {
            nameEnd = afterSpaces.index(after: nameEnd)
        }
        let name = afterSpaces[..<nameEnd]
        guard name.hasPrefix("Benchmark"), !name.isEmpty else { return nil }
        let rest = name.dropFirst("Benchmark".count)
        if let firstAfterPrefix = rest.first, firstAfterPrefix >= "a" && firstAfterPrefix <= "z" {
            return nil
        }

        let afterName = dropLeadingHorizontalSpace(afterSpaces[nameEnd...])
        guard afterName.first == "(" else { return nil }
        let paramsStart = afterName.index(after: afterName.startIndex)
        var scan = paramsStart
        var scannedBytes = 0
        var closeParen: String.Index?
        while scan < afterName.endIndex && scannedBytes < maxSignatureParenScanBytes {
            let ch = afterName[scan]
            if ch == ")" {
                closeParen = scan
                break
            }
            if ch == "(" || ch == "{" || ch == "\n" {
                return nil
            }
            let next = afterName.index(after: scan)
            scannedBytes += afterName[scan..<next].utf8.count
            scan = next
        }
        guard let closeParen else { return nil }
        let inner = afterName[paramsStart..<closeParen]
        guard isSingleTestingBParameter(inner) else { return nil }
        return String(name)
    }

    public static func discoverBenchmarks(in text: String) -> [DiscoveredBenchmark] {
        guard text.contains("Benchmark") else { return [] }
        var found: [DiscoveredBenchmark] = []
        SourceLineScanner.enumerateLines(in: text) { lineNumber, line, _ in
            if let name = parseBenchmarkFuncName(in: line) {
                found.append(DiscoveredBenchmark(line: lineNumber, name: name))
            }
        }
        return found
    }

    public static func resolve(
        astBenchmarks: [DiscoveredBenchmark],
        text: String,
        isEdited: Bool
    ) -> [DiscoveredBenchmark] {
        guard text.contains("Benchmark") else { return [] }
        if !isEdited {
            return astBenchmarks.isEmpty ? discoverBenchmarks(in: text) : astBenchmarks
        }
        var live = discoverBenchmarks(in: text)
        var seen = Set(live.map(\.name))
        for item in astBenchmarks where !seen.contains(item.name) && text.contains(item.name) {
            seen.insert(item.name)
            live.append(item)
        }
        return live.sorted { $0.line < $1.line }
    }

    public static func isSingleTestingBParameter(_ inner: Substring) -> Bool {
        var trimmed = trimHorizontalAndCR(inner)
        if trimmed.last == "," {
            trimmed = trimHorizontalAndCR(trimmed.dropLast())
        }
        guard !trimmed.isEmpty, !trimmed.contains(",") else { return false }
        guard let starIndex = trimmed.firstIndex(of: "*") else { return false }
        let paramIdent = trimHorizontalAndCR(trimmed[..<starIndex])
        if !paramIdent.isEmpty && !isValidGoIdentifier(paramIdent) {
            return false
        }
        let typePart = trimHorizontalAndCR(trimmed[trimmed.index(after: starIndex)...])
        guard let dotIndex = typePart.firstIndex(of: ".") else { return false }
        let pkgIdent = typePart[..<dotIndex]
        let typeIdent = typePart[typePart.index(after: dotIndex)...]
        guard typeIdent == "B", isValidGoIdentifier(pkgIdent) else {
            return false
        }
        return true
    }

    private static func isHorizontalSpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t"
    }

    private static func dropLeadingHorizontalSpace(_ s: Substring) -> Substring {
        var idx = s.startIndex
        while idx < s.endIndex && isHorizontalSpace(s[idx]) {
            idx = s.index(after: idx)
        }
        return s[idx...]
    }

    private static func trimHorizontalAndCR(_ s: Substring) -> Substring {
        var start = s.startIndex
        var end = s.endIndex
        while start < end && (isHorizontalSpace(s[start]) || s[start] == "\r") {
            start = s.index(after: start)
        }
        while end > start {
            let prev = s.index(before: end)
            if isHorizontalSpace(s[prev]) || s[prev] == "\r" {
                end = prev
            } else {
                break
            }
        }
        return s[start..<end]
    }

    private static func isGoIdentCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return ch.isLetter || ch.isNumber
        }
        let v = scalar.value
        return v == 0x5F || (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v >= 0x80
    }

    private static func isValidGoIdentifier(_ s: Substring) -> Bool {
        guard let first = s.first else { return false }
        if first >= "0" && first <= "9" {
            return false
        }
        return s.allSatisfy(isGoIdentCharacter)
    }
}

public struct BenchmarkMetricValues: Codable, Equatable, Sendable {
    public let nsPerOp: Double
    public let bytesPerOp: Int64
    public let allocsPerOp: Int64

    public init(nsPerOp: Double, bytesPerOp: Int64, allocsPerOp: Int64) {
        self.nsPerOp = nsPerOp
        self.bytesPerOp = bytesPerOp
        self.allocsPerOp = allocsPerOp
    }
}

public struct BenchmarkDiffSnapshot: Equatable, Sendable {
    public let name: String
    public let importPath: String
    public let baselineNsPerOp: Double
    public let currentNsPerOp: Double
    public let nsDeltaPct: Double
    public let baselineBytesPerOp: Int64
    public let currentBytesPerOp: Int64
    public let bytesDeltaPct: Double
    public let baselineAllocsPerOp: Int64
    public let currentAllocsPerOp: Int64
    public let allocsDeltaPct: Double
    public let verdict: String
    public let inlineBadge: String

    public init(
        name: String,
        importPath: String = "",
        baselineNsPerOp: Double,
        currentNsPerOp: Double,
        nsDeltaPct: Double,
        baselineBytesPerOp: Int64,
        currentBytesPerOp: Int64,
        bytesDeltaPct: Double,
        baselineAllocsPerOp: Int64,
        currentAllocsPerOp: Int64,
        allocsDeltaPct: Double,
        verdict: String,
        inlineBadge: String
    ) {
        self.name = name
        self.importPath = importPath
        self.baselineNsPerOp = baselineNsPerOp
        self.currentNsPerOp = currentNsPerOp
        self.nsDeltaPct = nsDeltaPct
        self.baselineBytesPerOp = baselineBytesPerOp
        self.currentBytesPerOp = currentBytesPerOp
        self.bytesDeltaPct = bytesDeltaPct
        self.baselineAllocsPerOp = baselineAllocsPerOp
        self.currentAllocsPerOp = currentAllocsPerOp
        self.allocsDeltaPct = allocsDeltaPct
        self.verdict = verdict
        self.inlineBadge = inlineBadge
    }

    public func matches(importPath targetImportPath: String, name targetName: String) -> Bool {
        guard name == targetName else { return false }
        if targetImportPath.isEmpty || importPath.isEmpty {
            return true
        }
        return importPath == targetImportPath
    }
}

public enum BenchmarkMetricsFormatter {
    public static func parseMetricString(_ raw: String) -> BenchmarkMetricValues? {
        var nsPerOp: Double = 0
        var bytesPerOp: Int64 = 0
        var allocsPerOp: Int64 = 0
        var found = false

        for segment in raw.split(separator: "·") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let valueStr = parts[0]
            let unit = parts[1]
            switch unit {
            case "ns/op":
                if let v = Double(valueStr) {
                    nsPerOp = v
                    found = true
                }
            case "B/op":
                if let v = Int64(valueStr) {
                    bytesPerOp = v
                    found = true
                }
            case "allocs/op":
                if let v = Int64(valueStr) {
                    allocsPerOp = v
                    found = true
                }
            default:
                break
            }
        }
        return found ? BenchmarkMetricValues(nsPerOp: nsPerOp, bytesPerOp: bytesPerOp, allocsPerOp: allocsPerOp) : nil
    }

    public static func formatNsPerOp(_ ns: Double) -> String {
        if ns >= 100 {
            return String(format: "%.0f ns/op", ns)
        } else if ns >= 10 {
            return String(format: "%.1f ns/op", ns)
        }
        return String(format: "%.2f ns/op", ns)
    }

    public static func formatMetricsTuple(
        nsPerOp: Double,
        bytesPerOp: Int64,
        allocsPerOp: Int64,
        includeZeroAllocs: Bool = false
    ) -> String {
        var parts = [formatNsPerOp(nsPerOp)]
        if bytesPerOp > 0 || allocsPerOp > 0 || includeZeroAllocs {
            parts.append("\(bytesPerOp) B/op")
            parts.append("\(allocsPerOp) allocs/op")
        }
        return parts.joined(separator: " · ")
    }

    public static func inlineBadge(currentNs: Double, baselineNs: Double) -> (badge: String, verdict: String) {
        let deltaPct = ((currentNs - baselineNs) / baselineNs) * 100.0
        if deltaPct <= -3.0 {
            return (String(format: "%.1f%% faster", deltaPct), "faster")
        } else if deltaPct >= 5.0 {
            return (String(format: "+%.1f%% slower", deltaPct), "regressed")
        }
        return (String(format: "≈%.1f%% ns/op", abs(deltaPct)), "unchanged")
    }

    public static func compareLensTitle(
        current: BenchmarkMetricValues?,
        baseline: BenchmarkMetricValues?,
        diff: BenchmarkDiffSnapshot?
    ) -> String {
        if let diff {
            let baselineHasAllocs = diff.baselineBytesPerOp > 0
                || diff.baselineAllocsPerOp > 0
                || (baseline.map { $0.bytesPerOp > 0 || $0.allocsPerOp > 0 } ?? false)
            if diff.currentNsPerOp > 0 && diff.baselineNsPerOp > 0 {
                let metrics = formatMetricsTuple(
                    nsPerOp: diff.currentNsPerOp,
                    bytesPerOp: diff.currentBytesPerOp,
                    allocsPerOp: diff.currentAllocsPerOp,
                    includeZeroAllocs: baselineHasAllocs
                )
                return "Compare Baseline (\(metrics) · \(diff.inlineBadge))"
            }
            if diff.baselineNsPerOp > 0 {
                let metrics = formatMetricsTuple(
                    nsPerOp: diff.baselineNsPerOp,
                    bytesPerOp: diff.baselineBytesPerOp,
                    allocsPerOp: diff.baselineAllocsPerOp
                )
                return "Compare Baseline (\(metrics) · baseline saved)"
            }
            if diff.currentNsPerOp > 0 {
                let metrics = formatMetricsTuple(
                    nsPerOp: diff.currentNsPerOp,
                    bytesPerOp: diff.currentBytesPerOp,
                    allocsPerOp: diff.currentAllocsPerOp
                )
                return "Compare Baseline (\(metrics) · \(diff.inlineBadge))"
            }
        }

        if let current, let base = baseline, base.nsPerOp > 0, current.nsPerOp > 0 {
            let badge = inlineBadge(currentNs: current.nsPerOp, baselineNs: base.nsPerOp).badge
            let baselineHasAllocs = base.bytesPerOp > 0 || base.allocsPerOp > 0
            let metrics = formatMetricsTuple(
                nsPerOp: current.nsPerOp,
                bytesPerOp: current.bytesPerOp,
                allocsPerOp: current.allocsPerOp,
                includeZeroAllocs: baselineHasAllocs
            )
            return "Compare Baseline (\(metrics) · \(badge))"
        }

        if let base = baseline, base.nsPerOp > 0 {
            let metrics = formatMetricsTuple(
                nsPerOp: base.nsPerOp,
                bytesPerOp: base.bytesPerOp,
                allocsPerOp: base.allocsPerOp
            )
            return "Compare Baseline (\(metrics) · baseline saved)"
        }

        if let current, current.nsPerOp > 0 {
            let metrics = formatMetricsTuple(
                nsPerOp: current.nsPerOp,
                bytesPerOp: current.bytesPerOp,
                allocsPerOp: current.allocsPerOp
            )
            return "Compare Baseline (\(metrics) · new)"
        }

        return "Compare Baseline"
    }

    public static func compactCompareLensTitle(
        current: BenchmarkMetricValues?,
        baseline: BenchmarkMetricValues?,
        diff: BenchmarkDiffSnapshot?
    ) -> String {
        if let diff {
            if diff.currentNsPerOp > 0 && diff.baselineNsPerOp > 0 {
                return "\(formatNsPerOp(diff.currentNsPerOp)) · \(diff.inlineBadge)"
            }
            if diff.baselineNsPerOp > 0 {
                return "Baseline \(formatNsPerOp(diff.baselineNsPerOp))"
            }
            if diff.currentNsPerOp > 0 {
                return "\(formatNsPerOp(diff.currentNsPerOp)) · \(diff.inlineBadge)"
            }
        }
        if let current, let base = baseline, base.nsPerOp > 0, current.nsPerOp > 0 {
            let badge = inlineBadge(currentNs: current.nsPerOp, baselineNs: base.nsPerOp).badge
            return "\(formatNsPerOp(current.nsPerOp)) · \(badge)"
        }
        if let base = baseline, base.nsPerOp > 0 {
            return "Baseline \(formatNsPerOp(base.nsPerOp))"
        }
        if let current, current.nsPerOp > 0 {
            return "\(formatNsPerOp(current.nsPerOp)) · new"
        }
        return "Compare"
    }

    public static func deltaSummary(
        current: BenchmarkMetricValues?,
        baseline: BenchmarkMetricValues?,
        diff: BenchmarkDiffSnapshot?
    ) -> (text: String, isImproved: Bool, isRegressed: Bool)? {
        if let diff, diff.baselineNsPerOp > 0, diff.currentNsPerOp > 0 {
            var summary = diff.inlineBadge
            if diff.baselineBytesPerOp > 0 && abs(diff.bytesDeltaPct) >= 1.0 {
                summary += String(format: " · %+.1f%% B/op", diff.bytesDeltaPct)
            }
            return (text: summary, isImproved: diff.verdict == "faster", isRegressed: diff.verdict == "regressed")
        }
        guard let current, let baseline, baseline.nsPerOp > 0, current.nsPerOp > 0 else {
            return nil
        }
        let result = inlineBadge(currentNs: current.nsPerOp, baselineNs: baseline.nsPerOp)
        var summary = result.badge
        if baseline.bytesPerOp > 0 {
            let bytesDeltaPct = (Double(current.bytesPerOp - baseline.bytesPerOp) / Double(baseline.bytesPerOp)) * 100.0
            if abs(bytesDeltaPct) >= 1.0 {
                summary += String(format: " · %+.1f%% B/op", bytesDeltaPct)
            }
        }
        return (text: summary, isImproved: result.verdict == "faster", isRegressed: result.verdict == "regressed")
    }
}

public enum BenchmarkScopeStore {
    public struct ComparisonPartition: Equatable, Sendable {
        public let importPath: String
        public let baselines: [String: BenchmarkMetricValues]
        public let currentLines: String

        public init(importPath: String, baselines: [String: BenchmarkMetricValues], currentLines: String) {
            self.importPath = importPath
            self.baselines = baselines
            self.currentLines = currentLines
        }
    }

    public static func testKey(importPath: String, name: String) -> String {
        importPath + "\u{0}" + name
    }

    public static func baselineKey(importPath: String, name: String) -> String {
        importPath.isEmpty ? name : "\(importPath)::\(name)"
    }

    public static func splitKey(_ rawKey: String) -> (importPath: String, name: String) {
        if let idx = rawKey.range(of: "\u{0}") {
            return (String(rawKey[..<idx.lowerBound]), String(rawKey[idx.upperBound...]))
        }
        if let idx = rawKey.range(of: "::") {
            return (String(rawKey[..<idx.lowerBound]), String(rawKey[idx.upperBound...]))
        }
        return ("", rawKey)
    }

    public static func shortName(fromKey rawKey: String) -> String {
        splitKey(rawKey).name
    }

    public static func hasScopedEntry<S: Sequence>(for name: String, in keys: S) -> Bool where S.Element == String {
        for key in keys {
            let (pkg, short) = splitKey(key)
            if !pkg.isEmpty && short == name {
                return true
            }
        }
        return false
    }

    public static func lookupBaseline(
        importPath: String,
        name: String,
        in baselines: [String: BenchmarkMetricValues],
        legacy: [String: BenchmarkMetricValues] = [:]
    ) -> BenchmarkMetricValues? {
        if !importPath.isEmpty {
            if let entry = baselines["\(importPath)::\(name)"] {
                return entry
            }
            if let entry = baselines[testKey(importPath: importPath, name: name)] {
                return entry
            }
            if let entry = legacy["\(importPath)::\(name)"] {
                return entry
            }
            if let entry = legacy[testKey(importPath: importPath, name: name)] {
                return entry
            }
            let hasAnyScoped = hasScopedEntry(for: name, in: baselines.keys) || hasScopedEntry(for: name, in: legacy.keys)
            if !hasAnyScoped {
                return baselines[name] ?? legacy[name]
            }
            return nil
        }

        if let entry = baselines[name] ?? legacy[name] {
            return entry
        }
        return uniqueScopedValue(for: name, in: baselines) ?? uniqueScopedValue(for: name, in: legacy)
    }

    public static func lookupMetric(
        importPath: String,
        name: String,
        in metrics: [String: BenchmarkMetricValues]
    ) -> BenchmarkMetricValues? {
        if !importPath.isEmpty {
            if let entry = metrics[testKey(importPath: importPath, name: name)] {
                return entry
            }
            if let entry = metrics["\(importPath)::\(name)"] {
                return entry
            }
            if !hasScopedEntry(for: name, in: metrics.keys) {
                return metrics[name]
            }
            return nil
        }

        if let entry = metrics[name] {
            return entry
        }
        return uniqueScopedValue(for: name, in: metrics)
    }

    public static func saveBaselines(
        currentBaselines: [String: BenchmarkMetricValues],
        metrics: [String: BenchmarkMetricValues],
        diffRows: [BenchmarkDiffSnapshot] = []
    ) -> (baselines: [String: BenchmarkMetricValues], savedCount: Int) {
        var next = currentBaselines
        var savedCount = 0
        var coveredTargets = Set<String>()

        let scopedMetricShortNames = Set(
            metrics.keys.compactMap { key -> String? in
                let (pkg, short) = splitKey(key)
                return pkg.isEmpty ? nil : short
            }
        )

        for key in metrics.keys.sorted() {
            guard let entry = metrics[key], entry.nsPerOp > 0 else { continue }
            let (pkg, short) = splitKey(key)
            guard !short.isEmpty else { continue }
            if pkg.isEmpty && scopedMetricShortNames.contains(short) {
                continue
            }
            let targetKey = baselineKey(importPath: pkg, name: short)
            next[targetKey] = entry
            coveredTargets.insert(targetKey)
            savedCount += 1
        }

        for row in diffRows where row.currentNsPerOp > 0 {
            let targetKey = baselineKey(importPath: row.importPath, name: row.name)
            guard !coveredTargets.contains(targetKey) else { continue }
            if row.importPath.isEmpty && hasScopedEntry(for: row.name, in: next.keys) {
                continue
            }
            let entry = BenchmarkMetricValues(
                nsPerOp: row.currentNsPerOp,
                bytesPerOp: row.currentBytesPerOp,
                allocsPerOp: row.currentAllocsPerOp
            )
            if next[targetKey] == nil {
                savedCount += 1
            }
            next[targetKey] = entry
            coveredTargets.insert(targetKey)
        }

        if savedCount == 0 && !next.isEmpty {
            savedCount = next.count
        }
        return (next, savedCount)
    }

    public static func partitionComparisonInputs(
        baselines: [String: BenchmarkMetricValues],
        metrics: [String: BenchmarkMetricValues],
        rawOutput: String
    ) -> [ComparisonPartition] {
        var scopedBaselines: [String: [String: BenchmarkMetricValues]] = [:]
        var legacyBaselines: [String: BenchmarkMetricValues] = [:]
        var scopedMetricNames = Set<String>()

        for (rawKey, entry) in baselines where entry.nsPerOp > 0 {
            let (pkg, short) = splitKey(rawKey)
            guard !short.isEmpty else { continue }
            if pkg.isEmpty {
                legacyBaselines[short] = entry
            } else {
                scopedBaselines[pkg, default: [:]][short] = entry
                scopedMetricNames.insert(short)
            }
        }

        var scopedMetrics: [String: [(String, BenchmarkMetricValues)]] = [:]
        var unscopedMetrics: [(String, BenchmarkMetricValues)] = []
        var allMetricShortNames = Set<String>()
        let scopedCurrentShortNames = Set(
            metrics.keys.compactMap { key -> String? in
                let (pkg, short) = splitKey(key)
                return pkg.isEmpty ? nil : short
            }
        )

        for key in metrics.keys.sorted() {
            guard let entry = metrics[key], entry.nsPerOp > 0 else { continue }
            let (pkg, short) = splitKey(key)
            guard !short.isEmpty else { continue }
            if pkg.isEmpty && scopedCurrentShortNames.contains(short) {
                continue
            }
            allMetricShortNames.insert(short)
            if pkg.isEmpty {
                unscopedMetrics.append((short, entry))
            } else {
                scopedMetrics[pkg, default: []].append((short, entry))
            }
        }

        let packagePaths = Set(scopedBaselines.keys).union(scopedMetrics.keys).sorted()
        var partitions: [ComparisonPartition] = []
        var consumedLegacyNames = Set<String>()

        for pkg in packagePaths {
            var pkgBaselines = scopedBaselines[pkg] ?? [:]
            if packagePaths.count == 1 {
                for (short, legacyEntry) in legacyBaselines where pkgBaselines[short] == nil && !scopedMetricNames.contains(short) {
                    pkgBaselines[short] = legacyEntry
                    consumedLegacyNames.insert(short)
                }
            } else {
                for (short, _) in scopedMetrics[pkg] ?? [] where pkgBaselines[short] == nil && !scopedMetricNames.contains(short) {
                    if let legacyEntry = legacyBaselines[short] {
                        pkgBaselines[short] = legacyEntry
                        consumedLegacyNames.insert(short)
                    }
                }
            }
            let lines = formatGoBenchmarkLines(scopedMetrics[pkg] ?? [])
            partitions.append(ComparisonPartition(importPath: pkg, baselines: pkgBaselines, currentLines: lines))
        }

        var leftoverRawLines: [String] = []
        let trimmedRaw = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty {
            SourceLineScanner.enumerateLines(in: trimmedRaw) { _, line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if let rawBenchName = rawBenchmarkLineShortName(trimmed) {
                    if !allMetricShortNames.contains(rawBenchName) {
                        leftoverRawLines.append(trimmed)
                    }
                } else if allMetricShortNames.isEmpty {
                    leftoverRawLines.append(trimmed)
                }
            }
        }

        var remainingLegacy: [String: BenchmarkMetricValues] = [:]
        for (short, legacyEntry) in legacyBaselines where !scopedMetricNames.contains(short) && !consumedLegacyNames.contains(short) {
            if packagePaths.count != 1 {
                remainingLegacy[short] = legacyEntry
            }
        }

        let unscopedLines = (formatGoBenchmarkLines(unscopedMetrics) + (unscopedMetrics.isEmpty || leftoverRawLines.isEmpty ? "" : "\n") + leftoverRawLines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !unscopedLines.isEmpty || (!remainingLegacy.isEmpty && packagePaths.isEmpty) || (!remainingLegacy.isEmpty && unscopedMetrics.isEmpty && packagePaths.count != 1) {
            let effectiveUnscopedBaselines = remainingLegacy.isEmpty && packagePaths.isEmpty ? legacyBaselines : remainingLegacy
            if !unscopedLines.isEmpty || !effectiveUnscopedBaselines.isEmpty {
                partitions.append(ComparisonPartition(importPath: "", baselines: effectiveUnscopedBaselines, currentLines: unscopedLines))
            }
        }

        return partitions
    }

    private static func formatGoBenchmarkLines(_ entries: [(String, BenchmarkMetricValues)]) -> String {
        entries.map { name, entry in
            String(
                format: "%@-8\t1000000\t%.2f ns/op\t%lld B/op\t%lld allocs/op",
                name,
                entry.nsPerOp,
                entry.bytesPerOp,
                entry.allocsPerOp
            )
        }.joined(separator: "\n")
    }

    private static func rawBenchmarkLineShortName(_ line: String) -> String? {
        guard line.hasPrefix("Benchmark") else { return nil }
        guard let firstField = line.split(whereSeparator: \.isWhitespace).first else { return nil }
        var name = String(firstField)
        if let dash = name.lastIndex(of: "-") {
            let afterDash = name[name.index(after: dash)...]
            if !afterDash.isEmpty && afterDash.allSatisfy(\.isNumber) {
                name = String(name[..<dash])
            }
        }
        return name
    }

    private static func uniqueScopedValue(
        for name: String,
        in dict: [String: BenchmarkMetricValues]
    ) -> BenchmarkMetricValues? {
        var matchPkg: String?
        var matchVal: BenchmarkMetricValues?
        for (rawKey, value) in dict {
            let (pkg, short) = splitKey(rawKey)
            guard !pkg.isEmpty && short == name else { continue }
            if let existingPkg = matchPkg {
                if existingPkg != pkg {
                    return nil
                }
            } else {
                matchPkg = pkg
                matchVal = value
            }
        }
        return matchVal
    }
}
