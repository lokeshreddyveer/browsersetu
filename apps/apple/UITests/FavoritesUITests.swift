import XCTest

/// The start page's favorites in the real Debug app (a throwaway profile, window-only pictures): a folder that opens, a favorite inside a folder that is not in the row, the add menu,
/// and the three styles.
final class FavoritesUITests: PerfCase {
    private func start(style: String, folder: Bool = true, count: Int = 6) {
        launch(state: "favorites", extra: ["-UIFavorites", "\(count)", "-UIFavoriteFolder", folder ? "1" : "0", "-UIFavoriteStyle", style],
               env: ["BS_WINDOW_SIZE": "1100x800", "BS_SKIP_SETUP": "1"])
        XCTAssertNotNil(until(30) { self.win.exists && self.app.textFields["start-search"].exists }, "the start page did not come up")
        Thread.sleep(forTimeInterval: 1.2)      // the page animates in
    }

    private func favorite(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    func testAFolderOpensAndItsFavoritesStayOutOfTheRow() throws {
        start(style: "classic")
        attachShot("favorites-classic")
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Work, folder'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "no folder tile on the start page")
        XCTAssertTrue(folder.label.contains("2 favorites"), "the folder says how many it holds: \(folder.label)")
        XCTAssertTrue(favorite("Site 3").exists, "a loose favorite is in the row")
        XCTAssertFalse(favorite("Site 0").exists, "a favorite inside a folder is not in the row")
        folder.click()
        XCTAssertTrue(favorite("Site 0").waitForExistence(timeout: 4), "the folder did not open")
        XCTAssertTrue(favorite("Site 1").exists)
        attachShot("favorites-folder-open")
        // The close button (the pointer's way)...
        let close = app.buttons["Close folder"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "the folder has no close button")
        close.click()
        XCTAssertNotNil(until(4) { !self.favorite("Site 0").exists }, "the close button did not close the folder")
        // ...and Escape (the keyboard's way).
        folder.click()
        XCTAssertTrue(favorite("Site 0").waitForExistence(timeout: 4), "the folder did not open again")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(until(4) { !self.favorite("Site 0").exists }, "Escape did not close the folder")
        app.terminate()
    }

    func testTheAddMenuOffersFolders() throws {
        start(style: "classic")
        let add = app.descendants(matching: .any).matching(identifier: "add-favorite").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add tile")
        add.click()
        for title in ["Add a Website…", "New Folder…"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3), "the Add menu has no “\(title)”")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testTheContextMenuOfAFavorite() throws {
        start(style: "classic")
        let site = favorite("Site 3")
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        site.rightClick()
        for title in ["Open in New Tab", "Open in Background Tab", "Open in New Window", "Open in Private Tab", "Copy Address", "Edit…", "Move to Folder", "Move Earlier", "Move Later", "Remove from Favorites"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3), "the favorite's menu has no “\(title)”")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testGlassAndCompactStylesAreDrawn() throws {
        start(style: "glass")
        XCTAssertTrue(favorite("Site 3").waitForExistence(timeout: 5))
        attachShot("favorites-glass")
        app.terminate()
        start(style: "compact")
        XCTAssertTrue(favorite("Site 3").waitForExistence(timeout: 5))
        attachShot("favorites-compact")
        app.terminate()
    }
}
