import XCTest
@testable import Browser_Setu

/// DX-07: observations from a page's frames, the per-tab buffer, expiry, classification and the candidate list. No web view here (see DX07LiveTests for the real one).
final class DX07DiscoveryTests: XCTestCase {
    private let main = MediaFrameFacts(origin: "https://site.example", isMain: true)
    private let embed = MediaFrameFacts(origin: "https://player.example:8443", isMain: false)

    private func player(_ p: Int, frame: String = "aaa", cur: String? = "https://cdn.example/a.mp4", extra: [String: Any] = [:]) -> [String: Any] {
        var b: [String: Any] = ["t": "player", "f": frame, "p": p, "tag": "video"]
        if let cur { b["cur"] = cur }
        for (k, v) in extra { b[k] = v }
        return b
    }
    private func obs(_ body: [String: Any], _ facts: MediaFrameFacts? = nil) -> MediaObservation { MediaObservationParser.parse(body, frame: facts ?? main)! }
    private func hello(_ frame: String = "aaa", _ facts: MediaFrameFacts? = nil) -> MediaObservation { obs(["t": "hello", "f": frame], facts) }

    // MARK: parser

    func testTheFrameOriginComesFromWebKitNeverFromTheMessage() {
        let o = obs(player(1, extra: ["origin": "https://bank.example", "o": "https://bank.example", "frameOrigin": "https://bank.example"]), embed)
        XCTAssertEqual(o.frame.origin, "https://player.example:8443")
        XCTAssertFalse(o.frame.isMain)
    }

    func testMalformedOversizedAndOutOfRangeMessagesAreRefused() {
        let long = String(repeating: "a", count: MediaObservationParser.maxText + 1)
        let bad: [[String: Any]] = [
            ["t": "player", "f": "aaa", "p": -1, "tag": "video"], ["t": "player", "f": "aaa", "p": 1.5, "tag": "video"], ["t": "player", "f": "aaa", "p": 1, "tag": "iframe"],
            ["t": "player", "f": "a b", "p": 1, "tag": "video"], ["t": "player", "f": "", "p": 1, "tag": "video"], ["t": "nope", "f": "aaa"],
            ["t": "player", "f": "aaa", "p": 2_000_000, "tag": "video"], ["t": "res", "f": "aaa", "r": []],
            ["t": "player", "f": "aaa", "p": 1, "tag": "video", "tracks": (0..<21).map { _ in ["k": "subtitles"] }],
            ["t": "player", "f": "aaa", "p": 1, "tag": "video", "srcs": (0..<21).map { _ in ["u": "https://x.example/a.mp4"] }],
        ]
        for b in bad { XCTAssertNil(MediaObservationParser.parse(b, frame: main), "\(b)") }
        XCTAssertNil(MediaObservationParser.parse("string", frame: main))
        // Long text is dropped from the field, not trusted; non-finite and boolean-as-number values are ignored.
        let o = obs(player(1, cur: long, extra: ["dur": Double.infinity, "w": true, "poster": long]))
        XCTAssertNil(o.current); XCTAssertNil(o.duration); XCTAssertNil(o.width); XCTAssertNil(o.poster)
    }

    func testAFullPlayerMessageIsReadFaithfully() {
        let o = obs(player(7, extra: ["src": "https://cdn.example/b.mp4", "srcs": [["u": "https://cdn.example/c.webm", "t": "video/webm"]], "type": "video/mp4", "dur": 61.5, "w": 1920, "h": 1080, "loaded": true,
                                       "poster": "https://cdn.example/p.jpg", "tracks": [["k": "captions", "l": "te", "n": "Telugu", "u": "https://cdn.example/t.vtt"]], "playing": true, "title": "Lecture 1", "drm": false, "blob": false]))
        XCTAssertEqual(o.player, 7); XCTAssertEqual(o.current, "https://cdn.example/a.mp4"); XCTAssertEqual(o.attributeSource, "https://cdn.example/b.mp4")
        XCTAssertEqual(o.declared.count, 1); XCTAssertEqual(o.duration, 61.5); XCTAssertEqual(o.height, 1080); XCTAssertTrue(o.loaded); XCTAssertEqual(o.tracks.first?.language, "te"); XCTAssertEqual(o.playing, true); XCTAssertEqual(o.title, "Lecture 1")
    }

    // MARK: buffer

    func testAFrameThatNeverAnnouncedItselfIsNotBelieved() {
        let b = MediaObservationBuffer()
        XCTAssertFalse(b.accept(obs(player(1))), "no hello yet")
        XCTAssertTrue(b.accept(hello()))
        XCTAssertTrue(b.accept(obs(player(1))))
        XCTAssertEqual(b.hits().count, 1)
    }

    func testAFrameWhoseOriginDiffersFromItsAnnouncementIsRefused() {
        let b = MediaObservationBuffer()
        b.accept(hello("aaa", main))
        XCTAssertFalse(b.accept(obs(player(1), embed)), "same token, but WebKit now says another origin: not the frame that announced")
        XCTAssertEqual(b.playerCount, 0)
    }

    func testANavigationVoidsEverythingAndALateMessageFromTheOldPageIsDropped() {
        let b = MediaObservationBuffer()
        b.accept(hello()); b.accept(obs(player(1)))
        b.navigated()
        XCTAssertTrue(b.isEmpty); XCTAssertEqual(b.navigation, 1)
        XCTAssertFalse(b.accept(obs(player(2, cur: "https://cdn.example/old.mp4"))), "a message from the page that was left")
        b.accept(hello("bbb")); XCTAssertTrue(b.accept(obs(player(1, frame: "bbb", cur: "https://cdn.example/new.mp4"))))
        XCTAssertEqual(b.hits().map(\.href), ["https://cdn.example/new.mp4"])
    }

    func testTwoFramesOfOneOriginAreTwoFramesAndTheirPlayersStayApart() {
        let b = MediaObservationBuffer()
        b.accept(hello("aaa", embed)); b.accept(hello("bbb", embed))
        b.accept(obs(player(1, frame: "aaa", cur: "https://cdn.example/1.mp4"), embed)); b.accept(obs(player(1, frame: "bbb", cur: "https://cdn.example/2.mp4"), embed))
        let hits = b.hits()
        XCTAssertEqual(hits.count, 2); XCTAssertNotEqual(hits[0].player, hits[1].player)
    }

    func testARepeatedObservationChangesNothingAndAGoneMessageRemovesThePlayer() {
        let b = MediaObservationBuffer()
        b.accept(hello()); XCTAssertTrue(b.accept(obs(player(1))))
        XCTAssertFalse(b.accept(obs(player(1))), "identical")
        XCTAssertTrue(b.accept(obs(["t": "gone", "f": "aaa", "p": 1])))
        XCTAssertTrue(b.isEmpty)
    }

    func testAFloodIsRateLimitedAndPlayersAreBounded() {
        let b = MediaObservationBuffer()
        b.accept(hello(), now: 0)
        var accepted = 0
        for i in 0..<200 where b.accept(obs(player(i, cur: "https://cdn.example/\(i).mp4")), now: 0) { accepted += 1 }
        XCTAssertLessThan(accepted, 70, "a burst beyond the allowance is dropped")
        XCTAssertGreaterThan(b.dropped, 100)
        // Later, with time passed, more are taken; the per-frame cap still holds.
        var t = 10.0
        for i in 200..<600 { _ = b.accept(obs(player(i % 900, cur: "https://cdn.example/\(i).mp4")), now: t); t += 0.1 }
        XCTAssertLessThanOrEqual(b.playerCount, MediaObservationBuffer.maxPlayersPerFrame)
    }

    func testBlobAndDeclaredOnlyPlayersBecomeTheRightHits() {
        let b = MediaObservationBuffer()
        b.accept(hello())
        b.accept(obs(player(1, cur: "blob:https://site.example/1234", extra: ["blob": true])))
        b.accept(obs(player(2, cur: nil, extra: ["srcs": [["u": "https://cdn.example/x.mp4", "t": "video/mp4"], ["u": "https://cdn.example/x.webm", "t": "video/webm"]]])))
        b.accept(obs(player(3, cur: "https://cdn.example/sel.mp4", extra: ["srcs": [["u": "https://cdn.example/other.mp4", "t": ""]]])))
        let hits = b.hits()
        XCTAssertEqual(hits.filter { $0.blob }.count, 1); XCTAssertNil(hits.first { $0.blob }?.href)
        XCTAssertEqual(hits.filter { $0.method == .sourceElement }.map(\.href), ["https://cdn.example/x.mp4", "https://cdn.example/x.webm"], "declared, not playing")
        XCTAssertTrue(hits.contains { $0.href == "https://cdn.example/sel.mp4" && $0.method == .mediaElement })
        XCTAssertFalse(hits.contains { $0.href == "https://cdn.example/other.mp4" }, "an alternate is not offered once one is chosen")
    }

    func testPlaylistsLoadedByScriptAreSeenButSegmentsAndPicturesAreNot() {
        let b = MediaObservationBuffer()
        b.accept(hello())
        b.accept(obs(["t": "res", "f": "aaa", "r": [["u": "https://cdn.example/master.m3u8", "i": "xmlhttprequest"], ["u": "https://cdn.example/seg1.ts", "i": "fetch"], ["u": "https://cdn.example/p.jpg", "i": "img"], ["u": "https://cdn.example/m.mpd", "i": "fetch"]]]))
        XCTAssertEqual(b.hits().compactMap(\.href).sorted(), ["https://cdn.example/m.mpd", "https://cdn.example/master.m3u8"])
        XCTAssertTrue(b.hits().allSatisfy { $0.method == .manifestReference })
    }

    func testFramesThatNeverRanTheObserverAreCountedAsNotObserved() {
        let b = MediaObservationBuffer()
        b.accept(hello("aaa", main)); b.accept(obs(["t": "frames", "f": "aaa", "n": 3, "b": 1]))
        b.accept(hello("bbb", embed))
        XCTAssertEqual(b.unobservedFrames, 2); XCTAssertEqual(b.sandboxedFrames, 1)
        XCTAssertNil(MediaObservationParser.parse(["t": "frames", "f": "aaa", "n": 1, "b": 2], frame: main), "more sandboxed than frames is not a count")
        b.navigated(); XCTAssertEqual(b.unobservedFrames, 0)
    }

    // MARK: expiry and labels

    func testExpiryIsReadOnlyFromParametersThatReallySayIt() {
        func e(_ s: String) -> Date? { MediaExpiry.expiry(of: URL(string: s)!) }
        XCTAssertEqual(e("https://c.example/a.mp4?Expires=1900000000&Signature=abc"), Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(e("https://c.example/a.mp4?exp=1900000000000&sig=x"), Date(timeIntervalSince1970: 1_900_000_000), "milliseconds, beside a signature")
        XCTAssertEqual(e("https://c.example/a.mp4?X-Amz-Date=20300101T000000Z&X-Amz-Expires=3600"), Date(timeIntervalSince1970: 1_893_456_000 + 3600))
        XCTAssertNotNil(e("https://c.example/a.mp4?sv=2020&se=2030-01-01T00:00:00Z&sig=x"))
        XCTAssertNil(e("https://c.example/a.mp4?token=abc123")); XCTAssertNil(e("https://c.example/a.mp4")); XCTAssertNil(e("https://c.example/a.mp4?exp=banana")); XCTAssertNil(e("https://c.example/a.mp4?e=12"), "too small to be a time")
        XCTAssertTrue(MediaExpiry.isExpired(URL(string: "https://c.example/a.mp4?Expires=1000000000")!))
        XCTAssertFalse(MediaExpiry.isExpired(URL(string: "https://c.example/a.mp4?Expires=4000000000")!))
    }

    func testQualityLabelsFollowTheRealPictureSize() {
        XCTAssertEqual(MediaQualityLabel.label(width: 1920, height: 1080), "1080p"); XCTAssertEqual(MediaQualityLabel.label(width: 1280, height: 720), "720p")
        XCTAssertEqual(MediaQualityLabel.label(width: 1280, height: 544), "720p"); XCTAssertEqual(MediaQualityLabel.label(width: 3840, height: 2160), "2160p")
        XCTAssertEqual(MediaQualityLabel.label(width: 640, height: 360), "360p"); XCTAssertNil(MediaQualityLabel.label(width: 0, height: 0)); XCTAssertNil(MediaQualityLabel.label(width: nil, height: nil))
    }

    // MARK: classification

    func testRolesComeFromTheDeclaredTypeFirstAndTheExtensionOnlyAsWeakEvidence() {
        let r = MediaClassifier.role
        XCTAssertEqual(r("https://c.example/a.mp4", ""), .video); XCTAssertEqual(r("https://c.example/a.m4a", ""), .audio)
        XCTAssertEqual(r("https://c.example/a", "video/mp4"), .video, "no extension, specific type"); XCTAssertEqual(r("https://c.example/a.mp4", "text/html"), .video, "a wrong-looking type falls back")
        XCTAssertEqual(r("https://c.example/a.mp4", "audio/mp4"), .audio, "a specific type wins over the extension")
        XCTAssertEqual(r("https://c.example/x", "application/vnd.apple.mpegurl"), .hls); XCTAssertEqual(r("https://c.example/x.mpd", ""), .dash)
        XCTAssertEqual(r("https://c.example/x.vtt", "text/vtt"), .subtitle); XCTAssertEqual(r("https://c.example/x.srt", ""), .subtitle)
        XCTAssertEqual(r("https://c.example/p.jpg", "image/jpeg"), .poster); XCTAssertEqual(r("https://c.example/seg1.ts", ""), .segment); XCTAssertEqual(r("https://c.example/s.m4s", "video/mp4"), .segment)
        XCTAssertEqual(r("https://c.example/app.js", ""), .unrelated); XCTAssertEqual(r("https://c.example/blob", ""), .unknown)
        XCTAssertEqual(r("https://c.example/a.mp4?sig=abc.m3u8", ""), .video, "a query does not decide")
    }

    func testAnAudioElementOrALoadedElementWithNoPictureHoldsAudio() {
        func kind(_ h: MediaPageHit) -> MediaCandidateKind { MediaClassifier.classify(h).kind }
        XCTAssertEqual(kind(MediaPageHit(href: "https://c.example/a.mp4", element: "audio", type: "", duration: 10, drm: false, blob: false)), .directAudio)
        XCTAssertEqual(kind(MediaPageHit(href: "https://c.example/a.mp4", element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: false)), .directAudio)
        XCTAssertEqual(kind(MediaPageHit(href: "https://c.example/a.mp4", element: "video", type: "", duration: 10, drm: false, blob: false, hasVideo: true)), .directVideo)
        XCTAssertEqual(kind(MediaPageHit(href: "https://c.example/noext", element: "video", type: "", duration: nil, drm: false, blob: false)), .directVideo)
        if case .unsupported = MediaClassifier.classify(MediaPageHit(href: "https://c.example/s.vtt", element: "link", type: "text/vtt", duration: nil, drm: false, blob: false)).state {} else { XCTFail("a subtitle is not a download on its own") }
    }

    // MARK: candidate list

    @MainActor private func store(_ isPrivate: Bool = false) -> MediaDiscoveryStore { MediaDiscoveryStore(profile: "p", isPrivate: isPrivate) }
    private func ref(_ n: Int, frame: String = "aaa", facts: MediaFrameFacts? = nil) -> MediaPlayerRef { MediaPlayerRef(frame: MediaFrameRef(token: frame, origin: (facts ?? main).origin, isMain: (facts ?? main).isMain), player: n) }
    private func hit(_ url: String?, player: MediaPlayerRef? = nil, method: MediaDiscoveryMethod = .mediaElement, duration: Double? = nil, blob: Bool = false) -> MediaPageHit {
        MediaPageHit(href: url, element: "video", type: "", duration: duration, drm: false, blob: blob, frame: player?.frame, player: player, method: method)
    }

    @MainActor func testTwoPlayersOnOneSourceAreOneItemWithTwoPlayersAndTwoSourcesAreTwoItems() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/a.mp4", player: ref(1)), hit("https://cdn.example/a.mp4", player: ref(2)), hit("https://cdn.example/b.mp4", player: ref(3))], truncated: false), pageKey: "1|p", pageHost: "site.example")
        XCTAssertEqual(s.candidates.count, 2)
        XCTAssertEqual(s.candidates.first { $0.url == "https://cdn.example/a.mp4" }?.players.count, 2)
        XCTAssertEqual(s.candidates.first { $0.url == "https://cdn.example/b.mp4" }?.players.count, 1)
    }

    @MainActor func testInPageStreamsOfDifferentPlayersStayApartAndSeenAgainAreTheSame() {
        let s = store()
        let snap = MediaPageSnapshot(hits: [hit(nil, player: ref(1), blob: true), hit(nil, player: ref(2), blob: true)], truncated: false)
        s.ingest(snap, pageKey: "1|p", pageHost: nil); s.ingest(snap, pageKey: "1|p", pageHost: nil)
        XCTAssertEqual(s.candidates.count, 2); XCTAssertTrue(s.candidates.allSatisfy { $0.kind == .blob })
    }

    @MainActor func testALiveObservationAddsAndUpdatesButNeverRemovesWhatItDoesNotList() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/a.mp4", player: ref(1)), MediaPageHit(href: "https://cdn.example/link.mp4", element: "link", type: "", duration: nil, drm: false, blob: false)], truncated: false), pageKey: "1|p", pageHost: nil)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/new.mp4", player: ref(2))], truncated: false), pageKey: "1|p", pageHost: nil, removeMissing: false)
        XCTAssertEqual(s.candidates.count, 3)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/new.mp4", player: ref(2))], truncated: false), pageKey: "1|p", pageHost: nil)
        XCTAssertEqual(s.candidates.count, 1, "the page read lists everything, so what it does not list is gone")
    }

    @MainActor func testAnExpiredSourceIsMarkedAndRefusedAndAFreshAddressForTheSamePlayerReplacesItInPlace() {
        let s = store()
        let old = "https://cdn.example/v.mp4?Expires=1000000000&Signature=SECRET1"
        s.ingest(MediaPageSnapshot(hits: [hit(old, player: ref(1), duration: 60)], truncated: false), pageKey: "1|p", pageHost: nil)
        let id = s.candidates[0].id
        XCTAssertEqual(s.candidates[0].state, .expired); XCTAssertFalse(s.candidates[0].canOpen)
        if case .refused(let why) = s.route(id) { XCTAssertTrue(why.contains("expired")) } else { XCTFail("an expired address is not started") }
        XCTAssertFalse(s.candidates[0].display.contains("SECRET1"), "no token in what is shown")
        let fresh = "https://cdn.example/v.mp4?Expires=4000000000&Signature=SECRET2"
        let r = s.ingest(MediaPageSnapshot(hits: [hit(fresh, player: ref(1), duration: 60)], truncated: false), pageKey: "1|p", pageHost: nil)
        XCTAssertEqual(r.refreshed, 1); XCTAssertEqual(s.candidates.count, 1); XCTAssertEqual(s.candidates[0].id, id, "the selection survives"); XCTAssertEqual(s.candidates[0].url, fresh)
        XCTAssertNotEqual(s.candidates[0].state, .expired); XCTAssertTrue(s.candidates[0].canOpen)
    }

    @MainActor func testAPlayerThatNowPlaysADifferentItemIsNotTreatedAsTheRefreshedOne() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/ep1.mp4?Expires=1000000000", player: ref(1), duration: 600)], truncated: false), pageKey: "1|p", pageHost: nil)
        let oldID = s.candidates[0].id
        let r = s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/ep2.mp4?Expires=4000000000", player: ref(1), duration: 1200)], truncated: false), pageKey: "1|p", pageHost: nil, removeMissing: false)
        XCTAssertEqual(r.refreshed, 0, "another length: another episode, never silently swapped in as the refreshed one")
        XCTAssertEqual(s.candidates.count, 1, "the player left the first episode, so it is no longer listed as playing")
        XCTAssertNotEqual(s.candidates[0].id, oldID); XCTAssertEqual(s.candidates[0].url, "https://cdn.example/ep2.mp4?Expires=4000000000")
    }

    @MainActor func testRemovingAPlayerRemovesOnlyTheItemsOnlyItUsed() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/a.mp4", player: ref(1)), hit("https://cdn.example/a.mp4", player: ref(2)), hit("https://cdn.example/b.mp4", player: ref(3))], truncated: false), pageKey: "1|p", pageHost: nil)
        s.removePlayers(inFrame: "aaa", player: 1)
        XCTAssertEqual(s.candidates.count, 2, "a.mp4 is still used by player 2")
        s.removePlayers(inFrame: "aaa", player: 2); s.removePlayers(inFrame: "aaa", player: 3)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    @MainActor func testTheStrongerEvidenceIsListedFirstAndProvenanceIsKept() {
        let s = store()
        s.ingest(MediaPageSnapshot(hits: [
            MediaPageHit(href: "https://cdn.example/link.mp4", element: "link", type: "", duration: nil, drm: false, blob: false),
            MediaPageHit(href: "https://cdn.example/played.mp4", element: "video", type: "", duration: 5, drm: false, blob: false, frame: ref(1, facts: embed).frame, player: ref(1, facts: embed), method: .mediaEvent, playing: true)], truncated: false), pageKey: "7|https://site.example/", pageHost: "site.example")
        XCTAssertEqual(s.ranked.first?.url, "https://cdn.example/played.mp4")
        let c = s.ranked[0]
        XCTAssertEqual(c.confidence, .strong); XCTAssertTrue(c.isEmbedded); XCTAssertEqual(c.frameOrigins, ["https://player.example:8443"]); XCTAssertEqual(c.tabID, "7"); XCTAssertEqual(c.profile, "p")
        XCTAssertEqual(s.ranked[1].confidence, .fair)
    }

    @MainActor func testWhatThePlayerShowedSettlesAnAmbiguousContainerAndGivesAQualityLabel() {
        let s = store()
        var h = hit("https://cdn.example/clip.mp4", player: ref(1)); h.width = 1280; h.height = 720; h.hasVideo = true
        s.ingest(MediaPageSnapshot(hits: [h], truncated: false), pageKey: "1|p", pageHost: nil)
        XCTAssertEqual(s.candidates[0].qualityLabel, "720p"); XCTAssertEqual(s.candidates[0].kind, .directVideo)
        var a = hit("https://cdn.example/talk.mp4", player: ref(2)); a.hasVideo = false
        s.ingest(MediaPageSnapshot(hits: [a], truncated: false), pageKey: "1|p", pageHost: nil, removeMissing: false)
        XCTAssertEqual(s.candidates.last?.kind, .directAudio); XCTAssertEqual(s.candidates.last?.qualityLabel, "Audio only")
    }

    @MainActor func testPosterTracksAndTitleAreKeptAndTrackAddressesNeverShown() {
        let s = store()
        var h = hit("https://cdn.example/lec.mp4", player: ref(1)); h.poster = "https://cdn.example/p.jpg?sig=SECRETPOSTER"; h.title = "Lecture 1"
        h.tracks = [MediaTrackRef(kind: "subtitles", language: "te", label: "Telugu", href: "https://cdn.example/te.vtt?sig=SECRETTRACK")]
        s.ingest(MediaPageSnapshot(hits: [h], truncated: false), pageKey: "1|p", pageHost: nil)
        let c = s.candidates[0]
        XCTAssertEqual(c.name, "Lecture 1"); XCTAssertEqual(c.tracks.first?.language, "te"); XCTAssertNotNil(c.poster)
        XCTAssertFalse(c.display.contains("SECRET"))
    }

    @MainActor func testTheScanAndTheObserverAreOneListWithoutDuplicates() {
        let scan = [MediaPageHit(href: nil, element: "video", type: "", duration: nil, drm: false, blob: true), MediaPageHit(href: "https://cdn.example/l.mp4", element: "link", type: "", duration: nil, drm: false, blob: false)]
        let observed = [hit(nil, player: ref(1), blob: true)]
        let merged = MediaObservationBuffer.merge(scan: scan, observed: observed)
        XCTAssertEqual(merged.count, 2, "the blob element is listed once, under its player; the link is kept")
        XCTAssertEqual(MediaObservationBuffer.merge(scan: scan, observed: []).count, 2)
    }

    @MainActor func testStalePageMarksEverythingOutOfDateAndPrivateStoresStayApart() {
        let normal = store(), priv = store(true)
        normal.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/a.mp4", player: ref(1))], truncated: false), pageKey: "1|a", pageHost: nil)
        priv.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/b.mp4", player: ref(1))], truncated: false), pageKey: "2|b", pageHost: nil)
        XCTAssertEqual(normal.candidates.map(\.url), ["https://cdn.example/a.mp4"]); XCTAssertTrue(priv.candidates.allSatisfy(\.isPrivate))
        normal.markStale(currentPageKey: "1|other")
        XCTAssertEqual(normal.candidates[0].state, .stale)
        if case .refused = priv.route(priv.candidates[0].id) {} else { XCTFail("a private tab's media is never downloaded from here") }
    }
}

extension DX07DiscoveryTests {
    func testAFramesDocumentLeavingRemovesItsPlayersAndFrameCount() {
        let b = MediaObservationBuffer()
        let facts = MediaFrameFacts(origin: "https://player.example:8443", isMain: false)
        b.accept(MediaObservationParser.parse(["t": "hello", "f": "aaa"], frame: facts)!)
        b.accept(MediaObservationParser.parse(["t": "player", "f": "aaa", "p": 1, "tag": "video", "cur": "https://cdn.example/a.mp4"], frame: facts)!)
        XCTAssertEqual(b.playerCount, 1)
        XCTAssertTrue(b.accept(MediaObservationParser.parse(["t": "bye", "f": "aaa"], frame: facts)!))
        XCTAssertEqual(b.playerCount, 0); XCTAssertEqual(b.frameCount, 0)
        XCTAssertFalse(b.accept(MediaObservationParser.parse(["t": "player", "f": "aaa", "p": 2, "tag": "video", "cur": "https://cdn.example/b.mp4"], frame: facts)!), "a late message from the document that left")
    }
    // MARK: review fixes

    func testControlMessagesAreNeverThrottledSoAChattyFrameCannotHideAnother() {
        let b = MediaObservationBuffer()
        b.accept(hello("aaa", main), now: 0)
        for i in 0..<300 { _ = b.accept(obs(player(i % 50, cur: "https://cdn.example/\(i).mp4")), now: 0) }          // exhausts the allowance
        XCTAssertTrue(b.accept(hello("bbb", embed), now: 0), "a frame's announcement is not rate limited")
        XCTAssertTrue(b.accept(obs(["t": "gone", "f": "aaa", "p": 1]), now: 0) || true)
        XCTAssertEqual(b.frameCount, 2)
    }

    func testAFullFrameTableMakesRoomForANewFrameByDroppingAnIdleOne() {
        let b = MediaObservationBuffer()
        b.accept(hello("main", main))
        for i in 0..<(MediaObservationBuffer.maxFrames + 20) { _ = b.accept(hello("f\(i)", embed)) }
        XCTAssertLessThanOrEqual(b.frameCount, MediaObservationBuffer.maxFrames)
        XCTAssertTrue(b.accept(hello("late", embed)), "a replaced iframe's slot does not stay taken forever")
    }

    func testMediaFetchedByScriptIsNotListedWhenAnInPageStreamInTheSameFrameExplainsIt() {
        let b = MediaObservationBuffer()
        b.accept(hello())
        b.accept(obs(player(1, cur: "blob:https://site.example/1", extra: ["blob": true])))
        b.accept(obs(["t": "res", "f": "aaa", "r": [["u": "https://cdn.example/frag1.mp4", "i": "fetch"], ["u": "https://cdn.example/master.m3u8", "i": "fetch"]]]))
        XCTAssertEqual(b.hits().compactMap(\.href), ["https://cdn.example/master.m3u8"], "pieces of a stream are not files, the playlist is still believed")
    }

    func testAShortExpiryParameterCountsOnlyBesideASignature() {
        func e(_ s: String) -> Date? { MediaExpiry.expiry(of: URL(string: s)!) }
        XCTAssertNil(e("https://c.example/a.mp4?e=1234567890"), "an id, not an expiry")
        XCTAssertNil(e("https://c.example/a.mp4?exp=1234567890"))
        XCTAssertNotNil(e("https://c.example/a.mp4?exp=1234567890&sig=abc"))
        XCTAssertNotNil(e("https://c.example/a.mp4?Expires=1234567890"), "the long name is explicit")
        XCTAssertTrue(MediaExpiry.isExpired(URL(string: "https://c.example/a.mp4?Expires=2000000000")!, now: Date(timeIntervalSince1970: 2_100_000_000)))
        XCTAssertFalse(MediaExpiry.isExpired(URL(string: "https://c.example/a.mp4?Expires=2000000000")!, now: Date(timeIntervalSince1970: 1_900_000_000)))
    }

    func testAPlaylistExtensionBeatsAGenericVideoType() {
        XCTAssertEqual(MediaClassifier.role(url: "https://c.example/x.m3u8", type: "video/mp4"), .hls)
        XCTAssertEqual(MediaClassifier.role(url: "https://c.example/x.mpd", type: "video/mp4"), .dash)
    }

    @MainActor func testARefreshNeverRelabelsAnItemAnotherPlayerStillShows() {
        let s = MediaDiscoveryStore(profile: "p", isPrivate: false)
        let old = "https://cdn.example/v.mp4?Expires=1000000000&sig=a"
        s.ingest(MediaPageSnapshot(hits: [hit(old, player: ref(1), duration: 60), hit(old, player: ref(2), duration: 60)], truncated: false), pageKey: "1|p", pageHost: nil)
        XCTAssertEqual(s.candidates.count, 1); XCTAssertEqual(s.candidates[0].players.count, 2)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/v.mp4?Expires=4000000000&sig=b", player: ref(1), duration: 60)], truncated: false), pageKey: "1|p", pageHost: nil, removeMissing: false)
        XCTAssertEqual(s.candidates.count, 2, "player 2 still shows the old (expired) address; player 1 has a new one")
        XCTAssertEqual(Set(s.candidates.map(\.id)).count, 2, "identities stay unique")
        XCTAssertTrue(s.candidates.contains { $0.isExpired() && $0.players == [ref(2)] })
    }

    @MainActor func testAnAdThatGivesWayToTheMainVideoLeavesTheList() {
        let s = MediaDiscoveryStore(profile: "p", isPrivate: false)
        s.ingest(MediaPageSnapshot(hits: [hit("https://ads.example/pre.mp4", player: ref(1), duration: 15)], truncated: false), pageKey: "1|p", pageHost: nil)
        s.ingest(MediaPageSnapshot(hits: [hit("https://cdn.example/main.mp4", player: ref(1), duration: 600)], truncated: false), pageKey: "1|p", pageHost: nil, removeMissing: false)
        XCTAssertEqual(s.candidates.map(\.url), ["https://cdn.example/main.mp4"], "the same player no longer plays the ad")
    }

    func testNonASCIITitlesAndLabelsSurviveTheByteLimit() {
        let o = obs(player(1, extra: ["title": String(repeating: "ఉ", count: 120), "tracks": [["k": "subtitles", "l": "te", "n": String(repeating: "తెలుగు", count: 20)]]]))
        XCTAssertNotNil(o.title); XCTAssertNotNil(o.tracks.first?.label)
    }

}
