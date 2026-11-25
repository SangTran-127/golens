import AppKit
import Observation
import SwiftUI

@Observable
final class KeymapStore {
    static let shared = KeymapStore()
    static let defaultsKey = "GoLensKeymap"
    private static let legacyAcceptKey = "GoLensCompletionAcceptKey"

    private(set) var keymap: Keymap

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.defaultsKey), let restored = try? Keymap.importJSON(data) {
            keymap = restored.keymap
        } else {
            var initial = Keymap()
            if let legacy = defaults.string(forKey: Self.legacyAcceptKey).flatMap(CompletionAcceptKey.init(rawValue:)) {
                initial.setCompletionAcceptKey(legacy)
            }
            keymap = initial
        }
    }

    private func update(_ change: (inout Keymap) -> Void) {
        var next = keymap
        change(&next)
        guard next != keymap else { return }
        keymap = next
        UserDefaults.standard.set(next.exportJSON(), forKey: Self.defaultsKey)
        DispatchQueue.main.async { Self.refreshMenus(NSApp.mainMenu) }
    }

    private static func refreshMenus(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items { refreshMenus(item.submenu) }
    }

    func shortcut(_ id: String) -> KeyboardShortcut? {
        keymap.chord(for: id)?.keyboardShortcut
    }

    func display(_ id: String) -> String {
        keymap.chord(for: id)?.display ?? ""
    }

    func labeled(_ title: String, _ id: String) -> String {
        let text = display(id)
        return text.isEmpty ? title : "\(title) (\(text))"
    }

    func applyMenuShortcut(_ id: String, to item: NSMenuItem) {
        guard let (equivalent, mask) = keymap.chord(for: id)?.appKitMenuShortcut else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = mask
    }

    var preset: KeymapPreset {
        get { keymap.preset }
        set { update { $0.switchPreset(newValue) } }
    }

    var completionAcceptKey: CompletionAcceptKey {
        get { keymap.completionAcceptKey }
        set { update { $0.setCompletionAcceptKey(newValue) } }
    }

    @discardableResult
    func assign(_ chord: KeyChord?, to id: String, replacing: Bool = false) -> Keymap.AssignResult {
        var result = Keymap.AssignResult.assigned
        update { result = $0.assign(chord, to: id, replacing: replacing) }
        return result
    }

    func reset(_ id: String) { update { $0.reset(id) } }
    func resetAll() { update { $0.resetAll() } }
    func replace(with keymap: Keymap) { update { $0 = keymap } }
}

extension KeyChord {
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent else { return nil }
        var modifiers: EventModifiers = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    var appKitMenuShortcut: (String, NSEvent.ModifierFlags)? {
        let equivalentString: String?
        switch key {
        case "up": equivalentString = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": equivalentString = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": equivalentString = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": equivalentString = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "enter": equivalentString = "\r"
        case "tab": equivalentString = "\t"
        case "space": equivalentString = " "
        case "escape": equivalentString = "\u{1B}"
        case "backspace": equivalentString = String(UnicodeScalar(NSBackspaceCharacter)!)
        case "delete": equivalentString = String(UnicodeScalar(NSDeleteCharacter)!)
        case "home": equivalentString = String(UnicodeScalar(NSHomeFunctionKey)!)
        case "end": equivalentString = String(UnicodeScalar(NSEndFunctionKey)!)
        case "pageup": equivalentString = String(UnicodeScalar(NSPageUpFunctionKey)!)
        case "pagedown": equivalentString = String(UnicodeScalar(NSPageDownFunctionKey)!)
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                equivalentString = String(scalar)
            } else if key.count == 1 {
                equivalentString = key.lowercased()
            } else {
                equivalentString = nil
            }
        }
        guard let equivalentString else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if control { mask.insert(.control) }
        if option { mask.insert(.option) }
        if shift { mask.insert(.shift) }
        if command { mask.insert(.command) }
        return (equivalentString, mask)
    }

    private var equivalent: KeyEquivalent? {
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "enter": return .return
        case "tab": return .tab
        case "space": return .space
        case "escape": return .escape
        case "backspace": return .delete
        case "delete": return .deleteForward
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = Unicode.Scalar(NSF1FunctionKey + n - 1) {
                return KeyEquivalent(Character(scalar))
            }
            return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    init?(event: NSEvent) {
        let specials: [UInt16: String] = [
            126: "up", 125: "down", 123: "left", 124: "right", 36: "enter", 76: "enter", 48: "tab", 49: "space", 53: "escape",
            51: "backspace", 117: "delete", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
            103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19",
        ]
        let flags = event.modifierFlags
        let name: String
        if let special = specials[event.keyCode] {
            name = special
        } else if let typed = event.characters(byApplyingModifiers: []), typed.count == 1 {
            name = typed.lowercased()
        } else {
            return nil
        }
        self.init(key: name, control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command))
    }
}

extension WorkspaceState.Navigator {
    var keymapID: String { "view.navigator.\(self)" }
}
