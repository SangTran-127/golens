import XCTest
import GoLensFoundation

final class AcknowledgementsTests: XCTestCase {
    private let json = """
    [
     {"title": "Components", "appliesTo": [], "text": "SwiftTerm 1.0\\ngolang.org/x/text v0.44.0\\nGo gopher"},
     {"title": "Go gopher", "appliesTo": [], "text": "Designed by Renée French."},
     {"title": "golang.org/x/text v0.44.0 and 1 more", "appliesTo": ["golang.org/x/text v0.44.0", "golang.org/x/net v0.62.0"], "text": "BSD"},
     {"title": "SwiftTerm 1.0", "appliesTo": ["SwiftTerm 1.0"], "text": "MIT"}
    ]
    """

    func testDecodesAndCountsComponents() {
        let sections = Acknowledgements.decode(Data(json.utf8))
        XCTAssertEqual(sections.count, 4)
        XCTAssertEqual(Acknowledgements.componentCount(in: sections), 3)
        XCTAssertTrue(Acknowledgements.decode(Data("not json".utf8)).isEmpty)
    }

    func testFilterHidesTheComponentListAndMatchesCoveredComponents() {
        let sections = Acknowledgements.decode(Data(json.utf8))
        XCTAssertEqual(Acknowledgements.filter(sections, query: "").map(\.title), ["Go gopher", "golang.org/x/text v0.44.0 and 1 more", "SwiftTerm 1.0"])
        XCTAssertEqual(Acknowledgements.filter(sections, query: " x/net ").map(\.title), ["golang.org/x/text v0.44.0 and 1 more"])
        XCTAssertEqual(Acknowledgements.filter(sections, query: "swiftterm").map(\.title), ["SwiftTerm 1.0"])
        XCTAssertTrue(Acknowledgements.filter(sections, query: "BSD").isEmpty)
    }

    func testRuntimeNoticesSplitIntoTitledSections() {
        let rule = String(repeating: "=", count: 80)
        let text = ["GoLens Linux runtime: third-party notices", "", rule, "Linux kernel 6.18.65 (vmlinuz)", rule, "GPL-2.0", "", rule, "Go 1.27.4 (goroot)", rule, "BSD-3-Clause", ""].joined(separator: "\n")
        let sections = Acknowledgements.runtimeSections(fromNotices: text, prefix: "Linux Sandbox")
        XCTAssertEqual(sections.map(\.title), ["Linux Sandbox: Linux kernel 6.18.65 (vmlinuz)", "Linux Sandbox: Go 1.27.4 (goroot)"])
        XCTAssertEqual(sections.map(\.text), ["GPL-2.0", "BSD-3-Clause"])
        XCTAssertEqual(Acknowledgements.filter(sections, query: "kernel").count, 1)
        XCTAssertTrue(Acknowledgements.runtimeSections(fromNotices: "no rules here", prefix: "x").isEmpty)
    }
}
