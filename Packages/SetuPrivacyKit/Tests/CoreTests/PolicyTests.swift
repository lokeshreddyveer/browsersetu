import XCTest
@testable import SetuPrivacyCore
import SetuPrivacyWebKit
import WebKit

final class PolicyTests: XCTestCase {
    private func rules(_ snapshot: PolicySnapshot) throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: snapshot.rulesJSON) as! [[String: Any]]
    }
    private func filters(_ snapshot: PolicySnapshot) throws -> [String] {
        try rules(snapshot).compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    }
    private func actionTypes(_ snapshot: PolicySnapshot) throws -> [String] {
        try rules(snapshot).compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
    }

    // MARK: Modes and toggles

    func testDefaultsAreBalancedAndBothProtectionsOn() {
        let config = PrivacyConfiguration()
        XCTAssertEqual(config.mode, .balanced)
        XCTAssertTrue(config.adBlocking && config.antiTracking && config.isEnabled)
        let snapshot = PolicyBuilder.build(configuration: config)!
        XCTAssertGreaterThan(snapshot.domainBlockRules, 30)
        XCTAssertTrue(snapshot.strictExtras.isEmpty, "Balanced must not claim strict-only protections")
        XCTAssertFalse(try actionTypes(snapshot).contains("block-cookies"))
    }

    func testBothTogglesOffMeansNoRulesAtAll() {
        var config = PrivacyConfiguration()
        config.adBlocking = false
        config.antiTracking = false
        XCTAssertNil(PolicyBuilder.build(configuration: config))
    }

    func testAdsAndTrackingTogglesSelectTheirOwnLists() throws {
        var config = PrivacyConfiguration()
        config.antiTracking = false
        let adsOnly = PolicyBuilder.build(configuration: config)!
        XCTAssertTrue(try filters(adsOnly).contains { $0.contains("doubleclick") })
        XCTAssertFalse(try filters(adsOnly).contains { $0.contains("google-analytics") })
        config.antiTracking = true; config.adBlocking = false
        let trackingOnly = PolicyBuilder.build(configuration: config)!
        XCTAssertTrue(try filters(trackingOnly).contains { $0.contains("google-analytics") })
        XCTAssertFalse(try filters(trackingOnly).contains { $0.contains("doubleclick") })
    }

    func testStrictInstallsExtraProtectionsAndBalancedDoesNot() throws {
        var config = PrivacyConfiguration()
        let standard = PolicyBuilder.build(configuration: config)!
        config.mode = .strict
        let strict = PolicyBuilder.build(configuration: config)!
        XCTAssertGreaterThan(strict.domainBlockRules, standard.domainBlockRules, "strict adds session-recording hosts")
        XCTAssertEqual(strict.strictExtras.count, 2)
        XCTAssertTrue(try actionTypes(strict).contains("block-cookies"))
        XCTAssertTrue(try filters(strict).contains { $0.contains("fullstory") })
        XCTAssertNotEqual(strict.identifier, standard.identifier)
    }

    func testCustomModeHonoursExplicitControlsOnly() throws {
        var config = PrivacyConfiguration()
        config.mode = .custom
        XCTAssertTrue(PolicyBuilder.build(configuration: config)!.strictExtras.isEmpty)
        config.customThirdPartyCookies = true
        XCTAssertEqual(PolicyBuilder.build(configuration: config)!.strictExtras, ["Third-party cookie blocking"])
    }

    func testLightIsAdsOnlyAndSmallerThanBalanced() throws {
        var config = PrivacyConfiguration()
        config.mode = .light
        let light = PolicyBuilder.build(configuration: config)!
        config.mode = .balanced
        let balanced = PolicyBuilder.build(configuration: config)!
        XCTAssertTrue(try filters(light).contains { $0.contains("doubleclick") }, "Light still blocks ad hosts")
        XCTAssertFalse(try filters(light).contains { $0.contains("google-analytics") }, "Light does not install the tracker list")
        XCTAssertFalse(try filters(light).contains { $0.contains("fullstory") })
        XCTAssertTrue(light.strictExtras.isEmpty)
        XCTAssertLessThan(light.totalRules, balanced.totalRules)
        XCTAssertEqual(Set(ProtectionMode.levels), [.light, .balanced, .strict])
    }

    func testEarlierSavedStandardModeLoadsAsBalanced() {
        let json = PrivacyConfiguration().encoded().replacingOccurrences(of: "\"balanced\"", with: "\"standard\"")
        XCTAssertTrue(json.contains("standard"))
        let decoded = PrivacyConfiguration.decode(json)
        XCTAssertEqual(decoded.configuration.mode, .balanced)
        XCTAssertFalse(decoded.wasRepaired)
        let unknown = PrivacyConfiguration.decode(PrivacyConfiguration().encoded().replacingOccurrences(of: "\"balanced\"", with: "\"turbo\""))
        XCTAssertEqual(unknown.configuration.mode, .balanced, "an unknown mode falls back to the default, never to something stronger or weaker")
    }

    // MARK: Precedence

    func testOutputOrderIsListsThenExceptionsThenUserRules() throws {
        var config = PrivacyConfiguration()
        try config.addSiteException("news.example")
        try config.addUserRule(domain: "ads.example", action: .block)
        let snapshot = PolicyBuilder.build(configuration: config)!
        let list = try rules(snapshot)
        let exceptionIndex = list.firstIndex { ($0["trigger"] as? [String: Any])?["if-domain"] != nil }!
        let userIndex = list.firstIndex { (($0["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("ads\\.example") == true }!
        let listIndex = list.firstIndex { (($0["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("doubleclick") == true }!
        XCTAssertLessThan(listIndex, exceptionIndex, "list rules come before exceptions")
        XCTAssertLessThan(exceptionIndex, userIndex, "user rules come after exceptions so they outrank them")
    }

    func testUserRulesAreSpecificityOrdered() throws {
        var config = PrivacyConfiguration()
        try config.addUserRule(domain: "cdn.example.com", action: .allow)
        try config.addUserRule(domain: "example.com", action: .block)
        let snapshot = PolicyBuilder.build(configuration: config)!
        let userTail = try rules(snapshot).suffix(2)
        let types = userTail.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types, ["block", "ignore-previous-rules"], "the more specific allow comes last and wins")
    }

    // MARK: Validation

    func testMalformedDomainsAreRejected() {
        var config = PrivacyConfiguration()
        for bad in ["", "localhost", "example", "192.168.1.1", "ex ample.com", "example.com/path", "*.example.com", "a@b.com", "com", "co.uk"] {
            XCTAssertThrowsError(try config.addUserRule(domain: bad, action: .block), bad)
            XCTAssertThrowsError(try config.addSiteException(bad), bad)
        }
        XCTAssertTrue(config.userRules.isEmpty && config.siteExceptions.isEmpty)
    }

    func testDuplicatesAndLimitsAreEnforced() throws {
        var config = PrivacyConfiguration()
        try config.addSiteException("example.com")
        XCTAssertThrowsError(try config.addSiteException("EXAMPLE.com")) { XCTAssertEqual($0 as? PrivacyConfiguration.ConfigurationError, .duplicate) }
        XCTAssertThrowsError(try config.setList("http://insecure.example/list.txt", enabled: true))
        XCTAssertThrowsError(try config.setList("not a url", enabled: true))
    }

    func testDomainAndSubdomainMatching() throws {
        var config = PrivacyConfiguration()
        try config.addSiteException("example.com")
        XCTAssertTrue(config.isException(host: "example.com"))
        XCTAssertTrue(config.isException(host: "WWW.Example.com"))
        XCTAssertFalse(config.isException(host: "notexample.com"))
        XCTAssertFalse(config.isException(host: "example.com.evil.net"))
        XCTAssertFalse(config.isException(host: nil))
    }

    func testCorruptNewerOrOversizedConfigurationFallsBackToDefaults() {
        XCTAssertTrue(PrivacyConfiguration.decode("{not json").wasRepaired)
        XCTAssertEqual(PrivacyConfiguration.decode("{not json").configuration, PrivacyConfiguration())
        var future = PrivacyConfiguration(); future.version = 99
        XCTAssertTrue(PrivacyConfiguration.decode(future.encoded()).wasRepaired)
        XCTAssertTrue(PrivacyConfiguration.decode(String(repeating: "x", count: 5_000_000)).wasRepaired)
        XCTAssertFalse(PrivacyConfiguration.decode(nil).wasRepaired)
    }

    func testEntriesThatFailValidationAreDroppedOnLoad() throws {
        var config = PrivacyConfiguration()
        try config.addSiteException("good.example")
        var json = config.encoded()
        json = json.replacingOccurrences(of: "\"siteExceptions\":[\"good.example\"]", with: "\"siteExceptions\":[\"good.example\",\"bad host\",\"localhost\"]")
        let decoded = PrivacyConfiguration.decode(json)
        XCTAssertEqual(decoded.configuration.siteExceptions, ["good.example"])
        XCTAssertTrue(decoded.wasRepaired)
    }

    func testConfigurationRoundTrips() throws {
        var config = PrivacyConfiguration()
        config.mode = .strict; config.customThirdPartyCookies = true; config.automaticUpdates = true
        try config.addUserRule(domain: "tracker.example", action: .block)
        try config.addSiteException("shop.example")
        try config.setList(FilterCatalog.all[0].url, enabled: true)
        XCTAssertEqual(PrivacyConfiguration.decode(config.encoded()).configuration, config)
    }

    // MARK: Lists and unsupported syntax

    func testUnsupportedSyntaxIsCountedNotApproximated() throws {
        var config = PrivacyConfiguration()
        config.mode = .custom
        let url = FilterCatalog.all.first { $0.url.contains("easylist.to/easylist/easylist.txt") }!.url
        try config.setList(url, enabled: true)
        let text = """
        ! comment
        ||ads.example.org/banner/*$image,third-party
        example.org##.sponsored
        example.org#?#div:-abp-has(.x)
        /regex-rule/
        ||tracker.example.net^$redirect=1x1.gif
        ||plain-ads.example.net^
        """
        let snapshot = PolicyBuilder.build(configuration: config, downloaded: [url: Data(text.utf8)])!
        XCTAssertEqual(snapshot.urlBlockRules, 1)
        XCTAssertEqual(snapshot.elementHidingRules, 1)
        XCTAssertGreaterThanOrEqual(snapshot.unsupportedRules, 3)
        XCTAssertFalse(try filters(snapshot).contains { $0.contains("regex-rule") }, "regex rules must not be approximated")
        XCTAssertFalse(try filters(snapshot).contains { $0.contains("tracker\\.example\\.net") }, "redirect rules must not become plain blocks")
    }

    func testMissingOrOversizedDownloadedListsAreReportedAndPartial() throws {
        var config = PrivacyConfiguration()
        config.mode = .custom
        let a = FilterCatalog.all[0].url, b = FilterCatalog.all[1].url
        try config.setList(a, enabled: true); try config.setList(b, enabled: true)
        let big = Data(repeating: 0x61, count: PolicyBuilder.byteLimit + 1)
        let snapshot = PolicyBuilder.build(configuration: config, downloaded: [b: big])!
        XCTAssertEqual(snapshot.failedLists.count, 2)
        let state = ProtectionEvaluator.state(configuration: config, snapshot: snapshot,
                                              install: InstallReport(installed: true, identifier: snapshot.identifier), updating: false, host: nil)
        guard case .partial = state else { return XCTFail("expected partial, got \(state)") }
        XCTAssertFalse(state.isProtected)
    }

    func testListsAreIgnoredOutsideCustomMode() throws {
        var config = PrivacyConfiguration()
        let url = FilterCatalog.all[0].url
        try config.setList(url, enabled: true)
        let snapshot = PolicyBuilder.build(configuration: config, downloaded: [url: Data("only-in-list.example\n".utf8)])!
        XCTAssertFalse(try filters(snapshot).contains { $0.contains("only-in-list") })
    }

    // MARK: Honest state

    func testProtectedHeadlineAppearsOnlyWhenInstalledAndComplete() throws {
        let config = PrivacyConfiguration()
        let snapshot = PolicyBuilder.build(configuration: config)!
        func state(_ install: InstallReport?, updating: Bool = false, host: String? = nil, config: PrivacyConfiguration = config) -> ProtectionState {
            ProtectionEvaluator.state(configuration: config, snapshot: snapshot, install: install, updating: updating, host: host)
        }
        XCTAssertEqual(state(nil).statusWord, "Unavailable", "enabled in settings but nothing installed must not read as protected")
        XCTAssertFalse(state(nil).isProtected)
        XCTAssertFalse(state(InstallReport(installed: false, identifier: nil, error: "boom")).isProtected)
        XCTAssertEqual(state(InstallReport(installed: true, identifier: "stale-id")).statusWord, "Partial")
        let ok = InstallReport(installed: true, identifier: snapshot.identifier)
        XCTAssertEqual(state(ok), .active)
        XCTAssertEqual(state(ok).headline, "Protected by VayuSetu")
        XCTAssertEqual(state(ok, updating: true), .updating)
        var withException = config
        try withException.addSiteException("shop.example")
        XCTAssertEqual(state(ok, host: "www.shop.example", config: withException), .exception)
        XCTAssertEqual(state(ok, host: "other.example", config: withException), .active)
        var off = config; off.adBlocking = false; off.antiTracking = false
        XCTAssertEqual(state(ok, config: off), .disabled)
        for s in [ProtectionState.partial("x"), .disabled, .exception, .updating, .error("e")] {
            XCTAssertNotEqual(s.headline, "Protected by VayuSetu")
        }
    }

    func testNoVPNOrDNSTerminologyInUserFacingText() {
        let texts = ProtectionMode.allCases.flatMap { [$0.title, $0.summary] }
            + PrivacyCapabilities.all.flatMap { [$0.name, $0.note] }
            + [ProtectionState.active, .partial("p"), .disabled, .exception, .updating, .error("e")].flatMap { [$0.headline, $0.statusWord, $0.detail ?? ""] }
        for text in texts {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("vpn"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("dns"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("tunnel"), text)
        }
    }

    // MARK: Compile budget and identifiers

    func testSnapshotIdentifierIsStableForSameInputAndChangesWithExceptions() throws {
        var config = PrivacyConfiguration()
        let a = PolicyBuilder.build(configuration: config)!
        XCTAssertEqual(a.identifier, PolicyBuilder.build(configuration: config)!.identifier)
        try config.addSiteException("x.example")
        XCTAssertNotEqual(a.identifier, PolicyBuilder.build(configuration: config)!.identifier)
    }

    func testBudgetNeverDropsUserRulesOrExceptions() throws {
        var config = PrivacyConfiguration()
        config.mode = .custom
        let url = FilterCatalog.all[0].url
        try config.setList(url, enabled: true)
        try config.addUserRule(domain: "keep-me.example", action: .block)
        try config.addSiteException("keep-me-too.example")
        // More hosts than one list holds: the rest go into more lists, and the user's rule and the exception are in every list.
        let many = (0..<(PolicyBuilder.rulesPerList + 5_000)).map { "host\($0).bulk-test-list.com" }.joined(separator: "\n")
        let snapshot = PolicyBuilder.build(configuration: config, downloaded: [url: Data(many.utf8)])!
        XCTAssertEqual(snapshot.droppedForBudget, 0, "nothing is thrown away while it fits in the allowed lists")
        XCTAssertEqual(snapshot.additionalRulesJSON.count, 1)
        for list in snapshot.allRulesJSON {
            let text = String(decoding: list, as: UTF8.self)
            XCTAssertTrue(text.contains("keep-me\\\\.example") && text.contains("keep-me-too.example"), "the user rule and the exception are in every list")
        }
        XCTAssertEqual(snapshot.userRules, 1)
        XCTAssertEqual(snapshot.siteExceptions, 1)
        XCTAssertTrue(try filters(snapshot).contains { $0.contains("keep-me\\.example") })
    }
}
