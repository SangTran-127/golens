import Foundation
import Observation

@Observable
final class BackgroundFFI {
    @ObservationIgnored static let shared = BackgroundFFI()

    @ObservationIgnored private let queue = DispatchQueue(
        label: "dev.golens.background-ffi",
        qos: .userInitiated,
        attributes: .concurrent
    )
    @ObservationIgnored private var generations: [AnyHashable: UInt64] = [:]
    @ObservationIgnored private var debounced: [AnyHashable: DispatchWorkItem] = [:]
    @ObservationIgnored private var pendingSync: [AnyHashable: () -> Void] = [:] {
        didSet { syncPendingKeys() }
    }
    @ObservationIgnored private var lastStart: [AnyHashable: DispatchTime] = [:]
    private(set) var pendingKeys: Set<AnyHashable> = []

    private init() {}

    func run<T>(
        _ key: AnyHashable,
        debounce: TimeInterval = 0,
        work: @escaping () -> T,
        deliver: @escaping (T) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation = bump(key)
        pendingSync[key] = { deliver(work()) }

        let start = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounced[key] = nil
            guard self.generations[key] == generation else { return }
            self.lastStart[key] = .now()
            self.queue.async {
                let result = work()
                DispatchQueue.main.async {
                    guard self.generations[key] == generation else { return }
                    self.pendingSync[key] = nil
                    deliver(result)
                }
            }
        }
        if debounce > 0, let last = lastStart[key], DispatchTime.now() < last + debounce {
            debounced[key] = start
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: start)
        } else {
            start.perform()
        }
    }

    func isPending(_ key: AnyHashable) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return pendingKeys.contains(key)
    }

    private func syncPendingKeys() {
        let keys = Set(pendingSync.keys)
        if keys != pendingKeys {
            pendingKeys = keys
        }
    }

    func flush(_ key: AnyHashable) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let job = pendingSync[key] else { return }
        bump(key)
        job()
    }

    func cancel(_ key: AnyHashable) {
        dispatchPrecondition(condition: .onQueue(.main))
        bump(key)
    }

    @discardableResult
    private func bump(_ key: AnyHashable) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(.main))
        let next = (generations[key] ?? 0) &+ 1
        generations[key] = next
        debounced.removeValue(forKey: key)?.cancel()
        pendingSync[key] = nil
        return next
    }

    static func callString(_ input: String, _ fn: (UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?) -> String? {
        input.withCString { cInput in
            guard let ptr = fn(UnsafeMutablePointer(mutating: cInput)) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
