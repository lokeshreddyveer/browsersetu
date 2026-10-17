import XCTest
@testable import Browser_Setu

final class DownloadScannerTests: XCTestCase {
    func testADocumentNameEndingInAProgramIsTheWorstKindOfWarning() {
        let found = DownloadScanner.assess(name: "Invoice.pdf.exe", header: [])
        XCTAssertEqual(found.first?.severity, .danger)
        XCTAssertTrue(found.first?.text.contains("common trick") == true)
    }

    func testAProgramExtensionAloneIsACaution() {
        XCTAssertEqual(DownloadScanner.assess(name: "tool.pkg", header: []).first?.severity, .caution)
        XCTAssertTrue(DownloadScanner.assess(name: "photo.png", header: Array("\u{89}PNG".utf8)).isEmpty || DownloadScanner.assess(name: "photo.png", header: [0x89, 0x50, 0x4E, 0x47]).isEmpty)
    }

    func testAFileThatIsNotWhatItsNameSaysIsFlagged() {
        XCTAssertEqual(DownloadScanner.assess(name: "report.pdf", header: [0x4D, 0x5A, 0x90, 0x00]).first?.severity, .danger)
        XCTAssertEqual(DownloadScanner.assess(name: "photo.jpg", header: Array("%PDF-1.7".utf8)).first?.severity, .caution)
        XCTAssertEqual(DownloadScanner.assess(name: "holiday.png", header: [0x89, 0x50, 0x4E, 0x47]).count, 0)
        XCTAssertEqual(DownloadScanner.assess(name: "notes.txt", header: Array("#!/bin/sh".utf8)).first?.severity, .danger)
    }

    func testAnArchiveWithProgramsInsideIsMentioned() {
        let found = DownloadScanner.assess(name: "files.zip", header: [0x50, 0x4B, 3, 4], zipEntries: ["readme.txt", "setup.exe", "bin/", "run.sh"])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].text.contains("2 files"))
        XCTAssertTrue(DownloadScanner.assess(name: "files.zip", header: [0x50, 0x4B, 3, 4], zipEntries: ["readme.txt"]).isEmpty)
    }
}

final class SiteRuleTests: XCTestCase {
    func testARuleMatchesAnySubdomainOfItsSites() {
        let rule = SiteDeleteRule(hosts: ["shop.example.com", "other.test"], trigger: .lastTabCloses, scope: .data)
        XCTAssertTrue(rule.matches(host: "www.example.com"))
        XCTAssertTrue(rule.matches(host: "cart.other.test"))
        XCTAssertFalse(rule.matches(host: "example.org"))
    }

    func testSecurityFindingsAreWorstFirstAndSayWhenAllIsWell() {
        let fine = SecurityReport(url: "https://a.test/", isHTTPS: true, certificates: [], mixedContent: [], insecureForms: [], redirects: 0, transport: "h2")
        XCTAssertEqual(fine.findings.map(\.severity), [.info])
        let bad = SecurityReport(url: "http://a.test/", isHTTPS: false, certificates: [], mixedContent: ["http://a.test/x.js"], insecureForms: ["http://a.test/login"], redirects: 4, transport: "")
        XCTAssertEqual(bad.findings.first?.severity, .danger)
        XCTAssertGreaterThanOrEqual(bad.findings.count, 3)
        let expiring = SecurityReport(url: "https://a.test/", isHTTPS: true, certificates: [.init(subject: "a.test", issuer: "CA", expires: Date().addingTimeInterval(3 * 86_400))], mixedContent: [], insecureForms: [], redirects: 0, transport: "")
        XCTAssertTrue(expiring.findings.contains { $0.text.contains("within a week") })
    }

    func testUserAgentPresetsAreKnownAndDistinct() {
        XCTAssertEqual(Set(UserAgentPreset.all.map(\.id)).count, UserAgentPreset.all.count)
        XCTAssertNotNil(UserAgentPreset.preset(id: "iphone"))
        XCTAssertNil(UserAgentPreset.preset(id: "nothing"))
    }
}

@MainActor
final class SitePrivacyModelTests: XCTestCase {
    private func makeModel() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-site-\(UUID().uuidString)", profile: "default")
    }

    func testTemporaryPermissionsEndOnTheirOwn() async throws {
        let model = makeModel()
        await model.start()
        let origin = "https://meet.example.test"
        try model.core.rememberPermission(origin: origin, kind: .camera, decision: .allow)
        try model.core.rememberPermission(origin: origin, kind: .microphone, decision: .allow)
        model.noteTemporaryPermission(origin: origin, kinds: [.camera], until: Date().timeIntervalSince1970 + 3600)
        model.noteTemporaryPermission(origin: origin, kinds: [.microphone], until: -1)
        XCTAssertEqual(model.expireTemporaryPermissions(), 0, "an hour has not passed and the app has not restarted")
        XCTAssertEqual(model.expireTemporaryPermissions(now: Date().addingTimeInterval(3 * 3600)), 1, "the hour is up")
        XCTAssertNotEqual(try model.core.listPermissions().first { $0.kind == .camera }?.decision, .allow, "back to asking")
        XCTAssertEqual(try model.core.listPermissions().first { $0.kind == .microphone }?.decision, .allow)
        XCTAssertEqual(model.expireTemporaryPermissions(atStart: true), 1, "the session one ends when the app starts again")
        XCTAssertNotEqual(try model.core.listPermissions().first { $0.kind == .microphone }?.decision, .allow)
    }

    func testForgettingASiteRemovesItsDecisionsSignInsAndSettings() async throws {
        let model = makeModel()
        await model.start()
        try model.core.rememberPermission(origin: "https://shop.example.test", kind: .camera, decision: .allow)
        try model.core.rememberPermission(origin: "https://keep.other.test", kind: .camera, decision: .allow)
        model.setSiteNotes(["shop.example.test": "note", "other.test": "keep"])
        model.setSiteUserAgent("shop.example.test", "iphone")
        let result = await model.forgetSiteCompletely(host: "shop.example.test")
        XCTAssertEqual(result.permissions, 1)
        XCTAssertNil(model.siteNotes["shop.example.test"])
        XCTAssertNil(model.siteUserAgents["shop.example.test"])
        XCTAssertEqual(model.siteNotes["other.test"], "keep", "other sites are not touched")
        XCTAssertEqual(try model.core.listPermissions().first { $0.origin.contains("keep.other") }?.decision, .allow)
    }

    func testRulesAreStoredAndCheckedAndABadHostIsIgnored() async throws {
        let model = makeModel()
        await model.start()
        model.addSiteDeleteRule(hosts: ["Shop.Example.com", "a b", "x/y", ""], trigger: .atStart, scope: .everything)
        XCTAssertEqual(model.siteDeleteRules.first?.hosts, ["shop.example.com"])
        model.addSiteDeleteRule(hosts: ["/"], trigger: .lastTabCloses, scope: .data)
        XCTAssertEqual(model.siteDeleteRules.count, 1)
    }

    func testTheWebRTCSwitchAndItsExceptionsPersist() async throws {
        let root = NSTemporaryDirectory() + "bs-rtc-\(UUID().uuidString)"
        let model = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await model.start()
        model.blockWebRTC = true
        model.setWebRTCException(host: "meet.example.test", allowed: true)
        XCTAssertTrue(model.webRTCExceptions.contains("meet.example.test"))
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertTrue(again.blockWebRTC)
        XCTAssertTrue(again.webRTCExceptions.contains("meet.example.test"))
    }
}
