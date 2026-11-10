import WebKit
import XCTest
@testable import Browser_Setu

/// Changing one feature's scripts must not take another's away, and private tabs follow the same switches as normal ones.
@MainActor
final class ScriptLifecycleTests: XCTestCase {
    private func sources(_ controller: WKUserContentController) -> [String] { controller.userScripts.map(\.source) }

    func testTheErrorCollectorSurvivesEveryReinstall() {
        let controller = WKUserContentController()
        for _ in 0..<3 {
            UserScriptInstaller.install([], policy: WebPolicy(), storage: nil, filter: FilterScripts(), into: controller)
            XCTAssertEqual(sources(controller).filter { $0.contains("__bsErrors") }.count, 1, "present once, never twice and never gone")
        }
    }

    func testEveryBrowserScriptIsStillThereAfterAReinstallAndNoneIsDoubled() {
        let controller = WKUserContentController()
        UserScriptInstaller.install([], policy: WebPolicy(), storage: nil, filter: FilterScripts(), into: controller)
        let first = sources(controller)
        UserScriptInstaller.install([], policy: WebPolicy(), storage: nil, filter: FilterScripts(), into: controller)
        XCTAssertEqual(sources(controller), first, "installing again gives exactly the same set")
        XCTAssertTrue(first.contains { $0.contains("scrollbar") || $0.contains("::-webkit-scrollbar") } || first.count > 3)
    }

    func testAPrivateTabIsGivenTheNewPolicyWhenItChanges() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-life-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        let tab = m.openTab(url: nil, isPrivate: true)
        let view = try XCTUnwrap(tab.engine.hostView as? WKWebView)
        XCTAssertFalse(sources(view.configuration.userContentController).contains { $0.contains("RTCPeerConnection") })
        var policy = WebPolicy()
        policy.blockWebRTC = true
        m.engine.setWebPolicy(policy)
        XCTAssertTrue(sources(view.configuration.userContentController).contains { $0.contains("RTCPeerConnection") }, "the open private tab follows the new switch")
        policy.blockWebRTC = false
        m.engine.setWebPolicy(policy)
        XCTAssertFalse(sources(view.configuration.userContentController).contains { $0.contains("RTCPeerConnection") }, "and the old one is gone when it is switched off")
    }

    func testAPrivateTabNeverGetsUserScriptsOrTheErrorCollector() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-life2-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        var script = try XCTUnwrap(UserScriptFile.parse("// ==UserScript==\n// @name T\n// @match https://*/*\n// ==/UserScript==\nvoid 0;", fallbackName: "T"))
        script.enabled = true
        m.engine.setUserScripts([script])
        let tab = m.openTab(url: nil, isPrivate: true)
        let view = try XCTUnwrap(tab.engine.hostView as? WKWebView)
        let all = sources(view.configuration.userContentController)
        XCTAssertFalse(all.contains { $0.contains("__bsErrors") })
        XCTAssertFalse(all.contains { $0.contains(script.id.uuidString) })
    }

    func testEveryScriptThatTheBrowserAddsComesFromTheOneFile() throws {
        // Only WebKitUserScripts.swift may add scripts or clear them, so no feature can wipe another's by accident.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for dir in ["Shared", "Engines/WebKit", "macOS", "iOS"] {
            let base = root.appendingPathComponent(dir)
            for file in try FileManager.default.subpathsOfDirectory(atPath: base.path) where file.hasSuffix(".swift") {
                if file == "WebKitUserScripts.swift" { continue }
                let text = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
                XCTAssertFalse(text.contains("removeAllUserScripts"), "\(dir)/\(file) must not clear scripts")
                XCTAssertFalse(text.contains(".addUserScript("), "\(dir)/\(file) must add scripts through the installer")
            }
        }
    }
}
