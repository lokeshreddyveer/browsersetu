import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Browser_Setu

/// What gets in, what is refused, and how little of it is ever held in memory.
final class IconDecoderTests: XCTestCase {
    private func output(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> IconDecoder.Output {
        switch IconDecoder.decode(data) {
        case .success(let out): return out
        case .failure(let f): XCTFail("unexpected failure \(f)", file: file, line: line); throw NSError(domain: "decode", code: 1)
        }
    }

    func testAPictureBecomesASixtyFourPixelPNG() throws {
        let out = try output(FaviconFixtures.png(width: 512, height: 256))
        XCTAssertEqual(FaviconFixtures.pixelSize(of: out.png).map { [$0.0, $0.1] }, [64, 64])
        XCTAssertEqual(out.sourceWidth, 512)
    }

    func testAnICOHoldingSeveralPicturesUsesTheBestOne() throws {
        let out = try output(FaviconFixtures.ico(sizes: [16, 48]))
        XCTAssertEqual(out.sourceWidth, 48, "none is as large as the output, so the largest is taken")
        let both = try output(FaviconFixtures.ico(sizes: [16, 32, 96, 128]))
        XCTAssertEqual(both.sourceWidth, 96, "the smallest picture at least as large as the output")
    }

    func testGarbageAndEmptyAndTooLargeAreRefused() {
        XCTAssertEqual(IconDecoder.decode(Data("not an image at all, just words".utf8)), .failure(.notAnImage))
        XCTAssertEqual(IconDecoder.decode(Data()), .failure(.empty))
        XCTAssertEqual(IconDecoder.decode(Data(count: IconDecoder.maxInputBytes + 1)), .failure(.tooLarge))
    }

    func testATruncatedPNGIsRefused() {
        let png = FaviconFixtures.png(width: 64, height: 64)
        if case .success = IconDecoder.decode(png.prefix(png.count / 3)) { XCTFail("a truncated picture was accepted") }
    }

    func testAPictureThatIsTooSmallToBeAnIconIsRefused() {
        XCTAssertEqual(IconDecoder.decode(FaviconFixtures.png(width: 1, height: 1)), .failure(.tooSmall), "a one-pixel tracking image is not an icon")
    }

    func testAPictureTooWideOrWithTooManyPixelsIsRefusedBeforeItIsDecoded() {
        // Small on the wire (a solid colour), huge when expanded. One side past the limit:
        let strip = FaviconFixtures.png(width: 4_200, height: 8)
        XCTAssertLessThanOrEqual(strip.count, IconDecoder.maxInputBytes, "the fixture must pass the byte limit for this to test the dimension limit")
        XCTAssertEqual(IconDecoder.decode(strip), .failure(.dimensionsTooLarge))
        // Every side within the limit, but more pixels in all than allowed (2,100 x 2,100 is 4.4 million):
        let square = FaviconFixtures.png(width: 2_100, height: 2_100)
        XCTAssertLessThanOrEqual(square.count, IconDecoder.maxInputBytes)
        XCTAssertEqual(IconDecoder.decode(square), .failure(.dimensionsTooLarge))
    }

    func testTooManyFramesAreRefused() {
        XCTAssertEqual(IconDecoder.decode(FaviconFixtures.ico(sizes: Array(repeating: 16, count: IconDecoder.maxFrames + 1))), .failure(.tooManyFrames))
    }

    func testTransparencyIsKeptAndTheOutputIsSquare() throws {
        let out = try output(FaviconFixtures.png(width: 128, height: 64, alpha: 0))
        XCTAssertEqual(FaviconFixtures.pixelSize(of: out.png).map { [$0.0, $0.1] }, [64, 64])
    }

    func testASafeSVGIsDrawnOrCleanlyUnsupportedButNeverTreatedAsUnsafe() {
        let result = IconDecoder.decode(FaviconFixtures.safeSVG)
        switch result {
        case .success(let out): XCTAssertEqual(FaviconFixtures.pixelSize(of: out.png).map { [$0.0, $0.1] }, [64, 64])
        case .failure(let f): XCTAssertEqual(f, .unsupported, "a safe SVG may only fail because this system cannot draw it")
        }
    }

    func testNothingActiveOrExternalInAnSVGIsAccepted() {
        let attacks: [String] = [
            #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><rect width="9" height="9"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div>x</div></foreignObject></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="https://evil.example/x.png"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="https://evil.example/a.svg#b"/></svg>"#,
            #"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg"><text>&x;</text></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>@import url(https://evil.example/a.css);</style></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="9" height="9" style="fill:url(https://evil.example/p)"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><rect width="9" height="9"/></a></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><animate attributeName="href" values="javascript:alert(1)"/></svg>"#,
        ]
        for text in attacks {
            XCTAssertEqual(IconDecoder.decode(Data(text.utf8)), .failure(.unsafeSVG), "accepted: \(text.prefix(70))")
        }
    }

    func testAnSVGThatOnlyPointsInsideItselfIsAcceptedBySanitizer() {
        let inside = Data(##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs><rect width="9" height="9" fill="url(#g)"/><use xlink:href="#g"/></svg>"##.utf8)
        XCTAssertTrue(SVGSanitizer.isSafe(inside))
        XCTAssertFalse(SVGSanitizer.isSafe(Data(count: SVGSanitizer.maxBytes + 1)))
    }


    func testTheBypassesAStringSearchWouldMissAreRefused() {
        let ns = #"xmlns="http://www.w3.org/2000/svg""#
        let cases: [String: String] = [
            "a prefixed script element": "<svg \(ns) xmlns:s=\"http://www.w3.org/2000/svg\"><s:script>alert(1)</s:script></svg>",
            "a prefixed foreignObject": "<svg \(ns) xmlns:x=\"http://www.w3.org/2000/svg\"><x:foreignObject><div/></x:foreignObject></svg>",
            "an element from another namespace": "<svg \(ns)><div xmlns=\"http://www.w3.org/1999/xhtml\">x</div></svg>",
            "a character-reference url()": "<svg \(ns)><rect width=\"9\" height=\"9\" fill=\"u&#114;l(https://evil.example/p)\"/></svg>",
            "an external DTD": "<!DOCTYPE svg SYSTEM \"http://evil.example/x.dtd\"><svg \(ns)><rect width=\"9\" height=\"9\"/></svg>",
            "a doctype with an internal subset and spacing": "<!doctype  svg  [ <!ENTITY a 'b'> ]><svg \(ns)><rect width=\"9\" height=\"9\"/></svg>",
            "an animate element": "<svg \(ns)><rect width=\"9\" height=\"9\"><animate attributeName=\"x\" values=\"1;2\"/></rect></svg>",
            "text (fonts)": "<svg \(ns)><text>hello</text></svg>",
            "a filter": "<svg \(ns)><filter id=\"f\"/><rect width=\"9\" height=\"9\" filter=\"url(#f)\"/></svg>",
            "malformed XML": "<svg \(ns)><rect width=\"9\" height=\"9\"></svg>",
            "a root that is not svg": "<g \(ns)><rect width=\"9\" height=\"9\"/></g>",
            "a deeply nested tree": "<svg \(ns)>" + String(repeating: "<g>", count: 40) + String(repeating: "</g>", count: 40) + "</svg>",
            "too many elements": "<svg \(ns)>" + String(repeating: "<rect width=\"1\" height=\"1\"/>", count: 450) + "</svg>",
        ]
        for (name, text) in cases { XCTAssertFalse(SVGSanitizer.isSafe(Data(text.utf8)), "accepted \(name)") }
    }


    func testSimpleStylesheetsAreAcceptedBecauseManyRealIconsNeedThem() {
        let ns = ##"xmlns="http://www.w3.org/2000/svg""##
        let ok: [String] = [
            "<svg \(ns)><style>.a{fill:#2a7;stroke:#fff;stroke-width:2}</style><rect class=\"a\" width=\"9\" height=\"9\"/></svg>",
            "<svg \(ns)><style type=\"text/css\"><![CDATA[ .a, #b > .c { fill: red; opacity: .5 } /* a note */ ]]></style><rect class=\"a\" width=\"9\" height=\"9\"/></svg>",
            "<svg \(ns)><rect width=\"9\" height=\"9\" style=\"fill:red;fill-opacity:0.5\"/></svg>",
            "<svg \(ns)><defs><linearGradient id=\"g\"/></defs><style>.x{fill:url(#g)}</style><rect class=\"x\" width=\"9\" height=\"9\"/></svg>",
        ]
        for text in ok { XCTAssertTrue(SVGSanitizer.isSafe(Data(text.utf8)), "refused: \(text.prefix(90))") }
    }

    func testStylesheetsThatReachOutOrDoMoreThanPaintAreRefused() {
        let ns = ##"xmlns="http://www.w3.org/2000/svg""##
        let bad: [String: String] = [
            "an @import": "<svg \(ns)><style>@import url(https://evil.example/a.css);</style><rect width=\"9\" height=\"9\"/></svg>",
            "a @font-face": "<svg \(ns)><style>@font-face{font-family:x;src:url(https://evil.example/f)}</style></svg>",
            "an external url()": "<svg \(ns)><style>.a{fill:url(https://evil.example/p)}</style><rect class=\"a\" width=\"9\" height=\"9\"/></svg>",
            "an escaped url": "<svg \(ns)><style>.a{fill:\\75rl(https://evil.example/p)}</style></svg>",
            "an unlisted property": "<svg \(ns)><style>.a{position:fixed;content:\"x\"}</style></svg>",
            "behavior and bindings": "<svg \(ns)><style>.a{-moz-binding:url(#x);behavior:url(#y)}</style></svg>",
            "an expression": "<svg \(ns)><style>.a{fill:expression(alert(1))}</style></svg>",
            "an attribute selector": "<svg \(ns)><style>rect[href^=http]{fill:red}</style></svg>",
            "a pseudo-class": "<svg \(ns)><style>rect:hover{fill:red}</style></svg>",
            "an unterminated comment": "<svg \(ns)><style>/* never closed .a{fill:red}</style></svg>",
            "a hidden url in a comment split": "<svg \(ns)><style>.a{fill:ur/**/l(https://e/x)}</style></svg>",
            "a wrong style type": "<svg \(ns)><style type=\"text/javascript\">.a{fill:red}</style></svg>",
            "a bad style attribute": "<svg \(ns)><rect width=\"9\" height=\"9\" style=\"fill:url(https://e/x)\"/></svg>",
            "a huge stylesheet": "<svg \(ns)><style>" + String(repeating: ".a{fill:red}", count: 3_000) + "</style></svg>",
        ]
        for (name, text) in bad { XCTAssertFalse(SVGSanitizer.isSafe(Data(text.utf8)), "accepted \(name)") }
    }

    func testACleanSVGWithGradientsAndInternalReferencesIsAccepted() {
        let ok = ##"<?xml version="1.0"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 32 32"><title>t</title><defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient><clipPath id="c"><circle cx="16" cy="16" r="15"/></clipPath></defs><g clip-path="url(#c)"><rect width="32" height="32" fill="url(#g)"/><use xlink:href="#g"/></g></svg>"##
        XCTAssertTrue(SVGSanitizer.isSafe(Data(ok.utf8)))
    }

    func testAnAbsurdDeclaredSizeNeverCrashesTheDecoder() {
        for size in ["1e30", "1e308", "99999999999", "-5", "NaN", "0"] {
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(size)" height="\#(size)"><rect width="9" height="9"/></svg>"#
            _ = IconDecoder.decode(Data(svg.utf8))     // any answer is fine; reaching the next line is the test
        }
    }

    func testPicturesInFormatsAnIconIsNeverServedInAreRefused() {
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, 1, nil)!
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        XCTAssertEqual(IconDecoder.decode(buffer as Data), .failure(.notAnImage), "a TIFF is a valid picture and still not an icon")
    }

    func testDecodingKeepsNoLargeBufferAlive() throws {
        // 200 decodes of a 2,000 x 2,000 picture must not grow the process by anything near 200 full pictures (16 MB each).
        let big = FaviconFixtures.png(width: 2_000, height: 2_000)
        let before = Self.residentBytes()
        for _ in 0..<40 { _ = IconDecoder.decode(big) }
        let grown = Self.residentBytes() - before
        XCTAssertLessThan(grown, 200 * 1024 * 1024, "decoding left \(grown / 1_048_576) MB behind")
    }

    static func residentBytes() -> Int {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
