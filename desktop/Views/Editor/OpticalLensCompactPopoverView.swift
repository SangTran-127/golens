import AppKit
import SwiftUI

struct OpticalLensCompactPopoverView: View {
    let item: OpticalLensLineItem
    let anchorRect: NSRect
    weak var textView: GoLensTextView?
    let onDismiss: () -> Void

    private var workspace: WorkspaceState { textView?.workspaceState ?? WorkspaceState.shared }

    private var fontSize: CGFloat {
        workspace.editorFontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.row) {
                Text("Line \(item.lineNumber)")
                    .font(TechnicalTypography.metricMono.weight(.semibold))
                    .foregroundStyle(ChromeColor.textSecondary)
                Spacer(minLength: Spacing.standard)
                Text(item.mode.rawValue.capitalized)
                    .font(TechnicalTypography.badgeMicro)
                    .foregroundStyle(ChromeColor.textTertiary)
            }

            if !item.issues.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.row) {
                    ForEach(item.issues) { diag in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                            Image(systemName: diag.severity == 1 ? StatusTone.failure.symbol : StatusTone.warning.symbol)
                                .foregroundStyle(diag.severity == 1 ? StatusTone.failure.tint : StatusTone.warning.tint)
                            Text(diag.message)
                                .font(TechnicalTypography.lensRail(size: fontSize))
                                .foregroundStyle(ChromeColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        let tv = textView
                        let diags = item.issues
                        let line = item.lineNumber
                        let rect = anchorRect
                        onDismiss()
                        if let tv {
                            workspace.toggleIssuePopup(in: tv, line: line, diags: diags, below: rect)
                        }
                    } label: {
                        Label("Show Quick Fixes & Details…", systemImage: "wrench.and.screwdriver")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !item.conflictActions.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(Array(item.conflictActions.enumerated()), id: \.offset) { _, action in
                        Button {
                            let tv = textView
                            let line = item.lineNumber
                            let rect = anchorRect
                            onDismiss()
                            tv?.performMergeConflictAction(action, line: line, anchor: rect)
                        } label: {
                            Label(action.title, systemImage: action.menuIcon)
                                .font(TechnicalTypography.lensRail(size: fontSize, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, Spacing.hairline)
                    }
                }
            }

            if let debugValue = item.debugValue {
                Text(debugValue)
                    .font(TechnicalTypography.lensRail(size: fontSize))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .textSelection(.enabled)
            }

            if item.profileHeat != nil || item.escapeNote != nil {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    if let heat = item.profileHeat {
                        Text(String(format: "CPU Sample Share: %.1f%%", heat * 100))
                            .font(TechnicalTypography.lensRail(size: fontSize, weight: .medium))
                            .foregroundStyle(DataVizTone.heatStroke(fraction: heat, isDark: CodeSurfaceTheme.isDark))
                    }
                    if let escapeNote = item.escapeNote {
                        Text(escapeNote)
                            .font(TechnicalTypography.lensRail(size: fontSize))
                            .foregroundStyle(StatusTone.warning.tint)
                    }
                }
            }

            if let renameOffer = item.renameOffer {
                Button {
                    let tv = textView
                    onDismiss()
                    tv?.acceptRenameSuggestion()
                } label: {
                    Label(renameOffer.title, systemImage: "pencil")
                        .font(TechnicalTypography.lensRail(size: fontSize, weight: .medium))
                        .foregroundStyle(ChromeColor.textPrimary)
                }
                .buttonStyle(.plain)
            }

            if let usagesLabel = item.usagesLabel {
                if item.usageInteractive {
                    Button {
                        let tv = textView
                        let line = item.lineNumber
                        onDismiss()
                        tv?.showUsagesForDeclaration(atLine: line)
                    } label: {
                        Label(usagesLabel, systemImage: "magnifyingglass")
                            .font(TechnicalTypography.lensRail(size: fontSize))
                            .foregroundStyle(ChromeColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(usagesLabel)
                        .font(TechnicalTypography.lensRail(size: fontSize))
                        .foregroundStyle(ChromeColor.textSecondary)
                }
            }

            if let implLabel = item.implementationsLabel {
                Button {
                    let tv = textView
                    let impls = item.implementations
                    let line = item.lineNumber
                    onDismiss()
                    guard let tv else { return }
                    if impls.count == 1, let only = impls.first {
                        tv.jumpTo(path: only.path, line: only.range.start.line + 1, col: only.range.start.character + 1)
                    } else {
                        let declName = workspace.activeGoDeclarations.first(where: { $0.line == line })?.symbolName
                        let sym = declName ?? tv.getWord(at: tv.selectedRange().location) ?? "symbol"
                        workspace.showReferences(impls, for: sym, kind: "Implementations")
                    }
                } label: {
                    Label(
                        implLabel,
                        systemImage: item.implementsDirection == .implements ? "arrow.up.right.circle" : "arrow.down.right.circle"
                    )
                    .font(TechnicalTypography.lensRail(size: fontSize))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if !item.goplsLenses.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(Array(item.goplsLenses.enumerated()), id: \.offset) { _, lens in
                        Button {
                            onDismiss()
                            workspace.runEditorLensCommand(lens.command, title: lens.title)
                        } label: {
                            Label(lens.title, systemImage: "play.circle")
                                .font(TechnicalTypography.lensRail(size: fontSize))
                                .foregroundStyle(ChromeColor.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let moduleNote = item.moduleNote {
                HStack(spacing: Spacing.row) {
                    Image(systemName: StatusTone.warning.symbol)
                        .foregroundStyle(StatusTone.warning.tint)
                    Text(moduleNote)
                        .font(TechnicalTypography.lensRail(size: fontSize))
                        .foregroundStyle(ChromeColor.textSecondary)
                }
            }

            if let blame = item.activeLineBlame {
                Button {
                    let path = textView?.filePath ?? ""
                    onDismiss()
                    if !path.isEmpty {
                        workspace.presentFileHistory(for: path, focusCaretLine: true)
                    }
                } label: {
                    Label(blame, systemImage: "clock.arrow.circlepath")
                        .font(TechnicalTypography.lensRail(size: fontSize))
                        .foregroundStyle(ChromeColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else if let author = item.author {
                HStack(spacing: Spacing.row) {
                    Image(systemName: "person")
                        .foregroundStyle(ChromeColor.textSecondary)
                    Text(author)
                        .font(TechnicalTypography.lensRail(size: fontSize))
                        .foregroundStyle(ChromeColor.textSecondary)
                }
            }
        }
        .padding(Spacing.comfortable)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
    }
}
