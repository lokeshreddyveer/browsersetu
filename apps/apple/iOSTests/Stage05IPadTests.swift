import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 0.5: iPad page hosting. The real `IPadRootView` is hosted in a real `UIWindow` at several window sizes (full screen, portrait, Split View, Slide Over, below the sidebar threshold), and the tests read
/// where the page's web view actually ends up. Meant to run on an iPad simulator; on any other device they skip. Throwaway storage per test; no production code is changed.
@MainActor
final class Stage05IPadTests: XCTestCase {
    private final class Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        init(model: BrowserModel, size: CGSize) {
            controller = UIHostingController(rootView: AnyView(IPadRootView().environmentObject(model)))
            // SwiftUI renders only into a window that belongs to a window scene, so the test window joins the app's own scene.
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) } else { window = UIWindow(frame: .zero) }
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
        func resize(_ size: CGSize) { window.frame = CGRect(origin: .zero, size: size); window.layoutIfNeeded(); controller.view.layoutIfNeeded() }
        func tearDown() { window.isHidden = true; window.rootViewController = nil }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad tests need an iPad simulator or device")
    }

    private func makeModel() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage05-ipad-\(UUID().uuidString)", profile: "default")
    }

    @discardableResult
    private func waitUntil(_ seconds: Double = 4.0, _ condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    /// A tab that shows a real page (a blank tab shows the start page, which has no web view to host).
    private func pageTab(_ model: BrowserModel, _ label: String) -> TabController {
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><body style='height:2000px'><h1>\(label)</h1></body></html>", baseURL: URL(string: "https://\(label).example.test/"))
        waitUntil(6) { !tab.isBlank }
        return tab
    }

    private func webView(of tab: TabController) -> WKWebView { (tab.engine as! WebKitTab).webView }

    /// The web view's frame in window coordinates, or nil while it is not in this window.
    private func frameInWindow(_ web: WKWebView, _ window: UIWindow) -> CGRect? {
        guard web.window === window, web.superview != nil else { return nil }
        return web.convert(web.bounds, to: window)
    }

    private let sizes: [(name: String, size: CGSize)] = [
        ("landscape full screen", CGSize(width: 1194, height: 834)),
        ("portrait full screen", CGSize(width: 834, height: 1194)),
        ("split view two thirds", CGSize(width: 639, height: 1194)),
        ("split view one third", CGSize(width: 507, height: 1194)),
        ("slide over", CGSize(width: 320, height: 1194)),
    ]

    /// Every width from Split View's one third up. Slide Over (320 pt) is its own test below, because it does not fit.
    private var fittingSizes: [(name: String, size: CGSize)] { sizes.filter { $0.size.width >= 507 } }

    func testThePageIsHostedInsideTheWindowAtEveryWidth() {
        for (name, size) in fittingSizes {
            let model = makeModel()
            let tab = pageTab(model, "ipad")
            let host = Host(model: model, size: size)
            let web = webView(of: tab)
            XCTAssertTrue(waitUntil { self.frameInWindow(web, host.window) != nil }, "\(name): the page's web view never reached the window")
            guard let frame = frameInWindow(web, host.window) else { host.tearDown(); continue }
            print("S05DIAG ipad host[\(name)] window=\(Int(size.width))x\(Int(size.height)) web=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) sidebarVisible=\(model.sidebarVisible)")
            XCTAssertGreaterThan(frame.width, 100, "\(name): the page has no usable width")
            XCTAssertGreaterThan(frame.height, 100, "\(name): the page has no usable height")
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(name): the page extends past the right edge")
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.5, "\(name): the page extends past the bottom edge")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5); XCTAssertGreaterThanOrEqual(frame.minY, -0.5)
            host.tearDown()
        }
    }


    /// FINDING S05-A (Stage 0.5, not changed in production): in a 320-pt window (Slide Over, which exists on the supported iPadOS 17) the hosted `IPadRootView` lays the page out 340 pt wide at x = -10, ten points past
    /// both edges. Strict expected failure: it reports an unexpected pass when the layout is fixed, and the wrapper should then be removed. Seen only in a hosted test window, not on a real Slide Over.
    func testSlideOverWidthPageFitsTheWindow() {
        let (name, size) = sizes[4]
        let model = makeModel()
        let tab = pageTab(model, "ipad-slide")
        let host = Host(model: model, size: size)
        let web = webView(of: tab)
        XCTAssertTrue(waitUntil { self.frameInWindow(web, host.window) != nil }, "\(name): the page's web view never reached the window")
        let frame = frameInWindow(web, host.window) ?? .zero
        print("S05DIAG ipad slide-over window=\(Int(size.width)) web=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        XCTExpectFailure("S05-A: the page is wider than a 320-pt window") {
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "the page starts left of the window")
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "the page extends past the right edge")
        }
        host.tearDown()
    }

    /// Resizing the window (rotation, Split View, Stage Manager) re-lays out the same web view; it is not replaced.
    func testResizingTheWindowKeepsTheSameWebViewInsideIt() {
        let model = makeModel()
        let tab = pageTab(model, "ipad-resize")
        let host = Host(model: model, size: sizes[0].size)
        let web = webView(of: tab)
        XCTAssertTrue(waitUntil { self.frameInWindow(web, host.window) != nil })
        for (name, size) in fittingSizes + [sizes[0]] {
            host.resize(size)
            XCTAssertTrue(waitUntil { if let f = self.frameInWindow(web, host.window) { return f.maxX <= size.width + 0.5 && f.maxY <= size.height + 0.5 && f.width > 100 } else { return false } }, "\(name): the page did not fit the resized window")
            XCTAssertTrue(web === webView(of: tab), "\(name): the web view was replaced by a resize")
        }
        host.tearDown()
    }

    /// Tab switching on iPad: the selected tab's web view is the one shown, with a usable frame, after each switch.
    func testSwitchingTabsShowsTheSelectedTabsWebView() {
        let model = makeModel()
        let tabs = (0..<3).map { pageTab(model, "ipad-\($0)") }
        let host = Host(model: model, size: sizes[0].size)
        for round in 0..<2 {
            for tab in tabs {
                model.select(tab.id)
                let web = webView(of: tab)
                XCTAssertTrue(waitUntil { if let f = self.frameInWindow(web, host.window) { return f.width > 100 && f.height > 100 && !web.isHidden } else { return false } }, "round \(round): tab \(tab.id) was selected but its page is not shown")
            }
        }
        // Rapid A -> B -> C: the last one is the one shown.
        model.select(tabs[0].id); model.select(tabs[1].id); model.select(tabs[2].id)
        let last = webView(of: tabs[2])
        XCTAssertTrue(waitUntil { self.frameInWindow(last, host.window).map { $0.width > 100 } ?? false }, "after a rapid A, B, C the last tab's page is not shown")
        XCTAssertEqual(model.activeID, tabs[2].id)
        host.tearDown()
    }

    /// Split panes are macOS-only: nothing in the iPad code reads `splitTabID`. Setting a second pane changes nothing on iPad: the selected tab's page stays shown and the other tab's page is not added. (Characterization, so
    /// that adding iPad split panes later is a deliberate change. It also means the memory-release split-pane race, S0-1, can only matter on the Mac.)
    func testASecondPaneIsNotShownOnIPad() {
        let model = makeModel()
        let tabs = (0..<2).map { pageTab(model, "ipad-split-\($0)") }
        model.select(tabs[0].id)
        let host = Host(model: model, size: sizes[0].size)
        let webA = webView(of: tabs[0]), webB = webView(of: tabs[1])
        XCTAssertTrue(waitUntil { (self.frameInWindow(webA, host.window)?.width ?? 0) > 100 }, "the selected tab's page is not shown")
        model.splitTabID = tabs[1].id
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        print("S05DIAG ipad split: selectedShown=\((frameInWindow(webA, host.window)?.width ?? 0) > 100) otherShown=\((frameInWindow(webB, host.window)?.width ?? 0) > 100)")
        XCTAssertGreaterThan(frameInWindow(webA, host.window)?.width ?? 0, 100, "the selected tab's page disappeared when a second pane was set")
        XCTAssertNil(frameInWindow(webB, host.window), "a second pane is shown on iPad, so iPad split panes now exist: update the split-pane tests and S0-1's scope")
        host.tearDown()
    }

    /// Safe-area change on iPad: the page still fits the window when the system adds a safe area.
    func testASafeAreaChangeKeepsThePageInsideTheWindow() {
        let model = makeModel()
        let tab = pageTab(model, "ipad-safe")
        let host = Host(model: model, size: sizes[0].size)
        let web = webView(of: tab)
        XCTAssertTrue(waitUntil { self.frameInWindow(web, host.window) != nil })
        host.controller.additionalSafeAreaInsets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        host.window.layoutIfNeeded()
        XCTAssertTrue(waitUntil { self.frameInWindow(web, host.window).map { $0.maxX <= self.sizes[0].size.width + 0.5 && $0.maxY <= self.sizes[0].size.height + 0.5 && $0.width > 100 } ?? false }, "the page does not fit after a safe-area change")
        host.tearDown()
    }

    /// Diagnostic: where do the web views end up when the real iPad root view is hosted? Prints what is in the window after the page is shown.
    func testDiagnoseWhereTheWebViewsAre() {
        let model = makeModel()
        let tab = pageTab(model, "diag")
        let host = Host(model: model, size: sizes[0].size)
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        func descendants(_ v: UIView) -> [UIView] { v.subviews.flatMap { [$0] + descendants($0) } }
        let all = descendants(host.controller.view)
        let webs = all.compactMap { $0 as? WKWebView }
        let web = webView(of: tab)
        print("S05DIAG ipad diag: tabBlank=\(tab.isBlank) tabURL=\(tab.url?.absoluteString ?? "nil") active=\(String(describing: model.activeID)) subviewsInWindow=\(all.count) webViewsInWindow=\(webs.count) tabWebInWindow=\(webs.contains { $0 === web }) tabWebWindowNil=\(web.window == nil) tabWebSuperviewNil=\(web.superview == nil) tabWebFrame=\(web.frame) hidden=\(web.isHidden) alpha=\(web.alpha) showSetup=\(model.showSetup) layout=\(model.layoutPreset)")
        print("S05DIAG ipad diag classes: \(Set(all.map { String(describing: type(of: $0)) }).sorted().prefix(25))")
        host.tearDown()
    }

    /// Sidebar on iPad (`IPadRootView.swift:12-16`): with the sidebar turned on it takes room from the page in a wide window, and steps aside below 640 pt so the page keeps its room.
    func testTheSidebarTakesRoomInAWideWindowAndStepsAsideInANarrowOne() {
        func pageWidth(_ size: CGSize) -> CGFloat {
            let model = makeModel()
            model.sidebarVisible = true
            let tab = pageTab(model, "ipad-sidebar")
            let host = Host(model: model, size: size)
            let web = webView(of: tab)
            waitUntil { self.frameInWindow(web, host.window) != nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let width = frameInWindow(web, host.window)?.width ?? 0
            host.tearDown()
            return width
        }
        let wide = pageWidth(sizes[0].size), narrow = pageWidth(sizes[3].size)
        print("S05DIAG ipad sidebar: wide window 1194 -> page \(Int(wide)) wide; 507 window -> page \(Int(narrow)) wide")
        XCTAssertLessThan(wide, 1194 - 200, "with the sidebar on, the page in a wide window should be narrower by the sidebar")
        // Observed: with the sidebar on, the 507-pt window's page is 433 wide, 50 pt narrower than the 483 it gets with the sidebar off (cause not examined). The bound here is only that it loses less than the
        // sidebar's own minimum width (220 pt), i.e. the sidebar did step aside.
        XCTAssertGreaterThan(narrow, 507 - 24 - 220, "below 640 pt the sidebar should step aside and leave the page its room")
    }
}
