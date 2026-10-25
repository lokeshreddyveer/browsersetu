import XCTest
@testable import Browser_Setu

/// Defects found in a review of the code written since build 14, each pinned by a test.
@MainActor
final class ReviewFixesTests: XCTestCase {
    private func makeModel() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-review-\(UUID().uuidString)", profile: "default")
    }

    // MARK: Clear Everything Now reaches every window and the lists of what was closed

    func testClearingEverythingClosesEveryTabInEveryWindowAndForgetsWhatWasClosed() async throws {
        let first = makeModel()
        await first.start()
        let second = BrowserModel(sharing: first)
        _ = first.openTab(url: nil, isPrivate: false)
        _ = first.openTab(url: nil, isPrivate: true)
        _ = second.openTab(url: nil, isPrivate: false)
        first.closedTabs = [ClosedTab(url: URL(string: "https://example.com/secret")!, title: "Secret", group: "")]
        second.closedTabs = [ClosedTab(url: URL(string: "https://example.org/also")!, title: "Also", group: "")]
        first.windows.closedWindows = [ClosedWindow(urls: [URL(string: "https://example.net/window")!])]
        XCTAssertTrue(first.tabs.contains(where: \.isPrivate))

        for window in first.windows.all { window.closeEverythingInThisWindow() }
        first.windows.closedWindows = []

        XCTAssertTrue(first.closedTabs.isEmpty, "Reopen Closed Tab must not reveal what was open")
        XCTAssertTrue(second.closedTabs.isEmpty, "…in any window")
        XCTAssertTrue(first.windows.closedWindows.isEmpty)
        XCTAssertFalse(first.tabs.contains(where: \.isPrivate), "private tabs close too")
        XCTAssertEqual(first.tabs.count, 1, "the first window keeps one blank tab")
        XCTAssertTrue(first.tabs.allSatisfy(\.isBlank))
        XCTAssertTrue(second.tabs.isEmpty, "another window with nothing left closes")
    }

    // MARK: a group from another device exists here before tabs are put in it

    func testAGroupFromAnotherDeviceIsCreatedBeforeItsTabsArePutInIt() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertFalse(model.groupNames.contains("Trip"))
        model.adoptSyncedGroup("  Trip  ", tabs: [BackupPayload.Tab(url: "https://example.com/a", title: "A", group: "Trip"),
                                                  BackupPayload.Tab(url: "javascript:alert(1)", title: "bad", group: "Trip"),
                                                  BackupPayload.Tab(url: "https://example.com/b", title: "B", group: "Trip")])
        XCTAssertTrue(model.groupNames.contains("Trip"), "the group is made, with its name tidied")
        XCTAssertEqual(model.tabs.filter { $0.group == "Trip" }.count, 2, "the web address that is not a web address is skipped")
        model.adoptSyncedGroup("x" + String(repeating: "y", count: 80), tabs: [BackupPayload.Tab(url: "https://example.com/c", title: "C", group: nil)])
        XCTAssertTrue(model.groupNames.allSatisfy { $0.count <= 40 }, "a name from outside is cut to the limit")
        model.adoptSyncedGroup("   ", tabs: [BackupPayload.Tab(url: "https://example.com/d", title: "D", group: nil)])
        XCTAssertFalse(model.tabs.contains { ($0.url?.absoluteString ?? "") == "https://example.com/d" }, "an empty name opens nothing")
    }

    // MARK: a look-alike question is asked once

    func testALookalikeQuestionIsNotStacked() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertTrue(model.lookalikePrompting.insert("paypa1.com").inserted)
        XCTAssertFalse(model.lookalikePrompting.insert("paypa1.com").inserted, "the second redirect finds the question already open")
    }
}

final class ReviewRulesTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private var now: Date { Date(timeIntervalSince1970: 1_792_584_000) }   // Wednesday 21 October 2026, midday UTC

    func testATimeWithNoWordsIsAnOrdinarySearch() {
        XCTAssertNil(PlainRecall.parse("yesterday", now: now, calendar: cal))
        XCTAssertNil(PlainRecall.parse("today", now: now, calendar: cal))
        XCTAssertNil(PlainRecall.parse("show me yesterday", now: now, calendar: cal), "only filler words besides the time")
        XCTAssertNotNil(PlainRecall.parse("bank yesterday", now: now, calendar: cal))
    }

    func testAnOvernightRuleIsAppliedOnceAcrossMidnight() {
        let rule = FocusRule(name: "Night", weekdays: Set(1...7), startMinute: 22 * 60, endMinute: 6 * 60)
        let before = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23))!
        let after = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 1))!
        let nextEvening = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23))!
        XCTAssertEqual(FocusSchedule.windowKey(rule, at: before, calendar: cal), FocusSchedule.windowKey(rule, at: after, calendar: cal),
                       "11 pm and 1 am are one stretch: a switch made by hand in between stays")
        XCTAssertNotEqual(FocusSchedule.windowKey(rule, at: before, calendar: cal), FocusSchedule.windowKey(rule, at: nextEvening, calendar: cal), "the next night is a new stretch")
        let day = FocusRule(name: "Work", startMinute: 9 * 60, endMinute: 17 * 60)
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
        XCTAssertEqual(FocusSchedule.windowKey(day, at: morning, calendar: cal), FocusSchedule.windowKey(day, at: afternoon, calendar: cal))
    }

    func testAHostingServiceWithABrandInFrontIsStillCaught() {
        // The reason the look-alike check does not use the Public Suffix List: it would treat these as separate sites named after the brand.
        XCTAssertNotNil(LookalikeCheck.check(host: "paypal.blogspot.com"))
        XCTAssertNotNil(LookalikeCheck.check(host: "microsoft.com.web.app"))
        XCTAssertNil(LookalikeCheck.check(host: "myblog.blogspot.com"))
    }

    func testTheStartPageAndTheLookupsAgreeAboutWhatIsLocal() {
        for host in ["172.20.1.1", "169.254.9.9", "nas.lan", "printer.internal", "router"] { XCTAssertFalse(PublicAddress.isPublicHost(host), host) }
        XCTAssertTrue(PublicAddress.isPublicHost("example.com"))
    }
}

@MainActor
final class DownloadCleanupTests: XCTestCase {
    func testAFileWrittenAfterACancelIsRemovedWhenTheFailureArrives() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let coordinator = DownloadCoordinator()
        coordinator.profileFolder = nil
        let started = coordinator.begin(suggestedName: "late-\(UUID().uuidString).bin", cancel: {})
        defer { try? FileManager.default.removeItem(at: started.destination); try? FileManager.default.removeItem(at: folder) }
        // The file is there while downloading; cancelling removes it.
        try Data("partial".utf8).write(to: started.destination)
        coordinator.discard(started.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.path))
        // WebKit writes once more, then reports the failure: the second cleanup finds the file again.
        try Data("one more chunk".utf8).write(to: started.destination)
        coordinator.discard(started.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.path), "the late file is removed, not left behind")
    }

    func testALateCleanupNeverTouchesANewDownloadThatTookTheSameName() throws {
        let coordinator = DownloadCoordinator()
        let old = coordinator.begin(suggestedName: "same-\(UUID().uuidString).bin", cancel: {})
        defer { try? FileManager.default.removeItem(at: old.destination) }
        try Data("old".utf8).write(to: old.destination)
        coordinator.discard(old.id)
        // A new download is given the same name (the first one is gone, so it is free again).
        let again = coordinator.begin(suggestedName: old.destination.lastPathComponent, cancel: {})
        XCTAssertEqual(again.destination, old.destination)
        try Data("new".utf8).write(to: again.destination)
        coordinator.discard(old.id)   // the old download's failure arrives late
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.destination.path), "the new download's file survives")
        coordinator.discard(again.id)
    }
}
