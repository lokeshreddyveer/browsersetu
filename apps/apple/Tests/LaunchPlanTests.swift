import XCTest
@testable import Browser_Setu

final class LaunchPlanTests: XCTestCase {
    private func plan(setupDone: Bool, seen: String?, current: String = "0.4.1 (24)", forced: Bool = false, skip: Bool = false, scripted: Bool = false, secondary: Bool = false) -> LaunchPlan {
        LaunchPlan.decide(setupDone: setupDone, seenVersion: seen, current: current, forced: forced, skipFilm: skip, scripted: scripted, secondaryWindow: secondary)
    }
    func testBrandNewInstallGetsFilmAndSetup() { XCTAssertEqual(plan(setupDone: false, seen: nil), .newInstall) }
    func testUpdateFromAnOlderBuildGetsFilmAndWhatsNewNotSetup() {
        XCTAssertEqual(plan(setupDone: true, seen: nil), .update)                       // 0.4.0 never recorded a version
        XCTAssertEqual(plan(setupDone: true, seen: "0.4.0 (23)"), .update)
        XCTAssertEqual(plan(setupDone: true, seen: "0.4.1 (23)"), .update)              // a new build is an update too
    }
    func testNothingAfterTheNewsWasSeen() { XCTAssertEqual(plan(setupDone: true, seen: "0.4.1 (24)"), .none) }
    func testNeverInTestsSecondaryWindowsOrWhenAsked() {
        XCTAssertEqual(plan(setupDone: true, seen: nil, scripted: true), .none)
        XCTAssertEqual(plan(setupDone: true, seen: nil, secondary: true), .none)
        XCTAssertEqual(plan(setupDone: true, seen: nil, skip: true), .none)
        XCTAssertEqual(plan(setupDone: true, seen: nil, forced: true), .none)
    }
    func testAProfileThatSawTheFilmIsAnExistingInstall() {
        XCTAssertTrue(LaunchPlan.established(setupDone: false, introDone: true))
        XCTAssertTrue(LaunchPlan.established(setupDone: true, introDone: false))
        XCTAssertFalse(LaunchPlan.established(setupDone: false, introDone: false))
        XCTAssertEqual(plan(setupDone: LaunchPlan.established(setupDone: false, introDone: true), seen: nil), .update)
    }
    func testWhatsNewListIsNotEmpty() { XCTAssertFalse(WhatsNewContent.items.isEmpty); XCTAssertTrue(WhatsNewContent.title.contains("0.4.1")) }
}
