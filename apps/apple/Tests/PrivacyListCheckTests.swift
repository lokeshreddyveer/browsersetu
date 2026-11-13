import XCTest
import SetuPrivacyCore
@testable import Browser_Setu

/// The check `updateLists` makes of each downloaded list now runs off the main actor (`PrivacyController.check`). These tests pin two things: it gives the same verdict as the check it replaced, and while it runs
/// the main actor keeps answering. Fixtures are made in memory; nothing is downloaded and no list is installed.
@MainActor
final class PrivacyListCheckTests: XCTestCase {
    /// The check as `updateLists` made it before it was moved (the reference the new one must agree with).
    private func reference(_ data: Data, name: String) -> PrivacyController.ListCheck {
        guard String(data: data, encoding: .utf8) != nil else { return .notText }
        guard (try? FilterParser.parse(data, source: name)) != nil || !ABPContentParser.parse(data).isEmpty else { return .unusable }
        return .usable
    }

    func testTheMovedCheckGivesTheSameVerdictsAsTheOriginal() async {
        let samples: [(String, Data)] = [
            ("domain list", Data("ads.localhost\ntracker.example\n".utf8)),
            ("adblock style", Data("||ads.example.com^\n||track.example.org^$third-party\n! a comment\n".utf8)),
            ("garbage page", Data("<html>not a filter list</html>\n".utf8)),
            ("comments only", Data("! only a comment\n# another\n".utf8)),
            ("empty", Data()),
            ("not text", Data([0xFF, 0xFE, 0xFD, 0x00, 0x80])),
            ("mixed", Data("ads.localhost\n<html>\n||x.example^\n".utf8)),
        ]
        for (label, data) in samples {
            let moved = await PrivacyController.check(downloaded: data, name: label)
            XCTAssertEqual(moved, reference(data, name: label), "\(label): the moved check disagrees with the original")
        }
    }

    /// While a large list is being checked the main actor still runs: a task that sleeps 40 ms at a time is woken on time. (Run on the main actor, the same check would hold it for as long as the parse takes.)
    func testTheMainActorStaysResponsiveWhileALargeListIsChecked() async throws {
        let lines = (0..<160_000).map { "||ad\($0).tracker\($0 % 97).example.com^" }
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertLessThan(data.count, FilterParser.byteLimit, "the fixture must be under the list size limit to be parsed")
        var worst = 0.0, beats = 0
        let started = Date()
        let finished = FinishedFlag()
        let check = Task { () -> PrivacyController.ListCheck in
            let result = await PrivacyController.check(downloaded: data, name: "large fixture")
            await finished.set()
            return result
        }
        while !(await finished.value) && Date().timeIntervalSince(started) < 90 {
            let before = Date()
            try await Task.sleep(nanoseconds: 40_000_000)
            worst = max(worst, Date().timeIntervalSince(before) - 0.040)
            beats += 1
        }
        let verdict = await check.value
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(verdict, .usable, "the large fixture was not read as a usable list")
        XCTAssertGreaterThan(beats, 2, "the check finished too fast (\(took) s) to show anything about the main actor; make the fixture larger")
        XCTAssertLessThan(worst, 0.25, "the main actor was held for \(worst) s while the list was checked (the check took \(took) s)")
    }
}

private actor FinishedFlag {
    private(set) var value = false
    func set() { value = true }
}
