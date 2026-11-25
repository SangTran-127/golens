import Foundation

struct KeyChord: Hashable, Codable, CustomStringConvertible {
    var control = false
    var option = false
    var shift = false
    var command = false
    var key: String

    static let namedKeys: Set<String> = Set(["up", "down", "left", "right", "enter", "tab", "space", "escape", "backspace", "delete", "home", "end", "pageup", "pagedown"])
        .union((1...19).map { "f\($0)" })

    init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let last: String
        let mods: [Substring]
        if s == "+" {
            (last, mods) = ("+", [])
        } else if s.hasSuffix("++") {
            (last, mods) = ("+", s.dropLast(2).split(separator: "+", omittingEmptySubsequences: false))
        } else {
            var parts = s.split(separator: "+", omittingEmptySubsequences: false)
            last = String(parts.removeLast())
            mods = parts
        }
        guard !last.isEmpty else { return nil }
        for m in mods {
            switch m {
            case "ctrl", "control": control = true
            case "alt", "opt", "option": option = true
            case "shift": shift = true
            case "cmd", "meta", "command": command = true
            default: return nil
            }
        }
        let aliases = ["return": "enter", "esc": "escape", "uparrow": "up", "downarrow": "down", "leftarrow": "left", "rightarrow": "right", "pgup": "pageup", "pgdn": "pagedown"]
        let name = aliases[last] ?? last
        guard name.count == 1 || Self.namedKeys.contains(name) else { return nil }
        key = name
    }

    var description: String {
        var p: [String] = []
        if control { p.append("ctrl") }
        if option { p.append("alt") }
        if shift { p.append("shift") }
        if command { p.append("cmd") }
        return (p + [key]).joined(separator: "+")
    }

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let glyphs = ["up": "↑", "down": "↓", "left": "←", "right": "→", "enter": "↩", "tab": "⇥", "space": "Space", "escape": "⎋",
                      "backspace": "⌫", "delete": "⌦", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"]
        return s + (glyphs[key] ?? key.uppercased())
    }

    var spoken: String {
        var p: [String] = []
        if control { p.append("Control") }
        if option { p.append("Option") }
        if shift { p.append("Shift") }
        if command { p.append("Command") }
        let names = ["up": "Up Arrow", "down": "Down Arrow", "left": "Left Arrow", "right": "Right Arrow", "enter": "Return", "tab": "Tab", "space": "Space",
                     "escape": "Escape", "backspace": "Delete", "delete": "Forward Delete", "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down"]
        return (p + [names[key] ?? key.uppercased()]).joined(separator: "-")
    }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a single-chord shortcut: \(text)"))
        }
        self = chord
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

enum CompletionAcceptKey: String, CaseIterable, Codable {
    case tab, returnKey = "return"

    var title: String { self == .tab ? "Tab" : "Return" }
}

struct KeymapCommand: Identifiable, Hashable {
    let id: String
    let title: String
    let menu: String
    let golens: KeyChord?
    let isSystem: Bool
    let isSystemOnly: Bool

    init(_ id: String, _ title: String, _ menu: String, _ golens: String? = nil, system: Bool = false, systemOnly: Bool = false) {
        self.id = id
        self.title = title
        self.menu = menu
        self.golens = golens.map { KeyChord($0)! }
        self.isSystem = system || systemOnly
        self.isSystemOnly = systemOnly
    }
}

enum KeymapPreset: String, CaseIterable, Codable, Identifiable {
    case golens, vscode, goland

    var id: String { rawValue }

    var title: String {
        switch self {
        case .golens: "GoLens"
        case .vscode: "VS Code"
        case .goland: "GoLand"
        }
    }

    var completionAcceptKey: CompletionAcceptKey { self == .golens ? .tab : .returnKey }

    var explicit: [String: String?] {
        switch self {
        case .golens: [:]
        case .vscode: KeymapPresets.vscode
        case .goland: KeymapPresets.goland
        }
    }
}

struct Keymap: Equatable {
    var preset: KeymapPreset = .golens
    var overrides: [String: KeyChord?] = [:]
    var completionAcceptKeyOverride: CompletionAcceptKey?

    enum Source: String { case preset = "Preset", custom = "Custom", system = "System" }

    static let commandsByID: [String: KeymapCommand] = Dictionary(uniqueKeysWithValues: KeymapCommand.all.map { ($0.id, $0) })

    static let sharedPairs: Set<Set<String>> = [
        ["product.debug", "debug.continue"],
        ["debug.continue", "debug.pause"],
    ]

    static func presetChord(_ id: String, in preset: KeymapPreset) -> KeyChord? {
        presetTable(preset)[id] ?? nil
    }

    private static let presetTables: [KeymapPreset: [String: KeyChord]] = Dictionary(uniqueKeysWithValues: KeymapPreset.allCases.map { ($0, buildTable($0)) })

    static func presetTable(_ preset: KeymapPreset) -> [String: KeyChord] { presetTables[preset] ?? [:] }

    private static func buildTable(_ preset: KeymapPreset) -> [String: KeyChord] {
        var table: [String: KeyChord] = [:]
        let explicit = preset.explicit
        var explicitChords = Set<KeyChord>()
        for (id, text) in explicit {
            guard let text else { continue }
            let chord = KeyChord(text)!
            table[id] = chord
            explicitChords.insert(chord)
        }
        for command in KeymapCommand.all {
            if command.isSystem {
                table[command.id] = command.golens
                continue
            }
            guard explicit.index(forKey: command.id) == nil, let chord = command.golens, !explicitChords.contains(chord) else { continue }
            table[command.id] = chord
        }
        return table
    }

    func chord(for id: String) -> KeyChord? {
        if let command = Self.commandsByID[id], command.isSystem { return command.golens }
        if let override = overrides[id] { return override }
        return Self.presetChord(id, in: preset)
    }

    func source(for id: String) -> Source {
        if Self.commandsByID[id]?.isSystem == true { return .system }
        return overrides[id] != nil ? .custom : .preset
    }

    var completionAcceptKey: CompletionAcceptKey { completionAcceptKeyOverride ?? preset.completionAcceptKey }

    func commands(using chord: KeyChord, except id: String? = nil) -> [KeymapCommand] {
        KeymapCommand.all.filter { $0.id != id && self.chord(for: $0.id) == chord }
    }

    func conflicts(for id: String) -> [KeymapCommand] {
        guard let chord = chord(for: id) else { return [] }
        return commands(using: chord, except: id).filter { !Self.sharedPairs.contains([id, $0.id]) }
    }

    enum AssignResult: Equatable {
        case assigned
        case system(KeymapCommand)
        case conflict([KeymapCommand])
    }

    @discardableResult
    mutating func assign(_ chord: KeyChord?, to id: String, replacing: Bool = false) -> AssignResult {
        guard let command = Self.commandsByID[id], !command.isSystem else { return .system(Self.commandsByID[id]!) }
        if let chord {
            let others = commands(using: chord, except: id)
            if let system = others.first(where: \.isSystem) { return .system(system) }
            if !others.isEmpty && !replacing { return .conflict(others) }
            for other in others { setOverride(nil, for: other.id) }
        }
        setOverride(chord, for: id)
        return .assigned
    }

    private mutating func setOverride(_ chord: KeyChord?, for id: String) {
        if chord == Self.presetChord(id, in: preset) {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = .some(chord)
        }
    }

    mutating func reset(_ id: String) { overrides.removeValue(forKey: id) }

    mutating func resetAll() {
        overrides.removeAll()
        completionAcceptKeyOverride = nil
    }

    mutating func setCompletionAcceptKey(_ key: CompletionAcceptKey) {
        completionAcceptKeyOverride = key == preset.completionAcceptKey ? nil : key
    }

    mutating func switchPreset(_ new: KeymapPreset) {
        let accept = completionAcceptKeyOverride
        preset = new
        for (id, chord) in overrides where chord == Self.presetChord(id, in: new) { overrides.removeValue(forKey: id) }
        completionAcceptKeyOverride = accept == new.completionAcceptKey ? nil : accept
    }

    static let exportFormat = "golens-keymap"

    private struct File: Codable {
        var format: String
        var version: Int
        var preset: KeymapPreset
        var completionAcceptKey: CompletionAcceptKey?
        var overrides: [String: String]
    }

    func exportJSON() -> Data {
        var map: [String: String] = [:]
        for (id, chord) in overrides { map[id] = chord?.description ?? "" }
        let file = File(format: Self.exportFormat, version: 1, preset: preset, completionAcceptKey: completionAcceptKeyOverride, overrides: map)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(file)) ?? Data()
    }

    static func isExport(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? String == exportFormat
    }

    struct ImportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func importJSON(_ data: Data) throws -> (keymap: Keymap, skipped: [String]) {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw ImportError("The file isn’t a GoLens keymap export.")
        }
        guard file.format == exportFormat else { throw ImportError("The file isn’t a GoLens keymap export.") }
        guard file.version == 1 else { throw ImportError("This keymap was exported by a newer version of GoLens.") }
        var keymap = Keymap(preset: file.preset)
        keymap.completionAcceptKeyOverride = file.completionAcceptKey
        var skipped: [String] = []
        for (id, text) in file.overrides.sorted(by: { $0.key < $1.key }) {
            guard let command = commandsByID[id] else { skipped.append("\(id): unknown command"); continue }
            guard !command.isSystem else { skipped.append("\(command.title): standard macOS shortcut, can’t be changed"); continue }
            if text.isEmpty { keymap.overrides[id] = .some(nil); continue }
            guard let chord = KeyChord(text) else { skipped.append("\(command.title): “\(text)” isn’t a single-chord shortcut"); continue }
            keymap.overrides[id] = chord
        }
        return (keymap, skipped)
    }
}
