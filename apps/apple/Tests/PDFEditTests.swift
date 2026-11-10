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

/// Safe writing, splitting, pictures to PDF, reordering and Undo, and a set of files written for an independent reader (see scripts/verify-pdf-with-ghostscript.sh).
@MainActor
final class PDFOperationsTests: XCTestCase {
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

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfops-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ width: Int, _ height: Int, color: CGColor) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testAWriteIsCheckedBeforeItReplacesAnythingAndAFailureLeavesTheOldFileAlone() throws {
        let dir = folder()
        let target = dir.appendingPathComponent("out.pdf")
        let old = Data("not a real pdf but the old contents".utf8)
        try old.write(to: target)
        let document = makePDF(pages: ["one", "two"])
        XCTAssertFalse(PDFEdit.writeValidated(document, to: target, validate: { _ in false }), "a check that fails stops the replacement")
        XCTAssertEqual(try Data(contentsOf: target), old, "the existing file is exactly as it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".writing.pdf") }.count, 0, "no temporary file is left")
        XCTAssertTrue(PDFEdit.writeValidated(document, to: target))
        XCTAssertEqual(PDFDocument(url: target)?.pageCount, 2, "now it is the new, checked file")
        XCTAssertFalse(PDFEdit.writeValidated(PDFDocument(), to: dir.appendingPathComponent("empty.pdf")), "a document with no pages is never written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("empty.pdf").path))
        // The same for a protected copy: it is opened with its password to check it.
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(PDFEdit.writeValidated(document, to: locked, password: "pw-\(UUID().uuidString.prefix(6))"))
        XCTAssertTrue(PDFDocument(url: locked)?.isLocked ?? false)
    }

    func testTheOriginalFileIsNeverTouchedByASavedCopy() throws {
        let dir = folder()
        let source = dir.appendingPathComponent("original.pdf")
        XCTAssertTrue(makePDF(pages: ["a", "b", "c"]).write(to: source))
        let before = try Data(contentsOf: source)
        let session = PDFEditorSession(source: source)
        let all = PDFEdit.pages(of: try XCTUnwrap(session.document))
        XCTAssertEqual(session.remove([all[1]]), 1)
        let copy = try XCTUnwrap(session.saveCopy())
        XCTAssertEqual(PDFDocument(url: copy)?.pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is byte for byte the same")
        XCTAssertNotEqual(copy, source)
    }

    func testSplitMakesTheRightPartsAndEachIsWrittenChecked() throws {
        let doc = makePDF(pages: ["1", "2", "3", "4", "5"])
        XCTAssertEqual(PDFEdit.split(doc, everyPages: 2).map(\.pageCount), [2, 2, 1])
        XCTAssertEqual(PDFEdit.split(doc, after: [1, 4]).map(\.pageCount), [1, 3, 1])
        XCTAssertEqual(PDFEdit.split(doc, after: []).map(\.pageCount), [5], "nothing to cut at is one part")
        XCTAssertEqual(PDFEdit.split(doc, after: [5, 9, 0]).map(\.pageCount), [5], "cuts outside the document are ignored")
        XCTAssertEqual(PDFEdit.split(doc, ranges: [2...3, 9...12]).map(\.pageCount), [2], "a range outside is skipped")
        XCTAssertTrue(PDFEdit.split(doc, everyPages: 0).isEmpty)
        let dir = folder()
        let source = dir.appendingPathComponent("book.pdf")
        XCTAssertTrue(doc.write(to: source))
        let files = PDFEdit.writeParts(PDFEdit.split(doc, everyPages: 2), beside: source)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.map { PDFDocument(url: $0)?.pageCount }, [2, 2, 1])
        XCTAssertEqual(Set(files.map(\.lastPathComponent)).count, 3)
        XCTAssertEqual(PDFDocument(url: files[0])?.page(at: 0)?.string?.contains("1"), true)
        XCTAssertEqual(PDFDocument(url: files[2])?.page(at: 0)?.string?.contains("5"), true)
    }

    func testPicturesBecomePagesTheSizeOfThemAndABadOneStopsTheWholeThing() throws {
        let dir = folder()
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try png(300, 200, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)).write(to: a)
        try png(100, 400, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)).write(to: b)
        let doc = try XCTUnwrap(PDFEdit.imagesToPDF(urls: [a, b]))
        XCTAssertEqual(doc.pageCount, 2)
        let first = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox), second = try XCTUnwrap(doc.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 300, accuracy: 1); XCTAssertEqual(first.height, 200, accuracy: 1)
        XCTAssertEqual(second.width, 100, accuracy: 1); XCTAssertEqual(second.height, 400, accuracy: 1)
        let bad = dir.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to: bad)
        XCTAssertNil(PDFEdit.imagesToPDF(urls: [a, bad]), "one unreadable picture means no half-made PDF")
        XCTAssertNil(PDFEdit.imagesToPDF(urls: []))
        // A very large picture is brought down to a sensible size.
        let big = dir.appendingPathComponent("big.png"); try png(6000, 3000, color: CGColor(gray: 0.5, alpha: 1)).write(to: big)
        let huge = try XCTUnwrap(PDFEdit.imagesToPDF(urls: [big]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(huge.page(at: 0)).bounds(for: .mediaBox).width, 843)
    }

    func testReorderRotateRemoveAndAddPicturesAreAllUndoneByUndo() throws {
        let dir = folder()
        let source = dir.appendingPathComponent("doc.pdf")
        XCTAssertTrue(makePDF(pages: ["A", "B", "C"]).write(to: source))
        let session = PDFEditorSession(source: source)
        let document = try XCTUnwrap(session.document)
        let original = PDFEdit.pages(of: document)
        func text() -> [String] { PDFEdit.pages(of: document).map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } }
        XCTAssertEqual(text(), ["A", "B", "C"])
        XCTAssertTrue(session.reorder(to: [original[2], original[0], original[1]]))
        XCTAssertEqual(text(), ["C", "A", "B"])
        session.undo()
        XCTAssertEqual(text(), ["A", "B", "C"], "undo puts the order back")
        XCTAssertFalse(session.reorder(to: [original[0]]), "not the same set of pages: refused")
        session.rotate([original[1]], by: 90)
        XCTAssertEqual(original[1].rotation, 90)
        session.undo()
        XCTAssertEqual(original[1].rotation, 0)
        XCTAssertEqual(session.remove([original[0], original[2]]), 2)
        XCTAssertEqual(text(), ["B"])
        XCTAssertEqual(session.remove([original[1]]), 0, "never the last page")
        session.undo()
        XCTAssertEqual(text(), ["A", "B", "C"], "removed pages come back where they were")
        let image = dir.appendingPathComponent("p.png"); try png(50, 50, color: CGColor(gray: 0, alpha: 1)).write(to: image)
        XCTAssertEqual(session.appendPictures([image]), 1)
        XCTAssertEqual(document.pageCount, 4)
        session.undo()
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(session.changes, 0)
    }

    /// Files for an independent reader: written to a folder named in the test output, then checked by scripts/verify-pdf-with-ghostscript.sh.
    func testWriteFilesForAnIndependentReader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-pdf-artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = makePDF(pages: ["alpha", "bravo", "charlie", "delta"])
        let source = dir.appendingPathComponent("source.pdf")
        XCTAssertTrue(PDFEdit.writeValidated(doc, to: source))
        let session = PDFEditorSession(source: source)
        let pages = PDFEdit.pages(of: try XCTUnwrap(session.document))
        XCTAssertTrue(session.reorder(to: [pages[3], pages[2], pages[1], pages[0]]))
        session.rotate([pages[0]], by: 90)
        _ = session.remove([pages[1]])
        XCTAssertNotNil(session.saveCopy(suffix: "organized"))
        let parts = PDFEdit.writeParts(PDFEdit.split(try XCTUnwrap(session.document), everyPages: 1), beside: source)
        XCTAssertEqual(parts.count, 3)
        let image = dir.appendingPathComponent("p.png"); try png(240, 160, color: CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1)).write(to: image)
        XCTAssertTrue(PDFEdit.writeValidated(try XCTUnwrap(PDFEdit.imagesToPDF(urls: [image])), to: dir.appendingPathComponent("from-picture.pdf")))
        print("PDF ARTIFACTS \(dir.path)")
    }
}
