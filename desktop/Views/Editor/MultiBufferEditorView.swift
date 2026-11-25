import SwiftUI
import AppKit
import CryptoKit

public struct MultiBufferChunkDTO: Codable {
    public let id: String
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let lines: String
    public let originalHash: String
    public let matchLines: [Int]?
}

public struct MultiBufferFileDTO: Codable {
    public let filePath: String
    public let relativePath: String
    public let originalSHA256: String
    public let chunks: [MultiBufferChunkDTO]
}

public struct MultiBufferResultDTO: Codable {
    public let query: String?
    public let files: [MultiBufferFileDTO]
    public let totalHits: Int
    public let totalFiles: Int
    public let error: String?
}

public struct MultiBufferEditDTO: Codable {
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let newLines: String
    public let originalHash: String?
}

public struct MultiBufferFileEditDTO: Codable {
    public let filePath: String
    public let originalSHA256: String?
    public let edits: [MultiBufferEditDTO]
}

public struct ApplyResultDTO: Codable {
    public let success: Bool
    public let filesModified: [String]
    public let undoSnapshot: [MultiBufferFileEditDTO]?
    public let errorMessage: String?
    public let conflictFile: String?
}

public struct MultiBufferChunkState: Identifiable, Equatable {
    public let id: String
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let originalLines: String
    public var currentLines: String
    public let originalHash: String
    public let matchLines: [Int]

    public var isDirty: Bool {
        currentLines != originalLines
    }
}

public struct MultiBufferFileState: Identifiable, Equatable {
    public var id: String { filePath }
    public let filePath: String
    public let relativePath: String
    public let originalSHA256: String
    public var chunks: [MultiBufferChunkState]
    public var isExpanded: Bool = true

    public var isDirty: Bool {
        chunks.contains(where: \.isDirty)
    }

    public var totalMatches: Int {
        chunks.reduce(0) { $0 + ($1.matchLines.isEmpty ? 1 : $1.matchLines.count) }
    }
}

public struct MultiBufferEditorView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.colorScheme) private var colorScheme

    @State private var fileStates: [MultiBufferFileState] = []
    @State private var isDiffPreview: Bool = false
    @State private var conflictFile: String? = nil
    @State private var conflictMessage: String? = nil
    @State private var undoSnapshots: [MultiBufferFileEditDTO] = []
    @State private var isSaving: Bool = false
    @State private var statusMessage: String = ""
    @State private var isShowingDiscardConfirmation: Bool = false

    private var dirtyFileCount: Int {
        fileStates.filter(\.isDirty).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let conflict = conflictFile, let msg = conflictMessage {
                conflictBanner(file: conflict, message: msg)
            }

            if fileStates.isEmpty {
                emptyStateView
            } else {
                contentScrollView
            }

            Divider()
            bottomToolbar
        }
        .sheetFrame(.multiBuffer)
        .onAppear {
            loadFromWorkspace()
        }
        .interactiveDismissDisabled(dirtyFileCount > 0)
        .confirmationDialog(
            "Discard Unsaved Multi-Buffer Edits?",
            isPresented: $isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save All Changes") {
                saveAllChanges(closeOnSuccess: true)
            }
            Button("Discard Edits", role: .destructive) {
                revertAllEdits()
                workspace.isMultiBufferOpen = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved edits across \(dirtyFileCount) \(dirtyFileCount == 1 ? "file" : "files").")
        }
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.comfortable) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .font(.body)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.row) {
                    Text("Multi-Buffer Editor")
                        .font(.body.weight(.semibold))
                    if !workspace.multiBufferTitle.isEmpty {
                        Text("— \(workspace.multiBufferTitle)")
                            .font(.callout)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                let totalFiles = fileStates.count
                let totalMatches = fileStates.reduce(0) { $0 + $1.totalMatches }
                Text("\(totalMatches) match\(totalMatches == 1 ? "" : "es") across \(totalFiles) file\(totalFiles == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Spacer()

            Toggle(isOn: $isDiffPreview) {
                Label("Diff Preview", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle side-by-side or inline diff against original contents")
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private func conflictBanner(file: String, message: String) -> some View {
        InlineBanner(
            .status(.warning),
            title: "External File Modification Conflict",
            message: message,
            onClose: {
                conflictFile = nil
                conflictMessage = nil
            }
        ) {
            Button("Reload from Disk") {
                reloadConflictFile(file)
            }
            Button("Overwrite Disk File") {
                forceOverwriteConflictFile(file)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.standard) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text("No matches to edit")
                .font(.body.weight(.medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.comfortable) {
                ForEach($fileStates) { $fileState in
                    fileSectionView(file: $fileState)
                }
            }
            .padding(Spacing.section)
        }
    }

    private func fileSectionView(file: Binding<MultiBufferFileState>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Button {
                    file.wrappedValue.isExpanded.toggle()
                } label: {
                    Image(systemName: file.wrappedValue.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(file.wrappedValue.isExpanded ? "Collapse File" : "Expand File")
                .help(file.wrappedValue.isExpanded ? "Collapse" : "Expand")

                FileIconView(fileName: (file.wrappedValue.filePath as NSString).lastPathComponent,
                             path: file.wrappedValue.filePath, isSelected: false, size: 16)

                Text(file.wrappedValue.relativePath)
                    .font(.callout.weight(.medium).monospaced())
                    .foregroundStyle(Color(nsColor: .labelColor))

                if file.wrappedValue.isDirty {
                    Circle()
                        .fill(StatusTone.warning.tint)
                        .frame(width: 6, height: 6)
                        .help("Contains unsaved modifications")
                }

                Spacer()

                Text("\(file.wrappedValue.totalMatches) match\(file.wrappedValue.totalMatches == 1 ? "" : "es")")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())

                Button {
                    workspace.jumpTo(filePath: file.wrappedValue.filePath, line: file.wrappedValue.chunks.first?.startLine ?? 1, column: 1)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Jump to this file in main editor")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.standard)
            .background(ThemeColor.wellFill)

            if file.wrappedValue.isExpanded {
                Divider()
                VStack(spacing: Spacing.comfortable) {
                    ForEach(file.chunks) { $chunk in
                        chunkCardView(chunk: $chunk)
                    }
                }
                .padding(Spacing.comfortable)
            }
        }
        .background(ThemeColor.wellFill, in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
        )
    }

    private func chunkCardView(chunk: Binding<MultiBufferChunkState>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack {
                Text("Lines \(chunk.wrappedValue.startLine)–\(chunk.wrappedValue.endLine)")
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                if chunk.wrappedValue.isDirty {
                    Text("Edited")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StatusTone.warning.tint)
                }

                Spacer()

                Button {
                    workspace.jumpTo(filePath: chunk.wrappedValue.filePath, line: chunk.wrappedValue.startLine, column: 1)
                } label: {
                    Text("Jump")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(.bottom, Spacing.hairline)

            if isDiffPreview {
                diffLinesView(original: chunk.wrappedValue.originalLines, current: chunk.wrappedValue.currentLines)
            } else {
                TextEditor(text: chunk.currentLines)
                    .font(.callout.monospaced())
                    .frame(minHeight: max(CGFloat(chunk.wrappedValue.currentLines.components(separatedBy: "\n").count * 18), 44))
                    .padding(Spacing.row)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline)
                    )
            }
        }
        .padding(Spacing.standard)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
    }

    private enum LineDiffKind {
        case context
        case added
        case removed
    }

    private struct LineDiffEntry: Identifiable {
        let id: Int
        let kind: LineDiffKind
        let text: String
    }

    private func buildPositionalDiff(original: String, current: String) -> [LineDiffEntry] {
        let origLines = original.components(separatedBy: "\n")
        let curLines = current.components(separatedBy: "\n")
        let diff = curLines.difference(from: origLines)

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var entries: [LineDiffEntry] = []
        entries.reserveCapacity(origLines.count + insertedOffsets.count)
        var origIdx = 0
        var curIdx = 0
        var nextId = 0

        while origIdx < origLines.count || curIdx < curLines.count {
            while origIdx < origLines.count && removedOffsets.contains(origIdx) {
                entries.append(LineDiffEntry(id: nextId, kind: .removed, text: origLines[origIdx]))
                nextId += 1
                origIdx += 1
            }
            while curIdx < curLines.count && insertedOffsets.contains(curIdx) {
                entries.append(LineDiffEntry(id: nextId, kind: .added, text: curLines[curIdx]))
                nextId += 1
                curIdx += 1
            }
            if origIdx < origLines.count && curIdx < curLines.count {
                entries.append(LineDiffEntry(id: nextId, kind: .context, text: curLines[curIdx]))
                nextId += 1
                origIdx += 1
                curIdx += 1
            }
        }
        return entries
    }

    private func diffLinesView(original: String, current: String) -> some View {
        let entries = buildPositionalDiff(original: original, current: current)

        return VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(entries) { entry in
                let prefix: String = switch entry.kind {
                case .removed: "-"
                case .added: "+"
                case .context: " "
                }
                let prefixColor: Color = switch entry.kind {
                case .removed: StatusTone.failure.tint
                case .added: StatusTone.success.tint
                case .context: Color(nsColor: .secondaryLabelColor)
                }
                let textColor: Color = switch entry.kind {
                case .removed: StatusTone.failure.tint
                case .added: StatusTone.success.tint
                case .context: Color(nsColor: .labelColor)
                }
                let bgColor: Color = switch entry.kind {
                case .removed: StatusTone.failure.fill
                case .added: StatusTone.success.fill
                case .context: Color.clear
                }

                HStack(spacing: Spacing.compact) {
                    Text(prefix)
                        .foregroundStyle(prefixColor)
                    Text(entry.text)
                        .foregroundStyle(textColor)
                }
                .font(.subheadline.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgColor)
            }
        }
        .padding(Spacing.row)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    private var bottomToolbar: some View {
        let dirtyCount = dirtyFileCount
        let totalDirtyChunks = fileStates.reduce(0) { $0 + $1.chunks.filter(\.isDirty).count }

        return HStack(spacing: Spacing.comfortable) {
            if dirtyCount > 0 {
                Text("\(dirtyCount) file\(dirtyCount == 1 ? "" : "s") modified (\(totalDirtyChunks) unsaved edit\(totalDirtyChunks == 1 ? "" : "s"))")
                    .font(.subheadline)
                    .foregroundStyle(StatusTone.warning.tint)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else {
                Text("All changes saved")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Spacer()

            if !undoSnapshots.isEmpty {
                Button {
                    performUndo()
                } label: {
                    Label("Undo Last Save", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.regular)
                .keyboardShortcut(KeymapStore.shared.shortcut("edit.undo"))
                .help("Revert last atomic batch save across all files (\(KeymapStore.shared.display("edit.undo")))")
            }

            Button("Revert All") {
                revertAllEdits()
            }
            .controlSize(.regular)
            .disabled(dirtyCount == 0)

            Button("Close") {
                requestClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.cancelAction)

            Button {
                saveAllChanges()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save All Changes")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(dirtyCount == 0 || isSaving)
            .keyboardShortcut(KeymapStore.shared.shortcut("file.save"))
            .help("Bottom-up atomic batch save across all modified files (\(KeymapStore.shared.display("file.save")))")
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requestClose() {
        if dirtyFileCount > 0 {
            isShowingDiscardConfirmation = true
        } else {
            workspace.isMultiBufferOpen = false
        }
    }

    private func loadFromWorkspace() {
        guard let res = workspace.multiBufferResult else { return }
        fileStates = res.files.map { file in
            MultiBufferFileState(
                filePath: file.filePath,
                relativePath: file.relativePath,
                originalSHA256: file.originalSHA256,
                chunks: file.chunks.map { chunk in
                    MultiBufferChunkState(
                        id: chunk.id,
                        filePath: chunk.filePath,
                        startLine: chunk.startLine,
                        endLine: chunk.endLine,
                        originalLines: chunk.lines,
                        currentLines: chunk.lines,
                        originalHash: chunk.originalHash,
                        matchLines: chunk.matchLines ?? []
                    )
                }
            )
        }
    }

    private func revertAllEdits() {
        for fIdx in fileStates.indices {
            for cIdx in fileStates[fIdx].chunks.indices {
                fileStates[fIdx].chunks[cIdx].currentLines = fileStates[fIdx].chunks[cIdx].originalLines
            }
        }
        statusMessage = "All edits reverted to original"
    }

    private func saveAllChanges(closeOnSuccess: Bool = false) {
        isSaving = true
        statusMessage = "Saving changes…"
        conflictFile = nil
        conflictMessage = nil

        let dirtyFiles = fileStates.filter(\.isDirty)
        var fileEdits: [MultiBufferFileEditDTO] = []

        for df in dirtyFiles {
            var edits: [MultiBufferEditDTO] = []
            for chunk in df.chunks where chunk.isDirty {
                edits.append(MultiBufferEditDTO(
                    filePath: chunk.filePath,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    newLines: chunk.currentLines,
                    originalHash: chunk.originalHash
                ))
            }
            fileEdits.append(MultiBufferFileEditDTO(
                filePath: df.filePath,
                originalSHA256: df.originalSHA256,
                edits: edits
            ))
        }

        guard let payloadData = try? JSONEncoder().encode(fileEdits),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            isSaving = false
            statusMessage = "Couldn’t save the edits. Try again."
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cJson = payloadJSON.cString(using: .utf8),
                  let resPtr = ApplyGoMultiBufferEdits(cJson) else {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusMessage = "Couldn’t save the edits. Try again."
                }
                return
            }
            defer { FreeGoCString(resPtr) }

            let jsonStr = String(cString: resPtr)
            let applyResult = try? JSONDecoder().decode(ApplyResultDTO.self, from: Data(jsonStr.utf8))

            DispatchQueue.main.async {
                self.isSaving = false
                guard let res = applyResult else {
                    self.statusMessage = "Unknown error from core engine"
                    return
                }

                if res.success {
                    let modifiedPaths = Set(res.filesModified)
                    for fIdx in self.fileStates.indices {
                        let currentFile = self.fileStates[fIdx]
                        guard modifiedPaths.contains(currentFile.filePath) || currentFile.isDirty else {
                            continue
                        }
                        let diskData = try? Data(contentsOf: URL(fileURLWithPath: currentFile.filePath))
                        let refreshedSHA = diskData.map(Self.sha256Hex) ?? ""
                        let diskLines = diskData
                            .flatMap { String(data: $0, encoding: .utf8) }?
                            .components(separatedBy: "\n")

                        let sortedIndices = currentFile.chunks.indices.sorted {
                            currentFile.chunks[$0].startLine < currentFile.chunks[$1].startLine
                        }
                        var updatedChunks = currentFile.chunks
                        var cumDelta = 0

                        for cIdx in sortedIndices {
                            let chunk = currentFile.chunks[cIdx]
                            let oldCount = chunk.endLine - chunk.startLine + 1
                            let editedLines = chunk.currentLines.components(separatedBy: "\n")
                            let newStart = chunk.startLine + cumDelta
                            let newEnd = newStart + editedLines.count - 1
                            cumDelta += editedLines.count - oldCount

                            if let diskLines, newStart >= 1, newEnd <= diskLines.count, newStart <= newEnd {
                                let slice = diskLines[(newStart - 1)..<newEnd].joined(separator: "\n")
                                let sliceHash = Self.sha256Hex(Data(slice.utf8))
                                updatedChunks[cIdx] = MultiBufferChunkState(
                                    id: chunk.id,
                                    filePath: chunk.filePath,
                                    startLine: newStart,
                                    endLine: newEnd,
                                    originalLines: slice,
                                    currentLines: slice,
                                    originalHash: sliceHash,
                                    matchLines: chunk.matchLines
                                )
                            } else {
                                let curr = chunk.currentLines
                                updatedChunks[cIdx] = MultiBufferChunkState(
                                    id: chunk.id,
                                    filePath: chunk.filePath,
                                    startLine: newStart,
                                    endLine: newEnd,
                                    originalLines: curr,
                                    currentLines: curr,
                                    originalHash: "",
                                    matchLines: chunk.matchLines
                                )
                            }
                        }

                        self.fileStates[fIdx] = MultiBufferFileState(
                            filePath: currentFile.filePath,
                            relativePath: currentFile.relativePath,
                            originalSHA256: refreshedSHA,
                            chunks: updatedChunks,
                            isExpanded: currentFile.isExpanded
                        )
                    }
                    if let undos = res.undoSnapshot {
                        self.undoSnapshots = undos
                    }
                    self.statusMessage = "Saved \(UserMessage.count(res.filesModified.count, "file"))"
                    if closeOnSuccess {
                        self.workspace.isMultiBufferOpen = false
                    }
                } else {
                    self.conflictFile = res.conflictFile
                    self.conflictMessage = res.errorMessage ?? "Save aborted"
                    self.statusMessage = "Save failed: \(res.errorMessage ?? "conflict")"
                }
            }
        }
    }

    private func performUndo() {
        guard let undo = undoSnapshots.last else { return }
        guard let data = try? JSONEncoder().encode([undo]),
              let json = String(data: data, encoding: .utf8) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cJson = json.cString(using: .utf8),
                  let ptr = ApplyGoMultiBufferEdits(cJson) else { return }
            defer { FreeGoCString(ptr) }

            DispatchQueue.main.async {
                self.undoSnapshots.removeLast()
                self.workspace.refreshMultiBuffer()
                self.loadFromWorkspace()
                self.statusMessage = "Reverted last save"
            }
        }
    }

    private func reloadConflictFile(_ file: String) {
        workspace.refreshMultiBuffer()
        loadFromWorkspace()
        conflictFile = nil
        conflictMessage = nil
        statusMessage = "Reloaded \((file as NSString).lastPathComponent) from disk"
    }

    private func forceOverwriteConflictFile(_ file: String) {
        for idx in fileStates.indices where fileStates[idx].filePath == file {
            fileStates[idx] = MultiBufferFileState(
                filePath: fileStates[idx].filePath,
                relativePath: fileStates[idx].relativePath,
                originalSHA256: "",
                chunks: fileStates[idx].chunks.map { c in
                    MultiBufferChunkState(
                        id: c.id,
                        filePath: c.filePath,
                        startLine: c.startLine,
                        endLine: c.endLine,
                        originalLines: c.originalLines,
                        currentLines: c.currentLines,
                        originalHash: "",
                        matchLines: c.matchLines
                    )
                }
            )
        }
        conflictFile = nil
        conflictMessage = nil
        saveAllChanges()
    }
}
