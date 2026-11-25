import AppKit
import Foundation
import GoLensFoundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    static let recentProjectsKey = "GoLensRecentProjects"
    static let selectedThemeIdKey = "GoLensSelectedThemeId"
    static let maxRecentProjects = 10

    let themeManager: ThemeManager
    let keymapStore: KeymapStore
    let sandboxVMManager: SandboxVMManager
    let gitAccountStore: GitAccountStore
    let servicesStore: ServicesStore

    var recentProjects: [String] = []
    private(set) var menusReady = false
    var selectedThemeId: String {
        didSet {
            guard selectedThemeId != oldValue else { return }
            UserDefaults.standard.set(selectedThemeId, forKey: Self.selectedThemeIdKey)
            themeManager.applyAppIcon(themeId: selectedThemeId)
            WorkspaceSessionRegistry.shared.syncThemeSelection(selectedThemeId)
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.selectedThemeIdKey: "xcode"
        ])
        self.themeManager = ThemeManager.shared
        self.keymapStore = KeymapStore.shared
        self.sandboxVMManager = SandboxVMManager.shared
        self.gitAccountStore = GitAccountStore.shared
        self.servicesStore = ServicesStore.shared
        self.selectedThemeId = UserDefaults.standard.string(forKey: Self.selectedThemeIdKey) ?? "xcode"
        reloadRecentProjects()
    }

    func reloadRecentProjects() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? []
        let existing = stored.filter { path in
            if SecurityScopedBookmarkManager.shared.isSandboxed {
                return SecurityScopedBookmarkManager.shared.canAccess(path: path)
            }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        if existing != stored {
            UserDefaults.standard.set(existing, forKey: Self.recentProjectsKey)
        }
        recentProjects = existing
        WorkspaceSessionRegistry.shared.syncRecentProjects(existing)
    }

    func firstWindowDrawn() {
        guard !menusReady else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.menusReady = true
            AppUpdater.shared.start()
        }
    }

    func addRecentProject(_ rawPath: String) {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        guard !canonical.isEmpty else { return }
        var updated = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? []
        updated.removeAll { WorkspacePathCanonicalizer.canonical($0) == canonical || $0 == rawPath }
        updated.insert(canonical, at: 0)
        if updated.count > Self.maxRecentProjects {
            updated = Array(updated.prefix(Self.maxRecentProjects))
        }
        UserDefaults.standard.set(updated, forKey: Self.recentProjectsKey)
        recentProjects = updated
        WorkspaceSessionRegistry.shared.syncRecentProjects(updated)
    }

    func removeRecentProject(_ rawPath: String) {
        let canonical = WorkspacePathCanonicalizer.canonical(rawPath)
        SecurityScopedBookmarkManager.shared.removeBookmark(for: rawPath)
        if !canonical.isEmpty && canonical != rawPath {
            SecurityScopedBookmarkManager.shared.removeBookmark(for: canonical)
        }
        var updated = recentProjects
        updated.removeAll { WorkspacePathCanonicalizer.canonical($0) == canonical || $0 == rawPath }
        UserDefaults.standard.set(updated, forKey: Self.recentProjectsKey)
        recentProjects = updated
        WorkspaceSessionRegistry.shared.syncRecentProjects(updated)
    }

    func clearRecentProjects() {
        for path in recentProjects {
            SecurityScopedBookmarkManager.shared.removeBookmark(for: path)
        }
        UserDefaults.standard.removeObject(forKey: Self.recentProjectsKey)
        recentProjects = []
        WorkspaceSessionRegistry.shared.syncRecentProjects([])
    }

    func recentProjectTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let clashes = recentProjects.filter { ($0 as NSString).lastPathComponent == name }.count > 1
        guard clashes else { return name }
        return "\(name) — \(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)"
    }
}
