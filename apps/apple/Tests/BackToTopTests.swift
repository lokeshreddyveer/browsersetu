import XCTest
@testable import Browser_Setu

/// The way-back-to-the-top pill is offered only to someone far down a page who is moving back up, stays a few seconds, comes back later, and stops asking.
final class BackToTopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNotOfferedNearTheTopOrWhileGoingDown() {
        var r = BackToTopRules()
        XCTAssertEqual(r.scrolled(deltaY: 200, screens: 1.0, now: at(0)), .none, "not far enough down")
        XCTAssertEqual(r.scrolled(deltaY: -300, screens: 5, now: at(1)), .none, "still going down")
    }

    func testOfferedWhenFarDownAndMovingBackUp() {
        var r = BackToTopRules()
        XCTAssertEqual(r.scrolled(deltaY: 60, screens: 4, now: at(0)), .none, "a short move is not enough")
        XCTAssertEqual(r.scrolled(deltaY: 80, screens: 4, now: at(0.2)), .show, "120 points back up, four screens down")
        XCTAssertTrue(r.isShown)
    }

    func testItGoesAfterFiveSecondsAndNotBefore() {
        var r = BackToTopRules()
        _ = r.scrolled(deltaY: 150, screens: 4, now: at(0))
        XCTAssertEqual(r.tick(now: at(4.9)), .none)
        XCTAssertEqual(r.tick(now: at(5.0)), .hide)
        XCTAssertFalse(r.isShown)
    }

    func testMovingUpKeepsItALittleLongerAndGoingDownRemovesIt() {
        var r = BackToTopRules()
        _ = r.scrolled(deltaY: 150, screens: 4, now: at(0))
        _ = r.scrolled(deltaY: 40, screens: 3.9, now: at(4))
        XCTAssertEqual(r.tick(now: at(6)), .none, "the clock started again at 4 s")
        XCTAssertEqual(r.scrolled(deltaY: -80, screens: 4.5, now: at(6.5)), .hide, "they went back down")
    }

    func testItComesBackOnlyAfterTheCooldownAndAFreshUpwardRun() {
        var r = BackToTopRules()
        _ = r.scrolled(deltaY: 150, screens: 4, now: at(0))
        _ = r.tick(now: at(5))
        XCTAssertEqual(r.scrolled(deltaY: 200, screens: 4, now: at(10)), .none, "inside the cooldown")
        XCTAssertEqual(r.scrolled(deltaY: 200, screens: 4, now: at(36)), .show, "after 30 s, moving up again")
    }

    func testItStopsAskingAfterThreeOffersOnAPageAndStartsAgainAtTheTop() {
        var r = BackToTopRules()
        var clock = 0.0
        for _ in 0..<3 {
            XCTAssertEqual(r.scrolled(deltaY: 200, screens: 4, now: at(clock)), .show)
            _ = r.tick(now: at(clock + 5)); clock += 40
        }
        XCTAssertEqual(r.scrolled(deltaY: 200, screens: 4, now: at(clock)), .none, "three is the most")
        _ = r.scrolled(deltaY: 100, screens: 0.2, now: at(clock + 1))   // back at the top
        XCTAssertEqual(r.scrolled(deltaY: 200, screens: 4, now: at(clock + 2)), .show, "a new trip down starts again")
    }

    func testUsingItEndsTheOffersForThatPage() {
        var r = BackToTopRules()
        _ = r.scrolled(deltaY: 150, screens: 4, now: at(0))
        r.used(now: at(1))
        XCTAssertFalse(r.isShown)
        XCTAssertEqual(r.scrolled(deltaY: 300, screens: 4, now: at(100)), .none)
    }

    func testANewPageStartsAgain() {
        var r = BackToTopRules()
        _ = r.scrolled(deltaY: 150, screens: 4, now: at(0))
        r.reset()
        XCTAssertFalse(r.isShown)
        XCTAssertEqual(r.offers, 0)
    }
}
