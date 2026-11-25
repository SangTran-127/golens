import CoreGraphics
import Foundation

public enum OpticalLensDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case column
    case inline
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .column: "Always Column"
        case .inline: "Always Inline"
        case .off: "Off"
        }
    }

    public var menuTitle: String {
        switch self {
        case .automatic: "Automatic (By Display)"
        case .column: "Always Column"
        case .inline: "Always Inline"
        case .off: "Off"
        }
    }
}

public enum EffectiveOpticalLensStyle: Equatable, Sendable {
    case column(width: CGFloat)
    case inline
    case minimalOnly

    public var reservedMarginWidth: CGFloat {
        switch self {
        case .column(let width): width
        case .inline, .minimalOnly: 0
        }
    }
}

public enum WorkspaceColumnLayoutMath {
    public static let minWindowWidth: CGFloat = 920
    public static let minWindowHeight: CGFloat = 580
    public static let defaultWindowWidth: CGFloat = 1280
    public static let defaultWindowHeight: CGFloat = 820

    public static let sidebarMinWidth: CGFloat = 210
    public static let sidebarIdealWidth: CGFloat = 256
    public static let sidebarMaxWidth: CGFloat = 320

    public static let editorMinWidth: CGFloat = 380

    public static let gopilotMinWidth: CGFloat = 300
    public static let gopilotIdealWidth: CGFloat = 360
    public static let gopilotMaxWidth: CGFloat = 480

    public static let autoCompactThresholdWidth: CGFloat = 980

    public static let opticalLensExpandedWidth: CGFloat = 208
    public static let wideDisplayMinScreenWidth: CGFloat = 1600
    public static let wideDisplayMinEditorWidth: CGFloat = 920
    public static let fallbackColumnEditorWidth: CGFloat = 1220
    public static let forcedColumnMinEditorWidth: CGFloat = 680

    public static func resolveOpticalLensStyle(
        mode: OpticalLensDisplayMode,
        viewportWidth: CGFloat,
        screenWidth: CGFloat
    ) -> EffectiveOpticalLensStyle {
        guard viewportWidth > 120 else { return .minimalOnly }
        switch mode {
        case .off:
            return .minimalOnly
        case .inline:
            return .inline
        case .column:
            return viewportWidth >= forcedColumnMinEditorWidth
                ? .column(width: opticalLensExpandedWidth)
                : .inline
        case .automatic:
            if screenWidth > 0 {
                if screenWidth >= wideDisplayMinScreenWidth && viewportWidth >= wideDisplayMinEditorWidth {
                    return .column(width: opticalLensExpandedWidth)
                }
                return .inline
            }
            return viewportWidth >= fallbackColumnEditorWidth
                ? .column(width: opticalLensExpandedWidth)
                : .inline
        }
    }

    public struct ColumnResolution: Equatable, Sendable {
        public let shouldCollapseSidebar: Bool
        public let clampedGopilotWidth: CGFloat

        public init(shouldCollapseSidebar: Bool, clampedGopilotWidth: CGFloat) {
            self.shouldCollapseSidebar = shouldCollapseSidebar
            self.clampedGopilotWidth = clampedGopilotWidth
        }
    }

    public static func clampGopilotPreference(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return gopilotIdealWidth }
        return min(max(width, gopilotMinWidth), gopilotMaxWidth)
    }

    public static func shouldAutoCollapseSidebarOnGopilotOpen(
        windowWidth: CGFloat,
        detailWidth: CGFloat,
        isSidebarVisible: Bool,
        gopilotChromeInset: CGFloat = 0
    ) -> Bool {
        guard isSidebarVisible else { return false }
        if windowWidth > 0 && windowWidth < autoCompactThresholdWidth {
            return true
        }
        if detailWidth > 0 && detailWidth < (editorMinWidth + gopilotMinWidth + gopilotChromeInset) {
            return true
        }
        return false
    }

    public static func resolveDetailColumns(
        windowWidth: CGFloat,
        detailWidth: CGFloat,
        isSidebarVisible: Bool,
        isGopilotVisible: Bool,
        requestedGopilotWidth: CGFloat,
        gopilotChromeInset: CGFloat = 0
    ) -> ColumnResolution {
        let baseGopilot = clampGopilotPreference(requestedGopilotWidth)
        guard isGopilotVisible else {
            return ColumnResolution(shouldCollapseSidebar: false, clampedGopilotWidth: baseGopilot)
        }

        let minDetailForBoth = editorMinWidth + gopilotMinWidth + gopilotChromeInset
        let collapseForDetailSqueeze = isSidebarVisible && detailWidth > 0 && detailWidth < minDetailForBoth
        let collapseForTightWindow = isSidebarVisible && detailWidth <= 0 && windowWidth > 0 && windowWidth < autoCompactThresholdWidth
        let shouldCollapse = collapseForDetailSqueeze || collapseForTightWindow

        let effectiveDetailWidth: CGFloat = {
            if shouldCollapse && windowWidth > 0 {
                return windowWidth
            }
            if detailWidth > 0 {
                return detailWidth
            }
            if windowWidth > 0 {
                return isSidebarVisible ? max(minDetailForBoth, windowWidth - sidebarIdealWidth) : windowWidth
            }
            return defaultWindowWidth
        }()

        let maxAllowedByEditor = max(gopilotMinWidth, effectiveDetailWidth - editorMinWidth - gopilotChromeInset)
        let upperBound = min(gopilotMaxWidth, maxAllowedByEditor)
        let clamped = min(max(baseGopilot, gopilotMinWidth), upperBound)
        return ColumnResolution(shouldCollapseSidebar: shouldCollapse, clampedGopilotWidth: clamped)
    }
}

public enum TestDurationFormatter {
    private static let locale = Locale(identifier: "en_US")

    public static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 0.001 {
            return "<1 ms"
        }
        if seconds < 1.0 {
            let ms = max(1, Int((seconds * 1000.0).rounded()))
            return "\(ms) ms"
        }
        if seconds < 10.0 {
            return String(format: "%.2f s", locale: locale, seconds)
        }
        if seconds < 60.0 {
            return String(format: "%.1f s", locale: locale, seconds)
        }
        let mins = Int(seconds) / 60
        let rem = seconds - Double(mins * 60)
        return String(format: "%dm %.1fs", locale: locale, mins, rem)
    }
}

public struct GopilotProseEvidenceRef: Equatable, Sendable {
    public let id: String
    public let path: String
    public let startLine1Based: Int?

    public init(id: String, path: String, startLine1Based: Int?) {
        self.id = id
        self.path = path
        self.startLine1Based = startLine1Based
    }
}

public enum GopilotProseSegment: Equatable, Sendable {
    case text(String)
    case citation(GopilotProseEvidenceRef)
    case unverified(token: String, isExpired: Bool)
}

public enum GopilotProseCitationEngine {
    private static let groupRegex = try! NSRegularExpression(pattern: #"\[(E[0-9]+(?:\s*[,;]\s*E[0-9]+)+)\]"#)
    private static let rangedRegex = try! NSRegularExpression(pattern: #"\[(E[0-9]+)[^\]\n]*\]"#)
    private static let gluedBareRunRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:E[0-9]{1,4}){2,}(?![A-Za-z0-9])"#)
    private static let singleBareERegex = try! NSRegularExpression(pattern: #"E[0-9]{1,4}"#)
    private static let bracketedTokenRegex = try! NSRegularExpression(pattern: #"\[E[0-9]+\]"#)
    private static let citationLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(gopilot-citation://([A-Za-z0-9_-]+)\)"#
    )
    private static let fileLineTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_/-])`?([A-Za-z0-9_./-]+(?:\.go|\.mod|\.sum|\.yaml|\.yml|\.json|\.md|\.sql|\.proto|\.toml|\.sh|\.env|Dockerfile)):([0-9]{1,5})(?:[–-][0-9]{1,5})?`?"#
    )

    public static func normalize(_ text: String) -> String {
        var result = text
        let whole = NSRange(location: 0, length: (result as NSString).length)
        let matches = groupRegex.matches(in: result, range: whole).reversed()
        for match in matches {
            let inner = (result as NSString).substring(with: match.range(at: 1))
            let ids = inner.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map { "[\($0)]" }
            result = (result as NSString).replacingCharacters(in: match.range, with: ids.joined(separator: " "))
        }
        let rangedMatches = rangedRegex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed()
        for match in rangedMatches {
            let id = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: "[\(id)]")
        }
        let gluedMatches = gluedBareRunRegex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed()
        for match in gluedMatches {
            let run = (result as NSString).substring(with: match.range)
            let tokens = singleBareERegex.matches(in: run, range: NSRange(location: 0, length: (run as NSString).length)).map {
                "[\((run as NSString).substring(with: $0.range))]"
            }
            if !tokens.isEmpty {
                result = (result as NSString).replacingCharacters(in: match.range, with: tokens.joined(separator: " "))
            }
        }
        return result
    }

    public static func markExpired(_ text: String) -> String {
        let normalized = normalize(text)
        var result = normalized
        for match in bracketedTokenRegex.matches(in: normalized, range: NSRange(location: 0, length: (normalized as NSString).length)).reversed() {
            result = (result as NSString).replacingCharacters(in: match.range, with: "(source not linked)")
        }
        return result
    }

    public static func stripUnresolvedTokens(_ text: String) -> String {
        var preserved = text
        let preRange = NSRange(location: 0, length: (preserved as NSString).length)
        for match in rangedRegex.matches(in: preserved, range: preRange).reversed() {
            let bracketText = (preserved as NSString).substring(with: match.range)
            let innerRange = NSRange(location: 0, length: (bracketText as NSString).length)
            if let fileMatch = fileLineTokenRegex.firstMatch(in: bracketText, range: innerRange) {
                let fileToken = (bracketText as NSString).substring(with: fileMatch.range)
                preserved = (preserved as NSString).replacingCharacters(in: match.range, with: fileToken)
            }
        }
        let normalized = normalize(preserved)
        let ns = normalized as NSString
        let stripped = bracketedTokenRegex.stringByReplacingMatches(
            in: normalized,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: #",\s*(?=[,;.)\]])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+([,.;:!?)\]])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    public static func linkedMarkdown(
        _ text: String,
        segments: [GopilotProseSegment]?,
        citationScheme: String = "gopilot-citation"
    ) -> String {
        guard let segments,
              segments.contains(where: { if case .text = $0 { return true } else { return false } }) else {
            return stripUnresolvedTokens(text)
        }
        var result = ""
        var lastAdjacentCitationLabel: String?
        for segment in segments {
            switch segment {
            case .text(let value):
                let cleaned = stripUnresolvedTokens(value)
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "," && trimmed != ";" {
                    lastAdjacentCitationLabel = nil
                }
                result += cleaned
            case .citation(let ref):
                guard !ref.path.isEmpty else { continue }
                let name = (ref.path as NSString).lastPathComponent
                let label = ref.startLine1Based.map { "\(name):\($0)" } ?? name
                if lastAdjacentCitationLabel == label {
                    if result.hasSuffix(", ") {
                        result.removeLast(2)
                    } else if result.hasSuffix(",") {
                        result.removeLast()
                    }
                    continue
                }
                if let lastChar = result.last, !lastChar.isWhitespace && lastChar != "(" && lastChar != "[" {
                    result += " "
                }
                result += "[\(label)](\(citationScheme)://\(ref.id))"
                lastAdjacentCitationLabel = label
            case .unverified(let token, let isExpired):
                lastAdjacentCitationLabel = nil
                if let lastChar = result.last, !lastChar.isWhitespace {
                    result += " "
                }
                result += isExpired ? "(expired source \(token))" : "(unverified source)"
            }
        }
        return result
    }

    private enum OccurrenceKind: Equatable {
        case citationChip(evidenceID: String)
        case inlineFileToken
    }

    private struct ReferenceOccurrence {
        let range: NSRange
        let kind: OccurrenceKind
        let relativePath: String
        let fileName: String
        let line: Int?
        let url: URL
    }

    private static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        return p
    }

    private static func isSeparatorOnlyBetweenAdjacentChips(_ gap: String) -> Bool {
        let allowed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;"))
        return gap.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isImmediateParenOrWhitespaceGap(_ gap: String) -> Bool {
        let allowed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "("))
        return gap.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func linkifyReferences(
        in rawText: String,
        evidenceByID: [String: GopilotProseEvidenceRef],
        citationScheme: String = "gopilot-citation",
        fileScheme: String = "gopilot-file"
    ) -> String {
        let ns = rawText as NSString
        let whole = NSRange(location: 0, length: ns.length)

        var knownPathsByFileName: [String: Set<String>] = [:]
        for ref in evidenceByID.values {
            let norm = normalizePath(ref.path)
            guard !norm.isEmpty else { continue }
            knownPathsByFileName[(norm as NSString).lastPathComponent, default: []].insert(norm)
        }

        func resolve(_ path: String) -> String {
            let norm = normalizePath(path)
            let base = (norm as NSString).lastPathComponent
            if !norm.contains("/"),
               let known = knownPathsByFileName[base],
               known.count == 1,
               let single = known.first {
                return single
            }
            return norm
        }

        var occurrences: [ReferenceOccurrence] = []
        let citationMatches = citationLinkRegex.matches(in: rawText, range: whole)
        for match in citationMatches {
            let label = ns.substring(with: match.range(at: 1))
            let evID = ns.substring(with: match.range(at: 2)).uppercased()
            let ref = evidenceByID[evID]
            let relPath = resolve(ref?.path ?? label.components(separatedBy: ":").first ?? label)
            let line = ref?.startLine1Based ?? label.components(separatedBy: ":").dropFirst().first.flatMap(Int.init)
            guard let url = URL(string: "\(citationScheme)://\(evID)") else { continue }
            occurrences.append(ReferenceOccurrence(
                range: match.range,
                kind: .citationChip(evidenceID: evID),
                relativePath: relPath,
                fileName: (relPath as NSString).lastPathComponent,
                line: line,
                url: url
            ))
        }

        for match in fileLineTokenRegex.matches(in: rawText, range: whole) {
            if citationMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                continue
            }
            let relPath = resolve(ns.substring(with: match.range(at: 1)))
            let line = Int(ns.substring(with: match.range(at: 2))) ?? 1
            var components = URLComponents()
            components.scheme = fileScheme
            components.host = "open"
            components.queryItems = [
                URLQueryItem(name: "path", value: relPath),
                URLQueryItem(name: "line", value: String(line))
            ]
            guard let url = components.url else { continue }
            occurrences.append(ReferenceOccurrence(
                range: match.range,
                kind: .inlineFileToken,
                relativePath: relPath,
                fileName: (relPath as NSString).lastPathComponent,
                line: line,
                url: url
            ))
        }

        guard !occurrences.isEmpty else { return rawText }
        occurrences.sort { $0.range.location < $1.range.location }

        var pathsPerBaseName = knownPathsByFileName
        for occurrence in occurrences {
            pathsPerBaseName[occurrence.fileName, default: []].insert(occurrence.relativePath)
        }

        func label(for occurrence: ReferenceOccurrence) -> String {
            var displayPath = occurrence.fileName
            let distinct = pathsPerBaseName[occurrence.fileName] ?? []
            if distinct.count > 1 && occurrence.relativePath.contains("/") {
                let comps = occurrence.relativePath.split(separator: "/")
                if comps.count >= 2 {
                    displayPath = "\(comps[comps.count - 2])/\(comps[comps.count - 1])"
                }
            }
            return occurrence.line.map { "\(displayPath):\($0)" } ?? displayPath
        }

        func sameTarget(_ lhs: ReferenceOccurrence, _ rhs: ReferenceOccurrence) -> Bool {
            guard lhs.relativePath == rhs.relativePath else { return false }
            if let l1 = lhs.line, let l2 = rhs.line {
                return l1 == l2
            }
            return true
        }

        var output = ""
        var cursor = 0
        var index = 0

        while index < occurrences.count {
            let occurrence = occurrences[index]
            if occurrence.range.location < cursor {
                index += 1
                continue
            }
            output += ns.substring(with: NSRange(location: cursor, length: occurrence.range.location - cursor))

            if occurrence.kind == .inlineFileToken,
               index + 1 < occurrences.count {
                let next = occurrences[index + 1]
                if case .citationChip = next.kind,
                   sameTarget(occurrence, next) {
                    let gapRange = NSRange(
                        location: NSMaxRange(occurrence.range),
                        length: max(0, next.range.location - NSMaxRange(occurrence.range))
                    )
                    let gap = ns.substring(with: gapRange)
                    if isImmediateParenOrWhitespaceGap(gap) {
                        output += "[\(label(for: occurrence))](\(next.url.absoluteString))"
                        if gap.contains("(") {
                            output += "("
                        }
                        cursor = NSMaxRange(next.range)
                        index += 2
                        continue
                    }
                }
            }

            output += "[\(label(for: occurrence))](\(occurrence.url.absoluteString))"
            cursor = NSMaxRange(occurrence.range)

            if case .citationChip = occurrence.kind {
                var lookahead = index + 1
                while lookahead < occurrences.count {
                    let candidate = occurrences[lookahead]
                    guard case .citationChip = candidate.kind,
                          sameTarget(occurrence, candidate) else {
                        break
                    }
                    let gapRange = NSRange(location: cursor, length: max(0, candidate.range.location - cursor))
                    let gap = ns.substring(with: gapRange)
                    guard isSeparatorOnlyBetweenAdjacentChips(gap) else {
                        break
                    }
                    cursor = NSMaxRange(candidate.range)
                    lookahead += 1
                }
                index = lookahead
                continue
            }

            index += 1
        }
        output += ns.substring(from: cursor)

        return output
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+([,.;:)\]])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
