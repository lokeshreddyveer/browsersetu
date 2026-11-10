import XCTest
@testable import Browser_Setu

/// The tools stay responsive whatever is typed into them.
final class ToolBoundsTests: XCTestCase {
    func testAPatternThatCouldRunForeverIsStoppedInAboutASecond() {
        let started = Date()
        let result = DevUtilities.testRegex("(a+)+$", in: String(repeating: "a", count: 40) + "!")
        let took = Date().timeIntervalSince(started)
        guard case .failed(let why) = result else { return XCTFail("it should have been stopped, not answered: \(result)") }
        XCTAssertTrue(why.contains("took too long"), why)
        XCTAssertLessThan(took, 3.0, "stopped in \(took) seconds")
    }

    func testAShortTimeLimitStopsASlowPatternSooner() {
        let started = Date()
        _ = DevUtilities.testRegex("(a|aa)+$", in: String(repeating: "a", count: 45) + "!", timeLimit: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testOrdinaryPatternsStillGiveTheirMatches() {
        guard case .matches(let found) = DevUtilities.testRegex("(\\d+)-(\\w+)", in: "10-ab 20-cd") else { return XCTFail() }
        XCTAssertEqual(found.map(\.text), ["10-ab", "20-cd"])
        XCTAssertEqual(found.first?.groups, ["10", "ab"])
        guard case .matches(let none) = DevUtilities.testRegex("zzz", in: "abc") else { return XCTFail() }
        XCTAssertTrue(none.isEmpty)
        if case .failed(let why) = DevUtilities.testRegex("(", in: "x") { XCTAssertTrue(why.contains("not valid")) } else { XCTFail() }
        guard case .matches(let many) = DevUtilities.testRegex("a", in: String(repeating: "a", count: 2_000)) else { return XCTFail() }
        XCTAssertEqual(many.count, 500, "no more than 500 matches are kept")
    }

    func testHugePatternsAndHugeTextAreRefusedAtOnce() {
        if case .failed = DevUtilities.testRegex(String(repeating: "a", count: 501), in: "a") {} else { XCTFail("pattern too long") }
        if case .failed = DevUtilities.testRegex("a", in: String(repeating: "a", count: 50_001)) {} else { XCTFail("text too long") }
    }

    func testEveryToolRefusesAMillionCharactersInsteadOfLockingUp() throws {
        let big = String(repeating: "x", count: ToolDescriptor.maxInput + 1)
        for tool in ToolRegistry.all {
            let values = Dictionary(uniqueKeysWithValues: tool.inputs.map { ($0.id, big) })
            let started = Date()
            let out = tool.runBounded(values)
            XCTAssertNotNil(out.error, tool.id)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, tool.id)
        }
    }

    func testAComparisonOfTooManyLinesIsRefused() throws {
        let many = Array(repeating: "line", count: DevUtilities.maxDiffLines + 5).joined(separator: "\n")
        let diff = try XCTUnwrap(ToolRegistry.tool("diff"))
        XCTAssertNotNil(diff.runBounded(["left": many, "right": "x"]).error)
        XCTAssertNil(diff.runBounded(["left": "a\nb", "right": "a\nc"]).error)
    }

    func testTheToolsGiveTheSameAnswersThroughTheBoundedPath() {
        for tool in ToolRegistry.all where !tool.example.isEmpty {
            let direct = tool.run(tool.example), bounded = tool.runBounded(tool.example)
            XCTAssertEqual(direct.error == nil, bounded.error == nil, tool.id)
            if tool.id != "uuid" { XCTAssertEqual(direct, bounded, tool.id) }
        }
    }

    func testThePanelNeverWorksOutAToolInsideTheViewBody() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/ToolsPanel.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        XCTAssertFalse(text.contains(".run(values)"), "the result is worked out once, off the main thread")
        XCTAssertTrue(text.contains("Task.detached") && text.contains("ToolJob("))
        XCTAssertTrue(text.contains("copySecretToPasteboard"), "a token's contents are copied as a secret")
    }
}
