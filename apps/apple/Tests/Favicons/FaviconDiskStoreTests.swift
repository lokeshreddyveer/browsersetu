import XCTest
@testable import Browser_Setu

final class FaviconDiskStoreTests: XCTestCase {
    private var folder: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() { folder = FaviconFixtures.temporaryFolder("diskstore") }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func record(_ host: String, _ id: IconResourceID, used: TimeInterval = 0, dark: IconResourceID? = nil) -> IconRecord {
        IconRecord(key: host, resource: id.hex, darkResource: dark?.hex, sourceHost: host, sourceDigest: "d", kind: .icon, fetchedAt: t0, validatedAt: t0,
                   expiresAt: t0.addingTimeInterval(86_400), etag: "\"e\"", lastModified: nil, lastUsed: t0.addingTimeInterval(used))
    }
    private func png(_ n: UInt8) -> Data { FaviconFixtures.png(width: 64, height: 64, red: n) }
    private var corruptFiles: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("index.corrupt-") }.sorted() }
    private var blobCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("blobs").path).count) ?? 0 }

    func testWhatIsStoredSurvivesARestart() throws {
        let store = FaviconDiskStore(directory: folder)
        let data = png(1)
        let id = store.put(png: data, width: 64, height: 64, now: t0)
        store.setRecord(record("a.example", id))
        store.flush()
        let again = FaviconDiskStore(directory: folder)
        XCTAssertEqual(again.record(IconKey(host: "a.example")!)?.etag, "\"e\"")
        XCTAssertEqual(again.resourceData(id.hex), data, "the stored bytes are the bytes that went in")
        XCTAssertFalse(again.quarantined)
    }

    func testTwoSitesWithTheSameIconShareOneFile() {
        let store = FaviconDiskStore(directory: folder)
        let a = store.put(png: png(7), width: 64, height: 64, now: t0), b = store.put(png: png(7), width: 64, height: 64, now: t0)
        XCTAssertEqual(a, b)
        store.setRecord(record("a.example", a)); store.setRecord(record("b.example", b))
        XCTAssertEqual(store.index.resources.count, 1)
        XCTAssertEqual(blobCount, 1)
        store.remove(IconKey(host: "a.example")!)
        XCTAssertNotNil(store.resourceData(a.hex), "the file stays while another site still shows it")
        store.remove(IconKey(host: "b.example")!)
        XCTAssertEqual(blobCount, 0, "and goes when the last one lets go")
    }

    func testADarkVariantKeepsItsFileWhileTheRecordUsesIt() {
        let store = FaviconDiskStore(directory: folder)
        let light = store.put(png: png(1), width: 64, height: 64, now: t0), dark = store.put(png: png(2), width: 64, height: 64, now: t0)
        store.setRecord(record("a.example", light, dark: dark))
        // The record is replaced by one with no dark variant: the dark file is no longer referenced and goes; the light one stays.
        store.setRecord(record("a.example", light))
        XCTAssertNotNil(store.resourceData(light.hex)); XCTAssertNil(store.resourceData(dark.hex))
        XCTAssertEqual(blobCount, 1)
    }

    func testTheRecordBudgetEvictsTheLeastRecentlyUsedAndIsDeterministic() {
        func run() -> Set<String> {
            let dir = FaviconFixtures.temporaryFolder("evict"); defer { try? FileManager.default.removeItem(at: dir) }
            let store = FaviconDiskStore(directory: dir, budget: FaviconBudget(maxRecords: 3, maxBytes: .max))
            for i in 0..<6 { store.setRecord(record("s\(i).example", store.put(png: png(UInt8(i)), width: 64, height: 64, now: t0), used: Double(i))) }
            return Set(store.index.records.keys)
        }
        XCTAssertEqual(run(), ["s3.example", "s4.example", "s5.example"])
        XCTAssertEqual(run(), run(), "the same history always evicts the same icons")
    }

    func testEqualUseIsBrokenByKey() {
        let store = FaviconDiskStore(directory: folder, budget: FaviconBudget(maxRecords: 2, maxBytes: .max))
        for name in ["c", "a", "b"] { store.setRecord(record("\(name).example", store.put(png: png(UInt8(name.utf8.first!)), width: 64, height: 64, now: t0))) }
        XCTAssertEqual(Set(store.index.records.keys), ["b.example", "c.example"], "a.example sorts first, so it is the one dropped")
    }

    func testTheByteBudgetIsEnforcedToo() {
        let one = png(1).count
        let store = FaviconDiskStore(directory: folder, budget: FaviconBudget(maxRecords: 100, maxBytes: one * 2 + 10))
        for i in 0..<5 { store.setRecord(record("s\(i).example", store.put(png: png(UInt8(i + 10)), width: 64, height: 64, now: t0), used: Double(i))) }
        XCTAssertLessThanOrEqual(store.totalBytes, one * 2 + 10)
        XCTAssertTrue(store.index.records.keys.contains("s4.example"))
    }

    func testAnUnreadableIndexIsSetAsideAndTheProfileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        try Data("orphan".utf8).write(to: folder.appendingPathComponent("blobs/deadbeef.png"))
        let store = FaviconDiskStore(directory: folder)
        XCTAssertTrue(store.quarantined)
        XCTAssertEqual(store.recordCount, 0)
        XCTAssertEqual(corruptFiles.count, 1, "the damaged file is kept for inspection, not deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("blobs/deadbeef.png").path), "files nothing refers to are swept")
    }

    func testAnIndexFromANewerBuildIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var future = FaviconIndex(); future.schemaVersion = FaviconIndex.currentVersion + 5
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: folder.appendingPathComponent("index.json"))
        let store = FaviconDiskStore(directory: folder)
        XCTAssertTrue(store.quarantined)
        XCTAssertEqual(corruptFiles.count, 1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(FaviconIndex.self, from: Data(contentsOf: folder.appendingPathComponent(corruptFiles[0]))), future, "and it is the newer file, untouched")
    }

    func testASecondProblemDoesNotOverwriteTheEvidenceOfTheFirst() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for round in 0..<3 {
            try Data("broken \(round)".utf8).write(to: folder.appendingPathComponent("index.json"))
            _ = FaviconDiskStore(directory: folder)
            Thread.sleep(forTimeInterval: 1.1)
        }
        XCTAssertEqual(corruptFiles.count, 3, "each damaged index keeps its own file")
    }

    func testARecordWhoseFileIsGoneIsDroppedAtStart() throws {
        let store = FaviconDiskStore(directory: folder)
        let id = store.put(png: png(3), width: 64, height: 64, now: t0)
        store.setRecord(record("gone.example", id)); store.flush()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("blobs/\(id.hex).png"))
        XCTAssertNil(FaviconDiskStore(directory: folder).record(IconKey(host: "gone.example")!), "a record without its picture must not be served")
    }

    func testTheOldSharedCacheIsReadInOnceAndLeftInPlace() throws {
        let legacy = FaviconFixtures.temporaryFolder("legacy"); defer { try? FileManager.default.removeItem(at: legacy) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try png(5).write(to: legacy.appendingPathComponent("one.example.png"))
        try Data("garbage".utf8).write(to: legacy.appendingPathComponent("two.example.png"))
        let store = FaviconDiskStore(directory: folder)
        XCTAssertEqual(store.importLegacy(from: legacy, now: t0), 1, "only the valid icon is taken in")
        XCTAssertNotNil(store.record(IconKey(host: "one.example")!))
        XCTAssertEqual(store.importLegacy(from: legacy, now: t0), 0, "once")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path).count, 2, "nothing is deleted from the old folder")
    }

    func testFailuresBackOffLongerEachTimeUpToADay() {
        let store = FaviconDiskStore(directory: folder)
        let key = IconKey(host: "bad.example")!
        var waits: [TimeInterval] = []
        for _ in 0..<12 { store.recordFailure(key, reason: "badStatus", now: t0); waits.append(store.failure(key)!.retryAfter.timeIntervalSince(t0)) }
        XCTAssertEqual(Array(waits.prefix(4)), [600, 1_200, 2_400, 4_800])
        XCTAssertEqual(waits.last, 86_400)
    }

    func testTheFailureListIsBounded() {
        let store = FaviconDiskStore(directory: folder, budget: FaviconBudget(maxRecords: 5, maxBytes: .max))
        for i in 0..<20 { store.recordFailure(IconKey(host: "f\(i).example")!, reason: "badStatus", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertLessThanOrEqual(store.index.failures.count, 5)
    }

    func testClearingSurvivesARelaunchAndDoesNotBringTheOldCacheBack() throws {
        let legacy = FaviconFixtures.temporaryFolder("legacy-clear"); defer { try? FileManager.default.removeItem(at: legacy) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try png(5).write(to: legacy.appendingPathComponent("old.example.png"))
        let store = FaviconDiskStore(directory: folder)
        store.setRecord(record("a.example", store.put(png: png(9), width: 64, height: 64, now: t0))); store.flush()
        store.removeAll(); store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("blobs").path))
        let reopened = FaviconDiskStore(directory: folder)
        XCTAssertEqual(reopened.recordCount, 0)
        XCTAssertEqual(reopened.importLegacy(from: legacy, now: t0), 0, "the empty index says the old cache was already read: clearing is not undone by a restart")
        XCTAssertEqual(reopened.recordCount, 0)
    }

    func testAnUnchangedStoreWritesNothing() throws {
        let store = FaviconDiskStore(directory: folder)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path), "no change, no write")
    }
}
