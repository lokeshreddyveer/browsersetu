import XCTest
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 0.5, S0-2: viewport insets requested in quick succession were seen to end at zero when the web view was NOT in a window. These tests run the same sequences with the web view hosted in a real
/// `UIWindow` and offscreen, side by side, with bounded waits on observable state (the scroll view's insets) instead of fixed sleeps, and record requested versus observed values.
/// Throwaway storage per test; no production code is changed.
@MainActor
final class Stage05HostedViewportTests: XCTestCase {
    private struct Inset: Equatable, CustomStringConvertible {
        var top: CGFloat, bottom: CGFloat
        var description: String { "\(Int(top))/\(Int(bottom))" }
    }

    private final class Host {
        let window: UIWindow
        let controller = UIViewController()
        init() {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
        func attach(_ view: UIView) {
            view.frame = controller.view.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(view)
            controller.view.layoutIfNeeded()
        }
        func tearDown() { window.isHidden = true; window.rootViewController = nil }
    }

    private func makeTab(hosted: Host?) -> (BrowserModel, TabController, WKWebView) {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage05-ios-\(UUID().uuidString)", profile: "default")
        let tab = model.openTab(url: URL(string: "about:blank#hosted")!, isPrivate: false)
        let web = (tab.engine as! WebKitTab).webView
        hosted?.attach(web)
        return (model, tab, web)
    }

    /// Waits (bounded) until the condition holds, polling the run loop. Returns how long it took in milliseconds, or nil if it never held.
    @discardableResult
    private func waitUntil(_ seconds: Double = 2.0, _ condition: () -> Bool) -> Double? {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            if condition() { return (CACurrentMediaTime() - start) * 1000 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition() ? (CACurrentMediaTime() - start) * 1000 : nil
    }

    private func observed(_ web: WKWebView) -> Inset { Inset(top: web.scrollView.contentInset.top, bottom: web.scrollView.contentInset.bottom) }

    /// Runs a sequence of requests as fast as possible and reports the final observed insets once they stop changing (or after the bound).
    private func runSequence(_ sequence: [Inset], on tab: TabController, web: WKWebView) -> (final: Inset, settledMs: Double?) {
        for item in sequence { tab.engine.setViewportInsets(top: item.top, bottom: item.bottom) }
        let want = sequence.last!
        let ms = waitUntil(2.0) { self.observed(web) == want }
        // Give any late animation a further moment to overwrite the value, then read again: "reached it" must also mean "stayed there".
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (observed(web), ms)
    }

    private func tally(_ name: String, hosted: Bool, trials: Int, sequence: [Inset]) -> (wrong: Int, didNotSettle: Int) {
        var wrong = 0, noSettle = 0
        var seen: [String] = []
        var times: [Double] = []
        for _ in 0..<trials {
            let host: Host? = hosted ? Host() : nil
            let (_, tab, web) = makeTab(hosted: host)
            let result = runSequence(sequence, on: tab, web: web)
            if result.final != sequence.last! { wrong += 1; seen.append("\(result.final)") }
            if let ms = result.settledMs { times.append(ms) } else { noSettle += 1 }
            host?.tearDown()
        }
        let sorted = times.sorted()
        func pct(_ q: Double) -> Int { sorted.isEmpty ? -1 : Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) }
        print("S05DIAG viewport \(name) hosted=\(hosted) trials=\(trials) wrongFinal=\(wrong) neverReachedRequested=\(noSettle) wrongValues=\(seen) timeToRequestedMs p50=\(pct(0.5)) p95=\(pct(0.95)) max=\(pct(1.0)) first=\(times.first.map { Int($0) } ?? -1)")
        return (wrong, noSettle)
    }

    private let twoQuick = [Inset(top: 60, bottom: 80), Inset(top: 30, bottom: 20)]
    private let sixRapid = [Inset(top: 60, bottom: 80), Inset(top: 0, bottom: 0), Inset(top: 44, bottom: 34), Inset(top: 60, bottom: 80), Inset(top: 0, bottom: 49), Inset(top: 30, bottom: 20)]

    /// The comparison that decides attribution: identical sequences, hosted versus offscreen, many fresh web views each.
    func testHostedAndOffscreenAreComparedOnQuickSequences() {
        let off2 = tally("two-quick", hosted: false, trials: 25, sequence: twoQuick)
        let hosted2 = tally("two-quick", hosted: true, trials: 25, sequence: twoQuick)
        let off6 = tally("six-rapid", hosted: false, trials: 25, sequence: sixRapid)
        let hosted6 = tally("six-rapid", hosted: true, trials: 25, sequence: sixRapid)
        print("S05DIAG viewport SUMMARY offscreen wrong=\(off2.wrong + off6.wrong)/50 hosted wrong=\(hosted2.wrong + hosted6.wrong)/50")
        // The claim that matters for production: with the web view in a window, the last request wins every time.
        XCTAssertEqual(hosted2.wrong + hosted6.wrong, 0, "with the web view hosted in a window, quick successive insets did not end on the last request")
    }

    func testHostedRepeatedIdenticalValuesDoNotAccumulate() {
        let host = Host()
        let (_, tab, web) = makeTab(hosted: host)
        for _ in 0..<8 { tab.engine.setViewportInsets(top: 60, bottom: 80) }
        XCTAssertNotNil(waitUntil { self.observed(web) == Inset(top: 60, bottom: 80) })
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(observed(web), Inset(top: 60, bottom: 80), "double inset compensation while hosted")
        host.tearDown()
    }

    func testHostedClearingRemovesAllRoom() {
        let host = Host()
        let (_, tab, web) = makeTab(hosted: host)
        tab.engine.setViewportInsets(top: 60, bottom: 80)
        waitUntil { self.observed(web) == Inset(top: 60, bottom: 80) }
        tab.engine.setViewportInsets(top: 0, bottom: 0)
        XCTAssertNotNil(waitUntil { self.observed(web) == Inset(top: 0, bottom: 0) })
        host.tearDown()
    }

    /// A safe-area change while hosted: the room told to the page includes the safe area, the scroll room does not (WebKitEngine.swift:511-514). Records the told values via the web view's own viewport insets.
    func testHostedSafeAreaChangeKeepsScrollRoomAndToldRoomConsistent() {
        let host = Host()
        let (_, tab, web) = makeTab(hosted: host)
        tab.engine.setViewportInsets(top: 20, bottom: 30)
        waitUntil { self.observed(web) == Inset(top: 20, bottom: 30) }
        host.controller.additionalSafeAreaInsets = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        host.controller.view.layoutIfNeeded()
        let safe = web.safeAreaInsets
        tab.engine.setViewportInsets(top: 20, bottom: 30)          // what the 0.35 s re-application does after a safe-area change
        waitUntil { web.minimumViewportInset.top == 20 + safe.top && web.minimumViewportInset.bottom == 30 + safe.bottom }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        print("S05DIAG viewport safe-area: safe=\(safe.top)/\(safe.bottom) told(min)=\(web.minimumViewportInset.top)/\(web.minimumViewportInset.bottom) scrollRoom=\(observed(web))")
        XCTAssertEqual(observed(web), Inset(top: 20, bottom: 30), "the scroll room must stay what was requested, without the safe area added")
        XCTAssertEqual(web.minimumViewportInset.top, 20 + safe.top, accuracy: 0.5)
        XCTAssertEqual(web.minimumViewportInset.bottom, 30 + safe.bottom, accuracy: 0.5)
        host.tearDown()
    }

    /// Tab switch while hosted: moving a different tab's web view into the window and applying the room to it leaves the first tab's room alone.
    func testHostedTabSwitchGivesEachWebViewItsOwnRoom() {
        let host = Host()
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage05-ios-\(UUID().uuidString)", profile: "default")
        let a = model.openTab(url: URL(string: "about:blank#a")!, isPrivate: false)
        let b = model.openTab(url: URL(string: "about:blank#b")!, isPrivate: false)
        let webA = (a.engine as! WebKitTab).webView, webB = (b.engine as! WebKitTab).webView
        host.attach(webA)
        model.phoneTopInset = 44; model.phoneBottomInset = 83
        a.applyBottomInset()
        waitUntil { self.observed(webA) == Inset(top: 44, bottom: 83) }
        webA.removeFromSuperview(); host.attach(webB)
        model.select(b.id)
        b.applyBottomInset()
        XCTAssertNotNil(waitUntil { self.observed(webB) == Inset(top: 44, bottom: 83) })
        XCTAssertEqual(observed(webA), Inset(top: 44, bottom: 83), "the first tab's room must not change when another tab is shown")
        host.tearDown()
    }

    /// The production flow around a page commit: the browser sets the room, a page loads, and the browser re-applies the room when the load ends (`TabController.swift:404`).
    /// Records whether the commit itself removed the room, and whether the room is back afterwards. `setViewportInsets` skips a request equal to the one it last applied (`WebKitEngine.swift:518`),
    /// so if WebKit resets the scroll view's insets on commit, a re-apply of the same values could be skipped and the room stay lost.
    func testTheRoomSurvivesAPageCommitHosted() {
        var lostAtCommit = 0, notRestored = 0
        let trials = 12
        for _ in 0..<trials {
            let host = Host()
            let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage05-ios-\(UUID().uuidString)", profile: "default")
            let tab = model.openTab(url: nil, isPrivate: false)
            let web = (tab.engine as! WebKitTab).webView
            host.attach(web)
            model.phoneTopInset = 60; model.phoneBottomInset = 80
            waitUntil { self.observed(web) == Inset(top: 60, bottom: 80) }
            var sawLoss = false
            tab.engine.showHTML("<html><body style='height:3000px'><h1>commit</h1></body></html>", baseURL: URL(string: "https://commit.example.test/"))
            // Watch the whole load: a loss at any moment is recorded, then wait for the load to end and the room to settle.
            let end = CACurrentMediaTime() + 4
            while CACurrentMediaTime() < end {
                if observed(web) != Inset(top: 60, bottom: 80) { sawLoss = true }
                if !web.isLoading && !tab.isLoading && CACurrentMediaTime() > end - 3.4 { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))      // covers the re-application that follows the end of a load
            if sawLoss { lostAtCommit += 1 }
            if observed(web) != Inset(top: 60, bottom: 80) { notRestored += 1 }
            host.tearDown()
        }
        print("S05DIAG commit trials=\(trials) roomLostDuringLoad=\(lostAtCommit) roomNotBackAfterLoad=\(notRestored)")
        XCTAssertEqual(notRestored, 0, "after a page loaded, the room requested for the floating bars was not back")
    }

    /// S0-2 diagnosis: a timeline of the scroll view's insets after the request, for a web view whose first page has not yet committed (what the Stage 0 tests did) versus one that has finished loading.
    /// Prints every change with its time; asserts nothing about the early case (that is the question), but the settled case must hold the room.
    func testTimelineOfInsetsBeforeAndAfterTheFirstPageCommit() {
        // The fourth case is the production path: the model holds the room, so the tab's own page-load events re-apply the same values instead of zero.
        for (label, waitForInitialLoad, hosted, modelHoldsRoom) in [("direct engine call, immediately after creation, offscreen", false, false, false), ("direct engine call, after the first load finished, offscreen", true, false, false), ("direct engine call, immediately after creation, hosted", false, true, false), ("model holds the room (production path), immediately after creation, hosted", false, true, true)] {
            for trial in 0..<4 {
                let host: Host? = hosted ? Host() : nil
                let (model, tab, web) = makeTab(hosted: host)
                if waitForInitialLoad { waitUntil(4) { !web.isLoading && web.url != nil } }
                let t0 = CACurrentMediaTime()
                var timeline: [String] = ["0ms:\(observed(web))"]
                var last = observed(web)
                if modelHoldsRoom { model.phoneTopInset = 60; model.phoneBottomInset = 80 } else { tab.engine.setViewportInsets(top: 60, bottom: 80) }
                let end = t0 + 2.5
                while CACurrentMediaTime() < end {
                    let now = observed(web)
                    if now != last { timeline.append("\(Int((CACurrentMediaTime() - t0) * 1000))ms:\(now)"); last = now }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                print("S05DIAG timeline [\(label)] trial=\(trial) isLoadingAtRequest=\(waitForInitialLoad ? "no" : "maybe") final=\(observed(web)) changes=\(timeline)")
                host?.tearDown()
            }
        }
    }
}
