import XCTest
@testable import Browser_Setu

/// Measures what the screens call while drawing (they must be cheap) and what is expensive (it must never run on the main thread). The numbers are printed (`RESPONSIVENESS …`) and bounded.
@MainActor
final class ResponsivenessTests: XCTestCase {
    func time(_ name: String, runs: Int = 1, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(runs)
        print("RESPONSIVENESS \(name): \(String(format: "%.3f", ms)) ms per call (\(runs) runs)")
        return ms
    }

    override func setUp() async throws { RealTool.use(); try RealFFmpeg.use() }
    override func tearDown() async throws { RealFFmpeg.reset(); BundledExtractor.helpersFolder = nil; BundledExtractor.forgetCache() }

    func testWhatTheScreensAskWhileDrawingIsCheapEvenWithTheLargeTree() async throws {
        // Warm: what a SwiftUI body may call. Each must be far below a frame (16 ms), measured with the real 124 MB extractor tree and the real FFmpeg tree in place.
        XCTAssertLessThan(time("ExtractorChoice.isAvailable", runs: 200) { _ = ExtractorChoice.isAvailable }, 2)
        XCTAssertLessThan(time("BundledExtractor.isPresent", runs: 200) { _ = BundledExtractor.isPresent }, 2)
        XCTAssertLessThan(time("DownloadPlanner.processingReady", runs: 200) { _ = DownloadPlanner.processingReady }, 2)
        let src = NormalizedMediaSource(title: "t", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([
            NormalizedRepresentation(role: .video, url: URL(string: "https://c.example/v.webm")!, container: "webm", codecs: "vp9", height: 720, formatID: "v"),
            NormalizedRepresentation(role: .audio, url: URL(string: "https://c.example/a.webm")!, container: "webm", codecs: "opus", formatID: "a")]))
        XCTAssertLessThan(time("DownloadPlanner.options", runs: 50) { _ = DownloadPlanner.options(for: src) }, 5)
    }

    // MARK: One address rule for every route

    func testEveryRouteAppliesTheSameAddressRule() {
        func cand(_ href: String) -> MediaCandidate {
            let store = MediaDiscoveryStore(profile: "t", isPrivate: false)
            _ = store.ingest(MediaPageSnapshot(hits: [MediaPageHit(href: href, element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: true)], truncated: false), pageKey: "1|p", pageHost: "site.example", removeMissing: false)
            return store.candidates[0]
        }
        let page = URL(string: "https://site.example/watch?v=1")!
        let ctx = RouterContext(extractorConfigured: true)
        let local = RouterContext(extractorConfigured: true, allowLocal: true)
        // A page may not point the browser at the local network through a playlist, a direct file, a plain file link or a video page.
        for bad in ["http://192.168.1.5/live.m3u8", "http://127.0.0.1/a.mpd", "http://169.254.169.254/x.m3u8", "ftp://example.com/a.m3u8", "file:///etc/hosts.m3u8"] {
            if case .stream = DownloadRouter.route(.candidate(cand(bad), pageURL: page), ctx) { XCTFail("candidate \(bad) must not route") }
            if case .stream = DownloadRouter.route(.file(URL(string: bad)!, category: .video), ctx) { XCTFail("file \(bad) must not route") }
        }
        if case .tracks = DownloadRouter.route(.candidate(cand("http://10.0.0.7/clip.mp4"), pageURL: page), ctx) { XCTFail("a private-network clip from a page") }
        if case .tracks = DownloadRouter.route(.file(URL(string: "http://localhost:8000/a.mp3")!, category: .audio), ctx) { XCTFail("a localhost sound from a page") }
        if case .extractor = DownloadRouter.route(.videoPage(URL(string: "http://192.168.0.1/video")!, provider: nil), ctx) { XCTFail("a router admin page is not handed to the extractor") }
        // Public addresses are untouched, and an address the person typed may name their own network.
        if case .stream = DownloadRouter.route(.candidate(cand("https://cdn.example/live.m3u8"), pageURL: page), ctx) {} else { XCTFail("a public playlist routes") }
        if case .tracks = DownloadRouter.route(.file(URL(string: "https://cdn.example/a.mp3")!, category: .audio), ctx) {} else { XCTFail("a public sound routes") }
        if case .stream = DownloadRouter.route(.file(URL(string: "http://192.168.1.5/live.m3u8")!, category: .video), local) {} else { XCTFail("a typed LAN playlist routes") }
        if case .tracks = DownloadRouter.route(.file(URL(string: "http://nas.local:8080/a.mp3")!, category: .audio), local) {} else { XCTFail("a typed LAN file routes") }
    }

    // MARK: A program that could not run is not an answer about the page

    func testOnlyTheProgramsOwnVerdictOnAPageIsRememberedAsFoundNothing() {
        XCTAssertTrue(ExtractorBroker.isNotAnAnswer(CancellationError()))
        let setup: [ExtractorFailure] = [.timedOut, .tooManyRunning, .notConfigured, .missing("x"), .notExecutable("x"), .unsafeLocation("changed"), .badAddress, .failed(137, "")]
        for e in setup { XCTAssertTrue(ExtractorBroker.isNotAnAnswer(e), "\(e) says nothing about the page") }
        let verdicts: [ExtractorFailure] = [.noFormats("none"), .malformed("bad json"), .wrongVideo, .tooMuchOutput, .failed(1, "ERROR: Unsupported URL")]
        for e in verdicts { XCTAssertFalse(ExtractorBroker.isNotAnAnswer(e), "\(e) is the program's own verdict: remembered briefly") }
    }

    // MARK: Choosing a stream in the picker opens the add-download form for it

    func testChoosingAStreamInThePickerOpensDownloadsWithItsAddressReadyAndDoesNotStartAnythingBlindly() {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pick-\(UUID().uuidString)", profile: "default")
        let store = model.mediaDiscovery
        let hit = MediaPageHit(href: "https://cdn.example/s/master.m3u8", element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: true)
        _ = store.ingest(MediaPageSnapshot(hits: [hit], truncated: false), pageKey: "k", pageHost: "site.example", removeMissing: false)
        let id = store.candidates[0].id
        model.panelMode = .float
        let before = model.engine.downloads.ledger.records.count
        let route = model.openDiscoveredMedia(id)
        XCTAssertEqual(route, .mediaPreview(URL(string: "https://cdn.example/s/master.m3u8")!))
        XCTAssertEqual(model.addDownloadPrefill, "https://cdn.example/s/master.m3u8", "the add-download form is given the stream's address")
        XCTAssertEqual(model.addDownloadPrefillOrigin, .page, "and knows it came from a page (so a page cannot aim it at the local network)")
        XCTAssertEqual(model.floatingPanel, .downloads, "Downloads is brought up")
        XCTAssertEqual(model.engine.downloads.ledger.records.count, before, "a stream is never started without the person choosing its quality")
        // Choosing again while Downloads is already open (the picker lives inside it) must not close it: that is how "Choose & Download…" used to do nothing.
        _ = model.openDiscoveredMedia(id)
        XCTAssertEqual(model.floatingPanel, .downloads, "still open")
    }

    func testChoosingAStreamInTabModeOpensOneDownloadsTabAndNeverToggleOrDuplicatesIt() {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-tabmode-\(UUID().uuidString)", profile: "default")
        model.panelMode = .tab
        let store = model.mediaDiscovery
        let hit = MediaPageHit(href: "https://cdn.example/s/master.m3u8", element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: true)
        _ = store.ingest(MediaPageSnapshot(hits: [hit], truncated: false), pageKey: "k", pageHost: "site.example", removeMissing: false)
        let id = store.candidates[0].id
        let panelURL = TabController.panelURL(.downloads)
        func downloadsTabs() -> Int { model.tabs.filter { $0.url == panelURL }.count }
        XCTAssertEqual(downloadsTabs(), 0)
        _ = model.openDiscoveredMedia(id)
        XCTAssertEqual(downloadsTabs(), 1, "the first request opens Downloads as a tab")
        let tab = model.active?.id
        _ = model.openDiscoveredMedia(id); model.openFeeds(); _ = model.openDiscoveredMedia(id)
        XCTAssertEqual(downloadsTabs(), 1, "later requests (from inside it too) reuse that tab: no second tab, no toggle that closes it")
        XCTAssertEqual(model.active?.id, tab, "and it stays the one in front")
        XCTAssertTrue(model.feedsRequested, "the feed sheet request is waiting for the Downloads view to take it")
    }

    // MARK: A master playlist is one entry

    func testAMasterPlaylistFoldsItsOwnVariantsAwayOnlyOnceItIsReadAndStandalonePlaylistsStay() async throws {
        let store = MediaDiscoveryStore(profile: "t", isPrivate: false)
        func hit(_ href: String) -> MediaPageHit { MediaPageHit(href: href, element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: true) }
        let base = "https://cdn.example/s/"
        _ = store.ingest(MediaPageSnapshot(hits: ["master.m3u8", "v360.m3u8", "v720.m3u8", "a-en.m3u8", "standalone.m3u8"].map { hit(base + $0) }, truncated: false), pageKey: "1|p", pageHost: "site.example", removeMissing: false)
        XCTAssertEqual(store.ranked.count, 5, "before the master is read, nothing is known about how they relate: all are shown")
        let master = try XCTUnwrap(store.candidates.first { $0.url?.hasSuffix("master.m3u8") == true })
        func stream(_ id: String, _ file: String, h: Int, kind: MediaStream.Kind = .video) -> MediaStream {
            MediaStream(id: id, kind: kind, label: "\(h)p", language: nil, codecs: nil, bandwidth: h * 1000, width: nil, height: h, container: .fragmentedMP4, playlistURL: base + file, initSegment: nil, segments: [], duration: nil)
        }
        var manifest = MediaManifest(format: .hls, sourceURL: base + "master.m3u8", duration: 10, videos: [stream("v1", "v360.m3u8", h: 360), stream("v2", "v720.m3u8", h: 720)],
                                     audios: [stream("a1", "a-en.m3u8", h: 0, kind: .audio)], subtitles: [], unsupported: nil, fingerprint: "f", warnings: [])
        manifest.videos[0].playlistURL = base + "v360.m3u8?x=1"          // a different query is a different address: not folded
        store.inspect(master.id) { _ in manifest }
        for _ in 0..<100 where store.candidates.first(where: { $0.id == master.id })?.state != .inspected { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.candidates.first { $0.id == master.id }?.state, .inspected)
        let shown = Set(store.ranked.compactMap { $0.url?.components(separatedBy: "/").last })
        XCTAssertEqual(shown, ["master.m3u8", "v360.m3u8", "standalone.m3u8"], "v720 and the audio playlist are folded into the master; the 360p one (listed with another address), and a playlist no master names, stay: \(shown)")
        XCTAssertEqual(store.candidates.count, 5, "nothing is deleted, only not listed twice")
    }

    func testTheInstallerLockIsWaitedForBrieflyThenGivenUpOn() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".lock").path
        let holder = open(path, O_CREAT | O_RDWR, 0o600); XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        // Held for a short moment (like the cleanup at launch): the waiter gets it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { flock(holder, LOCK_UN) }
        let waiter = open(path, O_RDWR); defer { close(waiter) }
        let start = Date()
        XCTAssertTrue(MediaToolsInstall.lockBriefly(waiter, seconds: 3)); XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        flock(waiter, LOCK_UN)
        // Held for good (a real second installer): it gives up after the wait, so the person is told.
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let begin = Date()
        XCTAssertFalse(MediaToolsInstall.lockBriefly(waiter, seconds: 0.3)); XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(begin), 0.25)
        flock(holder, LOCK_UN); close(holder)
    }

    func testTheExpensiveChecksAreMeasuredAndTheLookupButtonDoesNotRunThemOnTheMainThread() async throws {
        let root = try XCTUnwrap(BundledExtractor.helpersFolder).appendingPathComponent("yt-dlp", isDirectory: true)
        BundledExtractor.forgetCache()
        let stampMs = time("stamp of the extractor tree (cold)") { _ = ManagedTool.stamp(root) }
        let coldStart = Date()
        let cold = await BundledExtractor.verifyAsync()
        print("RESPONSIVENESS verify of the extractor tree, cold, off the main thread: \(Int(Date().timeIntervalSince(coldStart) * 1000)) ms")
        XCTAssertNotNil(cold)
        let warm = time("verify (warm cache; includes the stamp)") { _ = BundledExtractor.verify() }
        print("RESPONSIVENESS stamp \(stampMs) ms, warm verify \(warm) ms")
        // The main actor must stay responsive while the cold check runs: a ticker on the main actor keeps ticking.
        BundledExtractor.forgetCache()
        var ticks = 0
        let ticker = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 10_000_000) } }
        _ = try await ExtractorChoice.resolveAsync()
        ticker.cancel()
        print("RESPONSIVENESS main-actor ticks during a cold resolveAsync: \(ticks)")
        XCTAssertGreaterThanOrEqual(ticks, 2, "the main actor kept running during the cold check (a blocked one would manage 0 or 1 tick)")
    }
}
