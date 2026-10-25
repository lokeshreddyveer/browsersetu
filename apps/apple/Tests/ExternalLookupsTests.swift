import XCTest
@testable import Browser_Setu

final class ExternalLookupsTests: XCTestCase {
    // MARK: what may be sent

    func testOnlyPublicAddressesAreEverSent() {
        for host in ["example.com", "www.bbc.co.uk", "a-b.example.org", "1.1.1.1", "8.8.4.4"] { XCTAssertTrue(PublicAddress.isPublicHost(host), host) }
        for host in ["localhost", "router", "nas.local", "printer.lan", "intranet.corp", "wiki.internal", "10.0.0.5", "192.168.1.1", "172.16.0.9", "172.31.255.1", "127.0.0.1",
                     "169.254.1.1", "100.64.0.1", "0.0.0.0", "[::1]", "::1", "", "999.1.1.1", "exa mple.com", "home.arpa", "x.test"] {
            XCTAssertFalse(PublicAddress.isPublicHost(host), host)
        }
        XCTAssertTrue(PublicAddress.isPublicWeb(URL(string: "https://example.com/a")))
        XCTAssertFalse(PublicAddress.isPublicWeb(URL(string: "ftp://example.com")))
        XCTAssertFalse(PublicAddress.isPublicWeb(URL(string: "https://192.168.0.1/admin")))
        XCTAssertFalse(PublicAddress.isPublicWeb(nil))
    }

    // MARK: saved copy

    func testTheArchiveQuestionCarriesNoQueryFragmentOrSignIn() throws {
        let ask = try XCTUnwrap(Wayback.lookupURL(for: URL(string: "https://user:pw@Example.com/a/b?token=SECRET&q=private#frag")!))
        let text = ask.absoluteString
        XCTAssertTrue(text.hasPrefix("https://archive.org/wayback/available?url="))
        for leaked in ["SECRET", "private", "frag", "pw", "user"] { XCTAssertFalse(text.contains(leaked), leaked) }
        XCTAssertTrue(text.contains("Example.com") || text.lowercased().contains("example.com"))
        XCTAssertNil(Wayback.lookupURL(for: URL(string: "http://192.168.1.4/router")!), "a private address is never sent")
        XCTAssertNil(Wayback.lookupURL(for: URL(string: "file:///etc/passwd")!))
    }

    func testReadsTheClosestCopyOnlyIfItIsOnTheArchive() throws {
        let good = Data(#"{"url":"example.com","archived_snapshots":{"closest":{"status":"200","available":true,"url":"http://web.archive.org/web/20231105121314/http://example.com/","timestamp":"20231105121314"}}}"#.utf8)
        let found = try XCTUnwrap(Wayback.snapshot(from: good))
        XCTAssertEqual(found.url.absoluteString, "https://web.archive.org/web/20231105121314/http://example.com/", "http is upgraded to https")
        XCTAssertNotNil(found.date)
        let none = Data(#"{"url":"example.com","archived_snapshots":{}}"#.utf8)
        XCTAssertNil(Wayback.snapshot(from: none))
        let unavailable = Data(#"{"archived_snapshots":{"closest":{"available":false,"url":"http://web.archive.org/x"}}}"#.utf8)
        XCTAssertNil(Wayback.snapshot(from: unavailable))
        // An answer pointing anywhere else is refused: the page it names would be opened in the tab.
        let hijack = Data(#"{"archived_snapshots":{"closest":{"available":true,"url":"https://evil.example/web.archive.org/","timestamp":"20231105121314"}}}"#.utf8)
        XCTAssertNil(Wayback.snapshot(from: hijack))
        let other = Data(#"{"archived_snapshots":{"closest":{"available":true,"url":"https://web.archive.org.evil.example/x","timestamp":"1"}}}"#.utf8)
        XCTAssertNil(Wayback.snapshot(from: other))
        XCTAssertNil(Wayback.snapshot(from: Data("not json".utf8)))
        XCTAssertNil(Wayback.date(fromTimestamp: "2023"))
    }

    func testTheErrorPageOffersTheLinkOnlyWhenAsked() {
        XCTAssertFalse(ErrorPage.html(title: "t", detail: "d").contains("savedcopy"))
        let page = ErrorPage.html(title: "t", detail: "d", offersSavedCopy: true)
        XCTAssertTrue(page.contains("browsersetu://savedcopy"))
        XCTAssertFalse(page.contains("http"), "the link carries no address")
    }

    // MARK: security headers

    func testTheScanSendsOnlyTheHostAndReadsTheGrade() throws {
        let request = try XCTUnwrap(SiteScan.request(host: "Example.com"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://observatory-api.mdn.mozilla.net/api/v2/scan?host=example.com")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(SiteScan.request(host: "192.168.0.1"))
        XCTAssertNil(SiteScan.request(host: "intranet"))
        let answer = Data(#"{"id":1,"details_url":"https://developer.mozilla.org/en-US/observatory/analyze?host=example.com","algorithm_version":6,"error":null,"grade":"B+","score":75,"status_code":200,"tests_failed":3,"tests_passed":9,"tests_quantity":12}"#.utf8)
        let result = try XCTUnwrap(SiteScan.parse(answer))
        XCTAssertEqual(result, SiteScan.Result(grade: "B+", score: 75, passed: 9, failed: 3, total: 12, details: URL(string: "https://developer.mozilla.org/en-US/observatory/analyze?host=example.com")))
        // A details link that leaves Mozilla's site is dropped.
        let odd = Data(#"{"error":null,"grade":"A","score":100,"details_url":"https://evil.example/x","tests_failed":0,"tests_passed":12,"tests_quantity":12}"#.utf8)
        XCTAssertNil(try XCTUnwrap(SiteScan.parse(odd)).details)
        // An error answer is not a grade.
        let failure = Data(#"{"error":"invalid-hostname-lookup","message":"example.invalid cannot be resolved"}"#.utf8)
        XCTAssertNil(SiteScan.parse(failure))
        XCTAssertEqual(SiteScan.errorMessage(failure), "example.invalid cannot be resolved")
    }

    // MARK: currency

    func testAmountsAreFoundInTheWaysPeopleWriteThem() {
        func codes(_ text: String) -> [String] { Currency.amounts(in: text).map { "\($0.value) \($0.code)" } }
        XCTAssertEqual(codes("It costs $250 today"), ["250.0 USD"])
        XCTAssertEqual(codes("€40"), ["40.0 EUR"])
        XCTAssertEqual(codes("₹1,200.50"), ["1200.5 INR"])
        XCTAssertEqual(codes("£3.5 and ¥1,000"), ["3.5 GBP", "1000.0 JPY"])
        XCTAssertEqual(codes("USD 250"), ["250.0 USD"])
        XCTAssertEqual(codes("1,299.99 EUR"), ["1299.99 EUR"])
        XCTAssertEqual(codes("40 €"), ["40.0 EUR"])
        XCTAssertEqual(codes("R$ 99"), ["99.0 BRL"])
        XCTAssertEqual(codes("A$ 12"), ["12.0 AUD"])
        XCTAssertEqual(codes("1 234 EUR").first, "1234.0 EUR", "a space as the thousands mark")
        XCTAssertTrue(codes("in 2024 250 EUR").contains("250.0 EUR"), "a number does not start in the middle of another")
        XCTAssertFalse(codes("in 2024 250 EUR").contains("24250.0 EUR"))
        XCTAssertEqual(codes("no money here, 5 km and 20 degrees"), [])
        XCTAssertEqual(codes("250 RUB"), [], "the central bank publishes no rate for it")
        XCTAssertLessThanOrEqual(Currency.amounts(in: "$1 $2 $3 $4 $5 $6 $7 $8").count, 5)
        XCTAssertEqual(Currency.amounts(in: "$5 and $5").count, 1, "no repeats")
    }

    func testTheRateRequestCarriesOnlyCodes() throws {
        let request = try XCTUnwrap(Currency.request(from: "USD", to: ["INR", "EUR"]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.frankfurter.dev/v1/latest?base=USD&symbols=INR,EUR")
        XCTAssertNil(Currency.request(from: "RUB", to: ["USD"]))
        XCTAssertNil(Currency.request(from: "USD", to: []))
        XCTAssertNil(Currency.request(from: "USD", to: ["XXX"]))
        let amount = Currency.Amount(value: 10, code: "USD", source: "$10")
        let targets = Currency.targets(for: amount, locale: Locale(identifier: "en_IN"))
        XCTAssertEqual(targets, ["INR", "EUR"], "own currency first, never the amount's own")
        XCTAssertFalse(Currency.targets(for: Currency.Amount(value: 1, code: "EUR", source: "€1"), locale: Locale(identifier: "de_DE")).contains("EUR"))
    }

    func testRatesAreReadAndUnknownOnesIgnored() throws {
        let answer = Data(#"{"amount":1.0,"base":"USD","date":"2026-10-23","rates":{"EUR":0.89342,"INR":94.94,"ZZZ":3}}"#.utf8)
        let read = try XCTUnwrap(Currency.rates(from: answer))
        XCTAssertEqual(read.date, "2026-10-23")
        XCTAssertEqual(read.rates["INR"] ?? 0, 94.94, accuracy: 0.001)
        XCTAssertNil(read.rates["ZZZ"])
        XCTAssertNil(Currency.rates(from: Data(#"{"rates":{}}"#.utf8)))
        XCTAssertNil(Currency.rates(from: Data("nope".utf8)))
        XCTAssertEqual(Currency.format(1234.5, code: "USD", locale: Locale(identifier: "en_US")), "$1,234.50")
        XCTAssertEqual(Currency.format(1234.6, code: "JPY", locale: Locale(identifier: "en_US")), "¥1,235")
    }

    // MARK: DOI and citations

    func testFindingADOI() {
        XCTAssertEqual(DOI.find(in: ["https://doi.org/10.1038/nature12373"]), "10.1038/nature12373")
        XCTAssertEqual(DOI.find(in: ["Nothing", "see (doi: 10.1000/xyz123)."]), "10.1000/xyz123")
        XCTAssertEqual(DOI.find(in: ["https://example.com/a?doi=10.1016%2Fj.cell.2020.01.001&x=1"]), "10.1016/j.cell.2020.01.001", "stops at the next query part")
        XCTAssertEqual(DOI.find(in: ["https://doi.org/10.1038/nature12373."]), "10.1038/nature12373", "trailing full stop removed")
        XCTAssertNil(DOI.find(in: ["no doi here", "version 10.5 of something", ""]))
    }

    private let nature = """
    {"status":"ok","message":{"DOI":"10.1038/nature12373","type":"journal-article","title":["Nanometre-scale thermometry in a <i>living</i> cell"],"container-title":["Nature"],
     "volume":"500","issue":"7460","page":"54-58","issued":{"date-parts":[[2013,7,31]]},
     "author":[{"given":"G.","family":"Kucsko","sequence":"first"},{"given":"P. C.","family":"Maurer","sequence":"additional"},{"given":"Nathalie Yu-Ling","family":"Yao","sequence":"additional"}]}}
    """

    func testReadingAWorkFromCrossref() throws {
        let work = try XCTUnwrap(Crossref.work(from: Data(nature.utf8)))
        XCTAssertEqual(work.title, "Nanometre-scale thermometry in a living cell", "markup removed")
        XCTAssertEqual(work.year, "2013")
        XCTAssertEqual(work.authors.count, 3)
        XCTAssertNil(Crossref.work(from: Data(#"{"message":{"DOI":"10.1/x"}}"#.utf8)), "no title")
        XCTAssertNil(Crossref.work(from: Data("nope".utf8)))
        XCTAssertEqual(Crossref.request(doi: "10.1038/nature12373")?.url?.absoluteString, "https://api.crossref.org/works/10.1038/nature12373")
        XCTAssertNil(Crossref.request(doi: "not a doi"))
        XCTAssertNil(Crossref.request(doi: "10.1038/x?y=1#z "), "only a clean DOI is put in the address")
    }

    func testTheThreeReferenceStyles() throws {
        let work = try XCTUnwrap(Crossref.work(from: Data(nature.utf8)))
        XCTAssertEqual(Crossref.format(work, style: .apa),
                       "Kucsko, G., Maurer, P. C., & Yao, N. Y.-L. (2013). Nanometre-scale thermometry in a living cell. Nature, 500(7460), 54-58. https://doi.org/10.1038/nature12373")
        XCTAssertEqual(Crossref.format(work, style: .mla),
                       "Kucsko, G., et al. “Nanometre-scale thermometry in a living cell.” Nature, vol. 500, no. 7460, 2013, pp. 54-58, https://doi.org/10.1038/nature12373.")
        XCTAssertEqual(Crossref.format(work, style: .plain),
                       "G. Kucsko, P. C. Maurer, Nathalie Yu-Ling Yao — Nanometre-scale thermometry in a living cell — Nature, 2013 — https://doi.org/10.1038/nature12373")
    }

    func testReferencesCopeWithMissingParts() {
        let bare = Crossref.Work(title: "A short note", authors: [], container: "", year: "n.d.", volume: "", issue: "", pages: "", doi: "10.1/abc")
        XCTAssertEqual(Crossref.format(bare, style: .apa), "(n.d.). A short note. https://doi.org/10.1/abc")
        let one = Crossref.Work(title: "Why?", authors: [.init(given: "Ada", family: "Lovelace", organisation: "")], container: "Notes", year: "1843", volume: "", issue: "", pages: "7", doi: "10.1/abc")
        XCTAssertEqual(Crossref.format(one, style: .apa), "Lovelace, A. (1843). Why? Notes, 7. https://doi.org/10.1/abc")
        XCTAssertEqual(Crossref.format(one, style: .mla), "Lovelace, Ada. “Why?” Notes, 1843, p. 7, https://doi.org/10.1/abc.")
        let org = Crossref.Work(title: "Report", authors: [.init(given: "", family: "", organisation: "World Health Organization")], container: "", year: "2020", volume: "", issue: "", pages: "", doi: "10.1/abc")
        XCTAssertTrue(Crossref.format(org, style: .apa).hasPrefix("World Health Organization. (2020)."))
    }
}
