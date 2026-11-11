import XCTest
import AVFoundation
@testable import Browser_Setu

/// The bundled extractor (the real yt-dlp executable shipped inside the app) and the versioned media contract. These start the actual program; nothing here is a stand-in.
/// The base app does not embed the tool (it is installed on request), so tests that need the real program point the extractor at the pinned copy in ThirdParty (fetch-bundled-tools.sh).
enum RealTool {
    /// Points the tests at the video tool unpacked in ThirdParty/yt-dlp/bin. The tool is an OPTIONAL DOWNLOAD (docs/decisions/0001), so a checkout without it skips these tests with the reason; the shipped packages
    /// are exercised by MediaToolsPackageScenarioTests (BS_SIGNED_PACKAGES) and HostedPackagesLiveTests (BS_LIVE_HOSTED).
    static func use() throws {
        if !BundledExtractor.isPresent { useFolder() }
        try XCTSkipUnless(BundledExtractor.verify() != nil, "the video tool is not unpacked in ThirdParty/yt-dlp/bin (optional download; see MediaToolsPackageScenarioTests and HostedPackagesLiveTests)")
    }
    private static func useFolder() {
        BundledExtractor.helpersFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ThirdParty/yt-dlp/bin", isDirectory: true)
    }
}

@MainActor
final class BundledExtractorTests: XCTestCase {
    override func setUp() async throws { try await super.setUp(); try RealTool.use() }
    func need() throws -> BundledExtractor.Verified {
        try XCTUnwrap(BundledExtractor.verify(), "the bundled extractor is missing or does not match its pinned digest (run scripts/fetch-bundled-tools.sh)")
    }
    func fixturePage(_ key: String, body: String) async throws -> URL {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:18766/_media/\(key)/page.html")!); r.httpMethod = "PUT"; r.httpBody = Data(body.utf8)
        _ = try await URLSession.shared.data(for: r)
        return URL(string: "http://127.0.0.1:18766/media/\(key)/page.html")!
    }

    // MARK: Discovery, identity, health

    func testTheBundledToolIsFoundVerifiedAndRunsAndReportsItsPinnedVersion() async throws {
        let v = try need()
        XCTAssertEqual(v.manifest.name, "yt-dlp"); XCTAssertTrue(v.identity.hasPrefix("bundled:yt-dlp|"))
        XCTAssertTrue(ExtractorChoice.isAvailable); XCTAssertTrue(ExtractorSettings.useBundled)
        let out = try await ExternalExtractor.run(v.url, arguments: ["--version"], timeout: 30, maxBytes: 4096)
        XCTAssertEqual(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), v.manifest.version, "the program really is the pinned version")
        let c = try ExtractorChoice.resolve()
        XCTAssertTrue(c.bundled); XCTAssertEqual(c.identity, v.identity)
    }

    func testTheFolderDigestMatchesTheManifestAndAnyChangeIsRefused() throws {
        let v = try need()
        XCTAssertEqual(BundledExtractor.treeDigest(of: v.url.deletingLastPathComponent()), v.manifest.treeSHA256, "the app's digest of the embedded folder equals the pinned one (and the script's)")
        // A small folder with a manifest pinning it: verified; one changed byte, a new file, or a changed executable bit: refused.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-tool-\(UUID().uuidString)", isDirectory: true)
        let tool = dir.appendingPathComponent("Resources/Tools/mini", isDirectory: true)
        try FileManager.default.createDirectory(at: tool.appendingPathComponent("_internal"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            BundledExtractor.helpersFolder = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools", isDirectory: true)
            BundledExtractor.manifestURL = Bundle.main.url(forResource: "BundledTools", withExtension: "json")
        }
        let exe = tool.appendingPathComponent("mini"); try "#!/bin/sh\necho 1\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try "lib".write(to: tool.appendingPathComponent("_internal/lib.dat"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: tool.appendingPathComponent("_internal/link").path, withDestinationPath: "lib.dat")
        let digest = try XCTUnwrap(BundledExtractor.treeDigest(of: tool))
        func pin(_ d: String) throws {
            let m = dir.appendingPathComponent("BundledTools.json")
            try JSONSerialization.data(withJSONObject: ["name": "mini", "version": "1", "sha256": "x", "sourceURL": "x", "layout": "onedir", "executable": "mini", "treeSHA256": d]).write(to: m)
            BundledExtractor.helpersFolder = dir.appendingPathComponent("Resources/Tools"); BundledExtractor.manifestURL = m
        }
        try pin(digest); XCTAssertNotNil(BundledExtractor.verify())
        try "lib!".write(to: tool.appendingPathComponent("_internal/lib.dat"), atomically: true, encoding: .utf8)
        XCTAssertNil(BundledExtractor.verify(), "one changed file")
        try "lib".write(to: tool.appendingPathComponent("_internal/lib.dat"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(BundledExtractor.verify())
        try "extra".write(to: tool.appendingPathComponent("_internal/extra.dat"), atomically: true, encoding: .utf8)
        XCTAssertNil(BundledExtractor.verify(), "an added file")
        try FileManager.default.removeItem(at: tool.appendingPathComponent("_internal/extra.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.appendingPathComponent("_internal/lib.dat").path)
        XCTAssertNotNil(BundledExtractor.verify(), "a non-executable file's mode bits other than 'executable' are not part of the pin")
        try FileManager.default.removeItem(at: tool.appendingPathComponent("_internal/link"))
        try FileManager.default.createSymbolicLink(atPath: tool.appendingPathComponent("_internal/link").path, withDestinationPath: "elsewhere")
        XCTAssertNil(BundledExtractor.verify(), "a link pointing somewhere else")
    }

    // MARK: Real output, parsed

    func testTheRealToolsOwnOutputParsesIntoFormats() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ytdlp-2026.10.26-html5-playlist", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let src = try ExtractorParser.parse(data, asked: URL(string: "https://www.w3schools.com/html/html5_video.asp")!, tool: ("yt-dlp", "2026.10.26"))
        guard case .tracks(let reps) = src.shape else { return XCTFail() }
        XCTAssertEqual(reps.map(\.container).sorted(), ["mp4", "ogv"], "two formats from two entries that list the same files, collapsed; null codecs are read as a plain video file")
        XCTAssertTrue(reps.allSatisfy { $0.role == .muxed })
        XCTAssertEqual(src.origin, .extractor(tool: "yt-dlp", version: "2026.10.26")); XCTAssertEqual(src.renewal, .rerunExtractor); XCTAssertEqual(src.schemaVersion, 1)
        let plan = DownloadPlanner.options(for: src, encoders: (true, true))
        XCTAssertTrue(plan.contains { $0.isExecutable && $0.representation?.container == "mp4" })
        XCTAssertTrue(plan.contains { $0.option.kind == .audioM4A && $0.isExecutable }, "sound can be taken from the MP4")
    }

    // MARK: Cancellation reaches the whole tree

    /// A local socket that accepts connections and never answers, so the tool is left waiting on a "page".
    func silentServer() -> (port: UInt16, close: () -> Void)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); return nil }
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (UInt16(bigEndian: out.sin_port), { Darwin.close(fd) })
    }

    func testCancellingStopsTheBundledToolAndItsChildProcess() async throws {
        let v = try need()
        let server = try XCTUnwrap(silentServer()); defer { server.close() }
        let slow = URL(string: "http://127.0.0.1:\(server.port)/never-answers")!
        let t = Task { try await ExternalExtractor.lookup(page: slow, path: v.url.path, isPrivate: false, allowLocal: true, timeout: 60, expectedIdentity: v.identity) }
        try await Task.sleep(nanoseconds: 3_000_000_000)          // the program is up and waiting for an answer
        XCTAssertGreaterThan(helperProcessCount(), 0, "the tool is running")
        let started = Date(); t.cancel(); _ = try? await t.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(helperProcessCount(), 0, "neither the program nor any process it started is left")
    }
    func helperProcessCount() -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "/yt-dlp/yt-dlp_macos"]
        let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }

    // MARK: Consent, privacy, contract

    func testBundledConsentIsBoundToThisToolAndNeverGrantedInAPrivateTab() async throws {
        let v = try need()
        let d = UserDefaults(suiteName: "bs.test.bundled.\(UUID().uuidString)")!
        let c = MediaConsentStore(defaults: d)
        c.grant(.externalExtractor(v.identity), scope: .profile, profile: "p", isPrivate: false)
        XCTAssertTrue(c.isAllowed(.externalExtractor(v.identity), host: "x.org", profile: "p", isPrivate: false))
        XCTAssertFalse(c.isAllowed(.externalExtractor("bundled:yt-dlp|9999|abc"), host: "x.org", profile: "p", isPrivate: false), "a different version asks again")
        XCTAssertFalse(c.isAllowed(.externalExtractor(v.identity), host: "x.org", profile: "p", isPrivate: true))
        do { _ = try await ExternalExtractor.lookup(page: URL(string: "https://x.org/w")!, path: v.url.path, isPrivate: true, expectedIdentity: v.identity); XCTFail() } catch { XCTAssertNotNil(error as? ExtractorFailure) }
        do { _ = try await ExternalExtractor.lookup(page: URL(string: "https://x.org/w")!, path: v.url.path, isPrivate: false, expectedIdentity: "bundled:yt-dlp|0|0"); XCTFail() } catch { XCTAssertEqual(error as? ExtractorFailure, .unsafeLocation("the bundled extractor does not match its pinned digest")) }
    }

    func testTheContractIsVersionedAndCarriesOriginRenewalAndAuthorization() {
        var s = NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: URL(string: "https://c.example/a.mp4")!, container: "mp4")]))
        XCTAssertEqual(s.schemaVersion, NormalizedMediaSource.currentSchemaVersion); XCTAssertEqual(s.origin, .native); XCTAssertEqual(s.renewal, .none); XCTAssertEqual(s.authContext, .none)
        XCTAssertNoThrow(try s.validate())
        s.schemaVersion = NormalizedMediaSource.currentSchemaVersion + 1
        XCTAssertThrowsError(try s.validate(), "a description from a newer version is refused, not guessed")
        let auth = AuthorizedMediaSource(provider: .vimeo, mediaID: "1", url: URL(string: "https://player.vimeo.com/x.mp4")!, type: .directFile, profile: "p", scope: "vimeo:video_files", expiresAt: nil, contentType: "video/mp4", quality: nil, width: nil, height: nil, bytes: nil, md5: nil, title: "t", canRefresh: true)
        let p = NormalizedMediaSource(authorized: auth, isPrivate: false)
        XCTAssertEqual(p?.origin, .provider(.vimeo)); XCTAssertEqual(p?.renewal, .provider(.vimeo)); XCTAssertEqual(p?.authContext, .providerToken)
    }
}


/// The real program, a real page, a real download, a real probe. The sample clip is the public W3Schools test video (the same one the page-listing tests use); the tests skip if it cannot be fetched.
@MainActor
final class BundledExtractorFlowTests: MediaCase {
    override func setUp() async throws { try await super.setUp(); try RealTool.use() }
    func keep(_ file: URL, as name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx08-keep")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name + "." + file.pathExtension)
        try? FileManager.default.removeItem(at: target); try? FileManager.default.copyItem(at: file, to: target)
    }
    func assertPlays(_ file: URL, line: UInt = #line) async throws {
        let item = AVPlayerItem(url: file); let player = AVPlayer(playerItem: item); player.isMuted = true
        for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))", line: line)
        player.play(); try await Task.sleep(for: .milliseconds(1200))
        XCTAssertGreaterThan(player.currentTime().seconds, 0.6, "it plays", line: line)
        player.pause()
    }
    func clipData() async throws -> Data {
        var r = URLRequest(url: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!); r.timeoutInterval = 30
        let (d, _) = try await URLSession.shared.data(for: r)
        try XCTSkipIf(d.count < 100_000, "the public sample clip could not be fetched")
        return d
    }

    func testRealToolReadsAFixturePageAndTheListedFileDownloadsAndPlays() async throws {
        let v = try XCTUnwrap(BundledExtractor.verify())
        let key = "bf\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/clip.mp4", try await clipData())
        try await put("\(key)/page.html", text: "<html><head><title>Bundled fixture</title></head><body><video controls><source src=\"clip.mp4\" type=\"video/mp4\"></video></body></html>")
        let page = url("/media/\(key)/page.html")
        let src = try await ExtractorBroker().lookup(page: page, path: v.url.path, identity: v.identity, profile: "t", isPrivate: false, allowLocal: true, timeout: 60)
        XCTAssertEqual(src.origin, .extractor(tool: "yt-dlp", version: v.manifest.version))
        guard case .tracks(let reps) = src.shape, let rep = reps.first(where: { $0.url.lastPathComponent == "clip.mp4" }) else { return XCTFail("the real tool did not list the clip: \(src.shape)") }
        print("BUNDLED real-tool formats: \(reps.map { "\($0.formatID ?? "?") \($0.container) \($0.url.lastPathComponent)" })")
        let option = try XCTUnwrap(DownloadPlanner.options(for: src, encoders: (true, true)).first { $0.isExecutable && $0.representation == rep && $0.option.kind == .original })
        let op = SourceSaveOperation(source: src, choice: try XCTUnwrap(option.choice), name: "Bundled clip", coordinator: c, profileTag: "t", origin: .user)
        op.pickVideo = option.representation
        op.start()
        let end = Date().addingTimeInterval(60)
        while Date() < end, !op.stage.isFinal { try await Task.sleep(nanoseconds: 250_000_000) }
        guard case .done(let file) = op.stage else { return XCTFail("\(op.stage)") }
        let record = try XCTUnwrap(c.ledger.record(try XCTUnwrap(op.downloadIDs.first)))
        XCTAssertEqual(record.state, .completed); XCTAssertEqual(record.transfer.completedBytes, 788_493)
        let asset = AVURLAsset(url: file)
        let videoTracks = try await asset.loadTracks(withMediaType: .video).count, audioTracks = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(videoTracks, 1); XCTAssertGreaterThanOrEqual(audioTracks, 1, "the sample clip carries two sound tracks and a text track; what was downloaded is the whole file")
        try await assertPlays(file)
        keep(file, as: "bundled-fixture-clip")
    }

    func testRealToolOnTheLiveSamplePageListsFormatsAndTheMP4Downloads() async throws {
        let v = try XCTUnwrap(BundledExtractor.verify())
        _ = try await clipData()                                  // skips if offline
        let page = URL(string: "https://www.w3schools.com/html/html5_video.asp")!
        let src = try await ExtractorBroker().lookup(page: page, path: v.url.path, identity: v.identity, profile: "t", isPrivate: false, allowLocal: false, timeout: 90)
        guard case .tracks(let reps) = src.shape else { return XCTFail() }
        XCTAssertEqual(reps.map(\.container).sorted(), ["mp4", "ogv"])
        let mp4 = try XCTUnwrap(reps.first { $0.container == "mp4" })
        let option = try XCTUnwrap(DownloadPlanner.options(for: src, encoders: (true, true)).first { $0.isExecutable && $0.representation == mp4 && $0.option.kind == .original })
        let op = SourceSaveOperation(source: src, choice: try XCTUnwrap(option.choice), name: "Live sample", coordinator: c, profileTag: "t", origin: .page)
        op.pickVideo = option.representation
        op.start()
        let end = Date().addingTimeInterval(90)
        while Date() < end, !op.stage.isFinal { try await Task.sleep(nanoseconds: 250_000_000) }
        guard case .done(let file) = op.stage else { return XCTFail("\(op.stage)") }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        XCTAssertEqual(size, 788_493)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 10, accuracy: 0.5)
        keep(file, as: "bundled-live-sample")
    }
}
