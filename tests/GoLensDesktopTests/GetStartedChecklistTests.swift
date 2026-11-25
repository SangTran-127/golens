import XCTest
import GoLensFoundation

final class GetStartedChecklistTests: XCTestCase {
    func testStartsEmptyAndCountsProgress() {
        var checklist = GetStartedChecklist(storedCompleted: [], isHidden: false)
        XCTAssertEqual(checklist.progressText, "0 of 5 done")
        XCTAssertTrue(checklist.complete(.commandPalette))
        XCTAssertFalse(checklist.complete(.commandPalette))
        XCTAssertTrue(checklist.isDone(.commandPalette))
        XCTAssertFalse(checklist.isDone(.openProject))
        XCTAssertEqual(checklist.progressText, "1 of 5 done")
    }

    func testStoredStepsRoundTripInDisplayOrderAndIgnoreUnknownNames() {
        let checklist = GetStartedChecklist(storedCompleted: ["commandPalette", "retiredStep", "openProject"], isHidden: true)
        XCTAssertEqual(checklist.storedCompleted, ["openProject", "commandPalette"])
        XCTAssertTrue(checklist.isHidden)
        XCTAssertEqual(GetStartedChecklist(storedCompleted: checklist.storedCompleted, isHidden: true), checklist)
    }

    func testFinishesWhenEveryStepIsDone() {
        var checklist = GetStartedChecklist(storedCompleted: [], isHidden: false)
        for step in GetStartedStep.allCases { checklist.complete(step) }
        XCTAssertTrue(checklist.isFinished)
        XCTAssertEqual(checklist.progressText, "All done")
    }
}
