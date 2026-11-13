import XCTest
@testable import Browser_Setu

/// The drop operation behind dragging a bookmark onto a folder, checked without a drag session: the move itself and what must not change. Throwaway profile folder.
@MainActor
final class D1aClassicBookmarkDropTests: XCTestCase {
    private func model() throws -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-drop-\(UUID().uuidString)", profile: "default")
        try m.core.addBookmark(url: "https://a.example/one", title: "One (my title)", folder: "")
        try m.core.addBookmark(url: "https://a.example/two", title: "Two", folder: "Docs")
        try m.core.addBookmark(url: "https://a.example/three", title: "Three", folder: "Favorites")
        return m
    }
    private func all(_ m: BrowserModel) -> [BookmarkItem] { ((try? m.core.listBookmarks(query: "")) ?? []).sorted { $0.url < $1.url } }

    func testADropMovesOnlyTheFolderAndKeepsTitleAndAddress() throws {
        let m = try model()
        XCTAssertTrue(m.dropBookmark(["bookmark:https://a.example/one"], into: "Docs"))
        let one = try XCTUnwrap(all(m).first { $0.url == "https://a.example/one" })
        XCTAssertEqual(one.folder, "Docs")
        XCTAssertEqual(one.title, "One (my title)", "the move renamed the bookmark")
        XCTAssertEqual(all(m).count, 3, "the move made a copy or lost a bookmark")
    }

    func testDroppingOnTheFolderItIsAlreadyInChangesNothing() throws {
        let m = try model(); let before = all(m)
        XCTAssertFalse(m.dropBookmark(["bookmark:https://a.example/two"], into: "Docs"))
        XCTAssertEqual(all(m).map { [$0.url, $0.title, $0.folder] }, before.map { [$0.url, $0.title, $0.folder] })
    }

    func testAnythingThatIsNotASavedBookmarkChangesNothing() throws {
        let m = try model(); let before = all(m)
        XCTAssertFalse(m.dropBookmark(["12345"], into: "Docs"), "a tab's id was taken for a bookmark")
        XCTAssertFalse(m.dropBookmark(["bookmark:https://a.example/not-saved"], into: "Docs"), "an unsaved address was added")
        XCTAssertFalse(m.dropBookmark([], into: "Docs"))
        XCTAssertEqual(all(m).map { [$0.url, $0.title, $0.folder] }, before.map { [$0.url, $0.title, $0.folder] })
    }

    func testDroppingIntoANewFolderNameCreatesItByMovingTheBookmark() throws {
        let m = try model()
        XCTAssertTrue(m.dropBookmark(["bookmark:https://a.example/three"], into: "Later"))
        XCTAssertEqual(all(m).first { $0.url == "https://a.example/three" }?.folder, "Later")
    }
}
