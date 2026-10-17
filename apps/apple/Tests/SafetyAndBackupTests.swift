import XCTest
import WebKit
@testable import Browser_Setu

final class CrashGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testThirdCrashInTwoMinutesStopsReloadsForAMinute() {
        var guardian = CrashGuard()
        XCTAssertEqual(guardian.record(at: t0), .first)
        XCTAssertEqual(guardian.record(at: t0.addingTimeInterval(20)), .repeated(2))
        XCTAssertFalse(guardian.isPaused(at: t0.addingTimeInterval(21)))
        XCTAssertEqual(guardian.record(at: t0.addingTimeInterval(40)), .loop)
        XCTAssertTrue(guardian.isPaused(at: t0.addingTimeInterval(41)))
        XCTAssertEqual(guardian.secondsLeft(at: t0.addingTimeInterval(70)), 30)
        XCTAssertFalse(guardian.isPaused(at: t0.addingTimeInterval(101)), "the pause ends by itself")
    }

    func testOldCrashesDropOutAndNavigationResets() {
        var guardian = CrashGuard()
        _ = guardian.record(at: t0)
        _ = guardian.record(at: t0.addingTimeInterval(10))
        XCTAssertEqual(guardian.record(at: t0.addingTimeInterval(500)), .first, "crashes older than two minutes no longer count")
        _ = guardian.record(at: t0.addingTimeInterval(510)); _ = guardian.record(at: t0.addingTimeInterval(520))
        XCTAssertTrue(guardian.isPaused(at: t0.addingTimeInterval(521)))
        guardian.reset()
        XCTAssertFalse(guardian.isPaused(at: t0.addingTimeInterval(521)))
        XCTAssertEqual(guardian.record(at: t0.addingTimeInterval(530)), .first)
    }
}

final class LaunchGuardTests: XCTestCase {
    func testTwoUnfinishedLaunchesInARowIsALoopAndAHealthyMarkClearsIt() {
        let root = NSTemporaryDirectory() + "bs-launch-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(LaunchGuard.begin(root: root), 0, "a first launch is normal")
        XCTAssertEqual(LaunchGuard.begin(root: root), 1, "the last launch never finished")
        XCTAssertFalse(LaunchGuard.isLoop(unfinishedLaunches: 1))
        XCTAssertEqual(LaunchGuard.begin(root: root), 2)
        XCTAssertTrue(LaunchGuard.isLoop(unfinishedLaunches: 2))
        LaunchGuard.markHealthy(root: root)
        XCTAssertEqual(LaunchGuard.begin(root: root), 0, "after a healthy run the count starts again")
    }
}

final class BackupFileTests: XCTestCase {
    private let payload = BackupPayload(
        created: Date(timeIntervalSince1970: 1_700_000_000),
        bookmarks: [.init(url: "https://example.com/a", title: "A", folder: ""), .init(url: "https://example.org/", title: "Ünï", folder: "Work")],
        settings: ["appearance": "dark", "memory_mode": "saver"])

    func testRoundTripAndWrongPassphrase() throws {
        let sealed = try BackupFile.seal(payload, passphrase: "correct horse", iterations: 1_000)
        XCTAssertEqual(try BackupFile.open(sealed, passphrase: "correct horse"), payload)
        XCTAssertThrowsError(try BackupFile.open(sealed, passphrase: "wrong")) {
            XCTAssertEqual($0 as? BackupError, .wrongPassphraseOrDamaged)
        }
        let plain = String(decoding: sealed, as: UTF8.self)
        XCTAssertFalse(plain.contains("example.com"), "the contents are not readable in the file")
    }

    func testAnyChangedByteIsRejected() throws {
        let sealed = try BackupFile.seal(payload, passphrase: "pw", iterations: 1_000)
        for index in [0, 4, 6, 12, 30, sealed.count / 2, sealed.count - 1] {
            var copy = sealed
            copy[index] ^= 0x01
            XCTAssertThrowsError(try BackupFile.open(copy, passphrase: "pw"), "byte \(index) was changed")
        }
    }

    func testRejectsEmptyPassphraseAndForeignFiles() {
        XCTAssertThrowsError(try BackupFile.seal(payload, passphrase: "")) { XCTAssertEqual($0 as? BackupError, .emptyPassphrase) }
        XCTAssertThrowsError(try BackupFile.open(Data("hello".utf8), passphrase: "x")) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertThrowsError(try BackupFile.open(Data(repeating: 0x41, count: 200), passphrase: "x")) { XCTAssertEqual($0 as? BackupError, .notABackup) }
    }

    func testTwoBackupsOfTheSameDataDiffer() throws {
        let a = try BackupFile.seal(payload, passphrase: "pw", iterations: 1_000)
        let b = try BackupFile.seal(payload, passphrase: "pw", iterations: 1_000)
        XCTAssertNotEqual(a, b, "a fresh salt and nonce every time")
    }
}

@MainActor
final class SafetyIntegrationTests: XCTestCase {
    private func model(_ root: String? = nil) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-sf-\(UUID().uuidString)", profile: "default")
    }

    func testBackupRestoresBookmarksAndSettingsAndIgnoresUnknownKeys() async throws {
        let a = model()
        await a.start()
        try a.core.addBookmark(url: "https://example.com/keep", title: "Keep", folder: "")
        a.memoryMode = .saver
        a.density = .compact
        let data = try a.makeBackup(passphrase: "pw", iterations: 1_000)

        let b = model()
        await b.start()
        let result = try b.restoreBackup(data, passphrase: "pw")
        XCTAssertEqual(result.bookmarks, 1)
        XCTAssertEqual(b.memoryMode, .saver)
        XCTAssertEqual(b.density, .compact)
        XCTAssertTrue(try b.core.isBookmarked(url: "https://example.com/keep"))

        // A file that carries a setting the app never exports must not write it.
        let hostile = try BackupFile.seal(BackupPayload(created: Date(), bookmarks: [.init(url: "javascript:alert(1)", title: "x", folder: "")],
                                                        settings: ["evil_key": "1", "memory_mode": "balanced"]), passphrase: "pw", iterations: 1_000)
        let c = try b.restoreBackup(hostile, passphrase: "pw")
        XCTAssertEqual(c.bookmarks, 0, "a bookmark without a real address is skipped")
        XCTAssertNil(try b.core.getSetting(key: "evil_key"))
        XCTAssertEqual(b.memoryMode, .balanced)
        XCTAssertThrowsError(try b.restoreBackup(data, passphrase: "nope"))
    }

    func testSafeStartRestoresTabsWithoutLoadingAnyOfThem() async throws {
        let root = NSTemporaryDirectory() + "bs-safe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let a = model(root)
        await a.start()
        a.openTab(url: URL(string: "https://one.example/"), isPrivate: false)
        a.openTab(url: URL(string: "https://two.example/"), isPrivate: false)
        a.saveNow()

        let b = model(root)
        b.safeStart = true
        await b.start()
        XCTAssertGreaterThanOrEqual(b.tabs.count, 3, "the restored tabs plus a fresh one")
        XCTAssertTrue(b.active?.isBlank ?? false, "the user lands on a blank tab")
        XCTAssertTrue(b.tabs.filter { $0.url?.host?.hasSuffix(".example") == true }.allSatisfy { !$0.hasLoadedPage }, "none of the restored pages was loaded")
        XCTAssertNotNil(b.notice)
    }

    func testAPageCanBeArchivedForLater() async throws {
        let m = model()
        await m.start()
        let tab = try XCTUnwrap(m.active)
        tab.engine.showErrorPage(title: "Archive me", detail: "Some saved text", baseURL: URL(string: "http://127.0.0.1:1/"))
        for _ in 0..<60 where tab.engine.currentURL == nil { try? await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let data = await tab.engine.webArchive()
        XCTAssertGreaterThan(data?.count ?? 0, 100)
    }
}
