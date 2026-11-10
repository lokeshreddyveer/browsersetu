import XCTest
import AppKit
import WebKit
@testable import Browser_Setu

/// DX-07 against a real WKWebView and an independent local website (scripts/media_discovery_fixture.py, two origins). Skipped unless DX07_LIVE=1 and the fixture is running.
/// The web view is wired exactly as the engine wires a tab: the observer is installed with `MediaPageObserver.install`, its messages go through the same parser into a tab's
/// MediaObservationBuffer, and a committed navigation empties the buffer.
@MainActor
final class DX07LiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX07_LIVE"] == "1") }
    private let site = "http://127.0.0.1:18840", embedOrigin = "http://localhost:18841"

    private final class Tab: NSObject, WKNavigationDelegate {
        let web: WKWebView
        let buffer = MediaObservationBuffer()
        var finished = false
        var observations: [MediaObservation] = []
        private var window: NSWindow?
        init(observe: Bool = true) {
            let config = WKWebViewConfiguration()
            config.mediaTypesRequiringUserActionForPlayback = []
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            super.init()
            web.navigationDelegate = self
            // A page in a window that is not on screen is hidden to the page (document.visibilityState), and the observer rightly does nothing for a hidden page.
            let w = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = web; w.level = .floating; w.makeKeyAndOrderFront(nil); window = w
            MediaPageObserver.install(in: config.userContentController) { [weak self] _, o in
                guard let self else { return }
                self.observations.append(o)
                self.buffer.accept(o)
            }
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { buffer.navigated() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    private func open(_ path: String, in tab: Tab, origin: String? = nil) async {
        tab.finished = false
        tab.web.load(URLRequest(url: URL(string: (origin ?? site) + path)!))
        for _ in 0..<200 where !tab.finished { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    private func wait(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }
    private func expect(_ message: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let ok = await wait(seconds, condition)
        XCTAssertTrue(ok, message, file: file, line: line)
    }
    private func store() -> MediaDiscoveryStore { MediaDiscoveryStore(profile: "live", isPrivate: false) }
    private func ingest(_ tab: Tab, into s: MediaDiscoveryStore) { s.ingest(MediaPageSnapshot(hits: tab.buffer.hits(), truncated: false), pageKey: "1|live", pageHost: "127.0.0.1", removeMissing: false) }
    private func href(_ h: MediaPageHit) -> String { h.href ?? "(none)" }

    func testStaticVideoIsFoundWithItsRealSizeDurationAndCaptionTrack() async throws {
        let tab = Tab(); await open("/static", in: tab)
        await expect("loadedmetadata reported") { tab.buffer.hits().contains { $0.method == .mediaEvent && ($0.width ?? 0) > 0 } }
        let h = try XCTUnwrap(tab.buffer.hits().first)
        print("LIVE static:", href(h), h.width ?? -1, h.height ?? -1, h.duration ?? -1, h.tracks.map { $0.language ?? "?" }, h.frame?.origin ?? "?", h.frame?.isMain ?? false)
        XCTAssertEqual(h.href, site + "/media/clip.mp4"); XCTAssertEqual(h.frame?.origin, site); XCTAssertEqual(h.frame?.isMain, true)
        XCTAssertNotNil(h.duration); XCTAssertEqual(h.tracks.first?.language, "te"); XCTAssertEqual(h.hasVideo, true)
        // The fixture is on this Mac, and page discovery refuses local-network addresses (Phase 18), so the list says so instead of offering a download; everything observed is still kept.
        let s = store(); ingest(tab, into: s)
        if case .unsupported(let why) = s.candidates.first?.state { XCTAssertTrue(why.contains("own network")) } else { XCTFail("a loopback address is refused from page discovery") }
        XCTAssertNotNil(s.candidates.first?.qualityLabel); XCTAssertEqual(s.candidates.first?.players.count, 1); XCTAssertFalse(s.candidates.first?.canOpen ?? true)
    }

    func testAnAudioPlayerIsAudio() async throws {
        let tab = Tab(); await open("/audio", in: tab)
        await expect("") { tab.buffer.hits().contains { $0.element == "audio" } }
        let h = try XCTUnwrap(tab.buffer.hits().first)
        XCTAssertEqual(h.element, "audio"); XCTAssertEqual(h.hasVideo, false)
        let s = store(); ingest(tab, into: s)
        XCTAssertEqual(s.candidates.first?.qualityLabel, "Audio only"); XCTAssertEqual(s.candidates.first?.mechanism, .audioElement)
    }

    func testSeveralPlayersAreSeparatedAndOneSharedSourceIsOneItemWithTwoPlayers() async throws {
        let tab = Tab(); await open("/multi", in: tab)
        await expect("") { tab.buffer.playerCount == 4 }
        let s = store(); ingest(tab, into: s)
        print("LIVE multi:", s.candidates.map { ($0.url ?? "-", $0.players.count) })
        XCTAssertEqual(s.candidates.count, 3)
        XCTAssertEqual(s.candidates.first { $0.url == site + "/media/clip.mp4" }?.players.count, 2)
        XCTAssertEqual(s.candidates.first { $0.url == site + "/media/clip2.mp4" }?.players.count, 1)
    }

    func testAPlayerAddedLaterAndASourceChangedLaterAreFollowed() async throws {
        let late = Tab(); await open("/dynamic", in: late)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let diag = try? await late.web.callAsyncJavaScript("return [document.visibilityState, document.querySelectorAll('video').length, typeof window.__bsMedia, document.readyState].join(',');", contentWorld: .defaultClient)
        print("LIVE dynamic-diag:", diag ?? "nil")
        _ = try? await late.web.callAsyncJavaScript("window.__bsMedia.rescan(); return 1;", contentWorld: .defaultClient)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("LIVE dynamic-after-rescan:", late.observations.map { "\($0.kind)/\($0.player ?? -1)" })
        print("LIVE dynamic:", late.observations.map { "\($0.kind)/\($0.player ?? -1)/\($0.current ?? "-")/\($0.attributeSource ?? "-")" })
        await expect("a video created by script after load") { late.buffer.hits().contains { $0.href == self.site + "/media/clip.mp4" } }
        let changing = Tab(); await open("/changing", in: changing)
        // The first source may never be reported on its own: updates are coalesced, so only where the player ends up is asserted.
        await expect("the source was re-pointed") { changing.buffer.hits().contains { $0.href == self.site + "/media/clip2.mp4" } }
        XCTAssertEqual(changing.buffer.hits().filter { $0.player != nil }.count, 1, "one player, now playing the other file")
        XCTAssertEqual(changing.buffer.playerCount, 1)
    }

    func testAnSPARouteChangeThatSwapsThePlayerLeavesOnlyTheNewOne() async throws {
        let tab = Tab(); await open("/spa", in: tab)
        await expect("") { tab.buffer.hits().contains { $0.href == self.site + "/media/clip.mp4" } }
        let navigation = tab.buffer.navigation
        await expect("") { tab.buffer.hits().contains { $0.href == self.site + "/media/clip2.mp4" } }
        await expect("the old element left the DOM, so its player is gone") { tab.buffer.hits().filter { $0.href == self.site + "/media/clip.mp4" }.isEmpty }
        XCTAssertEqual(tab.buffer.navigation, navigation, "no document was committed: it is one page")
    }

    func testFramesGetTheirOwnOriginFromWebKit() async throws {
        let same = Tab(); await open("/iframe-same", in: same)
        await expect("") { !same.buffer.hits().isEmpty }
        let a = try XCTUnwrap(same.buffer.hits().first)
        XCTAssertEqual(a.frame?.isMain, false); XCTAssertEqual(a.frame?.origin, site, "a same-origin frame")
        let cross = Tab(); await open("/iframe-cross", in: cross)
        await expect("") { !cross.buffer.hits().isEmpty }
        let b = try XCTUnwrap(cross.buffer.hits().first)
        print("LIVE cross:", href(b), b.frame?.origin ?? "?", b.frame?.isMain ?? true)
        XCTAssertEqual(b.frame?.origin, embedOrigin); XCTAssertEqual(b.frame?.isMain, false); XCTAssertEqual(b.href, embedOrigin + "/media/clip.mp4")
        let nested = Tab(); await open("/nested", in: nested)
        await expect("") { !nested.buffer.hits().isEmpty }
        XCTAssertEqual(nested.buffer.hits().first?.frame?.origin, embedOrigin); XCTAssertEqual(nested.buffer.hits().first?.frame?.isMain, false)
        let s = store(); ingest(cross, into: s)
        XCTAssertTrue(s.candidates.first?.isEmbedded ?? false); XCTAssertEqual(s.candidates.first?.frameOrigins, [embedOrigin])
    }

    func testASandboxedFrameIsReportedHonestlyWhateverWebKitAllows() async throws {
        let tab = Tab(); await open("/sandbox", in: tab)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let frames = tab.observations.filter { $0.kind == .hello && !$0.frame.isMain }.count
        print("LIVE sandbox: frames announced =", frames, "players =", tab.buffer.playerCount)
        print("LIVE sandbox-detail:", tab.observations.map { "\($0.kind)/\($0.frame.isMain)/\($0.frame.origin)" }, "frameCount =", tab.buffer.frameCount, "unobserved =", tab.buffer.unobservedFrames, "sandboxed =", tab.buffer.sandboxedFrames)
        // WebKit does not run the observer in a sandboxed frame that may not run scripts, and nothing else may read that frame. What must hold: nothing is invented, and the limit is named.
        XCTAssertEqual(tab.buffer.playerCount, 0)
        await expect("the page's own document reports its sandboxed frame") { tab.buffer.sandboxedFrames == 1 && tab.buffer.unobservedFrames == 1 }
    }

    func testARemovedPlayerLeavesTheListWithItsPlayer() async throws {
        let tab = Tab(); await open("/removed", in: tab)
        await expect("") { tab.buffer.playerCount == 1 }
        let s = store(); ingest(tab, into: s)
        XCTAssertEqual(s.candidates.count, 1)
        await expect("the element was removed from the page") { tab.buffer.playerCount == 0 }
        let gone = tab.observations.last { $0.kind == .gone }
        let o = try XCTUnwrap(gone)
        s.removePlayers(inFrame: o.frame.token, player: o.player)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testAnExpiredSignedAddressIsMarkedAndNeverShownWithItsSignature() async throws {
        let past = Tab(); await open("/expiring?exp=1000000000", in: past)
        await expect("") { !past.buffer.hits().isEmpty }
        let s = store(); ingest(past, into: s)
        XCTAssertTrue(s.candidates.first?.isExpired() ?? false); XCTAssertFalse(s.candidates.first?.canOpen ?? true)
        XCTAssertFalse(s.candidates.first?.display.contains("SECRETSIG") ?? false)
        let future = Tab(); await open("/expiring?exp=4000000000", in: future)
        await expect("") { !future.buffer.hits().isEmpty }
        let t = store(); ingest(future, into: t)
        XCTAssertFalse(t.candidates.first?.isExpired() ?? true); XCTAssertNotNil(t.candidates.first?.expiresAt)
    }

    func testPlaylistsLoadedByScriptAndAnHLSSourceAreRecognised() async throws {
        let tab = Tab(); await open("/hls", in: tab)
        await expect("an XHR playlist is in Resource Timing") { tab.buffer.hits().contains { $0.method == .manifestReference && ($0.href ?? "").hasSuffix("v720.m3u8") } }
        let hits = tab.buffer.hits()
        print("LIVE hls:", hits.map { ($0.href ?? "-", $0.method.rawValue) })
        XCTAssertTrue(hits.contains { MediaClassifier.role(url: $0.href ?? "", type: "") == .hls }); XCTAssertTrue(hits.contains { MediaClassifier.role(url: $0.href ?? "", type: "") == .dash })
        XCTAssertFalse(hits.contains { ($0.href ?? "").hasSuffix(".ts") })
    }

    func testABlobBackedPlayerIsAnInPageStreamWithNoAddress() async throws {
        let tab = Tab(); await open("/blob", in: tab)
        await expect("") { tab.buffer.hits().contains { $0.blob } }
        let s = store(); ingest(tab, into: s)
        XCTAssertEqual(s.candidates.first?.kind, .blob); XCTAssertNil(s.candidates.first?.url); XCTAssertFalse(s.candidates.first?.canOpen ?? true)
    }

    func testAPlayerThatHasNotChosenASourceYetOffersItsDeclaredSourcesAsDeclared() async throws {
        let tab = Tab(); await open("/lazy", in: tab)
        await expect("") { !tab.buffer.hits().isEmpty }
        let hits = tab.buffer.hits()
        print("LIVE lazy:", hits.map { ($0.href ?? "-", $0.method.rawValue) })
        XCTAssertTrue(hits.allSatisfy { $0.method == .sourceElement || $0.method == .mediaElement || $0.method == .mediaEvent })
    }

    func testNavigatingAwayEmptiesTheBufferAndANewPageStartsClean() async throws {
        let tab = Tab(); await open("/static", in: tab)
        await expect("") { tab.buffer.playerCount == 1 }
        let before = tab.buffer.navigation
        await open("/audio", in: tab)
        XCTAssertGreaterThan(tab.buffer.navigation, before)
        await expect("") { tab.buffer.hits().contains { $0.element == "audio" } }
        XCTAssertFalse(tab.buffer.hits().contains { $0.href?.hasSuffix("clip.mp4") == true }, "nothing of the earlier page remains")
    }

    func testAPageThatFloodsThePageWithPlayersIsBounded() async throws {
        let tab = Tab(); await open("/static", in: tab)
        _ = try? await tab.web.callAsyncJavaScript("for (let i = 0; i < 800; i++) { const v = document.createElement('video'); v.src = '/media/clip.mp4?i=' + i; document.body.appendChild(v); } return 1;", contentWorld: .page)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("LIVE flood: players =", tab.buffer.playerCount, "dropped =", tab.buffer.dropped, "messages =", tab.observations.count)
        XCTAssertLessThanOrEqual(tab.buffer.playerCount, MediaObservationBuffer.maxPlayersPerFrame)
        XCTAssertLessThan(tab.observations.count, 400, "the page script coalesces and caps what it sends")
    }

    func testThePageCannotCallTheObserverOrSeeItsTokenFromItsOwnWorld() async throws {
        let tab = Tab(); await open("/static", in: tab)
        let seen = try await tab.web.callAsyncJavaScript("return [typeof window.__bsMedia, typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsMedia)].join(',');", contentWorld: .page) as? String
        XCTAssertEqual(seen, "undefined,undefined")
        // A forged message sent from the page's own world cannot reach the handler.
        _ = try? await tab.web.callAsyncJavaScript("try { window.webkit.messageHandlers.bsMedia.postMessage({t:'player', f:'forged', p:1, tag:'video', cur:'https://evil.example/x.mp4'}); } catch (e) {} return 1;", contentWorld: .page)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(tab.observations.contains { $0.frame.token == "forged" })
        XCTAssertFalse(tab.buffer.hits().contains { $0.href == "https://evil.example/x.mp4" })
    }
}
