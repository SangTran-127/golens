import AppKit
import GoLensFoundation
import GopilotPolicy
import SwiftUI

enum GopilotCitationNormalizer {
    static func markExpired(_ text: String) -> String {
        GopilotProseCitationEngine.markExpired(text)
    }

    static func normalize(_ text: String) -> String {
        GopilotProseCitationEngine.normalize(text)
    }

    static func stripUnresolvedTokens(_ text: String) -> String {
        GopilotProseCitationEngine.stripUnresolvedTokens(text)
    }
}

enum GopilotRenderedBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list([GopilotRenderedListItem])
    case code(language: String?, code: String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case quote(AttributedString)
    case rule
}

struct GopilotRenderedListItem {
    let marker: String
    let isOrdered: Bool
    let indent: Int
    let text: AttributedString
}

@MainActor
enum GopilotMarkdownRenderCache {
    private static var storage: [String: [GopilotRenderedBlock]] = [:]
    private static var order: [String] = []
    private static let capacity = 96

    static func blocks(for text: String, citations: [CitationSegment]?) -> [GopilotRenderedBlock] {
        let linkedText = GopilotAssistantText.linked(text, citations: citations)
        let evidenceByID = GopilotAssistantText.evidenceMap(citations)
        let key = linkedText + "\u{1F}" + evidenceByID.keys.sorted().joined(separator: ",")
        if let cached = storage[key] {
            return cached
        }
        let rendered = GopilotAssistantText.render(linkedText, evidenceByID: evidenceByID)
        storage[key] = rendered
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            storage[evicted] = nil
        }
        return rendered
    }
}

struct GopilotAssistantText: View, Equatable {
    let text: String
    var citations: [CitationSegment]?
    @Environment(\.windowWorkspace) private var workspace

    static func == (lhs: GopilotAssistantText, rhs: GopilotAssistantText) -> Bool {
        lhs.text == rhs.text && lhs.citations == rhs.citations
    }

    static let citationScheme = "gopilot-citation"
    static let fileScheme = "gopilot-file"

    static func evidenceMap(_ citations: [CitationSegment]?) -> [String: Evidence] {
        guard let citations else { return [:] }
        var map: [String: Evidence] = [:]
        for case .citation(let ev) in citations {
            map[ev.id.uppercased()] = ev
        }
        return map
    }

    var body: some View {
        let blocks = GopilotMarkdownRenderCache.blocks(for: text, citations: citations)
        VStack(alignment: .leading, spacing: Spacing.standard) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, index: index)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: GopilotRenderedBlock, index: Int) -> some View {
        switch block {
        case .heading(let level, let value):
            Text(value)
                .font(Self.headingFont(for: level))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, index == 0 ? 0 : 8)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let value):
            Text(value)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let items):
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItemView(item)
                }
            }

        case .code(let language, let value):
            GopilotCodeBlockView(language: language, code: value, fontSize: workspace.editorFontSize)

        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.body.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(Spacing.standard)
            }
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

        case .quote(let value):
            HStack(spacing: Spacing.standard) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .rule:
            Divider()
        }
    }

    private func listItemView(_ item: GopilotRenderedListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Text(item.marker)
                .font(item.isOrdered ? .body.monospacedDigit() : .body)
                .foregroundStyle(.secondary)
                .frame(minWidth: item.isOrdered ? 20 : 12, alignment: .trailing)
                .accessibilityHidden(!item.isOrdered)
            Text(item.text)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.indent) * 16)
    }

    private static func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .body.weight(.semibold)
        }
    }

    private static func proseEvidenceMap(_ evidenceByID: [String: Evidence]) -> [String: GopilotProseEvidenceRef] {
        var mapped: [String: GopilotProseEvidenceRef] = [:]
        for (key, ev) in evidenceByID {
            let ref = ev.sourceRefs.first
            mapped[key.uppercased()] = GopilotProseEvidenceRef(
                id: ev.id,
                path: ref?.path ?? "",
                startLine1Based: ref?.range.map { $0.startLine + 1 }
            )
        }
        return mapped
    }

    static func render(_ linkedText: String, evidenceByID: [String: Evidence]) -> [GopilotRenderedBlock] {
        let mappedEvidence = proseEvidenceMap(evidenceByID)
        func prose(_ value: String) -> AttributedString {
            inline(
                GopilotProseCitationEngine.linkifyReferences(
                    in: value,
                    evidenceByID: mappedEvidence,
                    citationScheme: citationScheme,
                    fileScheme: fileScheme
                )
            )
        }
        return GopilotMarkdownBlock.parse(linkedText).map { block in
            switch block {
            case .heading(let level, let value):
                return .heading(level: level, text: prose(value))
            case .paragraph(let value):
                return .paragraph(prose(value))
            case .list(let items):
                return .list(items.map { item in
                    GopilotRenderedListItem(marker: item.marker, isOrdered: item.isOrdered, indent: item.indent, text: prose(item.text))
                })
            case .code(let language, let code):
                return .code(language: language, code: code)
            case .table(let header, let rows):
                return .table(header: header.map(prose), rows: rows.map { $0.map(prose) })
            case .quote(let value):
                return .quote(prose(value))
            case .rule:
                return .rule
            }
        }
    }

    static func linked(_ text: String, citations: [CitationSegment]?) -> String {
        let mappedSegments: [GopilotProseSegment]? = citations?.map { segment in
            switch segment {
            case .text(let value):
                return .text(value)
            case .citation(let evidence):
                let ref = evidence.sourceRefs.first
                return .citation(
                    GopilotProseEvidenceRef(
                        id: evidence.id,
                        path: ref?.path ?? "",
                        startLine1Based: ref?.range.map { $0.startLine + 1 }
                    )
                )
            case .unverifiedCitation(let token, let reason):
                return .unverified(token: token, isExpired: reason == .expired)
            }
        }
        return GopilotProseCitationEngine.linkedMarkdown(
            text,
            segments: mappedSegments,
            citationScheme: citationScheme
        )
    }

    static func linkifyReferences(
        in rawText: String,
        evidenceByID: [String: Evidence]
    ) -> String {
        GopilotProseCitationEngine.linkifyReferences(
            in: rawText,
            evidenceByID: proseEvidenceMap(evidenceByID),
            citationScheme: citationScheme,
            fileScheme: fileScheme
        )
    }

    static func inline(_ value: String) -> AttributedString {
        let sanitized = stripExternalMedia(value)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: sanitized, options: options) else {
            return AttributedString(sanitized)
        }
        for run in attributed.runs {
            let range = run.range
            if let link = run.link {
                if link.scheme == GopilotAssistantText.citationScheme || link.scheme == GopilotAssistantText.fileScheme {
                    attributed[range].font = Font.body.monospaced()
                    attributed[range].foregroundColor = Color(nsColor: .linkColor)
                } else {
                    attributed[range].link = nil
                }
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[range].font = Font.body.monospaced()
                attributed[range].backgroundColor = Color(nsColor: .quaternarySystemFill)
                attributed[range].foregroundColor = Color(nsColor: .labelColor)
            } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                attributed[range].font = Font.body.weight(.semibold)
                attributed[range].foregroundColor = Color(nsColor: .labelColor)
            }
        }
        return attributed
    }

    private static let markdownImageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]+\)"#)
    private static let markdownRefImageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\s*\[([^\]]*)\]"#)
    private static let htmlMediaRegex = try! NSRegularExpression(pattern: #"(?i)<(img|iframe|video|audio|source|embed|object)\b[^>]*>(\s*</\1>)?|(?i)</(iframe|video|audio|object)>"#)

    static func stripExternalMedia(_ text: String) -> String {
        let ns = text as NSString
        var current = markdownImageRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "[External image blocked]"
        )
        let nsRef = current as NSString
        current = markdownRefImageRegex.stringByReplacingMatches(
            in: current,
            range: NSRange(location: 0, length: nsRef.length),
            withTemplate: "[External image blocked]"
        )
        let nsMedia = current as NSString
        return htmlMediaRegex.stringByReplacingMatches(
            in: current,
            range: NSRange(location: 0, length: nsMedia.length),
            withTemplate: "[External image blocked]"
        )
    }
}

struct GopilotCodeBlockView: View {
    let language: String?
    let code: String
    var fontSize: CGFloat = 13
    @State private var didCopy = false

    private var isMultiLine: Bool {
        code.contains("\n") || (language != nil && !(language ?? "").isEmpty)
    }

    private var headerTitle: String {
        if let language, !language.isEmpty {
            return language
        }
        if code.hasPrefix("go ") || code.hasPrefix("git ") || code.hasPrefix("curl ") || code.hasPrefix("make ") {
            return "shell"
        }
        return "code"
    }

    private var codeFont: Font {
        .system(size: fontSize, design: .monospaced)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
        Group {
            if isMultiLine {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.standard) {
                        Text(headerTitle)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        copyButton
                    }
                    .padding(.leading, Spacing.standard)
                    .padding(.trailing, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)

                    Divider()

                    ScrollView(.horizontal, showsIndicators: true) {
                        HighlightedCodeText(code)
                            .font(codeFont)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(Spacing.standard)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.compact) {
                    HighlightedCodeText(code)
                        .font(codeFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Spacing.standard)
                        .padding(.leading, Spacing.standard)
                    copyButton
                        .padding(.trailing, Spacing.compact)
                        .padding(.top, Spacing.compact)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isMultiLine ? "\(headerTitle) code block" : "Code")
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(minWidth: 20, minHeight: 20)
        .help(didCopy ? "Copied" : "Copy Code")
        .accessibilityLabel(didCopy ? "Copied code" : "Copy code")
    }
}

struct GopilotUserBubble: View {
    @Environment(\.windowWorkspace) private var workspace
    let text: String
    var attachment: String?
    @State private var showsFullPrompt = false

    private var shortTitle: String? {
        GopilotPresetPrompt.shortTitle(for: text)
    }

    private static func extractedRelativePath(from attachment: String) -> String {
        let firstPart = attachment.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? attachment
        let filePart = firstPart.components(separatedBy: " · ").last?.trimmingCharacters(in: .whitespaces) ?? firstPart
        let withoutLines = filePart.components(separatedBy: ":").first ?? filePart
        return withoutLines.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isFolderAttachment(_ attachment: String) -> Bool {
        let firstPart = attachment.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? attachment
        if firstPart.hasSuffix("/") {
            return true
        }
        let base = (extractedRelativePath(from: attachment) as NSString).lastPathComponent
        guard !base.isEmpty else { return false }
        let knownExtensionlessFiles: Set<String> = [
            "makefile", "dockerfile", "gnumakefile", "procfile",
            "jenkinsfile", "license", "caddyfile", "vagrantfile"
        ]
        return (base as NSString).pathExtension.isEmpty
            && !firstPart.contains(" · ")
            && !firstPart.contains(":")
            && !knownExtensionlessFiles.contains(base.lowercased())
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
        VStack(alignment: .trailing, spacing: Spacing.compact) {
            Group {
                if let shortTitle {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        HStack(spacing: Spacing.standard) {
                            Label(shortTitle, systemImage: GopilotPresetPrompt.symbol(for: shortTitle))
                                .font(.body.weight(.medium))
                            Button(showsFullPrompt ? "Hide Prompt" : "Show Prompt") {
                                showsFullPrompt.toggle()
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                        }
                        if showsFullPrompt {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .background(Color(nsColor: .quaternarySystemFill), in: shape)

            if let attachment {
                let isFolder = Self.isFolderAttachment(attachment)
                let relPath = Self.extractedRelativePath(from: attachment)
                let root = workspace.activeWorkspacePath
                let fullPath = (!root.isEmpty && !relPath.isEmpty) ? (root + "/" + relPath) : nil
                HStack(spacing: Spacing.compact) {
                    if attachment == "Project Context Off" {
                        Image(systemName: "folder.badge.minus")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } else {
                        FileIconView(
                            fileName: (relPath as NSString).lastPathComponent,
                            path: fullPath,
                            isFolder: isFolder,
                            isSelected: false,
                            size: FileIconSize.compact
                        )
                    }
                    Text(isFolder && !attachment.contains(",") && !attachment.hasSuffix("/") ? "\(attachment)/" : attachment)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.subheadline)
            }
        }
        .padding(.leading, Spacing.content)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You: \(shortTitle ?? text)" + (attachment.map { ", with context \($0)" } ?? ""))
    }
}

struct GopilotAssistantFooter: View {
    let canSaveNote: Bool
    let usage: String?
    var sourcesUsed: SourcesUsedSummary?
    var openSource: (SourceUsageItem) -> Void = { _ in }
    let saveNote: () -> Void
    @State private var showsDetails = false
    @State private var showsSources = ProcessInfo.processInfo.environment["GOPILOT_EXPAND_SOURCES"] == "1"

    private var hasSources: Bool {
        guard let sourcesUsed else { return false }
        return !sourcesUsed.isEmpty
    }

    private var collidingBaseNames: Set<String> {
        guard let sourcesUsed else { return [] }
        var pathsByBase: [String: Set<String>] = [:]
        for item in sourcesUsed.all {
            pathsByBase[(item.path as NSString).lastPathComponent, default: []].insert(item.path)
        }
        return Set(pathsByBase.filter { $0.value.count > 1 }.keys)
    }

    var body: some View {
        if canSaveNote || usage != nil || hasSources {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                GopilotFlowLayout(spacing: Spacing.comfortable, lineSpacing: 2) {
                    if let sourcesUsed, !sourcesUsed.isEmpty {
                        Button {
                            showsSources.toggle()
                        } label: {
                            Label("Sources Used (\(sourcesUsed.totalCount))", systemImage: showsSources ? "chevron.down" : "chevron.right")
                        }
                        .help(showsSources ? "Hide the files and symbols used for this answer" : "Show the files and symbols used for this answer")
                    }
                    if canSaveNote {
                        Button(action: saveNote) {
                            Label("Save Note", systemImage: "pin")
                        }
                        .help("Save this answer as a note for this project")
                    }
                    if usage != nil {
                        Button {
                            showsDetails.toggle()
                        } label: {
                            Label("Details", systemImage: showsDetails ? "chevron.down" : "chevron.right")
                        }
                        .help("Show model, request, and token usage for this answer")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)

                if showsSources, let sourcesUsed {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        sourceCategoryGroup(title: "Attached", items: sourcesUsed.attached)
                        sourceCategoryGroup(title: "Looked up", items: sourcesUsed.lookedUp)
                        sourceCategoryGroup(title: "Cited", items: sourcesUsed.cited)
                    }
                    .padding(.leading, Spacing.compact)
                }
                if showsDetails, let usage {
                    Text(usage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceCategoryGroup(title: String, items: [SourceUsageItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                GopilotFlowLayout(spacing: Spacing.standard, lineSpacing: 2) {
                    ForEach(items) { item in
                        GopilotSourceUsageLink(
                            item: item,
                            disambiguateFolder: collidingBaseNames.contains((item.path as NSString).lastPathComponent)
                        ) {
                            openSource(item)
                        }
                    }
                }
            }
        }
    }
}

private struct GopilotSourceUsageLink: View {
    @Environment(\.windowWorkspace) private var workspace
    let item: SourceUsageItem
    var disambiguateFolder: Bool = false
    let action: () -> Void

    private var displayLabel: String {
        guard disambiguateFolder, item.path.contains("/") else {
            return item.label
        }
        let comps = item.path.split(separator: "/")
        let prefix = comps.count >= 2 ? "\(comps[comps.count - 2])/\(comps[comps.count - 1])" : item.path
        if let symbolName = item.symbolName, !symbolName.isEmpty {
            return "\(symbolName) (\(prefix))"
        }
        if let s = item.startLine, let e = item.endLine, s > 0 {
            return s == e ? "\(prefix):\(s)" : "\(prefix):\(s)–\(e)"
        }
        return prefix
    }

    private var fullPath: String? {
        let root = workspace.activeWorkspacePath
        guard !root.isEmpty else { return nil }
        return root + "/" + item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.compact) {
                FileIconView(
                    fileName: (item.path as NSString).lastPathComponent,
                    path: fullPath,
                    isFolder: item.path.hasSuffix("/"),
                    isSelected: false,
                    size: FileIconSize.compact
                )
                Text(displayLabel)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isUnsaved {
                    Text("Unsaved")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(item.path)")
        .accessibilityLabel("Open \(displayLabel)" + (item.isUnsaved ? ", unsaved" : ""))
    }
}

struct GopilotFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct GopilotLiveThinkingRow: View {
    let text: String

    private var singleLinePreview: String {
        let lines = GopilotCitationNormalizer.stripUnresolvedTokens(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let latest = lines.last else { return "" }
        return latest
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    var body: some View {
        let preview = singleLinePreview
        if !preview.isEmpty {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thinking: \(preview)")
        }
    }
}

struct GopilotActivityStep: Identifiable, Equatable {
    enum Kind {
        case fileChange
        case command
        case lookup
        case narration
    }

    let id: String
    let label: String
    let status: GopilotTranscriptItem.ActivityStatus
    var isNarration = false

    var kind: Kind {
        if isNarration {
            return .narration
        }
        let fileChangePrefixes = ["Writing ", "Editing ", "Writing file", "Editing file", "Preparing a proposed change", "Saving project memory"]
        if fileChangePrefixes.contains(where: { label.hasPrefix($0) }) {
            return .fileChange
        }
        let commandPrefixes = ["Running ", "Run "]
        if commandPrefixes.contains(where: { label.hasPrefix($0) }) {
            return .command
        }
        return .lookup
    }

    var isPlanUpdate: Bool { label == "Updating task plan" }

    var symbolName: String {
        switch kind {
        case .fileChange: "pencil"
        case .command: "terminal"
        case .lookup: "doc.text.magnifyingglass"
        case .narration: "text.bubble"
        }
    }
}

struct GopilotStepStatusView: View {
    let status: GopilotTranscriptItem.ActivityStatus
    var isAwaitingPermission = false
    var didNotFinish = false

    var body: some View {
        Group {
            if isAwaitingPermission {
                Label("Waiting for you", systemImage: "hand.raised.fill")
                    .foregroundStyle(StatusTone.warning.tint)
            } else if didNotFinish {
                Label("Did not finish", systemImage: StatusTone.inactive.symbol)
                    .foregroundStyle(.secondary)
            } else {
                switch status {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("In progress")
                case .finished:
                    Label("Done", systemImage: StatusTone.success.symbol)
                        .foregroundStyle(StatusTone.success.tint)
                case .failed:
                    Label("Failed", systemImage: StatusTone.failure.symbol)
                        .foregroundStyle(StatusTone.failure.tint)
                }
            }
        }
        .font(.subheadline)
        .labelStyle(GopilotStatusLabelStyle())
        .fixedSize()
    }
}

private struct GopilotStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.compact) {
            configuration.icon
            configuration.title
        }
    }
}

struct GopilotRunSection: View {
    let steps: [GopilotActivityStep]
    let todos: [GopilotTodoItem]
    let isLive: Bool
    let isAwaitingPermission: Bool
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleSteps: [GopilotActivityStep] {
        steps.filter { !$0.isPlanUpdate }
    }

    private var impactSteps: [GopilotActivityStep] {
        visibleSteps.filter { $0.kind == .fileChange || $0.kind == .command }
    }

    private var toolSteps: [GopilotActivityStep] {
        visibleSteps.filter { $0.kind != .narration }
    }

    private var runningStep: GopilotActivityStep? {
        toolSteps.last { $0.status == .running }
    }

    private var awaitingStepID: String? {
        guard isAwaitingPermission else { return nil }
        return toolSteps.last { $0.status == .running && $0.kind == .command }?.id
    }

    private var failureCount: Int {
        toolSteps.filter { $0.status == .failed }.count
    }

    private var completedTodos: Int {
        todos.filter { $0.status == .completed }.count
    }

    private var summaryText: String {
        if isAwaitingPermission {
            return "Waiting for your permission"
        }
        var parts: [String] = []
        if let runningStep, isLive {
            parts.append(runningStep.label)
            if !todos.isEmpty {
                parts.append("Step \(min(completedTodos + 1, todos.count)) of \(todos.count)")
            }
            return parts.joined(separator: " · ")
        }
        if !todos.isEmpty {
            parts.append("Plan \(completedTodos)/\(todos.count)")
        }
        let lookups = toolSteps.filter { $0.kind == .lookup }
        let reads = lookups.filter { $0.label.hasPrefix("Reading ") && $0.label != "Reading project overview" }.count
        let others = lookups.count - reads
        if reads > 0 {
            parts.append("Read \(reads) file\(reads == 1 ? "" : "s")")
        }
        if others > 0 {
            parts.append("\(others) lookup\(others == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Steps" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Spacing.row) {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    summaryIcon
                        .frame(width: 16)
                    Text(summaryText)
                        .font(.callout)
                        .foregroundStyle(isAwaitingPermission ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if failureCount > 0 {
                        Text("\(failureCount) failed")
                            .font(.callout)
                            .foregroundStyle(StatusTone.failure.tint)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide plan and steps" : "Show plan and steps")
            .accessibilityLabel("Run: \(summaryText)" + (failureCount > 0 ? ", \(failureCount) failed" : ""))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the plan and every step")

            if !impactSteps.isEmpty && !isExpanded {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(impactSteps) { step in
                        stepRow(step)
                    }
                }
                .padding(.leading, Spacing.section)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    if !todos.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text("Plan")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(todos) { item in
                                todoRow(item)
                            }
                        }
                    }
                    if !visibleSteps.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text("Steps")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(visibleSteps) { step in
                                stepRow(step)
                            }
                        }
                    }
                }
                .padding(.leading, Spacing.section)
                .padding(.top, Spacing.hairline)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var summaryIcon: some View {
        if isAwaitingPermission {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(StatusTone.warning.tint)
                .accessibilityHidden(true)
        } else if runningStep != nil && isLive {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        } else if failureCount > 0 {
            Image(systemName: StatusTone.failure.symbol)
                .foregroundStyle(StatusTone.failure.tint)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func stepRow(_ step: GopilotActivityStep) -> some View {
        if step.kind == .narration {
            narrationRow(step)
        } else {
            toolStepRow(step)
        }
    }

    private func narrationRow(_ step: GopilotActivityStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Image(systemName: step.symbolName)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(GopilotAssistantText.inline(GopilotCitationNormalizer.stripUnresolvedTokens(step.label)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func toolStepRow(_ step: GopilotActivityStep) -> some View {
        let awaiting = step.id == awaitingStepID
        let didNotFinish = !isLive && step.status == .running
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Image(systemName: step.symbolName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(step.label)
                .font(.callout)
                .foregroundStyle(step.kind == .lookup ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            GopilotStepStatusView(status: step.status, isAwaitingPermission: awaiting, didNotFinish: didNotFinish)
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.label), \(didNotFinish ? "did not finish" : Self.statusText(step.status, awaiting: awaiting))")
    }

    private func todoRow(_ item: GopilotTodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Image(systemName: Self.todoSymbol(item.status))
                .font(.subheadline)
                .foregroundStyle(Self.todoColor(item.status))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(item.content)
                .font(.callout)
                .foregroundStyle(item.status == .pending ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.content), \(Self.todoStatusText(item.status))")
    }

    static func statusText(_ status: GopilotTranscriptItem.ActivityStatus, awaiting: Bool) -> String {
        if awaiting { return "waiting for your permission" }
        switch status {
        case .running: return "in progress"
        case .finished: return "done"
        case .failed: return "failed"
        }
    }

    private static func todoSymbol(_ status: GopilotTodoItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending: "circle"
        }
    }

    private static func todoColor(_ status: GopilotTodoItem.Status) -> Color {
        switch status {
        case .completed: StatusTone.success.tint
        case .inProgress: Color(nsColor: .controlAccentColor)
        case .pending: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private static func todoStatusText(_ status: GopilotTodoItem.Status) -> String {
        switch status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: "not started"
        }
    }
}

struct GopilotNoticeRow: View {
    let kind: GopilotTranscriptItem.NoticeKind
    let text: String
    let canRetry: Bool
    var isAgentMode = false
    let retry: () -> Void
    let openSettings: () -> Void
    var trust: () -> Void = {}
    var continueFindings: () -> Void = {}
    var narrowQuestion: () -> Void = {}
    var retryDefaultEffort: () -> Void = {}
    var verifyRoute: (String) -> Void = { _ in }
    var newConversation: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(kind == .info ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasActions {
                GopilotFlowLayout(spacing: Spacing.standard, lineSpacing: 4) {
                    if kind == .authentication {
                        Button("Open Settings", action: openSettings)
                    }
                    if kind == .trust {
                        Button("Trust This Project", action: trust)
                    }
                    if case .budgetExceeded(let hasFindings) = kind {
                        if hasFindings {
                            Button(isAgentMode ? "Continue" : "Continue from Findings", action: continueFindings)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Ask Narrower Question", action: narrowQuestion)
                    }
                    if case .unsupportedEffort = kind {
                        Button("Retry with Model Default", action: retryDefaultEffort)
                            .buttonStyle(.borderedProminent)
                    }
                    if case .untestedAgentRoute(let routeID) = kind {
                        Button("Check This Model") { verifyRoute(routeID) }
                            .buttonStyle(.borderedProminent)
                        Button("Open Settings", action: openSettings)
                    }
                    if kind == .requestRejected {
                        Button("New Conversation", action: newConversation)
                    }
                    if canRetry {
                        Button("Retry", action: retry)
                    }
                }
                .controlSize(.small)
                .padding(.leading, Spacing.content)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kindName): \(text)")
    }

    private var hasActions: Bool {
        switch kind {
        case .authentication, .requestRejected, .trust, .budgetExceeded, .unsupportedEffort, .untestedAgentRoute:
            return true
        case .info, .warning, .error:
            return canRetry
        }
    }

    private var kindName: String {
        switch kind {
        case .info: "Note"
        case .warning, .budgetExceeded, .unsupportedEffort, .untestedAgentRoute: "Warning"
        case .error, .authentication, .requestRejected: "Error"
        case .trust: "Permission needed"
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .warning, .budgetExceeded, .unsupportedEffort, .untestedAgentRoute: "exclamationmark.triangle.fill"
        case .error, .authentication, .requestRejected: StatusTone.failure.symbol
        case .trust: "lock.shield"
        }
    }

    private var symbolColor: Color {
        switch kind {
        case .info, .trust: .secondary
        case .warning, .budgetExceeded, .unsupportedEffort, .untestedAgentRoute: StatusTone.warning.tint
        case .error, .authentication, .requestRejected: StatusTone.failure.tint
        }
    }
}
