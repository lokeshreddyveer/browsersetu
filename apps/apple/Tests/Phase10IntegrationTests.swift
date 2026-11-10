import Darwin
import XCTest
@testable import Browser_Setu

/// The session over real TCP sockets, against scripts/ed2k_fixture.py (started by the test scheme on 127.0.0.1:18801-18803).
/// What this shows: the client and the fixture agree over real sockets. The fixture implements the same reading of the protocol as the client, so it does NOT show interoperability with real eD2k software.
final class ED2KSocketTests: ED2KSessionTestCase {
    private func reachable() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(18801).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    private func stats() -> [String: Int] {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(18811).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }) else { return [:] }
        _ = "STATS\n".withCString { write(fd, $0, 6) }
        var buf = [UInt8](repeating: 0, count: 512); let n = read(fd, &buf, 511)
        return n > 0 ? ((try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Int]) ?? [:] : [:]
    }

    private func runReal(_ b: Built, down: BandwidthController? = nil) throws -> (ED2KSession, ED2KStorage, Events) {
        let storage = ED2KStorage(size: b.link.size, partFile: ED2KStorage.partFile(for: taskID, in: root)); try storage.prepare()
        var s = ED2KSession.Settings(); s.allowLocalPeers = true; s.requestTimeout = 20
        let events = Events()
        let session = ED2KSession(file: b.link, servers: [PeerAddress(host: "127.0.0.1", port: 18801)], extraSources: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(),
                                  download: down, taskID: taskID, settings: s)
        session.onEvent = { events.add($0) }
        return (session, storage, events)
    }

    func testASmallFileThroughARealServerAndRealPeers() async throws {
        guard reachable() else { throw XCTSkip("the eD2k fixture is not running (run through the BrowserSetuMac scheme)") }
        let before = stats()
        let b = built(size: 600_000)
        let (s, storage, ev) = try runReal(b)
        s.start()
        let ok = await until(60) { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")  servers: \(s.snapshot.servers)")
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream, "the bytes that crossed the sockets are the file")
        let after = stats()
        XCTAssertGreaterThan(after["logins", default: 0], before["logins", default: 0], "the server saw the login")
        XCTAssertGreaterThan(after["getsources", default: 0], before["getsources", default: 0])
        XCTAssertGreaterThan(after["good_blocks", default: 0], before["good_blocks", default: 0])
        print("SOCKET ed2k small: logins \(after["logins"] ?? -1), blocks good \(after["good_blocks"] ?? -1) bad \(after["bad_blocks"] ?? -1)")
        s.stop()
    }

    func testAFileOfTwoPartsWithTheHashListFetchedOverTheSocket() async throws {
        guard reachable() else { throw XCTSkip("the eD2k fixture is not running") }
        let b = built(size: 10_500_000)
        let (s, storage, ev) = try runReal(b)
        s.start()
        let ok = await until(120) { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")  servers: \(s.snapshot.servers)")
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream)
        XCTAssertEqual(Set(ev.verified), [0, 1])
        s.stop()
    }

    func testTheDamagingPeerIsNeverBelievedOverRealSockets() async throws {
        guard reachable() else { throw XCTSkip("the eD2k fixture is not running") }
        let before = stats()
        let b = built(size: 600_000)
        let (s, storage, ev) = try runReal(b)
        s.start()
        _ = await until(60) { ev.finished }
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream, "whatever the damaging peer sent, the file is exact")
        XCTAssertGreaterThanOrEqual(stats()["bad_blocks", default: 0], before["bad_blocks", default: 0])
        s.stop()
    }

    func testTheSpeedLimitPacesRealSockets() async throws {
        guard reachable() else { throw XCTSkip("the eD2k fixture is not running") }
        let b = built(size: 600_000)
        let down = BandwidthController(); down.setOverallLimit(256 << 10)
        let (s, _, ev) = try runReal(b, down: down)
        let t0 = Date(); s.start()
        let ok = await until(60) { ev.finished }
        let took = Date().timeIntervalSince(t0)
        print("SOCKET MEASURED ed2k limit 256 KiB/s: 600 KB in \(took)s = \(600.0 / took) KB/s")
        XCTAssertTrue(ok); XCTAssertGreaterThan(took, 1.2, "unlimited this takes a fraction of a second on loopback")
        s.stop()
    }

    func testAPortNobodyListensOnFailsCleanly() async throws {
        let b = built(size: 100_000)
        let storage = ED2KStorage(size: b.link.size, partFile: ED2KStorage.partFile(for: taskID, in: root)); try storage.prepare()
        var st = ED2KSession.Settings(); st.allowLocalPeers = true
        let s = ED2KSession(file: b.link, servers: [PeerAddress(host: "127.0.0.1", port: 9)], extraSources: [PeerAddress(host: "127.0.0.1", port: 9)], storage: { storage }, alreadyHave: [],
                            transports: NWPeerTransportFactory(), download: nil, taskID: taskID, settings: st)
        s.start()
        try? await Task.sleep(for: .seconds(3))
        XCTAssertEqual(ED2KBudget.peers.holding(task: taskID) <= 2, true)
        s.stop()
        let released = await until(3) { ED2KBudget.peers.holding(task: self.taskID) == 0 && ED2KBudget.servers.holding(task: self.taskID) == 0 }
        XCTAssertTrue(released, "connections that failed give their slots back")
    }
}

/// The runner through the coordinator, ledger and scheduler (in-memory servers and peers).
@MainActor
final class ED2KIntegrationTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var made: [DownloadCoordinator] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p10i-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
    }

    override func tearDown() async throws {
        for c in made { for (id, r) in c.ledger.records where !r.state.isFinal && r.state != .failed { c.cancel(id) } }
        try? await Task.sleep(for: .milliseconds(250))
        let reset = DownloadCoordinator(); reset.ed2kSettings = ED2KSettings()
        ED2KBandwidth.download.setOverallLimit(nil)
        for c in made { if let s = c.store { DownloadTaskStore.close(folder: s) } }
        try? FileManager.default.removeItem(at: root)
        DownloadCoordinator.directoryOverride = savedOverride
        try await super.tearDown()
    }

    private let server = PeerAddress(host: "9.9.9.9", port: 4661)
    private func stream(_ n: Int) -> (data: Data, link: ED2KLink.File, parts: [Data], hash: Data) {
        let data = TorrentFixture.content(n)
        let (parts, whole) = ED2KHash.hashes(of: data)
        return (data, ED2KLink.File(name: "movie.bin", size: Int64(n), hash: whole, partHashes: nil, aichRoot: nil, sources: []), parts, whole)
    }

    private func coordinator(enabled: Bool = true, content: (data: Data, link: ED2KLink.File, parts: [Data], hash: Data)? = nil, servers: [String] = ["9.9.9.9:4661"], settings: ED2KSettings? = nil) -> (DownloadCoordinator, FakeED2KNet?) {
        let c = DownloadCoordinator()
        c.profileName = "default"; c.store = root.appendingPathComponent("store-\(made.count)"); c.hasHost = { false }; c.duplicatePolicy = .keepBoth
        var s = settings ?? ED2KSettings(); s.enabled = enabled; s.servers = servers
        c.ed2kSettings = s
        var net: FakeED2KNet?
        if let content {
            let source = ED2KWire.SourceEntry(id: 0x0808_0808, port: 4662)
            net = FakeED2KNet { a, q in
                if a == self.server { return FakeED2K(queue: q, role: .server(sources: [source]), stream: content.data, fileHash: content.hash, partHashes: content.parts) }
                return FakeED2K(queue: q, role: .peer(.init()), stream: content.data, fileHash: content.hash, partHashes: content.parts)
            }
            c.ed2k.transports = net!
            c.ed2k.sessionSettings.allowLocalPeers = true
        }
        made.append(c)
        return (c, net)
    }

    private func wait(_ c: DownloadCoordinator, _ id: UUID, for states: Set<DownloadState>, seconds: Double = 30) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let r = c.ledger.record(id), states.contains(r.state) { return r }; try? await Task.sleep(for: .milliseconds(25)) }
        return c.ledger.record(id)
    }

    func testADownloadFlowsThroughTheLedgerAndEndsChecked() async throws {
        let f = stream(900_000)
        let (c, _) = coordinator(content: f)
        let id = try await c.ed2k.add(f.link)
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        XCTAssertEqual(done?.protocolID, .ed2k); XCTAssertEqual(done?.file.integrity, .verified)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("movie.bin")), f.data)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: downloads.path)).filter { $0.hasPrefix(".") }, [], "no part file or hash list is left behind")
        XCTAssertEqual(ED2KBudget.peers.open, 0); XCTAssertEqual(ED2KBudget.servers.open, 0); XCTAssertEqual(ED2KSlots.shared.open, 0)
        XCTAssertTrue(DownloadRowProjector.integrityText(done!).contains("MD4"))
        XCTAssertTrue(DownloadRowProjector.integrityText(done!).contains("not prove"), "the result is not presented as proof of authenticity")
    }

    func testNothingIsContactedUntilTheyTurnItOn() async throws {
        let f = stream(100_000)
        let (c, net) = coordinator(enabled: false, content: f)
        do { _ = try await c.ed2k.add(f.link); XCTFail() } catch { XCTAssertEqual(error as? ED2KError, .disabled) }
        XCTAssertTrue(c.ledger.records.isEmpty); XCTAssertEqual(net?.all.count, 0)
        let (c2, net2) = coordinator(content: f)
        _ = try c2.ed2k.inspect(link: "ed2k://|file|x.bin|100000|\(f.hash.hexString)|/")
        XCTAssertEqual(net2?.all.count, 0, "looking at a link opens no connection")
        XCTAssertTrue(c2.ed2k.inspection(of: f.link).privacyNotice.contains("network address"))
        XCTAssertThrowsError(try c2.ed2k.inspect(link: "ed2k://|server|8.8.8.8|4661|/"), "only file links can be downloaded")
    }

    func testWithNoServerAndNoSourcesThereIsNothingToDo() async throws {
        let f = stream(100_000)
        let (c, net) = coordinator(content: f, servers: [])
        do { _ = try await c.ed2k.add(f.link); XCTFail() } catch { if case ED2KError.noSources = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(net?.all.count, 0); XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testAnUnreachableOrWrongFileNeverCountsAsComplete() async throws {
        let f = stream(500_000)
        var wrong = f.link; wrong.hash = Data(repeating: 7, count: 16)        // a link for a file the peers do not have
        let (c, _) = coordinator(content: f)
        let id = try await c.ed2k.add(wrong)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertNotEqual(c.ledger.record(id)?.state, .completed)
        c.cancel(id)
    }

    func testATrustedSHA256IsCheckedAndAMismatchDeletesTheFile() async throws {
        let f = stream(300_000)
        let (c, _) = coordinator(content: f)
        let good = try DownloadIntegrityCheck.verify(file: { let u = root.appendingPathComponent("ref.bin"); try? f.data.write(to: u); return u }(), expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false).sha256 ?? ""
        let id1 = try await c.ed2k.add(f.link, expectedSHA256: good)
        let ok = await wait(c, id1, for: [.completed, .failed])
        XCTAssertEqual(ok?.state, .completed, "failure: \(ok?.failure?.reason ?? "-")")
        XCTAssertEqual(ok?.engineMetadata["sha256"], good)

        var other = f.link; other.name = "second.bin"
        let id2 = try await c.ed2k.add(other, expectedSHA256: String(repeating: "ab", count: 32))
        let bad = await wait(c, id2, for: [.completed, .failed])
        XCTAssertEqual(bad?.state, .failed); XCTAssertTrue(bad?.failure?.reason.contains("SHA-256") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("second.bin").path), "a file that is not the one promised is not kept")
    }

    func testPauseKeepsCheckedPartsAndResumeFinishesWithTheSameTaskID() async throws {
        let f = stream(10_500_000)
        var s = ED2KSettings(); s.downloadLimit = 3 << 20
        let (c, _) = coordinator(content: f, settings: s)
        let id = try await c.ed2k.add(f.link)
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(1500))
        c.pause(id)
        let paused = await wait(c, id, for: [.paused, .failed, .completed], seconds: 15)
        XCTAssertEqual(paused?.state, .paused, "failure: \(paused?.failure?.reason ?? "-")")
        XCTAssertEqual(ED2KBudget.peers.holding(task: id), 0, "a paused download holds no connection")
        ED2KBandwidth.download.setOverallLimit(nil)
        c.resume(id)
        let done = await wait(c, id, for: [.completed, .failed], seconds: 90)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        XCTAssertEqual(done?.id, id, "the task keeps its identity")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("movie.bin")), f.data)
    }

    func testCancelRemovesOnlyThisTasksFilesAndGivesEverythingBack() async throws {
        let f = stream(10_500_000)
        try Data("mine".utf8).write(to: downloads.appendingPathComponent("keep.txt"))
        var s = ED2KSettings(); s.downloadLimit = BandwidthController.minimumRate
        let (c, _) = coordinator(content: f, settings: s)
        let id = try await c.ed2k.add(f.link)
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(800))
        c.cancel(id)
        _ = await wait(c, id, for: [.cancelled], seconds: 10)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["keep.txt"], "the person's own file is untouched and nothing of the task is left")
        XCTAssertEqual(ED2KBudget.peers.holding(task: id), 0); XCTAssertEqual(ED2KSlots.shared.open, 0)
    }

    func testTheSchedulerLimitsHowManyRunAtOnce() async throws {
        let f = stream(10_500_000)
        var s = ED2KSettings(); s.maxActiveDownloads = 1; s.downloadLimit = BandwidthController.minimumRate
        let (c, _) = coordinator(content: f, settings: s)
        let first = try await c.ed2k.add(f.link)
        XCTAssertEqual(ED2KSlots.shared.open, 1)
        var second = f.link; second.name = "two.bin"
        let waiting = Task { try await c.ed2k.add(second) }
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(ED2KSlots.shared.open, 1, "the second waits for the first's place")
        c.cancel(first); _ = await wait(c, first, for: [.cancelled])
        let id2 = try await waiting.value
        c.cancel(id2)
    }

    func testTurningItOffStopsRunningDownloads() async throws {
        let f = stream(10_500_000)
        var s = ED2KSettings(); s.downloadLimit = BandwidthController.minimumRate
        let (c, _) = coordinator(content: f, settings: s)
        let id = try await c.ed2k.add(f.link)
        _ = await wait(c, id, for: [.running]); try? await Task.sleep(for: .milliseconds(600))
        var off = c.ed2kSettings; off.enabled = false; c.ed2kSettings = off
        let r = await wait(c, id, for: [.paused, .failed], seconds: 10)
        XCTAssertTrue([.paused, .failed].contains(r?.state)); XCTAssertEqual(ED2KBudget.peers.holding(task: id), 0)
    }

    func testSettingsAreCheckedAndPerProfile() {
        var s = ED2KSettings(); s.servers = ["8.8.8.8:4661", "127.0.0.1:4661", "example.com:4661", "10.0.0.1:4661", "1.2.3.4:0", "garbage", "9.9.9.9:4661"]
        s.maxActiveDownloads = 99; s.maxSourcesPerDownload = 0; s.downloadLimit = 5
        let n = s.normalized()
        XCTAssertEqual(n.servers, ["8.8.8.8:4661", "9.9.9.9:4661"], "only public IPv4 servers with a port are kept")
        XCTAssertEqual(n.maxActiveDownloads, 10); XCTAssertEqual(n.maxSourcesPerDownload, 1); XCTAssertEqual(n.downloadLimit, BandwidthController.minimumRate)
        XCTAssertFalse(ED2KSettings().enabled); XCTAssertEqual(ED2KSettings.decode(n.encoded()), n); XCTAssertEqual(ED2KSettings.decode("junk"), ED2KSettings())
        let (a, _) = coordinator(enabled: true), (b, _) = coordinator(enabled: false)
        XCTAssertTrue(a.ed2k.settings.enabled); XCTAssertFalse(b.ed2k.settings.enabled); XCTAssertFalse(a.ed2k === b.ed2k)
    }

    func testTheEngineReportsOnlyWhatItDoes() {
        let caps = DownloadEngineRegistry().capabilities(of: .ed2k)
        for c: DownloadEngineCapabilities in [.pause, .resume, .pieces, .enforcesSpeedLimit] { XCTAssertTrue(caps.contains(c)) }
        XCTAssertFalse(caps.contains(.upload), "this client only downloads"); XCTAssertFalse(caps.contains(.multiFile)); XCTAssertFalse(caps.contains(.resolveMetadata))
    }

    func testPartFileNamesAreTheOnlyNamesUsedAsPaths() {
        XCTAssertTrue(ED2KRunner.isPartFileName(".ABCD1234.bsetu-ed2k"))
        for bad in ["..", "../x", ".abcd1234.bsetu-ed2k/..", "x", "/etc", "", ".ABCD123.bsetu-ed2k"] { XCTAssertFalse(ED2KRunner.isPartFileName(bad), bad) }
    }

    func testTheNetworkCodeOpensNoListener() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/ED2K")
        for name in ["ED2KSession.swift", "ED2KRunner.swift", "ED2KWire.swift"] {
            let text = (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.isEmpty); XCTAssertFalse(text.contains("NWListener") || text.contains("UPnP") || text.contains("bind("), "\(name) must not listen or map ports")
        }
    }
}
