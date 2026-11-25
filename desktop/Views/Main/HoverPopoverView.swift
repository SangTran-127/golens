import SwiftUI
import AppKit

struct HoverPopoverView: View {
    let text: String
    @Environment(\.windowWorkspace) private var workspace
    
    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        let content = parseHoverText(text)
        let signature = content.signature.map { highlightGoCode($0, isDark: isDark) }

        let canOpenSource = content.signature != nil
            && workspace.lsp.hoveredWordRange.location != NSNotFound
            && workspace.lsp.hoveredFilePath.hasSuffix(".go")
        let canOpenDocs = !content.rawText.isEmpty && (content.signature != nil || content.pkgGoDevURL != nil || canOpenSource)
        let hoverFile = workspace.lsp.hoveredFilePath
        let hoverIdx = workspace.lsp.hoveredWordRange.location
        let rawMD = content.rawText
        let sig = content.signature

        HoverPopoverContentView(
            content: content,
            workspace: workspace,
            isDark: isDark,
            highlightedSigDark: isDark ? signature : nil,
            highlightedSigLight: isDark ? nil : signature,
            onOpenSource: canOpenSource ? {
                let targetIdx = workspace.lsp.hoveredWordRange.location
                workspace.lsp.isMouseInsideHoverPopover = false
                workspace.lsp.hoverText = nil
                (workspace.activeTextView as? GoLensTextView)?.goToDefinition(at: targetIdx)
            } : nil,
            onOpenDocumentation: canOpenDocs ? {
                workspace.lsp.isMouseInsideHoverPopover = false
                workspace.lsp.hoverText = nil
                DocumentationService.shared.openFromHover(
                    workspace: workspace,
                    rawMarkdown: rawMD,
                    signature: sig,
                    filePath: hoverFile,
                    symbolIndex: hoverIdx == NSNotFound ? nil : hoverIdx
                )
            } : nil
        )
        .popupWidth(.hover)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
        .floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)
        .onHover { hovering in
            workspace.lsp.isMouseInsideHoverPopover = hovering
            if !hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !workspace.lsp.isMouseInsideHoverPopover,
                       ((workspace.activeTextView as? GoLensTextView)?.isMouseStillOverHoveredTokenOrPopup() ?? false) == false {
                        workspace.lsp.hoverText = nil
                    }
                }
            }
        }
        .onDisappear {
            workspace.lsp.isMouseInsideHoverPopover = false
        }
    }
}

struct PopoverLinkButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.row) {
                Image(systemName: symbol)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(ThemeColor.accent)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HoverPopoverContentView: View {
    let content: HoverContent
    @Bindable var workspace: WorkspaceState
    let isDark: Bool
    let highlightedSigDark: AttributedString?
    let highlightedSigLight: AttributedString?
    var onOpenSource: (() -> Void)? = nil
    var onOpenDocumentation: (() -> Void)? = nil

    @Environment(\.popupAvailableHeight) private var maxHeight
    static let bodyMaxHeight: CGFloat = 360

    private func inlineMarkdownText(_ raw: String) -> Text {
        if let attrStr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attrStr)
        }
        return Text(raw)
    }

    private func diagnosticSourceLabel(for message: String) -> String? {
        let path = workspace.lsp.hoveredFilePath
        guard !path.isEmpty else { return nil }
        return workspace.diagnosticsForPath(path).first { $0.sourceLabel != nil && $0.message.trimmingCharacters(in: .whitespacesAndNewlines) == message }?.sourceLabel
    }

    var body: some View {
        let hasDiagnostic = content.severity != nil && content.diagnosticMessage != nil
        let hasSignature = content.signature != nil
        let docBlocks = parseHoverDocBlocks(content.documentation)
        let hasDocumentation = !docBlocks.isEmpty
        let hasActions = !content.actions.isEmpty
        let hasPkgLink = content.pkgGoDevURL != nil
        let hasFooter = hasActions || hasPkgLink || hasDiagnostic || onOpenSource != nil || onOpenDocumentation != nil
        
        let badgeColor: Color
        let badgeTitle: String
        let badgeIcon: String
        
        if let severity = content.severity {
            switch severity {
            case 1:
                badgeColor = StatusTone.failure.tint
                badgeTitle = "Error"
                badgeIcon = StatusTone.failure.symbol
            case 2:
                badgeColor = StatusTone.warning.tint
                badgeTitle = "Warning"
                badgeIcon = StatusTone.warning.symbol
            case 3:
                badgeColor = Color(nsColor: .secondaryLabelColor)
                badgeTitle = "Info"
                badgeIcon = "info.circle.fill"
            default:
                badgeColor = Color(nsColor: .secondaryLabelColor)
                badgeTitle = "Hint"
                badgeIcon = "lightbulb.fill"
            }
        } else {
            badgeColor = Color(nsColor: .secondaryLabelColor)
            badgeTitle = "Hint"
            badgeIcon = "lightbulb.fill"
        }
        
        let primaryText = ThemeColor.textPrimary
        let secondaryText = ThemeColor.textSecondary
        let accentText = ThemeColor.accent

        let showsMissingDocumentation = onOpenSource != nil && hasSignature && !hasDocumentation

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if content.severity != nil, let diagMsg = content.diagnosticMessage {
                        VStack(alignment: .leading, spacing: Spacing.standard) {
                            HStack(spacing: Spacing.row) {
                                Image(systemName: badgeIcon)
                                    .foregroundStyle(badgeColor)
                                    .font(.caption.weight(.bold))
                                    .accessibilityHidden(true)
                                Text(badgeTitle.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(badgeColor)
                                    .tracking(0.5)
                            }

                            Text(diagMsg)
                                .font(.callout)
                                .foregroundStyle(primaryText)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                            if let label = diagnosticSourceLabel(for: diagMsg) {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(secondaryText)
                            }
                        }
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.vertical, Spacing.comfortable)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(badgeColor.opacity(isDark ? 0.12 : 0.06))

                        if hasSignature || hasDocumentation {
                            Divider()
                        }
                    }

                    if let sig = content.signature {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("DECLARATION")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(secondaryText)
                                .tracking(0.5)
                                .padding(.bottom, Spacing.hairline)

                            if let attrSig = isDark ? highlightedSigDark : highlightedSigLight {
                                Text(attrSig)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            } else {
                                Text(sig)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.vertical, Spacing.comfortable)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if hasDocumentation || showsMissingDocumentation {
                            Divider()
                        }
                    }

                    if showsMissingDocumentation {
                        Text("No documentation comment is available for this symbol.")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Spacing.comfortable)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if hasDocumentation {
                        VStack(alignment: .leading, spacing: Spacing.standard) {
                            if hasSignature || hasDiagnostic {
                                Text("DOCUMENTATION")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(secondaryText)
                                    .tracking(0.5)
                                    .padding(.bottom, Spacing.hairline)
                            }

                            ForEach(docBlocks) { block in
                                switch block {
                                case .heading(_, let level, let headingText):
                                    inlineMarkdownText(headingText)
                                        .font(level <= 2 ? .subheadline.weight(.semibold) : .callout.weight(.semibold))
                                        .foregroundStyle(primaryText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, Spacing.hairline)

                                case .bullet(_, let bulletText):
                                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                                        Text("•")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(secondaryText)
                                        inlineMarkdownText(bulletText)
                                            .font(.caption)
                                            .foregroundStyle(primaryText.opacity(0.9))
                                            .lineSpacing(2)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }

                                case .codeBlock(_, let code):
                                    Text(highlightGoCode(code, isDark: isDark))
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .padding(Spacing.standard)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                                                .fill(ThemeColor.editorSurface)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                                                .strokeBorder(ThemeColor.separator, lineWidth: Stroke.standard)
                                        )

                                case .paragraph(_, let paraText):
                                    inlineMarkdownText(paraText)
                                        .font(.caption)
                                        .foregroundStyle(primaryText.opacity(0.88))
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(Spacing.comfortable)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.bodyMaxHeight)
            
            if hasFooter {
                Divider()
                
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    if let upgradableMod = content.upgradableModule {
                        Button(action: {
                            workspace.lsp.isMouseInsideHoverPopover = false
                            workspace.lsp.hoverText = nil
                            workspace.upgradeModuleDependency("\(upgradableMod)@latest")
                        }) {
                            HStack(spacing: Spacing.row) {
                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.caption)
                                    .accessibilityHidden(true)
                                Text("Upgrade \(upgradableMod) to latest")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(accentText)
                        }
                        .buttonStyle(.plain)
                        .help("Run go get \(upgradableMod)@latest and go mod tidy")
                    }

                    ForEach(content.actions) { action in
                        Button(action: {
                            workspace.lsp.isMouseInsideHoverPopover = false
                            workspace.lsp.hoverText = nil
                            workspace.jumpTo(filePath: action.filePath, line: action.line, column: action.column)
                        }) {
                            HStack(spacing: Spacing.row) {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                                    .accessibilityHidden(true)
                                Text(action.title)
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(accentText)
                        }
                        .buttonStyle(.plain)
                        .help(action.title)
                    }
                    
                    GopilotFlowLayout(spacing: Spacing.comfortable, lineSpacing: Spacing.compact) {
                        if let onOpenSource {
                            PopoverLinkButton(title: "Open Source", symbol: "chevron.left.forwardslash.chevron.right", help: "Go to the declaration of this symbol", action: onOpenSource)
                        }

                        if let onOpenDocumentation {
                            PopoverLinkButton(title: "Open in Documentation Browser", symbol: "book", help: "Open this package or symbol in Documentation Browser", action: onOpenDocumentation)
                        }

                        if hasDiagnostic {
                            Button(action: {
                                if let editor = workspace.lsp.hoveredEditor ?? workspace.activeTextView as? GoLensTextView {
                                    editor.showCodeActionsForHover()
                                } else {
                                    workspace.presentCommandFeedback(
                                        "Open the file in the editor to view quick fixes.",
                                        title: "Code Actions"
                                    )
                                }
                            }) {
                                HStack(spacing: Spacing.compact) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.caption)
                                        .accessibilityHidden(true)
                                    Text("More Actions…")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(accentText)
                            }
                            .buttonStyle(.plain)
                            .help("Show quick fixes and code actions for this issue")
                        }

                        if let pkgLink = content.pkgGoDevURL {
                            Link(destination: pkgLink.url) {
                                HStack(spacing: Spacing.row) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(accentText)
                                        .accessibilityHidden(true)
                                    Text("'\(pkgLink.label)' on pkg.go.dev »")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(accentText)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: maxHeight)
    }
}
