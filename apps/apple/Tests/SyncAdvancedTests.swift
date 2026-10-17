import XCTest
@testable import Browser_Setu

final class SyncHistoryMergeTests: XCTestCase {
    private func cell(_ last: Double, at time: Double, device: String = "a", title: String = "T", live: Bool = true) -> SyncCell<SyncVisit> {
        SyncCell(stamp: SyncStamp(time: time, device: device), value: live ? SyncVisit(title: title, last: last) : nil)
    }

    func testTwoVisitsToTheSamePageKeepTheLaterOneInEitherOrder() {
        let a = ["u": cell(100, at: 10, device: "a", title: "Old")]
        let b = ["u": cell(200, at: 20, device: "b", title: "New")]
        let ab = SyncMerge.mergeHistory(a, b), ba = SyncMerge.mergeHistory(b, a)
        XCTAssertEqual(ab, ba, "the order devices meet in does not matter")
        XCTAssertEqual(ab["u"]?.value?.last, 200)
        XCTAssertEqual(ab["u"]?.value?.title, "New")
        XCTAssertEqual(SyncMerge.mergeHistory(ab, b), ab, "and merging again changes nothing")
    }

    func testADeletionBeatsAnOlderVisitAndALaterVisitBeatsTheDeletion() {
        let visit = ["u": cell(100, at: 10)]
        let deleted = ["u": cell(0, at: 20, live: false)]
        XCTAssertNil(SyncMerge.mergeHistory(visit, deleted)["u"]?.value, "deleted after the visit")
        let again = ["u": cell(300, at: 30)]
        XCTAssertEqual(SyncMerge.mergeHistory(deleted, again)["u"]?.value?.last, 300, "visited again after the deletion")
    }

    func testOnlyTheMomentOfTheLastVisitMakesTwoCopiesDifferent() {
        XCTAssertEqual(SyncVisit(title: "One", last: 5), SyncVisit(title: "Another title", last: 5))
        XCTAssertNotEqual(SyncVisit(title: "One", last: 5), SyncVisit(title: "One", last: 6))
    }

    func testASnapshotFromBeforeHistorySyncStillOpens() throws {
        let old = #"{"bookmarks":{},"settings":{},"workspaces":{},"logins":{},"sessions":{}}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(old.utf8))
        XCTAssertTrue(state.history.isEmpty)
        let none = try JSONDecoder().decode(SyncState.self, from: Data("{}".utf8))
        XCTAssertTrue(none.history.isEmpty && none.bookmarks.isEmpty)
    }

    func testAFullSnapshotShedsHistoryBeforeAnythingElse() throws {
        var payload = BackupPayload(created: Date(), bookmarks: [], settings: [:])
        var state = SyncState()
        for i in 0..<6_000 { state.history["https://h\(i).test/page/\(i)/with/a/longer/address"] = cell(Double(1_000_000 + i), at: Double(i), title: "A page title number \(i) that is fairly long") }
        for i in 0..<30 { state.bookmarks["https://b\(i).test/"] = SyncCell(stamp: SyncStamp(time: 1, device: "a"), value: SyncBookmark(title: "B\(i)", folder: "")) }
        payload.state = state
        let sealed = try SyncRules.sealedFitting(payload, passphrase: "a long enough phrase", iterations: 1_000)
        XCTAssertLessThanOrEqual(sealed.count, SyncRules.maxSealedBytes)
        let opened = try BackupFile.open(sealed, passphrase: "a long enough phrase")
        XCTAssertEqual(opened.state?.bookmarks.count, 30, "bookmarks are kept")
        let kept = opened.state?.history ?? [:]
        XCTAssertLessThan(kept.count, 6_000)
        XCTAssertNotNil(kept["https://h5999.test/page/5999/with/a/longer/address"], "the newest pages are the ones that stay")
    }
}

@MainActor
final class SyncAdvancedModelTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sa-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func visit(_ m: BrowserModel, _ url: String, ago: Int64, count: Int64 = 1) throws {
        let now = Int64(Date().timeIntervalSince1970)
        _ = try m.core.importHistory(visits: [ImportedVisit(url: url, title: "Title of " + url, lastVisit: now - ago, visitCount: count)])
    }

    private func has(_ m: BrowserModel, _ url: String) -> HistoryItem? { try? m.core.searchHistory(query: url, limit: 5).first { $0.url == url } }

    func testHistoryTravelsOnlyWhenBothSidesTurnedItOnAndNeverInflatesCounts() async throws {
        let a = await model(), b = await model()
        try visit(a, "https://h1.test/", ago: 100, count: 7)
        XCTAssertFalse(a.syncs(.history), "off until the person turns it on")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(has(b, "https://h1.test/"))
        a.setSync(.history, true)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(has(b, "https://h1.test/"), "the receiving side has it off")
        b.setSync(.history, true)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        let got = try XCTUnwrap(has(b, "https://h1.test/"))
        XCTAssertEqual(got.title, "Title of https://h1.test/")
        let count = got.visitCount
        for _ in 0..<3 { _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot())) }
        XCTAssertEqual(has(b, "https://h1.test/")?.visitCount, count, "syncing again does not add visits")
    }

    func testDeletingAPageAndVisitingItAgainBothTravel() async throws {
        let a = await model(), b = await model()
        for m in [a, b] { m.setSync(.history, true) }
        try visit(a, "https://gone.test/", ago: 500)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNotNil(has(b, "https://gone.test/"))
        try a.core.deleteHistoryEntry(url: "https://gone.test/")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(has(b, "https://gone.test/"), "the deletion reaches the other device")
        try visit(b, "https://gone.test/", ago: 0)
        _ = a.receiveWiFiSnapshot(try XCTUnwrap(b.wifiSnapshot()))
        XCTAssertNotNil(has(a, "https://gone.test/"), "a later visit brings it back")
    }

    func testSwitchingACategoryOffSendsNothingAndDeletesNothingElsewhere() async throws {
        let a = await model(), b = await model()
        try a.core.addBookmark(url: "https://keep.test/", title: "Keep", folder: "")
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertTrue(try b.core.isBookmarked(url: "https://keep.test/"))
        a.setSync(.bookmarks, false)
        let snapshot = try XCTUnwrap(a.makeSyncSnapshot() as BackupPayload?)
        XCTAssertTrue(snapshot.state?.bookmarks.isEmpty ?? false, "nothing is sent")
        _ = b.receiveWiFiSnapshot(try JSONEncoder().encode(snapshot))
        XCTAssertTrue(try b.core.isBookmarked(url: "https://keep.test/"), "and switching it off is not a deletion")
        try b.core.addBookmark(url: "https://new-on-b.test/", title: "B", folder: "")
        _ = a.receiveWiFiSnapshot(try XCTUnwrap(b.wifiSnapshot()))
        XCTAssertFalse(try a.core.isBookmarked(url: "https://new-on-b.test/"), "nothing is taken in either")
    }

    func testSiteRulesHaveTheirOwnSwitchApartFromSettings() async throws {
        let a = await model(), b = await model()
        try a.core.setSetting(key: "site_zoom", value: #"{"zoom.test":1.5}"#)
        try a.core.setSetting(key: "accent", value: "orange")
        a.setSync(.siteRules, true); a.syncSettingsToo = true
        b.syncSettingsToo = true                                  // settings on, site rules off
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(try b.core.getSetting(key: "accent"), "orange")
        XCTAssertNil(try b.core.getSetting(key: "site_zoom"), "site rules are not taken in while their switch is off")
        b.setSync(.siteRules, true)
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertEqual(try b.core.getSetting(key: "site_zoom"), #"{"zoom.test":1.5}"#)
        let c = await model()
        c.syncSettingsToo = true                                   // never turned site rules on
        _ = c.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(try c.core.getSetting(key: "site_zoom"))
    }

    func testSiteOpenRulesSyncAndAreActiveStraightAway() async throws {
        let a = await model(), b = await model()
        a.setSync(.siteRules, true); b.setSync(.siteRules, true)
        XCTAssertTrue(a.workbench.addSiteRule(host: "synced.test", action: .privateTab))
        _ = b.receiveWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertTrue(b.workbench.siteRules.contains { $0.host == "synced.test" }, "the rule is live on the other device without a restart")
    }

    func testATabSentToADeviceArrivesOnceOnlyThereAndOnlyAsAWebAddress() async throws {
        let mac = await model(), phone = await model(), other = await model()
        let tab = mac.openTab(url: URL(string: "https://article.test/read?utm_source=x"), isPrivate: false)
        let target = SyncDevice(id: phone.syncDeviceID, name: "Phone", status: .approved, lastSeen: Date())
        XCTAssertTrue(mac.sendTab(tab, to: target))
        _ = phone.receiveWiFiSnapshot(try XCTUnwrap(mac.wifiSnapshot()))
        XCTAssertEqual(phone.inbox.map(\.url), ["https://article.test/read"], "tracking is cleaned off on the way")
        XCTAssertEqual(phone.inbox.first?.fromName, mac.syncDeviceName)
        _ = phone.receiveWiFiSnapshot(try XCTUnwrap(mac.wifiSnapshot()))
        XCTAssertEqual(phone.inbox.count, 1, "the same tab is not delivered twice")
        _ = other.receiveWiFiSnapshot(try XCTUnwrap(mac.wifiSnapshot()))
        XCTAssertTrue(other.inbox.isEmpty, "a third device never sees it")
        phone.dismissSentTab(phone.inbox[0])
        _ = phone.receiveWiFiSnapshot(try XCTUnwrap(mac.wifiSnapshot()))
        XCTAssertTrue(phone.inbox.isEmpty, "and a dismissed one stays dismissed")
    }

    func testPrivateTabsAndUnsafeAddressesAreNeverSent() async throws {
        let mac = await model(), phone = await model()
        let target = SyncDevice(id: phone.syncDeviceID, name: "Phone", status: .approved, lastSeen: Date())
        let priv = mac.openTab(url: URL(string: "https://secret.test/"), isPrivate: true)
        XCTAssertFalse(mac.sendTab(priv, to: target))
        XCTAssertTrue(mac.outbox.isEmpty)
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://x.test/", "https:///nohost", "https://" + String(repeating: "a", count: 3000) + ".test"] {
            XCTAssertFalse(SentTab(id: "i", to: "d", fromName: "x", url: bad, title: "", sent: 0).isSafe, bad)
        }
        // A hand-made snapshot with a bad address or an old date is ignored by the receiver.
        var snapshot = try XCTUnwrap(mac.makeSyncSnapshot() as BackupPayload?)
        snapshot.outbox = [SentTab(id: "1", to: phone.syncDeviceID, fromName: "x", url: "javascript:alert(1)", title: "", sent: Date().timeIntervalSince1970),
                           SentTab(id: "2", to: phone.syncDeviceID, fromName: "x", url: "https://old.test/", title: "", sent: Date().timeIntervalSince1970 - 30 * 86_400)]
        _ = phone.receiveWiFiSnapshot(try JSONEncoder().encode(snapshot))
        XCTAssertTrue(phone.inbox.isEmpty)
    }

    func testTheSyncStatusSaysWhatIsWrong() async throws {
        let m = await model()
        XCTAssertEqual(m.syncHealth, .off)
        XCTAssertEqual(SyncHealth.off.title, "Sync is off")
        XCTAssertEqual(SyncHealth.waiting(2).title, "2 devices waiting for approval")
        XCTAssertEqual(SyncHealth.waiting(1).title, "1 device waiting for approval")
        m.recordSyncOutcome(push: true, error: "Too big")
        XCTAssertEqual(m.syncError, "Too big")
        m.recordSyncOutcome(push: true, error: nil)
        XCTAssertNil(m.syncError)
        XCTAssertNotNil(m.lastPush)
        XCTAssertNil(m.lastPull)
    }

    func testChoicesAreRememberedAndOlderSettingsOnKeepWorking() async throws {
        let root = NSTemporaryDirectory() + "bs-sc-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await m.start()
        XCTAssertEqual(m.syncCategorySet, SyncCategory.defaultOn)
        XCTAssertFalse(m.syncs(.history)); XCTAssertFalse(m.syncs(.passwords)); XCTAssertFalse(m.syncs(.siteRules))
        m.setSync(.history, true); m.setSync(.bookmarks, false)
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await again.start()
        XCTAssertTrue(again.syncs(.history)); XCTAssertFalse(again.syncs(.bookmarks))
        // Someone who already had "sync settings" on keeps getting per-site settings.
        let oldRoot = NSTemporaryDirectory() + "bs-so-\(UUID().uuidString)"
        let before = BrowserModel(engine: WebKitEngine(), root: oldRoot, profile: "default")
        await before.start()
        before.syncSettingsToo = true                              // as an older version would have left it
        let old = BrowserModel(engine: WebKitEngine(), root: oldRoot, profile: "default")
        await old.start()
        XCTAssertTrue(old.syncs(.settings))
        XCTAssertTrue(old.syncs(.siteRules))
    }
}
