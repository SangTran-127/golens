import Foundation

struct CodeActionTarget: Equatable {
    let range: NSRange
    let anchor: Int

    static func caret(selection: NSRange, characterIndex: Int?, wordRange: (Int) -> NSRange) -> CodeActionTarget {
        var range = selection
        if range.length == 0, let index = characterIndex {
            range = wordRange(index)
            if range.length == 0 { range = NSRange(location: index, length: 0) }
        }
        return CodeActionTarget(range: range, anchor: range.location)
    }

    static func hover(word: NSRange, diagnostic: NSRange, textLength: Int) -> CodeActionTarget? {
        guard word.location != NSNotFound, NSMaxRange(word) <= textLength else { return nil }
        guard diagnostic.location != NSNotFound, NSMaxRange(diagnostic) <= textLength else {
            return CodeActionTarget(range: word, anchor: word.location)
        }
        return CodeActionTarget(range: NSUnionRange(diagnostic, word), anchor: word.location)
    }
}
