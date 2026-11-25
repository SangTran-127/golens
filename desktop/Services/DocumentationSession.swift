import AppKit
import Foundation
import GoLensFoundation
import Observation

@MainActor
@Observable
final class DocumentationBrowserSession: Identifiable {
    let root: String
    nonisolated var id: String { root.isEmpty ? "__unbound__" : root }

    @ObservationIgnored weak var hostWindow: NSWindow?
    var isWorkspaceClosed = false
    var target: DocsTargetDTO
    var includeStd = false
    var includeUnexported = false

    var index: DocsIndexDTO?
    var isLoadingIndex = false
    var indexError: String?

    var currentRoute: DocsRoute?
    var currentPage: DocsPackageDocDTO?
    var isLoadingPage = false
    var pageError: String?

    var history = DocsHistoryStack()
    var pendingScrollTarget = ""
    var scrollRequestNonce = 0
    var staleReason: DocumentationStaleReason?
    var isStale: Bool { staleReason != nil }

    var searchQuery = ""
    var searchScope: DocsSearchScope = .all
    var searchResults: [DocsSearchResultDTO] = []
    var isSearching = false
    var isSearchResultsVisible = false
    var searchFocusTrigger = 0
    var pendingSearchFocus = false

    var pendingDownload: DocsPendingDownload?
    var isDownloading = false
    var downloadFailure: DocsDownloadFailure?
    var pendingExternalURL: URL?

    @ObservationIgnored private var indexSerial = 0
    @ObservationIgnored private var pageSerial = 0
    @ObservationIgnored private var searchSerial = 0
    @ObservationIgnored private var channelGenerations = DocsChannelGenerations()
    @ObservationIgnored private var activeIndexReqID = ""
    @ObservationIgnored private var activePageReqID = ""
    @ObservationIgnored private var activeSearchReqID = ""
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored var loadedDocVersions: [String: Int] = [:]
    @ObservationIgnored var loadedDiskStamps: [String: Date] = [:]

    init(root: String) {
        self.root = root
        self.target = Self.currentBuildTarget(includeStd: false, includeUnexported: false, scope: .all)
    }

    var workspaceName: String { root.isEmpty ? "Documentation Browser" : (root as NSString).lastPathComponent }
    var isRemoteTarget: Bool { SandboxVMManager.shared.executionMode == .linuxVM }

    var hasDirtyFilesInCurrentPackage: Bool {
        guard let dir = currentPage?.dir, !dir.isEmpty, let ws = owningWorkspace() else { return false }
        let canonDir = WorkspacePathCanonicalizer.canonical(dir)
        return ws.documents.contains { path, doc in
            doc.isEdited && WorkspacePathCanonicalizer.canonical((path as NSString).deletingLastPathComponent) == canonDir
        }
    }

    static func currentBuildTarget(includeStd: Bool, includeUnexported: Bool, scope: DocsSearchScope) -> DocsTargetDTO {
        let d = UserDefaults.standard
        var goos = d.string(forKey: "GoLensBuildGOOS") ?? ""
        if goos.isEmpty && SandboxVMManager.shared.executionMode == .linuxVM { goos = "linux" }
        return DocsTargetDTO(
            goos: goos,
            goarch: d.string(forKey: "GoLensBuildGOARCH") ?? "",
            tags: d.string(forKey: "GoLensBuildTags") ?? "",
            includeStd: includeStd,
            includeUnexported: includeUnexported,
            scope: scope.rawValue
        )
    }

    func owningWorkspace() -> WorkspaceState? {
        guard !root.isEmpty else { return nil }
        return WorkspaceSessionRegistry.shared.session(forWorkspacePath: root)?.workspace
    }

    func prepareOnOpen(route: DocsRoute? = nil, focusSearch: Bool = false) {
        syncWorkspaceOpenStatus()
        target = Self.currentBuildTarget(includeStd: includeStd, includeUnexported: includeUnexported, scope: searchScope)
        if let route {
            navigate(to: route, pushHistory: true, scrollAnchor: route.symbolAnchor)
        } else if index == nil && !root.isEmpty && !isLoadingIndex {
            refreshIndex(selectDefaultRouteIfNeeded: true)
        }
        if focusSearch { pendingSearchFocus = true }
    }

    func consumePendingSearchFocus() {
        guard pendingSearchFocus else { return }
        pendingSearchFocus = false
        DispatchQueue.main.async { [weak self] in
            self?.searchFocusTrigger &+= 1
        }
    }

    func syncWorkspaceOpenStatus() {
        isWorkspaceClosed = !root.isEmpty && owningWorkspace() == nil
    }

    func refreshIndex(selectDefaultRouteIfNeeded: Bool = false) {
        guard !root.isEmpty else { return }
        DocumentationFFI.cancel(reqID: activeIndexReqID)
        indexSerial &+= 1
        let serial = indexSerial
        let reqID = "idx-\(root.hashValue)-\(serial)"
        activeIndexReqID = reqID
        target = Self.currentBuildTarget(includeStd: includeStd, includeUnexported: includeUnexported, scope: searchScope)
        let expectedRoot = root
        let reqTarget = target
        isLoadingIndex = true
        indexError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dto = DocumentationFFI.listPackages(reqID: reqID, root: expectedRoot, target: reqTarget)
            DispatchQueue.main.async {
                guard let self,
                      serial == self.indexSerial,
                      expectedRoot == self.root,
                      reqTarget.targetKey == self.target.targetKey else { return }
                self.isLoadingIndex = false
                guard DocsRequestGuard.accepts(
                    expectedRoot: expectedRoot, expectedTargetKey: reqTarget.targetKey, expectedSerial: serial,
                    activeRoot: self.root, activeTargetKey: self.target.targetKey, activeSerial: self.indexSerial,
                    responseRoot: dto?.root, responseGeneration: dto?.generation,
                    minimumGeneration: self.channelGenerations.floor(for: .index), cancelled: dto?.cancelled
                ) else { return }
                guard let dto else {
                    self.indexError = "Couldn’t load package documentation for this workspace."
                    return
                }
                if let err = dto.error, !err.isEmpty { self.indexError = err }
                self.channelGenerations.record(dto.generation, for: .index)
                self.index = dto
                if selectDefaultRouteIfNeeded && self.currentRoute == nil,
                   let firstPkg = (dto.packages ?? []).first(where: { $0.origin == "project" }) ?? (dto.packages ?? []).first {
                    self.navigate(to: .package(importPath: firstPkg.importPath, symbol: nil), pushHistory: true)
                }
            }
        }
    }

    func navigate(to route: DocsRoute, pushHistory: Bool = true, scrollAnchor: String? = nil) {
        isSearchResultsVisible = false
        downloadFailure = nil
        if pushHistory {
            if !pendingScrollTarget.isEmpty { history.updateCurrentScrollTarget(pendingScrollTarget) }
            history.push(route, scrollTarget: scrollAnchor)
        }
        currentRoute = route
        pendingScrollTarget = scrollAnchor ?? route.symbolAnchor ?? ""
        scrollRequestNonce &+= 1
        switch route {
        case .module:
            if index == nil && !root.isEmpty && !isLoadingIndex { refreshIndex(selectDefaultRouteIfNeeded: false) }
        case .package(let importPath, _):
            if let currentPage, currentPage.importPath == importPath, staleReason == nil,
               currentPage.target.targetKey == target.targetKey,
               currentPage.includeUnexported == includeUnexported, !hasDirtyChangesComparedToLoaded(dir: currentPage.dir) {
                return
            }
            loadPackagePage(importPath: importPath, keepPreviousOnFailure: currentPage?.importPath == importPath)
        }
    }

    func goBack() {
        guard let entry = history.goBack() else { return }
        navigate(to: entry.route, pushHistory: false, scrollAnchor: entry.scrollTarget)
    }

    func goForward() {
        guard let entry = history.goForward() else { return }
        navigate(to: entry.route, pushHistory: false, scrollAnchor: entry.scrollTarget)
    }

    func refreshCurrent(saveDirtyFirst: Bool = false) {
        guard !root.isEmpty else { return }
        if saveDirtyFirst, let dir = currentPage?.dir, let ws = owningWorkspace() {
            let canonDir = WorkspacePathCanonicalizer.canonical(dir)
            let dirtyDocs = ws.documents.values.filter {
                $0.isEdited && WorkspacePathCanonicalizer.canonical(($0.path as NSString).deletingLastPathComponent) == canonDir
            }
            if !dirtyDocs.isEmpty {
                let group = DispatchGroup()
                for doc in dirtyDocs {
                    group.enter()
                    ws.save(doc, reportsFailure: true) { _ in group.leave() }
                }
                group.notify(queue: .main) { [weak self] in self?.performRefreshAfterInvalidation() }
                return
            }
        }
        performRefreshAfterInvalidation()
    }

    private func performRefreshAfterInvalidation() {
        DocumentationFFI.invalidate(root: root)
        refreshIndex(selectDefaultRouteIfNeeded: currentRoute == nil)
        if case .package(let importPath, _) = currentRoute {
            loadPackagePage(importPath: importPath, keepPreviousOnFailure: true)
        } else {
            staleReason = nil
        }
        if isSearchResultsVisible && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
    }

    private func loadPackagePage(importPath: String, keepPreviousOnFailure: Bool) {
        guard !root.isEmpty else { return }
        DocumentationFFI.cancel(reqID: activePageReqID)
        pageSerial &+= 1
        let serial = pageSerial
        let reqID = "page-\(root.hashValue)-\(serial)"
        activePageReqID = reqID
        target = Self.currentBuildTarget(includeStd: includeStd, includeUnexported: includeUnexported, scope: searchScope)
        let expectedRoot = root
        let reqTarget = target
        let overlay = collectPackageOverlay(forImportPath: importPath)
        isLoadingPage = true
        if !keepPreviousOnFailure { pageError = nil }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dto = DocumentationFFI.packagePage(reqID: reqID, root: expectedRoot, importPath: importPath, target: reqTarget, overlay: overlay)
            DispatchQueue.main.async {
                guard let self,
                      serial == self.pageSerial,
                      expectedRoot == self.root,
                      reqTarget.targetKey == self.target.targetKey else { return }
                self.isLoadingPage = false
                guard DocsRequestGuard.accepts(
                    expectedRoot: expectedRoot, expectedTargetKey: reqTarget.targetKey, expectedSerial: serial,
                    activeRoot: self.root, activeTargetKey: self.target.targetKey, activeSerial: self.pageSerial,
                    responseRoot: dto?.root, responseGeneration: dto?.generation,
                    minimumGeneration: self.channelGenerations.floor(for: .page), cancelled: dto?.cancelled
                ) else { return }
                guard let dto else {
                    let msg = "Couldn’t load documentation for \(importPath)."
                    if keepPreviousOnFailure && self.currentPage != nil { self.staleReason = .refreshFailed(msg) } else { self.pageError = msg }
                    return
                }
                self.channelGenerations.record(dto.generation, for: .page)
                let hasUsable = !(dto.funcs ?? []).isEmpty || !(dto.types ?? []).isEmpty || !(dto.consts ?? []).isEmpty || !(dto.vars ?? []).isEmpty || !(dto.doc ?? "").isEmpty || dto.missingSource == true || dto.errorKind == "buildConstraint"
                if let err = dto.error, !err.isEmpty, !hasUsable {
                    if keepPreviousOnFailure && self.currentPage != nil {
                        self.staleReason = .refreshFailed(err)
                    } else {
                        self.pageError = err
                        self.currentPage = dto
                    }
                    return
                }
                self.pageError = nil
                self.staleReason = nil
                self.currentPage = dto
                self.recordLoadedFileSnapshots(dir: dto.dir)
                self.scrollRequestNonce &+= 1
            }
        }
    }

    func handleTargetChanged() {
        let updated = Self.currentBuildTarget(includeStd: includeStd, includeUnexported: includeUnexported, scope: searchScope)
        guard updated.targetKey != target.targetKey else { return }
        target = updated
        if currentPage != nil { staleReason = .targetChanged }
        refreshIndex(selectDefaultRouteIfNeeded: false)
        if case .package(let importPath, _) = currentRoute { loadPackagePage(importPath: importPath, keepPreviousOnFailure: true) }
    }

    func handleManifestInvalidated() {
        if currentPage != nil { staleReason = .manifestChanged }
        refreshIndex(selectDefaultRouteIfNeeded: false)
        if case .package(let importPath, _) = currentRoute { loadPackagePage(importPath: importPath, keepPreviousOnFailure: true) }
    }

    func toggleIncludeStd() {
        includeStd.toggle()
        refreshIndex(selectDefaultRouteIfNeeded: false)
        if isSearchResultsVisible && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
    }

    func toggleIncludeUnexported() {
        includeUnexported.toggle()
        target = Self.currentBuildTarget(includeStd: includeStd, includeUnexported: includeUnexported, scope: searchScope)
        if case .package(let importPath, _) = currentRoute { loadPackagePage(importPath: importPath, keepPreviousOnFailure: true) }
        if isSearchResultsVisible && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
    }

    func updateSearchQuery(_ newValue: String) {
        searchQuery = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounceTask?.cancel()
        if trimmed.isEmpty {
            DocumentationFFI.cancel(reqID: activeSearchReqID)
            searchResults = []
            isSearching = false
            isSearchResultsVisible = false
            return
        }
        isSearchResultsVisible = true
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    func runSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !root.isEmpty else { searchResults = []; isSearching = false; return }
        DocumentationFFI.cancel(reqID: activeSearchReqID)
        searchSerial &+= 1
        let serial = searchSerial
        let reqID = "srch-\(root.hashValue)-\(serial)"
        activeSearchReqID = reqID
        target = Self.currentBuildTarget(includeStd: includeStd || searchScope == .stdlib, includeUnexported: includeUnexported, scope: searchScope)
        let expectedRoot = root
        let reqTarget = target
        isSearching = true
        isSearchResultsVisible = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dto = DocumentationFFI.search(reqID: reqID, root: expectedRoot, target: reqTarget, query: trimmed)
            DispatchQueue.main.async {
                guard let self,
                      serial == self.searchSerial,
                      expectedRoot == self.root,
                      reqTarget.targetKey == self.target.targetKey else { return }
                self.isSearching = false
                guard DocsRequestGuard.accepts(
                    expectedRoot: expectedRoot, expectedTargetKey: reqTarget.targetKey, expectedSerial: serial,
                    activeRoot: self.root, activeTargetKey: self.target.targetKey, activeSerial: self.searchSerial,
                    responseRoot: dto?.root, responseGeneration: dto?.generation,
                    minimumGeneration: self.channelGenerations.floor(for: .search), cancelled: dto?.cancelled
                ) else { return }
                self.channelGenerations.record(dto?.generation, for: .search)
                self.searchResults = dto?.results ?? []
            }
        }
    }

    func clearSearchAndFilters() {
        searchQuery = ""
        searchScope = .all
        searchResults = []
        isSearching = false
        isSearchResultsVisible = false
    }

    func openSource(file: String, line: Int = 1, column: Int = 1) {
        guard !file.isEmpty else { return }
        let ws = owningWorkspace() ?? WorkspaceSessionRegistry.shared.activeWorkspace
        if line > 0 { ws.jumpTo(filePath: file, line: line, column: max(1, column)) } else { ws.openFile(file) }
        ws.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestDownload(module: String, version: String) {
        guard !module.isEmpty else { return }
        pendingDownload = DocsPendingDownload(module: module, version: version)
    }

    func confirmDownloadDependency() {
        guard let item = pendingDownload, !root.isEmpty else { return }
        pendingDownload = nil
        downloadFailure = nil
        isDownloading = true
        let wsRoot = root
        let spec = item.version.isEmpty ? item.module : "\(item.module)@\(item.version)"
        DocumentationFFI.downloadModule(spec: spec, root: wsRoot) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloading = false
                switch result {
                case .success:
                    DocumentationFFI.invalidate(root: wsRoot)
                    self.refreshIndex(selectDefaultRouteIfNeeded: false)
                    if case .package(let p, _) = self.currentRoute { self.loadPackagePage(importPath: p, keepPreviousOnFailure: false) }
                case .failure(let failure):
                    self.downloadFailure = failure
                }
            }
        }
    }

    func requestOpenExternal(_ info: (url: URL, hasExactVersion: Bool)) {
        if info.hasExactVersion { NSWorkspace.shared.open(info.url) } else { pendingExternalURL = info.url }
    }

    func confirmOpenExternal() {
        guard let url = pendingExternalURL else { return }
        pendingExternalURL = nil
        NSWorkspace.shared.open(url)
    }
}
