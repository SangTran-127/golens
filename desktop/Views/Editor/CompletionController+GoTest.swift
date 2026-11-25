import AppKit
import Foundation
import GoLensFoundation

struct GoTestCompletionState {
    var cachedItems: (dir: String, items: [UntestedGoFunction])? = nil
    var hasTrailingParen = false

    mutating func reset() {
        cachedItems = nil
        hasTrailingParen = false
    }
}

extension CompletionController {
    @discardableResult
    func updateGoTestCompletionsIfEligible(in tv: GoLensTextView, doc: DocumentSession, explicit: Bool) -> Bool {
        guard doc.path.hasSuffix("_test.go"), tv.selectedRange().length == 0 else {
            if session == -1 && localSource == .goTest { dismiss() }
            return false
        }
        let caret = tv.selectedRange().location
        let text = doc.storage.string
        guard let match = GoTestCompletionContext.topLevelTestDeclPrefix(
            in: text,
            caretUTF16: caret,
            allowEmptyAfterFunc: explicit
        ) else {
            if session == -1 && localSource == .goTest { dismiss() }
            return false
        }

        let pkgDir = (doc.path as NSString).deletingLastPathComponent
        let wasSameGoTestSession = session == -1 && localSource == .goTest && path == doc.path && anchor == match.anchorUTF16Offset
        goTestState.hasTrailingParen = match.hasParameterParenAfterCaret

        if wasSameGoTestSession, let cached = goTestState.cachedItems, cached.dir == pkgDir {
            query = match.prefix
            applyGoTestItems(cached.items, match: match, pkgDir: pkgDir, in: tv, doc: doc)
            return true
        }

        beginLocal(.goTest, in: tv, doc: doc, anchor: match.anchorUTF16Offset, query: match.prefix)
        let gen = generation
        let live = liveGeneration
        let filePath = doc.path
        queue.async { [weak self] in
            guard live.withLock({ $0 }) == gen else { return }
            let json: String? = pkgDir.withCString { cDir in
                guard let ptr = UntestedPackageFunctions(cDir) else { return nil }
                defer { FreeGoCString(ptr) }
                return String(cString: ptr)
            }
            let items = json.flatMap { try? JSONDecoder().decode([UntestedGoFunction].self, from: Data($0.utf8)) } ?? []
            DispatchQueue.main.async {
                guard let self,
                      gen == self.generation,
                      let tv = self.textView,
                      let doc = tv.document,
                      doc.path == filePath,
                      tv.selectedRange().length == 0 else { return }
                let liveCaret = tv.selectedRange().location
                guard let liveMatch = GoTestCompletionContext.topLevelTestDeclPrefix(
                    in: doc.storage.string,
                    caretUTF16: liveCaret,
                    allowEmptyAfterFunc: explicit
                ), liveMatch.anchorUTF16Offset == self.anchor else {
                    self.dismiss()
                    return
                }
                self.goTestState.cachedItems = (dir: pkgDir, items: items)
                self.goTestState.hasTrailingParen = liveMatch.hasParameterParenAfterCaret
                self.query = liveMatch.prefix
                self.applyGoTestItems(items, match: liveMatch, pkgDir: pkgDir, in: tv, doc: doc)
            }
        }
        return true
    }

    func isGoTestQueryValid(in doc: DocumentSession, caret: Int) -> Bool {
        GoTestCompletionContext.topLevelTestDeclPrefix(
            in: doc.storage.string,
            caretUTF16: caret,
            allowEmptyAfterFunc: true
        )?.anchorUTF16Offset == anchor
    }

    func commitGoTestCompletion(_ row: CompletionRow, caret: Int, in tv: GoLensTextView, doc: DocumentSession) {
        let start = max(0, min(anchor, caret))
        var end = max(anchor, caret)
        let ns: NSString = doc.storage.mutableString
        while end < ns.length, Self.isGoTestIdentUnit(ns.character(at: end)) {
            end += 1
        }
        let replaceRange = NSRange(location: start, length: max(0, end - start))
        let hasParen = goTestState.hasTrailingParen
        let testName = row.insertText
        dismiss()
        if hasParen {
            tv.workspaceState.applyRanges([(replaceRange, testName)], in: doc)
            let newCaret = start + (testName as NSString).length
            tv.setSelectedRange(NSRange(location: min(newCaret, doc.length), length: 0))
        } else {
            expandTemplate(
                "\(testName)(t *testing.T) {\n\t$0\n}",
                replacing: replaceRange,
                selection: "",
                in: tv,
                actionName: "Insert Test"
            )
        }
    }

    private func applyGoTestItems(
        _ items: [UntestedGoFunction],
        match: GoTestDeclMatch,
        pkgDir: String,
        in tv: GoLensTextView,
        doc: DocumentSession
    ) {
        var existing = GoTestCompletionContext.existingTopLevelTestNames(in: doc.storage.string)
        for (docPath, openDoc) in ws.documents where docPath != doc.path && docPath.hasSuffix("_test.go") {
            if (docPath as NSString).deletingLastPathComponent == pkgDir {
                existing.formUnion(GoTestCompletionContext.existingTopLevelTestNames(in: openDoc.storage.string))
            }
        }
        let queryLower = match.prefix.lowercased()
        let filtered = items
            .filter { item in
                guard !existing.contains(item.testName) else { return false }
                guard !queryLower.isEmpty else { return true }
                return item.testName.lowercased().contains(queryLower)
            }
            .sorted { a, b in
                let aPref = a.testName.lowercased().hasPrefix(queryLower)
                let bPref = b.testName.lowercased().hasPrefix(queryLower)
                if aPref != bPref { return aPref }
                return a.testName.localizedStandardCompare(b.testName) == .orderedAscending
            }

        var rows: [CompletionRow] = []
        rows.reserveCapacity(filtered.count)
        docCache.removeAll(keepingCapacity: true)
        for (idx, item) in filtered.enumerated() {
            let rowId = -(idx + 1)
            let matched = Self.goTestMatchOffsets(in: item.testName, query: match.prefix)
            let targetDisplay = item.receiver.map { "\($0).\(item.funcName)" } ?? item.funcName
            let fileName = (item.file as NSString).lastPathComponent
            rows.append(
                CompletionRow(
                    i: rowId,
                    label: item.testName,
                    kind: "func",
                    params: match.hasParameterParenAfterCaret ? nil : "(t *testing.T)",
                    type: targetDisplay,
                    pkg: fileName,
                    m: matched.isEmpty ? nil : matched,
                    dep: false,
                    insert: item.testName
                )
            )
            docCache[rowId] = CompletionDocInfo(
                signature: item.signature,
                doc: "Untested function in \(fileName):\(item.line)"
            )
        }
        showLocal(rows, in: tv)
    }

    private static func isGoTestIdentUnit(_ u: unichar) -> Bool {
        u == 0x5F || (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u >= 0x80
    }

    private static func goTestMatchOffsets(in label: String, query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        let labelUnits = Array(label.utf16)
        let queryUnits = Array(query.lowercased().utf16)
        let lowerUnits = Array(label.lowercased().utf16)
        var matched: [Int] = []
        var qIdx = 0
        for (idx, unit) in lowerUnits.enumerated() where qIdx < queryUnits.count && unit == queryUnits[qIdx] {
            if idx < labelUnits.count {
                matched.append(idx)
            }
            qIdx += 1
        }
        return qIdx == queryUnits.count ? matched : []
    }
}
