import Foundation
import XCTest
import GoLensFoundation

final class StatementCompletionTests: XCTestCase {
    private func complete(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        guard let edit = StatementCompletion.compute(text: text, caret: caret) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.caret, length: 0), with: "|")
    }

    func testClosesCallAndMovesToNextLine() {
        XCTAssertEqual(complete("\tfmt.Println(\"a\"|\n"), "\tfmt.Println(\"a\")\n\t|\n")
    }

    func testClosesOpenStringBeforeParens() {
        XCTAssertEqual(complete("\tfmt.Println(\"a|"), "\tfmt.Println(\"a\")\n\t|")
    }

    func testIfGetsBracesAndCaretInside() {
        XCTAssertEqual(complete("\tif x > 0|\n"), "\tif x > 0 {\n\t\t|\n\t}\n")
    }

    func testFuncHeaderClosesParamsAndAddsBody() {
        XCTAssertEqual(complete("func add(a, b int|"), "func add(a, b int) {\n\t|\n}")
    }

    func testForWithoutClause() {
        XCTAssertEqual(complete("\tfor|"), "\tfor {\n\t\t|\n\t}")
    }

    func testElseAfterClosingBrace() {
        XCTAssertEqual(complete("\t} else|"), "\t} else {\n\t\t|\n\t}")
    }

    func testSwitchKeepsCasesAtSwitchIndent() {
        XCTAssertEqual(complete("\tswitch v|"), "\tswitch v {\n\t|\n\t}")
    }

    func testCaseGetsColon() {
        XCTAssertEqual(complete("\tcase 1, 2|"), "\tcase 1, 2:\n\t\t|")
    }

    func testStructType() {
        XCTAssertEqual(complete("type Point struct|"), "type Point struct {\n\t|\n}")
    }

    func testPlainTypeIsNotABlock() {
        XCTAssertEqual(complete("type ID int|"), "type ID int\n|")
    }

    func testGoroutineLiteralIsCalled() {
        XCTAssertEqual(complete("\tgo func(|"), "\tgo func() {\n\t\t|\n\t}()")
    }

    func testAssignedFuncLiteral() {
        XCTAssertEqual(complete("\th := func(w http.ResponseWriter|"), "\th := func(w http.ResponseWriter) {\n\t\t|\n\t}")
    }

    func testFuncArgumentIsNotABlock() {
        XCTAssertEqual(complete("\tsort.Slice(xs, less|"), "\tsort.Slice(xs, less)\n\t|")
    }

    func testCompleteStatementOnlyAddsALine() {
        XCTAssertEqual(complete("\tx :=| 1\n\ty := 2\n"), "\tx := 1\n\t|\n\ty := 2\n")
    }

    func testTrailingCommentStaysAfterTheCode() {
        XCTAssertEqual(complete("\tif ok| // check\n"), "\tif ok { // check\n\t\t|\n\t}\n")
    }

    func testOpenBraceWithExistingBodyAddsLineInside() {
        XCTAssertEqual(complete("func main() {|\n\tx := 1\n}\n"), "func main() {\n\t|\n\tx := 1\n}\n")
    }

    func testOpenBraceWithClosedEmptyBody() {
        XCTAssertEqual(complete("\tif ok {|\n\t}\n"), "\tif ok {\n\t\t|\n\t}\n")
    }

    func testOpenBraceWithoutCloserAddsIt() {
        XCTAssertEqual(complete("\tif ok {|\n"), "\tif ok {\n\t\t|\n\t}\n")
    }

    func testCompositeLiteralClosesBrace() {
        XCTAssertEqual(complete("\tp := Point{X: 1|"), "\tp := Point{X: 1}\n\t|")
    }

    func testBracketsInsideStringsAreIgnored() {
        XCTAssertEqual(complete("\tlog.Print(\"(\"|"), "\tlog.Print(\"(\")\n\t|")
    }

    func testBlankLineDoesNothing() {
        XCTAssertNil(complete("\t|\n"))
    }
}
