import XCTest
@testable import Browser_Setu

/// Fixes from the DX-01 independent review.
@MainActor
final class DX01ReviewFixTests: XCTestCase {
    func testOtherSpellingsOfLocalAddressesAreNotPublic() {
        for h in ["127.1", "0x7f.0.0.1", "0177.0.0.1", "2130706433", "0x7f000001", "10.1", "192.168.1"] {
            XCTAssertTrue(HTTPRequestPolicy.classify(host: h).isInternal, h)
        }
        for h in ["tracker.example.com", "93.184.216.34", "a1.example.org"] { XCTAssertFalse(HTTPRequestPolicy.classify(host: h).isInternal, h) }
    }

    func testPageMagnetsDropNumericSpellingTrackers() {
        let urls = ["http://127.1:8080/announce", "http://0x7f.0.0.1/a", "http://tracker.example.com/announce"].compactMap(URL.init(string:))
        XCTAssertEqual(TorrentRunner.usableTrackers(urls, origin: .page).map { $0.host }, ["tracker.example.com"])
    }

    func testHTTPTrackerPeersMustBeNumeric() throws {
        let body = BencodeDecoder.encode(.dict(["interval": .int(900), "peers": .list([
            .dict(["ip": TorrentFixture.b("evil.example.com"), "port": .int(22)]),
            .dict(["ip": TorrentFixture.b("127.1"), "port": .int(22)]),
            .dict(["ip": TorrentFixture.b("198.51.100.7"), "port": .int(51413)])])]))
        XCTAssertEqual(try HTTPTrackerClient.parse(body).peers.map(\.host), ["198.51.100.7"])
    }

    func testScrapeReplyKeyedByRawHashIsRead() throws {
        var body = Data("d5:filesd20:".utf8)
        body.append(Data([0xff, 0xfe, 0x80, 0x01, 0xc3, 0x28, 0xa0, 0xa1, 0xfa, 0xfb, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90]))
        body.append(Data("d8:completei7e10:downloadedi3e10:incompletei2eeee".utf8))
        let r = try HTTPTrackerClient.parseScrape(body)
        XCTAssertEqual(r.seeders, 7); XCTAssertEqual(r.completed, 3); XCTAssertEqual(r.leechers, 2)
    }

    func testTrackerRowIdsCarryNoPathOrKey() {
        let book = TrackerBook(tiers: [[URL(string: "http://t.example.com/announce?passkey=SECRET")!]])
        XCTAssertFalse(book.statuses(at: 0).map(\.id).joined().contains("SECRET"))
    }

    func testSavedTiersComeBackAfterResume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dx01-tiers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var m = try TorrentFixture.build(name: "n", files: [(["a"], 40_000)]).meta
        m.trackers = [URL(string: "udp://a.example.com:1")!, URL(string: "udp://b.example.com:2")!]
        m.trackerTiers = [m.trackers]
        try TorrentRunner.saveSidecar(dir, meta: m, selected: [0], trackers: m.trackers)
        let loaded = try XCTUnwrap(TorrentRunner.loadSidecar(dir, expectedHash: m.infoHashHex))
        XCTAssertEqual(loaded.meta.trackerTiers.map { $0.map { $0.host ?? "" } }, [["a.example.com", "b.example.com"]])
    }
}

/// The permission a page's link needs before a tracker on the local network is used.
@MainActor
final class LocalTrackerPermissionTests: XCTestCase {
    private let lan = URL(string: "udp://192.168.1.25:6969/announce?key=SECRET")!
    private let other = URL(string: "udp://192.168.1.26:6969")!
    private let pub = URL(string: "udp://tracker.example.com:6969")!
    typealias Answer = LocalTrackerPermission.Answer

    private func make(_ clock: Clock? = nil) -> (LocalTrackerPermission, UserDefaults) {
        let d = UserDefaults(suiteName: "perm-\(UUID().uuidString)")!
        return (LocalTrackerPermission(defaults: d, now: { clock?.now ?? Date() }), d)
    }
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1000) }

    func testCancelAllowsNothingAndIsTheSafeAnswer() async {
        let (p, _) = make()
        let got = await p.authorize([lan, pub], origin: .page, source: nil) { _ in Answer(allowed: false) }
        XCTAssertEqual(got, .init())
        XCTAssertTrue(p.granted().isEmpty)
    }

    func testAllowOnceCoversOnlyThatDestinationAndExpires() async {
        let clock = Clock(); let (p, _) = make(clock)
        let got = await p.authorize([lan, other], origin: .page, source: nil) { prompt in
            XCTAssertFalse(prompt.details.map { $0.1 }.joined().contains("SECRET"), "the key is never shown")
            return Answer(allowed: true)
        }
        XCTAssertEqual(got.trackers.count, 2); XCTAssertTrue(got.peers.isEmpty, "the tracker is allowed; the computers it lists are a separate choice")
        let again = await p.authorize([lan], origin: .page, source: nil) { _ in XCTFail("already covered"); return Answer(allowed: false) }
        XCTAssertEqual(again.trackers, [LocalTrackerPermission.key(lan)])
        let unrelated = await p.authorize([URL(string: "udp://192.168.1.99:6969")!], origin: .page, source: nil) { _ in Answer(allowed: false) }
        XCTAssertTrue(unrelated.trackers.isEmpty, "a grant for one address says nothing about another")
        clock.now += LocalTrackerPermission.onceLifetime + 1
        XCTAssertTrue(p.granted().isEmpty)
    }

    func testPeersAreAllowedOnlyWhenAskedForAndSeparately() async {
        let (p, _) = make()
        let got = await p.authorize([lan], origin: .page, source: nil) { _ in Answer(allowed: true, remember: false, peers: true) }
        XCTAssertEqual(got.peers, [LocalTrackerPermission.key(lan)])
        let prompt = LocalTrackerPermission.prompt([lan], source: nil, isPrivateSession: false)
        XCTAssertTrue(prompt.risk.contains("does not let Browser Setu connect to the computers the tracker lists"))
    }

    func testRememberPersistsAndCanBeRevoked() async {
        let (p, d) = make()
        _ = await p.authorize([lan], origin: .page, source: nil) { _ in Answer(allowed: true, remember: true, peers: true) }
        let reloaded = LocalTrackerPermission(defaults: d)
        XCTAssertEqual(reloaded.rememberedDestinations, ["udp://192.168.1.25:6969"])
        XCTAssertEqual(reloaded.rememberedPeerDestinations, ["udp://192.168.1.25:6969"])
        XCTAssertFalse((d.stringArray(forKey: "downloads.localTrackerGrants") ?? []).joined().contains("SECRET"))
        reloaded.revoke("udp://192.168.1.25:6969")
        let after = LocalTrackerPermission(defaults: d)
        XCTAssertTrue(after.granted().isEmpty); XCTAssertTrue(after.grantedPeers().isEmpty)
    }

    func testAPrivateSessionNeverRemembersNeverSharesAndEnds() async {
        let (p, d) = make()
        _ = await p.authorize([lan], origin: .page, source: nil) { _ in Answer(allowed: true, remember: true) }          // a normal session remembers it
        var offered: String?? = nil
        let got = await p.authorize([lan], origin: .page, source: nil, isPrivateSession: true) { prompt in offered = .some(prompt.rememberLabel); return Answer(allowed: true, remember: true, peers: true) }
        XCTAssertNotNil(offered, "a private session is asked even though a normal session remembered it")
        XCTAssertNil(offered!, "and is not offered Remember")
        XCTAssertEqual(got.trackers.count, 1)
        XCTAssertEqual(LocalTrackerPermission(defaults: d).rememberedDestinations, ["udp://192.168.1.25:6969"], "nothing new was written")
        XCTAssertEqual(p.granted(isPrivate: true), [LocalTrackerPermission.key(lan)])
        let (q, _) = make()
        _ = await q.authorize([other], origin: .page, source: nil, isPrivateSession: true) { _ in Answer(allowed: true) }
        XCTAssertTrue(q.granted().isEmpty, "a private grant is not seen by a normal session")
        q.endPrivateSession()
        XCTAssertTrue(q.granted(isPrivate: true).isEmpty, "and it ends with the private session")
    }

    func testOnlyTheRequestsOwnTaskDecidesWhichApprovalCounts() async {
        let (p, _) = make()
        let a = UUID(), b = UUID()
        p.trust(task: a, keys: [LocalTrackerPermission.key(lan)])
        let inA = TrackerScope.$task.withValue(a) { p.isAuthorized(lan) }
        let inB = TrackerScope.$task.withValue(b) { p.isAuthorized(lan) }
        XCTAssertTrue(inA); XCTAssertFalse(inB, "another task's approval is not borrowed")
        XCTAssertFalse(p.isAuthorized(lan), "nor is it visible outside any task")
        p.trust(task: b, keys: [], isPrivate: true)
        _ = await p.authorize([other], origin: .page, source: nil) { _ in Answer(allowed: true, remember: true) }
        XCTAssertTrue(TrackerScope.$task.withValue(a) { p.isAuthorized(other) })
        XCTAssertFalse(TrackerScope.$task.withValue(b) { p.isAuthorized(other) }, "a private task does not use what a normal session was granted")
    }

    func testThePersonsOwnRequestIsNotAskedAndAPublicTrackerNeedsNoGrant() async {
        let (p, _) = make()
        let own = await p.authorize([lan], origin: .user, source: nil) { _ in XCTFail("not asked"); return Answer(allowed: false) }
        XCTAssertEqual(own.trackers, [LocalTrackerPermission.key(lan)])
        let pubOnly = await p.authorize([pub], origin: .page, source: nil) { _ in XCTFail("nothing local"); return Answer(allowed: false) }
        XCTAssertTrue(pubOnly.trackers.isEmpty)
    }

    func testGrantedTrackerSurvivesTheFilterAndNothingElseDoes() {
        let granted: Set<String> = [LocalTrackerPermission.key(lan)]
        XCTAssertEqual(TorrentRunner.usableTrackers([lan, other, pub], origin: .page, granted: granted), [lan, pub])
    }

    func testTheDialogsTestHandlerMapsToAnswers() async {
        let prompt = LocalTrackerPermission.prompt([lan], source: nil, isPrivateSession: false)
        Dialogs.testHandler = { _, _, _ in 0 }
        var a = await Dialogs.permission(prompt); XCTAssertFalse(a.allowed)
        Dialogs.testHandler = { _, _, _ in 1 }
        a = await Dialogs.permission(prompt); XCTAssertTrue(a.allowed); XCTAssertFalse(a.remember); XCTAssertFalse(a.peers)
        Dialogs.testHandler = { _, _, _ in 7 }
        a = await Dialogs.permission(prompt); XCTAssertTrue(a.allowed); XCTAssertTrue(a.remember); XCTAssertTrue(a.peers)
        let priv = LocalTrackerPermission.prompt([lan], source: nil, isPrivateSession: true)
        a = await Dialogs.permission(priv); XCTAssertFalse(a.remember, "never offered, so never given")
        Dialogs.testHandler = nil
    }
}

// MARK: Final security closure

private final class ScriptedHTTP: PinnedHTTPConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(url: URL, address: String)] = []
    private(set) var flags: [(Bool, Bool)] = []
    var responder: (URL, String) -> PinnedHTTPResult = { _, _ in PinnedHTTPResult(status: 200, location: nil, body: Data("d8:intervali900e5:peers0:e".utf8)) }
    func get(_ url: URL, address: String, maxBody: Int, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        lock.lock(); requests.append((url, address)); flags.append((refuseExpensive, refuseConstrained)); lock.unlock()
        return responder(url, address)
    }
}

private final class FlippingResolver: HostAddressResolving, @unchecked Sendable {
    private let lock = NSLock(); private(set) var calls = 0
    func addresses(for host: String) async -> [String]? { lock.lock(); calls += 1; let n = calls; lock.unlock(); return n == 1 ? ["198.51.100.20"] : ["127.0.0.1"] }
}

final class HTTPTrackerDestinationTests: XCTestCase {
    private let infoHash = Data(count: 20), peerId = Data(count: 20)
    private func announce(_ c: HTTPTrackerClient, _ url: String) async throws -> TrackerReply {
        try await c.announce(URL(string: url)!, infoHash: infoHash, peerID: peerId, uploaded: 0, downloaded: 0, left: 1, event: nil)
    }

    func testANameThatResolvesToTheLANIsRefusedBeforeAnythingIsSent() async {
        let http = ScriptedHTTP()
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["192.168.1.7"]]), connector: http)
        do { _ = try await announce(c, "http://t.example.com/announce"); XCTFail() } catch { XCTAssertEqual(error as? HTTPTrackerClient.Failure, .blocked("This tracker's address (or a redirect from it) points to a local address, so it was not contacted.")) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAnApprovedDestinationWhoseNameIsLocalGoesThroughAndNothingElseDoes() async throws {
        let http = ScriptedHTTP()
        let ok = URL(string: "http://t.example.com/announce")!
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["192.168.1.7"], "u.example.com": ["192.168.1.7"]]), connector: http, authorized: { LocalTrackerPermission.key($0) == LocalTrackerPermission.key(ok) })
        _ = try await announce(c, ok.absoluteString)
        XCTAssertEqual(http.requests.first?.address, "192.168.1.7")
        do { _ = try await announce(c, "http://u.example.com/announce"); XCTFail("an unrelated name") } catch { XCTAssertTrue(error is HTTPTrackerClient.Failure) }
    }

    func testARedirectToLocalhostOrTheLANIsRefusedUnlessThatDestinationWasApproved() async throws {
        let http = ScriptedHTTP()
        http.responder = { url, _ in url.host == "t.example.com" ? PinnedHTTPResult(status: 302, location: "http://127.0.0.1:9000/x", body: Data()) : PinnedHTTPResult(status: 200, location: nil, body: Data("d8:intervali900e5:peers0:e".utf8)) }
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http)
        do { _ = try await announce(c, "http://t.example.com/announce"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("blocked")) }
        XCTAssertEqual(http.requests.count, 1, "the redirect target was never requested")
        let approved = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http, authorized: { $0.host == "127.0.0.1" })
        _ = try await announce(approved, "http://t.example.com/announce")
    }

    func testTheCheckedAddressIsTheOneConnectedToEvenIfTheNameChangesAfterwards() async throws {
        let http = ScriptedHTTP(), resolver = FlippingResolver()
        let c = HTTPTrackerClient(resolver: resolver, connector: http)
        _ = try await announce(c, "http://t.example.com/announce")
        XCTAssertEqual(http.requests.map(\.address), ["198.51.100.20"], "connected to the address that was checked")
        XCTAssertEqual(resolver.calls, 1, "the name is looked up once for the request")
    }

    func testAnnouncesAdvertiseNoListeningPort() async throws {
        let http = ScriptedHTTP()
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http)
        _ = try await announce(c, "http://t.example.com/announce")
        XCTAssertTrue(http.requests[0].url.absoluteString.contains("port=0&"))
    }

    func testTheSystemProxyIsHonouredAndAPageRequestIsNeverSentThroughOne() async throws {
        let http = ScriptedHTTP()
        // "Use my Mac's settings" with a proxy set on the Mac: the request does not go direct. For a page's request it is refused outright; nothing is connected to.
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http, systemProxyActive: { true })
        do {
            _ = try await TrackerScope.$origin.withValue(.page) { try await announce(c, "http://t.example.com/announce") }
            XCTFail()
        } catch { XCTAssertTrue(error is HTTPTrackerClient.Failure, "\(error)") }
        XCTAssertTrue(http.requests.isEmpty, "nothing went direct around the proxy")
        // With no proxy on the Mac the same request is made directly.
        let direct = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http, systemProxyActive: { false })
        _ = try await announce(direct, "http://t.example.com/announce")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testExpensiveAndConstrainedNetworkChoicesReachTheConnection() async throws {
        let http = ScriptedHTTP()
        var setup = DownloadNetworkSetup(); setup.refuseExpensive = true; setup.refuseConstrained = true; setup.proxy.mode = .direct
        let c = HTTPTrackerClient(network: { setup }, resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http)
        _ = try await announce(c, "http://t.example.com/announce")
        XCTAssertTrue(http.flags[0].0); XCTAssertTrue(http.flags[0].1)
    }

    func testTooManyRedirectsAreRefused() async {
        let http = ScriptedHTTP()
        http.responder = { _, _ in PinnedHTTPResult(status: 302, location: "http://t.example.com/again", body: Data()) }
        let c = HTTPTrackerClient(resolver: FixedResolver(table: ["t.example.com": ["198.51.100.20"]]), connector: http)
        do { _ = try await announce(c, "http://t.example.com/announce"); XCTFail() } catch { XCTAssertEqual(http.requests.count, HTTPTrackerClient.maxRedirects + 1) }
    }

    func testTheHTTPReplyParserReadsStatusRedirectAndRefusesChunking() throws {
        let ok = try NWPinnedHTTP.parse(Data("HTTP/1.0 302 Found\r\nLocation: /x\r\nContent-Length: 2\r\n\r\nabcdef".utf8), maxBody: 100)
        XCTAssertEqual(ok.status, 302); XCTAssertEqual(ok.location, "/x"); XCTAssertEqual(ok.body, Data("ab".utf8))
        XCTAssertThrowsError(try NWPinnedHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), maxBody: 100))
        XCTAssertThrowsError(try NWPinnedHTTP.parse(Data("garbage".utf8), maxBody: 100))
    }
}

final class DX01LifecycleClosureTests: TorrentSessionTestCase {
    private func make(_ t: TorrentFixture.Built, tracker: RecordingTracker, trackers: [URL], settings: TorrentSession.Settings = .testing, have: Set<Int> = []) throws -> (TorrentSession, TorrentSessionTestCase.Events, FakePeers) {
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        let factory = FakePeers { _, q in FakePeer(queue: q, stream: t.stream, meta: t.meta, infoHash: t.meta.infoHash) }
        let events = Events()
        let s = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: trackers, storage: { storage }, alreadyHave: have, transports: factory, tracker: tracker, download: nil, upload: nil, taskID: taskID, settings: settings)
        s.onEvent = { events.add($0) }
        return (s, events, factory)
    }
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testTurningPeerToPeerOffSendsNothingMore() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        let (s, _, _) = try make(t, tracker: rec, trackers: [url("http://a.example.com/announce")])
        s.start()
        let heard = await until { rec.calls(for: "a.example.com") >= 1 }
        XCTAssertTrue(heard)
        s.stop(sendStoppedAnnounce: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(rec.announces.contains { $0.event == "stopped" || $0.event == "completed" })
    }

    func testCompletedIsSentBeforeStopped() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker(); rec.peers = [addr(1)]
        let (s, events, _) = try make(t, tracker: rec, trackers: [url("http://a.example.com/announce")])
        s.start()
        let done = await until { events.finished }
        XCTAssertTrue(done)
        s.stop()
        let both = await until { rec.events(for: "a.example.com").contains { $0 == "stopped" } }
        XCTAssertTrue(both)
        let order = rec.events(for: "a.example.com").compactMap { $0 }
        XCTAssertEqual(order.filter { $0 != "started" }, ["completed", "stopped"], "\(order)")
    }

    func testLocalPeersComeOnlyFromTheApprovedTracker() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        var settings = TorrentSession.Settings.testing; settings.allowLocalPeers = false
        let (s, _, factory) = try make(t, tracker: rec, trackers: [url("http://a.example.com/announce")], settings: settings)
        s.localPeerSources = [LocalTrackerPermission.key(url("http://192.168.1.25:6969/announce"))]
        s.start()
        s.addCandidates([addr(7)])                                   // from some other tracker: a local peer is not taken
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(factory.all.isEmpty)
        let key = LocalTrackerPermission.key(url("http://192.168.1.25:6969/announce"))
        s.localPeerStillAllowed = { $0 == key }
        s.addCandidates([addr(8)], fromLocalTracker: true, source: key)           // from the approved tracker
        let connected = await until { !factory.all.isEmpty }
        XCTAssertTrue(connected)
        s.stop(sendStoppedAnnounce: false)
    }

    func testAStandaloneAnnounceIsIgnoredWhenThereIsAnAnnounceList() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 10)], announce: ["http://x.example.com/announce"],
                                         extra: ["announce-list": .list([.list([TorrentFixture.b("http://y.example.com/announce")])])])
        XCTAssertEqual(t.meta.trackerTiers.map { $0.map { $0.host ?? "" } }, [["y.example.com"]])
        let only = try TorrentFixture.build(files: [(["a.bin"], 10)], announce: [], extra: ["announce": TorrentFixture.b("http://z.example.com/announce")])
        XCTAssertEqual(only.meta.trackerTiers.map { $0.map { $0.host ?? "" } }, [["z.example.com"]], "alone it is still used")
    }

    func testBusyIsNotCountedAgainstTheTracker() {
        var book = TrackerBook(tiers: [[url("udp://a.example.com:1")]])
        let a = book.urls[0]
        book.began(tier: 0, url: a); book.postponed(tier: 0, url: a, delay: 15, at: 100)
        XCTAssertTrue(book.due(at: 100).isEmpty); XCTAssertEqual(book.due(at: 116).count, 1)
        XCTAssertNotEqual(book.statuses(at: 116)[0].state, .error)
    }

    func testABlockedOrProxyFailureIsRetriedNotPermanent() {
        XCTAssertFalse(TorrentSession.isUnsupported(UDPTrackerClient.Failure.blocked("x")))
        XCTAssertFalse(TorrentSession.isUnsupported(UDPTrackerClient.Failure.proxy("x")))
        XCTAssertTrue(TorrentSession.isUnsupported(UDPTrackerClient.Failure.unsupported("x")))
    }
}

final class UDPSendBoundTests: XCTestCase {
    func testAMacProxyStopsUDPTrackersWithAnExplanationNotASilentDirectConnection() async {
        let t = ScriptedUDP()
        let c = UDPTrackerClient(factory: ScriptedFactory(t), resolver: FixedResolver(table: [:]), systemProxyActive: { true })
        do { _ = try await c.announce(URL(string: "udp://203.0.113.9:6969")!, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil); XCTFail() }
        catch { guard case UDPTrackerClient.Failure.proxy(let why) = error else { return XCTFail("\(error)") }; XCTAssertTrue(why.contains("Settings → Downloads")) ; XCTAssertTrue(TorrentSession.isProxyProblem(error)) }
        XCTAssertTrue(t.packets.isEmpty)
        var direct = DownloadNetworkSetup(); direct.proxy.mode = .direct
        let ok = UDPTrackerClient(network: { direct }, factory: ScriptedFactory(t), resolver: FixedResolver(table: [:]), timing: UDPTrackerClient.Timing(base: 0.05, attempts: 1), systemProxyActive: { true })
        do { _ = try await ok.announce(URL(string: "udp://203.0.113.9:6969")!, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil) }
        catch { if case UDPTrackerClient.Failure.proxy = error { XCTFail("an explicit No proxy is the person's choice") } }
        XCTAssertFalse(t.packets.isEmpty)
    }

    func testExpensiveAndConstrainedChoicesReachTheUDPSocket() async {
        final class Capture: UDPTransportFactory, @unchecked Sendable {
            var flags: (Bool, Bool)?
            let t: ScriptedUDP
            init(_ t: ScriptedUDP) { self.t = t }
            func open(ipv4: String, port: UInt16) throws -> UDPDatagramTransport { t }
            func open(ipv4: String, port: UInt16, refuseExpensive: Bool, refuseConstrained: Bool) throws -> UDPDatagramTransport { flags = (refuseExpensive, refuseConstrained); return t }
        }
        let f = Capture(ScriptedUDP())
        var setup = DownloadNetworkSetup(); setup.refuseExpensive = true; setup.refuseConstrained = true; setup.proxy.mode = .direct
        let c = UDPTrackerClient(network: { setup }, factory: f, resolver: FixedResolver(table: [:]), timing: UDPTrackerClient.Timing(base: 0.05, attempts: 1))
        _ = try? await c.announce(URL(string: "udp://203.0.113.9:6969")!, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil)
        XCTAssertEqual(f.flags?.0, true); XCTAssertEqual(f.flags?.1, true)
    }

    func testASendThatNeverCompletesIsGivenUpOn() async {
        final class Hang: UDPDatagramTransport, @unchecked Sendable {
            private(set) var closed = false
            func send(_ datagram: Data) async throws { try await Task.sleep(nanoseconds: 30_000_000_000) }
            func receive(timeout: TimeInterval) async throws -> Data? { nil }
            func close() { closed = true }
        }
        struct Factory: UDPTransportFactory { let t: Hang; func open(ipv4: String, port: UInt16) throws -> UDPDatagramTransport { t } }
        let t = Hang()
        let c = UDPTrackerClient(factory: Factory(t: t), resolver: FixedResolver(table: [:]), timing: UDPTrackerClient.Timing(base: 1, attempts: 1, sendLimit: 0.1))
        let started = Date()
        do { _ = try await c.announce(URL(string: "udp://203.0.113.9:6969")!, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil); XCTFail() }
        catch { XCTAssertTrue(error is UDPTrackerClient.Failure) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(t.closed); XCTAssertEqual(c.openSockets, 0)
    }

    func testAnApprovedNameThatResolvesLocallyIsUsedByUDPAndAnUnapprovedOneIsNot() async {
        let t = ScriptedUDP()
        let url = URL(string: "udp://t.example.com:6969")!
        let denied = UDPTrackerClient(factory: ScriptedFactory(t), resolver: FixedResolver(table: ["t.example.com": ["192.168.1.7"]]))
        do { _ = try await denied.announce(url, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil); XCTFail() }
        catch { if case UDPTrackerClient.Failure.blocked = error {} else { XCTFail("\(error)") } }
        let allowed = UDPTrackerClient(factory: ScriptedFactory(t), resolver: FixedResolver(table: ["t.example.com": ["192.168.1.7"]]), authorized: { _ in true })
        do { _ = try await allowed.announce(url, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil) }
        catch { if case UDPTrackerClient.Failure.blocked = error { XCTFail("approved") } }
    }
}
