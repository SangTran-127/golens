import AppKit
import Darwin

struct FileIcon: Equatable {
    let name: String
    let palette: String
}

final class FileIconResolver: @unchecked Sendable {
    static let shared = FileIconResolver()
    static let maxCachedPaths = 2000
    static let maxContentFileBytes = 256 << 10

    private struct Rule: Decodable {
        struct Content: Decodable {
            let maxBytes: Int
            let all: [String]
        }
        var names: [String]?
        var globs: [String]?
        var pathGlobs: [String]?
        var extensions: [String]?
        var content: Content?
        var siblingFile: String?
        var containsFile: String?
        var ancestorFile: String?
        let icon: String
        let palette: String

        var needsIO: Bool { content != nil || siblingFile != nil || ancestorFile != nil }
    }

    private struct Mapping: Decodable {
        struct Fallback: Decodable {
            let icon: String
            let palette: String
        }
        let folders: [Rule]
        let files: [Rule]
        let fallback: [String: Fallback]
    }

    private let mapping: Mapping?
    private let lock = NSLock()
    private var cache: [String: (Date, FileIcon)] = [:]
    private var images: [String: NSImage] = [:]
    private var colorImages: [String: NSImage?] = [:]
    private var regexes: [String: NSRegularExpression] = [:]

    private init() {
        mapping = Self.resourceURL("mapping", "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
    }

    static func resourceURL(_ name: String, _ ext: String) -> URL? {
        AppResourceBundle.url(forResource: name, withExtension: ext)
    }

    func image(_ name: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[name] { return image }
        let image = Self.resourceURL(name, "pdf").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        images[name] = image
        return image
    }

    func colorImage(_ name: String, seasonalPack: String? = nil, dark: Bool, highContrast: Bool) -> NSImage? {
        let prefix = seasonalPack.map { "\(name)-\($0)" } ?? name
        let key = "\(prefix)-color-\(dark ? "dark" : "light")\(highContrast ? "-hc" : "")"
        lock.lock()
        defer { lock.unlock() }
        if let image = colorImages[key] { return image }
        let image = Self.resourceURL(key, "pdf").flatMap { NSImage(contentsOf: $0) }
        colorImages[key] = image
        return image
    }

    func icon(name: String, path: String?, root: String, isFolder: Bool, isExpanded: Bool, childNames: [String]? = nil) -> (icon: FileIcon, needsIO: Bool) {
        if let path {
            let key = path + (isExpanded ? "\u{1}" : "")
            lock.lock()
            if let (_, cached) = cache[key] {
                lock.unlock()
                return (cached, false)
            }
            lock.unlock()
        }
        return evaluate(name: name, path: path, root: root, isFolder: isFolder, isExpanded: isExpanded, childNames: childNames, allowIO: false)
    }

    func resolvedIcon(name: String, path: String, root: String, isFolder: Bool, isExpanded: Bool) -> FileIcon {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        let key = path + (isExpanded ? "\u{1}" : "")
        lock.lock()
        if let (cachedTime, icon) = cache[key], cachedTime == mtime {
            lock.unlock()
            return icon
        }
        lock.unlock()
        let icon = evaluate(name: name, path: path, root: root, isFolder: isFolder, isExpanded: isExpanded, childNames: nil, allowIO: true).icon
        lock.lock()
        if cache.count >= Self.maxCachedPaths { cache.removeAll(keepingCapacity: true) }
        cache[key] = (mtime, icon)
        lock.unlock()
        return icon
    }

    private func evaluate(name rawName: String, path: String?, root: String, isFolder: Bool, isExpanded: Bool, childNames: [String]?, allowIO: Bool) -> (icon: FileIcon, needsIO: Bool) {
        guard let mapping else { return (isFolder ? FileIcon(name: "folder", palette: FileIconPalette.accentKey) : FileIcon(name: "file", palette: "neutral"), false) }
        let name = (rawName as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let relative: String? = path.map { p in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return (p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p).lowercased()
        }
        var needsIO = false
        for rule in isFolder ? mapping.folders : mapping.files {
            if let names = rule.names, !names.contains(name) { continue }
            if let globs = rule.globs, !globs.contains(where: { fnmatch($0, name, 0) == 0 }) { continue }
            if let globs = rule.pathGlobs {
                guard let relative, globs.contains(where: { fnmatch($0, relative, 0) == 0 }) else { continue }
            }
            if let exts = rule.extensions, !exts.contains(ext) { continue }
            if let file = rule.containsFile {
                if let childNames {
                    guard childNames.contains(file) else { continue }
                } else if allowIO, let path {
                    guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(file)) else { continue }
                } else {
                    needsIO = needsIO || path != nil
                    continue
                }
            }
            if rule.needsIO {
                guard allowIO, let path else {
                    needsIO = needsIO || path != nil
                    continue
                }
                guard matchesIO(rule, path: path, root: root) else { continue }
            }
            return (FileIcon(name: rule.icon, palette: rule.palette), needsIO)
        }
        let key = isFolder ? (isExpanded ? "folderExpanded" : "folder") : "file"
        let fallback = mapping.fallback[key] ?? mapping.fallback["file"]
        return (FileIcon(name: fallback?.icon ?? "file", palette: fallback?.palette ?? "neutral"), needsIO)
    }

    private func matchesIO(_ rule: Rule, path: String, root: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if let sibling = rule.siblingFile, !fm.fileExists(atPath: (dir as NSString).appendingPathComponent(sibling)) {
            return false
        }
        if let ancestor = rule.ancestorFile {
            var current = dir
            var found = false
            while current.hasPrefix(root), !current.isEmpty, current != "/" {
                if fm.fileExists(atPath: (current as NSString).appendingPathComponent(ancestor)) { found = true; break }
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
            guard found else { return false }
        }
        if let content = rule.content {
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max
            guard size <= Self.maxContentFileBytes, let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: content.maxBytes)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(location: 0, length: (text as NSString).length)
            for pattern in content.all {
                guard let regex = regex(pattern), regex.firstMatch(in: text, range: range) != nil else { return false }
            }
        }
        return true
    }

    private func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let regex = regexes[pattern] { return regex }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        regexes[pattern] = regex
        return regex
    }
}

enum FileIconPalette {
    static let coloredKey = "GoLensColoredFileIcons"
    static let accentKey = "accent"
    static let minimumContrast: CGFloat = 3
    static let increasedContrast: CGFloat = 4.5

    private struct Tint: Decodable {
        let light: String
        let dark: String
        let lightHighContrast: String
        let darkHighContrast: String
        let system: String?
    }

    private struct Backgrounds: Decodable {
        let light: [String]
        let dark: [String]
    }

    private struct File: Decodable {
        let tints: [String: Tint]
        let sidebarBackgrounds: Backgrounds
    }

    private static let file: File? = FileIconResolver.resourceURL("palette", "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(File.self, from: $0) }

    private static let sidebarBackgrounds: (light: [NSColor], dark: [NSColor]) = (
        file?.sidebarBackgrounds.light.compactMap(color(hex:)) ?? [],
        file?.sidebarBackgrounds.dark.compactMap(color(hex:)) ?? []
    )

    private static let variantsByKey: [String: [NSColor]] = {
        guard let file else { return [:] }
        var map: [String: [NSColor]] = [:]
        for (key, tint) in file.tints where tint.system == nil {
            let variants = [tint.light, tint.dark, tint.lightHighContrast, tint.darkHighContrast].compactMap(color(hex:))
            if variants.count == 4 {
                map[key] = variants
            }
        }
        return map
    }()

    private static let colors: [String: NSColor] = {
        var colors: [String: NSColor] = [:]
        for (key, variants) in variantsByKey {
            colors[key] = NSColor(name: NSColor.Name("GoLensFileIcon.\(key)")) { appearance in
                switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
                case .darkAqua: return variants[1]
                case .accessibilityHighContrastAqua: return variants[2]
                case .accessibilityHighContrastDarkAqua: return variants[3]
                default: return variants[0]
                }
            }
        }
        return colors
    }()

    static func color(for key: String) -> NSColor? {
        colors[key]
    }

    static func color(for key: String, dark: Bool, highContrast: Bool = false) -> NSColor? {
        guard let variants = variantsByKey[key], variants.count == 4 else { return nil }
        if highContrast {
            return dark ? variants[3] : variants[2]
        }
        return dark ? variants[1] : variants[0]
    }

    static func accent(_ accent: NSColor, background: NSColor?, dark: Bool, highContrast: Bool) -> NSColor {
        let name: NSAppearance.Name = dark
            ? (highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
            : (highContrast ? .accessibilityHighContrastAqua : .aqua)
        let backgrounds = (dark ? sidebarBackgrounds.dark : sidebarBackgrounds.light) + [background].compactMap { $0 }
        return NSColor(name: nil) { _ in
            var resolved = accent
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                resolved = accent.usingColorSpace(.sRGB) ?? accent
            }
            return legible(resolved, on: backgrounds, minimum: highContrast ? increasedContrast : minimumContrast, lighten: dark)
        }
    }

    static func legible(_ color: NSColor, on backgrounds: [NSColor], minimum: CGFloat, lighten: Bool) -> NSColor {
        var result = color
        var fraction: CGFloat = 0
        while fraction < 1, backgrounds.contains(where: { contrast(result, $0) < minimum }) {
            fraction += 0.05
            result = color.blended(withFraction: fraction, of: lighten ? .white : .black) ?? result
        }
        return result
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private static func color(hex: String) -> NSColor? {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1) // hig-lint: ignore
    }
}
