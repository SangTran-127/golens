import AppKit

struct SymbolIcon: Equatable {
    let name: String
    let palette: String
}

final class SymbolIconResolver: @unchecked Sendable {
    static let shared = SymbolIconResolver()

    private struct Rule: Decodable {
        let icon: String
        let palette: String
    }

    private struct Mapping: Decodable {
        let lspKinds: [String: Rule]
        let completionKinds: [String: Rule]
        let fallback: Rule
    }

    private let mapping: Mapping?
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    private init() {
        mapping = FileIconResolver.resourceURL("symbol-mapping", "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
    }

    func icon(forKind rawKind: String) -> SymbolIcon {
        let key = rawKind.lowercased()
        if let rule = mapping?.completionKinds[key] {
            return SymbolIcon(name: rule.icon, palette: rule.palette)
        }
        if let fb = mapping?.fallback {
            return SymbolIcon(name: fb.icon, palette: fb.palette)
        }
        return SymbolIcon(name: "sym-var", palette: "infra")
    }

    func icon(forLSPKind kind: Int, fallbackModeIsCall: Bool = false) -> SymbolIcon {
        if let rule = mapping?.lspKinds[String(kind)] {
            return SymbolIcon(name: rule.icon, palette: rule.palette)
        }
        if fallbackModeIsCall {
            return SymbolIcon(name: "sym-func", palette: "go")
        }
        if let fb = mapping?.fallback {
            return SymbolIcon(name: fb.icon, palette: fb.palette)
        }
        return SymbolIcon(name: "sym-type", palette: "data")
    }

    func image(_ name: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[name] { return image }
        let image = FileIconResolver.resourceURL(name, "pdf").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        images[name] = image
        return image
    }
}
