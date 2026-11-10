import XCTest
@testable import Browser_Setu

/// The Downloads settings panel, the names and labels of streams, and the Downloads card that must not close itself when a request arrives.
@MainActor
final class DownloadsBatchTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-batch-\(UUID().uuidString)", profile: "default")
    }

    func testDownloadsHasItsOwnSettingsPanelAndSearchFindsItThere() {
        XCTAssertTrue(SettingsPanel.allCases.contains(.downloads))
        XCTAssertEqual(SettingsPanel.downloads.title, "Downloads")
        let entry = SettingsIndex.entries.first { $0.title == "Downloads" }
        XCTAssertEqual(entry?.mac, "downloads", "the search result opens the Downloads panel, not General")
        for word in ["torrent", "magnet", "speed limit", "proxy"] {
            XCTAssertTrue(SettingsIndex.search(word).contains { $0.title == "Downloads" }, "\"\(word)\" finds the Downloads settings")
        }
    }

    func testTheP2PWarningsPointToSettingsDownloads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["macOS/Downloads/TorrentAddView.swift", "macOS/Downloads/ED2KAddView.swift", "Shared/Downloads/Torrent/TorrentRunner.swift", "Shared/Downloads/ED2K/ED2KRunner.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file))
            XCTAssertTrue(text.contains("Settings → Downloads"), file)
            XCTAssertFalse(text.contains("Settings > Downloads"), file)
        }
    }

    /// Show in Finder: a record that says where its file went shows that file only. If it was moved or deleted nothing is shown (not another file with the same name).
    func testAFileThatWasMovedOrDeletedIsNotRevealedAsAnotherFileOfTheSameName() throws {
        let c = model().downloads
        let root = try XCTUnwrap(c.managedRoots.first)
        var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://files.test/zz.bin")), filename: "zz-\(UUID().uuidString).bin")
        r.state = .completed
        r.file.destinationPath = root.appendingPathComponent("gone-\(UUID().uuidString)/\(r.file.filename)").path
        XCTAssertNil(c.fileURL(for: r), "moved or deleted: nothing to show")
        r.file.destinationPath = "/etc/hosts"
        XCTAssertNil(c.fileURL(for: r), "a path outside the downloads folders is never shown")
    }

    /// Names from remote servers and old records go through the one naming rule.
    func testTheCoordinatorsSafeNameIsTheOneNamingRule() {
        XCTAssertEqual(DownloadCoordinator.safeName("..\\..\\evil.sh"), "evil.sh", "a backslash is a separator too")
        XCTAssertFalse(DownloadCoordinator.safeName("a:b.txt").contains(":"))
        XCTAssertFalse(DownloadCoordinator.safeName("doc\u{202E}txt.exe").unicodeScalars.contains { $0.value == 0x202E }, "no direction override in a name")
        XCTAssertLessThanOrEqual(DownloadCoordinator.safeName(String(repeating: "x", count: 600) + ".bin").utf8.count, 255)
        XCTAssertEqual(DownloadCoordinator.safeName(""), "download")
        XCTAssertEqual(DownloadCoordinator.safeName("movie.mp4"), "movie.mp4")
    }

    func testAStreamIsNamedFromItsAddressAndNeverFromABareHost() {
        XCTAssertEqual(MediaAddModel.suggestedName(URL(string: "https://cdn.example.com/shows/lecture-one/index.m3u8")!), "lecture-one")
        XCTAssertEqual(MediaAddModel.suggestedName(URL(string: "https://cdn.example.com/keynote-2026.m3u8")!), "keynote-2026")
        // "movie", "clip", "master"… are generic stems (FilenameResolver.genericStems): they say nothing, so the folder, then the host, name the stream instead.
        XCTAssertEqual(MediaAddModel.suggestedName(URL(string: "https://cdn.example.com/movie.m3u8")!), "Stream from cdn-example-com")
        XCTAssertEqual(MediaAddModel.suggestedName(URL(string: "https://cdn.example.com/talks/movie.m3u8")!), "talks")
        let bare = MediaAddModel.suggestedName(URL(string: "http://127.0.0.1:18790/media/hls/master.m3u8")!)
        XCTAssertFalse(bare.contains("."), "a dot would be taken for a file extension: \(bare)")
        XCTAssertTrue(bare.hasPrefix("Stream from"), bare)
        XCTAssertEqual(MediaAddModel.suggestedName(URL(string: "https://x")!), "Stream from x")
    }

    func testAudioOnlyStreamsAreRecognisedAndVideoIsNot() {
        func stream(_ kind: MediaStream.Kind, codecs: String?, width: Int? = nil, height: Int? = nil) -> MediaStream {
            MediaStream(id: UUID().uuidString, kind: kind, label: "x", language: nil, codecs: codecs, bandwidth: 1, width: width, height: height)
        }
        XCTAssertTrue(MediaAddModel.isAudioOnly(stream(.video, codecs: "mp4a.40.2")))
        XCTAssertTrue(MediaAddModel.isAudioOnly(stream(.audio, codecs: nil)))
        XCTAssertFalse(MediaAddModel.isAudioOnly(stream(.video, codecs: "avc1.64001f,mp4a.40.2", width: 1280, height: 720)))
        XCTAssertFalse(MediaAddModel.isAudioOnly(stream(.video, codecs: nil)), "with nothing said it is not claimed to be audio")
    }

    func testARequestMadeWhileDownloadsIsOpenDoesNotCloseIt() {
        let m = model()
        m.panelMode = .float
        m.ensureDownloadsShown()
        XCTAssertEqual(m.floatingPanel, .downloads, "opened")
        m.openLinkGrabber()
        XCTAssertEqual(m.floatingPanel, .downloads, "still open after a request for one of its sheets")
        XCTAssertTrue(m.linkGrabberRequested)
        m.openPackages(); m.openMediaDiscovery()
        XCTAssertEqual(m.floatingPanel, .downloads)
    }

    // MARK: DX-01: where a link from a page may reach, and what stays off by default

    func testALinkFromAPageCannotUseATrackerOnTheLocalNetwork() {
        let local = ["http://127.0.0.1:18791/announce", "http://localhost/announce", "http://192.168.1.1/admin", "http://10.0.0.5/a", "http://169.254.169.254/latest", "http://[::1]/a"].compactMap(URL.init(string:))
        let pub = URL(string: "https://tracker.example.com/announce")!
        XCTAssertEqual(TorrentRunner.usableTrackers(local + [pub], origin: .page), [pub], "only the public tracker survives for a page")
        XCTAssertEqual(TorrentRunner.usableTrackers(local + [pub], origin: .user).count, local.count + 1, "the person's own request may use their own network")
        XCTAssertEqual(TorrentRunner.usableTrackers(local + [pub], origin: .automation), [pub])
    }

    func testLocalPeersAreOnlyForThePersonsOwnRequestWithALocalTracker() {
        let local = [URL(string: "http://127.0.0.1:18791/announce")!], pub = [URL(string: "https://tracker.example.com/announce")!]
        XCTAssertTrue(TorrentRunner.allowsLocalPeers(settingsAllow: false, trackers: local, origin: .user))
        XCTAssertFalse(TorrentRunner.allowsLocalPeers(settingsAllow: false, trackers: local, origin: .page), "a page never gets the local-network exception")
        XCTAssertFalse(TorrentRunner.allowsLocalPeers(settingsAllow: false, trackers: pub, origin: .user), "a public tracker cannot send the browser to a local peer")
        XCTAssertTrue(TorrentRunner.allowsLocalPeers(settingsAllow: true, trackers: pub, origin: .user), "unless the person's settings already allow it")
    }

    func testPeerToPeerIsOffByDefaultAndNothingTurnsItOn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx01-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = folder
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(DownloadCoordinator().torrentSettings.enabled)
    }

    func testThePromptHintIsNeverSubmittedAsAnswer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let platform = try String(contentsOf: root.appendingPathComponent("Shared/Platform.swift"))
        XCTAssertTrue(platform.contains("field.placeholderString = placeholder"), "a hint is shown as a placeholder")
        for (file, hint) in [("macOS/Downloads/DownloadInspector.swift", "https://mirror.example.com/file.zip"), ("Shared/TabTools.swift", "Research, Trip, Work…"), ("Shared/LibraryPanels.swift", "work, receipts…")] {
            let text = try String(contentsOf: root.appendingPathComponent(file))
            XCTAssertTrue(text.contains("placeholder: \"\(hint)\", prefill: false"), "\(file) must not submit \"\(hint)\"")
        }
    }

    func testTheCorruptSourceRuleIsInTheRunnerAndRequiresAChecksum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Shared/Downloads/HTTP/HTTPDownloadRunner.swift"))
        XCTAssertTrue(runner.contains("markCorrupt(record.source.asURL, task: id)"))
        XCTAssertTrue(runner.contains("record.engineMetadata[\"sha256\"] != nil, let list = record.engineMetadata[Self.corruptKey]"), "a source is only held against a task that still asks for a checksum")
    }

    func testEverySettingsPanelHasAPlaceInTheSidebar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("macOS/Settings/SettingsWindow.swift"))
        guard let start = source.range(of: "private static let groups"), let end = source.range(of: "var body: some View", range: start.upperBound..<source.endIndex) else { return XCTFail("the sidebar groups were not found") }
        let groups = String(source[start.upperBound..<end.lowerBound])
        for panel in SettingsPanel.allCases { XCTAssertTrue(groups.contains(".\(panel.rawValue)"), "the \(panel.title) panel is not in any sidebar group, so it cannot be opened") }
    }
}
