import XCTest
@testable import Browser_Setu

/// Reported: every video in the toolbar list was "YouTube video · not resolved yet", and a pasted YouTube link downloaded the page's HTML as a file.
final class VideoLinkNamingAndRoutingTests: XCTestCase {
    @MainActor
    func testVideoCardsAreNamedByTheirOwnTitleWhenThePageGaveOne() {
        let a = "https://www.youtube.com/watch?v=AAAAAAAAAAA", b = "https://www.youtube.com/watch?v=BBBBBBBBBBB", c = "https://www.youtube.com/watch?v=CCCCCCCCCCC"
        let scan = PageLinkScan(links: [(a, false), (b, false), (c, false)], truncated: false, labels: [a: "Comedy Scene One", b: "Climax Scene"])
        let s = PageResourceSummary.build(scan: scan, media: .empty, pageHost: "www.youtube.com")
        let names = (s.items[.video] ?? []).map(\.filename)
        XCTAssertEqual(names.sorted(), ["Climax Scene", "Comedy Scene One", "YouTube video"].sorted(), "titled cards carry their title; one without keeps the generic name")
        XCTAssertEqual(Set(names).count, 3, "no two rows are identical here")
    }

    @MainActor
    func testAnAddedVideoPageGoesToTheVideoFlowNotToAFileDownload() {
        let store = LinkGrabberStore(profile: "p", isPrivate: false)
        for text in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/shorts/abcdefghijk"] {
            store.add(text: text, provenance: .pasted)
        }
        for link in store.items {
            guard case .videoPage = LinkRouter.route(link) else { return XCTFail("\(link.original) would be fetched as a file (saving its HTML)") }
        }
        store.add(text: "https://example.org/page.html", provenance: .pasted)
        store.add(text: "https://cdn.example.com/clip.mp4", provenance: .pasted)
        let others = store.items.suffix(2).map { LinkRouter.route($0) }
        for route in others { if case .videoPage = route { XCTFail("an ordinary address must not become a video page") } }
    }
}
