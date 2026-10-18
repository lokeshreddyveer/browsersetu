import XCTest
@testable import Browser_Setu

final class AutomationToolsTests: XCTestCase {
    func testLinksAreFoundOnceWithoutTrailingPunctuation() {
        let text = "See https://a.com/x?id=1, and (https://b.org/page). Again https://a.com/x?id=1! Not a link: ftp://c.com"
        XCTAssertEqual(ClipboardTransforms.links(in: text).map(\.absoluteString), ["https://a.com/x?id=1", "https://b.org/page"])
        XCTAssertTrue(ClipboardTransforms.links(in: "no links here").isEmpty)
    }

    func testCleaningRemovesTrackingOnly() {
        let out = ClipboardTransforms.apply(.cleanLinks, to: "Read https://example.com/a?id=5&utm_source=mail&fbclid=zzz now")
        XCTAssertFalse(out.contains("utm_source")); XCTAssertFalse(out.contains("fbclid"))
        XCTAssertTrue(out.contains("id=5")); XCTAssertTrue(out.hasPrefix("Read ")); XCTAssertTrue(out.hasSuffix(" now"))
    }

    func testLineTransforms() {
        XCTAssertEqual(ClipboardTransforms.apply(.dedupeLines, to: "a\nb\na\nc\nb"), "a\nb\nc")
        XCTAssertEqual(ClipboardTransforms.apply(.sortLines, to: "b10\nb2\na"), "a\nb2\nb10")
        XCTAssertEqual(ClipboardTransforms.apply(.trimLines, to: "  a \n\n  \n b"), "a\nb")
        XCTAssertEqual(ClipboardTransforms.apply(.extractLinks, to: "x https://a.com y\nhttps://b.com"), "https://a.com\nhttps://b.com")
        XCTAssertEqual(ClipboardTransforms.apply(.plainText, to: "a\u{00A0}b\r\nc"), "a b\nc")
    }

    func testWorkflowTransferRoundTripsAndFiltersUnsafeSteps() {
        let good = Workflow(name: "Morning", steps: [WorkflowStep(kind: .openURL, value: "https://news.example.com"), WorkflowStep(kind: .command, value: "new-tab")])
        let bad = Workflow(name: "Risky", steps: [WorkflowStep(kind: .command, value: "delete-everything")])
        let broken = Workflow(name: "", steps: [])
        let text = WorkflowTransfer.export([good, bad, broken])
        let result = WorkflowTransfer.parse(text, safeCommands: ["new-tab"])
        XCTAssertEqual(result.valid.map(\.name), ["Morning"])
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(WorkflowTransfer.parse("not json", safeCommands: []).valid.count, 0)
    }

    func testWorkflowRunHistoryRoundTrips() throws {
        let run = WorkflowRun(name: "Morning", steps: 3, source: "at start")
        XCTAssertEqual(try JSONDecoder().decode(WorkflowRun.self, from: JSONEncoder().encode(run)), run)
    }
}
