import XCTest
import Darwin
@testable import Browser_Setu

// Phase 13: the Replace-policy prerequisite, then the automation service, its socket, events, webhooks and CLI. All local; no outside network; the real Keychain is never touched.

// MARK: - Test rig

@MainActor
final class Rig {
    let coordinator: DownloadCoordinator
    var coordinators: [DownloadCoordinator]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var mono: TimeInterval = 1000
    let store: AutomationClientStore
    let service: AutomationService

    init(profile: String = "default", extra: [DownloadCoordinator] = [], started: Bool = true) {
        let c = DownloadCoordinator(); c.profileName = profile
        coordinator = c
        coordinators = [c] + extra
        var clock: () -> Date = { Date() }
        var monotonic: () -> TimeInterval = { 0 }
        let box = Box()
        clock = { box.now }
        monotonic = { box.mono }
        self.box = box
        store = AutomationClientStore(file: nil, now: { box.now })
        service = AutomationService(clients: store, coordinators: { [unowned box] in box.list }, clock: clock, monotonic: monotonic)
        box.list = coordinators
        if started { service.start() }
    }

    final class Box { var now = Date(timeIntervalSince1970: 1_800_000_000); var mono: TimeInterval = 1000; var list: [DownloadCoordinator] = [] }
    let box: Box

    func advance(_ s: TimeInterval) { box.now = box.now.addingTimeInterval(s); box.mono += s }

    func token(_ scopes: Set<AutomationScope>, name: String = "tool", profile: String? = nil) -> String {
        guard case .created(_, let t) = store.enrol(name: name, profile: profile ?? coordinator.profileName, scopes: scopes) else { fatalError("enrol") }
        return t
    }

    @discardableResult
    func call(_ method: String, _ path: String, token: String?, body: String? = nil, headers: [String: String] = [:], transport: AutomationRequest.Transport = .unixSocket) async -> (status: Int, json: Any?, reply: AutomationReply) {
        var h = headers
        if let token { h["authorization"] = "Bearer " + token }
        if body != nil, h["content-type"] == nil { h["content-type"] = "application/json" }
        let reply = await service.handle(AutomationRequest(method: method, target: path, headers: h, body: Data((body ?? "").utf8), transport: transport))
        if case .json(let status, let data) = reply { return (status, try? JSONSerialization.jsonObject(with: data), reply) }
        return (200, nil, reply)
    }

    func code(_ r: (status: Int, json: Any?, reply: AutomationReply)) -> String? { ((r.json as? [String: Any])?["error"] as? [String: Any])?["code"] as? String }
}

private let read: Set<AutomationScope> = [.downloadsRead]
private let control: Set<AutomationScope> = [.downloadsRead, .downloadsControl]

@MainActor
class AutomationTestCase: XCTestCase {
    var scratch: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p13-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }
}

// MARK: - 0. Replace policy (the prerequisite)

@MainActor
final class ReplacePolicyFixTests: AutomationTestCase {
    private func existing(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let f = scratch.appendingPathComponent(name); try Data(bytes).write(to: f); return f
    }

    func testReplaceNoLongerMovesTheOldFileWhenTheDownloadStarts() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7, 7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        XCTAssertEqual(try Data(contentsOf: old), Data([7, 7]), "the original is where it was")
        XCTAssertNotEqual(s.destination, old)
        XCTAssertTrue(s.destination.path.hasPrefix(DownloadCoordinator.saveAsRoot.path), "the new file is written to a place of its own")
    }

    func testAFailedReplaceKeepsTheOriginal() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        try Data([1, 2, 3]).write(to: s.destination)
        c.fail(s.id, source: nil, error: URLError(.networkConnectionLost), willRetry: false)
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.destination.path))
    }

    func testACancelledReplaceKeepsTheOriginal() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        try Data([1]).write(to: s.destination)
        c.cancel(s.id)
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
    }

    func testAFinishedReplaceTakesTheNameOnlyAtTheEnd() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        try Data([1, 2, 3]).write(to: s.destination)
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
        c.finish(s.id, source: nil)
        XCTAssertEqual(try Data(contentsOf: old), Data([1, 2, 3]))
        XCTAssertEqual(c.completed.first, old)
    }

    func testAnAnsweredReplaceFromTheQuestionIsStagedToo() async throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .ask
        c.duplicateAsker = { _ in .replace }
        let old = try existing("q.bin", [7])
        let id = UUID()
        let skipped = await c.askAboutDuplicate(suggestedName: "q.bin", sourceHost: nil, source: nil, isPrivate: false, taskID: id)
        XCTAssertFalse(skipped)
        let s = c.begin(suggestedName: "q.bin", taskID: id, cancel: {})
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
        XCTAssertTrue(s.destination.path.hasPrefix(DownloadCoordinator.saveAsRoot.path))
    }

    func testTwoReplacesOfOneFileNeverLoseAnything() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let a = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/1"), cancel: {})
        let b = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/2"), cancel: {})
        try Data([1]).write(to: a.destination); try Data([2]).write(to: b.destination)
        c.finish(a.id, source: nil); c.finish(b.id, source: nil)
        XCTAssertEqual(c.completed.count, 2)
        XCTAssertEqual(Set(c.completed).count, 2, "two files, not one overwritten by the other")
        XCTAssertEqual(try Data(contentsOf: old), Data([1]))
        XCTAssertEqual(Set(c.completed.map { try! Data(contentsOf: $0) }), [Data([1]), Data([2])])
    }

    func testWithNothingToReplaceTheUsualPathIsUsed() {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let s = c.begin(suggestedName: "fresh.bin", sourceURL: URL(string: "https://a.org/f"), cancel: {})
        XCTAssertEqual(s.destination.lastPathComponent, "fresh.bin")
        XCTAssertFalse(s.destination.path.hasPrefix(DownloadCoordinator.saveAsRoot.path))
    }

    func testAnInterruptedReplaceLeavesBothFilesOnDisk() throws {
        // The app stops after the transfer but before the swap: the original is still in place and the new file is in its task-owned folder.
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        try Data([1, 2]).write(to: s.destination)
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
        XCTAssertEqual(try Data(contentsOf: s.destination), Data([1, 2]))
        XCTAssertEqual(c.ledger.record(s.id)?.engineMetadata[DownloadCoordinator.saveAsReplaceKey], "1", "the intent is in the ledger, so a relaunch can finish the swap")
    }

    func testAResumeUnderAnotherPolicyNeverDeletesTheDownloadsFolderOrTheOriginal() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7])
        let id = UUID()
        _ = c.begin(suggestedName: "r.bin", taskID: id, cancel: {})              // staged for a replacement
        c.duplicatePolicy = .keepBoth                                            // then the person changes the policy and the task starts again
        let again = c.begin(suggestedName: "r.bin", taskID: id, cancel: {})
        XCTAssertFalse(again.destination.path.hasPrefix(DownloadCoordinator.saveAsRoot.path))
        try Data([1, 2]).write(to: again.destination)
        c.finish(id, source: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "the Downloads folder is still there")
        XCTAssertEqual(try Data(contentsOf: old), Data([7]), "the original was not replaced by a download that did not ask for it")
        XCTAssertEqual(try Data(contentsOf: again.destination), Data([1, 2]))
    }

    func testAFileOfTheWrongSizeNeverReplacesAGoodOne() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .replace
        let old = try existing("r.bin", [7, 7, 7])
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/r.bin"), cancel: {})
        c.ledger.update(s.id) { $0.transfer.totalBytes = 999 }
        try Data([1]).write(to: s.destination)
        c.finish(s.id, source: nil)
        XCTAssertEqual(try Data(contentsOf: old), Data([7, 7, 7]))
        XCTAssertNotEqual(c.completed.first, old)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(c.completed.first)), Data([1]))
    }

    func testAFileAnotherDownloadIsStillUsingIsNotReplaced() throws {
        let c = DownloadCoordinator(); c.duplicatePolicy = .keepBoth
        let a = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/1"), cancel: {})
        try Data([1]).write(to: a.destination)                                   // A is still downloading to r.bin
        c.duplicatePolicy = .replace
        let b = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "https://a.org/2"), cancel: {})
        XCTAssertFalse(b.destination.path.hasPrefix(DownloadCoordinator.saveAsRoot.path), "not staged for a replacement: A's file is not the person's old file")
        XCTAssertNotEqual(b.destination, a.destination)
    }

    func testStagingLeftByATaskThatNoLongerExistsIsSwept() throws {
        let probe = DownloadCoordinator()
        let orphan = probe.saveAsStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("x.bin"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p13-led-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: folder) }
        probe.store = folder
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testTheAutomationServiceCannotAskForAReplacement() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Automation/AutomationService.swift"), encoding: .utf8)
        for forbidden in ["duplicatePolicy =", "replaceChosen", "saveAs:", "SaveAsDestination"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }
}

// MARK: - 1. Authentication and permission

@MainActor
final class AutomationAuthTests: AutomationTestCase {
    func testItIsOffUntilStarted() async {
        let r = Rig(started: false)
        let t = r.token(read)
        let reply = await r.call("GET", "/v1/health", token: t)
        XCTAssertEqual(reply.status, 503); XCTAssertEqual(r.code(reply), "disabled")
    }

    func testMissingAndInvalidTokensAreRefusedTheSameWay() async {
        let r = Rig()
        let t = r.token(read)
        let none = await r.call("GET", "/v1/downloads", token: nil)
        let bad = await r.call("GET", "/v1/downloads", token: "bsat_deadbeef_" + String(repeating: "0", count: 64))
        let shape = await r.call("GET", "/v1/downloads", token: "nonsense")
        let wrongSecret = await r.call("GET", "/v1/downloads", token: String(t.dropLast(4)) + "0000")
        for x in [none, bad, shape, wrongSecret] { XCTAssertEqual(x.status, 401); XCTAssertEqual(r.code(x), "unauthorized") }
        XCTAssertEqual((none.json as? NSDictionary), (bad.json as? NSDictionary), "the answer does not say which part was wrong")
    }

    func testARevokedRotatedOrExpiredClientStopsAtOnce() async {
        let r = Rig()
        let t1 = r.token(read, name: "one"), t2 = r.token(read, name: "two")
        let ok1 = await r.call("GET", "/v1/downloads", token: t1); XCTAssertEqual(ok1.status, 200)
        let id1 = String(t1.split(separator: "_")[1]), id2 = String(t2.split(separator: "_")[1])
        r.store.revoke(id1)
        let revoked = await r.call("GET", "/v1/downloads", token: t1); XCTAssertEqual(revoked.status, 401)
        let fresh = r.store.rotate(id2).token!
        let old = await r.call("GET", "/v1/downloads", token: t2); XCTAssertEqual(old.status, 401, "the old secret is dead")
        let new = await r.call("GET", "/v1/downloads", token: fresh); XCTAssertEqual(new.status, 200)
        guard case .created(_, let short) = r.store.enrol(name: "short", profile: "default", scopes: read, validFor: 60) else { return XCTFail() }
        let live = await r.call("GET", "/v1/downloads", token: short); XCTAssertEqual(live.status, 200)
        r.advance(61)
        let expired = await r.call("GET", "/v1/downloads", token: short); XCTAssertEqual(expired.status, 401)
    }

    func testScopesAreEnforcedOneByOne() async throws {
        let r = Rig()
        let s = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let id = s.id.uuidString
        let reader = r.token(read, name: "reader")
        let denied = await r.call("POST", "/v1/downloads/\(id)/cancel", token: reader)
        XCTAssertEqual(denied.status, 403); XCTAssertEqual(r.code(denied), "missing_scope")
        let create = await r.call("POST", "/v1/downloads", token: reader, body: "{\"url\":\"https://a.org/x\"}")
        XCTAssertEqual(r.code(create), "missing_scope")
        let queues = await r.call("GET", "/v1/queues", token: reader); XCTAssertEqual(r.code(queues), "missing_scope")
        let settings = await r.call("GET", "/v1/settings", token: reader); XCTAssertEqual(r.code(settings), "missing_scope")
        let stillThere = await r.call("GET", "/v1/downloads/\(id)", token: reader); XCTAssertEqual(stillThere.status, 200)
        XCTAssertNotEqual(r.coordinator.ledger.record(s.id)?.state, .cancelled)
        // Controlling is not the same as touching files.
        let controller = r.token(control, name: "controller")
        let files = await r.call("POST", "/v1/downloads/\(id)/trash-file", token: controller); XCTAssertEqual(r.code(files), "missing_scope")
    }

    func testATokenInTheAddressIsRefused() async {
        let r = Rig(); let t = r.token(read)
        let x = await r.call("GET", "/v1/downloads?access_token=\(t)", token: nil)
        XCTAssertEqual(r.code(x), "token_in_url")
    }

    func testGuessingIsLimited() async {
        let r = Rig(); _ = r.token(read)
        var last = 0
        for _ in 0..<12 { last = await r.call("GET", "/v1/downloads", token: "bsat_00000000_" + String(repeating: "a", count: 64)).status }
        XCTAssertEqual(last, 429)
    }

    func testOnlyAHashOfTheSecretIsKept() throws {
        let file = scratch.appendingPathComponent("clients.json")
        let store = AutomationClientStore(file: file)
        guard case .created(let client, let token) = store.enrol(name: "x", profile: "default", scopes: read) else { return XCTFail() }
        let secret = String(token.split(separator: "_")[2])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret)); XCTAssertTrue(text.contains(client.tokenHash))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let again = AutomationClientStore(file: file)
        guard case .ok(let restored) = again.authenticate(token) else { return XCTFail("a restart keeps the client") }
        XCTAssertEqual(restored.id, client.id); XCTAssertEqual(restored.scopes, client.scopes); XCTAssertEqual(restored.tokenHash, client.tokenHash)
    }

    func testAHandEditedFileCannotInventAClientWithABadHash() throws {
        let file = scratch.appendingPathComponent("clients.json")
        try Data("[{\"id\":\"abcd1234\",\"name\":\"x\",\"profile\":\"default\",\"scopes\":[\"downloads.read\"],\"createdAt\":\"2026-01-01T00:00:00Z\",\"tokenHash\":\"short\"}]".utf8).write(to: file)
        XCTAssertTrue(AutomationClientStore(file: file).clients.isEmpty)
    }
}

// MARK: - 2. Request checks (CSRF, DNS rebinding, size, shape, rate)

@MainActor
final class AutomationRequestChecksTests: AutomationTestCase {
    func testAWebPageRequestIsRefusedWhateverItsToken() async {
        let r = Rig(); let t = r.token(read)
        let origin = await r.call("GET", "/v1/downloads", token: t, headers: ["origin": "https://evil.example"])
        XCTAssertEqual(r.code(origin), "browser_origin")
        let fetch = await r.call("GET", "/v1/downloads", token: t, headers: ["sec-fetch-site": "cross-site"])
        XCTAssertEqual(r.code(fetch), "browser_origin")
    }

    func testLoopbackNeedsTheExactHost() async {
        let r = Rig(); let t = r.token(read)
        let rebound = await r.call("GET", "/v1/downloads", token: t, headers: ["host": "evil.example:4000"], transport: .loopback(port: 4000))
        XCTAssertEqual(r.code(rebound), "bad_host")
        let wrongPort = await r.call("GET", "/v1/downloads", token: t, headers: ["host": "127.0.0.1:9999"], transport: .loopback(port: 4000))
        XCTAssertEqual(r.code(wrongPort), "bad_host")
        let missing = await r.call("GET", "/v1/downloads", token: t, transport: .loopback(port: 4000))
        XCTAssertEqual(r.code(missing), "bad_host")
        let good = await r.call("GET", "/v1/downloads", token: t, headers: ["host": "127.0.0.1:4000"], transport: .loopback(port: 4000))
        XCTAssertEqual(good.status, 200)
    }

    func testOversizedMalformedAndWrongTypeBodies() async {
        let r = Rig(); let t = r.token([.downloadsCreate])
        let big = await r.call("POST", "/v1/downloads", token: t, body: String(repeating: "a", count: AutomationService.maxBody + 1))
        XCTAssertEqual(big.status, 413)
        let bad = await r.call("POST", "/v1/downloads", token: t, body: "{not json")
        XCTAssertEqual(r.code(bad), "bad_json")
        let plain = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://a.org/x\"}", headers: ["content-type": "text/plain"])
        XCTAssertEqual(plain.status, 415, "a form or text post, the kind a web page can send without a preflight, is not accepted")
    }

    func testRateLimiting() async {
        let r = Rig(); let t = r.token(read)
        var codes: [Int] = []
        for _ in 0..<65 { codes.append(await r.call("GET", "/v1/health", token: t).status) }
        XCTAssertEqual(codes.prefix(60).filter { $0 == 200 }.count, 60); XCTAssertEqual(codes.last, 429)
        r.advance(11)
        let after = await r.call("GET", "/v1/health", token: t)
        XCTAssertEqual(after.status, 200, "the window passes")
    }

    func testUnknownRoutesAndMethods() async {
        let r = Rig(); let t = r.token(read)
        for (m, p) in [("GET", "/v2/downloads"), ("GET", "/v1/nothing"), ("DELETE", "/v1/downloads"), ("GET", "/v1/downloads/not-a-uuid")] {
            let x = await r.call(m, p, token: t); XCTAssertEqual(x.status, 404, "\(m) \(p)")
        }
    }

    func testTheRateLimiterIsBounded() {
        var l = AutomationRateLimiter(limit: 1, window: 10)
        for i in 0..<1000 { _ = l.allow("k\(i)", at: Double(i) * 20) }
        XCTAssertTrue(l.allow("fresh", at: 99_999))
    }
}

// MARK: - 3. Commands against the real coordinator

@MainActor
final class AutomationCommandTests: AutomationTestCase {
    private func body(_ json: String) -> String { json }

    func testAProposalIsNotATask() async throws {
        let r = Rig(); let t = r.token([.downloadsCreate, .downloadsRead])
        let x = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/a.zip?sig=SECRET\",\"filename\":\"a.zip\",\"priority\":\"high\"}")
        XCTAssertEqual(x.status, 202)
        let dto = try XCTUnwrap(x.json as? [String: Any])
        XCTAssertEqual(dto["state"] as? String, "pending")
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: dto), encoding: .utf8)!.contains("SECRET"), "the signed part of the address is never echoed")
        XCTAssertTrue(r.coordinator.ledger.records.isEmpty, "nothing was created, queued or connected")
    }

    func testOnlyThePersonApprovesAndApprovalIsTheirOwnRequest() async throws {
        let r = Rig(); let t = r.token([.downloadsCreate, .downloadsRead, .downloadsControl])
        let x = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/a.zip\"}")
        let id = try XCTUnwrap((x.json as? [String: Any])?["id"] as? String)
        for path in ["/v1/proposals/\(id)/approve", "/v1/proposals/\(id)", "/v1/downloads/\(id)/approve"] {
            let tried = await r.call("POST", path, token: t); XCTAssertEqual(tried.status, 404, path)
        }
        XCTAssertTrue(r.coordinator.ledger.records.isEmpty)
        let task = try XCTUnwrap(r.service.approve(id))
        let record = try XCTUnwrap(r.coordinator.ledger.record(task))
        XCTAssertNotEqual(record.engineMetadata["origin"], "automation", "the person's approval made it; the API's request did not become the person's")
        XCTAssertNotEqual(record.engineMetadata["origin"], "browserExtension")
        XCTAssertNil(r.service.approve(id), "once")
    }

    func testDirectStartsAndUnsafeDestinationsAreRefused() async {
        let r = Rig(); let t = r.token([.downloadsCreate])
        func post(_ json: String) async -> String? { r.code(await r.call("POST", "/v1/downloads", token: t, body: json)) }
        let direct = await post("{\"url\":\"https://a.org/x\",\"approved\":true}"); XCTAssertEqual(direct, "origin_not_allowed")
        let magnet = await post("{\"url\":\"magnet:?xt=urn:btih:abc\"}"); XCTAssertEqual(magnet, "p2p_requires_user")
        let ed2k = await post("{\"url\":\"ed2k://x\"}"); XCTAssertEqual(ed2k, "p2p_requires_user")
        for host in ["http://127.0.0.1/x", "http://localhost/x", "http://10.0.0.5/x", "http://192.168.1.1/x", "http://169.254.169.254/x", "http://[::1]/x"] {
            let denied = await post("{\"url\":\"\(host)\"}"); XCTAssertEqual(denied, "destination_not_allowed", host)
        }
        let creds = await post("{\"url\":\"https://u:p@a.org/x\"}"); XCTAssertEqual(creds, "credentials_in_url")
        let file = await post("{\"url\":\"file:///etc/passwd\"}"); XCTAssertEqual(file, "unsupported_scheme")
        let name = await post("{\"url\":\"https://a.org/x\",\"filename\":\"..\"}"); XCTAssertEqual(name, "bad_filename")
        let blank = await post("{\"url\":\"https://a.org/x\",\"filename\":\"   \"}"); XCTAssertEqual(blank, "bad_filename")
        let prio = await post("{\"url\":\"https://a.org/x\",\"priority\":\"urgent\"}"); XCTAssertEqual(prio, "bad_priority")
        let sha = await post("{\"url\":\"https://a.org/x\",\"sha256\":\"zz\"}"); XCTAssertEqual(sha, "bad_sha256")
        let far = await post("{\"url\":\"https://a.org/x\",\"startAt\":\"2099-01-01T00:00:00Z\"}"); XCTAssertEqual(far, "bad_start")
        XCTAssertTrue(r.coordinator.ledger.records.isEmpty)
        XCTAssertTrue(r.service.proposals.isEmpty)
    }

    func testTheExtensionAndGateRulesStayInForce() {
        XCTAssertFalse(HTTPRequestPolicy.untrustedRequestsEnabled)
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .automation).requireAllowedOrigin())
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .browserExtension).requireAllowedOrigin())
    }

    func testIdempotency() async throws {
        let r = Rig(); let t = r.token([.downloadsCreate, .downloadsRead])
        let json = "{\"url\":\"https://files.example.org/a.zip\"}"
        let a = await r.call("POST", "/v1/downloads", token: t, body: json, headers: ["idempotency-key": "key-0001-abc"])
        let b = await r.call("POST", "/v1/downloads", token: t, body: json, headers: ["idempotency-key": "key-0001-abc"])
        XCTAssertEqual((a.json as? NSDictionary), (b.json as? NSDictionary), "the same answer, the same id")
        XCTAssertEqual(r.service.proposals.count, 1)
        let other = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/other.zip\"}", headers: ["idempotency-key": "key-0001-abc"])
        XCTAssertEqual(other.status, 422); XCTAssertEqual(r.code(other), "idempotency_mismatch")
        let badKey = await r.call("POST", "/v1/downloads", token: t, body: json, headers: ["idempotency-key": "x"])
        XCTAssertEqual(r.code(badKey), "bad_idempotency_key")
        // Without a key, the same address from the same client is still the same proposal.
        let c = await r.call("POST", "/v1/downloads", token: t, body: json)
        XCTAssertEqual(((c.json as? [String: Any])?["id"] as? String), ((a.json as? [String: Any])?["id"] as? String))
        XCTAssertEqual(r.service.proposals.count, 1)
    }

    func testAKeyIsPerClient() async throws {
        let r = Rig(); let a = r.token([.downloadsCreate], name: "a"), b = r.token([.downloadsCreate], name: "b")
        let json = "{\"url\":\"https://files.example.org/a.zip\"}"
        _ = await r.call("POST", "/v1/downloads", token: a, body: json, headers: ["idempotency-key": "shared-key-1"])
        _ = await r.call("POST", "/v1/downloads", token: b, body: json, headers: ["idempotency-key": "shared-key-1"])
        XCTAssertEqual(r.service.proposals.count, 2)
    }

    func testListAndStatusShowOnlySanitizedFacts() async throws {
        let r = Rig(); let t = r.token(read)
        let s = r.coordinator.begin(suggestedName: "a.bin", sourceHost: "h.org", sourceURL: URL(string: "https://user:pw@h.org/f.bin?sig=SECRET#frag"), cancel: {})
        let list = await r.call("GET", "/v1/downloads", token: t)
        let one = await r.call("GET", "/v1/downloads/\(s.id.uuidString)", token: t)
        for reply in [list, one] {
            let text = String(data: try JSONSerialization.data(withJSONObject: reply.json as Any), encoding: .utf8)!
            for secret in ["SECRET", "pw", "user:", "frag", scratch.path] { XCTAssertFalse(text.contains(secret), secret) }
        }
        let dto = try XCTUnwrap(one.json as? [String: Any])
        XCTAssertEqual(dto["source"] as? String, "https://h.org/f.bin")
        XCTAssertEqual(dto["state"] as? String, "running")
    }

    func testPrivateDownloadsDoNotExist() async {
        let r = Rig(); let t = r.token(read)
        let p = r.coordinator.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {})
        let list = await r.call("GET", "/v1/downloads", token: t)
        XCTAssertEqual((list.json as? [Any])?.count, 0)
        let one = await r.call("GET", "/v1/downloads/\(p.id.uuidString)", token: t); XCTAssertEqual(one.status, 404)
        let stats = await r.call("GET", "/v1/stats", token: t)
        XCTAssertEqual((stats.json as? [String: Any])?["total"] as? Int, 0)
    }

    func testPauseResumeThroughTheCoordinator() async throws {
        let r = Rig(); let t = r.token(control)
        let c = r.coordinator
        var resumed = false
        c.hasHost = { true }; c.resumerWithID = { _, _ in resumed = true }
        let s = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {}, suspend: { done in done(Data([1, 2])) })
        let paused = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/pause", token: t)
        XCTAssertEqual(paused.status, 200)
        for _ in 0..<50 where c.interrupted[s.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(c.interrupted[s.id])
        let back = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/resume", token: t)
        XCTAssertEqual(back.status, 200)
        for _ in 0..<50 where !resumed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(resumed, "the engine's own resume ran")
    }

    func testAnEngineThatCannotPauseSaysSo() async {
        let r = Rig(); let t = r.token(control)
        let s = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})     // no way to hand back resume data
        let x = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/pause", token: t)
        XCTAssertEqual(x.status, 409); XCTAssertEqual(r.code(x), "unsupported_operation")
        let resume = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/resume", token: t)
        XCTAssertEqual(r.code(resume), "not_resumable")
    }

    func testCancelOnceAndNotAfterwards() async throws {
        let r = Rig(); let t = r.token(control)
        let s = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let x = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/cancel", token: t); XCTAssertEqual(x.status, 200)
        XCTAssertEqual(r.coordinator.ledger.record(s.id)?.state, .cancelled)
        let again = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/cancel", token: t); XCTAssertEqual(r.code(again), "already_finished")
    }

    func testRetryUsesTheCoordinatorAndOnlyWhenItCan() async throws {
        let r = Rig(); let t = r.token(control); let c = r.coordinator
        var started: URL?
        c.hasHost = { true }; c.starter = { started = $0 }
        let source = URL(string: "https://a.org/a.bin")!
        let s = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {})
        let notYet = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/retry", token: t); XCTAssertEqual(r.code(notYet), "not_retryable")
        c.fail(s.id, source: source, error: URLError(.badServerResponse), willRetry: false)
        let ok = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/retry", token: t); XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(started, source)
    }

    func testPriorityAndSchedule() async throws {
        let r = Rig(); let t = r.token(control); let c = r.coordinator
        let s = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let p = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/priority", token: t, body: "{\"priority\":\"high\"}"); XCTAssertEqual(p.status, 200)
        XCTAssertEqual(c.ledger.record(s.id)?.priority, .high)
        let bad = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/priority", token: t, body: "{\"priority\":\"x\"}"); XCTAssertEqual(r.code(bad), "bad_priority")
        let due = Date().addingTimeInterval(7200)
        let id = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://a.org/later")!, at: due))
        let later = ISO8601DateFormatter().string(from: due.addingTimeInterval(3600))
        let moved = await r.call("POST", "/v1/downloads/\(id.uuidString)/schedule", token: t, body: "{\"startAt\":\"\(later)\"}"); XCTAssertEqual(moved.status, 200)
        XCTAssertEqual(c.scheduled.first { $0.id == id }?.dueAt.map { Int($0.timeIntervalSince1970) }, Int(due.addingTimeInterval(3600).timeIntervalSince1970))
        let notScheduled = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/schedule", token: t, body: "{\"startAt\":\"\(later)\"}"); XCTAssertEqual(r.code(notScheduled), "not_scheduled")
    }

    func testQueueHoldAndRelease() async throws {
        let r = Rig(); let t = r.token([.queuesRead, .queuesControl])
        let list = await r.call("GET", "/v1/queues", token: t); XCTAssertEqual(((list.json as? [[String: Any]])?.first?["held"] as? Bool), false)
        let held = await r.call("POST", "/v1/queues/default/hold", token: t); XCTAssertEqual((held.json as? [String: Any])?["held"] as? Bool, true)
        XCTAssertTrue(r.coordinator.scheduler.isHeld)
        let freed = await r.call("POST", "/v1/queues/default/release", token: t); XCTAssertEqual((freed.json as? [String: Any])?["held"] as? Bool, false)
        XCTAssertFalse(r.coordinator.scheduler.isHeld)
    }

    func testBatchReportsEachItem() async throws {
        let r = Rig(); let t = r.token(control)
        let a = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let x = await r.call("POST", "/v1/downloads:batch", token: t, body: "{\"action\":\"cancel\",\"ids\":[\"\(a.id.uuidString)\",\"\(UUID().uuidString)\",\"junk\"]}")
        let rows = try XCTUnwrap(x.json as? [[String: Any]])
        XCTAssertEqual(rows.filter { $0["ok"] as? Bool == true }.count, 1)
        XCTAssertEqual(rows.filter { $0["code"] as? String == "not_found" }.count, 2)
        let tooMany = await r.call("POST", "/v1/downloads:batch", token: t, body: "{\"action\":\"cancel\",\"ids\":[\(Array(repeating: "\"x\"", count: 51).joined(separator: ","))]}")
        XCTAssertEqual(r.code(tooMany), "bad_batch")
    }

    func testCapabilitiesSayWhatTheApiCannotDo() async throws {
        let r = Rig(); let t = r.token(read)
        let x = await r.call("GET", "/v1/capabilities", token: t)
        let rows = try XCTUnwrap(x.json as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["engine"] as? String == "bittorrent" }?["createdThroughAPI"] as? Bool, false)
        XCTAssertEqual(rows.first { $0["engine"] as? String == "ed2k" }?["createdThroughAPI"] as? Bool, false)
    }

    func testTrashFileNeedsItsScopeAndAnAuthorizedPath() async throws {
        let r = Rig(); let t = r.token([.downloadsFiles]); let c = r.coordinator
        let s = c.begin(suggestedName: "done.bin", sourceURL: URL(string: "https://a.org/d"), cancel: {})
        try Data([1]).write(to: s.destination)
        let early = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/trash-file", token: t); XCTAssertEqual(r.code(early), "path_not_allowed", "not finished")
        c.finish(s.id, source: nil)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data([9]).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        c.ledger.update(s.id) { $0.file.destinationPath = outside.path }
        let denied = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/trash-file", token: t); XCTAssertEqual(r.code(denied), "path_not_allowed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a path outside Downloads is never touched")
    }

    func testTheAuditTrailHoldsNoAddressesOrSecrets() async throws {
        let r = Rig(); let t = r.token([.downloadsCreate, .downloadsRead])
        _ = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/a.zip?sig=SECRET\"}")
        let id = UUID().uuidString
        _ = await r.call("GET", "/v1/downloads/\(id)?x=1", token: t)
        let all = r.service.audit.map { "\($0.client) \($0.action) \($0.outcome)" }.joined(separator: "\n")
        XCTAssertFalse(all.contains("SECRET")); XCTAssertFalse(all.contains(id)); XCTAssertFalse(all.contains(t)); XCTAssertFalse(all.contains("files.example.org"))
        XCTAssertTrue(all.contains("GET /v1/downloads/:id"))
    }
}

// MARK: - 4. Profiles

@MainActor
final class AutomationProfileTests: AutomationTestCase {
    func testAClientNeverReachesAnotherProfile() async throws {
        let beta = DownloadCoordinator(); beta.profileName = "beta"
        let r = Rig(profile: "alpha", extra: [beta])
        let theirs = beta.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        let mine = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let t = r.token([.downloadsRead, .downloadsControl, .downloadsCreate])
        let list = await r.call("GET", "/v1/downloads", token: t)
        XCTAssertEqual((list.json as? [[String: Any]])?.map { $0["id"] as? String }, [mine.id.uuidString])
        for path in ["/v1/downloads/\(theirs.id.uuidString)", ] { let x = await r.call("GET", path, token: t); XCTAssertEqual(x.status, 404) }
        let cancel = await r.call("POST", "/v1/downloads/\(theirs.id.uuidString)/cancel", token: t); XCTAssertEqual(cancel.status, 404)
        XCTAssertNotEqual(beta.ledger.record(theirs.id)?.state, .cancelled)
        let named = await r.call("GET", "/v1/downloads", token: t, headers: ["x-browsersetu-profile": "beta"]); XCTAssertEqual(r.code(named), "profile_mismatch")
        let inBody = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://a.org/x\",\"profile\":\"beta\"}"); XCTAssertEqual(r.code(inBody), "profile_mismatch")
        let batch = await r.call("POST", "/v1/downloads:batch", token: t, body: "{\"action\":\"cancel\",\"ids\":[\"\(theirs.id.uuidString)\"]}")
        XCTAssertEqual(((batch.json as? [[String: Any]])?.first?["code"] as? String), "not_found")
        XCTAssertNotEqual(beta.ledger.record(theirs.id)?.state, .cancelled)
    }

    func testAProposalApprovedLandsInTheClientsOwnProfile() async throws {
        let beta = DownloadCoordinator(); beta.profileName = "beta"
        let r = Rig(profile: "alpha", extra: [beta])
        let t = r.token([.downloadsCreate])
        let x = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/a.zip\"}")
        let task = try XCTUnwrap(r.service.approve(try XCTUnwrap((x.json as? [String: Any])?["id"] as? String)))
        XCTAssertNotNil(r.coordinator.ledger.record(task)); XCTAssertNil(beta.ledger.record(task))
    }

    func testAClientForAProfileWithNoServiceGetsNothing() async {
        let r = Rig(profile: "alpha")
        let t = r.token(read, profile: "ghost")
        let x = await r.call("GET", "/v1/downloads", token: t); XCTAssertEqual(x.status, 404)
    }
}

// MARK: - 5. Events

@MainActor
final class AutomationEventTests: AutomationTestCase {
    private func snap(_ id: UUID, _ state: DownloadState, _ f: Double? = nil, profile: String = "default") -> AutomationEventHub.Snapshot {
        .init(id: id, state: state, fraction: f, bytes: Int64((f ?? 0) * 100), host: "h.org", profile: profile)
    }

    func testTheHubTurnsChangesIntoEventsAndLearnsSilently() {
        let hub = AutomationEventHub(); let id = UUID()
        var seen: [String] = []
        hub.ingest([snap(id, .running, 0)], now: 0) { seen.append($0.type) }
        XCTAssertTrue(seen.isEmpty, "the first look sends nothing")
        let other = UUID()
        hub.ingest([snap(id, .running, 0.5), snap(other, .queued)], now: 1) { seen.append($0.type) }
        hub.ingest([snap(id, .paused, 0.5), snap(other, .queued)], now: 2) { seen.append($0.type) }
        hub.ingest([snap(id, .running, 0.5), snap(other, .queued)], now: 3) { seen.append($0.type) }
        hub.ingest([snap(id, .completed, 1), snap(other, .failed)], now: 4) { seen.append($0.type) }
        XCTAssertEqual(seen, ["task.progress", "task.created", "task.paused", "task.resumed", "task.completed", "task.failed", "queue.completed"])
    }

    func testProgressIsCoalescedAndRateLimited() {
        let hub = AutomationEventHub(); let id = UUID(); var progress = 0
        hub.ingest([snap(id, .running, 0)], now: 0)
        for i in 1...100 { hub.ingest([snap(id, .running, Double(i) / 1000)], now: Double(i) * 0.001) { if $0.type == "task.progress" { progress += 1 } } }
        XCTAssertLessThanOrEqual(progress, 2, "a hundred tiny readings in a tenth of a second are not a hundred events")
    }

    func testSubscribingNeedsTheScopeAndHasLimits() async {
        let r = Rig()
        let none = r.token([.queuesRead], name: "none"); let ok = r.token(read, name: "ok")
        let denied = await r.call("GET", "/v1/events", token: none); XCTAssertEqual(r.code(denied), "missing_scope")
        var subs: [AutomationReply] = []
        for _ in 0..<4 { subs.append(await r.call("GET", "/v1/events", token: ok).reply) }
        for s in subs { guard case .stream = s else { return XCTFail("expected a stream") } }
        let fifth = await r.call("GET", "/v1/events", token: ok); XCTAssertEqual(r.code(fifth), "busy", "four at once per client")
        for s in subs { if case .stream(let sub) = s { sub.close() } }
    }

    func testEventsOfAnotherProfileAreNotDelivered() async {
        let hub = AutomationEventHub(); let a = hub.subscribe(clientID: "a", profile: "alpha", lastEventID: nil)!
        let id = UUID(), other = UUID()
        hub.ingest([], now: 0)
        hub.ingest([snap(id, .queued, profile: "alpha"), snap(other, .queued, profile: "beta")], now: 1)
        let first = await a.next()
        XCTAssertEqual(first?.taskID, id.uuidString)
        XCTAssertEqual(a.pending, 0, "beta's event never reached alpha's client")
        a.close()
    }

    func testASlowClientIsBoundedAndThenDisconnected() {
        let hub = AutomationEventHub(); let sub = hub.subscribe(clientID: "slow", profile: "default", lastEventID: nil)!
        hub.ingest([], now: 0)
        var snaps: [AutomationEventHub.Snapshot] = []
        for i in 0..<300 { snaps.append(snap(UUID(), .queued)); _ = i }
        hub.ingest(snaps, now: 1)        // 300 important events at once
        XCTAssertLessThanOrEqual(sub.pending, AutomationSubscription.capacity)
        XCTAssertTrue(sub.isClosed, "it fell too far behind and was cut off rather than buffered for ever")
    }

    func testReconnectingReplaysWhatWasMissedForTheSameProfileOnly() async {
        let hub = AutomationEventHub(); hub.ingest([], now: 0)
        let a = UUID(), b = UUID(), c = UUID()
        hub.ingest([snap(a, .queued, profile: "alpha")], now: 1)
        hub.ingest([snap(a, .queued, profile: "alpha"), snap(b, .queued, profile: "alpha"), snap(c, .queued, profile: "beta")], now: 2)
        let sub = hub.subscribe(clientID: "x", profile: "alpha", lastEventID: "\(hub.sequence.epoch)-1")!
        let replayed = await sub.next()
        XCTAssertEqual(replayed?.taskID, b.uuidString)
        XCTAssertEqual(sub.pending, 0)
        sub.close()
    }

    func testClosingAStreamFreesItsPlace() async throws {
        let hub = AutomationEventHub()
        let subs = (0..<4).map { _ in hub.subscribe(clientID: "c", profile: "p", lastEventID: nil)! }
        XCTAssertNil(hub.subscribe(clientID: "c", profile: "p", lastEventID: nil))
        subs[0].close()
        var freed: AutomationSubscription?
        for _ in 0..<50 where freed == nil { freed = hub.subscribe(clientID: "c", profile: "p", lastEventID: nil); if freed == nil { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNotNil(freed, "the closed stream's place was given back")
        hub.closeAll()
        XCTAssertTrue(hub.subscribers.isEmpty)
    }

    func testStoppingTheServiceEndsEveryStream() async {
        let r = Rig(); let t = r.token(read)
        guard case .stream(let sub) = await r.call("GET", "/v1/events", token: t).reply else { return XCTFail() }
        r.service.stop()
        XCTAssertTrue(sub.isClosed)
        let after = await sub.next(); XCTAssertNil(after)
        let refused = await r.call("GET", "/v1/downloads", token: t); XCTAssertEqual(refused.status, 503)
    }

    func testRealTasksProduceEventsThroughTheCoordinator() async throws {
        let r = Rig(); var types: [String] = []
        r.service.eventSink = { types.append($0.type) }
        let s = r.coordinator.begin(suggestedName: "e.bin", sourceURL: URL(string: "https://a.org/e"), cancel: {})
        r.service.publishChanges()
        try Data([1]).write(to: s.destination)
        r.coordinator.finish(s.id, source: nil)
        r.service.publishChanges()
        XCTAssertTrue(types.contains("task.created") || types.contains("task.started"))
        XCTAssertTrue(types.contains("task.completed"))
    }

    func testNoEventCarriesAnAddressOrAName() throws {
        let e = AutomationEvent(id: 1, type: "task.created", taskID: UUID().uuidString, state: "queued", fraction: nil, bytesReceived: 0, sourceHost: "h.org", profile: "p", at: Date())
        let text = String(data: try AutomationJSON.encoder.encode(e), encoding: .utf8)!
        XCTAssertFalse(text.contains("http")); XCTAssertFalse(text.lowercased().contains("filename")); XCTAssertFalse(text.contains("path"))
    }
}

// MARK: - 6. Webhooks

private final class FakeTransport: WebhookTransport, @unchecked Sendable {
    private let lock = NSLock()
    var posts: [(URL, [String: String], Data)] = []
    var results: [Int?] = []
    func post(_ url: URL, headers: [String: String], body: Data) async -> Int? {
        lock.lock(); posts.append((url, headers, body)); let r = results.isEmpty ? 200 : results.removeFirst(); lock.unlock(); return r
    }
}

@MainActor
final class AutomationWebhookTests: AutomationTestCase {
    private func hooks(_ t: FakeTransport = FakeTransport()) -> (AutomationWebhooks, MemorySecretVault) {
        let v = MemorySecretVault()
        return (AutomationWebhooks(file: nil, secrets: v, transport: t, sleeper: { _ in }), v)
    }
    private func event(_ type: String = "task.completed") -> AutomationEvent { .init(id: 1, type: type, taskID: UUID().uuidString, state: "completed", fraction: 1, bytesReceived: 5, sourceHost: "h.org", profile: "p", at: Date()) }

    func testNothingIsSentByDefault() async {
        let t = FakeTransport(); let (h, _) = hooks(t)
        XCTAssertTrue(h.endpoints.isEmpty)
        h.enqueue(event()); await h.flush()
        XCTAssertTrue(t.posts.isEmpty)
    }

    func testDestinationRules() {
        func why(_ s: String) -> WebhookDestination.Refusal? { WebhookDestination.validate(URL(string: s)!) }
        XCTAssertNil(why("http://127.0.0.1:9000/in")); XCTAssertNil(why("http://[::1]:9000/in")); XCTAssertNil(why("https://127.0.0.1/in"))
        for s in ["https://hooks.example.org/in", "http://hooks.example.org/in", "http://localhost/in", "https://10.0.0.5/in", "https://192.168.0.2/in", "https://169.254.169.254/in", "http://127.1/in", "http://0x7f.0.0.1/in", "http://2130706433/in", "http://127.0.0.1.nip.io/in"] {
            XCTAssertNotNil(why(s), s)
        }
        XCTAssertEqual(why("http://u:p@127.0.0.1/in"), .credentials)
        XCTAssertEqual(why("http://127.0.0.1/in?key=1"), .query)
        XCTAssertEqual(why("ftp://127.0.0.1/in"), .notWeb)
        XCTAssertEqual(why("file:///etc/passwd"), .notWeb)
    }

    func testSigning() {
        let secret = Data("s3cret".utf8), body = Data("{\"a\":1}".utf8), now = Date()
        let header = WebhookSigner.header(secret: secret, body: body, at: now)
        XCTAssertTrue(WebhookSigner.verify(header: header, secret: secret, body: body, now: now))
        XCTAssertFalse(WebhookSigner.verify(header: header, secret: secret, body: Data("{\"a\":2}".utf8), now: now))
        XCTAssertFalse(WebhookSigner.verify(header: header, secret: Data("other".utf8), body: body, now: now))
        XCTAssertFalse(WebhookSigner.verify(header: header, secret: secret, body: body, now: now.addingTimeInterval(301)), "a captured request is dead after five minutes")
        XCTAssertFalse(WebhookSigner.verify(header: "t=1,v1=00", secret: secret, body: body, now: now))
    }

    func testADeliveryIsSignedAndCarriesNoAddressOrName() async throws {
        let t = FakeTransport(); let (h, vault) = hooks(t)
        guard case .added(let e, let secret) = h.add(URL(string: "http://127.0.0.1:9000/in")!) else { return XCTFail() }
        h.enqueue(event()); await h.flush()
        XCTAssertEqual(t.posts.count, 1); XCTAssertEqual(h.delivered, 1)
        let (url, headers, body) = t.posts[0]
        XCTAssertEqual(url, e.url)
        XCTAssertTrue(WebhookSigner.verify(header: try XCTUnwrap(headers["X-BrowserSetu-Signature"]), secret: Data(secret.utf8), body: body, now: Date()))
        let text = String(data: body, encoding: .utf8)!
        XCTAssertFalse(text.contains("http")); XCTAssertFalse(text.lowercased().contains("file"))
        XCTAssertNotNil(vault.secret(for: e.id))
    }

    func testRetriesAreBoundedAndThenItGivesUp() async {
        let t = FakeTransport(); t.results = [500, nil, 200]
        let (h, _) = hooks(t); _ = h.add(URL(string: "http://127.0.0.1:9000/in")!)
        h.enqueue(event()); await h.flush()
        XCTAssertEqual(t.posts.count, 3); XCTAssertEqual(h.delivered, 1)
        let t2 = FakeTransport(); t2.results = [500, 500, 500, 500, 500]
        let (h2, _) = hooks(t2); _ = h2.add(URL(string: "http://127.0.0.1:9000/in")!)
        h2.enqueue(event()); await h2.flush()
        XCTAssertEqual(t2.posts.count, AutomationWebhooks.maxAttempts); XCTAssertEqual(h2.delivered, 0); XCTAssertEqual(h2.dropped, 1)
    }

    func testTheQueueIsBounded() {
        let (h, _) = hooks(); _ = h.add(URL(string: "http://127.0.0.1:9000/in")!)
        for _ in 0..<150 { h.enqueue(event()) }
        XCTAssertLessThanOrEqual(h.pendingCount, AutomationWebhooks.maxQueue)
        XCTAssertGreaterThanOrEqual(h.dropped, 49)
    }

    func testProgressIsNotSentAndFiltersApply() async {
        let t = FakeTransport(); let (h, _) = hooks(t)
        _ = h.add(URL(string: "http://127.0.0.1:9000/in")!, events: ["task.completed"])
        h.enqueue(event("task.progress")); h.enqueue(event("task.failed")); h.enqueue(event("task.completed")); await h.flush()
        XCTAssertEqual(t.posts.count, 1)
    }

    func testRemovingAnEndpointRemovesItsSecretAndStopsDelivery() async {
        let t = FakeTransport(); let (h, v) = hooks(t)
        guard case .added(let e, _) = h.add(URL(string: "http://127.0.0.1:9000/in")!) else { return XCTFail() }
        h.remove(e.id)
        XCTAssertNil(v.secret(for: e.id)); XCTAssertTrue(h.endpoints.isEmpty)
        h.enqueue(event()); await h.flush(); XCTAssertTrue(t.posts.isEmpty)
    }

    func testTheEndpointFileNeverHoldsTheSecret() throws {
        let file = scratch.appendingPathComponent("hooks.json"); let v = MemorySecretVault()
        let h = AutomationWebhooks(file: file, secrets: v, transport: FakeTransport(), sleeper: { _ in })
        guard case .added(_, let secret) = h.add(URL(string: "http://127.0.0.1:9000/in")!) else { return XCTFail() }
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(secret))
    }

    func testRedirectsAreNeverFollowed() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Automation/AutomationWebhooks.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("willPerformHTTPRedirection") && text.contains("{ nil }"))
        XCTAssertTrue(text.contains("httpCookieStorage = nil"))
    }
}

// MARK: - 7. The real socket

@MainActor
final class AutomationSocketTests: AutomationTestCase {
    private func shortPath() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("p13-\(UUID().uuidString.prefix(6)).sock").path }

    /// A tiny client: connect, send bytes, read until the server closes.
    private func exchange(_ path: String, _ request: String) async -> String? {
        await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard ok == 0 else { return nil }
            var tv = timeval(tv_sec: 5, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(buf, count: n) }
            return String(data: out, encoding: .utf8)
        }.value
    }

    private func http(_ method: String, _ path: String, token: String?, body: String = "") -> String {
        var s = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        if let token { s += "Authorization: Bearer \(token)\r\n" }
        if !body.isEmpty { s += "Content-Type: application/json\r\n" }
        return s + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    func testItRunsOnlyWhenStartedAndAnswersOverTheSocket() async throws {
        let r = Rig(); let t = r.token(read)
        let path = shortPath()
        let transport = AutomationTransport(service: r.service)
        defer { transport.stop() }
        try transport.start(.unix(path: path))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only the owner can open it")
        let ok = await exchange(path, http("GET", "/v1/health", token: t))
        XCTAssertTrue(ok?.hasPrefix("HTTP/1.1 200") == true, ok ?? "no reply")
        let noToken = await exchange(path, http("GET", "/v1/downloads", token: nil))
        XCTAssertTrue(noToken?.hasPrefix("HTTP/1.1 401") == true, noToken ?? "no reply")
        let created = r.coordinator.begin(suggestedName: "s.bin", sourceURL: URL(string: "https://a.org/s"), cancel: {})
        let list = await exchange(path, http("GET", "/v1/downloads", token: t))
        XCTAssertTrue(list?.contains(created.id.uuidString) == true)
        let post = await exchange(path, http("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://a.org/x\"}"))
        XCTAssertTrue(post?.hasPrefix("HTTP/1.1 403") == true, "the read-only client cannot create")
    }

    func testMalformedAndOversizedRequestsOverTheSocket() async throws {
        let r = Rig(); let t = r.token([.downloadsCreate])
        let path = shortPath(); let transport = AutomationTransport(service: r.service); defer { transport.stop() }
        try transport.start(.unix(path: path)); try await Task.sleep(for: .milliseconds(300))
        let garbage = await exchange(path, "NOT HTTP\r\n\r\n")
        XCTAssertTrue(garbage?.hasPrefix("HTTP/1.1 400") == true, garbage ?? "no reply")
        let huge = await exchange(path, http("POST", "/v1/downloads", token: t, body: String(repeating: "a", count: AutomationService.maxBody + 10)))
        XCTAssertTrue(huge?.hasPrefix("HTTP/1.1 413") == true, huge ?? "no reply")
        let json = await exchange(path, http("POST", "/v1/downloads", token: t, body: "{oops"))
        XCTAssertTrue(json?.hasPrefix("HTTP/1.1 400") == true)
        let chunked = await exchange(path, "POST /v1/downloads HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
        XCTAssertTrue(chunked?.hasPrefix("HTTP/1.1 400") == true)
    }

    func testStopClosesTheSocketAndRestartWorks() async throws {
        let r = Rig(); let t = r.token(read)
        let path = shortPath(); let transport = AutomationTransport(service: r.service); defer { transport.stop() }
        try transport.start(.unix(path: path)); try await Task.sleep(for: .milliseconds(300))
        let before = await exchange(path, http("GET", "/v1/health", token: t)); XCTAssertNotNil(before)
        transport.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file is removed")
        let closed = await exchange(path, http("GET", "/v1/health", token: t)); XCTAssertNil(closed)
        // The downloads were not touched by switching it off.
        _ = r.coordinator.begin(suggestedName: "k.bin", sourceURL: URL(string: "https://a.org/k"), cancel: {})
        try transport.start(.unix(path: path)); try await Task.sleep(for: .milliseconds(300))
        let again = await exchange(path, http("GET", "/v1/health", token: t)); XCTAssertTrue(again?.hasPrefix("HTTP/1.1 200") == true)
        XCTAssertEqual(r.coordinator.ledger.records.count, 1)
    }

    func testAStaleSocketIsReplacedButAnythingElseIsLeftAlone() throws {
        let file = scratch.appendingPathComponent("not-a-socket")
        try Data("mine".utf8).write(to: file)
        XCTAssertThrowsError(try AutomationTransport.prepareSocketPath(file.path)) { XCTAssertEqual($0 as? AutomationTransport.StartError, .notASocket) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine", "a file that is not ours is never deleted")
        let r = Rig(started: false)
        XCTAssertThrowsError(try AutomationTransport(service: r.service).start(.unix(path: "/" + String(repeating: "a", count: 120)))) { XCTAssertEqual($0 as? AutomationTransport.StartError, .pathTooLong) }
    }

    func testAStreamOverTheSocketDeliversEventsAndEndsWhenSwitchedOff() async throws {
        let r = Rig(); let t = r.token(read)
        let path = shortPath(); let transport = AutomationTransport(service: r.service); defer { transport.stop() }
        try transport.start(.unix(path: path)); try await Task.sleep(for: .milliseconds(300))
        async let reply = exchange(path, http("GET", "/v1/events", token: t))
        try await Task.sleep(for: .milliseconds(500))
        let s = r.coordinator.begin(suggestedName: "ev.bin", sourceURL: URL(string: "https://a.org/ev"), cancel: {})
        r.service.publishChanges()
        try Data([1]).write(to: s.destination)
        r.coordinator.finish(s.id, source: nil)
        r.service.publishChanges()
        try await Task.sleep(for: .milliseconds(300))
        r.service.stop()
        let text = await reply
        XCTAssertTrue(text?.contains("text/event-stream") == true, text ?? "no reply")
        XCTAssertTrue(text?.contains("event: task.completed") == true, text ?? "no reply")
        XCTAssertFalse(text?.contains("a.org/ev") == true, "no address in the stream")
    }
}

// MARK: - 8. CLI and scope

@MainActor
final class AutomationCLIAndScopeTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var script: String { (try? String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/bsetu-downloads"), encoding: .utf8)) ?? "" }
    private func src(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Shared/Downloads/Automation/" + file), encoding: .utf8) }

    func testTheCLIKeepsTheTokenOffTheCommandLine() {
        XCTAssertFalse(script.isEmpty)
        XCTAssertFalse(script.contains("--token"))
        XCTAssertFalse(script.contains("-H \"Authorization"), "the header must not be on curl's argument list")
        XCTAssertTrue(script.contains("-K -"), "the credential is handed to curl on standard input")
        XCTAssertTrue(script.contains("BSETU_TOKEN_FILE"))
        XCTAssertTrue(script.contains("--unix-socket"))
    }

    func testTheCLIMapsEachCommandToOneRequest() throws {
        let expected: [(String, String)] = [
            ("list", "GET /v1/downloads"), ("list running", "GET /v1/downloads?state=running"), ("status abc", "GET /v1/downloads/abc"),
            ("pause abc", "POST /v1/downloads/abc/pause"), ("resume abc", "POST /v1/downloads/abc/resume"), ("cancel abc", "POST /v1/downloads/abc/cancel"),
            ("retry abc", "POST /v1/downloads/abc/retry"), ("queues list", "GET /v1/queues"), ("queues hold", "POST /v1/queues/default/hold"),
            ("queues release", "POST /v1/queues/default/release"), ("stats", "GET /v1/stats"), ("downloads list", "GET /v1/downloads"), ("events", "GET /v1/events"), ("capabilities", "GET /v1/capabilities"),
        ]
        let url = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/bsetu-downloads")
        for (args, line) in expected {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [url.path] + args.split(separator: " ").map(String.init)
            p.environment = ["BSETU_DRY_RUN": "1", "PATH": "/usr/bin:/bin"]
            let out = Pipe(); p.standardOutput = out
            do { try p.run() } catch { throw XCTSkip("This environment does not let the tests start a shell: \(error)") }
            p.waitUntilExit()
            XCTAssertEqual((String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), line, args)
        }
    }

    func testTheServiceNeverStartsTransfersItself() throws {
        let service = try src("AutomationService.swift")
        for forbidden in ["scheduler.enqueue", "startScheduledItem", "http.start", "torrents.", "ed2k.", "TorrentRunner", "ED2KRunner", "untrustedRequestsEnabled =", "URLSession", "WKDownload"] {
            XCTAssertFalse(service.contains(forbidden), forbidden)
        }
        XCTAssertEqual(service.components(separatedBy: ".scheduleDownload(").count - 1, 1, "the one place a download is made is the person's approval")
    }

    func testNothingInTheAutomationCodeReadsCookiesHeadersOrSecretsFromTheBrowser() throws {
        for file in ["AutomationService.swift", "AutomationModels.swift", "AutomationEvents.swift", "AutomationClients.swift"] {
            let text = try src(file)
            // The client store may use the Keychain for exactly one thing: the record of withdrawn access (KeychainBackedDenyStore). Nothing else in these files may.
            let allowedKeychain = file == "AutomationClients.swift"
            for forbidden in ["httpCookieStore", "proxyCredentials", "UserDefaults"] + (allowedKeychain ? [] : ["Keychain", "SecretStore"]) { XCTAssertFalse(text.contains(forbidden), "\(file) \(forbidden)") }
            if allowedKeychain { XCTAssertEqual(text.components(separatedBy: "SecretStore.").count - 1, 3, "only the deny store's read, write and set-aside touch it") }
        }
    }

    func testTheSocketNeverListensOnAnyInterfaceButLoopbackAndTheTCPPathIsUnused() throws {
        let t = try src("AutomationTransport.swift")
        XCTAssertTrue(t.contains("requiredInterfaceType = .loopback") && t.contains("127.0.0.1"))
        XCTAssertFalse(t.contains("0.0.0.0"))
        let controller = try src("AutomationController.swift")
        XCTAssertFalse(controller.contains(".loopback(port"), "the shipped app only uses the Unix socket; TCP is code that is not switched on")
    }

    func testMCPIsDeferredAndDocumentedSo() throws {
        let doc = try String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/download-automation.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("MCP") && doc.lowercased().contains("deferred"))
    }
}

// MARK: - 9. Fixes from the independent review

@MainActor
final class AutomationReviewFixTests: AutomationTestCase {
    func testEveryEndpointOutsideReadingNeedsItsOwnScope() async {
        let r = Rig(); let reader = r.token(read, name: "reader")
        let s = r.coordinator.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a"), cancel: {})
        let id = s.id.uuidString
        let needsMore: [(String, String, String?)] = [
            ("POST", "/v1/downloads", "{\"url\":\"https://a.org/x\"}"), ("POST", "/v1/downloads:batch", "{\"action\":\"cancel\",\"ids\":[\"\(id)\"]}"),
            ("POST", "/v1/queues/default/hold", nil), ("POST", "/v1/queues/default/release", nil), ("GET", "/v1/queues", nil), ("GET", "/v1/settings", nil),
            ("POST", "/v1/downloads/\(id)/pause", nil), ("POST", "/v1/downloads/\(id)/resume", nil), ("POST", "/v1/downloads/\(id)/cancel", nil),
            ("POST", "/v1/downloads/\(id)/retry", nil), ("POST", "/v1/downloads/\(id)/priority", "{\"priority\":\"high\"}"),
            ("POST", "/v1/downloads/\(id)/schedule", "{\"startAt\":\"2030-01-01T00:00:00Z\"}"), ("POST", "/v1/downloads/\(id)/trash-file", nil),
        ]
        for (m, p, b) in needsMore { let x = await r.call(m, p, token: reader, body: b); XCTAssertEqual(r.code(x), "missing_scope", "\(m) \(p)") }
        let queuesOnly = r.token([.queuesRead], name: "q")
        for p in ["/v1/downloads", "/v1/downloads/\(id)", "/v1/proposals", "/v1/stats", "/v1/capabilities", "/v1/events"] {
            let x = await r.call("GET", p, token: queuesOnly); XCTAssertEqual(r.code(x), "missing_scope", p)
        }
        XCTAssertNotEqual(r.coordinator.ledger.record(s.id)?.state, .cancelled)
    }

    func testPrivateIdsCannotBeActedOnByAnyRoute() async {
        let r = Rig(); let t = r.token([.downloadsRead, .downloadsControl, .downloadsFiles])
        let p = r.coordinator.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {}, suspend: { done in done(Data([1])) })
        let id = p.id.uuidString
        for a in ["pause", "resume", "cancel", "retry", "priority", "schedule", "trash-file"] {
            let x = await r.call("POST", "/v1/downloads/\(id)/\(a)", token: t, body: "{\"priority\":\"high\",\"startAt\":\"2030-01-01T00:00:00Z\"}"); XCTAssertEqual(x.status, 404, a)
        }
        let batch = await r.call("POST", "/v1/downloads:batch", token: t, body: "{\"action\":\"cancel\",\"ids\":[\"\(id)\"]}")
        XCTAssertEqual(((batch.json as? [[String: Any]])?.first?["code"] as? String), "not_found")
        XCTAssertNotEqual(r.coordinator.ledger.record(p.id)?.state, .cancelled)
        var types: [String] = []; r.service.eventSink = { types.append($0.type) }
        r.service.publishChanges()
        r.coordinator.cancel(p.id); r.service.publishChanges()
        XCTAssertTrue(types.isEmpty, "a private task produces no event")
    }

    func testNumericHostSpellingsAreRefused() async {
        let r = Rig(); let t = r.token([.downloadsCreate])
        for host in ["127.1", "0x7f.0.0.1", "0177.0.0.1", "2130706433", "0x7f000001", "1.2.3", "010.1.1.1"] {
            let x = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"http://\(host)/x\"}")
            XCTAssertEqual(r.code(x), "destination_not_allowed", host)
        }
        let fine = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://93.184.216.34/x\"}"); XCTAssertEqual(fine.status, 202)
        let name = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://1e100.net/x\"}"); XCTAssertEqual(name.status, 202, "a real name that starts with a digit is fine")
    }

    func testOneClientCannotFillTheWaitingList() async {
        let r = Rig(); let a = r.token([.downloadsCreate], name: "a"), b = r.token([.downloadsCreate], name: "b")
        var last = ""
        for i in 0..<(AutomationService.maxProposalsPerClient + 1) {
            r.advance(1)
            last = r.code(await r.call("POST", "/v1/downloads", token: a, body: "{\"url\":\"https://files.example.org/\(i).zip\"}")) ?? "ok"
        }
        XCTAssertEqual(last, "too_many_proposals")
        let other = await r.call("POST", "/v1/downloads", token: b, body: "{\"url\":\"https://files.example.org/b.zip\"}"); XCTAssertEqual(other.status, 202)
    }

    func testOldProposalsFallAway() async {
        let r = Rig(); let t = r.token([.downloadsCreate])
        _ = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/old.zip\"}")
        r.advance(86_400 + 60)
        _ = await r.call("POST", "/v1/downloads", token: t, body: "{\"url\":\"https://files.example.org/new.zip\"}")
        XCTAssertEqual(r.service.proposals.count, 1)
        XCTAssertEqual(r.service.proposals.first?.url.lastPathComponent, "new.zip")
    }

    func testChangingACredentialOrPermissionEndsItsStreams() async {
        let r = Rig()
        for change in ["rotate", "scopes", "revoke", "remove"] {
            let t = r.token(read, name: change); let id = String(t.split(separator: "_")[1])
            guard case .stream(let sub) = await r.call("GET", "/v1/events", token: t).reply else { return XCTFail() }
            switch change {
            case "rotate": _ = r.store.rotate(id)
            case "scopes": r.store.setScopes(id, [.queuesRead])
            case "revoke": r.store.revoke(id)
            default: r.store.remove(id)
            }
            XCTAssertTrue(sub.isClosed, change)
        }
    }

    func testAMalformedHoldBodyIsRefusedNotTreatedAsForever() async {
        let r = Rig(); let t = r.token([.queuesControl])
        let x = await r.call("POST", "/v1/queues/default/hold", token: t, body: "{nope")
        XCTAssertEqual(r.code(x), "bad_json"); XCTAssertFalse(r.coordinator.scheduler.isHeld)
    }

    func testAnExpiredIdempotencyEntryDoesNotEvictAFreshOne() async {
        let r = Rig(); let t = r.token([.downloadsCreate])
        let json = "{\"url\":\"https://files.example.org/a.zip\"}"
        _ = await r.call("POST", "/v1/downloads", token: t, body: json, headers: ["idempotency-key": "key-aaaa-1111"])
        r.advance(3601)
        let again = await r.call("POST", "/v1/downloads", token: t, body: json, headers: ["idempotency-key": "key-aaaa-1111"])
        XCTAssertEqual(again.status, 202)
    }

    func testTheAuditTrailDoesNotRecordWhatACallerTyped() async {
        let r = Rig(); let t = r.token(read)
        _ = await r.call("GET", "/v1/downloads/aaaa-secret-looking-text", token: t)
        _ = await r.call("GET", "/v1/whatever-i-like", token: t)
        let all = r.service.audit.map(\.action).joined()
        XCTAssertFalse(all.contains("secret-looking")); XCTAssertFalse(all.contains("whatever"))
    }

    func testAFolderCannotBeTrashedThroughTheFilesScope() async throws {
        let r = Rig(); let t = r.token([.downloadsFiles])
        let s = r.coordinator.begin(suggestedName: "d.bin", sourceURL: URL(string: "https://a.org/d"), cancel: {})
        try Data([1]).write(to: s.destination); r.coordinator.finish(s.id, source: nil)
        r.coordinator.ledger.update(s.id) { $0.file.destinationPath = DownloadCoordinator.directory.path }
        let x = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/trash-file", token: t)
        XCTAssertEqual(r.code(x), "path_not_allowed"); XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
    }
}

@MainActor
final class AutomationSocketReviewTests: AutomationTestCase {
    private func shortPath() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("p13-\(UUID().uuidString.prefix(6)).sock").path }

    nonisolated private func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    private func listeningSocket(_ path: String, keep: Bool) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        if !keep { close(fd); return nil }
        return fd
    }

    func testADroppedStreamFreesItsConnectionAndItsSlot() async throws {
        let r = Rig(); let t = r.token(read)
        let path = shortPath(); let transport = AutomationTransport(service: r.service); defer { transport.stop() }
        try transport.start(.unix(path: path)); try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<4 {
            // The client runs off the main thread, as a real tool would; the service answers on the main actor.
            let answer = await Task.detached { [self] () -> String in
                guard let fd = self.connect(path) else { return "no connection" }
                let req = "GET /v1/events HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\nContent-Length: 0\r\n\r\n"
                _ = req.withCString { send(fd, $0, strlen($0), 0) }
                var buf = [UInt8](repeating: 0, count: 256); var tv = timeval(tv_sec: 3, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let got = recv(fd, &buf, buf.count, 0)
                close(fd)                                                // Ctrl-C
                return String(decoding: buf.prefix(max(0, got)), as: UTF8.self)
            }.value
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200"), answer)
        }
        for _ in 0..<100 where !(r.service.events.subscribers.isEmpty && transport.connectionCount == 0) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(r.service.events.subscribers.isEmpty, "the slots are free again")
        XCTAssertEqual(transport.connectionCount, 0, "and so are the connections")
        guard case .stream(let sub) = await r.call("GET", "/v1/events", token: t).reply else { return XCTFail("a new stream is accepted") }
        sub.close()
    }

    func testAStaleSocketIsReplacedAndALiveOneIsNotTakenOver() async throws {
        let r = Rig(started: false)
        let stale = shortPath()
        _ = listeningSocket(stale, keep: false)                          // bound, then closed without removing the file: what a crash leaves
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale))
        XCTAssertNoThrow(try AutomationTransport.prepareSocketPath(stale))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale), "the stale one is removed")
        let live = shortPath()
        let fd = try XCTUnwrap(listeningSocket(live, keep: true)); defer { close(fd); unlink(live) }
        XCTAssertThrowsError(try AutomationTransport.prepareSocketPath(live), "a socket that still answers is not taken over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live))
        _ = r
    }

    func testALooserFolderIsTightened() throws {
        let folder = scratch.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try AutomationTransport.prepareSocketPath(folder.appendingPathComponent("x.sock").path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
