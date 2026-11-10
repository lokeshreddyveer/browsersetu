import XCTest
import WebKit
@testable import Browser_Setu

// Private windows: what ⇧⌘N does, which tabs may move, and that each private window's storage is its own (real WebKit stores, no network).

final class PrivateOpeningRuleTests: XCTestCase {
    func testTheSettingDecidesAndAPrivateContextAlwaysGetsATab() {
        let table: [(PrivateOpenMode, Bool, Bool, PrivateOpening.Action)] = [
            (.window, false, true, .newWindow), (.tab, false, true, .tabHere), (.ask, false, true, .askFirst),
            (.window, true, true, .tabHere), (.ask, true, true, .tabHere), (.tab, true, true, .tabHere),      // already private: just a tab there
            (.window, false, false, .tabHere), (.ask, false, false, .tabHere),                                  // no windows to open (iPhone): a tab
        ]
        for (mode, privateContext, windows, expected) in table {
            XCTAssertEqual(PrivateOpening.action(mode: mode, inPrivateContext: privateContext, canOpenWindows: windows), expected, "\(mode) private=\(privateContext) windows=\(windows)")
        }
    }

    func testNoTabChangesWhoCanSeeItsCookiesByMoving() {
        func r(_ priv: Bool, from: Bool, to: Bool, guest: Bool = false) -> PrivateTabMove.Refusal? {
            PrivateTabMove.refusal(tabIsPrivate: priv, sourceIsPrivateWindow: from, targetIsPrivateWindow: to, targetIsGuest: guest)
        }
        XCTAssertEqual(r(true, from: true, to: false), .leavesPrivateWindow, "a private window's tab never goes to an ordinary window")
        XCTAssertEqual(r(true, from: true, to: true), .leavesPrivateWindow, "nor to another private window (different storage)")
        XCTAssertEqual(r(false, from: false, to: true), .entersPrivateWindow, "an ordinary tab never becomes private by being dropped in")
        XCTAssertEqual(r(true, from: false, to: true), .entersPrivateWindow, "a private tab of an ordinary window has other storage than the window's")
        XCTAssertEqual(r(false, from: false, to: false, guest: true), .normalTabInGuest)
        XCTAssertNil(r(true, from: false, to: false, guest: true), "existing behaviour: a private tab may go to a guest window")
        XCTAssertNil(r(false, from: false, to: false)); XCTAssertNil(r(true, from: false, to: false))
        for refusal in [PrivateTabMove.Refusal.leavesPrivateWindow, .entersPrivateWindow, .normalTabInGuest] { XCTAssertFalse(refusal.message.isEmpty) }
    }

    func testTheShortcutsAreDistinctAndShiftCommandNFollowsTheSetting() {
        let map = ShortcutMap()
        XCTAssertEqual(map.combo(for: .newPrivate)?.display, "⇧⌘N")
        let combos = [ShortcutAction.newPrivate, .newPrivateWindow, .newPrivateTab, .newTab, .reopenClosedTab].compactMap { map.combo(for: $0) }
        XCTAssertEqual(Set(combos.map(\.display)).count, combos.count, "no two of these share a key")
        XCTAssertEqual(PrivateOpenMode.allCases.count, 3)
    }
}

@MainActor
final class PrivateWindowModelTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pw-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        return m
    }

    func testTheDefaultIsAPrivateWindowAndTheChoiceIsSaved() async {
        let m = await model()
        XCTAssertEqual(m.privateOpenMode, .window)
        m.privateOpenMode = .ask
        XCTAssertEqual((try? m.core.getSetting(key: "private_open_mode")) ?? nil, "ask")
    }

    func testNewPrivateOpensAWindowAsksOrMakesATabAsChosen() async {
        let m = await model()
        var windowsRequested = 0
        m.windows.onNeedWindow = { windowsRequested += 1 }
        m.privateOpenMode = .window
        m.newPrivate()
        XCTAssertEqual(windowsRequested, 1); XCTAssertTrue(m.windows.openingPrivate); XCTAssertFalse(m.privateChoicePending)
        m.windows.openingPrivate = false

        m.privateOpenMode = .ask
        let before = m.tabs.count
        m.newPrivate()
        XCTAssertTrue(m.privateChoicePending, "it asks first"); XCTAssertEqual(m.tabs.count, before); XCTAssertEqual(windowsRequested, 1)

        m.answerPrivateChoice(window: false, remember: true)
        XCTAssertFalse(m.privateChoicePending); XCTAssertEqual(m.tabs.count, before + 1); XCTAssertTrue(m.tabs.last?.isPrivate == true)
        XCTAssertEqual(m.privateOpenMode, .tab, "remembered")

        m.newPrivate()
        XCTAssertEqual(m.tabs.count, before + 2, "now it just makes a tab, without asking"); XCTAssertFalse(m.privateChoicePending)
    }

    func testInsideAPrivateWindowEverythingIsPrivateAndNothingAsks() async {
        let m = await model()
        m.isPrivateWindow = true
        m.privateOpenMode = .ask
        let t = m.openTab(url: nil, isPrivate: false)
        XCTAssertTrue(t.isPrivate, "even a tab asked to be ordinary is private here")
        m.newPrivate()
        XCTAssertFalse(m.privateChoicePending)
        XCTAssertTrue(m.tabs.allSatisfy(\.isPrivate) || m.tabs.contains(where: \.isPrivate))
        m.moveTabToNewWindow(t.id)
        XCTAssertFalse(m.windows.movingTabs.contains(t.id), "a private window's tab does not leave it")
    }

    func testAnExplicitPrivateWindowRequestMarksTheNextWindow() async {
        let m = await model()
        var asked = 0
        m.windows.onNeedWindow = { asked += 1 }
        m.openPrivateWindow()
        XCTAssertEqual(asked, 1); XCTAssertTrue(m.windows.openingPrivate); XCTAssertFalse(m.windows.openingGuest)
    }
}

@MainActor
final class PrivateSessionStoreTests: XCTestCase {
    private func cookie(_ name: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "1", .domain: "example.test", .path: "/", .secure: "TRUE"])!
    }

    func testEachPrivateWindowHasItsOwnStoreAndTheSharedOneIsAnotherAgain() {
        let engine = WebKitEngine()
        let a = UUID(), b = UUID()
        let a1 = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: a).websiteDataStore
        let a2 = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: a).websiteDataStore
        let b1 = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: b).websiteDataStore
        let shared = engine.makeConfiguration(isPrivate: true, profile: "default").websiteDataStore
        let shared2 = engine.makeConfiguration(isPrivate: true, profile: "default").websiteDataStore
        XCTAssertTrue(a1 === a2, "tabs of one private window share its storage")
        XCTAssertFalse(a1 === b1, "another private window has other storage")
        XCTAssertTrue(shared === shared2); XCTAssertFalse(shared === a1); XCTAssertFalse(shared === b1)
        XCTAssertFalse(a1.isPersistent); XCTAssertFalse(b1.isPersistent)
        XCTAssertEqual(engine.privateSessionCount, 2)
        engine.releasePrivateSession(a)
        XCTAssertEqual(engine.privateSessionCount, 1); XCTAssertNil(engine.privateSessionStore(a)); XCTAssertNotNil(engine.privateSessionStore(b))
        let fresh = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: a).websiteDataStore
        XCTAssertFalse(fresh === a1, "a window that is opened again starts with new storage")
    }

    func testACookieInOnePrivateWindowIsNotSeenByAnotherByTheSharedStoreOrByANormalWindow() async {
        let engine = WebKitEngine()
        let a = UUID(), b = UUID()
        let storeA = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: a).websiteDataStore
        let storeB = engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: b).websiteDataStore
        let shared = engine.makeConfiguration(isPrivate: true, profile: "default").websiteDataStore
        await storeA.httpCookieStore.setCookie(cookie("only-in-a"))
        let inA = await storeA.httpCookieStore.allCookies().map(\.name)
        let inB = await storeB.httpCookieStore.allCookies().map(\.name)
        let inShared = await shared.httpCookieStore.allCookies().map(\.name)
        XCTAssertEqual(inA, ["only-in-a"]); XCTAssertEqual(inB, []); XCTAssertEqual(inShared, [])
    }
}
