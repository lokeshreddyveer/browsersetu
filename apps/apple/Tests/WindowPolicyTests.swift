import XCTest
@testable import Browser_Setu

final class WindowPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testARequestIsClaimedOnceAndExpires() {
        XCTAssertEqual(WindowPolicy.live([now.addingTimeInterval(-1), now.addingTimeInterval(-9)], now: now).count, 1)
        XCTAssertTrue(WindowPolicy.live([], now: now).isEmpty)
    }

    @MainActor
    func testOnlyWindowsTheAppAskedForAreWanted() {
        let registry = WindowRegistry()
        XCTAssertFalse(registry.claimRequest(now: now), "a window nobody asked for")
        registry.requestWindow(now: now)
        registry.requestWindow(now: now)
        XCTAssertTrue(registry.claimRequest(now: now.addingTimeInterval(1)))
        XCTAssertTrue(registry.claimRequest(now: now.addingTimeInterval(1)))
        XCTAssertFalse(registry.claimRequest(now: now.addingTimeInterval(1)), "two asked for, two claimed")
        // A request the system never answered must not be given to a window that shows up much later for another reason.
        registry.requestWindow(now: now)
        XCTAssertFalse(registry.claimRequest(now: now.addingTimeInterval(30)))
    }

    func testTheSameLinkReachingTwoWindowsIsActedOnOnce() {
        let url = URL(string: "https://claude.ai/login")!
        XCTAssertFalse(WindowPolicy.isDuplicate(url, last: nil, now: now))
        XCTAssertTrue(WindowPolicy.isDuplicate(url, last: (url, now), now: now.addingTimeInterval(0.4)))
        XCTAssertFalse(WindowPolicy.isDuplicate(url, last: (url, now), now: now.addingTimeInterval(5)), "the person clicked it again later")
        XCTAssertFalse(WindowPolicy.isDuplicate(URL(string: "https://example.com")!, last: (url, now), now: now.addingTimeInterval(0.1)), "a different link")
    }

    @MainActor
    func testRegistryActsOnALinkOnceInAWindow() {
        let registry = WindowRegistry()
        let url = URL(string: "https://example.com/a")!
        XCTAssertTrue(registry.acceptExternal(url, now: now))
        XCTAssertFalse(registry.acceptExternal(url, now: now.addingTimeInterval(0.5)))
        XCTAssertTrue(registry.acceptExternal(url, now: now.addingTimeInterval(3)))
    }

    func testRestoredWindowsAreSafeToOpen() {
        let stored: [[UInt64]] = [[1, 2], [], [2, 3], [3], [4], [5], [6], [7], [8], [9], [10], [11]]
        let out = WindowPolicy.restorable(stored)
        XCTAssertEqual(out.first, [1, 2])
        XCTAssertEqual(out[1], [3], "tab 2 is already in the first window")
        XCTAssertFalse(out.contains([]), "no empty window")
        XCTAssertLessThanOrEqual(out.count, WindowPolicy.restoreCap)
        XCTAssertEqual(Set(out.flatMap { $0 }).count, out.flatMap { $0 }.count, "no tab in two windows")
        XCTAssertTrue(WindowPolicy.restorable([]).isEmpty)
    }

    func testALinkFromAnotherAppGoesToTheWindowInFront() {
        typealias C = WindowPolicy.Candidate
        let primary = C(id: 0, isGuest: false, isUnrequested: false, isFocused: false, isPrimary: true)
        let front = C(id: 1, isGuest: false, isUnrequested: false, isFocused: true, isPrimary: false)
        let stray = C(id: 2, isGuest: false, isUnrequested: true, isFocused: true, isPrimary: false)
        let guest = C(id: 3, isGuest: true, isUnrequested: false, isFocused: true, isPrimary: false)
        XCTAssertEqual(WindowPolicy.externalTarget(among: [primary, front]), 1, "the window in front")
        XCTAssertEqual(WindowPolicy.externalTarget(among: [primary, front, stray]), 1, "never the stray window the system just made")
        XCTAssertEqual(WindowPolicy.externalTarget(among: [primary, guest]), 0, "never a guest window")
        XCTAssertEqual(WindowPolicy.externalTarget(among: [primary]), 0)
        XCTAssertNil(WindowPolicy.externalTarget(among: [stray]), "a stray window is the only one: nothing to hand it to")
        XCTAssertNil(WindowPolicy.externalTarget(among: []))
        let backgroundOnly = C(id: 5, isGuest: false, isUnrequested: false, isFocused: false, isPrimary: false)
        XCTAssertEqual(WindowPolicy.externalTarget(among: [backgroundOnly, primary]), 0, "no window in front: the first window")
    }
}
