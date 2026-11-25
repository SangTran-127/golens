import Foundation
import GopilotProvider

public final class CompletionScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ProviderClock
    private var current: Task<Void, Never>?
    private var generation = 0
    private var runningGeneration: Int?

    public init(clock: ProviderClock = SystemProviderClock()) {
        self.clock = clock
    }

    public var isBusy: Bool {
        lock.withLock { current != nil }
    }

    public var isRequestInFlight: Bool {
        lock.withLock { runningGeneration != nil }
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> Int {
        let clock = self.clock
        return lock.withLock {
            current?.cancel()
            generation += 1
            let mine = generation
            runningGeneration = nil
            current = Task { [weak self] in
                do {
                    if delay > 0 { try await clock.sleep(seconds: delay) }
                } catch {
                    return
                }
                guard let self, self.begin(mine) else { return }
                await work()
                self.end(mine)
            }
            return mine
        }
    }

    public func cancel() {
        lock.withLock {
            current?.cancel()
            current = nil
            generation += 1
            runningGeneration = nil
        }
    }

    public func isCurrent(_ token: Int) -> Bool {
        lock.withLock { token == generation }
    }

    private func begin(_ token: Int) -> Bool {
        lock.withLock {
            guard token == generation, !Task.isCancelled else { return false }
            runningGeneration = token
            return true
        }
    }

    private func end(_ token: Int) {
        lock.withLock {
            guard token == generation else { return }
            runningGeneration = nil
            current = nil
        }
    }
}

public enum CompletionPause: Sendable, Equatable {
    case until(Date, reason: String)
    case untilSettingsChange(reason: String)

    public var reason: String {
        switch self {
        case .until(_, let reason), .untilSettingsChange(let reason): return reason
        }
    }
}

public struct CompletionBackoff: Sendable, Equatable {
    public static let rateLimitDefaultSeconds: TimeInterval = 10
    public static let maximumPauseSeconds: TimeInterval = 60
    public static let failuresBeforePause = 2

    public private(set) var consecutiveFailures = 0
    public private(set) var pause: CompletionPause?

    public init() {}

    public func isPaused(at now: Date) -> Bool {
        switch pause {
        case .none: return false
        case .untilSettingsChange: return true
        case .until(let date, _): return now < date
        }
    }

    public func activePause(at now: Date) -> CompletionPause? {
        isPaused(at: now) ? pause : nil
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        pause = nil
    }

    public mutating func reset() {
        consecutiveFailures = 0
        pause = nil
    }

    @discardableResult
    public mutating func record(_ failure: CompletionFailure, at now: Date) -> CompletionPause? {
        consecutiveFailures += 1
        switch failure {
        case .unauthorized, .endpointNotFound, .invalidConfiguration, .consentRequired:
            pause = .untilSettingsChange(reason: failure.shortReason)
        case .rateLimited(let retryAfter):
            let seconds = min(retryAfter.map(TimeInterval.init) ?? Self.rateLimitDefaultSeconds, Self.maximumPauseSeconds)
            pause = .until(now.addingTimeInterval(max(1, seconds)), reason: failure.shortReason)
        case .server, .timeout, .offline, .invalidResponse:
            guard consecutiveFailures >= Self.failuresBeforePause else {
                pause = nil
                return nil
            }
            let exponent = Double(consecutiveFailures - Self.failuresBeforePause)
            let seconds = min(2 * pow(2, exponent), Self.maximumPauseSeconds)
            pause = .until(now.addingTimeInterval(seconds), reason: failure.shortReason)
        }
        return pause
    }
}
