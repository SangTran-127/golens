import AppKit

enum ReferencesPhase: Equatable {
    case loading
    case loaded
    case failed(LSPRequestFailure)
}

enum NavigationOutcome {
    case perform(() -> Void)
    case list([LSPLocation], kind: String)
    case empty
}

final class NavigationRequest {
    let id = UUID()
    var task: Task<Void, Never>?
    var progressWorkItem: DispatchWorkItem?
    var showsPopup = false
    let retry: () -> Void

    init(retry: @escaping () -> Void) {
        self.retry = retry
    }
}

extension WorkspaceState {
    static let navigationProgressDelay: TimeInterval = 0.5

    var languageServerIsLoading: Bool {
        switch languageServerState {
        case .starting, .indexing, .restarting: return true
        default: return false
        }
    }

    func updateLanguageServerConditions(reportedRemote: Bool?) {
        let vmRunning: Bool
        if Thread.isMainThread {
            vmRunning = MainActor.assumeIsolated {
                SandboxVMManager.shared.executionMode == .linuxVM && SandboxVMManager.shared.isRunning
            }
        } else {
            vmRunning = LSPServerConditionsStore.shared.current.isRemote
        }
        let isRemote = reportedRemote ?? vmRunning
        LSPServerConditionsStore.shared.update(LSPServerConditions(isRemote: isRemote, isLoading: languageServerIsLoading))
    }

    func languageServerDidBecomeReady() {
        guard !activeWorkspacePath.isEmpty else { return }
        codeLensVersions.removeAll()
        if let textView = activeTextView as? GoLensTextView, !textView.filePath.isEmpty, documents[textView.filePath] != nil {
            reloadCodeLens(forPath: textView.filePath, textView: textView)
        }
        fetchDocumentSymbols()
    }

    func runNavigationRequest(kind: String, symbol: String, showProgressImmediately: Bool = false, request: @escaping (_ setKind: @escaping (String) -> Void) async -> Result<NavigationOutcome, LSPRequestFailure>) {
        let replacesStatus = showReferences && referencesPhase != .loaded
        cancelPendingNavigationRequest()
        let navigation = NavigationRequest { [weak self] in
            self?.runNavigationRequest(kind: kind, symbol: symbol, showProgressImmediately: true, request: request)
        }
        navigationRequest = navigation
        let showProgress = { [weak self, weak navigation] in
            guard let self, let navigation, self.navigationRequest === navigation else { return }
            navigation.showsPopup = true
            self.referencesResults = []
            self.referencesSymbolName = symbol
            self.referencesPopupKind = kind
            self.referencesPhase = .loading
            self.showReferences = true
        }
        if showProgressImmediately || replacesStatus {
            showProgress()
        } else {
            let work = DispatchWorkItem(block: showProgress)
            navigation.progressWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationProgressDelay, execute: work)
        }
        let setKind: (String) -> Void = { [weak self, weak navigation] newKind in
            DispatchQueue.main.async {
                guard let self, let navigation, self.navigationRequest === navigation else { return }
                self.referencesPopupKind = newKind
            }
        }
        navigation.task = Task { [weak self, weak navigation] in
            let result = await request(setKind)
            await MainActor.run {
                guard let self, let navigation, self.navigationRequest === navigation else { return }
                self.finishNavigationRequest(navigation, symbol: symbol, kind: kind, result: result)
            }
        }
    }

    private func finishNavigationRequest(_ navigation: NavigationRequest, symbol: String, kind: String, result: Result<NavigationOutcome, LSPRequestFailure>) {
        navigation.progressWorkItem?.cancel()
        let popupVisible = navigation.showsPopup && showReferences
        switch result {
        case .success(.perform(let action)):
            navigationRequest = nil
            if popupVisible { showReferences = false }
            action()
        case .success(.list(let locations, let listKind)):
            navigationRequest = nil
            referencesPhase = .loaded
            showReferences(locations, for: symbol, kind: listKind)
        case .success(.empty):
            navigationRequest = nil
            if popupVisible {
                referencesResults = []
                referencesPhase = .loaded
            } else {
                let targetDesc = symbol == "symbol" ? "the symbol at the cursor" : "“\(symbol)”"
                presentCommandFeedback("No \(kind.lowercased()) found for \(targetDesc).", title: kind)
            }
        case .failure(let failure) where failure.isSilent:
            navigationRequest = nil
            if popupVisible { showReferences = false }
        case .failure(let failure):
            navigation.task = nil
            navigation.showsPopup = true
            referencesResults = []
            referencesSymbolName = symbol
            if !popupVisible { referencesPopupKind = kind }
            referencesPhase = .failed(failure)
            showReferences = true
        }
    }

    func retryNavigationRequest() {
        guard let navigation = navigationRequest, case .failed = referencesPhase else { return }
        navigation.retry()
    }

    func cancelPendingNavigationRequest() {
        guard let navigation = navigationRequest else { return }
        navigation.progressWorkItem?.cancel()
        navigation.task?.cancel()
        navigationRequest = nil
    }

    func referencesPopupDidClose() {
        if navigationRequest?.showsPopup == true {
            cancelPendingNavigationRequest()
        }
        if referencesPhase != .loaded {
            referencesPhase = .loaded
        }
    }

    static func locationsOutcome(_ result: Result<[LSPLocation], LSPRequestFailure>, kind: String, jump: @escaping (LSPLocation) -> Void) -> Result<NavigationOutcome, LSPRequestFailure> {
        result.map { locations in
            if locations.count == 1, let only = locations.first {
                return .perform { jump(only) }
            }
            return locations.isEmpty ? .empty : .list(locations, kind: kind)
        }
    }
}
