import XCTest
@testable import Browser_Setu

/// Nothing a person wrote into Research is lost by a bad file, a second save, or a full collection.
@MainActor
final class ResearchIntegrityTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("research-int-\(UUID().uuidString)") }

    private func item(_ kind: ResearchItem.Kind = .page, _ url: String? = "https://example.com/a", title: String = "A", text: String? = nil) -> ResearchItem {
        ResearchItem(kind: kind, title: title, url: url, text: text, citation: nil)
    }

    // MARK: A file that cannot be read

    func testAFileThatIsNotAListIsKeptAndNeverOverwrittenSilently() throws {
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let original = Data("{\"not\": \"a list\"}".utf8)
        try original.write(to: place.appendingPathComponent("collections.json"))
        let store = ResearchStore(folder: place)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertNotNil(store.recoveryNote)
        store.create(name: "New")                                          // a save after the failed read
        let kept = try FileManager.default.contentsOfDirectory(atPath: place.path).filter { $0.hasPrefix("collections.unreadable-") }
        XCTAssertEqual(kept.count, 1, "the original is still there")
        XCTAssertEqual(try Data(contentsOf: place.appendingPathComponent(kept[0])), original)
    }

    func testOneDamagedItemDoesNotTakeTheRestOfTheCollectionWithIt() throws {
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Work","created":0,"items":[
          {"kind":"page","title":"Good one","url":"https://a.test/"},
          {"kind":"page"},
          {"kind":"hologram","title":"From a newer version","text":"still words"}
        ]}]
        """
        try Data(json.utf8).write(to: place.appendingPathComponent("collections.json"))
        let store = ResearchStore(folder: place)
        XCTAssertEqual(store.collections.count, 1)
        let titles = store.collections[0].items.map(\.title)
        XCTAssertTrue(titles.contains("Good one"))
        XCTAssertTrue(titles.contains("From a newer version"), "an unknown kind is kept as a note")
        XCTAssertEqual(store.collections[0].items.first { $0.title == "From a newer version" }?.kind, .note)
        XCTAssertEqual(titles.count, 2, "only the item with no title was left out")
        XCTAssertNotNil(store.recoveryNote, "and the person is told, with the original kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: place.path).filter { $0.hasPrefix("collections.unreadable-") }.count, 1)
    }

    func testAnUndamagedFileLeavesNoCopyAndNoNote() throws {
        let place = folder()
        let a = ResearchStore(folder: place)
        let c = try XCTUnwrap(a.create(name: "Fine"))
        a.add(item(), to: c.id)
        let b = ResearchStore(folder: place)
        XCTAssertNil(b.recoveryNote)
        XCTAssertEqual(b.collections.first?.items.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: place.path).filter { $0.hasPrefix("collections.unreadable-") }.isEmpty)
    }

    func testASaveThatCannotBeWrittenIsReported() throws {
        let place = folder()
        let store = ResearchStore(folder: place)
        // Make the file's place a folder, so the write has to fail.
        try? FileManager.default.removeItem(at: place.appendingPathComponent("collections.json"))
        try FileManager.default.createDirectory(at: place.appendingPathComponent("collections.json"), withIntermediateDirectories: true)
        store.create(name: "X")
        XCTAssertNotNil(store.saveError)
    }

    // MARK: Saving the same thing again

    func testSavingAPageAgainKeepsTheCommentThePlaceTheNoteAndTheFirstCaptureTime() throws {
        let store = ResearchStore(folder: folder())
        let c = try XCTUnwrap(store.create(name: "R"))
        var first = item(text: "my note about the page")
        first.comment = "check the second table"; first.place = 0.4; first.tags = ["reading"]; first.captured = Date(timeIntervalSince1970: 1_000)
        store.add(first, to: c.id)
        var again = item(title: "A (new title)")
        again.captured = Date(timeIntervalSince1970: 9_000)
        XCTAssertTrue(store.add(again, to: c.id))
        let kept = try XCTUnwrap(store.collections[0].items.first)
        XCTAssertEqual(store.collections[0].items.count, 1)
        XCTAssertEqual(kept.title, "A (new title)")
        XCTAssertEqual(kept.comment, "check the second table")
        XCTAssertEqual(kept.place, 0.4)
        XCTAssertEqual(kept.text, "my note about the page")
        XCTAssertEqual(kept.tags, ["reading"])
        XCTAssertEqual(kept.captured, Date(timeIntervalSince1970: 1_000), "the first time it was captured is not overwritten")
    }

    func testSavingAnOfflineCopyAgainRemovesTheCopyItReplaces() throws {
        let store = ResearchStore(folder: folder())
        let c = try XCTUnwrap(store.create(name: "R"))
        let one = try XCTUnwrap(store.saveFile(Data("%PDF-1".utf8))), two = try XCTUnwrap(store.saveFile(Data("%PDF-2".utf8)))
        var a = item(.pdf); a.file = one; store.add(a, to: c.id)
        var b = item(.pdf); b.file = two; store.add(b, to: c.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filesFolder.appendingPathComponent(one).path), "the older copy would be orphaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.filesFolder.appendingPathComponent(two).path))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filesFolder.appendingPathComponent(two).path), "removing everything removes the files too")
    }

    func testTheSamePassageFromTheSamePageIsOneHighlight() throws {
        let store = ResearchStore(folder: folder())
        let c = try XCTUnwrap(store.create(name: "R"))
        store.add(item(.highlight, text: "The quick brown fox"), to: c.id)
        store.add(item(.highlight, "https://www.example.com/a?utm_source=x", text: "  The quick brown fox "), to: c.id)
        store.add(item(.highlight, text: "A different passage"), to: c.id)
        XCTAssertEqual(store.collections[0].items.count, 2)
    }

    // MARK: Addresses

    func testPagesOfASingleApplicationThatDifferOnlyByTheirRouteStaySeparate() {
        XCTAssertNotEqual(ResearchURL.normalize("https://app.test/#/inbox"), ResearchURL.normalize("https://app.test/#/settings"))
        XCTAssertNotEqual(ResearchURL.normalize("https://app.test/#!/a"), ResearchURL.normalize("https://app.test/#!/b"))
        XCTAssertEqual(ResearchURL.normalize("https://app.test/page#section-2"), ResearchURL.normalize("https://app.test/page"), "a plain anchor is the same page")
    }

    // MARK: A full collection

    func testAFullCollectionSaysSoInsteadOfClaimingToHaveAdded() throws {
        let store = ResearchStore(folder: folder())
        let c = try XCTUnwrap(store.create(name: "R"))
        for i in 0..<ResearchStore.maxItems { XCTAssertTrue(store.add(item(.note, nil, title: "n\(i)", text: "t\(i)"), to: c.id)) }
        XCTAssertFalse(store.add(item(.note, nil, title: "one too many", text: "x"), to: c.id))
        XCTAssertEqual(store.collections[0].items.count, ResearchStore.maxItems)
    }

    // MARK: Exports

    func testExportsCarryTheCommentTheTagsAndTheSavedDate() throws {
        var h = item(.highlight, text: "The passage"); h.comment = "why it matters"; h.tags = ["to-do", "work"]; h.captured = Date(timeIntervalSince1970: 1_760_000_000)
        let collection = ResearchCollection(name: "Notes [draft]", items: [h])
        let md = ResearchExport.markdown(collection)
        XCTAssertTrue(md.contains("Comment: why it matters"))
        XCTAssertTrue(md.contains("Tags: #to-do #work"))
        XCTAssertTrue(md.contains("Saved: 9 October 2025"))
        let html = ResearchExport.html(collection)
        XCTAssertTrue(html.contains("why it matters") && html.contains("#to-do") && html.contains("9 October 2025"))
    }

    func testMarkdownLinksAreOnlyWebAddressesAndTextCannotMakeLinks() {
        XCTAssertEqual(ResearchExport.mdLink("Click", "javascript:alert(1)"), "Click", "not a link")
        XCTAssertEqual(ResearchExport.mdLink("Click", "file:///etc/passwd"), "Click")
        XCTAssertEqual(ResearchExport.mdLink("A [b](c)", "https://x.test/a b(1)"), "[A \\[b\\](c)](https://x.test/a%20b%281%29)")
        XCTAssertEqual(ResearchExport.mdText("# Heading\nsecond *line*"), "\\# Heading second \\*line\\*")
    }

    func testFileNamesFromCollectionNamesCannotEscapeOrHide() {
        XCTAssertEqual(ResearchExport.fileStem("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ResearchExport.fileStem(".hidden"), "hidden")
        XCTAssertEqual(ResearchExport.fileStem("a:b*c?"), "a-b-c")
        XCTAssertEqual(ResearchExport.fileStem("   "), "Research")
        XCTAssertEqual(ResearchExport.fileStem(String(repeating: "x", count: 300)).count, 80)
    }

    func testControlCharactersCannotBreakTheEnexFile() throws {
        let nasty = item(.note, nil, title: "bad\u{0}title\u{1B}", text: "line\u{7}one")
        let enex = ResearchExport.enex(ResearchCollection(name: "C\u{0}", items: [nasty]))
        XCTAssertFalse(enex.unicodeScalars.contains { $0.value < 0x20 && ![0x9, 0xA, 0xD].contains($0.value) })
        let parser = XMLParser(data: Data(enex.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "")
    }
}
