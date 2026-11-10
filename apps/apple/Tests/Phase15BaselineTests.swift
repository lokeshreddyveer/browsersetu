import XCTest
@testable import Browser_Setu

// Phase 15: baseline integration. Authorization that survives restarts, replacement that cannot lose both versions, and cross-component behaviour with real coordinators.
// The real Keychain and the real notification centre are never touched.

final class DenyFake: AuthorizationDenyStore {
    var records: [String: DenyRecord] = [:]
    var failWrite: Bool
    var failRead = false
    var writes = 0
    init(failWrite: Bool = false) { self.failWrite = failWrite }
    struct Refused: Error {}
    func read() throws -> [String: DenyRecord] { if failRead { throw Refused() }; return records }
    func write(_ r: [String: DenyRecord]) throws { writes += 1; if failWrite { throw Refused() }; records = r }
    var setAsideCalls = 0
    func setAside() throws { setAsideCalls += 1; records = [:]; failRead = false }
}

private final class PrimaryDisk: @unchecked Sendable {
    var failing = false
    var writes = 0
    struct Refused: Error {}
    func write(_ data: Data, _ url: URL) throws { writes += 1; if failing { throw Refused() }; try data.write(to: url, options: .atomic) }
}

@MainActor
class P15Case: XCTestCase {
    var scratch: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p15-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }
}

// MARK: - P0: a revoked credential never comes back

@MainActor
final class AuthorizationDurabilityTests: P15Case {
    private let scopes: Set<AutomationScope> = [.downloadsRead, .downloadsControl]

    private func rig(_ disk: PrimaryDisk, _ deny: [AuthorizationDenyStore]) -> (AutomationClientStore, URL) {
        let file = scratch.appendingPathComponent("clients.json")
        return (AutomationClientStore(file: file, writer: disk.write, denyStores: deny), file)
    }
    private func enrol(_ s: AutomationClientStore, _ scopes: Set<AutomationScope>? = nil) -> (AutomationClient, String) {
        guard case .created(let c, let t) = s.enrol(name: "tool", profile: "default", scopes: scopes ?? self.scopes) else { fatalError() }
        return (c, t)
    }

    func testARevocationSurvivesARestartEvenWhenTheClientListCannotBeSaved() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, file) = rig(disk, [deny]); let (c, t) = enrol(s)
        disk.failing = true
        XCTAssertEqual(s.revoke(c.id), .committed, "a durable record of the withdrawal exists")
        // The list on disk is the old one, which still holds the client as active: exactly the stale file a failed write leaves behind.
        let restarted = AutomationClientStore(file: file, denyStores: [deny])
        XCTAssertEqual(restarted.authenticate(t), .failed, "the stale list cannot override what was withdrawn")
        XCTAssertNotNil(restarted.clients.first { $0.id == c.id }?.revokedAt)
    }

    func testTheSameWithRealFilesAndAStaleCopyOfTheList() throws {
        let file = scratch.appendingPathComponent("clients.json")
        let s = AutomationClientStore(file: file)                                   // real clients.json and real denied.json
        let (c, t) = enrol(s)
        let stale = try Data(contentsOf: file)                                     // what the list looked like before
        XCTAssertEqual(s.revoke(c.id), .committed)
        try stale.write(to: file)                                                   // a crash, a failed write, a restored backup: the old list is back
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("denied.json").path))
        XCTAssertEqual(AutomationClientStore(file: file).authenticate(t), .failed)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: scratch.appendingPathComponent("denied.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWhenNothingDurableCanBeWrittenTheWholeServiceLocksDown() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, file) = rig(disk, [deny]); let (c, tRevoked) = enrol(s); let (_, tOther) = enrol(s)
        disk.failing = true; deny.failWrite = true
        guard case .restrictedButNotSaved = s.revoke(c.id) else { return XCTFail("must not claim it is saved") }
        XCTAssertTrue(s.isLockedDown)
        XCTAssertEqual(s.authenticate(tRevoked), .failed); XCTAssertEqual(s.authenticate(tOther), .failed, "everyone is refused rather than risk an old credential returning")
        disk.failing = false; deny.failWrite = false
        XCTAssertTrue(s.flush()); XCTAssertFalse(s.isLockedDown)
        XCTAssertNotEqual(s.authenticate(tOther), .failed, "service resumes once the withdrawal is safely recorded")
        XCTAssertEqual(s.authenticate(tRevoked), .failed)
        XCTAssertEqual(AutomationClientStore(file: file, denyStores: [deny]).authenticate(tRevoked), .failed)
    }

    func testLockdownLiftsItselfWhenTheStorageComesBack() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = scratch.appendingPathComponent("clients.json")
        let s = AutomationClientStore(file: file, now: { now }, writer: disk.write, denyStores: [deny])
        let (c, _) = enrol(s); let (_, other) = enrol(s)
        disk.failing = true; deny.failWrite = true
        _ = s.revoke(c.id); XCTAssertTrue(s.isLockedDown)
        disk.failing = false; deny.failWrite = false; now = now.addingTimeInterval(6)
        XCTAssertNotEqual(s.authenticate(other), .failed, "the retry on use brought it back")
        XCTAssertFalse(s.isLockedDown)
    }

    func testAScopeReductionIsCappedForever() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, file) = rig(disk, [deny]); let (c, t) = enrol(s)
        disk.failing = true
        XCTAssertEqual(s.setScopes(c.id, [.downloadsRead]), .committed)
        let restarted = AutomationClientStore(file: file, denyStores: [deny])
        guard case .ok(let again) = restarted.authenticate(t) else { return XCTFail() }
        XCTAssertEqual(again.scopes, [.downloadsRead], "the old, wider list does not restore the permission")
    }

    func testWideningNeedsBothTheCapToLiftAndTheListToBeSaved() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, _) = rig(disk, [deny]); let (c, _) = enrol(s)
        XCTAssertEqual(s.setScopes(c.id, [.downloadsRead]), .committed)
        deny.failWrite = true
        guard case .refused = s.setScopes(c.id, [.downloadsRead, .downloadsControl]) else { return XCTFail() }
        XCTAssertEqual(s.clients[0].scopes, [.downloadsRead])
        deny.failWrite = false; disk.failing = true
        guard case .refused = s.setScopes(c.id, [.downloadsRead, .downloadsControl]) else { return XCTFail() }
        XCTAssertEqual(s.clients[0].scopes, [.downloadsRead]); XCTAssertEqual(deny.records[c.id]?.scopeCap, [.downloadsRead], "the cap was put back when the list could not be saved")
        disk.failing = false
        XCTAssertEqual(s.setScopes(c.id, [.downloadsRead, .downloadsControl]), .committed)
    }

    func testAnUnreadableDenyRecordClosesEverything() {
        let deny = DenyFake(); let disk = PrimaryDisk()
        let (s, file) = rig(disk, [deny]); let (_, t) = enrol(s)
        deny.failRead = true
        let restarted = AutomationClientStore(file: file, denyStores: [deny])
        XCTAssertFalse(restarted.isReadable); XCTAssertEqual(restarted.authenticate(t), .failed)
        guard case .refused = restarted.enrol(name: "x", profile: "default", scopes: [.downloadsRead]) else { return XCTFail() }
        // A garbage file does the same.
        try? Data("{ nope".utf8).write(to: scratch.appendingPathComponent("denied.json"))
        let viaFile = AutomationClientStore(file: file)
        XCTAssertFalse(viaFile.isReadable); XCTAssertEqual(viaFile.authenticate(t), .failed)
    }

    func testEitherStoreAloneIsEnough() {
        let disk = PrimaryDisk(); let good = DenyFake(), bad = DenyFake(failWrite: true)
        let (s, file) = rig(disk, [bad, good]); let (c, t) = enrol(s)
        XCTAssertEqual(s.revoke(c.id), .committed)
        XCTAssertEqual(AutomationClientStore(file: file, denyStores: [bad, good]).authenticate(t), .failed)
        XCTAssertEqual(AutomationClientStore(file: file, denyStores: [good]).authenticate(t), .failed)
    }

    func testRotationKeepsTheOldSecretDeadAcrossARestart() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, file) = rig(disk, [deny]); let (c, old) = enrol(s)
        let fresh = s.rotate(c.id).token!
        let r = AutomationClientStore(file: file, denyStores: [deny])
        XCTAssertEqual(r.authenticate(old), .failed); XCTAssertNotEqual(r.authenticate(fresh), .failed)
        disk.failing = true
        let failed = s.rotate(c.id)
        XCTAssertNil(failed.token); XCTAssertNotEqual(s.authenticate(fresh), .failed, "a rotation that cannot be saved changes nothing")
    }

    func testUsingATokenNeverWritesToDisk() {
        let disk = PrimaryDisk(); let (s, _) = rig(disk, [DenyFake()]); let (c, t) = enrol(s)
        let before = disk.writes
        for _ in 0..<5 { _ = s.authenticate(t); s.touch(c.id) }
        XCTAssertEqual(disk.writes, before, "touch is memory only: it cannot persist a half-saved list")
    }

    func testRemovalThatIsOnlyPartiallySavedStillKeepsTheClientOut() {
        let disk = PrimaryDisk(); let deny = DenyFake()
        let (s, file) = rig(disk, [deny]); let (c, t) = enrol(s)
        disk.failing = true
        XCTAssertEqual(s.remove(c.id), .committed)
        XCTAssertEqual(AutomationClientStore(file: file, denyStores: [deny]).authenticate(t), .failed)
    }

    func testTheProductionWiringAddsTheKeychainOnlyOutsideTests() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Automation/AutomationController.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("KeychainBackedDenyStore") && text.contains("XCTestConfigurationFilePath"))
    }
}

// MARK: - P1: replacement never loses both versions

@MainActor
final class ReplacementDurabilityTests: P15Case {
    func testTheIntentToReplaceIsInTheLedgerAndTheStagingSurvivesARelaunch() throws {
        let folder = scratch.appendingPathComponent("ledger")
        let old = scratch.appendingPathComponent("r.bin"); try Data([7]).write(to: old)
        let first = DownloadCoordinator(); first.duplicatePolicy = .replace; first.store = folder
        let s = first.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r"), cancel: {})
        try Data([1, 2]).write(to: s.destination)
        first.interrupt(s.id, resumeData: Data([9]), source: URL(string: "https://a.org/r"))
        let second = DownloadCoordinator(); second.store = folder                    // the app was quit and opened again
        XCTAssertEqual(second.ledger.record(s.id)?.engineMetadata[DownloadCoordinator.saveAsReplaceKey], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.destination.path), "the new file's staging is not swept: its task is still alive")
        XCTAssertEqual(try Data(contentsOf: old), Data([7]), "the old file is exactly as it was")
    }

    func testEveryWayAReplacementCanEndLeavesAFileAtTheName() throws {
        for outcome in ["fail", "cancel", "mismatch", "finish"] {
            let c = DownloadCoordinator(); c.duplicatePolicy = .replace
            let old = scratch.appendingPathComponent("\(outcome).bin"); try Data([7, 7, 7]).write(to: old)
            let s = c.begin(suggestedName: "\(outcome).bin", sourceURL: URL(string: "https://a.org/\(outcome)"), cancel: {})
            try Data([1]).write(to: s.destination)
            switch outcome {
            case "fail": c.fail(s.id, source: nil, error: URLError(.networkConnectionLost), willRetry: false)
            case "cancel": c.cancel(s.id)
            case "mismatch": c.ledger.update(s.id) { $0.transfer.totalBytes = 99 }; c.finish(s.id, source: nil)
            default: c.finish(s.id, source: nil)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), outcome)
            let content = try Data(contentsOf: old)
            XCTAssertEqual(content, outcome == "finish" ? Data([1]) : Data([7, 7, 7]), outcome)
            if outcome == "mismatch" { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(c.completed.first)), Data([1]), "the new, mismatching file is kept beside it") }
        }
    }

    func testTwoCoordinatorsReplacingTheSameNameNeverLoseOneAnother() throws {
        // Two profiles (two coordinators) both told to replace the same file in a shared folder.
        let old = scratch.appendingPathComponent("shared.bin"); try Data([7]).write(to: old)
        let a = DownloadCoordinator(), b = DownloadCoordinator(); a.duplicatePolicy = .replace; b.duplicatePolicy = .replace
        let sa = a.begin(suggestedName: "shared.bin", sourceURL: URL(string: "https://a.org/1"), cancel: {})
        let sb = b.begin(suggestedName: "shared.bin", sourceURL: URL(string: "https://a.org/2"), cancel: {})
        try Data([1]).write(to: sa.destination); try Data([2]).write(to: sb.destination)
        a.finish(sa.id, source: nil); b.finish(sb.id, source: nil)
        let all = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { !$0.hasPrefix(".") && $0.hasSuffix(".bin") }.map { try Data(contentsOf: scratch.appendingPathComponent($0)) }
        XCTAssertTrue(all.contains(Data([1]))); XCTAssertTrue(all.contains(Data([2])), "neither download was lost")
    }
}

// MARK: - P1: the feed follows coordinators that come and go

@MainActor
final class FeedLifecycleTests: P15Case {
    func testACoordinatorThatAppearsLaterIsWatched() {
        var list: [DownloadCoordinator] = []
        let a = DownloadCoordinator(); a.profileName = "alpha"; list = [a]
        let feed = DownloadEventFeed(coordinators: { list })
        var created: [String] = []; feed.observe { e, _ in if e.type == "task.created" { created.append(e.profile) } }
        feed.start()
        let b = DownloadCoordinator(); b.profileName = "beta"; list.append(b)
        XCTAssertTrue(feed.syncCoordinators())
        feed.publishChanges()
        _ = b.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        feed.publishChanges()
        XCTAssertEqual(created, ["beta"])
    }

    func testAReplacedCoordinatorIsLetGoAndItsTasksNoLongerSpeak() {
        let old = DownloadCoordinator(); old.profileName = "p"
        var list = [old]
        let feed = DownloadEventFeed(coordinators: { list })
        var created = 0; feed.observe { e, _ in if e.type == "task.created" { created += 1 } }
        feed.start()
        let new = DownloadCoordinator(); new.profileName = "p"; list = [new]
        XCTAssertTrue(feed.syncCoordinators())
        _ = old.begin(suggestedName: "old.bin", sourceURL: URL(string: "https://a.org/o"), cancel: {})
        feed.publishChanges()
        XCTAssertEqual(created, 0, "work on a coordinator that is gone is not announced")
        _ = new.begin(suggestedName: "new.bin", sourceURL: URL(string: "https://a.org/n"), cancel: {})
        feed.publishChanges()
        XCTAssertEqual(created, 1)
    }

    func testStoppingReleasesEverything() {
        let c = DownloadCoordinator()
        let feed = DownloadEventFeed(coordinators: { [c] })
        let id = feed.observe { _, _ in }
        feed.start(); feed.stop()
        XCTAssertFalse(feed.isRunning); XCTAssertFalse(feed.syncCoordinators(), "nothing is resubscribed while stopped")
        feed.unobserve(id); XCTAssertEqual(feed.observerCount, 0)
    }

    func testANotificationServiceSpeaksOnlyForItsOwnProfiles() async {
        let a = DownloadCoordinator(); a.profileName = "alpha"; let b = DownloadCoordinator(); b.profileName = "beta"
        let center = FakeCenter()
        let svc = DownloadNotificationService(center: center, coordinators: { [a] in [a] }, downloadsVisible: { false }, appActive: { false }, openDownloads: { _ in }, reveal: { _ in })
        svc.preferences.enabled = true
        let sb = b.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        try? Data([1]).write(to: sb.destination); b.finish(sb.id, source: nil)
        await svc.handle(.init(id: 1, epoch: "abcd1234", type: "task.completed", taskID: sb.id.uuidString, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: "beta", at: Date()), coordinator: b)
        XCTAssertTrue(center.delivered.isEmpty)
    }
}

// MARK: - Cross-component: one completed download through every consumer

@MainActor
final class CrossComponentTests: P15Case {
    func testOneDownloadReachesEventsNotificationsDiagnosticsAndTheDockExactlyOnce() async throws {
        let c = DownloadCoordinator()
        let feed = DownloadEventFeed(coordinators: { [c] })
        let center = FakeCenter()
        let notes = DownloadNotificationService(center: center, coordinators: { [c] in [c] }, downloadsVisible: { false }, appActive: { false }, openDownloads: { _ in }, reveal: { _ in })
        notes.preferences.enabled = true; notes.attach(to: feed)
        let diag = DownloadDiagnostics(file: nil); feed.observe { e, coord in diag.record(e, coordinator: coord) }
        let store = AutomationClientStore(file: nil)
        guard case .created(_, let token) = store.enrol(name: "t", profile: c.profileName, scopes: [.downloadsRead]) else { return XCTFail() }
        let service = AutomationService(clients: store, coordinators: { [c] in [c] }, feed: feed); service.start()
        guard case .stream(let sub) = await service.handle(AutomationRequest(method: "GET", target: "/v1/events", headers: ["authorization": "Bearer \(token)"], body: Data())) else { return XCTFail() }

        feed.publishChanges()
        let s = c.begin(suggestedName: "all.bin", sourceURL: URL(string: "https://files.example.org/all.bin?sig=SECRET"), cancel: {})
        feed.publishChanges()
        XCTAssertEqual(DownloadIndicators.make(c).active, 1)
        try Data([1]).write(to: s.destination); c.finish(s.id, source: nil)
        feed.publishChanges(); feed.publishChanges()
        for _ in 0..<100 where center.delivered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        var types: [String] = []
        while sub.pending > 0, let e = await sub.next() { types.append(e.type) }
        XCTAssertEqual(types.filter { $0 == "task.completed" }.count, 1)
        XCTAssertEqual(center.delivered.map(\.title), ["Download finished"])
        XCTAssertEqual(diag.timeline(for: s.id).filter { $0.category == "completed" }.count, 1)
        XCTAssertEqual(DownloadIndicators.make(c).active, 0)
        let text = DownloadDiagnostics.json(diag.report(for: [s.id], coordinator: c, appVersion: "1"))
        XCTAssertFalse(text.contains("SECRET"))
        sub.close(); notes.detach()
    }

    func testTwoProfilesWithTheSameAddressStayApartEverywhere() async throws {
        let a = DownloadCoordinator(); a.profileName = "alpha"; let b = DownloadCoordinator(); b.profileName = "beta"
        let url = URL(string: "https://files.example.org/same.bin")!
        let ta = a.begin(suggestedName: "same.bin", sourceURL: url, cancel: {}), tb = b.begin(suggestedName: "same.bin", sourceURL: url, cancel: {})
        XCTAssertNotEqual(ta.id, tb.id); XCTAssertNil(a.ledger.record(tb.id)); XCTAssertNil(b.ledger.record(ta.id))
        let store = AutomationClientStore(file: nil)
        guard case .created(_, let tokenA) = store.enrol(name: "a", profile: "alpha", scopes: [.downloadsRead, .downloadsControl]) else { return XCTFail() }
        let service = AutomationService(clients: store, coordinators: { [a, b] in [a, b] }); service.start()
        func call(_ m: String, _ p: String) async -> AutomationReply { await service.handle(AutomationRequest(method: m, target: p, headers: ["authorization": "Bearer \(tokenA)", "content-type": "application/json"], body: Data())) }
        let theirs = await call("GET", "/v1/downloads/\(tb.id.uuidString)"), theirsCancel = await call("POST", "/v1/downloads/\(tb.id.uuidString)/cancel"), mine = await call("GET", "/v1/downloads/\(ta.id.uuidString)")
        XCTAssertEqual(theirs.status, 404); XCTAssertEqual(theirsCancel.status, 404); XCTAssertEqual(mine.status, 200)
        XCTAssertNotEqual(b.ledger.record(tb.id)?.state, .cancelled)
    }

    func testAnExtensionOrAutomationRequestNeverBecomesTheUsersOwn() async throws {
        XCTAssertFalse(HTTPRequestPolicy.untrustedRequestsEnabled)
        for origin in [DownloadRequestOrigin.automation, .browserExtension] { XCTAssertThrowsError(try HTTPRequestPolicy(origin: origin).requireAllowedOrigin(), "\(origin)") }
        let c = DownloadCoordinator()
        let store = AutomationClientStore(file: nil)
        guard case .created(_, let token) = store.enrol(name: "t", profile: c.profileName, scopes: [.downloadsCreate, .downloadsRead]) else { return XCTFail() }
        let service = AutomationService(clients: store, coordinators: { [c] in [c] }); service.start()
        let r = await service.handle(AutomationRequest(method: "POST", target: "/v1/downloads", headers: ["authorization": "Bearer \(token)", "content-type": "application/json"], body: Data("{\"url\":\"https://files.example.org/x.zip\"}".utf8)))
        XCTAssertEqual(r.status, 202); XCTAssertTrue(c.ledger.records.isEmpty, "a proposal is not a task")
        let id = try XCTUnwrap(service.proposals.first?.id)
        let task = try XCTUnwrap(service.approve(id))
        XCTAssertNotEqual(c.ledger.record(task)?.engineMetadata["origin"], "automation")
    }

    func testResourcesAreReleasedOnceWhateverTheEnding() async throws {
        let c = DownloadCoordinator(); c.maxConcurrent = 1
        for ending in ["finish", "fail", "cancel"] {
            let t = await c.admitTicket(filename: "\(ending).bin", source: URL(string: "https://a.org/\(ending)"))
            XCTAssertTrue(t.admitted, ending)
            let s = c.begin(suggestedName: "\(ending).bin", sourceURL: URL(string: "https://a.org/\(ending)"), taskID: t.id, cancel: {})
            try Data([1]).write(to: s.destination)
            switch ending {
            case "finish": c.finish(s.id, source: nil); c.finish(s.id, source: nil)       // twice
            case "fail": c.fail(s.id, source: nil, error: URLError(.badServerResponse), willRetry: false); c.fail(s.id, source: nil, error: URLError(.badServerResponse), willRetry: false)
            default: c.cancel(s.id); c.cancel(s.id)
            }
        }
        let last = await c.admitTicket(filename: "again.bin", source: URL(string: "https://a.org/again"))
        XCTAssertTrue(last.admitted, "no place was leaked and none was handed out twice")
    }
}

// MARK: - Was a known limitation; fixed in Phase 22

@MainActor
final class ProcessWideSettingsEvidenceTests: P15Case {
    /// Phase 15 recorded that two coordinators (two profiles) shared these controllers and the last to apply its settings won for both. Phase 22 gives each profile its own limits
    /// (see `ProfileLimitTests`); this keeps the original scenario as the regression test.
    func testOverallSpeedLimitAndTimeoutAreNoLongerSharedBetweenCoordinators() {
        let savedTimeout = HTTPRequestPolicy.defaultRequestTimeout
        let a = DownloadCoordinator(), b = DownloadCoordinator()
        defer { BandwidthController.shared.setOverallLimit(nil, owner: a.ownerID); BandwidthController.shared.setOverallLimit(nil, owner: b.ownerID) }
        var sa = DownloadNetworkSettings(); sa.overallLimit = 1_000_000; sa.requestTimeout = 20
        var sb = DownloadNetworkSettings(); sb.overallLimit = 5_000_000; sb.requestTimeout = 90
        a.networkSettings = sa
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: a.ownerID), 1_000_000)
        b.networkSettings = sb
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: a.ownerID), 1_000_000, "profile A's limit is still A's")
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: b.ownerID), 5_000_000)
        XCTAssertEqual(HTTPRequestPolicy.defaultRequestTimeout, savedTimeout)
        XCTAssertEqual(a.networkSettings.requestTimeout, 20); XCTAssertEqual(b.networkSettings.requestTimeout, 90)
    }
}

// MARK: - Fixes from the Phase 15 independent review

@MainActor
final class Phase15ReviewFixTests: P15Case {
    private func enrol(_ s: AutomationClientStore, _ scopes: Set<AutomationScope> = [.downloadsRead, .downloadsControl]) -> (AutomationClient, String) {
        guard case .created(let c, let t) = s.enrol(name: "t", profile: "default", scopes: scopes) else { fatalError() }
        return (c, t)
    }

    // 2a / 2b: the start-up clean-up of one profile never touches another's

    func testAnotherProfilesUnfinishedDownloadSurvivesThisProfilesStartupCleanup() throws {
        let a = DownloadCoordinator(); a.profileName = "alpha"
        let folderA = scratch.appendingPathComponent("ledgerA"), folderB = scratch.appendingPathComponent("ledgerB")
        let old = scratch.appendingPathComponent("r.bin"); try Data([7]).write(to: old)
        a.duplicatePolicy = .replace; a.store = folderA
        let s = a.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r"), cancel: {})
        try Data([1, 2]).write(to: s.destination)
        a.interrupt(s.id, resumeData: Data([9]), source: URL(string: "https://a.org/r"))
        let b = DownloadCoordinator(); b.profileName = "beta"
        b.store = folderB                                                    // the app opens on another profile
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.destination.path), "alpha's staged file is still there")
        XCTAssertNotEqual(a.saveAsStagingRoot, b.saveAsStagingRoot)
        XCTAssertTrue(DownloadCoordinator.isStagedFile(s.destination))
    }

    func testNothingIsSweptWhenTheLedgerDidNotOpenProperly() throws {
        let folder = scratch.appendingPathComponent("badledger")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: folder.appendingPathComponent("downloads.sqlite"))
        let c = DownloadCoordinator()
        let orphan = c.saveAsStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("x.bin"))
        c.store = folder
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "a damaged database can look empty; nothing is deleted on that evidence")
    }

    // 2c: the only copy is never deleted

    func testIfEveryPlaceRefusesTheFinishedFileStaysWhereItIs() throws {
        let c = DownloadCoordinator()
        let missingFolder = scratch.appendingPathComponent("not-there", isDirectory: true).appendingPathComponent("x.bin")
        let s = c.begin(suggestedName: "x", sourceURL: URL(string: "https://a.org/x"), saveAs: .init(target: missingFolder, replaceExisting: false), cancel: {})
        try Data([4, 4]).write(to: s.destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)       // Downloads cannot take a new file
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path) }
        c.finish(s.id, source: nil)
        let final = try XCTUnwrap(c.completed.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path), "the finished download is still on disk")
        XCTAssertEqual(try Data(contentsOf: final), Data([4, 4]))
        XCTAssertEqual(c.ledger.record(s.id)?.file.destinationPath, final.path)
        XCTAssertEqual(c.ledger.record(s.id)?.engineMetadata["saveAsPlacement"], "failed-kept-in-staging")
    }

    // 2d / 2e

    func testWithoutAnIdentityNothingIsReplaced() throws {
        let target = scratch.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let staged = scratch.appendingPathComponent("staged"); try Data([2]).write(to: staged)
        let r = SaveAsDestination.place(staged: staged, choice: .init(target: target, replaceExisting: true, expectedIdentity: nil), dispose: { _ in XCTFail("nothing may be disposed of"); return true })
        guard case .keptBoth = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
    }

    func testAFileChangedAfterItWasAgreedToIsNotReplaced() throws {
        let target = scratch.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let choice = SaveAsDestination.resolve(target)
        XCTAssertTrue(choice.replaceExisting)
        try Data([1, 1, 1]).write(to: target)                                  // something else changed it meanwhile
        let staged = scratch.appendingPathComponent("staged"); try Data([2]).write(to: staged)
        guard case .keptBoth = SaveAsDestination.place(staged: staged, choice: choice) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 1, 1]))
    }

    func testAHiddenBackupLeftByAnInterruptedReplacementIsMadeVisibleAtStartup() throws {
        let folder = scratch.appendingPathComponent("ledger")
        let target = scratch.appendingPathComponent("doc.pdf"); try Data([2]).write(to: target)
        let hidden = scratch.appendingPathComponent(".doc.pdf.replaced-abcd1234"); try Data([1]).write(to: hidden)
        let first = DownloadCoordinator(); first.store = folder
        let t = first.begin(suggestedName: "doc.pdf", sourceURL: URL(string: "https://a.org/d"), saveAs: SaveAsDestination.Choice(target: target, replaceExisting: false), cancel: {})
        first.interrupt(t.id, resumeData: Data([1]), source: URL(string: "https://a.org/d"))
        let second = DownloadCoordinator(); second.store = folder                // relaunch
        XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
        let visible = scratch.appendingPathComponent("doc (previous).pdf")
        XCTAssertEqual(try Data(contentsOf: visible), Data([1]), "the person's old content is visible again")
        XCTAssertEqual(try Data(contentsOf: target), Data([2]))
    }

    // 1a-1d

    func testWithdrawingWhileADenyRecordIsUnreadableNeverOverwritesIt() {
        let deny = DenyFake(); let disk = PrimaryDisk()
        let file = scratch.appendingPathComponent("clients.json")
        let s = AutomationClientStore(file: file, writer: disk.write, denyStores: [deny])
        let (a, _) = enrol(s); let (b, tb) = enrol(s)
        _ = s.revoke(a.id)
        let recorded = deny.records
        deny.failRead = true
        let restarted = AutomationClientStore(file: file, writer: disk.write, denyStores: [deny])
        XCTAssertFalse(restarted.isReadable)
        let writesBefore = deny.writes
        _ = restarted.revoke(b.id)
        XCTAssertEqual(deny.writes, writesBefore, "an unreadable record is not written over")
        XCTAssertEqual(deny.records, recorded)
        XCTAssertEqual(restarted.authenticate(tb), .failed)
    }

    func testResettingWhenOnlyTheDenyRecordIsUnreadableWorksWithoutAListFile() {
        let deny = DenyFake(); deny.failRead = true
        let s = AutomationClientStore(file: nil, denyStores: [deny])
        XCTAssertFalse(s.isReadable)
        XCTAssertEqual(s.resetUnreadableList(), .committed)
        XCTAssertTrue(s.isReadable); XCTAssertEqual(deny.setAsideCalls, 1, "the old record was set aside, not left to be read again")
        XCTAssertTrue(s.clients.isEmpty, "and everyone starts again")
    }

    func testAWideningNeedsEveryDenyStoreToAcceptIt() {
        let good = DenyFake(), flaky = DenyFake()
        let s = AutomationClientStore(file: scratch.appendingPathComponent("c.json"), denyStores: [good, flaky])
        let (c, _) = enrol(s)
        XCTAssertEqual(s.setScopes(c.id, [.downloadsRead]), .committed)
        flaky.failWrite = true
        guard case .refused = s.setScopes(c.id, [.downloadsRead, .downloadsControl]) else { return XCTFail("one store would still hold the narrow cap") }
        XCTAssertEqual(s.clients[0].scopes, [.downloadsRead])
    }

    func testTheClientListIsBoundedEvenWithRevokedClients() {
        let s = AutomationClientStore(file: nil)
        var refused = false
        for _ in 0..<(AutomationClientStore.maxClients * 5 + 2) {
            if case .created(let c, _) = s.enrol(name: "t", profile: "default", scopes: [.downloadsRead]) { s.revoke(c.id) } else { refused = true; break }
        }
        XCTAssertTrue(refused)
    }

    // 3b / 3c

    func testAProfileThatJoinsLaterDoesNotAnnounceWhatItAlreadyHad() {
        let a = DownloadCoordinator(); a.profileName = "alpha"
        var list = [a]
        let feed = DownloadEventFeed(coordinators: { list })
        var created: [String] = []; feed.observe { e, _ in if e.type == "task.created" { created.append(e.profile) } }
        feed.start()
        let b = DownloadCoordinator(); b.profileName = "beta"
        for i in 0..<5 { _ = b.begin(suggestedName: "b\(i).bin", sourceURL: URL(string: "https://a.org/b\(i)"), cancel: {}) }
        list.append(b)
        feed.publishChanges()
        XCTAssertTrue(created.isEmpty, "five existing tasks are learned, not announced as new")
        _ = b.begin(suggestedName: "fresh.bin", sourceURL: URL(string: "https://a.org/fresh"), cancel: {})
        feed.publishChanges()
        XCTAssertEqual(created, ["beta"])
    }

    func testTheFeedDoesNotConfuseANewCoordinatorWithOneThatIsGone() {
        var list: [DownloadCoordinator] = [DownloadCoordinator()]
        let feed = DownloadEventFeed(coordinators: { list })
        feed.start()
        for _ in 0..<20 {
            list = [DownloadCoordinator()]                                   // the old one is released; its address may be reused
            XCTAssertTrue(feed.syncCoordinators(), "a different object is always a different coordinator")
        }
    }

    // The baseline fixes

    func testAProxyThatWantsALoginButHasNoPasswordFailsAtOnce() throws {
        var proxy = DownloadNetworkSettings.Proxy(); proxy.mode = .http; proxy.host = "127.0.0.1"; proxy.port = 8080; proxy.username = "alice"
        let config = URLSessionConfiguration.ephemeral
        XCTAssertThrowsError(try DownloadProxy.apply(proxy, password: nil, origin: .user, to: config)) { XCTAssertEqual($0 as? DownloadProxy.Problem, .missingPassword) }
        XCTAssertThrowsError(try DownloadProxy.apply(proxy, password: "", origin: .user, to: config))
        XCTAssertNoThrow(try DownloadProxy.apply(proxy, password: "s3cret", origin: .user, to: config))
        proxy.username = ""
        XCTAssertNoThrow(try DownloadProxy.apply(proxy, password: nil, origin: .user, to: config), "a proxy with no login needs no password")
    }
}
