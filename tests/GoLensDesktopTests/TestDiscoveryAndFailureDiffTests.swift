import XCTest
import GoLensFoundation

final class TestDiscoveryAndFailureDiffTests: XCTestCase {
    func testGoTestCompletionContextTopLevelPrefixes() {
        let base = """
        package billing

        import "testing"

        func TestExisting(t *testing.T) {
            t.Log("func TestInsideString")
        }

        func Test
        """
        let caretAtEnd = (base as NSString).length
        let match = GoTestCompletionContext.topLevelTestDeclPrefix(in: base, caretUTF16: caretAtEnd)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.prefix, "Test")
        XCTAssertEqual(match?.hasParameterParenAfterCaret, false)
        XCTAssertEqual((base as NSString).substring(from: match?.anchorUTF16Offset ?? 0), "Test")

        let partial = "package x\n\nfunc T"
        let partialMatch = GoTestCompletionContext.topLevelTestDeclPrefix(in: partial, caretUTF16: (partial as NSString).length)
        XCTAssertEqual(partialMatch?.prefix, "T")

        let afterSpace = "package x\n\nfunc "
        XCTAssertNil(GoTestCompletionContext.topLevelTestDeclPrefix(in: afterSpace, caretUTF16: (afterSpace as NSString).length, allowEmptyAfterFunc: false))
        let explicitMatch = GoTestCompletionContext.topLevelTestDeclPrefix(in: afterSpace, caretUTF16: (afterSpace as NSString).length, allowEmptyAfterFunc: true)
        XCTAssertEqual(explicitMatch?.prefix, "")

        let withParen = "package x\n\nfunc TestFoo(t *testing.T) {}"
        let caretBeforeParen = ("package x\n\nfunc TestFoo" as NSString).length
        let parenMatch = GoTestCompletionContext.topLevelTestDeclPrefix(in: withParen, caretUTF16: caretBeforeParen)
        XCTAssertEqual(parenMatch?.prefix, "TestFoo")
        XCTAssertEqual(parenMatch?.hasParameterParenAfterCaret, true)
    }

    func testGoTestCompletionContextRejectsNonTopLevelOrNonTestNames() {
        let insideFunc = """
        package billing

        func TestExisting(t *testing.T) {
            func Test
        }
        """
        let caret = ("package billing\n\nfunc TestExisting(t *testing.T) {\n    func Test" as NSString).length
        XCTAssertNil(GoTestCompletionContext.topLevelTestDeclPrefix(in: insideFunc, caretUTF16: caret))

        let nonTest = "package x\n\nfunc Helper"
        XCTAssertNil(GoTestCompletionContext.topLevelTestDeclPrefix(in: nonTest, caretUTF16: (nonTest as NSString).length))

        let commented = "package x\n\n// func TestCommented"
        XCTAssertNil(GoTestCompletionContext.topLevelTestDeclPrefix(in: commented, caretUTF16: (commented as NSString).length))

        let existing = GoTestCompletionContext.existingTopLevelTestNames(in: """
        package x
        func TestAlpha(t *testing.T) {}
        func (s *Suite) TestBeta() {}
        func helper() {}
        """)
        XCTAssertEqual(existing, ["TestAlpha", "TestBeta"])
    }

    func testFailedSubtestSelectionPrunesAncestors() {
        let pruned = FailedSubtestSelection.pruneAncestors([
            "TestSuite",
            "TestSuite/auth",
            "TestSuite/auth/expired_token",
            "TestSuite/billing",
            "TestStandalone",
        ])
        XCTAssertEqual(pruned, [
            "TestStandalone",
            "TestSuite/auth/expired_token",
            "TestSuite/billing",
        ])
    }

    func testSideBySideDiffAlignmentKeepsContextSynchronized() {
        let lines = [
            TestDiffLineItem(id: "1", type: "same", text: "Config{", lineNum: 1),
            TestDiffLineItem(id: "2", type: "want", text: "  Port: 9090,", lineNum: 2),
            TestDiffLineItem(id: "3", type: "want", text: "  TLS: true,", lineNum: 3),
            TestDiffLineItem(id: "4", type: "got", text: "  Port: 8080,", lineNum: 2),
            TestDiffLineItem(id: "5", type: "same", text: "}", lineNum: 4),
        ]
        let aligned = TestFailureDiffAlignment.alignSideBySide(lines)
        XCTAssertEqual(aligned.count, 4)
        XCTAssertEqual(aligned[0].want?.text, "Config{")
        XCTAssertEqual(aligned[0].got?.text, "Config{")
        XCTAssertEqual(aligned[1].want?.text, "  Port: 9090,")
        XCTAssertEqual(aligned[1].got?.text, "  Port: 8080,")
        XCTAssertEqual(aligned[2].want?.text, "  TLS: true,")
        XCTAssertNil(aligned[2].got)
        XCTAssertEqual(aligned[3].want?.text, "}")
        XCTAssertEqual(aligned[3].got?.text, "}")
    }
}
