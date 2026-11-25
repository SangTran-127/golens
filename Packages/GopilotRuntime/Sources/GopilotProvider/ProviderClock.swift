import Foundation

public protocol ProviderClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemProviderClock: ProviderClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
    }

    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let bounded = min(max(seconds, 0), 365 * 24 * 3600)
        return UInt64(bounded * 1_000_000_000)
    }
}

public final class ManualClock: ProviderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [TimeInterval] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    public func now() -> Date {
        lock.withLock { current }
    }

    public func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock {
            recorded.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }

    public var sleeps: [TimeInterval] {
        lock.withLock { recorded }
    }
}

struct TimeoutExpired: Error {}

private enum Raced<Value: Sendable>: Sendable {
    case value(Value)
    case expired
}

func withTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let raced: Raced<Value> = try await withThrowingTaskGroup(of: Raced<Value>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(nanoseconds: SystemProviderClock.nanoseconds(seconds))
            return .expired
        }
        guard let first = try await group.next() else { return .expired }
        group.cancelAll()
        return first
    }
    switch raced {
    case .value(let value): return value
    case .expired: throw TimeoutExpired()
    }
}
