import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var isStarted: Bool { controller != nil }

    var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                start()?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    @discardableResult
    func start() -> SPUStandardUpdaterController? {
        guard isAvailable else { return nil }
        if let controller { return controller }
        let created = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = created
        canCheckForUpdates = created.updater.canCheckForUpdates
        canCheckObservation = created.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        return created
    }

    func checkForUpdates() {
        start()?.checkForUpdates(nil)
    }
}
