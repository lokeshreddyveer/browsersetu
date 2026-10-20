import XCTest
@testable import Browser_Setu

final class ToolkitFeaturesTests: XCTestCase {
    func testRSSIsParsedWithMarkupRemovedAndBadLinksSkipped() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Example Blog</title>
        <item><title>First &amp; best</title><link>https://example.com/1</link><description><![CDATA[<p>Hello <b>world</b></p>]]></description><pubDate>Mon, 19 Oct 2026 10:00:00 +0000</pubDate></item>
        <item><title>No link</title></item>
        <item><title>Bad scheme</title><link>javascript:alert(1)</link></item>
        <item><title>Second</title><link>https://example.com/2</link></item>
        </channel></rss>
        """
        let r = FeedParser.parse(Data(xml.utf8), feedURL: "https://example.com/feed")
        XCTAssertEqual(r.title, "Example Blog")
        XCTAssertEqual(r.items.map(\.link), ["https://example.com/1", "https://example.com/2"])
        XCTAssertEqual(r.items[0].title, "First & best")
        XCTAssertEqual(r.items[0].summary, "Hello world")
        XCTAssertNotNil(r.items[0].date)
        XCTAssertEqual(r.items[0].feed, "https://example.com/feed")
    }

    func testAtomIsParsed() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Site</title>
        <entry><title>Entry</title><link rel="alternate" href="https://atom.test/a"/><link rel="edit" href="https://atom.test/edit"/><updated>2026-10-19T09:00:00Z</updated><summary>Short</summary></entry></feed>
        """
        let r = FeedParser.parse(Data(xml.utf8), feedURL: "f")
        XCTAssertEqual(r.title, "Atom Site")
        XCTAssertEqual(r.items.first?.link, "https://atom.test/a")
        XCTAssertNotNil(r.items.first?.date)
    }

    func testNonFeedGivesNothing() {
        XCTAssertTrue(FeedParser.parse(Data("<html><body>hi</body></html>".utf8), feedURL: "f").items.isEmpty)
        XCTAssertTrue(FeedParser.parse(Data("not xml".utf8), feedURL: "f").items.isEmpty)
    }

    func testFeedAddressChecks() {
        XCTAssertEqual(FeedFetcher.valid("example.com/feed")?.absoluteString, "https://example.com/feed")
        XCTAssertNil(FeedFetcher.valid("http://example.com/feed"))
        XCTAssertNil(FeedFetcher.valid("a b"))
        XCTAssertNil(FeedFetcher.valid("localhost"))
    }

    func testSiteTimeAddsPrunesAndRanks() {
        var log = SiteTimeLog()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        log.add(seconds: 30, host: "a.com", on: base); log.add(seconds: 90, host: "b.com", on: base); log.add(seconds: 10, host: "a.com", on: base)
        log.add(seconds: 500, host: "x.com", on: base)   // more than a tick can be: ignored
        XCTAssertEqual(log.sites(on: base).map(\.host), ["b.com", "a.com"])
        XCTAssertEqual(log.total(on: base), 130)
        for d in 1...40 { log.add(seconds: 5, host: "c.com", on: base.addingTimeInterval(Double(d) * 86_400)) }
        XCTAssertLessThanOrEqual(log.days.count, SiteTimeLog.keepDays)
        XCTAssertEqual(SiteTimeLog.clock(0), "0 min")
        XCTAssertEqual(SiteTimeLog.clock(30), "1 min")
        XCTAssertEqual(SiteTimeLog.clock(4000), "1 h 7 min")
    }

    func testClipboardHistoryDedupesCapsAndExpires() {
        let now = Date()
        var list = ClipboardRules.adding("one", to: [], now: now, keepFor: 3600)
        list = ClipboardRules.adding("two", to: list, now: now, keepFor: 3600)
        list = ClipboardRules.adding("one", to: list, now: now, keepFor: 3600)
        XCTAssertEqual(list.map(\.text), ["one", "two"])
        XCTAssertEqual(ClipboardRules.adding("  ", to: list, now: now, keepFor: 3600), list)
        for i in 0..<50 { list = ClipboardRules.adding("t\(i)", to: list, now: now, keepFor: 3600) }
        XCTAssertEqual(list.count, ClipboardRules.limit)
        XCTAssertTrue(ClipboardRules.expired(list, now: now.addingTimeInterval(7200), keepFor: 3600).isEmpty)
    }

    func testAskPromptHasTheQuestionAndTheTrimmedPage() {
        let p = PageAsk.prompt(question: "  Who wrote it? ", title: "T", text: String(repeating: "word ", count: 5000))
        XCTAssertTrue(p.hasPrefix("Question: Who wrote it?"))
        XCTAssertLessThan(p.count, PageSummary.characterLimit + 200)
    }
}

final class MoreToolsTests: XCTestCase {
    func testTOTPMatchesTheRFC6238Vectors() {
        // RFC 6238 appendix B, SHA-1, secret "12345678901234567890", 8 digits.
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 8), "94287082")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 1111111109), digits: 8), "07081804")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 20000000000), digits: 8), "65353130")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59))?.count, 6)
    }

    func testSecretsAreReadFromTextAndLinks() {
        XCTAssertNotNil(TOTP.secret(from: "gezd gnbv-gy3t qojq"))
        XCTAssertEqual(TOTP.secret(from: "otpauth://totp/Example:me?secret=GEZDGNBVGY3TQOJQ&issuer=Example"), "GEZDGNBVGY3TQOJQ")
        XCTAssertNil(TOTP.secret(from: "not a secret!"))
        XCTAssertNil(TOTP.code(secret: "1", at: Date()))
        XCTAssertTrue((1...30).contains(TOTP.secondsLeft()))
    }

    func testWebArchiveTextAndSnippet() throws {
        let html = "<html><head><style>p{color:red}</style><script>var secret=1</script></head><body><p>Bees make honey in the hive.</p></body></html>"
        let archive: [String: Any] = ["WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceURL": "https://x.test", "WebResourceMIMEType": "text/html"]]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).webarchive")
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = WebArchiveText.extract(from: url)
        XCTAssertTrue(text.contains("Bees make honey"))
        XCTAssertFalse(text.contains("secret=1")); XCTAssertFalse(text.contains("color:red"))
        XCTAssertTrue(WebArchiveText.snippet(in: text, for: "HONEY")?.contains("honey") ?? false)
        XCTAssertNil(WebArchiveText.snippet(in: text, for: "zebra"))
        XCTAssertEqual(WebArchiveText.extract(from: URL(fileURLWithPath: "/nonexistent")), "")
    }
}
