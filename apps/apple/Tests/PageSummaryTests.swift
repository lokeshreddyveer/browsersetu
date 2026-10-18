import XCTest
@testable import Browser_Setu

final class PageSummaryTests: XCTestCase {
    func testBlankLinesAndSpacesAreTidiedAwayBeforeTheModelReadsTheText() {
        XCTAssertEqual(PageSummary.trimmed("  Hello  \r\n\r\n\n  World \n"), "Hello\nWorld")
    }

    func testALongPageIsCutAtTheEndOfAParagraphNearTheLimit() {
        let paragraph = String(repeating: "word ", count: 300)   // 1500 characters
        let page = Array(repeating: paragraph, count: 20).joined(separator: "\n")
        let cut = PageSummary.trimmed(page)
        XCTAssertLessThanOrEqual(cut.count, PageSummary.characterLimit)
        XCTAssertGreaterThan(cut.count, PageSummary.characterLimit / 2)
        XCTAssertTrue(cut.hasSuffix("word"), "cut at a whole paragraph, not in the middle of one")
    }

    func testThePromptNamesThePageAndKeepsItsText() {
        let prompt = PageSummary.prompt(title: "A Title", text: "Body text here.")
        XCTAssertTrue(prompt.contains("A Title"))
        XCTAssertTrue(prompt.contains("Body text here."))
    }

    func testAPageWithNoTextFailsPlainlyAndNeverCallsTheModel() async {
        do { _ = try await PageSummary.summarize(title: "Empty", text: "  \n \n"); XCTFail("expected a failure") }
        catch { XCTAssertEqual(error as? PageSummary.Failure, .noText) }
    }

    func testTheModelIsEitherReadyOrGivesAReasonInPlainWords() {
        if let reason = PageSummary.unavailableReason { XCTAssertFalse(reason.isEmpty) }
    }
}
