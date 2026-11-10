import XCTest
@testable import Browser_Setu

// MARK: The book: tiers, backoff, events, status (no network, no session)

final class TrackerBookTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testEquivalentAddressesAreKeptOnceAndOtherSchemesAreMarkedUnsupported() {
        let book = TrackerBook(tiers: [[u("http://T.example.com:80/announce"), u("http://t.example.com/announce"), u("udp://t.example.com:6969")], [u("udp://t.example.com:6969"), u("ftp://t.example.com/a")]])
        XCTAssertEqual(book.endpointCount, 3, "the repeats are gone, ftp is kept to be reported")
        let rows = book.statuses(at: 0)
        XCTAssertEqual(rows.map(\.scheme), ["HTTP", "UDP", "FTP"])
        XCTAssertEqual(rows.last?.state, .unsupported); XCTAssertEqual(rows.last?.tier, 2)
        XCTAssertEqual(TrackerBook.key(u("https://x.example.com/announce/")), TrackerBook.key(u("https://x.example.com:443/announce")))
        XCTAssertNotEqual(TrackerBook.key(u("udp://x.example.com:1")), TrackerBook.key(u("udp://x.example.com:2")))
    }

    func testEachTierAnnouncesToItsFirstUsableEndpointAndAnEndpointWaitingOutAFailureIsSkipped() {
        var book = TrackerBook(tiers: [[u("http://a.example.com/announce"), u("http://b.example.com/announce")], [u("udp://c.example.com:80")]])
        var due = book.due(at: 0)
        XCTAssertEqual(due.map(\.url.host), ["a.example.com", "c.example.com"], "one for each tier, the first of the tier")
        XCTAssertEqual(due.map(\.event), ["started", "started"])
        for d in due { book.began(tier: d.tier, url: d.url) }
        XCTAssertTrue(book.due(at: 1).isEmpty, "nothing more while those are in flight")
        book.failed(tier: 0, url: due[0].url, reason: "refused", at: 1)
        due = book.due(at: 1)
        XCTAssertEqual(due.map(\.url.host), ["b.example.com"], "the next endpoint of the tier takes over at once")
        book.began(tier: 0, url: due[0].url)
        book.failed(tier: 0, url: due[0].url, reason: "refused", at: 2)
        XCTAssertTrue(book.due(at: 3).filter { $0.tier == 0 }.isEmpty, "both are waiting out a failure")
        XCTAssertEqual(book.due(at: 62).filter { $0.tier == 0 }.first?.url.host, "a.example.com", "never dropped for good: the first is asked again when its wait is over")
    }

    func testTheWaitAfterFailuresDoublesAndStopsGrowing() {
        var book = TrackerBook(tiers: [[u("http://a.example.com/announce")]])
        var waits: [TimeInterval] = []
        var t: TimeInterval = 0
        for _ in 0..<12 {
            let d = book.due(at: t); XCTAssertEqual(d.count, 1)
            book.began(tier: 0, url: d[0].url); book.failed(tier: 0, url: d[0].url, reason: "x", at: t)
            let next = (0..<100_000).first { book.due(at: t + TimeInterval($0)).count == 1 } ?? -1
            waits.append(TimeInterval(next)); t += TimeInterval(next)
        }
        XCTAssertEqual(Array(waits.prefix(4)), [60, 120, 240, 480])
        XCTAssertEqual(waits.last, TrackerBook.maxBackoff, "bounded: an hour at most")
    }

    func testAnEndpointThatAnsweredMovesToTheFrontAndTheIntervalIsRespected() {
        var book = TrackerBook(tiers: [[u("http://a.example.com/announce"), u("http://b.example.com/announce")]])
        let a = u("http://a.example.com/announce"), b = u("http://b.example.com/announce")
        book.began(tier: 0, url: a); book.failed(tier: 0, url: a, reason: "no", at: 0)
        book.began(tier: 0, url: b); book.answered(tier: 0, url: b, interval: 1800, seeders: 4, leechers: nil, event: "started", at: 1)
        XCTAssertEqual(book.urls.first, b, "the one that answered is asked first next time")
        XCTAssertTrue(book.due(at: 1000).isEmpty, "not before the interval is over")
        let again = book.due(at: 1802)
        XCTAssertEqual(again.first?.url, b); XCTAssertNil(again.first?.event, "started is sent once")
        let row = book.statuses(at: 10).first { $0.name == "b.example.com" }
        XCTAssertEqual(row?.state, .working); XCTAssertEqual(row?.seeders, 4); XCTAssertNil(row?.leechers, "a count nobody gave is unknown, not zero")
        XCTAssertEqual(row?.secondsUntilAnnounce ?? 0, 1791, accuracy: 1)
    }

    func testCompletedAndStoppedAreOwedOnceToWhoeverHeardStarted() {
        var book = TrackerBook(tiers: [[u("http://a.example.com/announce")], [u("http://b.example.com/announce")]])
        let a = u("http://a.example.com/announce"), b = u("http://b.example.com/announce")
        book.began(tier: 0, url: a); book.answered(tier: 0, url: a, interval: 100, seeders: nil, leechers: nil, event: "started", at: 0)
        book.began(tier: 1, url: b); book.failed(tier: 1, url: b, reason: "down", at: 0)
        XCTAssertEqual(book.completionTargets(), [a], "only a tracker that heard started is told it completed")
        book.markCompletedSent(a)
        XCTAssertTrue(book.completionTargets().isEmpty, "once")
        XCTAssertEqual(book.stopTargets(), [a]); XCTAssertTrue(book.stopTargets().isEmpty, "once")
        XCTAssertTrue(book.completionTargets().isEmpty, "nothing is completed after stopping")
    }

    func testUnsupportedStaysUnsupportedAndTheDisplayNameKeepsNoSecrets() {
        var book = TrackerBook(tiers: [[u("http://a.example.com:8080/KEYSECRET123/announce?passkey=ABCDEF")]])
        let a = book.urls[0]
        book.began(tier: 0, url: a); book.failed(tier: 0, url: a, reason: "UDP trackers cannot be reached through a proxy", unsupported: true, at: 0)
        XCTAssertTrue(book.due(at: 100_000).isEmpty, "not retried: nothing about it will change")
        let row = book.statuses(at: 0)[0]
        XCTAssertEqual(row.state, .unsupported); XCTAssertEqual(row.name, "a.example.com:8080")
        XCTAssertFalse(row.name.contains("KEYSECRET") || row.name.contains("passkey") || row.id == row.name && false)
    }

    func testScrapeTargetsAreOnePerTierAndBoundedInFrequency() {
        var book = TrackerBook(tiers: [[u("http://a.example.com/announce"), u("http://b.example.com/announce")], [u("udp://c.example.com:80")]])
        let a = u("http://a.example.com/announce"), b = u("http://b.example.com/announce")
        book.began(tier: 0, url: b); book.answered(tier: 0, url: b, interval: 100, seeders: nil, leechers: nil, event: nil, at: 0)
        XCTAssertEqual(book.scrapeTargets(at: 10).map(\.host), ["b.example.com", "c.example.com"], "the endpoint that answered, and the only one of the other tier")
        book.scraped(b, TrackerScrape(seeders: 0, completed: nil, leechers: 5), at: 10)
        XCTAssertEqual(book.scrapeTargets(at: 20).map(\.host), ["c.example.com"], "not again within a minute")
        XCTAssertEqual(book.scrapeTargets(at: 71).count, 2)
        let row = book.statuses(at: 20).first { $0.name == "b.example.com" }
        XCTAssertEqual(row?.seeders, 0, "a known zero is shown as zero"); XCTAssertNil(row?.completed); XCTAssertEqual(row?.leechers, 5)
        book.scrapeFailed(a, note: "This tracker does not offer counts", at: 30)
        XCTAssertEqual(book.statuses(at: 30).first { $0.name == "a.example.com" }?.scrapeNote, "This tracker does not offer counts")
        XCTAssertNil(book.statuses(at: 30).first { $0.name == "a.example.com" }?.lastError, "a tracker that will not scrape is not a tracker in error")
    }
}

// MARK: Scrape on the wire, and tiers in torrent files

final class TrackerScrapeTests: XCTestCase {
    private let infoHash = Data((0..<20).map { UInt8($0) })

    func testTheHTTPScrapeAddressFollowsTheConvention() {
        func scrape(_ s: String) -> String? { HTTPTrackerClient.scrapeURL(for: URL(string: s)!, infoHash: infoHash)?.absoluteString }
        let id = infoHash.map { String(format: "%%%02X", $0) }.joined()
        XCTAssertEqual(scrape("http://t.example.com/announce"), "http://t.example.com/scrape?info_hash=\(id)")
        XCTAssertEqual(scrape("http://t.example.com/x/announce.php?passkey=k"), "http://t.example.com/x/scrape.php?passkey=k&info_hash=\(id)")
        XCTAssertNil(scrape("http://t.example.com/tracker"), "no \"announce\", no scrape address that can be known")
        XCTAssertNil(scrape("http://t.example.com/"))
    }

    func testAnHTTPScrapeReplyGivesOnlyWhatItSays() throws {
        func reply(_ files: String) -> Data { Data("d5:filesd20:\(String(repeating: "x", count: 20))\(files)ee".utf8) }
        let full = try HTTPTrackerClient.parseScrape(reply("d8:completei7e10:downloadedi30e10:incompletei2ee"))
        XCTAssertEqual(full, TrackerScrape(seeders: 7, completed: 30, leechers: 2))
        let partial = try HTTPTrackerClient.parseScrape(reply("d8:completei0ee"))
        XCTAssertEqual(partial, TrackerScrape(seeders: 0, completed: nil, leechers: nil), "zero is zero; absent is unknown")
        XCTAssertThrowsError(try HTTPTrackerClient.parseScrape(Data("d14:failure reason9:not founde".utf8))) { XCTAssertEqual($0 as? HTTPTrackerClient.Failure, .refused("not found")) }
        XCTAssertThrowsError(try HTTPTrackerClient.parseScrape(Data("d5:filesdee".utf8)))
        XCTAssertThrowsError(try HTTPTrackerClient.parseScrape(Data("garbage".utf8)))
        XCTAssertThrowsError(try HTTPTrackerClient.parseScrape(Data("d5:filesd20:\(String(repeating: "x", count: 20))d8:completei-4eee e".utf8)))
    }

    func testAnHTTPAnnounceReplyCarriesItsCountsWhenItHasThem() throws {
        let r = try HTTPTrackerClient.parse(Data("d8:completei3e10:incompletei9e8:intervali900e5:peers0:e".utf8))
        XCTAssertEqual(r.seeders, 3); XCTAssertEqual(r.leechers, 9)
        let none = try HTTPTrackerClient.parse(Data("d8:intervali900e5:peers0:e".utf8))
        XCTAssertNil(none.seeders); XCTAssertNil(none.leechers)
    }

    private func be32(_ v: UInt32) -> Data { var d = Data(); d.appendBE(v); return d }

    func testTheUDPScrapePacketAndAnswerFollowBEP15() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in
            let tid = packet.beUInt32(at: 12)
            if packet.count == 16 { return [self.be32(0) + self.be32(tid) + (Data() + { var d = Data(); d.appendBE(UInt64(77)); return d }())] }
            XCTAssertEqual(packet.count, 36, "connection id, action, transaction id, one info-hash")
            XCTAssertEqual(packet.beUInt32(at: 8), 2, "action: scrape"); XCTAssertEqual(packet.beUInt64(at: 0), 77)
            return [self.be32(2) + self.be32(tid) + self.be32(12) + self.be32(40) + self.be32(3)]       // seeders, completed, leechers
        }
        let factory = ScriptedFactory(t)
        let client = UDPTrackerClient(network: { DownloadNetworkSetup() }, factory: factory, resolver: FixedResolver(table: [:]), timing: .init(base: 0.01, attempts: 3))
        let r = try await client.scrape(URL(string: "udp://203.0.113.9:6969")!, infoHash: infoHash)
        XCTAssertEqual(r, TrackerScrape(seeders: 12, completed: 40, leechers: 3))
        XCTAssertTrue(t.closed); XCTAssertEqual(client.openSockets, 0)
    }

    func testAShortUDPScrapeAnswerAndAProxyAreRefused() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in
            let tid = packet.beUInt32(at: 12)
            if packet.count == 16 { return [self.be32(0) + self.be32(tid) + Data(count: 8)] }
            return [self.be32(2) + self.be32(tid) + Data(count: 4)]
        }
        let client = UDPTrackerClient(network: { DownloadNetworkSetup() }, factory: ScriptedFactory(t), resolver: FixedResolver(table: [:]), timing: .init(base: 0.01, attempts: 2))
        do { _ = try await client.scrape(URL(string: "udp://203.0.113.9:6969")!, infoHash: infoHash); XCTFail() } catch UDPTrackerClient.Failure.badReply {}
        var setup = DownloadNetworkSetup(); setup.proxy = .init(mode: .socks5, host: "p.example.com", port: 1080, username: "")
        let proxied = UDPTrackerClient(network: { setup }, factory: ScriptedFactory(ScriptedUDP()), resolver: FixedResolver(table: [:]))
        do { _ = try await proxied.scrape(URL(string: "udp://203.0.113.9:6969")!, infoHash: infoHash); XCTFail() } catch UDPTrackerClient.Failure.proxy {}
    }

    private func torrentWith(announce: String?, list: String?) throws -> TorrentMetainfo {
        func s(_ t: String) -> String { "\(t.utf8.count):\(t)" }
        let info = "d6:lengthi10e4:name1:a12:piece lengthi16384e6:pieces20:" + String(repeating: "x", count: 20) + "e"
        let torrent = "d" + (announce.map { "8:announce\(s($0))" } ?? "") + (list.map { "13:announce-list\($0)" } ?? "") + "4:info\(info)e"
        return try TorrentMetainfo.parse(Data(torrent.utf8))
    }
    private func s(_ t: String) -> String { "\(t.utf8.count):\(t)" }

    /// BEP 12: "If the announce-list key is present, the client will ignore the announce key and only use the URLs in announce-list."
    func testTheTorrentKeepsItsTiersInOrderWithoutRepeats() throws {
        let list = "ll\(s("udp://a.example.com:1"))\(s("http://b.example.com/announce"))el\(s("udp://c.example.com:2"))\(s("udp://a.example.com:1"))el\(s("ftp://x.example.com/"))ee"
        let meta = try torrentWith(announce: "http://z.example.com/announce", list: list)
        XCTAssertEqual(meta.trackerTiers.map { $0.map(\.absoluteString) }, [["udp://a.example.com:1", "http://b.example.com/announce"], ["udp://c.example.com:2"]],
                       "the tiers of announce-list, in order; the repeat and the unsupported ftp address dropped; the standalone announce ignored because announce-list is present")
        XCTAssertFalse(meta.trackerTiers.flatMap { $0 }.contains { $0.host == "z.example.com" })
        XCTAssertEqual(meta.trackers.map(\.absoluteString), meta.trackerTiers.flatMap { $0 }.map(\.absoluteString), "the flat list the session and seeding use must not bring the ignored announce back")
    }

    func testWithoutAnAnnounceListTheStandaloneAnnounceIsTheOnlyTier() throws {
        let meta = try torrentWith(announce: "http://z.example.com/announce", list: nil)
        XCTAssertEqual(meta.trackerTiers.map { $0.map(\.absoluteString) }, [["http://z.example.com/announce"]])
    }

    func testAnAnnounceListWithNoUsableAddressFallsBackToTheStandaloneAnnounce() throws {
        let meta = try torrentWith(announce: "http://z.example.com/announce", list: "ll\(s("ftp://x.example.com/"))ee")
        XCTAssertEqual(meta.trackerTiers.map { $0.map(\.absoluteString) }, [["http://z.example.com/announce"]], "a list with nothing usable in it leaves announce as the only way")
    }

    func testRepeatsAreDroppedAcrossTiersButEachTierKeepsItsOrder() throws {
        let list = "ll\(s("http://a.example.com/announce"))\(s("http://b.example.com/announce"))el\(s("http://b.example.com/announce"))\(s("http://c.example.com/announce"))ee"
        let meta = try torrentWith(announce: nil, list: list)
        XCTAssertEqual(meta.trackerTiers.map { $0.map(\.host!) }, [["a.example.com", "b.example.com"], ["c.example.com"]])
        XCTAssertEqual(meta.trackers.map(\.host!), ["a.example.com", "b.example.com", "c.example.com"], "the flat list holds the same addresses")
    }
}

// MARK: The session: announces, events, tiers, failure isolation, scrape

final class RecordingTracker: TrackerAnnouncing, TrackerScraping, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var announces: [(url: URL, event: String?)] = []
    private(set) var scrapes: [URL] = []
    var failing: Set<String> = []                        // hosts that fail
    var peers: [PeerAddress] = []
    var scrapeResult: TrackerScrape? = TrackerScrape(seeders: 5, completed: 20, leechers: 1)

    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        lock.lock(); announces.append((tracker, event)); let fail = failing.contains(tracker.host ?? ""); let list = peers; lock.unlock()
        if fail { throw UDPTrackerClient.Failure.refused("down") }
        return TrackerReply(peers: list, interval: 1800, warning: nil, seeders: 5, leechers: 1)
    }
    func scrape(_ tracker: URL, infoHash: Data) async throws -> TrackerScrape {
        lock.lock(); scrapes.append(tracker); let r = scrapeResult; lock.unlock()
        guard let r else { throw HTTPTrackerClient.Failure.noScrape }
        return r
    }
    func events(for host: String) -> [String?] { lock.lock(); defer { lock.unlock() }; return announces.filter { $0.url.host == host }.map(\.event) }
    func calls(for host: String) -> Int { events(for: host).count }
}

final class TrackerLifecycleTests: TorrentSessionTestCase {
    private func session(_ t: TorrentFixture.Built, tracker: RecordingTracker, trackers: [URL], tiers: [[URL]]? = nil, have: Set<Int> = [], peers: [Int]) throws -> (TorrentSession, TorrentSessionTestCase.Events) {
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        for p in have { try storage.write(piece: p, data: t.stream.subdata(in: (p * Int(t.meta.pieceLength))..<(p * Int(t.meta.pieceLength) + Int(t.meta.length(ofPiece: p))))) }
        tracker.peers = peers.map(addr)
        let factory = FakePeers { a, q in FakePeer(queue: q, stream: t.stream, meta: t.meta, infoHash: t.meta.infoHash) }
        let events = Events()
        let s = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: trackers, trackerTiers: tiers, storage: { storage }, alreadyHave: have, transports: factory, tracker: tracker,
                               download: nil, upload: nil, taskID: taskID, settings: .testing)
        s.onEvent = { events.add($0) }
        return (s, events)
    }
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testEveryTrackerOfAFlatListHearsStartedOnceAndTheDownloadFinishesAndCompletedIsSentOnce() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        let (s, events) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce"), url("udp://b.example.com:6969")], peers: [1])
        s.start()
        let done = await until { events.finished }
        XCTAssertTrue(done, events.failure ?? "")
        XCTAssertEqual(rec.events(for: "a.example.com").first, "started"); XCTAssertEqual(rec.events(for: "b.example.com").first, "started")
        let completed = await until { rec.events(for: "a.example.com").contains { $0 == "completed" } && rec.events(for: "b.example.com").contains { $0 == "completed" } }
        XCTAssertTrue(completed, "\(rec.announces.map { "\($0.url.host ?? ""):\($0.event ?? "-")" })")
        XCTAssertEqual(rec.announces.filter { $0.event == "started" }.count, 2, "no duplicate started")
        XCTAssertEqual(rec.announces.filter { $0.event == "completed" }.count, 2, "completed once for each")
        s.stop()
    }

    func testATorrentThatWasAlreadyCompleteDoesNotSendCompleted() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        let (s, events) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce")], have: Set(0..<t.meta.pieceCount), peers: [])
        s.start()
        _ = await until { events.finished }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rec.announces.contains { $0.event == "completed" })
        s.stop()
    }

    func testStoppingSendsStoppedOnceToWhoHeardStartedAndNothingAfter() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker(); rec.failing = ["bad.example.com"]
        let (s, _) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce"), url("http://bad.example.com/announce")], peers: [])
        s.start()
        let heard = await until { rec.calls(for: "a.example.com") >= 1 && rec.calls(for: "bad.example.com") >= 1 }
        XCTAssertTrue(heard)
        try await Task.sleep(nanoseconds: 200_000_000)
        s.stop(); s.stop()
        let stopped = await until { rec.events(for: "a.example.com").contains { $0 == "stopped" } }
        XCTAssertTrue(stopped)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rec.announces.filter { $0.event == "stopped" }.count, 1, "once, and not to a tracker that never answered")
        XCTAssertFalse(rec.events(for: "bad.example.com").contains { $0 == "stopped" })
    }

    func testAFailingTrackerFallsBackWithinItsTierWithoutHammering() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker(); rec.failing = ["a.example.com"]
        let (s, events) = try session(t, tracker: rec, trackers: [], tiers: [[url("http://a.example.com/announce"), url("udp://b.example.com:6969")], [url("http://c.example.com/announce")]], peers: [])
        s.start()
        let moved = await until(8) { rec.calls(for: "b.example.com") >= 1 && rec.calls(for: "c.example.com") >= 1 }
        XCTAssertTrue(moved, "the next of the tier took over, and the other tier is independent: \(rec.announces.map { $0.url.host ?? "" })")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(rec.calls(for: "a.example.com"), 1, "the failing one is left alone during its wait, not asked again and again")
        XCTAssertNil(events.failure, "a failing tracker is not a failing torrent")
        let rows = s.snapshot.trackerRows
        XCTAssertEqual(rows.first { $0.name == "a.example.com" }?.state, .error)
        XCTAssertEqual(rows.first { $0.name == "b.example.com:6969" }?.state, .working)
        XCTAssertEqual(rows.map(\.tier), [1, 1, 2])
        s.stop()
    }

    func testTheDownloadFinishesFromWhatTheWorkingTrackerGaveEvenIfAnotherTrackerFails() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker(); rec.failing = ["a.example.com"]
        let (s, events) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce"), url("http://c.example.com/announce")], peers: [1])
        s.start()
        let done = await until(15) { events.finished }
        XCTAssertTrue(done, events.failure ?? "-")
        s.stop()
    }

    func testNothingIsAnnouncedAgainBeforeTheIntervalAndAfterStoppingNothingMoreIsStarted() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        let (s, _) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce")], peers: [])
        s.start()
        _ = await until { rec.calls(for: "a.example.com") >= 1 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(rec.calls(for: "a.example.com"), 1, "the interval (30 minutes) is respected, not the one-second timer")
        s.stop()
        let before = rec.announces.count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertLessThanOrEqual(rec.announces.count - before, 1, "only the stopped notice, nothing else")
    }

    func testANewSessionAfterARelaunchStartsAgainAndOnlyOnce() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        for _ in 0..<2 {
            let (s, _) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce")], peers: [])
            s.start()
            _ = await until { rec.announces.filter { $0.event == "started" }.count >= 1 }
            try await Task.sleep(nanoseconds: 1_300_000_000)
            s.stop()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(rec.announces.filter { $0.event == "started" }.count, 2, "once for each session, never twice within one")
    }

    func testScrapeIsOnRequestBoundedAndShownAsKnownOrUnknown() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker()
        let (s, _) = try session(t, tracker: rec, trackers: [], tiers: [[url("http://a.example.com/announce")], [url("udp://b.example.com:6969")]], peers: [])
        s.start()
        _ = await until { rec.calls(for: "a.example.com") >= 1 && rec.calls(for: "b.example.com") >= 1 }
        XCTAssertTrue(rec.scrapes.isEmpty, "nothing is scraped on its own")
        s.scrapeNow(); s.scrapeNow()
        _ = await until { rec.scrapes.count >= 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.scrapes.count, 2, "one for each tier, and the second request within the minute did nothing")
        let rows = s.snapshot.trackerRows
        XCTAssertEqual(rows.map(\.seeders), [5, 5]); XCTAssertEqual(rows.map(\.completed), [20, 20])
        s.stop()
    }

    func testAFailedScrapeLeavesTheCountsUnknownAndTheTrackerWorking() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let rec = RecordingTracker(); rec.scrapeResult = nil
        let (s, _) = try session(t, tracker: rec, trackers: [url("http://a.example.com/announce")], peers: [])
        s.start()
        _ = await until { rec.calls(for: "a.example.com") >= 1 }
        s.scrapeNow()
        _ = await until { rec.scrapes.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        let row = s.snapshot.trackerRows[0]
        XCTAssertEqual(row.scrapeNote, "This tracker does not offer counts"); XCTAssertEqual(row.state, .working)
        s.stop()
    }
}

// MARK: Offline until authorised

@MainActor
final class TrackerAuthorizationTests: XCTestCase {
    func testWithPeerToPeerOffNoTrackerIsContacted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx01u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = folder
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: folder) }
        let c = DownloadCoordinator()
        let rec = RecordingTracker()
        c.torrents.tracker = rec
        XCTAssertFalse(c.torrentSettings.enabled)
        let magnet = try MagnetLink.parse("magnet:?xt=urn:btih:\(String(repeating: "ab", count: 20))&tr=udp%3A%2F%2F203.0.113.9%3A6969&tr=http%3A%2F%2Ft.example.com%2Fannounce")
        do { _ = try await c.torrents.fetchDetails(of: magnet, timeout: 1); XCTFail("went ahead with peer-to-peer off") } catch TorrentError.disabled {}
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(rec.announces.isEmpty && rec.scrapes.isEmpty, "no tracker was contacted")
    }
}
