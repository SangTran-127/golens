import Darwin
import Foundation
import SwiftUI
import SwiftTerm

extension WorkspaceState {
    func scheduleProjectSearch() {
        projectSearchWorkItem?.cancel()
        let query = projectSearchQuery
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectSearchResults = []
            isProjectSearching = false
            return
        }
        isProjectSearching = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.performProjectSearch(query: query)
        }
        projectSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func localSearchTextView(for paneID: EditorPaneID) -> NSTextView? {
        if let tv = editorTextView(for: paneID) {
            return tv
        }
        return paneID == effectiveFocusedPaneID ? activeTextView : nil
    }

    func setShowLocalSearch(_ newValue: Bool, in paneID: EditorPaneID) {
        let pane = paneState(for: paneID)
        let wasShown = pane.showLocalSearch
        pane.showLocalSearch = newValue
        if !newValue {
            pane.localSearchTask?.cancel()
            clearLocalSearchHighlights(in: paneID)
            if wasShown, let tv = localSearchTextView(for: paneID) {
                tv.window?.makeFirstResponder(tv)
            }
        } else {
            if pane.findFieldTakesFocus {
                pane.findFocusRequestID &+= 1
            }
            if !pane.findQuery.isEmpty {
                performLocalSearch(in: paneID)
            }
        }
    }

    func openLocalSearch(in paneID: EditorPaneID? = nil) {
        let target = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: target)
        pane.findFieldTakesFocus = true
        setShowLocalSearch(true, in: target)
    }

    func setLocalSearchQuery(_ newValue: String, in paneID: EditorPaneID) {
        let pane = paneState(for: paneID)
        let oldValue = pane.findQuery
        pane.findQuery = newValue
        if newValue != oldValue {
            performLocalSearch(in: paneID)
        }
    }

    func setFindOptions(_ newValue: TextFinder.Options, in paneID: EditorPaneID) {
        let pane = paneState(for: paneID)
        let oldValue = pane.findOptions
        pane.findOptions = newValue
        guard newValue != oldValue else { return }
        UserDefaults.standard.set(newValue.matchCase, forKey: "GoLensFindMatchCase")
        UserDefaults.standard.set(newValue.wholeWords, forKey: "GoLensFindWholeWords")
        UserDefaults.standard.set(newValue.regex, forKey: "GoLensFindRegex")
        performLocalSearch(in: paneID)
    }

    private func localFinder(for paneID: EditorPaneID) -> TextFinder? {
        let pane = paneState(for: paneID)
        return try? TextFinder(query: pane.findQuery, options: pane.findOptions)
    }

    func replaceCurrentLocalMatch(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane), let finder = localFinder(for: targetPane) else { return }
        let caret = textView.selectedRange().location
        let template = pane.replaceQuery
        findLocalEdits(in: textView, paneID: targetPane, { text in
            guard let range = try finder.next(in: text, from: caret, isCancelled: { Task.isCancelled }) else { return [] }
            return [(range, try finder.replacement(for: range, in: text, template: template))]
        }, then: { [weak self, weak textView] edits in
            guard let self, let textView, let storage = textView.textStorage, let (range, replacement) = edits.first else { return }
            pane.isApplyingFindReplacement = true
            defer { pane.isApplyingFindReplacement = false }
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            self.performLocalSearch(in: targetPane, movesSelection: true)
        })
    }

    func replaceAllLocalMatches(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane), let finder = localFinder(for: targetPane) else { return }
        let template = pane.replaceQuery
        findLocalEdits(in: textView, paneID: targetPane, { text in
            try finder.replacements(in: text, template: template, isCancelled: { Task.isCancelled })
        }, then: { [weak self, weak textView] edits in
            guard let self, let textView, let storage = textView.textStorage else { return }
            pane.isApplyingFindReplacement = true
            defer { pane.isApplyingFindReplacement = false }
            let undo = (textView as? GoLensTextView)?.document?.undoManager
            let groupsByEvent = undo?.groupsByEvent ?? true
            textView.breakUndoCoalescing()
            undo?.groupsByEvent = false
            undo?.beginUndoGrouping()
            if textView.shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) {
                let caret = textView.selectedRange().location
                let shift = edits.filter { NSMaxRange($0.range) <= caret }.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
                storage.beginEditing()
                for edit in edits.reversed() {
                    storage.replaceCharacters(in: edit.range, with: edit.text)
                }
                storage.endEditing()
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: min(max(caret + shift, 0), storage.length), length: 0))
            }
            undo?.endUndoGrouping()
            undo?.groupsByEvent = groupsByEvent
            textView.breakUndoCoalescing()
            self.performLocalSearch(in: targetPane, movesSelection: false)
        })
    }

    private func findLocalEdits(in textView: NSTextView, paneID: EditorPaneID, _ find: @escaping (NSString) throws -> [(range: NSRange, text: String)], then apply: @escaping ([(range: NSRange, text: String)]) -> Void) {
        guard let storage = textView.textStorage else { return }
        let pane = paneState(for: paneID)
        let snapshot = NSString(string: storage.string)
        pane.localSearchTask?.cancel()
        pane.localSearchGeneration += 1
        let generation = pane.localSearchGeneration
        pane.localSearchTask = Task.detached(priority: .userInitiated) {
            let edits = try? find(snapshot)
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, pane.showLocalSearch, generation == pane.localSearchGeneration, self.localSearchTextView(for: paneID) === textView else { return }
                guard let edits else { return self.showLocalSearchTimedOut(in: paneID) }
                guard !edits.isEmpty, textView.textStorage?.string == snapshot as String else {
                    return self.performLocalSearch(in: paneID, movesSelection: false)
                }
                apply(edits)
            }
        }
    }

    private func showLocalSearchTimedOut(in paneID: EditorPaneID) {
        let pane = paneState(for: paneID)
        pane.localSearchTimedOut = true
        pane.localSearchMatches = []
        pane.localSearchTruncated = false
        pane.currentLocalMatchIndex = -1
        clearLocalSearchHighlights(in: paneID)
    }

    func scheduleLocalSearchRefresh(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        pane.localSearchRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, pane.showLocalSearch else { return }
            self.performLocalSearch(in: targetPane, movesSelection: false)
        }
        pane.localSearchRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func performLocalSearch(in paneID: EditorPaneID? = nil, movesSelection: Bool = true) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane), let storage = textView.textStorage else { return }
        pane.localSearchTask?.cancel()
        pane.localSearchGeneration += 1
        let generation = pane.localSearchGeneration
        let finder: TextFinder?
        do {
            finder = try TextFinder(query: pane.findQuery, options: pane.findOptions)
            pane.localSearchInvalid = false
        } catch {
            finder = nil
            pane.localSearchInvalid = true
        }
        guard let finder else {
            clearLocalSearchHighlights(in: targetPane)
            pane.localSearchTimedOut = false
            pane.localSearchMatches = []
            pane.localSearchTruncated = false
            pane.currentLocalMatchIndex = -1
            return
        }
        let snapshot = NSString(string: storage.string)
        let applyFound: ([NSRange]?) -> Void = { [weak self, weak textView] found in
            guard let self, let textView, pane.showLocalSearch, generation == pane.localSearchGeneration, self.localSearchTextView(for: targetPane) === textView else { return }
            guard let found else { return self.showLocalSearchTimedOut(in: targetPane) }
            pane.localSearchTimedOut = false
            pane.localSearchTruncated = found.count > TextFinder.maxMatches
            let matches = Array(found.prefix(TextFinder.maxMatches))
            pane.localSearchMatches = matches
            guard !matches.isEmpty else {
                pane.currentLocalMatchIndex = -1
                self.clearLocalSearchHighlights(in: targetPane)
                return
            }
            let caret = textView.selectedRange().location
            let at = Self.firstMatch(in: matches, endingAfter: caret)
            pane.currentLocalMatchIndex = at < matches.count ? at : 0
            if movesSelection {
                self.highlightAndScrollToMatch(in: targetPane)
            } else {
                self.applyLocalSearchHighlights(in: targetPane)
            }
        }
        pane.localSearchTask = Task.detached(priority: .userInitiated) {
            let found = try? finder.matches(in: snapshot, limit: TextFinder.maxMatches + 1, isCancelled: { Task.isCancelled })
            DispatchQueue.main.async {
                applyFound(found)
            }
        }
    }

    private static func firstMatch(in matches: [NSRange], endingAfter location: Int) -> Int {
        var low = 0, high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matches[mid]) > location { high = mid } else { low = mid + 1 }
        }
        return low
    }

    func highlightAndScrollToMatch(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane),
              !pane.localSearchMatches.isEmpty,
              pane.currentLocalMatchIndex >= 0,
              pane.currentLocalMatchIndex < pane.localSearchMatches.count else { return }

        let matchRange = pane.localSearchMatches[pane.currentLocalMatchIndex]

        textView.setSelectedRange(NSRange(location: matchRange.location, length: 0))
        textView.scrollRangeToVisible(matchRange)
        applyLocalSearchHighlights(in: targetPane)
    }

    func applyLocalSearchHighlights(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane), let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let length = textView.textStorage?.length else { return }
        clearLocalSearchHighlights(in: targetPane)
        let matches = pane.localSearchMatches
        guard !matches.isEmpty else { return }

        let isDark = currentTheme.resolvedIsDark
        let matchBgColor = isDark ? NSColor.systemYellow.withAlphaComponent(0.3) : NSColor.systemYellow.withAlphaComponent(0.4)
        let currentMatchBgColor = isDark ? NSColor.systemOrange.withAlphaComponent(0.6) : NSColor.systemOrange.withAlphaComponent(0.7)

        var rect = textView.visibleRect
        rect = rect.insetBy(dx: 0, dy: -rect.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var span = visible
        var index = Self.firstMatch(in: matches, endingAfter: visible.location)
        while index < matches.count, matches[index].location < NSMaxRange(visible) {
            let range = matches[index]
            if NSMaxRange(range) <= length {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: index == pane.currentLocalMatchIndex ? currentMatchBgColor : matchBgColor, forCharacterRange: range)
            }
            index += 1
        }
        if matches.indices.contains(pane.currentLocalMatchIndex) {
            let current = matches[pane.currentLocalMatchIndex]
            if NSMaxRange(current) <= length {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: currentMatchBgColor, forCharacterRange: current)
                span = NSUnionRange(span, current)
            }
        }
        pane.localSearchHighlightedSpan = span
    }

    func clearLocalSearchHighlights(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard let textView = localSearchTextView(for: targetPane), let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length, let span = pane.localSearchHighlightedSpan else {
            pane.localSearchHighlightedSpan = nil
            return
        }
        pane.localSearchHighlightedSpan = nil
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(span, NSRange(location: 0, length: length)))
    }

    func selectNextLocalMatch(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard !pane.localSearchMatches.isEmpty else { return }
        pane.currentLocalMatchIndex = (pane.currentLocalMatchIndex + 1) % pane.localSearchMatches.count
        highlightAndScrollToMatch(in: targetPane)
    }

    func selectPreviousLocalMatch(in paneID: EditorPaneID? = nil) {
        let targetPane = paneID ?? effectiveFocusedPaneID
        let pane = paneState(for: targetPane)
        guard !pane.localSearchMatches.isEmpty else { return }
        pane.currentLocalMatchIndex = (pane.currentLocalMatchIndex - 1 + pane.localSearchMatches.count) % pane.localSearchMatches.count
        highlightAndScrollToMatch(in: targetPane)
    }

    func matchesProjectFileFilter(_ relativePath: String, filter: String) -> Bool {
        Self.matchesProjectFileFilter(relativePath, filter: filter)
    }

    static func matchesProjectFileFilter(_ relativePath: String, filter: String) -> Bool {
        let tokens = filter
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }

        var includePatterns: [String] = []
        var excludePatterns: [String] = []
        for token in tokens {
            if token.hasPrefix("!") {
                let pat = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !pat.isEmpty {
                    excludePatterns.append(pat)
                }
            } else {
                includePatterns.append(token)
            }
        }

        for pat in excludePatterns {
            if globMatches(pattern: pat, relativePath: relativePath) {
                return false
            }
        }

        if includePatterns.isEmpty {
            return true
        }
        return includePatterns.contains { globMatches(pattern: $0, relativePath: relativePath) }
    }

    private static func globMatches(pattern rawPattern: String, relativePath: String) -> Bool {
        var pat = rawPattern.lowercased()
        if pat.hasPrefix("./") {
            pat = String(pat.dropFirst(2))
        }
        guard !pat.isEmpty else { return true }
        let lowerRel = relativePath.lowercased()
        let lowerBase = (relativePath as NSString).lastPathComponent.lowercased()

        if fnmatch(pat, lowerRel, 0) == 0 || fnmatch(pat, lowerBase, 0) == 0 {
            return true
        }
        if pat.hasSuffix("/**") {
            let prefix = String(pat.dropLast(3))
            if lowerRel == prefix || lowerRel.hasPrefix(prefix + "/") {
                return true
            }
        }
        if pat.hasPrefix("**/") {
            let suffix = String(pat.dropFirst(3))
            if fnmatch(suffix, lowerRel, 0) == 0 || fnmatch(suffix, lowerBase, 0) == 0 || fnmatch("*/" + suffix, lowerRel, 0) == 0 {
                return true
            }
        }
        return false
    }

    private static func buildFileSearchMatches(filePath: String, relativePath: String, text: String, finder: TextFinder) -> FileSearchMatches? {
        let nsText = text as NSString
        guard let matchRanges = try? finder.matches(in: nsText, limit: 100), !matchRanges.isEmpty else { return nil }

        var searchMatches: [SearchMatch] = []
        searchMatches.reserveCapacity(matchRanges.count)
        var scanIndex = 0
        var lineNumber = 1
        let length = nsText.length

        for range in matchRanges where NSMaxRange(range) <= length {
            while scanIndex < range.location {
                let nlRange = nsText.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: scanIndex, length: range.location - scanIndex)
                )
                if nlRange.location != NSNotFound {
                    lineNumber += 1
                    scanIndex = nlRange.location + 1
                } else {
                    scanIndex = range.location
                }
            }
            let lineBounds = nsText.lineRange(for: NSRange(location: range.location, length: 0))
            let rawLine = nsText.substring(with: lineBounds).trimmingCharacters(in: .whitespacesAndNewlines)
            let displayLine = rawLine.count > 300 ? String(rawLine.prefix(300)) : rawLine
            searchMatches.append(SearchMatch(lineNumber: lineNumber, lineContent: displayLine, range: range))
        }

        guard !searchMatches.isEmpty else { return nil }
        return FileSearchMatches(filePath: filePath, relativePath: relativePath, matches: searchMatches)
    }

    private static func readSearchableFileText(fullPath: String, openDocumentsSnapshot: [String: String]) -> String? {
        if let openText = openDocumentsSnapshot[fullPath] {
            guard openText.utf8.count <= 1_048_576 else { return nil }
            return openText
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
              let size = attrs[.size] as? Int,
              size > 0,
              size <= 1_048_576,
              let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath), options: .mappedIfSafe),
              !data.contains(0) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func dismissProjectSearchFile(_ filePath: String) {
        guard let idx = projectSearchResults.firstIndex(where: { $0.filePath == filePath }) else { return }
        let removed = projectSearchResults.remove(at: idx)
        projectSearchTotalMatches = max(0, projectSearchTotalMatches - removed.matches.count)
    }

    func dismissProjectSearchMatch(filePath: String, matchID: UUID) {
        guard let fileIdx = projectSearchResults.firstIndex(where: { $0.filePath == filePath }) else { return }
        let file = projectSearchResults[fileIdx]
        guard let matchIdx = file.matches.firstIndex(where: { $0.id == matchID }) else { return }
        var updatedMatches = file.matches
        updatedMatches.remove(at: matchIdx)
        projectSearchTotalMatches = max(0, projectSearchTotalMatches - 1)
        if updatedMatches.isEmpty {
            projectSearchResults.remove(at: fileIdx)
        } else {
            projectSearchResults[fileIdx] = FileSearchMatches(
                filePath: file.filePath,
                relativePath: file.relativePath,
                matches: updatedMatches
            )
        }
    }

    func performProjectSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = activeWorkspacePath
        projectSearchResultsQuery = trimmed
        projectSearchResults = []
        projectSearchTotalMatches = 0
        guard !trimmed.isEmpty, !root.isEmpty else {
            projectSearchID = 0
            isProjectSearching = false
            CancelProjectSearch()
            return
        }

        let fileFilter = projectSearchFileFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCustomSearch = projectSearchRegex || projectSearchCaseSensitive || projectSearchWholeWord || !fileFilter.isEmpty
        let treePaths = allWorkspaceRelativeFilePaths()
        var openDocTexts: [String: String] = [:]
        for (path, session) in documents {
            openDocTexts[path] = session.storage.string
        }

        if useCustomSearch {
            CancelProjectSearch()
            if projectSearchID < 1_000_000 {
                projectSearchID = 1_000_000
            }
            projectSearchID += 1
            let searchID = projectSearchID
            let options = TextFinder.Options(
                matchCase: projectSearchCaseSensitive,
                wholeWords: projectSearchWholeWord,
                regex: projectSearchRegex
            )
            guard let finder = try? TextFinder(query: trimmed, options: options) else {
                isProjectSearching = false
                return
            }
            isProjectSearching = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let json: String? = root.withCString { r in
                    guard let c = ListProjectFiles(r) else { return nil }
                    defer { FreeGoCString(c) }
                    return String(cString: c)
                }
                var relPaths = json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                if !treePaths.isEmpty {
                    var seen = Set(relPaths)
                    for p in treePaths where seen.insert(p).inserted {
                        relPaths.append(p)
                    }
                }
                let filteredPaths = relPaths
                    .filter { Self.matchesProjectFileFilter($0, filter: fileFilter) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

                var matchedFiles: [FileSearchMatches] = []
                var totalMatches = 0
                for rel in filteredPaths.prefix(10_000) {
                    if self.projectSearchID != searchID { return }
                    let fullPath = (root as NSString).appendingPathComponent(rel)
                    let fileMatch: FileSearchMatches? = autoreleasepool {
                        guard let text = Self.readSearchableFileText(fullPath: fullPath, openDocumentsSnapshot: openDocTexts) else {
                            return nil
                        }
                        return Self.buildFileSearchMatches(filePath: fullPath, relativePath: rel, text: text, finder: finder)
                    }
                    guard let fileMatch else { continue }
                    matchedFiles.append(fileMatch)
                    totalMatches += fileMatch.matches.count
                    if totalMatches >= 2_000 {
                        break
                    }
                }

                DispatchQueue.main.async {
                    guard self.projectSearchID == searchID else { return }
                    self.projectSearchResults = self.matchedPathsSorted(matchedFiles)
                    self.projectSearchTotalMatches = totalMatches
                    self.isProjectSearching = false
                }
            }
            return
        }

        isProjectSearching = true
        claimCoreEvents(.search)
        let searchID = root.withCString { r in trimmed.withCString { q in StartProjectSearch(r, q) } }
        projectSearchID = searchID

        let dotRelPaths = treePaths.filter { ($0 as NSString).lastPathComponent.hasPrefix(".") || $0.hasPrefix(".") }
        if !dotRelPaths.isEmpty,
           let finder = try? TextFinder(query: trimmed, options: .init(matchCase: false, wholeWords: false, regex: false)) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var dotFiles: [FileSearchMatches] = []
                for rel in dotRelPaths.prefix(500) {
                    if self.projectSearchID != searchID { return }
                    let fullPath = (root as NSString).appendingPathComponent(rel)
                    let fileMatch: FileSearchMatches? = autoreleasepool {
                        guard let text = Self.readSearchableFileText(fullPath: fullPath, openDocumentsSnapshot: openDocTexts) else {
                            return nil
                        }
                        return Self.buildFileSearchMatches(filePath: fullPath, relativePath: rel, text: text, finder: finder)
                    }
                    guard let fileMatch else { continue }
                    dotFiles.append(fileMatch)
                }
                guard !dotFiles.isEmpty else { return }
                DispatchQueue.main.async {
                    guard self.projectSearchID == searchID else { return }
                    let (results, addedCount) = Self.mergeSearchResults(self.projectSearchResults, adding: dotFiles)
                    if addedCount > 0 {
                        self.projectSearchResults = results
                        self.projectSearchTotalMatches += addedCount
                    }
                }
            }
        }
    }

    static func mergeSearchResults(_ existing: [FileSearchMatches], adding incoming: [FileSearchMatches]) -> ([FileSearchMatches], Int) {
        var seen = Set(existing.map(\.filePath))
        var fresh: [(offset: Int, file: FileSearchMatches)] = []
        for (offset, file) in incoming.enumerated() where seen.insert(file.filePath).inserted {
            fresh.append((offset, file))
        }
        guard !fresh.isEmpty else { return (existing, 0) }
        fresh.sort { a, b in
            switch a.file.relativePath.localizedStandardCompare(b.file.relativePath) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }
        var merged: [FileSearchMatches] = []
        merged.reserveCapacity(existing.count + fresh.count)
        var added = 0
        var i = existing.startIndex
        for (_, file) in fresh {
            while i < existing.endIndex, existing[i].relativePath.localizedStandardCompare(file.relativePath) != .orderedDescending {
                merged.append(existing[i])
                i += 1
            }
            merged.append(file)
            added += file.matches.count
        }
        merged.append(contentsOf: existing[i...])
        return (merged, added)
    }

    private func matchedPathsSorted(_ files: [FileSearchMatches]) -> [FileSearchMatches] {
        files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    @discardableResult
    func replaceAllInProject(with replacement: String) -> (replaced: Int, skipped: Int, failed: [String]) {
        let query = projectSearchResultsQuery
        var replaced = 0, skipped = 0, failed: [String] = []
        guard !query.isEmpty else { return (0, 0, []) }
        let options = TextFinder.Options(
            matchCase: projectSearchCaseSensitive,
            wholeWords: projectSearchWholeWord,
            regex: projectSearchRegex
        )
        guard let finder = try? TextFinder(query: query, options: options) else { return (0, 0, []) }
        for file in projectSearchResults {
            let ranges = file.matches.map(\.range).sorted { $0.location > $1.location }
            let session = documents[file.filePath]
            let text = session.map { $0.storage.string } ?? (try? String(contentsOfFile: file.filePath, encoding: .utf8))
            guard let text else { failed.append(file.relativePath); continue }
            let ns = text as NSString
            let valid = ranges.filter { range in
                guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
                return (try? finder.next(in: ns, from: range.location)) == range
            }
            let edits: [(NSRange, String)] = valid.compactMap { range in
                (try? finder.replacement(for: range, in: ns, template: replacement)).map { (range, $0) }
            }
            skipped += ranges.count - edits.count
            guard !edits.isEmpty else { continue }
            if let session {
                applyRanges(edits, in: session)
                documentDidEdit(session)
            } else {
                let updated = NSMutableString(string: text)
                for (range, rep) in edits {
                    updated.replaceCharacters(in: range, with: rep)
                }
                do {
                    try (updated as String).write(toFile: file.filePath, atomically: true, encoding: .utf8)
                } catch {
                    failed.append(file.relativePath)
                    continue
                }
            }
            replaced += edits.count
        }
        performProjectSearch(query: query)
        return (replaced, skipped, failed)
    }

    private struct SearchBatch: Decodable {
        struct File: Decodable {
            let path: String
            let relative: String
            let matches: [Match]
        }
        struct Match: Decodable {
            let line: Int
            let length: Int
            let offset: Int
            let text: String
        }
        let id: Int64
        let files: [File]?
        let done: Bool?
        let total: Int?
    }

    func receiveSearchBatch(_ json: String) {
        guard let batch = try? JSONDecoder().decode(SearchBatch.self, from: Data(json.utf8)) else { return }
        let files = (batch.files ?? []).map { file in
            FileSearchMatches(filePath: file.path, relativePath: file.relative, matches: file.matches.map {
                SearchMatch(lineNumber: $0.line, lineContent: $0.text, range: NSRange(location: $0.offset, length: $0.length))
            })
        }
        DispatchQueue.main.async {
            guard batch.id == self.projectSearchID else { return }
            if !files.isEmpty {
                let (results, addedCount) = Self.mergeSearchResults(self.projectSearchResults, adding: files)
                if addedCount > 0 {
                    self.projectSearchResults = results
                    self.projectSearchTotalMatches += addedCount
                }
            }
            if batch.done == true {
                self.isProjectSearching = false
            }
        }
    }

    func openMultiBufferFromReferences(_ locations: [LSPLocation], symbolName: String) {
        showReferences = false
        multiBufferTitle = symbolName

        struct SimpleLoc: Codable {
            let filePath: String
            let line: Int
            let column: Int
        }
        let locs = locations.map {
            SimpleLoc(filePath: $0.path, line: $0.range.start.line + 1, column: $0.range.start.character + 1)
        }
        guard let data = try? JSONEncoder().encode(locs),
              let json = String(data: data, encoding: .utf8) else { return }

        let dir = activeWorkspacePath
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cDir = dir.cString(using: .utf8),
                  let cJson = json.cString(using: .utf8),
                  let ptr = BuildGoMultiBufferFromLocations(cDir, cJson, 2) else { return }
            defer { FreeGoCString(ptr) }

            let resStr = String(cString: ptr)
            if let res = try? JSONDecoder().decode(MultiBufferResultDTO.self, from: Data(resStr.utf8)) {
                DispatchQueue.main.async {
                    self.multiBufferResult = res
                    self.isMultiBufferOpen = true
                }
            }
        }
    }

    func openMultiBufferFromProjectSearch() {
        let query = projectSearchResultsQuery
        let dir = activeWorkspacePath
        multiBufferTitle = "“\(query)”"

        let files = projectSearchResults.map(\.filePath)
        guard let filesData = try? JSONEncoder().encode(files),
              let filesJSON = String(data: filesData, encoding: .utf8) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cQuery = query.cString(using: .utf8),
                  let cDir = dir.cString(using: .utf8),
                  let cFiles = filesJSON.cString(using: .utf8),
                  let ptr = BuildGoMultiBuffer(cQuery, cDir, cFiles) else { return }
            defer { FreeGoCString(ptr) }

            let resStr = String(cString: ptr)
            if let res = try? JSONDecoder().decode(MultiBufferResultDTO.self, from: Data(resStr.utf8)) {
                DispatchQueue.main.async {
                    self.multiBufferResult = res
                    self.isMultiBufferOpen = true
                }
            }
        }
    }

    func refreshMultiBuffer() {
        if !projectSearchResultsQuery.isEmpty {
            openMultiBufferFromProjectSearch()
        }
    }
}
