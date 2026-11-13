import XCTest
@testable import Browser_Setu

/// The delayed-suggestion race in the address bar (One Row, and every layout that uses the same field): a response to a request from an editing session that has since ended must not appear in a later
/// session, even when the later session types the same query.
///
/// No network and no production change: under XCTest the engine request returns at once, so the request's only delay is the 180 ms typing pause before it is sent. The sequence is driven inside that
/// pause with the real editing sessions (`refresh`, the model's own tab switch). The response that "arrives" is the pending request waking up; a stale application of it would wipe the suggestions
/// the new session holds, which the test can see.
@MainActor
final class D1cSuggestionRaceTests: XCTestCase {
    private func model(remote: Bool) -> (BrowserModel, TabController, TabController) {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-race-\(UUID().uuidString)", profile: "default")
        m.searchSuggestionsEnabled = remote
        let a = m.openTab(url: URL(string: "about:blank#a")!, isPrivate: false, select: true)
        let b = m.openTab(url: URL(string: "about:blank#b")!, isPrivate: false, select: false)
        return (m, a, b)
    }
    private func edit(_ m: BrowserModel, _ query: String) {
        m.addressBar.isEditing = true
        m.addressBar.text = query
        m.addressBar.refresh(model: m)
    }
    private func titles(_ m: BrowserModel) -> [String] { m.addressBar.suggestions.map(\.title) }
    private let template = "https://duckduckgo.com/?q={}"
    private func ms(_ n: UInt64) async { try? await Task.sleep(nanoseconds: n * 1_000_000) }

    /// The harness sees a request apply: a same-session request that is not cancelled does apply when it wakes (here its empty answer replaces what was shown), so the absence checked below means something.
    func testControlASameSessionRequestThatWakesDoesApply() async {
        let (m, _, _) = model(remote: true)
        edit(m, "swift browser")
        m.addressBar.applyRemote(["marker answer"], query: "swift browser", searchTemplate: template)
        XCTAssertTrue(titles(m).contains("marker answer"), "setup: the answer was not shown")
        await ms(450)
        XCTAssertFalse(titles(m).contains("marker answer"), "the request did not wake and apply, so this test cannot see a stale one either")
    }

    /// Steps 1–6: edit A, the request is pending, switch tabs (the session ends), come back and type A again, then the old request wakes. The new session's suggestions stay as they are.
    func testAnOldRequestWakingInANewSessionOfTheSameQueryIsRejected() async {
        let (m, a, b) = model(remote: true)
        edit(m, "swift browser")                         // 1. query A, request pending (180 ms pause)
        m.select(b.id)                                    // 3. the tab switch ends the session
        XCTAssertFalse(m.addressBar.isEditing)
        m.searchSuggestionsEnabled = false                // keeps the new session from sending its own request, which would also wake and change the list
        m.select(a.id)
        edit(m, "swift browser")                          // 4. a new session, the same query
        m.addressBar.applyRemote(["new session answer"], query: "swift browser", searchTemplate: template)
        XCTAssertTrue(titles(m).contains("new session answer"), "setup: the new session's answer was not shown")
        await ms(450)                                     // 5. the old request wakes
        XCTAssertTrue(titles(m).contains("new session answer"), "the old session's request changed the new session's suggestions: \(titles(m))")
    }

    /// A new session begins with nothing from the last one, even for the same query.
    func testANewSessionStartsWithoutTheLastSessionsAnswers() {
        let (m, _, _) = model(remote: false)
        edit(m, "swift browser")
        m.addressBar.applyRemote(["old answer"], query: "swift browser", searchTemplate: template)
        XCTAssertTrue(titles(m).contains("old answer"))
        m.addressBar.isEditing = false; m.addressBar.clear()
        edit(m, "swift browser")
        XCTAssertFalse(titles(m).contains("old answer"), "the last session's answer is shown at the start of the new one: \(titles(m))")
    }

    /// Ending a session leaves no suggestions and no answers behind.
    func testEndingASessionLeavesNothing() {
        let (m, _, b) = model(remote: true)
        edit(m, "swift browser")
        m.addressBar.applyRemote(["answer"], query: "swift browser", searchTemplate: template)
        m.select(b.id)
        XCTAssertTrue(m.addressBar.suggestions.isEmpty, "suggestions survived the tab switch: \(titles(m))")
    }
}
