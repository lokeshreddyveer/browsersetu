import XCTest
@testable import Browser_Setu

/// Research: tags, the same page found again however its address is written, one flow that saves together, and exports other note applications read.
@MainActor
final class ResearchNotesTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-research-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    func testTheSamePageIsRecognisedWhateverTheTrackingOrTheWwwOrTheSlash() {
        let a = ResearchURL.normalize("https://www.Example.com/article/?utm_source=x&id=7#comments")
        for same in ["http://example.com/article?id=7", "https://example.com:443/article/?id=7&fbclid=abc", "HTTPS://EXAMPLE.COM/article?gclid=1&id=7"] { XCTAssertEqual(ResearchURL.normalize(same), a, same) }
        XCTAssertNotEqual(ResearchURL.normalize("https://example.com/article?id=8"), a, "a real parameter makes it another page")
        XCTAssertNotEqual(ResearchURL.normalize("https://example.com/other?id=7"), a)
        XCTAssertNotEqual(ResearchURL.normalize("https://sub.example.com/article?id=7"), a, "another host is another page")
        XCTAssertEqual(ResearchURL.normalize("https://example.com/"), ResearchURL.normalize("https://www.example.com"))
    }

    func testTagsAreCleanedLimitedAndNeverRepeated() {
        XCTAssertEqual(ResearchTags.parse("Reading, to do; #Work\nwork,  ,  big idea!"), ["reading", "to-do", "work", "big-idea"])
        XCTAssertEqual(ResearchTags.parse((1...20).map { "t\($0)" }.joined(separator: ",")).count, ResearchTags.maxPerItem)
        XCTAssertLessThanOrEqual(ResearchTags.parse(String(repeating: "a", count: 100)).first?.count ?? 0, ResearchTags.maxLength)
        XCTAssertEqual(ResearchTags.parse(" , ;; "), [])
    }

    func testSavingTheSamePageAgainUpdatesTheOneEntryAndKeepsItsTagsAcrossCollections() async throws {
        let m = await model()
        let a = try XCTUnwrap(m.research.create(name: "First"))
        let b = try XCTUnwrap(m.research.create(name: "Second"))
        var first = ResearchItem(kind: .page, title: "Article", url: "https://www.example.com/article?utm_source=mail", text: nil)
        first.tags = ["keep"]; first.captured = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(m.research.add(first, to: a.id))
        XCTAssertTrue(m.research.add(ResearchItem(kind: .page, title: "Article (new title)", url: "https://example.com/article/#top", text: nil), to: a.id))
        let items = try XCTUnwrap(m.research.collections.first { $0.id == a.id }?.items)
        XCTAssertEqual(items.count, 1, "one entry, not two")
        XCTAssertEqual(items[0].title, "Article (new title)")
        XCTAssertEqual(items[0].tags, ["keep"], "what the person added is kept")
        let found = try XCTUnwrap(m.research.duplicate(ofURL: "http://example.com/article?fbclid=1"))
        XCTAssertEqual(found.collection.name, "First", "found across collections")
        XCTAssertNil(m.research.duplicate(ofURL: "https://example.com/different"))
        XCTAssertNil(m.research.duplicate(ofURL: nil))
        _ = b
    }

    func testOneFlowSavesThePageThePassageAndTheNoteTogetherWithOneCaptureTimeAndTags() async throws {
        let m = await model()
        let collection = try XCTUnwrap(m.research.create(name: "Reading"))
        var draft = ResearchDraft(pageTitle: "Great Article", url: "https://example.com/a", citation: nil, captured: Date(timeIntervalSince1970: 5_000))
        draft.selection = "The important passage."
        draft.comment = "Why it matters"
        draft.note = "Follow up next week."
        draft.tags = "Reading, to do"
        draft.collectionID = collection.id
        XCTAssertEqual(m.saveResearchDraft(draft), 3)
        let items = try XCTUnwrap(m.research.collections.first { $0.id == collection.id }?.items)
        XCTAssertEqual(Set(items.map(\.kind.rawValue)), ["page", "highlight", "note"])
        XCTAssertTrue(items.allSatisfy { $0.tags == ["reading", "to-do"] && $0.captured == Date(timeIntervalSince1970: 5_000) && $0.url == "https://example.com/a" })
        XCTAssertEqual(items.first { $0.kind == .highlight }?.text, "The important passage.")
        XCTAssertEqual(items.first { $0.kind == .highlight }?.comment, "Why it matters")
        // Only what was ticked is saved.
        var onlyNote = draft; onlyNote.includePage = false; onlyNote.includeSelection = false; onlyNote.url = "https://example.com/b"
        XCTAssertEqual(m.saveResearchDraft(onlyNote), 1)
    }

    func testAPrivateTabIsNeverMadeIntoADraftOrSaved() async throws {
        let m = await model()
        _ = m.research.create(name: "R")
        let tab = m.openTab(url: nil, isPrivate: true)
        tab.url = URL(string: "https://example.com/secret")
        let draft = await m.researchDraftForActivePage()
        XCTAssertNil(draft, "nothing is read from a private tab")
        XCTAssertTrue(m.research.collections.flatMap(\.items).isEmpty)
        await m.addPageToResearch()
        XCTAssertTrue(m.research.collections.flatMap(\.items).isEmpty, "and the older buttons refuse it too")
    }

    func testOldSavedItemsStillOpenAndTagsSurviveSaving() throws {
        let old = #"{"id":"6F1C9F52-3B3A-4B52-9E6B-0A1B2C3D4E5F","kind":"page","title":"Old","url":"https://example.com","added":0}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(old.utf8))
        XCTAssertEqual(item.tags, []); XCTAssertNil(item.captured)
        var tagged = item; tagged.tags = ["a", "b"]; tagged.captured = Date(timeIntervalSince1970: 42)
        let again = try JSONDecoder().decode(ResearchItem.self, from: JSONEncoder().encode(tagged))
        XCTAssertEqual(again.tags, ["a", "b"]); XCTAssertEqual(again.captured, Date(timeIntervalSince1970: 42))
    }

    private func sampleCollection() -> ResearchCollection {
        var page = ResearchItem(kind: .page, title: "A \"quoted\" <Page> & more", url: "https://example.com/p?x=1&y=2", text: nil)
        page.tags = ["reading", "to-do"]; page.captured = Date(timeIntervalSince1970: 1_760_000_000)
        var highlight = ResearchItem(kind: .highlight, title: "A \"quoted\" <Page> & more", url: "https://example.com/p", text: "Line one\nLine two ]]> end", comment: "My comment")
        highlight.tags = ["reading"]
        var note = ResearchItem(kind: .note, title: "Idea: a/b*c?", url: nil, text: "Just a note")
        note.captured = Date(timeIntervalSince1970: 1_760_000_100)
        var duplicateName = note; duplicateName.id = UUID()
        return ResearchCollection(name: "Work / Reading", items: [page, highlight, note, duplicateName])
    }

    func testTheEnexExportIsWellFormedXMLThatKeepsTitlesTagsTimesAndSources() throws {
        let enex = ResearchExport.enex(sampleCollection(), now: Date(timeIntervalSince1970: 1_761_000_000))
        final class Checker: NSObject, XMLParserDelegate {
            var titles: [String] = [], tags: [String] = [], created: [String] = [], sources: [String] = [], current = "", cdata = 0
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { current = ""; if name == "note" { } }
            func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }
            func parser(_ parser: XMLParser, foundCDATA data: Data) { cdata += 1 }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name { case "title": titles.append(current); case "tag": tags.append(current); case "created": created.append(current); case "source-url": sources.append(current); default: break }
            }
        }
        let checker = Checker()
        let parser = XMLParser(data: Data(enex.utf8)); parser.delegate = checker
        parser.shouldResolveExternalEntities = false
        XCTAssertTrue(parser.parse(), "well-formed: \(parser.parserError?.localizedDescription ?? "")")
        XCTAssertEqual(checker.titles.count, 4)
        XCTAssertEqual(checker.titles[0], "A \"quoted\" <Page> & more", "special characters survive")
        XCTAssertEqual(checker.tags, ["reading", "to-do", "reading"])
        XCTAssertEqual(checker.created[0], "20251009T085320Z")
        XCTAssertEqual(checker.sources, ["https://example.com/p?x=1&y=2", "https://example.com/p"])
        XCTAssertEqual(checker.cdata, 4, "each note's content is CDATA")
        XCTAssertFalse(enex.contains("]]> end"), "text containing the CDATA terminator cannot break out")
    }

    func testTheNotesFolderHasOneSafelyNamedFilePerItemWithDetailsAtTheTop() {
        let files = ResearchExport.noteFiles(sampleCollection())
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(Set(files.map { $0.name.lowercased() }).count, 4, "no two files share a name")
        for file in files { XCTAssertTrue(file.name.hasSuffix(".md")); XCTAssertFalse(file.name.contains("/") || file.name.contains(":") || file.name.contains("*") || file.name.contains("?"), file.name) }
        let page = files[0].text
        XCTAssertTrue(page.hasPrefix("---\ntitle: \"A \\\"quoted\\\" <Page> & more\"\nsource: \"https://example.com/p?x=1&y=2\"\ncaptured: "))
        XCTAssertTrue(page.contains("tags: [reading, to-do]\n---\n"))
        XCTAssertTrue(page.contains("collection: \"Work / Reading\""))
        XCTAssertTrue(files[1].text.contains("> Line one\n> Line two ]]> end"))
        XCTAssertTrue(files[2].text.contains("type: note"))
        XCTAssertFalse(files[2].text.contains("source:"), "a note with no address has no source line")
    }

    func testTheExportsArePlainFilesTheStoreNeverReachesTheNetworkAndNothingIsAutomatic() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Shared/ResearchNotes.swift"), encoding: .utf8)
        for forbidden in ["URLSession", "NWConnection", "NSWorkspace", "UIApplication"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        XCTAssertTrue(ResearchFormat.allCases.map(\.rawValue).contains("enex") && ResearchFormat.allCases.map(\.rawValue).contains("notes"))
    }
}
