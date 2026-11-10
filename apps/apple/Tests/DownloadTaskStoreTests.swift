import XCTest
import SQLite3
@testable import Browser_Setu

/// The task database: round trips, damage, versions, bounds, and what is (and is not) written.
final class DownloadTaskStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-store-\(UUID().uuidString)")
    }
    override func tearDown() {
        DownloadTaskStore.close(folder: folder)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func record(_ name: String = "a.zip", state: DownloadState = .queued, profile: String = "default") -> DownloadTaskRecord {
        var r = DownloadTaskRecord(protocolID: .webKit, profile: profile, source: DownloadSourceRef(url: URL(string: "https://files.test/\(name)?x=1")), filename: name)
        r.state = state
        return r
    }

    func testARecordSurvivesBeingWrittenAndReadBack() {
        let store = DownloadTaskStore.open(folder: folder)
        var r = record()
        r.priority = .high; r.queueOrder = 7; r.attempt = 2; r.retryCount = 1
        r.transfer = DownloadTransfer(totalBytes: 1_000, completedBytes: 400, resumeAvailable: true)
        r.file.destinationPath = "/tmp/x/a.zip"; r.file.integrity = .verified
        r.failure = DownloadFailureInfo(code: "x:1", reason: "No.", retryable: true)
        r.engineMetadata = ["segments": "6"]
        store.save(r, resumeData: .some(Data("resume".utf8)))
        store.flush()
        let read = store.loadAll(profile: "default").records
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, r.id)
        XCTAssertEqual(read[0].priority, .high); XCTAssertEqual(read[0].queueOrder, 7); XCTAssertEqual(read[0].attempt, 2)
        XCTAssertEqual(read[0].transfer, r.transfer); XCTAssertEqual(read[0].failure, r.failure)
        XCTAssertEqual(read[0].file.destinationPath, "/tmp/x/a.zip"); XCTAssertEqual(read[0].engineMetadata, ["segments": "6"])
        XCTAssertEqual(read[0].source.url, "https://files.test/a.zip?x=1")
        XCTAssertEqual(store.resumeData(for: r.id), Data("resume".utf8))
    }

    func testASignedAddressIsWrittenWithoutItsSecretsAndStillReadsAsSigned() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let secret = "https://bucket.s3.amazonaws.com/model.bin?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=deadbeef1234&X-Amz-Expires=300&X-Amz-Date=20261109T101500Z"
        var r = record(); r.source = DownloadSourceRef(url: URL(string: secret))
        store.save(r, resumeData: nil); store.flush()
        let read = try XCTUnwrap(store.loadAll(profile: "default").records.first)
        XCTAssertFalse(read.source.url?.contains("deadbeef1234") ?? true, "the signature never reaches the file")
        XCTAssertTrue(read.source.url?.hasPrefix("https://bucket.s3.amazonaws.com/model.bin?") ?? false)
        XCTAssertTrue(DownloadURLRedactor.looksSigned(read.source.asURL), "after a relaunch it is still known to be a signed link, so recovery asks for a fresh one")
        let raw = try Data(contentsOf: folder.appendingPathComponent("downloads.sqlite"))
        XCTAssertNil(raw.range(of: Data("deadbeef1234".utf8)), "not in the database bytes")
        // An ordinary address is stored exactly as before.
        XCTAssertEqual(DownloadURLRedactor.persistable("https://files.test/a.zip?x=1"), "https://files.test/a.zip?x=1")
    }

    func testASignedAddressKeptAcrossARelaunchIsNeverStartedRetriedOrResumedFromTheStump() throws {
        let kept = try XCTUnwrap(DownloadURLRedactor.persistable("https://bucket.s3.amazonaws.com/m.bin?id=42&X-Amz-Signature=abc&X-Amz-Expires=300"))
        XCTAssertTrue(kept.contains("id=42"), "what identifies the file is kept")
        XCTAssertFalse(kept.contains("abc"))
        let url = try XCTUnwrap(URL(string: kept))
        XCTAssertTrue(DownloadURLRedactor.lostSecret(url))
        XCTAssertFalse(DownloadSchedule.canSchedule(url), "not scheduled, not offered Try Again")
        XCTAssertFalse(DownloadURLRedactor.lostSecret(URL(string: "https://files.test/get?id=42&key=abc")), "a live address is not a stump")
        var r = record(); r.source = DownloadSourceRef(url: url); r.state = .recoveryRequired; r.engineMetadata["mode"] = "multipart"
        r.transfer = DownloadTransfer(totalBytes: 100, completedBytes: 50, resumeAvailable: false)
        var facts = DownloadRecoveryFacts(); facts.donePieces = 3; facts.workingSize = 100; facts.hasSource = false; facts.sourceSecretLost = true; facts.sourceLooksSigned = true
        guard case .recover(.needsNewLink) = DownloadRecovery.assess(r, facts: facts) else { return XCTFail("a half-done multipart download of a signed link asks for a fresh link") }
    }

    func testSavingTheSameTaskAgainUpdatesItAndDoesNotDuplicateIt() {
        let store = DownloadTaskStore.open(folder: folder)
        var r = record()
        store.save(r)
        r.state = .running; r.transfer.completedBytes = 10
        store.save(r)
        store.flush()
        XCTAssertEqual(store.counts().tasks, 1)
        XCTAssertEqual(store.loadAll(profile: "default").records[0].state, .running)
    }

    func testAnotherProfilesTasksAreNeverReturned() {
        let store = DownloadTaskStore.open(folder: folder)
        store.save(record("mine.zip", profile: "default")); store.save(record("theirs.zip", profile: "work"))
        store.flush()
        XCTAssertEqual(store.loadAll(profile: "default").records.map(\.file.filename), ["mine.zip"])
        XCTAssertEqual(store.loadAll(profile: "work").records.map(\.file.filename), ["theirs.zip"])
    }

    func testResumeDataLivesApartFromTheRecordAndGoesWithIt() throws {
        let store = DownloadTaskStore.open(folder: folder)
        let r = record(state: .paused)
        store.save(r, resumeData: .some(Data("headers: Cookie: secret".utf8)))
        store.flush()
        XCTAssertEqual(store.counts().resume, 1)
        // The task table itself never contains it.
        DownloadTaskStore.close(folder: folder)
        let raw = try Data(contentsOf: folder.appendingPathComponent("downloads.sqlite"))
        XCTAssertNotNil(raw.range(of: Data("secret".utf8)), "it is in the database, in its own table")
        let store2 = DownloadTaskStore.open(folder: folder)
        XCTAssertEqual(store2.loadAll(profile: "default").records[0].file.filename, "a.zip")
        store2.delete(r.id); store2.flush()
        XCTAssertEqual(store2.counts().resume, 0, "removing the task removes its resume data")
    }

    func testAnOversizedResumeBlobIsNotKept() {
        let store = DownloadTaskStore.open(folder: folder)
        let r = record(state: .paused)
        store.save(r, resumeData: .some(Data(count: DownloadTaskStore.maxResumeBytes + 1)))
        store.flush()
        XCTAssertNil(store.resumeData(for: r.id))
    }

    func testGrowthIsBounded() {
        let store = DownloadTaskStore.open(folder: folder)
        for i in 0..<(DownloadTaskStore.keepCompleted + 30) {
            var r = record("f\(i).zip", state: .completed)
            r.updatedAt = Date(timeIntervalSince1970: Double(1_000 + i))
            store.save(r)
        }
        store.flush()
        let kept = store.loadAll(profile: "default").records
        XCTAssertEqual(kept.count, DownloadTaskStore.keepCompleted)
        XCTAssertTrue(kept.contains { $0.file.filename == "f\(DownloadTaskStore.keepCompleted + 29).zip" }, "the newest are the ones kept")
        XCTAssertFalse(kept.contains { $0.file.filename == "f0.zip" })
    }

    func testADamagedDatabaseIsMovedAsideNotDeletedAndNotSilentlyEmptied() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("downloads.sqlite")
        try Data("this is not a database, it is only some text that is long enough to look like one".utf8).write(to: file)
        let store = DownloadTaskStore.open(folder: folder)
        guard case .quarantined(let moved, _) = store.outcome else { return XCTFail("expected quarantine, got \(store.outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved), "the damaged file is kept")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: moved)).prefix(7), Data("this is".utf8))
        store.save(record()); store.flush()
        XCTAssertEqual(store.counts().tasks, 1, "and a new database works")
    }

    func testADatabaseFromANewerVersionIsLeftAlone() throws {
        // Make a database that says it is from the future.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("downloads.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE future (x); PRAGMA user_version = 99;", nil, nil, nil)
        sqlite3_close(handle)
        let before = try Data(contentsOf: file)
        let store = DownloadTaskStore.open(folder: folder)
        XCTAssertEqual(store.outcome, .newerVersion(99))
        store.save(record()); store.flush()
        XCTAssertEqual(store.loadAll(profile: "default").records.count, 0)
        DownloadTaskStore.close(folder: folder)
        XCTAssertEqual(try Data(contentsOf: file), before, "not a byte of it changed")
    }

    func testTheSchemaIsVersionedAndReopeningKeepsTheData() {
        let store = DownloadTaskStore.open(folder: folder)
        store.save(record()); store.flush()
        DownloadTaskStore.close(folder: folder)
        let again = DownloadTaskStore.open(folder: folder)
        XCTAssertEqual(again.outcome, .opened)
        XCTAssertEqual(again.loadAll(profile: "default").records.count, 1)
    }

    func testAnInterruptedWriteLeavesNothingHalfDone() throws {
        // A failed statement inside a transaction rolls the whole thing back.
        let store = DownloadTaskStore.open(folder: folder)
        let good = record("good.zip")
        store.save(good); store.flush()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.transaction { s in
            try s.saveInTransaction(self.record("half.zip"), resumeData: nil)
            throw Boom()
        })
        XCTAssertEqual(store.loadAll(profile: "default").records.map(\.file.filename), ["good.zip"])
    }

    func testRowsThatDoNotMakeSenseAreSkippedAndCounted() throws {
        let store = DownloadTaskStore.open(folder: folder)
        store.save(record("ok.zip")); store.flush()
        DownloadTaskStore.close(folder: folder)
        // A row with an engine id that is not valid.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("downloads.sqlite").path, &handle), SQLITE_OK)
        let id = UUID().uuidString
        sqlite3_exec(handle, "INSERT INTO tasks (id, protocol, profile, state, priority, queue_order, created_at, updated_at, filename) VALUES ('\(id)', 'BAD ID!', 'default', 'queued', 1, 0, 1, 1, 'x.zip')", nil, nil, nil)
        sqlite3_close(handle)
        let reopened = DownloadTaskStore.open(folder: folder).loadAll(profile: "default")
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.unreadable, 1, "counted, so it can be reported")
    }

    func testOnlyAKnownStateCanBeStored() {
        var handle: OpaquePointer?
        _ = DownloadTaskStore.open(folder: folder)
        DownloadTaskStore.close(folder: folder)
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("downloads.sqlite").path, &handle), SQLITE_OK)
        let rc = sqlite3_exec(handle, "INSERT INTO tasks (id, protocol, profile, state, priority, queue_order, created_at, updated_at, filename) VALUES ('\(UUID().uuidString)', 'webkit', 'default', 'exploding', 1, 0, 1, 1, 'x')", nil, nil, nil)
        sqlite3_close(handle)
        XCTAssertNotEqual(rc, SQLITE_OK, "the database itself refuses a state the app does not have")
    }
}

/// The old JSON files come into the database once, without being deleted.
final class DownloadLegacyMigrationTests: XCTestCase {
    private var folder: URL!
    override func setUp() { super.setUp(); folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-mig-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    override func tearDown() { DownloadTaskStore.close(folder: folder); try? FileManager.default.removeItem(at: folder); super.tearDown() }

    private func writeLegacy(id: UUID = UUID(), name: String = "big.zip", resume: String = "resume-bytes") throws -> UUID {
        try Data(resume.utf8).write(to: folder.appendingPathComponent(id.uuidString + ".resume"))
        try Data("[{\"id\":\"\(id.uuidString)\",\"filename\":\"\(name)\",\"source\":\"https://a.test/big.zip\"}]".utf8).write(to: folder.appendingPathComponent("interrupted.json"))
        return id
    }

    func testInterruptedAndScheduledDownloadsComeAcrossWithTheirResumeData() throws {
        let id = try writeLegacy()
        let scheduled = ScheduledDownload(url: "https://a.test/later.zip", filename: "later.zip", priority: .high)
        try JSONEncoder().encode([scheduled]).write(to: folder.appendingPathComponent("scheduled.json"))
        let store = DownloadTaskStore.open(folder: folder)
        let result = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertEqual(result.imported, 2); XCTAssertNil(result.failure)
        let records = store.loadAll(profile: "default").records
        XCTAssertEqual(records.first { $0.id == id }?.state, .paused)
        XCTAssertEqual(store.resumeData(for: id), Data("resume-bytes".utf8))
        XCTAssertEqual(records.first { $0.id == scheduled.id }?.state, .scheduled)
        XCTAssertEqual(records.first { $0.id == scheduled.id }?.priority, .high)
    }

    func testTheOldFilesAreKeptAsABackupAndNotDeleted() throws {
        let id = try writeLegacy()
        let store = DownloadTaskStore.open(folder: folder)
        _ = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        let backup = folder.appendingPathComponent(DownloadLegacyMigration.backupFolderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("interrupted.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(id.uuidString + ".resume").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("interrupted.json").path), "moved, so it is not read twice")
    }

    func testRunningItTwiceChangesNothing() throws {
        _ = try writeLegacy()
        let store = DownloadTaskStore.open(folder: folder)
        let first = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        let second = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertEqual(first.imported, 1)
        XCTAssertTrue(second.alreadyDone); XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(store.counts().tasks, 1)
    }

    func testAnUnreadableIndexLeavesTheOldFilesInPlaceAndTriesAgainNextTime() throws {
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("interrupted.json"))
        let store = DownloadTaskStore.open(folder: folder)
        let result = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("interrupted.json").path), "left where it was")
        XCTAssertNil(store.meta(DownloadLegacyMigration.markerKey), "so the next launch tries again")
    }

    func testAHostileOldFileIsReducedToAPlainName() throws {
        let id = try writeLegacy(name: "../../etc/passwd")
        let store = DownloadTaskStore.open(folder: folder)
        _ = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertEqual(store.loadAll(profile: "default").records.first { $0.id == id }?.file.filename, "passwd")
    }

    func testAnEntryWithNoResumeDataIsSkippedAndCounted() throws {
        let id = UUID()
        try Data("[{\"id\":\"\(id.uuidString)\",\"filename\":\"x.zip\",\"source\":null}]".utf8).write(to: folder.appendingPathComponent("interrupted.json"))
        let store = DownloadTaskStore.open(folder: folder)
        let result = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertEqual(result.imported, 0); XCTAssertEqual(result.skipped, 1)
    }

    func testNothingToMigrateIsRecordedAsDone() {
        let store = DownloadTaskStore.open(folder: folder)
        _ = DownloadLegacyMigration.run(folder: folder, store: store, profile: "default", safeName: DownloadCoordinator.safeName)
        XCTAssertNotNil(store.meta(DownloadLegacyMigration.markerKey))
    }
}
