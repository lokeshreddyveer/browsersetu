import CoreGraphics
import XCTest
@testable import Browser_Setu

@MainActor
final class ScreenshotRobustnessTests: XCTestCase {
    private func picture(_ w: Int, _ h: Int) -> CGImage {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<20 {
            context.setFillColor(CGColor(red: CGFloat(i) / 20, green: 0.3, blue: 1 - CGFloat(i) / 20, alpha: 1))
            context.fill(CGRect(x: i * (w / 20), y: 0, width: w / 20, height: h))
        }
        return context.makeImage()!
    }

    func testTheFinishedPictureIsMadeOnceUntilSomethingChanges() {
        let doc = ScreenshotDocument(image: picture(1200, 3000))
        doc.add(ShotMark(tool: .redact, rect: CGRect(x: 10, y: 10, width: 200, height: 40)))
        let first = doc.flattened(), again = doc.flattened()
        XCTAssertTrue((first as AnyObject) === (again as AnyObject), "asking again (as every redraw does) does not redo the work")
        doc.add(ShotMark(tool: .box, rect: CGRect(x: 50, y: 50, width: 80, height: 80)))
        XCTAssertFalse((doc.flattened() as AnyObject) === (first as AnyObject), "a new mark gives a new picture")
        let withBox = doc.flattened()
        doc.undo()
        XCTAssertFalse((doc.flattened() as AnyObject) === (withBox as AnyObject), "undo does too")
        let beforeCrop = doc.flattened()
        doc.setCrop(CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(doc.flattened()?.width, 400)
        XCTAssertFalse((doc.flattened() as AnyObject) === (beforeCrop as AnyObject))
        doc.commitHiding()
        XCTAssertNotNil(doc.flattened())
    }

    func testRepeatedlyAskingForAnAlreadyMadePictureIsFast() {
        let doc = ScreenshotDocument(image: picture(1200, 6000))
        doc.add(ShotMark(tool: .pixelate, rect: CGRect(x: 0, y: 0, width: 1200, height: 3000)))
        _ = doc.flattened()
        let start = Date()
        for _ in 0..<500 { _ = doc.flattened() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "500 redraws while drawing a line")
    }

    func testHidingSmallWritingLeavesNothingToReadBack() throws {
        // A line of writing about 14 pixels tall, with stripes standing in for the letters.
        let w = 200, h = 60
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 12, to: 150, by: 6) { context.fill(CGRect(x: x, y: 24, width: 2, height: 12)) }
        let doc = ScreenshotDocument(image: context.makeImage()!)
        doc.add(ShotMark(tool: .pixelate, rect: CGRect(x: 10, y: 20, width: 140, height: 18)))
        let out = try XCTUnwrap(doc.flattened())
        let read = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        read.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buffer = read.data!.assumingMemoryBound(to: UInt8.self)
        // Along one row of the hidden area, the values change only from one wide block to the next: the stripes (2 pixels wide, every 6) are gone.
        var changes = 0
        let row = 28 * read.bytesPerRow
        for x in 11..<149 where buffer[row + x * 4] != buffer[row + (x - 1) * 4] { changes += 1 }
        XCTAssertLessThanOrEqual(changes, 140 / 16 + 1, "only block edges remain (\(changes) changes)")
    }
}
