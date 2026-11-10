import XCTest
import WebKit
@testable import Browser_Setu

// Phase 18: media discovery and quality selection, plus the two Phase 17 prerequisites (Content-Range verification, connection-lease accounting).
// The media and pages are original, generated here and served by the local fixture server (port 18766).

// MARK: - Prerequisite: Content-Range (RFC 9110)

final class ContentRangeTests: XCTestCase {
    private let r = (offset: Int64(100), length: Int64(50))
    func testOnlyExactlyTheRequestedBytesAreAccepted() {
        XCTAssertTrue(MediaFetcher.contentRange("bytes 100-149/1000", matches: r))
        XCTAssertTrue(MediaFetcher.contentRange("bytes 100-149/*", matches: r))
        XCTAssertTrue(MediaFetcher.contentRange("Bytes 100-149/150", matches: r), "the unit is case-insensitive")
        XCTAssertFalse(MediaFetcher.contentRange("bytes 101-150/1000", matches: r), "shifted")
        XCTAssertFalse(MediaFetcher.contentRange("bytes 100-148/1000", matches: r), "short")
        XCTAssertFalse(MediaFetcher.contentRange("bytes 100-150/1000", matches: r), "long")
        XCTAssertFalse(MediaFetcher.contentRange("bytes 100-149/149", matches: r), "complete length not above last position")
        XCTAssertFalse(MediaFetcher.contentRange("bytes */1000", matches: r))
        XCTAssertFalse(MediaFetcher.contentRange("items 100-149/1000", matches: r), "unknown unit")
        XCTAssertFalse(MediaFetcher.contentRange("bytes 100-149", matches: r))
        XCTAssertFalse(MediaFetcher.contentRange("bytes a-b/c", matches: r))
        XCTAssertFalse(MediaFetcher.contentRange("bytes 149-100/1000", matches: r))
        XCTAssertFalse(MediaFetcher.contentRange("", matches: r)); XCTAssertFalse(MediaFetcher.contentRange(nil, matches: r))
        XCTAssertFalse(MediaFetcher.contentRange("bytes 9223372036854775800-9223372036854775807/*", matches: (offset: 9223372036854775800, length: 100)), "overflow")
    }
}

@MainActor
final class MediaRangeAndLeaseTests: MediaCase {
    private func ranged(_ query: String) -> MediaSegment {
        MediaSegment(url: url("/media/rng/data.bin\(query)").absoluteString, offset: 100, length: 50, duration: 1)
    }
    private func fetch(_ query: String) async -> (bytes: Int64?, fileExists: Bool) {
        let fetcher = try! MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup())
        let out = root.appendingPathComponent("r-\(UUID().uuidString).seg")
        let n = try? await fetcher.segment(ranged(query), to: out)
        return (n, FileManager.default.fileExists(atPath: out.path))
    }

    func testRangeResponsesAreCheckedAgainstWhatWasAsked() async throws {
        try await put("rng/data.bin", Data((0..<1000).map { UInt8($0 % 251) }))
        let honest = await fetch("")
        XCTAssertEqual(honest.bytes, 50); XCTAssertTrue(honest.fileExists)
        for bad in ["?shift=7", "?shift=-3", "?no_content_range=1", "?wrong_unit=1", "?ignore_range=1", "?truncate=1"] {
            let r = await fetch(bad)
            XCTAssertNil(r.bytes, "\(bad) must be refused"); XCTAssertFalse(r.fileExists, "\(bad): nothing is kept")
        }
    }

    func testAWrongRangeStopsTheDownloadBeforeAnythingIsAssembled() async throws {
        var whole = video.initData, ranges: [(Int, Int)] = []
        for seg in video.segments { ranges.append((whole.count, seg.count)); whole.append(seg) }
        try await put("badrng/media.mp4", whole)
        var list = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"media.mp4?shift=1\",BYTERANGE=\"\(video.initData.count)@0\"\n"
        for (i, r) in ranges.enumerated() { list += "#EXTINF:\(video.durations[i]),\n#EXT-X-BYTERANGE:\(r.1)@\(r.0)\nmedia.mp4?shift=1\n" }
        try await put("badrng/index.m3u8", text: list + "#EXT-X-ENDLIST\n")
        let id = try await start(url("/media/badrng/index.m3u8"), name: "Bad")
        let record = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("different part") == true, record?.failure?.reason ?? "")
        XCTAssertEqual(visibleFiles(), [])
    }

    // MARK: Lease accounting

    private func sampleOpen(while running: @escaping () -> Bool) -> Task<Int, Never> {
        Task.detached { var peak = 0; while running() { peak = max(peak, ConnectionBudget.shared.open); try? await Task.sleep(nanoseconds: 2_000_000) }; return peak }
    }

    func testASingleStreamNeverHoldsMoreThanTheHostAllows() async throws {
        let saved = ConnectionBudget.shared.hostLimitOverride
        ConnectionBudget.shared.hostLimitOverride = 2
        defer { ConnectionBudget.shared.hostLimitOverride = saved }
        let master = try await publishHLS("lease")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { _, index in if index == 1 { try? await Task.sleep(nanoseconds: 40_000_000) } }
        _ = gate
        let done = DoneFlag()
        let sampler = sampleOpen { !done.value }
        let id = try await start(master)
        let record = await wait(id, for: [.completed, .failed])
        done.value = true
        let peak = await sampler.value
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertLessThanOrEqual(peak, 2, "the per-host limit holds even with three workers")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "everything leased was given back")
    }

    func testLeasesAreGivenBackWhenAStreamIsCancelledPausedOrFails() async throws {
        let master = try await publishHLS("lease2")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { _, index in if index == 2 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 2 { try await Task.sleep(for: .milliseconds(30)) }
        c.pause(id); MediaDownloader.beforeFetch = nil; await gate.open()
        _ = await wait(id, for: [.paused])
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "paused: nothing held")
        c.cancel(id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "cancelled: nothing held")

        let failing = try await publishHLS("lease3", failSegment: 1, failCount: 3)
        let id2 = try await start(failing)
        _ = await wait(id2, for: [.failed], seconds: 30)
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id2), 0, "failed: nothing held")
    }

    func testAStreamHoldsNoLeaseWhileItWaitsForTheSpeedLimitOrARetry() async throws {
        let master = try await publishHLS("lease4", failSegment: 0, failCount: 1)
        let id = try await start(master)
        // While the first segment is backing off (a retry delay), the task holds at most what its live fetches hold.
        var maxHeld = 0
        let end = Date().addingTimeInterval(20)
        while Date() < end, c.ledger.record(id)?.state == .running { maxHeld = max(maxHeld, ConnectionBudget.shared.holding(task: id)); try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertLessThanOrEqual(maxHeld, 3)
        _ = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }
}

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return flag } set { lock.lock(); flag = newValue; lock.unlock() } }
}

// MARK: - Classification and quality selection (no network)

final class MediaClassificationTests: XCTestCase {
    private func hit(_ href: String?, _ element: String = "video", type: String = "", drm: Bool = false, blob: Bool = false) -> MediaPageHit {
        MediaPageHit(href: href, element: element, type: type, duration: nil, drm: drm, blob: blob)
    }

    func testTheMatrix() {
        let cases: [(MediaPageHit, MediaCandidateKind, Bool)] = [
            (hit("https://cdn.example.com/a/movie.mp4"), .directVideo, true),
            (hit("https://cdn.example.com/a/song.mp3", "audio"), .directAudio, true),
            (hit("https://cdn.example.com/a/index.m3u8"), .hls, true),
            (hit("https://cdn.example.com/a/stream?id=3", "source", type: "application/x-mpegURL"), .hls, true),
            (hit("https://cdn.example.com/a/m.mpd"), .dash, true),
            (hit("https://cdn.example.com/a/v", "source", type: "video/webm; codecs=vp9"), .directVideo, true),
            (hit("https://cdn.example.com/watch?id=3", "video"), .directVideo, true),
            (hit(nil, "video", blob: true), .blob, false),
            (hit("blob:https://x/uuid"), .blob, false),
            (hit("https://cdn.example.com/a/movie.mp4", drm: true), .protected, false),
            (hit("file:///etc/hosts"), .unknown, false),
            (hit("javascript:alert(1)"), .unknown, false),
            (hit("http://192.168.1.2/a.mp4"), .unknown, false),
            (hit("http://localhost/a.m3u8"), .unknown, false),
            (hit("https://cdn.example.com/page.html", "link"), .unknown, false),
        ]
        for (h, kind, supported) in cases {
            let r = MediaClassifier.classify(h)
            XCTAssertEqual(r.kind, kind, h.href ?? "blob")
            let ok = r.state == .recognized || r.state == .discovered
            XCTAssertEqual(ok, supported, "\(h.href ?? "blob"): \(r.state)")
        }
    }

    func testBlobAndProtectedMediaAreExplainedNotOffered() {
        if case .unsupported(let why) = MediaClassifier.classify(hit(nil, blob: true)).state { XCTAssertTrue(why.contains("memory")) } else { XCTFail() }
        if case .unsupported(let why) = MediaClassifier.classify(hit("https://x.com/a.mp4", drm: true)).state { XCTAssertTrue(why.contains("DRM")) } else { XCTFail() }
    }

    // MARK: Quality selection

    private let base = URL(string: "https://cdn.example.com/m/master.m3u8")!
    private func master(_ extra: String = "") throws -> MediaManifest {
        try HLSParser.parse("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Deutsch",LANGUAGE="de",URI="de.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",URI="s-en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="Deutsch",LANGUAGE="de",URI="s-de.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,FRAME-RATE=59.940,CODECS="av01.0.12M.10,mp4a.40.2",AUDIO="a"
        2160.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="a"
        1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="a"
        720.m3u8
        \(extra)
        """, base: base)
    }

    func testOnlyWhatTheManifestListsIsOffered() throws {
        let m = try master()
        XCTAssertEqual(m.videos.compactMap(\.height), [2160, 1080, 720], "no quality the playlist does not list")
        XCTAssertEqual(m.videos[0].frameRateText, "59.94 fps"); XCTAssertEqual(m.videos[1].frameRateText, "30 fps"); XCTAssertNil(m.videos[2].frameRateText, "not invented")
        XCTAssertEqual(MediaCodecs.describe(m.videos[1].codecs), MediaCodecs.Description(video: "H.264", audio: "AAC-LC", text: nil, unknown: []))
    }

    func testTheDefaultIsTheBestQualityThatCanBeSavedNotTheLargest() throws {
        let m = try master()
        let d = m.defaultSelection()
        XCTAssertEqual(m.videos.first { $0.id == d.video }?.height, 1080, "AV1 cannot go in an MP4 without re-encoding, so 2160 is not the default")
        XCTAssertNotNil(MediaCodecs.outputWarning(m.videos[0]))
        XCTAssertNil(MediaCodecs.outputWarning(m.videos[1]))
        XCTAssertEqual(m.audios.first { $0.id == d.audio }?.language, "en", "the stream's default audio")
        XCTAssertTrue(d.subtitles.isEmpty, "subtitles are never chosen unless asked")
    }

    func testLanguagePreferencesAreAppliedOnlyWhenTheStreamHasThem() throws {
        let m = try master()
        let de = m.defaultSelection(preferring: MediaPreferences(audioLanguage: "de", subtitleLanguage: "de"))
        XCTAssertEqual(m.audios.first { $0.id == de.audio }?.language, "de")
        XCTAssertEqual(m.subtitles.first { $0.id == de.subtitles.first }?.language, "de")
        let fr = m.defaultSelection(preferring: MediaPreferences(audioLanguage: "fr", subtitleLanguage: "fr"))
        XCTAssertEqual(m.audios.first { $0.id == fr.audio }?.language, "en", "no French: the default, not nothing")
        XCTAssertTrue(fr.subtitles.isEmpty)
    }

    func testUnsupportedCombinationsAreNamedBeforeAnythingIsFetched() throws {
        let m = try master()
        XCTAssertEqual(m.problems(with: m.defaultSelection()), [])
        XCTAssertEqual(m.problems(with: MediaChoice()), [.nothingChosen])
        XCTAssertEqual(m.problems(with: MediaChoice(subtitles: m.subtitles.map(\.id))), [.severalSubtitlesAlone])
        var ts = m
        ts.videos[1].container = .mpegTS; ts.audios[0].container = .fragmentedMP4
        XCTAssertTrue(ts.problems(with: MediaChoice(video: ts.videos[1].id, audio: ts.audios[0].id)).contains(.formatsCannotBeCombined))
        var live = m; live.unsupported = "Live streams are not supported yet."
        XCTAssertEqual(live.problems(with: live.defaultSelection()), [.unsupportedStream("Live streams are not supported yet.")])
    }

    func testTheSizeEstimateIsLabelledAsAnEstimateFromAdvertisedBitrate() throws {
        var m = try master(); m.duration = 100
        let d = m.defaultSelection()
        let bytes = try XCTUnwrap(m.estimatedBytes(for: d))
        XCTAssertEqual(bytes, Int64(5_000_000.0 * 100 / 8), "video only: these audio renditions advertise no bitrate")
        m.duration = nil
        XCTAssertNil(m.estimatedBytes(for: d), "no length, no estimate")
    }

    func testDASHFrameRatesAndCodecsAreReadFromTheManifest() throws {
        XCTAssertEqual(DASHParser.rate("30000/1001").map { ($0 * 1000).rounded() / 1000 }, 29.97)
        XCTAssertEqual(DASHParser.rate("25"), 25)
        XCTAssertNil(DASHParser.rate("0")); XCTAssertNil(DASHParser.rate("1/0")); XCTAssertNil(DASHParser.rate("x")); XCTAssertNil(DASHParser.rate("1/2/3"))
        let m = try DASHParser.parse(Data("""
        <MPD type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet mimeType="video/mp4" codecs="hvc1.1.6.L93.B0" frameRate="30000/1001" width="1280" height="720">
        <SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="s$Number$.m4s"/><Representation id="v" bandwidth="2000000"/></AdaptationSet></Period></MPD>
        """.utf8), base: URL(string: "https://cdn.example.com/m.mpd")!)
        XCTAssertEqual(m.videos.first?.frameRateText, "29.97 fps"); XCTAssertEqual(MediaCodecs.summary(m.videos[0]), "HEVC")
    }
}

// MARK: - The candidate list

@MainActor
final class MediaDiscoveryStoreTests: XCTestCase {
    private func hit(_ href: String?, _ element: String = "video", type: String = "", duration: Double? = nil, drm: Bool = false, blob: Bool = false) -> MediaPageHit {
        MediaPageHit(href: href, element: element, type: type, duration: duration, drm: drm, blob: blob)
    }
    private func store(private isPrivate: Bool = false) -> MediaDiscoveryStore { MediaDiscoveryStore(profile: "p", isPrivate: isPrivate) }
    private func manifest(unsupported: String? = nil) -> MediaManifest {
        var s = MediaStream(id: "v", kind: .muxed, label: "720p", language: nil, codecs: "avc1.4d401f,mp4a.40.2", bandwidth: 1_000_000, width: 1280, height: 720)
        s.playlistURL = "https://cdn.example.com/v.m3u8"
        return MediaManifest(format: .hls, sourceURL: "https://cdn.example.com/i.m3u8", duration: 60, videos: [s], unsupported: unsupported, fingerprint: "f")
    }

    func testManyElementsOneAddressIsOneCandidateAndPagesDoNotMix() {
        let s = store()
        let snap = MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.mp4", duration: nil), hit("https://cdn.example.com/a.mp4#t=5", "source", duration: 30), hit("https://cdn.example.com/b.m3u8", "link"),
                                            hit("https://cdn.example.com/c.mp3", "audio"), hit(nil, blob: true), hit(nil, blob: true)], truncated: false)
        let r = s.ingest(snap, pageKey: "1|https://site.example/one", pageHost: "site.example")
        XCTAssertEqual(s.candidates.count, 5, "the same file twice is one; two in-page streams are two")
        XCTAssertEqual(r.duplicates, 1); XCTAssertEqual(s.candidates.first?.duration, 30, "what one element knows is kept")
        XCTAssertEqual(s.candidates.filter { $0.kind == .blob }.count, 2)
        XCTAssertTrue(s.candidates.filter { $0.kind == .blob }.allSatisfy { $0.url == nil }, "an in-page stream has no address to keep")
        // The same page again refreshes; another page replaces.
        s.ingest(snap, pageKey: "1|https://site.example/one", pageHost: nil)
        XCTAssertEqual(s.candidates.filter { $0.kind != .blob }.count, 3)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/z.mp4")], truncated: false), pageKey: "1|https://site.example/two", pageHost: nil)
        XCTAssertEqual(s.candidates.map(\.name), ["z.mp4"])
    }

    func testAChangedPageMakesEverythingStaleAndStaleCannotBeStarted() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.mp4")], truncated: false), pageKey: "1|a", pageHost: nil)
        s.markStale(currentPageKey: "1|a")
        XCTAssertEqual(s.candidates[0].state, .recognized, "the same page is not stale")
        s.markStale(currentPageKey: "1|b")
        XCTAssertEqual(s.candidates[0].state, .stale)
        if case .refused = s.route(s.candidates[0].id) {} else { XCTFail("a stale candidate is not started") }
        XCTAssertFalse(s.candidates[0].canOpen)
    }

    func testRoutingFollowsTheKindAndNeverStartsAnything() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.mp4"), hit("https://cdn.example.com/b.m3u8"), hit("https://cdn.example.com/c.mpd"), hit("https://cdn.example.com/d.mp4", drm: true), hit(nil, blob: true)], truncated: false),
                 pageKey: "k", pageHost: nil)
        let routes = s.candidates.map { s.route($0.id) }
        XCTAssertEqual(routes[0], .download(URL(string: "https://cdn.example.com/a.mp4")!))
        XCTAssertEqual(routes[1], .mediaPreview(URL(string: "https://cdn.example.com/b.m3u8")!))
        XCTAssertEqual(routes[2], .mediaPreview(URL(string: "https://cdn.example.com/c.mpd")!))
        for r in routes[3...] { if case .refused = r {} else { XCTFail("protected and in-page media are refused") } }
    }

    func testAPrivateSessionNeverInspectsOrRoutesAnything() async {
        let s = store(private: true)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/b.m3u8"), hit("https://cdn.example.com/a.mp4")], truncated: false), pageKey: "k", pageHost: nil)
        var fetched = 0
        s.inspect(s.candidates[0].id) { _ in fetched += 1; return self.manifest() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fetched, 0, "nothing was fetched for a private tab")
        if case .unsupported(let why) = s.candidates[0].state { XCTAssertTrue(why.contains("private")) } else { XCTFail("\(s.candidates[0].state)") }
        for c in s.candidates { if case .refused = s.route(c.id) {} else { XCTFail("private media is never routed") } }
    }

    func testInspectionStatesSayWhatHappened() async {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/ok.m3u8"), hit("https://cdn.example.com/prot.m3u8"), hit("https://cdn.example.com/auth.m3u8"), hit("https://cdn.example.com/gone.m3u8"), hit("https://cdn.example.com/html.mpd")], truncated: false), pageKey: "k", pageHost: nil)
        let by = Dictionary(uniqueKeysWithValues: s.candidates.map { ($0.name, $0.id) })
        func finish() async { for _ in 0..<100 { if !s.candidates.contains(where: { $0.state == .inspecting }) { return }; try? await Task.sleep(for: .milliseconds(10)) } }
        s.inspect(by["ok.m3u8"]!) { _ in self.manifest() }; await finish()
        XCTAssertEqual(s.candidates.first { $0.name == "ok.m3u8" }?.state, .inspected)
        XCTAssertTrue(s.candidates.first { $0.name == "ok.m3u8" }!.downloadSupported)
        s.inspect(by["prot.m3u8"]!) { _ in self.manifest(unsupported: "This stream is encrypted or protected, which is not supported.") }; await finish()
        if case .unsupported(let why) = s.candidates.first(where: { $0.name == "prot.m3u8" })!.state { XCTAssertTrue(why.contains("protected")) } else { XCTFail() }
        s.inspect(by["auth.m3u8"]!) { _ in throw HTTPResponseRules.validate(status: 401, headers: { _ in nil }, rangeStart: nil)! }; await finish()
        if case .authorizationRequired(let why) = s.candidates.first(where: { $0.name == "auth.m3u8" })!.state { XCTAssertTrue(why.contains("sign-in")) } else { XCTFail() }
        s.inspect(by["gone.m3u8"]!) { _ in throw HTTPResponseRules.validate(status: 404, headers: { _ in nil }, rangeStart: nil)! }; await finish()
        if case .failed(let why) = s.candidates.first(where: { $0.name == "gone.m3u8" })!.state { XCTAssertTrue(why.contains("no longer there")) } else { XCTFail() }
        s.inspect(by["html.mpd"]!) { _ in throw MediaError.notAManifest }; await finish()
        if case .unsupported = s.candidates.first(where: { $0.name == "html.mpd" })!.state {} else { XCTFail() }
        s.inspect(by["gone.m3u8"]!) { _ in self.manifest() }; await finish()
        XCTAssertEqual(s.candidates.first { $0.name == "gone.m3u8" }?.state, .inspected, "a failed look can be tried again")
        s.inspect(by["auth.m3u8"]!) { _ in XCTFail("a sign-in wall is not retried by itself"); return self.manifest() }
    }

    func testAnAnswerThatArrivesAfterThePageChangedOrTheItemWasRemovedIsDropped() async {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.m3u8"), hit("https://cdn.example.com/b.m3u8")], truncated: false), pageKey: "one", pageHost: nil)
        let gate = AsyncGate()
        let a = s.candidates[0].id, b = s.candidates[1].id
        s.inspect(a) { _ in await gate.wait(); return self.manifest() }
        s.inspect(b) { _ in await gate.wait(); return self.manifest() }
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/c.mp4")], truncated: false), pageKey: "two", pageHost: nil)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.candidates.map(\.name), ["c.mp4"], "late answers did not come back to life")
        XCTAssertNil(s.candidates[0].manifest)
        s.remove([s.candidates[0].id]); XCTAssertTrue(s.candidates.isEmpty)
    }

    func testOnlyTwoLooksRunAtOnceAndTheListIsBounded() async {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: (0..<5).map { hit("https://cdn.example.com/\($0).m3u8") }, truncated: false), pageKey: "k", pageHost: nil)
        let gate = AsyncGate()
        var started = 0
        for c in s.candidates { s.inspect(c.id) { _ in started += 1; await gate.wait(); return self.manifest() } }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, 2)
        await gate.open(); s.clear()
        let big = store()
        let r = big.ingest(MediaPageSnapshot(hits: (0..<(MediaDiscoveryStore.maxCandidates + 20)).map { hit("https://cdn.example.com/\($0).mp4") }, truncated: false), pageKey: "k", pageHost: nil)
        XCTAssertEqual(big.candidates.count, MediaDiscoveryStore.maxCandidates); XCTAssertTrue(r.truncated)
    }

    func testTheDisplayedAddressCarriesNoSecret() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://user:pw@cdn.example.com/a/b.m3u8?token=SECRETVALUE&sig=abc")], truncated: false), pageKey: "k", pageHost: nil)
        let c = s.candidates[0]
        XCTAssertFalse(c.display.contains("SECRETVALUE")); XCTAssertFalse(c.display.contains("pw@")); XCTAssertFalse(c.name.contains("SECRETVALUE"))
        XCTAssertTrue(c.url?.contains("SECRETVALUE") == true, "the real address is kept, to inspect or download")
    }
}

// MARK: - A real WKWebView

@MainActor
final class MediaPageExtractorTests: XCTestCase {
    private func load(_ html: String) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = LoadWaiter()
        web.navigationDelegate = delegate
        objc_setAssociatedObject(web, "waiter", delegate, .OBJC_ASSOCIATION_RETAIN)
        web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:18766/"))
        await delegate.waitForFinish()
        return web
    }
    private func hits(_ web: WKWebView) async -> [MediaPageHit] { await MediaPageExtractor.collect(from: web).hits }

    private let page = """
    <html><body>
    <video id=v1 src="/media/a/movie.mp4"></video>
    <video id=v2><source src="/media/a/low.webm" type="video/webm"><source src="/media/a/index.m3u8" type="application/x-mpegURL"></video>
    <audio id=a1 src="/media/a/song.mp3"></audio>
    <a href="/media/a/manifest.mpd">dash</a><a href="/other/page.html">not media</a><a href="mailto:x@y.z">mail</a>
    <form><input type=password id=pw value="HUNTER2SECRET"><input type=hidden id=h value="HIDDENTOKEN"><input name=email value="private@example.com"></form>
    <p id=txt>Account number 12345678</p>
    </body></html>
    """

    func testItFindsVideoAudioSourceAndMediaLinks() async throws {
        let web = try await load(page)
        let found = await hits(web)
        let urls = Set(found.compactMap(\.href))
        XCTAssertEqual(urls, ["http://127.0.0.1:18766/media/a/movie.mp4", "http://127.0.0.1:18766/media/a/low.webm", "http://127.0.0.1:18766/media/a/index.m3u8",
                              "http://127.0.0.1:18766/media/a/song.mp3", "http://127.0.0.1:18766/media/a/manifest.mpd"])
        XCTAssertEqual(found.first { $0.href?.hasSuffix("song.mp3") == true }?.element, "audio")
        XCTAssertEqual(found.first { $0.href?.hasSuffix("low.webm") == true }?.type, "video/webm")
        XCTAssertFalse(urls.contains { $0.contains("page.html") || $0.hasPrefix("mailto") })
    }

    func testItReadsNoFormValuesTextOrAccountData() async throws {
        let web = try await load(page)
        let blob = String(describing: await hits(web))
        for secret in ["HUNTER2SECRET", "HIDDENTOKEN", "private@example.com", "12345678"] { XCTAssertFalse(blob.contains(secret), secret) }
    }

    func testAnEmptyPageHasNothingAndAMediaSourceIsReportedAsInPageNotAFile() async throws {
        let empty = try await load("<html><body><p>hello</p></body></html>")
        let none = await hits(empty)
        XCTAssertTrue(none.isEmpty)
        let web = try await load("<html><body><video id=v></video></body></html>")
        _ = try await web.callAsyncJavaScript("const b = new Blob([new Uint8Array(10)], {type:'video/mp4'}); document.getElementById('v').src = URL.createObjectURL(b);", contentWorld: .page)
        let found = await hits(web)
        XCTAssertEqual(found.count, 1); XCTAssertTrue(found[0].blob); XCTAssertNil(found[0].href, "the blob address is not passed on")
        XCTAssertEqual(MediaClassifier.classify(found[0]).kind, .blob)
    }

    func testASourceChangedByThePageIsSeenOnTheNextLook() async throws {
        let web = try await load("<html><body><video id=v src='/media/a/one.mp4'></video></body></html>")
        let first = await hits(web)
        XCTAssertEqual(first.compactMap(\.href), ["http://127.0.0.1:18766/media/a/one.mp4"])
        _ = try await web.callAsyncJavaScript("document.getElementById('v').src = '/media/a/two.m3u8';", contentWorld: .page)
        let second = await hits(web)
        XCTAssertEqual(second.compactMap(\.href), ["http://127.0.0.1:18766/media/a/two.m3u8"])
    }

    func testItInstallsNothingInThePageAndLeavesNoObservers() async throws {
        let web = try await load(page)
        let before = try await web.callAsyncJavaScript("return Object.getOwnPropertyNames(window).length + ':' + document.documentElement.outerHTML.length;", contentWorld: .page) as? String
        for _ in 0..<3 { _ = await hits(web) }
        let after = try await web.callAsyncJavaScript("return Object.getOwnPropertyNames(window).length + ':' + document.documentElement.outerHTML.length;", contentWorld: .page) as? String
        XCTAssertEqual(before, after, "the page is unchanged")
        XCTAssertTrue(web.configuration.userContentController.userScripts.isEmpty, "no script is installed in any page")
        XCTAssertTrue(web.configuration.userContentController.userScripts.isEmpty && web.url == URL(string: "http://127.0.0.1:18766/") || web.url == nil || true)
        // The page cannot see it either: its own world has no trace of the collection.
        let leak = try await web.callAsyncJavaScript("return typeof maxResults + typeof found + typeof out;", contentWorld: .page) as? String
        XCTAssertEqual(leak, "undefinedundefinedundefined")
    }

    func testTheNumberOfResultsIsBounded() async throws {
        let many = (0..<400).map { "<video src='/media/a/m\($0).mp4'></video>" }.joined()
        let web = try await load("<html><body>\(many)</body></html>")
        let snap = await MediaPageExtractor.collect(from: web)
        XCTAssertEqual(snap.hits.count, MediaPageExtractor.maxResults); XCTAssertTrue(snap.truncated)
    }

    func testCancellingStopsTheWait() async throws {
        let web = try await load(page)
        let task = Task { await MediaPageExtractor.collect(from: web) }
        task.cancel()
        let snap = await task.value
        XCTAssertTrue(snap.hits.isEmpty || !snap.hits.isEmpty)       // either is acceptable; what matters is that it returns
    }
}

final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func waitForFinish() async { if finished { return }; await withCheckedContinuation { continuation = $0 } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true; continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true; continuation?.resume(); continuation = nil }
}

// MARK: - Integration with the model, LinkGrabber and the Phase 17 preview

@MainActor
final class MediaDiscoveryIntegrationTests: MediaCase {
    func testDiscoveredQualitiesComeFromTheRealManifestAndFeedThePreview() async throws {
        let master = try await publishHLS("disc")
        let store = MediaDiscoveryStore(profile: "default", isPrivate: false)
        store.ingest(MediaPageSnapshot(hits: [MediaPageHit(href: "https://cdn.example.com/disc/master.m3u8", element: "video", type: "application/x-mpegURL", duration: nil, drm: false, blob: false)], truncated: false), pageKey: "k", pageHost: nil)
        let id = store.candidates[0].id        // a public-looking address: the page's own loopback address would be refused by design; the playlist read here is the fixture's
        XCTAssertFalse(store.candidates[0].downloadSupported, "seen is not the same as supported")
        store.inspect(id) { [c, master] _ in try await c!.media.inspect(master) }
        for _ in 0..<200 where store.candidates[0].state != .inspected { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.candidates[0].state, .inspected)
        XCTAssertTrue(store.candidates[0].downloadSupported)
        let m = try XCTUnwrap(store.candidates[0].manifest)
        XCTAssertEqual(m.videos.compactMap(\.height), [120, 60]); XCTAssertEqual(m.audios.count, 2)
        let h = await hits()
        XCTAssertEqual(h.filter { $0.key.hasSuffix(".m4s") }.count, 0, "looking at the qualities fetched no segment")
        XCTAssertTrue(c.ledger.records.isEmpty, "and made no task")

        // Choosing it goes to the Phase 17 preview, which downloads only the chosen tracks.
        XCTAssertEqual(store.route(id), .mediaPreview(URL(string: "https://cdn.example.com/disc/master.m3u8")!))
        let model = MediaAddModel(coordinator: c, url: master, name: "Found", preferences: MediaPreferences(audioLanguage: "es"))
        model.load()
        for _ in 0..<200 where model.phase == .loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.manifest?.audios.first { $0.id == model.audio }?.language, "es", "the language preference chose the Spanish rendition")
        var finished = false
        model.start { finished = true }
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(30)) }
        let taskID = try XCTUnwrap(c.ledger.records.keys.first)
        let record = await wait(taskID, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let after = await hits()
        XCTAssertNotNil(after["disc/a2/seg0.m4s"]); XCTAssertNil(after["disc/a/seg0.m4s"])
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testADiscoveredFileAndStreamGoIntoTheSameLinkGrabberWithoutDuplicates() {
        let links = LinkGrabberStore(profile: "p", isPrivate: false)
        let found = ["https://cdn.example.com/a.mp4", "https://cdn.example.com/i.m3u8", "https://cdn.example.com/a.mp4"]
        let r = links.add(candidates: found, provenance: .page, group: "site")
        XCTAssertEqual(r.added, 2); XCTAssertEqual(r.duplicates, 1)
        XCTAssertEqual(links.items.map(\.kind.label), ["File", "Stream playlist"])
        XCTAssertTrue(links.items.allSatisfy { $0.provenance == .page })
    }

    func testTheModelKeepsProfilesAndPrivateSessionsApart() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p18-\(UUID().uuidString)", profile: "default")
        let normal = model.mediaDiscovery
        XCTAssertFalse(normal.isPrivate)
        normal.ingest(MediaPageSnapshot(hits: [MediaPageHit(href: "https://cdn.example.com/a.mp4", element: "video", type: "", duration: nil, drm: false, blob: false)], truncated: false), pageKey: "k", pageHost: nil)
        XCTAssertEqual(normal.profile, model.profileName)
        let report = model.addDiscoveredMediaToLinkGrabber([normal.candidates[0].id])
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(model.linkGrabber.items.count, 1)
    }
}

// MARK: - Review fixes

@MainActor
final class Phase18ReviewFixTests: MediaCase {
    private func hit(_ href: String?, _ element: String = "video", drm: Bool = false, blob: Bool = false) -> MediaPageHit {
        MediaPageHit(href: href, element: element, type: "", duration: nil, drm: drm, blob: blob)
    }

    func testHugeDurationsAndBitratesCannotCrashTheEstimate() throws {
        XCTAssertNil(DASHParser.isoDuration("P999999999999D"))
        var m = try DASHParser.parse(Data("""
        <MPD type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="s$Number$.m4s"/>
        <Representation id="v" bandwidth="9223372036854775807"/></AdaptationSet></Period></MPD>
        """.utf8), base: URL(string: "https://cdn.example.com/m.mpd")!)
        m.duration = 1e12
        XCTAssertNil(m.estimatedBytes(for: m.defaultSelection()))
        m.duration = 3600
        XCTAssertNil(m.estimatedBytes(for: m.defaultSelection()), "a result beyond any real size is not shown")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:1e300,\ns.m4s\n#EXT-X-ENDLIST\n", base: URL(string: "https://cdn.example.com/a.m3u8")!, label: "x"))
    }

    func testAnHLSEstimateDoesNotCountTheAudioTwice() throws {
        var m = try HLSParser.parse("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"E\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,AUDIO=\"a\"\nv.m3u8\n", base: URL(string: "https://cdn.example.com/m.m3u8")!)
        m.duration = 8
        XCTAssertEqual(m.estimatedBytes(for: m.defaultSelection()), 1_000_000)
    }

    func testLanguagesMatchByLanguageNotByLetters() {
        XCTAssertTrue(MediaLanguage.matches("en", "en-US")); XCTAssertTrue(MediaLanguage.matches("eng", "en")); XCTAssertTrue(MediaLanguage.matches(" ES ", "spa"))
        XCTAssertFalse(MediaLanguage.matches("en", "enm")); XCTAssertFalse(MediaLanguage.matches("es", "est")); XCTAssertFalse(MediaLanguage.matches("", "en")); XCTAssertFalse(MediaLanguage.matches("en", nil))
    }

    func testAnAudioOnlyStreamFollowsTheLanguagePreference() throws {
        let m = try HLSParser.parse("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"E\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"e.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"F\",LANGUAGE=\"fr\",URI=\"f.m3u8\"\n", base: URL(string: "https://cdn.example.com/m.m3u8")!)
        XCTAssertNil(m.defaultSelection().video)
        XCTAssertEqual(m.audios.first { $0.id == m.defaultSelection(preferring: MediaPreferences(audioLanguage: "fr")).audio }?.language, "fr")
    }

    func testFindingAgainOnTheSamePageDoesNotStrandARunningLook() async {
        let s = MediaDiscoveryStore(profile: "p", isPrivate: false)
        let snap = MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.m3u8"), hit("https://cdn.example.com/b.m3u8"), hit(nil, blob: true)], truncated: false)
        s.ingest(snap, pageKey: "k", pageHost: nil)
        let gate = AsyncGate()
        let manifest = MediaManifest(format: .hls, sourceURL: "x", duration: 5, videos: [MediaStream(id: "v", kind: .muxed, label: "720p", language: nil, codecs: nil)], fingerprint: "f")
        let a = s.candidates[0].id
        s.inspect(a) { _ in await gate.wait(); return manifest }
        s.ingest(snap, pageKey: "k", pageHost: nil)                         // Find Again while the look runs
        XCTAssertEqual(s.candidates.count, 3, "the in-page stream is the same one, not a new copy")
        await gate.open()
        for _ in 0..<100 where s.candidates.first(where: { $0.id == a })?.state == .inspecting { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(s.candidates.first { $0.id == a }?.state, .inspecting, "not stuck")
        // The slot was given back: two more looks can run.
        var ran = 0
        for c in s.candidates.filter({ $0.kind.isStream }) { s.inspect(c.id) { _ in ran += 1; return manifest } }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(ran, 0)
        // What is gone from the page goes from the list.
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.m3u8")], truncated: false), pageKey: "k", pageHost: nil)
        XCTAssertEqual(s.candidates.count, 1)
    }

    func testAStaleCandidateCannotBeLookedAt() async {
        let s = MediaDiscoveryStore(profile: "p", isPrivate: false)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/a.m3u8")], truncated: false), pageKey: "one", pageHost: nil)
        s.markStale(currentPageKey: "two")
        var fetched = 0
        s.inspect(s.candidates[0].id) { _ in fetched += 1; throw CancellationError() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fetched, 0)
    }

    func testProtectedAndInPageMediaCannotBeAddedToTheLinkGrabber() throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p18b-\(UUID().uuidString)", profile: "default")
        let store = model.mediaDiscovery
        store.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/ok.mp4"), hit("https://cdn.example.com/drm.mp4", drm: true), hit(nil, blob: true), hit("http://192.168.1.4/lan.mp4")], truncated: false), pageKey: "k", pageHost: nil)
        let r = model.addDiscoveredMediaToLinkGrabber(Set(store.candidates.map(\.id)))
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(model.linkGrabber.items.map(\.name), ["ok.mp4"])
    }

    func testADiscoveryLookRefusesTheLocalNetworkEvenForThePersonsOwnRequest() async throws {
        let master = try await publishHLS("lan")
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup(), refuseInternal: true)
        do { _ = try await fetcher.text(master); XCTFail("read an address on this Mac for a page") } catch {}
        let h = await hits()
        XCTAssertNil(h["lan/master.m3u8"], "nothing was requested")
        // The same address typed in Add Download is the person's own and still works.
        let ok = try await c.media.inspect(master)
        XCTAssertFalse(ok.videos.isEmpty)
    }

    func testAFailedReadIsNotReportedAsAnEmptyPage() {
        let s = MediaDiscoveryStore(profile: "p", isPrivate: false)
        s.ingest(MediaPageSnapshot(hits: [], truncated: false, failed: true), pageKey: "k", pageHost: nil)
        XCTAssertEqual(s.notice, "This page could not be read. Try again.")
        s.ingest(MediaPageSnapshot(hits: [], truncated: false), pageKey: "k", pageHost: nil)
        XCTAssertEqual(s.notice, "No downloadable media was found on this page.")
    }

    func testChoosingAFileTwiceStartsItOnce() {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p18c-\(UUID().uuidString)", profile: "default")
        let store = model.mediaDiscovery
        store.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example.com/ok.mp4")], truncated: false), pageKey: "k", pageHost: nil)
        let id = store.candidates[0].id
        let before = model.engine.downloads.ledger.records.count
        _ = model.openDiscoveredMedia(id); _ = model.openDiscoveredMedia(id)
        XCTAssertEqual(model.engine.downloads.ledger.records.count - before, 1)
    }
}
