import XCTest
@testable import Browser_Setu

final class FrameMonitorTests: XCTestCase {
    private let tick = 1.0 / 60

    func testSmoothFramesLoseNothing() {
        var stats = FrameStats()
        for i in 0..<120 { stats.record(interval: tick, expected: tick, label: "Scrolling", at: Double(i) * tick) }
        XCTAssertEqual(stats.frames, 120)
        XCTAssertEqual(stats.slow, 0)
        XCTAssertEqual(stats.hitchMs, 0, accuracy: 0.001)
        XCTAssertEqual(FrameStats.rating(lostMsPerSecond: stats.lostMsPerSecond), "smooth")
    }

    func testSlowAndStutterThresholds() {
        var stats = FrameStats()
        stats.record(interval: tick * 1.4, expected: tick, label: "A", at: 0)
        stats.record(interval: tick * 2, expected: tick, label: "A", at: 1)
        stats.record(interval: tick * 4, expected: tick, label: "A", at: 2)
        XCTAssertEqual(stats.slow, 2)
        XCTAssertEqual(stats.stutters, 1)
        XCTAssertEqual(stats.hitchMs, (tick * 1 + tick * 3) * 1000, accuracy: 0.001)
    }

    func testLongWaitIsAPauseNotAStutter() {
        var stats = FrameStats()
        stats.record(interval: 5, expected: tick, label: "A", at: 0)
        XCTAssertEqual(stats.pauses, 1)
        XCTAssertEqual(stats.frames, 0)
    }

    func testWorstListKeepsTenLongest() {
        var stats = FrameStats()
        for i in 1...15 { stats.record(interval: tick * 2 + Double(i) / 1000, expected: tick, label: "A", at: Double(i)) }
        XCTAssertEqual(stats.worst.count, 10)
        XCTAssertGreaterThan(stats.worst[0].ms, stats.worst[9].ms)
        XCTAssertEqual(stats.worst[0].at, 15)
    }

    func testBucketsAreSeparatedAndReportNamesThem() {
        var stats = FrameStats()
        stats.record(interval: tick * 3, expected: tick, label: "Switching tab", at: 0)
        stats.record(interval: tick, expected: tick, label: "Scrolling a page", at: 1)
        stats.noteModelChange(label: "Switching tab", site: "BrowserModelC.foo ← bar")
        let text = stats.report(header: ["Test"])
        XCTAssertTrue(text.contains("Switching tab"))
        XCTAssertTrue(text.contains("Scrolling a page"))
        XCTAssertTrue(text.contains("BrowserModelC.foo ← bar"))
        XCTAssertEqual(stats.modelChanges, 1)
    }

    func testPublisherSiteTakesFirstModelFrameAndItsCaller() {
        let frames = [
            "0   Browser Setu   0x0000000100000010 $s12FrameMonitor0A0C15modelWillChangeyyF + 8",
            "1   Browser Setu   0x0000000100000020 $s12Browser_Setu12BrowserModelC15chromeCollapsedSbvs + 12",
            "2   Browser Setu   0x0000000100000030 $s12Browser_Setu12BrowserModelC12pageScrolled6deltaYySd_tF + 40",
        ]
        let site = PublisherSite.describe(frames)
        XCTAssertEqual(site, "$s12Browser_Setu12BrowserModelC15chromeCollapsedSbvs ← $s12Browser_Setu12BrowserModelC12pageScrolled6deltaYySd_tF")
        XCTAssertNil(PublisherSite.describe(["0   X   0x1 unrelated + 1"]))
    }

    func testReportHasNoAddressesOrTitles() {
        var stats = FrameStats()
        stats.record(interval: tick * 3, expected: tick, label: "Idle or other", at: 0)
        XCTAssertFalse(stats.report(header: []).contains("http"))
    }
}
