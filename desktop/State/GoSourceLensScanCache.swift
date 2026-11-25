import Foundation

struct GoSourceLensScan {
    let generate: [CodeLensItem]
    let routes: [CodeLensItem]
}

final class TextKeyedCache<Value> {
    private struct Key: Equatable {
        let length: Int
        let hash: Int
    }

    private var entries: [String: (key: Key, value: Value)] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func cached(path: String, text: String) -> Value? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let entry = entries[path], entry.key == Self.key(for: text) else { return nil }
        return entry.value
    }

    func store(_ value: Value, path: String, text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if entries[path] == nil, entries.count >= capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[path] = (Self.key(for: text), value)
    }

    func removeAll() {
        entries.removeAll()
    }

    private static func key(for text: String) -> Key {
        Key(length: text.utf8.count, hash: text.hashValue)
    }
}

enum GoSourceLensScanCache {
    static let shared = TextKeyedCache<GoSourceLensScan>(capacity: 64)

    static func scan(text: String, path: String) -> GoSourceLensScan {
        GoSourceLensScan(
            generate: WorkspaceState.goGenerateLenses(in: text, path: path),
            routes: CodeLensProvider.httpRouteLenses(in: text, path: path)
        )
    }
}
