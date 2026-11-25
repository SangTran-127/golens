import Foundation
import XCTest
import GoLensFoundation

final class LineEditingTests: XCTestCase {
    private func split(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let first = ns.range(of: "|").location
        let rest = ns.replacingCharacters(in: NSRange(location: first, length: 1), with: "") as NSString
        let second = rest.range(of: "|").location
        guard second != NSNotFound else { return (rest as String, NSRange(location: first, length: 0)) }
        let text = rest.replacingCharacters(in: NSRange(location: second, length: 1), with: "")
        return (text, NSRange(location: first, length: second - first))
    }

    private func render(_ text: String, _ edit: LineEdit?) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        if edit.selection.length == 0 {
            return result.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "|")
        }
        let end = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "|") as NSString
        return end.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "|")
    }

    private func join(_ marked: String) -> String? {
        let (text, selection) = split(marked)
        return render(text, LineJoiner.join(text: text, selection: selection))
    }

    private func move(_ marked: String, up: Bool) -> String? {
        let (text, selection) = split(marked)
        return render(text, StatementMover.move(text: text, selection: selection, up: up))
    }

    func testJoinTrimsIndentAndAddsOneSpace() {
        XCTAssertEqual(join("\tx :=| a +\n\t\tb\n"), "\tx := a +| b\n")
    }

    func testJoinAfterOpenParenAddsNoSpace() {
        XCTAssertEqual(join("\tf(|\n\t\ta,\n\t)\n"), "\tf(|a,\n\t)\n")
    }

    func testJoinBeforeClosingParenAddsNoSpace() {
        XCTAssertEqual(join("\tf(a,|\n\t)\n"), "\tf(a,|)\n")
    }

    func testJoinMergesLineComments() {
        XCTAssertEqual(join("// Open reads| the file\n// and returns it.\n"), "// Open reads the file| and returns it.\n")
    }

    func testJoinSelectionJoinsEveryLine() {
        XCTAssertEqual(join("|return Point{\n\tX: 1,\n\tY: 2,\n}|\n"), "return Point{ X: 1, Y: 2,| }\n")
    }

    func testJoinBlankLineKeepsNextLine() {
        XCTAssertEqual(join("|\n\tx := 1\n"), "\t|x := 1\n")
    }

    func testJoinOnLastLineDoesNothing() {
        XCTAssertNil(join("x := 1|\n"))
        XCTAssertNil(join("x := 1|"))
    }

    func testMoveSimpleStatementUp() {
        XCTAssertEqual(move("\ta := 1\n\tb| := 2\n", up: true), "\tb| := 2\n\ta := 1\n")
    }

    func testMoveStatementOverWholeBlock() {
        let text = "\tif ok {\n\t\tx()\n\t}\n\ty|()\n"
        XCTAssertEqual(move(text, up: true), "\ty|()\n\tif ok {\n\t\tx()\n\t}\n")
    }

    func testMoveBlockHeaderMovesWholeBlock() {
        let text = "\tif ok| {\n\t\tx()\n\t}\n\ty()\n"
        XCTAssertEqual(move(text, up: false), "\ty()\n\tif ok| {\n\t\tx()\n\t}\n")
    }

    func testMoveElseMovesWholeIfChain() {
        let text = "\ta()\n\tif ok {\n\t\tx()\n\t} el|se {\n\t\ty()\n\t}\n"
        XCTAssertEqual(move(text, up: true), "\tif ok {\n\t\tx()\n\t} el|se {\n\t\ty()\n\t}\n\ta()\n")
    }

    func testMoveStopsAtStartOfBlock() {
        XCTAssertNil(move("func main() {\n\tx|()\n}\n", up: true))
    }

    func testMoveStopsAtEndOfBlock() {
        XCTAssertNil(move("func main() {\n\tx|()\n}\n", up: false))
    }

    func testMoveStopsAtElse() {
        XCTAssertNil(move("\tif ok {\n\t\tx|()\n\t} else {\n\t}\n", up: false))
    }

    func testMoveFunctionTakesDocComment() {
        let text = "// A does a.\nfunc A() {\n}\n// B does b.\nfunc B|() {\n}\n"
        XCTAssertEqual(move(text, up: true), "// B does b.\nfunc B|() {\n}\n// A does a.\nfunc A() {\n}\n")
    }

    func testMoveFromDocCommentMovesFunction() {
        let text = "// A |does a.\nfunc A() {\n}\nvar x = 1\n"
        XCTAssertEqual(move(text, up: false), "var x = 1\n// A |does a.\nfunc A() {\n}\n")
    }

    func testMoveAcrossBlankLineMovesOneLine() {
        XCTAssertEqual(move("\ta()\n\n\tb|()\n", up: true), "\ta()\n\tb|()\n\n")
    }

    func testMoveMultilineCallAsOneStatement() {
        let text = "\tf(\n\t\ta,\n\t)\n\tg|()\n"
        XCTAssertEqual(move(text, up: true), "\tg|()\n\tf(\n\t\ta,\n\t)\n")
    }

    func testBracesInStringsAndCommentsAreIgnored() {
        let text = "\ts := \"{\"\n\tt|() // }\n"
        XCTAssertEqual(move(text, up: true), "\tt|() // }\n\ts := \"{\"\n")
    }

    func testMoveLastLineWithoutNewline() {
        XCTAssertEqual(move("a()\nb|()", up: true), "b|()\na()")
    }

    func testMoveKeepsSelection() {
        XCTAssertEqual(move("a()\n|b()|\n", up: true), "|b()|\na()\n")
    }

    func testContinuesWhenSplittingAComment() {
        XCTAssertEqual(LineCommentContinuation.prefix(lineBeforeCaret: "\t// Open reads", lineAfterCaret: " the file", nextLine: nil), "\t// ")
    }

    func testContinuesInsideACommentBlock() {
        XCTAssertEqual(LineCommentContinuation.prefix(lineBeforeCaret: "// Open reads.", lineAfterCaret: "", nextLine: "// It returns."), "// ")
    }

    func testKeepsListIndentInComments() {
        XCTAssertEqual(LineCommentContinuation.prefix(lineBeforeCaret: "//   - first", lineAfterCaret: " second", nextLine: nil), "//   ")
    }

    func testEndOfLastCommentLineDoesNotContinue() {
        XCTAssertNil(LineCommentContinuation.prefix(lineBeforeCaret: "// Open reads.", lineAfterCaret: "", nextLine: "func Open() {"))
    }

    func testDirectivesDoNotContinue() {
        XCTAssertNil(LineCommentContinuation.prefix(lineBeforeCaret: "//go:build", lineAfterCaret: " linux", nextLine: nil))
    }

    func testCodeLineDoesNotContinue() {
        XCTAssertNil(LineCommentContinuation.prefix(lineBeforeCaret: "\tx := 1 // one", lineAfterCaret: " two", nextLine: "// next"))
    }
}
