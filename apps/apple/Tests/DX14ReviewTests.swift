import XCTest
import SwiftUI
@testable import Browser_Setu

/// DX-14 follow-ups: redirect targets are checked by what they resolve to, a credentialed link is not mistaken for a duplicate, one free-space rule, a typed magnet link, a failed secret write,
/// and the bounded private-name list. Names are looked up through a stand-in resolver, so no network is used; the Keychain is replaced by counters.
@MainActor
final class DX14ReviewTests: XCTestCase {
    private func resolver(_ table: [String: (HostClass, [String]?)]) -> (String) async -> (kind: HostClass, resolved: [String]?) {
        { host in let r = table[host] ?? (.publicHost, ["93.184.216.34"]); return (r.0, r.1) }
    }
    private func model() -> BrowserModel { BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-dx14-\(UUID().uuidString)", profile: "default") }

    // MARK: Redirects by what the name resolves to

    func testAProviderRedirectToAPublicNameThatResolvesIntoTheNetworkIsRefused() async {
        let from = URL(string: "https://api.example/a")!
        let trap = URL(string: "https://rebind.example/file")!
        let table: [String: (HostClass, [String]?)] = ["rebind.example": (.privateNetwork, ["10.0.0.5"]), "api.example": (.publicHost, ["93.184.216.34"]), "cdn.example": (.publicHost, ["93.184.216.35"])]
        let refused = await URLSessionProviderTransport.Delegate.resolvesSafely(from: from, to: trap, chain: [from], resolve: resolver(table))
        XCTAssertFalse(refused, "the name looks public but leads into the local network")
        let fine = await URLSessionProviderTransport.Delegate.resolvesSafely(from: from, to: URL(string: "https://cdn.example/f")!, chain: [from], resolve: resolver(table))
        XCTAssertTrue(fine)
        let unknown = await URLSessionProviderTransport.Delegate.resolvesSafely(from: from, to: URL(string: "https://nowhere.example/f")!, chain: [from], resolve: resolver(["nowhere.example": (.publicHost, nil)]))
        XCTAssertTrue(unknown, "a name that cannot be looked up cannot be connected to either: the person's own local access is why it is not refused here")
    }

    func testAProviderOnTheLocalNetworkMayStillSendToItsOwnStorage() async {
        let from = URL(string: "http://192.168.1.20:9000/api")!
        let table: [String: (HostClass, [String]?)] = ["192.168.1.20": (.privateNetwork, nil), "192.168.1.21": (.privateNetwork, nil)]
        let ok = await URLSessionProviderTransport.Delegate.resolvesSafely(from: from, to: URL(string: "http://192.168.1.21:9000/blob")!, chain: [from], resolve: resolver(table))
        XCTAssertTrue(ok, "a self-hosted service is the person's own and keeps working")
    }

    func testTheCredentialRulesOfTheProviderRedirectAreUnchanged() {
        var req = URLRequest(url: URL(string: "https://cdn.example/b")!); req.setValue("Bearer x", forHTTPHeaderField: "Authorization"); req.setValue("a=b", forHTTPHeaderField: "Cookie")
        let other = URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://cdn.example/b")!, request: req, check: { _ in })
        XCTAssertNil(other?.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(other?.value(forHTTPHeaderField: "Cookie"))
        let same = URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://api.example/b")!, request: req, check: { _ in })
        XCTAssertEqual(same?.value(forHTTPHeaderField: "Authorization"), "Bearer x")
    }

    func testATrackerRedirectIsCheckedByWhatTheNameResolvesToAndNeverDowngraded() async {
        let https = URL(string: "https://tracker.example/announce")!
        let leak = URL(string: "https://rebind.example/a")!
        let table: [String: (HostClass, [String]?)] = ["rebind.example": (.loopback, ["127.0.0.1"])]
        let a = await HTTPTrackerClient.RedirectGuard.permits(from: https, to: leak, authorized: { _ in false }, resolve: resolver(table))
        XCTAssertFalse(a)
        let b = await HTTPTrackerClient.RedirectGuard.permits(from: https, to: URL(string: "http://other.example/a")!, authorized: { _ in false }, resolve: resolver(table))
        XCTAssertFalse(b, "a secure address is never sent on to a plain one")
        let c = await HTTPTrackerClient.RedirectGuard.permits(from: https, to: URL(string: "https://other.example/a")!, authorized: { _ in false }, resolve: resolver(table))
        XCTAssertTrue(c)
        let d = await HTTPTrackerClient.RedirectGuard.permits(from: https, to: leak, authorized: { $0.host == "rebind.example" }, resolve: resolver(table))
        XCTAssertTrue(d, "a tracker the person authorised may be on the local network")
        let e = await HTTPTrackerClient.RedirectGuard.permits(from: https, to: URL(string: "file:///etc/passwd")!, authorized: { _ in true }, resolve: resolver(table))
        XCTAssertFalse(e)
    }

    // MARK: Credentialed links and duplicates

    func testALinkWithAnAccountIsNeverCalledADuplicateAndAPlainOneIsMatchedByItsResource() {
        var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://user:secret@files.test/a.zip")), filename: "a.zip")
        r.state = .running
        let live = LinkClassifier.liveKeys([r])
        XCTAssertFalse(r.source.url?.contains("secret") ?? true, "the stored address has no password")
        XCTAssertFalse(LinkClassifier.isLive(URL(string: "https://user:secret@files.test/a.zip")!, in: live), "an address with an account is not skipped on a guess")
        XCTAssertTrue(LinkClassifier.isLive(URL(string: "https://FILES.test:443/a.zip#top")!, in: live), "the same resource spelled differently is the same download")
        XCTAssertFalse(LinkClassifier.isLive(URL(string: "https://files.test/b.zip")!, in: live))
        var done = r; done.state = .completed
        XCTAssertTrue(LinkClassifier.liveKeys([done]).isEmpty, "a finished download is not live")
        var priv = r; priv.isPrivate = true
        XCTAssertTrue(LinkClassifier.liveKeys([priv]).isEmpty, "private ones are never consulted")
        XCTAssertFalse(LinkClassifier.resourceKey(URL(string: "https://u:p@files.test/a")!).contains("p@"))
    }

    // MARK: One free-space rule

    func testTheFreeSpaceRuleKeepsEachEnginesOwnMargin() {
        XCTAssertTrue(DiskSpace.fits(needed: 1_000, available: 1_000, divisor: 0), "no spare asked for: an exact fit is enough")
        XCTAssertFalse(DiskSpace.fits(needed: 1_000, available: 999, divisor: 0))
        XCTAssertFalse(DiskSpace.fits(needed: 1_000_000_000, available: 1_200_000_000, floor: 256_000_000, divisor: 50), "providers: 2% or 256 MB spare")
        XCTAssertTrue(DiskSpace.fits(needed: 1_000_000_000, available: 1_300_000_000, floor: 256_000_000, divisor: 50))
        XCTAssertTrue(DiskSpace.isTight(needed: 1_000_000_000, available: 1_099_999_999), "tight as before: 5% or 100 MB")
        XCTAssertFalse(DiskSpace.isTight(needed: 1_000_000_000, available: 1_100_000_000))
        XCTAssertFalse(DiskSpace.isTight(needed: 1_000_000_000, available: 1_200_000_000))
        XCTAssertFalse(DiskSpace.isTight(needed: 0, available: 0))
    }

    // MARK: Magnet link in the address bar

    func testATypedMagnetLinkOpensTheDownloadPreviewAndIsNotSearchedOrNavigated() {
        let m = model()
        let tabsBefore = m.tabs.count
        let magnet = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Example"
        m.navigate(input: magnet)
        XCTAssertEqual(m.addDownloadPrefill, magnet, "the preview is asked for, which asks before anything is fetched")
        XCTAssertEqual(m.tabs.count, tabsBefore, "no tab was opened and nothing was searched")
        m.addDownloadPrefill = nil
        m.navigate(input: "  MAGNET:?xt=urn:btih:abc  ")
        XCTAssertEqual(m.addDownloadPrefill, "MAGNET:?xt=urn:btih:abc", "case and spaces around it do not matter")
        m.addDownloadPrefill = nil
        m.navigate(input: "magnetic fields explained")
        XCTAssertNil(m.addDownloadPrefill, "an ordinary search that starts with the same letters is left alone")
    }

    func testATypedMagnetLinkIsRefusedInAPrivateTab() {
        let m = model()
        _ = m.openTab(url: nil, isPrivate: true)
        XCTAssertEqual(m.active?.leavesNoTrace, true)
        m.addDownloadPrefill = nil
        m.navigate(input: "magnet:?xt=urn:btih:abc")
        XCTAssertNil(m.addDownloadPrefill, "nothing about it reaches the ordinary Downloads list")
        XCTAssertNotNil(m.linkNotice)
    }

    func testTheOldNameRuleStaysForOldRecordsAndTheSpaceRuleCannotOverflow() {
        XCTAssertEqual(DownloadCoordinator.legacySafeName(".hidden.txt"), "hidden.txt")
        XCTAssertFalse(DiskSpace.fits(needed: Int64.max, available: Int64.max, floor: 100, divisor: 20), "no overflow trap: it simply does not fit")
    }

    func testOnlyAnUntitledTabShownByItsNumericHostIsDescribedInWords() {
        XCTAssertEqual(TabController.spoken("127.0.0.1", titled: false), "Page without a title at 127.0.0.1")
        XCTAssertEqual(TabController.spoken("[::1]", titled: false), "Page without a title at [::1]")
        for real in ["1.5", "10.5", "3:30", "cafe.bad", "12:00"] { XCTAssertEqual(TabController.spoken(real, titled: true), real, "a real title is spoken as it is") }
        XCTAssertEqual(TabController.spoken("Example Domain", titled: false), "Example Domain")
        XCTAssertEqual(TabController.spoken("example.com", titled: false), "example.com", "a host name that is not numeric is already readable")
    }

    // MARK: A long status is not cut off

    func testALongStatusWrapsInsideTheRowInsteadOfBeingCutOff() throws {
        func row(_ state: DownloadState, retries: Int = 0) throws -> DownloadRow {
            var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://files.test/a.bin")), filename: "a.bin")
            r.state = state; r.retryCount = retries
            return try XCTUnwrap(DownloadRowProjector.rows(from: DownloadsSnapshot(records: [r])).first)
        }
        func height(_ r: DownloadRow) throws -> CGFloat {
            let renderer = ImageRenderer(content: DownloadStatusCell(row: r).frame(width: 140, alignment: .leading))      // 140: the narrowest the Status column gets
            renderer.scale = 2
            return try XCTUnwrap(renderer.nsImage).size.height
        }
        let long = try row(.retrying, retries: 11)
        XCTAssertEqual(long.statusText, "Trying again (attempt 12)", "the wording is unchanged")
        let short = try row(.completed)
        let hLong = try height(long), hShort = try height(short)
        XCTAssertGreaterThan(hLong, hShort + 8, "the long status takes a second line: \(hLong) vs \(hShort)")
        XCTAssertLessThanOrEqual(hLong, 40, "and still fits in the two-line row (about 42 points): \(hLong)")
    }

    // MARK: A failed secret write

    func testAFailedSecretWriteLeavesTheSavedSecretAlone() {
        var deletes = 0
        let failing = SecretStore.Operations(update: { _, _ in errSecInteractionNotAllowed }, delete: { _ in deletes += 1; return errSecSuccess })
        XCTAssertEqual(SecretStore.put(Data("new".utf8), service: "bs.test.dx14.\(UUID().uuidString)", account: "a", ops: failing), .failed)
        XCTAssertEqual(deletes, 0, "nothing was deleted: the old secret is exactly as it was")
        var cloudDeletes = 0
        let working = SecretStore.Operations(update: { _, _ in errSecSuccess }, delete: { _ in cloudDeletes += 1; return errSecSuccess })
        XCTAssertEqual(SecretStore.put(Data("new".utf8), service: "bs.test.dx14.\(UUID().uuidString)", account: "a", ops: working), .local, "replaced in place")
        XCTAssertEqual(cloudDeletes, 1, "only the leftover iCloud copy is removed")
    }

    // MARK: Memory and accessibility changes (source guards: the behaviour needs a running extractor / the screen reader)

    func testTheExtractorsTimeLimitDoesNotHoldTheRunsOutputAndPackageControlsAreLabelled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let extractor = try String(contentsOf: root.appendingPathComponent("Shared/Downloads/Media/ExternalExtractor.swift"))
        XCTAssertTrue(extractor.contains("Task { [weak box] in try? await Task.sleep"), "the sleeping limit holds the box weakly")
        let packages = try String(contentsOf: root.appendingPathComponent("macOS/Downloads/PackagesView.swift"))
        XCTAssertTrue(packages.contains(".accessibilityLabel(\"Package actions\")"))
        XCTAssertTrue(packages.contains("\"Hide items\" : \"Show items\""))
    }

    // MARK: The private-name list is bounded

    func testThePrivateNameListStopsGrowing() {
        let c = model().downloads
        for i in 0..<(DownloadCoordinator.privateNameLimit + 300) { c.rememberPrivateName("private-\(i).bin") }
        XCTAssertEqual(c.privateNameCount, DownloadCoordinator.privateNameLimit)
        c.rememberPrivateName("private-\(DownloadCoordinator.privateNameLimit + 299).bin")
        XCTAssertEqual(c.privateNameCount, DownloadCoordinator.privateNameLimit, "a name seen again is not added twice")
    }
}
