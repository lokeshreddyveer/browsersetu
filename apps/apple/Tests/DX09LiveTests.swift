import XCTest
@testable import Browser_Setu

// DX-09: a Vimeo-style authenticated, expiring API answered by the local fixture server (a fixture written from Vimeo's published description, not a recording of Vimeo), with the
// downloads routed through the real DownloadCoordinator.

@MainActor
final class DX09LiveTests: MediaCase {
    let payload = Data((0..<20_000).map { UInt8(($0 * 7 + 3) % 251) })
    var vimeoBase: URL { url("/media/vimeo") }

    override func setUp() async throws {
        try await super.setUp()
        ProviderSourceCheck.allowLocalForTests = true
    }
    override func tearDown() async throws {
        ProviderSourceCheck.allowLocalForTests = false
        try await super.tearDown()
    }

    func resolver(token: String? = "tok") -> ProviderResolver {
        let api = FetcherProviderAPI(provider: .vimeo, network: DownloadNetworkSetup(), hostOverride: "127.0.0.1", origin: .user)
        let base = vimeoBase
        return ProviderResolver(api: { _ in api }, adapter: { id in id == .vimeo ? VimeoAdapter(base: base) : ProviderRegistry.adapter(for: id) }, token: { _, _ in token })
    }
    func page(_ s: String = "https://vimeo.com/123456", profile: String = "default") -> MediaPageContext { MediaPageContext(pageURL: URL(string: s)!, profile: profile) }

    /// The API answer for video 123456: one owner-enabled download whose link is `file`.
    func publishVimeo(file: String, size: Int? = nil, md5: String = "m1", name: String = "Original") async throws {
        try await put("vimeo/videos/123456", text: """
        {"name":"Owner clip","duration":10,"privacy":{"download":true},"download":[{"quality":"hd","type":"source","width":1280,"height":720,"link":"\(file)","size":\(size ?? payload.count),"md5":"\(md5)","public_name":"\(name)","expires":"2099-01-01T00:00:00Z"}]}
        """)
    }

    func testAnAuthorizedDownloadLinkGoesThroughTheHTTPEngineWithoutTheToken() async throws {
        try await put("vimeo/file1.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/file1.bin").absoluteString)
        let r = await resolver().resolve(page())
        XCTAssertEqual(r.state, .ready, r.message ?? ""); XCTAssertEqual(r.sources.count, 1)
        let apiAuth = (await lastHeaders("vimeo/videos/123456"))["authorization"]
        XCTAssertEqual(apiAuth, "Bearer tok", "the API call carried the person's token")
        let id = try await ProviderDownloadRouter.start(r.sources[0], name: "Owner clip.bin", coordinator: c, origin: .user)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record!.file.destinationPath!)), payload)
        let fileAuth = (await lastHeaders("vimeo/file1.bin"))["authorization"]
        XCTAssertNil(fileAuth, "the token is for the API and never goes to the file's address")
    }

    func testAnExpiredLinkIsRenewedToTheSameFileAndTheTaskFinishes() async throws {
        try await put("vimeo/file2.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/file2.bin?status=403").absoluteString)
        let r = await resolver().resolve(page())
        let old = try XCTUnwrap(r.sources.first)
        let id = try await ProviderDownloadRouter.start(old, name: "Renew.bin", coordinator: c, origin: .user)
        let failed = await wait(id, for: [.failed, .completed])
        XCTAssertEqual(failed?.state, .failed, "the stale link is refused by the server")
        try await publishVimeo(file: url("/media/vimeo/file2.bin").absoluteString)             // the same file, a fresh link
        try await ProviderDownloadRouter.renew(taskID: id, old: old, context: page(), resolver: resolver(), coordinator: c)
        let done = await wait(id, for: [.completed], seconds: 30)          // the task is still marked failed until the restart takes hold
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: done!.file.destinationPath!)), payload)
    }

    func testARenewalThatIsADifferentFileIsRefusedAndTheTaskIsLeftAlone() async throws {
        try await put("vimeo/file3.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/file3.bin?status=403").absoluteString)
        let resolved = await resolver().resolve(page())
        let old = try XCTUnwrap(resolved.sources.first)
        let id = try await ProviderDownloadRouter.start(old, name: "Other.bin", coordinator: c, origin: .user)
        _ = await wait(id, for: [.failed, .completed])
        try await publishVimeo(file: url("/media/vimeo/file3.bin").absoluteString, size: payload.count - 1, md5: "m2")          // another video behind the same id
        do { try await ProviderDownloadRouter.renew(taskID: id, old: old, context: page(), resolver: resolver(), coordinator: c); XCTFail("a different file was accepted") }
        catch let e as ProviderSourceCheck.Problem { guard case .differentMedia = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(c.ledger.record(id)?.state, .failed, "untouched")
        XCTAssertEqual(c.ledger.record(id)?.source.asURL?.absoluteString.contains("status=403"), true, "still the old link; nothing was swapped in")
    }

    func testProfilesDoNotShareTokensAndImpersonatorsGetNone() async throws {
        let a = "dx09-live-a-\(UUID().uuidString)", b = "dx09-live-b-\(UUID().uuidString)"
        defer { ProviderCredentials.revoke(.vimeo, profile: a); ProviderCredentials.revoke(.vimeo, profile: b) }
        try await put("vimeo/file4.bin", payload)
        try await publishVimeo(file: url("/media/vimeo/file4.bin").absoluteString)
        XCTAssertTrue(ProviderCredentials.store("tokenA", .vimeo, profile: a))
        let api = FetcherProviderAPI(provider: .vimeo, network: DownloadNetworkSetup(), hostOverride: "127.0.0.1", origin: .user)
        let base = vimeoBase
        let real = ProviderResolver(api: { _ in api }, adapter: { id in id == .vimeo ? VimeoAdapter(base: base) : ProviderRegistry.adapter(for: id) })
        let withToken = await real.resolve(page(profile: a))
        XCTAssertEqual(withToken.state, .ready)
        let seen = await lastHeaders("vimeo/videos/123456")
        XCTAssertEqual(seen["authorization"], "Bearer tokenA")
        let without = await real.resolve(page(profile: b))
        XCTAssertEqual(without.state, .authorizationRequired, "another profile has no authorization")
        let stub = StubAPI()
        let fakeResolver = ProviderResolver(api: { _ in stub }, token: { _, _ in "tok" })
        let fake = await fakeResolver.resolve(page("https://vimeo.com.evil.net/123456"))
        XCTAssertEqual(fake.provider, .generic); XCTAssertEqual(stub.calls, 0, "a lookalike address is never sent to the provider's API or given its token")
    }

    func testAnApiThatRedirectsIsNotFollowedWithTheToken() async throws {
        try await publishVimeo(file: "https://player.vimeo.com/x.mp4")
        let api = FetcherProviderAPI(provider: .vimeo, network: DownloadNetworkSetup(), hostOverride: "127.0.0.1", origin: .user)
        let redirect = url("/media/vimeo/redir?redirect=\(url("/media/vimeo/videos/123456").absoluteString)")
        try await put("vimeo/redir", text: "{}")
        do { _ = try await api.data(redirect, method: "GET", body: nil, bearer: "SECRET", extraHeaders: [:]); XCTFail("followed a redirect with the token") } catch {}
        let hits = await hits()
        XCTAssertNil(hits["vimeo/videos/123456"], "the redirect target was never requested")
    }

    func testAnAuthorizedStreamIsRoutedThroughTheHLSEngine() async throws {
        let master = try await publishHLS("dx9-hls")
        let source = AuthorizedMediaSource(provider: .generic, mediaID: "hls1", url: master, type: .hls, profile: "default", scope: "generic", expiresAt: nil, contentType: nil, quality: nil, width: nil, height: nil, bytes: nil, md5: nil, title: "Stream", canRefresh: false)
        let id = try await ProviderDownloadRouter.start(source, name: "Routed", coordinator: c, request: MediaSelectionRequest(quality: .highest), origin: .user)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.protocolID, .media)
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testAnArchiveIsNeverRoutedAsAnOrdinaryFile() async throws {
        let source = AuthorizedMediaSource(provider: .tiktok, mediaID: "r1", url: url("/media/vimeo/x.zip"), type: .accountArchive, profile: "default", scope: "tiktok:portability", expiresAt: nil, contentType: nil, quality: nil, width: nil, height: nil, bytes: nil, md5: nil, title: nil, canRefresh: false)
        do { _ = try await ProviderDownloadRouter.start(source, name: "x", coordinator: c, origin: .user); XCTFail("an account archive was started as a file") } catch {}
        XCTAssertTrue(c.ledger.records.isEmpty)
    }
}
