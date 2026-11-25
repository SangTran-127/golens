import AppKit
import SwiftUI

private struct WindowWorkspaceKey: EnvironmentKey {
    static var defaultValue: WorkspaceState { WorkspaceState.shared }
}

extension EnvironmentValues {
    var windowWorkspace: WorkspaceState {
        get { self[WindowWorkspaceKey.self] }
        set { self[WindowWorkspaceKey.self] = newValue }
    }
}

extension WorkspaceState {
    static func shareSetting<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WorkspaceState, Value>, from source: WorkspaceState) {
        let value = source[keyPath: keyPath]
        for workspace in allRegisteredWorkspaces() where workspace !== source && workspace[keyPath: keyPath] != value {
            workspace[keyPath: keyPath] = value
        }
    }

    @MainActor
    static func owning(window: NSWindow?) -> WorkspaceState {
        guard let window else { return shared }
        let target = window.sheetParent ?? window
        return WorkspaceSessionRegistry.shared.sessions.first { $0.workspace.mainWindow === target }?.workspace ?? shared
    }
}

private struct WindowScope: ViewModifier {
    let workspace: WorkspaceState
    let session: WorkspaceSession?

    func body(content: Content) -> some View {
        if let session {
            content.environment(\.windowWorkspace, workspace).environment(session)
        } else {
            content.environment(\.windowWorkspace, workspace)
        }
    }
}

extension View {
    func windowScope(_ workspace: WorkspaceState, session: WorkspaceSession? = nil) -> some View {
        modifier(WindowScope(workspace: workspace, session: session))
    }
}
