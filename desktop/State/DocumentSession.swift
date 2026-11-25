import AppKit
import SwiftTreeSitter

private let scanChunk = 4096

private func forEachUnit(_ s: NSString, in range: NSRange, _ body: (Int, unichar) -> Void) {
    var buffer = [unichar](repeating: 0, count: min(scanChunk, max(range.length, 1)))
    var loc = range.location
    let end = NSMaxRange(range)
    while loc < end {
        let n = min(scanChunk, end - loc)
        buffer.withUnsafeMutableBufferPointer { buf in
            s.getCharacters(buf.baseAddress!, range: NSRange(location: loc, length: n))
            for i in 0..<n { body(loc + i, buf[i]) }
        }
        loc += n
    }
}

struct ShiftedOffsets {
    private var stored: [Int]
    private var pendingFrom: Int
    private var pendingDelta = 0

    init(_ values: [Int]) {
        stored = values
        pendingFrom = values.count
    }

    var count: Int { stored.count }

    subscript(i: Int) -> Int {
        i >= pendingFrom ? stored[i] + pendingDelta : stored[i]
    }

    mutating func flush() {
        movePending(to: stored.count)
        pendingDelta = 0
    }

    private mutating func movePending(to j: Int) {
        if pendingDelta != 0 {
            if j > pendingFrom {
                for i in pendingFrom..<j { stored[i] += pendingDelta }
            } else if j < pendingFrom {
                for i in j..<pendingFrom { stored[i] -= pendingDelta }
            }
        }
        pendingFrom = j
    }

    mutating func replaceSubrange(_ r: Range<Int>, with values: [Int], shiftingFollowingBy delta: Int) {
        movePending(to: r.upperBound)
        stored.replaceSubrange(r, with: values)
        pendingFrom = r.lowerBound + values.count
        pendingDelta += delta
        if pendingDelta == 0 { pendingFrom = stored.count }
    }
}

private func lowerBound(_ a: ShiftedOffsets, _ v: Int) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let mid = (lo + hi) >> 1
        if a[mid] < v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func upperBound(_ a: ShiftedOffsets, _ v: Int) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let mid = (lo + hi) >> 1
        if a[mid] <= v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

struct UTF8Index {
    private(set) var positions = ShiftedOffsets([])
    private(set) var prefix = ShiftedOffsets([0])
    private(set) var utf16Length = 0

    var byteLength: Int { utf16Length + prefix[prefix.count - 1] }

    static func extraBytes(_ u: unichar) -> UInt8 {
        if u < 0x80 { return 0 }
        if u < 0x800 || (u >= 0xD800 && u <= 0xDFFF) { return 1 }
        return 2
    }

    init(_ s: NSString) {
        utf16Length = s.length
        var pos: [Int] = []
        var pre: [Int] = [0]
        forEachUnit(s, in: NSRange(location: 0, length: s.length)) { i, u in
            let e = Self.extraBytes(u)
            if e > 0 {
                pos.append(i)
                pre.append(pre[pre.count - 1] + Int(e))
            }
        }
        positions = ShiftedOffsets(pos)
        prefix = ShiftedOffsets(pre)
    }

    func byteOffset(_ u: Int) -> Int {
        u + prefix[lowerBound(positions, u)]
    }

    func utf16Offset(byte b: Int) -> Int {
        var lo = 0, hi = positions.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if positions[mid] + prefix[mid] < b { lo = mid + 1 } else { hi = mid }
        }
        return b - prefix[lo]
    }

    mutating func replace(_ old: NSRange, with new: NSString, newRange: NSRange) {
        let lo = lowerBound(positions, old.location)
        let hi = lowerBound(positions, NSMaxRange(old))
        let base = prefix[lo]
        var addPos: [Int] = []
        var addPrefix: [Int] = []
        var running = base
        forEachUnit(new, in: newRange) { i, u in
            let e = Self.extraBytes(u)
            if e > 0 {
                addPos.append(old.location + i - newRange.location)
                running += Int(e)
                addPrefix.append(running)
            }
        }
        let delta = newRange.length - old.length
        let extraDelta = (running - base) - (prefix[hi] - base)
        positions.replaceSubrange(lo..<hi, with: addPos, shiftingFollowingBy: delta)
        prefix.replaceSubrange((lo + 1)..<(hi + 1), with: addPrefix, shiftingFollowingBy: extraDelta)
        utf16Length += delta
    }
}

struct LineIndex {
    private(set) var starts = ShiftedOffsets([0])

    var count: Int { starts.count }

    init(_ s: NSString) {
        var values = [0]
        forEachUnit(s, in: NSRange(location: 0, length: s.length)) { i, u in
            if u == 0x0A { values.append(i + 1) }
        }
        starts = ShiftedOffsets(values)
    }

    func line(at u: Int) -> Int {
        upperBound(starts, u) - 1
    }

    func start(ofLine line: Int) -> Int? {
        line >= 0 && line < starts.count ? starts[line] : nil
    }

    func contentEnd(ofLine line: Int, length: Int) -> Int {
        line + 1 < starts.count ? starts[line + 1] - 1 : length
    }

    mutating func replace(_ old: NSRange, with new: NSString, newRange: NSRange) {
        let lo = upperBound(starts, old.location)
        let hi = upperBound(starts, NSMaxRange(old))
        var added: [Int] = []
        forEachUnit(new, in: newRange) { i, u in
            if u == 0x0A { added.append(old.location + i - newRange.location + 1) }
        }
        starts.replaceSubrange(lo..<hi, with: added, shiftingFollowingBy: newRange.length - old.length)
    }
}

final class DocumentSession: NSObject, NSTextStorageDelegate {
    static let undoLevels = 500

    let path: String
    let storage: NSTextStorage
    let undoManager = UndoManager()
    let lineEnding: String
    let syncsToCore: Bool
    weak var workspace: WorkspaceState?
    private(set) var utf8: UTF8Index
    private(set) var lines: LineIndex
    private(set) var version = 0
    var savedVersion = 0
    var savedText: String? {
        didSet {
            savedNSText = savedText.map { NSString(string: $0) }
            savedUTF16Length = savedNSText?.length ?? -1
            editedMemo = nil
        }
    }
    private var savedNSText: NSString?
    private var savedUTF16Length = 0
    private var editedMemo: (version: Int, savedVersion: Int, edited: Bool)?
    var isEdited: Bool {
        guard version != savedVersion else { return false }
        guard let saved = savedNSText, storage.length == savedUTF16Length else { return true }
        if let memo = editedMemo, memo.version == version, memo.savedVersion == savedVersion { return memo.edited }
        let current = storage.mutableString
        var edited: Bool
        if let edit = lastEdit, edit.newLength > 0, edit.old.location + edit.newLength <= current.length {
            let window = NSRange(location: edit.old.location, length: edit.newLength)
            edited = current.substring(with: window) != saved.substring(with: window)
        } else {
            edited = false
        }
        if !edited { edited = !current.isEqual(to: saved as String) }
        if !edited {
            savedVersion = version
            return false
        }
        editedMemo = (version, savedVersion, true)
        return true
    }
    var diskModified: Date?
    private(set) var lastEdit: (old: NSRange, newLength: Int)?
    var semanticHighlights: [(NSRange, NSColor)] = []
    var lastSelection = NSRange(location: 0, length: 0)
    var lastScrollOrigin = NSPoint.zero
    var appliedFont: NSFont?
    var appliedTextColor: NSColor?
    var isLargeFileMode: Bool = false
    var largeFileAnalysisOverride: Bool = false
    var isEffectiveLargeFileMode: Bool { isLargeFileMode && !largeFileAnalysisOverride }
    lazy var highlighter = SyntaxHighlighter(path: path)
    var onEdit: ((DocumentSession, NSRange, Int) -> Void)?

    init(path: String, text: String, syncsToCore: Bool) {
        self.path = path
        self.syncsToCore = syncsToCore
        let ns = text as NSString
        let newline = ns.range(of: "\n")
        lineEnding = newline.location != NSNotFound && newline.location > 0 && ns.character(at: newline.location - 1) == 0x0D ? "CRLF" : "LF"
        storage = NSTextStorage(string: text)
        savedText = text
        savedNSText = ns
        savedUTF16Length = ns.length
        utf8 = UTF8Index(ns)
        lines = LineIndex(ns)
        isLargeFileMode = (utf8.byteLength > 2_000_000 || lines.count > 50_000)
        undoManager.levelsOfUndo = Self.undoLevels
        super.init()
        storage.delegate = self
        if syncsToCore {
            var copy = text
            copy.withUTF8 { buf in
                path.withCString { p in
                    buf.withMemoryRebound(to: CChar.self) { NotifyFileOpen(p, $0.baseAddress, Int32(buf.count)) }
                }
            }
        }
    }

    var length: Int { utf8.utf16Length }

    func lineAndColumn(at u: Int) -> (line: Int, col: Int) {
        let clamped = max(0, min(u, length))
        let line = lines.line(at: clamped)
        return (line, clamped - lines.starts[line])
    }

    func offset(line: Int, utf16Column: Int) -> Int? {
        guard let start = lines.start(ofLine: line) else { return nil }
        return min(start + max(0, utf16Column), lines.contentEnd(ofLine: line, length: length))
    }

    func lineRange(_ line: Int) -> NSRange? {
        guard let start = lines.start(ofLine: line) else { return nil }
        return NSRange(location: start, length: lines.contentEnd(ofLine: line, length: length) - start)
    }

    func close() {
        storage.delegate = nil
        undoManager.removeAllActions()
        if syncsToCore {
            path.withCString { NotifyFileClose($0) }
        }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let started = measureEnabled ? CFAbsoluteTimeGetCurrent() : 0
        defer { if measureEnabled { recordEditCost(CFAbsoluteTimeGetCurrent() - started) } }
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let ns = textStorage.mutableString
        let startByte = utf8.byteOffset(old.location)
        let endByte = utf8.byteOffset(NSMaxRange(old))
        let oldByteLength = utf8.byteLength
        let startPoint = point(at: old.location)
        let oldEndPoint = point(at: NSMaxRange(old))
        utf8.replace(old, with: ns, newRange: editedRange)
        lines.replace(old, with: ns, newRange: editedRange)
        let newEndPoint = point(at: NSMaxRange(editedRange))
        version += 1
        lastEdit = (old, editedRange.length)
        highlighter.noteEdit(InputEdit(
            startByte: UInt32(old.location * 2),
            oldEndByte: UInt32(NSMaxRange(old) * 2),
            newEndByte: UInt32(NSMaxRange(editedRange) * 2),
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint))
        shiftSemanticHighlights(old: old, newLength: editedRange.length, in: ns)
        let lineDelta = Int(newEndPoint.row) - Int(oldEndPoint.row)
        if syncsToCore && lineDelta != 0 {
            shiftLineAnnotations(startPoint: startPoint, oldEndPoint: oldEndPoint, old: old, editedRange: editedRange, lineDelta: lineDelta, in: ns)
        }
        if syncsToCore {
            var replacement = ns.substring(with: editedRange)
            let status = replacement.withUTF8 { buf in
                path.withCString { p in
                    buf.withMemoryRebound(to: CChar.self) {
                        NotifyIncrementalChange(p, Int32(startByte), Int32(endByte), $0.baseAddress, Int32(buf.count), Int32(oldByteLength))
                    }
                }
            }
            if status == 2 {
                measureLog("core desync \(path)")
                resyncCore()
            }
            LSPEditorActivity.shared.noteEdit()
        }
        onEdit?(self, old, editedRange.length)
    }

    private var editCosts: [Double] = []

    private func recordEditCost(_ seconds: Double) {
        editCosts.append(seconds)
        guard editCosts.count == 100 else { return }
        let sorted = editCosts.sorted()
        measureLog(String(format: "edit-sync p50 %.3f ms p95 %.3f ms max %.3f ms (n=100, %d bytes)", sorted[50] * 1000, sorted[95] * 1000, sorted[99] * 1000, utf8.byteLength))
        editCosts.removeAll(keepingCapacity: true)
    }

    private func point(at u: Int) -> Point {
        let line = lines.line(at: u)
        return Point(row: UInt32(line), column: UInt32((u - lines.starts[line]) * 2))
    }

    private func shiftSemanticHighlights(old: NSRange, newLength: Int, in ns: NSString) {
        guard !semanticHighlights.isEmpty else { return }
        let delta = newLength - old.length
        let oldEnd = NSMaxRange(old)
        let isIdentifierInsertion: Bool = {
            guard old.length == 0, newLength > 0, old.location + newLength <= ns.length else { return false }
            for i in old.location..<(old.location + newLength) {
                let c = ns.character(at: i)
                let isIdent = c == 0x5F || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80
                if !isIdent { return false }
            }
            return true
        }()
        var h = semanticHighlights
        semanticHighlights = []
        var read = semanticHighlightLowerBound(h, location: old.location)
        while read > 0 && NSMaxRange(h[read - 1].0) >= old.location { read -= 1 }
        var write = read
        while read < h.count {
            let (range, color) = h[read]
            read += 1
            let shifted: NSRange?
            if NSMaxRange(range) < old.location {
                shifted = range
            } else if NSMaxRange(range) == old.location {
                shifted = isIdentifierInsertion ? NSRange(location: range.location, length: range.length + newLength) : range
            } else if range.location >= oldEnd {
                shifted = NSRange(location: range.location + delta, length: range.length)
            } else if old.location >= range.location && oldEnd <= NSMaxRange(range) {
                let adjustedLen = range.length + delta
                shifted = adjustedLen > 0 ? NSRange(location: range.location, length: adjustedLen) : nil
            } else {
                shifted = nil
            }
            if let shifted {
                h[write] = (shifted, color)
                write += 1
            }
        }
        h.removeSubrange(write...)
        semanticHighlights = h
    }

    private func semanticHighlightLowerBound(_ h: [(NSRange, NSColor)], location: Int) -> Int {
        var lo = 0, hi = h.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if h[mid].0.location < location { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func semanticHighlightWindow(intersecting target: NSRange) -> Range<Int> {
        semanticHighlightWindow(semanticHighlights, intersecting: target)
    }

    func replaceSemanticHighlights(in target: NSRange, with fresh: [(NSRange, NSColor)]) {
        var h = semanticHighlights
        semanticHighlights = []
        let window = semanticHighlightWindow(h, intersecting: target)
        let kept = h[window].filter { NSIntersectionRange($0.0, target).length == 0 }
        h.replaceSubrange(window, with: (kept + fresh).sorted { $0.0.location < $1.0.location })
        semanticHighlights = h
    }

    private func semanticHighlightWindow(_ h: [(NSRange, NSColor)], intersecting target: NSRange) -> Range<Int> {
        var lo = semanticHighlightLowerBound(h, location: target.location)
        while lo > 0 && NSMaxRange(h[lo - 1].0) > target.location { lo -= 1 }
        let hi = max(lo, semanticHighlightLowerBound(h, location: NSMaxRange(target)))
        return lo..<hi
    }

    private func shiftLineAnnotations(startPoint: Point, oldEndPoint: Point, old: NSRange, editedRange: NSRange, lineDelta: Int, in ns: NSString) {
        let startLine1 = Int(startPoint.row) + 1
        let oldEndLine1 = Int(oldEndPoint.row) + 1
        let lineStart = lines.starts[Int(startPoint.row)]
        var leadingWhitespaceOnly = true
        for i in lineStart..<old.location {
            let c = ns.character(at: i)
            if c != 0x20 && c != 0x09 { leadingWhitespaceOnly = false; break }
        }
        if leadingWhitespaceOnly && lineDelta > 0 {
            let end = NSMaxRange(editedRange)
            for i in editedRange.location..<end {
                let c = ns.character(at: i)
                if c == 0x0A { break }
                if c != 0x20 && c != 0x09 && c != 0x0D { leadingWhitespaceOnly = false; break }
            }
        }
        let ws = workspace ?? WorkspaceState.shared
        if var cache = ws.codeLensCache[path], !cache.isEmpty {
            Self.shiftLineMap(&cache, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.codeLensCache[path] = cache
        }
        if var lenses = ws.goplsLenses[path], !lenses.isEmpty {
            Self.shiftLineMap(&lenses, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.goplsLenses[path] = lenses
        }
        if var notes = ws.moduleNotes[path], !notes.isEmpty {
            Self.shiftLineMap(&notes, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.moduleNotes[path] = notes
        }
        if var tests = ws.fileTestLines[path], !tests.isEmpty {
            Self.shiftLineMap(&tests, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.fileTestLines[path] = tests
        }
        if var cov = ws.fileCoverage[path], !cov.isEmpty {
            Self.shiftLineMap(&cov, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.fileCoverage[path] = cov
        }
        if var notes = ws.escapeAnnotations[path], !notes.isEmpty {
            Self.shiftLineMap(&notes, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.escapeAnnotations[path] = notes
        }
        if ws.bookmarksByPath[path]?.isEmpty == false {
            var items = Dictionary(ws.bookmarks.filter { $0.path == path }.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
            Self.shiftLineMap(&items, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.bookmarkLinesDidMove(in: path, to: items)
        }
        if let lines = ws.debug.breakpoints[path], !lines.isEmpty {
            var specs = Dictionary(uniqueKeysWithValues: lines.map { ($0, ws.debug.spec(path, $0)) })
            Self.shiftLineMap(&specs, startLine1: startLine1, oldEndLine1: oldEndLine1, delta: lineDelta, leadingWhitespaceOnly: leadingWhitespaceOnly)
            ws.breakpointLinesDidMove(in: path, to: specs)
        }
    }

    private static func shiftLineMap<V>(_ map: inout [Int: V], startLine1: Int, oldEndLine1: Int, delta: Int, leadingWhitespaceOnly: Bool) {
        let shiftFrom: Int
        if delta > 0 {
            shiftFrom = leadingWhitespaceOnly ? startLine1 : oldEndLine1 + 1
        } else {
            shiftFrom = (leadingWhitespaceOnly || map[startLine1] == nil) ? oldEndLine1 : oldEndLine1 + 1
        }
        var updated: [Int: V] = [:]
        updated.reserveCapacity(map.count)
        for (line, value) in map {
            if line >= shiftFrom {
                let newLine = line + delta
                if newLine >= 1 { updated[newLine] = value }
            } else if line < startLine1 || (line == startLine1 && shiftFrom > oldEndLine1) {
                updated[line] = value
            } else if line == startLine1 && delta < 0 && map[oldEndLine1] == nil {
                updated[line] = value
            }
        }
        map = updated
    }

    private func resyncCore() {
        var text = storage.string
        text.withUTF8 { buf in
            path.withCString { p in
                buf.withMemoryRebound(to: CChar.self) { _ = NotifyFullChange(p, $0.baseAddress, Int32(buf.count)) }
            }
        }
    }

    func replaceAll(with text: String) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
    }
}
