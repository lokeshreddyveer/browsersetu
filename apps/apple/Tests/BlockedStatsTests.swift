import XCTest
@testable import Browser_Setu

final class BlockedStatsTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testEachRangeAddsUpTheRightHours() {
        var stats = BlockedStats()
        let now = date("2026-10-18T15:30:00Z")
        stats.add(5, at: date("2026-10-18T09:10:00Z"))   // today
        stats.add(3, at: date("2026-10-17T20:00:00Z"))   // 19 hours ago, yesterday
        stats.add(7, at: date("2026-10-14T12:00:00Z"))   // 4 days ago
        stats.add(11, at: date("2026-09-25T12:00:00Z"))  // 23 days ago
        stats.add(13, at: date("2026-03-01T12:00:00Z"))  // 7 months ago
        XCTAssertEqual(stats.total(.today, now: now, calendar: calendar), 5)
        XCTAssertEqual(stats.total(.day, now: now, calendar: calendar), 8)
        XCTAssertEqual(stats.total(.week, now: now, calendar: calendar), 15)
        XCTAssertEqual(stats.total(.month, now: now, calendar: calendar), 26)
        XCTAssertEqual(stats.total(.year, now: now, calendar: calendar), 39)
        XCTAssertEqual(stats.total(.all, now: now, calendar: calendar), 39)
    }

    func testVeryOldHoursStillCountInAllTime() {
        var stats = BlockedStats()
        let now = date("2026-10-18T15:30:00Z")
        stats.add(100, at: date("2024-01-05T10:00:00Z"))
        stats.add(4, at: now)   // adding a new hour folds the old one into the all-time total
        XCTAssertEqual(stats.total(.all, now: now, calendar: calendar), 104)
        XCTAssertEqual(stats.total(.year, now: now, calendar: calendar), 4)
    }

    func testNothingOrNegativeIsIgnoredAndTheFileRoundTrips() throws {
        var stats = BlockedStats()
        stats.add(0); stats.add(-4)
        XCTAssertEqual(stats.total(.all), 0)
        stats.add(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        stats.save(to: url)
        XCTAssertEqual(BlockedStats.load(from: url).total(.all), 9)
        XCTAssertEqual(BlockedStats.load(from: URL(fileURLWithPath: "/nonexistent/x.json")).total(.all), 0)
    }
}

final class BlockedHistoryTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testTopSitesAreRankedAndLimitedToThePeriod() {
        var stats = BlockedStats()
        let now = date("2026-10-18T12:00:00Z")
        stats.add(10, host: "news.com", at: date("2026-10-17T10:00:00Z"))
        stats.add(4, host: "blog.org", at: date("2026-10-16T10:00:00Z"))
        stats.add(7, host: "news.com", at: date("2026-10-10T10:00:00Z"))
        stats.add(50, host: "old.net", at: date("2026-08-01T10:00:00Z"))
        let week = stats.topSites(days: 7, now: now)
        XCTAssertEqual(week.map(\.host), ["news.com", "blog.org"])
        XCTAssertEqual(week.first?.count, 10)
        XCTAssertEqual(stats.topSites(days: 30, now: now).first?.count, 17)
    }

    func testDailyTotalsHaveOneEntryPerDayIncludingEmptyOnes() {
        var stats = BlockedStats()
        let now = date("2026-10-18T12:00:00Z")
        stats.add(5, at: date("2026-10-18T09:00:00Z"))
        stats.add(2, at: date("2026-10-16T22:00:00Z"))
        let days = stats.dailyTotals(days: 4, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.count), [0, 2, 0, 5])
    }

    func testAnOldFileWithoutSiteCountsStillLoads() throws {
        let json = #"{"hours":{"1760000000":9},"older":3}"#
        let stats = try JSONDecoder().decode(BlockedStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.total(.all), 12)
        XCTAssertTrue(stats.topSites(days: 90).isEmpty)
    }
}
