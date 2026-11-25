import AppKit
import Foundation
import GoLensFoundation
import Observation

@MainActor
@Observable
final class WorkspaceSession: Identifiable {
    let sessionID: UUID
    var id: UUID { sessionID }
    let workspace: WorkspaceState
    var workspaceURL: URL?

    var router: WindowPresentationRouter {
        workspace.router
    }

    init(
        sessionID: UUID = UUID(),
        workspace: WorkspaceState,
        workspaceURL: URL? = nil
    ) {
        self.sessionID = sessionID
        self.workspace = workspace
        self.workspaceURL = workspaceURL
    }
}

@MainActor
@Observable
final class WorkspaceSessionRegistry {
    static let shared = WorkspaceSessionRegistry()

    let primarySession: WorkspaceSession
    private(set) var sessions: [WorkspaceSession]
    private(set) var activeSession: WorkspaceSession?
    let coordinator = WorkspaceSessionCoordinator()

    var showWelcomeNewProjectSheet: Bool = false

    @ObservationIgnored
    private var didClaimColdLaunchWindow = false
    @ObservationIgnored
    var activeCoreWorkspacePath: String = ""
    @ObservationIgnored
    var openWorkspaceWindowHandler: ((URL) -> Void)?
    @ObservationIgnored
    var openWelcomeWindowHandler: (() -> Void)?
    @ObservationIgnored
    private var windowObserversInstalled = false
    private var isTerminating = false

    var activeWorkspace: WorkspaceState {
        (activeSession ?? primarySession).workspace
    }

    private init() {
        let initialWorkspace = WorkspaceState(restoreLastOnSetup: true)
        let initialSession = WorkspaceSession(workspace: initialWorkspace)
        self.primarySession = initialSession
        self.sessions = [initialSession]
        self.activeSession = initialSession
        WorkspaceState.setActiveShared(initialWorkspace)
        coordinator.registerSession(id: initialSession.sessionID, makeActive: true)
        bindSessionCallbacks(initialSession)
        installWindowLifecycleObserversIfNeeded()
    }

    private func bindSessionCallbacks(_ session: WorkspaceSession) {
        let sessionID = session.sessionID
        session.router.onActiveSheetChanged = { [weak self] sheet in
            guard let self else { return }
            if let record = self.coordinator.sessions.first(where: { $0.id == sessionID }) {
                record.activeSheetKind = sheet?.kind
            }
        }
    }

    private func installWindowLifecycleObserversIfNeeded() {
        guard !windowObserversInstalled else { return }
        windowObserversInstalled = true

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self,
                      let session = self.sessions.first(where: { $0.workspace.mainWindow === window }) else {
                    return
                }
                self.activate(session)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(window)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isTerminating = true
            }
        }
    }

    func claimColdLaunchDecision() -> (session: WorkspaceSession, shouldPresentWelcomeOnly: Bool) {
        if !didClaimColdLaunchWindow {
            didClaimColdLaunchWindow = true
            primarySession.workspace.setup()
            let path = WorkspacePathCanonicalizer.canonical(primarySession.workspace.activeWorkspacePath)
            if !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                primarySession.workspaceURL = url
                coordinator.updateWorkspacePath(path, for: primarySession.sessionID)
                activate(primarySession)
                return (primarySession, false)
            }
            return (primarySession, true)
        }
        return (primarySession, primarySession.workspace.activeWorkspacePath.isEmpty)
    }

    func session(for workspaceURL: URL?) -> WorkspaceSession {
        guard let workspaceURL else {
            return primarySession
        }
        let canonical = WorkspacePathCanonicalizer.canonical(workspaceURL.path)
        guard !canonical.isEmpty else {
            return primarySession
        }
        if let existing = session(forWorkspacePath: canonical) {
            if existing.workspaceURL == nil {
                existing.workspaceURL = URL(fileURLWithPath: canonical, isDirectory: true)
            }
            return existing
        }
        if primarySession.workspace.activeWorkspacePath.isEmpty && primarySession.workspace.mainWindow == nil {
            let resolvedURL = URL(fileURLWithPath: canonical, isDirectory: true)
            primarySession.workspaceURL = resolvedURL
            primarySession.workspace.setup(opening: canonical)
            primarySession.workspace.activeWorkspacePath = canonical
            coordinator.updateWorkspacePath(canonical, for: primarySession.sessionID)
            activate(primarySession)
            return primarySession
        }
        return createSession(forCanonicalPath: canonical)
    }

    func session(forWorkspacePath rawPath: String) -> WorkspaceSession? {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        guard !canonical.isEmpty else { return nil }
        return sessions.first {
            WorkspacePathCanonicalizer.canonical($0.workspace.activeWorkspacePath) == canonical
                || ($0.workspaceURL.map { WorkspacePathCanonicalizer.canonical($0.path) == canonical } ?? false)
        }
    }

    @discardableResult
    func createSession(forCanonicalPath rawPath: String = "") -> WorkspaceSession {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        if !canonical.isEmpty, let existing = session(forWorkspacePath: canonical) {
            return existing
        }
        let ws = WorkspaceState(restoreLastOnSetup: false)
        let resolvedURL = canonical.isEmpty ? nil : URL(fileURLWithPath: canonical, isDirectory: true)
        let session = WorkspaceSession(workspace: ws, workspaceURL: resolvedURL)
        sessions.append(session)
        coordinator.registerSession(id: session.sessionID, workspacePath: canonical, makeActive: true)
        bindSessionCallbacks(session)
        ws.setup()
        if !canonical.isEmpty {
            ws.activeWorkspacePath = canonical
        }
        activate(session)
        return session
    }

    func activate(_ session: WorkspaceSession) {
        if activeSession?.sessionID != session.sessionID {
            activeSession = session
        }
        WorkspaceState.setActiveShared(session.workspace)
        coordinator.activate(sessionID: session.sessionID)
        let canonical = WorkspacePathCanonicalizer.canonical(session.workspace.activeWorkspacePath)
        coordinator.updateWorkspacePath(canonical, for: session.sessionID)
        guard !canonical.isEmpty else { return }
        UserDefaults.standard.set(canonical, forKey: "GoLensLastWorkspacePath")
        if !session.workspace.activeFilePath.isEmpty {
            UserDefaults.standard.set(session.workspace.activeFilePath, forKey: "GoLensLastFilePath")
        }
        if activeCoreWorkspacePath != canonical {
            activeCoreWorkspacePath = canonical
            SetUsageIndexEnabled(WorkspaceState.usageCountsEnabled ? 1 : 0)
            canonical.withCString { OpenWorkspace($0) }
            session.workspace.syncVisibleDocuments()
        }
    }

    func notifyWorkspaceDidChange(for workspace: WorkspaceState, canonicalPath: String) {
        guard let session = sessions.first(where: { $0.workspace === workspace }) else { return }
        session.workspaceURL = canonicalPath.isEmpty ? nil : URL(fileURLWithPath: canonicalPath, isDirectory: true)
        coordinator.updateWorkspacePath(canonicalPath, for: session.sessionID)
        if !canonicalPath.isEmpty {
            activeCoreWorkspacePath = canonicalPath
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak workspace] in
                guard let workspace, workspace.activeWorkspacePath == canonicalPath else { return }
                MainActor.assumeIsolated { UnsavedBufferJournal.shared.offerRecovery(for: workspace, workspacePath: canonicalPath) }
            }
        }
    }

    var hasAnyOpenWorkspace: Bool {
        sessions.contains { !$0.workspace.activeWorkspacePath.isEmpty }
    }

    func workspace(containingPath rawPath: String) -> WorkspaceState? {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        guard !canonical.isEmpty else { return nil }
        var best: WorkspaceSession?
        var bestLength = -1
        for candidate in sessions {
            let root = WorkspacePathCanonicalizer.canonical(candidate.workspace.activeWorkspacePath)
            guard !root.isEmpty else { continue }
            if WorkspacePathCanonicalizer.contains(workspaceRoot: root, targetPath: canonical),
               root.count > bestLength {
                best = candidate
                bestLength = root.count
            }
        }
        return best?.workspace
    }

    func workspace(owningTerminalID terminalID: String) -> WorkspaceState? {
        sessions.first { $0.workspace.terminalEngines[terminalID] != nil }?.workspace
    }

    func sessionsWithUnsavedDocuments() -> [WorkspaceSession] {
        sessions.filter { session in
            session.workspace.openFiles.contains { session.workspace.documents[$0]?.isEdited == true }
        }
    }

    func syncRecentProjects(_ updated: [String]) {
        for session in sessions where session.workspace.recentProjects != updated {
            session.workspace.recentProjects = updated
        }
    }

    func syncThemeSelection(_ themeId: String) {
        for session in sessions {
            if session.workspace.selectedThemeId != themeId {
                session.workspace.selectedThemeId = themeId
            } else {
                session.workspace.activeTextView?.needsDisplay = true
                session.workspace.updateWindowAppearance()
            }
        }
    }

    func presentWorkspacePickerWindow() {
        if let welcomeWin = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" || $0.title == "Welcome to GoLens" }) {
            welcomeWin.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWelcomeWindowHandler?()
    }

    func closeWelcomeWindowIfPresent() {
        if let welcomeWin = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" || $0.title == "Welcome to GoLens" }) {
            if let sheet = welcomeWin.attachedSheet {
                welcomeWin.endSheet(sheet)
            }
            welcomeWin.close()
        }
    }

    func openProject(at rawPath: String, then: @escaping (WorkspaceState) -> Void = { _ in }) {
        _ = SecurityScopedBookmarkManager.shared.resolveAndAccess(path: rawPath)
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        var isDir: ObjCBool = false
        guard !canonical.isEmpty,
              FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir),
              isDir.boolValue else {
            AppEnvironment.shared.removeRecentProject(rawPath)
            activeWorkspace.appendLog("Project directory no longer exists: \(rawPath)")
            let workspace = activeWorkspace
            workspace.presentFailure(
                "Couldn’t Open “\((rawPath as NSString).lastPathComponent)”",
                "The folder no longer exists at \(rawPath), so it was removed from Open Recent. If you moved it, open it from its new location.",
                recovery: ("Open Project…", { workspace.pickDirectory() })
            )
            return
        }

        let targetURL = URL(fileURLWithPath: canonical, isDirectory: true)
        SecurityScopedBookmarkManager.shared.saveBookmark(for: targetURL)
        AppEnvironment.shared.addRecentProject(canonical)

        if let existing = session(forWorkspacePath: canonical) {
            activate(existing)
            if let win = existing.workspace.mainWindow {
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWorkspaceWindowHandler?(targetURL)
            }
            closeWelcomeWindowIfPresent()
            then(existing.workspace)
            return
        }

        if let emptyVisible = sessions.first(where: { $0.workspace.activeWorkspacePath.isEmpty && $0.workspace.mainWindow != nil }) {
            emptyVisible.workspaceURL = targetURL
            emptyVisible.workspace.setup()
            emptyVisible.workspace.activeWorkspacePath = canonical
            activate(emptyVisible)
            emptyVisible.workspace.mainWindow?.makeKeyAndOrderFront(nil)
            closeWelcomeWindowIfPresent()
            then(emptyVisible.workspace)
            return
        }

        if primarySession.workspace.activeWorkspacePath.isEmpty && primarySession.workspace.mainWindow == nil {
            primarySession.workspaceURL = targetURL
            primarySession.workspace.setup(opening: canonical)
            primarySession.workspace.activeWorkspacePath = canonical
            coordinator.updateWorkspacePath(canonical, for: primarySession.sessionID)
            activate(primarySession)
            openWorkspaceWindowHandler?(targetURL)
            closeWelcomeWindowIfPresent()
            then(primarySession.workspace)
            return
        }

        let dedicated = createSession(forCanonicalPath: canonical)
        openWorkspaceWindowHandler?(targetURL)
        closeWelcomeWindowIfPresent()
        then(dedicated.workspace)
    }

    private func handleWindowWillClose(_ window: NSWindow) {
        guard !isTerminating, let session = sessions.first(where: { $0.workspace.mainWindow === window }) else {
            return
        }
        session.workspace.mainWindow = nil
        for path in session.workspace.editedFiles {
            UnsavedBufferJournal.forget(path)
        }
        if session.sessionID != primarySession.sessionID {
            session.workspace.teardownClosedSessionWindow()
            sessions.removeAll { $0.sessionID == session.sessionID }
            coordinator.removeSession(id: session.sessionID)
            if activeSession?.sessionID == session.sessionID {
                if let fallback = sessions.last(where: { !$0.workspace.activeWorkspacePath.isEmpty }) ?? sessions.first {
                    activate(fallback)
                }
            }
        } else if let otherOpen = sessions.first(where: { $0.sessionID != primarySession.sessionID && !$0.workspace.activeWorkspacePath.isEmpty }) {
            primarySession.workspace.teardownClosedSessionWindow()
            primarySession.workspaceURL = nil
            coordinator.updateWorkspacePath("", for: primarySession.sessionID)
            activate(otherOpen)
        }
        if !hasAnyOpenWorkspace {
            activeCoreWorkspacePath = ""
        }
    }
}
