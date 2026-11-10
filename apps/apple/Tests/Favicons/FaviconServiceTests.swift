import XCTest
@testable import Browser_Setu

final class FaviconServiceTests: XCTestCase {
    private var folders: [URL] = []
    private let clock = TestClock()

    override func tearDown() { folders.forEach { try? FileManager.default.removeItem(at: $0) }; folders = [] }

    private func service(_ fetcher: StubFetcher, directory: URL? = nil, budget: FaviconBudget = .standard, concurrent: Int = 3) -> FaviconService {
        let dir = directory ?? FaviconFixtures.temporaryFolder("service"); folders.append(dir)
        let clock = self.clock
        return FaviconService(directory: dir, budget: budget, fetcher: fetcher, maxConcurrentFetches: concurrent, now: { clock.now })
    }
    private func page(_ host: String) -> URL { URL(string: "https://\(host)/")! }
    private func declared(_ path: String, host: String, sizes: String = "64x64") -> [IconCandidate] {
        IconCandidateRanker.candidates(fromLinks: [["href": "https://\(host)\(path)", "rel": "icon", "sizes": sizes]], pageURL: page(host))
    }

    func testADeclaredIconIsFetchedStoredAndFound() async throws {
        let stub = StubFetcher(); await stub.set("https://a.example/i.png", .image())
        let s = service(stub)
        let result = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        XCTAssertEqual(result, .refreshed)
        let data = await s.lookup(IconKey(host: "a.example")!)
        XCTAssertEqual(data.flatMap(FaviconFixtures.pixelSize).map { [$0.0, $0.1] }, [64, 64])
        let seen = await stub.requestedURLs()
        XCTAssertEqual(seen, ["https://a.example/i.png"], "the first candidate worked, so nothing else was asked")
    }

    func testTheSitesDefaultIsUsedWhenThePageNamesNoIcon() async {
        let stub = StubFetcher(); await stub.set("https://b.example/favicon.ico", .image())
        let s = service(stub)
        let result = await s.resolve(pageURL: page("b.example"), declared: [])
        XCTAssertEqual(result, .refreshed)
        let seen = await stub.requestedURLs()
        XCTAssertEqual(seen, ["https://b.example/favicon.ico"])
    }

    func testAnIconIsStoredUnderTheSiteOfThePageThatNamedIt() async {
        let stub = StubFetcher(); await stub.set("https://cdn.example.net/i.png", .image())
        let s = service(stub)
        _ = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "cdn.example.net"))
        let a = await s.lookup(IconKey(host: "a.example")!), cdn = await s.lookup(IconKey(host: "cdn.example.net")!), other = await s.lookup(IconKey(host: "b.example")!)
        XCTAssertNotNil(a); XCTAssertNil(cdn, "the icon's own host is not a site the person visited"); XCTAssertNil(other)
    }

    func testConcurrentRequestsForOneSiteShareOneFetch() async {
        let stub = StubFetcher(); await stub.set("https://a.example/i.png", .image()); await stub.setDelay(.milliseconds(150))
        let s = service(stub)
        let results = await withTaskGroup(of: IconResolution.self) { group in
            for _ in 0..<12 { group.addTask { await s.resolve(pageURL: self.page("a.example"), declared: self.declared("/i.png", host: "a.example")) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 12)
        let count = await stub.requestedURLs().count
        XCTAssertEqual(count, 1, "twelve requests for the same site made one network request")
    }

    func testAFreshIconIsNotFetchedAgain() async {
        let stub = StubFetcher(); await stub.set("https://a.example/i.png", .image())
        let s = service(stub)
        _ = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        let again = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        XCTAssertEqual(again, .cached)
        let count = await stub.requestedURLs().count
        XCTAssertEqual(count, 1)
    }

    func testAnExpiredIconIsAskedAboutConditionallyAndCostsNoBodyWhenUnchanged() async {
        let stub = StubFetcher(); await stub.set("https://a.example/i.png", .image(etag: "\"v1\"", maxAge: 3_600))
        let s = service(stub)
        _ = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        clock.advance(7_200)
        let hints = IconCacheHints(etag: "\"v1\"", lastModified: nil, maxAge: 3_600)
        await stub.set("https://a.example/i.png", .notModified(hints))
        let result = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        XCTAssertEqual(result, .revalidated)
        let last = await stub.lastRequest()
        XCTAssertEqual(last?.etag, "\"v1\"", "the second request carried the validator")
        let fresh = await s.isFresh(IconKey(host: "a.example")!)
        XCTAssertTrue(fresh, "and a 304 made the icon fresh again")
    }

    func testASiteWithNoIconIsNotAskedAgainAtOnceAndTheWaitGrows() async {
        let stub = StubFetcher()   // everything fails with badStatus
        let s = service(stub)
        let first = await s.resolve(pageURL: page("none.example"), declared: [])
        XCTAssertEqual(first, .noIcon)
        let n1 = await stub.requestedURLs().count
        let again = await s.resolve(pageURL: page("none.example"), declared: [])
        XCTAssertEqual(again, .backedOff)
        let n2 = await stub.requestedURLs().count
        XCTAssertEqual(n2, n1, "no request while backed off")
        clock.advance(601)
        let third = await s.resolve(pageURL: page("none.example"), declared: [])
        XCTAssertEqual(third, .noIcon)
        clock.advance(601)
        let fourth = await s.resolve(pageURL: page("none.example"), declared: [])
        XCTAssertEqual(fourth, .backedOff, "the second wait is twenty minutes, not ten")
    }

    func testBeingOfflineIsNeverRememberedAgainstASite() async {
        let stub = StubFetcher(); await stub.setFallback(.failed(.offline))
        let s = service(stub)
        let first = await s.resolve(pageURL: page("a.example"), declared: [])
        XCTAssertEqual(first, .offline)
        await stub.set("https://a.example/favicon.ico", .image())
        let second = await s.resolve(pageURL: page("a.example"), declared: [])
        XCTAssertEqual(second, .refreshed, "no wait: the failure said nothing about the site")
    }

    func testAGoodIconKeepsBeingServedWhenItsRefreshFails() async {
        let stub = StubFetcher(); await stub.set("https://a.example/i.png", .image(maxAge: 3_600))
        let s = service(stub)
        _ = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        clock.advance(7_200)
        await stub.set("https://a.example/i.png", .failed(.badStatus)); await stub.set("https://a.example/favicon.ico", .failed(.badStatus))
        let result = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "a.example"))
        XCTAssertEqual(result, .staleKept)
        let data = await s.lookup(IconKey(host: "a.example")!)
        XCTAssertNotNil(data)
    }

    func testAnImageThatCannotBeDecodedMovesOnToTheNextCandidate() async {
        let stub = StubFetcher()
        await stub.set("https://a.example/bad.png", .image(Data("<html>not an icon, an error page with status 200</html>".utf8)))
        await stub.set("https://a.example/favicon.ico", .image())
        let s = service(stub)
        let result = await s.resolve(pageURL: page("a.example"), declared: declared("/bad.png", host: "a.example"))
        XCTAssertEqual(result, .refreshed)
        let seen = await stub.requestedURLs()
        XCTAssertEqual(seen, ["https://a.example/bad.png", "https://a.example/favicon.ico"])
    }

    func testNoMoreFetchesRunAtOnceThanTheBound() async {
        let stub = StubFetcher(); await stub.setFallback(.image()); await stub.setDelay(.milliseconds(120))
        let s = service(stub, concurrent: 2)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 { group.addTask { _ = await s.resolve(pageURL: self.page("s\(i).example"), declared: []) } }
        }
        let peak = await stub.peakConcurrent
        XCTAssertEqual(peak, 2)
        let stored = await s.recordCount
        XCTAssertEqual(stored, 8, "and none was lost waiting")
    }

    func testACancelledResolutionStoresNothing() async {
        let stub = StubFetcher(); await stub.setFallback(.image()); await stub.setDelay(.milliseconds(400))
        let s = service(stub)
        let task = Task { await s.resolve(pageURL: page("a.example"), declared: []) }
        try? await Task.sleep(for: .milliseconds(80))
        await s.cancel(host: "a.example")
        _ = await task.value
        let stored = await s.hasIcon(IconKey(host: "a.example")!)
        XCTAssertFalse(stored)
    }

    func testProfilesDoNotSeeEachOthersIcons() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let a = service(stub), b = service(stub)
        _ = await a.resolve(pageURL: page("private-looking.example"), declared: [])
        let inA = await a.hasIcon(IconKey(host: "private-looking.example")!), inB = await b.hasIcon(IconKey(host: "private-looking.example")!)
        XCTAssertTrue(inA); XCTAssertFalse(inB)
    }

    func testADarkVariantIsStoredAndServedForDarkAppearance() async throws {
        let stub = StubFetcher()
        await stub.set("https://a.example/l.png", .image(FaviconFixtures.png(width: 64, height: 64, red: 255)))
        await stub.set("https://a.example/d.png", .image(FaviconFixtures.png(width: 64, height: 64, red: 0)))
        let rows: [[String: Any]] = [["href": "https://a.example/l.png", "rel": "icon", "sizes": "64x64"],
                                     ["href": "https://a.example/d.png", "rel": "icon", "sizes": "64x64", "media": "(prefers-color-scheme: dark)"]]
        let s = service(stub)
        _ = await s.resolve(pageURL: page("a.example"), declared: IconCandidateRanker.candidates(fromLinks: rows, pageURL: page("a.example")))
        let light = await s.lookup(IconKey(host: "a.example")!, scheme: .light), dark = await s.lookup(IconKey(host: "a.example")!, scheme: .dark)
        XCTAssertNotNil(light); XCTAssertNotNil(dark); XCTAssertNotEqual(light, dark)
    }

    func testIconsComeBackAfterARestart() async {
        let dir = FaviconFixtures.temporaryFolder("restart")
        let stub = StubFetcher(); await stub.setFallback(.image())
        let first = service(stub, directory: dir)
        _ = await first.resolve(pageURL: page("a.example"), declared: [])
        await first.flush()
        let second = service(stub, directory: dir)
        let data = await second.lookup(IconKey(host: "a.example")!)
        XCTAssertNotNil(data, "a cold start finds what a warm one stored")
        let fresh = await second.isFresh(IconKey(host: "a.example")!)
        XCTAssertTrue(fresh)
    }

    func testRemovingASiteAndClearingForgetEverythingAboutIt() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let s = service(stub)
        for h in ["a.example", "b.example"] { _ = await s.resolve(pageURL: page(h), declared: []) }
        await s.remove(host: "a.example")
        let a = await s.hasIcon(IconKey(host: "a.example")!), b = await s.hasIcon(IconKey(host: "b.example")!)
        XCTAssertFalse(a); XCTAssertTrue(b)
        await s.clear()
        let count = await s.recordCount
        XCTAssertEqual(count, 0)
    }

    func testTheBudgetEvictsThroughTheService() async {
        let stub = StubFetcher()
        for i in 0..<5 { await stub.set("https://s\(i).example/favicon.ico", .image(FaviconFixtures.png(width: 64, height: 64, red: UInt8(i * 10)))) }
        let s = service(stub, budget: FaviconBudget(maxRecords: 3, maxBytes: .max), concurrent: 1)
        for i in 0..<5 { _ = await s.resolve(pageURL: page("s\(i).example"), declared: []); clock.advance(10) }
        let count = await s.recordCount
        XCTAssertEqual(count, 3)
        let oldest = await s.hasIcon(IconKey(host: "s0.example")!), newest = await s.hasIcon(IconKey(host: "s4.example")!)
        XCTAssertFalse(oldest); XCTAssertTrue(newest)
    }


    func testClearingWhileAFetchIsInFlightStoresNothingAndNothingComesBackAfterARestart() async {
        let dir = FaviconFixtures.temporaryFolder("clear-race")
        let stub = StubFetcher(); await stub.setFallback(.image()); await stub.setDelay(.milliseconds(300))
        let s = service(stub, directory: dir)
        let task = Task { await s.resolve(pageURL: page("a.example"), declared: []) }
        try? await Task.sleep(for: .milliseconds(100))
        await s.clear()
        let result = await task.value
        XCTAssertEqual(result, .noIcon)
        await s.flush()
        let again = service(stub, directory: dir)
        let found = await again.hasIcon(IconKey(host: "a.example")!)
        XCTAssertFalse(found, "an answer that arrived after the clear was not written")
    }

    func testRemovingASiteWhileItsFetchIsInFlightStoresNothing() async {
        let stub = StubFetcher(); await stub.setFallback(.image()); await stub.setDelay(.milliseconds(300))
        let s = service(stub)
        let task = Task { await s.resolve(pageURL: page("a.example"), declared: []) }
        try? await Task.sleep(for: .milliseconds(100))
        await s.remove(host: "a.example")
        _ = await task.value
        let found = await s.hasIcon(IconKey(host: "a.example")!)
        XCTAssertFalse(found)
    }

    func testAClosedServiceWritesNothingAndCannotRecreateAFolder() async {
        let dir = FaviconFixtures.temporaryFolder("closed")
        let stub = StubFetcher(); await stub.setFallback(.image())
        let s = service(stub, directory: dir)
        _ = await s.resolve(pageURL: page("a.example"), declared: [])
        await s.close()
        try? FileManager.default.removeItem(at: dir)           // the profile was deleted
        await s.flush()
        let later = await s.resolve(pageURL: page("b.example"), declared: [])
        await s.flush()
        XCTAssertEqual(later, .noIcon)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "a leaked flush must not bring a deleted profile's folder back")
    }

    func testCreatingAServiceReadsNoFileUntilItIsUsed() async {
        let dir = FaviconFixtures.temporaryFolder("lazy")
        let s = service(StubFetcher(), directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        _ = s
    }


    func testAnIconIsOnDiskShortlyAfterItIsLearnedWithoutAnyFlushCall() async throws {
        let dir = FaviconFixtures.temporaryFolder("early")
        let stub = StubFetcher(); await stub.setFallback(.image())
        let s = service(stub, directory: dir)
        _ = await s.resolve(pageURL: page("a.example"), declared: [])
        try await Task.sleep(for: .milliseconds(900))
        let again = service(stub, directory: dir)
        let found = await again.hasIcon(IconKey(host: "a.example")!)
        XCTAssertTrue(found, "written half a second after the change, not three seconds")
        _ = s
    }

    func testReadingIconsWritesNothing() async throws {
        let dir = FaviconFixtures.temporaryFolder("reads")
        let stub = StubFetcher(); await stub.setFallback(.image())
        let s = service(stub, directory: dir)
        _ = await s.resolve(pageURL: page("a.example"), declared: [])
        await s.flush()
        let index = dir.appendingPathComponent("index.json")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        for _ in 0..<200 { _ = await s.lookup(IconKey(host: "a.example")!) }
        try await Task.sleep(for: .milliseconds(900))
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "scrolling a list of icons does not rewrite the index")
        await s.flush()      // the uses are written when the app goes to the background or quits
    }

    func testSitesOnDifferentPortsKeepTheirOwnIconsAndRemovingTheHostRemovesAll() async {
        let stub = StubFetcher()
        await stub.set("https://localhost:3000/favicon.ico", .image(FaviconFixtures.png(width: 64, height: 64, red: 255)))
        await stub.set("https://localhost:8080/favicon.ico", .image(FaviconFixtures.png(width: 64, height: 64, red: 0)))
        let s = service(stub)
        let a = URL(string: "https://localhost:3000/")!, b = URL(string: "https://localhost:8080/")!
        _ = await s.resolve(pageURL: a, declared: []); _ = await s.resolve(pageURL: b, declared: [])
        let ia = await s.lookup(IconKey(url: a)!), ib = await s.lookup(IconKey(url: b)!)
        XCTAssertNotNil(ia); XCTAssertNotNil(ib); XCTAssertNotEqual(ia, ib)
        XCTAssertEqual(IconKey(url: URL(string: "https://example.com:443/")!)?.host, "example.com", "the default port is not part of the key")
        XCTAssertEqual(IconKey(url: URL(string: "http://example.com:80/")!)?.host, "example.com")
        XCTAssertEqual(IconKey(url: b)?.host, "localhost:8080")
        await s.remove(host: "localhost")
        let gone = await s.recordCount
        XCTAssertEqual(gone, 0, "removing a site's data removes the icon of every port")
    }

    func testAnIconOnABlockedThirdPartyHostIsNotFetchedButTheSitesOwnDefaultIs() async {
        let stub = StubFetcher()
        await stub.set("https://ads.tracker.example/i.png", .image()); await stub.set("https://a.example/favicon.ico", .image())
        let s = service(stub)
        await s.setBlocklist(IconBlocklist(domains: ["tracker.example"]))
        let result = await s.resolve(pageURL: page("a.example"), declared: declared("/i.png", host: "ads.tracker.example"))
        XCTAssertEqual(result, .refreshed)
        let asked = await stub.requestedURLs()
        XCTAssertEqual(asked, ["https://a.example/favicon.ico"], "the blocked host was never contacted")
        let events = await s.diagnostics()
        XCTAssertTrue(events.contains { $0.kind == .candidateBlocked })
    }

    func testDiagnosticsNameHostsAndReasonsButNeverAddresses() async {
        let stub = StubFetcher(); await stub.set("https://a.example/secret/path?token=abc123", .failed(.badStatus)); await stub.set("https://a.example/favicon.ico", .failed(.tooLarge))
        let s = service(stub)
        _ = await s.resolve(pageURL: URL(string: "https://a.example/account?session=xyz")!, declared: IconCandidateRanker.candidates(fromLinks: [["href": "https://a.example/secret/path?token=abc123", "rel": "icon"]], pageURL: page("a.example")))
        let events = await s.diagnostics()
        XCTAssertFalse(events.isEmpty)
        for e in events {
            for text in [e.host, e.detail] {
                XCTAssertFalse(text.contains("/") || text.contains("?") || text.contains("token") || text.contains("session") || text.contains("secret"), "leaked: \(text)")
            }
        }
    }
}
