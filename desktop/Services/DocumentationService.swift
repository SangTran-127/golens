import AppKit
import Foundation
import GoLensFoundation
import Observation

enum DocumentationStaleReason: Equatable {
    case sourceChanged
    case targetChanged
    case manifestChanged
    case refreshFailed(String)
}

struct DocsPendingDownload: Identifiable, Equatable {
    let module: String
    let version: String
    var id: String { "\(module)@\(version)" }
}

struct DocsDownloadFailure: Identifiable, Equatable, Error {
    let module: String
    let version: String
    let summary: String
    let details: String
    var id: String { "\(module)@\(version)" }
}

enum DocumentationFFI {
    static func targetJSON(_ target: DocsTargetDTO) -> String {
        guard let data = try? JSONEncoder().encode(target), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func listPackages(reqID: String, root: String, target: DocsTargetDTO) -> DocsIndexDTO? {
        let jsonTarget = targetJSON(target)
        let raw: String? = reqID.withCString { cReq in
            root.withCString { cRoot in
                jsonTarget.withCString { cTarget in
                    guard let ptr = DocsListPackages(cReq, cRoot, cTarget) else { return nil }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocsIndexDTO.self, from: data)
    }

    static func packagePage(reqID: String, root: String, importPath: String, target: DocsTargetDTO, overlay: [String: String]) -> DocsPackageDocDTO? {
        let jsonTarget = targetJSON(target)
        let jsonOverlay: String = {
            guard !overlay.isEmpty, let data = try? JSONEncoder().encode(overlay) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }()
        let raw: String? = reqID.withCString { cReq in
            root.withCString { cRoot in
                importPath.withCString { cPkg in
                    jsonTarget.withCString { cTarget in
                        jsonOverlay.withCString { cOv in
                            guard let ptr = DocsPackagePage(cReq, cRoot, cPkg, cTarget, cOv) else { return nil }
                            defer { FreeGoCString(ptr) }
                            return String(cString: ptr)
                        }
                    }
                }
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocsPackageDocDTO.self, from: data)
    }

    static func search(reqID: String, root: String, target: DocsTargetDTO, query: String, limit: Int32 = 200) -> DocsSearchResponseDTO? {
        let jsonTarget = targetJSON(target)
        let raw: String? = reqID.withCString { cReq in
            root.withCString { cRoot in
                jsonTarget.withCString { cTarget in
                    query.withCString { cQuery in
                        guard let ptr = DocsSearch(cReq, cRoot, cTarget, cQuery, limit) else { return nil }
                        defer { FreeGoCString(ptr) }
                        return String(cString: ptr)
                    }
                }
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocsSearchResponseDTO.self, from: data)
    }

    static func cancel(reqID: String) {
        guard !reqID.isEmpty else { return }
        reqID.withCString { DocsCancel($0) }
    }

    static func invalidate(root: String) {
        root.withCString { DocsInvalidate($0) }
    }

    static func downloadModule(spec: String, root: String, completion: @escaping @Sendable (Result<Void, DocsDownloadFailure>) -> Void) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let modName = parts.first ?? spec
        let modVer = parts.count > 1 ? parts[1] : ""
        DispatchQueue.global(qos: .userInitiated).async {
            let goPath: String = "go".withCString { cName in
                guard let ptr = FindTool(cName) else { return "/usr/local/go/bin/go" }
                defer { FreeGoCString(ptr) }
                let resolved = String(cString: ptr)
                return resolved.isEmpty ? "/usr/local/go/bin/go" : resolved
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: goPath)
            proc.arguments = ["mod", "download", spec]
            proc.currentDirectoryURL = URL(fileURLWithPath: root)
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let details = DocsErrorSanitizer.redact(errText.isEmpty ? "go mod download exited with status \(proc.terminationStatus)." : errText)
                    completion(.failure(DocsDownloadFailure(module: modName, version: modVer, summary: "Couldn’t download this dependency.", details: details)))
                }
            } catch {
                completion(.failure(DocsDownloadFailure(module: modName, version: modVer, summary: "Couldn’t download this dependency.", details: DocsErrorSanitizer.redact(error.localizedDescription))))
            }
        }
    }
}

@MainActor
@Observable
final class DocumentationService {
    static let shared = DocumentationService()

    private(set) var sessionsByRoot: [String: DocumentationBrowserSession] = [:]
    let unboundSession = DocumentationBrowserSession(root: "")

    @ObservationIgnored var openWindowHandler: ((String) -> Void)?
    @ObservationIgnored private var observersInstalled = false

    private init() {
        installObserversIfNeeded()
    }

    func session(forWorkspaceRoot rawRoot: String) -> DocumentationBrowserSession {
        let canon = WorkspacePathCanonicalizer.canonical(rawRoot)
        guard !canon.isEmpty else { return unboundSession }
        if let existing = sessionsByRoot[canon] {
            existing.syncWorkspaceOpenStatus()
            return existing
        }
        let created = DocumentationBrowserSession(root: canon)
        sessionsByRoot[canon] = created
        return created
    }

    func session(for workspace: WorkspaceState?) -> DocumentationBrowserSession {
        guard let workspace, !workspace.activeWorkspacePath.isEmpty else { return unboundSession }
        return session(forWorkspaceRoot: workspace.activeWorkspacePath)
    }

    func registerOpenWindowHandler(_ handler: @escaping (String) -> Void) {
        openWindowHandler = handler
    }

    func openBrowser(for workspace: WorkspaceState?, route: DocsRoute? = nil, focusSearch: Bool = false) {
        let targetSession = session(for: workspace)
        targetSession.prepareOnOpen(route: route, focusSearch: focusSearch)
        if let win = targetSession.hostWindow, win.isVisible || win.isMiniaturized {
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            targetSession.consumePendingSearchFocus()
        } else {
            openWindowHandler?(targetSession.root)
        }
    }

    func openFromHover(
        workspace: WorkspaceState,
        rawMarkdown: String,
        signature: String?,
        filePath: String,
        symbolIndex: Int?,
        line: Int? = nil,
        column: Int? = nil
    ) {
        let targetSession = self.session(for: workspace)
        let dir = filePath.isEmpty ? "" : WorkspacePathCanonicalizer.canonical((filePath as NSString).deletingLastPathComponent)
        let dirPkg = Self.packageImportPath(in: targetSession.index, matchingDir: dir)
        let resolved = DocsHoverResolver.resolve(rawMarkdown: rawMarkdown, signature: signature, activeFileDirPackage: dirPkg)
        if let importPath = resolved.importPath {
            openBrowser(for: workspace, route: .package(importPath: importPath, symbol: resolved.symbolName))
            return
        }
        openBrowser(for: workspace, route: nil)
        guard !filePath.isEmpty,
              let coords = Self.cursorCoordinates(workspace: workspace, filePath: filePath, symbolIndex: symbolIndex, line: line, column: column) else { return }
        let expectedRoot = targetSession.root
        let reqTarget = targetSession.target
        let sym = resolved.symbolName

        Task {
            let locs = await LSPClient.shared.requestDefinition(atLine: coords.line, col: coords.column, inPath: filePath)
            let defDir = locs.first.map { WorkspacePathCanonicalizer.canonical(($0.path as NSString).deletingLastPathComponent) } ?? dir
            var loadedIndex = await MainActor.run { self.session(forWorkspaceRoot: expectedRoot).index }
            if loadedIndex == nil && !expectedRoot.isEmpty {
                loadedIndex = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: DocumentationFFI.listPackages(reqID: "hover-\(expectedRoot.hashValue)", root: expectedRoot, target: reqTarget))
                    }
                }
            }
            await MainActor.run {
                let s = self.session(forWorkspaceRoot: expectedRoot)
                if s.index == nil, let loadedIndex { s.index = loadedIndex }
                if let pkg = Self.packageImportPath(in: s.index, matchingDir: defDir) {
                    s.navigate(to: .package(importPath: pkg, symbol: sym))
                } else if let sym, !s.root.isEmpty {
                    s.updateSearchQuery(sym)
                }
            }
        }
    }

    private static func packageImportPath(in index: DocsIndexDTO?, matchingDir dir: String) -> String? {
        guard !dir.isEmpty else { return nil }
        return (index?.packages ?? []).first { pkg in
            guard let pkgDir = pkg.dir, !pkgDir.isEmpty else { return false }
            return WorkspacePathCanonicalizer.canonical(pkgDir) == dir
        }?.importPath
    }

    private static func cursorCoordinates(workspace: WorkspaceState, filePath: String, symbolIndex: Int?, line: Int?, column: Int?) -> (line: Int, column: Int)? {
        if let line, let column { return (line, column) }
        guard let symbolIndex, let doc = workspace.documents[filePath] else { return nil }
        let text = doc.storage.string as NSString
        let before = text.substring(to: min(max(0, symbolIndex), text.length))
        let parts = before.components(separatedBy: "\n")
        return (parts.count, (parts.last?.utf16.count ?? 0) + 1)
    }

    func invalidate(root: String) {
        let canon = WorkspacePathCanonicalizer.canonical(root)
        guard !canon.isEmpty else { return }
        DocumentationFFI.invalidate(root: canon)
        sessionsByRoot[canon]?.handleManifestInvalidated()
    }

    func notifyBuildTargetChanged(root: String) {
        let canon = WorkspacePathCanonicalizer.canonical(root)
        guard !canon.isEmpty else { return }
        sessionsByRoot[canon]?.handleTargetChanged()
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(forName: .golensBuildTargetChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionsByRoot.values.forEach { $0.handleTargetChanged() } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let closed = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessionsByRoot.values where session.hostWindow === closed { session.hostWindow = nil }
                if self.unboundSession.hostWindow === closed { self.unboundSession.hostWindow = nil }
                DispatchQueue.main.async { self.sessionsByRoot.values.forEach { $0.syncWorkspaceOpenStatus() } }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let keyWindow = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.sessionsByRoot.values.first(where: { $0.hostWindow === keyWindow })?.checkFreshness()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionsByRoot.values.forEach { $0.checkFreshness() } }
        }
    }
}
