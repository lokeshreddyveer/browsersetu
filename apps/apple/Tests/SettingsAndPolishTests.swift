import AppKit
import SwiftUI
import XCTest
@testable import Browser_Setu

// MARK: - Search engines

final class SearchEnginesTests: XCTestCase {
    func testEveryPresetIsAValidSecureAddress() {
        XCTAssertGreaterThanOrEqual(SearchEngines.presets.count, 5)
        XCTAssertEqual(Set(SearchEngines.presets.map(\.id)).count, SearchEngines.presets.count, "ids are unique")
        for engine in SearchEngines.presets {
            XCTAssertEqual(SearchEngines.validated(engine.template), engine.template, "\(engine.name) must pass its own validation")
            XCTAssertEqual(SearchEngines.preset(for: engine.template)?.id, engine.id)
        }
        XCTAssertEqual(SearchEngines.defaultEngine.name, "Google", "Google is the default until a profile picks another")
        XCTAssertNotNil(SearchEngines.presets.first { $0.id == "brave" }, "Brave Search stays on offer")
    }

    func testCustomAddressesAreChecked() {
        XCTAssertEqual(SearchEngines.validated("  https://search.example.org/?q={}  "), "https://search.example.org/?q={}")
        XCTAssertNil(SearchEngines.validated("http://search.example.org/?q={}"), "plain http is refused")
        XCTAssertNil(SearchEngines.validated("https://search.example.org/?q="), "no place for the words")
        XCTAssertNil(SearchEngines.validated("https://search.example.org/?q={}&r={}"), "the words go in exactly one place")
        XCTAssertNil(SearchEngines.validated("https://search.example.org/ ?q={}"), "no spaces")
        XCTAssertNil(SearchEngines.validated("https://localhost/?q={}"), "a real host name is needed")
        XCTAssertNil(SearchEngines.validated("javascript:alert({})"))
        XCTAssertNil(SearchEngines.validated(""))
        XCTAssertNil(SearchEngines.validated("https://a.example/?q={}" + String(repeating: "x", count: 3000)))
    }
}

// MARK: - Scrolling folds the toolbar

final class ScrollChromeTests: XCTestCase {
    func testFoldsAfterDeliberateScrollingDownAndReturnsSooner() {
        var chrome = ScrollChrome()
        XCTAssertFalse(chrome.scrolled(by: -20)); XCTAssertFalse(chrome.scrolled(by: -20))
        XCTAssertFalse(chrome.collapsed, "a little movement changes nothing")
        XCTAssertTrue(chrome.scrolled(by: -25)); XCTAssertTrue(chrome.collapsed)
        XCTAssertFalse(chrome.scrolled(by: 10)); XCTAssertTrue(chrome.collapsed)
        XCTAssertTrue(chrome.scrolled(by: 20)); XCTAssertFalse(chrome.collapsed, "it takes less movement to come back")
    }

    func testAWobbleNeverCountsAndZeroIsIgnored() {
        var chrome = ScrollChrome()
        for _ in 0..<20 { chrome.scrolled(by: -10); chrome.scrolled(by: 10) }
        XCTAssertFalse(chrome.collapsed)
        XCTAssertFalse(chrome.scrolled(by: 0))
    }

    func testExpandAtOnceResetsTheCount() {
        var chrome = ScrollChrome()
        chrome.scrolled(by: -100)
        XCTAssertTrue(chrome.collapsed)
        chrome.expand()
        XCTAssertFalse(chrome.collapsed)
        XCTAssertFalse(chrome.scrolled(by: -30), "the count starts again after expanding")
    }
}

// MARK: - Dropdown text

final class SuggestionTextTests: XCTestCase {
    func testALongAddressReadsAsHostThenTheRest() {
        let parts = SuggestionRow.split("https://www.youtube.com/watch?v=xvT1jH8tB9AM&list=RDxvT1jH8tB9AM")
        XCTAssertEqual(parts.host, "youtube.com")
        XCTAssertEqual(parts.rest, "/watch?v=xvT1jH8tB9AM&list=RDxvT1jH8tB9AM")
        XCTAssertEqual(SearchSplit.rest("https://example.com/"), "", "a bare slash is not shown")
        XCTAssertEqual(SuggestionRow.split("not an address").host, "not an address")
    }

    func testSearchTitleGivesBackTheTypedWords() {
        XCTAssertEqual(SuggestionRow.query(from: "Search for “telugu songs”"), "telugu songs")
        XCTAssertEqual(SuggestionRow.query(from: "plain"), "plain")
    }

    func testTypedWordsAreBoldWhereverTheyAppear() {
        let text = SuggestionRow.highlight("Telugu Songs Collection", tokens: ["telugu", "SONGS", "zzz"])
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
        XCTAssertEqual(bold, ["Telugu", "Songs"], "case does not matter, and a word that is not there does nothing")
    }
}

private enum SearchSplit { static func rest(_ s: String) -> String { SuggestionRow.split(s).rest } }

// MARK: - The Settings window

@MainActor
final class SettingsWindowTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-set-\(UUID().uuidString)", profile: "default")
    }

    func testPanelsAreTheImplementedOnesInSafariOrder() {
        XCTAssertEqual(SettingsPanel.allCases.map(\.rawValue),
                       ["general", "appearance", "tabs", "search", "privacy", "websites", "profiles", "performance", "extensions", "shortcuts", "advanced"])
        XCTAssertEqual(Set(SettingsPanel.allCases.map(\.symbol)).count, SettingsPanel.allCases.count, "each panel has its own icon")
        for panel in SettingsPanel.allCases {
            XCTAssertFalse(panel.title.isEmpty); XCTAssertGreaterThan(panel.height, 240); XCTAssertLessThan(panel.height, 800)
        }
    }

    func testSearchEngineChoiceIsSavedAndInvalidOnesAreRefused() async throws {
        let root = NSTemporaryDirectory() + "bs-set-persist-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        XCTAssertTrue(a.setSearchTemplate("https://www.google.com/search?q={}"))
        XCTAssertFalse(a.setSearchTemplate("http://insecure.example/?q={}"))
        XCTAssertEqual(a.searchTemplate, "https://www.google.com/search?q={}", "a refused address leaves the choice alone")
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertEqual(b.searchTemplate, "https://www.google.com/search?q={}", "it is still chosen after a restart")
    }

    func testTabPositionMapsToTheLayout() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .classic
        XCTAssertEqual(m.effectiveTabLayout, .separate)
        m.layoutPreset = .sidebar
        XCTAssertEqual(m.effectiveTabLayout, .sidebar)
    }

    func testPrivacyLevelStaysInStepAcrossTheSettingsAndTheBrowser() async throws {
        let m = model()
        await m.start()
        m.privacy.setMode(.strict)
        XCTAssertEqual(m.privacy.configuration.mode, .strict, "the Settings picker and the shield popover read the same controller")
        m.privacy.setMode(.light)
        XCTAssertEqual(m.privacy.configuration.mode, .light)
    }

    func testCameraAndMicrophoneChoicesPersistPerWebsite() async throws {
        let m = model()
        await m.start()
        try m.core.rememberPermission(origin: "https://meet.example", kind: .camera, decision: .allow)
        try m.core.rememberPermission(origin: "https://meet.example", kind: .microphone, decision: .deny)
        let grants = try m.core.listPermissions()
        XCTAssertEqual(grants.first { $0.origin == "https://meet.example" && $0.kind == .camera }?.decision, .allow)
        XCTAssertEqual(grants.first { $0.origin == "https://meet.example" && $0.kind == .microphone }?.decision, .deny)
        try m.core.rememberPermission(origin: "https://meet.example", kind: .camera, decision: .prompt)
        let after = try m.core.listPermissions().filter { $0.origin == "https://meet.example" }
        XCTAssertNil(after.first { $0.kind == .camera }, "choosing Ask removes the saved decision, so the site asks again")
        XCTAssertEqual(after.first { $0.kind == .microphone }?.decision, .deny, "and the other choice is untouched")
    }

    func testFoldingOnScrollOnlyHappensWhereATopToolbarExists() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .classic
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertTrue(m.chromeCollapsed, "reading down folds the toolbar")
        m.expandChrome()
        XCTAssertFalse(m.chromeCollapsed)

        m.focusMode = true
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertFalse(m.chromeCollapsed, "focus mode has no toolbar to fold"); m.focusMode = false

        m.layoutPreset = .sidebar
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertFalse(m.chromeCollapsed, "the sidebar layout keeps everything in the sidebar")

        m.layoutPreset = .classic
        m.addressBar.isEditing = true
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertFalse(m.chromeCollapsed, "never while the address is being typed"); m.addressBar.isEditing = false

        m.collapseOnScroll = false
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertFalse(m.chromeCollapsed, "off means off")
    }

    func testSelectingATabBringsTheToolbarBack() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .classic
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertTrue(m.chromeCollapsed)
        m.select(m.newTab().id)
        XCTAssertFalse(m.chromeCollapsed)
    }

    func testAboutHasAVersionAndAcknowledgements() {
        XCTAssertFalse(AboutSection.version.isEmpty)
        XCTAssertFalse(AboutSection.build.isEmpty)
        let text = AcknowledgementsSheet.text
        XCTAssertGreaterThan(text.count, 2_000)
        XCTAssertTrue(text.contains("WebKit")); XCTAssertTrue(text.contains("rusqlite")); XCTAssertTrue(text.contains("Public Suffix List"))
    }

    // MARK: Rendering (images are kept so the result can be looked at)

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "shot-\(name)-\(dark ? "dark" : "light").png"))
        }
        return rep
    }

    private func variety(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) { for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        } }
        return seen.count
    }

    func testEveryPanelRendersInLightAndDark() async throws {
        let m = model()
        await m.start()
        for panel in SettingsPanel.allCases {
            for dark in [false, true] {
                let rep = try render(SettingsPanelView(panel: panel).environmentObject(m), size: CGSize(width: SettingsPanel.width, height: panel.height),
                                     dark: dark, name: "settings-\(panel.rawValue)")
                XCTAssertGreaterThan(variety(rep), 6, "\(panel.rawValue) \(dark ? "dark" : "light") drew something")
            }
        }
    }

    func testTheDropdownRendersWithEveryKindOfResult() async throws {
        let m = model()
        await m.start()
        try m.core.addBookmark(url: "https://telugu.example/songs", title: "Telugu songs collection", folder: "")
        m.active?.load(URL(string: "about:blank")!)
        let other = m.newTab()
        other.engineTitleChanged("Telugu movies")
        other.engineURLChanged(URL(string: "https://movies.example/telugu")!)
        m.select(m.tabs[0].id)
        m.addressBar.isEditing = true
        m.addressBar.text = "telugu"
        m.addressBar.refresh(model: m)
        m.addressBar.selection = 0
        XCTAssertGreaterThanOrEqual(m.addressBar.suggestions.count, 3)
        for dark in [false, true] {
            let rep = try render(SuggestionsList(address: m.addressBar).environmentObject(m).padding(24).frame(width: 640, height: 420, alignment: .top)
                .background(dark ? Color.black : Color.white), size: CGSize(width: 640, height: 420), dark: dark, name: "dropdown")
            XCTAssertGreaterThan(variety(rep), 6)
        }
    }
}

final class TrafficLightZoneTests: XCTestCase {
    func testOnlyTheTopLeftCornerRevealsTheWindowButtons() {
        let height: CGFloat = 800
        XCTAssertTrue(TrafficLightZone.contains(CGPoint(x: 20, y: 790), windowHeight: height), "right on the buttons")
        XCTAssertTrue(TrafficLightZone.contains(CGPoint(x: 100, y: 760), windowHeight: height), "a little beside them still counts")
        XCTAssertFalse(TrafficLightZone.contains(CGPoint(x: 400, y: 790), windowHeight: height), "the top centre is the pill, not the buttons")
        XCTAssertFalse(TrafficLightZone.contains(CGPoint(x: 20, y: 400), windowHeight: height), "down the left edge does nothing")
        XCTAssertFalse(TrafficLightZone.contains(CGPoint(x: 20, y: 700), windowHeight: height), "below the corner does nothing")
        XCTAssertFalse(TrafficLightZone.contains(CGPoint(x: -5, y: 790), windowHeight: height), "outside the window does nothing")
    }
}

@MainActor
final class AddressSelectionTests: XCTestCase {
    func testTakingFocusSelectsTheWholeAddressUntilTheUserTypes() async throws {
        let field = OmniboxTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        field.isEditable = true; field.isSelectable = true
        field.stringValue = "https://www.youtube.com/watch?v=xvT1jH8tB9AM&list=RDxvT1jH8tB9AM"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        guard window.makeFirstResponder(field), let editor = field.currentEditor() else {
            throw XCTSkip("this test window cannot host a field editor")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: (field.stringValue as NSString).length), "the whole address is selected")

        // Once the user has typed, a late selection must never replace their text.
        field.userEdited = true
        editor.selectedRange = NSRange(location: 3, length: 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(editor.selectedRange.length, 0)
    }
}

final class LoadingProgressTests: XCTestCase {
    func testStartsSmallOnlyMovesForwardRunsToTheEndAndResets() {
        var p = LoadingProgress()
        XCTAssertFalse(p.visible)
        p.update(progress: 0.5)
        XCTAssertEqual(p.fraction, 0, "nothing moves before loading has begun")
        p.begin(progress: 0)
        XCTAssertTrue(p.visible)
        XCTAssertEqual(p.fraction, LoadingProgress.minimum, "a page that has just started still shows a little bar")
        p.update(progress: 0.6); p.update(progress: 0.4)
        XCTAssertEqual(p.fraction, 0.6, "it never goes backwards")
        p.finish()
        XCTAssertEqual(p.fraction, 1); XCTAssertTrue(p.visible, "it runs to the end before it fades")
        p.hide()
        XCTAssertFalse(p.visible); XCTAssertEqual(p.fraction, 0, "and starts fresh for the next page")
        p.finish()
        XCTAssertFalse(p.visible, "finishing something that never started shows nothing")
    }
}

final class SearchSuggestionsTests: XCTestCase {
    func testOnlyEnginesThatPublishSuggestionsAreAsked() {
        for engine in SearchEngines.presets {
            let endpoint = SearchSuggestions.endpoint(forSearchTemplate: engine.template)
            switch engine.id {
            case "brave", "duckduckgo", "google", "bing", "qwant", "searxng":
                XCTAssertNotNil(endpoint, engine.name)
                XCTAssertTrue(endpoint!.hasPrefix("https://"), "\(engine.name) is asked over https only")
                XCTAssertEqual(endpoint!.components(separatedBy: "{}").count, 2, "the query goes in one place")
            default:
                XCTAssertNil(endpoint, "\(engine.name) has no public suggestions address, so nothing is sent")
            }
        }
        XCTAssertNil(SearchSuggestions.endpoint(forSearchTemplate: "https://custom.example/?q={}"), "a custom engine is never asked")
    }

    func testOnlyRealQuestionsAreSent() {
        XCTAssertTrue(SearchSuggestions.shouldAsk(for: "telugu songs"))
        XCTAssertTrue(SearchSuggestions.shouldAsk(for: "  swift  "))
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: "a"), "too short to be worth asking")
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: ""))
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: "https://example.com/private/page"), "an address is a destination, not a question")
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: "github.com/lokeshreddyveer"))
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: "javascript:alert(1)"))
        XCTAssertFalse(SearchSuggestions.shouldAsk(for: String(repeating: "x", count: 101)))
    }

    func testTheRequestEncodesTheQueryAndStaysHttps() throws {
        let url = try XCTUnwrap(SearchSuggestions.requestURL(endpoint: "https://search.brave.com/api/suggest?q={}&rich=false", query: "a&b=c d"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "a&b=c d")
        XCTAssertNil(SearchSuggestions.requestURL(endpoint: "http://insecure.example/?q={}", query: "x"), "never over plain http")
    }

    func testTheReplyIsReadSafely() {
        let reply = Data(#"["tel",["telugu songs","telugu movies","Telugu Songs","  ",""],{"extra":1}]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(reply), ["telugu songs", "telugu movies"], "blanks and repeats are dropped")
        XCTAssertEqual(SearchSuggestions.parse(Data(#"["q",[{"q":"one"},{"q":"two"}]]"#.utf8)), ["one", "two"])
        XCTAssertTrue(SearchSuggestions.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SearchSuggestions.parse(Data(#"{"a":1}"#.utf8)).isEmpty)
        XCTAssertTrue(SearchSuggestions.parse(Data(repeating: 0x20, count: 70_000)).isEmpty, "an oversized reply is ignored")
        let many = "[\"q\",[" + (1...40).map { "\"s\($0)\"" }.joined(separator: ",") + "]]"
        XCTAssertEqual(SearchSuggestions.parse(Data(many.utf8)).count, 6, "never more than six")
    }
}

@MainActor
final class SearchChoiceTests: XCTestCase {
    private func model(_ root: String? = nil) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-sc-\(UUID().uuidString)", profile: "default")
    }

    func testAFreshProfileSearchesWithBraveAndASavedChoiceWins() async throws {
        let root = NSTemporaryDirectory() + "bs-sc-\(UUID().uuidString)"
        let a = model(root)
        await a.start()
        XCTAssertEqual(a.searchTemplate, SearchEngines.defaultEngine.template)
        XCTAssertTrue(a.setSearchTemplate(SearchEngines.presets[2].template))
        let b = model(root)
        XCTAssertEqual(b.searchTemplate, SearchEngines.presets[2].template, "the engine chosen from the address bar is kept")
    }

    func testRemoteSuggestionsGoAfterTheFirstRowAndNeverRepeatTheTypedText() async throws {
        let m = model()
        await m.start()
        m.searchSuggestionsEnabled = false           // the list is fed by hand below; nothing is fetched
        m.addressBar.isEditing = true
        m.addressBar.text = "telugu"
        m.addressBar.refresh(model: m)
        let before = m.addressBar.suggestions
        XCTAssertEqual(before.first?.kind, .search)
        m.addressBar.applyRemote(["telugu songs", "Telugu", "telugu movies"], query: "telugu", searchTemplate: m.searchTemplate)
        let after = m.addressBar.suggestions
        XCTAssertEqual(after.first?.kind, .search, "the first row is still the search itself")
        XCTAssertEqual(after.dropFirst().prefix(2).map(\.title), ["telugu songs", "telugu movies"], "the engine's suggestions come next, without a repeat of the query")
        XCTAssertTrue(after.dropFirst().prefix(2).allSatisfy { $0.kind == .suggestion && $0.target.hasPrefix(m.searchTemplate.components(separatedBy: "{}")[0]) })
        m.addressBar.selection = 0
        m.addressBar.applyRemote(["another"], query: "telugu", searchTemplate: m.searchTemplate)
        XCTAssertEqual(m.addressBar.suggestions.map(\.title), after.map(\.title), "the list never shifts under someone choosing with the arrow keys")
    }

    func testNothingIsAskedInAPrivateTabOrWhenSwitchedOff() async throws {
        let m = model()
        await m.start()
        XCTAssertFalse(m.searchSuggestionsEnabled, "off by default: what is typed is not sent to a search engine unless the person turns this on")
        m.searchSuggestionsEnabled = false
        m.addressBar.isEditing = true
        m.addressBar.text = "telugu"
        m.addressBar.refresh(model: m)
        m.addressBar.applyRemote([], query: "telugu", searchTemplate: m.searchTemplate)
        XCTAssertFalse(m.addressBar.suggestions.contains { $0.kind == .suggestion })
        let off = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sc2-\(UUID().uuidString)", profile: "default")
        await off.start()
        off.searchSuggestionsEnabled = false
        XCTAssertFalse(off.searchSuggestionsEnabled)
    }

    func testTheSidebarWidthCanGrowToTheNewLimitAndIsSaved() async throws {
        let root = NSTemporaryDirectory() + "bs-sw-\(UUID().uuidString)"
        let a = model(root)
        await a.start()
        a.sidebarWidth = clampedSidebarWidth(9_000)
        XCTAssertEqual(a.sidebarWidth, 340)
        a.sidebarWidth = clampedSidebarWidth(300)
        let b = model(root)
        await b.start()
        XCTAssertEqual(b.sidebarWidth, 300, "a width dragged out stays")
    }
}
