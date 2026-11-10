import XCTest
@testable import Browser_Setu

final class ResourceDetectionTests: XCTestCase {
    /// The reported case: a gallery page (IMDb's interest page) whose pictures are <img srcset> tags, not links. The toolbar used to show only the few media items.
    @MainActor
    func testAPagesPicturesAreListedAsImagesAndASameFileLinkIsNotCountedTwice() {
        let scan = PageLinkScan(links: [("https://www.example.org/title/tt1/", false), ("https://cdn.example.org/posters/a.jpg", false)], truncated: false,
                                images: ["https://cdn.example.org/posters/a.jpg", "https://cdn.example.org/posters/b._V1_QL75_UX380_.jpg", "https://img.example.org/render?id=77&w=400", "data:image/png;base64,AAAA",
                                         "https://en.wikipedia.org/wiki/File:Telugu.svg"])
        let s = PageResourceSummary.build(scan: scan, media: .empty, pageHost: "www.example.org")
        let images = s.items[.image] ?? []
        XCTAssertEqual(images.map(\.url), ["https://cdn.example.org/posters/a.jpg", "https://cdn.example.org/posters/b._V1_QL75_UX380_.jpg", "https://img.example.org/render?id=77&w=400"],
                       "the linked file is one item, an extension-less image address is kept, a data: URL and a wiki File: page are not pictures")
        XCTAssertEqual(images.count, 3)
        XCTAssertFalse(s.isEmpty)
    }

    private func c(_ u: String, marked: Bool = false) -> DetectedResource? { ResourceClassifier.classify(link: u, marked: marked, pageHost: "example.org") }

    func testCategoriesByExtension() {
        XCTAssertEqual(c("https://x.org/a/movie.MP4")?.category, .video)
        XCTAssertEqual(c("https://x.org/a.flac")?.category, .audio)
        XCTAssertEqual(c("https://x.org/a.png")?.category, .image)
        XCTAssertEqual(c("https://x.org/a.pdf")?.category, .document)
        XCTAssertEqual(c("https://x.org/a.zip")?.category, .archive)
        XCTAssertEqual(c("https://x.org/a.dmg")?.category, .installer)
        XCTAssertEqual(c("https://x.org/a.csv")?.category, .data)
        XCTAssertEqual(c("https://x.org/a.yaml")?.category, .config)
        XCTAssertEqual(c("https://x.org/a.swift")?.category, .code)
        XCTAssertEqual(c("https://x.org/a.torrent")?.category, .torrent)
        XCTAssertEqual(c("https://x.org/Dockerfile")?.category, .config)
        XCTAssertEqual(c("https://x.org/feed.rss")?.category, .feed)
    }

    func testPagesAndServerSideAreNotFiles() {
        XCTAssertNil(c("https://x.org/about"))
        XCTAssertNil(c("https://x.org/index.php"))
        XCTAssertNil(c("https://x.org/page.html"))
        XCTAssertEqual(c("https://x.org/export.php", marked: true)?.category, .other)
        XCTAssertEqual(c("https://x.org/page.html", marked: true)?.category, .code)
        XCTAssertNil(c("javascript:alert(1)")); XCTAssertNil(c("data:text/plain,hi")); XCTAssertNil(c("ftp://x.org/a.zip"))
    }

    func testAmbiguousTypeScriptIsLowConfidence() {
        let r = c("https://x.org/seg.ts")
        XCTAssertEqual(r?.category, .code)
        XCTAssertEqual(r?.confidence, .low)
    }

    func testMagnetAndCloudAndVideoCards() {
        XCTAssertEqual(c("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x")?.category, .torrent)
        XCTAssertEqual(c("https://www.dropbox.com/s/abc123/file")?.category, .cloud)
        XCTAssertNil(c("https://www.dropbox.com/"))
        let card = c("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(card?.category, .video); XCTAssertEqual(card?.needsResolution, true); XCTAssertEqual(card?.provider, .youtube)
        XCTAssertEqual(c("https://www.youtube.com/shorts/abcdefghijk")?.needsResolution, true)
        XCTAssertNil(c("https://www.youtube.com/"))
        XCTAssertNil(c("https://notyoutube.com/watch?v=dQw4w9WgXcQ")?.provider)
    }

    func testSignedAddressIsFlagged() {
        XCTAssertEqual(c("https://x.org/a.zip?X-Amz-Signature=abc")?.signed, true)
        XCTAssertEqual(c("https://x.org/a.zip")?.signed, false)
    }

    func testServerAnswerWinsOverAddress() {
        let r = c("https://x.org/download.zip")!
        XCTAssertEqual(ResourceClassifier.refine(r, mime: "text/html; charset=utf-8", disposition: nil, size: nil).availability, .notAFile("The address returned a web page, not a file."))
        XCTAssertEqual(ResourceClassifier.refine(r, mime: "text/html", disposition: "attachment; filename=a.zip", size: 5).availability, .confirmed(size: 5, mime: "text/html"))
        let v = ResourceClassifier.refine(c("https://x.org/blob.bin", marked: true)!, mime: "video/mp4", disposition: nil, size: 9)
        XCTAssertEqual(v.category, .video)
    }

    func testDedupeAndBounds() {
        var list: [DetectedResource] = []
        for i in 0..<800 { if let r = c("https://x.org/f\(i).zip") { list.append(r) } }
        list += [c("https://x.org/f1.zip#frag")!, c("HTTPS://X.org:443/f1.zip")!]
        let s = PageResourceSummary.make(list)
        XCTAssertEqual(s.items[.archive]?.count, ResourceClassifier.maxPerPage)
        XCTAssertTrue(s.truncated)
        let d = PageResourceSummary.make([c("https://x.org/a.zip")!, c("https://x.org/a.zip#top")!, c("https://X.org/a.zip")!])
        XCTAssertEqual(d.items[.archive]?.count, 1)
    }

    func testSummaryUsesMediaCountsForVideo() {
        var s = PageResourceSummary.make([c("https://www.youtube.com/watch?v=dQw4w9WgXcQ")!])
        XCTAssertEqual(s.detected(.video), 1)
        s.mediaDetected[.video] = 3; s.mediaOpenable[.video] = 2
        XCTAssertEqual(s.detected(.video), 4); XCTAssertEqual(s.openable(.video), 2)
        XCTAssertEqual(PageResourceSummary.empty.categories, [])
    }

    func testSettingsParsing() {
        XCTAssertEqual(ResourceDetectionSettings.parse("image,bogus,code"), [.image, .code])
        XCTAssertEqual(ResourceDetectionSettings.parse(""), [])
    }

    func testManifestsAreNotPlainFiles() {
        let r = c("https://x.org/live/index.m3u8")
        XCTAssertEqual(r?.category, .video); XCTAssertEqual(r?.isManifest, true); XCTAssertEqual(r?.needsResolution, true); XCTAssertEqual(r?.confidence, .low)
    }

    func testCloudNeedsAShareShape() {
        XCTAssertNil(c("https://www.dropbox.com/pricing"))
        XCTAssertNil(c("https://docs.google.com/forms/d/abc/edit"))
        XCTAssertEqual(c("https://www.dropbox.com/s/abc/file.bin")?.category, .cloud)
        XCTAssertEqual(c("https://drive.google.com/file/d/abc/view")?.category, .cloud)
        XCTAssertEqual(c("https://mega.nz/file/abc#key")?.category, .cloud)
    }

    func testCardsAreCountedSeparatelyAndNeverOpenable() {
        var s = PageResourceSummary.make([c("https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, c("https://www.youtube.com/shorts/abcdefghijk")!, c("https://x.org/a.mp4")!])
        XCTAssertEqual(s.detected(.video), 3); XCTAssertEqual(s.openable(.video), 1)
        s.mediaDetected[.video] = 2; s.mediaOpenable[.video] = 2
        XCTAssertEqual(s.detected(.video), 4); XCTAssertEqual(s.openable(.video), 2)
    }

    func testMarkedLinkWinsOverPlainDuplicate() {
        let s = PageResourceSummary.make([c("https://x.org/a.ts")!, c("https://x.org/a.ts", marked: true)!])
        XCTAssertEqual(s.items[.code]?.count, 1); XCTAssertEqual(s.items[.code]?.first?.confidence, .high)
    }
}

/// The popover that failed to open or closed during a rescan: its open state lives in the model, not in a chip that the toolbar rebuilds when the set of chips changes. These pin the rules.
@MainActor
final class ResourcePopoverStateTests: XCTestCase {
    private func model() -> BrowserModel { BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pop-\(UUID().uuidString)", profile: "default") }
    private func summary(_ urls: [String]) -> PageResourceSummary { PageResourceSummary.make(urls.compactMap { ResourceClassifier.classify(link: $0, marked: false, pageHost: "x.org") }) }

    func testARescanOfTheSamePageNeverClosesAnOpenList() {
        let m = model()
        m.noteResourcePage("1|https://x.org/")
        m.applyResourceSummary(summary(["https://x.org/a.zip"]))
        m.resourcePopoverKey = "archive"
        // The page loads more: a new chip appears, then the chip set grows again.
        m.applyResourceSummary(summary(["https://x.org/a.zip", "https://x.org/b.csv"]))
        m.noteResourcePage("1|https://x.org/")
        m.applyResourceSummary(summary(["https://x.org/a.zip", "https://x.org/b.csv", "https://x.org/c.png"]))
        XCTAssertEqual(m.resourcePopoverKey, "archive")
        XCTAssertEqual(m.resourceSummary.categories.count, 3)
    }

    func testAnotherPageClearsTheChipsAndTheList() {
        let m = model()
        m.noteResourcePage("1|https://x.org/")
        m.applyResourceSummary(summary(["https://x.org/a.zip"]))
        m.resourcePopoverKey = "archive"
        m.noteResourcePage("1|https://x.org/next")
        XCTAssertNil(m.resourcePopoverKey); XCTAssertTrue(m.resourceSummary.isEmpty, "a stale Download button cannot be pressed on the new page")
        m.noteResourcePage("2|https://x.org/next")                     // another tab
        XCTAssertNil(m.resourcePopoverKey)
    }

    func testAnIdenticalResultChangesNothing() {
        let m = model()
        m.noteResourcePage("1|p")
        let s = summary(["https://x.org/a.zip"])
        m.applyResourceSummary(s)
        m.resourcePopoverKey = "all"
        m.applyResourceSummary(s)
        XCTAssertEqual(m.resourcePopoverKey, "all")
    }
}

/// The production rule: a request that came from a page may not reach the local network. The Debug-only fixture seam is off unless the app is launched with its flag.
final class PageOriginLocalAddressTests: XCTestCase {
    func testPageOriginRefusesLocalAddressesByDefault() {
        XCTAssertFalse(HTTPRequestPolicy.debugFixtureAllowsLocalPageOrigin)
        let page = HTTPRequestPolicy(origin: .page), user = HTTPRequestPolicy(origin: .user)
        XCTAssertFalse(page.allowsInternalHosts); XCTAssertTrue(user.allowsInternalHosts)
        XCTAssertThrowsError(try page.check(URL(string: "http://127.0.0.1:18766/a.mp4")!))
        XCTAssertThrowsError(try page.check(URL(string: "http://192.168.1.5/a.mp4")!))
        XCTAssertNoThrow(try page.check(URL(string: "https://example.com/a.mp4")!))
    }
}

/// A download started from a list in the browser window ends with a visible card.
@MainActor
final class DownloadAnnouncementTests: XCTestCase {
    func testFinishedAndFailedDownloadsRaiseTheBanner() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ann-\(UUID().uuidString)", profile: "default")
        let ledger = m.engine.downloads.ledger
        let done = ledger.create(protocolID: .http, source: URL(string: "https://x.org/bundled.zip"), filename: "bundled.zip", isPrivate: false)
        m.announceWhenDone(done.id)
        ledger.update(done.id) { $0.file.destinationPath = "/tmp/bundled.zip" }
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.unknown)] { XCTAssertNotNil(ledger.apply(e, to: done.id), e.name) }
        XCTAssertEqual(ledger.record(done.id)?.state, .completed)
        let end = Date().addingTimeInterval(4)
        while Date() < end, m.downloadBanner == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(m.downloadBanner?.filename, "bundled.zip"); XCTAssertNil(m.downloadBanner?.warning)
        m.dismissDownloadBanner()
        let bad = ledger.create(protocolID: .http, source: URL(string: "https://x.org/bad.zip"), filename: "bad.zip", isPrivate: true)
        m.announceWhenDone(bad.id)
        for e in [DownloadEvent.queued, .started, .running, .failed(DownloadFailureInfo(code: "http:403", reason: "The server refused it.", retryable: false))] { XCTAssertNotNil(ledger.apply(e, to: bad.id), e.name) }
        let end2 = Date().addingTimeInterval(4)
        while Date() < end2, m.downloadBanner == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(m.downloadBanner?.filename, "A private download", "a private download's name is not shown")
        XCTAssertTrue(m.downloadBanner?.warning?.contains("The server refused it.") ?? false)
    }
}
