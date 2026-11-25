import Foundation

struct GitPatchLine: Equatable {
    enum Kind: Equatable {
        case context
        case removed
        case added
    }

    let kind: Kind
    let text: String
    var noNewline = false
}

struct GitPatchHunk: Equatable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let section: String
    var lines: [GitPatchLine]
}

struct GitFilePatch: Equatable {
    var isNewFile = false
    var isDeletedFile = false
    var fileMode: String?
    var hunks: [GitPatchHunk] = []
}

struct GitPatchLineRef: Hashable, Comparable {
    let hunk: Int
    let line: Int

    static func < (lhs: GitPatchLineRef, rhs: GitPatchLineRef) -> Bool {
        (lhs.hunk, lhs.line) < (rhs.hunk, rhs.line)
    }
}

struct GitPatchRun: Equatable {
    let refs: [GitPatchLineRef]
    let newStart: Int
    let newCount: Int
}

enum GitPatchError: LocalizedError, Equatable {
    case emptySelection
    case incompleteLastLine

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No changed lines are selected."
        case .incompleteLastLine:
            return "The selected lines change the end of the file. Select the removed and added last lines together, then try again."
        }
    }
}

enum GitPatchBuilder {
    static func parse(_ diff: String) -> [GitFilePatch] {
        var files: [GitFilePatch] = []
        var current: GitFilePatch?
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        func finishFile() {
            if let file = current {
                files.append(file)
            }
            current = nil
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("diff --git ") {
                finishFile()
                current = GitFilePatch()
                i += 1
                continue
            }
            if line.hasPrefix("@@ -"), let header = parseHunkHeader(line) {
                if current == nil {
                    current = GitFilePatch()
                }
                var hunk = GitPatchHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    section: header.section,
                    lines: []
                )
                var oldLeft = header.oldCount
                var newLeft = header.newCount
                i += 1
                bodyLoop: while i < lines.count && (oldLeft > 0 || newLeft > 0) {
                    let body = lines[i]
                    let scalars = body.unicodeScalars
                    let text = String(Substring(scalars.dropFirst()))
                    switch scalars.first {
                    case nil:
                        guard oldLeft > 0, newLeft > 0 else { break bodyLoop }
                        hunk.lines.append(GitPatchLine(kind: .context, text: ""))
                        oldLeft -= 1
                        newLeft -= 1
                    case " ":
                        guard oldLeft > 0, newLeft > 0 else { break bodyLoop }
                        hunk.lines.append(GitPatchLine(kind: .context, text: text))
                        oldLeft -= 1
                        newLeft -= 1
                    case "-":
                        guard oldLeft > 0 else { break bodyLoop }
                        hunk.lines.append(GitPatchLine(kind: .removed, text: text))
                        oldLeft -= 1
                    case "+":
                        guard newLeft > 0 else { break bodyLoop }
                        hunk.lines.append(GitPatchLine(kind: .added, text: text))
                        newLeft -= 1
                    case "\\":
                        if !hunk.lines.isEmpty {
                            hunk.lines[hunk.lines.count - 1].noNewline = true
                        }
                    default:
                        break bodyLoop
                    }
                    i += 1
                }
                if i < lines.count, lines[i].hasPrefix("\\"), !hunk.lines.isEmpty {
                    hunk.lines[hunk.lines.count - 1].noNewline = true
                    i += 1
                }
                current?.hunks.append(hunk)
                continue
            }
            if line.hasPrefix("--- ") {
                if current?.hunks.isEmpty == false {
                    finishFile()
                }
                if current == nil {
                    current = GitFilePatch()
                }
                if line == "--- /dev/null" {
                    current?.isNewFile = true
                }
            } else if line == "+++ /dev/null" {
                current?.isDeletedFile = true
            } else if line.hasPrefix("new file mode ") {
                current?.isNewFile = true
                current?.fileMode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("deleted file mode ") {
                current?.isDeletedFile = true
                current?.fileMode = String(line.dropFirst("deleted file mode ".count))
            }
            i += 1
        }
        finishFile()
        return files
    }

    static func sameChanges(_ lhs: GitFilePatch, _ rhs: GitFilePatch) -> Bool {
        lhs.hunks.count == rhs.hunks.count && zip(lhs.hunks, rhs.hunks).allSatisfy { a, b in
            a.oldStart == b.oldStart && a.oldCount == b.oldCount && a.newStart == b.newStart && a.newCount == b.newCount && a.lines == b.lines
        }
    }

    static func runs(in patch: GitFilePatch) -> [GitPatchRun] {
        var result: [GitPatchRun] = []
        for (h, hunk) in patch.hunks.enumerated() {
            var newPos = hunk.newCount > 0 ? hunk.newStart : hunk.newStart + 1
            var refs: [GitPatchLineRef] = []
            var runFirstNew = newPos
            var added = 0

            func closeRun() {
                guard !refs.isEmpty else { return }
                result.append(GitPatchRun(refs: refs, newStart: added > 0 ? runFirstNew : runFirstNew - 1, newCount: added))
                refs = []
                added = 0
            }

            for (l, line) in hunk.lines.enumerated() {
                switch line.kind {
                case .context:
                    closeRun()
                    newPos += 1
                case .removed, .added:
                    if refs.isEmpty {
                        runFirstNew = newPos
                    }
                    refs.append(GitPatchLineRef(hunk: h, line: l))
                    if line.kind == .added {
                        added += 1
                        newPos += 1
                    }
                }
            }
            closeRun()
        }
        return result
    }

    static func build(_ patch: GitFilePatch, path: String, selecting selection: Set<GitPatchLineRef>, reverse: Bool) throws -> String {
        var changed = 0
        var selectedChanged = 0
        for (h, hunk) in patch.hunks.enumerated() {
            for (l, line) in hunk.lines.enumerated() where line.kind != .context {
                changed += 1
                if selection.contains(GitPatchLineRef(hunk: h, line: l)) {
                    selectedChanged += 1
                }
            }
        }
        guard selectedChanged > 0 else { throw GitPatchError.emptySelection }
        let allSelected = selectedChanged == changed

        var body: [String] = []
        var delta = 0
        for (h, hunk) in patch.hunks.enumerated() {
            var lines: [GitPatchLine] = []
            var hasChange = false
            var removed: [(line: GitPatchLine, selected: Bool)] = []
            var added: [(line: GitPatchLine, selected: Bool)] = []

            func emit(_ line: GitPatchLine, selected: Bool, keepsAsContext: Bool) {
                if selected {
                    lines.append(line)
                    hasChange = true
                } else if keepsAsContext {
                    lines.append(GitPatchLine(kind: .context, text: line.text, noNewline: line.noNewline))
                }
            }

            func flushRun() {
                for i in 0..<max(removed.count, added.count) {
                    if i < removed.count {
                        emit(removed[i].line, selected: removed[i].selected, keepsAsContext: !reverse)
                    }
                    if i < added.count {
                        emit(added[i].line, selected: added[i].selected, keepsAsContext: reverse)
                    }
                }
                removed.removeAll()
                added.removeAll()
            }

            for (l, line) in hunk.lines.enumerated() {
                let selected = selection.contains(GitPatchLineRef(hunk: h, line: l))
                switch line.kind {
                case .context:
                    flushRun()
                    lines.append(line)
                case .removed:
                    removed.append((line, selected))
                case .added:
                    added.append((line, selected))
                }
            }
            flushRun()
            guard hasChange else { continue }
            try validateLastLines(lines)

            let oldCount = lines.filter { $0.kind != .added }.count
            let newCount = lines.filter { $0.kind != .removed }.count
            let oldStart: Int
            let newStart: Int
            if reverse {
                newStart = hunk.newStart
                let newFirst = newCount > 0 ? newStart : newStart + 1
                let oldFirst = newFirst - delta
                oldStart = oldCount > 0 ? oldFirst : oldFirst - 1
            } else {
                oldStart = hunk.oldStart
                let oldFirst = oldCount > 0 ? oldStart : oldStart + 1
                let newFirst = oldFirst + delta
                newStart = newCount > 0 ? newFirst : newFirst - 1
            }
            delta += newCount - oldCount

            let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
            body.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(section)")
            for line in lines {
                let prefix: String
                switch line.kind {
                case .context: prefix = " "
                case .removed: prefix = "-"
                case .added: prefix = "+"
                }
                body.append(prefix + line.text)
                if line.noNewline {
                    body.append("\\ No newline at end of file")
                }
            }
        }

        let oldIsNull = patch.isNewFile && (!reverse || allSelected)
        let newIsNull = patch.isDeletedFile && (reverse || allSelected)
        let mode = patch.fileMode ?? "100644"
        var header = ["diff --git \(quotedPath("a/" + path)) \(quotedPath("b/" + path))"]
        if oldIsNull {
            header.append("new file mode \(mode)")
        } else if newIsNull {
            header.append("deleted file mode \(mode)")
        }
        header.append("--- " + (oldIsNull ? "/dev/null" : quotedPath("a/" + path)))
        header.append("+++ " + (newIsNull ? "/dev/null" : quotedPath("b/" + path)))
        return (header + body).joined(separator: "\n") + "\n"
    }

    private static func validateLastLines(_ lines: [GitPatchLine]) throws {
        for side in [GitPatchLine.Kind.removed, .added] {
            let sideLines = lines.filter { $0.kind == .context || $0.kind == side }
            if let index = sideLines.firstIndex(where: { $0.noNewline }), index != sideLines.count - 1 {
                throw GitPatchError.incompleteLastLine
            }
        }
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String)? {
        let afterOpen = line.index(line.startIndex, offsetBy: 3)
        guard let close = line.range(of: " @@", range: afterOpen..<line.endIndex) else { return nil }
        let ranges = line[afterOpen..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
              let old = parseRange(ranges[0].dropFirst()),
              let new = parseRange(ranges[1].dropFirst()) else { return nil }
        var section = line[close.upperBound...]
        if section.hasPrefix(" ") {
            section = section.dropFirst()
        }
        return (old.start, old.count, new.start, new.count, String(section))
    }

    private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]), start >= 0 else { return nil }
        guard parts.count > 1 else { return (start, 1) }
        guard parts.count == 2, let count = Int(parts[1]), count >= 0 else { return nil }
        return (start, count)
    }

    static func quotedPath(_ path: String) -> String {
        var needsQuotes = false
        var out = ""
        for byte in path.utf8 {
            switch byte {
            case 0x22: out += "\\\""; needsQuotes = true
            case 0x5C: out += "\\\\"; needsQuotes = true
            case 0x09: out += "\\t"; needsQuotes = true
            case 0x0A: out += "\\n"; needsQuotes = true
            case 0x0D: out += "\\r"; needsQuotes = true
            case 0x00..<0x20, 0x7F...0xFF:
                out += "\\" + String(byte, radix: 8).leftPadded(to: 3)
                needsQuotes = true
            default:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return needsQuotes ? "\"\(out)\"" : path
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
