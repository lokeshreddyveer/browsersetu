import XCTest
@testable import Browser_Setu

final class SlashCommandTests: XCTestCase {
    func testOnlyATextBeginningWithASlashIsACommand() {
        XCTAssertEqual(SlashParse.parse("tabs mail"), .notACommand)
        XCTAssertEqual(SlashParse.parse("https://a.test/tabs"), .notACommand)
        XCTAssertEqual(SlashParse.parse("/Users/me/file.txt"), .notACommand, "a path is still an address")
        XCTAssertEqual(SlashParse.parse("/zzz thing"), .notACommand)
    }

    func testASlashAloneListsEverythingAndAPrefixNarrowsIt() {
        XCTAssertEqual(SlashParse.parse("/"), .choosing(SlashCommand.allCases))
        XCTAssertEqual(SlashParse.parse("/fi"), .choosing([.find]))
        XCTAssertEqual(SlashParse.parse("/s"), .choosing([.sleep, .save, .scratch, .split]))
    }

    func testAWholeCommandKeepsItsArgumentAndAliasesWork() {
        XCTAssertEqual(SlashParse.parse("/tabs   mail inbox "), .command(.tabs, argument: "mail inbox"))
        XCTAssertEqual(SlashParse.parse("/save Morning reading"), .command(.save, argument: "Morning reading"))
        XCTAssertEqual(SlashParse.parse("/f invoice"), .command(.find, argument: "invoice"))
        XCTAssertEqual(SlashParse.parse("/ws Work"), .command(.workspace, argument: "Work"))
        XCTAssertEqual(SlashParse.parse("/private"), .command(.privateTab, argument: ""))
        XCTAssertEqual(SlashParse.parse("/SLEEP"), .command(.sleep, argument: ""))
    }

    func testEveryCommandHasUsageAndAUniqueName() {
        XCTAssertEqual(Set(SlashCommand.allCases.map(\.rawValue)).count, SlashCommand.allCases.count)
        for c in SlashCommand.allCases { XCTAssertTrue(c.usage.hasPrefix("/" + c.rawValue)); XCTAssertFalse(c.summary.isEmpty) }
    }

    func testTabMatchingNeedsEveryWordInTheTitleOrAddress() {
        XCTAssertTrue(TabMatch.matches(title: "Inbox (3) - Mail", url: "https://mail.example.test/u/0", words: "mail inbox"))
        XCTAssertTrue(TabMatch.matches(title: "x", url: "https://docs.example.test/", words: "DOCS"))
        XCTAssertFalse(TabMatch.matches(title: "Inbox", url: "https://a.test", words: "inbox calendar"))
        XCTAssertTrue(TabMatch.matches(title: "anything", url: "", words: ""))
    }

    func testASnippetShowsTheWordWithItsSurroundings() {
        let text = String(repeating: "lorem ", count: 40) + "the INVOICE number is 42" + String(repeating: " ipsum", count: 40)
        let snippet = try? XCTUnwrap(TextSnippet.make(in: text, around: "invoice"))
        XCTAssertTrue(snippet?.contains("INVOICE number") == true)
        XCTAssertTrue(snippet?.hasPrefix("…") == true); XCTAssertTrue(snippet?.hasSuffix("…") == true)
        XCTAssertNil(TextSnippet.make(in: "nothing here", around: "invoice"))
        XCTAssertEqual(TextSnippet.make(in: "café menu", around: "cafe"), "café menu", "accents do not stop a match")
    }
}

@MainActor
final class SlashModelTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-slash-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    func testCommandsBecomeRowsThatDoTheirJobAndOtherTextIsLeftAlone() async throws {
        let m = await model()
        XCTAssertNil(m.slashSuggestions(for: "swift"), "ordinary text is not touched")
        let mail = m.openTab(url: URL(string: "http://127.0.0.1:18765/"), isPrivate: false)
        mail.engine.showHTML("<html><head><title>Inbox mail</title></head><body>hello</body></html>", baseURL: URL(string: "https://mail.example.test/"))
        try await Task.sleep(for: .seconds(1))
        _ = m.openTab(url: nil, isPrivate: false)
        let rows = try XCTUnwrap(m.slashSuggestions(for: "/tabs mail"))
        XCTAssertEqual(rows.first?.kind, .openTab)
        XCTAssertEqual(rows.first?.tabID, mail.id)
        let close = try XCTUnwrap(m.slashSuggestions(for: "/close mail")).first
        XCTAssertTrue(close?.title.hasPrefix("Close 1 tab") == true)
        let before = m.tabs.count
        close?.action?()
        XCTAssertEqual(m.tabs.count, before - 1, "the command closed the matching tab")
        let list = try XCTUnwrap(m.slashSuggestions(for: "/"))
        XCTAssertEqual(list.count, SlashCommand.allCases.count)
        XCTAssertTrue(list.allSatisfy { $0.target.hasPrefix("slash:") })
    }

    func testSavingAndOpeningASessionFromTheBar() async throws {
        let m = await model()
        _ = m.openTab(url: URL(string: "https://one.example.test/"), isPrivate: false)
        try await Task.sleep(for: .milliseconds(300))
        try XCTUnwrap(m.slashSuggestions(for: "/save Morning")).first?.action?()
        XCTAssertEqual(m.savedSessions.first?.name, "Morning")
        let rows = try XCTUnwrap(m.slashSuggestions(for: "/open morn"))
        XCTAssertEqual(rows.first?.title, "Open “Morning”")
    }

    func testFindingTextInTabsIncludesTabsThatAreAsleepByTheirTitle() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><head><title>Quarterly report</title></head><body>The figure is 1,234 dollars.</body></html>", baseURL: URL(string: "https://report.example.test/"))
        try await Task.sleep(for: .seconds(1.5))
        _ = m.openTab(url: nil, isPrivate: false)
        let live = await m.searchTabText("dollars")
        XCTAssertEqual(live.first?.tabID, tab.id)
        XCTAssertTrue(live.first?.snippet.contains("1,234 dollars") == true)
        XCTAssertEqual(live.first?.asleep, false)
        let none = await m.searchTabText("zzzqqq")
        XCTAssertTrue(none.isEmpty)
        let short = await m.searchTabText("d")
        XCTAssertTrue(short.isEmpty, "one letter is not a search")
    }
}

final class SelectionSearchTests: XCTestCase {
    func testEnginesCoverPresetsKeywordsAndYourOwnWithoutRepeats() {
        let list = SelectionSearch.engines(custom: ["wiki2": "https://wiki.example.test/?q={}", "bad": "http://insecure.test/{}", "twice": "https://www.google.com/search?q={}"])
        XCTAssertTrue(list.contains { $0.name == "Google" })
        XCTAssertTrue(list.contains { $0.name == "GitHub" })
        XCTAssertTrue(list.contains { $0.name == "wiki2" })
        XCTAssertFalse(list.contains { $0.name == "bad" }, "an engine that is not https is left out")
        XCTAssertEqual(list.filter { $0.template == "https://www.google.com/search?q={}" }.count, 1)
    }

    func testSelectedWordsBecomeOneSafeQueryValue() {
        let url = SelectionSearch.url(for: "  rust &  swift=fast#x?\nnew line ", template: "https://s.test/?q={}")
        XCTAssertEqual(url?.absoluteString, "https://s.test/?q=rust%20%26%20swift%3Dfast%23x%3F%20new%20line")
        XCTAssertNil(SelectionSearch.url(for: "   ", template: "https://s.test/?q={}"))
        XCTAssertNil(SelectionSearch.url(for: "x", template: "https://s.test/"), "a template with no place for the words is refused")
        XCTAssertEqual(SelectionSearch.url(for: String(repeating: "a", count: 1000), template: "https://s.test/?q={}")?.absoluteString.count, "https://s.test/?q=".count + 300)
    }
}
