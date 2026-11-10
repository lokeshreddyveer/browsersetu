import XCTest
@testable import Browser_Setu

/// Where media was left and the marks in it: stored by fingerprint, only when worth it, never for a tab that leaves no trace.
final class MediaResumeTests: XCTestCase {
    func testOnlyLongMediaPastTheStartAndNotNearlyDoneIsWorthComingBackTo() {
        XCTAssertFalse(MediaResumeRules.worthResuming(time: 40, duration: 90), "too short")
        XCTAssertFalse(MediaResumeRules.worthResuming(time: 10, duration: 3600), "still at the start")
        XCTAssertFalse(MediaResumeRules.worthResuming(time: 3590, duration: 3600), "nearly finished")
        XCTAssertTrue(MediaResumeRules.worthResuming(time: 600, duration: 3600))
    }

    func testTheKeyStoresNoAddressAndIgnoresQueriesAndFragments() throws {
        let page = URL(string: "https://example.com/watch?v=abc&token=SECRET#t=30")
        let a = try XCTUnwrap(MediaResumeRules.key(pageURL: page, src: "https://cdn.example.com/v/video.mp4?sig=SECRET", duration: 3600))
        let b = try XCTUnwrap(MediaResumeRules.key(pageURL: URL(string: "https://example.com/watch?v=abc&token=OTHER"), src: "https://cdn.example.com/v/video.mp4?sig=OTHER", duration: 3600))
        XCTAssertEqual(a, b, "a changed token is still the same video")
        XCTAssertEqual(a.count, 64, "a fingerprint")
        XCTAssertFalse(a.contains("example") || a.contains("SECRET"))
    }

    func testABlobSourceIsNamedByThePageAndTheLength() throws {
        let page = URL(string: "https://example.com/watch")
        let a = try XCTUnwrap(MediaResumeRules.key(pageURL: page, src: "blob:https://example.com/1234", duration: 3600))
        let b = try XCTUnwrap(MediaResumeRules.key(pageURL: page, src: "blob:https://example.com/9999", duration: 3600))
        let other = try XCTUnwrap(MediaResumeRules.key(pageURL: page, src: "blob:https://example.com/1234", duration: 1800))
        XCTAssertEqual(a, b, "the blob's own number changes every visit and means nothing")
        XCTAssertNotEqual(a, other)
    }

    func testNothingIsKeyedForAPageThatIsNotWebAddressed() {
        XCTAssertNil(MediaResumeRules.key(pageURL: URL(string: "file:///tmp/a.html"), src: "", duration: 3600))
        XCTAssertNil(MediaResumeRules.key(pageURL: nil, src: "", duration: 3600))
    }

    func testTheListKeepsTheNewestFirstDropsTheOldAndStaysWithinItsLimit() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var list: [MediaResumeEntry] = []
        for i in 0..<(MediaResumeRules.limit + 20) { list = MediaResumeRules.updating(list, with: MediaResumeEntry(key: "k\(i)", time: 100, duration: 1000, saved: now), now: now) }
        XCTAssertEqual(list.count, MediaResumeRules.limit)
        XCTAssertEqual(list.first?.key, "k\(MediaResumeRules.limit + 19)")
        let old = MediaResumeEntry(key: "old", time: 100, duration: 1000, saved: now.addingTimeInterval(-70 * 86_400))
        let updated = MediaResumeRules.updating([old], with: MediaResumeEntry(key: "new", time: 1, duration: 1, saved: now), now: now)
        XCTAssertEqual(updated.map(\.key), ["new"], "older than sixty days is forgotten")
        let again = MediaResumeRules.updating(updated, with: MediaResumeEntry(key: "new", time: 50, duration: 1, saved: now), now: now)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.time, 50, "the same media is one entry")
    }
}
