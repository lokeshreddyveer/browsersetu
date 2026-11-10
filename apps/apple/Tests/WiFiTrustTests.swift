import XCTest
@testable import Browser_Setu

/// Who may change a device's data over Wi-Fi: the code alone is not enough.
@MainActor
final class WiFiTrustTests: XCTestCase {
    private func model() -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-trust-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()            // never the real Keychain
        return m
    }

    override func tearDown() { Dialogs.testHandler = nil; super.tearDown() }

    private func answers(_ buttons: [Int]) -> () -> [String] {
        var asked: [String] = [], queue = buttons
        Dialogs.testHandler = { title, message, _ in asked.append(title + "\n" + message); return queue.isEmpty ? 2 : queue.removeFirst() }
        return { asked }
    }

    func testAFirstDeviceIsAskedAboutAndNothingChangesUntilTheAnswerIsYes() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        try a.core.addBookmark(url: "https://from-a.test", title: "A", folder: "")
        let asked = answers([2])                                               // Not Now
        let reply = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNil(reply, "no answer is given to a device that was not approved")
        XCTAssertFalse(try b.core.isBookmarked(url: "https://from-a.test"), "and nothing was taken in")
        XCTAssertEqual(asked().count, 1)
        XCTAssertTrue(asked()[0].contains("Bookmarks"), "the question says what would be exchanged")
        XCTAssertFalse(asked()[0].contains("Saved passwords,"), "passwords are not listed when they are off")
    }

    func testApprovingTakesItInAndAnApprovedDeviceSyncsAgainWithoutAsking() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        try a.core.addBookmark(url: "https://one.test", title: "1", folder: "")
        let asked = answers([0])                                               // Approve and Sync
        let first = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNotNil(first)
        XCTAssertTrue(try b.core.isBookmarked(url: "https://one.test"))
        XCTAssertEqual(b.syncDevices.first?.status, .approved)
        try a.core.addBookmark(url: "https://two.test", title: "2", folder: "")
        let second = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNotNil(second)
        XCTAssertTrue(try b.core.isBookmarked(url: "https://two.test"))
        XCTAssertEqual(asked().count, 1, "the second time it did not ask")
    }

    func testSomeoneWithTheCodeCannotPoseAsAnApprovedDevice() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        _ = answers([0])
        _ = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))          // a is approved, its key is remembered
        // An attacker who has the code builds a snapshot that claims to be a, but cannot make a's proof.
        var forged = try JSONDecoder().decode(BackupPayload.self, from: try XCTUnwrap(a.signedWiFiSnapshot()))
        forged.bookmarks = []
        let evilKey = MemoryWiFiKeys().ownSecret()
        WiFiTrust.sign(&forged, secret: evilKey)
        let asked = answers([0])
        let reply = await b.acceptWiFiSnapshot(try JSONEncoder().encode(forged))
        XCTAssertNil(reply)
        XCTAssertTrue(b.syncStatus.contains("could not prove"), b.syncStatus)
        XCTAssertEqual(asked().count, 0, "it was refused without even asking")
    }

    func testABlockedDeviceIsRefusedAndCannotComeBackWithoutBeingApprovedAgain() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        _ = answers([1])                                                       // Block This Device
        let r1 = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNil(r1)
        XCTAssertEqual(b.syncDevices.first?.status, .blocked)
        let asked = answers([0])
        let r2 = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNil(r2)
        XCTAssertEqual(asked().count, 0)
        XCTAssertTrue(b.syncStatus.contains("blocked"))
    }

    func testRevokingADeviceRemovesItsKeySoItMustBeApprovedAgain() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        _ = answers([0])
        _ = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        let id = try XCTUnwrap(b.syncDevices.first?.id)
        XCTAssertNotNil(b.wifiKeys.pinnedSecret(for: id))
        b.forgetSyncDevice(id)
        XCTAssertNil(b.wifiKeys.pinnedSecret(for: id))
        let asked = answers([2])
        let r3 = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        XCTAssertNil(r3)
        XCTAssertEqual(asked().count, 1, "it asks again")
    }

    func testOldCopiesAndUnsignedSnapshotsAreRefused() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        let asked = answers([0])
        let r4 = await b.acceptWiFiSnapshot(try XCTUnwrap(a.wifiSnapshot()))
        XCTAssertNil(r4, "no proof of who sent it")
        XCTAssertTrue(b.syncStatus.contains("did not say who it is"))
        let legacy = try JSONEncoder().encode(BackupPayload(created: Date(), bookmarks: [.init(url: "https://old.test", title: "o", folder: "")], settings: [:]))
        let r5 = await b.acceptWiFiSnapshot(legacy)
        XCTAssertNil(r5, "an old-format copy cannot even add bookmarks")
        XCTAssertFalse(try b.core.isBookmarked(url: "https://old.test"))
        XCTAssertEqual(asked().count, 0)
        let r6 = await b.acceptWiFiSnapshot(Data("not json".utf8))
        XCTAssertNil(r6)
    }

    func testAReplayedCopyAndACopyForAnotherDeviceAreNotTakenInTwice() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        _ = answers([0])
        let first = try XCTUnwrap(a.signedWiFiSnapshot())
        _ = await b.acceptWiFiSnapshot(first)
        try a.core.addBookmark(url: "https://later.test", title: "L", folder: "")
        _ = await b.acceptWiFiSnapshot(try XCTUnwrap(a.signedWiFiSnapshot()))
        try b.core.removeBookmark(url: "https://later.test")
        _ = await b.acceptWiFiSnapshot(first)                                 // the old copy is delivered again
        XCTAssertFalse(try b.core.isBookmarked(url: "https://later.test"), "an older copy changes nothing")
    }

    func testPasswordsAreOnlyTakenInWhenTheReceiverHasThemOnEvenForAnApprovedDevice() async throws {
        let a = model(), b = model()
        await a.start(); await b.start()
        a.syncPasswords = true; b.syncPasswords = false
        let asked = answers([0])
        let snapshot = try JSONDecoder().decode(BackupPayload.self, from: try XCTUnwrap(a.signedWiFiSnapshot()))
        _ = await b.acceptWiFiSnapshot(try JSONEncoder().encode(snapshot))
        XCTAssertFalse(asked()[0].contains("Saved passwords,") || asked()[0].hasSuffix("Saved passwords"), "the question does not promise passwords")
        XCTAssertTrue(b.syncLedger.logins.isEmpty, "no password was taken in")
    }

    func testTheTagCoversTheFieldsItIsMeantToProtect() {
        let key = MemoryWiFiKeys().ownSecret()
        let t = Date()
        let tag = WiFiTrust.tag(secret: key, deviceID: "dev", seq: 5, created: t, group: "g")
        XCTAssertEqual(tag, WiFiTrust.tag(secret: key, deviceID: "dev", seq: 5, created: t, group: "g"))
        for other in [WiFiTrust.tag(secret: key, deviceID: "dev2", seq: 5, created: t, group: "g"),
                      WiFiTrust.tag(secret: key, deviceID: "dev", seq: 6, created: t, group: "g"),
                      WiFiTrust.tag(secret: key, deviceID: "dev", seq: 5, created: t.addingTimeInterval(1), group: "g"),
                      WiFiTrust.tag(secret: key, deviceID: "dev", seq: 5, created: t, group: "h")] {
            XCTAssertNotEqual(tag, other)
        }
    }

    func testOnlyTheGateCallsTheMergeAndTheLinkNeverSendsAnUnsignedCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }
        for file in files where file != "SyncModel.swift" {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("mergeWiFiSnapshot(") || text.contains("mergeWiFiReply("), "\(file) must go through the trust gate")
        }
        let link = try String(contentsOf: root.appendingPathComponent("LocalLink.swift"), encoding: .utf8)
        XCTAssertFalse(link.contains("wifiSnapshot()"), "the link sends only the signed copy")
        XCTAssertTrue(link.contains("acceptWiFiSnapshot") && link.contains("acceptWiFiReply") && link.contains("signedWiFiSnapshot"))
    }
}
