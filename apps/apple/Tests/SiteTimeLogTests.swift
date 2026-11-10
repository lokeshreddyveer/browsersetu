import XCTest
@testable import Browser_Setu

/// Time on sites: off by default, kept per site per day, forgotten after the chosen number of days, never from a private tab.
@MainActor
final class SiteTimeLogTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testRetentionForgetsOldDaysAndZeroKeepsEverything() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        var log = SiteTimeLog()
        for offset in [0, 3, 10, 40, 100, 400] {
            let day = calendar.date(byAdding: .day, value: -offset, to: now)!
            log.add(seconds: 60, host: "a.example", on: day)
        }
        XCTAssertEqual(log.days.count, 6, "adding never forgets anything by itself")
        var thirty = log; thirty.prune(keepingDays: 30, now: now, calendar: calendar)
        XCTAssertEqual(thirty.days.count, 3)
        var seven = log; seven.prune(keepingDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(seven.days.count, 2)
        var forever = log; forever.prune(keepingDays: 0, now: now, calendar: calendar)
        XCTAssertEqual(forever.days.count, 6)
    }

    func testTheChartAndTopSitesComeFromTheSameLocalNumbers() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        var log = SiteTimeLog()
        log.add(seconds: 100, host: "news.example", on: now)
        log.add(seconds: 50, host: "docs.example", on: now)
        log.add(seconds: 90, host: "news.example", on: calendar.date(byAdding: .day, value: -2, to: now)!)
        log.add(seconds: 70, host: "old.example", on: calendar.date(byAdding: .day, value: -9, to: now)!)
        let chart = log.recent(days: 14, endingOn: now, calendar: calendar)
        XCTAssertEqual(chart.count, 14)
        XCTAssertEqual(chart.last?.seconds, 150)
        XCTAssertEqual(chart.reduce(0) { $0 + $1.seconds }, 310)
        let top = log.topSites(days: 7, endingOn: now, calendar: calendar)
        XCTAssertEqual(top.map(\.host), ["news.example", "docs.example"], "only the last seven days")
        XCTAssertEqual(top.first?.seconds, 190)
        XCTAssertEqual(log.sites(on: now).count, 2)
    }

    func testAShortGapIsCountedAndALongOneIsNot() {
        var log = SiteTimeLog()
        log.add(seconds: 30, host: "a.example")
        log.add(seconds: 5000, host: "a.example")           // the computer was asleep: not counted
        log.add(seconds: -3, host: "a.example")
        XCTAssertEqual(log.total(), 30)
        XCTAssertEqual(SiteTimeLog.idleLimit, 120)
    }

    func testTrackingIsOffByDefaultNeverCountsAPrivateTabAndKeepsOnlySiteAndSeconds() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-time-\(UUID().uuidString)", profile: "default")
        await m.start()
        XCTAssertFalse(m.trackTime, "off until the person turns it on")
        let tab = m.openTab(url: nil, isPrivate: true)
        tab.url = URL(string: "https://secret.example/page")
        m.trackTime = true
        m.lastInteraction = Date()
        let start = Date()
        m.trackSiteTime(now: start)
        m.trackSiteTime(now: start.addingTimeInterval(20))
        XCTAssertTrue(m.siteTimeLog.days.isEmpty, "a private tab is never counted")
        let stored = String(data: try JSONEncoder().encode(m.siteTimeLog), encoding: .utf8) ?? ""
        XCTAssertFalse(stored.contains("secret.example"))
        m.setSiteTimeRetention(7)
        XCTAssertEqual(m.siteTimeRetentionDays, 7)
        m.clearSiteTime()
        XCTAssertTrue(m.siteTimeLog.days.isEmpty)
    }
}
