import WebKit
import XCTest
@testable import Browser_Setu

final class PrivacyBatchTests: XCTestCase {
    // MARK: Debouncing

    func testRedirectPagesLeadToTheirDestination() {
        let cases: [(String, String)] = [
            ("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&h=AT0", "https://example.com/a?b=1"),
            ("https://l.instagram.com/?u=https%3A%2F%2Fexample.org%2F&e=x", "https://example.org/"),
            ("https://www.google.com/url?sa=t&url=https%3A%2F%2Fexample.net%2Fp&q=", "https://example.net/p"),
            ("https://www.youtube.com/redirect?event=video&q=https%3A%2F%2Fexample.io%2F", "https://example.io/"),
            ("https://out.reddit.com/t3_abc?url=https%3A%2F%2Fexample.dev%2Fx", "https://example.dev/x"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(LinkDebouncer.destination(for: URL(string: input)!)?.absoluteString, expected, input)
        }
    }

    func testOrdinaryLinksAndOddDestinationsAreLeftAlone() {
        for input in ["https://www.google.com/search?q=cats", "https://www.google.com/url?q=javascript:alert(1)", "https://www.google.com/url?q=https://www.google.com/maps",
                      "https://l.facebook.com/other?u=https%3A%2F%2Fexample.com", "http://example.com/l.php?u=https%3A%2F%2Fx.com", "https://www.youtube.com/watch?v=abc"] {
            XCTAssertNil(LinkDebouncer.destination(for: URL(string: input)!), input)
        }
    }

    // MARK: Tracking parameters

    func testNewTrackingParametersAreRemovedAndRealOnesKept() {
        let url = URL(string: "https://shop.example/item?id=7&_gl=1*abc&gad_source=1&igsh=xyz&pf_rd_r=Q&color=red")!
        XCTAssertEqual(TrackingParameters.clean(url)?.absoluteString, "https://shop.example/item?id=7&color=red")
    }

    // MARK: Extra rules

    func testNoSwitchOnMeansNoRules() {
        XCTAssertNil(ExtraRules.json(for: WebPolicy()))
    }

    func testLocalNetworkRulesAreValidJSONAndCarryTheAllowedSites() throws {
        var policy = WebPolicy()
        policy.blockLocalNetwork = true
        policy.localNetworkAllowed = ["plex.example"]
        let text = try XCTUnwrap(ExtraRules.json(for: policy))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(text.contains("plex\\\\.example"), "an allowed site is an exception")
        XCTAssertTrue(text.contains("192\\\\.168"))
    }

    /// WebKit itself must accept every list: a pattern it cannot compile would silently leave the switch doing nothing.
    @MainActor func testWebKitCompilesEveryRuleList() async throws {
        var policy = WebPolicy()
        policy.blockLocalNetwork = true
        policy.localNetworkAllowed = ["plex.example", "nas.home"]
        policy.blockGoogleServices = true
        policy.blockSocialWidgets = true
        let text = try XCTUnwrap(ExtraRules.json(for: policy))
        let store = WKContentRuleListStore.default()!
        let identifier = "bs-extra-test-\(UUID().uuidString)"
        let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text)
        XCTAssertNotNil(compiled)
        try await store.removeContentRuleList(forIdentifier: identifier)
    }

    // MARK: Presets

    @MainActor func testPresetsRoundTripAndCustomIsRecognised() throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pb-\(UUID().uuidString)", profile: "default")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: model.root) }
        for preset in PrivacyPreset.allCases {
            preset.apply(to: model)
            XCTAssertEqual(PrivacyPreset.current(for: model), preset)
        }
        PrivacyPreset.paranoid.apply(to: model)
        model.blockGoogleServices = false
        model.blockWebRTC = false
        XCTAssertNil(PrivacyPreset.current(for: model), "a mix that matches no preset is Custom")
    }

    // MARK: Feeds

    func testFeedDiscoveryFindsAdvertisedFeedsOnly() {
        let html = """
        <html><head><title>x</title>
        <link rel="stylesheet" href="/a.css">
        <link rel="alternate" type="application/rss+xml" title="Posts &amp; more" href="/feed.xml">
        <link rel='alternate' type='application/atom+xml' href='https://example.com/atom'>
        <link rel="alternate" type="application/rss+xml" href="http://insecure.example/feed">
        <link rel="alternate" hreflang="fr" href="/fr">
        </head><body><link rel="alternate" type="application/rss+xml" href="/in-body"></body></html>
        """
        let found = FeedDiscovery.feeds(inHTML: html, baseURL: URL(string: "https://example.com/blog/"))
        XCTAssertEqual(found.map(\.url), ["https://example.com/feed.xml", "https://example.com/atom"])
        XCTAssertEqual(found.first?.title, "Posts & more")
    }

    func testOPMLRoundTrip() {
        let feeds = [Feed(url: "https://a.example/feed", title: "A & B"), Feed(url: "https://c.example/rss?x=1&y=2", title: "C \"quoted\"")]
        let parsed = OPML.parse(Data(OPML.export(feeds).utf8))
        XCTAssertEqual(parsed.map(\.url), feeds.map(\.url))
        XCTAssertEqual(parsed.map(\.title), feeds.map(\.title))
    }

    func testOPMLFromOtherReadersWithNestedFolders() {
        let xml = """
        <?xml version="1.0"?><opml version="1.0"><body>
        <outline text="News"><outline type="rss" text="One" xmlUrl="https://one.example/rss"/><outline text="Not a feed"/></outline>
        </body></opml>
        """
        XCTAssertEqual(OPML.parse(Data(xml.utf8)).map(\.url), ["https://one.example/rss"])
    }

    // MARK: Address bar

    func testControlReturnCompletesOnlyABareWord() {
        XCTAssertEqual(AddressShortcut.dotCom("apple"), "www.apple.com")
        XCTAssertEqual(AddressShortcut.dotCom("  GitHub \n"), "www.github.com")
        XCTAssertEqual(AddressShortcut.dotCom("my-site"), "www.my-site.com")
        for notAWord in ["", "apple.com", "two words", "https://a", "a/b", "a:80", "-bad", "bad-", "q?x", String(repeating: "a", count: 64)] {
            XCTAssertNil(AddressShortcut.dotCom(notAWord), notAWord)
        }
    }

    // MARK: Scripts

    func testPageScriptsAreWellFormed() {
        for script in [PageScripts.globalPrivacyControl, PageScripts.noLinkPings] {
            XCTAssertTrue(script.contains("(function () {"))
            XCTAssertTrue(script.hasSuffix("})();"))
        }
    }
}
