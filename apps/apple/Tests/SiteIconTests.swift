import XCTest
import AppKit
@testable import Browser_Setu

@MainActor
final class SiteIconTests: XCTestCase {
    func testKeyIgnoresCaseAndLeadingWww() {
        XCTAssertEqual(FaviconStore.key(forHost: "WWW.Example.com"), "example.com")
        XCTAssertEqual(FaviconStore.key(forHost: "m.example.com"), "m.example.com")
        XCTAssertNil(FaviconStore.key(forHost: nil))
        XCTAssertNil(FaviconStore.key(forHost: ""))
    }

    func testAnImageIsShrunkToASmallPNGAndGarbageIsRefused() throws {
        let big = NSImage(size: NSSize(width: 512, height: 256))
        big.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 512, height: 256).fill(); big.unlockFocus()
        let tiff = try XCTUnwrap(big.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let small = try XCTUnwrap(FaviconStore.shrunkPNG(from: png))
        let image = try XCTUnwrap(NSImage(data: small))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 64)
        XCTAssertNil(FaviconStore.shrunkPNG(from: Data("not an image at all".utf8)))
    }

    func testASavedIconIsFoundForAnyAddressOnTheSameSite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FaviconStore(directory: folder)
        XCTAssertNil(store.image(forURL: "https://example.com/a"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 8, height: 8))
        img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("example.com.png"))
        XCTAssertNotNil(store.image(forURL: "https://www.example.com/other/page"))
        store.clear()
        XCTAssertNil(store.image(forURL: "https://example.com/"))
    }
}
