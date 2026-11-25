import Foundation
import XCTest
import GoLensFoundation

final class SQLNameReferenceTests: XCTestCase {
    private func reference(_ text: String, at needle: String, offset: Int = 0) -> SQLNameReference? {
        let ns = text as NSString
        let location = ns.range(of: needle).location
        XCTAssertNotEqual(location, NSNotFound, needle)
        return SQLNameReference.at(location + offset, in: ns)
    }

    private func names(_ reference: SQLNameReference?) -> [String] {
        reference?.parts.map(\.name) ?? []
    }

    func testPlainName() {
        let ref = reference("SELECT * FROM orders WHERE id = 1", at: "orders", offset: 2)
        XCTAssertEqual(names(ref), ["orders"])
        XCTAssertEqual(ref?.range, NSRange(location: 14, length: 6))
    }

    func testSchemaQualifiedNameKeepsTheQualifier() {
        let text = "SELECT * FROM public.orders o"
        let ref = reference(text, at: "orders")
        XCTAssertEqual(names(ref), ["public", "orders"])
        XCTAssertEqual((text as NSString).substring(with: ref!.range), "public.orders")
    }

    func testHoveringTheQualifierStopsThere() {
        XCTAssertEqual(names(reference("SELECT o.id FROM public.orders o", at: "public")), ["public"])
    }

    func testColumnAfterTableIncludesEarlierParts() {
        XCTAssertEqual(names(reference("SELECT orders.id FROM orders", at: "id ")), ["orders", "id"])
    }

    func testQuotedNamesAreUnquoted() {
        let ref = reference("SELECT * FROM \"Sales\".\"Order \"\"Items\"\"\"", at: "Order")
        XCTAssertEqual(names(ref), ["Sales", "Order \"Items\""])
        XCTAssertEqual(ref?.parts.map(\.quoted), [true, true])
        XCTAssertEqual(names(reference("SELECT * FROM `shop`.`Orders`", at: "Orders")), ["shop", "Orders"])
    }

    func testStringsAndCommentsAreNotNames() {
        XCTAssertNil(reference("SELECT 'orders' FROM t", at: "orders"))
        XCTAssertNil(reference("SELECT 1 -- from orders", at: "orders"))
        XCTAssertNil(reference("SELECT 1 /* orders */ FROM t", at: "orders"))
        XCTAssertNil(reference("SELECT 'it''s orders' FROM t", at: "orders"))
        XCTAssertEqual(names(reference("SELECT 'a' FROM orders -- note", at: "orders")), ["orders"])
    }

    func testNumbersAndPunctuationAreNotNames() {
        XCTAssertNil(reference("SELECT 1.5 FROM t", at: "5"))
        XCTAssertNil(reference("SELECT * FROM t", at: "*"))
        XCTAssertNil(SQLNameReference.at(99, in: "SELECT" as NSString))
    }
}
