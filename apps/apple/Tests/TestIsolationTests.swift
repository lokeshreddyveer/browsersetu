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

    // MARK: Preferences (Stage 3 closure)

    /// What the person's own preferences file for this app looks like now (read only: whether it exists, its size, date and bytes). `cfprefsd` keeps it under the real home whatever the relocated home is.
    private struct PreferencesFileState: Equatable { let exists: Bool; let size: Int; let modified: Date?; let bytes: Data? }
    private func realPreferencesState(_ domain: String = "com.browsersetu.mac") -> PreferencesFileState {
        let path = TestIsolation.realHome + "/Library/Preferences/\(domain).plist"
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return PreferencesFileState(exists: attributes != nil, size: (attributes?[.size] as? Int) ?? 0, modified: attributes?[.modificationDate] as? Date,
                                    bytes: FileManager.default.contents(atPath: path))
    }

    /// The standard defaults of this test process are the in-memory store, installed before anything else ran.
    func testThisTestProcessHasInMemoryStandardDefaults() {
        #if DEBUG
        XCTAssertTrue(TestPreferencesGuard.installed)
        XCTAssertTrue(UserDefaults.standard is TestProcessDefaults, "a test process writes the person's own preferences")
        XCTAssertTrue(UserDefaults.standard === UserDefaults.standard)
        #endif
    }

    /// The writes `removeProfile` and the rest of the app make (set, typed set, removing a present key, removing a key that was never there, synchronizing) leave the person's own preferences file
    /// exactly as it was: not created, not changed. Removing an absent key is the call that used to create an empty file there.
    func testWritingAndRemovingStandardDefaultsLeavesThePersonsPreferencesUntouched() {
        #if DEBUG
        let before = realPreferencesState()
        let defaults = UserDefaults.standard
        let key = "bs.test.isolation.\(UUID().uuidString)"
        defaults.set("value", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "value")
        defaults.set(true, forKey: key + ".bool"); defaults.set(7, forKey: key + ".int"); defaults.set(2.5, forKey: key + ".double")
        XCTAssertTrue(defaults.bool(forKey: key + ".bool")); XCTAssertEqual(defaults.integer(forKey: key + ".int"), 7); XCTAssertEqual(defaults.double(forKey: key + ".double"), 2.5)
        defaults.set(["a", "b"], forKey: key + ".list"); XCTAssertEqual(defaults.stringArray(forKey: key + ".list"), ["a", "b"])
        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.object(forKey: key))
        defaults.removeObject(forKey: "bs.tiktok.export.never-existed-\(UUID().uuidString)")
        for k in [".bool", ".int", ".double", ".list"] { defaults.removeObject(forKey: key + k) }
        _ = defaults.synchronize()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))      // cfprefsd writes after the call returns; give it the time it took before the guard
        XCTAssertEqual(realPreferencesState(), before, "a test process created or changed the person's own preferences file")
        #endif
    }

    /// Removing a value shows the registered default again, and observers still hear every change (SwiftUI's `@AppStorage` and `didChangeNotification` listeners depend on that).
    func testInMemoryDefaultsKeepRegisteredValuesAndChangeNotices() {
        #if DEBUG
        let defaults = UserDefaults.standard
        let key = "bs.test.isolation.registered.\(UUID().uuidString)"
        defaults.register(defaults: [key: "registered"])
        XCTAssertEqual(defaults.string(forKey: key), "registered")
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        final class Watcher: NSObject { var seen = 0; override func observeValue(forKeyPath _: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) { seen += 1 } }
        let watcher = Watcher()
        defaults.addObserver(watcher, forKeyPath: key, options: [.new], context: nil)
        defer { defaults.removeObserver(watcher, forKeyPath: key) }
        defaults.set("written", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "written")
        defaults.removeObject(forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "registered")
        XCTAssertEqual(notices, 2)
        XCTAssertEqual(watcher.seen, 2)
        #endif
    }
}

