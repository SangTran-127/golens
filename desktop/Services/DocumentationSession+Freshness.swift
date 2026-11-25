import Foundation
import GoLensFoundation

extension DocumentationBrowserSession {
    func collectPackageOverlay(forImportPath importPath: String) -> [String: String] {
        guard let ws = owningWorkspace(),
              let pkg = (index?.packages ?? []).first(where: { $0.importPath == importPath }),
              pkg.origin == "project" || pkg.source == "local-replace",
              let dir = pkg.dir, !dir.isEmpty else { return [:] }
        let canonDir = WorkspacePathCanonicalizer.canonical(dir)
        var out: [String: String] = [:]
        for (path, doc) in ws.documents where doc.isEdited && path.hasSuffix(".go") {
            if WorkspacePathCanonicalizer.canonical((path as NSString).deletingLastPathComponent) == canonDir {
                out[(dir as NSString).appendingPathComponent((path as NSString).lastPathComponent)] = doc.storage.string
            }
        }
        return out
    }

    func recordLoadedFileSnapshots(dir: String?) {
        loadedDocVersions.removeAll()
        loadedDiskStamps.removeAll()
        guard let dir, !dir.isEmpty else { return }
        let canonDir = WorkspacePathCanonicalizer.canonical(dir)
        if let ws = owningWorkspace() {
            for (path, doc) in ws.documents where path.hasSuffix(".go") {
                if WorkspacePathCanonicalizer.canonical((path as NSString).deletingLastPathComponent) == canonDir {
                    loadedDocVersions[WorkspacePathCanonicalizer.canonical(path)] = doc.version
                }
            }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for name in entries where name.hasSuffix(".go") {
                let p = (dir as NSString).appendingPathComponent(name)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p), let mod = attrs[.modificationDate] as? Date {
                    loadedDiskStamps[p] = mod
                }
            }
        }
    }

    func hasDirtyChangesComparedToLoaded(dir: String?) -> Bool {
        guard let dir, !dir.isEmpty else { return false }
        let canonDir = WorkspacePathCanonicalizer.canonical(dir)
        if let ws = owningWorkspace() {
            for (path, doc) in ws.documents where path.hasSuffix(".go") {
                if WorkspacePathCanonicalizer.canonical((path as NSString).deletingLastPathComponent) == canonDir {
                    if let prev = loadedDocVersions[WorkspacePathCanonicalizer.canonical(path)] {
                        if prev != doc.version { return true }
                    } else if doc.isEdited {
                        return true
                    }
                }
            }
        }
        for (path, prevDate) in loadedDiskStamps {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let mod = attrs[.modificationDate] as? Date, mod != prevDate {
                return true
            }
        }
        return false
    }

    func checkFreshness() {
        syncWorkspaceOpenStatus()
        guard staleReason == nil, let page = currentPage else { return }
        if hasDirtyChangesComparedToLoaded(dir: page.dir) { staleReason = .sourceChanged }
    }

    func packageSourceLocation(for page: DocsPackageDocDTO? = nil) -> DocsSourceLocation? {
        DocsSourceLocator.resolve(for: page ?? currentPage, index: index)
    }

    func openPackageSource(for page: DocsPackageDocDTO? = nil) {
        guard let loc = packageSourceLocation(for: page) else { return }
        openSource(file: loc.file, line: loc.line, column: loc.column)
    }
}
