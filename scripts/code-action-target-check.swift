import Foundation

func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }

let source = "\tfor i := len(closer) - 1; i >= 0; i-- {\n\t\tcloser[i].Close()\n\t}\n" as NSString
let word = source.range(of: "closer")
let loop = NSRange(location: 1, length: source.range(of: "i-- {").location + 3 - 1)
let caretOnBrace = NSRange(location: source.length - 2, length: 0)
func noWord(_ index: Int) -> NSRange { NSRange(location: index, length: 0) }
func wordAt(_ index: Int) -> NSRange { word }

let hover = CodeActionTarget.hover(word: word, diagnostic: loop, textLength: source.length)
expect(hover != nil, "a hovered symbol has code actions")
expect(hover?.range == loop, "the request covers the hovered diagnostic, so its quick fix is offered")
expect(hover?.anchor == word.location, "the menu opens at the hovered symbol, not at the caret")
expect(hover.map { NSLocationInRange(caretOnBrace.location, $0.range) } == false, "the caret line does not decide the hover request")

let wordOnly = CodeActionTarget.hover(word: word, diagnostic: NSRange(location: NSNotFound, length: 0), textLength: source.length)
expect(wordOnly == CodeActionTarget(range: word, anchor: word.location), "without a diagnostic the request covers the hovered symbol")

let partial = NSRange(location: word.location + 2, length: 10)
expect(CodeActionTarget.hover(word: word, diagnostic: partial, textLength: source.length)?.range == NSUnionRange(word, partial), "the request covers both the symbol and the diagnostic")

expect(CodeActionTarget.hover(word: NSRange(location: NSNotFound, length: 0), diagnostic: loop, textLength: source.length) == nil, "no hovered symbol, no hover request")
expect(CodeActionTarget.hover(word: NSRange(location: source.length, length: 4), diagnostic: loop, textLength: source.length) == nil, "a stale hover beyond the text is ignored")
let stale = CodeActionTarget.hover(word: word, diagnostic: NSRange(location: 2, length: source.length), textLength: source.length)
expect(stale == CodeActionTarget(range: word, anchor: word.location), "a stale diagnostic range falls back to the symbol")

let caret = CodeActionTarget.caret(selection: caretOnBrace, characterIndex: caretOnBrace.location, wordRange: noWord)
expect(caret == CodeActionTarget(range: caretOnBrace, anchor: caretOnBrace.location), "Option-Return keeps using the insertion point")
let caretWord = CodeActionTarget.caret(selection: NSRange(location: word.location + 1, length: 0), characterIndex: word.location + 1, wordRange: wordAt)
expect(caretWord == CodeActionTarget(range: word, anchor: word.location), "an insertion point inside a word uses that word")
let selection = NSRange(location: 1, length: 3)
expect(CodeActionTarget.caret(selection: selection, characterIndex: 20, wordRange: wordAt).range == selection, "a selection wins over the clicked index")
expect(CodeActionTarget.caret(selection: caretOnBrace, characterIndex: nil, wordRange: wordAt).range == caretOnBrace, "without an index the insertion point is used as is")

print("ok")
