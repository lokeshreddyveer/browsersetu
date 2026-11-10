import XCTest
@testable import Browser_Setu

/// Defects found by reading every file once more, each pinned by a test.
final class ReviewFixesRound2Tests: XCTestCase {
    func testACredentialIsWrittenToACSVExactlyAsItIs() {
        XCTAssertEqual(CSV.field("-Xk3=ab", guardFormula: false), "-Xk3=ab", "an apostrophe in front would turn it into a different password")
        XCTAssertEqual(CSV.field("@pass", guardFormula: false), "@pass")
        XCTAssertEqual(CSV.field("=cmd"), "'=cmd", "a text column that looks like a formula is still made harmless")
        XCTAssertEqual(CSV.field("a,b", guardFormula: false), "\"a,b\"", "quoting still applies")
    }

    func testPreviewImagesAreOnlyFetchedFromTheOpenInternet() {
        XCTAssertNotNil(PreviewImageRules.allowed("https://example.com/a.png"))
        XCTAssertNil(PreviewImageRules.allowed("file:///etc/passwd"))
        XCTAssertNil(PreviewImageRules.allowed("http://127.0.0.1/x.png"))
        XCTAssertNil(PreviewImageRules.allowed("http://192.168.1.10/x.png"))
        XCTAssertNil(PreviewImageRules.allowed("http://10.0.0.5/x.png"))
        XCTAssertNil(PreviewImageRules.allowed("http://172.20.1.1/x.png"))
        XCTAssertNil(PreviewImageRules.allowed("http://printer.local/x.png"))
        XCTAssertNil(PreviewImageRules.allowed("http://[::1]/x.png"))
        XCTAssertNotNil(PreviewImageRules.allowed("http://172.32.1.1/x.png"), "172.32 is outside the private range")
    }

    func testAnAddressCarryingASecretIsNeverCopiedToTheSearchableIndex() {
        XCTAssertTrue(PageIndexRules.shouldIndex(URL(string: "https://example.com/article?id=5")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://example.com/article?token=abc")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://example.com/p?code=xyz&state=1")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://example.com/p?session_id=1")!, excludedHosts: []))
    }

    func testHiddenTagCharactersAreRemovedBeforeTextGoesToAnAITool() {
        let hidden = String(String.UnicodeScalarView([Unicode.Scalar(0xE0069)!, Unicode.Scalar(0xE0067)!]))
        let text = AgentPolicy.prepare(pageText: "Hello\(hidden) world\u{FE0F}", limit: 100)
        XCTAssertFalse(text.unicodeScalars.contains { $0.value >= 0xE0000 || $0.value == 0xFE0F })
        XCTAssertTrue(text.contains("Hello"))
    }

    func testTheHistoryImportSurvivesNumbersThatWouldStopTheApp() throws {
        let json = #"[{"url":"https://a.com","title":"A","visit_count":9223372036854775807,"time_usec":1e300},{"url":"https://a.com","title":"A","visit_count":9223372036854775807,"time_usec":"nan"}]"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = HistoryImport.parse(json: data)
        XCTAssertEqual(parsed.count, 1, "two entries for one address are merged")
        XCTAssertLessThanOrEqual(parsed.first?.count ?? 0, 1_000_000)
    }
}

/// SearXNG as a search provider the person chooses.
@MainActor
final class SearXNGTests: XCTestCase {
    func testOnlyUsableInstanceAddressesAreAccepted() {
        XCTAssertEqual(SearXNG.normalizedInstance("search.example.org"), "https://search.example.org")
        XCTAssertEqual(SearXNG.normalizedInstance(" https://Search.Example.org/ "), "https://search.example.org")
        XCTAssertEqual(SearXNG.normalizedInstance("https://example.org/searxng/search"), "https://example.org/searxng")
        XCTAssertEqual(SearXNG.normalizedInstance("http://192.168.1.20:8080"), "http://192.168.1.20:8080", "a server in your own network may be http")
        XCTAssertEqual(SearXNG.normalizedInstance("http://localhost:8888/"), "http://localhost:8888")
        for bad in ["http://search.example.org", "https://user:pw@search.example.org", "https://search.example.org/?q=1", "https://search.example.org/#x", "ftp://search.example.org",
                    "https://nodots", "two words.org", "", "javascript:alert(1)"] {
            XCTAssertNil(SearXNG.normalizedInstance(bad), bad)
        }
        XCTAssertEqual(SearXNG.searchTemplate(forInstance: "https://s.example.org"), "https://s.example.org/search?q={}")
        XCTAssertNil(SearXNG.suggestionEndpoint(forInstance: "http://192.168.1.20:8080"), "suggestions are https only")
        XCTAssertEqual(SearXNG.suggestionEndpoint(forInstance: "https://s.example.org"), "https://s.example.org/autocompleter?q={}")
    }

    func testChoosingAnInstanceSetsTheProfilesSearchAndSuggestionsStayOffUntilAskedFor() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-searx-\(UUID().uuidString)", profile: "default")
        await m.start()
        XCTAssertFalse(m.useSearXNG(instance: "not an address"))
        XCTAssertTrue(m.useSearXNG(instance: "https://s.example.org"))
        XCTAssertEqual(m.searchTemplate, "https://s.example.org/search?q={}")
        XCTAssertFalse(m.searxngSuggestions, "off by default")
        XCTAssertNil(SearchSuggestions.endpoint(forSearchTemplate: m.searchTemplate), "so nothing is asked of the instance while typing")
        m.searxngSuggestions = true
        XCTAssertEqual(SearchSuggestions.endpoint(forSearchTemplate: m.searchTemplate), "https://s.example.org/autocompleter?q={}")
        XCTAssertNil(SearchSuggestions.endpoint(forSearchTemplate: "https://other.example/search?q={}"), "only that instance")
        m.searxngSuggestions = false
        XCTAssertNil(SearchSuggestions.endpoint(forSearchTemplate: m.searchTemplate))
        // A home server over http still searches.
        XCTAssertTrue(m.useSearXNG(instance: "http://192.168.1.20:8080"))
        if case .search(let url)? = resolveInput(input: "hello world", searchTemplate: m.searchTemplate) { XCTAssertTrue(url.hasPrefix("http://192.168.1.20:8080/search?q=hello"), url) }
        else { XCTFail("a search on the home server was not made") }
        XCTAssertFalse(SearXNG.privacyNote.isEmpty)
        XCTAssertTrue(SearXNG.privacyNote.contains("receives every search"))
    }
}
