import XCTest
@testable import Browser_Setu

/// Stage B: one router decides what can resolve a thing, and one planner lists what can be made from it.
@MainActor
final class DownloadRouterTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }
    func candidate(_ href: String, element: String = "video", blob: Bool = false, drm: Bool = false, hasVideo: Bool? = true, page: String = "x.org") -> MediaCandidate {
        let store = MediaDiscoveryStore(profile: "t", isPrivate: false)
        _ = store.ingest(MediaPageSnapshot(hits: [MediaPageHit(href: blob ? nil : href, element: element, type: "", duration: 10, drm: drm, blob: blob, hasVideo: hasVideo)], truncated: false), pageKey: "1|p", pageHost: page, removeMissing: false)
        return store.candidates[0]
    }
    let on = RouterContext(isPrivate: false, extractorConfigured: true)
    let off = RouterContext(isPrivate: false, extractorConfigured: false)
    var priv: RouterContext { RouterContext(isPrivate: true, extractorConfigured: true) }

    func testDirectFilesAndStreamsAndTorrentsRouteNatively() {
        guard case .tracks = DownloadRouter.route(.file(url("https://x.org/a.mp4"), category: .video), on) else { return XCTFail() }
        guard case .tracks = DownloadRouter.route(.file(url("https://x.org/a.mp3"), category: .audio), on) else { return XCTFail() }
        XCTAssertEqual(DownloadRouter.route(.file(url("https://x.org/a.m3u8"), category: .video), on), .stream(url("https://x.org/a.m3u8")))
        XCTAssertEqual(DownloadRouter.route(.file(url("https://x.org/a.mpd"), category: .video), on), .stream(url("https://x.org/a.mpd")))
        XCTAssertEqual(DownloadRouter.route(.file(url("https://x.org/a.torrent"), category: .torrent), on), .torrent("https://x.org/a.torrent"))
        guard case .unresolved = DownloadRouter.route(.file(url("https://x.org/a.zip"), category: .archive), on) else { return XCTFail("an ordinary file is not routed through a media resolver") }
        guard case .tracks = DownloadRouter.route(.candidate(candidate("https://x.org/clip.mp4"), pageURL: url("https://x.org/p")), on) else { return XCTFail() }
    }

    func testProviderPagesUseTheirAdapterOnlyWhereOneExistsOtherwiseTheExtractor() {
        XCTAssertEqual(DownloadRouter.route(.videoPage(url("https://vimeo.com/123456"), provider: .vimeo), off), .providerAdapter(.vimeo))
        XCTAssertEqual(DownloadRouter.route(.videoPage(url("https://peertube.example/w/abc"), provider: .peertube), off), .providerAdapter(.peertube))
        let yt = url("https://www.youtube.com/watch?v=U21jXL8febU")
        XCTAssertEqual(DownloadRouter.route(.videoPage(yt, provider: .youtube), on), .extractor(page: yt), "no domain list: a page with no adapter goes to the extractor")
        XCTAssertEqual(DownloadRouter.route(.videoPage(yt, provider: .youtube), off), .unresolved(.extractorOff))
        let any = url("https://videos.example.org/watch/9")
        XCTAssertEqual(DownloadRouter.route(.videoPage(any, provider: nil), on), .extractor(page: any), "the same rule for any site")
    }

    func testInMemoryPlayersGoToTheExtractorOnlyWithAPageAndNeverInAPrivateTab() {
        let blob = candidate("", blob: true)
        let page = url("https://x.org/talk")
        XCTAssertEqual(blob.kind, .blob)
        XCTAssertEqual(DownloadRouter.route(.candidate(blob, pageURL: page), on), .extractor(page: page))
        XCTAssertEqual(DownloadRouter.route(.candidate(blob, pageURL: nil), on), .unresolved(.inMemoryNoPage))
        XCTAssertEqual(DownloadRouter.route(.candidate(blob, pageURL: page), priv), .unresolved(.privateTab))
        XCTAssertEqual(DownloadRouter.route(.candidate(candidate("", blob: true, drm: true), pageURL: page), on), .unresolved(.protected))
    }

    func testExpiredAndAlreadyFailedSourcesAreNotRoutedAgain() {
        let expired = NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: url("https://c.example/a.mp4"), container: "mp4", expires: Date(timeIntervalSinceNow: -5))]))
        XCTAssertEqual(DownloadRouter.route(.descriptor(expired), on), .unresolved(.expired))
        var failed = on; failed.extractorAlreadyFailed = true
        XCTAssertEqual(DownloadRouter.route(.videoPage(url("https://x.org/w"), provider: nil), failed), .unresolved(.extractorFailedBefore))
        let ok = NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .manifest(url("https://c.example/m.m3u8")))
        XCTAssertEqual(DownloadRouter.route(.descriptor(ok), on), .stream(url("https://c.example/m.m3u8")))
    }

    // MARK: One planner

    func testEveryEntryPointOffersTheSameChoices() {
        let c = candidate("https://x.org/clip.mp4")
        let viaCandidate = VideoOptions.options(for: c, encoders: (true, true)).map(\.id)
        let viaSource = NormalizedMediaSource(candidate: c)!.options(encoders: (true, true)).map(\.id)
        let viaPlanner = DownloadPlanner.options(for: NormalizedMediaSource(candidate: c)!, encoders: (true, true)).map(\.option.id)
        XCTAssertEqual(viaCandidate, viaSource); XCTAssertEqual(viaSource, viaPlanner)
        XCTAssertTrue(DownloadPlanner.options(for: NormalizedMediaSource(candidate: c)!, encoders: (true, true)).contains { $0.option.kind == .audioM4A && $0.isExecutable }, "sound can be taken from an MP4 file")
    }

    func testFormatIDsSurviveAndOnlyExecutablePlansAreSelectable() {
        let hd = NormalizedRepresentation(role: .muxed, url: url("https://c.example/hd.mp4"), container: "mp4", height: 720, formatID: "hd")
        let sd = NormalizedRepresentation(role: .muxed, url: url("https://c.example/sd.webm"), container: "webm", height: 360, formatID: "sd")
        let v = NormalizedRepresentation(role: .video, url: url("https://c.example/v.webm"), container: "webm", height: 1080, formatID: "v1080")
        let a = NormalizedRepresentation(role: .audio, url: url("https://c.example/a.m4a"), container: "m4a", language: "en", formatID: "aen")
        let src = NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([hd, sd, v, a]))
        let plan = DownloadPlanner.options(for: src, encoders: (true, true), processing: false)
        XCTAssertEqual(plan.first { $0.representation?.formatID == "hd" && $0.option.kind == .original }?.choice, .original)
        XCTAssertEqual(plan.first { $0.option.formatID == "sd" && $0.option.kind == .original }?.representation, sd, "the picked format is the one carried")
        // A WebM picture cannot be joined with M4A sound by the system engine: the join is listed as needing the processing tool, and the picture is still offered on its own.
        let join = plan.first { $0.option.formatID == "v1080" && $0.option.title.hasPrefix("Video with sound") }
        XCTAssertEqual(join?.requiresProcessingTool, true); XCTAssertNil(join?.choice)
        let picture = plan.first { $0.option.formatID == "v1080" && $0.option.title.hasPrefix("Picture only") }
        XCTAssertEqual(picture?.choice, .original, "the picture on its own stays available")
        XCTAssertTrue(picture?.option.title.hasPrefix("Picture only") ?? false)
        XCTAssertTrue(plan.allSatisfy { $0.isExecutable == ($0.choice != nil && $0.option.isAvailable) })
        let mp3 = plan.first { $0.option.kind == .audioMP3 }
        XCTAssertEqual(mp3?.representation, a, "audio is made from the audio track, not from a picture file")
        let none = DownloadPlanner.options(for: NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([])), encoders: (true, true))
        XCTAssertTrue(none.isEmpty, "no formats are invented for a source with none")
    }

    func testVideoOnlyAndAudioOnlyAndCombinedAreEachRepresented() {
        func opts(_ reps: [NormalizedRepresentation]) -> [PlannedOption] { DownloadPlanner.options(for: NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks(reps)), encoders: (true, true)) }
        let silent = opts([NormalizedRepresentation(role: .video, url: url("https://c.example/v.mp4"), container: "mp4", height: 480)])
        XCTAssertTrue(silent.contains { $0.option.title.hasPrefix("Video without sound") && $0.isExecutable }); XCTAssertFalse(silent.contains { $0.option.kind == .audioM4A }, "no sound to take")
        let sound = opts([NormalizedRepresentation(role: .audio, url: url("https://c.example/a.m4a"), container: "m4a")])
        XCTAssertTrue(sound.contains { $0.option.kind == .audioOriginal && $0.isExecutable })
        let both = opts([NormalizedRepresentation(role: .video, url: url("https://c.example/v.mp4"), container: "mp4", height: 480), NormalizedRepresentation(role: .audio, url: url("https://c.example/a.m4a"), container: "m4a")])
        XCTAssertEqual(both.first { $0.option.provenance.contains("joined") }?.choice, .joined)
    }

    // MARK: Lookups are not repeated

    func testTheSameQuestionIsAskedOnceAndTheAnswerIsShared() async throws {
        let script = TestExtractorScript.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script))
        let countFile = NSTemporaryDirectory() + "bs-ext-count.txt"; try? FileManager.default.removeItem(atPath: countFile)
        let exe = try ExternalExtractor.validateLocation(script); let id = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        let broker = ExtractorBroker()
        let page = URL(string: "http://127.0.0.1:18766/media/k/page.html?counted")!
        async let a = broker.lookup(page: page, path: script, identity: id, isPrivate: false, allowLocal: true)
        async let b = broker.lookup(page: page, path: script, identity: id, isPrivate: false, allowLocal: true)
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, y)
        _ = try await broker.lookup(page: page, path: script, identity: id, isPrivate: false, allowLocal: true)      // a later look: from memory
        let runs = ((try? String(contentsOfFile: countFile, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(runs, 1, "the program ran once for three questions"); XCTAssertEqual(broker.launches, 1)
        // A failure is remembered briefly, so a page that failed is not asked again at once.
        let bad = URL(string: "http://127.0.0.1:18766/media/k/page.html?noformats")!
        do { _ = try await broker.lookup(page: bad, path: script, identity: id, isPrivate: false, allowLocal: true); XCTFail() } catch {}
        XCTAssertTrue(broker.recentlyFailed(bad, identity: id))
        let before = broker.launches
        do { _ = try await broker.lookup(page: bad, path: script, identity: id, isPrivate: false, allowLocal: true); XCTFail() } catch {}
        XCTAssertEqual(broker.launches, before)
    }
}

/// Stage B review fixes.
@MainActor
final class DownloadRouterReviewTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }

    func testAProviderRouteAppliesToAVideoAddressNotToTheWholeSite() {
        let on = RouterContext(isPrivate: false, extractorConfigured: true)
        XCTAssertEqual(DownloadRouter.route(.videoPage(url("https://vimeo.com/123456789"), provider: .vimeo), on), .providerAdapter(.vimeo))
        XCTAssertEqual(DownloadRouter.route(.videoPage(url("https://vimeo.com/channels/staffpicks"), provider: .vimeo), on), .extractor(page: url("https://vimeo.com/channels/staffpicks")), "a page of the provider's site that names no video goes to the extractor")
    }

    func testBestAudioIsReadableThenHighestBitrateNotTheFirstListed() {
        func a(_ c: String, _ br: Int?, _ id: String) -> NormalizedRepresentation { NormalizedRepresentation(role: .audio, url: url("https://c.example/\(id).\(c)"), container: c, bitrate: br, formatID: id) }
        let list = [a("webm", 160_000, "opus"), a("m4a", 48_000, "low"), a("m4a", 128_000, "high")]
        XCTAssertEqual(DownloadPlanner.bestAudio(list)?.formatID, "high")
        let video = NormalizedRepresentation(role: .video, url: url("https://c.example/v.mp4"), container: "mp4", height: 720, formatID: "v")
        let plan = DownloadPlanner.options(for: NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([video] + list)), encoders: (true, true))
        XCTAssertEqual(plan.first { $0.choice == .joined }?.audio?.formatID, "high", "the join uses the best readable sound, so it is joined rather than degraded to picture only")
        XCTAssertEqual(plan.first { $0.option.kind == .audioMP3 }?.audio?.formatID, "high")
    }

    func testContainerFollowsTheDeclaredTypeWhenTheAddressHasNoMediaEnding() {
        XCTAssertEqual(NormalizedMediaSource.container(ext: "php", mime: "video/mp4", audio: false), "mp4")
        XCTAssertEqual(NormalizedMediaSource.container(ext: "", mime: "video/webm; codecs=vp9", audio: false), "webm")
        XCTAssertEqual(NormalizedMediaSource.container(ext: "mov", mime: nil, audio: false), "mov")
        XCTAssertEqual(NormalizedMediaSource.container(ext: "bin", mime: nil, audio: true), "m4a")
    }

    func testCancellingTheLastWaiterStopsTheProgramAndAProfileHasItsOwnAnswers() async throws {
        let script = TestExtractorScript.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script))
        let exe = try ExternalExtractor.validateLocation(script); let id = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        let broker = ExtractorBroker()
        let slow = URL(string: "http://127.0.0.1:18766/media/k/page.html?slow")!
        let t = Task { try await broker.lookup(page: slow, path: script, identity: id, profile: "a", isPrivate: false, allowLocal: true) }
        try await Task.sleep(nanoseconds: 800_000_000)
        let started = Date(); t.cancel()
        _ = try? await t.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancelling the only waiter ends the lookup without waiting for the program")
        // Not remembered: asking again launches again.
        let before = broker.launches
        let t2 = Task { try await broker.lookup(page: slow, path: script, identity: id, profile: "a", isPrivate: false, allowLocal: true, timeout: 1.5) }
        _ = try? await t2.value
        XCTAssertEqual(broker.launches, before + 1)
        // Profiles do not share answers.
        let ok = URL(string: "http://127.0.0.1:18766/media/k/page.html?muxed")!
        _ = try await broker.lookup(page: ok, path: script, identity: id, profile: "a", isPrivate: false, allowLocal: true)
        let l = broker.launches
        _ = try await broker.lookup(page: ok, path: script, identity: id, profile: "b", isPrivate: false, allowLocal: true)
        XCTAssertEqual(broker.launches, l + 1, "another profile asks for itself")
    }
}
