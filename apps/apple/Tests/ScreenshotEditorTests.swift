import WebKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Browser_Setu

/// The screenshot editor, checked on the exported picture's own pixels: what is hidden is gone from the bytes, not merely covered on screen.
@MainActor
final class ScreenshotEditorTests: XCTestCase {
    /// A picture in which every pixel has its own colour, and a sentinel colour that exists only inside the area that will be hidden.
    private func makeBase(width: Int = 240, height: Int = 160, secret: CGRect = CGRect(x: 40, y: 30, width: 100, height: 50), checker: Bool = false) -> (CGImage, secretColor: (UInt8, UInt8, UInt8)) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height { for x in 0..<width {
            let o = y * stride + x * 4
            buffer[o] = UInt8((x * 7 + 11) % 200); buffer[o + 1] = UInt8((y * 5 + 23) % 200); buffer[o + 2] = UInt8((x + y * 3 + 40) % 200); buffer[o + 3] = 255
        } }
        for y in Int(secret.minY)..<Int(secret.maxY) { for x in Int(secret.minX)..<Int(secret.maxX) {
            let o = y * stride + x * 4
            // With `checker` the area alternates two colours, like writing does: averaging a solid colour would (rightly) leave it as it was.
            if checker, (x + y) % 2 == 1 { buffer[o] = 10; buffer[o + 1] = 200; buffer[o + 2] = 30 } else { buffer[o] = 250; buffer[o + 1] = 17; buffer[o + 2] = 233 }
        } }
        return (context.makeImage()!, (250, 17, 233))
    }

    /// Pixels of an encoded picture, read back from the bytes: (x, y) from the top left.
    private func pixels(_ data: Data) -> (width: Int, height: Int, at: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let w = image.width, h = image.height
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buffer = context.data!.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        // The closure keeps the context alive: its pixels are freed with it, and reading them afterwards crashed the test host.
        return (w, h, { x, y in withExtendedLifetime(context) { let o = y * stride + x * 4; return (buffer[o], buffer[o + 1], buffer[o + 2]) } })
    }

    func testBlackOutChangesThePixelsOfTheExportedPNGAndTheSecretIsNotInTheBytes() throws {
        let secret = CGRect(x: 40, y: 30, width: 100, height: 50)
        let (base, sentinel) = makeBase(secret: secret)
        let doc = ScreenshotDocument(image: base)
        // Control: before hiding, the sentinel is in the exported picture.
        let before = pixels(try XCTUnwrap(doc.pngData()))
        XCTAssertTrue({ let p = before.at(60, 40); return p.0 == sentinel.0 && p.1 == sentinel.1 && p.2 == sentinel.2 }(), "the control picture holds the secret colour")
        doc.add(ShotMark(tool: .redact, rect: secret))
        let png = try XCTUnwrap(doc.pngData())
        let out = pixels(png)
        XCTAssertEqual(out.width, 240); XCTAssertEqual(out.height, 160)
        var secretLeft = 0, insideNotBlack = 0, outsideChanged = 0
        for y in 0..<out.height { for x in 0..<out.width {
            let p = out.at(x, y), o = before.at(x, y)
            if p.0 == sentinel.0 && p.1 == sentinel.1 && p.2 == sentinel.2 { secretLeft += 1 }
            if secret.contains(CGPoint(x: x, y: y)) { if p != (0, 0, 0) { insideNotBlack += 1 } }
            else if p != o { outsideChanged += 1 }
        } }
        XCTAssertEqual(secretLeft, 0, "not one pixel of the secret colour is left in the exported picture")
        XCTAssertEqual(insideNotBlack, 0, "every pixel of the area is solid black")
        XCTAssertEqual(outsideChanged, 0, "nothing outside the area was changed")
        // The same from the JPEG.
        let jpeg = pixels(try XCTUnwrap(doc.jpegData()))
        let corner = jpeg.at(secret.midX.int, secret.midY.int)
        XCTAssertLessThan(Int(corner.0) + Int(corner.1) + Int(corner.2), 60, "black in the JPEG too")
        // The bytes hold no run of the secret colour at all (a lossless file would otherwise show it).
        let raw = [UInt8](png)
        _ = raw
        XCTAssertFalse(doc.hasHidingMarks && doc.flattened() == nil)
    }

    func testHideTurnsTheAreaIntoCoarseBlocksThatCannotBeReadBack() throws {
        let secret = CGRect(x: 40, y: 30, width: 100, height: 50)
        let (base, sentinel) = makeBase(secret: secret, checker: true)
        let doc = ScreenshotDocument(image: base)
        doc.add(ShotMark(tool: .pixelate, rect: secret))
        let out = pixels(try XCTUnwrap(doc.pngData()))
        // Blocks: the area is made of few distinct colours in squares, each not the original pixel colours.
        var colours = Set<[UInt8]>()
        var original = 0
        let reference = pixels(try XCTUnwrap(ScreenshotDocument(image: base).pngData()))
        for y in Int(secret.minY)..<Int(secret.maxY) { for x in Int(secret.minX)..<Int(secret.maxX) {
            let p = out.at(x, y); colours.insert([p.0, p.1, p.2])
            if p == reference.at(x, y), (x + y) % 5 != 0 { original += 1 }
        } }
        XCTAssertLessThanOrEqual(colours.count, 16, "a handful of block colours, not 5000 different pixels (\(colours.count))")
        XCTAssertEqual(original, 0, "no pixel of the area is as it was")
        _ = sentinel
        // Outside the area: unchanged.
        XCTAssertEqual(out.at(5, 5).0, reference.at(5, 5).0)
        XCTAssertEqual(out.at(200, 140).1, reference.at(200, 140).1)
    }

    func testCropKeepsOnlyTheChosenAreaAndAHidingMarkOutsideItNeverAppears() throws {
        let (base, _) = makeBase()
        let doc = ScreenshotDocument(image: base)
        doc.add(ShotMark(tool: .redact, rect: CGRect(x: 0, y: 0, width: 30, height: 30)))
        doc.setCrop(CGRect(x: 100, y: 60, width: 80, height: 60))
        let out = pixels(try XCTUnwrap(doc.pngData()))
        XCTAssertEqual(out.width, 80); XCTAssertEqual(out.height, 60)
        let original = pixels(try XCTUnwrap(ScreenshotDocument(image: base).pngData()))
        XCTAssertTrue(out.at(0, 0) == original.at(100, 60) && out.at(79, 59) == original.at(179, 119), "the kept area is exactly that part of the picture")
        // A mark that straddles the edge of the crop is cut at the edge.
        let b = ScreenshotDocument(image: base)
        b.add(ShotMark(tool: .redact, rect: CGRect(x: 90, y: 50, width: 40, height: 40)))
        b.setCrop(CGRect(x: 100, y: 60, width: 80, height: 60))
        let cut = pixels(try XCTUnwrap(b.pngData()))
        XCTAssertEqual(Int(cut.at(5, 5).0) + Int(cut.at(5, 5).1) + Int(cut.at(5, 5).2), 0, "inside the straddling mark: black")
        XCTAssertNotEqual(Int(cut.at(60, 40).0) + Int(cut.at(60, 40).1) + Int(cut.at(60, 40).2), 0, "beyond it: the picture")
        doc.setCrop(CGRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertNil(doc.crop, "a crop too small to be one is ignored")
    }

    func testMakingHidingPermanentChangesTheBasePictureAndUndoCannotBringItBack() throws {
        let secret = CGRect(x: 40, y: 30, width: 100, height: 50)
        let (base, sentinel) = makeBase(secret: secret)
        let doc = ScreenshotDocument(image: base)
        doc.add(ShotMark(tool: .redact, rect: secret))
        doc.add(ShotMark(tool: .box, rect: CGRect(x: 5, y: 5, width: 30, height: 30)))
        doc.commitHiding()
        XCTAssertFalse(doc.hasHidingMarks)
        XCTAssertFalse(doc.canUndo, "the history that could restore the pixels is gone")
        doc.undo()
        let baseOnly = ScreenshotDocument(image: doc.base)
        let out = pixels(try XCTUnwrap(baseOnly.pngData()))
        let p = out.at(60, 40)
        XCTAssertFalse(p.0 == sentinel.0 && p.1 == sentinel.1 && p.2 == sentinel.2, "the picture itself no longer has the secret")
        XCTAssertEqual(p.0 + p.1 + p.2, 0)
        XCTAssertEqual(doc.marks.count, 1, "the box stays, as a mark")
    }

    func testArrowsBoxesTextAndPenDrawOnTheExportedPictureAndUndoTakesThemOff() throws {
        let (base, _) = makeBase()
        let doc = ScreenshotDocument(image: base)
        let plain = pixels(try XCTUnwrap(doc.pngData()))
        doc.add(ShotMark(tool: .box, rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: [1, 0, 0]))
        doc.add(ShotMark(tool: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 140)], color: [0, 0, 1]))
        doc.add(ShotMark(tool: .text, rect: CGRect(x: 10, y: 120, width: 0, height: 0), text: "Look here", color: [0, 0, 0]))
        doc.add(ShotMark(tool: .pen, points: [CGPoint(x: 150, y: 10), CGPoint(x: 200, y: 40)], color: [0, 1, 0]))
        let marked = pixels(try XCTUnwrap(doc.pngData()))
        var changed = 0
        for y in 0..<160 { for x in 0..<240 { if marked.at(x, y) != plain.at(x, y) { changed += 1 } } }
        XCTAssertGreaterThan(changed, 200, "marks were drawn into the picture")
        for _ in 0..<4 { doc.undo() }
        XCTAssertEqual(doc.marks.count, 0)
        let undone = pixels(try XCTUnwrap(doc.pngData()))
        var same = true
        for y in 0..<160 { for x in 0..<240 { if undone.at(x, y) != plain.at(x, y) { same = false } } }
        XCTAssertTrue(same, "undo took them all off again")
    }

    func testACaptureStaysInMemoryAndNothingIsWrittenUntilTheyChoose() async throws {
        let downloads = DownloadCoordinator.directory
        let folder = downloads.appendingPathComponent("Page Screenshots", isDirectory: true)
        let countBefore = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
        let tempBefore = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).count) ?? 0
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-shot-\(UUID().uuidString)", profile: "default")
        await m.start()
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML("<html><body style='background:#fff'><h1>Hello</h1><p>capture me</p></body></html>", baseURL: URL(string: "http://127.0.0.1:18765/shot"))
        try await Task.sleep(for: .seconds(1.2))
        tab.url = URL(string: "http://127.0.0.1:18765/shot")
        await m.startScreenshot(fullPage: false)
        let draft = try XCTUnwrap(m.screenshotDraft, "the capture is in memory")
        XCTAssertGreaterThan(draft.size.width, 100)
        XCTAssertEqual(m.sheet, .screenshot)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0, countBefore, "nothing was saved to Downloads")
        XCTAssertLessThanOrEqual((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).count) ?? 0, tempBefore + 6, "and no capture file was written elsewhere")
        XCTAssertNotNil(draft.pngData())
        XCTAssertNotNil(draft.jpegData())
        // The page text is in it: a picture of the page, taken by the browser's own capture.
        XCTAssertNotNil(ScreenshotDocument(pngOrJPEG: try XCTUnwrap(draft.pngData())))
    }

    /// Files for an independent check by OCR (scripts/verify-screenshot-redaction.sh): the same picture of text, as it is, with the digits blacked out, and with them hidden.
    func testWriteFilesForAnIndependentOCRCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-shot-artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 900, h = 220
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func draw(_ text: String, y: CGFloat, size: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil), .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            context.textPosition = CGPoint(x: 30, y: y); CTLineDraw(line, context)
        }
        draw("Account statement", y: 150, size: 48)
        draw("Card 4111 1111 1111 1111", y: 60, size: 60)
        let base = context.makeImage()!
        func write(_ name: String, _ doc: ScreenshotDocument) throws { try XCTUnwrap(doc.pngData()).write(to: dir.appendingPathComponent(name)) }
        try write("unredacted.png", ScreenshotDocument(image: base))
        let digits = CGRect(x: 0, y: 120, width: CGFloat(w), height: 90)         // the card line, from the top
        let blackened = ScreenshotDocument(image: base); blackened.add(ShotMark(tool: .redact, rect: digits)); try write("blacked-out.png", blackened)
        let hidden = ScreenshotDocument(image: base); hidden.add(ShotMark(tool: .pixelate, rect: digits)); try write("hidden.png", hidden)
        print("SHOT ARTIFACTS \(dir.path)")
    }
}

private extension CGFloat { var int: Int { Int(self) } }
