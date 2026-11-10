import XCTest
import Network
@testable import Browser_Setu

// MARK: Settings

final class NetworkSettingsTests: XCTestCase {
    func testDefaultsKeepTodaysBehaviour() {
        let s = DownloadNetworkSettings()
        XCTAssertNil(s.overallLimit)
        XCTAssertEqual(s.perHostConnections, ConnectionBudget.perHostLimit)
        XCTAssertEqual(s.workersPerDownload, 4)
        XCTAssertEqual(s.requestTimeout, 30)
        XCTAssertEqual(s.maxAutomaticRetries, 3)
        XCTAssertFalse(s.pauseOnExpensive); XCTAssertFalse(s.respectLowDataMode); XCTAssertFalse(s.waitForConnectivity)
        XCTAssertEqual(s.proxy.mode, .system)
        XCTAssertEqual(s.preset, .unlimited)
    }

    func testValuesAreBroughtIntoRange() {
        var s = DownloadNetworkSettings()
        s.overallLimit = 5; s.perHostConnections = 99; s.workersPerDownload = 0; s.requestTimeout = 1; s.maxAutomaticRetries = -4
        let n = s.normalized()
        XCTAssertEqual(n.overallLimit, BandwidthController.minimumRate)
        XCTAssertEqual(n.perHostConnections, 8); XCTAssertEqual(n.workersPerDownload, 1)
        XCTAssertEqual(n.requestTimeout, 10); XCTAssertEqual(n.maxAutomaticRetries, 0)
        s.overallLimit = 0; XCTAssertNil(s.normalized().overallLimit)
        s.overallLimit = Int64.max; XCTAssertEqual(s.normalized().overallLimit, DownloadNetworkSettings.maximumLimit)
    }

    func testSavingAndRestoringKeepsEverythingButNoPassword() throws {
        var s = DownloadNetworkSettings()
        s.overallLimit = 2_000_000; s.pauseOnExpensive = true; s.waitForConnectivity = true
        s.proxy = .init(mode: .socks5, host: "proxy.example", port: 1080, username: "alice")
        let text = try XCTUnwrap(s.encoded())
        XCTAssertFalse(text.lowercased().contains("password"), "a password is never part of the saved settings")
        XCTAssertEqual(DownloadNetworkSettings.decode(text), s)
    }

    func testUnreadableOrOldSettingsGiveDefaults() {
        XCTAssertEqual(DownloadNetworkSettings.decode(nil), DownloadNetworkSettings())
        XCTAssertEqual(DownloadNetworkSettings.decode("not json"), DownloadNetworkSettings())
        XCTAssertEqual(DownloadNetworkSettings.decode(String(repeating: "x", count: 20_000)), DownloadNetworkSettings())
        XCTAssertEqual(DownloadNetworkSettings.decode("{\"overallLimit\":4096}").overallLimit, 4096)       // missing fields keep their defaults
        XCTAssertEqual(DownloadNetworkSettings.decode("{\"overallLimit\":4096}").workersPerDownload, 4)
    }

    func testPresetsChangeOnlyTheirDocumentedNumbers() {
        var s = DownloadNetworkSettings()
        s.proxy = .init(mode: .http, host: "p", port: 8080, username: "u")
        s.pauseOnExpensive = true; s.respectLowDataMode = true; s.waitForConnectivity = true; s.requestTimeout = 60; s.maxAutomaticRetries = 1
        for preset in [DownloadNetworkSettings.Preset.unlimited, .balanced, .limited, .custom] {
            let r = s.applying(preset)
            XCTAssertEqual(r.proxy, s.proxy, "\(preset) must not touch the proxy")
            XCTAssertEqual(r.pauseOnExpensive, true); XCTAssertEqual(r.respectLowDataMode, true); XCTAssertEqual(r.waitForConnectivity, true)
            XCTAssertEqual(r.requestTimeout, 60); XCTAssertEqual(r.maxAutomaticRetries, 1)
        }
        XCTAssertEqual(s.applying(.limited).overallLimit, 1024 * 1024)
        XCTAssertEqual(s.applying(.limited).preset, .limited)
        XCTAssertEqual(s.applying(.balanced).preset, .balanced)
        var odd = s; odd.overallLimit = 123_456
        XCTAssertEqual(odd.preset, .custom)
    }
}

// MARK: Proxy

final class ProxyConfigurationTests: XCTestCase {
    private func proxy(_ mode: DownloadNetworkSettings.Proxy.Mode, host: String = "proxy.example", port: Int = 3128, user: String = "") -> DownloadNetworkSettings.Proxy {
        .init(mode: mode, host: host, port: port, username: user)
    }

    func testSystemLeavesTheSessionOnTheMacsSettings() throws {
        let config = URLSessionConfiguration.ephemeral
        try DownloadProxy.apply(proxy(.system), password: nil, origin: .user, to: config)
        XCTAssertTrue(config.proxyConfigurations.isEmpty)
        XCTAssertNil(config.connectionProxyDictionary)
    }

    func testDirectTurnsEveryProxyOff() throws {
        let config = URLSessionConfiguration.ephemeral
        try DownloadProxy.apply(proxy(.direct), password: nil, origin: .user, to: config)
        let d = try XCTUnwrap(config.connectionProxyDictionary)
        XCTAssertEqual(d[kCFNetworkProxiesHTTPEnable as String] as? Int, 0)
        XCTAssertEqual(d[kCFNetworkProxiesHTTPSEnable as String] as? Int, 0)
        XCTAssertEqual(d[kCFNetworkProxiesSOCKSEnable as String] as? Int, 0)
        XCTAssertEqual(d[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int, 0)
    }

    func testEachExplicitKindProducesOneConfigurationWithoutFailover() throws {
        for mode in [DownloadNetworkSettings.Proxy.Mode.http, .https, .socks5] {
            let config = URLSessionConfiguration.ephemeral
            try DownloadProxy.apply(proxy(mode, user: "u"), password: "p", origin: .user, to: config)
            XCTAssertEqual(config.proxyConfigurations.count, 1, "\(mode)")
            XCTAssertFalse(config.proxyConfigurations[0].allowFailover, "a failing proxy must never fall back to a direct connection (\(mode))")
        }
    }

    func testAddressesAndPortsAreChecked() {
        XCTAssertEqual(DownloadProxy.problem(proxy(.http, host: "")), .missingHost)
        for bad in ["http://p", "p/x", "a b", "p@h", "p?x", "p#x", "p\\x", "prøxy"] { XCTAssertEqual(DownloadProxy.problem(proxy(.http, host: bad)), .badHost, bad) }
        XCTAssertEqual(DownloadProxy.problem(proxy(.socks5, port: 0)), .badPort)
        XCTAssertEqual(DownloadProxy.problem(proxy(.socks5, port: 70000)), .badPort)
        XCTAssertNil(DownloadProxy.problem(proxy(.http, host: "10.0.0.5", port: 8080)))
        XCTAssertNil(DownloadProxy.problem(proxy(.http, host: "[::1]", port: 8080)))
        XCTAssertNil(DownloadProxy.problem(proxy(.socks5, host: "::1", port: 1080)))
        XCTAssertNil(DownloadProxy.problem(proxy(.system, host: "", port: 0)))
    }

    func testAnUnusableProxyThrowsAndLeavesTheConfigurationAlone() {
        let config = URLSessionConfiguration.ephemeral
        XCTAssertThrowsError(try DownloadProxy.apply(proxy(.http, port: 0), password: nil, origin: .user, to: config))
        XCTAssertTrue(config.proxyConfigurations.isEmpty)
        let failure = DownloadNetworkSetup.failure(for: DownloadProxy.Problem.badPort)
        XCTAssertFalse(failure.info.retryable, "retrying cannot fix a setting")
        XCTAssertTrue(failure.info.reason.contains("port"))
    }

    func testRequestsThatAreNotThePersonsOwnNeverUseAProxy() {
        let config = URLSessionConfiguration.ephemeral
        for origin in [DownloadRequestOrigin.automation] {
            XCTAssertThrowsError(try DownloadProxy.apply(proxy(.http), password: nil, origin: origin, to: config)) { XCTAssertEqual($0 as? DownloadProxy.Problem, .notForUntrustedRequests) }
        }
        // and the connection check refuses what it cannot see through a proxy, so the Phase 4 gate is not weakened by a proxy setting
        let untrusted = HTTPRequestPolicy(origin: .automation)
        XCTAssertEqual(untrusted.verifyConnection(host: "example.com", remote: nil, viaProxy: true, fromPublic: true), .refuse(.unverifiable("example.com")))
        XCTAssertFalse(HTTPRequestPolicy.untrustedRequestsEnabled, "automation and extension downloads stay disabled")
    }

    func testCapabilitiesAreStatedHonestly() {
        XCTAssertTrue(DownloadProxy.capabilities(.https).encryptedToProxy)
        XCTAssertFalse(DownloadProxy.capabilities(.http).encryptedToProxy)
        XCTAssertFalse(DownloadProxy.capabilities(.system).authentication)
        XCTAssertTrue(DownloadProxy.capabilities(.socks5).authentication)
    }

    func testPasswordsLiveOnlyInTheCredentialStore() {
        let store = MemoryProxyCredentialStore()
        store.setPassword("s3cret", profile: "a")
        XCTAssertEqual(store.password(profile: "a"), "s3cret")
        XCTAssertNil(store.password(profile: "b"), "another profile does not see it")
        var s = DownloadNetworkSettings(); s.proxy = proxy(.http, user: "alice")
        XCTAssertFalse(s.encoded()!.contains("s3cret"))
        XCTAssertFalse(DownloadProxy.summary(s.proxy).contains("s3cret"))
        store.setPassword(nil, profile: "a")
        XCTAssertNil(store.password(profile: "a"))
    }

    func testTheSetupDoesNotPrintItsPassword() {
        var s = DownloadNetworkSettings(); s.proxy = proxy(.http, user: "alice")
        let setup = DownloadNetworkSetup(s, password: "s3cret-pw")
        XCTAssertFalse(String(describing: DownloadNetworkSetup.failure(for: DownloadProxy.Problem.badHost)).contains("s3cret-pw"))
        XCTAssertEqual(setup.proxyPassword, "s3cret-pw")      // held for the engines, nowhere else
    }
}

// MARK: Network conditions

final class ReviewFixTests: XCTestCase {
    func testARequestThatIsNotThePersonsOwnIsRefusedNotSentAroundAProxy() {
        let engine = HTTPTransferEngine()
        var s = DownloadNetworkSettings(); s.proxy = .init(mode: .socks5, host: "127.0.0.1", port: 1080, username: "")
        engine.applyNetwork(DownloadNetworkSetup(s, password: nil))
        XCTAssertThrowsError(try engine.session(for: .automation)) { XCTAssertFalse(($0 as? HTTPDownloadError)?.info.retryable ?? true) }
        XCTAssertNoThrow(try engine.session(for: .user))
        engine.applyNetwork(DownloadNetworkSetup())
        XCTAssertNoThrow(try engine.session(for: .automation), "without a proxy chosen nothing changes")
    }

    func testAnUnchangedSetupKeepsTheOpenSession() throws {
        let engine = HTTPTransferEngine()
        let a = try engine.session(for: .user)
        engine.applyNetwork(DownloadNetworkSetup())
        XCTAssertTrue(a === (try engine.session(for: .user)), "applying the same settings again must not throw away the connections")
        var s = DownloadNetworkSettings(); s.requestTimeout = 60
        engine.applyNetwork(DownloadNetworkSetup(s, password: nil))
        XCTAssertFalse(a === (try engine.session(for: .user)))
    }

    func testTheHostLimitCanBeChangedFromAnyThread() {
        let budget = ConnectionBudget()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            budget.hostLimitOverride = i % 2 == 0 ? 2 : nil
            _ = budget.canGrant(1, scope: "h")
        }
        budget.hostLimitOverride = 1
        XCTAssertTrue(budget.grant(1, scope: "h", task: UUID()))
        XCTAssertFalse(budget.grant(1, scope: "h", task: UUID()))
    }
}

final class NetworkPolicyTests: XCTestCase {
    private func path(online: Bool = true, expensive: Bool = false, constrained: Bool = false) -> PathInfo { PathInfo(online: online, expensive: expensive, constrained: constrained) }

    func testDefaultsNeverHold() {
        let s = DownloadNetworkSettings()
        for p in [path(), path(online: false), path(expensive: true), path(constrained: true), path(expensive: true, constrained: true)] { XCTAssertNil(NetworkPolicy.hold(for: p, settings: s)) }
    }

    func testEachSettingHoldsOnlyItsOwnCondition() {
        var s = DownloadNetworkSettings(); s.pauseOnExpensive = true
        XCTAssertEqual(NetworkPolicy.hold(for: path(expensive: true), settings: s), .expensive)
        XCTAssertNil(NetworkPolicy.hold(for: path(constrained: true), settings: s))
        s = DownloadNetworkSettings(); s.respectLowDataMode = true
        XCTAssertEqual(NetworkPolicy.hold(for: path(constrained: true), settings: s), .constrained)
        XCTAssertNil(NetworkPolicy.hold(for: path(expensive: true), settings: s))
        s = DownloadNetworkSettings(); s.waitForConnectivity = true
        XCTAssertEqual(NetworkPolicy.hold(for: path(online: false), settings: s), .offline)
        XCTAssertNil(NetworkPolicy.hold(for: path(), settings: s))
    }

    func testOfflineWinsOverTheOthersAndLowDataOverMetered() {
        var s = DownloadNetworkSettings(); s.pauseOnExpensive = true; s.respectLowDataMode = true; s.waitForConnectivity = true
        XCTAssertEqual(NetworkPolicy.hold(for: path(online: false, expensive: true, constrained: true), settings: s), .offline)
        XCTAssertEqual(NetworkPolicy.hold(for: path(expensive: true, constrained: true), settings: s), .constrained)
    }
}

// MARK: Real transfers (fixture server on port 18766)

@MainActor
class NetworkFixtureTestCase: XCTestCase {
    static let port = 18766
    var root: URL!
    var downloads: URL!
    var savedOverride: URL?
    var made: [DownloadCoordinator] = []

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "run through the BrowserSetuMac scheme, which starts the fixture server")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p8-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        HTTPRetrySchedule.delayScale = 0.01
        _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/_reset")!)
    }

    override func tearDown() async throws {
        for c in made { for (id, r) in c.ledger.records where !r.state.isFinal && r.state != .failed { c.cancel(id) } }
        // Everything this test started must have given its connections back, and the check waits for that (cancelled transfers finish stopping on their own queues) rather than for a fixed time.
        var leftover = ConnectionBudget.shared.holders()
        let deadline = Date().addingTimeInterval(5)
        while !leftover.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)); leftover = ConnectionBudget.shared.holders() }
        XCTAssertTrue(leftover.isEmpty, "\(name) left \(leftover.count) connection lease(s) behind: \(leftover.map { "\($0.connections)" })")
        // Put the shared, process-wide settings back so no test leaks into the next.
        let defaults = DownloadCoordinator()
        defaults.networkSettings = DownloadNetworkSettings()
        BandwidthController.shared.setOverallLimit(nil)
        HTTPRetrySchedule.delayScale = 1.0
        for c in made { if let s = c.store { DownloadTaskStore.close(folder: s) } }
        try? FileManager.default.removeItem(at: root)
        DownloadCoordinator.directoryOverride = savedOverride
        try await super.tearDown()
    }

    func coordinator(profile: String = "default", settings: DownloadNetworkSettings = DownloadNetworkSettings()) -> DownloadCoordinator {
        let c = DownloadCoordinator()
        c.profileName = profile
        c.store = root.appendingPathComponent("store-\(profile)-\(made.count)")
        c.hasHost = { false }
        c.proxyCredentials = MemoryProxyCredentialStore()
        c.networkPath = { PathInfo() }
        c.networkSettings = settings
        made.append(c)
        return c
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }

    func wait(_ c: DownloadCoordinator, _ id: UUID, for states: Set<DownloadState>, seconds: Double = 40) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let r = c.ledger.record(id), states.contains(r.state) { return r }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return c.ledger.record(id)
    }

    func serverLog() async -> String {
        let data = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/_log")!).0
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func checkContent(_ record: DownloadTaskRecord?, size: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(record?.file.destinationPath, file: file, line: line)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(data.count, size, file: file, line: line)
        // byte i of a fixture file is (i * 31 + 7) % 251: a sample across the file is enough to show the pieces landed in place
        for i in stride(from: 0, to: size, by: max(1, size / 997)) { if data[i] != UInt8((i * 31 + 7) % 251) { XCTFail("wrong byte at \(i)", file: file, line: line); break } }
    }

    func elapsed(_ since: Date) -> Double { Date().timeIntervalSince(since) }
}

final class BandwidthTransportTests: NetworkFixtureTestCase {
    func testUnlimitedControlIsFast() async throws {
        let c = coordinator()
        let t0 = Date()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(3 << 20)"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed)
        XCTAssertLessThan(elapsed(t0), 3.0)
        try checkContent(done, size: 3 << 20)
    }

    func testOverallLimitIsKeptByARealTransfer() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 1 << 20
        let c = coordinator(settings: s)
        let t0 = Date()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(3 << 20)"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed])
        let took = elapsed(t0)
        XCTAssertEqual(done?.state, .completed)
        XCTAssertEqual(done?.engineMetadata["mode"], "multipart", "a limited download goes through the path that can be slowed")
        // 3 MiB at 1 MiB/s is 3 s less the quarter-second burst; a transfer that ignored the limit takes well under a second
        XCTAssertGreaterThan(took, 2.3, "measured \(3.0 / took) MiB/s")
        XCTAssertLessThan(took, 6.0)
        print("MEASURED overall limit 1 MiB/s: 3 MiB in \(took)s = \(3.0 / took) MiB/s")
        try checkContent(done, size: 3 << 20)
        XCTAssertEqual(c.http.bandwidthEnforcement(id), .enforced)
    }

    func testPerDownloadLimitHoldsOneDownloadWhileAnotherRunsFree() async throws {
        let c = coordinator()
        let t0 = Date()
        let slow = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(1_500_000)"), at: Date(), speedLimit: 512 << 10))
        let free = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(1_500_000)?x=1"), at: Date()))
        let freeDone = await wait(c, free, for: [.completed, .failed])
        let freeTook = elapsed(t0)
        XCTAssertEqual(freeDone?.state, .completed)
        XCTAssertLessThan(freeTook, 2.0, "the unlimited one is not held back by the other's limit")
        let slowDone = await wait(c, slow, for: [.completed, .failed])
        let slowTook = elapsed(t0)
        XCTAssertEqual(slowDone?.state, .completed)
        XCTAssertGreaterThan(slowTook, 2.0, "1.5 MB at 512 KiB/s")
        XCTAssertLessThan(slowTook, 6.0)
        print("MEASURED per-download 512 KiB/s: 1.5 MB in \(slowTook)s; unlimited neighbour \(freeTook)s")
        try checkContent(slowDone, size: 1_500_000)
    }

    func testTwoDownloadsShareTheOverallLimit() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 1 << 20
        let c = coordinator(settings: s)
        let t0 = Date()
        let a = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(2 << 20)"), at: Date()))
        let b = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(2 << 20)?y=1"), at: Date()))
        let da = await wait(c, a, for: [.completed, .failed]), db = await wait(c, b, for: [.completed, .failed])
        let took = elapsed(t0)
        XCTAssertEqual(da?.state, .completed); XCTAssertEqual(db?.state, .completed)
        // 4 MiB together at 1 MiB/s: about 3.75 s. Two limits of 1 MiB/s each would finish in about 2 s.
        XCTAssertGreaterThan(took, 3.0, "the limit is shared, not given to each: \(4.0 / took) MiB/s together")
        XCTAssertLessThan(took, 9.0)
        print("MEASURED two downloads sharing 1 MiB/s: 4 MiB in \(took)s = \(4.0 / took) MiB/s")
    }

    func testRaisingTheLimitWhileDownloadingTakesEffect() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 256 << 10
        let c = coordinator(settings: s)
        let t0 = Date()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(3 << 20)"), at: Date()))
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(c.ledger.record(id)?.state, .running, "still slow after 1.2 s")
        var faster = s; faster.overallLimit = nil
        c.networkSettings = faster
        let done = await wait(c, id, for: [.completed, .failed], seconds: 8)
        XCTAssertEqual(done?.state, .completed)
        XCTAssertLessThan(elapsed(t0), 5.0, "at the old limit it would take 12 s")
    }

    func testPauseKeepsTheDownloadsOwnLimitAndResumeCarriesOn() async throws {
        let c = coordinator()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(2 << 20)"), at: Date(), speedLimit: 512 << 10))
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(600))
        c.pause(id)
        let paused = await wait(c, id, for: [.paused, .failed, .completed], seconds: 10)
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.engineMetadata["speedLimit"], String(512 << 10), "the limit is saved with the task")
        let before = paused?.transfer.completedBytes ?? 0
        let t1 = Date()
        c.resume(id)
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed)
        XCTAssertGreaterThan(elapsed(t1), 1.0, "after resuming it is still limited (\(2 << 20) - \(before) bytes left at 512 KiB/s)")
        try checkContent(done, size: 2 << 20)
    }

    func testALimitSetOnAFinishedDownloadLeavesNothingBehind() async throws {
        let c = coordinator()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096?fin=1"), at: Date()))
        _ = await wait(c, id, for: [.completed, .failed])
        c.http.setSpeedLimit(id, bytesPerSecond: 5000)
        XCTAssertNil(BandwidthController.shared.taskLimit(id))
        XCTAssertNil(BandwidthController.shared.effectiveLimit(for: id), "no limit is left that applies to it")
    }

    func testCancelWhileWaitingForBandwidthLeavesNothingBehind() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 128 << 10
        let c = coordinator(settings: s)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(3 << 20)"), at: Date(), speedLimit: 64 << 10))
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(ConnectionBudget.shared.open, 0)
        c.cancel(id)
        _ = await wait(c, id, for: [.cancelled], seconds: 5)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(ConnectionBudget.shared.open, 0, "every connection lease is given back")
        XCTAssertNil(BandwidthController.shared.taskLimit(id))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasPrefix(".") || $0.hasSuffix(".bin") }.isEmpty, "no working file left: \(leftovers)")
    }

    func testAServerThatCannotDoRangesIsNotLimitedAndTheListSaysSo() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 64 << 10
        let c = coordinator(settings: s)
        let t0 = Date()
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/nores/\(1 << 20)"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 15)
        XCTAssertEqual(done?.state, .completed)
        XCTAssertLessThan(elapsed(t0), 5.0, "it arrived at full speed: the system fetched it, and that cannot be slowed")
        XCTAssertEqual(done?.engineMetadata["mode"], "single")
        guard case .notEnforced(let why) = c.http.bandwidthEnforcement(id) else { return XCTFail("must not claim a limit it did not keep") }
        XCTAssertFalse(why.isEmpty)
    }

    func testSettingsReachTheSchedulerAndEnginesAndComeBack() async throws {
        var s = DownloadNetworkSettings()
        s.perHostConnections = 2; s.workersPerDownload = 3; s.requestTimeout = 45; s.maxAutomaticRetries = 5; s.overallLimit = 3 << 20
        let c = coordinator(settings: s)
        // Phase 22: these belong to this coordinator (profile), not to the process.
        XCTAssertEqual(ConnectionBudget.shared.hostLimit(owner: c.ownerID), 2)
        XCTAssertEqual(c.http.multipartConnections, 3)
        XCTAssertEqual(c.http.engine.currentNetwork.maxAttempts, 6)
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: c.ownerID), 3 << 20)
        XCTAssertEqual(c.http.engine.currentNetwork.requestTimeout, 45)
        c.networkSettings = DownloadNetworkSettings()
        XCTAssertNil(ConnectionBudget.shared.hostLimitOverride, "the unclaimed-task ceiling is never set by a profile")
        XCTAssertEqual(c.http.engine.currentNetwork.maxAttempts, 4)
        XCTAssertNil(BandwidthController.shared.overallLimit(owner: c.ownerID))
        XCTAssertEqual(ConnectionBudget.shared.hostLimit(owner: c.ownerID), ConnectionBudget.perHostLimit)
    }

    func testStoppingReadsBacksUpTheSenderAndDoesNotJustDelayCallbacks() async throws {
        // 24 MiB from a server that sends as fast as it is allowed. If suspending only delayed our callbacks the server would have written all of it within moments;
        // if the connection really backs up, it can only have written what we read plus what the two socket buffers hold.
        var s = DownloadNetworkSettings(); s.overallLimit = 512 << 10
        let c = coordinator(settings: s)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/\(24 << 20)"), at: Date()))
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .seconds(4))
        let peak = try await URLSession(configuration: .ephemeral).data(from: url("/_peak")).0
        let sent = (try JSONSerialization.jsonObject(with: peak) as? [String: Any])?["bytes_sent"] as? Int ?? -1
        let received = c.http.multipartSnapshot(id)?.networkBytes ?? -1
        print("MEASURED backpressure: after 4 s the server had written \(sent) bytes, the app had read \(received) of 25165824 (limit 512 KiB/s)")
        XCTAssertGreaterThan(sent, 0)
        XCTAssertLessThan(sent, 12 << 20, "the sender was held back by the connection, not left to finish")
        XCTAssertLessThan(received, 5 << 20, "about limit x time plus the first burst")
        c.cancel(id)
    }

    func testThePerWebsiteLimitHoldsOnTheSchedulersOwnPool() async throws {
        var s = DownloadNetworkSettings(); s.perHostConnections = 2
        let c = coordinator(settings: s)
        c.maxConcurrent = 6
        var ids: [UUID] = []
        for i in 0..<4 { ids.append(try XCTUnwrap(c.scheduleDownload(url: url("/throttle/\(2 << 20)?bps=400000&i=\(i)"), at: Date()))) }
        var peak = 0
        let end = Date().addingTimeInterval(2.5)
        while Date() < end {
            let running = ids.filter { [.running, .starting, .resuming].contains(c.ledger.record($0)?.state) }.count
            peak = max(peak, running)
            XCTAssertLessThanOrEqual(ConnectionBudget.shared.open, 2, "never more connections to one website than the limit")
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(peak, 2, "two run, the others wait their turn")
    }
}

final class NetworkHoldTests: NetworkFixtureTestCase {
    func testAMeteredLinkStopsWhatItStartedAndOnlyThat() async throws {
        var s = DownloadNetworkSettings(); s.pauseOnExpensive = true
        let c = coordinator(settings: s)
        c.maxConcurrent = 4
        let a = try XCTUnwrap(c.scheduleDownload(url: url("/throttle/\(4 << 20)?bps=300000&a=1"), at: Date()))
        let b = try XCTUnwrap(c.scheduleDownload(url: url("/throttle/\(4 << 20)?bps=300000&b=1"), at: Date()))
        _ = await wait(c, a, for: [.running]); _ = await wait(c, b, for: [.running])
        try? await Task.sleep(for: .milliseconds(400))
        c.pause(b)                                                                  // the person's own pause
        let w1 = await wait(c, b, for: [.paused], seconds: 8); XCTAssertEqual(w1?.state, .paused)

        c.evaluateNetworkHold(PathInfo(expensive: true))
        XCTAssertEqual(c.networkHold, .expensive)
        let w2 = await wait(c, a, for: [.paused], seconds: 8); XCTAssertEqual(w2?.state, .paused)
        XCTAssertTrue(c.policyPaused.contains(a)); XCTAssertFalse(c.policyPaused.contains(b))

        let late = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096?late=1"), at: Date()))
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertNotEqual(c.ledger.record(late)?.state, .completed, "nothing new starts while the policy holds")
        XCTAssertNotEqual(c.ledger.record(late)?.state, .running)

        c.evaluateNetworkHold(PathInfo())
        XCTAssertNil(c.networkHold)
        let resumed = await wait(c, a, for: [.running, .completed], seconds: 8)
        XCTAssertTrue([.running, .completed].contains(resumed?.state), "the one the policy stopped carries on")
        let w3 = await wait(c, late, for: [.completed], seconds: 10); XCTAssertEqual(w3?.state, .completed, "what waited starts now")
        XCTAssertEqual(c.ledger.record(b)?.state, .paused, "the person's own pause is not undone by the network coming back")
    }

    func testOfflineWithWaitForConnectivityHoldsNewStartsUntilBack() async throws {
        var s = DownloadNetworkSettings(); s.waitForConnectivity = true
        let c = coordinator(settings: s)
        c.evaluateNetworkHold(PathInfo(online: false))
        XCTAssertEqual(c.networkHold, .offline)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/8192?off=1"), at: Date()))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse([.running, .completed].contains(c.ledger.record(id)?.state ?? .created))
        c.evaluateNetworkHold(PathInfo())
        let w4 = await wait(c, id, for: [.completed, .failed], seconds: 10); XCTAssertEqual(w4?.state, .completed)
    }

    func testWithTheSettingsOffNothingIsEverHeld() async throws {
        let c = coordinator()
        for p in [PathInfo(online: false), PathInfo(expensive: true), PathInfo(constrained: true)] { c.evaluateNetworkHold(p); XCTAssertNil(c.networkHold) }
        XCTAssertFalse(c.scheduler.policyHold)
    }

    func testTheNetworkPolicyAndThePersonsHoldAreSeparate() async throws {
        var s = DownloadNetworkSettings(); s.pauseOnExpensive = true
        let c = coordinator(settings: s)
        c.holdQueue(until: .distantFuture)
        c.evaluateNetworkHold(PathInfo(expensive: true))
        c.evaluateNetworkHold(PathInfo())
        XCTAssertTrue(c.scheduler.isHeld, "lifting the network hold does not lift the person's hold")
        c.holdQueue(until: nil)
        c.evaluateNetworkHold(PathInfo(expensive: true))
        c.holdQueue(until: nil)
        XCTAssertTrue(c.scheduler.policyHold, "and the person's release does not lift the network's")
    }

    func testSettingsAreRestoredFromTheirSavedFormAndApplied() async throws {
        var s = DownloadNetworkSettings(); s.overallLimit = 2 << 20; s.pauseOnExpensive = true; s.workersPerDownload = 2
        let saved = try XCTUnwrap(s.encoded())
        let relaunched = coordinator(settings: DownloadNetworkSettings.decode(saved))
        XCTAssertEqual(relaunched.networkSettings, s)
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: relaunched.ownerID), 2 << 20)
        XCTAssertEqual(relaunched.http.multipartConnections, 2)
    }
}

// MARK: Proxies
//
// Two local proxies are started by the test scheme (see project.yml): open on 18767 (HTTP), 18768 (SOCKS5), log on 18769; and one that wants alice:s3cret on 18770, 18771, 18772.
// The name originhost exists only inside them and leads to the local fixture server, so a download of http://originhost/... can only succeed by going THROUGH the proxy.
// (The system never sends loopback addresses through an explicit proxy; `testLoopbackAddressesAreNeverSentThroughAProxy` records that.)

final class ProxyTransportTests: NetworkFixtureTestCase {
    private let open = (http: 18767, socks: 18768, ctl: 18769)
    private let locked = (http: 18770, socks: 18771, ctl: 18772)

    override func setUp() async throws {
        try await super.setUp()
        for ctl in [open.ctl, locked.ctl] {
            let ok = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(ctl)/reset")!)) != nil
            if !ok { throw XCTSkip("proxy fixtures are not running (run through the BrowserSetuMac scheme)") }
        }
    }

    private func proxyLog(_ ctl: Int) async -> String {
        let data = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(ctl)/log")!).0
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func settings(_ mode: DownloadNetworkSettings.Proxy.Mode, port: Int, user: String = "") -> DownloadNetworkSettings {
        var s = DownloadNetworkSettings(); s.proxy = .init(mode: mode, host: "127.0.0.1", port: port, username: user); s.maxAutomaticRetries = 0
        return s
    }

    private func origin(_ path: String) -> URL { URL(string: "http://originhost\(path)")! }

    func testAnHTTPProxyCarriesTheDownload() async throws {
        let c = coordinator(settings: settings(.http, port: open.http))
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/70001"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        let log = await proxyLog(open.ctl)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")  proxy log: \(log)")
        XCTAssertTrue(log.contains("originhost"), "the proxy saw the request: \(log)")
        try checkContent(done, size: 70001)
    }

    func testALimitedDownloadAlsoGoesThroughTheProxy() async throws {
        var s = settings(.http, port: open.http); s.overallLimit = 1 << 20
        let c = coordinator(settings: s)
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/\(2 << 20)"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 30)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        XCTAssertEqual(done?.engineMetadata["mode"], "multipart", "the data-task path uses the proxy too")
        let log = await proxyLog(open.ctl)
        XCTAssertTrue(log.contains("originhost"))
        try checkContent(done, size: 2 << 20)
    }

    func testASocks5ProxyCarriesTheDownload() async throws {
        let c = coordinator(settings: settings(.socks5, port: open.socks))
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/70002"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        let log = await proxyLog(open.ctl)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")  proxy log: \(log)")
        XCTAssertTrue(log.contains("\"socks\""), log)
    }

    func testProxyLoginsAreUsedAndMissingOrWrongOnesFailClearly() async throws {
        // none supplied
        let none = coordinator(profile: "a", settings: settings(.http, port: locked.http, user: "alice"))
        let id1 = try XCTUnwrap(none.scheduleDownload(url: origin("/file/70003"), at: Date()))
        let failed = await wait(none, id1, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(failed?.state, .failed, "a proxy that wants a login and gets none is an error, not a direct connection")
        // wrong
        let wrong = coordinator(profile: "b")
        wrong.proxyCredentials.setPassword("nope", profile: "b")
        wrong.networkSettings = settings(.http, port: locked.http, user: "alice")
        let id2 = try XCTUnwrap(wrong.scheduleDownload(url: origin("/file/70004"), at: Date()))
        let w2 = await wait(wrong, id2, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(w2?.state, .failed)
        // right
        let right = coordinator(profile: "c")
        right.proxyCredentials.setPassword("s3cret", profile: "c")
        right.networkSettings = settings(.http, port: locked.http, user: "alice")
        let id3 = try XCTUnwrap(right.scheduleDownload(url: origin("/file/70005"), at: Date()))
        let ok = await wait(right, id3, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(ok?.state, .completed, "failure: \(ok?.failure?.reason ?? "-")")
        // SOCKS5 with a login
        let socks = coordinator(profile: "d")
        socks.proxyCredentials.setPassword("s3cret", profile: "d")
        socks.networkSettings = settings(.socks5, port: locked.socks, user: "alice")
        let id4 = try XCTUnwrap(socks.scheduleDownload(url: origin("/file/70010"), at: Date()))
        let s4 = await wait(socks, id4, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(s4?.state, .completed, "failure: \(s4?.failure?.reason ?? "-")")
        // the password is nowhere a person or a log could read it
        for c in [none, wrong, right, socks] {
            let text = (c.events + c.ledger.records.values.flatMap { [$0.failure?.reason ?? "", $0.failure?.code ?? "", $0.source.url ?? ""] + Array($0.engineMetadata.values) }).joined(separator: "\n")
            XCTAssertFalse(text.contains("s3cret") || text.contains("nope"))
        }
        let log = await proxyLog(locked.ctl)
        XCTAssertTrue(log.contains("\"auth_ok\": false"), "the refusals were real: \(log)")
    }

    func testAProxyThatIsDownFailsAndTheNameIsNotLookedUpAnotherWay() async throws {
        let c = coordinator(settings: settings(.http, port: 9))      // nothing listens there
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/70006"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 30)
        XCTAssertEqual(done?.state, .failed, "failure: \(done?.failure?.reason ?? "-")")
        let log = await serverLog()
        XCTAssertFalse(log.contains("70006"), "nothing reached the website: \(log)")
    }

    func testLoopbackAddressesAreNeverSentThroughAProxy() async throws {
        // Recorded system behaviour, not something the app does: with a proxy that cannot be reached, a loopback address still works, because the system connects to it directly.
        // So a proxy setting cannot be used to test, or to rely on, how local addresses are reached.
        let c = coordinator(settings: settings(.http, port: 9))
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/70011"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(done?.state, .completed)
    }

    func testAnUnusableProxyFailsAtOnceWithAReadableReason() async throws {
        var s = DownloadNetworkSettings(); s.proxy = .init(mode: .socks5, host: "127.0.0.1", port: 0, username: "")
        let c = coordinator(settings: s)
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/70007"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 15)
        XCTAssertEqual(done?.state, .failed)
        XCTAssertTrue(done?.failure?.reason.contains("port") == true, done?.failure?.reason ?? "-")
        let log = await serverLog()
        XCTAssertFalse(log.contains("70007"))
    }

    func testDirectNeverUsesAProxyAndSoAProxyOnlyNameFails() async throws {
        var s = DownloadNetworkSettings(); s.proxy.mode = .direct; s.maxAutomaticRetries = 0
        let c = coordinator(settings: s)
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/file/70008"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(done?.state, .failed)
        let log = await proxyLog(open.ctl)
        XCTAssertEqual(log, "[]", "the proxy was not asked")
    }

    func testProxyChoiceIsPerProfile() async throws {
        let a = coordinator(profile: "work", settings: settings(.http, port: open.http))
        let b = coordinator(profile: "home")
        XCTAssertEqual(a.http.engine.currentNetwork.proxy.mode, .http)
        XCTAssertEqual(b.http.engine.currentNetwork.proxy.mode, .system, "another profile's coordinator has its own engine and setup")
    }

    func testRedirectsAreFollowedThroughTheSameProxy() async throws {
        let c = coordinator(settings: settings(.http, port: open.http))
        let id = try XCTUnwrap(c.scheduleDownload(url: origin("/redirect/2/70009"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        let log = await proxyLog(open.ctl)
        // Tunnels are reused, so the proxy logs connections rather than requests; that every hop worked at all proves it: the name exists nowhere but inside the proxy.
        XCTAssertTrue(log.contains("originhost"), log)
    }
}
