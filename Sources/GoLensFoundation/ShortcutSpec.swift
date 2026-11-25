import Foundation

public struct ShortcutSpec: Hashable, Codable, Sendable, CustomStringConvertible {
    public var control = false
    public var option = false
    public var shift = false
    public var command = false
    public var key: String

    public static let namedKeys: Set<String> = Set([
        "up", "down", "left", "right", "enter", "tab", "space", "escape",
        "backspace", "delete", "home", "end", "pageup", "pagedown"
    ]).union((1...19).map { "f\($0)" })

    public init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    public init?(_ text: String) {
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
        let aliases = [
            "return": "enter",
            "esc": "escape",
            "uparrow": "up",
            "downarrow": "down",
            "leftarrow": "left",
            "rightarrow": "right",
            "pgup": "pageup",
            "pgdn": "pagedown"
        ]
        let name = aliases[last] ?? last
        guard name.count == 1 || Self.namedKeys.contains(name) else { return nil }
        key = name
    }

    public var description: String {
        var p: [String] = []
        if control { p.append("ctrl") }
        if option { p.append("alt") }
        if shift { p.append("shift") }
        if command { p.append("cmd") }
        return (p + [key]).joined(separator: "+")
    }

    public var display: String {
        var s = ""
        if control { s += "\u{2303}" }
        if option { s += "\u{2325}" }
        if shift { s += "\u{21E7}" }
        if command { s += "\u{2318}" }
        let glyphs = [
            "up": "\u{2191}",
            "down": "\u{2193}",
            "left": "\u{2190}",
            "right": "\u{2192}",
            "enter": "\u{21A9}",
            "tab": "\u{21E5}",
            "space": "Space",
            "escape": "\u{238B}",
            "backspace": "\u{232B}",
            "delete": "\u{2326}",
            "home": "\u{2196}",
            "end": "\u{2198}",
            "pageup": "\u{21DE}",
            "pagedown": "\u{21DF}"
        ]
        return s + (glyphs[key] ?? key.uppercased())
    }

    public var spoken: String {
        var p: [String] = []
        if control { p.append("Control") }
        if option { p.append("Option") }
        if shift { p.append("Shift") }
        if command { p.append("Command") }
        let names = [
            "up": "Up Arrow",
            "down": "Down Arrow",
            "left": "Left Arrow",
            "right": "Right Arrow",
            "enter": "Return",
            "tab": "Tab",
            "space": "Space",
            "escape": "Escape",
            "backspace": "Delete",
            "delete": "Forward Delete",
            "home": "Home",
            "end": "End",
            "pageup": "Page Up",
            "pagedown": "Page Down"
        ]
        return (p + [names[key] ?? key.uppercased()]).joined(separator: "-")
    }

    public var isFunctionKey: Bool {
        key.count > 1 && key.hasPrefix("f")
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let spec = ShortcutSpec(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a single-chord shortcut: \(text)"))
        }
        self = spec
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
