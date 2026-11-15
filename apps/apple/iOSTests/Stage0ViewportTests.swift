import XCTest
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 0 viewport contract on iOS: how the room for floating chrome is applied to a page today. These pin the behavior that later viewport work must keep or deliberately change.
/// They need the iOS simulator (the insets are UIKit scroll-view values). No production code is touched; each test uses a throwaway storage root.
///
/// Stage 0.5 (S0-2): the first version of these tests wrote insets straight to the web view's engine. The tab's own page-load events then re-apply the MODEL's insets (zero in a test) a few hundred
/// milliseconds after the tab is created, which overwrote the test's values: two writers, so the result depended on load timing and looked intermittent. The model is now the single writer, as in the
/// app (`BrowserModel.phoneTopInset` and `phoneBottomInset`, applied by `TabController.applyBottomInset`). `Stage05HostedViewportTests.testTimelineOfInsetsBeforeAndAfterTheFirstPageCommit` has the evidence.
@MainActor
final class Stage0ViewportTests: XCTestCase {
    private func makeTab() -> (BrowserModel, TabController, WKWebView) {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage0-ios-\(UUID().uuidString)", profile: "default")
        let tab = model.openTab(url: URL(string: "about:blank#vp")!, isPrivate: false)
        return (model, tab, (tab.engine as! WebKitTab).webView)
    }

    /// The way the app asks for room: it tells the model, which tells every tab.
    private func request(_ model: BrowserModel, top: CGFloat, bottom: CGFloat) {
        model.phoneTopInset = top
        model.phoneBottomInset = bottom
    }

    /// Waits (bounded) on the observable value, then lets any late write prove it does not overwrite it.
    private func settle(until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        try? await Task.sleep(nanoseconds: 800_000_000)          // longer than the page-load re-application seen at roughly 0.4 to 0.9 s
    }

    private func room(_ web: WKWebView) -> (top: CGFloat, bottom: CGFloat) { (web.scrollView.contentInset.top, web.scrollView.contentInset.bottom) }

    func testApplyingTheSameInsetsRepeatedlyDoesNotAccumulate() async {
        let (model, tab, web) = makeTab()
        request(model, top: 60, bottom: 80)
        for _ in 0..<6 { tab.applyBottomInset() }
        await settle { self.room(web) == (60, 80) }
        XCTAssertEqual(room(web).top, 60, "double inset compensation: the top room was added more than once")
        XCTAssertEqual(room(web).bottom, 80, "double inset compensation: the bottom room was added more than once")
        XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets.top, 60)
        XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets.bottom, 80)
    }

    /// Control: when each change is given time to finish, the last request wins.
    func testTheLastRequestedInsetsWinWhenChangesAreSpacedApart() async {
        let (model, _, web) = makeTab()
        for (top, bottom) in [(60, 80), (0, 0), (44, 34), (30, 20)] as [(CGFloat, CGFloat)] {
            request(model, top: top, bottom: bottom)
            await settle { self.room(web) == (top, bottom) }
        }
        XCTAssertEqual(room(web).top, 30)
        XCTAssertEqual(room(web).bottom, 20)
    }

    /// Two changes in quick succession (inside the 0.25 s animation): the smallest case of the overlap the review describes.
    func testTheSecondOfTwoQuickInsetChangesWins() async {
        let (model, _, web) = makeTab()
        request(model, top: 60, bottom: 80)
        request(model, top: 30, bottom: 20)
        await settle { self.room(web) == (30, 20) }
        XCTAssertEqual(room(web).top, 30)
        XCTAssertEqual(room(web).bottom, 20)
    }

    /// Rapid changes, last one wins.
    func testTheLastRequestedInsetsWinAfterRapidChanges() async {
        let (model, _, web) = makeTab()
        for (top, bottom) in [(60, 80), (0, 0), (44, 34), (60, 80), (0, 49), (30, 20)] as [(CGFloat, CGFloat)] { request(model, top: top, bottom: bottom) }
        await settle { self.room(web) == (30, 20) }
        XCTAssertEqual(room(web).top, 30)
        XCTAssertEqual(room(web).bottom, 20)
    }

    func testClearingTheInsetsRemovesAllRoom() async {
        let (model, _, web) = makeTab()
        request(model, top: 60, bottom: 80)
        await settle { self.room(web) == (60, 80) }
        request(model, top: 0, bottom: 0)
        await settle { self.room(web) == (0, 0) }
        XCTAssertEqual(room(web).top, 0)
        XCTAssertEqual(room(web).bottom, 0)
        XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets, .zero)
    }

    /// Each tab's room is applied to its own web view, once: two tabs each end with exactly the requested room, not the sum.
    func testEachTabsWebViewGetsTheRoomExactlyOnce() async {
        let (model, a, webA) = makeTab()
        let b = model.openTab(url: URL(string: "about:blank#b")!, isPrivate: false)
        let webB = (b.engine as! WebKitTab).webView
        request(model, top: 50, bottom: 70)
        await settle { self.room(webA) == (50, 70) && self.room(webB) == (50, 70) }
        XCTAssertEqual(room(webA).bottom, 70)
        XCTAssertEqual(room(webB).bottom, 70, "each tab's web view has the room once, not added up across tabs")
        XCTAssertNotEqual(ObjectIdentifier(webA), ObjectIdentifier(webB))
        _ = a
    }

    /// The `PhoneRootView` re-application 0.35 s after a safe-area or tab change must be harmless (idempotent): repeating the request leaves the room unchanged.
    func testTheDelayedSecondApplicationIsIdempotent() async {
        let (model, tab, web) = makeTab()
        request(model, top: 44, bottom: 83)
        await settle { self.room(web) == (44, 83) }
        let first = web.scrollView.contentInset
        tab.applyBottomInset()                      // what the 0.35 s re-application does
        await settle { self.room(web) == (44, 83) }
        XCTAssertEqual(web.scrollView.contentInset, first)
        XCTAssertEqual(first.top, 44); XCTAssertEqual(first.bottom, 83)
    }
}
