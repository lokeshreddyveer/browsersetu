import XCTest
@testable import Browser_Setu

@MainActor
final class LayoutPaletteTests: XCTestCase {
    func testPresetsResolveAndCustomPassesThrough() {
        XCTAssertEqual(resolveLayout(preset: .classic, customTabLayout: .sidebar, customSidebarVisible: true),
                       ResolvedLayout(tabLayout: .separate, sidebarVisible: false))
        XCTAssertEqual(resolveLayout(preset: .sidebar, customTabLayout: .separate, customSidebarVisible: false),
                       ResolvedLayout(tabLayout: .sidebar, sidebarVisible: true, singleToolbar: true))
        XCTAssertEqual(resolveLayout(preset: .minimal, customTabLayout: .sidebar, customSidebarVisible: true),
                       ResolvedLayout(tabLayout: .compact, sidebarVisible: false))
        XCTAssertEqual(resolveLayout(preset: .custom, customTabLayout: .compact, customSidebarVisible: true),
                       ResolvedLayout(tabLayout: .compact, sidebarVisible: true))
    }

    func testSingleToolbarImpliesVerticalTabsAndOnlySidebarOrCustomUseIt() {
        for preset in [LayoutPreset.classic, .minimal] {
            XCTAssertFalse(resolveLayout(preset: preset, customTabLayout: .separate, customSidebarVisible: false, customSingleToolbar: true).singleToolbar)
        }
        let custom = resolveLayout(preset: .custom, customTabLayout: .separate, customSidebarVisible: false, customSingleToolbar: true)
        XCTAssertTrue(custom.singleToolbar)
        XCTAssertEqual(custom.tabLayout, .sidebar, "the address bar needs the sidebar, so tabs go vertical")
        XCTAssertFalse(resolveLayout(preset: .custom, customTabLayout: .separate, customSidebarVisible: false).singleToolbar)
    }

    func testSidebarWidthIsClamped() {
        XCTAssertEqual(clampedSidebarWidth(10), 190)
        XCTAssertEqual(clampedSidebarWidth(9999), 340)
        XCTAssertEqual(clampedSidebarWidth(300), 300)
    }

    func testFuzzyMatching() {
        XCTAssertNotNil(fuzzyScore(query: "ntb", in: "New Tab"))
        XCTAssertNil(fuzzyScore(query: "xyz", in: "New Tab"))
        XCTAssertGreaterThan(fuzzyScore(query: "new", in: "New Tab")!, fuzzyScore(query: "new", in: "Renewable energy news")!)
        XCTAssertEqual(fuzzyScore(query: "", in: "anything"), 0)
    }

    private func makeModel() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-lp-\(UUID().uuidString)", profile: "default")
    }

    func testLayoutSettingsPersistPerProfile() throws {
        let root = NSTemporaryDirectory() + "bs-lp-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        a.layoutPreset = .sidebar
        a.sidebarPosition = .right
        a.sidebarWidth = 333
        a.sidebarRail = true
        a.density = .compact
        XCTAssertTrue(a.sidebarVisible, "sidebar preset shows the sidebar")
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertEqual(b.layoutPreset, .sidebar)
        XCTAssertEqual(b.sidebarPosition, .right)
        XCTAssertEqual(b.sidebarWidth, 333)
        XCTAssertTrue(b.sidebarRail)
        XCTAssertEqual(b.density, .compact)
        XCTAssertEqual(b.effectiveTabLayout, .sidebar)
        XCTAssertTrue(b.sidebarVisible)
        XCTAssertTrue(b.createProfile("other"))
        b.switchProfile("other")
        XCTAssertEqual(b.layoutPreset, .classic, "layout is per profile")
    }

    func testPaletteReusesCommandsAndFiltersTabs() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertTrue(model.paletteItems(query: "").contains { $0.id == "new-tab" })
        XCTAssertEqual(model.paletteItems(query: "layout sidebar").first?.id, "layout-sidebar")
        let before = model.tabs.count
        model.paletteItems(query: "new tab").first { $0.id == "new-tab" }?.run()
        XCTAssertEqual(model.tabs.count, before + 1)
        model.paletteItems(query: "layout minimal").first?.run()
        XCTAssertEqual(model.layoutPreset, .minimal)
        XCTAssertTrue(model.paletteItems(query: "zzzzqqq").isEmpty)
    }

    func testReopenClosedTabSkipsPrivateAndBlank() async throws {
        let model = makeModel()
        await model.start()
        let blank = model.newTab()
        model.closeTab(id: blank.id)
        XCTAssertTrue(model.closedTabs.isEmpty, "blank tabs are not remembered")
        let priv = model.openTab(url: nil, isPrivate: true)
        priv.engineURLChanged(URL(string: "https://secret.example/")!)
        model.closeTab(id: priv.id)
        XCTAssertTrue(model.closedTabs.isEmpty, "private tabs are never remembered")
        let normal = model.newTab()
        normal.engineURLChanged(URL(string: "https://open.example/")!)
        model.closeTab(id: normal.id)
        XCTAssertEqual(model.closedTabs.last?.url.absoluteString, "https://open.example/")
        let count = model.tabs.count
        model.reopenClosedTab()
        XCTAssertEqual(model.tabs.count, count + 1)
        XCTAssertTrue(model.closedTabs.isEmpty)
    }
}
