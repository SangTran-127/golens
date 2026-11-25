import XCTest
import GoLensFoundation

final class LinkedRenameTests: XCTestCase {
    private func apply(_ edits: [LinkedEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        XCTAssertEqual(edits.map(\.range.location), edits.map(\.range.location).sorted(by: >))
        for edit in edits { ns.replaceCharacters(in: edit.range, with: edit.text) }
        return ns as String
    }

    private func occurrences(of name: String, in text: String) -> [NSRange] {
        var found: [NSRange] = []
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let hit = ns.range(of: name, options: [], range: search)
            guard hit.location != NSNotFound else { return found }
            found.append(hit)
            search = NSRange(location: NSMaxRange(hit), length: ns.length - NSMaxRange(hit))
        }
    }

    func testTypingInPrimaryMirrorsEveryOccurrence() {
        var text = "a := greet()\nb := greet()\nfunc greet() {}\n"
        let ranges = occurrences(of: "greet", in: text)
        var rename = LinkedRename(original: "greet", ranges: ranges, primaryLocation: ranges[1].location + 2)!
        XCTAssertEqual(rename.primaryIndex, 1)

        let typed = NSRange(location: NSMaxRange(rename.primaryRange), length: 0)
        text = apply(rename.apply(typed, replacement: "ing")!, to: text)

        XCTAssertEqual(text, "a := greeting()\nb := greeting()\nfunc greeting() {}\n")
        XCTAssertEqual(rename.name, "greeting")
        XCTAssertEqual(rename.ranges, occurrences(of: "greeting", in: text))
    }

    func testDeletingAndReplacingKeepsRangesInStep() {
        var text = "x x x"
        var rename = LinkedRename(original: "x", ranges: occurrences(of: "x", in: text), primaryLocation: 4)!
        let replace = rename.primaryRange
        text = apply(rename.apply(replace, replacement: "total")!, to: text)
        XCTAssertEqual(text, "total total total")

        let backspace = NSRange(location: NSMaxRange(rename.primaryRange) - 2, length: 2)
        text = apply(rename.apply(backspace, replacement: "")!, to: text)
        XCTAssertEqual(text, "tot tot tot")
        XCTAssertEqual(rename.ranges, occurrences(of: "tot", in: text))
    }

    func testEditsOutsideTheNameOrWithSymbolsAreRefused() {
        var rename = LinkedRename(original: "greet", ranges: [NSRange(location: 5, length: 5)], primaryLocation: 5)!
        XCTAssertNil(rename.apply(NSRange(location: 4, length: 1), replacement: ""))
        XCTAssertNil(rename.apply(NSRange(location: 10, length: 1), replacement: "x"))
        XCTAssertNil(rename.apply(NSRange(location: 10, length: 0), replacement: "("))
        XCTAssertNil(rename.apply(NSRange(location: 7, length: 0), replacement: " "))
        XCTAssertNotNil(rename.apply(NSRange(location: 10, length: 0), replacement: "Ñ_2"))
        XCTAssertEqual(rename.name, "greetÑ_2")
    }

    func testSetAllRestoresOriginalFromAnyState() {
        var text = "f(); f(); f()"
        var rename = LinkedRename(original: "f", ranges: occurrences(of: "f", in: text), primaryLocation: 0)!
        let edit = NSRange(location: 1, length: 0)
        text = apply(rename.apply(edit, replacement: "oo")!, to: text)
        XCTAssertEqual(text, "foo(); foo(); foo()")
        text = apply(rename.setAll(to: rename.original), to: text)
        XCTAssertEqual(text, "f(); f(); f()")
        XCTAssertEqual(rename.ranges, occurrences(of: "f", in: text))
        XCTAssertFalse(rename.changed)
        text = apply(rename.setAll(to: "foo"), to: text)
        XCTAssertEqual(text, "foo(); foo(); foo()")
    }

    func testInitDropsMismatchedAndOverlappingRangesAndNeedsPrimary() {
        let rename = LinkedRename(original: "ab", ranges: [NSRange(location: 3, length: 2), NSRange(location: 0, length: 2), NSRange(location: 1, length: 2), NSRange(location: 0, length: 2), NSRange(location: 8, length: 3)], primaryLocation: 5)!
        XCTAssertEqual(rename.ranges, [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(rename.primaryIndex, 1)
        XCTAssertNil(LinkedRename(original: "ab", ranges: [NSRange(location: 0, length: 2)], primaryLocation: 7))
        XCTAssertNil(LinkedRename(original: "", ranges: [], primaryLocation: 0))
    }

    func testShiftMovesRangesAroundForeignEditsAndRejectsOverlap() {
        var rename = LinkedRename(original: "ab", ranges: [NSRange(location: 2, length: 2), NSRange(location: 10, length: 2)], primaryLocation: 2)!
        XCTAssertTrue(rename.shift(byEditAt: NSRange(location: 5, length: 1), newLength: 4))
        XCTAssertEqual(rename.ranges, [NSRange(location: 2, length: 2), NSRange(location: 13, length: 2)])
        XCTAssertTrue(rename.shift(byEditAt: NSRange(location: 2, length: 0), newLength: 1))
        XCTAssertEqual(rename.ranges, [NSRange(location: 3, length: 2), NSRange(location: 14, length: 2)])
        XCTAssertFalse(rename.shift(byEditAt: NSRange(location: 4, length: 1), newLength: 0))
    }

    func testIdentifierProblemsAreExplained() {
        XCTAssertNil(GoIdentifier.problem(with: "newName"))
        XCTAssertNil(GoIdentifier.problem(with: "_private2"))
        XCTAssertEqual(GoIdentifier.problem(with: ""), "Type a name for the symbol.")
        XCTAssertEqual(GoIdentifier.problem(with: "1x"), "A Go name can’t start with a digit.")
        XCTAssertEqual(GoIdentifier.problem(with: "func"), "‘func’ is a Go keyword, so it can’t be a name.")
        XCTAssertEqual(GoIdentifier.problem(with: "a-b"), "Go names use only letters, digits and _.")
        XCTAssertNotNil(GoIdentifier.problem(with: "_"))
        XCTAssertFalse(GoIdentifier.isValid("type"))
    }
}
