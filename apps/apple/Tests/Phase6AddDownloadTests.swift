import XCTest
@testable import Browser_Setu

/// Add Download, Try Again and Resume for the app's own downloads, with no web page open at all (fixture server on port 18766).
@MainActor
final class AddDownloadWithoutAPageTests: XCTestCase {
    private static let port = 18766
    private var root: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var made: [DownloadCoordinator] = []

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "run through the BrowserSetuMac scheme, which starts the fixture server")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("add6-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
    }

    override func tearDown() async throws {
        for c in made { for (id, r) in c.ledger.records where !r.state.isFinal && r.state != .failed { c.cancel(id) } }
        try? await Task.sleep(for: .milliseconds(150))
        for c in made { if let s = c.store { DownloadTaskStore.close(folder: s) } }
        try? FileManager.default.removeItem(at: root)
        DownloadCoordinator.directoryOverride = savedOverride
        try await super.tearDown()
    }

    /// A coordinator with its own database folder and, deliberately, a host that says no page is open.
    private func coordinator(profile: String = "default") -> DownloadCoordinator {
        let c = DownloadCoordinator()
        c.profileName = profile
        c.store = root.appendingPathComponent("store-\(profile)")
        c.hasHost = { false }
        made.append(c)
        return c
    }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }

    private func wait(_ c: DownloadCoordinator, _ id: UUID, for states: Set<DownloadState>, seconds: Double = 30) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let r = c.ledger.record(id), states.contains(r.state) { return r }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return c.ledger.record(id)
    }

    func testAnAddressTypedInStartsAndFinishesWithNoPageOpen() async throws {
        let c = coordinator()
        XCTAssertFalse(c.hasHost!())
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/65536"), at: Date()))
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "it needs no page")
        XCTAssertEqual(done?.id, id, "the task keeps the id it was given when added")
        XCTAssertEqual(done?.protocolID, .http)
        XCTAssertEqual(done?.profile, "default")
        XCTAssertEqual(done?.engineMetadata["origin"], DownloadRequestOrigin.user.rawValue, "added by the person, so it is not an untrusted request")
        XCTAssertEqual(done?.transfer.completedBytes, 65_536)
        let path = try XCTUnwrap(done?.file.destinationPath)
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(path, roots: [downloads]))
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), 65_536)
        XCTAssertFalse(c.events.contains { $0.contains("no page is open") }, "nothing waited for a page")
    }

    func testItGoesThroughTheSchedulerSoAHeldQueueHoldsIt() async throws {
        let c = coordinator()
        c.holdQueue(until: .distantFuture)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096"), at: Date()))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(c.ledger.record(id)?.state, .scheduled, "a held queue starts nothing, not even a typed-in address")
        XCTAssertTrue(c.active.isEmpty)
        c.resumeAll()
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed)
    }

    func testTheConcurrencyLimitStillApplies() async throws {
        let c = coordinator()
        c.maxConcurrent = 1
        let a = try XCTUnwrap(c.scheduleDownload(url: url("/throttle/\(4 << 20)?bps=1000000"), at: Date()))
        _ = await wait(c, a, for: [.running], seconds: 10)
        let b = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096"), at: Date()))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertLessThanOrEqual(c.active.count, 1, "one place, one download")
        XCTAssertNotEqual(c.ledger.record(b)?.state, .completed)
        c.cancel(a)
        let done = await wait(c, b, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "it takes the place when it is free")
    }

    func testEachProfileKeepsItsOwnDownloads() async throws {
        let work = coordinator(profile: "work"), home = coordinator(profile: "home")
        let id = try XCTUnwrap(work.scheduleDownload(url: url("/file/2048"), at: Date()))
        let done = await wait(work, id, for: [.completed, .failed])
        XCTAssertEqual(done?.profile, "work")
        XCTAssertNil(home.ledger.record(id), "the other profile never sees it")
        XCTAssertTrue(home.ledger.records.isEmpty)
        XCTAssertTrue(home.dashboardSnapshot { _ in false }.records.isEmpty)
    }

    func testOnlyWebAddressesAreAccepted() {
        let c = coordinator()
        XCTAssertNil(c.scheduleDownload(url: URL(string: "ftp://example.com/a.bin")!, at: Date()))
        XCTAssertNil(c.scheduleDownload(url: URL(string: "file:///etc/hosts")!, at: Date()))
        XCTAssertTrue(c.ledger.records.isEmpty, "nothing is created for a refused address")
    }

    func testTryAgainOnAFailedDownloadNeedsNoPageEither() async throws {
        let c = coordinator()
        let id = try await c.http.start(url: url("/status/404"))
        let failed = await wait(c, id, for: [.failed])
        XCTAssertEqual(failed?.state, .failed)
        let before = failed?.attempt ?? 0
        XCTAssertTrue(c.failures.contains { $0.id == id && $0.canRetry })
        c.retryFailure(id)
        let end = Date().addingTimeInterval(15)
        while Date() < end, (c.ledger.record(id)?.attempt ?? 0) <= before { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertGreaterThan(c.ledger.record(id)?.attempt ?? 0, before, "it was started again, as the same task")
        XCTAssertFalse(c.events.contains { $0.contains("no page is open") })
    }
}
