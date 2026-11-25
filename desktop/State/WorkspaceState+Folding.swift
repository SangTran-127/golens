import Foundation
import SwiftUI
import SwiftTerm

extension WorkspaceState {
    func isLineFolded(_ line: Int, in path: String) -> Bool {
        guard let ranges = foldedRanges[path] else { return false }
        for r in ranges {
            if line >= r.startLine && line < r.endLine {
                return true
            }
        }
        return false
    }

    func toggleFold(forLine startLine: Int, in path: String, textView: NSTextView) {
        if foldableRangesWorkItem != nil || foldableRanges[path] == nil, let session = documents[path] {
            foldableRangesWorkItem?.cancel()
            foldableRangesWorkItem = nil
            foldableRanges[path] = findFoldableRanges(in: session.storage.string as NSString, path: path)
        }
        if foldedRanges[path] == nil {
            foldedRanges[path] = []
        }
        
        if let existing = foldedRanges[path]?.first(where: { $0.startLine == startLine }) {
            foldedRanges[path]?.remove(existing)
        } else {
            if let rangeToFold = foldableRanges[path]?.first(where: { $0.startLine == startLine }) {
                foldedRanges[path]?.insert(rangeToFold)
            }
        }
        
        updateFoldedCharRangesCache(for: path, textView: textView)
    }

    func cancelFoldableUpdate() {
        foldableRangesWorkItem?.cancel()
        foldableRangesWorkItem = nil
    }

    func scheduleFoldableUpdate(for path: String, session: DocumentSession, textView: NSTextView) {
        foldableRangesWorkItem?.cancel()
        final class TokenBox: @unchecked Sendable {
            weak var workItem: DispatchWorkItem?
        }
        let token = TokenBox()
        let workItem = DispatchWorkItem { [weak self, weak textView, weak session] in
            guard let self,
                  let current = token.workItem,
                  self.foldableRangesWorkItem === current,
                  let session,
                  let textView,
                  self.documents[path] === session else { return }
            if let goTextView = textView as? GoLensTextView, goTextView.document !== session {
                return
            }
            let snapshot = NSString(string: session.storage.string)
            let version = session.version
            DispatchQueue.global(qos: .utility).async { [weak self, weak textView, weak session] in
                let ranges = findFoldableRanges(in: snapshot, path: path)
                DispatchQueue.main.async {
                    guard let self,
                          let current = token.workItem,
                          self.foldableRangesWorkItem === current,
                          let session,
                          session.version == version,
                          self.documents[path] === session else { return }
                    self.foldableRangesWorkItem = nil
                    self.foldableRanges[path] = ranges
                    if let textView {
                        self.updateFoldedCharRangesCache(for: path, textView: textView)
                        textView.setNeedsDisplay(textView.visibleRect)
                    }
                }
            }
        }
        token.workItem = workItem
        foldableRangesWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func updateFoldableRanges(for path: String, session: DocumentSession) {
        let snapshot = NSString(string: session.storage.string)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ranges = findFoldableRanges(in: snapshot, path: path)
            DispatchQueue.main.async {
                guard let self, self.documents[path] === session else { return }
                self.foldableRanges[path] = ranges
            }
        }
    }

    func updateFoldedCharRangesCache(for path: String, textView: NSTextView) {
        let old = foldedCharRangesCache[path] ?? []
        let new = (documents[path].map { session in (foldedRanges[path] ?? []).compactMap { session.charRange(forFoldableRange: $0) } } ?? []).sorted { $0.location < $1.location }
        foldedCharRangesCache[path] = new
        guard let lm = textView.layoutManager, old != new else { return }
        let ns = textView.string as NSString
        let length = ns.length
        for r in old + new where NSMaxRange(r) <= length {
            let full = ns.lineRange(for: r)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            lm.ensureGlyphs(forCharacterRange: full)
            lm.ensureLayout(forCharacterRange: full)
        }
        if let r = new.first(where: { NSLocationInRange(textView.selectedRange().location, $0) }) {
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
        }
        if let tc = textView.textContainer {
            let visibleGlyphs = lm.glyphRange(forBoundingRect: textView.visibleRect, in: tc)
            lm.ensureLayout(forGlyphRange: visibleGlyphs)
        }
        textView.setNeedsDisplay(textView.visibleRect)
        textView.needsDisplay = true
    }

    func setFold(_ fold: Bool, all: Bool) {
        guard let textView = activeTextView, let session = documents[activeFilePath] else { return }
        let path = activeFilePath
        if foldableRangesWorkItem != nil || foldableRanges[path] == nil {
            foldableRangesWorkItem?.cancel()
            foldableRangesWorkItem = nil
            foldableRanges[path] = findFoldableRanges(in: session.storage.string as NSString, path: path)
        }
        if all {
            foldedRanges[path] = fold ? Set(foldableRanges[path] ?? []) : []
        } else {
            let line = session.lines.line(at: textView.selectedRange().location) + 1
            let candidates = fold ? (foldableRanges[path] ?? []) : Array(foldedRanges[path] ?? [])
            guard let inner = candidates.filter({ $0.startLine <= line && line <= $0.endLine && $0.endLine > $0.startLine }).max(by: { $0.startLine < $1.startLine }) else { return }
            if fold { foldedRanges[path, default: []].insert(inner) } else { foldedRanges[path]?.remove(inner) }
        }
        updateFoldedCharRangesCache(for: path, textView: textView)
    }

}
