import XCTest
@testable import Browser_Setu

final class SplitToolsTests: XCTestCase {
    func testLinesAreTrimmedShortOnesDroppedAndRepeatsKeptOnce() {
        XCTAssertEqual(PageDiff.lines("  Hello world  \nok\nHello world\n\nAnother line here"), ["Hello world", "Another line here"])
    }

    func testCompareFindsWhatDiffers() {
        let c = PageDiff.compare(leftTitle: "A", left: "Shared line one\nOnly on the left\nShared line two", rightTitle: "B", right: "Shared line two\nShared line one\nOnly on the right\nAnd another right one")
        XCTAssertEqual(c.shared, 2)
        XCTAssertEqual(c.onlyLeft, ["Only on the left"])
        XCTAssertEqual(c.onlyRight, ["Only on the right", "And another right one"])
        XCTAssertEqual(c.similarity, 2.0 / 5.0, accuracy: 0.0001)
    }

    func testIdenticalAndEmptyPages() {
        XCTAssertEqual(PageDiff.compare(leftTitle: "A", left: "Same text here", rightTitle: "B", right: "Same text here").similarity, 1)
        XCTAssertEqual(PageDiff.compare(leftTitle: "A", left: "", rightTitle: "B", right: "").similarity, 1)
        XCTAssertEqual(PageDiff.compare(leftTitle: "A", left: "Only left side", rightTitle: "B", right: "Only right side").similarity, 0)
    }

    func testOtherPaneIsALinkChoice() {
        XCTAssertNotEqual(LinkAction.otherPane, LinkAction.split)
    }
}
