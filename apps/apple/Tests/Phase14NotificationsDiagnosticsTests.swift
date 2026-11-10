import XCTest
@testable import Browser_Setu

// Phase 14: the two security prerequisites from the Phase 13 gate, reliable event identity, notifications, diagnostics and indicators. Controlled fixtures and injected clocks;
// the real notification center and the real Keychain are never touched.

@MainActor
class P14Case: XCTestCase {
    var scratch: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p14-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }
}

private final class Flaky: @unchecked Sendable {
    var failing = false
    struct Refused: Error, LocalizedError { var errorDescription: String? { "the disk refused" } }
    func write(_ data: Data, _ url: URL) throws {
        if failing { throw Refused() }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 3. Credential-store persistence fails closed

@MainActor
final class ClientStorePersistenceTests: P14Case {
    private let all: Set<AutomationScope> = [.downloadsRead, .downloadsControl]
    private func makeStore(_ flaky: Flaky, deny: DenyFake = DenyFake(failWrite: true), now: @escaping () -> Date = Date.init) -> (AutomationClientStore, URL) {
        let file = scratch.appendingPathComponent("clients.json")
        // No deny store accepts anything here, so these tests are about the case where nothing durable is possible.
        return (AutomationClientStore(file: file, now: now, writer: flaky.write, denyStores: [deny]), file)
    }
    private func enrolled(_ s: AutomationClientStore, scopes: Set<AutomationScope>? = nil) -> (AutomationClient, String) {
        guard case .created(let c, let t) = s.enrol(name: "tool", profile: "default", scopes: scopes ?? all) else { fatalError() }
        return (c, t)
    }

    func testRevocationIsSavedAndSurvivesARestart() {
        let f = Flaky(); let (s, file) = makeStore(f)
        let (c, t) = enrolled(s)
        XCTAssertEqual(s.revoke(c.id), .committed)
        XCTAssertEqual(s.authenticate(t), .failed)
        let again = AutomationClientStore(file: file)
        XCTAssertEqual(again.authenticate(t), .failed, "after a restart the revoked client is still refused")
    }

    func testAFailedSaveOfARevocationIsNeverReportedAsDone() {
        let f = Flaky(); let (s, file) = makeStore(f)
        let (c, t) = enrolled(s)
        f.failing = true
        var closed: [String] = []; s.onInvalidate = { closed.append($0) }
        guard case .restrictedButNotSaved(let why) = s.revoke(c.id) else { return XCTFail("must not say it was saved") }
        XCTAssertFalse(why.contains(t), "no secret in the message")
        XCTAssertEqual(s.authenticate(t), .failed, "blocked in this run all the same")
        XCTAssertEqual(closed, [c.id], "streams are closed at once")
        XCTAssertNotNil(s.storageProblem); XCTAssertTrue(s.hasUnsavedRestrictions)
        // The honest part: the file still holds the old state, so a restart would bring it back. That is why the person is told.
        XCTAssertEqual(AutomationClientStore(file: file).authenticate(t) != .failed, true)
    }

    func testTheSaveIsRetriedOnUseAndThenHolds() {
        let f = Flaky(); var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (s, file) = makeStore(f, now: { now })
        let (c, t) = enrolled(s)
        f.failing = true; _ = s.revoke(c.id)
        f.failing = false; now = now.addingTimeInterval(6)
        XCTAssertEqual(s.authenticate(t), .failed)          // use triggers the retry
        XCTAssertFalse(s.hasUnsavedRestrictions); XCTAssertNil(s.storageProblem)
        XCTAssertEqual(AutomationClientStore(file: file).authenticate(t), .failed, "now it would survive a restart")
    }

    func testAFailedRotationLeavesTheOldSecretWorking() {
        let f = Flaky(); let (s, _) = makeStore(f)
        let (c, t) = enrolled(s)
        f.failing = true
        let r = s.rotate(c.id)
        XCTAssertNil(r.token)
        guard case .refused = r.commit else { return XCTFail() }
        XCTAssertEqual(s.authenticate(t), .ok(s.clients[0]), "nothing changed, in memory or on disk")
    }

    func testRotationIsSavedAndTheOldSecretStaysDeadAfterARestart() {
        let f = Flaky(); let (s, file) = makeStore(f)
        let (c, old) = enrolled(s)
        let fresh = s.rotate(c.id).token!
        let again = AutomationClientStore(file: file)
        XCTAssertEqual(again.authenticate(old), .failed); XCTAssertNotEqual(again.authenticate(fresh), .failed)
    }

    func testScopeReductionIsSavedAndASavedFailureStillRestricts() {
        let f = Flaky(); let deny = DenyFake(failWrite: false); let (s, file) = makeStore(f, deny: deny)
        let (c, t) = enrolled(s)
        XCTAssertEqual(s.setScopes(c.id, [.downloadsRead]), .committed)
        guard case .ok(let reloaded) = AutomationClientStore(file: file).authenticate(t) else { return XCTFail() }
        XCTAssertEqual(reloaded.scopes, [.downloadsRead])
        let (c2, t2) = enrolled(s)                                           // two permissions, to narrow
        f.failing = true; deny.failWrite = true
        guard case .restrictedButNotSaved = s.setScopes(c2.id, [.downloadsRead]) else { return XCTFail() }
        XCTAssertEqual(s.authenticate(t2), .failed, "with nothing durable possible, nobody is admitted rather than risk the old permission returning")
        f.failing = false; deny.failWrite = false
        XCTAssertTrue(s.flush())
        guard case .ok(let now) = s.authenticate(t2) else { return XCTFail() }
        XCTAssertEqual(now.scopes, [.downloadsRead], "narrower, and saved")
    }

    func testWideningNeedsASuccessfulSave() {
        let f = Flaky(); let (s, _) = makeStore(f)
        let (c, _) = enrolled(s, scopes: [.downloadsRead])
        f.failing = true
        guard case .refused = s.setScopes(c.id, [.downloadsRead, .downloadsFiles]) else { return XCTFail() }
        XCTAssertEqual(s.clients[0].scopes, [.downloadsRead])
        guard case .refused = s.enrol(name: "new", profile: "default", scopes: [.downloadsRead]) else { return XCTFail("a new client is not made if it cannot be saved") }
        XCTAssertEqual(s.clients.count, 1)
    }

    func testARemovalThatCannotBeSavedKeepsTheClientRevoked() {
        let f = Flaky(); let (s, _) = makeStore(f)
        let (c, t) = enrolled(s)
        f.failing = true
        guard case .restrictedButNotSaved = s.remove(c.id) else { return XCTFail() }
        XCTAssertEqual(s.authenticate(t), .failed)
        XCTAssertNotNil(s.clients.first { $0.id == c.id }?.revokedAt, "kept, as revoked, rather than forgotten")
    }

    func testAnUnreadableListAdmitsNobodyUntilItIsReset() throws {
        let file = scratch.appendingPathComponent("clients.json")
        let f = Flaky(); let ok = AutomationClientStore(file: file, writer: f.write)
        let (_, t) = enrolled(ok)
        try Data("{ not json".utf8).write(to: file)
        let broken = AutomationClientStore(file: file, writer: f.write)
        XCTAssertFalse(broken.isReadable); XCTAssertNotNil(broken.storageProblem)
        XCTAssertEqual(broken.authenticate(t), .failed)
        guard case .refused = broken.enrol(name: "x", profile: "default", scopes: [.downloadsRead]) else { return XCTFail() }
        XCTAssertEqual(broken.resetUnreadableList(), .committed)
        XCTAssertTrue(broken.isReadable)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: scratch.path)).contains { $0.hasPrefix("clients.unreadable-") }, "the bad file is kept, not deleted")
        XCTAssertEqual(broken.authenticate(t), .failed, "the old client did not come back")
    }

    func testWithdrawingAccessThroughTheServiceClosesStreamsEvenWhenTheSaveFails() async {
        let f = Flaky(); let (s, _) = makeStore(f)
        let (c, t) = enrolled(s, scopes: [.downloadsRead])
        let coordinator = DownloadCoordinator()
        let service = AutomationService(clients: s, coordinators: { [coordinator] in [coordinator] })
        service.start()
        let r = await service.handle(AutomationRequest(method: "GET", target: "/v1/events", headers: ["authorization": "Bearer \(t)"], body: Data()))
        guard case .stream(let sub) = r else { return XCTFail() }
        f.failing = true
        _ = s.revoke(c.id)
        XCTAssertTrue(sub.isClosed)
        let after = await service.handle(AutomationRequest(method: "GET", target: "/v1/events", headers: ["authorization": "Bearer \(t)", "last-event-id": "abcd1234-1"], body: Data()))
        XCTAssertEqual(after.status, 401, "a revoked client cannot resume a stream")
    }
}

// MARK: - 4. Webhook destinations

@MainActor
final class WebhookEnforcementTests: P14Case {
    private final class Spy: WebhookTransport, @unchecked Sendable {
        var posts = 0
        func post(_ url: URL, headers: [String: String], body: Data) async -> Int? { posts += 1; return 200 }
    }
    private func event() -> AutomationEvent { .init(id: 1, epoch: "abcd1234", type: "task.completed", taskID: UUID().uuidString, state: "completed", fraction: 1, bytesReceived: 1, sourceHost: "h.org", profile: "p", at: Date()) }

    func testOnlyThisMacsNumericAddressIsAccepted() {
        for ok in ["http://127.0.0.1:9000/in", "http://127.5.5.5/in", "http://[::1]:9/in"] { XCTAssertNil(WebhookDestination.validate(URL(string: ok)!), ok) }
        for no in ["https://example.org/in", "http://localhost/in", "http://10.0.0.1/in", "http://192.168.1.1/in", "http://169.254.169.254/in", "http://127.0.0.1.nip.io/in", "http://2130706433/in", "http://0x7f.1/in", "http://[::ffff:10.0.0.1]/in", "http://0.0.0.0/in"] {
            XCTAssertNotNil(WebhookDestination.validate(URL(string: no)!), no)
        }
    }

    func testANameIsNeverLookedUpSoRebindingHasNothingToWinOn() {
        // The old validator asked a resolver; now none is consulted. A name that answers "public" and then "private" is refused before either answer matters.
        let spy = Spy(); let h = AutomationWebhooks(file: nil, secrets: MemorySecretVault(), transport: spy, sleeper: { _ in })
        guard case .refused(let why) = h.add(URL(string: "https://rebind.example.org/in")!) else { return XCTFail() }
        XCTAssertTrue(why.contains("127.0.0.1"))
        XCTAssertTrue(h.endpoints.isEmpty)
    }

    func testAnEndpointSavedByAnEarlierVersionForAWebsiteIsNeverSentTo() async throws {
        let file = scratch.appendingPathComponent("hooks.json")
        let legacy = [WebhookEndpoint(id: "legacy01", url: URL(string: "https://hooks.example.org/in")!, createdAt: Date())]
        try AutomationJSON.encoder.encode(legacy).write(to: file)
        let vault = MemorySecretVault(); _ = vault.store(Data("s".utf8), for: "legacy01")
        let spy = Spy(); let h = AutomationWebhooks(file: file, secrets: vault, transport: spy, sleeper: { _ in })
        XCTAssertEqual(h.endpoints.count, 1)
        h.enqueue(event()); await h.flush()
        XCTAssertEqual(spy.posts, 0, "fails closed"); XCTAssertEqual(h.dropped, 1)
    }

    func testRedirectsProxiesAndCookiesAreOffInTheDeliveryTransport() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Automation/AutomationWebhooks.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("willPerformHTTPRedirection") && text.contains("{ nil }"))
        XCTAssertTrue(text.contains("connectionProxyDictionary = [:]"))
        XCTAssertTrue(text.contains("httpCookieStorage = nil"))
        XCTAssertFalse(text.contains("getaddrinfo"), "no name lookup remains in the webhook path")
    }
}

// MARK: - 5. Event identity and replay

@MainActor
final class EventReliabilityTests: P14Case {
    private func snap(_ id: UUID = UUID(), _ state: DownloadState = .queued, profile: String = "default") -> AutomationEventHub.Snapshot { .init(id: id, state: state, fraction: nil, bytes: 0, host: "h.org", profile: profile) }
    private func hub(file: URL? = nil, block: Int = 4) -> AutomationEventHub { AutomationEventHub(sequence: AutomationEventSequence(file: file, block: block)) }
    private func firstEvents(_ sub: AutomationSubscription, _ n: Int) async -> [AutomationEvent] {
        var out: [AutomationEvent] = []
        for _ in 0..<n { if sub.pending > 0 || out.isEmpty { if let e = await sub.next() { out.append(e) } } }
        return out
    }

    func testIdsContinueAboveEverythingIssuedBeforeARestart() {
        let file = scratch.appendingPathComponent("seq.json")
        let first = AutomationEventSequence(file: file, block: 4)
        let issued = (0..<10).map { _ in first.next() }
        let second = AutomationEventSequence(file: file, block: 4)           // the app was quit and opened again
        XCTAssertEqual(second.epoch, first.epoch, "one unbroken sequence")
        XCTAssertGreaterThan(second.next(), issued.max()!, "no number is used twice")
    }

    func testAnUnsavableOrUnreadableSequenceGetsANewEpoch() throws {
        let file = scratch.appendingPathComponent("seq.json")
        try Data("garbage".utf8).write(to: file)
        let a = AutomationEventSequence(file: file)
        XCTAssertTrue(a.persistenceDegraded)
        let failing = AutomationEventSequence(file: scratch.appendingPathComponent("never.json"), writer: { _, _ in throw Flaky.Refused() })
        XCTAssertTrue(failing.persistenceDegraded)
        let other = AutomationEventSequence(file: scratch.appendingPathComponent("never.json"), writer: { _, _ in throw Flaky.Refused() })
        XCTAssertNotEqual(failing.epoch, other.epoch, "positions from an unsaved run can never be mistaken for these")
    }

    func testReconnectingReplaysExactlyWhatWasMissedForOneProfile() async {
        let h = hub(); h.ingest([], now: 0)
        let a = UUID(), b = UUID(), c = UUID()
        h.ingest([snap(a, profile: "alpha")], now: 1)
        h.ingest([snap(a, profile: "alpha"), snap(b, profile: "alpha"), snap(c, profile: "beta")], now: 2)
        let sub = h.subscribe(clientID: "x", profile: "alpha", lastEventID: "\(h.sequence.epoch)-1")!
        let got = await sub.next()
        XCTAssertEqual(got?.taskID, b.uuidString); XCTAssertEqual(sub.pending, 0, "beta's event is not replayed")
        XCTAssertNotEqual(got?.type, "stream.gap")
    }

    func testAClientThatIsUpToDateGetsNoGap() async {
        let h = hub(); h.ingest([], now: 0); h.ingest([snap()], now: 1)
        let sub = h.subscribe(clientID: "x", profile: "default", lastEventID: "\(h.sequence.epoch)-\(h.sequence.lastIssued)")!
        XCTAssertEqual(sub.pending, 0)
    }

    func testEveryKindOfUnreplayablePositionIsSaidOutLoud() async {
        let h = hub(); h.ingest([], now: 0)
        for _ in 0..<5 { h.ingest([snap()], now: 1); h.ingest([], now: 2) }
        let cases: [(String, String)] = [
            ("deadbeef-1", "restarted"), ("\(h.sequence.epoch)-99999", "unknown_position"), ("12", "unrecognised_position"), ("nonsense", "unrecognised_position"), ("", "unrecognised_position"),
        ]
        for (header, why) in cases {
            let sub = h.subscribe(clientID: "c\(why)", profile: "default", lastEventID: header)!
            let first = await sub.next()
            XCTAssertEqual(first?.type, "stream.gap", header); XCTAssertEqual(first?.note, why, header)
            sub.close()
        }
    }

    func testAnExpiredPositionIsAGapNotAPartialReplay() async {
        let h = hub(block: 1000); h.ingest([], now: 0)
        for _ in 0..<(AutomationEventHub.historyLimit + 50) { h.ingest([snap()], now: 1); h.ingest([], now: 2) }
        let sub = h.subscribe(clientID: "x", profile: "default", lastEventID: "\(h.sequence.epoch)-1")!
        let first = await sub.next()
        XCTAssertEqual(first?.type, "stream.gap"); XCTAssertEqual(first?.note, "expired")
        XCTAssertEqual(sub.pending, 0, "no pretend-complete replay follows")
    }

    func testMoreThanTheBufferHoldsIsAGapNotATruncatedReplay() async {
        let h = hub(block: 1000); h.ingest([], now: 0)
        for _ in 0..<70 { h.ingest([snap()], now: 1); h.ingest([], now: 2) }
        let sub = h.subscribe(clientID: "x", profile: "default", lastEventID: "\(h.sequence.epoch)-0")!
        let first = await sub.next()
        XCTAssertEqual(first?.note, "too_many_missed"); XCTAssertEqual(sub.pending, 0)
    }

    func testAfterARestartWithNoHistoryTheGapIsHistoryUnavailable() async {
        let file = scratch.appendingPathComponent("seq.json")
        let before = hub(file: file); before.ingest([], now: 0)
        for _ in 0..<3 { before.ingest([snap()], now: 1); before.ingest([], now: 2) }
        let epoch = before.sequence.epoch
        let after = hub(file: file)                                          // restarted: sequence kept, history gone
        let sub = after.subscribe(clientID: "x", profile: "default", lastEventID: "\(epoch)-1")!
        let first = await sub.next()
        XCTAssertEqual(first?.type, "stream.gap"); XCTAssertEqual(first?.note, "history_unavailable")
        XCTAssertGreaterThan(after.sequence.next(), 3)
    }

    func testTheStreamHeaderRoundTrips() {
        let h = AutomationEventSequence.header(epoch: "abcd1234", id: 42)
        XCTAssertEqual(h, "abcd1234-42")
        XCTAssertTrue(AutomationEventSequence.parse(h)! == (epoch: "abcd1234", id: 42))
        XCTAssertNil(AutomationEventSequence.parse("42")); XCTAssertNil(AutomationEventSequence.parse("abcd1234--1"))
    }

    func testTheServiceStreamStartsWithAGapWhenTheClientHoldsAnOldPosition() async {
        let store = AutomationClientStore(file: nil)
        guard case .created(_, let t) = store.enrol(name: "t", profile: "default", scopes: [.downloadsRead]) else { return XCTFail() }
        let service = AutomationService(clients: store, coordinators: { [DownloadCoordinator()] })
        service.start()
        let r = await service.handle(AutomationRequest(method: "GET", target: "/v1/events", headers: ["authorization": "Bearer \(t)", "last-event-id": "deadbeef-7"], body: Data()))
        guard case .stream(let sub) = r else { return XCTFail() }
        let first = await sub.next()
        XCTAssertEqual(first?.note, "restarted"); sub.close()
    }

    func testRetainedHistoryIsBounded() {
        let h = hub(block: 10_000); h.ingest([], now: 0)
        for _ in 0..<500 { h.ingest([snap()], now: 1); h.ingest([], now: 2) }
        let sub = h.subscribe(clientID: "x", profile: "default", lastEventID: "\(h.sequence.epoch)-\(h.sequence.lastIssued - 5)")!
        XCTAssertLessThanOrEqual(sub.pending, 8)
    }

    func testDerivedEventsAppearOnce() {
        let h = hub(); var types: [String] = []
        let a = UUID()
        h.ingest([snap(a, .running, profile: "p")], now: 0) { types.append($0.type) }
        h.ingest([snap(a, .running, profile: "p")], now: 1) { types.append($0.type) }
        var done = snap(a, .completed, profile: "p"); done.integrity = "mismatch"
        h.ingest([done], now: 2) { types.append($0.type) }
        h.ingest([done], now: 3) { types.append($0.type) }
        XCTAssertEqual(types, ["task.completed", "task.integrity_failed", "queue.completed"])
    }

    func testScheduledReadyAndRetryEvents() {
        let h = hub(); var types: [String] = []
        let a = UUID(), b = UUID()
        h.ingest([snap(a, .scheduled), snap(b, .running)], now: 0)
        var retry = snap(b, .running); retry.retryCount = 1
        h.ingest([snap(a, .queued), retry], now: 1) { types.append($0.type) }
        XCTAssertEqual(Set(types), ["task.scheduled_ready", "task.retry_scheduled"])
    }

    func testOnlyOneWatcherReadsTheLedger() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads")
        var users: [String] = []
        for folder in ["Automation", "Notifications"] {
            for f in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path) where f.hasSuffix(".swift") {
                if try String(contentsOf: root.appendingPathComponent(folder).appendingPathComponent(f), encoding: .utf8).contains("tasksChanged") { users.append(f) }
            }
        }
        XCTAssertEqual(users, ["DownloadEventFeed.swift"])
    }

    func testTwoCoordinatorsAreCompared_TogetherNotOneAtATime() {
        let a = DownloadCoordinator(); a.profileName = "alpha"; let b = DownloadCoordinator(); b.profileName = "beta"
        let feed = DownloadEventFeed(coordinators: { [a, b] })
        var types: [String] = []; feed.observe { e, _ in types.append(e.type) }
        feed.publishChanges()
        _ = a.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        _ = b.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        feed.publishChanges(); feed.publishChanges()
        XCTAssertEqual(types.filter { $0 == "task.created" }.count, 2, "each task is new once, not once per coordinator pass")
    }
}

// MARK: - 6–8. Notifications

@MainActor
final class FakeCenter: NotificationCenterProviding {
    var status = NotificationPermission.allowed
    var grantOnRequest = true
    var delivered: [NotificationPayload] = []
    var requests = 0, categoryRegistrations = 0
    func permission() async -> NotificationPermission { status }
    func requestPermission() async -> Bool { requests += 1; status = grantOnRequest ? .allowed : .denied; return grantOnRequest }
    func deliver(_ payload: NotificationPayload) async { delivered.append(payload) }
    func registerCategories() { categoryRegistrations += 1 }
    func remove(identifiers: [String]) {}
}

@MainActor
final class NotificationTests: P14Case {
    var center: FakeCenter!, coordinator: DownloadCoordinator!, service: DownloadNotificationService!
    var visible = false, active = true
    var opened: [UUID?] = [], revealed: [URL] = [], inApp: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        center = FakeCenter(); coordinator = DownloadCoordinator()
        opened = []; revealed = []; inApp = []; visible = false; active = true
        service = DownloadNotificationService(center: center, coordinators: { [unowned self] in [self.coordinator] }, downloadsVisible: { [unowned self] in self.visible },
                                              appActive: { [unowned self] in self.active }, openDownloads: { [unowned self] in self.opened.append($0) },
                                              reveal: { [unowned self] in self.revealed.append($0) }, inApp: { [unowned self] t, b in self.inApp.append("\(t)|\(b)") })
        service.preferences.enabled = true
    }

    private func finished(_ name: String = "a.bin", integrityTotal: Int64? = nil) throws -> (UUID, AutomationEvent) {
        let s = coordinator.begin(suggestedName: name, sourceURL: URL(string: "https://files.example.org/\(name)"), cancel: {})
        if let integrityTotal { coordinator.ledger.update(s.id) { $0.transfer.totalBytes = integrityTotal } }
        try Data([1]).write(to: s.destination)
        coordinator.finish(s.id, source: nil)
        return (s.id, event("task.completed", s.id))
    }
    private func event(_ type: String, _ id: UUID?, id n: Int = 1) -> AutomationEvent {
        .init(id: n, epoch: "abcd1234", type: type, taskID: id?.uuidString, state: nil, fraction: nil, bytesReceived: nil, sourceHost: "files.example.org", profile: coordinator.profileName, at: Date())
    }

    func testCompletionNamesTheFileAndOffersFinderAndDownloads() async throws {
        let (_, e) = try finished("report.pdf")
        await service.handle(e, coordinator: coordinator)
        let p = try XCTUnwrap(center.delivered.first)
        XCTAssertEqual(p.title, "Download finished"); XCTAssertEqual(p.body, "report.pdf"); XCTAssertEqual(p.category, "download.completed")
        XCTAssertFalse(p.body.contains("files.example.org"))
    }

    func testFailureExplainsAndOffersRetryOnlyWhenItCanHelp() async throws {
        let source = URL(string: "https://files.example.org/f.bin")!
        let s = coordinator.begin(suggestedName: "f.bin", sourceURL: source, cancel: {})
        coordinator.fail(s.id, source: source, error: URLError(.timedOut), willRetry: false)
        await service.handle(event("task.failed", s.id), coordinator: coordinator)
        XCTAssertEqual(center.delivered.last?.category, "download.failed", "a timeout can be tried again")
        XCTAssertTrue(center.delivered.last?.body.contains("took too long") == true)
        let t = coordinator.begin(suggestedName: "g.bin", sourceURL: source, cancel: {})
        coordinator.fail(t.id, source: source, error: HTTPDownloadError(info: DownloadFailureInfo(code: "http:404", reason: "gone", retryable: false)), willRetry: false)
        await service.handle(event("task.failed", t.id, id: 2), coordinator: coordinator)
        XCTAssertEqual(center.delivered.last?.category, "download.info", "a missing file is not offered a retry")
        XCTAssertFalse(center.delivered.last?.body.contains("gone") == true, "the raw message is not shown")
    }

    func testRecoveryIntegrityQueueAndScheduledEvents() async throws {
        service.preferences.queueCompleted = true; service.preferences.scheduledReady = true
        let s = coordinator.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r"), cancel: {})
        await service.handle(event("task.recovery_required", s.id, id: 1), coordinator: coordinator)
        await service.handle(event("task.integrity_failed", s.id, id: 2), coordinator: coordinator)
        await service.handle(event("task.scheduled_ready", s.id, id: 3), coordinator: coordinator)
        await service.handle(event("queue.completed", nil, id: 4), coordinator: coordinator)
        XCTAssertEqual(center.delivered.map(\.title), ["Download needs attention", "File does not match", "Scheduled download started", "Downloads finished"])
    }

    func testNothingIsSentForOffPreferencesOrProgress() async throws {
        let (_, e) = try finished()
        service.preferences.enabled = false
        await service.handle(e, coordinator: coordinator)
        service.preferences.enabled = true; service.preferences.completion = false
        await service.handle(e, coordinator: coordinator)
        service.preferences.completion = true
        await service.handle(event("task.progress", UUID()), coordinator: coordinator)
        await service.handle(event("task.started", UUID()), coordinator: coordinator)
        await service.handle(event("queue.completed", nil), coordinator: coordinator)       // off by default
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testPermissionIsNeverAssumedAndIsOnlyAskedForOnRequest() async throws {
        center.status = .notDetermined
        let (_, e) = try finished()
        await service.handle(e, coordinator: coordinator)
        XCTAssertTrue(center.delivered.isEmpty); XCTAssertEqual(center.requests, 0, "nothing asks on its own")
        service.attach(to: DownloadEventFeed(coordinators: { [] })); service.prepare()
        XCTAssertEqual(center.requests, 0, "not on attach, not on prepare")
        await service.requestPermission()
        XCTAssertEqual(center.requests, 1); XCTAssertEqual(service.permission, .allowed)
    }

    func testDeniedPermissionDeliversNothingToTheSystemButInAppStillWorks() async throws {
        center.status = .denied
        let (_, e) = try finished("d.bin")
        await service.handle(e, coordinator: coordinator)
        XCTAssertTrue(center.delivered.isEmpty); XCTAssertTrue(inApp.isEmpty, "system-only mode shows nothing in the app")
        service.preferences.delivery = .inApp
        let (_, e2) = try finished("e.bin")
        await service.handle(e2, coordinator: coordinator)
        XCTAssertEqual(inApp.count, 1); XCTAssertTrue(center.delivered.isEmpty)
        service.preferences.delivery = .both
        let (_, e3) = try finished("f.bin")
        await service.handle(e3, coordinator: coordinator)
        XCTAssertEqual(inApp.count, 2); XCTAssertTrue(center.delivered.isEmpty, "denied stays denied")
    }

    func testQuietWhileTheDownloadsWindowIsInFront() async throws {
        visible = true; active = true
        let (_, e) = try finished("q.bin")
        await service.handle(e, coordinator: coordinator)
        XCTAssertTrue(center.delivered.isEmpty)
        active = false
        let (_, e2) = try finished("w.bin")
        await service.handle(e2, coordinator: coordinator)
        XCTAssertEqual(center.delivered.count, 1, "in the background it is sent even with the window open")
        service.preferences.quietWhileDownloadsVisible = false; visible = true; active = true
        let (_, e3) = try finished("z.bin")
        await service.handle(e3, coordinator: coordinator)
        XCTAssertEqual(center.delivered.count, 2)
    }

    func testTheSameEventNeverNotifiesTwice() async throws {
        let (_, e) = try finished("dup.bin")
        await service.handle(e, coordinator: coordinator); await service.handle(e, coordinator: coordinator)
        var again = e; again.id = 99
        await service.handle(again, coordinator: coordinator)
        XCTAssertEqual(center.delivered.count, 1)
    }

    func testAPrivateDownloadNeverNotifies() async throws {
        let s = coordinator.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {})
        try Data([1]).write(to: s.destination); coordinator.finish(s.id, source: nil)
        await service.handle(event("task.completed", s.id), coordinator: coordinator)
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testThroughTheFeedEndToEndWithoutAProgressFlood() async throws {
        let feed = DownloadEventFeed(coordinators: { [unowned self] in [self.coordinator] })
        service.attach(to: feed)
        feed.publishChanges()
        let s = coordinator.begin(suggestedName: "e2e.bin", sourceURL: URL(string: "https://a.org/e2e"), cancel: {})
        feed.publishChanges()
        try Data([1]).write(to: s.destination); coordinator.finish(s.id, source: nil)
        feed.publishChanges(); feed.publishChanges()
        for _ in 0..<100 where center.delivered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(center.delivered.map(\.title), ["Download finished"])
        service.detach(); XCTAssertEqual(feed.observerCount, 0, "no observer is left behind")
    }

    // Actions

    func testRevealShowsACompletedFileAndNeverOpensIt() throws {
        let (id, _) = try finished("show.bin")
        let info = ["profile": coordinator.profileName, "task": id.uuidString]
        XCTAssertEqual(service.perform(action: "reveal", userInfo: info), .done)
        XCTAssertEqual(revealed.count, 1); XCTAssertEqual(revealed.first?.lastPathComponent, "show.bin")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Notifications/DownloadNotifications.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("NSWorkspace.shared.open") || source.contains("openApplication"), "a file is shown, never opened")
    }

    func testActionsAreCheckedAgainstProfileTaskAndState() throws {
        let (id, _) = try finished("a.bin")
        let good = ["profile": coordinator.profileName, "task": id.uuidString]
        XCTAssertEqual(service.perform(action: "reveal", userInfo: ["profile": "other", "task": id.uuidString]), .refused("That download belongs to a profile that is not open."))
        XCTAssertEqual(service.perform(action: "reveal", userInfo: ["profile": coordinator.profileName, "task": UUID().uuidString]), .refused("That download is no longer in the list."))
        XCTAssertEqual(service.perform(action: "retry", userInfo: good), .refused("This download cannot be tried again from here."), "a finished download has nothing to retry")
        XCTAssertEqual(service.perform(action: "explode", userInfo: good), .refused("Unknown action."))
        let p = coordinator.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {})
        XCTAssertEqual(service.perform(action: "details", userInfo: ["profile": coordinator.profileName, "task": p.id.uuidString]), .refused("That download is no longer in the list."))
        XCTAssertTrue(revealed.isEmpty)
    }

    func testRevealRefusesAFileThatMovedOrIsOutsideDownloads() throws {
        let (id, _) = try finished("x.bin")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("p14-outside-\(UUID().uuidString)"); try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        coordinator.ledger.update(id) { $0.file.destinationPath = outside.path }
        guard case .refused = service.perform(action: "reveal", userInfo: ["profile": coordinator.profileName, "task": id.uuidString]) else { return XCTFail() }
        XCTAssertTrue(revealed.isEmpty)
    }

    func testRetryRunsThroughTheCoordinatorOnlyForARetryableFailure() throws {
        var started: URL?; coordinator.hasHost = { true }; coordinator.starter = { started = $0 }
        let source = URL(string: "https://files.example.org/r.bin")!
        let s = coordinator.begin(suggestedName: "r.bin", sourceURL: source, cancel: {})
        coordinator.fail(s.id, source: source, error: URLError(.badServerResponse), willRetry: false)
        XCTAssertEqual(service.perform(action: "retry", userInfo: ["profile": coordinator.profileName, "task": s.id.uuidString]), .done)
        XCTAssertEqual(started, source)
        // A failure that cannot be repeated from its address (a POST) is refused.
        let t = coordinator.begin(suggestedName: "t.bin", sourceURL: source, cancel: {})
        coordinator.fail(t.id, source: source, error: URLError(.badServerResponse), willRetry: false, replayableByAddress: false)
        guard case .refused = service.perform(action: "retry", userInfo: ["profile": coordinator.profileName, "task": t.id.uuidString]) else { return XCTFail() }
    }

    func testOpenAndDetailsRouteToTheDownloadsWindow() throws {
        let (id, _) = try finished("o.bin")
        service.perform(action: "open", userInfo: ["profile": coordinator.profileName])
        service.perform(action: "details", userInfo: ["profile": coordinator.profileName, "task": id.uuidString])
        XCTAssertEqual(opened.count, 2); XCTAssertEqual(opened.last ?? nil, id)
    }

    // Preferences and the old notifier

    func testPreferencesRoundTripAndStartOff() {
        let fresh = DownloadNotificationPreferences()
        XCTAssertFalse(fresh.enabled)
        var p = fresh; p.enabled = true; p.sounds = true; p.delivery = .both; p.queueCompleted = true
        XCTAssertEqual(DownloadNotificationPreferences.decode(p.encoded()), p)
        XCTAssertNil(DownloadNotificationPreferences.decode("{broken"))
    }

    func testTheOldNotifierThatAskedPermissionAtCompletionIsGone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var asks = 0
        let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Shared"), includingPropertiesForKeys: nil)!
        for case let url as URL in walker where url.pathExtension == "swift" {
            asks += (try String(contentsOf: url, encoding: .utf8)).components(separatedBy: "requestAuthorization(").count - 1
        }
        XCTAssertEqual(asks, 1, "the only place the system is asked is SystemNotificationCenter.requestPermission")
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("Shared/BrowserModel.swift"), encoding: .utf8).contains("DownloadNotifier.finished"))
    }
}

// MARK: - 9–11. Diagnostics

@MainActor
final class DiagnosticsTests: P14Case {
    private func started(_ c: DownloadCoordinator, _ name: String = "a.bin", url: String = "https://files.example.org/a.bin", isPrivate: Bool = false) -> UUID {
        c.begin(suggestedName: name, sourceURL: URL(string: url), isPrivate: isPrivate, cancel: {}).id
    }
    private func ev(_ type: String, _ id: UUID, _ c: DownloadCoordinator, state: String? = nil, n: Int = 1) -> AutomationEvent {
        .init(id: n, epoch: "abcd1234", type: type, taskID: id.uuidString, state: state, fraction: nil, bytesReceived: 5, sourceHost: "files.example.org", profile: c.profileName, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)))
    }

    func testTheTimelineIsInOrderAndNamesTheEngineAndTheError() throws {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil)
        let id = started(c)
        d.record(ev("task.created", id, c, n: 1), coordinator: c)
        d.record(ev("task.started", id, c, n: 2), coordinator: c)
        d.record(ev("task.paused", id, c, n: 3), coordinator: c)
        d.record(ev("task.resumed", id, c, n: 4), coordinator: c)
        c.fail(id, source: nil, error: URLError(.timedOut), willRetry: false)
        d.record(ev("task.failed", id, c, n: 5), coordinator: c)
        let t = d.timeline(for: id)
        XCTAssertEqual(t.map(\.category), ["created", "engine_selected", "transfer_started", "paused", "resumed", "failed"])
        XCTAssertEqual(t.map(\.at), t.map(\.at).sorted())
        XCTAssertEqual(t.last?.errorCategory, "timeout"); XCTAssertEqual(t.first?.host, "files.example.org"); XCTAssertEqual(t.first?.engine, "webkit")
    }

    func testProgressIsNotRecordedAndVerificationIsNamed() {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil); let id = started(c)
        for n in 0..<50 { d.record(ev("task.progress", id, c, n: n), coordinator: c) }
        d.record(ev("task.updated", id, c, state: "verifying", n: 60), coordinator: c)
        XCTAssertEqual(d.timeline(for: id).map(\.category), ["verification_started"])
    }

    func testRetentionIsBounded() {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil); let id = started(c)
        for n in 0..<200 { d.record(ev("task.paused", id, c, n: n), coordinator: c) }
        XCTAssertEqual(d.timeline(for: id).count, DownloadDiagnostics.maxEntries)
        XCTAssertEqual(d.timeline(for: id).last?.at, Date(timeIntervalSince1970: 1_800_000_199), "the newest are kept")
        for i in 0..<(DownloadDiagnostics.maxTasks + 30) { d.record(ev("task.paused", started(c, "f\(i).bin", url: "https://a.org/f\(i)"), c, n: i), coordinator: c) }
        XCTAssertLessThanOrEqual(d.taskCount, DownloadDiagnostics.maxTasks)
    }

    func testAPrivateDownloadLeavesNothingAndIsNeverExported() throws {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: scratch.appendingPathComponent("t.json"))
        let p = started(c, "secret.bin", url: "https://private.example.org/secret.bin", isPrivate: true)
        d.record(ev("task.created", p, c), coordinator: c)
        XCTAssertTrue(d.timeline(for: p).isEmpty)
        let report = d.report(for: [p], coordinator: c, appVersion: "1")
        XCTAssertTrue(report.tasks.isEmpty)
        d.saveNow()
        XCTAssertFalse(((try? String(contentsOf: scratch.appendingPathComponent("t.json"), encoding: .utf8)) ?? "").contains("private.example.org"))
    }

    func testSecretsNeverReachTheTimelineTheReportOrTheText() throws {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil)
        let id = started(c, "doc.pdf", url: "https://user:hunter2@files.example.org/dl/aaaaaaaaaaaaaaaaaaaaaaaaaaaa1111/doc.pdf?sig=SECRETSIG&X-Amz-Signature=AMZSECRET&token=TOK123#frag")
        c.fail(id, source: nil, error: HTTPDownloadError(info: DownloadFailureInfo(code: "http:503", reason: "Failed: Authorization: Bearer abcdef1234567890SECRET Cookie: session=COOKIESECRET https://x.org/p?api_key=APIKEY9 bsat_12345678_\(String(repeating: "a", count: 64))", retryable: true)), willRetry: false)
        d.record(ev("task.failed", id, c), coordinator: c)
        let report = d.report(for: [id], coordinator: c, appVersion: "9.9")
        let json = DownloadDiagnostics.json(report), text = DownloadDiagnostics.text(report)
        for secret in ["hunter2", "SECRETSIG", "AMZSECRET", "TOK123", "frag", "SECRET", "COOKIESECRET", "APIKEY9", "bsat_", "aaaaaaaaaaaaaaaaaaaaaaaaaaaa1111", "sig="] {
            XCTAssertFalse(json.contains(secret), "json: \(secret)"); XCTAssertFalse(text.contains(secret), "text: \(secret)")
        }
        XCTAssertTrue(json.contains("files.example.org")); XCTAssertEqual(report.schema, DiagnosticReport.currentSchema)
        XCTAssertEqual(report.tasks.first?.errorCategory, "serverUnavailable")
    }

    func testRedactorRules() {
        XCTAssertEqual(DiagnosticRedactor.url("https://u:p@h.org/a/b?x=1#f"), "https://h.org/a/b")
        XCTAssertNil(DiagnosticRedactor.url("not a url"))
        XCTAssertEqual(DiagnosticRedactor.filename("/Users/me/Secret Folder/report.pdf"), "report.pdf")
        let t = DiagnosticRedactor.text("GET https://h.org/f?sig=ZZZ failed; set-cookie: a=b; password=hunter2")!
        XCTAssertFalse(t.contains("ZZZ")); XCTAssertFalse(t.contains("hunter2")); XCTAssertFalse(t.contains("a=b"))
        XCTAssertLessThanOrEqual(DiagnosticRedactor.text(String(repeating: "x ", count: 1000), limit: 50)!.count, 51)
    }

    func testTheExportFitsItsLimitAndSaysWhenItWasShortened() throws {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil)
        var ids: [UUID] = []
        for i in 0..<60 {
            let id = started(c, "f\(i).bin", url: "https://files.example.org/f\(i).bin"); ids.append(id)
            for n in 0..<DownloadDiagnostics.maxEntries { d.record(ev("task.paused", id, c, n: n), coordinator: c) }
        }
        let big = d.report(for: ids, coordinator: c, appVersion: "1", maxBytes: 20_000)
        XCTAssertLessThanOrEqual(try AutomationJSON.encoder.encode(big).count, 20_000); XCTAssertTrue(big.truncated)
        let roomy = d.report(for: Array(ids.prefix(1)), coordinator: c, appVersion: "1")
        XCTAssertFalse(roomy.truncated); XCTAssertEqual(roomy.tasks.first?.timeline.count, DownloadDiagnostics.maxEntries)
        XCTAssertTrue(DownloadDiagnostics.text(big).contains("Shortened"))
    }

    func testAStorageFailureIsReportedAndNeverHurtsTheDownload() {
        let flaky = Flaky(); flaky.failing = true
        let c = DownloadCoordinator()
        let d = DownloadDiagnostics(file: scratch.appendingPathComponent("t.json"), writer: flaky.write)
        let id = started(c)
        d.record(ev("task.created", id, c), coordinator: c)
        XCTAssertFalse(d.saveNow()); XCTAssertNotNil(d.storageProblem)
        XCTAssertEqual(d.timeline(for: id).count, 2, "the timeline is still there in memory")
        flaky.failing = false
        XCTAssertTrue(d.saveNow()); XCTAssertNil(d.storageProblem)
        let again = DownloadDiagnostics(file: scratch.appendingPathComponent("t.json"))
        XCTAssertEqual(again.timeline(for: id).count, 2, "and it comes back after a restart")
    }

    func testRetryScheduledCarriesTheAttemptNumber() {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil); let id = started(c)
        c.ledger.update(id) { $0.retryCount = 2 }
        d.record(ev("task.retry_scheduled", id, c), coordinator: c)
        XCTAssertEqual(d.timeline(for: id).last?.retryAttempt, 2)
    }

    func testFailureClassification() {
        let cases: [(String, String?, DownloadFailureCategory, Bool, Bool)] = [
            ("NSURLErrorDomain:-1009", nil, .networkUnavailable, true, false), ("NSURLErrorDomain:-1001", nil, .timeout, true, false),
            ("http:401", nil, .authenticationRequired, false, true), ("http:403", nil, .serverRefused, false, true), ("http:404", nil, .serverRefused, false, true),
            ("http:503", nil, .serverUnavailable, true, false), ("http:416", nil, .fileChanged, true, false), ("http:checksum", nil, .integrityMismatch, false, true),
            ("http:wrong-size", nil, .integrityMismatch, false, true), ("policy:untrustedRequestsDisabled", nil, .policyRefused, false, true),
            ("NSCocoaErrorDomain:640", nil, .diskFull, false, true), ("NSCocoaErrorDomain:513", nil, .permissionDenied, false, true), ("session", nil, .sessionUnavailable, false, true),
            ("retry-not-scheduled", nil, .admissionFailure, true, false), ("weird", "The proxy refused", .proxyFailure, false, true), ("???", nil, .unknown, false, false), ("NSURLErrorDomain:-1100", nil, .serverRefused, false, true), ("NSURLErrorDomain:-1200", nil, .secureConnectionFailed, false, true), ("NSCocoaErrorDomain:4097", nil, .unknown, false, false),
        ]
        for (code, reason, cat, retry, user) in cases {
            let got = DownloadFailureCategory.classify(code: code, reason: reason)
            XCTAssertEqual(got, cat, code); XCTAssertEqual(got.retryable, retry, code); XCTAssertEqual(got.needsUser, user, code)
            XCTAssertFalse(got.advice.contains("http"), "advice carries no address")
        }
        XCTAssertTrue(DownloadFailureCategory.allCases.allSatisfy { !$0.title.isEmpty && !$0.advice.isEmpty })
    }
}

// MARK: - 12. Indicators

@MainActor
final class IndicatorTests: XCTestCase {
    private func a(_ done: Int64, _ total: Int64) -> ActiveDownload { ActiveDownload(id: UUID(), filename: "x", fraction: total > 0 ? Double(done) / Double(total) : 0, completedBytes: done, totalBytes: total) }

    func testAggregateProgressUsesBytesAndIsHiddenWhenASizeIsUnknown() {
        let known = DownloadIndicators.make(active: [a(50, 100), a(150, 300)], queued: 0, failed: 0, needsAttention: 0)
        XCTAssertEqual(known.aggregateProgress ?? 0, 200.0 / 400.0, accuracy: 0.0001); XCTAssertEqual(known.badge, "50%")
        let unknown = DownloadIndicators.make(active: [a(50, 100), a(10, 0)], queued: 0, failed: 0, needsAttention: 0)
        XCTAssertNil(unknown.aggregateProgress, "an average with an unknown size would be invented"); XCTAssertEqual(unknown.badge, "2")
    }

    func testBadgesForFailureQueueAndNothing() {
        XCTAssertEqual(DownloadIndicators.make(active: [], queued: 0, failed: 1, needsAttention: 0).badge, "!")
        XCTAssertEqual(DownloadIndicators.make(active: [], queued: 0, failed: 0, needsAttention: 2).badge, "!")
        XCTAssertEqual(DownloadIndicators.make(active: [], queued: 3, failed: 0, needsAttention: 0).badge, "3")
        XCTAssertNil(DownloadIndicators.make(active: [], queued: 0, failed: 0, needsAttention: 0).badge)
        XCTAssertEqual(DownloadIndicators.make(active: [a(1, 2)], queued: 1, failed: 1, needsAttention: 1).summary, "1 downloading, 1 waiting, 1 failed, 1 need attention")
        XCTAssertEqual(DownloadIndicators.make(active: [], queued: 0, failed: 0, needsAttention: 0).summary, "No downloads")
    }

    func testTheCoordinatorProjectionCountsOnlyNonPrivateWork() {
        let c = DownloadCoordinator()
        let s = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        c.fail(s.id, source: URL(string: "https://a.org/a"), error: URLError(.badServerResponse), willRetry: false)
        _ = c.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {})
        let snap = DownloadIndicators.make(c)
        XCTAssertEqual(snap.failed, 1)
        XCTAssertEqual(snap.active, 0, "a private download running is not on the Dock icon or the toolbar")
        XCTAssertEqual(snap.queued, 0)
    }

    func testTheDockUsesTheSameCalculation() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macOS/MacRootView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("DownloadIndicators.make(model.downloads).badge"))
        XCTAssertFalse(text.contains("average * 100"), "the old average over unknown sizes is gone")
    }
}


// MARK: - Fixes from the independent review

@MainActor
final class Phase14ReviewFixTests: P14Case {
    private func snap(_ id: UUID, _ state: DownloadState, profile: String = "p") -> AutomationEventHub.Snapshot { .init(id: id, state: state, fraction: nil, bytes: 0, host: "h.org", profile: profile) }

    func testASecondRevokeAfterAFailedSaveStillSaysItIsNotSaved() {
        let f = Flaky(); let file = scratch.appendingPathComponent("c.json")
        let s = AutomationClientStore(file: file, writer: f.write, denyStores: [DenyFake(failWrite: true)])
        guard case .created(let c, _) = s.enrol(name: "t", profile: "default", scopes: [.downloadsRead]) else { return XCTFail() }
        f.failing = true
        guard case .restrictedButNotSaved = s.revoke(c.id) else { return XCTFail() }
        guard case .restrictedButNotSaved = s.revoke(c.id) else { return XCTFail("a second click must not turn it into a false success") }
        f.failing = false
        XCTAssertEqual(s.revoke(c.id), .committed)
        XCTAssertNotNil(AutomationClientStore(file: file).clients.first { $0.id == c.id }?.revokedAt, "and now it is on disk")
    }

    func testEachStartIsReportedOnceAndAResumeIsAResume() {
        let h = AutomationEventHub(); var types: [String] = []
        let a = UUID()
        h.ingest([snap(a, .queued)], now: 0)
        for state in [DownloadState.starting, .running] { h.ingest([snap(a, state)], now: 1) { types.append($0.type) } }
        h.ingest([snap(a, .paused)], now: 2) { types.append($0.type) }
        h.ingest([snap(a, .resuming)], now: 3) { _ in }
        h.ingest([snap(a, .running)], now: 4) { types.append($0.type) }
        XCTAssertEqual(types, ["task.started", "task.paused", "task.resumed"])
    }

    func testTheQueueIsNotFinishedWhenTheLastDownloadIsOnlyPausedOrCancelled() {
        let h = AutomationEventHub(); var types: [String] = []
        let a = UUID(), b = UUID()
        h.ingest([snap(a, .running), snap(b, .running)], now: 0)
        h.ingest([snap(a, .completed), snap(b, .running)], now: 1) { types.append($0.type) }
        h.ingest([snap(a, .completed), snap(b, .paused)], now: 2) { types.append($0.type) }
        XCTAssertFalse(types.contains("queue.completed"), "paused work is not finished work")
        let c = UUID(), d = UUID()
        let h2 = AutomationEventHub(); var t2: [String] = []
        h2.ingest([snap(c, .running), snap(d, .running)], now: 0)
        h2.ingest([snap(c, .completed), snap(d, .running)], now: 1) { t2.append($0.type) }
        h2.ingest([snap(c, .completed), snap(d, .cancelled)], now: 2) { t2.append($0.type) }
        XCTAssertFalse(t2.contains("queue.completed"), "a cancellation is not the queue finishing")
        let e = UUID(), g = UUID()
        let h3 = AutomationEventHub(); var t3: [String] = []
        h3.ingest([snap(e, .running), snap(g, .running)], now: 0)
        h3.ingest([snap(e, .completed), snap(g, .completed)], now: 1) { t3.append($0.type) }
        XCTAssertEqual(t3.filter { $0 == "queue.completed" }.count, 1)
    }

    func testAnEpochChangeMidRunDropsOldHistoryAndTellsConnectedClients() async {
        var allow = true
        let seq = AutomationEventSequence(file: scratch.appendingPathComponent("s.json"), block: 2, writer: { d, u in if !allow { throw Flaky.Refused() }; try d.write(to: u) })
        let h = AutomationEventHub(sequence: seq); h.ingest([], now: 0)
        let sub = h.subscribe(clientID: "x", profile: "p", lastEventID: nil)!
        let before = seq.epoch
        h.ingest([snap(UUID(), .queued)], now: 1)
        _ = await sub.next()
        allow = false                                              // the disk stops accepting the reservation
        for _ in 0..<6 { h.ingest([snap(UUID(), .queued)], now: 2); h.ingest([], now: 3) }
        XCTAssertNotEqual(seq.epoch, before)
        var sawGap = false
        while sub.pending > 0, let e = await sub.next() { if e.type == "stream.gap" && e.note == "restarted" { sawGap = true } }
        XCTAssertTrue(sawGap, "a connected client is told the sequence restarted")
        let late = h.subscribe(clientID: "y", profile: "p", lastEventID: "\(before)-1")!
        let first = await late.next()
        XCTAssertEqual(first?.note, "restarted", "an old-epoch position is never replayed as if it were new")
    }

    func testMoreSecretShapesAreRemoved() {
        let samples = ["refresh_token=RT123456", "id_token: IDTOK123456", "client_secret=CS123456", "token=LEAD123456", "{\"token\":\"JSON123456\"}", "x-api-key: APIK123456",
                       "AKIAABCDEFGHIJKLMNOP", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig", "GET http://h.org/a b|c?token=URLTOK123 failed", "jsessionid=JS123456",
                       "cannot read /Users/jane.doe/Documents/secret.txt"]
        for sample in samples {
            let out = DiagnosticRedactor.text(sample)!
            for needle in ["RT123456", "IDTOK123456", "CS123456", "LEAD123456", "JSON123456", "APIK123456", "AKIAABCDEFGHIJKLMNOP", "eyJhbGci", "URLTOK123", "JS123456", "jane.doe"] {
                XCTAssertFalse(out.contains(needle), "\(sample) -> \(out)")
            }
        }
        XCTAssertEqual(DiagnosticRedactor.host("user:pass@files.example.org"), "files.example.org")
        XCTAssertLessThanOrEqual(DiagnosticRedactor.text(String(repeating: "http://a:b", count: 20_000))!.count, 4004, "long input is cut before the patterns run")
    }

    func testAFailureAfterARetryIsToldAgainAndADeniedPermissionDoesNotUseUpTheNotice() async throws {
        let center = FakeCenter(); let c = DownloadCoordinator()
        let svc = DownloadNotificationService(center: center, coordinators: { [c] in [c] }, downloadsVisible: { false }, appActive: { false }, openDownloads: { _ in }, reveal: { _ in })
        svc.preferences.enabled = true
        let source = URL(string: "https://files.example.org/f.bin")!
        let s = c.begin(suggestedName: "f.bin", sourceURL: source, cancel: {})
        c.fail(s.id, source: source, error: URLError(.badServerResponse), willRetry: false)
        func ev(_ n: Int) -> AutomationEvent { .init(id: n, epoch: "abcd1234", type: "task.failed", taskID: s.id.uuidString, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: c.profileName, at: Date()) }
        center.status = .denied
        await svc.handle(ev(1), coordinator: c)
        center.status = .allowed
        await svc.handle(ev(1), coordinator: c)
        XCTAssertEqual(center.delivered.count, 1, "the notice was not used up while permission was denied")
        await svc.handle(ev(1), coordinator: c)
        XCTAssertEqual(center.delivered.count, 1, "the same event is never told twice")
        await svc.handle(ev(2), coordinator: c)
        XCTAssertEqual(center.delivered.count, 2, "a second failure is a new event")
    }

    func testProgressAndStartedNeverNotifyEvenForARealTask() async throws {
        let center = FakeCenter(); let c = DownloadCoordinator()
        let svc = DownloadNotificationService(center: center, coordinators: { [c] in [c] }, downloadsVisible: { false }, appActive: { false }, openDownloads: { _ in }, reveal: { _ in })
        svc.preferences.enabled = true
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r"), cancel: {})
        for type in ["task.progress", "task.started", "task.paused", "task.resumed", "task.created", "task.updated", "task.cancelled", "task.retry_scheduled"] {
            await svc.handle(.init(id: 1, epoch: "abcd1234", type: type, taskID: s.id.uuidString, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: c.profileName, at: Date()), coordinator: c)
        }
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testTimelinesOfRemovedDownloadsArePruned() {
        let c = DownloadCoordinator(); let d = DownloadDiagnostics(file: nil)
        let keep = c.begin(suggestedName: "k.bin", sourceURL: URL(string: "https://a.org/k"), cancel: {}).id
        let gone = c.begin(suggestedName: "g.bin", sourceURL: URL(string: "https://a.org/g"), cancel: {}).id
        for id in [keep, gone] { d.record(.init(id: 1, epoch: "abcd1234", type: "task.created", taskID: id.uuidString, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: c.profileName, at: Date()), coordinator: c) }
        c.ledger.remove(gone)
        d.prune(keeping: c)
        XCTAssertFalse(d.timeline(for: keep).isEmpty); XCTAssertTrue(d.timeline(for: gone).isEmpty)
    }
}
