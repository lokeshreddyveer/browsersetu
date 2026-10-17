import XCTest
import PDFKit
import CoreText
@testable import Browser_Setu

final class PDFEditTests: XCTestCase {
    /// A small PDF with one line of real text on each page.
    private func makePDF(pages words: [String]) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for word in words {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]))
            context.textPosition = CGPoint(x: 40, y: 400)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    private func roundTrip(_ document: PDFDocument) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfedit-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        return try XCTUnwrap(PDFDocument(url: url))
    }

    func testPagesRotateMoveDeleteExtractAndMerge() throws {
        let d = makePDF(pages: ["alpha", "bravo", "charlie"])
        PDFEdit.rotate(d, pages: [0], by: 90); XCTAssertEqual(d.page(at: 0)?.rotation, 90)
        PDFEdit.rotate(d, pages: [0], by: -180); XCTAssertEqual(d.page(at: 0)?.rotation, 270, "turning keeps a value in 0...359")
        PDFEdit.rotate(d, pages: [9, -1], by: 90)                                         // outside the document: ignored
        PDFEdit.move(d, from: 2, to: 0); XCTAssertEqual(d.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "charlie")
        XCTAssertEqual(PDFEdit.delete(d, pages: [1, 99]), 1); XCTAssertEqual(d.pageCount, 2)
        XCTAssertEqual(PDFEdit.delete(d, pages: [0, 1]), 0, "the last page can never be removed"); XCTAssertEqual(d.pageCount, 2)
        let part = try XCTUnwrap(PDFEdit.extract(makePDF(pages: ["a", "b", "c", "d"]), from: 2, to: 3)); XCTAssertEqual(part.pageCount, 2)
        XCTAssertNil(PDFEdit.extract(d, from: 5, to: 6)); XCTAssertNil(PDFEdit.extract(d, from: 0, to: 1))
        PDFEdit.append(makePDF(pages: ["x", "y"]), to: d); XCTAssertEqual(d.pageCount, 4)
    }

    func testPageRangesAreReadForgivingly() {
        XCTAssertEqual(PDFEdit.parseRange("1-3, 5, 8-", pageCount: 9), [1, 2, 3, 5, 8, 9])
        XCTAssertEqual(PDFEdit.parseRange("-2", pageCount: 5), [1, 2])
        XCTAssertEqual(PDFEdit.parseRange("0, 7, 3-1, x", pageCount: 5), [], "outside, backwards and nonsense give nothing")
        XCTAssertEqual(PDFEdit.parseRange("2,2,2", pageCount: 5), [2])
    }

    func testMarksTextShapesAndInkSurviveSavingAndReopening() throws {
        let d = makePDF(pages: ["Hello brave new world"])
        let page = try XCTUnwrap(d.page(at: 0))
        let selection = try XCTUnwrap(d.findString("brave", withOptions: []).first)
        XCTAssertEqual(PDFEdit.mark(selection, type: .highlight, color: .yellow), 1)
        XCTAssertEqual(PDFEdit.mark(selection, type: .underline, color: .red), 1)
        XCTAssertNotNil(PDFEdit.addText("Check this", on: page, at: CGPoint(x: 50, y: 300)))
        XCTAssertNil(PDFEdit.addText("   ", on: page, at: CGPoint(x: 50, y: 300)), "an empty box is not added")
        XCTAssertNotNil(PDFEdit.addShape(.square, in: CGRect(x: 60, y: 200, width: 80, height: 40), on: page))
        XCTAssertNil(PDFEdit.addShape(.square, in: CGRect(x: 60, y: 200, width: 1, height: 1), on: page))
        XCTAssertNotNil(PDFEdit.addInk([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40), CGPoint(x: 90, y: 20)], on: page))
        XCTAssertNil(PDFEdit.addInk([CGPoint(x: 10, y: 10)], on: page), "one point is not a line")
        let reopened = try roundTrip(d)
        let types = Set((reopened.page(at: 0)?.annotations ?? []).compactMap(\.type))
        XCTAssertTrue(types.isSuperset(of: ["Highlight", "Underline", "FreeText", "Square", "Ink"]), "marks are real annotations in the file: \(types)")
    }

    func testADrawnSignatureBecomesLinesThatStayInsideItsBoxAndATypedOneBecomesText() throws {
        let d = makePDF(pages: ["Sign here"])
        let page = try XCTUnwrap(d.page(at: 0))
        let drawn = PDFEdit.Signature.normalized([[CGPoint(x: 5, y: 5), CGPoint(x: 40, y: 60), CGPoint(x: 80, y: 20)], [CGPoint(x: 10, y: 30), CGPoint(x: 70, y: 32)]])
        XCTAssertTrue(drawn.strokes.flatMap { $0 }.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }, "scaled into the unit square")
        let box = CGRect(x: 100, y: 100, width: 150, height: 50)
        XCTAssertEqual(PDFEdit.place(drawn, in: box, on: page), 2)
        for a in page.annotations { XCTAssertTrue(box.insetBy(dx: -8, dy: -8).contains(a.bounds), "inside its box: \(a.bounds)") }
        XCTAssertEqual(PDFEdit.place(PDFEdit.Signature(strokes: [], typed: "Lokesh"), in: box, on: page), 1)
        XCTAssertEqual(PDFEdit.place(PDFEdit.Signature(strokes: []), in: box, on: page), 0, "nothing drawn, nothing placed")
        XCTAssertEqual(PDFEdit.place(drawn, in: CGRect(x: 0, y: 0, width: 2, height: 2), on: page), 0, "a box too small is refused")
        XCTAssertEqual(try JSONDecoder().decode(PDFEdit.Signature.self, from: JSONEncoder().encode(drawn)), drawn, "it can be stored as text")
    }

    func testAPictureSignatureChangesOnlyItsOwnPage() throws {
        let d = makePDF(pages: ["one", "two"])
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(PDFEdit.burnImage(image, in: CGRect(x: 100, y: 100, width: 120, height: 40), onPageAt: 1, of: d))
        XCTAssertEqual(d.pageCount, 2)
        XCTAssertEqual(d.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "one", "the other page is untouched")
        XCTAssertFalse(PDFEdit.burnImage(image, in: CGRect(x: 100, y: 100, width: 120, height: 40), onPageAt: 9, of: d))
    }

    func testRedactionRemovesTheWordsFromTheFileNotJustFromView() throws {
        let d = makePDF(pages: ["secret-number-4242", "keep-this-page"])
        XCTAssertTrue(d.page(at: 0)?.string?.contains("4242") == true)
        let found = try XCTUnwrap(d.findString("4242", withOptions: []).first)
        let rect = found.bounds(for: try XCTUnwrap(d.page(at: 0))).insetBy(dx: -4, dy: -4)
        XCTAssertTrue(PDFEdit.redact([rect], onPageAt: 0, of: d))
        let reopened = try roundTrip(d)
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertFalse((reopened.page(at: 0)?.string ?? "").contains("4242"), "the words are gone from the file")
        XCTAssertTrue(reopened.findString("4242", withOptions: []).isEmpty, "and cannot be searched for")
        XCTAssertTrue((reopened.page(at: 1)?.string ?? "").contains("keep-this-page"), "other pages keep their text")
        XCTAssertFalse(PDFEdit.redact([], onPageAt: 0, of: d)); XCTAssertFalse(PDFEdit.redact([rect], onPageAt: 5, of: d))
    }

    func testAPasswordProtectedCopyNeedsThePassword() throws {
        let d = makePDF(pages: ["private"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prot-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PDFEdit.writeProtected(d, to: url, password: "correct horse"))
        XCTAssertTrue(PDFDocument(url: url)?.isLocked == true)
        XCTAssertNil(PDFEdit.open(url, password: nil)); XCTAssertNil(PDFEdit.open(url, password: "wrong"))
        XCTAssertEqual(PDFEdit.open(url, password: "correct horse")?.pageCount, 1)
        XCTAssertFalse(PDFEdit.writeProtected(d, to: url, password: ""), "an empty password protects nothing")
    }

    func testASavedCopyNeverTakesAnExistingName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("form.pdf")
        let first = PDFEdit.copyURL(for: source, suffix: "signed"); XCTAssertEqual(first.lastPathComponent, "form signed.pdf")
        try Data("x".utf8).write(to: first)
        XCTAssertEqual(PDFEdit.copyURL(for: source, suffix: "signed").lastPathComponent, "form signed 2.pdf")
    }
}
