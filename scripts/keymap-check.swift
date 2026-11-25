// Self-check for keymaps (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/keymap-check.swift $T/main.swift && swiftc desktop/Utilities/Keymap*.swift $T/main.swift -o $T/kc && $T/kc
// Covers the command registry, the three presets, conflicts, overrides and reset, VS Code JSONC and GoLand XML import, and export round-trip.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let ids = KeymapCommand.all.map(\.id)
expect(Set(ids).count == ids.count, "command IDs are unique")
for c in KeymapCommand.all { expect(!c.title.isEmpty && !c.menu.isEmpty, "\(c.id) has a title and menu") }

let shipped: [String: String] = [
    "file.newFile": "⌘N", "file.newFolder": "⌥⌘N", "file.newWindow": "⌃⇧⌘N", "file.newScratch": "⌃⌥⌘N", "file.newProject": "⇧⌘N", "file.openProject": "⌘O",
    "file.openQuickly": "⇧⌘O", "file.closeTab": "⌘W", "file.closeWindow": "⇧⌘W", "file.save": "⌘S", "file.localHistory": "⌃⇧H",
    "edit.duplicate": "⌘D", "edit.pasteJSONAsStruct": "⇧⌘V", "edit.expandSelection": "⌃⇧↑", "edit.shrinkSelection": "⌃⇧↓", "edit.addCursorAbove": "⌥⌘↑", "edit.addCursorBelow": "⌥⌘↓",
    "edit.joinLines": "⌃⇧J", "edit.moveLineUp": "⌥↑", "edit.moveLineDown": "⌥↓", "edit.moveStatementUp": "⌥⌘[", "edit.moveStatementDown": "⌥⌘]",
    "view.commandPalette": "⇧⌘P", "view.console": "⇧⌘Y", "view.toggleWordWrap": "⌥Z", "view.quickDocumentation": "⌃⌘?", "view.quickDefinition": "⌥Space", "view.parameterInfo": "⇧⌘Space", "view.documentationBrowser": "⇧⌘0",
    "view.fold": "⌥⌘←", "view.unfold": "⌥⌘→", "view.foldAll": "⌥⇧⌘←", "view.unfoldAll": "⌥⇧⌘→",
    "view.zoomIn": "⌘+", "view.zoomOut": "⌘-", "view.actualSize": "⌃⌘0", "view.navigator": "⌘0",
    "view.navigator.files": "⌘1", "view.navigator.git": "⌘2", "view.navigator.search": "⌘3", "view.navigator.issues": "⌘4", "view.navigator.tests": "⌘5",
    "view.codeReview": "⌥⇧⌘↩", "view.previousTab": "⇧⌘[", "view.nextTab": "⇧⌘]",
    "find.find": "⌘F", "find.findNext": "⌘G", "find.findPrevious": "⇧⌘G", "find.findInProject": "⇧⌘F",
    "find.useSelection": "⌘E", "find.selectNextOccurrence": "⌥⌘E",
    "navigate.back": "⌘[", "navigate.forward": "⌘]", "navigate.recentFiles": "⇧⌘E", "navigate.symbolInFile": "⌃6",
    "navigate.workspaceSymbol": "⌥⌘O", "navigate.goToLine": "⌘L", "navigate.definition": "⌃⌘J", "navigate.implementation": "⌃⌘I",
    "navigate.typeDefinition": "⌃⇧⌘T", "navigate.references": "⌥⇧⌘F", "navigate.jumpToTest": "⇧⌘T", "navigate.callHierarchy": "⌃⌥H",
    "navigate.typeHierarchy": "⌃H", "navigate.packageDependencies": "⌃⌥G", "navigate.toggleBookmark": "⌘F2", "navigate.nextBookmark": "F3",
    "navigate.previousBookmark": "⇧F3", "navigate.nextChange": "⌃\\", "navigate.previousChange": "⌃⇧\\",
    "navigate.nextIssue": "⌘'", "navigate.previousIssue": "⇧⌘'",
    "editor.toggleComment": "⌘/", "editor.format": "⌥⇧F", "editor.organizeImports": "⌃⌥O", "editor.codeActions": "⌥↩", "editor.completeStatement": "⌥⌘↩", "editor.showSuggestion": "⌥\\",
    "refactor.rename": "F2", "refactor.changeSignature": "⌘F6", "refactor.moveSymbol": "⌃F6",
    "refactor.extractFunction": "⌥⌘M", "refactor.extractVariable": "⌥⌘V", "refactor.extractType": "⌥⌘T", "refactor.inlineVariable": "⌥⌘I",
    "refactor.implementInterface": "⌃I", "refactor.propagateMethod": "⌃⌥P", "refactor.handleError": "⌃⌥E",
    "generate.constructorOptions": "⌃⌥N", "generate.fillStruct": "⌃⌥F", "generate.structTags": "⌃⌥T", "generate.jsonToStruct": "⌃⌥V",
    "generate.enumStringer": "⌃⌥S", "generate.tableTest": "⌃⇧T", "generate.fuzzTest": "⌃⌥U",
    "generate.benchmark": "⌃⌥7", "generate.mock": "⌃⌥M",
    "inspect.structLayout": "⌃⌥L", "inspect.complexity": "⌃⌥Q", "inspect.disassembly": "⌃⇧D",
    "product.run": "⌘R", "product.debug": "⇧⌘R", "product.attach": "⌃⌥⌘A", "product.build": "⌘B", "product.stop": "⌘.",
    "product.test": "⌘U", "product.testAtCursor": "⌃⇧R", "product.debugTestAtCursor": "⌃⌥R", "product.rerunFailed": "⌥⌘U", "product.coverage": "⌃⇧⌘U",
    "product.runHTTPRequest": "⌃↩", "product.runAllHTTPRequests": "⌃⇧↩", "database.runStatement": "⌘↩", "database.submitChanges": "⇧⌘↩",
    "product.profile": "⌃⇧⌘P", "product.profileTests": "⌃⌥⌘P", "product.benchmarks": "⌃⌘U", "product.compareBenchmarks": "⌃⌥B",
    "product.safetyAudit": "⌃⇧⌘S",
    "debug.continue": "⌃⌘Y", "debug.pause": "⌃⌘Y", "debug.runToCursor": "⌃⌘C", "debug.stepOver": "F6", "debug.stepInto": "F7", "debug.stepOut": "F8", "debug.evaluate": "⌥F8",
    "sc.commit": "⌥⌘C", "sc.commitChanges": "⌥⇧⌘C", "sc.pull": "⌥⌘X",
    "help.diagnostics": "⌃⌥⌘D",
]
let golens = Keymap()
for c in KeymapCommand.all where !c.isSystemOnly {
    expect((golens.chord(for: c.id)?.display ?? "") == (shipped[c.id] ?? ""), "GoLens preset keeps the shipped shortcut of \(c.id): \(golens.chord(for: c.id)?.display ?? "none") vs \(shipped[c.id] ?? "none")")
}
expect(shipped.count == 130, "125 menu shortcuts plus five navigators are shipped (got \(shipped.count))")
expect(golens.completionAcceptKey == .tab, "GoLens accepts completions with Tab")
expect(Keymap(preset: .vscode).completionAcceptKey == .returnKey && Keymap(preset: .goland).completionAcceptKey == .returnKey, "VS Code and GoLand accept with Return")

expect(golens.chord(for: "navigate.implementation") != golens.chord(for: "editor.format"), "Go to Implementation and Format Document do not collide")
expect(golens.chord(for: "file.localHistory") != golens.chord(for: "navigate.callHierarchy"), "Show Local History and Call Hierarchy do not collide")
expect(golens.chord(for: "editor.organizeImports") != golens.chord(for: "inspect.prealloc"), "Organize Imports and Preallocation Inspector do not collide")
expect(golens.commands(using: KeyChord("ctrl+alt+o")!).map(\.id) == ["editor.organizeImports"], "ctrl+alt+o belongs exclusively to Organize Imports")
expect(golens.chord(for: "file.newFolder") != golens.chord(for: "refactor.inlineVariable"), "New Folder and Inline Variable do not collide")
for c in KeymapCommand.all {
    expect(golens.conflicts(for: c.id).isEmpty, "GoLens preset has zero conflicts for \(c.id)")
    if let chord = golens.chord(for: c.id) {
        let others = golens.commands(using: chord, except: c.id).filter { !Keymap.sharedPairs.contains([c.id, $0.id]) }
        expect(others.isEmpty, "GoLens preset assigns \(chord.display) uniquely to \(c.id), apart from declared pairs")
    }
}

// Presets: every ID valid, every chord parses, no shortcut shared except the declared pairs.
for preset in KeymapPreset.allCases {
    for (id, text) in preset.explicit {
        expect(Keymap.commandsByID[id] != nil, "\(preset.title) maps a known command: \(id)")
        if let text { expect(KeyChord(text) != nil, "\(preset.title) \(id) parses: \(text)") }
        expect(Keymap.commandsByID[id]?.isSystem != true, "\(preset.title) does not remap a system shortcut: \(id)")
    }
    var byChord: [KeyChord: [String]] = [:]
    for (id, chord) in Keymap.presetTable(preset) { byChord[chord, default: []].append(id) }
    for (chord, users) in byChord where users.count > 1 {
        expect(users.count == 2 && Keymap.sharedPairs.contains(Set(users)), "\(preset.title): \(chord.display) is shared only on purpose: \(users.sorted())")
    }
}
for pair in Keymap.sharedPairs { for id in pair { expect(Keymap.commandsByID[id] != nil, "shared pair names a known command: \(id)") } }

let vs = Keymap(preset: .vscode)
for (id, display) in ["file.openQuickly": "⌘P", "view.commandPalette": "⇧⌘P", "navigate.definition": "F12", "navigate.references": "⇧F12",
                      "refactor.rename": "F2", "editor.toggleComment": "⌘/", "editor.format": "⌥⇧F", "view.console": "⌃`", "product.build": "⇧⌘B",
                      "find.findNext": "⌘G", "find.findPrevious": "⇧⌘G", "view.toggleWordWrap": "⌥Z", "view.previousTab": "⇧⌘[", "view.nextTab": "⇧⌘]",
                      "navigate.nextIssue": "F8", "navigate.previousIssue": "⇧F8", "debug.stepOut": "⇧F11", "debug.pause": "F6",
                      "edit.joinLines": "⌃J", "edit.moveLineUp": "⌥↑", "edit.moveLineDown": "⌥↓", "view.quickDefinition": "⌥F12"] {
    expect(vs.chord(for: id)?.display == display, "VS Code \(id) is \(display), got \(vs.chord(for: id)?.display ?? "none")")
}
expect(vs.conflicts(for: "product.debug").isEmpty, "declared shared pairs aren't reported")
expect(vs.chord(for: "inspect.structLayout")?.display == "⌃⌥L", "GoLens-only commands keep their shortcut in VS Code")
expect(vs.chord(for: "product.stop")?.display == "⇧F5", "VS Code Stop is ⇧F5, so ⌘. goes to Quick Fix")
expect(vs.chord(for: "edit.moveStatementUp") == nil && vs.chord(for: "edit.moveStatementDown") == nil, "VS Code folds with ⌥⌘[ and ⌥⌘], so Move Statement has no VS Code shortcut")
let gl = Keymap(preset: .goland)
for (id, display) in ["navigate.definition": "⌘B", "navigate.implementation": "⌥⌘B", "navigate.references": "⌥F7", "refactor.rename": "⇧F6",
                      "editor.format": "⌥⌘L", "view.commandPalette": "⇧⌘A", "product.build": "⌘F9", "debug.stepOver": "F8",
                      "find.findNext": "⌘G", "find.findPrevious": "⇧⌘G", "view.previousTab": "⇧⌘[", "view.nextTab": "⇧⌘]",
                      "navigate.nextIssue": "F2", "navigate.previousIssue": "⇧F2", "debug.runToCursor": "⌥F9", "editor.surroundWith": "⌥⌘T",
                      "editor.completeStatement": "⇧⌘↩", "database.submitChanges": "⌥⌘↩", "edit.joinLines": "⌃⇧J",
                      "edit.moveLineUp": "⌥⇧↑", "edit.moveLineDown": "⌥⇧↓", "edit.moveStatementUp": "⇧⌘↑", "edit.moveStatementDown": "⇧⌘↓", "view.quickDefinition": "⌥Space"] {
    expect(gl.chord(for: id)?.display == display, "GoLand \(id) is \(display), got \(gl.chord(for: id)?.display ?? "none")")
}
expect(gl.chord(for: "debug.pause") == nil, "GoLand pauses from the toolbar, without a shortcut")
expect(gl.chord(for: "find.useSelection") == nil, "GoLand drops ⌘E Use Selection for Find because ⌘E is Recent Files")
expect(gl.chord(for: "view.zoomOut")?.display == "⌃⇧,", "GoLand zooms the editor font with ⌃⇧, and ⌘- folds")
expect(golens.chord(for: "view.quickDocumentation")?.display == "⌃⌘?" && vs.chord(for: "view.quickDocumentation")?.display == "⌃⌘?", "Quick Documentation is ⌃⌘? (Xcode's Quick Help key) in GoLens and VS Code")
expect(gl.chord(for: "view.quickDocumentation")?.display == "F1", "GoLand keeps F1 for Quick Documentation")
for preset in KeymapPreset.allCases {
    let keymap = Keymap(preset: preset)
    for alternate in ["f1", "ctrl+shift+cmd+/", "ctrl+cmd+?"] {
        let users = keymap.commands(using: KeyChord(alternate)!).map(\.id)
        expect(users.isEmpty || users == ["view.quickDocumentation"], "\(preset.title): \(alternate) is free for Quick Documentation (used by \(users))")
    }
}

// Chord parsing and display.
expect(KeyChord("cmd++")?.key == "+" && KeyChord("cmd++")?.command == true, "cmd++ is Command-Plus")
expect(KeyChord("cmd+k cmd+c") == nil, "chord sequences are rejected")
expect(KeyChord("ctrl+alt+shift+cmd+k")?.display == "⌃⌥⇧⌘K", "modifiers display in HIG order")
expect(KeyChord("shift+alt+f")?.description == "alt+shift+f", "canonical text orders modifiers")
expect(KeyChord("hyper+k") == nil && KeyChord("cmd+") == nil && KeyChord("cmd+numpad0") == nil, "unknown modifiers and keys are rejected")

// Conflicts, overrides, reset.
var km = Keymap()
expect(km.assign(KeyChord("cmd+c"), to: "product.build") == .system(Keymap.commandsByID["edit.copy"]!), "a system shortcut is never taken")
expect(km.assign(KeyChord("cmd+k"), to: "file.save") == .system(Keymap.commandsByID["file.save"]!), "a system command can't be rebound")
let conflict = km.assign(KeyChord("cmd+r"), to: "product.build")
expect(conflict == .conflict([Keymap.commandsByID["product.run"]!]), "conflict names the other command")
expect(km.chord(for: "product.build")?.display == "⌘B", "a conflict changes nothing until replaced")
expect(km.assign(KeyChord("cmd+r"), to: "product.build", replacing: true) == .assigned, "replace assigns")
expect(km.chord(for: "product.build")?.display == "⌘R" && km.chord(for: "product.run") == nil, "replace clears the other command")
expect(km.source(for: "product.build") == .custom && km.source(for: "product.run") == .custom && km.source(for: "file.save") == .system, "sources")
km.reset("product.run")
expect(km.chord(for: "product.run")?.display == "⌘R" && km.source(for: "product.run") == .preset, "reset restores the preset")
expect(km.conflicts(for: "product.run").map(\.id) == ["product.build"], "conflicts list the other user of a shortcut")
expect(km.conflicts(for: "editor.format").isEmpty, "editor.format has zero conflicts")
expect(km.assign(KeyChord("cmd+b"), to: "product.build") == .assigned && km.overrides.isEmpty, "assigning the preset shortcut drops the override")
expect(km.assign(KeyChord("ctrl+alt+cmd+k"), to: "git.stageHunk") == .assigned, "a free shortcut assigns")
km.assign(nil, to: "debug.stepOver")
expect(km.chord(for: "debug.stepOver") == nil && km.source(for: "debug.stepOver") == .custom, "clearing is an override")
km.setCompletionAcceptKey(.returnKey)
km.switchPreset(.vscode)
expect(km.chord(for: "git.stageHunk")?.display == "⌃⌥⌘K" && km.completionAcceptKeyOverride == nil && km.completionAcceptKey == .returnKey, "switching preset keeps overrides and drops ones that now match")
km.resetAll()
expect(km.overrides.isEmpty && km == Keymap(preset: .vscode), "reset all returns to the preset")

// Export and import round-trip.
var custom = Keymap(preset: .goland)
custom.assign(KeyChord("ctrl+alt+cmd+k"), to: "git.stageHunk")
custom.assign(nil, to: "navigate.definition")
custom.setCompletionAcceptKey(.tab)
let exported = custom.exportJSON()
expect(Keymap.isExport(exported), "export is recognized")
let restored = try! Keymap.importJSON(exported)
expect(restored.keymap == custom && restored.skipped.isEmpty, "import restores the exported keymap")
let foreign = #"{"format":"golens-keymap","version":1,"preset":"golens","overrides":{"nope.command":"cmd+k","file.save":"cmd+k","product.run":"cmd+k cmd+r"}}"#
let partial = try! Keymap.importJSON(Data(foreign.utf8))
expect(partial.skipped.count == 3 && partial.keymap.overrides.isEmpty, "unknown, system and chord entries are skipped")
expect((try? Keymap.importJSON(Data("[]".utf8))) == nil, "a non-export file is refused")

// VS Code keybindings.json (JSONC).
let vscodeSample = """
// Place your key bindings in this file to override the defaults
[
    /* build with F9 */
    { "key": "f9", "command": "workbench.action.tasks.build" },
    { "key": "cmd+k cmd+c", "command": "editor.action.commentLine", "when": "editorTextFocus" },
    { "key": "ctrl+alt+r", "command": "editor.action.rename", "when": "editorHasRenameProvider && editorTextFocus" },
    { "key": "f2", "command": "-editor.action.rename" },
    { "key": "cmd+i", "command": "workbench.action.chat.open" },
    { "key": "cmd+c", "command": "workbench.action.quickOpen" },
    { "key": "cmd+// not a comment", "command": "editor.action.commentLine" },
    { "key": "shift+f12", "command": "-editor.action.goToReferences" },
    { "key": "alt+cmd+t", "command": "go.toggle.test.file", },
]
"""
let (vsKeymap, vsReport) = try! KeymapImport.vscode(vscodeSample)
expect(vsKeymap.preset == .vscode, "VS Code import starts from the VS Code preset")
expect(vsKeymap.chord(for: "product.build")?.display == "F9", "f9 builds")
expect(vsKeymap.chord(for: "refactor.rename")?.display == "⌃⌥R", "rename moved to ctrl+alt+r")
expect(vsKeymap.chord(for: "navigate.references") == nil, "the -command removal cleared the default")
expect(vsKeymap.chord(for: "navigate.jumpToTest")?.display == "⌥⌘T" && vsKeymap.chord(for: "refactor.extractType") == nil, "Go extension command imported; the shortcut it took is cleared")
expect(vsKeymap.chord(for: "file.openQuickly")?.display == "⌘P", "a system shortcut isn't imported")
expect(vsReport.notImported.contains { $0.contains("cmd+k cmd+c") && $0.contains("chord") }, "chords are reported")
expect(vsReport.notImported.contains { $0.hasPrefix("workbench.action.chat.open") }, "unknown commands are listed")
expect(vsReport.notImported.contains { $0.contains("standard macOS shortcut") || $0.contains("used by macOS") }, "system shortcut is reported")
expect(vsReport.notes.contains { $0.contains("2 “when” clauses") }, "when clauses are noted: \(vsReport.notes)")
expect(vsReport.removed.contains("Find References"), "removals are reported")
expect((try? KeymapImport.vscode("{\"key\": 1}")) == nil, "a non-array file is refused")

// GoLand keymap XML.
let golandSample = """
<keymap version="1" name="Sang" parent="Mac OS X 10.5+">
  <action id="ReformatCode">
    <keyboard-shortcut first-keystroke="meta alt L" />
    <keyboard-shortcut first-keystroke="shift meta F" />
  </action>
  <action id="RenameElement"><keyboard-shortcut first-keystroke="control shift R" /></action>
  <action id="GotoDeclaration"><keyboard-shortcut first-keystroke="meta K" second-keystroke="meta D" /></action>
  <action id="CommentByLineComment"><keyboard-shortcut first-keystroke="control SLASH" /></action>
  <action id="FindUsages" />
  <action id="Vcs.ShowTabbedFileHistory"><keyboard-shortcut first-keystroke="shift meta OPEN_BRACKET" /></action>
  <action id="EditorBackSpace"><keyboard-shortcut first-keystroke="BACK_SPACE" /></action>
  <action id="GotoImplementation"><mouse-shortcut keystroke="meta alt button1" /></action>
</keymap>
"""
let (glKeymap, glReport) = try! KeymapImport.goland(golandSample)
expect(glKeymap.preset == .goland && glReport.notes.allSatisfy { !$0.contains("Parent keymap") }, "the macOS parent is the GoLand preset")
expect(glKeymap.chord(for: "editor.format")?.display == "⌥⌘L", "first keystroke kept")
expect(glReport.notes.contains { $0.contains("⇧⌘F") }, "extra keystrokes are noted")
expect(glKeymap.chord(for: "refactor.rename")?.display == "⌃⇧R", "rename imported")
expect(glKeymap.chord(for: "navigate.definition")?.display == "⌘B", "a chord leaves the preset shortcut")
expect(glReport.notImported.contains { $0.hasPrefix("GotoDeclaration") && $0.contains("chord") }, "chord reported")
expect(glKeymap.chord(for: "editor.toggleComment")?.display == "⌃/", "SLASH parsed")
expect(glKeymap.chord(for: "navigate.references") == nil && glReport.removed.contains("Find References"), "empty action removes")
expect(glKeymap.chord(for: "git.fileHistory")?.display == "⇧⌘[" && glKeymap.chord(for: "view.previousTab") == nil, "OPEN_BRACKET parsed, and it takes the shortcut from Select Previous Tab")
expect(glReport.notImported.contains { $0.hasPrefix("EditorBackSpace") }, "unmapped action listed")
expect(glReport.notes.contains { $0.contains("1 mouse shortcut") }, "mouse shortcuts noted")
let (_, otherParent) = try! KeymapImport.goland(#"<keymap version="1" name="X" parent="Emacs"/>"#)
expect(otherParent.notes.contains { $0.contains("Emacs") }, "an unknown parent is reported")
expect((try? KeymapImport.goland("<settings/>")) == nil, "a non-keymap XML is refused")

print("keymap-check: OK (\(KeymapCommand.all.count) commands, \(KeymapCommand.all.filter { !$0.isSystemOnly }.count) in GoLens menus)")
