import XCTest
@testable import Browser_Setu

/// Relationship-aware discovery: a page's own files on OTHER websites (a media host, a CDN, a PDF elsewhere) are listed without being contacted; pages of other websites are never read; the person's
/// network stays out of reach; a site that refuses automatic reads says so honestly. All with an injected fetch (no network).
@MainActor
final class ExplorerReferencedFilesTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var urls: [String] = []
        func add(_ u: URL) { lock.lock(); urls.append(u.absoluteString); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private let start = URL(string: "https://articles.example/wiki/Topic")!
    private let page = """
    <html><body>
      <img src="https://media.example/pictures/a.jpg">
      <audio><source src="https://media.example/sound/talk.mp3"></audio>
      <a href="https://docs.example/papers/study.pdf">paper</a>
      <a href="https://elsewhere.example/another-page.html">another website's page</a>
      <a href="https://media.example/pictures/page-without-extension">a thumbnail page</a>
      <img src="http://192.168.1.5/private/home.jpg">
      <a href="/files/local.zip">a file on this site</a>
    </body></html>
    """

    private func run(include: Bool, status: Int? = nil) async -> (items: [ExplorerItem], summary: ExplorerSummary, requested: [String]) {
        let log = Log(); let body = Data(page.utf8); let start = self.start
        let ex = WebsiteExplorer(fetch: { req in
            log.add(req.url)
            if let status, req.url.path != "/robots.txt" { throw ExplorerFetchError.status(status) }
            if req.url.path == "/robots.txt" { return ExplorerPage(data: Data("User-agent: *\nAllow: /\n".utf8), finalURL: req.url, contentType: "text/plain") }
            if req.url == start { return ExplorerPage(data: body, finalURL: req.url, contentType: "text/html") }
            throw ExplorerFetchError.status(404)
        }, sleep: { _ in })
        var scope = ExplorerScope(start: start, origin: .user)
        scope.maxDepth = 1; scope.sameOriginOnly = true; scope.stayInDirectory = false; scope.includeReferencedFiles = include
        var items: [ExplorerItem] = []
        let summary = await ex.explore(scope.clamped()) { items.append($0) }
        return (items, summary, log.all)
    }

    func testFilesOnOtherWebsitesAreListedButNothingOnThemIsContacted() async {
        let r = await run(include: true)
        let urls = Set(r.items.map(\.url))
        XCTAssertTrue(urls.contains("https://media.example/pictures/a.jpg"))
        XCTAssertTrue(urls.contains("https://media.example/sound/talk.mp3"))
        XCTAssertTrue(urls.contains("https://docs.example/papers/study.pdf"))
        XCTAssertTrue(urls.contains("https://articles.example/files/local.zip"), "the site's own file is still found")
        let elsewhere = r.items.filter(\.hostedElsewhere)
        XCTAssertEqual(Set(elsewhere.map(\.host)), ["media.example", "docs.example"])
        XCTAssertFalse(r.items.first { $0.url.hasSuffix("local.zip") }!.hostedElsewhere)
        XCTAssertEqual(r.summary.referencedElsewhere, 3)
        // Not contacted: the only requests were this website's robots.txt and the starting page.
        XCTAssertEqual(Set(r.requested), ["https://articles.example/robots.txt", "https://articles.example/wiki/Topic"], "no request went to another website")
        // Another website's PAGE (and a media host's extension-less page link) is neither listed nor followed; the person's own network is refused.
        XCTAssertFalse(urls.contains("https://elsewhere.example/another-page.html"))
        XCTAssertFalse(urls.contains("https://media.example/pictures/page-without-extension"))
        XCTAssertFalse(urls.contains("http://192.168.1.5/private/home.jpg"), "a page cannot send the explorer into the home network")
        XCTAssertEqual(r.summary.insideNetworkRefused, 1)
    }

    func testTurningItOffRestoresTheStrictSingleWebsiteList() async {
        let r = await run(include: false)
        XCTAssertEqual(Set(r.items.map(\.url)), ["https://articles.example/files/local.zip"])
        XCTAssertEqual(r.summary.referencedElsewhere, 0)
        XCTAssertGreaterThanOrEqual(r.summary.outOfScope, 3)
    }

    func testASiteThatRefusesAutomaticReadsSaysSoAndPointsToThePageCollector() async {
        for code in [403, 429, 503] {
            let r = await run(include: true, status: code)
            XCTAssertEqual(r.summary.stop, .startFailed)
            let note = r.summary.note ?? ""
            XCTAssertTrue(note.contains("\(code)") && note.contains("Collect from This Page"), "status \(code): \(note)")
        }
        let notFound = await run(include: true, status: 404)
        XCTAssertEqual(notFound.summary.note, "The starting page could not be read (the website answered 404).")
    }

    func testTheSamePageThroughTheLinkGrabberStaysUnrestrictedByHost() {
        // The LinkGrabber never had a host limit: every direct file link on the page is a candidate, wherever it is hosted.
        XCTAssertEqual(LinkClassifier.classify("https://media.example/pictures/a.jpg").kind, .httpResource)
        XCTAssertEqual(LinkClassifier.classify("https://docs.example/papers/study.pdf").kind, .httpResource)
    }
}
