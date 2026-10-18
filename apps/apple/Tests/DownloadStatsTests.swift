import XCTest
@testable import Browser_Setu

final class DownloadStatsTests: XCTestCase {
    func testTimeLeftNeedsASizeAndARate() {
        XCTAssertNil(DownloadStats.secondsLeft(completed: 10, total: 0, rate: 5))
        XCTAssertNil(DownloadStats.secondsLeft(completed: 10, total: 100, rate: 0))
        XCTAssertEqual(DownloadStats.secondsLeft(completed: 50_000_000, total: 100_000_000, rate: 10_000_000), 5)
    }

    func testDurationWording() {
        XCTAssertEqual(DownloadStats.duration(0.2), "1 s")
        XCTAssertEqual(DownloadStats.duration(95), "2 min")
        XCTAssertEqual(DownloadStats.duration(3900), "1 h 5 min")
    }

    func testDetailLeavesOutWhatIsUnknown() {
        XCTAssertEqual(DownloadStats.detail(completed: 0, total: 0, rate: 0), "")
        XCTAssertTrue(DownloadStats.detail(completed: 1_000_000, total: 0, rate: 0).contains("MB") || DownloadStats.detail(completed: 1_000_000, total: 0, rate: 0).contains("KB"))
        XCTAssertTrue(DownloadStats.detail(completed: 5_000_000, total: 10_000_000, rate: 1_000_000).contains("left"))
    }

    func testDiskSpaceIsTightWithLessThanTheFilePlusMargin() {
        XCTAssertTrue(DiskSpace.isTight(needed: 2_000_000_000, available: 1_000_000_000))
        XCTAssertFalse(DiskSpace.isTight(needed: 1_000_000, available: 50_000_000_000))
        XCTAssertFalse(DiskSpace.isTight(needed: 0, available: 0))
    }

    func testSHA256OfKnownContentAndLenientComparison() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try FileChecksum.sha256(of: url)
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(FileChecksum.matches("SHA256:BA7816BF 8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", hash))
        XCTAssertFalse(FileChecksum.matches("", hash))
        XCTAssertFalse(FileChecksum.matches("deadbeef", hash))
    }
}
