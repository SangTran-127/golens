import AppKit
import SwiftUI

struct AppContentView: View {
    @Binding var workspaceURL: URL?
    @State private var shouldCloseEmptyWindow = false
    @State private var boundSession: WorkspaceSession?
    @State private var boundURL: URL?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var appEnvironment: AppEnvironment {
        AppEnvironment.shared
    }

    private var sessionRegistry: WorkspaceSessionRegistry {
        WorkspaceSessionRegistry.shared
    }

    private var session: WorkspaceSession {
        if let boundSession, boundURL?.standardizedFileURL == workspaceURL?.standardizedFileURL {
            return boundSession
        }
        return sessionRegistry.session(for: workspaceURL)
    }

    var body: some View {
        let _ = measureStartupOnce("content-body")
        let currentSession = session
        let workspace = currentSession.workspace

        Group {
            if workspace.activeWorkspacePath.isEmpty {
                Color.clear
                    .background(EmptyWorkspaceWindowCloser(shouldClose: shouldCloseEmptyWindow))
            } else {
                MainLayoutView(workspace: workspace)
                    .environment(currentSession)
                    .environment(\.windowWorkspace, workspace)
                    .environment(appEnvironment)
            }
        }
        .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
        .onAppear {
            measureStartup("window-content")
            registerWindowHandlers()
            if workspaceURL == nil {
                let decision = sessionRegistry.claimColdLaunchDecision()
                if decision.shouldPresentWelcomeOnly {
                    openWindow(id: "welcome")
                    shouldCloseEmptyWindow = true
                    dismiss()
                } else if let claimedURL = decision.session.workspaceURL {
                    boundSession = decision.session
                    boundURL = claimedURL
                    workspaceURL = claimedURL
                }
            } else {
                boundSession = currentSession
                boundURL = workspaceURL
                sessionRegistry.activate(currentSession)
            }
        }
        .onChange(of: workspace.activeWorkspacePath) { _, newPath in
            guard !newPath.isEmpty else { return }
            let updatedURL = URL(fileURLWithPath: newPath, isDirectory: true)
            if workspaceURL?.standardizedFileURL != updatedURL.standardizedFileURL {
                boundSession = currentSession
                boundURL = updatedURL
                workspaceURL = updatedURL
            }
        }
    }

    private func registerWindowHandlers() {
        sessionRegistry.openWorkspaceWindowHandler = { url in
            openWindow(id: "workspace", value: url)
        }
        sessionRegistry.openWelcomeWindowHandler = {
            openWindow(id: "welcome")
        }
    }
}

private struct EmptyWorkspaceWindowCloser: NSViewRepresentable {
    let shouldClose: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if shouldClose {
            closeWindowIfNeeded(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if shouldClose {
            closeWindowIfNeeded(from: nsView)
        }
    }

    private func closeWindowIfNeeded(from view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.orderOut(nil)
            window.close()
        }
    }
}
