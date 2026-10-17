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

    // MARK: Deterministic merging between real models

    func testADeletedBookmarkStaysDeletedOnTheOtherDevice() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        try a.core.addBookmark(url: "https://shared.test", title: "Shared", folder: "")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertTrue(try b.core.isBookmarked(url: "https://shared.test"))
        try a.core.removeBookmark(url: "https://shared.test")                    // removed on the first device
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertFalse(try b.core.isBookmarked(url: "https://shared.test"), "the deletion travels instead of the bookmark coming back")
        _ = a.receiveWiFiSnapshot(try XCTUnwrap(b.wifiSnapshot()))
        XCTAssertFalse(try a.core.isBookmarked(url: "https://shared.test"), "and it does not return when the other device syncs back")
    }

    func testAnEditOnOneDeviceReachesTheOtherAndAnOutOfDateCopyIsIgnored() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        try a.core.addBookmark(url: "https://page.test", title: "Old", folder: "")
        let first = try XCTUnwrap(a.wifiSnapshot())
        _ = b.receiveWiFiSnapshot(first)
        try a.core.removeBookmark(url: "https://page.test")
        try a.core.addBookmark(url: "https://page.test", title: "New", folder: "")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(try b.core.listBookmarks(query: "").first { $0.url == "https://page.test" }?.title, "New")
        _ = b.receiveWiFiSnapshot(first)                                         // the old copy is delivered late
        XCTAssertEqual(try b.core.listBookmarks(query: "").first { $0.url == "https://page.test" }?.title, "New", "a late, older copy cannot undo the edit")
    }

    func testWorkspacesSyncByNameButEachDeviceKeepsItsOwnLayout() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        a.createWorkspace("Research", icon: "book")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(b.workspaces.first { $0.name == "Research" }?.icon, "book")
        a.deleteWorkspace("Research")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(b.workspaces.first { $0.name == "Research" }, "deleting a workspace travels too")
    }

    func testSavedPasswordsTravelOnlyWhenTurnedOnAndOnlyInsideTheSnapshot() async throws {
        // Throwaway profile names: this test saves and then deletes passwords, and it must never be able to touch the real "default" profile's Keychain items.
        let a = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sync-\(UUID().uuidString)", profile: "sync-test-" + UUID().uuidString), b = model()
        await a.start(); await b.start()
        guard WebLoginVault.save(WebLogin(origin: "https://bank.test", user: "me", password: "s3cret"), profile: a.profileName) else { return XCTFail("the Keychain is not available to this test run") }
        defer { WebLoginVault.removeAll(profile: a.profileName) }
        let snapshotOff = try JSONDecoder().decode(BackupPayload.self, from: try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertTrue(snapshotOff.state?.logins.isEmpty ?? true, "off means no password is put into a snapshot")
        a.syncPasswords = true
        let on = try XCTUnwrap(a.makeSyncSnapshot())
        XCTAssertEqual(on.state?.logins.count, 1)
        // The receiving device is another profile, so the Keychain separates them.
        let receiver = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sync-\(UUID().uuidString)", profile: "sync-test-" + UUID().uuidString)
        await receiver.start()
        receiver.syncPasswords = false
        _ = receiver.applySyncSnapshot(on)
        XCTAssertEqual(receiver.syncLedger.logins.count, 0, "a device with password sync off takes none in")
    }
}

@MainActor
final class SessionSyncTests: XCTestCase {
    private func model() -> BrowserModel { BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ss-\(UUID().uuidString)", profile: "default") }

    func testASessionSavedOnOneDeviceAppearsOnTheOtherAndDeletionTravels() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        a.setSavedSessions([SavedSession(name: "Reading", tabs: [SavedSession.Tab(url: "https://a.test/x", title: "A", pinned: false, scroll: 0.4)], workspace: "")])
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(b.savedSessions.first?.name, "Reading")
        XCTAssertEqual(b.savedSessions.first?.tabs.first?.scroll, 0.4, "the place on the page travels with it")
        let session = try XCTUnwrap(a.savedSessions.first)
        a.deleteSession(session)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertTrue(b.savedSessions.isEmpty)
    }

    func testASessionWithUnsafeAddressesLosesThemOnTheWayIn() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        a.setSavedSessions([SavedSession(name: "Mixed", tabs: [SavedSession.Tab(url: "javascript:alert(1)", title: "x", pinned: false), SavedSession.Tab(url: "https://ok.test/", title: "ok", pinned: false)])])
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(b.savedSessions.first?.tabs.map(\.url), ["https://ok.test/"])
    }

    func testOpeningASessionReturnsEachPageToWhereItWasSaved() async throws {
        let m = model()
        await m.start()
        let session = SavedSession(name: "Place", tabs: [SavedSession.Tab(url: "http://127.0.0.1:18765/", title: "T", pinned: false, scroll: 0.5)])
        m.openSession(session)
        let tab = try XCTUnwrap(m.tabs.last)
        XCTAssertEqual(m.sessionScroll[tab.id], 0.5, "the place is remembered for the page until it has loaded")
    }

    func testSnapshotsWithoutSessionsStillOpen() throws {
        let json = #"{"bookmarks":{},"settings":{},"workspaces":{},"logins":{}}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        XCTAssertTrue(state.sessions.isEmpty)
    }
}
