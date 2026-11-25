import AppKit

extension NSTextView {
    var liveText: NSString { textStorage?.mutableString ?? (string as NSString) }
}

extension Array {
    var storageIdentity: UnsafeRawPointer? {
        withUnsafeBufferPointer { $0.baseAddress.map { UnsafeRawPointer($0) } }
    }

    func hasSameStorage(as other: [Element]) -> Bool {
        count == other.count && storageIdentity == other.storageIdentity
    }
}

enum EditorDisplaySettings {
    private static var cache: [String: Bool] = [:]
    private static var observer: NSObjectProtocol?

    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = cache[key] { return value }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
                if Thread.isMainThread {
                    EditorDisplaySettings.cache.removeAll()
                } else {
                    DispatchQueue.main.async { EditorDisplaySettings.cache.removeAll() }
                }
            }
        }
        let value = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
        cache[key] = value
        return value
    }

    static var showIssuesInline: Bool { bool(WorkspaceState.showIssuesInlineKey, default: true) }
    static var showInlineSafety: Bool { bool("GoLensShowInlineSafety", default: true) }
    static var showProfileLineHeat: Bool { bool("GoLensShowProfileLineHeat", default: true) }
}

struct ProfileHeatCache {
    let mode: String
    let entries: [ProfileEntry]
    let byPath: [String: [Int: Double]]
}
