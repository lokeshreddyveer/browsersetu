import WebKit
import XCTest
@testable import Browser_Setu

/// Whether a Web Extension's content scripts survive the browser reinstalling its own scripts. Both reinstall paths call removeAllUserScripts on the page's script controller.
@available(macOS 15.4, *)
@MainActor
final class ExtensionScriptSurvivalTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func makeExtension() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-probe-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Probe","version":"1.0","host_permissions":["<all_urls>"],
         "content_scripts":[{"matches":["<all_urls>"],"js":["probe.js"],"run_at":"document_start","all_frames":false}]}
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.setAttribute('data-bs-probe', 'ran');".utf8).write(to: dir.appendingPathComponent("probe.js"))
        return dir
    }

    private func load(_ view: WKWebView, _ loader: Loader) async throws -> String {
        await withCheckedContinuation { c in
            loader.done = c
            view.loadHTMLString("<html><body>probe</body></html>", baseURL: URL(string: "https://probe.example.test/"))
        }
        try await Task.sleep(for: .seconds(1.5))
        return try await view.evaluateJavaScript("document.documentElement.getAttribute('data-bs-probe') || 'absent'") as? String ?? "?"
    }

    func testAnExtensionsContentScriptStillRunsAfterTheBrowserReinstallsItsOwnScripts() async throws {
        let folder = try makeExtension()
        defer { try? FileManager.default.removeItem(at: folder) }
        let loaded = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: loaded)
        if let all = try? WKWebExtension.MatchPattern(string: "<all_urls>") { context.setPermissionStatus(.grantedExplicitly, for: all) }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        try controller.load(context)

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = Loader()
        view.navigationDelegate = loader

        let before = try await load(view, loader)
        print("EXTENSION PROBE before reinstall: \(before)")
        guard before == "ran" else { throw XCTSkip("the probe extension's content script did not run in this test host even before a reinstall (\(before)), so survival cannot be judged here") }

        // The browser reinstalls its scripts (a policy, filter or userscript change): this is exactly what every such change does.
        UserScriptInstaller.install([], policy: WebPolicy(), storage: nil, filter: FilterScripts(), into: configuration.userContentController)
        let after = try await load(view, loader)
        print("EXTENSION PROBE after reinstall: \(after)")
        XCTAssertEqual(after, "ran", "a reinstall of the browser's scripts must not take an extension's content script away")
    }
}
