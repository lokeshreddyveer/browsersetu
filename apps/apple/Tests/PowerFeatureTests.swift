import XCTest
@testable import Browser_Setu

@MainActor
final class PowerFeatureTests: XCTestCase {
    private func model(_ name: String = UUID().uuidString) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-\(name)", profile: "default")
    }

    // MARK: Reader

    func testReaderKeepsTheArticleAndEscapesEverything() throws {
        let raw: [String: Any] = ["title": "A <b>bold</b> title", "site": "example.com", "blocks": [
            ["t": "h2", "v": "Heading"], ["t": "p", "v": "First paragraph with <script>alert(1)</script> inside."],
            ["t": "li", "v": "one"], ["t": "li", "v": "two"], ["t": "blockquote", "v": "Quoted"],
            ["t": "img", "v": "https://example.com/a.jpg", "a": "a \"photo\""],
            ["t": "img", "v": "javascript:alert(1)", "a": "bad"], ["t": "img", "v": "http://insecure.example/x.jpg", "a": "http"],
            ["t": "video", "v": "ignored"],
        ]]
        let article = try XCTUnwrap(ReadableArticle.from(raw))
        XCTAssertEqual(article.blocks.count, 6, "only headings, text, lists, quotes and https pictures are kept")
        let html = ReaderHTML.page(for: article)
        XCTAssertFalse(html.contains("<script>"), "page text can never become markup")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("alt=\"a &quot;photo&quot;\""))
    }

    func testAPageWithoutParagraphsIsNotReadable() {
        XCTAssertNil(ReadableArticle.from(["title": "x", "blocks": [["t": "h2", "v": "Only a heading"]]]))
        XCTAssertNil(ReadableArticle.from(nil))
        XCTAssertNil(ReadableArticle.from(["blocks": "nope"]))
    }

    // MARK: Zoom

    func testEachSiteKeepsItsOwnZoomAndHostsIgnoreWww() async throws {
        let m = model("zoom")
        await m.start()
        m.rememberZoom(1.4, forHost: "www.Example.com")
        XCTAssertEqual(m.siteZoomFactor(forHost: "example.com"), 1.4)
        XCTAssertNil(m.siteZoomFactor(forHost: "other.com"))
        m.rememberZoom(1.0, forHost: "example.com")
        XCTAssertNil(m.siteZoomFactor(forHost: "example.com"), "100% forgets the site")
        m.rememberZoom(0.8, forHost: "a.com"); m.rememberZoom(1.2, forHost: "b.com")
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-zoom", profile: "default")
        XCTAssertEqual(again.siteZoomFactor(forHost: "a.com"), 0.8, "it is still set after a restart")
        m.forgetAllSiteZoom()
        XCTAssertTrue(m.siteZoom.isEmpty)
    }

    // MARK: Groups, workspaces, clear on quit

    func testGroupColoursAreSavedAndCanBeRemoved() async throws {
        let m = model("groups")
        await m.start()
        m.setGroupColor("Work", .purple)
        XCTAssertEqual(m.groupColor("Work"), .purple)
        XCTAssertNil(m.groupColor("Home"))
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-groups", profile: "default")
        XCTAssertEqual(again.groupColor("Work"), .purple)
        m.setGroupColor("Work", nil)
        XCTAssertNil(m.groupColor("Work"))
    }

    func testAWorkspaceCanHaveItsOwnAccentAndLeavingItRestoresTheGeneralOne() async throws {
        let m = model("theme")
        await m.start()
        m.accent = .teal
        m.createWorkspace("Work")
        m.setWorkspaceAccent("Work", accent: .purple)
        m.switchWorkspace("Work")
        XCTAssertEqual(Theme.accent, AccentChoice.purple.color)
        m.switchWorkspace("")
        XCTAssertEqual(Theme.accent, AccentChoice.teal.color)
    }

    func testClearOnQuitIsRememberedPerProfile() async throws {
        let name = "quit-" + UUID().uuidString
        let m = model(name)
        await m.start()
        XCTAssertEqual(m.clearOnQuit, .never)
        m.clearOnQuit = .both
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-" + name, profile: "default")
        await again.start()
        XCTAssertEqual(again.clearOnQuit, .both)
        XCTAssertTrue(ClearOnQuit.both.clearsHistory && ClearOnQuit.both.clearsSiteData)
        XCTAssertFalse(ClearOnQuit.history.clearsSiteData)
    }

    // MARK: Closed tabs and incoming links

    func testOnlyWebLinksFromOtherAppsOpen() async throws {
        let m = model("incoming")
        await m.start()
        let before = m.tabs.count
        m.openIncoming(URL(string: "javascript:alert(1)")!)
        m.openIncoming(URL(string: "file:///etc/passwd")!)
        m.openIncoming(URL(string: "https://example.com/")!)
        XCTAssertEqual(m.tabs.count, before + 1)
    }

    // MARK: Density

    func testCompactIsSmallerThanComfortableEverywhere() {
        let c = InterfaceDensity.compact, r = InterfaceDensity.comfortable
        XCTAssertLessThan(c.tabRowHeight, r.tabRowHeight)
        XCTAssertLessThan(c.smallRowHeight, r.smallRowHeight)
        XCTAssertLessThan(c.searchResultHeight, r.searchResultHeight)
        XCTAssertLessThan(c.pinnedTileHeight, r.pinnedTileHeight)
        XCTAssertLessThan(c.rowSpacing, r.rowSpacing)
        XCTAssertLessThan(c.stripHeight, r.stripHeight)
        XCTAssertLessThan(c.stripPillHeight, r.stripPillHeight)
        XCTAssertLessThan(c.listRowPadding, r.listRowPadding)
    }

    func testDensityIsSavedWithTheProfile() async throws {
        let m = model("density")
        await m.start()
        m.density = .compact
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-density", profile: "default")
        XCTAssertEqual(again.density, .compact)
    }

    // MARK: Locking, duplicates, sessions

    func testALockedTabCannotBeClosedUntilUnlocked() async throws {
        let m = model("lock")
        await m.start()
        let tab = m.openTab(url: URL(string: "https://example.com/a"), isPrivate: false)
        let count = m.tabs.count
        m.toggleLock(tab)
        m.closeTab(id: tab.id)
        XCTAssertEqual(m.tabs.count, count, "a locked tab stays")
        XCTAssertNotNil(m.notice)
        m.toggleLock(tab)
        m.closeTab(id: tab.id)
        XCTAssertEqual(m.tabs.count, count - 1)
    }

    func testTheLockSurvivesARestart() async throws {
        let name = "lock2-" + UUID().uuidString
        let m = model(name)
        await m.start()
        let tab = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false)
        m.toggleLock(tab)
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pf-" + name, profile: "default")
        await again.start()
        XCTAssertTrue(again.lockedTabIDs.contains(tab.id))
    }

    func testDuplicateTabsAreFoundIgnoringFragmentsAndCaseAndOneIsKept() async throws {
        let m = model("dups")
        await m.start()
        _ = m.openTab(url: URL(string: "https://Example.com/page#top"), isPrivate: false)
        _ = m.openTab(url: URL(string: "https://example.com/page/"), isPrivate: false)
        _ = m.openTab(url: URL(string: "https://example.com/other"), isPrivate: false)
        XCTAssertEqual(m.duplicateGroups().count, 1)
        XCTAssertEqual(m.closeDuplicateTabs(), 1)
        XCTAssertTrue(m.duplicateGroups().isEmpty)
        XCTAssertEqual(m.tabs.filter { $0.url?.path.hasPrefix("/page") == true }.count, 1)
    }

    func testSavedSessionsStoreOnlyNormalTabsAndReopenThem() async throws {
        let m = model("sess")
        await m.start()
        _ = m.openTab(url: URL(string: "https://example.com/1"), isPrivate: false)
        _ = m.openTab(url: URL(string: "https://example.com/2"), isPrivate: false)
        _ = m.openTab(url: URL(string: "https://secret.example/"), isPrivate: true)
        m.saveSession(named: "Research")
        let session = try XCTUnwrap(m.savedSessions.first)
        XCTAssertEqual(session.name, "Research")
        XCTAssertFalse(session.tabs.contains { $0.url.contains("secret") }, "private tabs are never saved")
        let before = m.tabs.count
        m.openSession(session)
        XCTAssertEqual(m.tabs.count, before + session.tabs.count)
        m.deleteSession(session)
        XCTAssertTrue(m.savedSessions.isEmpty)
    }

    func testTheTimelineListsTabsByWhenTheyWereUsed() async throws {
        let m = model("timeline")
        await m.start()
        let a = m.openTab(url: URL(string: "https://example.com/a"), isPrivate: false)
        let b = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false)
        a.lastActive = Date().addingTimeInterval(-3 * 86_400)
        let groups = m.activityGroups()
        XCTAssertTrue(groups.contains { $0.title == "Older" && $0.tabs.contains { $0.id == a.id } })
        XCTAssertTrue(groups.contains { $0.title == "In use now" && $0.tabs.contains { $0.id == b.id } })
    }
}

@MainActor
final class PrivacyExtrasTests: XCTestCase {
    func testRiskyDownloadsGetAWarningAndPlainFilesDoNot() {
        XCTAssertNotNil(DownloadSafety.warning(forFilename: "Installer.DMG", from: URL(string: "https://example.com/x")))
        XCTAssertNotNil(DownloadSafety.warning(forFilename: "run.sh", from: nil))
        XCTAssertNotNil(DownloadSafety.warning(forFilename: "settings.mobileconfig", from: nil))
        XCTAssertNil(DownloadSafety.warning(forFilename: "photo.jpg", from: nil))
        XCTAssertNil(DownloadSafety.warning(forFilename: "notes.pdf", from: nil))
        XCTAssertTrue(DownloadSafety.warning(forFilename: "a.pkg", from: URL(string: "https://evil.example/a.pkg"))?.contains("evil.example") ?? false)
    }

    func testPermissionEventsDescribeWhatHappened() {
        XCTAssertEqual(PermissionEvent(origin: "https://a.example", kinds: ["camera"], allowed: false, how: "saved").summary, "Blocked camera (saved decision)")
        XCTAssertEqual(PermissionEvent(origin: "https://a.example", kinds: ["camera", "microphone"], allowed: true, how: "asked").summary, "You allowed camera and microphone this time")
    }

    func testThePermissionLogIsKeptAndCanBeCleared() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-perm-\(UUID().uuidString)", profile: "default")
        await m.start()
        Dialogs.testHandler = { _, _, _ in 0 }
        defer { Dialogs.testHandler = nil }
        _ = await m.resolvePermission(origin: "https://a.example", kinds: [.camera], isPrivate: false)
        _ = await m.resolvePermission(origin: "https://b.example", kinds: [.microphone], isPrivate: true)
        XCTAssertEqual(m.permissionLog.count, 1, "private tabs are never recorded")
        XCTAssertEqual(m.permissionLog.first?.origin, "https://a.example")
        m.clearPermissionLog()
        XCTAssertTrue(m.permissionLog.isEmpty)
    }
}

@MainActor
final class DownloadsAndFilesTests: XCTestCase {
    func testDownloadsAreSortedIntoFoldersByKind() {
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "Photo.JPG"), "Images")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "report.pdf"), "Documents")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "a.tar.gz"), "Archives")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "song.m4a"), "Audio")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "movie.mp4"), "Video")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "Setup.dmg"), "Installers")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "mystery"), "Other")
    }

    func testSortingSendsANewDownloadIntoItsKindFolderAndNeverOutsideTheDownloadsFolder() {
        let c = DownloadCoordinator()
        c.organize = true
        let started = c.begin(suggestedName: "../../escape.pdf", cancel: {})
        XCTAssertEqual(started.destination.deletingLastPathComponent().lastPathComponent, "Documents")
        XCTAssertTrue(started.destination.path.hasPrefix(DownloadCoordinator.directory.path))
        XCTAssertEqual(started.destination.lastPathComponent, "escape.pdf")
        c.discard(started.id)
        try? FileManager.default.removeItem(at: DownloadCoordinator.directory.appendingPathComponent("Documents", isDirectory: true))
    }

    func testAnInterruptedDownloadCanBeResumedOrDismissed() {
        let c = DownloadCoordinator()
        var resumedWith: Data?
        c.resumer = { resumedWith = $0 }
        let first = c.begin(suggestedName: "big.zip", cancel: {})
        c.interrupt(first.id, resumeData: Data([1, 2, 3]), source: URL(string: "https://example.com/big.zip"))
        XCTAssertNil(c.active[first.id], "it is no longer in progress")
        XCTAssertEqual(c.interrupted[first.id]?.filename, "big.zip")
        c.resume(first.id)
        XCTAssertEqual(resumedWith, Data([1, 2, 3]))
        XCTAssertNil(c.interrupted[first.id])
        let second = c.begin(suggestedName: "other.zip", cancel: {})
        c.interrupt(second.id, resumeData: Data([9]), source: nil)
        c.dismissInterrupted(second.id)
        XCTAssertTrue(c.interrupted.isEmpty)
    }

    func testAWholePagePDFBecomesOneTallPicture() throws {
        // A two-page PDF, 100 x 200 points each, made on the spot.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 50, height: 50)); context.endPDFPage() }
        context.closePDF()
        let png = try XCTUnwrap(PageImage.png(fromPDF: data as Data, scale: 1))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 400, "the two pages are stacked, top to bottom")
        XCTAssertNil(PageImage.png(fromPDF: Data("not a pdf".utf8)))
    }
}

@MainActor
final class ProductivityTests: XCTestCase {
    private func model(_ name: String = UUID().uuidString) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-prod-\(name)", profile: "default")
    }

    // MARK: Search shortcuts

    func testASearchWordPicksTheEngineForOneSearch() {
        let g = SearchShortcuts.resolve("g cats & dogs", custom: [:])
        XCTAssertEqual(g?.name, "Google")
        XCTAssertEqual(g?.url, "https://www.google.com/search?q=cats%20%26%20dogs")
        XCTAssertEqual(SearchShortcuts.resolve("YT lofi beats", custom: [:])?.name, "YouTube")
        XCTAssertNil(SearchShortcuts.resolve("g", custom: [:]), "a word on its own is just a search")
        XCTAssertNil(SearchShortcuts.resolve("hello world", custom: [:]))
        XCTAssertNil(SearchShortcuts.resolve("g   ", custom: [:]))
    }

    func testYourOwnWordsWinAndMustBeSafeAddresses() {
        let custom = ["g": "https://searx.example/search?q={}", "bad": "http://insecure.example/?q={}"]
        XCTAssertEqual(SearchShortcuts.resolve("g cats", custom: custom)?.url, "https://searx.example/search?q=cats")
        XCTAssertNil(SearchShortcuts.resolve("bad cats", custom: custom), "a custom address that is not https is ignored")
    }

    func testTypingAShortcutOffersThatSearchFirstAndCommandsAfterAChevron() async throws {
        let m = model("shortcut")
        await m.start()
        m.addressBar.isEditing = true
        m.addressBar.text = "w Ada Lovelace"
        m.addressBar.refresh(model: m)
        XCTAssertEqual(m.addressBar.suggestions.first?.kind, .search)
        XCTAssertTrue(m.addressBar.suggestions.first?.target.contains("wikipedia.org") ?? false)
        m.addressBar.text = ">settings"
        m.addressBar.refresh(model: m)
        XCTAssertFalse(m.addressBar.suggestions.isEmpty)
        XCTAssertTrue(m.addressBar.suggestions.allSatisfy { $0.kind == .command }, "after > only commands are offered")
    }

    // MARK: Reading list

    func testHighlightsAreMarkedInTheSavedArticleAndEscaped() {
        let article = ReadableArticle(title: "T", site: "example.com", blocks: [.paragraph("The quick <b>brown</b> fox jumps. The quick one.")])
        let html = ReaderHTML.page(for: article, highlights: ["quick", "brown</b>"])
        XCTAssertEqual(html.components(separatedBy: "<mark>quick</mark>").count - 1, 2, "every occurrence is marked")
        XCTAssertTrue(html.contains("<mark>brown&lt;/b&gt;</mark>"), "marked text is escaped, never markup")
        XCTAssertFalse(html.contains("<b>"))
    }

    func testAnArticleSurvivesBeingSavedAndLoadedAgain() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = ReadableArticle(title: "T", site: "s", blocks: [.heading(2, "H"), .paragraph("P"), .image(url: "https://x.example/a.png", caption: "c")])
        let item = ReadingItem(url: "https://example.com/a", title: "T", site: "example.com", highlights: ["P"], hasOfflineCopy: true)
        ReadingStore.saveArticle(article, id: item.id, root: root)
        ReadingStore.saveIndex([item], root: root)
        XCTAssertEqual(ReadingStore.loadArticle(id: item.id, root: root), article)
        XCTAssertEqual(ReadingStore.loadIndex(root: root), [item])
        ReadingStore.deleteArticle(id: item.id, root: root)
        XCTAssertNil(ReadingStore.loadArticle(id: item.id, root: root))
    }

    // MARK: Notes, tags, links

    func testANoteBelongsToAPageAndIsKeptUntilEmptied() async throws {
        let m = model("note")
        await m.start()
        _ = m.openTab(url: URL(string: "https://Example.com/page/?utm=1#x"), isPrivate: false)
        XCTAssertEqual(m.noteKey(for: m.active), "example.com/page")
        m.setNoteForActivePage("remember this")
        XCTAssertEqual(m.noteForActivePage(), "remember this")
        let again = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-prod-note", profile: "default")
        XCTAssertEqual(again.siteNotes["example.com/page"], "remember this")
        m.setNoteForActivePage("   ")
        XCTAssertEqual(m.noteForActivePage(), "")
    }

    func testBookmarkTagsAreCleanedAndSaved() async throws {
        let m = model("tags")
        await m.start()
        m.setTags(" Work, recipes ; WORK,  , a-very-long-" + String(repeating: "x", count: 40), forBookmark: "https://example.com/")
        XCTAssertEqual(m.tags(forBookmark: "https://example.com/"), ["work", "recipes"])
        m.setTags("", forBookmark: "https://example.com/")
        XCTAssertTrue(m.tags(forBookmark: "https://example.com/").isEmpty)
    }

    func testQRCodesAreMadeForShortTextOnly() {
        XCTAssertNotNil(QRCode.image(for: "https://example.com/page"))
        XCTAssertNil(QRCode.image(for: ""))
        XCTAssertNil(QRCode.image(for: String(repeating: "a", count: 2_000)))
    }

    func testImportedSessionsKeepOnlyWebAddressesAndSkipWhatIsAlreadyHere() async throws {
        let m = model("import")
        await m.start()
        let good = SavedSession(name: "Good", tabs: [.init(url: "https://example.com/a", title: "A", pinned: false), .init(url: "javascript:alert(1)", title: "x", pinned: false)])
        let empty = SavedSession(name: "Bad", tabs: [.init(url: "file:///etc/passwd", title: "x", pinned: false)])
        XCTAssertEqual(m.importSessions([good, empty]), 1)
        XCTAssertEqual(m.savedSessions.first?.tabs.count, 1)
        XCTAssertEqual(m.importSessions([good]), 0, "the same session is not added twice")
    }
}

@MainActor
final class ScriptsAndSecretsTests: XCTestCase {
    // MARK: User scripts

    func testAUserScriptFileHeaderGivesNameSitesAndTiming() throws {
        let text = """
        // ==UserScript==
        // @name         Hide banners
        // @match        https://*.example.com/*
        // @match        *://news.test/path/*
        // @include      https://other.org/
        // @run-at       document-start
        // ==/UserScript==
        document.body.style.background = 'red';
        """
        let script = try XCTUnwrap(UserScriptFile.parse(text, fallbackName: "x"))
        XCTAssertEqual(script.name, "Hide banners")
        XCTAssertEqual(script.sites, ["example.com", "news.test", "other.org"])
        XCTAssertTrue(script.runAtStart)
        XCTAssertFalse(script.enabled, "an imported script starts switched off")
        XCTAssertFalse(script.inPageWorld, "and in the private world")
    }

    func testPatternsBecomeWebsiteNamesAndNothingElse() {
        XCTAssertEqual(UserScriptFile.site(fromPattern: "*://*/*"), "*")
        XCTAssertEqual(UserScriptFile.site(fromPattern: "<all_urls>"), "*")
        XCTAssertEqual(UserScriptFile.site(fromPattern: "https://*.Example.COM/a/b"), "example.com")
        XCTAssertNil(UserScriptFile.site(fromPattern: "localhost"), "a bare name is not a website")
        XCTAssertNil(UserScriptFile.site(fromPattern: "https://bad host.com/"))
        XCTAssertNil(UserScriptFile.parse("   ", fallbackName: "x"))
    }

    func testTheWrapperRunsOnlyOnTheNamedWebsitesAndNothingIsJoinedIntoCode() {
        var script = UserScript(name: "evil\"); alert(1);//", sites: ["example.com", "x\"]; alert(2); //"], source: "doThing();")
        script.enabled = true
        let code = UserScriptInstaller.wrapped(script)
        XCTAssertTrue(code.contains("doThing();"))
        XCTAssertTrue(code.contains("host.endsWith('.' + s)"))
        XCTAssertFalse(code.contains("alert(1);//\", sites"), "the name is JSON text, so a quote in it cannot end the string")
        XCTAssertTrue(code.contains("\\\"); alert(1);"), "a quote in the name is escaped")
    }

    func testScriptsAreSavedAndEnabledOnesAreHandedToTheEngine() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-us-\(UUID().uuidString)", profile: "default")
        await m.start()
        var script = UserScript(name: "S", sites: ["example.com"], source: "1")
        await m.saveUserScript(script)
        XCTAssertEqual(m.userScripts.count, 1)
        XCTAssertFalse(m.userScripts[0].enabled, "a new script starts off")
        Dialogs.testHandler = { _, _, _ in 0 }
        defer { Dialogs.testHandler = nil }
        await m.setUserScript(m.userScripts[0], enabled: true)
        XCTAssertTrue(m.userScripts[0].enabled)
        script = m.userScripts[0]
        script.source = "2"
        await m.saveUserScript(script)
        XCTAssertFalse(m.userScripts[0].enabled, "changing the code of a script that is on switches it off until it is confirmed again")
    }

    // MARK: Secrets and sign-ins

    func testSignInsAreKeptPerProfileAndForgotten() throws {
        let a = "test-\(UUID().uuidString)", b = "test-\(UUID().uuidString)"
        defer { SignInVault.removeAll(profile: a); SignInVault.removeAll(profile: b) }
        let space = SignInSpace(scheme: "https", host: "Example.com", port: 443, realm: "Admin", method: "NSURLAuthenticationMethodHTTPBasic", isProxy: false)
        guard SignInVault.remember(space: space, user: "ada", password: "pw", profile: a) else { throw XCTSkip("the Keychain is not available here") }
        XCTAssertEqual(SignInVault.saved(space: space, profile: a)?.user, "ada")
        XCTAssertNil(SignInVault.saved(space: space, profile: b), "another profile cannot see it")
        XCTAssertEqual(SignInVault.list(profile: a).first?.password, "", "the list never carries passwords")
        SignInVault.forget(space: space, profile: a)
        XCTAssertNil(SignInVault.saved(space: space, profile: a))
    }

    func testASavedSignInIsNotOfferedToAnotherSchemePortMethodOrProxy() throws {
        let profile = "test-\(UUID().uuidString)"
        defer { SignInVault.removeAll(profile: profile) }
        let base = SignInSpace(scheme: "https", host: "example.com", port: 443, realm: "Admin", method: "basic", isProxy: false)
        guard SignInVault.remember(space: base, user: "ada", password: "pw", profile: profile) else { throw XCTSkip("the Keychain is not available here") }
        var http = base; http.scheme = "http"
        var otherPort = base; otherPort.port = 8443
        var otherMethod = base; otherMethod.method = "digest"
        var proxy = base; proxy.isProxy = true
        var otherRealm = base; otherRealm.realm = "Other"
        for other in [http, otherPort, otherMethod, proxy, otherRealm] {
            XCTAssertNil(SignInVault.saved(space: other, profile: profile), "must not be offered to \(other.key)")
        }
        XCTAssertFalse(SignInVault.remember(space: http, user: "ada", password: "pw", profile: profile), "nothing is saved for a plain-HTTP box")
        XCTAssertNotNil(SignInVault.saved(space: base, profile: profile))
    }

    func testTheLockCannotBeTurnedOnWithoutAWayToAuthenticateAndCanAlwaysBeTurnedOff() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-lock-\(UUID().uuidString)", profile: "default")
        BiometricGate.testAvailability = false
        defer { BiometricGate.testAvailability = nil; BiometricGate.testAnswer = nil }
        await model.setLockSensitiveSettings(true)
        XCTAssertFalse(model.lockSensitiveSettings, "it cannot be turned on: there is nothing to authenticate with")
        XCTAssertNotNil(model.notice)
        model.lockSensitiveSettings = true
        await model.setLockSensitiveSettings(false)
        XCTAssertFalse(model.lockSensitiveSettings, "it can be turned off, so a removed passcode never locks the settings for good")
        model.lockSensitiveSettings = true
        let allowed = await model.requireAuthentication("Change something")
        XCTAssertFalse(allowed, "an enabled lock that cannot authenticate does not open by itself")
    }

    func testTheLockAsksOnlyWhenOnAndRemembersASuccessForAMinute() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-lock-\(UUID().uuidString)", profile: "default")
        await m.start()
        BiometricGate.testAnswer = false
        defer { BiometricGate.testAnswer = nil }
        let offResult = await m.requireAuthentication("x")
        XCTAssertTrue(offResult, "nothing is asked while the lock is off")
        BiometricGate.testAnswer = true
        await m.setLockSensitiveSettings(true)
        XCTAssertTrue(m.lockSensitiveSettings)
        m.lastAuthentication = .distantPast
        BiometricGate.testAnswer = false
        let refused = await m.requireAuthentication("x")
        XCTAssertFalse(refused, "a refusal blocks the change")
        BiometricGate.testAnswer = true
        let first = await m.requireAuthentication("x")
        XCTAssertTrue(first)
        BiometricGate.testAnswer = false
        let remembered = await m.requireAuthentication("x")
        XCTAssertTrue(remembered, "a success counts for the next minute")
        await m.setLockSensitiveSettings(false)
        XCTAssertTrue(m.lockSensitiveSettings, "turning the lock off needs authentication too, which was refused")
    }
}
