import XCTest
import CryptoKit
@testable import Browser_Setu

/// A source that gave the wrong file is not asked again for that task, and another source the person gave is tried, with the checksum still deciding.
@MainActor
final class CorruptSourceFailoverTests: MediaCase {
    static let good: Data = { var b = [UInt8](repeating: 0, count: 3 << 20); for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }; return Data(b) }()
    static let goodHash = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()

    private func fileHash(_ path: String?) -> String? {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    private func sourceHits() async -> [String: Int] {
        guard let d = try? await get("/_media_hits"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j["hits"] as? [String: Int] ?? [:]
    }
    override func setUp() async throws { try await super.setUp(); HTTPRetrySchedule.delayScale = 0.02 }
    override func tearDown() async throws { HTTPRetrySchedule.delayScale = 1; try await super.tearDown() }

    /// Starts the retry and waits for it to actually begin: the task is still "failed" for a moment after the request, which a plain wait would take for the answer.
    private func retry(_ id: UUID) async {
        c.retryFailure(id)
        for _ in 0..<100 where c.ledger.record(id)?.state == .failed { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private var wrong: Data { var w = Self.good; for i in stride(from: 1000, to: w.count, by: 4096) { w[i] ^= 0x5A }; return w }

    func testAfterAChecksumMismatchTheNextSourceIsUsedAndTheCorruptOneIsNotFetchedAgain() async throws {
        try await put("cs1/a.bin", wrong); try await put("cs1/b.bin", Self.good)
        c.segmentedEnabled = false
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/cs1/a.bin"), at: Date(), expectedSHA256: Self.goodHash))
        let first = await wait(id, for: [.completed, .failed], seconds: 60)
        XCTAssertEqual(first?.state, .failed, "no other source yet: the wrong file is refused")
        XCTAssertNil(first?.file.destinationPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }, "the wrong file is not kept")
        let before = await sourceHits()["cs1/a.bin"] ?? 0
        c.mirrors.add([url("/media/cs1/b.bin").absoluteString], to: id)
        await retry(id)
        let record = await wait(id, for: [.completed, .failed], seconds: 90)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(fileHash(record?.file.destinationPath), Self.goodHash, "only a file that matches the checksum is kept")
        let after = await sourceHits()["cs1/a.bin"] ?? 0
        XCTAssertEqual(after, before, "the source that gave the wrong file was not asked again")
        XCTAssertEqual(c.ledger.records.count, 1, "one task")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }

    func testWithNoOtherSourceTryAgainDoesNotFetchTheSameWrongFileAgain() async throws {
        try await put("cs2/a.bin", wrong)
        c.segmentedEnabled = false
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/cs2/a.bin"), at: Date(), expectedSHA256: Self.goodHash))
        _ = await wait(id, for: [.completed, .failed], seconds: 60)
        let before = await sourceHits()["cs2/a.bin"] ?? 0
        c.retryFailure(id)
        for _ in 0..<200 where !(c.ledger.record(id)?.failure?.reason ?? "").contains("not used again") { try? await Task.sleep(nanoseconds: 50_000_000) }
        let record = c.ledger.record(id)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue((record?.failure?.reason ?? "").contains("not used again"), record?.failure?.reason ?? "")
        let after = await sourceHits()["cs2/a.bin"] ?? 0
        XCTAssertEqual(after, before, "no new request to a source already found wrong")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }

    func testAMirrorThatAlsoGivesTheWrongFileIsAlsoSetAside() async throws {
        try await put("cs3/a.bin", wrong); var other = wrong; other[5] ^= 0xFF; try await put("cs3/b.bin", other); try await put("cs3/c.bin", Self.good)
        c.segmentedEnabled = false
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/cs3/a.bin"), at: Date(), expectedSHA256: Self.goodHash))
        _ = await wait(id, for: [.completed, .failed], seconds: 60)
        c.mirrors.add([url("/media/cs3/b.bin").absoluteString, url("/media/cs3/c.bin").absoluteString], to: id)
        await retry(id)
        var record = await wait(id, for: [.completed, .failed], seconds: 90)
        if record?.state == .failed { await retry(id); record = await wait(id, for: [.completed, .failed], seconds: 90) }
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(fileHash(record?.file.destinationPath), Self.goodHash)
    }

    func testWithoutAChecksumNothingIsMarkedCorrupt() async throws {
        try await put("cs4/a.bin", Self.good)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/cs4/a.bin"), at: Date()))
        let record = await wait(id, for: [.completed, .failed], seconds: 60)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertNil(record?.engineMetadata["corruptSources"])
    }
}
