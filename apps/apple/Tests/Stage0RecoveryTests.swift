import XCTest
@testable import Browser_Setu

/// Stage 0: web-content process recovery at the tab level (the pure counting rule is covered by `CrashGuardTests`). Each test uses throwaway storage and no production code is changed.
@MainActor
final class Stage0RecoveryTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage0-rec-\(UUID().uuidString)", profile: "default")
    }

    /// A page whose process ended while it was not in front is put to sleep (not shown an error) and keeps its identity.
    func testABackgroundTabWhoseProcessEndedGoesToSleepWithoutAnError() async {
        let m = model()
        let a = m.openTab(url: URL(string: "https://one.example/")!, isPrivate: false)
        let b = m.openTab(url: URL(string: "https://two.example/")!, isPrivate: false)
        a.engineURLChanged(URL(string: "https://one.example/")!)
        m.select(b.id)
        let id = a.id
        a.engineProcessCrashed()
        // The sleep is scheduled a moment later on purpose (see TabController.engineProcessCrashed).
        for _ in 0..<40 where !a.isDiscarded { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(a.id, id)
        XCTAssertTrue(a.isDiscarded, "a background tab whose process ended should be put to sleep")
        XCTAssertFalse(a.isShowingError, "an isolated crash of a background tab must not show an error page")
        XCTAssertEqual(m.activeID, b.id, "recovering one tab must not change which tab is in front")
    }

    /// Repeated crashes of one page stop the cycle: after three in the window the tab shows an error with reloads paused instead of reloading forever.
    func testRepeatedCrashesOfTheFrontTabEndInAPausedErrorNotALoop() {
        let m = model()
        let tab = m.openTab(url: URL(string: "https://crashy.example/")!, isPrivate: false)
        tab.engineURLChanged(URL(string: "https://crashy.example/")!)
        for _ in 0..<3 { tab.engineProcessCrashed() }
        XCTAssertTrue(tab.isShowingError, "the third crash in a row must show the error page")
        let before = tab.engine.currentURL
        tab.reload()                                  // paused: must not start another load
        XCTAssertEqual(tab.engine.currentURL, before)
        XCTAssertFalse((m.notice ?? "").isEmpty, "the person is told why reload is paused")
    }

    /// A crash in one tab leaves every other tab's web view and state alone.
    func testACrashInOneTabDoesNotTouchTheOthers() {
        let m = model()
        let tabs = (0..<3).map { m.openTab(url: URL(string: "about:blank#r\($0)")!, isPrivate: false) }
        let engines = tabs.map { ObjectIdentifier($0.engine as AnyObject) }
        tabs[1].engineProcessCrashed()
        XCTAssertEqual(ObjectIdentifier(tabs[0].engine as AnyObject), engines[0])
        XCTAssertEqual(ObjectIdentifier(tabs[2].engine as AnyObject), engines[2])
        XCTAssertFalse(tabs[0].isShowingError); XCTAssertFalse(tabs[2].isShowingError)
    }
}
