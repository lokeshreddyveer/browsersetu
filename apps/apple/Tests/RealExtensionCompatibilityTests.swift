import XCTest
import WebKit
@testable import Browser_Setu

@MainActor
private final class NoTabsHost: ExtensionHost {
    var extensionTabs: [TabController] { [] }
    var extensionActiveTab: TabController? { nil }
    func extensionOpenTab(url: URL?) -> TabController { fatalError("not used") }
    func extensionClose(_ tab: TabController) {}
    func extensionSelect(_ tab: TabController) {}
    func extensionAsk(title: String, message: String, allow: String) async -> Bool { false }
}

/// A report on real extensions downloaded from the Chrome Web Store. It runs only when `BS_COMPAT_DIR` names a folder of `.crx` files, so the normal
/// test run never touches the network. It prints one "COMPAT" line per extension: whether WebKit loads it, what WebKit and our own check say about it,
/// and whether a web page changes once it is installed. It does not open popups or sign in anywhere, so "loads" is not "works".
@available(macOS 15.4, *)
@MainActor
final class RealExtensionCompatibilityTests: XCTestCase {
    private let host = NoTabsHost()

    private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// What a page looks like after loading, with or without the extension controller: the attributes on <html> and how many style sheets it holds.
    private func snapshot(controller: WKWebExtensionController?) async throws -> String {
        let configuration = WKWebViewConfiguration()
        if let controller { configuration.webExtensionController = controller }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loader = Loader()
        view.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.done = continuation
            view.loadHTMLString("<html><head><title>t</title></head><body><p>hello</p></body></html>", baseURL: URL(string: "https://example.test/"))
        }
        try await Task.sleep(for: .seconds(3))
        let value = try await view.evaluateJavaScript("document.documentElement.getAttributeNames().sort().join(',') + ' | sheets=' + document.styleSheets.length + ' | style-elements=' + document.querySelectorAll('style').length")
        return value as? String ?? "?"
    }

    func testReport() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BS_COMPAT_DIR"] else { throw XCTSkip("Set BS_COMPAT_DIR to a folder of .crx files to run this report.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".crx") }.sorted()
        let plain = try await snapshot(controller: nil)
        print("COMPAT baseline page: \(plain)")
        // Names (without .crx) that must install; the report fails if one does not. Empty means it only reports.
        let mustInstall = Set((ProcessInfo.processInfo.environment["BS_COMPAT_EXPECT_INSTALL"] ?? "").split(separator: ",").map(String.init))
        var installed = Set<String>()
        for name in names {
            let path = dir + "/" + name
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size > 0 else { print("COMPAT \(name): no package downloaded (the store returned nothing for that id)"); continue }
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: storage) }
            let center = ExtensionCenter()
            let manager = WebKitExtensionManager(profile: "compat-\(UUID().uuidString)", directory: storage, center: center, host: host)
            center.attach(manager, supported: true)
            await manager.start()
            do {
                let folder = try await ExtensionPackage.unpackAsync(file: URL(fileURLWithPath: path))
                let info = try await manager.inspect(folder: folder, chromeID: nil)
                try await manager.installPending()
                let id = try XCTUnwrap(center.extensions.first?.id)
                let withExtension = try await snapshot(controller: manager.controller)
                print("COMPAT \(name): installs=yes name=\"\(info.name)\" version=\(info.version) permissions=\(info.permissions.count) sites=\(info.sites) toolbarButton=\(center.actions.contains { $0.id == id }) options=\(info.hasOptions)")
                print("COMPAT \(name):   webkitReports=\(info.problems)")
                print("COMPAT \(name):   ourNotes=\(info.compatibility)")
                installed.insert(String(name.dropLast(4)))
                print("COMPAT \(name):   pageChanged=\(withExtension != plain) (\(withExtension))")
            } catch {
                print("COMPAT \(name): installs=no reason=\(error.localizedDescription)")
            }
        }
        XCTAssertTrue(mustInstall.isSubset(of: installed), "expected to install: \(mustInstall.subtracting(installed).sorted())")
    }
}
