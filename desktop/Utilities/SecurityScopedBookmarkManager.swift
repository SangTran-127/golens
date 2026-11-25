import Foundation

public final class SecurityScopedBookmarkManager: @unchecked Sendable {
    public static let shared = SecurityScopedBookmarkManager()

    private let lock = NSLock()
    private var activeScopedURLs: [String: URL] = [:]
    private let bookmarksKey = "GoLensSecurityScopedBookmarks"

    private init() {}

    public var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ||
        NSHomeDirectory().contains("/Library/Containers/")
    }

    public func createBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        let canonical = url.standardizedFileURL
        if let data = try? canonical.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        let resolved = canonical.resolvingSymlinksInPath()
        if let data = try? resolved.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        if let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        return try? resolved.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func saveBookmark(for url: URL) {
        guard let data = createBookmark(for: url) else { return }
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()

        lock.lock()
        defer { lock.unlock() }

        var stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        stored[url.path] = data
        stored[canonical.path] = data
        if resolved.path != canonical.path {
            stored[resolved.path] = data
        }
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
    }

    public func bookmarkData(for path: String) -> Data? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        lock.lock()
        defer { lock.unlock() }
        let stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        if let data = stored[path] {
            return data
        }
        if let data = stored[canonical.path] {
            return data
        }
        return stored[resolved.path]
    }

    public func resolveBookmark(data: Data, isStale: inout Bool) -> URL? {
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    @discardableResult
    public func resolveAndAccess(path: String) -> URL? {
        if let data = bookmarkData(for: path) {
            var isStale = false
            if let resolved = resolveBookmark(data: data, isStale: &isStale) {
                _ = startAccessing(url: resolved)
                if isStale {
                    saveBookmark(for: resolved)
                }
                return resolved
            }
        }

        let fallbackURL = URL(fileURLWithPath: path).standardizedFileURL
        if !isSandboxed {
            return fallbackURL
        }
        return nil
    }

    public func startAccessing(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let rawPath = url.path
        let canonicalPath = url.standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: canonicalPath).resolvingSymlinksInPath().path

        if activeScopedURLs[canonicalPath] != nil || activeScopedURLs[resolvedPath] != nil || activeScopedURLs[rawPath] != nil {
            return true
        }

        let success = url.startAccessingSecurityScopedResource()
        if success {
            activeScopedURLs[rawPath] = url
            activeScopedURLs[canonicalPath] = url
            if resolvedPath != canonicalPath {
                activeScopedURLs[resolvedPath] = url
            }
            return true
        }

        if !isSandboxed {
            return true
        }
        return false
    }

    public func stopAccessing(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        let rawPath = url.path
        let canonicalPath = url.standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: canonicalPath).resolvingSymlinksInPath().path

        let target = activeScopedURLs[canonicalPath] ?? activeScopedURLs[resolvedPath] ?? activeScopedURLs[rawPath] ?? url
        target.stopAccessingSecurityScopedResource()

        activeScopedURLs.removeValue(forKey: rawPath)
        activeScopedURLs.removeValue(forKey: canonicalPath)
        activeScopedURLs.removeValue(forKey: resolvedPath)
    }

    public func stopAllAccess() {
        lock.lock()
        defer { lock.unlock() }

        var stoppedPointers = Set<UnsafeRawPointer>()
        for scopedURL in activeScopedURLs.values {
            let ptr = Unmanaged.passUnretained(scopedURL as NSURL).toOpaque()
            if !stoppedPointers.contains(ptr) {
                stoppedPointers.insert(ptr)
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        activeScopedURLs.removeAll()
    }

    public func canAccess(path: String) -> Bool {
        if !isSandboxed {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        guard let data = bookmarkData(for: path) else { return false }
        var isStale = false
        return resolveBookmark(data: data, isStale: &isStale) != nil
    }

    public func removeBookmark(for path: String) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        lock.lock()
        defer { lock.unlock() }

        var stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        stored.removeValue(forKey: canonical.path)
        if resolved.path != canonical.path {
            stored.removeValue(forKey: resolved.path)
        }
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
    }
}
