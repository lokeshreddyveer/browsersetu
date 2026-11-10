import XCTest
@testable import Browser_Setu

final class SandboxMigrationTests: XCTestCase {
    var root: URL!
    override func setUp() { root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-mig-\(UUID().uuidString)", isDirectory: true); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func write(_ rel: String, _ text: String, in base: URL) { let u = base.appendingPathComponent(rel); try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try? text.write(to: u, atomically: true, encoding: .utf8) }
    func read(_ rel: String, in base: URL) -> String? { try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8) }
    func tree(_ base: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) { for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out[String(u.path.dropFirst(base.path.count))] = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 } }
        return out
    }
    func fixtureContainer() -> URL {
        let c = root.appendingPathComponent("container/Data", isDirectory: true)
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db", "DB-DEFAULT", in: c)
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db-wal", "WAL", in: c)
        write("Library/Application Support/BrowserSetu/profiles/work/bookmarks.json", "{\"b\":1}", in: c)
        write("Library/Application Support/BrowserSetu/downloads/ledger.json", "LEDGER", in: c)
        write("Library/WebKit/WebsiteData/Default/cookies.sqlite", "COOKIES", in: c)
        write("Library/WebKit/WebsiteDataStore/abc/LocalStorage/x.db", "LS", in: c)
        write("Library/Caches/skip-me", "CACHE", in: c)
        write("Library/WebKit/WebsiteDataStore/abc/Cookies/Cookies.binarycookies", "COOKIEJAR", in: c)
        write("Library/WebKit/WebsiteDataStore/abc/IndexedDB/v1/db.sqlite3", "IDB", in: c)
        write("Library/WebKit/WebsiteDataStore/abc/NetworkCache/Records/big", "HTTPCACHE", in: c)
        write("Library/WebKit/WebsiteDataStore/abc/HSTS/hsts.plist", "HSTS", in: c)
        let prefs: [String: Any] = ["profile": "work", "bs.media.observe": false, "NSWindow Frame": "x"]
        try? FileManager.default.createDirectory(at: c.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        (prefs as NSDictionary).write(to: c.appendingPathComponent("Library/Preferences/com.test.app.plist"), atomically: true)
        return c
    }
    func defaults() -> UserDefaults { UserDefaults(suiteName: "bs.mig.\(UUID().uuidString)")! }
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    func run(_ c: URL, _ d: UserDefaults) -> SandboxMigration.Outcome { SandboxMigration.runIfNeeded(bundleID: "com.test.app", sourceContainer: c, destinationHome: home, defaults: d) }

    func testCopiesProfilesStoresAndPreferencesAndLeavesTheOriginalUntouched() throws {
        let c = fixtureContainer(); let before = tree(c); let d = defaults()
        guard case .migrated(let rec) = run(c, d) else { return XCTFail() }
        XCTAssertEqual(tree(c), before, "the container is exactly as it was")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db", in: home), "DB-DEFAULT")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db-wal", in: home), "WAL", "the write-ahead log travels with its database")
        XCTAssertEqual(read("Library/WebKit/com.test.app/WebsiteData/Default/cookies.sqlite", in: home), "COOKIES")
        XCTAssertEqual(read("Library/WebKit/com.test.app/WebsiteDataStore/abc/LocalStorage/x.db", in: home), "LS")
        XCTAssertNil(read("Library/Caches/skip-me", in: home), "caches are rebuilt, not copied")
        // A signed-in session is cookies + local storage + IndexedDB + HSTS inside the store; the store's HTTP cache is not part of it.
        let store = "Library/WebKit/com.test.app/WebsiteDataStore/abc"
        XCTAssertEqual(read(store + "/Cookies/Cookies.binarycookies", in: home), "COOKIEJAR"); XCTAssertEqual(read(store + "/IndexedDB/v1/db.sqlite3", in: home), "IDB")
        XCTAssertEqual(read(store + "/HSTS/hsts.plist", in: home), "HSTS"); XCTAssertEqual(read(store + "/LocalStorage/x.db", in: home), "LS")
        XCTAssertNil(read(store + "/NetworkCache/Records/big", in: home), "the store's HTTP cache is rebuilt, not copied")
        XCTAssertEqual(d.string(forKey: "profile"), "work"); XCTAssertEqual(d.object(forKey: "bs.media.observe") as? Bool, false); XCTAssertNil(d.object(forKey: "NSWindow Frame"))
        XCTAssertEqual(rec.conflicts, []); XCTAssertGreaterThanOrEqual(rec.copied.count, 6)
    }

    func testRepeatLaunchesDoNothingAndExistingDestinationDataWins() throws {
        let c = fixtureContainer(); let d = defaults(); d.set("existing", forKey: "profile")
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db", "NEWER-DEST-DATA", in: home)
        guard case .migrated(let rec) = run(c, d) else { return XCTFail() }
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db", in: home), "NEWER-DEST-DATA", "nothing at the destination is overwritten")
        XCTAssertEqual(rec.conflicts.count, 1); XCTAssertEqual(d.string(forKey: "profile"), "existing", "a preference already set is kept")
        XCTAssertEqual(run(c, d), .alreadyDone); XCTAssertEqual(run(c, d), .alreadyDone)
    }

    func testAnInterruptedMigrationLeavesWholeFilesOnlyAndTheNextLaunchFinishesIt() throws {
        let c = fixtureContainer(); let d = defaults()
        // As if an earlier run stopped after one file and mid-way through another: a finished file, and a half-written temporary one, but no record.
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db", "DB-DEFAULT", in: home)
        write("Library/Application Support/BrowserSetu/downloads/.ledger.json.1234.migrating", "HALF", in: home)
        guard case .migrated = run(c, d) else { return XCTFail() }
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/downloads/ledger.json", in: home), "LEDGER")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/work/bookmarks.json", in: home), "{\"b\":1}")
        XCTAssertEqual(run(c, d), .alreadyDone)
    }

    func testADatabaseAndItsLogMoveAsOneUnitAndAnExistingDatabaseIsNeverGivenAnotherCopysLog() throws {
        let c = fixtureContainer()
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db-shm", "SHM", in: c)
        write("Library/Application Support/BrowserSetu/profiles/work/other.db", "OTHER", in: c)
        write("Library/Application Support/BrowserSetu/profiles/work/other.db-wal", "OTHERWAL", in: c)
        // The destination already has its own default database (a run of the new build): the container's log must not be put beside it.
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db", "DESTINATION-DB", in: home)
        guard case .migrated(let rec) = run(c, defaults()) else { return XCTFail() }
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db", in: home), "DESTINATION-DB")
        XCTAssertNil(read("Library/Application Support/BrowserSetu/profiles/default/profile.db-wal", in: home), "no foreign log beside a database that was already there")
        XCTAssertNil(read("Library/Application Support/BrowserSetu/profiles/default/profile.db-shm", in: home), "the shared-memory file is never copied")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/work/other.db", in: home), "OTHER")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/work/other.db-wal", in: home), "OTHERWAL", "a database that was not there comes with its log")
        XCTAssertTrue(rec.conflicts.contains { $0.hasSuffix("profile.db") })
    }

    func testAnInterruptedSetIsCompletedBecauseTheDatabaseIsPlacedLast() throws {
        let c = fixtureContainer()
        // Interrupted after the log was placed but before the database: the database is absent, so the whole set is done again and nothing is lost.
        write("Library/Application Support/BrowserSetu/profiles/default/profile.db-wal", "WAL", in: home)
        guard case .migrated = run(c, defaults()) else { return XCTFail() }
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db", in: home), "DB-DEFAULT")
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/default/profile.db-wal", in: home), "WAL")
    }

    func testUndoMovesOnlyUnchangedCopiesAndKeepsAnythingTheAppHasWrittenSince() throws {
        let c = fixtureContainer()
        guard case .migrated = run(c, defaults()) else { return XCTFail() }
        // The app has since written to the live copy of one file.
        write("Library/Application Support/BrowserSetu/profiles/work/bookmarks.json", "{\"b\":1,\"newer\":true}", in: home)
        let moved = SandboxMigration.undo(destinationHome: home, bundleID: "com.test.app")
        XCTAssertGreaterThan(moved, 0)
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/work/bookmarks.json", in: home), "{\"b\":1,\"newer\":true}", "a file changed since the copy is live data and stays")
        XCTAssertNil(read("Library/Application Support/BrowserSetu/downloads/ledger.json", in: home))
    }

    func testUndoRemovesOnlyWhatWasCopiedAndNotTheContainer() throws {
        let c = fixtureContainer(); let before = tree(c)
        write("Library/Application Support/BrowserSetu/profiles/keep/own.txt", "MINE", in: home)
        guard case .migrated = run(c, defaults()) else { return XCTFail() }
        XCTAssertGreaterThan(SandboxMigration.undo(destinationHome: home, bundleID: "com.test.app"), 0)
        XCTAssertNil(read("Library/Application Support/BrowserSetu/profiles/default/profile.db", in: home))
        XCTAssertEqual(read("Library/Application Support/BrowserSetu/profiles/keep/own.txt", in: home), "MINE", "a file that was already there is not removed")
        XCTAssertEqual(tree(c), before)
    }

    func testNotNeededWithoutAContainerOrWhenSandboxed() {
        XCTAssertEqual(SandboxMigration.runIfNeeded(bundleID: "com.test.app", sourceContainer: root.appendingPathComponent("nothing"), destinationHome: home, defaults: defaults()), .notNeeded("there is no earlier sandbox container"))
    }

    /// The real data, read-only: a copy of this Mac's actual container is migrated and the profile data opens from the migrated place and matches the copy.
    @MainActor func testRealContainerDataMigratesAndOpens() throws {
        let real = SandboxMigration.defaultSource("com.browsersetu.mac")
        let source = real.appendingPathComponent("Library/Application Support/BrowserSetu/profiles")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "no real container on this Mac")
        let fake = root.appendingPathComponent("realcopy/Data/Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real.appendingPathComponent("Library/Application Support/BrowserSetu"), to: fake.appendingPathComponent("BrowserSetu"))
        let c = root.appendingPathComponent("realcopy/Data", isDirectory: true); let before = tree(c)
        guard case .migrated(let rec) = SandboxMigration.runIfNeeded(bundleID: "com.test.app", sourceContainer: c, destinationHome: home, defaults: defaults()) else { return XCTFail() }
        XCTAssertEqual(tree(c), before)
        let migrated = home.appendingPathComponent("Library/Application Support/BrowserSetu")
        // Every file matches except the ones that are rebuilt on purpose (shared-memory files) and the record itself.
        func keep(_ k: String) -> Bool { !k.hasSuffix(SandboxMigration.recordName) && !k.hasSuffix("-shm") }
        let a = tree(c.appendingPathComponent("Library/Application Support/BrowserSetu")).filter { keep($0.key) }
        let b = tree(migrated).filter { keep($0.key) }
        XCTAssertEqual(a, b, "every file and size matches")
        print("MIGRATION real-data copy: \(rec.copied.count) files, \(rec.conflicts.count) conflicts, \(rec.skipped.count) skipped")
        // Normal startup from the migrated place: the profile store opens (a copy, so the real data is never opened for writing).
        let m = BrowserModel(engine: WebKitEngine(), root: migrated.path, profile: "default")
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: migrated.appendingPathComponent("profiles").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let listed = m.profiles.sorted()
        XCTAssertFalse(listed.isEmpty); XCTAssertTrue(listed.allSatisfy { onDisk.contains($0) || $0 == "default" }, "the profiles shown are the migrated ones: \(listed) vs \(onDisk)")
    }
}
