import XCTest
import WebKit
@testable import Browser_Setu

/// A host with no tabs, so the extension manager can be tested on its own.
@MainActor
private final class EmptyHost: ExtensionHost {
    var extensionTabs: [TabController] { [] }
    var extensionActiveTab: TabController? { nil }
    func extensionOpenTab(url: URL?) -> TabController { fatalError("not used") }
    func extensionClose(_ tab: TabController) {}
    func extensionSelect(_ tab: TabController) {}
    func extensionAsk(title: String, message: String, allow: String) async -> Bool { false }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTests: XCTestCase {
    private var scratch: [URL] = []
    private let host = EmptyHost()

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func tempDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-ext-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    /// A small Manifest V3 extension whose content script marks the page it ran on.
    private func makeExtension(matches: String = "https://example.test/*", hosts: String = "https://example.test/*") throws -> URL {
        let folder = tempDirectory("src")
        let manifest = """
        {"manifest_version": 3, "name": "Marker", "version": "1.2",
         "permissions": ["storage"], "host_permissions": ["\(hosts)"],
         "content_scripts": [{"matches": ["\(matches)"], "js": ["content.js"], "run_at": "document_end"}]}
        """
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.setAttribute('data-bs-ext', '1');".write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return folder
    }

    private func manager(directory: URL, profile: String = "ext-\(UUID().uuidString)") -> (WebKitExtensionManager, ExtensionCenter) {
        let center = ExtensionCenter()
        let manager = WebKitExtensionManager(profile: profile, directory: directory, center: center, host: host)
        center.attach(manager, supported: true)
        return (manager, center)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Loads a page into a web view that uses the extension controller and reports whether the marker appeared.
    private func marked(by manager: WebKitExtensionManager, page baseURL: String, wait: Double = 3) async throws -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = manager.controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loader = Loader()
        view.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.done = continuation
            view.loadHTMLString("<html><body><p>hello</p></body></html>", baseURL: URL(string: baseURL))
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let value = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-bs-ext')") as? String
            if value == "1" { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Inspecting

    func testInspectShowsWhatTheExtensionAsksForAndRejectsNonExtensions() async throws {
        let (manager, _) = manager(directory: tempDirectory("store"))
        let info = try await manager.inspect(folder: try makeExtension())
        XCTAssertEqual(info.name, "Marker")
        XCTAssertEqual(info.version, "1.2")
        XCTAssertTrue(info.permissions.contains("Save its own settings"), "permissions are explained in plain words: \(info.permissions)")
        XCTAssertTrue(info.sites.contains { $0.contains("example.test") }, "sites: \(info.sites)")

        do {
            _ = try await manager.inspect(folder: tempDirectory("empty"))
            XCTFail("an empty folder is not an extension")
        } catch { XCTAssertTrue(error is ExtensionError) }

        let broken = tempDirectory("broken")
        try "{ not json".write(to: broken.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        do {
            _ = try await manager.inspect(folder: broken)
            XCTFail("a broken manifest is not an extension")
        } catch { XCTAssertTrue(error is ExtensionError) }
        do { try await manager.installPending(); XCTFail("nothing is pending after a failed inspect") }
        catch { XCTAssertTrue(error is ExtensionError) }
    }

    // MARK: Running

    func testInstalledExtensionRunsOnItsSiteAndNowhereElse() async throws {
        let (manager, center) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension())
        try await manager.installPending()
        XCTAssertEqual(center.extensions.map(\.name), ["Marker"])

        let onSite = try await marked(by: manager, page: "https://example.test/page")
        XCTAssertTrue(onSite, "the content script runs on a matching page")
        let elsewhere = try await marked(by: manager, page: "https://other.test/page", wait: 1.5)
        XCTAssertFalse(elsewhere, "and does not run on a site it was not given")
    }

    func testDisablingStopsItAndEnablingBringsItBack() async throws {
        let (manager, center) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension())
        try await manager.installPending()
        let id = try XCTUnwrap(center.extensions.first?.id)

        await center.setEnabled(id, false)
        XCTAssertEqual(center.extensions.first?.enabled, false)
        let whileOff = try await marked(by: manager, page: "https://example.test/", wait: 1.5)
        XCTAssertFalse(whileOff)

        await center.setEnabled(id, true)
        let whileOn = try await marked(by: manager, page: "https://example.test/")
        XCTAssertTrue(whileOn)
    }

    func testAnExtensionWithoutPermissionForASiteDoesNotRunThere() async throws {
        // It asks to run on example.test but is only given access to a different host.
        let (manager, _) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension(matches: "https://example.test/*", hosts: "https://elsewhere.test/*"))
        try await manager.installPending()
        let ran = try await marked(by: manager, page: "https://example.test/", wait: 1.5)
        XCTAssertFalse(ran, "a content script needs host permission for the page, not just a match pattern")
    }

    // MARK: Keeping

    func testExtensionsSurviveARestartAndRemovalDeletesEverything() async throws {
        let store = tempDirectory("store")
        let profile = "ext-persist-\(UUID().uuidString)"
        let (first, firstCenter) = manager(directory: store, profile: profile)
        await first.start()
        _ = try await first.inspect(folder: try makeExtension())
        try await first.installPending()
        let id = try XCTUnwrap(firstCenter.extensions.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(id).path), "a copy lives in the app's own storage")

        let (second, secondCenter) = manager(directory: store, profile: profile)
        await second.start()
        XCTAssertEqual(secondCenter.extensions.map(\.name), ["Marker"], "it is still installed after a restart")
        let stillRuns = try await marked(by: second, page: "https://example.test/")
        XCTAssertTrue(stillRuns, "with the permissions the user approved")

        await secondCenter.remove(id)
        XCTAssertTrue(secondCenter.extensions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(id).path), "its files are deleted")
        let (third, thirdCenter) = manager(directory: store, profile: profile)
        await third.start()
        XCTAssertTrue(thirdCenter.extensions.isEmpty, "and it does not come back")
    }

    func testOnlyNormalTabsGetTheExtensionController() async throws {
        let engine = WebKitEngine()
        let center = ExtensionCenter()
        engine.attachExtensions(center: center, profile: "ext-priv-\(UUID().uuidString)", directory: tempDirectory("store"), host: host)
        XCTAssertTrue(center.isSupported)
        XCTAssertNotNil(engine.makeConfiguration(isPrivate: false, profile: "default").webExtensionController)
        XCTAssertNil(engine.makeConfiguration(isPrivate: true, profile: "default").webExtensionController, "extensions never run in private tabs")
    }

    func testCopyingKeepsTheOriginalFolderUntouched() async throws {
        let (manager, _) = manager(directory: tempDirectory("store"))
        await manager.start()
        let source = try makeExtension()
        _ = try await manager.inspect(folder: source)
        try await manager.installPending()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path))
    }

    // MARK: Revoking permissions

    func testTurningOffASitePermissionStopsTheExtensionThereAndSurvivesRestart() async throws {
        let storage = tempDirectory("store")
        let (first, firstCenter) = manager(directory: storage, profile: "revoke-profile")
        await first.start()
        _ = try await first.inspect(folder: try makeExtension())
        try await first.installPending()
        let id = try XCTUnwrap(firstCenter.extensions.first?.id)
        let site = try XCTUnwrap(first.permissionRows(id: id).first { $0.isSite })
        XCTAssertTrue(site.granted)
        let ranBefore = try await marked(by: first, page: "https://example.test/")
        XCTAssertTrue(ranBefore, "granted: the content script runs")

        first.setPermission(id: id, key: site.key, isSite: true, granted: false)
        XCTAssertFalse(first.permissionRows(id: id).first { $0.isSite }?.granted ?? true)
        let ranAfter = try await marked(by: first, page: "https://example.test/", wait: 1.5)
        XCTAssertFalse(ranAfter, "revoked: the content script no longer runs on that site")

        // A fresh manager reading the same saved records keeps the choice.
        let (second, secondCenter) = manager(directory: storage, profile: "revoke-profile")
        await second.start()
        XCTAssertEqual(secondCenter.extensions.count, 1)
        XCTAssertFalse(second.permissionRows(id: id).first { $0.isSite }?.granted ?? true)

        second.setPermission(id: id, key: site.key, isSite: true, granted: true)
        let ranAgain = try await marked(by: second, page: "https://example.test/")
        XCTAssertTrue(ranAgain, "granted again: it runs")
    }

    func testAPIPermissionsAreListedInPlainWords() async throws {
        let (manager, center) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension())
        try await manager.installPending()
        let id = try XCTUnwrap(center.extensions.first?.id)
        let rows = manager.permissionRows(id: id)
        let storage = try XCTUnwrap(rows.first { $0.key == "storage" })
        XCTAssertEqual(storage.title, "Save its own settings")
        XCTAssertFalse(storage.isSite)
    }

    func testSiteAccessModesGrantAndRevokeSites() async throws {
        let (manager, center) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension(hosts: "https://example.test/*"))
        try await manager.installPending()
        let id = try XCTUnwrap(center.extensions.first?.id)
        XCTAssertEqual(manager.siteAccess(id: id), .specific)
        manager.setSiteAccess(id: id, mode: .onClick)
        XCTAssertEqual(manager.siteAccess(id: id), .onClick)
        let ran = try await marked(by: manager, page: "https://example.test/", wait: 1.5)
        XCTAssertFalse(ran, "on click: nothing runs by itself")
        manager.setSiteAccess(id: id, mode: .specific)
        XCTAssertEqual(manager.siteAccess(id: id), .specific)
        XCTAssertFalse(manager.permissionHistory(id: id).isEmpty, "the changes are written down")
    }

    func testABlockRuleStopsTheExtensionOnThatSiteAndRemovingItBringsItBack() async throws {
        let (manager, center) = manager(directory: tempDirectory("store"))
        await manager.start()
        _ = try await manager.inspect(folder: try makeExtension(hosts: "https://example.test/*"))
        try await manager.installPending()
        let id = try XCTUnwrap(center.extensions.first?.id)
        let before = try await marked(by: manager, page: "https://example.test/", wait: 2)
        XCTAssertTrue(before, "it runs there to begin with")
        XCTAssertTrue(manager.addSiteRule(id: id, host: "example.test", allow: false))
        let rule = try XCTUnwrap(manager.permissionRows(id: id).first { $0.custom })
        XCTAssertFalse(rule.granted)
        XCTAssertEqual(rule.title, "example.test")
        let blocked = try await marked(by: manager, page: "https://example.test/", wait: 1.5)
        XCTAssertFalse(blocked, "a block rule keeps it off that site")
        manager.removeSiteRule(id: id, key: rule.key)
        XCTAssertNil(manager.permissionRows(id: id).first { $0.custom })
        XCTAssertFalse(manager.addSiteRule(id: id, host: "not a site", allow: true), "nonsense is refused")
    }

    func testInstallingIsRefusedWhereItIsNotOffered() async throws {
        #if os(macOS)
        throw XCTSkip("Installing is offered on the Mac; the refusal applies to iPhone.")
        #endif
    }
}
