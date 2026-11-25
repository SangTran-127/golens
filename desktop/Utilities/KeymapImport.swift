import Foundation

struct KeymapImportReport: Equatable {
    var source: String
    var mapped: [String] = []
    var removed: [String] = []
    var notImported: [String] = []
    var notes: [String] = []
}

enum KeymapImport {
    static func vscode(_ text: String) throws -> (keymap: Keymap, report: KeymapImportReport) {
        let cleaned = stripJSONC(text)
        guard let data = cleaned.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw Keymap.ImportError("The file isn’t a VS Code keybindings.json: it must be a JSON array of key bindings.")
        }
        var keymap = Keymap(preset: .vscode)
        var report = KeymapImportReport(source: "VS Code keybindings.json")
        var whenCount = 0
        for case let entry as [String: Any] in entries {
            guard let key = entry["key"] as? String, let rawCommand = entry["command"] as? String else {
                report.notImported.append("An entry without “key” and “command”")
                continue
            }
            if entry["when"] != nil { whenCount += 1 }
            let isRemoval = rawCommand.hasPrefix("-")
            let vsCommand = isRemoval ? String(rawCommand.dropFirst()) : rawCommand
            guard let id = KeymapPresets.vscodeCommands[vsCommand], let command = Keymap.commandsByID[id] else {
                report.notImported.append("\(vsCommand) (\(key)): no matching GoLens command")
                continue
            }
            guard let chord = KeyChord(key) else {
                let reason = key.trimmingCharacters(in: .whitespaces).contains(" ") ? "chord sequences aren’t supported" : "unrecognized key"
                report.notImported.append("\(vsCommand) (\(key)): \(reason)")
                continue
            }
            apply(chord, removal: isRemoval, to: command, in: &keymap, report: &report)
        }
        if whenCount > 0 {
            report.notes.append("\(whenCount) “when” \(whenCount == 1 ? "clause was" : "clauses were") ignored; GoLens enables each command from its menu state.")
        }
        return (keymap, report)
    }

    static func goland(_ text: String) throws -> (keymap: Keymap, report: KeymapImportReport) {
        let parsed = try JetBrainsKeymapParser.parse(text)
        var keymap = Keymap(preset: .goland)
        var report = KeymapImportReport(source: parsed.name.isEmpty ? "GoLand keymap" : "GoLand keymap “\(parsed.name)”")
        if let parent = parsed.parent, !KeymapPresets.golandParents.contains(parent) {
            report.notes.append("Parent keymap “\(parent)” isn’t built in; its actions were applied on top of the GoLand (macOS) preset.")
        }
        for action in parsed.actions {
            guard let id = KeymapPresets.golandActions[action.id], let command = Keymap.commandsByID[id] else {
                report.notImported.append("\(action.id): no matching GoLens command")
                continue
            }
            if action.keystrokes.isEmpty {
                if keymap.chord(for: id) != nil, !command.isSystem {
                    keymap.overrides[id] = .some(nil)
                    report.removed.append(command.title)
                }
                continue
            }
            var chosen: KeyChord?
            for stroke in action.keystrokes {
                if let second = stroke.second {
                    report.notImported.append("\(action.id) (\(stroke.first), \(second)): chord sequences aren’t supported")
                } else if let chord = JetBrainsKeymapParser.chord(stroke.first) {
                    if chosen == nil { chosen = chord } else { report.notes.append("\(command.title): kept \(chosen!.display); GoLens has one shortcut per command, so \(chord.display) was not imported.") }
                } else {
                    report.notImported.append("\(action.id) (\(stroke.first)): unrecognized keystroke")
                }
            }
            if let chosen { apply(chosen, removal: false, to: command, in: &keymap, report: &report) }
        }
        if parsed.mouseShortcuts > 0 {
            report.notes.append("\(parsed.mouseShortcuts) mouse \(parsed.mouseShortcuts == 1 ? "shortcut was" : "shortcuts were") ignored.")
        }
        return (keymap, report)
    }

    private static func apply(_ chord: KeyChord, removal: Bool, to command: KeymapCommand, in keymap: inout Keymap, report: inout KeymapImportReport) {
        if command.isSystem {
            report.notImported.append("\(command.title) (\(chord.display)): standard macOS shortcut, can’t be changed")
            return
        }
        if removal {
            if keymap.chord(for: command.id) == chord {
                keymap.overrides[command.id] = .some(nil)
                report.removed.append(command.title)
            }
            return
        }
        switch keymap.assign(chord, to: command.id, replacing: true) {
        case .assigned:
            report.mapped.append("\(command.title): \(chord.display)")
        case .system(let other):
            report.notImported.append("\(command.title) (\(chord.display)): used by macOS for \(other.title)")
        case .conflict:
            break
        }
    }

    static func stripJSONC(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        chars = Array(out)
        var result = ""
        for (n, c) in chars.enumerated() {
            if c == "," {
                var j = n + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "]" || chars[j] == "}" { continue }
            }
            result.append(c)
        }
        return result
    }
}

final class JetBrainsKeymapParser: NSObject, XMLParserDelegate {
    struct Stroke { let first: String; let second: String? }
    struct Action { let id: String; var keystrokes: [Stroke] }
    struct Result { var name = ""; var parent: String?; var actions: [Action] = []; var mouseShortcuts = 0 }

    private var result = Result()
    private var current: Action?
    private var sawKeymap = false

    static func parse(_ text: String) throws -> Result {
        guard let data = text.data(using: .utf8) else { throw Keymap.ImportError("The keymap file isn’t UTF-8 text.") }
        let delegate = JetBrainsKeymapParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawKeymap else {
            throw Keymap.ImportError("The file isn’t a JetBrains keymap: it must have a <keymap> element.")
        }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "keymap":
            sawKeymap = true
            result.name = attributes["name"] ?? ""
            result.parent = attributes["parent"]
        case "action":
            current = Action(id: attributes["id"] ?? "", keystrokes: [])
        case "keyboard-shortcut":
            if let first = attributes["first-keystroke"] { current?.keystrokes.append(Stroke(first: first, second: attributes["second-keystroke"])) }
        case "mouse-shortcut", "keyboard-gesture-shortcut":
            result.mouseShortcuts += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "action", let current {
            result.actions.append(current)
            self.current = nil
        }
    }

    static func chord(_ stroke: String) -> KeyChord? {
        let ignored: Set<String> = ["pressed", "released", "typed"]
        let tokens: [String] = stroke.split(separator: " ").map(String.init).filter { !ignored.contains($0) }
        guard let last = tokens.last else { return nil }
        var chord = KeyChord(key: "")
        for m in tokens.dropLast() {
            switch m.lowercased() {
            case "meta": chord.command = true
            case "alt", "altgraph": chord.option = true
            case "control", "ctrl": chord.control = true
            case "shift": chord.shift = true
            default: return nil
            }
        }
        let names: [String: String] = [
            "OPEN_BRACKET": "[", "CLOSE_BRACKET": "]", "SLASH": "/", "BACK_SLASH": "\\", "COMMA": ",", "PERIOD": ".",
            "MINUS": "-", "EQUALS": "=", "SEMICOLON": ";", "QUOTE": "'", "BACK_QUOTE": "`", "ADD": "+", "SUBTRACT": "-",
            "PLUS": "+", "MULTIPLY": "*", "DIVIDE": "/", "DECIMAL": ".",
            "ENTER": "enter", "TAB": "tab", "SPACE": "space", "ESCAPE": "escape", "BACK_SPACE": "backspace", "DELETE": "delete",
            "UP": "up", "DOWN": "down", "LEFT": "left", "RIGHT": "right", "KP_UP": "up", "KP_DOWN": "down", "KP_LEFT": "left", "KP_RIGHT": "right",
            "HOME": "home", "END": "end", "PAGE_UP": "pageup", "PAGE_DOWN": "pagedown",
        ]
        if let named = names[last] {
            chord.key = named
        } else if last.hasPrefix("NUMPAD"), let digit = last.dropFirst(6).first, last.count == 7, digit.isNumber {
            chord.key = String(digit)
        } else if last.count == 1, let c = last.first, c.isLetter || c.isNumber {
            chord.key = last.lowercased()
        } else if last.hasPrefix("F"), let n = Int(last.dropFirst()), (1...19).contains(n) {
            chord.key = "f\(n)"
        } else {
            return nil
        }
        return chord
    }
}
