import SwiftUI
import AppKit

struct MarkdownBlockRendererView: View {
    let block: MarkdownBlock
    let filePath: String
    let baseDirectory: String
    let isDark: Bool
    let primaryText: Color
    let secondaryText: Color
    @Bindable var workspace: WorkspaceState
    let onSelectAnchor: (String) -> Void
    let onToggleTaskLine: (Int) -> Void

    var body: some View {
        switch block {
        case .heading(_, let level, let text, _):
            headingView(level: level, text: text)

        case .paragraph(_, let text):
            MarkdownInlineTextView(
                rawMarkdown: text,
                font: .body,
                foregroundColor: primaryText
            )
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .codeBlock(_, let language, let code):
            MarkdownCodeBlockView(
                language: language,
                code: code,
                isDark: isDark,
                workspace: workspace
            )

        case .mermaid(_, let code):
            MermaidDiagramBlockView(
                code: code,
                isDark: isDark,
                workspace: workspace
            )

        case .alert(_, let kind, let bodyBlocks):
            alertView(kind: kind, bodyBlocks: bodyBlocks)

        case .blockquote(_, let bodyBlocks):
            blockquoteView(bodyBlocks: bodyBlocks)

        case .table(_, let headers, let alignments, let rows):
            tableView(headers: headers, alignments: alignments, rows: rows)

        case .list(_, let items):
            listView(items: items)

        case .image(_, let alt, let path):
            MarkdownImageBlockView(
                alt: alt,
                imagePath: path,
                baseDirectory: baseDirectory,
                secondaryText: secondaryText
            )

        case .thematicBreak:
            Divider()
                .padding(.vertical, Spacing.row)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            MarkdownInlineTextView(
                rawMarkdown: text,
                font: headingFont(for: level),
                foregroundColor: level >= 5 ? secondaryText : primaryText
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if level <= 2 {
                Divider()
            }
        }
        .padding(.top, level == 1 ? Spacing.standard : (level == 2 ? Spacing.row : Spacing.compact))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 24, weight: .bold)
        case 2:
            return .system(size: 20, weight: .bold)
        case 3:
            return .system(size: 16, weight: .semibold)
        case 4:
            return .system(size: 14, weight: .semibold)
        default:
            return .body.weight(.medium)
        }
    }

    @ViewBuilder
    private func alertView(kind: GFMAlertKind, bodyBlocks: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(kind.tintColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack(spacing: Spacing.row) {
                    Image(systemName: kind.symbolName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(kind.tintColor)
                        .accessibilityHidden(true)
                    Text(kind.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(kind.tintColor)
                }

                ForEach(bodyBlocks) { innerBlock in
                    MarkdownBlockRendererView(
                        block: innerBlock,
                        filePath: filePath,
                        baseDirectory: baseDirectory,
                        isDark: isDark,
                        primaryText: primaryText,
                        secondaryText: secondaryText,
                        workspace: workspace,
                        onSelectAnchor: onSelectAnchor,
                        onToggleTaskLine: onToggleTaskLine
                    )
                }
            }
            .padding(Spacing.comfortable)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                .fill(kind.tintColor.opacity(isDark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                .strokeBorder(kind.tintColor.opacity(0.35), lineWidth: Stroke.standard)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
    }

    @ViewBuilder
    private func blockquoteView(bodyBlocks: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: Spacing.comfortable) {
            Capsule()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: Spacing.standard) {
                ForEach(bodyBlocks) { innerBlock in
                    MarkdownBlockRendererView(
                        block: innerBlock,
                        filePath: filePath,
                        baseDirectory: baseDirectory,
                        isDark: isDark,
                        primaryText: secondaryText,
                        secondaryText: secondaryText,
                        workspace: workspace,
                        onSelectAnchor: onSelectAnchor,
                        onToggleTaskLine: onToggleTaskLine
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.hairline)
    }

    @ViewBuilder
    private func tableView(headers: [String], alignments: [GFMTableAlignment], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { colIdx in
                        let align = colIdx < alignments.count ? alignments[colIdx] : .leading
                        MarkdownInlineTextView(
                            rawMarkdown: headers[colIdx],
                            font: .callout.weight(.semibold),
                            foregroundColor: primaryText
                        )
                        .multilineTextAlignment(align.textAlignment)
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.vertical, Spacing.standard)
                        .frame(maxWidth: .infinity, alignment: align.frameAlignment)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            Rectangle()
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
                        )
                    }
                }

                ForEach(rows.indices, id: \.self) { rowIdx in
                    let row = rows[rowIdx]
                    GridRow {
                        ForEach(headers.indices, id: \.self) { colIdx in
                            let align = colIdx < alignments.count ? alignments[colIdx] : .leading
                            let cellText = colIdx < row.count ? row[colIdx] : ""
                            MarkdownInlineTextView(
                                rawMarkdown: cellText,
                                font: .callout,
                                foregroundColor: primaryText
                            )
                            .multilineTextAlignment(align.textAlignment)
                            .padding(.horizontal, Spacing.comfortable)
                            .padding(.vertical, Spacing.row)
                            .frame(maxWidth: .infinity, alignment: align.frameAlignment)
                            .background(
                                rowIdx.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color(nsColor: .controlBackgroundColor).opacity(0.45)
                            )
                            .overlay(
                                Rectangle()
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
            )
        }
    }

    @ViewBuilder
    private func listView(items: [GFMListItem]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                    if let isChecked = item.taskState {
                        Button {
                            onToggleTaskLine(item.sourceLineIndex)
                        } label: {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .font(.callout)
                                .foregroundStyle(isChecked ? Color.accentColor : secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isChecked ? "Completed task: \(item.text)" : "Incomplete task: \(item.text)")
                        .help("Toggle task item in Markdown source")
                    } else if item.isOrdered {
                        Text("\(item.orderNumber).")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(secondaryText)
                    } else {
                        Text(item.indentLevel == 0 ? "•" : (item.indentLevel == 1 ? "◦" : "▪"))
                            .font(.callout.weight(.bold))
                            .foregroundStyle(secondaryText)
                    }

                    MarkdownInlineTextView(
                        rawMarkdown: item.text,
                        font: .body,
                        foregroundColor: (item.taskState == true) ? secondaryText : primaryText
                    )
                    .strikethrough(item.taskState == true, color: secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.indentLevel) * 18)
            }
        }
    }
}

private struct MarkdownInlineTextView: View {
    let rawMarkdown: String
    let font: Font
    let foregroundColor: Color

    var body: some View {
        Text(buildAttributedString())
            .font(font)
            .foregroundStyle(foregroundColor)
            .textSelection(.enabled)
    }

    private func buildAttributedString() -> AttributedString {
        let rewritten = Self.rewriteLinksForGoLensHandler(rawMarkdown)
        guard var attr = try? AttributedString(
            markdown: rewritten,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(rawMarkdown)
        }

        for run in attr.runs {
            let range = run.range
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[range].font = .callout.monospaced()
                attr[range].backgroundColor = NSColor.quaternaryLabelColor
            }
            if run.link != nil {
                attr[range].foregroundColor = NSColor.controlAccentColor
                attr[range].underlineStyle = .single
            }
        }
        return attr
    }

    private static func rewriteLinksForGoLensHandler(_ raw: String) -> String {
        guard raw.contains("[") && raw.contains("](") else { return raw }
        guard let regex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)]+)\)"#) else {
            return raw
        }
        let nsString = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return raw }

        let mutable = NSMutableString(string: raw)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let label = nsString.substring(with: match.range(at: 1))
            var target = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if let spaceQuote = target.range(of: " \"") {
                target = String(target[..<spaceQuote.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
            let replacement = "[\(label)](golens-md-link://open?target=\(encoded))"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String
    let code: String
    let isDark: Bool
    @Bindable var workspace: WorkspaceState
    @State private var didCopy = false

    private var displayLanguage: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "text" : trimmed.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.standard) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "curlybraces")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                    Text(displayLanguage.uppercased())
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        didCopy = false
                    }
                } label: {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(didCopy ? "Copied" : "Copy")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(didCopy ? StatusTone.success.tint : Color.secondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Copied code block" : "Copy code block")
                .help("Copy code block to clipboard")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                Group {
                    if displayLanguage == "go" || displayLanguage == "golang" {
                        Text(highlightGoCode(code, isDark: isDark))
                    } else {
                        Text(code)
                            .foregroundStyle(ThemeColor.textPrimary)
                    }
                }
                .font(.callout.monospaced())
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(Spacing.comfortable)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ThemeColor.panelSurface.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
        )
    }
}

private struct MarkdownImageBlockView: View {
    let alt: String
    let imagePath: String
    let baseDirectory: String
    let secondaryText: Color

    private var resolvedFilePath: String {
        let decoded = imagePath.removingPercentEncoding ?? imagePath
        if decoded.hasPrefix("file://"), let url = URL(string: decoded) {
            return url.path
        }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardized.path
        }
        return URL(fileURLWithPath: baseDirectory)
            .appendingPathComponent(decoded)
            .standardized
            .path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            if let nsImage = NSImage(contentsOfFile: resolvedFilePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
                    )
                    .accessibilityLabel(alt.isEmpty ? (resolvedFilePath as NSString).lastPathComponent : alt)
            } else {
                HStack(spacing: Spacing.standard) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(alt.isEmpty ? "Image not found" : alt)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Text(imagePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(secondaryText)
                    }
                }
                .padding(Spacing.inset)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
                )
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
        }
    }
}
