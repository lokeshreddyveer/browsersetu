import XCTest
import Network
@testable import Browser_Setu

/// A stand-in for the wire. The fetcher's own code runs for real on top of it: its request headers, redirect handling, size and type checks, and the shared request policy.
final class IconWire: URLProtocol {
    enum Reply {
        case ok(Data, [String: String])
        case status(Int, [String: String])
        case redirect(String, Int)
        case stream(Int)                 // a body of this many bytes with no length announced
    }
    nonisolated(unsafe) static var routes: [String: Reply] = [:]
    nonisolated(unsafe) static var seenHeaders: [String: [String: String]] = [:]
    private static let lock = NSLock()

    static func reset(_ routes: [String: Reply]) { lock.withLock { self.routes = routes; seenHeaders = [:] } }
    static func headers(for url: String) -> [String: String]? { lock.withLock { seenHeaders[url] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        Self.lock.withLock { Self.seenHeaders[key] = request.allHTTPHeaderFields ?? [:] }
        let reply = Self.lock.withLock { Self.routes[key] }
        switch reply {
        case .ok(let data, let headers)?:
            var h = headers; h["Content-Length"] = h["Content-Length"] ?? "\(data.count)"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: h)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        case .status(let code, let headers)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let to, let code)?:
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
        case .stream(let count)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(count: count)); client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}


/// A connector that records what it was asked and answers from a script, to see which address a request really went to.
final class ScriptedPinned: PinnedHTTPConnecting, @unchecked Sendable {
    struct Call: Equatable { var url: String; var address: String; var conditional: [String: String] }
    private let lock = NSLock()
    private var script: [String: PinnedHTTPResult] = [:]
    private var failures: [String: Error] = [:]
    private var _calls: [Call] = []
    func reply(_ url: String, _ result: PinnedHTTPResult) { lock.withLock { script[url] = result } }
    func fail(_ url: String, _ error: Error) { lock.withLock { failures[url] = error } }
    var calls: [Call] { lock.withLock { _calls } }
    func get(_ url: URL, address: String, maxBody: Int, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, conditional: [:], refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }
    func get(_ url: URL, address: String, maxBody: Int, range: String?, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, conditional: [:], refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }
    func get(_ url: URL, address: String, maxBody: Int, conditional: [String: String], refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        let key = url.absoluteString
        lock.withLock { _calls.append(Call(url: key, address: address, conditional: conditional)) }
        if let error = lock.withLock({ failures[key] }) { throw error }
        return lock.withLock { script[key] } ?? PinnedHTTPResult(status: 404, location: nil, body: Data())
    }
}

/// Counts name lookups and lets a name answer differently each time, as a DNS-rebinding server does.
final class ScriptedDNS: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [(HostClass, [String])]] = [:]
    private var counts: [String: Int] = [:]
    func answer(_ host: String, _ list: [(HostClass, [String])]) { lock.withLock { answers[host] = list } }
    func lookups(_ host: String) -> Int { lock.withLock { counts[host] ?? 0 } }
    func resolve(_ host: String) -> (kind: HostClass, resolved: [String]?) {
        lock.withLock {
            let n = counts[host] ?? 0; counts[host] = n + 1
            guard let list = answers[host], !list.isEmpty else { return (.publicHost, ["203.0.113.7"]) }
            let pick = list[min(n, list.count - 1)]
            return (pick.0, pick.1)
        }
    }
}

final class IconFetcherPinnedTests: XCTestCase {
    private let png = FaviconFixtures.png(width: 64, height: 64)
    private func ok(_ headers: [String: String] = ["content-type": "image/png"]) -> PinnedHTTPResult { PinnedHTTPResult(status: 200, location: nil, body: png, headers: headers) }
    private func make(_ connector: ScriptedPinned, _ dns: ScriptedDNS) -> NetworkIconFetcher {
        var f = NetworkIconFetcher(); f.connector = connector; f.systemProxyActive = { false }; f.resolver = { dns.resolve($0) }; return f
    }
    private func request(_ url: String, page: String = "example.com", etag: String? = nil, origin: String? = nil) -> IconFetchRequest {
        IconFetchRequest(url: URL(string: url)!, pageHost: page, etag: etag, lastModified: nil, pageOrigin: origin)
    }

    func testTheRequestGoesToTheAddressThatWasCheckedNotToTheName() async {
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        dns.answer("example.com", [(.publicHost, ["198.51.100.20"])])
        connector.reply("https://example.com/i.png", ok())
        guard case .fresh(let body) = await make(connector, dns).fetch(request("https://example.com/i.png")) else { return XCTFail("not fetched") }
        XCTAssertEqual(body.data, png)
        XCTAssertEqual(connector.calls.map(\.address), ["198.51.100.20"], "the connection was made to the numeric address that passed the check")
        XCTAssertEqual(dns.lookups("example.com"), 1, "the name was looked up once: the system is never asked to look it up again")
    }

    func testANameThatChangesItsAnswerCannotRedirectTheRequest() async {
        // The classic rebinding: public when it is checked, private afterwards. With the connection pinned, the second answer is never used for the first hop.
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        dns.answer("rebind.example", [(.publicHost, ["198.51.100.20"]), (.privateNetwork, ["10.0.0.5"])])
        connector.reply("https://rebind.example/i.png", ok())
        guard case .fresh = await make(connector, dns).fetch(request("https://rebind.example/i.png")) else { return XCTFail() }
        XCTAssertEqual(connector.calls.map(\.address), ["198.51.100.20"])
        // And a name that is private from the start is refused before anything is sent.
        let c2 = ScriptedPinned(), d2 = ScriptedDNS(); d2.answer("inside.example", [(.privateNetwork, ["10.0.0.5"])])
        let refused = await make(c2, d2).fetch(request("https://inside.example/i.png"))
        XCTAssertEqual(refused, .failed(.refusedByPolicy)); XCTAssertTrue(c2.calls.isEmpty)
    }

    func testARedirectIsJudgedAndResolvedBeforeItIsFollowed() async {
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        dns.answer("cdn.example.net", [(.publicHost, ["198.51.100.30"])])
        connector.reply("https://example.com/old.png", PinnedHTTPResult(status: 301, location: "https://cdn.example.net/new.png", body: Data()))
        connector.reply("https://cdn.example.net/new.png", ok())
        guard case .fresh = await make(connector, dns).fetch(request("https://example.com/old.png")) else { return XCTFail("not followed") }
        XCTAssertEqual(connector.calls.map(\.address), ["203.0.113.7", "198.51.100.30"])
        // A redirect whose target name now answers with a private address is refused without a connection.
        let c2 = ScriptedPinned(), d2 = ScriptedDNS(); d2.answer("evil.example.net", [(.privateNetwork, ["192.168.1.1"])])
        c2.reply("https://example.com/old.png", PinnedHTTPResult(status: 302, location: "https://evil.example.net/x.png", body: Data()))
        let result = await make(c2, d2).fetch(request("https://example.com/old.png"))
        XCTAssertEqual(result, .failed(.redirectRefused)); XCTAssertEqual(c2.calls.count, 1, "only the first hop was ever connected to")
    }

    func testARedirectDownToHTTPOrInfinitelyLongIsRefused() async {
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        connector.reply("https://example.com/old.png", PinnedHTTPResult(status: 302, location: "http://example.com/new.png", body: Data()))
        let down = await make(connector, dns).fetch(request("https://example.com/old.png"))
        XCTAssertEqual(down, .failed(.redirectRefused))
        let loopConnector = ScriptedPinned()
        for i in 0..<12 { loopConnector.reply("https://example.com/\(i)", PinnedHTTPResult(status: 302, location: "https://example.com/\(i + 1)", body: Data())) }
        let loop = await make(loopConnector, dns).fetch(request("https://example.com/0"))
        XCTAssertEqual(loop, .failed(.redirectRefused), "after five redirects it stops")
        XCTAssertLessThanOrEqual(loopConnector.calls.count, NetworkIconFetcher.maxRedirects + 1)
    }

    func testValidatorsAreSentOnlyOnTheFirstRequestAndA304IsHandled() async {
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        connector.reply("https://example.com/i.png", PinnedHTTPResult(status: 304, location: nil, body: Data(), headers: ["etag": "\"v2\"", "cache-control": "max-age=600"]))
        let result = await make(connector, dns).fetch(request("https://example.com/i.png", etag: "\"v1\""))
        XCTAssertEqual(connector.calls.first?.conditional["If-None-Match"], "\"v1\"")
        guard case .notModified(let hints) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(hints.etag, "\"v2\""); XCTAssertEqual(hints.maxAge, 600)
    }

    func testTypesStatusesAndConnectorFailuresAreMapped() async {
        let dns = ScriptedDNS()
        let html = ScriptedPinned(); html.reply("https://example.com/i", ok(["content-type": "text/html"]))
        let notImage = await make(html, dns).fetch(request("https://example.com/i"))
        XCTAssertEqual(notImage, .failed(.notImageType))
        let gone = ScriptedPinned(); gone.reply("https://example.com/i", PinnedHTTPResult(status: 410, location: nil, body: Data()))
        let status = await make(gone, dns).fetch(request("https://example.com/i"))
        XCTAssertEqual(status, .failed(.badStatus))
        let big = ScriptedPinned(); big.fail("https://example.com/i", NWPinnedHTTP.Failure.tooLarge)
        let large = await make(big, dns).fetch(request("https://example.com/i"))
        XCTAssertEqual(large, .failed(.tooLarge))
        let slow = ScriptedPinned(); slow.fail("https://example.com/i", NWPinnedHTTP.Failure.timedOut)
        let timeout = await make(slow, dns).fetch(request("https://example.com/i"))
        XCTAssertEqual(timeout, .failed(.timeout))
    }

    func testALocalSitesOwnIconStillWorksOverThePinnedPathAndStaysConfined() async {
        let connector = ScriptedPinned(), dns = ScriptedDNS()
        dns.answer("nas.local", [(.localName, ["192.168.1.20"])])
        connector.reply("https://nas.local/favicon.ico", ok(["content-type": "image/x-icon"]))
        guard case .fresh = await make(connector, dns).fetch(request("https://nas.local/favicon.ico", page: "nas.local", origin: "https://nas.local:443")) else { return XCTFail("its own icon was refused") }
        XCTAssertEqual(connector.calls.first?.address, "192.168.1.20")
        let c2 = ScriptedPinned(); c2.reply("https://nas.local/i.png", PinnedHTTPResult(status: 302, location: "https://192.168.1.1/admin.png", body: Data()))
        let r = await make(c2, dns).fetch(request("https://nas.local/i.png", page: "nas.local", origin: "https://nas.local:443"))
        XCTAssertEqual(r, .failed(.redirectRefused)); XCTAssertEqual(c2.calls.count, 1)
    }

    func testAnAddressIsChosenFromWhatTheNameResolvedTo() {
        XCTAssertEqual(NetworkIconFetcher.address(for: "example.com", resolved: ["2001:db8::1", "198.51.100.9"]), "198.51.100.9", "IPv4 first")
        XCTAssertEqual(NetworkIconFetcher.address(for: "example.com", resolved: ["2001:db8::1"]), "2001:db8::1")
        XCTAssertEqual(NetworkIconFetcher.address(for: "203.0.113.5", resolved: nil), "203.0.113.5")
        XCTAssertEqual(NetworkIconFetcher.address(for: "[2001:db8::1]", resolved: nil), "2001:db8::1")
        XCTAssertNil(NetworkIconFetcher.address(for: "example.com", resolved: nil))
    }
}

final class IconFetcherTests: XCTestCase {
    private let png = FaviconFixtures.png(width: 64, height: 64)

    /// Every name is public unless it looks like a local one, so no test needs the network.
    private func fetcher(resolve: @escaping @Sendable (String) async -> (kind: HostClass, resolved: [String]?) = { host in
        (HTTPRequestPolicy.classify(host: host), ["203.0.113.7"]) }) -> NetworkIconFetcher {
        var f = NetworkIconFetcher(); f.protocolClasses = [IconWire.self]; f.resolver = resolve; return f
    }
    private func request(_ url: String, page: String = "example.com", etag: String? = nil, origin: String? = nil) -> IconFetchRequest {
        IconFetchRequest(url: URL(string: url)!, pageHost: page, etag: etag, lastModified: nil, pageOrigin: origin)
    }

    func testAnImageIsFetchedWithItsBytesAndCacheHints() async {
        IconWire.reset(["https://example.com/i.png": .ok(png, ["Content-Type": "image/png", "ETag": "\"v1\"", "Cache-Control": "max-age=3600"])])
        guard case .fresh(let body) = await fetcher().fetch(request("https://example.com/i.png")) else { return XCTFail("not fetched") }
        XCTAssertEqual(body.data, png, "the bytes that arrive are the bytes that were sent")
        XCTAssertEqual(body.hints.etag, "\"v1\""); XCTAssertEqual(body.hints.maxAge, 3600)
        let headers = IconWire.headers(for: "https://example.com/i.png") ?? [:]
        XCTAssertNil(headers["Cookie"]); XCTAssertNil(headers["Authorization"]); XCTAssertTrue(headers["Accept"]?.contains("image/") ?? false)
    }

    func testAConditionalRequestCarriesTheValidatorAndA304IsNotModified() async {
        IconWire.reset(["https://example.com/i.png": .status(304, ["ETag": "\"v1\""])])
        let result = await fetcher().fetch(request("https://example.com/i.png", etag: "\"v1\""))
        XCTAssertEqual(IconWire.headers(for: "https://example.com/i.png")?["If-None-Match"], "\"v1\"")
        guard case .notModified = result else { return XCTFail("\(result)") }
    }

    func testAnHTMLPageServedAsAnIconIsRefused() async {
        IconWire.reset(["https://example.com/favicon.ico": .ok(Data("<html>Not found</html>".utf8), ["Content-Type": "text/html"])])
        let r1 = await fetcher().fetch(request("https://example.com/favicon.ico"))
        XCTAssertEqual(r1, .failed(.notImageType))
    }

    func testAnErrorStatusIsAFailure() async {
        IconWire.reset(["https://example.com/i.png": .status(500, [:])])
        let r2 = await fetcher().fetch(request("https://example.com/i.png"))
        XCTAssertEqual(r2, .failed(.badStatus))
        IconWire.reset(["https://example.com/i.png": .status(401, ["WWW-Authenticate": "Basic realm=x"])])
        let r3 = await fetcher().fetch(request("https://example.com/i.png"))
        XCTAssertEqual(r3, .failed(.badStatus), "a login request is never answered")
    }

    func testAnAnnouncedHugeBodyIsRefusedBeforeItIsRead() async {
        IconWire.reset(["https://example.com/i.png": .ok(Data(count: 10), ["Content-Type": "image/png", "Content-Length": "5000000"])])
        let r4 = await fetcher().fetch(request("https://example.com/i.png"))
        XCTAssertEqual(r4, .failed(.tooLarge))
    }

    func testABodyThatIsLargerThanItSaidIsCutOffAtTheLimit() async {
        IconWire.reset(["https://example.com/i.png": .stream(NetworkIconFetcher.maxBytes * 4)])
        let r5 = await fetcher().fetch(request("https://example.com/i.png"))
        XCTAssertEqual(r5, .failed(.tooLarge))
    }

    func testARedirectToAnotherPublicHostIsFollowed() async {
        IconWire.reset(["https://example.com/old.png": .redirect("https://static.example.net/new.png", 301), "https://static.example.net/new.png": .ok(png, ["Content-Type": "image/png"])])
        guard case .fresh = await fetcher().fetch(request("https://example.com/old.png")) else { return XCTFail("not followed") }
    }

    func testARedirectDownToHTTPIsRefused() async {
        IconWire.reset(["https://example.com/old.png": .redirect("http://example.com/new.png", 302), "http://example.com/new.png": .ok(png, ["Content-Type": "image/png"])])
        let r6 = await fetcher().fetch(request("https://example.com/old.png"))
        XCTAssertEqual(r6, .failed(.redirectRefused))
    }

    func testARedirectIntoTheLocalNetworkIsRefused() async {
        for target in ["https://192.168.1.1/admin.png", "https://localhost/x.png", "https://router.local/x.png", "https://10.0.0.5/x.png", "https://169.254.169.254/latest/meta-data"] {
            IconWire.reset(["https://example.com/old.png": .redirect(target, 302), target: .ok(png, ["Content-Type": "image/png"])])
            let r7 = await fetcher().fetch(request("https://example.com/old.png"))
            XCTAssertEqual(r7, .failed(.redirectRefused), "followed: \(target)")
        }
    }

    func testANameThatResolvesToAPrivateAddressIsRefusedBeforeAnyRequest() async {
        IconWire.reset(["https://sneaky.example.org/i.png": .ok(png, ["Content-Type": "image/png"])])
        let privateResolver: @Sendable (String) async -> (kind: HostClass, resolved: [String]?) = { _ in (.privateNetwork, ["10.1.2.3"]) }
        let r8 = await fetcher(resolve: privateResolver).fetch(request("https://sneaky.example.org/i.png"))
        XCTAssertEqual(r8, .failed(.refusedByPolicy))
        XCTAssertNil(IconWire.headers(for: "https://sneaky.example.org/i.png"), "no request was made")
    }

    func testAPageCannotAimAnIconAtItsOwnVisitorsNetwork() async {
        IconWire.reset([:])
        for url in ["https://127.0.0.1/i.png", "https://localhost/i.png", "https://[::1]/i.png", "https://192.168.0.1/i.png", "https://nas.local/i.png", "https://0x7f.0.0.1/i.png"] {
            let r9 = await fetcher().fetch(request(url, page: "example.com"))
            XCTAssertEqual(r9, .failed(.refusedByPolicy), url)
            XCTAssertNil(IconWire.headers(for: url), "a request was sent to \(url)")
        }
    }

    func testASiteTheyOpenedOnTheirOwnNetworkMaySupplyItsOwnIcon() async {
        IconWire.reset(["https://nas.local/favicon.ico": .ok(png, ["Content-Type": "image/x-icon"])])
        guard case .fresh = await fetcher().fetch(request("https://nas.local/favicon.ico", page: "nas.local", origin: "https://nas.local:443")) else { return XCTFail("their own server's icon was refused") }
        IconWire.reset(["https://other.local/favicon.ico": .ok(png, ["Content-Type": "image/x-icon"])])
        let r10 = await fetcher().fetch(request("https://other.local/favicon.ico", page: "nas.local", origin: "https://nas.local:443"))
        XCTAssertEqual(r10, .failed(.refusedByPolicy), "but that page may not reach a different local host")
    }


    func testALocalSitesIconMustComeFromExactlyItsOwnOriginIncludingThePort() async {
        IconWire.reset(["https://localhost:6379/x.png": .ok(png, ["Content-Type": "image/png"]), "https://localhost:3000/i.png": .ok(png, ["Content-Type": "image/png"]), "http://localhost:3000/i.png": .ok(png, ["Content-Type": "image/png"])])
        let origin = "https://localhost:3000"
        let other = await fetcher().fetch(request("https://localhost:6379/x.png", page: "localhost", origin: origin))
        XCTAssertEqual(other, .failed(.refusedByPolicy), "another port on the same machine is another service")
        let scheme = await fetcher().fetch(request("http://localhost:3000/i.png", page: "localhost", origin: origin))
        XCTAssertEqual(scheme, .failed(.refusedByPolicy), "and so is another scheme")
        guard case .fresh = await fetcher().fetch(request("https://localhost:3000/i.png", page: "localhost", origin: origin)) else { return XCTFail("its own icon was refused") }
    }

    func testALocalSitesIconCannotRedirectToAnotherLocalPlace() async {
        for target in ["https://169.254.169.254/latest/meta-data", "https://192.168.1.1/admin.png", "https://localhost:6379/x", "https://other.local/x.png", "https://example.net/x.png"] {
            IconWire.reset(["https://nas.local/i.png": .redirect(target, 302), target: .ok(png, ["Content-Type": "image/png"])])
            let r = await fetcher().fetch(request("https://nas.local/i.png", page: "nas.local", origin: "https://nas.local:443"))
            XCTAssertEqual(r, .failed(.redirectRefused), "followed: \(target)")
            XCTAssertNil(IconWire.headers(for: target), "a request was sent to \(target)")
        }
        IconWire.reset(["https://nas.local/i.png": .redirect("https://nas.local/new.png", 302), "https://nas.local/new.png": .ok(png, ["Content-Type": "image/png"])])
        guard case .fresh = await fetcher().fetch(request("https://nas.local/i.png", page: "nas.local", origin: "https://nas.local:443")) else { return XCTFail("a redirect within its own origin was refused") }
    }

    func testUnsupportedSchemesAreRefused() async {
        for url in ["ftp://example.com/i.png", "file:///etc/passwd", "data:image/png;base64,AAAA"] {
            let r11 = await fetcher().fetch(request(url))
            XCTAssertEqual(r11, .failed(.refusedByPolicy), url)
        }
    }

    func testCacheControlIsReadAndTypesAreJudged() {
        let r = HTTPURLResponse(url: URL(string: "https://e.com")!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "public, max-age=86400", "ETag": "W/\"x\""])!
        XCTAssertEqual(NetworkIconFetcher.hints(from: r).maxAge, 86_400)
        let nostore = HTTPURLResponse(url: URL(string: "https://e.com")!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!
        XCTAssertTrue(NetworkIconFetcher.hints(from: nostore).noStore)
        XCTAssertTrue(NetworkIconFetcher.isImageLike("image/svg+xml")); XCTAssertTrue(NetworkIconFetcher.isImageLike(nil)); XCTAssertTrue(NetworkIconFetcher.isImageLike("application/octet-stream"))
        XCTAssertFalse(NetworkIconFetcher.isImageLike("text/html")); XCTAssertFalse(NetworkIconFetcher.isImageLike("application/json"))
    }

    /// Real sites, over the real network, with the shipping fetcher. Skipped (not failed) when there is no network.
    func testRealSitesGiveRealIconsThroughTheWholePipeline() async throws {
        let service = FaviconService(directory: FaviconFixtures.temporaryFolder("real"))
        var stored = 0
        for host in ["www.wikipedia.org", "github.com", "www.apple.com"] {
            let page = URL(string: "https://\(host)/")!
            if await service.resolve(pageURL: page, declared: []) == .refreshed { stored += 1 }
        }
        if stored == 0 {
            let why = await service.diagnostics().filter { $0.kind == .fetchFailed || $0.kind == .decodeFailed }.map { "\($0.host):\($0.detail)" }.joined(separator: ", ")
            throw XCTSkip("nothing was stored (\(why))")
        }
        for host in ["wikipedia.org", "github.com", "apple.com"] {
            if let data = await service.lookup(IconKey(host: host)!) { XCTAssertEqual(FaviconFixtures.pixelSize(of: data).map { [$0.0, $0.1] }, [64, 64], host) }
        }
        let diag = await service.diagnostics()
        XCTAssertFalse(diag.contains { $0.host.contains("/") || $0.detail.contains("http") })
    }
}
