import XCTest
@testable import Browser_Setu

/// Scripts, Web Apps and the newer switches belong to the profile: every window sees a change at once, and a window cannot write over another's work.
@MainActor
final class SharedStateTests: XCTestCase {
    private func pair() async -> (BrowserModel, BrowserModel) {
        let a = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-shared-\(UUID().uuidString)", profile: "default")
        a.wifiKeys = MemoryWiFiKeys()
        await a.start()
        let b = BrowserModel(sharing: a)
        b.hasStarted = true
        _ = b.openTab(url: nil, isPrivate: false)
        return (a, b)
    }

    private func script(_ name: String) throws -> UserScript {
        try XCTUnwrap(UserScriptFile.parse("// ==UserScript==\n// @name \(name)\n// @match https://\(name.lowercased()).test/*\n// ==/UserScript==\nvoid 0;", fallbackName: name))
    }

    func testAScriptAddedInOneWindowAppearsInTheOtherAndTheOthersNextChangeKeepsIt() async throws {
        let (a, b) = await pair()
        let one = try script("One"), two = try script("Two")
        a.setUserScripts([one])
        XCTAssertEqual(b.userScripts.map(\.name), ["One"], "the other window follows")
        b.setUserScripts(b.userScripts + [two])
        XCTAssertEqual(Set(a.userScripts.map(\.name)), ["One", "Two"], "and the second window's change did not replace the first's")
        a.setUserScripts(a.userScripts.filter { $0.name != "One" })
        XCTAssertEqual(b.userScripts.map(\.name), ["Two"], "a removal reaches the other window too")
    }

    func testRevokingAPermissionInOneWindowIsSeenInTheOther() async throws {
        let (a, b) = await pair()
        var s = try script("Net")
        s.granted = [.network]
        a.setUserScripts([s])
        XCTAssertEqual(b.userScripts.first?.granted, [.network])
        a.revokeCapability(.network, from: s)
        XCTAssertEqual(b.userScripts.first?.granted, [], "the other window cannot go on showing, or saving back, a permission that was taken away")
    }

    func testTheNewerSwitchesAreProfileWide() {
        for key in ["user_scripts", "user_script_values", "web_apps", "download_duplicate", "download_template", "sponsor_on", "sponsor_server", "searxng_instance", "track_time", "link_ask"] {
            XCTAssertTrue(WindowRegistry.sharedSettingKeys.contains(key), key)
        }
        for key in ["layout_preset", "sidebar_width"] { XCTAssertFalse(WindowRegistry.sharedSettingKeys.contains(key), "\(key) belongs to one window") }
    }

    func testAScriptFromABackupComesBackOffWithNothingAllowed() throws {
        var s = try script("Restored")
        s.enabled = true; s.granted = [.network, .storage]
        let json = try XCTUnwrap(String(data: JSONEncoder().encode([s]), encoding: .utf8))
        let safe = BrowserModel.quarantined(userScripts: json)
        let back = try JSONDecoder().decode([UserScript].self, from: Data(safe.utf8))
        XCTAssertEqual(back.count, 1)
        XCTAssertFalse(back[0].enabled)
        XCTAssertEqual(back[0].granted, [])
        XCTAssertFalse(back[0].autoDisabledReason.isEmpty)
        XCTAssertEqual(BrowserModel.quarantined(userScripts: "not json"), "[]")
        let many = (0..<80).map { _ in s }
        let capped = try JSONDecoder().decode([UserScript].self, from: Data(BrowserModel.quarantined(userScripts: String(data: JSONEncoder().encode(many), encoding: .utf8)!).utf8))
        XCTAssertLessThanOrEqual(capped.count, UserScript.maxScripts)
    }

    func testNoConsentOrServerChoiceTravelsInABackupFile() {
        for key in ["sponsor_consent", "sponsor_on", "sponsor_server", "searxng_suggest"] { XCTAssertFalse(BrowserModel.backupSettingKeys.contains(key), key) }
        XCTAssertTrue(BrowserModel.backupSettingKeys.contains("user_scripts"))
    }
}
