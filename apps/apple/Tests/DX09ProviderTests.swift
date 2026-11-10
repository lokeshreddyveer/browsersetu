import XCTest
@testable import Browser_Setu

// DX-09: websites and what they permit. Fixtures are written from each provider's published documentation or invented to exercise a rule; none is a recording of a live service,
// and nothing here shows that a live provider behaves this way.

private func u(_ s: String) -> URL { URL(string: s)! }

final class DX09RecognitionTests: XCTestCase {
    func r(_ s: String) -> ProviderMatch? { ProviderRecognizer.recognize(u(s)) }

    func testCanonicalAddressesGiveProviderKindAndId() {
        XCTAssertEqual(r("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.mediaID, "dQw4w9WgXcQ")
        XCTAssertEqual(r("https://m.youtube.com/shorts/dQw4w9WgXcQ")?.kind, .short)
        XCTAssertEqual(r("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")?.isEmbed, true)
        XCTAssertEqual(r("https://youtu.be/dQw4w9WgXcQ")?.isShortLink, true)
        XCTAssertEqual(r("https://www.youtube.com/playlist?list=PLabcdefghijkl")?.kind, .playlist)
        XCTAssertEqual(r("https://www.youtube.com/live/dQw4w9WgXcQ")?.kind, .live)
        XCTAssertEqual(r("https://vimeo.com/76979871")?.mediaID, "76979871")
        XCTAssertEqual(r("https://vimeo.com/channels/staffpicks/76979871")?.mediaID, "76979871")
        XCTAssertEqual(r("https://player.vimeo.com/video/76979871?h=abc")?.isEmbed, true)
        XCTAssertEqual(r("https://www.tiktok.com/@scout2015/video/6718335390845095173")?.mediaID, "6718335390845095173")
        XCTAssertEqual(r("https://vm.tiktok.com/ZMabc123/")?.isShortLink, true)
        XCTAssertEqual(r("https://www.instagram.com/reel/CxAbC12de/")?.kind, .reel)
        XCTAssertEqual(r("https://www.instagram.com/p/CxAbC12de/")?.kind, .post)
        XCTAssertEqual(r("https://www.facebook.com/watch/?v=1234567890")?.mediaID, "1234567890")
        XCTAssertEqual(r("https://fb.watch/abcDEF12/")?.isShortLink, true)
        XCTAssertEqual(r("https://x.com/someone/status/1234567890123")?.mediaID, "1234567890123")
        XCTAssertEqual(r("https://mobile.twitter.com/someone/status/1234567890123")?.provider, .x)
        XCTAssertEqual(r("https://t.co/AbCdEf")?.isShortLink, true)
        XCTAssertEqual(r("https://old.reddit.com/r/videos/comments/abc123/title/")?.mediaID, "abc123")
        XCTAssertEqual(r("https://redd.it/abc123")?.isShortLink, true)
        XCTAssertEqual(r("https://v.redd.it/xyz789")?.kind, .video)
    }

    func testLookalikesAreNotProviders() {
        for bad in ["https://youtube.com.evil.net/watch?v=dQw4w9WgXcQ", "https://notyoutube.com/watch?v=dQw4w9WgXcQ", "https://youtube.com@evil.net/watch?v=dQw4w9WgXcQ",
                    "https://evil.net/youtube.com/watch?v=dQw4w9WgXcQ", "https://vimeo.com.evil.net/76979871", "https://xn--vimeo-9ua.com/1", "https://vіmeo.com/76979871",
                    "https://x.com.evil.net/a/status/1234567", "ftp://youtube.com/watch?v=dQw4w9WgXcQ", "https://evilt.co/abc", "https://reddit.com.evil.net/r/a/comments/abc123"] {
            XCTAssertNil(r(bad), bad)
        }
    }

    func testAKnownProviderWithAnAddressItDoesNotUnderstandStillBelongsToIt() {
        let m = r("https://www.youtube.com/feed/subscriptions")
        XCTAssertEqual(m?.provider, .youtube); XCTAssertNil(m?.mediaID)
        XCTAssertNil(r("https://www.youtube.com/watch?v=short")?.mediaID, "an id that cannot be one is not taken")
        XCTAssertNil(r("https://example.com/watch?v=dQw4w9WgXcQ"))
    }

    func testTheFrameWinsForWhatPlaysInItAndThePageStaysSeparate() {
        let ctx = MediaPageContext(pageURL: u("https://blog.example.com/post"), frameURL: u("https://player.vimeo.com/video/76979871"), isMainFrame: false, profile: "p")
        let found = ProviderRecognizer.provider(for: ctx)
        XCTAssertNil(found.page); XCTAssertEqual(found.frame?.provider, .vimeo)
        let two = MediaPageContext(pageURL: u("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), frameURL: u("https://player.vimeo.com/video/76979871"), isMainFrame: false, profile: "p")
        XCTAssertEqual(ProviderRecognizer.provider(for: two).page?.provider, .youtube); XCTAssertEqual(ProviderRecognizer.provider(for: two).frame?.provider, .vimeo)
    }
}

final class DX09CapabilityTests: XCTestCase {
    func resolver(api: ProviderAPI = StubAPI(), token: String? = nil) -> ProviderResolver {
        ProviderResolver(api: { _ in api }, token: { _, _ in token })
    }
    func ctx(_ s: String) -> MediaPageContext { MediaPageContext(pageURL: u(s), profile: "default") }

    func testRestrictedProvidersOfferNoDownloadButAnOfficialRoute() async {
        for page in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.instagram.com/reel/CxAbC12de/", "https://www.facebook.com/watch/?v=1234567890", "https://x.com/a/status/1234567", "https://www.reddit.com/r/a/comments/abc123/t/"] {
            let r = await resolver().resolve(ctx(page))
            XCTAssertFalse(r.capabilities.canDownloadNow, page)
            XCTAssertEqual(r.state, .restricted(.noRoute), page)
            XCTAssertNotNil(r.capabilities.alternative, page); XCTAssertTrue(r.sources.isEmpty)
            XCTAssertTrue(r.capabilities.metadata)
        }
        XCTAssertTrue(ProviderCatalog.entry(.youtube).base.requiresProviderApproval)
    }

    func testTikTokIsAnAccountArchiveNotASingleVideo() async {
        let r = await resolver(token: "t").resolve(ctx("https://www.tiktok.com/@a/video/6718335390845095173"))
        XCTAssertTrue(r.capabilities.archiveExport); XCTAssertFalse(r.capabilities.canDownloadNow)
        XCTAssertTrue(r.capabilities.note?.contains("account data") == true)
    }

    func testVimeoNeedsAuthorizationBeforeAnythingIsAsked() async {
        let api = StubAPI()
        let r = await resolver(api: api, token: nil).resolve(ctx("https://vimeo.com/76979871"))
        XCTAssertEqual(r.state, .authorizationRequired); XCTAssertEqual(api.calls, 0, "no request was made without an authorization")
    }

    func testAnUnknownSiteIsGenericAndDownloadable() async {
        let r = await resolver().resolve(ctx("https://example.com/talk"))
        XCTAssertEqual(r.provider, .generic); XCTAssertTrue(r.capabilities.canDownloadNow)
    }

    func testTheButtonRuleHasNoOtherWayOn() {
        var c = MediaProviderCapabilities(directDownload: true)
        XCTAssertTrue(c.canDownloadNow)
        c.requiresAuthentication = true; XCTAssertFalse(c.canDownloadNow)
        c.requiresAuthentication = false; c.restriction = .removed; XCTAssertFalse(c.canDownloadNow)
        XCTAssertFalse(MediaProviderCapabilities(metadata: true, embeddedPlayback: true, archiveExport: true).canDownloadNow)
    }
}

final class StubAPI: ProviderAPI, @unchecked Sendable {
    var calls = 0
    var answers: [Result<Any, Error>] = []
    private let lock = NSLock()
    func data(_ url: URL, method: String, body: Data?, bearer: String?, extraHeaders: [String: String]) async throws -> Data {
        lock.lock(); calls += 1; let next = answers.isEmpty ? nil : answers.removeFirst(); lock.unlock()
        guard let next else { throw ProviderFailure.malformed("nothing stubbed") }
        let value = try next.get()
        return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("1".utf8)
    }
    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) { throw ProviderFailure.malformed("no download stubbed") }
}

final class DX09VimeoTests: XCTestCase {
    let vimeoJSON = """
    {"uri":"/videos/76979871","name":"Owner video","duration":62,"width":1920,"height":1080,"privacy":{"download":true},"pictures":{"base_link":"https://i.vimeocdn.com/video/1_640"},
     "download":[{"quality":"hd","type":"source","width":1920,"height":1080,"link":"https://player.vimeo.com/progressive_redirect/download/1?x=1","size":9000000,"md5":"abc","public_name":"Original","expires":"2099-01-01T00:00:00Z"},
                 {"quality":"sd","type":"video/mp4","width":960,"height":540,"link":"https://player.vimeo.com/progressive_redirect/download/2?x=1","size":3000000,"public_name":"540p"},
                 {"quality":"bad","link":"http://insecure.example/x.mp4","size":1}],
     "files":[{"quality":"hls","link":"https://playback.example/master.m3u8"}]}
    """

    func parse(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testOnlyTheDownloadArrayIsUsedNeverPlaybackFiles() throws {
        let r = try VimeoAPI.sources(from: parse(vimeoJSON), id: "76979871", profile: "p")
        XCTAssertEqual(r.sources.count, 2, "the insecure link and the playback `files` are not sources")
        XCTAssertEqual(r.sources.map(\.quality), ["Original", "540p"])
        XCTAssertEqual(r.metadata.title, "Owner video"); XCTAssertEqual(r.downloadAllowed, true)
        XCTAssertEqual(r.sources[0].expiresAt, ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try VimeoAPI.sources(from: parse(vimeoJSON), id: "1", profile: "p", fetchedAt: fetched).sources[1].expiresAt, fetched.addingTimeInterval(86400), "the documented 24 hours when none is given")
        XCTAssertEqual(r.sources[0].scope, "vimeo:video_files")
    }

    func testResolveFailuresAreNamedAndPermanentOnesAreNotRetried() async throws {
        let ctx = MediaPageContext(pageURL: u("https://vimeo.com/76979871"), profile: "p")
        func run(_ answers: [Result<Any, Error>], token: String? = "tok") async -> (ProviderResolution, Int) {
            let api = StubAPI(); api.answers = answers
            return (await ProviderResolver(api: { _ in api }, token: { _, _ in token }).resolve(ctx), api.calls)
        }
        func http(_ code: String, retry: Bool = false, after: TimeInterval? = nil) -> Result<Any, Error> { var e = HTTPDownloadError(info: DownloadFailureInfo(code: code, reason: "x", retryable: retry)); e.retryAfter = after; return .failure(e) }
        ProviderRetry.scale = 0.01; defer { ProviderRetry.scale = 1 }
        let (a, ca) = await run([http("http:401")]); XCTAssertEqual(a.state, .authorizationRequired); XCTAssertEqual(ca, 1)
        let (b, cb) = await run([http("http:403")]); XCTAssertEqual(b.state, .authorizationRequired); XCTAssertEqual(cb, 1)
        let (c, cc) = await run([http("http:404")]); if case .failed = c.state {} else { XCTFail("\(c.state)") }; XCTAssertEqual(cc, 1)
        let (d, cd) = await run([http("http:429", retry: true, after: 0.01), http("http:429", retry: true, after: 0.01), .success(try parse(vimeoJSON))])
        XCTAssertEqual(d.state, .ready); XCTAssertEqual(cd, 3)
        let (e, ce) = await run([http("http:503", retry: true), http("http:503", retry: true), http("http:503", retry: true), .success(try parse(vimeoJSON))])
        if case .failed = e.state {} else { XCTFail("\(e.state)") }; XCTAssertEqual(ce, 3, "bounded")
        let (f, _) = await run([.success(try parse("{\"name\":\"x\"}"))]); XCTAssertEqual(f.state, .restricted(.noEntitlement))
        let (g, _) = await run([.success(try parse("{\"privacy\":{\"download\":false}}"))]); XCTAssertEqual(g.state, .restricted(.downloadDisabledByOwner))
        let (h, _) = await run([.success(["not": "a video"])]); XCTAssertNotEqual(h.state, .ready)
        let (i, _) = await run([.success(1)]); if case .failed = i.state {} else { XCTFail("malformed answers fail cleanly: \(i.state)") }
    }

    func testRenewalKeepsTheSameFileAndRefusesAnythingElse() async throws {
        let ctx = MediaPageContext(pageURL: u("https://vimeo.com/76979871"), profile: "p")
        let old = try VimeoAPI.sources(from: parse(vimeoJSON), id: "76979871", profile: "p").sources[0]
        func renew(_ json: String) async throws -> AuthorizedMediaSource {
            let api = StubAPI(); api.answers = [.success(try parse(json))]
            return try await ProviderResolver(api: { _ in api }, token: { _, _ in "tok" }).renew(old, context: ctx)
        }
        let same = vimeoJSON.replacingOccurrences(of: "download/1?x=1", with: "download/1?x=NEW")
        let fresh = try await renew(same)
        XCTAssertTrue(fresh.url.absoluteString.contains("x=NEW")); XCTAssertEqual(fresh.identity, old.identity)
        // another quality or a different file behind the same name
        for bad in [vimeoJSON.replacingOccurrences(of: "\"size\":9000000", with: "\"size\":8000000"), vimeoJSON.replacingOccurrences(of: "\"md5\":\"abc\"", with: "\"md5\":\"zzz\""), vimeoJSON.replacingOccurrences(of: "\"public_name\":\"Original\"", with: "\"public_name\":\"Other\"")] {
            do { _ = try await renew(bad); XCTFail("a different file replaced the old one") } catch {}
        }
        // a link on a server nobody was using
        do { _ = try await renew(same.replacingOccurrences(of: "player.vimeo.com/progressive_redirect/download/1", with: "evil.example.net/x/1")); XCTFail("moved to another server") }
        catch let e as ProviderSourceCheck.Problem { XCTAssertEqual(e, .hostNotAllowed("example.net")) }
        // another profile
        var elsewhere = old; elsewhere.profile = "other"
        XCTAssertThrowsError(try ProviderSourceCheck.verifyRenewal(old: old, new: elsewhere))
        var other = old; other.mediaID = "999"
        XCTAssertThrowsError(try ProviderSourceCheck.verifyRenewal(old: old, new: other))
        var cannot = old; cannot.canRefresh = false
        XCTAssertThrowsError(try ProviderSourceCheck.verifyRenewal(old: cannot, new: old))
    }

    func testSourceValidation() throws {
        var s = try VimeoAPI.sources(from: parse(vimeoJSON), id: "1", profile: "p").sources[0]
        XCTAssertNoThrow(try ProviderSourceCheck.validate(s))
        s.url = u("https://192.168.1.5/x.mp4"); XCTAssertThrowsError(try ProviderSourceCheck.validate(s))
        s.url = u("https://localhost/x.mp4"); XCTAssertThrowsError(try ProviderSourceCheck.validate(s))
        s.url = u("http://player.vimeo.com/x.mp4"); XCTAssertThrowsError(try ProviderSourceCheck.validate(s))
        s.url = u("https://player.vimeo.com/x.mp4"); s.expiresAt = Date(timeIntervalSinceNow: -1); XCTAssertThrowsError(try ProviderSourceCheck.validate(s))
    }

    func testTheTokenIsPerProviderAndPerProfileAndOnlyGoesToTheProvidersApiHost() async throws {
        let api = FetcherProviderAPI(provider: .vimeo, network: DownloadNetworkSetup())
        do { _ = try await api.data(u("https://evil.example.net/videos/1"), method: "GET", body: nil, bearer: "SECRET", extraHeaders: [:]); XCTFail("sent to another host") } catch let e as ProviderFailure { XCTAssertEqual(e, .malformed("an address outside the website's API")) }
        do { _ = try await api.data(u("https://api.vimeo.com.evil.net/videos/1"), method: "GET", body: nil, bearer: "SECRET", extraHeaders: [:]); XCTFail() } catch {}
        let profileA = "dx09-a-\(UUID().uuidString)", profileB = "dx09-b-\(UUID().uuidString)"
        defer { ProviderCredentials.revoke(.vimeo, profile: profileA); ProviderCredentials.revoke(.vimeo, profile: profileB) }
        XCTAssertTrue(ProviderCredentials.store("tokA", .vimeo, profile: profileA))
        XCTAssertEqual(ProviderCredentials.token(.vimeo, profile: profileA), "tokA"); XCTAssertNil(ProviderCredentials.token(.vimeo, profile: profileB))
        ProviderCredentials.revoke(.vimeo, profile: profileA); XCTAssertNil(ProviderCredentials.token(.vimeo, profile: profileA))
    }
}

final class DX09ParserTests: XCTestCase {
    func j(_ t: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(t.utf8)) }

    func testTikTokPortabilityStatesAndMalformedAnswers() throws {
        func state(_ s: String) throws -> TikTokPortability.State { try TikTokPortability.parse(j("{\"data\":{\"request_id\":\"r1\",\"status\":\"\(s)\",\"data_format\":\"json\",\"category_selection_list\":[\"video\"]}}")).state }
        XCTAssertEqual(try state("pending"), .pending); XCTAssertEqual(try state("downloading"), .ready); XCTAssertEqual(try state("expired"), .expired); XCTAssertEqual(try state("cancelled"), .cancelled); XCTAssertEqual(try state("failed"), .failed)
        XCTAssertEqual(try state("weird"), .unknown("weird"))
        XCTAssertEqual(try TikTokPortability.parse(j("{\"request_id\":\"r2\",\"status\":\"pending\"}")).requestID, "r2")
        XCTAssertThrowsError(try TikTokPortability.parse(j("{\"data\":{}}")))
        XCTAssertThrowsError(try TikTokPortability.parse(j("[]")))
    }

    func testXMediaEntitiesAreDescribedNotAuthorized() throws {
        let m = XMediaEntities.parse(try j("{\"includes\":{\"media\":[{\"media_key\":\"1\",\"type\":\"video\",\"duration_ms\":5000,\"width\":640,\"height\":360,\"variants\":[{\"bit_rate\":832000,\"content_type\":\"video/mp4\",\"url\":\"https://video.twimg.com/a.mp4\"}]}]}}"))
        XCTAssertEqual(m.duration, 5); XCTAssertEqual(m.described, ["video video/mp4 832 kbit/s"])
        XCTAssertEqual(XMediaEntities.parse([:]).described, [])
    }

    func testRedditPosts() throws {
        let video = try RedditPost.parse(j("[{\"data\":{\"children\":[{\"data\":{\"title\":\"t\",\"media\":{\"reddit_video\":{\"duration\":12,\"width\":720,\"height\":1280,\"has_audio\":false,\"hls_url\":\"https://v.redd.it/x/HLSPlaylist.m3u8\"}}}}]}}]"))
        XCTAssertTrue(video.hostedVideo); XCTAssertEqual(video.metadata.duration, 12); XCTAssertTrue(video.metadata.described[0].contains("no sound"))
        let ext = try RedditPost.parse(j("{\"data\":{\"children\":[{\"data\":{\"title\":\"t\",\"url_overridden_by_dest\":\"https://files.example.org/a.mp4\"}}]}}"))
        XCTAssertEqual(ext.externalLink?.host, "files.example.org")
        let own = try RedditPost.parse(j("{\"data\":{\"children\":[{\"data\":{\"url_overridden_by_dest\":\"https://v.redd.it/x\"}}]}}"))
        XCTAssertNil(own.externalLink, "Reddit's own hosts are not an ordinary link")
        let gal = try RedditPost.parse(j("{\"data\":{\"children\":[{\"data\":{\"is_gallery\":true,\"gallery_data\":{\"items\":[{\"media_id\":\"a\"},{\"media_id\":\"b\"}]},\"removed_by_category\":\"moderator\"}}]}}"))
        XCTAssertEqual(gal.galleryItems, 2); XCTAssertTrue(gal.removed)
        XCTAssertThrowsError(try RedditPost.parse(j("{\"data\":{\"children\":[]}}")))
    }
}

final class DX09StateTests: XCTestCase {
    func testOnlyLegalMovesAreAllowedAndCancelIsTerminal() {
        XCTAssertTrue(ProviderOperationState.identifying.canMove(to: .discovering))
        XCTAssertTrue(ProviderOperationState.resolving.canMove(to: .ready))
        XCTAssertTrue(ProviderOperationState.ready.canMove(to: .refreshRequired))
        XCTAssertTrue(ProviderOperationState.refreshRequired.canMove(to: .resolving))
        XCTAssertFalse(ProviderOperationState.ready.canMove(to: .identifying))
        XCTAssertFalse(ProviderOperationState.restricted(.noRoute).canMove(to: .ready))
        XCTAssertFalse(ProviderOperationState.failed("x").canMove(to: .ready))
        XCTAssertTrue(ProviderOperationState.resolving.canMove(to: .cancelled))
        XCTAssertFalse(ProviderOperationState.cancelled.canMove(to: .resolving))
    }

    func testFailuresAreSortedIntoTransientAndPermanent() {
        XCTAssertTrue(ProviderFailure.rateLimited(3).isTransient); XCTAssertTrue(ProviderFailure.serverTrouble.isTransient); XCTAssertTrue(ProviderFailure.offline.isTransient)
        XCTAssertFalse(ProviderFailure.authorizationRequired.isTransient); XCTAssertFalse(ProviderFailure.removed.isTransient); XCTAssertFalse(ProviderFailure.malformed("x").isTransient)
        XCTAssertEqual(ProviderFailure.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ProviderFailure.from(CancellationError()), .cancelled)
    }
}

final class DX09ReviewFixTests: XCTestCase {
    func candidate(page: String?, url: String) -> MediaCandidate {
        MediaCandidate(id: "c", profile: "p", isPrivate: false, pageKey: "1|x", pageHost: page, mechanism: .videoElement, kind: .directVideo, url: url, display: "d", name: "n", mime: "video/mp4", duration: nil, state: .recognized, manifest: nil, firstSeen: Date(), lastObserved: Date())
    }
    /// Provider identity alone blocks nothing: a plain, unprotected file or stream is downloadable wherever it is found, whoever serves it. What decides is what it is.
    func testProviderIdentityAloneDoesNotBlockAPlainDownload() {
        let pages: [(String, String)] = [("www.youtube.com", "https://r1.googlevideo.com/x.mp4"), ("blog.example", "https://r1.googlevideo.com./x.mp4"), ("vimeo.com", "https://vod.vimeocdn.com/x.mp4"),
                                         ("www.instagram.com", "https://scontent.fna.fbcdn.net/v.mp4"), ("www.reddit.com", "https://i.redd.it/a.mp4"), ("x.com", "https://video.twimg.com/a.mp4"),
                                         ("www.tiktok.com", "https://v16.tiktokcdn.com/a.mp4"), ("www.facebook.com", "https://video.fbcdn.net/a.mp4"), ("example.com", "https://example.com/talk.mp4")]
        for (page, url) in pages {
            let c = candidate(page: page, url: url)
            XCTAssertTrue(c.canOpen, "\(page) \(url)"); XCTAssertTrue(c.downloadSupported, "\(page) \(url)")
        }
    }

    /// What does block: protected media, an in-page (blob) stream, an expired link. Those are about the media, not the website.
    func testCapabilityStillBlocksProtectedBlobAndExpiredMedia() {
        for kind in [MediaCandidateKind.protected, .blob] {
            var c = candidate(page: "www.reddit.com", url: "https://i.redd.it/a.mp4"); c.kind = kind
            XCTAssertFalse(c.canOpen, "\(kind)")
        }
        var expired = candidate(page: "example.com", url: "https://example.com/a.mp4"); expired.expiresAt = Date(timeIntervalSinceNow: -60)
        XCTAssertFalse(expired.canOpen)
    }

    /// The provider note is background for the picker, never a verdict.
    func testProviderNoteIsInformationalOnly() {
        let c = candidate(page: "www.reddit.com", url: "https://i.redd.it/a.mp4")
        XCTAssertEqual(ProviderPolicy.governing(c), .reddit)
        XCTAssertNotNil(ProviderPolicy.note(for: c)); XCTAssertTrue(c.canOpen)
        XCTAssertNil(ProviderPolicy.governing(candidate(page: "example.com", url: "https://example.com/talk.mp4")))
        XCTAssertNil(ProviderPolicy.governing(candidate(page: "www.reddit.com", url: "https://files.example.org/a.mp4")), "an ordinary link from a provider's page")
    }

    func testUserinfoCannotChangeWhoTheHostIs() {
        XCTAssertEqual(ProviderRecognizer.recognize(URL(string: "https://x@www.youtube.com/watch?v=dQw4w9WgXcQ")!)?.provider, .youtube)
        XCTAssertNil(ProviderRecognizer.recognize(URL(string: "https://www.youtube.com@evil.net/watch?v=dQw4w9WgXcQ")!))
        XCTAssertEqual(ProviderRecognizer.recognize(URL(string: "https://www.youtube.com./watch?v=dQw4w9WgXcQ")!)?.provider, .youtube)
    }

    func testRenewalNeedsSomethingToCompareAndDoesNotTrustASharedDomain() {
        var a = AuthorizedMediaSource(provider: .vimeo, mediaID: "1", url: URL(string: "https://player.vimeo.com/a")!, type: .directFile, profile: "p", scope: "s", expiresAt: nil, contentType: nil, quality: "hd", width: nil, height: nil, bytes: nil, md5: nil, title: nil, canRefresh: true)
        XCTAssertThrowsError(try ProviderSourceCheck.verifyRenewal(old: a, new: a), "nothing to show it is the same file")
        a.bytes = 100
        var b = a; b.url = URL(string: "https://tenant2.cloudfront.net/a")!
        var old = a; old.url = URL(string: "https://tenant1.cloudfront.net/a")!
        XCTAssertThrowsError(try ProviderSourceCheck.verifyRenewal(old: old, new: b), "another tenant of the same storage service")
        XCTAssertNoThrow(try ProviderSourceCheck.verifyRenewal(old: a, new: { var n = a; n.url = URL(string: "https://vod.vimeocdn.com/z")!; return n }()))
        var z = a; z.width = 0; XCTAssertNotEqual(z.identity, a.identity, "absent is not zero")
    }

    func testAPrivateTabNeverUsesTheAccountsToken() async {
        let stub = StubAPI()
        let resolver = ProviderResolver(api: { _ in stub }, token: { _, _ in "tok" })
        let r = await resolver.resolve(MediaPageContext(pageURL: URL(string: "https://vimeo.com/76979871")!, profile: "p", isPrivate: true))
        XCTAssertEqual(r.state, .authorizationRequired); XCTAssertEqual(stub.calls, 0)
    }

    func testTikTokStatusWordsAreNotMatchedLoosely() throws {
        func s(_ w: String) throws -> TikTokPortability.State { try TikTokPortability.parse(["request_id": "r", "status": w]).state }
        XCTAssertEqual(try s("pending_download"), .pending); XCTAssertEqual(try s("not_ready"), .unknown("not_ready")); XCTAssertEqual(try s("incomplete"), .unknown("incomplete"))
    }
}

final class DX09PeerTubeTests: XCTestCase {
    // Shape taken from a live public instance's GET /api/v1/videos/<uuid> (fields kept, values invented).
    let json = """
    {"uuid":"f4f932c0-ff57-4733-83ae-503d9a18bb0d","shortUUID":"wfwdWFaJiog47QWQGYXrkB","name":"A public clip","duration":62,"privacy":{"id":1,"label":"Public"},"isLive":false,"downloadEnabled":true,"thumbnailPath":"/lazy-static/thumbnails/x.jpg",
     "files":[{"id":1,"resolution":{"id":720,"label":"720p"},"height":720,"size":9000000,"hasVideo":true,"hasAudio":true,"fileUrl":"https://static.example.org/web-videos/a-720.mp4","fileDownloadUrl":"https://static.example.org/download/web-videos/a-720.mp4"},
              {"id":2,"resolution":{"id":0,"label":"Audio only"},"height":0,"size":900000,"hasVideo":false,"hasAudio":true,"fileUrl":"https://static.example.org/web-videos/a-0.mp4","fileDownloadUrl":"https://static.example.org/download/web-videos/a-0.mp4"}],
     "streamingPlaylists":[{"type":1,"playlistUrl":"https://static.example.org/streaming-playlists/hls/x/master.m3u8","files":[]}]}
    """
    func obj(_ s: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(s.utf8)) }

    func testPublicVideoGivesItsFilesAndTheAdaptiveStream() throws {
        let r = try PeerTubeAPI.sources(from: obj(json), host: "tube.example.org", profile: "p")
        XCTAssertEqual(r.sources.map(\.quality), ["720p", "Audio only", "Adaptive stream (HLS)"])
        XCTAssertEqual(r.sources.map(\.type), [.directFile, .directFile, .hls])
        XCTAssertEqual(r.sources[0].bytes, 9_000_000); XCTAssertEqual(r.sources[0].url.host, "static.example.org")
        XCTAssertTrue(r.sources.allSatisfy { !$0.canRefresh && $0.scope == "peertube:public" })
    }

    func testEveryWayItCanBeRefusedIsNamed() throws {
        func fail(_ replace: (String, String)) -> ProviderFailure? {
            do { _ = try PeerTubeAPI.sources(from: obj(json.replacingOccurrences(of: replace.0, with: replace.1)), host: "t", profile: "p"); return nil } catch { return error as? ProviderFailure }
        }
        XCTAssertEqual(fail(("\"downloadEnabled\":true", "\"downloadEnabled\":false")), .restricted(.downloadDisabledByOwner))
        XCTAssertEqual(fail(("\"isLive\":false", "\"isLive\":true")), .restricted(.live))
        XCTAssertEqual(fail(("\"privacy\":{\"id\":1", "\"privacy\":{\"id\":3")), .restricted(.privateContent))
        XCTAssertThrowsError(try PeerTubeAPI.sources(from: obj("{\"error\":\"Video not found\"}"), host: "t", profile: "p"))
        XCTAssertThrowsError(try PeerTubeAPI.sources(from: obj("[]"), host: "t", profile: "p"))
    }

    func testOnlyVideoShapedAddressesAreCandidatesAndKnownSitesAreNeverPeerTube() {
        func shape(_ s: String) -> ProviderMatch? { ProviderRecognizer.peerTubeShape(URL(string: s)!) }
        XCTAssertEqual(shape("https://tube.example.org/w/wfwdWFaJiog47QWQGYXrkB")?.mediaID, "wfwdWFaJiog47QWQGYXrkB")
        XCTAssertEqual(shape("https://tube.example.org/videos/watch/f4f932c0-ff57-4733-83ae-503d9a18bb0d")?.provider, .peertube)
        XCTAssertEqual(shape("https://tube.example.org/videos/embed/wfwdWFaJiog47QWQGYXrkB")?.isEmbed, true)
        XCTAssertNil(shape("https://wiki.example.org/w/index.php"), "a wiki's /w/ is not a video")
        XCTAssertNil(shape("https://wiki.example.org/w/load.php?x=1"))
        XCTAssertNil(shape("https://www.youtube.com/w/abcdefghijk"), "a known site is never taken for PeerTube")
        XCTAssertNil(shape("https://tube.example.org/w/short"))
        XCTAssertNil(shape("https://tube.example.org/watch?v=abcdefghij"))
    }

    func testTheInstanceApiTalksToOneHostOverHttpsAndNeverCarriesACredential() async {
        let api = FetcherProviderAPI(provider: .peertube, network: DownloadNetworkSetup(), allowedHost: "tube.example.org")
        do { _ = try await api.data(URL(string: "https://evil.example.net/api/v1/videos/x")!, method: "GET", body: nil, bearer: nil, extraHeaders: [:]); XCTFail("another host") } catch let e as ProviderFailure { XCTAssertEqual(e, .malformed("an address outside the website's API")) } catch {}
        do { _ = try await api.data(URL(string: "http://tube.example.org/api/v1/videos/x")!, method: "GET", body: nil, bearer: nil, extraHeaders: [:]); XCTFail("plain http") } catch let e as ProviderFailure { XCTAssertEqual(e, .malformed("not https")) } catch {}
        do { _ = try await api.data(URL(string: "https://tube.example.org/api/v1/videos/x")!, method: "GET", body: nil, bearer: "SECRET", extraHeaders: [:]); XCTFail("a credential for an unknown server") } catch let e as ProviderFailure { XCTAssertEqual(e, .malformed("a credential for an unknown server")) } catch {}
    }
}
