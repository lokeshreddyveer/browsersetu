import XCTest
@testable import Browser_Setu

final class PageVersionsTests: XCTestCase {
    func testDiffMarksAddedAndRemovedLines() {
        let diff = TextDiff.compare(old: "Price 10\nShips free\nIn stock", new: "Price 8\nShips free\nIn stock\nNew colour")
        XCTAssertTrue(diff.contains { $0.kind == .removed && $0.text == "Price 10" })
        XCTAssertTrue(diff.contains { $0.kind == .added && $0.text == "Price 8" })
        XCTAssertTrue(diff.contains { $0.kind == .added && $0.text == "New colour" })
        XCTAssertTrue(diff.contains { $0.kind == .same && $0.text == "Ships free" })
        XCTAssertEqual(TextDiff.changeCount(diff), 3)
    }

    func testIdenticalTextHasNoChanges() {
        XCTAssertEqual(TextDiff.changeCount(TextDiff.compare(old: "a\nb", new: "a\nb")), 0)
    }

    func testPriceFinder() {
        XCTAssertEqual(PriceFinder.firstPrice(in: "Now only $1,249.99 today"), 1249.99)
        XCTAssertEqual(PriceFinder.firstPrice(in: "₹499 per month"), 499)
        XCTAssertNil(PriceFinder.firstPrice(in: "free"))
    }

    func testWatchDetectsChangeAndPriceDropButNotReflow() {
        let watch = PageWatch(title: "t", digest: PageDigest.of("Shirt\nPrice $40"), firstPrice: 40, checked: Date())
        XCTAssertEqual(WatchCheck.evaluate(watch: watch, newText: "Shirt   Price $40"), .unchanged)
        XCTAssertEqual(WatchCheck.evaluate(watch: watch, newText: "Shirt\nPrice $30"), .priceDropped(from: 40, to: 30))
        XCTAssertEqual(WatchCheck.evaluate(watch: watch, newText: "Shirt\nPrice $45\nSold out soon"), .changed)
    }

    func testShareTextAndVideoTimeLink() {
        let url = URL(string: "https://a.test/watch?v=1&utm_source=x")!
        XCTAssertFalse(TabSharing.text(for: [("Clip", url)]).contains("utm_source"))
        XCTAssertTrue(TabSharing.link(URL(string: "https://a.test/watch?v=1&t=9")!, atSeconds: 125).absoluteString.hasSuffix("t=125"))
        XCTAssertEqual(TabSharing.link(url, atSeconds: 2), url)
    }
}
