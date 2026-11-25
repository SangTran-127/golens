import Foundation
import Observation
import GoLensFoundation

typealias ActiveCommandCapabilities = GoLensFoundation.ActiveCommandCapabilities

@Observable
final class CommandCapabilitiesStore: @unchecked Sendable {
    private(set) var current = ActiveCommandCapabilities()

    func update(
        workspacePath: String,
        filePath: String,
        canSave: Bool = false,
        isCodeMode: Bool = true,
        isDiffMode: Bool = false,
        canStageActiveFile: Bool = false,
        canUnstageActiveFile: Bool = false,
        isActiveFileConflicted: Bool = false,
        hasActiveFileGitChanges: Bool = false,
        hasDataSources: Bool = false,
        isAttachedConsole: Bool = false,
        canStopDatabaseStatement: Bool = false,
        isAttachedDataSourceConnected: Bool = false,
        isKubernetesManifest: Bool = false
    ) {
        let next = ActiveCommandCapabilities(
            workspacePath: workspacePath,
            filePath: filePath,
            canSave: canSave,
            isCodeMode: isCodeMode,
            isDiffMode: isDiffMode,
            canStageActiveFile: canStageActiveFile,
            canUnstageActiveFile: canUnstageActiveFile,
            isActiveFileConflicted: isActiveFileConflicted,
            hasActiveFileGitChanges: hasActiveFileGitChanges,
            hasDataSources: hasDataSources,
            isAttachedConsole: isAttachedConsole,
            canStopDatabaseStatement: canStopDatabaseStatement,
            isAttachedDataSourceConnected: isAttachedDataSourceConnected,
            isKubernetesManifest: isKubernetesManifest
        )
        if next != current {
            current = next
        }
    }
}
