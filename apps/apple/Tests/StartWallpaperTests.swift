import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Browser_Setu

/// The start page's picture: the saved look, what the picture looks like, and the cache of decoded sizes.
final class StartWallpaperTests: XCTestCase {
    /// A PNG of the given size, filled by `paint(x, y)` returning red, green, blue in 0...255.
    private func png(width: Int = 64, height: Int = 64, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let c = paint(x, y); let i = (y * width + x) * 4; pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2 } }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image: CGImage = try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    // MARK: The saved look

    func testTheLookSurvivesBeingSavedAndRead() {
        var look = StartLook()
        look.focalX = 0.25; look.focalY = 0.8; look.fit = true; look.saturation = 1.4; look.brightness = -0.1
        look.ambient = false; look.pointerGlow = true; look.parallax = true; look.adaptiveText = false
        XCTAssertEqual(StartLook.decode(look.encoded), look)
    }

    func testAnUnreadableOrMissingLookGivesTheDefaults() {
        XCTAssertEqual(StartLook.decode(nil), StartLook())
        XCTAssertEqual(StartLook.decode(""), StartLook())
        XCTAssertEqual(StartLook.decode("not json at all"), StartLook())
    }

    func testEveryValueIsBroughtBackIntoRange() {
        let wild = StartLook(focalX: -3, focalY: 9, fit: false, saturation: 50, brightness: -7, adaptiveText: true, ambient: true, pointerGlow: false, parallax: false).clamped()
        XCTAssertEqual(wild.focalX, 0); XCTAssertEqual(wild.focalY, 1)
        XCTAssertEqual(wild.saturation, 2); XCTAssertEqual(wild.brightness, -0.4)
        let saved = StartLook.decode("{\"focalX\":5,\"focalY\":-1,\"saturation\":-4,\"brightness\":3}")
        XCTAssertEqual(saved.focalX, 1); XCTAssertEqual(saved.focalY, 0); XCTAssertEqual(saved.saturation, 0); XCTAssertEqual(saved.brightness, 0.4)
    }

    func testALookSavedByAnOlderVersionWithFewerFieldsIsStillRead() {
        // Only one key present: the rest take their defaults, and what was there is kept.
        let partial = StartLook.decode("{\"focalX\":0.3}")
        XCTAssertEqual(partial.focalX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(partial.focalY, 0.5); XCTAssertTrue(partial.adaptiveText); XCTAssertTrue(partial.ambient); XCTAssertFalse(partial.parallax)
    }

    // MARK: What the picture looks like

    func testABrightPictureAsksForDarkInkAndADarkOneForLight() throws {
        let bright = try XCTUnwrap(WallpaperAnalyzer.analyze(try png { _, _ in (240, 240, 235) }))
        let dark = try XCTUnwrap(WallpaperAnalyzer.analyze(try png { _, _ in (20, 25, 40) }))
        XCTAssertGreaterThan(bright.centerLuminance, 0.85)
        XCTAssertLessThan(dark.centerLuminance, 0.15)
        XCTAssertEqual(StartReadability.prefersDarkInk(bright, dim: 0, brightness: 0), true)
        XCTAssertEqual(StartReadability.prefersDarkInk(dark, dim: 0, brightness: 0), false)
    }

    func testDarkeningABrightPictureEventuallyTurnsTheInkLight() throws {
        let bright = try XCTUnwrap(WallpaperAnalyzer.analyze(try png { _, _ in (200, 200, 200) }))
        XCTAssertEqual(StartReadability.prefersDarkInk(bright, dim: 0, brightness: 0), true)
        XCTAssertEqual(StartReadability.prefersDarkInk(bright, dim: 0.7, brightness: 0), false, "70% darker leaves it dim enough for light text")
    }

    func testTheMiddleCountsMoreThanTheEdgesBecauseThatIsWhereTheTextIs() throws {
        // Bright at the left and right edges, dark in the middle.
        let data = try png(width: 100, height: 100) { x, _ in (x < 15 || x >= 85) ? (250, 250, 250) : (10, 10, 10) }
        let a = try XCTUnwrap(WallpaperAnalyzer.analyze(data))
        XCTAssertLessThan(a.centerLuminance, 0.2)
        XCTAssertGreaterThan(a.luminance, a.centerLuminance, "the whole picture is brighter than its middle")
    }

    func testTheMainColourIsTheColourfulOneNotTheGreyOne() throws {
        // A grey picture with a strip of strong blue in the middle.
        let data = try png(width: 100, height: 100) { x, y in (x > 35 && x < 65 && y > 35 && y < 65) ? (20, 60, 230) : (128, 128, 128) }
        let a = try XCTUnwrap(WallpaperAnalyzer.analyze(data))
        XCTAssertGreaterThan(a.b, a.r + 0.15, "blue wins over the grey around it")
    }

    func testSomethingThatIsNotAPictureGivesNothing() {
        XCTAssertNil(WallpaperAnalyzer.analyze(Data("hello".utf8)))
        XCTAssertNil(WallpaperAnalyzer.analyze(Data()))
        XCTAssertNil(StartReadability.prefersDarkInk(nil, dim: 0, brightness: 0))
    }

    // MARK: The cache

    func testAPictureIsDecodedOnceAtAGivenSizeAndAtMostTheLargestStep() throws {
        let data = try png(width: 3000, height: 2000) { x, y in (UInt8(x % 256), UInt8(y % 256), 90) }
        WallpaperImages.clear()
        let small = try XCTUnwrap(WallpaperImages.image(data, longSide: 300))
        XCTAssertLessThanOrEqual(max(small.width, small.height), 480)
        let again = try XCTUnwrap(WallpaperImages.image(data, longSide: 300))
        XCTAssertTrue(small === again, "the second ask is answered from the cache, not decoded again")
        let huge = try XCTUnwrap(WallpaperImages.image(data, longSide: 9000))
        XCTAssertLessThanOrEqual(max(huge.width, huge.height), 3000, "a picture only 3000 wide is never enlarged")
        XCTAssertEqual(max(huge.width, huge.height), 3000)
        XCTAssertNil(WallpaperImages.image(Data("junk".utf8), longSide: 300))
    }

    func testOnlyTheLastTwoSizesOfAPictureStayDecoded() async throws {
        let data = try png(width: 3000, height: 2000) { x, y in (UInt8(x % 256), UInt8(y % 256), 40) }
        WallpaperImages.clear()
        WallpaperImages.retain(WallpaperImages.identity(data))
        for size in [640, 960, 1280, 1600] { let made = await WallpaperImages.decode(data, bucket: size); XCTAssertNotNil(made) }
        XCTAssertNil(WallpaperImages.cached(data, bucket: 640), "older sizes are let go, so resizing a window never piles up copies")
        XCTAssertNil(WallpaperImages.cached(data, bucket: 960))
        XCTAssertNotNil(WallpaperImages.cached(data, bucket: 1280), "the size before the current one stays, to show while a resize is decoding")
        XCTAssertNotNil(WallpaperImages.cached(data, bucket: 1600))
    }

    func testAPictureIsLetGoWhenTheLastPageShowingItGoes() async throws {
        let data = try png(width: 2000, height: 1200) { x, _ in (UInt8(x % 256), 90, 200) }
        WallpaperImages.clear()
        let id = WallpaperImages.identity(data)
        WallpaperImages.retain(id); WallpaperImages.retain(id)            // two pages show it
        _ = await WallpaperImages.decode(data, bucket: 1280)
        WallpaperImages.release(id)
        XCTAssertNotNil(WallpaperImages.cached(data, bucket: 1280), "one page still shows it")
        WallpaperImages.release(id)
        XCTAssertNil(WallpaperImages.cached(data, bucket: 1280), "no page shows it, so its pixels are freed")
    }

    func testAPictureDecodedAfterItsPageWentAwayIsNotLeftBehind() async throws {
        let data = try png(width: 2000, height: 1200) { x, _ in (UInt8(x % 256), 10, 90) }
        WallpaperImages.clear()
        // No page holds it (the page already disappeared): the decode result is returned but nothing is kept.
        let made = await WallpaperImages.decode(data, bucket: 1280)
        XCTAssertNotNil(made)
        XCTAssertNil(WallpaperImages.cached(data, bucket: 1280), "nothing is kept for a picture no page shows")
        XCTAssertEqual(WallpaperImages.keptSizes(data), 0)
    }

    func testTheSmallSizesAreLetGoWithThePicture() async throws {
        let data = try png(width: 2400, height: 1500) { _, y in (30, UInt8(y % 256), 200) }
        WallpaperImages.clear()
        let id = WallpaperImages.identity(data)
        WallpaperImages.retain(id)
        _ = WallpaperImages.image(data, longSide: 640)          // the placeholder (a 640 bucket)
        _ = WallpaperImages.image(data, longSide: 320)          // a thumbnail (a different, 320 bucket: sizes come in steps of 320, so 480 would share the 640 one)
        _ = await WallpaperImages.decode(data, bucket: 1600)
        XCTAssertGreaterThanOrEqual(WallpaperImages.keptSizes(data), 3)
        WallpaperImages.release(id)
        XCTAssertEqual(WallpaperImages.keptSizes(data), 0, "every size, small and large, goes when the last page lets the picture go")
    }

    func testDecodingTheSameSizeTwiceGivesTheSameImage() async throws {
        let data = try png(width: 1500, height: 900) { _, y in (30, UInt8(y % 256), 120) }
        WallpaperImages.clear()
        WallpaperImages.retain(WallpaperImages.identity(data))
        let first = await WallpaperImages.decode(data, bucket: 960), second = await WallpaperImages.decode(data, bucket: 960)
        XCTAssertTrue(first === second, "the second ask is answered from the cache")
    }

    // MARK: Keeping a picture

    func testAKeptPictureIsAGoodQualityJPEGCutDownToTheLongestSideAndNeverEnlarged() throws {
        let big = try png(width: 5000, height: 2500) { x, y in (UInt8(x % 256), UInt8(y % 256), 120) }
        let kept = try XCTUnwrap(WallpaperImages.prepared(big))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(kept as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3840, "the long side is cut to the largest kept size")
        XCTAssertEqual(image.height, 1920, "and the shape is kept")
        let small = try XCTUnwrap(WallpaperImages.prepared(try png(width: 800, height: 600) { _, _ in (10, 200, 90) }))
        let smallImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil)), 0, nil))
        XCTAssertEqual(smallImage.width, 800, "a small picture is not blown up")
    }

    func testAKeptPictureCarriesNoCameraOrLocationDetails() throws {
        // A picture that arrives with EXIF and GPS: the kept copy has neither.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.34, kCGImagePropertyGPSLongitude: 56.78],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = out as Data
        let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil)), 0, nil) as? [CFString: Any])
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "the test picture really has a location")
        let kept = try XCTUnwrap(WallpaperImages.prepared(original))
        let after = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(kept as CFData, nil)), 0, nil) as? [CFString: Any])
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "no location is kept")
        XCTAssertNil((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment], "and no note")
    }

    func testSomethingThatIsNotAPictureIsNotKept() {
        XCTAssertNil(WallpaperImages.prepared(Data("not a picture".utf8)))
        XCTAssertNil(WallpaperImages.prepared(Data()))
    }
}
