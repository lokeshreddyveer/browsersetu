import XCTest
@testable import Browser_Setu

final class SyncRulesTests: XCTestCase {
    private func bookmark(_ url: String) -> BackupPayload.Bookmark { .init(url: url, title: url, folder: "") }

    func testBookmarksAreAddedNotDuplicatedAndUnsafeOnesAreSkipped() {
        let added = SyncRules.bookmarksToAdd(remote: [bookmark("https://a.test"), bookmark("https://b.test"), bookmark("https://a.test"),
                                                      bookmark("javascript:alert(1)"), bookmark("file:///etc/passwd")],
                                             existing: ["https://b.test"])
        XCTAssertEqual(added.map(\.url), ["https://a.test"])
    }

    func testOnlySettingsThatMeanTheSameEverywhereAreTaken() {
        let accepted = SyncRules.acceptedSettings(["search_template": "x", "layout_preset": "sidebar", "sidebar_width": "300", "evil": "1", "accent": "blue"])
        XCTAssertEqual(Set(accepted.keys), ["search_template", "accent"], "layout and sidebar choices belong to each screen")
    }

    func testTabsAreWebAddressesOnlyAndCapped() {
        let many = (0..<500).map { BackupPayload.Tab(url: "https://t\($0).test", title: "t") } + [.init(url: "about:blank", title: ""), .init(url: "javascript:1", title: "")]
        let clean = SyncRules.cleanTabs(many)
        XCTAssertEqual(clean.count, SyncRules.maxTabs)
        XCTAssertTrue(clean.allSatisfy { $0.url.hasPrefix("https://") })
    }

    func testASnapshotIsSealedAndOnlyOpensWithTheSamePassphrase() throws {
        var snapshot = BackupPayload(created: Date(), bookmarks: [bookmark("https://a.test")], settings: ["accent": "blue"])
        snapshot.tabs = [.init(url: "https://t.test", title: "T")]
        snapshot.device = "Test Mac"
        let sealed = try SyncRules.sealedFitting(snapshot, passphrase: "correct horse", iterations: 1_000)
        XCTAssertNil(sealed.range(of: Data("https://a.test".utf8)), "nothing readable is stored")
        let opened = try BackupFile.open(sealed, passphrase: "correct horse")
        XCTAssertEqual(opened.tabs, snapshot.tabs)
        XCTAssertEqual(opened.device, "Test Mac")
        XCTAssertThrowsError(try BackupFile.open(sealed, passphrase: "wrong"))
    }

    func testAnOversizedSnapshotIsTrimmedToFitICloud() throws {
        let big = (0..<3_000).map { bookmark("https://example.com/\($0)/" + String(repeating: "x", count: 300)) }
        var snapshot = BackupPayload(created: Date(), bookmarks: big, settings: [:])
        snapshot.tabs = (0..<100).map { .init(url: "https://t.test/\($0)/" + String(repeating: "y", count: 400), title: "tab") }
        let sealed = try SyncRules.sealedFitting(snapshot, passphrase: "pw-123456", iterations: 1_000)
        XCTAssertLessThanOrEqual(sealed.count, SyncRules.maxSealedBytes)
    }

    func testAnOldBackupWithoutTabsStillOpens() throws {
        let plain = BackupPayload(created: Date(), bookmarks: [], settings: [:])
        let sealed = try BackupFile.seal(plain, passphrase: "pw", iterations: 1_000)
        XCTAssertNil(try BackupFile.open(sealed, passphrase: "pw").tabs)
    }
}

@MainActor
final class SyncModelTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sync-\(UUID().uuidString)", profile: "default")
    }

    func testTwoDevicesEndUpWithTheSameBookmarksOverWiFi() async throws {
        let mac = model(), phone = model()
        await mac.start(); await phone.start()
        try mac.core.addBookmark(url: "https://from-mac.test", title: "Mac", folder: "")
        try phone.core.addBookmark(url: "https://from-phone.test", title: "Phone", folder: "")
        // The Mac sends first and the phone answers with its own, as the link does.
        let reply = try XCTUnwrap(phone.receiveWiFiSnapshot(try XCTUnwrap(mac.wifiSnapshot())))
        mac.finishWiFiSync(reply: reply, deviceName: "Phone")
        for m in [mac, phone] {
            XCTAssertTrue(try m.core.isBookmarked(url: "https://from-mac.test"))
            XCTAssertTrue(try m.core.isBookmarked(url: "https://from-phone.test"))
        }
    }

    func testSettingsOnlySyncWhenTheyAreTurnedOnAndNeverTouchTheLayout() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        try a.core.setSetting(key: "accent", value: "green")
        try a.core.setSetting(key: "layout_preset", value: "sidebar")
        b.syncSettingsToo = false
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(try b.core.getSetting(key: "accent"), "off means nothing is applied")
        b.syncSettingsToo = true
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(try b.core.getSetting(key: "accent"), "green")
        XCTAssertNotEqual(try b.core.getSetting(key: "layout_preset"), "sidebar", "layout stays on its own device")
    }

    func testOtherDevicesTabsAreListedNotOpened() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        a.openTab(url: URL(string: "https://reading.test/page"), isPrivate: false)
        a.openTab(url: URL(string: "https://secret.test/"), isPrivate: true)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        let listed = b.remoteTabs.flatMap(\.tabs).map(\.url)
        XCTAssertTrue(listed.contains("https://reading.test/page"))
        XCTAssertFalse(listed.contains("https://secret.test/"), "private tabs are never shared")
        XCTAssertFalse(b.tabs.contains { $0.url?.host == "reading.test" }, "they are only offered, never opened by themselves")
    }
}
