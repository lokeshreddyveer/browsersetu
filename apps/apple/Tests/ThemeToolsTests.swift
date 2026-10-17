import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Browser_Setu

final class ThemeColourTests: XCTestCase {
    func testHexRoundTripsAndBadHexIsRefused() {
        XCTAssertEqual(RGB(hexString: "#BD93F9")?.hexString, "#BD93F9")
        XCTAssertEqual(RGB(hexString: "bd93f9")?.hexString, "#BD93F9")
        for bad in ["", "#12345", "#GGGGGG", "red", "#1234567", "0x112233"] { XCTAssertNil(RGB(hexString: bad), bad) }
    }

    func testContrastMatchesTheKnownExtremesAndFixingMakesAColourVisible() {
        XCTAssertEqual(RGB(hex: 0x000000).contrast(with: RGB(hex: 0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: 0x777777).contrast(with: RGB(hex: 0x777777)), 1, accuracy: 0.001)
        let background = RGB(hex: 0x121826)
        let dim = RGB(hex: 0x1D2A40)
        XCTAssertLessThan(dim.contrast(with: background), 3)
        XCTAssertGreaterThanOrEqual(dim.readable(against: background).contrast(with: background), 3, "on a dark background the accent is lightened")
        let paper = RGB(hex: 0xFAF6EE), pale = RGB(hex: 0xF0E6C8)
        XCTAssertLessThan(pale.contrast(with: paper), 3)
        XCTAssertGreaterThanOrEqual(pale.readable(against: paper).contrast(with: paper), 3, "on a light one it is darkened")
        let fine = RGB(hex: 0x4F8CFF)
        XCTAssertEqual(fine.readable(against: background), fine, "a colour that can already be seen is left alone")
    }

    func testEveryReadyMadeThemeHasAnAccentThatCanBeSeenOnItsBackground() {
        for theme in BrowserTheme.all + BrowserTheme.palettes {
            XCTAssertGreaterThanOrEqual(theme.accent.contrast(with: theme.top), 3, "\(theme.name)")
        }
        let ids = (BrowserTheme.all + BrowserTheme.palettes).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no two themes share an id")
        XCTAssertTrue(BrowserTheme.palettes.contains { $0.name == "Dracula" } && BrowserTheme.palettes.contains { $0.name == "Nord" })
    }

    private func png(_ paint: (CGContext, Int, Int) -> Void) -> Data {
        let w = 80, h = 80
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(context, w, h)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testThePhotosMainColourBecomesTheAccent() throws {
        // Mostly orange sky, a little blue, and a grey ground.
        let photo = png { c, w, h in
            c.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(CGColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
            c.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let accent = try XCTUnwrap(ThemeColor.dominantAccent(from: photo))
        XCTAssertGreaterThan(accent.r, accent.b + 0.3, "orange wins over the small blue patch")
        XCTAssertGreaterThan(accent.r, 0.6, "and it is bright enough to be an accent")
    }

    func testAGreyPhotoHasNoColourToTake() {
        let grey = png { c, w, h in c.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        XCTAssertNil(ThemeColor.dominantAccent(from: grey))
        XCTAssertNil(ThemeColor.dominantAccent(from: Data([1, 2, 3])), "and bytes that are not a picture are refused")
    }
}

final class ThemeFileTests: XCTestCase {
    func testAThemeSurvivesBeingWrittenAndRead() throws {
        for original in [BrowserTheme.palettes[0], BrowserTheme.all[1], BrowserTheme.palettes[5]] {
            let file = ThemeFile(original)
            let back = try JSONDecoder().decode(ThemeFile.self, from: file.data())
            let theme = try XCTUnwrap(back.theme(id: "x"))
            XCTAssertEqual(theme.name, original.name)
            XCTAssertEqual(theme.accent.hexString, original.accent.hexString)
            XCTAssertEqual(theme.top.hexString, original.top.hexString)
            XCTAssertEqual(theme.scheme, original.scheme)
            XCTAssertEqual(theme.decoration, original.decoration)
        }
    }

    func testFilesThatAreNotThemesAreRefused() {
        func decode(_ json: String) -> BrowserTheme? { (try? JSONDecoder().decode(ThemeFile.self, from: Data(json.utf8)))?.theme(id: "t") }
        let ok = ##"{"format":"browsersetu-theme","version":1,"name":"Mine","accent":"#112233","top":"#000000","bottom":"#111111"}"##
        XCTAssertEqual(decode(ok)?.name, "Mine")
        XCTAssertNotNil(decode(ok)?.glow, "a missing glow is worked out")
        XCTAssertNil(decode(ok.replacingOccurrences(of: "browsersetu-theme", with: "other")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "#112233", with: "#12")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "\"Mine\"", with: "\"  \"")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "\"version\":1", with: "\"version\":9")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "}", with: ",\"scheme\":\"sepia\"}")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "}", with: ",\"glow\":\"nope\"}")))
        XCTAssertNil(try? JSONDecoder().decode(ThemeFile.self, from: Data("not json".utf8)))
    }

    @MainActor func testImportingAddsASelectedThemeThatStaysAfterARestartAndCanBeDeleted() async throws {
        let root = NSTemporaryDirectory() + "bs-th-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await m.start()
        let json = ThemeFile(BrowserTheme.palettes[1]).data()
        XCTAssertNil(m.importTheme(data: json))
        XCTAssertTrue(m.themeID.hasPrefix("user-"))
        XCTAssertEqual(m.activeTheme.name, "Nord 2", "a name already in use gets a number")
        XCTAssertTrue(m.themeIsActive)
        XCTAssertNotNil(m.importTheme(data: Data("{}".utf8)), "a bad file gives a reason")
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await again.start()
        XCTAssertEqual(again.activeTheme.name, "Nord 2", "it is still there, and still chosen")
        again.deleteUserTheme(again.themeID)
        XCTAssertEqual(again.themeID, "midnight")
        XCTAssertTrue(again.userThemes.isEmpty)
    }

    @MainActor func testTheStyleSheetForEveryWebsiteComesBeforeASitesOwn() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-gs-\(UUID().uuidString)", profile: "default")
        await m.start()
        XCTAssertNil(m.siteStyle(forHost: "a.test"))
        m.setGlobalStyle(".banner{display:none}")
        XCTAssertEqual(m.siteStyle(forHost: "a.test"), ".banner{display:none}")
        m.setSiteStyles(m.siteStyles.merging(["a.test": "body{color:red}"]) { $1 })
        XCTAssertEqual(m.siteStyle(forHost: "www.a.test"), ".banner{display:none}\nbody{color:red}")
        m.setGlobalStyle("   ")
        XCTAssertEqual(m.siteStyle(forHost: "a.test"), "body{color:red}")
    }

    @MainActor func testEditingAReadyMadeThemeCopiesItIntoCustom() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ec-\(UUID().uuidString)", profile: "default")
        await m.start()
        m.editAsCustom(BrowserTheme.palettes[0])
        XCTAssertEqual(m.themeID, "custom")
        XCTAssertEqual(m.customTheme.accent.hexString, BrowserTheme.palettes[0].accent.hexString)
        m.startTile = .large
        XCTAssertEqual(StartTile.large.points, 62)
    }
}
