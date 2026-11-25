import XCTest
import GoLensFoundation

final class DefinitionSnippetTests: XCTestCase {
    func testFunctionIncludesDocCommentAndBody() {
        let text = "package main\n\n// Add sums two numbers.\n// It never fails.\nfunc Add(a, b int) int {\n\treturn a + b\n}\n\nfunc other() {}\n"
        XCTAssertEqual(
            DefinitionSnippet.extract(text: text, line: 4),
            DefinitionSnippet(firstLine: 2, code: "// Add sums two numbers.\n// It never fails.\nfunc Add(a, b int) int {\n    return a + b\n}", truncated: false)
        )
    }

    func testStructFieldIsOneLineWithoutIndent() {
        let text = "type User struct {\n\t// Name is shown.\n\tName string\n\tAge  int\n}\n"
        XCTAssertEqual(
            DefinitionSnippet.extract(text: text, line: 2),
            DefinitionSnippet(firstLine: 1, code: "// Name is shown.\nName string", truncated: false)
        )
    }

    func testNestedBlockKeepsRelativeIndent() {
        let text = "func f() {\n\tfor i := range xs {\n\t\tuse(i)\n\t}\n}\n"
        XCTAssertEqual(DefinitionSnippet.extract(text: text, line: 1)?.code, "for i := range xs {\n    use(i)\n}")
    }

    func testMultilineSignatureRunsToClosingBrace() {
        let text = "func New(\n\tname string,\n) *T {\n\treturn &T{name: name}\n}\n"
        XCTAssertEqual(DefinitionSnippet.extract(text: text, line: 0)?.code, "func New(\n    name string,\n) *T {\n    return &T{name: name}\n}")
    }

    func testBracesInStringsDoNotEndTheSnippet() {
        let text = "var s = map[string]string{\n\t\"a\": \"}\",\n}\nvar t = 1\n"
        XCTAssertEqual(DefinitionSnippet.extract(text: text, line: 0)?.code, "var s = map[string]string{\n    \"a\": \"}\",\n}")
    }

    func testLongDefinitionIsTruncated() {
        let body = (1...60).map { "\tx\($0)()" }.joined(separator: "\n")
        let text = "func big() {\n\(body)\n}\n"
        let snippet = DefinitionSnippet.extract(text: text, line: 0, maxLines: 40)
        XCTAssertEqual(snippet?.truncated, true)
        XCTAssertEqual(snippet?.code.components(separatedBy: "\n").count, 40)
    }

    func testUnbalancedFileStopsAtEnd() {
        XCTAssertEqual(DefinitionSnippet.extract(text: "func f() {\n\tx()", line: 0)?.code, "func f() {\n    x()")
    }

    func testOutOfRangeLineReturnsNil() {
        XCTAssertNil(DefinitionSnippet.extract(text: "var x = 1\n", line: 1))
        XCTAssertNil(DefinitionSnippet.extract(text: "var x = 1\n", line: 9))
    }
}
