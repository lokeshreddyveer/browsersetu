import XCTest
@testable import Browser_Setu

final class CitationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)   // 14 October 2026

    func testACitationNamesAuthorTitleSiteDateAddressAndAccessDate() {
        let c = Citation(title: "How Rust works", url: "https://example.com/a", author: "Ada Lovelace", published: "2026-03-04T10:00:00Z", site: "Example", accessed: date)
        XCTAssertTrue(c.plain.hasPrefix("Ada Lovelace. “How Rust works.” Example, 4 March 2026. https://example.com/a (accessed "))
        XCTAssertEqual(c.publishedText, "4 March 2026")
        XCTAssertTrue(c.markdown.hasPrefix("[How Rust works](https://example.com/a) — Ada Lovelace, Example, 4 March 2026"))
    }

    func testMissingPartsAreLeftOutNotInvented() {
        let c = Citation(title: "Untitled", url: "https://x.test/", author: nil, published: nil, site: nil, accessed: date)
        XCTAssertTrue(c.plain.hasPrefix("“Untitled.” https://x.test/ (accessed"))
        XCTAssertNil(c.publishedText)
        XCTAssertEqual(Citation(title: "T", url: "u", author: nil, published: "March 2026", site: nil, accessed: date).publishedText, "March 2026", "a date that cannot be read is shown as given")
    }
}

@MainActor
final class ResearchStoreTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("research-\(UUID().uuidString)")
        return url
    }

    func testCollectionsPersistAndAPageIsListedOnce() throws {
        let place = folder()
        let store = ResearchStore(folder: place)
        let collection = try XCTUnwrap(store.create(name: "  Climate  "))
        XCTAssertEqual(collection.name, "Climate")
        XCTAssertTrue(store.add(ResearchItem(kind: .page, title: "A", url: "https://a.test/", text: nil, citation: nil), to: collection.id))
        XCTAssertTrue(store.add(ResearchItem(kind: .page, title: "A, updated", url: "https://a.test/", text: nil, citation: nil), to: collection.id))
        XCTAssertTrue(store.add(ResearchItem(kind: .highlight, title: "A", url: "https://a.test/", text: "a passage", citation: nil), to: collection.id))
        XCTAssertEqual(store.current?.items.count, 2, "the same page is not listed twice, but a highlight from it is its own item")
        XCTAssertEqual(store.current?.items.first?.title, "A, updated")
        let again = ResearchStore(folder: place)
        XCTAssertEqual(again.collections.first?.items.count, 2)
    }

    func testLimitsAndBadNames() {
        let store = ResearchStore(folder: folder())
        XCTAssertNil(store.create(name: "   "))
        XCTAssertNil(store.create(name: String(repeating: "x", count: 61)))
        let id = store.create(name: "Big")!.id
        let long = String(repeating: "w", count: ResearchStore.maxText + 500)
        store.add(ResearchItem(kind: .note, title: "n", url: nil, text: long, citation: nil), to: id)
        XCTAssertEqual(store.current?.items.first?.text?.count, ResearchStore.maxText)
        for i in 0..<(ResearchStore.maxItems + 5) { store.add(ResearchItem(kind: .note, title: "n\(i)", url: nil, text: "t", citation: nil), to: id) }
        XCTAssertEqual(store.current?.items.count, ResearchStore.maxItems)
    }

    func testTheTimelineGroupsEverythingByDayNewestFirst() throws {
        let store = ResearchStore(folder: folder())
        let a = store.create(name: "A")!.id, b = store.create(name: "B")!.id
        let calendar = Calendar(identifier: .gregorian)
        let today = Date(), yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        store.add(ResearchItem(kind: .note, title: "old", url: nil, text: "x", citation: nil, added: yesterday), to: a)
        store.add(ResearchItem(kind: .note, title: "new", url: nil, text: "y", citation: nil, added: today), to: b)
        let timeline = store.timeline(calendar: calendar)
        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.first?.items.first?.item.title, "new")
        XCTAssertEqual(timeline.first?.items.first?.collection, "B")
    }

    func testExportsHoldEverythingAndEscapeWhatTheyShould() throws {
        let store = ResearchStore(folder: folder())
        let id = store.create(name: "Trip <2026>")!.id
        let cite = Citation(title: "Guide & Map", url: "https://guide.test/x?a=1&b=2", author: "Sam", published: "2026-01-02", site: "Guide", accessed: Date())
        store.add(ResearchItem(kind: .page, title: "Guide & Map", url: cite.url, text: "my note", citation: cite), to: id)
        store.add(ResearchItem(kind: .highlight, title: "Guide & Map", url: cite.url, text: "line one\nline two", citation: cite), to: id)
        store.add(ResearchItem(kind: .note, title: "Idea", url: nil, text: "pack light", citation: nil), to: id)
        store.add(ResearchItem(kind: .page, title: "Bad", url: "javascript:alert(1)", text: nil, citation: nil), to: id)
        let collection = try XCTUnwrap(store.current)
        let markdown = ResearchExport.markdown(collection)
        XCTAssertTrue(markdown.contains("# Trip <2026>"))
        XCTAssertTrue(markdown.contains("## Pages") && markdown.contains("## Highlights") && markdown.contains("## Notes") && markdown.contains("## Sources"))
        XCTAssertTrue(markdown.contains("> line one\n> line two"))
        let html = ResearchExport.html(collection)
        XCTAssertTrue(html.contains("<h1>Trip &lt;2026&gt;</h1>"))
        XCTAssertTrue(html.contains("a=1&amp;b=2"))
        XCTAssertFalse(html.contains("href=\"javascript:"), "only web addresses become links")
        XCTAssertFalse(html.contains("<script"))
    }
}

@MainActor
final class ResearchOfflineTests: XCTestCase {
    private func store() -> ResearchStore { ResearchStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString)")) }

    func testASavedCopyIsKeptFoundAndRemovedWithItsItem() throws {
        let s = store()
        let c = try XCTUnwrap(s.create(name: "Trip"))
        let name = try XCTUnwrap(s.saveFile(Data("%PDF-1.4 test".utf8)))
        let item = ResearchItem(kind: .pdf, title: "Page", url: "https://a.test/", text: nil, citation: nil, file: name)
        XCTAssertTrue(s.add(item, to: c.id))
        let url = try XCTUnwrap(s.savedFile(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        s.remove(item.id, from: c.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the file goes with the item")
    }

    func testDeletingACollectionDeletesItsFiles() throws {
        let s = store()
        let c = try XCTUnwrap(s.create(name: "Trip"))
        let name = try XCTUnwrap(s.saveFile(Data("%PDF-1.4 test".utf8)))
        let item = ResearchItem(kind: .pdf, title: "P", url: "https://a.test/", text: nil, citation: nil, file: name)
        s.add(item, to: c.id)
        let url = try XCTUnwrap(s.savedFile(for: item))
        s.delete(c.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAFileNameCannotPointOutsideTheFolderAndHugeFilesAreRefused() throws {
        let s = store()
        for bad in ["../../etc/passwd", "/etc/passwd", ".hidden.pdf", "a/b.pdf", "x.txt", ""] {
            XCTAssertNil(s.savedFile(for: ResearchItem(kind: .pdf, title: "x", url: nil, text: nil, citation: nil, file: bad)), bad)
        }
        XCTAssertNil(s.saveFile(Data()))
        XCTAssertNil(s.saveFile(Data(count: ResearchStore.maxFileBytes + 1)))
    }

    func testOlderCollectionFilesStillOpen() throws {
        let old = #"{"id":"9F7B6C1E-0000-4000-8000-000000000001","kind":"page","title":"T","added":0}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(old.utf8))
        XCTAssertNil(item.file); XCTAssertNil(item.comment)
    }

    func testANoteOnASelectionKeepsThePassageAndTheComment() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-an-\(UUID().uuidString)", profile: "default")
        await m.start()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><head><title>Doc</title></head><body><p id='p'>The quick brown fox jumps.</p><script>var r=document.createRange();r.selectNodeContents(document.getElementById('p'));var s=getSelection();s.removeAllRanges();s.addRange(r);</script></body></html>", baseURL: URL(string: "https://doc.example.test/"))
        try await Task.sleep(for: .seconds(1.5))
        await m.addAnchoredNote("check this claim")
        let item = m.research.collections.first?.items.first
        XCTAssertEqual(item?.comment, "check this claim")
        XCTAssertTrue(item?.text?.contains("quick brown fox") == true, "the selected words are kept (\(item?.text ?? "nothing"))")
        XCTAssertEqual(item?.kind, .highlight)
    }
}
