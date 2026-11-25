import SwiftUI

struct QuickDocumentationPopoverView: View {
    let request: QuickDocumentationRequest
    @Environment(\.windowWorkspace) private var workspace

    static let documentationWidth = PopupWidth.hover.rawValue
    static let definitionWidth = PopupWidth.medium.rawValue

    static func origin(for request: QuickDocumentationRequest?, in width: CGFloat) -> CGPoint {
        guard let request else { return .zero }
        let x: CGFloat
        let panelWidth = request.kind == .definition ? definitionWidth : documentationWidth
        switch request.phase {
        case .loaded, .definition:
            x = request.anchor.midX - panelWidth / 2
        default:
            x = request.anchor.minX - 8
        }
        return CGPoint(x: max(10, min(width - panelWidth - 10, x)), y: request.anchor.maxY + 8)
    }

    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        Group {
            switch request.phase {
            case .loaded(let text):
                let content = parseHoverText(text)
                let signature = content.signature.map { highlightGoCode($0, isDark: isDark) }
                let editor = request.editor
                let filePath = editor?.filePath ?? workspace.activeFilePath
                let symbolIdx = request.symbolIndex
                HoverPopoverContentView(
                    content: content,
                    workspace: workspace,
                    isDark: isDark,
                    highlightedSigDark: isDark ? signature : nil,
                    highlightedSigLight: isDark ? nil : signature,
                    onOpenSource: symbolIdx != nil ? { editor?.openQuickDocumentationSource() } : nil,
                    onOpenDocumentation: {
                        if let editor {
                            editor.dismissHoverImmediate()
                        } else {
                            workspace.lsp.quickDocumentation = nil
                        }
                        DocumentationService.shared.openFromHover(
                            workspace: workspace,
                            rawMarkdown: text,
                            signature: content.signature,
                            filePath: filePath,
                            symbolIndex: symbolIdx
                        )
                    }
                )
                .frame(width: Self.documentationWidth)
            case .definition(let target):
                definition(target, isDark: isDark)
            case .loading:
                status {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(isDefinition ? "Loading definition…" : "Loading documentation…")
                        .foregroundStyle(ThemeColor.textSecondary)
                }
            case .noSymbol:
                status {
                    Image(systemName: "text.cursor")
                        .foregroundStyle(ThemeColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(isDefinition ? "Place the cursor on a Go symbol to view its definition." : "Place the cursor on a Go symbol to view its documentation.")
                        .foregroundStyle(ThemeColor.textSecondary)
                }
            case .unresolved:
                status {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(ThemeColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(isDefinition ? "GoLens couldn’t find the definition of this symbol in the current project." : "GoLens couldn’t resolve this symbol in the current project.")
                        .foregroundStyle(ThemeColor.textPrimary)
                    Button("Retry") { request.editor?.retryQuickDocumentation() }
                        .controlSize(.small)
                        .help(isDefinition ? "Look up the definition again" : "Look up the documentation again")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
        .floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)
    }

    private var isDefinition: Bool { request.kind == .definition }

    private func definition(_ target: QuickDefinitionTarget, isDark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.title)
                .font(.caption)
                .foregroundStyle(ThemeColor.textSecondary)
                .help(target.path)
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(highlightGoCode(target.snippet.code, isDark: isDark))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(Spacing.comfortable)
                    .frame(minWidth: Self.definitionWidth, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: HoverPopoverContentView.bodyMaxHeight)
            Divider()
            HStack(spacing: Spacing.comfortable) {
                if target.snippet.truncated {
                    Text("Showing the first \(target.snippet.code.components(separatedBy: "\n").count) lines. Open Source shows the rest.")
                        .font(.caption)
                        .foregroundStyle(ThemeColor.textSecondary)
                }
                Spacer(minLength: 0)
                PopoverLinkButton(title: "Open Source", symbol: "chevron.left.forwardslash.chevron.right", help: "Open the definition in the editor (Return)") {
                    request.editor?.openQuickDocumentationSource()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
        }
        .frame(width: Self.definitionWidth)
    }

    private func status<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.standard) {
            content()
        }
        .font(.callout)
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
        .fixedSize()
    }
}
