import XCTest
@testable import Browser_Setu

@MainActor
final class StartPageTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-start-\(UUID().uuidString)", profile: "default")
    }

    func testFavoritesAreOnlyWhatThePersonAddsAndKeepTheirOrder() async throws {
        let m = model()
        await m.start()
        XCTAssertTrue(m.orderedFavorites.isEmpty, "nothing is filled in for you")
        m.addFavorite(address: "alpha.example", name: "Alpha")
        m.addFavorite(address: "https://beta.example/", name: "Beta")
        m.addFavorite(address: "gamma.example", name: "Gamma")
        XCTAssertEqual(Set(m.orderedFavorites.map(\.title)), ["Alpha", "Beta", "Gamma"])
        m.moveFavorite("https://gamma.example", before: "https://alpha.example")
        XCTAssertEqual(m.orderedFavorites.first?.title, "Gamma")
        m.nudgeFavorite("https://gamma.example", by: 5)
        XCTAssertEqual(m.orderedFavorites.last?.title, "Gamma", "a nudge stops at the end")
        m.removeFavorite("https://beta.example/")
        XCTAssertFalse(m.orderedFavorites.contains { $0.title == "Beta" })
    }

    func testBadAddressesAreNotAddedAsFavorites() async throws {
        let m = model()
        await m.start()
        for bad in ["", "   ", "not a site", "javascript:alert(1)", "localhost", "ftp://files.example"] { m.addFavorite(address: bad, name: "x") }
        XCTAssertTrue(m.orderedFavorites.isEmpty)
    }

    func testContinueNeverOffersTheBlankTabOrAPrivateOne() async throws {
        let m = model()
        await m.start()
        XCTAssertNil(m.continueTab, "a fresh start has nothing to continue")
        let page = m.openTab(url: URL(string: "https://read.example/article"), isPrivate: false)
        let secret = m.openTab(url: URL(string: "https://secret.example/"), isPrivate: true)
        m.select(page.id)
        _ = m.newTab()
        XCTAssertEqual(m.continueTab?.id, page.id)
        XCTAssertNotEqual(m.continueTab?.id, secret.id)
        XCTAssertFalse(m.continueTab?.isBlank ?? true)
    }

    #if os(macOS)
    /// ⌘L on a blank tab goes to the search field in the middle of the page; on a loaded page it goes to the address bar in the toolbar.
    func testOpenLocationGoesToTheFieldThatIsShowing() async throws {
        let m = model()
        await m.start()
        let before = (m.startFocusTick, m.omniboxFocusTick)
        m.focusAddressBar()
        XCTAssertEqual(m.startFocusTick, before.0 + 1, "a blank tab: the page's own field")
        XCTAssertEqual(m.omniboxFocusTick, before.1)
        m.openTab(url: URL(string: "https://example.org/"), isPrivate: false)
        let start = m.startFocusTick
        m.focusAddressBar()
        XCTAssertEqual(m.startFocusTick, start, "a loaded page: the toolbar's field")
    }
    #endif
}
