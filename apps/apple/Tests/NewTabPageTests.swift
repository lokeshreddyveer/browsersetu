import XCTest
@testable import Browser_Setu

final class NewTabPageTests: XCTestCase {
    func testCustomAddressRules() {
        XCTAssertEqual(NewTabMode.customURL(from: "google.com")?.absoluteString, "https://google.com")
        XCTAssertEqual(NewTabMode.customURL(from: " https://www.google.com/ ")?.absoluteString, "https://www.google.com/")
        XCTAssertNil(NewTabMode.customURL(from: ""))
        XCTAssertNil(NewTabMode.customURL(from: "not a url"))
        XCTAssertNil(NewTabMode.customURL(from: "javascript:alert(1)"))
        XCTAssertNil(NewTabMode.customURL(from: "file:///etc/passwd"))
        XCTAssertNil(NewTabMode.customURL(from: "localhost"), "needs a dot, like the favorites")
    }

    func testHexColours() throws {
        let c = try XCTUnwrap(StartColor.components("#1B2A4A"))
        XCTAssertEqual(c.r, 27.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(StartColor.hex(r: c.r, g: c.g, b: c.b), "#1B2A4A")
        XCTAssertNotNil(StartColor.components("0C0F17"))
        XCTAssertNil(StartColor.components("#12345"))
        XCTAssertNil(StartColor.components("#GGGGGG"))
        XCTAssertEqual(StartColor.hex(r: 2, g: -1, b: 0.5), "#FF0080", "values are clamped")
    }

    func testGoogleIsTheDefaultSearchAndTheOthersStay() {
        XCTAssertEqual(SearchEngines.defaultEngine.id, "google")
        for id in ["brave", "duckduckgo", "bing"] { XCTAssertNotNil(SearchEngines.presets.first { $0.id == id }) }
    }

    func testStartBackgroundChoicesIncludeColourAndBlend() {
        XCTAssertTrue(StartBackground.allCases.contains(.color))
        XCTAssertTrue(StartBackground.allCases.contains(.blend))
        XCTAssertEqual(StartBackground(rawValue: "gradient"), .gradient, "an old saved choice still reads")
    }
}

final class VoiceQueryTests: XCTestCase {
    func testCleaningTrimsPunctuationAndSpaces() {
        XCTAssertEqual(VoiceQuery.clean("  What is the weather today?  "), "What is the weather today")
        XCTAssertEqual(VoiceQuery.clean("open   github dot com."), "open github dot com")
        XCTAssertEqual(VoiceQuery.clean("..."), "")
        XCTAssertEqual(VoiceQuery.clean(""), "")
    }

    func testPictureIsABackgroundChoice() {
        XCTAssertTrue(StartBackground.allCases.contains(.image))
        XCTAssertEqual(StartBackground.image.title, "Picture")
    }
}

final class MotionStyleTests: XCTestCase {
    func testOffGivesNoAnimationAndTheOthersDo() {
        XCTAssertNil(MotionStyle.off.apply(.easeOut(duration: 0.2)))
        for style in MotionStyle.allCases where style != .off { XCTAssertNotNil(style.apply(.easeOut(duration: 0.2))) }
        XCTAssertEqual(MotionStyle.allCases.count, 5)
        XCTAssertEqual(MotionStyle(rawValue: "standard"), .standard)
    }
}

final class LookTests: XCTestCase {
    func testIconChoices() {
        XCTAssertEqual(SiteIconShape.circle.corner, 0.5)
        XCTAssertLessThan(SiteIconShape.square.corner, SiteIconShape.rounded.corner)
        XCTAssertEqual(IconWeight.allCases.count, 4)
        XCTAssertEqual(IconWeight(rawValue: "bold")?.weight, .bold)
    }

    func testAnimatedDecorationsAreTheOnesThatMove() {
        XCTAssertTrue(ThemeDecoration.aurora.isAnimated)
        XCTAssertFalse(ThemeDecoration.stars.isAnimated)
        XCTAssertEqual(BrowserTheme.animated.count, 16)
        XCTAssertEqual(BrowserTheme.photos.count, 7)
        XCTAssertTrue(BrowserTheme.photos.allSatisfy { $0.backdropImage != nil })
        XCTAssertTrue(BrowserTheme.animated.allSatisfy { $0.decoration.isAnimated })
    }

    func testAnOldCustomThemeStillReadsAndCanBeAnimated() throws {
        let old = #"{"accent":{"r":0.3,"g":0.5,"b":1},"top":{"r":0.07,"g":0.09,"b":0.15},"bottom":{"r":0.03,"g":0.03,"b":0.06},"hasPhoto":false,"photoDim":0.35}"#
        var theme = try JSONDecoder().decode(CustomTheme.self, from: Data(old.utf8))
        XCTAssertNil(theme.decoration)
        XCTAssertEqual(theme.theme.decoration, ThemeDecoration.none)
        theme.decoration = .rain
        XCTAssertEqual(theme.theme.decoration, .rain)
    }
}
