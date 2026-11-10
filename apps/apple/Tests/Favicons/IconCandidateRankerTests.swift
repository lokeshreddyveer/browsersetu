import XCTest
@testable import Browser_Setu

/// The ranking rules, one case each, including the ambiguous ones. See `IconCandidateRanker` for the rules in words.
final class IconCandidateRankerTests: XCTestCase {
    private let page = URL(string: "https://example.com/docs/page")!

    private func row(_ href: String, rel: String = "icon", sizes: String = "", type: String = "", media: String = "") -> [String: Any] {
        ["href": href, "rel": rel, "sizes": sizes, "type": type, "media": media]
    }
    private func order(_ rows: [[String: Any]]) -> [String] {
        IconCandidateRanker.ordered(IconCandidateRanker.candidates(fromLinks: rows, pageURL: page), pageURL: page).map { $0.url.path }
    }

    func testThePagesOwnIconAlwaysComesBeforeTheSitesDefault() {
        let list = order([row("/a.png", sizes: "16x16")])
        XCTAssertEqual(list, ["/a.png", "/favicon.ico"], "a tiny page icon still outranks the default; the default is only the last resort")
    }

    func testTheSmallestIconAtLeastAsLargeAsWhatIsDrawnWins() {
        let list = order([row("/s32.png", sizes: "32x32"), row("/s256.png", sizes: "256x256"), row("/s128.png", sizes: "128x128")])
        XCTAssertEqual(list, ["/s128.png", "/s256.png", "/s32.png", "/favicon.ico"], "128 is the closest above 64, then 256, then the too-small 32")
    }

    func testAScalableIconBeatsEveryRaster() {
        let list = order([row("/big.png", sizes: "512x512"), row("/logo.svg", type: "image/svg+xml"), row("/any.png", sizes: "any")])
        XCTAssertEqual(Array(list.prefix(2)), ["/any.png", "/logo.svg"].sorted { list.firstIndex(of: $0)! < list.firstIndex(of: $1)! })
        XCTAssertEqual(list.last, "/favicon.ico")
        XCTAssertTrue(list.firstIndex(of: "/logo.svg")! < list.firstIndex(of: "/big.png")!)
    }

    func testAnIconWithNoDeclaredSizeComesAfterOnesThatFitAndBeforeOnesThatAreTooSmall() {
        let list = order([row("/tiny.png", sizes: "16x16"), row("/unknown.png"), row("/fit.png", sizes: "64x64")])
        XCTAssertEqual(list, ["/fit.png", "/unknown.png", "/tiny.png", "/favicon.ico"])
    }

    func testAmongEqualSizesAPlainIconBeatsAnAppleTouchIconAndOrderBreaksTheRest() {
        let list = order([row("/touch.png", rel: "apple-touch-icon", sizes: "180x180"), row("/plain.png", sizes: "180x180"), row("/second.png", sizes: "180x180")])
        XCTAssertEqual(list, ["/plain.png", "/second.png", "/touch.png", "/favicon.ico"])
    }

    func testADarkOnlyIconIsNotAFirstChoiceButIsTheDarkVariant() {
        let rows = [row("/light.png", sizes: "64x64"), row("/dark.png", sizes: "64x64", media: "(prefers-color-scheme: dark)")]
        let declared = IconCandidateRanker.candidates(fromLinks: rows, pageURL: page)
        XCTAssertEqual(IconCandidateRanker.ordered(declared, pageURL: page).map(\.url.path), ["/light.png", "/favicon.ico"])
        XCTAssertEqual(IconCandidateRanker.darkVariants(declared).map(\.url.path), ["/dark.png"])
    }

    func testAtMostFourPageIconsAreTriedAndTheDefaultIsNeverCrowdedOut() {
        let rows = (0..<7).map { row("/i\($0).png", sizes: "64x64") }
        let list = order(rows)
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.last, "/favicon.ico", "the old code cut the list after adding the default, so with four links it was never tried")
    }

    func testTheSameAddressIsListedOnce() {
        let list = order([row("/a.png", sizes: "64x64"), row("/a.png#x", sizes: "64x64"), row("https://EXAMPLE.com/a.png", sizes: "64x64")])
        XCTAssertEqual(list, ["/a.png", "/favicon.ico"])
    }

    func testRelativeAddressesAreResolvedAgainstThePage() {
        let list = IconCandidateRanker.candidates(fromLinks: [row("../img/i.png"), row("//cdn.example.net/i.png"), row("i.png")], pageURL: page).map(\.url.absoluteString)
        XCTAssertEqual(list, ["https://example.com/img/i.png", "https://cdn.example.net/i.png", "https://example.com/docs/i.png"])
    }

    func testAnHTTPSPageMayNotNameAnHTTPIconButAnHTTPPageMay() {
        XCTAssertTrue(IconCandidateRanker.candidates(fromLinks: [row("http://example.com/i.png")], pageURL: page).isEmpty)
        let plain = URL(string: "http://example.com/")!
        XCTAssertEqual(IconCandidateRanker.candidates(fromLinks: [row("http://example.com/i.png")], pageURL: plain).count, 1)
        XCTAssertTrue(IconCandidateRanker.candidates(fromLinks: [row("javascript:alert(1)"), row("data:image/png;base64,AAAA"), row("file:///etc/passwd")], pageURL: page).isEmpty)
    }

    func testSizesAreReadFromTheDeclarationAndBadOnesAreIgnored() {
        let c = IconCandidateRanker.candidates(fromLinks: [row("/a.png", sizes: "16x16 32x32 junk 0x0 99999x99999"), row("/b.svg", sizes: "any")], pageURL: page)
        XCTAssertEqual(c[0].declaredSizes, [IconPixelSize(width: 16, height: 16), IconPixelSize(width: 32, height: 32)])
        XCTAssertTrue(c[1].declaresAnySize)
    }

    func testTheOrderIsTheSameEveryTime() {
        let rows = (0..<6).map { row("/i\($0).png", sizes: $0 % 2 == 0 ? "64x64" : "128x128") }
        let first = order(rows)
        for _ in 0..<20 { XCTAssertEqual(order(rows), first) }
    }

    func testAPageWithNoLinksStillTriesTheDefaultAndANonWebPageHasNone() {
        XCTAssertEqual(order([]), ["/favicon.ico"])
        XCTAssertTrue(IconCandidateRanker.ordered([], pageURL: URL(string: "about:blank")!).isEmpty)
    }

    func testTheKeyIgnoresCaseWwwAndTrailingDot() {
        XCTAssertEqual(IconKey(host: "WWW.Example.COM.")?.host, "example.com")
        XCTAssertEqual(IconKey(host: "m.example.com")?.host, "m.example.com")
        XCTAssertNil(IconKey(host: nil)); XCTAssertNil(IconKey(host: "")); XCTAssertNil(IconKey(host: "."))
    }
}
