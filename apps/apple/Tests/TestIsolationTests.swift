import XCTest
@testable import Browser_Setu

/// The rule that keeps every test process away from the person's own home (and so from their web data). Made-up paths only: nothing here reads or writes a real store.
final class TestIsolationTests: XCTestCase {
    private let real = "/Users/someone-made-up"
    private let target = "/private/tmp/made-up-test-home"

    private func decide(_ environment: [String: String] = [:], _ arguments: [String] = ["Browser Setu"]) -> TestIsolation.HomeDecision {
        TestIsolation.homeDecision(environment: environment, arguments: arguments, realHome: real, relocatedHome: target)
    }

    func testANormalLaunchIsLeftAlone() {
        XCTAssertEqual(decide(), .notATestProcess)
        XCTAssertEqual(decide(["CFFIXED_USER_HOME": real]), .notATestProcess, "not a test process: the installed app is never relocated")
        XCTAssertEqual(decide([:], ["Browser Setu", "-UITestRoot", ""]), .notATestProcess, "an empty root is not a test launch")
    }

    func testAUITestLaunchWithoutARelocatedHomeIsRestarted() {
        let args = ["Browser Setu", "-UITestRoot", "bs-perf-1", "-UIState", "none"]
        XCTAssertEqual(decide([:], args), .relocate(to: target))
        XCTAssertEqual(decide(["CFFIXED_USER_HOME": ""], args), .relocate(to: target))
        XCTAssertEqual(decide(["CFFIXED_USER_HOME": real], args), .relocate(to: target), "pointing at the real home is the same as not relocating")
        XCTAssertEqual(decide(["CFFIXED_USER_HOME": real + "/"], args), .relocate(to: target), "a trailing slash does not hide the real home")
    }

    func testAnAppHostedUnitTestRunWithoutARelocatedHomeIsRestarted() {
        XCTAssertEqual(decide(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]), .relocate(to: target))
        XCTAssertEqual(decide(["XCTestBundlePath": "/tmp/x.xctest", "CFFIXED_USER_HOME": real]), .relocate(to: target))
    }

    func testAnAlreadyRelocatedTestProcessIsNotRestartedAgain() {
        let args = ["Browser Setu", "-UITestRoot", "bs-perf-1"]
        XCTAssertEqual(decide(["CFFIXED_USER_HOME": target], args), .alreadyRelocated)
        XCTAssertEqual(decide(["XCTestConfigurationFilePath": "/tmp/x", "CFFIXED_USER_HOME": "/var/folders/zz/T/bs-ui-home"]), .alreadyRelocated)
    }

    /// This very process (an app-hosted unit-test run) must not have the person's home: the guard restarted it, or the launcher set a home.
    func testThisTestProcessDoesNotHaveThePersonsHome() {
        #if DEBUG
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
        XCTAssertFalse(home.isEmpty, "a unit-test run without a relocated home")
        XCTAssertNotEqual((home as NSString).standardizingPath, (TestIsolation.realHome as NSString).standardizingPath)
        XCTAssertNotEqual(NSHomeDirectory(), TestIsolation.realHome, "NSHomeDirectory() is the person's own home")
        #endif
    }

    /// A window in a test process cannot be given an autosave name, so AppKit never saves its frame into the person's preferences (nothing is saved here: only the name is checked).
    func testAWindowCannotBeGivenAnAutosaveNameInATestProcess() {
        #if DEBUG
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        _ = window.setFrameAutosaveName("bs-synthetic-never-saved")
        XCTAssertEqual(window.frameAutosaveName, "", "a test process let a window take an autosave name")
        #endif
    }

    // MARK: Website data store identity (Section 26)

    private let storeFakeHome = "/Users/someone"
    private let tmp = "/private/var/folders/xx/T/"
    private func decide(_ profile: String = "default", env: [String: String] = [:], args: [String] = [], token: String = "tok") -> ProfileIdentity.StoreDecision {
        ProfileIdentity.storeDecision(profile: profile, environment: env, arguments: args, realHome: storeFakeHome, temporaryDirectory: tmp, processToken: token)
    }

    func testAProductionProcessGetsTheUnchangedProductionIdentity() {
        XCTAssertEqual(decide("Work"), .production(ProfileIdentity.dataStoreID(for: "Work")))
        XCTAssertEqual(decide("default"), .production(ProfileIdentity.dataStoreID(for: "default")))
    }

    func testProductionIdentitiesAreFixedValues() {
        // These name people's existing website data and must never change. The values come from the formula (SHA-256 of "browsersetu.profile.<name>", version and variant bits set) computed outside Swift.
        XCTAssertEqual(ProfileIdentity.dataStoreID(for: "default").uuidString, "8511FA7F-298B-5976-8F7B-B55B798BF470")
        XCTAssertEqual(ProfileIdentity.dataStoreID(for: "Work").uuidString, "B3AA4074-E39E-54B4-BC74-708D4FC02643")
    }

    func testATestProcessNeverGetsAProductionIdentity() {
        let env = ["CFFIXED_USER_HOME": "/private/var/folders/xx/T/bs-ui-home"]
        guard case .test(let id) = decide("default", env: env, args: ["-UITestRoot", "bs-perf-1"]) else { return XCTFail("not a test identity") }
        XCTAssertNotEqual(id, ProfileIdentity.dataStoreID(for: "default"))
        guard case .test(let host) = decide("default", env: ["XCTestConfigurationFilePath": "/x", "CFFIXED_USER_HOME": "/tmp/h"]) else { return XCTFail("not a test identity") }
        XCTAssertNotEqual(host, ProfileIdentity.dataStoreID(for: "default"))
    }

    func testTheTestIdentityFollowsTheRootAndTheProfile() {
        let env = ["CFFIXED_USER_HOME": "/tmp/h"]
        let a = decide("default", env: env, args: ["-UITestRoot", "root-a"]), b = decide("default", env: env, args: ["-UITestRoot", "root-b"])
        XCTAssertNotEqual(a, b, "two roots shared one store")
        XCTAssertEqual(a, decide("default", env: env, args: ["-UITestRoot", "root-a"]), "the identity is not deterministic")
        XCTAssertNotEqual(a, decide("Work", env: env, args: ["-UITestRoot", "root-a"]), "two profiles shared one store")
        XCTAssertEqual(decide("default", env: env, args: ["-UITestRoot", tmp + "root-a"]), a, "a relative and an absolute spelling of one root differ")
    }

    func testATestProcessWithThePersonsHomeIsRefused() {
        guard case .refused = decide(args: ["-UITestRoot", "r"]) else { return XCTFail("a test process with the person's home got a store") }
        guard case .refused = decide(env: ["XCTestConfigurationFilePath": "/x", "CFFIXED_USER_HOME": storeFakeHome]) else { return XCTFail("a unit-test host with the person's home got a store") }
    }

    func testAnEmptyOrForeignTestRootIsRefused() {
        let env = ["CFFIXED_USER_HOME": "/tmp/h"]
        guard case .refused = decide(env: env, args: ["-UITestRoot", ""]) else { return XCTFail("an empty root was accepted") }
        guard case .refused = decide(env: env, args: ["-UITestRoot", "/Users/someone/Library/Application Support/BrowserSetu"]) else { return XCTFail("a root outside the temporary folders was accepted") }
        guard case .refused = decide(env: ["XCTestConfigurationFilePath": "/x", "CFFIXED_USER_HOME": "/tmp/h"], token: "") else { return XCTFail("a unit-test host without a namespace was accepted") }
    }

    func testThisTestProcessIsRecognizedAndHasATestIdentity() {
        XCTAssertTrue(TestIsolation.isTestProcess, "the unit-test host must count as a test process")
        let id = ProfileIdentity.storeID(for: "default")
        XCTAssertNotNil(id, "the unit-test host has no safe store identity (is its home relocated?)")
        XCTAssertNotEqual(id, ProfileIdentity.dataStoreID(for: "default"), "this test process would open the production default store")
    }
}
