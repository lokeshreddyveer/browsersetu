import XCTest
import WebKit
@testable import Browser_Setu

// Phase 12: browser downloads and the one download manager. The pure decisions are tested directly; the WebKit lifecycle runs a real WKWebView
// against the local download fixture (127.0.0.1:18766), never an outside site.

private let fixtureBase = "http://127.0.0.1:18766"

// MARK: - Pure decisions

final class BrowserDownloadContextTests: XCTestCase {
    private func ctx(_ method: String = "GET", body: Data? = nil, headers: [String: String] = [:], url: String = "https://example.org/a.zip", persistent: Bool = true) -> BrowserDownloadContext {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method; r.httpBody = body; r.allHTTPHeaderFields = headers
        return BrowserDownloadContext(store: DownloadStoreKey(identifier: nil, isPersistent: persistent), request: r)
    }

    func testPlainGetCanBeRepeatedFromItsAddress() { XCTAssertTrue(ctx().isReplayableByAddress) }
    func testPostIsNeverRepeatedAsAGet() { XCTAssertFalse(ctx("POST").isReplayableByAddress) }
    func testARequestWithABodyIsNotReplayable() { XCTAssertFalse(ctx("GET", body: Data([1])).isReplayableByAddress) }
    func testCredentialHeadersMakeARequestNonReplayable() {
        for name in ["Authorization", "cookie", "Proxy-Authorization"] { XCTAssertFalse(ctx(headers: [name: "x"]).isReplayableByAddress, name) }
    }
    func testNonWebAddressIsNotReplayable() { XCTAssertFalse(ctx(url: "blob:https://example.org/uuid").isReplayableByAddress) }
    func testPrivacyComesFromTheStoreRecordedAtTheStart() {
        XCTAssertTrue(ctx(persistent: false).isPrivate)
        XCTAssertFalse(ctx(persistent: true).isPrivate)
    }
}

final class BrowserMenuDownloadsTests: XCTestCase {
    func testALinkOffersSaveLinkAs() {
        XCTAssertEqual(BrowserMenuDownloads.items(link: URL(string: "https://a.org/f.zip"), image: nil), [.saveLinkAs(URL(string: "https://a.org/f.zip")!), .showDownloads])
    }
    func testAnImageOffersSaveImageAs() {
        XCTAssertEqual(BrowserMenuDownloads.items(link: nil, image: URL(string: "https://a.org/p.png")), [.saveImageAs(URL(string: "https://a.org/p.png")!), .showDownloads])
    }
    func testNothingUnderThePointerOffersNothing() { XCTAssertTrue(BrowserMenuDownloads.items(link: nil, image: nil).isEmpty) }
    func testBlobDataAndScriptAddressesAreNotSavedAsStandaloneResources() {
        for text in ["blob:https://a.org/1", "data:image/png;base64,AAAA", "javascript:alert(1)", "file:///etc/passwd", "ftp://a.org/f", "https:///nohost"] {
            XCTAssertFalse(BrowserMenuDownloads.isSavable(URL(string: text)), text)
            XCTAssertTrue(BrowserMenuDownloads.items(link: URL(string: text), image: URL(string: text)).isEmpty, text)
        }
    }
}

final class DownloadRoutingTests: XCTestCase {
    private func route(_ i: BrowserDownloadRouting.Input) -> DownloadRoute { BrowserDownloadRouting.route(i) }
    func testBrowserDownloadsStayWithWebKit() { XCTAssertEqual(route(.browserDownload), .webKitSession) }
    func testSavingFromAPageUsesThePageSession() {
        XCTAssertEqual(route(.saveFromPage(URL(string: "https://a.org/i.png")!)), .webKitSession)
        XCTAssertEqual(route(.saveFromPage(URL(string: "blob:https://a.org/1")!)), .refused)
    }
    func testATypedAddressUsesTheStandaloneEngineOrAPreview() {
        XCTAssertEqual(route(.typedAddress(URL(string: "https://a.org/f")!)), .standaloneHTTP)
        XCTAssertEqual(route(.typedAddress(URL(string: "magnet:?xt=urn:btih:aaaa")!)), .torrentPreview)
        XCTAssertEqual(route(.typedAddress(URL(string: "ed2k://%7Cfile%7Ca%7C1%7C" + String(repeating: "A", count: 32) + "%7C/")!)), .ed2kPreview)
        XCTAssertEqual(route(.typedAddress(URL(string: "ftp://a.org/f")!)), .refused)
    }
    func testPeerToPeerAlwaysGoesThroughItsPreview() {
        XCTAssertEqual(route(.magnetLink), .torrentPreview); XCTAssertEqual(route(.torrentFile), .torrentPreview); XCTAssertEqual(route(.ed2kLink), .ed2kPreview)
    }
    func testExtensionSuggestionsAndPageContentNeverBecomeTasks() {
        XCTAssertEqual(route(.extensionSuggestion), .informationOnly)
        XCTAssertEqual(route(.pageContentOnly), .refused)
    }
}

final class PieceTakeoverCredentialTests: XCTestCase {
    private func response() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://a.org/big.bin")!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Accept-Ranges": "bytes", "Content-Length": "\(PiecePlan.minimumSize + 1)"])!
    }
    func testAPlainLargeGetIsEligible() { XCTAssertTrue(PiecePlan.eligible(response: response(), request: URLRequest(url: URL(string: "https://a.org/big.bin")!))) }
    func testARequestWithCredentialsIsNeverCopiedToTheSeparateSession() {
        for name in ["Authorization", "Cookie", "Proxy-Authorization"] {
            var r = URLRequest(url: URL(string: "https://a.org/big.bin")!); r.setValue("secret", forHTTPHeaderField: name)
            XCTAssertFalse(PiecePlan.eligible(response: response(), request: r), name)
        }
    }
}

// MARK: - Coordinator side of the lifecycle

@MainActor
final class BrowserDownloadCoordinatorTests: XCTestCase {
    private var scratch: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p12-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }

    func testAHeldQueueDoesNotKeepADownloadItCouldOnlyRepeatAsAGet() async {
        let c = DownloadCoordinator()
        c.holdQueue(until: .distantFuture)
        let source = URL(string: "https://a.org/export")!
        let kept = await c.admitTicket(filename: "k.bin", source: source)
        XCTAssertFalse(kept.admitted)
        XCTAssertFalse(c.scheduled.isEmpty, "an ordinary download is kept for later")
        let before = c.scheduled.count
        let dropped = await c.admitTicket(filename: "p.bin", source: URL(string: "https://a.org/post")!, allowSchedule: false)
        XCTAssertFalse(dropped.admitted)
        XCTAssertEqual(c.scheduled.count, before, "a POST, private or chosen-place download is not scheduled")
        XCTAssertEqual(c.ledger.record(dropped.id)?.state, .cancelled)
    }

    func testWithoutAChosenDestinationAnExistingFileIsNeverReused() throws {
        let c = DownloadCoordinator()
        try Data([9]).write(to: scratch.appendingPathComponent("same.bin"))
        let started = c.begin(suggestedName: "same.bin", sourceHost: nil, sourceURL: nil, cancel: {})
        XCTAssertNotEqual(started.destination.lastPathComponent, "same.bin")
    }

    func testTheTaskKeepsOneIdentityFromTicketToCompletion() async throws {
        let c = DownloadCoordinator()
        let source = URL(string: "https://a.org/f.bin")!
        let ticket = await c.admitTicket(filename: "f.bin", source: source)
        XCTAssertTrue(ticket.admitted)
        let started = c.begin(suggestedName: "f.bin", sourceURL: source, taskID: ticket.id, cancel: {})
        XCTAssertEqual(started.id, ticket.id)
        try Data([1]).write(to: started.destination)
        c.finish(started.id, source: source)
        XCTAssertEqual(c.ledger.records.count, 1)
    }

    func testCompletionHappensExactlyOnce() throws {
        let c = DownloadCoordinator()
        var finishes = 0
        c.onFinished = { _, _, _ in finishes += 1 }
        let started = c.begin(suggestedName: "f.bin", sourceURL: URL(string: "https://a.org/f.bin"), cancel: {})
        try Data([1]).write(to: started.destination)
        c.finish(started.id, source: nil)
        c.finish(started.id, source: nil)
        c.finish(started.id, source: nil)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(c.completed.count, 1)
    }

    func testALateFailureAfterCompletionDoesNotReopenTheTask() throws {
        let c = DownloadCoordinator()
        let started = c.begin(suggestedName: "f.bin", sourceURL: URL(string: "https://a.org/f.bin"), cancel: {})
        try Data([1]).write(to: started.destination)
        c.finish(started.id, source: nil)
        c.fail(started.id, source: nil, error: URLError(.networkConnectionLost), willRetry: false)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .completed)
    }

    func testAPostDownloadIsNotRetriedFromItsAddress() throws {
        let c = DownloadCoordinator()
        let source = URL(string: "https://a.org/export")!
        let started = c.begin(suggestedName: "e.csv", sourceURL: source, cancel: {})
        XCTAssertFalse(c.planRetry(for: source, error: URLError(.networkConnectionLost), resumeData: nil, id: started.id, replayableByAddress: false))
        let other = c.begin(suggestedName: "g.csv", sourceURL: source, cancel: {})
        XCTAssertTrue(c.planRetry(for: source, error: URLError(.networkConnectionLost), resumeData: nil, id: other.id, replayableByAddress: true))
    }

    func testAFailedPostDownloadOffersNoRetryButAFailedGetDoes() {
        let c = DownloadCoordinator()
        let source = URL(string: "https://a.org/export")!
        c.fail(nil, filename: "e.csv", source: source, error: URLError(.badServerResponse), willRetry: false, replayableByAddress: false)
        c.fail(nil, filename: "g.csv", source: source, error: URLError(.badServerResponse), willRetry: false)
        XCTAssertEqual(c.failures.first { $0.filename == "e.csv" }?.canRetry, false)
        XCTAssertEqual(c.failures.first { $0.filename == "g.csv" }?.canRetry, true)
    }

    func testAPrivateDownloadLeavesNoFailureRecord() {
        let c = DownloadCoordinator()
        let started = c.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p.bin"), isPrivate: true, cancel: {})
        XCTAssertEqual(c.ledger.record(started.id)?.isPrivate, true)
        c.fail(started.id, source: URL(string: "https://a.org/p.bin"), error: URLError(.networkConnectionLost), willRetry: false)
        XCTAssertTrue(c.failures.isEmpty)
    }

    func testADownloadThatEndedWhileWaitingGivesItsPlaceBack() async {
        let c = DownloadCoordinator()
        c.maxConcurrent = 1
        let first = await c.admitTicket(filename: "a.bin", source: URL(string: "https://a.org/a.bin"))
        XCTAssertTrue(first.admitted)
        c.abandonAdmitted(first.id)
        XCTAssertEqual(c.ledger.record(first.id)?.state, .cancelled)
        let second = await c.admitTicket(filename: "b.bin", source: URL(string: "https://a.org/b.bin"))
        XCTAssertTrue(second.admitted, "the abandoned place was returned to the queue")
    }

    func testCancellingStopsTheTransferAndRecordsACancellation() throws {
        let c = DownloadCoordinator()
        var cancelled = false
        let started = c.begin(suggestedName: "c.bin", sourceURL: URL(string: "https://a.org/c.bin"), cancel: { cancelled = true })
        try Data([1]).write(to: started.destination)
        c.cancel(started.id)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.path))
        // WebKit reports the cancellation as an error afterwards: it is not a failure.
        c.fail(started.id, source: nil, error: URLError(.cancelled), willRetry: false)
        XCTAssertTrue(c.failures.isEmpty)
    }

    func testInterruptedWithResumeDataIsConditional() {
        let c = DownloadCoordinator()
        let source = URL(string: "https://a.org/r.bin")!
        let started = c.begin(suggestedName: "r.bin", sourceURL: source, cancel: {})
        c.interrupt(started.id, resumeData: Data([1, 2]), source: source)
        XCTAssertEqual(c.ledger.record(started.id)?.transfer.resumeAvailable, true)
        // With no resume data WebKit cannot continue it: the task fails rather than claiming a resume.
        let b = c.begin(suggestedName: "n.bin", sourceURL: source, cancel: {})
        c.fail(b.id, source: source, error: URLError(.networkConnectionLost), willRetry: false)
        XCTAssertNotEqual(c.ledger.record(b.id)?.transfer.resumeAvailable, true)
    }
}

// MARK: - Scope and wiring (source scans)

final class BrowserIntegrationScopeTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testThereIsStillOneCoordinatorAndOneDelegateForWebKitDownloads() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        XCTAssertEqual(engine.components(separatedBy: "DownloadCoordinator()").count - 1, 1)
        XCTAssertEqual(engine.components(separatedBy: ": NSObject, WKDownloadDelegate").count - 1, 1)
        XCTAssertEqual(engine.components(separatedBy: "didBecome download: WKDownload").count - 1, 2)
    }

    func testBothHandoffsGoThroughAdopt() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        XCTAssertFalse(engine.contains("download.delegate = downloads"), "a download must be adopted, not given the delegate directly")
        XCTAssertEqual(engine.components(separatedBy: "downloads.adopt(download)").count - 1, 2)
    }

    func testTheIntegrationHelpersTouchNeitherWebKitNorTheNetwork() throws {
        let text = try source("Shared/Downloads/Browser/BrowserDownloadIntegration.swift")
        for forbidden in ["WKWebView", "URLSession", "startDownload", "scheduleDownload", "Process(", "NWConnection"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }

    func testPeerToPeerIsNeverStartedByTheBrowserIntegration() throws {
        let text = try source("Shared/Downloads/Browser/BrowserDownloadIntegration.swift")
        XCTAssertFalse(text.contains("TorrentRunner")); XCTAssertFalse(text.contains("ED2KRunner"))
    }

    func testNoAutomaticLinkInterceptionWasAdded() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        XCTAssertFalse(engine.contains("magnet:") && engine.contains("scheme == \"magnet\""))
        XCTAssertFalse(engine.contains("ed2k://"))
    }

    func testTheDelegateDoesNotReadPrivacyFromTheWebViewAfterTheStart() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        let start = try XCTUnwrap(engine.range(of: "final class WebKitDownloads"))
        let tail = String(engine[start.lowerBound...])
        XCTAssertFalse(tail.contains("download.webView?.configuration"), "privacy is read from the recorded context, in any spelling")
        XCTAssertFalse(tail.contains("isPersistent != false"))
        XCTAssertFalse(tail.contains("isPersistent == false"))
    }
}

// MARK: - Real WebKit downloads against the local fixture

@MainActor
final class BrowserWebKitDownloadTests: XCTestCase {
    private var scratch: URL!
    private var coordinator: DownloadCoordinator!
    private var delegate: WebKitDownloads!
    private var handler: PolicyDelegate!
    private var views: [WKWebView] = []

    /// The same two decisions the engine makes: an attachment (or something the page cannot show) becomes a download, and so does a link marked as one.
    final class PolicyDelegate: NSObject, WKNavigationDelegate {
        let downloads: WebKitDownloads
        var handoffs = 0
        init(_ d: WebKitDownloads) { downloads = d }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.shouldPerformDownload ? .download : .allow
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let http = navigationResponse.response as? HTTPURLResponse, (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return .download }
            return navigationResponse.canShowMIMEType ? .allow : .download
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { handoffs += 1; downloads.adopt(download) }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { handoffs += 1; downloads.adopt(download) }
    }

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p12-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
        coordinator = DownloadCoordinator()
        delegate = WebKitDownloads(coordinator: coordinator)
        handler = PolicyDelegate(delegate)
        _ = try await fixture("/_reset")
    }
    override func tearDown() async throws {
        views.removeAll()
        DownloadCoordinator.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ path: String) async throws -> Data { try await URLSession.shared.data(from: URL(string: fixtureBase + path)!).0 }
    private func log() async throws -> [[String: Any]] { (try JSONSerialization.jsonObject(with: try await fixture("/_log")) as? [[String: Any]]) ?? [] }

    private func makeView(persistent: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        if !persistent { config.websiteDataStore = .nonPersistent() }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        view.navigationDelegate = handler
        views.append(view)
        return view
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    private func gets(_ path: String) async throws -> [[String: Any]] { try await log().filter { ($0["path"] as? String)?.hasPrefix(path) == true && ($0["method"] as? String) == "GET" } }

    func testAnAttachmentResponseBecomesOneTaskAndOneRequest() async throws {
        let view = makeView()
        view.load(URLRequest(url: URL(string: fixtureBase + "/file/50000?cd=attachment;%20filename%3D%22p12.bin%22")!))
        await wait("the download completes") { self.coordinator.completed.count == 1 }
        XCTAssertEqual(coordinator.ledger.records.count, 1, "one task for the download, not one for the navigation and one for the download")
        let id = try XCTUnwrap(coordinator.ledger.records.keys.first)
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .completed)
        XCTAssertEqual(coordinator.completed.first?.lastPathComponent, "p12.bin")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(coordinator.completed.first)).count, 50000)
        let requests = try await gets("/file/50000")
        XCTAssertEqual(requests.count, 1, "the response became the download without a second request")
        XCTAssertEqual(handler.handoffs, 1)
    }

    func testTheSessionCookieTravelsWithTheDownload() async throws {
        let view = makeView()
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session", .value: "abc123", .secure: false])!
        await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        view.load(URLRequest(url: URL(string: fixtureBase + "/file/40000?cd=attachment;%20filename%3D%22auth.bin%22")!))
        await wait("completes") { self.coordinator.completed.count == 1 }
        let seen = try await gets("/file/40000")
        XCTAssertEqual(seen.count, 1)
        let headers = seen.first?["headers"] as? [String: String]
        XCTAssertEqual(headers?["cookie"]?.contains("session=abc123"), true, "WebKit kept the session")
        // Nothing in this path hands the cookie to the app's own engines.
        XCTAssertTrue(coordinator.ledger.records.values.allSatisfy { $0.protocolID == .webKit })
    }

    func testALinkMarkedAsADownloadIsHandedOverOnce() async throws {
        let view = makeView()
        let html = "<html><body><a id='a' href='\(fixtureBase)/file/20000' download='linked.bin'>get</a></body></html>"
        view.loadHTMLString(html, baseURL: URL(string: fixtureBase)!)
        await wait("page loaded") { !view.isLoading && view.url != nil }
        _ = try? await view.evaluateJavaScript("document.getElementById('a').click()")
        await wait("completes") { self.coordinator.completed.count == 1 }
        XCTAssertEqual(coordinator.ledger.records.count, 1)
        XCTAssertEqual(handler.handoffs, 1)
    }

    func testCancellingASlowDownloadRecordsACancellationAndLeavesNoFile() async throws {
        let view = makeView()
        view.load(URLRequest(url: URL(string: fixtureBase + "/slow/3000000?ms=40&cd=attachment;%20filename%3D%22slow.bin%22")!))
        await wait("it started") { !self.coordinator.active.isEmpty }
        let id = try XCTUnwrap(coordinator.active.keys.first)
        let destination = try XCTUnwrap(coordinator.destination(of: id))
        coordinator.cancel(id)
        await wait("it settled") { self.coordinator.active.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .cancelled)
        XCTAssertTrue(coordinator.failures.isEmpty, "a cancellation is not a failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(coordinator.ledger.records.count, 1)
    }

}
