import SwiftUI

struct GitHunkMenuItems: View {
    @Bindable var workspace: WorkspaceState
    let isAvailable: Bool

    var body: some View {
        let line = max(1, workspace.cursorLine)
        let hasHunk = isAvailable && workspace.git.activeFileDiffs[line] != nil

        Button("Stage Change at Cursor", systemImage: "plus.circle") {
            workspace.stageGitHunkAtLine(nil, inPath: workspace.activeFilePath)
        }
        .keyboardShortcut(KeymapStore.shared.shortcut("git.stageHunk"))
        .disabled(!hasHunk)

        Button("Discard Change at Cursor", systemImage: "arrow.uturn.backward") {
            workspace.revertGitHunkAtLine(max(1, workspace.cursorLine), inPath: workspace.activeFilePath)
        }
        .keyboardShortcut(KeymapStore.shared.shortcut("git.revertHunk"))
        .disabled(!hasHunk)
    }
}
