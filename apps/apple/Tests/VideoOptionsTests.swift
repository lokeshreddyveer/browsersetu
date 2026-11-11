import XCTest
@testable import Browser_Setu

@MainActor
final class VideoOptionsTests: XCTestCase {
    /// A candidate made the way the app makes one: through the discovery store's own classification.
    private func candidate(_ href: String, element: String, hasVideo: Bool? = nil) -> MediaCandidate {
        let store = MediaDiscoveryStore(profile: "t", isPrivate: false)
        _ = store.ingest(MediaPageSnapshot(hits: [MediaPageHit(href: href, element: element, type: "", duration: 10, drm: false, blob: false, hasVideo: hasVideo)], truncated: false), pageKey: "t|p", pageHost: "x.org", removeMissing: false)
        return store.candidates[0]
    }

    func testHeightNamesNeverExceedPixels() {
        XCTAssertEqual(VideoOptions.heightName(2160), "4K (2160p)"); XCTAssertEqual(VideoOptions.heightName(1080), "1080p"); XCTAssertEqual(VideoOptions.heightName(1079), "720p")
        XCTAssertEqual(VideoOptions.heightName(360), "360p"); XCTAssertNil(VideoOptions.heightName(nil))
    }

    func testEncoderProbeIsHonest() {
        XCTAssertTrue(LocalEncoders.m4a)
        XCTAssertFalse(LocalEncoders.canEncode(0x12345678))
        print("ENCODER mp3 available: \(LocalEncoders.mp3)")
    }

    func testMP3IsListedButDisabledWithReason() {
        let c = candidate("https://x.org/a.m4a", element: "audio")
        let o = VideoOptions.options(for: c, encoders: (true, false))
        XCTAssertEqual(o.first?.kind, .audioOriginal)
        let mp3 = o.first { $0.kind == .audioMP3 }
        XCTAssertNotNil(mp3?.unavailableReason)
        XCTAssertNil(VideoOptions.options(for: c, encoders: (true, true)).first { $0.kind == .audioMP3 }?.unavailableReason)
    }

    func testDirectVideoOffersOriginalOnly() {
        let o = VideoOptions.options(for: candidate("https://x.org/clip.webm", element: "video", hasVideo: true), encoders: (true, false), processing: false)      // independent of any tool installed on this Mac
        XCTAssertEqual(o.first?.title, "Video with sound · WEBM"); XCTAssertEqual(o.first?.provenance, "Source quality")
        XCTAssertFalse(o.first { $0.kind == .audioM4A }!.isAvailable)
    }

    func testConsentScopesAndPrivateRule() {
        let d = UserDefaults(suiteName: "bs.test.consent.\(UUID().uuidString)")!
        let s = MediaConsentStore(defaults: d)
        let svc = MediaConsentPurpose.externalService("Example")
        XCTAssertFalse(s.isAllowed(svc, host: "a.org", profile: "p", isPrivate: false))
        s.grant(svc, scope: .site("a.org"), profile: "p", isPrivate: false)
        XCTAssertTrue(s.isAllowed(svc, host: "a.org", profile: "p", isPrivate: false))
        XCTAssertFalse(s.isAllowed(svc, host: "b.org", profile: "p", isPrivate: false))
        XCTAssertFalse(s.isAllowed(svc, host: "a.org", profile: "other", isPrivate: false), "another profile is not covered")
        XCTAssertFalse(s.isAllowed(svc, host: "a.org", profile: "p", isPrivate: true), "a private tab never shares with a service")
        s.grant(.localConversion, scope: .once, profile: "p", isPrivate: false)
        XCTAssertTrue(s.isAllowed(.localConversion, host: nil, profile: "p", isPrivate: false))
        s.consumeOnce(.localConversion)
        XCTAssertFalse(s.isAllowed(.localConversion, host: nil, profile: "p", isPrivate: false))
        s.revoke(svc, profile: "p")
        XCTAssertFalse(s.isAllowed(svc, host: "a.org", profile: "p", isPrivate: false))
    }

    func testPrivateTabsStoreNothingAndOnceGrantsAreClearable() {
        let d = UserDefaults(suiteName: "bs.test.consent.\(UUID().uuidString)")!
        let s = MediaConsentStore(defaults: d)
        s.grant(.localConversion, scope: .profile, profile: "p", isPrivate: true)
        s.grant(.localConversion, scope: .site("a.org"), profile: "p", isPrivate: true)
        XCTAssertTrue(s.grants(profile: "p").isEmpty, "a private tab writes no grant")
        s.grant(.localConversion, scope: .once, profile: "p", isPrivate: false)
        XCTAssertTrue(s.isAllowed(.localConversion, host: nil, profile: "p", isPrivate: false))
        s.clearOnce()                                              // the sheet closed without using it
        XCTAssertFalse(s.isAllowed(.localConversion, host: nil, profile: "p", isPrivate: false))
    }

    func testOnlyMediaEndingsAreForcedOntoATypedName() {
        XCTAssertTrue(VideoSaveOperation.mediaEndings.contains("mp4")); XCTAssertTrue(VideoSaveOperation.mediaEndings.contains("mp3"))
        XCTAssertFalse(VideoSaveOperation.mediaEndings.contains("php")); XCTAssertFalse(VideoSaveOperation.mediaEndings.contains("m3u8"))
    }

    struct Fake: DownloaderServiceConnector {
        var id = "fake"; var displayName = "Fake"; var documentation: URL? = URL(string: "https://docs.example/api"); var allowedHosts: Set<String> = ["cdn.example"]
        func accepts(_ page: URL) -> Bool { true }
        func inspect(page: URL) async throws -> ConnectorResponse { fatalError() }
    }

    func testConnectorResponseChecks() throws {
        let page = URL(string: "https://site.org/watch/1")!
        func fmt(_ u: String, mime: String? = "video/mp4", expires: Date? = nil, kind: OutputOption.Kind = .video) -> ConnectorFormat { ConnectorFormat(label: "720p", kind: kind, height: 720, url: URL(string: u)!, mime: mime, expires: expires, estimatedBytes: nil) }
        func check(_ r: ConnectorResponse) -> ConnectorFailure? { do { _ = try ConnectorValidator.validate(r, asked: page, connector: Fake()); return nil } catch { return error as? ConnectorFailure } }
        let ok = ConnectorResponse(videoPage: page, formats: [fmt("https://cdn.example/a.mp4")], contentType: "application/json")
        XCTAssertNil(check(ok))
        XCTAssertEqual(check(ConnectorResponse(videoPage: URL(string: "https://site.org/watch/2")!, formats: ok.formats, contentType: nil)), .wrongVideo)
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: [], contentType: nil)), .noFormats)
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: ok.formats, contentType: "text/html")), .htmlInsteadOfData)
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: [fmt("http://cdn.example/a.mp4")], contentType: nil)), .notSecure)
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: [fmt("https://evil.example/a.mp4")], contentType: nil)), .hostNotAllowed("evil.example"))
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: [fmt("https://cdn.example/a.mp4", expires: Date(timeIntervalSinceNow: -5))], contentType: nil)), .expired)
        XCTAssertEqual(check(ConnectorResponse(videoPage: page, formats: [fmt("https://cdn.example/a.mp4", mime: "audio/mpeg")], contentType: nil)), .mimeMismatch("audio/mpeg"))
        XCTAssertTrue(ConnectorRegistry.connectors.isEmpty, "no service is enabled by default")
    }
}

/// A blob: player is not called protected unless the page reports encryption.
final class BlobClassificationTests: XCTestCase {
    func testBlobIsNotDRMAndProtectedIsProtected() {
        let blob = MediaClassifier.classify(MediaPageHit(href: "blob:https://x.org/abc", element: "video", type: "", duration: 10, drm: false, blob: true))
        XCTAssertEqual(blob.kind, .blob)
        if case .unsupported(let why) = blob.state { XCTAssertTrue(why.contains("not DRM")); XCTAssertFalse(why.contains("never downloaded or bypassed")) } else { XCTFail() }
        let drm = MediaClassifier.classify(MediaPageHit(href: nil, element: "video", type: "", duration: 10, drm: true, blob: true))
        XCTAssertEqual(drm.kind, .protected)
    }
}
