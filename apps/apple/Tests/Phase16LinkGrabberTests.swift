import XCTest
import WebKit
@testable import Browser_Setu

// Phase 16: link recognition, the LinkGrabber collection, the clipboard, page extraction and routing. Local fixtures only; nothing here contacts an outside site.

private let hex40 = "00112233445566778899aabbccddeeff00112233"
private let magnet = "magnet:?xt=urn:btih:\(hex40)&dn=Linux%20ISO&tr=https%3A%2F%2Ftracker.example.org%2Fannounce"
private let ed2kHash = "31D6CFE0D16AE931B73C59D7E0C089C0"
private let ed2k = "ed2k://|file|archive.zip|123456|\(ed2kHash)|/"

private let ed2kEscaped = ed2k.replacingOccurrences(of: "|", with: "%7C")

private func base32(_ data: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var out = "", buffer = 0, bits = 0
    for b in data { buffer = (buffer << 8) | Int(b); bits += 8; while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 } }
    if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
    return out
}
private func hexData(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s[s.index(s.startIndex, offsetBy: $0)...][..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)! }) }

// MARK: - Classification

final class LinkClassifierTests: XCTestCase {
    private func kind(_ s: String) -> LinkKind { LinkClassifier.classify(s).kind }

    func testTheKindsOfLink() {
        XCTAssertEqual(kind("https://files.example.org/a/archive.zip"), .httpResource)
        XCTAssertEqual(kind("http://files.example.org/video.MP4?x=1"), .httpResource)
        XCTAssertEqual(kind("https://example.org/releases/linux.torrent"), .torrentURL)
        XCTAssertEqual(kind("https://example.org/about"), .webpage)
        XCTAssertEqual(kind("https://example.org/"), .webpage)
        XCTAssertEqual(kind(magnet), .magnet)
        XCTAssertEqual(kind(ed2k), .ed2kFile)
        XCTAssertEqual(kind("file:///Users/me/Downloads/a.torrent"), .localTorrent)
    }

    func testAnEndingProvesNothing() {
        // A name that looks like a file is only "probably a file": it is a web address until something checks it.
        let r = LinkClassifier.classify("https://example.org/fake.zip")
        XCTAssertEqual(r.kind, .httpResource)
        XCTAssertEqual(DetectedLink(id: r.identity, original: "x", display: r.display, kind: r.kind, name: r.name, host: r.host, provenance: .pasted, profile: "p", isPrivate: false).check, .notChecked)
    }

    func testUnsupportedAndUnsafeSchemes() {
        for s in ["javascript:alert(1)", "data:text/html;base64,AAAA", "blob:https://a.org/uuid", "ftp://a.org/f.zip", "mailto:a@b.org", "tel:123", "vbscript:x", "file:///etc/passwd", "ed2k://|server|1.2.3.4|4661|/"] {
            guard case .unsupported = kind(s) else { return XCTFail("\(s) -> \(kind(s))") }
        }
    }

    func testMalformedInput() {
        for s in ["", "   ", "not a link", "example.org/file.zip", "https://", "http:///nohost", "https://exa mple.org/a.zip", "magnet:?dn=NoHash", "magnet:?xt=urn:btih:zzzz", "ed2k://|file|x|notanumber|abc|/", "https://a.org/\u{0000}x",
                  String(repeating: "a", count: 9000), "https://a.org/" + String(repeating: "a", count: 9000)] {
            guard case .invalid = kind(s) else { return XCTFail("\(s.prefix(40)) -> \(kind(s))") }
        }
    }

    func testAVersion2OnlyMagnetIsAMagnetNow() {
        XCTAssertEqual(kind("magnet:?xt=urn:btmh:1220" + String(repeating: "a", count: 64)), .magnet)          // DX-06: SHA-256 multihashes are supported
        guard case .invalid = kind("magnet:?xt=urn:btmh:1114" + String(repeating: "a", count: 40)) else { return XCTFail("another hash type is refused") }
    }

    func testWhatIsShownNeverHasTheQueryOrPassword() {
        let r = LinkClassifier.classify("https://user:hunter2@files.example.org/dl/archive.zip?sig=SECRETSIG&token=T0K#frag")
        for secret in ["hunter2", "SECRETSIG", "T0K", "frag", "user:"] { XCTAssertFalse(r.display.contains(secret), secret) }
        XCTAssertEqual(r.host, "files.example.org"); XCTAssertEqual(r.name, "archive.zip")
    }

    func testClassifyingNeverUsesTheNetwork() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/LinkGrabber/DetectedLink.swift"), encoding: .utf8)
        for forbidden in ["URLSession", "NWConnection", "Process(", "startDownload", "scheduleDownload", "TorrentRunner", "ED2KRunner"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }
}

// MARK: - Identity and normalisation

final class LinkIdentityTests: XCTestCase {
    private func id(_ s: String) -> String { LinkClassifier.classify(s).identity }

    func testDifferentSpellingsOfOneAddressAreOne() {
        XCTAssertEqual(id("HTTP://EXAMPLE.com:80/a%7eb/file.zip#top"), id("http://example.com/a~b/file.zip"))
        XCTAssertEqual(id("https://example.com:443/a/f.zip"), id("https://example.com/a/f.zip"))
        XCTAssertEqual(id("https://example.com/a%2fb.zip"), id("https://example.com/a%2Fb.zip"))
        XCTAssertEqual(id("https://example.com./f.zip"), id("https://example.com/f.zip"))
        XCTAssertEqual(id("https://example.com"), id("https://example.com/"))
    }

    func testDifferentQueriesAndPathsAreDifferentLinks() {
        XCTAssertNotEqual(id("https://example.com/dl?file=1"), id("https://example.com/dl?file=2"))
        XCTAssertNotEqual(id("https://example.com/f.zip?sig=aaa"), id("https://example.com/f.zip?sig=bbb"), "a signed link is not the same link as another signature")
        XCTAssertNotEqual(id("https://example.com/A/f.zip"), id("https://example.com/a/f.zip"), "paths are case-sensitive")
        XCTAssertNotEqual(id("http://example.com/f.zip"), id("https://example.com/f.zip"))
        XCTAssertNotEqual(id("https://a.example.com/f.zip"), id("https://b.example.com/f.zip"), "the same name on another website is not the same file")
    }

    func testATorrentIsItsInfoHashHoweverTheMagnetIsWritten() {
        let upper = "magnet:?xt=urn:btih:\(hex40.uppercased())&dn=Other%20Name"
        let b32 = "magnet:?xt=urn:btih:\(base32(hexData(hex40)))"
        XCTAssertEqual(id(magnet), id(upper)); XCTAssertEqual(id(magnet), id(b32))
        XCTAssertNotEqual(id(magnet), id("magnet:?xt=urn:btih:" + String(repeating: "ab", count: 20)))
        XCTAssertEqual(id(magnet), "btih:" + hex40)
    }

    func testAnED2KFileIsItsHashAndSizeNotItsName() {
        XCTAssertEqual(id(ed2k), id("ed2k://|file|renamed.bin|123456|\(ed2kHash.lowercased())|/"))
        XCTAssertNotEqual(id(ed2k), id("ed2k://|file|archive.zip|123457|\(ed2kHash)|/"), "a different size is a different file")
        XCTAssertNotEqual(id(ed2k), id("ed2k://|file|archive.zip|123456|" + String(repeating: "A", count: 32) + "|/"))
    }

    func testEscapeNormalisationRules() {
        XCTAssertEqual(LinkClassifier.normalizeEscapes("%41%7e%2f%2F%e2%82%AC"), "A~%2F%2F%E2%82%AC")
        XCTAssertEqual(LinkClassifier.normalizeEscapes("100%"), "100%")
        XCTAssertEqual(LinkClassifier.normalizeEscapes("%zz"), "%zz")
    }
}

// MARK: - Extraction from text

final class LinkExtractorTests: XCTestCase {
    func testFindsLinksInProseAndTrimsPunctuation() {
        let text = "Get https://files.example.org/a.zip. Also (https://files.example.org/b.iso), \(magnet) and \(ed2k)! Then see https://example.org/page?x=1&y=2; done."
        let r = LinkExtractor.candidates(in: text)
        XCTAssertEqual(r.links, ["https://files.example.org/a.zip", "https://files.example.org/b.iso", magnet, ed2k, "https://example.org/page?x=1&y=2"])
        XCTAssertFalse(r.truncated)
    }

    func testDuplicatesAreDroppedAndNoLinksIsEmpty() {
        XCTAssertEqual(LinkExtractor.candidates(in: "https://a.org/f.zip https://a.org/f.zip https://a.org/f.zip").links.count, 1)
        XCTAssertTrue(LinkExtractor.candidates(in: "just some words, no links here").links.isEmpty)
        XCTAssertTrue(LinkExtractor.candidates(in: "").links.isEmpty)
    }

    func testTheNumberOfLinksAndTheSizeOfTheTextAreBounded() {
        let many = (0..<5000).map { "https://a.org/f\($0).zip" }.joined(separator: "\n")
        let r = LinkExtractor.candidates(in: many)
        XCTAssertEqual(r.links.count, LinkExtractor.maxCandidates); XCTAssertTrue(r.truncated)
        let huge = String(repeating: "x ", count: 700_000) + "https://late.example.org/after-the-limit.zip"
        let h = LinkExtractor.candidates(in: huge)
        XCTAssertTrue(h.links.isEmpty, "text past the first megabyte is not read"); XCTAssertTrue(h.truncated)
    }

    func testItIsFastOnHostileInput() {
        let start = Date()
        _ = LinkExtractor.candidates(in: String(repeating: "http://", count: 100_000))
        _ = LinkExtractor.candidates(in: String(repeating: "magnet:?", count: 100_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

// MARK: - The collection

@MainActor
final class LinkGrabberStoreTests: XCTestCase {
    func testPastingManyLinksCollectsDedupesAndReports() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        let r = s.add(text: "https://a.org/one.zip https://a.org/two.zip \(magnet) \(ed2k) https://a.org/one.zip#again javascript:alert(1)", provenance: .pasted)
        XCTAssertEqual(r.added, 4); XCTAssertEqual(r.duplicates, 1)
        XCTAssertEqual(s.items.map(\.kind.label), ["File", "File", "Magnet", "eD2k"])
        let again = s.add(text: magnet, provenance: .clipboard)
        XCTAssertEqual(again.added, 0); XCTAssertEqual(again.duplicates, 1); XCTAssertEqual(s.notice, "Those links are already collected.")
    }

    func testUnsupportedItemsAreShownButCannotBeAdded() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["ftp://a.org/f.zip", "not a link", "https://a.org/f.zip"], provenance: .pasted)
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.items.filter(\.canAdd).count, 1)
        s.selectAllAddable()
        XCTAssertEqual(s.selection.count, 1)
    }

    func testFilteringSearchingAndSelection() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["https://a.org/alpha.zip", "https://b.org/beta.iso", magnet, ed2k, "https://c.org/page", "https://a.org/x.torrent"], provenance: .pasted)
        s.filter = .files; XCTAssertEqual(s.visible.count, 2)
        s.filter = .magnets; XCTAssertEqual(s.visible.count, 1)
        s.filter = .ed2k; XCTAssertEqual(s.visible.count, 1)
        s.filter = .torrents; XCTAssertEqual(s.visible.count, 1)
        s.filter = .other; XCTAssertEqual(s.visible.count, 1)
        s.filter = .all; s.search = "beta"; XCTAssertEqual(s.visible.map(\.name), ["beta.iso"])
        s.search = "b.org"; XCTAssertEqual(s.visible.count, 1)
        s.search = ""; s.selectAllAddable(); XCTAssertEqual(s.selection.count, 5, "the ordinary web address is not selected by Select All")
        s.remove([s.items[0].id]); XCTAssertEqual(s.items.count, 5); XCTAssertEqual(s.selection.count, 4)
        s.clear(); XCTAssertTrue(s.items.isEmpty); XCTAssertTrue(s.selection.isEmpty)
    }

    func testTheCollectionIsBounded() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        for chunk in 0..<3 { s.add(candidates: (0..<500).map { "https://a.org/c\(chunk)-\($0).zip" }, provenance: .page) }
        XCTAssertEqual(s.items.count, LinkGrabberStore.maxItems)
        XCTAssertEqual(s.notice, "The collection is full (1000 links).")
    }

    func testEachItemKeepsItsProfileAndPrivacyAndProvenance() {
        let a = LinkGrabberStore(profile: "alpha", isPrivate: false), b = LinkGrabberStore(profile: "beta", isPrivate: true)
        a.add(candidates: ["https://a.org/f.zip"], provenance: .page, group: "a.org"); b.add(candidates: ["https://a.org/f.zip"], provenance: .clipboard)
        XCTAssertEqual(a.items[0].profile, "alpha"); XCTAssertFalse(a.items[0].isPrivate); XCTAssertEqual(a.items[0].group, "a.org")
        XCTAssertEqual(b.items[0].profile, "beta"); XCTAssertTrue(b.items[0].isPrivate)
        XCTAssertEqual(a.items.count, 1); XCTAssertEqual(b.items.count, 1, "two collections never share an item")
    }

    func testSuggestionsFromExtensionsAndProgramsAreShownButNeverAddable() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["https://a.org/x.zip"], provenance: .extensionSuggestion)
        s.add(candidates: ["https://a.org/y.zip"], provenance: .automationProposal)
        XCTAssertTrue(s.items.allSatisfy { !$0.canAdd })
        s.selectAllAddable(); XCTAssertTrue(s.selection.isEmpty)
        for item in s.items { guard case .refused = LinkRouter.route(item) else { return XCTFail("\(item.provenance)") } }
    }
}

// MARK: - Routing and adding (real coordinator)

@MainActor
final class LinkRoutingTests: XCTestCase {
    private var scratch: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p16-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }

    func testTheRouteForEachKind() {
        func link(_ s: String, _ p: LinkProvenance = .pasted) -> DetectedLink {
            let c = LinkClassifier.classify(s); return DetectedLink(id: c.identity, original: s, display: c.display, kind: c.kind, name: c.name, host: c.host, provenance: p, profile: "p", isPrivate: false)
        }
        XCTAssertEqual(LinkRouter.route(link(magnet)), .preview(text: magnet))
        XCTAssertEqual(LinkRouter.route(link(ed2k)), .preview(text: ed2k))
        XCTAssertEqual(LinkRouter.route(link("https://a.org/f.zip")), .download(URL(string: "https://a.org/f.zip")!))
        XCTAssertEqual(LinkRouter.route(link("https://a.org/x.torrent")), .download(URL(string: "https://a.org/x.torrent")!))
        XCTAssertEqual(LinkRouter.route(link("file:///tmp/x.torrent")), .previewLocalTorrent(URL(string: "file:///tmp/x.torrent")!))
        for bad in ["javascript:alert(1)", "ftp://a.org/f", "nonsense"] { guard case .refused = LinkRouter.route(link(bad)) else { return XCTFail(bad) } }
    }

    func testAddingSelectedLinksStartsOnlyWebDownloadsAndOnlyPreviewsPeerToPeer() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        s.add(candidates: ["https://a.org/one.zip", "https://a.org/two.zip", "https://a.org/three.iso", magnet, ed2k], provenance: .pasted)
        s.selectAllAddable()
        var previews: [LinkRoute] = []
        let r = s.addSelected(to: c) { previews.append($0) }
        XCTAssertEqual(r.started, 3)
        XCTAssertEqual(c.ledger.records.count, 3, "exactly the three web downloads: nothing for the magnet or the eD2k link")
        XCTAssertTrue(c.ledger.records.values.allSatisfy { $0.protocolID == .http })
        XCTAssertEqual(previews, [.preview(text: magnet)], "one preview at a time; the other waits for its own decision")
        XCTAssertFalse(c.torrentsStarted); XCTAssertFalse(c.ed2kStarted, "no peer-to-peer engine was even started")
        XCTAssertEqual(s.items.map(\.kind.label), ["eD2k"], "the added and previewed ones leave the collection; the waiting one stays")
    }

    func testPreviewsOpenTheExistingModelsWithoutContactingAnyone() throws {
        let c = DownloadCoordinator()
        let m = try XCTUnwrap(try? MagnetLink.parse(magnet))
        let torrent = TorrentAddModel(coordinator: c, magnet: m)
        _ = try ED2KAddModel(coordinator: c, link: ed2k, sha256: nil)
        // Looking at a preview contacts no one and creates nothing: no details were fetched, nothing is busy, and the ledger is empty.
        XCTAssertNil(torrent.meta); XCTAssertFalse(torrent.busy); XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testTheSameAddressIsNotDownloadedTwice() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        s.add(candidates: ["https://a.org/one.zip"], provenance: .pasted); s.selectAllAddable()
        XCTAssertEqual(s.addSelected(to: c) { _ in }.started, 1)
        s.add(candidates: ["HTTPS://A.org:443/one.zip#again"], provenance: .page); s.selectAllAddable()
        let second = s.addSelected(to: c) { _ in }
        XCTAssertEqual(second.started, 0); XCTAssertEqual(second.alreadyThere, 1)
        XCTAssertEqual(c.ledger.records.count, 1)
    }

    func testAThousandLinksNeverMakeAThousandTasks() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        s.add(candidates: (0..<300).map { "https://a.org/f\($0).zip" }, provenance: .pasted); s.selectAllAddable()
        let r = s.addSelected(to: c) { _ in }
        XCTAssertEqual(r.started, LinkGrabberStore.maxBatchAdd); XCTAssertTrue(r.tooMany)
        XCTAssertEqual(c.ledger.records.count, LinkGrabberStore.maxBatchAdd)
        XCTAssertEqual(s.items.count, 100, "the ones that were not added are still there")
    }

    func testAPrivateCollectionNeverCreatesLedgerEntries() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: true)
        s.add(candidates: ["https://a.org/one.zip"], provenance: .pasted); s.selectAllAddable()
        let r = s.addSelected(to: c) { _ in }
        XCTAssertEqual(r.started, 0); XCTAssertEqual(r.refused, 1); XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testCollectingCreatesNothingAndTheGatesStayClosed() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        s.add(text: String(repeating: "https://a.org/f.zip \(magnet) \(ed2k) ", count: 50), provenance: .page)
        XCTAssertTrue(c.ledger.records.isEmpty, "a collected link is not a transfer")
        XCTAssertFalse(HTTPRequestPolicy.untrustedRequestsEnabled)
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .browserExtension).requireAllowedOrigin())
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .automation).requireAllowedOrigin())
    }
}

// MARK: - Looking up details (only on request)

@MainActor
final class LinkMetadataCheckerTests: XCTestCase {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        var calls: [URL] = []; var running = 0; var peak = 0
        func enter(_ u: URL) { lock.lock(); calls.append(u); running += 1; peak = max(peak, running); lock.unlock() }
        func leave() { lock.lock(); running -= 1; lock.unlock() }
    }
    private func waitUntilIdle(_ c: LinkMetadataChecker) async { for _ in 0..<200 where c.isRunning { try? await Task.sleep(for: .milliseconds(20)) } }

    func testNothingIsLookedUpUnlessAsked() {
        let probe = Probe(); let checker = LinkMetadataChecker { u in probe.enter(u); return LinkMetadata() }
        _ = checker
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(text: (0..<100).map { "https://a.org/f\($0).zip" }.joined(separator: " ") + " \(magnet) \(ed2k)", provenance: .page)
        XCTAssertTrue(probe.calls.isEmpty); XCTAssertTrue(s.items.allSatisfy { $0.check == .notChecked })
    }

    func testOnlyTheChosenWebAddressesAreAskedAFewAtATime() async {
        let probe = Probe()
        let checker = LinkMetadataChecker { u in probe.enter(u); defer { probe.leave() }; try await Task.sleep(for: .milliseconds(40)); return LinkMetadata(filename: "real-\(u.lastPathComponent)", size: 4096, acceptsRanges: true) }
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: (0..<12).map { "https://a.org/f\($0).zip" } + [magnet, ed2k], provenance: .pasted)
        checker.check(s.items.map(\.id), in: s)
        await waitUntilIdle(checker)
        XCTAssertEqual(probe.calls.count, 12, "never the magnet or the eD2k link")
        XCTAssertLessThanOrEqual(probe.peak, LinkMetadataChecker.maxConcurrent)
        XCTAssertEqual(s.items.filter { if case .checked = $0.check { return true }; return false }.count, 12)
        XCTAssertEqual(s.items.first?.name, "real-f0.zip", "the name the server gave replaces the one guessed from the address")
        XCTAssertEqual(s.items.last?.check, .notChecked); XCTAssertEqual(s.items[12].check, .notChecked)
    }

    func testAServerThatRefusesALookIsNotCheckedAndNotBroken() async {
        let checker = LinkMetadataChecker { u in
            switch u.lastPathComponent {
            case "head.zip": throw HTTPDownloadError(info: DownloadFailureInfo(code: "http:405", reason: "no", retryable: false))
            case "signin.zip": throw HTTPDownloadError(info: DownloadFailureInfo(code: "http:403", reason: "no", retryable: false))
            default: throw HTTPDownloadError(info: DownloadFailureInfo(code: "http:404", reason: "The file is not there: https://a.org/x?sig=SECRET", retryable: false))
            }
        }
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["https://a.org/head.zip", "https://a.org/signin.zip", "https://a.org/gone.zip"], provenance: .pasted)
        checker.check(s.items.map(\.id), in: s); await waitUntilIdle(checker)
        guard case .notCheckable = s.items[0].check, case .notCheckable = s.items[1].check else { return XCTFail("\(s.items[0].check) \(s.items[1].check)") }
        guard case .failed(let why) = s.items[2].check else { return XCTFail() }
        XCTAssertFalse(why.contains("SECRET"), "the failure text carries no signed query")
    }

    func testAPrivateCollectionIsNotLookedUp() {
        let probe = Probe(); let checker = LinkMetadataChecker { u in probe.enter(u); return LinkMetadata() }
        let s = LinkGrabberStore(profile: "p", isPrivate: true)
        s.add(candidates: ["https://a.org/f.zip"], provenance: .pasted)
        checker.check(s.items.map(\.id), in: s)
        XCTAssertTrue(probe.calls.isEmpty)
        guard case .notCheckable = s.items[0].check else { return XCTFail() }
    }

    func testCancellingStopsTheWork() async {
        let probe = Probe()
        let checker = LinkMetadataChecker { u in probe.enter(u); defer { probe.leave() }; try await Task.sleep(for: .seconds(5)); return LinkMetadata() }
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: (0..<9).map { "https://a.org/f\($0).zip" }, provenance: .pasted)
        checker.check(s.items.map(\.id), in: s)
        try? await Task.sleep(for: .milliseconds(150))
        checker.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(checker.isRunning)
        XCTAssertLessThanOrEqual(probe.calls.count, LinkMetadataChecker.maxConcurrent, "the rest were never started")
        XCTAssertTrue(s.items.allSatisfy { $0.check != .checking }, "nothing is left saying it is being checked")
    }
}

// MARK: - The clipboard

final class FakePasteboard: PasteboardSource, @unchecked Sendable {
    var changeCount = 0
    var text: String?
    var stringReads = 0, countReads = 0
    func string() -> String? { stringReads += 1; return text }
    func copy(_ t: String?) { text = t; changeCount += 1 }
}

@MainActor
final class ClipboardWatcherTests: XCTestCase {
    private func rig(isPrivate: Bool = false) -> (FakePasteboard, ClipboardLinkWatcher, () -> [[String]]) {
        let pb = FakePasteboard(); var got: [[String]] = []
        let w = ClipboardLinkWatcher(pasteboard: pb, isPrivateContext: { isPrivate }, onLinks: { got.append($0) })
        return (pb, w, { got })
    }

    func testOffByDefaultAndWhenOffTheClipboardIsNeverRead() {
        let (pb, w, got) = rig()
        XCTAssertFalse(w.isEnabled)
        pb.copy("https://a.org/f.zip"); w.poll(); w.poll()
        XCTAssertEqual(pb.stringReads, 0, "no text was read"); XCTAssertTrue(got().isEmpty)
    }

    func testOnceOnItWatchesOnlyWhatIsCopiedAfterwards() {
        let (pb, w, got) = rig()
        pb.copy("https://a.org/before.zip")                               // was there before it was switched on
        w.setEnabled(true, polling: false)
        w.poll(); XCTAssertEqual(pb.stringReads, 0, "the change counter did not move, so the text was not read")
        pb.copy("see https://a.org/after.zip please"); w.poll()
        XCTAssertEqual(got(), [["https://a.org/after.zip"]])
    }

    func testTheSameCopyIsNotImportedTwice() {
        let (pb, w, got) = rig(); w.setEnabled(true, polling: false)
        pb.copy(magnet); w.poll(); w.poll(); w.poll()
        pb.copy(magnet); w.poll()                                           // copied again: the counter moved, the content did not
        XCTAssertEqual(got().count, 1)
        pb.copy(ed2k); w.poll(); XCTAssertEqual(got().count, 2)
    }

    func testTextWithoutLinksAndHugeTextAreIgnored() {
        let (pb, w, got) = rig(); w.setEnabled(true, polling: false)
        pb.copy("my password is hunter2 and my note is private"); w.poll()
        pb.copy(String(repeating: "x", count: ClipboardLinkWatcher.maxTextBytes + 1) + " https://a.org/f.zip"); w.poll()
        XCTAssertTrue(got().isEmpty)
    }

    func testAPrivateContextNeverReadsOrImports() {
        let (pb, w, got) = rig(isPrivate: true); w.setEnabled(true, polling: false)
        pb.copy("https://a.org/f.zip"); w.poll()
        XCTAssertEqual(pb.stringReads, 0); XCTAssertTrue(got().isEmpty)
    }

    func testSwitchingOffStopsIt() {
        let (pb, w, got) = rig(); w.setEnabled(true, polling: false)
        w.setEnabled(false)
        pb.copy("https://a.org/f.zip"); w.poll()
        XCTAssertEqual(pb.stringReads, 0); XCTAssertTrue(got().isEmpty)
    }

    func testWhatItFindsGoesToTheCollectionNeverToTheDownloadList() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/BrowserModel.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private(set) lazy var clipboardWatcher"))
        let block = String(text[start.lowerBound...].prefix(700))
        XCTAssertTrue(block.contains("add(candidates: links, provenance: .clipboard)"))
        XCTAssertFalse(block.contains("scheduleDownload"))
    }

    func testItNeverKeepsOrLogsTheText() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/LinkGrabber/LinkGrabberStore.swift"), encoding: .utf8)
        let a = try XCTUnwrap(src.range(of: "final class ClipboardLinkWatcher")), b = try XCTUnwrap(src.range(of: "// MARK: - Links the person clicks"))
        let body = String(src[a.lowerBound..<b.lowerBound])
        for word in ["NSLog", "print(", "Logger", "os_log", "lastText", "UserDefaults"] { XCTAssertFalse(body.contains(word), word) }
    }
}

// MARK: - Clicks on magnet and eD2k links

@MainActor
final class LinkNavigationTests: XCTestCase {
    func testOnlyAClickOpensAnythingAndOnlyOncePerClick() {
        var gate = LinkNavigationGate()
        let m = URL(string: magnet)!, e = URL(string: ed2kEscaped)!
        XCTAssertEqual(gate.decide(url: m, linkActivated: true, now: 100), .open(magnet))
        XCTAssertEqual(gate.decide(url: m, linkActivated: true, now: 100.2), .ignore, "WebKit asked twice for one click")
        XCTAssertEqual(gate.decide(url: e, linkActivated: true, now: 100.3), .open(ed2k), "a different link is a different click")
        XCTAssertEqual(gate.decide(url: m, linkActivated: true, now: 102), .open(magnet), "clicked again later")
        XCTAssertEqual(gate.decide(url: m, linkActivated: false, now: 200), .ignore, "a page that navigates by itself gets nothing")
        XCTAssertEqual(gate.decide(url: URL(string: "https://a.org/f.zip")!, linkActivated: true, now: 300), .notOurs)
        XCTAssertEqual(gate.decide(url: URL(string: "mailto:a@b.org")!, linkActivated: true, now: 300), .notOurs)
    }

    private func makeModel() -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p16-\(UUID().uuidString)", profile: "p16")
        m.interceptP2PLinks = true
        return m
    }

    func testTheModelOpensThePreviewForAClickAndNotForAScript() {
        let m = makeModel()
        XCTAssertTrue(m.handleCustomLink(URL(string: magnet)!, linkActivated: true))
        XCTAssertEqual(m.addDownloadPrefill, magnet)
        m.addDownloadPrefill = nil
        XCTAssertTrue(m.handleCustomLink(URL(string: magnet)!, linkActivated: true), "swallowed: a duplicate callback does nothing")
        XCTAssertNil(m.addDownloadPrefill)
        XCTAssertTrue(m.handleCustomLink(URL(string: ed2kEscaped)!, linkActivated: false), "handled (stopped) but not opened")
        XCTAssertNil(m.addDownloadPrefill)
        XCTAssertTrue(m.handleCustomLink(URL(string: ed2kEscaped)!, linkActivated: true))
        XCTAssertEqual(m.addDownloadPrefill, ed2k, "the escaped bars are put back for the preview")
        XCTAssertFalse(m.handleCustomLink(URL(string: "https://a.org/")!, linkActivated: true), "ordinary navigation is untouched")
        XCTAssertTrue(m.downloads.ledger.records.isEmpty); XCTAssertFalse(m.downloads.torrentsStarted); XCTAssertFalse(m.downloads.ed2kStarted)
    }

    func testTurningItOffRestoresTheOldBehaviour() {
        let m = makeModel(); m.interceptP2PLinks = false
        XCTAssertFalse(m.handleCustomLink(URL(string: magnet)!, linkActivated: true))
        XCTAssertNil(m.addDownloadPrefill)
    }

    func testAClickInARealPageReachesTheModelOnlyWithARealGesture() async throws {
        let m = makeModel()
        let tab = m.openTab(url: nil, isPrivate: false)
        let web = try XCTUnwrap(tab.engine.hostView as? WKWebView)
        let webKitTab = try XCTUnwrap(tab.engine as? WebKitTab)
        web.loadHTMLString("<html><body><a id='m' href='\(magnet)'>get</a><a id='e' href='\(ed2k)'>ed2k</a><a id='b' target='_blank' href='\(magnet)&dn=Blank'>blank</a></body></html>", baseURL: URL(string: "http://127.0.0.1:18766/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        // A script clicking by itself, with no gesture from the person: nothing opens.
        webKitTab.lastGesture = .distantPast
        _ = try? await web.evaluateJavaScript("document.getElementById('m').click()")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(m.addDownloadPrefill, "a page cannot open the preview by clicking its own link")
        // The person did something in the page a moment ago: the click counts.
        m.addDownloadPrefill = nil; webKitTab.lastGesture = Date()
        _ = try? await web.evaluateJavaScript("document.getElementById('m').click()")
        for _ in 0..<60 where m.addDownloadPrefill == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(m.addDownloadPrefill, magnet, "the click on a magnet link opened its preview")
        XCTAssertEqual(web.url?.scheme, "http", "the page did not navigate away or hand the link to another application")
        m.addDownloadPrefill = nil; webKitTab.lastGesture = Date()
        _ = try? await web.evaluateJavaScript("document.getElementById('e').click()")
        for _ in 0..<60 where m.addDownloadPrefill == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(m.addDownloadPrefill, ed2k, "an eD2k link, whose bars the browser's own URL parser refuses, still reaches its preview")
        // target=_blank: the preview, and no empty tab.
        m.addDownloadPrefill = nil; webKitTab.lastGesture = Date()
        let tabsBefore = m.tabs.count
        _ = try? await web.evaluateJavaScript("document.getElementById('b').click()")
        for _ in 0..<60 where m.addDownloadPrefill == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(m.addDownloadPrefill, magnet + "&dn=Blank")
        XCTAssertEqual(m.tabs.count, tabsBefore, "no blank tab was opened")
        XCTAssertTrue(m.downloads.ledger.records.isEmpty)
        XCTAssertFalse(m.downloads.torrentsStarted)
    }

    func testTheNavigationCodeCompletesItsCallbackOnEveryPath() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Engines/WebKit/WebKitEngine.swift"), encoding: .utf8)
        let a = try XCTUnwrap(text.range(of: "engineCustomLink(target")), b = try XCTUnwrap(text.range(of: "A sign-in form is read here", range: a.upperBound..<text.endIndex))
        let block = String(text[a.lowerBound..<b.lowerBound])
        XCTAssertTrue(block.contains("return .cancel"))
        XCTAssertFalse(block.contains("decisionHandler"), "this is the async form: the policy is its return value, so it cannot be answered twice")
    }
}

// MARK: - Links on the open page

@MainActor
final class PageExtractionTests: XCTestCase {
    private func page(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://example.org/dir/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        return web
    }

    func testOnlyLikelyDownloadsAreCollectedAndNothingElseIsRead() async throws {
        let web = try await page("""
        <a href="files/archive.zip">zip</a><a href="https://cdn.example.org/linux.torrent">t</a><a href="\(magnet)">m</a><a href="\(ed2k)">e</a>
        <a href="/about">about</a><a href="https://example.org/get?id=7" download>marked</a><a href="javascript:alert(1)">js</a><a href="mailto:a@b.org">mail</a>
        <a href="data:text/html;base64,AAAA">d</a><a href="https://example.org/files/archive.zip">dup</a>
        <form><input type="password" value="hunter2"><input type="hidden" name="csrf" value="CSRFTOKEN123"><textarea>my private message SECRETNOTE</textarea></form>
        <p>API key: sk-live-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789</p>
        """)
        let raw = await LinkPageExtractor.collect(from: web)
        let chosen = LinkPageExtractor.downloadCandidates(raw)
        XCTAssertEqual(Set(chosen), Set(["https://example.org/dir/files/archive.zip", "https://cdn.example.org/linux.torrent", magnet, ed2k, "https://example.org/get?id=7", "https://example.org/files/archive.zip"]))
        let everything = raw.links.map(\.href).joined(separator: " ")
        for secret in ["hunter2", "CSRFTOKEN123", "SECRETNOTE", "sk-live", "javascript", "mailto"] { XCTAssertFalse(everything.contains(secret), secret) }
        XCTAssertFalse(raw.truncated)
    }

    func testTheResultAndTheWorkAreBounded() async throws {
        let many = (0..<6000).map { "<a href='https://a.org/f\($0).zip'>x</a>" }.joined()
        let web = try await page(many)
        let r = await LinkPageExtractor.collect(from: web)
        XCTAssertEqual(r.links.count, LinkPageExtractor.maxResults); XCTAssertTrue(r.truncated)
    }

    func testCancellingGivesNothing() async throws {
        let web = try await page((0..<200).map { "<a href='https://a.org/f\($0).zip'>x</a>" }.joined())
        let t = Task { await LinkPageExtractor.collect(from: web) }
        t.cancel()
        let r = await t.value
        XCTAssertTrue(r.links.isEmpty, "a cancelled collection hands back nothing")
    }

    func testItOnlyRunsWhenAskedAndIsNotInstalledInAnyPage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ext = try String(contentsOf: root.appendingPathComponent("Engines/WebKit/LinkPageExtractor.swift"), encoding: .utf8)
        XCTAssertFalse(ext.contains("WKUserScript")); XCTAssertTrue(ext.contains(".defaultClient"), "the browser's own world, which the page cannot see")
        for word in [".value", "innerText", "textContent", "innerHTML", "FormData", "cookie", "localStorage"] { XCTAssertFalse(LinkPageExtractor.script.contains(word), word) }
        let engine = try String(contentsOf: root.appendingPathComponent("Engines/WebKit/WebKitEngine.swift"), encoding: .utf8)
        XCTAssertEqual(engine.components(separatedBy: "collectLinks()").count - 1, 1, "one definition, no automatic caller in the engine")
        let model = try String(contentsOf: root.appendingPathComponent("Shared/BrowserModel.swift"), encoding: .utf8)
        XCTAssertEqual(model.components(separatedBy: ".collectLinks()").count - 1, 1, "called from the one user action")
    }

    func testAPrivateTabsLinksGoToThePrivateCollection() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p16-\(UUID().uuidString)", profile: "p16b")
        let normal = m.linkGrabber
        let tab = m.openTab(url: nil, isPrivate: true)
        XCTAssertTrue(tab.leavesNoTrace)
        XCTAssertTrue(m.linkGrabber.isPrivate); XCTAssertFalse(normal.isPrivate)
        XCTAssertFalse(m.linkGrabber === normal)
        m.linkGrabber.add(candidates: ["https://a.org/p.zip"], provenance: .page)
        XCTAssertTrue(normal.items.isEmpty, "nothing from a private tab appears in the ordinary collection")
    }
}

// MARK: - Scope

final class Phase16ScopeTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }

    func testThereIsOneClassifierAndItReusesTheExistingParsers() throws {
        let c = try src("Shared/Downloads/LinkGrabber/DetectedLink.swift")
        XCTAssertTrue(c.contains("MagnetLink.parse") && c.contains("ED2KLink.parse"))
        for forbidden in ["func parseBencode", "func md4", "struct MagnetLink", "enum ED2KLink"] { XCTAssertFalse(c.contains(forbidden), "a second parser: \(forbidden)") }
        XCTAssertEqual(try src("Shared/Downloads/LinkGrabber/LinkGrabberStore.swift").components(separatedBy: "LinkClassifier.classify(").count - 1, 1)
    }

    func testTheLinkGrabberCodeStartsNoPeerToPeerAndOnlyOneCallCreatesTasks() throws {
        for file in ["DetectedLink.swift", "LinkGrabberStore.swift"] {
            let t = try src("Shared/Downloads/LinkGrabber/" + file)
            for forbidden in ["torrents.add", "torrents.fetchDetails", "ed2k.add", "TorrentRunner", "ED2KRunner", "untrustedRequestsEnabled ="] { XCTAssertFalse(t.contains(forbidden), "\(file) \(forbidden)") }
        }
        XCTAssertEqual(try src("Shared/Downloads/LinkGrabber/LinkGrabberStore.swift").components(separatedBy: ".scheduleDownload(").count - 1, 1)
    }

    func testTheWebKitDownloadPathIsUntouched() throws {
        let e = try src("Engines/WebKit/WebKitEngine.swift")
        XCTAssertEqual(e.components(separatedBy: "didBecome download: WKDownload").count - 1, 2)
        XCTAssertEqual(e.components(separatedBy: "downloads.adopt(download)").count - 1, 2)
    }
}


// MARK: - Fixes from the independent review

@MainActor
final class Phase16ReviewFixTests: XCTestCase {
    func testSelectAllLeavesOrdinaryWebAddressesAlone() {
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["https://a.org/f.zip", "https://a.org/page1", "https://a.org/page2", magnet], provenance: .pasted)
        s.selectAllAddable()
        XCTAssertEqual(s.selectedItems.map(\.kind.label).sorted(), ["File", "Magnet"])
    }

    func testAHiddenLinkIsNeverAddedBecauseItWasSelectedBeforeTheFilterChanged() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        s.add(candidates: (0..<5).map { "https://a.org/f\($0).zip" } + [magnet], provenance: .pasted)
        s.selectAllAddable(); s.filter = .magnets
        XCTAssertEqual(s.selectedItems.count, 1)
        _ = s.addSelected(to: c) { _ in }
        XCTAssertTrue(c.ledger.records.isEmpty, "the five hidden files were not started")
    }

    func testAnAddressOnYourOwnNetworkIsNeverAddedOrCheckedFromHereWhateverItsSource() async {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: false)
        for host in ["127.0.0.1", "192.168.1.1", "169.254.169.254", "localhost", "10.0.0.5"] { s.add(candidates: ["http://\(host)/secret.zip"], provenance: .page) }
        s.add(candidates: ["http://127.0.0.1:8080/clip.zip"], provenance: .clipboard)
        s.add(candidates: ["http://127.0.0.1:8080/typed.zip"], provenance: .pasted)
        s.selection = Set(s.items.map(\.id))
        let r = s.addSelected(to: c) { _ in }
        XCTAssertEqual(r.started, 0, "pasting is not permission either: the same rule for every source")
        XCTAssertEqual(r.refused, 7)
        var asked = 0
        let checker = LinkMetadataChecker { _ in asked += 1; return LinkMetadata() }
        s.add(candidates: ["http://192.168.0.9/also.zip"], provenance: .pasted)
        checker.check(s.items.map(\.id), in: s)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asked, 0)
        guard case .notCheckable = s.items.last!.check else { return XCTFail() }
    }

    func testCheckingTwiceDoesNotLetTheFirstRunWipeTheSecond() async {
        let checker = LinkMetadataChecker { _ in try await Task.sleep(for: .seconds(2)); return LinkMetadata() }
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(candidates: ["https://a.org/a.zip", "https://a.org/b.zip"], provenance: .pasted)
        checker.check(s.items.map(\.id), in: s)
        try? await Task.sleep(for: .milliseconds(100))
        checker.check(s.items.map(\.id), in: s)                      // pressed again
        try? await Task.sleep(for: .milliseconds(400))                 // the first run has finished cancelling
        XCTAssertTrue(checker.isRunning, "the second run is still the current one")
        checker.cancel()
        XCTAssertFalse(checker.isRunning)
    }

    func testASecretInThePathNeverReachesTheNameColumn() {
        let token = String(repeating: "a1b2c3d4", count: 8)
        let r = LinkClassifier.classify("https://files.example.org/dl/\(token)")
        XCTAssertFalse(r.name.contains(token)); XCTAssertEqual(r.name, "files.example.org")
        XCTAssertFalse(r.display.contains(token))
        let bad = LinkClassifier.classify("https://user:hunter2@host.example.org/\u{1}")
        XCTAssertFalse(bad.name.contains("hunter2")); XCTAssertFalse(bad.display.contains("hunter2"))
        XCTAssertEqual(LinkClassifier.classify("https://a.org/Annual%20Report.pdf").name, "Annual Report.pdf", "an ordinary name is shown as it is")
    }

    func testDifferentLoginsAreDifferentLinks() {
        XCTAssertNotEqual(LinkClassifier.classify("https://a:1@h.org/f.zip").identity, LinkClassifier.classify("https://a:2@h.org/f.zip").identity)
        XCTAssertNotEqual(LinkClassifier.classify("https://a:1@h.org/f.zip").identity, LinkClassifier.classify("https://h.org/f.zip").identity)
        XCTAssertFalse(LinkClassifier.classify("https://a:1@h.org/f.zip").display.contains("a:1"))
    }

    func testAnSVGAnchorDoesNotBreakCollection() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        web.loadHTMLString("<html><body><svg width='10' height='10'><a href='https://example.org/svg-link'><rect width='5' height='5'/></a></svg><a href='https://example.org/real.zip'>zip</a></body></html>", baseURL: URL(string: "https://example.org/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        let r = await LinkPageExtractor.collect(from: web)
        XCTAssertTrue(LinkPageExtractor.downloadCandidates(r).contains("https://example.org/real.zip"), "the real link is found even though an SVG link comes first")
    }

    func testABlankTabLinkAndTheTabControllerPathOpenThePreview() throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p16-\(UUID().uuidString)", profile: "p16c")
        m.interceptP2PLinks = true
        let tab = m.openTab(url: nil, isPrivate: false)
        let before = m.tabs.count
        XCTAssertTrue(tab.engineCustomLink(URL(string: magnet)!, linkActivated: true))
        XCTAssertEqual(m.addDownloadPrefill, magnet); XCTAssertEqual(m.tabs.count, before)
    }

    func testAPrefillThatArrivesWhileAnotherIsShownIsNotLost() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macOS/Downloads/DownloadsDashboard.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".id(prefill ?? prefillTorrent?.path ?? \"form\")"), "a new request rebuilds the form")
        XCTAssertTrue(src.contains("onChange(of: adding) { _, now in if !now { prefill = nil; prefillTorrent = nil } }"), "and a dismissed popover forgets its request")
        XCTAssertTrue(src.contains("fileSize ?? Int.max"), "an unknown size counts as too large")
    }
}


// MARK: - Phase 16 privacy corrections (Phase 17 prerequisite)

@MainActor
final class Phase17PrerequisiteTests: XCTestCase {
    private func model() -> BrowserModel { BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p17-\(UUID().uuidString)", profile: "p17") }

    func testAMagnetClickInAPrivateTabNeverReachesTheOrdinaryProfile() {
        let m = model(); m.interceptP2PLinks = true
        let tab = m.openTab(url: nil, isPrivate: true)
        XCTAssertTrue(tab.leavesNoTrace)
        XCTAssertTrue(tab.engineCustomLink(URL(string: magnet)!, linkActivated: true), "handled: the link goes nowhere else")
        XCTAssertNil(m.addDownloadPrefill, "no preview in the ordinary profile")
        XCTAssertNotNil(m.linkNotice)
        XCTAssertTrue(m.downloads.ledger.records.isEmpty); XCTAssertFalse(m.downloads.torrentsStarted)
        // The same click in an ordinary tab still works.
        let normal = m.openTab(url: nil, isPrivate: false)
        XCTAssertTrue(normal.engineCustomLink(URL(string: magnet)!, linkActivated: true))
        XCTAssertEqual(m.addDownloadPrefill, magnet)
    }

    func testAPrivateCollectionNeverOpensAPreview() {
        let c = DownloadCoordinator()
        let s = LinkGrabberStore(profile: c.profileName, isPrivate: true)
        s.add(candidates: [magnet, ed2k], provenance: .pasted); s.selection = Set(s.items.map(\.id))
        var opened = 0
        let r = s.addSelected(to: c) { _ in opened += 1 }
        XCTAssertEqual(opened, 0); XCTAssertEqual(r.refused, 2); XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testThePrivateCollectionEndsWithThePrivateSession() {
        let m = model()
        let priv = m.openTab(url: nil, isPrivate: true)
        m.linkGrabber.add(candidates: ["https://a.org/p.zip"], provenance: .page)
        XCTAssertEqual(m.linkGrabber.items.count, 1)
        let normalStore = m.openTab(url: nil, isPrivate: false)
        m.select(normalStore.id)
        m.linkGrabber.add(candidates: ["https://a.org/n.zip"], provenance: .page)
        m.closeTab(id: priv.id, force: true)                       // the last private tab
        m.select(normalStore.id)
        XCTAssertEqual(m.linkGrabber.items.map(\.name), ["n.zip"], "the ordinary collection is untouched")
        _ = m.openTab(url: nil, isPrivate: true)
        XCTAssertTrue(m.linkGrabber.items.isEmpty, "and the private one started empty again")
    }
}
