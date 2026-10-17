import XCTest
@testable import Browser_Setu

final class ExtensionToolsTests: XCTestCase {
    private func summary(_ id: String, _ manifest: [String: Any]) -> ExtensionManifestSummary { ExtensionManifestSummary(id: id, name: id.capitalized, version: "1", manifest: manifest) }

    func testASummaryReadsHostsShortcutsAndWhatItChanges() {
        let s = summary("a", ["manifest_version": 3, "host_permissions": ["https://*.example.com/*"], "permissions": ["declarativeNetRequest", "storage"],
                              "content_scripts": [["matches": ["https://x.test/*"], "css": ["a.css"], "js": ["a.js"]]],
                              "commands": ["go": ["suggested_key": ["default": "Ctrl+Shift+K", "mac": "Command+Shift+K"]]],
                              "chrome_url_overrides": ["newtab": "n.html"], "background": ["service_worker": "b.js"]])
        XCTAssertEqual(s.hosts, ["https://*.example.com/*", "https://x.test/*"])
        XCTAssertEqual(s.permissions, ["declarativeNetRequest", "storage"])
        XCTAssertTrue(s.injectsCSS); XCTAssertTrue(s.changesRequests); XCTAssertTrue(s.replacesNewTab); XCTAssertTrue(s.hasBackground)
        XCTAssertEqual(s.shortcuts["go"], "command+shift+k")
        XCTAssertEqual(s.contentScriptCount, 1)
    }

    func testHostPatternsOverlapOnlyWhereTheyShould() {
        XCTAssertTrue(HostPatterns.overlap("<all_urls>", "https://a.test/*"))
        XCTAssertTrue(HostPatterns.overlap("*://*.example.com/*", "https://docs.example.com/x"))
        XCTAssertTrue(HostPatterns.overlap("https://a.test/*", "http://a.test/b"))
        XCTAssertFalse(HostPatterns.overlap("https://a.test/*", "https://b.test/*"))
        XCTAssertFalse(HostPatterns.overlap("*://*.example.com/*", "https://example.org/*"))
        XCTAssertTrue(HostPatterns.overlap(["https://a.test/*"], ["https://c.test/*", "*://*.test/*"]))
    }

    func testConflictsAreNamedForTheRightPairsOnly() {
        let a = summary("alpha", ["manifest_version": 3, "permissions": ["declarativeNetRequest"], "host_permissions": ["<all_urls>"],
                                  "commands": ["x": ["suggested_key": ["default": "Alt+1"]]], "chrome_url_overrides": ["newtab": "n.html"]])
        let b = summary("beta", ["manifest_version": 3, "permissions": ["declarativeNetRequest"], "host_permissions": ["https://a.test/*"],
                                 "commands": ["y": ["suggested_key": ["default": "Alt+1"]]], "chrome_url_overrides": ["newtab": "m.html"]])
        let c = summary("gamma", ["manifest_version": 3, "permissions": ["storage"]])
        let kinds = Set(ExtensionConflicts.detect([a, b, c]).map(\.kind))
        XCTAssertEqual(kinds, [.shortcut, .blocking, .newTab])
        XCTAssertTrue(ExtensionConflicts.detect([a, c]).isEmpty)
        XCTAssertTrue(ExtensionConflicts.detect([a]).isEmpty)
    }

    func testFileDiffsListWhatWasAddedRemovedAndChanged() {
        let diff = ExtensionFileDiff.compare(old: ["a.js": "1", "b.js": "2", "c.js": "3"], new: ["a.js": "1", "b.js": "9", "d.js": "4"])
        XCTAssertEqual(diff.added, ["d.js"]); XCTAssertEqual(diff.removed, ["c.js"]); XCTAssertEqual(diff.changed, ["b.js"])
        XCTAssertEqual(diff.lines, ["1 added: d.js", "1 removed: c.js", "1 changed: b.js"])
        XCTAssertTrue(ExtensionFileDiff.compare(old: ["a": "1"], new: ["a": "1"]).isEmpty)
    }

    func testScoresCountOnlyTheChecksThatApplied() {
        let checks = [ExtensionCheck(name: "loads", status: .passed, detail: ""), ExtensionCheck(name: "popup", status: .failed, detail: ""),
                      ExtensionCheck(name: "options", status: .skipped, detail: ""), ExtensionCheck(name: "pages", status: .passed, detail: "")]
        XCTAssertEqual(ExtensionScore.percent(checks), 67)
        XCTAssertEqual(ExtensionScore.label(checks), "Partly works (67%)")
        XCTAssertNil(ExtensionScore.percent([ExtensionCheck(name: "x", status: .skipped, detail: "")]))
        XCTAssertEqual(ExtensionScore.label([]), "Not tested")
    }

    func testAZipWrittenHereIsReadBackByTheExtractor() throws {
        let data = ZipWriter.zip([("manifest.json", Data("{\"a\":1}".utf8)), ("sub/x.js", Data("alert(1)".utf8))])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try ExtensionPackage.extract(zip: data, into: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("manifest.json"), encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("sub/x.js"), encoding: .utf8), "alert(1)")
    }

    func testPresetsMapToSiteAccessAndNameTheRiskyFeatures() {
        XCTAssertEqual(ExtensionPermissionPreset.cautious.siteAccess, .onClick)
        XCTAssertEqual(ExtensionPermissionPreset.balanced.siteAccess, .specific)
        XCTAssertEqual(ExtensionPermissionPreset.open.siteAccess, .all)
        XCTAssertTrue(ExtensionPermissionPreset.highRisk.contains("cookies"))
        XCTAssertFalse(ExtensionPermissionPreset.highRisk.contains("storage"))
    }

    func testWebsiteRulesBecomeMatchPatternsAndNonsenseIsRefused() {
        XCTAssertEqual(ExtensionSitePattern.pattern(forHost: "Example.com"), "*://example.com/*")
        XCTAssertEqual(ExtensionSitePattern.pattern(forHost: "https://docs.example.com/a/b?x=1"), "*://docs.example.com/*")
        XCTAssertEqual(ExtensionSitePattern.pattern(forHost: "*.example.com"), "*://*.example.com/*")
        XCTAssertEqual(ExtensionSitePattern.pattern(forHost: "example.com:8443/path"), "*://example.com/*")
        XCTAssertNil(ExtensionSitePattern.pattern(forHost: ""))
        XCTAssertNil(ExtensionSitePattern.pattern(forHost: "localhost"))
        XCTAssertNil(ExtensionSitePattern.pattern(forHost: "a b.com"))
        XCTAssertNil(ExtensionSitePattern.pattern(forHost: "<all_urls>"))
        XCTAssertNil(ExtensionSitePattern.pattern(forHost: "exa mple..com"))
    }
}
