import SwiftUI
import AppKit
import GoLensFoundation

struct GitDiffView: View {
    let filePath: String
    @Environment(\.windowWorkspace) var workspace
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(WorkspaceState.comparisonLocalOnLeftKey) var localOnLeft = false
    @State var displayItems: [DisplayDiffItem] = []
    @State var patch: GitFilePatch? = nil
    @State var runRefs: [String: [GitPatchLineRef]] = [:]
    @State var loadedSource: GitDiffSource = .unstaged
    @State var loadedFullContext = false
    @State var selectedRefs: Set<GitPatchLineRef> = []
    @State var selectionAnchor: GitPatchLineRef? = nil
    @State var isApplyingGitChange = false
    @State var hunkAnchorLineIds: [String] = []
    @State var firstChangedLineNumber: Int? = nil
    @State var currentHunkIndex: Int = 0
    @State var expandedBlockIds: Set<String> = []
    @State var addedCount: Int = 0
    @State var removedCount: Int = 0
    @State var isLoading = true
    @State var loadedFilePath: String = ""
    @State var loadTask: Task<Void, Never>? = nil
    @State var diffNotice: String? = nil
    @State var originalScrollX: CGFloat = 0
    @State var modifiedScrollX: CGFloat = 0
    @State var unifiedScrollX: CGFloat = 0
    @State var originalViewportWidth: CGFloat = 0
    @State var modifiedViewportWidth: CGFloat = 0
    @State var unifiedViewportWidth: CGFloat = 0
    @State var estimatedOriginalWidth: CGFloat = 0
    @State var estimatedModifiedWidth: CGFloat = 0
    @State var estimatedUnifiedWidth: CGFloat = 0
    @State var measuredOriginalWidth: CGFloat = 0
    @State var measuredModifiedWidth: CGFloat = 0
    @State var measuredUnifiedWidth: CGFloat = 0

    static let sideBySideGutterWidth: CGFloat = 3 + 42 + Spacing.standard + 14
    static let unifiedGutterWidth: CGFloat = 3 + 42 + Spacing.row + 42 + Spacing.standard + 16

    enum DiffStyle: String, CaseIterable, Identifiable {
        case sideBySide
        case unified
        var id: String { self.rawValue }
        var title: String { self == .sideBySide ? "Side by Side" : "Inline" }
    }

    var isCommitDiffMode: Bool {
        workspace.isCommitDiffActive(for: filePath)
    }

    var diffSource: GitDiffSource {
        workspace.effectiveDiffSource(for: filePath)
    }

    var canStageLines: Bool {
        !isCommitDiffMode && patch != nil && workspace.gitStatus(for: filePath) != "U"
    }

    var stageVerb: String {
        loadedSource == .staged ? "Unstage" : "Stage"
    }

    var comparesStagedBase: Bool {
        diffSource == .unstaged && workspace.gitChangeState(for: filePath).hasStaged
    }

    var leftHeaderTitle: String {
        if isCommitDiffMode, let ctx = workspace.git.activeCommitDiffContext {
            return "Parent of \(ctx.commit.shortHash)"
        }
        return comparesStagedBase ? "Staged" : "Original (HEAD)"
    }

    var canOpenInCodeEditor: Bool {
        FileManager.default.fileExists(atPath: filePath) || workspace.documentSession(forPath: filePath) != nil
    }

    var rightHeaderTitle: String {
        if isCommitDiffMode, let ctx = workspace.git.activeCommitDiffContext {
            return "Commit \(ctx.commit.shortHash) — \(ctx.commit.subject)"
        }
        if diffSource == .staged {
            return "Staged"
        }
        if workspace.documentSession(forPath: filePath)?.isEdited == true {
            return "Working Tree (Unsaved Edits)"
        }
        return "Local Changes"
    }

    var comparisonTitle: String {
        if diffSource == .staged {
            return "HEAD ↔ Staged"
        }
        return comparesStagedBase ? "Staged ↔ Working Tree" : "HEAD ↔ Working Tree"
    }

    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        let editorBg = ThemeColor.editorSurface

        VStack(spacing: 0) {
            diffNavigationToolbar(isDark: isDark)

            Divider()

            if isLoading && displayItems.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading comparison diff…")
                        .font(.caption)
                        .foregroundStyle(CodeSurfaceTheme.textSecondary)
                        .padding(.top, Spacing.standard)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(editorBg)
                .environment(\.colorScheme, isDark ? .dark : .light)
            } else if !isLoading, let diffNotice {
                VStack(spacing: Spacing.comfortable) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(CodeSurfaceTheme.textSecondary)
                        .accessibilityHidden(true)
                    Text(diffNotice)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CodeSurfaceTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    diffEmptyStateActions
                    Spacer()
                }
                .padding(.horizontal, Spacing.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(editorBg)
                .environment(\.colorScheme, isDark ? .dark : .light)
            } else if !isLoading && (displayItems.isEmpty || (addedCount == 0 && removedCount == 0 && hunkAnchorLineIds.isEmpty)) {
                VStack(spacing: Spacing.comfortable) {
                    Spacer()
                    EmptyStateBadgeView(badge: "git", size: 32)
                    Text("No differences found in this file")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CodeSurfaceTheme.textSecondary)
                    diffEmptyStateActions
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(editorBg)
                .environment(\.colorScheme, isDark ? .dark : .light)
            } else {
                if workspace.diffStyle == .sideBySide {
                    sideBySideStickyHeader(isDark: isDark)
                }

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        if workspace.diffStyle == .sideBySide {
                            sideBySideLayout(items: displayItems, isDark: isDark)
                        } else {
                            unifiedLayout(items: displayItems, isDark: isDark)
                        }
                    }
                    .background(
                        DiffHorizontalWheelCatcher(
                            mode: workspace.diffStyle == .sideBySide ? .split : .single,
                            leadingMetrics: leadingHorizontalMetrics,
                            trailingMetrics: trailingHorizontalMetrics,
                            onLeadingOffsetChange: { setLeadingScrollOffset($0) },
                            onTrailingOffsetChange: { setTrailingScrollOffset($0) }
                        )
                    )
                    .background(editorBg)
                    .environment(\.colorScheme, isDark ? .dark : .light)
                    .onChange(of: currentHunkIndex) { _, _ in
                        scrollToCurrentHunkIfNeeded(proxy: scrollProxy, animated: true)
                    }
                    .onChange(of: loadedFilePath) { _, _ in
                        if !workspace.git.collapseUnchangedInDiff {
                            scrollToCurrentHunkIfNeeded(proxy: scrollProxy, animated: false)
                        }
                    }
                }

                diffBottomHorizontalScrollRail(isDark: isDark)
            }
        }
        .onAppear(perform: loadDiffData)
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: filePath) {
            expandedBlockIds.removeAll()
            currentHunkIndex = 0
            resetHorizontalScroll()
            loadDiffData()
        }
        .onChange(of: workspace.git.collapseUnchangedInDiff) {
            loadDiffData()
        }
        .onChange(of: workspace.git.changedFiles) {
            loadDiffData()
        }
        .onChange(of: workspace.git.activeCommitDiffContext?.commit.hash) {
            expandedBlockIds.removeAll()
            currentHunkIndex = 0
            resetHorizontalScroll()
            loadDiffData()
        }
        .onChange(of: workspace.git.activeCommitDiffContext?.relativePath) {
            expandedBlockIds.removeAll()
            currentHunkIndex = 0
            resetHorizontalScroll()
            loadDiffData()
        }
        .onChange(of: diffSource) {
            clearLineSelection()
            currentHunkIndex = 0
            resetHorizontalScroll()
            loadDiffData()
        }
        .onChange(of: workspace.git.activeFileDiffs) {
            if workspace.activeFilePath == filePath && !isCommitDiffMode && diffSource == .unstaged {
                loadDiffData()
            }
        }
    }

    func resetHorizontalScroll() {
        originalScrollX = 0
        modifiedScrollX = 0
        unifiedScrollX = 0
        measuredOriginalWidth = 0
        measuredModifiedWidth = 0
        measuredUnifiedWidth = 0
    }

    func horizontalMetrics(original: Bool) -> DiffHorizontalScrollMetrics {
        let contentWidth = original
            ? max(estimatedOriginalWidth, measuredOriginalWidth)
            : max(estimatedModifiedWidth, measuredModifiedWidth)
        let viewportWidth = original ? originalViewportWidth : modifiedViewportWidth
        let offset = original ? originalScrollX : modifiedScrollX
        return DiffHorizontalScrollMetrics(contentWidth: contentWidth, viewportWidth: viewportWidth, offset: offset)
    }

    var unifiedHorizontalMetrics: DiffHorizontalScrollMetrics {
        DiffHorizontalScrollMetrics(
            contentWidth: max(estimatedUnifiedWidth, measuredUnifiedWidth),
            viewportWidth: unifiedViewportWidth,
            offset: unifiedScrollX
        )
    }

    var leadingHorizontalMetrics: DiffHorizontalScrollMetrics {
        workspace.diffStyle == .sideBySide ? horizontalMetrics(original: !localOnLeft) : unifiedHorizontalMetrics
    }

    var trailingHorizontalMetrics: DiffHorizontalScrollMetrics {
        workspace.diffStyle == .sideBySide
            ? horizontalMetrics(original: localOnLeft)
            : DiffHorizontalScrollMetrics(contentWidth: 0, viewportWidth: 0, offset: 0)
    }

    func setSideBySideScrollOffset(_ offset: CGFloat, original: Bool) {
        let clamped = horizontalMetrics(original: original).clamped(offset)
        if original {
            originalScrollX = clamped
        } else {
            modifiedScrollX = clamped
        }
    }

    func setLeadingScrollOffset(_ offset: CGFloat) {
        if workspace.diffStyle == .sideBySide {
            setSideBySideScrollOffset(offset, original: !localOnLeft)
        } else {
            unifiedScrollX = unifiedHorizontalMetrics.clamped(offset)
        }
    }

    func setTrailingScrollOffset(_ offset: CGFloat) {
        guard workspace.diffStyle == .sideBySide else { return }
        setSideBySideScrollOffset(offset, original: localOnLeft)
    }

    @ViewBuilder
    func diffBottomHorizontalScrollRail(isDark: Bool) -> some View {
        let scrollerHeight = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        if workspace.diffStyle == .sideBySide {
            let leftOriginal = !localOnLeft
            let rightOriginal = localOnLeft
            let leftMetrics = horizontalMetrics(original: leftOriginal)
            let rightMetrics = horizontalMetrics(original: rightOriginal)
            if leftMetrics.needsScrollbar || rightMetrics.needsScrollbar {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: Self.sideBySideGutterWidth)
                        if leftMetrics.needsScrollbar {
                            DiffHorizontalScroller(
                                metrics: leftMetrics,
                                accessibilityLabel: "\(leftOriginal ? leftHeaderTitle : rightHeaderTitle) Horizontal Scrollbar"
                            ) { newOffset in
                                setSideBySideScrollOffset(newOffset, original: leftOriginal)
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: Stroke.standard)

                    HStack(spacing: 0) {
                        Color.clear.frame(width: Self.sideBySideGutterWidth)
                        if rightMetrics.needsScrollbar {
                            DiffHorizontalScroller(
                                metrics: rightMetrics,
                                accessibilityLabel: "\(rightOriginal ? leftHeaderTitle : rightHeaderTitle) Horizontal Scrollbar"
                            ) { newOffset in
                                setSideBySideScrollOffset(newOffset, original: rightOriginal)
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: scrollerHeight + Spacing.hairline * 2)
                .background(ThemeColor.panelSurface.opacity(0.85))
                .overlay(alignment: .top) { Divider() }
                .environment(\.colorScheme, isDark ? .dark : .light)
            }
        } else {
            let metrics = unifiedHorizontalMetrics
            if metrics.needsScrollbar {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.unifiedGutterWidth)
                    DiffHorizontalScroller(
                        metrics: metrics,
                        accessibilityLabel: "Diff Horizontal Scrollbar"
                    ) { newOffset in
                        unifiedScrollX = metrics.clamped(newOffset)
                    }
                }
                .frame(height: scrollerHeight + Spacing.hairline * 2)
                .background(ThemeColor.panelSurface.opacity(0.85))
                .overlay(alignment: .top) { Divider() }
                .environment(\.colorScheme, isDark ? .dark : .light)
            }
        }
    }

    @ViewBuilder
    var diffEmptyStateActions: some View {
        HStack(spacing: Spacing.comfortable) {
            if isCommitDiffMode {
                if workspace.git.commitDiffReturnHistory != nil {
                    Button("Back to History") {
                        workspace.returnFromCommitDiffToHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Back to Working Tree") {
                    workspace.clearCommitDiffContext()
                    loadDiffData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if canOpenInCodeEditor {
                Button("Return to Code Editor") {
                    workspace.clearCommitDiffContext()
                    workspace.setEditorMode(.code, for: filePath)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Return to code editor")
            }
        }
    }

    @ViewBuilder
    func diffNavigationToolbar(isDark: Bool) -> some View {
        HStack(spacing: Spacing.inset) {
            if isCommitDiffMode, let ctx = workspace.git.activeCommitDiffContext {
                HStack(spacing: Spacing.row) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text("Commit \(ctx.commit.shortHash)")
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(Color.accentColor)
                    Text(ctx.commit.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if workspace.git.commitDiffReturnHistory != nil {
                        Button {
                            workspace.returnFromCommitDiffToHistory()
                        } label: {
                            Label("Back to History", systemImage: "chevron.backward")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Return to Git History")
                    }
                    Button {
                        workspace.clearCommitDiffContext()
                        loadDiffData()
                    } label: {
                        Label("Working Tree", systemImage: "xmark.circle.fill")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Exit commit diff preview and return to working tree diff")
                }
            } else {
                HStack(spacing: Spacing.row) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(comparisonTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if addedCount > 0 || removedCount > 0 || !hunkAnchorLineIds.isEmpty {
                Divider()
                    .frame(height: 12)

                HStack(spacing: Spacing.row) {
                    Text("\(max(1, hunkAnchorLineIds.count)) \(hunkAnchorLineIds.count == 1 ? "change" : "changes")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if addedCount > 0 {
                        Text("+\(addedCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(StatusTone.success.tint)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(StatusTone.success.fill, in: Capsule())
                    }
                    if removedCount > 0 {
                        Text("-\(removedCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(StatusTone.failure.tint)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(StatusTone.failure.fill, in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: Spacing.standard) {
                if !hunkAnchorLineIds.isEmpty {
                    HStack(spacing: Spacing.compact) {
                        Button {
                            guard !hunkAnchorLineIds.isEmpty else { return }
                            currentHunkIndex = (currentHunkIndex - 1 + hunkAnchorLineIds.count) % hunkAnchorLineIds.count
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkAnchorLineIds.count <= 1)
                        .help("Previous Change")
                        .accessibilityLabel("Previous Change")

                        Text("\(min(currentHunkIndex + 1, hunkAnchorLineIds.count)) / \(hunkAnchorLineIds.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 34)

                        Button {
                            guard !hunkAnchorLineIds.isEmpty else { return }
                            currentHunkIndex = (currentHunkIndex + 1) % hunkAnchorLineIds.count
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkAnchorLineIds.count <= 1)
                        .help("Next Change")
                        .accessibilityLabel("Next Change")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Toggle(isOn: Bindable(workspace).git.collapseUnchangedInDiff) {
                    Label(
                        workspace.git.collapseUnchangedInDiff ? "Collapse Unchanged" : "Full File",
                        systemImage: "arrow.up.and.down.text.horizontal"
                    )
                    .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Toggle collapsing unchanged code blocks")

                Button {
                    let targetLine = firstChangedLineNumber
                    workspace.clearCommitDiffContext()
                    workspace.setEditorMode(.code, for: filePath)
                    if let targetLine {
                        workspace.restoreCaretLocation(line: targetLine, column: 1, inPath: filePath)
                    }
                    workspace.focusCodeEditor(for: filePath)
                } label: {
                    Label("Edit Code", systemImage: "pencil.line")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(!canOpenInCodeEditor)
                .help(canOpenInCodeEditor ? "Switch to Code Editor at current change" : "File does not exist in the working tree")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .background(ThemeColor.panelSurface.opacity(0.92))
    }

}
