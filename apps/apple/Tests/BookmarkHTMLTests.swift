import XCTest
@testable import Browser_Setu

final class BookmarkHTMLTests: XCTestCase {
    private let chrome = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://example.com/a?x=1&amp;y=2" ADD_DATE="2">Example &amp; Co</A>
            <DT><H3>News</H3>
            <DL><p>
                <DT><A HREF="https://news.example.org/" ICON="data:image/png;base64,AAAA">Daily News</A>
                <DT><H3>Tech</H3>
                <DL><p>
                    <DT><A HREF="http://tech.example.org/x">Tech &lt;Site&gt;</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="javascript:alert(1)">Evil</A>
            <DT><A HREF="file:///etc/passwd">Local</A>
        </DL><p>
        <DT><A HREF='https://single.example/q'>Single quotes</A>
    </DL><p>
    """

    func testReadsNestedFoldersEntitiesAndDropsNonWebLinks() {
        let entries = BookmarkHTML.parse(chrome)
        XCTAssertEqual(entries.map(\.title), ["Example & Co", "Daily News", "Tech <Site>", "Single quotes"])
        XCTAssertEqual(entries[0].url, "https://example.com/a?x=1&y=2")
        XCTAssertEqual(entries[0].folder, "", "the browser's own 'Bookmarks bar' is not a folder to keep")
        XCTAssertEqual(entries[1].folder, "News")
        XCTAssertEqual(entries[2].folder, "News/Tech")
        XCTAssertEqual(entries[3].folder, "", "after the folder closes, we are back at the top")
        XCTAssertFalse(entries.contains { $0.url.hasPrefix("javascript") || $0.url.hasPrefix("file") })
    }

    func testExportThenImportKeepsEverything() {
        let original = [BookmarkHTML.Entry(url: "https://a.example/?q=1&r=2", title: "A \"quoted\" <title>", folder: ""),
                        BookmarkHTML.Entry(url: "https://b.example/", title: "B", folder: "Reading"),
                        BookmarkHTML.Entry(url: "https://c.example/", title: "C", folder: "Reading")]
        let html = BookmarkHTML.export(original)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        let back = BookmarkHTML.parse(html)
        XCTAssertEqual(Set(back.map(\.url)), Set(original.map(\.url)))
        XCTAssertEqual(back.first { $0.url == "https://a.example/?q=1&r=2" }?.title, "A \"quoted\" <title>")
        XCTAssertEqual(back.filter { $0.folder == "Reading" }.count, 2)
    }

    func testGarbageGivesNothing() {
        XCTAssertTrue(BookmarkHTML.parse("").isEmpty)
        XCTAssertTrue(BookmarkHTML.parse("<html><body>no bookmarks here</body></html>").isEmpty)
        XCTAssertTrue(BookmarkHTML.parse("<A HREF=>x</A><A>y</A>").isEmpty)
    }

    @MainActor
    func testImportAddsOnceAndSkipsWhatIsAlreadySaved() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-bm-\(UUID().uuidString)", profile: "default")
        await model.start()
        let first = model.importBookmarks(html: chrome)
        XCTAssertEqual(first.added, 4)
        let second = model.importBookmarks(html: chrome)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skipped, 4)
        XCTAssertTrue(BookmarkHTML.parse(model.bookmarksHTML()).contains { $0.url == "https://news.example.org/" })
    }
}
