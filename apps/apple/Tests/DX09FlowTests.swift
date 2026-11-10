import XCTest
@testable import Browser_Setu

// DX-09 closure: the operations the browser's provider panel drives (ProviderFlow), the TikTok export model, and the archive check — run against the local fixture server through the real
// DownloadCoordinator. The windows themselves (SwiftUI) are compiled but not clicked; these tests stand in for what the buttons call.

struct SlowAPI: ProviderAPI {
    let json: String
    let delay: Double
    func data(_ url: URL, method: String, body: Data?, bearer: String?, extraHeaders: [String: String]) async throws -> Data {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return Data(json.utf8)
    }
    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) { throw ProviderFailure.malformed("none") }
}

/// An API whose first answer is held until the test lets it go; later answers come at once. `entered` opens when the first request is in flight.
final class GatedAPI: ProviderAPI, @unchecked Sendable {
    let first: String, later: String
    let entered = AsyncGate(), release = AsyncGate()
    private let lock = NSLock()
    private var calls = 0
    init(first: String, later: String) { self.first = first; self.later = later }
    func data(_ url: URL, method: String, body: Data?, bearer: String?, extraHeaders: [String: String]) async throws -> Data {
        lock.lock(); calls += 1; let n = calls; lock.unlock()
        if n == 1 { await entered.open(); await release.wait(); return Data(first.utf8) }
        return Data(later.utf8)
    }
    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) { throw ProviderFailure.malformed("none") }
}

final class DX09ArchiveTests: XCTestCase {
    func file(_ data: Data) throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("dx09-\(UUID().uuidString)"); try data.write(to: u); return u }
    func testOnlyAWholeZipPasses() throws {
        var zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 100) + Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 18)
        XCTAssertEqual(ArchiveCheck.inspect(try file(zip)), .zip)
        XCTAssertEqual(ArchiveCheck.inspect(try file(Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 18))), .zip, "an empty archive")
        zip.removeLast(40)
        XCTAssertEqual(ArchiveCheck.inspect(try file(zip)), .notAnArchive, "cut short: no end record")
        XCTAssertEqual(ArchiveCheck.inspect(try file(Data("this is not a zip".utf8))), .notAnArchive)
        XCTAssertEqual(ArchiveCheck.inspect(try file(Data("{\"error\":{\"code\":\"invalid_params\",\"message\":\"Incorrect request_id\"}}".utf8))), .apiError("invalid_params: Incorrect request_id"))
        XCTAssertEqual(ArchiveCheck.inspect(try file(Data("{}".utf8))), .notAnArchive)
        XCTAssertEqual(ArchiveCheck.inspect(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")), .notAnArchive)
    }
    func testTheMachineAllowsTheMovesTheFlowMakes() {
        XCTAssertTrue(ProviderOperationState.identifying.canMove(to: .authorizationRequired))
        XCTAssertTrue(ProviderOperationState.identifying.canMove(to: .ready))
        XCTAssertTrue(ProviderOperationState.ready.canMove(to: .refreshRequired)); XCTAssertTrue(ProviderOperationState.refreshRequired.canMove(to: .resolving)); XCTAssertTrue(ProviderOperationState.resolving.canMove(to: .ready))
    }
}

@MainActor
final class DX09FlowTests: MediaCase {
    let payload = Data((0..<20_000).map { UInt8(($0 * 11 + 5) % 251) })
    var vimeoBase: URL { url("/media/vimeo") }
    var profileName = "default"
    var pageURL = URL(string: "https://vimeo.com/123456")!
    var isPrivate = false
    var token: String? = "tok"

    override func setUp() async throws { try await super.setUp(); ProviderSourceCheck.allowLocalForTests = true; profileName = "dx09f-\(UUID().uuidString)" }
    override func tearDown() async throws {
        ProviderSourceCheck.allowLocalForTests = false
        ProviderCredentials.revoke(.vimeo, profile: profileName); ProviderCredentials.revoke(.tiktok, profile: c.ledger.profile)
        UserDefaults.standard.removeObject(forKey: "bs.tiktok.export." + c.ledger.profile)
        try await super.tearDown()
    }

    func resolverNow(api: ProviderAPI?, useStoredToken: Bool) -> ProviderResolver {
        let base = vimeoBase
        let current = token
        let real = FetcherProviderAPI(provider: .vimeo, network: DownloadNetworkSetup(), hostOverride: "127.0.0.1", origin: .user)
        let chosenAPI: ProviderAPI = api ?? real
        let adapters: @Sendable (MediaProviderID) -> MediaSiteAdapter = { id in id == .vimeo ? VimeoAdapter(base: base) : ProviderRegistry.adapter(for: id) }
        let tokens: @Sendable (MediaProviderID, String) -> String?
        if useStoredToken { tokens = { (p: MediaProviderID, profile: String) -> String? in ProviderCredentials.token(p, profile: profile) } }
        else { tokens = { (_: MediaProviderID, _: String) -> String? in current } }
        return ProviderResolver(api: { _ in chosenAPI }, adapter: adapters, token: tokens)
    }

    func makeFlow(api: ProviderAPI? = nil, useStoredToken: Bool = false) -> ProviderFlow {
        let flow = ProviderFlow(coordinator: { [unowned self] in self.c }, profile: { [unowned self] in self.profileName }, activePage: { [unowned self] in (self.pageURL, self.isPrivate) })
        let resolver = resolverNow(api: api, useStoredToken: useStoredToken)
        flow.makeResolver = { _ in resolver }
        flow.watchInterval = .milliseconds(100)
        return flow
    }
    func publishVimeo(file: String, size: Int? = nil, md5: String = "m1") async throws {
        try await put("vimeo/videos/123456", text: """
        {"name":"Owner clip","duration":10,"privacy":{"download":true},"download":[{"quality":"hd","type":"source","width":1280,"height":720,"link":"\(file)","size":\(size ?? payload.count),"md5":"\(md5)","public_name":"Original","expires":"2099-01-01T00:00:00Z"}]}
        """)
    }
    func ctx() -> MediaPageContext { MediaPageContext(pageURL: pageURL, profile: profileName, isPrivate: isPrivate) }
    func until(_ seconds: Double = 20, _ f: @escaping () -> Bool) async -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if f() { return true }; try? await Task.sleep(for: .milliseconds(50)) }; return f() }

    // MARK: ProviderFlow

    func testResolveStartAndFinishThroughTheFlow() async throws {
        try await put("vimeo/f1.bin", payload); try await publishVimeo(file: url("/media/vimeo/f1.bin").absoluteString)
        let flow = makeFlow()
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready, "\(String(describing: flow.entry(for: ctx())))")
        let source = try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first)
        let id = try await flow.start(source, in: ctx(), name: "Flow.bin", origin: .user)
        let again = try await flow.start(source, in: ctx(), name: "Flow.bin", origin: .user)
        XCTAssertEqual(again, id, "the same source is not started twice while it runs")
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record!.file.destinationPath!)), payload)
    }

    func testAuthorizationIsRequiredThenGiven() async throws {
        try await put("vimeo/f2.bin", payload); try await publishVimeo(file: url("/media/vimeo/f2.bin").absoluteString)
        let flow = makeFlow(useStoredToken: true)
        flow.resolve(ctx())
        let needs = await until { flow.entry(for: self.ctx())?.state == .authorizationRequired }
        XCTAssertTrue(needs)
        XCTAssertTrue(ProviderCredentials.store("tok-\(UUID().uuidString)", .vimeo, profile: profileName))
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready)
        ProviderCredentials.revoke(.vimeo, profile: profileName)
        // revoked: the next lookup asks again, and a started-from-stale source is refused
        flow.resolve(ctx())
        let again = await until { flow.entry(for: self.ctx())?.state == .authorizationRequired }
        XCTAssertTrue(again)
    }

    func json(_ title: String) -> String { "{\"name\":\"\(title)\",\"download\":[{\"quality\":\"hd\",\"link\":\"https://player.vimeo.com/a.mp4\",\"size\":5,\"public_name\":\"Original\",\"expires\":\"2099-01-01T00:00:00Z\"}]}" }

    func testACancelledLookupNeverComesBackAndAReplacedOneKeepsTheNewerResult() async throws {
        // Cancelled while the request is in flight (held by a gate, not by a delay).
        let held = GatedAPI(first: json("old"), later: json("new"))
        let flow = makeFlow(api: held)
        flow.resolve(ctx())
        await held.entered.wait()
        flow.cancel(ctx())
        await held.release.open()
        await flow.quiesce()
        XCTAssertEqual(flow.entry(for: ctx())?.state, .cancelled, "the late answer did not bring it back")
        XCTAssertNil(flow.entry(for: ctx())?.resolution)
        // Replaced: the first lookup is held, the second finishes, then the first is let go: its answer is the stale one.
        let again = GatedAPI(first: json("old"), later: json("new"))
        let flow2 = makeFlow(api: again)
        flow2.resolve(ctx())
        await again.entered.wait()
        flow2.resolve(ctx())
        await flow2.settle(ctx())
        XCTAssertEqual(flow2.entry(for: ctx())?.state, .ready)
        await again.release.open()
        await flow2.quiesce()
        XCTAssertEqual(flow2.entry(for: ctx())?.resolution?.sources.first?.title, "new", "the replaced lookup's late answer was dropped")
        // A cancelled operation cannot start anything.
        let source = try XCTUnwrap(flow2.entry(for: ctx())?.resolution?.sources.first)
        flow2.cancel(ctx())
        do { _ = try await flow2.start(source, in: ctx(), name: "x.mp4", origin: .user); XCTFail("started from a cancelled operation") } catch let e as ProviderFlow.StartError { XCTAssertEqual(e, .notReady) }
        XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testAnOperationCancelledWhileTheEngineAcceptsTheStartLeavesNoRunningDownload() async throws {
        try await publishVimeo(file: url("/throttle/\(8 << 20)?bps=100000").absoluteString)             // slow enough that it cannot finish during the test
        let flow = makeFlow()
        flow.resolve(ctx())
        await flow.settle(ctx())
        XCTAssertEqual(flow.entry(for: ctx())?.state, .ready)
        let source = try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first)
        let context = ctx()
        flow.afterRouterStart = { flow.cancel(context) }           // the operation is cancelled after the engine has accepted the start, before the flow re-checks it
        do { _ = try await flow.start(source, in: context, name: "Orphan.bin", origin: .user); XCTFail("a cancelled operation started a download") }
        catch let e as ProviderFlow.StartError { XCTAssertEqual(e, .stale) }
        let records = Array(c.ledger.records.values)
        XCTAssertEqual(records.count, 1, "the engine did create the task…")
        XCTAssertTrue(records.allSatisfy { $0.state == .cancelled || $0.state.isFinal && $0.state != .completed }, "…and the flow cancelled it: \(records.map(\.state))")
        XCTAssertTrue(visibleFiles().isEmpty)
    }

    func testAProfileOrPageChangeStopsAStartAndDropsAResult() async throws {
        try await put("vimeo/f3.bin", payload); try await publishVimeo(file: url("/media/vimeo/f3.bin").absoluteString)
        let flow = makeFlow()
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready)
        let source = try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first)
        let original = pageURL
        pageURL = URL(string: "https://vimeo.com/999")!
        do { _ = try await flow.start(source, in: MediaPageContext(pageURL: original, profile: profileName), name: "x", origin: .user); XCTFail("started after the page changed") } catch let e as ProviderFlow.StartError { XCTAssertEqual(e, .stale) }
        pageURL = original
        // a result for a profile that is no longer in front is dropped
        let slow = makeFlow(api: SlowAPI(json: "{\"download\":[{\"link\":\"https://player.vimeo.com/a.mp4\",\"size\":5,\"quality\":\"hd\"}]}", delay: 0.4))
        let before = profileName
        slow.resolve(ctx())
        profileName = "someone-else"
        try await Task.sleep(for: .milliseconds(900))
        profileName = before
        XCTAssertNotEqual(slow.entry(for: ctx())?.state, .ready, "the answer arrived for another profile")
        // a private tab is never given the account's token
        isPrivate = true
        let priv = makeFlow(useStoredToken: true)
        XCTAssertTrue(ProviderCredentials.store("tok-\(UUID().uuidString)", .vimeo, profile: profileName))
        priv.resolve(ctx())
        let stays = await until { priv.entry(for: self.ctx())?.state == .authorizationRequired }
        XCTAssertTrue(stays)
    }

    func testTheFlowRenewsAnExpiredLinkItself() async throws {
        try await put("vimeo/f4.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/f4.bin?status=403").absoluteString)
        let flow = makeFlow()
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready)
        let source = try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first)
        let id = try await flow.start(source, in: ctx(), name: "Auto.bin", origin: .user)
        _ = await wait(id, for: [.failed, .completed])
        try await publishVimeo(file: url("/media/vimeo/f4.bin").absoluteString)           // the provider now gives the same file a fresh link
        let done = await wait(id, for: [.completed], seconds: 30)
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(flow.entry(for: ctx())?.renewals, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: done!.file.destinationPath!)), payload)
    }

    func testARenewalToAnotherFileShowsAFailureAndLeavesTheTask() async throws {
        try await put("vimeo/f5.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/f5.bin?status=403").absoluteString)
        let flow = makeFlow()
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready)
        let id = try await flow.start(try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first), in: ctx(), name: "Other.bin", origin: .user)
        _ = await wait(id, for: [.failed, .completed])
        try await publishVimeo(file: url("/media/vimeo/f5.bin").absoluteString, size: payload.count + 1, md5: "other")
        let failed = await until { if case .failed = flow.entry(for: self.ctx())?.state { return true }; return false }
        XCTAssertTrue(failed, "\(String(describing: flow.entry(for: ctx())?.state))")
        XCTAssertEqual(c.ledger.record(id)?.state, .failed)
    }

    func testAVimeoLinkThatRedirectsToItsStorageWorksAndNoTokenFollows() async throws {
        try await put("vimeo/f6.bin", payload)
        let target = url("/media/vimeo/f6.bin").absoluteString
        try await publishVimeo(file: url("/media/vimeo/hop.bin?redirect=\(target)").absoluteString)
        try await put("vimeo/hop.bin", Data("x".utf8))
        let flow = makeFlow()
        flow.resolve(ctx())
        let ready = await until { flow.entry(for: self.ctx())?.state == .ready }
        XCTAssertTrue(ready)
        let id = try await flow.start(try XCTUnwrap(flow.entry(for: ctx())?.resolution?.sources.first), in: ctx(), name: "Hop.bin", origin: .user)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record!.file.destinationPath!)), payload)
        let a = (await lastHeaders("vimeo/hop.bin"))["authorization"], b = (await lastHeaders("vimeo/f6.bin"))["authorization"]
        XCTAssertNil(a); XCTAssertNil(b)
    }

    func testARestrictedSiteHasNoSourcesAndNothingToStart() async throws {
        pageURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let flow = makeFlow()
        flow.resolve(ctx())
        let restricted = await until { if case .restricted = flow.entry(for: self.ctx())?.state { return true }; return false }
        XCTAssertTrue(restricted)
        XCTAssertTrue(flow.entry(for: ctx())?.resolution?.sources.isEmpty == true)
        let fake = AuthorizedMediaSource(provider: .youtube, mediaID: "dQw4w9WgXcQ", url: URL(string: "https://example.com/a.mp4")!, type: .directFile, profile: profileName, scope: "x", expiresAt: nil, contentType: nil, quality: nil, width: nil, height: nil, bytes: 1, md5: nil, title: nil, canRefresh: false)
        do { _ = try await flow.start(fake, in: ctx(), name: "x", origin: .user); XCTFail("a restricted provider's media was started") } catch let e as ProviderFlow.StartError { XCTAssertEqual(e, .notReady) }
        XCTAssertTrue(c.ledger.records.isEmpty)
    }

    // MARK: TikTok export

    func tiktok() -> TikTokExportModel {
        let m = TikTokExportModel(profile: c.ledger.profile, coordinator: { [unowned self] in self.c })
        m.base = url("/tt/v2/user/data/")
        m.apiFactory = { FetcherProviderAPI(provider: .tiktok, network: $0.http.engine.currentNetwork, hostOverride: "127.0.0.1", origin: .user) }
        return m
    }

    func testTheWholeExportFlowAgainstThePortabilityShapedFixture() async throws {
        _ = try await get("/_tt/pending")
        let m = tiktok()
        await m.request(); XCTAssertEqual(m.phase, .needsToken, "no authorization, no request")
        XCTAssertTrue(ProviderCredentials.store("tt-token-12345", .tiktok, profile: c.ledger.profile))
        await m.request()
        XCTAssertEqual(m.phase, .pending); XCTAssertEqual(m.requestID, "123451234512345")
        await m.check(); XCTAssertEqual(m.phase, .pending)
        // relaunch: a new model for the same profile remembers the request
        let reborn = tiktok()
        XCTAssertEqual(reborn.requestID, "123451234512345"); XCTAssertEqual(reborn.phase, .pending)
        _ = try await get("/_tt/downloading")
        await reborn.check(); XCTAssertEqual(reborn.phase, .ready)
        await reborn.download()
        guard case .done(let name) = reborn.phase else { return XCTFail("\(reborn.phase)") }
        let saved = downloads.appendingPathComponent(name)
        XCTAssertEqual(ArchiveCheck.inspect(saved), .zip)
        XCTAssertEqual(c.ledger.records.values.filter { $0.state == .completed }.count, 1, "it went through the Downloads lifecycle")
        XCTAssertEqual(segmentFolders(), [], "no staging left behind")
    }

    func testTheExportReportsEveryDocumentedAndFailureState() async throws {
        XCTAssertTrue(ProviderCredentials.store("tt-token-12345", .tiktok, profile: c.ledger.profile))
        let m = tiktok()
        _ = try await get("/_tt/pending"); await m.request()
        _ = try await get("/_tt/expired"); await m.check(); XCTAssertEqual(m.phase, .expired)
        _ = try await get("/_tt/cancelled"); await m.check(); XCTAssertEqual(m.phase, .cancelled)
        _ = try await get("/_tt/noscope"); await m.check()
        if case .ineligible = m.phase {} else { XCTFail("a refused scope is reported as ineligibility, not retried: \(m.phase)") }
        // an error served instead of the archive
        let n = tiktok(); _ = try await get("/_tt/downloading"); await n.check(); XCTAssertEqual(n.phase, .ready)
        _ = try await get("/_tt/jsonerror"); await n.download()
        if case .failed(let why) = n.phase { XCTAssertTrue(why.contains("Incorrect request_id") || why.contains("refused") || why.contains("answer"), why) } else { XCTFail("\(n.phase)") }
        XCTAssertTrue(visibleFiles().isEmpty)
        // a 200 that is JSON, and one that is not a ZIP
        for mode in ["jsonok", "badzip"] {
            _ = try await get("/_tt/downloading"); let k = tiktok(); await k.check(); XCTAssertEqual(k.phase, .ready)
            _ = try await get("/_tt/\(mode)"); await k.download()
            if case .failed = k.phase {} else { XCTFail("\(mode): \(k.phase)") }
        }
        XCTAssertTrue(visibleFiles().isEmpty, "nothing half-made is presented")
        XCTAssertEqual(c.ledger.records.values.filter { $0.state == .completed }.count, 0)
        m.forget(); XCTAssertNil(m.requestID); XCTAssertEqual(tiktok().phase, .idle)
    }

    func testTheExportTokenGoesOnlyToTikTokAndIsRejectedWhenBad() async throws {
        let api = FetcherProviderAPI(provider: .tiktok, network: DownloadNetworkSetup())
        do { _ = try await api.download(URL(string: "https://evil.example.net/v2/user/data/download/")!, body: Data(), bearer: "SECRET", to: root.appendingPathComponent("x.zip"), maxBytes: 100); XCTFail() } catch let e as ProviderFailure { XCTAssertEqual(e, .malformed("an address outside the website's API")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x.zip").path))
    }
}
