import XCTest
@testable import Browser_Setu

final class VimSearchAutomationTests: XCTestCase {
    func testVimSequencesCountsAndEscape() {
        var m = VimMachine()
        XCTAssertEqual(m.feed("j"), .run(.scrollDown, times: 1))
        XCTAssertEqual(m.feed("5"), .waiting)
        XCTAssertEqual(m.feed("j"), .run(.scrollDown, times: 5))
        XCTAssertEqual(m.feed("g"), .waiting)
        XCTAssertEqual(m.feed("g"), .run(.scrollTop, times: 1))
        XCTAssertEqual(m.feed("g"), .waiting)
        XCTAssertEqual(m.feed("\u{1B}"), .none)
        XCTAssertEqual(m.feed("j"), .run(.scrollDown, times: 1), "escape cleared the half-typed sequence")
        XCTAssertEqual(m.feed("g"), .waiting)
        XCTAssertEqual(m.feed("z"), .none, "an unbound continuation resets")
        XCTAssertEqual(m.feed("?"), .none)
    }

    func testKeymapRefusesClashesAndRoundTrips() {
        var k = VimKeymap.standard
        XCTAssertFalse(k.bind("g", to: .reload), "g is the start of gg")
        XCTAssertFalse(k.bind("jj", to: .reload), "j is already an action")
        XCTAssertFalse(k.bind("", to: .reload))
        XCTAssertFalse(k.bind("abcd", to: .reload))
        XCTAssertTrue(k.bind("zz", to: .reload))
        XCTAssertEqual(VimKeymap.decode(k.encoded()), k)
        XCTAssertEqual(VimKeymap.decode(""), .standard)
        XCTAssertEqual(k.sequence(for: .scrollDown), "j")
        XCTAssertEqual(Set(VimKeymap.standard.bindings.values).count, VimKeymap.standard.bindings.count, "no action has two keys by default")
    }

    func testSearchRanksAndDedupes() {
        let entries = [
            SearchEntry(kind: .history, title: "Swift Evolution", detail: "", url: "https://swift.org/evo", key: "h1"),
            SearchEntry(kind: .tab, title: "Swift Evolution", detail: "", url: "https://swift.org/evo", key: "t1"),
            SearchEntry(kind: .bookmark, title: "Recipes", detail: "swift soup", url: "https://food.test", key: "b1"),
            SearchEntry(kind: .history, title: "Other", detail: "", url: "https://o.test", key: "h2"),
        ]
        let found = UnifiedSearch.search("swift", in: entries)
        XCTAssertEqual(found.map(\.key), ["t1", "b1"], "the open tab beats history for the same page; detail-only matches rank last")
        XCTAssertTrue(UnifiedSearch.search("swift evo", in: entries).count == 1)
        XCTAssertTrue(UnifiedSearch.search("   ", in: entries).isEmpty)
        XCTAssertTrue(UnifiedSearch.search("zzz", in: entries).isEmpty)
    }

    func testSearchCapsEachSource() {
        let many = (0..<30).map { SearchEntry(kind: .history, title: "page \($0)", detail: "", url: "https://x.test/\($0)", key: "\($0)") }
        XCTAssertEqual(UnifiedSearch.search("page", in: many).count, 12)
    }

    func testURLActionsAcceptOnlySafeThings() {
        XCTAssertEqual(URLAction.parse(URL(string: "browsersetu://open?url=https%3A%2F%2Fa.test%2Fx&private=1")!), .open(URL(string: "https://a.test/x")!, privateTab: true))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://open?url=file%3A%2F%2F%2Fetc%2Fpasswd")!))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://open?url=javascript%3Aalert(1)")!))
        XCTAssertNil(URLAction.parse(URL(string: "https://open?url=https://a.test")!))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://delete-everything")!))
        XCTAssertEqual(URLAction.parse(URL(string: "browsersetu://search?q=hello%20world")!), .search("hello world"))
        XCTAssertEqual(URLAction.parse(URL(string: "browsersetu://workflow?name=Morning")!), .workflow("Morning"))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://search")!))
    }

    func testWorkflowValidationAndWatchSchedule() {
        XCTAssertTrue(Workflow(name: "A", steps: [WorkflowStep(kind: .openURL, value: "https://a.test"), WorkflowStep(kind: .wait, value: "2")]).isValid)
        XCTAssertFalse(Workflow(name: "A", steps: [WorkflowStep(kind: .openURL, value: "javascript:1")]).isValid)
        XCTAssertFalse(Workflow(name: "A", steps: [WorkflowStep(kind: .wait, value: "999")]).isValid)
        XCTAssertFalse(Workflow(name: " ", steps: [WorkflowStep(kind: .search, value: "x")]).isValid)
        XCTAssertFalse(Workflow(name: "A", steps: []).isValid)
        var w = ScheduledCheck(key: "k", url: "https://a.test", everyMinutes: 60)
        XCTAssertTrue(w.isDue(now: Date()))
        w.lastRun = Date().timeIntervalSince1970
        XCTAssertFalse(w.isDue(now: Date().addingTimeInterval(600)))
        XCTAssertTrue(w.isDue(now: Date().addingTimeInterval(3700)))
    }

    func testScriptsHaveNothingUntilAllowed() {
        var g = ScriptGrants()
        XCTAssertFalse(g.isAllowed("s", .readPage))
        g.allow("s", .readPage)
        XCTAssertTrue(g.isAllowed("s", .readPage)); XCTAssertFalse(g.isAllowed("s", .openTabs)); XCTAssertFalse(g.isAllowed("t", .readPage))
        g.revoke("s"); XCTAssertFalse(g.isAllowed("s", .readPage))
    }
}
