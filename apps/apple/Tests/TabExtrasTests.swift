import XCTest
@testable import Browser_Setu

final class TabExtrasTests: XCTestCase {
    func testGroupPathParts() {
        XCTAssertEqual(GroupPath.depth("Work/Project A/Docs"), 2)
        XCTAssertEqual(GroupPath.leaf("Work/Project A"), "Project A")
        XCTAssertEqual(GroupPath.parent("Work/Project A"), "Work")
        XCTAssertNil(GroupPath.parent("Work"))
        XCTAssertTrue(GroupPath.isInside("Work/A", of: "Work"))
        XCTAssertTrue(GroupPath.isInside("Work", of: "Work"))
        XCTAssertFalse(GroupPath.isInside("Workshop", of: "Work"), "a longer name is not a subgroup")
    }

    func testVisibleGroupsAreInTreeOrderWithMissingParentsAndFolding() {
        let names = ["Work/A", "Home", "Work/B", "Work/A/Docs"]
        XCTAssertEqual(GroupPath.visible(names, collapsed: []), ["Work", "Work/A", "Work/A/Docs", "Work/B", "Home"])
        XCTAssertEqual(GroupPath.visible(names, collapsed: ["Work"]), ["Work", "Home"])
        XCTAssertEqual(GroupPath.visible(names, collapsed: ["Work/A"]), ["Work", "Work/A", "Work/B", "Home"])
    }

    func testGroupSearchKeepsMatchesWithTheirParentsAndChildren() {
        let names = ["Work/Budget", "Work/Plans", "Home"]
        XCTAssertEqual(GroupPath.visible(names, collapsed: [], query: "budget"), ["Work", "Work/Budget"])
        XCTAssertEqual(GroupPath.visible(names, collapsed: ["Work"], query: "plans"), ["Work", "Work/Plans"], "a search ignores folding")
    }

    func testSortingKeepsPinnedFirstAndIsStable() {
        struct T { var name: String; var host: String; var pinned: Bool; var used: Date }
        let now = Date()
        let tabs = [T(name: "b", host: "www.z.com", pinned: false, used: now), T(name: "a", host: "y.com", pinned: false, used: now.addingTimeInterval(-10)),
                    T(name: "c", host: "x.com", pinned: true, used: now.addingTimeInterval(-99))]
        func run(_ o: TabSortOrder) -> [String] { TabSortOrder.sorted(tabs, by: o, pinned: \.pinned, host: \.host, title: \.name, lastUsed: \.used).map(\.name) }
        XCTAssertEqual(run(.website), ["c", "a", "b"])
        XCTAssertEqual(run(.title), ["c", "a", "b"])
        XCTAssertEqual(run(.lastUsed), ["c", "b", "a"])
    }

    func testSnoozeChoicesLandInTheFutureAtTheRightHour() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20, minute: 30))! // a Sunday
        let tomorrow = SnoozeChoice.tomorrow.date(from: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.day, .hour], from: tomorrow).day, 19)
        XCTAssertEqual(cal.component(.hour, from: tomorrow), 9)
        XCTAssertEqual(cal.component(.weekday, from: SnoozeChoice.nextWeek.date(from: now, calendar: cal)), 2)
        XCTAssertGreaterThan(SnoozeChoice.thisEvening.date(from: now, calendar: cal), now)
    }

    func testDueEntriesOpenAndRepeatsComeBack() {
        let now = Date()
        let once = TabSchedule(url: "https://a.com", title: "A", when: now.addingTimeInterval(-5))
        let daily = TabSchedule(url: "https://b.com", title: "B", when: now.addingTimeInterval(-5), repeats: .daily)
        let later = TabSchedule(url: "https://c.com", title: "C", when: now.addingTimeInterval(500))
        let result = ScheduleRules.run([once, daily, later], now: now)
        XCTAssertEqual(result.due.map(\.title), ["A", "B"])
        XCTAssertEqual(result.remaining.map(\.title), ["B", "C"])
        XCTAssertGreaterThan(result.remaining[0].when, now)
    }
}
