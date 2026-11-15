import XCTest
@testable import Browser_Setu

/// Favorites: folders, order, equivalent addresses, the look that is kept, and the sites hidden from Often visited. A favorite is a bookmark, so these also check that
/// there is only ever one record for a page.
@MainActor
final class FavoritesTests: XCTestCase {
    private func model(root: String = NSTemporaryDirectory() + "bs-fav-\(UUID().uuidString)", profile: String = "default") -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root, profile: profile)
    }

    private func threeFavorites(_ m: BrowserModel) {
        m.addFavorite(address: "https://alpha.example/", name: "Alpha")
        m.addFavorite(address: "https://beta.example/", name: "Beta")
        m.addFavorite(address: "https://gamma.example/", name: "Gamma")
    }

    private func bookmarks(_ m: BrowserModel, url: String) -> [BookmarkItem] {
        ((try? m.core.listBookmarks(query: "")) ?? []).filter { $0.url == url }
    }

    // MARK: Folders

    func testAFolderHoldsFavoritesWithoutCopyingThem() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        XCTAssertEqual(m.createFavoriteFolder("Work"), "Work")
        m.moveFavorite("https://beta.example/", toFolder: "Work")

        XCTAssertEqual(m.favoriteFolder(of: "https://beta.example/"), "Work")
        let entries = m.favoriteEntries()
        XCTAssertEqual(entries.count, 3, "two loose favorites and one folder")
        guard case .folder(let folder) = entries.last else { return XCTFail("the folder is last: it was made last") }
        XCTAssertEqual(folder.items.map(\.title), ["Beta"])
        let records = bookmarks(m, url: "https://beta.example/")
        XCTAssertEqual(records.count, 1, "still one bookmark for the page")
        XCTAssertEqual(records.first?.folder, "Favorites/Work")
        XCTAssertTrue(m.isFavorite("https://beta.example/"), "a favorite in a folder is still a favorite")
    }

    func testRenamingAFolderKeepsItsFavoritesAndPlace() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.createFavoriteFolder("Work")
        m.moveFavorite("https://beta.example/", toFolder: "Work")
        m.moveFavoriteEntry(FavoriteToken.folder("Work"), before: "https://alpha.example/")
        m.renameFavoriteFolder("Work", to: "Office")

        XCTAssertEqual(m.favoriteFolderNames, ["Office"])
        XCTAssertEqual(m.favoriteFolder(of: "https://beta.example/"), "Office")
        guard case .folder(let first) = m.favoriteEntries().first else { return XCTFail("the folder keeps the place it was given") }
        XCTAssertEqual(first.name, "Office")
        XCTAssertEqual(first.items.count, 1)
    }

    func testDeletingAFolderKeepsEveryBookmark() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.createFavoriteFolder("Work")
        m.moveFavorite("https://alpha.example/", toFolder: "Work")
        m.moveFavorite("https://beta.example/", toFolder: "Work")
        m.deleteFavoriteFolder("Work")

        XCTAssertTrue(m.favoriteFolderNames.isEmpty)
        XCTAssertEqual(m.favorites.count, 3, "no favorite was lost")
        XCTAssertEqual(m.favoriteEntries().count, 3, "they are back in the row")
        XCTAssertNil(m.favoriteFolder(of: "https://alpha.example/"))
        XCTAssertEqual(bookmarks(m, url: "https://alpha.example/").count, 1)
    }

    func testAnEmptyFolderSurvives() async throws {
        let m = model()
        await m.start()
        m.createFavoriteFolder("Later")
        XCTAssertEqual(m.favoriteFolderNames, ["Later"])
        guard case .folder(let folder) = m.favoriteEntries().first else { return XCTFail("an empty folder is still shown") }
        XCTAssertTrue(folder.items.isEmpty)
    }

    func testFolderNamesAreChecked() async throws {
        let m = model()
        await m.start()
        XCTAssertNil(m.createFavoriteFolder("   "), "a name is needed")
        XCTAssertEqual(m.createFavoriteFolder("A/B"), "A-B", "a slash would break the folder path")
        XCTAssertNil(m.createFavoriteFolder("a-b"), "the same name in other letters is the same folder")
        XCTAssertEqual(m.createFavoriteFolder(String(repeating: "x", count: 60))?.count, 40)
        m.moveFavorite("https://nothing.example/", toFolder: "A-B")      // not a favorite: nothing happens, nothing crashes
        XCTAssertTrue(m.favorites.isEmpty)
    }

    func testAFavoriteCannotBeMovedIntoAFolderThatDoesNotExist() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.moveFavorite("https://alpha.example/", toFolder: "Ghost")
        XCTAssertNil(m.favoriteFolder(of: "https://alpha.example/"))
        XCTAssertEqual(bookmarks(m, url: "https://alpha.example/").first?.folder, BrowserModel.favoritesFolder)
    }

    func testFoldersCanBeShownFlat() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.createFavoriteFolder("Work")
        m.moveFavorite("https://beta.example/", toFolder: "Work")
        let flat = m.favoriteEntries(flattened: true)
        XCTAssertEqual(flat.count, 3)
        XCTAssertTrue(flat.allSatisfy { if case .item = $0 { return true } else { return false } }, "no folder entry when folders are off")
    }

    // MARK: Order

    func testOrdersSavedBeforeFoldersStillWork() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        // The way it was saved before folders: a list of addresses only.
        try m.core.setSetting(key: "favorites_order", value: #"["https://gamma.example/","https://alpha.example/","https://beta.example/"]"#)
        XCTAssertEqual(m.favoriteEntries().map(\.id), ["https://gamma.example/", "https://alpha.example/", "https://beta.example/"])
        XCTAssertEqual(m.orderedFavorites.map(\.title), ["Gamma", "Alpha", "Beta"])
    }

    func testADamagedOrderLosesNothing() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        try m.core.setSetting(key: "favorites_order", value: "{this is not json")
        XCTAssertEqual(Set(m.favoriteEntries().map(\.id)), ["https://alpha.example/", "https://beta.example/", "https://gamma.example/"])
    }

    func testAnOrderMentioningGoneFavoritesIsTidied() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        try m.core.setSetting(key: "favorites_order", value: #"["https://gone.example/","https://beta.example/","folder:Deleted"]"#)
        let order = m.completedFavoriteOrder()
        XCTAssertFalse(order.contains("https://gone.example/"))
        XCTAssertFalse(order.contains("folder:Deleted"))
        XCTAssertEqual(order.first, "https://beta.example/")
        XCTAssertEqual(Set(order), ["https://alpha.example/", "https://beta.example/", "https://gamma.example/"])
    }

    func testReorderingInsideAFolderAndDroppingOnAnItemInAFolder() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.createFavoriteFolder("Work")
        m.moveFavorite("https://alpha.example/", toFolder: "Work")
        m.moveFavorite("https://beta.example/", toFolder: "Work")
        // Gamma is dropped on Alpha, which is in Work: it joins Work and goes before Alpha.
        m.moveFavorite("https://gamma.example/", before: "https://alpha.example/")
        XCTAssertEqual(m.favoriteFolder(of: "https://gamma.example/"), "Work")
        guard case .folder(let folder) = m.favoriteEntries().first(where: { if case .folder = $0 { return true } else { return false } }) else { return XCTFail("the folder") }
        XCTAssertEqual(folder.items.map(\.title), ["Gamma", "Alpha", "Beta"])
        // A nudge moves a favorite one place among those beside it, and stops at the end.
        m.nudgeFavorite("https://gamma.example/", by: 1)
        m.nudgeFavorite("https://gamma.example/", by: 9)
        guard case .folder(let after) = m.favoriteEntries().first(where: { if case .folder = $0 { return true } else { return false } }) else { return XCTFail("the folder") }
        XCTAssertEqual(after.items.map(\.title), ["Alpha", "Beta", "Gamma"])
    }

    func testAFolderCanBeMovedAmongTheFavorites() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.createFavoriteFolder("Work")
        m.moveFavoriteEntry(FavoriteToken.folder("Work"), before: "https://alpha.example/")
        XCTAssertEqual(m.favoriteEntries().first?.id, FavoriteToken.folder("Work"))
        m.nudgeFavorite(FavoriteToken.folder("Work"), by: 1)
        XCTAssertEqual(m.favoriteEntries().map(\.id).first, "https://alpha.example/")
    }

    // MARK: Adding and equivalent addresses

    func testTheSamePageWrittenAnotherWayIsOneFavorite() async throws {
        let m = model()
        await m.start()
        m.addFavorite(address: "https://www.Example.com/page/", name: "First")
        m.addFavorite(address: "example.com/page", name: "Second")
        XCTAssertEqual(m.favorites.count, 1, "one page, one favorite")
        XCTAssertEqual(m.favorites.first?.title, "Second", "the title is updated")
        XCTAssertTrue(m.isFavorite("https://example.com/page#top"))
        XCTAssertEqual(FavoriteURL.key("HTTPS://Example.com:443/a/"), FavoriteURL.key("https://example.com/a"))
        XCTAssertNotEqual(FavoriteURL.key("https://example.com/a?x=1"), FavoriteURL.key("https://example.com/a"), "a different query is a different page")
    }

    func testABookmarkBecomesAFavoriteWithoutACopy() async throws {
        let m = model()
        await m.start()
        try m.core.addBookmark(url: "https://saved.example/", title: "Saved", folder: "Reading")
        let pick = try XCTUnwrap(m.bookmarksToPick().first)
        XCTAssertEqual(pick.url, "https://saved.example/")
        m.makeFavorite(pick)
        XCTAssertTrue(m.isFavorite("https://saved.example/"))
        XCTAssertEqual(bookmarks(m, url: "https://saved.example/").count, 1)
        XCTAssertTrue(m.bookmarksToPick().isEmpty, "it is offered once")
    }

    func testRemovingAFavoriteKeepsTheBookmark() async throws {
        let m = model()
        await m.start()
        threeFavorites(m)
        m.removeFavorite("https://alpha.example/")
        XCTAssertFalse(m.isFavorite("https://alpha.example/"))
        let kept = bookmarks(m, url: "https://alpha.example/")
        XCTAssertEqual(kept.count, 1, "it is still a bookmark")
        XCTAssertFalse(BrowserModel.isFavoritesFolder(kept[0].folder))
    }

    func testAddingToAFolderDirectly() async throws {
        let m = model()
        await m.start()
        m.createFavoriteFolder("Work")
        m.addFavorite(address: "https://tool.example/", name: "Tool", folder: "Work")
        XCTAssertEqual(m.favoriteFolder(of: "https://tool.example/"), "Work")
    }

    // MARK: Often visited

    func testHiddenSitesStayHiddenUntilShownAgain() async throws {
        let m = model()
        await m.start()
        XCTAssertFalse(m.isDismissedOften("https://news.example/"))
        m.dismissOften("https://www.news.example/story/")
        XCTAssertTrue(m.isDismissedOften("https://news.example/story"), "the same page, written another way, is hidden too")
        XCTAssertFalse(m.isDismissedOften("https://news.example/other"), "another page of the site is not")
        m.dismissOften("https://news.example/story")
        XCTAssertEqual(m.dismissedOftenCount, 1, "hiding twice is one entry")
        m.clearDismissedOften()
        XCTAssertFalse(m.isDismissedOften("https://news.example/story"))
        XCTAssertEqual(m.dismissedOftenCount, 0)
    }

    func testPrivateTabsGetNoFrequentSites() async throws {
        let m = model()
        await m.start()
        _ = m.openTab(url: URL(string: "https://secret.example/"), isPrivate: true)
        XCTAssertTrue(m.frequentSites().isEmpty, "nothing drawn from history in a private tab")
    }

    // MARK: Look, and profiles

    func testTheLookIsKeptAndRestoredWithoutTouchingFavorites() async throws {
        let root = NSTemporaryDirectory() + "bs-fav-look-\(UUID().uuidString)"
        let first = model(root: root)
        await first.start()
        threeFavorites(first)
        first.favoriteStyle = .glass
        first.favoriteLabels = false
        first.favoriteFoldersShown = false
        first.oftenCount = 6
        XCTAssertEqual(try first.core.getSetting(key: "fav_style"), "glass")
        XCTAssertEqual(try first.core.getSetting(key: "often_count"), "6")

        first.restoreFavoriteLayoutDefaults()
        XCTAssertEqual(first.favoriteStyle, .classic)
        XCTAssertTrue(first.favoriteLabels)
        XCTAssertTrue(first.favoriteFoldersShown)
        XCTAssertEqual(first.oftenCount, BrowserModel.defaultOftenCount)
        XCTAssertEqual(first.favorites.count, 3, "the defaults come back; the favorites do not go")
    }

    func testEachProfileHasItsOwnFavoritesAndFolders() async throws {
        let a = model(profile: "alpha")
        let b = model(profile: "beta")
        await a.start()
        await b.start()
        a.addFavorite(address: "https://only-a.example/", name: "A")
        a.createFavoriteFolder("Mine")
        XCTAssertTrue(b.favorites.isEmpty, "another profile sees none of it")
        XCTAssertTrue(b.favoriteFolderNames.isEmpty)
        XCTAssertTrue(b.favoriteEntries().isEmpty)
    }

    /// With a large bookmark list the favorites row still has to come up quickly: the time to work out what it shows, with 3,000 bookmarks and 20 favorites in 3 folders.
    func testTheRowIsQuickWithAThousandsOfBookmarks() async throws {
        let m = model()
        await m.start()
        for index in 0..<3000 { try m.core.addBookmark(url: "https://bulk\(index).example/page", title: "Bulk \(index)", folder: "Reading") }
        for index in 0..<20 { m.addFavorite(address: "https://fav\(index).example/", name: "Fav \(index)") }
        for name in ["One", "Two", "Three"] { m.createFavoriteFolder(name) }
        for index in 0..<9 { m.moveFavorite("https://fav\(index).example/", toFolder: ["One", "Two", "Three"][index % 3]) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = m.favoriteEntries(); _ = m.favorites.count }
        let each = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
        print("PERF favorites-row-ms = \(String(format: "%.2f", each)) (3000 bookmarks, 20 favorites, 3 folders)")
        XCTAssertLessThan(each, 250, "working out the favorites row took \(each) ms")
    }

    func testTheStylesAreNamedAndExplained() {
        XCTAssertEqual(FavoriteStyle.allCases.map(\.title), ["Classic", "Glass", "Compact"])
        XCTAssertTrue(FavoriteStyle.allCases.allSatisfy { !$0.summary.isEmpty })
        XCTAssertLessThan(FavoriteStyle.compact.scale, FavoriteStyle.classic.scale)
    }
}
