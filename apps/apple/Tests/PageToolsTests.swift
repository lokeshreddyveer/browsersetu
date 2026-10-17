import XCTest
@testable import Browser_Setu

final class PageToolsTests: XCTestCase {
    func testCSVQuotesCommasQuotesAndLineBreaks() {
        let csv = TableCSV.encode([["Name", "Note"], ["A, B", "say \"hi\""], ["C", "two\nlines"]])
        XCTAssertEqual(csv, "Name,Note\n\"A, B\",\"say \"\"hi\"\"\"\nC,\"two\nlines\"")
    }

    func testExtractParsesAndSkipsEmpties() {
        let raw: [String: Any] = [
            "images": [["url": "https://a.test/x.png", "alt": "x", "w": 300, "h": 200], ["url": "", "alt": "", "w": 1, "h": 1]],
            "tables": [["caption": "T", "rows": [["a", "b"], ["1", 2]]], ["caption": "", "rows": []]],
            "documents": [["url": "https://a.test/f.pdf", "title": "F", "kind": "pdf"]],
            "headings": [["level": 1, "text": "Intro"], ["level": 2, "text": ""]],
        ]
        let extract = PageExtract(raw: raw)
        XCTAssertEqual(extract.images.count, 1)
        XCTAssertEqual(extract.tables.count, 1)
        XCTAssertEqual(extract.tables[0].rows[1], ["1", "2"])
        XCTAssertEqual(extract.documents.first?.kind, "pdf")
        XCTAssertEqual(extract.headings.count, 1)
    }
}
