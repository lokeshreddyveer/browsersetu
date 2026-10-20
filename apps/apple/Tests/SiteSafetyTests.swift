import XCTest
@testable import Browser_Setu

final class SiteSafetyTests: XCTestCase {
    // MARK: look-alikes

    func testRealSitesAreLeftAlone() {
        for host in ["paypal.com", "www.paypal.com", "paypal.me", "login.microsoft.com", "example.com", "mail.google.com", "google.co.uk", "github.com", "paypal.github.io", "apple-pie.com", "reddit.com"] {
            XCTAssertNil(LookalikeCheck.check(host: host), host)
        }
    }

    func testDigitsAndLettersSwappedAreCaught() {
        XCTAssertEqual(LookalikeCheck.check(host: "paypa1.com")?.imitates, "paypal")
        XCTAssertEqual(LookalikeCheck.check(host: "g00gle.com")?.imitates, "google")
        XCTAssertEqual(LookalikeCheck.check(host: "rnicrosoft.com")?.imitates, "microsoft")
        XCTAssertEqual(LookalikeCheck.check(host: "amaz0n.in")?.imitates, "amazon")
    }

    func testOtherAlphabetsAreCaught() {
        // The first letter is Cyrillic "а".
        XCTAssertEqual(LookalikeCheck.check(host: "аpple.com")?.imitates, "apple")
        // The same address written the way the network carries it.
        XCTAssertNotNil(LookalikeCheck.check(host: "xn--pple-43d.com"))
    }

    func testPunycodeDecodes() {
        XCTAssertEqual(LookalikeCheck.punycodeDecode("pple-43d"), "аpple")
        XCTAssertEqual(LookalikeCheck.punycodeDecode("bcher-kva"), "bücher")
    }

    func testOneLetterAwayAndNamesInFrontAreCaught() {
        XCTAssertNotNil(LookalikeCheck.check(host: "paypall.com"))
        XCTAssertNotNil(LookalikeCheck.check(host: "gooogle.com"))
        XCTAssertNotNil(LookalikeCheck.check(host: "paypal.com.secure-login.io"))
        XCTAssertNotNil(LookalikeCheck.check(host: "microsoft.com.attacker.net"))
        XCTAssertNotNil(LookalikeCheck.check(host: "secure-paypal-login.com"))
        XCTAssertNotNil(LookalikeCheck.check(host: "login.paypal.example.org"))
    }

    func testRegistrableDomain() {
        XCTAssertEqual(LookalikeCheck.registrable("mail.example.com"), "example.com")
        XCTAssertEqual(LookalikeCheck.registrable("shop.example.co.uk"), "example.co.uk")
        XCTAssertEqual(LookalikeCheck.registrable("example.com"), "example.com")
    }

    // MARK: score

    func testScoreRewardsAQuietSecureSiteAndPunishesTheOpposite() {
        let calm = SiteScore.score(secure: true, thirdParties: 0, blocked: 0, permissionsGranted: 0, lookalike: nil)
        XCTAssertEqual(calm.grade, "A")
        let busy = SiteScore.score(secure: false, thirdParties: 20, blocked: 30, permissionsGranted: 3, lookalike: LookalikeCheck.check(host: "paypa1.com"))
        XCTAssertEqual(busy.grade, "F")
        XCTAssertTrue(busy.points >= 0)
        XCTAssertTrue(calm.reasons.allSatisfy(\.good))
    }

    func testScoreStaysInRange() {
        let worst = SiteScore.score(secure: false, thirdParties: 500, blocked: 500, permissionsGranted: 50, lookalike: LookalikeCheck.check(host: "g00gle.com"))
        XCTAssertEqual(worst.points, 0)
    }

    // MARK: asking in plain words

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    // Wednesday 21 Oct 2026, midday.
    private var now: Date { Date(timeIntervalSince1970: 1_792_584_000) }

    func testPlainRecallFindsTheTimeAndKeepsTheWords() throws {
        let request = try XCTUnwrap(PlainRecall.parse("that pasta recipe from last week", now: now, calendar: cal))
        XCTAssertEqual(request.terms, ["pasta", "recipe"])
        XCTAssertEqual(request.phrase, "last week")
        let from = try XCTUnwrap(request.from), to = try XCTUnwrap(request.to)
        XCTAssertEqual(to.timeIntervalSince(from), 7 * 86_400, accuracy: 1)
        XCTAssertLessThan(to, now)
    }

    func testPlainRecallOtherPhrases() throws {
        XCTAssertNotNil(PlainRecall.parse("yesterday bank", now: now, calendar: cal))
        XCTAssertNotNil(PlainRecall.parse("flights 3 days ago", now: now, calendar: cal))
        XCTAssertEqual(try XCTUnwrap(PlainRecall.parse("flights 3 days ago", now: now, calendar: cal)).terms, ["flights"])
        XCTAssertNil(PlainRecall.parse("swift concurrency tutorial", now: now, calendar: cal))
    }

    func testPlainRecallMatchesOnlyInsideTheTime() throws {
        let request = try XCTUnwrap(PlainRecall.parse("pasta yesterday", now: now, calendar: cal))
        let yesterday = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        let lastMonth = Int64(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        XCTAssertTrue(PlainRecall.matches(HistoryItem(url: "https://x.com/a", title: "Best Pasta", lastVisit: yesterday, visitCount: 1), request))
        XCTAssertFalse(PlainRecall.matches(HistoryItem(url: "https://x.com/a", title: "Best Pasta", lastVisit: lastMonth, visitCount: 1), request))
        XCTAssertFalse(PlainRecall.matches(HistoryItem(url: "https://x.com/a", title: "Soup", lastVisit: yesterday, visitCount: 1), request))
    }

    // MARK: focus schedule

    func testFocusRuleTimesAndDays() {
        var rule = FocusRule(name: "Work", workspace: "Work")
        let wed10 = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
        let wed18 = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18))!
        let sat10 = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))!
        XCTAssertTrue(rule.isActive(at: wed10, calendar: cal))
        XCTAssertFalse(rule.isActive(at: wed18, calendar: cal))
        XCTAssertFalse(rule.isActive(at: sat10, calendar: cal))
        rule.enabled = false
        XCTAssertNil(FocusSchedule.current([rule], at: wed10, calendar: cal))
    }

    func testFocusRuleOverMidnight() {
        let rule = FocusRule(name: "Night", weekdays: Set(1...7), startMinute: 22 * 60, endMinute: 6 * 60)
        let late = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23))!
        let early = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 5))!
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        XCTAssertTrue(rule.isActive(at: late, calendar: cal))
        XCTAssertTrue(rule.isActive(at: early, calendar: cal))
        XCTAssertFalse(rule.isActive(at: noon, calendar: cal))
    }
}
