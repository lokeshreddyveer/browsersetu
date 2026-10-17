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

    func testWebKitAcceptsEveryProtectionLevel() async throws {
        let installer = ContentRuleInstaller(store: Self.isolatedStore())
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
        let installer = ContentRuleInstaller(store: Self.isolatedStore())
        let snapshot = try XCTUnwrap(PolicyBuilder.build(configuration: PrivacyConfiguration()))
        let first = await installer.apply(snapshot)
        XCTAssertTrue(first.installed)
        let again = await installer.apply(snapshot)
        XCTAssertTrue(again.reusedCompiledList, "same hash must not recompile")
        let goodID = installer.activeIdentifier

        let broken = PolicySnapshot(rulesJSON: Data("[{\"trigger\":{\"url-filter\":\"(\"},\"action\":{\"type\":\"block\"}}]".utf8), additionalRulesJSON: [],
                                    identifier: "setu-broken-test", domainBlockRules: 1, urlBlockRules: 0, elementHidingRules: 0, userRules: 0,
                                    siteExceptions: 0, droppedForBudget: 0, unsupportedRules: 0, failedLists: [:], listNames: [], strictExtras: [])
        let failed = await installer.apply(broken)
        XCTAssertNotNil(failed.error, "WebKit must reject the malformed rule")
        XCTAssertTrue(failed.installed, "previous valid rules stay installed")
        XCTAssertEqual(installer.activeIdentifier, goodID)
        XCTAssertEqual(failed.identifier, goodID)
    }

    func testNewTabsInheritProtectionAndRemovalDetaches() async throws {
        let installer = ContentRuleInstaller(store: Self.isolatedStore())
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
