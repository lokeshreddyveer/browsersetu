import SQLite3
import XCTest
@testable import Browser_Setu

/// Piece planning, multipart eligibility and the hostname/connection security policy: decisions that need no network.
final class MultipartPlannerTests: XCTestCase {
    func testEveryByteBelongsToExactlyOnePieceForAnySize() {
        let sizes: [Int64] = [1, 2, 1023, (4 << 20) - 1, 4 << 20, (8 << 20) - 1, 8 << 20, (8 << 20) + 1, 16 << 20, 100_000_001, 1_000_000_007, 5 << 30, (64 << 30) + 12_345, Int64(1) << 40]
        for total in sizes {
            let pieces = MultipartPlanner.plan(total: total)
            XCTAssertNil(MultipartPlanner.coverageProblem(pieces, total: total, requireDone: false), "\(total)")
            XCTAssertEqual(pieces.reduce(Int64(0)) { $0 + $1.length }, total, "\(total): lengths add up")
            XCTAssertLessThanOrEqual(pieces.count, MultipartPlanner.maxPieces, "\(total): bounded")
            XCTAssertEqual(pieces.first?.start, 0)
            XCTAssertEqual(pieces.last?.end, total - 1)
            XCTAssertEqual(pieces.map(\.index), Array(pieces.indices))
        }
    }

    func testPiecesAreNotTinyExceptTheLast() {
        for total: Int64 in [50_000_000, 777_777_777, 20 << 30] {
            let pieces = MultipartPlanner.plan(total: total)
            for piece in pieces.dropLast() { XCTAssertGreaterThanOrEqual(piece.length, MultipartPlanner.minimumPieceSize, "\(total)") }
        }
    }

    func testTheBoundariesAreStableForAGivenSize() {
        XCTAssertEqual(MultipartPlanner.plan(total: 123_456_789), MultipartPlanner.plan(total: 123_456_789), "a restart computes the same pieces")
    }

    func testNothingToPlanForANonPositiveSize() {
        XCTAssertTrue(MultipartPlanner.plan(total: 0).isEmpty)
        XCTAssertTrue(MultipartPlanner.plan(total: -5).isEmpty)
        XCTAssertEqual(MultipartPlanner.coverageProblem([], total: 10, requireDone: false), .empty)
    }

    func testAVerySmallFileIsOnePiece() {
        XCTAssertEqual(MultipartPlanner.plan(total: 1000).count, 1)
        XCTAssertEqual(MultipartPlanner.connections(total: 1000, configured: 6), 1, "never more connections than pieces")
    }

    func testTheConnectionCountIsConservativeBoundedAndAtLeastOne() {
        XCTAssertEqual(MultipartPlanner.connections(total: 1 << 30, configured: 4), 4)
        XCTAssertEqual(MultipartPlanner.connections(total: 1 << 30, configured: 100), MultipartPlanner.maxConnections)
        XCTAssertEqual(MultipartPlanner.connections(total: 1 << 30, configured: 0), 1)
        XCTAssertEqual(MultipartPlanner.connections(total: 1 << 30, configured: -3), 1)
        XCTAssertEqual(MultipartPlanner.defaultConnections, 4, "starts low; more is not automatically faster")
    }

    func testGapsOverlapsAndAShortEndAreCaught() {
        let good = MultipartPlanner.plan(total: 30 << 20)
        var gap = good; gap[1].start += 10
        XCTAssertEqual(MultipartPlanner.coverageProblem(gap, total: 30 << 20, requireDone: false), .gap(after: gap[0].end))
        var overlap = good; overlap[1].start -= 10
        XCTAssertEqual(MultipartPlanner.coverageProblem(overlap, total: 30 << 20, requireDone: false), .overlap(at: overlap[1].start))
        XCTAssertEqual(MultipartPlanner.coverageProblem(Array(good.dropLast()), total: 30 << 20, requireDone: false), .wrongEnd(good[good.count - 2].end))
        var skipped = good; skipped[2].index = 5
        XCTAssertEqual(MultipartPlanner.coverageProblem(skipped, total: 30 << 20, requireDone: false), .badIndex(5))
        XCTAssertEqual(MultipartPlanner.coverageProblem(good, total: 30 << 20, requireDone: true), .notDone(0), "all must be done before finalising")
        var done = good; for i in done.indices { done[i].state = .done }
        XCTAssertNil(MultipartPlanner.coverageProblem(done, total: 30 << 20, requireDone: true))
    }
}

final class MultipartEligibilityTests: XCTestCase {
    private func eval(origin: DownloadRequestOrigin = .user, status: Int = 206, _ headers: [String: String], min: Int64 = 1 << 20) -> Result<MultipartEligibility, MultipartEligibility.Refusal> {
        MultipartEligibility.evaluate(origin: origin, status: status, headers: { headers[$0] }, minimumTotal: min)
    }
    private let good = ["Content-Range": "bytes 0-0/50000000", "ETag": "\"v1\""]

    func testAVerifiedRangeAnswerWithAValidatorIsEligible() throws {
        let ok = try eval(good).get()
        XCTAssertEqual(ok.total, 50_000_000); XCTAssertEqual(ok.etag, "\"v1\"")
        XCTAssertEqual(try eval(["Content-Range": "bytes 0-0/50000000", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"]).get().lastModified, "Wed, 21 Oct 2015 07:28:00 GMT")
    }

    func testAcceptRangesAloneIsNotEnough() {
        XCTAssertEqual(eval(status: 200, ["Accept-Ranges": "bytes", "Content-Length": "50000000", "ETag": "\"v1\""]), .failure(.noRangeSupport))
    }

    func testOnlyThePersonsOwnRequestsAreEligible() {
        XCTAssertEqual(eval(origin: .automation, good), .failure(.origin))
        XCTAssertEqual(eval(origin: .browserExtension, good), .failure(.origin))
    }

    func testEveryWayTheAnswerCanBeWrongIsRefused() {
        XCTAssertEqual(eval(["Content-Range": "bytes 5-9/50000000", "ETag": "\"v1\""]), .failure(.wrongRange))
        XCTAssertEqual(eval(["ETag": "\"v1\""]), .failure(.wrongRange), "no Content-Range")
        XCTAssertEqual(eval(["Content-Range": "bytes 0-0/*", "ETag": "\"v1\""]), .failure(.unknownSize))
        XCTAssertEqual(eval(["Content-Range": "bytes 0-0/500", "ETag": "\"v1\""], min: 1 << 20), .failure(.size))
        XCTAssertEqual(eval(["Content-Range": "bytes 0-0/50000000", "ETag": "\"v1\"", "Content-Encoding": "gzip"]), .failure(.encoded))
        XCTAssertEqual(eval(["Content-Range": "bytes 0-0/50000000"]), .failure(.noValidator), "no way to tell whether it changes between requests")
        XCTAssertEqual(eval(["Content-Range": "bytes 0-0/50000000", "ETag": "W/\"weak\""]), .failure(.weakValidator))
        XCTAssertEqual(eval(status: 416, good), .failure(.noRangeSupport))
        XCTAssertEqual(eval(status: 200, good), .failure(.noRangeSupport))
    }

    func testAWeakTagWithAModificationDateStillWorksOnTheDate() throws {
        let ok = try eval(["Content-Range": "bytes 0-0/50000000", "ETag": "W/\"weak\"", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"]).get()
        XCTAssertNil(ok.etag)
        XCTAssertNotNil(ok.lastModified)
    }

    func testTheDefaultMinimumSizeIsWhatThePlannerSays() {
        XCTAssertEqual(MultipartEligibility.evaluate(origin: .user, status: 206, headers: { ["Content-Range": "bytes 0-0/\(MultipartPlanner.minimumTotal - 1)", "ETag": "\"x\""][$0] }), .failure(.size))
        XCTAssertNotNil(try? MultipartEligibility.evaluate(origin: .user, status: 206, headers: { ["Content-Range": "bytes 0-0/\(MultipartPlanner.minimumTotal)", "ETag": "\"x\""][$0] }).get())
    }

    func testTheConnectionBudgetIsBoundedInTotalAndPerHost() {
        let budget = ConnectionBudget()
        budget.hostLimitOverride = 3; budget.totalLimitOverride = 5
        XCTAssertTrue((0..<3).allSatisfy { _ in budget.acquire(host: "a") })
        XCTAssertFalse(budget.acquire(host: "a"), "per host")
        XCTAssertTrue(budget.acquire(host: "b")); XCTAssertTrue(budget.acquire(host: "b"))
        XCTAssertFalse(budget.acquire(host: "c"), "in total")
        XCTAssertEqual(budget.open, 5)
        budget.release(host: "a")
        XCTAssertTrue(budget.acquire(host: "c"))
        for _ in 0..<20 { budget.release(host: "a"); budget.release(host: "b"); budget.release(host: "c") }
        XCTAssertEqual(budget.open, 0, "never goes below zero")
    }
}

/// Resolves from a table, so the hostname policy is tested with names that lead into the network, without a real DNS server.
private struct FakeResolver: HostAddressResolving {
    var table: [String: [String]]
    func addresses(for host: String) async -> [String]? { table[host] }
}

final class HostResolutionPolicyTests: XCTestCase {
    func testAddressesHiddenInsideOtherIPv6FormsAreStillInternal() {
        for host in ["64:ff9b::a9fe:a9fe", "64:ff9b::7f00:1", "2002:7f00:1::1", "2002:a9fe:a9fe::", "::7f00:1", "::a00:1", "fec0::1", "ff02::1", "[::ffff:10.0.0.1]"] {
            XCTAssertTrue(HTTPRequestPolicy.classify(host: host).isInternal, host)
        }
        for host in ["64:ff9b::808:808", "2002:808:808::1", "2606:4700:4700::1111"] {
            XCTAssertFalse(HTTPRequestPolicy.classify(host: host).isInternal, host)
        }
    }

    private var saved: HostAddressResolving!
    private var savedUntrusted = false
    override func setUp() {
        super.setUp()
        // These test the address layers that sit behind the switch for scripts' requests, so the switch is on here (and put back).
        savedUntrusted = HTTPRequestPolicy.untrustedRequestsEnabled
        HTTPRequestPolicy.untrustedRequestsEnabled = true
        saved = HTTPRequestPolicy.resolver
        HTTPRequestPolicy.resolver = FakeResolver(table: [
            "good.example": ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
            "evil.example": ["10.1.2.3"],
            "mixed.example": ["93.184.216.34", "192.168.1.5"],
            "loop.example": ["127.0.0.1"],
            "meta.example": ["169.254.169.254"],
            "v6local.example": ["fd12:3456:789a::1"],
            "v6loop.example": ["::1"],
            "mapped.example": ["::ffff:10.0.0.9"],
            "linklocal.example": ["fe80::1"],
            "nas.home": ["192.168.1.20"],
        ])
    }
    override func tearDown() { HTTPRequestPolicy.resolver = saved; HTTPRequestPolicy.untrustedRequestsEnabled = savedUntrusted; super.tearDown() }

    private let script = HTTPRequestPolicy(origin: .automation)
    private let user = HTTPRequestPolicy(origin: .user)

    func testANameThatResolvesIntoTheNetworkIsRefusedForAScript() async {
        for host in ["evil.example", "mixed.example", "loop.example", "meta.example", "v6local.example", "v6loop.example", "mapped.example", "linklocal.example"] {
            do { try await script.checkResolving(URL(string: "https://\(host)/f.zip")!); XCTFail("\(host) must be refused") }
            catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .internalAddress(host), host) }
        }
    }

    func testOneBadAddressAmongGoodOnesIsEnoughToRefuse() async {
        do { try await script.checkResolving(URL(string: "https://mixed.example/")!); XCTFail() } catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .internalAddress("mixed.example")) }
    }

    func testAPublicNameInBothFamiliesIsAccepted() async throws {
        try await script.checkResolving(URL(string: "https://good.example/f.zip")!)
    }

    func testANameThatCannotBeResolvedFailsClosedForAScriptButNotForThePerson() async throws {
        do { try await script.checkResolving(URL(string: "https://nowhere.example/")!); XCTFail("unverifiable") }
        catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .unverifiable("nowhere.example")) }
        try await user.checkResolving(URL(string: "https://nowhere.example/")!)       // the person's own request is theirs to make
    }

    func testThePersonsOwnRequestMayNameAHostOnTheirNetwork() async throws {
        try await user.checkResolving(URL(string: "http://nas.home/f.zip")!)
        try await user.checkResolving(URL(string: "http://evil.example/f.zip")!)
    }

    func testARedirectFromAPublicSiteToANameInsideIsRefusedForEveryone() async {
        let site = URL(string: "https://good.example/start")!
        for host in ["evil.example", "loop.example", "meta.example", "nas.home", "v6local.example"] {
            let target = URL(string: "https://\(host)/x")!
            for policy in [user, script] {
                let decision = await policy.decideRedirectResolving(from: site, to: target, chain: [site])
                XCTAssertEqual(decision, .refuse(.redirectIntoInternalNetwork(host)), "\(host) for \(policy.origin)")
            }
        }
    }

    func testAnInternalSiteMayRedirectInsideOnlyForThePerson() async {
        let nas = URL(string: "http://nas.home/a")!, other = URL(string: "http://evil.example/b")!
        let mine = await user.decideRedirectResolving(from: nas, to: other, chain: [nas])
        XCTAssertEqual(mine, .follow(dropCredentials: true))
        let theirs = await script.decideRedirectResolving(from: nas, to: other, chain: [nas])
        XCTAssertEqual(theirs, .refuse(.redirectIntoInternalNetwork("evil.example")))
    }

    func testARedirectToAnUnresolvableNameIsRefusedForAScript() async {
        let site = URL(string: "https://good.example/start")!
        let decision = await script.decideRedirectResolving(from: site, to: URL(string: "https://nowhere.example/x")!, chain: [site])
        XCTAssertEqual(decision, .refuse(.unverifiable("nowhere.example")))
    }

    func testTheAddressTheConnectionReallyWentToIsCheckedAfterwards() {
        // A name that resolved to a public address when checked and to a private one when connected (DNS rebinding) is caught by what the connection shows.
        XCTAssertEqual(script.verifyConnection(host: "rebind.example", remote: "10.0.0.7", viaProxy: false, fromPublic: true), .refuse(.connectedToInternalAddress("rebind.example", "10.0.0.7")))
        XCTAssertEqual(script.verifyConnection(host: "rebind.example", remote: "127.0.0.1", viaProxy: false, fromPublic: true), .refuse(.connectedToInternalAddress("rebind.example", "127.0.0.1")))
        XCTAssertEqual(script.verifyConnection(host: "rebind.example", remote: "fe80::1%en0", viaProxy: false, fromPublic: true), .refuse(.connectedToInternalAddress("rebind.example", "fe80::1%en0")))
        XCTAssertEqual(script.verifyConnection(host: "rebind.example", remote: "::ffff:192.168.0.2", viaProxy: false, fromPublic: true), .refuse(.connectedToInternalAddress("rebind.example", "::ffff:192.168.0.2")))
        XCTAssertEqual(script.verifyConnection(host: "good.example", remote: "93.184.216.34", viaProxy: false, fromPublic: true), .acceptable)
        XCTAssertEqual(script.verifyConnection(host: "good.example", remote: "2606:2800:220:1::1", viaProxy: false, fromPublic: true), .acceptable)
        // The person's own request to their own network is theirs; one that began at a public place is held to the rule too.
        XCTAssertEqual(user.verifyConnection(host: "nas.home", remote: "192.168.1.20", viaProxy: false, fromPublic: false), .acceptable)
        XCTAssertEqual(user.verifyConnection(host: "good.example", remote: "192.168.1.20", viaProxy: false, fromPublic: true), .refuse(.connectedToInternalAddress("good.example", "192.168.1.20")))
    }

    func testWhereTheAddressCannotBeKnownAScriptIsRefusedNotAssumedSafe() {
        XCTAssertEqual(script.verifyConnection(host: "good.example", remote: nil, viaProxy: false, fromPublic: true), .refuse(.unverifiable("good.example")), "no address in the metrics")
        XCTAssertEqual(script.verifyConnection(host: "good.example", remote: "93.184.216.34", viaProxy: true, fromPublic: true), .refuse(.unverifiable("good.example")), "a proxy resolves the name, not this app")
        XCTAssertEqual(user.verifyConnection(host: "nas.home", remote: nil, viaProxy: true, fromPublic: false), .acceptable)
    }

    func testClassifyingResolvesNamesAndTakesTheWorstAddress() async {
        let mixed = await HTTPRequestPolicy.classifyResolving(host: "mixed.example")
        XCTAssertEqual(mixed.kind, .privateNetwork)
        let good = await HTTPRequestPolicy.classifyResolving(host: "good.example")
        XCTAssertEqual(good.kind, .publicHost)
        XCTAssertEqual(good.resolved?.count, 2)
        let unknown = await HTTPRequestPolicy.classifyResolving(host: "nowhere.example")
        XCTAssertNil(unknown.resolved)
        let literal = await HTTPRequestPolicy.classifyResolving(host: "93.184.216.34")
        XCTAssertEqual(literal.kind, .publicHost, "a public literal is not resolved")
    }

    func testTheSystemResolverAnswersForARealName() async {
        let addresses = await SystemHostResolver().addresses(for: "localhost")
        XCTAssertTrue(addresses?.contains(where: { $0 == "127.0.0.1" || $0 == "::1" }) == true, "\(String(describing: addresses))")
        let none = await SystemHostResolver().addresses(for: "no-such-host-\(UUID().uuidString.prefix(8).lowercased()).invalid")
        XCTAssertNil(none)
    }
}

final class QuarantineTests: XCTestCase {
    /// The attribute is "flags;hex-seconds;agent;uuid". A sandboxed app's own files are marked by the system as they are created, so "is it marked" proves nothing here; what proves
    /// that this code wrote it is that the time inside it moves forward when it runs.
    private func quarantineTime(_ file: URL) -> UInt64? {
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(file.path, "com.apple.quarantine", &buffer, size, 0, 0) == size else { return nil }
        let fields = String(decoding: buffer, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        return fields.count >= 2 ? UInt64(fields[1], radix: 16) : nil
    }

    func testAFileIsMarkedAsDownloadedFromTheInternetByTheCode() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try XCTUnwrap(quarantineTime(file), "the system marks the files a sandboxed app creates")
        Thread.sleep(forTimeInterval: 2.2)
        DownloadQuarantine.apply(to: file, sourceOrigin: "https://files.example:443")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(file))
        XCTAssertGreaterThan(try XCTUnwrap(quarantineTime(file)), before, "the mark was written again, by this code")
    }

    func testFinalisingADownloadMarksTheResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q-final-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = directory.appendingPathComponent("incoming.tmp")
        try Data("payload".utf8).write(to: incoming)
        let before = try XCTUnwrap(quarantineTime(incoming))
        Thread.sleep(forTimeInterval: 2.2)
        let result = try HTTPTransferEngine.finalise(from: incoming, to: directory.appendingPathComponent("out.bin"), taskID: UUID(), sourceOrigin: "https://files.example:443")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(result))
        XCTAssertGreaterThan(try XCTUnwrap(quarantineTime(result)), before, "the real finalisation path marks the file")
    }
}

final class TaskPiecesStoreTests: XCTestCase {
    private var folder: URL!
    override func setUp() { super.setUp(); folder = FileManager.default.temporaryDirectory.appendingPathComponent("pieces-\(UUID().uuidString)") }
    override func tearDown() { DownloadTaskStore.close(folder: folder); try? FileManager.default.removeItem(at: folder); super.tearDown() }

    private func task(_ store: DownloadTaskStore) -> DownloadTaskRecord {
        let record = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: nil), filename: "big.bin")
        store.save(record); store.flush()
        return record
    }

    func testAPlanIsSavedReadBackAndPiecesAreMarkedDone() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let record = task(store)
        let plan = MultipartPlanner.plan(total: 40 << 20)
        try store.savePlan(task: record.id, pieces: plan)
        store.markPieceDone(task: record.id, index: 1, checksum: "abc", session: 2)
        store.flush()
        let read = store.loadPieces(task: record.id)
        XCTAssertEqual(read.count, plan.count)
        XCTAssertEqual(read.map(\.start), plan.map(\.start)); XCTAssertEqual(read.map(\.end), plan.map(\.end))
        XCTAssertEqual(read[1].state, .done); XCTAssertEqual(read[1].checksum, "abc"); XCTAssertEqual(read[1].session, 2)
        XCTAssertEqual(read[0].state, .pending)
        XCTAssertNil(MultipartPlanner.coverageProblem(read, total: 40 << 20, requireDone: false))
    }

    func testReplacingAPlanLeavesNoneOfTheOldOne() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let record = task(store)
        try store.savePlan(task: record.id, pieces: MultipartPlanner.plan(total: 100 << 20))
        try store.savePlan(task: record.id, pieces: MultipartPlanner.plan(total: 20 << 20))
        XCTAssertEqual(store.loadPieces(task: record.id).count, MultipartPlanner.plan(total: 20 << 20).count)
    }

    func testPiecesGoWithTheirTaskAndAreBounded() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let record = task(store)
        try store.savePlan(task: record.id, pieces: MultipartPlanner.plan(total: Int64(1) << 40))
        XCTAssertLessThanOrEqual(store.pieceCount(), MultipartPlanner.maxPieces, "rows are bounded however big the file")
        store.delete(record.id); store.flush()
        XCTAssertEqual(store.pieceCount(), 0, "removing the task removes its pieces")
    }

    func testPiecesOfOneTaskAreInvisibleToAnother() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let a = task(store), b = task(store)
        try store.savePlan(task: a.id, pieces: MultipartPlanner.plan(total: 20 << 20))
        XCTAssertTrue(store.loadPieces(task: b.id).isEmpty)
    }

    func testAnOldDatabaseWithoutPiecesIsMigratedAndKeepsItsTasks() throws {
        // A version-1 database (what Phase 1 and 2 wrote) gains the pieces table without losing anything.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("downloads.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, """
        CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
        CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, protocol TEXT NOT NULL, profile TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('created','resolving','queued','scheduled','starting','running','pausing','paused','resuming','verifying','retrying','completed','failed','cancelled','recoveryRequired')),
          priority INTEGER NOT NULL, queue_order INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, started_at REAL, completed_at REAL, scheduled_at REAL,
          attempt INTEGER NOT NULL DEFAULT 0, retry_count INTEGER NOT NULL DEFAULT 0, source_url TEXT, source_host TEXT, filename TEXT NOT NULL, destination_path TEXT, temporary_path TEXT,
          integrity TEXT NOT NULL DEFAULT 'unknown', total_bytes INTEGER, completed_bytes INTEGER NOT NULL DEFAULT 0, resume_available INTEGER NOT NULL DEFAULT 0, failure_code TEXT,
          failure_reason TEXT, failure_retryable INTEGER, engine_metadata TEXT, record_version INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE task_resume (task_id TEXT PRIMARY KEY NOT NULL REFERENCES tasks (id) ON DELETE CASCADE, data BLOB NOT NULL);
        INSERT INTO tasks (id, protocol, profile, state, priority, queue_order, created_at, updated_at, filename) VALUES ('\(UUID().uuidString)', 'http', 'default', 'completed', 1, 0, 1, 1, 'old.bin');
        PRAGMA user_version = 1;
        """, nil, nil, nil)
        sqlite3_close(handle)
        let store = DownloadTaskStore.open(folder: folder)
        XCTAssertEqual(store.outcome, .opened)
        XCTAssertEqual(store.loadAll(profile: "default").records.map(\.file.filename), ["old.bin"], "nothing lost")
        let id = store.loadAll(profile: "default").records[0].id
        try store.savePlan(task: id, pieces: MultipartPlanner.plan(total: 20 << 20))
        XCTAssertFalse(store.loadPieces(task: id).isEmpty, "and the new table works")
    }
}
