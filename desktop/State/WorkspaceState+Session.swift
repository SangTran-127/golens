import AppKit

struct SavedWorkspaceTabSession: Codable {
    struct View: Codable {
        var caret: Int
        var scrollY: Double
    }
    var files: [String]
    var active: String
    var secondary: String?
    var views: [String: View]
    var saved: Date
}

extension WorkspaceState {
    static let sessionsKey = "GoLensWorkspaceSessions"
    static let maxStoredSessions = 20
    static let maxStoredTabs = 50

    private static func loadSessions() -> [String: SavedWorkspaceTabSession] {
        UserDefaults.standard.data(forKey: sessionsKey).flatMap { try? JSONDecoder().decode([String: SavedWorkspaceTabSession].self, from: $0) } ?? [:]
    }

    func scheduleSessionSave() {
        guard !isClosingAllDocuments, !openedWorkspaceRoot.isEmpty else { return }
        sessionSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveSession() {
        sessionSaveWorkItem?.cancel()
        let root = openedWorkspaceRoot
        guard !root.isEmpty else { return }
        if let tv = activeTextView as? GoLensTextView, let doc = tv.document {
            doc.lastSelection = tv.selectedRange()
            doc.lastScrollOrigin = tv.enclosingScrollView?.contentView.bounds.origin ?? .zero
        }
        var files = Array(openFiles.suffix(Self.maxStoredTabs))
        if !activeFilePath.isEmpty, !files.contains(activeFilePath), openFiles.contains(activeFilePath) {
            files.removeFirst()
            files = openFiles.filter { $0 == activeFilePath || files.contains($0) }
        }
        var views: [String: SavedWorkspaceTabSession.View] = restoredViewStates
        for path in files {
            if let doc = documents[path] {
                views[path] = .init(caret: doc.lastSelection.location, scrollY: doc.lastScrollOrigin.y)
            }
        }
        views = views.filter { files.contains($0.key) }
        var sessions = Self.loadSessions()
        sessions[root] = SavedWorkspaceTabSession(files: files, active: activeFilePath, secondary: isSplitMode ? secondaryFilePath : nil, views: views, saved: Date())
        if sessions.count > Self.maxStoredSessions {
            for key in sessions.sorted(by: { $0.value.saved < $1.value.saved }).prefix(sessions.count - Self.maxStoredSessions).map(\.key) {
                sessions.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    func restoreSession(for root: String) {
        guard let session = Self.loadSessions()[root] else { return }
        let fm = FileManager.default
        let isRestorable: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return path.hasPrefix(root + "/") && fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
        let files = session.files.filter(isRestorable)
        guard !files.isEmpty else { return }
        restoredViewStates = session.views.filter { files.contains($0.key) }
        openFiles = files
        activeFilePath = files.contains(session.active) ? session.active : files[files.count - 1]
        if let secondary = session.secondary, isRestorable(secondary) {
            loadDocument(secondary)
            secondaryFilePath = secondary
            isSplitMode = true
        }
    }
}
