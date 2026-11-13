import XCTest
@testable import SetuPrivacyCore
import SetuPrivacyWebKit
import WebKit

@MainActor
final class WebKitCompileTests: XCTestCase {
    /// A rule store in a folder of this test's own, so the tests never depend on (or write to) the user's default store.
    @MainActor private static func isolatedStore() -> WKContentRuleListStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder) ?? .default()
    }

    private static func isolatedDefaults() -> UserDefaults? { nil }                 // nothing is written to the person's preferences

    func testWebKitAcceptsEveryProtectionLevel() async throws {
        let installer = ContentRuleInstaller(store: Self.isolatedStore(), defaults: Self.isolatedDefaults())
        var config = PrivacyConfiguration()
        try config.addSiteException("shop.example")
        try config.addUserRule(domain: "blocked.example", action: .block)
        for mode in ProtectionMode.allCases {
            config.mode = mode
            config.customThirdPartyCookies = true; config.customTrackingEndpoints = true; config.customSessionRecordingHosts = true
            let snapshot = try XCTUnwrap(PolicyBuilder.build(configuration: config))
            let report = await installer.apply(snapshot)
            XCTAssertTrue(report.installed, "\(mode): \(report.error ?? "")")
            XCTAssertNil(report.error)
        }
    }

    func testIdenticalSnapshotReusesCompiledListAndInvalidRulesKeepThePreviousOne() async throws {
        let installer = ContentRuleInstaller(store: Self.isolatedStore(), defaults: Self.isolatedDefaults())
        let snapshot = try XCTUnwrap(PolicyBuilder.build(configuration: PrivacyConfiguration()))
        let first = await installer.apply(snapshot)
        XCTAssertTrue(first.installed)
        let again = await installer.apply(snapshot)
        XCTAssertTrue(again.reusedCompiledList, "same hash must not recompile")
        let goodID = installer.activeIdentifier

        let broken = PolicySnapshot(rulesJSON: Data("[{\"trigger\":{\"url-filter\":\"(\"},\"action\":{\"type\":\"block\"}}]".utf8), additionalRulesJSON: [],
                                    identifier: "setu-broken-test", domainBlockRules: 1, urlBlockRules: 0, elementHidingRules: 0, userRules: 0,
                                    siteExceptions: 0, droppedForBudget: 0, unsupportedRules: 0, importantRules: 0, diagnostics: [], scriptRules: ScriptRuleSet(), scriptIdentifier: "",
                                    failedLists: [:], listNames: [], strictExtras: [])
        let failed = await installer.apply(broken)
        XCTAssertNotNil(failed.error, "WebKit must reject the malformed rule")
        XCTAssertTrue(failed.installed, "previous valid rules stay installed")
        XCTAssertEqual(installer.activeIdentifier, goodID)
        XCTAssertEqual(failed.identifier, goodID)
    }

    /// The app applies a light list at start and the full one right after. A relaunch (a new installer on the same store) must find BOTH already compiled: pruning at the first apply must not delete the
    /// list the second apply needs (it used to, so the full list was compiled again on every launch).
    func testRelaunchDoesNotPruneTheListTheNextApplyNeeds() async throws {
        let store = Self.isolatedStore()
        let suiteName = "bs.rules.relaunch.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        var light = PrivacyConfiguration(); light.mode = .light
        var full = PrivacyConfiguration(); full.mode = .strict
        let lightSnapshot = try XCTUnwrap(PolicyBuilder.build(configuration: light)), fullSnapshot = try XCTUnwrap(PolicyBuilder.build(configuration: full))
        XCTAssertNotEqual(lightSnapshot.identifier, fullSnapshot.identifier)

        let first = ContentRuleInstaller(store: store, defaults: suite)
        _ = await first.apply(lightSnapshot); _ = await first.apply(fullSnapshot)

        let relaunched = ContentRuleInstaller(store: store, defaults: suite)          // a new process: nothing in memory
        let again1 = await relaunched.apply(lightSnapshot)
        let again2 = await relaunched.apply(fullSnapshot)
        XCTAssertTrue(again1.reusedCompiledList, "the light list is found compiled after a relaunch")
        XCTAssertTrue(again2.reusedCompiledList, "the full list must still be compiled after the light list's apply pruned the cache")
    }

    func testNewTabsInheritProtectionAndRemovalDetaches() async throws {
        let installer = ContentRuleInstaller(store: Self.isolatedStore(), defaults: Self.isolatedDefaults())
        let snapshot = try XCTUnwrap(PolicyBuilder.build(configuration: PrivacyConfiguration()))
        _ = await installer.apply(snapshot)
        let early = WKUserContentController()
        installer.register(early)
        XCTAssertEqual(installer.attachedCount, 1)
        var strict = PrivacyConfiguration(); strict.mode = .strict
        let report = await installer.apply(try XCTUnwrap(PolicyBuilder.build(configuration: strict)))
        XCTAssertTrue(report.installed)
        XCTAssertEqual(report.attachedWebViews, 1, "update reaches existing tabs without recreating them")
        let late = WKUserContentController()
        installer.register(late)
        XCTAssertEqual(installer.attachedCount, 2)
        let removed = await installer.apply(nil)
        XCTAssertTrue(removed.removed)
        XCTAssertNil(installer.activeIdentifier)
    }
}
