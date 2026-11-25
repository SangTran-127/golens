import SwiftUI

struct MergeConflictBanner: View {
    let path: String
    var inSplitPane = false
    @Environment(\.windowWorkspace) private var workspace
    @State private var isMarking = false
    @State private var errorMessage: String?

    var body: some View {
        let count = workspace.mergeConflictCount(for: path)
        let treeConflict = workspace.isTreeOrBinaryMergeConflict(for: path)
        let isFileConflictOnly = treeConflict && count == 0
        InlineBanner(
            (count > 0 || isFileConflictOnly) ? .symbol("exclamationmark.circle.fill", tone: .failure) : .status(.success),
            title: isFileConflictOnly ? "File Conflict" : title(count),
            message: count > 0
                ? "Choose a side above each conflict, edit the text, or open the merge editor, then mark the file as resolved."
                : (isFileConflictOnly
                    ? "Modified on one branch and deleted or binary-changed on the other. Choose whether to keep or delete this file."
                    : "No conflict markers remain. Mark the file as resolved to stage it.")
        ) {
            if count > 0 {
                ControlGroup {
                    Button {
                        workspace.navigateMergeConflict(in: path, forward: false, inSplitPane: inSplitPane)
                    } label: {
                        Label("Previous Conflict", systemImage: "chevron.up")
                    }
                    .help("Previous Conflict")
                    Button {
                        workspace.navigateMergeConflict(in: path, forward: true, inSplitPane: inSplitPane)
                    } label: {
                        Label("Next Conflict", systemImage: "chevron.down")
                    }
                    .help("Next Conflict")
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                Button("Open in Merge Editor") { workspace.openMergeEditor(path) }
                    .help("Resolve every conflict side by side: Left, Result and Right")
            } else if isFileConflictOnly {
                let canKeep = FileManager.default.fileExists(atPath: path) || workspace.documentSession(forPath: path) != nil
                Button("Keep File") { keepFile() }
                    .disabled(isMarking || !canKeep)
                    .help(canKeep ? "Keep this file and stage it as resolved" : "File does not exist on disk or in the editor")
                Button("Delete File", role: .destructive) { deleteFile() }
                    .disabled(isMarking)
                    .help("Remove this file and stage its deletion as resolved")
            } else {
                Button("Mark “\((path as NSString).lastPathComponent)” as Resolved") { markResolved() }
                    .disabled(isMarking)
                    .help("Stage this file so git records the conflict as resolved")
            }
        }
        .alert("Couldn’t Mark as Resolved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func title(_ count: Int) -> String {
        switch count {
        case 0: return "All Conflicts Resolved"
        case 1: return "1 Conflict"
        default: return "\(count) Conflicts"
        }
    }

    private func markResolved() {
        isMarking = true
        Task { @MainActor in
            defer { isMarking = false }
            do {
                try await workspace.markMergeConflictResolved(path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func keepFile() {
        isMarking = true
        Task { @MainActor in
            defer { isMarking = false }
            do {
                try await workspace.keepConflictedFile(path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteFile() {
        isMarking = true
        Task { @MainActor in
            defer { isMarking = false }
            do {
                try await workspace.deleteConflictedFile(path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
