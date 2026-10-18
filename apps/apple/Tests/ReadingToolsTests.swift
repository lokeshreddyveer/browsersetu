import XCTest
@testable import Browser_Setu

final class ReadingToolsTests: XCTestCase {
    private let article = ReadableArticle(title: "On Bees", site: "bees.org", blocks: [.heading(2, "Hives"), .paragraph("Honey is made in the hive."), .listItem("wax")])

    func testStyleCSSReflectsEveryChoice() {
        var s = ReaderStyle()
        s.size = 24; s.theme = .sepia; s.width = .wide; s.family = .mono; s.lineSpacing = 1.85; s.letterSpacing = 0.05
        let css = s.css
        XCTAssertTrue(css.contains("24px/1.85"))
        XCTAssertTrue(css.contains("#f4ecd8"))
        XCTAssertTrue(css.contains("max-width: 840px"))
        XCTAssertTrue(css.contains("ui-monospace"))
        XCTAssertTrue(css.contains("letter-spacing: 0.05em"))
        XCTAssertTrue(css.contains("color-scheme: light"))
    }

    func testStyleIsClamped() {
        var s = ReaderStyle(); s.size = 200; s.lineSpacing = 9; s.letterSpacing = 3
        let c = s.clamped()
        XCTAssertEqual(c.size, ReaderStyle.sizeRange.upperBound)
        XCTAssertEqual(c.lineSpacing, 2.4)
        XCTAssertEqual(c.letterSpacing, 0.12)
    }

    func testPageUsesTheGivenStyleAndStillMarksHighlights() {
        var s = ReaderStyle(); s.theme = .black
        let html = ReaderHTML.page(for: article, highlights: ["Honey"], style: s)
        XCTAssertTrue(html.contains("#000000"))
        XCTAssertTrue(html.contains("<mark>"))
        XCTAssertTrue(html.contains("default-src 'none'"), "the page still runs no scripts")
    }

    func testStyleRoundTripsThroughJSON() throws {
        var s = ReaderStyle(); s.family = .rounded; s.size = 22
        XCTAssertEqual(try JSONDecoder().decode(ReaderStyle.self, from: JSONEncoder().encode(s)), s)
    }

    func testCitationStyles() {
        let date = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14 UTC
        let apa = PageCitation.format(title: "On Bees", site: "bees.org", url: "https://bees.org/a", accessed: date, style: .apa)
        XCTAssertTrue(apa.hasPrefix("bees.org. (n.d.). On Bees. Retrieved "))
        XCTAssertTrue(apa.hasSuffix("from https://bees.org/a"))
        let mla = PageCitation.format(title: "On Bees", site: "bees.org", url: "https://bees.org/a", accessed: date, style: .mla)
        XCTAssertTrue(mla.hasPrefix("“On Bees.” bees.org, n.d., https://bees.org/a. Accessed "))
        XCTAssertEqual(PageCitation.format(title: "T", site: "", url: "https://x.y", style: .plain), "T — https://x.y — https://x.y")
    }

    func testLanguageDetection() {
        XCTAssertEqual(LanguageDetector.detect("Der schnelle braune Fuchs springt über den faulen Hund und läuft durch den Wald.")?.code, "de")
        XCTAssertEqual(LanguageDetector.detect("The quick brown fox jumps over the lazy dog and runs through the forest today.")?.code, "en")
        XCTAssertNil(LanguageDetector.detect("hi"))
    }

    func testSearchFindsTitleHighlightsAndArticleText() {
        var item = ReadingItem(url: "https://bees.org/a", title: "On Bees", site: "bees.org")
        item.highlights = ["waggle dance"]
        XCTAssertTrue(ReadingSearch.matches(item, article: nil, query: "bees"))
        XCTAssertTrue(ReadingSearch.matches(item, article: nil, query: "WAGGLE"))
        XCTAssertFalse(ReadingSearch.matches(item, article: nil, query: "honey"))
        XCTAssertTrue(ReadingSearch.matches(item, article: article, query: "honey"))
        XCTAssertTrue(ReadingSearch.matches(item, article: nil, query: "  "))
    }

    func testProgressLabels() {
        XCTAssertNil(ReadingSearch.progressLabel(nil))
        XCTAssertNil(ReadingSearch.progressLabel(0.01))
        XCTAssertEqual(ReadingSearch.progressLabel(0.4), "40% read")
        XCTAssertEqual(ReadingSearch.progressLabel(0.99), "finished")
    }
}
