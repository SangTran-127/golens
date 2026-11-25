import SwiftUI
import AppKit
import GoLensFoundation

extension GitDiffView {
    func stickyHeaderCell(original: Bool, isDark: Bool) -> some View {
        let symbol: String = original ? "clock" : "doc.badge.gearshape"
        let title: String = original ? leftHeaderTitle : rightHeaderTitle
        return HStack(spacing: Spacing.row) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ThemeColor.textSecondary)
                .lineLimit(1)
        }
        .padding(.leading, Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func sideBySideStickyHeader(isDark: Bool) -> some View {
        HStack(spacing: 0) {
            stickyHeaderCell(original: !localOnLeft, isDark: isDark)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: Stroke.standard)

            stickyHeaderCell(original: localOnLeft, isDark: isDark)
        }
        .frame(height: 24)
        .background(ThemeColor.panelSurface.opacity(0.85))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    func sideBySideLayout(items: [DisplayDiffItem], isDark: Bool) -> some View {
        let lineNumColor = ThemeColor.textTertiary
        let blocks = DiffRenderBlock.grouped(from: items)

        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case .collapsed(let blockId, let count, let startLine, let endLine):
                    collapsedRegionBanner(blockId: blockId, count: count, startLine: startLine, endLine: endLine)
                        .id(blockId)

                case .hunk(let anchorId, let ordinal, let leftStart, let rightStart, let hunk):
                    hunkHeaderBanner(anchorId: anchorId, ordinal: ordinal, leftStart: leftStart, rightStart: rightStart, hunk: hunk)
                        .id(anchorId)

                case .lines(_, let lines):
                    HStack(spacing: 0) {
                        sideBySidePane(lines: lines, original: !localOnLeft, lineNumColor: lineNumColor)

                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: Stroke.standard)

                        sideBySidePane(lines: lines, original: localOnLeft, lineNumColor: lineNumColor)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, Spacing.comfortable)
    }

    @ViewBuilder
    func sideBySidePane(lines: [AlignedLine], original: Bool, lineNumColor: Color) -> some View {
        let blockHeight = CGFloat(lines.count) * 20
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    let number: Int? = original ? line.leftLineNum : line.rightLineNum
                    let jumpNum: Int = line.rightLineNum ?? max(1, line.targetNewLine)
                    let ref: GitPatchLineRef? = original ? line.leftRef : line.rightRef
                    let barColor: Color = original ? line.leftGutterBarColor() : line.rightGutterBarColor()
                    let symbol: String = original ? line.leftPrefixSymbol() : line.rightPrefixSymbol()
                    let symbolColor: Color = original ? line.leftPrefixColor() : line.rightPrefixColor()
                    let background: Color = original ? line.leftBgColor() : line.rightBgColor()

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(barColor)
                            .frame(width: 3)

                        Button {
                            jumpToDiffLineInCode(line)
                        } label: {
                            Text(number.map { "\($0)" } ?? "")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(lineNumColor)
                                .frame(width: 42, alignment: .trailing)
                                .padding(.trailing, Spacing.standard)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canOpenInCodeEditor || number == nil)
                        .accessibilityHidden(number == nil)
                        .accessibilityLabel("Jump to Line \(jumpNum) in Code Editor")
                        .help(canOpenInCodeEditor ? "Jump to Line in Code Editor" : "File does not exist in the working tree")

                        Text(symbol)
                            .font(.caption.monospaced())
                            .foregroundStyle(symbolColor)
                            .frame(width: 14, alignment: .center)
                    }
                    .frame(height: 20)
                    .background(lineBackground(ref, base: background))
                }
            }

            DiffCodeViewport(
                blockHeight: blockHeight,
                contentWidth: original ? max(estimatedOriginalWidth, measuredOriginalWidth) : max(estimatedModifiedWidth, measuredModifiedWidth),
                scrollOffset: original ? originalScrollX : modifiedScrollX,
                onViewportWidthChange: { width in
                    if original {
                        originalViewportWidth = width
                        originalScrollX = horizontalMetrics(original: true).clampedOffset
                    } else {
                        modifiedViewportWidth = width
                        modifiedScrollX = horizontalMetrics(original: false).clampedOffset
                    }
                },
                onMeasuredWidthChange: { width in
                    if original {
                        if width > measuredOriginalWidth { measuredOriginalWidth = width }
                    } else {
                        if width > measuredModifiedWidth { measuredModifiedWidth = width }
                    }
                }
            ) {
                ForEach(lines) { line in
                    let ref: GitPatchLineRef? = original ? line.leftRef : line.rightRef
                    let text: AttributedString = original ? line.leftAttributed : line.rightAttributed
                    let background: Color = original ? line.leftBgColor() : line.rightBgColor()
                    let rowRefs = [line.leftRef, line.rightRef].compactMap { $0 }

                    Button {
                        selectLine(ref)
                    } label: {
                        Text(text)
                            .font(.body.monospaced())
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.trailing, Spacing.comfortable)
                            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(lineBackground(ref, base: background))
                    .jumpToCodeAccessibility(enabled: canOpenInCodeEditor) {
                        jumpToDiffLineInCode(line)
                    }
                    .lineSelectionAccessibility(refs: rowRefs, selected: selectedRefs, enabled: canStageLines) {
                        toggleLines(rowRefs)
                    }
                    .contextMenu {
                        diffLineContextMenu(line, refs: rowRefs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct UnifiedDiffEntry: Identifiable {
        let id: String
        let leftNum: Int?
        let rightNum: Int?
        let prefix: String
        let attributedText: AttributedString
        let bgColor: Color
        let barColor: Color
        let prefixColor: Color
        let line: AlignedLine
        let ref: GitPatchLineRef?
    }

    private func unifiedEntries(from lines: [AlignedLine]) -> [UnifiedDiffEntry] {
        var result: [UnifiedDiffEntry] = []
        result.reserveCapacity(lines.count * 2)
        for line in lines {
            if line.type == .modified {
                result.append(UnifiedDiffEntry(
                    id: "\(line.id)-del",
                    leftNum: line.leftLineNum,
                    rightNum: nil,
                    prefix: "-",
                    attributedText: line.leftAttributed,
                    bgColor: StatusTone.failure.tint.opacity(0.13),
                    barColor: StatusTone.failure.tint,
                    prefixColor: StatusTone.failure.tint,
                    line: line,
                    ref: line.leftRef
                ))
                result.append(UnifiedDiffEntry(
                    id: "\(line.id)-add",
                    leftNum: nil,
                    rightNum: line.rightLineNum,
                    prefix: "+",
                    attributedText: line.rightAttributed,
                    bgColor: StatusTone.success.tint.opacity(0.13),
                    barColor: StatusTone.success.tint,
                    prefixColor: StatusTone.success.tint,
                    line: line,
                    ref: line.rightRef
                ))
            } else {
                result.append(UnifiedDiffEntry(
                    id: line.id,
                    leftNum: line.leftLineNum,
                    rightNum: line.rightLineNum,
                    prefix: line.unifiedPrefix(),
                    attributedText: line.type == .deleted ? line.leftAttributed : line.rightAttributed,
                    bgColor: line.unifiedBgColor(),
                    barColor: line.type == .added ? StatusTone.success.tint : (line.type == .deleted ? StatusTone.failure.tint : Color.clear),
                    prefixColor: line.type == .added ? StatusTone.success.tint : (line.type == .deleted ? StatusTone.failure.tint : .secondary),
                    line: line,
                    ref: line.type == .added ? line.rightRef : line.leftRef
                ))
            }
        }
        return result
    }

    @ViewBuilder
    func unifiedLayout(items: [DisplayDiffItem], isDark: Bool) -> some View {
        let blocks = DiffRenderBlock.grouped(from: items)
        let lineNumColor = ThemeColor.textTertiary

        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case .collapsed(let blockId, let count, let startLine, let endLine):
                    collapsedRegionBanner(blockId: blockId, count: count, startLine: startLine, endLine: endLine)
                        .id(blockId)

                case .hunk(let anchorId, let ordinal, let leftStart, let rightStart, let hunk):
                    hunkHeaderBanner(anchorId: anchorId, ordinal: ordinal, leftStart: leftStart, rightStart: rightStart, hunk: hunk)
                        .id(anchorId)

                case .lines(_, let lines):
                    let entries = unifiedEntries(from: lines)
                    let blockHeight = CGFloat(entries.count) * 20

                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                let jumpNum: Int = entry.rightNum ?? max(1, entry.line.targetNewLine)
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(entry.barColor)
                                        .frame(width: 3)

                                    Button {
                                        jumpToDiffLineInCode(entry.line)
                                    } label: {
                                        HStack(spacing: 0) {
                                            Text(entry.leftNum.map(String.init) ?? "")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(lineNumColor)
                                                .frame(width: 42, alignment: .trailing)
                                                .padding(.trailing, Spacing.row)

                                            Text(entry.rightNum.map(String.init) ?? "")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(lineNumColor)
                                                .frame(width: 42, alignment: .trailing)
                                                .padding(.trailing, Spacing.standard)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canOpenInCodeEditor)
                                    .accessibilityLabel("Jump to Line \(jumpNum) in Code Editor")
                                    .help(canOpenInCodeEditor ? "Jump to Line in Code Editor" : "File does not exist in the working tree")

                                    Text(entry.prefix)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(entry.prefixColor)
                                        .frame(width: 16, alignment: .center)
                                }
                                .frame(height: 20)
                                .background(lineBackground(entry.ref, base: entry.bgColor))
                            }
                        }

                        DiffCodeViewport(
                            blockHeight: blockHeight,
                            contentWidth: max(estimatedUnifiedWidth, measuredUnifiedWidth),
                            scrollOffset: unifiedScrollX,
                            onViewportWidthChange: { width in
                                unifiedViewportWidth = width
                                unifiedScrollX = unifiedHorizontalMetrics.clampedOffset
                            },
                            onMeasuredWidthChange: { width in
                                if width > measuredUnifiedWidth { measuredUnifiedWidth = width }
                            }
                        ) {
                            ForEach(entries) { entry in
                                let entryRefs = entry.ref.map { [$0] } ?? []
                                Button {
                                    selectLine(entry.ref)
                                } label: {
                                    Text(entry.attributedText)
                                        .font(.body.monospaced())
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.trailing, Spacing.comfortable)
                                        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(lineBackground(entry.ref, base: entry.bgColor))
                                .jumpToCodeAccessibility(enabled: canOpenInCodeEditor) {
                                    jumpToDiffLineInCode(entry.line)
                                }
                                .lineSelectionAccessibility(refs: entryRefs, selected: selectedRefs, enabled: canStageLines) {
                                    toggleLines(entryRefs)
                                }
                                .contextMenu {
                                    diffLineContextMenu(entry.line, refs: entryRefs)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.bottom, Spacing.comfortable)
    }

    @ViewBuilder
    func collapsedRegionBanner(blockId: String, count: Int, startLine: Int, endLine: Int) -> some View {
        Button {
            expandedBlockIds.insert(blockId)
            loadDiffData()
        } label: {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "ellipsis")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Expand \(count) unchanged lines (Lines \(startLine)–\(endLine))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .quaternarySystemFill))
            .overlay(alignment: .top) { Divider().opacity(0.5) }
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to show \(count) unchanged lines")
    }

    @ViewBuilder
    func hunkHeaderBanner(anchorId: String, ordinal: Int, leftStart: Int?, rightStart: Int?, hunk: GitDiffHunk?) -> some View {
        let targetLine = rightStart ?? hunk.map { max(1, $0.newStart) } ?? leftStart ?? 1
        HStack(spacing: Spacing.standard) {
            Text("Change #\(ordinal)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.hairline)
                .background(Color.accentColor.opacity(0.12), in: Capsule())

            if let hunk {
                Text(hunk.header)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Line \(targetLine)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if canStageLines, let refs = runRefs[anchorId], !refs.isEmpty {
                if !selectedRefs.isDisjoint(with: refs) {
                    Button {
                        applyLines(selectedRefs)
                    } label: {
                        Label("\(stageVerb) Selected Lines", systemImage: loadedSource == .staged ? "text.badge.minus" : "text.badge.plus")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isApplyingGitChange)
                    .help(loadedSource == .staged ? "Move the selected lines back to unstaged changes" : "Add only the selected lines to the next commit")
                }

                Button {
                    applyLines(Set(refs))
                } label: {
                    Label("\(stageVerb) Hunk", systemImage: loadedSource == .staged ? "minus.circle" : "plus.circle")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isApplyingGitChange)
                .help(loadedSource == .staged ? "Move this change back to unstaged changes" : "Add this change to the next commit")
            }

            if !isCommitDiffMode, loadedSource == .unstaged, !workspace.isUntrackedPath(filePath), workspace.gitStatus(for: filePath) != "U", let hunk {
                Button {
                    let refs = Set(runRefs[anchorId] ?? [])
                    if let currentPatch = patch, !refs.isEmpty {
                        let path = filePath
                        isApplyingGitChange = true
                        Task { @MainActor in
                            await workspace.revertOrDiscardHunkInDiffView(runRefs: refs, patch: currentPatch, hunk: hunk, inPath: path)
                            isApplyingGitChange = false
                            loadDiffData()
                        }
                    } else {
                        workspace.revertGitHunk(hunk, inPath: filePath)
                        loadDiffData()
                    }
                } label: {
                    Label("Revert Change", systemImage: "arrow.uturn.backward")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isApplyingGitChange)
                .foregroundStyle(StatusTone.failure.tint)
                .help("Revert this specific hunk (\(KeymapStore.shared.display("edit.undo")) in editor to undo)")
            }

            if canOpenInCodeEditor {
                Button {
                    workspace.clearCommitDiffContext()
                    workspace.setEditorMode(.code, for: filePath)
                    workspace.restoreCaretLocation(line: targetLine, column: 1, inPath: filePath)
                } label: {
                    Label("Line \(targetLine)", systemImage: "arrow.up.right.square")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Jump to Line \(targetLine) in Code Editor")
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    @ViewBuilder
    func diffLineContextMenu(_ line: AlignedLine, refs: [GitPatchLineRef]) -> some View {
        let targetLine = line.rightLineNum ?? max(1, line.targetNewLine)
        if canStageLines, !refs.isEmpty {
            let usesSelection = !selectedRefs.isDisjoint(with: refs)
            let isUnstage = stageVerb == "Unstage"
            Button(usesSelection ? "\(stageVerb) Selected Lines" : "\(stageVerb) Line", systemImage: isUnstage ? "minus.circle" : "plus.circle") {
                applyLines(usesSelection ? selectedRefs : Set(refs))
            }
            .disabled(isApplyingGitChange)
            Divider()
        }
        if canOpenInCodeEditor {
            Button("Jump to Line \(targetLine) in Code Editor", systemImage: "text.cursor") {
                jumpToDiffLineInCode(line)
            }
            Divider()
        }
        if let right = line.rightContent {
            Button("Copy New Line", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(right, forType: .string)
            }
        }
        if let left = line.leftContent {
            Button("Copy Original Line", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(left, forType: .string)
            }
        }
    }

    func jumpToDiffLineInCode(_ line: AlignedLine) {
        guard canOpenInCodeEditor else { return }
        let targetLine = line.rightLineNum ?? max(1, line.targetNewLine)
        workspace.clearCommitDiffContext()
        workspace.setEditorMode(.code, for: filePath)
        workspace.restoreCaretLocation(line: targetLine, column: 1, inPath: filePath)
    }

    func lineBackground(_ ref: GitPatchLineRef?, base: Color) -> Color {
        if let ref, selectedRefs.contains(ref) {
            return Color(nsColor: .controlAccentColor).opacity(0.28)
        }
        return base
    }

    func selectLine(_ ref: GitPatchLineRef?) {
        guard canStageLines else { return }
        guard let ref else {
            clearLineSelection()
            return
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor {
            let range = min(anchor, ref)...max(anchor, ref)
            selectedRefs = Set(changedRefs.filter { range.contains($0) })
        } else if flags.contains(.command) {
            toggleLines([ref])
        } else {
            selectedRefs = selectedRefs == [ref] ? [] : [ref]
            selectionAnchor = ref
        }
    }

    func toggleLines(_ refs: [GitPatchLineRef]) {
        guard canStageLines, !refs.isEmpty else { return }
        if refs.allSatisfy({ selectedRefs.contains($0) }) {
            selectedRefs.subtract(refs)
        } else {
            selectedRefs.formUnion(refs)
        }
        selectionAnchor = refs.last
    }

    func clearLineSelection() {
        selectedRefs = []
        selectionAnchor = nil
    }

    var changedRefs: [GitPatchLineRef] {
        guard let patch else { return [] }
        return patch.hunks.enumerated().flatMap { h, hunk in
            hunk.lines.indices.compactMap { l in
                hunk.lines[l].kind == .context ? nil : GitPatchLineRef(hunk: h, line: l)
            }
        }
    }

    func applyLines(_ refs: Set<GitPatchLineRef>) {
        guard let patch, !refs.isEmpty, !isApplyingGitChange else { return }
        let source = loadedSource
        let fullContext = loadedFullContext
        let path = filePath
        isApplyingGitChange = true
        Task { @MainActor in
            let applied = await workspace.applyGitLineSelection(refs, from: patch, inPath: path, source: source, fullContext: fullContext)
            isApplyingGitChange = false
            if applied {
                clearLineSelection()
            }
            loadDiffData()
        }
    }

    func scrollToCurrentHunkIfNeeded(proxy: ScrollViewProxy, animated: Bool) {
        guard !hunkAnchorLineIds.isEmpty else { return }
        let safeIdx = max(0, min(currentHunkIndex, hunkAnchorLineIds.count - 1))
        let targetId = hunkAnchorLineIds[safeIdx]
        if animated && !reduceMotion {
            withAnimation(reduceMotion ? nil : Motion.quick) {
                proxy.scrollTo(targetId, anchor: .top)
            }
        } else {
            proxy.scrollTo(targetId, anchor: .top)
        }
    }

    func loadDiffData() {
        loadTask?.cancel()
        if loadedFilePath != filePath && displayItems.isEmpty {
            isLoading = true
        }
        let path = filePath
        let collapseEnabled = self.workspace.git.collapseUnchangedInDiff
        let expandedIds = expandedBlockIds
        let needFullContext = !collapseEnabled || !expandedIds.isEmpty
        let baseTextColor: Color = ThemeColor.textPrimary
        let source = diffSource
        let workspace = self.workspace

        loadTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let output = await workspace.getFullDiff(for: path, fullContext: needFullContext, source: source)
            if Task.isCancelled { return }
            if let notice = GitDiffNotice.message(in: output) {
                await MainActor.run {
                    if !Task.isCancelled, self.filePath == path {
                        self.diffNotice = notice
                        self.displayItems = []
                        self.estimatedOriginalWidth = 0
                        self.estimatedModifiedWidth = 0
                        self.estimatedUnifiedWidth = 0
                        self.resetHorizontalScroll()
                        self.patch = nil
                        self.runRefs = [:]
                        self.addedCount = 0
                        self.removedCount = 0
                        self.hunkAnchorLineIds = []
                        self.clearLineSelection()
                        self.loadedFilePath = path
                        self.isLoading = false
                    }
                }
                return
            }

            let files = GitPatchBuilder.parse(output)
            let computed = buildDisplayDiffOffMainThread(
                files: files,
                collapseEnabled: collapseEnabled,
                expandedBlockIds: expandedIds,
                baseTextColor: baseTextColor
            )
            if Task.isCancelled { return }
            let headerOnlyNotice = computed.items.isEmpty ? GitDiffNotice.headerOnlyMessage(in: output) : nil
            let loadedPatch = files.count == 1 ? files[0] : nil

            await MainActor.run {
                if !Task.isCancelled, self.filePath == path {
                    self.diffNotice = headerOnlyNotice
                    self.displayItems = computed.items
                    self.estimatedOriginalWidth = computed.estimatedOriginalWidth
                    self.estimatedModifiedWidth = computed.estimatedModifiedWidth
                    self.estimatedUnifiedWidth = computed.estimatedUnifiedWidth
                    self.measuredOriginalWidth = 0
                    self.measuredModifiedWidth = 0
                    self.measuredUnifiedWidth = 0
                    self.originalScrollX = self.horizontalMetrics(original: true).clampedOffset
                    self.modifiedScrollX = self.horizontalMetrics(original: false).clampedOffset
                    self.unifiedScrollX = self.unifiedHorizontalMetrics.clampedOffset
                    self.addedCount = computed.addedCount
                    self.removedCount = computed.removedCount
                    self.hunkAnchorLineIds = computed.hunkAnchorIds
                    self.firstChangedLineNumber = computed.firstChangedLine
                    if loadedPatch != self.patch || source != self.loadedSource {
                        self.clearLineSelection()
                    }
                    self.patch = headerOnlyNotice == nil ? loadedPatch : nil
                    self.runRefs = computed.runRefs
                    self.loadedSource = source
                    self.loadedFullContext = needFullContext
                    if self.currentHunkIndex >= max(1, computed.hunkAnchorIds.count) {
                        self.currentHunkIndex = 0
                    }
                    self.loadedFilePath = path
                    self.isLoading = false
                }
            }
        }
    }
}
