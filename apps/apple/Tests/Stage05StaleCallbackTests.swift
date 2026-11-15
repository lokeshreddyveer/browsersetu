import XCTest
import WebKit
@testable import Browser_Setu

/// Stage 0.5: can an engine that a tab has already replaced still change that tab? Two angles, using real objects and no test double:
/// 1. does the old engine even outlive the replacement (if it is freed, a late callback cannot arrive), and
/// 2. if something did keep it alive, what would a late callback from it do to the tab's new state.
/// Throwaway storage per test; no production code is changed.
@MainActor
final class Stage05StaleCallbackTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage05-\(UUID().uuidString)", profile: "default")
    }

    private func pump(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// A tab put to sleep drops its web view: the old engine object is freed shortly after, so nothing can call back from it.
    func testTheReplacedEngineIsFreedAfterTheTabSleeps() async {
        let m = model()
        let tab = m.openTab(url: URL(string: "about:blank#stale-1")!, isPrivate: false)
        _ = m.openTab(url: URL(string: "about:blank#stale-2")!, isPrivate: false)
        weak var old: AnyObject? = tab.engine as AnyObject
        XCTAssertNotNil(old)
        tab.discard(afterProcessEnd: true)
        XCTAssertTrue(tab.isDiscarded)
        var freed = false
        for _ in 0..<60 where !freed { await pump(0.1); freed = (old == nil) }
        print("S05DIAG old engine freed after sleep = \(freed)")
        XCTAssertTrue(freed, "the replaced engine is still alive, so it could still deliver late callbacks to the tab")
    }

    /// If an old engine WERE still alive (here held on purpose), a late "web content process ended" from it must not turn a sleeping tab into an error page, nor count as a crash of the new engine.
    func testALateProcessEndFromAnOldEngineDoesNotChangeTheSleepingTab() async {
        let m = model()
        let tab = m.openTab(url: URL(string: "about:blank#stale-3")!, isPrivate: false)
        _ = m.openTab(url: URL(string: "about:blank#stale-4")!, isPrivate: false)        // so `tab` is not in front
        let oldEngine = tab.engine as! WebKitTab                                          // held on purpose
        tab.discard(afterProcessEnd: true)
        XCTAssertTrue(tab.isDiscarded)
        let before = ReliabilityStats.shared.tabCrashes
        oldEngine.webViewWebContentProcessDidTerminate(oldEngine.webView)                // the old web view's process "ends" late
        await pump(0.5)
        print("S05DIAG after late old-engine crash: showingError=\(tab.isShowingError) discarded=\(tab.isDiscarded) crashesCounted=\(ReliabilityStats.shared.tabCrashes - before)")
        // LATENT EXPOSURE S0-5 (Stage 0.5, not changed in production): `WebKitTab.close()` does not clear its event target, so a late callback from a replaced engine that is somehow still alive
        // reaches the tab. The previous test shows the old engine is freed in practice, so this has not been seen outside this injection. Strict expected failure: when `close()` is made to drop its
        // events (the one-line correction proposed in STAGE_0_5_REPORT.md) this reports an unexpected pass and the wrapper should be removed. It is NOT a passing behavioral guarantee.
        XCTExpectFailure("S0-5: a replaced engine that is still alive can still change the tab it used to belong to") {
            XCTAssertFalse(tab.isShowingError, "a late crash notice from a replaced engine put an error page on the sleeping tab")
            XCTAssertEqual(ReliabilityStats.shared.tabCrashes, before, "a late crash notice from a replaced engine was counted against the tab")
        }
        XCTAssertTrue(tab.isDiscarded)
    }
}
