import Foundation

enum LinuxRuntimeLocation {
    private static var override: URL? {
        guard let path = ProcessInfo.processInfo.environment["GOLENS_VM_RUNTIME_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var directory: URL {
        override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GoLens/VMRuntime", isDirectory: true)
    }

    static var downloadDirectory: URL {
        if let override {
            return override.deletingLastPathComponent().appendingPathComponent(override.lastPathComponent + ".download", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GoLens/LinuxRuntimeDownload", isDirectory: true)
    }
}
