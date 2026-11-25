import AppKit

struct EditorCursor: Equatable {
    var anchor: Int
    var head: Int
    var column: Int?

    init(anchor: Int, head: Int, column: Int? = nil) {
        self.anchor = anchor
        self.head = head
        self.column = column
    }

    init(_ range: NSRange) {
        self.init(anchor: range.location, head: NSMaxRange(range))
    }

    var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    var isEmpty: Bool { anchor == head }
}

final class MultiCursorState {
    struct Snapshot {
        var cursors: [EditorCursor]
        var primary: Int
        var single: NSRange
    }

    struct TypingRun {
        let token: NSObject
        let before: NSString
        let restore: Snapshot
        var version: Int
        var cursors: [EditorCursor]
    }

    var cursors: [EditorCursor] = []
    var primary = 0
    var applying = false
    var indicators: [NSTextInsertionIndicator] = []
    var typingRun: TypingRun?
    var columnAnchor: NSPoint?
    var columnDragged = false
    var columnBase: [EditorCursor] = []
}

extension GoLensTextView {
    var hasMultipleCursors: Bool { multiCursor.cursors.count > 1 }

    @objc var multiCursorSummary: String {
        guard hasMultipleCursors else { return "single \(NSStringFromRange(selectedRange()))" }
        let list = multiCursor.cursors.map { $0.isEmpty ? "\($0.head)" : "\($0.anchor)-\($0.head)" }.joined(separator: ",")
        return "count=\(multiCursor.cursors.count) primary=\(multiCursor.primary) cursors=\(list) indicators=\(multiCursor.indicators.count)"
    }

    private func currentCursors() -> [EditorCursor] {
        hasMultipleCursors ? multiCursor.cursors : [EditorCursor(selectedRange())]
    }

    private func snapshot() -> MultiCursorState.Snapshot {
        MultiCursorState.Snapshot(cursors: multiCursor.cursors, primary: multiCursor.primary, single: selectedRange())
    }

    private func restore(_ snapshot: MultiCursorState.Snapshot) {
        if snapshot.cursors.count > 1 {
            setCursors(snapshot.cursors, primary: snapshot.primary)
        } else {
            setCursors([EditorCursor(snapshot.single)], primary: 0)
        }
    }

    func setCursors(_ list: [EditorCursor], primary requested: Int, scrollTo: Int? = nil, keepsTypingRun: Bool = false) {
        let length = textStorage?.length ?? 0
        var indexed = list.enumerated().map { offset, cursor -> (cursor: EditorCursor, isPrimary: Bool) in
            var clamped = cursor
            clamped.anchor = min(max(0, cursor.anchor), length)
            clamped.head = min(max(0, cursor.head), length)
            return (clamped, offset == requested)
        }
        indexed.sort { $0.cursor.range.location != $1.cursor.range.location ? $0.cursor.range.location < $1.cursor.range.location : $0.cursor.range.length < $1.cursor.range.length }
        var merged: [(cursor: EditorCursor, isPrimary: Bool)] = []
        for item in indexed {
            guard let last = merged.last else { merged.append(item); continue }
            let a = last.cursor.range, b = item.cursor.range
            let overlaps = b.location < NSMaxRange(a) || b.location == a.location
            if overlaps {
                let union = NSUnionRange(a, b)
                let forward = item.cursor.head >= item.cursor.anchor
                let combined = forward ? EditorCursor(anchor: union.location, head: NSMaxRange(union), column: item.cursor.column)
                                       : EditorCursor(anchor: NSMaxRange(union), head: union.location, column: item.cursor.column)
                merged[merged.count - 1] = (combined, last.isPrimary || item.isPrimary)
            } else {
                merged.append(item)
            }
        }
        if !keepsTypingRun { multiCursor.typingRun = nil }
        let primaryIndex = merged.firstIndex(where: \.isPrimary) ?? max(0, merged.count - 1)
        let wasMultiple = hasMultipleCursors
        if merged.count > 1 {
            if !wasMultiple {
                CompletionController.shared.dismiss()
                inlineSuggestions.dismiss()
            }
            multiCursor.cursors = merged.map(\.cursor)
            multiCursor.primary = primaryIndex
        } else {
            multiCursor.cursors = []
            multiCursor.primary = 0
        }
        let native = merged.isEmpty ? selectedRange() : merged[primaryIndex].cursor.range
        multiCursor.applying = true
        setSelectedRange(native)
        multiCursor.applying = false
        if let scrollTo, merged.indices.contains(scrollTo) {
            scrollRangeToVisible(NSRange(location: merged[scrollTo].cursor.head, length: 0))
        }
        refreshMultiCursorDisplay()
        if wasMultiple || hasMultipleCursors { updateMultiCursorStatus() }
    }

    func endMultiCursor() {
        guard hasMultipleCursors || !multiCursor.indicators.isEmpty else { return }
        multiCursor.cursors = []
        multiCursor.primary = 0
        multiCursor.typingRun = nil
        refreshMultiCursorDisplay()
        updateMultiCursorStatus()
    }

    private func updateMultiCursorStatus() {
        let workspace = workspaceState
        guard paneID == workspace.effectiveFocusedPaneID else { return }
        let selected = selectedRange()
        let (line, col) = lineAndCol(forCharacterIndex: selected.location)
        var position = "Ln \(line), Col \(col)"
        if hasMultipleCursors {
            let total = multiCursor.cursors.reduce(0) { $0 + $1.range.length }
            position += total > 0 ? " (\(multiCursor.cursors.count) cursors, \(total) selected)" : " (\(multiCursor.cursors.count) cursors)"
        } else if selected.length > 0 {
            position += " (\(selected.length) selected)"
        }
        if workspace.displayCursorPosition != position { workspace.displayCursorPosition = position }
    }

    func caretRect(at index: Int) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        let length = storage.length
        let fallbackHeight = layoutManager.defaultLineHeight(for: font ?? lineNumberFont)
        if length == 0 {
            return NSRect(x: origin.x + textContainer.lineFragmentPadding, y: origin.y, width: 0, height: fallbackHeight)
        }
        if index >= length {
            let ns = storage.mutableString
            if ns.character(at: length - 1) == 0x0A {
                let extra = layoutManager.extraLineFragmentRect
                if extra.height > 0 {
                    return NSRect(x: origin.x + extra.minX + textContainer.lineFragmentPadding, y: origin.y + extra.minY, width: 0, height: extra.height)
                }
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            return NSRect(x: origin.x + rect.maxX, y: origin.y + rect.minY, width: 0, height: rect.height)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return NSRect(x: origin.x + fragment.minX + location.x, y: origin.y + fragment.minY, width: 0, height: fragment.height)
    }

    func refreshMultiCursorDisplay() {
        let extras = hasMultipleCursors ? multiCursor.cursors.enumerated().filter { $0.offset != multiCursor.primary }.map(\.element) : []
        while multiCursor.indicators.count > extras.count {
            multiCursor.indicators.removeLast().removeFromSuperview()
        }
        while multiCursor.indicators.count < extras.count {
            let indicator = NSTextInsertionIndicator(frame: .zero)
            addSubview(indicator)
            multiCursor.indicators.append(indicator)
        }
        let focused = window?.firstResponder === self
        for (indicator, cursor) in zip(multiCursor.indicators, extras) {
            if let rect = caretRect(at: cursor.head) {
                indicator.frame = NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
            }
            indicator.color = insertionPointColor
            indicator.displayMode = focused ? .automatic : .hidden
        }
        setNeedsDisplay(visibleRect)
    }

    func drawMultiCursorSelections(in dirtyRect: NSRect) {
        guard hasMultipleCursors, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let focused = window?.firstResponder === self
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        for (offset, cursor) in multiCursor.cursors.enumerated() where offset != multiCursor.primary && !cursor.isEmpty {
            let glyphs = layoutManager.glyphRange(forCharacterRange: cursor.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer) { rect, _ in
                let shifted = rect.offsetBy(dx: origin.x, dy: origin.y)
                if shifted.intersects(dirtyRect) { shifted.fill() }
            }
        }
    }

    private var indentUnit: String {
        editorIndentUnit(forPath: filePath, tabSize: workspaceState.tabSize)
    }

    private func lineBounds(at index: Int, in ns: NSString) -> (start: Int, contentsEnd: Int, end: Int) {
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(index, ns.length), length: 0))
        return (start, contentsEnd, end)
    }

    private func visualColumn(of index: Int, in ns: NSString) -> Int {
        let line = lineBounds(at: index, in: ns)
        let tab = max(1, workspaceState.tabSize)
        var column = 0
        var i = line.start
        while i < min(index, line.contentsEnd) {
            column = ns.character(at: i) == 0x09 ? (column / tab + 1) * tab : column + 1
            i += 1
        }
        return column
    }

    private func index(forVisualColumn target: Int, lineStart: Int, contentsEnd: Int, in ns: NSString) -> Int {
        let tab = max(1, workspaceState.tabSize)
        var column = 0
        var i = lineStart
        while i < contentsEnd {
            let next = ns.character(at: i) == 0x09 ? (column / tab + 1) * tab : column + 1
            if next > target { return target - column >= next - target ? i + 1 : i }
            column = next
            i += 1
        }
        return contentsEnd
    }

    private func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F
    }

    private func wordBoundary(from index: Int, forward: Bool, in ns: NSString) -> Int {
        var i = index
        if forward {
            while i < ns.length, !isWordCharacter(ns.character(at: i)) { i += 1 }
            while i < ns.length, isWordCharacter(ns.character(at: i)) { i += 1 }
        } else {
            while i > 0, !isWordCharacter(ns.character(at: i - 1)) { i -= 1 }
            while i > 0, isWordCharacter(ns.character(at: i - 1)) { i -= 1 }
        }
        return i
    }

    private func replace(_ edits: [(range: NSRange, text: String)]) -> Bool {
        guard let storage = textStorage, !edits.isEmpty else { return false }
        let allowed = allowsUndo
        allowsUndo = false
        defer { allowsUndo = allowed }
        guard shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) else { return false }
        CompletionController.shared.suppressed = true
        defer { CompletionController.shared.suppressed = false }
        storage.beginEditing()
        for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        didChangeText()
        return true
    }

    private func registerUndo(token: NSObject, range: NSRange, text: String, restore: MultiCursorState.Snapshot,
                              counterpart: MultiCursorState.Snapshot, actionName: String) {
        guard let undo = undoManager else { return }
        let topLevel = !undo.isUndoing && !undo.isRedoing
        let groupsByEvent = undo.groupsByEvent
        if topLevel {
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
        }
        undo.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self, let storage = self.textStorage, NSMaxRange(range) <= storage.length else { return }
            let replaced = storage.mutableString.substring(with: range)
            self.multiCursor.applying = true
            let changed = self.replace([(range, text)])
            self.multiCursor.applying = false
            guard changed else { return }
            self.restore(restore)
            self.registerUndo(token: token, range: NSRange(location: range.location, length: (text as NSString).length), text: replaced,
                              restore: counterpart, counterpart: restore, actionName: actionName)
        }
        undo.setActionName(actionName)
        if topLevel {
            undo.endUndoGrouping()
            undo.groupsByEvent = groupsByEvent
        }
    }

    private func apply(_ edits: [(range: NSRange, text: String)], cursors: [EditorCursor], primary: Int, typing: Bool, actionName: String) {
        guard let storage = textStorage else { return }
        let effective = edits.filter { $0.range.length > 0 || !$0.text.isEmpty }
        guard !effective.isEmpty else {
            setCursors(cursors, primary: primary, scrollTo: primary)
            return
        }
        let version = document?.version ?? -1
        var run = multiCursor.typingRun
        if !typing || run == nil || run?.version != version || run?.cursors != multiCursor.cursors {
            breakUndoCoalescing()
            run = MultiCursorState.TypingRun(token: NSObject(), before: storage.mutableString.copy() as? NSString ?? "", restore: snapshot(),
                                             version: version, cursors: [])
        } else if let run {
            undoManager?.removeAllActions(withTarget: run.token)
        }
        guard var run else { return }
        multiCursor.applying = true
        let changed = replace(effective)
        multiCursor.applying = false
        guard changed else { return }
        setCursors(cursors, primary: primary, scrollTo: primary, keepsTypingRun: true)
        let region = WorkspaceState.changedRegion(from: run.before, to: storage.mutableString)
        if region.old.length > 0 || region.new.length > 0 {
            registerUndo(token: run.token, range: region.new, text: run.before.substring(with: region.old), restore: run.restore,
                         counterpart: snapshot(), actionName: actionName)
        }
        run.version = document?.version ?? -1
        run.cursors = multiCursor.cursors
        multiCursor.typingRun = typing ? run : nil
    }

    private func applyPerCursor(typing: Bool = false, actionName: String = "Typing", _ edit: (EditorCursor, NSString) -> (range: NSRange, text: String, caret: Int, selects: Int)) {
        guard let storage = textStorage else { return }
        let ns = storage.mutableString
        var planned = multiCursor.cursors.map { edit($0, ns) }
        var i = 1
        while i < planned.count {
            if planned[i].range.location < NSMaxRange(planned[i - 1].range) {
                let union = NSUnionRange(planned[i - 1].range, planned[i].range)
                planned[i - 1] = (union, planned[i - 1].text + planned[i].text, planned[i - 1].caret, 0)
                planned.remove(at: i)
            } else {
                i += 1
            }
        }
        var shift = 0
        var cursors: [EditorCursor] = []
        for item in planned {
            let start = item.range.location + shift + item.caret
            cursors.append(EditorCursor(anchor: start, head: start + item.selects))
            shift += (item.text as NSString).length - item.range.length
        }
        let primary = min(multiCursor.primary, cursors.count - 1)
        apply(planned.map { ($0.range, $0.text) }, cursors: cursors, primary: primary, typing: typing, actionName: actionName)
    }

    func multiCursorInsert(_ string: String) {
        guard hasMultipleCursors, let storage = textStorage else { return }
        let ns = storage.mutableString
        let length = (string as NSString).length
        let cursors = multiCursor.cursors
        let allEmpty = cursors.allSatisfy(\.isEmpty)
        let openers: [String: String] = ["(": ")", "[": "]", "{": "}"]
        let wrappers: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
        if allEmpty, [")", "]", "}"].contains(string),
           cursors.allSatisfy({ $0.head < ns.length && ns.substring(with: NSRange(location: $0.head, length: 1)) == string }) {
            setCursors(cursors.map { EditorCursor(anchor: $0.head + 1, head: $0.head + 1) }, primary: multiCursor.primary, scrollTo: multiCursor.primary)
            return
        }
        if allEmpty, let closer = openers[string] {
            applyPerCursor(typing: true) { cursor, _ in (cursor.range, string + closer, length, 0) }
            return
        }
        if !allEmpty, cursors.allSatisfy({ !$0.isEmpty }), let closer = wrappers[string] {
            applyPerCursor { cursor, ns in
                let inner = ns.substring(with: cursor.range)
                return (cursor.range, string + inner + closer, length, cursor.range.length)
            }
            return
        }
        applyPerCursor(typing: true) { cursor, _ in (cursor.range, string, length, 0) }
    }

    func multiCursorCommitMarkedText(_ commit: () -> Void) {
        guard hasMultipleCursors, let storage = textStorage else { commit(); return }
        let marked = markedRange()
        let primaryIndex = multiCursor.primary
        let location = marked.location == NSNotFound ? selectedRange().location : marked.location
        let before = storage.length
        multiCursor.applying = true
        commit()
        multiCursor.applying = false
        let delta = storage.length - before
        let caret = selectedRange()
        let inserted = hasMarkedText() ? "" : storage.mutableString.substring(with: NSRange(location: location, length: max(0, caret.location - location)))
        var cursors = multiCursor.cursors
        for i in cursors.indices where i != primaryIndex && cursors[i].range.location > location {
            cursors[i].anchor += delta
            cursors[i].head += delta
        }
        cursors[primaryIndex] = EditorCursor(caret)
        multiCursor.cursors = cursors
        guard !hasMarkedText(), !inserted.isEmpty else {
            refreshMultiCursorDisplay()
            return
        }
        let length = (inserted as NSString).length
        var edits: [(range: NSRange, text: String)] = []
        var result: [EditorCursor] = []
        var shift = 0
        for (i, cursor) in cursors.enumerated() {
            if i == primaryIndex {
                result.append(EditorCursor(anchor: cursor.head + shift, head: cursor.head + shift))
                continue
            }
            edits.append((cursor.range, inserted))
            let start = cursor.range.location + shift + length
            result.append(EditorCursor(anchor: start, head: start))
            shift += length - cursor.range.length
        }
        apply(edits, cursors: result, primary: primaryIndex, typing: false, actionName: "Typing")
    }

    func multiCursorMarkedTextChanged(_ change: () -> Void) {
        guard hasMultipleCursors, let storage = textStorage else { change(); return }
        let primaryIndex = multiCursor.primary
        let marked = markedRange()
        let location = marked.location == NSNotFound ? multiCursor.cursors[primaryIndex].range.location : marked.location
        let before = storage.length
        multiCursor.applying = true
        change()
        multiCursor.applying = false
        let delta = storage.length - before
        for i in multiCursor.cursors.indices where i != primaryIndex && multiCursor.cursors[i].range.location > location {
            multiCursor.cursors[i].anchor += delta
            multiCursor.cursors[i].head += delta
        }
        multiCursor.cursors[primaryIndex] = EditorCursor(selectedRange())
        multiCursor.typingRun = nil
        refreshMultiCursorDisplay()
    }

    private func deleteEach(actionName: String = "Delete", _ target: (EditorCursor, NSString) -> NSRange) {
        applyPerCursor(actionName: actionName) { cursor, ns in
            (cursor.isEmpty ? target(cursor, ns) : cursor.range, "", 0, 0)
        }
    }

    private func insertNewlines() {
        let unit = indentUnit
        applyPerCursor { cursor, ns in
            let range = cursor.range
            let line = self.lineBounds(at: range.location, in: ns)
            var indentEnd = line.start
            while indentEnd < range.location, ns.character(at: indentEnd) == 0x20 || ns.character(at: indentEnd) == 0x09 { indentEnd += 1 }
            let indent = ns.substring(with: NSRange(location: line.start, length: indentEnd - line.start))
            var before = range.location
            while before > line.start, ns.character(at: before - 1) == 0x20 || ns.character(at: before - 1) == 0x09 { before -= 1 }
            let previous: unichar? = before > line.start ? ns.character(at: before - 1) : nil
            let next: unichar? = NSMaxRange(range) < ns.length ? ns.character(at: NSMaxRange(range)) : nil
            let pairs: [unichar: unichar] = [0x7B: 0x7D, 0x28: 0x29, 0x5B: 0x5D]
            if let previous, let closer = pairs[previous] {
                let head = "\n" + indent + unit
                if next == closer { return (range, head + "\n" + indent, (head as NSString).length, 0) }
                return (range, head, (head as NSString).length, 0)
            }
            let text = "\n" + indent
            return (range, text, (text as NSString).length, 0)
        }
    }

    private func shiftLines(outdent: Bool) {
        guard let storage = textStorage else { return }
        let ns = storage.mutableString
        let unit = indentUnit
        let unitLength = (unit as NSString).length
        var starts: [Int] = []
        for cursor in multiCursor.cursors {
            var position = lineBounds(at: cursor.range.location, in: ns).start
            let last = cursor.isEmpty ? cursor.head : max(cursor.range.location, NSMaxRange(cursor.range) - 1)
            while position <= last {
                if starts.last.map({ $0 < position }) ?? true { starts.append(position) }
                let line = lineBounds(at: position, in: ns)
                guard line.end > position else { break }
                position = line.end
                if position >= ns.length { break }
            }
        }
        var edits: [(range: NSRange, text: String)] = []
        for start in starts {
            if !outdent {
                edits.append((NSRange(location: start, length: 0), unit))
            } else if start < ns.length, ns.character(at: start) == 0x09 {
                edits.append((NSRange(location: start, length: 1), ""))
            } else {
                var count = 0
                while count < max(1, workspaceState.tabSize), start + count < ns.length, ns.character(at: start + count) == 0x20 { count += 1 }
                if count > 0 { edits.append((NSRange(location: start, length: count), "")) }
            }
        }
        func moved(_ position: Int) -> Int {
            var result = position
            for edit in edits {
                if !outdent, edit.range.location <= position { result += unitLength }
                if outdent, edit.range.location < position { result -= min(edit.range.length, position - edit.range.location) }
            }
            return result
        }
        let cursors = multiCursor.cursors.map { EditorCursor(anchor: moved($0.anchor), head: moved($0.head)) }
        apply(edits, cursors: cursors, primary: multiCursor.primary, typing: false, actionName: outdent ? "Outdent" : "Indent")
    }

    private func move(extend: Bool, _ target: (EditorCursor, NSString) -> (head: Int, column: Int?)) {
        guard let storage = textStorage else { return }
        let ns = storage.mutableString
        let cursors = multiCursor.cursors.map { cursor -> EditorCursor in
            let moved = target(cursor, ns)
            return EditorCursor(anchor: extend ? cursor.anchor : moved.head, head: moved.head, column: moved.column)
        }
        setCursors(cursors, primary: multiCursor.primary, scrollTo: multiCursor.primary)
    }

    private func moveHorizontally(forward: Bool, extend: Bool) {
        move(extend: extend) { cursor, ns in
            if !extend, !cursor.isEmpty { return (forward ? NSMaxRange(cursor.range) : cursor.range.location, nil) }
            if forward {
                guard cursor.head < ns.length else { return (cursor.head, nil) }
                return (NSMaxRange(ns.rangeOfComposedCharacterSequence(at: cursor.head)), nil)
            }
            guard cursor.head > 0 else { return (0, nil) }
            return (ns.rangeOfComposedCharacterSequence(at: cursor.head - 1).location, nil)
        }
    }

    private func verticalTarget(from cursor: EditorCursor, down: Bool, in ns: NSString) -> (head: Int, column: Int?) {
        let column = cursor.column ?? visualColumn(of: cursor.head, in: ns)
        let line = lineBounds(at: cursor.head, in: ns)
        if down {
            guard line.end > line.contentsEnd else { return (ns.length, column) }
            let next = lineBounds(at: line.end, in: ns)
            return (index(forVisualColumn: column, lineStart: next.start, contentsEnd: next.contentsEnd, in: ns), column)
        }
        guard line.start > 0 else { return (0, column) }
        let previous = lineBounds(at: line.start - 1, in: ns)
        return (index(forVisualColumn: column, lineStart: previous.start, contentsEnd: previous.contentsEnd, in: ns), column)
    }

    private func moveVertically(down: Bool, extend: Bool) {
        move(extend: extend) { cursor, ns in self.verticalTarget(from: cursor, down: down, in: ns) }
    }

    @objc func addCursorAbove(_ sender: Any?) { addCursor(down: false) }
    @objc func addCursorBelow(_ sender: Any?) { addCursor(down: true) }

    private func addCursor(down: Bool) {
        guard let storage = textStorage else { return }
        let ns = storage.mutableString
        var cursors = currentCursors()
        let primary = hasMultipleCursors ? multiCursor.primary : 0
        guard let edge = down ? cursors.last : cursors.first else { return }
        let column = edge.column ?? visualColumn(of: edge.head, in: ns)
        let line = lineBounds(at: edge.head, in: ns)
        if down ? line.end == line.contentsEnd : line.start == 0 { return }
        let target = verticalTarget(from: EditorCursor(anchor: edge.head, head: edge.head, column: column), down: down, in: ns)
        for i in cursors.indices where cursors[i].column == nil { cursors[i].column = visualColumn(of: cursors[i].head, in: ns) }
        let added = EditorCursor(anchor: target.head, head: target.head, column: column)
        if down { cursors.append(added) } else { cursors.insert(added, at: 0) }
        setCursors(cursors, primary: down ? primary : primary + 1, scrollTo: down ? cursors.count - 1 : 0)
    }

    func handleMultiCursorCommand(_ selector: Selector) -> Bool {
        guard hasMultipleCursors else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            let cursor = multiCursor.cursors[multiCursor.primary]
            setCursors([EditorCursor(anchor: cursor.head, head: cursor.head)], primary: 0)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
            moveHorizontally(forward: false, extend: false)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
            moveHorizontally(forward: true, extend: false)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)), #selector(NSResponder.moveBackwardAndModifySelection(_:)):
            moveHorizontally(forward: false, extend: true)
        case #selector(NSResponder.moveRightAndModifySelection(_:)), #selector(NSResponder.moveForwardAndModifySelection(_:)):
            moveHorizontally(forward: true, extend: true)
        case #selector(NSResponder.moveUp(_:)):
            moveVertically(down: false, extend: false)
        case #selector(NSResponder.moveDown(_:)):
            moveVertically(down: true, extend: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            moveVertically(down: false, extend: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            moveVertically(down: true, extend: true)
        case #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordBackward(_:)):
            move(extend: false) { cursor, ns in (self.wordBoundary(from: cursor.head, forward: false, in: ns), nil) }
        case #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordForward(_:)):
            move(extend: false) { cursor, ns in (self.wordBoundary(from: cursor.head, forward: true, in: ns), nil) }
        case #selector(NSResponder.moveWordLeftAndModifySelection(_:)), #selector(NSResponder.moveWordBackwardAndModifySelection(_:)):
            move(extend: true) { cursor, ns in (self.wordBoundary(from: cursor.head, forward: false, in: ns), nil) }
        case #selector(NSResponder.moveWordRightAndModifySelection(_:)), #selector(NSResponder.moveWordForwardAndModifySelection(_:)):
            move(extend: true) { cursor, ns in (self.wordBoundary(from: cursor.head, forward: true, in: ns), nil) }
        case #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)):
            move(extend: false) { cursor, ns in (self.lineBounds(at: cursor.head, in: ns).start, nil) }
        case #selector(NSResponder.moveToRightEndOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            move(extend: false) { cursor, ns in (self.lineBounds(at: cursor.head, in: ns).contentsEnd, nil) }
        case #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)), #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)):
            move(extend: true) { cursor, ns in (self.lineBounds(at: cursor.head, in: ns).start, nil) }
        case #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)), #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)):
            move(extend: true) { cursor, ns in (self.lineBounds(at: cursor.head, in: ns).contentsEnd, nil) }
        case #selector(NSResponder.deleteBackward(_:)):
            deleteEach { cursor, ns in
                guard cursor.head > 0 else { return cursor.range }
                return ns.rangeOfComposedCharacterSequence(at: cursor.head - 1)
            }
        case #selector(NSResponder.deleteForward(_:)):
            deleteEach { cursor, ns in
                guard cursor.head < ns.length else { return cursor.range }
                return ns.rangeOfComposedCharacterSequence(at: cursor.head)
            }
        case #selector(NSResponder.deleteWordBackward(_:)):
            deleteEach { cursor, ns in
                let start = self.wordBoundary(from: cursor.head, forward: false, in: ns)
                return NSRange(location: start, length: cursor.head - start)
            }
        case #selector(NSResponder.deleteWordForward(_:)):
            deleteEach { cursor, ns in
                let end = self.wordBoundary(from: cursor.head, forward: true, in: ns)
                return NSRange(location: cursor.head, length: end - cursor.head)
            }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleteEach { cursor, ns in
                let start = self.lineBounds(at: cursor.head, in: ns).start
                return NSRange(location: start, length: cursor.head - start)
            }
        case #selector(NSResponder.deleteToEndOfLine(_:)):
            deleteEach { cursor, ns in
                let end = self.lineBounds(at: cursor.head, in: ns).contentsEnd
                return NSRange(location: cursor.head, length: end - cursor.head)
            }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            insertNewlines()
        case #selector(NSResponder.insertTab(_:)):
            if multiCursor.cursors.allSatisfy(\.isEmpty) {
                let unit = indentUnit
                applyPerCursor(typing: true) { cursor, _ in (cursor.range, unit, (unit as NSString).length, 0) }
            } else {
                shiftLines(outdent: false)
            }
        case #selector(NSResponder.insertBacktab(_:)):
            shiftLines(outdent: true)
        default:
            return false
        }
        return true
    }

    func multiCursorCopy() -> Bool {
        guard hasMultipleCursors, let storage = textStorage else { return false }
        let ns = storage.mutableString
        let parts = multiCursor.cursors.map { cursor -> String in
            if !cursor.isEmpty { return ns.substring(with: cursor.range) }
            let line = lineBounds(at: cursor.head, in: ns)
            return ns.substring(with: NSRange(location: line.start, length: line.contentsEnd - line.start))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: "\n"), forType: .string)
        return true
    }

    func multiCursorCut() -> Bool {
        guard multiCursorCopy() else { return false }
        applyPerCursor(actionName: "Cut") { cursor, ns in
            if !cursor.isEmpty { return (cursor.range, "", 0, 0) }
            let line = self.lineBounds(at: cursor.head, in: ns)
            return (NSRange(location: line.start, length: line.end - line.start), "", 0, 0)
        }
        return true
    }

    func multiCursorPaste() -> Bool {
        guard hasMultipleCursors, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let distribute = lines.count == multiCursor.cursors.count
        var next = 0
        applyPerCursor(actionName: "Paste") { cursor, _ in
            let piece = distribute ? lines[min(next, lines.count - 1)] : text
            next += 1
            return (cursor.range, piece, (piece as NSString).length, 0)
        }
        return true
    }

    private func cursorIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index != NSNotFound else { return nil }
        let ns = storage.mutableString
        let line = lineBounds(at: index, in: ns)
        return min(fraction >= 0.5 ? index + 1 : index, line.contentsEnd)
    }

    func beginMultiCursorMouse(with event: NSEvent, at point: NSPoint) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
        let controlShift = flags.contains(.control) && flags.contains(.shift) && !flags.contains(.command) && !flags.contains(.option)
        guard option || controlShift, cursorIndex(at: point) != nil else { return false }
        window?.makeFirstResponder(self)
        multiCursor.columnBase = flags.contains(.shift) && option ? currentCursors() : []
        if controlShift {
            toggleCursor(at: point)
            return true
        }
        multiCursor.columnAnchor = point
        multiCursor.columnDragged = false
        return true
    }

    private func toggleCursor(at point: NSPoint) {
        guard let index = cursorIndex(at: point) else { return }
        var cursors = currentCursors()
        if cursors.count > 1, let existing = cursors.firstIndex(where: { NSLocationInRange(index, $0.range) || $0.head == index }) {
            cursors.remove(at: existing)
            setCursors(cursors, primary: min(existing, cursors.count - 1))
            return
        }
        cursors.append(EditorCursor(anchor: index, head: index))
        setCursors(cursors, primary: cursors.count - 1)
    }

    private func selectColumn(to point: NSPoint) {
        guard let anchorPoint = multiCursor.columnAnchor, let layoutManager, let textContainer, let storage = textStorage,
              let first = cursorIndex(at: anchorPoint), let last = cursorIndex(at: point) else { return }
        let ns = storage.mutableString
        let origin = textContainerOrigin
        var cursors: [EditorCursor] = multiCursor.columnBase
        var position = lineBounds(at: min(first, last), in: ns).start
        let finalLine = lineBounds(at: max(first, last), in: ns).start
        var primary = 0
        while position <= finalLine {
            let line = lineBounds(at: position, in: ns)
            let y: CGFloat
            if line.start < ns.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: line.start)
                y = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY + origin.y
            } else {
                y = layoutManager.extraLineFragmentRect.midY + origin.y
            }
            func index(atX x: CGFloat) -> Int {
                guard line.contentsEnd > line.start else { return line.start }
                var fraction: CGFloat = 0
                let hit = layoutManager.characterIndex(for: NSPoint(x: x - origin.x, y: y - origin.y), in: textContainer,
                                                       fractionOfDistanceBetweenInsertionPoints: &fraction)
                return min(max(line.start, fraction >= 0.5 ? hit + 1 : hit), line.contentsEnd)
            }
            let cursor = EditorCursor(anchor: index(atX: anchorPoint.x), head: index(atX: point.x))
            if line.start == lineBounds(at: last, in: ns).start { primary = cursors.count }
            cursors.append(cursor)
            guard line.end > line.contentsEnd else { break }
            position = line.end
        }
        setCursors(cursors, primary: primary)
    }

    func continueMultiCursorMouse(with event: NSEvent) -> Bool {
        guard multiCursor.columnAnchor != nil else { return false }
        multiCursor.columnDragged = true
        selectColumn(to: convert(event.locationInWindow, from: nil))
        autoscroll(with: event)
        return true
    }

    func endMultiCursorMouse(with event: NSEvent) -> Bool {
        guard let anchor = multiCursor.columnAnchor else { return false }
        if !multiCursor.columnDragged { toggleCursor(at: anchor) }
        multiCursor.columnAnchor = nil
        multiCursor.columnDragged = false
        multiCursor.columnBase = []
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        if continueMultiCursorMouse(with: event) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if endMultiCursorMouse(with: event) { return }
        super.mouseUp(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        multiCursorMarkedTextChanged { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }

    override func unmarkText() {
        multiCursorMarkedTextChanged { super.unmarkText() }
    }

    override func copy(_ sender: Any?) {
        if !multiCursorCopy() { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        if !multiCursorCut() { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        if !multiCursorPaste() { super.paste(sender) }
    }

    func addNextOccurrence() {
        guard let storage = textStorage else { return }
        let ns = storage.mutableString
        let cursors = currentCursors()
        guard let first = cursors.first else { return }
        if cursors.count == 1, first.isEmpty {
            let word = wordRange(at: first.head)
            if word.length > 0 { setSelectedRange(word) }
            return
        }
        guard !first.isEmpty else {
            workspaceState.presentCommandFeedback("Select the text to match first.", title: "Select Next Occurrence")
            return
        }
        let needle = ns.substring(with: first.range)
        let ranges = cursors.map(\.range)
        let primary = hasMultipleCursors ? multiCursor.primary : 0
        var from = NSMaxRange(ranges[primary])
        for _ in 0..<2 {
            while from <= ns.length {
                let found = ns.range(of: needle, options: .literal, range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound else { break }
                if !ranges.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    let all = cursors + [EditorCursor(found)]
                    setCursors(all, primary: all.count - 1, scrollTo: nil)
                    scrollRangeToVisible(found)
                    return
                }
                from = NSMaxRange(found)
            }
            from = 0
        }
        workspaceState.presentCommandFeedback("Every occurrence is already selected.", title: "Select Next Occurrence")
    }
}
