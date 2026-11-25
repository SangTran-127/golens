import SwiftUI
import AppKit

struct NativeEditorView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    var paneID: EditorPaneID = .primary
    var customFilePath: String? = nil
    @State private var localTextView: GoLensTextView? = nil

    private var pane: EditorPaneState {
        workspace.paneState(for: paneID)
    }

    private var targetFilePath: String {
        return customFilePath ?? workspace.filePath(for: paneID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !targetFilePath.isEmpty {
                let fullPath = targetFilePath
                let ext = (fullPath as NSString).pathExtension.lowercased()
                let isImg = ["png", "jpg", "jpeg", "gif", "tiff", "bmp"].contains(ext)

                if isImg {
                    ImagePreviewView(path: fullPath)
                } else if let error = workspace.fileOpenErrors[fullPath] {
                    ContentUnavailableView {
                        Label("Can’t Open \((fullPath as NSString).lastPathComponent)", systemImage: "doc.questionmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: fullPath)) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)]) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ThemeColor.editorSurface)
                } else {
                    let isMarkdown = ext == "md" || ext == "markdown"
                    let isMarkdownPreview = isMarkdown && ((workspace.markdownPreviewMode[fullPath] ?? false) || (paneID == .secondary && fullPath == workspace.activeFilePath))
                    if workspace.editorMode(for: fullPath) == .diff {
                        GitDiffView(filePath: fullPath)
                    } else if isMarkdownPreview {
                        MarkdownPreviewView(filePath: fullPath)
                    } else {
                        if paneID == .secondary && workspace.isCounterpartSplitEnabled && !FileManager.default.fileExists(atPath: fullPath) {
                            ContentUnavailableView {
                                Label("No Counterpart Test", systemImage: "testtube.2")
                            } description: {
                                Text("No test file exists for \((workspace.activeFilePath as NSString).lastPathComponent). Generate a table-driven test skeleton to start testing.")
                            } actions: {
                                Button(KeymapStore.shared.labeled("Generate Table-Driven Test…", "generate.tableTest")) {
                                    workspace.presentGenerateTableDrivenTestSheet()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(ThemeColor.editorSurface)
                        } else {
                            let _ = workspace.largeFileModeRevision
                            if let session = workspace.documents[fullPath], !session.syncsToCore {
                                InlineBanner(
                                    .symbol("lock"),
                                    title: "Large File — Read-Only",
                                    message: "Files over 10 MB open without editing or code intelligence so GoLens stays responsive."
                                ) {
                                    Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: fullPath)) }
                                }
                            } else if let session = workspace.documents[fullPath], session.isEffectiveLargeFileMode {
                                InlineBanner(
                                    .symbol("gauge.with.dots.needle.33percent"),
                                    title: "Large-File Mode Active (\(UserMessage.byteCount(Int64(max(0, session.utf8.byteLength)))) · \(UserMessage.integer(session.lines.count)) lines)",
                                    message: "Semantic tokens and inlay hints are paused so scrolling and typing stay responsive."
                                ) {
                                    Button("Enable Anyway") { workspace.enableFullAnalysisForLargeFile(fullPath) }
                                }
                            }
                            if workspace.diskConflicts.contains(fullPath) {
                                InlineBanner(
                                    .status(.warning),
                                    title: "“\((fullPath as NSString).lastPathComponent)” Changed on Disk",
                                    message: "Another app changed this file while it has unsaved edits in GoLens. Choose which version to keep."
                                ) {
                                    Button("Revert to Disk Version") { workspace.revertToDiskVersion(fullPath, reportsFailure: true) }
                                    Button("Keep GoLens Version") { workspace.keepGoLensVersion(fullPath) }
                                }
                            }
                            if fullPath == workspace.activeFilePath, let reason = workspace.activeFileExcludedReason {
                                if workspace.activeBuildTargetIsCustom {
                                    InlineBanner(
                                        .symbol("slider.horizontal.below.rectangle"),
                                        title: "File Excluded from Active Build Target",
                                        message: reason
                                    ) {
                                        Button("Reset Build Target") { workspace.resetBuildTarget() }
                                    }
                                } else {
                                    InlineBanner(
                                        .symbol("slider.horizontal.below.rectangle"),
                                        title: "File Excluded from Active Build Target",
                                        message: reason,
                                        detail: "To work on this file, choose a matching target from Build Target in the status bar."
                                    )
                                }
                            }
                            if let origin = workspace.generatedOrigin(for: fullPath) {
                                let sourceDetail = origin.sourceDisplayName.map { " from “\($0)”" } ?? ""
                                let message: String = origin.generateDirective != nil
                                    ? "Generated by \(origin.generator)\(sourceDetail). Edit the source and regenerate instead."
                                    : "Generated by \(origin.generator)\(sourceDetail). No //go:generate directive was found in this package."
                                InlineBanner(
                                    .symbol("gearshape.2", tone: .info),
                                    title: "Generated File — Do Not Edit",
                                    message: message
                                ) {
                                    if origin.sourcePath != nil {
                                        Button("Open Source") {
                                            let line = fullPath == workspace.activeFilePath ? workspace.cursorLine : nil
                                            workspace.openGeneratedFileOrigin(for: fullPath, line1Based: line)
                                        }
                                    }
                                    Button("Regenerate") {
                                        workspace.regenerateGeneratedFile(for: fullPath)
                                    }
                                    .disabled(origin.generateDirective == nil || workspace.isRunning)
                                    .help(
                                        origin.generateDirective.map { "Run //go:generate (\($0.command))" }
                                            ?? "No matching //go:generate directive was found in this package."
                                    )
                                }
                            }
                            ZStack(alignment: .topLeading) {
                                MacTextView(
                                    filePath: fullPath,
                                    isLoaded: workspace.loadedDocuments.contains(fullPath),
                                    themeId: workspace.selectedThemeId,
                                    isDark: workspace.currentTheme.resolvedIsDark,
                                    localTextView: $localTextView,
                                    pendingJumpToLine: pane.pendingJumpToLine,
                                    pendingJumpToCol: pane.pendingJumpToCol,
                                    pendingJumpToRange: pane.pendingJumpToRange,
                                    paneID: paneID
                                )
                                .focusedValue(\.commentSelectionAction) {
                                    if let textView = workspace.editorTextView(for: paneID) ?? workspace.activeTextView {
                                        toggleComment(in: textView)
                                    }
                                }

                                if workspace.showMinimap, let golensTextView = localTextView ?? workspace.editorTextView(for: paneID) {
                                    MinimapView(sourceTextView: golensTextView)
                                        .frame(width: 80)
                                        .padding(.trailing, Spacing.inset)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                        .allowsHitTesting(true)
                                }
                                if pane.showLocalSearch {
                                    LocalSearchView(paneID: paneID)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                        .padding(.top, Spacing.inset)
                                        .padding(.trailing, Spacing.section)
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyEditorStateView(workspace: workspace)
            }
        }
    }
}

private struct EmptyEditorStateView: View {
    @Bindable var workspace: WorkspaceState
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"

    var body: some View {
        let isDark = CodeSurfaceTheme.isDark
        let primaryText = CodeSurfaceTheme.textPrimary
        let secondaryText = CodeSurfaceTheme.textSecondary

        VStack(spacing: Spacing.comfortable) {
            Image(nsImage: ThemeManager.shared.appIconImage(themeId: workspace.selectedThemeId, costume: mascotCostume))
                .resizable()
                .frame(width: 56, height: 56)
                .shadow(color: Color(nsColor: .shadowColor).opacity(isDark ? 0.24 : 0.08), radius: 8, x: 0, y: 3)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.compact) {
                Text("No File Selected")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(primaryText)

                Text(GopherLore.emptyEditorSubtitle(themeId: workspace.selectedThemeId, costume: mascotCostume))
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
            }

            VStack(spacing: Spacing.compact) {
                EmptyEditorShortcutItem(
                    icon: "magnifyingglass",
                    label: "Open Quickly",
                    shortcut: KeymapStore.shared.display("file.openQuickly"),
                    primaryText: primaryText,
                    secondaryText: secondaryText
                ) {
                    workspace.activePopup = .openQuickly
                }
                EmptyEditorShortcutItem(
                    icon: "command.square",
                    label: "Command Palette",
                    shortcut: KeymapStore.shared.display("view.commandPalette"),
                    primaryText: primaryText,
                    secondaryText: secondaryText
                ) {
                    workspace.activePopup = .commandPalette
                }
                EmptyEditorShortcutItem(
                    icon: "doc.badge.plus",
                    label: "New File",
                    shortcut: KeymapStore.shared.display("file.newFile"),
                    primaryText: primaryText,
                    secondaryText: secondaryText
                ) {
                    workspace.requestNewItem(folder: false)
                }
            }
            .frame(width: 248)
            .padding(.top, Spacing.compact)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.editorSurface)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

private struct EmptyEditorShortcutItem: View {
    let icon: String
    let label: String
    let shortcut: String
    let primaryText: Color
    let secondaryText: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
                    .frame(width: 16, height: 16)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(primaryText)
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(TechnicalTypography.codeCompact)
                        .foregroundStyle(secondaryText)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .wellBackground(cornerRadius: CornerRadius.small)
                }
            }
            .padding(.horizontal, Spacing.inset)
            .padding(.vertical, Spacing.row)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .fill(isHovered ? ThemeColor.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

