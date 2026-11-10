import XCTest
import WebKit
import Darwin
@testable import Browser_Setu

/// DX-10 feeds: the parser (RSS 2.0, Atom, JSON Feed, podcast extras), hostile input, discovery from a page, the local store, the names given to episodes, and a real feed read from the fixture server
/// whose episodes are downloaded into a collection and checked on disk and in the ledger.
final class FeedParserTests: XCTestCase {
    let base = URL(string: "https://pod.example/feeds/show.xml")!

    func parse(_ s: String) throws -> DownloadFeed { try DownloadFeedParser.parse(Data(s.utf8), from: base) }

    let podcast = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>The Show</title><link>https://pod.example/</link>
        <item>
          <title><![CDATA[Episode 2: “Ünïcode” & more]]></title><guid isPermaLink="false">ep-2</guid><pubDate>Sat, 08 Nov 2026 10:00:00 +0000</pubDate>
          <description><![CDATA[<p>Hello <b>world</b> &amp; friends</p>]]></description>
          <enclosure url="/audio/two" type="audio/mpeg" length="12345"/>
          <itunes:duration>1:02:03</itunes:duration><itunes:episode>2</itunes:episode><itunes:season>3</itunes:season>
        </item>
        <item><title>Episode 1</title><guid>ep-1</guid><pubDate>Sat, 01 Nov 2026 10:00:00 GMT</pubDate><enclosure url="https://cdn.example/one.mp3" type="audio/mpeg" length="999"/></item>
        <item><title>Just a post</title><link>https://pod.example/post</link></item>
        <item><title>Bad enclosure</title><guid>bad</guid><enclosure url="javascript:alert(1)" type="audio/mpeg"/><enclosure url="file:///etc/passwd"/></item>
        <item><title>Duplicate</title><guid>ep-1</guid><enclosure url="https://cdn.example/dup.mp3"/></item>
      </channel>
    </rss>
    """

    func testAPodcastFeedKeepsTitlesDatesEnclosuresAndTheExtras() throws {
        let f = try parse(podcast)
        XCTAssertEqual(f.kind, .rss); XCTAssertEqual(f.title, "The Show"); XCTAssertEqual(f.siteURL, URL(string: "https://pod.example/"))
        XCTAssertEqual(f.items.map(\.id), ["ep-2", "ep-1", "pod.example/post", "bad"], "the duplicate guid is one item; identity is the item's own id, else its enclosure or link by host and path (a changing signed query is not a new item)")
        let two = f.items[0]
        XCTAssertEqual(two.title, "Episode 2: “Ünïcode” & more"); XCTAssertEqual(two.summary, "Hello world & friends", "markup is dropped")
        XCTAssertEqual(two.enclosures, [FeedEnclosure(url: URL(string: "https://pod.example/audio/two")!, type: "audio/mpeg", length: 12345)], "a relative enclosure address is resolved against the feed")
        XCTAssertEqual(two.duration, 3723); XCTAssertEqual(two.episode, 2); XCTAssertEqual(two.season, 3)
        XCTAssertEqual(two.published, ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z"))
        XCTAssertEqual(f.items[1].published, ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        XCTAssertTrue(f.items[2].enclosures.isEmpty, "a post with no enclosure has nothing to download")
        XCTAssertTrue(f.items[3].enclosures.isEmpty, "javascript: and file: enclosures are dropped")
    }

    func testAtomWithEnclosureLinksAndAnotherPage() throws {
        let f = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Show</title><link rel="alternate" href="https://pod.example/"/><link rel="next" href="page2.xml"/>
          <entry><id>tag:pod.example,2026:1</id><title>One</title><published>2026-11-08T10:00:00Z</published><updated>2026-11-09T10:00:00Z</updated>
            <link rel="alternate" href="https://pod.example/1"/><link rel="enclosure" type="video/mp4" length="42" href="https://cdn.example/1.mp4"/><summary>Short</summary></entry>
          <entry><title>No id</title><link rel="enclosure" href="https://cdn.example/2.mp3" type="audio/mpeg"/></entry>
        </feed>
        """)
        XCTAssertEqual(f.kind, .atom); XCTAssertEqual(f.title, "Atom Show"); XCTAssertEqual(f.next, URL(string: "https://pod.example/feeds/page2.xml"))
        XCTAssertEqual(f.items.map(\.id), ["tag:pod.example,2026:1", "cdn.example/2.mp3"])
        XCTAssertEqual(f.items[0].enclosures.first?.length, 42); XCTAssertEqual(f.items[0].link, URL(string: "https://pod.example/1"))
        XCTAssertEqual(f.items[0].published, ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z"), "published wins over updated")
    }

    func testJSONFeedWithAttachments() throws {
        let f = try parse("""
        {"version":"https://jsonfeed.org/version/1.1","title":"JSON Show","home_page_url":"https://pod.example/","next_url":"https://pod.example/feeds/2.json",
         "items":[{"id":"a1","title":"Ep A","date_published":"2026-11-08T10:00:00Z","summary":"S","attachments":[{"url":"https://cdn.example/a.m4a","mime_type":"audio/x-m4a","size_in_bytes":77,"duration_in_seconds":60},{"url":"ftp://x/y.mp3"}]},
                  {"id":2,"content_text":"Body only","url":"https://pod.example/2"}]}
        """)
        XCTAssertEqual(f.kind, .json); XCTAssertEqual(f.title, "JSON Show"); XCTAssertEqual(f.next, URL(string: "https://pod.example/feeds/2.json"))
        XCTAssertEqual(f.items.count, 2); XCTAssertEqual(f.items[0].enclosures.count, 1, "the ftp attachment is dropped"); XCTAssertEqual(f.items[0].duration, 60)
        XCTAssertEqual(f.items[1].id, "2", "a numeric id is kept as text"); XCTAssertEqual(f.items[1].title, "2", "no title: the link's last part")
    }

    func testHostileAndBrokenFeedsFailSafely() throws {
        XCTAssertThrowsError(try parse("<html><body>Hello</body></html>")) { XCTAssertEqual($0 as? FeedError, .notAFeed) }
        XCTAssertThrowsError(try parse("{\"title\":\"no version\"}")) { XCTAssertEqual($0 as? FeedError, .notAFeed) }
        XCTAssertThrowsError(try parse("<rss><channel><item><title>x")) { XCTAssertTrue(($0 as? FeedError).map { if case .malformed = $0 { return true }; return false } ?? false) }
        XCTAssertThrowsError(try DownloadFeedParser.parse(Data(count: FeedLimits.maxBytes + 1), from: base)) { XCTAssertEqual($0 as? FeedError, .tooLarge) }
        // An external entity is never read: the file's contents must not appear anywhere.
        let hosts = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)).map { String($0.prefix(200)) } ?? "localhost"
        let marker = hosts.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }).map(String.init) ?? "localhost"
        do {
            let xxe = try parse("""
            <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/hosts">]><rss version="2.0"><channel><title>&secret;</title><item><title>&secret;</title><guid>x</guid><enclosure url="https://c.example/a.mp3"/></item></channel></rss>
            """)
            XCTAssertFalse(xxe.title.contains(marker)); XCTAssertFalse(xxe.items.first?.title.contains(marker) ?? false)
        } catch { /* refusing the document is also safe: the file's contents are never read */ }
        // Depth and element bombs are refused, not followed.
        let deep = String(repeating: "<a>", count: 200) + String(repeating: "</a>", count: 200)
        XCTAssertThrowsError(try parse("<rss><channel>" + deep + "</channel></rss>"))
        // Many items: bounded, and said.
        var many = "<rss><channel><title>Big</title>"
        for i in 0..<1200 { many += "<item><title>T\(i)</title><guid>g\(i)</guid><enclosure url=\"https://c.example/\(i).mp3\"/></item>" }
        let big = try parse(many + "</channel></rss>")
        XCTAssertEqual(big.items.count, FeedLimits.maxItems); XCTAssertTrue(big.truncated)
        // Control characters and direction overrides in titles are removed; very long titles are cut.
        let odd = try parse("<rss><channel><item><title>A\u{202E}B\u{0007}C" + String(repeating: "x", count: 1000) + "</title><guid>o</guid></item></channel></rss>")
        XCTAssertFalse(odd.items[0].title.unicodeScalars.contains { $0.value == 0x202E || $0.value == 7 }); XCTAssertLessThanOrEqual(odd.items[0].title.count, FeedLimits.maxTitle)
    }

    func testFeedsAreFoundOnAPageAndAFeedIsRecognisedItself() {
        let html = """
        <html><head><link rel="stylesheet" href="/s.css"><link rel="alternate" type="application/rss+xml" title="Episodes &amp; more" href="/feed.xml">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://other.example/atom'><link rel="alternate" type="text/html" href="/fr">
        <link rel="alternate" type="application/feed+json" href="feed.json"><link rel="alternate" type="application/rss+xml" href="javascript:x"></head></html>
        """
        let found = DownloadFeedDiscovery.links(inHTML: html, pageURL: URL(string: "https://pod.example/blog/")!)
        XCTAssertEqual(found.map(\.url.absoluteString), ["https://pod.example/feed.xml", "https://other.example/atom", "https://pod.example/blog/feed.json"])
        XCTAssertEqual(found.first?.title, "Episodes & more")
        XCTAssertTrue(DownloadFeedDiscovery.looksLikeFeed(Data(podcast.utf8))); XCTAssertTrue(DownloadFeedDiscovery.looksLikeFeed(Data("{\"version\":\"https://jsonfeed.org/version/1\"}".utf8)))
        XCTAssertFalse(DownloadFeedDiscovery.looksLikeFeed(Data(html.utf8)))
    }

    func testEpisodesAreNamedByTitleWithTheRightEndingAndNeverCollideInOneBatch() throws {
        let f = try parse("""
        <rss><channel><title>Show</title>
        <item><title>Intro</title><guid>1</guid><enclosure url="https://c.example/get?id=1" type="audio/mpeg"/></item>
        <item><title>Intro</title><guid>2</guid><enclosure url="https://c.example/x/same.mp3"/></item>
        <item><title>Highlights</title><guid>3</guid><enclosure url="https://c.example/v.php?f=3" type="video/mp4"/><enclosure url="https://c.example/extra.pdf" type="application/pdf"/></item>
        <item><title>Nothing</title><guid>4</guid></item></channel></rss>
        """)
        let links = FeedCollection.links(for: f.items, feed: f, profile: "default", isPrivate: false)
        XCTAssertEqual(links.map(\.suggestedFilename), ["Intro.mp3", "Intro (1).mp3", "Highlights.mp4", "Highlights (2).pdf"], "title + the ending from the type or the address; same names get free ones; no enclosure, no link")
        XCTAssertTrue(links.allSatisfy { $0.kind == .httpResource && $0.group == "Show" }, "an enclosure without a file ending is still a file")
        XCTAssertEqual(links[0].metadata["feed"], "Show")
    }

    /// Resident memory of this process in bytes.
    static func residentBytes() -> Int64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    func testLargeFeedsParseQuicklyInBoundedMemoryAndTheirLinksAreMadeInBulk() throws {
        for n in [100, 500, 2000] {
            var rss = "<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Big Show</title>"
            for i in 0..<n { rss += "<item><title>Episode \(i): a title that is long enough to be realistic</title><guid>guid-\(i)</guid><pubDate>Sat, 08 Nov 2026 10:00:00 +0000</pubDate><description>\(String(repeating: "Some show notes. ", count: 12))</description><enclosure url=\"https://cdn.example/\(i).mp3\" type=\"audio/mpeg\" length=\"\(1000 + i)\"/><itunes:duration>45:00</itunes:duration></item>" }
            rss += "</channel></rss>"
            var json = "{\"version\":\"https://jsonfeed.org/version/1.1\",\"title\":\"Big JSON\",\"items\":["
            json += (0..<n).map { "{\"id\":\"j\($0)\",\"title\":\"Entry \($0)\",\"attachments\":[{\"url\":\"https://cdn.example/\($0).mp3\",\"mime_type\":\"audio/mpeg\"}]}" }.joined(separator: ",") + "]}"
            let memBefore = Self.residentBytes()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let a = try parse(rss), b = try parse(json)
            let links = FeedCollection.links(for: a.items, feed: a, profile: "default", isPrivate: false)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let mb = Double(Self.residentBytes() - memBefore) / 1_048_576
            print(String(format: "PERF feed %d items (RSS + JSON + links): %.0f ms, resident +%.1f MB", n, ms, mb))
            XCTAssertEqual(a.items.count, min(n, FeedLimits.maxItems)); XCTAssertEqual(b.items.count, min(n, FeedLimits.maxItems)); XCTAssertEqual(links.count, a.items.count)
            XCTAssertLessThan(ms, n == 2000 ? 4000 : 1500, "\(n) items parse in bounded time"); XCTAssertLessThan(mb, 200, "and bounded memory")
            XCTAssertEqual(Set(links.compactMap(\.suggestedFilename)).count, links.count, "every episode got its own name")
        }
    }

    func testPlaylistFilesAreListsOfItemsButAnHLSStreamIsNot() throws {
        let m3u = "#EXTM3U\n#EXTINF:215,First Track\nhttps://cdn.example/a/one.mp3\n# a comment\n#EXTINF:-1,Second\n/rel/two.mp3\nftp://bad.example/x.mp3\n\n"
        let f = try parse(m3u)
        XCTAssertEqual(f.kind, .playlist); XCTAssertEqual(f.items.map(\.title), ["First Track", "Second"]); XCTAssertEqual(f.items[0].duration, 215); XCTAssertNil(f.items[1].duration)
        XCTAssertEqual(f.items[1].enclosures.first?.url, URL(string: "https://pod.example/rel/two.mp3"), "relative entries resolve against the playlist's address")
        let pls = try parse("[playlist]\nFile1=https://cdn.example/x.ogg\nTitle1=Song X\nFile2=https://cdn.example/y.ogg\nNumberOfEntries=2\n")
        XCTAssertEqual(pls.items.map(\.title), ["Song X", "y"])
        // Renditions and segments of a stream are never collected as separate downloads.
        for hls in ["#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow.m3u8\n", "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg0.ts\n#EXT-X-ENDLIST\n", "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"a.m3u8\"\n"] {
            XCTAssertThrowsError(try parse(hls)) { XCTAssertEqual($0 as? FeedError, .isAStream, hls) }
        }
        XCTAssertThrowsError(try parse("#EXTM3U\n# nothing here\n")) { XCTAssertEqual($0 as? FeedError, .notAFeed) }
        XCTAssertTrue(DownloadFeedDiscovery.looksLikeFeed(Data(m3u.utf8)))
    }

    func testAnExtractorsFlatListingBecomesSeparateEntriesAndHostileEntriesAreDropped() throws {
        let page = URL(string: "https://video.example/playlist?list=1")!
        let json = """
        {"_type":"playlist","id":"pl","title":"My List","webpage_url":"https://video.example/playlist?list=1","entries":[
         {"id":"a1","title":"One","url":"https://video.example/watch?v=a1","duration":61},
         null,
         {"id":"a1","title":"Repeat of One","url":"https://video.example/watch?v=a1"},
         {"id":"a2","title":"Private","url":"http://192.168.1.2/v"},
         {"id":"a3","title":"Script","url":"javascript:alert(1)"},
         {"id":"a4","_has_drm":true,"url":"https://video.example/watch?v=a4"},
         {"id":"a5","title":"","url":"https://video.example/watch?v=a5"}]}
        """
        let f = try ExtractorPlaylistParser.parse(Data(json.utf8), asked: page, start: 11)
        XCTAssertEqual(f.kind, .playlist); XCTAssertEqual(f.title, "My List")
        XCTAssertEqual(f.items.map(\.id), ["a1", "a5"], "unusable, protected, local-network and repeated entries are dropped")
        XCTAssertEqual(f.unavailable, 4, "null, local-network, javascript: and protected entries; the repeat is dropped without being counted"); XCTAssertEqual(f.items[1].title, "Entry 17", "an untitled entry is numbered by its place in the playlist")
        XCTAssertTrue(f.items.allSatisfy { $0.enclosures.isEmpty && $0.link != nil }, "entries carry the address of their own page; nothing is resolved yet")
        // Disk space: sizes that are known are compared with what is free; unknown sizes do not block.
        XCTAssertNil(DiskPreflight.problem(needed: 1_000_000_000, free: 50_000_000_000)); XCTAssertNil(DiskPreflight.problem(needed: 0, free: 1)); XCTAssertNil(DiskPreflight.problem(needed: 5, free: 0))
        XCTAssertTrue(DiskPreflight.problem(needed: 3_000_000_000, free: 3_200_000_000)?.contains("only") ?? false, "the margin counts too")
        XCTAssertGreaterThan(DiskPreflight.freeBytes(at: FileManager.default.temporaryDirectory), 0)
        // 2000 entries in 20 pages of 100 (the page size): each page parses quickly and the whole stays small.
        var all = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for p in 0..<20 {
            let entries = (0..<100).map { "{\"id\":\"v\(p)-\($0)\",\"title\":\"Video \(p * 100 + $0)\",\"url\":\"https://video.example/watch?v=\(p)-\($0)\",\"duration\":60}" }.joined(separator: ",")
            all += try ExtractorPlaylistParser.parse(Data("{\"_type\":\"playlist\",\"title\":\"Big\",\"entries\":[\(entries)]}".utf8), asked: page, start: p * 100 + 1).items.count
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        print(String(format: "PERF playlist 2000 entries in 20 pages: %.0f ms", ms))
        XCTAssertEqual(all, 2000); XCTAssertLessThan(ms, 2000)
        XCTAssertThrowsError(try ExtractorPlaylistParser.parse(Data("{\"id\":\"v\",\"title\":\"A single video\",\"formats\":[]}".utf8), asked: page))
        XCTAssertThrowsError(try ExtractorPlaylistParser.parse(Data("not json".utf8), asked: page))
        let args = try ExternalExtractor.playlistArguments(for: page, start: 101, count: 100)
        XCTAssertEqual(args, ["--dump-single-json", "--flat-playlist", "--playlist-start", "101", "--playlist-end", "200", "--no-warnings", "--", page.absoluteString], "a flat listing of one page; the address is after `--`")
        XCTAssertThrowsError(try ExternalExtractor.playlistArguments(for: URL(string: "file:///etc/passwd")!, start: 1, count: 10))
    }

    func testStatedSizesAndDurationsAreClampedAndIdentitiesAreStable() throws {
        let f = try parse("""
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>T</title>
        <item><title>A</title><enclosure url="https://c.example/a.mp3?sig=1" length="9223372036854775807"/><itunes:duration>1e30</itunes:duration></item>
        <item><title>B</title><enclosure url="https://c.example/b.mp3" length="-5"/><itunes:duration>inf</itunes:duration></item>
        <item><title>C\u{2066}isolate</title><enclosure url="https://c.example/c.mp3?sig=2" length="5"/></item></channel></rss>
        """)
        XCTAssertEqual(f.items.map { $0.enclosures[0].length }, [nil, nil, 5], "a size that is negative or beyond 1 PiB is not believed")
        XCTAssertEqual(f.items.map(\.duration), [nil, nil, nil], "an absurd or non-finite duration is not believed")
        XCTAssertEqual(f.items[0].id, "c.example/a.mp3", "an item with no id of its own is identified by host and path: a signed query that changes does not make it a new item")
        XCTAssertFalse(f.items[2].title.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
        let json = try parse("{\"version\":\"https://jsonfeed.org/version/1\",\"items\":[{\"id\":\"a\",\"attachments\":[{\"url\":\"https://c.example/a.mp3\",\"size_in_bytes\":9.3e18,\"duration_in_seconds\":1e300}]}]}")
        XCTAssertNil(json.items[0].enclosures[0].length); XCTAssertNil(json.items[0].duration)
        // Adding stated sizes and comparing them with free space cannot overflow.
        XCTAssertNotNil(DiskPreflight.problem(needed: Int64.max, free: 1_000_000_000_000))
        XCTAssertNil(DiskPreflight.problem(needed: Int64.max, free: 0))
    }

    @MainActor
    func testTheSheetForgetsWhatTheOtherKindOfTabLoadedAndNeverKeepsCredentials() {
        let c = DownloadCoordinator()
        let sheet = FeedSheetModel(coordinator: c)
        sheet.address = "https://pod.example/feed.xml"
        sheet.isPrivate = true
        XCTAssertEqual(sheet.address, "", "opened from a private tab: nothing from a normal tab remains")
        sheet.isPrivate = false
        XCTAssertEqual(FeedSheetModel.withoutCredentials(URL(string: "https://user:secret@pod.example/f.xml?x=1")!).absoluteString, "https://pod.example/f.xml?x=1")
        XCTAssertEqual(FeedSheetModel.withoutCredentials(URL(string: "https://pod.example/f.xml")!).absoluteString, "https://pod.example/f.xml")
    }

    @MainActor
    func testSubscriptionsAreLocalBoundedAndPerProfile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bs-feeds-\(UUID().uuidString)/feeds.json"); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = FeedStore(profile: "work", file: file)
        let a = try XCTUnwrap(store.subscribe(URL(string: "https://pod.example/feed.xml")!, title: "Show"))
        XCTAssertEqual(store.subscribe(URL(string: "HTTPS://POD.example:443/feed.xml#top")!, title: "Again")?.id, a.id, "the same feed is one subscription")
        store.markSeen(["ep-1", "ep-2", "ep-1"], in: a.id); store.markChecked(a.id, title: "The Show")
        let again = FeedStore(profile: "work", file: file)
        XCTAssertEqual(again.subscriptions.count, 1); XCTAssertEqual(again.subscriptions[0].title, "The Show"); XCTAssertEqual(again.subscriptions[0].seen, ["ep-1", "ep-2"])
        XCTAssertTrue(again.isSeen("ep-2", in: a.id)); XCTAssertFalse(again.isSeen("ep-3", in: a.id))
        XCTAssertTrue(FeedStore(profile: "home", file: file).subscriptions.isEmpty, "another profile does not see them")
        again.markSeen((0..<(FeedStore.maxSeen + 50)).map { "i\($0)" }, in: a.id)
        XCTAssertEqual(again.subscriptions[0].seen.count, FeedStore.maxSeen, "the list of handled items is bounded, oldest dropped")
        again.unsubscribe(a.id); XCTAssertTrue(FeedStore(profile: "work", file: file).subscriptions.isEmpty)
        let priv = FeedStore(profile: "work", file: file, isPrivate: true)
        XCTAssertNil(priv.subscribe(URL(string: "https://pod.example/p.xml")!, title: "P"), "a private session keeps nothing"); XCTAssertTrue(FeedStore(profile: "work", file: file).subscriptions.isEmpty)
    }

    func testSignedLinksAreTheSameItemButDifferentFilesAreNot() {
        let a = FeedURLIdentity.stable(URL(string: "https://cdn.example/dl?file=a.mp3&X-Amz-Signature=111&Expires=5")!)
        let a2 = FeedURLIdentity.stable(URL(string: "https://CDN.example/dl?Expires=9&X-Amz-Signature=222&file=a.mp3")!)
        let b = FeedURLIdentity.stable(URL(string: "https://cdn.example/dl?file=b.mp3&X-Amz-Signature=111&Expires=5")!)
        XCTAssertEqual(a, a2, "rotating signature and expiry do not make a new item"); XCTAssertNotEqual(a, b, "a parameter that chooses the file does")
        XCTAssertEqual(FeedURLIdentity.stable(URL(string: "https://c.example/a.mp3")!), "c.example/a.mp3")
        XCTAssertNotEqual(FeedURLIdentity.stable(URL(string: "https://x.example/play?s=1&e=3")!), FeedURLIdentity.stable(URL(string: "https://x.example/play?s=1&e=4")!), "an episode number is not a signature")
        XCTAssertEqual(FeedURLIdentity.stable(URL(string: "https://x.example/play?e=3&sig=a")!), FeedURLIdentity.stable(URL(string: "https://x.example/play?e=4&sig=b")!), "...but beside a signature the short names are the signature's")
    }

    func testQualityChoiceUsesWhatTheEntryReallyOffers() {
        func video(_ h: Int) -> PlannedOption {
            PlannedOption(option: OutputOption(kind: .video, title: "\(h)p", provenance: "Source quality"), choice: .joined,
                          representation: NormalizedRepresentation(role: .video, url: URL(string: "https://v.example/\(h).mp4")!, container: "mp4", height: h))
        }
        let audio = PlannedOption(option: OutputOption(kind: .audioM4A, title: "M4A", provenance: "Converted"), choice: .audioM4A, representation: nil)
        let gone = PlannedOption(option: OutputOption(kind: .video, title: "4K", provenance: "x", unavailableReason: "needs a tool"), choice: nil, representation: nil)
        let all = [gone, video(1080), video(720), video(360), audio]
        XCTAssertEqual(PlaylistQuality.best.choose(from: all)?.option.title, "1080p", "best skips what cannot be done")
        XCTAssertEqual(PlaylistQuality.p720.choose(from: all)?.option.title, "720p")
        XCTAssertEqual(PlaylistQuality.p480.choose(from: all)?.option.title, "360p", "the tallest within the limit")
        XCTAssertEqual(PlaylistQuality.p480.choose(from: [video(1080), video(720)])?.option.title, "720p", "everything is taller: the smallest, never nothing")
        XCTAssertEqual(PlaylistQuality.audio.choose(from: all)?.option.kind, .audioM4A)
        XCTAssertNil(PlaylistQuality.best.choose(from: [gone]))
    }
}

@MainActor
final class FeedIntegrationTests: MediaCase {
    func episodeBytes(_ n: Int) -> Data { Data(repeating: UInt8(0x41 + n), count: 2000 + n * 100) }

    func testAFeedIsReadFromAServerAndItsEpisodesDownloadIntoACollectionWithTheirTitles() async throws {
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin"); defer { UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin") }
        for n in 1...3 { try await put("fd/ep\(n)", episodeBytes(n)) }          // no file ending on purpose: the type says what it is
        let rss = """
        <rss version="2.0"><channel><title>Local Show</title><link>\(url("/media/fd/"))</link>
        \((1...3).map { "<item><title>Episode \($0): Ünï</title><guid>g\($0)</guid><pubDate>Sat, 0\($0) Nov 2026 10:00:00 +0000</pubDate><enclosure url=\"\(url("/media/fd/ep\($0)"))\" type=\"audio/mpeg\" length=\"\(2000 + $0 * 100)\"/></item>" }.joined())
        </channel></rss>
        """
        try await put("fd/feed.xml", Data(rss.utf8))
        try await put("fd/index.html", Data("<html><head><link rel=\"alternate\" type=\"application/rss+xml\" title=\"Local Show\" href=\"feed.xml\"></head></html>".utf8))

        // The address of a PAGE finds its feed; a feed address is read directly. (A typed address: it may be on this Mac.)
        let viaPage = try await FeedLoader.load(url("/media/fd/index.html"), coordinator: c, origin: .user)
        XCTAssertEqual(viaPage.feed.items.count, 3); XCTAssertEqual(viaPage.url, url("/media/fd/feed.xml")); XCTAssertEqual(viaPage.alternatives.count, 1)
        let loaded = try await FeedLoader.load(url("/media/fd/feed.xml"), coordinator: c, origin: .user)
        // A page may not aim the browser at this Mac's own network: the same address as a page-found one is refused.
        UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin")
        do { _ = try await FeedLoader.load(url("/media/fd/feed.xml"), coordinator: c, origin: .page); XCTFail("a page-found feed on the local network") } catch {}
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin")

        let sub = try XCTUnwrap(c.feeds.subscribe(loaded.url, title: loaded.feed.title))
        let links = FeedCollection.links(for: Array(loaded.feed.items.prefix(2)), feed: loaded.feed, profile: "default", isPrivate: false)
        XCTAssertEqual(links.map(\.suggestedFilename), ["Episode 1: Ünï.mp3", "Episode 2: Ünï.mp3"].map { DownloadFilename.sanitize($0)! }, "titles with their ending from the declared type; ':' is made safe")
        let source = "feed:" + LinkClassifier.normalizedKey(loaded.url)
        let result = await BatchSubmitter.submit(BatchRequest(name: loaded.feed.title, source: source), links: links, isPrivate: false, coordinator: c)
        XCTAssertEqual(result.started, 2); XCTAssertEqual(result.packages.count, 1)
        c.feeds.markSeen(loaded.feed.items.prefix(2).map(\.id), in: sub.id)

        let package = try XCTUnwrap(c.packages.package(result.packages[0]))
        XCTAssertEqual(package.name, "Local Show"); XCTAssertEqual(package.members.count, 2)
        for id in package.members { _ = await wait(id, for: [.completed, .failed], seconds: 30) }
        let progress = c.packages.progress(of: package.id)
        XCTAssertEqual(progress.completed, 2); XCTAssertEqual(progress.failed, 0); XCTAssertEqual(progress.status, .completed)
        // The files on disk are the episodes' bytes under their titles; the ledger says the same.
        for (i, id) in package.members.enumerated() {
            let record = try XCTUnwrap(c.ledger.record(id))
            XCTAssertEqual(record.state, .completed); XCTAssertEqual(record.engineMetadata["feed"], "Local Show"); XCTAssertNotNil(record.engineMetadata["published"])
            let path = try XCTUnwrap(record.file.destinationPath)
            XCTAssertTrue(path.hasSuffix(".mp3"), path); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), episodeBytes(i + 1))
            XCTAssertTrue(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("Episode \(i + 1)"), path)
        }
        // A refresh: the whole feed is offered again. The two collected episodes are not made again, the third joins the SAME collection, and only it is started.
        let all = FeedCollection.links(for: loaded.feed.items, feed: loaded.feed, profile: "default", isPrivate: false)
        let refresh = await BatchSubmitter.submit(BatchRequest(name: loaded.feed.title, source: source), links: all, isPrivate: false, coordinator: c)
        XCTAssertEqual(refresh.alreadyCollected, 2); XCTAssertEqual(refresh.started, 1); XCTAssertEqual(c.packages.packages.filter { $0.source == source }.count, 1, "one collection per source")
        let collection = try XCTUnwrap(c.packages.package(withSource: source))
        XCTAssertEqual(collection.members.count, 3); XCTAssertEqual(collection.originalCount, 3); XCTAssertEqual(collection.identities?.count, 3)
        for id in collection.members { _ = await wait(id, for: [.completed, .failed], seconds: 30) }
        XCTAssertEqual(c.packages.progress(of: collection.id).completed, 3)
        let unseen = loaded.feed.items.filter { !c.feeds.isSeen($0.id, in: sub.id) }
        XCTAssertEqual(unseen.map(\.id), ["g3"], "the third was started but not marked handled by this test's own bookkeeping (only the first batch marked seen)")

        // The same request twice at once (two clicks, two windows): each item is made once.
        let twice = FeedCollection.links(for: [loaded.feed.items[0]], feed: loaded.feed, profile: "default", isPrivate: false)
        let other = "feed:" + LinkClassifier.normalizedKey(url("/media/fd/other.xml"))
        async let r1 = BatchSubmitter.submit(BatchRequest(name: "Twice", source: other), links: twice, isPrivate: false, coordinator: c)
        async let r2 = BatchSubmitter.submit(BatchRequest(name: "Twice", source: other), links: twice, isPrivate: false, coordinator: c)
        let (a, b) = await (r1, r2)
        XCTAssertEqual(a.started + b.started, 1, "made once, not twice"); XCTAssertEqual(c.packages.packages.filter { $0.source == other }.count, 1)

        // A relaunch: the collections, their sources and item identities come back from disk and agree with the ledger; a removed task is not a ghost member.
        c.ledger.flush()
        let before = c.packages.packages.map { ($0.id, $0.members.count, $0.source ?? "") }
        DownloadTaskStore.close(folder: folder)
        let c2 = makeCoordinator()
        let restored = c2.packages.packages.map { ($0.id, $0.members.count, $0.source ?? "") }
        XCTAssertEqual(restored.map(\.0), before.map(\.0)); XCTAssertEqual(restored.map(\.1), before.map(\.1)); XCTAssertEqual(restored.map(\.2), before.map(\.2))
        XCTAssertTrue(c2.packages.isCollected(collection.identities!.keys.first!, source: source), "a finished item with its file is still collected after a relaunch")
        let victim = try XCTUnwrap(collection.members.first)
        let victimKey = try XCTUnwrap(collection.identities?.first { $0.value == victim.uuidString }?.key)
        if let path = c2.ledger.record(victim)?.file.destinationPath { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(c2.packages.isCollected(victimKey, source: source), "its file is gone: asking again makes it again, it is not a ghost")
        c2.ledger.remove(victim); c2.packages.reconcile()
        XCTAssertEqual(c2.packages.package(withSource: source)?.members.contains(victim), false, "a removed task leaves the collection")
        // Leaving nothing behind that is not a download: no working files in the folder.
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: downloads.path)).filter { $0.hasPrefix(".") && !$0.hasPrefix(".Browser Setu") }
        XCTAssertEqual(leftovers, [])
    }

    func testAPagedFeedIsFollowedAFewPagesAndALoopOrAHugeChainStops() async throws {
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin"); defer { UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin") }
        func page(_ n: Int, next: String?) -> Data {
            let items = (0..<40).map { "<entry><id>p\(n)-\($0)</id><title>P\(n) E\($0)</title><link rel=\"enclosure\" type=\"audio/mpeg\" href=\"https://cdn.example/p\(n)-\($0).mp3\"/></entry>" }.joined()
            return Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Paged</title>\(next.map { "<link rel=\"next\" href=\"\($0)\"/>" } ?? "")\(items)</feed>".utf8)
        }
        // Three pages: all read, in order, without repeats.
        try await put("pg/a1.xml", page(1, next: "a2.xml")); try await put("pg/a2.xml", page(2, next: "a3.xml")); try await put("pg/a3.xml", page(3, next: nil))
        let three = try await FeedLoader.load(url("/media/pg/a1.xml"), coordinator: c, origin: .user)
        XCTAssertEqual(three.feed.items.count, 120); XCTAssertEqual(three.feed.items.first?.id, "p1-0"); XCTAssertEqual(three.feed.items.last?.id, "p3-39"); XCTAssertNil(three.feed.next)
        // A loop (the last page points back to the first) ends instead of reading forever, and nothing is listed twice.
        try await put("pg/l1.xml", page(1, next: "l2.xml")); try await put("pg/l2.xml", page(2, next: "l1.xml"))
        let loop = try await FeedLoader.load(url("/media/pg/l1.xml"), coordinator: c, origin: .user)
        XCTAssertEqual(loop.feed.items.count, 80); XCTAssertEqual(Set(loop.feed.items.map(\.id)).count, 80)
        // A long chain is cut at the page limit, and the rest is still reachable (its address is kept as the next page).
        for n in 1...10 { try await put("pg/c\(n).xml", page(n, next: n < 10 ? "c\(n + 1).xml" : nil)) }
        let chain = try await FeedLoader.load(url("/media/pg/c1.xml"), coordinator: c, origin: .user)
        XCTAssertEqual(chain.feed.items.count, FeedLoader.maxPages * 40); XCTAssertNotNil(chain.feed.next, "more pages remain")
    }

    func testAPlaylistIsListedAPageAtATimeAndChosenEntriesAreSavedAFewAtATimeIntoOneCollection() async throws {
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin"); defer { UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin"); MediaConsentStore.shared.clearOnce() }
        let script = TestExtractorScript.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in extractor fixture is missing")
        let exe = try ExternalExtractor.validateLocation(script); let identity = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        let key = "pl\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/clip.mp4", try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video/clip.mp4")))
        let page = url("/media/\(key)/list?flatlist")

        // Listed a page at a time; an unavailable entry is counted, not shown; "more" says whether to ask for the next page.
        let first = try await ExternalExtractor.playlist(page: page, path: script, isPrivate: false, allowLocal: true, start: 1, count: 3, expectedIdentity: identity)
        XCTAssertEqual(first.items.map(\.id), ["vid1", "vid2", "vid3"]); XCTAssertTrue(first.more); XCTAssertEqual(first.title, "Test List")
        let second = try await ExternalExtractor.playlist(page: page, path: script, isPrivate: false, allowLocal: true, start: 4, count: 4, expectedIdentity: identity)
        XCTAssertEqual(second.items.map(\.id), ["vid4", "vid6", "vid7"]); XCTAssertEqual(second.unavailable, 1, "entry 5 was removed")
        XCTAssertTrue(second.more, "a full page may be followed by more: that is only known by asking")
        let third = try await ExternalExtractor.playlist(page: page, path: script, isPrivate: false, allowLocal: true, start: 8, count: 4, expectedIdentity: identity)
        XCTAssertTrue(third.items.isEmpty); XCTAssertFalse(third.more, "an empty page ends the listing")

        // Not allowed for this site yet: nothing is looked up, and the entry says what to do.
        let runner = PlaylistRunner(coordinator: c)
        let program = PlaylistRunner.Program(path: script, identity: identity)
        let source = "playlist:" + LinkClassifier.normalizedKey(page)
        runner.start(items: [first.items[0]], title: first.title, source: source, program: program, profile: "default")
        while runner.running { try await Task.sleep(nanoseconds: 50_000_000) }
        if case .failed(let why) = runner.states["vid1"] ?? .waiting { XCTAssertTrue(why.contains("not allowed"), why) } else { XCTFail("\(String(describing: runner.states["vid1"]))") }

        // Allowed: chosen entries are resolved two at a time and saved under their titles into one collection; one entry that fails does not stop the others.
        MediaConsentStore.shared.grant(.externalExtractor(identity), scope: .once, profile: "default", isPrivate: false)
        let chosen = [first.items[0], first.items[1], first.items[2], second.items[2]]          // vid1, vid2, vid3, vid7 (vid7's page fails)
        runner.start(items: chosen, title: first.title, source: source, program: program, profile: "default")
        var mostAtOnce = 0
        while runner.running { mostAtOnce = max(mostAtOnce, runner.states.values.filter { if case .looking = $0 { return true }; if case .saving = $0 { return true }; return false }.count); try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertLessThanOrEqual(mostAtOnce, PlaylistRunner.concurrency, "never more than two entries are being resolved or saved at once"); XCTAssertGreaterThanOrEqual(mostAtOnce, 1)
        XCTAssertEqual(runner.doneCount, 3); XCTAssertEqual(runner.failedCount, 1)
        guard case .failed(let why) = runner.states["vid7"] ?? .waiting else { return XCTFail("vid7 should have failed") }
        XCTAssertFalse(why.isEmpty)
        let pkg = try XCTUnwrap(c.packages.package(withSource: source))
        XCTAssertEqual(pkg.members.count, 3); XCTAssertEqual(pkg.identities?.count, 3)
        let names = pkg.members.compactMap { c.ledger.record($0)?.file.filename }.sorted()
        XCTAssertEqual(names, ["Item 1- Ünï.mp4", "Item 2- Ünï.mp4", "Item 3- Ünï.mp4"].map { DownloadFilename.sanitize($0)! }.sorted(), "named by entry title with the file's own ending")
        for id in pkg.members {
            let r = try XCTUnwrap(c.ledger.record(id)); XCTAssertEqual(r.state, .completed); XCTAssertEqual(r.engineMetadata["playlist"]?.isEmpty, false)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(r.file.destinationPath))).count, try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video/clip.mp4")).count, "the real file was saved")
        }
        XCTAssertEqual(c.packages.progress(of: pkg.id).completed, 3)
        XCTAssertEqual(c.packages.progress(of: pkg.id).total, 4, "the failed entry is a child of the collection too"); XCTAssertEqual(c.packages.progress(of: pkg.id).status, .needsAttention)
        XCTAssertEqual(pkg.entries?["vid7#0"]?.state, .failed); XCTAssertNil(pkg.entries?["vid1#0"], "an entry that became a task is no longer a pending entry")
        // A refresh offers everything again: the three saved are skipped, the failed one is the only one tried (and fails again, visibly).
        runner.start(items: chosen, title: first.title, source: source, program: program, profile: "default")
        // (states were kept: only failed entries are re-run; done ones stay done)
        while runner.running { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(runner.doneCount, 3); XCTAssertEqual(c.packages.package(withSource: source)?.members.count, 3, "nothing was made twice")
        // No working files are left over, and the halves the saves downloaded are not listed as completed downloads.
        let hidden = (try FileManager.default.contentsOfDirectory(atPath: downloads.path)).filter { $0.hasPrefix(".") && !$0.hasPrefix(".Browser Setu") }
        XCTAssertEqual(hidden, [])
        XCTAssertEqual(c.ledger.records.values.filter { $0.state == .completed }.count, 3, "only the three results are completed downloads")
    }

    func testACollectionMadeInSeveralGroupsIsStillRecognisedAndAnotherPlaylistStartsFresh() async throws {
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin"); defer { UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin"); MediaConsentStore.shared.clearOnce() }
        // Two collections of one source (a request grouped by site or type makes several): an item in the SECOND is collected too, and stops being collected when its file is gone.
        let dir = downloads.appendingPathComponent("grp"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("one.mp3"); try Data("x".utf8).write(to: file)
        let id = try XCTUnwrap(c.recordProducedFile(file, source: nil, isPrivate: false))
        let first = try XCTUnwrap(c.packages.create(name: "A", members: [], source: "feed:s")?.package), second = try XCTUnwrap(c.packages.create(name: "B", members: [], batchKey: "k2", source: "feed:s")?.package)
        XCTAssertNotEqual(first.id, second.id)
        c.packages.recordIdentity("item#0", task: id, in: second.id)
        XCTAssertTrue(c.packages.isCollected("item#0", source: "feed:s"), "found in the second collection of the source")
        XCTAssertFalse(c.packages.isCollected("item#0", source: "feed:other"))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(c.packages.isCollected("item#0", source: "feed:s"), "its file is gone: not collected")

        // A second playlist with the same entry ids is its own: nothing carries over from the first, and the same names get free ones.
        let script = TestExtractorScript.path
        let exe = try ExternalExtractor.validateLocation(script); let identity = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        let key = "p2\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/clip.mp4", try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video/clip.mp4")))
        let pageA = url("/media/\(key)/a?flatlist"), pageB = url("/media/\(key)/b?flatlist")
        let listA = try await ExternalExtractor.playlist(page: pageA, path: script, isPrivate: false, allowLocal: true, start: 1, count: 2, expectedIdentity: identity)
        let program = PlaylistRunner.Program(path: script, identity: identity)
        MediaConsentStore.shared.grant(.externalExtractor(identity), scope: .once, profile: "default", isPrivate: false)
        let runner = PlaylistRunner(coordinator: c)
        XCTAssertTrue(runner.start(items: listA.items, title: "A", source: "playlist:A", program: program, profile: "default"))
        XCTAssertFalse(runner.start(items: listA.items, title: "A", source: "playlist:A", program: program, profile: "default"), "a second start while one runs starts nothing")
        runner.cancel()
        while runner.running { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(runner.start(items: listA.items, title: "A", source: "playlist:A", program: program, profile: "default"), "after a stop, entries that were stopped can be asked for again")
        while runner.running { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertEqual(runner.doneCount, 2)
        XCTAssertTrue(runner.start(items: listA.items, title: "B", source: "playlist:B", program: program, profile: "default"), "another playlist starts clean")
        while runner.running { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertEqual(runner.doneCount, 2, "both entries saved again for the other playlist")
        let pkgB = try XCTUnwrap(c.packages.package(withSource: "playlist:B")); XCTAssertEqual(pkgB.members.count, 2)
        let pkgA = try XCTUnwrap(c.packages.package(withSource: "playlist:A"))
        let names = Set((pkgA.members + pkgB.members).compactMap { c.ledger.record($0)?.file.filename })
        XCTAssertEqual(names.count, 4, "four different files: the second playlist's got free names, nothing was replaced: \(names)")
    }

    func testMergeAndSplitKeepSourceIdentityAndWaitingEntries() throws {
        func made(_ n: String) throws -> UUID {
            let dir = downloads.appendingPathComponent("ms"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(n); try Data(n.utf8).write(to: file)
            return try XCTUnwrap(c.recordProducedFile(file, source: nil, isPrivate: false))
        }
        let (t1, t2, t3) = (try made("a.mp3"), try made("b.mp3"), try made("c.mp3"))
        let a = try XCTUnwrap(c.packages.create(name: "A", members: [t1, t2], source: "feed:a")?.package)
        c.packages.recordIdentity("k1#0", task: t1, in: a.id); c.packages.recordIdentity("k2#0", task: t2, in: a.id); c.packages.noteChosen(2, in: a.id)
        // Split: the new collection keeps the source and takes its items' identities along; the old one keeps the rest. Both still recognise everything.
        let part = try XCTUnwrap(c.packages.split([t2], from: a.id, name: "Part"))
        XCTAssertEqual(part.source, "feed:a"); XCTAssertEqual(part.identities?.keys.sorted(), ["k2#0"]); XCTAssertEqual(c.packages.package(a.id)?.identities?.keys.sorted(), ["k1#0"])
        XCTAssertTrue(c.packages.isCollected("k1#0", source: "feed:a")); XCTAssertTrue(c.packages.isCollected("k2#0", source: "feed:a"))
        // Merge from a different source: the target's source stays, and the other source's items are still recognised under their own source.
        let b = try XCTUnwrap(c.packages.create(name: "B", members: [t3], batchKey: "kb", source: "feed:b")?.package)
        c.packages.recordIdentity("k3#0", task: t3, in: b.id)
        c.packages.setEntry("k4#0", title: "Four", state: .failed, reason: "no", in: b.id)
        c.packages.merge(b.id, into: a.id)
        XCTAssertNil(c.packages.package(b.id)); XCTAssertEqual(c.packages.package(a.id)?.source, "feed:a")
        XCTAssertTrue(c.packages.isCollected("k3#0", source: "feed:b"), "the merged item is still known under its own source")
        XCTAssertFalse(c.packages.isCollected("k3#0", source: "feed:a"))
        XCTAssertEqual(c.packages.entry("k4#0", in: a.id)?.state, .failed, "a failed entry is carried into the merged collection")
        // Waiting and failed entries count as members of the collection until they become tasks.
        let p = try XCTUnwrap(c.packages.create(name: "P", members: [], batchKey: "kp", source: "playlist:p")?.package)
        c.packages.setEntry("x#0", title: "X", state: .queued, in: p.id)
        XCTAssertEqual(c.packages.progress(of: p.id).total, 1); XCTAssertEqual(c.packages.progress(of: p.id).status, .waiting)
        c.packages.setEntry("x#0", title: "X", state: .working, in: p.id)
        // A relaunch: the identities, sources and entries come back; an entry that was running is shown as stopped, ready to retry.
        c.ledger.flush(); DownloadTaskStore.close(folder: folder)
        let c2 = makeCoordinator()
        XCTAssertTrue(c2.packages.isCollected("k3#0", source: "feed:b")); XCTAssertTrue(c2.packages.isCollected("k2#0", source: "feed:a"))
        XCTAssertEqual(c2.packages.entry("x#0", in: p.id)?.state, .failed); XCTAssertTrue(c2.packages.entry("x#0", in: p.id)?.reason?.contains("Interrupted") == true)
        XCTAssertEqual(c2.packages.progress(of: p.id).status, .needsAttention)
        c2.packages.clearEntry("x#0", in: p.id); XCTAssertEqual(c2.packages.progress(of: p.id).status, .empty)
    }

    func testARefreshOfAnUnchangedFeedDownloadsNothingAndAChangedOneIsReadAgain() async throws {
        UserDefaults.standard.set(true, forKey: "UITestAllowLocalPageOrigin"); defer { UserDefaults.standard.removeObject(forKey: "UITestAllowLocalPageOrigin") }
        let key = "cond\(Int(Date().timeIntervalSince1970))"
        func rss(_ n: Int) -> Data { Data("<rss version=\"2.0\"><channel><title>Cond</title>\((1...n).map { "<item><guid>c\($0)</guid><title>E\($0)</title><enclosure url=\"https://cdn.example/\($0).mp3\" type=\"audio/mpeg\"/></item>" }.joined())</channel></rss>".utf8) }
        try await put("\(key)/feed.xml", rss(2))
        let address = url("/media/\(key)/feed.xml")
        let firstOutcome = try await FeedLoader.load(address, coordinator: c, origin: .user, ifChanged: nil)
        let first = try XCTUnwrap(firstOutcome.loadedValue)
        let v = try XCTUnwrap(first.validators, "the server's ETag / Last-Modified are kept"); XCTAssertEqual(first.feed.items.count, 2)
        // Same validators, nothing changed: "not modified", no document.
        let again = try await FeedLoader.load(address, coordinator: c, origin: .user, ifChanged: v)
        guard case .notModified = again else { return XCTFail("an unchanged feed should answer not modified") }
        // The feed changes: the new one is read, with new validators.
        try await put("\(key)/feed.xml", rss(3))
        let changedOutcome = try await FeedLoader.load(address, coordinator: c, origin: .user, ifChanged: v)
        let changed = try XCTUnwrap(changedOutcome.loadedValue)
        XCTAssertEqual(changed.feed.items.count, 3); XCTAssertNotEqual(changed.validators, v)
    }
}

extension FeedLoader.Outcome { var loadedValue: FeedLoader.Loaded? { if case .loaded(let l) = self { return l }; return nil } }


final class GalleryExtractorTests: XCTestCase {
    @MainActor
    func testGalleryPicturesAreCollectedAsFullSizeFilesOnceEach() async throws {
        let html = """
        <html><body>
        <a href="/full/one.jpg"><img src="/thumb/one.jpg"></a>
        <a href="/full/one.jpg"><img src="/thumb/one-again.jpg"></a>
        <img src="/small.jpg" srcset="/mid.jpg 1x, /big.jpg 2x">
        <a href="/page/two.html"><img src="/thumb/two.jpg"></a>
        <img src="javascript:alert(1)"><img src="data:image/png;base64,AAAA">
        <div aria-hidden="true"><img src="/hidden.jpg"></div>
        </body></html>
        """
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString(html, baseURL: URL(string: "https://gallery.example/album/"))
        let end = Date().addingTimeInterval(10)
        while (web.isLoading || web.url == nil) && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        let snapshot = await GalleryExtractor.collect(from: web)
        XCTAssertEqual(snapshot.candidates, ["https://gallery.example/full/one.jpg", "https://gallery.example/big.jpg", "https://gallery.example/thumb/two.jpg"],
                       "the linked full-size file once, the largest srcset version, a plain picture; no script/data addresses, nothing hidden")
        XCTAssertFalse(snapshot.truncated)
    }
}
