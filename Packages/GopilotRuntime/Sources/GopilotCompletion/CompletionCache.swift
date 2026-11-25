import Foundation

public final class CompletionCache: @unchecked Sendable {
    public static let prefixTailLength = 512
    public static let suffixHeadLength = 256
    static let typingThroughAnchorLength = 256
    static let typingThroughCandidates = 16
    static let typingThroughMaxTyped = 128

    struct Key: Hashable {
        let scope: String
        let path: String
        let prefixTail: String
        let suffixHead: String
    }

    private struct Entry {
        let key: Key
        let text: String
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
        }
    }

    public func store(_ text: String, scope: String, path: String, prefix: String, suffix: String) {
        let key = Self.key(scope: scope, path: path, prefix: prefix, suffix: suffix)
        lock.withLock {
            if entries[key] != nil {
                order.removeAll { $0 == key }
            }
            entries[key] = Entry(key: key, text: text)
            order.append(key)
            while order.count > capacity {
                let evicted = order.removeFirst()
                entries[evicted] = nil
            }
        }
    }

    public func lookup(scope: String, path: String, prefix: String, suffix: String) -> String? {
        let key = Self.key(scope: scope, path: path, prefix: prefix, suffix: suffix)
        return lock.withLock {
            if let hit = entries[key] {
                touch(key)
                return hit.text
            }
            for candidate in order.suffix(Self.typingThroughCandidates).reversed() {
                guard candidate.scope == key.scope, candidate.path == key.path, candidate.suffixHead == key.suffixHead,
                      let entry = entries[candidate],
                      let remaining = Self.remainder(of: entry.text, typedAfter: candidate.prefixTail, current: key.prefixTail) else { continue }
                touch(candidate)
                return remaining
            }
            return nil
        }
    }

    static func remainder(of text: String, typedAfter storedTail: String, current: String) -> String? {
        let anchor = storedTail.suffix(typingThroughAnchorLength)
        let limit = min(text.count - 1, typingThroughMaxTyped)
        guard limit >= 1 else { return nil }
        for typed in 1...limit {
            let typedText = text.prefix(typed)
            guard current.hasSuffix(typedText) else { continue }
            let before = current.dropLast(typedText.count)
            if before.hasSuffix(anchor) {
                let rest = String(text.dropFirst(typed))
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    static func key(scope: String, path: String, prefix: String, suffix: String) -> Key {
        Key(scope: scope, path: path, prefixTail: String(prefix.suffix(prefixTailLength)), suffixHead: String(suffix.prefix(suffixHeadLength)))
    }
}
