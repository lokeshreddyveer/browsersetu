import XCTest
@testable import Browser_Setu

/// The right-click menu adds a few choices for what was clicked, and only those.
final class PageMenuTests: XCTestCase {
    private func actions(_ ids: [String]) -> [PageMenuAction] { PageMenuChoices.choices(for: ids).compactMap(\.action) }

    func testASelectionGetsSearchResearchAndTranslate() {
        let a = actions(["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb"])
        XCTAssertEqual(a.count, 3)
        XCTAssertTrue(a.contains(.searchSelection) && a.contains(.researchSelection) && a.contains(.translateSelection))
    }

    func testALinkGetsACleanCopyAndNothingForThePage() {
        let a = actions(["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierReload"])
        XCTAssertEqual(a, [.copyCleanLink], "a page's own choices do not appear on a link")
    }

    func testAnImageGetsOpenInNewTab() {
        XCTAssertEqual(actions(["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierDownloadImage"]), [.openImageInTab])
    }

    func testAVideoGetsThePlayerAndPictureInPicture() {
        let a = actions(["WKMenuItemIdentifierMediaPlayPause", "WKMenuItemIdentifierCopyMediaLink"])
        XCTAssertEqual(a.count, 2)
        XCTAssertTrue(a.contains(.playerControls) && a.contains(.pictureInPicture))
    }

    func testTheBackgroundOfAPageGetsThreeChoicesAndASubmenuOfTheRest() {
        let all = PageMenuChoices.choices(for: ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"])
        XCTAssertEqual(all.compactMap(\.action), [.screenshot, .autoScroll, .backToTop])
        XCTAssertEqual(all.count, 4, "three choices and one submenu, so the menu stays short")
        let more = try? XCTUnwrap(all.last)
        XCTAssertNil(more?.action, "the submenu itself does nothing")
        XCTAssertEqual(more?.children.compactMap(\.action), [.fullPageScreenshot, .pagePDF, .editPageText, .reader, .readingList])
    }

    func testDownloadToolsAreOnlyOfferedOnAWebPageAndStayInOneSubmenu() throws {
        let page = ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"]
        let plain = PageMenuChoices.choices(for: page, downloadTools: true)
        let tools = try XCTUnwrap(plain.first { $0.title == "Download from This Page" })
        XCTAssertEqual(tools.children.compactMap(\.action), [.findMedia, .collectImages, .linkGrabber, .exploreSite])
        XCTAssertEqual(plain.count, 5, "one more entry, never four more")
        XCTAssertNil(PageMenuChoices.choices(for: page).first { $0.title == "Download from This Page" }, "off unless the page is a web page")
        XCTAssertFalse(PageMenuChoices.choices(for: ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierReload"], downloadTools: true).contains { $0.title == "Download from This Page" }, "not on a link")
        XCTAssertEqual(PageMenuChoices.choices(for: ["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierDownloadImage"], downloadTools: true).compactMap(\.action), [.openImageInTab, .collectImages])
        XCTAssertTrue(PageMenuChoices.choices(for: ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierSearchWeb"], downloadTools: true).allSatisfy { $0.action != .findMedia })
    }

    func testTheAutoScrollScriptStopsItselfAndTakesItsSpeedAsAnArgument() {
        let script = PageToolScripts.autoScroll
        XCTAssertTrue(script.contains("window.__bsAuto.stop()"), "running it again switches it off")
        XCTAssertTrue(script.contains("speed"))
        for event in ["wheel", "keydown", "mousedown", "touchstart"] { XCTAssertTrue(script.contains("'\(event)'"), "\(event) stops it") }
        XCTAssertTrue(script.contains("scrollHeight"), "and the foot of the page does")
        XCTAssertTrue(PageToolScripts.editText.contains("designMode"))
    }

    func testAnUnknownMenuGetsNothing() {
        XCTAssertTrue(actions([]).isEmpty)
        XCTAssertTrue(actions(["WKMenuItemIdentifierSomethingNew"]).isEmpty)
    }

    func testOnlyWebAddressesAndAShortSelectionAreKept() {
        let kept = PageMenuTarget(["link": "https://example.com/a?utm_source=x", "image": "javascript:alert(1)", "selection": "  hello  "])
        XCTAssertEqual(kept.link?.absoluteString, "https://example.com/a?utm_source=x")
        XCTAssertNil(kept.image, "a script address is not an image address")
        XCTAssertEqual(kept.selection, "hello")
        XCTAssertNil(PageMenuTarget(["selection": "   "]).selection)
        XCTAssertNil(PageMenuTarget(["link": "file:///etc/passwd"]).link)
        XCTAssertNil(PageMenuTarget(nil).link)
        XCTAssertEqual(PageMenuTarget(["selection": String(repeating: "x", count: 5000)]).selection?.count, 2000)
    }
}
