import WebKit
import XCTest
@testable import Browser_Setu

/// Drives real WKWebViews against scripts/testserver.py on 127.0.0.1:18765.
@MainActor
final class BrowserIntegrationTests: XCTestCase {
    let base = "http://127.0.0.1:18765"
    var root = ""

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try await fetch("/_reset")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: helpers

    func fetch(_ path: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + path)!)
        return String(decoding: data, as: UTF8.self)
    }

    func makeModel(profile: String = "default") -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root, profile: profile)
    }

    func waitUntil(_ seconds: Double = 15, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    func loaded(_ tab: TabController, title: String) async -> Bool {
        await waitUntil { !tab.isLoading && tab.title == title }
    }

    func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies()
    }

    // MARK: 1-2. load, history, navigation

    func testLoadRecordsHistoryAndTitle() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let ok = await loaded(tab, title: "Page")
        XCTAssertTrue(ok, "page did not load")
        let urls = try model.core.recentHistory(limit: 10).map(\.url)
        XCTAssertEqual(urls, [base + "/page"])
    }

    func testBackForwardReload() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let first = await loaded(tab, title: "Page")
        XCTAssertTrue(first)
        tab.load(URL(string: base + "/page2")!)
        let second = await loaded(tab, title: "Page Two")
        XCTAssertTrue(second)
        XCTAssertTrue(tab.canGoBack)
        tab.goBack()
        let back = await waitUntil { tab.title == "Page" && !tab.isLoading }
        XCTAssertTrue(back, "back failed")
        XCTAssertTrue(tab.canGoForward)
        tab.goForward()
        let fwd = await waitUntil { tab.title == "Page Two" && !tab.isLoading }
        XCTAssertTrue(fwd, "forward failed")
        let before = try await fetch("/_requests").components(separatedBy: "/page2").count
        tab.reload()
        let reloaded = await waitUntil {
            let n = (try? self.syncRequests())?.components(separatedBy: "/page2").count ?? 0
            return n > before
        }
        XCTAssertTrue(reloaded, "reload did not hit the server")
    }

    func syncRequests() throws -> String {
        try String(contentsOf: URL(string: base + "/_requests")!, encoding: .utf8)
    }

    // MARK: 3. tabs and session restore

    func testSessionRestoreIsLazyAndExcludesPrivate() async throws {
        let m1 = makeModel()
        let a = m1.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let b = m1.openTab(url: URL(string: base + "/page2"), isPrivate: false)
        let secret = m1.openTab(url: URL(string: base + "/p/SECRETTAB"), isPrivate: true)
        let loadedAll = await waitUntil { [a, b, secret].allSatisfy { !$0.isLoading && !$0.title.isEmpty } }
        XCTAssertTrue(loadedAll)
        m1.select(a.id)
        m1.saveNow()

        let m2 = makeModel()
        await m2.start()
        XCTAssertEqual(m2.tabs.count, 2, "private tab must not be restored")
        XCTAssertEqual(m2.tabs.map { $0.url?.absoluteString }, [base + "/page", base + "/page2"])
        XCTAssertEqual(m2.active?.url?.absoluteString, base + "/page")
        let other = m2.tabs[1]
        XCTAssertFalse(other.hasLoadedPage, "inactive restored tab must not load until selected")
        m2.select(other.id)
        let lazy = await waitUntil { other.hasLoadedPage && !other.isLoading }
        XCTAssertTrue(lazy, "tab did not load when selected")
    }

    func testClosingLastTabKeepsABrowserWindowUsable() async throws {
        let model = makeModel()
        await model.start()
        let only = model.tabs[0].id
        model.closeTab(id: only)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNotEqual(model.tabs[0].id, only)
    }

    // MARK: 4. bookmarks

    func testBookmarkToggleAndSearch() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let ok = await loaded(tab, title: "Page")
        XCTAssertTrue(ok)
        model.toggleBookmark()
        XCTAssertTrue(model.activeBookmarked)
        XCTAssertEqual(try model.core.listBookmarks(query: "page").count, 1)
        model.toggleBookmark()
        XCTAssertFalse(model.activeBookmarked)
        XCTAssertEqual(try model.core.listBookmarks(query: "").count, 0)
    }

    // MARK: 5. downloads

    func testDownloadSanitizesNameAndRecords() async throws {
        XCTAssertEqual(DownloadCoordinator.safeName("../../evil name.bin"), "evil name.bin")
        XCTAssertEqual(DownloadCoordinator.safeName("..."), "download")
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/download.bin"), isPrivate: false)
        _ = tab
        let done = await waitUntil(20) { !model.downloads.completed.isEmpty }
        XCTAssertTrue(done, "download did not complete")
        guard let file = model.downloads.completed.first else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL,
                       DownloadCoordinator.directory.standardizedFileURL, "escaped downloads folder")
        XCTAssertFalse(file.lastPathComponent.contains("/"))
        XCTAssertTrue(file.lastPathComponent.contains("evil name") && file.pathExtension == "bin",
                      "unexpected name \(file.lastPathComponent)")   // a numbered suffix is fine: collisions never overwrite
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello-download")
        let recorded = await waitUntil { ((try? model.core.listDownloads(limit: 5).count) ?? 0) == 1 }
        XCTAssertTrue(recorded)
    }

    // MARK: 6-7. profile isolation and deletion

    func testProfilesIsolateCookiesAndBookmarks() async throws {
        let model = makeModel(profile: "iso-a")
        let tab = model.openTab(url: URL(string: base + "/cookie/AAA"), isPrivate: false)
        let ok = await loaded(tab, title: "Cookie")
        XCTAssertTrue(ok)
                let a = await model.engine.cookies(profile: "iso-a", isPrivate: false)
        XCTAssertTrue(a.contains { $0.name == "marker" && $0.value == "AAA" }, "cookie not stored in profile A")
        try model.core.addBookmark(url: base + "/page", title: "P", folder: "")

        XCTAssertTrue(model.createProfile("iso-b"))
        model.switchProfile("iso-b")
                let b = await model.engine.cookies(profile: "iso-b", isPrivate: false)
        XCTAssertFalse(b.contains { $0.name == "marker" }, "cookie leaked into profile B")
        XCTAssertEqual(try model.core.listBookmarks(query: "").count, 0, "bookmark leaked into profile B")

        model.switchProfile("iso-a")
        let again = await model.engine.cookies(profile: "iso-a", isPrivate: false)
        XCTAssertTrue(again.contains { $0.name == "marker" }, "profile A lost its cookie")
        XCTAssertEqual(try model.core.listBookmarks(query: "").count, 1)
    }

    func testDeletingProfileRemovesDatabaseAndWebsiteData() async throws {
        let model = makeModel()
        XCTAssertTrue(model.createProfile("doomed"))
        let id = ProfileIdentity.dataStoreID(for: "doomed")
        _ = await model.engine.cookies(profile: "doomed", isPrivate: false)  // makes the store exist
        await model.removeProfile("doomed")
        XCTAssertFalse(model.profiles.contains("doomed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/profiles/doomed"))
        let ids = await WebKitEngine.existingDataStoreIDs()
        XCTAssertFalse(ids.contains(id))
        await model.removeProfile("default")
        XCTAssertTrue(model.profiles.contains("default"), "default profile must not be deletable")
    }

    // MARK: 8. private browsing leaves nothing behind

    func testPrivateBrowsingPersistsNothing() async throws {
        let marker = "PRIVMARK\(UInt32.random(in: 100000...999999))"
        let model = makeModel(profile: "priv")
        let tab = model.openTab(url: URL(string: base + "/cookie/\(marker)"), isPrivate: true)
        let ok = await loaded(tab, title: "Cookie")
        XCTAssertTrue(ok)
        let page = model.openTab(url: URL(string: base + "/p/\(marker)"), isPrivate: true)
        let ok2 = await waitUntil { !page.isLoading && page.title.contains(marker) }
        XCTAssertTrue(ok2)

        // 1. nothing in the profile database
        XCTAssertTrue(try model.core.recentHistory(limit: 50).isEmpty, "private visit reached history")
        // 2. cookie lives only in the non-persistent store, not the profile's store
        let persisted = await model.engine.cookies(profile: "priv", isPrivate: false)
        XCTAssertFalse(persisted.contains { $0.value == marker }, "private cookie reached persistent store")
        let privateCookies = await model.engine.cookies(profile: "priv", isPrivate: true)
        XCTAssertTrue(privateCookies.contains { $0.value == marker }, "positive control: private store should hold cookie")
        // 3. no session checkpoint of private tabs
        model.saveNow()
        let reopened = try BrowserCore.open(root: root, profile: "priv")
        XCTAssertNil(try reopened.restoreSession())

        // 4. close private tabs, then scan every file the app owns for the marker
        model.closeTab(id: tab.id)
        model.closeTab(id: page.id)
        try await Task.sleep(for: .seconds(2))
        let id = Bundle.main.bundleIdentifier ?? "com.browsersetu.mac"
        let lib = NSHomeDirectory() + "/Library"
        // Only directories owned by this app, never the user's other data.
        let roots = [lib + "/WebKit/" + id, lib + "/Caches/" + id, lib + "/HTTPStorages/" + id,
                     lib + "/Cookies", lib + "/Application Support/BrowserSetu", root]
        let hits = roots.flatMap { filesContaining(marker, under: $0) }
        XCTAssertTrue(hits.isEmpty, "marker found on disk: \(hits)")
    }

    func filesContaining(_ marker: String, under dir: String) -> [String] {
        var hits: [String] = []
        let needle = Data(marker.utf8)
        guard let e = FileManager.default.enumerator(atPath: dir) else { return hits }
        for case let rel as String in e {
            let path = dir + "/" + rel
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? Int ?? 0) < 50_000_000,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            else { continue }
            if data.range(of: needle) != nil { hits.append(rel) }
        }
        return hits
    }

    // MARK: 9. permissions

    func testPermissionAllowDenyRevokeAndProfileSeparation() async throws {
        let model = makeModel(profile: "perm-a")
        let origin = "https://camera.example"
        var v = try model.core.decidePermission(origin: origin, kind: .camera, private: false)
        XCTAssertEqual(v.decision, .prompt)
        try model.core.rememberPermission(origin: origin, kind: .camera, decision: .deny)
        v = try model.core.decidePermission(origin: origin, kind: .camera, private: false)
        XCTAssertEqual(v.decision, .deny)
        try model.core.rememberPermission(origin: origin, kind: .camera, decision: .allow)
        v = try model.core.decidePermission(origin: origin, kind: .camera, private: false)
        XCTAssertEqual(v.decision, .allow)
        v = try model.core.decidePermission(origin: origin, kind: .camera, private: true)
        XCTAssertEqual(v.decision, .prompt, "private tabs must always prompt")
        v = try model.core.decidePermission(origin: "http://camera.example", kind: .camera, private: false)
        XCTAssertEqual(v.decision, .deny, "insecure origins must be denied")
        XCTAssertTrue(model.createProfile("perm-b"))
        model.switchProfile("perm-b")
        v = try model.core.decidePermission(origin: origin, kind: .camera, private: false)
        XCTAssertEqual(v.decision, .prompt, "permission leaked across profiles")
        model.switchProfile("perm-a")
        try model.core.rememberPermission(origin: origin, kind: .camera, decision: .prompt)
        v = try model.core.decidePermission(origin: origin, kind: .camera, private: false)
        XCTAssertEqual(v.decision, .prompt, "revoke failed")
    }

    // Tracker blocking is covered end to end in PrivacyIntegrationTests.

    // MARK: 11. error and policy paths

    func testUnreachableHostShowsErrorPageAndNoHistory() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: "http://127.0.0.1:1/"), isPrivate: false)
        try await Task.sleep(for: .seconds(2))
        let ok = await waitUntil { !tab.isLoading }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(tab.isBlank, "error should keep the failed URL visible")
        XCTAssertTrue(try model.core.recentHistory(limit: 5).isEmpty, "failed load must not enter history")
    }

    func testDangerousSchemesAreBlockedAtNavigation() async throws {
        let model = makeModel()
        let tab = model.openTab(url: nil, isPrivate: false)
        for raw in ["file:///etc/hosts", "data:text/html,<title>x</title>"] {
            model.notice = nil
            tab.load(URL(string: raw)!)
            let blocked = await waitUntil(5) { model.notice != nil }
            XCTAssertTrue(blocked, "\(raw) was not blocked")
        }
        // javascript: is never produced by the address bar: it is treated as a search.
        if case .search? = resolveInput(input: "javascript:alert(1)", searchTemplate: defaultSearchTemplate()) {} else {
            XCTFail("javascript: input must become a search")
        }
        XCTAssertTrue(try model.core.recentHistory(limit: 5).isEmpty)
    }

    func testOmniboxNavigationUsesSearchAndUrl() async throws {
        let model = makeModel()
        await model.start()
        model.navigate(input: "127.0.0.1:18765/page")
        let ok = await waitUntil { model.active?.title == "Page" && model.active?.isLoading == false }
        XCTAssertTrue(ok, "bare host:port did not navigate")
        XCTAssertEqual(model.active?.url?.absoluteString, base + "/page")
    }

}
