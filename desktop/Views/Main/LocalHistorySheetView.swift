import SwiftUI

struct LocalHistorySheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntryId: UUID?

    private var targetPath: String {
        workspace.localHistoryTargetPath
    }

    private var currentFileContent: String {
        if let doc = workspace.documents[targetPath] {
            return doc.storage.string
        }
        return (try? String(contentsOfFile: targetPath, encoding: .utf8)) ?? ""
    }

    private var selectedEntry: LocalHistoryEntry? {
        if let id = selectedEntryId {
            return workspace.localHistoryEntries.first(where: { $0.id == id })
        }
        return workspace.localHistoryEntries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if workspace.localHistoryEntries.isEmpty {
                ContentUnavailableView(
                    "No Local History Snapshots Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Snapshots are saved automatically whenever you save a file (⌘S) or before discarding Git changes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    snapshotListSidebar
                    Divider()
                    snapshotDiffDetail
                }
            }
            Divider()
            footerBar
        }
        .sheetFrame(.splitInspector)
        .onAppear {
            selectedEntryId = workspace.localHistoryEntries.first?.id
        }
        .onChange(of: workspace.localHistoryEntries) { _, entries in
            if selectedEntryId == nil || !entries.contains(where: { $0.id == selectedEntryId }) {
                selectedEntryId = entries.first?.id
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Local History — \((targetPath as NSString).lastPathComponent)")
                    .font(.body.weight(.semibold))
                Text(workspace.projectRelativePath(targetPath))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(workspace.localHistoryEntries.count) / \(WorkspaceState.maxLocalHistoryEntriesPerFile) snapshots")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private var snapshotListSidebar: some View {
        List(selection: $selectedEntryId) {
            ForEach(workspace.localHistoryEntries) { entry in
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    HStack(spacing: Spacing.row) {
                        Text(entry.label)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Self.relativeTimeString(for: entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.row) {
                        Text(Self.exactTimeString(for: entry.timestamp))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.lineCount) lines")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, Spacing.compact)
                .tag(entry.id)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 240)
    }

    private var snapshotDiffDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                let diffLines = Self.computeUnifiedPreview(snapshot: entry.content, current: currentFileContent)
                HStack {
                    Text("Snapshot from \(Self.exactTimeString(for: entry.timestamp)) (\(entry.label)) vs Current")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if entry.content == currentFileContent {
                        Text("Identical to current file")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.row)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

                Divider()

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diffLines.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: Spacing.standard) {
                                Text(row.prefixSymbol)
                                    .font(.subheadline.weight(.semibold).monospaced())
                                    .foregroundStyle(row.symbolColor)
                                    .frame(width: 14, alignment: .center)
                                Text(row.text.isEmpty ? " " : row.text)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(row.textColor)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.inset)
                            .padding(.vertical, Spacing.hairline)
                            .background(row.backgroundColor)
                        }
                    }
                    .padding(.vertical, Spacing.row)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        HStack {
            Text("Restoring automatically creates a 'Before Restore' snapshot of your current file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if let entry = selectedEntry {
                Button("Restore This Version") {
                    workspace.restoreLocalHistoryEntry(entry, for: targetPath) { restored in
                        if restored {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(entry.content == currentFileContent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private struct DiffPreviewLine {
        enum Kind { case same, snapshotOnly, currentOnly }
        let kind: Kind
        let text: String

        var prefixSymbol: String {
            switch kind {
            case .same: return " "
            case .snapshotOnly: return "-"
            case .currentOnly: return "+"
            }
        }

        var symbolColor: Color {
            switch kind {
            case .same: return .secondary
            case .snapshotOnly: return StatusTone.failure.tint
            case .currentOnly: return StatusTone.success.tint
            }
        }

        var textColor: Color {
            switch kind {
            case .same: return .primary
            case .snapshotOnly: return StatusTone.failure.tint
            case .currentOnly: return StatusTone.success.tint
            }
        }

        var backgroundColor: Color {
            switch kind {
            case .same: return .clear
            case .snapshotOnly: return StatusTone.failure.tint.opacity(0.10)
            case .currentOnly: return StatusTone.success.tint.opacity(0.10)
            }
        }
    }

    private static func computeUnifiedPreview(snapshot: String, current: String) -> [DiffPreviewLine] {
        let oldLines = snapshot.components(separatedBy: "\n")
        let newLines = current.components(separatedBy: "\n")
        if oldLines.count * newLines.count > 250_000 {
            return oldLines.prefix(600).map { DiffPreviewLine(kind: .same, text: $0) }
        }
        let diff = newLines.difference(from: oldLines)
        var removedSet = Set<Int>()
        var insertedMap: [Int: [String]] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedSet.insert(offset)
            case .insert(let offset, let element, _):
                insertedMap[offset, default: []].append(element)
            }
        }
        var result: [DiffPreviewLine] = []
        result.reserveCapacity(min(1200, oldLines.count + newLines.count))
        var newIdx = 0
        for oldIdx in 0..<oldLines.count {
            while let ins = insertedMap[newIdx] {
                for line in ins {
                    result.append(DiffPreviewLine(kind: .currentOnly, text: line))
                    newIdx += 1
                }
            }
            if removedSet.contains(oldIdx) {
                result.append(DiffPreviewLine(kind: .snapshotOnly, text: oldLines[oldIdx]))
            } else {
                result.append(DiffPreviewLine(kind: .same, text: oldLines[oldIdx]))
                newIdx += 1
            }
            if result.count >= 1200 { break }
        }
        while newIdx <= newLines.count {
            if let ins = insertedMap[newIdx] {
                for line in ins {
                    result.append(DiffPreviewLine(kind: .currentOnly, text: line))
                }
            }
            newIdx += 1
            if result.count >= 1200 { break }
        }
        return result
    }

    private static func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func exactTimeString(for date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }
}
